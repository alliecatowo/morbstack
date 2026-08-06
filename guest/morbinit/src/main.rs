//! morbinit — the Morbstack guest's PID 1.
//!
//! morbinit is `/init` inside a gzipped-newc initramfs; the guest is booted
//! with `rdinit=/init` and no `root=`, so the rootfs lives in RAM and this
//! process is the very first thing the kernel starts. Boot sequence:
//!
//!   1. `mounts::early_mounts` — /proc, /sys, /dev, /run, /tmp, cgroup2.
//!   2. `disk::provision` — classify `/dev/vda`, format it if it is blank,
//!      mount it at `/var/lib/docker`, or fall back to a tmpfs.
//!   3. hostname.
//!   4. `net::bring_up_network` — lo + eth0 + DHCP via busybox — and
//!      `net::enable_container_forwarding` for container NAT.
//!   5. `supervisor` — containerd, then dockerd (unix socket only).
//!   6. Long-lived duties, each on its own thread so none can stall another:
//!        * the MRB0 control server on vsock 1024 (`control.rs`),
//!        * the Docker API relay on vsock 2375 (`proxy.rs`),
//!        * the stream dialer on vsock 2376 (`dial.rs`),
//!        * the datagram dialer on vsock 2378 (`datagram.rs`),
//!        * the local ssh-agent forward listener, guest-initiated out to vsock
//!          2383 per accepted connection (`ssh_agent_forward.rs`),
//!        * the dockerd readiness monitor (`proxy.rs`), which also triggers
//!          the one-shot offline image load.
//!
//! Meanwhile this thread runs the supervisor tick loop — which is also the
//! only child reaper, as PID 1 must be, and which owns the shutdown
//! sequence.
//!
//! On any other OS (in practice: macOS, where this crate is developed and
//! unit tested) morbinit refuses to do any of that and exits — there is no
//! sensible init sequence to run outside the guest VM. Every library
//! module still compiles and is unit tested there.
//!
//! Real deployment target: aarch64-unknown-linux-musl, as a small static
//! binary baked into the guest initramfs (hence the size-tuned
//! `[profile.release]` in Cargo.toml and `.cargo/config.toml`'s cross
//! linker).
//!
//! Most of this crate's logic only ever runs on Linux (or under `cargo
//! test`); on a plain `cargo build` on macOS large parts of it are
//! unreachable from `main`, which is expected and intentional rather than
//! a sign of actual dead code — see the contract note in Cargo.toml/the
//! module docs above. We allow the resulting `dead_code` lint only in that
//! configuration, on the theory that "prefer cfg-gating over allow" already
//! applies everywhere it reasonably can (see `sys.rs`, `mounts.rs`, which
//! are `#![cfg(target_os = "linux")]` in full).
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

mod binfmt;
mod control;
mod datagram;
mod dial;
mod disk;
mod dns;
mod jsonlite;
mod k8s;
mod live_share;
mod live_share_receiver;
mod log;
mod meminfo;
mod mounts;
mod net;
mod netaddr;
mod proxy;
mod proxy_wrapper;
mod sha256;
mod shares;
mod ssh_agent_forward;
mod supervisor;
mod sys;
mod wire;

#[cfg(target_os = "linux")]
use std::sync::atomic::AtomicBool;
#[cfg(target_os = "linux")]
use std::sync::Arc;
#[cfg(target_os = "linux")]
use std::time::{Duration, Instant};

/// morbinit's version string, per the shared contract ("everything is version
/// 0.1.0-m0"). Read from Cargo.toml at compile time so the package metadata and
/// the string reported by `--version` and the `info` control message cannot
/// drift apart.
const VERSION: &str = env!("CARGO_PKG_VERSION");

/// How often the supervisor loop reaps children and checks for restarts.
#[cfg(target_os = "linux")]
const TICK_INTERVAL: Duration = Duration::from_millis(500);

/// The tick loop sleeps in slices this long so a shutdown request is picked
/// up promptly instead of waiting out a whole `TICK_INTERVAL`.
#[cfg(target_os = "linux")]
const SHUTDOWN_CHECK_INTERVAL: Duration = Duration::from_millis(25);

/// How long the supervisor waits for the control thread to put the `ok`
/// frame on the wire before cutting the power anyway. Short: the frame is a
/// few dozen bytes onto an already-connected socket, so anything beyond this
/// means the host is gone.
#[cfg(target_os = "linux")]
const REPLY_FLUSH_TIMEOUT: Duration = Duration::from_secs(5);

