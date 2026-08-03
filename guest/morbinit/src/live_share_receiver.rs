//! Authenticated host-edit notifications for explicitly selected VirtioFS roots.
//!
//! A VirtioFS mount makes changed host bytes visible in the guest, but the host's
//! FSEvents record is not an inotify record.  This receiver accepts a narrow,
//! authenticated invalidation from the paired macOS daemon and performs a
//! descriptor-confined same-mode `fchmod(2)` on the existing guest object.  That
//! operation travels through the guest VFS and emits an ordinary fsnotify attribute
//! event for workloads watching the bind-mounted path.  We never try to forge an
//! inotify message, write user bytes, follow project symlinks, or accept a pathname
//! that was not rooted in the immutable session hello.
//!
//! The wire is intentionally line-oriented and bounded so the offline guest build
//! needs no JSON dependency.  It is distinct from MRB0:
//!
//! ```text
//! guest -> host  BOOT <32-hex>
//! host  -> guest HELLO 1 <session-32hex> <boot-32hex> <capability-64hex> <roots>
//! host  -> guest ROOT <id> <tag> <pct-guest> <pct-backing> <0|1> <epoch>
//! host  -> guest COMMIT <hmac-hex>
//! guest -> host  READY <hmac-hex>
//! host  -> guest EVENT <seq> <root-id> <i|r> <pct-relative|-> <hmac-hex>
//! guest -> host  ACK <seq> <applied|rescan-required|rejected> <hmac-hex>
//! ```
//!
//! The hello's capability is fresh per connection and becomes the HMAC-SHA256 key
//! after the receiver proves it parsed the entire immutable claim transcript.  The
//! listener is reachable only through the host side of the VM's vsock device; the
//! secret prevents a stale/replayed stream from becoming a path authority.

pub const VSOCK_LIVE_SHARE_PORT: u32 = 2381;

const MAX_CONNECTIONS: usize = 4;
// A canonical POSIX path can be 4 KiB and its percent form can expand to
// three times that. A ROOT claim has *two* such paths, so 32 KiB admits a
// valid maximum-length claim while bounding unauthenticated memory use per
// connection.
const MAX_LINE_BYTES: usize = 32_768;
const MAX_RESCAN_NUDGES: usize = 65_536;
const MAX_RESCAN_DEPTH: usize = 64;
const PROTOCOL_VERSION: i64 = 1;

#[cfg(target_os = "linux")]
mod imp {
    use super::{
        MAX_CONNECTIONS, MAX_LINE_BYTES, MAX_RESCAN_DEPTH, MAX_RESCAN_NUDGES, PROTOCOL_VERSION,
        VSOCK_LIVE_SHARE_PORT,
    };
    use crate::live_share::{
        self, Direction, Hello, MountedShare, RecordHeader, RootClaim, SequenceCursor,
        ValidatedSession,
    };
    use crate::log;
    use crate::sha256::Sha256;
    use crate::shares::{MountState, ShareSpec};
    use crate::sys;
    use std::fmt;
    use std::fs::{self, File};
    use std::io::{self, Read, Write};
    use std::os::fd::AsRawFd;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::thread;
    use std::time::{Duration, Instant};

    const HELLO_TIMEOUT: Duration = Duration::from_secs(10);

    #[derive(Clone)]
    struct ReceiverContext {
        mounted_shares: Vec<MountedShare>,
        boot_id: [u8; live_share::GUEST_BOOT_ID_BYTES],
    }

    struct ConnectionGuard(Arc<AtomicUsize>);

    impl Drop for ConnectionGuard {
        fn drop(&mut self) {
            self.0.fetch_sub(1, Ordering::SeqCst);
        }
    }

    /// Starts the one bounded data-plane listener.  Mount results are passed from
    /// PID 1's boot transaction, not re-read from config: an advertised share that
    /// failed to mount can never be accepted as a live notification root.
    pub fn spawn_live_share_receiver(
        advertised: &[ShareSpec],
        mount_results: &[(String, MountState)],
    ) -> io::Result<()> {
        let mounted_shares = advertised
            .iter()
            .filter(|share| {
                mount_results
                    .iter()
                    .any(|(path, state)| path == &share.path && *state == MountState::Mounted)
            })
            .map(|share| MountedShare {
                tag: share.tag.clone(),
                guest_path: share.path.clone(),
                read_only: share.read_only,
            })
            .collect();
        let context = ReceiverContext {
            mounted_shares,
            boot_id: read_boot_id()?,
        };
        let listener = sys::VsockListener::bind(VSOCK_LIVE_SHARE_PORT)?;
        log::log(&format!(
            "live-share receiver listening on vsock port {} for {} mounted share(s)",
            VSOCK_LIVE_SHARE_PORT,
            context.mounted_shares.len()
        ));
        thread::Builder::new()
            .name("live-share".to_string())
            .spawn(move || accept_loop(listener, context))?;
        Ok(())
    }

