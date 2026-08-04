// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import CoreServices
import CryptoKit
import Darwin
import Dispatch
import Foundation
import Security

/// Owns one authenticated host-edit notification session for explicitly selected
/// VirtioFS project roots.
///
/// VirtioFS already makes host-written bytes readable in the guest.  The missing
/// piece is a guest-kernel filesystem operation that makes ordinary Linux watchers
/// notice that byte change.  This service starts an FSEvent stream only after the
/// guest receiver has authenticated the exact mounted-share claims.  It forwards
/// bounded invalidations (not invented inotify masks) to vsock 2381; the guest
/// receiver translates each accepted record into a descriptor-confined VFS metadata
/// nudge on the same VirtioFS object.
///
/// A selected root is never inferred from a bind request or a broad share.  A
/// disconnect, guest boot change, mount failure, overflow which cannot be fully
/// reconciled, or configuration mismatch closes the whole session and stops its
/// FSEvents stream before any retry can occur.
public final class MorbLiveShareTransport: @unchecked Sendable {

    /// A terminal per-configuration failure. Retrying it without an operator
    /// changing the selected root would repeatedly walk the same oversized tree.
    private enum TerminalFailure: LocalizedError {
        case receiverRescanLimit

        var errorDescription: String? {
            switch self {
            case .receiverRescanLimit:
                return "the guest could not complete the bounded live-share root rescan"
            }
        }
    }

    public enum State: Equatable, Sendable {
        case disabled
        case waitingForGuest
        case connecting
        case active
        case failed(String)
        case stopped
    }

    private static let eventAckTimeout: TimeInterval = 5
    private static let reconnectDelay: TimeInterval = 2
    private static let echoCoalescingWindow: TimeInterval = 0.25

    private let vm: VMManager
    private let config: MorbConfig
    private let log: MorbLog
    private let queue = DispatchQueue(label: "dev.morbstack.live-share.lifecycle", qos: .utility)
    private let stateLock = NSLock()
    private var stateStorage: State = .stopped
    private var generation: UInt64 = 0
    private var session: Session?
    private var watcher: FSEventWatcher?
    private var draining = false
    /// The guest's same-mode metadata write can itself be visible to FSEvents.
    /// Suppress only the matching path for one coalescing window so it cannot turn
    /// into a self-sustaining host→guest loop; a root rescan is never suppressed.
    private var echoedPaths: [String: Date] = [:]

    /// The immutable root authority serialized in the authenticated hello. This
    /// remains internal so focused tests can prove that the running transport uses
    /// the same narrow-plan and backing-share contract as the guest receiver, without
    /// opening a vsock connection or an FSEvent stream.
    struct WireClaim: Equatable {
        let rootID: String
        let tag: String
        let rootPath: String
        let backingPath: String
        let readOnly: Bool
        let epoch: UInt64
    }

    public init(vm: VMManager, config: MorbConfig, log: MorbLog) {
        self.vm = vm
        self.config = config
        self.log = log
    }

    public var state: State {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stateStorage
    }

