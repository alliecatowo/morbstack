// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The bounded host-side contract for the FSEvents -> guest notification bridge.
//
// VirtioFS propagates bytes but cannot receive a synthetic inotify record from macOS.
// ``MorbLiveShareTransport`` owns the dedicated authenticated receiver session and
// turns these scoped invalidations into real guest-VFS metadata notifications.  This
// type remains pure so selection, FSEvent overflow, and status admission stay
// independently auditable and testable.

import Foundation

/// Plans and records scoped host file-system invalidations for live-share.
///
/// A live-share root is never inferred from the broad VirtioFS defaults. It must be
/// explicitly named in `live_share_paths` and be a strict descendant of a configured
/// share. This type remains pure and creates no stream itself; the daemon-owned
/// transport starts a scoped FSEvent stream only after its guest receiver is
/// authenticated and the exact shares are confirmed mounted.
public enum MorbLiveShareBridge {

    /// No more than this many narrow roots may be selected for one session.
    /// This is separate from `MorbShares.maximumShares`: one broad VirtioFS share can
    /// cover several explicitly selected development projects.
    public static let maximumRoots = 8

    /// Maximum number of pending event records. Overflow is never hidden; it replaces
    /// affected records with a `rescan` marker that the receiver must honor.
    public static let defaultBufferCapacity = 1_024

    /// A defensive upper bound beneath MRB0's 1 MiB frame limit. A path bigger than
    /// this is represented as a root rescan, not queued as an arbitrarily large event.
    public static let maximumEventPathUTF8Bytes = 4_096

    /// The version of the dedicated delivery contract, independent of MRB0 framing.
    public static let contractVersion = 1

    // MARK: - Guest advertisement validation

    /// The additive statement a running guest makes about the dedicated live-share
    /// receiver.
    ///
    /// This is deliberately an *advertisement*, not a request to start delivery.
    /// It is decoded from the existing `info` reply and can therefore be checked
    /// before a dedicated data-plane connection exists. Keeping the capability and its
    /// schema version together prevents a host from mistaking an older guest's
    /// omitted version for the current contract, or from treating a coincidental
    /// version number as proof that a receiver session or watcher is active.
    public struct GuestAdvertisement: Codable, Equatable, Sendable {
        /// The receiver capability reported by the guest, if it recognizes the
        /// additive field at all.
        public let capability: GuestCapability
        /// The version reported alongside ``capability``. `nil` is an older or
        /// incomplete guest and is never promoted to ``contractVersion``.
        public let contractVersion: Int?

        public init(capability: GuestCapability, contractVersion: Int?) {
            self.capability = capability
            self.contractVersion = contractVersion
        }

        /// Builds the typed advertisement from the flat MRB0 `info` fields.
        public init(wireCapability: String?, contractVersion: Int?) {
            self.init(
                capability: GuestCapability(wireValue: wireCapability),
                contractVersion: contractVersion)
        }

        /// Whether this guest describes the exact schema this host understands.
        ///
        /// Compatibility alone is intentionally not delivery authorization. A
        /// matching `ready` receiver still needs a fresh authenticated session and
        /// mounted exact roots before the daemon starts FSEvents.
        public var compatibility: ContractCompatibility {
            guard let contractVersion else { return .unknown }
            return contractVersion == MorbLiveShareBridge.contractVersion
                ? .exact
                : .unsupported(actual: contractVersion)
        }
    }

    /// The host's verdict on the schema number carried by a
    /// ``GuestAdvertisement``.
    ///
    /// This is separate from ``GuestCapability`` on purpose. An unavailable guest
    /// can still name the current record shape, while a hypothetical ready guest
    /// with a different schema must fail closed.
    public enum ContractCompatibility: Codable, Equatable, Sendable {
        /// The guest did not report a version. Never assume version 1 by default.
        case unknown
        /// The guest and host agree on the versioned record schema.
        case exact
        /// The guest reported a different schema. It must not receive records from
        /// this host, even if it advertises an unrecognized `ready` capability.
        case unsupported(actual: Int)

        /// A stable value for diagnostics and daemon IPC. The detailed observed
        /// version remains in ``GuestAdvertisement/contractVersion``.
        public var wireValue: String {
            switch self {
            case .unknown:
                return "unknown"
            case .exact:
                return "exact"
            case .unsupported:
                return "unsupported"
            }
        }
    }

