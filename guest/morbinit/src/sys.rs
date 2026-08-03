//! Raw libc FFI declarations and safe wrappers for the handful of Linux
//! syscalls morbinit needs as PID 1: mounting filesystems, setting the
//! hostname, reaping children, powering off, and listening on AF_VSOCK.
//!
//! This entire module is Linux-only (`#![cfg(target_os = "linux")]` below)
//! — none of it means anything on macOS. We declare the FFI by hand rather
//! than depending on the `libc` crate because Morbstack builds fully
//! offline with zero external dependencies anywhere in the tree (see
//! Cargo.toml). The declarations below are deliberately narrow: only the
//! constants, struct layouts, and function signatures morbinit actually
//! calls.
#![cfg(target_os = "linux")]
#![allow(dead_code)] // some wrappers (e.g. umount2) exist for completeness / future milestones.

use std::ffi::CString;
use std::io;
use std::os::fd::{FromRawFd, RawFd};
use std::os::raw::{c_char, c_int, c_ulong, c_void};

// ---- mount(2) flags (from linux/mount.h / sys/mount.h) ---------------------

pub const MS_RDONLY: c_ulong = 1;
pub const MS_NOSUID: c_ulong = 1 << 1;
pub const MS_NODEV: c_ulong = 1 << 2;
pub const MS_NOEXEC: c_ulong = 1 << 3;
pub const MS_REMOUNT: c_ulong = 1 << 5;
/// Bind-mount an existing directory (or file) onto another path instead of
/// mounting a filesystem. `fstype` is ignored by the kernel for this flag —
/// callers pass an empty string, which `mount()` below turns into a valid
/// (non-NULL, zero-length) C string rather than a NULL `data`/`fstype`
/// pointer, which is what the raw `mount(2)` wrapper otherwise reserves for
/// "no filesystem-specific option string".
pub const MS_BIND: c_ulong = 1 << 12;

/// `umount2(2)` flag: detach the mount from the tree immediately and clean
/// up once the last reference goes away. The escape hatch when a normal
/// unmount reports EBUSY.
pub const MNT_DETACH: c_int = 2;

/// errno for "device or resource busy" — returned by mount(2) when a target
/// is already mounted, which we tolerate (idempotent early_mounts).
pub const EBUSY: i32 = 16;
/// errno for "no child processes" — returned by waitpid(2) when there is
/// nothing left to reap.
const ECHILD: i32 = 10;

// ---- reboot(2), from linux/reboot.h ----------------------------------------

// The libc *wrapper* is `int reboot(int cmd)` — one argument. The two magic
// numbers (LINUX_REBOOT_MAGIC1 0xfee1dead, MAGIC2 0x28121969) that guard the
// raw syscall are supplied by the wrapper itself, and are deliberately not
// named here: declaring `reboot` with the raw syscall's four-argument shape
// and passing MAGIC1 first lands MAGIC1 in the `cmd` slot, which the kernel
// rejects with EINVAL. That failure is nastier than it sounds — power_off()
// returns an error, PID 1 falls off the end of main, and the kernel panics
// with "Attempted to kill init!" instead of halting, leaving the host to
// time out and pull the plug on a guest that had already flushed its disk.
pub const LINUX_REBOOT_CMD_POWER_OFF: c_int = 0x4321fedc;

// ---- waitpid(2) options -----------------------------------------------------

pub const WNOHANG: c_int = 1;

// ---- AF_VSOCK, from linux/vm_sockets.h -------------------------------------

pub const AF_VSOCK: c_int = 40;
pub const SOCK_STREAM: c_int = 1;
pub const VMADDR_CID_ANY: u32 = 0xffffffff;

// ---- shutdown(2) "how" values, from sys/socket.h ---------------------------

pub const SHUT_RD: c_int = 0;
pub const SHUT_WR: c_int = 1;
/// Disable both halves of a stream after a terminal relay error. Unlike a
/// directional EOF, this wakes the peer copy worker so the connection cannot
/// remain pinned behind an abandoned BuildKit/Engine session.
pub const SHUT_RDWR: c_int = 2;

// ---- signals we send to supervised services --------------------------------

/// Polite "please exit" — dockerd/containerd both install handlers for it
/// and use it to stop containers and flush their state cleanly.
pub const SIGTERM: c_int = 15;
/// Unignorable. Only used after `SIGTERM` has been given a grace period.
pub const SIGKILL: c_int = 9;
/// A write to a disconnected stream must return `EPIPE` to a relay worker,
/// never terminate the guest init while it is serving a streamed Docker API
/// response such as `docker cp`.
pub const SIGPIPE: c_int = 13;