    fn accept_loop(listener: sys::VsockListener, context: ReceiverContext) {
        let live = Arc::new(AtomicUsize::new(0));
        loop {
            let connection = match listener.accept() {
                Ok(connection) => connection,
                Err(error) => {
                    log::log(&format!("live-share receiver accept error: {}", error));
                    thread::sleep(Duration::from_millis(100));
                    continue;
                }
            };
            if live.load(Ordering::SeqCst) >= MAX_CONNECTIONS {
                log::log("live-share receiver is at its connection cap; dropping peer");
                continue;
            }
            live.fetch_add(1, Ordering::SeqCst);
            let live_for_thread = Arc::clone(&live);
            let context_for_thread = context.clone();
            let spawn = thread::Builder::new()
                .name("live-share-conn".to_string())
                .spawn(move || {
                    let _guard = ConnectionGuard(live_for_thread);
                    if let Err(error) = serve_connection(connection, &context_for_thread) {
                        log::log(&format!("live-share connection ended: {}", error));
                    }
                });
            if let Err(error) = spawn {
                live.fetch_sub(1, Ordering::SeqCst);
                log::log(&format!(
                    "could not start live-share connection worker: {}",
                    error
                ));
            }
        }
    }

    fn serve_connection(mut connection: File, context: &ReceiverContext) -> io::Result<()> {
        write_line(&mut connection, &format!("BOOT {}", hex(&context.boot_id)))?;
        let (message, hello) = read_hello(&mut connection, context)?;
        let session =
            live_share::validate_hello(message, &context.mounted_shares).map_err(protocol_error)?;
        let ready_body = format!("READY {} {}", hello.session_hex, hex(&context.boot_id));
        write_line(
            &mut connection,
            &format!(
                "{} {}",
                ready_body,
                hmac_hex(&hello.capability, ready_body.as_bytes())
            ),
        )?;

        let mut cursor = SequenceCursor::default();
        loop {
            let line = read_line(&mut connection, MAX_LINE_BYTES)?;
            let body = strip_line_end(&line)?;
            if body.starts_with("CLOSE ") {
                let fields: Vec<_> = body.split(' ').collect();
                if fields.len() != 3 || !verify_hmac(&hello.capability, fields[1], fields[2]) {
                    return Err(protocol_error("invalid live-share close"));
                }
                write_line(&mut connection, "STOPPED")?;
                return Ok(());
            }
            let acknowledgement = match apply_event(body, &hello, &session, &mut cursor) {
                Ok((sequence, disposition)) => acknowledgement_line(
                    &hello.capability,
                    &hello.session_hex,
                    &hex(&context.boot_id),
                    sequence,
                    disposition,
                ),
                Err(error) => {
                    log::log(&format!("live-share rejected an event: {}", error));
                    return Err(error);
                }
            };
            write_line(&mut connection, &acknowledgement)?;
        }
    }

    /// The parts of a validated HELLO the connection loop keeps for the life of
    /// the session. Deliberately does NOT hold the `Hello` itself: `validate_hello`
    /// consumes that by value, and every later use needs only these `Copy`
    /// identity fields plus the capability, so keeping the two separate avoids a
    /// partial move out of a struct we still need to borrow.
    struct ParsedHello {
        capability: [u8; live_share::CAPABILITY_BYTES],
        session_hex: String,
        session_id: [u8; live_share::SESSION_ID_BYTES],
        guest_boot_id: [u8; live_share::GUEST_BOOT_ID_BYTES],
    }

