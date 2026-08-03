//! Read-only guest listener discovery for host-network containers.
//!
//! A Virtualization.framework NAT attachment does not make an arbitrary guest
//! host-network listener reachable from macOS. The host can safely bridge only a
//! port Docker identifies as effective (`Config.ExposedPorts`) and this service
//! verifies is bound on guest loopback or all guest interfaces. It deliberately
//! never scans or exports an undeclared guest port.

/// Reserved vsock port for the host's listener-presence probe.
pub const VSOCK_LISTEN_PROBE_PORT: u32 = 2380;
const MAX_PREAMBLE_LEN: usize = 64;
const MAX_CONNECTIONS: usize = 16;
#[cfg(target_os = "linux")]
const PREAMBLE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Transport {
    Tcp,
    Udp,
}

/// Parses `LISTEN <tcp|udp> <port>\n` without accepting a broader control
/// language. The host supplies Docker-derived candidates only; strict parsing keeps
/// a malformed request from turning into a guest port scan.
pub fn parse_preamble(line: &str) -> Result<(Transport, u16), String> {
    let body = line
        .strip_suffix('\n')
        .ok_or_else(|| "preamble is not newline terminated".to_string())?;
    let body = body.strip_suffix('\r').unwrap_or(body);
    let fields: Vec<_> = body.split(' ').collect();
    guard_fields(&fields)?;
    let transport = match fields[1] {
        "tcp" => Transport::Tcp,
        "udp" => Transport::Udp,
        other => return Err(format!("unsupported transport {:?}", other)),
    };
    if fields[2].is_empty() || !fields[2].bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(format!("port is not decimal: {:?}", fields[2]));
    }
    let port: u16 = fields[2]
        .parse()
        .map_err(|_| format!("port is out of range: {:?}", fields[2]))?;
    if port == 0 { return Err("port 0 is not probeable".to_string()) }
    Ok((transport, port))
}

fn guard_fields(fields: &[&str]) -> Result<(), String> {
    if fields.len() != 3 || fields[0] != "LISTEN" || fields.iter().any(|field| field.is_empty()) {
        return Err("expected \"LISTEN <tcp|udp> <port>\"".to_string());
    }
    Ok(())
}

/// Whether a `/proc/net/{tcp,tcp6,udp,udp6}` table has a loopback-reachable
/// socket for `port`. TCP must be in LISTEN (`0A`); UDP must be unconnected
/// (`07`) so an outbound UDP source port cannot become a false publication.
pub fn table_has_loopback_listener(table: &str, transport: Transport, port: u16) -> bool {
    let expected_state = match transport {
        Transport::Tcp => "0A",
        Transport::Udp => "07",
    };
    table.lines().skip(1).any(|line| {
        let fields: Vec<_> = line.split_whitespace().collect();
        let Some(local) = fields.get(1) else { return false };
        if fields.get(3).copied() != Some(expected_state) { return false }
        let Some((address, raw_port)) = local.rsplit_once(':') else { return false };
        let Ok(found_port) = u16::from_str_radix(raw_port, 16) else { return false };
        found_port == port && is_loopback_or_wildcard(address)
    })
}

fn is_loopback_or_wildcard(address: &str) -> bool {
    let normalized = address.to_ascii_uppercase();
    match normalized.len() {
        // `/proc/net/tcp` encodes IPv4 words little-endian.
        8 => normalized == "00000000" || normalized == "0100007F",
        // Accept both byte presentations seen for ::1 across proc parsers.
        32 => normalized == "00000000000000000000000000000000"
            || normalized == "00000000000000000000000000000001"
            || normalized == "00000000000000000000000001000000",
        _ => false,
    }
}

#[cfg(target_os = "linux")]
mod imp {
    use super::{
        parse_preamble, table_has_loopback_listener, Transport, MAX_CONNECTIONS,
        MAX_PREAMBLE_LEN, PREAMBLE_TIMEOUT, VSOCK_LISTEN_PROBE_PORT,
    };
    use crate::dial::{err_line, read_preamble_line};
    use crate::log;
    use crate::sys;
    use std::fs;
    use std::io::{self, Read, Write};
    use std::os::fd::AsRawFd;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::thread;
    use std::time::Instant;

