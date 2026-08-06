// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The log viewer's model: one stream in, a bounded scrollback out.
//
// Two decisions here carry the whole "10,000 lines at 120Hz" claim:
//
//  1. **Everything per-line is computed once, at ingest.** ANSI is parsed, the
//     attributed string is built, and a lowercased copy is cached the moment a line
//     arrives. A row's `body` then does nothing but hand SwiftUI a value it already
//     has. Parsing escapes inside `body` — the obvious way to write this — would redo
//     the work for every visible row on every frame, and a scroll would visibly stutter.
//
//  2. **Appends are batched into frames.** A container that logs thousands of lines a
//     second would otherwise publish thousands of observable changes a second, and
//     SwiftUI would try to honour every one. Lines land in a staging buffer and are
//     flushed on a fixed cadence, so the view redraws at a steady rate no matter how
//     loud the container is.

import Foundation
import Observation
import SwiftUI

// MARK: - Rendered line

/// One log line, pre-rendered.
///
/// `attributed` is built once and never rebuilt: the colours it holds are dynamic
/// `Color`s, so the same value renders correctly in light and dark without the cache
/// ever being invalidated.
struct TrackBRenderedLine: Identifiable {

    let id: Int
    let stream: StdStream
    let timestamp: Date?
    /// The line with escape sequences removed — what copy, export and search see.
    let plain: String
    /// `plain`, lowercased once, for the filter's hot loop.
    let lowered: String
    let attributed: AttributedString
    /// Which service produced the line, in an aggregated document. `nil` for a
    /// single-container transcript, where the whole document is one source.
    let source: TrackBLogSource?
    /// URLs found literally in the text. Empty for the overwhelming majority of lines.
    let links: [TrackBLinkSpan]

    /// - Parameters:
    ///   - id: overrides the per-stream ID Docker's assembler produced. An aggregated
    ///     document must number its lines itself: two containers' streams each count
    ///     from zero, and the find navigator requires IDs that ascend in *display*
    ///     order across the whole document.
    ///   - source: the service this line came from, in an aggregated document.
    init(_ line: LogLine, id: Int? = nil, source: TrackBLogSource? = nil) {
        self.id = id ?? line.id
        self.stream = line.stream
        self.timestamp = line.timestamp
        self.source = source

        let spans = TrackBAnsi.spans(line.text)
        let plain = spans.count == 1 ? spans[0].text : spans.reduce(into: "") { $0 += $1.text }
        self.plain = plain
        self.lowered = plain.lowercased()
        self.links = TrackBLogLinkifier.spans(in: plain)
        self.attributed = Self.render(spans: spans, links: links)
    }

    /// Builds the attributed payload for one line. ANSI is the program's explicit
    /// presentation; standard error is a Docker source channel, not an error severity.
    /// The transcript presents the latter as labelled metadata instead of repainting
    /// every stderr message as a warning.
    ///
    /// Links are baked in here, once, for the same reason everything else is: a row's
    /// `body` must never re-scan text. Where a URL falls inside an ANSI-coloured run the
    /// link presentation wins for those characters — a link that does not look like a
    /// link is a worse outcome than a colour that does not survive, and the underlying
    /// colour is still visible on the rest of the line.
    private static func render(
        spans: [TrackBAnsiSpan], links: [TrackBLinkSpan]
    ) -> AttributedString {
        guard !spans.isEmpty else { return AttributedString("") }

        var result = AttributedString()
        for span in spans {
            var piece = AttributedString(span.text)
            var container = AttributeContainer()

            if let color = span.style.color {
                container.foregroundColor = ContainerLogPalette.ansi(color)
            }
            if span.style.bold {
                container.font = .system(size: 11.5, weight: .bold, design: .monospaced)
            }
            if span.style.dim {
                container.foregroundColor = (container.foregroundColor ?? .primary).opacity(0.55)
            }

            piece.mergeAttributes(container)
            result.append(piece)
        }

        guard !links.isEmpty else { return result }
        let characterCount = result.characters.count
        for link in links {
            // The spans were measured on the plain text, which is these spans joined, so
            // the offsets line up by construction. The bounds check keeps a hypothetical
            // divergence a missing link rather than a crash.
            guard link.offset + link.length <= characterCount else { continue }
            let start = result.index(result.startIndex, offsetByCharacters: link.offset)
            let end = result.index(start, offsetByCharacters: link.length)
            result[start..<end].link = link.url
        }
        return result
    }
}

extension StdStream {