    fn read_hello(
        connection: &mut File,
        context: &ReceiverContext,
    ) -> io::Result<(Hello, ParsedHello)> {
        let deadline = Instant::now() + HELLO_TIMEOUT;
        let hello_line = read_line_until(connection, MAX_LINE_BYTES, deadline)?;
        let hello_body = strip_line_end(&hello_line)?;
        let fields: Vec<_> = hello_body.split(' ').collect();
        if fields.len() != 6 || fields[0] != "HELLO" || fields[1] != "1" {
            return Err(protocol_error("invalid live-share hello header"));
        }
        let session_id = parse_hex_fixed::<{ live_share::SESSION_ID_BYTES }>(fields[2])?;
        let boot_id = parse_hex_fixed::<{ live_share::GUEST_BOOT_ID_BYTES }>(fields[3])?;
        if boot_id != context.boot_id {
            return Err(protocol_error(
                "live-share hello named a different guest boot",
            ));
        }
        let capability = parse_hex_fixed::<{ live_share::CAPABILITY_BYTES }>(fields[4])?;
        let session_hex = fields[2].to_string();
        let root_count = fields[5]
            .parse::<usize>()
            .ok()
            .filter(|count| (1..=live_share::MAX_ROOTS).contains(count))
            .ok_or_else(|| protocol_error("invalid live-share root count"))?;

        let mut transcript = hello_line.as_bytes().to_vec();
        let mut roots = Vec::with_capacity(root_count);
        for _ in 0..root_count {
            let line = read_line_until(connection, MAX_LINE_BYTES, deadline)?;
            let body = strip_line_end(&line)?;
            roots.push(parse_root(body)?);
            transcript.extend_from_slice(line.as_bytes());
        }
        let commit = read_line_until(connection, MAX_LINE_BYTES, deadline)?;
        let commit_body = strip_line_end(&commit)?;
        let commit_fields: Vec<_> = commit_body.split(' ').collect();
        if commit_fields.len() != 2
            || commit_fields[0] != "COMMIT"
            || !verify_hmac(
                &capability,
                &String::from_utf8_lossy(&transcript),
                commit_fields[1],
            )
        {
            return Err(protocol_error("live-share hello commitment did not verify"));
        }
        Ok((
            Hello {
                contract_version: PROTOCOL_VERSION,
                session_id,
                guest_boot_id: boot_id,
                peer_capability: capability,
                roots,
            },
            ParsedHello {
                capability,
                session_hex,
                session_id,
                guest_boot_id: boot_id,
            },
        ))
    }

    fn parse_root(body: &str) -> io::Result<RootClaim> {
        let fields: Vec<_> = body.split(' ').collect();
        if fields.len() != 7 || fields[0] != "ROOT" {
            return Err(protocol_error("invalid live-share root claim"));
        }
        let read_only = match fields[5] {
            "0" => false,
            "1" => true,
            _ => return Err(protocol_error("invalid live-share root access mode")),
        };
        let epoch = fields[6]
            .parse::<u64>()
            .ok()
            .filter(|epoch| *epoch > 0)
            .ok_or_else(|| protocol_error("invalid live-share root epoch"))?;
        Ok(RootClaim {
            root_id: fields[1].to_string(),
            backing_share_tag: fields[2].to_string(),
            guest_path: percent_decode(fields[3])?,
            backing_share_path: percent_decode(fields[4])?,
            read_only,
            epoch,
        })
    }

    fn apply_event(
        body: &str,
        hello: &ParsedHello,
        session: &ValidatedSession,
        cursor: &mut SequenceCursor,
    ) -> io::Result<(u64, &'static str)> {
        let fields: Vec<_> = body.split(' ').collect();
        if fields.len() != 6 || fields[0] != "EVENT" {
            return Err(protocol_error("invalid live-share event header"));
        }
        let sequence = fields[1]
            .parse::<u64>()
            .ok()
            .filter(|sequence| *sequence > 0)
            .ok_or_else(|| protocol_error("invalid live-share event sequence"))?;
        let authenticated = fields[..5].join(" ");
        if !verify_hmac(&hello.capability, &authenticated, fields[5]) {
            return Err(protocol_error("live-share event HMAC did not verify"));
        }
        let kind = fields[3];
        let relative = match kind {
            "i" => Some(percent_decode(fields[4])?),
            "r" if fields[4] == "-" => None,
            _ => return Err(protocol_error("invalid live-share event kind or path")),
        };
        let header = RecordHeader {
            contract_version: PROTOCOL_VERSION,
            session_id: hello.session_id,
            guest_boot_id: hello.guest_boot_id,
            root_id: fields[2].to_string(),
            epoch: session.epoch_for_root(fields[2]).map_err(protocol_error)?,
            direction: Direction::HostToGuest,
            sequence,
            base_revision: 0,
        };
        session
            .validate_next_inbound_header(cursor, &header)
            .map_err(protocol_error)?;
        if session
            .root_is_read_only(fields[2])
            .map_err(protocol_error)?
        {
            return Ok((sequence, "rejected"));
        }
        let root = session
            .guest_path_for_root(fields[2])
            .map_err(protocol_error)?;
        match relative {
            Some(relative) => {
                let relative = session
                    .validate_entry_path(fields[2], &relative)
                    .map_err(protocol_error)?;
                nudge_nearest(root, relative.as_str())?;
                Ok((sequence, "applied"))
            }
            None => match nudge_tree(root) {
                Ok(()) => Ok((sequence, "applied")),
                Err(NudgeError::BudgetExhausted) => Ok((sequence, "rescan-required")),
                Err(NudgeError::IO(error)) => Err(error),
            },
        }
    }

