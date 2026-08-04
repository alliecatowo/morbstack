// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Dispatch
import Foundation

/// Publishes `~/.morbstack/run/docker.sock` and relays it to the guest's Docker API.
///
/// This is "socket-activation-lite": the socket exists whenever the daemon runs, but
/// the VM only boots when a client actually connects. Combined with the auto-suspend
/// timer in ``Daemon``, an idle Morbstack costs no guest memory at all.
///
/// # Admission
///
/// Every request on every connection is framed and offered to the admission checks —
/// not just the first one. The proxy used to peek at a connection's opening request
/// and then splice the socket raw forever, which meant that in normal use (the CLI
/// pings, then reuses the connection for the real work) `POST /containers/create` was
/// never inspected at all: a `-v /etc/hosts:/x` bind quietly resolved inside the guest
/// and container writes to it vanished. ``DockerFramedRelay`` owns the framing;
/// this class owns the policy, in ``admit(_:body:)``.
public final class DockerProxy {

    /// How long a client will wait for the VM to become usable.
    ///
    /// Comfortably above ``VMManager/controlReadyTimeout`` so the client sees the
    /// manager's specific diagnosis ("dockerd was not serving within 40s") rather
    /// than this layer's generic one.
    public static let bootTimeout: TimeInterval = 50

    private let vm: VMManager
    private let log: MorbLog
    private let forwarder: PortForwarder
    private let server: UnixSocketServer
    private let queue = DispatchQueue(label: "dev.morbstack.dockerproxy")
    private let relayQueue = DispatchQueue(label: "dev.morbstack.dockerproxy.relay", attributes: .concurrent)

    private let countLock = NSLock()
    private var _activeConnections = 0
    /// Set by ``Daemon`` around a deliberate shutdown; see ``beginOrderlyShutdown()``.
    private var _orderlyShutdown = false
    /// Live relays, keyed by a sequence number rather than by object identity so the
    /// key exists *before* the relay does — see ``startRelay(clientFD:guestFD:)``.
    private var relays: [UInt64: DockerFramedRelay] = [:]
    private var relaySequence: UInt64 = 0

    /// Called on the proxy's queue when the last active relay finishes.
    public var idleHandler: (() -> Void)?

    /// Creates a proxy bound to `socketPath` (defaults to ``MorbPaths/dockerSocket``).
    public init(
        vm: VMManager,
        log: MorbLog,
        forwarder: PortForwarder,
        socketPath: String = MorbPaths.dockerSocket.path
    ) {
        self.vm = vm
        self.log = log
        self.forwarder = forwarder
        self.server = UnixSocketServer(path: socketPath, queue: queue)
        self.server.onConnection = { [weak self] fd in
            self?.handle(clientFD: fd)
        }
    }

    /// The number of relays currently pumping bytes.
    public var activeConnections: Int {
        countLock.lock()
        defer { countLock.unlock() }
        return _activeConnections
    }

    /// The path the Docker socket is published at.
    public var socketPath: String { server.path }

    /// Tells the proxy that the VM is being taken down on purpose.
    ///
    /// Clients that were mid-flight when a `morb stop` landed will fail, and they
    /// should: there is no engine to reach any more. What they should *not* do is
    /// produce ERROR lines, because a user who has just asked for a shutdown and finds
    /// errors in the log reasonably concludes the shutdown went wrong. `Daemon` raises
    /// this for the duration of a deliberate stop and lowers it afterwards.
    public func beginOrderlyShutdown() { setOrderlyShutdown(true) }

    /// Clears the flag raised by ``beginOrderlyShutdown()``.
    public func endOrderlyShutdown() { setOrderlyShutdown(false) }

    private func setOrderlyShutdown(_ value: Bool) {
        countLock.lock()
        _orderlyShutdown = value
        countLock.unlock()
    }

    /// Whether a rejection right now is an expected consequence of a shutdown.
    ///
    /// The VM state is consulted as well as the flag: a guest that powered itself off,
    /// or a stop started by something other than the control socket, is just as
    /// orderly from the client's point of view.
    private var isShuttingDown: Bool {
        countLock.lock()
        let flagged = _orderlyShutdown
        countLock.unlock()
        if flagged { return true }
        switch vm.state {
        case .stopping, .stopped: return true
        case .starting, .running, .pausing, .suspended, .error: return false
        }
    }

