//! The Morbstack userland proxy wrapper: what stock dockerd execs for every
//! published port, via its stock `--userland-proxy-path` flag.
//!
//! Invoked (verified against pinned Moby `docker-v29.7.1`,
//! `daemon/libnetwork/portmapper/proxy_linux.go` `StartProxy`) as:
//!
//! ```text
//! morbstack-docker-proxy -proto tcp -host-ip 0.0.0.0 -host-port 49153 \
//!                        -container-ip 172.17.0.2 -container-port 80 \
//!                        [-use-listen-fd]
//! ```
//!
//! with two inherited descriptors:
//!
//!   * fd 3 — the "signal-parent" pipe. dockerd waits up to 16 s for `"0\n"`
//!     (success) or `"1\n<error>"` (failure) before it lets the container
//!     start proceed (`cmd/docker-proxy/main_linux.go`).
//!   * fd 4 — when `-use-listen-fd` is passed, the host-port listener dockerd
//!     already bound *inside the guest*. Modern dockerd always passes this.
//!
//! The wrapper's one job is to make the publication **fail closed on the
//! Mac**: it asks the host daemon, over a guest-initiated vsock connection to
//! ``HOST_PORT_LEASE_PORT``, to bind the same endpoint on the Mac. Only after
//! the host answers `OK` does it `exec` the stock `docker-proxy` with the
//! original argv, so the in-guest listener, the UDP relay, and the fd-3
//! readiness signal are all stock behaviour. The lease connection is not
//! close-on-exec, so it lives exactly as long as the proxy process: dockerd
//! stopping the container kills the proxy, the descriptor closes, and the
//! host releases the Mac listener. There is no separate release protocol to
//! get wrong across restarts.
//!
//! If the host refuses (`ERR <reason>`, typically because another Mac process
//! owns the port) or cannot be reached, the wrapper reports the failure on
//! fd 3 and exits non-zero; dockerd then fails the container start with an
//! honest error — the same semantics a busy port has on native Linux.
//!
//! Two deliberate pass-through cases never contact the host:
//!
//!   * `-v` / `-version`: dockerd probes the binary's version at startup.
//!   * `-proto sctp`: macOS has no SCTP listener to offer, and stock Docker
//!     Desktop behaves the same way; the guest-side proxy still runs so the
//!     publication works between containers.
//!
//! The argv parser and lease-line builder are portable and unit-tested on the
//! macOS dev host; only the vsock connect and `exec` are Linux-only.

use std::io::{self, Read};

/// Host-side vsock port for the port-lease channel, per the shared contract's
/// port registry (`docs/protocol.md` §3). Unlike every other entry, this is a
/// **host** listener: the guest connects out to `VMADDR_CID_HOST`.
pub const HOST_PORT_LEASE_PORT: u32 = 2382;

/// The stock upstream `docker-proxy` this wrapper execs after a granted lease.
pub const STOCK_DOCKER_PROXY: &str = "/usr/local/bin/docker-proxy";

/// The basename dockerd is pointed at; `main` dispatches on it.
pub const WRAPPER_BASENAME: &str = "morbstack-docker-proxy";

/// How long to wait for the host's `OK`/`ERR` line. dockerd abandons the
/// proxy after 16 s (`StartProxy`'s `time.After(16 * time.Second)`), so this
/// must lose that race and still leave time to report on fd 3.
const LEASE_REPLY_TIMEOUT_MS: i32 = 12_000;

/// Longest host reply line accepted, including the newline. `OK\n` is three
/// bytes; an `ERR` line carries one bounded human-readable reason.
const MAX_REPLY_LINE: usize = 512;

/// Whether this process was invoked as the userland-proxy wrapper.
///
/// morbinit is a multi-call binary: `/usr/local/bin/morbstack-docker-proxy`
/// is a link to the same executable, and dockerd always execs it under that
/// name (Moby sets `Args[0]` to the configured proxy path).
pub fn is_wrapper_invocation(argv0: &str) -> bool {
    std::path::Path::new(argv0)
        .file_name()
        .map(|name| name == WRAPPER_BASENAME)
        .unwrap_or(false)
}

