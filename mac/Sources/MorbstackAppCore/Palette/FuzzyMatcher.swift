// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The command palette's matcher.
//
// Deliberately a pure, dependency-free value type with no SwiftUI in sight: matching is
// the one part of the palette with a right answer, and it is the part worth testing.
//
// The model is the familiar one — a query matches a candidate if its characters appear
// in order (a subsequence), and the *score* decides which of the many possible
// alignments and candidates wins. Scoring is what separates a palette that feels
// telepathic from one that makes you type the whole name:
//
//   * a character that starts a word is worth much more than one in the middle, so
//     `wc` finds `my-web-cache` at `w`/`c` rather than at `w`/`the c in cache`;
//   * consecutive characters are worth more than scattered ones, so `abc` in `a-abc`
//     picks the tight run at the end over the loose one that starts at index 0;
//   * gaps and a late first match cost a little, so short, early, dense matches float
//     to the top.
//
// The alignment is chosen by dynamic programming rather than greedily, because the
// greedy answer is wrong exactly in the cases people notice (the `a-abc` one above).

import Foundation

/// The result of matching a query against one candidate.
struct FuzzyMatch: Equatable, Sendable {

    /// Higher is better. Only comparable between matches of the *same* query.
    var score: Int

    /// Indices into the candidate's `Character` array that the query matched,
    /// ascending. Used to embolden the matched characters in the palette row.
    var matchedIndices: [Int]
}

enum FuzzyMatcher {

    // MARK: - Tuning
    //
    // Integer weights, so scores are exactly reproducible and the tests can assert on
    // orderings without worrying about floating-point drift.

    /// Base value of any matched character.
    static let scoreMatch = 16
    /// A match at the start of a word — index 0, after a separator, or at a camelCase
    /// hump. The single biggest signal in the whole function.
    static let bonusWordStart = 14
    /// A match immediately after the previous one.
    static let bonusConsecutive = 12
    /// The query character matched the candidate's case exactly.
    static let bonusCaseExact = 2
    /// The match covers the candidate from its very first character.
    static let bonusFullPrefix = 24
    /// The query matched the entire candidate.
    static let bonusExact = 20

    /// Cost per character skipped between two matches, and the cap on it. Capped
    /// because the distance between `d` and `b` in `docker … build` should not make an
    /// otherwise excellent match unrankable.
    static let penaltyGap = 2
    static let penaltyGapMax = 12
    /// Cost per character before the first match, and its cap.
    static let penaltyLeading = 1
    static let penaltyLeadingMax = 8

    /// Longer candidates are very slightly worse at equal quality, so `nginx` beats
    /// `nginx-proxy-manager` for the query `nginx`.
    static let penaltyLengthDivisor = 4
    static let penaltyLengthMax = 8

    /// Candidates longer than this are truncated before matching. The DP is quadratic
    /// in the candidate length, and nothing in this app has a meaningful 256th
    /// character — image digests are the only strings that come close.
    static let maxCandidateLength = 256

    /// Characters that make the next character a word start.
    private static let separators: Set<Character> = [
        " ", "-", "_", ".", "/", ":", "\\", "@", "+", ",", "(", ")", "[", "]", "\t", "=", "|",
    ]

    // MARK: - Matching

