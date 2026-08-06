// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Dispatch
import Foundation
import Virtualization

/// Lifecycle state of the Morbstack virtual machine.
public enum VMState: Equatable, Sendable, CustomStringConvertible {
    /// No VM object exists and no saved state is being used.
    case stopped
    /// A VM is being created, booted or restored.
    case starting
    /// The guest is executing.
    case running
    /// A suspend is in flight (pause + save).
    case pausing
    /// The VM has been saved to `vmstate.bin` and its memory returned to the host.
    case suspended
    /// A shutdown is in flight.
    case stopping
    /// The last operation failed; the message is safe to show to the user.
    case error(String)

    public var description: String {
        switch self {
        case .stopped: return "stopped"
        case .starting: return "starting"
        case .running: return "running"
        case .pausing: return "pausing"
        case .suspended: return "suspended"
        case .stopping: return "stopping"
        case .error(let message): return "error: \(message)"
        }
    }

    /// A short machine-readable token for the control protocol.
    public var token: String {
        switch self {
        case .stopped: return "stopped"
        case .starting: return "starting"
        case .running: return "running"
        case .pausing: return "pausing"
        case .suspended: return "suspended"
        case .stopping: return "stopping"
        case .error: return "error"
        }
    }

    /// `true` while an operation is in flight and the state will change on its own.
    ///
    /// Callers that want a usable VM must *wait* in these states rather than fail:
    /// a `docker` client that lands mid-suspend should ride the transition out, not
    /// come back with a 502.
    public var isTransitional: Bool {
        switch self {
        case .starting, .pausing, .stopping: return true
        case .stopped, .running, .suspended, .error: return false
        }
    }
}

/// A completion handler that can be fired from several escape paths but runs once.
///
/// Every asynchronous entry point in ``VMManager`` hands its caller's completion to
/// one of these before doing anything else. Virtualization.framework's handlers are
/// full of `[weak self]` captures, and the natural `guard let self else { return }`
/// silently drops the completion — the caller then waits out its entire timeout for a
/// reply that can never arrive. Capturing the handler here instead of on `self` means
/// it survives the manager's deallocation and still reports a real error.
final class CompletionOnce {

    private let lock = NSLock()
    private var handler: ((Result<Void, Error>) -> Void)?

    init(_ handler: @escaping (Result<Void, Error>) -> Void) {
        self.handler = handler
    }

    deinit {
        // A handler still present at deallocation means some path forgot to answer.
        // Answering late beats hanging the caller until its timeout expires.
        fire(.failure(MorbError.vm("the VM operation was abandoned before it completed")))
    }

    /// Delivers `result` if nothing has been delivered yet.
    func fire(_ result: Result<Void, Error>) {
        lock.lock()
        let handler = self.handler
        self.handler = nil
        lock.unlock()
        handler?(result)
    }

    /// The failure used when `self` has already gone away inside a VZ callback.
    static let managerGone = MorbError.vm("the VM manager was released before the operation finished")
}

/// Owns the single Morbstack VM and every call into Virtualization.framework.
///
/// `VZVirtualMachine` has strict queue affinity: it must be created and driven from
/// the queue handed to its initialiser. `VMManager` therefore funnels *all* VZ work
/// onto one private serial queue and exposes a completion-handler API that is safe
/// to call from anywhere.
public final class VMManager: NSObject, VZVirtualMachineDelegate {

    /// How long a fresh boot has to reach "dockerd is serving".
    ///
    /// This covers the whole bring-up, not just `morbinit`'s first `pong`: the guest
    /// still has to mount and possibly *format* `/dev/vda` before dockerd starts, so
    /// the budget is generous compared with the ~1.4 s a warm boot actually takes.
    public static let controlReadyTimeout: TimeInterval = 40

    /// How long the guest gets to acknowledge a clean shutdown.
    ///
    /// `morbinit` stops the container runtime and `sync`s the Docker data disk
    /// *before* it replies, so this is a data-durability deadline rather than a
    /// round-trip one. The guest side sends `ok` as its *last* frame, after
    /// SIGTERM → 10 s grace → SIGKILL plus unmount/sync — ~25 s in the normal
    /// case, capped guest-side at 54 s. Anything shorter than that cap hard-stops
    /// the VM mid-flush and reintroduces the data-loss bug this deadline exists
    /// to prevent, so we sit above it with room for the reply to reach the wire.
    ///
    /// THIS NUMBER MIRRORS A GUEST CONSTANT. `control::SHUTDOWN_REPLY_TIMEOUT` in
    /// `guest/morbinit/src/control.rs` is *derived* — it computes
    /// `SUPERVISED_SERVICE_COUNT * (STOP_GRACE + KILL_GRACE) + FLUSH_ALLOWANCE`
    /// = 2 * (10 s + 2 s) + 30 s = 54 s — and the guest test
    /// `the_reply_budget_leaves_room_for_the_host_ack_timeout_above_it` hardcodes
    /// *this* value as its `HOST_ACK_TIMEOUT`. The two move together or the guest
    /// suite fails. The margin is not arbitrary either: after the guest's 54 s cap
    /// expires it still needs `main.rs`'s `REPLY_FLUSH_TIMEOUT` (5 s) to get the
    /// `ok` onto the socket, so the host must wait at least 54 + 5 = 59 s or it
    /// walks away from a reply that was about to arrive. 65 s leaves 6 s of slack
    /// for vsock connect and scheduling.
    ///
    ///     guest reply cap (54 s) + reply flush (5 s) = 59 s ≤ this (65 s)
    public static let shutdownAckTimeout: TimeInterval = 65

    /// How long to wait for the guest to actually power off after acknowledging.
    public static let guestPowerOffTimeout: TimeInterval = 5

    /// Interval between guest-control probes while waiting for boot.
    private static let controlProbeInterval: useconds_t = 250_000

    /// The serial queue that owns the `VZVirtualMachine`.
    private let queue = DispatchQueue(label: "dev.morbstack.vm", qos: .userInitiated)

    /// Off-queue workers for the blocking guest-control handshake.
    ///
    /// Concurrent on purpose: a probe from a superseded bring-up can be parked in a
    /// three-second vsock connect, and on a serial queue that would delay the probe
    /// that actually matters by the full remaining timeout.
    private let probeQueue = DispatchQueue(
        label: "dev.morbstack.vm.probe", qos: .userInitiated, attributes: .concurrent)

    private let config: MorbConfig
    private let log: MorbLog

    /// A successful disk grow updates this override so a same-daemon reset cannot
    /// recreate a fresh image at the pre-grow capacity. Other boot settings remain
    /// the immutable daemon-start configuration and still apply on restart.
    private let diskCapacityLock = NSLock()
    private var configuredDiskSizeGiB: Int

    private var virtualMachine: VZVirtualMachine?
    /// Guest-initiated vsock handlers, re-installed on every VM this manager
    /// creates. See ``setGuestInitiatedConnectionHandler(port:handler:)``.
    private var guestListenerHandlers: [UInt32: (Int32) -> Void] = [:]
    /// The live listeners (and their delegates, which VZ does not retain) for
    /// the *current* VM object. Replaced wholesale when a new VM is built.
    private var guestListeners: [UInt32: (VZVirtioSocketListener, GuestVsockAcceptDelegate)] = [:]
    private var consoleHandle: FileHandle?

    private let stateLock = NSLock()
    private var _state: VMState = .stopped

    /// Waiters registered by ``ensureRunning(timeout:completion:)``.
    private var runWaiters: [RunWaiter] = []

    /// `true` once the guest is *usable* — `morbinit` answered **and** it reported
    /// `docker_ready`. Queue-confined; this is what ``ensureRunning`` gates on.
    private var controlReady = false
    private var controlProbeInFlight = false
    private var bringUpStartedAt: Date?

    /// Prevents socket activation from admitting Docker work between the host RAW
    /// growth and the durable guest filesystem proof.
    private var diskGrowthInFlight = false

    /// Bumped whenever a probe in flight is superseded. Guarded by ``stateLock`` so
    /// the probe worker, which does not run on ``queue``, can read it safely.
    private var _probeGeneration = 0

    /// Set when a client arrives while a suspend is in flight. Queue-confined.
    private var suspendCancelRequested = false

    /// `true` between the start of a stop and its completion. Queue-confined.
    private var stopInFlight = false

    /// Everyone waiting on the stop described by ``stopInFlight``. Queue-confined.
    ///
    /// A second `morb stop` arriving mid-shutdown used to start a *second* shutdown
    /// sequence. The first one owns the `VZVirtualMachine`, so the second immediately
    /// falls down a path that answers nothing and lets its ``CompletionOnce`` go out
    /// of scope unfired — which the deinit then reports as "the VM operation was
    /// abandoned before it completed", an alarming message for the entirely ordinary
    /// act of pressing Ctrl-C twice. Both callers want the same event, so both wait
    /// for it.
    private var stopWaiters: [CompletionOnce] = []

    /// One-shot callbacks fired when the guest powers itself off. Queue-confined.
    private var guestStopObservers: [GuestStopObserver] = []

    /// `true` once this host has proved it cannot restore what it saves.
    private let saveRestoreLock = NSLock()
    private var _saveRestoreBroken = false

    /// Invoked (on the VM queue) whenever the state changes. Set before starting.
    public var onStateChange: ((VMState) -> Void)?

    /// Creates a manager for `config`. No VM is created until ``start(completion:)``.
    public init(config: MorbConfig, log: MorbLog) {
        self.config = config
        self.log = log
        self.configuredDiskSizeGiB = max(1, config.diskSizeGiB)
        super.init()

        _saveRestoreBroken = FileManager.default.fileExists(atPath: MorbPaths.saveRestoreUnsupported.path)
        if _saveRestoreBroken {
            log.info(
                "suspend-to-disk disabled: a previous restore failed "
                    + "(delete \(MorbPaths.saveRestoreUnsupported.path) to try again)")
            // Any state blob left over is unusable; do not start life pretending to
            // be suspended when the only possible outcome is a failed restore.
            discardSavedState()
        }
        if FileManager.default.fileExists(atPath: MorbPaths.vmState.path) {
            _state = .suspended
        }
    }

    /// The guest's fixed MAC address. `02:` marks it locally administered and
    /// unicast (so it can never collide with a real vendor address); `4d:52:42`
    /// is "MRB". See `buildConfiguration()` for why this must not be random.
    static let guestMACAddress = "02:4d:52:42:00:01"

    /// `true` when a restore has failed on this host and suspend degrades to a stop.
    public var isSaveRestoreBroken: Bool {
        saveRestoreLock.lock()
        defer { saveRestoreLock.unlock() }
        return _saveRestoreBroken
    }

    /// Records that restore does not work here, so nothing tries to save again.
    private func markSaveRestoreBroken() {
        saveRestoreLock.lock()
        let alreadyKnown = _saveRestoreBroken
        _saveRestoreBroken = true
        saveRestoreLock.unlock()
        guard !alreadyKnown else { return }
        let url = MorbPaths.saveRestoreUnsupported
        let note = """
            Virtualization.framework accepted saveMachineStateTo on this host and then
            refused to restore the result, so Morbstack now stops the guest instead of
            suspending it. Delete this file to make it try again.

            recorded by morbstack \(MorbVersion.string) at \(Date())

            """
        try? note.write(to: url, atomically: true, encoding: .utf8)
        log.warn(
            "suspend-to-disk disabled on this host; recorded in \(url.path). "
                + "Idle and shutdown will stop the guest instead of saving it.")
    }

    /// Removes the saved-state blob, if any.
    private func discardSavedState() {
        try? FileManager.default.removeItem(at: MorbPaths.vmState)
    }

    // MARK: - Observable state

