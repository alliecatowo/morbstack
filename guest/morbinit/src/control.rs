//! The guest control server: a vsock listener on port 1024 speaking the
//! "MRB0 framing" protocol defined in the shared contract.
//!
//! Frame format: 4 ASCII bytes `"MRB0"`, then a big-endian u32 payload
//! length, then that many bytes of UTF-8 JSON payload. Capped at 1 MiB.
//!
//! The frame codec (`read_frame`/`write_frame`) and message dispatch
//! (`handle_request`) are written as portable code over generic
//! `Read`/`Write`, so they unit-test on macOS with in-memory buffers. Only
//! the actual AF_VSOCK listener (`sys::VsockListener`) is Linux-only.

use crate::jsonlite::{self, Value};
use crate::log;
use std::io::{self, Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// vsock port the guest control channel listens on, per the shared contract's
/// port registry (1024 = guest control, 2375 = Docker Engine API relay).
/// Mirrors `MorbVsockPorts.guestControl` on the host side.
pub const VSOCK_CONTROL_PORT: u32 = 1024;

/// Magic bytes that open every MRB0 frame.
const MAGIC: &[u8; 4] = b"MRB0";
/// Payload size cap, per the shared contract ("1 MiB cap"). Enforced before
/// allocating the receive buffer, so a malicious/corrupt length header
/// can't be used to force a huge allocation.
const MAX_PAYLOAD: u32 = 1 << 20;

/// Guest capability for the future host FSEvents delivery contract.
///
/// This is intentionally a negative, additive capability rather than a fake control
/// request. Linux inotify queues are owned by the kernel and there is no userspace API
/// for injecting host-originated events into arbitrary watcher descriptors. Until the
/// guest has an explicit kernel/filesystem endpoint *and* a bounded event transport,
/// `morbinit` must report `unavailable` rather than implying VirtioFS supports hot
/// reload. See docs/protocol.md §5.4.
pub const SHARE_EVENT_BRIDGE_CAPABILITY: &str = crate::live_share::ADVERTISED_CAPABILITY;

/// The reserved schema version for a future acknowledged share-event receiver.
///
/// This describes the event-record shape in `docs/protocol.md` §5.4 only. It is
/// deliberately independent of ``SHARE_EVENT_BRIDGE_CAPABILITY``: reporting version
/// 1 while the capability remains `unavailable` does not advertise a receiver,
/// transport, acknowledgement path, or hot-reload support. A future host must require
/// both an exact supported version and an explicit `ready` capability before it starts
/// an FSEvents stream.
pub const SHARE_EVENT_BRIDGE_CONTRACT_VERSION: i64 = crate::live_share::CONTRACT_VERSION;

/// Guest capability for a future stop-only host disk-growth transaction.
///
/// The initramfs contains filesystem utilities, but that is not a resize protocol:
/// the host has no explicit target/transaction request, and the guest has no way to
/// identify the mounted filesystem, resize it safely, and prove the result back to
/// the host. Advertise the absence so a larger `disk.img` is never mistaken for a
/// larger Docker filesystem. See docs/protocol.md §2.2.
pub const DISK_RESIZE_CAPABILITY: &str = "unavailable";

/// Read one MRB0 frame from `r`, returning its JSON payload bytes.
pub fn read_frame<R: Read>(r: &mut R) -> io::Result<Vec<u8>> {
    let mut magic = [0u8; 4];
    r.read_exact(&mut magic)?;
    if &magic != MAGIC {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("bad MRB0 magic: {:?}", magic),
        ));
    }

    let mut len_buf = [0u8; 4];
    r.read_exact(&mut len_buf)?;
    let len = u32::from_be_bytes(len_buf);
    if len > MAX_PAYLOAD {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("frame payload too large: {} bytes (cap {})", len, MAX_PAYLOAD),
        ));
    }

    let mut payload = vec![0u8; len as usize];
    r.read_exact(&mut payload)?;
    Ok(payload)
}

/// Write one MRB0 frame containing `payload` to `w`.
pub fn write_frame<W: Write>(w: &mut W, payload: &[u8]) -> io::Result<()> {
    if payload.len() > MAX_PAYLOAD as usize {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "refusing to write oversize frame: {} bytes (cap {})",
                payload.len(),
                MAX_PAYLOAD
            ),
        ));
    }
    w.write_all(MAGIC)?;
    w.write_all(&(payload.len() as u32).to_be_bytes())?;
    w.write_all(payload)?;
    w.flush()
}

/// The three-step handshake between a `shutdown` request and the actual
/// `reboot(2)`.
///
/// The shared contract requires that the `ok` frame be the **last** thing
/// the host sees: it is the host's proof that services stopped and the
/// layer store reached the disk, so sending it up front (as morbinit used
/// to) makes it a promise about the future rather than a report about the
/// past — and a host that trusts it can tear the VM down mid-flush.
///
/// So the reply is deliberately deferred, which means two waits pointing in
/// opposite directions:
///
/// ```text
///  control thread                    supervisor (main) thread
///  --------------                    ------------------------
///  request()          ------------>  is_requested()
///  wait_stopped(..)                  stop services, flush disk
///                     <------------  mark_stopped()
///  write "ok" frame
///  mark_replied()     ------------>  wait_replied(..)
///                                    power_off()
/// ```
///
/// Both waits are bounded and failure-tolerant: a wedged peer costs a
/// timeout and a log line, never a guest that will not power off. Polling
/// rather than a condvar because the waits happen exactly twice in a
/// process's lifetime and the states are one-way latches — the machinery to
/// avoid a 25ms poll here would cost more than it saves.
///
/// Meanwhile the accept loop keeps running and every other connection keeps
/// being served, so the host can still `ping` throughout the shutdown.
pub struct ShutdownSignal {
    requested: AtomicBool,
    stopped: AtomicBool,
    replied: AtomicBool,
}

/// How often the two waits below re-check their latch.
const LATCH_POLL_INTERVAL: Duration = Duration::from_millis(25);

