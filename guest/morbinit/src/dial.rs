//! The stream dialer: AF_VSOCK port 2376 in the guest, spliced to an
//! arbitrary guest-local TCP port on request.
//!
//! This is what makes published container ports reachable from the Mac.
//! `docker run -p 8080:80` makes dockerd (via `docker-proxy`) listen on
//! `127.0.0.1:8080` *inside the guest*; nothing on the host can reach that,
//! because the guest's only host-facing transport is vsock. So the host's
//! port forwarder dials this port and asks morbinit to make the connection
//! on its behalf.
//!
//! The protocol, per the shared contract, is one ASCII line and then raw
//! bytes:
//!
//! ```text
//! host -> guest:  "TCP <port>\n"      port is decimal, guest-local
//! guest -> host:  "OK\n"              connection established, splice begins
//!            or:  "ERR <reason>\n"    then the connection closes
//! ```
//!
//! Every rejection goes out as an `ERR` line, including the ones that are
//! not the host's fault. Backpressure at `MAX_CONNECTIONS` used to close the
//! connection silently, which on the host reads as a peer that hung up
//! without speaking the protocol — a "protocol violation" report for
//! behaviour the contract documents. `ERR busy\n` is what makes documented
//! backpressure look like documented backpressure.
//!
//! Two details are load-bearing:
//!
//!   * The preamble is read **one byte at a time**. Anything read past the
//!     newline belongs to the spliced stream and there is nowhere to put it,
//!     so buffered reading would silently eat the first bytes of the
//!     client's request.
//!   * Half-close is propagated in both directions, exactly as in
//!     `proxy.rs`. A client that finishes its request and shuts down its
//!     write side must still receive the response, which is the normal
//!     shape of every HTTP request the forwarder carries.
//!
//! The preamble parser and its wire replies are plain portable code over
//! `Read`/`Write`, so they unit test with in-memory streams on the macOS dev
//! host; only the vsock listener and the splice are Linux-only.

use std::io::{self, Read, Write};

/// vsock port the stream dialer listens on, per the shared contract's port
/// registry (1024 = MRB0 control, 2375 = Docker API, 2376 = stream dial).
pub const VSOCK_STREAM_DIAL_PORT: u32 = 2376;

/// Upper bound on simultaneously spliced connections, per the contract.
/// Each costs two threads, and PID 1 must not be DoS-able into thread
/// exhaustion.
const MAX_CONNECTIONS: usize = 512;

/// Longest preamble line we will read before giving up, including the
/// newline. `"TCP 65535\n"` is 10 bytes; the rest is slack for nothing in
/// particular, and the cap is what stops a client that never sends a newline
/// from making us read forever.
const MAX_PREAMBLE_LEN: usize = 64;

/// How long a connection has to deliver its preamble before we hang up.
/// Generous for a line the host writes immediately after connecting, and
/// short enough that a stalled dialer cannot pin a thread indefinitely.
#[cfg(target_os = "linux")]
const PREAMBLE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

/// How long the busy rejection gets to reach the host before we give up on
/// it and close anyway. The reply is nine bytes onto a socket that just
/// completed its handshake, so this is only ever spent on a peer that is
/// already gone; the accept loop must not be stalled by one.
#[cfg(target_os = "linux")]
const BUSY_REPLY_TIMEOUT_MS: i32 = 250;

/// Success reply. Sent only once the TCP connection is actually established,
/// so the host can distinguish "no listener yet" from "connected, no data
/// yet" — which matters for the retry loop on the host side.
pub const OK_LINE: &[u8] = b"OK\n";

/// The reason string for a connection refused at `MAX_CONNECTIONS`.
///
/// One word, stable, and documented: the host matches on it to tell
/// "morbinit is saturated, back off and retry" apart from a real failure of
/// the port being dialed.
pub const BUSY_REASON: &str = "busy";

/// The address the dialer connects to on the host's behalf.
///
/// Bridge publications reach dockerd's `docker-proxy` listener here.
pub const DIAL_ADDR: &str = "127.0.0.1";