    /// A fact-only admission verdict for the daemon-owned live-share transport.
    /// The verdict does not itself authorize a watcher: the transport additionally
    /// establishes an authenticated session and verifies the mounted root snapshot.
    public enum DeliveryAdmission: Equatable, Sendable {
        case receiverUnknown
        case receiverUnavailable
        case unsupportedContractVersion(actual: Int?)
        case compatibleReceiverRequiresTransport

        /// Computes the admission verdict from facts already observed by the daemon.
        /// It starts no FSEvent stream and opens no host↔guest connection.
        public static func evaluate(_ advertisement: GuestAdvertisement) -> Self {
            switch advertisement.capability {
            case .unknown:
                return .receiverUnknown
            case .unavailable:
                return .receiverUnavailable
            case .ready:
                switch advertisement.compatibility {
                case .unknown:
                    return .unsupportedContractVersion(actual: nil)
                case .unsupported(let actual):
                    return .unsupportedContractVersion(actual: actual)
                case .exact:
                    return .compatibleReceiverRequiresTransport
                }
            }
        }
    }

    /// One explicitly selected project directory and the VirtioFS root that covers it.
    public struct Root: Codable, Equatable, Hashable, Sendable, Identifiable {
        /// The selected host and guest path. It is always a strict descendant of
        /// ``backingSharePath`` and is never displayed as a translated guest path.
        public let path: String
        /// The mounted VirtioFS root that makes `path` visible in the guest.
        public let backingSharePath: String

        public var id: String { path }

        public init(path: String, backingSharePath: String) {
            self.path = MorbShares.canonicalHostPath(path)
            self.backingSharePath = MorbShares.canonicalHostPath(backingSharePath)
        }
    }

    /// The validated opt-in roots. Planning has no filesystem or VM side effect.
    public struct Plan: Codable, Equatable, Sendable {
        public let roots: [Root]

        public init(roots: [Root] = []) {
            self.roots = roots
        }

        public var isEnabled: Bool { !roots.isEmpty }
    }

    /// Builds the event-bridge plan from explicit paths and actual VirtioFS shares.
    ///
    /// A mount root such as `/Users` is intentionally rejected even when it was
    /// explicitly listed: it is a sensible sharing root but an unbounded watcher.
    /// Selecting `/Users/name/project` under that share is the required scope.
    public static func plan(
        paths: [String],
        shares: [MorbDirectoryShare]
    ) throws -> Plan {
        guard paths.count <= maximumRoots else {
            throw MorbError.config(
                "too many live_share_paths: Morbstack permits at most \(maximumRoots) narrow roots")
        }

        let availableShares = shares.map { share in
            Root(path: share.path, backingSharePath: share.path)
        }
        var roots: [Root] = []
        var seen = Set<String>()

        for rawPath in paths {
            let path = MorbShares.canonicalHostPath(rawPath)
            guard path.hasPrefix("/"), path != "/" else {
                throw MorbError.config(
                    "live_share_paths entry \"\(rawPath)\" is not an absolute project directory")
            }
            guard seen.insert(path).inserted else {
                throw MorbError.config("live_share_paths lists \"\(path)\" more than once")
            }

            let matchingShares = availableShares.filter { isWithin(path, root: $0.path) }
            guard let backing = matchingShares.max(by: { $0.path.count < $1.path.count }) else {
                throw MorbError.config(
                    "live_share_paths entry \"\(path)\" is not inside a configured shared_paths root")
            }
            guard path != backing.path else {
                throw MorbError.config(
                    "live_share_paths entry \"\(path)\" is a broad VirtioFS root; select a narrower project directory beneath \(backing.path)")
            }
            let root = Root(path: path, backingSharePath: backing.path)
            // The guest treats a selected root as an immutable authority. Two
            // overlapping authorities would make one FSEvent eligible for two
            // independently sequenced claims, so the guest correctly rejects them
            // during its authenticated hello. Reject the same configuration before
            // the host can create a session that is guaranteed to fail.
            if let overlap = roots.first(where: {
                isWithin(root.path, root: $0.path) || isWithin($0.path, root: root.path)
            }) {
                throw MorbError.config(
                    "live_share_paths entries \"\(overlap.path)\" and \"\(root.path)\" overlap; select separate project directories")
            }
            roots.append(root)
        }
        return Plan(roots: roots)
    }

