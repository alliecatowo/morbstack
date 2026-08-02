// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Dispatch
import XCTest

@testable import MorbstackKit

/// Coverage for ``FDRelay``'s flush-then-half-close behaviour.
///
/// Both tests wire the relay between two `socketpair(2)`s so the test process holds
/// the outer end of each:
///
/// ```text
///   clientOuter <-> clientInner  [FDRelay]  guestInner <-> guestOuter
/// ```
///
/// which is exactly the shape of the real thing — an accepted `docker.sock`
/// connection on one side and a vsock connection to the guest on the other.
final class RelayTests: XCTestCase {

    private var toClose: [Int32] = []

    override func tearDown() {
        for fd in toClose { close(fd) }
        toClose = []
        super.tearDown()
    }

    /// Returns a connected pair of stream sockets.
    private func makePair() throws -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw XCTSkip("socketpair failed: \(String(cString: strerror(errno)))")
        }
        POSIXSocketSupport.suppressSIGPIPE(fds[0])
        POSIXSocketSupport.suppressSIGPIPE(fds[1])
        return (fds[0], fds[1])
    }

    /// Reads from `fd` until EOF or `limit` bytes, whichever comes first.
    private func readUntilEOF(_ fd: Int32, limit: Int) -> Data {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while out.count < limit {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                POSIXSocketSupport.readSome(fd, into: raw.baseAddress!, count: raw.count)
            }
            if n <= 0 { break }
            out.append(contentsOf: buffer[0..<n])
        }
        return out
    }

    /// A large response written just before the peer closes must arrive whole.
    ///
    /// This is the truncation bug in its natural habitat: `dockerd` writes the last
    /// chunk of a response and immediately closes, and a relay that tears both
    /// channels down on the first EOF drops whatever has not yet drained.
    func testPendingWritesAreFlushedBeforeTheCloseIsPropagated() throws {
        let (clientOuter, clientInner) = try makePair()
        let (guestOuter, guestInner) = try makePair()
        toClose.append(clientOuter)

        let finished = expectation(description: "relay finished")
        let relay = FDRelay(
            fdA: clientInner, fdB: guestInner,
            queue: DispatchQueue(label: "test.relay.flush")
        ) { finished.fulfill() }
        relay.start()

        // 1 MiB is comfortably more than any socket buffer, so the relay is forced to
        // still have writes in flight when the EOF arrives.
        let payloadSize = 1 << 20
        let payload = Data(repeating: 0x5A, count: payloadSize)

        DispatchQueue.global().async {
            _ = POSIXSocketSupport.writeAll(guestOuter, payload)
            close(guestOuter)
        }

        let received = readUntilEOF(clientOuter, limit: payloadSize)
        XCTAssertEqual(received.count, payloadSize, "the relay truncated the response")
        XCTAssertEqual(received, payload)

        // The client end is still open, so only one half has closed; closing it now
        // completes the teardown.
        close(clientOuter)
        toClose.removeAll { $0 == clientOuter }
        wait(for: [finished], timeout: 5)
    }

    /// A shutdown in one direction must not kill the other direction.
    func testHalfCloseLeavesTheOppositeDirectionUsable() throws {
        let (clientOuter, clientInner) = try makePair()
        let (guestOuter, guestInner) = try makePair()
        toClose.append(contentsOf: [clientOuter, guestOuter])

        let finished = expectation(description: "relay finished")
        let relay = FDRelay(
            fdA: clientInner, fdB: guestInner,
            queue: DispatchQueue(label: "test.relay.halfclose")
        ) { finished.fulfill() }
        relay.start()

        // Client sends its request, then signals "no more input from me".
        XCTAssertTrue(POSIXSocketSupport.writeAll(clientOuter, Data("GET /_ping\n".utf8)))
        XCTAssertEqual(shutdown(clientOuter, SHUT_WR), 0)

        // The guest sees the request followed by a clean EOF.
        var buffer = [UInt8](repeating: 0, count: 256)
        let requestLength = buffer.withUnsafeMutableBytes { raw -> Int in
            POSIXSocketSupport.readSome(guestOuter, into: raw.baseAddress!, count: 11)
        }
        XCTAssertEqual(requestLength, 11)
        let eof = buffer.withUnsafeMutableBytes { raw -> Int in
            POSIXSocketSupport.readSome(guestOuter, into: raw.baseAddress!, count: raw.count)
        }
        XCTAssertEqual(eof, 0, "the relay should have half-closed the guest's write side")

        // Crucially, the guest can still answer: the reverse direction is untouched.
        let response = Data("HTTP/1.1 200 OK\r\n\r\nOK".utf8)
        XCTAssertTrue(POSIXSocketSupport.writeAll(guestOuter, response))
        let received = readUntilEOF(clientOuter, limit: response.count)
        XCTAssertEqual(received, response)

        // Closing the guest end retires the second half and finishes the relay.
        close(guestOuter)
        toClose.removeAll { $0 == guestOuter }
        wait(for: [finished], timeout: 5)
    }

    /// A small final write followed immediately by a close must reach the peer *and*
    /// be followed by an EOF.
    ///
    /// This is the shape of every short Docker API response: dockerd writes a few
    /// hundred bytes and closes in the same breath, and a client reading a response
    /// with no Content-Length only knows it is finished when the stream ends.
    ///
    /// Note this does **not** discriminate the `done`-carrying-data case the relay now
    /// guards against: Darwin's `DispatchIO` currently always signals `done` in a
    /// separate empty delivery, so the old `done && data.isEmpty` condition passes
    /// here too. It is a regression guard for EOF propagation, not a reproduction.
    func testEOFCarryingTheFinalBytesStillHalfCloses() throws {
        let (clientOuter, clientInner) = try makePair()
        let (guestOuter, guestInner) = try makePair()
        toClose.append(clientOuter)

        let finished = expectation(description: "relay finished")
        let relay = FDRelay(
            fdA: clientInner, fdB: guestInner,
            queue: DispatchQueue(label: "test.relay.eofwithdata")
        ) { finished.fulfill() }
        relay.start()

        let payload = Data("HTTP/1.1 200 OK\r\n\r\nhi".utf8)
        XCTAssertTrue(POSIXSocketSupport.writeAll(guestOuter, payload))
        close(guestOuter)

        let sawEOF = expectation(description: "client saw EOF")
        var received = Data()
        DispatchQueue.global().async {
            received = self.readUntilEOF(clientOuter, limit: 1 << 20)
            sawEOF.fulfill()
        }
        wait(for: [sawEOF], timeout: 5)
        XCTAssertEqual(received, payload)

        close(clientOuter)
        toClose.removeAll { $0 == clientOuter }
        wait(for: [finished], timeout: 5)
    }

    /// ``FDRelay/cancel()`` still fires the completion exactly once.
    func testCancelFiresTheCompletionOnce() throws {
        let (clientOuter, clientInner) = try makePair()
        let (guestOuter, guestInner) = try makePair()
        toClose.append(contentsOf: [clientOuter, guestOuter])

        let finished = expectation(description: "relay finished")
        finished.assertForOverFulfill = true
        let relay = FDRelay(
            fdA: clientInner, fdB: guestInner,
            queue: DispatchQueue(label: "test.relay.cancel")
        ) { finished.fulfill() }
        relay.start()
        relay.cancel()
        relay.cancel()
        wait(for: [finished], timeout: 5)
    }
}