// The C API expresses these special signal dispositions as function-pointer
// macros. Linux specifies `SIG_IGN` as the all-platform integer value 1 and
// reports an error from `signal(2)` as `(void *) -1`. Keeping their FFI form
// as pointer-sized integers avoids an invented callback for either special
// value and is valid for the musl/Linux deployment ABI used by morbinit.
const SIG_IGN_HANDLER: usize = 1;
const SIG_ERR_HANDLER: usize = usize::MAX;

/// `struct sockaddr_vm`, matching the kernel's `linux/vm_sockets.h` layout.
#[repr(C)]
#[derive(Clone, Copy)]
struct SockAddrVm {
    svm_family: u16,
    svm_reserved1: u16,
    svm_port: u32,
    svm_cid: u32,
    svm_zero: [u8; 4],
}

/// `struct pollfd`, from poll.h.
#[repr(C)]
struct PollFd {
    fd: c_int,
    events: i16,
    revents: i16,
}
const POLLIN: i16 = 0x0001;
const POLLOUT: i16 = 0x0004;

/// `struct utsname`, from sys/utsname.h. Field width is 65 bytes on Linux
/// (glibc and musl agree here).
#[repr(C)]
struct Utsname {
    sysname: [c_char; 65],
    nodename: [c_char; 65],
    release: [c_char; 65],
    version: [c_char; 65],
    machine: [c_char; 65],
    domainname: [c_char; 65],
}

/// The raw, unsafe FFI surface. Kept in its own module so the safe wrappers
/// below can reuse ordinary names (`mount`, `sync`, ...) without colliding
/// with these `extern "C"` declarations.
mod raw {
    use super::{c_char, c_int, c_ulong, c_void, PollFd, Utsname};

    extern "C" {
        pub fn mount(
            source: *const c_char,
            target: *const c_char,
            fstype: *const c_char,
            flags: c_ulong,
            data: *const c_void,
        ) -> c_int;
        pub fn umount2(target: *const c_char, flags: c_int) -> c_int;
        pub fn sethostname(name: *const c_char, len: usize) -> c_int;
        /// One argument, not four: see the LINUX_REBOOT_CMD_POWER_OFF note above.
        pub fn reboot(cmd: c_int) -> c_int;
        pub fn sync();
        pub fn waitpid(pid: i32, status: *mut c_int, options: c_int) -> i32;
        pub fn kill(pid: i32, sig: c_int) -> c_int;
        pub fn signal(signum: c_int, handler: usize) -> usize;
        pub fn getpid() -> i32;
        pub fn socket(domain: c_int, ty: c_int, protocol: c_int) -> c_int;
        pub fn bind(sockfd: c_int, addr: *const c_void, addrlen: u32) -> c_int;
        pub fn listen(sockfd: c_int, backlog: c_int) -> c_int;
        pub fn accept(sockfd: c_int, addr: *mut c_void, addrlen: *mut u32) -> c_int;
        pub fn close(fd: c_int) -> c_int;
        pub fn shutdown(sockfd: c_int, how: c_int) -> c_int;
        pub fn poll(fds: *mut PollFd, nfds: c_ulong, timeout: c_int) -> c_int;
        pub fn uname(buf: *mut Utsname) -> c_int;
    }
}

fn invalid_input(e: impl std::error::Error + Send + Sync + 'static) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, e)
}

/// Mount `source` (type `fstype`) at `target` with the given `mount(2)`
/// flags. `target` must already exist as a directory — callers are
/// responsible for `mkdir -p`'ing it first (see `mounts.rs`).
pub fn mount(source: &str, target: &str, fstype: &str, flags: c_ulong) -> io::Result<()> {
    mount_with_data(source, target, fstype, flags, None)
}

