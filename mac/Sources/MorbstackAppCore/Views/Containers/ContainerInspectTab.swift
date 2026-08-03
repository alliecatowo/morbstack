// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// INSPECT: the raw document, searchable.
//
// The Overview tab is the curated view; this is the escape hatch for everything it does
// not show — and for a container inspect document that is a lot, because the engine
// reports several hundred lines of it. So the requirements are a monospaced dump, fast
// search with somewhere to jump, and a copy button.
//
// Colouring and lowercasing happen once when the document arrives, not per frame. An
// inspect document is a few hundred lines rather than ten thousand, so unlike the log
// viewer it can afford to prepare every line up front — which makes both the search and
// the scroll completely free afterwards.

import AppKit
import SwiftUI

// MARK: - Prepared document

/// One line of pretty-printed JSON, coloured and indexed for search.
struct TrackBJSONLine: Identifiable {

    let id: Int
    let attributed: AttributedString
    let plain: String
    let lowered: String

    init(id: Int, text: String) {
        self.id = id
        self.plain = text
        self.lowered = text.lowercased()
        self.attributed = TrackBJSONHighlighter.highlight(text)
    }
}

/// A deliberately small JSON colouriser.
///
/// This is not a parser and does not try to be: it runs over one already-pretty-printed
/// line and tints the three things worth distinguishing — keys, string values, and
/// literals. Anything it cannot classify stays the primary text colour, which is the
/// correct failure mode for a syntax highlighter.
enum TrackBJSONHighlighter {

    static func highlight(_ line: String) -> AttributedString {
        var result = AttributedString(line)
        result.foregroundColor = .primary

        let characters = Array(line)
        var index = 0
        var stringStart: Int?
        var strings: [(start: Int, end: Int)] = []

        // Find string literals, respecting backslash escapes.
        while index < characters.count {
            let character = characters[index]
            if character == "\\", stringStart != nil {
                index += 2
                continue
            }
            if character == "\"" {
                if let start = stringStart {
                    strings.append((start, index))
                    stringStart = nil
                } else {
                    stringStart = index
                }
            }
            index += 1
        }

        // A string immediately followed by a colon is a key; everything else is a value.
        for span in strings {
            var after = span.end + 1
            while after < characters.count, characters[after] == " " { after += 1 }
            let isKey = after < characters.count && characters[after] == ":"

            guard let range = range(in: result, of: line, from: span.start, to: span.end) else {
                continue
            }
            result[range].foregroundColor = isKey
                ? TrackBPalette.ansi(.blue)
                : TrackBPalette.ansi(.green)
        }

        // Literals, only on lines with no string spans that could contain the same word
        // — `"note": "this is null"` must not get a magenta patch in the middle of it.
        if strings.isEmpty {
            for literal in ["true", "false", "null"] where line.contains(literal) {
                if let found = result.range(of: literal) {
                    result[found].foregroundColor = TrackBPalette.ansi(.magenta)
                }
            }
        }

        return result
    }

    /// Maps a character offset pair in the source string onto the attributed copy.
    private static func range(
        in attributed: AttributedString, of source: String, from start: Int, to end: Int
    ) -> Range<AttributedString.Index>? {
        guard start <= end, end < source.count else { return nil }
        let lower = attributed.index(attributed.startIndex, offsetByCharacters: start)
        let upper = attributed.index(attributed.startIndex, offsetByCharacters: end + 1)
        guard lower < upper, upper <= attributed.endIndex else { return nil }
        return lower..<upper
    }
}

// MARK: - Tab

struct ContainerInspectTab: View {

    let json: String
    let isLoading: Bool
    let errorText: String?

    @State private var query: String
    @State private var lines: [TrackBJSONLine]
    @State private var matches: [Int]
    @State private var currentMatch = 0
    @State private var didCopy = false
    @State private var preparedFor: String

    /// - Parameter initialQuery: pre-fills the search box and its match highlighting.
    ///   Only previews and the screenshot harness pass one.
    ///
    /// The document is also split and coloured here rather than only in `.task`, so the
    /// very first render is already the finished view. `ImageRenderer` never runs
    /// `.task`, and the app pays nothing for it: the work happens once either way, just
    /// a few microseconds earlier.
    init(json: String, isLoading: Bool, errorText: String?, initialQuery: String = "") {
        self.json = json
        self.isLoading = isLoading
        self.errorText = errorText

        let prepared = Self.split(json)
        _query = State(initialValue: initialQuery)
        _lines = State(initialValue: prepared)
        _matches = State(initialValue: Self.matches(in: prepared, query: initialQuery))
        _preparedFor = State(initialValue: json)
    }

