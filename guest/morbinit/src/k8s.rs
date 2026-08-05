//! The Kubernetes subsystem: k3s wired to the SAME dockerd everything else
//! in the guest already uses, through cri-dockerd.
//!
//! ## Why this shape
//!
//! The obvious way to put Kubernetes in a VM is to let k3s run its own
//! embedded containerd. That is deliberately not what happens here. k3s is
//! started with `--container-runtime-endpoint` pointed at cri-dockerd, which
//! translates kubelet's CRI calls into Docker Engine API calls against the
//! very same `/var/run/docker.sock` that `docker build` writes to. The payoff
//! is the whole reason the feature exists: an image you just built is already
//! in the cluster's image store. No registry, no push, no `kind load`.
//!
//! ## Off by default, and it costs nothing when it is off
//!
//! Nothing in this module runs unless somebody asked for it. Concretely:
//!
//!   * The 122 MB of k3s + cri-dockerd binaries are **not** in the initramfs.
//!     The initramfs is unpacked into RAM on every boot and is never freed, so
//!     baking them in would tax every boot — including the overwhelmingly
//!     common one where nobody wants Kubernetes — for a feature that is off.
//!     Instead the host streams them in over vsock 2377 on the first
//!     `morb k8s enable`, and morbinit writes them to the persistent ext4
//!     disk, where they survive reboots.
//!   * The two services live in the normal supervisor table but behind a
//!     *gate* (see `supervisor::ServiceSpec::gate`): while the gate is down
//!     they are never spawned, and lowering it stops them.
//!   * Enabled-ness is a flag file on the persistent disk, so a reboot comes
//!     back up in whatever state the user last chose.
//!
//! ## Where the state lives, and why it looks odd
//!
//! Everything is under `/var/lib/docker/morbstack-k8s`. That is not a typo:
//! `/dev/vda` is mounted at `/var/lib/docker` and nowhere else (see
//! `disk.rs`), so a subdirectory of it is the only path in the guest that is
//! both persistent and already mounted. A tidier `/var/lib/morb` would need
//! either a second disk or a bind mount, and a bind mount out of
//! `/var/lib/docker` makes the shutdown `umount` return EBUSY — which would
//! quietly downgrade the layer-store flush that the whole shutdown handshake
//! exists to guarantee. Ugly path, correct behaviour. If the data root ever
//! moves to its own mount point, this moves with it.
//!
//! When `/var/lib/docker` is RAM-backed (no disk, or a disk that would not
//! mount), the same paths still work but nothing survives a restart, and
//! `install` says so.

use crate::log;
use crate::sha256;
use crate::supervisor::ServiceSpec;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
#[cfg(target_os = "linux")]
use std::time::Instant;

/// vsock port the payload-install server listens on, extending the shared
/// contract's registry (1024 = MRB0 control, 2375 = Docker API, 2376 = stream
/// dial, 2377 = k8s payload install).
pub const VSOCK_K8S_INSTALL_PORT: u32 = 2377;

/// Root of everything Kubernetes owns in the guest. See the module docs for
/// why it is inside docker's data root.
pub const STATE_ROOT: &str = "/var/lib/docker/morbstack-k8s";

/// The CRI socket cri-dockerd serves and kubelet dials. On `/run`, which is a
/// tmpfs, because a socket must not outlive the process that made it.
pub const CRI_SOCKET: &str = "/run/cri-dockerd.sock";

/// The two binaries the host may install, by name. An allow-list rather than
/// a path: the install protocol takes a name from the host, and a host that
/// could name `../../../init` could replace PID 1 on the next boot.
pub const PAYLOAD_NAMES: &[&str] = &["k3s", "cri-dockerd"];

/// The node name the cluster reports. Fixed rather than the hostname so the
/// name is stable even if the hostname ever changes.
const NODE_NAME: &str = "morbstack";

/// Port the k3s API server listens on inside the guest. The host reaches it
/// through the existing stream dialer (vsock 2376), which is why this is a
/// plain loopback-reachable TCP port and not something exotic.
pub const APISERVER_PORT: u16 = 6443;

/// How long the payload-install server waits for the host's preamble line.
const PREAMBLE_TIMEOUT: Duration = Duration::from_secs(10);
/// Longest preamble line accepted. `PUT cri-dockerd 48693410 <64 hex>\n` is
/// about 90 bytes; the rest is slack, and the cap is what stops a peer that
/// never sends a newline from making us read forever.
const MAX_PREAMBLE_LEN: usize = 256;
/// Largest payload the guest will accept in one `PUT`. k3s is ~74 MB today;
/// 512 MB leaves room for growth while still refusing an absurd length before
/// a single byte is written to the disk.
const MAX_PAYLOAD_BYTES: u64 = 512 * 1024 * 1024;
/// Read buffer for the payload stream.
const TRANSFER_CHUNK: usize = 256 * 1024;

/// How often the monitor thread refreshes the cached cluster snapshot while
/// Kubernetes is enabled.
const MONITOR_INTERVAL: Duration = Duration::from_millis(1500);
/// How long a `kubectl` probe may take before the monitor gives up on it.
/// Generous: an API server that is still starting can sit on a connection.
const PROBE_TIMEOUT: Duration = Duration::from_secs(8);

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

pub fn state_root() -> PathBuf {
    PathBuf::from(STATE_ROOT)
}

/// Where the two installed binaries live.
pub fn bin_dir() -> PathBuf {
    state_root().join("bin")
}

pub fn binary_path(name: &str) -> PathBuf {
    bin_dir().join(name)
}

/// k3s's `--data-dir`. This is also where k3s self-extracts its bundled
/// helper binaries (~250 MB of iptables/conntrack/socat/containerd), which is
/// precisely why it must be on the disk: extracting that into the initramfs
/// rootfs would be a quarter of a gigabyte of unreclaimable RAM.
pub fn data_dir() -> PathBuf {
    state_root().join("rancher")
}

/// kubelet's `--root-dir`.
///
/// This has to be on the persistent disk, and not for the usual "it should
/// survive a reboot" reason. kubelet's container manager asks cAdvisor for
/// filesystem statistics about its root directory before it will start at all,
/// and cAdvisor answers by looking the directory's device up in
/// `/proc/self/mountinfo`. kubelet's default `/var/lib/kubelet` is on the
/// initramfs, whose device is the literal string `rootfs` and which appears in
/// no filesystem table, so the lookup fails and kubelet dies with
///
/// ```text
/// Failed to start ContainerManager: failed to get rootfs info:
///   cannot find filesystem info for device "rootfs"
/// ```
///
/// ...roughly three seconds into every start, forever, with the supervisor
/// dutifully backing off and trying again. Pointing `--root-dir` at the ext4
/// disk gives cAdvisor a real device to find. Same family of problem as
/// `DOCKER_RAMDISK`: the guest's `/` is not a filesystem in the sense that
/// container runtimes assume.
pub fn kubelet_root_dir() -> PathBuf {
    state_root().join("kubelet")
}

