//! Split DNS for `host.docker.internal` / `gateway.docker.internal`
//! (docs/parity.md #18/#19).
//!
//! Real Docker Desktop resolves these two names for free; upstream dockerd
//! does not — there is no "host.docker.internal" string anywhere in the
//! `dockerd` binary this repo ships (checked directly: `strings
//! dist/guest-bin/dockerd | grep host.docker.internal` finds nothing).
//! Desktop's trick lives in its own DNS layer, not in the engine, so
//! Morbstack needs one too. `docs/parity.md` #22 already proved the
//! underlying path to the host works (the VM's own gateway address reaches a
//! Mac-side listener) — this module is "just" the DNS plumbing on top of
//! that fact, per the audit's own root-cause note.
//!
//! ## Design
//!
//! A tiny UDP stub, bound on every guest address, that answers exactly two
//! names itself and forwards everything else upstream unmodified:
//!
//!   * `host.docker.internal` / `gateway.docker.internal`, type A: answered
//!     directly with the VM's default gateway address (the one address
//!     `docs/parity.md` #22 confirms reaches the Mac). The two names are
//!     deliberately given the same answer — there is only one "host" from
//!     the guest's point of view, and real Docker Desktop has historically
//!     treated `gateway.docker.internal` as an alias of the same address.
//!   * the same two names, type AAAA: answered NOERROR with zero records,
//!     so a dual-stack resolver's parallel AAAA query fails fast instead of
//!     hanging, rather than being forwarded to an upstream that has never
//!     heard of these names either.
//!   * anything else: forwarded byte-for-byte to the real upstream and its
//!     reply relayed back untouched. This stub does not implement DNS; it
//!     only intercepts two specific answers.
//!
//! ## Why this reaches every container, not just some
//!
//! dockerd only runs its embedded per-container DNS proxy (127.0.0.11) for
//! containers on *user-defined* networks (what `docker compose` creates).
//! Containers on the plain default `bridge` network — what a bare
//! `docker run` with no `--network` lands on, which is exactly what
//! `docs/parity.md` #18's reproduction command uses — get no such proxy;
//! dockerd instead copies whatever `--dns` server(s) it was started with
//! straight into *that* container's own `/etc/resolv.conf`, dialed directly
//! from the container's own network namespace. That rules out binding this
//! stub only on loopback: a legacy-bridge container's `127.0.0.1` is its own
//! isolated loopback, not the guest's. Binding on every guest address
//! (`0.0.0.0`) and pointing dockerd's `--dns` at the guest's real `eth0`
//! address (see `net::guest_ipv4`, wired up in `main.rs`) means the same
//! stub is reachable both ways: directly, over the bridge, by a legacy
//! container, and from the root network namespace by the embedded-DNS
//! proxy's own upstream forwarding on a user-defined network.

use std::net::Ipv4Addr;

/// The two names Docker Desktop resolves for free that upstream dockerd does
/// not. See the module docs for why both get the same answer.
pub const SPECIAL_NAMES: [&str; 2] = ["host.docker.internal", "gateway.docker.internal"];

const TYPE_A: u16 = 1;
const TYPE_AAAA: u16 = 28;
const CLASS_IN: u16 = 1;

/// Short on purpose: this answer can change across a guest boot (a new DHCP
/// lease could hand out a different gateway), and nothing about a
/// container's resolver setup will ask again before the container itself is
/// torn down and rebuilt anyway.
const ANSWER_TTL: u32 = 30;

/// UDP port the stub listens on and forwards to — port 53, as any resolver
/// expects.
pub const DNS_PORT: u16 = 53;

/// How long a forwarded query waits for the real upstream before the client
/// is left to retry on its own. Generous for a query that never leaves the
/// VM's virtual network; short enough that one dead upstream cannot pin a
/// thread per query for long.
#[cfg(target_os = "linux")]
const UPSTREAM_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(3);

