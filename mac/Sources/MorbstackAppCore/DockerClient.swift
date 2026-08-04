// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The app's Docker Engine API client.
//
// It speaks HTTP/1.1 over the unix socket at ~/.morbstack/run/docker.sock using
// `MinimalHTTP` from MorbstackKit — the same parser the daemon's own proxy uses. There
// is no URLSession here because URLSession cannot dial a unix socket, and no HTTP
// package because the zero-dependency rule is not negotiable.
//
// Two shapes of call:
//
//   * **one-shot** (`listContainers`, `pruneImages`, …) — connect, send
//     `Connection: close`, read to EOF, decode, close. Nothing is pooled: the socket
//     is local, connect costs microseconds, and a pool would only buy the chance to
//     inherit a half-dead connection.
//   * **streaming** (`logs`, `stats`, `events`, `pull`) — one dedicated connection per
//     stream, read on its own thread, delivered through an `AsyncThrowingStream`.
//     Cancelling the consuming task shuts the socket down, which unblocks the reader.
//
// The reads are blocking `read(2)` calls on real threads rather than `async` I/O on
// the cooperative pool. A log stream can sit idle for hours; parking a cooperative
// thread on that would starve the pool, and Swift concurrency has no non-blocking unix
// socket primitive that would avoid it.

import Darwin
import Foundation
import MorbstackKit

// MARK: - Errors

/// Something went wrong talking to the engine.
enum DockerClientError: Error, LocalizedError {

    /// The socket file is absent or nothing is listening — the engine is down.
    case engineUnreachable(String)
    /// The engine answered with a non-2xx status.
    case http(status: Int, message: String)
    /// The engine answered with something that was not the JSON we expected.
    case decoding(String)
    /// A read or write failed mid-flight.
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .engineUnreachable(let detail): return "The Docker engine is not reachable: \(detail)"
        case .http(let status, let message): return message.isEmpty ? "Engine returned HTTP \(status)" : message
        case .decoding(let detail): return "Could not read the engine's reply: \(detail)"
        case .transport(let detail): return detail
        }
    }

    /// `true` when the right response is "show the start-the-engine screen" rather
    /// than "show an error".
    var isUnreachable: Bool {
        if case .engineUnreachable = self { return true }
        return false
    }
}

/// The finite result of Morbstack's deliberately noninteractive container-command
/// workflow. Docker reports stdout and stderr on one multiplexed connection when no
/// TTY is allocated; keeping them separate preserves that fact for the result sheet.
struct DockerExecResult: Sendable, Equatable {
    let standardOutput: String
    let standardError: String
    /// `nil` means the output connection closed but Docker did not subsequently report
    /// an exit status. It must not be displayed as success.
    let exitCode: Int?
    let standardOutputWasTruncated: Bool
    let standardErrorWasTruncated: Bool

    var exitStatusDescription: String {
        guard let exitCode else { return "Not reported by Docker" }
        return String(exitCode)
    }
}

// MARK: - Connection

/// One socket, owned by one request or one stream.
///
/// `@unchecked Sendable` because the descriptor is guarded by a lock and the class is
/// deliberately shared between the reader thread and the task that cancels it. That
/// cancellation is why `shutdown` and `close` are separate: closing a descriptor another
/// thread is blocked in `read(2)` on is a use-after-free waiting for the number to be
/// handed out again, so the canceller only ever calls `shutdown(2)` — which makes the
/// pending read return 0 — and the reader thread, the sole owner, does the `close`.
private final class DockerConnection: @unchecked Sendable {

    private let lock = NSLock()
    private var fd: Int32
    private var closed = false

    init(socketPath: String, timeout: TimeInterval = 5) throws {
        do {
            fd = try UnixSocketClient.connect(path: socketPath, timeout: timeout)
        } catch {
            throw DockerClientError.engineUnreachable("\(error)")
        }
        POSIXSocketSupport.suppressSIGPIPE(fd)
    }

    /// Unblocks a reader without invalidating the descriptor. Safe from any thread.
    func shutdownRead() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, fd >= 0 else { return }
        _ = Darwin.shutdown(fd, SHUT_RDWR)
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
            throw DockerClientError.transport("write to the engine socket failed")
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
            // A shutdown from the canceller surfaces here; treat it as a clean EOF
            // rather than an error the consumer has to special-case.
            if errno == EBADF || errno == ECONNRESET || errno == EPIPE { return Data() }
            throw DockerClientError.transport("read from the engine socket failed: \(String(cString: strerror(errno)))")
        }
        return Data(buffer[0..<n])
    }
}

// MARK: - Body framing

/// Turns raw socket bytes into body bytes, whichever framing the engine chose.
///
/// Docker uses all three depending on the endpoint: `Content-Length` for small JSON
/// documents, `chunked` for `/events` and `/stats`, and bare read-until-EOF for
/// hijacked log streams. Keeping the decision in one place means every caller — one
/// shot or streaming — gets the same treatment.
private struct BodyFramer {

    enum Framing {
        case chunked(ChunkedBodyDecoder)
        case length(remaining: Int)
        case untilEOF
    }

    private var framing: Framing

    init(head: HTTPResponseHead) {
        if head.isChunked {
            framing = .chunked(ChunkedBodyDecoder())
        } else if let length = head.contentLength {
            framing = .length(remaining: length)
        } else {
            framing = .untilEOF
        }
    }

    /// `true` once the framing itself says the body is over, regardless of EOF.
    var isComplete: Bool {
        switch framing {
        case .chunked(let decoder): return decoder.isComplete
        case .length(let remaining): return remaining <= 0
        case .untilEOF: return false
        }
    }

    mutating func feed(_ data: Data) throws -> Data {
        switch framing {
        case .chunked(var decoder):
            let out = try decoder.feed(data)
            framing = .chunked(decoder)
            return out
        case .length(let remaining):
            let take = Swift.min(remaining, data.count)
            framing = .length(remaining: remaining - take)
            return data.prefix(take)
        case .untilEOF:
            return data
        }
    }
}

// MARK: - Stdcopy

/// Demultiplexes Docker's stdout/stderr framing.
///
/// A container started without a TTY has its output wrapped in 8-byte headers —
/// `[stream:1][pad:3][length:4 big-endian]` — so stdout and stderr can share one
/// stream. A container *with* a TTY has no framing at all: the bytes are the output.
///
/// Which one you get depends on how the container was created, and the API tells you
/// only indirectly (via `Content-Type`, or by inspecting `Config.Tty`). Rather than
/// trust one signal, the default mode sniffs the first 8 bytes: a real header has a
/// stream byte of 0, 1 or 2 followed by three zero bytes, a combination that plain text
/// essentially never begins with. Once decided, the mode is fixed for the connection —
/// re-deciding mid-stream on a payload that happens to look like a header is how
/// demultiplexers corrupt output.
struct StdcopyDemuxer {

    enum Mode: Sendable {
        /// Sniff the first bytes and decide.
        case auto
        /// Container has no TTY: 8-byte headers.
        case multiplexed
        /// Container has a TTY: raw bytes, all stdout.
        case raw
    }

    /// A run of bytes known to belong to one stream.
    struct Frame: Equatable {
        var stream: StdStream
        var bytes: Data
    }

    /// The number of bytes in a stdcopy header.
    static let headerSize = 8

    private var mode: Mode
    private var buffer: [UInt8] = []

    init(mode: Mode = .auto) {
        self.mode = mode
    }

    /// The framing currently in effect; `.auto` until enough bytes arrived to decide.
    var resolvedMode: Mode { mode }

