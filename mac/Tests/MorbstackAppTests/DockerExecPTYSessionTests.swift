// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

// Coverage for the interactive `docker exec` transport: the hijacked start
// connection, resize coalescing, the non-TTY demultiplexed shape, and exit reporting.
//
// `DockerExecPTYSession` dials a real unix socket (`UnixSocketClient.connect`, exactly
// like `DockerClient` does), so a fake has to be a real listener rather than a mock
// object substituted for the client. `FakeExecEngine` binds one under `/tmp` — not the
// scratchpad, and not a long descriptive name — because `sun_path` on Darwin has a
// 104-byte ceiling and a temp directory's own path already eats a third of it.

import Darwin
import Dispatch
import Foundation
import MorbstackKit
import XCTest

@testable import MorbstackAppCore

// MARK: - Fake engine

/// A scripted Docker Engine for exactly the calls an exec session makes: `POST
/// .../exec` (create), `POST /exec/{id}/start` (the hijack), `POST /exec/{id}/resize`,
/// `GET /exec/{id}/json` (inspect), and `GET /containers/{id}/json`. Each is its own
/// connection — `DockerClient`'s one-shot calls always are — so the fake simply hands
/// every accepted connection to the test in the order it arrives and lets the test
/// drive the read/write bytes directly, the same discipline
/// `DockerRequestFramingTests` uses for the proxy's own socket pairs.
final class FakeExecEngine {
    let socketPath: String
    private let directory: String
    private let server: UnixSocketServer
    private let lock = NSLock()
    private var pending: [Int32] = []
    private let semaphore = DispatchSemaphore(value: 0)

    init() throws {
        var template = Array("/tmp/morbexec.XXXXXX".utf8CString)
        let bound = template.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let base = buffer.baseAddress else { return nil }
            guard mkdtemp(base) != nil else { return nil }
            return String(cString: base)
        }
        guard let directory = bound else {
            throw MorbError.io("mkdtemp failed: \(String(cString: strerror(errno)))")
        }
        self.directory = directory
        self.socketPath = directory + "/e.sock"
        self.server = UnixSocketServer(path: socketPath, queue: DispatchQueue(label: "test.fake.exec.engine"))
        server.onConnection = { [weak self] fd in
            guard let self else { return }
            self.lock.lock()
            self.pending.append(fd)
            self.lock.unlock()
            self.semaphore.signal()
        }
        try server.start()
    }

    /// The next accepted connection, in arrival order. `nil` on timeout — used both to
    /// fetch an expected connection and, deliberately, to confirm one never arrives.
    func nextConnection(timeout: TimeInterval = 5) -> Int32? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return pending.isEmpty ? nil : pending.removeFirst()
    }

    func stop() {
        server.stop()
        try? FileManager.default.removeItem(atPath: directory)
    }
}

// MARK: - Raw HTTP helpers over an accepted fd

/// Reads one HTTP/1.1 request head plus its `Content-Length` body from a raw,
/// already-accepted descriptor. Bounded by `timeout` via `poll(2)` rather than the
/// blocking reads the production code uses, because a test that hangs forever on a
/// script it got wrong is a worse failure mode than one that times out with a message.
private func recvRequest(_ fd: Int32, timeout: TimeInterval = 5) -> (head: HTTPRequestHead, body: Data)? {
    var buffer = Data()
    var head: HTTPRequestHead?
    var consumed = 0
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
        if head != nil {
            let bodyLength = head!.headers["content-length"].flatMap(Int.init) ?? 0
            if buffer.count - consumed >= bodyLength {
                let body = buffer.subdata(in: (buffer.startIndex + consumed)..<(buffer.startIndex + consumed + bodyLength))
                return (head!, body)
            }
        }
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let remainingMs = max(1, Int32((deadline.timeIntervalSinceNow * 1000).rounded(.up)))
        let pollResult = withUnsafeMutablePointer(to: &poller, { poll($0, 1, remainingMs) })
        guard pollResult > 0 else { break }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = chunk.withUnsafeMutableBytes { raw -> Int in
            POSIXSocketSupport.readSome(fd, into: raw.baseAddress!, count: raw.count)
        }
        guard n > 0 else { break }
        buffer.append(contentsOf: chunk[0..<n])
        if head == nil, let parsed = try? MinimalHTTP.parseRequestHead(buffer) {
            head = parsed.head
            consumed = parsed.consumed
        }
    }
    return nil
}

