//! amd64 emulation for the guest: the Rosetta virtiofs share plus the
//! `binfmt_misc` registration that makes `docker run --platform
//! linux/amd64 ...` work.
//!
//! Three moving parts, in order:
//!
//!   1. **The share.** The host adds a `VZLinuxRosettaDirectoryShare` tagged
//!      `rosetta` when Rosetta for Linux is installed (see
//!      `VMManager.makeConfiguration`). It shows up in the guest as a
//!      virtiofs filesystem we mount at `/run/rosetta`, and the interpreter
//!      itself is `/run/rosetta/rosetta`.
//!   2. **binfmt_misc.** `/proc/sys/fs/binfmt_misc` has to be mounted before
//!      anything can be registered. The kata kernel builds `CONFIG_BINFMT_MISC`
//!      in, so the directory exists from boot and the mount always succeeds;
//!      if a future kernel drops it, the mount fails with ENOENT and we
//!      degrade to "no amd64 support" rather than dying.
//!   3. **The registration.** One line written to
//!      `/proc/sys/fs/binfmt_misc/register` teaching the kernel that x86-64
//!      ELF binaries are to be handed to the interpreter.
//!
//! # Why the flags are `OCF` and not, say, `P`
//!
//! This is the part that decides whether containers work, so it is worth
//! writing down rather than rediscovering:
//!
//!   * `F` (**fix binary**) is load-bearing. Without it the kernel resolves
//!     the interpreter path *at exec time, in the mount namespace of the
//!     process being executed*. A container's mount namespace has its own
//!     root — the image's rootfs — which does not contain `/run/rosetta`,
//!     so every amd64 exec inside a container would fail with ENOENT even
//!     though the interpreter is right there in the init namespace. With
//!     `F` the kernel opens the interpreter once, at registration time, and
//!     holds that `struct file` forever; exec then uses the pinned file and
//!     the caller's namespace is irrelevant. This is exactly why
//!     `tonistiigi/binfmt` and `qemu-binfmt-conf.sh --persistent` exist.
//!   * `C` (**credentials**) makes the kernel compute the new process's
//!     credentials from the *binary* rather than from the interpreter, which
//!     is what keeps setuid/setgid amd64 binaries behaving the way they
//!     would natively. `C` implies `O`.
//!   * `O` (**open binary**) passes the already-open fd of the target binary
//!     to the interpreter as `AT_EXECFD`, so the interpreter does not have
//!     to re-open a path that may not be reachable (or may have been
//!     replaced) from where it runs. Listed explicitly even though `C`
//!     implies it, because "the flags we asked for" should read the same as
//!     the flags in every other project's registration.
//!   * `P` (**preserve argv[0]**) is deliberately *not* set. Rosetta and
//!     qemu-user both expect the interpreter's argv to be
//!     `[interpreter, binary_path, ...args]`; `P` inserts the original
//!     argv[0] as an extra argument, which these interpreters do not expect.
//!
//! # Fallback
//!
//! When the Rosetta share is not there (Rosetta not installed on the host,
//! `rosetta = false` in morb.conf, or an Intel Mac) we look for a
//! `qemu-x86_64` user-mode emulator on the guest `PATH` and register that
//! instead, with the same magic/mask and the same flags. The current
//! initramfs does **not** ship one — see the note on
//! [`QEMU_INTERPRETER_NAMES`] — so in practice this path reports
//! [`Amd64Binfmt::None`] today. The code is here so that dropping a static
//! `qemu-x86_64` into the image is the only change needed to light it up.

// Only the Linux half of this module logs; the pure string-building and
// parsing above it is silent by design (that is what makes it testable), so
// on a macOS `cargo test` build this import would otherwise be unused.
#[cfg(target_os = "linux")]
use crate::log;

/// Where the Rosetta virtiofs share is mounted inside the guest.
pub const ROSETTA_MOUNTPOINT: &str = "/run/rosetta";

/// The virtiofs tag the host exports the Rosetta share under. Must match the
/// `VZVirtioFileSystemDeviceConfiguration(tag:)` in `VMManager.swift`.
pub const ROSETTA_TAG: &str = "rosetta";

/// The interpreter binary inside the share.
pub const ROSETTA_INTERPRETER: &str = "/run/rosetta/rosetta";

/// Where `binfmt_misc` is conventionally mounted. Not a free choice: the
/// kernel creates this exact directory under `/proc/sys/fs` and the
/// filesystem can only be mounted there.
pub const BINFMT_MISC_DIR: &str = "/proc/sys/fs/binfmt_misc";

