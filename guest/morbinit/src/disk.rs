//! Persistent storage for Docker's data root.
//!
//! The host attaches a raw image (`~/.morbstack/data/disk.img`) as the
//! guest's `/dev/vda`. On a first boot that image is a freshly created
//! sparse file — all zeros, no filesystem — so somebody has to format it,
//! and PID 1 is the only somebody there is. On every later boot the same
//! image already holds the layer store, and formatting it would silently
//! destroy every image the user has pulled.
//!
//! So the whole module turns on one question: **is this device blank?**
//!
//!   * blank (first 1 MiB reads back all zeros)  -> mkfs, then mount,
//!   * carries our format-intent marker          -> mkfs (see below),
//!   * not blank                                 -> mount only, *never* mkfs,
//!   * missing / unreadable                      -> treat as absent.
//!
//! "Not blank but won't mount" is deliberately a dead end: we log loudly and
//! fall back to a tmpfs rather than reformatting. A disk we cannot read is a
//! disk whose contents we cannot judge, and destroying a user's image cache
//! to recover from a transient mount failure is not a trade worth making.
//! The cost of being wrong in the safe direction is a slow boot; the cost of
//! being wrong in the other direction is unrecoverable data loss.
//!
//! That safe direction has one hole, which the **format-intent marker**
//! closes. If the guest dies *during* the very first `mkfs` — the host
//! quitting, the VM being killed, the laptop's battery going — the device is
//! left non-blank (mkfs wrote something) and unmountable (it wrote only part
//! of something). Every later boot then classifies it as `Formatted`,
//! refuses to touch it, and falls back to tmpfs: persistence is bricked
//! forever, by exactly the caution that is supposed to protect it, and the
//! only escape is deleting `disk.img` by hand.
//!
//! So immediately before invoking `mkfs` — at a point where the device has
//! just been *proven* blank — we stamp `MORBFMT!` plus a version byte into
//! its first sector and sync it. A successful `mkfs` overwrites that sector
//! (both formatters wipe the head of the device; `format_and_mount` verifies
//! it and clears it explicitly if not). So finding the marker on a later boot
//! can mean only one thing: a format started and never finished, and the
//! bytes on the device are our own half-written filesystem. Such a disk is
//! classified `Blank` and formatted again. This cannot destroy user data —
//! the marker is only ever written to a device we had just verified held
//! nothing at all.
//!
//! Filesystem preference is btrfs, then ext4, depending on which `mkfs`
//! binary the initramfs actually ships (probed off `GUEST_PATH`). btrfs is
//! preferred because transparent zstd compression makes the layer store
//! markedly smaller and `discard=async` lets the sparse host image shrink
//! back when images are removed.
//!
//! When any step fails we mount a tmpfs at `/var/lib/docker` instead and
//! report `docker_data_on_disk = false`, which is what makes `supervisor.rs`
//! fall back from `overlay2` to the `vfs` storage driver — overlayfs cannot
//! stack on tmpfs. Boot always continues.
//!
//! The classification logic (`probe_is_blank`, `classify`) and the `PATH`
//! probe are plain portable code so they unit test on the macOS dev host;
//! only the actual `mount(2)`/`mkfs` plumbing is Linux-only.

use crate::log;
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Mutex;

/// The guest's raw data disk, as attached by morbstackd on the host side.
pub const DATA_DISK: &str = "/dev/vda";

/// Docker's data root. Mounting the disk directly here (rather than at some
/// private mountpoint we then bind into place) means dockerd's layer store
/// lands on real storage with no extra plumbing.
pub const DOCKER_DATA_ROOT: &str = "/var/lib/docker";

/// The device/filesystem facts returned after an explicit host-authorized grow.
///
/// This is intentionally a flat value because MRB0 accepts only flat JSON objects.
/// It is a proof for the host to validate against its durable journal, not a request
/// to trust a bare command exit status.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResizeProof {
    pub device: String,
    pub mount_point: String,
    pub filesystem: String,
    pub device_bytes: i64,
    pub before_filesystem_bytes: i64,
    pub after_filesystem_bytes: i64,
    pub resized: bool,
    /// `true` only when a previous successful grow left a durable receipt on this
    /// same filesystem. This closes the crash window after a grow tool succeeds but
    /// before the host can record its MRB0 reply.
    pub previously_proved: bool,
}

/// `disk_resize` is a mutating control operation. The host normally has only one
/// control client, but serializing here makes a duplicated/retried request prove one
/// whole state transition at a time instead of running two filesystem tools against
/// the same mounted data root.
static DISK_GROW_LOCK: Mutex<()> = Mutex::new(());

/// How much of the device has to read back as zeros before we are willing
/// to call it blank and format it.
///
/// 1 MiB is chosen to comfortably cover every filesystem signature we might
/// be about to destroy: ext4's primary superblock sits at byte 1024, btrfs's
/// at 64 KiB, xfs's at byte 0, and LVM/LUKS/partition-table headers all live
/// in the first few sectors. If all of that is zero, there is nothing here.
const BLANK_PROBE_LEN: usize = 1024 * 1024;

/// Read granularity for the blank probe.
const PROBE_CHUNK_LEN: usize = 64 * 1024;

/// Magic opening the format-intent marker. Eight bytes, ASCII, nothing else
/// writes it: it appears on a device only because morbinit put it there.
const FORMAT_MARKER_MAGIC: &[u8; 8] = b"MORBFMT!";

/// Marker layout version, immediately after the magic. Bumped only if the
/// marker ever grows fields; any *nonzero* value is still recognised as our
/// marker, because the thing it proves ("a format started here") does not
/// depend on the layout — a newer morbinit's marker must still be understood
/// by an older one.
///
/// Zero is deliberately not a version: it is what a torn write leaves behind
/// when the magic lands and the rest does not, so it reads as "not a marker".
const FORMAT_MARKER_VERSION: u8 = 1;

/// The marker occupies the device's first sector, zero-padded. A whole
/// sector rather than the nine bytes it needs, because a 512-byte aligned
/// write is the largest one the block layer will not tear.
const FORMAT_MARKER_SECTOR_LEN: usize = 512;

/// Whether `head` (the start of a device) carries the format-intent marker.
///
/// Requires the full magic *and* a nonzero version byte behind it. Being
/// strict matters in one direction only: this predicate hands out a licence
/// to run `mkfs`, so a torn or coincidental partial match must read as "not
/// a marker" and leave the device alone.
pub fn has_format_marker(head: &[u8]) -> bool {
    head.len() > FORMAT_MARKER_MAGIC.len()
        && head.starts_with(FORMAT_MARKER_MAGIC)
        && head[FORMAT_MARKER_MAGIC.len()] != 0
}

/// The exact bytes of a format-intent marker sector.
fn format_marker_sector() -> [u8; FORMAT_MARKER_SECTOR_LEN] {
    let mut sector = [0u8; FORMAT_MARKER_SECTOR_LEN];
    sector[..FORMAT_MARKER_MAGIC.len()].copy_from_slice(FORMAT_MARKER_MAGIC);
    sector[FORMAT_MARKER_MAGIC.len()] = FORMAT_MARKER_VERSION;
    sector
}

/// Stamp the format-intent marker onto `path` and get it onto the platter
/// before anything else happens.
///
/// Ordering is the whole point: this must be durable *before* `mkfs` starts,
/// or a crash in the window between them leaves exactly the unrecoverable
/// state the marker exists to prevent. Hence `sync_all` (and, on Linux, a
/// global `sync(2)`) rather than trusting the page cache.
///
/// Only ever called on a device `classify` just called `Blank`.
pub fn write_format_marker(path: &str) -> io::Result<()> {
    let mut file = std::fs::OpenOptions::new().write(true).open(path)?;
    file.write_all(&format_marker_sector())?;
    file.flush()?;
    file.sync_all()?;
    #[cfg(target_os = "linux")]
    crate::sys::sync();
    Ok(())
}

/// Whether `path` still carries the marker — i.e. whether the formatter
/// failed to overwrite the head of the device.
pub fn format_marker_present(path: &str) -> io::Result<bool> {
    let mut file = std::fs::File::open(path)?;
    let mut head = [0u8; FORMAT_MARKER_SECTOR_LEN];
    let n = read_head(&mut file, &mut head)?;
    Ok(has_format_marker(&head[..n]))
}

/// Zero the marker sector. Used only to clean up after a formatter that did
/// not overwrite the head of the device itself.
///
/// Safe for both filesystems we create: btrfs's superblock lives at 64 KiB
/// (and mkfs zeroes everything before it), ext4's at byte 1024 with the first
/// 1024 bytes reserved for a boot sector we do not have. Nothing we mount
/// keeps anything in sector 0.
pub fn clear_format_marker(path: &str) -> io::Result<()> {
    let mut file = std::fs::OpenOptions::new().write(true).open(path)?;
    file.write_all(&[0u8; FORMAT_MARKER_SECTOR_LEN])?;
    file.flush()?;
    file.sync_all()?;
    #[cfg(target_os = "linux")]
    crate::sys::sync();
    Ok(())
}

