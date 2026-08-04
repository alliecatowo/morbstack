//! Service supervisor: spawns and restarts the long-running processes
//! morbinit is responsible for (containerd, dockerd), with exponential
//! backoff on repeated failure, and stops them cleanly on shutdown.
//!
//! Design note — no async runtime: morbinit is PID 1 for a single-purpose
//! guest VM babysitting at most a couple of processes. Pulling in an async
//! executor (even a hand-rolled one) would add real complexity — a
//! reactor, task scheduling, cross-task synchronization — for no benefit
//! over a plain loop: `tick()` is called once per iteration of morbinit's
//! main loop, does a bounded amount of non-blocking work (reap zombies,
//! maybe spawn a process), and returns immediately. The blocking servers
//! (control channel, docker proxy, stream dialer) each own a thread of their
//! own so they can never stall this loop — see `main.rs`.
//!
//! Design note — one reaper, one source of truth: PID 1 inherits every
//! orphan in the guest, so it must call `waitpid(-1)` in a loop or leak
//! zombies. That drain is therefore the *only* thing that reaps, including
//! for our own services. Calling `Child::try_wait()` as well would be a
//! race we always lose: the drain reaps the pid first, `try_wait` then gets
//! `ECHILD` forever, and the service's `Child` handle stays `Some` so it is
//! never restarted. Instead we record each service's pid at spawn time and
//! match the drain's results against that table (`note_child_exit`).
//!
//! Design note — the `Platform` seam: every syscall the state machines make
//! (spawn, reap, signal, clock, sleep) goes through the `Platform` trait.
//! That is not abstraction for its own sake. Restart backoff and the
//! SIGTERM/SIGKILL shutdown ladder are both *timing* logic, and timing logic
//! tested against the real clock is either slow or a lie. With the seam, a
//! crash loop that would take a minute of wall time runs instantly against a
//! fake clock and asserts the exact backoff sequence — see the tests at the
//! bottom of this file.

use crate::log;
use crate::proxy::DOCKER_SOCK;
use std::path::Path;
use std::process::{Child, Command};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// Description of a service morbinit supervises. Argument lists are owned
/// because some of them depend on what boot discovered (e.g. whether
/// docker's data root is on a real disk) — see `default_services`.
pub struct ServiceSpec {
    pub name: &'static str,
    pub path: &'static str,
    pub args: Vec<String>,
    /// Extra environment variables, layered on top of `GUEST_PATH`.
    pub env: Vec<(&'static str, &'static str)>,
    /// An optional on/off switch, checked on every tick.
    ///
    /// `None` — the overwhelming majority — means "always supposed to be
    /// running", which is every service morbinit had before Kubernetes: the
    /// engine is the reason the guest exists and there is no state in which it
    /// should be down.
    ///
    /// `Some(flag)` makes the service *optional at runtime*. While the flag is
    /// low the supervisor will not spawn it, will not log it as missing, and
    /// will not schedule retries for it; raising the flag starts it on the next
    /// tick and lowering it stops it on the next tick, with the same
    /// SIGTERM/SIGKILL ladder as a shutdown. That is what lets `morb k8s
    /// enable` be a single atomic store rather than a control-channel thread
    /// blocking on a process launch — see `k8s.rs`.
    pub gate: Option<Arc<AtomicBool>>,
}

impl ServiceSpec {
    /// Whether this service is currently wanted.
    fn wanted(&self) -> bool {
        self.gate
            .as_ref()
            .map(|g| g.load(Ordering::SeqCst))
            .unwrap_or(true)
    }

    /// How long this service gets to honour SIGTERM, and then how long to wait
    /// after SIGKILL.
    ///
    /// Gated (optional) services get the short ladder, and that is a budget
    /// decision as much as a correctness one. `control::SHUTDOWN_REPLY_TIMEOUT`
    /// is derived from the worst-case stop sequence and has to stay under the
    /// host's 65 s ack timeout with room for the reply itself — which left
    /// roughly six seconds of headroom before Kubernetes existed. It fits
    /// because the optional services can afford it: k3s keeps its state in a
    /// crash-safe SQLite database and cri-dockerd keeps none at all, so a
    /// SIGKILL costs a slower next start, not data. dockerd, whose SIGTERM
    /// handler is flushing a layer store, keeps the full ten seconds.
    fn stop_ladder(&self) -> (Duration, Duration) {
        if self.gate.is_some() {
            (GATED_STOP_GRACE, GATED_KILL_GRACE)
        } else {
            (STOP_GRACE, KILL_GRACE)
        }
    }
}

/// containerd's socket, which dockerd is pointed at explicitly. This is
/// also containerd's own compiled-in default, which is why morbinit writes
/// no `/etc/containerd/config.toml`: a hand-written config would have to
/// declare a `version` matching whichever containerd the guest image ships,
/// and getting that wrong is a startup failure. Defaults are correct here,
/// so the right amount of config is none.
const CONTAINERD_SOCK: &str = "/run/containerd/containerd.sock";

/// Directories the services need to exist before they start. `/run` and
/// `/tmp` are tmpfs (see `mounts.rs`), so these are recreated every boot.
const RUNTIME_DIRS: &[&str] = &["/run/containerd", "/var/run", "/var/lib/containerd"];

/// The stock upstream userland proxy, installed alongside the other Docker
/// engine binaries by `scripts/mkinitramfs.sh`. The Morbstack wrapper execs
/// it after the Mac-side port lease is granted.
const DOCKER_PROXY_BIN: &str = "/usr/local/bin/docker-proxy";

/// The Morbstack userland-proxy wrapper (a multi-call link to morbinit
/// itself; see `proxy_wrapper.rs`). Preferred as `--userland-proxy-path`:
/// it leases the published host port on the Mac — fail-closed — and then
/// execs ``DOCKER_PROXY_BIN`` with the original argv.
const MORBSTACK_PROXY_BIN: &str = "/usr/local/bin/morbstack-docker-proxy";

/// The Docker CLI, used for the one-shot offline image load (see
/// `load_baked_in_image`).
const DOCKER_CLI_BIN: &str = "/usr/local/bin/docker";

/// An OCI archive baked into the initramfs by `scripts/mkinitramfs.sh`, so
/// the guest can run `hello-world` with no registry and no network at all.
const BAKED_IMAGE_TAR: &str = "/usr/share/morb/hello-world-oci.tar";
/// The image the archive above is expected to contain.
const BAKED_IMAGE_NAME: &str = "hello-world";

/// `PATH` for every supervised service.
///
/// This is not cosmetic. The kernel hands `rdinit=/init` an environment with
/// no `PATH` at all, and both engines resolve helpers by name off `PATH`
/// rather than relative to their own argv[0]:
///
///   * dockerd looks up `docker-proxy` at startup and *aborts* if it can't
///     find it ("invalid userland-proxy-path: userland-proxy is enabled, but
///     userland-proxy-path is not set") — this crash-looped the whole boot,
///   * containerd execs `containerd-shim-runc-v2` by name for every
///     container, and the shim in turn execs `runc` by name,
///   * dockerd execs `iptables` by name to program the bridge's NAT rules.
///
/// So the services inherit a real `PATH` with our install dir first. Keeping
/// `/usr/local/bin` ahead of the Alpine directories also means our pinned
/// static binaries win over anything the rootfs happens to ship.
///
/// This is also the search path morbinit itself uses to decide what the
/// guest image contains (`disk::which`), so "what dockerd can find" and
/// "what we think dockerd can find" cannot drift apart.
pub const GUEST_PATH: &str = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";

/// dockerd's documented switch for "my root filesystem is a ramdisk": it
/// propagates `NoPivotRoot` through containerd's runc shim options, so runc
/// isolates with `MS_MOVE` + `chroot` instead of `pivot_root(2)`.
///
/// We need it because morbinit never leaves the initramfs. `/` is the
/// kernel's initial `rootfs` mount, which is the root of the mount namespace
/// and has no parent mount; `pivot_root` explicitly rejects that ("not
/// attached"), and it stays rejected in every cloned mount namespace, so
/// *every* container fails at create with `pivot_root .: invalid argument`.
/// Where `/var/lib/docker` lives makes no difference — the check is on the
/// old root, not the new one. So this stays set even once the data root is
/// on a real disk.
///
/// M2 follow-up: `chroot`-based isolation is weaker than `pivot_root` (the
/// old root stays reachable through stray fds, the classic container-escape
/// primitive). The real fix is to stop running from the initramfs —
/// `switch_root` into the formatted `/dev/vda` instead of only mounting it
/// at `/var/lib/docker`.
const DOCKER_RAMDISK_ENV: &str = "DOCKER_RAMDISK";

/// dockerd's documented switch for lowering the minimum API version it
/// accepts, honoured by upstream moby since 25.0.
///
/// Stock moby 29 defaults its minimum to 1.44 and answers older version
/// probes with HTTP 400 — an **upstream default, not Morbstack behaviour**.
/// That default breaks a large installed base silently: testcontainers-java
/// <= 1.20.x (docker-java <= 3.4.0) probes `GET /v1.32/info` during daemon
/// discovery, treats the 400 as "not a working daemon", and fails over to
/// whatever other engine is on the machine without a word to the user — a
/// green test suite against the wrong Docker. No client-side environment
/// variable rescues those versions, so the daemon has to accept the probe.
///
/// 1.24 is upstream's hard floor (`MinSupportedAPIVersion`); the daemon
/// refuses to start with anything lower, and anything higher re-breaks some
/// band of old clients for no gain. Lowering the minimum only *widens* what
/// is accepted — modern clients still negotiate the highest mutual version
/// exactly as before — which is also why this is unconditional rather than a
/// config toggle: the failure it prevents is silent and severe, and the cost
/// is accepting API verbs the engine already implements.
const DOCKER_MIN_API_VERSION_ENV: &str = "DOCKER_MIN_API_VERSION";
const DOCKER_MIN_API_VERSION: &str = "1.24";

/// Morbstack owns the default Docker bridge, so keep its gateway stable.
///
/// Containers on Docker's legacy default bridge reach the guest through this
/// address, not through the VM's NAT-facing `eth0` lease. The split-DNS
/// listener binds `0.0.0.0:53` before dockerd creates `docker0`, and the
/// kernel attaches that already-bound socket to this address when dockerd
/// brings the bridge up. Pinning `--bip` makes the DNS endpoint a real
/// contract rather than an assumption about dockerd's current default.
pub const DEFAULT_DOCKER_BRIDGE_GATEWAY: std::net::Ipv4Addr =
    std::net::Ipv4Addr::new(172, 17, 0, 1);