    /// The only two payload forms the guest receiver observes.
    ///
    /// `invalidated` deliberately is not named after an inotify mask. FSEvents is
    /// directory-granular and coalescing, so claiming create/write/delete fidelity here
    /// would be a lie. A receiver can use this as a path invalidation; a `rescan`
    /// invalidates the entire selected root.
    public enum EventKind: String, Codable, Equatable, Sendable {
        case invalidated
        case rescan
    }

    /// Why a receiver must discard incremental state and recursively rescan a root.
    public enum RescanReason: String, Codable, Equatable, Sendable {
        case fseventsMustScanSubdirectories = "fsevents-must-scan-subdirectories"
        case fseventsDropped = "fsevents-dropped"
        case fseventsRootChanged = "fsevents-root-changed"
        case fseventsEventIDsWrapped = "fsevents-event-ids-wrapped"
        case queueOverflow = "queue-overflow"
        case invalidPath = "invalid-path"
    }

    /// A normalized record from the host event source.
    public struct Event: Codable, Equatable, Sendable, Identifiable {
        /// FSEvent stream ID when one exists. IDs are monotonic but not consecutive.
        public let sourceEventID: UInt64
        /// The explicitly configured root that bounds this event.
        public let rootPath: String
        /// An invalidated path for `invalidated`, or the root itself for `rescan`.
        public let path: String
        public let kind: EventKind
        public let rescanReason: RescanReason?

        public var id: String {
            "\(sourceEventID):\(rootPath):\(path):\(kind.rawValue)"
        }

        public init(
            sourceEventID: UInt64,
            rootPath: String,
            path: String,
            kind: EventKind,
            rescanReason: RescanReason? = nil
        ) {
            let root = MorbShares.canonicalHostPath(rootPath)
            self.sourceEventID = sourceEventID
            self.rootPath = root
            // FSEvents gives us an OS path, not a user-authored config path. Preserve
            // its spelling (notably whitespace) instead of using `normalise`, which
            // trims textual config input. The one macOS alias remains necessary for
            // the same-path share comparison.
            self.path = kind == .rescan ? root : MorbLiveShareBridge.eventPath(path)
            self.kind = kind
            self.rescanReason = kind == .rescan ? rescanReason : nil
        }
    }

    /// Raw FSEvents flags used by ``EventBuffer/recordFSEvent``.
    ///
    /// The values mirror `FSEventStreamEventFlags`. They live as raw values so the
    /// pure queue can be tested without creating an FSEvent stream or touching the
    /// user's filesystem. The CoreServices adapter passes the flag word through
    /// unchanged.
    public enum FSEventFlag {
        public static let mustScanSubdirectories: UInt32 = 0x00000001
        public static let userDropped: UInt32 = 0x00000002
        public static let kernelDropped: UInt32 = 0x00000004
        public static let eventIDsWrapped: UInt32 = 0x00000008
        public static let rootChanged: UInt32 = 0x00000020
    }

    /// Result of admitting one host event. A coalesced/overflow result is still a
    /// useful event: the receiver must honor the queued root rescan.
    public enum RecordResult: Equatable, Sendable {
        case enqueued
        case rescanQueued
        case coalescedByExistingRescan
        case ignoredOutsideScope
    }

    /// A thread-safe, bounded event queue. It owns no FSEvent stream and starts no
    /// background work; the daemon-owned adapter feeds it only after the
    /// guest confirms both a mounted share and a real delivery endpoint.
    public final class EventBuffer: @unchecked Sendable {
        private struct Pending {
            let arrival: UInt64
            let event: Event
        }

        private let lock = NSLock()
        private let rootsByPath: [String: Root]
        private let capacity: Int
        private var nextArrival: UInt64 = 0
        private var pending: [Pending] = []
        private var rescans: [String: Pending] = [:]

        /// `capacity` must leave room for one rescan marker per root. This keeps an
        /// overflow bounded even when every configured project needs a full rescan.
        public init(plan: Plan, capacity: Int = MorbLiveShareBridge.defaultBufferCapacity) {
            precondition(
                capacity >= plan.roots.count,
                "live-share event capacity must hold one rescan marker per root")
            self.rootsByPath = Dictionary(uniqueKeysWithValues: plan.roots.map { ($0.path, $0) })
            self.capacity = max(capacity, 1)
        }