impl ShutdownSignal {
    pub fn new() -> Self {
        Self {
            requested: AtomicBool::new(false),
            stopped: AtomicBool::new(false),
            replied: AtomicBool::new(false),
        }
    }

    /// A signal for contexts with no supervisor behind it (the
    /// `--serve-control` test mode): `stopped` starts latched, so a
    /// `shutdown` request is answered immediately instead of waiting out a
    /// timeout for a sequence nobody is going to run.
    pub fn detached() -> Self {
        let s = Self::new();
        s.stopped.store(true, Ordering::SeqCst);
        s
    }

    /// Ask for shutdown. Idempotent, and never lowered once raised.
    pub fn request(&self) {
        self.requested.store(true, Ordering::SeqCst);
    }

    pub fn is_requested(&self) -> bool {
        self.requested.load(Ordering::SeqCst)
    }

    /// Announce that services are stopped and storage is flushed, so the
    /// `ok` frame may now go out.
    pub fn mark_stopped(&self) {
        self.stopped.store(true, Ordering::SeqCst);
    }

    /// Announce that the `ok` frame has been written, so it is safe to cut
    /// the power.
    pub fn mark_replied(&self) {
        self.replied.store(true, Ordering::SeqCst);
    }

    /// Block until `mark_stopped`, or `timeout`. Returns whether it latched.
    pub fn wait_stopped(&self, timeout: Duration) -> bool {
        wait_for_latch(&self.stopped, timeout)
    }

    /// Block until `mark_replied`, or `timeout`. Returns whether it latched.
    pub fn wait_replied(&self, timeout: Duration) -> bool {
        wait_for_latch(&self.replied, timeout)
    }
}

impl Default for ShutdownSignal {
    fn default() -> Self {
        Self::new()
    }
}

