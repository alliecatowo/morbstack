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
    private let server: UnixSocketServer
    private let queue = DispatchQueue(label: "dev.morbstack.dockerproxy")
    private let relayQueue = DispatchQueue(label: "dev.morbstack.dockerproxy.relay", attributes: .concurrent)

    private let countLock = NSLock()
    private var _activeConnections = 0
    /// Set by ``Daemon`` around a deliberate shutdown; see ``beginOrderlyShutdown()``.
    private var _orderlyShutdown = false
    /// Live relays, keyed by a sequence number rather than by object identity so the
    /// key exists *before* the relay does — see ``startRelay(clientFD:guestFD:)``.
    private var relays: [UInt64: FDRelay] = [:]
    private var relaySequence: UInt64 = 0

    /// Called on the proxy's queue when the last active relay finishes.
    public var idleHandler: (() -> Void)?

    /// Creates a proxy bound to `socketPath` (defaults to ``MorbPaths/dockerSocket``).
    public init(vm: VMManager, log: MorbLog, socketPath: String = MorbPaths.dockerSocket.path) {
        self.vm = vm
        self.log = log
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
        guard let createBody = inspectContainerCreate(in: clientFD) else {
            relayAfterCreatePreflight(clientFD: clientFD, createBody: nil)
            return
        }

        switch DockerPortPublicationPreflight.inspectContainerCreate(body: createBody) {
        case .allowed:
            // Bind validation needs the VM's actual attached share list and the
            // guest's post-boot mount report, so it runs after `ensureRunning`.
            relayAfterCreatePreflight(clientFD: clientFD, createBody: createBody)
        case .rejected(let message):
            rejectContainerCreate(
                clientFD: clientFD,
                statusCode: 500,
                reason: "Internal Server Error",
                message: message)
        }
    }

    /// Performs a bounded `MSG_PEEK` only for a normal fixed-length Docker create
    /// request. No bytes are removed from `clientFD`; the original stream remains
    /// intact for ``FDRelay``. That is what lets the normal proxy preserve upgraded,
    /// chunked, and otherwise opaque Engine traffic without a second HTTP proxy.
    private func inspectContainerCreate(in clientFD: Int32) -> Data? {
        let deadline = Date().addingTimeInterval(DockerProxy.createPreflightPeekBudget)

        while Date() < deadline {
            let remainingMilliseconds = max(1, Int32((deadline.timeIntervalSinceNow * 1_000).rounded(.up)))
            var descriptor = pollfd(fd: clientFD, events: Int16(POLLIN), revents: 0)
            let polled = POSIXSocketSupport.retryOnInterrupt {
                withUnsafeMutablePointer(to: &descriptor) { poll($0, 1, remainingMilliseconds) }
            }
            guard polled > 0 else { return nil }

            guard let bytes = peekClientBytes(clientFD) else { return nil }
            let parsed: (head: HTTPRequestHead, consumed: Int)?
            do {
                parsed = try MinimalHTTP.parseRequestHead(bytes)
            } catch {
                return nil
            }
            guard let parsed else {
                // The complete header is not visible yet. Keep waiting only while it
                // can still fit in the bounded peek buffer.
                guard bytes.count < DockerProxy.createPreflightPeekLimit else { return nil }
                // `MSG_PEEK` leaves the partial head readable, so `poll` would wake
                // immediately again. Yield briefly rather than spinning a relay worker
                // while the local client finishes writing its request.
                usleep(1_000)
                continue
            }

            guard isContainerCreate(parsed.head) else { return nil }
            guard
                !(parsed.head.headers["transfer-encoding"] ?? "").lowercased().contains("chunked"),
                let contentLength = parsed.head.headers["content-length"].flatMap(Int.init),
                contentLength >= 0,
                contentLength <= DockerProxy.createPreflightPeekLimit - parsed.consumed
            else {
                return nil
            }

            let bodyEnd = parsed.consumed + contentLength
            guard bytes.count >= bodyEnd else {
                usleep(1_000)
                continue
            }
            return Data(bytes[parsed.consumed..<bodyEnd])
        }
        return nil
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

    private func relayAfterCreatePreflight(clientFD: Int32, createBody: Data?) {

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
                        self.connectionFinished()
                    case .success(let guestFD):
                        self.startRelay(clientFD: clientFD, guestFD: guestFD)
                    }
                }
            }
        }
    }

    private func startRelay(clientFD: Int32, guestFD: Int32) {
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
        countLock.lock()
        relaySequence &+= 1
        let key = relaySequence
        let relay = FDRelay(fdA: clientFD, fdB: guestFD, queue: perRelayQueue) { [weak self] in
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
