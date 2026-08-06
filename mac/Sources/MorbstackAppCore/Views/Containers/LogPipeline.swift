// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The non-visual half of the log viewer: how many lines are kept, when the view sticks
// to the bottom, and which lines a filter lets through.
//
// All three are pure value types with no SwiftUI in sight. That is deliberate — these
// are the parts with real edge cases (a ring that drops the wrong end, a follow mode
// that fights the user's scroll wheel, a filter that miscounts) and they are far easier
// to get right when they can be tested without a window.

import Foundation

// MARK: - Ring buffer

/// A bounded, append-only buffer that keeps the newest `capacity` elements.
///
/// Trimming is amortised rather than exact: elements accumulate up to
/// `capacity + slack` and are then removed in one block. Dropping the oldest element on
/// every single append would memmove the whole array per log line, which on a chatty
/// container is the single most expensive thing the viewer could do; batching turns
/// that into one memmove per `slack` lines.
///
/// The consequence is a documented one: `count` never falls below `capacity` once the
/// buffer is full, and never exceeds `capacity + slack`. Nothing downstream cares about
/// the exact number, only that it is bounded and that the *oldest* lines are the ones
/// that go.
struct TrackBRingBuffer<Element> {

    /// The floor the buffer trims back to.
    let capacity: Int
    /// How far past `capacity` the buffer is allowed to grow before trimming.
    let slack: Int

    private(set) var elements: [Element] = []

    /// How many elements have been evicted over the buffer's lifetime.
    private(set) var droppedCount: Int = 0

    init(capacity: Int) {
        self.capacity = Swift.max(1, capacity)
        self.slack = Swift.max(1, self.capacity / 8)
        elements.reserveCapacity(Swift.min(self.capacity + self.slack, 16_384))
    }

    /// `true` once anything has been evicted — the view shows a "…earlier lines
    /// dropped" marker so a truncated scrollback never looks like the whole story.
    var hasDropped: Bool { droppedCount > 0 }

    mutating func append(_ element: Element) {
        elements.append(element)
        trim()
    }

    mutating func append(contentsOf newElements: some Sequence<Element>) {
        elements.append(contentsOf: newElements)
        trim()
    }

    mutating func removeAll() {
        elements.removeAll(keepingCapacity: true)
        droppedCount = 0
    }

    private mutating func trim() {
        let overflow = elements.count - (capacity + slack)
        guard overflow > 0 else { return }
        let excess = elements.count - capacity
        elements.removeFirst(excess)
        droppedCount += excess
    }
}

extension TrackBRingBuffer: RandomAccessCollection {
    var startIndex: Int { elements.startIndex }
    var endIndex: Int { elements.endIndex }
    subscript(position: Int) -> Element { elements[position] }
    func index(after i: Int) -> Int { i + 1 }
    func index(before i: Int) -> Int { i - 1 }
}

extension TrackBRingBuffer: Sendable where Element: Sendable {}

// MARK: - Follow / stick-to-bottom

/// Decides whether new output should drag the scroll view down with it.
///
/// Two independent facts combine into one answer:
///
///   * `followEnabled` — the toolbar toggle, which is the user's stated intent;
///   * `isPinned` — whether the view is currently parked at the bottom, which is the
///     user's *demonstrated* intent and always wins in the moment.
///
/// Scrolling up therefore pauses auto-scroll without turning the toggle off, and
/// scrolling back down resumes it, which is what every log viewer worth using does.
struct TrackBTailTracker: Equatable, Sendable {

    /// How close to the bottom still counts as "at the bottom", in points. A few points
    /// of slop absorbs sub-pixel geometry and the elastic overscroll at the end of a
    /// trackpad flick, neither of which is the user asking to stop following.
    var stickThreshold: Double

    /// The toolbar toggle.
    private(set) var followEnabled: Bool

    /// Whether the last observed scroll position was at the bottom.
    private(set) var isPinned: Bool

    init(followEnabled: Bool = true, stickThreshold: Double = 28) {
        self.followEnabled = followEnabled
        self.stickThreshold = stickThreshold
        self.isPinned = true
    }