fn wait_for_latch(flag: &AtomicBool, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    loop {
        if flag.load(Ordering::SeqCst) {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(LATCH_POLL_INTERVAL);
    }
}

/// Headroom for the disk flush that runs *after* the last service is stopped
/// and *before* the `ok` frame: `sync(2)`, `umount(2)` of `/var/lib/docker`,
/// and (if that says EBUSY) a read-only remount plus a lazy detach.
///
/// This is the part the budget used to forget. Stopping services is bounded
/// by signals and graces, but the umount is bounded by *writeback*: after a
/// heavy `docker pull` the layer store can hold hundreds of megabytes of
/// dirty pages, and umount does not return until they are on the virtio
/// device. 30s covers that comfortably on a slow host disk.
pub const FLUSH_ALLOWANCE: Duration = Duration::from_secs(30);

/// How long a `shutdown` connection waits for the supervisor to report the
/// guest fully stopped — services down *and* storage flushed — before
/// answering anyway.
///
/// ```text
/// ======================================================================
///  THIS NUMBER IS DERIVED, NOT CHOSEN. DO NOT HAND-EDIT IT.
///
///    SUPERVISED_SERVICE_COUNT * (STOP_GRACE + KILL_GRACE) + FLUSH_ALLOWANCE
///  =            2             * (    10s    +     2s    ) +      30s
///  =                       24s                            +      30s
///  =                                 54s
///
///  Timing out here means writing an `ok` that is a promise about the
///  future rather than a report about the past — the exact bug this whole
///  handshake exists to prevent (see `ShutdownSignal`). So the budget must
///  cover *everything* that precedes the reply: the full stop ladder
///  (sequential, so the per-service graces add up rather than overlapping)
///  plus the disk flush that follows it in `run_shutdown_sequence`. The old
///  hand-picked 45s covered only the 24s ladder, leaving 21s for a flush
///  that can need more — so a heavy pull followed by a slow umount put the
///  `ok` on the wire mid-flush and re-created the bug it was meant to close.
///
///  BUDGETS NEST, AND THE NESTING IS LOAD-BEARING. Each layer must be
///  strictly larger than the one inside it, or an outer layer gives up
///  mid-flush and tears the VM down with dirty pages outstanding:
///
///    guest reply cap        54s  <- this constant
///      < host ack timeout   65s  (VMManager.shutdownAckTimeout)
///        < daemon stop      90s  (Daemon's awaitVMOperation("stop"))
///          < CLI           120s
///
///  Raising this constant therefore requires raising all three host-side
///  numbers in the same change. Lowering STOP_GRACE / KILL_GRACE /
///  FLUSH_ALLOWANCE lowers it automatically and is always safe.
/// ======================================================================
/// ```
pub const SHUTDOWN_REPLY_TIMEOUT: Duration = Duration::from_secs(
    (crate::supervisor::SUPERVISED_SERVICE_COUNT as u64)
        * (crate::supervisor::STOP_GRACE.as_secs() + crate::supervisor::KILL_GRACE.as_secs())
        + GATED_PHASE_ALLOWANCE.as_secs()
        + FLUSH_ALLOWANCE.as_secs(),
);

/// What the optional (gated) services add to the shutdown budget.
///
/// One ladder, not one per service: `Supervisor::stop_gated_concurrently`
/// signals every gated service at once and then waits once, so the phase costs
/// a single grace period no matter how many of them there are. That is not an
/// optimisation for its own sake — it is what makes Kubernetes fit. Before it
/// existed the chain had about six seconds of slack:
///
/// ```text
///   guest reply cap  54s  <  host ack  65s   (with 5s for the reply itself)
/// ```
///
/// Two more services stopped sequentially at the engine's 10s+2s ladder would
/// have added 24s and blown straight through the host's ack timeout, and every
/// number in the chain lives in a different file on the other side of the
/// vsock. Concurrent + a short ladder (see `ServiceSpec::stop_ladder`) costs 5s
/// instead of 24s, so the chain still nests with a second to spare.
pub const GATED_PHASE_ALLOWANCE: Duration = Duration::from_secs(
    crate::supervisor::GATED_STOP_GRACE.as_secs() + crate::supervisor::GATED_KILL_GRACE.as_secs(),
);

/// Facts about this morbinit instance, handed to `handle_request` so it can
/// answer `info`/`ping` without reaching out to global state.
///
/// Shared by reference across every control connection thread, so all of it
/// is either immutable or an atomic.
pub struct ControlContext {
    /// Captured once at server startup; `ping`'s `uptime_ms` is measured
    /// relative to this.
    pub start: Instant,
    pub version: &'static str,
    pub kernel: String,
    /// Set once dockerd's Unix socket accepts a connection (see
    /// `proxy::spawn_ready_monitor`). Reported to the host as `docker_ready`
    /// in `info` replies so it doesn't have to scrape the console log.
    pub docker_ready: Arc<AtomicBool>,
    /// Whether `/var/lib/docker` is on the real disk rather than RAM — i.e.
    /// whether anything pulled in this boot will still be there after a
    /// restart. Decided once at boot by `disk::provision` and reported in
    /// `info` so the host can tell the user the truth about persistence
    /// instead of assuming it.
    pub docker_data_on_disk: bool,
    /// Whether dockerd is running with the userland proxy (`docker-proxy`)
    /// enabled, as decided at boot by `supervisor::default_services`.
    ///
    /// Reported in `info` because it changes what "published port" means
    /// inside the guest: with the proxy on there is a real
    /// `127.0.0.1:<port>` listener for `dial.rs` to connect to, and with it
    /// off publishing is DNAT-only and every stream dial gets
    /// ECONNREFUSED. Additive field — hosts that predate it ignore it.
    pub userland_proxy: bool,
    /// What `binfmt::setup` managed to arrange for x86-64 ELF at boot.
    ///
    /// Reported in `info` as two additive fields — `rosetta` (bool) and
    /// `binfmt_amd64` (`"rosetta"`/`"qemu"`/`"none"`) — because the host
    /// cannot see any of it: whether the Rosetta share actually mounted,
    /// whether the interpreter registered, and which interpreter won are all
    /// guest-side facts, and the difference between them is the difference
    /// between `docker run --platform linux/amd64` working and failing with
    /// `exec format error`. Two fields rather than one because they answer
    /// different questions: `rosetta` is "did the host's share work", which
    /// `morb doctor` pairs with the host-side availability check, while
    /// `binfmt_amd64` is "what is actually registered", which may be `qemu`
    /// even on a machine where Rosetta is installed but the share failed.
    pub binfmt: crate::binfmt::BinfmtStatus,
    /// What became of each host directory share, pre-encoded by
    /// `shares::encode_report` at boot: `"<path>:mounted,<path>:failed"` with
    /// the paths percent-encoded so a path containing a comma or a colon
    /// cannot be mistaken for a separator.
    ///
    /// Reported so the host can tell the user which of the directories it
    /// configured actually made it in. It cannot find out any other way, and
    /// the failure is otherwise silent: dockerd *creates* a missing bind
    /// source instead of refusing, so an unmounted share presents as an empty
    /// directory inside the container with nothing anywhere saying why.
    /// Additive field — hosts that predate it ignore it.
    pub shares: String,
    /// `true` only when the guest successfully bound its literal `/tmp` onto the
    /// mounted `/private/tmp` VirtioFS root. The source-path spelling remains owned
    /// by Docker; this is only an admission fact for a macOS `/tmp` bind source.
    /// Additive so a host can reject rather than guess when an older guest omits it.
    pub tmp_alias_mounted: bool,
    /// The Kubernetes subsystem: the enable gate, the persistence fact, and
    /// the monitor's cached cluster snapshot.
    ///
    /// Held rather than copied because `k8s` requests *mutate* it — an
    /// `enable` flips the gate the supervisor reads on its next tick — and
    /// because the snapshot has to be read fresh on every `status` rather than
    /// frozen at server startup like `kernel`.
    pub k8s: Arc<crate::k8s::K8sState>,
    /// The shutdown handshake. See `ShutdownSignal`.
    pub shutdown: Arc<ShutdownSignal>,
}

/// The kernel release string for `info` replies: `uname -r` on Linux,
/// `"unknown"` everywhere else (there is no meaningful answer on macOS,
/// since morbinit never actually serves control traffic there).
pub fn kernel_string() -> String {
    #[cfg(target_os = "linux")]
    {
        crate::sys::uname_release().unwrap_or_else(|_| "unknown".to_string())
    }
    #[cfg(not(target_os = "linux"))]
    {
        "unknown".to_string()
    }
}

/// Handle one decoded request payload, returning the JSON response payload
/// to send back and whether the caller should shut down after sending it
/// (only true for a successfully-parsed `shutdown` request).
///
/// Side effects belong to the caller: this function never touches
/// processes, disks, or power state — it only decides *what to say*, which
/// keeps it plain, portable, and easy to unit test.
pub fn handle_request(payload: &[u8], ctx: &ControlContext) -> (Vec<u8>, bool) {
    let text = match std::str::from_utf8(payload) {
        Ok(t) => t,
        Err(_) => return (error_response("payload is not valid UTF-8"), false),
    };
    let fields = match jsonlite::parse(text) {
        Ok(f) => f,
        Err(e) => return (error_response(&format!("invalid JSON: {}", e)), false),
    };
    let msg_type = match fields.get("type") {
        Some(Value::Str(s)) => s.as_str(),
        _ => return (error_response("missing string \"type\" field"), false),
    };

    match msg_type {
        "ping" => {
            let uptime_ms = ctx.start.elapsed().as_millis() as i64;
            let body = jsonlite::emit(&[
                ("type", Value::Str("pong".to_string())),
                ("uptime_ms", Value::Int(uptime_ms)),
            ]);
            (body.into_bytes(), false)
        }
        "info" => {
            let body = jsonlite::emit(&[
                ("type", Value::Str("info".to_string())),
                ("morbinit_version", Value::Str(ctx.version.to_string())),
                ("kernel", Value::Str(ctx.kernel.clone())),
                (
                    "docker_ready",
                    Value::Bool(ctx.docker_ready.load(Ordering::SeqCst)),
                ),
                (
                    "docker_data_on_disk",
                    Value::Bool(ctx.docker_data_on_disk),
                ),
                ("userland_proxy", Value::Bool(ctx.userland_proxy)),
                ("rosetta", Value::Bool(ctx.binfmt.rosetta)),
                (
                    "binfmt_amd64",
                    Value::Str(ctx.binfmt.amd64.as_str().to_string()),
                ),
                ("shares", Value::Str(ctx.shares.clone())),
                ("tmp_alias_mounted", Value::Bool(ctx.tmp_alias_mounted)),
                (
                    "share_event_bridge",
                    Value::Str(SHARE_EVENT_BRIDGE_CAPABILITY.to_string()),
                ),
                (
                    "share_event_bridge_contract_version",
                    Value::Int(SHARE_EVENT_BRIDGE_CONTRACT_VERSION),
                ),
                (
                    "disk_resize",
                    Value::Str(DISK_RESIZE_CAPABILITY.to_string()),
                ),
            ]);
            (body.into_bytes(), false)
        }
        "clock_sync" => match fields.get("unix_nanos") {
            Some(Value::Int(host_nanos)) => {
                let local_nanos = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_nanos() as i64)
                    .unwrap_or(0);
                let delta_ms = (host_nanos - local_nanos) / 1_000_000;
                // M0: we only observe and log the host/guest clock delta.
                // Actually stepping the guest clock needs CAP_SYS_TIME plus
                // a clock_settime(2) FFI wrapper and some thought about who
                // is allowed to move time backwards — that plumbing is
                // deferred to a later milestone.
                log::log(&format!(
                    "clock_sync: observed host-guest delta ~{} ms (not applied)",
                    delta_ms
                ));
                (ok_response(), false)
            }
            _ => (
                error_response("clock_sync requires an integer \"unix_nanos\" field"),
                false,
            ),
        },
        "k8s" => (handle_k8s(&fields, ctx), false),
        "shutdown" => {
            log::log("shutdown requested by host");
            (ok_response(), true)
        }
        other => (
            error_response(&format!("unknown message type: {:?}", other)),
            false,
        ),
    }
}


