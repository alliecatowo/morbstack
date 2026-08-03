//! The Docker Engine API relay: AF_VSOCK port 2375 in the guest, forwarded
//! byte-for-byte to dockerd's Unix socket.
//!
//! Why this exists: the host's `DockerProxy` dials the guest on vsock port
//! 2375 and speaks plain HTTP to it, but dockerd deliberately does **not**
//! listen on TCP — an unauthenticated TCP Docker API is root-equivalent
//! access to the VM for anything else that can reach the NAT subnet, and
//! nothing in the guest binds AF_VSOCK on dockerd's behalf. So morbinit owns
//! that socket: it binds vsock 2375, and for every accepted connection opens
//! a *fresh* connection to `/var/run/docker.sock` and shuttles bytes both
//! ways until each direction closes.
//!
//! Design notes:
//!   * One connection is one dockerd connection. The Docker Engine API is
//!     HTTP/1.1 with hijacked upgrades (attach, exec, build, log follow), so
//!     multiplexing several vsock connections onto one Unix socket is not an
//!     option and neither is parsing the stream — this is a dumb pipe.
//!   * Half-close aware: when one direction hits EOF we `shutdown(SHUT_WR)`
//!     the *other* endpoint rather than tearing the whole connection down,
//!     so `docker build -` / `docker run -i` style "client closed stdin,
//!     still wants the response" flows work.
//!   * A terminal read/write error is different from EOF: it shuts down both
//!     endpoints, waking the opposite copy worker. This releases the bounded
//!     connection slot when a client cancels a streamed BuildKit session.
//!   * Bounded concurrency (`MAX_CONNECTIONS`), because each connection
//!     costs two threads and PID 1 must not be DoS-able into thread
//!     exhaustion.
//!
//! `copy_stream` is deliberately written over generic `Read`/`Write` so it
//! compiles and unit-tests on the macOS dev host; only the vsock listener
//! and `shutdown(2)` plumbing are Linux-only.

use std::io::{self, Read, Write};

/// Path dockerd is told to listen on (`--host unix://...`), and therefore
/// the path this proxy dials. Single source of truth: `supervisor.rs` builds
/// dockerd's argv from this same constant.
pub const DOCKER_SOCK: &str = "/var/run/docker.sock";

/// vsock port the Docker Engine API stream is served on, per the shared
/// contract's port registry (1024 = MRB0 control, 2375 = Docker API).
pub const VSOCK_DOCKER_PORT: u32 = 2375;

/// Upper bound on simultaneously proxied Docker connections. The Docker CLI
/// opens a handful at a time; 64 leaves generous headroom while capping
/// thread usage at ~128 threads worst case.
const MAX_CONNECTIONS: usize = 64;

/// Copy buffer size. 64 KiB is comfortably above the typical Docker API
/// response chunk and keeps syscall counts low for image pulls/pushes.
const COPY_BUF_LEN: usize = 64 * 1024;

/// Copy every byte from `src` to `dst` until `src` reports EOF.
///
/// Unlike `io::copy` this is explicit about the two things that matter here:
/// `EINTR` is retried rather than surfaced (PID 1 takes signals), and short
/// writes are looped until the whole chunk lands, so no data is ever
/// silently truncated. Returns the number of bytes copied.
pub fn copy_stream<R: Read + ?Sized, W: Write + ?Sized>(
    src: &mut R,
    dst: &mut W,
) -> io::Result<u64> {
    let mut buf = vec![0u8; COPY_BUF_LEN];
    let mut total: u64 = 0;
    loop {
        let n = match src.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        };
        let mut written = 0usize;
        while written < n {
            match dst.write(&buf[written..n]) {
                Ok(0) => {
                    return Err(io::Error::new(
                        io::ErrorKind::WriteZero,
                        "peer accepted 0 bytes; refusing to spin",
                    ))
                }
                Ok(w) => written += w,
                Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(e),
            }
        }
        total += n as u64;
    }
    dst.flush()?;
    Ok(total)
}

// ---------------------------------------------------------------------------
// Everything below talks to dockerd and/or AF_VSOCK, so it is Linux-only.
// ---------------------------------------------------------------------------

#[cfg(target_os = "linux")]
mod imp {
    use super::{copy_stream, DOCKER_SOCK, MAX_CONNECTIONS, VSOCK_DOCKER_PORT};
    use crate::log;
    use crate::sys;
    use std::io;
    use std::net::Shutdown;
    use std::os::fd::{AsRawFd, RawFd};
    use std::os::unix::net::UnixStream;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::thread;
    use std::time::{Duration, Instant};

    /// How long a freshly accepted connection will keep retrying the connect
    /// to dockerd's socket before giving up. Generous because the first
    /// `docker` command usually races dockerd's own startup.
    const DOCKERD_CONNECT_TIMEOUT: Duration = Duration::from_secs(60);
    const DOCKERD_CONNECT_INITIAL_BACKOFF: Duration = Duration::from_millis(50);
    const DOCKERD_CONNECT_MAX_BACKOFF: Duration = Duration::from_millis(500);

