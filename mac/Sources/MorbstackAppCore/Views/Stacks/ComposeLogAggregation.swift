// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The non-visual half of the Compose-aggregated log document: which service a line came
// from, what colour that service is, and — the part that is actually hard — what order
// several concurrent streams should be shown in.
//
// Everything here is a pure value type with an injectable clock. Interleaving is a
// correctness problem, not a cosmetic one: two services merged by arrival order will lie
// about causality the moment one stream is slower than the other, and a lie about
// ordering in a log is worse than not shipping the log. A screenshot cannot audit any of
// this, so it is all testable without a window.

import Foundation
import SwiftUI

// MARK: - Service identity

/// One service inside an aggregated document.
///
/// `containerID` is identity — a service can be recreated under a new container while
/// the name stays put, and the palette must follow the *name*, not the container.
struct TrackBLogSource: Hashable, Identifiable, Sendable {

    /// The Docker container currently serving this service's output.
    let containerID: String
    /// The Compose service name, or the container name when Docker reported no service
    /// label. This is the text the row shows; colour is only ever supplemental to it.
    let service: String
    /// Slot in `ComposeServicePalette`.
    let colorIndex: Int

    var id: String { containerID }
}

// MARK: - Palette

/// Per-service colour for the aggregated document.
///
/// Three rules, in priority order:
///
///  1. **The service name is always drawn as text.** Colour is a second, redundant
///     channel. A colour-blind reader, a high-contrast setting, and a black-and-white
///     screenshot all lose the hue and lose nothing else.
///  2. **Colour never touches the message body.** The body belongs to the ANSI parser —
///     those escapes are the program's own explicit presentation, and repainting them
///     per service would both discard information and produce two colour systems
///     fighting inside one line. The service colour is applied to the service *column*
///     only, so the two can never collide.
///  3. **Assignment is a pure function of the service names.** Same project, same
///     colours — across a container restart, a `compose down`/`up`, and an app relaunch.
///
/// The slots are drawn from the existing ANSI palette rather than a new colour set:
/// those sixteen are already tuned for contrast against the log surface in both
/// appearances (`ContainerLogPalette.ansi`), and reusing them keeps one palette in the
/// app instead of two. Black, white and the greys are excluded — a service that is the
/// same colour as ordinary text is not colour-coded at all.
enum ComposeServicePalette {

    static let slots: [TrackBAnsiColor] = [
        .blue, .green, .magenta, .cyan, .yellow, .red,
        .brightBlue, .brightGreen, .brightMagenta, .brightCyan,
    ]

    static func color(at index: Int) -> Color {
        ContainerLogPalette.ansi(slots[((index % slots.count) + slots.count) % slots.count])
    }

    /// Assigns a palette slot to every service name.
    ///
    /// Deterministic in two senses that both matter:
    ///
    ///   * **Order-independent.** The caller may hand these over in any order; the
    ///     result is the same. (The engine does not promise a container listing order.)
    ///   * **Stable across processes.** The hash is FNV-1a over UTF-8, written out here
    ///     rather than taken from `Hasher`, because Swift seeds `hashValue` per process:
    ///     using it would give every service a new colour on every app launch, which is
    ///     precisely the property this function exists to provide.
    ///
    /// Collisions are resolved by probing forward from the hashed slot, walking the
    /// names in sorted order, so every service in a project of ten or fewer gets a
    /// distinct colour. Adding a service can move the colour of another service it
    /// collides with; that is the cost of not reshuffling the whole project every time,
    /// which rank-based assignment would do.
    static func assign(services: [String]) -> [String: Int] {
        var taken = Set<Int>()
        var result: [String: Int] = [:]
        for name in Set(services).sorted() {
            let start = Int(fnv1a(name) % UInt64(slots.count))
            var slot = start
            var probes = 0
            while taken.contains(slot), probes < slots.count {
                slot = (slot + 1) % slots.count
                probes += 1
            }
            taken.insert(slot)
            result[name] = slot
        }
        return result
    }

    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }
}

/// One document's live colour assignment.
///
/// Held as its own value because assignments must be **immutable for the life of a
/// document**: a line already on screen carries the colour index it was rendered with,
/// so re-running the whole assignment when a service appears mid-session would leave
/// old lines one colour and new lines another for the same service. A service
/// discovered later therefore takes the next free slot from its own hash instead.
struct ComposeServiceColors {

    private(set) var assignments: [String: Int]
    private var taken: Set<Int>

    init(services: [String]) {
        assignments = ComposeServicePalette.assign(services: services)
        taken = Set(assignments.values)
    }

    mutating func index(for service: String) -> Int {
        if let existing = assignments[service] { return existing }
        let start = Int(ComposeServicePalette.fnv1a(service) % UInt64(ComposeServicePalette.slots.count))
        var slot = start
        var probes = 0
        while taken.contains(slot), probes < ComposeServicePalette.slots.count {
            slot = (slot + 1) % ComposeServicePalette.slots.count
            probes += 1
        }
        taken.insert(slot)
        assignments[service] = slot
        return slot
    }
}

// MARK: - Merge

