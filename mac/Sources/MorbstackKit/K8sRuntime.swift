// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import CryptoKit
import Darwin
import Dispatch
import Foundation

/// The moving parts of Kubernetes support: getting the payload into the guest,
/// making the API server reachable from the Mac, and joining the two to the
/// control-channel client in ``K8s``.
///
/// ``K8s`` is deliberately all pure functions and wire types, so its kubeconfig
/// handling can be tested exhaustively against fixtures. Everything with a socket or
/// a file descriptor in it lives here.

// MARK: - Payload staging

/// One file the daemon may stream into the guest.
public struct K8sPayloadFile: Equatable, Sendable {
    /// Must match a name in the guest's allow-list (`k8s::PAYLOAD_NAMES`).
    public let name: String
    public let url: URL
    public let size: Int
    public let sha256: String
}

/// Finding and hashing the Kubernetes payload on the Mac.
public enum K8sPayloadStaging {

    /// Describe both payload files, hashing each one.
    ///
    /// The digest is computed here, from the bytes about to be sent, rather than read
    /// from the `PROVENANCE.txt` the fetch script wrote. Provenance describes what
    /// *was* downloaded; the guest is being asked to prove what it *received*, and
    /// those are only the same claim if nothing has touched the file since. Hashing
    /// 122 MB costs about a second and happens once per enable.
    ///
    /// The pinned digests in ``K8s/payloadFiles`` are still checked: a local file
    /// that does not match the pin is refused outright rather than shipped into the
    /// guest, because at that point Morbstack has no idea what it is about to run.
    public static func describe(in directory: URL = MorbPaths.k8sPayloadDirectory) throws
        -> [K8sPayloadFile]
    {
        try K8s.payloadFiles.map { pinned in
            let url = directory.appendingPathComponent(pinned.name)
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw MorbError.notFound(
                    "\(url.path) is missing.\n"
                        + "       Run `scripts/fetch-guest-assets.sh --k8s-only` to download the "
                        + "pinned\n       k3s and cri-dockerd binaries (about 122 MB).")
            }
            let (digest, size) = try hash(url)
            guard digest == pinned.sha256 else {
                throw MorbError.io(
                    "\(url.path) does not match the digest Morbstack pins for \(pinned.name)\n"
                        + "       (got \(digest),\n        expected \(pinned.sha256)).\n"
                        + "       Refusing to install it. Delete the file and re-run "
                        + "`scripts/fetch-guest-assets.sh --k8s-only`.")
            }
            return K8sPayloadFile(name: pinned.name, url: url, size: size, sha256: digest)
        }
    }

    /// Whether both payload files are present on this Mac at all.
    ///
    /// Cheap — an existence check, not a hash — because this answers "should the CLI
    /// suggest downloading the payload?", which must not cost a second.
    public static func isStagedOnHost(in directory: URL = MorbPaths.k8sPayloadDirectory) -> Bool {
        K8s.payloadFiles.allSatisfy {
            FileManager.default.isReadableFile(atPath: directory.appendingPathComponent($0.name).path)
        }
    }

    /// Streaming sha256 of a file, plus its length.
    ///
    /// Streaming because the larger of these is a 74 MB executable, and a daemon that
    /// is also holding a VM's worth of memory should not read it into a `Data` to
    /// describe it.
    static func hash(_ url: URL) throws -> (sha256: String, size: Int) {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw MorbError.io("could not open \(url.path)")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        var size = 0
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            size += chunk.count
            hasher.update(data: chunk)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }
}

// MARK: - API server forwarding

/// Mirrors the guest's Kubernetes API server onto the Mac's loopback.
///
/// ``PortForwarder`` cannot do this job: it publishes what *Docker* publishes, and
/// the API server is a listener inside the k3s process, not a container port. So this
/// is one fixed forward assembled from the same three pieces the port forwarder uses
/// — a ``TCPListener``, the ``StreamDial`` handshake on vsock 2376, and an
/// ``FDRelay``.
///
/// Nothing equivalent is needed for LoadBalancer or NodePort services, and that is
/// the quiet payoff of running the cluster on cri-dockerd instead of containerd:
/// k3s's servicelb schedules klipper-lb pods with host ports, cri-dockerd creates
/// their sandboxes as ordinary Docker containers with published ports, and the
/// existing ``PortForwarder`` mirrors them onto `127.0.0.1` off the Docker event
/// stream — with no Kubernetes-aware code anywhere in that path.
public final class K8sAPIServerForward {

