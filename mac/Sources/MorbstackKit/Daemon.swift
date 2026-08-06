// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Dispatch
import Foundation

/// A very small timestamped logger: one line per event, to stderr and to a file.
///
/// Deliberately not `os.Logger` — the daemon's log has to be greppable from a
/// terminal without `log stream`, and users need to be able to paste it into an issue.
public final class MorbLog {

    /// Severity of a log line.
    public enum Level: String, Sendable {
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    private let lock = NSLock()
    private let echoToStderr: Bool
    private var handle: FileHandle?
    private let formatter: DateFormatter

    /// Creates a logger.
    ///
    /// - Parameters:
    ///   - fileURL: Log file to append to; `nil` logs only to stderr. Failures to open
    ///     the file are non-fatal — logging must never take the daemon down.
    ///   - echoToStderr: Whether to also write to standard error.
    public init(fileURL: URL? = MorbPaths.daemonLog, echoToStderr: Bool = true) {
        self.echoToStderr = echoToStderr
        formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.timeZone = TimeZone.current

        guard let fileURL else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            _ = fm.createFile(atPath: fileURL.path, contents: nil,
                              attributes: [.posixPermissions: NSNumber(value: Int16(0o600))])
        }
        if let opened = try? FileHandle(forWritingTo: fileURL) {
            _ = try? opened.seekToEnd()
            handle = opened
        }
    }

    deinit {
        try? handle?.close()
    }

    /// Logs an informational line.
    public func info(_ message: String) { write(.info, message) }
    /// Logs a warning.
    public func warn(_ message: String) { write(.warn, message) }
    /// Logs an error.
    public func error(_ message: String) { write(.error, message) }

    /// Closes the underlying file handle. Called during shutdown.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }

    private func write(_ level: Level, _ message: String) {
        let line = "\(formatter.string(from: Date())) \(level.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        if echoToStderr {
            FileHandle.standardError.write(Data(line.utf8))
        }
        if let handle {
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}

/// Wires the whole mac-side stack together and owns the process lifetime.
///
/// Responsibilities:
/// * create `~/.morbstack` and load `config.toml`
/// * own the ``VMManager`` and the ``DockerProxy``
/// * serve the newline-JSON control protocol on `morbstackd.sock`
/// * suspend the VM after a configurable idle period
/// * shut down cleanly on `SIGTERM` / `SIGINT`
public final class Daemon {

    private let log: MorbLog
    private let config: MorbConfig
    private let vm: VMManager
    private let proxy: DockerProxy
    private let forwarder: PortForwarder
    /// Serves the guest userland-proxy wrapper's port-lease channel
    /// (vsock 2382). Held here so its EOF watchers outlive the closure
    /// registered with the VM manager.
    private let portLeaseServer: GuestPortLeaseServer
    /// Serves the guest's SSH-agent forward channel (vsock 2383, UX-19). Held
    /// for the same reason as ``portLeaseServer``: the closure registered with
    /// the VM manager must not outlive the object it calls into.
    private let sshAgentForwardServer: SSHAgentForwardServer
    private let liveShareTransport: MorbLiveShareTransport
    private let k8s: K8sManager
    private let controlServer: UnixSocketServer
    private let instanceLock: FileLock
    private let controlQueue = DispatchQueue(label: "dev.morbstack.control")
    private let clientQueue = DispatchQueue(label: "dev.morbstack.control.clients", attributes: .concurrent)
    /// Where the idle check's blocking Engine API query runs.
    ///
    /// Never `controlQueue`: that queue also serves the control socket and the signal
    /// sources, and blocking it for the length of a vsock round trip would make
    /// `morb status` — and Ctrl-C — wait on the guest.
    private let idleQueue = DispatchQueue(label: "dev.morbstack.idle", qos: .utility)
    /// Serialises port-forwarder start/stop, off the VM queue.
    ///
    /// ``PortForwarder/stop(reason:)`` closes listening sockets *synchronously* — that
    /// is the whole point of it, since the next thing anyone does with those ports is
    /// bind them again — and synchronous means briefly blocking. The VM queue is the
    /// one queue that must never block: every `docker` command in flight is waiting on
    /// it. Serial, so a fast running → stopped → running flap cannot reorder into a
    /// stop that lands after the start it preceded.
    private let forwarderQueue = DispatchQueue(label: "dev.morbstack.forwarder.lifecycle")
    /// Owns FSEvent/session orchestration independently of forwarded Docker
    /// ports: a blocked acknowledgement must never delay VM state callbacks.
    private let liveShareQueue = DispatchQueue(label: "dev.morbstack.live-share.lifecycle")
    /// Performs Kubernetes readiness reads away from the VM and idle queues.
    ///
    /// A k3s status read can wait for a guest-control timeout while a cluster is
    /// booting. That must not stall the VM callback that tears down listeners, or an
    /// unrelated idle check that needs the Docker API.
    private let kubernetesQueue = DispatchQueue(label: "dev.morbstack.k8s.reconciliation", qos: .utility)
    /// Monitors a booting or enabled cluster without making a listener look healthy
    /// before the guest says it is. One check is in flight at a time.
    private static let kubernetesReconciliationDelay: DispatchTimeInterval = .seconds(2)
    private static let kubernetesHealthCheckDelay: DispatchTimeInterval = .seconds(5)
    /// Queue-confined to ``forwarderQueue``. Invalidates status reads from an older
    /// VM lifecycle before they can re-bind a listener on a stopped VM.
    private var kubernetesForwardGeneration: UInt64 = 0

    /// How long the idle check gives the engine to list running containers.
    ///
    /// Short: this runs every 30 s on a stack nobody is using, and an engine that
    /// cannot answer in three seconds has told us something useful anyway.
    /// Internal rather than private so the budget-nesting test can include it in the
    /// arithmetic; it is part of the `suspend` chain, not just an idle-loop detail.
    static let idleContainerQueryTimeout: TimeInterval = 3

    /// How long the daemon will wait for a clean `stop` before answering with an error.
    ///
    /// Derived from the guest, not chosen here — see the nesting block at the `stop`
    /// case in ``handle(_:)`` for the full chain and the arithmetic. Named rather than
    /// inlined so ``LifecycleTests`` can assert the nesting still holds; the guest
    /// pins the other end of the same chain in
    /// `the_reply_budget_leaves_room_for_the_host_ack_timeout_above_it`.
    static let stopBudget: TimeInterval = 90

    /// How long the daemon will wait for a `suspend`. Below the CLI's timeout by
    /// enough to also absorb the pre-suspend container query that precedes it.
    static let suspendBudget: TimeInterval = 110

    /// What the `morb` CLI waits for any single daemon call — the outermost budget.
    ///
    /// Lives here, next to the budgets it has to contain, rather than as a default
    /// argument in `morb/main.swift`: the CLI's number is only meaningful relative to
    /// the daemon's, and a chain whose ends are declared in two files is a chain that
    /// drifts. `callDaemon` uses this as its default.
    public static let clientTimeout: TimeInterval = 120

    private var idleTimer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private let stateLock = NSLock()
    private var lastBusyAt = Date()
    private var shuttingDown = false
    /// Guards against a second idle check starting while the first is still asking the
    /// engine about containers.
    private var idleCheckInFlight = false

