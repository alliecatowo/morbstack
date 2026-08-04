//! Broker for Docker's `--publish-all` (`-P`) allocation handshake.
//!
//! A guest cannot bind a Mac loopback port, and Moby must not be taught to
//! guess one: the host forwarder needs to reserve the complete TCP/UDP set as
//! one transaction before libnetwork programs it.  The host consequently
//! holds a long-lived vsock session, registered under one immutable container
//! ID, while patched dockerd asks this local Unix socket for an allocation at
//! each start.  This module only brokers the framed request; the Mac process
//! remains the endpoint owner.

use std::io;

/// Host-to-guest vsock control channel for a `-P` allocation session.
pub const VSOCK_PUBLISH_ALL_ALLOCATOR_PORT: u32 = 2379;
/// The patched dockerd's private request socket.  It is intentionally in
/// `/run`, so it disappears with the guest and can never leak a host session
/// into another VM generation.
pub const PUBLISH_ALL_SOCKET: &str = "/run/morbstack/publish-all.sock";

const MAX_LINE_BYTES: usize = 512;
const MAX_BINDINGS: usize = 128;
const HOST_REGISTRATION_WAIT: std::time::Duration = std::time::Duration::from_secs(45);

/// A host session's immutable routing identity plus its optional diagnostic
/// correlation token. The parser stays outside the Linux-only broker so both
/// the normal host test lane and the guest target pin the wire grammar.
#[cfg(any(target_os = "linux", test))]
#[derive(Debug, Eq, PartialEq)]
struct HostRegistration<'a> {
    container_id: &'a str,
    trace_id: Option<&'a str>,
}

/// Accept the original two-field registration and exactly one backwards-
/// compatible SP-6 extension. Nothing downstream of this parser uses the
/// trace token for allocation or authorization.
#[cfg(any(target_os = "linux", test))]
fn parse_host_registration(line: &str) -> Option<HostRegistration<'_>> {
    let fields: Vec<_> = line.split(' ').collect();
    match fields.as_slice() {
        ["REGISTER", container_id] if valid_container_id(container_id) => Some(HostRegistration {
            container_id,
            trace_id: None,
        }),
        ["REGISTER", container_id, "TRACE", trace_id]
            if valid_container_id(container_id) && valid_trace_id(trace_id) =>
        {
            Some(HostRegistration {
                container_id,
                trace_id: Some(trace_id),
            })
        }
        _ => None,
    }
}

#[cfg(any(target_os = "linux", test))]
fn valid_container_id(id: &str) -> bool {
    id.len() == 64
        && id
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
}

#[cfg(any(target_os = "linux", test))]
fn valid_trace_id(trace_id: &str) -> bool {
    trace_id.len() == 32
        && trace_id
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
}

#[cfg(target_os = "linux")]
mod imp {
    use super::{
        io, parse_host_registration, valid_container_id, HOST_REGISTRATION_WAIT, MAX_BINDINGS,
        MAX_LINE_BYTES, PUBLISH_ALL_SOCKET, VSOCK_PUBLISH_ALL_ALLOCATOR_PORT,
    };
    use crate::{log, sys};
    use std::collections::HashMap;
    use std::fs::{self, File};
    use std::io::{Read, Write};
    use std::os::unix::fs::FileTypeExt;
    use std::os::unix::io::AsRawFd;
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::sync::{Arc, Mutex};
    use std::thread;
    use std::time::Duration;

    /// The host descriptor remains owned by this map after registration.  The
    /// optional trace token is never used for allocation; it only correlates an
    /// opt-in host diagnostic run with the guest's PID-1 log.
    #[derive(Clone)]
    struct HostSession {
        stream: Arc<Mutex<File>>,
        trace_id: Option<String>,
    }

    type Sessions = Arc<Mutex<HashMap<String, HostSession>>>;