/// The admin kubeconfig k3s writes, and the host fetches.
pub fn kubeconfig_path() -> PathBuf {
    state_root().join("kubeconfig")
}

/// The enabled flag. Presence is the whole signal; the contents are a comment
/// for whoever finds the file.
pub fn enabled_flag_path() -> PathBuf {
    state_root().join("enabled")
}

/// Whether both payload binaries are present and executable.
pub fn is_installed() -> bool {
    PAYLOAD_NAMES
        .iter()
        .all(|name| is_executable(&binary_path(name)))
}

fn is_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(path)
            .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

/// `sync(2)`, but callable from the portable parts of this module.
///
/// Every write here is a decision the user made — a toggle, an installed
/// binary — and the next thing that reads it may well be the *next boot*.
/// `sys` is Linux-only, so the macOS unit-test build simply does nothing.
fn sync_now() {
    #[cfg(target_os = "linux")]
    crate::sys::sync();
}

// ---------------------------------------------------------------------------
// Enabled state
// ---------------------------------------------------------------------------

/// Read the persisted enable flag. A missing file means off, which is also
/// what an unreadable one means: Kubernetes is opt-in, so every ambiguous
/// answer resolves to "no".
pub fn read_enabled_flag() -> bool {
    read_enabled_flag_in(&state_root())
}

/// Persist the enable flag. Returns an error the caller should report to the
/// host rather than swallow — a toggle that silently fails to persist is worse
/// than one that refuses, because the user finds out on the next reboot.
pub fn write_enabled_flag(enabled: bool) -> io::Result<()> {
    write_enabled_flag_in(&state_root(), enabled)
}

/// `read_enabled_flag` against an arbitrary root.
///
/// The root is a parameter — rather than the module constant, or a test-only
/// environment variable — purely so persistence can be tested for what it is:
/// a fact that has to survive a process exit. The tests write a flag under a
/// scratch directory, drop everything, and read it back through the same code
/// path a reboot would take.
pub fn read_enabled_flag_in(root: &Path) -> bool {
    root.join("enabled").exists()
}

/// `write_enabled_flag` against an arbitrary root. See `read_enabled_flag_in`.
pub fn write_enabled_flag_in(root: &Path, enabled: bool) -> io::Result<()> {
    let path = root.join("enabled");
    if enabled {
        std::fs::create_dir_all(root)?;
        std::fs::write(
            &path,
            b"Morbstack: Kubernetes is enabled. Delete this file (or run \
              `morb k8s disable`) to turn it off.\n",
        )?;
    } else {
        match std::fs::remove_file(&path) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => return Err(e),
        }
    }
    // The next reader of this file may well be the next boot, and an enable
    // that only reached the page cache is an enable the user will find
    // mysteriously undone. Cheap, and exactly once per toggle.
    sync_now();
    Ok(())
}

// ---------------------------------------------------------------------------
// The shared runtime state
// ---------------------------------------------------------------------------

/// What the control channel reports and the supervisor gate reads.
pub struct K8sState {
    /// The supervisor gate. Raised means "cri-dockerd and k3s should be
    /// running"; the supervisor starts and stops them to match.
    pub gate: Arc<AtomicBool>,
    /// Whether `/var/lib/docker` is on the real disk, i.e. whether an install
    /// and an enable flag will still be there after a restart.
    pub persistent: bool,
    /// The last snapshot the monitor thread took.
    snapshot: Mutex<Snapshot>,
    /// Serialises installs so two concurrent `PUT`s of the same name cannot
    /// interleave their renames.
    install_lock: Mutex<()>,
}

/// A point-in-time view of the cluster, cheap for the control channel to read.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Snapshot {
    pub phase: Phase,
    pub nodes: u32,
    pub nodes_ready: u32,
    pub pods: u32,
    pub pods_ready: u32,
    /// Populated when something is wrong and a human would want to know what.
    pub message: String,
}

impl Snapshot {
    fn inert(phase: Phase) -> Self {
        Self {
            phase,
            nodes: 0,
            nodes_ready: 0,
            pods: 0,
            pods_ready: 0,
            message: String::new(),
        }
    }
}

/// The lifecycle states the host renders. Deliberately few: a user deciding
/// whether to run `kubectl` needs "can I?", not a state machine.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    /// The payload has never been installed into this guest.
    NotInstalled,
    /// Installed, but the toggle is off.
    Stopped,
    /// Toggle on; the control plane is not answering yet, or no node is Ready.
    Starting,
    /// At least one node is Ready. `kubectl` will work.
    Ready,
}

impl Phase {
    pub fn as_str(self) -> &'static str {
        match self {
            Phase::NotInstalled => "not-installed",
            Phase::Stopped => "stopped",
            Phase::Starting => "starting",
            Phase::Ready => "ready",
        }
    }
}

impl K8sState {
    /// Build the shared state, seeding the gate from the persisted flag so a
    /// reboot resumes whatever the user last chose.
    pub fn from_disk(persistent: bool) -> Self {
        let installed = is_installed();
        let enabled = installed && read_enabled_flag();
        Self {
            gate: Arc::new(AtomicBool::new(enabled)),
            persistent,
            snapshot: Mutex::new(Snapshot::inert(if !installed {
                Phase::NotInstalled
            } else if enabled {
                Phase::Starting
            } else {
                Phase::Stopped
            })),
            install_lock: Mutex::new(()),
        }
    }

    pub fn is_enabled(&self) -> bool {
        self.gate.load(Ordering::SeqCst)
    }

    /// Flip the toggle and persist it. The supervisor picks the change up on
    /// its next tick — this never spawns or signals anything itself, so a
    /// control connection can never block on a service starting.
    pub fn set_enabled(&self, enabled: bool) -> io::Result<()> {
        if enabled && !is_installed() {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!(
                    "the Kubernetes payload is not installed in this guest (expected {} and {} \
                     under {})",
                    PAYLOAD_NAMES[0],
                    PAYLOAD_NAMES[1],
                    bin_dir().display()
                ),
            ));
        }
        write_enabled_flag(enabled)?;
        self.gate.store(enabled, Ordering::SeqCst);
        self.set_snapshot(Snapshot::inert(if enabled {
            Phase::Starting
        } else {
            Phase::Stopped
        }));
        log::log(&format!(
            "kubernetes {} (persisted to {})",
            if enabled { "enabled" } else { "disabled" },
            enabled_flag_path().display()
        ));
        Ok(())
    }

    pub fn snapshot(&self) -> Snapshot {
        self.snapshot
            .lock()
            .map(|s| s.clone())
            .unwrap_or_else(|poisoned| poisoned.into_inner().clone())
    }

    fn set_snapshot(&self, next: Snapshot) {
        match self.snapshot.lock() {
            Ok(mut slot) => *slot = next,
            Err(poisoned) => *poisoned.into_inner() = next,
        }
    }
}