/// The `k8s` message family: `{"type":"k8s","action":"..."}`.
///
/// One message type with an `action` rather than four message types, because
/// the reply to three of the four is the same status object and a host that
/// enables the cluster wants to see the state it just moved to without a
/// second round trip.
///
/// Nothing here blocks on the cluster. `enable`/`disable` are a flag write and
/// an atomic store — the supervisor does the starting and stopping on its own
/// thread — and `status` reads the monitor's cached snapshot. A control
/// connection must never be parked behind a Kubernetes API server that is
/// still finding its feet.
fn handle_k8s(
    fields: &std::collections::HashMap<String, Value>,
    ctx: &ControlContext,
) -> Vec<u8> {
    let action = match fields.get("action") {
        Some(Value::Str(s)) => s.as_str(),
        _ => return error_response("k8s requires a string \"action\" field"),
    };

    match action {
        "status" => k8s_status_response(ctx, String::new()),
        "enable" | "disable" => {
            let want = action == "enable";
            match ctx.k8s.set_enabled(want) {
                Ok(()) => {
                    if want {
                        crate::k8s::prepare_host();
                    }
                    k8s_status_response(ctx, String::new())
                }
                Err(e) => error_response(&format!("could not {} kubernetes: {}", action, e)),
            }
        }
        "kubeconfig" => match crate::k8s::read_kubeconfig() {
            Ok(text) => jsonlite::emit(&[
                ("type", Value::Str("k8s_kubeconfig".to_string())),
                ("kubeconfig", Value::Str(text)),
                ("apiserver_port", Value::Int(crate::k8s::APISERVER_PORT as i64)),
            ])
            .into_bytes(),
            Err(e) => error_response(&format!(
                "no kubeconfig available yet ({}): the cluster writes it once the API \
                 server has started",
                e
            )),
        },
        other => error_response(&format!("unknown k8s action: {:?}", other)),
    }
}

/// The status object, shared by `status`, `enable` and `disable`.
fn k8s_status_response(ctx: &ControlContext, note: String) -> Vec<u8> {
    let snapshot = ctx.k8s.snapshot();
    let message = if note.is_empty() { snapshot.message } else { note };
    jsonlite::emit(&[
        ("type", Value::Str("k8s_status".to_string())),
        ("installed", Value::Bool(crate::k8s::is_installed())),
        ("enabled", Value::Bool(ctx.k8s.is_enabled())),
        // Whether an install and an enable will still be here after a restart.
        // A guest whose data root fell back to tmpfs can still run a cluster;
        // it just cannot remember that it was asked to.
        ("persistent", Value::Bool(ctx.k8s.persistent)),
        ("phase", Value::Str(snapshot.phase.as_str().to_string())),
        ("nodes", Value::Int(snapshot.nodes as i64)),
        ("nodes_ready", Value::Int(snapshot.nodes_ready as i64)),
        ("pods", Value::Int(snapshot.pods as i64)),
        ("pods_ready", Value::Int(snapshot.pods_ready as i64)),
        ("apiserver_port", Value::Int(crate::k8s::APISERVER_PORT as i64)),
        ("message", Value::Str(message)),
    ])
    .into_bytes()
}

fn ok_response() -> Vec<u8> {
    jsonlite::emit(&[("type", Value::Str("ok".to_string()))]).into_bytes()
}

fn error_response(msg: &str) -> Vec<u8> {
    jsonlite::emit(&[
        ("type", Value::Str("error".to_string())),
        ("message", Value::Str(msg.to_string())),
    ])
    .into_bytes()
}