const DEFAULT_DOCKER_BRIDGE_CIDR: &str = "172.17.0.1/16";

/// How many services `default_services` returns (containerd, dockerd).
///
/// A constant rather than a `.len()` because `control::SHUTDOWN_REPLY_TIMEOUT`
/// has to be computed at compile time from the worst-case stop ladder, which
/// is `SUPERVISED_SERVICE_COUNT * (STOP_GRACE + KILL_GRACE)` — `stop_all_on`
/// walks the table one service at a time, so the graces add up rather than
/// overlapping. `default_services_length_matches_the_declared_count` keeps the
/// two from drifting; if you add a service, that test fails and the shutdown
/// budget (and the host-side budgets nested around it) must be revisited.
pub const SUPERVISED_SERVICE_COUNT: usize = 2;

/// The service table for a real boot, in start order (containerd first;
/// dockerd retries its containerd connection on its own, but starting them
/// in dependency order keeps the console log readable).
///
/// `docker_data_on_disk` comes from `disk::provision`: when docker's data
/// root is RAM-backed we must force the `vfs` storage driver, because
/// overlay2 refuses to stack on tmpfs/rootfs. vfs is slow and space-hungry
/// but correct. On a real disk we ask for `overlay2` explicitly rather than
/// letting dockerd pick, so a stale `vfs` layer store left behind by an
/// earlier boot cannot silently keep us on the slow driver forever.
pub fn default_services(docker_data_on_disk: bool) -> Vec<ServiceSpec> {
    let mut dockerd_args: Vec<String> = vec![
        "--host".to_string(),
        format!("unix://{}", DOCKER_SOCK),
        "--containerd".to_string(),
        CONTAINERD_SOCK.to_string(),
        "--storage-driver".to_string(),
        if docker_data_on_disk {
            "overlay2"
        } else {
            "vfs"
        }
        .to_string(),
        "--bip".to_string(),
        DEFAULT_DOCKER_BRIDGE_CIDR.to_string(),
    ];
    // No `-H tcp://...`: the Docker API reaches the host over AF_VSOCK port
    // 2375, proxied by morbinit itself (see `proxy.rs`). A TCP listener here
    // would hand unauthenticated root-equivalent access to anything that can
    // reach the guest's NAT address.

    // dockerd validates the userland proxy at startup and refuses to run if
    // it cannot resolve the helper — a hard `exit 1`, not a warning. We ship
    // both proxies next to dockerd, so point at one explicitly rather than
    // relying on a PATH lookup; if the image somehow lacks both, disabling
    // the userland proxy is strictly better than crash-looping.
    //
    // Preference order is load-bearing: the Morbstack wrapper is what makes
    // a published port fail closed when the Mac cannot bind it (it leases
    // the endpoint host-side, then execs the stock proxy). Falling back to
    // the bare stock proxy keeps containers working guest-side, but Mac
    // reachability then depends only on the event-driven forwarder, which
    // cannot refuse a start.
    if Path::new(MORBSTACK_PROXY_BIN).exists() && Path::new(DOCKER_PROXY_BIN).exists() {
        dockerd_args.push("--userland-proxy-path".to_string());
        dockerd_args.push(MORBSTACK_PROXY_BIN.to_string());
    } else if Path::new(DOCKER_PROXY_BIN).exists() {
        log::log(&format!(
            "{} not found — falling back to the stock {} (published ports lose \
             fail-closed Mac binding)",
            MORBSTACK_PROXY_BIN, DOCKER_PROXY_BIN
        ));
        dockerd_args.push("--userland-proxy-path".to_string());
        dockerd_args.push(DOCKER_PROXY_BIN.to_string());
    } else {
        log::log(&format!(
            "{} not found — starting dockerd with --userland-proxy=false",
            DOCKER_PROXY_BIN
        ));
        dockerd_args.push("--userland-proxy=false".to_string());
    }

    match find_iptables() {
        Some(found) => {
            // dockerd owns the NAT rules from here: it creates `docker0`,
            // MASQUERADEs the bridge subnet out of eth0, and adds the DNAT
            // rules that make `-p 8080:80` reachable. The kernel side
            // (xtables/netfilter) is compiled into the kata kernel, so the
            // userspace binary is the only prerequisite.
            log::log(&format!(
                "found {} — letting dockerd manage iptables (container NAT enabled)",
                found
            ));
        }
        None => {
            // Without an iptables binary dockerd aborts while programming the
            // default bridge's NAT rules. Containers then have no outbound
            // connectivity, but they do run.
            //
            // `--ip6tables=false` too: it defaults to on and is a *separate*
            // switch, so leaving it alone means dockerd retries the same
            // missing binary for IPv6 and logs "ip6tables is enabled, but
            // cannot set up ip6tables chains" on every boot.
            log::log(
                "no iptables binary found on the guest PATH — starting dockerd with \
                 --iptables=false --ip6tables=false (containers will have no outbound \
                 NAT and published ports will not work)",
            );
            dockerd_args.push("--iptables=false".to_string());
            dockerd_args.push("--ip6tables=false".to_string());
        }
    }

    vec![
        ServiceSpec {
            name: "containerd",
            path: "/usr/local/bin/containerd",
            args: Vec::new(),
            env: Vec::new(),
            gate: None,
        },
        ServiceSpec {
            name: "dockerd",
            path: "/usr/local/bin/dockerd",
            args: dockerd_args,
            env: vec![
                (DOCKER_RAMDISK_ENV, "1"),
                (DOCKER_MIN_API_VERSION_ENV, DOCKER_MIN_API_VERSION),
            ],
            gate: None,
        },
    ]
}

/// Adds the `--dns`/`--host-gateway-ip` flags that make
/// `host.docker.internal`/`gateway.docker.internal` resolve by default and
/// make `--add-host=foo:host-gateway` resolve to the right place
/// (docs/parity.md #18/#19), onto an already-built `dockerd` spec.
///
/// A separate function rather than extra parameters on `default_services`
/// itself: the split-DNS listener is known ready only after `main` has bound
/// and spawned it; the optional NAT-facing fallback and the host-gateway
/// address come from DHCP/NAT routing and can legitimately be unavailable.
/// If the listener failed to start this leaves out `--dns`, so dockerd keeps
/// its ordinary resolver setup rather than pointing containers at a failed
/// listener. `default_services`'s own five existing call sites (four of them
/// tests) stay untouched rather than growing parameters they would all have
/// to thread through as `None`.
///
///   * first `--dns`: `DEFAULT_DOCKER_BRIDGE_GATEWAY`, which every legacy
///     default-bridge container can reach directly. This is the primary path
///     for `docker run` with no `--network`.
///   * optional second `--dns <guest_eth0_ip>`: a NAT-facing fallback for
///     user-defined bridge networks, whose isolation rules can prevent a
///     packet from reaching `docker0` but still allow outbound traffic to the
///     guest's normal interface. Both addresses reach the same wildcard-bound
///     split-DNS socket.
///   * `--host-gateway-ip <gateway_ip>`: dockerd's own documented switch for
///     what the magic `host-gateway` string in `--add-host` resolves to.
///     Passing the same address `dns.rs`'s stub answers with keeps the two
///     mechanisms — Morbstack's default DNS answer, and the standard
///     `--add-host=foo:host-gateway` spelling — in agreement.
///
/// No-op (services returned unchanged) if `services` has no `dockerd` entry,
/// which cannot happen from `default_services` but keeps this total rather
/// than panicking on a table some future caller reshapes.
pub fn apply_dns_flags(
    mut services: Vec<ServiceSpec>,
    split_dns_ready: bool,
    guest_dns_fallback_ip: Option<std::net::Ipv4Addr>,
    host_gateway_ip: Option<std::net::Ipv4Addr>,
) -> Vec<ServiceSpec> {
    if let Some(dockerd) = services.iter_mut().find(|s| s.name == "dockerd") {
        // `--dns` is only useful after `main` has bound and spawned the
        // split-DNS listener. Supplying either address before then would
        // replace containers' normal DNS with a listener that does not exist.
        if split_dns_ready {
            dockerd.args.push("--dns".to_string());
            dockerd.args.push(DEFAULT_DOCKER_BRIDGE_GATEWAY.to_string());
            if let Some(ip) = guest_dns_fallback_ip {
                dockerd.args.push("--dns".to_string());
                dockerd.args.push(ip.to_string());
            }
        }
        if let Some(ip) = host_gateway_ip {
            dockerd.args.push("--host-gateway-ip".to_string());
            dockerd.args.push(ip.to_string());
        }
    }
    services
}

/// Whether dockerd in `services` was started with the userland proxy
/// (`docker-proxy`) enabled.
///
/// Read off the argument list we actually built rather than re-probing the
/// filesystem, so it reports what dockerd was *launched with* and cannot
/// disagree with it.
///
/// This matters well beyond dockerd's own behaviour: with the userland proxy
/// on, a published port has a real `127.0.0.1:<port>` listener inside the
/// guest, which is precisely what `dial.rs` connects to on the host's behalf.
/// With it off, publishing is DNAT-only — there is no loopback listener, and
/// every stream dial gets ECONNREFUSED. The host cannot see the difference, so
/// we report it in the MRB0 `info` reply and name it in the dial's `ERR` line.
pub fn userland_proxy_enabled(services: &[ServiceSpec]) -> bool {
    services
        .iter()
        .find(|s| s.name == "dockerd")
        .map(|s| !s.args.iter().any(|a| a == "--userland-proxy=false"))
        .unwrap_or(false)
}

/// The names dockerd might resolve for packet filtering, in the order it
/// tries them. `iptables` is usually a symlink to one of the other two.
const IPTABLES_NAMES: &[&str] = &["iptables", "iptables-nft", "iptables-legacy"];

/// Find an iptables binary on the same `PATH` dockerd will search. Returns
/// the resolved path for logging.
fn find_iptables() -> Option<String> {
    IPTABLES_NAMES
        .iter()
        .find_map(|name| crate::disk::which(name))
        .map(|p| p.display().to_string())
}

/// Create the directories containerd/dockerd expect. Best effort: each
/// failure is logged and boot continues, since the service itself will
/// produce a much more specific error if the directory really was needed.
pub fn prepare_runtime_dirs() {
    for dir in RUNTIME_DIRS {
        if let Err(e) = std::fs::create_dir_all(dir) {
            log::log(&format!("mkdir -p {} failed: {}", dir, e));
        }
    }
}