    /// Feeds wire bytes, returning every frame that is now complete.
    mutating func feed(_ data: Data) -> [Frame] {
        guard !data.isEmpty else { return [] }
        buffer.append(contentsOf: data)

        if case .auto = mode {
            // Fewer than 8 bytes is not enough to rule a header in *or* out, but it is
            // enough to rule one out: if the leading bytes already disagree with the
            // header shape, commit to raw now rather than holding output hostage to a
            // trickle that may never reach 8 bytes.
            if buffer.count >= Self.headerSize {
                mode = Self.looksLikeHeader(buffer) ? .multiplexed : .raw
            } else if !Self.couldBeHeaderPrefix(buffer) {
                mode = .raw
            } else {
                return []
            }
        }

        if case .raw = mode {
            let out = Data(buffer)
            buffer.removeAll(keepingCapacity: true)
            return out.isEmpty ? [] : [Frame(stream: .stdout, bytes: out)]
        }

        var frames: [Frame] = []
        var cursor = 0
        while buffer.count - cursor >= Self.headerSize {
            let streamByte = buffer[cursor]
            let length =
                (Int(buffer[cursor + 4]) << 24) | (Int(buffer[cursor + 5]) << 16)
                | (Int(buffer[cursor + 6]) << 8) | Int(buffer[cursor + 7])
            let payloadStart = cursor + Self.headerSize
            let payloadEnd = payloadStart + length
            guard buffer.count >= payloadEnd else { break }
            if length > 0 {
                frames.append(
                    Frame(
                        stream: streamByte == 2 ? .stderr : .stdout,
                        bytes: Data(buffer[payloadStart..<payloadEnd])))
            }
            cursor = payloadEnd
        }
        if cursor > 0 { buffer.removeFirst(cursor) }
        return frames
    }

    /// Flushes anything held back — used at EOF so a final unterminated run is not lost.
    mutating func finish() -> [Frame] {
        guard !buffer.isEmpty else { return [] }
        // A partial multiplexed frame is genuinely unusable; a partial raw tail is not.
        if case .multiplexed = mode {
            buffer.removeAll()
            return []
        }
        let out = Data(buffer)
        buffer.removeAll()
        return [Frame(stream: .stdout, bytes: out)]
    }

    static func looksLikeHeader(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= headerSize else { return false }
        return bytes[0] <= 2 && bytes[1] == 0 && bytes[2] == 0 && bytes[3] == 0
    }

    private static func couldBeHeaderPrefix(_ bytes: [UInt8]) -> Bool {
        for (index, byte) in bytes.prefix(4).enumerated() {
            if index == 0 { if byte > 2 { return false } } else if byte != 0 { return false }
        }
        return true
    }
}

/// Accumulates demultiplexed bytes into whole lines, with stable ids.
///
/// Kept separate from the demuxer because the two split on different boundaries: a
/// stdcopy frame is not a line, a line can span frames, and stdout and stderr each need
/// their own partial-line tail so an interleaved write does not splice two half-lines
/// together.
struct LogLineAssembler {

    /// A line still waiting for its newline, plus the time of the entry that started it.
    private struct Partial {
        var text: String = ""
        var timestamp: Date?
        var isEmpty: Bool { text.isEmpty && timestamp == nil }
    }

    private var nextID = 0
    private var partials: [StdStream: Partial] = [:]
    private let parseTimestamps: Bool

    init(parseTimestamps: Bool) {
        self.parseTimestamps = parseTimestamps
    }

    /// Consumes one demultiplexed frame.
    ///
    /// The timestamp is stripped **per log entry, not per line**, and a log entry is
    /// exactly one stdcopy frame: dockerd calls `Write` once per entry, so the prefix it
    /// prepends when `timestamps=1` lands at the start of every frame.
    ///
    /// Those two boundaries usually coincide, which is why stripping per line looked
    /// right for so long. They stop coinciding at 16 KiB: the logging drivers split any
    /// message longer than that into several entries, each written as its own frame with
    /// its own copy of the *same* timestamp, and only the last one ending in a newline.
    /// Stripping per line then removes the first prefix and leaves the rest embedded in
    /// the middle of the text — a stray `2026-08-02T11:13:06.591203856Z ` sitting
    /// 16 384 characters into a long JSON log or a stack trace. Stripping per frame
    /// removes all of them and reassembles the line clean.
    mutating func consume(_ frame: StdcopyDemuxer.Frame) -> [LogLine] {
        // `components(separatedBy:)` keeps empty pieces, and that is deliberate: blank
        // lines are printed on purpose and dropping them makes stack traces unreadable.
        var pieces = String(decoding: frame.bytes, as: UTF8.self).components(separatedBy: "\n")
        let tail = pieces.removeLast()

        var pending = partials[frame.stream] ?? Partial()
        var out: [LogLine] = []

        for piece in pieces {
            let entry = split(piece)
            let text = pending.text + entry.text
            out.append(
                make(
                    from: text.hasSuffix("\r") ? String(text.dropLast()) : text,
                    stream: frame.stream,
                    timestamp: pending.timestamp ?? entry.timestamp))
            pending = Partial()
        }

        let entry = split(tail)
        pending.text += entry.text
        pending.timestamp = pending.timestamp ?? entry.timestamp
        partials[frame.stream] = pending

        return out
    }

    /// Splits the entry prefix off one piece of frame text.
    ///
    /// Every piece is a candidate: the first because the frame starts an entry, the rest
    /// because a frame *may* carry several entries back to back. A piece that is a bare
    /// continuation carries no prefix and `splitTimestamp` leaves it alone, so running
    /// this everywhere costs nothing but a failed parse.
    private func split(_ piece: String) -> (timestamp: Date?, text: String) {
        guard parseTimestamps else { return (nil, piece) }
        let (date, remainder) = Self.splitTimestamp(piece)
        return (date, remainder)
    }

    /// Emits any trailing text that never got its newline — the last line of a log
    /// that ended without one, which is otherwise silently swallowed.
    mutating func flush() -> [LogLine] {
        var out: [LogLine] = []
        for (stream, partial) in partials where !partial.text.isEmpty {
            out.append(make(from: partial.text, stream: stream, timestamp: partial.timestamp))
        }
        partials.removeAll()
        return out
    }

    private mutating func make(from raw: String, stream: StdStream, timestamp: Date?) -> LogLine {
        defer { nextID += 1 }
        return LogLine(id: nextID, text: raw, stream: stream, timestamp: parseTimestamps ? timestamp : nil)
    }

    /// Splits Docker's RFC 3339 nano prefix off a log line.
    ///
    /// The engine writes `2026-03-12T09:41:22.418913274Z message`. `ISO8601DateFormatter`
    /// rejects nine-digit fractional seconds, so the fraction is truncated to the three
    /// digits it accepts. When the line does not start with a timestamp — which happens
    /// on a raw TTY stream the caller mis-flagged — the whole line is returned unchanged
    /// rather than mangled.
    static func splitTimestamp(_ line: String) -> (Date?, String) {
        guard let space = line.firstIndex(of: " ") else { return (nil, line) }
        let prefix = String(line[line.startIndex..<space])
        guard prefix.count >= 20, prefix.first?.isNumber == true,
              let date = parseRFC3339(prefix)
        else { return (nil, line) }
        return (date, String(line[line.index(after: space)...]))
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601NoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseRFC3339(_ text: String) -> Date? {
        if let dot = text.firstIndex(of: ".") {
            let head = String(text[text.startIndex..<dot])
            let rest = text[text.index(after: dot)...]
            let digits = String(rest.prefix(while: { $0.isNumber }))
            let suffix = String(rest.dropFirst(digits.count))
            let millis = String((digits + "000").prefix(3))
            if let date = iso8601.date(from: "\(head).\(millis)\(suffix)") { return date }
            return iso8601NoFraction.date(from: head + suffix)
        }
        return iso8601NoFraction.date(from: text)
    }
}

// MARK: - Stats maths

/// The CPU, memory, and network accounting from `docker stats`, isolated so it can be
/// tested before it becomes a number or line in the inspector.
enum StatsMath {