fn main() {
    let args: Vec<String> = std::env::args().collect();

    // Multi-call dispatch: dockerd execs this same binary as
    // `morbstack-docker-proxy` (its `--userland-proxy-path`), once per
    // published port. That mode must win before any PID-1 or --version
    // handling — dockerd owns the argv, and `-version` there means the
    // *proxy's* version probe, not morbinit's.
    if let Some(argv0) = args.first() {
        if proxy_wrapper::is_wrapper_invocation(argv0) {
            proxy_wrapper::run(&args);
        }
    }

    if args.iter().any(|a| a == "--version") {
        println!("{}", VERSION);
        return;
    }

    #[cfg(target_os = "linux")]
    {
        run_linux(&args);
    }

    #[cfg(not(target_os = "linux"))]
    {
        eprintln!("morbinit is the Morbstack guest PID 1; it only runs inside the VM");
        std::process::exit(64);
    }
}

#[cfg(target_os = "linux")]
fn run_linux(args: &[String]) {
    // Every long-lived guest transport ultimately writes to a raw accepted
    // vsock `File`. A Docker client cancelling a `docker cp` tar download
    // must make that writer observe EPIPE, not deliver SIGPIPE and terminate
    // morbinit (PID 1) before its relay can release the connection.
    if let Err(e) = sys::ignore_sigpipe() {
        eprintln!("morbinit: could not ignore SIGPIPE: {}", e);
        std::process::exit(1);
    }

    if sys::getpid() == 1 {
        real_init();
        return;
    }

    if args.iter().any(|a| a == "--serve-control") {
        // Testing/dev hook: run just the control server, without mounting
        // filesystems, setting the hostname, or supervising services. Lets
        // you point a client at a non-PID-1 morbinit for protocol testing.
        let ctx = Arc::new(control::ControlContext {
            start: Instant::now(),
            version: VERSION,
            kernel: control::kernel_string(),
            docker_ready: Arc::new(AtomicBool::new(false)),
            docker_data_on_disk: false,
            // Nothing here starts dockerd either, so there is no userland
            // proxy to report.
            userland_proxy: false,
            // Nor does anything here mount the Rosetta share or touch
            // binfmt_misc — this hook must not change the machine's state.
            binfmt: binfmt::BinfmtStatus::disabled(),
            // Nor does it mount anything, so it has no shares to report.
            shares: String::new(),
            tmp_alias_mounted: false,
            // Reads whatever the disk says, so `--serve-control` can be
            // pointed at a guest image to inspect its persisted k8s state —
            // but nothing here supervises the services, so an `enable` through
            // this hook only ever flips the flag.
            k8s: Arc::new(k8s::K8sState::from_disk(false)),
            // Nothing here supervises anything, so a `shutdown` must not sit
            // waiting for a stop sequence that will never run.
            shutdown: Arc::new(control::ShutdownSignal::detached()),
        });
        if let Err(e) = serve_control_only(&ctx) {
            log::log(&format!("control server error: {}", e));
            std::process::exit(1);
        }
        return;
    }

    eprintln!(
        "morbinit: not running as PID 1 (pass --serve-control to test the control \
         server standalone, or --version to print the version)"
    );
    std::process::exit(64);
}