/// `mount(2)` with an explicit filesystem-specific option string — the
/// `-o` argument of the `mount` command, e.g.
/// `compress=zstd:1,discard=async` for btrfs.
///
/// `None` passes a NULL `data` pointer, which is what "mount with the
/// filesystem's own defaults" means at the syscall level; there is no
/// `"defaults"` string in `mount(2)` (that is a util-linux nicety).
pub fn mount_with_data(
    source: &str,
    target: &str,
    fstype: &str,
    flags: c_ulong,
    data: Option<&str>,
) -> io::Result<()> {
    let source_c = CString::new(source).map_err(invalid_input)?;
    let target_c = CString::new(target).map_err(invalid_input)?;
    let fstype_c = CString::new(fstype).map_err(invalid_input)?;
    let data_c = match data {
        Some(d) => Some(CString::new(d).map_err(invalid_input)?),
        None => None,
    };
    let data_ptr = match &data_c {
        Some(d) => d.as_ptr() as *const c_void,
        None => std::ptr::null(),
    };
    let ret = unsafe {
        raw::mount(
            source_c.as_ptr(),
            target_c.as_ptr(),
            fstype_c.as_ptr(),
            flags,
            data_ptr,
        )
    };
    if ret == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

/// Flip an existing mount to read-only in place: `mount(NULL, target, NULL,
/// MS_REMOUNT | MS_RDONLY, NULL)`.
///
/// For `MS_REMOUNT` the kernel identifies the filesystem from `target`
/// alone and ignores `source`/`fstype`, so both are passed as NULL — which
/// also means the caller does not have to remember which filesystem it
/// mounted there. Used on shutdown as the fallback when `/var/lib/docker`
/// cannot be unmounted outright: a read-only remount still forces a full
/// writeback of the filesystem's dirty state.
pub fn remount_readonly(target: &str) -> io::Result<()> {
    let target_c = CString::new(target).map_err(invalid_input)?;
    let ret = unsafe {
        raw::mount(
            std::ptr::null(),
            target_c.as_ptr(),
            std::ptr::null(),
            MS_REMOUNT | MS_RDONLY,
            std::ptr::null(),
        )
    };
    if ret == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

/// `sync(2)`: flush every filesystem's dirty pages to its backing device.
/// Cannot fail.
pub fn sync() {
    unsafe { raw::sync() };
}

/// Send signal `sig` to `pid`. Used by the supervisor's shutdown sequence,
/// which needs SIGTERM-then-SIGKILL semantics that `std::process::Child`
/// does not offer (`Child::kill` is SIGKILL only).
pub fn kill(pid: i32, sig: c_int) -> io::Result<()> {
    let ret = unsafe { raw::kill(pid, sig) };
    if ret == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

/// Unmount `target`.
pub fn umount2(target: &str, flags: c_int) -> io::Result<()> {
    let target_c = CString::new(target).map_err(invalid_input)?;
    let ret = unsafe { raw::umount2(target_c.as_ptr(), flags) };
    if ret == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

/// Set the kernel hostname. `sethostname(2)` takes an explicit length
/// rather than requiring a NUL terminator, so we pass the raw UTF-8 bytes
/// directly.
pub fn set_hostname(name: &str) -> io::Result<()> {
    let ret = unsafe { raw::sethostname(name.as_ptr() as *const c_char, name.len()) };
    if ret == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

/// `sync(2)` followed by `reboot(RB_POWER_OFF)`. On success this does not
/// return in practice (the kernel halts the machine); the `Ok(())` case
/// exists mainly for API symmetry and testability of callers.
pub fn power_off() -> io::Result<()> {
    sync();
    let ret = unsafe { raw::reboot(LINUX_REBOOT_CMD_POWER_OFF) };
    if ret == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

/// The current process's PID, via `getpid(2)`. Used at startup to decide
/// whether morbinit is really running as PID 1.
pub fn getpid() -> i32 {
    unsafe { raw::getpid() }
}

/// Make broken stream writes report `EPIPE` instead of delivering `SIGPIPE`.
///
/// `morbinit` relays arbitrary Docker traffic through accepted AF_VSOCK fds.
/// The Rust `File` used for that accepted endpoint ultimately calls `write(2)`,
/// whose default broken-pipe disposition would terminate the whole process.
/// This process-wide setting must be made before the relay threads start;
/// callers then handle the ordinary I/O error and tear their connection down.
pub fn ignore_sigpipe() -> io::Result<()> {
    let previous = unsafe { raw::signal(SIGPIPE, SIG_IGN_HANDLER) };
    if previous == SIG_ERR_HANDLER {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

/// Non-blocking reap of a single exited (or otherwise state-changed) child,
/// via `waitpid(-1, WNOHANG)`. This is the "any child" form PID 1 needs to
/// reap re-parented orphans, not just the services it spawned itself
/// directly (those are also reaped this way by the supervisor's tick loop —
/// see `supervisor.rs`).
///
/// Returns `Ok(None)` both when there's nothing currently exited (`pid ==
/// 0`) and when there are no children at all (`ECHILD`) — both are
/// unremarkable steady-state outcomes for an init process, not errors.
pub fn wait_any_nonblocking() -> io::Result<Option<(i32, i32)>> {
    let mut status: c_int = 0;
    let pid = unsafe { raw::waitpid(-1, &mut status as *mut c_int, WNOHANG) };
    if pid > 0 {
        Ok(Some((pid, status)))
    } else if pid == 0 {
        Ok(None)
    } else {
        let err = io::Error::last_os_error();
        if err.raw_os_error() == Some(ECHILD) {
            Ok(None)
        } else {
            Err(err)
        }
    }
}

/// Poll a single fd for readability with a millisecond timeout. Returns
/// `Ok(true)` if the fd became readable before the timeout, `Ok(false)` on
/// timeout.
pub fn poll_readable(fd: RawFd, timeout_ms: i32) -> io::Result<bool> {
    let mut pfd = PollFd {
        fd,
        events: POLLIN,
        revents: 0,
    };
    let ret = unsafe { raw::poll(&mut pfd as *mut PollFd, 1, timeout_ms) };
    if ret < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(ret > 0 && (pfd.revents & POLLIN) != 0)
    }
}

/// Poll a single fd for writability with a millisecond timeout. Returns
/// `Ok(true)` if the fd became writable before the timeout, `Ok(false)` on
/// timeout.
///
/// The mirror image of `poll_readable`, and used for the same reason: the
/// vsock fds are plain `std::fs::File`s with no socket timeout knobs, so a
/// "write this if you can, but never block on it" needs `poll(2)` in front
/// of it (see `dial.rs`'s busy reply).
pub fn poll_writable(fd: RawFd, timeout_ms: i32) -> io::Result<bool> {
    let mut pfd = PollFd {
        fd,
        events: POLLOUT,
        revents: 0,
    };
    let ret = unsafe { raw::poll(&mut pfd as *mut PollFd, 1, timeout_ms) };
    if ret < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(ret > 0 && (pfd.revents & POLLOUT) != 0)
    }
}

/// Half-close a socket fd: `shutdown(fd, SHUT_WR)` sends EOF to the peer
/// while leaving our read side open, which is exactly what a bidirectional
/// byte-stream proxy needs when one direction drains (see `proxy.rs`).
///
/// Takes a raw fd rather than a typed socket because the vsock side of the
/// proxy is a `std::fs::File` wrapping an `accept(2)`ed fd (see
/// `VsockListener::accept`), which has no `shutdown` method of its own.
pub fn shutdown_write(fd: RawFd) -> io::Result<()> {
    shutdown(fd, SHUT_WR)
}

/// `shutdown(2)` with an explicit `how`.
pub fn shutdown(fd: RawFd, how: c_int) -> io::Result<()> {
    let ret = unsafe { raw::shutdown(fd, how) };
    if ret == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

/// The kernel release string (e.g. `"6.6.30"`), via `uname(2)`.
pub fn uname_release() -> io::Result<String> {
    let mut buf: Utsname = unsafe { std::mem::zeroed() };
    let ret = unsafe { raw::uname(&mut buf as *mut Utsname) };
    if ret != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: uname(2) succeeded, so `release` is a NUL-terminated C string
    // within the buffer we just initialized.
    let cstr = unsafe { std::ffi::CStr::from_ptr(buf.release.as_ptr()) };
    Ok(cstr.to_string_lossy().into_owned())
}

/// A bound, listening AF_VSOCK socket. `accept()` hands back a plain
/// `std::fs::File` — `File`'s `Read`/`Write` impls are just `read(2)` /
/// `write(2)` against the wrapped fd, which works identically for a
/// connected socket fd, so the rest of morbinit (see `control.rs`) can
/// treat a vsock connection as an ordinary `Read + Write` stream.
pub struct VsockListener {
    fd: RawFd,
}

impl VsockListener {
    /// Bind and listen on `port`, accepting connections from any CID. Only
    /// the host hypervisor can dial into this guest's vsock address space
    /// at all, so we don't need to filter by CID ourselves.
    pub fn bind(port: u32) -> io::Result<Self> {
        let fd = unsafe { raw::socket(AF_VSOCK, SOCK_STREAM, 0) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let addr = SockAddrVm {
            svm_family: AF_VSOCK as u16,
            svm_reserved1: 0,
            svm_port: port,
            svm_cid: VMADDR_CID_ANY,
            svm_zero: [0; 4],
        };
        let bind_ret = unsafe {
            raw::bind(
                fd,
                &addr as *const SockAddrVm as *const c_void,
                std::mem::size_of::<SockAddrVm>() as u32,
            )
        };
        if bind_ret < 0 {
            let err = io::Error::last_os_error();
            unsafe { raw::close(fd) };
            return Err(err);
        }
        let listen_ret = unsafe { raw::listen(fd, 16) };
        if listen_ret < 0 {
            let err = io::Error::last_os_error();
            unsafe { raw::close(fd) };
            return Err(err);
        }
        Ok(Self { fd })
    }

    /// Block until a host connection arrives.
    pub fn accept(&self) -> io::Result<std::fs::File> {
        let ret = unsafe { raw::accept(self.fd, std::ptr::null_mut(), std::ptr::null_mut()) };
        if ret < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: `ret` is a freshly accept()ed, uniquely-owned fd.
        Ok(unsafe { std::fs::File::from_raw_fd(ret) })
    }

    pub fn as_raw_fd(&self) -> RawFd {
        self.fd
    }
}

impl Drop for VsockListener {
    fn drop(&mut self) {
        unsafe { raw::close(self.fd) };
    }
}
