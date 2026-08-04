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
    @State private var currentStandardErrorID: Int?
    @State private var scrollTarget: Int?
    @State private var pendingExport: TrackBLogExport.Document?
    @State private var exportError: String?

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
        .onAppear { if streamsLive { start() } }
        .onDisappear { if streamsLive { store.stop() } }
        .onChange(of: container.isRunning) { _, isRunning in
            if streamsLive, isRunning, !store.isStreaming { start() }
        }
        .alert(
            "Couldn’t Save Log Transcript",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } })
        ) {
            Button("Choose Another Location…") {
                guard let pendingExport else { return }
                exportError = nil
                chooseExportDestination(for: pendingExport)
            }
            Button("Cancel", role: .cancel) {
                exportError = nil
                pendingExport = nil
            }
        } message: {
            Text(exportError ?? "")
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            DocumentSearchField(text: $store.query, prompt: "Filter lines")
            Text(lineCount)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            streamStatus

            // The log document's commands live with the log document. In the window
            // toolbar they appeared and disappeared with the inspector tab, churning
            // the route's toolbar on every tab switch.
            logOptionsMenu
        }
        .padding(8)
    }

    private var lineCount: String {
        let visible = store.visibleLines.count
        if store.isFiltering {
            return "\(visible) of \(store.lines.count) \(store.lines.count == 1 ? "line" : "lines")"
        }
        return "\(visible) \(visible == 1 ? "line" : "lines")"
    }

    @ViewBuilder
    private var streamStatus: some View {
        if store.isStreaming {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Streaming container output")
                .help("Streaming container output")
        } else if let errorText = store.errorText {
            Label("Stream interrupted", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Log stream interrupted: \(errorText)")
                .help(errorText)
        }
    }

    private func start() {
        store.start(client: client, containerID: container.id)
    }

    // Follow, timestamps, error navigation, and export are all commands for the
    // selected log document. They live in the document's own bar rather than the
    // window toolbar, which must not mutate when the inspector switches tabs.
    private var logOptionsMenu: some View {
        Menu {
                Toggle("Follow Output", isOn: Binding(
                    get: { store.tail.followEnabled },
                    set: { store.tail.setFollow($0) }))
                    .accessibilityLabel("Follow output")
                    .help("Follow new output")

                Toggle("Show Timestamps", isOn: $store.showsTimestamps)
                    .accessibilityLabel("Show timestamps")
                    .help("Show timestamps")

                Button("Jump to Next Standard Error Line", systemImage: "arrow.down.to.line") {
                    jumpToNextStandardErrorLine()
                }
                .accessibilityLabel("Jump to next standard error line")
                .help("Jump to the next line written to standard error")
                .disabled(!hasStandardErrorLines)

                Divider()

                Button(copied ? "Copied" : "Copy Visible Lines", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    copyVisibleLines()
                }
                .accessibilityLabel("Copy visible lines")
                .help("Copy visible lines")

                Button("Save Visible Transcript…", systemImage: "square.and.arrow.down") {
                    export()
                }
                .accessibilityLabel("Save visible log transcript")
                .help("Save the currently visible bounded log transcript")
                .disabled(store.visibleLines.isEmpty)

                Divider()

                Button("Clear Scrollback") {
                    store.clear()
                }
                .accessibilityLabel("Clear scrollback")
                .help("Clear scrollback")
        } label: {
            Label("Log options", systemImage: "text.alignleft")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Log options")
        .help("Follow, display, and export options for this log")
    }

    private var hasStandardErrorLines: Bool {
        store.visibleLines.contains { $0.stream == .stderr }
    }

    private func jumpToNextStandardErrorLine() {
        let standardErrorLines = store.visibleLines.filter { $0.stream == .stderr }
        guard !standardErrorLines.isEmpty else { return }
        if let current = currentStandardErrorID,
           let index = standardErrorLines.firstIndex(where: { $0.id == current })
        {
            currentStandardErrorID = standardErrorLines[(index + 1) % standardErrorLines.count].id
        } else {
            currentStandardErrorID = standardErrorLines[0].id
        }
        scrollTarget = currentStandardErrorID
    }

    private func copyVisibleLines() {
        MorbPasteboard.copy(store.exportText())
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            copied = false
        }
    }

    private var logSurface: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.lines.hasDropped { droppedMarker }
                    ForEach(store.visibleLines) { line in
                        TrackBLogRow(
                            line: line,
                            showsTimestamp: store.showsTimestamps,
                            isCurrentStandardError: line.id == currentStandardErrorID)
                        .id(line.id)
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
            ProgressView("Loading Logs")
        } else if let errorText = store.errorText {
            ContentUnavailableView {
                Label("Log Stream Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorText)
            }
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
        let document = store.exportDocument(
            containerName: container.displayName,
            containerID: container.id)
        guard document.lineCount > 0 else { return }
        chooseExportDestination(for: document)
    }

    /// `NSSavePanel` owns location selection and its standard replacement prompt. The
    /// document is frozen before the panel opens, so a running stream cannot alter what
    /// the person reviewed as the current visible transcript while choosing a location.
    @MainActor
    private func chooseExportDestination(for document: TrackBLogExport.Document) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = TrackBLogExport.suggestedFilename(container: container.displayName)
        panel.allowedContentTypes = [UTType.log, UTType.plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.message = document.panelMessage
        panel.prompt = "Save"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try document.data.write(to: url, options: .atomic)
            pendingExport = nil
        } catch {
            pendingExport = document
            exportError = "Morbstack could not save the selected transcript to \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

struct TrackBLogRow: View {

    let line: TrackBRenderedLine
    let showsTimestamp: Bool
    var isCurrentStandardError: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if showsTimestamp {
                Text(line.timestamp.map(Formatters.logTime) ?? "—")
                    .font(.caption.monospaced())
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(width: 78, alignment: .leading)
                    .accessibilityLabel(line.timestamp.map(Formatters.absoluteDate) ?? "No timestamp")
            }

            Text(line.stream.logTranscriptLabel)
                .font(.caption2.monospaced())
                .foregroundStyle(isCurrentStandardError ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: 42, alignment: .leading)
                .accessibilityLabel(line.stream.logTranscriptAccessibilityLabel)

            Text(line.attributed)
                .font(.body.monospaced().weight(isCurrentStandardError ? .medium : .regular))
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 1)
    }
}