/// The real PID-1 init sequence.
#[cfg(target_os = "linux")]
fn real_init() {
    log::log(&format!("morbinit {} starting as PID 1", VERSION));

    mounts::early_mounts();

    // Host directories over VirtioFS, mounted at their real absolute paths so
    // that `docker run -v /Users/me/app:/app` resolves to the same bytes on
    // both sides. Straight after `early_mounts` because the share map comes
    // off /proc/cmdline, which needs /proc and nothing else — and because a
    // failure here is worth seeing at the top of the console log rather than
    // buried between dockerd's startup lines.
    let advertised_shares = mounts::advertised_shares();
    let share_results = mounts::mount_shares(&advertised_shares);
    // docs/parity.md #9: alias the guest's own /tmp onto the same content as
    // a live /private/tmp share, so a bind mount source under the bare,
    // unresolved /tmp a Mac user naturally types (macOS itself resolves it
    // via the same symlink) does not silently see an empty directory. Right
    // after the shares themselves mount, and well before dockerd starts, so
    // every container sees the aliased /tmp from its very first bind mount.
    let tmp_alias_mounted = mounts::alias_tmp_to_shared_private_tmp(&share_results);
    let share_report = shares::encode_report(&share_results);

    // After `early_mounts`, which is what puts /dev/vda on /dev in the first
    // place, and before the supervisor, whose reaper would race the mkfs
    // child's `waitpid`.
    let docker_data_on_disk = disk::provision();

    if let Err(e) = sys::set_hostname("morbstack") {
        log::log(&format!(
            "WARNING: sethostname(\"morbstack\") failed: {}",
            e
        ));
    }

    // Networking before the services: dockerd probes its own connectivity at
    // startup, and image pulls need DNS immediately.
    net::bring_up_network();
    // And forwarding before dockerd programs the bridge, so container NAT
    // works from the first container onwards.
    net::enable_container_forwarding();

    // host.docker.internal / gateway.docker.internal (docs/parity.md
    // #18/#19). The VM NAT gateway and DHCP resolver can legitimately be
    // absent (no network) — loud but not fatal, matching every other
    // best-effort step in this boot sequence. The primary DNS endpoint is
    // Docker's stable bridge gateway, not the guest's DHCP lease: a legacy
    // default-bridge container can always reach docker0, while its route to
    // eth0 is not a resolver contract. Keep the guest lease only as a
    // secondary resolver for user-defined bridges.
    //
    // Computed before the services are built below, since `apply_dns_flags`
    // needs a *ready* listener, and the DNS stub itself starts before dockerd
    // so it is already answering when the first container asks.
    let guest_dns_fallback_ip = net::guest_ipv4();
    let host_gateway_ip = net::default_gateway();
    let dns_upstream_ip = net::dns_upstream_ipv4();
    let split_dns_ready = match (host_gateway_ip, dns_upstream_ip) {
        (Some(gateway_ip), Some(upstream_ip))
            if upstream_ip != supervisor::DEFAULT_DOCKER_BRIDGE_GATEWAY =>
        {
            match dns::spawn_split_dns(gateway_ip, upstream_ip) {
                Ok(()) => true,
                Err(e) => {
                    log::log(&format!(
                        "WARNING: could not start the split DNS stub: {} — \
                         host.docker.internal/gateway.docker.internal will not resolve; \
                         leaving dockerd's ordinary DNS configuration intact",
                        e
                    ));
                    false
                }
            }
        }
        (Some(_), Some(upstream_ip)) => {
            log::log(&format!(
                "WARNING: configured DNS resolver {} is Docker's bridge gateway {} — \
                 refusing a split-DNS forwarding loop; leaving dockerd's ordinary DNS \
                 configuration intact",
                upstream_ip,
                supervisor::DEFAULT_DOCKER_BRIDGE_GATEWAY
            ));
            false
        }
        _ => {
            log::log(
                "WARNING: could not determine the VM NAT gateway and/or a usable IPv4 \
                 resolver — host.docker.internal/gateway.docker.internal will not resolve; \
                 --add-host=<name>:host-gateway remains available only when the VM NAT \
                 gateway was discovered",
            );
            false
        }
    };

    // amd64 emulation before the engine starts, so the binfmt_misc entry is
    // already in place by the time the first container can be created. It
    // only needs /proc and the /run tmpfs, both of which `early_mounts`
    // provided; nothing here can fail fatally.
    let binfmt_status = binfmt::setup();

    supervisor::prepare_runtime_dirs();
    let services = supervisor::apply_dns_flags(
        supervisor::default_services(docker_data_on_disk),
        split_dns_ready,
        guest_dns_fallback_ip,
        host_gateway_ip,
    );
    // Captured before the table is handed to the supervisor: the host needs
    // it in `info`, and `dial.rs`'s ECONNREFUSED diagnostic is only accurate
    // if it describes the dockerd we actually started.
    let userland_proxy = supervisor::userland_proxy_enabled(&services);
    if !userland_proxy {
        log::log(
            "WARNING: dockerd is running without the userland proxy — published \
             ports are DNAT-only, so there is no 127.0.0.1 listener for the stream \
             dialer to reach and host port forwarding will not work",
        );
    }
    // Kubernetes. Inert unless a previous `morb k8s enable` left its flag on
    // the persistent disk, in which case the gate comes up already raised and
    // the cluster restarts with the guest — which is the whole point of
    // persisting it.
    //
    // The two services join the ordinary supervisor table rather than getting
    // a supervisor of their own: they need the same SIGTERM ladder, the same
    // restart backoff, and above all the same single `waitpid(-1)` reaper, and
    // a second reaper in PID 1 is a race no amount of care survives.
    let k8s_state = Arc::new(k8s::K8sState::from_disk(docker_data_on_disk));
    if k8s_state.is_enabled() {
        log::log("kubernetes is enabled (flag found on the data disk) — preparing the guest");
        k8s::prepare_host();
    }
    let mut services = services;
    services.extend(k8s::service_specs(Arc::clone(&k8s_state.gate)));

    let mut sup = supervisor::Supervisor::new(services);
    sup.start_all();

    let docker_ready = Arc::new(AtomicBool::new(false));
    let shutdown = Arc::new(control::ShutdownSignal::new());

    let ctx = Arc::new(control::ControlContext {
        start: Instant::now(),
        version: VERSION,
        kernel: control::kernel_string(),
        docker_ready: Arc::clone(&docker_ready),
        docker_data_on_disk,
        userland_proxy,
        binfmt: binfmt_status,
        shares: share_report,
        tmp_alias_mounted,
        k8s: Arc::clone(&k8s_state),
        shutdown: Arc::clone(&shutdown),
    });

    // Control channel (vsock 1024). A bind failure is loud but not fatal:
    // we're PID 1, there is nothing above us to hand off to, and an init
    // that exits panics the kernel — so we degrade to "supervise services
    // with no control channel" rather than dying.
    match sys::VsockListener::bind(control::VSOCK_CONTROL_PORT) {
        Ok(listener) => {
            if let Err(e) = control::spawn_server(listener, Arc::clone(&ctx)) {
                log::log(&format!(
                    "FATAL: could not start control server thread: {}",
                    e
                ));
            } else {
                log::log(&format!(
                    "control server listening on vsock port {}",
                    control::VSOCK_CONTROL_PORT
                ));
            }
        }
        Err(e) => log::log(&format!(
            "FATAL: could not bind vsock control port {}: {} — running services \
             without a control channel",
            control::VSOCK_CONTROL_PORT,
            e
        )),
    }

    // Docker Engine API relay (vsock 2375 -> /var/run/docker.sock). Same
    // reasoning on failure: log loudly, keep running.
    if let Err(e) = proxy::spawn_docker_proxy() {
        log::log(&format!(
            "FATAL: could not bind vsock docker port {}: {} — the host will not be able \
             to reach the Docker API",
            proxy::VSOCK_DOCKER_PORT,
            e
        ));
    }

    // Published container ports (vsock 2376 -> 127.0.0.1:<port>). Same
    // failure policy: loud, not fatal.
    if let Err(e) = dial::spawn_stream_dialer() {
        log::log(&format!(
            "FATAL: could not bind vsock stream-dial port {}: {} — published \
             container ports will not be reachable from the host",
            dial::VSOCK_STREAM_DIAL_PORT,
            e
        ));
    }

    // Published UDP container ports (vsock 2378 -> connected guest UDP socket).
    // Independent from stream-dial because a byte splice cannot preserve UDP packet
    // boundaries or route replies to the correct Mac sender.
    if let Err(e) = datagram::spawn_datagram_dialer() {
        log::log(&format!(
            "FATAL: could not bind vsock datagram-dial port {}: published UDP \
             container ports will not be reachable from the host ({})",
            datagram::VSOCK_DATAGRAM_DIAL_PORT,
            e
        ));
    }

    // Host edits under explicitly opted-in live-share roots arrive over this
    // separate, authenticated vsock channel.  The receiver has authority only
    // over shares that mounted during this boot and turns invalidations into
    // guest-kernel metadata notifications; it never accepts an arbitrary path.
    if let Err(e) =
        live_share_receiver::spawn_live_share_receiver(&advertised_shares, &share_results)
    {
        log::log(&format!(
            "ERROR: could not bind live-share receiver port {}: host file notifications will be unavailable ({})",
            live_share_receiver::VSOCK_LIVE_SHARE_PORT,
            e
        ));
    }

    // `docker run -P` needs no guest-side broker: stock dockerd execs the
    // morbstack-docker-proxy wrapper (see proxy_wrapper.rs) per published
    // port, and the wrapper leases the Mac endpoint host-side over its own
    // guest-initiated vsock connection.

    // SSH agent forward (UX-19): the local /run/host-services/ssh-auth.sock
    // listener always exists, matching Docker Desktop's static contract, but
    // every connection is a request the host answers fresh — off by default.
    // Same failure policy as the others: loud, not fatal.
    if let Err(e) = ssh_agent_forward::spawn_ssh_agent_forwarder() {
        log::log(&format!(
            "ERROR: could not bind the ssh-agent forward listener at {}: {} — \
             SSH_AUTH_SOCK forwarding will not be available in containers",
            ssh_agent_forward::SSH_AUTH_SOCK_PATH,
            e
        ));
    }

    // Kubernetes payload install (vsock 2377 -> the persistent disk). Bound
    // unconditionally even though Kubernetes is off: this is the channel the
    // host uses to *make* it installable, so refusing to listen until it is
    // installed would be a deadlock. Same failure policy as the others.
    if let Err(e) = k8s::spawn_install_server(Arc::clone(&k8s_state)) {
        log::log(&format!(
            "FATAL: could not bind vsock k8s install port {}: {} — `morb k8s enable` \
             will not be able to deliver the cluster payload",
            k8s::VSOCK_K8S_INSTALL_PORT,
            e
        ));
    }
    // Keeps the cached cluster snapshot fresh so the control channel can
    // answer `k8s status` without ever running kubectl on a caller's thread.
    k8s::spawn_monitor(Arc::clone(&k8s_state));

    proxy::spawn_ready_monitor(Arc::clone(&docker_ready));
    spawn_offline_image_loader(Arc::clone(&docker_ready));

    log::log("entering supervisor tick loop");
    loop {
        sup.tick();

        if sleep_until_tick_or_shutdown(&shutdown) {
            run_shutdown_sequence(&mut sup, &shutdown, docker_data_on_disk);
            return;
        }
    }
}

