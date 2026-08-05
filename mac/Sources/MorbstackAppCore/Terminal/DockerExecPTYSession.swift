// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

// One live, hijacked Docker exec: the transport under the container terminal.
//
// The exchange is the one the Docker CLI performs: `POST /containers/{id}/exec`
// creates the instance, `POST /exec/{id}/start` with `Connection: Upgrade` +
// `Upgrade: tcp` takes the connection over — after the Engine's `101` (or a `2xx`
// carrying a Docker stream content type) the socket stops being HTTP and becomes
// stdin one way, stdout the other. Resize is a separate ordinary HTTP call to
// `/exec/{id}/resize`, made after start, coalesced so a live window drag does not
// queue fifty of them.
//
// Morbstack's own proxy sits between this class and dockerd. Its framer nominates
// `POST /exec/{id}/start` as a hijack candidate and confirms on the response
// (docs/audit/PROXY-FRAMING.md §2.4), so these bytes splice raw exactly like the
// CLI's do.

import Darwin
import Foundation
import MorbstackKit

/// One interactive (or piped) exec against one running container.
///
/// Callbacks are delivered on `callbackQueue` (the terminal controller passes main).
/// `onTermination` fires exactly once, whatever ends the session.
final class DockerExecPTYSession: @unchecked Sendable {

    struct Options: Sendable {
        var containerID: String
        var command: [String]
        /// `true` allocates a TTY: one merged output stream, raw bytes. `false` is the
        /// piped `exec -i` shape: stdout/stderr multiplexed and demultiplexed here.
        var tty: Bool
        var initialColumns: Int
        var initialRows: Int
    }

    enum TerminationReason: Equatable, Sendable {
        /// The process ended; `nil` means the Engine did not report an exit code.
        case exited(code: Int?)
        /// The stream ended because the container itself stopped.
        case containerStopped
        /// The connection failed or the Engine refused the exec.
        case transportFailure(String)
        /// `close()` — the person closed the terminal.
        case closedByUser
    }

    /// TTY sessions deliver everything here; non-TTY sessions deliver stdout.
    var onOutput: ((Data) -> Void)?
    /// Non-TTY sessions only: demultiplexed stderr.
    var onStderr: ((Data) -> Void)?
    /// The hijack is confirmed and bytes may flow.
    var onStarted: (() -> Void)?
    var onTermination: ((TerminationReason) -> Void)?

    init(client: DockerClient, options: Options, callbackQueue: DispatchQueue = .main) {
        self.client = client
        self.options = options
        self.callbackQueue = callbackQueue
    }

