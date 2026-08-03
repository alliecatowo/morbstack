//! Guest network bring-up.
//!
//! The host attaches a `VZNATNetworkDeviceAttachment`, which gives the guest
//! a virtio-net `eth0` behind macOS's NAT with a DHCP server on the other
//! end. Nothing brings that interface up automatically in an initramfs, so
//! PID 1 does it, using the busybox already present in the Alpine-derived
//! initramfs rather than linking a DHCP client of our own:
//!
//!   busybox ip link set lo up
//!   busybox ip link set eth0 up
//!   busybox udhcpc -i eth0 -n -q -t 8
//!
//! IMAGE PIPELINE REQUIREMENT: `udhcpc` does not configure anything itself —
//! it execs a script (default `/usr/share/udhcpc/default.script`) with the
//! lease details in the environment, and that script is what actually sets
//! the address, default route and `/etc/resolv.conf`. Alpine ships it in the
//! `busybox` package; the initramfs build MUST include
//! `/usr/share/udhcpc/default.script` (executable) or DHCP will "succeed"
//! with no addressing applied. If it is missing we tolerate the failure:
//! `bring_up_network` returns false, we still write a fallback resolv.conf,
//! and boot continues — docker can serve locally loaded images without a
//! network.
//!
//! Timing note: this runs during the single-threaded part of boot, *before*
//! the supervisor's `waitpid(-1)` reaper starts, so `Command::status()`
//! reaping its own child cannot race the reaper.
#![cfg(target_os = "linux")]

use crate::log;
use std::io;
use std::path::Path;
use std::process::{Command, Stdio};

/// busybox's canonical location in the Alpine initramfs.
const BUSYBOX: &str = "/bin/busybox";
/// Where udhcpc expects its lease-handling script to live.
const UDHCPC_SCRIPT: &str = "/usr/share/udhcpc/default.script";
const RESOLV_CONF: &str = "/etc/resolv.conf";
/// Used when DHCP gave us no resolver, per the shared contract.
const FALLBACK_NAMESERVER: &str = "1.1.1.1";

/// Bring up `lo` and `eth0` and acquire a DHCP lease. Returns whether DHCP
/// succeeded. Never fatal: a guest with no network still boots and still
/// serves the Docker API over vsock.
pub fn bring_up_network() -> bool {
    if !Path::new(BUSYBOX).exists() {
        log::log(&format!(
            "WARNING: {} not found — cannot configure networking; the guest will have \
             no network (docker can still run already-present images)",
            BUSYBOX
        ));
        write_fallback_resolv_conf();
        return false;
    }

    // Loopback first: dockerd and containerd talk to themselves over it.
    run_busybox(&["ip", "link", "set", "lo", "up"]);
    run_busybox(&["ip", "link", "set", "eth0", "up"]);

    if !Path::new(UDHCPC_SCRIPT).exists() {
        log::log(&format!(
            "WARNING: {} is missing — udhcpc cannot apply a lease without it \
             (initramfs must ship busybox's default.script); attempting DHCP anyway",
            UDHCPC_SCRIPT
        ));
    }

    // -n: give up rather than daemonize if no lease; -q: quit after the
    // lease is obtained; -t 8: eight discover attempts.
    let dhcp_ok = run_busybox(&["udhcpc", "-i", "eth0", "-n", "-q", "-t", "8"]);
    if dhcp_ok {
        log::log("DHCP lease acquired on eth0");
    } else {
        log::log(
            "WARNING: DHCP on eth0 FAILED — the guest has no routable address. \
             Image pulls will not work; locally present images still will.",
        );
    }

    // Even on success, the lease script may not have written a resolver
    // (e.g. a lease with no DNS option); make sure something is there.
    ensure_resolv_conf();
    dhcp_ok
}

/// Run `busybox <args>`, logging the outcome. Returns true on exit status 0.
fn run_busybox(args: &[&str]) -> bool {
    match Command::new(BUSYBOX)
        .args(args)
        .stdin(Stdio::null())
        .status()
    {
        Ok(status) if status.success() => {
            log::log(&format!("busybox {} — ok", args.join(" ")));
            true
        }
        Ok(status) => {
            log::log(&format!("busybox {} — failed ({})", args.join(" "), status));
            false
        }
        Err(e) => {
            log::log(&format!(
                "busybox {} — could not run: {}",
                args.join(" "),
                e
            ));
            false
        }
    }
}

/// `net.ipv4.ip_forward`. Without this the kernel drops every packet that
/// arrives on `docker0` destined for anywhere else, so containers can reach
/// each other and nothing beyond — dockerd's NAT rules are all present and
/// entirely inert.
///
/// dockerd does set this itself when it creates the default bridge, but only
/// when it is managing iptables; setting it here means the sysctl is already
/// correct before dockerd starts, and stays correct in the configurations
/// where dockerd would not have touched it.
const IP_FORWARD_SYSCTL: &str = "/proc/sys/net/ipv4/ip_forward";

/// Bridged traffic only traverses iptables when these are on. They live in
/// the `br_netfilter` module, so the files exist only once something has
/// pulled it in; dockerd loads it when it programs the bridge. Best effort
/// by design — see `enable_container_forwarding`.
const BRIDGE_NF_SYSCTLS: &[&str] = &[
    "/proc/sys/net/bridge/bridge-nf-call-iptables",
    "/proc/sys/net/bridge/bridge-nf-call-ip6tables",
];

