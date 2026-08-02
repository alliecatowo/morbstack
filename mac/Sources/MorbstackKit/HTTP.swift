// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Foundation

/// A parsed HTTP response status line plus headers.
public struct HTTPResponseHead: Equatable, Sendable {

    /// The numeric status, e.g. `200`.
    public var statusCode: Int
    /// The reason phrase, which servers are allowed to leave empty.
    public var reason: String
    /// Header fields with **lowercased** names; repeats are joined with `", "`.
    public var headers: [String: String]

    public init(statusCode: Int, reason: String, headers: [String: String]) {
        self.statusCode = statusCode
        self.reason = reason
        self.headers = headers
    }

    /// `true` when the body arrives as `Transfer-Encoding: chunked`.
    public var isChunked: Bool {
        (headers["transfer-encoding"] ?? "").lowercased().contains("chunked")
    }

    /// The declared body length, when the server sent one.
    public var contentLength: Int? {
        guard let raw = headers["content-length"] else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespaces))
    }
}

/// The smallest HTTP/1.1 client Morbstack can get away with.
///
/// The Docker Engine API is reached over a vsock stream rather than a socket
/// `URLSession` will talk to, and pulling in a real HTTP library would break the
/// zero-dependency rule for the sake of three request shapes: a `GET` that returns a
/// JSON document, a `GET` that streams newline-delimited events forever, and the
/// framing that carries them. What follows is deliberately partial — no redirects, no
/// compression, no keep-alive accounting — but it is tolerant about the things real
/// servers vary on: bare `LF` line endings, chunk extensions, and absent trailers.
public enum MinimalHTTP {

    /// Builds a request. `Host` is required by HTTP/1.1 even though the guest ignores it.
    ///
    /// - Parameter closeWhenDone: sends `Connection: close`, which turns "read the
    ///   body" into "read until EOF" and is what the one-shot requests rely on.
    public static func request(
        method: String,
        path: String,
        closeWhenDone: Bool
    ) -> Data {
        var text = "\(method) \(path) HTTP/1.1\r\n"
        text += "Host: morbstack\r\n"
        text += "Accept: application/json\r\n"
        text += "User-Agent: morbstack/\(MorbVersion.string)\r\n"
        if closeWhenDone { text += "Connection: close\r\n" }
        text += "\r\n"
        return Data(text.utf8)
    }