    /// Whether an append should scroll the view.
    var shouldAutoScroll: Bool { followEnabled && isPinned }

    /// Whether to offer the "jump to newest" affordance.
    var showsJumpToBottom: Bool { !isPinned }

    /// Records a scroll position reported by the view.
    ///
    /// `distanceFromBottom` is content height minus offset minus viewport height, so
    /// zero means parked at the end and a large number means scrolled back in history.
    mutating func observe(distanceFromBottom: Double) {
        guard distanceFromBottom.isFinite else { return }
        isPinned = distanceFromBottom <= stickThreshold
    }

    /// The user asked to go back to the newest output.
    mutating func jumpToBottom() {
        isPinned = true
    }

    /// Flips the toolbar toggle. Turning follow back on also re-pins: asking to follow
    /// while parked in history and then seeing nothing happen is a bug, not a feature.
    mutating func setFollow(_ enabled: Bool) {
        followEnabled = enabled
        if enabled { isPinned = true }
    }

    mutating func toggleFollow() {
        setFollow(!followEnabled)
    }
}

// MARK: - Query modes

/// What the log bar's one query field does with its text.
///
/// Two modes, both legitimate, and deliberately explicit rather than merged:
///
///   * `.find` — every line stays on screen; matches are highlighted in place and
///     Enter/Shift+Enter step between them. This is the reading mode: a match means
///     nothing without the lines around it.
///   * `.filter` — only matching lines are shown. This is the triage mode:
///     "show me only the errors".
///
/// Shipping only the second and calling it search is a documented competitor defect
/// (OrbStack #2178, fixed in their v2.2.0); `.find` is the default here for that reason.
enum TrackBLogQueryMode: String, CaseIterable, Identifiable, Sendable {
    case find, filter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .find: return "Find"
        case .filter: return "Filter"
        }
    }
}

// MARK: - Filtering

/// One case-insensitive hit inside a line, measured in `Character` offsets so a view
/// can translate it into any string representation whose characters match the plain
/// text it was computed from (an `AttributedString` built from the same spans).
struct TrackBMatchSpan: Equatable, Sendable {
    var offset: Int
    var length: Int
}

/// Case-insensitive substring filtering, factored out so the match count and the
/// visible rows can never disagree — they are computed from the same predicate.
enum TrackBLogFilter {

    /// Trims and lowercases a raw query. An all-whitespace query is not a filter.
    static func normalize(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// `needle` must already be normalised; `haystack` must already be lowercased.
    ///
    /// Both preconditions exist so the hot loop does no case folding: lines are
    /// lowercased once when they are ingested, and the needle once when it changes.
    static func matches(_ haystack: String, needle: String) -> Bool {
        needle.isEmpty || haystack.contains(needle)
    }

    static func filter<T>(
        _ items: some Sequence<T>, needle: String, lowered: (T) -> String
    ) -> [T] {
        guard !needle.isEmpty else { return Array(items) }
        return items.filter { matches(lowered($0), needle: needle) }
    }

    static func matchCount<T>(
        _ items: some Sequence<T>, needle: String, lowered: (T) -> String
    ) -> Int {
        guard !needle.isEmpty else { return 0 }
        return items.reduce(into: 0) { count, item in
            if matches(lowered(item), needle: needle) { count += 1 }
        }
    }

    /// Every case-insensitive occurrence of `needle` inside `text`, as character
    /// offsets into `text` itself.
    ///
    /// Ranges are found on the *original* string with `.caseInsensitive` rather than on
    /// a lowercased copy, because Unicode case folding can change a string's length
    /// ("İ" lowercases to two scalars) and offsets computed on a folded copy would
    /// paint the highlight one character adrift on such lines.
    static func matchSpans(of needle: String, in text: String) -> [TrackBMatchSpan] {
        guard !needle.isEmpty, !text.isEmpty else { return [] }
        var spans: [TrackBMatchSpan] = []
        var searchStart = text.startIndex
        var offset = 0
        while searchStart < text.endIndex,
            let range = text.range(
                of: needle, options: [.caseInsensitive], range: searchStart..<text.endIndex)
        {
            offset += text.distance(from: searchStart, to: range.lowerBound)
            let length = text.distance(from: range.lowerBound, to: range.upperBound)
            spans.append(TrackBMatchSpan(offset: offset, length: length))
            offset += length
            searchStart = range.upperBound
        }
        return spans
    }
}

// MARK: - Match stepping

/// Pure Enter/Shift+Enter navigation over the ascending line IDs that match a find
/// query. Factored out of the store because the wrap-around and evicted-current edge
/// cases are exactly the kind of logic a screenshot cannot audit.
enum TrackBMatchNavigator {

