// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// HTTP/1.1 request framing for the Docker proxy's client-to-guest direction.
//
// The proxy used to inspect only the first request on a connection and then splice
// the socket raw for the rest of its life. Because the `docker` CLI opens one
// connection, pings, and then reuses it, every admission check the proxy owns was
// skipped for essentially all real traffic. This file supplies the missing piece:
// a bounded, allocation-frugal framer that can walk request after request on a live
// connection without ever buffering a body it does not need to read.

import Darwin
import Foundation

/// A pull-based byte source.
///
/// Modelled directly on `read(2)`: a positive count is data, `0` is end of stream,
/// and a negative value is an error. Expressed as a closure so the framer can be
/// unit-tested against a scripted byte script with no descriptors involved.
struct RelayByteSource {
    let read: (UnsafeMutableRawPointer, Int) -> Int

    /// A source that replays `script` in the given slices, then reports end of stream.
    static func replaying(_ script: [Data]) -> RelayByteSource {
        var remaining = script
        return RelayByteSource { buffer, capacity in
            while let first = remaining.first, first.isEmpty { remaining.removeFirst() }
            guard let first = remaining.first else { return 0 }
            let count = min(capacity, first.count)
            first.withUnsafeBytes { raw in
                _ = memcpy(buffer, raw.baseAddress!, count)
            }
            if count == first.count {
                remaining.removeFirst()
            } else {
                remaining[0] = Data(first.dropFirst(count))
            }
            return count
        }
    }
}

/// A push-based byte sink. `false` means the peer is gone and the caller must stop.
struct RelayByteSink {
    let write: (UnsafeRawBufferPointer) -> Bool

    /// A sink that accumulates everything written, for tests.
    static func collecting(into box: RelayByteBox) -> RelayByteSink {
        RelayByteSink { buffer in
            box.append(Data(buffer))
            return true
        }
    }
}

/// A thread-safe accumulator used by ``RelayByteSink/collecting(into:)``.
final class RelayByteBox {
    private let lock = NSLock()
    private var storage = Data()

    init() {}

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }
}

/// Pulls complete HTTP/1.1 requests, one at a time, from a byte source.
///
/// The framer is deliberately strict. Every shape it cannot frame with certainty is
/// an error rather than a shrug, because "I could not understand this request" used
/// to mean "relay it unread", and that is precisely how a `-v /etc/hosts:/x` bind
/// reached the guest unchecked. Being strict is affordable here: the only clients
/// are Docker's own CLI, Compose, BuildKit and libraries built on `net/http`, none of
/// which emit the ambiguous framings this rejects.
///
/// Bodies are never copied unless a caller explicitly asks for one. ``streamBody(_:to:)``
/// walks a body of any size — a `docker build` context, a `docker cp` archive — while
/// forwarding it straight from the read buffer, so the per-connection memory cost is
/// the same fixed 64 KiB the raw splice used.
final class DockerRequestFramer {

    /// Largest request head the framer will assemble before giving up. Docker's own
    /// heads are a few hundred bytes; this matches the usual server-side limit.
    static let maximumHeadBytes = 64 * 1024

    /// Largest single line accepted inside a chunked body (size lines and trailers).
    private static let maximumChunkLineBytes = 8 * 1024

    /// Read granularity. Matches ``FDRelay/copyBufferBytes`` so a spliced connection
    /// and a framed one make the same syscall pattern.
    private static let readChunkBytes = 64 * 1024

    /// Above this many already-consumed bytes the pending buffer is compacted.
    private static let compactionThresholdBytes = 256 * 1024

    enum Failure: Error, Equatable, CustomStringConvertible {
        /// `read(2)` failed on the client socket.
        case sourceFailed
        /// The sink refused a write; the far side is gone.
        case sinkFailed
        /// End of stream arrived in the middle of a request.
        case truncated
        case oversizedHead
        case malformedHead(String)
        /// Both `Content-Length` and `Transfer-Encoding` were present, or
        /// `Content-Length` was repeated. Either is a request-smuggling shape.
        case conflictingFraming
        case unsupportedTransferEncoding(String)
        case malformedChunkedBody
        case bodyTooLarge(limit: Int)

