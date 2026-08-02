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