    /// Container CPU as a percentage of one host core × the number of online cores.
    ///
    /// `(cpu_delta / system_delta) * online_cpus * 100`, which is exactly what the
    /// Docker CLI computes. Every term can be missing or zero on the first sample of a
    /// stream — `precpu_stats` is empty until there is something to compare against —
    /// so a zero or negative denominator returns 0 rather than an infinity that would
    /// render as `inf%` and poison any chart it is fed to.
    static func cpuPercent(_ stats: Wire.Stats) -> Double {
        guard let current = stats.cpu_stats, let previous = stats.precpu_stats,
              let currentTotal = current.cpu_usage?.total_usage,
              let currentSystem = current.system_cpu_usage
        else { return 0 }

        let previousTotal = previous.cpu_usage?.total_usage ?? 0
        let previousSystem = previous.system_cpu_usage ?? 0
        let cpuDelta = currentTotal - previousTotal
        let systemDelta = currentSystem - previousSystem
        guard cpuDelta > 0, systemDelta > 0 else { return 0 }

        let onlineCPUs = Double(
            current.online_cpus
                ?? current.cpu_usage?.percpu_usage?.count
                ?? 1)
        let percent = (cpuDelta / systemDelta) * max(1, onlineCPUs) * 100
        return percent.isFinite ? max(0, percent) : 0
    }

    /// Memory actually attributable to the container.
    ///
    /// Raw `usage` includes page cache, which makes an idle container that once read a
    /// large file look like it is holding hundreds of megabytes. The CLI subtracts
    /// `inactive_file` on cgroup v2 and `cache` on v1; both keys are checked because
    /// which one is present depends on the guest kernel's cgroup mode.
    static func memoryBytes(_ stats: Wire.Stats) -> Int64 {
        guard let memory = stats.memory_stats, let usage = memory.usage else { return 0 }
        let extra = memory.stats?["inactive_file"] ?? memory.stats?["total_inactive_file"] ?? memory.stats?["cache"] ?? 0
        return max(0, usage - Int64(extra))
    }

    /// Totals Docker's cumulative per-interface counters.
    ///
    /// The Engine API reports a dictionary because a container may be attached to more
    /// than one network. Returning `nil` when any interface lacks either counter is
    /// intentional: presenting a partial sum as the container's traffic would be less
    /// honest than saying that the engine did not provide a complete total.
    static func networkTotals(_ stats: Wire.Stats) -> (received: Int64?, transmitted: Int64?) {
        guard let interfaces = stats.networks, !interfaces.isEmpty else { return (nil, nil) }

        var received: Int64 = 0
        var transmitted: Int64 = 0
        for interface in interfaces.values {
            guard let rx = interface.rx_bytes, let tx = interface.tx_bytes,
                  rx >= 0, tx >= 0
            else { return (nil, nil) }

            let receivedSum = received.addingReportingOverflow(rx)
            let transmittedSum = transmitted.addingReportingOverflow(tx)
            guard !receivedSum.overflow, !transmittedSum.overflow else { return (nil, nil) }
            received = receivedSum.partialValue
            transmitted = transmittedSum.partialValue
        }
        return (received, transmitted)
    }

    static func sample(_ stats: Wire.Stats, now: Date = Date()) -> StatsSample {
        let network = networkTotals(stats)
        return StatsSample(
            cpuPercent: cpuPercent(stats),
            memBytes: memoryBytes(stats),
            memLimit: stats.memory_stats?.limit ?? 0,
            networkReceivedBytes: network.received,
            networkTransmittedBytes: network.transmitted,
            ts: stats.read.flatMap(LogLineAssembler.parseRFC3339) ?? now)
    }

    /// `true` when this document carries no usable baseline to subtract.
    ///
    /// The engine answers `stats?stream=1` before it has anything to compare against, so
    /// the first document arrives with the `precpu_stats` object *present* but empty:
    /// `total_usage` zero and `system_cpu_usage` missing entirely. Testing for a nil
    /// `precpu_stats` therefore misses it, which is the trap — the baseline looks like a
    /// reading of a container that has used no CPU.
    ///
    /// It is not a "0% sample" either. With `previousSystem == 0` the system delta
    /// becomes the host's entire accumulated CPU time and the CPU delta becomes the
    /// container's entire lifetime, so the quotient is the container's *lifetime
    /// average*, dressed up as a one-second reading. Measured against this engine that
    /// is a 0.17% reading where the true interval was 0.22%: not an infinity, not a
    /// zero, nothing about it looks wrong — which is exactly why it has to be dropped
    /// rather than clamped.
    static func isPriming(_ stats: Wire.Stats) -> Bool {
        guard let previous = stats.precpu_stats else { return true }
        return (previous.system_cpu_usage ?? 0) <= 0
    }
}

/// Turns the documents of one `stats?stream=1` response into samples.
///
/// Exists so the drop rule is a value type with a test rather than three lines buried
/// in a stream closure. Two rules, deliberately overlapping: document 0 is never
/// emitted, and any document whose `precpu_stats` has no baseline is never emitted.
/// The index rule is the one the Docker CLI itself applies; the `isPriming` rule
/// covers an engine that sends more than one priming document (a container that is
/// still starting), and neither on its own is quite enough.
struct StatsStreamDecoder {

    /// How many documents have been offered, including the ones dropped.
    private(set) var seen = 0

    /// The sample for `stats`, or `nil` when the document is only a baseline.
    mutating func admit(_ stats: Wire.Stats, now: Date = Date()) -> StatsSample? {
        let index = seen
        seen += 1
        guard index > 0, !StatsMath.isPriming(stats) else { return nil }
        return StatsMath.sample(stats, now: now)
    }
}

// MARK: - Client

/// Talks to the Docker Engine API over the Morbstack socket.
///
/// Not `@MainActor`: every method blocks on socket I/O and is called with `await` from
/// the model. Statelessness is what makes that safe — the client holds a path and
/// nothing else, so there is no shared mutable state for concurrent calls to race on.
/// Non-`final` so developer fixture clients can substitute a deterministic engine (see
/// `Shots/ShotClients.swift`). Nothing in production subclasses it: the overridable
/// surface is the endpoint methods, not the socket plumbing.
class DockerClient: @unchecked Sendable {

    /// The Engine API version the app pins to. v1.43 is the floor Morbstack's daemon
    /// documents; every endpoint used here has been stable since well before it.
    static let apiVersion = "v1.43"

    let socketPath: String

    init(socketPath: String = MorbPaths.dockerSocket.path) {
        self.socketPath = socketPath
    }

    /// `true` when the socket file exists. Cheap enough to call from a view.
    var socketExists: Bool { FileManager.default.fileExists(atPath: socketPath) }

    private static let decoder: JSONDecoder = JSONDecoder()

    // MARK: One-shot requests

    /// Sends a request and returns the whole body.
    private func send(
        method: String,
        path: String,
        requestBody: Data? = nil,
        timeout: TimeInterval = 20
    ) throws -> Data {
        let connection = try DockerConnection(socketPath: socketPath, timeout: 5)
        defer { connection.close() }

        if let requestBody {
            try connection.write(Self.jsonRequest(method: method, path: path, body: requestBody))
        } else {
            try connection.write(MinimalHTTP.request(method: method, path: path, closeWhenDone: true))
        }

        var raw = Data()
        var head: HTTPResponseHead?
        var framer: BodyFramer?
        var body = Data()
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let chunk = try connection.read()
            if chunk.isEmpty { break }

            if head == nil {
                raw.append(chunk)
                guard let parsed = try MinimalHTTP.parseHead(raw) else { continue }
                head = parsed.head
                framer = BodyFramer(head: parsed.head)
                let leftover = raw.suffix(from: raw.startIndex + parsed.consumed)
                if !leftover.isEmpty { body.append(try framer!.feed(Data(leftover))) }
            } else {
                body.append(try framer!.feed(chunk))
            }
            if let framer, framer.isComplete { break }
        }

