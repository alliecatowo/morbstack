// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Foundation

/// Connects to unix-domain sockets with a bounded deadline.
///
/// Used by the `morb` CLI to reach `morbstackd`, and by ``Doctor`` to probe liveness.
public enum UnixSocketClient {

    /// Connects to `path`, returning an owned blocking file descriptor.
    ///
    /// The connect itself is performed non-blocking so the caller cannot hang on a
    /// socket file whose owner has wedged; the descriptor is switched back to
    /// blocking mode before it is returned.
    ///
    /// - Parameters:
    ///   - path: Socket path.
    ///   - timeout: Maximum time to wait for the connection to complete.
    /// - Returns: A connected file descriptor the caller must `close`.
    public static func connect(path: String, timeout: TimeInterval = 2.0) throws -> Int32 {
        guard FileManager.default.fileExists(atPath: path) else {
            throw MorbError.notFound("socket not present at \(path)")
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw MorbError.io("socket(AF_UNIX) failed: \(String(cString: strerror(errno)))")
        }
        POSIXSocketSupport.setNonBlocking(fd, true)
        POSIXSocketSupport.suppressSIGPIPE(fd)

        var address = try POSIXSocketSupport.makeAddress(path: path)
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                POSIXSocketSupport.retryOnInterrupt { Darwin.connect(fd, generic, length) }
            }
        }

        if result != 0 {
            guard errno == EINPROGRESS else {
                let message = String(cString: strerror(errno))
                Darwin.close(fd)
                throw MorbError.io("connect(\(path)) failed: \(message)")
            }
            var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let milliseconds = Int32(max(1, (timeout * 1000).rounded()))
            let ready = POSIXSocketSupport.retryOnInterrupt { withUnsafeMutablePointer(to: &poller) { poll($0, 1, milliseconds) } }
            if ready <= 0 {
                Darwin.close(fd)
                throw MorbError.timeout("connect(\(path)) timed out after \(timeout)s")
            }
            var socketError: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            if getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &size) != 0 || socketError != 0 {
                let message = String(cString: strerror(socketError == 0 ? errno : socketError))
                Darwin.close(fd)
                throw MorbError.io("connect(\(path)) failed: \(message)")
            }
        }

        POSIXSocketSupport.setNonBlocking(fd, false)
        return fd
    }

    /// Returns `true` when something is listening on `path`.
    public static func isAlive(path: String, timeout: TimeInterval = 0.5) -> Bool {
        guard let fd = try? connect(path: path, timeout: timeout) else { return false }
        Darwin.close(fd)
        return true
    }

    /// Sends one request line and reads one response line. Used by the CLI.
    ///
    /// - Parameter timeout: Deadline for the reply, enforced with `SO_RCVTIMEO`.
    public static func roundTrip(path: String, request: DaemonRequest, timeout: TimeInterval = 30) throws -> DaemonResponse {
        let fd = try connect(path: path, timeout: min(timeout, 5))
        defer { Darwin.close(fd) }

        var tv = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let line = try IPCCodec.encodeLine(request)
        guard POSIXSocketSupport.writeAll(fd, line) else {
            throw MorbError.io("failed to write control request")
        }

        var accumulated = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !accumulated.contains(0x0A) {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return POSIXSocketSupport.readSome(fd, into: base, count: raw.count)
            }
            if n == 0 { break }
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw MorbError.timeout("daemon did not reply within \(Int(timeout))s")
                }
                throw MorbError.io("read failed: \(String(cString: strerror(errno)))")
            }
            accumulated.append(contentsOf: buffer[0..<n])
            if accumulated.count > 4 * 1024 * 1024 {
                throw MorbError.protocolViolation("control response too large")
            }
        }
        guard !accumulated.isEmpty else {
            throw MorbError.io("daemon closed the connection without replying")
        }
        return try IPCCodec.decodeLine(DaemonResponse.self, from: accumulated)
    }
}
