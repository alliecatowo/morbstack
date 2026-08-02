// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// A second, deliberately dumb Engine API client.
//
// The whole point of this harness is to check `DockerClient` against reality, so the
// numbers it produces have to be compared with something that is *not* `DockerClient`.
// This is that something: forty lines of connect/write/read-to-EOF with no shared code
// beyond `MinimalHTTP`'s parser, used to fetch the ground truth (`/info`'s CPU count,
// `/containers/json` straight off the wire) that the assertions are made against.

import Darwin
import Foundation
import MorbstackKit

enum RawEngine {

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    /// One `GET`, read to EOF, body returned. Handles both framings the engine uses.
    static func get(_ path: String, socketPath: String, timeout: TimeInterval = 20) throws -> Data {
        let fd = try UnixSocketClient.connect(path: socketPath, timeout: 5)
        defer { Darwin.close(fd) }
        POSIXSocketSupport.suppressSIGPIPE(fd)

        let request = MinimalHTTP.request(method: "GET", path: path, closeWhenDone: true)
        guard POSIXSocketSupport.writeAll(fd, request) else {
            throw Failure(description: "write to \(socketPath) failed")
        }

        var raw = Data()
        var head: HTTPResponseHead?
        var chunked: ChunkedBodyDecoder?
        var body = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        while Date() < deadline {
            let n = buffer.withUnsafeMutableBytes { region -> Int in
                guard let base = region.baseAddress else { return -1 }
                return POSIXSocketSupport.readSome(fd, into: base, count: region.count)
            }
            if n <= 0 { break }
            var slice = Data(buffer[0..<n])

            if head == nil {
                raw.append(slice)
                guard let parsed = try MinimalHTTP.parseHead(raw) else { continue }
                head = parsed.head
                if parsed.head.isChunked { chunked = ChunkedBodyDecoder() }
                slice = Data(raw.suffix(from: raw.startIndex + parsed.consumed))
                raw = Data()
                if slice.isEmpty { continue }
            }

            if chunked != nil {
                body.append(try chunked!.feed(slice))
                if chunked!.isComplete { break }
            } else {
                body.append(slice)
                if let length = head?.contentLength, body.count >= length { break }
            }
        }

        guard let head else { throw Failure(description: "no reply from \(path)") }
        guard (200..<300).contains(head.statusCode) else {
            throw Failure(description: "\(path) returned HTTP \(head.statusCode): \(String(decoding: body, as: UTF8.self))")
        }
        return body
    }

    /// The first newline-delimited JSON document of a *streaming* response, then hang up.
    ///
    /// `get` reads to EOF, which a `stream=1` endpoint never reaches — it would sit there
    /// until the deadline and hand back an arbitrary number of documents. This stops at
    /// the first complete line and closes the socket, which is the only way to see what a
    /// stream *opens* with.
    ///
    /// That distinction matters more than it looks: `stats?stream=0` is not the same
    /// document. dockerd services the one-shot form by collecting twice internally and
    /// answering with the second reading, precpu already filled — which is exactly why
    /// `docker stats --no-stream` prints a usable number. Only `stream=1` shows the
    /// zero-filled baseline the client has to throw away.
    static func firstStreamedObject(
        _ path: String, socketPath: String, timeout: TimeInterval = 20
    ) throws -> [String: Any] {
        let fd = try UnixSocketClient.connect(path: socketPath, timeout: 5)
        defer { Darwin.close(fd) }
        POSIXSocketSupport.suppressSIGPIPE(fd)

        let request = MinimalHTTP.request(method: "GET", path: path, closeWhenDone: true)
        guard POSIXSocketSupport.writeAll(fd, request) else {
            throw Failure(description: "write to \(socketPath) failed")
        }

        var raw = Data()
        var head: HTTPResponseHead?
        var chunked: ChunkedBodyDecoder?
        var body = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        while Date() < deadline {
            let n = buffer.withUnsafeMutableBytes { region -> Int in
                guard let base = region.baseAddress else { return -1 }
                return POSIXSocketSupport.readSome(fd, into: base, count: region.count)
            }
            if n <= 0 { break }
            var slice = Data(buffer[0..<n])

            if head == nil {
                raw.append(slice)
                guard let parsed = try MinimalHTTP.parseHead(raw) else { continue }
                head = parsed.head
                guard (200..<300).contains(parsed.head.statusCode) else {
                    throw Failure(description: "\(path) returned HTTP \(parsed.head.statusCode)")
                }
                if parsed.head.isChunked { chunked = ChunkedBodyDecoder() }
                slice = Data(raw.suffix(from: raw.startIndex + parsed.consumed))
                raw = Data()
                if slice.isEmpty { continue }
            }

            body.append(chunked != nil ? try chunked!.feed(slice) : slice)

            // Documents are newline-delimited; the first newline ends the first one.
            if let newline = body.firstIndex(of: 0x0A) {
                let line = body[body.startIndex..<newline]
                guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                else { throw Failure(description: "\(path) first line is not a JSON object") }
                return object
            }
        }
        throw Failure(description: "no complete document from \(path) within \(Int(timeout))s")
    }

    /// A top-level JSON object from the engine.
    static func object(_ path: String, socketPath: String) throws -> [String: Any] {
        let data = try get(path, socketPath: socketPath)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(description: "\(path) did not return a JSON object")
        }
        return object
    }

    /// A top-level JSON array from the engine.
    static func array(_ path: String, socketPath: String) throws -> [[String: Any]] {
        let data = try get(path, socketPath: socketPath)
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw Failure(description: "\(path) did not return a JSON array")
        }
        return array
    }
}