    /// The line to visit next.
    ///
    /// * No current line: forward starts at the first match, backward at the last.
    /// * Current line still matching: step one, wrapping at either end.
    /// * Current line gone (scrollback eviction or a query edit): resume from the
    ///   nearest match in the direction of travel rather than yanking back to an edge.
    static func step(from current: Int?, in matchIDs: [Int], forward: Bool) -> Int? {
        guard !matchIDs.isEmpty else { return nil }
        guard let current else { return forward ? matchIDs.first : matchIDs.last }

        if let index = binarySearch(matchIDs, for: current) {
            let next = forward ? index + 1 : index - 1
            return matchIDs[(next + matchIDs.count) % matchIDs.count]
        }

        if forward {
            return matchIDs.first(where: { $0 > current }) ?? matchIDs.first
        }
        return matchIDs.last(where: { $0 < current }) ?? matchIDs.last
    }

    /// 1-based rank of `id` among the matches, for a "3 of 47" readout. `nil` when the
    /// line is not (or is no longer) a match.
    static func position(of id: Int, in matchIDs: [Int]) -> Int? {
        binarySearch(matchIDs, for: id).map { $0 + 1 }
    }

    /// Whether `id` is one of the matches. `matchIDs` is ascending by construction —
    /// lines are appended in ID order — so membership is a binary search, not a scan
    /// of ten thousand elements per visible row.
    static func contains(_ id: Int, in matchIDs: [Int]) -> Bool {
        binarySearch(matchIDs, for: id) != nil
    }

    private static func binarySearch(_ sorted: [Int], for value: Int) -> Int? {
        var low = 0
        var high = sorted.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if sorted[mid] == value { return mid }
            if sorted[mid] < value { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }
}

// MARK: - Links in log text

/// One URL found literally inside a log line, as `Character` offsets into the plain
/// text — the same offset convention `TrackBMatchSpan` uses, so a row can apply both.
///
/// `url.absoluteString` is always exactly the substring at `offset..<offset+length`.
/// That equality is the entire safety argument for making log text clickable: the thing
/// a person reads is the thing a click opens, so no log line can ever present a
/// friendly label over a hostile destination.
struct TrackBLinkSpan: Equatable, Sendable {
    var offset: Int
    var length: Int
    var url: URL
}

/// What the app is willing to do with a URL that came out of a container.
enum TrackBLinkDisposition: Equatable, Sendable {
    /// Ordinary remote web address: a click hands it to the user's browser.
    case open
    /// Resolves somewhere on this Mac or this LAN. Still clickable, but a click asks
    /// first and names the destination, because a GET to `127.0.0.1:8080/admin/reset`
    /// is a real operation and the container that printed it is untrusted input.
    case confirmLocal
    /// Never linked and never opened.
    case reject
}

/// Finds and classifies URLs inside log text.
///
/// A log line is untrusted input written by whatever is running inside a container, so
/// this is deliberately a small allowlist rather than `NSDataDetector`:
///
///   * **Only `http` and `https`.** No `file:`, no `javascript:`, no `data:`, no
///     application schemes — those reach local handlers, and a log line must not be
///     able to invoke one. `NSDataDetector` was rejected for a second reason: it
///     promotes bare `www.example.com` to `http://www.example.com`, which breaks the
///     display-equals-destination property below.
///   * **The link text is the destination, character for character.** Only the exact
///     literal substring is linked; nothing is normalised, completed, punycode-decoded
///     or re-encoded on the way to `URL`.
///   * **No embedded credentials.** `http://user:pass@host/` is a phishing shape and a
///     credential-leak shape at once.
///   * **No bidirectional formatting anywhere in the line.** A single U+202E can make
///     the rendered text read differently from the characters it is made of, which
///     would defeat the property above; such a line simply gets no links at all.
///   * **Nothing opens by itself.** This type only produces spans. Opening is a
///     deliberate click, and `confirmLocal` destinations get a confirmation naming the
///     full URL before anything is handed to the system.
enum TrackBLogLinkifier {