// ---------------------------------------------------------------------------
// Service table
// ---------------------------------------------------------------------------

/// dockerd's socket, which cri-dockerd is pointed at. Spelled out rather than
/// imported so the coupling is visible: this is the line that makes the
/// cluster and `docker build` share an image store.
const DOCKER_ENDPOINT: &str = "unix:///var/run/docker.sock";

/// The pod sandbox ("pause") image. Pinned rather than left to cri-dockerd's
/// built-in default so an upgrade of the shim cannot silently change which
/// image every pod in the cluster depends on.
const PAUSE_IMAGE: &str = "registry.k8s.io/pause:3.10";

/// The two gated services, in start order (the shim first: kubelet dials it
/// immediately and k3s would otherwise spend its first seconds retrying).
///
/// Both carry the same gate `Arc`, so one flag flip moves both.
pub fn service_specs(gate: Arc<AtomicBool>) -> Vec<ServiceSpec> {
    let state = state_root();
    let bin = bin_dir();

    let cri_args: Vec<String> = vec![
        format!("--container-runtime-endpoint=unix://{}", CRI_SOCKET),
        format!("--docker-endpoint={}", DOCKER_ENDPOINT),
        format!("--pod-infra-container-image={}", PAUSE_IMAGE),
        // Empty on purpose: with no CNI plugin, cri-dockerd leaves pod
        // networking to docker's own bridge, exactly as the old dockershim
        // did. That is what lets the node go Ready without waiting for a CNI
        // DaemonSet to land, and it is why k3s runs with --flannel-backend=none
        // below. The two settings are one decision and must move together.
        "--network-plugin=".to_string(),
        format!(
            "--cri-dockerd-root-directory={}",
            state.join("cri-dockerd").display()
        ),
    ];

    let k3s_args: Vec<String> = vec![
        "server".to_string(),
        format!("--data-dir={}", data_dir().display()),
        format!("--container-runtime-endpoint=unix://{}", CRI_SOCKET),
        // No CNI: see the cri-dockerd note above. --disable-network-policy
        // follows because the netpol controller is a flannel feature.
        "--flannel-backend=none".to_string(),
        "--disable-network-policy".to_string(),
        // traefik is a full ingress controller nobody asked for, and it is the
        // single biggest contributor to time-to-ready. servicelb (klipper-lb)
        // is deliberately KEPT: it is what turns a LoadBalancer Service into a
        // host port on the node, which the existing port forwarder then
        // publishes on the Mac's loopback with no extra machinery.
        "--disable=traefik".to_string(),
        // metrics-server is a 60 MB pull for `kubectl top`. Off by default;
        // one `kubectl apply` away for anyone who wants it.
        "--disable=metrics-server".to_string(),
        "--disable-helm-controller".to_string(),
        format!("--write-kubeconfig={}", kubeconfig_path().display()),
        // 0600 would be right on a shared machine. The guest has exactly one
        // user (root) and the file is fetched over an authenticated vsock
        // channel, so the mode that matters is the one the *host* writes at
        // ~/.morbstack/kubeconfig — which K8s.swift sets to 0600.
        "--write-kubeconfig-mode=0644".to_string(),
        format!("--node-name={}", NODE_NAME),
        // dockerd on Alpine has no systemd, so its native cgroup driver is
        // cgroupfs. kubelet must agree or every pod fails to start with a
        // cgroup-driver mismatch that reads like an unrelated CRI error.
        "--kubelet-arg=cgroup-driver=cgroupfs".to_string(),
        // Off the initramfs, or kubelet's container manager never starts. See
        // `kubelet_root_dir` for the full failure.
        format!("--kubelet-arg=root-dir={}", kubelet_root_dir().display()),
        // There is no swap in the guest, but kubelet's check is on the
        // *presence* of the file, and a future kernel that exposes an empty
        // /proc/swaps differently should not crash-loop the control plane.
        "--kubelet-arg=fail-swap-on=false".to_string(),
    ];

    vec![
        ServiceSpec {
            name: "cri-dockerd",
            path: leak_path(bin.join("cri-dockerd")),
            args: cri_args,
            env: Vec::new(),
            gate: Some(Arc::clone(&gate)),
        },
        ServiceSpec {
            name: "k3s",
            path: leak_path(bin.join("k3s")),
            args: k3s_args,
            env: Vec::new(),
            gate: Some(gate),
        },
    ]
}

/// `ServiceSpec::path` is a `&'static str` because every other service in the
/// table is a compile-time constant. These two are not — they live under a
/// path that is only known at runtime — so the string is leaked, deliberately
/// and exactly twice per boot. The alternative is turning `path` into a
/// `String` across the whole supervisor to save 80 bytes for the life of a
/// process that is PID 1.
fn leak_path(path: PathBuf) -> &'static str {
    Box::leak(path.display().to_string().into_boxed_str())
}

// ---------------------------------------------------------------------------
// Host prerequisites for kubelet
// ---------------------------------------------------------------------------

/// `MS_REC | MS_SHARED`, spelled out because `sys.rs` has no reason to know
/// about mount propagation.
const MS_REC: u64 = 1 << 14;
const MS_SHARED: u64 = 1 << 20;