    /// Decrements the live-connection counter however the handler thread
    /// exits (return, error, or panic).
    struct ConnGuard(Arc<AtomicUsize>);

    impl Drop for ConnGuard {
        fn drop(&mut self) {
            self.0.fetch_sub(1, Ordering::SeqCst);
        }
    }

    /// Bind vsock 2375 and serve it from a dedicated thread.
    ///
    /// Binding happens on the caller's thread so a failure is reported at
    /// boot (where it can be logged next to the rest of the init sequence)
    /// rather than disappearing into a detached thread.
    pub fn spawn_docker_proxy() -> io::Result<()> {
        let listener = sys::VsockListener::bind(VSOCK_DOCKER_PORT)?;
        log::log(&format!(
            "docker proxy listening on vsock port {} -> {}",
            VSOCK_DOCKER_PORT, DOCKER_SOCK
        ));
        thread::Builder::new()
            .name("docker-proxy".to_string())
            .spawn(move || accept_loop(listener))?;
        Ok(())
    }

    fn accept_loop(listener: sys::VsockListener) {
        let live = Arc::new(AtomicUsize::new(0));
        loop {
            let conn = match listener.accept() {
                Ok(c) => c,
                Err(e) => {
                    log::log(&format!("docker proxy accept error: {}", e));
                    // Don't hot-spin if the listener is wedged.
                    thread::sleep(Duration::from_millis(100));
                    continue;
                }
            };

            if live.load(Ordering::SeqCst) >= MAX_CONNECTIONS {
                log::log(&format!(
                    "docker proxy at connection cap ({}) — dropping new vsock connection",
                    MAX_CONNECTIONS
                ));
                drop(conn); // closes the fd; host sees the connection close
                continue;
            }

            live.fetch_add(1, Ordering::SeqCst);
            let live_for_thread = Arc::clone(&live);
            let spawned = thread::Builder::new()
                .name("docker-proxy-conn".to_string())
                .spawn(move || {
                    let _guard = ConnGuard(live_for_thread);
                    if let Err(e) = handle_connection(conn) {
                        log::log(&format!("docker proxy connection ended: {}", e));
                    }
                });
            if let Err(e) = spawned {
                // The guard never got constructed, so undo the increment here.
                live.fetch_sub(1, Ordering::SeqCst);
                log::log(&format!("docker proxy could not spawn handler: {}", e));
            }
        }
    }

    /// Dial dockerd's Unix socket, retrying with backoff while dockerd is
    /// still coming up (or restarting after a crash).
    fn connect_dockerd(timeout: Duration) -> io::Result<UnixStream> {
        let deadline = Instant::now() + timeout;
        let mut backoff = DOCKERD_CONNECT_INITIAL_BACKOFF;
        loop {
            let last_err = match UnixStream::connect(DOCKER_SOCK) {
                Ok(s) => return Ok(s),
                Err(e) => e,
            };
            if Instant::now() >= deadline {
                return Err(last_err);
            }
            thread::sleep(backoff);
            backoff = std::cmp::min(backoff * 2, DOCKERD_CONNECT_MAX_BACKOFF);
        }
    }

    /// Abort both halves of a relay after a terminal I/O error.
    ///
    /// A clean EOF is directional and must remain a half-close: a client can
    /// finish sending a Dockerfile or BuildKit session request while still
    /// waiting for the build result. A read/write *error* means its peer is
    /// no longer usable, though. Leaving the other copy worker blocked in
    /// that case makes `handle_connection` wait forever in `join`, consuming
    /// one of the proxy's bounded slots after a cancelled build or session.
    /// `shutdown` operates on the underlying socket, so either duplicated fd
    /// safely wakes the reader and writer clones owned by the two workers.
    fn abort_relay(vsock_fd: RawFd, dockerd_fd: RawFd) {
        let _ = sys::shutdown(vsock_fd, sys::SHUT_RDWR);
        let _ = sys::shutdown(dockerd_fd, sys::SHUT_RDWR);
    }