    pub fn spawn_publish_all_allocator() -> io::Result<()> {
        let vsock = sys::VsockListener::bind(VSOCK_PUBLISH_ALL_ALLOCATOR_PORT)?;
        prepare_socket_path()?;
        let local = UnixListener::bind(PUBLISH_ALL_SOCKET)?;
        let sessions: Sessions = Arc::new(Mutex::new(HashMap::new()));

        let host_sessions = Arc::clone(&sessions);
        thread::Builder::new()
            .name("publish-all-host".to_string())
            .spawn(move || accept_host_sessions(vsock, host_sessions))?;

        thread::Builder::new()
            .name("publish-all-local".to_string())
            .spawn(move || accept_local_requests(local, sessions))?;

        log::log(&format!(
            "publish-all allocator listening on vsock port {} and {}",
            VSOCK_PUBLISH_ALL_ALLOCATOR_PORT, PUBLISH_ALL_SOCKET
        ));
        Ok(())
    }

    fn prepare_socket_path() -> io::Result<()> {
        fs::create_dir_all("/run/morbstack")?;
        match fs::symlink_metadata(PUBLISH_ALL_SOCKET) {
            Ok(metadata) if metadata.file_type().is_socket() => fs::remove_file(PUBLISH_ALL_SOCKET),
            Ok(_) => Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                format!("refusing to replace non-socket {}", PUBLISH_ALL_SOCKET),
            )),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error),
        }
    }

    fn accept_host_sessions(listener: sys::VsockListener, sessions: Sessions) {
        loop {
            match listener.accept() {
                Ok(mut stream) => {
                    let sessions = Arc::clone(&sessions);
                    let spawned = thread::Builder::new()
                        .name("publish-all-register".to_string())
                        .spawn(move || register_host_session(&mut stream, sessions));
                    if let Err(error) = spawned {
                        log::log(&format!(
                            "publish-all could not spawn host registration: {}",
                            error
                        ));
                    }
                }
                Err(error) => {
                    log::log(&format!("publish-all host accept error: {}", error));
                    thread::sleep(Duration::from_millis(100));
                }
            }
        }
    }

    fn register_host_session(stream: &mut File, sessions: Sessions) {
        let line = match read_line(stream) {
            Ok(line) => line,
            Err(error) => {
                log::log(&format!(
                    "publish-all host registration read failed: {}",
                    error
                ));
                return;
            }
        };
        let Some(registration) = parse_host_registration(&line) else {
            let _ = stream.write_all(b"ERR malformed registration\n");
            return;
        };
        let container_id = registration.container_id;
        let trace_id = registration.trace_id;
        let accepted_fd = stream.as_raw_fd();
        let cloned = match stream.try_clone() {
            Ok(cloned) => cloned,
            Err(error) => {
                let _ = stream.write_all(b"ERR session unavailable\n");
                log::log(&format!(
                    "publish-all host registration clone failed: {}",
                    error
                ));
                return;
            }
        };
        let retained_fd = cloned.as_raw_fd();
        let session = HostSession {
            stream: Arc::new(Mutex::new(cloned)),
            trace_id: trace_id.map(|trace_id| trace_id.to_string()),
        };
        match sessions.lock() {
            Ok(mut sessions) => {
                sessions.insert(container_id.to_string(), session);
            }
            Err(_) => {
                let _ = stream.write_all(b"ERR allocator unavailable\n");
                return;
            }
        }
        trace(
            trace_id,
            format!(
                "event=register-accepted container={} accepted-fd={} retained-fd={}",
                short_id(container_id),
                accepted_fd,
                retained_fd
            ),
        );
        if let Err(error) = stream.write_all(b"READY\n").and_then(|()| stream.flush()) {
            trace(
                trace_id,
                format!("event=ready-write-failed error={}", error),
            );
            log::log(&format!(
                "publish-all host registration reply failed: {}",
                error
            ));
        } else {
            // `stream` returns from this function now, but `retained-fd` in the
            // session map remains open.  This line rules out that expected drop as
            // the source of a later host-side EOF.
            trace(
                trace_id,
                format!(
                    "event=ready-sent original-fd-will-drop retained-fd={}",
                    retained_fd
                ),
            );
        }
    }

    fn accept_local_requests(listener: UnixListener, sessions: Sessions) {
        loop {
            match listener.accept() {
                Ok((stream, _)) => {
                    let sessions = Arc::clone(&sessions);
                    let spawned = thread::Builder::new()
                        .name("publish-all-request".to_string())
                        .spawn(move || handle_local_request(stream, sessions));
                    if let Err(error) = spawned {
                        log::log(&format!(
                            "publish-all could not spawn local request: {}",
                            error
                        ));
                    }
                }
                Err(error) => {
                    log::log(&format!("publish-all local accept error: {}", error));
                    thread::sleep(Duration::from_millis(100));
                }
            }
        }
    }

    fn handle_local_request(mut local: UnixStream, sessions: Sessions) {
        let request = match read_allocation_request(&mut local) {
            Ok(request) => request,
            Err(error) => {
                let _ = write_error(&mut local, "malformed allocation request");
                log::log(&format!("publish-all rejected local request: {}", error));
                return;
            }
        };
        let session = wait_for_host_session(&sessions, &request.container_id);
        let Some(session) = session else {
            let _ = write_error(&mut local, "host allocator is not registered");
            return;
        };
        let forwarded = request.encode();
        let trace_id = session.trace_id.as_deref();
        trace(
            trace_id,
            format!(
                "event=alloc-request container={} count={}",
                short_id(&request.container_id),
                request.count
            ),
        );
        let reply = match session.stream.lock() {
            Ok(mut host) => {
                trace(
                    trace_id,
                    format!("event=alloc-forward fd={}", host.as_raw_fd()),
                );
                if let Err(error) = host.write_all(forwarded.as_bytes()) {
                    Err(format!("write allocation request: {}", error))
                } else if let Err(error) = host.flush() {
                    Err(format!("flush allocation request: {}", error))
                } else {
                    trace(trace_id, "event=alloc-forwarded".to_string());
                    read_allocation_reply(&mut host, request.count)
                        .map_err(|error| format!("read allocation reply: {}", error))
                }
            }
            Err(_) => Err("host allocator lock poisoned".to_string()),
        };
        match reply {
            Ok(reply) => {
                trace(
                    trace_id,
                    format!("event=host-reply-received bytes={}", reply.len()),
                );
                match local
                    .write_all(reply.as_bytes())
                    .and_then(|()| local.flush())
                {
                    Ok(()) => trace(
                        trace_id,
                        "event=reply-relayed-to-moby session-retained".to_string(),
                    ),
                    Err(error) => trace(
                        trace_id,
                        format!("event=reply-relay-failed error={}", error),
                    ),
                }
            }
            Err(error) => {
                trace(
                    trace_id,
                    format!("event=host-session-failed error={}", error),
                );
                if let Ok(mut sessions) = sessions.lock() {
                    sessions.remove(&request.container_id);
                }
                let _ = write_error(&mut local, "host allocator disconnected");
                log::log(&format!("publish-all host allocation failed: {}", error));
            }
        }
    }

    fn wait_for_host_session(sessions: &Sessions, container_id: &str) -> Option<HostSession> {
        let deadline = std::time::Instant::now() + HOST_REGISTRATION_WAIT;
        loop {
            if let Ok(sessions) = sessions.lock() {
                if let Some(session) = sessions.get(container_id) {
                    return Some(session.clone());
                }
            }
            if std::time::Instant::now() >= deadline {
                return None;
            }
            thread::sleep(Duration::from_millis(100));
        }
    }

    struct AllocationRequest {
        container_id: String,
        count: usize,
        lines: Vec<String>,
    }

    impl AllocationRequest {
        fn encode(&self) -> String {
            let mut request = format!("ALLOC {} {}\n", self.container_id, self.count);
            for line in &self.lines {
                request.push_str(line);
                request.push('\n');
            }
            request
        }
    }

    fn read_allocation_request(stream: &mut UnixStream) -> io::Result<AllocationRequest> {
        let header = read_line(stream)?;
        let fields: Vec<_> = header.split(' ').collect();
        if fields.len() != 3 || fields[0] != "ALLOC" || !valid_container_id(fields[1]) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid ALLOC header",
            ));
        }
        let count = fields[2]
            .parse::<usize>()
            .ok()
            .filter(|count| (1..=MAX_BINDINGS).contains(count))
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid ALLOC count"))?;
        let mut lines = Vec::with_capacity(count);
        for _ in 0..count {
            let line = read_line(stream)?;
            if !valid_binding(&line) {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "invalid ALLOC binding",
                ));
            }
            lines.push(line);
        }
        Ok(AllocationRequest {
            container_id: fields[1].to_string(),
            count,
            lines,
        })
    }

    fn read_allocation_reply(stream: &mut File, count: usize) -> io::Result<String> {
        let header = read_line(stream)?;
        if let Some(reason) = header.strip_prefix("ERR ") {
            return Ok(format!("ERR {}\n", sanitize(reason)));
        }
        let expected = format!("OK {}", count);
        if header != expected {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid host allocator reply",
            ));
        }
        let mut reply = format!("{}\n", header);
        for _ in 0..count {
            let line = read_line(stream)?;
            let Some(port) = line
                .strip_prefix("PORT ")
                .and_then(|port| port.parse::<u16>().ok())
            else {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "invalid allocated port",
                ));
            };
            if port == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "allocated port was zero",
                ));
            }
            reply.push_str(&line);
            reply.push('\n');
        }
        Ok(reply)
    }

    fn valid_binding(line: &str) -> bool {
        let fields: Vec<_> = line.split(' ').collect();
        if fields.len() != 4 || !(fields[0] == "tcp" || fields[0] == "udp") {
            return false;
        }
        let port = |value: &str| value.parse::<u16>().ok().filter(|port| *port > 0).is_some();
        port(fields[1])
            && (fields[2] == "-"
                || fields[2]
                    .chars()
                    .all(|c| c.is_ascii_hexdigit() || c == '.' || c == ':'))
            && (fields[3] == "0" || port(fields[3]))
    }

    fn short_id(id: &str) -> &str {
        id.get(..12).unwrap_or(id)
    }

    fn trace(trace_id: Option<&str>, message: String) {
        if let Some(trace_id) = trace_id {
            log::log(&format!(
                "publish-all trace={} endpoint=guest {}",
                trace_id, message
            ));
        }
    }

    fn sanitize(reason: &str) -> String {
        reason
            .chars()
            .filter(|c| *c != '\r' && *c != '\n')
            .take(MAX_LINE_BYTES - 5)
            .collect()
    }

    fn write_error(stream: &mut UnixStream, reason: &str) -> io::Result<()> {
        stream.write_all(format!("ERR {}\n", sanitize(reason)).as_bytes())?;
        stream.flush()
    }

    fn read_line<R: Read>(stream: &mut R) -> io::Result<String> {
        let mut bytes = Vec::with_capacity(64);
        loop {
            let mut byte = [0_u8; 1];
            stream.read_exact(&mut byte)?;
            if byte[0] == b'\n' {
                break;
            }
            if byte[0] == b'\r' || !byte[0].is_ascii() || bytes.len() >= MAX_LINE_BYTES {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "line is invalid or too long",
                ));
            }
            bytes.push(byte[0]);
        }
        String::from_utf8(bytes)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "line is not UTF-8"))
    }
}