/// The control file that accepts new registrations.
pub const BINFMT_REGISTER: &str = "/proc/sys/fs/binfmt_misc/register";

/// The `binfmt_misc` entry name we register x86-64 ELF under when Rosetta is
/// the interpreter. Also the filename that appears in [`BINFMT_MISC_DIR`].
pub const ROSETTA_ENTRY: &str = "rosetta";

/// Ditto, for the qemu fallback. A different name so the two can never be
/// confused when reading `/proc/sys/fs/binfmt_misc/`.
pub const QEMU_ENTRY: &str = "qemu-x86_64";

/// The magic bytes that identify a little-endian 64-bit x86-64 ELF, as the
/// `\xNN`-escaped text `binfmt_misc` expects. Byte for byte:
///
/// ```text
///   offset  0  \x7f E L F     e_ident magic
///   offset  4  \x02           EI_CLASS   = ELFCLASS64
///   offset  5  \x01           EI_DATA    = ELFDATA2LSB
///   offset  6  \x01           EI_VERSION = EV_CURRENT
///   offset  7  \x00 ...       EI_OSABI + EI_ABIVERSION + padding
///   offset 16  \x02\x00       e_type    = ET_EXEC
///   offset 18  \x3e\x00       e_machine = EM_X86_64 (62)
/// ```
///
/// Identical to the string in qemu's `qemu-binfmt-conf.sh` and in
/// `tonistiigi/binfmt`; there is exactly one right answer here and it is
/// this one.
pub const X86_64_MAGIC: &str =
    "\\x7fELF\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\x3e\\x00";

/// The mask applied to the first 20 bytes before comparing against
/// [`X86_64_MAGIC`]. Two entries are deliberately not `\xff`:
///
///   * offset 7 is `\x00` — EI_OSABI/EI_ABIVERSION are ignored entirely, so
///     a System V, Linux, or FreeBSD-tagged binary all match.
///   * offset 16 is `\xfe` — masking off the low bit of `e_type` makes both
///     `ET_EXEC` (2) and `ET_DYN` (3) compare equal to the `\x02` in the
///     magic, which is what lets position-independent executables match. In
///     2026 essentially every distro binary is PIE, so dropping this would
///     silently break almost everything.
///
/// Offsets 5 and 6 are `\xfe` for the same historical reason qemu uses:
/// they tolerate the odd off-by-one in `EI_DATA`/`EI_VERSION` seen in the
/// wild without letting a big-endian or 32-bit object through (those differ
/// at offset 4, which is masked `\xff`).
pub const X86_64_MASK: &str =
    "\\xff\\xff\\xff\\xff\\xff\\xfe\\xfe\\x00\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xfe\\xff\\xff\\xff";

/// The flag set every entry is registered with. See the module docs for why
/// each letter is here and why `P` is not.
pub const BINFMT_FLAGS: &str = "OCF";

/// The names a static user-mode x86-64 qemu might be installed under, in the
/// order we try them.
///
/// **Not currently shipped.** `scripts/mkinitramfs.sh` installs the Alpine
/// minirootfs, morbinit, and the pinned Docker engine binaries, and none of
/// those carry a user-mode emulator; Alpine's `qemu-x86_64` apk is not in
/// `dist/apks/` either. So on a host without Rosetta, amd64 images do not
/// run and [`setup`] reports [`Amd64Binfmt::None`]. Adding a static
/// `qemu-x86_64` to `dist/guest-bin/` (roughly 4 MiB, and it must be static
/// — the interpreter is resolved before any container's dynamic loader
/// exists) is the follow-up that turns this branch on; the registration
/// code below needs no changes for it.
pub const QEMU_INTERPRETER_NAMES: &[&str] = &["qemu-x86_64-static", "qemu-x86_64"];

/// Which interpreter, if any, ended up handling x86-64 ELF.
///
/// The string forms are the wire values of the MRB0 `info` reply's
/// `binfmt_amd64` field, so they are part of the host/guest contract and
/// must not be renamed casually.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Amd64Binfmt {
    /// Rosetta, via the host's directory share.
    Rosetta,
    /// A user-mode qemu found on the guest `PATH`.
    Qemu,
    /// Nothing — `--platform linux/amd64` will fail with `exec format error`.
    None,
}

impl Amd64Binfmt {
    /// The wire string for the MRB0 `info` reply.
    pub fn as_str(self) -> &'static str {
        match self {
            Amd64Binfmt::Rosetta => "rosetta",
            Amd64Binfmt::Qemu => "qemu",
            Amd64Binfmt::None => "none",
        }
    }
}