    /// Scores `query` against `candidate`, or returns `nil` when it is not a
    /// subsequence of it.
    ///
    /// An empty query matches everything with score zero, which lets the palette show
    /// its full command list without a special case at the call site.
    static func match(_ query: String, in candidate: String) -> FuzzyMatch? {
        let queryChars = Array(query)
        guard !queryChars.isEmpty else { return FuzzyMatch(score: 0, matchedIndices: []) }

        let candidateChars = Array(candidate.prefix(maxCandidateLength))
        let n = queryChars.count
        let m = candidateChars.count
        guard n <= m else { return nil }

        // `Character.lowercased()` returns a `String` because a few scripts change
        // length when cased; taking the first character keeps this total instead of
        // trapping on them, and those scripts do not appear in container names.
        let queryLower = queryChars.map { $0.lowercased().first ?? $0 }
        let candidateLower = candidateChars.map { $0.lowercased().first ?? $0 }

        // `best[i][j]` is the best score for matching query[0...i] with query[i] landing
        // on candidate[j]; `nil` means that alignment is impossible. `parent` records
        // which j the previous query character used, for the traceback.
        var best = [[Int?]](repeating: [Int?](repeating: nil, count: m), count: n)
        var parent = [[Int]](repeating: [Int](repeating: -1, count: m), count: n)

        var wordStart = [Bool](repeating: false, count: m)
        for j in 0..<m { wordStart[j] = isWordStart(candidateChars, at: j) }

        for i in 0..<n {
            var anyThisRow = false
            for j in 0..<m {
                guard queryLower[i] == candidateLower[j] else { continue }

                var here = scoreMatch
                if wordStart[j] { here += bonusWordStart }
                if queryChars[i] == candidateChars[j] { here += bonusCaseExact }

                if i == 0 {
                    best[0][j] = here - min(j * penaltyLeading, penaltyLeadingMax)
                    parent[0][j] = -1
                    anyThisRow = true
                    continue
                }

                var bestPrevious: Int?
                var bestK = -1
                for k in 0..<j {
                    guard let previous = best[i - 1][k] else { continue }
                    let gap = j - k - 1
                    var total = previous - min(gap * penaltyGap, penaltyGapMax)
                    if gap == 0 { total += bonusConsecutive }
                    if bestPrevious == nil || total > bestPrevious! {
                        bestPrevious = total
                        bestK = k
                    }
                }
                if let bestPrevious {
                    best[i][j] = bestPrevious + here
                    parent[i][j] = bestK
                    anyThisRow = true
                }
            }
            // No alignment survived this query character: the rest cannot recover.
            if !anyThisRow { return nil }
        }

        var endIndex = -1
        var endScore = Int.min
        for j in 0..<m {
            guard let value = best[n - 1][j] else { continue }
            if value > endScore {
                endScore = value
                endIndex = j
            }
        }
        guard endIndex >= 0 else { return nil }

        var indices = [Int](repeating: 0, count: n)
        var cursor = endIndex
        for i in stride(from: n - 1, through: 0, by: -1) {
            indices[i] = cursor
            cursor = parent[i][cursor]
        }

        var score = endScore
        if indices.first == 0 && indices.last == n - 1 { score += bonusFullPrefix }
        if n == m { score += bonusExact }
        score -= min((m - n) / penaltyLengthDivisor, penaltyLengthMax)

        return FuzzyMatch(score: score, matchedIndices: indices)
    }

    /// Whether `index` begins a word: the string's start, the character after a
    /// separator, or a camelCase hump.
    static func isWordStart(_ characters: [Character], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = characters[index - 1]
        if separators.contains(previous) { return true }
        let current = characters[index]
        // `dockerHost` → the `H` is a word start; `HTTPServer` → the `S` is too, but the
        // run of capitals in `HTTP` is not a series of them.
        if current.isUppercase && !previous.isUppercase { return true }
        if current.isNumber && !previous.isNumber { return true }
        return false
    }

    // MARK: - Ranking

    /// One ranked item.
    struct Ranked<Item> {
        var item: Item
        var match: FuzzyMatch
    }

    /// Scores every item and returns the matches, best first.
    ///
    /// Ties are broken by the shorter key and then alphabetically, so the order is
    /// stable across keystrokes — a list that reshuffles under equal scores is the
    /// fastest way to make somebody select the wrong thing.
    static func rank<Item>(
        _ items: [Item],
        query: String,
        key: (Item) -> String
    ) -> [Ranked<Item>] {
        let scored: [(ranked: Ranked<Item>, key: String)] = items.compactMap { item in
            let text = key(item)
            guard let match = match(query, in: text) else { return nil }
            return (Ranked(item: item, match: match), text)
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.ranked.match.score != rhs.ranked.match.score {
                    return lhs.ranked.match.score > rhs.ranked.match.score
                }
                if lhs.key.count != rhs.key.count { return lhs.key.count < rhs.key.count }
                return lhs.key < rhs.key
            }
            .map(\.ranked)
    }
}