/// Fill as much of `head` as the device will give us, retrying short reads
/// and EINTR. Returns how many bytes were actually read: a device shorter
/// than a sector is legal here and simply cannot carry a marker.
fn read_head<R: Read>(r: &mut R, head: &mut [u8]) -> io::Result<usize> {
    let mut filled = 0usize;
    while filled < head.len() {
        match r.read(&mut head[filled..]) {
            Ok(0) => break,
            Ok(n) => filled += n,
            Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(filled)
}

/// What we concluded about the data disk before touching it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiskState {
    /// No such device node, or it could not be opened at all.
    Absent,
    /// Present and demonstrably empty — safe to `mkfs`.
    Blank,
    /// Present with *something* on it. Never formatted, only mounted.
    Formatted,
}

/// The filesystems morbinit knows how to create and mount, in preference
/// order (see `CANDIDATE_FILESYSTEMS`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FsKind {
    Btrfs,
    Ext4,
}

/// Preference order for both formatting a blank disk and probing an
/// existing one.
const CANDIDATE_FILESYSTEMS: &[FsKind] = &[FsKind::Btrfs, FsKind::Ext4];

impl FsKind {
    /// The name `mount(2)` wants.
    pub fn fstype(self) -> &'static str {
        match self {
            FsKind::Btrfs => "btrfs",
            FsKind::Ext4 => "ext4",
        }
    }

    /// The formatter binary, resolved off `GUEST_PATH` rather than
    /// hard-coded: the initramfs track decides where these land.
    pub fn mkfs_binary(self) -> &'static str {
        match self {
            FsKind::Btrfs => "mkfs.btrfs",
            FsKind::Ext4 => "mkfs.ext4",
        }
    }

    /// Arguments preceding the device.
    ///
    /// Both formatters get their "force" flag. We have already proven the
    /// device is blank for the first megabyte, but btrfs also keeps backup
    /// superblocks at 64 MiB and 256 GiB, and either tool will stop and ask
    /// for confirmation if it thinks it sees a remnant — and there is no one
    /// here to answer.
    pub fn mkfs_args(self) -> &'static [&'static str] {
        match self {
            FsKind::Btrfs => &["-f", "-L", "morbdata"],
            FsKind::Ext4 => &["-F", "-q", "-L", "morbdata"],
        }
    }

    /// Filesystem-specific mount options, or `None` for "kernel defaults".
    ///
    /// btrfs: `compress=zstd:1` (level 1 — the layer store is mostly
    /// already-compressed blobs, so a higher level costs CPU for very little
    /// space) and `discard=async`, which lets deletes propagate back to the
    /// sparse host image without stalling the filesystem.
    ///
    /// ext4 deliberately does **not** get a live `discard` mount option here
    /// (TECH-3/UX-16, `docs/design/DISK-RECLAIM-DECISION.md`). Both
    /// mechanisms were measured to work — a live `discard` mount reclaims
    /// per delete, `fstrim` reclaims in one bounded sweep — but continuous
    /// `discard` on ext4 issues a synchronous `FITRIM`-equivalent for every
    /// freed extent inline with the delete that freed it, which is exactly
    /// the well-known reason production Linux images (systemd's
    /// `fstrim.timer`, most cloud distro defaults) schedule `fstrim`
    /// periodically instead of mounting `discard` live: `docker system
    /// prune`, `docker rmi`, and ordinary layer-store GC are delete-heavy
    /// and latency-sensitive, and paying a TRIM round trip inline with every
    /// one of those deletes is a cost this guest does not need to take when
    /// a periodic sweep (`spawn_periodic_trim`, driven from `main.rs`)
    /// reclaims the same space in the background instead.
    pub fn mount_data(self) -> Option<&'static str> {
        match self {
            FsKind::Btrfs => Some("compress=zstd:1,discard=async"),
            FsKind::Ext4 => None,
        }
    }
}

