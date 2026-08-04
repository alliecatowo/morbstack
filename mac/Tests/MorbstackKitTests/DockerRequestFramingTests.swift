// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Coverage for the HTTP/1.1 request framing that replaced the Docker proxy's
// inspect-the-first-request-then-splice behaviour.

import Darwin
import Dispatch
import Foundation
import XCTest

@testable import MorbstackKit

// MARK: - The framer on its own

final class DockerRequestFramerTests: XCTestCase {

    private func framer(_ script: [String]) -> DockerRequestFramer {
        DockerRequestFramer(source: .replaying(script.map { Data($0.utf8) }))
    }

    private func framer(_ script: [Data]) -> DockerRequestFramer {
        DockerRequestFramer(source: .replaying(script))
    }

    /// The bug, reduced to its smallest form: a connection carries more than one
    /// request, and the framer must produce every one of them.
    func testEveryRequestOnAReusedConnectionIsFramed() throws {
        let stream = """
            GET /_ping HTTP/1.1\r
            Host: morbstack\r
            \r
            POST /v1.47/containers/create HTTP/1.1\r
            Host: morbstack\r
            Content-Length: 9\r
            \r
            {"a":"b"}GET /_ping HTTP/1.1\r
            Host: morbstack\r
            \r

            """
        let framer = framer([stream])

        guard case .request(let ping) = framer.nextHead() else {
            return XCTFail("the first request must be framed")
        }
        XCTAssertEqual(ping.head.target, "/_ping")
        XCTAssertEqual(ping.framing, .empty)
        XCTAssertNil(framer.streamBody(ping.framing, to: .collecting(into: RelayByteBox())))

        guard case .request(let create) = framer.nextHead() else {
            return XCTFail("the SECOND request on a reused connection must also be framed")
        }
        XCTAssertEqual(create.head.target, "/v1.47/containers/create")
        XCTAssertEqual(create.framing, .fixed(9))
        guard case .success(let body) = create.bufferedBody(with: framer) else {
            return XCTFail("the create body must be readable")
        }
        XCTAssertEqual(String(decoding: body.decoded, as: UTF8.self), #"{"a":"b"}"#)

        guard case .request(let third) = framer.nextHead() else {
            return XCTFail("a third pipelined request must still be framed")
        }
        XCTAssertEqual(third.head.target, "/_ping")
        XCTAssertNil(framer.streamBody(third.framing, to: .collecting(into: RelayByteBox())))

        guard case .endOfStream = framer.nextHead() else {
            return XCTFail("a clean close on a request boundary is end of stream, not a failure")
        }
    }

    /// One byte per read is the worst case a local client can produce; the framer must
    /// not care where the segment boundaries fall.
    func testFramingSurvivesByteAtATimeDelivery() throws {
        let stream = Data(
            """
            POST /v1.47/containers/create HTTP/1.1\r
            Content-Length: 5\r
            \r
            hello
            """.utf8)
        let framer = framer(stream.map { Data([$0]) })

        guard case .request(let request) = framer.nextHead() else {
            return XCTFail("a dribbled head must still frame")
        }
        XCTAssertEqual(request.framing, .fixed(5))
        guard case .success(let body) = request.bufferedBody(with: framer) else {
            return XCTFail("a dribbled body must still frame")
        }
        XCTAssertEqual(String(decoding: body.decoded, as: UTF8.self), "hello")
    }

    func testChunkedBodyIsDecodedForInspectionAndPreservedForRelay() throws {
        let raw = """
            POST /v1.47/containers/create HTTP/1.1\r
            Transfer-Encoding: chunked\r
            \r
            5\r
            {"a":\r
            4\r
            "b"}\r
            0\r
            \r

            """
        let framer = framer([raw])
        guard case .request(let request) = framer.nextHead() else {
            return XCTFail("a chunked create must frame")
        }
        XCTAssertEqual(request.framing, .chunked)
        guard case .success(let body) = request.bufferedBody(with: framer) else {
            return XCTFail("a chunked create body must be readable")
        }
        XCTAssertEqual(String(decoding: body.decoded, as: UTF8.self), #"{"a":"b"}"#)
        // The raw form is what gets relayed, so it has to survive verbatim.
        XCTAssertEqual(
            String(decoding: body.raw, as: UTF8.self),
            "5\r\n{\"a\":\r\n4\r\n\"b\"}\r\n0\r\n\r\n")
    }

    /// A build context or a `docker cp` archive must reach the Engine byte for byte
    /// without the proxy ever holding it.
    func testLargeStreamedBodyIsForwardedByteForByte() throws {
        var payload = Data()
        for index in 0..<40_000 { payload.append(UInt8(index % 251)) }
        var stream = Data(
            """
            PUT /v1.47/containers/abc/archive?path=/ HTTP/1.1\r
            Content-Length: \(payload.count)\r
            \r

            """.utf8)
        stream.append(payload)

        let framer = framer([stream])
        guard case .request(let request) = framer.nextHead() else {
            return XCTFail("an archive PUT must frame")
        }
        let box = RelayByteBox()
        XCTAssertNil(framer.streamBody(request.framing, to: .collecting(into: box)))
        XCTAssertEqual(box.data, payload)
        guard case .endOfStream = framer.nextHead() else {
            return XCTFail("the stream ended on a boundary")
        }
    }

    func testChunkedBodyIsStreamedVerbatim() throws {
        let bodyText = "7\r\nchunk-1\r\n7\r\nchunk-2\r\n0\r\n\r\n"
        let framer = framer([
            "POST /v1.47/build HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" + bodyText
        ])
        guard case .request(let request) = framer.nextHead() else {
            return XCTFail("a chunked build must frame")
        }
        let box = RelayByteBox()
        XCTAssertNil(framer.streamBody(request.framing, to: .collecting(into: box)))
        XCTAssertEqual(String(decoding: box.data, as: UTF8.self), bodyText)
    }

    /// Every framing the proxy cannot resolve with certainty is refused rather than
    /// waved through. Combining the two length headers, or repeating one of them, is
    /// the classic request-smuggling desynchronisation.
    func testAmbiguousFramingIsRefusedRatherThanGuessed() {
        let combined = HTTPRequestHead(
            method: "POST", target: "/x",
            headers: ["content-length": "5", "transfer-encoding": "chunked"])
        XCTAssertEqual(
            DockerRequestFramer.bodyFraming(for: combined).failure, .conflictingFraming)

        // MinimalHTTP joins repeated headers with ", ", which is how a duplicate
        // Content-Length reaches this check.
        let duplicated = HTTPRequestHead(
            method: "POST", target: "/x", headers: ["content-length": "5, 6"])
        XCTAssertEqual(
            DockerRequestFramer.bodyFraming(for: duplicated).failure, .conflictingFraming)

        let exotic = HTTPRequestHead(
            method: "POST", target: "/x", headers: ["transfer-encoding": "gzip"])
        XCTAssertEqual(
            DockerRequestFramer.bodyFraming(for: exotic).failure,
            .unsupportedTransferEncoding("gzip"))

        let plain = HTTPRequestHead(method: "GET", target: "/_ping", headers: [:])
        XCTAssertEqual(try DockerRequestFramer.bodyFraming(for: plain).get(), .empty)
    }

    /// "Too big to inspect" must mean refused, not relayed unchecked.
    func testOversizedInspectableBodyReportsTooLargeInsteadOfPassingThrough() throws {
        let framer = framer([
            "POST /v1.47/containers/create HTTP/1.1\r\nContent-Length: 4096\r\n\r\n"
                + String(repeating: "x", count: 4096)
        ])
        guard case .request(let request) = framer.nextHead() else {
            return XCTFail("the create must frame")
        }
        guard case .failure(let failure) = framer.bufferBody(request.framing, limit: 1024) else {
            return XCTFail("a body over the inspection limit must not be handed back as inspected")
        }
        XCTAssertEqual(failure, .bodyTooLarge(limit: 1024))
    }

    func testOversizedHeadIsRefused() {
        let padding = String(repeating: "X-Pad: \(String(repeating: "y", count: 200))\r\n", count: 400)
        let framer = framer(["GET /_ping HTTP/1.1\r\n" + padding])
        guard case .failed(let failure) = framer.nextHead() else {
            return XCTFail("an unbounded head must be refused")
        }
        XCTAssertEqual(failure, .oversizedHead)
    }

    func testEndOfStreamMidRequestIsTruncationNotACleanClose() {
        let framer = framer(["POST /v1.47/containers/create HTTP/1.1\r\nContent-Len"])
        guard case .failed(let failure) = framer.nextHead() else {
            return XCTFail("a half-written head is truncation")
        }
        XCTAssertEqual(failure, .truncated)
    }

    func testGarbageIsRefusedRatherThanSplicedRaw() {
        let framer = framer(["\u{01}\u{02}not http at all\r\n\r\n"])
        guard case .failed(let failure) = framer.nextHead() else {
            return XCTFail("non-HTTP bytes must be refused")
        }
        guard case .malformedHead = failure else {
            return XCTFail("expected a malformed head, got \(failure)")
        }
    }

    func testPendingBytesSurviveTheHandoffToARawSplice() throws {
        let framer = framer([
            "POST /v1.47/exec/abc/start HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}STDIN-ALREADY-SENT"
        ])
        guard case .request(let request) = framer.nextHead() else {
            return XCTFail("the exec start must frame")
        }
        XCTAssertNil(framer.streamBody(request.framing, to: .collecting(into: RelayByteBox())))
        XCTAssertEqual(
            String(decoding: framer.takePendingBytes(), as: UTF8.self), "STDIN-ALREADY-SENT")
    }
}

// MARK: - Hijack classification

final class DockerHijackDetectionTests: XCTestCase {

    private func head(_ method: String, _ target: String, _ headers: [String: String] = [:]) -> HTTPRequestHead {
        HTTPRequestHead(method: method, target: target, headers: headers)
    }

    func testTheEndpointsThatTakeOverAConnectionAreNominated() {
        XCTAssertTrue(DockerHijackDetection.isHijackCandidate(
            head("POST", "/v1.47/containers/abc/attach?stream=1&stdin=1")))
        XCTAssertTrue(DockerHijackDetection.isHijackCandidate(
            head("GET", "/v1.47/containers/abc/attach/ws")))
        XCTAssertTrue(DockerHijackDetection.isHijackCandidate(
            head("POST", "/v1.47/exec/deadbeef/start")))
        XCTAssertTrue(DockerHijackDetection.isHijackCandidate(
            head("POST", "/v1.47/session", ["upgrade": "h2c"])))
        XCTAssertTrue(DockerHijackDetection.isHijackCandidate(
            head("POST", "/v1.47/anything", ["connection": "Upgrade"])))
    }

    /// Streaming responses are not hijacks: the connection stays HTTP, so framing must
    /// not be abandoned for them.
    func testStreamingEndpointsAreNotNominated() {
        XCTAssertFalse(DockerHijackDetection.isHijackCandidate(
            head("GET", "/v1.47/containers/abc/logs?follow=1")))
        XCTAssertFalse(DockerHijackDetection.isHijackCandidate(head("GET", "/v1.47/events")))
        XCTAssertFalse(DockerHijackDetection.isHijackCandidate(
            head("GET", "/v1.47/containers/abc/archive?path=/etc")))
        XCTAssertFalse(DockerHijackDetection.isHijackCandidate(
            head("POST", "/v1.47/containers/create")))
        XCTAssertFalse(DockerHijackDetection.isHijackCandidate(
            head("POST", "/v1.47/containers/abc/exec")))
        XCTAssertFalse(DockerHijackDetection.isHijackCandidate(
            head("GET", "/v1.47/exec/deadbeef/json")))
        XCTAssertFalse(DockerHijackDetection.isHijackCandidate(
            head("GET", "/v1.47/exec/deadbeef/start")))
    }

    func testOnlyTheEngineCanConfirmAHijack() {
        XCTAssertTrue(DockerHijackDetection.confirmsHijack(
            HTTPResponseHead(statusCode: 101, reason: "Switching Protocols", headers: [:])))
        XCTAssertTrue(DockerHijackDetection.confirmsHijack(
            HTTPResponseHead(
                statusCode: 200, reason: "OK",
                headers: ["content-type": "application/vnd.docker.raw-stream"])))
        XCTAssertTrue(DockerHijackDetection.confirmsHijack(
            HTTPResponseHead(
                statusCode: 200, reason: "OK",
                headers: ["content-type": "application/vnd.docker.multiplexed-stream"])))
        // A candidate that answers like ordinary HTTP goes back to being framed.
        XCTAssertFalse(DockerHijackDetection.confirmsHijack(
            HTTPResponseHead(
                statusCode: 404, reason: "Not Found",
                headers: ["content-type": "application/json"])))
        XCTAssertFalse(DockerHijackDetection.confirmsHijack(
            HTTPResponseHead(
                statusCode: 200, reason: "OK",
                headers: ["content-type": "application/json"])))
    }
}

final class HTTPRequestHeadRewritingTests: XCTestCase {

    func testExpectHeaderIsRemovedAndEverythingElseKept() throws {
        let head = Data("POST /x HTTP/1.1\r\nHost: m\r\nExpect: 100-continue\r\nContent-Length: 2\r\n\r\n".utf8)
        let stripped = try XCTUnwrap(HTTPRequestHeadRewriting.removingHeader(named: "expect", in: head))
        XCTAssertEqual(
            String(decoding: stripped, as: UTF8.self),
            "POST /x HTTP/1.1\r\nHost: m\r\nContent-Length: 2\r\n\r\n")
    }
}

// MARK: - The relay end to end

/// Records what the proxy policy was asked about, and answers a scripted verdict.
private final class RecordingPolicy: DockerRequestAdmissionPolicy {

    private let lock = NSLock()
    private var _seen: [(head: HTTPRequestHead, body: Data?)] = []
    private var _refusals: [String] = []
    private var _framingFailures: [String] = []

    var inspectBodyOf: (HTTPRequestHead) -> Bool = { _ in false }
    var verdict: (DockerRequestFramer.Request, Data?) -> DockerRequestAdmission = { _, _ in .forward }

    var seen: [(head: HTTPRequestHead, body: Data?)] {
        lock.lock()
        defer { lock.unlock() }
        return _seen
    }

    var refusals: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _refusals
    }

    var framingFailures: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _framingFailures
    }