    /// Creates the exec instance and opens the hijacked start connection.
    ///
    /// `createExec` is bridged onto `controlQueue` rather than fired from whatever
    /// thread calls `start()`: the socket work that follows runs on its own dedicated
    /// thread regardless, but funnelling the kickoff through one queue means a `start()`
    /// immediately followed by a `close()` (both plausible from a UI action handler)
    /// resolve in the order they were issued rather than racing each other into the
    /// async world.
    func start() {
        controlQueue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            Task {
                do {
                    let execID = try await self.client.createExec(
                        containerID: self.options.containerID,
                        command: self.options.command,
                        tty: self.options.tty,
                        attachStdin: true)
                    self.spawnReader(execID: execID)
                } catch {
                    self.terminate(.transportFailure(error.localizedDescription))
                }
            }
        }
    }

    /// Sends stdin bytes.
    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        let connection: ExecConnection? = withState { state in
            guard state.started, !state.stdinClosed, !state.closed else { return nil }
            return state.connection
        }
        guard let connection else { return }
        writeQueue.async {
            // A write that fails here means the connection is on its way down; the
            // reader thread will discover that on its own next read and terminate the
            // session, so dropping the byte silently rather than surfacing a second,
            // redundant error is the honest thing to do.
            _ = try? connection.write(data)
        }
    }

    /// Half-closes stdin — the piped `exec -i` contract: the process sees EOF and its
    /// remaining output still drains.
    func closeStdin() {
        let connection: ExecConnection? = withState { state in
            guard !state.stdinClosed, !state.closed, let connection = state.connection else { return nil }
            state.stdinClosed = true
            return connection
        }
        guard let connection else { return }
        writeQueue.async {
            connection.shutdownWrite()
        }
    }

    /// Reports the terminal's new size. Coalesced; safe to call on every frame of a
    /// window drag. No-op for non-TTY sessions.
    func resize(columns: Int, rows: Int) {
        guard options.tty else { return }
        let ready: (execID: String, ok: Bool) = withState { state in
            (state.execID ?? "", state.started && !state.closed)
        }
        guard ready.ok, !ready.execID.isEmpty else { return }
        scheduleResize(execID: ready.execID, size: TermSize(columns: columns, rows: rows))
    }

    /// Tears the session down: shuts the socket, ends the reader, fires
    /// `onTermination(.closedByUser)`. Docker does not promise the process dies with
    /// its attachment for a plain exec; a TTY exec's shell receives SIGHUP.
    func close() {
        let outcome: (fired: Bool, connection: ExecConnection?) = withState { state in
            guard !state.closed else { return (false, nil) }
            state.closed = true
            return (true, state.connection)
        }
        guard outcome.fired else { return }
        // Only `shutdownRead`, never `close`: the reader thread is the sole owner of
        // the descriptor and may be blocked inside `read(2)` on it right now. Closing
        // it here would be a use-after-free the moment that number gets handed to the
        // next socket this process opens.
        outcome.connection?.shutdownRead()
        terminate(.closedByUser)
    }

    // MARK: Implementation detail

    private let client: DockerClient
    private let options: Options
    private let callbackQueue: DispatchQueue

    /// Serializes the `start()`/`close()` entry points before either touches shared
    /// state or the async world.
    private let controlQueue = DispatchQueue(label: "morbstack.exec.control")
    /// Off-loads `send()`'s socket write so a caller typing into the terminal never
    /// blocks on a full pipe.
    private let writeQueue = DispatchQueue(label: "morbstack.exec.write")

    private struct SessionState {
        var execID: String?
        var connection: ExecConnection?
        var started = false
        var stdinClosed = false
        var closed = false
    }

    private let stateLock = NSLock()
    private var state = SessionState()

    private func withState<T>(_ body: (inout SessionState) -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body(&state)
    }

    private var isClosed: Bool { withState { $0.closed } }

    private let terminationLock = NSLock()
    private var terminationFired = false

    /// Fires `onTermination` at most once, first caller wins. Every path that can end
    /// the session — a refused start, a dead socket, `close()`, a clean exit — funnels
    /// through this rather than calling `onTermination` directly.
    private func terminate(_ reason: TerminationReason) {
        terminationLock.lock()
        guard !terminationFired else {
            terminationLock.unlock()
            return
        }
        terminationFired = true
        terminationLock.unlock()
        callbackQueue.async { [onTermination] in onTermination?(reason) }
    }

    // MARK: Resize coalescing

    private struct TermSize: Equatable {
        var columns: Int
        var rows: Int
    }

    private let resizeLock = NSLock()
    private var lastSentSize: TermSize?
    private var pendingSize: TermSize?
    private var resizeInFlight = false

    private func scheduleResize(execID: String, size: TermSize) {
        resizeLock.lock()
        if lastSentSize == size {
            resizeLock.unlock()
            return
        }
        pendingSize = size
        if resizeInFlight {
            resizeLock.unlock()
            return
        }
        resizeInFlight = true
        resizeLock.unlock()
        drainResize(execID: execID)
    }

    /// Sends exactly one in-flight resize at a time, always the most recent one asked
    /// for. A window drag can call `resize()` faster than a round trip to the engine
    /// completes; queueing every call would mean the terminal keeps catching up to
    /// sizes the user has already moved past, so anything superseded before its turn
    /// comes is simply dropped.
    private func drainResize(execID: String) {
        resizeLock.lock()
        guard let next = pendingSize else {
            resizeInFlight = false
            resizeLock.unlock()
            return
        }
        pendingSize = nil
        resizeLock.unlock()

        Task { [client] in
            // A resize losing a race with the session ending, or the engine briefly
            // refusing one sent a moment too early, is not a session error — it is
            // cosmetic, and the next frame's resize (or the session's own end) is
            // what actually matters.
            _ = try? await client.resizeExec(id: execID, columns: next.columns, rows: next.rows)
            self.finishResize(execID: execID, sent: next)
        }
    }

    /// The lock traffic from one completed resize, kept in its own synchronous
    /// function so the locking itself never happens textually inside an `async` body.
    private func finishResize(execID: String, sent: TermSize) {
        resizeLock.lock()
        lastSentSize = sent
        resizeLock.unlock()
        drainResize(execID: execID)
    }

    // MARK: The reader thread

    private func spawnReader(execID: String) {
        let thread = Thread { [weak self] in
            self?.runSession(execID: execID)
        }
        thread.name = "morbstack.exec.pty"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    /// Everything from opening the socket to the stream's end, on its own thread.
    ///
    /// This is deliberately one long blocking function rather than a series of async
    /// hops: every step in it is a blocking `read`/`write`, and the only way to keep
    /// that off Swift concurrency's small cooperative pool is a real thread it owns
    /// start to finish, exactly like `DockerClient.stream`'s reader.
    private func runSession(execID: String) {
        guard !isClosed else { return }

        let fd: Int32
        do {
            fd = try UnixSocketClient.connect(path: client.socketPath, timeout: 5)
        } catch {
            terminate(.transportFailure("could not connect to the engine: \(error.localizedDescription)"))
            return
        }
        let connection = ExecConnection(fd: fd)

        let adopted = withState { state -> Bool in
            guard !state.closed else { return false }
            state.execID = execID
            state.connection = connection
            return true
        }
        guard adopted else {
            connection.shutdownRead()
            connection.close()
            return
        }

        do {
            try connection.write(Self.startRequest(execID: execID, tty: options.tty))
        } catch {
            terminate(.transportFailure("could not send the exec start request: \(error.localizedDescription)"))
            connection.close()
            return
        }

        let head: HTTPResponseHead
        let leftover: Data
        switch readResponseHead(connection) {
        case .failure(let message):
            terminate(.transportFailure(message))
            connection.close()
            return
        case .success(let resultHead, let resultLeftover):
            head = resultHead
            leftover = resultLeftover
        }

        guard Self.confirmsHijack(head) else {
            let message = readErrorBody(connection, initial: leftover, head: head)
            terminate(.transportFailure(message))
            connection.close()
            return
        }

        withState { $0.started = true }
        callbackQueue.async { [onStarted] in onStarted?() }
        if options.tty {
            resize(columns: options.initialColumns, rows: options.initialRows)
        }

        // `nil` means "no framing": a TTY stream is raw bytes end to end. A non-TTY
        // stream carries Docker's 8-byte stdcopy headers, decoded by the same
        // `StdcopyDemuxer` the noninteractive exec path uses.
        var demuxer: StdcopyDemuxer? = options.tty ? nil : StdcopyDemuxer()
        deliver(leftover, demuxer: &demuxer)

        readLoop: while true {
            let chunk: Data
            do {
                chunk = try connection.read()
            } catch {
                // A transport error after the hijack is confirmed is treated exactly
                // like a clean EOF: either way the only honest next step is asking the
                // engine what happened to the process, not inventing a distinct error
                // path for a socket that failed instead of closing politely.
                break readLoop
            }
            if chunk.isEmpty { break readLoop }
            deliver(chunk, demuxer: &demuxer)
        }

        if demuxer != nil {
            route(demuxer!.finish())
        }

        finalize(execID: execID, connection: connection)
    }

    private func deliver(_ data: Data, demuxer: inout StdcopyDemuxer?) {
        guard !data.isEmpty else { return }
        guard demuxer != nil else {
            callbackQueue.async { [onOutput] in onOutput?(data) }
            return
        }
        route(demuxer!.feed(data))
    }

    private func route(_ frames: [StdcopyDemuxer.Frame]) {
        for frame in frames {
            switch frame.stream {
            case .stdout:
                callbackQueue.async { [onOutput] in onOutput?(frame.bytes) }
            case .stderr:
                callbackQueue.async { [onStderr] in onStderr?(frame.bytes) }
            }
        }
    }

    /// Reads until a full HTTP response head has arrived, returning it plus whatever
    /// bytes came in on the same read past the terminating blank line. Those leftover
    /// bytes are real stream output — the engine is free to write its first chunk in
    /// the same packet as the `101` — and losing them would mean the first line or two
    /// a shell prints simply never reaching the terminal.
    private enum HeadReadOutcome {
        case success(head: HTTPResponseHead, leftover: Data)
        case failure(String)
    }

    private func readResponseHead(_ connection: ExecConnection) -> HeadReadOutcome {
        var raw = Data()
        while true {
            let chunk: Data
            do {
                chunk = try connection.read()
            } catch {
                return .failure("the engine connection failed before confirming the exec start: \(error.localizedDescription)")
            }
            if chunk.isEmpty {
                return .failure("the engine closed the connection without confirming the exec start")
            }
            raw.append(chunk)
            do {
                guard let parsed = try MinimalHTTP.parseHead(raw) else { continue }
                let leftover = Data(raw.suffix(from: raw.startIndex + parsed.consumed))
                return .success(head: parsed.head, leftover: leftover)
            } catch {
                return .failure("could not parse the engine's response to the exec start: \(error.localizedDescription)")
            }
        }
    }

    /// Reads a bounded amount of a refusal's body — Docker's `{"message": "..."}`
    /// shape — so a refused start (a stopped container, an exec ID that already
    /// finished) surfaces the engine's own words instead of a bare status code.
    private func readErrorBody(_ connection: ExecConnection, initial: Data, head: HTTPResponseHead) -> String {
        let capacity = 8192
        var body = Data(initial.prefix(capacity))
        let target = head.headers["content-length"].flatMap(Int.init).map { min($0, capacity) } ?? capacity
        while body.count < target {
            guard let chunk = try? connection.read(), !chunk.isEmpty else { break }
            body.append(chunk.prefix(target - body.count))
        }
        return Self.errorMessage(body, status: head.statusCode)
    }

    /// The stream ended (cleanly or not) after a confirmed hijack. Docker runs the exec
    /// process independently of this attachment, so the only way to know why is to ask:
    /// an exit code means the process finished; no exit code but a stopped container
    /// means the container went down under it; anything else is reported honestly as
    /// "no exit code available" rather than guessed at.
    private func finalize(execID: String, connection: ExecConnection) {
        connection.close()
        // `close()` already fired `.closedByUser` if that is what ended the stream;
        // asking the engine for an exit code the caller no longer wants would only
        // race the session's own shutdown for nothing.
        guard !isClosed else { return }

        let semaphore = DispatchSemaphore(value: 0)
        let box = TerminationReasonBox()
        Task { [client, options] in
            defer { semaphore.signal() }
            guard let status = try? await client.inspectExec(id: execID) else { return }
            if let exitCode = status.exitCode {
                box.set(.exited(code: exitCode))
            } else if await client.containerIsRunning(id: options.containerID) == false {
                box.set(.containerStopped)
            }
        }
        semaphore.wait()
        terminate(box.get())
    }

    // MARK: Wire shapes

    /// The hand-built hijack request. `MinimalHTTP.request` cannot be reused here: it
    /// has no body and no way to add `Connection: Upgrade` / `Upgrade: tcp`, which are
    /// exactly what tells Morbstack's proxy (and the real Docker CLI's own request) to
    /// splice this connection raw instead of framing it as ordinary HTTP.
    private static func startRequest(execID: String, tty: Bool) -> Data {
        let body = Data(#"{"Detach":false,"Tty":\#(tty)}"#.utf8)
        // Joined explicitly rather than written as a multi-line literal. A `"""` block
        // ends every line with the source's own `\n`, so a trailing `\r` line plus the
        // blank line before the closing delimiter emits `\r\n\r\n` AND a stray `\n` —
        // one extra byte sitting between the head terminator and the body, which the
        // peer then reads as the body's first byte.
        let head =
            [
                "POST /\(DockerClient.apiVersion)/exec/\(execID)/start HTTP/1.1",
                "Host: morbstack",
                "Content-Type: application/json",
                "Content-Length: \(body.count)",
                "Connection: Upgrade",
                "Upgrade: tcp",
                "User-Agent: morbstack/\(MorbVersion.string)",
                "", "",
            ].joined(separator: "\r\n")
        return Data(head.utf8) + body
    }

    /// A `101` is unambiguous. A `2xx` only counts if its content type is one of
    /// Docker's two stream shapes — a plain `200 application/json` is an ordinary,
    /// unhijacked answer (the shape a refusal or a not-yet-attached exec would take).
    private static func confirmsHijack(_ head: HTTPResponseHead) -> Bool {
        if head.statusCode == 101 { return true }
        guard (200..<300).contains(head.statusCode) else { return false }
        let contentType = (head.headers["content-type"] ?? "").lowercased()
        return contentType.contains("vnd.docker.raw-stream") || contentType.contains("vnd.docker.multiplexed-stream")
    }

    private static func errorMessage(_ body: Data, status: Int) -> String {
        if let decoded = try? JSONDecoder().decode(Wire.ErrorBody.self, from: body),
           let message = decoded.message, !message.isEmpty {
            return message
        }
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "the engine refused the exec start (HTTP \(status))" : text
    }
}

/// Bridges a `TerminationReason` computed inside an `async` `Task` back to the plain
/// thread that is waiting on a semaphore for it — the same shape as `DockerClient`'s
/// own `PullOutcome` and `DockerExecStreamOutcome`, kept as a value under a lock rather
/// than a bare captured `var` so the write inside the `Task` and the read after the
/// semaphore wait are never mistaken for a data race.
private final class TerminationReasonBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reason: DockerExecPTYSession.TerminationReason = .exited(code: nil)

    func set(_ newValue: DockerExecPTYSession.TerminationReason) {
        lock.lock()
        reason = newValue
        lock.unlock()
    }

    func get() -> DockerExecPTYSession.TerminationReason {
        lock.lock()
        defer { lock.unlock() }
        return reason
    }
}

