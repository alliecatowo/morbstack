// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// One log document, drawn once.
//
// A log is a document, not a dashboard card: normal macOS text fields, toolbar controls,
// document background colours and empty states, with only the terminal-specific
// behaviour — streaming, find/filter, tailing, wrap, export — added on top.
//
// This view exists in its own file because there are now two log documents in the app:
// one container's transcript (`ContainerLogsTab`) and a Compose project's merged
// transcript (`ComposeProjectLogsView`). They differ in where their lines come from and
// in nothing else, so they share this. The alternative — a second copy of the query bar,
// the scroll surface, the find navigation, the follow behaviour and the export panel —
// would guarantee the two drift, and the first thing to drift would be the
// context-preserving search that exists specifically because a competitor got it wrong.
//
// Every identifier is built from a `scope` string, so the container document keeps its
// existing `containers.logs.*` names verbatim (the XCUITest suite queries them) while
// the project document gets `stacks.projectLogs.*`, per
// docs/design/ACCESSIBILITY-IDENTIFIERS.md.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Document

struct TrackBLogDocumentView<Options: View, Empty: View>: View {

    let store: TrackBLogStore
    /// Identifier scope: `containers.logs` or `stacks.projectLogs`.
    let scope: String
    /// Whether rows carry a service column. Only an aggregated document has one.
    var showsSourceColumn: Bool = false
    /// Suggested `NSSavePanel` filename for "Save Visible Transcript…".
    let exportFilename: String
    /// Freezes the visible transcript into a provenance-bearing document.
    let makeExportDocument: () -> TrackBLogExport.Document
    /// Document-specific entries at the top of the options menu.
    @ViewBuilder var additionalOptions: () -> Options
    /// What fills the surface when there is nothing to show.
    @ViewBuilder var emptyOverlay: () -> Empty

    /// Wrap is a reading preference, not document state, so it is remembered across
    /// launches and shared by both log documents — a person who wants long lines wrapped
    /// wants that everywhere, and OrbStack #536 is a request for the setting, not for a
    /// per-window mode.
    @AppStorage(TrackDPreferences.logWrapsLines) private var wrapsLines = true

    @State private var copied = false
    @State private var viewportHeight: CGFloat = 0
    @State private var currentStandardErrorID: Int?
    @State private var scrollRequest: ScrollRequest?
    @State private var pendingExport: TrackBLogExport.Document?
    @State private var exportError: String?
    @State private var searchFocusRequests = 0
    @State private var linkConfirmation: URL?

    private let bottomAnchor = "trackb.log.bottom"