/// Largest UDP DNS message handled. 512 is the historical plain-UDP
/// ceiling; EDNS0 clients can announce a larger UDP payload size, but
/// nothing this stub answers (a single A record) or forwards (ordinary
/// container lookups) needs it, and a fixed buffer this size is simplest to
/// reason about.
const MAX_MESSAGE: usize = 4096;

/// A slow upstream must not make a request for one unrelated hostname delay
/// the two Docker host aliases for every other container. The stub keeps a
/// small bounded set of concurrent forwards; above this limit a resolver can
/// retry rather than making an untrusted container create unbounded threads.
#[cfg(target_os = "linux")]
const MAX_CONCURRENT_FORWARDS: usize = 32;

/// Case-insensitively compare a decoded wire-format name against one of
/// `SPECIAL_NAMES`, tolerating an optional trailing dot (the wire form is
/// always "rooted"; a resolver's textual form often is not).
fn is_special_name(name: &str) -> bool {
    let trimmed = name.trim_end_matches('.');
    SPECIAL_NAMES
        .iter()
        .any(|n| n.eq_ignore_ascii_case(trimmed))
}

/// A decoded question section: the name (dotted, no trailing dot), qtype,
/// qclass, and the byte offset immediately past it.
struct Question {
    name: String,
    qtype: u16,
    qclass: u16,
    end: usize,
}

/// Parse the question section of a DNS query starting at the fixed 12-byte
/// header. Returns `None` on anything malformed rather than panicking — this
/// runs on input from every container's resolver, and the only acceptable
/// failure mode is "forward it upstream unexamined."
///
/// Compression pointers are deliberately not implemented: nothing before the
/// question section of a *query* could be a valid backward-pointer target,
/// so a real resolver never sends one there. A query that does anyway simply
/// fails to parse here (see `a_compressed_name_is_not_understood_and_falls_
/// through`) and is forwarded untouched, where the real upstream answers it
/// regardless — the fallback path costs nothing.
fn parse_question(msg: &[u8]) -> Option<Question> {
    if msg.len() < 12 {
        return None;
    }
    let qdcount = u16::from_be_bytes([msg[4], msg[5]]);
    if qdcount == 0 {
        return None;
    }
    let mut pos = 12usize;
    let mut labels = Vec::new();
    loop {
        let len = *msg.get(pos)? as usize;
        if len == 0 {
            pos += 1;
            break;
        }
        // Reject compression pointers (top two bits set) rather than
        // misreading their two bytes as a label length + one data byte.
        if len & 0xC0 != 0 {
            return None;
        }
        pos += 1;
        let label = msg.get(pos..pos + len)?;
        labels.push(String::from_utf8_lossy(label).into_owned());
        pos += len;
    }
    let qtype = u16::from_be_bytes([*msg.get(pos)?, *msg.get(pos + 1)?]);
    let qclass = u16::from_be_bytes([*msg.get(pos + 2)?, *msg.get(pos + 3)?]);
    pos += 4;
    Some(Question {
        name: labels.join("."),
        qtype,
        qclass,
        end: pos,
    })
}

/// Build a synthetic reply for a query already known (by `answer_locally`)
/// to be one this stub answers for itself.
///
/// The original question section is echoed back byte-for-byte
/// (`msg[12..question.end]`) rather than re-encoded, so nothing here needs
/// to re-serialize a domain name — one less place to get wire format wrong.
/// The answer record's own name is a compression pointer back to that same
/// echoed question (offset 12), which every resolver understands.
fn build_answer(msg: &[u8], question: &Question, answer: Ipv4Addr) -> Vec<u8> {
    let mut out = Vec::with_capacity(question.end + 16);
    out.push(msg[0]);
    out.push(msg[1]); // same transaction ID
    let rd = msg[2] & 0x01;
    out.push(0x80 | rd); // QR=1 (response), Opcode=0, AA=0, TC=0, RD=copied
    out.push(0x80); // RA=1, Z=0, RCODE=0 (NOERROR)
    out.extend_from_slice(&1u16.to_be_bytes()); // QDCOUNT
    let ancount: u16 = if question.qtype == TYPE_A { 1 } else { 0 };
    out.extend_from_slice(&ancount.to_be_bytes());
    out.extend_from_slice(&0u16.to_be_bytes()); // NSCOUNT
    out.extend_from_slice(&0u16.to_be_bytes()); // ARCOUNT
    out.extend_from_slice(&msg[12..question.end]);
    if question.qtype == TYPE_A {
        out.extend_from_slice(&0xC00Cu16.to_be_bytes()); // name = pointer to offset 12
        out.extend_from_slice(&TYPE_A.to_be_bytes());
        out.extend_from_slice(&CLASS_IN.to_be_bytes());
        out.extend_from_slice(&ANSWER_TTL.to_be_bytes());
        out.extend_from_slice(&4u16.to_be_bytes()); // RDLENGTH
        out.extend_from_slice(&answer.octets());
    }
    out
}

