// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The bounded contract for a future FSEvents -> guest file-notification bridge.
//
// This is deliberately *not* a hot-reload implementation. VirtioFS propagates bytes
// but not host-originated inotify events, and Linux offers no userspace API that can
// inject synthetic events into another process's inotify descriptor. The current MRB0
// channel is also request/reply only, so there is no event receiver to drain a queue.
// Keep the selection, FSEvents interpretation, overflow rule, and diagnostics here so
// the eventual transport/kernel endpoint has one truthful contract to implement.

import Foundation

/// Plans and records scoped host file-system invalidations for a future live-share
/// bridge.
///
/// A live-share root is never inferred from the broad VirtioFS defaults. It must be
/// explicitly named in `live_share_paths` and be a strict descendant of a configured
/// share. No FSEvent stream is created by this type today: there is no guest delivery
/// endpoint and keeping an unconsumed watch queue alive would be both wasteful and a
/// false hot-reload claim.
public enum MorbLiveShareBridge {

    /// No more than this many narrow roots may be selected for the future bridge.
    /// This is separate from `MorbShares.maximumShares`: one broad VirtioFS share can
    /// cover several explicitly selected development projects.
    public static let maximumRoots = 8

    /// Maximum number of pending event records. Overflow is never hidden; it replaces
    /// affected records with a `rescan` marker that a future receiver must honor.
    public static let defaultBufferCapacity = 1_024

    /// A defensive upper bound beneath MRB0's 1 MiB frame limit. A path bigger than
    /// this is represented as a root rescan, not queued as an arbitrarily large event.
    public static let maximumEventPathUTF8Bytes = 4_096

    /// The version of the future delivery contract, independent of MRB0's framing.
    public static let contractVersion = 1

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
            roots.append(Root(path: path, backingSharePath: backing.path))
        }
        return Plan(roots: roots)
    }

    /// The only two payload forms a future guest receiver may observe.
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

    /// A normalized record from the future host event source.
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
    /// user's filesystem. The eventual CoreServices adapter must pass the flag word
    /// through unchanged.
    public enum FSEventFlag {
        public static let mustScanSubdirectories: UInt32 = 0x00000001
        public static let userDropped: UInt32 = 0x00000002
        public static let kernelDropped: UInt32 = 0x00000004
        public static let eventIDsWrapped: UInt32 = 0x00000008
        public static let rootChanged: UInt32 = 0x00000020
    }

    /// Result of admitting one host event. A coalesced/overflow result is still a
    /// useful event: the future receiver must honor the queued root rescan.
    public enum RecordResult: Equatable, Sendable {
        case enqueued
        case rescanQueued
        case coalescedByExistingRescan
        case ignoredOutsideScope
    }

    /// A thread-safe, bounded event queue. It owns no FSEvent stream and starts no
    /// background work; the future daemon-owned adapter will feed it only after the
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
        /// selected plan are rejected rather than allowing a future stream to leak
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

        /// Number of bounded records awaiting a future delivery transport.
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

    /// What the currently running guest says about future event delivery.
    /// `unknown` is intentionally distinct from `unavailable`: an older or stopped
    /// guest has not answered, while the current guest positively has no injection
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
        }

        public let state: State
        public let roots: [Root]
        public let guestCapability: GuestCapability
        public let detail: String

        /// Always false in this foundation. Keeping the boolean makes a future UI or
        /// CLI avoid inferring active delivery merely from selected roots.
        public var isActive: Bool { false }

        public var ipcFields: [String: AnyCodableValue] {
            [
                "state": .string(state.rawValue),
                "active": .bool(isActive),
                "guest_capability": .string(guestCapability.rawValue),
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
        guestCapability: GuestCapability
    ) -> Diagnostic {
        guard !paths.isEmpty else {
            return Diagnostic(
                state: .disabled,
                roots: [],
                guestCapability: guestCapability,
                detail: "No live_share_paths are configured; Morbstack does not watch broad VirtioFS roots.")
        }
        let plan: Plan
        do {
            plan = try plan(paths: paths, shares: shares)
        } catch {
            return Diagnostic(
                state: .invalidConfiguration,
                roots: [],
                guestCapability: guestCapability,
                detail: (error as? MorbError)?.description ?? error.localizedDescription)
        }
        let unmounted = plan.roots.filter {
            guestShareStates[$0.backingSharePath] != .mounted
        }
        if !unmounted.isEmpty {
            return Diagnostic(
                state: .waitingForGuestMount,
                roots: plan.roots,
                guestCapability: guestCapability,
                detail: "Waiting for the guest to confirm the VirtioFS share(s) covering "
                    + unmounted.map(\.path).joined(separator: ", ") + ".")
        }
        let detail: String
        switch guestCapability {
        case .unknown:
            detail = "The guest has not reported a file-notification capability; no FSEvents watch is started."
        case .unavailable:
            detail = "The guest has no inotify injection endpoint; no FSEvents watch is started."
        case .ready:
            detail = "The guest can receive the future contract, but this build has no event-stream transport; no FSEvents watch is started."
        }
        return Diagnostic(
            state: .deliveryUnavailable,
            roots: plan.roots,
            guestCapability: guestCapability,
            detail: detail)
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