/// The outcome of [`setup`], reported to the host in `info`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BinfmtStatus {
    /// Whether the Rosetta share was found, mounted, and registered. Note
    /// this is stricter than "the host offered a share": a share that mounts
    /// but whose interpreter will not register leaves this `false`, because
    /// from the user's point of view Rosetta is not working.
    pub rosetta: bool,
    /// Which interpreter x86-64 ELF is registered to.
    pub amd64: Amd64Binfmt,
}

impl BinfmtStatus {
    /// The "nothing is set up" state. Also what a non-Linux build reports.
    pub const fn disabled() -> Self {
        BinfmtStatus {
            rosetta: false,
            amd64: Amd64Binfmt::None,
        }
    }
}

/// One `binfmt_misc` registration, in the form the kernel's `register` file
/// parses.
///
/// Kept as data with a pure [`Self::register_line`] rather than formatting
/// the string at the write site, because the string is fiddly, unforgiving
/// (a single misplaced colon is silently a different registration), and
/// completely untestable once it is inlined into an I/O call.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BinfmtRegistration {
    /// The entry name; becomes a file under [`BINFMT_MISC_DIR`].
    pub name: String,
    /// `\xNN`-escaped magic bytes.
    pub magic: String,
    /// `\xNN`-escaped mask, same length as the magic.
    pub mask: String,
    /// Absolute path to the interpreter, resolved in the *init* mount
    /// namespace (the `F` flag pins it there — see the module docs).
    pub interpreter: String,
    /// Flag letters, e.g. `OCF`.
    pub flags: String,
}

impl BinfmtRegistration {
    /// The x86-64 ELF registration for a given interpreter and entry name.
    pub fn x86_64(name: &str, interpreter: &str) -> Self {
        BinfmtRegistration {
            name: name.to_string(),
            magic: X86_64_MAGIC.to_string(),
            mask: X86_64_MASK.to_string(),
            interpreter: interpreter.to_string(),
            flags: BINFMT_FLAGS.to_string(),
        }
    }

    /// The exact bytes to write to `/proc/sys/fs/binfmt_misc/register`.
    ///
    /// Format, from `Documentation/admin-guide/binfmt-misc.rst`:
    ///
    /// ```text
    ///   :name:type:offset:magic:mask:interpreter:flags
    /// ```
    ///
    /// The leading colon is the field delimiter declaration, not an empty
    /// first field — `binfmt_misc` takes the first character of the line as
    /// the delimiter for the rest of it. `type` is `M` for magic-byte
    /// matching (as opposed to `E` for filename extension), and `offset` is
    /// left empty, which the kernel reads as 0: our magic starts at the very
    /// first byte of the file.
    ///
    /// No trailing newline. The kernel strips one if present, but writing
    /// exactly the bytes it parses removes a class of "why does the entry
    /// name have a stray character" debugging.
    pub fn register_line(&self) -> String {
        format!(
            ":{}:M::{}:{}:{}:{}",
            self.name, self.magic, self.mask, self.interpreter, self.flags
        )
    }

    /// Whether this registration can be written at all: every field the
    /// kernel splits on `:` must be free of `:` itself, and the name,
    /// magic, mask, and interpreter must be non-empty.
    ///
    /// A `:` in a path (legal on Linux!) would silently shift every
    /// following field one place left, producing either an EINVAL or — much
    /// worse — a *valid but wrong* registration. Cheaper to refuse.
    pub fn is_valid(&self) -> bool {
        if self.name.is_empty()
            || self.magic.is_empty()
            || self.mask.is_empty()
            || self.interpreter.is_empty()
        {
            return false;
        }
        // Decoded byte counts, not character counts: the magic's literal
        // `ELF` makes the two strings different lengths for the same twenty
        // bytes. A mask shorter than the magic silently stops checking part
        // of the header; a longer one is rejected by the kernel outright.
        match (decode_escaped(&self.magic), decode_escaped(&self.mask)) {
            (Some(magic), Some(mask)) if magic.len() == mask.len() => {}
            _ => return false,
        }
        ![
            self.name.as_str(),
            self.magic.as_str(),
            self.mask.as_str(),
            self.interpreter.as_str(),
            self.flags.as_str(),
        ]
        .iter()
        .any(|field| field.contains(':') || field.contains('\n'))
    }
}