    /// Host ports tried in order.
    ///
    /// 6443 first because it is what every kubeconfig, tutorial and muscle memory
    /// expects. The rest exist for the Mac that already has something on 6443 —
    /// another k3s, a Docker Desktop cluster, a colima VM. Whichever port binds is
    /// the one written into the generated kubeconfig, so a fallback is invisible to
    /// the user rather than a broken cluster.
    public static let candidatePorts = Array(6443...6452)

    /// How long the guest gets to answer a stream-dial for the API server.
    private static let dialTimeout: TimeInterval = 8

    private let vm: VMManager
    private let log: MorbLog
    private let guestPort: Int
    private let acceptQueue = DispatchQueue(label: "dev.morbstack.k8s.accept", attributes: .concurrent)
    private let dialQueue = DispatchQueue(
        label: "dev.morbstack.k8s.dial", qos: .userInitiated, attributes: .concurrent)
    private let relayQueue = DispatchQueue(label: "dev.morbstack.k8s.relay", attributes: .concurrent)

    private let lock = NSLock()
    private var listener: TCPListener?
    private var relays: [UInt64: FDRelay] = [:]
    private var relaySequence: UInt64 = 0
    /// Bumped by every start/stop; a dial carrying a stale value closes rather than
    /// splicing a client into a VM that has since gone away.
    private var generation = 0

    public init(vm: VMManager, log: MorbLog, guestPort: Int = K8s.guestAPIServerPort) {
        self.vm = vm
        self.log = log
        self.guestPort = guestPort
    }

    /// The Mac-side port currently serving the API server, or `nil` when stopped.
    public var boundPort: Int? {
        lock.lock()
        defer { lock.unlock() }
        return listener?.port
    }

    /// Bind the first free candidate port. Idempotent: a second call returns the port
    /// already bound.
    @discardableResult
    public func start() throws -> Int {
        lock.lock()
        if let existing = listener?.port {
            lock.unlock()
            return existing
        }
        generation += 1
        let generation = self.generation
        lock.unlock()

        var lastError: Error?
        for port in Self.candidatePorts {
            let candidate = TCPListener(port: port, queue: acceptQueue)
            candidate.onConnection = { [weak self] fd in
                self?.handle(clientFD: fd, generation: generation)
            }
            do {
                try candidate.start()
            } catch TCPListenerError.addressInUse {
                lastError = TCPListenerError.addressInUse(port: port)
                continue
            } catch {
                lastError = error
                continue
            }

            lock.lock()
            let accepted = self.generation == generation
            if accepted { listener = candidate }
            lock.unlock()
            guard accepted else {
                candidate.stop()  // stopped while we were binding
                throw MorbError.io("the Kubernetes API forward was torn down while starting")
            }
            if port != Self.candidatePorts[0] {
                log.info(
                    "127.0.0.1:\(Self.candidatePorts[0]) was taken, so the Kubernetes API server "
                        + "is on 127.0.0.1:\(port) instead (the generated kubeconfig says so too)")
            } else {
                log.info("kubernetes API server published on 127.0.0.1:\(port)")
            }
            return port
        }

        throw MorbError.io(
            "could not bind any port between \(Self.candidatePorts.first!) and "
                + "\(Self.candidatePorts.last!) on 127.0.0.1 for the Kubernetes API server "
                + "(\(lastError.map { "\($0)" } ?? "unknown reason")).")
    }

    /// Close the listener and cancel every live relay. Idempotent.
    public func stop() {
        lock.lock()
        generation += 1
        let closing = listener
        listener = nil
        let live = relays
        relays = [:]
        lock.unlock()

        closing?.stop()
        for relay in live.values { relay.cancel() }
        if closing != nil { log.info("kubernetes API server forward stopped") }
    }

    private func handle(clientFD: Int32, generation: Int) {
        // Off the accept queue: a vsock connect plus the 2376 preamble can take
        // seconds when the guest is busy, and blocking the accept loop for that long
        // would stall every other `kubectl` behind it.
        dialQueue.async { [weak self] in
            guard let self else {
                Darwin.close(clientFD)
                return
            }
            self.splice(clientFD: clientFD, generation: generation)
        }
    }

