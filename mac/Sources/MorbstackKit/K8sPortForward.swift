// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import CryptoKit
import Darwin
import Dispatch
import Foundation

/// A narrow request to make one selected Pod port available on this Mac.
///
/// This is intentionally a Pod identity, rather than a general `kubectl` argument
/// bag. The caller must carry the UID it obtained from the selected row. A name is
/// reusable after a Pod is deleted; the coordinator refuses to attach a forward to a
/// replacement with a different UID.
public struct K8sPodPortForwardRequest: Equatable, Sendable {
    /// The selected Pod's namespace.
    public let namespace: String
    /// The selected Pod's DNS-style name.
    public let pod: String
    /// The selected Pod's immutable Kubernetes UID.
    public let uid: String
    /// The selected regular container, when the Pod has more than one. Kubernetes
    /// port-forward targets the Pod network namespace, so this is revalidated as
    /// selection authority; it is never turned into an arbitrary `kubectl` flag.
    public let container: String?
    /// A requested local TCP port. `nil` asks kubectl for one ephemeral loopback
    /// port; zero, ranges, and non-TCP transports are not part of this type.
    public let localPort: Int?
    /// The exact TCP port in the selected Pod's network namespace.
    public let podPort: Int

    public init(
        namespace: String,
        pod: String,
        uid: String,
        container: String? = nil,
        localPort: Int? = nil,
        podPort: Int
    ) {
        self.namespace = namespace
        self.pod = pod
        self.uid = uid
        self.container = container
        self.localPort = localPort
        self.podPort = podPort
    }
}

/// The non-secret information a caller may retain about one active Pod forward.
///
/// A lease is process-local only. It is neither persisted nor restored after an app,
/// daemon, VM, or Kubernetes restart. Cancellation requires the exact lease ID so a
/// late selection change cannot tear down a newer forward accidentally.
public struct K8sPodPortForwardLease: Equatable, Sendable {
    public let id: UUID
    public let request: K8sPodPortForwardRequest
    /// The actual loopback port reported by the bundled kubectl process. This differs
    /// from `request.localPort` only when the caller requested an ephemeral port.
    public let localPort: Int

    init(id: UUID, request: K8sPodPortForwardRequest, localPort: Int) {
        self.id = id
        self.request = request
        self.localPort = localPort
    }
}

/// A fresh, API-derived view of the Pod a forward is allowed to target.
///
/// This type is deliberately small. It contains only the identity and lifecycle facts
/// required to prevent retargeting a forward; it is not a second Pod representation
/// for the app UI.
public struct K8sPodPortForwardTarget: Equatable, Sendable {
    public struct Container: Equatable, Sendable {
        public let name: String
        public let isRunning: Bool

        public init(name: String, isRunning: Bool) {
            self.name = name
            self.isRunning = isRunning
        }
    }

    public let namespace: String
    public let name: String
    public let uid: String
    public let isRunning: Bool
    public let isDeleting: Bool
    public let containers: [Container]

    public init(
        namespace: String,
        name: String,
        uid: String,
        isRunning: Bool,
        isDeleting: Bool,
        containers: [Container]
    ) {
        self.namespace = namespace
        self.name = name
        self.uid = uid
        self.isRunning = isRunning
        self.isDeleting = isDeleting
        self.containers = containers
    }

    /// Requires the live Pod to still be the exact selected target. A container is
    /// selection authority, not a transport switch: all regular containers in a Pod
    /// share its network namespace, which is the endpoint kubectl forwards to.
    func validate(_ request: K8sPodPortForwardRequest) throws {
        guard namespace == request.namespace, name == request.pod else {
            throw MorbError.io(
                "the selected Kubernetes Pod changed while starting its local port forward; refresh and select it again")
        }
        guard uid == request.uid else {
            throw MorbError.io(
                "the selected Kubernetes Pod was replaced (its UID changed); select the current Pod before forwarding")
        }
        guard isRunning, !isDeleting else {
            throw MorbError.io(
                "the selected Kubernetes Pod is no longer running; wait for a current running Pod before forwarding")
        }

        if let container = request.container {
            guard containers.contains(where: { $0.name == container && $0.isRunning }) else {
                throw MorbError.io(
                    "the selected container is no longer running in this Pod; select a current running container before forwarding")
            }
        } else {
            let running = containers.filter(\.isRunning)
            guard running.count == 1 else {
                throw MorbError.io(
                    "select one running container before forwarding this multi-container Pod")
            }
        }
    }
}

