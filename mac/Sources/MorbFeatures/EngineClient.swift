// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// A small, synchronous Docker Engine API client over a unix socket.
//
// Morbstack already has a *relay* for the Engine API (MorbstackKit's DockerProxy),
// and a decoder for the two documents the port forwarder cares about
// (DockerAPIDecoding). Neither is a general-purpose client: the relay is a
// byte-for-byte pipe with no opinion about what flows through it, and the decoder
// only knows `containers/json` and `/events`.
//
// The features in this module — the MCP server, `morb migrate`, `morb bench`,
// `morb scan`, `morb debug` — all need the same third thing: issue an arbitrary
// Engine API request, get a status and a body back, and sometimes keep reading a
// stream until told to stop. That is what this is, built on MorbstackKit's existing
// HTTP framing primitives so there is exactly one chunked-transfer decoder in the
// repository rather than two.

import Darwin
import Foundation
import MorbstackKit

/// One complete Engine API response.
public struct EngineResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// `true` for 2xx.
    public var isSuccess: Bool { (200..<300).contains(status) }

    /// The body decoded as UTF-8, lossily — for error messages and log text.
    public var text: String { String(decoding: body, as: UTF8.self) }

    /// Docker error bodies are `{"message": "..."}`. Falls back to the raw text.
    public var engineMessage: String {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let message = object["message"] as? String {
            return message
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "HTTP \(status)" : trimmed
    }
}

/// Errors this client raises. Distinct from ``MorbError`` so callers can tell an
/// engine-said-no (which has a status code and a message the user should see) from a
/// socket-level failure (which usually means the VM is not running).
public enum EngineError: Error, CustomStringConvertible, LocalizedError {
    /// The socket could not be reached at all.
    case unreachable(String)
    /// A transport-level failure mid-request.
    case transport(String)
    /// The engine answered, and the answer was a refusal.
    case engine(status: Int, message: String)
    /// The engine answered with something that was not the expected JSON shape.
    case malformed(String)
    /// The request did not finish inside its deadline.
    case timedOut(String)

    public var description: String {
        switch self {
        case .unreachable(let m): return "docker engine unreachable: \(m)"
        case .transport(let m): return "docker engine transport error: \(m)"
        case .engine(let status, let message): return "docker engine returned \(status): \(message)"
        case .malformed(let m): return "unexpected response from the docker engine: \(m)"
        case .timedOut(let m): return "timed out talking to the docker engine: \(m)"
        }
    }

    public var errorDescription: String? { description }
}

/// A blocking Docker Engine API client speaking HTTP/1.1 over a unix socket.
///
/// Deliberately one-request-per-connection (`Connection: close`). Keep-alive would
/// save a connect on a socket that is already local, and would buy a whole class of
/// state bugs — a half-read body poisoning the next request — for that saving.
public final class EngineClient: @unchecked Sendable {

    /// The API version every path is prefixed with.
    ///
    /// Pinned rather than negotiated: an unversioned path means "whatever the daemon
    /// defaults to", which silently changes the response shape under us when the
    /// pinned guest Docker version moves. 1.43 is Docker 24+, comfortably below the
    /// guest's 29.7.1, and every field these features read exists there.
    public static let apiVersion = "v1.43"

    public let socketPath: String

    public init(socketPath: String? = nil) {
        self.socketPath = socketPath ?? MorbPaths.dockerSocket.path
    }

    /// The client for whatever engine `DOCKER_HOST` names, when it names a unix socket.
    ///
    /// Used by `morb migrate` to reach *another* engine (Docker Desktop's) without
    /// hardcoding its socket path.
    public static func forUnixSocket(_ path: String) -> EngineClient {
        EngineClient(socketPath: path)
    }

    // MARK: - Path construction

    /// Builds `/v1.43/<path>?<query>` with values percent-encoded.
    public static func path(_ path: String, query: [(String, String)] = []) -> String {
        let base = path.hasPrefix("/") ? path : "/" + path
        var full = "/\(apiVersion)\(base)"
        if !query.isEmpty {
            let encoded = query.map { key, value in
                "\(MinimalHTTP.percentEncodeQueryValue(key))=\(MinimalHTTP.percentEncodeQueryValue(value))"
            }
            full += "?" + encoded.joined(separator: "&")
        }
        return full
    }

    // MARK: - Requests