/// Serve requests over a single already-accepted connection until it closes
/// or a `shutdown` request has been carried out. Returns `true` if shutdown
/// was requested.
///
/// The `shutdown` case is the interesting one. Rather than answering and
/// letting the supervisor clean up afterwards, this raises the request,
/// waits for the supervisor to report services stopped and storage flushed,
/// and only *then* writes the `ok` — so that frame is both the last thing
/// on the connection and an accurate statement about the guest's state.
/// See `ShutdownSignal`.
pub fn handle_connection<S: Read + Write>(conn: &mut S, ctx: &ControlContext) -> bool {
    loop {
        let payload = match read_frame(conn) {
            Ok(p) => p,
            Err(e) => {
                if e.kind() != io::ErrorKind::UnexpectedEof {
                    log::log(&format!("control connection read error: {}", e));
                }
                return false;
            }
        };
        let (response, should_shutdown) = handle_request(&payload, ctx);

        if should_shutdown {
            ctx.shutdown.request();
            if !ctx.shutdown.wait_stopped(SHUTDOWN_REPLY_TIMEOUT) {
                log::log(&format!(
                    "WARNING: services did not finish stopping within {:?} — replying \
                     ok anyway so the host is not left hanging",
                    SHUTDOWN_REPLY_TIMEOUT
                ));
            }
        }

        let write_result = write_frame(conn, &response);

        if should_shutdown {
            // Either way the supervisor must stop waiting on us: a failed
            // write means the host already hung up, which is not a reason to
            // keep the guest alive.
            ctx.shutdown.mark_replied();
        }

        if let Err(e) = write_result {
            log::log(&format!("control connection write error: {}", e));
            return false;
        }
        if should_shutdown {
            return true;
        }
    }
}

/// Maximum control connections served concurrently. The host opens one at a
/// time in normal operation; the cap exists so a stuck or hostile client
/// can't make PID 1 spawn threads without bound.
#[cfg(target_os = "linux")]
const MAX_CONTROL_CONNECTIONS: usize = 8;

/// Bind vsock 1024 and serve the control protocol from its own thread, one
/// thread per accepted connection.
///
/// The dedicated thread is the point: when the control server shared the
/// supervisor's tick loop, a single connection that stayed open (which the
/// host's control client does deliberately) blocked reaping and restarts
/// entirely, and a second dial could not be accepted until the first one
/// closed.
///
/// The shutdown request itself is raised through `ctx.shutdown` by whichever
/// connection thread receives it; the supervisor loop notices, performs the
/// actual stop sequence, and hands the reply back — see `ShutdownSignal`. The
/// accept loop keeps running throughout, so `ping` and `info` stay answerable
/// while the guest is stopping.
#[cfg(target_os = "linux")]
pub fn spawn_server(
    listener: crate::sys::VsockListener,
    ctx: Arc<ControlContext>,
) -> io::Result<()> {
    std::thread::Builder::new()
        .name("control".to_string())
        .spawn(move || accept_loop(listener, ctx))?;
    Ok(())
}