/// The `ERR` reason for a failed dial to `127.0.0.1:<port>`.
///
/// ECONNREFUSED gets its own wording because the host needs to distinguish a
/// missing guest-local bridge listener from a transport failure. It can mean a
/// publication whose proxy has not bound yet, so the message deliberately does
/// not guess.
pub fn dial_error_reason(port: u16, e: &io::Error) -> String {
    if e.kind() == io::ErrorKind::ConnectionRefused {
        format!(
            "connection refused on {}:{} (no guest loopback listener)",
            DIAL_ADDR, port
        )
    } else {
        format!("dial {}:{}: {}", DIAL_ADDR, port, e)
    }
}

/// Parse `"TCP <port>\n"`, returning the port to dial.
///
/// Strict by design — the contract specifies exactly one form, and anything
/// else is a bug on the other side that should surface as a clear `ERR`
/// rather than being guessed at. The `Err` string becomes that reply.
pub fn parse_preamble(line: &str) -> Result<u16, String> {
    let body = line
        .strip_suffix('\n')
        .ok_or_else(|| "preamble is not newline terminated".to_string())?;
    // Tolerate CRLF: it costs nothing and turns an intractable "connection
    // just closed" into a working one.
    let body = body.strip_suffix('\r').unwrap_or(body);

    let digits = body
        .strip_prefix("TCP ")
        .ok_or_else(|| format!("expected \"TCP <port>\", got {:?}", body))?;

    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return Err(format!("port is not a decimal number: {:?}", digits));
    }
    let port: u16 = digits
        .parse()
        .map_err(|_| format!("port out of range for u16: {:?}", digits))?;
    if port == 0 {
        return Err("port 0 is not dialable".to_string());
    }
    Ok(port)
}

/// Read and validate a preamble, writing the `ERR` reply itself when the
/// line is well-formed enough to answer.
///
/// Returns `Ok(Some(port))` when the caller should dial, `Ok(None)` when a
/// rejection has already been sent, and `Err` when the connection failed
/// before a reply could mean anything.
pub fn negotiate<S: Read + Write>(conn: &mut S) -> io::Result<Option<u16>> {
    let line = crate::wire::read_preamble_line(conn, MAX_PREAMBLE_LEN)?;
    match parse_preamble(&line) {
        Ok(port) => Ok(Some(port)),
        Err(reason) => {
            conn.write_all(&crate::wire::err_line(&reason))?;
            conn.flush()?;
            Ok(None)
        }
    }
}

// ---------------------------------------------------------------------------
// Everything below binds AF_VSOCK and opens TCP connections: Linux-only.
// ---------------------------------------------------------------------------

#[cfg(target_os = "linux")]
mod imp {
    use super::{
        dial_error_reason, negotiate, BUSY_REASON, BUSY_REPLY_TIMEOUT_MS, DIAL_ADDR,
        MAX_CONNECTIONS, OK_LINE, PREAMBLE_TIMEOUT, VSOCK_STREAM_DIAL_PORT,
    };
    use crate::log;
    use crate::proxy::copy_stream;
    use crate::sys;
    use crate::wire::{self, ConnGuard, DeadlineStream};
    use std::io::{self, Write};
    use std::net::{Shutdown, TcpStream};
    use std::os::fd::AsRawFd;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::thread;
    use std::time::{Duration, Instant};

    /// Bind vsock 2376 and serve it from a dedicated thread.
    ///
    /// Binding happens on the caller's thread so a failure is reported at
    /// boot, next to the rest of the init sequence, rather than disappearing
    /// into a detached thread.
    pub fn spawn_stream_dialer() -> io::Result<()> {
        let listener = sys::VsockListener::bind(VSOCK_STREAM_DIAL_PORT)?;
        log::log(&format!(
            "stream dialer listening on vsock port {}",
            VSOCK_STREAM_DIAL_PORT
        ));
        thread::Builder::new()
            .name("stream-dial".to_string())
            .spawn(move || accept_loop(listener))?;
        Ok(())
    }