    /// Issues one request and reads the whole response.
    ///
    /// - Parameter timeout: a deadline on *inactivity*, applied with `SO_RCVTIMEO`, not
    ///   on total duration. A `docker pull` legitimately takes minutes while producing
    ///   a steady trickle of progress; a wedged engine produces nothing at all. The
    ///   distinction that matters is silence, not elapsed time.
    @discardableResult
    public func request(
        _ method: String,
        _ path: String,
        query: [(String, String)] = [],
        body: Data? = nil,
        contentType: String? = nil,
        timeout: TimeInterval = 60
    ) throws -> EngineResponse {
        var collected = Data()
        var head: HTTPResponseHead?
        try stream(
            method, path, query: query, body: body, contentType: contentType, timeout: timeout,
            onChunk: { chunk, _ in
                collected.append(chunk)
                return true
            },
            onHead: { head = $0 })
        guard let head else {
            throw EngineError.transport("no response head")
        }
        return EngineResponse(status: head.statusCode, headers: head.headers, body: collected)
    }

    /// Issues a request as JSON and decodes the reply as JSON.
    ///
    /// - Throws: ``EngineError/engine(status:message:)`` for any non-2xx, so callers
    ///   never have to remember to check.
    public func json(
        _ method: String,
        _ path: String,
        query: [(String, String)] = [],
        body: Any? = nil,
        timeout: TimeInterval = 60
    ) throws -> Any {
        var payload: Data?
        if let body {
            payload = try JSONSerialization.data(withJSONObject: body, options: [])
        }
        let response = try request(
            method, path, query: query, body: payload,
            contentType: payload == nil ? nil : "application/json", timeout: timeout)
        guard response.isSuccess else {
            throw EngineError.engine(status: response.status, message: response.engineMessage)
        }
        if response.body.isEmpty { return NSNull() }
        do {
            return try JSONSerialization.jsonObject(with: response.body, options: [.fragmentsAllowed])
        } catch {
            throw EngineError.malformed("body is not JSON (\(response.body.count) bytes)")
        }
    }

    /// `json` narrowed to an array of objects, which is most Docker list endpoints.
    public func jsonArray(
        _ method: String, _ path: String, query: [(String, String)] = [], timeout: TimeInterval = 60
    ) throws -> [[String: Any]] {
        let value = try json(method, path, query: query, timeout: timeout)
        guard let array = value as? [[String: Any]] else {
            throw EngineError.malformed("expected a JSON array of objects at \(path)")
        }
        return array
    }

    /// `json` narrowed to a single object.
    public func jsonObject(
        _ method: String, _ path: String, query: [(String, String)] = [], body: Any? = nil,
        timeout: TimeInterval = 60
    ) throws -> [String: Any] {
        let value = try json(method, path, query: query, body: body, timeout: timeout)
        guard let object = value as? [String: Any] else {
            throw EngineError.malformed("expected a JSON object at \(path)")
        }
        return object
    }