    /// Longer than any URL worth clicking, and a bound on the work one hostile line can
    /// cause. `RFC 9110` recommends supporting at least 8000 octets in a request line;
    /// this is a UI affordance, not a fetch, so the smaller bound is deliberate.
    static let maximumLength = 2_048

    /// Characters that may appear in a linked URL — RFC 3986's unreserved, reserved and
    /// percent characters, and nothing else. Space, quotes, angle brackets, braces,
    /// backslash, backtick and pipe all end the URL, which is what makes a URL inside
    /// prose or JSON terminate where a reader expects it to.
    private static let allowed = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")

    /// Trailing punctuation a sentence contributes and a URL almost never ends with.
    private static let trailingPunctuation = Set(".,;:!?'\"")

    /// Bidi overrides and isolates. Any of these anywhere in the line disables linking
    /// for that line — see the type comment.
    private static let bidiControls: Set<Unicode.Scalar> = [
        "\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
        "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
    ]

    /// Every linkable URL in `text`, in order.
    static func spans(in text: String) -> [TrackBLinkSpan] {
        // The overwhelmingly common case is a line with no URL in it at all; one
        // case-insensitive search is far cheaper than walking every character.
        guard text.range(of: "http", options: .caseInsensitive) != nil else { return [] }
        guard !text.unicodeScalars.contains(where: { bidiControls.contains($0) }) else { return [] }

        let characters = Array(text)
        var spans: [TrackBLinkSpan] = []
        var index = 0

        while index < characters.count {
            guard let schemeLength = schemeLength(in: characters, at: index),
                isBoundary(characters, before: index)
            else {
                index += 1
                continue
            }

            var end = index + schemeLength
            var brokeOnUnicodeWord = false
            while end < characters.count {
                let character = characters[end]
                if allowed.contains(character) {
                    end += 1
                    continue
                }
                // A URL that continues into non-ASCII text (an IDN host written in its
                // own script) would be linked as a misleading ASCII prefix. Refuse the
                // whole candidate instead.
                if !character.isASCII, character.isLetter || character.isNumber {
                    brokeOnUnicodeWord = true
                }
                break
            }

            defer { index = max(end, index + 1) }
            guard !brokeOnUnicodeWord else { continue }

            let trimmed = trimTrailing(characters, from: index + schemeLength, to: end)
            guard trimmed > index + schemeLength else { continue }

            let candidate = String(characters[index..<trimmed])
            guard candidate.count <= maximumLength, let url = validate(candidate) else { continue }
            spans.append(TrackBLinkSpan(offset: index, length: trimmed - index, url: url))
            end = trimmed
        }

        return spans
    }

    /// How many characters `http://` or `https://` occupies at `index`, or `nil`.
    private static func schemeLength(in characters: [Character], at index: Int) -> Int? {
        for scheme in ["http://", "https://"] {
            let count = scheme.count
            guard index + count <= characters.count else { continue }
            let slice = String(characters[index..<(index + count)]).lowercased()
            if slice == scheme { return count }
        }
        return nil
    }

    /// A scheme must start at a word boundary, so `xhttp://evil` and
    /// `https://good/http://evil` do not each produce a second link.
    private static func isBoundary(_ characters: [Character], before index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = characters[index - 1]
        if previous.isLetter || previous.isNumber { return false }
        return !"-._~%@:/".contains(previous)
    }

