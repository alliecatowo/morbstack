// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Host-side published-port availability snapshots.
//
// A successful probe means only that `127.0.0.1:<port>/<protocol>` bound during this
// check. It is intentionally *not* a reservation: the descriptor is closed before
// the result returns, so another process can claim the port before Docker starts a
// container. Calling a snapshot a reservation would make a race look like a guarantee.

import Darwin
import Foundation

/// Checks whether the Mac loopback endpoint Morbstack would use is currently free.
///
/// The current data plane forwards TCP on loopback only. UDP checks are still useful
/// before a Docker operation—the TCP and UDP port spaces conflict independently—but
/// return an explicit `notForwarded` publication state until Morbstack has a UDP relay.
public enum HostPortPreflight {

    public static let loopbackAddress = "127.0.0.1"

    public enum Transport: String, Codable, CaseIterable, Equatable, Sendable {
        case tcp
        case udp
    }

    public enum Availability: String, Codable, Equatable, Sendable {
        /// The exact loopback endpoint accepted a bind at the time of the probe.
        case available
        /// Another local process had the endpoint bound at the time of the probe.
        case inUse = "in_use"
        /// The input is not a real TCP/UDP port.
        case invalid
        /// A bind failed for a reason other than an ordinary conflict.
        case unavailable
    }

    public enum Publication: String, Codable, Equatable, Sendable {
        /// Morbstack's TCP forwarder binds `127.0.0.1`, never every network interface.
        case loopbackOnly = "loopback_only"
        /// UDP has no host relay yet. A free UDP port is not a promise that it will be
        /// reachable through Morbstack.
        case notForwarded = "not_forwarded"
    }

    public struct Result: Codable, Equatable, Sendable {
        public let port: Int
        public let transport: Transport
        public let bindAddress: String
        public let availability: Availability
        public let publication: Publication
        public let detail: String

        public var hasConflict: Bool { availability == .inUse }

        public var isSnapshotOnly: Bool { true }
    }

    /// Performs one conservative, non-reserving bind check.
    ///
    /// TCP deliberately uses `SO_REUSEADDR`, exactly like ``TCPListener``. Apple
    /// documents `SO_REUSEPORT` as the option that permits duplicate port bindings;
    /// this probe never sets it. UDP sets neither reuse option, which avoids turning a
    /// diagnostic check into a shared/hijackable UDP endpoint.
    public static func check(port: Int, transport: Transport) -> Result {
        let publication: Publication = transport == .tcp ? .loopbackOnly : .notForwarded
        guard (1...65535).contains(port) else {
            return Result(
                port: port,
                transport: transport,
                bindAddress: loopbackAddress,
                availability: .invalid,
                publication: publication,
                detail: "port must be between 1 and 65535")
        }

        let type: Int32 = transport == .tcp ? SOCK_STREAM : SOCK_DGRAM
        let protocolNumber: Int32 = transport == .tcp ? IPPROTO_TCP : IPPROTO_UDP
        let fd = socket(AF_INET, type, protocolNumber)
        guard fd >= 0 else {
            return Result(
                port: port,
                transport: transport,
                bindAddress: loopbackAddress,
                availability: .unavailable,
                publication: publication,
                detail: "could not create a \(transport.rawValue.uppercased()) socket")
        }
        defer { Darwin.close(fd) }

        if transport == .tcp {
            var on: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(truncatingIfNeeded: port).bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)

        let length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                POSIXSocketSupport.retryOnInterrupt { Darwin.bind(fd, generic, length) }
            }
        }
        guard bindResult == 0 else {
            let code = errno
            return Result(
                port: port,
                transport: transport,
                bindAddress: loopbackAddress,
                availability: code == EADDRINUSE ? .inUse : .unavailable,
                publication: publication,
                detail: code == EADDRINUSE
                    ? "another process currently owns \(loopbackAddress):\(port)/\(transport.rawValue)"
                    : "the loopback bind could not be checked (\(String(cString: strerror(code))))")
        }

        return Result(
            port: port,
            transport: transport,
            bindAddress: loopbackAddress,
            availability: .available,
            publication: publication,
            detail: transport == .tcp
                ? "available now on loopback; this check does not reserve the port"
                : "available now on loopback; UDP forwarding is not implemented and this check does not reserve the port")
    }

    /// Why this API does not reject `POST /containers/create` yet.
    ///
    /// The proxy currently relays arbitrary Docker HTTP byte streams and the host only
    /// learns published bindings after guest Docker has created and started a
    /// container. A race-free feature would need (1) HTTP framing for create/start and
    /// their responses, (2) a reservation ledger keyed to the returned container ID,
    /// (3) held TCP descriptors promoted into ``PortForwarder`` only after the guest
    /// reports the matching binding, plus expiry/rollback for failed or never-started
    /// containers, and (4) a guest-to-host allocation contract for `-P`, ranges, and
    /// omitted host ports that Docker chooses inside the guest. Until that protocol
    /// exists, a preflight result must remain advisory and must never be used to claim
    /// that a later container operation cannot race.
    public static let reservationDesign = "Host port probes are advisory snapshots; see source for the required reservation protocol."
}