    enum NudgeError {
        BudgetExhausted,
        IO(io::Error),
    }

    impl From<io::Error> for NudgeError {
        fn from(error: io::Error) -> Self {
            Self::IO(error)
        }
    }

    fn nudge_nearest(root: &str, relative: &str) -> io::Result<()> {
        let mut directory = sys::openat_readonly_no_follow(sys::AT_FDCWD, root, true)?;
        let components: Vec<_> = relative.split('/').collect();
        for (index, component) in components.iter().enumerate() {
            let final_component = index + 1 == components.len();
            match sys::openat_readonly_no_follow(directory.as_raw_fd(), component, !final_component)
            {
                Ok(entry) => {
                    if final_component {
                        return sys::nudge_metadata(&entry);
                    }
                    directory = entry;
                }
                Err(error) if error.kind() == io::ErrorKind::NotFound => {
                    // Deletions and rename targets naturally disappear before an
                    // invalidation arrives.  Nudge the nearest still-open parent;
                    // it is the object a directory watcher actually observes.
                    return sys::nudge_metadata(&directory);
                }
                Err(error) => return Err(error),
            }
        }
        sys::nudge_metadata(&directory)
    }

    fn nudge_tree(root: &str) -> Result<(), NudgeError> {
        let root = sys::openat_readonly_no_follow(sys::AT_FDCWD, root, true)?;
        let mut remaining = MAX_RESCAN_NUDGES;
        nudge_tree_from(root, 0, &mut remaining)
    }

    fn nudge_tree_from(
        directory: File,
        depth: usize,
        remaining: &mut usize,
    ) -> Result<(), NudgeError> {
        if *remaining == 0 || depth > MAX_RESCAN_DEPTH {
            return Err(NudgeError::BudgetExhausted);
        }
        *remaining -= 1;
        sys::nudge_metadata(&directory)?;
        let entries = fs::read_dir(format!("/proc/self/fd/{}", directory.as_raw_fd()))?;
        for entry in entries {
            let entry = entry?;
            let name = entry.file_name();
            let Some(name) = name.to_str() else { continue };
            if name.is_empty() || name == "." || name == ".." || name.contains('/') {
                continue;
            }
            // The descriptor open is the authoritative type + no-follow check; a
            // `DirEntry` can race a host rename between `read_dir` and openat.
            match sys::openat_readonly_no_follow(directory.as_raw_fd(), name, false) {
                Ok(child) => {
                    if child.metadata()?.is_dir() {
                        nudge_tree_from(child, depth + 1, remaining)?;
                    } else {
                        if *remaining == 0 {
                            return Err(NudgeError::BudgetExhausted);
                        }
                        *remaining -= 1;
                        sys::nudge_metadata(&child)?;
                    }
                }
                Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
                // A symlink or special object is deliberately not followed.  It is
                // still visible through VirtioFS, but it never becomes a receiver
                // capability to touch an arbitrary guest destination.
                Err(error) if error.raw_os_error() == Some(40) => continue,
                Err(error) => return Err(NudgeError::IO(error)),
            }
        }
        Ok(())
    }

    fn acknowledgement_line(
        capability: &[u8; live_share::CAPABILITY_BYTES],
        session: &str,
        boot: &str,
        sequence: u64,
        disposition: &str,
    ) -> String {
        let body = format!("ACK {} {} {} {}", session, boot, sequence, disposition);
        format!("{} {}", body, hmac_hex(capability, body.as_bytes()))
    }

    fn write_line(connection: &mut File, line: &str) -> io::Result<()> {
        connection.write_all(line.as_bytes())?;
        connection.write_all(b"\n")?;
        connection.flush()
    }

    fn read_line(connection: &mut File, cap: usize) -> io::Result<String> {
        crate::dial::read_preamble_line(connection, cap)
    }