    /// Factual status for daemon/CLI surfaces.  It deliberately reuses the
    /// pure planner diagnostic for selection and mount errors, then adds only
    /// lifecycle facts owned by this transport.
    public func diagnostic() -> MorbLiveShareBridge.Diagnostic {
        let snapshot = vm.shareMountSnapshot
        var shares = snapshot.shares
        if shares.isEmpty { shares = (try? vm.sharePlan())?.shares ?? [] }
        let advertisement = MorbLiveShareBridge.GuestAdvertisement(
            wireCapability: vm.guestShareEventBridge,
            contractVersion: vm.guestShareEventBridgeContractVersion)
        let base = MorbLiveShareBridge.diagnose(
            paths: config.liveSharePaths,
            shares: shares,
            guestShareStates: snapshot.guestShareStates,
            guestAdvertisement: advertisement)
        switch state {
        case .active:
            return MorbLiveShareBridge.Diagnostic(
                state: .active, roots: base.roots,
                guestCapability: base.guestCapability,
                guestContractVersion: base.guestContractVersion,
                contractCompatibility: base.contractCompatibility,
                detail: "Authenticated receiver session and scoped FSEvents watch are active.")
        case .failed(let detail):
            return MorbLiveShareBridge.Diagnostic(
                state: .failed, roots: base.roots,
                guestCapability: base.guestCapability,
                guestContractVersion: base.guestContractVersion,
                contractCompatibility: base.contractCompatibility,
                detail: detail)
        case .connecting:
            return MorbLiveShareBridge.Diagnostic(
                state: .waitingForSession, roots: base.roots,
                guestCapability: base.guestCapability,
                guestContractVersion: base.guestContractVersion,
                contractCompatibility: base.contractCompatibility,
                detail: "Connecting to the authenticated guest live-share receiver.")
        case .waitingForGuest:
            return MorbLiveShareBridge.Diagnostic(
                state: .waitingForSession, roots: base.roots,
                guestCapability: base.guestCapability,
                guestContractVersion: base.guestContractVersion,
                contractCompatibility: base.contractCompatibility,
                detail: "Waiting for the running guest to report its live-share receiver and mounted roots.")
        case .disabled, .stopped:
            return base
        }
    }