    fn accept_loop(listener: sys::VsockListener) {
        let live = Arc::new(AtomicUsize::new(0));
        loop {
            let conn = match listener.accept() {
                Ok(c) => c,
                Err(e) => {
                    log::log(&format!("stream dialer accept error: {}", e));
                    thread::sleep(Duration::from_millis(100));
                    continue;
                }
            };

            if live.load(Ordering::SeqCst) >= MAX_CONNECTIONS {
                log::log(&format!(
                    "stream dialer at connection cap ({}) — rejecting new vsock \
                     connection with ERR {}",
                    MAX_CONNECTIONS, BUSY_REASON
                ));
                // Say so before hanging up. Closing silently makes documented
                // backpressure indistinguishable from a peer that never spoke
                // the protocol, and the host reports it as a violation.
                send_busy(conn);
                continue;
            }

            live.fetch_add(1, Ordering::SeqCst);
            let live_for_thread = Arc::clone(&live);
            let spawned = thread::Builder::new()
                .name("stream-dial-conn".to_string())
                .spawn(move || {
                    let _guard = ConnGuard::new(live_for_thread);
                    if let Err(e) = handle_connection(conn) {
                        log::log(&format!("stream dial connection ended: {}", e));
                    }
                });
            if let Err(e) = spawned {
                live.fetch_sub(1, Ordering::SeqCst);
                log::log(&format!("stream dialer could not spawn handler: {}", e));
            }
        }
    }

    /// Best-effort `ERR busy\n` on a connection we are about to refuse.
    ///
    /// Runs on the accept thread, so it must not be able to stall it: the
    /// `poll(2)` bounds the wait at `BUSY_REPLY_TIMEOUT_MS`, and past that
    /// (or on any error) we simply close, which is exactly the behaviour
    /// this replaces. A peer that cannot take nine bytes within a quarter of
    /// a second is gone anyway, and the connection cap exists precisely so
    /// PID 1 does not spawn a thread per caller — including for this.
    fn send_busy(mut conn: std::fs::File) {
        let reply = wire::err_line(BUSY_REASON);
        match wire::send_best_effort(&mut conn, &reply, BUSY_REPLY_TIMEOUT_MS) {
            wire::SendOutcome::Sent => {}
            wire::SendOutcome::WriteFailed(e) => {
                log::log(&format!("could not send the busy rejection: {}", e))
            }
            wire::SendOutcome::NotWritableInTime => log::log(
                "busy rejection could not be sent within its timeout — closing the \
                 connection instead",
            ),
            wire::SendOutcome::PollFailed(e) => log::log(&format!(
                "could not poll a rejected connection for writability: {} — closing \
                 it instead",
                e
            )),
        }
    }

    fn handle_connection(mut vsock: std::fs::File) -> io::Result<()> {
        let port = {
            let mut framed = DeadlineStream::new(
                &mut vsock,
                Instant::now() + PREAMBLE_TIMEOUT,
                "timed out waiting for the preamble",
            );
            match negotiate(&mut framed)? {
                Some(port) => port,
                // negotiate already sent the ERR line.
                None => return Ok(()),
            }
        };

        let tcp = match TcpStream::connect((DIAL_ADDR, port)) {
            Ok(s) => s,
            Err(e) => {
                let reason = dial_error_reason(port, &e);
                log::log(&format!("stream dial refused: {}", reason));
                vsock.write_all(&wire::err_line(&reason))?;
                vsock.flush()?;
                return Ok(());
            }
        };

        vsock.write_all(OK_LINE)?;
        vsock.flush()?;

        splice(vsock, tcp)
    }

    /// Shuttle bytes both ways until each direction closes, propagating
    /// half-close rather than tearing the whole connection down — the same
    /// contract `proxy.rs` implements for the Docker API.
    fn splice(vsock: std::fs::File, tcp: TcpStream) -> io::Result<()> {
        let mut vsock_read = vsock;
        let mut vsock_write = vsock_read.try_clone()?;
        let mut tcp_read = tcp;
        let mut tcp_write = tcp_read.try_clone()?;
        let vsock_write_fd = vsock_write.as_raw_fd();

        // host -> container port
        let up = thread::Builder::new()
            .name("stream-dial-up".to_string())
            .spawn(move || {
                if let Err(e) = copy_stream(&mut vsock_read, &mut tcp_write) {
                    log::log(&format!("stream dial host->guest copy error: {}", e));
                }
                // The host is done sending. Tell the listener so, but leave
                // its response direction open.
                let _ = tcp_write.shutdown(Shutdown::Write);
            })?;

        // container port -> host
        if let Err(e) = copy_stream(&mut tcp_read, &mut vsock_write) {
            log::log(&format!("stream dial guest->host copy error: {}", e));
        }
        let _ = sys::shutdown_write(vsock_write_fd);

        let _ = up.join();
        Ok(())
    }
}

