// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// A log is a document, not a dashboard card.  This view keeps the terminal-specific
// behaviour (streaming, filtering, tailing, and export) while relying on normal macOS
// text fields, toolbar controls, document background colours, and empty states.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContainerLogsTab: View {

    let container: ContainerSummary
    let client: DockerClient

    @State private var store: TrackBLogStore
    @State private var copied = false
    @State private var viewportHeight: CGFloat = 0
    @State private var currentErrorID: Int?
    @State private var scrollTarget: Int?

    private let streamsLive: Bool
    private let bottomAnchor = "trackb.log.bottom"

    init(container: ContainerSummary, client: DockerClient, preloadedStore: TrackBLogStore? = nil) {
        self.container = container
        self.client = client
        self.streamsLive = preloadedStore == nil
        _store = State(initialValue: preloadedStore ?? TrackBLogStore())
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            logSurface
        }
        .toolbar { toolbarContent }
        .onAppear { if streamsLive { start() } }
        .onDisappear { if streamsLive { store.stop() } }
        .onChange(of: container.isRunning) { _, isRunning in
            if streamsLive, isRunning, !store.isStreaming { start() }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            DocumentSearchField(text: $store.query, prompt: "Filter lines")
            Text(lineCount)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(8)
    }

    private var lineCount: String {
        if store.isFiltering {
            return "\(store.visibleLines.count) of \(store.lines.count) lines"
        }
        return "\(store.lines.count) lines"
    }

    private func start() {
        store.start(client: client, containerID: container.id)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: Binding(
                get: { store.tail.followEnabled },
                set: { store.tail.setFollow($0) })
            ) {
                Image(systemName: "arrow.down.to.line")
            }
            .toggleStyle(.button)
            .accessibilityLabel("Follow output")
            .help("Follow new output")

            Toggle(isOn: $store.showsTimestamps) {
                Image(systemName: "clock")
            }
            .toggleStyle(.button)
            .accessibilityLabel("Show timestamps")
            .help("Show timestamps")

            Button { jumpToNextError() } label: {
                Image(systemName: "exclamationmark.triangle")
            }
            .accessibilityLabel("Jump to next error")
            .help("Jump to next error")
            .disabled(!hasErrors)
        }

        ToolbarItem(id: "logs.clear", placement: .secondaryAction) {
            Button { store.clear() } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Clear scrollback")
            .help("Clear scrollback")
        }

        ToolbarItem(id: "logs.copy", placement: .secondaryAction) {
            Button {
                MorbPasteboard.copy(store.exportText())
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .accessibilityLabel("Copy visible lines")
            .help("Copy visible lines")
        }

        ToolbarItem(id: "logs.export", placement: .secondaryAction) {
            Button(action: export) {
                Image(systemName: "square.and.arrow.down")
            }
            .accessibilityLabel("Export visible lines")
            .help("Export visible lines")
        }
    }

    private var hasErrors: Bool {
        store.visibleLines.contains { $0.stream == .stderr }
    }

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

    private var logSurface: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.lines.hasDropped { droppedMarker }
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
                .padding(.vertical, 6)
                .frame(
                    maxWidth: .infinity,
                    minHeight: viewportHeight > 0 ? viewportHeight : nil,
                    alignment: .topLeading)
            }
            .defaultScrollAnchor(.bottom)
            .background(Color(nsColor: .textBackgroundColor))
            .onScrollGeometryChange(for: Double.self) { geometry in
                let contentBottom = geometry.contentSize.height + geometry.contentInsets.bottom
                return max(0, contentBottom - geometry.contentOffset.y - geometry.containerSize.height)
            } action: { _, distance in
                store.tail.observe(distanceFromBottom: distance)
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, height in
                if abs(height - viewportHeight) > 0.5 { viewportHeight = height }
            }
            .onChange(of: store.visibleLines.count) { _, _ in
                guard store.tail.shouldAutoScroll else { return }
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if store.tail.showsJumpToBottom, !store.visibleLines.isEmpty {
                    Button("Jump to Newest", systemImage: "arrow.down.to.line") {
                        store.tail.jumpToBottom()
                        proxy.scrollTo(bottomAnchor, anchor: .bottom)
                    }
                    .buttonStyle(.bordered)
                    .padding()
                }
            }
            .overlay {
                if store.visibleLines.isEmpty { emptyOverlay }
            }
        }
    }

    private var numberedVisibleLines: [(line: TrackBRenderedLine, showsTimestamp: Bool)] {
        var previousTimestamp: Date?
        return store.visibleLines.map { line in
            let isBlank = line.plain.trimmingCharacters(in: .whitespaces).isEmpty
            let repeatsPrevious = line.timestamp != nil && line.timestamp == previousTimestamp
            let shows = !isBlank && !repeatsPrevious
            previousTimestamp = line.timestamp
            return (line, shows)
        }
    }

    private var droppedMarker: some View {
        Label(
            "\(store.lines.droppedCount) earlier lines were dropped. Showing the most recent \(TrackBLogStore.capacity).",
            systemImage: "arrow.up.to.line.compact")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(8)
    }

    @ViewBuilder
    private var emptyOverlay: some View {
        if store.isFiltering {
            ContentUnavailableView.search(text: store.query)
        } else if store.isStreaming {
            ProgressView()
        } else {
            ContentUnavailableView {
                Label("No Output", systemImage: "text.alignleft")
            } description: {
                Text(container.isRunning
                    ? "This container has not written anything to standard output or standard error yet."
                    : "This container is not running and produced no output.")
            }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = TrackBLogExport.suggestedFilename(container: container.displayName)
        panel.allowedContentTypes = [UTType.log, UTType.plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.message = "Export the lines currently shown."

        let text = store.exportText()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

struct TrackBLogRow: View {

    let line: TrackBRenderedLine
    let showsTimestamp: Bool
    var isCurrentError: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(showsTimestamp ? (line.timestamp.map(Formatters.logTime) ?? "") : "")
                .font(.caption.monospaced())
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: 78, alignment: .leading)

            if line.stream == .stderr {
                Image(systemName: isCurrentError
                    ? "exclamationmark.triangle.fill"
                    : "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(isCurrentError ? .primary : .secondary)
                    .accessibilityHidden(true)
            }

            Text(line.attributed)
                .font(.body.monospaced().weight(isCurrentError ? .semibold : .regular))
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 1)
    }
}
