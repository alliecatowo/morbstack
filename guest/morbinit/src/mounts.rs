//! Early filesystem setup for PID 1.
//!
//! Linux-only. morbinit boots as `/init` inside a gzipped-newc initramfs
//! (`rdinit=/init`, no `root=` on the kernel command line), so the rootfs is
//! the initramfs itself, living in RAM, and *nothing* is mounted when we get
//! control: PID 1 has to bring up `/proc`, `/sys`, `/dev`, `/run`, `/tmp`
//! and the unified cgroup hierarchy itself before the supervisor or the
//! control server can rely on any of them.
//!
//! Only the pseudo-filesystems live here. The one real block device,
//! `/dev/vda`, is handled separately by `disk.rs` — it has to be classified
//! before it is touched, possibly formatted, and unwound again on shutdown,
//! which is a great deal more logic than "mount these six things in order".
#![cfg(target_os = "linux")]

use crate::guest_proxy::{self, ProxyEnv};
use crate::log;
use crate::shares::{self, MountState, ShareSpec};
use crate::sys;
use std::fs;

struct MountSpec {
    source: &'static str,
    target: &'static str,
    fstype: &'static str,
    flags: std::os::raw::c_ulong,
}

/// The standard pseudo-filesystems every Linux init needs, in mount order.
/// `/run` and `/tmp` are tmpfs so services get a writable scratch area even
/// before (or if) the data disk mounts successfully.
const EARLY_MOUNTS: &[MountSpec] = &[
    MountSpec {
        source: "proc",
        target: "/proc",
        fstype: "proc",
        flags: sys::MS_NODEV | sys::MS_NOSUID | sys::MS_NOEXEC,
    },
    MountSpec {
        source: "sysfs",
        target: "/sys",
        fstype: "sysfs",
        flags: sys::MS_NODEV | sys::MS_NOSUID | sys::MS_NOEXEC,
    },
    MountSpec {
        source: "devtmpfs",
        target: "/dev",
        fstype: "devtmpfs",
        flags: sys::MS_NOSUID,
    },
    MountSpec {
        source: "tmpfs",
        target: "/run",
        fstype: "tmpfs",
        flags: sys::MS_NODEV | sys::MS_NOSUID,
    },
    MountSpec {
        source: "tmpfs",
        target: "/tmp",
        fstype: "tmpfs",
        flags: sys::MS_NODEV | sys::MS_NOSUID,
    },
    MountSpec {
        source: "cgroup2",
        target: "/sys/fs/cgroup",
        fstype: "cgroup2",
        flags: sys::MS_NODEV | sys::MS_NOSUID | sys::MS_NOEXEC,
    },
];

/// Read the kernel command line, or an empty string if it cannot be read.
///
/// Requires `/proc` to be mounted, so this runs after `early_mounts`. A
/// failure here is not fatal: the guest boots fine without host directories,
/// it just cannot serve bind mounts.
pub fn advertised_shares() -> Vec<ShareSpec> {
    match fs::read_to_string(shares::CMDLINE_PATH) {
        Ok(cmdline) => shares::parse_cmdline(&cmdline),
        Err(e) => {
            log::log(&format!(
                "WARNING: could not read {}: {} — no host directories will be shared",
                shares::CMDLINE_PATH,
                e
            ));
            Vec::new()
        }
    }
}

/// Read the same kernel command line ``advertised_shares`` reads, decoded for
/// the proxy environment instead. Same file, same failure policy: an unset or
/// unreadable command line just means dockerd starts with no proxy.
pub fn advertised_proxy_env() -> ProxyEnv {
    match fs::read_to_string(shares::CMDLINE_PATH) {
        Ok(cmdline) => guest_proxy::parse_cmdline(&cmdline),
        Err(e) => {
            log::log(&format!(
                "WARNING: could not read {}: {} — dockerd will start with no proxy configured",
                shares::CMDLINE_PATH,
                e
            ));
            ProxyEnv::default()
        }
    }
}