        var description: String {
            switch self {
            case .sourceFailed: return "the Docker client connection failed"
            case .sinkFailed: return "the Docker Engine connection failed"
            case .truncated: return "the Docker client closed the connection mid-request"
            case .oversizedHead: return "the request head exceeded \(DockerRequestFramer.maximumHeadBytes) bytes"
            case .malformedHead(let detail): return "the request head was malformed: \(detail)"
            case .conflictingFraming:
                return "the request combined Content-Length with Transfer-Encoding, or repeated Content-Length"
            case .unsupportedTransferEncoding(let value):
                return "the request used an unsupported Transfer-Encoding `\(value)`"
            case .malformedChunkedBody: return "the request had a malformed chunked body"
            case .bodyTooLarge(let limit):
                return "the request body exceeded morbstack's \(limit)-byte inspection limit"
            }
        }
    }

    /// How the body that follows a head is delimited.
    enum BodyFraming: Equatable {
        case empty
        case fixed(Int)
        case chunked
    }

    /// One framed request head, with its body still unread on the wire.
    struct Request: Equatable {
        var head: HTTPRequestHead
        /// The head exactly as it arrived, terminator included.
        var rawHead: Data
        var framing: BodyFraming
    }

    enum HeadOutcome {
        case request(Request)
        /// End of stream landed cleanly on a request boundary.
        case endOfStream
        case failed(Failure)
    }

    private let source: RelayByteSource
    private var pending: [UInt8] = []
    private var cursor = 0

    init(source: RelayByteSource) {
        self.source = source
    }

    /// Bytes already pulled off the socket but not yet consumed by the framer.
    ///
    /// Handed to the raw splice when a connection is hijacked: a client that wrote
    /// its first stdin bytes in the same segment as its `attach` request must not
    /// lose them.
    func takePendingBytes() -> Data {
        guard cursor < pending.count else {
            pending.removeAll(keepingCapacity: true)
            cursor = 0
            return Data()
        }
        let out = Data(pending[cursor...])
        pending.removeAll(keepingCapacity: true)
        cursor = 0
        return out
    }

    // MARK: - Heads

    /// Frames the next request head, leaving its body unread.
    func nextHead() -> HeadOutcome {
        while true {
            if cursor < pending.count {
                let end = min(pending.count, cursor + Self.maximumHeadBytes)
                let window = Data(pending[cursor..<end])
                do {
                    if let parsed = try MinimalHTTP.parseRequestHead(window) {
                        let rawHead = Data(window.prefix(parsed.consumed))
                        cursor += parsed.consumed
                        switch Self.bodyFraming(for: parsed.head) {
                        case .failure(let failure):
                            return .failed(failure)
                        case .success(let framing):
                            return .request(
                                Request(head: parsed.head, rawHead: rawHead, framing: framing))
                        }
                    }
                } catch {
                    return .failed(.malformedHead("\(error)"))
                }
                if pending.count - cursor >= Self.maximumHeadBytes {
                    return .failed(.oversizedHead)
                }
            }

            switch fill() {
            case .more:
                continue
            case .endOfStream:
                return cursor == pending.count ? .endOfStream : .failed(.truncated)
            case .failed:
                return .failed(.sourceFailed)
            }
        }
    }