    /// Starts or re-evaluates the session for a running VM.  It is safe to call on
    /// every VM state transition: previous transport and watcher ownership are
    /// closed before a new attempt begins.
    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation &+= 1
            self.stopOnQueue(reason: "restarting live-share session", reportStopped: false)
            self.openWhenReady(generation: self.generation)
        }
    }

    /// Stops transport first, then invalidates the FSEvent stream.  This ordering
    /// makes callbacks harmless during teardown and guarantees no host filesystem
    /// metadata is retained after an opted-in root is revoked.
    public func stop(reason: String) {
        queue.async { [weak self] in
            self?.generation &+= 1
            self?.stopOnQueue(reason: reason, reportStopped: true)
        }
    }

    private func openWhenReady(generation: UInt64) {
        guard generation == self.generation else { return }
        guard vm.state == .running else {
            setState(.waitingForGuest)
            return
        }
        guard !config.liveSharePaths.isEmpty else {
            setState(.disabled)
            return
        }
        let advertisement = MorbLiveShareBridge.GuestAdvertisement(
            wireCapability: vm.guestShareEventBridge,
            contractVersion: vm.guestShareEventBridgeContractVersion)
        guard MorbLiveShareBridge.DeliveryAdmission.evaluate(advertisement)
            == .compatibleReceiverRequiresTransport
        else {
            setState(.waitingForGuest)
            retry(generation: generation)
            return
        }

        let snapshot = vm.shareMountSnapshot
        let plan: MorbLiveShareBridge.Plan
        do {
            plan = try MorbLiveShareBridge.plan(paths: config.liveSharePaths, shares: snapshot.shares)
            guard !plan.roots.isEmpty else {
                setState(.disabled)
                return
            }
            try Self.validateHostRoots(plan.roots, shares: snapshot.shares)
            for root in plan.roots {
                guard snapshot.guestShareStates[root.backingSharePath] == .mounted else {
                    setState(.waitingForGuest)
                    retry(generation: generation)
                    return
                }
            }
        } catch {
            setState(.failed("live-share configuration: \(error)"))
            return
        }

        setState(.connecting)
        let descriptor: Int32
        switch vm.connectVsockBlocking(
            port: MorbVsockPorts.liveShareReceiver,
            timeout: Self.eventAckTimeout
        ) {
        case .success(let fd): descriptor = fd
        case .failure:
            setState(.waitingForGuest)
            retry(generation: generation)
            return
        }
        do {
            let liveSession = try Session.open(
                descriptor: descriptor,
                plan: plan,
                shares: snapshot.shares)
            guard generation == self.generation, vm.state == .running else {
                liveSession.close()
                return
            }
            session = liveSession
            let watcher = try FSEventWatcher(plan: plan) { [weak self] in
                self?.scheduleDrain()
            }
            try watcher.start()
            self.watcher = watcher
            // The stream begins after the receiver is authenticated, leaving a
            // small unavoidable setup interval in which an editor could have
            // changed a selected root.  Bytes are already coherent through
            // VirtioFS, so enqueue one bounded root invalidation before marking
            // the session active.  Callback drains are serialized behind this
            // work on `queue`, so a concurrent FSEvent cannot overtake it.
            for root in plan.roots {
                try liveSession.send(MorbLiveShareBridge.Event(
                    sourceEventID: 0,
                    rootPath: root.path,
                    path: root.path,
                    kind: .rescan))
            }
            setState(.active)
            log.info("live-share notifications active for \(plan.roots.count) explicit project root(s)")
        } catch {
            // `Session.open` either left descriptor ownership with this scope or
            // installed it as `session`; close through the owner exactly once.
            if let active = session {
                active.close()
                session = nil
            } else {
                Darwin.close(descriptor)
            }
            watcher?.stop()
            watcher = nil
            setState(.failed("live-share setup failed: \(error)"))
            if !(error is TerminalFailure) {
                retry(generation: generation)
            }
        }
    }

    private func retry(generation: UInt64) {
        queue.asyncAfter(deadline: .now() + Self.reconnectDelay) { [weak self] in
            self?.openWhenReady(generation: generation)
        }
    }

    private func scheduleDrain() {
        queue.async { [weak self] in
            guard let self, !self.draining else { return }
            self.draining = true
            defer { self.draining = false }
            self.drainEventsOnQueue()
        }
    }

    private func drainEventsOnQueue() {
        guard let watcher, let session, state == .active else { return }
        for event in watcher.drain() {
            pruneEchoes(now: Date())
            if event.kind == .invalidated,
               let until = echoedPaths[event.path], until > Date() {
                continue
            }
            do {
                try session.send(event)
                if event.kind == .invalidated {
                    echoedPaths[event.path] = Date().addingTimeInterval(Self.echoCoalescingWindow)
                }
            } catch {
                failActiveSession(error)
                return
            }
        }
    }

    private func failActiveSession(_ error: Error) {
        let currentGeneration = generation
        stopOnQueue(reason: "notification transport failure", reportStopped: false)
        setState(.failed("live-share transport: \(error)"))
        if error is TerminalFailure {
            log.warn("live-share stopped: \(error.localizedDescription)")
        } else {
            retry(generation: currentGeneration)
        }
    }

    private func stopOnQueue(reason: String, reportStopped: Bool) {
        watcher?.stop()
        watcher = nil
        session?.close()
        session = nil
        draining = false
        echoedPaths.removeAll(keepingCapacity: false)
        if reportStopped {
            setState(config.liveSharePaths.isEmpty ? .disabled : .stopped)
            log.info("live-share notifications stopped (\(reason))")
        }
    }

    private func setState(_ state: State) {
        stateLock.lock()
        stateStorage = state
        stateLock.unlock()
    }

    private func pruneEchoes(now: Date) {
        echoedPaths = echoedPaths.filter { $0.value > now }
    }

    /// Builds the exact root claims accepted by the guest's hello validator.
    ///
    /// This is pure protocol construction: callers must still establish the fresh
    /// authenticated receiver session before these claims become authority.
    static func makeWireClaims(
        plan: MorbLiveShareBridge.Plan,
        shares: [MorbDirectoryShare],
        epoch: UInt64
    ) throws -> [WireClaim] {
        guard epoch > 0 else {
            throw MorbError.protocolViolation("live-share root claim epoch must be nonzero")
        }
        var ids = Set<String>()
        return try plan.roots.map { root in
            guard let share = shares.first(where: { $0.path == root.backingSharePath }) else {
                throw MorbError.protocolViolation("live-share root has no current backing share")
            }
            var material = Data()
            material.append(Data(share.tag.utf8)); material.append(0)
            material.append(Data(root.path.utf8)); material.append(0)
            material.append(Data(root.backingSharePath.utf8)); material.append(0)
            material.append(share.readOnly ? 1 : 0)
            let id = "root_" + SHA256.hash(data: material)
                .map { String(format: "%02x", $0) }.joined().prefix(59)
            guard ids.insert(String(id)).inserted else {
                throw MorbError.protocolViolation("live-share generated duplicate root claim")
            }
            return WireClaim(
                rootID: String(id), tag: share.tag, rootPath: root.path,
                backingPath: root.backingSharePath, readOnly: share.readOnly, epoch: epoch)
        }
    }

    private static func validateHostRoots(
        _ roots: [MorbLiveShareBridge.Root],
        shares: [MorbDirectoryShare]
    ) throws {
        for root in roots {
            guard let share = shares.first(where: { $0.path == root.backingSharePath }) else {
                throw MorbError.protocolViolation("live-share root lost its backing VirtioFS share")
            }
            guard !share.readOnly else {
                throw MorbError.unsupported(
                    "live-share notifications require a writable VirtioFS root at \(root.path)")
            }
            var info = stat()
            guard lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
                throw MorbError.notFound("live-share root \(root.path) is not an existing directory")
            }
            guard (info.st_mode & S_IFMT) != S_IFLNK, access(root.path, R_OK | X_OK) == 0 else {
                throw MorbError.io("live-share root \(root.path) is not a readable, traversable real directory")
            }
            let physicalRoot = URL(fileURLWithPath: root.path).resolvingSymlinksInPath().path
            let physicalShare = URL(fileURLWithPath: root.backingSharePath).resolvingSymlinksInPath().path
            guard physicalRoot == root.path,
                  physicalShare == root.backingSharePath,
                  physicalRoot.hasPrefix(physicalShare + "/")
            else {
                throw MorbError.config(
                    "live-share root \(root.path) must be a real strict descendant of its configured VirtioFS share")
            }
        }
    }
}

