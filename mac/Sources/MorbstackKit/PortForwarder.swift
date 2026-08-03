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
/// 2. **Listeners.** Each published port gets the matching local loopback socket:
///    TCP preserves an explicit IPv6 loopback publication as `::1`; the existing UDP
///    data path remains IPv4 loopback-only.
/// 3. **Transport.** TCP accepts open a vsock stream-dial (2376) and use ``FDRelay``.
///    UDP clients instead get a long-lived framed datagram-dial (2378), preserving
///    individual messages and their reply flow.
///
/// The forwarder is owned by ``Daemon``. Its event stream is active only while the VM
/// is running; a fixed-port lease may bind just before a cold VM starts so the Engine
/// can never win a host-port race during a recognized create/start exchange.
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
        var binding: DockerPortBinding
        let listener: TCPListener
        /// A listener pre-bound by DockerProxy before the Engine saw its create
        /// request. Normal event-discovered forwards have no lease identity.
        let leaseID: UUID?
    }

    /// One active UDP publication. UDP's source tuple matters, so an endpoint owns
    /// a small set of per-Mac-client datagram-dial flows rather than one unlabelled
    /// shared stream to the guest.
    private final class UDPForward {
        var binding: DockerPortBinding
        let listener: UDPListener
        /// A listener retained before Docker received its create request. Event-only
        /// UDP forwards leave this `nil`; a mixed transport lease uses one shared ID
        /// for both TCP and UDP listener records.
        let leaseID: UUID?
        var flows: [UDPListener.Client: UDPFlow] = [:]

        init(binding: DockerPortBinding, listener: UDPListener, leaseID: UUID? = nil) {
            self.binding = binding
            self.listener = listener
            self.leaseID = leaseID
        }
    }

    /// A bounded host sender -> guest connected-UDP socket flow.
    ///
    /// Writes are serialized on a private queue so two datagrams from the same
    /// client cannot interleave their frame headers. Queue accounting prevents a
    /// local UDP flood from becoming an unbounded collection of Dispatch blocks.
    private final class UDPFlow {
        private enum State { case opening, open(Int32), closed }
        private static let maximumQueuedDatagrams = 64
        private static let maximumQueuedBytes = 1_048_576

        let client: UDPListener.Client
        let binding: DockerPortBinding
        let generation: Int
        private let queue = DispatchQueue(label: "dev.morbstack.portforward.udp-flow")
        private let lock = NSLock()
        private var state: State = .opening
        private var pending: [Data] = []
        private var queuedDatagrams = 0
        private var queuedBytes = 0
        private var lastActivity = Date()
        private var overloadLogged = false

        init(client: UDPListener.Client, binding: DockerPortBinding, generation: Int) {
            self.client = client
            self.binding = binding
            self.generation = generation
        }

        /// Returns true only once for an overload burst, so the caller can explain a
        /// dropped UDP datagram without logging one line per packet.
        func enqueue(_ datagram: Data, onWriteFailure: @escaping () -> Void) -> Bool {
            lock.lock()
            if case .closed = state {
                lock.unlock()
                return false
            }
            let overLimit = queuedDatagrams >= UDPFlow.maximumQueuedDatagrams
                || queuedBytes + datagram.count > UDPFlow.maximumQueuedBytes
            if overLimit {
                let shouldLog = !overloadLogged
                overloadLogged = true
                lock.unlock()
                return shouldLog
            }
            queuedDatagrams += 1
            queuedBytes += datagram.count
            lastActivity = Date()
            if case .opening = state {
                pending.append(datagram)
                lock.unlock()
                return false
            }
            lock.unlock()
            schedule(datagram, onWriteFailure: onWriteFailure)
            return false
        }

        func activate(_ descriptor: Int32, onWriteFailure: @escaping () -> Void) -> Bool {
            lock.lock()
            guard case .opening = state else {
                lock.unlock()
                Darwin.close(descriptor)
                return false
            }
            state = .open(descriptor)
            let buffered = pending
            pending.removeAll(keepingCapacity: false)
            lastActivity = Date()
            lock.unlock()
            for datagram in buffered {
                schedule(datagram, onWriteFailure: onWriteFailure)
            }
            return true
        }

        func noteReply() {
            lock.lock()
            lastActivity = Date()
            lock.unlock()
        }

        var openDescriptor: Int32? {
            lock.lock()
            defer { lock.unlock() }
            if case .open(let fd) = state { return fd }
            return nil
        }

        func idle(at date: Date, timeout: TimeInterval) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return date.timeIntervalSince(lastActivity) >= timeout
        }

        func close() {
            lock.lock()
            let descriptor: Int32
            switch state {
            case .open(let fd): descriptor = fd
            case .opening, .closed: descriptor = -1
            }
            state = .closed
            lock.unlock()
            guard descriptor >= 0 else { return }
            // Wake a reader and any frame writer before the descriptor can be reused.
            // The close itself is ordered after already-queued writes on the serial
            // flow queue, so a writer that observed this fd cannot accidentally write
            // into an unrelated later vsock connection with the same number.
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
            queue.async { Darwin.close(descriptor) }
        }

        private func write(_ datagram: Data, onFailure: @escaping () -> Void) {
            lock.lock()
            let descriptor: Int32
            if case .open(let fd) = state { descriptor = fd } else { descriptor = -1 }
            lock.unlock()
            let succeeded = descriptor >= 0 && DatagramDial.writeFrame(fd: descriptor, datagram: datagram)

            lock.lock()
            queuedDatagrams = max(0, queuedDatagrams - 1)
            queuedBytes = max(0, queuedBytes - datagram.count)
            if queuedDatagrams == 0 { overloadLogged = false }
            lock.unlock()
            if !succeeded { onFailure() }
        }

        private func schedule(_ datagram: Data, onWriteFailure: @escaping () -> Void) {
            queue.async { [weak self] in
                self?.write(datagram, onFailure: onWriteFailure)
            }
        }
    }

    /// Opaque ownership of listeners reserved before a recognized Docker create
    /// request is relayed. A token has no meaning outside this daemon process; the
    /// listeners are the actual exclusion mechanism.
    struct PortLease: Hashable, Sendable {
        let identifier: UUID
        let tcp: [DockerExplicitTCPPortBinding]
        let udp: [DockerExplicitUDPPortBinding]
    }

    /// The held lease plus the concrete bindings allocated for a dynamic create.
    ///
    /// `publications` preserves the request-plan order, allowing DockerProxy to put
    /// each kernel-reserved port into the exact `PortBindings` entry that caused it.
    /// The opaque lease contains both these entries and any fixed TCP entries from the
    /// same create, so all of them use one existing create/start lifecycle.
    struct DynamicPortReservation {
        let lease: PortLease
        let publications: [DockerDynamicPortPublication]
    }

    /// The only non-error way an inspect-derived reservation can decline. It means
    /// a lifecycle transition or another owner changed the in-memory ledger between
    /// the guest inspect and the atomic host bind; DockerProxy must retain its raw
    /// relay fallback rather than report a host-side publication error.
    private enum PortLeaseReservationAttempt {
        case reserved(DynamicPortReservation)
        case noLongerCurrent
    }

    /// Couples the recovered host lease to the immutable ID proved by a stopped
    /// container inspect, while rejecting a VM-forwarder generation that changed
    /// during that blocking inspect.
    private struct StartLeaseAssociation {
        let containerID: String
        let generation: Int
    }

    private struct LeaseRecord {
        let lease: PortLease
        var tcpListeners: [Int: TCPListener]
        var udpListeners: [Int: UDPListener]
        /// Ports withdrawn from this lease after Docker reported an ambiguous running
        /// publication. Retaining the lease record preserves container lifecycle
        /// bookkeeping, but never lets a later start observer reactivate a listener
        /// that was deliberately removed from the Mac.
        var withdrawnTCPHostPorts: Set<Int> = []
        /// UDP has a separate host socket namespace. A conflict can withdraw only
        /// that transport without allowing a later lifecycle promotion to reclaim it.
        var withdrawnUDPHostPorts: Set<Int> = []
        var containerID: String?
        var startClaimed = false
        var isForwarding = false
        /// `PublishAllPorts` allocations belong to one Engine start only. Moby keeps
        /// the config dynamic, so a later stop must close rather than pause them.
        var releaseOnStop = false
    }

    enum PortLeaseError: LocalizedError {
        case addressInUse(port: Int, protocolName: String)
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .addressInUse(let port, let protocolName):
                "driver failed programming external connectivity: Bind for local loopback port \(port)/\(protocolName) failed: port is already allocated"
            case .unavailable(let message):
                message
            }
        }
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
    private let udpDialQueue = DispatchQueue(
        label: "dev.morbstack.portforward.udp-dial", qos: .userInitiated, attributes: .concurrent)
    private let relayQueue = DispatchQueue(
        label: "dev.morbstack.portforward.relay", attributes: .concurrent)

    /// Permits for ``dialQueue``; see ``maxConcurrentDials``.
    private let dialPermits = DispatchSemaphore(value: PortForwarder.maxConcurrentDials)
    /// UDP flows are long-lived. A smaller setup limit leaves capacity for interactive
    /// TCP accepts while preventing one noisy datagram service from creating unlimited
    /// blocked vsock connects.
    private let udpDialPermits = DispatchSemaphore(value: 16)

    private let lock = NSLock()
    private var running = false
    /// Bumped by every ``start()`` and ``stop()``; workers carry the value they were
    /// launched with and exit as soon as it goes stale.
    private var generation = 0
    private var forwards: [Int: Forward] = [:]
    private var udpForwards: [Int: UDPForward] = [:]
    /// Fixed TCP/UDP listeners held continuously from a recognized create through a
    /// matching start handoff (or container destruction/daemon stop).
    private var leases: [UUID: LeaseRecord] = [:]
    private var leaseByContainerID: [String: UUID] = [:]
    /// Persistent host sessions for `-P` containers owned by Engine restart
    /// policy. They survive individual container restarts but are discarded with
    /// the VM generation, then rebuilt from the Engine's persisted metadata.
    private var publishAllRestartSessions: [String: PublishAllPortAllocator.Session] = [:]
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
    private var failedBinds: [Int: FailedBind] = [:]
    private var failedUDPBinds: [Int: FailedBind] = [:]
    /// Docker snapshots that claim one Mac endpoint for competing targets. These are
    /// terminal for their snapshot, not retryable host bind failures.
    private var conflictingTCPForwards: [Int: PortForwardPlan.ListenerConflict] = [:]
    private var conflictingUDPForwards: [Int: PortForwardPlan.ListenerConflict] = [:]
    private var retryTimer: DispatchSourceTimer?
    /// Dials started but not yet spliced, throttled by ``maxConcurrentDials``.
    private var pendingDials = 0
    /// Set while a burst is being shed, so the refusal is logged once and not per client.
    private var dialBurstLogged = false

    /// Global, not per port: each UDP client flow holds a vsock connection and a
    /// guest thread, so letting every published port consume 128 would multiply the
    /// guest resource budget rather than enforce one.
    private static let maximumUDPFlows = 48
    private static let udpFlowIdleTimeout: TimeInterval = 60

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
        let tcp = forwards.keys.sorted().compactMap { forwards[$0]?.binding.description }
        let udp = udpForwards.keys.sorted().compactMap { udpForwards[$0]?.binding.description }
        return tcp + udp
    }

    /// An atomic, structured view of Morbstack-owned loopback TCP forwards for the
    /// pure local-domain claim reconciler.
    ///
    /// This does not expose listeners, cause a refresh, or reserve a port. The caller
    /// must pair it with a fresh Engine `running`-container snapshot before trusting
    /// a prospective domain claim. Failed and conflicting ports are captured under
    /// the same lock as live listeners so a stale active entry can never win over a
    /// known denial.
    public var localDomainForwardSnapshot: MorbLocalDomain.LoopbackTCPForwardSnapshot {
        lock.lock()
        defer { lock.unlock() }

        let active = forwards.values.compactMap { forward -> MorbLocalDomain.LoopbackTCPForward? in
            let binding = forward.binding
            guard binding.networkProtocol == "tcp",
                  (1...65_535).contains(binding.hostPort),
                  !binding.containerID.isEmpty
            else {
                return nil
            }
            return MorbLocalDomain.LoopbackTCPForward(
                ownerID: binding.containerID,
                hostPort: UInt16(binding.hostPort))
        }.sorted { lhs, rhs in
            lhs.hostPort == rhs.hostPort ? lhs.ownerID < rhs.ownerID : lhs.hostPort < rhs.hostPort
        }

        let failed = Set(failedBinds.keys.compactMap(Self.validTCPHostPort))
        let conflicts = Set(conflictingTCPForwards.keys.compactMap(Self.validTCPHostPort))
        return MorbLocalDomain.LoopbackTCPForwardSnapshot(
            forwarderIsRunning: running,
            activeForwards: active,
            failedHostPorts: failed,
            conflictingHostPorts: conflicts)
    }

    private static func validTCPHostPort(_ port: Int) -> UInt16? {
        guard (1...65_535).contains(port) else { return nil }
        return UInt16(port)
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
        let tcp: [String] = Set(failedBinds.keys).union(conflictingTCPForwards.keys)
            .sorted().compactMap { port -> String? in
                if let conflict = conflictingTCPForwards[port] { return conflict.diagnostic }
                guard let failure = failedBinds[port] else { return nil }
                return "\(failure.binding.description) — \(failure.reason)"
        }
        let udp: [String] = Set(failedUDPBinds.keys).union(conflictingUDPForwards.keys)
            .sorted().compactMap { port -> String? in
                if let conflict = conflictingUDPForwards[port] { return conflict.diagnostic }
                guard let failure = failedUDPBinds[port] else { return nil }
                return "\(failure.binding.description) — \(failure.reason)"
        }
        return tcp + udp
    }

    /// `true` between ``start()`` and ``stop()``.
    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    // MARK: - Fixed transport-indexed create/start leases

    /// Reserves the whole fixed transport set from one Docker create request. TCP and
    /// UDP are separate socket spaces, but neither can be associated, activated, or
    /// later released independently of the same container lifecycle.
    func reserveExplicitPorts(_ plan: DockerFixedPortLeasePlan) throws -> PortLease {
        precondition(!plan.isEmpty, "a fixed port lease needs at least one publication")
        guard case .reserved(let reservation) = try reservePorts(
            fixedTCP: plan.tcp,
            fixedUDP: plan.udp,
            dynamic: [])
        else {
            preconditionFailure("an unconditional fixed port reservation cannot become stale")
        }
        return reservation.lease
    }

    /// Reserves fixed and kernel-selected TCP/UDP ports as one lease.
    ///
    /// The input order is retained exactly so the proxy can replace each original
    /// JSON binding with the corresponding held endpoint, including mixed transport
    /// requests. A bind failure unwinds every listener before dockerd sees create.
    func reserveDynamicPorts(
        _ publications: [DockerDynamicPortPublication],
        alongside fixedPlan: DockerFixedPortLeasePlan
    ) throws -> DynamicPortReservation {
        precondition(!publications.isEmpty, "a dynamic published-port transaction needs at least one publication")
        guard case .reserved(let reservation) = try reservePorts(
            fixedTCP: fixedPlan.tcp,
            fixedUDP: fixedPlan.udp,
            dynamic: publications)
        else {
            preconditionFailure("an unconditional dynamic published-port reservation cannot become stale")
        }
        return reservation
    }

    /// Reserves the complete effective `docker -P` set reported by patched Moby.
    /// The Unix/vsock bridge has already proved the immutable container ID; all
    /// entries are held as one transaction and are released on the next stop so Moby
    /// can allocate a fresh set on restart.
    func reservePublishAllPorts(
        containerID: String,
        requests: [DockerPublishAllPortRequest]
    ) throws -> [Int] {
        guard DockerPortPublicationPreflight.isFullContainerID(containerID),
              !requests.isEmpty,
              requests.count <= DockerPortPublicationPreflight.maximumSynchronousFixedPortBindings
        else {
            throw PortLeaseError.unavailable("invalid Docker publish-all allocation request")
        }

        // Moby reaches this hook only after it has stopped the previous instance.
        // The Engine event stream is asynchronous, so its `die`/`stop` event may not
        // have released our old ephemeral lease yet. Retire only a prior `-P` lease
        // for this same immutable container before atomically choosing its replacement.
        lock.lock()
        let previous = leaseByContainerID[containerID].flatMap { identifier in
            leases[identifier]?.releaseOnStop == true ? identifier : nil
        }
        lock.unlock()
        if let previous {
            releaseLease(previous, reason: "Moby began a fresh publish-all allocation")
        }

        var fixedTCP: [DockerExplicitTCPPortBinding] = []
        var fixedUDP: [DockerExplicitUDPPortBinding] = []
        var dynamic: [DockerDynamicPortPublication] = []
        dynamic.reserveCapacity(requests.count)
        for request in requests {
            let allowedAddresses = request.transport == .tcp
                ? PortForwardPlan.forwardableHostAddresses
                : PortForwardPlan.forwardableUDPHostAddresses
            guard allowedAddresses.contains(request.hostIP),
                  (0...65535).contains(request.requestedHostPort),
                  (1...65535).contains(request.containerPort)
            else {
                throw PortLeaseError.unavailable("unsupported Docker publish-all host publication")
            }
            if request.requestedHostPort == 0 {
                dynamic.append(DockerDynamicPortPublication(
                    transport: request.transport,
                    hostIP: request.hostIP,
                    hostPort: 0,
                    containerPort: request.containerPort))
            } else if request.transport == .tcp {
                fixedTCP.append(DockerExplicitTCPPortBinding(
                    hostIP: request.hostIP,
                    hostPort: request.requestedHostPort,
                    containerPort: request.containerPort))
            } else {
                fixedUDP.append(DockerExplicitUDPPortBinding(
                    hostIP: request.hostIP,
                    hostPort: request.requestedHostPort,
                    containerPort: request.containerPort))
            }
        }

        guard case .reserved(let reservation) = try reservePorts(
            fixedTCP: fixedTCP,
            fixedUDP: fixedUDP,
            dynamic: dynamic,
            releaseOnStop: true)
        else {
            throw PortLeaseError.unavailable("publish-all allocation became stale")
        }
        guard associate(reservation.lease, withContainerID: containerID) else {
            abandon(reservation.lease, reason: "publish-all allocation could not be associated with its container")
            throw PortLeaseError.unavailable("publish-all allocation lost its container identity")
        }
        var dynamicPublications = reservation.publications.makeIterator()
        return try requests.map { request in
            guard request.requestedHostPort == 0 else { return request.requestedHostPort }
            guard let publication = dynamicPublications.next() else {
                throw PortLeaseError.unavailable("publish-all allocation returned the wrong number of ports")
            }
            return publication.hostPort
        }
    }

    /// Rebuilds the complete fixed TCP/UDP lease after VM stop. Recovery is all or
    /// nothing: inspect must prove every retained binding before the host opens one
    /// socket, otherwise the lifecycle request remains an ordinary raw relay.
    func reserveStoppedContainerStartLease(
        containerID: String,
        timeout: TimeInterval = 5
    ) throws -> PortLease? {
        guard DockerPortPublicationPreflight.isFullContainerID(containerID) else {
            return nil
        }

        lock.lock()
        guard running, leaseByContainerID[containerID] == nil else {
            lock.unlock()
            return nil
        }
        let inspectedGeneration = generation
        lock.unlock()

        let inspectBody: Data
        do {
            inspectBody = try getEngineJSON(
                path: DockerAPIDecoding.containerInspectPath(containerID: containerID),
                timeout: timeout)
        } catch {
            log.info("could not inspect stopped container \(String(containerID.prefix(12))) for fixed-port lease recovery: \(error)")
            return nil
        }

        guard let plan = DockerPortPublicationPreflight.stoppedContainerFixedPortLeasePlan(
            in: inspectBody,
            expectedContainerID: containerID)
        else {
            return nil
        }

        let association = StartLeaseAssociation(
            containerID: containerID,
            generation: inspectedGeneration)
        switch try reservePorts(
            fixedTCP: plan.tcp,
            fixedUDP: plan.udp,
            dynamic: [],
            startLeaseAssociation: association)
        {
        case .reserved(let reservation):
            log.info(
                "recovered fixed-port lease \(leasePortDescription(reservation.lease)) for stopped container "
                    + "\(String(containerID.prefix(12))) before Docker start")
            return reservation.lease
        case .noLongerCurrent:
            return nil
        }
    }

    /// Inspects an immutable stopped container only to decide whether the
    /// publish-all host session is needed. The effective endpoint set stays in
    /// Moby because only Moby has merged image `EXPOSE` metadata at this point.
    func stoppedContainerUsesPublishAllPorts(
        containerID: String,
        timeout: TimeInterval = 5
    ) -> Bool {
        guard DockerPortPublicationPreflight.isFullContainerID(containerID) else { return false }
        let inspectBody: Data
        do {
            inspectBody = try getEngineJSON(
                path: DockerAPIDecoding.containerInspectPath(containerID: containerID),
                timeout: timeout)
        } catch {
            log.info("could not inspect stopped container \(String(containerID.prefix(12))) for publish-all recovery: \(error)")
            return false
        }
        return DockerPortPublicationPreflight.stoppedContainerUsesPublishAllPorts(
            in: inspectBody,
            expectedContainerID: containerID)
    }

    /// The one ledger lock covers all fixed TCP/UDP binds and dynamic TCP/UDP
    /// allocation. A failed bind rolls every listener from this request back before
    /// Docker sees a create/start success, so the host never reports a partial lease.
    private func reservePorts(
        fixedTCP: [DockerExplicitTCPPortBinding],
        fixedUDP: [DockerExplicitUDPPortBinding],
        dynamic: [DockerDynamicPortPublication],
        startLeaseAssociation: StartLeaseAssociation? = nil,
        releaseOnStop: Bool = false
    ) throws -> PortLeaseReservationAttempt {
        let leaseID = UUID()
        var tcpListeners: [Int: TCPListener] = [:]
        var udpListeners: [Int: UDPListener] = [:]
        var allocatedDynamic: [DockerDynamicPortPublication] = []
        var allocatedDynamicTCP: [DockerExplicitTCPPortBinding] = []
        var allocatedDynamicUDP: [DockerExplicitUDPPortBinding] = []
        let expectedPublicationCount = fixedTCP.count + fixedUDP.count + dynamic.count

        lock.lock()
        if let startLeaseAssociation {
            guard running,
                  generation == startLeaseAssociation.generation,
                  leaseByContainerID[startLeaseAssociation.containerID] == nil
            else {
                lock.unlock()
                return .noLongerCurrent
            }
        }
        do {
            for publication in fixedTCP {
                let loopbackAddress = TCPListener.LoopbackAddress
                    .forDockerHostAddress(publication.hostIP)
                guard conflictingTCPForwards[publication.hostPort] == nil else {
                    throw PortLeaseError.unavailable(
                        "cannot reserve published TCP port \(loopbackAddress.rawValue):\(publication.hostPort): "
                            + "Docker currently reports competing targets for this host port")
                }
                let listener = TCPListener(
                    port: publication.hostPort,
                    queue: acceptQueue,
                    loopbackAddress: loopbackAddress)
                do {
                    try listener.start()
                } catch TCPListenerError.addressInUse {
                    throw PortLeaseError.addressInUse(port: publication.hostPort, protocolName: "tcp")
                } catch {
                    throw PortLeaseError.unavailable(
                        "could not reserve published TCP port \(loopbackAddress.rawValue):\(publication.hostPort): \(error.localizedDescription)")
                }
                tcpListeners[publication.hostPort] = listener
            }

            for publication in fixedUDP {
                guard conflictingUDPForwards[publication.hostPort] == nil else {
                    throw PortLeaseError.unavailable(
                        "cannot reserve published UDP port 127.0.0.1:\(publication.hostPort): "
                            + "Docker currently reports competing targets for this host port")
                }
                let listener = UDPListener(port: publication.hostPort, queue: acceptQueue)
                do {
                    // A held UDP socket drains and discards packets until the exact
                    // successful start response installs its synchronized handler.
                    try listener.start()
                } catch UDPListener.Error.addressInUse {
                    throw PortLeaseError.addressInUse(port: publication.hostPort, protocolName: "udp")
                } catch {
                    throw PortLeaseError.unavailable(
                        "could not reserve published UDP port 127.0.0.1:\(publication.hostPort): \(error.localizedDescription)")
                }
                udpListeners[publication.hostPort] = listener
            }

            for publication in dynamic {
                switch publication.transport {
                case .tcp:
                    let loopbackAddress = TCPListener.LoopbackAddress
                        .forDockerHostAddress(publication.hostIP)
                    let listener = TCPListener(
                        port: 0,
                        queue: acceptQueue,
                        loopbackAddress: loopbackAddress)
                    do {
                        try listener.start()
                    } catch {
                        throw PortLeaseError.unavailable(
                            "could not allocate a dynamic published TCP port on \(loopbackAddress.rawValue): \(error.localizedDescription)")
                    }
                    let allocated = DockerExplicitTCPPortBinding(
                        hostIP: publication.hostIP,
                        hostPort: listener.port,
                        containerPort: publication.containerPort)
                    guard tcpListeners[allocated.hostPort] == nil else {
                        listener.stop()
                        throw PortLeaseError.unavailable(
                            "kernel returned an already-reserved dynamic TCP port \(allocated.hostPort)")
                    }
                    tcpListeners[allocated.hostPort] = listener
                    allocatedDynamicTCP.append(allocated)
                    allocatedDynamic.append(DockerDynamicPortPublication(
                        transport: .tcp,
                        hostIP: allocated.hostIP,
                        hostPort: allocated.hostPort,
                        containerPort: allocated.containerPort))

                case .udp:
                    let listener = UDPListener(port: 0, queue: acceptQueue)
                    do {
                        // Like fixed UDP leases, this bound socket drains until the
                        // create-associated listener receives an exact start success.
                        try listener.start()
                    } catch {
                        throw PortLeaseError.unavailable(
                            "could not allocate a dynamic published UDP port on 127.0.0.1: \(error.localizedDescription)")
                    }
                    let allocated = DockerExplicitUDPPortBinding(
                        hostIP: publication.hostIP,
                        hostPort: listener.port,
                        containerPort: publication.containerPort)
                    guard udpListeners[allocated.hostPort] == nil else {
                        listener.stop()
                        throw PortLeaseError.unavailable(
                            "kernel returned an already-reserved dynamic UDP port \(allocated.hostPort)")
                    }
                    udpListeners[allocated.hostPort] = listener
                    allocatedDynamicUDP.append(allocated)
                    allocatedDynamic.append(DockerDynamicPortPublication(
                        transport: .udp,
                        hostIP: allocated.hostIP,
                        hostPort: allocated.hostPort,
                        containerPort: allocated.containerPort))
                }
            }

            let allTCP = fixedTCP + allocatedDynamicTCP
            let allUDP = fixedUDP + allocatedDynamicUDP
            guard allTCP.count + allUDP.count == expectedPublicationCount else {
                throw PortLeaseError.unavailable("fixed port allocation did not retain every requested listener")
            }
            let lease = PortLease(identifier: leaseID, tcp: allTCP, udp: allUDP)
            leases[lease.identifier] = LeaseRecord(
                lease: lease,
                tcpListeners: tcpListeners,
                udpListeners: udpListeners,
                containerID: startLeaseAssociation?.containerID,
                releaseOnStop: releaseOnStop)
            if let startLeaseAssociation {
                leaseByContainerID[startLeaseAssociation.containerID] = lease.identifier
            }
            lock.unlock()
        } catch {
            lock.unlock()
            for listener in tcpListeners.values { listener.stop() }
            for listener in udpListeners.values { listener.stop() }
            throw error
        }

        let lease = PortLease(
            identifier: leaseID,
            tcp: fixedTCP + allocatedDynamicTCP,
            udp: fixedUDP + allocatedDynamicUDP)
        let purpose = startLeaseAssociation == nil ? "Docker create" : "Docker start"
        log.info("reserved fixed-port lease \(leasePortDescription(lease)) for \(purpose)")
        return .reserved(DynamicPortReservation(lease: lease, publications: allocatedDynamic))
    }

    private func leasePortDescription(_ lease: PortLease) -> String {
        (lease.tcp.map { "\($0.hostPort)/tcp" } + lease.udp.map { "\($0.hostPort)/udp" })
            .joined(separator: ", ")
    }

    /// Records the only stable identity returned by Docker's create response.
    ///
    /// The response observer calls this before the bytes reach the Docker client, so
    /// a following `start` can claim the already-bound listener rather than probing a
    /// port a second time.
    func associate(_ lease: PortLease, withContainerID containerID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var record = leases[lease.identifier], record.containerID == nil,
              leaseByContainerID[containerID] == nil
        else {
            return false
        }
        record.containerID = containerID
        leases[lease.identifier] = record
        leaseByContainerID[containerID] = lease.identifier
        return true
    }

    /// Claims a created lease for a start/restart response observer.
    ///
    /// Docker routes accept names and ID prefixes, but this host-side lease ledger
    /// cannot prove which object dockerd will resolve for either spelling. A full
    /// immutable ID is the only request identifier that can safely activate the
    /// listener before the Engine's `204`; all other spellings remain byte-for-byte
    /// relays and rely on the ordinary Engine event reconciliation.
    func claimStartLease(containerIdentifier: String) -> PortLease? {
        lock.lock()
        defer { lock.unlock() }
        guard DockerPortPublicationPreflight.isFullContainerID(containerIdentifier),
              let identifier = leaseByContainerID[containerIdentifier],
              var record = leases[identifier], !record.startClaimed
        else {
            return nil
        }
        record.startClaimed = true
        leases[identifier] = record
        return record.lease
    }

    /// `PublishAllPorts` cannot use a retained fixed-port start claim: Moby must
    /// ask the host allocator again for every start/restart, including an immediate
    /// stop→start before event reconciliation has observed the stop.
    func requiresPublishAllAllocator(containerIdentifier: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard DockerPortPublicationPreflight.isFullContainerID(containerIdentifier),
              let identifier = leaseByContainerID[containerIdentifier],
              let record = leases[identifier]
        else { return false }
        return record.releaseOnStop
    }

    /// Promotes a lease after Docker's normal `204` start reply is observed. The
    /// response observer runs before FDRelay writes those bytes to the client, so the
    /// service never sees a successful start while Morbstack has released its host
    /// port in between.
    @discardableResult
    func completeStart(_ lease: PortLease, succeeded: Bool) -> Bool {
        guard succeeded else {
            releaseStartClaim(lease)
            return false
        }
        return promoteLease(lease.identifier)
    }

    /// Releases a provisional lease when create failed, its response was not in the
    /// bounded shape this protocol can prove, or the client connection ended first.
    func abandon(_ lease: PortLease, reason: String) {
        releaseLease(lease.identifier, reason: reason)
    }

    /// The event stream gives a full ID on `destroy`; this removes a lease even for a
    /// container that was created but never started and therefore never appeared in
    /// the running-container port snapshot.
    func releaseLease(forContainerID containerID: String, reason: String) {
        lock.lock()
        let identifier = leaseByContainerID[containerID]
        lock.unlock()
        guard let identifier else { return }
        releaseLease(identifier, reason: reason)
    }

    private func releaseStartClaim(_ lease: PortLease) {
        lock.lock()
        guard var record = leases[lease.identifier] else {
            lock.unlock()
            return
        }
        record.startClaimed = false
        leases[lease.identifier] = record
        lock.unlock()
    }

    /// Transfers the entire continuously-held transport set into active forward maps.
    /// Listener descriptors never close here: TCP receives its stream-dial handler,
    /// while UDP receives its synchronized datagram handler only after an exact
    /// successful start/restart handoff.
    @discardableResult
    private func promoteLease(_ identifier: UUID) -> Bool {
        lock.lock()
        guard var record = leases[identifier], let containerID = record.containerID else {
            lock.unlock()
            return false
        }
        if record.isForwarding {
            record.startClaimed = false
            leases[identifier] = record
            lock.unlock()
            return true
        }
        // A create can cold-boot the VM. In that small interval `Daemon` has not yet
        // started the event stream, but the guest may already return the start `204`.
        // Arm the listener for the generation `start()` is about to publish, so the
        // response still has the no-gap handoff contract. Connections accepted before
        // `running` becomes true are conservatively closed by `handleAccepted`.
        let generation = running ? self.generation : self.generation + 1
        let activeTCP = record.lease.tcp.filter {
            !record.withdrawnTCPHostPorts.contains($0.hostPort)
        }
        let activeUDP = record.lease.udp.filter {
            !record.withdrawnUDPHostPorts.contains($0.hostPort)
        }
        guard !activeTCP.isEmpty || !activeUDP.isEmpty else {
            record.startClaimed = false
            leases[identifier] = record
            lock.unlock()
            return false
        }
        for publication in activeTCP {
            guard let listener = record.tcpListeners[publication.hostPort] else {
                record.startClaimed = false
                leases[identifier] = record
                lock.unlock()
                return false
            }
            let binding = DockerPortBinding(
                hostIP: publication.hostIP,
                hostPort: publication.hostPort,
                containerPort: publication.containerPort,
                networkProtocol: "tcp",
                containerID: containerID,
                containerName: String(containerID.prefix(12)))
            listener.setConnectionHandler { [weak self] fd in
                self?.handleAccepted(clientFD: fd, binding: binding, generation: generation)
            }
            forwards[publication.hostPort] = Forward(
                binding: binding, listener: listener, leaseID: identifier)
        }
        for publication in activeUDP {
            guard let listener = record.udpListeners[publication.hostPort] else {
                record.startClaimed = false
                leases[identifier] = record
                lock.unlock()
                return false
            }
            let binding = DockerPortBinding(
                hostIP: publication.hostIP,
                hostPort: publication.hostPort,
                containerPort: publication.containerPort,
                networkProtocol: "udp",
                containerID: containerID,
                containerName: String(containerID.prefix(12)))
            // The forward map is installed while the forwarder ledger remains locked.
            // A packet drained immediately after this handler assignment blocks on
            // that same ledger and cannot see a half-installed UDP forward.
            listener.setDatagramHandler { [weak self, weak listener] datagram, client in
                guard let self, let listener else { return }
                self.handleUDPDatagram(
                    datagram, from: client, binding: binding, listener: listener, generation: generation)
            }
            udpForwards[publication.hostPort] = UDPForward(
                binding: binding, listener: listener, leaseID: identifier)
        }
        record.isForwarding = true
        record.startClaimed = false
        leases[identifier] = record
        lock.unlock()

        for publication in activeTCP {
            log.info(
                "port lease activated: \(publication.hostPort) -> \(String(containerID.prefix(12))):\(publication.containerPort)/tcp")
        }
        for publication in activeUDP {
            log.info(
                "port lease activated: \(publication.hostPort) -> \(String(containerID.prefix(12))):\(publication.containerPort)/udp")
        }
        return true
    }

    /// Stops forwarding every transport in one lease while retaining every bound
    /// socket for a later start. UDP flows are closed before the held socket returns
    /// to drain-only mode, so no datagram can cross a stopped-container lifecycle.
    private func deactivateLease(_ identifier: UUID, reason: String) {
        lock.lock()
        let releaseOnStop = leases[identifier]?.releaseOnStop ?? false
        lock.unlock()
        if releaseOnStop {
            releaseLease(identifier, reason: reason)
            return
        }
        var tcpListeners: [TCPListener] = []
        var udpListeners: [UDPListener] = []
        var flows: [UDPFlow] = []
        lock.lock()
        guard var record = leases[identifier] else {
            lock.unlock()
            return
        }
        for publication in record.lease.tcp {
            if forwards[publication.hostPort]?.leaseID == identifier {
                forwards.removeValue(forKey: publication.hostPort)
            }
            if let listener = record.tcpListeners[publication.hostPort] {
                tcpListeners.append(listener)
            }
        }
        for publication in record.lease.udp {
            if let forward = udpForwards[publication.hostPort], forward.leaseID == identifier {
                udpForwards.removeValue(forKey: publication.hostPort)
                flows.append(contentsOf: forward.flows.values)
            }
            if let listener = record.udpListeners[publication.hostPort] {
                udpListeners.append(listener)
            }
        }
        record.isForwarding = false
        record.startClaimed = false
        leases[identifier] = record
        lock.unlock()

        for listener in tcpListeners { listener.setConnectionHandler(nil) }
        for listener in udpListeners { listener.setDatagramHandler(nil) }
        for flow in flows { flow.close() }
        log.info("fixed-port lease paused: \(leasePortDescription(record.lease)) — after \(reason)")
    }

    /// Withdraws only the concrete listeners whose Docker endpoint is ambiguous.
    ///
    /// A fixed-create lease can cover several independent ports, so releasing its
    /// whole record would unnecessarily darken a non-conflicting publication. The
    /// record stays associated with its container for later destroy cleanup, while a
    /// withdrawn port is permanently excluded from any late start-observer promotion.
    private func withdrawConflictingTCPLeaseListeners(at ports: Set<Int>, reason: String) {
        guard !ports.isEmpty else { return }
        var listeners: [(port: Int, listener: TCPListener)] = []
        lock.lock()
        for identifier in Array(leases.keys) {
            guard var record = leases[identifier] else { continue }
            let withdrawn = record.tcpListeners.keys.filter { ports.contains($0) }
            guard !withdrawn.isEmpty else { continue }
            for port in withdrawn {
                guard let listener = record.tcpListeners.removeValue(forKey: port) else { continue }
                record.withdrawnTCPHostPorts.insert(port)
                if forwards[port]?.leaseID == identifier {
                    forwards.removeValue(forKey: port)
                }
                listeners.append((port, listener))
            }
            record.isForwarding = record.tcpListeners.keys.contains { forwards[$0]?.leaseID == identifier }
                || record.udpListeners.keys.contains { udpForwards[$0]?.leaseID == identifier }
            leases[identifier] = record
        }
        lock.unlock()

        for entry in listeners {
            entry.listener.stop()
            log.warn("withdrew fixed TCP lease on 127.0.0.1:\(entry.port) — \(reason)")
        }
    }

    /// UDP conflict withdrawal mirrors TCP's lease behavior but never shares a port
    /// map with it. The whole container lease remains associated for destroy cleanup;
    /// only the ambiguous UDP endpoint is permanently unavailable for later starts.
    private func withdrawConflictingUDPLeaseListeners(at ports: Set<Int>, reason: String) {
        guard !ports.isEmpty else { return }
        var listeners: [(port: Int, listener: UDPListener)] = []
        var flows: [UDPFlow] = []
        lock.lock()
        for identifier in Array(leases.keys) {
            guard var record = leases[identifier] else { continue }
            let withdrawn = record.udpListeners.keys.filter { ports.contains($0) }
            guard !withdrawn.isEmpty else { continue }
            for port in withdrawn {
                guard let listener = record.udpListeners.removeValue(forKey: port) else { continue }
                record.withdrawnUDPHostPorts.insert(port)
                if let forward = udpForwards[port], forward.leaseID == identifier {
                    udpForwards.removeValue(forKey: port)
                    flows.append(contentsOf: forward.flows.values)
                }
                listeners.append((port, listener))
            }
            record.isForwarding = record.tcpListeners.keys.contains { forwards[$0]?.leaseID == identifier }
                || record.udpListeners.keys.contains { udpForwards[$0]?.leaseID == identifier }
            leases[identifier] = record
        }
        lock.unlock()

        for flow in flows { flow.close() }
        for entry in listeners {
            entry.listener.stop()
            log.warn("withdrew fixed UDP lease on 127.0.0.1:\(entry.port) — \(reason)")
        }
    }

    private func releaseLease(_ identifier: UUID, reason: String) {
        lock.lock()
        guard let record = leases.removeValue(forKey: identifier) else {
            lock.unlock()
            return
        }
        if let containerID = record.containerID {
            leaseByContainerID.removeValue(forKey: containerID)
        }
        for publication in record.lease.tcp {
            if forwards[publication.hostPort]?.leaseID == identifier {
                forwards.removeValue(forKey: publication.hostPort)
            }
        }
        var udpFlows: [UDPFlow] = []
        for publication in record.lease.udp {
            if let forward = udpForwards[publication.hostPort], forward.leaseID == identifier {
                udpForwards.removeValue(forKey: publication.hostPort)
                udpFlows.append(contentsOf: forward.flows.values)
            }
        }
        lock.unlock()

        for listener in record.tcpListeners.values { listener.stop() }
        for listener in record.udpListeners.values { listener.stop() }
        for flow in udpFlows { flow.close() }
        log.info("released fixed-port lease \(leasePortDescription(record.lease)) — \(reason)")
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
        lock.unlock()

        log.info("port forwarding active; watching the Docker event stream")
        startRetryTimer()
        workQueue.async { [weak self] in
            self?.recoverPublishAllRestartPolicySessions()
        }
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
        guard running || !leases.isEmpty else {
            lock.unlock()
            return
        }
        running = false
        generation &+= 1
        let closing = forwards
        forwards.removeAll()
        let closingUDP = udpForwards
        udpForwards.removeAll()
        let closingLeases = leases.values
        leases.removeAll()
        leaseByContainerID.removeAll()
        let restartSessions = publishAllRestartSessions.values
        publishAllRestartSessions.removeAll()
        let inFlight = Array(relays.values)
        relays.removeAll()
        // Stale completions are allowed to arrive; they find no entry for their
        // generation and become no-ops rather than debits against the next run.
        connectionCounts.removeAll()
        failedBinds.removeAll()
        failedUDPBinds.removeAll()
        conflictingTCPForwards.removeAll()
        conflictingUDPForwards.removeAll()
        let timer = retryTimer
        retryTimer = nil
        lock.unlock()

        timer?.cancel()
        var listeners: [ObjectIdentifier: TCPListener] = [:]
        for forward in closing.values { listeners[ObjectIdentifier(forward.listener)] = forward.listener }
        for lease in closingLeases {
            for listener in lease.tcpListeners.values {
                listeners[ObjectIdentifier(listener)] = listener
            }
        }
        for listener in listeners.values { listener.stop() }
        for forward in closingUDP.values {
            forward.listener.stop()
            for flow in forward.flows.values { flow.close() }
        }
        for lease in closingLeases {
            for listener in lease.udpListeners.values { listener.stop() }
        }
        for relay in inFlight { relay.cancel() }
        for session in restartSessions { session.invalidate() }

        let because = reason.map { " (\($0))" } ?? ""
        if closing.isEmpty, closingUDP.isEmpty, closingLeases.isEmpty {
            log.info("port forwarding stopped\(because)")
        } else {
            // Named individually: this is the line a user greps for when
            // `curl 127.0.0.1:8080` stops answering, and "3 listener(s)" does not
            // tell them which three.
            let tcpPorts = Set(closing.keys).union(closingLeases.flatMap { $0.lease.tcp.map(\.hostPort) })
            let udpPorts = Set(closingUDP.keys).union(closingLeases.flatMap { $0.lease.udp.map(\.hostPort) })
            let descriptions = tcpPorts.sorted().map { "\($0)/tcp" }
                + udpPorts.sorted().map { "\($0)/udp" }
            let ports = descriptions.joined(separator: ", ")
            let subject = descriptions.count == 1 ? "port \(ports) is" : "ports \(ports) are"
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
        let dueUDP = failedUDPBinds.values
            .filter { $0.nextAttemptAt <= now }
            .map(\.binding)
            .sorted { $0.hostPort < $1.hostPort }
        lock.unlock()

        for binding in due {
            openForward(binding, generation: generation)
        }
        for binding in dueUDP {
            openUDPForward(binding, generation: generation)
        }
        expireUDPFlows(now: now)
    }

    /// UDP has no close handshake. Retire inactive client flows so a process that
    /// sprays one packet from thousands of ephemeral ports cannot keep vsock sockets
    /// forever. Sixty seconds is deliberately much longer than normal request/reply
    /// use while still bounding the guest-side connection count.
    private func expireUDPFlows(now: Date) {
        var expired: [UDPFlow] = []
        lock.lock()
        for forward in udpForwards.values {
            let clients = forward.flows.compactMap { client, flow in
                flow.idle(at: now, timeout: PortForwarder.udpFlowIdleTimeout) ? client : nil
            }
            for client in clients {
                if let flow = forward.flows.removeValue(forKey: client) { expired.append(flow) }
            }
        }
        lock.unlock()
        for flow in expired { flow.close() }
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
                if event.action == "destroy" {
                    // A never-started container never appears in the normal running
                    // port snapshot, so its destroy event is the direct cleanup path
                    // for a lease that intentionally kept its host port reserved.
                    releaseLease(forContainerID: event.containerID, reason: "container destroyed")
                }
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
                do {
                    try self.reconcileAssociatedLeases()
                } catch {
                    // Do not turn a successful running-port refresh into a failure
                    // merely because the slower all-container cleanup snapshot is
                    // unavailable. The held listener remains conservative until a
                    // future refresh or daemon stop can prove its owner is gone.
                    self.log.warn("could not reconcile fixed-port leases: \(error)")
                }
                self.apply(bindings: bindings, generation: generation, reason: reason)
                self.recoverPublishAllRestartPolicySessions()
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

    /// Reclaims leases belonging to containers that no longer exist, including a
    /// destroy event missed while the event stream was reconnecting. This deliberately
    /// asks `all=1`: a stopped but still-created container must keep its lease so a
    /// later `docker start` cannot lose the port to another Mac process.
    private func reconcileAssociatedLeases() throws {
        lock.lock()
        let associated = leaseByContainerID
        lock.unlock()
        guard !associated.isEmpty else { return }

        let body = try getEngineJSON(path: DockerAPIDecoding.allContainersPath, timeout: 20)
        let existing = try DockerAPIDecoding.containerIDs(containersJSON: body)
        for (containerID, identifier) in associated where !existing.contains(containerID) {
            releaseLease(identifier, reason: "container is absent from Docker's all-container snapshot")
        }
    }

    /// Re-registers the host endpoint for persisted Engine restart policies after
    /// each VM generation. Moby's patched `-P` path waits at the guest broker while
    /// this recovery query runs, so dockerd never falls back to a guest-owned port.
    /// This executes only on `workQueue`, alongside the Engine snapshot readers.
    private func recoverPublishAllRestartPolicySessions() {
        lock.lock()
        guard running else { lock.unlock(); return }
        lock.unlock()

        let allContainers: Data
        do {
            allContainers = try getEngineJSON(path: DockerAPIDecoding.allContainersPath, timeout: 10)
        } catch {
            log.info("publish-all restart-policy recovery will retry after Engine is ready: \(error)")
            return
        }
        guard let identifiers = try? DockerAPIDecoding.containerIDs(containersJSON: allContainers) else {
            log.warn("could not decode containers while recovering publish-all restart policies")
            return
        }

        var wanted: Set<String> = []
        for containerID in identifiers.prefix(DockerPortPublicationPreflight.maximumSynchronousFixedPortBindings) {
            guard let inspect = try? getEngineJSON(
                path: DockerAPIDecoding.containerInspectPath(containerID: containerID),
                timeout: 5),
                DockerPortPublicationPreflight.restartPolicyUsesPublishAllPorts(
                    in: inspect,
                    expectedContainerID: containerID)
            else { continue }
            wanted.insert(containerID)
        }

        lock.lock()
        let stale = publishAllRestartSessions.filter { !wanted.contains($0.key) }.map(\.value)
        publishAllRestartSessions = publishAllRestartSessions.filter { wanted.contains($0.key) }
        let missing = wanted.filter { publishAllRestartSessions[$0] == nil }
        lock.unlock()
        for session in stale { session.invalidate() }

        for containerID in missing {
            guard case .success(let fd) = vm.connectVsockBlocking(
                port: MorbVsockPorts.publishAllAllocator,
                timeout: 5)
            else {
                log.info("could not reconnect publish-all allocator for \(String(containerID.prefix(12))) yet")
                continue
            }
            do {
                let session = PublishAllPortAllocator.Session(
                    fd: fd,
                    containerID: containerID,
                    forwarder: self,
                    log: log,
                    remainsAvailableForRestartPolicy: true)
                try session.start()
                lock.lock()
                if running, publishAllRestartSessions[containerID] == nil {
                    publishAllRestartSessions[containerID] = session
                    lock.unlock()
                } else {
                    lock.unlock()
                    session.invalidate()
                }
            } catch {
                Darwin.close(fd)
                log.info("could not register publish-all restart-policy allocator for \(String(containerID.prefix(12))): \(error)")
            }
        }
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
        let tcpReconciliation = PortForwardPlan.reconcileTCPListeners(bindings)
        let udpReconciliation = PortForwardPlan.reconcileUDPListeners(bindings)
        let tcpDesired = tcpReconciliation.listeners
        let udpDesired = udpReconciliation.listeners

        let newTCPConflicts = updateTCPConflicts(tcpReconciliation.conflicts)
        let newUDPConflicts = updateUDPConflicts(udpReconciliation.conflicts)
        withdrawConflictingTCPLeaseListeners(
            at: Set(tcpReconciliation.conflicts.keys),
            reason: "Docker reported competing targets")
        withdrawConflictingUDPLeaseListeners(
            at: Set(udpReconciliation.conflicts.keys),
            reason: "Docker reported competing targets")
        for conflict in newTCPConflicts + newUDPConflicts { log.warn(conflict.diagnostic) }

        // A start by name or an opaque client cannot supply an exact lifecycle
        // response to DockerProxy. A snapshot is sufficient only when it proves the
        // full TCP+UDP set of one associated lease; never promote one transport from
        // a mixed publication while another remains unproved.
        reconcileHeldLeases(tcpDesired: tcpDesired, udpDesired: udpDesired, reason: reason)

        applyTCP(desired: tcpDesired, generation: generation, reason: reason)
        applyUDP(desired: udpDesired, generation: generation, reason: reason)
    }

    private func reconcileHeldLeases(
        tcpDesired: [Int: DockerPortBinding],
        udpDesired: [Int: DockerPortBinding],
        reason: String
    ) {
        var toPromote: [UUID] = []
        var toDeactivate: [UUID] = []
        lock.lock()
        for (identifier, record) in leases {
            guard let containerID = record.containerID else { continue }
            let expectedTCP = record.lease.tcp.filter {
                !record.withdrawnTCPHostPorts.contains($0.hostPort)
            }
            let expectedUDP = record.lease.udp.filter {
                !record.withdrawnUDPHostPorts.contains($0.hostPort)
            }
            let tcpMatches = expectedTCP.allSatisfy { publication in
                guard let actual = tcpDesired[publication.hostPort] else { return false }
                return actual.containerID == containerID
                    && actual.containerPort == publication.containerPort
                    && actual.networkProtocol == "tcp"
            }
            let udpMatches = expectedUDP.allSatisfy { publication in
                guard let actual = udpDesired[publication.hostPort] else { return false }
                return actual.containerID == containerID
                    && actual.containerPort == publication.containerPort
                    && actual.networkProtocol == "udp"
            }
            let hasRetainedEndpoint = !expectedTCP.isEmpty || !expectedUDP.isEmpty
            if hasRetainedEndpoint, tcpMatches, udpMatches {
                if !record.isForwarding { toPromote.append(identifier) }
            } else if record.isForwarding {
                toDeactivate.append(identifier)
            }
        }
        lock.unlock()

        for identifier in toDeactivate {
            deactivateLease(identifier, reason: reason)
        }
        for identifier in toPromote {
            _ = promoteLease(identifier)
        }
    }

    private func applyTCP(
        desired: [Int: DockerPortBinding],
        generation: Int,
        reason: String
    ) {

        lock.lock()
        for (port, desiredBinding) in desired {
            guard var forward = forwards[port], forwardTargetMatches(forward.binding, desiredBinding) else {
                continue
            }
            // Preserve a pre-bound listener while replacing only the presentation
            // metadata (most notably Docker's real container name).
            forward.binding = desiredBinding
            forwards[port] = forward
        }
        let current = forwards.mapValues(\.binding)
        lock.unlock()

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
        if !plan.close.isEmpty || !plan.open.isEmpty {
            // Close first: a port whose container was replaced appears in both lists,
            // and rebinding it while the old listener still holds it would fail
            // EADDRINUSE against ourselves.
            for port in plan.close {
                let replacementOwnsPort = desired[port].map { desiredBinding in
                    current[port].map { $0.containerID != desiredBinding.containerID } ?? false
                } ?? false
                closeForward(port: port, reason: reason, preserveLease: !replacementOwnsPort)
            }
            for binding in plan.open {
                openForward(binding, generation: generation)
            }
        }

    }

    /// UDP has the same event-driven discovery as TCP, but its independent port space
    /// needs a separate plan: Docker may legitimately publish TCP and UDP on the same
    /// numerical port at once. Nothing in this method guesses a pre-start dynamic or
    /// range allocation; `containers/json` has already supplied the concrete endpoint.
    private func applyUDP(
        desired: [Int: DockerPortBinding],
        generation: Int,
        reason: String
    ) {
        lock.lock()
        for (port, desiredBinding) in desired {
            guard let forward = udpForwards[port], forwardTargetMatches(forward.binding, desiredBinding) else {
                continue
            }
            forward.binding = desiredBinding
        }
        let current = udpForwards.mapValues(\.binding)
        for port in failedUDPBinds.keys {
            if let stillWanted = desired[port] {
                failedUDPBinds[port]?.binding = stillWanted
            } else {
                failedUDPBinds.removeValue(forKey: port)
            }
        }
        lock.unlock()

        let plan = PortForwardPlan.diff(current: current, desired: desired)
        guard !plan.close.isEmpty || !plan.open.isEmpty else { return }
        for port in plan.close {
            closeUDPForward(port: port, reason: reason)
        }
        for binding in plan.open {
            openUDPForward(binding, generation: generation)
        }
    }

    /// Replaces the non-retryable TCP conflict snapshot and returns diagnostics that
    /// have not already been emitted for this exact competing-target state.
    private func updateTCPConflicts(
        _ conflicts: [Int: PortForwardPlan.ListenerConflict]
    ) -> [PortForwardPlan.ListenerConflict] {
        lock.lock()
        let newConflicts = conflicts.keys.sorted().compactMap { port -> PortForwardPlan.ListenerConflict? in
            guard let conflict = conflicts[port] else { return nil }
            return conflictingTCPForwards[port] == conflict ? nil : conflict
        }
        conflictingTCPForwards = conflicts
        for port in conflicts.keys { failedBinds.removeValue(forKey: port) }
        lock.unlock()
        return newConflicts
    }

    /// UDP is independent from TCP but has the same one-target requirement within
    /// its own transport. These are state diagnostics, never timer retry entries.
    private func updateUDPConflicts(
        _ conflicts: [Int: PortForwardPlan.ListenerConflict]
    ) -> [PortForwardPlan.ListenerConflict] {
        lock.lock()
        let newConflicts = conflicts.keys.sorted().compactMap { port -> PortForwardPlan.ListenerConflict? in
            guard let conflict = conflicts[port] else { return nil }
            return conflictingUDPForwards[port] == conflict ? nil : conflict
        }
        conflictingUDPForwards = conflicts
        for port in conflicts.keys { failedUDPBinds.removeValue(forKey: port) }
        lock.unlock()
        return newConflicts
    }

    private func closeForward(port: Int, reason: String, preserveLease: Bool = true) {
        lock.lock()
        let forward = forwards.removeValue(forKey: port)
        // The port is no longer wanted, so a pending retry for it is no longer wanted
        // either — otherwise the timer keeps chasing a container that is long gone.
        failedBinds.removeValue(forKey: port)
        lock.unlock()
        guard let forward else { return }
        if let identifier = forward.leaseID, !preserveLease {
            releaseLease(identifier, reason: "the port was reassigned after \(reason)")
        } else if let identifier = forward.leaseID {
            deactivateLease(identifier, reason: reason)
        } else {
            forward.listener.stop()
            log.info("port forward removed: \(forward.binding.description) — after \(reason)")
        }
    }

    private func closeUDPForward(port: Int, reason: String) {
        lock.lock()
        let forward = udpForwards[port]
        failedUDPBinds.removeValue(forKey: port)
        if forward?.leaseID == nil {
            udpForwards.removeValue(forKey: port)
        }
        lock.unlock()
        guard let forward else { return }
        if let identifier = forward.leaseID {
            deactivateLease(identifier, reason: reason)
            return
        }
        forward.listener.stop()
        for flow in forward.flows.values { flow.close() }
        log.info("UDP port forward removed: \(forward.binding.description) — after \(reason)")
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

        let loopbackAddress = TCPListener.LoopbackAddress
            .forDockerHostAddress(binding.hostIP)
        let listener = TCPListener(
            port: port,
            queue: acceptQueue,
            loopbackAddress: loopbackAddress)
        listener.setConnectionHandler { [weak self] fd in
            self?.handleAccepted(clientFD: fd, binding: binding, generation: generation)
        }

        do {
            try listener.start()
        } catch TCPListenerError.addressInUse {
            recordFailedBind(
                binding,
                reason: "another process holds \(loopbackAddress.rawValue):\(port); will retry")
            return
        } catch {
            recordFailedBind(binding, reason: "\(error); will retry")
            return
        }

        lock.lock()
        let accepted = running && self.generation == generation
        if accepted {
            forwards[port] = Forward(binding: binding, listener: listener, leaseID: nil)
            failedBinds.removeValue(forKey: port)
        }
        lock.unlock()

        guard accepted else {
            listener.stop()  // the forwarder was torn down while we were binding
            return
        }
        log.info("port forward added: \(binding.description) on \(loopbackAddress.rawValue):\(port)")
    }

    /// Binds one event-confirmed UDP publication. The listener is a real datagram
    /// endpoint, not a TCP approximation: every host client gets a framed vsock flow
    /// to a connected guest UDP socket and replies return to that same client.
    private func openUDPForward(_ binding: DockerPortBinding, generation: Int) {
        let port = binding.hostPort
        lock.lock()
        let deferred = failedUDPBinds[port].map { $0.nextAttemptAt > Date() } ?? false
        lock.unlock()
        if deferred { return }

        let listener = UDPListener(port: port, queue: acceptQueue)
        listener.setDatagramHandler { [weak self, weak listener] datagram, client in
            guard let self, let listener else { return }
            self.handleUDPDatagram(
                datagram, from: client, binding: binding, listener: listener, generation: generation)
        }
        do {
            try listener.start()
        } catch UDPListener.Error.addressInUse {
            recordFailedUDPBind(
                binding,
                reason: "another process holds 127.0.0.1:\(port)/udp; will retry")
            return
        } catch {
            recordFailedUDPBind(binding, reason: "\(error); will retry")
            return
        }

        lock.lock()
        let accepted = running && self.generation == generation
        if accepted {
            udpForwards[port] = UDPForward(binding: binding, listener: listener)
            failedUDPBinds.removeValue(forKey: port)
        }
        lock.unlock()
        guard accepted else {
            listener.stop()
            return
        }
        log.info("UDP port forward added: \(binding.description) on 127.0.0.1:\(port)")
    }

    /// The actual host listener is keyed by port, container identity, and its guest
    /// target. Docker's `Ports` response may normalize `0.0.0.0` to an empty address
    /// or finally reveal the human-readable name; neither difference requires a
    /// close/rebind of a lease that already owns the same endpoint.
    private func forwardTargetMatches(_ lhs: DockerPortBinding, _ rhs: DockerPortBinding) -> Bool {
        lhs.hostPort == rhs.hostPort
            && lhs.containerPort == rhs.containerPort
            && lhs.networkProtocol == rhs.networkProtocol
            && lhs.containerID == rhs.containerID
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

    private func recordFailedUDPBind(_ binding: DockerPortBinding, reason: String) {
        let port = binding.hostPort
        lock.lock()
        let attempts = (failedUDPBinds[port]?.attempts ?? 0) + 1
        let delay = min(
            PortForwarder.minimumBindBackoff * pow(2, Double(attempts - 1)),
            PortForwarder.maximumBindBackoff)
        let previousDelay = failedUDPBinds[port].map { _ in
            min(
                PortForwarder.minimumBindBackoff * pow(2, Double(attempts - 2)),
                PortForwarder.maximumBindBackoff)
        }
        failedUDPBinds[port] = FailedBind(
            binding: binding,
            reason: reason,
            attempts: attempts,
            nextAttemptAt: Date().addingTimeInterval(delay))
        lock.unlock()
        guard previousDelay == nil || previousDelay! < delay else { return }
        log.warn(
            "cannot publish \(binding.description): \(reason) in \(Int(delay))s "
                + "(container \(binding.containerName) is not reachable on 127.0.0.1:\(port)/udp until then)")
    }

    // MARK: - Per-client UDP flows

    private func handleUDPDatagram(
        _ datagram: Data,
        from client: UDPListener.Client,
        binding: DockerPortBinding,
        listener: UDPListener,
        generation: Int
    ) {
        let flow: UDPFlow
        let needsDial: Bool
        lock.lock()
        guard running, self.generation == generation,
              let forward = udpForwards[binding.hostPort],
              forward.listener === listener,
              forwardTargetMatches(forward.binding, binding)
        else {
            lock.unlock()
            return
        }
        if let existing = forward.flows[client] {
            flow = existing
            needsDial = false
        } else {
            let activeFlowCount = udpForwards.values.reduce(0) { $0 + $1.flows.count }
            guard activeFlowCount < PortForwarder.maximumUDPFlows else {
                lock.unlock()
                log.warn(
                    "dropping UDP datagram for \(binding.description): \(PortForwarder.maximumUDPFlows) "
                        + "client flows are already active")
                return
            }
            let created = UDPFlow(client: client, binding: binding, generation: generation)
            forward.flows[client] = created
            flow = created
            needsDial = true
        }
        lock.unlock()

        let onWriteFailure = { [weak self, weak flow] in
            guard let self, let flow else { return }
            self.removeUDPFlow(flow, hostPort: binding.hostPort, client: client, reason: "a frame write failed")
        }
        if flow.enqueue(datagram, onWriteFailure: onWriteFailure) {
            log.warn(
                "dropping UDP datagrams for \(binding.description) from \(client.description): "
                    + "the per-client bridge queue is full")
        }
        if needsDial {
            busyHandler?()
            establishUDPFlow(flow, listener: listener)
        }
    }

    /// Opens the host-to-guest transport after the first real UDP packet. The first
    /// packet stays in the flow's bounded opening queue; subsequent packets from that
    /// client retain their arrival order until the handshake completes.
    private func establishUDPFlow(_ flow: UDPFlow, listener: UDPListener) {
        vm.ensureRunning(timeout: PortForwarder.dialBootTimeout) { [weak self, weak flow, weak listener] result in
            guard let self, let flow, let listener else { return }
            guard case .success = result else {
                self.log.warn("dropping UDP flow to \(flow.binding.description): the VM is unavailable")
                self.removeUDPFlow(flow, hostPort: flow.binding.hostPort, client: flow.client, reason: "the VM was unavailable")
                return
            }
            self.udpDialQueue.async { [weak self, weak flow, weak listener] in
                guard let self, let flow, let listener else { return }
                self.udpDialPermits.wait()
                defer { self.udpDialPermits.signal() }
                self.dialUDPFlow(flow, listener: listener)
            }
        }
    }

    /// Blocking datagram-dial handshake, bounded by the flow and setup caps above.
    private func dialUDPFlow(_ flow: UDPFlow, listener: UDPListener) {
        guard isCurrent(flow.generation) else {
            removeUDPFlow(flow, hostPort: flow.binding.hostPort, client: flow.client, reason: "the forwarder stopped")
            return
        }
        let descriptor: Int32
        switch vm.connectVsockBlocking(port: MorbVsockPorts.datagramDial, timeout: 5) {
        case .failure(let error):
            log.warn("could not open a datagram-dial for \(flow.binding.description): \(error)")
            removeUDPFlow(flow, hostPort: flow.binding.hostPort, client: flow.client, reason: "the guest datagram channel was unavailable")
            return
        case .success(let fd):
            descriptor = fd
        }
        do {
            try DatagramDial.perform(fd: descriptor, hostPort: flow.binding.hostPort)
        } catch {
            Darwin.close(descriptor)
            log.warn("datagram-dial to \(flow.binding.description) refused: \(error)")
            removeUDPFlow(flow, hostPort: flow.binding.hostPort, client: flow.client, reason: "the guest rejected the UDP dial")
            return
        }

        let onWriteFailure = { [weak self, weak flow] in
            guard let self, let flow else { return }
            self.removeUDPFlow(flow, hostPort: flow.binding.hostPort, client: flow.client, reason: "a frame write failed")
        }
        guard flow.activate(descriptor, onWriteFailure: onWriteFailure) else { return }
        relayQueue.async { [weak self, weak flow, weak listener] in
            guard let self, let flow, let listener else { return }
            self.readUDPReplies(flow, listener: listener)
        }
    }

    /// Sends guest UDP replies back through the same Mac socket and exact source tuple
    /// that produced the flow. This is why a generic one-shot "UDP over TCP" proxy is
    /// insufficient: it could not carry unsolicited or multi-datagram replies.
    private func readUDPReplies(_ flow: UDPFlow, listener: UDPListener) {
        while isCurrent(flow.generation) {
            let descriptor: Int32
            // The flow intentionally keeps its descriptor private; `readFrame` needs
            // it here only after activation, so ask through this small accessor.
            guard let fd = flow.openDescriptor else { return }
            descriptor = fd
            do {
                guard let reply = try DatagramDial.readFrame(fd: descriptor) else {
                    removeUDPFlow(flow, hostPort: flow.binding.hostPort, client: flow.client, reason: "the guest closed the UDP flow")
                    return
                }
                flow.noteReply()
                guard listener.send(reply, to: flow.client) else {
                    removeUDPFlow(flow, hostPort: flow.binding.hostPort, client: flow.client, reason: "the local UDP listener closed")
                    return
                }
            } catch {
                log.warn("datagram-dial reply for \(flow.binding.description) failed: \(error)")
                removeUDPFlow(flow, hostPort: flow.binding.hostPort, client: flow.client, reason: "the datagram reply stream failed")
                return
            }
        }
    }

    private func removeUDPFlow(
        _ flow: UDPFlow,
        hostPort: Int,
        client: UDPListener.Client,
        reason: String
    ) {
        lock.lock()
        if let forward = udpForwards[hostPort], forward.flows[client] === flow {
            forward.flows.removeValue(forKey: client)
        }
        lock.unlock()
        flow.close()
        // Flow closure is normal UDP lifetime (including the idle timeout), so it is
        // intentionally not a line in the user-facing daemon log. Failures were
        // reported at their source above; retaining every remote ephemeral port would
        // make the log unusable during normal DNS or game traffic.
        _ = reason
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