    /// Percent-encodes `value` for use in a query string.
    ///
    /// Hand-rolled against an explicit allow-list rather than
    /// `addingPercentEncoding(withAllowedCharacters:)`, because the standard
    /// `urlQueryAllowed` set leaves `&`, `=`, `+` and `?` untouched — all of which
    /// appear in the JSON filter documents this exists to encode.
    public static func percentEncodeQueryValue(_ value: String) -> String {
        var out = ""
        for byte in Array(value.utf8) {
            let isUnreserved =
                (byte >= 0x41 && byte <= 0x5A)  // A-Z
                || (byte >= 0x61 && byte <= 0x7A)  // a-z
                || (byte >= 0x30 && byte <= 0x39)  // 0-9
                || byte == 0x2D || byte == 0x2E || byte == 0x5F || byte == 0x7E  // - . _ ~
            if isUnreserved {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// Finds the end of one line, accepting `CRLF` and bare `LF`.
    ///
    /// - Returns: the index one past the last content byte, and the index the next
    ///   line starts at; `nil` when no terminator is in the buffer yet.
    static func lineBounds(_ bytes: [UInt8], from start: Int) -> (contentEnd: Int, next: Int)? {
        var index = start
        while index < bytes.count {
            if bytes[index] == 0x0A {
                let contentEnd = (index > start && bytes[index - 1] == 0x0D) ? index - 1 : index
                return (contentEnd, index + 1)
            }
            index += 1
        }
        return nil
    }

    /// Parses a response head.
    ///
    /// - Returns: the head and the number of bytes it occupied, or `nil` when the
    ///   blank line that ends the head has not arrived yet.
    /// - Throws: ``MorbError/protocolViolation(_:)`` on an unparseable status line.
    public static func parseHead(_ buffer: Data) throws -> (head: HTTPResponseHead, consumed: Int)? {
        let bytes = [UInt8](buffer)
        var lines: [String] = []
        var cursor = 0
        var consumed: Int?

        while let (contentEnd, next) = lineBounds(bytes, from: cursor) {
            if contentEnd == cursor {  // the blank line that terminates the head
                consumed = next
                break
            }
            lines.append(String(decoding: bytes[cursor..<contentEnd], as: UTF8.self))
            cursor = next
        }
        guard let consumed, let statusLine = lines.first else { return nil }

        // "HTTP/1.1 200 OK" — the reason phrase is optional and may contain spaces.
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/"),
              let statusCode = Int(statusParts[1])
        else {
            throw MorbError.protocolViolation("unparseable HTTP status line `\(statusLine)`")
        }
        let reason = statusParts.count > 2 ? String(statusParts[2]) : ""

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }
        return (HTTPResponseHead(statusCode: statusCode, reason: reason, headers: headers), consumed)
    }
}

/// An incremental decoder for `Transfer-Encoding: chunked` bodies.
///
/// Fed arbitrary slices of the wire stream, it returns whatever complete chunk data
/// it can and keeps the remainder. Docker's `/events` endpoint is an infinite chunked
/// stream where each chunk happens to be one JSON object, but nothing guarantees that
/// alignment — a chunk can split a JSON document, and one read can deliver several
/// chunks — so the decoding and the record framing are kept strictly separate.
public struct ChunkedBodyDecoder {

    private var buffer: [UInt8] = []
    private var complete = false

    public init() {}

    /// `true` once the terminating zero-length chunk has been seen.
    public var isComplete: Bool { complete }

    /// Bytes received that could not be decoded yet.
    public var pendingByteCount: Int { buffer.count }

    /// Appends `data` to the stream and returns every newly decoded body byte.
    ///
    /// - Throws: ``MorbError/protocolViolation(_:)`` on a malformed chunk size line.
    @discardableResult
    public mutating func feed(_ data: Data) throws -> Data {
        guard !complete else { return Data() }
        buffer.append(contentsOf: data)

        var out = Data()
        var cursor = 0

        loop: while true {
            guard let (sizeLineEnd, afterSizeLine) = MinimalHTTP.lineBounds(buffer, from: cursor) else {
                break loop  // the size line has not fully arrived
            }
            // A leading empty line is the previous chunk's terminator arriving late
            // in a stream we resynchronised on; skip it rather than fail.
            if sizeLineEnd == cursor {
                cursor = afterSizeLine
                continue loop
            }
            let sizeLine = String(decoding: buffer[cursor..<sizeLineEnd], as: UTF8.self)
            guard let size = Self.parseChunkSize(sizeLine) else {
                throw MorbError.protocolViolation("malformed chunk size line `\(sizeLine)`")
            }

            if size == 0 {
                // Optional trailer fields, then a blank line. Waiting for that blank
                // line means a trailer split across two reads is not mistaken for the
                // end of the body.
                var trailerCursor = afterSizeLine
                var sawTerminator = false
                while let (contentEnd, next) = MinimalHTTP.lineBounds(buffer, from: trailerCursor) {
                    let isEmptyLine = contentEnd == trailerCursor
                    trailerCursor = next
                    if isEmptyLine {
                        sawTerminator = true
                        break
                    }
                }
                guard sawTerminator else { break loop }
                complete = true
                cursor = trailerCursor
                break loop
            }

            let dataStart = afterSizeLine
            let dataEnd = dataStart + size
            guard buffer.count > dataEnd else { break loop }  // need the data + terminator

            // Consume the chunk's trailing CRLF (or bare LF). Nothing is emitted until
            // the whole chunk *including* its terminator is present, so a partial
            // delivery is never handed out twice.
            var next = dataEnd
            if buffer[next] == 0x0D {
                next += 1
                if next >= buffer.count { break loop }
            }
            if buffer[next] == 0x0A {
                next += 1
            }
            out.append(contentsOf: buffer[dataStart..<dataEnd])
            cursor = next
        }

        if cursor > 0 { buffer.removeFirst(cursor) }
        return out
    }

    /// Parses a chunk size line, ignoring any `;ext=value` suffix.
    ///
    /// The grammar accepted is exactly `[0-9a-fA-F]{1,8}` before the optional `;`,
    /// which RFC 9112 §7.1 gives as `1*HEXDIG`. The explicit character check is not
    /// pedantry: `Int(_:radix:)` also accepts a leading sign, so a peer that sent
    /// `-1\r\n` used to produce a *negative* chunk length, and `dataStart + size` then
    /// went backwards past the start of the buffer. The subsequent slice traps and
    /// takes the daemon with it — a one-line remote kill from anything that can speak
    /// to the Docker API socket.
    ///
    /// `isHexDigit` alone is not enough either: it is true for the fullwidth and
    /// Arabic-Indic digit forms, none of which `Int(radix:)` then accepts, so the pair
    /// of checks has to agree on ASCII.
    static func parseChunkSize(_ line: String) -> Int? {
        let head = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty, head.count <= 8 else { return nil }
        guard head.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return Int(head, radix: 16)
    }
}

/// Splits a byte stream into newline-delimited records.
///
/// Docker's event stream is one JSON object per line; this keeps the partial trailing
/// line between deliveries so a document split across two chunks is not lost.
public struct LineAccumulator {

    private var buffer: [UInt8] = []

    /// Largest line tolerated before the accumulator gives up, to keep a wedged or
    /// hostile peer from making the daemon allocate without bound.
    public static let maxLineBytes = 4 << 20

    public init() {}

    /// Appends `data` and returns every complete line, with terminators stripped.
    public mutating func feed(_ data: Data) -> [Data] {
        buffer.append(contentsOf: data)
        var lines: [Data] = []
        var cursor = 0
        while let (contentEnd, next) = MinimalHTTP.lineBounds(buffer, from: cursor) {
            if contentEnd > cursor {
                lines.append(Data(buffer[cursor..<contentEnd]))
            }
            cursor = next
        }
        if cursor > 0 { buffer.removeFirst(cursor) }
        if buffer.count > Self.maxLineBytes { buffer.removeAll() }
        return lines
    }
}