    /// Issues a request and delivers the body incrementally.
    ///
    /// - Parameter onChunk: called with each newly available slice of the *decoded*
    ///   body (chunked transfer encoding already removed). Return `false` to stop
    ///   reading and close the connection — which is how the events subscription and
    ///   `logs --follow` terminate without a signal.
    /// - Parameter onHead: called once, with the response head, before any body.
    public func stream(
        _ method: String,
        _ path: String,
        query: [(String, String)] = [],
        body: Data? = nil,
        contentType: String? = nil,
        timeout: TimeInterval = 60,
        onChunk: (Data, HTTPResponseHead) -> Bool,
        onHead: ((HTTPResponseHead) -> Void)? = nil
    ) throws {
        let fd = try openSocket(timeout: timeout)
        defer { Darwin.close(fd) }

        try writeRequest(fd: fd, method: method, path: path, query: query, body: body, contentType: contentType)

        var buffer = Data()
        var head: HTTPResponseHead?
        var chunked = ChunkedBodyDecoder()
        var remainingContentLength: Int?
        var scratch = [UInt8](repeating: 0, count: 64 * 1024)

        while true {
            let n = scratch.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                var read = 0
                repeat {
                    read = Darwin.read(fd, base, raw.count)
                } while read < 0 && errno == EINTR
                return read
            }
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw EngineError.timedOut("no data for \(Int(timeout))s on \(method) \(path)")
                }
                throw EngineError.transport(String(cString: strerror(errno)))
            }
            if n == 0 { break }  // EOF
            buffer.append(contentsOf: scratch[0..<n])

            if head == nil {
                guard let parsed = try MinimalHTTP.parseHead(buffer) else { continue }
                head = parsed.head
                onHead?(parsed.head)
                remainingContentLength = parsed.head.contentLength
                buffer.removeFirst(parsed.consumed)
                if remainingContentLength == 0 { return }
            }
            guard let head else { continue }

            let payload: Data
            if head.isChunked {
                payload = try chunked.feed(buffer)
            } else {
                payload = buffer
            }
            buffer.removeAll(keepingCapacity: true)

            if !payload.isEmpty, !onChunk(payload, head) { return }
            if head.isChunked, chunked.isComplete { return }
            if let remaining = remainingContentLength {
                let left = remaining - payload.count
                remainingContentLength = left
                if left <= 0 { return }
            }
        }
        if head == nil {
            throw EngineError.transport("connection closed before a response head arrived")
        }
    }

    /// Streams a response body straight to a file instead of accumulating it in memory.
    ///
    /// `GET /images/{name}/get` returns a docker-save tar of an entire image. Reading
    /// that into a `Data` is fine for `alpine` and ruinous for a 12 GB CUDA image, and
    /// the difference between the two is not visible at the call site — so the
    /// operations that handle image payloads use this and never `request`.
    ///
    /// - Parameter onProgress: called with the running byte total, roughly per read.
    ///   Return `false` to abort; the partial file is deleted before returning.
    /// - Returns: the response head and the number of body bytes written.
    @discardableResult
    public func download(
        _ method: String,
        _ path: String,
        query: [(String, String)] = [],
        to fileURL: URL,
        timeout: TimeInterval = 300,
        onProgress: ((Int64) -> Bool)? = nil
    ) throws -> (head: HTTPResponseHead, bytes: Int64) {
        let manager = FileManager.default
        try? manager.removeItem(at: fileURL)
        guard manager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw EngineError.transport("could not create \(fileURL.path)")
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        var written: Int64 = 0
        var head: HTTPResponseHead?
        var aborted = false

        func cleanUp() { try? handle.close() }

        do {
            try stream(
                method, path, query: query, timeout: timeout,
                onChunk: { chunk, responseHead in
                    // A 404 or a 500 has a short JSON body, not a tar. Writing it to the
                    // destination file would leave a "successfully exported" image that
                    // is thirty bytes of error message.
                    guard (200..<300).contains(responseHead.statusCode) else { return true }
                    handle.write(chunk)
                    written += Int64(chunk.count)
                    if let onProgress, !onProgress(written) {
                        aborted = true
                        return false
                    }
                    return true
                },
                onHead: { head = $0 })
        } catch {
            cleanUp()
            try? manager.removeItem(at: fileURL)
            throw error
        }
        cleanUp()

        guard let head else {
            try? manager.removeItem(at: fileURL)
            throw EngineError.transport("no response head")
        }
        if aborted {
            try? manager.removeItem(at: fileURL)
            throw EngineError.transport("download of \(path) was cancelled after \(written) bytes")
        }
        guard (200..<300).contains(head.statusCode) else {
            // The body we deliberately did not write is the error message, so re-read
            // it the cheap way rather than leaving the caller with a bare status code.
            try? manager.removeItem(at: fileURL)
            let detail = (try? request(method, path, query: query, timeout: 30).engineMessage) ?? "HTTP \(head.statusCode)"
            throw EngineError.engine(status: head.statusCode, message: detail)
        }
        return (head, written)
    }

    /// Streams a file up as the request body.
    ///
    /// The counterpart of ``download(_:_:query:to:timeout:onProgress:)``, and the
    /// reason `morb migrate` can move an image collection larger than the Mac's RAM:
    /// `POST /images/load` gets a real `Content-Length` and the file is fed to the
    /// socket a chunk at a time rather than being materialised as one `Data`.
    @discardableResult
    public func upload(
        _ method: String,
        _ path: String,
        query: [(String, String)] = [],
        from fileURL: URL,
        contentType: String = "application/x-tar",
        timeout: TimeInterval = 600,
        onProgress: ((Int64) -> Void)? = nil,
        shouldContinue: (() -> Bool)? = nil,
        onUploadComplete: (() -> Void)? = nil
    ) throws -> EngineResponse {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        // Size the already-open descriptor rather than resolving the path once for a
        // size and then opening it again. That keeps Content-Length attached to the
        // actual file descriptor supplying the upload bytes.
        var sourceStat = stat()
        guard Darwin.fstat(handle.fileDescriptor, &sourceStat) == 0 else {
            throw EngineError.transport("could not stat the opened upload source")
        }
        guard (sourceStat.st_mode & S_IFMT) == S_IFREG else {
            throw EngineError.transport("upload source is not a regular file")
        }
        let size = Int64(sourceStat.st_size)

        let fd = try openSocket(timeout: timeout)
        defer { Darwin.close(fd) }

        var text = "\(method) \(Self.path(path, query: query)) HTTP/1.1\r\n"
        text += "Host: morbstack\r\n"
        text += "Accept: application/json\r\n"
        text += "User-Agent: morbstack/\(MorbVersion.string)\r\n"
        text += "Connection: close\r\n"
        text += "Content-Type: \(contentType)\r\n"
        text += "Content-Length: \(size)\r\n"
        text += "\r\n"
        try writeAll(fd: fd, Data(text.utf8))

        var sent: Int64 = 0
        while sent < size {
            guard shouldContinue?() ?? true else {
                // Closing this one-request connection tells Docker that the promised
                // Content-Length will not arrive. The caller still has to treat a
                // cancelled load as an unknown engine outcome, because Docker may
                // have consumed a prefix before EOF reached it.
                throw EngineError.transport("upload cancelled after \(sent) bytes")
            }
            // Keep every read inside the original descriptor size. If another writer
            // grows this file after `fstat`, the request still never sends more bytes
            // than its Content-Length promised to Docker.
            let remaining = size - sent
            let chunk = handle.readData(ofLength: min(1 << 20, Int(remaining)))
            if chunk.isEmpty { break }
            try writeAll(fd: fd, chunk)
            sent += Int64(chunk.count)
            onProgress?(sent)
        }
        guard sent == size else {
            // Bailing out here rather than letting the engine block waiting for the
            // bytes we promised in Content-Length and will never send.
            throw EngineError.transport("sent \(sent) of \(size) bytes from \(fileURL.lastPathComponent)")
        }

        // The complete source is now in Docker's hands, but image unpacking and tag
        // registration can still be in progress while `readResponse` waits. A UI can
        // use this boundary to stop offering a misleading cancellable progress bar.
        onUploadComplete?()
        return try readResponse(fd: fd, timeout: timeout, label: "\(method) \(path)")
    }

    /// Reads one complete response off an already-written connection.
    private func readResponse(fd: Int32, timeout: TimeInterval, label: String) throws -> EngineResponse {
        var buffer = Data()
        var body = Data()
        var head: HTTPResponseHead?
        var chunked = ChunkedBodyDecoder()
        var remaining: Int?
        var scratch = [UInt8](repeating: 0, count: 64 * 1024)

        while true {
            let n = scratch.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                var read = 0
                repeat { read = Darwin.read(fd, base, raw.count) } while read < 0 && errno == EINTR
                return read
            }
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw EngineError.timedOut("no data for \(Int(timeout))s on \(label)")
                }
                throw EngineError.transport(String(cString: strerror(errno)))
            }
            if n == 0 { break }
            buffer.append(contentsOf: scratch[0..<n])

            if head == nil {
                guard let parsed = try MinimalHTTP.parseHead(buffer) else { continue }
                head = parsed.head
                remaining = parsed.head.contentLength
                buffer.removeFirst(parsed.consumed)
                if remaining == 0 { break }
            }
            guard let head else { continue }
            let payload = head.isChunked ? try chunked.feed(buffer) : buffer
            buffer.removeAll(keepingCapacity: true)
            body.append(payload)
            if head.isChunked, chunked.isComplete { break }
            if let left = remaining {
                remaining = left - payload.count
                if left - payload.count <= 0 { break }
            }
        }
        guard let head else {
            throw EngineError.transport("connection closed before a response head arrived on \(label)")
        }
        return EngineResponse(status: head.statusCode, headers: head.headers, body: body)
    }

    /// `true` when `GET /_ping` answers 200.
    public func ping(timeout: TimeInterval = 5) -> Bool {
        guard let response = try? request("GET", "/_ping", timeout: timeout) else { return false }
        return response.isSuccess
    }

    /// The engine's own version document, or `nil` when it is not answering.
    public func version(timeout: TimeInterval = 10) -> [String: Any]? {
        try? jsonObject("GET", "/version", timeout: timeout)
    }

    // MARK: - Socket plumbing

    private func openSocket(timeout: TimeInterval) throws -> Int32 {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw EngineError.unreachable("no socket at \(socketPath)")
        }
        let fd: Int32
        do {
            fd = try UnixSocketClient.connect(path: socketPath, timeout: min(timeout, 10))
        } catch {
            throw EngineError.unreachable("\(socketPath): \((error as? MorbError)?.description ?? "\(error)")")
        }
        var tv = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private func writeRequest(
        fd: Int32, method: String, path: String, query: [(String, String)],
        body: Data?, contentType: String?
    ) throws {
        let target = Self.path(path, query: query)
        var text = "\(method) \(target) HTTP/1.1\r\n"
        text += "Host: morbstack\r\n"
        text += "Accept: application/json\r\n"
        text += "User-Agent: morbstack/\(MorbVersion.string)\r\n"
        text += "Connection: close\r\n"
        if let contentType { text += "Content-Type: \(contentType)\r\n" }
        text += "Content-Length: \(body?.count ?? 0)\r\n"
        text += "\r\n"
        var out = Data(text.utf8)
        if let body { out.append(body) }
        try writeAll(fd: fd, out)
    }

    private func writeAll(fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw EngineError.transport("write: \(String(cString: strerror(errno)))")
                }
                if written == 0 { throw EngineError.transport("write returned 0") }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
        }
    }
}