/// The five values dockerd passes for a real publication.
#[derive(Debug, PartialEq, Eq)]
pub struct ProxySpec {
    pub proto: String,
    pub host_ip: String,
    pub host_port: u16,
    pub container_ip: String,
    pub container_port: u16,
}

/// What the wrapper should do with one argv.
#[derive(Debug, PartialEq, Eq)]
pub enum Invocation {
    /// A real TCP/UDP publication: lease the Mac port, then exec.
    Lease(ProxySpec),
    /// `-v`/`-version` probe or an SCTP publication: exec the stock proxy
    /// directly. There is nothing to hold on the Mac for either.
    PassThrough,
}

/// Parse dockerd's argv (excluding argv[0]).
///
/// Strict about the five values it needs — a malformed lease request must
/// fail closed, not fall through to a Mac-invisible publication — while
/// tolerating both `-flag value` and `-flag=value` spellings and ignoring
/// flags it does not know (`-use-listen-fd` today, whatever Moby adds next;
/// they are passed through to the stock proxy unchanged either way).
pub fn parse_invocation(args: &[String]) -> Result<Invocation, String> {
    let mut proto: Option<String> = None;
    let mut host_ip: Option<String> = None;
    let mut host_port: Option<String> = None;
    let mut container_ip: Option<String> = None;
    let mut container_port: Option<String> = None;

    let mut index = 0;
    while index < args.len() {
        let arg = &args[index];
        if arg == "-v" || arg == "--v" || arg == "-version" || arg == "--version" {
            return Ok(Invocation::PassThrough);
        }
        let (name, inline_value) = match arg.split_once('=') {
            Some((name, value)) => (name, Some(value.to_string())),
            None => (arg.as_str(), None),
        };
        let slot = match name {
            "-proto" | "--proto" => Some(&mut proto),
            "-host-ip" | "--host-ip" => Some(&mut host_ip),
            "-host-port" | "--host-port" => Some(&mut host_port),
            "-container-ip" | "--container-ip" => Some(&mut container_ip),
            "-container-port" | "--container-port" => Some(&mut container_port),
            _ => None,
        };
        if let Some(slot) = slot {
            let value = match inline_value {
                Some(value) => value,
                None => {
                    index += 1;
                    args.get(index)
                        .cloned()
                        .ok_or_else(|| format!("{} is missing its value", name))?
                }
            };
            *slot = Some(value);
        }
        index += 1;
    }

    let proto = proto.ok_or("missing -proto")?;
    match proto.as_str() {
        "tcp" | "udp" => {}
        "sctp" => return Ok(Invocation::PassThrough),
        other => return Err(format!("unsupported -proto {:?}", other)),
    }
    let parse_port = |name: &str, value: Option<String>| -> Result<u16, String> {
        let value = value.ok_or_else(|| format!("missing {}", name))?;
        let port: u32 = value
            .parse()
            .map_err(|_| format!("{} is not a port number: {:?}", name, value))?;
        if port == 0 || port > u16::MAX as u32 {
            return Err(format!("{} is out of range: {}", name, port));
        }
        Ok(port as u16)
    };
    let host_ip = host_ip.ok_or("missing -host-ip")?;
    let container_ip = container_ip.ok_or("missing -container-ip")?;
    if host_ip.is_empty() || host_ip.contains(' ') || container_ip.contains(' ') {
        return Err("host/container addresses must be non-empty and space-free".to_string());
    }
    Ok(Invocation::Lease(ProxySpec {
        proto,
        host_ip,
        host_port: parse_port("-host-port", host_port)?,
        container_ip: if container_ip.is_empty() {
            "-".to_string()
        } else {
            container_ip
        },
        container_port: parse_port("-container-port", container_port)?,
    }))
}

/// The one request line of the lease protocol.
pub fn lease_line(spec: &ProxySpec) -> String {
    format!(
        "LEASE {} {} {} {} {}\n",
        spec.proto, spec.host_ip, spec.host_port, spec.container_ip, spec.container_port
    )
}

