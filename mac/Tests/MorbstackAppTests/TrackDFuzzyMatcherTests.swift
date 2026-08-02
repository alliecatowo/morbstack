// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Coverage for the command palette's matcher and its ranking.
//
// The assertions are mostly about *which alignment wins*, not about absolute scores:
// the weights in `FuzzyMatcher` are tunable and these tests are meant to survive a
// retune. Where a score does appear it is only ever compared against another score for
// the same query, which is the only comparison the matcher promises is meaningful.

import Foundation
import XCTest

@testable import MorbstackAppCore

final class TrackDFuzzyMatcherTests: XCTestCase {

    // MARK: - Basics

    func testEmptyQueryMatchesEverythingWithZeroScore() {
        let match = FuzzyMatcher.match("", in: "nginx")
        XCTAssertEqual(match?.score, 0)
        XCTAssertEqual(match?.matchedIndices, [])
    }

    func testNonSubsequenceDoesNotMatch() {
        XCTAssertNil(FuzzyMatcher.match("xyz", in: "nginx"))
        // Order matters — and note that `gn` *does* match `nginx`, because there is a
        // second `n` after the `g`. The reversal has to be one the string cannot supply.
        XCTAssertNil(FuzzyMatcher.match("xg", in: "nginx"))
    }

    func testQueryLongerThanCandidateDoesNotMatch() {
        XCTAssertNil(FuzzyMatcher.match("nginx-alpine", in: "nginx"))
    }

    func testMatchIsCaseInsensitive() {
        XCTAssertNotNil(FuzzyMatcher.match("NGINX", in: "nginx"))
        XCTAssertNotNil(FuzzyMatcher.match("nginx", in: "NGINX"))
    }

    func testExactCaseScoresAtLeastAsWellAsMismatchedCase() {
        let exact = FuzzyMatcher.match("Do", in: "DockerHost")
        let mismatched = FuzzyMatcher.match("do", in: "DockerHost")
        XCTAssertNotNil(exact)
        XCTAssertNotNil(mismatched)
        XCTAssertGreaterThan(exact!.score, mismatched!.score)
    }

    func testIndicesAreAscendingAndInBounds() {
        let candidate = "morbstack-web-frontend-1"
        guard let match = FuzzyMatcher.match("mwf1", in: candidate) else {
            return XCTFail("expected a match")
        }
        XCTAssertEqual(match.matchedIndices.count, 4)
        XCTAssertEqual(match.matchedIndices, match.matchedIndices.sorted())
        XCTAssertEqual(Set(match.matchedIndices).count, 4, "no index may be used twice")
        for index in match.matchedIndices {
            XCTAssertTrue((0..<candidate.count).contains(index))
        }
    }

    func testMatchedIndicesPointAtTheQueryCharacters() {
        let candidate = "postgres:16-alpine"
        guard let match = FuzzyMatcher.match("pg16", in: candidate) else {
            return XCTFail("expected a match")
        }
        let characters = Array(candidate)
        let matched = String(match.matchedIndices.map { characters[$0] })
        XCTAssertEqual(matched.lowercased(), "pg16")
    }

    // MARK: - Alignment

    func testPrefersWordStarts() {
        // `w` and `c` both appear mid-word later on; the alignment that wins should be
        // the one on the two word boundaries.
        guard let match = FuzzyMatcher.match("wc", in: "my-web-cache") else {
            return XCTFail("expected a match")
        }
        XCTAssertEqual(match.matchedIndices, [3, 7])
    }

    func testPrefersConsecutiveRunOverEarlierScatteredMatch() {
        // A greedy left-to-right matcher answers [0, 3, 4] here. The right answer is
        // the tight run.
        guard let match = FuzzyMatcher.match("abc", in: "a-abc") else {
            return XCTFail("expected a match")
        }
        XCTAssertEqual(match.matchedIndices, [2, 3, 4])
    }

    func testCamelCaseHumpsCountAsWordStarts() {
        guard let match = FuzzyMatcher.match("dh", in: "dockerHost") else {
            return XCTFail("expected a match")
        }
        XCTAssertEqual(match.matchedIndices, [0, 6])
    }

    func testDigitBoundaryCountsAsWordStart() {
        XCTAssertTrue(FuzzyMatcher.isWordStart(Array("web1"), at: 3))
        XCTAssertFalse(FuzzyMatcher.isWordStart(Array("web11"), at: 4))
    }

    func testSeparatorsBeginWords() {
        for candidate in ["a-b", "a_b", "a.b", "a/b", "a:b", "a b"] {
            XCTAssertTrue(
                FuzzyMatcher.isWordStart(Array(candidate), at: 2),
                "`\(candidate)` should treat index 2 as a word start")
        }
    }

    // MARK: - Ranking

    func testWordStartBeatsMidWordMatch() {
        let start = FuzzyMatcher.match("ng", in: "nginx")
        let middle = FuzzyMatcher.match("ng", in: "long-running")
        XCTAssertNotNil(start)
        XCTAssertNotNil(middle)
        XCTAssertGreaterThan(start!.score, middle!.score)
    }