/// Initial and maximum restart backoff, per the shared contract
/// ("exponential backoff (1s..30s cap)").
const INITIAL_BACKOFF: Duration = Duration::from_secs(1);
const MAX_BACKOFF: Duration = Duration::from_secs(30);

/// How long a service has to stay up before we call the start a success and
/// forgive its restart history.
///
/// This threshold is the whole point of the backoff. Resetting on *spawn*
/// (which is what morbinit used to do) means a service that dies immediately
/// resets its own backoff every time it is restarted, so the delay is pinned
/// at 1s forever and "exponential backoff" degenerates into a hot restart
/// loop — a crash-looping dockerd then competes with the reaper for the CPU
/// and floods the console log. Only surviving `STABLE_RUNTIME` proves the
/// service actually got somewhere.
const STABLE_RUNTIME: Duration = Duration::from_secs(30);

/// How long to wait before re-checking for a missing binary. Not part of
/// the crash-restart backoff sequence (that's `next_backoff`) — a missing
/// binary isn't a crash, it's "this guest image doesn't have it".
const MISSING_BINARY_RECHECK_INTERVAL: Duration = Duration::from_secs(30);

/// How long a service gets to honour SIGTERM before it is killed outright.
/// dockerd needs most of this on a busy engine: it stops running containers,
/// waits for their shims, and flushes the layer store's metadata.
///
/// Crate-public because `control::SHUTDOWN_REPLY_TIMEOUT` is *derived* from
/// this ladder rather than guessed at. Read the comment on that constant
/// before changing this one: it participates in a nested budget that reaches
/// all the way out to the CLI.
pub const STOP_GRACE: Duration = Duration::from_secs(10);
/// How long we then wait for the corpse after SIGKILL. Only uninterruptible
/// kernel sleep can exceed this. Also feeds `control::SHUTDOWN_REPLY_TIMEOUT`.
pub const KILL_GRACE: Duration = Duration::from_secs(2);

/// The same ladder for gated (optional) services. See `ServiceSpec::stop_ladder`
/// for why these are shorter, and `control::SHUTDOWN_REPLY_TIMEOUT` for the
/// budget they have to fit inside.
///
/// Crate-public for the same reason as the pair above: the shutdown budget is
/// derived from them, not guessed.
pub const GATED_STOP_GRACE: Duration = Duration::from_secs(4);
pub const GATED_KILL_GRACE: Duration = Duration::from_secs(1);

/// Polling granularity while waiting for a stopping service to exit.
const STOP_POLL_INTERVAL: Duration = Duration::from_millis(50);

/// Pure backoff-doubling step, factored out so it's trivially unit
/// testable: doubles `current`, capped at `MAX_BACKOFF`.
fn next_backoff(current: Duration) -> Duration {
    let doubled = current.saturating_mul(2);
    if doubled > MAX_BACKOFF {
        MAX_BACKOFF
    } else {
        doubled
    }
}

/// Render a raw `waitpid(2)` status word the way a human reads it. Pure and
/// portable (the encoding is the same everywhere we care about), so it is
/// unit tested on the macOS dev host.
fn describe_wait_status(status: i32) -> String {
    let low = status & 0x7f;
    if low == 0 {
        format!("exit status {}", (status >> 8) & 0xff)
    } else if low == 0x7f {
        format!("stopped by signal {}", (status >> 8) & 0xff)
    } else {
        let core = if status & 0x80 != 0 {
            " (core dumped)"
        } else {
            ""
        };
        format!("killed by signal {}{}", low, core)
    }
}

enum StartOutcome {
    Started { pid: u32, child: Option<Child> },
    BinaryMissing,
    SpawnFailed(std::io::Error),
}

/// Every OS interaction the supervisor's state machines perform. See the
/// "Platform seam" note in the module docs for why this exists.
trait Platform {
    fn now(&self) -> Instant;
    fn start(&mut self, spec: &ServiceSpec) -> StartOutcome;
    /// One non-blocking reap. `None` means "nothing more to collect right
    /// now" — including the error cases, which the implementation logs.
    fn reap(&mut self) -> Option<(u32, i32)>;
    fn signal(&mut self, pid: u32, sig: i32);
    fn sleep(&mut self, dur: Duration);
}

/// The real thing: fork/exec, `waitpid(-1, WNOHANG)`, `kill(2)`, the
/// monotonic clock.
struct SystemPlatform;

impl Platform for SystemPlatform {
    fn now(&self) -> Instant {
        Instant::now()
    }

    fn start(&mut self, spec: &ServiceSpec) -> StartOutcome {
        if !Path::new(spec.path).exists() {
            return StartOutcome::BinaryMissing;
        }
        // stdout/stderr are deliberately inherited: PID 1's are the kernel
        // console, so containerd/dockerd diagnostics land in the host's
        // console.log next to morbinit's own.
        //
        // PATH is set explicitly because PID 1 doesn't have one to inherit —
        // see `GUEST_PATH`. Everything else in the (near-empty) init
        // environment is passed through untouched.
        match Command::new(spec.path)
            .args(&spec.args)
            .env("PATH", GUEST_PATH)
            .envs(spec.env.iter().copied())
            .spawn()
        {
            Ok(child) => StartOutcome::Started {
                pid: child.id(),
                child: Some(child),
            },
            Err(e) => StartOutcome::SpawnFailed(e),
        }
    }

    fn reap(&mut self) -> Option<(u32, i32)> {
        #[cfg(target_os = "linux")]
        {
            match crate::sys::wait_any_nonblocking() {
                Ok(Some((pid, status))) => Some((pid as u32, status)),
                Ok(None) => None,
                Err(e) => {
                    log::log(&format!("waitpid drain error: {}", e));
                    None
                }
            }
        }
        #[cfg(not(target_os = "linux"))]
        {
            None
        }
    }

    fn signal(&mut self, pid: u32, sig: i32) {
        #[cfg(target_os = "linux")]
        {
            if let Err(e) = crate::sys::kill(pid as i32, sig) {
                log::log(&format!("kill({}, {}) failed: {}", pid, sig, e));
            }
        }
        #[cfg(not(target_os = "linux"))]
        {
            let _ = (pid, sig);
        }
    }

    fn sleep(&mut self, dur: Duration) {
        std::thread::sleep(dur);
    }
}

struct ServiceState {
    spec: ServiceSpec,
    /// Kept only so the handle is dropped when the process goes away. It is
    /// never waited on or killed through — signalling goes through
    /// `Platform::signal` against `pid`, and reaping through the drain (see
    /// the module docs).
    child: Option<Child>,
    /// The authoritative "is this service running" record, and the key the
    /// `waitpid(-1)` drain matches against.
    pid: Option<u32>,
    /// When the current (or most recent) process was spawned. Compared
    /// against `STABLE_RUNTIME` on exit to decide whether the run counts as
    /// a success.
    started_at: Option<Instant>,
    backoff: Duration,
    /// Earliest time we're allowed to attempt (re)starting this service.
    next_attempt: Instant,
    /// What `spec.wanted()` said on the previous tick, so a gate going up can
    /// be told apart from a gate that was already up.
    was_wanted: bool,
}

impl ServiceState {
    fn new(spec: ServiceSpec) -> Self {
        let spec_wanted = spec.wanted();
        Self {
            spec,
            child: None,
            pid: None,
            started_at: None,
            backoff: INITIAL_BACKOFF,
            // Eligible to start immediately.
            next_attempt: Instant::now(),
            was_wanted: spec_wanted,
        }
    }
}

/// Record that `pid` exited with `status`. Returns true if `pid` belonged to
/// a tracked service (in which case its state is cleared and, unless we are
/// shutting down, a restart is scheduled), false if it was an unrelated
/// re-parented orphan.
///
/// This is where backoff is decided, and specifically where it is *not*
/// reset: only a run that lasted at least `STABLE_RUNTIME` clears the
/// history. See the `STABLE_RUNTIME` docs.
fn note_child_exit(
    services: &mut [ServiceState],
    pid: u32,
    status: i32,
    now: Instant,
    shutting_down: bool,
) -> bool {
    for state in services.iter_mut() {
        if state.pid != Some(pid) {
            continue;
        }
        let lifetime = state
            .started_at
            .map(|t| now.saturating_duration_since(t))
            .unwrap_or_default();

        state.pid = None;
        // Drop the handle without waiting: the pid has already been reaped
        // by the drain that called us, so `wait()` would only return ECHILD,
        // and holding on to a `Child` for a dead pid risks a later signal
        // landing on whatever process the kernel recycles that number into.
        state.child = None;
        state.started_at = None;

        if shutting_down {
            log::log(&format!(
                "service {} (pid {}) stopped: {}",
                state.spec.name,
                pid,
                describe_wait_status(status)
            ));
            return true;
        }

        if lifetime >= STABLE_RUNTIME {
            // It ran long enough to count as a working start, so the next
            // failure begins a fresh backoff sequence rather than inheriting
            // whatever the last crash loop escalated to.
            state.backoff = INITIAL_BACKOFF;
        }
        log::log(&format!(
            "service {} (pid {}) exited after {:?}: {} — restarting in {:?}",
            state.spec.name,
            pid,
            lifetime,
            describe_wait_status(status),
            state.backoff
        ));
        state.next_attempt = now + state.backoff;
        state.backoff = next_backoff(state.backoff);
        return true;
    }
    false
}

/// Owns the service table's runtime state and drives it forward one
/// `tick()` at a time.
pub struct Supervisor {
    services: Vec<ServiceState>,
    /// Latched by `stop_all`, never cleared. It stops the reap drain from
    /// scheduling restarts for processes we just killed on purpose, and
    /// makes any subsequent `tick` a no-op.
    ///
    /// Latching rather than scoping it to `stop_all` matters: in production
    /// the tick loop returns and powers off immediately afterwards, so the
    /// two behaviours are indistinguishable — but that is an accident of the
    /// caller, and a supervisor that quietly resurrects a stopped dockerd if
    /// anyone ticks it again is a trap for the next person to touch
    /// `main.rs`. Stopped means stopped.
    shutting_down: bool,
}

impl Supervisor {
    pub fn new(specs: Vec<ServiceSpec>) -> Self {
        Self {
            services: specs.into_iter().map(ServiceState::new).collect(),
            shutting_down: false,
        }
    }

    /// Attempt to start every service for the first time. Called once
    /// during boot, before entering the tick loop.
    pub fn start_all(&mut self) {
        self.start_all_on(&mut SystemPlatform);
    }