/// Interpret the host's single reply line.
///
/// `Ok(())` only for the exact `OK` reply. Anything else is a refusal whose
/// text becomes dockerd's error message.
pub fn parse_reply(line: &str) -> Result<(), String> {
    let body = line.strip_suffix('\n').unwrap_or(line);
    let body = body.strip_suffix('\r').unwrap_or(body);
    if body == "OK" {
        return Ok(());
    }
    if let Some(reason) = body.strip_prefix("ERR ") {
        return Err(reason.to_string());
    }
    Err(format!("unexpected host reply: {:?}", body))
}

/// Read one newline-terminated reply, one byte at a time, bounded in size and
/// (on Linux, where the fd supports `poll`) in time.
pub fn read_reply_line<R: Read>(reader: &mut R, max: usize) -> io::Result<String> {
    let mut buf = Vec::with_capacity(16);
    let mut byte = [0u8; 1];
    loop {
        if buf.len() >= max {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "host reply had no newline within the size cap",
            ));
        }
        match reader.read(&mut byte) {
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "host closed the lease channel before replying",
                ))
            }
            Ok(_) => {
                buf.push(byte[0]);
                if byte[0] == b'\n' {
                    break;
                }
            }
            Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    String::from_utf8(buf)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "host reply is not UTF-8"))
}

// ---------------------------------------------------------------------------
// Everything below talks to the host and execs: Linux-only.
// ---------------------------------------------------------------------------

#[cfg(target_os = "linux")]
mod imp {
    use super::{
        lease_line, parse_invocation, parse_reply, read_reply_line, Invocation,
        HOST_PORT_LEASE_PORT, LEASE_REPLY_TIMEOUT_MS, MAX_REPLY_LINE, STOCK_DOCKER_PROXY,
    };
    use crate::sys;
    use std::io::{self, Read, Write};
    use std::os::fd::AsRawFd;
    use std::os::unix::process::CommandExt;
    use std::time::Instant;

    /// dockerd's "signal-parent" status pipe.
    const PARENT_PIPE_FD: i32 = 3;

    /// Run the wrapper. Never returns: it either becomes the stock
    /// `docker-proxy` via `exec` or exits non-zero.
    pub fn run(args: &[String]) -> ! {
        match parse_invocation(&args[1..]) {
            Ok(Invocation::PassThrough) => exec_stock_proxy(args),
            Ok(Invocation::Lease(spec)) => {
                let lease = match acquire_lease(&lease_line(&spec)) {
                    Ok(lease) => lease,
                    Err(reason) => fail(&format!(
                        "morbstack: cannot publish {}:{}/{} on the Mac: {}",
                        spec.host_ip, spec.host_port, spec.proto, reason
                    )),
                };
                // The lease fd is deliberately not close-on-exec (see
                // sys::vsock_connect): from here on its lifetime *is* the
                // proxy process's lifetime.
                std::mem::forget(lease);
                exec_stock_proxy(args)
            }
            Err(reason) => fail(&format!(
                "morbstack: refusing an unrecognized userland-proxy invocation: {}",
                reason
            )),
        }
    }

    /// One connection, one request line, one reply line.
    fn acquire_lease(request: &str) -> Result<std::fs::File, String> {
        let mut conn =
            sys::vsock_connect(sys::VMADDR_CID_HOST, HOST_PORT_LEASE_PORT).map_err(|e| {
                format!(
                    "the Morbstack daemon's port-lease channel is unreachable ({})",
                    e
                )
            })?;
        conn.write_all(request.as_bytes())
            .and_then(|()| conn.flush())
            .map_err(|e| format!("could not send the port-lease request ({})", e))?;
        let line = {
            let mut deadline = DeadlineReader {
                file: &mut conn,
                deadline: Instant::now()
                    + std::time::Duration::from_millis(LEASE_REPLY_TIMEOUT_MS as u64),
            };
            read_reply_line(&mut deadline, MAX_REPLY_LINE)
                .map_err(|e| format!("no lease reply from the Morbstack daemon ({})", e))?
        };
        parse_reply(&line)?;
        Ok(conn)
    }

