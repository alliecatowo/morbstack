// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The command palette: ⌘K, type three letters, press Return.
//
// Not an `NSPanel`. A panel would float over other apps, need its own key-window
// dance, and could get separated from the window it acts on. This is an ordinary view,
// so it inherits the window's appearance and accent colour for free.
//
// Track A presents it as a sheet:
//
//     .sheet(isPresented: $isPalettePresented) {
//         CommandPalette(model: model, isPresented: $isPalettePresented)
//     }
//
// which is why the root is *just* the panel — no full-bleed dimming layer, no
// `ignoresSafeArea` — and why it asks for `.presentationBackground(.clear)`: a macOS
// sheet already dims and animates down from the titlebar, and clearing its background
// is what turns it from a document sheet into a floating palette. The modifier is inert
// anywhere else, so a conditionally-built `.overlay { if shown { … } }` hosts it just
// as well.

import SwiftUI

struct CommandPalette: View {

    let model: AppModel
    @Binding var isPresented: Bool

    /// Rows past this point are unreachable in practice and cost layout, so the list
    /// stops there. The ranking has already put the good ones on top.
    private static let resultLimit = 40

    @State private var query: String
    @State private var results: [PaletteResult]
    @State private var selection: Int
    @State private var activity = TrackDPaletteActivity()
    @State private var appeared: Bool
    @FocusState private var searchFocused: Bool

    /// Set only by previews and the screenshot harness; `nil` in the app.
    private let preloadedQuery: String?

    /// - Parameter preloadedQuery: a query to open with, already ranked.
    ///
    /// Only previews and the offscreen screenshot harness pass one. Both render a view
    /// once and synchronously, and this palette does all of its setup in `onAppear` —
    /// including `appeared`, which drives the entrance fade and therefore leaves the
    /// whole panel at zero opacity if it never runs. Passing a query seeds the results
    /// *and* skips the entrance animation, so the first frame is the settled palette.
    init(model: AppModel, isPresented: Binding<Bool>, preloadedQuery: String? = nil) {
        self.model = model
        self._isPresented = isPresented
        self.preloadedQuery = preloadedQuery

        let query = preloadedQuery ?? ""
        _query = State(initialValue: query)
        _selection = State(initialValue: 0)
        _appeared = State(initialValue: preloadedQuery != nil)
        _results = State(initialValue: preloadedQuery == nil
            ? []
            : PaletteResult.rank(
                PaletteCommandBuilder.commands(model: model, query: query),
                query: query,
                limit: Self.resultLimit))
    }