#[cfg(target_os = "linux")]
pub use imp::spawn_publish_all_allocator;

#[cfg(not(target_os = "linux"))]
pub fn spawn_publish_all_allocator() -> io::Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{parse_host_registration, HostRegistration};

    const CONTAINER_ID: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const TRACE_ID: &str = "0123456789abcdef0123456789abcdef";

    #[test]
    fn registration_grammar_keeps_the_original_two_field_form() {
        assert_eq!(
            parse_host_registration(&format!("REGISTER {CONTAINER_ID}")),
            Some(HostRegistration {
                container_id: CONTAINER_ID,
                trace_id: None,
            })
        );
    }

    #[test]
    fn registration_grammar_accepts_the_opt_in_trace_extension() {
        assert_eq!(
            parse_host_registration(&format!("REGISTER {CONTAINER_ID} TRACE {TRACE_ID}")),
            Some(HostRegistration {
                container_id: CONTAINER_ID,
                trace_id: Some(TRACE_ID),
            })
        );
    }

    #[test]
    fn registration_grammar_rejects_malformed_or_unsafe_trace_extensions() {
        let uppercase_trace = TRACE_ID.replace('a', "A");
        for line in [
            format!("REGISTER {CONTAINER_ID} TRACE"),
            format!("REGISTER {CONTAINER_ID} TRACE {uppercase_trace}"),
            format!("REGISTER {CONTAINER_ID} TRACE {TRACE_ID} extra"),
            format!("REGISTER {}", &CONTAINER_ID[..63]),
            format!("REGISTER {}", CONTAINER_ID.to_uppercase()),
        ] {
            assert_eq!(parse_host_registration(&line), None, "{line}");
        }
    }
}
