// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Dispatch
import Foundation

/// Mirrors the guest's published container ports onto the Mac's loopback interface.
///
/// This is what makes `docker run -d -p 8080:80 nginx` followed by
/// `curl http://127.0.0.1:8080` work from the Mac. Three pieces:
///
/// 1. **Discovery.** A long-lived connection to the Docker Engine API over vsock 2375
///    subscribes to `GET /events` filtered to container events. Every event that could
///    move a port triggers a re-read of `GET /containers/json`, which is also what
///    seeds the initial state on each (re)connect. Polling `containers/json` alone
///    would either be laggy or wasteful; events alone would miss whatever happened
///    while the daemon was not watching, and would have to reconstruct port bindings
///    from a stream that does not carry them.
/// 2. **Listeners.** Each published TCP port gets a ``TCPListener`` on `127.0.0.1`.
/// 3. **Splicing.** Each accepted connection opens a vsock stream-dial (2376), names
///    the port, and hands both descriptors to an ``FDRelay``.
///
/// The forwarder is owned by ``Daemon`` and is active only while the VM is running.
public final class PortForwarder {

    /// How long an accepted connection will wait for the VM to be usable.
    ///
    /// A connection can land during a suspend the auto-suspend timer just started, so
    /// this rides the transition out instead of refusing — same reasoning as the
    /// Docker socket proxy, with a shorter budget because a `curl` to a published port
    /// has much less patience than a `docker` command.
    public static let dialBootTimeout: TimeInterval = 20

    /// Backoff bounds for reconnecting the event stream.
    private static let minimumBackoff: TimeInterval = 0.5
    private static let maximumBackoff: TimeInterval = 5

    /// Backoff bounds for re-attempting a host port some other process holds.
    private static let minimumBindBackoff: TimeInterval = 5
    private static let maximumBindBackoff: TimeInterval = 60

    /// How often the "is that port free yet?" timer fires.
    private static let bindRetryInterval: TimeInterval = 5

    /// Ceiling on stream-dials being established at once.
    ///
    /// Each dial parks a ``dialQueue`` worker for as long as the vsock connect plus the
    /// 2376 preamble takes — up to about eight seconds when the guest is unhealthy.
    /// `dialQueue` is concurrent, so without a ceiling a burst of accepted connections
    /// becomes a burst of blocked GCD threads; the pool is per-QoS and shared, so the
    /// first thing to starve is ``VMManager``'s probe queue, which is the machinery
    /// that would have noticed the guest was unhealthy in the first place.
    ///
    /// 48 sits deliberately below the guest-side stream-dial limit of 128, so the host
    /// is always the side that pushes back and the guest never has to.
    public static let maxConcurrentDials = 48

    /// Extra dials allowed to queue behind the ceiling before new clients are refused.
    ///
    /// Small on purpose: these are threads parked on a semaphore, and a client that
    /// cannot be served within a couple of seconds is better off being closed — `curl`
    /// reports a refused connection immediately, where a stalled one just hangs.
    public static let dialBacklogAllowance = 8

    /// One active mapping: the Docker binding and the Mac-side listener serving it.
    private struct Forward {
        let binding: DockerPortBinding
        let listener: TCPListener
    }

    /// A host port we wanted but could not bind, and when to try it again.
    private struct FailedBind {
        var binding: DockerPortBinding
        var reason: String
        var attempts: Int
        var nextAttemptAt: Date
    }

    private let vm: VMManager
    private let log: MorbLog

    /// Invoked whenever a connection is accepted on a published port.
    ///
    /// ``Daemon`` hooks this to its idle clock. Without it, traffic through a
    /// published port did not count as activity: only the *count* of live forwarded
    /// connections did, so a stream of short-lived requests — a health check every ten
    /// seconds, a browser reloading — left the clock untouched between them and the
    /// stack suspended out from under a service somebody was actively using.
    public var busyHandler: (() -> Void)?