        guard let head else {
            throw DockerClientError.engineUnreachable("the engine closed the connection without replying")
        }
        guard (200..<300).contains(head.statusCode) else {
            throw DockerClientError.http(status: head.statusCode, message: Self.errorMessage(body, status: head.statusCode))
        }
        return body
    }

    /// Pulls the human-readable message out of Docker's `{"message": "..."}` error body.
    private static func errorMessage(_ body: Data, status: Int) -> String {
        if let decoded = try? decoder.decode(Wire.ErrorBody.self, from: body),
           let message = decoded.message, !message.isEmpty {
            return message
        }
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "engine returned HTTP \(status)" : text
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String) async throws -> T {
        let data = try await run { try self.send(method: "GET", path: self.url(path)) }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw DockerClientError.decoding("\(error)")
        }
    }

    @discardableResult
    private func post(_ path: String, timeout: TimeInterval = 60) async throws -> Data {
        try await run { try self.send(method: "POST", path: self.url(path), timeout: timeout) }
    }

    /// Sends one bounded, locally-owned JSON request. Callers declare a fixed request
    /// shape near their command rather than exposing a generic UI-to-Docker editor.
    @discardableResult
    private func postJSON(_ path: String, body: Data, timeout: TimeInterval = 60) async throws -> Data {
        try await run {
            try self.send(method: "POST", path: self.url(path), requestBody: body, timeout: timeout)
        }
    }

    @discardableResult
    private func delete(_ path: String, timeout: TimeInterval = 60) async throws -> Data {
        try await run { try self.send(method: "DELETE", path: self.url(path), timeout: timeout) }
    }

    private func url(_ path: String) -> String { "/\(Self.apiVersion)\(path)" }

    /// `MinimalHTTP` owns the shared bodyless request vocabulary; keeping this
    /// complete-body shape here makes a typed JSON request's content type and byte
    /// count explicit. Callers pass only internally-defined request documents, never
    /// an arbitrary HTTP editor from the UI.
    private static func jsonRequest(method: String, path: String, body: Data) -> Data {
        let head = """
            \(method) \(path) HTTP/1.1\r
            Host: morbstack\r
            Accept: application/json\r
            Content-Type: application/json\r
            Content-Length: \(body.count)\r
            User-Agent: morbstack/\(MorbVersion.string)\r
            Connection: close\r
            \r
            """
        return Data(head.utf8) + body
    }

    /// Runs a blocking body off the cooperative pool.
    ///
    /// Every request here is a synchronous `read`/`write` loop. Running those directly
    /// inside an `async` function would block one of the handful of cooperative
    /// threads; a few concurrent refreshes would then deadlock everything else in the
    /// app, including the UI's own actor hops.
    private func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try body()) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    // MARK: Listing

    func listContainers(all: Bool = true) async throws -> [ContainerSummary] {
        let wire = try await get([Wire.Container].self, "/containers/json?all=\(all ? 1 : 0)")
        return wire.map(ContainerSummary.init)
    }

    func listImages() async throws -> [ImageSummary] {
        let wire = try await get([Wire.Image].self, "/images/json?all=0")
        return wire.map(ImageSummary.init).sorted { $0.createdAt > $1.createdAt }
    }

    /// The platform one image was built for.
    ///
    /// Its own request, made only for the image the user selected. `GET /images/json`
    /// answers this for free for anything pulled from a multi-arch index, so this is the
    /// fallback for the rest: locally built images, single-manifest repositories, and
    /// anything from an engine older than API 1.45.
    ///
    /// Inspecting every image on the list instead would be one request per row on every
    /// refresh — forty round trips through the vsock relay to fill in a column most of
    /// which is already populated.
    func imageArchitecture(id: String) async throws -> ImageArchitecture? {
        let wire = try await get(Wire.ImageInspect.self, "/images/\(id)/json")
        return ImageArchitecture(wire)
    }

    func listVolumes() async throws -> [VolumeSummary] {
        let wire = try await get(Wire.VolumeList.self, "/volumes")
        return (wire.Volumes ?? []).map(VolumeSummary.init).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Lists networks, with the attachment count filled in.
    ///
    /// `GET /networks` returns `"Containers": null` for every network — the endpoint
    /// builds a summary and deliberately leaves the endpoint map out, because on a
    /// swarm manager assembling it for every network is expensive. Only
    /// `GET /networks/{id}` carries it.
    ///
    /// That is worth a second round trip rather than a `0`, because the Networks screen
    /// does not merely display the count: it sorts on it, badges on it, and classifies
    /// `containers == 0` as *unused*. Taking the list endpoint at its word makes every
    /// user network on the machine look like garbage the user is invited to prune,
    /// including the one their database is currently talking over.
    func listNetworks() async throws -> [NetworkSummary] {
        let wire = try await get([Wire.Network].self, "/networks")
        let counts = await attachmentCounts(for: wire.map(\.Id))
        return wire.map { network -> NetworkSummary in
            var summary = NetworkSummary(network)
            // A network removed between the two calls keeps the summary's own count
            // rather than being reported as empty on the strength of a failed request.
            if let count = counts[network.Id] { summary.containers = count }
            return summary
        }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Inspects one explicitly selected network. Docker omits IPAM, options, labels,
    /// endpoint addresses, and attached-member identities from its list response, so
    /// this request belongs to the selected-record inspector rather than inventory
    /// refresh.
    func inspectNetwork(id: String) async throws -> NetworkInspection {
        NetworkInspection(try await get(Wire.Network.self, "/networks/\(id)"))
    }

    /// How many containers are attached to each of `ids`, by inspecting them.
    ///
    /// Bounded concurrency rather than one task per network: a machine with forty
    /// compose projects on it would otherwise open forty sockets to the relay at once,
    /// on a screen refresh, to answer a question worth one small integer per row. Six in
    /// flight keeps a typical listing inside a single round-trip's worth of wall time
    /// without the stampede.
    ///
    /// Never throws. A count that cannot be fetched is simply absent from the result;
    /// this is decoration on a list that has already succeeded, and failing the whole
    /// Networks screen because one network disappeared mid-refresh would be a poor trade.
    private func attachmentCounts(for ids: [String], maxInFlight: Int = 6) async -> [String: Int] {
        guard !ids.isEmpty else { return [:] }

        return await withTaskGroup(of: (String, Int)?.self) { group in
            var counts: [String: Int] = [:]
            var next = 0

            func addTask(_ id: String) {
                group.addTask { [weak self] in
                    guard let self,
                          let inspected = try? await self.get(Wire.Network.self, "/networks/\(id)")
                    else { return nil }
                    return (id, inspected.Containers?.count ?? 0)
                }
            }

            while next < min(maxInFlight, ids.count) {
                addTask(ids[next])
                next += 1
            }
            while let result = await group.next() {
                if let result { counts[result.0] = result.1 }
                if next < ids.count {
                    addTask(ids[next])
                    next += 1
                }
            }
            return counts
        }
    }

    /// `docker system df`.
    func diskUsage() async throws -> DiskUsage {
        let data = try await run { try self.send(method: "GET", path: self.url("/system/df"), timeout: 45) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DockerClientError.decoding("/system/df did not return an object")
        }
        return Self.diskUsage(from: object)
    }

    /// Folds a `/system/df` document into ``DiskUsage``.
    ///
    /// Hand-walked rather than `Codable` because the reclaimable total needs fields
    /// from four differently shaped arrays, and because `SizeRw` only appears on this
    /// endpoint's container objects. `LayersSize` is the honest number for images: the
    /// per-image `Size` values double-count every shared base layer, so summing them
    /// reports far more disk than is actually used.
    static func diskUsage(from object: [String: Any]) -> DiskUsage {
        func int64(_ any: Any?) -> Int64 {
            switch any {
            case let value as Int64: return value
            case let value as Int: return Int64(value)
            case let value as Double: return Int64(value)
            case let value as NSNumber: return value.int64Value
            default: return 0
            }
        }

        let layersSize = int64(object["LayersSize"])

        let images = object["Images"] as? [[String: Any]] ?? []
        let danglingImageBytes = images
            .filter { int64($0["Containers"]) <= 0 }
            .reduce(Int64(0)) { $0 + int64($1["Size"]) }

        let volumes = object["Volumes"] as? [[String: Any]] ?? []
        var volumeBytes: Int64 = 0
        var reclaimableVolumeBytes: Int64 = 0
        for volume in volumes {
            let usage = volume["UsageData"] as? [String: Any]
            let size = max(0, int64(usage?["Size"]))
            volumeBytes += size
            if int64(usage?["RefCount"]) <= 0 { reclaimableVolumeBytes += size }
        }

        let buildCache = object["BuildCache"] as? [[String: Any]] ?? []
        var cacheBytes: Int64 = 0
        var reclaimableCacheBytes: Int64 = 0
        for record in buildCache {
            let size = max(0, int64(record["Size"]))
            // A shared cache record is reported once per parent; counting it each time
            // inflates the total by a multiple of however many images share it.
            if record["Shared"] as? Bool == true { continue }
            cacheBytes += size
            if record["InUse"] as? Bool != true { reclaimableCacheBytes += size }
        }

        let containers = object["Containers"] as? [[String: Any]] ?? []
        var containerBytes: Int64 = 0
        var reclaimableContainerBytes: Int64 = 0
        for container in containers {
            let size = max(0, int64(container["SizeRw"]))
            containerBytes += size
            if (container["State"] as? String) != "running" { reclaimableContainerBytes += size }
        }

        return DiskUsage(
            layersSize: layersSize,
            imagesTotal: layersSize > 0 ? layersSize : images.reduce(Int64(0)) { $0 + int64($1["Size"]) },
            volumesTotal: volumeBytes,
            buildCacheTotal: cacheBytes,
            containersTotal: containerBytes,
            reclaimable: danglingImageBytes + reclaimableVolumeBytes + reclaimableCacheBytes + reclaimableContainerBytes)
    }

    /// Every BuildKit cache record `/system/df` knows about.
    ///
    /// A second read of the same endpoint `diskUsage()` calls — the response is small
    /// (a few hundred records at most) and this is only fetched when the Builds screen
    /// is actually on screen, the same rule `refreshDisk()` follows for the rest of
    /// this endpoint.
    func buildCacheRecords() async throws -> [BuildCacheRecord] {
        let data = try await run { try self.send(method: "GET", path: self.url("/system/df"), timeout: 45) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DockerClientError.decoding("/system/df did not return an object")
        }
        return Self.buildCacheRecords(from: object)
    }

    static func buildCacheRecords(from object: [String: Any]) -> [BuildCacheRecord] {
        let buildCache = object["BuildCache"] as? [[String: Any]] ?? []
        return buildCache.compactMap { record -> BuildCacheRecord? in
            guard let id = record["ID"] as? String else { return nil }
            let size: Int64
            switch record["Size"] {
            case let value as Int64: size = value
            case let value as Int: size = Int64(value)
            case let value as Double: size = Int64(value)
            case let value as NSNumber: size = value.int64Value
            default: size = 0
            }
            let createdAt = (record["CreatedAt"] as? String).flatMap(LogLineAssembler.parseRFC3339) ?? .distantPast
            let lastUsed = (record["LastUsedAt"] as? String).flatMap(LogLineAssembler.parseRFC3339)
            let usageCount: Int
            switch record["UsageCount"] {
            case let value as Int: usageCount = value
            case let value as NSNumber: usageCount = value.intValue
            default: usageCount = 0
            }
            let description = record["Description"] as? String ?? ""
            return BuildCacheRecord(
                id: id,
                description: description.isEmpty ? (record["Type"] as? String ?? "cache record") : description,
                type: record["Type"] as? String ?? "regular",
                size: max(0, size),
                inUse: record["InUse"] as? Bool ?? false,
                shared: record["Shared"] as? Bool ?? false,
                createdAt: createdAt,
                lastUsedAt: lastUsed,
                usageCount: usageCount)
        }
    }

    /// The full inspect document, pretty-printed for the detail pane's JSON tab.
    func inspectContainer(id: String) async throws -> String {
        let data = try await run { try self.send(method: "GET", path: self.url("/containers/\(id)/json")) }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              // `.withoutEscapingSlashes` for parity with `docker inspect`, which prints
              // `/var/lib/postgresql/data`. Without it every path in the document comes
              // out as `\/var\/lib\/…`, which is valid JSON and unreadable.
              let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else {
            return String(decoding: data, as: UTF8.self)
        }
        return String(decoding: pretty, as: UTF8.self)
    }

    /// Whether the container was created with a TTY, which decides its log framing.
    func containerHasTTY(id: String) async -> Bool {
        guard let data = try? await run({ try self.send(method: "GET", path: self.url("/containers/\(id)/json")) }),
              let inspected = try? Self.decoder.decode(Wire.InspectTTY.self, from: data)
        else { return false }
        return inspected.Config?.Tty ?? false
    }

    // MARK: Container commands

    /// Runs one explicitly noninteractive command in a running container and returns
    /// the output Docker attached to that command. This is intentionally not a shell:
    /// `command` is sent as Docker's `Cmd` array, stdin stays closed, and no TTY is
    /// allocated. A caller that cancels this method stops reading the attached stream;
    /// Docker's exec API does not promise that disconnecting the reader terminates the
    /// process, so the UI must describe that boundary rather than call it cancellation.
    ///
    /// The stored prefix is limited independently for each stream. We continue reading
    /// after either cap so Docker can close the operation normally, but tell the caller
    /// exactly which output was incomplete.
    func executeContainerCommand(id: String, command: [String]) async throws -> DockerExecResult {
        guard !command.isEmpty else {
            throw DockerClientError.decoding("a container command needs an executable")
        }

        let createBody = try JSONEncoder().encode(
            DockerExecCreateRequest(
                AttachStdin: false,
                AttachStdout: true,
                AttachStderr: true,
                Tty: false,
                Cmd: command))
        let createData = try await postJSON("/containers/\(id)/exec", body: createBody)
        let created: DockerExecCreateResponse
        do {
            created = try Self.decoder.decode(DockerExecCreateResponse.self, from: createData)
        } catch {
            throw DockerClientError.decoding("could not decode Docker's exec response: \(error)")
        }
        guard let execID = created.Id, !execID.isEmpty else {
            throw DockerClientError.decoding("Docker created an exec instance without returning its ID")
        }

        try Task.checkCancellation()
        let startBody = try JSONEncoder().encode(DockerExecStartRequest(Detach: false, Tty: false))
        let output = DockerExecOutputCollector()
        try await readExecOutput(id: execID, startBody: startBody, collector: output)
        try Task.checkCancellation()

        // `/exec/{id}/json` is a post-completion metadata read. A successful attached
        // stream does not make a missing follow-up status a command success, so retain
        // `nil` when the Engine does not report an exit code instead of manufacturing 0.
        let exitCode = try? await inspectExecExitCode(id: execID)
        return output.result(exitCode: exitCode)
    }

    private func readExecOutput(
        id: String,
        startBody: Data,
        collector: DockerExecOutputCollector
    ) async throws {
        let outcome = DockerExecStreamOutcome()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard outcome.begin(continuation) else { return }
                let handle = stream(
                    method: "POST",
                    path: "/exec/\(id)/start",
                    requestBody: startBody,
                    onBody: { collector.consume($0) },
                    onFinish: { error in
                        collector.finish()
                        outcome.finish(error)
                    })
                outcome.adopt(handle)
            }
        } onCancel: {
            outcome.cancel()
        }
    }

    private func inspectExecExitCode(id: String) async throws -> Int? {
        let data = try await run { try self.send(method: "GET", path: self.url("/exec/\(id)/json")) }
        do {
            return try Self.decoder.decode(DockerExecInspectResponse.self, from: data).ExitCode
        } catch {
            throw DockerClientError.decoding("could not decode Docker's exec inspection: \(error)")
        }
    }

    // MARK: Container lifecycle

    /// Creates one container from the immutable ID of an image that the Images route
    /// has already listed locally. The JSON has *only* `Image`: Docker therefore uses
    /// the image's own entrypoint, command, user, working directory, and environment.
    /// It does not request a pull, mounts, ports, a custom network, privilege, or host
    /// configuration. An optional user name is carried only in Docker's normal query
    /// parameter and remains Engine-validated.
    func createLocalImageContainer(imageID: String, requestedName: String?) async throws -> String {
        let name = requestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if let name, !name.isEmpty {
            path = "/containers/create?name=\(MinimalHTTP.percentEncodeQueryValue(name))"
        } else {
            path = "/containers/create"
        }

        let body = try JSONEncoder().encode(LocalImageCreateRequest(Image: imageID))
        let data = try await postJSON(path, body: body)
        let response: LocalImageCreateResponse
        do {
            response = try Self.decoder.decode(LocalImageCreateResponse.self, from: data)
        } catch {
            throw DockerClientError.decoding("could not decode Docker's create response: \(error)")
        }
        guard let id = response.Id, !id.isEmpty else {
            throw DockerClientError.decoding("Docker created a container without returning its ID")
        }
        return id
    }

    /// Creates or returns one named volume using Docker's default `local` driver. The
    /// body deliberately contains no labels or driver options: the Volumes route
    /// presents that narrow contract before sending it, and Docker remains the source
    /// of truth for name validation and an existing same-driver name.
    func createVolume(name: String) async throws -> VolumeSummary {
        let body = try JSONEncoder().encode(VolumeCreatePayload(Name: name))
        let data = try await postJSON("/volumes/create", body: body)
        do {
            return VolumeSummary(try Self.decoder.decode(Wire.Volume.self, from: data))
        } catch {
            throw DockerClientError.decoding("could not decode Docker's volume create response: \(error)")
        }
    }

    func startContainer(id: String) async throws { try await post("/containers/\(id)/start") }
    func stopContainer(id: String) async throws { try await post("/containers/\(id)/stop?t=10", timeout: 45) }
    func restartContainer(id: String) async throws { try await post("/containers/\(id)/restart?t=10", timeout: 45) }
    func pauseContainer(id: String) async throws { try await post("/containers/\(id)/pause") }
    func unpauseContainer(id: String) async throws { try await post("/containers/\(id)/unpause") }

    /// Removes a container, taking its anonymous volumes with it.
    ///
    /// `force=1` so a running container can be removed in one step — the UI already
    /// asked for confirmation, and a second "it is still running" error at that point
    /// is a dead end rather than a safeguard.
    func removeContainer(id: String) async throws {
        try await delete("/containers/\(id)?v=1&force=1")
    }

    func removeImage(id: String, force: Bool = false) async throws {
        try await delete("/images/\(id)?force=\(force ? 1 : 0)")
    }

    func removeVolume(name: String, force: Bool = false) async throws {
        try await delete("/volumes/\(name)?force=\(force ? 1 : 0)")
    }

    /// Creates the native Networks route's deliberately bounded bridge network.
    ///
    /// The v1.43 request omits `EnableIPv4` because Docker added it in v1.48; omitting
    /// it preserves Docker's default IPv4 allocation. `EnableIPv6`, labels, and bridge
    /// options are the exact values reviewed in `NetworkCreateSheet`. The request has
    /// no IPAM configuration and no endpoint/container attachment fields.
    func createNetwork(_ request: NetworkCreateRequest) async throws -> NetworkCreateResult {
        let body = try JSONEncoder().encode(NetworkCreatePayload(request))
        let data = try await postJSON("/networks/create", body: body)
        let response: NetworkCreateResponse
        do {
            response = try Self.decoder.decode(NetworkCreateResponse.self, from: data)
        } catch {
            throw DockerClientError.decoding("could not decode Docker's network-create response: \(error)")
        }
        guard let id = response.Id, !id.isEmpty else {
            throw DockerClientError.decoding("Docker created a network without returning its ID")
        }
        return NetworkCreateResult(id: id, warning: response.Warning)
    }

    /// Connects one selected running container to one selected network. The typed body
    /// carries only Docker's documented endpoint aliases; static addresses, links,
    /// driver options, gateway priority, and sysctls are intentionally absent.
    func connectNetwork(_ request: NetworkConnectRequest) async throws {
        let body = try JSONEncoder().encode(NetworkConnectPayload(request))
        _ = try await postJSON("/networks/\(request.networkID)/connect", body: body)
    }

    /// Disconnects one selected running container after the route's confirmation.
    /// `Force` remains false: a stopped-container force path would be a distinct,
    /// more consequential workflow, not an invisible fallback for this command.
    func disconnectNetwork(_ request: NetworkDisconnectRequest) async throws {
        let body = try JSONEncoder().encode(NetworkDisconnectPayload(request))
        _ = try await postJSON("/networks/\(request.networkID)/disconnect", body: body)
    }

    func removeNetwork(id: String) async throws {
        try await delete("/networks/\(id)")
    }

    // MARK: Pruning

    private func prune(_ path: String) async throws -> Int64 {
        let data = try await post(path, timeout: 180)
        let report = try? Self.decoder.decode(Wire.PruneReport.self, from: data)
        return report?.SpaceReclaimed ?? 0
    }

    func pruneContainers() async throws -> Int64 { try await prune("/containers/prune") }

    /// Prunes dangling images only — the same default as `docker image prune` without
    /// `-a`. Removing every unused image is a much bigger hammer than a toolbar button
    /// should swing.
    func pruneImages() async throws -> Int64 { try await prune("/images/prune") }

    /// Prunes anonymous unused volumes.
    ///
    /// `all=0` keeps *named* volumes: those hold databases people care about, and an
    /// unused named volume is usually a stopped stack rather than garbage.
    func pruneVolumes() async throws -> Int64 { try await prune("/volumes/prune") }

    func pruneBuildCache() async throws -> Int64 { try await prune("/build/prune") }

    func pruneNetworks() async throws -> Int64 { try await prune("/networks/prune") }

    // MARK: - Streaming

    /// Opens a connection, sends `request`, and hands each decoded body slice to
    /// `onBody` on a private thread until the stream ends or the task is cancelled.
    ///
    /// The shared spine of `logs`, `stats`, `events` and `pull`: connect, parse the
    /// head, check the status, then loop. `onFinish` runs exactly once.
    private func stream(
        method: String,
        path: String,
        requestBody: Data? = nil,
        onBody: @escaping @Sendable (Data) -> Void,
        onFinish: @escaping @Sendable (Error?) -> Void
    ) -> DockerConnectionHandle {
        let handle = DockerConnectionHandle()
        let socketPath = self.socketPath
        let fullPath = url(path)

        let thread = Thread {
            var connection: DockerConnection?
            var failure: Error?
            do {
                let opened = try DockerConnection(socketPath: socketPath, timeout: 5)
                connection = opened
                // Publishing before the first read is what makes cancellation work: a
                // consumer that gives up while the engine is silent needs something to
                // shut down, and there is no other moment at which it becomes available.
                guard handle.adopt(opened) else {
                    opened.close()
                    onFinish(nil)
                    return
                }
                if let requestBody {
                    try opened.write(Self.jsonRequest(method: method, path: fullPath, body: requestBody))
                } else {
                    try opened.write(MinimalHTTP.request(method: method, path: fullPath, closeWhenDone: true))
                }

                var raw = Data()
                var head: HTTPResponseHead?
                var framer: BodyFramer?
                var errorBody = Data()

                while !handle.isCancelled {
                    let chunk = try opened.read()
                    if chunk.isEmpty { break }

                    var payload = chunk
                    if head == nil {
                        raw.append(chunk)
                        guard let parsed = try MinimalHTTP.parseHead(raw) else { continue }
                        head = parsed.head
                        framer = BodyFramer(head: parsed.head)
                        payload = Data(raw.suffix(from: raw.startIndex + parsed.consumed))
                        raw = Data()
                        if payload.isEmpty { continue }
                    }

                    let body = try framer!.feed(payload)
                    if body.isEmpty { continue }
                    if let head, !(200..<300).contains(head.statusCode) {
                        errorBody.append(body)
                        if errorBody.count > 8192 { break }
                        continue
                    }
                    onBody(body)
                    if framer!.isComplete { break }
                }

                if let head, !(200..<300).contains(head.statusCode) {
                    failure = DockerClientError.http(
                        status: head.statusCode, message: Self.errorMessage(errorBody, status: head.statusCode))
                } else if head == nil, !handle.isCancelled {
                    failure = DockerClientError.engineUnreachable("the engine closed the stream without replying")
                }
            } catch {
                if !handle.isCancelled { failure = error }
            }
            connection?.close()
            onFinish(handle.isCancelled ? nil : failure)
        }
        thread.name = "morbstack.docker.stream"
        thread.stackSize = 512 * 1024
        thread.start()
        return handle
    }

    /// Streams container output.
    ///
    /// `timestamps=1` is always requested and the prefix parsed off, so the gutter can
    /// show times without the caller having to opt in — and so a line's time survives
    /// even when the program itself printed none.
    func logs(id: String, follow: Bool = true, tail: Int = 500) -> AsyncThrowingStream<LogLine, Error> {
        AsyncThrowingStream { continuation in
            let tailArgument = tail <= 0 ? "all" : String(tail)
            let path = "/containers/\(id)/logs?stdout=1&stderr=1&timestamps=1&follow=\(follow ? 1 : 0)&tail=\(tailArgument)"

            // Both closures below run on the reader thread and both touch the
            // demuxer/assembler pair, so the pair lives in one box with one lock rather
            // than as two captured `var`s a concurrency check would rightly reject.
            let state = LogStreamState()
            let handle = stream(
                method: "GET",
                path: path,
                onBody: { data in
                    for line in state.consume(data) { continuation.yield(line) }
                },
                onFinish: { error in
                    for line in state.flush() { continuation.yield(line) }
                    continuation.finish(throwing: error)
                })
            continuation.onTermination = { _ in handle.cancel() }
        }
    }

    /// Streams resampled CPU/memory for one container, roughly once a second.
    ///
    /// The first document off the wire is swallowed rather than yielded: it is the
    /// engine's baseline, not a reading (see `StatsStreamDecoder`). The cost is that the
    /// first point appears after about a second instead of instantly; the alternative is
    /// a first point that is a lifetime average and is wrong by an arbitrary factor.
    func stats(id: String) -> AsyncThrowingStream<StatsSample, Error> {
        AsyncThrowingStream { continuation in
            let lines = LineBox()
            let samples = StatsStreamState()
            let handle = stream(
                method: "GET",
                path: "/containers/\(id)/stats?stream=1",
                onBody: { data in
                    for line in lines.feed(data) {
                        guard let wire = try? Self.decoder.decode(Wire.Stats.self, from: line),
                              let sample = samples.admit(wire)
                        else { continue }
                        continuation.yield(sample)
                    }
                },
                onFinish: { continuation.finish(throwing: $0) })
            continuation.onTermination = { _ in handle.cancel() }
        }
    }

    /// Streams engine events.
    ///
    /// Filtered to the object types the UI actually renders. An unfiltered stream on a
    /// busy engine is mostly `exec_*` and network attach/detach chatter, every line of
    /// which would wake the model for nothing.
    func events() -> AsyncThrowingStream<DockerEvent, Error> {
        AsyncThrowingStream { continuation in
            let filters = #"{"type":["container","image","volume","network"]}"#
            let path = "/events?filters=" + MinimalHTTP.percentEncodeQueryValue(filters)
            let lines = LineBox()
            let handle = stream(
                method: "GET",
                path: path,
                onBody: { data in
                    for line in lines.feed(data) {
                        guard let wire = try? Self.decoder.decode(Wire.Event.self, from: line),
                              let event = DockerEvent(wire)
                        else { continue }
                        continuation.yield(event)
                    }
                },
                onFinish: { continuation.finish(throwing: $0) })
            continuation.onTermination = { _ in handle.cancel() }
        }
    }

    /// Pulls an image, reporting each progress line.
    ///
    /// Returns when the pull finishes. A `{"error": …}` line is the only way the engine
    /// reports failure here — the HTTP status is 200 even for a nonexistent image — so
    /// the body has to be inspected rather than the status code.
    func pull(ref: String, progress: @escaping @Sendable (String) -> Void) async throws {
        let (image, tag) = Self.splitImageReference(ref)
        var path = "/images/create?fromImage=" + MinimalHTTP.percentEncodeQueryValue(image)
        path += "&tag=" + MinimalHTTP.percentEncodeQueryValue(tag)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let lines = LineBox()
            let outcome = PullOutcome()
            _ = stream(
                method: "POST",
                path: path,
                onBody: { data in
                    for line in lines.feed(data) {
                        guard let update = try? Self.decoder.decode(Wire.PullProgress.self, from: line) else { continue }
                        if let error = update.error {
                            outcome.fail(DockerClientError.http(status: 200, message: error))
                            continue
                        }
                        guard let status = update.status else { continue }
                        if let layer = update.id, !layer.isEmpty {
                            progress("\(layer): \(status)\(update.progress.map { " \($0)" } ?? "")")
                        } else {
                            progress(status)
                        }
                    }
                },
                onFinish: { error in
                    outcome.finish(with: error, continuation: continuation)
                })
        }
    }

    /// Splits `nginx:1.25` into `("nginx", "1.25")`.
    ///
    /// A digest reference keeps its `@sha256:…` in the tag slot, which is what the API
    /// expects, and a registry host's port must not be mistaken for a tag — hence the
    /// last-slash check before the last colon.
    static func splitImageReference(_ ref: String) -> (image: String, tag: String) {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        if let at = trimmed.firstIndex(of: "@") {
            return (String(trimmed[trimmed.startIndex..<at]), String(trimmed[trimmed.index(after: at)...]))
        }
        guard let colon = trimmed.lastIndex(of: ":") else { return (trimmed, "latest") }
        let afterColon = trimmed[trimmed.index(after: colon)...]
        if afterColon.contains("/") { return (trimmed, "latest") }  // registry port, not a tag
        if afterColon.isEmpty { return (String(trimmed[trimmed.startIndex..<colon]), "latest") }
        return (String(trimmed[trimmed.startIndex..<colon]), String(afterColon))
    }
}