    var body: some View {
        content
            .background(TrackBPalette.logSurface)
            .toolbar { toolbarContent }
            .searchable(text: $query, placement: .toolbar, prompt: "Search document")
            .task(id: json) { prepare() }
            .onChange(of: query) { _, _ in recomputeMatches() }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !matches.isEmpty {
            ToolbarItem(id: "inspect.prev", placement: MorbToolbarGroup.navigation) {
                MorbIconButton("chevron.up", help: "Previous match") { step(-1) }
            }
            ToolbarItem(id: "inspect.next", placement: MorbToolbarGroup.navigation) {
                MorbIconButton("chevron.down", help: "Next match") { step(1) }
            }
            MorbToolbarStatus(id: "match-count") {
                MorbNumber(matchCaption)
            }
        }
        MorbToolbarStatus(id: "line-count") {
            MorbNumber("\(lines.count) lines")
        }
        ToolbarItem(id: "inspect.copy", placement: MorbToolbarGroup.actions) {
            MorbIconButton(didCopy ? "checkmark" : "doc.on.doc", help: "Copy the whole document") {
                TrackBClipboard.copy(json)
                didCopy = true
                Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    didCopy = false
                }
            }
        }
    }

    private var matchCaption: String {
        matches.isEmpty ? "0" : "\(currentMatch + 1)/\(matches.count)"
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let errorText {
            TrackBInlineError(text: errorText)
                .padding(Theme.pagePadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if isLoading && lines.isEmpty {
            MorbLoading()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if lines.isEmpty {
            MorbEmptyState(
                "Nothing to inspect",
                systemImage: "curlybraces",
                description: "The engine did not return a document for this container.")
        } else {
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    // `VStack`, not `LazyVStack`. A lazy stack cannot report an ideal
                    // width — it has not built its rows yet — so `fixedSize` below has
                    // nothing to work with and every row collapses to a single ellipsis.
                    // An inspect document is a few hundred lines that are already split
                    // and coloured, which is exactly the case an eager stack is for.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { line in
                            TrackBJSONRow(
                                line: line,
                                isMatch: !query.isEmpty && line.lowered.contains(lowerQuery),
                                isCurrent: currentMatchID == line.id)
                            .id(line.id)
                        }
                    }
                    .padding(.vertical, Theme.space3)
                    // A horizontally scrollable `ScrollView` proposes *no* width to its
                    // content, and `maxWidth: .infinity` against an unspecified proposal
                    // resolves to the minimum — which for a `Text` is one character. The
                    // document rendered as a single column of letters down the middle of
                    // the pane. `fixedSize` makes the stack ask its rows for their ideal
                    // widths instead, so the stack is as wide as the longest line and
                    // every row's match highlight spans the same width.
                    .fixedSize(horizontal: true, vertical: false)
                }
                .onChange(of: currentMatch) { _, _ in
                    guard let id = currentMatchID else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private var lowerQuery: String { TrackBLogFilter.normalize(query) }

    private var currentMatchID: Int? {
        guard !matches.isEmpty, matches.indices.contains(currentMatch) else { return nil }
        return matches[currentMatch]
    }

    // MARK: Behaviour

    private func prepare() {
        guard preparedFor != json else { return }
        preparedFor = json
        lines = Self.split(json)
        recomputeMatches()
    }

    private func recomputeMatches() {
        matches = Self.matches(in: lines, query: query)
        currentMatch = 0
    }

    /// Splits and colours a pretty-printed document. Free of view state so that `init`
    /// and `prepare()` cannot drift apart.
    private static func split(_ json: String) -> [TrackBJSONLine] {
        guard !json.isEmpty else { return [] }
        return json
            .components(separatedBy: "\n")
            .enumerated()
            .map { TrackBJSONLine(id: $0.offset, text: $0.element) }
    }

    private static func matches(in lines: [TrackBJSONLine], query: String) -> [Int] {
        let needle = TrackBLogFilter.normalize(query)
        guard !needle.isEmpty else { return [] }
        return lines.filter { $0.lowered.contains(needle) }.map(\.id)
    }

    private func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        // Wrapping rather than clamping: search that stops dead at the last hit makes
        // you scroll back up by hand to start again.
        currentMatch = (currentMatch + delta + matches.count) % matches.count
    }
}

// MARK: - Row

struct TrackBJSONRow: View {

    let line: TrackBJSONLine
    let isMatch: Bool
    let isCurrent: Bool

    var body: some View {
        Text(line.attributed)
            .font(.system(size: 11.5, design: .monospaced))
            .textSelection(.enabled)
            // One line per line: this is a document viewer with a horizontal scroller,
            // not a paragraph. Without it a long `Env` entry reflows and the line
            // numbers stop meaning anything.
            .lineLimit(1)
            .padding(.horizontal, Theme.space4)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
    }

    @ViewBuilder
    private var background: some View {
        if isCurrent {
            Theme.accent.opacity(0.28)
        } else if isMatch {
            Theme.accent.opacity(0.12)
        } else {
            Color.clear
        }
    }
}