    private func splice(clientFD: Int32, generation: Int) {
        guard isCurrent(generation) else {
            Darwin.close(clientFD)
            return
        }

        let dialFD: Int32
        switch vm.connectVsockBlocking(port: MorbVsockPorts.streamDial, timeout: Self.dialTimeout) {
        case .success(let fd):
            dialFD = fd
        case .failure(let error):
            log.warn("could not open a stream-dial for the Kubernetes API server: \(error)")
            Darwin.close(clientFD)
            return
        }

        do {
            try StreamDial.perform(fd: dialFD, guestPort: guestPort)
        } catch {
            // Overwhelmingly the ordinary case rather than a fault: `kubectl` is
            // being run while the control plane is still starting, so nothing is
            // listening on :6443 inside the guest yet. `info`, not `warn` — kubectl
            // retries, and a warning per attempt would bury the daemon log.
            log.info("the Kubernetes API server is not accepting connections yet: \(error)")
            Darwin.close(dialFD)
            Darwin.close(clientFD)
            return
        }

        lock.lock()
        guard self.generation == generation, listener != nil else {
            lock.unlock()
            Darwin.close(dialFD)
            Darwin.close(clientFD)
            return
        }
        relaySequence += 1
        let identifier = relaySequence
        let relay = FDRelay(fdA: clientFD, fdB: dialFD, queue: relayQueue) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.relays.removeValue(forKey: identifier)
            self.lock.unlock()
        }
        relays[identifier] = relay
        lock.unlock()
        relay.start()
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.generation == generation && listener != nil
    }
}

/// The only states in which it is honest to expose a host Kubernetes endpoint.
///
/// A listener is not the API server. In particular, a just-booted guest can answer
/// its control channel while k3s is still bringing the API server up. The guest's
/// `ready` phase is explicitly the contract that `kubectl` can work, so this small
/// policy keeps lifecycle code from mistaking a bound loopback socket for a usable
/// cluster. It is deliberately pure so stopped/error transitions can be covered
/// without booting a VM or binding a host port.
enum K8sAPIForwardPublication {
    enum Action: Equatable {
        /// Close any existing listener and do not schedule another attempt.
        case stop
        /// Close any existing listener and ask the guest again later.
        case awaitReadiness
        /// The guest has reported a usable cluster; publish the loopback forward.
        case publish
    }

    static func action(vmState: VMState, status: K8s.Status?) -> Action {
        guard vmState == .running else { return .stop }
        guard let status else { return .awaitReadiness }
        guard status.enabled else { return .stop }
        switch status.phase {
        case .ready:
            return .publish
        case .starting:
            return .awaitReadiness
        case .notInstalled, .stopped:
            return .stop
        }
    }
}

// MARK: - The manager

/// Everything `morb k8s ...` needs, in one object the daemon owns.
public final class K8sManager {

    /// How long the guest gets to answer a `k8s` control message.
    ///
    /// Longer than `ping`'s five seconds because `enable` writes and fsyncs a flag
    /// file on a disk that may be in the middle of an image pull, and because
    /// answering it at all requires the guest's control server to get a thread.
    public static let controlTimeout: TimeInterval = 20

    /// How long the guest gets to verify and install one payload file after the last
    /// byte is on the wire. This is a sha256 over 74 MB plus an `fsync`, on a guest
    /// that may be busy.
    public static let verifyTimeout: TimeInterval = 120

    private let vm: VMManager
    private let log: MorbLog
    private let payloadDirectory: URL

    /// The loopback forward for the API server. Public so ``Daemon`` can start and
    /// stop it alongside the port forwarder as the VM comes and goes.
    public let forward: K8sAPIServerForward
    /// The daemon-owned selected-Pod port-forward session boundary. IPC and `morb`
    /// use the explicit methods below; a future selected-row action must use those
    /// same daemon methods rather than shelling out from the UI.
    public let podPortForward: K8sPodPortForwardCoordinator

    public init(vm: VMManager, log: MorbLog, payloadDirectory: URL = MorbPaths.k8sPayloadDirectory) {
        self.vm = vm
        self.log = log
        self.payloadDirectory = payloadDirectory
        self.forward = K8sAPIServerForward(vm: vm, log: log)
        self.podPortForward = K8sPodPortForwardCoordinator(log: log)
    }

    // MARK: Control channel