/// Make the guest ready to run kubelet. Idempotent, best effort, and every
/// failure is logged rather than fatal: a partially prepared guest produces a
/// specific error from k3s, which is far more useful than morbinit refusing to
/// try.
///
/// Called once, when the gate first goes up, rather than at boot — this is the
/// "costs nothing when off" rule applied to sysctls as well as to bytes.
#[cfg(target_os = "linux")]
pub fn prepare_host() {
    for dir in [
        state_root(),
        bin_dir(),
        data_dir(),
        kubelet_root_dir(),
        state_root().join("cri-dockerd"),
    ] {
        if let Err(e) = std::fs::create_dir_all(&dir) {
            log::log(&format!("k8s: mkdir -p {} failed: {}", dir.display(), e));
        }
    }

    // kubelet propagates volume mounts out of its own mount namespace, which
    // requires the root mount to be shared. On a systemd host this is done by
    // the init system; morbinit is the init system.
    if let Err(e) = crate::sys::mount("none", "/", "none", MS_REC | MS_SHARED) {
        log::log(&format!(
            "k8s: could not make / rshared: {} — kubelet volume mounts may not \
             propagate into containers",
            e
        ));
    }

    // Service routing depends on bridged pod traffic being seen by iptables:
    // pods live on docker0 (no CNI, see `service_specs`), so without this a
    // pod cannot reach a ClusterIP. CONFIG_BRIDGE_NETFILTER is compiled into
    // the kata kernel, so the knob exists as soon as the bridge module is
    // live — which dockerd has already ensured by creating docker0.
    //
    // route_localnet is what makes a NodePort reachable at 127.0.0.1 from
    // inside the guest, which is in turn what lets the host's stream dialer
    // reach it. kube-proxy sets it too; setting it here means a NodePort works
    // even in the window before kube-proxy has synced.
    for (knob, value) in [
        ("/proc/sys/net/bridge/bridge-nf-call-iptables", "1"),
        ("/proc/sys/net/bridge/bridge-nf-call-ip6tables", "1"),
        ("/proc/sys/net/ipv4/conf/all/route_localnet", "1"),
        ("/proc/sys/net/ipv4/ip_forward", "1"),
    ] {
        if let Err(e) = std::fs::write(knob, value) {
            log::log(&format!("k8s: could not set {} = {}: {}", knob, value, e));
        }
    }
}

#[cfg(not(target_os = "linux"))]
pub fn prepare_host() {}

// ---------------------------------------------------------------------------
// Status probing
// ---------------------------------------------------------------------------

/// Count nodes and ready nodes in `kubectl get nodes --no-headers` output.
///
/// Columns are `NAME STATUS ROLES AGE VERSION`. A node is Ready only when the
/// status column is exactly `Ready` — `Ready,SchedulingDisabled` is a cordoned
/// node that will not run anything, and `NotReady` obviously is not one.
pub fn parse_node_table(output: &str) -> (u32, u32) {
    let mut total = 0;
    let mut ready = 0;
    for line in output.lines() {
        let mut fields = line.split_whitespace();
        let Some(_name) = fields.next() else { continue };
        let Some(status) = fields.next() else {
            continue;
        };
        total += 1;
        if status == "Ready" {
            ready += 1;
        }
    }
    (total, ready)
}

/// Count pods and ready pods in `kubectl get pods -A --no-headers` output.
///
/// Columns are `NAMESPACE NAME READY STATUS RESTARTS AGE`, where READY is
/// `<ready>/<total>` containers. A pod counts as ready when every container in
/// it is up *and* the phase is one that means it did its job — `Completed` and
/// `Succeeded` jobs report `0/1` and are not failures.
pub fn parse_pod_table(output: &str) -> (u32, u32) {
    let mut total = 0;
    let mut ready = 0;
    for line in output.lines() {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() < 4 {
            continue;
        }
        total += 1;
        let containers = fields[2];
        let status = fields[3];
        if status == "Completed" || status == "Succeeded" {
            ready += 1;
            continue;
        }
        if status != "Running" {
            continue;
        }
        if let Some((up, want)) = containers.split_once('/') {
            if !up.is_empty() && up == want {
                ready += 1;
            }
        }
    }
    (total, ready)
}

/// Run `k3s kubectl <args>` against the local cluster and return stdout.
///
/// stderr is captured rather than inherited: a `kubectl` that cannot reach the
/// API server prints a paragraph, and during the first ten seconds of a
/// cluster coming up that is *expected*, so it must not flood the console.
#[cfg(target_os = "linux")]
fn kubectl(args: &[&str]) -> io::Result<String> {
    use std::process::{Command, Stdio};

    let mut child = Command::new(binary_path("k3s"))
        .arg("kubectl")
        .args(args)
        .env("PATH", crate::supervisor::GUEST_PATH)
        .env("KUBECONFIG", kubeconfig_path())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;

    // Never `wait`ed on: the supervisor's `waitpid(-1)` drain is the only
    // reaper in morbinit and will almost always collect this pid first. The
    // pipe closing at exit is the synchronisation point instead — see the
    // same pattern in `supervisor::docker_stdout`.
    let mut out = String::new();
    if let Some(mut stdout) = child.stdout.take() {
        stdout.read_to_string(&mut out)?;
    }
    Ok(out)
}

#[cfg(not(target_os = "linux"))]
fn kubectl(_args: &[&str]) -> io::Result<String> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "kubectl is only run inside the guest",
    ))
}

/// Take one reading of the cluster.
fn probe() -> Snapshot {
    if !kubeconfig_path().exists() {
        return Snapshot {
            message: "k3s has not written its kubeconfig yet".to_string(),
            ..Snapshot::inert(Phase::Starting)
        };
    }

    let nodes_out = match kubectl(&["get", "nodes", "--no-headers"]) {
        Ok(o) => o,
        Err(e) => {
            return Snapshot {
                message: format!("could not run kubectl: {}", e),
                ..Snapshot::inert(Phase::Starting)
            }
        }
    };
    let (nodes, nodes_ready) = parse_node_table(&nodes_out);
    if nodes == 0 {
        return Snapshot {
            message: "the API server is not answering yet".to_string(),
            ..Snapshot::inert(Phase::Starting)
        };
    }

    let (pods, pods_ready) = kubectl(&["get", "pods", "-A", "--no-headers"])
        .map(|o| parse_pod_table(&o))
        .unwrap_or((0, 0));

    Snapshot {
        phase: if nodes_ready > 0 {
            Phase::Ready
        } else {
            Phase::Starting
        },
        nodes,
        nodes_ready,
        pods,
        pods_ready,
        message: if nodes_ready > 0 {
            String::new()
        } else {
            "the node has registered but is not Ready yet".to_string()
        },
    }
}

/// Keep `state`'s cached snapshot fresh on a thread of its own.
///
/// The control channel reads the cache and never runs `kubectl` itself. That
/// is the point: a wedged API server would otherwise park a control-connection
/// thread for the whole probe timeout, and `morb status` would hang on a
/// feature the user may not even have turned on.
#[cfg(target_os = "linux")]
pub fn spawn_monitor(state: Arc<K8sState>) {
    let spawned = std::thread::Builder::new()
        .name("k8s-monitor".to_string())
        .spawn(move || loop {
            if !state.is_enabled() {
                let phase = if is_installed() {
                    Phase::Stopped
                } else {
                    Phase::NotInstalled
                };
                let current = state.snapshot();
                if current.phase != phase || current.nodes != 0 {
                    state.set_snapshot(Snapshot::inert(phase));
                }
                std::thread::sleep(MONITOR_INTERVAL);
                continue;
            }

            let started = Instant::now();
            let snapshot = probe();
            state.set_snapshot(snapshot);
            // A probe that took longer than its budget means the API server is
            // struggling; say so once rather than every 1.5s.
            if started.elapsed() > PROBE_TIMEOUT {
                log::log(&format!(
                    "k8s: a status probe took {:?} — the API server is slow to answer",
                    started.elapsed()
                ));
            }
            std::thread::sleep(MONITOR_INTERVAL);
        });
    if let Err(e) = spawned {
        log::log(&format!("k8s: could not spawn the status monitor: {}", e));
    }
}