/// Decode the `\xNN`-escaped byte-string syntax `binfmt_misc` uses for
/// magic and mask into the bytes the kernel will actually compare.
///
/// Mirrors the kernel's own `unquote()`: `\xNN` is a hex byte, and every
/// other character stands for itself (which is why `ELF` can sit in the
/// middle of [`X86_64_MAGIC`] as three plain characters).
///
/// Returns `None` on a malformed escape — a trailing `\x`, or `\x` followed
/// by something that is not two hex digits. Worth being strict about: the
/// kernel treats a bad escape as literal text rather than rejecting it, so
/// a typo like `\xf` would quietly register a *different, longer* magic
/// that matches nothing, and the only symptom would be amd64 binaries
/// mysteriously not being translated.
///
/// Pure, so [`BinfmtRegistration::is_valid`] can check that magic and mask
/// describe the same number of bytes without a mounted `binfmt_misc` — a
/// check that cannot be done on the strings' character lengths, since the
/// magic's literal `ELF` makes it nine characters shorter than the
/// all-escapes mask for the same twenty bytes.
pub fn decode_escaped(s: &str) -> Option<Vec<u8>> {
    let bytes = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\\' && i + 1 < bytes.len() && bytes[i + 1] == b'x' {
            if i + 3 >= bytes.len() {
                return None;
            }
            let hi = (bytes[i + 2] as char).to_digit(16)?;
            let lo = (bytes[i + 3] as char).to_digit(16)?;
            out.push((hi * 16 + lo) as u8);
            i += 4;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    Some(out)
}

/// Whether a `/proc/sys/fs/binfmt_misc/<name>` file's contents say the entry
/// is live.
///
/// The file looks like:
///
/// ```text
///   enabled
///   interpreter /run/rosetta/rosetta
///   flags: OCF
///   offset 0
///   magic 7f454c46...
///   mask fffffffff...
/// ```
///
/// The first line is `enabled` or `disabled`. Split out as a pure function
/// so the parse is unit tested without a mounted `binfmt_misc`.
pub fn registration_is_enabled(contents: &str) -> bool {
    contents
        .lines()
        .next()
        .map(|line| line.trim() == "enabled")
        .unwrap_or(false)
}

/// The interpreter path recorded in a `/proc/sys/fs/binfmt_misc/<name>`
/// file, if it names one.
///
/// Used to tell "the entry we just wrote" apart from a stale entry left by
/// an earlier boot pointing somewhere that no longer exists.
pub fn registration_interpreter(contents: &str) -> Option<&str> {
    contents
        .lines()
        .find_map(|line| line.strip_prefix("interpreter "))
        .map(str::trim)
}

// ---------------------------------------------------------------------------
// Everything below mounts filesystems or writes to /proc, so it is Linux-only.
// ---------------------------------------------------------------------------

/// Mount the Rosetta share, mount `binfmt_misc`, and register an x86-64
/// interpreter. Best effort throughout: every failure is logged and
/// downgrades the result, because an amd64-less guest is a working guest
/// and PID 1 has nothing to hand off to.
///
/// Must run after [`crate::mounts::early_mounts`] (it needs `/proc`, `/sys`
/// and the `/run` tmpfs) and should run before the supervisor starts
/// dockerd, so the registration is in place before the first container can
/// possibly be created. Nothing enforces that ordering at the type level;
/// `main.rs` is the single caller.
/// Whether the host attached a Rosetta share is not something the guest is
/// told: `rosetta = false` in `morb.conf` simply means the device is absent,
/// and the mount then fails. So there is no knob here — we try, and the
/// outcome *is* the answer.
#[cfg(target_os = "linux")]
pub fn setup() -> BinfmtStatus {
    if !binfmt_misc_available() {
        log::log(
            "binfmt_misc is not available in this kernel — amd64 images will not run \
             (docker run --platform linux/amd64 will fail with \"exec format error\")",
        );
        return BinfmtStatus::disabled();
    }

    match mount_rosetta_share() {
        Ok(()) => {
            if register(&BinfmtRegistration::x86_64(ROSETTA_ENTRY, ROSETTA_INTERPRETER)) {
                log::log(&format!(
                    "amd64 binfmt: registered Rosetta ({}) for x86-64 ELF",
                    ROSETTA_INTERPRETER
                ));
                return BinfmtStatus {
                    rosetta: true,
                    amd64: Amd64Binfmt::Rosetta,
                };
            }
            log::log("amd64 binfmt: the Rosetta share mounted but would not register");
        }
        Err(e) => log::log(&format!("amd64 binfmt: no usable Rosetta share ({})", e)),
    }

    // Fallback. Currently always None in a stock image — see QEMU_INTERPRETER_NAMES.
    match find_qemu_x86_64() {
        Some(path) => {
            if register(&BinfmtRegistration::x86_64(QEMU_ENTRY, &path)) {
                log::log(&format!(
                    "amd64 binfmt: registered qemu-user ({}) for x86-64 ELF",
                    path
                ));
                return BinfmtStatus {
                    rosetta: false,
                    amd64: Amd64Binfmt::Qemu,
                };
            }
            log::log(&format!(
                "amd64 binfmt: found {} but it would not register",
                path
            ));
        }
        None => log::log(&format!(
            "amd64 binfmt: no x86-64 interpreter available (looked for {} on {}) — \
             amd64 images will not run",
            QEMU_INTERPRETER_NAMES.join(", "),
            crate::supervisor::GUEST_PATH
        )),
    }

    BinfmtStatus::disabled()
}