/// Read up to `BLANK_PROBE_LEN` bytes from `r` and report whether every one
/// of them was zero.
///
/// A device we could not read a single byte from is reported as *not* blank:
/// "blank" is a licence to run `mkfs`, and we only issue it on positive
/// evidence.
pub fn probe_is_blank<R: Read>(r: &mut R) -> io::Result<bool> {
    let mut buf = vec![0u8; PROBE_CHUNK_LEN];
    let mut total = 0usize;
    while total < BLANK_PROBE_LEN {
        let want = std::cmp::min(buf.len(), BLANK_PROBE_LEN - total);
        match r.read(&mut buf[..want]) {
            Ok(0) => break, // device shorter than the probe window
            Ok(n) => {
                if buf[..n].iter().any(|&b| b != 0) {
                    return Ok(false);
                }
                total += n;
            }
            Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(total > 0)
}

/// Decide what to do with `path` without modifying it.
///
/// Every failure mode resolves *away* from formatting: a device we cannot
/// open is `Absent`, and a device we cannot read is `Formatted` (i.e. hands
/// off), because an I/O error is not evidence of emptiness.
///
/// The one exception is the format-intent marker, which is positive evidence
/// pointing the other way — see the module docs.
pub fn classify(path: &str) -> DiskState {
    if !Path::new(path).exists() {
        return DiskState::Absent;
    }
    let mut file = match std::fs::File::open(path) {
        Ok(f) => f,
        Err(e) => {
            log::log(&format!(
                "{} exists but could not be opened: {} — treating it as absent",
                path, e
            ));
            return DiskState::Absent;
        }
    };

    // Before the blank probe, because a crashed format is precisely the case
    // where the device is *not* blank and must be formatted anyway.
    let mut head = [0u8; FORMAT_MARKER_SECTOR_LEN];
    match read_head(&mut file, &mut head) {
        Ok(n) if has_format_marker(&head[..n]) => {
            log::log(&format!(
                "{} carries morbinit's format-intent marker (version {}) — a previous \
                 boot was interrupted mid-mkfs, so whatever is on the device is our \
                 own half-written filesystem. Treating it as blank and formatting it \
                 again.",
                path,
                head[FORMAT_MARKER_MAGIC.len()]
            ));
            return DiskState::Blank;
        }
        Ok(_) => {}
        Err(e) => {
            log::log(&format!(
                "WARNING: could not read the first sector of {}: {} — assuming it \
                 holds data and refusing to format it",
                path, e
            ));
            return DiskState::Formatted;
        }
    }

    // Rewind: the blank probe reads the same window from byte 0.
    if let Err(e) = file.seek(SeekFrom::Start(0)) {
        log::log(&format!(
            "WARNING: could not rewind {} after reading its first sector: {} — \
             assuming it holds data and refusing to format it",
            path, e
        ));
        return DiskState::Formatted;
    }

    match probe_is_blank(&mut file) {
        Ok(true) => DiskState::Blank,
        Ok(false) => DiskState::Formatted,
        Err(e) => {
            log::log(&format!(
                "WARNING: could not read the first {} bytes of {}: {} — assuming it \
                 holds data and refusing to format it",
                BLANK_PROBE_LEN, path, e
            ));
            DiskState::Formatted
        }
    }
}

/// Look `name` up in a colon-separated search path, returning the first
/// entry that exists. Split from `which` so it can be unit tested against
/// directories that actually exist on the dev host.
pub fn which_in(search_path: &str, name: &str) -> Option<PathBuf> {
    search_path
        .split(':')
        .filter(|dir| !dir.is_empty())
        .map(|dir| Path::new(dir).join(name))
        .find(|candidate| candidate.exists())
}

/// Resolve `name` against the same `PATH` the supervised services get, so
/// morbinit and dockerd always agree about which binaries the guest has.
pub fn which(name: &str) -> Option<PathBuf> {
    which_in(crate::supervisor::GUEST_PATH, name)
}

/// Where the kernel lists the filesystems it can actually mount.
const PROC_FILESYSTEMS: &str = "/proc/filesystems";

/// Whether `fstype` appears in the contents of `/proc/filesystems`.
///
/// Format is one filesystem per line, optionally prefixed with the literal
/// `nodev` and whitespace (`nodev` marks filesystems that do not need a block
/// device — tmpfs, proc, overlay). We want a match either way: the prefix says
/// nothing about whether the kernel supports the type, only about how it is
/// mounted. Taking the last whitespace-separated column handles both shapes.
/// Split out from ``kernel_supports`` so it can be unit tested off a Linux host.
pub fn proc_filesystems_lists(contents: &str, fstype: &str) -> bool {
    contents
        .lines()
        .filter_map(|line| line.split_whitespace().next_back())
        .any(|name| name == fstype)
}

// ---------------------------------------------------------------------------
// Everything below issues mount(2) / runs mkfs, so it is Linux-only.
// ---------------------------------------------------------------------------

/// Whether the running kernel can mount `fstype` at all.
///
/// The guest kernel is monolithic — kata ships no loadable modules — so
/// `/proc/filesystems` is the complete and final list, not a snapshot of what
/// happens to be loaded. Checking it before choosing a formatter is the
/// difference between picking a filesystem and picking a filesystem we can
/// use: `mkfs.btrfs` will happily write a perfect btrfs onto a disk this
/// kernel then refuses to mount with ENODEV, which costs a full-device TRIM
/// (~1.5s on a 64 GiB image, on the very first boot of every fresh install)
/// and a scary warning on the way to the ext4 fallback that was always the
/// only real option.
///
/// Unreadable `/proc/filesystems` answers `true` for everything: an unexpected
/// environment must not be able to silently disable persistence, and the mount
/// attempt itself is the real test either way.
#[cfg(target_os = "linux")]
fn kernel_supports(fstype: &str) -> bool {
    match std::fs::read_to_string(PROC_FILESYSTEMS) {
        Ok(contents) => proc_filesystems_lists(&contents, fstype),
        Err(e) => {
            log::log(&format!(
                "could not read {} ({}) — assuming the kernel supports {}",
                PROC_FILESYSTEMS, e, fstype
            ));
            true
        }
    }
}

/// Prepare `/var/lib/docker` and report whether it ended up on the real
/// disk (which is what decides `overlay2` vs `vfs`, and what the MRB0 `info`
/// reply exposes as `docker_data_on_disk`).
///
/// Called during the single-threaded part of boot, before the supervisor's
/// `waitpid(-1)` reaper exists — so the `mkfs` child cannot be stolen by the
/// reaper and `Command::status()` is safe here.
#[cfg(target_os = "linux")]
pub fn provision() -> bool {
    if let Err(e) = std::fs::create_dir_all(DOCKER_DATA_ROOT) {
        log::log(&format!("mkdir -p {} failed: {}", DOCKER_DATA_ROOT, e));
    }

    let on_disk = match classify(DATA_DISK) {
        DiskState::Absent => {
            log::log(&format!(
                "{} is not present — {} will be RAM-backed",
                DATA_DISK, DOCKER_DATA_ROOT
            ));
            false
        }
        DiskState::Blank => {
            // Two ways to get here — an untouched image, or one carrying our
            // format-intent marker — and `classify` has already said which in
            // the log, so this line must not claim the first.
            log::log(&format!(
                "{} holds nothing that must be preserved (its first {} bytes read \
                 back blank, or it carries a crashed-format marker — see above) — \
                 formatting it",
                DATA_DISK, BLANK_PROBE_LEN
            ));
            format_and_mount()
        }
        DiskState::Formatted => {
            log::log(&format!(
                "{} already holds data — mounting as-is",
                DATA_DISK
            ));
            mount_existing()
        }
    };

    if !on_disk {
        tmpfs_fallback();
    }
    on_disk
}

/// Format a known-blank disk and mount it. Returns whether
/// `/var/lib/docker` is now on the disk.
///
/// Each candidate filesystem is tried in turn rather than committing to the
/// first one whose formatter exists: `mkfs.btrfs` refuses devices below
/// roughly 110 MiB, so on a small disk image btrfs is present, fails, and
/// ext4 is the right answer. Falling all the way back to RAM there would
/// throw away persistence over a recoverable error.
///
/// Retrying is only safe because we established the device is blank — every
/// attempt here overwrites nothing but our own previous attempt.
#[cfg(target_os = "linux")]
fn format_and_mount() -> bool {
    let mut attempted = false;

    for kind in CANDIDATE_FILESYSTEMS {
        if !kernel_supports(kind.fstype()) {
            log::log(&format!(
                "kernel has no {} support — skipping it",
                kind.fstype()
            ));
            continue;
        }

        let Some(mkfs_bin) = which(kind.mkfs_binary()) else {
            log::log(&format!(
                "{} is not on {} — skipping {}",
                kind.mkfs_binary(),
                crate::supervisor::GUEST_PATH,
                kind.fstype()
            ));
            continue;
        };
        attempted = true;

        log::log(&format!(
            "formatting {} as {} using {}",
            DATA_DISK,
            kind.fstype(),
            mkfs_bin.display()
        ));
        // Announce the intent *before* the formatter runs, so a crash in the
        // middle of it leaves evidence a later boot can act on instead of a
        // device that looks like unreadable user data forever. Best effort:
        // failing to write the marker is a reason to lose the safety net, not
        // a reason to lose persistence.
        if let Err(e) = write_format_marker(DATA_DISK) {
            log::log(&format!(
                "WARNING: could not write the format-intent marker to {}: {} — \
                 formatting anyway, but an interrupted mkfs will not be recoverable \
                 automatically",
                DATA_DISK, e
            ));
        }
        if !run_mkfs(&mkfs_bin, *kind) {
            continue;
        }
        if !marker_cleared_after_mkfs(*kind) {
            continue;
        }

        match mount_fs(*kind) {
            Ok(()) => return true,
            Err(e) => log::log(&format!(
                "WARNING: freshly formatted {} would not mount as {}: {}",
                DATA_DISK,
                kind.fstype(),
                e
            )),
        }
    }

    if !attempted {
        log::log(&format!(
            "WARNING: no filesystem formatter found on {} — cannot format {}",
            crate::supervisor::GUEST_PATH,
            DATA_DISK
        ));
    }
    log::log(&format!(
        "WARNING: could not put {} on {} — falling back to RAM-backed storage, so \
         images pulled in this boot will not persist",
        DOCKER_DATA_ROOT, DATA_DISK
    ));
    false
}

/// Make sure the format-intent marker is gone now that the formatter has
/// succeeded, clearing it ourselves if the formatter left it. Returns whether
/// the device is safe to start using.
///
/// Belt and braces: both formatters wipe the head of the device (mke2fs zaps
/// the first sectors, mkfs.btrfs zeroes everything up to its 64 KiB
/// superblock), so this should always find the marker already gone. It
/// matters because a marker that survives onto a disk we then fill with the
/// user's images would make the *next* boot classify that disk as a crashed
/// format and reformat it — turning a safety net into the data loss it was
/// meant to prevent. If we cannot guarantee the marker is gone, we refuse the
/// disk instead: a boot on RAM-backed storage is recoverable, a wiped layer
/// store is not.
#[cfg(target_os = "linux")]
fn marker_cleared_after_mkfs(kind: FsKind) -> bool {
    match format_marker_present(DATA_DISK) {
        Ok(false) => return true,
        Ok(true) => log::log(&format!(
            "{} left morbinit's format-intent marker on {} — clearing it",
            kind.mkfs_binary(),
            DATA_DISK
        )),
        Err(e) => {
            log::log(&format!(
                "WARNING: could not re-read the first sector of {} after {}: {} — \
                 refusing to use the disk rather than risk a later boot mistaking a \
                 live layer store for a crashed format",
                DATA_DISK,
                kind.mkfs_binary(),
                e
            ));
            return false;
        }
    }

    if let Err(e) = clear_format_marker(DATA_DISK) {
        log::log(&format!(
            "WARNING: could not clear the format-intent marker on {}: {} — refusing \
             to use the disk, because a later boot would read the marker and \
             reformat it",
            DATA_DISK, e
        ));
        return false;
    }
    true
}

/// Run the formatter. Returns true only on a clean exit status.
#[cfg(target_os = "linux")]
fn run_mkfs(mkfs_bin: &Path, kind: FsKind) -> bool {
    use std::process::{Command, Stdio};

    let status = Command::new(mkfs_bin)
        .args(kind.mkfs_args())
        .arg(DATA_DISK)
        .env("PATH", crate::supervisor::GUEST_PATH)
        // No tty in the guest, and a formatter that decides to ask a
        // question must get EOF rather than block boot forever.
        .stdin(Stdio::null())
        .status();

    match status {
        Ok(s) if s.success() => {
            log::log(&format!("{} on {} — ok", kind.mkfs_binary(), DATA_DISK));
            true
        }
        Ok(s) => {
            log::log(&format!(
                "WARNING: {} on {} failed ({})",
                kind.mkfs_binary(),
                DATA_DISK,
                s
            ));
            false
        }
        Err(e) => {
            log::log(&format!(
                "WARNING: could not run {}: {}",
                mkfs_bin.display(),
                e
            ));
            false
        }
    }
}

/// Mount a disk that already has data on it, trying each filesystem we know.
///
/// Nothing in here formats anything, and nothing may be added that does:
/// reaching this function means the device holds bytes we did not write.
#[cfg(target_os = "linux")]
fn mount_existing() -> bool {
    let mut failures = Vec::new();
    for kind in CANDIDATE_FILESYSTEMS {
        match mount_fs(*kind) {
            Ok(()) => return true,
            Err(e) => failures.push(format!("{}: {}", kind.fstype(), e)),
        }
    }

    // Loud on purpose. This is the state where a user's pulled images exist
    // but are unreachable, and the only correct response is to leave them
    // alone and say so — a `mkfs` here would "fix" the boot by deleting
    // everything the disk was for.
    log::log(&format!(
        "WARNING: {} HAS DATA ON IT BUT WOULD NOT MOUNT ({}). NOT reformatting — \
         the existing contents are being preserved. This boot falls back to \
         RAM-backed storage, so images pulled now will not persist.",
        DATA_DISK,
        failures.join("; ")
    ));
    false
}

#[cfg(target_os = "linux")]
fn mount_fs(kind: FsKind) -> io::Result<()> {
    crate::sys::mount_with_data(
        DATA_DISK,
        DOCKER_DATA_ROOT,
        kind.fstype(),
        0,
        kind.mount_data(),
    )?;
    log::log(&format!(
        "mounted {} ({}{}) at {}",
        DATA_DISK,
        kind.fstype(),
        kind.mount_data()
            .map(|d| format!(",{}", d))
            .unwrap_or_default(),
        DOCKER_DATA_ROOT
    ));
    Ok(())
}

/// Last resort: a tmpfs at `/var/lib/docker`.
///
/// Better than leaving docker's data root on the bare initramfs, which is
/// `rootfs` (a ramfs): it has no size limit and its pages are never
/// reclaimable, so a large `docker pull` there grows until the guest OOMs.
/// tmpfs defaults to half of RAM and can be swapped, so the same pull fails
/// cleanly with ENOSPC instead.
#[cfg(target_os = "linux")]
fn tmpfs_fallback() {
    match crate::sys::mount("tmpfs", DOCKER_DATA_ROOT, "tmpfs", crate::sys::MS_NOSUID) {
        Ok(()) => log::log(&format!(
            "mounted tmpfs at {} (docker data will NOT persist across restarts)",
            DOCKER_DATA_ROOT
        )),
        Err(e) if e.raw_os_error() == Some(crate::sys::EBUSY) => {
            log::log(&format!("{} is already mounted (EBUSY)", DOCKER_DATA_ROOT));
        }
        Err(e) => log::log(&format!(
            "WARNING: tmpfs mount at {} failed: {} — falling back to the initramfs \
             rootfs, which is unbounded and unswappable",
            DOCKER_DATA_ROOT, e
        )),
    }
}

/// Get the layer store onto stable storage before the machine loses power.
///
/// Called on shutdown *after* the services have stopped, so nothing is
/// writing any more. Unmounting outright is the strongest guarantee; if the
/// kernel says the mount is busy (a leftover container mount, a stray fd) we
/// settle for a read-only remount, which still forces a full writeback, and
/// then a lazy detach. `sync(2)` brackets the whole thing so we flush
/// something useful even in the worst case.
#[cfg(target_os = "linux")]
pub fn flush_docker_data(on_disk: bool) {
    crate::sys::sync();
    if !on_disk {
        // Nothing durable to protect — the sync above is enough.
        return;
    }

    match crate::sys::umount2(DOCKER_DATA_ROOT, 0) {
        Ok(()) => {
            log::log(&format!("unmounted {}", DOCKER_DATA_ROOT));
            crate::sys::sync();
            return;
        }
        Err(e) => log::log(&format!(
            "could not unmount {}: {} — remounting read-only instead",
            DOCKER_DATA_ROOT, e
        )),
    }

    match crate::sys::remount_readonly(DOCKER_DATA_ROOT) {
        Ok(()) => log::log(&format!("remounted {} read-only", DOCKER_DATA_ROOT)),
        Err(e) => log::log(&format!(
            "WARNING: could not remount {} read-only either: {} — relying on sync(2) \
             alone",
            DOCKER_DATA_ROOT, e
        )),
    }

    // Detach lazily so the block device stops taking writes even if some
    // reference is still open somewhere.
    if let Err(e) = crate::sys::umount2(DOCKER_DATA_ROOT, crate::sys::MNT_DETACH) {
        log::log(&format!(
            "lazy unmount of {} failed: {}",
            DOCKER_DATA_ROOT, e
        ));
    }
    crate::sys::sync();
}

// ---------------------------------------------------------------------------
// Periodic trim (TECH-3 / UX-16): the reclaim half of disk space, run from a
// background thread rather than a live `discard` mount — see the reasoning
// on `FsKind::mount_data`.
// ---------------------------------------------------------------------------

/// How long to wait after boot before the very first sweep. `fstrim` is a
/// whole-filesystem scan that costs real I/O while it runs (measured:
/// `docs/design/DISK-RECLAIM-DECISION.md` §4 step 8 swept ~9.3 GiB in one
/// pass); running it immediately at boot would compete with the image pulls
/// and container starts a fresh VM is normally used for in its first minute.
const TRIM_WARMUP_DELAY: std::time::Duration = std::time::Duration::from_secs(10 * 60);

/// Steady-state interval between sweeps. Deliberately much slower than a
/// delete-driven trigger: `fstrim` reclaims whatever has accumulated since
/// the last sweep regardless of how long that took to build up, so there is
/// nothing to gain from checking more often than a user could plausibly
/// notice disk pressure changing, and real cost (I/O contention with
/// whatever the guest is doing) to checking more often than that.
const TRIM_INTERVAL: std::time::Duration = std::time::Duration::from_secs(60 * 60);

/// Sentinel `disk_last_trim_bytes` value meaning "no sweep has completed yet
/// this boot" — collapsed to `nil` by the host's `GuestReply` decoder, same
/// convention as ``mem_total_kb``/``mem_available_kb``. A real `fstrim`
/// result is always `>= 0`.
pub const NO_TRIM_YET: i64 = -1;

/// Parses the byte count out of `fstrim -v`'s one line of output.
///
/// util-linux has shipped two shapes across versions actually seen in the
/// wild:
///   - `"/var/lib/docker: 59050795008 bytes trimmed"` (older / busybox-style)
///   - `"/var/lib/docker: 55 GiB (59050795008 bytes) trimmed on /dev/vda"` (2.36+)
///
/// Rather than special-case either shape, this looks for a run of ASCII
/// digits immediately followed by `" bytes"` — inside parentheses or not —
/// and takes the *last* such match on the line, since the parenthesized
/// exact-byte figure (when present) always follows the rounded human-readable
/// one. Pure and portable so it is testable without a Linux host or a real
/// `fstrim` binary.
pub fn parse_fstrim_trimmed_bytes(output: &str) -> Option<i64> {
    let line = output.lines().find(|line| line.contains(" bytes"))?;
    // Operates on bytes throughout, never on a `&str` slice at an
    // arbitrary offset: a digit run is always pure ASCII and therefore a
    // valid UTF-8 boundary on both ends, but the *suffix* check below must
    // not risk slicing `line` mid-codepoint if the line ever contains
    // non-ASCII (a locale-dependent `fstrim` message, for instance). This is
    // local subprocess output, not peer input, but a background thread
    // panicking is still worse than silently reporting "no trim result".
    let bytes = line.as_bytes();
    let mut best: Option<i64> = None;
    let mut index = 0usize;
    while index < bytes.len() {
        if !bytes[index].is_ascii_digit() {
            index += 1;
            continue;
        }
        let start = index;
        while index < bytes.len() && bytes[index].is_ascii_digit() {
            index += 1;
        }
        if bytes[index..].starts_with(b" bytes") {
            // `start..index` is a contiguous run of ASCII digit bytes, so this
            // is always valid UTF-8 — the `unwrap` cannot fail.
            if let Ok(value) = std::str::from_utf8(&bytes[start..index])
                .unwrap()
                .parse::<i64>()
            {
                best = Some(value);
            }
        }
    }
    best
}

/// Runs one `fstrim` sweep of `DOCKER_DATA_ROOT` and returns the bytes it
/// reported reclaiming, or `None` on any failure (missing binary, a
/// filesystem that does not support `FITRIM`, a nonzero exit, unparseable
/// output) — every failure is logged but never fatal, matching every other
/// best-effort step in this module.
#[cfg(target_os = "linux")]
fn run_fstrim() -> Option<i64> {
    use std::process::{Command, Stdio};

    let Some(binary) = which("fstrim") else {
        log::log("fstrim is not on GUEST_PATH — skipping the periodic trim sweep");
        return None;
    };
    let output = match Command::new(&binary)
        .args(["-v", DOCKER_DATA_ROOT])
        .env("PATH", crate::supervisor::GUEST_PATH)
        .stdin(Stdio::null())
        .output()
    {
        Ok(output) => output,
        Err(e) => {
            log::log(&format!("could not run fstrim: {}", e));
            return None;
        }
    };
    if !output.status.success() {
        log::log(&format!(
            "fstrim {} exited with {} ({})",
            DOCKER_DATA_ROOT,
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        ));
        return None;
    }
    let text = String::from_utf8_lossy(&output.stdout);
    match parse_fstrim_trimmed_bytes(&text) {
        Some(bytes) => {
            log::log(&format!(
                "fstrim {}: {} bytes trimmed",
                DOCKER_DATA_ROOT, bytes
            ));
            Some(bytes)
        }
        None => {
            log::log(&format!(
                "fstrim {} succeeded but its output could not be parsed: {:?}",
                DOCKER_DATA_ROOT,
                text.trim()
            ));
            None
        }
    }
}

/// Starts the background sweep thread. A no-op when `/var/lib/docker` is not
/// on the real disk (`on_disk == false`, i.e. the tmpfs fallback): trimming a
/// tmpfs is meaningless, and there is no `disk.img` on the host for the
/// reclaim to matter to.
///
/// `last_trim_bytes` is shared with `ControlContext` so `info` replies can
/// report the most recent sweep's result without this thread needing any
/// awareness of the control protocol.
#[cfg(target_os = "linux")]
pub fn spawn_periodic_trim(on_disk: bool, last_trim_bytes: std::sync::Arc<AtomicI64>) {
    if !on_disk {
        return;
    }
    let spawned = std::thread::Builder::new()
        .name("disk-trim".to_string())
        .spawn(move || {
            std::thread::sleep(TRIM_WARMUP_DELAY);
            loop {
                if let Some(bytes) = run_fstrim() {
                    last_trim_bytes.store(bytes, Ordering::SeqCst);
                }
                std::thread::sleep(TRIM_INTERVAL);
            }
        });
    if let Err(e) = spawned {
        log::log(&format!(
            "WARNING: could not start the periodic disk-trim thread: {} — deleted \
             images and containers will not return space to the Mac until the next \
             restart",
            e
        ));
    }
}

// ---------------------------------------------------------------------------
// Explicit grow-only transaction (Linux guest only)
// ---------------------------------------------------------------------------

/// The relevant entry from `/proc/mounts`, reduced to the identity facts a disk
/// growth operation must check before executing any filesystem tool.
#[derive(Debug, Clone, PartialEq, Eq)]
struct MountedFilesystem {
    source: String,
    mount_point: String,
    filesystem: String,
}

/// Decodes Linux's octal escaping in `/proc/mounts` (for example `\\040` for a
/// space). We do not accept a malformed escape as an equivalent path: a grow action
/// is authorised for one literal mount point, so ambiguity fails closed.
fn decode_mount_field(input: &str) -> Option<String> {
    let mut out = String::with_capacity(input.len());
    let bytes = input.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] != b'\\' {
            out.push(bytes[index] as char);
            index += 1;
            continue;
        }
        if index + 3 >= bytes.len()
            || !bytes[index + 1..index + 4]
                .iter()
                .all(|byte| (b'0'..=b'7').contains(byte))
        {
            return None;
        }
        // Widened deliberately: three octal digits reach 0o777 = 511, which does
        // not fit in a `u8`. The kernel only ever emits `\040`, `\011`, `\012`
        // and `\134`, so this is unreachable from a real `/proc/mounts` — but the
        // arithmetic would wrap in the shipped release build (overflow checks
        // off) and abort PID 1 in a checked one, and neither is an acceptable
        // response to a byte sequence this function's whole job is to survive.
        let value = u16::from(bytes[index + 1] - b'0') * 64
            + u16::from(bytes[index + 2] - b'0') * 8
            + u16::from(bytes[index + 3] - b'0');
        let byte = u8::try_from(value).ok()?;
        out.push(byte as char);
        index += 4;
    }
    Some(out)
}

