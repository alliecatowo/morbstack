// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Coverage for making log text clickable (UX-3).
//
// A log line is untrusted input written by whatever is inside a container, so most of
// this file is the reject set. The property every accept case also asserts is the one
// the whole design rests on: the linked characters spell the destination exactly, so no
// container can present a friendly label over a hostile URL.

import SwiftUI
import XCTest

@testable import MorbstackAppCore

final class TrackBLogLinkifierTests: XCTestCase {

    private func urls(in text: String) -> [String] {
        TrackBLogLinkifier.spans(in: text).map(\.url.absoluteString)
    }

    /// Every span must be exactly the text it covers. This runs on all the accept
    /// cases below, because it is the safety argument, not a detail.
    private func assertTextEqualsDestination(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let characters = Array(text)
        for span in TrackBLogLinkifier.spans(in: text) {
            let covered = String(characters[span.offset..<(span.offset + span.length)])
            XCTAssertEqual(
                covered, span.url.absoluteString,
                "linked text must be the destination", file: file, line: line)
        }
    }

    // MARK: Accept

    func testFindsAPlainHTTPAndHTTPSURL() {
        XCTAssertEqual(urls(in: "listening on http://example.com/health"), ["http://example.com/health"])
        XCTAssertEqual(urls(in: "see https://example.com/a/b?c=1&d=2#frag"), ["https://example.com/a/b?c=1&d=2#frag"])
        assertTextEqualsDestination("see https://example.com/a/b?c=1&d=2#frag")
    }

    func testSchemeIsCaseInsensitive() {
        XCTAssertEqual(urls(in: "HTTP://Example.COM/x"), ["HTTP://Example.COM/x"])
        assertTextEqualsDestination("HTTP://Example.COM/x")
    }

    func testFindsSeveralURLsInOneLine() {
        let text = "from http://a.example/1 to https://b.example/2 done"
        XCTAssertEqual(urls(in: text), ["http://a.example/1", "https://b.example/2"])
        assertTextEqualsDestination(text)
    }