    /// Starts listening.
    public func start() throws {
        try server.start()
        log.info("docker socket listening at \(server.path)")
    }

    /// Stops listening and cancels every in-flight relay.
    public func stop() {
        server.stop()
        countLock.lock()
        let inFlight = Array(relays.values)
        relays.removeAll()
        _activeConnections = 0
        countLock.unlock()
        for relay in inFlight { relay.cancel() }
    }

    // MARK: - Connection handling

    private func handle(clientFD: Int32) {
        // Count the client the moment it is accepted so a boot in progress cannot be
        // mistaken for an idle stack by the auto-suspend timer.
        countLock.lock()
        _activeConnections += 1
        countLock.unlock()

        // Leave the Unix listener's serial accept queue immediately: a client that
        // dribbles a request head must not delay unrelated Docker clients.
        relayQueue.async { [weak self] in
            guard let self else {
                Darwin.close(clientFD)
                return
            }
            self.establish(clientFD: clientFD)
        }
    }

    /// Boots the VM if needed, opens the Docker API vsock, and starts framing.
    ///
    /// Admission has deliberately moved *behind* this point. Every check the proxy
    /// owns needs either the running VM's share list (bind sources) or a host listener
    /// it can only hold while the stack is up (published ports), and the first thing
    /// any real client sends is a `/_ping` that boots the VM regardless.
    private func establish(clientFD: Int32) {
        vm.ensureRunning(timeout: DockerProxy.bootTimeout) { [weak self] result in
            guard let self else {
                Darwin.close(clientFD)
                return
            }
            switch result {
            case .failure(let error):
                if self.isShuttingDown {
                    self.log.info("client arrived during shutdown; rejected cleanly (\(error))")
                } else {
                    self.log.error("docker client rejected: \(error)")
                }
                self.writeGatewayError(to: clientFD, message: "\(error)")
                Darwin.close(clientFD)
                self.connectionFinished()

            case .success:
                self.vm.connectVsock(port: MorbVsockPorts.dockerAPI) { [weak self] vsockResult in
                    guard let self else {
                        Darwin.close(clientFD)
                        return
                    }
                    switch vsockResult {
                    case .failure(let error):
                        // Same reasoning as above: the vsock connect is the next thing
                        // to fail once the guest is on its way out.
                        if self.isShuttingDown {
                            self.log.info("client arrived during shutdown; rejected cleanly (\(error))")
                        } else {
                            self.log.error("docker relay could not reach the guest: \(error)")
                        }
                        self.writeGatewayError(to: clientFD, message: "\(error)")
                        Darwin.close(clientFD)
                        self.connectionFinished()

                    case .success(let guestFD):
                        self.startRelay(clientFD: clientFD, guestFD: guestFD)
                    }
                }
            }
        }
    }

    private func startRelay(clientFD: Int32, guestFD: Int32) {
        // Each relay gets its own serial completion queue; the concurrent parent lets
        // many Docker connections make progress at once.
        let perRelayQueue = DispatchQueue(label: "dev.morbstack.relay", target: relayQueue)

        // The key is minted before the relay so the completion handler can capture it
        // by value. Capturing a `var identifier` that is only assigned *after* the
        // initialiser returns is both a data race and a leak: a relay built on a
        // descriptor that is already dead can complete before the assignment lands,
        // find `nil`, and skip the removal — after which the entry is inserted and
        // never taken out again.
        //
        // The lock is held across construction *and* insertion for the same reason:
        // it makes an early completion block until the dictionary is consistent.
        countLock.lock()
        relaySequence &+= 1
        let key = relaySequence
        let relay = DockerFramedRelay(
            clientFD: clientFD,
            guestFD: guestFD,
            queue: perRelayQueue,
            policy: self,
            log: log
        ) { [weak self] in
            guard let self else { return }
            self.countLock.lock()
            self.relays.removeValue(forKey: key)  // tolerates an entry stop() already took
            self.countLock.unlock()
            self.connectionFinished()
        }
        relays[key] = relay
        countLock.unlock()

        relay.start()
    }