        /// Records one FSEvents callback record. This mapping is deliberately
        /// conservative: FSEvents coalesces directory changes, so a normal record is
        /// only an invalidation. Dropped/wrapped IDs require every selected root to be
        /// rescanned, as Apple documents for a multi-root stream.
        @discardableResult
        public func recordFSEvent(
            sourceEventID: UInt64,
            path rawPath: String,
            flags: UInt32
        ) -> RecordResult {
            let dropped = flags & (
                MorbLiveShareBridge.FSEventFlag.userDropped
                    | MorbLiveShareBridge.FSEventFlag.kernelDropped
            ) != 0
            if dropped {
                return recordAllRescans(
                    sourceEventID: sourceEventID,
                    reason: .fseventsDropped)
            }
            if flags & MorbLiveShareBridge.FSEventFlag.eventIDsWrapped != 0 {
                return recordAllRescans(
                    sourceEventID: sourceEventID,
                    reason: .fseventsEventIDsWrapped)
            }

            let path = MorbLiveShareBridge.eventPath(rawPath)
            guard let root = matchingRoot(for: path) else { return .ignoredOutsideScope }
            if path.utf8.count > MorbLiveShareBridge.maximumEventPathUTF8Bytes {
                return recordRescan(
                    root: root,
                    sourceEventID: sourceEventID,
                    reason: .invalidPath)
            }
            if flags & MorbLiveShareBridge.FSEventFlag.rootChanged != 0 {
                return recordRescan(
                    root: root,
                    sourceEventID: sourceEventID,
                    reason: .fseventsRootChanged)
            }
            if flags & MorbLiveShareBridge.FSEventFlag.mustScanSubdirectories != 0 {
                return recordRescan(
                    root: root,
                    sourceEventID: sourceEventID,
                    reason: .fseventsMustScanSubdirectories)
            }
            return record(
                Event(sourceEventID: sourceEventID, rootPath: root.path, path: path, kind: .invalidated))
        }

        /// Records a normalized contract event. Events whose root/path escapes the
        /// selected plan are rejected rather than allowing an event stream to leak
        /// host path names beyond the explicitly configured projects.
        @discardableResult
        public func record(_ event: Event) -> RecordResult {
            lock.lock()
            defer { lock.unlock() }
            return recordLocked(event)
        }

        /// Returns all pending records in arrival order and clears the buffer. A
        /// `rescan` record subsumes every earlier granular record for that root.
        public func drain() -> [Event] {
            lock.lock()
            defer { lock.unlock() }
            let result = (pending + rescans.values)
                .sorted { $0.arrival < $1.arrival }
                .map(\.event)
            pending.removeAll(keepingCapacity: true)
            rescans.removeAll(keepingCapacity: true)
            return result
        }

        /// Number of bounded records awaiting delivery.
        public var pendingCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return pending.count + rescans.count
        }

        private func recordAllRescans(
            sourceEventID: UInt64,
            reason: RescanReason
        ) -> RecordResult {
            lock.lock()
            defer { lock.unlock() }
            let roots = rootsByPath.values.sorted { $0.path < $1.path }
            guard !roots.isEmpty else { return .ignoredOutsideScope }
            var changed = false
            for root in roots {
                let result = recordRescanLocked(root: root, sourceEventID: sourceEventID, reason: reason)
                changed = changed || result == .rescanQueued
            }
            return changed ? .rescanQueued : .coalescedByExistingRescan
        }

        private func recordRescan(
            root: Root,
            sourceEventID: UInt64,
            reason: RescanReason
        ) -> RecordResult {
            lock.lock()
            defer { lock.unlock() }
            return recordRescanLocked(root: root, sourceEventID: sourceEventID, reason: reason)
        }

        private func recordLocked(_ event: Event) -> RecordResult {
            guard let root = rootsByPath[event.rootPath],
                  MorbLiveShareBridge.isWithin(event.path, root: root.path)
            else {
                return .ignoredOutsideScope
            }
            if event.kind == .rescan {
                return recordRescanLocked(
                    root: root,
                    sourceEventID: event.sourceEventID,
                    reason: event.rescanReason ?? .invalidPath)
            }
            if rescans[root.path] != nil { return .coalescedByExistingRescan }
            if pending.count + rescans.count >= capacity {
                return recordRescanLocked(
                    root: root,
                    sourceEventID: event.sourceEventID,
                    reason: .queueOverflow)
            }
            pending.append(Pending(arrival: issueArrival(), event: event))
            return .enqueued
        }