    /// The Docker multiplex channel is source metadata, not a severity classifier.
    var logTranscriptLabel: String {
        switch self {
        case .stdout: return "stdout"
        case .stderr: return "stderr"
        }
    }

    var logTranscriptAccessibilityLabel: String {
        switch self {
        case .stdout: return "Standard output"
        case .stderr: return "Standard error"
        }
    }
}

extension TrackBRenderedLine: Equatable {
    /// Identity is enough: a rendered line is immutable, and comparing two attributed
    /// strings on every diff would cost more than the diff saves.
    static func == (lhs: TrackBRenderedLine, rhs: TrackBRenderedLine) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Store

@MainActor
@Observable
final class TrackBLogStore {

    /// How many lines the scrollback holds.
    static let capacity = 10_000
    /// How many lines to ask the engine for when opening a container.
    static let initialTail = 1_000

    /// The scrollback. A `RandomAccessCollection`, so `ForEach` can read it directly
    /// without an intermediate array copy per frame.
    private(set) var lines = TrackBRingBuffer<TrackBRenderedLine>(capacity: TrackBLogStore.capacity)

    /// The displayed subset of `lines` — non-matching lines removed in filter mode,
    /// hidden services removed in an aggregated document. Recomputed only when the
    /// query, the hidden set, or the content changes; empty and unused when the whole
    /// scrollback is on screen, which is the ordinary case.
    private(set) var filtered: [TrackBRenderedLine] = []

    /// Container IDs whose lines are currently hidden.
    ///
    /// Only the Compose-aggregated document sets this: a per-service show/hide is a
    /// scope on the same document, so it composes with find and filter rather than
    /// being a third parallel mechanism. Hidden lines stay in the scrollback — showing
    /// a service again must not require re-reading it from Docker.
    var hiddenSources: Set<String> = [] {
        didSet {
            guard hiddenSources != oldValue else { return }
            recomputeQuery()
        }
    }

    var hasHiddenSources: Bool { !hiddenSources.isEmpty }

    /// Whether the scrollback is being narrowed at all — by a filter, by a hidden
    /// service, or both.
    private var isNarrowed: Bool { isFiltering || hasHiddenSources }

    /// Whether a line survives the current scope. Hiding is applied before matching, so
    /// a match count never includes a line the person cannot see.
    private func admits(_ line: TrackBRenderedLine) -> Bool {
        if let source = line.source, hiddenSources.contains(source.containerID) { return false }
        guard isFiltering else { return true }
        return TrackBLogFilter.matches(line.lowered, needle: needle)
    }

    /// Whether a *visible* line matches the find query.
    private func isFindMatch(_ line: TrackBRenderedLine) -> Bool {
        guard isFinding else { return false }
        if let source = line.source, hiddenSources.contains(source.containerID) { return false }
        return TrackBLogFilter.matches(line.lowered, needle: needle)
    }

    /// How many lines the current query matches.
    private(set) var matchCount: Int = 0

    /// What the query field does: highlight in place (`.find`) or hide non-matching
    /// lines (`.filter`). Find is the default — a destructive filter presented as the
    /// only search is the competitor defect this store exists to avoid.
    var mode: TrackBLogQueryMode = .find {
        didSet {
            guard mode != oldValue else { return }
            currentMatchID = nil
            recomputeQuery()
        }
    }

    /// Ascending IDs of the lines the find query matches. Empty in filter mode.
    private(set) var matchIDs: [Int] = []

    /// The match Enter/Shift+Enter last stepped to, if it is still in the scrollback.
    private(set) var currentMatchID: Int?

    private(set) var isStreaming = false
    private(set) var errorText: String?

    /// Scroll/follow state, owned here so the toolbar and the scroll view agree.
    var tail = TrackBTailTracker()

    var showsTimestamps = true