    /// One iteration of the supervisor's work: reap anything that exited,
    /// then attempt to (re)start any service that isn't running and whose
    /// backoff has elapsed. Non-blocking; safe to call frequently from the
    /// main tick loop.
    pub fn tick(&mut self) {
        self.tick_on(&mut SystemPlatform);
    }

    /// Stop every running service, newest first, escalating SIGTERM to
    /// SIGKILL. Blocks for up to `STOP_GRACE + KILL_GRACE` per service.
    pub fn stop_all(&mut self) {
        self.stop_all_on(&mut SystemPlatform);
    }

    /// The first start is unconditional: `next_attempt` only ever means
    /// "how long to wait after a failure", and nothing has failed yet. (It
    /// is also the only way the initial value of `next_attempt` could matter,
    /// which is what lets `ServiceState::new` stay free of a wall-clock read
    /// that a simulated clock would then disagree with.)
    fn start_all_on<P: Platform>(&mut self, p: &mut P) {
        let now = p.now();
        for state in &mut self.services {
            // A gated service that nobody has asked for is not started, not
            // logged, and not scheduled for a retry. "Off" has to be free, or
            // an optional subsystem is only optional in name.
            if !state.spec.wanted() {
                continue;
            }
            Self::start_and_log(p, state, now);
        }
    }

    fn tick_on<P: Platform>(&mut self, p: &mut P) {
        // Still reap — orphans keep arriving as containers wind down — but
        // never start anything again.
        self.drain(p);
        if self.shutting_down {
            return;
        }

        // Gate edges, before anything else looks at the table.
        //
        // Going down means somebody ran `morb k8s disable`: stop the process
        // here rather than on the control thread, so the toggle stays a single
        // atomic store — the caller never waits out a SIGTERM ladder, and the
        // ladder runs on the one thread that owns process lifetimes.
        //
        // Going up means `morb k8s enable`, which is a deliberate act by a
        // person and therefore a clean slate: any backoff inherited from a
        // previous enable is forgiven, and the service is eligible to start on
        // this very tick. Without the reset, `next_attempt` still holds
        // whatever the last crash loop escalated to (up to 30s), and a user who
        // fixes the problem and re-enables waits out a penalty for a failure
        // they already dealt with.
        let now_for_edges = p.now();
        for idx in 0..self.services.len() {
            let wanted = self.services[idx].spec.wanted();
            if wanted == self.services[idx].was_wanted {
                continue;
            }
            self.services[idx].was_wanted = wanted;
            if wanted {
                self.services[idx].backoff = INITIAL_BACKOFF;
                self.services[idx].next_attempt = now_for_edges;
                log::log(&format!(
                    "{} was enabled — starting it",
                    self.services[idx].spec.name
                ));
            } else if self.services[idx].pid.is_some() {
                log::log(&format!(
                    "{} is no longer enabled — stopping it",
                    self.services[idx].spec.name
                ));
                self.stop_one(p, idx);
            }
        }

        let now = p.now();
        for state in &mut self.services {
            if state.pid.is_some() {
                continue;
            }
            if !state.spec.wanted() {
                continue;
            }
            if now < state.next_attempt {
                continue;
            }
            Self::start_and_log(p, state, now);
        }
    }

    /// Run the SIGTERM -> grace -> SIGKILL ladder against one service.
    ///
    /// Shared by the disable path and the shutdown path so a service can only
    /// ever be stopped one way.
    fn stop_one<P: Platform>(&mut self, p: &mut P, idx: usize) {
        let Some(pid) = self.services[idx].pid else {
            self.services[idx].child = None;
            return;
        };
        let name = self.services[idx].spec.name;
        let (stop_grace, kill_grace) = self.services[idx].spec.stop_ladder();

        log::log(&format!("sending SIGTERM to {} (pid {})", name, pid));
        p.signal(pid, SIGTERM);
        if self.wait_for_exit(p, idx, stop_grace) {
            return;
        }

        log::log(&format!(
            "{} (pid {}) ignored SIGTERM for {:?} — sending SIGKILL",
            name, pid, stop_grace
        ));
        p.signal(pid, SIGKILL);
        if !self.wait_for_exit(p, idx, kill_grace) {
            log::log(&format!(
                "WARNING: {} (pid {}) still has not exited after SIGKILL — \
                 continuing without it",
                name, pid
            ));
            // Give up tracking it rather than leave a stale pid that later
            // logging (or a later signal) would attribute to whatever process
            // the kernel recycles that number into.
            self.services[idx].pid = None;
            self.services[idx].child = None;
        }
    }

    fn start_and_log<P: Platform>(p: &mut P, state: &mut ServiceState, now: Instant) {
        match p.start(&state.spec) {
            StartOutcome::Started { pid, child } => {
                state.pid = Some(pid);
                state.child = child;
                state.started_at = Some(now);
                log::log(&format!(
                    "started service {} (pid {})",
                    state.spec.name, pid
                ));
                // Backoff is deliberately NOT reset here. Spawning is not
                // succeeding — see `STABLE_RUNTIME`.
            }
            StartOutcome::BinaryMissing => {
                log::log(&format!(
                    "service {} not found at {} — skipping (guest image may not include it yet)",
                    state.spec.name, state.spec.path
                ));
                state.next_attempt = now + MISSING_BINARY_RECHECK_INTERVAL;
            }
            StartOutcome::SpawnFailed(e) => {
                log::log(&format!(
                    "failed to spawn {}: {} — retrying in {:?}",
                    state.spec.name, e, state.backoff
                ));
                state.next_attempt = now + state.backoff;
                state.backoff = next_backoff(state.backoff);
            }
        }
    }

    /// Reap every child that has exited, via a single `waitpid(-1, WNOHANG)`
    /// drain — the only reaping path in morbinit (see the module docs).
    /// Results that match a tracked service update that service's state;
    /// the rest are re-parented orphans, which PID 1 must reap and can then
    /// forget.
    fn drain<P: Platform>(&mut self, p: &mut P) {
        // Bounded by however many children actually exited since the last
        // call, not unbounded.
        while let Some((pid, status)) = p.reap() {
            let now = p.now();
            if !note_child_exit(&mut self.services, pid, status, now, self.shutting_down) {
                log::log(&format!(
                    "reaped orphan process pid={} ({})",
                    pid,
                    describe_wait_status(status)
                ));
            }
        }
    }

    /// The shutdown ladder, newest service first (dockerd before
    /// containerd — dockerd needs a live containerd to stop containers
    /// cleanly, so killing containerd first would strand them).
    ///
    /// Per service: SIGTERM, wait up to `STOP_GRACE`, then SIGKILL and wait
    /// up to `KILL_GRACE`. Waiting is done by polling the same reap drain
    /// the tick loop uses, so the pid bookkeeping stays correct and orphaned
    /// container processes get collected along the way.
    fn stop_all_on<P: Platform>(&mut self, p: &mut P) {
        self.shutting_down = true;

        // Phase one: the optional services, all at once.
        //
        // Concurrently, and before anything else, for two reasons. Ordering:
        // cri-dockerd talks to dockerd and kubelet talks to cri-dockerd, so
        // tearing them down after the engine would strand both mid-call.
        // Budget: `control::SHUTDOWN_REPLY_TIMEOUT` is a sum over the stop
        // sequence, and doing these two sequentially would spend twice the
        // wall time for no benefit — they are independent processes with
        // nothing to hand each other. Signalling both and then waiting once
        // costs one grace period for the whole phase.
        self.stop_gated_concurrently(p);

        // Phase two: the engine, newest first (dockerd before containerd —
        // dockerd needs a live containerd to stop containers cleanly, so
        // killing containerd first would strand them).
        for idx in (0..self.services.len()).rev() {
            if self.services[idx].spec.gate.is_some() {
                continue;
            }
            self.stop_one(p, idx);
        }
    }

    /// SIGTERM every running gated service, wait out one shared grace period,
    /// then SIGKILL whatever is left and wait out one shared kill grace.
    fn stop_gated_concurrently<P: Platform>(&mut self, p: &mut P) {
        let gated: Vec<usize> = (0..self.services.len())
            .filter(|&i| self.services[i].spec.gate.is_some() && self.services[i].pid.is_some())
            .collect();
        if gated.is_empty() {
            return;
        }

        for &idx in &gated {
            let (Some(pid), name) = (self.services[idx].pid, self.services[idx].spec.name) else {
                continue;
            };
            log::log(&format!("sending SIGTERM to {} (pid {})", name, pid));
            p.signal(pid, SIGTERM);
        }

        if !self.wait_for_all_to_exit(p, &gated, GATED_STOP_GRACE) {
            for &idx in &gated {
                let (Some(pid), name) = (self.services[idx].pid, self.services[idx].spec.name)
                else {
                    continue;
                };
                log::log(&format!(
                    "{} (pid {}) ignored SIGTERM for {:?} — sending SIGKILL",
                    name, pid, GATED_STOP_GRACE
                ));
                p.signal(pid, SIGKILL);
            }
            if !self.wait_for_all_to_exit(p, &gated, GATED_KILL_GRACE) {
                for &idx in &gated {
                    if let Some(pid) = self.services[idx].pid {
                        log::log(&format!(
                            "WARNING: {} (pid {}) survived SIGKILL — continuing shutdown \
                             without it",
                            self.services[idx].spec.name, pid
                        ));
                        self.services[idx].pid = None;
                        self.services[idx].child = None;
                    }
                }
            }
        }
    }

    /// Poll the reap drain until every service in `indices` has exited or
    /// `budget` elapses. Returns whether they all did.
    fn wait_for_all_to_exit<P: Platform>(
        &mut self,
        p: &mut P,
        indices: &[usize],
        budget: Duration,
    ) -> bool {
        let deadline = p.now() + budget;
        loop {
            self.drain(p);
            if indices.iter().all(|&i| self.services[i].pid.is_none()) {
                return true;
            }
            if p.now() >= deadline {
                return false;
            }
            p.sleep(STOP_POLL_INTERVAL);
        }
    }

    /// Poll the reap drain until `services[idx]` is no longer running or
    /// `budget` elapses. Returns whether it exited.
    fn wait_for_exit<P: Platform>(&mut self, p: &mut P, idx: usize, budget: Duration) -> bool {
        let deadline = p.now() + budget;
        loop {
            self.drain(p);
            if self.services[idx].pid.is_none() {
                return true;
            }
            if p.now() >= deadline {
                return false;
            }
            p.sleep(STOP_POLL_INTERVAL);
        }
    }
}