/// Mount each advertised host directory at its own absolute path.
///
/// Returns `(path, state)` for every share, in mount order, for the `shares`
/// field of `info` replies — the host uses it to tell the user which of the
/// directories it configured actually made it in.
///
/// A share that fails to mount is logged loudly and skipped. It must not stop
/// the boot: a guest with no `/Volumes` is a guest that cannot bind-mount
/// `/Volumes`, whereas a guest that refuses to boot is a Docker engine that
/// does not exist. The loudness matters because the downstream symptom is
/// mute — dockerd *creates* a missing bind source rather than failing, so the
/// container sees an empty directory and nothing anywhere says why.
pub fn mount_shares(specs: &[ShareSpec]) -> Vec<(String, MountState)> {
    let table = shares::mount_table(specs);
    if table.is_empty() {
        log::log("no host directories advertised on the kernel command line");
        return Vec::new();
    }

    let mut results = Vec::with_capacity(table.len());
    for mount in table {
        let mut flags = 0;
        if mount.nosuid {
            flags |= sys::MS_NOSUID;
        }
        if mount.nodev {
            flags |= sys::MS_NODEV;
        }
        if mount.rdonly {
            flags |= sys::MS_RDONLY;
        }

        if let Err(e) = fs::create_dir_all(&mount.target) {
            log::log(&format!(
                "WARNING: could not create share mount point {}: {} — {} will not be \
                 available to bind mounts",
                mount.target, e, mount.target
            ));
            results.push((mount.target, MountState::Failed));
            continue;
        }
        // No `data` string. The virtiofs driver accepts only `dax` and
        // `source`, and DAX needs a shared memory window that
        // Virtualization.framework does not expose, so anything we passed here
        // would be rejected with EINVAL.
        match sys::mount(&mount.tag, &mount.target, shares::FSTYPE, flags) {
            Ok(()) => {
                log::log(&format!(
                    "mounted host directory {} (virtiofs tag {})",
                    mount.target, mount.tag
                ));
                results.push((mount.target, MountState::Mounted));
            }
            Err(e) => {
                log::log(&format!(
                    "WARNING: mount -t {} {} {} failed: {} — bind mounts under {} will see \
                     an empty directory",
                    shares::FSTYPE,
                    mount.tag,
                    mount.target,
                    e,
                    mount.target
                ));
                results.push((mount.target, MountState::Failed));
            }
        }
    }
    results
}

/// The guest path a shared root has to appear at for `alias_tmp` to fire.
const SHARED_TMP_PATH: &str = "/private/tmp";
/// Where the guest's own tmpfs `/tmp` (mounted by `early_mounts`) lives.
const GUEST_TMP_PATH: &str = "/tmp";

