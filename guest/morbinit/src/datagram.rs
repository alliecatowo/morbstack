//! Datagram dialer — guest half of published UDP port forwarding.
//!
//! Vsock is a stream transport, while Docker's UDP publications need message
//! boundaries and a stable source flow for replies. The host therefore opens one
//! vsock connection per Mac UDP client and speaks this deliberately small protocol:
//!
//! ```text
//! host -> guest: "UDP <port>\n"
//! guest -> host: "OK\n" or "ERR <reason>\n"
//! both directions: [u32 big-endian length][exactly that many datagram bytes]
//! ```
//!
//! After the successful handshake the guest owns one connected UDP socket to
//! `127.0.0.1:<port>` (dockerd's userland proxy). Frames moving in either direction
//! are complete UDP datagrams, including zero-length datagrams. The portable parser
//! and frame codec unit test on macOS; only the vsock listener lives under Linux.

use std::io::{self, Read, Write};

/// Registered in `docs/protocol.md`; never reuse an existing control port.
pub const VSOCK_DATAGRAM_DIAL_PORT: u32 = 2378;
pub const MAX_DATAGRAM_BYTES: usize = 65_507;
const MAX_PREAMBLE_LEN: usize = 64;
const OK_LINE: &[u8] = b"OK\n";
const BUSY_REASON: &str = "busy";
const DIAL_ADDR: &str = "127.0.0.1";
/// Lower than stream-dial's cap because each UDP flow permanently owns a guest UDP
/// socket as well as its bridge threads. The host caps itself below this at 48.
const MAX_CONNECTIONS: usize = 64;

#[cfg(target_os = "linux")]
const PREAMBLE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);
#[cfg(target_os = "linux")]
const BUSY_REPLY_TIMEOUT_MS: i32 = 250;

pub fn err_line(reason: &str) -> Vec<u8> {
    let mut out = String::with_capacity(reason.len() + 5);
    out.push_str("ERR ");
    for c in reason.chars() {
        out.push(if c == '\n' || c == '\r' { ' ' } else { c });
    }
    out.push('\n');
    out.into_bytes()
}

/// Reads a line one byte at a time. There is no buffered reader here: anything
/// after the newline is the first four-byte frame header and must remain unread.
pub fn read_preamble_line<R: Read>(reader: &mut R, max: usize) -> io::Result<String> {
    let mut bytes = Vec::with_capacity(16);
    let mut byte = [0u8; 1];
    loop {
        if bytes.len() >= max {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("no newline within the first {} bytes", max),
            ));
        }
        match reader.read(&mut byte) {
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "connection closed before the preamble was complete",
                ))
            }
            Ok(_) => {
                bytes.push(byte[0]);
                if byte[0] == b'\n' {
                    break;
                }
            }
            Err(ref error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        }
    }
    String::from_utf8(bytes)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "preamble is not valid UTF-8"))
}

pub fn parse_preamble(line: &str) -> Result<u16, String> {
    let body = line
        .strip_suffix('\n')
        .ok_or_else(|| "preamble is not newline terminated".to_string())?;
    let body = body.strip_suffix('\r').unwrap_or(body);
    let digits = body
        .strip_prefix("UDP ")
        .ok_or_else(|| format!("expected \"UDP <port>\", got {:?}", body))?;
    if digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
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

pub fn negotiate<S: Read + Write>(conn: &mut S) -> io::Result<Option<u16>> {
    let line = read_preamble_line(conn, MAX_PREAMBLE_LEN)?;
    match parse_preamble(&line) {
        Ok(port) => Ok(Some(port)),
        Err(reason) => {
            conn.write_all(&err_line(&reason))?;
            conn.flush()?;
            Ok(None)
        }
    }
}

/// Writes exactly one bounded datagram frame.
pub fn write_frame<W: Write>(writer: &mut W, datagram: &[u8]) -> io::Result<()> {
    if datagram.len() > MAX_DATAGRAM_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("datagram has {} bytes; maximum is {}", datagram.len(), MAX_DATAGRAM_BYTES),
        ));
    }
    writer.write_all(&(datagram.len() as u32).to_be_bytes())?;
    writer.write_all(datagram)
}