private extension MorbLiveShareTransport {
    /// One authenticated vsock connection.  It owns no FSEvents stream, so a
    /// transport failure cannot leave a host watch alive by itself.
    final class Session {
        private let fd: Int32
        private let sessionHex: String
        private let bootHex: String
        private let capability: Data
        private let claimsByPath: [String: Claim]
        private var nextSequence: UInt64 = 1
        private var closed = false

        private struct Claim {
            let rootID: String
            let epoch: UInt64
            let rootPath: String
        }

        private init(
            fd: Int32,
            sessionHex: String,
            bootHex: String,
            capability: Data,
            claimsByPath: [String: Claim]
        ) {
            self.fd = fd
            self.sessionHex = sessionHex
            self.bootHex = bootHex
            self.capability = capability
            self.claimsByPath = claimsByPath
            POSIXSocketSupport.suppressSIGPIPE(fd)
        }

        static func open(
            descriptor: Int32,
            plan: MorbLiveShareBridge.Plan,
            shares: [MorbDirectoryShare]
        ) throws -> Session {
            let boot = try Self.readLine(fd: descriptor)
            let bootFields = boot.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
            guard bootFields.count == 2, bootFields[0] == "BOOT",
                  let bootData = Data(hexadecimal: String(bootFields[1])), bootData.count == 16
            else {
                throw MorbError.protocolViolation("live-share receiver did not present a 128-bit guest boot identity")
            }
            let capability = try Self.randomBytes(count: 32)
            let session = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let epoch = Self.epochFromCapability(capability)
            let claims = try MorbLiveShareTransport.makeWireClaims(
                plan: plan, shares: shares, epoch: epoch)
            let hello = "HELLO 1 \(session) \(bootFields[1]) \(capability.hexadecimalString) \(claims.count)"
            var transcript = Data((hello + "\n").utf8)
            try Self.sendLine(fd: descriptor, hello)
            for claim in claims.sorted(by: { $0.rootPath < $1.rootPath }) {
                let line = "ROOT \(claim.rootID) \(claim.tag) \(Self.percentEncode(claim.rootPath)) \(Self.percentEncode(claim.backingPath)) \(claim.readOnly ? "1" : "0") \(claim.epoch)"
                transcript.append(Data((line + "\n").utf8))
                try Self.sendLine(fd: descriptor, line)
            }
            try Self.sendLine(fd: descriptor, "COMMIT \(Self.hmacHex(key: capability, message: transcript))")
            let ready = try Self.readLine(fd: descriptor).trimmingCharacters(in: .whitespacesAndNewlines)
            let expectedReadyBody = "READY \(session) \(bootFields[1])"
            let readyFields = ready.split(separator: " ")
            guard readyFields.count == 4,
                  ready == "\(expectedReadyBody) \(Self.hmacHex(key: capability, message: Data(expectedReadyBody.utf8)))"
            else {
                throw MorbError.protocolViolation("live-share receiver authentication failed")
            }
            let claimMap = Dictionary(uniqueKeysWithValues: claims.map {
                ($0.rootPath, Claim(rootID: $0.rootID, epoch: $0.epoch, rootPath: $0.rootPath))
            })
            return Session(
                fd: descriptor,
                sessionHex: session,
                bootHex: String(bootFields[1]),
                capability: capability,
                claimsByPath: claimMap)
        }

