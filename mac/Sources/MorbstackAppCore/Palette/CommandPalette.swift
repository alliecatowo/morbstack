// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The command palette: ⌘K, type a query, press Return.
//
// Presentation contract
// ---------------------
// This view is the content of a *standard, document-scoped macOS sheet*. Its host must
// use the system `.sheet` treatment directly — no clear presentation background, manual
// scrim, overlay, top offset, or custom panel material. A sheet is appropriate because
// the palette is scoped to its document window and a person dismisses or invokes it
// before returning to that window. A popover would be wrong for ⌘K because HIG popovers
// need a visible initiating control to anchor to; an NSPanel would be a detached,
// modeless auxiliary window. Keep this view host-agnostic so it can also be rendered by
// previews and automation without pretending to be a floating web-style overlay.

import SwiftUI

struct CommandPalette: View {

    let model: AppModel
    @Binding var isPresented: Bool

    /// Rows past this point are unreachable in practice and cost layout, so the list
    /// stops there. The ranking has already put the good ones on top.
    private static let resultLimit = 40

    @State private var query: String
    @State private var results: [PaletteResult]
    @State private var selection: String?
    @State private var activity = TrackDPaletteActivity()
    @State private var isSearchPresented = true
    /// Presentation controls whether the system toolbar search field is visible; focus
    /// controls its responder status. Keeping both explicit makes ⌘K keyboard-first
    /// without inserting a custom text field or focus relay.
    @FocusState private var isSearchFocused: Bool
    /// A destructive palette result is never invoked solely because it was the current
    /// keyboard selection. The standard confirmation dialog supplies the explicit
    /// review boundary before it can run.
    @State private var pendingDestructiveResult: PaletteResult?

    /// Set only by previews and deterministic fixture runs; `nil` in the app.
    private let preloadedQuery: String?

    init(model: AppModel, isPresented: Binding<Bool>, preloadedQuery: String? = nil) {
        self.model = model
        self._isPresented = isPresented
        self.preloadedQuery = preloadedQuery

        let query = preloadedQuery ?? ""
        let initialResults = PaletteResult.rank(
            PaletteCommandBuilder.commands(model: model, query: query),
            query: query,
            limit: Self.resultLimit)
        _query = State(initialValue: query)
        _results = State(initialValue: initialResults)
        _selection = State(initialValue: initialResults.first?.id)
    }