/// The whole local-answer decision, pure and independent of any socket:
/// given a raw query and the address to answer with, returns the reply
/// bytes if this stub should answer locally, or `None` if the query should
/// be forwarded upstream unmodified (not one of the two special names, or
/// too malformed to be sure).
pub fn answer_locally(query: &[u8], answer: Ipv4Addr) -> Option<Vec<u8>> {
    let question = parse_question(query)?;
    if question.qclass != CLASS_IN {
        return None;
    }
    if !is_special_name(&question.name) {
        return None;
    }
    if question.qtype != TYPE_A && question.qtype != TYPE_AAAA {
        // Anything else (PTR, TXT, SOA...) for these names: let the real
        // upstream answer — it may have something more sensible to say
        // (e.g. authoritative NXDOMAIN) than a stub that only knows A/AAAA.
        return None;
    }
    Some(build_answer(query, &question, answer))
}

#[cfg(target_os = "linux")]
mod imp {
    use super::{answer_locally, DNS_PORT, MAX_CONCURRENT_FORWARDS, MAX_MESSAGE, UPSTREAM_TIMEOUT};
    use crate::log;
    use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, UdpSocket};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::thread;

    /// Bind the stub on every guest address — so both dockerd's own
    /// root-netns embedded-DNS forwarding (reachable via loopback or the
    /// guest's own address) and containers on the legacy default-bridge
    /// network (reachable only via the guest's real interface address; see
    /// the module docs) can reach it — and serve it from its own thread.
    ///
    /// `answer` is the address handed back for host.docker.internal /
    /// gateway.docker.internal; `upstream` is where every other query is
    /// forwarded, unmodified, byte for byte.
    pub fn spawn_split_dns(answer: Ipv4Addr, upstream: Ipv4Addr) -> std::io::Result<()> {
        let socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, DNS_PORT))?;
        log::log(&format!(
            "split DNS listening on 0.0.0.0:{} — host.docker.internal and \
             gateway.docker.internal answer {}, everything else forwards to {}",
            DNS_PORT, answer, upstream
        ));
        thread::Builder::new()
            .name("split-dns".to_string())
            .spawn(move || serve(socket, answer, upstream))?;
        Ok(())
    }

    fn serve(socket: UdpSocket, answer: Ipv4Addr, upstream: Ipv4Addr) {
        let in_flight_forwards = Arc::new(AtomicUsize::new(0));
        let mut buf = [0u8; MAX_MESSAGE];
        loop {
            let (len, from) = match socket.recv_from(&mut buf) {
                Ok(v) => v,
                Err(e) => {
                    log::log(&format!("split DNS recv error: {} — continuing", e));
                    continue;
                }
            };
            let query = &buf[..len];
            match answer_locally(query, answer) {
                Some(reply) => {
                    if let Err(e) = socket.send_to(&reply, from) {
                        log::log(&format!("split DNS could not reply to {}: {}", from, e));
                    }
                }
                None => spawn_forward(
                    &socket,
                    query,
                    from,
                    upstream,
                    Arc::clone(&in_flight_forwards),
                ),
            }
        }
    }

    /// Forward ordinary DNS requests off the receive loop. A DNS lookup for
    /// an unrelated name may wait up to `UPSTREAM_TIMEOUT`; keeping it on
    /// `serve` would make that one timeout stall the special-name replies
    /// too. The bounded counter is deliberately acquired before cloning the
    /// socket or allocating a packet copy.
    fn spawn_forward(
        main: &UdpSocket,
        query: &[u8],
        from: SocketAddr,
        upstream: Ipv4Addr,
        in_flight: Arc<AtomicUsize>,
    ) {
        if !try_acquire_forward(&in_flight) {
            log::log("split DNS forward limit reached — dropping query so the resolver can retry");
            return;
        }

        let main = match main.try_clone() {
            Ok(socket) => socket,
            Err(e) => {
                in_flight.fetch_sub(1, Ordering::Release);
                log::log(&format!("split DNS could not clone receive socket: {}", e));
                return;
            }
        };
        let query = query.to_vec();
        let worker_in_flight = Arc::clone(&in_flight);
        if let Err(e) = thread::Builder::new()
            .name("split-dns-forward".to_string())
            .spawn(move || {
                forward(&main, &query, from, upstream);
                worker_in_flight.fetch_sub(1, Ordering::Release);
            })
        {
            in_flight.fetch_sub(1, Ordering::Release);
            log::log(&format!("split DNS could not spawn forwarder: {}", e));
        }
    }

    fn try_acquire_forward(in_flight: &AtomicUsize) -> bool {
        let mut current = in_flight.load(Ordering::Acquire);
        loop {
            if current >= MAX_CONCURRENT_FORWARDS {
                return false;
            }
            match in_flight.compare_exchange_weak(
                current,
                current + 1,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => return true,
                Err(observed) => current = observed,
            }
        }
    }

    /// Forward one query to `upstream` and relay its reply back to `from`,
    /// on a short-lived socket of its own so a dead or slow upstream can
    /// only ever stall the single query that hit it, never `serve`'s one
    /// socket that every other query also depends on.
    fn forward(main: &UdpSocket, query: &[u8], from: SocketAddr, upstream: Ipv4Addr) {
        let sock = match UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)) {
            Ok(s) => s,
            Err(e) => {
                log::log(&format!(
                    "split DNS could not open a forwarding socket: {}",
                    e
                ));
                return;
            }
        };
        if let Err(e) = sock.set_read_timeout(Some(UPSTREAM_TIMEOUT)) {
            log::log(&format!(
                "split DNS could not set a forwarding timeout: {}",
                e
            ));
            return;
        }
        let upstream_addr = SocketAddrV4::new(upstream, DNS_PORT);
        if let Err(e) = sock.send_to(query, upstream_addr) {
            log::log(&format!(
                "split DNS could not reach upstream {}: {}",
                upstream_addr, e
            ));
            return;
        }
        let mut reply = [0u8; MAX_MESSAGE];
        match sock.recv_from(&mut reply) {
            Ok((n, _)) => {
                if let Err(e) = main.send_to(&reply[..n], from) {
                    log::log(&format!(
                        "split DNS could not relay upstream's reply to {}: {}",
                        from, e
                    ));
                }
            }
            Err(e) => {
                // Normal for a client that gave up and retried, or a
                // genuinely slow/unreachable upstream — not worth more than
                // a note in the console log.
                log::log(&format!(
                    "split DNS got no answer from upstream {} within {:?}: {}",
                    upstream_addr, UPSTREAM_TIMEOUT, e
                ));
            }
        }
    }
}