    /// Open a short-lived control connection, run `body`, and close it.
    ///
    /// A connection per exchange rather than one held open for the daemon's life:
    /// ``GuestControl`` is single-in-flight by construction, so a long-lived
    /// Kubernetes channel would either serialise against the daemon's own health
    /// probes or need a second connection anyway. Connections are cheap; contention
    /// on the one channel that reports whether the guest is alive is not.
    private func withControl<T>(_ body: (GuestControl) throws -> T) throws -> T {
        let fd: Int32
        switch vm.connectVsockBlocking(port: MorbVsockPorts.guestControl, timeout: 8) {
        case .success(let value):
            fd = value
        case .failure(let error):
            throw MorbError.io("could not reach the guest control channel: \(error)")
        }
        let control = GuestControl(fd: fd)
        defer { control.closeOwnedDescriptor() }
        return try body(control)
    }

    /// Ask the guest what state the cluster is in.
    public func status() throws -> K8s.Status {
        try withControl { try K8s.requestStatus($0, action: "status", timeout: Self.controlTimeout) }
    }

    /// Turn the cluster on, streaming the payload in first if the guest does not have
    /// it yet.
    ///
    /// Install-then-enable is one command on purpose. "Enable Kubernetes" is a single
    /// intention; a two-step flow whose first step is "upload 122 MB" is an
    /// implementation detail escaping into the interface. The install is idempotent
    /// and digest-checked on both sides, so the second `enable` skips it entirely.
    public func enable() throws -> K8s.Status {
        let before = try status()
        if !before.installed {
            if !before.persistent {
                // Worth saying out loud: everything below will work, and none of it
                // will survive `morb stop`.
                log.warn(
                    "the guest's data root is RAM-backed, so the Kubernetes payload and the "
                        + "enabled flag will not survive a restart")
            }
            try installPayload()
        }
        let after = try withControl {
            try K8s.requestStatus($0, action: "enable", timeout: Self.controlTimeout)
        }
        // Do not bind a host port merely because the persisted toggle is on. The
        // daemon reconciles the forward after the guest reports `.ready`, whose
        // contract is that `kubectl` can work. Publishing during `.starting` would
        // advertise a local endpoint that can only accept and then close clients.
        return after
    }

    /// Turn the cluster off, keeping the installed binaries and the cluster's own
    /// state so that re-enabling is fast and nothing the user created is lost.
    public func disable() throws -> K8s.Status {
        let status = try withControl {
            try K8s.requestStatus($0, action: "disable", timeout: Self.controlTimeout)
        }
        podPortForward.cancelAll(reason: "Kubernetes was disabled")
        forward.stop()
        return status
    }

    /// Explicitly starts one daemon-owned selected-Pod loopback forward. This does
    /// not generate a kubeconfig, start Kubernetes, or republish the API server: all
    /// of those are already-required facts and are revalidated by the coordinator.
    @discardableResult
    public func startPodPortForward(
        _ request: K8sPodPortForwardRequest
    ) throws -> K8sPodPortForwardLease {
        try podPortForward.start(request) { [weak self] in
            guard let self else {
                throw MorbError.io("Morbstack stopped while preparing the selected Pod port forward")
            }
            let status = try self.status()
            guard status.phase == .ready else {
                throw MorbError.io(
                    "Kubernetes is \(status.phase.summary), so the selected Pod cannot be forwarded yet. Wait for Kubernetes to report ready.")
            }
            guard let port = self.forward.boundPort else {
                throw MorbError.io(
                    "Kubernetes is ready but Morbstack’s local API forward is not current; refresh status before forwarding the selected Pod.")
            }
            guard FileManager.default.fileExists(atPath: K8s.defaultKubeconfigURL.path) else {
                throw MorbError.io(
                    "Morbstack’s private kubeconfig is missing; generate it before forwarding the selected Pod.")
            }
            return try K8sPodPortForwardPrerequisites(
                kubeconfigURL: K8s.defaultKubeconfigURL,
                apiForwardPort: port)
        }
    }

    /// Explicit cancellation for the selected route owner. A stale lease cannot
    /// cancel a later selection's forward.
    public func cancelPodPortForward(_ lease: K8sPodPortForwardLease) {
        podPortForward.cancel(lease)
    }

    /// Cancels a lease only when the caller presents the exact opaque ID returned at
    /// start. A stale ID is a truthful no-op, so an old CLI invocation can never
    /// terminate a newly selected Pod's replacement forward.
    @discardableResult
    public func cancelPodPortForward(id: UUID) -> Bool {
        podPortForward.cancel(id: id)
    }

