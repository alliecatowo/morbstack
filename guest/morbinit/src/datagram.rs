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
//! `127.0.0.1:<port>` (dockerd's bridge proxy).
//! Frames moving in either direction are complete UDP datagrams, including zero-length
//! datagrams. The portable parser and frame codec unit test on macOS; only the vsock
//! listener lives under Linux.

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

/// Writes exactly one bounded datagram frame.
pub fn write_frame<W: Write>(writer: &mut W, datagram: &[u8]) -> io::Result<()> {
    if datagram.len() > MAX_DATAGRAM_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "datagram has {} bytes; maximum is {}",
                datagram.len(),
                MAX_DATAGRAM_BYTES
            ),
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
            format!(
                "datagram frame length {} exceeds {}",
                length, MAX_DATAGRAM_BYTES
            ),
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
        negotiate, read_frame, write_frame, BUSY_REASON, BUSY_REPLY_TIMEOUT_MS, DIAL_ADDR,
        MAX_CONNECTIONS, MAX_DATAGRAM_BYTES, OK_LINE, PREAMBLE_TIMEOUT, VSOCK_DATAGRAM_DIAL_PORT,
    };
    use crate::log;
    use crate::sys;
    use crate::wire::{self, ConnGuard, DeadlineStream};
    use std::io::{self, Write};
    use std::net::UdpSocket;
    use std::os::fd::AsRawFd;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::thread;
    use std::time::{Duration, Instant};

    pub fn spawn_datagram_dialer() -> io::Result<()> {
        let listener = sys::VsockListener::bind(VSOCK_DATAGRAM_DIAL_PORT)?;
        log::log(&format!(
            "datagram dialer listening on vsock port {}",
            VSOCK_DATAGRAM_DIAL_PORT
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
                    let _guard = ConnGuard::new(live_for_thread);
                    if let Err(error) = handle_connection(conn) {
                        log::log(&format!("datagram dial connection ended: {}", error));
                    }
                });
            if let Err(error) = spawned {
                live.fetch_sub(1, Ordering::SeqCst);
                log::log(&format!(
                    "datagram dialer could not spawn handler: {}",
                    error
                ));
            }
        }
    }

    /// Best-effort `ERR busy\n` on a connection about to be refused.
    ///
    /// Unlike every sibling `send_busy` (`dial`, `proxy`, `live_share_receiver`,
    /// `control`), this one does not log on a timeout or a poll/write
    /// failure — it only ever tries once, silently, and moves on either way.
    /// That is the behavior this had before this extraction; preserved
    /// as-is rather than made consistent with the others, since silencing it
    /// or adding logging here would be an observable behavior change this
    /// refactor is not supposed to make. See the refactor report for the
    /// divergence.
    fn send_busy(mut conn: std::fs::File) {
        let reply = wire::err_line(BUSY_REASON);
        let _ = wire::send_best_effort(&mut conn, &reply, BUSY_REPLY_TIMEOUT_MS);
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
                None => return Ok(()),
            }
        };

        // A connected socket is intentional: each host sender gets a stable guest
        // source port and can receive every reply without an address field in frames.
        let udp = UdpSocket::bind((DIAL_ADDR, 0))?;
        if let Err(error) = udp.connect((DIAL_ADDR, port)) {
            let reason = format!("dial UDP {}:{}: {}", DIAL_ADDR, port, error);
            log::log(&format!("datagram dial refused: {}", reason));
            vsock.write_all(&wire::err_line(&reason))?;
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
                                log::log(&format!(
                                    "datagram dial host->guest send error: {}",
                                    error
                                ));
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
                        || error.kind() == io::ErrorKind::TimedOut =>
                {
                    continue
                }
                Err(error) => {
                    log::log(&format!(
                        "datagram dial guest->host receive error: {}",
                        error
                    ));
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
    fn the_frame_header_is_a_four_byte_big_endian_length() {
        // The anchor for the round trip below. `write_frame` and `read_frame` are only
        // ever composed with each other, so a matched pair of `to_le_bytes` /
        // `from_le_bytes` passes every other test in this module while silently
        // breaking `docker run -p 53:53/udp` against the Mac side
        // (`mac/Sources/MorbstackKit/DatagramDial.swift`, which speaks big-endian).
        // Verified: with both sides swapped to little-endian, all 260 guest tests
        // still passed. Keep a literal here so that stops being true.
        let mut encoded = Vec::new();
        write_frame(&mut encoded, b"hi").unwrap();
        assert_eq!(encoded, vec![0x00, 0x00, 0x00, 0x02, b'h', b'i']);

        let mut empty = Vec::new();
        write_frame(&mut empty, b"").unwrap();
        assert_eq!(empty, vec![0x00, 0x00, 0x00, 0x00]);

        // 258 = 0x0102, which is the byte order's discriminating case: a
        // little-endian writer would emit 02 01 00 00 here.
        let mut wide = Vec::new();
        write_frame(&mut wide, &[0u8; 258]).unwrap();
        assert_eq!(&wide[..4], &[0x00, 0x00, 0x01, 0x02]);
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