#[cfg(target_os = "linux")]
fn accept_loop(listener: crate::sys::VsockListener, ctx: Arc<ControlContext>) {
    use std::sync::atomic::AtomicUsize;

    struct ConnGuard(Arc<AtomicUsize>);
    impl Drop for ConnGuard {
        fn drop(&mut self) {
            self.0.fetch_sub(1, Ordering::SeqCst);
        }
    }

    let live = Arc::new(AtomicUsize::new(0));
    loop {
        let mut conn = match listener.accept() {
            Ok(c) => c,
            Err(e) => {
                log::log(&format!("vsock accept error: {}", e));
                std::thread::sleep(std::time::Duration::from_millis(100));
                continue;
            }
        };

        if live.load(Ordering::SeqCst) >= MAX_CONTROL_CONNECTIONS {
            log::log(&format!(
                "control server at connection cap ({}) — dropping connection",
                MAX_CONTROL_CONNECTIONS
            ));
            continue;
        }

        live.fetch_add(1, Ordering::SeqCst);
        let live_for_thread = Arc::clone(&live);
        let ctx_for_thread = Arc::clone(&ctx);
        let spawned = std::thread::Builder::new()
            .name("control-conn".to_string())
            .spawn(move || {
                let _guard = ConnGuard(live_for_thread);
                // Never powers off from this thread: `handle_connection`
                // hands the request to the supervisor loop, which stops
                // services in a defined order and then cuts the power.
                handle_connection(&mut conn, &ctx_for_thread);
            });
        if let Err(e) = spawned {
            live.fetch_sub(1, Ordering::SeqCst);
            log::log(&format!("could not spawn control connection handler: {}", e));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn test_ctx() -> ControlContext {
        ControlContext {
            start: Instant::now(),
            version: "0.1.0-m0",
            kernel: "test-kernel".to_string(),
            docker_ready: Arc::new(AtomicBool::new(false)),
            docker_data_on_disk: false,
            userland_proxy: true,
            binfmt: crate::binfmt::BinfmtStatus::disabled(),
            shares: crate::shares::encode_report(&[(
                "/Users".to_string(),
                crate::shares::MountState::Mounted,
            )]),
            tmp_alias_mounted: false,
            // Nothing is installed on the macOS test host, so this reports
            // `not-installed` — which is exactly the state a fresh guest is in
            // and the one the protocol tests want to pin.
            k8s: Arc::new(crate::k8s::K8sState::from_disk(false)),
            // `detached` so `shutdown` answers immediately: these tests are
            // about the protocol, not the handshake (which has tests of its
            // own below).
            shutdown: Arc::new(ShutdownSignal::detached()),
        }
    }

    #[test]
    fn frame_round_trips() {
        let payload = br#"{"type":"ping"}"#.to_vec();
        let mut buf = Vec::new();
        write_frame(&mut buf, &payload).unwrap();

        // MRB0 + 4-byte length + payload.
        assert_eq!(&buf[0..4], MAGIC);
        let len = u32::from_be_bytes(buf[4..8].try_into().unwrap());
        assert_eq!(len as usize, payload.len());

        let mut cursor = Cursor::new(buf);
        let decoded = read_frame(&mut cursor).unwrap();
        assert_eq!(decoded, payload);
    }

    #[test]
    fn frame_rejects_bad_magic() {
        let mut buf = Vec::new();
        buf.extend_from_slice(b"XXXX");
        buf.extend_from_slice(&0u32.to_be_bytes());
        let mut cursor = Cursor::new(buf);
        let err = read_frame(&mut cursor).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn frame_rejects_oversize_payload_without_allocating() {
        let mut buf = Vec::new();
        buf.extend_from_slice(MAGIC);
        // Claim a payload far larger than the 1 MiB cap; if this weren't
        // checked before allocation, this would try to allocate 4 GiB.
        buf.extend_from_slice(&u32::MAX.to_be_bytes());
        let mut cursor = Cursor::new(buf);
        let err = read_frame(&mut cursor).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn frame_rejects_short_read_as_eof_style_error() {
        // Magic + length header claim 10 bytes of payload, but none follow.
        let mut buf = Vec::new();
        buf.extend_from_slice(MAGIC);
        buf.extend_from_slice(&10u32.to_be_bytes());
        let mut cursor = Cursor::new(buf);
        assert!(read_frame(&mut cursor).is_err());
    }

    #[test]
    fn write_frame_refuses_oversize_payload() {
        let huge = vec![0u8; (MAX_PAYLOAD as usize) + 1];
        let mut buf = Vec::new();
        assert!(write_frame(&mut buf, &huge).is_err());
    }

    #[test]
    fn handles_ping() {
        let ctx = test_ctx();
        let (resp, shutdown) = handle_request(br#"{"type":"ping"}"#, &ctx);
        assert!(!shutdown);
        let fields = jsonlite::parse(std::str::from_utf8(&resp).unwrap()).unwrap();
        assert_eq!(fields.get("type"), Some(&Value::Str("pong".to_string())));
        assert!(matches!(fields.get("uptime_ms"), Some(Value::Int(_))));
    }

    #[test]
    fn handles_info() {
        let ctx = test_ctx();
        let (resp, shutdown) = handle_request(br#"{"type":"info"}"#, &ctx);
        assert!(!shutdown);
        let fields = jsonlite::parse(std::str::from_utf8(&resp).unwrap()).unwrap();
        assert_eq!(fields.get("type"), Some(&Value::Str("info".to_string())));
        assert_eq!(
            fields.get("morbinit_version"),
            Some(&Value::Str("0.1.0-m0".to_string()))
        );
        assert_eq!(
            fields.get("kernel"),
            Some(&Value::Str("test-kernel".to_string()))
        );
        assert_eq!(fields.get("docker_ready"), Some(&Value::Bool(false)));
        assert_eq!(fields.get("tmp_alias_mounted"), Some(&Value::Bool(false)));
        assert_eq!(
            fields.get("docker_data_on_disk"),
            Some(&Value::Bool(false))
        );
        assert_eq!(fields.get("userland_proxy"), Some(&Value::Bool(true)));
        assert_eq!(
            fields.get("share_event_bridge"),
            Some(&Value::Str("unavailable".to_string()))
        );
        assert_eq!(
            fields.get("share_event_bridge_contract_version"),
            Some(&Value::Int(1))
        );
        assert_eq!(
            fields.get("disk_resize"),
            Some(&Value::Str("unavailable".to_string()))
        );
    }

    #[test]
    fn info_reports_a_disabled_userland_proxy() {
        // The host needs this to explain a published port that refuses every
        // connection: without the userland proxy there is no loopback
        // listener for the stream dialer to reach, so `-p` is DNAT-only and
        // the dial can only ever fail. See `dial::dial_error_reason`.
        let mut ctx = test_ctx();
        ctx.userland_proxy = false;
        let (resp, _) = handle_request(br#"{"type":"info"}"#, &ctx);
        let fields = jsonlite::parse(std::str::from_utf8(&resp).unwrap()).unwrap();
        assert_eq!(fields.get("userland_proxy"), Some(&Value::Bool(false)));
        // Additive only: the pre-existing fields are untouched.
        assert_eq!(fields.get("type"), Some(&Value::Str("info".to_string())));
        assert!(fields.contains_key("docker_ready"));
        assert!(fields.contains_key("docker_data_on_disk"));
        assert!(fields.contains_key("morbinit_version"));
        assert!(fields.contains_key("kernel"));
        assert!(fields.contains_key("disk_resize"));
    }

    #[test]
    fn info_reports_no_amd64_emulation_by_default() {
        let ctx = test_ctx();
        let (resp, _) = handle_request(br#"{"type":"info"}"#, &ctx);
        let fields = jsonlite::parse(std::str::from_utf8(&resp).unwrap()).unwrap();
        assert_eq!(fields.get("rosetta"), Some(&Value::Bool(false)));
        assert_eq!(
            fields.get("binfmt_amd64"),
            Some(&Value::Str("none".to_string()))
        );
    }

    #[test]
    fn info_reports_rosetta_when_the_share_registered() {
        let mut ctx = test_ctx();
        ctx.binfmt = crate::binfmt::BinfmtStatus {
            rosetta: true,
            amd64: crate::binfmt::Amd64Binfmt::Rosetta,
        };
        let (resp, _) = handle_request(br#"{"type":"info"}"#, &ctx);
        let fields = jsonlite::parse(std::str::from_utf8(&resp).unwrap()).unwrap();
        assert_eq!(fields.get("rosetta"), Some(&Value::Bool(true)));
        assert_eq!(
            fields.get("binfmt_amd64"),
            Some(&Value::Str("rosetta".to_string()))
        );
        // Additive only.
        assert!(fields.contains_key("userland_proxy"));
        assert!(fields.contains_key("docker_data_on_disk"));
    }

    #[test]
    fn info_reports_qemu_without_claiming_rosetta() {
        // The two fields are independent: falling back to qemu on a machine
        // with no Rosetta share must not report `rosetta: true`, or `morb
        // doctor` will tell the user their share is fine when it is not.
        let mut ctx = test_ctx();
        ctx.binfmt = crate::binfmt::BinfmtStatus {
            rosetta: false,
            amd64: crate::binfmt::Amd64Binfmt::Qemu,
        };
        let (resp, _) = handle_request(br#"{"type":"info"}"#, &ctx);
        let fields = jsonlite::parse(std::str::from_utf8(&resp).unwrap()).unwrap();
        assert_eq!(fields.get("rosetta"), Some(&Value::Bool(false)));
        assert_eq!(
            fields.get("binfmt_amd64"),
            Some(&Value::Str("qemu".to_string()))
        );
    }

    #[test]
    fn info_reports_docker_ready_once_the_flag_is_raised() {
        let ctx = test_ctx();
        ctx.docker_ready.store(true, Ordering::SeqCst);
        let (resp, _) = handle_request(br#"{"type":"info"}"#, &ctx);
        let fields = jsonlite::parse(std::str::from_utf8(&resp).unwrap()).unwrap();
        assert_eq!(fields.get("docker_ready"), Some(&Value::Bool(true)));
    }

    #[test]
    fn info_reports_persistent_storage_when_the_data_root_is_on_disk() {
        // The host uses this to tell the user whether images will survive a
        // restart, so it must reflect what `disk::provision` actually
        // achieved rather than what it attempted.
        let mut ctx = test_ctx();
        ctx.docker_data_on_disk = true;
        let (resp, _) = handle_request(br#"{"type":"info"}"#, &ctx);
        let fields = jsonlite::parse(std::str::from_utf8(&resp).unwrap()).unwrap();
        assert_eq!(fields.get("docker_data_on_disk"), Some(&Value::Bool(true)));
    }

    #[test]
    fn handles_clock_sync() {
        let ctx = test_ctx();
        let (resp, shutdown) =
            handle_request(br#"{"type":"clock_sync","unix_nanos":1730000000000000000}"#, &ctx);
        assert!(!shutdown);
        let fields = jsonlite::parse(std::str::from_utf8(&resp).unwrap()).unwrap();
        assert_eq!(fields.get("type"), Some(&Value::Str("ok".to_string())));
    }

    #[test]
    fn handles_shutdown() {
        let ctx = test_ctx();
        let (resp, shutdown) = handle_request(br#"{"type":"shutdown"}"#, &ctx);
        assert!(shutdown);
        let fields = jsonlite::parse(std::str::from_utf8(&resp).unwrap()).unwrap();
        assert_eq!(fields.get("type"), Some(&Value::Str("ok".to_string())));
    }

    #[test]
    fn unknown_type_is_an_error_response() {
        let ctx = test_ctx();
        let (resp, shutdown) = handle_request(br#"{"type":"frobnicate"}"#, &ctx);
        assert!(!shutdown);
        let fields = jsonlite::parse(std::str::from_utf8(&resp).unwrap()).unwrap();
        assert_eq!(fields.get("type"), Some(&Value::Str("error".to_string())));
        assert!(matches!(fields.get("message"), Some(Value::Str(_))));
    }

    #[test]
    fn malformed_json_is_an_error_response_not_a_panic() {
        let ctx = test_ctx();
        let (resp, shutdown) = handle_request(b"not json at all", &ctx);
        assert!(!shutdown);
        let fields = jsonlite::parse(std::str::from_utf8(&resp).unwrap()).unwrap();
        assert_eq!(fields.get("type"), Some(&Value::Str("error".to_string())));
    }

    /// A tiny in-memory duplex stream so `handle_connection` (which needs
    /// `Read + Write` on the *same* object) can be exercised without a
    /// real socket.
    struct DuplexBuf {
        in_data: Cursor<Vec<u8>>,
        out_data: Vec<u8>,
    }

    impl Read for DuplexBuf {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            self.in_data.read(buf)
        }
    }

    impl Write for DuplexBuf {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            self.out_data.write(buf)
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn handle_connection_processes_frames_until_shutdown() {
        let ctx = test_ctx();
        let mut input = Vec::new();
        write_frame(&mut input, br#"{"type":"ping"}"#).unwrap();
        write_frame(&mut input, br#"{"type":"shutdown"}"#).unwrap();

        let mut duplex = DuplexBuf {
            in_data: Cursor::new(input),
            out_data: Vec::new(),
        };

        let shutdown_requested = handle_connection(&mut duplex, &ctx);
        assert!(shutdown_requested);

        // Two responses should have been written: pong, then ok.
        let mut out = Cursor::new(duplex.out_data);
        let first = read_frame(&mut out).unwrap();
        let first_fields = jsonlite::parse(std::str::from_utf8(&first).unwrap()).unwrap();
        assert_eq!(
            first_fields.get("type"),
            Some(&Value::Str("pong".to_string()))
        );

        let second = read_frame(&mut out).unwrap();
        let second_fields = jsonlite::parse(std::str::from_utf8(&second).unwrap()).unwrap();
        assert_eq!(
            second_fields.get("type"),
            Some(&Value::Str("ok".to_string()))
        );
    }

    // ---- the shutdown handshake -------------------------------------------

    #[test]
    fn shutdown_ok_is_the_last_frame_and_nothing_follows_it() {
        // Frames after `shutdown` must not be served: the guest is on its way
        // down, and answering them would put bytes on the wire after the
        // frame the host treats as final.
        let ctx = test_ctx();
        let mut input = Vec::new();
        write_frame(&mut input, br#"{"type":"shutdown"}"#).unwrap();
        write_frame(&mut input, br#"{"type":"ping"}"#).unwrap();

        let mut duplex = DuplexBuf {
            in_data: Cursor::new(input),
            out_data: Vec::new(),
        };
        assert!(handle_connection(&mut duplex, &ctx));

        let mut out = Cursor::new(duplex.out_data);
        let first = read_frame(&mut out).unwrap();
        let fields = jsonlite::parse(std::str::from_utf8(&first).unwrap()).unwrap();
        assert_eq!(fields.get("type"), Some(&Value::Str("ok".to_string())));
        assert!(
            read_frame(&mut out).is_err(),
            "the ok frame must be the last one written"
        );
    }

    #[test]
    fn shutdown_reply_waits_for_the_supervisor_to_report_services_stopped() {
        // The regression: morbinit used to answer `ok` immediately and stop
        // services afterwards, so the host could power the VM off while the
        // layer store was still being flushed. The reply must come *after*.
        let ctx = Arc::new(ControlContext {
            start: Instant::now(),
            version: "0.1.0-m0",
            kernel: "test-kernel".to_string(),
            docker_ready: Arc::new(AtomicBool::new(false)),
            docker_data_on_disk: true,
            userland_proxy: true,
            binfmt: crate::binfmt::BinfmtStatus::disabled(),
            shares: String::new(),
            tmp_alias_mounted: false,
            k8s: Arc::new(crate::k8s::K8sState::from_disk(true)),
            shutdown: Arc::new(ShutdownSignal::new()),
        });

        let mut input = Vec::new();
        write_frame(&mut input, br#"{"type":"shutdown"}"#).unwrap();
        let mut duplex = DuplexBuf {
            in_data: Cursor::new(input),
            out_data: Vec::new(),
        };

        let ctx_for_thread = Arc::clone(&ctx);
        let handle =
            std::thread::spawn(move || handle_connection(&mut duplex, &ctx_for_thread));

        // Stand in for the supervisor: wait for the request to be raised,
        // "stop services", then release the reply.
        let deadline = Instant::now() + Duration::from_secs(5);
        while !ctx.shutdown.is_requested() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(ctx.shutdown.is_requested(), "shutdown was never requested");
        assert!(
            !ctx.shutdown.wait_replied(Duration::from_millis(100)),
            "the ok frame was written before services were reported stopped"
        );

        ctx.shutdown.mark_stopped();
        assert!(
            ctx.shutdown.wait_replied(Duration::from_secs(5)),
            "the ok frame was never written after services stopped"
        );
        assert!(handle.join().unwrap());
    }

    #[test]
    fn a_detached_signal_answers_shutdown_without_waiting() {
        // `--serve-control` has no supervisor to stop anything, so a
        // shutdown there must not sit out the full reply timeout.
        let signal = ShutdownSignal::detached();
        let before = Instant::now();
        assert!(signal.wait_stopped(SHUTDOWN_REPLY_TIMEOUT));
        assert!(before.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn latches_are_one_way_and_start_low() {
        let signal = ShutdownSignal::new();
        assert!(!signal.is_requested());
        assert!(!signal.wait_stopped(Duration::from_millis(1)));
        assert!(!signal.wait_replied(Duration::from_millis(1)));

        signal.request();
        signal.mark_stopped();
        signal.mark_replied();

        assert!(signal.is_requested());
        assert!(signal.wait_stopped(Duration::ZERO));
        assert!(signal.wait_replied(Duration::ZERO));

        // Raising again changes nothing.
        signal.request();
        assert!(signal.is_requested());
    }

    #[test]
    fn the_reply_budget_covers_the_stop_ladder_and_the_flush_that_follows_it() {
        // The regression this guards: the budget used to be a hand-picked 45s
        // that only covered the service-stop ladder. `run_shutdown_sequence`
        // also flushes `/var/lib/docker` before releasing the reply, and a
        // umount after a heavy pull can take tens of seconds — so the reply
        // would time out and go out *during* the flush, which is exactly the
        // promise-about-the-future the handshake exists to prevent.
        let ladder = crate::supervisor::STOP_GRACE + crate::supervisor::KILL_GRACE;
        let worst_case = ladder * (crate::supervisor::SUPERVISED_SERVICE_COUNT as u32);
        assert_eq!(worst_case, Duration::from_secs(24));
        // ...plus the optional (gated) services, which are signalled together
        // and waited on once, so they contribute one 4s+1s ladder in total
        // rather than one per service. See `GATED_PHASE_ALLOWANCE`.
        assert_eq!(GATED_PHASE_ALLOWANCE, Duration::from_secs(5));
        assert_eq!(
            SHUTDOWN_REPLY_TIMEOUT,
            worst_case + GATED_PHASE_ALLOWANCE + FLUSH_ALLOWANCE
        );
        assert_eq!(SHUTDOWN_REPLY_TIMEOUT, Duration::from_secs(59));
    }

    #[test]
    fn the_reply_budget_leaves_room_for_the_host_ack_timeout_above_it() {
        // Budgets nest: guest reply cap < host ack timeout < daemon stop
        // budget < CLI. This end asserts only its own side of the contract —
        // that the guest cap stays comfortably under the smallest host ack
        // timeout the nesting tolerates — because the host constants live in
        // mac/ and cannot be imported here.
        const HOST_ACK_TIMEOUT: Duration = Duration::from_secs(65);
        assert!(
            SHUTDOWN_REPLY_TIMEOUT < HOST_ACK_TIMEOUT,
            "guest cap {:?} must stay below the host ack timeout {:?}",
            SHUTDOWN_REPLY_TIMEOUT,
            HOST_ACK_TIMEOUT
        );
        // And the gap must be large enough for the reply itself to make it
        // out: `main::REPLY_FLUSH_TIMEOUT` is 5s on top of this wait.
        assert!(SHUTDOWN_REPLY_TIMEOUT + Duration::from_secs(5) <= HOST_ACK_TIMEOUT);
    }

    #[test]
    fn a_wedged_supervisor_still_gets_an_answer_out() {
        // If the stop sequence never completes we must still reply rather
        // than leave the host's control connection open forever. Uses the
        // wait directly with a short timeout — the production path uses
        // SHUTDOWN_REPLY_TIMEOUT.
        let signal = ShutdownSignal::new();
        let before = Instant::now();
        assert!(!signal.wait_stopped(Duration::from_millis(60)));
        assert!(before.elapsed() >= Duration::from_millis(50));
    }
}