/// The whole request document for the local-image run flow. Keeping this next to the
/// client rather than a view makes the authority boundary reviewable: no host config
/// or user-configurable Docker field can enter the request.
private struct LocalImageCreateRequest: Encodable {
    let Image: String
}

/// Docker's successful container-create response contains the new immutable ID.
private struct LocalImageCreateResponse: Decodable {
    let Id: String?
}

/// The fixed body for the native Volume creation sheet. Omitting `Driver` asks Docker
/// for its documented default (`local`) while leaving labels and driver options absent.
private struct VolumeCreatePayload: Encodable {
    let Name: String
}

/// The exact v1.43 network-create body. This deliberately lacks both `EnableIPv4`
/// (introduced in v1.48) and `IPAM`, so the UI cannot make a version-incompatible
/// IPv4 or custom-subnet promise.
private struct NetworkCreatePayload: Encodable {
    let Name: String
    let Driver: String
    let EnableIPv6: Bool
    let Labels: [String: String]
    let Options: [String: String]

    init(_ request: NetworkCreateRequest) {
        Name = request.name
        Driver = request.driver.rawValue
        EnableIPv6 = request.enableIPv6
        Labels = request.labels
        Options = request.options
    }
}

/// Docker's successful network-create response contains the new immutable ID and may
/// include a warning that remains meaningful even though the request succeeded.
private struct NetworkCreateResponse: Decodable {
    let Id: String?
    let Warning: String?
}