#[cfg(not(target_os = "linux"))]
pub fn spawn_monitor(_state: Arc<K8sState>) {}

/// Read the admin kubeconfig k3s wrote, for the host to rewrite and hand to
/// `kubectl`.
pub fn read_kubeconfig() -> io::Result<String> {
    std::fs::read_to_string(kubeconfig_path())
}

// ---------------------------------------------------------------------------
// The payload install channel (vsock 2377)
// ---------------------------------------------------------------------------

/// One request off the install channel.
#[derive(Debug, PartialEq, Eq)]
pub enum InstallRequest {
    /// "do you already have this exact file?"
    Have { name: String, sha256: String },
    /// "here come `length` bytes of `name`, whose digest is `sha256`".
    Put {
        name: String,
        length: u64,
        sha256: String,
    },
}

/// Parse an install-channel preamble line.
///
/// ```text
/// HAVE <name> <sha256hex>
/// PUT  <name> <length> <sha256hex>
/// ```
///
/// `name` is checked against `PAYLOAD_NAMES` here rather than at the point of
/// use. That check is the security boundary of this whole channel: the host
/// picks the name, and a name that reached the filesystem unchecked could be
/// `../../init`.
pub fn parse_install_request(line: &str) -> Result<InstallRequest, String> {
    let fields: Vec<&str> = line.split_whitespace().collect();
    let verb = fields.first().copied().unwrap_or("");

    let check_name = |name: &str| -> Result<String, String> {
        if PAYLOAD_NAMES.contains(&name) {
            Ok(name.to_string())
        } else {
            Err(format!(
                "unknown payload name {:?} (expected one of {:?})",
                name, PAYLOAD_NAMES
            ))
        }
    };
    let check_digest = |digest: &str| -> Result<String, String> {
        if digest.len() == 64 && digest.bytes().all(|b| b.is_ascii_hexdigit()) {
            Ok(digest.to_ascii_lowercase())
        } else {
            Err(format!("{:?} is not a 64-character hex sha256", digest))
        }
    };

    match verb {
        "HAVE" if fields.len() == 3 => Ok(InstallRequest::Have {
            name: check_name(fields[1])?,
            sha256: check_digest(fields[2])?,
        }),
        "PUT" if fields.len() == 4 => {
            let length: u64 = fields[2]
                .parse()
                .map_err(|_| format!("{:?} is not a byte count", fields[2]))?;
            if length == 0 || length > MAX_PAYLOAD_BYTES {
                return Err(format!(
                    "refusing a {}-byte payload (cap {})",
                    length, MAX_PAYLOAD_BYTES
                ));
            }
            Ok(InstallRequest::Put {
                name: check_name(fields[1])?,
                length,
                sha256: check_digest(fields[3])?,
            })
        }
        "HAVE" | "PUT" => Err(format!("wrong number of fields for {}", verb)),
        "" => Err("empty request".to_string()),
        other => Err(format!("unknown verb {:?}", other)),
    }
}

/// Whether the installed `name` already hashes to `want`.
///
/// Re-hashed every time rather than cached in a sidecar file. Hashing 74 MB
/// off a warm page cache costs a fraction of a second and happens only on an
/// explicit enable, and a cache would mean the guest could tell the host "yes,
/// I have that" about a file that was truncated by a crash.
pub fn installed_digest_matches(name: &str, want: &str) -> bool {
    match sha256::hash_file(&binary_path(name).display().to_string()) {
        Ok(got) => got == want,
        Err(_) => false,
    }
}

fn write_line<W: Write>(writer: &mut W, line: &str) -> io::Result<()> {
    writer.write_all(line.as_bytes())?;
    writer.write_all(b"\n")?;
    writer.flush()
}

/// Serve one install-channel connection.
///
/// Portable over `Read + Write` so the whole protocol — including the
/// digest-mismatch path, which is the one that must never leave a bad binary
/// on the disk — is exercised by unit tests on the macOS dev host with an
/// in-memory stream.
pub fn handle_install_connection<S: Read + Write>(conn: &mut S, state: &K8sState) {
    let line = match crate::wire::read_install_preamble_line(conn, MAX_PREAMBLE_LEN) {
        Ok(l) => l,
        Err(e) => {
            log::log(&format!("k8s install: {}", e));
            let _ = write_line(conn, &format!("ERR {}", e));
            return;
        }
    };

    let request = match parse_install_request(&line) {
        Ok(r) => r,
        Err(reason) => {
            log::log(&format!("k8s install: rejected request: {}", reason));
            let _ = write_line(conn, &format!("ERR {}", reason));
            return;
        }
    };

    match request {
        InstallRequest::Have { name, sha256 } => {
            let have = installed_digest_matches(&name, &sha256);
            let _ = write_line(conn, if have { "YES" } else { "NO" });
        }
        InstallRequest::Put {
            name,
            length,
            sha256,
        } => {
            // Serialised: two concurrent PUTs of the same name would race on
            // the rename and could leave the loser's temp file behind.
            let _guard = state
                .install_lock
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());

            if write_line(conn, "OK").is_err() {
                return;
            }
            match receive_payload(conn, &name, length, &sha256) {
                Ok(()) => {
                    log::log(&format!(
                        "k8s install: {} ({} bytes) verified and installed at {}",
                        name,
                        length,
                        binary_path(&name).display()
                    ));
                    let _ = write_line(conn, "OK");
                }
                Err(e) => {
                    log::log(&format!("k8s install: {} failed: {}", name, e));
                    let _ = write_line(conn, &format!("ERR {}", e));
                }
            }
        }
    }
}

/// Stream `length` bytes into a temporary file, verify the digest, and only
/// then move it into place.
///
/// Write-verify-rename, in that order, is the entire reason this is not just
/// "write to the final path": a binary that fails its digest must never be
/// reachable at a path the supervisor is willing to `exec`.
fn receive_payload<R: Read>(
    reader: &mut R,
    name: &str,
    length: u64,
    want_digest: &str,
) -> io::Result<()> {
    std::fs::create_dir_all(bin_dir())?;
    let final_path = binary_path(name);
    let temp_path = bin_dir().join(format!(".{}.incoming", name));
    stream_verify_rename(reader, &temp_path, &final_path, length, want_digest)
}