    /// Reads one preamble without allowing a caller that connects but never writes
    /// to occupy one of the bounded worker slots indefinitely.
    struct DeadlineReader<'a> {
        file: &'a mut std::fs::File,
        deadline: Instant,
    }

    impl Read for DeadlineReader<'_> {
        fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
            let remaining = self.deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "timed out waiting for the listener-probe preamble",
                ));
            }
            let milliseconds = std::cmp::min(remaining.as_millis(), i32::MAX as u128) as i32;
            if !sys::poll_readable(self.file.as_raw_fd(), milliseconds)? {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "timed out waiting for the listener-probe preamble",
                ));
            }
            self.file.read(buffer)
        }
    }

    pub fn spawn_listener_probe() -> io::Result<()> {
        let listener = sys::VsockListener::bind(VSOCK_LISTEN_PROBE_PORT)?;
        log::log(&format!(
            "listener probe listening on vsock port {}",
            VSOCK_LISTEN_PROBE_PORT
        ));
        thread::Builder::new()
            .name("listen-probe".to_string())
            .spawn(move || accept_loop(listener))?;
        Ok(())
    }

    fn accept_loop(listener: sys::VsockListener) {
        let live = Arc::new(AtomicUsize::new(0));
        loop {
            let connection = match listener.accept() {
                Ok(connection) => connection,
                Err(error) => {
                    log::log(&format!("listener probe accept error: {}", error));
                    continue;
                }
            };
            if live.load(Ordering::SeqCst) >= MAX_CONNECTIONS {
                drop(connection);
                continue;
            }
            live.fetch_add(1, Ordering::SeqCst);
            let live_for_thread = Arc::clone(&live);
            let spawned = thread::Builder::new()
                .name("listen-probe-conn".to_string())
                .spawn(move || {
                    let _guard = ConnectionGuard(live_for_thread);
                    if let Err(error) = handle(connection) {
                        log::log(&format!("listener probe connection ended: {}", error));
                    }
                });
            if let Err(error) = spawned {
                live.fetch_sub(1, Ordering::SeqCst);
                log::log(&format!("listener probe could not spawn handler: {}", error));
            }
        }
    }

    struct ConnectionGuard(Arc<AtomicUsize>);
    impl Drop for ConnectionGuard {
        fn drop(&mut self) { self.0.fetch_sub(1, Ordering::SeqCst); }
    }

    fn handle(mut connection: std::fs::File) -> io::Result<()> {
        let line = {
            let mut reader = DeadlineReader {
                file: &mut connection,
                deadline: Instant::now() + PREAMBLE_TIMEOUT,
            };
            read_preamble_line(&mut reader, MAX_PREAMBLE_LEN)?
        };
        let (transport, port) = match parse_preamble(&line) {
            Ok(request) => request,
            Err(reason) => {
                connection.write_all(&err_line(&reason))?;
                connection.flush()?;
                return Ok(());
            }
        };
        let listening = guest_loopback_listener_exists(transport, port)?;
        connection.write_all(if listening { b"YES\n" } else { b"NO\n" })?;
        connection.flush()
    }

    fn guest_loopback_listener_exists(transport: Transport, port: u16) -> io::Result<bool> {
        let paths: &[&str] = match transport {
            Transport::Tcp => &["/proc/net/tcp", "/proc/net/tcp6"],
            Transport::Udp => &["/proc/net/udp", "/proc/net/udp6"],
        };
        for path in paths {
            let table = fs::read_to_string(path)?;
            if table_has_loopback_listener(&table, transport, port) { return Ok(true) }
        }
        Ok(false)
    }
}

#[cfg(target_os = "linux")]
pub use imp::spawn_listener_probe;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_one_closed_probe_grammar() {
        assert_eq!(parse_preamble("LISTEN tcp 8080\n"), Ok((Transport::Tcp, 8080)));
        assert_eq!(parse_preamble("LISTEN udp 53\r\n"), Ok((Transport::Udp, 53)));
        assert!(parse_preamble("LISTEN tcp 0\n").is_err());
        assert!(parse_preamble("LISTEN sctp 80\n").is_err());
        assert!(parse_preamble("LISTEN tcp 80 extra\n").is_err());
    }

    #[test]
    fn accepts_only_loopback_or_wildcard_listener_rows() {
        let tcp = "sl local_address rem_address st\n 0: 00000000:1F90 00000000:0000 0A\n 1: 0100007F:0050 00000000:0000 0A\n 2: 0200000A:0050 00000000:0000 0A\n";
        assert!(table_has_loopback_listener(tcp, Transport::Tcp, 8080));
        assert!(table_has_loopback_listener(tcp, Transport::Tcp, 80));
        assert!(!table_has_loopback_listener(tcp, Transport::Tcp, 81));

        let udp = "sl local_address rem_address st\n 0: 00000000:0035 00000000:0000 07\n 1: 0100007F:0036 00000000:0000 07\n 2: 00000000:0037 00000000:0000 01\n";
        assert!(table_has_loopback_listener(udp, Transport::Udp, 53));
        assert!(table_has_loopback_listener(udp, Transport::Udp, 54));
        assert!(!table_has_loopback_listener(udp, Transport::Udp, 55));
    }
}