/// Signal numbers. Identical on Linux and macOS, and morbinit does not link
/// libc's headers, so they are spelled out here rather than imported from
/// the Linux-only `sys` module (which the macOS test build does not compile).
const SIGTERM: i32 = 15;
const SIGKILL: i32 = 9;

// ---------------------------------------------------------------------------
// One-shot offline image load.
// ---------------------------------------------------------------------------

/// Import the initramfs's baked-in OCI archive into the freshly started
/// engine, once, if the image is not already there.
///
/// The point is a guest that can run `docker run hello-world` with no
/// registry, no DNS and no network — the boot gate's smoke test, and the
/// only thing that makes the tarball in the image worth its bytes.
///
/// Entirely best effort: every failure is logged and ignored. A guest that
/// cannot preload `hello-world` is still a perfectly good guest.
///
/// Reaper note: this runs on its own thread, *after* the supervisor's
/// `waitpid(-1)` drain is live, so the drain will almost always collect the
/// docker CLI's pid before we could wait for it ourselves — exit statuses
/// here are simply not available. So success is judged from the child's
/// stdout, read to EOF, which is reliable regardless of who reaps: the pipe
/// closes when the process dies either way.
pub fn load_baked_in_image() {
    if !Path::new(BAKED_IMAGE_TAR).exists() {
        return;
    }
    if !Path::new(DOCKER_CLI_BIN).exists() {
        log::log(&format!(
            "{} exists but {} does not — skipping the offline image load",
            BAKED_IMAGE_TAR, DOCKER_CLI_BIN
        ));
        return;
    }

    if image_present(BAKED_IMAGE_NAME) {
        log::log(&format!(
            "{} is already in the local image store — skipping the offline load",
            BAKED_IMAGE_NAME
        ));
        return;
    }

    log::log(&format!("loading {} into dockerd", BAKED_IMAGE_TAR));
    match docker_stdout(&["load", "-i", BAKED_IMAGE_TAR]) {
        Ok(out) => {
            let summary = out.trim();
            if summary.is_empty() {
                log::log(&format!(
                    "docker load -i {} produced no output — see the dockerd log above \
                     for why",
                    BAKED_IMAGE_TAR
                ));
            } else {
                log::log(&format!("docker load: {}", summary.replace('\n', "; ")));
            }
        }
        Err(e) => log::log(&format!("docker load -i {} failed: {}", BAKED_IMAGE_TAR, e)),
    }
}

/// Whether dockerd already knows about `name`.
fn image_present(name: &str) -> bool {
    match docker_stdout(&["image", "inspect", "--format", "{{.Id}}", name]) {
        // `docker image inspect` prints the id on success and nothing at all
        // on failure, so a non-empty stdout is the answer — no exit status
        // needed.
        Ok(out) => !out.trim().is_empty(),
        Err(e) => {
            log::log(&format!("docker image inspect {} failed: {}", name, e));
            false
        }
    }
}