/// Merges several per-container log streams into one ordered transcript.
///
/// **The ordering contract, stated plainly, because the alternative is a subtle lie:**
///
///   * Lines are ordered by the timestamp *dockerd* recorded when the container wrote
///     them (`timestamps=1` on every `/containers/{id}/logs` request). Every service in
///     a project is served by the same daemon, so those stamps share one clock and are
///     comparable across services. Timestamps printed *inside* a message by the program
///     itself are never parsed and never used for ordering — they can be any clock, any
///     zone, or a lie.
///   * Arrival order is not order. A slower stream would otherwise push its lines behind
///     a faster service's later output and invert cause and effect. Lines are therefore
///     held briefly and released in timestamp order.
///   * **Nothing is ever re-ordered once shown.** A released line keeps its position for
///     the life of the document, and IDs are assigned at release, so display order and
///     ID order are the same sequence. The find navigator's binary search depends on
///     that, and so does anyone reading.
///   * **A line whose engine timestamp is missing** — a TTY stream, or a prefix Docker
///     did not write — inherits the last timestamp seen from *its own service*, so a
///     stack trace stays attached to the line that started it. A service that never
///     produces a usable timestamp falls back to arrival time for all of its lines: with
///     no clock reading, arrival is the only honest answer, and the timestamp column
///     shows "—" so the reader can see which lines those are.
///
/// **Known failure modes, deliberately accepted:**
///
///   * A line delayed by more than `holdInterval` (a stalled socket, a reconnect) is
///     appended where it arrived, out of timestamp order. It is not dropped and it is
///     not inserted into history: its true timestamp stays on screen, so the
///     discontinuity is visible rather than silently smoothed.
///   * `pendingLimit` bounds memory on a firehose. Past it, the oldest pending lines are
///     released even if they have not ripened, trading reorder accuracy for a bound.
struct ComposeLogMerge {

    /// A line waiting to be released.
    struct Pending: Equatable {
        var line: LogLine
        var source: TrackBLogSource
        /// The instant the line reached this process.
        var receivedAt: Date
        /// What it is sorted by. See the type comment.
        var orderKey: Date
        /// Global ingest counter; the tie-break that makes sorting stable.
        var sequence: Int
    }

    /// How long a line waits before it can be shown, so a slower stream's earlier line
    /// still lands ahead of it. Long enough to absorb ordinary socket jitter between two
    /// streams on one local daemon, short enough that "live" still looks live.
    let holdInterval: TimeInterval
    /// The longest the document stays blank while waiting for every service to answer.
    let primeTimeout: TimeInterval
    /// Upper bound on lines held for reordering.
    let pendingLimit: Int

    private var pending: [Pending] = []
    private var sequence = 0
    private var lastTimestamps: [String: Date] = [:]
    private var registered: Set<String> = []
    private var ready: Set<String> = []
    private var primeDeadline: Date?

    init(
        holdInterval: TimeInterval = 0.25,
        primeTimeout: TimeInterval = 2.0,
        pendingLimit: Int = 20_000
    ) {
        self.holdInterval = holdInterval
        self.primeTimeout = primeTimeout
        self.pendingLimit = pendingLimit
    }

    /// Declares a service the document is waiting on before it shows anything.
    ///
    /// This is what stops the common start-up case from being wrong: every service
    /// answers `tail` with a burst of history, and whichever one answers first would
    /// otherwise have its whole backlog rendered before the others' backlogs existed.
    mutating func register(_ source: TrackBLogSource, at now: Date) {
        registered.insert(source.id)
        if primeDeadline == nil { primeDeadline = now.addingTimeInterval(primeTimeout) }
    }

    /// A service produced its first line, ended, or failed — either way it is no longer
    /// something the document should wait for.
    mutating func markReady(_ sourceID: String) {
        ready.insert(sourceID)
    }

    /// Whether the document is still waiting for its services' first answers.
    func isPriming(at now: Date) -> Bool {
        guard let primeDeadline else { return false }
        guard !registered.isEmpty else { return false }
        if ready.isSuperset(of: registered) { return false }
        return now < primeDeadline
    }

    var pendingCount: Int { pending.count }

    mutating func ingest(_ line: LogLine, from source: TrackBLogSource, at now: Date) {
        markReady(source.id)
        let key: Date
        if let timestamp = line.timestamp {
            lastTimestamps[source.id] = timestamp
            key = timestamp
        } else {
            key = lastTimestamps[source.id] ?? now
        }
        pending.append(
            Pending(line: line, source: source, receivedAt: now, orderKey: key, sequence: sequence))
        sequence += 1
    }

    /// Releases everything that can be shown now, in order.
    ///
    /// The rule is "release the longest sorted prefix that has ripened, and stop at the
    /// first line that has not". Releasing every ripe line instead — the obvious
    /// implementation — would emit a line ahead of an *earlier* one that is still
    /// waiting, which is the exact defect the hold interval exists to prevent.
    mutating func drain(now: Date) -> [Pending] {
        guard !pending.isEmpty else { return [] }
        if isPriming(at: now) { return [] }

        pending.sort { left, right in
            left.orderKey == right.orderKey
                ? left.sequence < right.sequence
                : left.orderKey < right.orderKey
        }

        let watermark = now.addingTimeInterval(-holdInterval)
        var count = 0
        while count < pending.count, pending[count].receivedAt <= watermark { count += 1 }

        // A firehose must not be able to grow this buffer without bound. Releasing
        // unripened lines here can mis-order them relative to a slower stream; a bounded
        // ordering error beats an unbounded allocation.
        if pending.count - count > pendingLimit {
            count = pending.count - pendingLimit
        }

        guard count > 0 else { return [] }
        let released = Array(pending.prefix(count))
        pending.removeFirst(count)
        return released
    }

    /// Releases everything held, ordered, without waiting. Used when the document stops.
    mutating func flush() -> [Pending] {
        guard !pending.isEmpty else { return [] }
        pending.sort { left, right in
            left.orderKey == right.orderKey
                ? left.sequence < right.sequence
                : left.orderKey < right.orderKey
        }
        let released = pending
        pending.removeAll(keepingCapacity: true)
        return released
    }

    mutating func removeAll() {
        pending.removeAll(keepingCapacity: true)
        lastTimestamps.removeAll()
        registered.removeAll()
        ready.removeAll()
        primeDeadline = nil
        sequence = 0
    }
}