/// Locates the exact mounted filesystem at `/var/lib/docker`; never picks an
/// ancestor, a bind mount, or a similarly named path.
fn mounted_data_filesystem(mounts: &str) -> Option<MountedFilesystem> {
    for line in mounts.lines() {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() < 3 {
            continue;
        }
        let source = decode_mount_field(fields[0])?;
        let mount_point = decode_mount_field(fields[1])?;
        let filesystem = decode_mount_field(fields[2])?;
        if mount_point == DOCKER_DATA_ROOT {
            return Some(MountedFilesystem {
                source,
                mount_point,
                filesystem,
            });
        }
    }
    None
}

/// Parses the POSIX `df -Pk` capacity column (1024-byte blocks) into bytes.
/// Split from command execution because output handling is part of the safety proof
/// and deserves portable tests.
fn parse_df_capacity_bytes(output: &str) -> Option<i64> {
    let line = output
        .lines()
        .skip(1)
        .find(|line| !line.trim().is_empty())?;
    let fields: Vec<&str> = line.split_whitespace().collect();
    let kibibytes = fields.get(1)?.parse::<i64>().ok()?;
    kibibytes.checked_mul(1024).filter(|value| *value > 0)
}

/// Guest-side durable acknowledgement of a successful grow. The host retains the
/// authoritative transaction journal; this tiny receipt exists only to make that
/// journal recoverable if the guest completed its filesystem operation and the host
/// crashed before it could persist the returned proof.
#[cfg(target_os = "linux")]
const GROW_RECEIPT_DIRECTORY: &str = "/var/lib/docker/.morbstack";
#[cfg(target_os = "linux")]
const GROW_RECEIPT_PATH: &str = "/var/lib/docker/.morbstack/disk-grow-v1";