    var body: some View {
        NavigationStack {
            Group {
                if results.isEmpty, !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else if results.isEmpty {
                    ContentUnavailableView(
                        "No Commands Available",
                        systemImage: "command",
                        description: Text("Start the engine or refresh Morbstack, then try again."))
                } else {
                    List(selection: $selection) {
                        ForEach(results) { result in
                            PaletteRow(result: result)
                                .tag(result.id)
                                .onTapGesture(count: 2) {
                                    activate(result.id)
                                }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("Command Palette")
            .searchable(
                text: $query,
                isPresented: $isSearchPresented,
                placement: .toolbar,
                prompt: "Search commands, containers, and images")
            .searchFocused($isSearchFocused)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { close() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let status = activity.status {
                    PaletteActivityStatus(activity: activity, status: status)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .onAppear {
            // A summoned palette always starts from an empty query. A fixture may
            // intentionally preload one, in which case it must remain deterministic.
            if preloadedQuery == nil {
                query = ""
                activity.clear()
                rebuild()
            }
            // The system search field is the initial key target. Setting its standard
            // presentation binding after the sheet enters the responder chain avoids a
            // custom focus relay or fake text field.
            Task { @MainActor in
                isSearchPresented = true
                isSearchFocused = true
            }
        }
        .onChange(of: rebuildKey) { _, _ in rebuild() }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) { runSelected(); return .handled }
        .onExitCommand { close() }
        .confirmationDialog(
            "Run \(pendingDestructiveResult?.command.title ?? "this command")?",
            isPresented: destructiveConfirmationIsPresented,
            titleVisibility: .visible
        ) {
            Button(
                pendingDestructiveResult?.command.title ?? "Run Command",
                role: .destructive
            ) {
                confirmDestructiveResult()
            }
            Button("Cancel", role: .cancel) {
                pendingDestructiveResult = nil
            }
        } message: {
            Text(
                pendingDestructiveResult?.command.subtitle
                    ?? "This action can’t be undone."
            )
        }
    }

    // MARK: - Behaviour

    /// Container and image *counts* rather than the arrays themselves: a stats-driven
    /// status string changing every second must not reshuffle the list under a query.
    private var rebuildKey: String {
        "\(query)|\(model.containers.count)|\(model.images.count)|\(model.engine.state)"
    }

    private func rebuild() {
        let commands = PaletteCommandBuilder.commands(model: model, query: query)
        results = PaletteResult.rank(commands, query: query, limit: Self.resultLimit)
        if !results.contains(where: { $0.id == selection }) {
            selection = results.first?.id
        }
        if query.isEmpty { selection = results.first?.id }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        let current = selection.flatMap { id in results.firstIndex { $0.id == id } } ?? 0
        let next = (current + delta + results.count) % results.count
        selection = results[next].id
    }

    private func runSelected() {
        guard let selection else { return }
        activate(selection)
    }

    private func activate(_ id: String) {
        guard let result = results.first(where: { $0.id == id }) else { return }
        guard !result.command.isDestructive else {
            pendingDestructiveResult = result
            return
        }
        run(result)
    }

    private func run(_ result: PaletteResult) {
        let context = PaletteContext(
            model: model,
            activity: activity,
            dismiss: { isPresented = false })
        result.command.run(context)
    }

    private func confirmDestructiveResult() {
        guard let result = pendingDestructiveResult else { return }
        pendingDestructiveResult = nil
        run(result)
    }

    private var destructiveConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { pendingDestructiveResult != nil },
            set: { isPresented in
                if !isPresented { pendingDestructiveResult = nil }
            })
    }

    private func close() {
        isPresented = false
    }
}

// MARK: - Activity

/// A compact system footer for a command that intentionally keeps the sheet open.
private struct PaletteActivityStatus: View {
    let activity: TrackDPaletteActivity
    let status: String

    var body: some View {
        HStack(spacing: 8) {
            if activity.isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
            }
            Text(status)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

// MARK: - Result

/// A command plus the highlight positions its matcher produced.
struct PaletteResult: Identifiable {

    let command: PaletteCommand
    /// Indices into `command.title`; empty when the hit came from the keywords.
    let highlights: [Int]

    var id: String { command.id }

    /// A keyword-only hit is a real hit but a weaker one than a title hit, so it is
    /// docked this much before the two are compared.
    static let keywordDiscount = 10

    /// Ranks `commands` against `query`, best first.
    static func rank(_ commands: [PaletteCommand], query: String, limit: Int) -> [PaletteResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        // Empty query: show a small, useful default deck rather than hundreds of rows.
        guard !trimmed.isEmpty else {
            let defaults = commands.filter { $0.kind == .engine || $0.kind == .navigate || $0.kind == .general }
            return defaults.prefix(limit).map { PaletteResult(command: $0, highlights: []) }
        }

        var scored: [(result: PaletteResult, score: Int, length: Int)] = []
        for command in commands {
            let titleMatch = FuzzyMatcher.match(trimmed, in: command.title)
            let keywordMatch = command.keywords.isEmpty
                ? nil
                : FuzzyMatcher.match(trimmed, in: command.keywords)

            let keywordScore = keywordMatch.map { $0.score - keywordDiscount }
            switch (titleMatch, keywordScore) {
            case (nil, nil):
                continue
            case (let title?, let keyword?):
                let best = max(title.score, keyword)
                scored.append((PaletteResult(command: command, highlights: title.matchedIndices), best, command.title.count))
            case (let title?, nil):
                scored.append((PaletteResult(command: command, highlights: title.matchedIndices), title.score, command.title.count))
            case (nil, let keyword?):
                scored.append((PaletteResult(command: command, highlights: []), keyword, command.title.count))
            }
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.length != rhs.length { return lhs.length < rhs.length }
                return lhs.result.command.id < rhs.result.command.id
            }
            .prefix(limit)
            .map(\.result)
    }
}

// MARK: - Row

/// Plain list content: `List(selection:)` owns row selection, focus, hover, and
/// accessibility. A nested button would consume a click without selecting its row.
private struct PaletteRow: View {

    let result: PaletteResult

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(highlightedTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = result.command.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        } icon: {
            Image(systemName: result.command.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(result.command.isDestructive ? .red : .secondary)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(result.command.title)
        .accessibilityHint(result.command.isDestructive ? "Destructive command. Press Return to review it before running." : "Press Return to run this command.")
    }

    private var highlightedTitle: AttributedString {
        var attributed = AttributedString(result.command.title)
        guard !result.highlights.isEmpty else { return attributed }

        let wanted = Set(result.highlights)
        var ranges: [Range<AttributedString.Index>] = []
        var cursor = attributed.startIndex
        var offset = 0
        while cursor < attributed.endIndex {
            let next = attributed.characters.index(after: cursor)
            if wanted.contains(offset) { ranges.append(cursor..<next) }
            cursor = next
            offset += 1
        }
        for range in ranges {
            attributed[range].font = .body.bold()
        }
        return attributed
    }
}