    /// The raw filter text. Setting it re-derives the filtered view immediately, so the
    /// count in the toolbar and the rows below it can never be out of step.
    var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            needle = TrackBLogFilter.normalize(query)
            currentMatchID = nil
            recomputeQuery()
        }
    }

    private(set) var needle: String = ""

    /// Whether non-matching lines are currently hidden.
    var isFiltering: Bool { mode == .filter && !needle.isEmpty }

    /// Whether matches are currently highlighted in place.
    var isFinding: Bool { mode == .find && !needle.isEmpty }

    /// Lines waiting for the next flush.
    private var staged: [TrackBRenderedLine] = []
    private var streamTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?

    /// Roughly 80ms. Fast enough that a log looks live, slow enough that a firehose
    /// cannot force more than ~12 layout passes a second.
    private let flushInterval = Duration.milliseconds(80)

    // MARK: Lifecycle

    /// Starts streaming a container's output, replacing whatever was on screen.
    func start(client: DockerClient, containerID: String, follow: Bool = true) {
        stop()
        lines.removeAll()
        filtered.removeAll()
        matchCount = 0
        matchIDs.removeAll()
        currentMatchID = nil
        errorText = nil
        isStreaming = true
        tail.jumpToBottom()

        streamTask = Task { [weak self] in
            do {
                for try await line in client.logs(
                    id: containerID, follow: follow, tail: Self.initialTail)
                {
                    if Task.isCancelled { return }
                    self?.stage(TrackBRenderedLine(line))
                }
                if !Task.isCancelled { self?.finish(error: nil) }
            } catch {
                if !Task.isCancelled { self?.finish(error: error) }
            }
        }

        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.flushInterval ?? .milliseconds(80))
                if Task.isCancelled { return }
                self?.flush()
            }
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        flushTask?.cancel()
        flushTask = nil
        flush()
        isStreaming = false
    }

    /// Fills the scrollback from a fixed list of lines, with no engine involved.
    ///
    /// Previews and deterministic fixture runs can provide a known scrollback without
    /// opening a Docker stream. Lines still go through the same
    /// `TrackBRenderedLine` pipeline as live output, so ANSI parsing, stream-source
    /// metadata, and the filter index are exercised for real rather than faked.
    func seed(_ lines: [LogLine], isStreaming: Bool = true) {
        stop()
        self.lines.removeAll()
        filtered.removeAll()
        matchCount = 0
        matchIDs.removeAll()
        currentMatchID = nil
        errorText = nil
        self.lines.append(contentsOf: lines.map { TrackBRenderedLine($0) })
        recomputeQuery()
        self.isStreaming = isStreaming
        tail.jumpToBottom()
    }

    // MARK: Hosted ingest

    /// Takes over the document for a host that owns its own transport.
    ///
    /// The Compose-aggregated view has to merge several Docker streams before anything
    /// can be shown, so it cannot use `start(client:containerID:)` — but every*thing*
    /// downstream of ingest is identical, and reimplementing find, filter, follow,
    /// eviction and export beside this class would guarantee the two drift. So the
    /// aggregator owns the sockets and the ordering, and this store stays the one
    /// implementation of what a log document *is*.
    func beginHostedStream() {
        stop()
        lines.removeAll()
        filtered.removeAll()
        matchCount = 0
        matchIDs.removeAll()
        currentMatchID = nil
        errorText = nil
        isStreaming = true
        tail.jumpToBottom()
    }

    /// Appends an already-ordered batch. The host has done the batching, so these go
    /// straight into the scrollback rather than through the staging buffer.
    func appendHosted(_ batch: [TrackBRenderedLine]) {
        guard !batch.isEmpty else { return }
        append(batch)
    }

    func finishHostedStream(error: Error?) {
        isStreaming = false
        if let error { errorText = TrackBErrorText.short(error) }
    }

    func clear() {
        lines.removeAll()
        staged.removeAll()
        filtered.removeAll()
        matchCount = 0
        matchIDs.removeAll()
        currentMatchID = nil
        tail.jumpToBottom()
    }

    // MARK: Ingest

    private func stage(_ line: TrackBRenderedLine) {
        staged.append(line)
        // A single burst larger than the whole scrollback can be trimmed before it ever
        // reaches the ring, which keeps the staging array from ballooning on a container
        // that dumps a hundred thousand lines at startup.
        if staged.count > Self.capacity {
            staged.removeFirst(staged.count - Self.capacity)
        }
    }

    private func flush() {
        guard !staged.isEmpty else { return }
        let batch = staged
        staged.removeAll(keepingCapacity: true)
        append(batch)
    }

    /// Adds a batch to the scrollback and brings the derived views up to date.
    private func append(_ batch: [TrackBRenderedLine]) {
        lines.append(contentsOf: batch)

        guard isNarrowed || isFinding else { return }
        // Only the new lines need testing; everything already computed still stands,
        // minus whatever the ring just evicted — eviction forces a full recompute.
        if lines.droppedCount > 0 {
            recomputeQuery()
            return
        }
        if isNarrowed {
            filtered.append(contentsOf: batch.filter(admits))
        }
        if isFinding {
            matchIDs.append(contentsOf: batch.filter(isFindMatch).map(\.id))
            matchCount = matchIDs.count
        } else if isFiltering {
            matchCount = filtered.count
        }
    }

    private func finish(error: Error?) {
        flush()
        isStreaming = false
        if let error { errorText = TrackBErrorText.short(error) }
    }

    private func recomputeQuery() {
        if isNarrowed {
            filtered = lines.elements.filter(admits)
        } else {
            filtered.removeAll(keepingCapacity: true)
        }

        if isFinding {
            matchIDs = lines.elements.filter(isFindMatch).map(\.id)
            matchCount = matchIDs.count
        } else if isFiltering {
            matchIDs.removeAll(keepingCapacity: true)
            matchCount = filtered.count
        } else {
            matchIDs.removeAll(keepingCapacity: true)
            matchCount = 0
        }
        // The ring may have evicted the line the person was parked on, or the query
        // may no longer match it. A stale "current" would highlight the wrong line.
        if let current = currentMatchID, !TrackBMatchNavigator.contains(current, in: matchIDs) {
            currentMatchID = nil
        }
    }

    // MARK: Find navigation

    /// Steps to the next (or previous) matching line and returns its ID so the view
    /// can scroll to it. Wraps at either end, exactly like the system find bar.
    @discardableResult
    func stepMatch(forward: Bool) -> Int? {
        guard isFinding else { return nil }
        currentMatchID = TrackBMatchNavigator.step(
            from: currentMatchID, in: matchIDs, forward: forward)
        return currentMatchID
    }

    /// The "3 of 47" readout. `nil` when find is inactive.
    var matchPositionText: String? {
        guard isFinding else { return nil }
        guard !matchIDs.isEmpty else { return "No matches" }
        if let current = currentMatchID,
            let position = TrackBMatchNavigator.position(of: current, in: matchIDs)
        {
            return "\(position) of \(matchIDs.count)"
        }
        return "\(matchIDs.count) \(matchIDs.count == 1 ? "match" : "matches")"
    }

    // MARK: Output

    /// The lines the view should draw right now.
    var visibleLines: [TrackBRenderedLine] {
        isNarrowed ? filtered : lines.elements
    }

    var lastVisibleID: Int? {
        isNarrowed ? filtered.last?.id : lines.elements.last?.id
    }

    /// Plain text of everything currently visible, for copy and export.
    ///
    /// An aggregated document labels every line with its service: pasting a merged
    /// transcript into an issue without saying which service said what would be worse
    /// than useless.
    func exportText() -> String {
        TrackBLogExport.text(
            visibleLines,
            timestamp: \.timestamp,
            stream: \.stream,
            body: \.plain,
            includeTimestamps: showsTimestamps,
            service: { $0.source?.service })
    }

    /// A frozen, provenance-bearing document of a Compose-aggregated transcript.
    func exportProjectDocument(
        project: String,
        includedServices: [String],
        hiddenServices: [String],
        unavailableServices: [String],
        capturedAt: Date = Date()
    ) -> TrackBLogExport.Document {
        TrackBLogExport.projectDocument(
            project: project,
            includedServices: includedServices,
            hiddenServices: hiddenServices,
            unavailableServices: unavailableServices,
            lines: visibleLines,
            bufferedLineCount: lines.elements.count,
            droppedEarlierLineCount: lines.droppedCount,
            initialTail: Self.initialTail,
            searchQuery: isFiltering ? query : nil,
            isStreaming: isStreaming,
            capturedAt: capturedAt,
            timestamp: \.timestamp,
            stream: \.stream,
            body: \.plain,
            service: { $0.source?.service })
    }

    /// A frozen, provenance-bearing document of the visible client-side transcript.
    ///
    /// This deliberately consumes only retained memory. Export never reaches back to
    /// Docker for a supposed "complete" transcript, and a search remains a search
    /// subset rather than an unlabelled full-history download.
    func exportDocument(
        containerName: String,
        containerID: String,
        capturedAt: Date = Date()
    ) -> TrackBLogExport.Document {
        TrackBLogExport.document(
            containerName: containerName,
            containerID: containerID,
            lines: visibleLines,
            bufferedLineCount: lines.elements.count,
            droppedEarlierLineCount: lines.droppedCount,
            initialTail: Self.initialTail,
            searchQuery: isFiltering ? query : nil,
            isStreaming: isStreaming,
            capturedAt: capturedAt,
            timestamp: \.timestamp,
            stream: \.stream,
            body: \.plain)
    }
}