/// Builds one HTTP/1.1 response. `extraBytes` lets a test append stream output to the
/// exact same `write(2)` as the head, which is the only way to reproduce "the engine's
/// first output arrived in the same read as the hijack confirmation".
private func httpResponse(
    status: Int, reason: String, headers: [String: String] = [:], body: Data = Data(), extraBytes: Data = Data()
) -> Data {
    var text = "HTTP/1.1 \(status) \(reason)\r\n"
    var sawContentLength = false
    for (name, value) in headers {
        text += "\(name): \(value)\r\n"
        if name.lowercased() == "content-length" { sawContentLength = true }
    }
    if !sawContentLength { text += "Content-Length: \(body.count)\r\n" }
    text += "\r\n"
    return Data(text.utf8) + body + extraBytes
}

/// Reads whatever arrives on `fd` within `timeout`, stopping as soon as `atLeast` bytes
/// have accumulated. `0` bytes with no timeout elapsed but the poll seeing HUP/EOF is
/// reported the same as a plain empty read — both mean "nothing more is coming".
private func readAvailable(_ fd: Int32, atLeast: Int = 1, timeout: TimeInterval = 5) -> Data {
    var out = Data()
    let deadline = Date().addingTimeInterval(timeout)
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while out.count < atLeast, Date() < deadline {
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let remainingMs = max(1, Int32((deadline.timeIntervalSinceNow * 1000).rounded(.up)))
        guard withUnsafeMutablePointer(to: &poller, { poll($0, 1, remainingMs) }) > 0 else { break }
        let n = buffer.withUnsafeMutableBytes { raw -> Int in
            POSIXSocketSupport.readSome(fd, into: raw.baseAddress!, count: raw.count)
        }
        if n <= 0 { break }
        out.append(contentsOf: buffer[0..<n])
    }
    return out
}

/// Parses `h=` and `w=` off a resize request's query string.
private func resizeQuery(_ target: String) -> (h: Int, w: Int)? {
    guard let mark = target.firstIndex(of: "?") else { return nil }
    var h: Int?
    var w: Int?
    for pair in target[target.index(after: mark)...].split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { continue }
        if parts[0] == "h" { h = Int(parts[1]) }
        if parts[0] == "w" { w = Int(parts[1]) }
    }
    guard let h, let w else { return nil }
    return (h, w)
}

// MARK: - Collected callbacks

/// Everything a test needs to observe from a session's callbacks, behind one lock —
/// the callbacks fire on `callbackQueue` (a background queue in these tests, since
/// `.main` never spins during `XCTestCase`), which is a different thread than the one
/// driving the fake engine.
private final class SessionObserver: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var output = Data()
    private(set) var stderrOutput = Data()
    private(set) var started = false
    private(set) var terminations: [DockerExecPTYSession.TerminationReason] = []

    let startedExpectation = XCTestExpectation(description: "started")
    let terminationExpectation = XCTestExpectation(description: "terminated")

    func attach(to session: DockerExecPTYSession) {
        session.onOutput = { [weak self] data in
            guard let self else { return }
            self.lock.lock()
            self.output.append(data)
            self.lock.unlock()
        }
        session.onStderr = { [weak self] data in
            guard let self else { return }
            self.lock.lock()
            self.stderrOutput.append(data)
            self.lock.unlock()
        }
        session.onStarted = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.started = true
            self.lock.unlock()
            self.startedExpectation.fulfill()
        }
        session.onTermination = { [weak self] reason in
            guard let self else { return }
            self.lock.lock()
            self.terminations.append(reason)
            self.lock.unlock()
            self.terminationExpectation.fulfill()
        }
    }

    func snapshotOutput() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return output
    }

    func snapshotStderr() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return stderrOutput
    }

    func snapshotTerminations() -> [DockerExecPTYSession.TerminationReason] {
        lock.lock()
        defer { lock.unlock() }
        return terminations
    }

    func waitForOutput(atLeast count: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if snapshotOutput().count >= count { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return snapshotOutput().count >= count
    }
}

// MARK: - Tests

final class DockerExecPTYSessionTests: XCTestCase {