    /// A scroll-to-line request. The generation exists because two consecutive
    /// requests for the *same* line — Enter on a log with one match, or the stderr
    /// jump wrapping over a single stderr line — are still two requests; an `Int?`
    /// alone would coalesce them into no `onChange` at all.
    private struct ScrollRequest: Equatable {
        var lineID: Int
        var generation: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            queryBar
            Divider()
            logSurface
        }
        // Log text is untrusted container output, so this document does not hand a URL
        // straight to the system. See `TrackBLogLinkifier`: only literal http/https
        // spans are ever linked, and anything that resolves onto this Mac or this LAN
        // is confirmed by name first.
        .environment(
            \.openURL,
            OpenURLAction { url in
                switch TrackBLogLinkifier.disposition(for: url) {
                case .open:
                    return .systemAction
                case .confirmLocal:
                    linkConfirmation = url
                    return .handled
                case .reject:
                    return .discarded
                }
            }
        )
        .confirmationDialog(
            "Open This Address in Your Browser?",
            isPresented: Binding(
                get: { linkConfirmation != nil },
                set: { if !$0 { linkConfirmation = nil } }),
            titleVisibility: .visible,
            presenting: linkConfirmation
        ) { url in
            Button("Open") {
                linkConfirmation = nil
                NSWorkspace.shared.open(url)
            }
            Button("Copy Address") {
                MorbPasteboard.copy(url.absoluteString)
                linkConfirmation = nil
            }
            Button("Cancel", role: .cancel) { linkConfirmation = nil }
        } message: { url in
            Text(
                "\(url.absoluteString)\n\nThis address is on this Mac or your local network, "
                    + "and the link came from a container’s own output. Opening it sends a "
                    + "request to that service.")
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

    // MARK: Query bar

    /// Two rows, not one: this bar can live in a 270–460pt inspector column, and the
    /// one-row arrangement measurably overflowed it — the mode picker and options
    /// menu were clipped outside the column and unreachable (verified in the real
    /// window under XCUITest). Mode and document status share the first row; the
    /// query field and its match navigation share the second.
    private var queryBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Two explicit modes for one query field. Find keeps every line on
                // screen and highlights matches — a search that hides all context is
                // the exact defect a competitor shipped and had to walk back
                // (OrbStack #2178). Filter remains for genuine triage: "show me only
                // the errors".
                Picker("Query mode", selection: Binding(
                    get: { store.mode },
                    set: { store.mode = $0 }))
                {
                    ForEach(TrackBLogQueryMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("\(scope).searchMode")
                .help("Find highlights matches in place; Filter shows only matching lines")

                Spacer(minLength: 0)

                Text(lineCount)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(scope).lineCount")

                streamStatus

                // The log document's commands live with the log document. In the
                // window toolbar they appeared and disappeared with the inspector
                // tab, churning the route's toolbar on every tab switch.
                logOptionsMenu
            }

            HStack(spacing: 6) {
                DocumentSearchField(
                    text: Binding(get: { store.query }, set: { store.query = $0 }),
                    prompt: store.mode == .find ? "Find in log" : "Filter lines",
                    identifier: "\(scope).search",
                    onSubmit: { forward in stepMatch(forward: forward) },
                    focusRequestCount: searchFocusRequests,
                    isWidthFlexible: true)
                // Command-F belongs to find-in-document. The bar is always present,
                // so the shortcut focuses the field rather than revealing anything.
                .background {
                    Button("") { searchFocusRequests += 1 }
                        .keyboardShortcut("f", modifiers: .command)
                        .hidden()
                        .accessibilityHidden(true)
                }

                if store.isFinding {
                    matchNavigator
                }
            }
        }
        .padding(8)
    }

