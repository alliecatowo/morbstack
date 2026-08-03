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
public final class DockerProxy {

    /// How long a client will wait for the VM to become usable.
    ///
    /// Comfortably above ``VMManager/controlReadyTimeout`` so the client sees the
    /// manager's specific diagnosis ("dockerd was not serving within 40s") rather
    /// than this layer's generic one.
    public static let bootTimeout: TimeInterval = 50

    /// Ordinary Docker create documents are small JSON. This is a strict upper bound
    /// for the non-consuming admission peek, not a request-size limit for the Engine:
    /// a larger or chunked request simply bypasses this best-effort preflight and is
    /// relayed byte-for-byte as it was before.
    private static let createPreflightPeekLimit = 256 * 1024
    private static let createPreflightPeekBudget: TimeInterval = 0.25

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
    /// key exists *before* the relay does — see ``startRelay(clientFD:guestFD:leaseObservation:)``.
    private var relays: [UInt64: FDRelay] = [:]
    /// Bounded dynamic-create exchanges. They own descriptors until their complete
    /// `201` has been associated (or rejected), so daemon stop must cancel them just
    /// as it cancels ordinary opaque relays.
    private var dynamicCreateTransactions: [UInt64: DockerDynamicCreateTransaction] = [:]
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
        let inFlightTransactions = Array(dynamicCreateTransactions.values)
        relays.removeAll()
        dynamicCreateTransactions.removeAll()
        _activeConnections = 0
        countLock.unlock()
        for relay in inFlight { relay.cancel() }
        for transaction in inFlightTransactions { transaction.cancel() }
    }

    // MARK: - Connection handling

    private func handle(clientFD: Int32) {
        // Count the client the moment it is accepted so a boot in progress cannot be
        // mistaken for an idle stack by the auto-suspend timer.
        countLock.lock()
        _activeConnections += 1
        countLock.unlock()

        // Do the short, non-consuming preflight away from the Unix listener's serial
        // accept queue. A local client that dribbles a request head must not delay
        // unrelated Docker clients from connecting.
        relayQueue.async { [weak self] in
            guard let self else {
                Darwin.close(clientFD)
                return
            }
            self.preflightThenRelay(clientFD: clientFD)
        }
    }

    private func preflightThenRelay(clientFD: Int32) {
        switch inspectDockerRequest(in: clientFD) {
        case .other:
            relayAfterPreflight(clientFD: clientFD, createBody: nil, leaseObservation: nil)

        case .create(let create):
            switch DockerPortPublicationPreflight.inspectContainerCreate(body: create.body) {
            case .rejected(let message):
                rejectContainerCreate(
                    clientFD: clientFD,
                    statusCode: 500,
                    reason: "Internal Server Error",
                    message: message)

            case .allowed:
                switch DockerPortPublicationPreflight.dynamicTCPCreatePlan(in: create.body) {
                case .rejected(let message):
                    rejectContainerCreate(
                        clientFD: clientFD,
                        statusCode: 500,
                        reason: "Internal Server Error",
                        message: message)
                    return

                case .supported(let plan):
                    beginDynamicTCPCreate(
                        clientFD: clientFD,
                        create: create,
                        plan: plan)
                    return

                case .notDynamic:
                    break
                }

                // A successful snapshot is still not enough. Hold the real listeners
                // before the create reaches dockerd; a failed bind here has the same
                // Docker-style error, but no guest side effect to roll back.
                let publications = DockerPortPublicationPreflight.explicitTCPBindings(in: create.body)
                let lease: PortForwarder.TCPPortLease?
                do {
                    lease = publications.isEmpty ? nil : try forwarder.reserveExplicitTCPPorts(publications)
                } catch {
                    rejectContainerCreate(
                        clientFD: clientFD,
                        statusCode: 500,
                        reason: "Internal Server Error",
                        message: error.localizedDescription)
                    return
                }
                // Bind validation needs the VM's actual attached share list and the
                // guest's post-boot mount report, so it runs after `ensureRunning`.
                relayAfterPreflight(
                    clientFD: clientFD,
                    createBody: create.body,
                    leaseObservation: lease.map(PortLeaseObservation.create))
            }

        case .start(let containerIdentifier):
            let observation = forwarder.claimStartLease(containerIdentifier: containerIdentifier)
                .map(PortLeaseObservation.start)
            relayAfterPreflight(clientFD: clientFD, createBody: nil, leaseObservation: observation)
        }
    }

    private enum DockerRequestInspection {
        case other
        case create(ContainerCreateRequest)
        case start(String)
    }

    /// A complete create request as seen non-consumingly by `MSG_PEEK`.
    ///
    /// `rawRequest` is consumed only by the dynamic transaction, in exactly this
    /// length. A following request remains unread in the client socket until the
    /// transaction has associated its `201` and hands the socket back here.
    private struct ContainerCreateRequest {
        let head: HTTPRequestHead
        let headBytes: Data
        let body: Data
        let rawRequest: Data
    }

    private enum PortLeaseObservation {
        case create(PortForwarder.TCPPortLease)
        case start(PortForwarder.TCPPortLease)
    }

    /// Performs a bounded `MSG_PEEK` for only the normal fixed-length create and
    /// bodyless start shapes this lease protocol can prove. No bytes are removed from
    /// `clientFD`; every other request remains intact for ``FDRelay``, including
    /// upgraded, chunked, and otherwise opaque Engine traffic.
    private func inspectDockerRequest(in clientFD: Int32) -> DockerRequestInspection {
        let deadline = Date().addingTimeInterval(DockerProxy.createPreflightPeekBudget)

        while Date() < deadline {
            let remainingMilliseconds = max(1, Int32((deadline.timeIntervalSinceNow * 1_000).rounded(.up)))
            var descriptor = pollfd(fd: clientFD, events: Int16(POLLIN), revents: 0)
            let polled = POSIXSocketSupport.retryOnInterrupt {
                withUnsafeMutablePointer(to: &descriptor) { poll($0, 1, remainingMilliseconds) }
            }
            guard polled > 0 else { return .other }

            guard let bytes = peekClientBytes(clientFD) else { return .other }
            let parsed: (head: HTTPRequestHead, consumed: Int)?
            do {
                parsed = try MinimalHTTP.parseRequestHead(bytes)
            } catch {
                return .other
            }
            guard let parsed else {
                // The complete header is not visible yet. Keep waiting only while it
                // can still fit in the bounded peek buffer.
                guard bytes.count < DockerProxy.createPreflightPeekLimit else { return .other }
                // `MSG_PEEK` leaves the partial head readable, so `poll` would wake
                // immediately again. Yield briefly rather than spinning a relay worker
                // while the local client finishes writing its request.
                usleep(1_000)
                continue
            }

            if let containerIdentifier = containerStartIdentifier(in: parsed.head) {
                let transferEncoding = parsed.head.headers["transfer-encoding"] ?? ""
                let contentLength: Int
                if let rawLength = parsed.head.headers["content-length"] {
                    guard let parsedLength = Int(rawLength) else { return .other }
                    contentLength = parsedLength
                } else {
                    contentLength = 0
                }
                guard !transferEncoding.lowercased().contains("chunked"), contentLength == 0 else {
                    return .other
                }
                return .start(containerIdentifier)
            }

            guard isContainerCreate(parsed.head) else { return .other }
            guard
                !(parsed.head.headers["transfer-encoding"] ?? "").lowercased().contains("chunked"),
                let contentLength = parsed.head.headers["content-length"].flatMap(Int.init),
                contentLength >= 0,
                contentLength <= DockerProxy.createPreflightPeekLimit - parsed.consumed
            else {
                return .other
            }

            let bodyEnd = parsed.consumed + contentLength
            guard bytes.count >= bodyEnd else {
                usleep(1_000)
                continue
            }
            let headBytes = Data(bytes[0..<parsed.consumed])
            let body = Data(bytes[parsed.consumed..<bodyEnd])
            return .create(ContainerCreateRequest(
                head: parsed.head,
                headBytes: headBytes,
                body: body,
                rawRequest: Data(bytes[0..<bodyEnd])))
        }
        return .other
    }

    private func peekClientBytes(_ clientFD: Int32) -> Data? {
        var buffer = [UInt8](repeating: 0, count: DockerProxy.createPreflightPeekLimit)
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.recv(clientFD, base, raw.count, Int32(MSG_PEEK))
        }
        guard count > 0 else { return nil }
        return Data(buffer[0..<count])
    }

    private func isContainerCreate(_ request: HTTPRequestHead) -> Bool {
        guard request.method.uppercased() == "POST" else { return false }
        let path = request.target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        return components.suffix(2).map(String.init) == ["containers", "create"]
    }

    private func containerStartIdentifier(in request: HTTPRequestHead) -> String? {
        guard request.method.uppercased() == "POST" else { return nil }
        let path = request.target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 3,
              components[components.count - 3] == "containers",
              components.last == "start"
        else {
            return nil
        }
        let identifier = String(components[components.count - 2])
        return identifier.isEmpty ? nil : identifier
    }

    // MARK: - Bounded dynamic TCP create transaction

    /// Starts Phase 1's only request-transforming path: an explicit empty TCP
    /// `HostPort` and a normal fixed-length create body.
    ///
    /// The original request remains in the Unix socket until this point. It is read
    /// with an exact byte count — never a generous buffer — so a following request
    /// remains available for a fresh preflight after the `201` is associated.
    private func beginDynamicTCPCreate(
        clientFD: Int32,
        create: ContainerCreateRequest,
        plan: DockerDynamicTCPCreatePlan
    ) {
        guard dynamicCreateDoesNotExpectContinue(create) else {
            rejectContainerCreate(
                clientFD: clientFD,
                statusCode: 500,
                reason: "Internal Server Error",
                message: "dynamic published TCP ports do not support Expect: 100-continue requests")
            return
        }
        guard consumeExactly(clientFD, expected: create.rawRequest) else {
            // No Engine request has crossed the boundary. A client that disappeared
            // cannot consume a useful HTTP diagnosis, so cleanly finish its slot.
            Darwin.close(clientFD)
            connectionFinished()
            return
        }

        let fixedPublications = DockerPortPublicationPreflight.explicitTCPBindings(in: create.body)
        let reservation: PortForwarder.DynamicTCPPortReservation
        do {
            reservation = try forwarder.reserveDynamicTCPPorts(
                plan.requestedPublications,
                alongside: fixedPublications)
        } catch {
            rejectContainerCreate(
                clientFD: clientFD,
                statusCode: 500,
                reason: "Internal Server Error",
                message: error.localizedDescription)
            return
        }

        let rewrittenBody: Data
        let rewrittenHead: Data
        do {
            rewrittenBody = try plan.rewrittenBody(with: reservation.publications)
            guard let head = DockerDynamicCreateTransaction.rewritingContentLength(
                in: create.headBytes,
                bodyLength: rewrittenBody.count)
            else {
                throw MorbError.protocolViolation("dynamic TCP create did not have one rewritable Content-Length header")
            }
            rewrittenHead = head
        } catch {
            forwarder.abandon(reservation.lease, reason: "the dynamic TCP create request could not be rewritten")
            rejectContainerCreate(
                clientFD: clientFD,
                statusCode: 500,
                reason: "Internal Server Error",
                message: "morbstack could not prepare the dynamic TCP port allocation")
            return
        }

        relayDynamicCreateAfterPreflight(
            clientFD: clientFD,
            createBody: rewrittenBody,
            rewrittenRequest: rewrittenHead + rewrittenBody,
            lease: reservation.lease,
            closeClientAfterResponse: dynamicCreateRequestsConnectionClose(create))
    }

    private func dynamicCreateDoesNotExpectContinue(_ create: ContainerCreateRequest) -> Bool {
        !(create.head.headers["expect"] ?? "").lowercased().contains("100-continue")
    }

    private func dynamicCreateRequestsConnectionClose(_ create: ContainerCreateRequest) -> Bool {
        let values = (create.head.headers["connection"] ?? "")
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces).lowercased() }
        return values.contains("close")
    }

    /// Reads exactly a request we just saw through `MSG_PEEK`. Each `read(2)` is
    /// capped at the remaining byte count, so a later pipelined request stays in the
    /// kernel buffer until the associated create response hands the client socket
    /// back to this proxy for a fresh preflight.
    private func consumeExactly(_ fd: Int32, expected: Data) -> Bool {
        var received = Data()
        received.reserveCapacity(expected.count)
        while received.count < expected.count {
            let remaining = expected.count - received.count
            var bytes = [UInt8](repeating: 0, count: min(16 * 1024, remaining))
            let count = bytes.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return POSIXSocketSupport.readSome(fd, into: base, count: raw.count)
            }
            guard count > 0 else { return false }
            received.append(contentsOf: bytes[0..<count])
        }
        return received == expected
    }

    private func relayDynamicCreateAfterPreflight(
        clientFD: Int32,
        createBody: Data,
        rewrittenRequest: Data,
        lease: PortForwarder.TCPPortLease,
        closeClientAfterResponse: Bool
    ) {
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
                    self.log.error("dynamic Docker create rejected: \(error)")
                }
                self.writeGatewayError(to: clientFD, message: "\(error)")
                Darwin.close(clientFD)
                self.forwarder.abandon(lease, reason: "the VM was unavailable before dynamic Docker create could be relayed")
                self.connectionFinished()

            case .success:
                switch DockerBindMountPreflight.inspectContainerCreate(
                    body: createBody,
                    shares: self.vm.shares,
                    guestShareStates: self.vm.guestShareStates)
                {
                case .allowed:
                    break
                case .rejected(let message):
                    self.forwarder.abandon(lease, reason: "bind source validation rejected the dynamic create")
                    self.rejectContainerCreate(
                        clientFD: clientFD,
                        statusCode: 400,
                        reason: "Bad Request",
                        message: message)
                    return
                }
                self.vm.connectVsock(port: MorbVsockPorts.dockerAPI) { [weak self] vsockResult in
                    guard let self else {
                        Darwin.close(clientFD)
                        return
                    }
                    switch vsockResult {
                    case .failure(let error):
                        if self.isShuttingDown {
                            self.log.info("client arrived during shutdown; rejected cleanly (\(error))")
                        } else {
                            self.log.error("dynamic Docker create relay could not reach the guest: \(error)")
                        }
                        self.writeGatewayError(to: clientFD, message: "\(error)")
                        Darwin.close(clientFD)
                        self.forwarder.abandon(lease, reason: "the Docker API vsock connection failed for dynamic create")
                        self.connectionFinished()
                    case .success(let guestFD):
                        self.startDynamicCreateTransaction(
                            clientFD: clientFD,
                            guestFD: guestFD,
                            request: rewrittenRequest,
                            lease: lease,
                            closeClientAfterResponse: closeClientAfterResponse)
                    }
                }
            }
        }
    }

    private func relayAfterPreflight(
        clientFD: Int32,
        createBody: Data?,
        leaseObservation: PortLeaseObservation?
    ) {

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
                self.finishLeaseObservation(leaseObservation, reason: "the VM was unavailable before Docker create/start could be relayed")
                self.connectionFinished()
            case .success:
                if let createBody {
                    switch DockerBindMountPreflight.inspectContainerCreate(
                        body: createBody,
                        shares: self.vm.shares,
                        guestShareStates: self.vm.guestShareStates)
                    {
                    case .allowed:
                        break
                    case .rejected(let message):
                        self.rejectContainerCreate(
                            clientFD: clientFD,
                            statusCode: 400,
                            reason: "Bad Request",
                            message: message)
                        self.finishLeaseObservation(leaseObservation, reason: "bind source validation rejected the create")
                        return
                    }
                }
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
                        self.finishLeaseObservation(leaseObservation, reason: "the Docker API vsock connection failed")
                        self.connectionFinished()
                    case .success(let guestFD):
                        self.startRelay(
                            clientFD: clientFD,
                            guestFD: guestFD,
                            leaseObservation: leaseObservation)
                    }
                }
            }
        }
    }

    private func startRelay(
        clientFD: Int32,
        guestFD: Int32,
        leaseObservation: PortLeaseObservation?
    ) {
        // Each relay gets its own serial queue; the concurrent parent lets many
        // Docker connections make progress at once.
        let perRelayQueue = DispatchQueue(label: "dev.morbstack.relay", target: relayQueue)

        // The key is minted before the relay so the completion handler can capture it
        // by value. Capturing a `var identifier` that is only assigned *after* the
        // initialiser returns is both a data race and a leak: `DispatchIO` fires its
        // cleanup handler asynchronously, so a relay built on a descriptor that is
        // already dead can complete before the assignment lands, find `nil`, and skip
        // the removal — after which the entry is inserted and never taken out again.
        //
        // The lock is held across construction *and* insertion for the same reason:
        // it makes an early completion block until the dictionary is consistent,
        // rather than racing the insert. `FDRelay.init` never takes `countLock`, so
        // this cannot deadlock.
        let responseObserver = makeLeaseResponseObserver(for: leaseObservation)
        countLock.lock()
        relaySequence &+= 1
        let key = relaySequence
        let relay = FDRelay(
            fdA: clientFD,
            fdB: guestFD,
            queue: perRelayQueue,
            observer: { direction, data in
                guard direction == .secondToFirst else { return }
                responseObserver?.receive(data)
            }
        ) { [weak self] in
            responseObserver?.relayFinished()
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

    /// Registers and starts the one-way bounded transaction for a rewritten dynamic
    /// create. The transaction owns both descriptors; unlike `FDRelay`, it must keep
    /// the complete `201` private until its lease is associated.
    private func startDynamicCreateTransaction(
        clientFD: Int32,
        guestFD: Int32,
        request: Data,
        lease: PortForwarder.TCPPortLease,
        closeClientAfterResponse: Bool
    ) {
        let transactionQueue = DispatchQueue(
            label: "dev.morbstack.dynamic-create-transaction",
            target: relayQueue)

        countLock.lock()
        relaySequence &+= 1
        let key = relaySequence
        let transaction = DockerDynamicCreateTransaction(
            clientFD: clientFD,
            guestFD: guestFD,
            request: request,
            closeClientAfterResponse: closeClientAfterResponse,
            queue: transactionQueue,
            associate: { [forwarder] containerID in
                forwarder.associate(lease, withContainerID: containerID)
            },
            abandon: { [forwarder] reason in
                forwarder.abandon(lease, reason: reason)
            },
            reportTransactionError: { [weak self] message in
                self?.writeEngineError(
                    to: clientFD,
                    statusCode: 500,
                    reason: "Internal Server Error",
                    message: message)
            }
        ) { [weak self] handoffClientFD in
            guard let self else {
                if let handoffClientFD { Darwin.close(handoffClientFD) }
                return
            }
            self.countLock.lock()
            self.dynamicCreateTransactions.removeValue(forKey: key)
            self.countLock.unlock()
            if let handoffClientFD {
                self.relayQueue.async { [weak self] in
                    self?.preflightThenRelay(clientFD: handoffClientFD)
                }
            } else {
                self.connectionFinished()
            }
        }
        dynamicCreateTransactions[key] = transaction
        countLock.unlock()

        transaction.start()
    }

    private func makeLeaseResponseObserver(
        for observation: PortLeaseObservation?
    ) -> DockerPortLeaseResponseObserver? {
        guard let observation else { return nil }
        switch observation {
        case .create(let lease):
            return DockerPortLeaseResponseObserver(kind: .create) { [forwarder] outcome in
                switch outcome {
                case .created(let containerID):
                    guard forwarder.associate(lease, withContainerID: containerID) else {
                        forwarder.abandon(lease, reason: "Docker create returned an already-leased or unusable container identity")
                        return
                    }
                case .failed:
                    forwarder.abandon(lease, reason: "Docker create returned an error response")
                case .unrecognized:
                    forwarder.abandon(lease, reason: "Docker create response was not a bounded identity-bearing HTTP response")
                case .startSucceeded:
                    break
                }
            }

        case .start(let lease):
            return DockerPortLeaseResponseObserver(kind: .start) { [forwarder] outcome in
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

    /// The response observer owns create/start cleanup once a relay exists. These
    /// earlier error branches have no guest response to observe, so they must retire
    /// the provisional reservation explicitly.
    private func finishLeaseObservation(_ observation: PortLeaseObservation?, reason: String) {
        guard let observation else { return }
        switch observation {
        case .create(let lease): forwarder.abandon(lease, reason: reason)
        case .start(let lease): _ = forwarder.completeStart(lease, succeeded: false)
        }
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

    private func rejectContainerCreate(
        clientFD: Int32,
        statusCode: Int,
        reason: String,
        message: String
    ) {
        log.warn("docker container create rejected before relay: \(message)")
        writeEngineError(to: clientFD, statusCode: statusCode, reason: reason, message: message)
        Darwin.close(clientFD)
        connectionFinished()
    }

    /// Writes a minimal HTTP 502 so `docker ps` shows a real message instead of
    /// "connection reset by peer".
    private func writeGatewayError(to fd: Int32, message: String) {
        writeEngineError(to: fd, statusCode: 502, reason: "Bad Gateway", message: "morbstack: \(message)")
    }

    /// Writes a Docker-style JSON error without forwarding the rejected request.
    ///
    /// Port preflight failures are deliberately `500`, matching the class Docker
    /// clients already treat as an Engine-side publication failure. The body remains
    /// the standard `{ "message": ... }` shape the Docker CLI reads.
    private func writeEngineError(to fd: Int32, statusCode: Int, reason: String, message: String) {
        let sanitized = message
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
        let body = "{\"message\":\"\(sanitized)\"}"
        let response = """
            HTTP/1.1 \(statusCode) \(reason)\r
            Content-Type: application/json\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
        POSIXSocketSupport.writeAll(fd, Data(response.utf8))
    }
}