    private var engine: FakeExecEngine!
    private var client: DockerClient!

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = try FakeExecEngine()
        client = DockerClient(socketPath: engine.socketPath)
    }

    override func tearDown() {
        engine.stop()
        engine = nil
        client = nil
        super.tearDown()
    }

    private func makeSession(tty: Bool, command: [String] = ["/bin/sh"]) -> DockerExecPTYSession {
        DockerExecPTYSession(
            client: client,
            options: .init(containerID: "c1", command: command, tty: tty, initialColumns: 80, initialRows: 24),
            callbackQueue: DispatchQueue(label: "test.exec.callbacks"))
    }

    /// Services the `POST .../containers/{id}/exec` create call, answering the given
    /// exec ID.
    private func serviceCreate(execID: String, timeout: TimeInterval = 5) throws {
        guard let fd = engine.nextConnection(timeout: timeout) else {
            return XCTFail("the create request never arrived")
        }
        defer { Darwin.close(fd) }
        guard let request = recvRequest(fd) else {
            return XCTFail("could not read the create request")
        }
        XCTAssertEqual(request.head.method, "POST")
        XCTAssertTrue(request.head.target.hasSuffix("/containers/c1/exec"), request.head.target)
        let body = Data(#"{"Id":"\#(execID)"}"#.utf8)
        XCTAssertTrue(POSIXSocketSupport.writeAll(fd, httpResponse(status: 201, reason: "Created", body: body)))
    }

    /// Services the hijacked `POST /exec/{id}/start`, asserting the Upgrade headers and
    /// body the CLI itself would send, then answers with `responseHead` (plus any
    /// `extraBytes` written in the very same packet). Returns the live fd for the test
    /// to keep driving.
    @discardableResult
    private func serviceStart(
        execID: String, tty: Bool, statusLine: (Int, String), headers: [String: String], extraBytes: Data = Data(),
        timeout: TimeInterval = 5
    ) throws -> Int32 {
        guard let fd = engine.nextConnection(timeout: timeout) else {
            XCTFail("the start request never arrived")
            return -1
        }
        guard let request = recvRequest(fd) else {
            XCTFail("could not read the start request")
            return fd
        }
        XCTAssertEqual(request.head.method, "POST")
        XCTAssertTrue(request.head.target.hasSuffix("/exec/\(execID)/start"), request.head.target)
        XCTAssertEqual(request.head.headers["connection"], "Upgrade")
        XCTAssertEqual(request.head.headers["upgrade"], "tcp")
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), #"{"Detach":false,"Tty":\#(tty)}"#)

        let response = httpResponse(status: statusLine.0, reason: statusLine.1, headers: headers, extraBytes: extraBytes)
        XCTAssertTrue(POSIXSocketSupport.writeAll(fd, response))
        return fd
    }

    /// Services one `/exec/{id}/resize` call, asserting the `h=rows&w=columns` mapping,
    /// and answers with a bare `200`.
    @discardableResult
    private func serviceResize(execID: String, expected: (columns: Int, rows: Int), timeout: TimeInterval = 5) -> (h: Int, w: Int)? {
        guard let fd = engine.nextConnection(timeout: timeout) else { return nil }
        defer { Darwin.close(fd) }
        guard let request = recvRequest(fd) else {
            XCTFail("could not read a resize request")
            return nil
        }
        XCTAssertTrue(request.head.target.contains("/exec/\(execID)/resize"), request.head.target)
        let query = resizeQuery(request.head.target)
        XCTAssertEqual(query?.h, expected.rows, "h must carry rows")
        XCTAssertEqual(query?.w, expected.columns, "w must carry columns")
        XCTAssertTrue(POSIXSocketSupport.writeAll(fd, httpResponse(status: 200, reason: "OK")))
        return query
    }

    /// Services `GET /exec/{id}/json`, answering the given running/exit-code shape.
    private func serviceInspect(execID: String, running: Bool, exitCode: Int?, timeout: TimeInterval = 5) {
        guard let fd = engine.nextConnection(timeout: timeout) else {
            return XCTFail("the inspect request never arrived")
        }
        defer { Darwin.close(fd) }
        guard let request = recvRequest(fd) else {
            return XCTFail("could not read the inspect request")
        }
        XCTAssertTrue(request.head.target.hasSuffix("/exec/\(execID)/json"), request.head.target)
        var fields = [#""Running":\#(running)"#]
        if let exitCode { fields.append(#""ExitCode":\#(exitCode)"#) }
        let body = Data("{\(fields.joined(separator: ","))}".utf8)
        XCTAssertTrue(POSIXSocketSupport.writeAll(fd, httpResponse(status: 200, reason: "OK", body: body)))
    }

    /// Services `GET /containers/{id}/json`, answering `State.Running`.
    private func serviceContainerRunning(running: Bool, timeout: TimeInterval = 5) {
        guard let fd = engine.nextConnection(timeout: timeout) else {
            return XCTFail("the container inspect request never arrived")
        }
        defer { Darwin.close(fd) }
        guard let request = recvRequest(fd) else {
            return XCTFail("could not read the container inspect request")
        }
        XCTAssertTrue(request.head.target.hasSuffix("/containers/c1/json"), request.head.target)
        let body = Data(#"{"State":{"Running":\#(running)}}"#.utf8)
        XCTAssertTrue(POSIXSocketSupport.writeAll(fd, httpResponse(status: 200, reason: "OK", body: body)))
    }

    // MARK: 1. Happy path TTY

    func testHappyPathTTYWithLeftoverBytesEchoAndCleanExit() throws {
        let execID = "exec-tty-1"
        let observer = SessionObserver()
        let session = makeSession(tty: true)
        observer.attach(to: session)

        session.start()
        try serviceCreate(execID: execID)
        let startFD = try serviceStart(
            execID: execID, tty: true,
            statusLine: (101, "UPGRADED"),
            headers: ["Connection": "Upgrade", "Upgrade": "tcp"],
            extraBytes: Data("hello\r\n".utf8))
        defer { Darwin.close(startFD) }

        wait(for: [observer.startedExpectation], timeout: 5)
        _ = serviceResize(execID: execID, expected: (columns: 80, rows: 24))

        XCTAssertTrue(observer.waitForOutput(atLeast: 7), "the leftover bytes after the 101 head must reach onOutput")
        XCTAssertEqual(String(decoding: observer.snapshotOutput(), as: UTF8.self), "hello\r\n")

        session.send(Data("echo\n".utf8))
        let echoed = readAvailable(startFD, atLeast: 5)
        XCTAssertEqual(String(decoding: echoed, as: UTF8.self), "echo\n")

        XCTAssertTrue(POSIXSocketSupport.writeAll(startFD, Data("more\r\n".utf8)))
        XCTAssertTrue(observer.waitForOutput(atLeast: 13))
        XCTAssertEqual(String(decoding: observer.snapshotOutput(), as: UTF8.self), "hello\r\nmore\r\n")

        Darwin.close(startFD)
        serviceInspect(execID: execID, running: false, exitCode: 0)

        wait(for: [observer.terminationExpectation], timeout: 5)
        XCTAssertEqual(observer.snapshotTerminations(), [.exited(code: 0)])
    }

    // MARK: 2. 200 + raw-stream content type

    func testTwoHundredWithRawStreamContentTypeConfirmsTheHijack() throws {
        let execID = "exec-tty-2"
        let observer = SessionObserver()
        let session = makeSession(tty: true)
        observer.attach(to: session)

        session.start()
        try serviceCreate(execID: execID)
        let startFD = try serviceStart(
            execID: execID, tty: true,
            statusLine: (200, "OK"),
            headers: ["Content-Type": "application/vnd.docker.raw-stream"])
        defer { Darwin.close(startFD) }

        wait(for: [observer.startedExpectation], timeout: 5)
        _ = serviceResize(execID: execID, expected: (columns: 80, rows: 24))

        session.close()
        XCTAssertEqual(readAvailable(startFD, atLeast: 1, timeout: 2).count, 0, "close() must half-close the socket")
        wait(for: [observer.terminationExpectation], timeout: 5)
        XCTAssertEqual(observer.snapshotTerminations(), [.closedByUser])
    }

    // MARK: 3. Refusal

    func testRefusedStartReportsTheEnginesMessageAndNeverFiresOnStarted() throws {
        let execID = "exec-refused"
        let observer = SessionObserver()
        let session = makeSession(tty: true)
        observer.attach(to: session)
        observer.startedExpectation.isInverted = true

        session.start()
        try serviceCreate(execID: execID)
        let message = "container not running"
        let body = Data(#"{"message":"\#(message)"}"#.utf8)
        guard let fd = engine.nextConnection() else { return XCTFail("the start request never arrived") }
        defer { Darwin.close(fd) }
        guard recvRequest(fd) != nil else { return XCTFail("could not read the start request") }
        XCTAssertTrue(POSIXSocketSupport.writeAll(fd, httpResponse(status: 409, reason: "Conflict", body: body)))

        wait(for: [observer.terminationExpectation, observer.startedExpectation], timeout: 5)
        guard case .transportFailure(let reported)? = observer.snapshotTerminations().first else {
            return XCTFail("expected a transport failure, got \(observer.snapshotTerminations())")
        }
        XCTAssertTrue(reported.contains(message), reported)
    }

    // MARK: 4. Non-TTY demux

    func testNonTTYDemultiplexesInterleavedAndSplitFrames() throws {
        let execID = "exec-nontty"
        let observer = SessionObserver()
        let session = makeSession(tty: false)
        observer.attach(to: session)

        session.start()
        try serviceCreate(execID: execID)
        let startFD = try serviceStart(
            execID: execID, tty: false,
            statusLine: (101, "UPGRADED"),
            headers: ["Connection": "Upgrade", "Upgrade": "tcp"])
        defer { Darwin.close(startFD) }
        wait(for: [observer.startedExpectation], timeout: 5)

        // A stdout frame delivered in two writes (the header and part of the payload
        // in one, the rest of the payload in a second) — the segmentation a real TCP
        // stream can impose at any byte boundary.
        let stdoutPayload = Data("hello".utf8)
        var stdoutHeader = Data([1, 0, 0, 0])
        withUnsafeBytes(of: UInt32(stdoutPayload.count).bigEndian) { stdoutHeader.append(contentsOf: $0) }
        XCTAssertTrue(POSIXSocketSupport.writeAll(startFD, stdoutHeader + stdoutPayload.prefix(2)))
        XCTAssertTrue(POSIXSocketSupport.writeAll(startFD, stdoutPayload.dropFirst(2)))

        let stderrPayload = Data("world".utf8)
        var stderrHeader = Data([2, 0, 0, 0])
        withUnsafeBytes(of: UInt32(stderrPayload.count).bigEndian) { stderrHeader.append(contentsOf: $0) }
        XCTAssertTrue(POSIXSocketSupport.writeAll(startFD, stderrHeader + stderrPayload))

        XCTAssertTrue(observer.waitForOutput(atLeast: 5))
        XCTAssertEqual(String(decoding: observer.snapshotOutput(), as: UTF8.self), "hello")

        let stderrDeadline = Date().addingTimeInterval(5)
        while observer.snapshotStderr().count < 5, Date() < stderrDeadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(String(decoding: observer.snapshotStderr(), as: UTF8.self), "world")

        Darwin.close(startFD)
        serviceInspect(execID: execID, running: false, exitCode: 0)
        wait(for: [observer.terminationExpectation], timeout: 5)
        XCTAssertEqual(observer.snapshotTerminations(), [.exited(code: 0)])
    }

    // MARK: 5. closeStdin half-close

    func testCloseStdinHalfClosesWriteButLeavesOutputDraining() throws {
        let execID = "exec-halfclose"
        let observer = SessionObserver()
        let session = makeSession(tty: true)
        observer.attach(to: session)

        session.start()
        try serviceCreate(execID: execID)
        let startFD = try serviceStart(
            execID: execID, tty: true,
            statusLine: (101, "UPGRADED"),
            headers: ["Connection": "Upgrade", "Upgrade": "tcp"])
        defer { Darwin.close(startFD) }
        wait(for: [observer.startedExpectation], timeout: 5)
        _ = serviceResize(execID: execID, expected: (columns: 80, rows: 24))

        session.closeStdin()
        let eof = readAvailable(startFD, atLeast: 1, timeout: 2)
        XCTAssertEqual(eof.count, 0, "closeStdin() must reach the engine as a write-side EOF")

        // The read side must still be open: output written after the half-close has to
        // reach the terminal, which is the entire point of a piped `exec -i`.
        XCTAssertTrue(POSIXSocketSupport.writeAll(startFD, Data("final output\n".utf8)))
        XCTAssertTrue(observer.waitForOutput(atLeast: 13))
        XCTAssertEqual(String(decoding: observer.snapshotOutput(), as: UTF8.self), "final output\n")

        Darwin.close(startFD)
        serviceInspect(execID: execID, running: false, exitCode: 0)
        wait(for: [observer.terminationExpectation], timeout: 5)
        XCTAssertEqual(observer.snapshotTerminations(), [.exited(code: 0)])
    }

    // MARK: 6. Resize coalescing

    func testRapidResizesCoalesceToTheLastRequestedSize() throws {
        let execID = "exec-resize"
        let observer = SessionObserver()
        let session = makeSession(tty: true)
        observer.attach(to: session)

        session.start()
        try serviceCreate(execID: execID)
        let startFD = try serviceStart(
            execID: execID, tty: true,
            statusLine: (101, "UPGRADED"),
            headers: ["Connection": "Upgrade", "Upgrade": "tcp"])
        defer { Darwin.close(startFD) }
        wait(for: [observer.startedExpectation], timeout: 5)
        _ = serviceResize(execID: execID, expected: (columns: 80, rows: 24))

        // Fired back to back, faster than any one round trip to the "engine" can
        // complete. Whether the in-flight initial resize has settled by the time these
        // run is a genuine race — the coalescer's contract only promises that whatever
        // arrives, the *last* size requested is the last one sent, and that no more
        // than a couple of calls happen in between.
        session.resize(columns: 100, rows: 30)
        session.resize(columns: 110, rows: 32)
        session.resize(columns: 120, rows: 40)

        var seen: [(h: Int, w: Int)] = []
        while let query = serviceResize(execID: execID, expected: (columns: 120, rows: 40), timeout: 2) {
            seen.append(query)
            if seen.count >= 4 { break }  // a runaway coalescer would hang the test otherwise
        }

        XCTAssertFalse(seen.isEmpty, "at least one coalesced resize must reach the engine")
        XCTAssertLessThanOrEqual(seen.count, 2, "rapid resizes must coalesce rather than queue")
        XCTAssertEqual(seen.last?.w, 120)
        XCTAssertEqual(seen.last?.h, 40)

        session.close()
    }

    // MARK: 7. close() mid-stream fires exactly once

    func testCloseMidStreamFiresTerminationExactlyOnce() throws {
        let execID = "exec-close"
        let observer = SessionObserver()
        observer.terminationExpectation.assertForOverFulfill = true
        let session = makeSession(tty: false)
        observer.attach(to: session)

        session.start()
        try serviceCreate(execID: execID)
        let startFD = try serviceStart(
            execID: execID, tty: false,
            statusLine: (101, "UPGRADED"),
            headers: ["Connection": "Upgrade", "Upgrade": "tcp"])
        defer { Darwin.close(startFD) }
        wait(for: [observer.startedExpectation], timeout: 5)

        session.close()
        session.close()  // idempotent: must not fire a second time or crash

        XCTAssertEqual(readAvailable(startFD, atLeast: 1, timeout: 2).count, 0)
        wait(for: [observer.terminationExpectation], timeout: 5)
        XCTAssertEqual(observer.snapshotTerminations(), [.closedByUser])

        // Give any errant second callback a moment it would need to arrive in, then
        // confirm it never did.
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(observer.snapshotTerminations().count, 1)
    }

    // MARK: 8. containerStopped

    func testMissingExitCodeWithStoppedContainerReportsContainerStopped() throws {
        let execID = "exec-stopped"
        let observer = SessionObserver()
        let session = makeSession(tty: false)
        observer.attach(to: session)

        session.start()
        try serviceCreate(execID: execID)
        let startFD = try serviceStart(
            execID: execID, tty: false,
            statusLine: (101, "UPGRADED"),
            headers: ["Connection": "Upgrade", "Upgrade": "tcp"])
        wait(for: [observer.startedExpectation], timeout: 5)

        Darwin.close(startFD)
        serviceInspect(execID: execID, running: false, exitCode: nil)
        serviceContainerRunning(running: false)

        wait(for: [observer.terminationExpectation], timeout: 5)
        XCTAssertEqual(observer.snapshotTerminations(), [.containerStopped])
    }
}