        private func recordRescanLocked(
            root: Root,
            sourceEventID: UInt64,
            reason: RescanReason
        ) -> RecordResult {
            if rescans[root.path] != nil { return .coalescedByExistingRescan }
            let hadRootEvent = pending.contains { $0.event.rootPath == root.path }
            pending.removeAll { $0.event.rootPath == root.path }

            // If a different root filled the bounded queue, one lost event means the
            // receiver cannot trust any incremental state. Replace the whole queue
            // with one marker per selected root; capacity was checked in init.
            if !hadRootEvent && pending.count + rescans.count >= capacity {
                pending.removeAll(keepingCapacity: true)
                rescans.removeAll(keepingCapacity: true)
                for root in rootsByPath.values.sorted(by: { $0.path < $1.path }) {
                    rescans[root.path] = Pending(
                        arrival: issueArrival(),
                        event: Event(
                            sourceEventID: sourceEventID,
                            rootPath: root.path,
                            path: root.path,
                            kind: .rescan,
                            rescanReason: .queueOverflow))
                }
                return .rescanQueued
            }

            rescans[root.path] = Pending(
                arrival: issueArrival(),
                event: Event(
                    sourceEventID: sourceEventID,
                    rootPath: root.path,
                    path: root.path,
                    kind: .rescan,
                    rescanReason: reason))
            return .rescanQueued
        }

        private func issueArrival() -> UInt64 {
            defer { nextArrival &+= 1 }
            return nextArrival
        }