/// Reads one frame. `Ok(None)` is clean EOF before a new header; EOF after any
/// header byte or within a payload is corruption, never an empty datagram.
pub fn read_frame<R: Read>(reader: &mut R) -> io::Result<Option<Vec<u8>>> {
    let mut header = [0u8; 4];
    let mut read = 0;
    while read < header.len() {
        match reader.read(&mut header[read..]) {
            Ok(0) if read == 0 => return Ok(None),
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "datagram stream closed in the middle of a frame header",
                ))
            }
            Ok(count) => read += count,
            Err(ref error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        }
    }
    let length = u32::from_be_bytes(header) as usize;
    if length > MAX_DATAGRAM_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("datagram frame length {} exceeds {}", length, MAX_DATAGRAM_BYTES),
        ));
    }
    let mut datagram = vec![0u8; length];
    let mut read = 0;
    while read < length {
        match reader.read(&mut datagram[read..]) {
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "datagram stream closed in the middle of a frame payload",
                ))
            }
            Ok(count) => read += count,
            Err(ref error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        }
    }
    Ok(Some(datagram))
}

#[cfg(target_os = "linux")]
mod imp {
    use super::{
        err_line, negotiate, read_frame, write_frame, BUSY_REASON, BUSY_REPLY_TIMEOUT_MS,
        DIAL_ADDR, MAX_CONNECTIONS, MAX_DATAGRAM_BYTES, OK_LINE, PREAMBLE_TIMEOUT,
        VSOCK_DATAGRAM_DIAL_PORT,
    };
    use crate::log;
    use crate::sys;
    use std::io::{self, Read, Write};
    use std::net::UdpSocket;
    use std::os::fd::AsRawFd;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::thread;
    use std::time::{Duration, Instant};

    struct ConnGuard(Arc<AtomicUsize>);
    impl Drop for ConnGuard {
        fn drop(&mut self) {
            self.0.fetch_sub(1, Ordering::SeqCst);
        }
    }

    struct DeadlineStream<'a> {
        file: &'a mut std::fs::File,
        deadline: Instant,
    }
    impl Read for DeadlineStream<'_> {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            let remaining = self.deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(io::Error::new(io::ErrorKind::TimedOut, "timed out waiting for the preamble"));
            }
            let milliseconds = std::cmp::min(remaining.as_millis(), i32::MAX as u128) as i32;
            if !sys::poll_readable(self.file.as_raw_fd(), milliseconds)? {
                return Err(io::Error::new(io::ErrorKind::TimedOut, "timed out waiting for the preamble"));
            }
            self.file.read(buf)
        }
    }
    impl Write for DeadlineStream<'_> {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> { self.file.write(buf) }
        fn flush(&mut self) -> io::Result<()> { self.file.flush() }
    }

    pub fn spawn_datagram_dialer() -> io::Result<()> {
        let listener = sys::VsockListener::bind(VSOCK_DATAGRAM_DIAL_PORT)?;
        log::log(&format!(
            "datagram dialer listening on vsock port {}", VSOCK_DATAGRAM_DIAL_PORT
        ));
        thread::Builder::new()
            .name("datagram-dial".to_string())
            .spawn(move || accept_loop(listener))?;
        Ok(())
    }

    fn accept_loop(listener: sys::VsockListener) {
        let live = Arc::new(AtomicUsize::new(0));
        loop {
            let conn = match listener.accept() {
                Ok(conn) => conn,
                Err(error) => {
                    log::log(&format!("datagram dialer accept error: {}", error));
                    thread::sleep(Duration::from_millis(100));
                    continue;
                }
            };
            if live.load(Ordering::SeqCst) >= MAX_CONNECTIONS {
                send_busy(conn);
                continue;
            }
            live.fetch_add(1, Ordering::SeqCst);
            let live_for_thread = Arc::clone(&live);
            let spawned = thread::Builder::new()
                .name("datagram-dial-conn".to_string())
                .spawn(move || {
                    let _guard = ConnGuard(live_for_thread);
                    if let Err(error) = handle_connection(conn) {
                        log::log(&format!("datagram dial connection ended: {}", error));
                    }
                });
            if let Err(error) = spawned {
                live.fetch_sub(1, Ordering::SeqCst);
                log::log(&format!("datagram dialer could not spawn handler: {}", error));
            }
        }
    }

    fn send_busy(mut conn: std::fs::File) {
        let reply = err_line(BUSY_REASON);
        if matches!(sys::poll_writable(conn.as_raw_fd(), BUSY_REPLY_TIMEOUT_MS), Ok(true)) {
            let _ = conn.write_all(&reply).and_then(|()| conn.flush());
        }
    }

    fn handle_connection(mut vsock: std::fs::File) -> io::Result<()> {
        let port = {
            let mut framed = DeadlineStream {
                file: &mut vsock,
                deadline: Instant::now() + PREAMBLE_TIMEOUT,
            };
            match negotiate(&mut framed)? {
                Some(port) => port,
                None => return Ok(()),
            }
        };

        // A connected socket is intentional: each host sender gets a stable guest
        // source port and can receive every reply without an address field in frames.
        let udp = UdpSocket::bind((DIAL_ADDR, 0))?;
        if let Err(error) = udp.connect((DIAL_ADDR, port)) {
            let reason = format!("dial UDP {}:{}: {}", DIAL_ADDR, port, error);
            log::log(&format!("datagram dial refused: {}", reason));
            vsock.write_all(&err_line(&reason))?;
            vsock.flush()?;
            return Ok(());
        }
        // recv() needs a deadline so it can notice the host-to-guest frame reader
        // ended even if the container never replies.
        udp.set_read_timeout(Some(Duration::from_millis(250)))?;

        vsock.write_all(OK_LINE)?;
        vsock.flush()?;
        bridge(vsock, udp)
    }

    fn bridge(vsock: std::fs::File, udp: UdpSocket) -> io::Result<()> {
        let mut vsock_read = vsock;
        let mut vsock_write = vsock_read.try_clone()?;
        let udp_write = udp.try_clone()?;
        let open = Arc::new(AtomicBool::new(true));
        let open_for_upstream = Arc::clone(&open);
        let upstream = thread::Builder::new()
            .name("datagram-dial-up".to_string())
            .spawn(move || {
                loop {
                    match read_frame(&mut vsock_read) {
                        Ok(Some(datagram)) => {
                            if let Err(error) = udp_write.send(&datagram) {
                                log::log(&format!("datagram dial host->guest send error: {}", error));
                                break;
                            }
                        }
                        Ok(None) => break,
                        Err(error) => {
                            log::log(&format!("datagram dial host->guest frame error: {}", error));
                            break;
                        }
                    }
                }
                open_for_upstream.store(false, Ordering::SeqCst);
            })?;

        let mut buffer = vec![0u8; MAX_DATAGRAM_BYTES];
        while open.load(Ordering::SeqCst) {
            match udp.recv(&mut buffer) {
                Ok(count) => {
                    if let Err(error) = write_frame(&mut vsock_write, &buffer[..count]) {
                        log::log(&format!("datagram dial guest->host frame error: {}", error));
                        break;
                    }
                    if let Err(error) = vsock_write.flush() {
                        log::log(&format!("datagram dial guest->host flush error: {}", error));
                        break;
                    }
                }
                Err(error)
                    if error.kind() == io::ErrorKind::WouldBlock
                        || error.kind() == io::ErrorKind::TimedOut => continue,
                Err(error) => {
                    log::log(&format!("datagram dial guest->host receive error: {}", error));
                    break;
                }
            }
        }
        open.store(false, Ordering::SeqCst);
        // The upstream thread can be blocked in a vsock read while the reply direction
        // fails first. Wake it before joining: otherwise a vanished host response path
        // could leave this per-client thread (and its guest UDP socket) alive forever.
        let _ = sys::shutdown(vsock_write.as_raw_fd(), sys::SHUT_RD);
        let _ = upstream.join();
        Ok(())
    }
}