    /// The current lifecycle state. Safe to read from any thread.
    public var state: VMState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _state
    }

    /// `true` when a usable `vmstate.bin` blob is present on disk.
    public var hasSavedState: Bool {
        guard !isSaveRestoreBroken else { return false }
        return FileManager.default.fileExists(atPath: MorbPaths.vmState.path)
    }

    /// `true` when `morbinit` answered its control channel on the current boot.
    ///
    /// Note this is *weaker* than ``isDockerReady``: the guest can be answering MRB0
    /// several seconds before dockerd binds its socket.
    public var isGuestControlReady: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _guestPingedSnapshot
    }

    /// `true` when the guest reported `docker_ready` on the current boot.
    public var isDockerReady: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _controlReadySnapshot
    }

    /// Whether the guest put `/var/lib/docker` on the virtio disk rather than a
    /// tmpfs, or `nil` while the guest has not said (older guest, or not booted).
    public var dockerDataOnDisk: Bool? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _dockerDataOnDisk
    }

    /// The `morbinit` version the current boot reported, or `nil` while no guest
    /// has answered `info`. Compare with ``MorbVersion/minimumCompatibleMorbinit``.
    public var guestMorbinitVersion: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _guestMorbinitVersion
    }

    /// What the running guest reports it actually launched dockerd with, for
    /// each of the three proxy fields (UX-18). Empty string means "dockerd
    /// has no proxy of this kind this boot"; `nil` means no guest has
    /// answered `info` yet, or the guest predates the field — those two
    /// states must not be conflated, since the first is a real "off" and the
    /// second is "unknown".
    public var guestHTTPProxy: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _guestHTTPProxy
    }
    public var guestHTTPSProxy: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _guestHTTPSProxy
    }
    public var guestNoProxy: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _guestNoProxy
    }

    /// Mirror of ``controlReady`` for cross-thread reads, guarded by ``stateLock``.
    private var _controlReadySnapshot = false

    /// `true` once a `ping` succeeded on this boot, even if dockerd is still starting.
    private var _guestPingedSnapshot = false

    /// Last `docker_data_on_disk` value reported by the guest.
    private var _dockerDataOnDisk: Bool?

    /// Last `morbinit_version` reported by the guest's `info` reply.
    ///
    /// This is the field `docs/protocol.md` nominates as *the* compatibility probe
    /// for the control channel, so it must not stay write-only: the boot probe
    /// records it once per boot and compares it against
    /// ``MorbVersion/minimumCompatibleMorbinit`` (see `beginControlProbe`), and
    /// `morb status` / `morb doctor` surface it. `nil` means the guest has not
    /// answered `info` on this boot — an initramfs old enough to omit the field
    /// predates every release that shipped one.
    private var _guestMorbinitVersion: String?

    /// Last `http_proxy`/`https_proxy`/`no_proxy` values reported by the guest's
    /// `info` reply — what dockerd was actually launched with, not merely what
    /// the host asked for. See ``guestHTTPProxy`` for the empty-string-vs-`nil`
    /// convention.
    private var _guestHTTPProxy: String?
    private var _guestHTTPSProxy: String?
    private var _guestNoProxy: String?

    /// Last `rosetta` value reported by the guest: the share mounted *and* an
    /// interpreter was registered from it.
    private var _guestRosetta: Bool?

    /// Last `binfmt_amd64` value reported by the guest — `rosetta`, `qemu`, or
    /// `none`.
    private var _guestBinfmtAmd64: String?

    /// Last `share_event_bridge` capability reported by the guest. `nil` means an
    /// older/stopped guest did not answer; `"unavailable"` is the current guest's
    /// explicit statement that it cannot inject host file notifications into inotify.
    private var _guestShareEventBridge: String?

    /// Reserved schema version observed with the guest's future share-event
    /// capability. A matching number does not by itself create a receiver.
    private var _guestShareEventBridgeContractVersion: Int?

    /// Last `disk_resize` capability reported by the guest. `nil` means an
    /// older/stopped guest has not said; `"unavailable"` is an explicit no-mutation
    /// boundary, not a transient resize failure.
    private var _guestDiskResize: String?

    /// Capability most recently observed during this daemon lifetime. A stopped VM
    /// cannot answer `info`, so Settings may use this only as a preflight hint; the
    /// transaction asks the freshly booted guest to prove `ready` again.
    private var _lastGuestDiskResize: String?

    /// Whether the running guest has Rosetta working, or `nil` if no guest has
    /// said (not booted, or an initramfs older than the field).
    ///
    /// Deliberately distinct from "the host has Rosetta installed": the share is
    /// a device attached when the VM is *configured*, so installing Rosetta or
    /// flipping `rosetta = true` does nothing for an already-running VM. Keeping
    /// the two separate is what lets `morb rosetta` say "restart the VM" instead
    /// of contradicting `morb doctor`.
    public var guestRosetta: Bool? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _guestRosetta
    }

    /// Which x86-64 interpreter the running guest registered, or `nil` if no
    /// guest has said. `"qemu"` with ``guestRosetta`` false is a working amd64
    /// setup, not a failure.
    public var guestBinfmtAmd64: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _guestBinfmtAmd64
    }

    /// The current guest's future file-event delivery capability, when it has reported
    /// one. This is diagnostic only and never creates an FSEvents subscription.
    public var guestShareEventBridge: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _guestShareEventBridge
    }

    /// The current guest's reported share-event schema version. Absence does not
    /// default to the host's version because an older guest is not an implicit match.
    public var guestShareEventBridgeContractVersion: Int? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _guestShareEventBridgeContractVersion
    }

    /// The current guest's disk-resize capability, when it has reported one.
    /// This is read-only diagnostic state; it never changes the attached disk.
    public var guestDiskResize: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _guestDiskResize
    }

    /// The last guest protocol advertisement observed by this daemon.
    public var lastGuestDiskResize: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _lastGuestDiskResize
    }

    /// The VirtioFS shares handed to the current (or most recent) configuration.
    private var _shares: [MorbDirectoryShare] = []

    /// What the guest said it did with each share, keyed by host path. Empty until
    /// the boot probe's first `info` reply.
    private var _guestShareStates: [String: MorbShares.GuestMountState] = [:]

    /// Whether this guest explicitly confirmed that its literal `/tmp` aliases the
    /// mounted `/private/tmp` share. `nil` is an older guest and must not admit a
    /// bare macOS `/tmp` bind source.
    private var _guestTmpAliasMounted: Bool?

    /// The one coherent read of the live VirtioFS contract used to admit a Docker
    /// bind mount. A share plan and its guest report must come from the same state
    /// lock acquisition: reading them separately can otherwise pair a freshly
    /// planned root with a previous VM's `mounted` result while the VM is being
    /// reconfigured.
    public struct ShareMountSnapshot: Sendable {
        public let shares: [MorbDirectoryShare]
        public let guestShareStates: [String: MorbShares.GuestMountState]
        public let guestTmpAliasMounted: Bool?

        public init(
            shares: [MorbDirectoryShare],
            guestShareStates: [String: MorbShares.GuestMountState],
            guestTmpAliasMounted: Bool?
        ) {
            self.shares = shares
            self.guestShareStates = guestShareStates
            self.guestTmpAliasMounted = guestTmpAliasMounted
        }
    }

    /// The host directories shared with the guest, as configured. Safe from any thread.
    ///
    /// Populated when a configuration is built, so it is empty before the first boot
    /// attempt; ``sharePlan()`` computes the same list without one.
    public var shares: [MorbDirectoryShare] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _shares
    }

    /// The guest's report on each share, keyed by host path. Safe from any thread.
    public var guestShareStates: [String: MorbShares.GuestMountState] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _guestShareStates
    }

    /// Atomically snapshots the attached share roots and the running guest's mount
    /// report. Callers that make an admission decision must use this rather than
    /// independently reading ``shares`` and ``guestShareStates``.
    public var shareMountSnapshot: ShareMountSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return ShareMountSnapshot(
            shares: _shares,
            guestShareStates: _guestShareStates,
            guestTmpAliasMounted: _guestTmpAliasMounted)
    }

    /// The sharing plan for the current configuration, without building a VM.
    public func sharePlan() throws -> MorbShares.Plan { try config.sharePlan() }

    /// Plans the shares and records them for ``shares``. Runs on ``queue``.
    private func planShares() throws -> MorbShares.Plan {
        let plan = try config.sharePlan()
        stateLock.lock()
        _shares = plan.shares
        stateLock.unlock()
        return plan
    }

    /// Replaces every `morb.proxy=<value>` token's value with `<redacted>`,
    /// for logging a boot command line that may otherwise carry a proxy URL's
    /// embedded basic-auth credentials. Pure and static so it can be tested
    /// without booting anything.
    static func redactingProxyTokens(_ cmdline: String) -> String {
        cmdline.split(separator: " ", omittingEmptySubsequences: false)
            .map { token -> String in
                token.hasPrefix(MorbGuestProxy.cmdlineKey + "=")
                    ? "\(MorbGuestProxy.cmdlineKey)=<redacted>"
                    : String(token)
            }
            .joined(separator: " ")
    }

    /// Records the guest's share report. Safe from any thread.
    private func noteGuestShares(_ states: [String: MorbShares.GuestMountState]) {
        stateLock.lock()
        _guestShareStates = states
        stateLock.unlock()
    }

    /// Records the guest's `/tmp`-alias outcome for the running boot. Safe from any
    /// thread; absence is kept distinct from a reported failure.
    ///
    /// This and the other `ifCurrent` note functions are written from the probe
    /// worker while it holds no queue confinement, so each write checks the probe
    /// generation *inside* the state lock: a probe superseded mid-exchange must not
    /// deposit the previous boot's answers into snapshots the next boot just reset
    /// (see `invalidateControlReadiness`, which bumps the generation before wiping).
    private func noteGuestTmpAliasMounted(_ mounted: Bool?, ifCurrent generation: Int) {
        stateLock.lock()
        if _probeGeneration == generation { _guestTmpAliasMounted = mounted }
        stateLock.unlock()
    }

    /// The current probe generation. Safe to read from any thread.
    private var probeGeneration: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _probeGeneration
    }

    /// Invalidates every probe in flight and returns the new generation.
    @discardableResult
    private func bumpProbeGeneration() -> Int {
        stateLock.lock()
        _probeGeneration &+= 1
        let generation = _probeGeneration
        stateLock.unlock()
        return generation
    }

    private func setState(_ newState: VMState) {
        stateLock.lock()
        let changed = _state != newState
        _state = newState
        stateLock.unlock()
        guard changed else { return }
        log.info("vm state -> \(newState.description)")
        onStateChange?(newState)
    }

    /// Records whether the guest is usable (dockerd serving). Must run on ``queue``.
    private func setControlReady(_ ready: Bool) {
        controlReady = ready
        stateLock.lock()
        _controlReadySnapshot = ready
        if !ready {
            // Everything learned from the guest belongs to the boot that just ended.
            _guestPingedSnapshot = false
            _dockerDataOnDisk = nil
            _guestMorbinitVersion = nil
            _guestShareStates = [:]
            _guestTmpAliasMounted = nil
            _guestRosetta = nil
            _guestBinfmtAmd64 = nil
            _guestShareEventBridge = nil
            _guestShareEventBridgeContractVersion = nil
            _guestDiskResize = nil
            _guestHTTPProxy = nil
            _guestHTTPSProxy = nil
            _guestNoProxy = nil
        }
        stateLock.unlock()
    }

    /// Records that `morbinit` answered on this boot. Safe from any thread.
    private func noteGuestPinged() {
        stateLock.lock()
        _guestPingedSnapshot = true
        stateLock.unlock()
    }

    /// Records that `morbinit` answered, but only while `generation` is still the
    /// current probe generation. Safe from any thread.
    ///
    /// The check and the write share one critical section with
    /// ``bumpProbeGeneration()``, so a probe superseded mid-exchange cannot slip a
    /// stale "the guest answered" into the snapshots the next boot just reset —
    /// provided invalidation bumps the generation *before* it wipes (see
    /// ``invalidateControlReadiness()``).
    private func noteGuestPinged(ifCurrent generation: Int) {
        stateLock.lock()
        if _probeGeneration == generation { _guestPingedSnapshot = true }
        stateLock.unlock()
    }

    /// Records the guest's `docker_data_on_disk` answer. Safe from any thread.
    private func noteDockerDataOnDisk(_ value: Bool?) {
        stateLock.lock()
        _dockerDataOnDisk = value
        stateLock.unlock()
    }

    /// Records the guest's `rosetta` / `binfmt_amd64` answers. Safe from any thread.
    ///
    /// Both are left untouched when the guest omits them, so a single reply from
    /// an older initramfs cannot erase what a newer one already told us.
    private func noteGuestRosetta(
        rosetta: Bool?, binfmtAmd64: String?, ifCurrent generation: Int
    ) {
        stateLock.lock()
        if _probeGeneration == generation {
            if let rosetta { _guestRosetta = rosetta }
            if let binfmtAmd64 { _guestBinfmtAmd64 = binfmtAmd64 }
        }
        stateLock.unlock()
    }

    /// Records the guest's `morbinit_version`. Left untouched when omitted: an
    /// older initramfs not repeating the field must not erase a prior report.
    private func noteGuestMorbinitVersion(_ version: String?, ifCurrent generation: Int) {
        guard let version else { return }
        stateLock.lock()
        if _probeGeneration == generation { _guestMorbinitVersion = version }
        stateLock.unlock()
    }

    /// Records the guest's reported proxy environment. Each field is left
    /// untouched when the guest omits it — an older initramfs not repeating
    /// `info`'s proxy fields must not erase a prior report — but an empty
    /// string, unlike `nil`, is recorded: it is the guest's positive
    /// statement that dockerd has no proxy of that kind.
    private func noteGuestProxy(
        http: String?, https: String?, noProxy: String?, ifCurrent generation: Int
    ) {
        guard http != nil || https != nil || noProxy != nil else { return }
        stateLock.lock()
        if _probeGeneration == generation {
            if let http { _guestHTTPProxy = http }
            if let https { _guestHTTPSProxy = https }
            if let noProxy { _guestNoProxy = noProxy }
        }
        stateLock.unlock()
    }

    /// Records the guest's additive event-delivery capability. Absence from an older
    /// guest intentionally leaves the prior observation untouched for this boot, just
    /// as the other additive `info` fields do.
    private func noteGuestShareEventBridge(
        capability: String?, contractVersion: Int?, ifCurrent generation: Int
    ) {
        guard capability != nil || contractVersion != nil else { return }
        stateLock.lock()
        if _probeGeneration == generation {
            if let capability { _guestShareEventBridge = capability }
            if let contractVersion { _guestShareEventBridgeContractVersion = contractVersion }
        }
        stateLock.unlock()
    }

    /// Records the guest's additive disk-resize capability. Like other `info`
    /// capabilities, an older guest's absence must not become a false `ready`.
    private func noteGuestDiskResize(_ capability: String?, ifCurrent generation: Int) {
        guard let capability else { return }
        stateLock.lock()
        if _probeGeneration == generation {
            _guestDiskResize = capability
            _lastGuestDiskResize = capability
        }
        stateLock.unlock()
    }

    // MARK: - Public lifecycle API

    /// Boots the VM from scratch (or reports success if it is already running).
    ///
    /// The completion fires once the hypervisor reports the guest as running; the
    /// guest-control handshake continues in the background and is what
    /// ``ensureRunning(timeout:completion:)`` waits on.
    public func start(completion: @escaping (Result<Void, Error>) -> Void) {
        let done = CompletionOnce(completion)
        queue.async { [weak self] in
            guard let self else { return done.fire(.failure(CompletionOnce.managerGone)) }
            self.startOnQueue(done: done)
        }
    }

    /// Stops the VM.
    ///
    /// Unless `force` is set, `morbinit` is asked to shut down over the guest control
    /// channel first so that containerd gets a chance to flush state.
    public func stop(force: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        let done = CompletionOnce(completion)
        queue.async { [weak self] in
            guard let self else { return done.fire(.failure(CompletionOnce.managerGone)) }
            self.stopOnQueue(force: force, done: done)
        }
    }

    /// Pauses the guest, writes `vmstate.bin` and releases the VM's memory.
    ///
    /// - Parameter ifStillIdle: Evaluated on the VM queue immediately before the guest
    ///   is paused. Returning `false` abandons the suspend and reports success without
    ///   touching the VM. The auto-suspend timer uses this to re-check its "no active
    ///   Docker connections" precondition at the last possible moment, closing the gap
    ///   between deciding to suspend and actually doing it.
    public func suspend(ifStillIdle: (() -> Bool)? = nil,
                        completion: @escaping (Result<Void, Error>) -> Void) {
        let done = CompletionOnce(completion)
        queue.async { [weak self] in
            guard let self else { return done.fire(.failure(CompletionOnce.managerGone)) }
            self.suspendOnQueue(ifStillIdle: ifStillIdle, done: done)
        }
    }

    /// Rebuilds the VM from `vmstate.bin` and resumes execution.
    public func resume(completion: @escaping (Result<Void, Error>) -> Void) {
        let done = CompletionOnce(completion)
        queue.async { [weak self] in
            guard let self else { return done.fire(.failure(CompletionOnce.managerGone)) }
            self.resumeOnQueue(done: done)
        }
    }

    /// Deletes the Docker data disk after proving that this manager has released it.
    ///
    /// This intentionally runs on the VM queue instead of exposing the disk image to
    /// a command-line caller. A lifecycle token is only a report of the last operation:
    /// an `.error` token can still retain a `VZVirtualMachine`, and unlinking its disk
    /// would leave a live guest writing to an orphaned file. The only safe proof is
    /// that the queue which owns Virtualization.framework no longer owns a VM object.
    ///
    /// A saved state has no live VM object and is safe to discard with the disk. An
    /// error, including one whose VM object was released by a failed operation, is
    /// deliberately refused until the owner has completed an explicit stop. That
    /// makes recovery fail closed rather than guessing what Virtualization.framework
    /// still has attached.
    public func resetDisk(completion: @escaping (Result<Void, Error>) -> Void) {
        let done = CompletionOnce(completion)
        queue.async { [weak self] in
            guard let self else { return done.fire(.failure(CompletionOnce.managerGone)) }
            self.resetDiskOnQueue(done: done)
        }
    }

    /// Performs the complete grow-only persistent Docker-disk transaction.
    ///
    /// The VM must be fully stopped. This method journals the exact regular RAW file,
    /// extends only that file, boots a fresh guest, and completes only after the guest
    /// identifies `/dev/vda`, grows the mounted filesystem, and returns a proof that
    /// matches the journal. A failure after `ftruncate` intentionally leaves the
    /// journal for an explicit safe retry; no rollback ever shrinks the disk.
    public func growDisk(targetGiB: Int, completion: @escaping (Result<Void, Error>) -> Void) {
        let done = CompletionOnce(completion)
        queue.async { [weak self] in
            guard let self else { return done.fire(.failure(CompletionOnce.managerGone)) }
            self.growDiskOnQueue(targetGiB: targetGiB, done: done)
        }
    }

    /// Brings the VM to a state where the guest answers its control channel, booting
    /// or resuming as appropriate.
    ///
    /// This is the entry point used by socket activation: several Docker CLI
    /// connections can land at once and they all wait on the same boot. Callers that
    /// arrive during a transitional state (`starting`, `pausing`, `stopping`) are
    /// queued and serviced when that transition settles — in particular, a client that
    /// races an auto-suspend cancels it, or resumes immediately behind it, rather than
    /// being told to "retry shortly".
    public func ensureRunning(timeout: TimeInterval, completion: @escaping (Result<Void, Error>) -> Void) {
        let done = CompletionOnce(completion)
        queue.async { [weak self] in
            guard let self else { return done.fire(.failure(CompletionOnce.managerGone)) }
            if self.diskGrowthInFlight {
                self.addWaiter(timeout: timeout, done: done)
                return
            }
            switch self.state {
            case .running:
                if self.controlReady {
                    done.fire(.success(()))
                } else {
                    // Booted but the guest has not answered yet; wait for the probe.
                    self.addWaiter(timeout: timeout, done: done)
                    self.beginControlProbe(syncClock: false)
                }
            case .starting:
                self.addWaiter(timeout: timeout, done: done)
            case .pausing:
                // A suspend is in flight. Either it has not written anything yet, in
                // which case it is cancelled and the guest simply keeps running, or it
                // is already saving, in which case the resume is queued behind it.
                self.suspendCancelRequested = true
                self.log.info("client arrived during a suspend; cancelling or resuming immediately")
                self.addWaiter(timeout: timeout, done: done)
            case .stopping:
                self.addWaiter(timeout: timeout, done: done)
            case .stopped, .suspended, .error:
                self.addWaiter(timeout: timeout, done: done)
                self.beginBringUp()
            }
        }
    }

    /// Registers a handler for **guest-initiated** vsock connections to `port`.
    ///
    /// Everything else on the vsock link is host-initiated; this is the one
    /// reversed channel (the userland-proxy wrapper's port-lease requests,
    /// ``MorbVsockPorts/hostPortLease``). The handler receives a `dup`'d
    /// descriptor it owns outright, and is invoked on the VM queue — it must
    /// hand off to its own queue immediately rather than block.
    ///
    /// The registration is durable across VM generations: it is re-installed
    /// on every VZVirtualMachine this manager creates, cold-boot or restore,
    /// so a lease request arriving the moment dockerd starts a restart-policy
    /// container is always answerable.
    public func setGuestInitiatedConnectionHandler(
        port: UInt32,
        handler: @escaping (Int32) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.guestListenerHandlers[port] = handler
            if let vm = self.virtualMachine {
                self.installGuestVsockListener(on: vm, port: port, handler: handler)
            }
        }
    }

    /// Installs every registered guest-initiated listener on a fresh VM.
    /// Must run on the VM queue with `vm` current.
    private func installGuestVsockListeners(on vm: VZVirtualMachine) {
        for (port, handler) in guestListenerHandlers {
            installGuestVsockListener(on: vm, port: port, handler: handler)
        }
    }

    private func installGuestVsockListener(
        on vm: VZVirtualMachine,
        port: UInt32,
        handler: @escaping (Int32) -> Void
    ) {
        guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else {
            log.warn("cannot serve guest vsock port \(port): the VM has no virtio-socket device")
            return
        }
        let delegate = GuestVsockAcceptDelegate(handler: handler, log: log)
        let listener = VZVirtioSocketListener()
        listener.delegate = delegate
        device.setSocketListener(listener, forPort: port)
        // The device retains the listener but not the delegate; keep both so
        // the accept callback cannot dangle for the VM's lifetime.
        guestListeners[port] = (listener, delegate)
    }

    /// Accepts one guest-initiated connection, `dup`s the descriptor out of the
    /// `VZVirtioSocketConnection` (same ownership rule as ``connectVsock``),
    /// and hands it to the registered handler.
    private final class GuestVsockAcceptDelegate: NSObject, VZVirtioSocketListenerDelegate {
        private let handler: (Int32) -> Void
        private let log: MorbLog

        init(handler: @escaping (Int32) -> Void, log: MorbLog) {
            self.handler = handler
            self.log = log
        }

        func listener(
            _ listener: VZVirtioSocketListener,
            shouldAcceptNewConnection connection: VZVirtioSocketConnection,
            from socketDevice: VZVirtioSocketDevice
        ) -> Bool {
            let original = connection.fileDescriptor
            guard original >= 0 else {
                connection.close()
                return false
            }
            let owned = dup(original)
            connection.close()
            guard owned >= 0 else {
                log.warn("dup of a guest-initiated vsock descriptor failed: \(String(cString: strerror(errno)))")
                return false
            }
            handler(owned)
            return true
        }
    }

    /// Opens a vsock connection to `port` in the guest.
    ///
    /// The returned descriptor is `dup`'d out of the `VZVirtioSocketConnection` and the
    /// original is closed, so its lifetime belongs to the caller rather than to an
    /// Objective-C object we would otherwise have to keep alive.
    public func connectVsock(port: UInt32, completion: @escaping (Result<Int32, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else {
                completion(.failure(CompletionOnce.managerGone))
                return
            }
            guard let vm = self.virtualMachine, vm.state == .running else {
                completion(.failure(MorbError.vm("VM is not running")))
                return
            }
            guard let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else {
                completion(.failure(MorbError.vm("VM has no virtio-socket device")))
                return
            }
            socketDevice.connect(toPort: port) { result in
                switch result {
                case .failure(let error):
                    completion(.failure(MorbError.vm("vsock connect to port \(port) failed: \(error.localizedDescription)")))
                case .success(let connection):
                    let original = connection.fileDescriptor
                    guard original >= 0 else {
                        connection.close()
                        completion(.failure(MorbError.vm("vsock connection returned a closed descriptor")))
                        return
                    }
                    let owned = dup(original)
                    connection.close()
                    guard owned >= 0 else {
                        completion(.failure(MorbError.io("dup of vsock descriptor failed: \(String(cString: strerror(errno)))")))
                        return
                    }
                    completion(.success(owned))
                }
            }
        }
    }

    // MARK: - Queue-confined implementation

    private func startOnQueue(done: CompletionOnce) {
        if state == .running, virtualMachine != nil {
            if !controlReady { beginControlProbe(syncClock: false) }
            done.fire(.success(()))
            return
        }
        if virtualMachine != nil, case .error(let reason) = state {
            // A VM object stranded in `.error` used to be permanent: the guard
            // below refuses to build a second one, so every later `docker`
            // command — and every retry of `morb start` — failed with "a virtual
            // machine already exists in state error" until the daemon was killed
            // by hand. One failed suspend should not take the stack down for
            // good; tear the corpse down and boot a fresh one.
            log.warn("recovering from a wedged VM (\(reason)): forcing a stop, then cold-booting")
            hardStopOnQueue(done: CompletionOnce { [weak self] _ in
                guard let self else { return done.fire(.failure(CompletionOnce.managerGone)) }
                self.queue.async { [weak self] in
                    guard let self else { return done.fire(.failure(CompletionOnce.managerGone)) }
                    guard self.virtualMachine == nil else {
                        done.fire(.failure(MorbError.vm(
                            "could not recover the virtual machine from state \(self.state.description)")))
                        return
                    }
                    self.startOnQueue(done: done)
                }
            })
            return
        }
        guard virtualMachine == nil else {
            done.fire(.failure(MorbError.vm("a virtual machine already exists in state \(state.description)")))
            return
        }

        // "Start" on a suspended stack means "make it usable", and the fastest
        // correct way to do that is to restore. Cold-booting here instead would
        // silently throw away the guest's running state *and* orphan the blob,
        // which the next suspend then trips over (saveMachineStateTo will not
        // overwrite). resumeOnQueue falls through to a cold boot when the blob
        // is missing or unusable, so this is safe unconditionally.
        if FileManager.default.fileExists(atPath: MorbPaths.vmState.path), !isSaveRestoreBroken {
            resumeOnQueue(done: done)
            return
        }

        setState(.starting)
        bringUpStartedAt = Date()
        invalidateControlReadiness()
        do {
            let configuration = try buildConfiguration()
            let vm = VZVirtualMachine(configuration: configuration, queue: queue)
            vm.delegate = self
            virtualMachine = vm
            installGuestVsockListeners(on: vm)
            log.info("starting VM: \(configuration.cpuCount) vCPU, \(configuration.memorySize / (1024 * 1024)) MiB")
            vm.start { [weak self] result in
                guard let self else { return done.fire(.failure(CompletionOnce.managerGone)) }
                switch result {
                case .success:
                    self.setState(.running)
                    self.beginControlProbe(syncClock: false)
                    done.fire(.success(()))
                case .failure(let error):
                    let wrapped = MorbError.vm("VM failed to start: \(error.localizedDescription)")
                    self.virtualMachine = nil
                    self.closeConsole()
                    self.invalidateControlReadiness()
                    self.setState(.error(wrapped.description))
                    self.flushWaiters(.failure(wrapped))
                    done.fire(.failure(wrapped))
                }
            }
        } catch {
            virtualMachine = nil
            closeConsole()
            invalidateControlReadiness()
            setState(.error("\(error)"))
            flushWaiters(.failure(error))
            done.fire(.failure(error))
        }
    }

    /// Stops the VM, or joins the stop that is already running. Must run on ``queue``.
    ///
    /// Every caller is parked in ``stopWaiters`` — including the first one — so there
    /// is exactly one place that answers them and no path where a completion is
    /// dropped on the floor.
    private func stopOnQueue(force: Bool, done: CompletionOnce) {
        stopWaiters.append(done)
        if stopInFlight {
            log.info("stop already in flight; joining it (\(stopWaiters.count) caller(s) waiting)")
            return
        }
        stopInFlight = true

        let finish = CompletionOnce { [weak self] result in
            guard let self else { return }
            // Hop back onto the VM queue: this fires from Virtualization.framework
            // callbacks and from the off-queue guest-control worker alike, and the
            // waiter list is queue-confined.
            self.queue.async { self.finishStopOnQueue(result) }
        }
        performStopOnQueue(force: force, done: finish)
    }

    /// Answers everyone who was waiting on the stop that just finished. Runs on ``queue``.
    private func finishStopOnQueue(_ result: Result<Void, Error>) {
        stopInFlight = false
        let waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters { waiter.fire(result) }
    }

    private func performStopOnQueue(force: Bool, done: CompletionOnce) {
        guard let vm = virtualMachine else {
            invalidateControlReadiness()
            setState(.stopped)
            done.fire(.success(()))
            serviceWaitersOnQueue()
            return
        }
        setState(.stopping)
        invalidateControlReadiness()

        guard !force, vm.state == .running,
              let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice
        else {
            hardStopOnQueue(done: done)
            return
        }

        // Ask morbinit to shut down cleanly first. The MRB0 exchange is blocking, so
        // it runs off the VM queue; we hop back before touching the VM again.
        socketDevice.connect(toPort: MorbVsockPorts.guestControl) { [weak self] result in
            guard let self else { return done.fire(.failure(CompletionOnce.managerGone)) }
            guard case .success(let connection) = result else {
                self.log.warn("guest control unreachable; stopping without a clean shutdown")
                self.hardStopOnQueue(done: done)
                return
            }
            let original = connection.fileDescriptor
            let owned = original >= 0 ? dup(original) : -1
            connection.close()
            guard owned >= 0 else {
                self.hardStopOnQueue(done: done)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let control = GuestControl(fd: owned)
                // `morbinit` stops its services and syncs the Docker data disk
                // *before* it answers, so this reply can legitimately take many
                // seconds. Hard-stopping on the old eight-second budget would cut
                // the guest off mid-`sync` and lose whatever containerd had not
                // flushed — which only became a data-loss bug once /var/lib/docker
                // moved onto a real disk.
                var acknowledged = false
                do {
                    try control.shutdown(timeout: VMManager.shutdownAckTimeout)
                    acknowledged = true
                    self?.log.info("guest acknowledged shutdown (services stopped and synced)")
                } catch {
                    self?.log.warn("guest shutdown request failed: \(error)")
                }
                control.closeOwnedDescriptor()
                guard let self else { return done.fire(.failure(CompletionOnce.managerGone)) }
                self.queue.async { [weak self] in
                    guard let self else { return done.fire(.failure(CompletionOnce.managerGone)) }
                    guard acknowledged else {
                        self.hardStopOnQueue(done: done)
                        return
                    }
                    // The ack means the data is safe; the guest is now on its way to
                    // powering itself off. Letting it get there means the hypervisor
                    // sees an orderly halt instead of a yanked plug.
                    self.whenGuestPowersOff(vm, timeout: VMManager.guestPowerOffTimeout) { [weak self] timedOut in
                        guard let self else { return done.fire(.failure(CompletionOnce.managerGone)) }
                        if timedOut {
                            self.log.info(
                                "guest did not power off within \(Int(VMManager.guestPowerOffTimeout))s; "
                                    + "stopping it")
                        }
                        self.hardStopOnQueue(done: done)
                    }
                }
            }
        }
    }

    /// A one-shot `guestDidStop` observer with a deadline.
    private final class GuestStopObserver {
        let body: (Bool) -> Void
        var fired = false
        init(_ body: @escaping (Bool) -> Void) { self.body = body }
        /// Fires once; `timedOut` says whether the deadline beat the guest.
        func fire(timedOut: Bool) {
            guard !fired else { return }
            fired = true
            body(timedOut)
        }
    }

    /// Calls `body` on ``queue`` once `vm` powers itself off, or after `timeout`.
    ///
    /// Must run on ``queue``. `body` receives `true` when the deadline expired first.
    ///
    /// Ordering-safe against `guestDidStop`: the registration is scheduled from the
    /// guest-control worker after the shutdown ack, and the guest can power off —
    /// and the delegate callback land on ``queue`` — before that hop arrives. The
    /// event is therefore *recorded* rather than merely broadcast: every path that
    /// empties the VM slot goes through ``releaseVirtualMachine(_:)``, so
    /// `virtualMachine !== vm` here means the power-off (or its moral equivalent)
    /// already happened and `body` runs immediately instead of burning the deadline.
    /// Comparing identity rather than nil-ness also keeps a registration that lost
    /// the race from latching onto a *newer* boot that slipped into the slot and
    /// then hard-stopping it five seconds later.
    private func whenGuestPowersOff(
        _ vm: VZVirtualMachine, timeout: TimeInterval, _ body: @escaping (Bool) -> Void
    ) {
        guard virtualMachine === vm else {
            body(false)
            return
        }
        let observer = GuestStopObserver(body)
        guestStopObservers.append(observer)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return observer.fire(timedOut: true) }
            self.guestStopObservers.removeAll { $0 === observer }
            // A no-op when the observer already fired: `releaseVirtualMachine`
            // flushes pending observers, and `fire` is one-shot.
            observer.fire(timedOut: true)
        }
    }

    /// Fires every pending power-off observer. Must run on ``queue``.
    ///
    /// The observers fire on the *next* queue turn, not inline: the release that
    /// triggers this flush sits mid-way through a delegate callback or stop path
    /// that still has its own state and waiter bookkeeping to finish (for example,
    /// `guestDidStop` fails the run waiters *after* releasing the VM). An observer
    /// body runs `hardStopOnQueue`, which services waiters — reentering that inside
    /// the callback would interleave the two and can boot a new VM before the
    /// callback has even recorded that the old one stopped.
    private func flushGuestStopObservers() {
        let observers = guestStopObservers
        guestStopObservers.removeAll()
        guard !observers.isEmpty else { return }
        queue.async {
            for observer in observers { observer.fire(timedOut: false) }
        }
    }

    /// Unconditional `vm.stop()`; must run on the VM queue.
    private func hardStopOnQueue(done: CompletionOnce) {
        invalidateControlReadiness()
        guard let vm = virtualMachine else {
            setState(.stopped)
            done.fire(.success(()))
            serviceWaitersOnQueue()
            return
        }
        guard vm.canStop else {
            releaseVirtualMachine(vm)
            setState(.stopped)
            done.fire(.success(()))
            serviceWaitersOnQueue()
            return
        }
        vm.stop { [weak self] error in
            guard let self else { return done.fire(.failure(CompletionOnce.managerGone)) }
            self.virtualMachine = nil
            self.closeConsole()
            if let error {
                let wrapped = MorbError.vm("VM stop failed: \(error.localizedDescription)")
                self.setState(.error(wrapped.description))
                done.fire(.failure(wrapped))
            } else {
                self.setState(.stopped)
                done.fire(.success(()))
            }
            self.serviceWaitersOnQueue()
        }
    }

    private func suspendOnQueue(ifStillIdle: (() -> Bool)?, done: CompletionOnce) {
        guard let vm = virtualMachine else {
            // Nothing to do; report the state we are already in.
            done.fire(.success(()))
            return
        }
        guard vm.state == .running || vm.state == .paused else {
            done.fire(.failure(MorbError.vm("cannot suspend from state \(state.description)")))
            return
        }
        if let ifStillIdle, !ifStillIdle() {
            log.info("suspend skipped: the stack became busy before the guest was paused")
            done.fire(.success(()))
            return
        }
        if isSaveRestoreBroken {
            // Writing a state blob we already know cannot be restored would cost 150 MB
            // and several seconds, and then wedge the next start. Stopping frees the
            // guest's memory just the same, which is the point of auto-suspend; the
            // only thing lost is the instant wake-up.
            log.info("suspend-to-disk unavailable here; stopping the guest instead")
            // A graceful stop, not a hard one: containerd still deserves the chance to
            // flush, and the memory is freed either way.
            stopOnQueue(force: false, done: done)
            return
        }

        suspendCancelRequested = false
        setState(.pausing)
        // Same reasoning as stop and hard-stop: from here on the guest is no longer
        // usable, and any boot probe still spinning belongs to a bring-up this
        // suspend has superseded. Leaving it live lets its failure block flush the
        // waiters that ``ensureRunning`` queued behind the suspend-cancel — the
        // client that just arrived would get a 502 for a VM that is about to be
        // running again. Bumping the generation orphans that probe instead.
        invalidateControlReadiness()

        let saveURL = MorbPaths.vmState
        let finishSave: () -> Void = { [weak self] in
            guard let self else { return done.fire(.failure(CompletionOnce.managerGone)) }
            guard let vm = self.virtualMachine else {
                self.invalidateControlReadiness()
                self.setState(.stopped)
                done.fire(.success(()))
                self.serviceWaitersOnQueue()
                return
            }
            if self.suspendCancelRequested {
                self.abortSuspend(vm: vm, done: done)
                return
            }
            // saveMachineStateTo refuses to overwrite: it creates the file with
            // O_EXCL and fails the whole suspend with "The save file could not be
            // created ... File exists" if anything is already there. A blob is
            // there whenever a previous suspend was resumed by a cold boot rather
            // than a restore, so this is the normal case, not the exotic one.
            self.discardSavedState()
            vm.saveMachineStateTo(url: saveURL) { [weak self] error in
                guard let self else { return done.fire(.failure(CompletionOnce.managerGone)) }
                if let error {
                    let wrapped = MorbError.vm("saving VM state failed: \(error.localizedDescription)")
                    // The guest is still paused and intact, but its state was not
                    // written. Let it go rather than parking a live VZVirtualMachine
                    // in `.error` forever: `startOnQueue` refuses to build a second
                    // VM while one exists, so keeping it would mean every later
                    // `docker` command fails until the daemon is killed. A partial
                    // blob is worse than none — drop it too.
                    self.log.warn(
                        "\(wrapped.description) — discarding the guest and cold-booting on next use")
                    self.discardSavedState()
                    self.releaseVirtualMachine(vm)
                    self.setState(.stopped)
                    done.fire(.failure(wrapped))
                    self.serviceWaitersOnQueue()
                    return
                }
                // Releasing the VM object is what actually returns the guest's RAM
                // to the host, which is the whole point of suspending.
                self.releaseVirtualMachine(vm)
                self.setState(.suspended)
                self.log.info("VM suspended to \(saveURL.path)")
                done.fire(.success(()))
                // A client may have arrived while the save was running; bring the VM
                // straight back up for it rather than making it wait for a retry.
                self.serviceWaitersOnQueue()
            }
        }

        if vm.state == .paused {
            finishSave()
            return
        }
        vm.pause { [weak self] result in
            guard let self else { return done.fire(.failure(CompletionOnce.managerGone)) }
            switch result {
            case .success:
                finishSave()
            case .failure(let error):
                let wrapped = MorbError.vm("pausing VM failed: \(error.localizedDescription)")
                self.setState(.error(wrapped.description))
                done.fire(.failure(wrapped))
                self.serviceWaitersOnQueue()
            }
        }
    }

    /// Undoes a suspend that a client raced before anything was written to disk.
    private func abortSuspend(vm: VZVirtualMachine, done: CompletionOnce) {
        suspendCancelRequested = false
        log.info("suspend cancelled: a client connected before the guest was saved")
        guard vm.canResume else {
            setState(.running)
            done.fire(.success(()))
            serviceWaitersOnQueue()
            return
        }
        vm.resume { [weak self] result in
            guard let self else { return done.fire(.failure(CompletionOnce.managerGone)) }
            switch result {
            case .success:
                self.setState(.running)
                done.fire(.success(()))
            case .failure(let error):
                let wrapped = MorbError.vm(
                    "resuming after a cancelled suspend failed: \(error.localizedDescription)")
                self.setState(.error(wrapped.description))
                done.fire(.failure(wrapped))
            }
            self.serviceWaitersOnQueue()
        }
    }

    private func resumeOnQueue(done: CompletionOnce) {
        if state == .running, virtualMachine != nil {
            if !controlReady { beginControlProbe(syncClock: false) }
            done.fire(.success(()))
            return
        }
        let saveURL = MorbPaths.vmState
        guard FileManager.default.fileExists(atPath: saveURL.path), !isSaveRestoreBroken else {
            // Nothing usable saved — a cold boot is the right interpretation of "resume".
            discardSavedState()
            startOnQueue(done: done)
            return
        }
        guard virtualMachine == nil else {
            done.fire(.failure(MorbError.vm("a virtual machine already exists in state \(state.description)")))
            return
        }

        setState(.starting)
        bringUpStartedAt = Date()
        invalidateControlReadiness()
        do {
            let configuration = try buildConfiguration()
            let vm = VZVirtualMachine(configuration: configuration, queue: queue)
            vm.delegate = self
            virtualMachine = vm
            installGuestVsockListeners(on: vm)
            log.info("restoring VM from \(saveURL.path)")
            vm.restoreMachineStateFrom(url: saveURL) { [weak self] error in
                guard let self else { return done.fire(.failure(CompletionOnce.managerGone)) }
                if let error {
                    // A save blob that will not restore is worse than no save blob at
                    // all: every subsequent bring-up would pick it up and fail the
                    // same way, wedging the daemon until somebody deletes the file by
                    // hand. Discard it and cold-boot instead — the guest's container
                    // state is lost either way, and a fresh boot takes a couple of
                    // seconds. (Restore is also, empirically, refused outright by
                    // Virtualization.framework on some macOS builds.)
                    self.log.warn(
                        "restoring VM state failed: \(error.localizedDescription); "
                            + "discarding \(saveURL.path) and cold-booting")
                    self.discardSavedState()
                    self.markSaveRestoreBroken()
                    self.virtualMachine = nil
                    self.closeConsole()
                    self.invalidateControlReadiness()
                    self.setState(.stopped)
                    self.startOnQueue(done: done)
                    return
                }
                // A save file is single-use; keeping it would restore stale state.
                try? FileManager.default.removeItem(at: saveURL)
                vm.resume { [weak self] result in
                    guard let self else { return done.fire(.failure(CompletionOnce.managerGone)) }
                    switch result {
                    case .success:
                        self.setState(.running)
                        // The guest's clock stopped while it was saved; push the host
                        // wall clock back into it as soon as it answers.
                        self.beginControlProbe(syncClock: true)
                        done.fire(.success(()))
                    case .failure(let resumeError):
                        // The blob has already been consumed above, so a cold boot is
                        // the only way forward and is better than reporting failure.
                        self.log.warn(
                            "resuming the restored VM failed: \(resumeError.localizedDescription); "
                                + "cold-booting instead")
                        self.virtualMachine = nil
                        self.closeConsole()
                        self.invalidateControlReadiness()
                        self.setState(.stopped)
                        self.startOnQueue(done: done)
                    }
                }
            }
        } catch {
            virtualMachine = nil
            closeConsole()
            invalidateControlReadiness()
            setState(.error("\(error)"))
            flushWaiters(.failure(error))
            done.fire(.failure(error))
        }
    }

    /// Deletes the data disk only after the VM-owning queue has verified release.
    private func resetDiskOnQueue(done: CompletionOnce) {
        guard virtualMachine == nil else {
            done.fire(.failure(MorbError.vm(
                "the VM is still attached in state \(state.description); refusing to delete its disk. "
                    + "Run `morb stop --force` and retry.")))
            return
        }

        switch state {
        case .stopped, .suspended:
            break
        case .error:
            done.fire(.failure(MorbError.vm(
                "the VM is in an error state; refusing to guess whether Virtualization.framework "
                    + "has released the disk. Run `morb stop --force` and retry.")))
            return
        case .starting, .running, .pausing, .stopping:
            done.fire(.failure(MorbError.vm(
                "the VM is \(state.description); stop it before deleting the disk.")))
            return
        }

        let disk = MorbPaths.diskImage
        do {
            let savedState = MorbPaths.vmState
            if FileManager.default.fileExists(atPath: savedState.path) {
                // A saved VM state is no longer resumable once this operation has
                // begun. Remove it before touching the disk, so a later failure can
                // only leave a cold-bootable disk — never a resumable state whose
                // device it was written against has disappeared.
                try FileManager.default.removeItem(at: savedState)
            }
            setState(.stopped)
            if FileManager.default.fileExists(atPath: disk.path) {
                try FileManager.default.removeItem(at: disk)
            }
            log.warn("deleted Docker data disk after verified VM release: \(disk.path)")
            done.fire(.success(()))
        } catch {
            done.fire(.failure(MorbError.io(
                "could not delete \(disk.path): \(error.localizedDescription)")))
        }
    }

    // MARK: - Durable disk growth

    /// Runs only on the VM queue. That serializes the stopped-state proof with every
    /// Virtualization.framework attachment, closing the window between lifecycle
    /// observation and the host-side `ftruncate`.
    private func growDiskOnQueue(targetGiB: Int, done: CompletionOnce) {
        guard !diskGrowthInFlight else {
            done.fire(.failure(MorbError.vm("a disk-growth transaction is already in progress")))
            return
        }
        guard targetGiB > 0 else {
            done.fire(.failure(MorbError.config("disk growth requires a positive GiB target")))
            return
        }
        let targetBytes = MorbDiskCapacity.configuredBytes(forGiB: targetGiB)
        guard targetBytes != Int64.max else {
            done.fire(.failure(MorbError.config("disk growth target is too large")))
            return
        }
        guard virtualMachine == nil, state == .stopped else {
            done.fire(.failure(MorbError.vm(
                "the VM is \(state.description); stop it completely before growing its disk.")))
            return
        }
        guard !FileManager.default.fileExists(atPath: MorbPaths.vmState.path) else {
            done.fire(.failure(MorbError.vm(
                "a saved VM state still describes this disk; resume or discard it before growing the disk.")))
            return
        }

        do {
            var journal: MorbDiskGrowth.Journal
            if let existing = try MorbDiskGrowth.loadJournal() {
                guard existing.targetBytes == targetBytes else {
                    throw MorbError.protocolViolation(
                        "a disk-grow recovery journal targets \(existing.targetBytes) bytes; retry that target "
                            + "before requesting \(targetBytes) bytes")
                }
                journal = existing
            } else {
                let capacity = MorbDiskCapacity.inspect(configuredGiB: targetGiB)
                switch capacity.state {
                case .willCreate:
                    // No filesystem exists yet. The normal first boot will create a
                    // sparse image at this capacity, so do not boot merely to resize.
                    // Persist only after the stopped-state guard above accepted this
                    // request; a refused running grow must not change configuration.
                    try persistConfiguredDiskSizeGiB(targetGiB)
                    setConfiguredDiskSizeGiB(targetGiB)
                    done.fire(.success(()))
                    return
                case .matchesConfiguration:
                    try persistConfiguredDiskSizeGiB(targetGiB)
                    setConfiguredDiskSizeGiB(targetGiB)
                    done.fire(.success(()))
                    return
                case .decreaseUnsupported:
                    throw MorbError.unsupported("Morbstack never shrinks an existing VM disk")
                case .unavailable:
                    throw MorbError.io(capacity.inspectionError ?? "could not inspect the VM disk image")
                case .increaseRequiresGuestResize:
                    guard let originalBytes = capacity.currentBytes else {
                        throw MorbError.io("disk capacity inspection returned no existing image length")
                    }
                    journal = try MorbDiskGrowth.makeJournal(
                        originalBytes: originalBytes, targetBytes: targetBytes)
                    // This must be durable before the RAW file changes length.
                    try MorbDiskGrowth.storeJournal(journal)
                }
            }

            if journal.phase != .guestProved {
                journal.phase = try MorbDiskGrowth.extendRawImage(journal)
                try MorbDiskGrowth.storeJournal(journal)
            }
            try MorbDiskGrowth.verifyHostGrowth(journal)

            diskGrowthInFlight = true
            log.info(
                "disk-grow journal is durable: \(journal.originalBytes) -> \(journal.targetBytes) bytes; "
                    + "booting guest for filesystem proof")
            let bootDone = CompletionOnce { [weak self] result in
                guard let self else { return done.fire(.failure(CompletionOnce.managerGone)) }
                self.diskGrowthBootDidComplete(result, journal: journal, targetGiB: targetGiB, done: done)
            }
            startOnQueue(done: bootDone)
        } catch {
            done.fire(.failure(error))
        }
    }

    /// Starts the MRB0 proof exchange off the Virtualization queue. `morbinit` offers
    /// control before dockerd is ready, which is exactly when this must happen.
    private func diskGrowthBootDidComplete(
        _ result: Result<Void, Error>,
        journal: MorbDiskGrowth.Journal,
        targetGiB: Int,
        done: CompletionOnce
    ) {
        switch result {
        case .failure(let error):
            finishDiskGrowth(.failure(error), targetGiB: targetGiB, done: done)
        case .success:
            probeQueue.async { [weak self] in
                guard let self else {
                    return done.fire(.failure(CompletionOnce.managerGone))
                }
                let result = self.obtainDiskGrowthProof(journal: journal, targetGiB: targetGiB)
                self.queue.async { [weak self] in
                    self?.finishDiskGrowth(result, targetGiB: targetGiB, done: done)
                }
            }
        }
    }

    /// A missing control server is expected while a guest is booting. A guest that
    /// answers but lacks the protocol, or rejects its grow tool, fails immediately and
    /// leaves the journal as the only recovery authority.
    private func obtainDiskGrowthProof(
        journal: MorbDiskGrowth.Journal,
        targetGiB: Int
    ) -> Result<Void, Error> {
        let deadline = Date().addingTimeInterval(VMManager.controlReadyTimeout)
        var lastError: Error = MorbError.timeout("guest control did not answer")
        while Date() < deadline {
            guard state == .running else {
                return .failure(MorbError.vm("the VM stopped before its disk resize could be proved"))
            }
            switch connectVsockBlocking(port: MorbVsockPorts.guestControl, timeout: 3) {
            case .failure(let error):
                lastError = error
                usleep(VMManager.controlProbeInterval)
            case .success(let fd):
                let control = GuestControl(fd: fd)
                defer { control.closeOwnedDescriptor() }
                do {
                    let info: GuestReply
                    do {
                        info = try control.info(timeout: 3)
                    } catch {
                        lastError = error
                        usleep(VMManager.controlProbeInterval)
                        continue
                    }
                    guard info.diskResize == MorbDiskResize.GuestCapability.ready.rawValue else {
                        return .failure(MorbError.unsupported(
                            "the freshly booted guest does not support the verified disk-resize protocol"))
                    }
                    let proof: GuestDiskResizeProof
                    do {
                        proof = try control.diskResize(targetBytes: journal.targetBytes)
                    } catch let error as MorbError {
                        // The guest returned an explicit control error (for example a
                        // mount mismatch or a missing grow tool). Do not turn that
                        // deterministic safety refusal into an unbounded retry.
                        if case .protocolViolation(_) = error { return .failure(error) }
                        lastError = error
                        usleep(VMManager.controlProbeInterval)
                        continue
                    }
                    let journalProof = proof.journalProof
                    try MorbDiskGrowth.validateGuestProof(journalProof, journal: journal)

                    // A crash after this write but before removal is safe: recovery
                    // re-queries the guest, and this phase permits its idempotent
                    // `resized: false` response only after a prior durable proof.
                    var completed = journal
                    completed.phase = .guestProved
                    completed.proof = journalProof
                    try MorbDiskGrowth.storeJournal(completed)
                    // The physical image and guest filesystem are now proven. Commit
                    // the user-visible target before dropping the recovery journal:
                    // if this preserving write fails, retry re-verifies the guest and
                    // can finish the config commit without ever shrinking the image.
                    try persistConfiguredDiskSizeGiB(targetGiB)
                    try MorbDiskGrowth.removeJournal()
                    return .success(())
                } catch let error as MorbError {
                    return .failure(error)
                } catch {
                    lastError = error
                    usleep(VMManager.controlProbeInterval)
                }
            }
        }
        return .failure(MorbError.timeout(
            "guest did not provide a disk-resize proof within \(Int(VMManager.controlReadyTimeout))s "
                + "(last error: \(lastError))"))
    }

    /// Releases socket-activation waiters only after the full journal/proof protocol.
    /// On failure the VM is stopped before a client can use a raw-grown but unverified
    /// filesystem; the journal deliberately remains in place for a retry.
    private func finishDiskGrowth(
        _ result: Result<Void, Error>,
        targetGiB: Int,
        done: CompletionOnce
    ) {
        guard diskGrowthInFlight else { return }
        diskGrowthInFlight = false
        switch result {
        case .success:
            setConfiguredDiskSizeGiB(targetGiB)
            log.info("disk-grow completed with verified guest filesystem proof (\(targetGiB) GiB)")
            if controlReady { flushWaiters(.success(())) }
            done.fire(.success(()))
        case .failure(let error):
            log.error("disk-grow stopped before proof: \(error). Recovery journal retained.")
            flushWaiters(.failure(error))
            hardStopOnQueue(done: CompletionOnce { _ in
                done.fire(.failure(error))
            })
        }
    }

    private func setConfiguredDiskSizeGiB(_ value: Int) {
        diskCapacityLock.lock()
        configuredDiskSizeGiB = max(1, value)
        diskCapacityLock.unlock()
    }

    /// Commits the next-boot capacity only at a transaction point that already passed
    /// the VM lifecycle guard. This owns the last durable step for the transaction,
    /// so a CLI/direct request cannot leave `disk_size_gib` ahead of a refused or
    /// unproved host image.
    private func persistConfiguredDiskSizeGiB(_ targetGiB: Int) throws {
        let saved = try MorbConfig.load()
        var requested = saved
        requested.diskSizeGiB = targetGiB
        let changed = MorbConfig.changedKeys(from: saved, to: requested)
        if !changed.isEmpty {
            _ = try requested.savePreservingFile(expected: saved, changing: changed)
        }
    }

    private var effectiveDiskSizeGiB: Int {
        diskCapacityLock.lock()
        defer { diskCapacityLock.unlock() }
        return configuredDiskSizeGiB
    }

    private func releaseVirtualMachine(_ vm: VZVirtualMachine) {
        vm.delegate = nil
        virtualMachine = nil
        // The listener objects belong to the departing VM's socket device;
        // the handler registrations persist and are re-installed on the next
        // VM (see setGuestInitiatedConnectionHandler).
        guestListeners.removeAll()
        closeConsole()
        invalidateControlReadiness()
        // This is the one place the VM slot empties, which makes it the one place
        // that can promise `whenGuestPowersOff` observers never outlive the VM they
        // watch: whatever emptied the slot (clean power-off, error, hard stop,
        // suspend) is the event they were waiting for. A clean stop is usually
        // waiting on exactly this; releasing it here saves the five seconds its
        // deadline would otherwise burn.
        flushGuestStopObservers()
    }

    private func closeConsole() {
        try? consoleHandle?.close()
        consoleHandle = nil
    }

    // MARK: - Bring-up and waiters

    private final class RunWaiter {
        let done: CompletionOnce
        var fired = false
        init(_ done: CompletionOnce) { self.done = done }
    }

    private func addWaiter(timeout: TimeInterval, done: CompletionOnce) {
        let waiter = RunWaiter(done)
        runWaiters.append(waiter)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self, weak waiter] in
            guard let waiter, !waiter.fired else { return }
            waiter.fired = true
            self?.runWaiters.removeAll { $0 === waiter }
            waiter.done.fire(
                .failure(MorbError.timeout("VM did not become usable within \(Int(timeout))s")))
        }
    }

    private func flushWaiters(_ result: Result<Void, Error>) {
        let waiters = runWaiters
        runWaiters.removeAll()
        for waiter in waiters where !waiter.fired {
            waiter.fired = true
            waiter.done.fire(result)
        }
    }

    /// Starts a boot or a restore, routing failures to the queued waiters.
    ///
    /// The bring-up's own completion is not discarded: several of ``startOnQueue``'s
    /// early-exit paths fail without ever touching `runWaiters`, so without this the
    /// waiters would sit there until their individual timeouts expired.
    private func beginBringUp() {
        let kick: (Result<Void, Error>) -> Void = { [weak self] result in
            guard let self, case .failure(let error) = result else { return }
            self.log.warn("bring-up failed: \(error)")
            self.flushWaiters(.failure(error))
        }
        if hasSavedState {
            resumeOnQueue(done: CompletionOnce(kick))
        } else {
            startOnQueue(done: CompletionOnce(kick))
        }
    }

    /// Re-evaluates queued waiters after settling into a new state. Runs on ``queue``.
    private func serviceWaitersOnQueue() {
        // An explicit disk growth owns this boot until its guest proof is durable.
        // Starting a queued Docker relay here would otherwise reopen the same race the
        // transaction gate in `ensureRunning` closes.
        guard !diskGrowthInFlight else { return }
        guard !runWaiters.isEmpty else { return }
        switch state {
        case .running:
            if controlReady {
                flushWaiters(.success(()))
            } else {
                beginControlProbe(syncClock: false)
            }
        case .starting, .pausing, .stopping:
            break  // still in flight; the next settle services them
        case .stopped, .suspended, .error:
            beginBringUp()
        }
    }

    // MARK: - Guest control handshake

    /// Invalidates guest-control readiness and orphans any probe in flight.
    /// Must run on ``queue``.
    ///
    /// The generation bump comes *first*: once the snapshots are wiped, any write
    /// still guarded by the old generation must already be failing its check, or a
    /// superseded probe could repopulate the wiped snapshots in the window between
    /// the wipe and the bump.
    private func invalidateControlReadiness() {
        bumpProbeGeneration()
        setControlReady(false)
        controlProbeInFlight = false
    }

    /// What one connect + `ping` (+ `info`) exchange with the guest established.
    private enum ProbeOutcome {
        /// `morbinit` answered *and* reported `docker_ready`.
        case ready(
            uptimeMilliseconds: Int, dataOnDisk: Bool?,
            shares: [String: MorbShares.GuestMountState])
        /// `morbinit` answered but dockerd has not bound its socket yet.
        case dockerStarting(uptimeMilliseconds: Int)
        /// The guest could not be reached at all.
        case unreachable(Error)
    }

    /// Polls `morbinit` on vsock 1024 until the guest can actually serve Docker, then
    /// releases the waiters.
    ///
    /// There are *two* gaps to ride out, not one. "The hypervisor says the VM is
    /// running" and "morbinit answers MRB0" are a second or so apart; "morbinit
    /// answers" and "dockerd accepts connections on its socket" are several more,
    /// longer still on the boot that formats `/dev/vda`. Releasing the waiters on the
    /// `pong` alone means the first `docker` command relays into a vsock port with
    /// nothing behind it — a 502 if the connect fails outright, and a request that is
    /// silently absorbed and then closed if the guest-side proxy is listening but
    /// dockerd is not. Waiting for the `docker_ready` field turns both into a slightly
    /// slower first command, and a real error message if the guest never gets there.
    private func beginControlProbe(syncClock: Bool) {
        guard !controlProbeInFlight else { return }
        guard state == .running else { return }
        controlProbeInFlight = true
        // Bump before wiping, for the same reason as `invalidateControlReadiness()`:
        // after the wipe, a write guarded by the previous generation must already
        // be stale.
        let generation = bumpProbeGeneration()
        setControlReady(false)
        let started = bringUpStartedAt ?? Date()
        let deadline = Date().addingTimeInterval(VMManager.controlReadyTimeout)

        probeQueue.async { [weak self] in
            guard let self else { return }
            var lastError: Error = MorbError.timeout("guest control never answered")
            var guestAnswered = false
            var needsClockSync = syncClock

            while Date() < deadline {
                // Checked *between* iterations as well as at the end: a stop, a
                // suspend or a newer bring-up supersedes this probe, and the loop
                // must not run its remaining budget out holding a probe worker — nor
                // reach the failure block below and flush somebody else's waiters.
                guard self.probeGeneration == generation else { return }
                guard self.state == .running else {
                    lastError = MorbError.vm("the VM left the running state during boot")
                    break
                }
                switch self.probeGuestControlOnce(syncClock: needsClockSync, generation: generation) {
                case .ready(let uptimeMilliseconds, let dataOnDisk, let shares):
                    let elapsed = Date().timeIntervalSince(started)
                    // Everything learned from this exchange is recorded only behind
                    // the generation check on ``queue``. Recording it out here first
                    // looks harmless but is not: this closure can belong to a probe
                    // from a superseded boot, whose `invalidateControlReadiness()`
                    // already wiped the snapshots for the next boot. An unguarded
                    // write here would repopulate them with the *previous* boot's
                    // answers, and `morb status`/`doctor` would report data the
                    // current guest never sent.
                    self.queue.async { [weak self] in
                        guard let self, generation == self.probeGeneration else { return }
                        self.controlProbeInFlight = false
                        self.setControlReady(true)
                        self.noteGuestPinged()
                        self.noteDockerDataOnDisk(dataOnDisk)
                        self.noteGuestShares(shares)
                        // The one place per boot the protocol compatibility field is
                        // consulted. `info` was already exchanged, so a silent gap
                        // here would leave `morbinit_version` decoded-but-unread —
                        // the doc calls it the compatibility probe, and a probe
                        // nobody reads gates nothing.
                        if let reported = self.guestMorbinitVersion {
                            if MorbVersion.isOlder(
                                reported, than: MorbVersion.minimumCompatibleMorbinit) {
                                self.log.warn(
                                    "guest morbinit \(reported) is older than the oldest "
                                        + "version this daemon supports "
                                        + "(\(MorbVersion.minimumCompatibleMorbinit)) — "
                                        + "rebuild the guest image with `make guest-image`")
                            }
                        } else {
                            self.log.warn(
                                "the guest did not report morbinit_version — it predates "
                                    + "every supported guest image; rebuild it with "
                                    + "`make guest-image`")
                        }
                        self.log.info(
                            String(
                                format: "guest ready %.2fs after bring-up (guest uptime %dms, "
                                    + "docker data on %@)",
                                elapsed, uptimeMilliseconds,
                                dataOnDisk == nil
                                    ? "unknown storage" : (dataOnDisk! ? "disk" : "tmpfs")))
                        self.reportShareMounts(shares)
                        if !self.diskGrowthInFlight {
                            self.flushWaiters(.success(()))
                        }
                    }
                    return
                case .dockerStarting(let uptimeMilliseconds):
                    if !guestAnswered {
                        self.log.info(
                            "guest control answered (uptime \(uptimeMilliseconds)ms); "
                                + "waiting for dockerd")
                    }
                    guestAnswered = true
                    needsClockSync = false  // done once, on the first successful exchange
                    // Guarded: the generation check at the top of the loop ran
                    // *before* the blocking exchange, and an invalidation can land
                    // during it. The atomic form keeps a superseded probe from
                    // marking the next boot's guest as having answered.
                    self.noteGuestPinged(ifCurrent: generation)
                    lastError = MorbError.timeout("dockerd has not finished starting")
                    usleep(VMManager.controlProbeInterval)
                case .unreachable(let error):
                    lastError = error
                    usleep(VMManager.controlProbeInterval)
                }
            }

            let budget = Int(VMManager.controlReadyTimeout)
            let failure = MorbError.timeout(
                (guestAnswered
                    ? "the guest booted but dockerd was not serving within \(budget)s"
                    : "guest control did not answer within \(budget)s")
                    + " (last error: \(lastError)) — see \(MorbPaths.consoleLog.path)")
            self.log.error("\(failure)")
            self.queue.async { [weak self] in
                guard let self, generation == self.probeGeneration else { return }
                self.controlProbeInFlight = false
                self.setControlReady(false)
                self.flushWaiters(.failure(failure))
            }
        }
    }

    /// Logs the guest's verdict on each share, loudly when one did not mount.
    ///
    /// A share that the host configured and the guest did not mount is the single
    /// most confusing failure mode in this feature: every bind mount under that root
    /// silently becomes an empty directory inside the container, because dockerd
    /// creates missing bind sources rather than refusing. Naming it here means the
    /// daemon log says so before the user spends an hour on it.
    private func reportShareMounts(_ states: [String: MorbShares.GuestMountState]) {
        let configured = shares
        guard !configured.isEmpty else { return }
        if states.isEmpty {
            log.warn(
                "the guest did not report on its VirtioFS shares — it is probably older "
                    + "than this daemon; rebuild it with `make guest-image`")
            return
        }
        for share in configured {
            switch states[share.path] {
            case .mounted:
                continue
            case .failed:
                log.warn(
                    "the guest failed to mount \(share.path) (tag \(share.tag)) — bind mounts "
                        + "under it will see an empty directory; see \(MorbPaths.consoleLog.path)")
            case nil:
                log.warn(
                    "the guest never mentioned \(share.path) (tag \(share.tag)); it may not have "
                        + "seen the share on its kernel command line")
            }
        }
    }

    /// One connect + `ping` + `info` exchange. Blocking; never call from ``queue``.
    private func probeGuestControlOnce(syncClock: Bool, generation: Int) -> ProbeOutcome {
        switch connectVsockBlocking(port: MorbVsockPorts.guestControl, timeout: 3) {
        case .failure(let error):
            return .unreachable(error)
        case .success(let fd):
            let control = GuestControl(fd: fd)
            defer { control.closeOwnedDescriptor() }
            do {
                let uptime = try control.ping(timeout: 3)
                if syncClock {
                    // Best effort: a guest that cannot set its clock is still usable,
                    // it just has skewed container timestamps until the next attempt.
                    do {
                        try control.clockSync(
                            unixNanos: Int64(Date().timeIntervalSince1970 * 1_000_000_000))
                        log.info("guest clock synchronised after resume")
                    } catch {
                        log.warn("guest clock sync failed: \(error)")
                    }
                }
                let info = try control.info(timeout: 3)
                // Recorded here rather than threaded through `ProbeOutcome.ready`
                // because it is also true of a guest still starting dockerd: amd64
                // translation is set up long before the engine is up (binfmt at
                // ~220ms, dockerd ready at ~730ms), so `morb rosetta` should be able
                // to answer during that window instead of reporting "unknown".
                noteGuestRosetta(
                    rosetta: info.rosetta, binfmtAmd64: info.binfmtAmd64,
                    ifCurrent: generation)
                noteGuestMorbinitVersion(info.morbinitVersion, ifCurrent: generation)
                noteGuestTmpAliasMounted(info.tmpAliasMounted, ifCurrent: generation)
                noteGuestShareEventBridge(
                    capability: info.shareEventBridge,
                    contractVersion: info.shareEventBridgeContractVersion,
                    ifCurrent: generation)
                noteGuestDiskResize(info.diskResize, ifCurrent: generation)
                noteGuestProxy(
                    http: info.httpProxy, https: info.httpsProxy, noProxy: info.noProxy,
                    ifCurrent: generation)
                // A guest too old to report the field cannot tell us dockerd is up;
                // treating "absent" as ready keeps this compatible rather than
                // hanging for the whole boot budget against an older initramfs.
                guard info.dockerReady ?? true else {
                    return .dockerStarting(uptimeMilliseconds: uptime)
                }
                return .ready(
                    uptimeMilliseconds: uptime, dataOnDisk: info.dockerDataOnDisk,
                    shares: MorbShares.parseGuestShares(info.shares ?? ""))
            } catch {
                return .unreachable(error)
            }
        }
    }

    /// Synchronous wrapper around ``connectVsock(port:completion:)``.
    ///
    /// A descriptor that arrives after the deadline is closed rather than leaked.
    ///
    /// - Important: never call this from ``queue``; it blocks waiting on work that
    ///   has to run there.
    public func connectVsockBlocking(port: UInt32, timeout: TimeInterval) -> Result<Int32, Error> {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var value: Result<Int32, Error>?
            var abandoned = false
        }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)

        connectVsock(port: port) { result in
            box.lock.lock()
            if box.abandoned {
                box.lock.unlock()
                if case .success(let fd) = result { Darwin.close(fd) }
                return
            }
            box.value = result
            box.lock.unlock()
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            box.lock.lock()
            box.abandoned = true
            let late = box.value
            box.value = nil
            box.lock.unlock()
            if case .success(let fd)? = late { Darwin.close(fd) }
            return .failure(MorbError.timeout("vsock connect to port \(port) timed out"))
        }

        box.lock.lock()
        let value = box.value
        box.lock.unlock()
        return value ?? .failure(MorbError.vm("vsock connect produced no result"))
    }

    // MARK: - Configuration

    /// Assembles the `VZVirtualMachineConfiguration` for the current settings.
    ///
    /// Called on the VM queue for every boot and every restore; the device layout must
    /// be identical across a save/restore pair or the restore is rejected.
    private func buildConfiguration() throws -> VZVirtualMachineConfiguration {
        // Checked here rather than at the `VZVirtualMachine` call site because the
        // kernel does not return an error for a missing entitlement: it SIGKILLs the
        // process. Anything after this point could take the daemon down silently.
        guard MorbEntitlements.currentProcessHasVirtualization() else {
            throw MorbError.unsupported(
                "this binary is not signed with \(MorbEntitlements.virtualization); "
                    + MorbEntitlements.signHint)
        }

        let kernelURL = config.resolvedKernelURL
        guard FileManager.default.fileExists(atPath: kernelURL.path) else {
            throw MorbError.notFound(
                "guest kernel not found at \(kernelURL.path) — run scripts/fetch-kernel.sh to download it")
        }

        let configuration = VZVirtualMachineConfiguration()

        // CPU and memory, clamped into whatever the host actually permits.
        let requestedCPUs = max(1, config.resolvedCPUCount)
        configuration.cpuCount = min(
            max(requestedCPUs, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
            VZVirtualMachineConfiguration.maximumAllowedCPUCount)

        let requestedMemory = UInt64(max(1, config.memoryMiB)) * 1024 * 1024
        configuration.memorySize = min(
            max(requestedMemory, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
            VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        // Directory sharing. Planned before the boot loader because the share map
        // travels to the guest on the kernel command line: morbinit reads
        // /proc/cmdline and mounts each tag at its host path, which is what makes
        // `docker run -v $PWD:/app` resolve to the same bytes on both sides.
        let sharePlan = try planShares()

        // Boot loader. An initramfs, when one has been built, is what lets a guest
        // come up with nothing prepared on /dev/vda: morbinit runs as `/init` out of
        // RAM and only uses the disk opportunistically, for /var/lib/docker.
        let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
        let initrdURL = config.resolvedInitrdURL
        let bootMode: MorbConfig.BootMode
        if FileManager.default.fileExists(atPath: initrdURL.path) {
            bootLoader.initialRamdiskURL = initrdURL
            bootMode = .initramfs
        } else {
            bootMode = .disk
        }
        // The Mac's proxy configuration (UX-18), read fresh on every boot so a
        // proxy that changed since the last start — a laptop moving between a
        // corporate network and home — takes effect without an explicit
        // config edit. `config.toml` overrides win; see `effectiveGuestProxy`.
        let proxy = config.effectiveGuestProxy(host: HostProxyConfiguration.current())
        let cmdline = try config.resolvedKernelCmdline(for: bootMode, shares: sharePlan.shares, proxy: proxy)
        bootLoader.commandLine = cmdline
        configuration.bootLoader = bootLoader
        log.info("boot mode \(bootMode.rawValue)"
            + (bootMode == .initramfs ? ", initrd \(initrdURL.path)" : "")
            // Proxy tokens are redacted: a proxy URL can carry embedded
            // basic-auth credentials, and the console log is not a secret
            // store. Shares are plain paths and stay visible.
            + ", cmdline \"\(Self.redactingProxyTokens(cmdline))\""
            + (proxy.isEmpty ? "" : ", proxy configured for the guest"))
        if proxy.pacOnly {
            log.warn(
                "the Mac's proxy is configured via PAC/auto-discovery"
                    + (proxy.pacURLString.map { " (\($0))" } ?? "")
                    + " — Morbstack cannot evaluate a PAC script, so no proxy is being passed "
                    + "to the guest; set http_proxy/https_proxy in \(MorbPaths.configFile.path) "
                    + "to work around this")
        }

        // Serial console -> ~/.morbstack/logs/console.log
        configuration.serialPorts = [try makeConsolePort()]

        // Entropy and ballooning.
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        // Networking: NAT is enough for M1; bridged/vmnet comes later.
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        // Pin the MAC. VZVirtioNetworkDeviceConfiguration defaults to a *random*
        // locally-administered address, generated afresh on every call to this
        // method — and restoring a saved VM builds a brand-new configuration, so
        // a random MAC guarantees it no longer matches the one that was saved.
        // Virtualization.framework rejects the mismatch with a bare "permission
        // denied", which reads like an entitlement problem and is not one.
        // A fixed address also keeps the guest's DHCP lease (and therefore its
        // IP) stable across reboots. Safe as a constant because morbstackd is
        // singleton-locked, so there is only ever one of these VMs on a host.
        if let mac = VZMACAddress(string: Self.guestMACAddress) {
            network.macAddress = mac
        } else {
            log.warn("could not parse the pinned guest MAC \(Self.guestMACAddress); "
                + "falling back to a random one (suspend/resume will not work)")
        }
        configuration.networkDevices = [network]

        // Root disk.
        let diskURL = try ensureDiskImage()
        let attachment: VZDiskImageStorageDeviceAttachment
        do {
            attachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
        } catch {
            throw MorbError.io("could not attach \(diskURL.path): \(error.localizedDescription)")
        }
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]

        // vsock: guest control on 1024, Docker Engine API on 2375.
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        // Host directories over VirtioFS, one device per shared root.
        //
        // VZSingleDirectoryShare, not VZMultipleDirectoryShare: a multiple share
        // exposes its directories *by name* underneath one tag, so the guest would
        // mount a synthetic parent and every path inside it would gain a prefix —
        // exactly the translation this design exists to avoid. One device per root
        // means `mount -t virtiofs morbshare0 /Users` puts the host's /Users at the
        // guest's /Users, byte for byte.
        var directorySharingDevices: [VZDirectorySharingDeviceConfiguration] = []
        for share in sharePlan.shares {
            do {
                try VZVirtioFileSystemDeviceConfiguration.validateTag(share.tag)
            } catch {
                // Generated tags are `morbshare<n>`, so this is unreachable short of a
                // bug in the generator; report it as one rather than booting a guest
                // whose share list quietly lost an entry.
                throw MorbError.vm(
                    "generated VirtioFS tag \"\(share.tag)\" was rejected: \(error.localizedDescription)")
            }
            let device = VZVirtioFileSystemDeviceConfiguration(tag: share.tag)
            device.share = VZSingleDirectoryShare(
                directory: VZSharedDirectory(
                    url: URL(fileURLWithPath: share.path, isDirectory: true),
                    readOnly: share.readOnly))
            directorySharingDevices.append(device)
        }
        for skipped in sharePlan.skipped {
            log.info("not sharing \(skipped.path): \(skipped.reason)")
        }
        if sharePlan.shares.isEmpty {
            log.warn(
                "no host directories are shared with the guest; bind mounts such as "
                    + "`docker run -v $PWD:/app` will see an empty directory. Check "
                    + "shared_paths in \(MorbPaths.configFile.path)")
        } else {
            log.info(
                "sharing \(sharePlan.shares.count) host director"
                    + (sharePlan.shares.count == 1 ? "y" : "ies") + " over VirtioFS: "
                    + sharePlan.shares.map { "\($0.tag)=\($0.path)" }.joined(separator: ", "))
        }

        // Rosetta, when the user wants it and the host has it installed. The
        // guest mounts this tag at /run/rosetta and registers the interpreter with
        // binfmt_misc, which is what makes `--platform linux/amd64` work; see
        // guest/morbinit/src/binfmt.rs.
        //
        // Never installs anything. `RosettaSupport.install` puts a system
        // software-download dialog on screen, and morbstackd can start at login —
        // a daemon-triggered prompt would appear with no application behind it, on
        // a machine whose owner never asked for amd64 support. So a missing
        // runtime is only ever *reported* here; `morb doctor` shows the state and
        // `morb rosetta install` is the one thing allowed to act on it.
        if config.rosetta {
            let (share, reason) = RosettaSupport.makeShare()
            if let share {
                let device = VZVirtioFileSystemDeviceConfiguration(tag: RosettaSupport.shareTag)
                device.share = share
                // Appended, not assigned: the host shares above are already in
                // this list, and overwriting it would silently take every bind
                // mount away the moment Rosetta is installed.
                directorySharingDevices.append(device)
                log.info("Rosetta share attached as tag \"\(RosettaSupport.shareTag)\"")
            } else {
                log.warn("Rosetta: \(reason)")
            }
        } else {
            log.info("Rosetta disabled in \(MorbPaths.configFile.path); amd64 images will not run")
        }
        configuration.directorySharingDevices = directorySharingDevices

        do {
            try configuration.validate()
        } catch {
            throw MorbError.vm("invalid VM configuration: \(error.localizedDescription)")
        }
        return configuration
    }

    /// Creates the serial port that streams the guest console into the log file.
    private func makeConsolePort() throws -> VZVirtioConsoleDeviceSerialPortConfiguration {
        let url = MorbPaths.consoleLog
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil,
                                attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]) else {
                throw MorbError.io("could not create \(url.path)")
            }
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
        } catch {
            throw MorbError.io("could not open \(url.path) for writing: \(error.localizedDescription)")
        }
        closeConsole()
        consoleHandle = handle

        let port = VZVirtioConsoleDeviceSerialPortConfiguration()
        port.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: nil, fileHandleForWriting: handle)
        return port
    }

    /// Returns the root disk path, creating a sparse image on first run.
    private func ensureDiskImage() throws -> URL {
        let url = MorbPaths.diskImage
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return url }

        guard fm.createFile(atPath: url.path, contents: nil,
                            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]) else {
            throw MorbError.io("could not create \(url.path)")
        }
        // `truncate` on APFS produces a sparse file: the apparent size is the full
        // disk, but no blocks are allocated until the guest writes.
        let bytes = UInt64(effectiveDiskSizeGiB) * 1024 * 1024 * 1024
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: bytes)
        } catch {
            try? fm.removeItem(at: url)
            throw MorbError.io("could not size \(url.path): \(error.localizedDescription)")
        }
        log.info("created sparse disk image \(url.path) (\(effectiveDiskSizeGiB) GiB)")
        return url
    }

    // MARK: - VZVirtualMachineDelegate

    /// Called when the guest powers itself off.
    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        log.info("guest stopped")
        // releaseVirtualMachine also flushes the power-off observers a clean stop
        // parks in `whenGuestPowersOff`.
        releaseVirtualMachine(virtualMachine)
        setState(.stopped)
        flushWaiters(.failure(MorbError.vm("guest stopped before reaching a usable state")))
    }

    /// Called when the VM stops because of an error.
    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        let message = "guest stopped with error: \(error.localizedDescription)"
        log.error(message)
        releaseVirtualMachine(virtualMachine)
        setState(.error(message))
        flushWaiters(.failure(MorbError.vm(message)))
    }

    /// Called when a network attachment drops; logged so `morb doctor` users can see it.
    public func virtualMachine(_ virtualMachine: VZVirtualMachine,
                               networkDevice: VZNetworkDevice,
                               attachmentWasDisconnectedWithError error: Error) {
        log.warn("network attachment disconnected: \(error.localizedDescription)")
    }
}

