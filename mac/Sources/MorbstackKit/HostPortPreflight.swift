// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Host-side published-port availability snapshots.
//
// A successful probe means only that the requested host endpoint bound
// during this check. It is intentionally *not* a reservation: the descriptor is
// closed before the result returns, so another process can claim the port before
// Docker starts a container. Calling a snapshot a reservation would make a race look
// like a guarantee.

import Darwin
import Foundation

/// Checks whether the Mac endpoint Morbstack would use is currently free.
///
/// A recognized fixed TCP/UDP
/// create takes the real held listener after this early check and retains it through
/// the acknowledged start response, so this API remains a deliberately non-reserving
/// availability snapshot for both transports.
public enum HostPortPreflight {

    public enum Transport: String, Codable, CaseIterable, Equatable, Sendable {
        case tcp
        case udp
    }

    public enum Availability: String, Codable, Equatable, Sendable {
        /// The exact host endpoint accepted a bind at the time of the probe.
        case available
        /// Another local process had the endpoint bound at the time of the probe.
        case inUse = "in_use"
        /// The input is not a real TCP/UDP port.
        case invalid
        /// A bind failed for a reason other than an ordinary conflict.
        case unavailable
    }

    public enum Publication: String, Codable, Equatable, Sendable {
        case loopback
        case localNetwork = "local_network"
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
    public static func check(
        port: Int,
        transport: Transport,
        hostAddress: DockerHostAddress
    ) -> Result {
        let publication: Publication = hostAddress.isLoopback ? .loopback : .localNetwork
        guard (1...65535).contains(port) else {
            return Result(
                port: port,
                transport: transport,
                bindAddress: hostAddress.stringValue,
                availability: .invalid,
                publication: publication,
                detail: "port must be between 1 and 65535")
        }

        let type: Int32 = transport == .tcp ? SOCK_STREAM : SOCK_DGRAM
        let protocolNumber: Int32 = transport == .tcp ? IPPROTO_TCP : IPPROTO_UDP
        let family = hostAddress.family
        let fd = socket(family, type, protocolNumber)
        guard fd >= 0 else {
            return Result(
                port: port,
                transport: transport,
                bindAddress: hostAddress.stringValue,
                availability: .unavailable,
                publication: publication,
                detail: "could not create a \(transport.rawValue.uppercased()) socket")
        }
        defer { Darwin.close(fd) }

        if transport == .tcp {
            var on: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        }

        let bindResult: Int32
        switch hostAddress {
        case .ipv4(let hostAddress):
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(truncatingIfNeeded: port).bigEndian
            guard inet_pton(AF_INET, hostAddress, &address.sin_addr) == 1 else {
                return Result(
                    port: port, transport: transport, bindAddress: hostAddress,
                    availability: .invalid, publication: publication, detail: "invalid IPv4 host address")
            }
            bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    POSIXSocketSupport.retryOnInterrupt {
                        Darwin.bind(fd, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        case .ipv6(let hostAddress):
            var v6Only: Int32 = 1
            _ = setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &v6Only, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = UInt16(truncatingIfNeeded: port).bigEndian
            guard inet_pton(AF_INET6, hostAddress, &address.sin6_addr) == 1 else {
                return Result(
                    port: port, transport: transport, bindAddress: hostAddress,
                    availability: .invalid, publication: publication, detail: "invalid IPv6 host address")
            }
            bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    POSIXSocketSupport.retryOnInterrupt {
                        Darwin.bind(fd, generic, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }
            }
        }
        guard bindResult == 0 else {
            let code = errno
            return Result(
                port: port,
                transport: transport,
                bindAddress: hostAddress.stringValue,
                availability: code == EADDRINUSE ? .inUse : .unavailable,
                publication: publication,
                detail: code == EADDRINUSE
                    ? "another process currently owns \(hostAddress.stringValue):\(port)/\(transport.rawValue)"
                    : "the host bind could not be checked (\(String(cString: strerror(code))))")
        }

        return Result(
            port: port,
            transport: transport,
            bindAddress: hostAddress.stringValue,
            availability: .available,
            publication: publication,
            detail: transport == .tcp
                ? "available now; this check does not reserve the port"
                : "available now; this check does not reserve the port")
    }

    /// The boundary of the Engine-facing create preflight.
    ///
    /// ``DockerProxy`` uses this snapshot as an early diagnostic for a recognizable,
    /// fixed-length `POST /containers/create`, then takes real ``TCPListener`` and
    /// ``UDPListener`` leases for its complete fixed supported publication set before
    /// forwarding the request.
    /// The lease is associated only with a bounded identity-bearing create response
    /// and is handed to ``PortForwarder`` without rebinding after a normal `204`
    /// start response. This API itself remains a snapshot: callers of `morb ports
    /// check`, dynamic (`-P`/omitted host port), range, malformed, chunked, and
    /// oversized shapes must not infer a reservation from its result.
    public static let reservationDesign = "HostPortPreflight is advisory; recognized fixed TCP/UDP Docker creates take one continuously held transport-indexed listener lease before reaching the Engine."
}