    func testOffsetsAreCharacterOffsetsPastUnicode() {
        let spans = TrackBLogLinkifier.spans(in: "🎉 ready http://example.com/x")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].offset, 8, "the emoji is one character, not four bytes")
        assertTextEqualsDestination("🎉 ready http://example.com/x")
    }

    func testTrailingSentencePunctuationIsNotPartOfTheURL() {
        XCTAssertEqual(urls(in: "open http://example.com/x."), ["http://example.com/x"])
        XCTAssertEqual(urls(in: "open http://example.com/x, then"), ["http://example.com/x"])
        XCTAssertEqual(urls(in: "\"http://example.com/x\""), ["http://example.com/x"])
    }

    func testUnbalancedClosingBracketsAreTrimmedButBalancedOnesAreKept() {
        XCTAssertEqual(urls(in: "(see http://example.com/x)"), ["http://example.com/x"])
        XCTAssertEqual(
            urls(in: "http://example.com/wiki/Thing_(disambiguation)"),
            ["http://example.com/wiki/Thing_(disambiguation)"])
    }

    func testURLsInsideJSONAndQuotesTerminateCleanly() {
        let text = #"{"upstream":"http://api.internal:8080/v1","ok":true}"#
        XCTAssertEqual(urls(in: text), ["http://api.internal:8080/v1"])
        assertTextEqualsDestination(text)
    }

    // MARK: Reject

    func testOnlyHTTPAndHTTPSAreEverLinked() {
        XCTAssertEqual(urls(in: "file:///etc/passwd"), [])
        XCTAssertEqual(urls(in: "javascript:alert(1)"), [])
        XCTAssertEqual(urls(in: "data:text/html;base64,PHNjcmlwdD4="), [])
        XCTAssertEqual(urls(in: "ftp://example.com/x"), [])
        XCTAssertEqual(urls(in: "vnc://127.0.0.1"), [])
        XCTAssertEqual(urls(in: "smb://fileserver/share"), [])
        XCTAssertEqual(urls(in: "x-morbstack://do-something"), [])
        XCTAssertEqual(urls(in: "mailto:someone@example.com"), [])
    }

    /// `NSDataDetector` would promote this to `http://www.example.com`, inventing a
    /// destination the text does not contain. That is why it is not used here.
    func testBareHostnamesAreNotPromotedToLinks() {
        XCTAssertEqual(urls(in: "visit www.example.com for details"), [])
        XCTAssertEqual(urls(in: "example.com/health"), [])
    }

    func testEmbeddedCredentialsAreRefused() {
        XCTAssertEqual(urls(in: "http://user:hunter2@evil.example/x"), [])
        XCTAssertEqual(urls(in: "https://token@evil.example/x"), [])
    }

    func testMalformedOrEmptyHostsAreRefused() {
        XCTAssertEqual(urls(in: "http://"), [])
        XCTAssertEqual(urls(in: "http:// spaced.example"), [])
        XCTAssertEqual(urls(in: "https:///onlypath"), [])
    }

    /// A scheme that starts mid-word is not a link, or `https://good/http://evil` would
    /// produce a second, separately clickable "URL" that is really part of a path.
    func testASchemeMustStartAtAWordBoundary() {
        XCTAssertEqual(urls(in: "xhttp://evil.example/x"), [])
        XCTAssertEqual(
            urls(in: "https://good.example/redirect?to=http://evil.example"),
            ["https://good.example/redirect?to=http://evil.example"],
            "the query is part of the one visible URL, not a second link")
    }

    /// A right-to-left override can make rendered text read differently from the
    /// characters it is made of, which would break the display-equals-destination
    /// property. Such a line gets no links at all.
    func testBidirectionalOverridesDisableLinkingForTheWholeLine() {
        XCTAssertEqual(urls(in: "http://example.com/\u{202E}gnp.exe"), [])
        XCTAssertEqual(urls(in: "safe http://example.com/x \u{200F} trailing"), [])
        XCTAssertEqual(urls(in: "http://example.com/x \u{2066}isolated\u{2069}"), [])
    }

    /// An internationalised host written in its own script would otherwise be linked as
    /// a misleading ASCII prefix ("http://exam" of "http://exampleü.com").
    func testAURLContinuingIntoNonASCIITextIsRefusedRatherThanTruncated() {
        XCTAssertEqual(urls(in: "http://exampleü.com/x"), [])
        XCTAssertEqual(urls(in: "http://例え.jp"), [])
        // Punycode is ASCII and is linked as written — the text and the destination are
        // the same string, and the browser is what shows the decoded name.
        XCTAssertEqual(urls(in: "http://xn--r8jz45g.jp/x"), ["http://xn--r8jz45g.jp/x"])
    }

    func testAbsurdlyLongCandidatesAreRefused() {
        let long = "http://example.com/" + String(repeating: "a", count: 4_000)
        XCTAssertEqual(urls(in: long), [])
    }

    func testTextWithoutAnyURLCostsNothing() {
        XCTAssertEqual(TrackBLogLinkifier.spans(in: "GET /health 200 1.2ms"), [])
        XCTAssertEqual(TrackBLogLinkifier.spans(in: ""), [])
    }

    // MARK: Disposition

    func testPublicWebAddressesOpenDirectly() {
        XCTAssertEqual(
            TrackBLogLinkifier.disposition(for: URL(string: "https://example.com/docs")!), .open)
        XCTAssertEqual(
            TrackBLogLinkifier.disposition(for: URL(string: "http://93.184.216.34/x")!), .open)
    }

    /// Anything that lands on this Mac or this LAN is confirmed by name first: a GET to
    /// a local admin endpoint is a real operation, and the container that printed the
    /// address is untrusted.
    func testLocalAndPrivateDestinationsAskFirst() {
        for address in [
            "http://localhost:3000/",
            "http://127.0.0.1:8080/admin",
            "http://[::1]:9000/",
            "http://10.1.2.3/",
            "http://172.16.0.9/",
            "http://172.31.255.1/",
            "http://192.168.1.10/",
            "http://169.254.169.254/latest/meta-data",
            "http://db.local/",
            "http://api.internal:8080/v1",
            "http://grafana:3000/",
            "http://0.0.0.0:8080/",
        ] {
            XCTAssertEqual(
                TrackBLogLinkifier.disposition(for: URL(string: address)!), .confirmLocal,
                "\(address) resolves locally")
        }
    }

    func testPublicAddressesThatMerelyLookPrivateAreNotConfused() {
        XCTAssertEqual(
            TrackBLogLinkifier.disposition(for: URL(string: "http://172.32.0.1/")!), .open)
        XCTAssertEqual(
            TrackBLogLinkifier.disposition(for: URL(string: "http://11.0.0.1/")!), .open)
        XCTAssertEqual(
            TrackBLogLinkifier.disposition(for: URL(string: "https://localhost.example.com/")!), .open)
    }

    func testDispositionRefusesWhatTheLinkifierWouldNeverProduce() {
        XCTAssertEqual(TrackBLogLinkifier.disposition(for: URL(string: "file:///etc/passwd")!), .reject)
        XCTAssertEqual(
            TrackBLogLinkifier.disposition(for: URL(string: "http://user:p@example.com/")!), .reject)
        XCTAssertEqual(TrackBLogLinkifier.disposition(for: URL(string: "mailto:a@b.c")!), .reject)
    }
}