    /// Drops sentence punctuation and unbalanced closing brackets from the end.
    private static func trimTrailing(_ characters: [Character], from start: Int, to end: Int) -> Int {
        var end = end
        while end > start {
            let last = characters[end - 1]
            if trailingPunctuation.contains(last) {
                end -= 1
                continue
            }
            if last == ")" || last == "]" {
                let open: Character = last == ")" ? "(" : "["
                let opens = characters[start..<end].filter { $0 == open }.count
                let closes = characters[start..<end].filter { $0 == last }.count
                if closes > opens {
                    end -= 1
                    continue
                }
            }
            break
        }
        return end
    }

    /// The allowlist, applied to the parsed URL.
    private static func validate(_ candidate: String) -> URL? {
        guard let url = URL(string: candidate) else { return nil }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        guard url.user == nil, url.password == nil else { return nil }
        guard let host = url.host, !host.isEmpty else { return nil }
        // `URL` is permissive about what it will parse; require the string it produces
        // to be the string that was read, so the destination cannot drift from the text.
        // The one tolerated difference is the empty path Foundation may spell as a
        // trailing slash, which addresses the same resource.
        guard url.absoluteString == candidate || url.absoluteString == candidate + "/" else {
            return nil
        }
        return url
    }

    // MARK: Classification

    /// Whether a click may go straight to the browser, needs a confirmation, or is
    /// refused outright. Re-checked at click time as well as at render time: the render
    /// path and the open path must not be able to disagree.
    static func disposition(for url: URL) -> TrackBLinkDisposition {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .reject
        }
        guard url.user == nil, url.password == nil else { return .reject }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return .reject }
        return isLocalHost(host) ? .confirmLocal : .open
    }

    /// Hosts that resolve to this Mac, this LAN, or an unqualified intranet name.
    ///
    /// Deliberately generous: a false "ask first" costs one click, and the cost of the
    /// opposite mistake is a container silently steering a browser at a service that
    /// only exists inside the person's own network.
    static func isLocalHost(_ host: String) -> Bool {
        let bare = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast())
            : host

        if bare == "localhost" || bare.hasSuffix(".localhost") { return true }
        // mDNS. `.internal` is the Compose/Docker convention for in-cluster names.
        if bare.hasSuffix(".local") || bare.hasSuffix(".internal") { return true }
        if bare == "::1" || bare.hasPrefix("fe80:") || bare.hasPrefix("fc") || bare.hasPrefix("fd") {
            return true
        }

        let octets = bare.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) {
            let values = octets.compactMap { UInt8($0) }
            switch (values[0], values[1]) {
            case (0, _), (127, _), (10, _), (169, 254), (192, 168): return true
            case (172, 16...31): return true
            default: return false
            }
        }

        // A single-label name ("grafana", "build-server") is an intranet name that only
        // the person's own resolver can answer.
        return !bare.contains(".")
    }
}

// MARK: - Export

/// Renders the bounded client-side scrollback as a plain `.log` document.
///
/// Escape sequences are already gone by the time a line reaches here, and timestamps
/// are re-emitted in ISO 8601 rather than the viewer's `HH:mm:ss.SSS` — an exported log
/// tends to end up in a bug report, where the date matters. The document preamble makes
/// its capture, time, filter, source, and retention scope explicit so a bounded client
/// snapshot cannot masquerade as the container's complete Docker log history.
enum TrackBLogExport {

    struct Document: Sendable {
        let text: String
        let lineCount: Int
        let panelMessage: String

        var data: Data { Data(text.utf8) }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// - Parameter service: names the service a line came from, in an aggregated
    ///   document. `nil` (or a `nil` result) omits the column entirely, so a
    ///   single-container transcript keeps exactly the format it has always had.
    static func text<T>(
        _ lines: some Sequence<T>,
        timestamp: (T) -> Date?,
        stream: (T) -> StdStream,
        body: (T) -> String,
        includeTimestamps: Bool,
        service: ((T) -> String?)? = nil
    ) -> String {
        var out = ""
        for line in lines {
            if includeTimestamps, let date = timestamp(line) {
                out += isoFormatter.string(from: date)
                out += " "
            }
            if let name = service?(line) {
                out += "[\(name)] "
            }
            out += "[\(streamLabel(stream(line)))] "
            out += body(line)
            out += "\n"
        }
        return out
    }

