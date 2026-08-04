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
//!   * `morbinit` ignores `SIGPIPE` before this listener starts. A cancelled
//!     archive/build receiver therefore surfaces as `EPIPE` here and releases
//!     only its relay, rather than terminating guest PID 1.
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

/// The reason word `dial::BUSY_REASON` uses for its own connection-cap
/// rejection, reused here so every over-capacity guest listener reports the
/// same stable, matchable word.
pub const BUSY_REASON: &str = "busy";

/// The HTTP response morbinit writes when the Docker relay is at its
/// connection cap, immediately before closing the connection.
///
/// This port carries plain HTTP/1.1 with no framing of its own (see the
/// module docs), and its peer is always an HTTP client — so unlike
/// `dial.rs`'s line-oriented `ERR busy\n`, the busy signal here has to *be*
/// a well-formed HTTP response, or the client's own parser sees an
/// unparseable reply rather than a server error it already knows how to
/// render.
///
/// `mac/Sources/MorbstackKit/DockerFramedRelay.swift`'s response side
/// (`runResponseSide`, `.passthrough` mode) relays whatever bytes the guest
/// writes back to the real client unmodified — it does not require a
/// hijack, a particular status line, or any cooperation beyond "valid
/// HTTP" — so this reaches the Docker client exactly as if dockerd itself
/// had answered. `503 Service Unavailable` is the correct status for
/// exactly this ("temporarily unable to handle the request"), and pairs
/// with the host's own synthetic `502 Bad Gateway`
/// (`DockerProxy.writeGatewayError`, used when the guest cannot be reached
/// at all): together the two codes let a client tell "no guest to ask" (host
/// 502) apart from "guest reachable, relay saturated" (guest 503). The JSON
/// body, `{"message": "..."}`, is exactly `DockerEngineErrorResponse`'s
/// shape on the host side and the shape the real Docker Engine API uses for
/// its own errors, so the `docker` CLI's ordinary error rendering picks it
/// up without special-casing morbstack. `Connection: close` is not just
/// convention here — the guest is about to close the vsock connection
/// outright, and a client that thought it could keep the socket alive would
/// be wrong.
///
/// Portable (no vsock needed) so it unit tests directly; see
/// `the_busy_rejection_is_a_well_formed_http_response` below.
pub fn busy_response() -> Vec<u8> {
    let body = format!(
        "{{\"message\":\"morbstack: docker relay is {} (connection cap of {} reached); retry\"}}",
        BUSY_REASON, MAX_CONNECTIONS
    );
    let mut response = format!(
        "HTTP/1.1 503 Service Unavailable\r\n\
         Content-Type: application/json\r\n\
         Content-Length: {}\r\n\
         Connection: close\r\n\
         \r\n",
        body.len()
    );
    response.push_str(&body);
    response.into_bytes()
}

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
                    ));
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
    use super::{busy_response, copy_stream, DOCKER_SOCK, MAX_CONNECTIONS, VSOCK_DOCKER_PORT};
    use crate::log;
    use crate::sys;
    use std::io::{self, Write};
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

    /// How long the busy HTTP response has to reach the host before we give
    /// up on it and close anyway. Mirrors `dial::BUSY_REPLY_TIMEOUT_MS`: the
    /// reply lands on a socket that just finished its vsock handshake, so
    /// this bound is only ever spent on a peer that is already gone.
    const BUSY_REPLY_TIMEOUT_MS: i32 = 250;

    /// Decrements the live-connection counter however the handler thread
    /// exits (return, error, or panic).
    struct ConnGuard(Arc<AtomicUsize>);

    impl Drop for ConnGuard {
        fn drop(&mut self) {
            self.0.fetch_sub(1, Ordering::SeqCst);
        }
    }

    /// Best-effort busy rejection on a connection about to be refused.
    ///
    /// Same discipline as `dial::send_busy`: `poll(2)` bounds the wait so a
    /// wedged peer cannot stall the accept loop, and any failure — including
    /// the timeout — just falls through to closing the connection, which is
    /// what happened before this existed.
    fn send_busy(mut conn: std::fs::File) {
        let reply = busy_response();
        match sys::poll_writable(conn.as_raw_fd(), BUSY_REPLY_TIMEOUT_MS) {
            Ok(true) => {
                if let Err(e) = conn.write_all(&reply) {
                    log::log(&format!(
                        "could not send the docker proxy busy rejection: {}",
                        e
                    ));
                }
            }
            Ok(false) => log::log(
                "docker proxy busy rejection could not be sent within its timeout — \
                 closing the connection instead",
            ),
            Err(e) => log::log(&format!(
                "could not poll a rejected docker proxy connection for writability: {} \
                 — closing it instead",
                e
            )),
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
                    "docker proxy at connection cap ({}) — rejecting new vsock \
                     connection with an HTTP 503",
                    MAX_CONNECTIONS
                ));
                // Say so before hanging up, matching dial.rs: closing silently
                // makes documented backpressure indistinguishable from a peer
                // that never spoke HTTP at all.
                send_busy(conn);
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
    ///
    /// The accepted vsock belongs to one Docker CLI connection.  Keep retrying
    /// for a real client, but do not hold one of the bounded proxy slots for the
    /// whole startup timeout after that client has cancelled.  The disconnect
    /// probe intentionally ignores a directional EOF: `docker build -` and
    /// interactive execs may be finished writing while still awaiting output.
    fn connect_dockerd(vsock_fd: RawFd, timeout: Duration) -> io::Result<UnixStream> {
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
            let wait = std::cmp::min(backoff, deadline.saturating_duration_since(Instant::now()));
            let wait_millis = wait.as_millis().min(i32::MAX as u128) as i32;
            match sys::poll_disconnected(vsock_fd, wait_millis) {
                Ok(true) => {
                    return Err(io::Error::new(
                        io::ErrorKind::ConnectionAborted,
                        "Docker client disconnected while waiting for dockerd",
                    ));
                }
                Ok(false) => {}
                Err(e) => {
                    return Err(io::Error::new(
                        e.kind(),
                        format!("watching Docker client while dockerd restarts: {}", e),
                    ));
                }
            }
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
        let vsock_fd = vsock.as_raw_fd();
        let unix = connect_dockerd(vsock_fd, DOCKERD_CONNECT_TIMEOUT).map_err(|e| {
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

    #[test]
    fn the_busy_rejection_is_a_well_formed_http_response() {
        // Connection-cap backpressure used to close the vsock connection
        // silently, which an HTTP client on the other end reports as a bare
        // reset rather than a diagnosable server error. It has to arrive as
        // an ordinary, parseable HTTP response instead — the same
        // `{"message": ...}` shape the real Docker Engine API (and the
        // host's own synthetic errors) already use.
        let response = busy_response();
        let text = String::from_utf8(response).expect("busy response is valid UTF-8");

        let (head, body) = text
            .split_once("\r\n\r\n")
            .expect("response has a head/body separator");
        assert!(head.starts_with("HTTP/1.1 503 Service Unavailable\r\n"));
        let header_lines: Vec<&str> = head.lines().skip(1).collect();
        assert!(header_lines.contains(&"Connection: close"));
        assert!(header_lines.contains(&"Content-Type: application/json"));

        let content_length: usize = head
            .lines()
            .find_map(|line| line.strip_prefix("Content-Length: "))
            .expect("response declares Content-Length")
            .parse()
            .expect("Content-Length is a decimal number");
        assert_eq!(content_length, body.len());

        assert!(body.starts_with('{') && body.ends_with('}'));
        assert!(
            body.contains(BUSY_REASON),
            "body {:?} should contain the stable reason word {:?}",
            body,
            BUSY_REASON
        );
        // Every header line and the body are exactly one line each — nothing
        // downstream can smuggle a second status line or an extra frame.
        assert!(!body.contains('\n'));
    }
}
