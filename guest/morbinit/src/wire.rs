//! Shared wire-level plumbing for morbinit's vsock listeners.
//!
//! Every port morbinit serves — the stream dialer (`dial.rs`), the datagram
//! dialer (`datagram.rs`), the k8s payload installer (`k8s.rs`), the Docker
//! API relay (`proxy.rs`), the live-share receiver (`live_share_receiver.rs`)
//! and the MRB0 control server (`control.rs`) — independently grew the same
//! handful of primitives for the same reasons. This module is their one
//! shared home:
//!
//!   * [`read_preamble_line`] / [`read_install_preamble_line`]: byte-at-a-time
//!     newline readers. Byte-at-a-time is deliberate everywhere it is used —
//!     a buffered read would swallow bytes that belong to whatever comes
//!     right after the preamble (a spliced stream, a frame header, the next
//!     protocol line), and there is nowhere to put them back. The two
//!     functions are two distinct, independently-preserved flavors rather
//!     than one knob-laden function — see their doc comments for exactly how
//!     they differ (CR handling, EINTR retry, terminator handling, UTF-8
//!     strictness) and why that is `k8s.rs`'s behavior, not a bug introduced
//!     here.
//!   * [`err_line`]: the `"ERR <reason>\n"` reply builder shared by `dial.rs`
//!     and `datagram.rs`, whose line-oriented protocols are byte-identical in
//!     this one respect.
//!   * [`ConnGuard`]: the fetch_add/fetch_sub RAII connection-count guard
//!     every bounded accept loop in this crate used to define for itself
//!     (as `ConnGuard` in four places and `ConnectionGuard` in a fifth, all
//!     with identical semantics).
//!   * (Linux-only, since both need real polling) [`DeadlineStream`], the
//!     poll-bounded `Read`/`Write` wrapper used while a preamble is still
//!     being negotiated, and [`send_best_effort`], the poll-bounded
//!     best-effort write used to answer a connection that is about to be
//!     refused for being over a listener's connection cap.
//!
//! What is deliberately **not** here: the reply *payload* each port sends
//! when busy — `dial::err_line(dial::BUSY_REASON)`,
//! `live_share_receiver::busy_line()`, `control::busy_frame()`,
//! `proxy::busy_response()`. Those differ **by design**: a line, a
//! length-prefixed MRB0 frame, and a well-formed HTTP/1.1 503 are three
//! different wire formats for three different clients, and each one belongs
//! next to the protocol that defines it. Only the mechanical bounded-wait
//! send is shared.

#[cfg(target_os = "linux")]
use std::io::Write;
use std::io::{self, Read};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

// ---------------------------------------------------------------------------
// Preamble line readers. Portable: plain `Read`, so they unit test with
// in-memory streams on the macOS dev host exactly like their callers already
// did before this extraction.
// ---------------------------------------------------------------------------

/// Knobs `read_preamble_raw` needs to reproduce either flavor below exactly.
/// Not `pub`: this is an implementation detail shared by the two named
/// flavors, not a general-purpose "configure your own preamble reader" API.
struct PreambleReadPolicy {
    /// Longest line accepted. What counts toward it depends on `drop_cr`:
    /// see the flavor doc comments.
    max: usize,
    /// Retry a `read` that returns `ErrorKind::Interrupted` instead of
    /// surfacing it as an error.
    retry_on_interrupted: bool,
    /// Drop every `\r` byte as it is read — never buffered, never counted
    /// toward `max` — instead of keeping it as ordinary line data.
    drop_cr: bool,
    /// Include the trailing `\n` in the returned bytes.
    keep_terminator: bool,
    too_long: fn(usize) -> String,
    eof: &'static str,
}

/// The byte-at-a-time loop shared by both preamble flavors. Returns the raw
/// line bytes (terminator handling per `policy.keep_terminator`); the two
/// public wrappers below turn that into a `String` their own way.
fn read_preamble_raw<R: Read>(r: &mut R, policy: &PreambleReadPolicy) -> io::Result<Vec<u8>> {
    let mut buf = Vec::with_capacity(16);
    let mut byte = [0u8; 1];
    loop {
        if buf.len() >= policy.max {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                (policy.too_long)(policy.max),
            ));
        }
        match r.read(&mut byte) {
            Ok(0) => return Err(io::Error::new(io::ErrorKind::UnexpectedEof, policy.eof)),
            Ok(_) => {
                if byte[0] == b'\n' {
                    if policy.keep_terminator {
                        buf.push(byte[0]);
                    }
                    break;
                }
                if policy.drop_cr && byte[0] == b'\r' {
                    continue;
                }
                buf.push(byte[0]);
            }
            Err(ref e) if policy.retry_on_interrupted && e.kind() == io::ErrorKind::Interrupted => {
                continue
            }
            Err(e) => return Err(e),
        }
    }
    Ok(buf)
}