    private func connectionFinished() {
        countLock.lock()
        _activeConnections = max(0, _activeConnections - 1)
        let remaining = _activeConnections
        countLock.unlock()
        guard remaining == 0 else { return }
        queue.async { [weak self] in
            self?.idleHandler?()
        }
    }

    // MARK: - Request classification

    /// The two bodyless Engine endpoints whose successful `204` means a container
    /// has started and a held fixed-port listener set may be activated. They share the
    /// lease protocol, but their request bytes are always relayed unchanged.
    enum ContainerLifecycleOperation: String {
        case start
        case restart
    }

    struct ContainerLifecycleRequest {
        let containerIdentifier: String
        let operation: ContainerLifecycleOperation
    }

    func isContainerCreate(_ request: HTTPRequestHead) -> Bool {
        guard request.method.uppercased() == "POST" else { return false }
        let path = request.target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        return components.suffix(2).map(String.init) == ["containers", "create"]
    }

    func containerLifecycleRequest(in request: HTTPRequestHead) -> ContainerLifecycleRequest? {
        guard request.method.uppercased() == "POST" else { return nil }
        let path = request.target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 3,
              components[components.count - 3] == "containers",
              let finalComponent = components.last,
              let operation = ContainerLifecycleOperation(rawValue: String(finalComponent))
        else {
            return nil
        }
        let identifier = String(components[components.count - 2])
        guard !identifier.isEmpty else { return nil }
        return ContainerLifecycleRequest(
            containerIdentifier: identifier,
            operation: operation)
    }

    // MARK: - Engine-shaped errors

    /// Writes a minimal HTTP 502 so `docker ps` shows a real message instead of
    /// "connection reset by peer".
    private func writeGatewayError(to fd: Int32, message: String) {
        POSIXSocketSupport.writeAll(
            fd,
            DockerEngineErrorResponse.bytes(
                statusCode: 502,
                reason: "Bad Gateway",
                message: "morbstack: \(message)"))
    }
}

// MARK: - Per-request admission

extension DockerProxy: DockerRequestAdmissionPolicy {

    /// Only `containers/create` needs its body in memory. Everything else — a build
    /// context, a `docker cp` archive, an image push — streams through the framer
    /// without being copied.
    func requiresBodyInspection(_ head: HTTPRequestHead) -> Bool {
        isContainerCreate(head)
    }

    func requestWasRefused(_ message: String) {
        log.warn("docker request refused before relay: \(message)")
    }

    func framingFailed(_ description: String) {
        log.warn("docker connection could not be framed: \(description)")
    }

    /// The verdict for one request.
    ///
    /// Runs on the relay's request worker, one request at a time per connection, and
    /// independently across connections. Everything it touches — the forwarder ledger,
    /// the VM's share snapshot — is already safe from any thread.
    func admit(_ request: DockerRequestFramer.Request, body: Data?) -> DockerRequestAdmission {
        if isContainerCreate(request.head), let body {
            return admitContainerCreate(request: request, body: body)
        }
        if let lifecycle = containerLifecycleRequest(in: request.head),
           request.framing == .empty
        {
            return admitContainerLifecycle(lifecycle)
        }
        return .forward
    }

