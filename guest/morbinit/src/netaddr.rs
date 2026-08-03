//! Pure address-parsing helpers for `net.rs`.
//!
//! Split out of `net.rs` specifically because that file is
//! `#![cfg(target_os = "linux")]` in full (it shells out to busybox and
//! brings up real interfaces), which would take any tests living there down
//! with it — this crate's dev/CI loop runs `cargo test` on the macOS host,
//! per `Cargo.toml`'s contract that "every library module still compiles and
//! is unit tested there." Nothing in this module touches the filesystem, a
//! socket, or a subprocess; it only turns text `net.rs` already collected
//! into typed addresses.

/// Pure parser for `ip -4 -o addr show <iface>` output, e.g.:
/// `2: eth0    inet 192.168.64.3/24 brd 192.168.64.255 scope global eth0\...`
///
/// Returns the first `inet` address found (an interface normally has at most
/// one IPv4 address in this guest's configuration).
pub fn parse_ipv4_addr_show(text: &str) -> Option<std::net::Ipv4Addr> {
    let tokens: Vec<&str> = text.split_whitespace().collect();
    let inet_at = tokens.iter().position(|&t| t == "inet")?;
    let cidr = tokens.get(inet_at + 1)?;
    cidr.split('/').next()?.parse().ok()
}

/// Pure parser for `/proc/net/route`. Columns are tab-separated:
/// `Iface Destination Gateway Flags RefCnt Use Metric Mask MTU Window IRTT`;
/// the default route is the row whose `Destination` is `00000000`, and the
/// kernel formats `Gateway` (like `Destination`) as 8 hex digits that are the
/// address's bytes in *little-endian* order regardless of host endianness —
/// a long-standing `/proc/net/route` quirk, not an artifact of this parser.
pub fn parse_default_gateway(text: &str) -> Option<std::net::Ipv4Addr> {
    for line in text.lines().skip(1) {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() < 3 || fields[1] != "00000000" {
            continue;
        }
        let raw = u32::from_str_radix(fields[2], 16).ok()?;
        let bytes = raw.to_le_bytes();
        return Some(std::net::Ipv4Addr::new(bytes[0], bytes[1], bytes[2], bytes[3]));
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_real_ip_addr_show_line() {
        let text = "2: eth0    inet 192.168.64.3/24 brd 192.168.64.255 scope global eth0\\       valid_lft forever preferred_lft forever";
        assert_eq!(
            parse_ipv4_addr_show(text),
            Some("192.168.64.3".parse().unwrap())
        );
    }

    #[test]
    fn ip_addr_show_with_no_inet_line_is_none() {
        assert_eq!(
            parse_ipv4_addr_show("2: eth0    inet6 fe80::1/64 scope link"),
            None
        );
        assert_eq!(parse_ipv4_addr_show(""), None);
    }

    #[test]
    fn parses_the_default_gateway_from_proc_net_route() {
        // Real /proc/net/route shape: a header line, then one row per route.
        // 0140A8C0 decodes (little-endian bytes) to 192.168.64.1 — the
        // address docs/parity.md #22 confirms actually reaches the Mac.
        let text = "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\t\
                     Mask\t\tMTU\tWindow\tIRTT\n\
                     eth0\t00000000\t0140A8C0\t0003\t0\t0\t0\t\
                     00000000\t0\t0\t0\n\
                     eth0\t0040A8C0\t00000000\t0001\t0\t0\t0\t\
                     00FFFFFF\t0\t0\t0\n";
        assert_eq!(
            parse_default_gateway(text),
            Some("192.168.64.1".parse().unwrap())
        );
    }

    #[test]
    fn no_default_route_is_none() {
        let text = "Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT\n\
                     eth0\t0040A8C0\t00000000\t0001\t0\t0\t0\t00FFFFFF\t0\t0\t0\n";
        assert_eq!(parse_default_gateway(text), None);
    }

    #[test]
    fn empty_route_table_is_none() {
        assert_eq!(parse_default_gateway(""), None);
        assert_eq!(parse_default_gateway("Iface\tDestination\tGateway\n"), None);
    }
}