    /// Blocking Engine API work (the `containers/json` re-reads), serialised so two
    /// refreshes cannot interleave and apply their diffs out of order.
    private let workQueue = DispatchQueue(label: "dev.morbstack.portforward.work")
    private let acceptQueue = DispatchQueue(
        label: "dev.morbstack.portforward.accept", attributes: .concurrent)
    private let dialQueue = DispatchQueue(
        label: "dev.morbstack.portforward.dial", qos: .userInitiated, attributes: .concurrent)
    private let relayQueue = DispatchQueue(
        label: "dev.morbstack.portforward.relay", attributes: .concurrent)

    /// Permits for ``dialQueue``; see ``maxConcurrentDials``.
    private let dialPermits = DispatchSemaphore(value: PortForwarder.maxConcurrentDials)

    private let lock = NSLock()
    private var running = false
    /// Bumped by every ``start()`` and ``stop()``; workers carry the value they were
    /// launched with and exit as soon as it goes stale.
    private var generation = 0
    private var forwards: [Int: Forward] = [:]
    private var relays: [UInt64: FDRelay] = [:]
    private var relaySequence: UInt64 = 0
    /// Live forwarded connections, counted **per generation**.
    ///
    /// Not one integer. A ``stop()`` cancels every relay but their completions land
    /// asynchronously, often after the next ``start()`` has already begun counting new
    /// connections; with a single counter those stale completions decrement the new
    /// generation's total. The daemon reads that total to decide whether the stack is
    /// idle, so the failure mode is an auto-suspend fired while connections are live.
    private var connectionCounts: [Int: Int] = [:]
    private var refreshQueued = false
    private var announcedUDPPorts: Set<Int> = []
    private var failedBinds: [Int: FailedBind] = [:]
    private var retryTimer: DispatchSourceTimer?
    /// Dials started but not yet spliced, throttled by ``maxConcurrentDials``.
    private var pendingDials = 0
    /// Set while a burst is being shed, so the refusal is logged once and not per client.
    private var dialBurstLogged = false

    /// Creates a forwarder. Nothing happens until ``start()``.
    public init(vm: VMManager, log: MorbLog) {
        self.vm = vm
        self.log = log
    }

    // MARK: - Observable state

    /// Human-readable descriptions of the live forwards, sorted by host port.
    public var activeForwards: [String] {
        lock.lock()
        defer { lock.unlock() }
        return forwards.keys.sorted().compactMap { forwards[$0]?.binding.description }
    }

