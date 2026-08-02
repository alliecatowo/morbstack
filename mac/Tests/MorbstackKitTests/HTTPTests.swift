// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Foundation
import XCTest

@testable import MorbstackKit

/// Coverage for the hand-rolled HTTP/1.1 pieces the port forwarder reads Docker with.
final class HTTPTests: XCTestCase {

    // MARK: - Response head

    func testParsesAStatusLineAndHeaders() throws {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n[]".utf8)
        let parsed = try XCTUnwrap(MinimalHTTP.parseHead(raw))
        XCTAssertEqual(parsed.head.statusCode, 200)
        XCTAssertEqual(parsed.head.reason, "OK")
        XCTAssertEqual(parsed.head.headers["content-type"], "application/json")
        XCTAssertEqual(parsed.head.contentLength, 2)
        XCTAssertFalse(parsed.head.isChunked)
        // `consumed` must land exactly on the body, or every byte is off by two.
        XCTAssertEqual(Data(raw.dropFirst(parsed.consumed)), Data("[]".utf8))
    }

    /// Header names are matched case-insensitively, and bare LF is accepted.
    func testToleratesBareLineFeedsAndHeaderCasing() throws {
        let raw = Data("HTTP/1.1 200 OK\nTRANSFER-Encoding: chunked\n\nbody".utf8)
        let parsed = try XCTUnwrap(MinimalHTTP.parseHead(raw))
        XCTAssertTrue(parsed.head.isChunked)
        XCTAssertEqual(Data(raw.dropFirst(parsed.consumed)), Data("body".utf8))
    }

    /// An empty reason phrase is legal and must not be mistaken for a bad status line.
    func testAcceptsAnEmptyReasonPhrase() throws {
        let parsed = try XCTUnwrap(MinimalHTTP.parseHead(Data("HTTP/1.1 500 \r\n\r\n".utf8)))
        XCTAssertEqual(parsed.head.statusCode, 500)
    }

    /// A head that has not fully arrived yields `nil` rather than a partial parse.
    func testIncompleteHeadReturnsNil() throws {
        XCTAssertNil(try MinimalHTTP.parseHead(Data("HTTP/1.1 200 OK\r\nContent-Len".utf8)))
    }

    func testRejectsAGarbageStatusLine() {
        XCTAssertThrowsError(try MinimalHTTP.parseHead(Data("NOT HTTP AT ALL\r\n\r\n".utf8)))
    }

    // MARK: - Chunked decoding

