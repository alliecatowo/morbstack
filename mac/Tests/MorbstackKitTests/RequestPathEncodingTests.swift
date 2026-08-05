// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import XCTest

@testable import MorbstackKit

/// `MinimalHTTP.percentEncodePath` is the single defence between an identifier and
/// the HTTP request line. MCP-1 proved what happens without it: a CRLF in a
/// container id ends the request line early, our own `Connection: close` header
/// lands on whatever followed, and the engine reads two pipelined requests — the
/// second one arbitrary. See `docs/mcp.md`.
final class RequestPathEncodingTests: XCTestCase {

    // MARK: The attack it exists to stop

    func testCarriageReturnAndNewlineCannotReachTheRequestLine() {
        let smuggled = "/containers/web\r\nGET /volumes/prune HTTP/1.1\r\n\r\n/json"
        let encoded = MinimalHTTP.percentEncodePath(smuggled)
        XCTAssertFalse(encoded.contains("\r"), "a bare CR would terminate the request line")
        XCTAssertFalse(encoded.contains("\n"), "a bare LF would terminate the request line")
        XCTAssertTrue(encoded.contains("%0D%0A"))
    }

    func testASpaceCannotSplitTheRequestTarget() {
        // `GET /containers/a b/json HTTP/1.1` parses as target `/containers/a`, and the
        // rest becomes a version token the engine rejects — or worse, is interpreted.
        XCTAssertEqual(MinimalHTTP.percentEncodePath("/containers/a b"), "/containers/a%20b")
    }

    func testAQuestionMarkInsideAnIdentifierIsEscaped() {
        // MCP-1's narrower half: `?force=1&` in an id starts a query string ahead of
        // the parameters the caller meant to send, and Go returns the FIRST value for a
        // repeated key — so `force=0` silently became `force=1`.
        let encoded = MinimalHTTP.percentEncodePath("/containers/web%3Fforce=1")
        XCTAssertFalse(encoded.contains("?"))
    }

    // MARK: Structure that must survive

    func testPathSeparatorsAreKept() {
        XCTAssertEqual(
            MinimalHTTP.percentEncodePath("/containers/abc123/json"), "/containers/abc123/json")
    }

    func testDockersOwnIdentifierGrammarPassesThroughUnchanged() {
        // Escaping an image reference would break every pull: the engine percent-decodes
        // before matching, but a needlessly encoded name is harder to read in a log and
        // in a `docker port` comparison.
        let reference = "/images/registry.example.com:5000/team/app_name-v2.1@sha256:abc/json"
        XCTAssertEqual(MinimalHTTP.percentEncodePath(reference), reference)
    }

    // MARK: The query string, which is separately encoded and must not be touched

    func testAQueryStringIsPreservedVerbatim() {
        // Callers hand in targets that already carry a query whose values were encoded
        // at the point they were interpolated. Encoding the whole target would escape
        // the `?`, `&` and `=` that give it structure.
        let target = "/containers/create?name=web&platform=linux%2Famd64"
        XCTAssertEqual(MinimalHTTP.percentEncodePath(target), target)
    }

    func testOnlyTheFirstQuestionMarkSplitsPathFromQuery() {
        // A `?` inside the query is ordinary data, not a second separator.
        let target = "/events?filters=%7B%22x%22%3A%22a%3Fb%22%7D"
        XCTAssertEqual(MinimalHTTP.percentEncodePath(target), target)
    }

    func testAnIdentifierIsStillEncodedWhenAQueryFollows() {
        // The dangerous half and the must-not-touch half in one target.
        let encoded = MinimalHTTP.percentEncodePath("/containers/a b/stats?stream=1")
        XCTAssertEqual(encoded, "/containers/a%20b/stats?stream=1")
    }

    // MARK: Totality

    func testEncodingIsLosslessForNonASCIINames() {
        // Escaping rather than rejecting keeps this total: the engine decodes before
        // matching a route, so an honest odd name still reaches the right handler.
        let encoded = MinimalHTTP.percentEncodePath("/volumes/données")
        XCTAssertFalse(encoded.contains("é"))
        XCTAssertTrue(encoded.hasPrefix("/volumes/donn"))
        XCTAssertEqual(encoded.removingPercentEncoding, "/volumes/données")
    }

    func testAnEmptyTargetIsNotACrash() {
        XCTAssertEqual(MinimalHTTP.percentEncodePath(""), "")
    }
}