/// The bounded Engine request for `POST /networks/{id}/connect`. `EndpointConfig` is
/// omitted when there are no aliases, so this request cannot accidentally imply any
/// IPAM/static-address configuration.
private struct NetworkConnectPayload: Encodable {
    let Container: String
    let EndpointConfig: EndpointConfiguration?

    struct EndpointConfiguration: Encodable {
        let Aliases: [String]
    }

    init(_ request: NetworkConnectRequest) {
        Container = request.containerID
        EndpointConfig = request.aliases.isEmpty ? nil : EndpointConfiguration(Aliases: request.aliases)
    }
}

/// The bounded Engine request for `POST /networks/{id}/disconnect`. The native route
/// does not expose Docker's force-disconnect escape hatch, but serializes `false`
/// explicitly so its non-forced behavior is unambiguous at the API boundary.
private struct NetworkDisconnectPayload: Encodable {
    let Container: String
    let Force: Bool

    init(_ request: NetworkDisconnectRequest) {
        Container = request.containerID
        Force = false
    }
}

/// The only Engine request shape the app exposes for an attached command. There is no
/// stdin, terminal allocation, detached execution, environment override, working
/// directory override, privilege override, or generic JSON escape hatch in this first
/// command workflow.
private struct DockerExecCreateRequest: Encodable {
    let AttachStdin: Bool
    let AttachStdout: Bool
    let AttachStderr: Bool
    let Tty: Bool
    let Cmd: [String]
}