    func requiresBodyInspection(_ head: HTTPRequestHead) -> Bool { inspectBodyOf(head) }

    func admit(_ request: DockerRequestFramer.Request, body: Data?) -> DockerRequestAdmission {
        lock.lock()
        _seen.append((request.head, body))
        lock.unlock()
        return verdict(request, body)
    }

    func requestWasRefused(_ message: String) {
        lock.lock()
        _refusals.append(message)
        lock.unlock()
    }

    func framingFailed(_ description: String) {
        lock.lock()
        _framingFailures.append(description)
        lock.unlock()
    }
}

final class DockerFramedRelayTests: XCTestCase {

    private var toClose: [Int32] = []
    private var policy = RecordingPolicy()

    override func setUp() {
        super.setUp()
        policy = RecordingPolicy()
    }

    override func tearDown() {
        for fd in toClose { close(fd) }
        toClose = []
        super.tearDown()
    }

    private func makePair() throws -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw XCTSkip("socketpair failed: \(String(cString: strerror(errno)))")
        }
        POSIXSocketSupport.suppressSIGPIPE(fds[0])
        POSIXSocketSupport.suppressSIGPIPE(fds[1])
        return (fds[0], fds[1])
    }

    /// Builds `clientOuter <-> [relay] <-> guestOuter` and returns the outer ends.
    private func makeRelay() throws -> (client: Int32, guest: Int32, relay: DockerFramedRelay, done: XCTestExpectation) {
        let (clientOuter, clientInner) = try makePair()
        let (guestInner, guestOuter) = try makePair()
        toClose.append(contentsOf: [clientOuter, guestOuter])
        let done = expectation(description: "relay completed")
        let relay = DockerFramedRelay(
            clientFD: clientInner,
            guestFD: guestInner,
            queue: DispatchQueue(label: "test.framed.relay"),
            policy: policy,
            log: MorbLog(fileURL: nil, echoToStderr: false)
        ) {
            done.fulfill()
        }
        relay.start()
        return (clientOuter, guestOuter, relay, done)
    }

    private func write(_ text: String, to fd: Int32) {
        XCTAssertTrue(POSIXSocketSupport.writeAll(fd, Data(text.utf8)))
    }

    private func write(_ data: Data, to fd: Int32) {
        XCTAssertTrue(POSIXSocketSupport.writeAll(fd, data))
    }

    private func readAvailable(_ fd: Int32, atLeast: Int, timeout: TimeInterval = 5) -> Data {
        var out = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while out.count < atLeast, Date() < deadline {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = max(1, Int32((deadline.timeIntervalSinceNow * 1000).rounded(.up)))
            guard withUnsafeMutablePointer(to: &poller, { poll($0, 1, remaining) }) > 0 else { break }
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                POSIXSocketSupport.readSome(fd, into: raw.baseAddress!, count: raw.count)
            }
            if count <= 0 { break }
            out.append(contentsOf: buffer[0..<count])
        }
        return out
    }

    private static let ping = "GET /_ping HTTP/1.1\r\nHost: morbstack\r\n\r\n"
    private static let pong = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"

    private static func createRequest(_ body: String) -> String {
        "POST /v1.47/containers/create HTTP/1.1\r\nHost: morbstack\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
    }

    private static func chunked(_ chunks: [Data]) -> Data {
        var wire = Data()
        for chunk in chunks {
            wire.append(Data(String(chunk.count, radix: 16).utf8))
            wire.append(Data("\r\n".utf8))
            wire.append(chunk)
            wire.append(Data("\r\n".utf8))
        }
        wire.append(Data("0\r\n\r\n".utf8))
        return wire
    }

    /// **The test whose absence let the defect ship.**
    ///
    /// A `docker` CLI invocation pings and then reuses the same connection for the
    /// real request. Before this change, only the ping was ever inspected and the
    /// create was spliced through unread. Both requests must reach the policy, and a
    /// refusal of the *second* one must stop it dead.
    func testSecondRequestOnAReusedConnectionIsInspectedAndCanBeRefused() throws {
        let body = #"{"Image":"alpine","HostConfig":{"Binds":["/etc/hosts:/x"]}}"#
        policy.inspectBodyOf = { $0.target.hasSuffix("/containers/create") }
        policy.verdict = { request, _ in
            request.head.target.hasSuffix("/containers/create")
                ? .reject(statusCode: 400, reason: "Bad Request", message: "bind source refused")
                : .forward
        }

        let wired = try makeRelay()

        write(Self.ping, to: wired.client)
        let relayedPing = readAvailable(wired.guest, atLeast: Self.ping.utf8.count)
        XCTAssertEqual(String(decoding: relayedPing, as: UTF8.self), Self.ping)
        write(Self.pong, to: wired.guest)
        _ = readAvailable(wired.client, atLeast: Self.pong.utf8.count)

        write(Self.createRequest(body), to: wired.client)
        let answer = readAvailable(wired.client, atLeast: 60)
        wait(for: [wired.done], timeout: 10)

        let answerText = String(decoding: answer, as: UTF8.self)
        XCTAssertTrue(answerText.hasPrefix("HTTP/1.1 400 Bad Request"), answerText)
        XCTAssertTrue(answerText.contains("bind source refused"), answerText)

        XCTAssertEqual(policy.seen.count, 2, "both requests on the connection must be inspected")
        XCTAssertEqual(policy.seen[0].head.target, "/_ping")
        XCTAssertNil(policy.seen[0].body)
        XCTAssertEqual(policy.seen[1].head.target, "/v1.47/containers/create")
        XCTAssertEqual(policy.seen[1].body.map { String(decoding: $0, as: UTF8.self) }, body)

        // The refused create must never have reached the Engine.
        let leaked = readAvailable(wired.guest, atLeast: 1, timeout: 0.5)
        XCTAssertEqual(leaked.count, 0, "a refused request must not reach dockerd")
    }

    /// The same assertion for the tenth request, so the fix is not "inspect two".
    func testEveryRequestInALongKeepAliveConversationIsInspected() throws {
        let wired = try makeRelay()
        for _ in 0..<10 {
            write(Self.ping, to: wired.client)
            _ = readAvailable(wired.guest, atLeast: Self.ping.utf8.count)
            write(Self.pong, to: wired.guest)
            _ = readAvailable(wired.client, atLeast: Self.pong.utf8.count)
        }
        XCTAssertEqual(policy.seen.count, 10)
        wired.relay.cancel()
        wait(for: [wired.done], timeout: 10)
    }

    /// A confirmed hijack must stop framing: raw stdin has to reach the Engine
    /// unmolested, and raw output has to come back.
    func testConfirmedHijackSplicesBothDirections() throws {
        let wired = try makeRelay()
        let start = "POST /v1.47/exec/abc/start HTTP/1.1\r\nContent-Length: 26\r\n\r\n"
            + #"{"Detach":false,"Tty":true}"#.prefix(26)
        write(String(start), to: wired.client)
        _ = readAvailable(wired.guest, atLeast: start.utf8.count)

        write(
            "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.docker.raw-stream\r\n\r\n",
            to: wired.guest)
        _ = readAvailable(wired.client, atLeast: 60)

        // Bytes that are emphatically not HTTP, in both directions.
        write("\u{00}\u{01}ls -la\n\u{7F}not-a-request", to: wired.client)
        let stdin = readAvailable(wired.guest, atLeast: 20)
        XCTAssertEqual(String(decoding: stdin, as: UTF8.self), "\u{00}\u{01}ls -la\n\u{7F}not-a-request")

        write("\u{01}\u{00}\u{00}\u{00}total 0\n", to: wired.guest)
        let stdout = readAvailable(wired.client, atLeast: 12)
        XCTAssertEqual(String(decoding: stdout, as: UTF8.self), "\u{01}\u{00}\u{00}\u{00}total 0\n")

        XCTAssertEqual(policy.framingFailures, [], "a hijacked connection must not be framed")
        wired.relay.cancel()
        wait(for: [wired.done], timeout: 10)
    }

    /// Attached non-TTY exec is the CLI's normal noninteractive path.  The create
    /// and inspect calls remain ordinary HTTP; only the successful start response
    /// hijacks the connection, where Docker multiplexes stdout and stderr with its
    /// eight-byte stream header.  Closing stdin must still leave the final output
    /// readable so the caller can then inspect its exit status on a new request.
    func testAttachedNonTTYExecPreservesMultiplexedOutputAfterClientHalfClose() throws {
        let wired = try makeRelay()
        let body = #"{"Detach":false,"Tty":false}"#
        let start = "POST /v1.47/exec/deadbeef/start HTTP/1.1\r\nHost: morbstack\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        write(start, to: wired.client)
        XCTAssertEqual(
            String(decoding: readAvailable(wired.guest, atLeast: start.utf8.count), as: UTF8.self),
            start)

        let stdout = Data([1, 0, 0, 0, 0, 0, 0, 3]) + Data("out".utf8)
        let stderr = Data([2, 0, 0, 0, 0, 0, 0, 3]) + Data("err".utf8)
        let upgraded = Data((
            "HTTP/1.1 101 UPGRADED\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n"
                + "Content-Type: application/vnd.docker.multiplexed-stream\r\n\r\n").utf8)
            + stdout + stderr
        write(upgraded, to: wired.guest)
        XCTAssertEqual(
            readAvailable(wired.client, atLeast: upgraded.count),
            upgraded,
            "the relay must neither decode nor discard Docker's stdout/stderr frames")

        shutdown(wired.client, SHUT_WR)
        var buffer = [UInt8](repeating: 0, count: 16)
        let eof = buffer.withUnsafeMutableBytes { raw -> Int in
            POSIXSocketSupport.readSome(wired.guest, into: raw.baseAddress!, count: raw.count)
        }
        XCTAssertEqual(eof, 0, "closing exec stdin must half-close only the Engine write side")

        let tail = Data([1, 0, 0, 0, 0, 0, 0, 5]) + Data("later".utf8)
        write(tail, to: wired.guest)
        shutdown(wired.guest, SHUT_WR)
        XCTAssertEqual(
            readAvailable(wired.client, atLeast: tail.count),
            tail,
            "the final non-TTY output must drain after stdin closes")
        XCTAssertEqual(policy.framingFailures, [])
        wait(for: [wired.done], timeout: 10)
    }

    /// Docker creates an exec, starts it, then inspects it to read its final exit
    /// status.  `create` and `json` must never be mistaken for a raw stream: both
    /// stay in the HTTP request loop and preserve their JSON bodies byte for byte.
    func testExecCreateAndInspectStayFramedOnAReusedConnection() throws {
        let wired = try makeRelay()
        let createBody = #"{"AttachStdin":false,"AttachStdout":true,"AttachStderr":true,"Tty":false,"Cmd":["sh","-c","exit 17"]}"#
        let create = "POST /v1.47/containers/abc/exec HTTP/1.1\r\nHost: morbstack\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(createBody.utf8.count)\r\n\r\n\(createBody)"
        write(create, to: wired.client)
        XCTAssertEqual(
            String(decoding: readAvailable(wired.guest, atLeast: create.utf8.count), as: UTF8.self),
            create)

        let createdBody = #"{"Id":"deadbeef"}"#
        let created = "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(createdBody.utf8.count)\r\n\r\n\(createdBody)"
        write(created, to: wired.guest)
        XCTAssertEqual(readAvailable(wired.client, atLeast: created.utf8.count), Data(created.utf8))

        let inspect = "GET /v1.47/exec/deadbeef/json HTTP/1.1\r\nHost: morbstack\r\n\r\n"
        write(inspect, to: wired.client)
        XCTAssertEqual(
            String(decoding: readAvailable(wired.guest, atLeast: inspect.utf8.count), as: UTF8.self),
            inspect)

        let inspectBody = #"{"ID":"deadbeef","Running":false,"ExitCode":17,"ProcessConfig":{"tty":false}}"#
        let inspected = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(inspectBody.utf8.count)\r\n\r\n\(inspectBody)"
        write(inspected, to: wired.guest)
        XCTAssertEqual(readAvailable(wired.client, atLeast: inspected.utf8.count), Data(inspected.utf8))

        XCTAssertEqual(policy.seen.map { $0.head.target }, [
            "/v1.47/containers/abc/exec",
            "/v1.47/exec/deadbeef/json",
        ])
        XCTAssertTrue(policy.seen.allSatisfy { $0.body == nil }, "exec bodies must stream through untouched")

        wired.relay.cancel()
        wait(for: [wired.done], timeout: 10)
    }

    /// A candidate the Engine answers with ordinary HTTP is not a hijack, and framing
    /// must resume — otherwise nominating candidates generously would cost inspection.
    func testUnconfirmedHijackCandidateResumesFraming() throws {
        let wired = try makeRelay()
        let attach = "POST /v1.47/containers/nope/attach?stream=1 HTTP/1.1\r\nContent-Length: 0\r\n\r\n"
        write(attach, to: wired.client)
        _ = readAvailable(wired.guest, atLeast: attach.utf8.count)

        let notFound = "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: 27\r\n\r\n"
            + #"{"message":"no such container"}"#.prefix(27)
        write(String(notFound), to: wired.guest)
        _ = readAvailable(wired.client, atLeast: notFound.utf8.count)

        write(Self.ping, to: wired.client)
        let relayed = readAvailable(wired.guest, atLeast: Self.ping.utf8.count)
        XCTAssertEqual(String(decoding: relayed, as: UTF8.self), Self.ping)
        XCTAssertEqual(policy.seen.count, 2, "framing must resume after an unconfirmed hijack")
        XCTAssertEqual(policy.seen[1].head.target, "/_ping")

        wired.relay.cancel()
        wait(for: [wired.done], timeout: 10)
    }

    /// `docker logs -f` and `docker events`: an endless response on a framed
    /// connection must simply flow.
    func testEndlessResponseStreamIsUnaffectedByFraming() throws {
        let wired = try makeRelay()
        let follow = "GET /v1.47/containers/abc/logs?follow=1&stdout=1 HTTP/1.1\r\n\r\n"
        write(follow, to: wired.client)
        _ = readAvailable(wired.guest, atLeast: follow.utf8.count)

        write("HTTP/1.1 200 OK\r\nContent-Type: application/vnd.docker.multiplexed-stream\r\n\r\n", to: wired.guest)
        _ = readAvailable(wired.client, atLeast: 70)
        for index in 0..<50 {
            write("line \(index)\n", to: wired.guest)
        }
        let streamed = readAvailable(wired.client, atLeast: 300)
        XCTAssertTrue(String(decoding: streamed, as: UTF8.self).contains("line 49"))

        wired.relay.cancel()
        wait(for: [wired.done], timeout: 10)
    }

    /// A large uninspected body must arrive byte for byte, which is what `docker cp`
    /// and a classic build context depend on.
    func testLargeUninspectedBodyIsRelayedVerbatim() throws {
        let wired = try makeRelay()
        var payload = Data()
        for index in 0..<200_000 { payload.append(UInt8(index % 251)) }
        var request = Data(
            "PUT /v1.47/containers/abc/archive?path=/tmp HTTP/1.1\r\nContent-Length: \(payload.count)\r\n\r\n".utf8)
        let headLength = request.count
        request.append(payload)

        let writer = DispatchQueue(label: "test.writer")
        writer.async { [client = wired.client] in
            _ = POSIXSocketSupport.writeAll(client, request)
        }
        let relayed = readAvailable(wired.guest, atLeast: request.count, timeout: 15)
        XCTAssertEqual(relayed.count, request.count)
        XCTAssertEqual(Data(relayed.dropFirst(headLength)), payload)

        wired.relay.cancel()
        wait(for: [wired.done], timeout: 10)
    }

    /// `docker cp` uploads a tar stream with `PUT /archive`, then downloads one with
    /// `GET /archive`. Neither direction has a JSON envelope for the proxy to own:
    /// chunk framing, tar bytes, and the path-stat response metadata must remain
    /// opaque. A following request proves the chunked upload did not desynchronise
    /// the shared HTTP/1.1 connection.
    func testChunkedContainerArchiveUploadAndDownloadStayByteExactOnKeepAlive() throws {
        let wired = try makeRelay()
        let tar = Data([
            0x75, 0x73, 0x74, 0x61, 0x72, 0x00, 0x0A, 0x00,
            0xFF, 0x00, 0x72, 0x61, 0x77, 0x0D, 0x0A, 0x62,
        ])
        let uploadBody = Self.chunked([
            Data(tar.prefix(5)),
            Data(tar.dropFirst(5)),
        ])
        var upload = Data((
            "PUT /v1.47/containers/abc/archive?path=%2Fwork HTTP/1.1\r\n"
                + "Host: morbstack\r\nContent-Type: application/x-tar\r\n"
                + "Transfer-Encoding: chunked\r\n\r\n").utf8)
        upload.append(uploadBody)
        write(upload, to: wired.client)
        XCTAssertEqual(
            readAvailable(wired.guest, atLeast: upload.count),
            upload,
            "a chunked tar upload must reach the Engine without decoding or re-chunking")

        let extracted = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
        write(extracted, to: wired.guest)
        XCTAssertEqual(readAvailable(wired.client, atLeast: extracted.utf8.count), Data(extracted.utf8))

        let download = Data((
            "GET /v1.47/containers/abc/archive?path=%2Fwork HTTP/1.1\r\n"
                + "Host: morbstack\r\n\r\n").utf8)
        write(download, to: wired.client)
        XCTAssertEqual(readAvailable(wired.guest, atLeast: download.count), download)

        let downloadedBody = Self.chunked([Data(tar.prefix(9)), Data(tar.dropFirst(9))])
        var downloaded = Data((
            "HTTP/1.1 200 OK\r\nContent-Type: application/x-tar\r\n"
                + "Transfer-Encoding: chunked\r\n"
                + "X-Docker-Container-Path-Stat: eyJuYW1lIjoid29yayJ9\r\n\r\n").utf8)
        downloaded.append(downloadedBody)
        write(downloaded, to: wired.guest)
        XCTAssertEqual(
            readAvailable(wired.client, atLeast: downloaded.count),
            downloaded,
            "a tar download and Docker's path-stat header must be relayed unchanged")

        write(Self.ping, to: wired.client)
        XCTAssertEqual(
            readAvailable(wired.guest, atLeast: Self.ping.utf8.count),
            Data(Self.ping.utf8),
            "the request after a chunked archive upload must remain framed")
        XCTAssertEqual(policy.seen.map { $0.head.target }, [
            "/v1.47/containers/abc/archive?path=%2Fwork",
            "/v1.47/containers/abc/archive?path=%2Fwork",
            "/_ping",
        ])
        XCTAssertTrue(policy.seen.allSatisfy { $0.body == nil }, "archive bodies must never be inspected")

        wired.relay.cancel()
        wait(for: [wired.done], timeout: 10)
    }

    /// The `FDRelay` half-close contract, preserved: the client closing its write half
    /// must not truncate the response still coming back.
    func testClientHalfCloseStillDrainsTheResponse() throws {
        let wired = try makeRelay()
        write(Self.ping, to: wired.client)
        _ = readAvailable(wired.guest, atLeast: Self.ping.utf8.count)
        shutdown(wired.client, SHUT_WR)

        // The guest must observe EOF on its side...
        var buffer = [UInt8](repeating: 0, count: 16)
        let eof = buffer.withUnsafeMutableBytes { raw -> Int in
            POSIXSocketSupport.readSome(wired.guest, into: raw.baseAddress!, count: raw.count)
        }
        XCTAssertEqual(eof, 0, "the half-close must propagate to the Engine")

        // ...and its response must still reach the client.
        let late = "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nlate"
        write(late, to: wired.guest)
        shutdown(wired.guest, SHUT_WR)
        let received = readAvailable(wired.client, atLeast: late.utf8.count)
        XCTAssertEqual(String(decoding: received, as: UTF8.self), late)

        wait(for: [wired.done], timeout: 10)
    }

    func testPlainRewrittenCreateReachesTheGuestAndKeepsTheConnectionFramed() throws {
        let originalBody = #"{"Image":"alpine","HostConfig":{"Binds":["/etc/hosts:/host"]}}"#
        let rewrittenBody = #"{"Image":"alpine","HostConfig":{"Binds":["/private/etc/hosts:/host"]}}"#
        policy.inspectBodyOf = { $0.target.hasSuffix("/containers/create") }
        policy.verdict = { request, _ in
            guard request.head.target.hasSuffix("/containers/create") else { return .forward }
            return .forwardRewritten(
                request: Data(
                    "POST /v1.47/containers/create HTTP/1.1\r\nContent-Length: \(rewrittenBody.utf8.count)\r\n\r\n\(rewrittenBody)".utf8))
        }

        let wired = try makeRelay()
        write(Self.createRequest(originalBody), to: wired.client)
        let relayed = readAvailable(wired.guest, atLeast: rewrittenBody.utf8.count)
        XCTAssertTrue(String(decoding: relayed, as: UTF8.self).hasSuffix(rewrittenBody))

        let created = #"{"Id":"abc123","Warnings":[]}"#
        write("HTTP/1.1 201 Created\r\nContent-Length: \(created.utf8.count)\r\n\r\n\(created)", to: wired.guest)
        XCTAssertTrue(String(decoding: readAvailable(wired.client, atLeast: 40), as: UTF8.self).contains("abc123"))

        write(Self.ping, to: wired.client)
        _ = readAvailable(wired.guest, atLeast: Self.ping.utf8.count)
        XCTAssertEqual(policy.seen.count, 2)

        wired.relay.cancel()
        wait(for: [wired.done], timeout: 10)
    }

    func testRewrittenInspectedCreateDoesNotRestoreAnAlreadyAnsweredExpectHeader() throws {
        let body = #"{"Image":"alpine"}"#
        policy.inspectBodyOf = { $0.target.hasSuffix("/containers/create") }
        policy.verdict = { request, inspectedBody in
            guard let inspectedBody else { return .forward }
            return .forwardRewritten(request: request.rawHead + inspectedBody)
        }

        let wired = try makeRelay()
        let head = "POST /v1.47/containers/create HTTP/1.1\r\nHost: m\r\nExpect: 100-continue\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n"
        write(head, to: wired.client)
        XCTAssertEqual(
            String(decoding: readAvailable(wired.client, atLeast: 25), as: UTF8.self),
            "HTTP/1.1 100 Continue\r\n\r\n")
        write(body, to: wired.client)

        let relayed = String(decoding: readAvailable(wired.guest, atLeast: body.utf8.count), as: UTF8.self)
        XCTAssertFalse(relayed.lowercased().contains("expect:"), relayed)
        XCTAssertTrue(relayed.hasSuffix(body), relayed)

        wired.relay.cancel()
        wait(for: [wired.done], timeout: 10)
    }

    func testObservedRewrittenCreateRetainsTheFixedPortResponseObserver() throws {
        let observed = expectation(description: "rewritten create observed")
        let body = #"{"Image":"alpine"}"#
        policy.inspectBodyOf = { $0.target.hasSuffix("/containers/create") }
        policy.verdict = { request, _ in
            guard request.head.target.hasSuffix("/containers/create") else { return .forward }
            return .forwardRewrittenObserving(
                request: Data(
                    "POST /v1.47/containers/create HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8),
                observer: DockerPortLeaseResponseObserver(kind: .create) { outcome in
                    if outcome == .created(containerID: "abc123") { observed.fulfill() }
                })
        }

        let wired = try makeRelay()
        write(Self.createRequest(body), to: wired.client)
        _ = readAvailable(wired.guest, atLeast: body.utf8.count)

        let created = #"{"Id":"abc123","Warnings":[]}"#
        write("HTTP/1.1 201 Created\r\nContent-Length: \(created.utf8.count)\r\n\r\n\(created)", to: wired.guest)
        XCTAssertTrue(String(decoding: readAvailable(wired.client, atLeast: 40), as: UTF8.self).contains("abc123"))
        wait(for: [observed], timeout: 5)

        wired.relay.cancel()
        wait(for: [wired.done], timeout: 10)
    }

    /// A rewritten create must have its response held back until the association
    /// callback has run — the client must not learn the container id first.
    func testHeldCreateAssociatesBeforeReleasingTheResponse() throws {
        let associated = RelayByteBox()
        let body = #"{"Image":"alpine"}"#
        policy.inspectBodyOf = { $0.target.hasSuffix("/containers/create") }
        policy.verdict = { request, _ in
            guard request.head.target.hasSuffix("/containers/create") else { return .forward }
            let rewritten = Data(
                "POST /v1.47/containers/create HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
            return .forwardRewrittenHoldingCreate(
                request: rewritten,
                hold: DockerHeldCreate(
                    associate: { containerID in
                        associated.append(Data(containerID.utf8))
                        return true
                    },
                    abandon: { _ in }))
        }

        let wired = try makeRelay()
        write(Self.createRequest(body), to: wired.client)
        _ = readAvailable(wired.guest, atLeast: 60)

        let created = #"{"Id":"abc123","Warnings":[]}"#
        write("HTTP/1.1 201 Created\r\nContent-Length: \(created.utf8.count)\r\n\r\n\(created)", to: wired.guest)
        let released = readAvailable(wired.client, atLeast: 40)
        XCTAssertTrue(String(decoding: released, as: UTF8.self).contains("abc123"))
        XCTAssertEqual(String(decoding: associated.data, as: UTF8.self), "abc123")

        // The connection stays framed afterwards, so a following start is inspected.
        write(Self.ping, to: wired.client)
        _ = readAvailable(wired.guest, atLeast: Self.ping.utf8.count)
        XCTAssertEqual(policy.seen.count, 2)

        wired.relay.cancel()
        wait(for: [wired.done], timeout: 10)
    }

    /// `Expect: 100-continue` on an inspected request is answered by the proxy so the
    /// body can be read, and the header is not forwarded twice.
    func testExpectContinueIsAnsweredSoTheBodyCanBeInspected() throws {
        let body = #"{"Image":"alpine"}"#
        policy.inspectBodyOf = { $0.target.hasSuffix("/containers/create") }

        let wired = try makeRelay()
        let head = "POST /v1.47/containers/create HTTP/1.1\r\nHost: m\r\nExpect: 100-continue\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n"
        write(head, to: wired.client)

        let interim = readAvailable(wired.client, atLeast: 25)
        XCTAssertEqual(String(decoding: interim, as: UTF8.self), "HTTP/1.1 100 Continue\r\n\r\n")

        write(body, to: wired.client)
        let relayed = readAvailable(wired.guest, atLeast: head.utf8.count)
        let relayedText = String(decoding: relayed, as: UTF8.self)
        XCTAssertFalse(relayedText.lowercased().contains("expect:"), relayedText)
        XCTAssertTrue(relayedText.hasSuffix(body), relayedText)
        XCTAssertEqual(policy.seen.first?.body.map { String(decoding: $0, as: UTF8.self) }, body)

        wired.relay.cancel()
        wait(for: [wired.done], timeout: 10)
    }

    /// A create too large to inspect is refused with a Docker-shaped error rather than
    /// relayed unchecked.
    func testUninspectableCreateIsRefusedNotWavedThrough() throws {
        policy.inspectBodyOf = { $0.target.hasSuffix("/containers/create") }

        let wired = try makeRelay()
        let oversize = DockerFramedRelay.maximumInspectableBodyBytes + 1
        write(
            "POST /v1.47/containers/create HTTP/1.1\r\nContent-Length: \(oversize)\r\n\r\n",
            to: wired.client)

        let answer = readAvailable(wired.client, atLeast: 60)
        let answerText = String(decoding: answer, as: UTF8.self)
        XCTAssertTrue(answerText.hasPrefix("HTTP/1.1 400 Bad Request"), answerText)
        XCTAssertTrue(answerText.contains("could not be admission-checked"), answerText)
        XCTAssertEqual(policy.seen.count, 0, "an unread body is not an inspected body")

        wait(for: [wired.done], timeout: 10)
    }
}

// MARK: - Small test conveniences

extension DockerRequestFramer.Request {
    /// Reads this request's body through `framer` with the production limit.
    func bufferedBody(
        with framer: DockerRequestFramer
    ) -> Result<(raw: Data, decoded: Data), DockerRequestFramer.Failure> {
        framer.bufferBody(framing, limit: DockerFramedRelay.maximumInspectableBodyBytes)
    }
}

extension Result {
    fileprivate var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