    /// Derives the body framing from a head, rejecting every ambiguous combination.
    ///
    /// RFC 9112 §6.1 lets a server choose between `Transfer-Encoding` and
    /// `Content-Length` when both appear. Choosing is how request smuggling happens,
    /// and a proxy that inspects bodies for admission must not disagree with the
    /// server behind it about where one request stops. Refusing is the only answer
    /// that cannot be desynchronised.
    static func bodyFraming(for head: HTTPRequestHead) -> Result<BodyFraming, Failure> {
        let transferEncoding = head.headers["transfer-encoding"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let contentLength = head.headers["content-length"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let transferEncoding, !transferEncoding.isEmpty {
            if let contentLength, !contentLength.isEmpty {
                return .failure(.conflictingFraming)
            }
            guard transferEncoding.lowercased() == "chunked" else {
                return .failure(.unsupportedTransferEncoding(transferEncoding))
            }
            return .success(.chunked)
        }

        guard let contentLength, !contentLength.isEmpty else { return .success(.empty) }
        // `MinimalHTTP` joins repeated headers with ", ", so a duplicated
        // Content-Length arrives here as "5, 5" and fails this parse. That is the
        // intent: repeats are the other half of the smuggling shape above.
        guard let length = Int(contentLength), length >= 0 else {
            return .failure(.conflictingFraming)
        }
        return .success(length == 0 ? .empty : .fixed(length))
    }

    // MARK: - Bodies

    /// Forwards a body to `sink` without ever holding more than one read buffer of it.
    func streamBody(_ framing: BodyFraming, to sink: RelayByteSink) -> Failure? {
        walkBody(framing, maximumDecodedBytes: nil) { buffer, _ in sink.write(buffer) }
    }

    /// Reads a body into memory so it can be inspected.
    ///
    /// - Returns: `raw` is the body exactly as it arrived (chunk framing included) so
    ///   it can be relayed byte-for-byte; `decoded` is the entity body the admission
    ///   checks read.
    func bufferBody(
        _ framing: BodyFraming,
        limit: Int
    ) -> Result<(raw: Data, decoded: Data), Failure> {
        var raw = Data()
        var decoded = Data()
        if case .fixed(let length) = framing {
            raw.reserveCapacity(length)
            decoded.reserveCapacity(length)
        }
        let failure = walkBody(framing, maximumDecodedBytes: limit) { buffer, isEntityData in
            raw.append(contentsOf: buffer)
            if isEntityData { decoded.append(contentsOf: buffer) }
            return true
        }
        if let failure { return .failure(failure) }
        return .success((raw, decoded))
    }

    /// Walks the body, handing every consumed byte range to `emit`.
    ///
    /// `emit` is called with a pointer into the framer's own read buffer and a flag
    /// saying whether those bytes are entity data (as opposed to chunk framing). It
    /// is always called before the next refill, so the pointer stays valid.
    private func walkBody(
        _ framing: BodyFraming,
        maximumDecodedBytes: Int?,
        emit: (UnsafeRawBufferPointer, Bool) -> Bool
    ) -> Failure? {
        switch framing {
        case .empty:
            return nil

        case .fixed(let length):
            if let maximumDecodedBytes, length > maximumDecodedBytes {
                return .bodyTooLarge(limit: maximumDecodedBytes)
            }
            return walkExactly(length, isEntityData: true, emit: emit)

        case .chunked:
            var decodedTotal = 0
            while true {
                switch takeLine() {
                case .failure(let failure):
                    return failure
                case .success(let line):
                    let text = String(
                        decoding: pending[line.start..<(line.start + line.contentLength)],
                        as: UTF8.self)
                    guard let size = ChunkedBodyDecoder.parseChunkSize(text) else {
                        return .malformedChunkedBody
                    }
                    if let failure = emitPending(line.range, isEntityData: false, emit: emit) {
                        return failure
                    }

                    if size == 0 {
                        // Trailer fields, then the blank line that ends the body.
                        while true {
                            switch takeLine() {
                            case .failure(let failure):
                                return failure
                            case .success(let trailer):
                                let isBlank = trailer.contentLength == 0
                                if let failure = emitPending(
                                    trailer.range, isEntityData: false, emit: emit)
                                {
                                    return failure
                                }
                                if isBlank { return nil }
                            }
                        }
                    }

                    if let maximumDecodedBytes {
                        decodedTotal += size
                        if decodedTotal > maximumDecodedBytes {
                            return .bodyTooLarge(limit: maximumDecodedBytes)
                        }
                    }
                    if let failure = walkExactly(size, isEntityData: true, emit: emit) {
                        return failure
                    }
                    // The chunk's own terminator must be an empty line.
                    switch takeLine() {
                    case .failure(let failure):
                        return failure
                    case .success(let terminator):
                        guard terminator.contentLength == 0 else { return .malformedChunkedBody }
                        if let failure = emitPending(
                            terminator.range, isEntityData: false, emit: emit)
                        {
                            return failure
                        }
                    }
                }
            }
        }
    }

    private func walkExactly(
        _ count: Int,
        isEntityData: Bool,
        emit: (UnsafeRawBufferPointer, Bool) -> Bool
    ) -> Failure? {
        var remaining = count
        while remaining > 0 {
            if cursor == pending.count {
                switch fill() {
                case .more: break
                case .endOfStream: return .truncated
                case .failed: return .sourceFailed
                }
            }
            let take = min(remaining, pending.count - cursor)
            if let failure = emitPending(
                cursor..<(cursor + take), isEntityData: isEntityData, emit: emit)
            {
                return failure
            }
            remaining -= take
        }
        return nil
    }

    /// Emits `range` from the pending buffer and advances the cursor past it.
    private func emitPending(
        _ range: Range<Int>,
        isEntityData: Bool,
        emit: (UnsafeRawBufferPointer, Bool) -> Bool
    ) -> Failure? {
        let accepted = pending.withUnsafeBytes { raw -> Bool in
            emit(UnsafeRawBufferPointer(rebasing: raw[range]), isEntityData)
        }
        cursor = range.upperBound
        return accepted ? nil : .sinkFailed
    }

    private struct Line {
        /// The whole line including its terminator, as an index range into `pending`.
        let range: Range<Int>
        /// Bytes before the terminator.
        let contentLength: Int
        var start: Int { range.lowerBound }
    }

    /// Finds the next `LF`-terminated line without consuming it.
    private func takeLine() -> Result<Line, Failure> {
        while true {
            var index = cursor
            while index < pending.count {
                if pending[index] == 0x0A {
                    let contentEnd = (index > cursor && pending[index - 1] == 0x0D) ? index - 1 : index
                    return .success(
                        Line(range: cursor..<(index + 1), contentLength: contentEnd - cursor))
                }
                index += 1
            }
            if pending.count - cursor >= Self.maximumChunkLineBytes {
                return .failure(.malformedChunkedBody)
            }
            switch fill() {
            case .more: continue
            case .endOfStream: return .failure(.truncated)
            case .failed: return .failure(.sourceFailed)
            }
        }
    }

    // MARK: - Buffer management

    private enum FillOutcome {
        case more
        case endOfStream
        case failed
    }

    private func fill() -> FillOutcome {
        compactIfNeeded()
        var chunk = [UInt8](repeating: 0, count: Self.readChunkBytes)
        let count = chunk.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return source.read(base, raw.count)
        }
        if count > 0 {
            pending.append(contentsOf: chunk[0..<count])
            return .more
        }
        return count == 0 ? .endOfStream : .failed
    }

    private func compactIfNeeded() {
        if cursor == pending.count {
            pending.removeAll(keepingCapacity: true)
            cursor = 0
        } else if cursor >= Self.compactionThresholdBytes {
            pending.removeFirst(cursor)
            cursor = 0
        }
    }
}

/// Byte-preserving edits to a request head the proxy has already parsed.
///
/// Both operations rewrite exactly one header and copy every other byte through,
/// including header spelling and line endings, so a request that Morbstack forwards
/// stays as close to what the client wrote as the change allows.
enum HTTPRequestHeadRewriting {

