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
    @FocusState private var filterFocused: Bool

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
        VStack(spacing: 0) {
            toolbar
            Divider()
            logSurface
        }
        .onAppear { if streamsLive { start() } }
        .onDisappear { if streamsLive { store.stop() } }
        .onChange(of: container.isRunning) { _, isRunning in
            // A container that was restarted has a brand new stream; the old one ended
            // when the process did.
            if streamsLive, isRunning, !store.isStreaming { start() }
        }
    }

    private func start() {
        store.start(client: client, containerID: container.id)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { store.tail.followEnabled },
                set: { store.tail.setFollow($0) })
            ) {
                Label("Follow", systemImage: "arrow.down.to.line")
                    .font(.caption)
            }
            .toggleStyle(.button)
            .controlSize(.small)
            // An "on" button toggle is filled with the accent by AppKit, so without a
            // tint these two are the loudest thing in the window on any Mac whose accent
            // is not blue.
            .tint(Theme.accent)
            .help("Keep scrolling as new output arrives")

            Toggle(isOn: $store.showsTimestamps) {
                Label("Times", systemImage: "clock")
                    .font(.caption)
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .tint(Theme.accent)
            .help("Show the engine's timestamp for each line")

            TrackBSearchField(
                text: $store.query,
                prompt: "Filter lines",
                width: 200,
                caption: matchCaption,
                externalFocus: $filterFocused)

            Spacer(minLength: 8)

            statusPill

            TrackBIconButton(symbol: "trash", help: "Clear the scrollback", tint: .secondary) {
                store.clear()
            }
            TrackBIconButton(
                symbol: copied ? "checkmark" : "doc.on.doc",
                help: "Copy visible lines",
                tint: copied ? .green : Theme.accent
            ) {
                TrackBClipboard.copy(store.exportText())
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    copied = false
                }
            }
            TrackBIconButton(
                symbol: "square.and.arrow.down",
                help: "Export as .log",
                tint: Theme.accent,
                action: export)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background {
            Button("Filter logs") { filterFocused = true }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    private var matchCaption: String? {
        store.isFiltering ? "\(store.matchCount)" : nil
    }

    /// The one place the viewer admits what it is doing: streaming, finished, failed, or
    /// holding a truncated scrollback.
    @ViewBuilder
    private var statusPill: some View {
        if let error = store.errorText {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(1)
                .help(error)
        } else if store.isStreaming {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 5, height: 5)
                Text("\(store.lines.count) lines")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .help("Following live output")
        } else {
            Text("\(store.lines.count) lines · ended")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Surface

    private var logSurface: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.lines.hasDropped {
                        droppedMarker
                    }
                    ForEach(store.visibleLines) { line in
                        TrackBLogRow(line: line, showsTimestamp: store.showsTimestamps)
                            .id(line.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .padding(.vertical, 6)
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
            .background(TrackBPalette.logSurface)
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

    private var droppedMarker: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.to.line.compact").font(.system(size: 9))
            Text("\(store.lines.droppedCount) earlier lines dropped — the viewer keeps the most recent \(TrackBLogStore.capacity).")
                .font(.caption2)
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func jumpButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            store.tail.jumpToBottom()
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        } label: {
            Label("Jump to newest", systemImage: "arrow.down.to.line")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .padding(14)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: store.tail.showsJumpToBottom)
    }

    @ViewBuilder
    private var emptyOverlay: some View {
        if store.isFiltering {
            TrackBEmptyState(
                symbols: ["line.3.horizontal.decrease"],
                title: "No matching lines",
                message: "Nothing in the last \(store.lines.count) lines contains “\(store.query)”.",
                snippet: nil
            ) {
                Button("Clear filter") { store.query = "" }
                    .buttonStyle(.borderless)
            }
        } else if store.isStreaming {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for output…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            TrackBEmptyState(
                symbols: ["text.alignleft"],
                title: "No output",
                message: container.isRunning
                    ? "This container has not written anything to stdout or stderr yet."
                    : "This container is not running and produced no output.",
                snippet: nil
            ) {
                EmptyView()
            }
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

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if showsTimestamp {
                // Wide enough for `HH:MM:SS.mmm` with a point to spare. It was 74, which
                // is within a hair of the string's own width at this size, and the last
                // digit of every timestamp wrapped onto a second line — a ragged column
                // of stray milliseconds down the gutter.
                Text(line.timestamp.map(Formatters.logTime) ?? "")
                    .font(.system(size: 10, design: .monospaced).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(width: 84, alignment: .leading)
            }
            Text(line.attributed)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
        .background(line.stream == .stderr ? TrackBPalette.stderrWash : Color.clear)
    }
}