#[cfg(target_os = "linux")]
pub use imp::spawn_datagram_dialer;

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn parses_the_udp_preamble() {
        assert_eq!(parse_preamble("UDP 53\n"), Ok(53));
        assert_eq!(parse_preamble("UDP 65535\r\n"), Ok(65535));
        assert!(parse_preamble("TCP 53\n").is_err());
        assert!(parse_preamble("UDP 0\n").is_err());
    }

    #[test]
    fn frame_round_trip_preserves_boundaries_and_empty_datagrams() {
        let mut encoded = Vec::new();
        write_frame(&mut encoded, b"one").unwrap();
        write_frame(&mut encoded, b"").unwrap();
        write_frame(&mut encoded, b"three").unwrap();
        let mut cursor = Cursor::new(encoded);
        assert_eq!(read_frame(&mut cursor).unwrap(), Some(b"one".to_vec()));
        assert_eq!(read_frame(&mut cursor).unwrap(), Some(Vec::new()));
        assert_eq!(read_frame(&mut cursor).unwrap(), Some(b"three".to_vec()));
        assert_eq!(read_frame(&mut cursor).unwrap(), None);
    }

    #[test]
    fn refuses_oversized_and_truncated_frames() {
        let mut output = Vec::new();
        assert!(write_frame(&mut output, &vec![0; MAX_DATAGRAM_BYTES + 1]).is_err());
        assert!(read_frame(&mut Cursor::new(vec![0, 0, 0])).is_err());
        assert!(read_frame(&mut Cursor::new(vec![0, 0, 0, 2, 1])).is_err());
    }
}