    /// Replaces the single `Content-Length` value. `nil` when the head does not have
    /// exactly one such header, which the caller has already proved it does.
    static func replacingContentLength(in head: Data, bodyLength: Int) -> Data? {
        guard bodyLength >= 0 else { return nil }
        let bytes = [UInt8](head)
        var cursor = 0
        var foundContentLength = false
        var rewritten = Data()

        while let (contentEnd, next) = MinimalHTTP.lineBounds(bytes, from: cursor) {
            let line = String(decoding: bytes[cursor..<contentEnd], as: UTF8.self)
            if line.isEmpty {
                rewritten.append(contentsOf: bytes[cursor..<next])
                return foundContentLength ? rewritten : nil
            }

            if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                if name == "content-length" {
                    guard !foundContentLength else { return nil }
                    foundContentLength = true
                    rewritten.append(Data("Content-Length: \(bodyLength)".utf8))
                    rewritten.append(contentsOf: bytes[contentEnd..<next])
                    cursor = next
                    continue
                }
            }
            rewritten.append(contentsOf: bytes[cursor..<next])
            cursor = next
        }
        return nil
    }

    /// Removes every occurrence of `name`, keeping the rest of the head verbatim.
    ///
    /// Used for `Expect: 100-continue`: once the proxy has answered the expectation
    /// itself in order to read the body it must inspect, forwarding the header would
    /// make the Engine answer it a second time.
    static func removingHeader(named name: String, in head: Data) -> Data? {
        let target = name.lowercased()
        let bytes = [UInt8](head)
        var cursor = 0
        var rewritten = Data()

        while let (contentEnd, next) = MinimalHTTP.lineBounds(bytes, from: cursor) {
            let line = String(decoding: bytes[cursor..<contentEnd], as: UTF8.self)
            if line.isEmpty {
                rewritten.append(contentsOf: bytes[cursor..<next])
                return rewritten
            }
            if let colon = line.firstIndex(of: ":"),
               String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased() == target
            {
                cursor = next
                continue
            }
            rewritten.append(contentsOf: bytes[cursor..<next])
            cursor = next
        }
        return nil
    }
}

/// Recognises the Engine exchanges that stop being HTTP part-way through.
///
/// Detection is deliberately two-sided. The request side nominates *candidates* — a
/// generous set, because a missed hijack would break `docker exec` — and the response
/// side confirms them from what dockerd actually replied. Over-nomination therefore
/// costs nothing: a candidate whose response turns out to be an ordinary one simply
/// goes back to being framed.
enum DockerHijackDetection {