/// Read one newline-terminated line, at most `max` bytes including the
/// newline, one byte per `read` call.
///
/// Used by `dial.rs`'s stream dialer, `datagram.rs`'s datagram dialer, and
/// `live_share_receiver.rs`'s authenticated line protocol — all three
/// treated this identically before this extraction. Behavior:
///
///   * A `read` returning `ErrorKind::Interrupted` is retried, since PID 1
///     takes signals.
///   * `\r` is ordinary line data: kept in the buffer and counted toward
///     `max` like any other byte. A caller that wants to tolerate CRLF (as
///     `dial::parse_preamble` and `datagram::parse_preamble` do) strips a
///     single trailing `\r` itself, after the fact.
///   * The returned string includes the trailing `\n` (and a trailing `\r`,
///     if present).
///   * The line must be valid UTF-8 or the read fails outright.
///
/// `max` bounds the total bytes read before giving up, which is what stops a
/// peer that never sends a newline from making the caller read forever.
pub fn read_preamble_line<R: Read>(r: &mut R, max: usize) -> io::Result<String> {
    let policy = PreambleReadPolicy {
        max,
        retry_on_interrupted: true,
        drop_cr: false,
        keep_terminator: true,
        too_long: |max| format!("no newline within the first {} bytes", max),
        eof: "connection closed before the preamble was complete",
    };
    let bytes = read_preamble_raw(r, &policy)?;
    String::from_utf8(bytes)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "preamble is not valid UTF-8"))
}

/// Read one `\n`-terminated request line for the k8s payload-install
/// protocol (`k8s.rs`), one byte at a time.
///
/// This is a **distinct flavor**, not the same behavior as
/// [`read_preamble_line`] under a different name — preserved exactly as
/// `k8s.rs` implemented it before this extraction, divergences included:
///
///   * A `read` error (including `ErrorKind::Interrupted`) is surfaced
///     immediately rather than retried.
///   * Every `\r` byte is dropped as it is read, wherever it appears in the
///     line — not just a trailing one — and does **not** count toward `max`.
///     This means a peer that sends an unbounded run of bare `\r` bytes
///     before ever completing a line is read from forever by this function
///     alone; nothing here bounds that case. (It looks like an oversight
///     rather than intent, and is called out in the refactor report that
///     introduced this module — not fixed here, since fixing it would be a
///     behavior change on infrastructure this ticket is required to leave
///     alone.)
///   * The trailing `\n` is not included in the returned string.
///   * The line is decoded with `String::from_utf8_lossy`: invalid UTF-8 is
///     replaced rather than rejected, so one garbled byte cannot abort an
///     otherwise-valid file install request.
///
/// `max` bounds the number of *kept* (non-`\r`) bytes; see above for what
/// that means for an all-`\r` input.
pub fn read_install_preamble_line<R: Read>(r: &mut R, max: usize) -> io::Result<String> {
    let policy = PreambleReadPolicy {
        max,
        retry_on_interrupted: false,
        drop_cr: true,
        keep_terminator: false,
        too_long: |max| format!("install request exceeded {} bytes with no newline", max),
        eof: "the host closed the install channel before sending a request",
    };
    let bytes = read_preamble_raw(r, &policy)?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

/// Build an `"ERR <reason>\n"` reply.
///
/// Shared by `dial.rs` and `datagram.rs`, whose line-oriented protocols both
/// use exactly this shape for every rejection (not just the busy case).
/// `live_share_receiver.rs` builds the same shape as a literal
/// (`busy_line`) rather than calling this, since that channel never sends
/// any other `ERR` line — busy is the only failure it names on the wire.
///
/// The reason is flattened to a single line: it is a framing delimiter, and
/// an error string containing a newline (an OS error message, say) would
/// otherwise let the failure reply masquerade as two.
pub fn err_line(reason: &str) -> Vec<u8> {
    let mut out = String::with_capacity(reason.len() + 5);
    out.push_str("ERR ");
    for c in reason.chars() {
        out.push(if c == '\n' || c == '\r' { ' ' } else { c });
    }
    out.push('\n');
    out.into_bytes()
}

// ---------------------------------------------------------------------------
// Connection-count guard. Portable: plain `Arc<AtomicUsize>`, no OS
// dependency, so it unit tests directly.
// ---------------------------------------------------------------------------

/// RAII connection-count guard: decrements the shared live-connection
/// counter when the handler thread that owns it exits, however it exits
/// (return, error, or panic unwind).
///
/// Every bounded accept loop in this crate (`dial`, `datagram`, `proxy`,
/// `live_share_receiver`, `control`) used to define this identically, under
/// `ConnGuard` in four places and `ConnectionGuard` in the fifth.
pub struct ConnGuard(Arc<AtomicUsize>);

impl ConnGuard {
    pub fn new(live: Arc<AtomicUsize>) -> Self {
        Self(live)
    }
}

impl Drop for ConnGuard {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

// ---------------------------------------------------------------------------
// Everything below polls a real file descriptor, so it is Linux-only, same
// as the `sys` module it calls into.
// ---------------------------------------------------------------------------

#[cfg(target_os = "linux")]
use std::os::fd::AsRawFd;
#[cfg(target_os = "linux")]
use std::time::Instant;

/// A `Read`/`Write` view of an accepted vsock fd whose reads give up at a
/// deadline.
///
/// The vsock fd is a plain `std::fs::File` (see `sys::VsockListener`), so it
/// has no socket timeout knobs; `poll(2)` before each read supplies them.
/// Meant only for the preamble — once a listener starts splicing or
/// streaming, blocking forever is the desired behaviour.
///
/// `timeout_message` is carried per instance rather than hardcoded because
/// callers word it differently (`dial.rs`/`datagram.rs` say "timed out
/// waiting for the preamble"; `live_share_receiver.rs` says "live-share
/// hello timed out") and that wording is user/log-facing.
#[cfg(target_os = "linux")]
pub struct DeadlineStream<'a> {
    file: &'a mut std::fs::File,
    deadline: Instant,
    timeout_message: &'static str,
}

#[cfg(target_os = "linux")]
impl<'a> DeadlineStream<'a> {
    pub fn new(
        file: &'a mut std::fs::File,
        deadline: Instant,
        timeout_message: &'static str,
    ) -> Self {
        Self {
            file,
            deadline,
            timeout_message,
        }
    }
}

#[cfg(target_os = "linux")]
impl Read for DeadlineStream<'_> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let remaining = self.deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                self.timeout_message,
            ));
        }
        let ms = std::cmp::min(remaining.as_millis(), i32::MAX as u128) as i32;
        if !crate::sys::poll_readable(self.file.as_raw_fd(), ms)? {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                self.timeout_message,
            ));
        }
        self.file.read(buf)
    }
}