    /// `poll(2)`-bounded reads for the reply, exactly as `dial.rs` does for
    /// its preamble: the raw vsock `File` has no timeout knobs of its own.
    struct DeadlineReader<'a> {
        file: &'a mut std::fs::File,
        deadline: Instant,
    }

    impl Read for DeadlineReader<'_> {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            let remaining = self.deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "timed out waiting for the host lease reply",
                ));
            }
            let ms = std::cmp::min(remaining.as_millis(), i32::MAX as u128) as i32;
            if !sys::poll_readable(self.file.as_raw_fd(), ms)? {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "timed out waiting for the host lease reply",
                ));
            }
            self.file.read(buf)
        }
    }

    /// Replace this process with the stock proxy, preserving argv and every
    /// inherited descriptor (fd 3 status pipe, fd 4 pre-bound listener, and a
    /// granted lease connection).
    fn exec_stock_proxy(args: &[String]) -> ! {
        let error = std::process::Command::new(STOCK_DOCKER_PROXY)
            .args(&args[1..])
            .exec();
        // Only reached when exec itself failed.
        fail(&format!(
            "morbstack: could not exec {}: {}",
            STOCK_DOCKER_PROXY, error
        ));
    }

    /// Report a startup failure the way stock docker-proxy does — `"1\n"` plus
    /// the message on fd 3 — so dockerd surfaces the reason instead of a bare
    /// "proxy exited". Best-effort: when run by hand there is no fd 3.
    fn fail(message: &str) -> ! {
        eprintln!("{}", message);
        let payload = format!("1\n{}", message);
        unsafe {
            let _ = libc_write(
                PARENT_PIPE_FD,
                payload.as_ptr() as *const core::ffi::c_void,
                payload.len(),
            );
        }
        std::process::exit(1);
    }

    extern "C" {
        #[link_name = "write"]
        fn libc_write(fd: i32, buf: *const core::ffi::c_void, count: usize) -> isize;
    }
}

#[cfg(target_os = "linux")]
pub use imp::run;