    /// Splice one accepted vsock connection to a fresh dockerd connection.
    fn handle_connection(vsock: std::fs::File) -> io::Result<()> {
        let unix = connect_dockerd(DOCKERD_CONNECT_TIMEOUT).map_err(|e| {
            io::Error::new(
                e.kind(),
                format!("connect {}: {} (is dockerd running?)", DOCKER_SOCK, e),
            )
        })?;

        // Two independent handles per endpoint: each direction owns one
        // reader and one writer, so neither thread has to lock the other out.
        let mut vsock_read = vsock;
        let mut vsock_write = vsock_read.try_clone()?;
        let mut unix_read = unix;
        let mut unix_write = unix_read.try_clone()?;
        let vsock_write_fd = vsock_write.as_raw_fd();
        let vsock_abort_fd = vsock_read.as_raw_fd();
        let dockerd_abort_fd = unix_read.as_raw_fd();
        let aborted = Arc::new(AtomicBool::new(false));

        // host -> dockerd
        let up_aborted = Arc::clone(&aborted);
        let up = thread::Builder::new()
            .name("docker-proxy-up".to_string())
            .spawn(move || {
                if let Err(e) = copy_stream(&mut vsock_read, &mut unix_write) {
                    log::log(&format!("docker proxy host->dockerd copy error: {}", e));
                    if !up_aborted.swap(true, Ordering::SeqCst) {
                        abort_relay(vsock_abort_fd, dockerd_abort_fd);
                    }
                    return;
                }
                // EOF from the host: tell dockerd no more request bytes are
                // coming, but leave its response direction open.
                let _ = unix_write.shutdown(Shutdown::Write);
            })?;

        // dockerd -> host
        if let Err(e) = copy_stream(&mut unix_read, &mut vsock_write) {
            log::log(&format!("docker proxy dockerd->host copy error: {}", e));
            if !aborted.swap(true, Ordering::SeqCst) {
                abort_relay(vsock_abort_fd, dockerd_abort_fd);
            }
        } else {
            // dockerd finished responding: half-close the vsock so the host's
            // HTTP client sees a clean end-of-response instead of hanging.
            let _ = sys::shutdown_write(vsock_write_fd);
        }

        let _ = up.join();
        Ok(())
    }

    /// Watch for dockerd becoming reachable and announce it exactly once.
    ///
    /// The host's readiness check keys off the `MORBINIT: docker-ready`
    /// console line, and the MRB0 `info` reply exposes the same fact as
    /// `docker_ready`.
    pub fn spawn_ready_monitor(flag: Arc<AtomicBool>) {
        let spawned = thread::Builder::new()
            .name("docker-ready".to_string())
            .spawn(move || {
                let mut attempts: u64 = 0;
                loop {
                    match UnixStream::connect(DOCKER_SOCK) {
                        Ok(s) => {
                            drop(s);
                            flag.store(true, Ordering::SeqCst);
                            log::log("MORBINIT: docker-ready");
                            return;
                        }
                        Err(e) => {
                            attempts += 1;
                            // ~every 15s, so a wedged dockerd is visible in
                            // the console log without flooding it.
                            if attempts.is_multiple_of(30) {
                                log::log(&format!(
                                    "still waiting for dockerd at {} after {} attempts: {}",
                                    DOCKER_SOCK, attempts, e
                                ));
                            }
                        }
                    }
                    thread::sleep(Duration::from_millis(500));
                }
            });
        if let Err(e) = spawned {
            log::log(&format!("could not spawn docker readiness monitor: {}", e));
        }
    }
}

#[cfg(target_os = "linux")]
pub use imp::{spawn_docker_proxy, spawn_ready_monitor};

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn copy_stream_copies_everything_including_past_one_buffer() {
        // Deliberately larger than COPY_BUF_LEN so the loop runs more than
        // once — a truncating implementation would fail here.
        let src_data: Vec<u8> = (0..(COPY_BUF_LEN * 2 + 12345))
            .map(|i| (i % 251) as u8)
            .collect();
        let mut src = Cursor::new(src_data.clone());
        let mut dst: Vec<u8> = Vec::new();
        let n = copy_stream(&mut src, &mut dst).unwrap();
        assert_eq!(n as usize, src_data.len());
        assert_eq!(dst, src_data);
    }

    #[test]
    fn copy_stream_on_empty_source_is_a_clean_zero() {
        let mut src = Cursor::new(Vec::new());
        let mut dst: Vec<u8> = Vec::new();
        assert_eq!(copy_stream(&mut src, &mut dst).unwrap(), 0);
        assert!(dst.is_empty());
    }

    /// A writer that only accepts a few bytes per `write` call, to prove the
    /// inner loop handles short writes without dropping data.
    struct DribbleWriter {
        sink: Vec<u8>,
        chunk: usize,
    }

    impl Write for DribbleWriter {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            let n = std::cmp::min(self.chunk, buf.len());
            self.sink.extend_from_slice(&buf[..n]);
            Ok(n)
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn copy_stream_tolerates_short_writes_without_truncating() {
        let src_data: Vec<u8> = (0..5000).map(|i| (i % 97) as u8).collect();
        let mut src = Cursor::new(src_data.clone());
        let mut dst = DribbleWriter {
            sink: Vec::new(),
            chunk: 7,
        };
        let n = copy_stream(&mut src, &mut dst).unwrap();
        assert_eq!(n as usize, src_data.len());
        assert_eq!(dst.sink, src_data);
    }

    /// A reader that returns `Interrupted` before yielding its data, to
    /// prove EINTR is retried rather than reported as a failure.
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
    fn copy_stream_retries_eintr() {
        let mut src = InterruptingReader {
            interrupts_left: 3,
            inner: Cursor::new(b"docker api bytes".to_vec()),
        };
        let mut dst: Vec<u8> = Vec::new();
        let n = copy_stream(&mut src, &mut dst).unwrap();
        assert_eq!(n, 16);
        assert_eq!(dst, b"docker api bytes");
    }
}