#[cfg(target_os = "linux")]
pub use imp::spawn_stream_dialer;

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    /// An in-memory duplex stream: `negotiate` needs `Read + Write` on one
    /// object, and the whole point of testing here is to see exactly what
    /// bytes go back on the wire.
    struct DuplexBuf {
        inbound: Cursor<Vec<u8>>,
        outbound: Vec<u8>,
    }

    impl DuplexBuf {
        fn new(input: &[u8]) -> Self {
            Self {
                inbound: Cursor::new(input.to_vec()),
                outbound: Vec::new(),
            }
        }
        fn written(&self) -> &str {
            std::str::from_utf8(&self.outbound).unwrap()
        }
    }

    impl Read for DuplexBuf {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            self.inbound.read(buf)
        }
    }

    impl Write for DuplexBuf {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            self.outbound.write(buf)
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn parses_the_contract_preamble() {
        assert_eq!(parse_preamble("TCP 8080\n"), Ok(8080));
        assert_eq!(parse_preamble("TCP 1\n"), Ok(1));
        assert_eq!(parse_preamble("TCP 65535\n"), Ok(65535));
    }

    #[test]
    fn tolerates_crlf() {
        assert_eq!(parse_preamble("TCP 8080\r\n"), Ok(8080));
    }

    #[test]
    fn rejects_port_zero() {
        // Port 0 means "assign me one" to connect(2)'s caller and nothing at
        // all to a dialer, so it can only be a bug on the other side.
        assert!(parse_preamble("TCP 0\n").is_err());
    }

    #[test]
    fn rejects_ports_past_u16() {
        assert!(parse_preamble("TCP 65536\n").is_err());
        assert!(parse_preamble("TCP 99999999999\n").is_err());
    }

    #[test]
    fn rejects_non_numeric_and_signed_ports() {
        for bad in [
            "TCP \n",
            "TCP abc\n",
            "TCP 80a\n",
            "TCP -1\n",
            "TCP +80\n",
            "TCP 0x50\n",
            "TCP  80\n", // double space: the extra one is not a digit
            "TCP 80 \n", // trailing space
            "TCP 80 90\n",
        ] {
            assert!(
                parse_preamble(bad).is_err(),
                "{:?} should have been rejected",
                bad
            );
        }
    }

    #[test]
    fn rejects_other_verbs_and_casings() {
        // The contract specifies exactly one form. Anything else is a
        // protocol mismatch worth reporting, not guessing at.
        for bad in [
            "UDP 80\n",
            "tcp 80\n",
            "Tcp 80\n",
            "TCP\n",
            "TCP80\n",
            "CONNECT 80\n",
            "\n",
            "GET / HTTP/1.1\n",
        ] {
            assert!(
                parse_preamble(bad).is_err(),
                "{:?} should have been rejected",
                bad
            );
        }
    }

    #[test]
    fn rejects_an_unterminated_line() {
        assert!(parse_preamble("TCP 8080").is_err());
    }

    // The raw byte-at-a-time preamble reader's own tests (cap enforcement,
    // EOF, UTF-8 validation, "stops exactly at the newline") now live with
    // its implementation in `wire.rs`'s test module — `negotiate`'s tests
    // below exercise it through this module's own protocol on top of that.

    #[test]
    fn negotiate_accepts_a_valid_preamble_and_writes_nothing_yet() {
        // The OK line is the caller's to send, and only after the dial
        // actually succeeds — otherwise the host cannot tell "connected"
        // from "no listener there".
        let mut conn = DuplexBuf::new(b"TCP 8080\n");
        assert_eq!(negotiate(&mut conn).unwrap(), Some(8080));
        assert_eq!(conn.written(), "");
    }

    #[test]
    fn negotiate_rejects_a_bad_preamble_with_a_single_err_line() {
        let mut conn = DuplexBuf::new(b"UDP 80\n");
        assert_eq!(negotiate(&mut conn).unwrap(), None);
        let written = conn.written();
        assert!(written.starts_with("ERR "), "got {:?}", written);
        assert!(written.ends_with('\n'));
        assert_eq!(written.matches('\n').count(), 1, "reply must be one line");
    }

    #[test]
    fn err_reasons_are_flattened_to_one_line() {
        // An OS error string with an embedded newline must not be able to
        // forge a second protocol frame.
        let line = crate::wire::err_line("connection refused\nEXTRA\r\n");
        let text = String::from_utf8(line).unwrap();
        assert_eq!(text.matches('\n').count(), 1);
        assert!(text.starts_with("ERR "));
        assert!(text.ends_with('\n'));
        assert!(text.contains("EXTRA"));
    }

    #[test]
    fn ok_line_is_exactly_the_contract_bytes() {
        assert_eq!(OK_LINE, b"OK\n");
    }

    #[test]
    fn the_busy_rejection_is_a_well_formed_err_line() {
        // Backpressure at MAX_CONNECTIONS used to close the connection
        // without a word, which the host reports as a protocol violation. It
        // has to arrive as an ordinary, parseable ERR line instead.
        let line = crate::wire::err_line(BUSY_REASON);
        assert_eq!(line, b"ERR busy\n".to_vec());
        let text = String::from_utf8(line).unwrap();
        assert!(text.starts_with("ERR "));
        assert_eq!(text.matches('\n').count(), 1);
        // One stable word, so the host can match on it to distinguish "retry
        // later" from a failure of the port being dialed.
        assert!(!BUSY_REASON.contains(char::is_whitespace));
    }

    #[test]
    fn a_refused_dial_names_loopback_and_the_userland_proxy() {
        // The dialer only works because docker-proxy gives every published
        // port a real 127.0.0.1 listener. With --userland-proxy=false the
        // publishing path is DNAT-only, so the dial gets ECONNREFUSED and the
        // host sees a port that refuses everything for no visible reason.
        let refused = io::Error::from(io::ErrorKind::ConnectionRefused);
        let reason = dial_error_reason(8080, &refused);
        assert_eq!(
            reason,
            "connection refused on 127.0.0.1:8080 (no guest loopback listener)"
        );
        // Still one line once it is on the wire.
        let line = String::from_utf8(crate::wire::err_line(&reason)).unwrap();
        assert_eq!(line.matches('\n').count(), 1);
        assert!(line.starts_with("ERR connection refused on 127.0.0.1:8080"));
    }

    #[test]
    fn other_dial_failures_keep_the_generic_wording() {
        // Only ECONNREFUSED can prove the guest-local listener is absent; a
        // timeout or ENETUNREACH needs its ordinary operating-system wording.
        for kind in [
            io::ErrorKind::TimedOut,
            io::ErrorKind::PermissionDenied,
            io::ErrorKind::AddrNotAvailable,
        ] {
            let reason = dial_error_reason(8080, &io::Error::from(kind));
            assert!(
                reason.starts_with("dial 127.0.0.1:8080: "),
                "got {:?}",
                reason
            );
            assert!(!reason.contains("userland-proxy"));
        }
    }

    #[test]
    fn the_dial_address_is_loopback() {
        // Documented as load-bearing for bridge proxies. See DIAL_ADDR.
        assert_eq!(DIAL_ADDR, "127.0.0.1");
    }

    #[test]
    fn the_port_registry_entry_matches_the_contract() {
        assert_eq!(VSOCK_STREAM_DIAL_PORT, 2376);
        assert_ne!(VSOCK_STREAM_DIAL_PORT, crate::proxy::VSOCK_DOCKER_PORT);
        assert_ne!(VSOCK_STREAM_DIAL_PORT, crate::control::VSOCK_CONTROL_PORT);
    }
}