/// Non-Linux builds have nothing to register. Present so `main.rs` and the
/// control context do not need their own `cfg` around every call site.
#[cfg(not(target_os = "linux"))]
pub fn setup() -> BinfmtStatus {
    BinfmtStatus::disabled()
}

/// Mount `binfmt_misc` at [`BINFMT_MISC_DIR`], returning whether the
/// directory is usable afterwards.
///
/// `EBUSY` means somebody already mounted it, which is success. The
/// directory itself is created by the kernel when `CONFIG_BINFMT_MISC` is
/// compiled in, so its absence is the tell that the kernel cannot do this
/// at all — we check that first and skip the mount attempt entirely, since
/// mounting onto a nonexistent target only yields a confusing ENOENT.
#[cfg(target_os = "linux")]
fn binfmt_misc_available() -> bool {
    if !std::path::Path::new(BINFMT_MISC_DIR).is_dir() {
        return false;
    }
    match crate::sys::mount("binfmt_misc", BINFMT_MISC_DIR, "binfmt_misc", 0) {
        Ok(()) => {
            log::log(&format!("mounted binfmt_misc at {}", BINFMT_MISC_DIR));
            true
        }
        Err(e) if e.raw_os_error() == Some(crate::sys::EBUSY) => {
            log::log("binfmt_misc already mounted (EBUSY, treating as ok)");
            true
        }
        Err(e) => {
            log::log(&format!(
                "WARNING: mount binfmt_misc at {} failed: {}",
                BINFMT_MISC_DIR, e
            ));
            // The register file is the only thing we actually need; if it is
            // somehow there without our mount succeeding, carry on.
            std::path::Path::new(BINFMT_REGISTER).exists()
        }
    }
}

/// Mount the host's Rosetta virtiofs share at [`ROSETTA_MOUNTPOINT`] and
/// confirm the interpreter is inside it.
///
/// Mounted `nosuid,nodev` but emphatically *not* `noexec`: the whole point
/// is to execute the file, and with the `F` flag the kernel does that
/// `open_exec` at registration time, so a `noexec` mount would fail the
/// registration outright rather than at first use.
#[cfg(target_os = "linux")]
fn mount_rosetta_share() -> std::io::Result<()> {
    if !kernel_supports_virtiofs() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::Unsupported,
            "this kernel cannot mount virtiofs",
        ));
    }

    std::fs::create_dir_all(ROSETTA_MOUNTPOINT)?;

    match crate::sys::mount(
        ROSETTA_TAG,
        ROSETTA_MOUNTPOINT,
        "virtiofs",
        crate::sys::MS_NODEV | crate::sys::MS_NOSUID,
    ) {
        Ok(()) => log::log(&format!(
            "mounted virtiofs tag \"{}\" at {}",
            ROSETTA_TAG, ROSETTA_MOUNTPOINT
        )),
        Err(e) if e.raw_os_error() == Some(crate::sys::EBUSY) => {
            log::log("rosetta share already mounted (EBUSY, treating as ok)");
        }
        Err(e) => return Err(e),
    }

    // A mount alone proves nothing: if the host did not attach a Rosetta
    // device the tag simply does not resolve, and on some kernels that is a
    // successful mount of an empty directory rather than an error.
    if !std::path::Path::new(ROSETTA_INTERPRETER).exists() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            format!("{} is not present in the share", ROSETTA_INTERPRETER),
        ));
    }
    Ok(())
}

/// Whether `/proc/filesystems` lists virtiofs.
///
/// Same reasoning as `disk::kernel_supports`: the guest kernel is monolithic
/// (kata ships no loadable modules), so this list is complete and final
/// rather than "what happens to be loaded right now".
#[cfg(target_os = "linux")]
fn kernel_supports_virtiofs() -> bool {
    match std::fs::read_to_string("/proc/filesystems") {
        Ok(contents) => crate::disk::proc_filesystems_lists(&contents, "virtiofs"),
        // Unreadable /proc is weird enough that guessing "yes" and letting
        // mount(2) produce the real error beats refusing pre-emptively.
        Err(_) => true,
    }
}