/// One socket, owned by this session's reader thread.
///
/// A near-exact copy of `DockerClient`'s private `DockerConnection`: same
/// shutdown-vs-close split (the canceller only ever shuts the descriptor down; the
/// reader thread that is the sole owner of the number performs the actual `close`),
/// same `SIGPIPE` suppression, same "errno after a shutdown looks like a plain EOF to
/// the reader" treatment. It cannot be reused directly because it is `private` to
/// `DockerClient.swift`, but the discipline that makes it safe has to be copied exactly,
/// not reinvented.
private final class ExecConnection: @unchecked Sendable {

    private let lock = NSLock()
    private var fd: Int32
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
        POSIXSocketSupport.suppressSIGPIPE(fd)
    }

    /// Unblocks a reader without invalidating the descriptor. Safe from any thread.
    func shutdownRead() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, fd >= 0 else { return }
        _ = Darwin.shutdown(fd, SHUT_RDWR)
    }

    /// Half-closes the write side only — `closeStdin()`'s contract: the process sees
    /// EOF on its stdin, but the read side (and therefore the reader thread) stays live
    /// so the remaining output still drains.
    func shutdownWrite() {
        lock.lock()
        let descriptor = fd
        let isClosed = closed
        lock.unlock()
        guard !isClosed, descriptor >= 0 else { return }
        _ = Darwin.shutdown(descriptor, SHUT_WR)
    }

    /// Releases the descriptor. Only the owning reader may call this.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, fd >= 0 else { return }
        closed = true
        Darwin.close(fd)
        fd = -1
    }

    func write(_ data: Data) throws {
        lock.lock()
        let descriptor = fd
        lock.unlock()
        guard descriptor >= 0, POSIXSocketSupport.writeAll(descriptor, data) else {
            throw DockerClientError.transport("write to the exec socket failed")
        }
    }

    /// One `read(2)`. Returns an empty `Data` at EOF.
    func read(max: Int = 64 * 1024) throws -> Data {
        lock.lock()
        let descriptor = fd
        let isClosed = closed
        lock.unlock()
        guard !isClosed, descriptor >= 0 else { return Data() }

        var buffer = [UInt8](repeating: 0, count: max)
        let n = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return POSIXSocketSupport.readSome(descriptor, into: base, count: raw.count)
        }
        if n == 0 { return Data() }
        if n < 0 {
            // A shutdown from `close()` surfaces here; treat it as a clean EOF rather
            // than an error the read loop has to special-case.
            if errno == EBADF || errno == ECONNRESET || errno == EPIPE { return Data() }
            throw DockerClientError.transport("read from the exec socket failed: \(String(cString: strerror(errno)))")
        }
        return Data(buffer[0..<n])
    }
}