/// The path-parameterized body of `receive_payload`, so the truncation,
/// digest-mismatch, and cleanup behavior unit test against a scratch
/// directory on the macOS dev host.
///
/// Every failure removes the staging file: the next attempt removes it anyway,
/// but a failed 512 MB transfer must not squat on the persistent disk until
/// then, and an I/O error mid-write must not leave unverified bytes lying at a
/// predictable path.
fn stream_verify_rename<R: Read>(
    reader: &mut R,
    temp_path: &Path,
    final_path: &Path,
    length: u64,
    want_digest: &str,
) -> io::Result<()> {
    // A leftover from an interrupted earlier attempt is not evidence of
    // anything; truncating is what `File::create` does anyway, but removing it
    // first means a stale file with awkward permissions cannot fail the open.
    let _ = std::fs::remove_file(temp_path);
    let result = stream_verify_rename_inner(reader, temp_path, final_path, length, want_digest);
    if result.is_err() {
        let _ = std::fs::remove_file(temp_path);
    }
    result
}

fn stream_verify_rename_inner<R: Read>(
    reader: &mut R,
    temp_path: &Path,
    final_path: &Path,
    length: u64,
    want_digest: &str,
) -> io::Result<()> {
    let mut hasher = sha256::Sha256::new();
    let mut written: u64 = 0;
    {
        let mut file = std::fs::File::create(temp_path)?;
        let mut buffer = vec![0u8; TRANSFER_CHUNK];
        while written < length {
            let want = ((length - written) as usize).min(buffer.len());
            let n = reader.read(&mut buffer[..want])?;
            if n == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    format!(
                        "the host sent {} of {} bytes and then closed the stream",
                        written, length
                    ),
                ));
            }
            file.write_all(&buffer[..n])?;
            hasher.update(&buffer[..n]);
            written += n as u64;
        }
        file.flush()?;
        // The payload has to be on the disk before the rename makes it
        // reachable, or a power loss between the two leaves a name pointing at
        // nothing. This is the same argument as the shutdown flush, at a much
        // smaller scale.
        file.sync_all()?;
    }

    let got = sha256::hex(&hasher.finalize());
    if got != want_digest {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "sha256 mismatch after {} bytes: got {}, host said {}",
                written, got, want_digest
            ),
        ));
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(temp_path, std::fs::Permissions::from_mode(0o755))?;
    }
    std::fs::rename(temp_path, final_path)?;
    sync_now();
    Ok(())
}

/// Bind vsock 2377 and serve the install protocol, one connection at a time.
///
/// Serial on purpose. There are exactly two files, the host sends them one
/// after another, and a concurrent accept loop here would buy nothing but the
/// chance for two 74 MB writes to contend for the same disk.
#[cfg(target_os = "linux")]
pub fn spawn_install_server(state: Arc<K8sState>) -> io::Result<()> {
    let listener = crate::sys::VsockListener::bind(VSOCK_K8S_INSTALL_PORT)?;
    std::thread::Builder::new()
        .name("k8s-install".to_string())
        .spawn(move || loop {
            match listener.accept() {
                Ok(mut conn) => {
                    // Bound the wait for the host's first byte. The accept loop
                    // is serial — there are exactly two files and the host
                    // sends them one after the other — so a peer that connects
                    // and then says nothing would otherwise wedge installs for
                    // every later caller. Once the preamble starts arriving the
                    // rest follows immediately, so this one poll is the whole
                    // guard that is needed.
                    use std::os::unix::io::AsRawFd;
                    let ready = crate::sys::poll_readable(
                        conn.as_raw_fd(),
                        PREAMBLE_TIMEOUT.as_millis() as i32,
                    );
                    match ready {
                        Ok(true) => handle_install_connection(&mut conn, &state),
                        Ok(false) => log::log(&format!(
                            "k8s install: a connection sent nothing within {:?} — dropping it",
                            PREAMBLE_TIMEOUT
                        )),
                        Err(e) => log::log(&format!("k8s install: poll failed: {}", e)),
                    }
                }
                Err(e) => {
                    log::log(&format!("k8s install accept error: {}", e));
                    std::thread::sleep(Duration::from_millis(100));
                }
            }
        })?;
    Ok(())
}