    /// The "3 of 47" readout and the next/previous steppers, shown only while a find
    /// query is active. A search that highlights but cannot say where you are is half
    /// a search.
    private var matchNavigator: some View {
        HStack(spacing: 2) {
            Text(store.matchPositionText ?? "")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("\(scope).match.position")
                .accessibilityLabel(matchPositionAccessibilityLabel)

            Button {
                stepMatch(forward: false)
            } label: {
                Label("Previous Match", systemImage: "chevron.up")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(store.matchIDs.isEmpty)
            .accessibilityIdentifier("\(scope).match.previous")
            .help("Go to the previous match (⇧⏎ or ⇧⌘G)")

            Button {
                stepMatch(forward: true)
            } label: {
                Label("Next Match", systemImage: "chevron.down")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("g", modifiers: .command)
            .disabled(store.matchIDs.isEmpty)
            .accessibilityIdentifier("\(scope).match.next")
            .help("Go to the next match (⏎ or ⌘G)")
        }
    }

    /// What VoiceOver speaks for the position readout. "3 of 47" alone has no
    /// subject, and "47 matches" would misstate line-level matching, so the spoken
    /// forms are "Match 3 of 47" and "47 matching lines".
    private var matchPositionAccessibilityLabel: String {
        guard let text = store.matchPositionText else { return "" }
        if text == "No matches" { return text }
        if text.contains(" of ") { return "Match \(text)" }
        return "\(store.matchIDs.count) matching \(store.matchIDs.count == 1 ? "line" : "lines")"
    }

    private func stepMatch(forward: Bool) {
        guard store.isFinding else { return }
        guard let target = store.stepMatch(forward: forward) else { return }
        requestScroll(to: target)
    }

    private func requestScroll(to lineID: Int) {
        scrollRequest = ScrollRequest(
            lineID: lineID,
            generation: (scrollRequest?.generation ?? 0) + 1)
    }

    private var lineCount: String {
        let visible = store.visibleLines.count
        if store.isFiltering || store.hasHiddenSources {
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

    // Follow, timestamps, wrap, error navigation, and export are all commands for the
    // selected log document. They live in the document's own bar rather than the
    // window toolbar, which must not mutate when the inspector switches tabs.
    private var logOptionsMenu: some View {
        Menu {
            additionalOptions()

            Toggle("Follow Output", isOn: Binding(
                get: { store.tail.followEnabled },
                set: { store.tail.setFollow($0) }))
                .accessibilityLabel("Follow output")
                .help("Follow new output")

            Toggle("Show Timestamps", isOn: Binding(
                get: { store.showsTimestamps },
                set: { store.showsTimestamps = $0 }))
                .accessibilityLabel("Show timestamps")
                .help("Show timestamps")

            Toggle("Wrap Long Lines", isOn: $wrapsLines)
                .accessibilityIdentifier("\(scope).options.wrapLines")
                .accessibilityLabel("Wrap long lines")
                .help("Wrap long lines instead of scrolling sideways")

            Button("Jump to Next Standard Error Line", systemImage: "arrow.down.to.line") {
                jumpToNextStandardErrorLine()
            }
            .accessibilityIdentifier("\(scope).options.jumpToNextStandardError")
            .accessibilityLabel("Jump to next standard error line")
            .help("Jump to the next line written to standard error")
            .disabled(!hasStandardErrorLines)

            Divider()

            Button(copied ? "Copied" : "Copy Visible Lines", systemImage: copied ? "checkmark" : "doc.on.doc") {
                copyVisibleLines()
            }
            .accessibilityIdentifier("\(scope).options.copyVisibleLines")
            .accessibilityLabel("Copy visible lines")
            .help("Copy visible lines")

            Button("Save Visible Transcript…", systemImage: "square.and.arrow.down") {
                export()
            }
            .accessibilityIdentifier("\(scope).options.saveTranscript")
            .accessibilityLabel("Save visible log transcript")
            .help("Save the currently visible bounded log transcript")
            .disabled(store.visibleLines.isEmpty)

            Divider()

            Button("Clear Scrollback") {
                store.clear()
            }
            .accessibilityIdentifier("\(scope).options.clearScrollback")
            .accessibilityLabel("Clear scrollback")
            .help("Clear scrollback")
        } label: {
            Label("Log options", systemImage: "text.alignleft")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("\(scope).options")
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
        if let currentStandardErrorID { requestScroll(to: currentStandardErrorID) }
    }

    private func copyVisibleLines() {
        MorbPasteboard.copy(store.exportText())
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            copied = false
        }
    }

    // MARK: Surface

    private var logSurface: some View {
        ScrollViewReader { proxy in
            ScrollView(wrapsLines ? .vertical : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.lines.hasDropped { droppedMarker }
                    ForEach(store.visibleLines) { line in
                        TrackBLogRow(
                            line: line,
                            showsTimestamp: store.showsTimestamps,
                            showsSource: showsSourceColumn,
                            isCurrentStandardError: line.id == currentStandardErrorID,
                            findNeedle: store.isFinding ? store.needle : nil,
                            isCurrentMatch: line.id == store.currentMatchID,
                            wraps: wrapsLines)
                        .id(line.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .padding(.vertical, 6)
                // Wrapped rows stretch to the viewport; unwrapped rows keep their own
                // width so the horizontal scroller has something to scroll.
                .frame(
                    maxWidth: wrapsLines ? .infinity : nil,
                    minHeight: viewportHeight > 0 ? viewportHeight : nil,
                    alignment: .topLeading)
            }
            // `.bottom` centres horizontally, which would park an unwrapped document
            // in the middle of its longest line. Reading starts at the left margin.
            .defaultScrollAnchor(wrapsLines ? .bottom : .bottomLeading)
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
            .onChange(of: scrollRequest) { _, request in
                guard let request else { return }
                // Deliberately not animated. Animating `scrollTo` over a large
                // LazyVStack of variable-height rows makes the layout engine hunt for
                // the target's estimated offset; consecutive Enter-Enter match steps
                // reproducibly wedged the main thread for 30+ seconds under XCUITest.
                // The system find bar also jumps to matches without animation.
                proxy.scrollTo(request.lineID, anchor: .center)
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
                if store.visibleLines.isEmpty { emptyOverlay() }
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

    // MARK: Export

    private func export() {
        let document = makeExportDocument()
        guard document.lineCount > 0 else { return }
        chooseExportDestination(for: document)
    }

    /// `NSSavePanel` owns location selection and its standard replacement prompt. The
    /// document is frozen before the panel opens, so a running stream cannot alter what
    /// the person reviewed as the current visible transcript while choosing a location.
    @MainActor
    private func chooseExportDestination(for document: TrackBLogExport.Document) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = exportFilename
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

// MARK: - Row

struct TrackBLogRow: View {

    let line: TrackBRenderedLine
    let showsTimestamp: Bool
    /// Draws the service column of an aggregated document.
    var showsSource: Bool = false
    var isCurrentStandardError: Bool = false
    /// Normalized find query; matches are painted in place. `nil` outside find mode.
    var findNeedle: String? = nil
    /// Whether this line is the one the find navigation is parked on.
    var isCurrentMatch: Bool = false
    /// Long lines wrap; otherwise the surface scrolls sideways (OrbStack #536).
    var wraps: Bool = true

    /// The pre-rendered line, with find highlights layered over the cached attributed
    /// string. Only rows the `LazyVStack` actually materialises pay this cost, so the
    /// ingest-time render cache still carries the 10,000-line scroll performance.
    ///
    /// The system's own find idiom supplies the colours: `NSColor.findHighlightColor`
    /// (with black text, as AppKit pairs it) for the current match, and a translucent
    /// wash of the same colour for the other matches on screen.
    private var highlightedText: AttributedString {
        guard let findNeedle, !findNeedle.isEmpty else { return line.attributed }
        let spans = TrackBLogFilter.matchSpans(of: findNeedle, in: line.plain)
        guard !spans.isEmpty else { return line.attributed }

        var text = line.attributed
        // `attributed` is built from the same spans as `plain`, so character offsets
        // line up by construction; the count check keeps a hypothetical divergence a
        // missing highlight instead of a trap.
        let characterCount = text.characters.count
        for span in spans {
            guard span.offset + span.length <= characterCount else { continue }
            let start = text.index(text.startIndex, offsetByCharacters: span.offset)
            let end = text.index(start, offsetByCharacters: span.length)
            if isCurrentMatch {
                text[start..<end].backgroundColor = Color(nsColor: .findHighlightColor)
                text[start..<end].foregroundColor = .black
            } else {
                text[start..<end].backgroundColor =
                    Color(nsColor: .findHighlightColor).opacity(0.3)
            }
        }
        return text
    }

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

            if showsSource, let source = line.source {
                // The service name is the identification; the colour is a second,
                // redundant channel over the same fact. See `ComposeServicePalette`.
                Text(source.service)
                    .font(.caption.monospaced())
                    .foregroundStyle(ComposeServicePalette.color(at: source.colorIndex))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 96, alignment: .leading)
                    .accessibilityLabel("Service \(source.service)")
                    .help(source.service)
            }

            Text(line.stream.logTranscriptLabel)
                .font(.caption2.monospaced())
                .foregroundStyle(isCurrentStandardError ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: 42, alignment: .leading)
                .accessibilityLabel(line.stream.logTranscriptAccessibilityLabel)

            Text(highlightedText)
                .font(.body.monospaced().weight(isCurrentStandardError ? .medium : .regular))
                .lineSpacing(2)
                .textSelection(.enabled)
                .lineLimit(wraps ? nil : 1)
                // Wrapped: fix the height to the wrapped text. Unwrapped: fix the width
                // to the whole line and let the surface scroll to reach it. Selection
                // and copy read `plain` either way, so neither mode can mangle text.
                .fixedSize(horizontal: !wraps, vertical: wraps)
                .frame(maxWidth: wraps ? .infinity : nil, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 1)
    }
}