#[cfg(target_os = "linux")]
impl Write for DeadlineStream<'_> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.file.write(buf)
    }
    fn flush(&mut self) -> io::Result<()> {
        self.file.flush()
    }
}

/// What happened when [`send_best_effort`] tried to deliver a reply.
///
/// Deliberately not collapsed into a plain `io::Result`: `Sent` and
/// `NotWritableInTime` are not error conditions to most callers (a peer that
/// vanished before a rejection reached it is not a bug), but each caller
/// logs a different sentence for each case — see e.g. `dial::send_busy` —
/// so the distinction has to survive the call.
#[cfg(target_os = "linux")]
pub enum SendOutcome {
    /// The payload was written and flushed.
    Sent,
    /// `poll(2)` never reported the fd writable within the timeout.
    NotWritableInTime,
    /// `poll(2)` itself failed.
    PollFailed(io::Error),
    /// The fd was writable, but the write (or flush) failed.
    WriteFailed(io::Error),
}

/// Best-effort, bounded-wait delivery of a reply on a connection about to be
/// closed (typically because a listener is at its connection cap).
///
/// Runs on the accept thread in every caller, so it must not be able to
/// stall it: `poll(2)` bounds the wait at `timeout_ms`, and past that (or on
/// any error) the caller simply closes the connection — the behaviour this
/// replaced everywhere it is used. A peer that cannot take a few bytes
/// within a quarter of a second of finishing its handshake is gone anyway.
///
/// The reply *payload* is the caller's concern (`err_line`, `busy_line`,
/// `busy_frame`, `busy_response` all differ by design); this function only
/// owns the poll-then-write-then-flush mechanics.
#[cfg(target_os = "linux")]
pub fn send_best_effort<T: Write + AsRawFd>(
    conn: &mut T,
    payload: &[u8],
    timeout_ms: i32,
) -> SendOutcome {
    match crate::sys::poll_writable(conn.as_raw_fd(), timeout_ms) {
        Ok(true) => match conn.write_all(payload).and_then(|()| conn.flush()) {
            Ok(()) => SendOutcome::Sent,
            Err(e) => SendOutcome::WriteFailed(e),
        },
        Ok(false) => SendOutcome::NotWritableInTime,
        Err(e) => SendOutcome::PollFailed(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    // ---- ConnGuard ---------------------------------------------------

    #[test]
    fn conn_guard_decrements_on_drop() {
        let live = Arc::new(AtomicUsize::new(1));
        {
            let _guard = ConnGuard::new(Arc::clone(&live));
            assert_eq!(live.load(Ordering::SeqCst), 1, "must not decrement early");
        }
        assert_eq!(live.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn conn_guard_decrements_even_when_the_owning_thread_panics() {
        // The whole point of an RAII guard here: a handler that panics must
        // still free its connection slot, or a handful of crashes would
        // wedge every bounded listener into permanent "busy".
        let live = Arc::new(AtomicUsize::new(1));
        let live_for_thread = Arc::clone(&live);
        let joined = std::thread::spawn(move || {
            let _guard = ConnGuard::new(live_for_thread);
            panic!("simulated handler panic");
        })
        .join();
        assert!(joined.is_err());
        assert_eq!(live.load(Ordering::SeqCst), 0);
    }

    // ---- read_preamble_line -------------------------------------------

    #[test]
    fn reads_exactly_the_preamble_and_no_further() {
        // The bytes after the newline belong to whatever comes next (a
        // spliced stream, a frame header, ...). If the reader buffers ahead
        // they are lost.
        let mut conn = Cursor::new(b"TCP 8080\nGET / HTTP/1.1\r\n\r\n".to_vec());
        let line = read_preamble_line(&mut conn, 64).unwrap();
        assert_eq!(line, "TCP 8080\n");
        let pos = conn.position() as usize;
        assert_eq!(&conn.get_ref()[pos..], b"GET / HTTP/1.1\r\n\r\n");
    }

    #[test]
    fn a_line_longer_than_the_cap_is_rejected_rather_than_read_forever() {
        let flood = vec![b'A'; 4096];
        let mut conn = Cursor::new(flood);
        let err = read_preamble_line(&mut conn, 64).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
        assert!(conn.position() as usize <= 64);
    }

    #[test]
    fn eof_before_a_newline_is_an_unexpected_eof() {
        let mut conn = Cursor::new(b"TCP 80".to_vec());
        let err = read_preamble_line(&mut conn, 64).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::UnexpectedEof);
    }

    #[test]
    fn non_utf8_input_is_rejected_without_panicking() {
        let mut conn = Cursor::new(vec![0xff, 0xfe, b'\n']);
        let err = read_preamble_line(&mut conn, 64).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn carriage_return_is_kept_as_ordinary_data() {
        let mut conn = Cursor::new(b"TCP 80\r\n".to_vec());
        let line = read_preamble_line(&mut conn, 64).unwrap();
        assert_eq!(line, "TCP 80\r\n");
    }

    // ---- read_install_preamble_line ------------------------------------

    #[test]
    fn install_preamble_drops_carriage_returns_and_the_terminator() {
        let mut conn = Cursor::new(b"PUT k3s 10 abc\r\n".to_vec());
        let line = read_install_preamble_line(&mut conn, 256).unwrap();
        // Unlike `read_preamble_line`: no trailing newline, and the `\r` is
        // gone rather than merely tolerated.
        assert_eq!(line, "PUT k3s 10 abc");
    }

    #[test]
    fn install_preamble_is_lossy_on_invalid_utf8_rather_than_rejecting_it() {
        let mut conn = Cursor::new(vec![b'P', 0xff, b'T', b'\n']);
        let line = read_install_preamble_line(&mut conn, 256).unwrap();
        assert_eq!(line, "P\u{FFFD}T");
    }

    #[test]
    fn install_preamble_with_no_newline_is_bounded() {
        let mut conn = Cursor::new(vec![b'A'; 256 * 4]);
        let err = read_install_preamble_line(&mut conn, 256).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }

    // ---- err_line -------------------------------------------------------

    #[test]
    fn err_line_is_one_line_ending_in_newline() {
        let line = err_line("busy");
        assert_eq!(line, b"ERR busy\n".to_vec());
    }

    #[test]
    fn err_line_flattens_embedded_newlines() {
        let line = err_line("connection refused\nEXTRA\r\n");
        let text = String::from_utf8(line).unwrap();
        assert_eq!(text.matches('\n').count(), 1);
        assert!(text.starts_with("ERR "));
        assert!(text.contains("EXTRA"));
    }
}