#[cfg(not(target_os = "linux"))]
pub fn spawn_install_server(_state: Arc<K8sState>) -> io::Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn node_table_counts_only_exactly_ready_nodes() {
        let out = "\
morbstack   Ready      control-plane,master   42s   v1.36.2+k3s1
other       NotReady   <none>                 10s   v1.36.2+k3s1
cordoned    Ready,SchedulingDisabled   <none>   1h   v1.36.2+k3s1
";
        assert_eq!(parse_node_table(out), (3, 1));
    }

    #[test]
    fn an_empty_node_table_is_zero_not_a_panic() {
        // What the probe sees for the first several seconds of a cold start,
        // and what it sees if kubectl printed only a stderr paragraph.
        assert_eq!(parse_node_table(""), (0, 0));
        assert_eq!(parse_node_table("\n\n  \n"), (0, 0));
        // A single bare word is a malformed row, not a node.
        assert_eq!(parse_node_table("morbstack\n"), (0, 0));
    }

    #[test]
    fn pod_table_counts_ready_containers_and_finished_jobs() {
        let out = "\
kube-system   coredns-abc-123                 1/1   Running     0   30s
kube-system   local-path-provisioner-xyz      1/1   Running     0   30s
kube-system   svclb-demo-000                  0/1   Pending     0   5s
default       demo-7d9f                       2/2   Running     1   12s
default       migrate-once                    0/1   Completed   0   1m
default       broken                          0/1   CrashLoopBackOff   6   4m
";
        // 6 pods; ready = 2 coredns/local-path + demo(2/2) + the Completed job.
        assert_eq!(parse_pod_table(out), (6, 4));
    }

    #[test]
    fn a_partially_ready_running_pod_is_not_ready() {
        let out = "default   half   1/2   Running   0   9s\n";
        assert_eq!(parse_pod_table(out), (1, 0));
    }

    #[test]
    fn short_pod_rows_are_ignored_rather_than_indexed_into() {
        // Defensive: kubectl warnings and blank lines share the stream.
        let out = "warning: something\n\ndefault   ok   1/1   Running   0   1s\n";
        assert_eq!(parse_pod_table(out), (1, 1));
    }

    // ---- install protocol -------------------------------------------------

    const DIGEST: &str = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    #[test]
    fn parses_have_and_put() {
        assert_eq!(
            parse_install_request(&format!("HAVE k3s {}", DIGEST)).unwrap(),
            InstallRequest::Have {
                name: "k3s".to_string(),
                sha256: DIGEST.to_string()
            }
        );
        assert_eq!(
            parse_install_request(&format!("PUT cri-dockerd 48693410 {}", DIGEST)).unwrap(),
            InstallRequest::Put {
                name: "cri-dockerd".to_string(),
                length: 48_693_410,
                sha256: DIGEST.to_string()
            }
        );
    }

    #[test]
    fn a_payload_name_outside_the_allow_list_is_refused() {
        // The security boundary of the whole channel: the host names the file,
        // and morbinit is PID 1. A traversal that reached the filesystem could
        // replace /init and own the next boot.
        for name in ["../../init", "/init", "dockerd", "k3s/../../init", ""] {
            let request = format!("PUT {} 10 {}", name, DIGEST);
            assert!(
                parse_install_request(&request).is_err(),
                "accepted payload name {:?}",
                name
            );
        }
    }

    #[test]
    fn a_malformed_digest_or_length_is_refused() {
        assert!(parse_install_request("PUT k3s 10 nothex").is_err());
        assert!(parse_install_request(&format!("PUT k3s zero {}", DIGEST)).is_err());
        assert!(parse_install_request(&format!("PUT k3s 0 {}", DIGEST)).is_err());
        // Above the cap, before a single byte is written.
        assert!(parse_install_request(&format!("PUT k3s 999999999999 {}", DIGEST)).is_err());
        assert!(parse_install_request(&format!("HAVE k3s {}", DIGEST)).is_ok());
        assert!(parse_install_request("HAVE k3s").is_err());
        assert!(parse_install_request("FROBNICATE k3s").is_err());
        assert!(parse_install_request("").is_err());
    }

    #[test]
    fn digests_are_normalised_to_lower_case() {
        let upper = DIGEST.to_ascii_uppercase();
        match parse_install_request(&format!("HAVE k3s {}", upper)).unwrap() {
            InstallRequest::Have { sha256, .. } => assert_eq!(sha256, DIGEST),
            other => panic!("unexpected {:?}", other),
        }
    }

    #[test]
    fn a_preamble_with_no_newline_is_bounded() {
        let mut input = std::io::Cursor::new(vec![b'A'; MAX_PREAMBLE_LEN * 4]);
        assert!(crate::wire::read_install_preamble_line(&mut input, MAX_PREAMBLE_LEN).is_err());
    }

    // ---- payload streaming: write-verify-rename -----------------------------

    #[test]
    fn a_verified_payload_is_renamed_into_place_and_the_staging_file_is_gone() {
        let scratch = Scratch::new("put-ok");
        let temp = scratch.0.join(".k3s.incoming");
        let dest = scratch.0.join("k3s");
        let payload = b"#!/bin/sh\nexit 0\n";
        let digest = sha256::hex_of(payload);

        stream_verify_rename(
            &mut std::io::Cursor::new(payload.to_vec()),
            &temp,
            &dest,
            payload.len() as u64,
            &digest,
        )
        .expect("a byte-exact payload must install");

        assert_eq!(std::fs::read(&dest).unwrap(), payload);
        assert!(!temp.exists(), "staging file must not survive success");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&dest).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o755);
        }
    }

    #[test]
    fn a_truncated_stream_is_a_clean_error_and_leaves_no_partial_file() {
        // The host claims 1000 bytes but hangs up after 10. Nothing may be
        // reachable at the final path, and the staging file must be cleaned
        // up rather than squatting on the persistent disk until the retry.
        let scratch = Scratch::new("put-truncated");
        let temp = scratch.0.join(".k3s.incoming");
        let dest = scratch.0.join("k3s");

        let err = stream_verify_rename(
            &mut std::io::Cursor::new(vec![0xab; 10]),
            &temp,
            &dest,
            1000,
            DIGEST,
        )
        .unwrap_err();

        assert_eq!(err.kind(), io::ErrorKind::UnexpectedEof);
        assert!(!dest.exists(), "no partial binary may become reachable");
        assert!(!temp.exists(), "staging file must be removed on failure");
    }

    #[test]
    fn a_digest_mismatch_never_leaves_the_payload_reachable() {
        // Right length, wrong bytes: the exact case write-verify-rename
        // exists for. The binary must not appear at a path the supervisor is
        // willing to exec, and the staging copy must be removed.
        let scratch = Scratch::new("put-mismatch");
        let temp = scratch.0.join(".k3s.incoming");
        let dest = scratch.0.join("k3s");
        let payload = vec![0x5a_u8; 64];

        let err = stream_verify_rename(
            &mut std::io::Cursor::new(payload.clone()),
            &temp,
            &dest,
            payload.len() as u64,
            DIGEST, // digest of the empty string; cannot match 64 bytes
        )
        .unwrap_err();

        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
        assert!(!dest.exists());
        assert!(!temp.exists());
    }

    // ---- enable-state persistence -----------------------------------------

    /// A scratch directory that removes itself, so these tests leave nothing
    /// behind on a dev machine.
    struct Scratch(PathBuf);
    impl Scratch {
        fn new(tag: &str) -> Self {
            let dir = std::env::temp_dir().join(format!(
                "morbstack-k8s-{}-{}-{:?}",
                tag,
                std::process::id(),
                std::thread::current().id()
            ));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).unwrap();
            Self(dir)
        }
    }
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn the_enable_flag_survives_being_forgotten_and_read_back() {
        // This is the reboot, modelled: write the flag, throw away every bit
        // of in-process state, and ask the filesystem again. Kubernetes coming
        // back up after `morb stop` depends on exactly this and nothing else.
        let scratch = Scratch::new("persist");
        assert!(!read_enabled_flag_in(&scratch.0), "must default to off");

        write_enabled_flag_in(&scratch.0, true).unwrap();
        assert!(read_enabled_flag_in(&scratch.0));

        write_enabled_flag_in(&scratch.0, false).unwrap();
        assert!(!read_enabled_flag_in(&scratch.0));
    }

    #[test]
    fn writing_the_flag_creates_the_state_root_if_it_is_missing() {
        // First-ever enable on a freshly formatted disk: nothing exists yet.
        let scratch = Scratch::new("mkdir");
        let nested = scratch.0.join("morbstack-k8s");
        assert!(!nested.exists());
        write_enabled_flag_in(&nested, true).unwrap();
        assert!(read_enabled_flag_in(&nested));
    }

    #[test]
    fn disabling_something_that_was_never_enabled_is_not_an_error() {
        // `morb k8s disable` on a guest that never had a cluster must be a
        // successful no-op, not an error the CLI has to explain away.
        let scratch = Scratch::new("idempotent");
        write_enabled_flag_in(&scratch.0, false).unwrap();
        write_enabled_flag_in(&scratch.0, false).unwrap();
        assert!(!read_enabled_flag_in(&scratch.0));
    }

    #[test]
    fn enabling_twice_leaves_exactly_one_flag() {
        let scratch = Scratch::new("twice");
        write_enabled_flag_in(&scratch.0, true).unwrap();
        write_enabled_flag_in(&scratch.0, true).unwrap();
        assert!(read_enabled_flag_in(&scratch.0));
        let entries: Vec<_> = std::fs::read_dir(&scratch.0).unwrap().collect();
        assert_eq!(entries.len(), 1);
    }

    #[test]
    fn enabling_is_refused_when_the_payload_is_not_installed() {
        // The macOS test host has no /var/lib/docker/morbstack-k8s/bin, which
        // is the same state a guest is in before the host has streamed the
        // payload across. Enabling then would raise the gate on two binaries
        // that do not exist, and the supervisor would log "not found" every
        // thirty seconds forever instead of anyone being told why.
        let state = K8sState::from_disk(true);
        assert!(!is_installed());
        let err = state.set_enabled(true).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::NotFound);
        assert!(!state.is_enabled(), "the gate must not have moved");
        assert_eq!(state.snapshot().phase, Phase::NotInstalled);
    }

    #[test]
    fn a_fresh_state_reports_not_installed_and_stays_off() {
        let state = K8sState::from_disk(false);
        assert!(!state.is_enabled());
        assert_eq!(state.snapshot().phase, Phase::NotInstalled);
        assert!(!state.persistent);
    }

    #[test]
    fn phase_tokens_are_the_ones_the_host_renders() {
        assert_eq!(Phase::NotInstalled.as_str(), "not-installed");
        assert_eq!(Phase::Stopped.as_str(), "stopped");
        assert_eq!(Phase::Starting.as_str(), "starting");
        assert_eq!(Phase::Ready.as_str(), "ready");
    }

    #[test]
    fn service_specs_wire_the_cluster_to_the_existing_dockerd() {
        // The single most important assertion in this file: if cri-dockerd is
        // ever pointed somewhere other than the dockerd the Docker socket
        // serves, `docker build` output stops being runnable in the cluster
        // and the entire reason for choosing cri-dockerd over containerd is
        // gone — silently, with everything still appearing to work.
        let gate = Arc::new(AtomicBool::new(false));
        let specs = service_specs(gate);
        let cri = specs.iter().find(|s| s.name == "cri-dockerd").unwrap();
        assert!(cri
            .args
            .iter()
            .any(|a| a == &format!("--docker-endpoint={}", DOCKER_ENDPOINT)));

        let k3s = specs.iter().find(|s| s.name == "k3s").unwrap();
        assert!(k3s
            .args
            .iter()
            .any(|a| a == &format!("--container-runtime-endpoint=unix://{}", CRI_SOCKET)));
        // ...and k3s must never be allowed to fall back to its own bundled
        // containerd, which would give the cluster a second, separate image
        // store that `docker build` does not write to.
        assert!(!k3s.args.iter().any(|a| a.contains("containerd")));
    }

    #[test]
    fn no_cni_and_no_flannel_are_one_decision() {
        // Pods get docker-bridge networking, so flannel must be off; flannel
        // on with no CNI plugin is a node that never goes Ready. The two flags
        // are only correct together.
        let specs = service_specs(Arc::new(AtomicBool::new(false)));
        let cri = specs.iter().find(|s| s.name == "cri-dockerd").unwrap();
        let k3s = specs.iter().find(|s| s.name == "k3s").unwrap();
        assert!(cri.args.iter().any(|a| a == "--network-plugin="));
        assert!(k3s.args.iter().any(|a| a == "--flannel-backend=none"));
    }

    #[test]
    fn servicelb_is_kept_so_loadbalancer_services_reach_the_mac() {
        // klipper-lb turns a LoadBalancer Service into a hostPort on the node,
        // which cri-dockerd publishes as a docker port binding, which the
        // host's existing PortForwarder then mirrors onto 127.0.0.1 with no
        // new machinery. Disabling servicelb would break that chain and leave
        // every LoadBalancer stuck in <pending>.
        let specs = service_specs(Arc::new(AtomicBool::new(false)));
        let k3s = specs.iter().find(|s| s.name == "k3s").unwrap();
        assert!(!k3s.args.iter().any(|a| a.contains("servicelb")));
        assert!(k3s.args.iter().any(|a| a == "--disable=traefik"));
    }

    #[test]
    fn both_services_share_one_gate() {
        let gate = Arc::new(AtomicBool::new(false));
        let specs = service_specs(Arc::clone(&gate));
        assert_eq!(specs.len(), 2);
        for spec in &specs {
            assert!(spec.gate.is_some(), "{} is ungated", spec.name);
        }
        gate.store(true, Ordering::SeqCst);
        for spec in &specs {
            assert!(spec.gate.as_ref().unwrap().load(Ordering::SeqCst));
        }
    }

    #[test]
    fn kubelet_is_pointed_off_the_initramfs() {
        // Regression, and it cost a crash loop to find. kubelet asks cAdvisor for
        // filesystem stats about its root directory before starting its container
        // manager; the default /var/lib/kubelet lives on the initramfs, whose
        // device is the string "rootfs" and appears in no filesystem table, so
        // kubelet died with `failed to get rootfs info: cannot find filesystem
        // info for device "rootfs"` about three seconds into every start — and the
        // supervisor faithfully restarted it, forever, with the real cause buried
        // a hundred lines above each restart.
        let specs = service_specs(Arc::new(AtomicBool::new(false)));
        let k3s = specs.iter().find(|s| s.name == "k3s").unwrap();
        let arg = k3s
            .args
            .iter()
            .find(|a| a.starts_with("--kubelet-arg=root-dir="))
            .expect("kubelet must be given an explicit root-dir");
        assert!(
            arg.contains(STATE_ROOT),
            "kubelet's root-dir must be on the persistent disk, got {}",
            arg
        );
        assert!(!arg.contains("=/var/lib/kubelet"));
    }

    #[test]
    fn k3s_data_dir_is_on_the_persistent_disk() {
        // k3s self-extracts ~250 MB of bundled helper binaries into its data
        // dir on first start. On the initramfs rootfs that is a quarter of a
        // gigabyte of RAM that can never be reclaimed.
        assert!(data_dir().starts_with(STATE_ROOT));
        assert!(state_root().starts_with("/var/lib/docker"));
    }
}
