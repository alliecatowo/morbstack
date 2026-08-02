// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// LOGS.
//
// The view is deliberately thin: `TrackBLogStore` owns the scrollback, the filtering
// and the batching, and `TrackBTailTracker` owns the follow logic. What is left here is
// the part that genuinely needs a view — reading the scroll geometry, and putting the
// scroll view back at the bottom when it should be.
//
// Two things keep it fast with ten thousand lines on screen:
//
//   * `LazyVStack` only realises the rows in the viewport, and each row's content is a
//     pre-built `AttributedString`, so realising one costs a layout and nothing else;
//   * the auto-scroll fires on the line *count* changing, never on every append, so a
//     burst of four hundred lines produces one scroll instead of four hundred.
//
// Follow / Times / the filter field / the line count / clear / copy / export all live in
// a real `.toolbar` now, not a hand-drawn bar above the viewport — see
// `ContainersRootView`'s header note about the offscreen screenshot harness not being
// able to composite toolbar content; the same applies here. The log surface itself is
// flat `Theme.contentBackground` at every size, never a material — see
// `docs/design/IDENTITY.md` §5.1: ten thousand lines of monospaced text over a
// live-blurring backdrop is unreadable, and it re-composites the blur on every scroll
// tick.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContainerLogsTab: View {

    let container: ContainerSummary
    let client: DockerClient

    @State private var store: TrackBLogStore
    @State private var copied = false
    /// The log surface's own height, fed back so short scrollbacks can top-align.
    @State private var viewportHeight: CGFloat = 0
    @State private var currentErrorID: Int?

    /// `false` when the store was handed in already full, in which case this view must
    /// not open (or close) a stream of its own.
    private let streamsLive: Bool

    /// - Parameter preloadedStore: a store that is already full. Supplied by SwiftUI
    ///   previews and by the offscreen screenshot harness, where `onAppear` never runs
    ///   and `start()` would therefore never be called. `nil` — the app's own path —
    ///   builds an empty store and streams into it as usual.
    init(container: ContainerSummary, client: DockerClient, preloadedStore: TrackBLogStore? = nil) {
        self.container = container
        self.client = client
        self.streamsLive = preloadedStore == nil
        _store = State(initialValue: preloadedStore ?? TrackBLogStore())
    }

    /// The invisible row at the very end that `scrollTo` aims at. Anchoring on the last
    /// *line* instead would scroll it flush with the bottom edge and hide the padding,
    /// which reads as a clipped final line.
    private let bottomAnchor = "trackb.log.bottom"

    var body: some View {
        logSurface
            .background(Theme.contentBackground)
            .toolbar { toolbarContent }
            .searchable(text: $store.query, placement: .toolbar, prompt: "Filter lines")
            .onAppear { if streamsLive { start() } }
            .onDisappear { if streamsLive { store.stop() } }
            .onChange(of: container.isRunning) { _, isRunning in
                // A container that was restarted has a brand new stream; the old one
                // ended when the process did.
                if streamsLive, isRunning, !store.isStreaming { start() }
            }
    }

    private func start() {
        store.start(client: client, containerID: container.id)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(id: "follow", placement: MorbToolbarGroup.navigation) {
            Toggle(isOn: Binding(
                get: { store.tail.followEnabled },
                set: { store.tail.setFollow($0) })
            ) {
                Label("Follow", systemImage: "arrow.down.to.line")
            }
            .toggleStyle(.button)
            .tint(Theme.brand)
            .help("Keep scrolling as new output arrives")
        }
        ToolbarItem(id: "times", placement: MorbToolbarGroup.navigation) {
            Toggle(isOn: $store.showsTimestamps) {
                Label("Times", systemImage: "clock")
            }
            .toggleStyle(.button)
            .tint(Theme.brand)
            .help("Show the engine's timestamp for each line")
        }
        MorbToolbarStatus(id: "status") { statusPill }
        ToolbarItem(id: "next-error", placement: MorbToolbarGroup.actions) {
            MorbIconButton("exclamationmark.triangle", help: "Jump to next error", action: jumpToNextError)
                .disabled(!hasErrors)
        }
        ToolbarItem(id: "clear", placement: MorbToolbarGroup.overflow) {
            MorbIconButton("trash", help: "Clear the scrollback") { store.clear() }
        }
        ToolbarItem(id: "copy", placement: MorbToolbarGroup.overflow) {
            MorbIconButton(copied ? "checkmark" : "doc.on.doc", help: "Copy visible lines") {
                TrackBClipboard.copy(store.exportText())
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    copied = false
                }
            }
        }
        ToolbarItem(id: "export", placement: MorbToolbarGroup.overflow) {
            MorbIconButton("square.and.arrow.down", help: "Export as .log", action: export)
        }
    }

    /// The one place the viewer admits what it is doing: streaming, finished, failed, or
    /// holding a truncated scrollback.
    @ViewBuilder
    private var statusPill: some View {
        if let error = store.errorText {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Theme.statusDegraded)
                .lineLimit(1)
                .help(error)
        } else if store.isStreaming {
            HStack(spacing: Theme.space2) {
                MorbStatusDot(tone: .running)
                MorbNumber("\(store.lines.count) lines")
            }
            .help("Following live output")
        } else {
            MorbNumber("\(store.lines.count) lines · ended", tone: Color.secondary)
        }
    }

    // MARK: Surface

    private var hasErrors: Bool { store.visibleLines.contains { $0.stream == .stderr } }

    private func jumpToNextError() {
        let errors = store.visibleLines.filter { $0.stream == .stderr }
        guard !errors.isEmpty else { return }
        if let current = currentErrorID, let index = errors.firstIndex(where: { $0.id == current }) {
            currentErrorID = errors[(index + 1) % errors.count].id
        } else {
            currentErrorID = errors[0].id
        }
        scrollTarget = currentErrorID
    }

    @State private var scrollTarget: Int?

    private var logSurface: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.lines.hasDropped {
                        droppedMarker
                    }
                    ForEach(Array(numberedVisibleLines), id: \.line.id) { entry in
                        TrackBLogRow(
                            line: entry.line,
                            showsTimestamp: store.showsTimestamps && entry.showsTimestamp,
                            isCurrentError: entry.line.id == currentErrorID)
                            .id(entry.line.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .padding(.vertical, Theme.space2)
                // Fill the viewport, top-aligned, whenever the lines do not.
                //
                // `defaultScrollAnchor(.bottom)` is right for a log — new output belongs
                // at the bottom edge — but it also pins *short* content there, so
                // filtering four hundred lines down to twenty leaves a band of empty
                // surface above the first line and the pane looks broken. Growing the
                // content box to the viewport height puts the shortfall below the last
                // line instead, where a terminal puts it. Once the lines overflow, the
                // minimum stops binding and the bottom anchor behaves exactly as before.
                .frame(
                    maxWidth: .infinity,
                    minHeight: viewportHeight > 0 ? viewportHeight : nil,
                    alignment: .topLeading)
            }
            .defaultScrollAnchor(.bottom)
            .morbScrollEdge(.hard, for: .top)
            .onScrollGeometryChange(for: Double.self) { geometry in
                let contentBottom = geometry.contentSize.height + geometry.contentInsets.bottom
                return max(0, contentBottom - geometry.contentOffset.y - geometry.containerSize.height)
            } action: { _, distance in
                store.tail.observe(distanceFromBottom: distance)
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, height in
                // Guarded: writing the height back into a frame that helps determine it
                // is a loop unless the comparison has slack.
                if abs(height - viewportHeight) > 0.5 { viewportHeight = height }
            }
            // Keyed on the count rather than on the collection: comparing ten thousand
            // lines for equality on every append would cost more than the scroll.
            .onChange(of: store.visibleLines.count) { _, _ in
                guard store.tail.shouldAutoScroll else { return }
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(Theme.springSubtle) {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
            .background(Theme.contentBackground)
            .overlay(alignment: .bottomTrailing) {
                if store.tail.showsJumpToBottom, !store.visibleLines.isEmpty {
                    jumpButton(proxy)
                }
            }
            .overlay {
                if store.visibleLines.isEmpty { emptyOverlay }
            }
        }
    }

    /// Pairs each visible line with whether its timestamp should draw.
    ///
    /// Suppressed on a blank continuation line and on a run of lines that share the
    /// previous line's timestamp — a stack trace logged inside one millisecond does not
    /// need `08:44:05.032` repeated down every row of it.
    private var numberedVisibleLines: [(line: TrackBRenderedLine, showsTimestamp: Bool)] {
        let lines = store.visibleLines
        var previousTimestamp: Date?
        return lines.map { line in
            let isBlank = line.plain.trimmingCharacters(in: .whitespaces).isEmpty
            let repeatsPrevious = line.timestamp != nil && line.timestamp == previousTimestamp
            let shows = !isBlank && !repeatsPrevious
            previousTimestamp = line.timestamp
            return (line, shows)
        }
    }

    private var droppedMarker: some View {
        HStack(spacing: Theme.space2) {
            Image(systemName: "arrow.up.to.line.compact").font(.system(size: 9))
            Text("\(store.lines.droppedCount) earlier lines dropped — the viewer keeps the most recent \(TrackBLogStore.capacity).")
                .font(.caption2)
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, Theme.space4)
        .padding(.vertical, Theme.space3)
    }

    private func jumpButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            store.tail.jumpToBottom()
            withAnimation(Theme.fade) {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        } label: {
            Label("Jump to newest", systemImage: "arrow.down.to.line")
                .font(.caption.weight(.medium))
        }
        .morbButton(.floating)
        .padding(Theme.space4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .morbAnimation(.snappy, value: store.tail.showsJumpToBottom)
    }

    @ViewBuilder
    private var emptyOverlay: some View {
        if store.isFiltering {
            MorbNoMatches(query: store.query)
        } else if store.isStreaming {
            MorbLoading(label: "Waiting for output…")
        } else {
            MorbEmptyState(
                "No output",
                systemImage: "text.alignleft",
                description: container.isRunning
                    ? "This container has not written anything to stdout or stderr yet."
                    : "This container is not running and produced no output.")
        }
    }

    // MARK: Export

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = TrackBLogExport.suggestedFilename(
            container: container.displayName)
        panel.allowedContentTypes = [UTType.log, UTType.plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.message = "Export the lines currently shown."

        // The text is snapshotted before the panel runs so that a container still
        // logging cannot change what gets written half way through the save.
        let text = store.exportText()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Row

/// One line.
///
/// Everything expensive already happened in `TrackBRenderedLine.init`: this hands
/// SwiftUI a finished `AttributedString` and does no string work at all.
struct TrackBLogRow: View {

    let line: TrackBRenderedLine
    let showsTimestamp: Bool
    var isCurrentError: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.space3) {
            // Wide enough for `HH:MM:SS.mmm` with a point to spare, suppressed rather
            // than blank on a line that repeats the previous one's timestamp — a blank
            // 78pt gutter still reads as a gutter, an empty one does not.
            Group {
                if showsTimestamp {
                    Text(line.timestamp.map(Formatters.logTime) ?? "")
                } else {
                    Text("")
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .frame(width: 78, alignment: .leading)

            Text(line.attributed)
                .font(.system(size: 11.5, design: .monospaced))
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.space4)
        .padding(.vertical, 1)
        .background(errorBackground)
        .overlay(alignment: .leading) { errorRule }
    }

    @ViewBuilder
    private var errorRule: some View {
        if line.stream == .stderr {
            Rectangle()
                .fill(isCurrentError ? Theme.statusBad : Theme.statusBad.opacity(0.5))
                .frame(width: 3)
        }
    }

    private var errorBackground: Color {
        guard line.stream == .stderr else { return .clear }
        return Theme.statusBad.opacity(isCurrentError ? Theme.chipAlpha : Theme.chipAlpha * 0.4)
    }
}