#[cfg(target_os = "linux")]
#[derive(Debug, Clone, PartialEq, Eq)]
struct GrowReceipt {
    phase: GrowReceiptPhase,
    target_bytes: i64,
    filesystem: String,
    device_bytes: i64,
    before_filesystem_bytes: i64,
    after_filesystem_bytes: i64,
}

/// The receipt is a tiny write-ahead log rather than merely a completion marker.
/// If PID 1 crashes after `resize2fs` succeeds but before it can record its reply,
/// the durable `prepared` capacity lets the next boot prove that the filesystem did
/// in fact become larger. Without that intent record, a retry would see an already
/// grown filesystem and have no sound way to distinguish it from an unrelated state.
#[cfg(target_os = "linux")]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum GrowReceiptPhase {
    Prepared,
    Completed,
}

#[cfg(target_os = "linux")]
impl GrowReceiptPhase {
    fn token(self) -> &'static str {
        match self {
            Self::Prepared => "prepared",
            Self::Completed => "completed",
        }
    }

    fn parse(value: &str) -> Option<Self> {
        match value {
            "prepared" => Some(Self::Prepared),
            "completed" => Some(Self::Completed),
            _ => None,
        }
    }
}

#[cfg(target_os = "linux")]
fn load_grow_receipt() -> Option<GrowReceipt> {
    let text = std::fs::read_to_string(GROW_RECEIPT_PATH).ok()?;
    let fields: Vec<&str> = text.split_whitespace().collect();
    if fields.len() != 7 || fields[0] != "MRBDISKGROW2" {
        return None;
    }
    let phase = GrowReceiptPhase::parse(fields[1])?;
    let target_bytes = fields[2].parse().ok()?;
    let device_bytes = fields[4].parse().ok()?;
    let before_filesystem_bytes = fields[5].parse().ok()?;
    let after_filesystem_bytes = fields[6].parse().ok()?;
    if target_bytes <= 0
        || device_bytes <= 0
        || before_filesystem_bytes <= 0
        || after_filesystem_bytes < before_filesystem_bytes
    {
        return None;
    }
    Some(GrowReceipt {
        phase,
        target_bytes,
        filesystem: fields[3].to_string(),
        device_bytes,
        before_filesystem_bytes,
        after_filesystem_bytes,
    })
}

#[cfg(target_os = "linux")]
fn store_grow_receipt(receipt: &GrowReceipt) -> Result<(), String> {
    use std::fs::{self, File, OpenOptions};
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;

    fs::create_dir_all(GROW_RECEIPT_DIRECTORY)
        .map_err(|e| format!("could not create disk-grow receipt directory: {}", e))?;
    // `create_new` refuses an attacker-controlled final name, while a PID-specific
    // temporary avoids ever following or truncating a stale `.tmp` from a crash.
    // `rename` replaces the final receipt atomically rather than following a link.
    let temporary = format!("{}.tmp.{}", GROW_RECEIPT_PATH, std::process::id());
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)
        .map_err(|e| format!("could not create disk-grow receipt: {}", e))?;
    writeln!(
        file,
        "MRBDISKGROW2 {} {} {} {} {} {}",
        receipt.phase.token(),
        receipt.target_bytes,
        receipt.filesystem,
        receipt.device_bytes,
        receipt.before_filesystem_bytes,
        receipt.after_filesystem_bytes,
    )
    .map_err(|e| format!("could not write disk-grow receipt: {}", e))?;
    file.sync_all()
        .map_err(|e| format!("could not sync disk-grow receipt: {}", e))?;
    fs::rename(&temporary, GROW_RECEIPT_PATH)
        .map_err(|e| format!("could not install disk-grow receipt: {}", e))?;
    File::open(GROW_RECEIPT_DIRECTORY)
        .and_then(|directory| directory.sync_all())
        .map_err(|e| format!("could not sync disk-grow receipt directory: {}", e))
}

#[cfg(target_os = "linux")]
fn block_device_bytes() -> Result<i64, String> {
    let sectors = std::fs::read_to_string("/sys/class/block/vda/size")
        .map_err(|e| format!("could not read /sys/class/block/vda/size: {}", e))?
        .trim()
        .parse::<i64>()
        .map_err(|e| format!("could not parse /sys/class/block/vda/size: {}", e))?;
    sectors
        .checked_mul(512)
        .filter(|value| *value > 0)
        .ok_or_else(|| "invalid /dev/vda capacity from sysfs".to_string())
}

