// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The raw inspect response is treated as a selectable text document.  The system owns
// search controls and toolbar appearance; the only local presentation rule is the
// monospaced document font Docker's JSON requires.

import AppKit
import SwiftUI

struct TrackBJSONLine: Identifiable {
    let id: Int
    let attributed: AttributedString
    let plain: String
    let lowered: String

    init(id: Int, text: String) {
        self.id = id
        self.plain = text
        self.lowered = text.lowercased()
        self.attributed = AttributedString(text)
    }
}

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
        VStack(spacing: 0) {
            // The document's own commands live in the document's own bar. Putting
            // them in the window toolbar made the toolbar churn on every inspector
            // tab switch, which defeats motor memory for the whole route.
            HStack(spacing: 8) {
                DocumentSearchField(text: $query, prompt: "Search JSON")
                if !query.isEmpty {
                    Text(matchCaption)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                if !matches.isEmpty {
                    Button { step(-1) } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Previous match")
                    .help("Previous match")

                    Button { step(1) } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Next match")
                    .help("Next match")
                }

                Button {
                    MorbPasteboard.copy(json)
                    didCopy = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        didCopy = false
                    }
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy raw inspect JSON")
                .help("Copy raw inspect JSON")
            }
            .padding(8)

            Divider()
            content
        }
        .task(id: json) { prepare() }
        .onChange(of: query) { _, _ in recomputeMatches() }
    }

    private var matchCaption: String {
        matches.isEmpty ? "0 matches" : "\(currentMatch + 1) of \(matches.count)"
    }

    @ViewBuilder
    private var content: some View {
        if let errorText {
            ContentUnavailableView {
                Label("Raw Inspect JSON Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorText)
            }
        } else if isLoading && lines.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if lines.isEmpty {
            ContentUnavailableView {
                Label("Nothing to Inspect", systemImage: "curlybraces")
            } description: {
                Text("The engine did not return raw inspect JSON for this container.")
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { line in
                            TrackBJSONRow(
                                line: line,
                                isMatch: !query.isEmpty && line.lowered.contains(lowerQuery),
                                isCurrent: currentMatchID == line.id)
                            .id(line.id)
                        }
                    }
                    .padding(.vertical, 6)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .background(Color(nsColor: .textBackgroundColor))
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
        currentMatch = (currentMatch + delta + matches.count) % matches.count
    }
}

struct TrackBJSONRow: View {
    let line: TrackBJSONLine
    let isMatch: Bool
    let isCurrent: Bool

    var body: some View {
        Text(line.attributed)
            .font(.body.monospaced())
            .textSelection(.enabled)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlight)
    }

    private var highlight: Color {
        if isCurrent { return Color.accentColor.opacity(0.20) }
        if isMatch { return Color.accentColor.opacity(0.10) }
        return .clear
    }
}