private struct DockerExecCreateResponse: Decodable {
    let Id: String?
}

private struct DockerExecStartRequest: Encodable {
    let Detach: Bool
    let Tty: Bool
}

private struct DockerExecInspectResponse: Decodable {
    let ExitCode: Int?
}

/// Separates Docker's non-TTY stdcopy frames and retains a bounded prefix for each
/// output stream. The per-stream cap avoids a chatty stdout stream hiding all stderr.
private final class DockerExecOutputCollector: @unchecked Sendable {

    private static let maximumStoredBytesPerStream = 2 * 1024 * 1024

    private let lock = NSLock()
    private var demuxer = StdcopyDemuxer(mode: .multiplexed)
    private var standardOutput = Data()
    private var standardError = Data()
    private var standardOutputWasTruncated = false
    private var standardErrorWasTruncated = false

    func consume(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        append(demuxer.feed(data))
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        append(demuxer.finish())
    }

    func result(exitCode: Int?) -> DockerExecResult {
        lock.lock()
        defer { lock.unlock() }
        return DockerExecResult(
            standardOutput: String(decoding: standardOutput, as: UTF8.self),
            standardError: String(decoding: standardError, as: UTF8.self),
            exitCode: exitCode,
            standardOutputWasTruncated: standardOutputWasTruncated,
            standardErrorWasTruncated: standardErrorWasTruncated)
    }

