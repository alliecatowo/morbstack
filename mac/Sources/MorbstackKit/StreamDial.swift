// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Foundation

/// The tiny handshake spoken on guest vsock port 2376.
///
/// vsock gives the host one connection to one guest port, which is not enough for
/// port publishing: the host needs to reach an *arbitrary* guest-local TCP port,
/// chosen per connection. Rather than one vsock port per published port — the guest
/// would have to be told about each one, and the mapping would have to survive
/// reconnects — 2376 takes the destination as the first line of the stream:
///
/// ```text
/// host -> guest   "TCP 8080\n"
/// guest -> host   "OK\n"                    (or "ERR connection refused\n")
/// both            raw bidirectional splice
/// ```
///
/// The port in the preamble is the guest-local bridge-publication port where
/// dockerd's proxy listens. Host-network containers do not create Mac forwards.
public enum StreamDial {

    /// How long the guest gets to answer the preamble.
    ///
    /// Short on purpose. The guest only has to `connect(2)` to a loopback port, so a
    /// slow answer means something is wrong rather than merely busy, and the Mac-side
    /// client is sitting there with an accepted-but-silent socket in the meantime.
    public static let replyTimeout: TimeInterval = 3

    /// Longest reply line accepted, so a confused guest cannot stream forever.
    public static let maxReplyBytes = 256

    /// Encodes the preamble that names `guestPort` as the guest-local destination.
    public static func preamble(guestPort: Int) -> Data {
        Data("TCP \(guestPort)\n".utf8)
    }

    /// Interprets the guest's reply line (terminator already stripped or not).
    public static func parseReply(_ line: String) -> Result<Void, MorbError> {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "OK" { return .success(()) }
        if trimmed.hasPrefix("ERR") {
            let reason = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            return .failure(.io(reason.isEmpty ? "the guest refused the dial" : reason))
        }
        if trimmed.isEmpty {
            return .failure(.protocolViolation("the guest closed the stream-dial without replying"))
        }
        return .failure(.protocolViolation("unexpected stream-dial reply `\(trimmed)`"))
    }

    /// Reads one `\n`-terminated line from `fd` without consuming a byte past it.
    ///
    /// Byte-at-a-time on purpose: everything after the newline is the peer's payload,
    /// and a buffered read would swallow the first bytes of the spliced stream. The
    /// line is a dozen characters, so the syscall count does not matter.
    ///
    /// - Throws: ``MorbError/timeout(_:)`` past `deadline`, ``MorbError/io(_:)`` on a
    ///   read failure or premature EOF.
    public static func readReplyLine(fd: Int32, deadline: Date) throws -> String {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0

        while bytes.count < maxReplyBytes {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw MorbError.timeout("the guest did not answer the stream-dial in time")
            }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = POSIXSocketSupport.retryOnInterrupt {
                withUnsafeMutablePointer(to: &poller) { poll($0, 1, Int32(remaining * 1000)) }
            }
            if ready == 0 {
                throw MorbError.timeout("the guest did not answer the stream-dial in time")
            }
            if ready < 0 {
                throw MorbError.io("poll on the stream-dial failed: \(String(cString: strerror(errno)))")
            }

            let n = withUnsafeMutablePointer(to: &byte) { pointer -> Int in
                POSIXSocketSupport.readSome(fd, into: UnsafeMutableRawPointer(pointer), count: 1)
            }
            if n == 0 {
                throw MorbError.io("the guest closed the stream-dial before replying")
            }
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw MorbError.io("stream-dial read failed: \(String(cString: strerror(errno)))")
            }
            if byte == 0x0A { break }
            if byte != 0x0D { bytes.append(byte) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Performs the whole handshake on an already-connected vsock descriptor.
    ///
    /// The descriptor is left open and usable for splicing on success, and is *not*
    /// closed on failure — ownership stays with the caller either way.
    public static func perform(fd: Int32, guestPort: Int, timeout: TimeInterval = replyTimeout) throws {
        POSIXSocketSupport.suppressSIGPIPE(fd)
        guard POSIXSocketSupport.writeAll(fd, preamble(guestPort: guestPort)) else {
            throw MorbError.io("could not send the stream-dial preamble: \(String(cString: strerror(errno)))")
        }
        let line = try readReplyLine(fd: fd, deadline: Date().addingTimeInterval(timeout))
        try parseReply(line).get()
    }
}