/// Turn on the kernel-side switches container NAT depends on.
///
/// `ip_forward` is the one that matters and is reported loudly if it fails.
/// The `bridge-nf-*` knobs are opportunistic: they only exist once
/// `br_netfilter` is loaded, which normally happens later (when dockerd
/// creates `docker0`), so "no such file" here is the expected case on a cold
/// boot and is not worth a warning.
pub fn enable_container_forwarding() {
    match std::fs::write(IP_FORWARD_SYSCTL, b"1\n") {
        Ok(()) => log::log("net.ipv4.ip_forward = 1"),
        Err(e) => log::log(&format!(
            "WARNING: could not set net.ipv4.ip_forward: {} — containers will have no \
             outbound connectivity",
            e
        )),
    }

    for path in BRIDGE_NF_SYSCTLS {
        if Path::new(path).exists() {
            if let Err(e) = std::fs::write(path, b"1\n") {
                log::log(&format!("could not set {}: {}", path, e));
            }
        }
    }
}

/// Write the fallback resolver unless DHCP already produced a usable one.
fn ensure_resolv_conf() {
    let has_nameserver = std::fs::read_to_string(RESOLV_CONF)
        .map(|s| s.lines().any(|l| l.trim_start().starts_with("nameserver")))
        .unwrap_or(false);
    if has_nameserver {
        return;
    }
    log::log(&format!(
        "{} has no nameserver — writing fallback {}",
        RESOLV_CONF, FALLBACK_NAMESERVER
    ));
    write_fallback_resolv_conf();
}

fn write_fallback_resolv_conf() {
    if let Err(e) = write_resolv_conf() {
        log::log(&format!("WARNING: could not write {}: {}", RESOLV_CONF, e));
    }
}

fn write_resolv_conf() -> io::Result<()> {
    if let Some(parent) = Path::new(RESOLV_CONF).parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(RESOLV_CONF, format!("nameserver {}\n", FALLBACK_NAMESERVER))
}

// ---------------------------------------------------------------------------
// host.docker.internal / gateway.docker.internal (docs/parity.md #18/#19).
//
// Two addresses this module can discover, both needed by `dns.rs` and by the
// `--dns`/`--host-gateway-ip` flags `supervisor::default_services` passes to
// dockerd:
//
//   * the guest's own address on eth0 (`guest_ipv4`) — a normal, locally
//     owned address that containers on the *legacy* default bridge network
//     can dial directly (dockerd writes `--dns` server IPs straight into
//     those containers' /etc/resolv.conf; there is no embedded-DNS layer to
//     do any NAT/pointer trick for them, so the address has to be one the
//     kernel actually routes back to this host, not merely "reachable in the
//     abstract"). The split-DNS stub in `dns.rs` binds every guest address
//     including this one, so it answers there too.
//   * the VM's default gateway (`default_gateway`) — the one address that is
//     empirically confirmed (docs/parity.md #22) to reach a listener on the
//     Mac, because Virtualization.framework's NAT device treats its own
//     gateway address as "the host". This is both the answer the split-DNS
//     stub gives for host.docker.internal/gateway.docker.internal, and the
//     value handed to dockerd's own `--host-gateway-ip`, so the two
//     mechanisms (Morbstack's default DNS answer, and the documented
//     `--add-host=foo:host-gateway` spelling) always agree.
//
// The actual byte-parsing is pure and lives in `netaddr.rs` (untangled from
// this file's `#![cfg(target_os = "linux")]`, specifically so it can be unit
// tested on the macOS dev host — see that module's header). This pair of
// functions is the only place that parsing meets real I/O.
// ---------------------------------------------------------------------------

/// The guest's own IPv4 address on `eth0`, as leased by DHCP.
///
/// Parsed from `busybox ip -4 -o addr show eth0` rather than an ioctl: this
/// crate has zero external dependencies and no libc socket-ioctl bindings of
/// its own (see `sys.rs`'s header), and busybox is already a hard
/// prerequisite for bringing the interface up at all in `bring_up_network`.
pub fn guest_ipv4() -> Option<std::net::Ipv4Addr> {
    let output = Command::new(BUSYBOX)
        .args(["ip", "-4", "-o", "addr", "show", "eth0"])
        .stdin(Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    crate::netaddr::parse_ipv4_addr_show(&String::from_utf8_lossy(&output.stdout))
}

/// The default route's gateway address, read from `/proc/net/route`.
///
/// A raw `/proc` read rather than `ip route show default | ...` parsing:
/// the kernel's own table needs no external command and no textual
/// column-format guessing.
pub fn default_gateway() -> Option<std::net::Ipv4Addr> {
    let text = std::fs::read_to_string("/proc/net/route").ok()?;
    crate::netaddr::parse_default_gateway(&text)
}

/// The configured, container-reachable IPv4 DNS resolver.
///
/// `bring_up_network` ensures `/etc/resolv.conf` has at least a fallback
/// resolver before this is called. The NAT route gateway and DHCP's resolver
/// are often the same address, but they are separate pieces of configuration:
/// forwarding every non-special lookup to the route gateway would otherwise
/// make host-alias support break ordinary image pulls on networks whose DHCP
/// server supplies a different resolver.
pub fn dns_upstream_ipv4() -> Option<std::net::Ipv4Addr> {
    let text = std::fs::read_to_string(RESOLV_CONF).ok()?;
    crate::netaddr::parse_resolv_conf_ipv4_nameserver(&text)
}