// MARK: - Rendered line integration

@MainActor
final class TrackBRenderedLineLinkTests: XCTestCase {

    private func rendered(_ text: String) -> TrackBRenderedLine {
        TrackBRenderedLine(LogLine(id: 0, text: text, stream: .stdout, timestamp: nil))
    }

    func testLinksAreBakedIntoTheCachedAttributedString() {
        let line = rendered("ready on http://example.com/health")
        XCTAssertEqual(line.links.map(\.url.absoluteString), ["http://example.com/health"])

        let linked = line.attributed.runs.compactMap { run -> String? in
            guard let url = run.link else { return nil }
            return url.absoluteString
        }
        XCTAssertEqual(linked, ["http://example.com/health"])
    }

    /// ANSI colour and a link can cover the same characters. The link presentation wins
    /// there — a link that does not look like a link is the worse outcome — but the
    /// colour on the rest of the line must survive, and the plain text must be intact.
    func testALinkInsideAnANSISpanKeepsTheLineIntact() {
        let line = rendered("\u{1B}[32mready\u{1B}[0m at http://example.com/x done")
        XCTAssertEqual(line.plain, "ready at http://example.com/x done")
        XCTAssertEqual(line.links.count, 1)
        XCTAssertEqual(
            String(line.attributed.characters), "ready at http://example.com/x done")
    }

    /// The find highlighter indexes into the same attributed string the linkifier just
    /// wrote to. An off-by-one between those two is a crash in the real window.
    func testFindHighlightRangesStayInBoundsOnALineWithLinks() {
        let samples = [
            "🎉 ready at http://example.com/health after 3s",
            "\u{1B}[31mERROR\u{1B}[0m upstream https://api.example.com/v1/orders timed out",
            "no links here at all",
        ]
        for sample in samples {
            let line = rendered(sample)
            XCTAssertEqual(line.attributed.characters.count, line.plain.count)
            for needle in ["http", "e", "error", "🎉"] {
                var text = line.attributed
                let characterCount = text.characters.count
                for span in TrackBLogFilter.matchSpans(of: needle, in: line.plain) {
                    XCTAssertLessThanOrEqual(span.offset + span.length, characterCount)
                    let start = text.index(text.startIndex, offsetByCharacters: span.offset)
                    let end = text.index(start, offsetByCharacters: span.length)
                    text[start..<end].backgroundColor = .yellow
                }
            }
        }
    }

    /// Wrap is presentation only. Search, copy and export all read `plain`, so turning
    /// wrapping off cannot change what a match is or what lands on the pasteboard.
    func testWrapCannotAffectSearchOrCopiedText() {
        let store = TrackBLogStore()
        store.seed(
            [
                LogLine(
                    id: 0,
                    text: String(repeating: "long ", count: 200) + "needle",
                    stream: .stdout,
                    timestamp: nil)
            ],
            isStreaming: false)
        store.query = "needle"

        XCTAssertEqual(store.matchIDs, [0])
        let copied = store.exportText()
        XCTAssertTrue(copied.hasSuffix("needle\n"))
        XCTAssertFalse(copied.contains("\n["), "one log line is one exported line, wrapped or not")
    }
}