    /// Validates publication shape and bind sources before taking a host-port lease.
    /// A verified macOS `/etc` or `/var` bind is made explicit before Docker's port
    /// plans inspect the document, so every later request rewrite retains the exact
    /// host source rather than accidentally restoring a guest-system alias.
    private func admitContainerCreate(
        request: DockerRequestFramer.Request,
        body: Data
    ) -> DockerRequestAdmission {
        switch DockerPortPublicationPreflight.inspectContainerCreate(body: body) {
        case .rejected(let message):
            return .reject(statusCode: 500, reason: "Internal Server Error", message: message)
        case .allowed:
            break
        }

        let bindPrepared: DockerBindMountPreflight.Preparation
        let shareSnapshot = vm.shareMountSnapshot
        bindPrepared = DockerBindMountPreflight.prepareContainerCreate(
            body: body,
            shares: shareSnapshot.shares,
            guestShareStates: shareSnapshot.guestShareStates,
            guestTmpAliasMounted: shareSnapshot.guestTmpAliasMounted)

        let admittedBody: Data
        let bindSourcesWereRewritten: Bool
        switch bindPrepared {
        case .rejected(let message):
            return .reject(statusCode: 400, reason: "Bad Request", message: message)
        case .allowed(let preparedBody, let wasRewritten):
            admittedBody = preparedBody
            bindSourcesWereRewritten = wasRewritten
        }

        switch DockerPortPublicationPreflight.dynamicPortCreatePlan(in: admittedBody) {
        case .rejected(let message):
            return .reject(statusCode: 500, reason: "Internal Server Error", message: message)

        case .supported(let plan):
            return admitDynamicPortCreate(request: request, plan: plan)

        case .notDynamic:
            break
        }

        // A successful publication snapshot is still not enough. Hold the real
        // listeners before the create reaches dockerd, so a failed host bind has no
        // guest side effect to roll back.
        let plan = DockerPortPublicationPreflight.fixedPortLeasePlan(in: admittedBody)
        let lease: PortForwarder.PortLease?
        do {
            lease = try plan.map { try forwarder.reserveExplicitPorts($0) }
        } catch {
            return .reject(
                statusCode: 500,
                reason: "Internal Server Error",
                message: error.localizedDescription)
        }

        guard let lease else {
            guard bindSourcesWereRewritten else { return .forward }
            guard let rewrittenRequest = rewrittenCreateRequest(request: request, body: admittedBody) else {
                return .reject(
                    statusCode: 500,
                    reason: "Internal Server Error",
                    message: "morbstack could not prepare the verified macOS bind source")
            }
            return .forwardRewritten(request: rewrittenRequest)
        }

        let observer = createObserver(for: lease)
        guard bindSourcesWereRewritten else { return .forwardObserving(observer) }
        guard let rewrittenRequest = rewrittenCreateRequest(request: request, body: admittedBody) else {
            forwarder.abandon(lease, reason: "the verified macOS bind source could not be rewritten")
            return .reject(
                statusCode: 500,
                reason: "Internal Server Error",
                message: "morbstack could not prepare the verified macOS bind source")
        }
        return .forwardRewrittenObserving(request: rewrittenRequest, observer: observer)
    }

    private func admitDynamicPortCreate(
        request: DockerRequestFramer.Request,
        plan: DockerDynamicPortCreatePlan
    ) -> DockerRequestAdmission {
        let reservation: PortForwarder.DynamicPortReservation
        do {
            reservation = try forwarder.reserveDynamicPorts(
                plan.requestedPublications,
                alongside: plan.fixedPlan)
        } catch {
            return .reject(
                statusCode: 500,
                reason: "Internal Server Error",
                message: error.localizedDescription)
        }

        let rewrittenBody: Data
        let rewrittenHead: Data
        do {
            rewrittenBody = try plan.rewrittenBody(with: reservation.publications)
            guard let head = HTTPRequestHeadRewriting.replacingBodyFraming(
                in: request.rawHead,
                bodyLength: rewrittenBody.count)
            else {
                throw MorbError.protocolViolation(
                    "dynamic published-port create did not have one rewritable body-framing header")
            }
            rewrittenHead = head
        } catch {
            forwarder.abandon(
                reservation.lease,
                reason: "the dynamic published-port create request could not be rewritten")
            return .reject(
                statusCode: 500,
                reason: "Internal Server Error",
                message: "morbstack could not prepare the dynamic published-port allocation")
        }

        let lease = reservation.lease
        return .forwardRewrittenHoldingCreate(
            request: rewrittenHead + rewrittenBody,
            hold: DockerHeldCreate(
                associate: { [forwarder] containerID in
                    forwarder.associate(lease, withContainerID: containerID)
                },
                abandon: { [forwarder] reason in
                    forwarder.abandon(lease, reason: reason)
                }))
    }