#[cfg(target_os = "linux")]
fn filesystem_capacity_bytes() -> Result<i64, String> {
    use std::process::{Command, Stdio};

    let output = Command::new("df")
        .args(["-Pk", DOCKER_DATA_ROOT])
        .env("PATH", crate::supervisor::GUEST_PATH)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("could not execute df for {}: {}", DOCKER_DATA_ROOT, e))?;
    if !output.status.success() {
        return Err(format!(
            "df for {} failed ({})",
            DOCKER_DATA_ROOT, output.status
        ));
    }
    let text =
        String::from_utf8(output.stdout).map_err(|_| "df returned non-UTF-8 output".to_string())?;
    parse_df_capacity_bytes(&text)
        .ok_or_else(|| format!("could not parse df capacity for {}", DOCKER_DATA_ROOT))
}

#[cfg(target_os = "linux")]
fn run_filesystem_grow(filesystem: &str) -> Result<(), String> {
    use std::process::{Command, Stdio};

    let mut command = match filesystem {
        "ext4" => {
            let binary = which("resize2fs")
                .ok_or_else(|| "resize2fs is not available in this guest".to_string())?;
            let mut command = Command::new(binary);
            command.arg(DATA_DISK);
            command
        }
        "btrfs" => {
            let binary =
                which("btrfs").ok_or_else(|| "btrfs is not available in this guest".to_string())?;
            let mut command = Command::new(binary);
            command.args(["filesystem", "resize", "max", DOCKER_DATA_ROOT]);
            command
        }
        other => return Err(format!("unsupported mounted filesystem {}", other)),
    };
    let status = command
        .env("PATH", crate::supervisor::GUEST_PATH)
        .stdin(Stdio::null())
        .status()
        .map_err(|e| format!("could not start filesystem grow tool: {}", e))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("filesystem grow tool exited with {}", status))
    }
}

/// Performs the guest half of Morbstack's explicit disk-growth transaction.
///
/// The host first proves the VM is stopped, then journals and extends its RAW image.
/// This function refuses to act unless the *running guest* now sees precisely that
/// target on `/dev/vda`, and unless `/var/lib/docker` is mounted directly from that
/// device as ext4 or btrfs. It captures capacity before and after the filesystem tool
/// so the host receives evidence of the actual result rather than a success-shaped
/// promise. This may safely report `resized: false` on a journal-recovery retry only
/// when the guest has a durable receipt from the earlier successful grow.
#[cfg(target_os = "linux")]
pub fn grow_mounted_data(target_bytes: i64) -> Result<ResizeProof, String> {
    if target_bytes <= 0 {
        return Err("disk_resize requires a positive target_bytes".to_string());
    }
    let _guard = DISK_GROW_LOCK
        .lock()
        .map_err(|_| "disk resize lock was poisoned".to_string())?;

    let mounts = std::fs::read_to_string("/proc/mounts")
        .map_err(|e| format!("could not read /proc/mounts: {}", e))?;
    let mounted = mounted_data_filesystem(&mounts)
        .ok_or_else(|| format!("{} is not mounted", DOCKER_DATA_ROOT))?;
    if mounted.source != DATA_DISK {
        return Err(format!(
            "{} is mounted from {}, not {}; refusing resize",
            DOCKER_DATA_ROOT, mounted.source, DATA_DISK
        ));
    }
    if mounted.filesystem != "ext4" && mounted.filesystem != "btrfs" {
        return Err(format!(
            "{} uses {}, not an expandable Morbstack filesystem",
            DOCKER_DATA_ROOT, mounted.filesystem
        ));
    }

    let device_bytes = block_device_bytes()?;
    if device_bytes != target_bytes {
        return Err(format!(
            "{} reports {} bytes, but host authorised {} bytes",
            DATA_DISK, device_bytes, target_bytes
        ));
    }
    let before = filesystem_capacity_bytes()?;
    let prior_receipt = load_grow_receipt();
    if let Some(receipt) = prior_receipt.as_ref() {
        if receipt.target_bytes == target_bytes
            && receipt.filesystem == mounted.filesystem
            && receipt.device_bytes == device_bytes
        {
            let was_completed = receipt.phase == GrowReceiptPhase::Completed
                && before >= receipt.after_filesystem_bytes;
            let grew_after_preparation = before > receipt.before_filesystem_bytes;
            if was_completed || grew_after_preparation {
                // If an earlier host crash cut off the MRB0 reply, a prepared receipt
                // plus a strictly larger measured filesystem is the durable proof.
                // Promote it before replying so another crash remains recoverable.
                if !was_completed {
                    store_grow_receipt(&GrowReceipt {
                        phase: GrowReceiptPhase::Completed,
                        target_bytes,
                        filesystem: mounted.filesystem.clone(),
                        device_bytes,
                        before_filesystem_bytes: receipt.before_filesystem_bytes,
                        after_filesystem_bytes: before,
                    })?;
                }
                return Ok(ResizeProof {
                    device: mounted.source,
                    mount_point: mounted.mount_point,
                    filesystem: mounted.filesystem,
                    device_bytes,
                    before_filesystem_bytes: before,
                    after_filesystem_bytes: before,
                    resized: false,
                    previously_proved: true,
                });
            }
        }
    }
    // This receipt is the guest's write-ahead record. It must reach stable storage
    // before the filesystem tool runs, otherwise a post-tool crash would leave no
    // recoverable proof that the capacity transition occurred.
    store_grow_receipt(&GrowReceipt {
        phase: GrowReceiptPhase::Prepared,
        target_bytes,
        filesystem: mounted.filesystem.clone(),
        device_bytes,
        before_filesystem_bytes: before,
        after_filesystem_bytes: before,
    })?;
    run_filesystem_grow(&mounted.filesystem)?;
    let after = filesystem_capacity_bytes()?;
    if after < before {
        return Err(format!(
            "filesystem capacity fell from {} to {} bytes after resize; refusing proof",
            before, after
        ));
    }
    let resized = after > before;
    if !resized {
        return Err(
            "filesystem grow completed without increasing capacity and no prior durable proof exists"
                .to_string(),
        );
    }
    store_grow_receipt(&GrowReceipt {
        phase: GrowReceiptPhase::Completed,
        target_bytes,
        filesystem: mounted.filesystem.clone(),
        device_bytes,
        before_filesystem_bytes: before,
        after_filesystem_bytes: after,
    })?;
    Ok(ResizeProof {
        device: mounted.source,
        mount_point: mounted.mount_point,
        filesystem: mounted.filesystem,
        device_bytes,
        before_filesystem_bytes: before,
        after_filesystem_bytes: after,
        resized,
        previously_proved: false,
    })
}