/// Write one registration, removing any entry already holding the name.
///
/// Returns whether the entry is enabled and pointing at our interpreter
/// afterwards — a write that the kernel accepts but that produces a
/// disabled or differently-aimed entry is a failure as far as callers are
/// concerned.
#[cfg(target_os = "linux")]
fn register(reg: &BinfmtRegistration) -> bool {
    use std::io::Write;

    if !reg.is_valid() {
        log::log(&format!(
            "refusing to register binfmt entry \"{}\": a field contains a delimiter \
             or is empty (interpreter {:?})",
            reg.name, reg.interpreter
        ));
        return false;
    }

    let entry = format!("{}/{}", BINFMT_MISC_DIR, reg.name);

    // A leftover entry from an earlier boot would make the register write
    // fail with EEXIST. Removing it is a write of "-1" to the entry file.
    if std::path::Path::new(&entry).exists() {
        log::log(&format!("removing the existing binfmt entry {}", entry));
        if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open(&entry) {
            let _ = f.write_all(b"-1");
        }
    }

    let line = reg.register_line();
    let write_result = std::fs::OpenOptions::new()
        .write(true)
        .open(BINFMT_REGISTER)
        .and_then(|mut f| f.write_all(line.as_bytes()));
    if let Err(e) = write_result {
        log::log(&format!(
            "WARNING: writing the {} binfmt registration to {} failed: {}",
            reg.name, BINFMT_REGISTER, e
        ));
        return false;
    }

    // Read it back. `write(2)` returning success only means the kernel
    // parsed the line; this confirms the entry exists, is enabled, and aims
    // where we told it to.
    match std::fs::read_to_string(&entry) {
        Ok(contents) => {
            let enabled = registration_is_enabled(&contents);
            let interpreter = registration_interpreter(&contents);
            if !enabled {
                log::log(&format!("binfmt entry {} registered but is disabled", entry));
                return false;
            }
            if let Some(found) = interpreter {
                if found != reg.interpreter {
                    log::log(&format!(
                        "binfmt entry {} points at {} rather than {}",
                        entry, found, reg.interpreter
                    ));
                    return false;
                }
            }
            true
        }
        Err(e) => {
            log::log(&format!(
                "binfmt entry {} could not be read back after registration: {}",
                entry, e
            ));
            false
        }
    }
}