/// Run the Docker CLI against the guest's own socket and return its stdout.
///
/// stderr is inherited so CLI diagnostics land in the console log next to
/// everything else. The child is never `wait`ed on — see the reaper note on
/// `load_baked_in_image`.
fn docker_stdout(args: &[&str]) -> std::io::Result<String> {
    use std::io::Read;
    use std::process::Stdio;

    let mut child = Command::new(DOCKER_CLI_BIN)
        .arg("-H")
        .arg(format!("unix://{}", DOCKER_SOCK))
        .args(args)
        .env("PATH", GUEST_PATH)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()?;

    let mut out = String::new();
    if let Some(mut stdout) = child.stdout.take() {
        // Reading to EOF is the synchronization point: the pipe closes when
        // the child exits, whoever ends up reaping it.
        stdout.read_to_string(&mut out)?;
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::{HashMap, HashSet, VecDeque};

    fn spec(name: &'static str, path: &'static str) -> ServiceSpec {
        ServiceSpec {
            name,
            path,
            args: Vec::new(),
            env: Vec::new(),
            gate: None,
        }
    }

    /// A service behind an on/off switch, as `k8s.rs` builds them.
    fn gated_spec(name: &'static str, path: &'static str, gate: Arc<AtomicBool>) -> ServiceSpec {
        ServiceSpec {
            name,
            path,
            args: Vec::new(),
            env: Vec::new(),
            gate: Some(gate),
        }
    }

    /// A `Platform` with a clock that only moves when something sleeps, and
    /// processes that exist purely as pid numbers.
    ///
    /// `lifetimes` decides how long each successive spawn of a service
    /// survives; that is what lets a test say "crash instantly, six times in
    /// a row" and get an exact backoff sequence out with no wall-clock time
    /// spent at all.
    struct FakePlatform {
        clock: Instant,
        next_pid: u32,
        /// Per service name, the lifetime of each successive spawn. The last
        /// entry repeats once exhausted; an empty deque means "never exits".
        lifetimes: HashMap<&'static str, VecDeque<Option<Duration>>>,
        /// pid -> (name, instant at which it should be reapable).
        pending: HashMap<u32, (&'static str, Instant)>,
        /// pid -> service name, for every pid ever spawned.
        names: HashMap<u32, &'static str>,
        /// Services whose processes exit when they are sent SIGTERM. Anything
        /// not listed here ignores it and has to be SIGKILLed.
        cooperative: HashSet<&'static str>,
        signals: Vec<(u32, i32)>,
        starts: Vec<&'static str>,
        /// Exit status handed to every simulated exit.
        exit_status: i32,
    }

    impl FakePlatform {
        fn new() -> Self {
            Self {
                clock: Instant::now(),
                next_pid: 1000,
                lifetimes: HashMap::new(),
                pending: HashMap::new(),
                names: HashMap::new(),
                cooperative: HashSet::new(),
                signals: Vec::new(),
                starts: Vec::new(),
                exit_status: 1 << 8, // exit status 1
            }
        }

        /// Mark `name`'s processes as honouring SIGTERM.
        fn cooperative(mut self, name: &'static str) -> Self {
            self.cooperative.insert(name);
            self
        }

        /// Every spawn of `name` lives exactly `d` before exiting.
        fn always_lives(mut self, name: &'static str, d: Duration) -> Self {
            self.lifetimes.entry(name).or_default().push_back(Some(d));
            self
        }

        /// Spawns of `name` live for each listed duration in turn; `None`
        /// means "stays up forever".
        fn lives(mut self, name: &'static str, ds: &[Option<Duration>]) -> Self {
            let slot = self.lifetimes.entry(name).or_default();
            for d in ds {
                slot.push_back(*d);
            }
            self
        }

        fn next_lifetime(&mut self, name: &'static str) -> Option<Duration> {
            match self.lifetimes.get_mut(name) {
                Some(q) if q.len() > 1 => q.pop_front().flatten(),
                Some(q) => q.front().copied().flatten(),
                None => None,
            }
        }

        fn signals_to(&self, pid: u32) -> Vec<i32> {
            self.signals
                .iter()
                .filter(|(p, _)| *p == pid)
                .map(|(_, s)| *s)
                .collect()
        }
    }

    impl Platform for FakePlatform {
        fn now(&self) -> Instant {
            self.clock
        }

        fn start(&mut self, spec: &ServiceSpec) -> StartOutcome {
            let pid = self.next_pid;
            self.next_pid += 1;
            self.starts.push(spec.name);
            self.names.insert(pid, spec.name);
            if let Some(d) = self.next_lifetime(spec.name) {
                self.pending.insert(pid, (spec.name, self.clock + d));
            }
            StartOutcome::Started { pid, child: None }
        }

        fn reap(&mut self) -> Option<(u32, i32)> {
            let now = self.clock;
            let ready = self
                .pending
                .iter()
                .find(|(_, (_, at))| *at <= now)
                .map(|(pid, _)| *pid)?;
            self.pending.remove(&ready);
            Some((ready, self.exit_status))
        }

        fn signal(&mut self, pid: u32, sig: i32) {
            self.signals.push((pid, sig));
            let name = self.names.get(&pid).copied().unwrap_or("<unknown>");
            // SIGKILL is not negotiable; SIGTERM only works on a process
            // that chose to honour it. Either way the process becomes
            // reapable on the next drain.
            if sig == SIGKILL || (sig == SIGTERM && self.cooperative.contains(name)) {
                self.pending.insert(pid, (name, self.clock));
            }
        }

        fn sleep(&mut self, dur: Duration) {
            self.clock += dur;
        }
    }

    /// Advance the fake clock without any component having asked to sleep —
    /// used to model wall time passing between supervisor ticks.
    fn advance(p: &mut FakePlatform, d: Duration) {
        p.clock += d;
    }

    #[test]
    fn backoff_doubles_and_caps_at_30s() {
        let mut b = INITIAL_BACKOFF;
        let expected_secs = [1, 2, 4, 8, 16, 30, 30, 30];
        for &expected in &expected_secs {
            assert_eq!(b, Duration::from_secs(expected));
            b = next_backoff(b);
        }
    }

    #[test]
    fn backoff_never_exceeds_cap_even_from_a_large_start() {
        let b = next_backoff(Duration::from_secs(1000));
        assert_eq!(b, MAX_BACKOFF);
    }

    /// The regression this whole `Platform` seam exists for.
    ///
    /// The previous version of this test poked `note_child_exit` directly
    /// with a hand-set pid table, which meant it passed just as happily when
    /// the supervisor reset the backoff on every spawn — the reset lived in
    /// `start_and_log`, and the test never called it. So "exponential
    /// backoff" was asserted while the running system restarted a
    /// crash-looping dockerd once a second, forever.
    ///
    /// This drives the real `tick` path against a fake clock: a service that
    /// dies 100ms after every spawn must see its restart delay grow
    /// 1s, 2s, 4s, ... and stick at the 30s cap.
    #[test]
    fn a_rapid_crash_loop_escalates_the_backoff_through_the_real_tick_path() {
        let mut p = FakePlatform::new().always_lives("crasher", Duration::from_millis(100));
        let mut sup = Supervisor::new(vec![spec("crasher", "/nope/crasher")]);

        sup.start_all_on(&mut p);
        assert_eq!(p.starts.len(), 1, "the first start is immediate");

        for expected_delay_secs in [1u64, 2, 4, 8, 16, 30, 30, 30] {
            let expected_delay = Duration::from_secs(expected_delay_secs);

            // Let the child die, then tick: the drain notices and schedules
            // the restart.
            advance(&mut p, Duration::from_millis(100));
            let starts_before = p.starts.len();
            sup.tick_on(&mut p);
            assert_eq!(
                p.starts.len(),
                starts_before,
                "a service must not be restarted the instant it dies"
            );

            // Ticking just shy of the delay must still not restart it.
            advance(&mut p, expected_delay - Duration::from_millis(1));
            sup.tick_on(&mut p);
            assert_eq!(
                p.starts.len(),
                starts_before,
                "restarted early: expected to wait {:?}",
                expected_delay
            );

            // ...and one more millisecond makes it eligible.
            advance(&mut p, Duration::from_millis(1));
            sup.tick_on(&mut p);
            assert_eq!(
                p.starts.len(),
                starts_before + 1,
                "expected a restart after {:?}",
                expected_delay
            );
        }
    }

    #[test]
    fn a_service_that_stays_up_long_enough_earns_a_fresh_backoff_sequence() {
        // Crash three times (escalating to a 4s delay for the next failure),
        // then run for well over STABLE_RUNTIME, then crash again: that last
        // crash must be treated as a first failure, not a fourth.
        let mut p = FakePlatform::new().lives(
            "flaky",
            &[
                Some(Duration::from_millis(50)),
                Some(Duration::from_millis(50)),
                Some(Duration::from_millis(50)),
                Some(STABLE_RUNTIME + Duration::from_secs(5)),
                Some(Duration::from_millis(50)),
            ],
        );
        let mut sup = Supervisor::new(vec![spec("flaky", "/nope/flaky")]);
        sup.start_all_on(&mut p);

        // Three quick crashes: delays of 1s, 2s, 4s.
        for delay_secs in [1u64, 2, 4] {
            advance(&mut p, Duration::from_millis(50));
            sup.tick_on(&mut p);
            advance(&mut p, Duration::from_secs(delay_secs));
            sup.tick_on(&mut p);
        }
        assert_eq!(sup.services[0].backoff, Duration::from_secs(8));

        // The long, healthy run.
        advance(&mut p, STABLE_RUNTIME + Duration::from_secs(5));
        sup.tick_on(&mut p);
        assert_eq!(
            sup.services[0].next_attempt,
            p.now() + INITIAL_BACKOFF,
            "a long-lived run must restart after the initial 1s, not 8s"
        );
        assert_eq!(sup.services[0].backoff, Duration::from_secs(2));
    }

    #[test]
    fn a_run_just_under_the_stability_threshold_does_not_reset_the_backoff() {
        // The boundary case: 29.999s of uptime is still a crash loop, just a
        // slow one, and must keep escalating.
        let almost = STABLE_RUNTIME - Duration::from_millis(1);
        let mut p = FakePlatform::new().always_lives("slowcrash", almost);
        let mut sup = Supervisor::new(vec![spec("slowcrash", "/nope/slowcrash")]);
        sup.start_all_on(&mut p);

        for expected_backoff_secs in [2u64, 4, 8] {
            advance(&mut p, almost);
            sup.tick_on(&mut p);
            assert_eq!(
                sup.services[0].backoff,
                Duration::from_secs(expected_backoff_secs)
            );
            advance(&mut p, Duration::from_secs(expected_backoff_secs));
            sup.tick_on(&mut p);
        }
    }

    #[test]
    fn missing_binaries_are_skipped_without_panicking() {
        // Uses the real platform: these paths do not exist on the macOS test
        // host, which exercises the "skip with log" branch.
        let mut sup = Supervisor::new(vec![spec(
            "nonexistent",
            "/definitely/not/a/real/binary/morbstack-test",
        )]);
        sup.start_all();
        assert!(sup.services[0].pid.is_none());
        assert!(sup.services[0].child.is_none());
        // Next attempt should have been pushed into the future, not left
        // eligible for an immediate (wasteful) retry.
        assert!(sup.services[0].next_attempt > Instant::now());
    }

    #[test]
    fn tick_is_a_no_op_before_next_attempt_time() {
        let mut sup = Supervisor::new(vec![spec(
            "nonexistent2",
            "/definitely/not/a/real/binary/morbstack-test-2",
        )]);
        sup.start_all();
        let first_attempt = sup.services[0].next_attempt;
        sup.tick();
        // Ticking again immediately shouldn't move next_attempt forward
        // again since we haven't reached it yet.
        assert_eq!(sup.services[0].next_attempt, first_attempt);
    }

    /// FINDING 2 regression: the reap drain is the only reaper, so the pid
    /// table it matches against has to be updated correctly.
    #[test]
    fn reaped_pid_clears_that_service_and_schedules_a_restart() {
        let mut sup = Supervisor::new(vec![spec("a", "/nope/a"), spec("b", "/nope/b")]);
        sup.services[0].pid = Some(101);
        sup.services[1].pid = Some(202);
        let now = Instant::now();

        assert!(note_child_exit(&mut sup.services, 202, 0, now, false));

        // Only the matching service is affected.
        assert_eq!(sup.services[1].pid, None);
        assert!(sup.services[1].child.is_none());
        assert_eq!(sup.services[1].next_attempt, now + INITIAL_BACKOFF);
        assert_eq!(sup.services[1].backoff, Duration::from_secs(2));
        assert_eq!(sup.services[0].pid, Some(101));
        assert_eq!(sup.services[0].backoff, INITIAL_BACKOFF);
    }

    #[test]
    fn reaped_orphan_pid_matches_nothing_and_disturbs_nothing() {
        let mut sup = Supervisor::new(vec![spec("a", "/nope/a")]);
        sup.services[0].pid = Some(101);
        let before = sup.services[0].next_attempt;

        assert!(!note_child_exit(
            &mut sup.services,
            9999,
            0,
            Instant::now(),
            false
        ));

        assert_eq!(sup.services[0].pid, Some(101));
        assert_eq!(sup.services[0].next_attempt, before);
        assert_eq!(sup.services[0].backoff, INITIAL_BACKOFF);
    }

    #[test]
    fn tick_does_not_restart_a_service_that_is_still_running() {
        let mut p = FakePlatform::new().lives("a", &[None]);
        let mut sup = Supervisor::new(vec![spec("a", "/nope/a")]);
        sup.start_all_on(&mut p);
        assert_eq!(p.starts.len(), 1);

        advance(&mut p, Duration::from_secs(600));
        sup.tick_on(&mut p);
        sup.tick_on(&mut p);

        assert_eq!(p.starts.len(), 1, "a live service must not be respawned");
    }

    // ---- shutdown ladder --------------------------------------------------

    #[test]
    fn stop_all_sigterms_first_and_never_escalates_for_a_cooperative_service() {
        let mut p = FakePlatform::new().lives("a", &[None]).cooperative("a");
        let mut sup = Supervisor::new(vec![spec("a", "/nope/a")]);
        sup.start_all_on(&mut p);
        let pid = sup.services[0].pid.unwrap();

        sup.stop_all_on(&mut p);

        assert_eq!(
            p.signals_to(pid),
            vec![SIGTERM],
            "a service that honours SIGTERM must never be SIGKILLed"
        );
        assert!(sup.services[0].pid.is_none());
    }

    #[test]
    fn stop_all_escalates_to_sigkill_only_after_the_full_grace_period() {
        let mut p = FakePlatform::new().lives("stubborn", &[None]);
        let mut sup = Supervisor::new(vec![spec("stubborn", "/nope/stubborn")]);
        sup.start_all_on(&mut p);
        let pid = sup.services[0].pid.unwrap();
        let started_at = p.clock;

        sup.stop_all_on(&mut p);

        assert_eq!(p.signals_to(pid), vec![SIGTERM, SIGKILL]);
        // The grace period must actually have been honoured — an escalation
        // that fires immediately would defeat the point of SIGTERM.
        let elapsed = p.clock.saturating_duration_since(started_at);
        assert!(
            elapsed >= STOP_GRACE,
            "escalated after only {:?}, expected to wait at least {:?}",
            elapsed,
            STOP_GRACE
        );
        assert!(sup.services[0].pid.is_none());
    }

    #[test]
    fn stop_all_stops_services_in_reverse_start_order() {
        // dockerd needs containerd alive to shut containers down, so the
        // last service started must be the first one stopped.
        let mut p = FakePlatform::new()
            .lives("containerd", &[None])
            .lives("dockerd", &[None])
            .cooperative("containerd")
            .cooperative("dockerd");
        let mut sup = Supervisor::new(vec![
            spec("containerd", "/nope/containerd"),
            spec("dockerd", "/nope/dockerd"),
        ]);
        sup.start_all_on(&mut p);
        let containerd_pid = sup.services[0].pid.unwrap();
        let dockerd_pid = sup.services[1].pid.unwrap();

        sup.stop_all_on(&mut p);

        let order: Vec<u32> = p.signals.iter().map(|(pid, _)| *pid).collect();
        assert_eq!(order, vec![dockerd_pid, containerd_pid]);
    }

    #[test]
    fn stop_all_does_not_resurrect_anything_it_stopped() {
        // The drain runs during stop_all, so a stopped service must not be
        // scheduled for a restart on the way out.
        let mut p = FakePlatform::new().lives("a", &[None]).cooperative("a");
        let mut sup = Supervisor::new(vec![spec("a", "/nope/a")]);
        sup.start_all_on(&mut p);

        sup.stop_all_on(&mut p);
        let starts_after_stop = p.starts.len();

        // Even a tick long afterwards must not bring it back.
        advance(&mut p, Duration::from_secs(3600));
        sup.tick_on(&mut p);
        assert_eq!(
            p.starts.len(),
            starts_after_stop,
            "stop_all must not leave a restart scheduled"
        );
    }

    #[test]
    fn stop_all_on_an_empty_or_already_stopped_table_is_a_no_op() {
        let mut p = FakePlatform::new();
        let mut sup = Supervisor::new(Vec::new());
        sup.stop_all_on(&mut p);
        assert!(p.signals.is_empty());

        let mut sup = Supervisor::new(vec![spec("a", "/nope/a")]);
        sup.stop_all_on(&mut p);
        assert!(p.signals.is_empty(), "nothing running, nothing to signal");
    }

    #[test]
    fn shutdown_reaps_orphans_that_appear_while_waiting() {
        // Container processes get re-parented to PID 1 as dockerd tears them
        // down; the shutdown wait must keep draining them rather than
        // leaving zombies behind.
        // dockerd takes two seconds to wind down after SIGTERM, so it is
        // modelled with a lifetime rather than as cooperative.
        let mut p = FakePlatform::new().lives("dockerd", &[Some(Duration::from_secs(2))]);
        let mut sup = Supervisor::new(vec![spec("dockerd", "/nope/dockerd")]);
        sup.start_all_on(&mut p);
        let pid = sup.services[0].pid.unwrap();
        // An unrelated orphan becomes reapable partway through the grace
        // period — a container process being re-parented to PID 1.
        p.pending
            .insert(7777, ("<orphan>", p.clock + Duration::from_secs(1)));

        sup.stop_all_on(&mut p);

        assert!(p.pending.is_empty(), "every exited child must be reaped");
        assert_eq!(p.signals_to(pid), vec![SIGTERM]);
    }

    // ---- gated (optional) services ----------------------------------------

    #[test]
    fn a_gated_service_is_not_started_while_its_gate_is_down() {
        // "Off by default" has to mean off, not "started and immediately
        // killed" and not "logged as missing every thirty seconds".
        let gate = Arc::new(AtomicBool::new(false));
        let mut p = FakePlatform::new().lives("k3s", &[None]);
        let mut sup = Supervisor::new(vec![gated_spec("k3s", "/nope/k3s", gate)]);

        sup.start_all_on(&mut p);
        assert!(
            p.starts.is_empty(),
            "a gated-off service must not be spawned"
        );

        advance(&mut p, Duration::from_secs(600));
        sup.tick_on(&mut p);
        sup.tick_on(&mut p);
        assert!(p.starts.is_empty(), "ticking must not start it either");
    }

    #[test]
    fn raising_the_gate_starts_the_service_on_the_next_tick() {
        let gate = Arc::new(AtomicBool::new(false));
        let mut p = FakePlatform::new().lives("k3s", &[None]);
        let mut sup = Supervisor::new(vec![gated_spec("k3s", "/nope/k3s", Arc::clone(&gate))]);
        sup.start_all_on(&mut p);
        assert!(p.starts.is_empty());

        gate.store(true, Ordering::SeqCst);
        sup.tick_on(&mut p);
        assert_eq!(p.starts, vec!["k3s"]);
        assert!(sup.services[0].pid.is_some());
    }

    #[test]
    fn lowering_the_gate_stops_the_service_and_does_not_restart_it() {
        // The `morb k8s disable` path. It must stop the process — a gate that
        // only stopped *future* starts would leave a cluster running that the
        // user believes they turned off — and it must not then be treated as a
        // crash and restarted.
        let gate = Arc::new(AtomicBool::new(true));
        let mut p = FakePlatform::new().lives("k3s", &[None]).cooperative("k3s");
        let mut sup = Supervisor::new(vec![gated_spec("k3s", "/nope/k3s", Arc::clone(&gate))]);
        sup.start_all_on(&mut p);
        let pid = sup.services[0].pid.unwrap();

        gate.store(false, Ordering::SeqCst);
        sup.tick_on(&mut p);

        assert_eq!(p.signals_to(pid), vec![SIGTERM]);
        assert!(sup.services[0].pid.is_none());

        advance(&mut p, Duration::from_secs(3600));
        sup.tick_on(&mut p);
        assert_eq!(p.starts.len(), 1, "a disabled service must stay disabled");
    }

    #[test]
    fn a_gate_that_goes_up_again_restarts_the_service() {
        // enable -> disable -> enable, which is what a user poking at the
        // toggle in the app actually does.
        let gate = Arc::new(AtomicBool::new(true));
        let mut p = FakePlatform::new().lives("k3s", &[None]).cooperative("k3s");
        let mut sup = Supervisor::new(vec![gated_spec("k3s", "/nope/k3s", Arc::clone(&gate))]);
        sup.start_all_on(&mut p);

        gate.store(false, Ordering::SeqCst);
        sup.tick_on(&mut p);
        gate.store(true, Ordering::SeqCst);
        sup.tick_on(&mut p);

        assert_eq!(p.starts.len(), 2);
        assert!(sup.services[0].pid.is_some());
    }

    #[test]
    fn a_gated_service_still_gets_backoff_when_it_crash_loops() {
        // Being optional does not mean being unsupervised: an enabled k3s that
        // dies on startup must back off exactly like dockerd would, or it
        // burns the guest's CPU restarting forever.
        let gate = Arc::new(AtomicBool::new(true));
        let mut p = FakePlatform::new().always_lives("k3s", Duration::from_millis(100));
        let mut sup = Supervisor::new(vec![gated_spec("k3s", "/nope/k3s", gate)]);
        sup.start_all_on(&mut p);

        for expected_delay_secs in [1u64, 2, 4] {
            advance(&mut p, Duration::from_millis(100));
            let before = p.starts.len();
            sup.tick_on(&mut p);
            advance(
                &mut p,
                Duration::from_secs(expected_delay_secs) - Duration::from_millis(1),
            );
            sup.tick_on(&mut p);
            assert_eq!(
                p.starts.len(),
                before,
                "restarted before {}s",
                expected_delay_secs
            );
            advance(&mut p, Duration::from_millis(1));
            sup.tick_on(&mut p);
            assert_eq!(p.starts.len(), before + 1);
        }
    }

    #[test]
    fn shutdown_stops_gated_services_first_and_all_at_once() {
        // Ordering: cri-dockerd talks to dockerd, so both must be down before
        // the engine is. Concurrency: the shutdown reply budget is a sum, and
        // `control::SHUTDOWN_REPLY_TIMEOUT` only fits under the host's ack
        // timeout because this phase costs one grace period rather than one
        // per service.
        let gate = Arc::new(AtomicBool::new(true));
        let mut p = FakePlatform::new()
            .lives("containerd", &[None])
            .lives("dockerd", &[None])
            .lives("cri-dockerd", &[None])
            .lives("k3s", &[None])
            .cooperative("containerd")
            .cooperative("dockerd")
            .cooperative("cri-dockerd")
            .cooperative("k3s");
        let mut sup = Supervisor::new(vec![
            spec("containerd", "/nope/containerd"),
            spec("dockerd", "/nope/dockerd"),
            gated_spec("cri-dockerd", "/nope/cri-dockerd", Arc::clone(&gate)),
            gated_spec("k3s", "/nope/k3s", gate),
        ]);
        sup.start_all_on(&mut p);
        let pids: Vec<u32> = sup.services.iter().map(|s| s.pid.unwrap()).collect();
        let (containerd, dockerd, cri, k3s) = (pids[0], pids[1], pids[2], pids[3]);

        sup.stop_all_on(&mut p);

        let order: Vec<u32> = p.signals.iter().map(|(pid, _)| *pid).collect();
        // Both gated services are signalled before either engine service.
        let cri_at = order.iter().position(|&x| x == cri).unwrap();
        let k3s_at = order.iter().position(|&x| x == k3s).unwrap();
        let dockerd_at = order.iter().position(|&x| x == dockerd).unwrap();
        let containerd_at = order.iter().position(|&x| x == containerd).unwrap();
        assert!(cri_at < dockerd_at && k3s_at < dockerd_at);
        assert!(
            dockerd_at < containerd_at,
            "dockerd still stops before containerd"
        );
        assert!(sup.services.iter().all(|s| s.pid.is_none()));
    }

    #[test]
    fn a_stubborn_gated_service_costs_one_short_ladder_not_two() {
        // The budget assertion, in wall time. Two gated services that both
        // ignore SIGTERM must together cost GATED_STOP_GRACE + GATED_KILL_GRACE
        // — not twice that — because they are signalled together and waited on
        // once. `control::SHUTDOWN_REPLY_TIMEOUT` is derived on that basis.
        let gate = Arc::new(AtomicBool::new(true));
        let mut p = FakePlatform::new()
            .lives("cri-dockerd", &[None])
            .lives("k3s", &[None]);
        let mut sup = Supervisor::new(vec![
            gated_spec("cri-dockerd", "/nope/cri-dockerd", Arc::clone(&gate)),
            gated_spec("k3s", "/nope/k3s", gate),
        ]);
        sup.start_all_on(&mut p);
        let started_at = p.clock;

        sup.stop_all_on(&mut p);

        let elapsed = p.clock.saturating_duration_since(started_at);
        assert!(
            elapsed >= GATED_STOP_GRACE,
            "escalated after only {:?}",
            elapsed
        );
        assert!(
            elapsed < (GATED_STOP_GRACE + GATED_KILL_GRACE) * 2,
            "the gated phase took {:?}; it must be one shared ladder, not one per service",
            elapsed
        );
        for state in &sup.services {
            assert!(state.pid.is_none());
        }
    }

    #[test]
    fn the_engine_keeps_the_long_ladder_and_optional_services_get_the_short_one() {
        // dockerd's SIGTERM handler is flushing a layer store; k3s's is
        // closing a crash-safe SQLite database. Only one of those deserves ten
        // seconds, and the difference is what buys the budget headroom.
        assert_eq!(
            spec("dockerd", "/x").stop_ladder(),
            (STOP_GRACE, KILL_GRACE)
        );
        assert_eq!(
            gated_spec("k3s", "/x", Arc::new(AtomicBool::new(true))).stop_ladder(),
            (GATED_STOP_GRACE, GATED_KILL_GRACE)
        );
        assert!(GATED_STOP_GRACE < STOP_GRACE);
    }

    #[test]
    fn default_services_are_never_gated() {
        // The engine is the reason the guest exists. If a future change ever
        // put a gate on containerd or dockerd, `start_all` would silently skip
        // it and the guest would boot with no Docker at all.
        for on_disk in [true, false] {
            for service in default_services(on_disk) {
                assert!(service.gate.is_none(), "{} must not be gated", service.name);
            }
        }
    }

    #[test]
    fn wait_status_is_decoded_for_humans() {
        // exit(0) and exit(1)
        assert_eq!(describe_wait_status(0), "exit status 0");
        assert_eq!(describe_wait_status(1 << 8), "exit status 1");
        // SIGKILL (9)
        assert_eq!(describe_wait_status(9), "killed by signal 9");
        // SIGSEGV (11) with the core-dumped bit set
        assert_eq!(
            describe_wait_status(11 | 0x80),
            "killed by signal 11 (core dumped)"
        );
    }

    // ---- dockerd argv -----------------------------------------------------

    fn dockerd_args(on_disk: bool) -> Vec<String> {
        default_services(on_disk)
            .into_iter()
            .find(|s| s.name == "dockerd")
            .unwrap()
            .args
    }

    #[test]
    fn dockerd_never_gets_a_tcp_listener() {
        // FINDING 1 regression: a TCP listener would be an unauthenticated,
        // root-equivalent Docker API on the guest's NAT address.
        for on_disk in [true, false] {
            let args = dockerd_args(on_disk);
            assert!(
                !args.iter().any(|a| a.contains("tcp://")),
                "dockerd must not listen on TCP"
            );
            assert!(args
                .windows(2)
                .any(|w| w[0] == "--host" && w[1] == format!("unix://{}", DOCKER_SOCK)));
        }
    }

    #[test]
    fn storage_driver_follows_where_the_data_root_actually_lives() {
        // overlay2 cannot stack on tmpfs/rootfs, so a RAM-backed data root
        // must use vfs; a real disk must use overlay2, stated explicitly so
        // a leftover vfs layer store can't keep us on the slow driver.
        let on_disk = dockerd_args(true);
        assert!(on_disk
            .windows(2)
            .any(|w| w[0] == "--storage-driver" && w[1] == "overlay2"));

        let in_ram = dockerd_args(false);
        assert!(in_ram
            .windows(2)
            .any(|w| w[0] == "--storage-driver" && w[1] == "vfs"));
    }

    #[test]
    fn dockerd_always_gets_a_resolved_userland_proxy() {
        // Regression: dockerd resolves `docker-proxy` off PATH, PID 1 has no
        // PATH, and the resulting "invalid userland-proxy-path" is a hard
        // exit(1) — it crash-looped the guest for the whole boot. Whichever
        // branch we take, dockerd must never be left to guess.
        for on_disk in [true, false] {
            let args = dockerd_args(on_disk);
            let pinned_path = args.windows(2).any(|w| {
                w[0] == "--userland-proxy-path"
                    && (w[1] == MORBSTACK_PROXY_BIN || w[1] == DOCKER_PROXY_BIN)
            });
            let disabled = args.iter().any(|a| a == "--userland-proxy=false");
            assert!(
                pinned_path || disabled,
                "dockerd args must pin or disable the userland proxy, got {:?}",
                args
            );
            // Exactly one of the two, never both (dockerd would reject the
            // combination as contradictory). Which branch is taken depends on
            // the filesystem this test runs on, so it isn't asserted here.
            assert!(!(pinned_path && disabled));
        }
    }

    #[test]
    fn default_services_length_matches_the_declared_count() {
        // `control::SHUTDOWN_REPLY_TIMEOUT` multiplies the stop ladder by
        // SUPERVISED_SERVICE_COUNT at compile time. Adding a service without
        // bumping the constant would silently under-budget the shutdown reply
        // — and the fix is not just the constant, it is the whole nested
        // budget chain out to the CLI. Fail here so that is impossible to
        // miss.
        for on_disk in [true, false] {
            assert_eq!(default_services(on_disk).len(), SUPERVISED_SERVICE_COUNT);
        }
    }

    #[test]
    fn apply_dns_flags_adds_dns_and_host_gateway_ip_to_dockerd_only() {
        let services = apply_dns_flags(
            default_services(true),
            true,
            Some("192.168.64.3".parse().unwrap()),
            Some("192.168.64.1".parse().unwrap()),
        );
        let dockerd = services.iter().find(|s| s.name == "dockerd").unwrap();
        assert!(dockerd
            .args
            .windows(2)
            .any(|w| w == ["--dns", "172.17.0.1"]));
        assert!(dockerd
            .args
            .windows(2)
            .any(|w| w == ["--dns", "192.168.64.3"]));
        assert!(dockerd
            .args
            .windows(2)
            .any(|w| w == ["--host-gateway-ip", "192.168.64.1"]));
        // containerd never sees these — they are dockerd-specific flags.
        let containerd = services.iter().find(|s| s.name == "containerd").unwrap();
        assert!(containerd.args.is_empty());
    }

    #[test]
    fn apply_dns_flags_is_a_no_op_with_nothing_to_add() {
        let before = default_services(true);
        let after = apply_dns_flags(default_services(true), false, None, None);
        let before_args = &before.iter().find(|s| s.name == "dockerd").unwrap().args;
        let after_args = &after.iter().find(|s| s.name == "dockerd").unwrap().args;
        assert_eq!(before_args, after_args);
    }

    #[test]
    fn apply_dns_flags_keeps_ordinary_dns_when_listener_failed_to_start() {
        let gateway_only = apply_dns_flags(
            default_services(true),
            false,
            Some("192.168.64.3".parse().unwrap()),
            Some("10.0.0.1".parse().unwrap()),
        );
        let args = &gateway_only
            .iter()
            .find(|s| s.name == "dockerd")
            .unwrap()
            .args;
        assert!(!args.iter().any(|a| a == "--dns"));
        assert!(args.iter().any(|a| a == "--host-gateway-ip"));
    }

    #[test]
    fn apply_dns_flags_uses_the_bridge_gateway_when_the_listener_is_ready() {
        let dns_only = apply_dns_flags(default_services(true), true, None, None);
        let args = &dns_only.iter().find(|s| s.name == "dockerd").unwrap().args;
        assert!(args.windows(2).any(|w| w == ["--dns", "172.17.0.1"]));
        assert!(!args.iter().any(|a| a == "--host-gateway-ip"));
    }

    #[test]
    fn dockerd_pins_the_default_bridge_that_hosts_the_primary_dns_endpoint() {
        for on_disk in [true, false] {
            let args = dockerd_args(on_disk);
            assert!(args
                .windows(2)
                .any(|w| w == ["--bip", DEFAULT_DOCKER_BRIDGE_CIDR]));
        }
    }

    #[test]
    fn userland_proxy_state_is_read_off_the_arguments_dockerd_was_given() {
        // Reported to the host in the MRB0 `info` reply, so it has to describe
        // the running dockerd rather than a fresh filesystem probe that might
        // disagree with it.
        let spec = |args: &[&str]| ServiceSpec {
            name: "dockerd",
            path: "/usr/local/bin/dockerd",
            args: args.iter().map(|s| s.to_string()).collect(),
            env: Vec::new(),
            gate: None,
        };

        assert!(userland_proxy_enabled(&[spec(&[
            "--userland-proxy-path",
            DOCKER_PROXY_BIN
        ])]));
        assert!(!userland_proxy_enabled(&[spec(&[
            "--userland-proxy=false"
        ])]));
        // Enabled is the dockerd default, so a bare argument list means on.
        assert!(userland_proxy_enabled(&[spec(&[])]));
        // No dockerd at all: report the conservative answer rather than
        // claiming a loopback listener exists.
        assert!(!userland_proxy_enabled(&[]));
    }

    #[test]
    fn userland_proxy_state_agrees_with_the_real_service_table() {
        // Whichever branch `default_services` takes on this machine, the
        // reported flag and the argv must tell the same story.
        for on_disk in [true, false] {
            let services = default_services(on_disk);
            let args = &services.iter().find(|s| s.name == "dockerd").unwrap().args;
            let disabled = args.iter().any(|a| a == "--userland-proxy=false");
            assert_eq!(userland_proxy_enabled(&services), !disabled);
        }
    }

    #[test]
    fn iptables_switches_track_whether_the_binary_is_actually_present() {
        // With iptables in the image dockerd must be left to program the
        // bridge itself (that is what gives containers outbound NAT and
        // makes published ports work); without it, both switches must be
        // disabled or dockerd aborts at startup.
        let present = find_iptables().is_some();
        let args = dockerd_args(true);
        let disabled_v4 = args.iter().any(|a| a == "--iptables=false");
        let disabled_v6 = args.iter().any(|a| a == "--ip6tables=false");
        assert_eq!(disabled_v4, !present);
        assert_eq!(disabled_v6, !present);
        // Never one without the other: ip6tables is a separate switch that
        // defaults to on, so leaving it enabled means a failed lookup and a
        // console warning on every boot.
        assert_eq!(disabled_v4, disabled_v6);
    }

    #[test]
    fn iptables_is_looked_up_on_the_same_path_dockerd_searches() {
        for name in IPTABLES_NAMES {
            assert!(
                !name.contains('/'),
                "{} must be a bare name resolved off GUEST_PATH, not a fixed path",
                name
            );
        }
    }

    #[test]
    fn dockerd_runs_in_ramdisk_mode() {
        // Regression: without DOCKER_RAMDISK every `docker run` dies with
        // "pivot_root .: invalid argument", because morbinit never leaves the
        // initramfs. Unconditional — it does not depend on where
        // /var/lib/docker ended up, because the check is on the *old* root.
        for on_disk in [true, false] {
            let services = default_services(on_disk);
            let dockerd = services.iter().find(|s| s.name == "dockerd").unwrap();
            assert_eq!(
                dockerd
                    .env
                    .iter()
                    .find(|(k, _)| *k == DOCKER_RAMDISK_ENV)
                    .map(|(_, v)| *v),
                Some("1")
            );
        }
    }

    #[test]
    fn dockerd_accepts_old_api_clients() {
        // Regression: stock moby 29's default minimum API version (1.44)
        // 400s the `GET /v1.32/info` probe testcontainers-java <= 1.20.x
        // uses for daemon discovery, and the library then silently fails
        // over to another engine on the machine. DOCKER_MIN_API_VERSION at
        // upstream's 1.24 floor keeps those clients on Morbstack.
        for on_disk in [true, false] {
            let services = default_services(on_disk);
            let dockerd = services.iter().find(|s| s.name == "dockerd").unwrap();
            assert_eq!(
                dockerd
                    .env
                    .iter()
                    .find(|(k, _)| *k == DOCKER_MIN_API_VERSION_ENV)
                    .map(|(_, v)| *v),
                Some("1.24")
            );
        }
    }

    #[test]
    fn guest_path_covers_the_engine_install_dir() {
        // containerd execs `containerd-shim-runc-v2` by name and the shim
        // execs `runc` by name; both live in /usr/local/bin, so a PATH that
        // omits it means every `docker run` fails at container create.
        let dir = Path::new(DOCKER_PROXY_BIN).parent().unwrap();
        assert!(GUEST_PATH.split(':').any(|p| Path::new(p) == dir));
        // sbin too, which is where mkfs.btrfs / iptables usually land.
        assert!(GUEST_PATH.split(':').any(|p| p == "/usr/local/sbin"));
        assert!(GUEST_PATH.split(':').any(|p| p == "/sbin"));
    }
}
