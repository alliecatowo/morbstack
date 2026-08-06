// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Live CPU, memory, network and block I/O for the rows that are actually on screen.
//
// `/containers/{id}/stats` is one long-lived connection per container, so a naive
// "subscribe on appear" over a hundred rows would open a hundred sockets and wake the
// UI a hundred times a second. Three things prevent that:
//
//   * subscriptions are reference-counted, so a row and the detail pane looking at the
//     same container share one stream;
//   * samples are throttled to one every two seconds, because a number that changes
//     faster than the eye can read it is decoration, not information;
//   * each container gets its own `@Observable` probe, so a sample for `nginx` does not
//     invalidate the row for `postgres`. A single dictionary on one observable object
//     would redraw the entire list on every sample, which is exactly the kind of jank
//     that makes a list feel cheap.

import Foundation
import Observation

/// The live stats for one container.
///
/// Handed to whichever views care; the hub owns the stream feeding it.
@MainActor
@Observable
final class TrackBStatsProbe {

    /// How many samples the sparklines draw.
    static let historyLimit = 60

    let containerID: String

    /// The most recent sample, or `nil` before the first one arrives.
    private(set) var latest: StatsSample?

    /// Up to `historyLimit` samples, oldest first.
    private(set) var history: [StatsSample] = []

    /// `true` once the stream has delivered anything.
    private(set) var isLive = false

    /// Set when the stream failed; the UI degrades to dashes rather than to a spinner
    /// that never resolves.
    private(set) var failure: String?

    init(containerID: String) {
        self.containerID = containerID
        history.reserveCapacity(Self.historyLimit)
    }

    func record(_ sample: StatsSample) {
        latest = sample
        isLive = true
        failure = nil
        history.append(sample)
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
    }

    func markFailed(_ message: String) {
        failure = message
        isLive = false
    }

    /// Clears everything but the identity — used when a container restarts and its old
    /// curve would splice onto the new process's.
    func reset() {
        latest = nil
        history.removeAll(keepingCapacity: true)
        isLive = false
        failure = nil
    }

    var cpuSeries: [Double] { history.map(\.cpuPercent) }
    var memorySeries: [Double] { history.map { Double($0.memBytes) } }
    var networkRates: [ByteRateSample] { StatsSample.networkRates(in: history) }
    var blockIORates: [ByteRateSample] { StatsSample.blockIORates(in: history) }
}

/// Owns the stats streams and hands out probes.
///
/// Not `@Observable`: nothing observes the hub itself, only the probes it vends. That
/// is the whole point — see the note at the top of the file.
@MainActor
final class TrackBStatsHub {

    /// Minimum spacing between samples handed to the UI.
    let minimumInterval: TimeInterval

    private var probes: [String: TrackBStatsProbe] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var retainCounts: [String: Int] = [:]

    /// Probes for containers nobody is watching are kept so that scrolling a row back
    /// into view redraws its sparkline instantly instead of starting from an empty
    /// chart. The cache is bounded because a long session on a busy engine would
    /// otherwise accumulate one per container ever seen.
    private let idleProbeLimit = 128

    init(minimumInterval: TimeInterval = 2.0) {
        self.minimumInterval = minimumInterval
    }

    /// Starts (or joins) the stream for `id` and returns its probe.
    ///
    /// Every `retain` must be balanced by exactly one `release`.
    @discardableResult
    func retain(_ id: String, client: DockerClient) -> TrackBStatsProbe {
        let probe = probes[id] ?? {
            let fresh = TrackBStatsProbe(containerID: id)
            probes[id] = fresh
            return fresh
        }()

        retainCounts[id, default: 0] += 1
        guard tasks[id] == nil else { return probe }

        let interval = minimumInterval
        tasks[id] = Task { [weak self, weak probe] in
            var lastAccepted = Date.distantPast
            do {
                for try await sample in client.stats(id: id) {
                    if Task.isCancelled { return }
                    // The engine samples roughly once a second; taking every other one
                    // is cheaper and steadier than resampling, and the value it reports
                    // is already an average over its own window.
                    let now = Date()
                    guard now.timeIntervalSince(lastAccepted) >= interval - 0.15 else { continue }
                    lastAccepted = now
                    probe?.record(sample)
                }
                // A clean end means the container stopped: the last reading is stale, and
                // leaving it on screen implies a process that is still burning CPU.
                if !Task.isCancelled { probe?.markFailed("stream ended") }
            } catch {
                if !Task.isCancelled { probe?.markFailed(TrackBErrorText.short(error)) }
            }
            if !Task.isCancelled { self?.tasks[id] = nil }
        }
        return probe
    }

    /// Drops one reference; the stream closes when the last one goes.
    func release(_ id: String) {
        guard let count = retainCounts[id] else { return }
        if count <= 1 {
            retainCounts[id] = nil
            tasks[id]?.cancel()
            tasks[id] = nil
            pruneIdleProbes()
        } else {
            retainCounts[id] = count - 1
        }
    }

    /// Existing probe without subscribing — for a row that wants to show the last known
    /// numbers while it decides whether to stream.
    func existingProbe(_ id: String) -> TrackBStatsProbe? { probes[id] }

    /// Installs a probe filled from a fixed series, opening no stream.
    ///
    /// Previews and deterministic fixture runs use this because a chart needs a history,
    /// while live history only exists after a stats socket has streamed. Seeding makes
    /// the chart's data and behavior inspectable without opening that stream.
    @discardableResult
    func seed(_ id: String, samples: [StatsSample]) -> TrackBStatsProbe {
        let probe = probes[id] ?? TrackBStatsProbe(containerID: id)
        probe.reset()
        for sample in samples { probe.record(sample) }
        probes[id] = probe
        return probe
    }

    /// Forgets a container entirely, e.g. after it is removed.
    func forget(_ id: String) {
        retainCounts[id] = nil
        tasks[id]?.cancel()
        tasks[id] = nil
        probes[id] = nil
    }

    /// Drops a process's old history before subscribing after a stop/restart. The
    /// Docker counters and CPU baseline are tied to that process lifetime, so joining
    /// the old series to the new one would fabricate a continuous trend.
    func reset(_ id: String) {
        probes[id]?.reset()
    }

    /// Cancels everything. Called when the Containers screen goes away.
    func stopAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        retainCounts.removeAll()
    }

    private func pruneIdleProbes() {
        let idle = probes.keys.filter { retainCounts[$0] == nil }
        guard probes.count > idleProbeLimit else { return }
        // Oldest-first is not knowable here, and it does not matter: any bounded
        // eviction keeps the cache honest, and a re-subscribe rebuilds in two seconds.
        for id in idle.prefix(probes.count - idleProbeLimit) { probes[id] = nil }
    }
}

// MARK: - Errors

enum TrackBErrorText {

    /// A one-line description fit for a row or a caption.
    static func short(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        let text = String(describing: error)
        return text.count > 160 ? String(text.prefix(160)) + "…" : text
    }
}