/// Look for a user-mode x86-64 qemu on the same `PATH` the services get.
#[cfg(target_os = "linux")]
fn find_qemu_x86_64() -> Option<String> {
    QEMU_INTERPRETER_NAMES
        .iter()
        .find_map(|name| crate::disk::which(name))
        .map(|p| p.display().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rosetta_register_line_matches_the_documented_format() {
        let reg = BinfmtRegistration::x86_64(ROSETTA_ENTRY, ROSETTA_INTERPRETER);
        assert_eq!(
            reg.register_line(),
            ":rosetta:M::\\x7fELF\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\x3e\\x00\
             :\\xff\\xff\\xff\\xff\\xff\\xfe\\xfe\\x00\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xfe\\xff\\xff\\xff\
             :/run/rosetta/rosetta:OCF"
        );
    }

    #[test]
    fn register_line_has_exactly_seven_colon_separated_fields() {
        let line = BinfmtRegistration::x86_64(ROSETTA_ENTRY, ROSETTA_INTERPRETER).register_line();
        assert!(line.starts_with(':'), "the delimiter declaration is missing");
        // Leading ':' yields an empty first element, then the seven fields.
        let parts: Vec<&str> = line.split(':').collect();
        assert_eq!(parts.len(), 8, "unexpected field count in {:?}", line);
        assert_eq!(parts[0], "");
        assert_eq!(parts[1], "rosetta", "name");
        assert_eq!(parts[2], "M", "type must be magic-byte matching");
        assert_eq!(parts[3], "", "offset must be empty, meaning 0");
        assert_eq!(parts[6], ROSETTA_INTERPRETER);
        assert_eq!(parts[7], "OCF");
    }

    /// The magic and mask, decoded to the bytes the kernel compares.
    fn magic_bytes() -> Vec<u8> {
        decode_escaped(X86_64_MAGIC).expect("the magic must decode")
    }
    fn mask_bytes() -> Vec<u8> {
        decode_escaped(X86_64_MASK).expect("the mask must decode")
    }

    #[test]
    fn the_magic_and_mask_describe_twenty_bytes_each() {
        // Through e_machine at offsets 18..19 — one byte short and we would
        // not be checking the architecture at all.
        assert_eq!(magic_bytes().len(), 20);
        assert_eq!(mask_bytes().len(), 20);
    }

    #[test]
    fn the_magic_is_a_little_endian_64_bit_x86_64_elf_header() {
        let m = magic_bytes();
        assert_eq!(&m[0..4], b"\x7fELF", "e_ident magic");
        assert_eq!(m[4], 2, "EI_CLASS must be ELFCLASS64");
        assert_eq!(m[5], 1, "EI_DATA must be ELFDATA2LSB");
        assert_eq!(m[6], 1, "EI_VERSION must be EV_CURRENT");
        assert_eq!(&m[7..16], &[0u8; 9], "EI_OSABI and padding are zeroed");
        assert_eq!(u16::from_le_bytes([m[16], m[17]]), 2, "e_type = ET_EXEC");
        assert_eq!(
            u16::from_le_bytes([m[18], m[19]]),
            62,
            "e_machine = EM_X86_64"
        );
    }

    #[test]
    fn the_mask_lets_pie_binaries_match() {
        // e_type is at offset 16. Masking off its low bit makes ET_DYN (3)
        // compare equal to the magic's ET_EXEC (2), which is what lets
        // position-independent executables match. Get this wrong and every
        // modern amd64 binary silently fails to be recognised.
        let mask = mask_bytes();
        let magic = magic_bytes();
        assert_eq!(mask[16], 0xfe, "e_type must be masked with 0xfe");
        assert_eq!(3u8 & mask[16], magic[16], "ET_DYN must match the magic");
        assert_eq!(2u8 & mask[16], magic[16], "ET_EXEC must match the magic");

        assert_eq!(mask[7], 0x00, "EI_OSABI must be ignored entirely");
        assert_eq!(mask[18], 0xff, "e_machine must be matched exactly");
        assert_eq!(mask[19], 0xff, "e_machine must be matched exactly");
        assert_eq!(mask[4], 0xff, "EI_CLASS must be matched exactly");
    }

    #[test]
    fn the_mask_rejects_an_arm64_header() {
        // The negative case the mask exists for: a 20-byte aarch64 ELF
        // header must not match, or we would hand native binaries to the
        // emulator. e_machine = EM_AARCH64 (183 = 0xb7).
        let mut arm = magic_bytes();
        arm[18] = 0xb7;
        arm[19] = 0x00;
        let magic = magic_bytes();
        let mask = mask_bytes();
        let matches = arm
            .iter()
            .zip(mask.iter())
            .zip(magic.iter())
            .all(|((b, m), want)| b & m == *want);
        assert!(!matches, "an aarch64 header must not match the x86-64 magic");
    }

    #[test]
    fn escape_decoding_handles_literals_bad_escapes_and_empties() {
        assert_eq!(decode_escaped("\\x00\\xff"), Some(vec![0x00, 0xff]));
        assert_eq!(decode_escaped("ELF"), Some(vec![b'E', b'L', b'F']));
        assert_eq!(decode_escaped(""), Some(Vec::new()));
        // A truncated or non-hex escape is a typo that the kernel would
        // silently take literally, changing the magic's length.
        assert_eq!(decode_escaped("\\x0"), None);
        assert_eq!(decode_escaped("\\xzz"), None);
        assert_eq!(decode_escaped("\\x"), None);
        // A lone backslash is not an escape introducer.
        assert_eq!(decode_escaped("\\n"), Some(vec![b'\\', b'n']));
    }

    #[test]
    fn flags_include_f_so_containers_can_resolve_the_interpreter() {
        // The single most important letter: without F the kernel looks the
        // interpreter up in the *container's* mount namespace, where
        // /run/rosetta does not exist.
        assert!(BINFMT_FLAGS.contains('F'));
        assert!(BINFMT_FLAGS.contains('C'));
        assert!(BINFMT_FLAGS.contains('O'));
        // And P must stay off: it prepends argv[0], which neither Rosetta
        // nor qemu-user expects.
        assert!(!BINFMT_FLAGS.contains('P'));
    }

    #[test]
    fn qemu_registration_differs_only_in_name_and_interpreter() {
        let rosetta = BinfmtRegistration::x86_64(ROSETTA_ENTRY, ROSETTA_INTERPRETER);
        let qemu = BinfmtRegistration::x86_64(QEMU_ENTRY, "/usr/local/bin/qemu-x86_64");
        assert_eq!(rosetta.magic, qemu.magic);
        assert_eq!(rosetta.mask, qemu.mask);
        assert_eq!(rosetta.flags, qemu.flags);
        assert_ne!(rosetta.name, qemu.name);
        assert_eq!(
            qemu.register_line(),
            format!(
                ":qemu-x86_64:M::{}:{}:/usr/local/bin/qemu-x86_64:OCF",
                X86_64_MAGIC, X86_64_MASK
            )
        );
    }

    #[test]
    fn a_colon_in_the_interpreter_path_is_refused() {
        // Legal on Linux, catastrophic here: it would shift every later
        // field one place left and register something entirely different.
        let reg = BinfmtRegistration::x86_64(ROSETTA_ENTRY, "/run/ros:etta/rosetta");
        assert!(!reg.is_valid());
        assert!(BinfmtRegistration::x86_64(ROSETTA_ENTRY, ROSETTA_INTERPRETER).is_valid());
    }

    #[test]
    fn empty_and_mismatched_fields_are_refused() {
        assert!(!BinfmtRegistration::x86_64(ROSETTA_ENTRY, "").is_valid());
        assert!(!BinfmtRegistration::x86_64("", ROSETTA_INTERPRETER).is_valid());

        let mut short_mask = BinfmtRegistration::x86_64(ROSETTA_ENTRY, ROSETTA_INTERPRETER);
        short_mask.mask = "\\xff".to_string();
        assert!(!short_mask.is_valid());

        let mut newline = BinfmtRegistration::x86_64(ROSETTA_ENTRY, ROSETTA_INTERPRETER);
        newline.interpreter = "/run/rosetta/rose\ntta".to_string();
        assert!(!newline.is_valid());
    }

    #[test]
    fn the_register_line_carries_no_trailing_newline() {
        let line = BinfmtRegistration::x86_64(ROSETTA_ENTRY, ROSETTA_INTERPRETER).register_line();
        assert!(!line.ends_with('\n'));
        assert!(!line.contains('\n'));
    }

    #[test]
    fn enabled_is_read_off_the_first_line() {
        let live = "enabled\ninterpreter /run/rosetta/rosetta\nflags: OCF\noffset 0\n";
        let dead = "disabled\ninterpreter /run/rosetta/rosetta\nflags: OCF\noffset 0\n";
        assert!(registration_is_enabled(live));
        assert!(!registration_is_enabled(dead));
        assert!(!registration_is_enabled(""));
        // Only the first line counts: the word "enabled" appearing later
        // must not be mistaken for the status.
        assert!(!registration_is_enabled("disabled\nenabled\n"));
    }

    #[test]
    fn the_interpreter_is_read_back_off_the_entry_file() {
        let contents = "enabled\ninterpreter /run/rosetta/rosetta\nflags: OCF\noffset 0\n\
                        magic 7f454c46\nmask ffffffff\n";
        assert_eq!(
            registration_interpreter(contents),
            Some("/run/rosetta/rosetta")
        );
        assert_eq!(registration_interpreter("enabled\n"), None);
    }

    #[test]
    fn binfmt_wire_strings_are_the_three_contract_values() {
        assert_eq!(Amd64Binfmt::Rosetta.as_str(), "rosetta");
        assert_eq!(Amd64Binfmt::Qemu.as_str(), "qemu");
        assert_eq!(Amd64Binfmt::None.as_str(), "none");
    }

    #[test]
    fn the_disabled_status_reports_no_amd64_support() {
        let status = BinfmtStatus::disabled();
        assert!(!status.rosetta);
        assert_eq!(status.amd64, Amd64Binfmt::None);
        assert_eq!(status.amd64.as_str(), "none");
    }

    #[test]
    fn the_rosetta_mountpoint_and_interpreter_agree() {
        assert!(ROSETTA_INTERPRETER.starts_with(ROSETTA_MOUNTPOINT));
        assert_eq!(
            ROSETTA_INTERPRETER,
            format!("{}/{}", ROSETTA_MOUNTPOINT, "rosetta")
        );
        // The mountpoint must live under the /run tmpfs that early_mounts
        // creates, or there is nowhere to mount it before dockerd starts.
        assert!(ROSETTA_MOUNTPOINT.starts_with("/run/"));
    }

    #[test]
    fn the_register_path_is_inside_the_binfmt_misc_dir() {
        assert_eq!(BINFMT_REGISTER, format!("{}/register", BINFMT_MISC_DIR));
    }
}
