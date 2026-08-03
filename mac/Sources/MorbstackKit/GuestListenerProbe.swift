// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Foundation

/// Read-only request/reply protocol on guest vsock port 2380.
///
/// The host asks only about a Docker `Config.ExposedPorts` candidate. The guest
/// answers whether a socket of that transport is bound on loopback or every guest
/// interface, which is the reachability contract the existing dialers can honor.
public enum GuestListenerProbe {
    public enum Transport: String, Sendable {
        case tcp
        case udp
    }

    public static func preamble(transport: Transport, guestPort: Int) -> Data {
        Data("LISTEN \(transport.rawValue) \(guestPort)\n".utf8)
    }

    public static func perform(
        fd: Int32,
        transport: Transport,
        guestPort: Int,
        timeout: TimeInterval = StreamDial.replyTimeout
    ) throws -> Bool {
        guard (1...65_535).contains(guestPort) else {
            throw MorbError.protocolViolation("guest listener probe received an invalid port")
        }
        POSIXSocketSupport.suppressSIGPIPE(fd)
        guard POSIXSocketSupport.writeAll(fd, preamble(transport: transport, guestPort: guestPort)) else {
            throw MorbError.io(
                "could not send the guest listener probe: \(String(cString: strerror(errno)))")
        }
        let reply = try StreamDial.readReplyLine(
            fd: fd,
            deadline: Date().addingTimeInterval(timeout))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch reply {
        case "YES": return true
        case "NO": return false
        default:
            if reply.hasPrefix("ERR") {
                throw MorbError.io(String(reply.dropFirst(3)).trimmingCharacters(in: .whitespaces))
            }
            throw MorbError.protocolViolation("unexpected guest listener probe reply `\(reply)`")
        }
    }
}