/// Bind-mount the guest's `/tmp` onto the same content as `/private/tmp`,
/// when (and only when) that root is actually a live host share.
///
/// This is docs/parity.md #9's fix: on macOS, `/tmp` is a symlink to
/// `/private/tmp`, and the default `shared_paths` shares `/private/tmp`
/// (not the bare, unresolved `/tmp` a Mac user naturally types). Without
/// this, `docker run -v /tmp/x/f:/y ...` doesn't error — dockerd just
/// creates `/tmp/x/f` as an empty directory in the guest, because the
/// guest's own `/tmp` is its own independent tmpfs that has never heard of
/// the host's `/private/tmp` share, and a bind mount of a path that doesn't
/// exist yet is dockerd's own default behaviour for "create it". That is
/// the worst class of bug: no error, no warning at the point of failure,
/// just silently wrong data days later.
///
/// The fix mirrors what macOS itself already does with `/tmp`: after this
/// runs, the guest's own `/tmp` shows the exact same content as
/// `/private/tmp` (a plain Linux bind mount, `mount --bind`), so a bind
/// mount source of literal `/tmp/x/f` now resolves to the real host file —
/// the same way it already does today on the Mac side, where every
/// process's own `/tmp` writes land in `/private/tmp` because that is what
/// the symlink already means. There is a real trade-off worth knowing: any
/// of dockerd/containerd/buildkit's own incidental scratch use of `/tmp`
/// (not a bind mount — their own temp files) now round-trips through
/// VirtioFS like any other shared directory, rather than a local tmpfs.
/// Given the alternative is silent data loss on one of the most natural
/// paths a Mac user can type, that trade is made unconditionally by
/// default; see `docs/sharing.md` for the user-facing writeup.
///
/// If `/private/tmp` was never shared (a customized `shared_paths` without it,
/// or the mount failed), this reports `false` to the host. A current host then
/// rejects a literal `/tmp` bind source before it reaches dockerd; this log still
/// gives the necessary diagnosis to an older host that cannot consume the report.
/// Returns `true` only after the literal guest `/tmp` is mounted onto the live
/// `/private/tmp` share. The host uses this fact to admit a Docker bind source that
/// still spells `/tmp`; the mounted VirtioFS root alone is not proof that this second
/// mount worked.
pub fn alias_tmp_to_shared_private_tmp(share_results: &[(String, MountState)]) -> bool {
    let shared_tmp_is_live = share_results
        .iter()
        .any(|(path, state)| path == SHARED_TMP_PATH && *state == MountState::Mounted);

    if !shared_tmp_is_live {
        log::log(&format!(
            "{} is not a live host share (not in shared_paths, or it failed to mount) — \
             the guest's {} stays its own tmpfs, so a current host rejects a bare {} bind \
             source; use {} instead and see `morb doctor`'s shares-tmp check",
            SHARED_TMP_PATH, GUEST_TMP_PATH, GUEST_TMP_PATH, SHARED_TMP_PATH
        ));
        return false;
    }

    match sys::mount(SHARED_TMP_PATH, GUEST_TMP_PATH, "", sys::MS_BIND) {
        Ok(()) => {
            log::log(&format!(
                "bind-mounted {} onto {} — `-v /tmp/...` bind-mount sources now resolve the \
                 same way they do on the Mac itself",
                SHARED_TMP_PATH, GUEST_TMP_PATH
            ));
            true
        }
        Err(e) => {
            log::log(&format!(
                "WARNING: could not bind-mount {} onto {}: {} — a bind mount source under the \
                 bare, unresolved {} is rejected by a current host; use {} instead",
                SHARED_TMP_PATH, GUEST_TMP_PATH, e, GUEST_TMP_PATH, SHARED_TMP_PATH
            ));
            false
        }
    }
}

/// Mount every pseudo-filesystem PID 1 needs before anything else runs.
/// Idempotent: safe to call more than once (an already-mounted target
/// reports `EBUSY`, which we log and treat as success).
///
/// Docker's data root is *not* set up here — see `disk::provision`, which
/// must run after this because it needs `/dev` to exist before it can look
/// at `/dev/vda`.
pub fn early_mounts() {
    for spec in EARLY_MOUNTS {
        if let Err(e) = fs::create_dir_all(spec.target) {
            log::log(&format!(
                "mkdir -p {} failed: {} (mount will likely fail too)",
                spec.target, e
            ));
        }
        match sys::mount(spec.source, spec.target, spec.fstype, spec.flags) {
            Ok(()) => log::log(&format!("mounted {} at {}", spec.fstype, spec.target)),
            Err(e) if e.raw_os_error() == Some(sys::EBUSY) => {
                log::log(&format!(
                    "{} already mounted at {} (EBUSY, treating as ok)",
                    spec.fstype, spec.target
                ));
            }
            Err(e) => log::log(&format!(
                "WARNING: mount {} at {} failed: {}",
                spec.fstype, spec.target, e
            )),
        }
    }
}
