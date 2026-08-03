// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Foundation

/// Framed datagram transport spoken with the guest on vsock 2378.
///
/// Vsock on this VM is stream-only. Treating that stream as UDP would lose packet
/// boundaries, so each datagram is carried as an unsigned big-endian length followed
/// by exactly that many bytes. One host client gets one vsock connection and therefore
/// one guest UDP socket; this preserves replies and the source-flow semantics that UDP
/// services rely on.
public enum DatagramDial {
    public static let maximumDatagramBytes = UDPListener.maximumDatagramBytes
    private static let frameHeaderBytes = 4

    public static func preamble(guestPort: Int) -> Data {
        Data("UDP \(guestPort)\n".utf8)
    }

    public static func perform(
        fd: Int32,
        guestPort: Int,
        timeout: TimeInterval = StreamDial.replyTimeout
    ) throws {
        POSIXSocketSupport.suppressSIGPIPE(fd)
        guard POSIXSocketSupport.writeAll(fd, preamble(guestPort: guestPort)) else {
            throw MorbError.io(
                "could not send the datagram-dial preamble: \(String(cString: strerror(errno)))")
        }
        let line = try StreamDial.readReplyLine(fd: fd, deadline: Date().addingTimeInterval(timeout))
        try StreamDial.parseReply(line).get()
    }

    /// Writes one exactly-bounded datagram frame. The caller serializes writes for a
    /// flow, so frames from different host packets can never interleave.
    public static func writeFrame(fd: Int32, datagram: Data) -> Bool {
        guard datagram.count <= maximumDatagramBytes else { return false }
        var length = UInt32(datagram.count).bigEndian
        let header = withUnsafeBytes(of: &length) { Data($0) }
        return POSIXSocketSupport.writeAll(fd, header) && POSIXSocketSupport.writeAll(fd, datagram)
    }

    /// Reads one full frame without ever turning EOF into an empty UDP datagram.
    /// `nil` is clean peer EOF; an EOF in the four-byte header or payload is a protocol
    /// violation because it would otherwise silently truncate a packet.
    public static func readFrame(fd: Int32) throws -> Data? {
        guard let header = try readExact(fd: fd, count: frameHeaderBytes, allowInitialEOF: true) else {
            return nil
        }
        let bytes = [UInt8](header)
        let length = (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
        guard length <= UInt32(maximumDatagramBytes) else {
            throw MorbError.protocolViolation(
                "datagram-dial frame length \(length) exceeds \(maximumDatagramBytes) bytes")
        }
        return try readExact(fd: fd, count: Int(length), allowInitialEOF: false) ?? Data()
    }

    private static func readExact(fd: Int32, count: Int, allowInitialEOF: Bool) throws -> Data? {
        if count == 0 { return Data() }
        var result = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = result.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return POSIXSocketSupport.readSome(fd, into: base.advanced(by: offset), count: count - offset)
            }
            if received == 0 {
                if offset == 0 && allowInitialEOF { return nil }
                throw MorbError.protocolViolation("datagram-dial closed in the middle of a frame")
            }
            if received < 0 {
                throw MorbError.io("datagram-dial read failed: \(String(cString: strerror(errno)))")
            }
            offset += received
        }
        return Data(result)
    }
}
