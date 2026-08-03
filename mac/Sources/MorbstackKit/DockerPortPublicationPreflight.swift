// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Read-only admission checks for explicit `HostConfig.PortBindings` in a Docker
// container-create request. This is deliberately not a lease protocol: every probe
// closes its descriptor before returning, and dynamic/range allocations remain for a
// future Engine/guest allocation contract.

import Foundation

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

    private static func networkProtocol(in containerPort: String) -> String {
        let pieces = containerPort.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2, !pieces[1].isEmpty else { return "tcp" }
        return String(pieces[1]).lowercased()
    }

    private static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