/// Sleep out one tick interval in short slices, returning early (as `true`)
/// the moment a shutdown is requested. Without the slicing, a shutdown would
/// sit unnoticed for up to a full `TICK_INTERVAL`.
#[cfg(target_os = "linux")]
fn sleep_until_tick_or_shutdown(shutdown: &control::ShutdownSignal) -> bool {
    let deadline = Instant::now() + TICK_INTERVAL;
    loop {
        if shutdown.is_requested() {
            return true;
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return false;
        }
        std::thread::sleep(std::cmp::min(remaining, SHUTDOWN_CHECK_INTERVAL));
    }
}

/// Bring the guest down in the order the shared contract requires: stop the
/// services (SIGTERM, then SIGKILL), get `/var/lib/docker` onto the disk,
/// *then* let the `ok` frame go out, and only power off once it has.
///
/// Doing the flush before the reply is the whole point — the host treats
/// `ok` as permission to tear the VM down, so anything still buffered when
/// it is sent is data we have promised to have written and have not.
#[cfg(target_os = "linux")]
fn run_shutdown_sequence(
    sup: &mut supervisor::Supervisor,
    shutdown: &control::ShutdownSignal,
    docker_data_on_disk: bool,
) {
    log::log("shutdown requested — stopping services");
    sup.stop_all();

    log::log("flushing docker's data root");
    disk::flush_docker_data(docker_data_on_disk);

    // Release the control thread's `ok`.
    shutdown.mark_stopped();
    if !shutdown.wait_replied(REPLY_FLUSH_TIMEOUT) {
        log::log(&format!(
            "no shutdown reply was sent within {:?} — powering off anyway",
            REPLY_FLUSH_TIMEOUT
        ));
    }

    log::log("powering off");
    if let Err(e) = sys::power_off() {
        // PID 1 must not return from here. Exiting init makes the kernel
        // panic with "Attempted to kill init!", which buries the real error
        // under a stack trace and looks like a guest crash rather than the
        // orderly-but-incomplete shutdown it actually is. Park instead and
        // let the host's stop path take the VM down: everything worth
        // persisting was already flushed above.
        log::log(&format!(
            "power_off failed: {} — parking; the host will stop the VM",
            e
        ));
        loop {
            std::thread::sleep(std::time::Duration::from_secs(3600));
        }
    }
}