    /// The number of forwarded connections currently being relayed.
    ///
    /// Counts the *current* generation only: connections belonging to a torn-down
    /// generation are already being cancelled and must not keep the stack awake.
    public var activeConnections: Int {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return 0 }
        return connectionCounts[generation] ?? 0
    }

    /// Host ports Docker asked for that could not be bound, newest reason first.
    ///
    /// Surfaced in `morb status`: a port that silently never appeared is the single
    /// most confusing failure this subsystem has, because `docker ps` cheerfully
    /// reports the publish that the Mac side could not honour.
    public var failedForwards: [String] {
        lock.lock()
        defer { lock.unlock() }
        return failedBinds.keys.sorted().compactMap { port in
            guard let failure = failedBinds[port] else { return nil }
            return "\(failure.binding.description) — \(failure.reason)"
        }
    }

    /// `true` between ``start()`` and ``stop()``.
    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    // MARK: - Lifecycle

    /// Begins watching the Docker event stream and publishing ports. Idempotent.
    ///
    /// Safe to call from the VM queue: everything blocking is dispatched away.
    public func start() {
        lock.lock()
        if running {
            lock.unlock()
            return
        }
        running = true
        generation &+= 1
        let generation = self.generation
        announcedUDPPorts.removeAll()
        lock.unlock()

        log.info("port forwarding active; watching the Docker event stream")
        startRetryTimer()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.runEventStream(generation: generation)
        }
    }

    /// Closes every listener and cancels every forwarded relay. Idempotent.
    ///
    /// - Parameter reason: Why the forwards are going away, for the log. Callers should
    ///   say so: "the published ports vanished" is alarming on its own and unremarkable
    ///   once you know the guest went with them.
    public func stop(reason: String? = nil) {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        running = false
        generation &+= 1
        let closing = forwards
        forwards.removeAll()
        let inFlight = Array(relays.values)
        relays.removeAll()
        // Stale completions are allowed to arrive; they find no entry for their
        // generation and become no-ops rather than debits against the next run.
        connectionCounts.removeAll()
        failedBinds.removeAll()
        let timer = retryTimer
        retryTimer = nil
        lock.unlock()

        timer?.cancel()
        for forward in closing.values { forward.listener.stop() }
        for relay in inFlight { relay.cancel() }

        let because = reason.map { " (\($0))" } ?? ""
        if closing.isEmpty {
            log.info("port forwarding stopped\(because)")
        } else {
            // Named individually: this is the line a user greps for when
            // `curl 127.0.0.1:8080` stops answering, and "3 listener(s)" does not
            // tell them which three.
            let ports = closing.keys.sorted().map(String.init).joined(separator: ", ")
            let subject = closing.count == 1 ? "port \(ports) is" : "ports \(ports) are"
            log.info(
                "port forwarding stopped\(because); 127.0.0.1 \(subject) no longer "
                    + "published and will be republished when the guest is running again")
        }
    }

    /// Whether `generation` is still the live one.
    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running && self.generation == generation
    }

    /// Starts the timer that re-attempts host ports another process was holding.
    ///
    /// Retrying only on container events is not enough: the conflict is on the *Mac*,
    /// so the event that resolves it — somebody quitting the app that had the port —
    /// produces nothing for Docker to tell us about. Without a clock of its own, a
    /// port lost to a transient conflict stayed lost for as long as the container ran.
    private func startRetryTimer() {
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(
            deadline: .now() + PortForwarder.bindRetryInterval,
            repeating: PortForwarder.bindRetryInterval)
        timer.setEventHandler { [weak self] in
            self?.retryFailedBinds()
        }
        lock.lock()
        let previous = retryTimer
        retryTimer = timer
        lock.unlock()
        previous?.cancel()
        timer.resume()
    }

    /// Re-attempts every failed bind whose backoff has elapsed. Runs on ``workQueue``.
    private func retryFailedBinds() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        let generation = self.generation
        let now = Date()
        let due = failedBinds.values
            .filter { $0.nextAttemptAt <= now }
            .map(\.binding)
            .sorted { $0.hostPort < $1.hostPort }
        lock.unlock()

        for binding in due {
            openForward(binding, generation: generation)
        }
    }

    // MARK: - Event stream

    /// Reconnect loop around ``streamEvents(generation:)``.
    private func runEventStream(generation: Int) {
        var backoff = PortForwarder.minimumBackoff
        var quietFailures = 0

        while isCurrent(generation) {
            // Connecting before dockerd is serving would just churn: the guest-side
            // proxy accepts and then immediately closes. Waiting on the readiness the
            // boot probe already establishes keeps the log free of noise that is not
            // a problem.
            guard vm.isDockerReady else {
                sleepInterruptibly(0.25, generation: generation)
                continue
            }
            let startedAt = Date()
            do {
                try streamEvents(generation: generation)
            } catch {
                guard isCurrent(generation) else { return }
                // The first failure of a run is worth a line; the retries are not.
                if quietFailures == 0 {
                    log.warn("docker event stream unavailable (\(error)); retrying")
                }
                quietFailures += 1
            }
            // Only a subscription that actually *held* counts as recovery. Resetting
            // the backoff on any clean EOF would turn a dockerd that accepts and
            // immediately closes into a twice-a-second reconnect loop that never
            // slows down and never says anything.
            if Date().timeIntervalSince(startedAt) >= 5 {
                backoff = PortForwarder.minimumBackoff
                quietFailures = 0
            }
            guard isCurrent(generation) else { return }
            sleepInterruptibly(backoff, generation: generation)
            backoff = min(backoff * 2, PortForwarder.maximumBackoff)
        }
    }

    /// Sleeps in short slices so a ``stop()`` is noticed promptly.
    private func sleepInterruptibly(_ duration: TimeInterval, generation: Int) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline, isCurrent(generation) {
            usleep(50_000)
        }
    }

    /// Holds one Engine API event subscription open, refreshing ports as events arrive.
    ///
    /// Returns normally when the stream ends; throws when it could not be established.
    private func streamEvents(generation: Int) throws {
        let fd = try vm.connectVsockBlocking(port: MorbVsockPorts.dockerAPI, timeout: 10).get()
        defer { Darwin.close(fd) }
        POSIXSocketSupport.suppressSIGPIPE(fd)

        let request = MinimalHTTP.request(
            method: "GET", path: DockerAPIDecoding.eventsPath, closeWhenDone: false)
        guard POSIXSocketSupport.writeAll(fd, request) else {
            throw MorbError.io("could not send the events request: \(String(cString: strerror(errno)))")
        }

        var pending = Data()
        var head: HTTPResponseHead?
        var chunks = ChunkedBodyDecoder()
        var lines = LineAccumulator()

        while isCurrent(generation) {
            guard let piece = try readAvailable(fd: fd, timeoutMilliseconds: 500) else {
                return  // EOF: dockerd closed the stream
            }
            if piece.isEmpty { continue }  // poll tick; loop to re-check the generation
            pending.append(piece)

            if head == nil {
                guard let parsed = try MinimalHTTP.parseHead(pending) else {
                    guard pending.count <= 64 * 1024 else {
                        throw MorbError.protocolViolation("the Docker API sent an oversized response head")
                    }
                    continue
                }
                guard parsed.head.statusCode == 200 else {
                    throw MorbError.io(
                        "GET \(DockerAPIDecoding.eventsPath) returned HTTP \(parsed.head.statusCode)")
                }
                head = parsed.head
                pending = Data(pending.dropFirst(parsed.consumed))
                log.info("subscribed to the Docker container event stream")
                // Seed *after* the subscription is live, never before: a container
                // started in between would otherwise be absent from the snapshot and
                // produce no event either, and its port would stay unpublished until
                // something unrelated happened.
                scheduleRefresh(reason: "event stream connected")
            }

            let body = head!.isChunked ? try chunks.feed(pending) : pending
            pending = Data()

            for line in lines.feed(body) {
                guard let event = DockerAPIDecoding.containerEvent(line: line) else { continue }
                guard event.affectsPublishedPorts else { continue }
                let who = event.containerName ?? String(event.containerID.prefix(12))
                scheduleRefresh(reason: "container \(who) \(event.action)")
            }
        }
    }

    /// One `poll` + `read`. Returns `nil` at EOF and empty on a poll timeout.
    private func readAvailable(fd: Int32, timeoutMilliseconds: Int32) throws -> Data? {
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = POSIXSocketSupport.retryOnInterrupt {
            withUnsafeMutablePointer(to: &poller) { poll($0, 1, timeoutMilliseconds) }
        }
        if ready == 0 { return Data() }
        if ready < 0 {
            throw MorbError.io("poll on the Docker API failed: \(String(cString: strerror(errno)))")
        }

        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        let n = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return POSIXSocketSupport.readSome(fd, into: base, count: raw.count)
        }
        if n == 0 { return nil }
        if n < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK { return Data() }
            throw MorbError.io("reading the Docker API failed: \(String(cString: strerror(errno)))")
        }
        return Data(buffer[0..<n])
    }

    // MARK: - Refreshing the forward set

    /// Queues a `containers/json` re-read, collapsing a burst of events into one.
    private func scheduleRefresh(reason: String) {
        lock.lock()
        guard running, !refreshQueued else {
            lock.unlock()
            return
        }
        refreshQueued = true
        let generation = self.generation
        lock.unlock()

        workQueue.async { [weak self] in
            guard let self else { return }
            // Cleared before the work, not after: an event that lands *during* a
            // refresh describes a change the in-flight read may have missed, so it
            // must be able to queue another one.
            self.lock.lock()
            self.refreshQueued = false
            self.lock.unlock()

            guard self.isCurrent(generation) else { return }
            do {
                let bindings = try self.fetchPublishedPorts()
                guard self.isCurrent(generation) else { return }
                self.apply(bindings: bindings, generation: generation, reason: reason)
            } catch {
                guard self.isCurrent(generation) else { return }
                self.log.warn("could not read published ports (\(reason)): \(error)")
            }
        }
    }

    /// Reads `GET /containers/json` over a fresh vsock connection. Blocking.
    private func fetchPublishedPorts() throws -> [DockerPortBinding] {
        // 20 s overall: a 10 s connect plus a 10 s read, which is what this call had
        // before the budget became a single end-to-end number. Nothing waits on it, so
        // it can afford to be patient with a busy engine.
        let body = try getEngineJSON(path: DockerAPIDecoding.containersPath, timeout: 20)
        return try DockerAPIDecoding.publishedPorts(containersJSON: body)
    }

    /// How many containers the engine currently reports as running. Blocking.
    ///
    /// Lives here rather than in ``Daemon`` because this is where the vsock-to-Engine
    /// plumbing already is. It is called on the auto-suspend path, where the answer
    /// decides whether the guest — and therefore every running container — is allowed
    /// to be torn down, so the timeout is short and any failure is the caller's to
    /// interpret conservatively.
    ///
    /// - Important: blocking. Never call from the VM queue.
    public func runningContainerCount(timeout: TimeInterval = 5) throws -> Int {
        let body = try getEngineJSON(path: DockerAPIDecoding.runningContainersPath, timeout: timeout)
        return try DockerAPIDecoding.containerCount(containersJSON: body)
    }

    /// Performs one `GET` against the guest's Engine API and returns the body. Blocking.
    ///
    /// `timeout` is the budget for the *whole* exchange, connect included, not for each
    /// phase. Callers size it against something — the auto-suspend path against the
    /// daemon's reply deadline — and a per-phase reading would quietly double it.
    private func getEngineJSON(path: String, timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        // Half the budget for the connect, so a guest that accepts slowly still leaves
        // time to actually read the answer.
        let fd = try vm.connectVsockBlocking(
            port: MorbVsockPorts.dockerAPI, timeout: max(0.5, min(timeout / 2, 10))).get()
        defer { Darwin.close(fd) }
        POSIXSocketSupport.suppressSIGPIPE(fd)

        // `Connection: close` makes the response self-delimiting even if dockerd
        // decides not to send a Content-Length, which turns "know when to stop
        // reading" into "read until EOF".
        let request = MinimalHTTP.request(method: "GET", path: path, closeWhenDone: true)
        guard POSIXSocketSupport.writeAll(fd, request) else {
            throw MorbError.io("could not send GET \(path): \(String(cString: strerror(errno)))")
        }
        var buffer = Data()
        var head: HTTPResponseHead?
        var headLength = 0

        while Date() < deadline {
            guard let piece = try readAvailable(fd: fd, timeoutMilliseconds: 250) else { break }
            buffer.append(piece)
            if buffer.count > 16 << 20 {
                throw MorbError.protocolViolation("containers/json response was implausibly large")
            }
            if head == nil {
                // Re-parsing a growing buffer is quadratic, so the head must arrive
                // in the first few kilobytes or the response is not one we can use.
                guard buffer.count <= 64 * 1024 else {
                    throw MorbError.protocolViolation("the Docker API sent an oversized response head")
                }
                if let parsed = try MinimalHTTP.parseHead(buffer) {
                    head = parsed.head
                    headLength = parsed.consumed
                }
            }
            if let head, let length = head.contentLength, buffer.count - headLength >= length {
                break
            }
        }

        guard let head else {
            throw MorbError.timeout("the Docker API did not answer GET \(path)")
        }
        guard head.statusCode == 200 else {
            throw MorbError.io("GET \(path) returned HTTP \(head.statusCode)")
        }

        var body = Data(buffer.dropFirst(headLength))
        if head.isChunked {
            var decoder = ChunkedBodyDecoder()
            body = try decoder.feed(body)
        } else if let length = head.contentLength, body.count > length {
            body = Data(body.prefix(length))
        }
        return body
    }

    /// Reconciles the live listeners with what Docker says is published.
    ///
    /// Only ever called from ``workQueue``, so the read-diff-write below cannot
    /// interleave with another reconciliation.
    private func apply(bindings: [DockerPortBinding], generation: Int, reason: String) {
        for udp in PortForwardPlan.udpHostPorts(bindings) {
            lock.lock()
            let isNew = announcedUDPPorts.insert(udp.hostPort).inserted
            lock.unlock()
            guard isNew else { continue }
            log.warn(
                "UDP port \(udp.hostPort) published by \(udp.containerName) is not forwarded to the "
                    + "Mac; Morbstack forwards TCP only for now")
        }

        lock.lock()
        let current = forwards.mapValues(\.binding)
        lock.unlock()

        let desired = PortForwardPlan.desiredListeners(bindings)

        // Ports nobody publishes any more must stop being retried, and a container
        // that was replaced changes the binding a retry should carry. Both are
        // invisible to the plan below, which only ever sees ports that *bound*.
        lock.lock()
        for port in failedBinds.keys {
            if let stillWanted = desired[port] {
                failedBinds[port]?.binding = stillWanted
            } else {
                failedBinds.removeValue(forKey: port)
            }
        }
        lock.unlock()

        let plan = PortForwardPlan.diff(current: current, desired: desired)
        guard !plan.close.isEmpty || !plan.open.isEmpty else { return }

        // Close first: a port whose container was replaced appears in both lists, and
        // rebinding it while the old listener still holds it would fail EADDRINUSE
        // against ourselves.
        for port in plan.close {
            closeForward(port: port, reason: reason)
        }
        for binding in plan.open {
            openForward(binding, generation: generation)
        }
    }

    private func closeForward(port: Int, reason: String) {
        lock.lock()
        let forward = forwards.removeValue(forKey: port)
        // The port is no longer wanted, so a pending retry for it is no longer wanted
        // either — otherwise the timer keeps chasing a container that is long gone.
        failedBinds.removeValue(forKey: port)
        lock.unlock()
        guard let forward else { return }
        forward.listener.stop()
        log.info("port forward removed: \(forward.binding.description) — after \(reason)")
    }

    /// Binds one host port, or records the failure and schedules a retry.
    ///
    /// Internal rather than private so the backoff can be tested against a real
    /// squatted port without standing up a guest.
    func openForward(_ binding: DockerPortBinding, generation: Int) {
        let port = binding.hostPort

        // A port under backoff is skipped silently. `apply` cannot tell the difference
        // between "never tried" and "tried and lost the port", because a failed bind
        // leaves no entry in `forwards`, so the check has to happen here or every
        // container event turns into another bind attempt and another log line.
        lock.lock()
        let deferred = failedBinds[port].map { $0.nextAttemptAt > Date() } ?? false
        lock.unlock()
        if deferred { return }

        let listener = TCPListener(port: port, queue: acceptQueue)
        listener.onConnection = { [weak self] fd in
            self?.handleAccepted(clientFD: fd, binding: binding, generation: generation)
        }

        do {
            try listener.start()
        } catch TCPListenerError.addressInUse {
            recordFailedBind(
                binding,
                reason: "another process holds 127.0.0.1:\(port); will retry")
            return
        } catch {
            recordFailedBind(binding, reason: "\(error); will retry")
            return
        }

        lock.lock()
        let accepted = running && self.generation == generation
        if accepted {
            forwards[port] = Forward(binding: binding, listener: listener)
            failedBinds.removeValue(forKey: port)
        }
        lock.unlock()

        guard accepted else {
            listener.stop()  // the forwarder was torn down while we were binding
            return
        }
        log.info("port forward added: \(binding.description) on 127.0.0.1:\(port)")
    }

    /// Remembers a bind that failed and schedules the next attempt.
    ///
    /// The backoff runs 5 s → 60 s. The first failure and every escalation are logged;
    /// the attempts in between are not, because a conflict that lasts an afternoon
    /// should cost one line per doubling rather than one line per five seconds.
    private func recordFailedBind(_ binding: DockerPortBinding, reason: String) {
        let port = binding.hostPort
        lock.lock()
        let attempts = (failedBinds[port]?.attempts ?? 0) + 1
        let delay = min(
            PortForwarder.minimumBindBackoff * pow(2, Double(attempts - 1)),
            PortForwarder.maximumBindBackoff)
        let previousDelay = failedBinds[port].map { _ in
            min(
                PortForwarder.minimumBindBackoff * pow(2, Double(attempts - 2)),
                PortForwarder.maximumBindBackoff)
        }
        failedBinds[port] = FailedBind(
            binding: binding,
            reason: reason,
            attempts: attempts,
            nextAttemptAt: Date().addingTimeInterval(delay))
        lock.unlock()

        // Log the first attempt, and thereafter only when the interval actually grew.
        guard previousDelay == nil || previousDelay! < delay else { return }
        log.warn(
            "cannot publish \(binding.description): \(reason) in \(Int(delay))s "
                + "(container \(binding.containerName) is not reachable on 127.0.0.1:\(port) "
                + "until then)")
    }

    // MARK: - Per-connection splicing

    private func handleAccepted(clientFD: Int32, binding: DockerPortBinding, generation: Int) {
        connectionStarted(generation)

        // Traffic on a published port is use of the stack, whether or not the
        // connection is still open when the idle timer next looks.
        busyHandler?()

        guard isCurrent(generation) else {
            Darwin.close(clientFD)
            connectionFinished(generation)
            return
        }

        vm.ensureRunning(timeout: PortForwarder.dialBootTimeout) { [weak self] result in
            guard let self else {
                Darwin.close(clientFD)
                return
            }
            if case .failure(let error) = result {
                self.log.warn("dropping a connection to 127.0.0.1:\(binding.hostPort): \(error)")
                Darwin.close(clientFD)
                self.connectionFinished(generation)
                return
            }
            if case .refused(let worthLogging) = self.claimDialSlot() {
                // Shedding beats stalling: a refused connection is a fast, legible
                // error at the client, where a queued one just holds a GCD thread and
                // makes the whole daemon slower at everything else.
                if worthLogging {
                    self.log.warn(
                        "shedding connections to published ports: "
                            + "\(PortForwarder.maxConcurrentDials) stream-dials are already in "
                            + "flight and the backlog is full; is the guest healthy?")
                }
                Darwin.close(clientFD)
                self.connectionFinished(generation)
                return
            }
            self.dialQueue.async { [weak self] in
                guard let self else {
                    Darwin.close(clientFD)
                    return
                }
                self.dialPermits.wait()
                defer {
                    self.dialPermits.signal()
                    self.releaseDialSlot()
                }
                self.dialAndSplice(clientFD: clientFD, binding: binding, generation: generation)
            }
        }
    }

    /// The outcome of asking for permission to dial.
    enum DialSlot: Equatable {
        /// A slot was claimed; the caller must call ``releaseDialSlot()`` when done.
        case granted
        /// At capacity. The accepted client must be closed; `worthLogging` is `true`
        /// only for the first refusal of a burst.
        case refused(worthLogging: Bool)
    }

    /// Claims one of the ``maxConcurrentDials`` slots, plus a small backlog.
    func claimDialSlot() -> DialSlot {
        let ceiling = PortForwarder.maxConcurrentDials + PortForwarder.dialBacklogAllowance
        lock.lock()
        defer { lock.unlock() }
        guard pendingDials < ceiling else {
            // One line per burst, not one per refused client: a burst is exactly the
            // situation in which logging per client makes everything worse.
            let first = !dialBurstLogged
            dialBurstLogged = true
            return .refused(worthLogging: first)
        }
        pendingDials += 1
        return .granted
    }

    /// Releases a dial slot claimed by ``claimDialSlot()``.
    func releaseDialSlot() {
        lock.lock()
        pendingDials = max(0, pendingDials - 1)
        if pendingDials == 0 { dialBurstLogged = false }
        lock.unlock()
    }

    /// Opens the stream-dial, performs the preamble handshake and starts the relay.
    /// Blocking; runs on ``dialQueue``.
    private func dialAndSplice(clientFD: Int32, binding: DockerPortBinding, generation: Int) {
        guard isCurrent(generation) else {
            Darwin.close(clientFD)
            connectionFinished(generation)
            return
        }

        let guestFD: Int32
        switch vm.connectVsockBlocking(port: MorbVsockPorts.streamDial, timeout: 5) {
        case .failure(let error):
            log.warn("could not open a stream-dial for \(binding.description): \(error)")
            Darwin.close(clientFD)
            connectionFinished(generation)
            return
        case .success(let fd):
            guestFD = fd
        }

        do {
            try StreamDial.perform(fd: guestFD, hostPort: binding.hostPort)
        } catch {
            log.warn("stream-dial to \(binding.description) refused: \(error)")
            Darwin.close(guestFD)
            Darwin.close(clientFD)
            connectionFinished(generation)
            return
        }

        startRelay(clientFD: clientFD, guestFD: guestFD, generation: generation)
    }

    private func startRelay(clientFD: Int32, guestFD: Int32, generation: Int) {
        let perRelayQueue = DispatchQueue(label: "dev.morbstack.portforward.splice", target: relayQueue)

        // Registered under a key minted before the relay exists, and inserted under
        // the same lock the completion takes — see DockerProxy.startRelay for why an
        // identity-keyed, register-after-start version leaks.
        lock.lock()
        relaySequence &+= 1
        let key = relaySequence
        let relay = FDRelay(fdA: clientFD, fdB: guestFD, queue: perRelayQueue) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.relays.removeValue(forKey: key)
            self.lock.unlock()
            self.connectionFinished(generation)
        }
        relays[key] = relay
        lock.unlock()

        relay.start()
    }

    /// Counts one accepted connection against `generation`.
    func connectionStarted(_ generation: Int) {
        lock.lock()
        connectionCounts[generation, default: 0] += 1
        lock.unlock()
    }

    /// Retires one connection from `generation`.
    ///
    /// A completion for a generation that has already been torn down finds no entry
    /// and does nothing, which is the entire point: it must not be able to debit the
    /// connections the *current* generation is counting on to stay awake.
    func connectionFinished(_ generation: Int) {
        lock.lock()
        if let live = connectionCounts[generation] {
            let remaining = live - 1
            if remaining <= 0 {
                connectionCounts.removeValue(forKey: generation)
            } else {
                connectionCounts[generation] = remaining
            }
        }
        lock.unlock()
    }

    /// The generation new connections are being counted against. Test seam.
    var currentGeneration: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }
}