#[cfg(not(target_os = "linux"))]
pub fn run(_args: &[String]) -> ! {
    eprintln!("morbstack-docker-proxy only runs inside the Morbstack guest");
    std::process::exit(64);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn parses_the_exact_moby_invocation() {
        // The argv shape from moby docker-v29.7.1 StartProxy, verbatim.
        let parsed = parse_invocation(&args(&[
            "-proto",
            "tcp",
            "-host-ip",
            "0.0.0.0",
            "-host-port",
            "49153",
            "-container-ip",
            "172.17.0.2",
            "-container-port",
            "80",
        ]))
        .unwrap();
        assert_eq!(
            parsed,
            Invocation::Lease(ProxySpec {
                proto: "tcp".to_string(),
                host_ip: "0.0.0.0".to_string(),
                host_port: 49153,
                container_ip: "172.17.0.2".to_string(),
                container_port: 80,
            })
        );
    }

    #[test]
    fn tolerates_use_listen_fd_and_unknown_flags() {
        // Modern dockerd appends -use-listen-fd (the pre-bound guest socket
        // arrives on fd 4). Unknown future flags must not break the lease.
        let parsed = parse_invocation(&args(&[
            "-proto",
            "udp",
            "-host-ip",
            "127.0.0.1",
            "-host-port",
            "53",
            "-container-ip",
            "172.17.0.3",
            "-container-port",
            "53",
            "-use-listen-fd",
            "-some-future-switch",
        ]))
        .unwrap();
        match parsed {
            Invocation::Lease(spec) => {
                assert_eq!(spec.proto, "udp");
                assert_eq!(spec.host_port, 53);
            }
            other => panic!("expected a lease, got {:?}", other),
        }
    }

    #[test]
    fn accepts_flag_equals_value_spellings() {
        let parsed = parse_invocation(&args(&[
            "-proto=tcp",
            "-host-ip=::",
            "-host-port=8080",
            "-container-ip=fd00::2",
            "-container-port=80",
        ]))
        .unwrap();
        match parsed {
            Invocation::Lease(spec) => {
                assert_eq!(spec.host_ip, "::");
                assert_eq!(spec.container_ip, "fd00::2");
            }
            other => panic!("expected a lease, got {:?}", other),
        }
    }

    #[test]
    fn version_probes_pass_through_without_a_lease() {
        // dockerd may probe `docker-proxy -v`; there is nothing to hold.
        assert_eq!(
            parse_invocation(&args(&["-v"])).unwrap(),
            Invocation::PassThrough
        );
        assert_eq!(
            parse_invocation(&args(&["--version"])).unwrap(),
            Invocation::PassThrough
        );
    }

    #[test]
    fn sctp_passes_through_without_a_lease() {
        // macOS offers no SCTP socket to lease; the guest-side proxy still
        // serves container-to-container traffic, matching Docker Desktop.
        let parsed = parse_invocation(&args(&[
            "-proto",
            "sctp",
            "-host-ip",
            "0.0.0.0",
            "-host-port",
            "9999",
            "-container-ip",
            "172.17.0.2",
            "-container-port",
            "9999",
        ]))
        .unwrap();
        assert_eq!(parsed, Invocation::PassThrough);
    }

    #[test]
    fn malformed_publications_fail_closed() {
        // A lease the wrapper cannot express must be an error, never a
        // silent pass-through: pass-through means "runs but unreachable
        // from the Mac", which is exactly the lie this design exists to kill.
        for bad in [
            vec!["-proto", "tcp"],
            vec![
                "-proto",
                "tcp",
                "-host-ip",
                "0.0.0.0",
                "-host-port",
                "0",
                "-container-ip",
                "172.17.0.2",
                "-container-port",
                "80",
            ],
            vec![
                "-proto",
                "tcp",
                "-host-ip",
                "0.0.0.0",
                "-host-port",
                "70000",
                "-container-ip",
                "172.17.0.2",
                "-container-port",
                "80",
            ],
            vec![
                "-proto",
                "icmp",
                "-host-ip",
                "0.0.0.0",
                "-host-port",
                "80",
                "-container-ip",
                "172.17.0.2",
                "-container-port",
                "80",
            ],
            vec!["-proto", "tcp", "-host-ip", "0.0.0.0", "-host-port"],
        ] {
            assert!(
                parse_invocation(&args(&bad)).is_err(),
                "{:?} should have been rejected",
                bad
            );
        }
    }

    #[test]
    fn the_lease_line_is_one_bounded_ascii_line() {
        let spec = ProxySpec {
            proto: "tcp".to_string(),
            host_ip: "0.0.0.0".to_string(),
            host_port: 49153,
            container_ip: "172.17.0.2".to_string(),
            container_port: 80,
        };
        assert_eq!(lease_line(&spec), "LEASE tcp 0.0.0.0 49153 172.17.0.2 80\n");
        assert_eq!(lease_line(&spec).matches('\n').count(), 1);
    }

    #[test]
    fn replies_parse_exactly() {
        assert!(parse_reply("OK\n").is_ok());
        assert!(parse_reply("OK\r\n").is_ok());
        assert_eq!(
            parse_reply("ERR port is already allocated\n"),
            Err("port is already allocated".to_string())
        );
        assert!(parse_reply("YES\n").is_err());
        assert!(parse_reply("\n").is_err());
    }

    #[test]
    fn reply_reader_stops_at_the_newline_and_caps_floods() {
        let mut ok = io::Cursor::new(b"OK\nextra".to_vec());
        assert_eq!(read_reply_line(&mut ok, MAX_REPLY_LINE).unwrap(), "OK\n");
        assert_eq!(ok.position(), 3);

        let flood = vec![b'A'; 4096];
        let mut flooded = io::Cursor::new(flood);
        assert!(read_reply_line(&mut flooded, MAX_REPLY_LINE).is_err());
        assert!(flooded.position() as usize <= MAX_REPLY_LINE);
    }

    #[test]
    fn wrapper_dispatch_matches_only_the_installed_basename() {
        assert!(is_wrapper_invocation(
            "/usr/local/bin/morbstack-docker-proxy"
        ));
        assert!(is_wrapper_invocation("morbstack-docker-proxy"));
        assert!(!is_wrapper_invocation("/init"));
        assert!(!is_wrapper_invocation("/usr/local/bin/docker-proxy"));
        assert!(!is_wrapper_invocation(""));
    }

    #[test]
    fn the_registry_entry_is_the_contract_port() {
        // docs/protocol.md §3: 2382 is the guest-initiated host port-lease
        // channel. Everything else in the registry is a guest listener.
        assert_eq!(HOST_PORT_LEASE_PORT, 2382);
    }
}