#[cfg(target_os = "linux")]
pub use imp::spawn_split_dns;

#[cfg(test)]
mod tests {
    use super::*;

    /// Hand-encode a minimal DNS query: one question, no EDNS0, RD=1.
    fn encode_query(id: u16, name: &str, qtype: u16) -> Vec<u8> {
        let mut msg = Vec::new();
        msg.extend_from_slice(&id.to_be_bytes());
        msg.extend_from_slice(&0x0100u16.to_be_bytes()); // RD=1, standard query
        msg.extend_from_slice(&1u16.to_be_bytes()); // QDCOUNT
        msg.extend_from_slice(&0u16.to_be_bytes());
        msg.extend_from_slice(&0u16.to_be_bytes());
        msg.extend_from_slice(&0u16.to_be_bytes());
        for label in name.split('.') {
            msg.push(label.len() as u8);
            msg.extend_from_slice(label.as_bytes());
        }
        msg.push(0);
        msg.extend_from_slice(&qtype.to_be_bytes());
        msg.extend_from_slice(&CLASS_IN.to_be_bytes());
        msg
    }

    #[test]
    fn answers_host_docker_internal_with_the_gateway_address() {
        let query = encode_query(0xBEEF, "host.docker.internal", TYPE_A);
        let answer_ip: Ipv4Addr = "192.168.64.1".parse().unwrap();
        let reply = answer_locally(&query, answer_ip).expect("should answer locally");

        assert_eq!(&reply[0..2], &0xBEEFu16.to_be_bytes());
        assert_eq!(reply[2] & 0x80, 0x80, "QR bit must be set on a reply");
        assert_eq!(reply[2] & 0x01, 1, "RD must be echoed back");
        assert_eq!(reply[3], 0x80, "RA set, RCODE NOERROR");
        assert_eq!(&reply[4..6], &1u16.to_be_bytes(), "one question echoed");
        assert_eq!(&reply[6..8], &1u16.to_be_bytes(), "one answer");
        // The answer RR's RDATA is the last 4 bytes.
        assert_eq!(&reply[reply.len() - 4..], &answer_ip.octets());
    }