    func testDecodesASingleChunkedBody() throws {
        var decoder = ChunkedBodyDecoder()
        let body = try decoder.feed(Data("5\r\nhello\r\n0\r\n\r\n".utf8))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "hello")
        XCTAssertTrue(decoder.isComplete)
    }

    /// The decoder must never emit a chunk twice when the wire splits it, which is
    /// exactly what a byte-at-a-time delivery exercises.
    func testDecodesAcrossArbitrarySplits() throws {
        let wire = Array("4\r\nabcd\r\n6\r\nefghij\r\n0\r\n\r\n".utf8)
        var decoder = ChunkedBodyDecoder()
        var out = Data()
        for byte in wire {
            out.append(try decoder.feed(Data([byte])))
        }
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "abcdefghij")
        XCTAssertTrue(decoder.isComplete)
    }

    /// Docker's event stream never terminates, so the decoder has to keep producing
    /// without ever seeing a zero-length chunk.
    func testDecodesAnUnterminatedStreamIncrementally() throws {
        var decoder = ChunkedBodyDecoder()
        XCTAssertEqual(String(decoding: try decoder.feed(Data("3\r\none\r\n".utf8)), as: UTF8.self), "one")
        XCTAssertFalse(decoder.isComplete)
        XCTAssertEqual(String(decoding: try decoder.feed(Data("3\r\ntwo\r\n".utf8)), as: UTF8.self), "two")
        XCTAssertFalse(decoder.isComplete)
    }

    /// A chunk whose data has arrived but whose terminator has not must be withheld,
    /// otherwise the next feed emits it a second time.
    func testWithholdsAChunkUntilItsTerminatorArrives() throws {
        var decoder = ChunkedBodyDecoder()
        XCTAssertTrue(try decoder.feed(Data("5\r\nhello".utf8)).isEmpty)
        let out = try decoder.feed(Data("\r\n".utf8))
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "hello")
    }

    func testIgnoresChunkExtensions() throws {
        var decoder = ChunkedBodyDecoder()
        let body = try decoder.feed(Data("5;name=value\r\nhello\r\n0\r\n\r\n".utf8))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "hello")
    }

    func testAcceptsBareLineFeedFraming() throws {
        var decoder = ChunkedBodyDecoder()
        let body = try decoder.feed(Data("3\nabc\n0\n\n".utf8))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "abc")
        XCTAssertTrue(decoder.isComplete)
    }

    func testRejectsANonHexChunkSize() {
        var decoder = ChunkedBodyDecoder()
        XCTAssertThrowsError(try decoder.feed(Data("zz\r\nabc\r\n".utf8)))
    }

    // MARK: - Chunk size grammar

    /// `Int(_:radix:)` accepts a leading sign, so `-1` used to parse as a *negative*
    /// chunk length. `dataStart + size` then pointed before the start of the buffer
    /// and the slice trapped — a one-line remote kill of the daemon from anything
    /// that could answer on the Docker API socket. The grammar is `1*HEXDIG`, and
    /// nothing else may get through.
    func testRejectsASignedChunkSize() {
        XCTAssertNil(ChunkedBodyDecoder.parseChunkSize("-1"))
        XCTAssertNil(ChunkedBodyDecoder.parseChunkSize("+1"))
        XCTAssertNil(ChunkedBodyDecoder.parseChunkSize("-ff"))

        var decoder = ChunkedBodyDecoder()
        XCTAssertThrowsError(try decoder.feed(Data("-1\r\nabcdef\r\n".utf8))) { error in
            guard case MorbError.protocolViolation = error else {
                return XCTFail("expected a protocol violation, got \(error)")
            }
        }
    }

    func testChunkSizeGrammarEdgeCases() {
        // Empty, over-long, and outright junk are all rejected.
        XCTAssertNil(ChunkedBodyDecoder.parseChunkSize(""))
        XCTAssertNil(ChunkedBodyDecoder.parseChunkSize(";ext=1"))
        XCTAssertNil(ChunkedBodyDecoder.parseChunkSize("100000000"))  // nine digits
        XCTAssertNil(ChunkedBodyDecoder.parseChunkSize("0x10"))
        XCTAssertNil(ChunkedBodyDecoder.parseChunkSize("1 2"))
        XCTAssertNil(ChunkedBodyDecoder.parseChunkSize("nonsense"))
        // `isHexDigit` alone would accept these fullwidth digits, which
        // `Int(radix:)` then refuses; the two checks have to agree on ASCII.
        XCTAssertNil(ChunkedBodyDecoder.parseChunkSize("１"))

        // Valid: plain hex, either case, with and without an extension, at the
        // eight-digit ceiling.
        XCTAssertEqual(ChunkedBodyDecoder.parseChunkSize("0"), 0)
        XCTAssertEqual(ChunkedBodyDecoder.parseChunkSize("1;ext"), 1)
        XCTAssertEqual(ChunkedBodyDecoder.parseChunkSize("1;name=value"), 1)
        XCTAssertEqual(ChunkedBodyDecoder.parseChunkSize("aF"), 175)
        XCTAssertEqual(ChunkedBodyDecoder.parseChunkSize("ffffffff"), 4_294_967_295)
        // Leading/trailing whitespace around the size is tolerated, as some
        // servers emit it.
        XCTAssertEqual(ChunkedBodyDecoder.parseChunkSize(" 10 "), 16)
    }

    /// An implausibly large but *well-formed* size must simply withhold output until
    /// the data arrives, not throw and not trap.
    func testAnEnormousChunkSizeJustWaitsForData() throws {
        var decoder = ChunkedBodyDecoder()
        XCTAssertTrue(try decoder.feed(Data("ffffffff\r\nabc".utf8)).isEmpty)
        XCTAssertFalse(decoder.isComplete)
    }

    /// A zero-length chunk followed by trailer fields still ends the body.
    func testTrailerFieldsAreConsumed() throws {
        var decoder = ChunkedBodyDecoder()
        let body = try decoder.feed(Data("2\r\nhi\r\n0\r\nX-Trailer: yes\r\n\r\n".utf8))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "hi")
        XCTAssertTrue(decoder.isComplete)
    }

    // MARK: - Line accumulation

    func testLineAccumulatorKeepsPartialTrailingLines() {
        var accumulator = LineAccumulator()
        XCTAssertEqual(accumulator.feed(Data("{\"a\":1}\n{\"b\"".utf8)).count, 1)
        let second = accumulator.feed(Data(":2}\n".utf8))
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(String(decoding: second[0], as: UTF8.self), "{\"b\":2}")
    }

    func testLineAccumulatorSkipsBlankLines() {
        var accumulator = LineAccumulator()
        XCTAssertEqual(accumulator.feed(Data("\n\nx\n".utf8)).count, 1)
    }

    // MARK: - Query encoding

    /// The default `urlQueryAllowed` set leaves the JSON filter's punctuation alone,
    /// which dockerd then rejects; this is why the encoder is hand-rolled.
    func testPercentEncodesEverythingOutsideTheUnreservedSet() {
        let encoded = MinimalHTTP.percentEncodeQueryValue(#"{"type":["container"]}"#)
        XCTAssertEqual(encoded, "%7B%22type%22%3A%5B%22container%22%5D%7D")
        XCTAssertTrue(DockerAPIDecoding.eventsPath.hasSuffix(encoded))
    }

    func testRequestLineIsWellFormed() {
        let text = String(decoding: MinimalHTTP.request(method: "GET", path: "/x", closeWhenDone: true), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("GET /x HTTP/1.1\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
        let keepAlive = String(decoding: MinimalHTTP.request(method: "GET", path: "/x", closeWhenDone: false), as: UTF8.self)
        XCTAssertFalse(keepAlive.contains("Connection: close"))
    }
}