/// Coordinates one selected-Pod loopback TCP forward owned by the daemon.
///
/// Kubernetes owns the port-forward protocol, including connection relays and the
/// listener. Morbstack therefore launches only its hash-pinned helper in a private
/// process group instead of attempting a partial WebSocket/SPDY implementation. The
/// coordinator owns the child lifetime, bounds startup, sanitises its environment,
/// and never reconnects, retargets, or restores a forward.
public final class K8sPodPortForwardCoordinator: @unchecked Sendable {

    /// Startup has a finite budget so a dead API server cannot leave an invisible
    /// child and listener behind. The timeout is intentionally shorter than the
    /// daemon's ordinary client budget, leaving time to terminate and report truth.
    public static let startupTimeout: TimeInterval = 15

    /// A cancellation sends TERM to the private process group, then KILL only that
    /// same group if it did not exit. No broad process-name lookup is ever used.
    private static let terminationGrace: TimeInterval = 3

    private let log: MorbLog
    private let queue = DispatchQueue(label: "dev.morbstack.k8s.port-forward", qos: .userInitiated)
    /// `waitpid` blocks for the whole lease. Keep it off the output queue so the
    /// readiness line can be drained while the child is still running.
    private let waitQueue = DispatchQueue(label: "dev.morbstack.k8s.port-forward.wait", qos: .utility)
    private let lock = NSLock()
    private var current: Run?
    private var starting = false

    public init(log: MorbLog) {
        self.log = log
    }

    /// Starts one forward after the caller has supplied a fresh daemon-owned
    /// readiness check. This method never starts Kubernetes, publishes the API
    /// server, generates a kubeconfig, consults PATH, or consults user Kubernetes
    /// configuration.
    ///
    /// The readiness closure is run both before the child is launched and after its
    /// exact loopback readiness line. A new target is read from the authenticated
    /// Morbstack API at both points, preventing a Pod recreation from being silently
    /// adopted while kubectl starts.
    @discardableResult
    public func start(
        _ request: K8sPodPortForwardRequest,
        prerequisites: () throws -> K8sPodPortForwardPrerequisites
    ) throws -> K8sPodPortForwardLease {
        try Self.validate(request)
        try claimStartSlot()
        defer { releaseStartSlotIfNeeded() }

        // Verify the only permitted executable before creating a credential
        // descriptor, binding anything, or launching any child.
        let kubectl = try MorbKubernetesKubectl.bundledKubectl()
        let initial = try prerequisites()
        let initialTarget = try Self.readTarget(request, kubeconfigURL: initial.kubeconfigURL)
        try initialTarget.validate(request)

        // The credentials live only in an unlinked, 0600 descriptor inherited by the
        // child as /dev/fd/3. The real path therefore never appears in arguments,
        // diagnostics, logs, or an exported command. `KUBECONFIG` is deliberately
        // absent from the child's small environment.
        let credential = try Self.makePrivateCredentialDescriptor(from: initial.kubeconfigURL)
        guard credential.fingerprint == initial.kubeconfigFingerprint else {
            Darwin.close(credential.descriptor)
            throw MorbError.io(
                "Morbstack’s private Kubernetes credentials changed while preparing the selected Pod forward; generate or select the current Pod again")
        }
        let run: Run
        do {
            run = try spawn(kubectl: kubectl, request: request, credentialFD: credential.descriptor)
        } catch {
            Darwin.close(credential.descriptor)
            throw error
        }
        Darwin.close(credential.descriptor)

        lock.lock()
        current = run
        starting = false
        lock.unlock()
        beginOutputRead(for: run)
        beginWait(for: run)

        let ready = run.readySignal.wait(timeout: .now() + Self.startupTimeout)
        guard ready == .success else {
            stop(run, reason: "did not report a loopback listener before the startup deadline")
            throw MorbError.timeout(
                "the bundled Kubernetes port-forward did not open its loopback listener within \(Int(Self.startupTimeout)) seconds")
        }

        lock.lock()
        let actualPort = run.readyPort
        let stillCurrent = current === run && !run.cancelled && !run.exited
        lock.unlock()
        guard let actualPort, stillCurrent else {
            stop(run, reason: "exited or was cancelled before becoming ready")
            throw MorbError.io(
                "the bundled Kubernetes port-forward exited before opening its requested loopback listener")
        }

        do {
            let final = try prerequisites()
            guard final.apiForwardPort == initial.apiForwardPort,
                  final.kubeconfigFingerprint == initial.kubeconfigFingerprint
            else {
                throw MorbError.io(
                    "Morbstack’s local Kubernetes API forward or private credentials changed while starting the Pod forward; start it again from the current Pod")
            }
            let finalTarget = try Self.readTarget(request, kubeconfigURL: final.kubeconfigURL)
            try finalTarget.validate(request)
        } catch {
            stop(run, reason: "target or local Kubernetes prerequisites changed during startup")
            throw error
        }

        lock.lock()
        let active = current === run && !run.cancelled && !run.exited
        if active { run.validated = true }
        lock.unlock()
        guard active else {
            stop(run, reason: "exited before startup revalidation completed")
            throw MorbError.io(
                "the bundled Kubernetes port-forward exited while Morbstack revalidated the selected Pod")
        }

        log.info(
            "selected Kubernetes Pod forward active on 127.0.0.1:\(actualPort) for \(request.namespace)/\(request.pod)")
        return K8sPodPortForwardLease(id: run.id, request: request, localPort: actualPort)
    }