        func send(_ event: MorbLiveShareBridge.Event) throws {
            guard !closed else { throw MorbError.io("live-share session is closed") }
            guard let claim = claimsByPath[event.rootPath] else {
                throw MorbError.protocolViolation("FSEvent escaped the active live-share root plan")
            }
            guard nextSequence < UInt64.max else {
                throw MorbError.protocolViolation("live-share sequence space exhausted")
            }
            let path: String
            let kind: String
            switch event.kind {
            case .invalidated:
                if event.path == claim.rootPath {
                    // FSEvents may report a root object metadata change without
                    // `RootChanged`.  It carries no safely scoped child name, so
                    // preserve correctness by requesting the bounded root rescan.
                    path = "-"
                    kind = "r"
                    break
                }
                guard event.path.hasPrefix(claim.rootPath + "/") else {
                    throw MorbError.protocolViolation("live-share invalidation was not strictly inside its root")
                }
                path = Self.percentEncode(String(event.path.dropFirst(claim.rootPath.count + 1)))
                kind = "i"
            case .rescan:
                path = "-"
                kind = "r"
            }
            let body = "EVENT \(nextSequence) \(claim.rootID) \(kind) \(path)"
            try Self.sendLine(fd: fd, "\(body) \(Self.hmacHex(key: capability, message: Data(body.utf8)))")
            let acknowledgement = try Self.readLine(fd: fd)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let expectedPrefix = "ACK \(sessionHex) \(bootHex) \(nextSequence) "
            let fields = acknowledgement.split(separator: " ")
            guard fields.count == 6, acknowledgement.hasPrefix(expectedPrefix) else {
                throw MorbError.protocolViolation("malformed live-share acknowledgement")
            }
            let disposition = String(fields[4])
            let acknowledgementBody = fields.dropLast().joined(separator: " ")
            guard Self.constantTimeEqual(
                String(fields[5]),
                Self.hmacHex(key: capability, message: Data(acknowledgementBody.utf8)))
            else {
                throw MorbError.protocolViolation("live-share acknowledgement HMAC failed")
            }
            nextSequence += 1
            guard disposition == "applied" else {
                if disposition == "rescan-required" {
                    throw MorbLiveShareTransport.TerminalFailure.receiverRescanLimit
                }
                throw MorbError.protocolViolation("live-share receiver rejected the invalidation")
            }
        }

        func close() {
            guard !closed else { return }
            closed = true
            let body = "CLOSE \(nextSequence)"
            _ = try? Self.sendLine(fd: fd, "\(body) \(Self.hmacHex(key: capability, message: Data(body.utf8)))")
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }

        private static func readLine(fd: Int32) throws -> String {
            try StreamDial.readReplyLine(
                fd: fd, deadline: Date().addingTimeInterval(MorbLiveShareTransport.eventAckTimeout))
        }

        private static func sendLine(fd: Int32, _ line: String) throws {
            // A ROOT claim may contain two percent-encoded PATH_MAX values.
            guard line.utf8.count < 32_768,
                  POSIXSocketSupport.writeAll(fd, Data((line + "\n").utf8))
            else {
                throw MorbError.io("could not send live-share protocol record")
            }
        }

        private static func randomBytes(count: Int) throws -> Data {
            var bytes = [UInt8](repeating: 0, count: count)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess,
                  bytes.contains(where: { $0 != 0 })
            else {
                throw MorbError.io("could not create live-share session capability")
            }
            return Data(bytes)
        }

        private static func epochFromCapability(_ capability: Data) -> UInt64 {
            let value = capability.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            return value == 0 ? 1 : value
        }

        private static func hmacHex(key: Data, message: Data) -> String {
            Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))).hexadecimalString
        }

        private static func constantTimeEqual(_ left: String, _ right: String) -> Bool {
            let left = Array(left.utf8), right = Array(right.utf8)
            guard left.count == right.count else { return false }
            return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
        }

        private static func percentEncode(_ path: String) -> String {
            let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._/")
            return path.utf8.map { byte in
                let scalar = Character(UnicodeScalar(byte))
                return allowed.contains(scalar) ? String(scalar) : String(format: "%%%02X", byte)
            }.joined()
        }
    }

    final class FSEventWatcher {
        private final class CallbackBox {
            let buffer: MorbLiveShareBridge.EventBuffer
            let callback: () -> Void
            init(plan: MorbLiveShareBridge.Plan, callback: @escaping () -> Void) {
                buffer = MorbLiveShareBridge.EventBuffer(plan: plan)
                self.callback = callback
            }
        }

        private let queue = DispatchQueue(label: "dev.morbstack.live-share.fsevents", qos: .utility)
        private let box: CallbackBox
        private var stream: FSEventStreamRef?
        private var retainedBox: UnsafeMutableRawPointer?

        init(plan: MorbLiveShareBridge.Plan, callback: @escaping () -> Void) throws {
            box = CallbackBox(plan: plan, callback: callback)
            let retained = Unmanaged.passRetained(box).toOpaque()
            retainedBox = retained
            var context = FSEventStreamContext(
                version: 0, info: retained, retain: nil, release: nil, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagWatchRoot)
            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault, Self.callback, &context,
                plan.roots.map(\.path) as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15, flags)
            else {
                Unmanaged<CallbackBox>.fromOpaque(retained).release()
                retainedBox = nil
                throw MorbError.io("could not create a scoped FSEvent stream")
            }
            self.stream = stream
        }

        deinit { stop() }

        func start() throws {
            guard let stream else { throw MorbError.io("live-share watcher is unavailable") }
            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else {
                throw MorbError.io("could not start the scoped live-share FSEvent stream")
            }
        }

        func stop() {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            if let retainedBox {
                Unmanaged<CallbackBox>.fromOpaque(retainedBox).release()
                self.retainedBox = nil
            }
        }

        func drain() -> [MorbLiveShareBridge.Event] { box.buffer.drain() }

        private static let callback: FSEventStreamCallback = {
            _, info, count, paths, flags, identifiers in
            // FSEvents guarantees paths, flags, and identifiers for every
            // callback. Only the client context is nullable in this stream.
            guard let info else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(paths, to: CFArray.self)
            for index in 0..<Int(count) {
                let item = CFArrayGetValueAtIndex(paths, index)
                let path = unsafeBitCast(item, to: CFString.self) as String
                _ = box.buffer.recordFSEvent(
                    sourceEventID: identifiers[index], path: path, flags: flags[index])
            }
            box.callback()
        }
    }
}

private extension Data {
    init?(hexadecimal value: String) {
        guard value.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    var hexadecimalString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