    /// The one non-secret lease fact the daemon may expose to an IPC/CLI status
    /// query. It neither probes Kubernetes nor creates a listener.
    public var activePodPortForwardLease: K8sPodPortForwardLease? {
        podPortForward.activeLease
    }

    /// VM, API-forward, route, and selection owners use this to end a current lease.
    /// There is deliberately no restore path.
    public func cancelPodPortForwards(reason: String) {
        podPortForward.cancelAll(reason: reason)
    }

    // MARK: Read-only selected-resource inspection

    /// Reads one bounded Pod or Node description from the local, mTLS-authenticated
    /// Kubernetes API forward. This never starts a forward, generates a kubeconfig,
    /// changes the guest, or makes a workload API request other than the fixed GET.
    ///
    /// The forward and app-owned kubeconfig must already exist because both are user
    /// visible prerequisites. Creating either while answering a describe request would
    /// turn an observation into an unexpected host/guest mutation.
    public func describe(_ reference: K8s.ResourceReference) throws -> K8s.ResourceDescription {
        let status = try status()
        guard status.phase == .ready else {
            throw MorbError.io(
                "Kubernetes is \(status.phase.summary), so the selected resource cannot be described yet. "
                    + "Wait for `morb k8s status` to report ready.")
        }
        guard forward.boundPort != nil else {
            throw MorbError.io(
                "Kubernetes is ready but its local API forward is still reconciling. Run `morb k8s diagnose` and refresh status.")
        }
        return try K8sResourceReader().describe(reference)
    }

    // MARK: Kubeconfig

    /// Fetch the guest's kubeconfig, rewrite it for the Mac, and write it to
    /// `~/.morbstack/kubeconfig` with mode 0600.
    @discardableResult
    public func writeHostKubeconfig() throws -> (path: URL, hostPort: Int) {
        let status = try status()
        guard status.enabled else {
            throw MorbError.io("Kubernetes is disabled; enable it before generating a kubeconfig.")
        }
        guard status.phase == .ready else {
            throw MorbError.io(
                "Kubernetes is \(status.phase.summary), so its API endpoint is not ready yet. "
                    + "Wait for `morb k8s status` to report ready, then try again.")
        }
        let hostPort = try forward.boundPort ?? forward.start()
        let reply = try withControl { try K8s.requestKubeconfig($0, timeout: Self.controlTimeout) }
        let rewritten = K8s.rewriteKubeconfig(reply.kubeconfig, hostPort: hostPort)
        let path = try K8s.writeStandaloneKubeconfig(rewritten)
        return (path, hostPort)
    }

    /// Merge Morbstack's context into `~/.kube/config`, after taking a backup.
    ///
    /// Reached only from an explicit `morb k8s kubeconfig --merge`, which confirms
    /// with the user first. `switchContext` defaults to false: enabling a local
    /// cluster must never silently retarget a `kubectl` that was pointing somewhere
    /// that matters.
    public func mergeIntoUserKubeconfig(switchContext: Bool = false) throws -> K8s.MergeOutcome {
        let (path, _) = try writeHostKubeconfig()
        let ours = try String(contentsOf: path, encoding: .utf8)
        let target = MorbPaths.userKubeconfig
        let existing = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
        let (merged, replaced) = K8s.mergeKubeconfig(
            existing: existing, morbstackConfig: ours, switchContext: switchContext)
        return try K8s.writeMergedKubeconfig(
            merged, to: target, replacedExisting: replaced, switchedContext: switchContext)
    }

    // MARK: Payload install

    /// Stream every payload file the guest does not already have into it.
    public func installPayload() throws {
        let files = try K8sPayloadStaging.describe(in: payloadDirectory)
        for file in files {
            if try guestAlreadyHas(file) {
                log.info("the guest already has a verified \(file.name); skipping the transfer")
                continue
            }
            let started = Date()
            try upload(file)
            let seconds = max(Date().timeIntervalSince(started), 0.001)
            let megabytes = Double(file.size) / 1_048_576
            log.info(
                String(
                    format: "installed %@ into the guest: %.0f MB in %.1fs (%.0f MB/s)",
                    file.name, megabytes, seconds, megabytes / seconds))
        }
    }