    /// Freezes exactly the current visible transcript before an `NSSavePanel` opens.
    ///
    /// The log stream can keep appending while the panel is on screen. Capturing here
    /// means the eventual write contains one stable set of already-fetched lines rather
    /// than a later mixture, and it never starts a second Docker request to fill in
    /// earlier history. The metadata is a document preamble, not app-authored log
    /// entries; the body is the same rendered line content the viewer holds.
    static func document<T>(
        containerName: String,
        containerID: String,
        lines: [T],
        bufferedLineCount: Int,
        droppedEarlierLineCount: Int,
        initialTail: Int,
        searchQuery: String?,
        isStreaming: Bool,
        capturedAt: Date,
        timestamp: (T) -> Date?,
        stream: (T) -> StdStream,
        body: (T) -> String
    ) -> Document {
        let normalizedQuery = searchQuery?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let queryDescription: String
        if let normalizedQuery, !normalizedQuery.isEmpty {
            queryDescription = "\"\(normalizedQuery)\" (only matching buffered lines)"
        } else {
            queryDescription = "None (all buffered lines currently shown)"
        }

        let timestamps = lines.compactMap(timestamp)
        let timeDescription: String
        if let first = timestamps.first, let last = timestamps.last {
            timeDescription = first == last
                ? isoFormatter.string(from: first)
                : "\(isoFormatter.string(from: first)) to \(isoFormatter.string(from: last))"
        } else {
            timeDescription = "No Docker timestamp was reported for the saved lines"
        }

        let retentionDescription: String
        if droppedEarlierLineCount > 0 {
            retentionDescription = "\(droppedEarlierLineCount) earlier client-side line\(droppedEarlierLineCount == 1 ? " was" : "s were") dropped before this snapshot"
        } else {
            retentionDescription = "No client-side lines were dropped before this snapshot"
        }

        let safeContainerName = containerName.isEmpty ? "container" : containerName
        let header = [
            "# Morbstack container log transcript",
            "# Container: \(safeContainerName) (\(containerID))",
            "# Captured: \(isoFormatter.string(from: capturedAt))",
            "# Visible transcript: \(lines.count) line\(lines.count == 1 ? "" : "s") saved from \(bufferedLineCount) buffered line\(bufferedLineCount == 1 ? "" : "s")",
            "# Search filter: \(queryDescription)",
            "# Reported timestamp range: \(timeDescription)",
            "# Docker sources: stdout and stderr; each saved entry has an explicit stream label and a timestamp when Docker reported one.",
            "# Fetch state: initial request asked Docker for its latest \(initialTail) lines; follow was \(isStreaming ? "active" : "not active") when this snapshot was captured.",
            "# Retention: \(retentionDescription). This is a bounded client snapshot, not complete container log history.",
            "# Format: ANSI escape sequences were removed by the viewer before saving. Lines below are the exact currently visible transcript.",
            "#",
        ].joined(separator: "\n") + "\n"

        let transcript = text(
            lines,
            timestamp: timestamp,
            stream: stream,
            body: body,
            includeTimestamps: true)
        let panelMessage = "Save \(lines.count) currently visible log line\(lines.count == 1 ? "" : "s") from \(safeContainerName). The file includes capture, timestamp, search, stream, and bounded-retention metadata; it does not fetch or represent complete container history."
        return Document(text: header + transcript, lineCount: lines.count, panelMessage: panelMessage)
    }

