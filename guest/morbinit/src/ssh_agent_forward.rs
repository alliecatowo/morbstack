//! SSH agent forwarding (UX-19): a local Unix socket at
//! `/run/host-services/ssh-auth.sock`, spliced over vsock to whatever the
//! host decides to do with it.
//!
//! This is Docker Desktop's own documented contract: a container that
//! bind-mounts that fixed path and sets `SSH_AUTH_SOCK` to it expects to
//! reach the *host's* SSH agent. Matching the path (not inventing our own) is
//! what makes a Compose file or devcontainer config copied from a Docker
//! Desktop machine find the socket instead of failing to locate it at all.
//!
//! The listener here always exists — that is the whole point of matching
//! Docker Desktop's static contract — but whether a connection to it goes
//! anywhere is entirely the host's decision, made fresh per connection over
//! vsock port 2383:
//!
//! ```text
//! guest -> host:  "SSHAUTH\n"
//! host  -> guest: "OK\n"             then the connection splices to the host's SSH agent
//!            or:  "ERR <reason>\n"   then the connection closes
//! ```
//!
//! The host refuses by default (`MorbConfig.sshAgentForwarding` starts
//! `false`); see `docs/design/SSH-AGENT-FORWARDING.md` for the full threat
//! model. This module has no opinion of its own and no local enable flag —
//! it always listens, and it always asks, and the host always answers
//! honestly either way. A refusal or an unreachable host both end the same
//! way from the local client's point of view: the connection closes, which
//! an SSH client reports as an ordinary connection reset — the same failure
//! shape a genuinely absent Unix socket would produce on real Docker
//! Desktop, not a Morbstack-specific error.
//!
//! Splicing reuses `proxy::copy_stream`, the same half-close-aware primitive
//! `dial.rs`'s stream dialer uses for published container ports.

/// vsock port the host's SSH-agent forward server listens on. Guest-initiated,
/// like the port-lease channel (2382) — see `docs/protocol.md` §3.
pub const VSOCK_SSH_AGENT_FORWARD_PORT: u32 = 2383;

/// The guest-local socket path, fixed to match Docker Desktop's own contract.
pub const SSH_AUTH_SOCK_PATH: &str = "/run/host-services/ssh-auth.sock";

/// The one request line this channel ever sends. There is nothing to
/// parametrize — the mapping is always "the one host SSH agent" — so unlike
/// the port-lease channel's `LEASE` line, this carries no fields.
pub const REQUEST_LINE: &[u8] = b"SSHAUTH\n";

/// Longest reply line accepted from the host, including the newline. `"OK\n"`
/// is 3 bytes; the rest is slack for an `ERR <reason>` explanation.
const MAX_REPLY_LINE: usize = 256;

/// Whether a host reply line is exactly the affirmative one.
///
/// Portable and pure so it unit tests on the macOS dev host like every other
/// preamble/reply grammar in this crate. `read_preamble_line` keeps the
/// trailing newline, so the affirmative reply must include it too.
pub fn reply_is_ok(line: &str) -> bool {
    line == "OK\n"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognizes_exactly_the_ok_line() {
        assert!(reply_is_ok("OK\n"));
    }

    #[test]
    fn rejects_everything_else() {
        assert!(!reply_is_ok("OK"));
        assert!(!reply_is_ok("ok\n"));
        assert!(!reply_is_ok("ERR disabled\n"));
        assert!(!reply_is_ok(""));
        assert!(!reply_is_ok("OK\nextra"));
    }

    #[test]
    fn the_registry_entry_is_the_contract_port() {
        // docs/protocol.md §3: 2383 is the guest-initiated SSH-agent forward
        // channel. Everything else in the registry except 2382 (port lease)
        // is a guest listener the host dials into.
        assert_eq!(VSOCK_SSH_AGENT_FORWARD_PORT, 2383);
    }
}

// ---------------------------------------------------------------------------
// Everything below binds a Unix listener and opens a vsock connection:
// Linux-only.
// ---------------------------------------------------------------------------

#[cfg(target_os = "linux")]
mod imp {
    use super::{
        reply_is_ok, MAX_REPLY_LINE, REQUEST_LINE, SSH_AUTH_SOCK_PATH, VSOCK_SSH_AGENT_FORWARD_PORT,
    };
    use crate::log;
    use crate::proxy::copy_stream;
    use crate::sys;
    use crate::wire::{read_preamble_line, ConnGuard, DeadlineStream};
    use std::fs;
    use std::io::{self, Write};
    use std::net::Shutdown;
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::path::Path;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::thread;
    use std::time::{Duration, Instant};

    /// Upper bound on simultaneously forwarded local connections. Each costs
    /// two threads (the two copy workers), same accounting as `dial.rs`.
    const MAX_CONNECTIONS: usize = 64;

    /// How long the guest waits for the host's `OK`/`ERR` reply once
    /// connected. Generous: the host's own inbound-preamble read is bounded
    /// at 10s (`SSHAgentForward.requestTimeout`) and its `SSH_AUTH_SOCK`
    /// dial at a few seconds, so this only ever fires against a genuinely
    /// stuck or gone host.
    const HOST_REPLY_TIMEOUT: Duration = Duration::from_secs(15);