/// Keeps the portable control codec testable on macOS without pretending the host
/// filesystem can resize the Linux guest's `/dev/vda`.
#[cfg(not(target_os = "linux"))]
pub fn grow_mounted_data(_target_bytes: i64) -> Result<ResizeProof, String> {
    Err("disk resize is available only inside the Linux guest".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn mounted_data_root_requires_the_exact_mount_and_decodes_proc_escaping() {
        let mounts = "/dev/vda /var/lib/docker ext4 rw 0 0\n\
            /dev/vdb /var/lib/docker-old ext4 rw 0 0\n\
            host\\040share /workspace virtiofs rw 0 0\n";
        let mounted = mounted_data_filesystem(mounts).expect("data mount");
        assert_eq!(mounted.source, "/dev/vda");
        assert_eq!(mounted.mount_point, DOCKER_DATA_ROOT);
        assert_eq!(mounted.filesystem, "ext4");
        assert_eq!(
            decode_mount_field("host\\040share"),
            Some("host share".to_string())
        );
        assert_eq!(decode_mount_field("bad\\0x0"), None);
    }

    #[test]
    fn an_octal_escape_above_one_byte_is_refused_rather_than_wrapped() {
        // 0o400..=0o777 do not fit in a byte. The kernel never emits them, but
        // the decoder must not wrap (silently decoding `\400` to NUL in a release
        // build) or overflow (aborting PID 1 in a checked one) if one appears.
        assert_eq!(decode_mount_field("a\\400b"), None);
        assert_eq!(decode_mount_field("a\\777b"), None);
        // The whole in-range span still decodes, including the boundary.
        assert_eq!(decode_mount_field("\\000"), Some("\u{0}".to_string()));
        assert_eq!(decode_mount_field("\\377"), Some("\u{ff}".to_string()));
        assert_eq!(decode_mount_field("\\134"), Some("\\".to_string()));
        // A truncated escape at end-of-string is still a refusal, not a panic.
        assert_eq!(decode_mount_field("a\\04"), None);
        assert_eq!(decode_mount_field("\\"), None);
    }

    #[test]
    fn df_capacity_parser_uses_total_kibibytes_not_used_or_available_space() {
        let output = "Filesystem 1024-blocks Used Available Capacity Mounted on\n\
            /dev/vda 67108864 4096 67104768 1% /var/lib/docker\n";
        assert_eq!(parse_df_capacity_bytes(output), Some(68_719_476_736));
        assert_eq!(parse_df_capacity_bytes("Filesystem 1024-blocks\n"), None);
    }

    #[test]
    fn an_all_zero_probe_window_is_blank() {
        let mut src = Cursor::new(vec![0u8; BLANK_PROBE_LEN]);
        assert!(probe_is_blank(&mut src).unwrap());
    }

    #[test]
    fn a_device_shorter_than_the_probe_window_can_still_be_blank() {
        let mut src = Cursor::new(vec![0u8; 4096]);
        assert!(probe_is_blank(&mut src).unwrap());
    }

    #[test]
    fn a_completely_unreadable_device_is_not_blank() {
        // Zero bytes readable is not evidence of emptiness, and "blank" is a
        // licence to run mkfs — so it must not be granted here.
        let mut src = Cursor::new(Vec::new());
        assert!(!probe_is_blank(&mut src).unwrap());
    }

    #[test]
    fn an_ext4_superblock_is_enough_to_not_be_blank() {
        // ext4's primary superblock lives at byte 1024, well inside the
        // window but nowhere near its start — a probe that only looked at
        // the first sector would format right over it.
        let mut disk = vec![0u8; BLANK_PROBE_LEN];
        disk[1024 + 56] = 0x53; // s_magic = 0xEF53, little endian
        disk[1024 + 57] = 0xef;
        let mut src = Cursor::new(disk);
        assert!(!probe_is_blank(&mut src).unwrap());
    }

    #[test]
    fn a_btrfs_superblock_is_enough_to_not_be_blank() {
        // btrfs puts its primary superblock at 64 KiB.
        let mut disk = vec![0u8; BLANK_PROBE_LEN];
        disk[64 * 1024 + 0x40..64 * 1024 + 0x48].copy_from_slice(b"_BHRfS_M");
        let mut src = Cursor::new(disk);
        assert!(!probe_is_blank(&mut src).unwrap());
    }

    /// The exact shape of /proc/filesystems on the kata guest kernel: some
    /// lines are a bare `nodev` plus a name, some are a leading tab plus a
    /// name. Taking the last column handles both.
    const PROC_FILESYSTEMS_SAMPLE: &str = "nodev\tsysfs\n\
         nodev\tproc\n\
         nodev\ttmpfs\n\
         nodev\tdevtmpfs\n\
         \text3\n\
         \text2\n\
         \text4\n\
         nodev\tmqueue\n\
         nodev\tcgroup2\n\
         \tvfat\n";

    #[test]
    fn a_filesystem_the_kernel_lists_is_supported() {
        assert!(proc_filesystems_lists(PROC_FILESYSTEMS_SAMPLE, "ext4"));
        // nodev entries are named in the same column as device-backed ones.
        assert!(proc_filesystems_lists(PROC_FILESYSTEMS_SAMPLE, "cgroup2"));
    }

    #[test]
    fn a_filesystem_the_kernel_does_not_list_is_unsupported() {
        // The case this whole probe exists for: mkfs.btrfs ships in the
        // initramfs, but the kata kernel has no btrfs driver, so formatting
        // with it can only ever be followed by a failed mount.
        assert!(!proc_filesystems_lists(PROC_FILESYSTEMS_SAMPLE, "btrfs"));
    }

    #[test]
    fn the_nodev_marker_is_never_mistaken_for_a_filesystem_name() {
        assert!(!proc_filesystems_lists(PROC_FILESYSTEMS_SAMPLE, "nodev"));
    }

    #[test]
    fn a_prefix_of_a_listed_name_does_not_count_as_listed() {
        // "ext" must not match "ext4"/"ext3"/"ext2", and "vfat" must not be
        // satisfied by "fat".
        assert!(!proc_filesystems_lists(PROC_FILESYSTEMS_SAMPLE, "ext"));
        assert!(!proc_filesystems_lists(PROC_FILESYSTEMS_SAMPLE, "fat"));
    }

    #[test]
    fn an_empty_or_blank_proc_filesystems_supports_nothing() {
        assert!(!proc_filesystems_lists("", "ext4"));
        assert!(!proc_filesystems_lists("\n\n   \n", "ext4"));
    }

    #[test]
    fn a_single_nonzero_byte_at_the_very_end_of_the_window_still_counts() {
        let mut disk = vec![0u8; BLANK_PROBE_LEN];
        disk[BLANK_PROBE_LEN - 1] = 1;
        let mut src = Cursor::new(disk);
        assert!(!probe_is_blank(&mut src).unwrap());
    }

    #[test]
    fn data_past_the_probe_window_does_not_affect_the_verdict() {
        // Documents the boundary: we look at exactly 1 MiB and nothing more,
        // so the probe must not be fooled into reading the whole device.
        let mut disk = vec![0u8; BLANK_PROBE_LEN + 4096];
        disk[BLANK_PROBE_LEN + 10] = 0xff;
        let mut src = Cursor::new(disk);
        assert!(probe_is_blank(&mut src).unwrap());
    }

    /// A reader that returns EINTR before its data, mirroring what a real
    /// `read(2)` on a block device does when PID 1 takes a signal.
    struct InterruptingReader {
        interrupts_left: usize,
        inner: Cursor<Vec<u8>>,
    }

    impl Read for InterruptingReader {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            if self.interrupts_left > 0 {
                self.interrupts_left -= 1;
                return Err(io::Error::new(io::ErrorKind::Interrupted, "signal"));
            }
            self.inner.read(buf)
        }
    }

    #[test]
    fn probe_retries_eintr_rather_than_calling_the_disk_unreadable() {
        let mut src = InterruptingReader {
            interrupts_left: 3,
            inner: Cursor::new(vec![0u8; 8192]),
        };
        assert!(probe_is_blank(&mut src).unwrap());
    }

    #[test]
    fn probe_propagates_real_io_errors() {
        struct Failing;
        impl Read for Failing {
            fn read(&mut self, _buf: &mut [u8]) -> io::Result<usize> {
                Err(io::Error::other("EIO"))
            }
        }
        assert!(probe_is_blank(&mut Failing).is_err());
    }

    #[test]
    fn a_missing_device_classifies_as_absent() {
        assert_eq!(
            classify("/definitely/not/a/real/block/device/morbstack-test"),
            DiskState::Absent
        );
    }

    #[test]
    fn a_file_full_of_zeros_classifies_as_blank_and_one_with_bytes_does_not() {
        let dir = std::env::temp_dir().join(format!(
            "morbinit-disk-test-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::create_dir_all(&dir).unwrap();

        let blank = dir.join("blank.img");
        std::fs::write(&blank, vec![0u8; 128 * 1024]).unwrap();
        assert_eq!(classify(blank.to_str().unwrap()), DiskState::Blank);

        let used = dir.join("used.img");
        let mut contents = vec![0u8; 128 * 1024];
        contents[2048] = 0x42;
        std::fs::write(&used, contents).unwrap();
        assert_eq!(classify(used.to_str().unwrap()), DiskState::Formatted);

        let _ = std::fs::remove_dir_all(&dir);
    }

    // ---- the format-intent marker ----------------------------------------

    /// A scratch directory per test, so the marker cases can use real files
    /// (which is what `classify` actually opens).
    fn scratch(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "morbinit-marker-{}-{}-{:?}",
            tag,
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn a_marker_needs_the_whole_magic_and_the_version_byte() {
        assert!(has_format_marker(&format_marker_sector()));
        // Absent.
        assert!(!has_format_marker(&[0u8; 512]));
        assert!(!has_format_marker(b""));
        // Partial magic: not ours, and must not be read as ours.
        assert!(!has_format_marker(b"MORB"));
        assert!(!has_format_marker(b"MORBFMT"));
        assert!(!has_format_marker(b"MORBFMTX\x01"));
        // Full magic but torn before the version byte — whether the sector
        // simply ends there or the byte landed as a zero.
        assert!(!has_format_marker(b"MORBFMT!"));
        assert!(!has_format_marker(b"MORBFMT!\x00"));
        assert!(!has_format_marker(b"MORBFMT!\x00\x00\x00"));
        // Full magic plus a version byte, whatever the version is: the claim
        // "a format started here" does not depend on the layout.
        assert!(has_format_marker(b"MORBFMT!\x01"));
        assert!(has_format_marker(b"MORBFMT!\x07"));
    }

    #[test]
    fn the_marker_sector_is_one_aligned_sector_of_mostly_padding() {
        let sector = format_marker_sector();
        assert_eq!(sector.len(), 512);
        assert_eq!(&sector[..8], FORMAT_MARKER_MAGIC);
        assert_eq!(sector[8], FORMAT_MARKER_VERSION);
        assert!(sector[9..].iter().all(|&b| b == 0));
    }

    #[test]
    fn a_disk_carrying_the_marker_classifies_as_blank_so_it_gets_reformatted() {
        // The bug this closes: an interrupted mkfs leaves the device
        // non-blank *and* unmountable, so every later boot calls it Formatted,
        // preserves it, and falls back to tmpfs — persistence bricked forever.
        let dir = scratch("crashed");
        let img = dir.join("crashed.img");

        // A half-written filesystem: our marker, then whatever mkfs managed
        // to put down before the power went.
        let mut contents = vec![0u8; 128 * 1024];
        contents[..512].copy_from_slice(&format_marker_sector());
        contents[64 * 1024..64 * 1024 + 8].copy_from_slice(b"_BHRfS_M");
        std::fs::write(&img, &contents).unwrap();

        assert_eq!(classify(img.to_str().unwrap()), DiskState::Blank);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_partial_marker_does_not_license_a_format() {
        // "Blank" is a licence to destroy the device, so it is granted only on
        // an exact match. Anything that merely resembles the marker is data
        // somebody else wrote.
        let dir = scratch("partial");
        for (name, head) in [
            ("truncated-magic", &b"MORBFM"[..]),
            ("magic-without-version", &b"MORBFMT!"[..]),
            ("lookalike", &b"MORBFMTX\x01"[..]),
        ] {
            let img = dir.join(format!("{}.img", name));
            let mut contents = vec![0u8; 128 * 1024];
            contents[..head.len()].copy_from_slice(head);
            std::fs::write(&img, &contents).unwrap();
            assert_eq!(
                classify(img.to_str().unwrap()),
                DiskState::Formatted,
                "{} must not be treated as a crashed format",
                name
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_marker_is_only_found_at_the_very_start_of_the_device() {
        // A device whose *contents* happen to contain the magic further in
        // (an image of another morbstack disk, a tarball, anything) is user
        // data, not a crashed format.
        let dir = scratch("offset");
        let img = dir.join("offset.img");
        let mut contents = vec![0u8; 128 * 1024];
        contents[512..512 + 9].copy_from_slice(b"MORBFMT!\x01");
        std::fs::write(&img, &contents).unwrap();
        assert_eq!(classify(img.to_str().unwrap()), DiskState::Formatted);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn writing_then_clearing_the_marker_round_trips_through_classify() {
        // The real lifecycle: blank device -> stamped just before mkfs ->
        // cleared once the filesystem is down. Each step has to be visible to
        // the next boot's classification.
        let dir = scratch("lifecycle");
        let img = dir.join("disk.img");
        std::fs::write(&img, vec![0u8; 128 * 1024]).unwrap();
        let path = img.to_str().unwrap();

        assert_eq!(classify(path), DiskState::Blank);

        write_format_marker(path).unwrap();
        assert!(format_marker_present(path).unwrap());
        assert_eq!(classify(path), DiskState::Blank);

        clear_format_marker(path).unwrap();
        assert!(!format_marker_present(path).unwrap());
        assert_eq!(classify(path), DiskState::Blank);

        // Writing the marker must not disturb anything past its own sector,
        // or "blank" would stop meaning blank.
        let after = std::fs::read(&img).unwrap();
        assert_eq!(after.len(), 128 * 1024);
        assert!(after.iter().all(|&b| b == 0));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_marker_write_leaves_the_rest_of_a_used_device_untouched() {
        // Only reachable on a device we just proved blank, but if the marker
        // write ever did more than its sector the blast radius would be the
        // user's entire layer store.
        let dir = scratch("scoped");
        let img = dir.join("used.img");
        let mut contents = vec![0xABu8; 4096];
        contents[..512].fill(0);
        std::fs::write(&img, &contents).unwrap();

        write_format_marker(img.to_str().unwrap()).unwrap();
        let after = std::fs::read(&img).unwrap();
        assert_eq!(after.len(), 4096);
        assert!(has_format_marker(&after));
        assert!(after[512..].iter().all(|&b| b == 0xAB));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn read_head_tolerates_short_reads_and_eintr() {
        // Block-device reads are interruptible in PID 1, and a device shorter
        // than a sector must come back as "no marker" rather than an error.
        let mut src = InterruptingReader {
            interrupts_left: 2,
            inner: Cursor::new(b"MORBFMT!\x01".to_vec()),
        };
        let mut head = [0u8; FORMAT_MARKER_SECTOR_LEN];
        let n = read_head(&mut src, &mut head).unwrap();
        assert_eq!(n, 9);
        assert!(has_format_marker(&head[..n]));
    }

    #[test]
    fn which_in_finds_the_first_match_in_search_order() {
        let dir = std::env::temp_dir().join(format!(
            "morbinit-which-test-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let first = dir.join("first");
        let second = dir.join("second");
        std::fs::create_dir_all(&first).unwrap();
        std::fs::create_dir_all(&second).unwrap();
        std::fs::write(second.join("mkfs.btrfs"), b"").unwrap();

        let search = format!("{}:{}", first.display(), second.display());
        assert_eq!(
            which_in(&search, "mkfs.btrfs"),
            Some(second.join("mkfs.btrfs"))
        );
        assert_eq!(which_in(&search, "mkfs.ext4"), None);

        // A shadowing copy earlier in the path must win.
        std::fs::write(first.join("mkfs.btrfs"), b"").unwrap();
        assert_eq!(
            which_in(&search, "mkfs.btrfs"),
            Some(first.join("mkfs.btrfs"))
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn which_in_tolerates_empty_path_segments() {
        assert_eq!(which_in("", "anything"), None);
        assert_eq!(which_in("::", "anything"), None);
    }

    #[test]
    fn btrfs_is_preferred_and_carries_its_mount_options() {
        assert_eq!(CANDIDATE_FILESYSTEMS[0], FsKind::Btrfs);
        assert_eq!(
            FsKind::Btrfs.mount_data(),
            Some("compress=zstd:1,discard=async")
        );
        // ext4 gets kernel defaults, which at the syscall level is a NULL
        // data pointer — there is no "defaults" option string.
        assert_eq!(FsKind::Ext4.mount_data(), None);
    }

    #[test]
    fn both_formatters_run_non_interactively() {
        // No tty exists in the guest; a formatter that stops to ask a
        // question would hang the entire boot.
        assert!(FsKind::Btrfs.mkfs_args().contains(&"-f"));
        assert!(FsKind::Ext4.mkfs_args().contains(&"-F"));
    }

    #[test]
    fn mkfs_binaries_are_bare_names_resolved_off_the_guest_path() {
        // Hard-coding /usr/local/sbin/mkfs.btrfs would break the moment the
        // initramfs track moves it; the probe must stay path-based.
        for kind in CANDIDATE_FILESYSTEMS {
            assert!(!kind.mkfs_binary().contains('/'));
        }
    }

    // MARK: - fstrim output parsing (TECH-3 / UX-16)

    #[test]
    fn parses_the_older_bare_bytes_fstrim_format() {
        // The exact shape observed live in the TECH-3 spike
        // (`docs/design/DISK-RECLAIM-DECISION.md` §4 step 8).
        assert_eq!(
            parse_fstrim_trimmed_bytes("/var/lib/docker: 59050795008 bytes trimmed\n"),
            Some(59_050_795_008)
        );
    }

    #[test]
    fn parses_the_util_linux_2_36_human_readable_plus_parenthesized_format() {
        assert_eq!(
            parse_fstrim_trimmed_bytes(
                "/var/lib/docker: 3.5 GiB (3758096384 bytes) trimmed on /dev/vda\n"
            ),
            Some(3_758_096_384)
        );
    }

    #[test]
    fn a_zero_byte_sweep_is_a_real_result_not_a_missing_one() {
        // Zero is a legitimate answer ("nothing to reclaim this sweep") and
        // must decode as `Some(0)`, distinct from `NO_TRIM_YET` (-1).
        assert_eq!(
            parse_fstrim_trimmed_bytes("/var/lib/docker: 0 bytes trimmed\n"),
            Some(0)
        );
    }

    #[test]
    fn unparseable_output_yields_no_result_rather_than_a_panic() {
        assert_eq!(parse_fstrim_trimmed_bytes(""), None);
        assert_eq!(
            parse_fstrim_trimmed_bytes("fstrim: no FITRIM support\n"),
            None
        );
        // A number that is not immediately followed by "bytes" (a byte count
        // in a different unit, a PID, a percentage) must not be mistaken for
        // the trimmed-bytes figure.
        assert_eq!(
            parse_fstrim_trimmed_bytes("/var/lib/docker: something else 42%\n"),
            None
        );
    }

    #[test]
    fn multiple_candidate_numbers_prefer_the_one_actually_labelled_bytes() {
        // "3.5 GiB (3758096384 bytes)" — the rounded human figure "3" or "5"
        // must not be picked over the exact parenthesized byte count.
        assert_eq!(
            parse_fstrim_trimmed_bytes("/mnt: 3.5 GiB (3758096384 bytes) trimmed on /dev/sda1\n"),
            Some(3_758_096_384)
        );
    }

    #[test]
    fn a_non_ascii_line_does_not_panic_the_parser() {
        // Local subprocess output, not peer input — but a background thread
        // panicking on it would still be a self-inflicted denial of service.
        assert_eq!(
            parse_fstrim_trimmed_bytes("/var/lib/docker: 42 bytes trimmed — café\n"),
            Some(42)
        );
    }
}