    func testShorterCandidateWinsAtEqualQuality() {
        let short = FuzzyMatcher.match("nginx", in: "nginx")
        let long = FuzzyMatcher.match("nginx", in: "nginx-proxy-manager")
        XCTAssertNotNil(short)
        XCTAssertNotNil(long)
        XCTAssertGreaterThan(short!.score, long!.score)
    }

    func testRankOrdersByScore() {
        let candidates = ["long-running", "nginx-proxy-manager", "nginx", "redis"]
        let ranked = FuzzyMatcher.rank(candidates, query: "ngi") { $0 }
        XCTAssertEqual(ranked.first?.item, "nginx")
        XCTAssertEqual(ranked.count, 3, "`redis` has no `ngi` subsequence")
        XCTAssertFalse(ranked.contains { $0.item == "redis" })
    }

    func testRankDropsNonMatches() {
        let ranked = FuzzyMatcher.rank(["alpha", "beta"], query: "zzz") { $0 }
        XCTAssertTrue(ranked.isEmpty)
    }

    func testRankIsStableForEqualScores() {
        // Same shape, same length, same alignment — the tie-break is alphabetical, and
        // it must not depend on the input order.
        let forwards = FuzzyMatcher.rank(["ab-cd", "ab-ce"], query: "abc") { $0 }.map(\.item)
        let backwards = FuzzyMatcher.rank(["ab-ce", "ab-cd"], query: "abc") { $0 }.map(\.item)
        XCTAssertEqual(forwards, backwards)
        XCTAssertEqual(forwards, ["ab-cd", "ab-ce"])
    }

    func testRankPrefersShorterKeyBeforeAlphabetical() {
        let ranked = FuzzyMatcher.rank(["web", "web-frontend"], query: "web") { $0 }.map(\.item)
        XCTAssertEqual(ranked.first, "web")
    }

    // MARK: - Robustness

    func testVeryLongCandidateIsTruncatedRatherThanRejected() {
        let long = String(repeating: "a", count: 5000) + "z"
        // The `z` lives past the truncation point, so it cannot match…
        XCTAssertNil(FuzzyMatcher.match("az", in: long))
        // …but the prefix still does, and nothing blows up doing it.
        XCTAssertNotNil(FuzzyMatcher.match("aaa", in: long))
    }

    func testNonASCIICandidatesDoNotTrap() {
        XCTAssertNotNil(FuzzyMatcher.match("caf", in: "café-server"))
        XCTAssertNotNil(FuzzyMatcher.match("ß", in: "straße"))
    }
}

// MARK: - Palette ranking

final class TrackDPaletteRankingTests: XCTestCase {

    @MainActor
    private func command(
        id: String,
        title: String,
        kind: PaletteCommand.Kind,
        keywords: String = ""
    ) -> PaletteCommand {
        PaletteCommand(
            id: id, title: title, symbol: "circle", kind: kind, keywords: keywords, run: { _ in })
    }

    @MainActor
    func testEmptyQueryShowsTheDefaultDeckOnly() {
        let commands = [
            command(id: "1", title: "Stop web", kind: .container),
            command(id: "2", title: "Containers", kind: .navigate),
            command(id: "3", title: "Start engine", kind: .engine),
            command(id: "4", title: "Copy docker context command", kind: .general),
            command(id: "5", title: "Remove nginx:latest", kind: .image),
        ]
        let results = PaletteResult.rank(commands, query: "   ", limit: 40)
        let kinds = Set(results.map(\.command.kind))
        XCTAssertEqual(kinds, [.navigate, .engine, .general])
        XCTAssertTrue(results.allSatisfy { $0.highlights.isEmpty })
    }

    @MainActor
    func testTitleMatchProducesHighlights() {
        let commands = [command(id: "1", title: "Stop web", kind: .container)]
        let results = PaletteResult.rank(commands, query: "web", limit: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].highlights, [5, 6, 7])
    }

    @MainActor
    func testKeywordOnlyMatchIsFoundButNotHighlighted() {
        let commands = [
            command(id: "1", title: "Remove nginx:latest", kind: .image, keywords: "rmi delete")
        ]
        // `dlt` is a subsequence of "…delete" but not of "Remove nginx:latest".
        let results = PaletteResult.rank(commands, query: "dlt", limit: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].highlights.isEmpty, "nothing in the title matched")
    }

    @MainActor
    func testTitleMatchOutranksAnIdenticalKeywordMatch() {
        // Both commands contain the query as a perfect exact match — one in its title,
        // one only in its keywords. The discount is what breaks the tie, and it must
        // break it towards the row whose visible text is the thing you typed.
        let commands = [
            command(id: "keyword", title: "Remove nginx:latest", kind: .image, keywords: "stop"),
            command(id: "title", title: "stop", kind: .container),
        ]
        let results = PaletteResult.rank(commands, query: "stop", limit: 10)
        XCTAssertEqual(results.first?.command.id, "title")
        XCTAssertEqual(results.count, 2, "the keyword-only command is still offered, just lower")
    }

    @MainActor
    func testResultsAreCappedAtTheLimit() {
        let commands = (0..<80).map { command(id: "\($0)", title: "Stop web-\($0)", kind: .container) }
        XCTAssertEqual(PaletteResult.rank(commands, query: "web", limit: 12).count, 12)
    }
}