    private func admitContainerLifecycle(
        _ lifecycle: ContainerLifecycleRequest
    ) -> DockerRequestAdmission {
        let containerIdentifier = lifecycle.containerIdentifier

        if forwarder.requiresPublishAllAllocator(containerIdentifier: containerIdentifier) {
            return admitPublishAllStart(containerID: containerIdentifier)
        }
        if let lease = forwarder.claimStartLease(containerIdentifier: containerIdentifier) {
            return .forwardObserving(startObserver(for: lease))
        }
        guard DockerPortPublicationPreflight.isFullContainerID(containerIdentifier) else {
            // Names and ID prefixes can resolve to a different container between an
            // inspect and the lifecycle operation, so they keep the raw relay.
            return .forward
        }

        // A VM/daemon stop intentionally closes every held listener. Before this one
        // exact immutable-ID lifecycle request reaches dockerd, give the forwarder a
        // bounded chance to rebuild a fixed-port lease from the guest's persistent
        // HostConfig.PortBindings.
        do {
            _ = try forwarder.reserveStoppedContainerStartLease(containerID: containerIdentifier)
        } catch {
            // Deliberately different from an unavailable or unsupported inspect
            // document, which reserve... reports as nil and which keeps the historical
            // raw lifecycle relay. Here a concrete HostConfig publication was proved
            // but Mac bind ownership could not be obtained, so do not start a container
            // whose promised endpoint Morbstack cannot hold.
            return .reject(
                statusCode: 500,
                reason: "Internal Server Error",
                message: error.localizedDescription)
        }

        if let lease = forwarder.claimStartLease(containerIdentifier: containerIdentifier) {
            return .forwardObserving(startObserver(for: lease))
        }
        if forwarder.stoppedContainerUsesPublishAllPorts(containerID: containerIdentifier) {
            return admitPublishAllStart(containerID: containerIdentifier)
        }
        return .forward
    }

    /// Opens the per-container host allocator session before Moby receives the exact
    /// start request. The session does not allocate anything eagerly; it waits until
    /// Moby has expanded the image's effective `EXPOSE` set.
    private func admitPublishAllStart(containerID: String) -> DockerRequestAdmission {
        do {
            let session = try forwarder.beginPublishAllLifecycleSession(containerID: containerID)
            // Capture the forwarder, not `self`. The observer outlives this call —
            // it fires when Moby answers the start — so capturing `self` would keep
            // the whole proxy alive for the duration of every publish-all start, and
            // `[weak self]` would silently drop the completion if the proxy went
            // away mid-flight, leaving the session open forever. The forwarder is
            // the only thing the closure actually needs.
            let forwarder = self.forwarder
            return .forwardObserving(
                DockerPortLeaseResponseObserver(kind: .start) { outcome in
                    forwarder.completePublishAllLifecycleSession(
                        session,
                        containerID: containerID,
                        succeeded: outcome == .startSucceeded)
                })
        } catch {
            return .reject(
                statusCode: 500,
                reason: "Internal Server Error",
                message: "could not register the host publish-all allocator: \(error.localizedDescription)")
        }
    }

    private func rewrittenCreateRequest(
        request: DockerRequestFramer.Request,
        body: Data
    ) -> Data? {
        guard let rewrittenHead = HTTPRequestHeadRewriting.replacingBodyFraming(
            in: request.rawHead,
            bodyLength: body.count)
        else { return nil }
        return rewrittenHead + body
    }

    private func createObserver(for lease: PortForwarder.PortLease) -> DockerPortLeaseResponseObserver {
        DockerPortLeaseResponseObserver(kind: .create) { [forwarder] outcome in
            switch outcome {
            case .created(let containerID):
                guard forwarder.associate(lease, withContainerID: containerID) else {
                    forwarder.abandon(
                        lease,
                        reason: "Docker create returned an already-leased or unusable container identity")
                    return
                }
            case .failed:
                forwarder.abandon(lease, reason: "Docker create returned an error response")
            case .unrecognized:
                forwarder.abandon(
                    lease,
                    reason: "Docker create response was not a bounded identity-bearing HTTP response")
            case .startSucceeded:
                break
            }
        }
    }

    private func startObserver(for lease: PortForwarder.PortLease) -> DockerPortLeaseResponseObserver {
        DockerPortLeaseResponseObserver(kind: .start) { [forwarder] outcome in
            let succeeded: Bool
            if case .startSucceeded = outcome {
                succeeded = true
            } else {
                succeeded = false
            }
            _ = forwarder.completeStart(lease, succeeded: succeeded)
        }
    }
}