    /// The same frozen snapshot for a Compose-aggregated document.
    ///
    /// Two facts the single-container preamble has no reason to state, and this one must:
    /// which services the transcript covers (including any the person had hidden, so a
    /// partial capture cannot be read as the whole project), and how the lines were
    /// ordered — a merged transcript whose ordering rule is unstated invites the reader
    /// to infer causality the document cannot support.
    static func projectDocument<T>(
        project: String,
        includedServices: [String],
        hiddenServices: [String],
        unavailableServices: [String],
        lines: [T],
        bufferedLineCount: Int,
        droppedEarlierLineCount: Int,
        initialTail: Int,
        searchQuery: String?,
        isStreaming: Bool,
        capturedAt: Date,
        timestamp: (T) -> Date?,
        stream: (T) -> StdStream,
        body: (T) -> String,
        service: @escaping (T) -> String?
    ) -> Document {
        let normalizedQuery = searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryDescription: String
        if let normalizedQuery, !normalizedQuery.isEmpty {
            queryDescription = "\"\(normalizedQuery)\" (only matching buffered lines)"
        } else {
            queryDescription = "None (all buffered lines currently shown)"
        }

        let timestamps = lines.compactMap(timestamp)
        let timeDescription: String
        if let first = timestamps.min(), let last = timestamps.max() {
            timeDescription = first == last
                ? isoFormatter.string(from: first)
                : "\(isoFormatter.string(from: first)) to \(isoFormatter.string(from: last))"
        } else {
            timeDescription = "No Docker timestamp was reported for the saved lines"
        }

        let retentionDescription: String
        if droppedEarlierLineCount > 0 {
            retentionDescription = "\(droppedEarlierLineCount) earlier client-side line\(droppedEarlierLineCount == 1 ? " was" : "s were") dropped before this snapshot"
        } else {
            retentionDescription = "No client-side lines were dropped before this snapshot"
        }

        let safeProject = project.isEmpty ? "project" : project
        var header = [
            "# Morbstack Compose project log transcript",
            "# Project: \(safeProject)",
            "# Captured: \(isoFormatter.string(from: capturedAt))",
            "# Services included: \(list(includedServices))",
        ]
        if !hiddenServices.isEmpty {
            header.append(
                "# Services hidden when captured (their lines are NOT in this file): \(list(hiddenServices))")
        }
        if !unavailableServices.isEmpty {
            header.append(
                "# Services Docker could not stream: \(list(unavailableServices))")
        }
        header.append(contentsOf: [
            "# Visible transcript: \(lines.count) line\(lines.count == 1 ? "" : "s") saved from \(bufferedLineCount) buffered line\(bufferedLineCount == 1 ? "" : "s")",
            "# Search filter: \(queryDescription)",
            "# Reported timestamp range: \(timeDescription)",
            "# Ordering: merged on the timestamp dockerd recorded for each line, with a short reorder window; a line delayed past that window keeps its arrival position and its true timestamp. Lines without a Docker timestamp are placed after the previous line from the same service.",
            "# Docker sources: stdout and stderr per service; each saved entry carries its service and stream label, and a timestamp when Docker reported one.",
            "# Fetch state: each service's initial request asked Docker for its latest \(initialTail) lines; follow was \(isStreaming ? "active" : "not active") when this snapshot was captured.",
            "# Retention: \(retentionDescription). This is a bounded client snapshot, not complete project log history.",
            "# Format: ANSI escape sequences were removed by the viewer before saving. Lines below are the exact currently visible transcript.",
            "#",
        ])

        let transcript = text(
            lines,
            timestamp: timestamp,
            stream: stream,
            body: body,
            includeTimestamps: true,
            service: service)
        let panelMessage = "Save \(lines.count) currently visible merged log line\(lines.count == 1 ? "" : "s") from \(safeProject). The file names every included and hidden service, states how the streams were ordered, and does not fetch or represent complete project history."
        return Document(
            text: header.joined(separator: "\n") + "\n" + transcript,
            lineCount: lines.count,
            panelMessage: panelMessage)
    }

    private static func list(_ names: [String]) -> String {
        names.isEmpty ? "none" : names.joined(separator: ", ")
    }

    private static func streamLabel(_ stream: StdStream) -> String {
        switch stream {
        case .stdout: return "stdout"
        case .stderr: return "stderr"
        }
    }

    /// `nginx-2026-03-12-094122.log` — a filename that sorts usefully in Downloads.
    static func suggestedFilename(container: String, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let safe = container.isEmpty ? "container" : container
        let sanitized = safe.map { $0 == "/" || $0 == ":" ? "-" : $0 }
        return "\(String(sanitized))-\(formatter.string(from: now)).log"
    }
}