    /// Prepares every subsystem. Nothing is bound until ``run()``.
    ///
    /// - Throws: when the runtime directories cannot be created, or `config.toml` is invalid.
    public init(log: MorbLog? = nil) throws {
        // Belt and braces alongside SO_NOSIGPIPE: a daemon must never be killed
        // because a `docker` client hung up in the middle of a response.
        signal(SIGPIPE, SIG_IGN)
        try MorbPaths.ensureDirectories()
        let logger = log ?? MorbLog()
        self.log = logger
        self.config = try MorbConfig.load()
        if let runtime = try RuntimeArtifactStore.installBundledRuntimeIfPresent() {
            let disposition =
                runtime.wasReplaced
                ? "replaced (the installed payload did not match this bundle)"
                : (runtime.wasAlreadyInstalled ? "verified" : "installed")
            logger.info("runtime \(runtime.version) \(disposition) at \(runtime.directory.path)")
        }
        self.vm = VMManager(config: config, log: logger)
        let portForwarder = PortForwarder(
            vm: vm,
            log: logger,
            portExposure: config.allowLANPortPublishing ? .localNetwork : .loopbackOnly)
        self.forwarder = portForwarder
        self.proxy = DockerProxy(vm: vm, log: logger, forwarder: portForwarder)
        // The guest-initiated port-lease channel: stock dockerd's userland
        // proxy (the morbstack-docker-proxy wrapper) asks here, per published
        // port, for the Mac endpoint before its container start may succeed.
        // Registered once; VMManager re-installs it on every VM generation,
        // so a restart-policy container's lease request at guest boot always
        // finds a listener.
        let leaseServer = GuestPortLeaseServer(forwarder: portForwarder, log: logger)
        self.portLeaseServer = leaseServer
        vm.setGuestInitiatedConnectionHandler(port: MorbVsockPorts.hostPortLease) { fd in
            leaseServer.handleConnection(fd: fd)
        }
        // The guest-initiated SSH-agent forward channel (UX-19). Off by
        // default: `config.sshAgentForwarding` is this process's actual
        // `ssh_agent_forwarding` setting, loaded once at startup like every
        // other configuration value here — an edit needs a daemon restart to
        // take effect, same as the rest of `config.toml`. Registered the same
        // durable way as the lease server above — VMManager re-installs it on
        // every VM generation.
        let sshAgentForwardingEnabled = config.sshAgentForwarding
        let sshAgentServer = SSHAgentForwardServer(
            isEnabled: { sshAgentForwardingEnabled }, log: logger)
        self.sshAgentForwardServer = sshAgentServer
        vm.setGuestInitiatedConnectionHandler(port: MorbVsockPorts.sshAgentForward) { fd in
            sshAgentServer.handleConnection(fd: fd)
        }
        self.liveShareTransport = MorbLiveShareTransport(vm: vm, config: config, log: logger)
        self.k8s = K8sManager(vm: vm, log: logger)
        self.controlServer = UnixSocketServer(path: MorbPaths.controlSocket.path, queue: controlQueue)
        self.instanceLock = FileLock(path: MorbPaths.lockFile.path)

        controlServer.onConnection = { [weak self] fd in
            self?.serveControlClient(fd)
        }
        proxy.idleHandler = { [weak self] in
            self?.markIdle()
        }
        // A connection through a published port is use of the stack, exactly like a
        // `docker` command is. Without this the idle clock only ever moved for the
        // Docker socket, and a service that is being actively used through
        // `127.0.0.1:8080` and nothing else looked completely idle.
        forwarder.busyHandler = { [weak self] in
            self?.markBusy()
        }
        vm.onStateChange = { [weak self] state in
            guard let self else { return }
            self.markBusy()
            // Published ports only exist while there is a guest to forward them to.
            // This runs on the VM queue, which must never block, so the work goes to
            // `forwarderQueue` — closing a listener is synchronous by design.
            self.forwarderQueue.async { [weak self] in
                guard let self else { return }
                if state == .running {
                    self.forwarder.start()
                    self.beginKubernetesAPIServerReconciliationOnForwarderQueue()
                } else {
                    // Tearing the listeners down is right *while restore is unavailable
                    // on this host*: a suspend degrades to a stop, so the containers
                    // behind those ports are gone and a listener that still accepted
                    // would splice clients into nothing. If save/restore ever starts
                    // working here, this becomes wrong and the listeners should be held
                    // across the pause instead.
                    self.forwarder.stop(reason: "vm \(state.token)")
                    // Kubernetes is an independent loopback listener rather than a
                    // Docker-published port, so it needs the same lifecycle teardown
                    // explicitly. This also cancels a status read that began while a
                    // previous VM was still running.
                    self.k8s.cancelPodPortForwards(reason: "the VM \(state.token)")
                    self.stopKubernetesAPIServerForwardOnForwarderQueue()
                }
            }
            self.liveShareQueue.async { [weak self] in
                guard let self else { return }
                if state == .running {
                    self.liveShareTransport.start()
                } else {
                    self.liveShareTransport.stop(reason: "the VM \(state.token)")
                }
            }
        }
    }

    /// Binds both sockets, installs signal handling and starts the idle timer.
    ///
    /// Returns once everything is running; the caller is expected to call `dispatchMain()`.
    public func run() throws {
        // Fail before anything can touch Virtualization.framework. A VZVirtualMachine
        // created without com.apple.security.virtualization does not return an error:
        // the kernel SIGKILLs the process, so the user sees the daemon disappear with
        // an empty log and no idea that a signature is what is missing.
        guard MorbEntitlements.currentProcessHasVirtualization() else {
            throw MorbError.unsupported(
                "morbstackd is not signed with \(MorbEntitlements.virtualization), so it would be "
                    + "killed the moment it created a VM. To fix: \(MorbEntitlements.signHint).")
        }

        // Single-instance enforcement, before any unlink or bind. Probing the control
        // socket and then unlinking it is a time-of-check/time-of-use race: two
        // daemons starting together both see a dead socket, both unlink it, and the
        // second silently hijacks the endpoint. The kernel serialises `flock`, so
        // whoever loses finds out here instead of corrupting the winner's state.
        guard try instanceLock.acquire() else {
            throw MorbError.io(
                "another morbstackd is running (it holds \(instanceLock.path)); "
                    + "stop it before starting a second one")
        }
        // Belt and braces: a live daemon that predates the lock file still owns the
        // socket, and taking it from under them would break their clients.
        if UnixSocketClient.isAlive(path: MorbPaths.controlSocket.path) {
            instanceLock.release()
            throw MorbError.io("another morbstackd is already listening on \(MorbPaths.controlSocket.path)")
        }

        try controlServer.start()
        log.info("control socket listening at \(MorbPaths.controlSocket.path)")
        try proxy.start()

        installSignalHandlers()
        startIdleTimer()

        log.info("morbstackd \(MorbVersion.string) ready "
            + "(\(config.resolvedCPUCount) vCPU, \(config.memoryMiB) MiB, "
            + "auto-suspend \(config.autoSuspendMinutes == 0 ? "off" : "\(config.autoSuspendMinutes)m"))")
    }

    // MARK: - Control protocol