    var body: some View {
        panel
            .scaleEffect(appeared ? 1 : 0.97)
            .opacity(appeared ? 1 : 0)
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: appeared)
            .presentationBackground(.clear)
            .onAppear {
                // A palette that is *summoned* always opens empty, however it was left
                // last time. A preloaded one keeps what it was built with — this used to
                // clear it unconditionally, which quietly undid the whole point of the
                // parameter anywhere the view really appears (previews, and the
                // screenshot harness, which hosts views for real rather than rasterising
                // a snapshot of them).
                if preloadedQuery == nil {
                    query = ""
                    selection = 0
                    activity.clear()
                    rebuild()
                }
                appeared = true
                // One turn of the run loop: the text field is not in the responder
                // chain until after this view's first layout pass.
                Task { @MainActor in searchFocused = true }
            }
            .onDisappear { appeared = false }
            // Belt and braces for the escape key: the text field handles it while it
            // has focus, and this catches the case where focus has moved to a row.
            .onExitCommand { close() }
    }

    // MARK: - Chrome

    private var panel: some View {
        VStack(spacing: 0) {
            searchField
            if !results.isEmpty {
                Divider().opacity(0.6)
                resultList
            } else if !query.isEmpty {
                emptyResults
            }
            Divider().opacity(0.6)
            statusBar
        }
        .frame(width: 620)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.separator.opacity(0.8), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.30), radius: 34, y: 14)
        .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "command")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.tertiary)

            TextField("Search containers, images and commands…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 19, weight: .regular))
                .focused($searchFocused)
                .onSubmit { runSelected() }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { close(); return .handled }

            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .onChange(of: rebuildKey) { _, _ in rebuild() }
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        PaletteRow(
                            result: result,
                            selected: index == selection,
                            activate: { activate(index) })
                            .id(result.id)
                            .onHover { inside in
                                // Hover moves the selection so the mouse and the arrow
                                // keys never disagree about what Return will do.
                                if inside { selection = index }
                            }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 372)
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: selection) { _, new in
                guard results.indices.contains(new) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(results[new].id, anchor: .center)
                }
            }
        }
    }

    private var emptyResults: some View {
        VStack(spacing: 5) {
            Text("No matches")
                .font(.callout.weight(.medium))
            Text("Nothing in Morbstack matches “\(query)”.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let status = activity.status {
                if activity.isBusy {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
                } else {
                    Image(systemName: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                hint("↑↓", "navigate")
                hint("↵", "run")
                hint("esc", "close")
            }
            Spacer(minLength: 8)
            if !results.isEmpty {
                Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .animation(.easeOut(duration: 0.15), value: activity.status)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.quaternary.opacity(0.7), in: .rect(cornerRadius: 3, style: .continuous))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Behaviour

    /// Everything that should force the command list to be rebuilt.
    ///
    /// Container and image *counts* rather than the arrays themselves: a stats-driven
    /// status string changing every second must not reshuffle the list under the
    /// user's fingers mid-keystroke.
    private var rebuildKey: String {
        "\(query)|\(model.containers.count)|\(model.images.count)|\(model.engine.state)"
    }

    private func rebuild() {
        let commands = PaletteCommandBuilder.commands(model: model, query: query)
        results = PaletteResult.rank(commands, query: query, limit: Self.resultLimit)
        selection = results.isEmpty ? 0 : min(selection, results.count - 1)
        if query.isEmpty { selection = 0 }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    private func runSelected() {
        guard results.indices.contains(selection) else { return }
        activate(selection)
    }

    private func activate(_ index: Int) {
        guard results.indices.contains(index) else { return }
        let context = PaletteContext(
            model: model,
            activity: activity,
            dismiss: { isPresented = false })
        results[index].command.run(context)
    }

    private func close() {
        isPresented = false
    }
}

// MARK: - Result

/// A command plus the highlight positions its match produced.
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

        // Empty query: show a sensible default deck rather than 300 rows of nothing in
        // particular — engine, navigation and the general utilities, in that order.
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

private struct PaletteRow: View {

    let result: PaletteResult
    let selected: Bool
    let activate: () -> Void

    var body: some View {
        Button(action: activate) {
            HStack(spacing: 11) {
                Image(systemName: result.command.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(iconTint)
                    .frame(width: 26, height: 26)
                    .background(iconTint.opacity(selected ? 0.20 : 0.12), in: .rect(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(highlightedTitle)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let subtitle = result.command.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 8)

                Text(result.command.kind.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if selected {
                    Image(systemName: "return")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.accent.opacity(selected ? 0.18 : 0))
            }
            .contentShape(.rect(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var iconTint: Color {
        if result.command.isDestructive { return .red }
        return result.command.tone == .neutral ? .secondary : result.command.tone.color
    }

    /// The title with the matched characters emboldened in the accent colour.
    private var highlightedTitle: AttributedString {
        var attributed = AttributedString(result.command.title)
        guard !result.highlights.isEmpty else { return attributed }

        // Ranges are collected before any attribute is applied: mutating attributes
        // while walking the same string's indices is the kind of thing that works until
        // a run coalesces underneath you.
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
            attributed[range].font = .body.weight(.bold)
            attributed[range].foregroundColor = Theme.accent
        }
        return attributed
    }
}