/// The vsock ports Morbstack reserves inside the guest.
public enum MorbVsockPorts {
    /// `morbinit`'s MRB0 control channel.
    public static let guestControl: UInt32 = 1024
    /// The Docker Engine API, relayed to `~/.morbstack/run/docker.sock`.
    public static let dockerAPI: UInt32 = 2375
    /// Stream-dial: the host names a guest-local TCP port and gets a splice to it.
    ///
    /// See ``StreamDial`` for the one-line preamble that opens the exchange.
    public static let streamDial: UInt32 = 2376
    /// Kubernetes payload install channel: the host streams k3s/cri-dockerd
    /// binaries the guest does not already have. Mirrors the guest's
    /// `k8s::VSOCK_K8S_INSTALL_PORT`; see ``K8s`` for the transfer protocol.
    public static let k8sInstall: UInt32 = 2377
    /// Datagram-dial: framed UDP messages for published UDP container ports.
    ///
    /// The stream transport preserves each UDP payload with explicit frames; see
    /// ``DatagramDial`` for the handshake and data-plane contract.
    public static let datagramDial: UInt32 = 2378
    /// Bounded host-to-guest shared-file event receiver.
    public static let liveShareReceiver: UInt32 = 2381
    /// Host-side port-lease channel — the registry's one **guest-initiated**
    /// entry. The guest's userland-proxy wrapper (`morbstack-docker-proxy`,
    /// which stock dockerd execs per published port) connects out to the host
    /// on this port, asks for the Mac endpoint, and holds the connection for
    /// the proxy process's lifetime; EOF releases the Mac listener.
    public static let hostPortLease: UInt32 = 2382
}