/// Wait for dockerd to come up, then do the one-shot offline image load.
///
/// On its own thread because it has to wait for a readiness flag that the
/// tick loop is responsible for keeping the engine alive to produce.
#[cfg(target_os = "linux")]
fn spawn_offline_image_loader(docker_ready: Arc<AtomicBool>) {
    let spawned = std::thread::Builder::new()
        .name("image-load".to_string())
        .spawn(move || {
            while !docker_ready.load(std::sync::atomic::Ordering::SeqCst) {
                std::thread::sleep(Duration::from_millis(100));
            }
            supervisor::load_baked_in_image();
        });
    if let Err(e) = spawned {
        log::log(&format!("could not spawn the offline image loader: {}", e));
    }
}

/// `--serve-control` test path: serve the control protocol without any of
/// PID-1's other duties. Connections are handled one at a time.
#[cfg(target_os = "linux")]
fn serve_control_only(ctx: &control::ControlContext) -> std::io::Result<()> {
    let listener = sys::VsockListener::bind(control::VSOCK_CONTROL_PORT)?;
    log::log(&format!(
        "morbinit --serve-control: listening on vsock port {}",
        control::VSOCK_CONTROL_PORT
    ));
    loop {
        let mut conn = listener.accept()?;
        if control::handle_connection(&mut conn, ctx) {
            log::log("shutdown requested (--serve-control mode; not powering off)");
            return Ok(());
        }
    }
}