        private func matchingRoot(for path: String) -> Root? {
            rootsByPath.values
                .filter { MorbLiveShareBridge.isWithin(path, root: $0.path) }
                .max { $0.path.count < $1.path.count }
        }
    }

    /// What the currently running guest says about event delivery.
    /// `unknown` is intentionally distinct from `unavailable`: an older or stopped
    /// guest has not answered, while the current guest positively has no delivery
    /// endpoint.
    public enum GuestCapability: String, Codable, Equatable, Sendable {
        case unknown
        case unavailable
        case ready

        public init(wireValue: String?) {
            self = wireValue.flatMap(Self.init(rawValue:)) ?? .unknown
        }
    }

    /// A read-only diagnostic for `morb shares`, the app, and support bundles.
    public struct Diagnostic: Codable, Equatable, Sendable {
        public enum State: String, Codable, Equatable, Sendable {
            case disabled
            case invalidConfiguration = "invalid-configuration"
            case waitingForGuestMount = "waiting-for-guest-mount"
            case deliveryUnavailable = "delivery-unavailable"
            /// The guest advertises the exact receiver contract and the daemon can
            /// now attempt its authenticated vsock session.  This is not active
            /// until the transport has completed hello/ready and started FSEvents.
            case waitingForSession = "waiting-for-session"
            /// The daemon has an authenticated receiver session and an active,
            /// scoped FSEvent stream for every listed root.
            case active
            /// A post-admission receiver or transport failure.  The daemon stops
            /// the stream before reconnecting so a failed session retains no watch.
            case failed
        }

        public let state: State
        public let roots: [Root]
        public let guestCapability: GuestCapability
        /// The guest's additive record-schema advertisement, kept beside the
        /// capability so status can distinguish an old guest from a version mismatch.
        public let guestContractVersion: Int?
        /// Whether the guest's advertised schema matches this host's record
        /// contract. It remains distinct from the transport's active-session state.
        public let contractCompatibility: ContractCompatibility
        public let detail: String

        /// `true` only after the daemon's authenticated data-plane owner reports an
        /// active session.  Configuration, a compatible guest, or root selection
        /// alone must never infer this state.
        public var isActive: Bool { state == .active }

        public var ipcFields: [String: AnyCodableValue] {
            [
                "state": .string(state.rawValue),
                "active": .bool(isActive),
                "guest_capability": .string(guestCapability.rawValue),
                "guest_contract_version": guestContractVersion.map { .int($0) } ?? .null,
                "expected_contract_version": .int(MorbLiveShareBridge.contractVersion),
                "contract_compatibility": .string(contractCompatibility.wireValue),
                "roots": .array(roots.map { root in
                    .object([
                        "path": .string(root.path),
                        "backing_share": .string(root.backingSharePath),
                    ])
                }),
                "detail": .string(detail),
            ]
        }
    }

    /// Explains why no event stream is active. It performs no host watch, VM action,
    /// or guest call; callers supply their already-observed shares/capability.
    public static func diagnose(
        paths: [String],
        shares: [MorbDirectoryShare],
        guestShareStates: [String: MorbShares.GuestMountState],
        guestAdvertisement: GuestAdvertisement
    ) -> Diagnostic {
        guard !paths.isEmpty else {
            return Diagnostic(
                state: .disabled,
                roots: [],
                guestCapability: guestAdvertisement.capability,
                guestContractVersion: guestAdvertisement.contractVersion,
                contractCompatibility: guestAdvertisement.compatibility,
                detail: "Live reload is off. Add narrow project directories to live_share_paths in config.toml, then restart the engine; Morbstack never watches broad VirtioFS roots.")
        }
        let plan: Plan
        do {
            plan = try Self.plan(paths: paths, shares: shares)
        } catch {
            return Diagnostic(
                state: .invalidConfiguration,
                roots: [],
                guestCapability: guestAdvertisement.capability,
                guestContractVersion: guestAdvertisement.contractVersion,
                contractCompatibility: guestAdvertisement.compatibility,
                detail: (error as? MorbError)?.description ?? error.localizedDescription)
        }
        let unmounted = plan.roots.filter {
            guestShareStates[$0.backingSharePath] != .mounted
        }
        if !unmounted.isEmpty {
            return Diagnostic(
                state: .waitingForGuestMount,
                roots: plan.roots,
                guestCapability: guestAdvertisement.capability,
                guestContractVersion: guestAdvertisement.contractVersion,
                contractCompatibility: guestAdvertisement.compatibility,
                detail: "Waiting for the guest to confirm the VirtioFS share(s) covering "
                    + unmounted.map(\.path).joined(separator: ", ") + ".")
        }
        let detail: String
        switch DeliveryAdmission.evaluate(guestAdvertisement) {
        case .receiverUnknown:
            detail = "The guest has not reported a file-notification capability; no FSEvents watch is started."
        case .receiverUnavailable:
            detail = "The guest has no inotify injection endpoint or compatible live-share receiver; no FSEvents watch is started."
        case .unsupportedContractVersion(let actual):
            if let actual {
                detail = "The guest reports share-event contract version \(actual), but this host requires version \(contractVersion); no FSEvents watch is started."
            } else {
                detail = "The guest did not report a share-event contract version; no FSEvents watch is started."
            }
        case .compatibleReceiverRequiresTransport:
            return Diagnostic(
                state: .waitingForSession,
                roots: plan.roots,
                guestCapability: guestAdvertisement.capability,
                guestContractVersion: guestAdvertisement.contractVersion,
                contractCompatibility: guestAdvertisement.compatibility,
                detail: "The guest receiver is compatible; waiting for morbstackd to establish its authenticated live-share session.")
        }
        return Diagnostic(
            state: .deliveryUnavailable,
            roots: plan.roots,
            guestCapability: guestAdvertisement.capability,
            guestContractVersion: guestAdvertisement.contractVersion,
            contractCompatibility: guestAdvertisement.compatibility,
            detail: detail)
    }

    /// Compatibility entry point for callers that only have the legacy capability
    /// value. New daemon code must pass ``GuestAdvertisement`` so an omitted or
    /// mismatched guest schema can fail closed instead of being silently assumed.
    ///
    /// The legacy shape predates the version field, so it models only the old
    /// in-process caller contract—not an observed guest advertisement. It is kept
    /// for source compatibility while older support surfaces migrate.
    @available(*, deprecated, message: "Pass GuestAdvertisement so the guest schema version is validated.")
    public static func diagnose(
        paths: [String],
        shares: [MorbDirectoryShare],
        guestShareStates: [String: MorbShares.GuestMountState],
        guestCapability: GuestCapability
    ) -> Diagnostic {
        diagnose(
            paths: paths,
            shares: shares,
            guestShareStates: guestShareStates,
            guestAdvertisement: GuestAdvertisement(
                capability: guestCapability,
                contractVersion: nil))
    }

    private static func isWithin(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// The event-side counterpart to the sharing planner's `/private` alias rule.
    /// It deliberately does not trim whitespace, collapse `.`/`..`, or resolve
    /// arbitrary symlinks: an FSEvents callback already names the filesystem object
    /// that changed, and rewriting it would turn an observability record into a lie.
    private static func eventPath(_ path: String) -> String {
        for alias in ["/tmp", "/var", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            return "/private" + path
        }
        return path
    }
}