// MARK: - Docker stream demultiplexing

/// Splits Docker's multiplexed attach/exec/logs stream into stdout and stderr.
///
/// When a container has no TTY, Docker frames its output: an 8-byte header whose
/// first byte is the stream id (1 = stdout, 2 = stderr) and whose last four bytes are
/// a big-endian payload length. With a TTY there is no framing at all, and the bytes
/// are the output. Getting this wrong is how log viewers end up printing
/// `\u{01}\u{00}\u{00}\u{00}` in front of every line.
public enum DockerStreamDemux {

    public struct Output: Sendable {
        public var stdout: Data
        public var stderr: Data
        public init(stdout: Data = Data(), stderr: Data = Data()) {
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    /// `true` when `data` looks like it carries stdcopy framing.
    ///
    /// A heuristic, and it is used as one: the caller normally knows whether a TTY was
    /// allocated. It exists for `docker logs` on a container whose TTY setting we did
    /// not look up, where guessing wrong is cosmetic rather than corrupting.
    public static func looksFramed(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let bytes = [UInt8](data.prefix(8))
        guard bytes[0] <= 2, bytes[1] == 0, bytes[2] == 0, bytes[3] == 0 else { return false }
        let length = (Int(bytes[4]) << 24) | (Int(bytes[5]) << 16) | (Int(bytes[6]) << 8) | Int(bytes[7])
        // A frame that claims more than 16 MiB is far more likely to be raw output
        // that happens to start with a small byte than a real Docker frame.
        return length >= 0 && length <= 16 << 20
    }

    /// Demultiplexes a complete stream. Trailing partial frames are dropped.
    public static func split(_ data: Data) -> Output {
        var result = Output()
        let bytes = [UInt8](data)
        var cursor = 0
        while cursor + 8 <= bytes.count {
            let streamID = bytes[cursor]
            guard streamID <= 2, bytes[cursor + 1] == 0, bytes[cursor + 2] == 0, bytes[cursor + 3] == 0 else {
                // Not framing after all: hand back everything from here as stdout
                // rather than silently truncating the user's output.
                result.stdout.append(contentsOf: bytes[cursor...])
                return result
            }
            let length = (Int(bytes[cursor + 4]) << 24) | (Int(bytes[cursor + 5]) << 16)
                | (Int(bytes[cursor + 6]) << 8) | Int(bytes[cursor + 7])
            let start = cursor + 8
            let end = min(start + length, bytes.count)
            guard start <= end else { break }
            let slice = Data(bytes[start..<end])
            if streamID == 2 {
                result.stderr.append(slice)
            } else {
                result.stdout.append(slice)
            }
            cursor = start + length
        }
        return result
    }
}
