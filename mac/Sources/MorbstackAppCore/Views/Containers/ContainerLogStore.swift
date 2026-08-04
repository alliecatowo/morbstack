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

    init(_ line: LogLine) {
        self.id = line.id
        self.stream = line.stream
        self.timestamp = line.timestamp

        let spans = TrackBAnsi.spans(line.text)
        self.plain = spans.count == 1 ? spans[0].text : spans.reduce(into: "") { $0 += $1.text }
        self.lowered = plain.lowercased()
        self.attributed = Self.render(spans: spans)
    }

    /// Builds the attributed payload for one line. ANSI is the program's explicit
    /// presentation; standard error is a Docker source channel, not an error severity.
    /// The transcript presents the latter as labelled metadata instead of repainting
    /// every stderr message as a warning.
    private static func render(spans: [TrackBAnsiSpan]) -> AttributedString {
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

    /// The filtered view of `lines`, recomputed only when the query or the content
    /// changes. Empty and unused when no filter is active.
    private(set) var filtered: [TrackBRenderedLine] = []

    /// How many lines the current query matches.
    private(set) var matchCount: Int = 0

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
            recomputeFilter()
        }
    }

    private(set) var needle: String = ""

    var isFiltering: Bool { !needle.isEmpty }

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
        errorText = nil
        self.lines.append(contentsOf: lines.map(TrackBRenderedLine.init))
        recomputeFilter()
        self.isStreaming = isStreaming
        tail.jumpToBottom()
    }

    func clear() {
        lines.removeAll()
        staged.removeAll()
        filtered.removeAll()
        matchCount = 0
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
        lines.append(contentsOf: batch)

        guard isFiltering else { return }
        // Only the new lines need testing; everything already in `filtered` still
        // matches, minus whatever the ring just evicted.
        if lines.droppedCount > 0 {
            recomputeFilter()
        } else {
            let additions = TrackBLogFilter.filter(batch, needle: needle, lowered: \.lowered)
            filtered.append(contentsOf: additions)
            matchCount = filtered.count
        }
    }

    private func finish(error: Error?) {
        flush()
        isStreaming = false
        if let error { errorText = TrackBErrorText.short(error) }
    }

    private func recomputeFilter() {
        guard isFiltering else {
            filtered.removeAll(keepingCapacity: true)
            matchCount = 0
            return
        }
        filtered = TrackBLogFilter.filter(lines, needle: needle, lowered: \.lowered)
        matchCount = filtered.count
    }

    // MARK: Output

    /// The lines the view should draw right now.
    var visibleLines: [TrackBRenderedLine] {
        isFiltering ? filtered : lines.elements
    }

    var lastVisibleID: Int? {
        isFiltering ? filtered.last?.id : lines.elements.last?.id
    }

    /// Plain text of everything currently visible, for copy and export.
    func exportText() -> String {
        TrackBLogExport.text(
            visibleLines,
            timestamp: \.timestamp,
            stream: \.stream,
            body: \.plain,
            includeTimestamps: showsTimestamps)
    }
}
