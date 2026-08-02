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
        // The one surface in the app where opaque is objectively wrong, along with the
        // menu-bar popover — see `docs/design/IDENTITY.md` §5.1.
        .morbGlassPanel()
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous)
                .strokeBorder(.separator.opacity(0.8), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.30), radius: 34, y: 14)
        .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
    }

    private var searchField: some View {
        HStack(spacing: Theme.space3) {
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
        .padding(.horizontal, Theme.space5)
        .padding(.vertical, Theme.space4)
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
                .padding(.horizontal, Theme.space3)
                .padding(.vertical, Theme.space2)
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
        VStack(spacing: Theme.space2) {
            Text("No matches")
                .font(.callout.weight(.medium))
            Text("Nothing in Morbstack matches “\(query)”.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.space6)
    }

    private var statusBar: some View {
        HStack(spacing: Theme.space3) {
            if let status = activity.status {
                if activity.isBusy {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
                } else {
                    Image(systemName: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(Theme.statusRunning)
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
            Spacer(minLength: Theme.space3)
            if !results.isEmpty {
                Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Theme.space5)
        .padding(.vertical, Theme.space3)
        .animation(.easeOut(duration: 0.15), value: activity.status)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: Theme.space2) {
            Text(key)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, Theme.space2)
                .padding(.vertical, 1)
                .background(.quaternary.opacity(0.7), in: .rect(cornerRadius: Theme.radiusChip - 2, style: .continuous))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
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
            HStack(spacing: Theme.space3) {
                // The symbol and its tint carry the *command* — what pressing Return
                // does — not the status of whatever it acts on. Every "View logs of
                // X" row shares the same glyph no matter which container X is, which
                // used to be carried instead by a status-coloured tint; that made the
                // icon column encode neither the command nor the category, since eight
                // rows for one fuzzy match all wore the identical shape. Only the
                // destructive rows still earn a colour, because that is the one fact
                // about a command that is worth a warning colour on the icon itself.
                Image(systemName: result.command.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(result.command.isDestructive ? Theme.statusBad : .secondary)
                    .frame(width: 18)

                Text(highlightedTitle)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let subtitle = result.command.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: Theme.space3)

                // A chip, not eight repetitions of plain right-aligned text — the
                // rank system keeps it quiet, so it reads as metadata rather than as
                // a section header printed once per row.
                MorbChip(result.command.kind.rawValue, rank: .quiet)

                if selected {
                    Image(systemName: "return")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .morbRow(.compact, isSelected: selected, showsHover: false)
        }
        .buttonStyle(.plain)
    }

    /// The title with the matched characters emboldened — `.primary`, not a second
    /// accent colour. The selected row's own fill is `Theme.selectionFill`; a brighter
    /// indigo on the matched characters *inside* that fill is what made the two
    /// indigos fight on the selected row and left the highlight nearly invisible.
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
            attributed[range].font = .callout.weight(.bold)
        }
        return attributed
    }
}
