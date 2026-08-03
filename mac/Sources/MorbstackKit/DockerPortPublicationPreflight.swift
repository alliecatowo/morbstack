// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Admission parsing for explicit `HostConfig.PortBindings` in a Docker
// container-create request. The parser intentionally recognizes only fixed TCP
// bindings. `DockerProxy` may turn those into held listener leases; dynamic/range
// allocations remain for a future Engine/guest allocation contract.

import Foundation

/// One explicit TCP publication that is safe to reserve on the Mac's loopback.
///
/// This retains the original Docker host-address spelling for eventual forwarder
/// metadata, but the actual listener is always on `127.0.0.1`; that is the existing
/// PortForwarder safety boundary.
public struct DockerExplicitTCPPortBinding: Hashable, Sendable {
    public let hostIP: String
    public let hostPort: Int
    public let containerPort: Int

    public init(hostIP: String, hostPort: Int, containerPort: Int) {
        self.hostIP = hostIP
        self.hostPort = hostPort
        self.containerPort = containerPort
    }
}

/// Checks the portion of a normal Docker container-create document Morbstack can
/// verify before it relays the request to the guest Engine.
public enum DockerPortPublicationPreflight {

    public enum Verdict: Equatable, Sendable {
        case allowed
        case rejected(message: String)
    }

    /// Inspects only explicit published ports in `HostConfig.PortBindings`.
    ///
    /// Invalid JSON and shapes the Engine owns are allowed through for dockerd to
    /// diagnose. This avoids turning a host-side advisory into a second, incompatible
    /// implementation of Docker's create validator.
    public static func inspectContainerCreate(body: Data) -> Verdict {
        guard
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let hostConfig = object["HostConfig"] as? [String: Any],
            let portBindings = hostConfig["PortBindings"] as? [String: Any]
        else {
            return .allowed
        }

        var examined: Set<String> = []
        for containerPort in portBindings.keys.sorted() {
            let protocolName = networkProtocol(in: containerPort)
            guard let entries = portBindings[containerPort] as? [Any] else {
                // A null/unknown binding means there is no explicit host listener to
                // inspect. Let dockerd decide what it means.
                continue
            }

            for entry in entries {
                guard let entry = entry as? [String: Any] else { continue }
                let hostPort = string(entry["HostPort"])?.trimmingCharacters(in: .whitespaces) ?? ""
                guard !hostPort.isEmpty else {
                    // Docker will allocate this later. No host endpoint exists yet to
                    // check, and treating it as a fixed port would be a false claim.
                    continue
                }
                let hostIP = string(entry["HostIp"])?.trimmingCharacters(in: .whitespaces) ?? ""
                let key = "\(protocolName)|\(hostIP)|\(hostPort)"
                guard examined.insert(key).inserted else { continue }

                guard protocolName == "tcp" else {
                    if protocolName == "udp" {
                        return .rejected(
                            message: "published UDP port \(hostPort) cannot be used: Morbstack does not forward UDP ports")
                    }
                    return .rejected(
                        message: "published \(protocolName.uppercased()) port \(hostPort) is not supported by Morbstack's TCP-only host forwarder")
                }

                guard PortForwardPlan.forwardableHostAddresses.contains(hostIP) else {
                    return .rejected(
                        message: "published host address \(hostIP) is not supported; Morbstack forwards TCP only on loopback")
                }
                guard let port = Int(hostPort) else {
                    return .rejected(
                        message: "published TCP host port \(hostPort) is not a single port; dynamic and range allocations are not preflighted")
                }

                let result = HostPortPreflight.check(port: port, transport: .tcp)
                switch result.availability {
                case .available:
                    continue
                case .inUse:
                    return .rejected(
                        message: "driver failed programming external connectivity: Bind for 127.0.0.1:\(port) failed: port is already allocated")
                case .invalid:
                    return .rejected(message: "published TCP host port \(hostPort) is invalid")
                case .unavailable:
                    return .rejected(
                        message: "could not verify published TCP port 127.0.0.1:\(port): \(result.detail)")
                }
            }
        }
        return .allowed
    }

    /// Returns the fixed TCP publications that the host can actually reserve.
    ///
    /// Call this only after ``inspectContainerCreate(body:)`` returned `.allowed`.
    /// It intentionally returns no value for dynamic host ports, ranges, malformed
    /// Engine-owned shapes, UDP, and a host address outside the loopback-only
    /// forwarder contract. The proxy leaves all of those byte-for-byte opaque rather
    /// than inventing a partial Docker allocator.
    public static func explicitTCPBindings(in body: Data) -> [DockerExplicitTCPPortBinding] {
        guard
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let hostConfig = object["HostConfig"] as? [String: Any],
            let portBindings = hostConfig["PortBindings"] as? [String: Any]
        else {
            return []
        }

        // The host owns one loopback listener per port, even when Docker reports
        // matching IPv4 and IPv6 publication entries. Prefer an IPv4 spelling for
        // diagnostics, matching PortForwardPlan.desiredListeners(_:).
        var byHostPort: [Int: DockerExplicitTCPPortBinding] = [:]
        var ambiguousHostPorts: Set<Int> = []
        for containerPortKey in portBindings.keys.sorted() {
            guard networkProtocol(in: containerPortKey) == "tcp",
                  let containerPort = containerPort(in: containerPortKey),
                  (1...65535).contains(containerPort),
                  let entries = portBindings[containerPortKey] as? [Any]
            else {
                continue
            }

            for entry in entries {
                guard let entry = entry as? [String: Any] else { continue }
                let rawHostPort = string(entry["HostPort"])?.trimmingCharacters(in: .whitespaces) ?? ""
                guard let hostPort = Int(rawHostPort), (1...65535).contains(hostPort) else {
                    continue
                }
                let hostIP = string(entry["HostIp"])?.trimmingCharacters(in: .whitespaces) ?? ""
                guard PortForwardPlan.forwardableHostAddresses.contains(hostIP) else { continue }

                let candidate = DockerExplicitTCPPortBinding(
                    hostIP: hostIP, hostPort: hostPort, containerPort: containerPort)
                guard !ambiguousHostPorts.contains(hostPort) else { continue }
                if let existing = byHostPort[hostPort] {
                    // One Mac listener cannot safely represent two distinct guest
                    // targets on the same host port. Dockerd owns diagnosis of that
                    // invalid shape, so leave it unleased instead of guessing.
                    guard existing.containerPort == candidate.containerPort else {
                        byHostPort.removeValue(forKey: hostPort)
                        ambiguousHostPorts.insert(hostPort)
                        continue
                    }
                    if existing.hostIP.contains(":"), !candidate.hostIP.contains(":") {
                        byHostPort[hostPort] = candidate
                    }
                } else {
                    byHostPort[hostPort] = candidate
                }
            }
        }
        return byHostPort.values.sorted { $0.hostPort < $1.hostPort }
    }

    private static func networkProtocol(in containerPort: String) -> String {
        let pieces = containerPort.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2, !pieces[1].isEmpty else { return "tcp" }
        return String(pieces[1]).lowercased()
    }

    private static func containerPort(in key: String) -> Int? {
        let raw = key.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return Int(raw)
    }

    private static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