    fn read_line_until(connection: &mut File, cap: usize, deadline: Instant) -> io::Result<String> {
        struct DeadlineReader<'a> {
            file: &'a mut File,
            deadline: Instant,
        }
        impl Read for DeadlineReader<'_> {
            fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
                let remaining = self.deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    return Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        "live-share hello timed out",
                    ));
                }
                let ms = remaining.as_millis().min(i32::MAX as u128) as i32;
                if !sys::poll_readable(self.file.as_raw_fd(), ms)? {
                    return Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        "live-share hello timed out",
                    ));
                }
                self.file.read(buffer)
            }
        }
        crate::dial::read_preamble_line(
            &mut DeadlineReader {
                file: connection,
                deadline,
            },
            cap,
        )
    }

    fn strip_line_end(line: &str) -> io::Result<&str> {
        let body = line
            .strip_suffix('\n')
            .ok_or_else(|| protocol_error("live-share line is not newline terminated"))?;
        Ok(body.strip_suffix('\r').unwrap_or(body))
    }

    fn hmac_hex(key: &[u8; live_share::CAPABILITY_BYTES], message: &[u8]) -> String {
        let mut inner = Sha256::new();
        let mut ipad = [0x36_u8; 64];
        for (byte, key_byte) in ipad.iter_mut().zip(key.iter()) {
            *byte ^= *key_byte;
        }
        inner.update(&ipad);
        inner.update(message);
        let inner_digest = inner.finalize();
        let mut outer = Sha256::new();
        let mut opad = [0x5c_u8; 64];
        for (byte, key_byte) in opad.iter_mut().zip(key.iter()) {
            *byte ^= *key_byte;
        }
        outer.update(&opad);
        outer.update(&inner_digest);
        hex(&outer.finalize())
    }

    fn verify_hmac(key: &[u8; live_share::CAPABILITY_BYTES], message: &str, tag: &str) -> bool {
        constant_time_equal(hmac_hex(key, message.as_bytes()).as_bytes(), tag.as_bytes())
    }

    fn constant_time_equal(left: &[u8], right: &[u8]) -> bool {
        if left.len() != right.len() {
            return false;
        }
        let mut difference = 0_u8;
        for (left, right) in left.iter().zip(right.iter()) {
            difference |= left ^ right;
        }
        difference == 0
    }

    fn parse_hex_fixed<const N: usize>(value: &str) -> io::Result<[u8; N]> {
        if value.len() != N * 2 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(protocol_error("invalid live-share fixed hex field"));
        }
        let mut out = [0_u8; N];
        for (index, slot) in out.iter_mut().enumerate() {
            *slot = u8::from_str_radix(&value[index * 2..index * 2 + 2], 16)
                .map_err(|_| protocol_error("invalid live-share hex field"))?;
        }
        Ok(out)
    }

    fn percent_decode(value: &str) -> io::Result<String> {
        if value.len() > live_share::MAX_PATH_BYTES * 3 {
            return Err(protocol_error("live-share path encoding is too long"));
        }
        let mut bytes = Vec::with_capacity(value.len());
        let source = value.as_bytes();
        let mut index = 0;
        while index < source.len() {
            if source[index] == b'%' {
                if index + 2 >= source.len() {
                    return Err(protocol_error("truncated live-share escape"));
                }
                let hex = std::str::from_utf8(&source[index + 1..index + 3])
                    .map_err(|_| protocol_error("invalid live-share escape"))?;
                bytes.push(
                    u8::from_str_radix(hex, 16)
                        .map_err(|_| protocol_error("invalid live-share escape"))?,
                );
                index += 3;
            } else {
                if source[index].is_ascii_control() || source[index].is_ascii_whitespace() {
                    return Err(protocol_error("invalid live-share path byte"));
                }
                bytes.push(source[index]);
                index += 1;
            }
        }
        String::from_utf8(bytes).map_err(|_| protocol_error("live-share path is not UTF-8"))
    }

    fn read_boot_id() -> io::Result<[u8; live_share::GUEST_BOOT_ID_BYTES]> {
        let raw = fs::read_to_string("/proc/sys/kernel/random/boot_id")?;
        let compact: String = raw
            .trim()
            .chars()
            .filter(|character| *character != '-')
            .collect();
        parse_hex_fixed(&compact)
    }

    fn hex(bytes: &[u8]) -> String {
        const DIGITS: &[u8; 16] = b"0123456789abcdef";
        let mut result = String::with_capacity(bytes.len() * 2);
        for byte in bytes {
            result.push(DIGITS[(byte >> 4) as usize] as char);
            result.push(DIGITS[(byte & 0x0f) as usize] as char);
        }
        result
    }

    // Takes `Display` rather than `Into<String>` so the same helper accepts both
    // the literal &str reasons below and a `ValidationError` straight out of
    // `.map_err(protocol_error)`. `ValidationError` implements `Display` (it is a
    // `std::error::Error`) but not `Into<String>`, and the mismatch only ever
    // surfaced when cross-compiling for the real guest target.
    fn protocol_error(message: impl fmt::Display) -> io::Error {
        io::Error::new(io::ErrorKind::InvalidData, message.to_string())
    }
}

#[cfg(target_os = "linux")]
pub use imp::spawn_live_share_receiver;