    /// Whether this request may take the connection over.
    static func isHijackCandidate(_ head: HTTPRequestHead) -> Bool {
        let path = head.target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let last = components.last else { return false }

        // The Engine documents `/events` as an ordinary streaming HTTP response.
        // Do not let an accidental or stale Upgrade header turn it into a raw splice:
        // event consumers need the response's chunk framing and a clean close to
        // reconnect correctly.
        if head.method.uppercased() == "GET", last == "events" { return false }

        // Container export is an ordinary tar response. It must retain HTTP chunk
        // framing and cancellation semantics even if a stale Upgrade header arrives.
        if head.method.uppercased() == "GET",
           components.count >= 3,
           components[components.count - 3] == "containers",
           last == "export" {
            return false
        }

        // Both live and one-shot container statistics are JSON over ordinary HTTP.
        // The live form remains open until the client cancels it; neither form is an
        // attach-style takeover, even when a stale Upgrade header is present.
        if head.method.uppercased() == "GET",
           components.count >= 3,
           components[components.count - 3] == "containers",
           last == "stats" {
            return false
        }

        // Image pull and import share this ordinary streaming HTTP route.
        // `fromImage`/`tag` and `fromSrc=-`/`repo` are query values the relay must
        // preserve; an import archive is a request body, while pull/import progress
        // or failures are response data rather than a connection upgrade.
        if head.method.uppercased() == "POST",
           components.count >= 2,
           components[components.count - 2] == "images",
           last == "create" {
            return false
        }

        // Image pushes carry their repository in the escaped route path, with the
        // tag in the query and registry credentials in a request header. Their
        // progress and terminal errors stay in an ordinary JSON HTTP response;
        // closing that response is how the Engine observes push cancellation.
        if head.method.uppercased() == "POST",
           components.count >= 3,
           components[components.count - 3] == "images",
           last == "push" {
            return false
        }

        // The build context is a regular (often chunked) tar request and its output
        // is a regular JSON response stream. Client disconnect is build cancellation,
        // so this route must keep HTTP framing even if a stale Upgrade header appears.
        if head.method.uppercased() == "POST", last == "build" { return false }

        // Image save/load use ordinary tar streams. Neither an exported OCI/Docker
        // archive nor an import-progress response is a connection upgrade.
        if head.method.uppercased() == "GET",
           components.count >= 2,
           components[components.count - 2] == "images",
           last == "get" {
            return false
        }
        if head.method.uppercased() == "POST",
           components.count >= 2,
           components[components.count - 2] == "images",
           last == "load" {
            return false
        }

        if head.headers["upgrade"] != nil { return true }
        if (head.headers["connection"] ?? "").lowercased().contains("upgrade") { return true }

        // `POST /containers/{id}/attach` and its `GET` websocket sibling are
        // the only container-attach routes that may switch this connection to raw
        // stdin/stdout/stderr. `resize` and `logs?follow=1` stay ordinary HTTP.
        if head.method.uppercased() == "POST",
           components.count >= 3,
           components[components.count - 3] == "containers",
           last == "attach" {
            return true
        }
        if head.method.uppercased() == "GET",
           components.count >= 4,
           components[components.count - 4] == "containers",
           components[components.count - 2] == "attach",
           last == "ws" {
            return true
        }
        // Only `POST /exec/{id}/start` attaches an exec stream. In particular,
        // `/containers/{id}/exec` and `/exec/{id}/json` remain ordinary HTTP.
        if head.method.uppercased() == "POST",
           components.count >= 3,
           components[components.count - 3] == "exec",
           last == "start" {
            return true
        }
        // BuildKit's session and gRPC upgrades.
        if last == "session" || last == "grpc" { return true }
        return false
    }

    /// Whether a response head proves the connection was taken over.
    static func confirmsHijack(_ head: HTTPResponseHead) -> Bool {
        if head.statusCode == 101 { return true }
        guard (200..<300).contains(head.statusCode) else { return false }
        let contentType = (head.headers["content-type"] ?? "").lowercased()
        return contentType.contains("vnd.docker.raw-stream")
            || contentType.contains("vnd.docker.multiplexed-stream")
    }
}

/// The Docker-shaped error document the proxy answers with when it refuses a request.
enum DockerEngineErrorResponse {

    static func bytes(statusCode: Int, reason: String, message: String, closeConnection: Bool = true) -> Data {
        let sanitized = message
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
        let body = "{\"message\":\"\(sanitized)\"}"
        var response = "HTTP/1.1 \(statusCode) \(reason)\r\n"
        response += "Content-Type: application/json\r\n"
        response += "Content-Length: \(body.utf8.count)\r\n"
        if closeConnection { response += "Connection: close\r\n" }
        response += "\r\n"
        response += body
        return Data(response.utf8)
    }
}