    /// Bind the local listener and serve it from a dedicated thread.
    ///
    /// Binding happens on the caller's thread so a failure is reported at
    /// boot, next to the rest of the init sequence, rather than disappearing
    /// into a detached thread — the same policy `dial::spawn_stream_dialer`
    /// and every other long-lived listener in this crate follow.
    pub fn spawn_ssh_agent_forwarder() -> io::Result<()> {
        if let Some(parent) = Path::new(SSH_AUTH_SOCK_PATH).parent() {
            fs::create_dir_all(parent)?;
        }
        // A crashed or restarted process could leave a stale socket file;
        // `bind` fails with `AddrInUse` against one, so clear it first. Best
        // effort: "nothing there to remove" is not a failure.
        let _ = fs::remove_file(SSH_AUTH_SOCK_PATH);
        let listener = UnixListener::bind(SSH_AUTH_SOCK_PATH)?;
        // World read/write: the security boundary is the host's per-connection
        // enable decision (`docs/design/SSH-AGENT-FORWARDING.md`), not which
        // guest UID can dial a local socket inside an already-isolated VM —
        // matching Docker Desktop's own permissive local contract, where any
        // container that mounts the path can use it.
        fs::set_permissions(SSH_AUTH_SOCK_PATH, fs::Permissions::from_mode(0o666))?;
        log::log(&format!(
            "ssh-agent forward listening at {} (host decides per connection whether to forward)",
            SSH_AUTH_SOCK_PATH
        ));
        thread::Builder::new()
            .name("ssh-agent-fwd".to_string())
            .spawn(move || accept_loop(listener))?;
        Ok(())
    }

    fn accept_loop(listener: UnixListener) {
        let live = Arc::new(AtomicUsize::new(0));
        loop {
            let conn = match listener.accept() {
                Ok((conn, _addr)) => conn,
                Err(e) => {
                    log::log(&format!("ssh-agent forward accept error: {}", e));
                    thread::sleep(Duration::from_millis(100));
                    continue;
                }
            };

            if live.load(Ordering::SeqCst) >= MAX_CONNECTIONS {
                log::log(&format!(
                    "ssh-agent forward at connection cap ({}) — dropping a new local connection",
                    MAX_CONNECTIONS
                ));
                // No wire "busy" reply exists on this leg: the local peer is
                // an ordinary SSH client speaking the SSH agent protocol, not
                // morbinit's own line grammar, so there is nothing meaningful
                // to write before closing. The client sees the same
                // connection reset it would see against a saturated real
                // agent socket.
                drop(conn);
                continue;
            }

            live.fetch_add(1, Ordering::SeqCst);
            let live_for_thread = Arc::clone(&live);
            let spawned = thread::Builder::new()
                .name("ssh-agent-fwd-conn".to_string())
                .spawn(move || {
                    let _guard = ConnGuard::new(live_for_thread);
                    if let Err(e) = handle_connection(conn) {
                        log::log(&format!("ssh-agent forward connection ended: {}", e));
                    }
                });
            if let Err(e) = spawned {
                live.fetch_sub(1, Ordering::SeqCst);
                log::log(&format!("ssh-agent forward could not spawn handler: {}", e));
            }
        }
    }

    fn handle_connection(local: UnixStream) -> io::Result<()> {
        let mut vsock = sys::vsock_connect(sys::VMADDR_CID_HOST, VSOCK_SSH_AGENT_FORWARD_PORT)
            .map_err(|e| {
                io::Error::new(
                    e.kind(),
                    format!(
                        "the Morbstack daemon's ssh-agent forward channel is unreachable: {}",
                        e
                    ),
                )
            })?;
        vsock.write_all(REQUEST_LINE)?;
        vsock.flush()?;

        let line = {
            let mut framed = DeadlineStream::new(
                &mut vsock,
                Instant::now() + HOST_REPLY_TIMEOUT,
                "timed out waiting for the host's ssh-agent forward reply",
            );
            read_preamble_line(&mut framed, MAX_REPLY_LINE)?
        };

        if !reply_is_ok(&line) {
            log::log(&format!(
                "ssh-agent forward refused by the host: {}",
                line.trim_end_matches(['\n', '\r'])
            ));
            return Ok(());
        }

        splice(local, vsock)
    }

    /// Shuttle bytes both ways until each direction closes, propagating
    /// half-close rather than tearing the whole connection down — the same
    /// contract `dial.rs`'s `splice` implements for published container ports.
    fn splice(local: UnixStream, vsock: std::fs::File) -> io::Result<()> {
        let mut local_read = local;
        let mut local_write = local_read.try_clone()?;
        let mut vsock_read = vsock;
        let mut vsock_write = vsock_read.try_clone()?;
        let vsock_write_fd = vsock_write.as_raw_fd();

        // local (ssh client) -> host agent
        let up = thread::Builder::new()
            .name("ssh-agent-fwd-up".to_string())
            .spawn(move || {
                if let Err(e) = copy_stream(&mut local_read, &mut vsock_write) {
                    log::log(&format!("ssh-agent forward local->host copy error: {}", e));
                }
                let _ = sys::shutdown_write(vsock_write_fd);
            })?;

        // host agent -> local (ssh client)
        if let Err(e) = copy_stream(&mut vsock_read, &mut local_write) {
            log::log(&format!("ssh-agent forward host->local copy error: {}", e));
        }
        let _ = local_write.shutdown(Shutdown::Write);

        let _ = up.join();
        Ok(())
    }
}

#[cfg(target_os = "linux")]
pub use imp::spawn_ssh_agent_forwarder;