    /// Ask the guest whether it already holds a byte-identical copy.
    ///
    /// The guest re-hashes its own file to answer, which is the point: "I have a file
    /// with that name" would happily skip re-installing a binary that a crash left
    /// half-written.
    private func guestAlreadyHas(_ file: K8sPayloadFile) throws -> Bool {
        try withInstallChannel { fd in
            try Self.writeLine(fd, "HAVE \(file.name) \(file.sha256)")
            let reply = try StreamDial.readReplyLine(
                fd: fd, deadline: Date().addingTimeInterval(Self.verifyTimeout))
            switch reply.trimmingCharacters(in: .whitespaces) {
            case "YES": return true
            case "NO": return false
            case let other where other.hasPrefix("ERR"):
                throw MorbError.io(
                    "the guest refused a payload query: "
                        + other.dropFirst(3).trimmingCharacters(in: .whitespaces))
            case let other:
                throw MorbError.protocolViolation(
                    "unexpected reply to `HAVE \(file.name)`: `\(other)`")
            }
        }
    }

    private func upload(_ file: K8sPayloadFile) throws {
        try withInstallChannel { fd in
            try Self.writeLine(fd, "PUT \(file.name) \(file.size) \(file.sha256)")
            let go = try StreamDial.readReplyLine(fd: fd, deadline: Date().addingTimeInterval(30))
            try Self.expectOK(go, context: "PUT \(file.name)")

            guard let handle = FileHandle(forReadingAtPath: file.url.path) else {
                throw MorbError.io("could not open \(file.url.path)")
            }
            defer { try? handle.close() }

            var sent = 0
            while sent < file.size {
                let chunk = handle.readData(ofLength: 1 << 19)
                if chunk.isEmpty { break }
                guard POSIXSocketSupport.writeAll(fd, chunk) else {
                    throw MorbError.io(
                        "the guest stopped reading \(file.name) after \(sent) of \(file.size) "
                            + "bytes: \(String(cString: strerror(errno)))")
                }
                sent += chunk.count
            }
            guard sent == file.size else {
                // The length was announced in the preamble, so a file that shrank
                // underneath us would leave the guest waiting for bytes that will
                // never come. Fail here, where the reason is still knowable.
                throw MorbError.io(
                    "\(file.url.path) yielded \(sent) bytes but was described as \(file.size); "
                        + "it changed while it was being uploaded")
            }

            // The guest hashes what it received and only then moves it into place, so
            // this second OK — not the last byte written — is what makes an install
            // real.
            let done = try StreamDial.readReplyLine(
                fd: fd, deadline: Date().addingTimeInterval(Self.verifyTimeout))
            try Self.expectOK(done, context: "installing \(file.name)")
        }
    }

    /// One connection to the guest's install server, closed on the way out.
    private func withInstallChannel<T>(_ body: (Int32) throws -> T) throws -> T {
        let fd: Int32
        switch vm.connectVsockBlocking(port: K8s.installPort, timeout: 10) {
        case .success(let value):
            fd = value
        case .failure(let error):
            throw MorbError.io(
                "could not reach the guest's Kubernetes install channel on vsock "
                    + "\(K8s.installPort): \(error).\n"
                    + "       A guest image built before Kubernetes support does not have one; "
                    + "run `make guest-image && morb stop && morb start`.")
        }
        POSIXSocketSupport.suppressSIGPIPE(fd)
        defer { Darwin.close(fd) }
        return try body(fd)
    }

    static func writeLine(_ fd: Int32, _ line: String) throws {
        guard POSIXSocketSupport.writeAll(fd, Data((line + "\n").utf8)) else {
            throw MorbError.io(
                "could not write to the Kubernetes install channel: "
                    + String(cString: strerror(errno)))
        }
    }

    /// Interpret one `OK` / `ERR <reason>` reply from the install channel.
    ///
    /// Shares its wire vocabulary with ``StreamDial`` on purpose: the guest already
    /// speaks that dialect on 2376, the host already has a line reader for it, and a
    /// second bespoke framing would be two things to get right instead of one.
    static func expectOK(_ reply: String, context: String) throws {
        let trimmed = reply.trimmingCharacters(in: .whitespaces)
        if trimmed == "OK" { return }
        if trimmed.hasPrefix("ERR") {
            throw MorbError.io(
                "\(context) failed in the guest: "
                    + trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces))
        }
        throw MorbError.protocolViolation("unexpected reply while \(context): `\(trimmed)`")
    }
}