    #[test]
    fn gateway_docker_internal_is_also_answered() {
        let query = encode_query(1, "gateway.docker.internal", TYPE_A);
        let answer_ip: Ipv4Addr = "10.0.0.1".parse().unwrap();
        assert!(answer_locally(&query, answer_ip).is_some());
    }

    #[test]
    fn is_case_insensitive() {
        let query = encode_query(1, "Host.Docker.Internal", TYPE_A);
        assert!(answer_locally(&query, "1.2.3.4".parse().unwrap()).is_some());
    }

    #[test]
    fn unrelated_names_are_forwarded_not_answered() {
        let query = encode_query(1, "example.com", TYPE_A);
        assert!(answer_locally(&query, "1.2.3.4".parse().unwrap()).is_none());
    }

    #[test]
    fn aaaa_queries_get_a_noerror_zero_answer_reply_not_a_forward() {
        let query = encode_query(42, "host.docker.internal", TYPE_AAAA);
        let reply = answer_locally(&query, "1.2.3.4".parse().unwrap()).expect("answered locally");
        assert_eq!(&reply[6..8], &0u16.to_be_bytes(), "zero answers for AAAA");
        assert_eq!(reply[3], 0x80, "still NOERROR, not an error");
    }

    #[test]
    fn other_record_types_for_the_special_names_are_forwarded() {
        let query = encode_query(1, "host.docker.internal", 12 /* PTR */);
        assert!(answer_locally(&query, "1.2.3.4".parse().unwrap()).is_none());
    }

    #[test]
    fn malformed_queries_fall_through_to_forwarding() {
        assert!(answer_locally(&[0u8; 4], "1.2.3.4".parse().unwrap()).is_none());
        assert!(answer_locally(&[], "1.2.3.4".parse().unwrap()).is_none());
    }

    #[test]
    fn a_compressed_name_is_not_understood_and_falls_through() {
        // A query with a compression pointer in the question section is not
        // something a real resolver would ever send (nothing before byte 12
        // is a valid backward target), but the parser must not panic on it
        // — it should simply decline to answer, which sends it upstream.
        let mut msg = encode_query(1, "x", TYPE_A);
        msg[12] = 0xC0; // compression-pointer marker in the length byte
        assert!(answer_locally(&msg, "1.2.3.4".parse().unwrap()).is_none());
    }

    #[test]
    fn the_two_special_names_are_exactly_the_documented_pair() {
        assert_eq!(
            SPECIAL_NAMES,
            ["host.docker.internal", "gateway.docker.internal"]
        );
    }
}