    /// Cancels only the matching current lease. Passing a stale lease is deliberately
    /// a no-op: a former inspector must not terminate a different selected Pod's
    /// newer forward.
    public func cancel(_ lease: K8sPodPortForwardLease) {
        _ = cancel(id: lease.id)
    }

    /// Cancels only a current lease with this exact opaque ID. Returning `false` is
    /// intentionally not an error: a selection owner may be cleaning up after the
    /// helper already exited, and it must never turn that stale cleanup into a
    /// cancellation of a later selection.
    @discardableResult
    public func cancel(id: UUID) -> Bool {
        lock.lock()
        let run: Run?
        if let current, current.id == id, !current.cancelled, !current.exited {
            run = current
        } else {
            run = nil
        }
        lock.unlock()
        guard let run else { return false }
        stop(run, reason: "cancelled explicitly")
        return true
    }

    /// Cancels the one current lease, if any. Daemon lifecycle, selection, and route
    /// owners call this rather than attempting to resume a forward later.
    public func cancelAll(reason: String) {
        lock.lock()
        let run = current
        lock.unlock()
        if let run { stop(run, reason: reason) }
    }

    /// There is no persisted state; this only answers whether a child still owns one
    /// current forward in this daemon process.
    public var activeLease: K8sPodPortForwardLease? {
        lock.lock()
        defer { lock.unlock() }
        guard let run = current, let localPort = run.readyPort, run.validated,
              !run.cancelled, !run.exited
        else {
            return nil
        }
        return K8sPodPortForwardLease(id: run.id, request: run.request, localPort: localPort)
    }

    // MARK: - Request and target authority

    private static func validate(_ request: K8sPodPortForwardRequest) throws {
        try validateDNSIdentifier(request.namespace, label: "namespace", maximumLength: 63)
        try validateDNSIdentifier(request.pod, label: "Pod name", maximumLength: 253)
        try validateDNSIdentifier(request.uid, label: "Pod UID", maximumLength: 253)
        if let container = request.container {
            try validateDNSIdentifier(container, label: "container name", maximumLength: 63)
        }
        if let localPort = request.localPort {
            guard (1...65535).contains(localPort) else {
                throw MorbError.protocolViolation(
                    "the requested local Kubernetes port must be between 1 and 65535, or omitted for an ephemeral loopback port")
            }
        }
        guard (1...65535).contains(request.podPort) else {
            throw MorbError.protocolViolation(
                "the selected Kubernetes Pod TCP port must be between 1 and 65535")
        }
    }