    /// Serves one control client: newline-delimited JSON requests, one reply each.
    private func serveControlClient(_ fd: Int32) {
        clientQueue.async { [weak self] in
            defer { Darwin.close(fd) }
            guard let self else { return }

            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = chunk.withUnsafeMutableBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return POSIXSocketSupport.readSome(fd, into: base, count: raw.count)
                }
                if n <= 0 { return }
                buffer.append(contentsOf: chunk[0..<n])
                if buffer.count > 1 << 20 {
                    _ = self.reply(fd, .failure("control request too large"))
                    return
                }

                while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<newlineIndex])
                    buffer = Data(buffer[buffer.index(after: newlineIndex)...])
                    if line.isEmpty { continue }
                    let response: DaemonResponse
                    do {
                        let request = try IPCCodec.decodeLine(DaemonRequest.self, from: line)
                        response = self.handle(request)
                    } catch {
                        response = .failure("\(error)")
                    }
                    guard self.reply(fd, response) else { return }
                }
            }
        }
    }

    /// Starts a readiness-gated loopback-forward reconciliation on the lifecycle
    /// queue. Safe from a concurrent control request because it only enqueues work.
    private func beginKubernetesAPIServerReconciliation() {
        forwarderQueue.async { [weak self] in
            self?.beginKubernetesAPIServerReconciliationOnForwarderQueue()
        }
    }

    private func beginKubernetesAPIServerReconciliationOnForwarderQueue() {
        kubernetesForwardGeneration &+= 1
        reconcileKubernetesAPIServerOnForwarderQueue(generation: kubernetesForwardGeneration)
    }

    /// Tears down the independent Kubernetes listener and invalidates every older
    /// status result. In particular, this prevents a slow read from a VM that has
    /// stopped or failed from publishing 127.0.0.1:6443 after the fact.
    private func stopKubernetesAPIServerForward() {
        forwarderQueue.async { [weak self] in
            self?.stopKubernetesAPIServerForwardOnForwarderQueue()
        }
    }

    private func stopKubernetesAPIServerForwardOnForwarderQueue() {
        kubernetesForwardGeneration &+= 1
        k8s.cancelPodPortForwards(reason: "Morbstack’s Kubernetes API forward stopped")
        k8s.forward.stop()
    }

    /// Reads the guest's cached Kubernetes readiness away from the lifecycle queue,
    /// then returns the decision to that queue before touching a listener.
    private func reconcileKubernetesAPIServerOnForwarderQueue(generation: UInt64) {
        kubernetesQueue.async { [weak self] in
            guard let self else { return }
            let status = try? self.k8s.status()
            self.forwarderQueue.async { [weak self] in
                guard let self, generation == self.kubernetesForwardGeneration else { return }

                switch K8sAPIForwardPublication.action(vmState: self.vm.state, status: status) {
                case .stop:
                    self.k8s.cancelPodPortForwards(reason: "Kubernetes is no longer ready")
                    self.k8s.forward.stop()

                case .awaitReadiness:
                    // An open listener is a promise that the endpoint can serve a
                    // client. Close it while control readiness is unknown or the
                    // guest explicitly says k3s is still starting, then retry.
                    self.k8s.cancelPodPortForwards(reason: "Kubernetes API readiness is no longer current")
                    self.k8s.forward.stop()
                    self.scheduleKubernetesAPIServerReconciliation(
                        generation: generation, after: Self.kubernetesReconciliationDelay)

                case .publish:
                    let wasPublished = self.k8s.forward.boundPort != nil
                    do {
                        let port = try self.k8s.forward.start()
                        if !wasPublished {
                            self.log.info(
                                "Kubernetes reports Ready; API forward published on 127.0.0.1:\(port)")
                        }
                        // Keep the listener reconciled after a later k3s failure or
                        // disable without relying on an unrelated VM state change.
                        self.scheduleKubernetesAPIServerReconciliation(
                            generation: generation, after: Self.kubernetesHealthCheckDelay)
                    } catch {
                        self.log.warn("could not publish the ready Kubernetes API server: \(error)")
                        self.scheduleKubernetesAPIServerReconciliation(
                            generation: generation, after: Self.kubernetesReconciliationDelay)
                    }
                }
            }
        }
    }

    private func scheduleKubernetesAPIServerReconciliation(
        generation: UInt64, after delay: DispatchTimeInterval
    ) {
        forwarderQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.kubernetesForwardGeneration else { return }
            self.reconcileKubernetesAPIServerOnForwarderQueue(generation: generation)
        }
    }

    /// One `k8s-*` command.
    ///
    /// Split into named commands rather than one `k8s` with an argument so
    /// ``MorbCommandPolicy`` can treat them differently: `k8s-enable` is allowed to
    /// bring a daemon up, because "give me a cluster" implies "give me an engine",
    /// while `k8s-status` and `k8s-describe` must never create the thing they were
    /// asked to describe.
    private func handleK8s(_ request: DaemonRequest) -> DaemonResponse {
        // `k8s-enable` is the one Kubernetes command whose explicit meaning includes
        // making an engine available.  The CLI is consequently allowed to launch a
        // stopped daemon for it.  Starting the daemon alone does not start its VM,
        // though; rejecting the very first request with "run morb start first" left
        // a new but idle daemon behind and contradicted that command policy.  Bring
        // the guest-control channel up before asking it to install or enable k3s.
        // The remaining `k8s-*` requests stay observations (or an explicit disable)
        // and must never make a VM appear merely to answer them.
        if request.cmd == "k8s-enable" {
            return enableKubernetes()
        }
        // A lease is daemon-process-local. These two operations need neither a
        // running VM nor a Kubernetes API query: status can truthfully say that no
        // child exists after a VM stop, and cancellation remains able to clean up a
        // child whose VM transition raced the ordinary lifecycle hooks. Neither can
        // start a daemon or a VM through the command policy.
        if request.cmd == "k8s-port-forward-status" {
            guard request.args == nil || request.args?.isEmpty == true else {
                return .failure("k8s-port-forward-status does not accept arguments")
            }
            if let lease = k8s.activePodPortForwardLease {
                return .success(Self.podPortForwardFields(for: lease))
            }
            return .success(["active": .bool(false)])
        }
        if request.cmd == "k8s-port-forward-cancel" {
            markBusy()
            let args = request.args ?? [:]
            guard Set(args.keys) == Set(["lease"]),
                  let rawLease = args["lease"],
                  let lease = UUID(uuidString: rawLease)
            else {
                return .failure(
                    "k8s-port-forward-cancel requires the exact lease ID returned by k8s-port-forward-start")
            }
            let cancelled = k8s.cancelPodPortForward(id: lease)
            return .success([
                "cancelled": .bool(cancelled),
                "lease": .string(lease.uuidString.lowercased()),
            ])
        }
        guard vm.state == .running else {
            return .failure(
                "the VM is \(vm.state.token). Kubernetes needs a running engine — "
                    + "run `morb start` first.")
        }
        do {
            switch request.cmd {
            case "k8s-status":
                return .success(try k8s.status().ipcFields)
            case "k8s-diagnose":
                // This is a read-only reconciliation of the guest's status with two
                // host facts only the daemon can see: the readiness-gated loopback
                // listener and Morbstack's own kubeconfig. It must not install,
                // restart, or otherwise "repair" a workload while diagnosing it.
                let status = try k8s.status()
                let diagnosis = K8s.Diagnosis(
                    status: status,
                    hostAPIServerPort: k8s.forward.boundPort,
                    kubeconfigExists: FileManager.default.fileExists(
                        atPath: K8s.defaultKubeconfigURL.path))
                return .success(diagnosis.ipcFields)
            case "k8s-describe":
                let args = request.args ?? [:]
                let allowed = Set(["kind", "name", "namespace"])
                guard Set(args.keys).isSubset(of: allowed),
                      let rawKind = args["kind"],
                      let kind = K8s.ResourceKind(rawValue: rawKind),
                      let name = args["name"], !name.isEmpty
                else {
                    return .failure(
                        "k8s-describe requires kind=pod|node and a selected resource name")
                }
                let namespace = args["namespace"]
                if kind == .pod, namespace?.isEmpty != false {
                    return .failure("k8s-describe requires a namespace for a selected Pod")
                }
                if kind == .node, namespace != nil {
                    return .failure("k8s-describe does not accept a namespace for a Node")
                }
                let reference = K8s.ResourceReference(kind: kind, name: name, namespace: namespace)
                return .success(try k8s.describe(reference).ipcFields)
            case "k8s-port-forward-start":
                markBusy()
                let args = request.args ?? [:]
                let allowed = Set(["namespace", "pod", "uid", "container", "local_port", "pod_port"])
                guard Set(args.keys).isSubset(of: allowed),
                      let namespace = args["namespace"], !namespace.isEmpty,
                      let pod = args["pod"], !pod.isEmpty,
                      let uid = args["uid"], !uid.isEmpty,
                      let rawPodPort = args["pod_port"],
                      let podPort = Self.strictPort(rawPodPort)
                else {
                    return .failure(
                        "k8s-port-forward-start requires exact namespace, pod, uid, and decimal pod_port arguments")
                }
                let container = args["container"]
                if container?.isEmpty == true {
                    return .failure("k8s-port-forward-start rejects an empty container name")
                }
                let localPort: Int?
                if let rawLocalPort = args["local_port"] {
                    guard let parsed = Self.strictPort(rawLocalPort) else {
                        return .failure(
                            "k8s-port-forward-start local_port must be a decimal TCP port from 1 through 65535")
                    }
                    localPort = parsed
                } else {
                    localPort = nil
                }
                let lease = try k8s.startPodPortForward(
                    K8sPodPortForwardRequest(
                        namespace: namespace,
                        pod: pod,
                        uid: uid,
                        container: container,
                        localPort: localPort,
                        podPort: podPort))
                return .success(Self.podPortForwardFields(for: lease))
            case "k8s-disable":
                markBusy()
                let status = try k8s.disable()
                stopKubernetesAPIServerForward()
                return .success(status.ipcFields)
            case "k8s-kubeconfig":
                markBusy()
                let merge = request.args?["merge"] == "true"
                let switchContext = request.args?["switch_context"] == "true"
                if merge {
                    let outcome = try k8s.mergeIntoUserKubeconfig(switchContext: switchContext)
                    return .success([
                        "merged": .bool(true),
                        "path": .string(outcome.path),
                        "backup": outcome.backupPath.map { AnyCodableValue.string($0) } ?? .null,
                        "replaced_existing": .bool(outcome.replacedExisting),
                        "switched_context": .bool(outcome.switchedContext),
                        "context": .string(K8s.contextName),
                    ])
                }
                let (path, port) = try k8s.writeHostKubeconfig()
                return .success([
                    "merged": .bool(false),
                    "path": .string(path.path),
                    "host_port": .int(port),
                    "context": .string(K8s.contextName),
                ])
            default:
                return .failure("unknown kubernetes command `\(request.cmd)`")
            }
        } catch {
            return .failure("\(error)")
        }
    }

    /// Rejects ambiguous spellings before a request reaches the coordinator. The
    /// CLI and IPC use only canonical decimal TCP ports: no zero, signs, spaces,
    /// leading zeroes, ranges, or transport suffixes are silently reinterpreted.
    private static func strictPort(_ raw: String) -> Int? {
        guard !raw.isEmpty,
              raw.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let port = Int(raw),
              (1...65535).contains(port),
              raw == String(port)
        else {
            return nil
        }
        return port
    }

    /// The control surface intentionally returns operational lease facts only. In
    /// particular it never reflects private kubeconfig material, child arguments,
    /// helper output, process IDs, a Kubernetes API address, or arbitrary Pod data.
    private static func podPortForwardFields(
        for lease: K8sPodPortForwardLease
    ) -> [String: AnyCodableValue] {
        [
            "active": .bool(true),
            "lease": .string(lease.id.uuidString.lowercased()),
            "namespace": .string(lease.request.namespace),
            "pod": .string(lease.request.pod),
            "container": lease.request.container.map { AnyCodableValue.string($0) } ?? .null,
            "local_address": .string("127.0.0.1"),
            "local_port": .int(lease.localPort),
            "pod_port": .int(lease.request.podPort),
        ]
    }

    /// Makes the engine control-ready, then performs the user-requested Kubernetes
    /// enablement.  This is intentionally not used for status, diagnosis, describe,
    /// disable, or kubeconfig requests: those remain non-starting observations or
    /// actions against an already-running engine.
    ///
    /// `VMManager.start` completes when the hypervisor starts, which is earlier than
    /// the guest control endpoint.  `ensureRunning` is the stronger contract needed
    /// here: the subsequent `K8sManager.enable` can safely query/install the payload
    /// rather than racing a just-booted guest and reporting a misleading failure.
    private func enableKubernetes() -> DaemonResponse {
        markBusy()

        let semaphore = DispatchSemaphore(value: 0)
        final class ResultBox: @unchecked Sendable {
            var response: DaemonResponse?
        }
        let box = ResultBox()

        vm.ensureRunning(timeout: Daemon.clientTimeout) { [weak self] result in
            guard let self else {
                box.response = .failure("Morbstack service stopped while enabling Kubernetes")
                semaphore.signal()
                return
            }

            // `ensureRunning` completes on the VM queue.  Payload hashing and the
            // install protocol can wait on guest I/O, so move that work off the
            // lifecycle queue before synchronously replying to the control client.
            self.kubernetesQueue.async {
                let response: DaemonResponse
                switch result {
                case .failure(let error):
                    response = .failure("could not start the engine for Kubernetes: \(error)")
                case .success:
                    do {
                        let status = try self.k8s.enable()
                        self.beginKubernetesAPIServerReconciliation()
                        response = .success(status.ipcFields)
                    } catch {
                        response = .failure("could not enable Kubernetes: \(error)")
                    }
                }
                box.response = response
                semaphore.signal()
            }
        }

        // The outer CLI budget for `k8s enable` is five minutes: one bounded guest
        // boot plus a one-time, digest-verified payload transfer may legitimately
        // take longer than an ordinary lifecycle operation.  If a caller gave up,
        // returning an error here remains truthful; no success is fabricated.
        if semaphore.wait(timeout: .now() + 300) == .timedOut {
            return .failure("Kubernetes enablement did not complete within 300s")
        }
        return box.response ?? .failure("Kubernetes enablement ended without a result")
    }

    @discardableResult
    private func reply(_ fd: Int32, _ response: DaemonResponse) -> Bool {
        guard let data = try? IPCCodec.encodeLine(response) else { return false }
        return POSIXSocketSupport.writeAll(fd, data)
    }

    /// Executes one control command. Blocking commands wait for the VM operation.
    private func handle(_ request: DaemonRequest) -> DaemonResponse {
        log.info("control: \(request.cmd)")
        switch request.cmd {
        case "version":
            return .success([
                "version": .string(MorbVersion.string),
                "component": .string("morbstackd"),
            ])

        case "rosetta":
            // Read-only, and deliberately NOT auto-starting: asking whether amd64
            // translation is available must never be the thing that boots a VM.
            // `MorbCommandPolicy` gives that for free (only start/resume auto-start),
            // and `RosettaPolicyTests` pins it so a future edit to that set cannot
            // quietly change it.
            //
            // Three independent facts, from three places, reconciled by
            // `RosettaStatus.make`: the host framework, morb.toml, and the running
            // guest's MRB0 `info` reply. They routinely disagree — the share is a
            // device attached at VM configuration time, so installing Rosetta or
            // enabling it in config does nothing until the VM restarts — and saying
            // which one is the blocker is the entire value of this command.
            return .success(rosettaPayload())

        case "rosetta_install":
            // Mutating, interactive, and slow: it puts Apple's own system
            // installation dialog on screen and downloads a runtime. It must only
            // ever run because a human asked for it by name, which is why it is its
            // own command rather than a fallback inside `rosetta` or a fix-up
            // inside the VM start path.
            return handleRosettaInstall()

        case "status":
            markBusyIfActive()
            let forwards = forwarder.activeForwards
            let failedForwards = forwarder.failedForwards
            let liveShareBridge = liveShareBridgeDiagnostic()
            // A successful disk-growth transaction commits `disk_size_gib` before it
            // clears its recovery journal. Reload this one field so the daemon never
            // reports its startup snapshot after a successful transaction.
            let configuredDiskGiB = (try? MorbConfig.load())?.diskSizeGiB ?? config.diskSizeGiB
            let diskCapacity = MorbDiskCapacity.inspect(configuredGiB: configuredDiskGiB)
            let guestDiskResize = MorbDiskResize.GuestCapability(
                wireValue: vm.guestDiskResize ?? vm.lastGuestDiskResize)
            let diskResize: MorbDiskResize.Diagnostic
            do {
                if let journal = try MorbDiskGrowth.loadJournal() {
                    // A RAW image at the target length is not enough. Prioritize the
                    // journal over capacity facts so a crash cannot masquerade as a
                    // completed filesystem resize.
                    diskResize = MorbDiskResize.recoveryDiagnostic(
                        journal: journal, guestCapability: guestDiskResize)
                } else {
                    diskResize = MorbDiskResize.diagnose(
                        capacity: diskCapacity,
                        vmState: vm.state,
                        guestCapability: guestDiskResize)
                }
            } catch {
                diskResize = MorbDiskResize.Diagnostic(
                    state: .capacityUnavailable,
                    guestCapability: guestDiskResize,
                    currentBytes: diskCapacity.currentBytes,
                    targetBytes: diskCapacity.configuredBytes,
                    summary: "Morbstack cannot read the disk-growth recovery journal, so it will not alter the disk: \(error)")
            }
            return .success([
                "failed_port_forwards": .array(failedForwards.map { AnyCodableValue.string($0) }),
                "state": .string(vm.state.token),
                "vm_state": .string(vm.state.description),
                "guest_control": .string(vm.isGuestControlReady ? "ready" : "not ready"),
                "docker_ready": .bool(vm.isDockerReady),
                // The protocol's compatibility probe, surfaced rather than merely
                // decoded. `null` while no guest has answered `info` on this boot;
                // `morb status` and `morb doctor` compare it against
                // `MorbVersion.minimumCompatibleMorbinit`.
                "morbinit_version": vm.guestMorbinitVersion.map { AnyCodableValue.string($0) }
                    ?? .null,
                // `null` rather than `false` when the guest has not said: "we do not
                // know" and "the data is on a tmpfs and will not survive a stop" are
                // very different things to tell somebody about their images.
                "docker_data_on_disk": vm.dockerDataOnDisk.map { AnyCodableValue.bool($0) } ?? .null,
                // The shares the VM was configured with, and — as a flat encoded
                // string, in the same wire form the guest sent it — what the guest
                // did with each. `morb doctor` decodes the second one; a caller that
                // only wants to know what is shared can read the first.
                "shares": .array(vm.shares.map { AnyCodableValue.string($0.path) }),
                "guest_shares": .string(
                    MorbShares.encodeGuestShares(vm.guestShareStates)),
                "active_connections": .int(proxy.activeConnections),
                "forwarded_connections": .int(forwarder.activeConnections),
                "port_forwards": .array(forwards.map { AnyCodableValue.string($0) }),
                "version": .string(MorbVersion.string),
                "docker_socket": .string(proxy.socketPath),
                "cpus": .int(config.resolvedCPUCount),
                "memory_mib": .int(config.memoryMiB),
                "auto_suspend_minutes": .int(config.autoSuspendMinutes),
                // How many configured host directories the guest does not have
                // mounted. The app polls `status` anyway, so the whole shares warning
                // costs one integer already on the wire. `null`, never `0`, when the
                // guest has not reported: "nothing is wrong" and "nothing is known"
                // must not render the same.
                "shares_degraded": sharesDegradedCount().map { AnyCodableValue.int($0) } ?? .null,
                // This is deliberately a negative capability/status report until a
                // guest endpoint can receive the bounded contract. It never starts an
                // FSEvents watcher merely because `status` was read.
                "live_share_bridge": .object(liveShareBridge.ipcFields),
                // A readiness report only. In particular it does not turn a larger
                // configured value into a host file resize while `status` is read.
                "disk_resize": .object(diskResize.ipcFields),
                // What the running guest reports it actually launched dockerd
                // with (UX-18) — `null` while no guest has answered `info` on
                // this boot, distinct from the empty string the guest itself
                // sends for "no proxy of this kind". `morb doctor` compares
                // this against what the *next* boot would configure.
                "guest_http_proxy": vm.guestHTTPProxy.map { AnyCodableValue.string($0) } ?? .null,
                "guest_https_proxy": vm.guestHTTPSProxy.map { AnyCodableValue.string($0) } ?? .null,
                "guest_no_proxy": vm.guestNoProxy.map { AnyCodableValue.string($0) } ?? .null,
            ])

        case "shares":
            // Read-only, and deliberately answerable while the VM is stopped: "these
            // three roots are configured and none is mounted because nothing is
            // running" is the exact state a user is in when a bind mount comes up
            // empty. `markBusyIfActive` is not called for the same reason `status`
            // does not count as activity — asking a question must not postpone an
            // idle suspend.
            let liveShareBridge = liveShareBridgeDiagnostic()
            return .success([
                "shares": MorbShareSurface.encode(liveShares()),
                "live_share_bridge": .object(liveShareBridge.ipcFields),
            ])

        case "k8s-status", "k8s-diagnose", "k8s-describe", "k8s-enable", "k8s-disable", "k8s-kubeconfig",
             "k8s-port-forward-start", "k8s-port-forward-status", "k8s-port-forward-cancel":
            return handleK8s(request)

        case "start":
            markBusy()
            return awaitVMOperation("start") { self.vm.start(completion: $0) }

        case "disk-grow":
            guard let rawTarget = request.args?["target_gib"],
                  let targetGiB = Int(rawTarget), targetGiB > 0
            else {
                return .failure("disk-grow requires a positive target_gib argument")
            }
            // VMManager owns both the stopped-state proof and the final preserving
            // config write. Saving first made a running/refused CLI request describe a
            // larger disk that was never grown.
            // The proxy stays closed through both host mutation and the guest proof;
            // queued Docker clients are released by VMManager only after completion.
            proxy.beginOrderlyShutdown()
            defer { proxy.endOrderlyShutdown() }
            markBusy()
            var response = awaitVMOperation("disk-grow", timeout: 110) {
                self.vm.growDisk(targetGiB: targetGiB, completion: $0)
            }
            if response.ok {
                response.data?["target_gib"] = .int(targetGiB)
                response.data?["target_bytes"] = .int(Int(MorbDiskCapacity.configuredBytes(forGiB: targetGiB)))
            }
            return response

        case "stop":
            markBusy()
            let force = request.args?["force"].map { $0 == "true" || $0 == "1" } ?? false
            proxy.beginOrderlyShutdown()
            defer { proxy.endOrderlyShutdown() }
            // Budget must clear the clean-shutdown worst case: up to
            // `VMManager.shutdownAckTimeout` (65 s) for the guest's ack, plus
            // `guestPowerOffTimeout` (5 s) waiting for it to halt itself, plus
            // vsock connect and teardown overhead. The `morb` CLI waits 120 s,
            // so this replies with a real error before the client gives up.
            //
            // BUDGETS NEST AND THE NESTING IS LOAD-BEARING — an outer layer that
            // gives up first tears the VM down with the guest's dirty pages still
            // outstanding, which is the data-loss bug this whole handshake exists
            // to prevent. Outermost last, every step strictly larger:
            //
            //   guest reply cap    54 s  (morbinit control::SHUTDOWN_REPLY_TIMEOUT,
            //                             itself derived: 2 * (10 s + 2 s) + 30 s)
            //     < host ack       65 s  (VMManager.shutdownAckTimeout)
            //       < this         90 s
            //         < CLI       120 s  (callDaemon's default in morb/main.swift)
            //
            // The 90 is sized from the inside out, not picked: worst case here is
            // ack (65) + power-off wait (5) = 70 s of guest-driven waiting, and the
            // remaining 20 s absorbs vsock connect, teardown and queue hops while
            // still leaving 30 s before the CLI stops listening.
            return awaitVMOperation("stop", timeout: Daemon.stopBudget) {
                self.vm.stop(force: force, completion: $0)
            }

        case "suspend":
            markBusy()
            // Asked *before* the suspend, because afterwards there is no engine left to
            // ask. On a host where restore works this is merely informative; on one
            // where it does not — which is every host Morbstack has met so far — a
            // suspend is a stop wearing a different name, and the containers really do
            // die. Saying so in the reply is the difference between a surprising
            // outcome and an expected one.
            let running = vm.state == .running
                ? runningContainerCount(timeout: Daemon.idleContainerQueryTimeout)
                : nil
            if let running, running > 0 {
                log.info(
                    vm.isSaveRestoreBroken
                        ? "suspend requested with \(running) running container(s); "
                            + "suspend-to-disk is unavailable on this host, so this is a stop and "
                            + "they will be stopped with the VM"
                        : "suspend requested with \(running) running container(s); "
                            + "they go with the VM")
            }
            proxy.beginOrderlyShutdown()
            defer { proxy.endOrderlyShutdown() }
            // 110, not 120. The container query above can spend up to
            // `idleContainerQueryTimeout` before this even starts, and the whole reply
            // still has to beat the CLI's 120 s so the user sees a real error rather
            // than a client-side timeout. Nesting, outermost last:
            //   query (3 s) + this (110 s) < CLI (120 s)
            // and inside it, when suspend degrades to a stop on a host that cannot
            // restore, the same ladder the `stop` case documents has to fit:
            //   guest reply cap (54 s) < shutdownAckTimeout (65 s) < this (110 s)
            var response = awaitVMOperation("suspend", timeout: Daemon.suspendBudget) {
                self.vm.suspend(completion: $0)
            }
            if response.ok, let running, running > 0 {
                // Report what actually happened, and do not overclaim. Reaching
                // `.suspended` means the state blob was *written*; it does not mean it
                // can be read back. Virtualization.framework accepts
                // `saveMachineStateTo` for a direct-kernel guest on hosts that then
                // refuse the restore, and the only way to find out is to try — at
                // which point `resumeOnQueue` discards the blob and cold-boots, taking
                // the containers with it. So a save is reported as conditional until
                // a restore has actually failed here, after which it is reported as
                // the stop it has become.
                let saved = vm.state == .suspended
                response.data?["containers_stopped"] = .int(saved ? 0 : running)
                response.data?["containers_suspended"] = .int(saved ? running : 0)
                response.data?["note"] = .string(
                    saved
                        ? "\(running) running container(s) were saved with the VM; they come back "
                            + "only if the restore succeeds, and are lost to a cold boot if it does not"
                        : "\(running) running container(s) were stopped with the VM")
                log.info(
                    saved
                        ? "suspend complete: \(running) running container(s) saved with the VM "
                            + "(they survive only if the next restore succeeds)"
                        : "suspend complete: \(running) running container(s) were stopped with the VM")
            }
            return response

        case "reset-disk":
            // This must be a VM-owner operation, not a CLI state check followed by an
            // unlink. `VMManager` serializes the verification and deletion with every
            // Virtualization.framework transition, so a Docker client can either start
            // before this request (causing a safe refusal) or after it (booting a fresh
            // disk), but never attach the image while it is being removed.
            proxy.beginOrderlyShutdown()
            defer { proxy.endOrderlyShutdown() }
            let hadDisk = FileManager.default.fileExists(atPath: MorbPaths.diskImage.path)
            let hadSavedState = FileManager.default.fileExists(atPath: MorbPaths.vmState.path)
            var response = awaitVMOperation("reset-disk", timeout: 15) {
                self.vm.resetDisk(completion: $0)
            }
            if response.ok {
                response.data?["deleted"] = .bool(hadDisk)
                response.data?["saved_state_deleted"] = .bool(hadSavedState)
                response.data?["disk"] = .string(MorbPaths.diskImage.path)
            }
            return response

        case "resume":
            markBusy()
            return awaitVMOperation("resume", timeout: 120) { self.vm.resume(completion: $0) }

        default:
            return .unknownCommand(request.cmd)
        }
    }

    /// The daemon's live view of directory sharing: one row per share the VM was
    /// configured with, carrying what the guest said about it.
    ///
    /// Only the two facts the daemon alone has are filled in here — the guest's mount
    /// verdict and the tag the guest was actually told. The configured spine, the
    /// skip reasons and the rendering all belong to ``MorbShareSurface`` and are
    /// applied by whichever front end asked, so `morb shares` and the app cannot
    /// disagree about what a row means.
    ///
    /// A path the guest reports that the plan does not contain is appended rather
    /// than dropped: it means the running guest predates an edit to `shared_paths`,
    /// and "your config says something the engine has not picked up" is the most
    /// useful thing anyone could be told at that moment.
    private func liveShares() -> [MorbShareState] {
        let guestStates = vm.guestShareStates
        // `vm.shares` is populated when a configuration is built, so before the first
        // boot attempt it is empty; fall back to planning, which is the same pure
        // function and gives an honest answer on a stopped stack.
        var planned = vm.shares
        if planned.isEmpty { planned = (try? vm.sharePlan())?.shares ?? [] }

        var rows: [MorbShareState] = []
        var reported = guestStates
        for share in planned {
            let state = reported.removeValue(forKey: share.path)
            rows.append(
                MorbShareState(
                    path: share.path,
                    tag: share.tag,
                    readOnly: share.readOnly,
                    configured: true,
                    mounted: state == .mounted,
                    guestPath: share.path,
                    rootWritable: MorbShares.isWritable(share.path),
                    error: shareError(for: state)))
        }
        for (path, state) in reported.sorted(by: { $0.key < $1.key }) {
            rows.append(
                MorbShareState(
                    path: path, configured: false, mounted: state == .mounted,
                    guestPath: path,
                    error: state == .mounted
                        ? "the running guest has this mounted but it is no longer in "
                            + "shared_paths; restart the engine to apply the change"
                        : shareError(for: state)))
        }
        return rows
    }

    /// The live-share notification status.  The transport owns activation and
    /// teardown; answering status only reads its current immutable lifecycle fact.
    private func liveShareBridgeDiagnostic() -> MorbLiveShareBridge.Diagnostic {
        liveShareTransport.diagnostic()
    }

    /// The one-line reason a share is not usable, or `nil` when it is.
    private func shareError(for state: MorbShares.GuestMountState?) -> String? {
        switch state {
        case .mounted:
            return nil
        case .failed:
            return "the guest could not mount it — see \(MorbPaths.consoleLog.path)"
        case nil:
            // Two very different causes, and the daemon cannot tell them apart from
            // here: a guest that never saw the share, and a guest that has not booted.
            return vm.isGuestControlReady
                ? "the guest did not report this share; it may predate a change to "
                    + "shared_paths — restart the engine"
                : "the engine is not running, so nothing is mounted yet"
        }
    }

    /// How many configured roots the guest does not have, or `nil` when there is no
    /// guest to have asked.
    private func sharesDegradedCount() -> Int? {
        guard vm.isGuestControlReady else { return nil }
        return liveShares().filter(\.isDegraded).count
    }

    /// The `rosetta` reply: the architect-fixed five fields plus the two detail
    /// fields `doctor` and the app need to pick a remedy.
    ///
    /// `active_in_guest` and `binfmt_registered` are `null` rather than `false`
    /// when no guest has answered. The distinction matters: "the VM is not
    /// running so we cannot know" and "the VM is running and Rosetta is broken"
    /// call for completely different advice, and collapsing them into `false`
    /// is how a status display ends up telling somebody to reinstall Rosetta
    /// when they simply have not started the VM.
    private func rosettaPayload() -> [String: AnyCodableValue] {
        let host = RosettaSupport.state
        // "Has any guest answered" is asked of the recorded fields, not of the VM
        // state token, because morbinit answers `info` as soon as it is up — well
        // before dockerd is ready (binfmt lands ~220ms in, dockerd ~730ms). Asking
        // the token would report "unknown" through the whole of that window.
        let guestAnswered = vm.guestBinfmtAmd64 != nil || vm.guestRosetta != nil
        // Reconciled by the same surface type the CLI and the app render, so the
        // three of us cannot reach different verdicts from identical inputs.
        let live: MorbRosettaState? = guestAnswered
            ? MorbRosettaState(
                installed: host == .installed,
                enabledInConfig: config.rosetta,
                activeInGuest: vm.guestRosetta ?? false,
                binfmtRegistered: (vm.guestBinfmtAmd64 ?? "none") != "none",
                note: nil,
                supported: host != .notSupported && host != .unknown)
            : nil
        let status = MorbShareSurface.rosetta(
            host: host, enabledInConfig: config.rosetta, live: live)
        return [
            "installed": .bool(status.installed),
            "enabled_in_config": .bool(status.enabledInConfig),
            "active_in_guest": status.activeInGuest.map { AnyCodableValue.bool($0) } ?? .null,
            "binfmt_registered": status.binfmtRegistered.map { AnyCodableValue.bool($0) } ?? .null,
            "note": (status.note ?? status.remedy).map { AnyCodableValue.string($0) } ?? .null,
            "availability": .string(status.availability.rawValue),
            "host_state": .string(host.rawValue),
            // Which interpreter actually won — `rosetta`, `qemu`, or `none`.
            // `binfmt_registered` alone cannot distinguish Rosetta from the qemu
            // fallback, and those have very different performance stories.
            "binfmt_amd64": vm.guestBinfmtAmd64.map { AnyCodableValue.string($0) } ?? .null,
        ]
    }

    /// Runs the Rosetta installation, then reports the state it left behind.
    ///
    /// Refuses early when there is nothing to do, so the caller gets a clear
    /// message rather than a system dialog that cannot succeed. The reply
    /// carries the full `rosetta` payload afterwards so the CLI can print the
    /// new state — including the "now restart the VM" note, which is the step
    /// people forget.
    private func handleRosettaInstall() -> DaemonResponse {
        let before = RosettaSupport.state
        guard before.isInstallable else {
            switch before {
            case .installed:
                var payload = rosettaPayload()
                payload["note"] = .string("Rosetta for Linux is already installed.")
                return .success(payload)
            case .notSupported, .unknown:
                return .failure(
                    "Rosetta for Linux is not supported on this Mac, so amd64 images "
                        + "cannot be translated")
            case .notInstalled:
                return .failure("unreachable: notInstalled is installable")
            }
        }
        log.info("rosetta_install: user asked for Rosetta for Linux; invoking the installer")
        do {
            try RosettaSupport.install()
        } catch {
            log.error("rosetta_install failed: \(error)")
            return .failure("\(error)")
        }
        log.info("rosetta_install: complete")
        return .success(rosettaPayload())
    }

    /// Bridges a completion-handler VM operation into the synchronous control reply.
    private func awaitVMOperation(
        _ name: String,
        timeout: TimeInterval = 90,
        _ operation: (@escaping (Result<Void, Error>) -> Void) -> Void
    ) -> DaemonResponse {
        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var result: Result<Void, Error>? }
        let box = Box()
        operation { result in
            box.result = result
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            return .failure("\(name) did not complete within \(Int(timeout))s")
        }
        switch box.result {
        case .success, .none:
            return .success(["state": .string(vm.state.token), "vm_state": .string(vm.state.description)])
        case .failure(let error):
            return .failure("\(error)")
        }
    }

    // MARK: - Auto-suspend

    private func markBusy() {
        stateLock.lock()
        lastBusyAt = Date()
        stateLock.unlock()
    }

    private func markBusyIfActive() {
        guard proxy.activeConnections > 0 || forwarder.activeConnections > 0 else { return }
        markBusy()
    }

    private func markIdle() {
        // The idle clock starts when the last relay drops, not when it began.
        markBusy()
        log.info("docker relays idle")
    }

    private func startIdleTimer() {
        guard config.autoSuspendMinutes > 0 else {
            log.info("auto-suspend disabled")
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.checkIdle()
        }
        stateLock.lock()
        idleTimer = timer
        stateLock.unlock()
        timer.resume()
    }

    /// Asks the engine how many containers are running, or `nil` when it cannot say.
    ///
    /// `nil` is not zero and callers must not treat it as such. A guest that has not
    /// finished booting, a dockerd that is restarting, a vsock connect that times out
    /// — none of those are evidence that the user has nothing running, and the whole
    /// point of the question is to avoid destroying containers we did not know about.
    ///
    /// - Important: blocking. Never call from the VM queue or ``controlQueue``'s timer
    ///   handler without hopping off it first.
    private func runningContainerCount(timeout: TimeInterval) -> Int? {
        guard vm.isDockerReady else { return nil }
        do {
            return try forwarder.runningContainerCount(timeout: timeout)
        } catch {
            log.warn("could not ask the engine for running containers: \(error)")
            return nil
        }
    }

    private func checkIdle() {
        // `shuttingDown` is written from whichever thread delivered the signal and
        // read from the timer's queue, so the read needs the lock as much as the
        // write does.
        stateLock.lock()
        let stopping = shuttingDown
        let alreadyChecking = idleCheckInFlight
        stateLock.unlock()
        guard !stopping, !alreadyChecking else { return }
        // A live connection through a published port is just as much "in use" as a
        // `docker` command is; suspending underneath one would drop it.
        guard proxy.activeConnections == 0, forwarder.activeConnections == 0,
              vm.state == .running
        else { return }
        stateLock.lock()
        let idleFor = Date().timeIntervalSince(lastBusyAt)
        let overBudget = idleFor >= Double(config.autoSuspendMinutes) * 60
        if overBudget { idleCheckInFlight = true }
        stateLock.unlock()
        guard overBudget else { return }

        // The connection counts say nothing is *talking* to the stack. That is not the
        // same as nothing running in it, and the engine is the only thing that knows
        // the difference — so ask it, off this queue, before doing anything drastic.
        idleQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.stateLock.lock()
                self.idleCheckInFlight = false
                self.stateLock.unlock()
            }
            self.suspendIfNothingIsRunning(idleFor: idleFor)
        }
    }

    /// The second half of ``checkIdle()``, off the control queue and allowed to block.
    private func suspendIfNothingIsRunning(idleFor: TimeInterval) {
        // Docker Desktop semantics, and the architect's ruling: a VM with running
        // containers is not idle. Nothing may be *connected* to a container for hours
        // — a queue worker, a database nobody has queried today — and stopping it
        // because of that is data loss dressed up as power management. It is worse
        // here than on Docker Desktop, because this host cannot restore a saved VM:
        // the "suspend" degrades to a stop and the containers die rather than pause.
        switch runningContainerCount(timeout: Daemon.idleContainerQueryTimeout) {
        case .some(let count) where count > 0:
            log.info("idle timer: \(count) running containers, not suspending")
            // Reset the clock too, so the next check is a fresh 30 s away rather than
            // re-asking the engine on every single tick for as long as they run.
            markBusy()
            return
        case .none:
            log.info("idle timer: could not confirm the container list; not suspending")
            markBusy()
            return
        case .some:
            break  // nothing running; the suspend may go ahead
        }

        // Re-check the cheap preconditions: the engine query took a moment, and a
        // client can have arrived inside it.
        guard proxy.activeConnections == 0, forwarder.activeConnections == 0,
              vm.state == .running
        else { return }

        log.info("idle for \(Int(idleFor))s with no running containers; suspending")
        // `ifStillIdle` is re-evaluated on the VM queue immediately before the guest
        // is paused. Between this timer firing and the hypervisor acting, a `docker`
        // command can easily arrive and get counted; without the re-check we would
        // pause a VM that a client is already waiting on.
        vm.suspend(
            ifStillIdle: { [weak self] in
                guard let self else { return false }
                guard self.proxy.activeConnections == 0, self.forwarder.activeConnections == 0 else {
                    self.log.info("auto-suspend abandoned: a client connected first")
                    return false
                }
                return true
            },
            completion: { [weak self] result in
                guard let self else { return }
                if case .failure(let error) = result {
                    self.log.warn("auto-suspend failed: \(error)")
                }
                self.markBusy()
            })
    }

    // MARK: - Signals and shutdown

    private func installSignalHandlers() {
        for number in [SIGTERM, SIGINT] {
            // The dispatch source only fires if the default disposition is suppressed.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: controlQueue)
            source.setEventHandler { [weak self] in
                self?.shutdown(reason: number == SIGINT ? "SIGINT" : "SIGTERM")
            }
            signalSources.append(source)
            source.resume()
        }
    }

    /// Suspends the VM, removes both sockets and exits the process.
    public func shutdown(reason: String) {
        stateLock.lock()
        if shuttingDown {
            stateLock.unlock()
            return
        }
        shuttingDown = true
        let timer = idleTimer
        idleTimer = nil
        stateLock.unlock()

        log.info("shutting down (\(reason))")
        timer?.cancel()
        // Raised before anything is torn down so the clients that were mid-request
        // when the signal landed are logged as the expected casualties they are.
        proxy.beginOrderlyShutdown()
        proxy.stop()
        // Through `forwarderQueue`, synchronously — never straight onto the
        // forwarder. Every other start/stop funnels through that serial queue
        // precisely so a fast running → stopped → running flap cannot reorder into
        // a stop that lands after the start it preceded (see the queue's comment);
        // stopping directly from here would race a queued `forwarder.start()` from
        // a late VM state change and could leave listeners bound on the way out.
        // Sync is safe: nothing on `forwarderQueue` ever blocks back on the caller
        // (its hops are all `async`), and the lines below assume the ports are
        // already free.
        forwarderQueue.sync {
            forwarder.stop(reason: "daemon shutting down")
            // The generation bump orphans any scheduled Kubernetes reconciliation
            // that would otherwise re-publish 127.0.0.1:6443 between here and exit,
            // and the listener itself comes down with the rest of the ports.
            kubernetesForwardGeneration &+= 1
            k8s.cancelPodPortForwards(reason: "the daemon is shutting down")
            k8s.forward.stop()
        }
        controlServer.stop()

        let semaphore = DispatchSemaphore(value: 0)
        if vm.state == .running {
            // Suspending rather than stopping means the next `docker ps` is instant.
            vm.suspend { [weak self] result in
                if case .failure(let error) = result {
                    self?.log.warn("suspend during shutdown failed: \(error)")
                }
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + 60) == .timedOut {
                log.warn("suspend during shutdown timed out")
            }
        }

        log.info("morbstackd stopped")
        // Released last so no replacement daemon can start until both sockets are
        // gone and the VM state is on disk.
        instanceLock.release()
        log.close()
        exit(0)
    }
}