    private func append(_ frames: [StdcopyDemuxer.Frame]) {
        for frame in frames {
            switch frame.stream {
            case .stdout:
                append(
                    frame.bytes,
                    to: &standardOutput,
                    truncated: &standardOutputWasTruncated)
            case .stderr:
                append(
                    frame.bytes,
                    to: &standardError,
                    truncated: &standardErrorWasTruncated)
            }
        }
    }

    private func append(_ data: Data, to destination: inout Data, truncated: inout Bool) {
        let remaining = Self.maximumStoredBytesPerStream - destination.count
        guard remaining > 0 else {
            if !data.isEmpty { truncated = true }
            return
        }
        let retained = data.prefix(remaining)
        destination.append(retained)
        if retained.count < data.count { truncated = true }
    }
}

// MARK: - Stream plumbing

/// Coordinates attached-exec completion with Task cancellation. The only cancellable
/// resource is the app's socket attachment: Moby runs the exec process with a
/// background context, so the connection close must never be described as killing it.
private final class DockerExecStreamOutcome: @unchecked Sendable {

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var handle: DockerConnectionHandle?
    private var wasCancelled = false
    private var didResume = false

    /// Registers the waiter. Returns `false` after a cancellation that arrived before
    /// the operation installed its continuation; that continuation is already resumed.
    func begin(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
        lock.lock()
        self.continuation = continuation
        if wasCancelled {
            didResume = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        lock.unlock()
        return true
    }

    func adopt(_ handle: DockerConnectionHandle) {
        lock.lock()
        self.handle = handle
        let shouldCancel = wasCancelled
        lock.unlock()
        if shouldCancel { handle.cancel() }
    }

    func cancel() {
        lock.lock()
        wasCancelled = true
        let handle = self.handle
        let continuation = didResume ? nil : self.continuation
        if continuation != nil {
            didResume = true
            self.continuation = nil
        }
        lock.unlock()

        handle?.cancel()
        continuation?.resume(throwing: CancellationError())
    }

    func finish(_ error: Error?) {
        lock.lock()
        guard !didResume, let continuation else {
            lock.unlock()
            return
        }
        didResume = true
        self.continuation = nil
        let cancellationWon = wasCancelled
        lock.unlock()

        if cancellationWon {
            continuation.resume(throwing: CancellationError())
        } else if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

/// A cancellation token for an in-flight stream.
///
/// The consumer holds this; the reader thread holds the connection. Cancelling before
/// the connection is even open has to work — `AsyncThrowingStream.onTermination` can
/// fire while the thread is still inside `connect(2)` — so the flag is authoritative
/// and `adopt` refuses a connection that arrived too late.
private final class DockerConnectionHandle: @unchecked Sendable {

    private let lock = NSLock()
    private var connection: DockerConnection?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Registers the live connection. Returns `false` if cancellation already happened,
    /// in which case the caller must close it and stop.
    func adopt(_ connection: DockerConnection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.connection = connection
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let target = connection
        connection = nil
        lock.unlock()
        target?.shutdownRead()
    }
}

/// A `LineAccumulator` that survives being captured by two `@Sendable` closures.
private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulator = LineAccumulator()

    func feed(_ data: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return accumulator.feed(data)
    }
}

/// A `StatsStreamDecoder` that survives being captured by a `@Sendable` closure.
private final class StatsStreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var decoder = StatsStreamDecoder()

    func admit(_ stats: Wire.Stats) -> StatsSample? {
        lock.lock()
        defer { lock.unlock() }
        return decoder.admit(stats)
    }
}

/// The demuxer and line assembler for one log stream, behind one lock.
private final class LogStreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var demuxer = StdcopyDemuxer()
    private var assembler = LogLineAssembler(parseTimestamps: true)

    func consume(_ data: Data) -> [LogLine] {
        lock.lock()
        defer { lock.unlock() }
        return demuxer.feed(data).flatMap { assembler.consume($0) }
    }

    func flush() -> [LogLine] {
        lock.lock()
        defer { lock.unlock() }
        return demuxer.finish().flatMap { assembler.consume($0) } + assembler.flush()
    }
}

/// Resolves a pull's continuation exactly once.
///
/// The failure can arrive in the body (an `error` line) long before the stream ends,
/// and the stream can also fail on its own; whichever comes first wins, and resuming a
/// continuation twice is a crash rather than a bug report.
private final class PullOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: Error?
    private var resumed = false

    func fail(_ error: Error) {
        lock.lock()
        if failure == nil { failure = error }
        lock.unlock()
    }

    func finish(with error: Error?, continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        guard !resumed else { return lock.unlock() }
        resumed = true
        let outcome = failure ?? error
        lock.unlock()
        if let outcome { continuation.resume(throwing: outcome) } else { continuation.resume() }
    }
}