    private static func validateDNSIdentifier(_ value: String, label: String, maximumLength: Int) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        guard !value.isEmpty,
              value.count <= maximumLength,
              value.unicodeScalars.allSatisfy(allowed.contains),
              value.first?.isLetter == true || value.first?.isNumber == true,
              value.last?.isLetter == true || value.last?.isNumber == true
        else {
            throw MorbError.protocolViolation(
                "the selected Kubernetes \(label) is not a supported DNS-style identifier")
        }
    }

    private static func readTarget(
        _ request: K8sPodPortForwardRequest,
        kubeconfigURL: URL
    ) throws -> K8sPodPortForwardTarget {
        let reader = try K8sResourceReader(kubeconfigURL: kubeconfigURL)
        return try reader.portForwardTarget(namespace: request.namespace, pod: request.pod)
    }

    // MARK: - Child launch and output

    private final class Run {
        let id = UUID()
        let request: K8sPodPortForwardRequest
        let pid: pid_t
        let outputFD: Int32
        let readySignal = DispatchSemaphore(value: 0)
        var outputSource: DispatchSourceRead?
        var pendingOutput = Data()
        var readyPort: Int?
        var validated = false
        var cancelled = false
        var exited = false
        var readySignalled = false

        init(request: K8sPodPortForwardRequest, pid: pid_t, outputFD: Int32) {
            self.request = request
            self.pid = pid
            self.outputFD = outputFD
        }
    }

    private func claimStartSlot() throws {
        lock.lock()
        defer { lock.unlock() }
        guard current == nil, !starting else {
            throw MorbError.io(
                "a selected Kubernetes Pod port-forward is already starting or active; cancel it before starting another")
        }
        starting = true
    }

    private func releaseStartSlotIfNeeded() {
        lock.lock()
        if current == nil { starting = false }
        lock.unlock()
    }

    private func spawn(
        kubectl: URL,
        request: K8sPodPortForwardRequest,
        credentialFD: Int32
    ) throws -> Run {
        var outputPipe = try Self.makePipe()
        defer {
            // Ownership of the read end transfers to `Run` only on a successful
            // spawn. The child receives a duplicate of the write end.
            if outputPipe.didTransferReadEnd == false { Darwin.close(outputPipe.read) }
        }
        defer { Darwin.close(outputPipe.write) }

        var actions = posix_spawn_file_actions_t()
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw MorbError.io("could not initialise the Kubernetes port-forward process actions")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        let openedNullInput = Darwin.open("/dev/null", O_RDONLY)
        guard openedNullInput >= 0 else {
            throw MorbError.io("could not prepare standard input for the Kubernetes port-forward process")
        }
        let nullInput = Darwin.fcntl(openedNullInput, F_DUPFD, 10)
        Darwin.close(openedNullInput)
        guard nullInput >= 0 else {
            throw MorbError.io("could not prepare standard input for the Kubernetes port-forward process")
        }
        defer { Darwin.close(nullInput) }

        // All inherited descriptor numbers are moved above the standard descriptors,
        // so the ordering below is stable even in a daemon started with unusual stdio.
        guard posix_spawn_file_actions_adddup2(&actions, nullInput, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, outputPipe.write, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, outputPipe.write, STDERR_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, credentialFD, Self.credentialDescriptor) == 0,
              posix_spawn_file_actions_addclose(&actions, outputPipe.read) == 0,
              posix_spawn_file_actions_addclose(&actions, outputPipe.write) == 0,
              posix_spawn_file_actions_addclose(&actions, nullInput) == 0,
              (credentialFD == Self.credentialDescriptor
                || posix_spawn_file_actions_addclose(&actions, credentialFD) == 0)
        else {
            throw MorbError.io("could not configure the Kubernetes port-forward process descriptors")
        }

        var attributes = posix_spawnattr_t()
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw MorbError.io("could not initialise the Kubernetes port-forward process attributes")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0
        else {
            throw MorbError.io("could not isolate the Kubernetes port-forward process group")
        }

        let localMapping = request.localPort.map { "\($0):\(request.podPort)" } ?? ":\(request.podPort)"
        let arguments = [
            kubectl.path,
            "--kubeconfig=/dev/fd/\(Self.credentialDescriptor)",
            "--namespace", request.namespace,
            "--address", "127.0.0.1",
            "port-forward",
            "pod/\(request.pod)",
            localMapping,
        ]
        let environment = [
            "PATH=/usr/bin:/bin",
            "HOME=/var/empty",
            "LANG=C",
            "LC_ALL=C",
        ]

        let pid = try Self.posixSpawn(
            executable: kubectl.path,
            arguments: arguments,
            environment: environment,
            actions: &actions,
            attributes: &attributes)
        outputPipe.didTransferReadEnd = true
        return Run(request: request, pid: pid, outputFD: outputPipe.read)
    }

    private func beginOutputRead(for run: Run) {
        let source = DispatchSource.makeReadSource(fileDescriptor: run.outputFD, queue: queue)
        source.setEventHandler { [weak self, weak run] in
            guard let self, let run else { return }
            self.drainOutput(for: run)
        }
        let outputFD = run.outputFD
        source.setCancelHandler {
            Darwin.close(outputFD)
        }
        lock.lock()
        run.outputSource = source
        lock.unlock()
        source.resume()
    }

    private func beginWait(for run: Run) {
        waitQueue.async { [weak self, run] in
            guard let self else { return }
            var status: Int32 = 0
            while Darwin.waitpid(run.pid, &status, 0) == -1, errno == EINTR {}
            self.childExited(run, waitStatus: status)
        }
    }

    private func drainOutput(for run: Run) {
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = bytes.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(run.outputFD, base, raw.count)
            }
            if count > 0 {
                lock.lock()
                guard current === run || (!run.exited && !run.cancelled) else {
                    lock.unlock()
                    return
                }
                run.pendingOutput.append(contentsOf: bytes[0..<count])
                Self.trimOutputBuffer(&run.pendingOutput)
                let lines = Self.takeCompleteLines(from: &run.pendingOutput)
                lock.unlock()
                for line in lines { observeOutput(line, from: run) }
                continue
            }
            if count == 0 {
                lock.lock()
                let source = run.outputSource
                run.outputSource = nil
                lock.unlock()
                source?.cancel()
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            lock.lock()
            let source = run.outputSource
            run.outputSource = nil
            lock.unlock()
            source?.cancel()
            return
        }
    }

    private func observeOutput(_ line: String, from run: Run) {
        guard let port = Self.readyPort(in: line, expectedPodPort: run.request.podPort) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard current === run, !run.cancelled, !run.exited, run.readyPort == nil else { return }
        run.readyPort = port
        run.readySignalled = true
        run.readySignal.signal()
    }

    private func childExited(_ run: Run, waitStatus: Int32) {
        lock.lock()
        run.exited = true
        let wasCurrent = current === run
        if wasCurrent { current = nil }
        starting = false
        let source = run.outputSource
        run.outputSource = nil
        if !run.readySignalled {
            run.readySignalled = true
            run.readySignal.signal()
        }
        let wasCancelled = run.cancelled
        lock.unlock()
        source?.cancel()

        guard !wasCancelled else { return }
        let status = Self.exitDescription(waitStatus)
        log.warn(
            "selected Kubernetes Pod port-forward for \(run.request.namespace)/\(run.request.pod) ended (\(status)); it was not restarted")
    }

    private func stop(_ run: Run, reason: String) {
        lock.lock()
        guard !run.cancelled else {
            lock.unlock()
            return
        }
        run.cancelled = true
        if current === run { current = nil }
        starting = false
        let source = run.outputSource
        run.outputSource = nil
        if !run.readySignalled {
            run.readySignalled = true
            run.readySignal.signal()
        }
        let exited = run.exited
        lock.unlock()
        source?.cancel()
        guard !exited else { return }

        // A negative PID names exactly the isolated group created with
        // POSIX_SPAWN_SETPGROUP. This also cleans up an unexpected helper child,
        // without targeting another user's kubectl or any unrelated process.
        _ = Darwin.kill(-run.pid, SIGTERM)
        queue.asyncAfter(deadline: .now() + Self.terminationGrace) { [weak self, weak run] in
            guard let self, let run else { return }
            self.lock.lock()
            let shouldKill = !run.exited
            self.lock.unlock()
            if shouldKill { _ = Darwin.kill(-run.pid, SIGKILL) }
        }
        log.info(
            "selected Kubernetes Pod port-forward for \(run.request.namespace)/\(run.request.pod) \(reason)")
    }

    // MARK: - Private credential descriptor

    private static let credentialDescriptor: Int32 = 3

    /// Creates an unlinked 0600 descriptor containing Morbstack's own kubeconfig.
    /// There is deliberately no pathname after this method returns. A kubectl child
    /// receives only descriptor 3 and opens `/dev/fd/3`; callers never get a URL to
    /// inspect, copy, or accidentally expose.
    private struct PrivateCredentialDescriptor {
        let descriptor: Int32
        let fingerprint: String
    }

    private static func makePrivateCredentialDescriptor(
        from source: URL
    ) throws -> PrivateCredentialDescriptor {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let isSymbolicLink = (try? fileManager.destinationOfSymbolicLink(atPath: source.path)) != nil
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
              !isSymbolicLink,
              !isDirectory.boolValue,
              fileManager.isReadableFile(atPath: source.path)
        else {
            throw MorbError.io(
                "Morbstack’s private kubeconfig is unavailable; generate a new private kubeconfig before forwarding a Pod")
        }
        let attributes = try fileManager.attributesOfItem(atPath: source.path)
        guard let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              mode & 0o077 == 0
        else {
            throw MorbError.config(
                "Morbstack’s private kubeconfig permissions are too broad; generate a new private kubeconfig before forwarding a Pod")
        }

        try fileManager.createDirectory(
            at: MorbPaths.runDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        var template = MorbPaths.runDirectory
            .appendingPathComponent("k8s-port-forward-XXXXXXXX", isDirectory: false)
            .path
            .utf8CString
        let descriptor = template.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return Darwin.mkstemp(base)
        }
        guard descriptor >= 0 else {
            throw MorbError.io("could not create the private Kubernetes port-forward credential descriptor")
        }
        let temporaryPath = String(cString: template)
        defer { _ = Darwin.unlink(temporaryPath) }
        guard Darwin.fchmod(descriptor, 0o600) == 0 else {
            Darwin.close(descriptor)
            throw MorbError.io("could not restrict the private Kubernetes port-forward credential descriptor")
        }

        var hasher = SHA256()
        do {
            guard let sourceHandle = FileHandle(forReadingAtPath: source.path) else {
                throw MorbError.io("could not open Morbstack’s private kubeconfig for Pod forwarding")
            }
            defer { try? sourceHandle.close() }
            while true {
                let chunk = sourceHandle.readData(ofLength: 1 << 16)
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
                try writeAll(chunk, to: descriptor)
            }
            guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else {
                throw MorbError.io("could not rewind the private Kubernetes port-forward credential descriptor")
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }

        let moved = Darwin.fcntl(descriptor, F_DUPFD, 10)
        Darwin.close(descriptor)
        guard moved >= 0 else {
            throw MorbError.io("could not prepare the private Kubernetes credential descriptor for forwarding")
        }
        let fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return PrivateCredentialDescriptor(descriptor: moved, fingerprint: fingerprint)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
            }
            if count > 0 {
                offset += count
                continue
            }
            if count < 0, errno == EINTR { continue }
            throw MorbError.io("could not write the private Kubernetes port-forward credential descriptor")
        }
    }

    // MARK: - POSIX helpers

    private struct PipeEnds {
        let read: Int32
        let write: Int32
        var didTransferReadEnd = false
    }

    private static func makePipe() throws -> PipeEnds {
        var descriptors: [Int32] = [0, 0]
        guard Darwin.pipe(&descriptors) == 0 else {
            throw MorbError.io("could not create the Kubernetes port-forward output pipe")
        }
        let read = Darwin.fcntl(descriptors[0], F_DUPFD, 10)
        let write = Darwin.fcntl(descriptors[1], F_DUPFD, 10)
        Darwin.close(descriptors[0])
        Darwin.close(descriptors[1])
        guard read >= 0, write >= 0 else {
            if read >= 0 { Darwin.close(read) }
            if write >= 0 { Darwin.close(write) }
            throw MorbError.io("could not prepare the Kubernetes port-forward output pipe")
        }
        let flags = Darwin.fcntl(read, F_GETFL, 0)
        guard flags >= 0, Darwin.fcntl(read, F_SETFL, flags | O_NONBLOCK) == 0 else {
            Darwin.close(read)
            Darwin.close(write)
            throw MorbError.io("could not configure the Kubernetes port-forward output pipe")
        }
        return PipeEnds(read: read, write: write)
    }

    private static func posixSpawn(
        executable: String,
        arguments: [String],
        environment: [String],
        actions: inout posix_spawn_file_actions_t,
        attributes: inout posix_spawnattr_t
    ) throws -> pid_t {
        let argumentStorage = arguments.map { strdup($0) }
        let environmentStorage = environment.map { strdup($0) }
        defer {
            argumentStorage.forEach { pointer in
                if let pointer { free(pointer) }
            }
            environmentStorage.forEach { pointer in
                if let pointer { free(pointer) }
            }
        }
        guard !argumentStorage.contains(where: { $0 == nil }),
              !environmentStorage.contains(where: { $0 == nil })
        else {
            throw MorbError.io("could not allocate the Kubernetes port-forward process arguments")
        }
        var argv = argumentStorage + [nil]
        var envp = environmentStorage + [nil]
        var pid: pid_t = 0
        let result = executable.withCString { path in
            posix_spawn(&pid, path, &actions, &attributes, &argv, &envp)
        }
        guard result == 0 else {
            throw MorbError.io(
                "could not launch Morbstack’s bundled Kubernetes port-forward helper: \(String(cString: strerror(result)))")
        }
        return pid
    }

    private static func readyPort(in line: String, expectedPodPort: Int) -> Int? {
        let prefix = "Forwarding from 127.0.0.1:"
        let suffix = " -> \(expectedPodPort)"
        guard line.hasPrefix(prefix), line.hasSuffix(suffix) else { return nil }
        let start = line.index(line.startIndex, offsetBy: prefix.count)
        let end = line.index(line.endIndex, offsetBy: -suffix.count)
        guard let port = Int(line[start..<end]), (1...65535).contains(port) else { return nil }
        return port
    }

    private static func takeCompleteLines(from data: inout Data) -> [String] {
        var lines: [String] = []
        while let newline = data.firstIndex(of: 0x0A) {
            let line = String(decoding: data[data.startIndex..<newline], as: UTF8.self)
            data.removeSubrange(...newline)
            lines.append(line)
        }
        return lines
    }

    private static func trimOutputBuffer(_ data: inout Data) {
        // Output is only used to recognise one fixed non-secret readiness line. Keep
        // at most one partial line, so a hostile/erroring child cannot retain an
        // unbounded diagnostic blob in the daemon.
        let maximum = 16 * 1024
        if data.count > maximum { data.removeFirst(data.count - maximum) }
    }

    private static func exitDescription(_ status: Int32) -> String {
        // `waitpid` encodes a normal status in the high byte and a terminating
        // signal in the low seven bits. Do not retain child output here: it can
        // include arbitrary server text, while this fixed summary proves the lease
        // ended without making a credential-bearing diagnostic channel.
        let signal = status & 0x7f
        if signal == 0 { return "exit status \((status >> 8) & 0xff)" }
        if signal < 0x7f { return "signal \(signal)" }
        return "stopped by the operating system"
    }
}

/// The daemon-owned facts a coordinator revalidates around child readiness.
///
/// This has no public initializer because only `K8sManager` may claim that its API
/// forward and private kubeconfig are current.
public struct K8sPodPortForwardPrerequisites: Sendable {
    fileprivate let kubeconfigURL: URL
    fileprivate let apiForwardPort: Int
    fileprivate let kubeconfigFingerprint: String

    init(kubeconfigURL: URL, apiForwardPort: Int) throws {
        self.kubeconfigURL = kubeconfigURL
        self.apiForwardPort = apiForwardPort
        self.kubeconfigFingerprint = try Self.fingerprint(of: kubeconfigURL)
    }

    private static func fingerprint(of url: URL) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw MorbError.io("Morbstack could not read its private kubeconfig for selected Pod forwarding")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 16)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
