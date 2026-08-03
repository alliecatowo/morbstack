// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Admission parsing for explicit `HostConfig.PortBindings` in a Docker
// container-create request. The parser admits only fixed loopback TCP/UDP bindings
// it can inspect without consuming bytes. `DockerProxy` turns concrete fixed TCP
// bindings into held listener leases. The Docker CLI expands a fixed equal-length
// `-p` range into just such bindings before it sends the Engine request. UDP is
// event-confirmed after Docker has assigned a concrete endpoint, so dynamic host-port
// ranges remain outside the synchronous contract.

import Foundation

/// One explicit TCP publication that is safe to reserve on the Mac's loopback.
///
/// This retains the original Docker host-address spelling for eventual forwarder
/// metadata. Morbstack always binds a local loopback endpoint: ordinary/default IPv4
/// spellings use `127.0.0.1`, while explicit IPv6 loopback spellings use `::1`.
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

/// A bounded dynamic-host-port TCP create document that can be transformed before it
/// reaches the guest Engine.
///
/// This is intentionally not a general Docker create model. It remembers only the
/// exact JSON entries the Phase 1 transaction is allowed to replace, and reparses the
/// original body before rewriting so a plan can never be applied to different bytes.
struct DockerDynamicTCPCreatePlan {

    /// The exact dynamic spelling admitted from the original JSON document.
    ///
    /// Docker accepts three distinct string-level forms for a dynamically allocated
    /// host port. Keep them distinct so a plan cannot rewrite a later fixed,
    /// whitespace-normalized, or otherwise different binding.
    fileprivate enum DynamicHostPortOrigin: Hashable {
        case omitted
        case empty
        case explicitZero
    }

    private struct Entry: Hashable {
        let containerPortKey: String
        let index: Int
        let hostIP: String
        let containerPort: Int
        /// Keep the request's exact dynamic spelling so a stale plan cannot
        /// overwrite a later fixed or malformed binding.
        let hostPortOrigin: DynamicHostPortOrigin
    }

    let requestedPublications: [DockerExplicitTCPPortBinding]
    private let body: Data
    private let entries: [Entry]

    fileprivate init(
        body: Data,
        entries: [(
            containerPortKey: String,
            index: Int,
            hostIP: String,
            containerPort: Int,
            hostPortOrigin: DynamicHostPortOrigin
        )]
    ) {
        self.body = body
        self.entries = entries.map {
            Entry(
                containerPortKey: $0.containerPortKey,
                index: $0.index,
                hostIP: $0.hostIP,
                containerPort: $0.containerPort,
                hostPortOrigin: $0.hostPortOrigin)
        }
        self.requestedPublications = entries.map {
            DockerExplicitTCPPortBinding(hostIP: $0.hostIP, hostPort: 0, containerPort: $0.containerPort)
        }
    }

    /// Replaces only planned empty, omitted, or literal `"0"` `HostPort` entries
    /// with kernel-reserved ports.
    ///
    /// Rechecking every entry is defensive but significant: JSON object graphs are
    /// mutable Foundation values, and a transaction must never turn a stale plan into
    /// a different container's port mapping.
    func rewrittenBody(with publications: [DockerExplicitTCPPortBinding]) throws -> Data {
        guard publications.count == entries.count else {
            throw MorbError.protocolViolation("dynamic TCP allocator returned the wrong number of ports")
        }
        guard
            var object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
            var hostConfig = object["HostConfig"] as? [String: Any],
            var portBindings = hostConfig["PortBindings"] as? [String: Any]
        else {
            throw MorbError.protocolViolation("dynamic TCP create body changed before it could be rewritten")
        }

        for (entry, publication) in zip(entries, publications) {
            guard publication.hostIP == entry.hostIP,
                  publication.containerPort == entry.containerPort,
                  (1...65535).contains(publication.hostPort),
                  var bindings = portBindings[entry.containerPortKey] as? [Any],
                  bindings.indices.contains(entry.index),
                  var binding = bindings[entry.index] as? [String: Any]
            else {
                throw MorbError.protocolViolation("dynamic TCP create plan no longer matches its request body")
            }
            let originalFormStillMatches: Bool
            switch entry.hostPortOrigin {
            case .omitted:
                originalFormStillMatches = binding["HostPort"] == nil
            case .empty:
                originalFormStillMatches = (binding["HostPort"] as? String) == ""
            case .explicitZero:
                originalFormStillMatches = (binding["HostPort"] as? String) == "0"
            }
            guard originalFormStillMatches else {
                throw MorbError.protocolViolation("dynamic TCP create plan no longer matches its request body")
            }
            binding["HostPort"] = String(publication.hostPort)
            bindings[entry.index] = binding
            portBindings[entry.containerPortKey] = bindings
        }

        hostConfig["PortBindings"] = portBindings
        object["HostConfig"] = hostConfig
        guard JSONSerialization.isValidJSONObject(object) else {
            throw MorbError.protocolViolation("rewritten dynamic TCP create is not valid JSON")
        }
        return try JSONSerialization.data(withJSONObject: object, options: [])
    }
}

/// Checks the portion of a normal Docker container-create document Morbstack can
/// verify before it relays the request to the guest Engine.
public enum DockerPortPublicationPreflight {

    /// Maximum number of distinct concrete TCP host endpoints one recognized create
    /// may reserve.
    ///
    /// Docker CLI normalizes a fixed equal-length range into a collection of ordinary
    /// bindings, so this is intentionally a lease-size limit rather than a second
    /// range parser. Holding listeners runs under the forwarder's ledger lock before
    /// a guest create; beyond this bounded amount, refusing the request is safer than
    /// creating a container while only some of its requested endpoints are held.
    public static let maximumSynchronousFixedTCPBindings = 128

    public enum Verdict: Equatable, Sendable {
        case allowed
        case rejected(message: String)
    }

    /// The Phase 1 dynamic allocator either receives a fully understood TCP-only
    /// request or does not run at all. `rejected` is deliberately precise: forwarding
    /// one of these shapes dynamically would let guest dockerd choose a port after
    /// the host had already committed to a different endpoint.
    enum DynamicTCPVerdict {
        case notDynamic
        case supported(DockerDynamicTCPCreatePlan)
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
        var fixedTCPHostPorts: Set<Int> = []
        // Morbstack has exactly one safe loopback listener per transport/host-port
        // pair. Docker can describe its dual-stack representation more than once,
        // but two different container targets cannot both be delivered through that
        // one listener. Detect the latter before a recognized create reaches the
        // Engine rather than allowing a successful create followed by a lossy event
        // reconciliation that picks an arbitrary target.
        var containerTargetByEndpoint: [String: Int] = [:]
        for containerPort in portBindings.keys.sorted() {
            let protocolName = networkProtocol(in: containerPort)
            guard let entries = portBindings[containerPort] as? [Any] else {
                // A null/unknown binding means there is no explicit host listener to
                // inspect. Let dockerd decide what it means.
                continue
            }

            for entry in entries {
                guard let entry = entry as? [String: Any] else { continue }
                // The dynamic transaction validates this exact string spelling
                // below. It has no fixed host endpoint to preflight here.
                if (entry["HostPort"] as? String) == "0" {
                    continue
                }
                let hostPort = string(entry["HostPort"])?.trimmingCharacters(in: .whitespaces) ?? ""
                guard !hostPort.isEmpty else {
                    // Docker will allocate this later. No host endpoint exists yet to
                    // check, and treating it as a fixed port would be a false claim.
                    continue
                }
                let hostIP = string(entry["HostIp"])?.trimmingCharacters(in: .whitespaces) ?? ""
                let key = "\(protocolName)|\(hostIP)|\(hostPort)"
                guard examined.insert(key).inserted else { continue }

                guard protocolName == "tcp" || protocolName == "udp" else {
                    return .rejected(
                        message: "published \(protocolName.uppercased()) port \(hostPort) is not supported by Morbstack's host forwarder")
                }

                let forwardableAddresses = protocolName == "udp"
                    ? PortForwardPlan.forwardableUDPHostAddresses
                    : PortForwardPlan.forwardableHostAddresses
                guard forwardableAddresses.contains(hostIP) else {
                    return .rejected(
                        message: "published host address \(hostIP) is not supported by Morbstack's \(protocolName.uppercased()) loopback forwarder")
                }
                guard let port = Int(hostPort) else {
                    return .rejected(
                        message: "published \(protocolName.uppercased()) host port \(hostPort) is not a concrete port; dynamic host-port ranges are not supported")
                }

                if protocolName == "tcp",
                   fixedTCPHostPorts.insert(port).inserted,
                   fixedTCPHostPorts.count > maximumSynchronousFixedTCPBindings {
                    return .rejected(
                        message: "published TCP mapping has more than \(maximumSynchronousFixedTCPBindings) concrete host ports; Morbstack refuses a partial port lease")
                }

                if let targetPort = Self.containerPort(in: containerPort) {
                    let endpoint = "\(protocolName)|\(port)"
                    if let existingTarget = containerTargetByEndpoint[endpoint], existingTarget != targetPort {
                        return .rejected(
                            message: "published \(protocolName.uppercased()) host port \(hostPort) maps to more than one container port; Morbstack cannot deliver one loopback listener to multiple targets")
                    }
                    containerTargetByEndpoint[endpoint] = targetPort
                }

                let transport: HostPortPreflight.Transport = protocolName == "tcp" ? .tcp : .udp
                let tcpLoopbackAddress = TCPListener.LoopbackAddress
                    .forDockerHostAddress(hostIP)
                let result = HostPortPreflight.check(
                    port: port,
                    transport: transport,
                    tcpLoopbackAddress: tcpLoopbackAddress)
                switch result.availability {
                case .available:
                    continue
                case .inUse:
                    return .rejected(
                        message: "driver failed programming external connectivity: Bind for \(result.bindAddress):\(port)/\(protocolName) failed: port is already allocated")
                case .invalid:
                    return .rejected(message: "published \(protocolName.uppercased()) host port \(hostPort) is invalid")
                case .unavailable:
                    return .rejected(
                        message: "could not verify published \(protocolName.uppercased()) port \(result.bindAddress):\(port): \(result.detail)")
                }
            }
        }
        return .allowed
    }

    /// Returns the fixed TCP publications that the host can actually reserve.
    ///
    /// Call this only after ``inspectContainerCreate(body:)`` returned `.allowed`.
    /// It intentionally returns no value for dynamic host ports (including a raw
    /// host-port range), malformed Engine-owned shapes, UDP, and a host address
    /// outside the loopback-only forwarder contract. A normal Docker CLI fixed
    /// equal-length range has already been expanded into individual concrete entries,
    /// so it deliberately follows this same fixed binding path. The proxy leaves all
    /// other forms byte-for-byte opaque rather than inventing a partial Docker
    /// allocator.
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

    /// Whether `identifier` is an immutable Docker container ID rather than a name
    /// or an accepted unique prefix.
    ///
    /// A start-time lease recovery has to inspect one container and then forward an
    /// unchanged start request. Names and prefixes can resolve to a different object
    /// between those operations, so that recovery deliberately accepts only this
    /// canonical, 64-character lowercase hexadecimal form Docker returns in its
    /// inspect response.
    static func isFullContainerID(_ identifier: String) -> Bool {
        let bytes = Array(identifier.utf8)
        guard bytes.count == 64 else { return false }
        return bytes.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    /// Returns the fully understood fixed TCP publications in a stopped-container
    /// inspect document, or `nil` when this document cannot safely support a
    /// synchronous start-time host lease.
    ///
    /// This is intentionally stricter than ``explicitTCPBindings(in:)``. The latter
    /// may ignore an Engine-owned or unsupported sibling in a create request; an
    /// inspect-derived recovery must instead understand *every* published entry
    /// before it reserves any port. Otherwise it could make a partial claim while
    /// forwarding a start for a container with a different publication shape.
    ///
    /// The caller supplies the full ID from the request path. Matching it to the
    /// inspect document is the identity proof that lets the proxy preserve the
    /// original start bytes without a name/prefix reuse race.
    static func stoppedContainerTCPBindings(
        in inspectBody: Data,
        expectedContainerID: String
    ) -> [DockerExplicitTCPPortBinding]? {
        guard isFullContainerID(expectedContainerID),
              let object = try? JSONSerialization.jsonObject(with: inspectBody) as? [String: Any],
              let containerID = object["Id"] as? String,
              containerID == expectedContainerID,
              let state = object["State"] as? [String: Any],
              let isRunning = state["Running"] as? Bool,
              !isRunning,
              let hostConfig = object["HostConfig"] as? [String: Any],
              let portBindings = hostConfig["PortBindings"] as? [String: Any],
              !portBindings.isEmpty
        else {
            return nil
        }

        // The host owns one loopback listener per port. Docker may describe the
        // same target through IPv4 and IPv6 wildcard entries; retain the IPv4
        // spelling for diagnostics, matching PortForwardPlan.desiredListeners(_:).
        var byHostPort: [Int: DockerExplicitTCPPortBinding] = [:]
        var ambiguousHostPorts: Set<Int> = []

        for containerPortKey in portBindings.keys.sorted() {
            guard networkProtocol(in: containerPortKey) == "tcp",
                  let containerPort = containerPort(in: containerPortKey),
                  (1...65535).contains(containerPort),
                  let entries = portBindings[containerPortKey] as? [Any],
                  !entries.isEmpty
            else {
                return nil
            }

            for rawEntry in entries {
                guard let entry = rawEntry as? [String: Any],
                      let rawHostPort = string(entry["HostPort"])?.trimmingCharacters(in: .whitespaces),
                      let hostPort = Int(rawHostPort),
                      (1...65535).contains(hostPort)
                else {
                    // Empty, zero, missing, and raw host-port range values are all
                    // Engine-owned allocation shapes. A normal CLI fixed range has
                    // already been persisted as individual concrete entries; a
                    // recovery must leave the remaining forms opaque.
                    return nil
                }
                let hostIP = string(entry["HostIp"])?.trimmingCharacters(in: .whitespaces) ?? ""
                guard PortForwardPlan.forwardableHostAddresses.contains(hostIP) else {
                    return nil
                }

                let candidate = DockerExplicitTCPPortBinding(
                    hostIP: hostIP,
                    hostPort: hostPort,
                    containerPort: containerPort)
                guard !ambiguousHostPorts.contains(hostPort) else { continue }
                if let existing = byHostPort[hostPort] {
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

        // An ambiguous Mac port must not be reserved for one of several guest
        // targets. Treat the whole recovery as unsupported rather than making a
        // partial promise; the ordinary event reconciler remains the fallback.
        guard ambiguousHostPorts.isEmpty, !byHostPort.isEmpty else { return nil }
        return byHostPort.values.sorted { $0.hostPort < $1.hostPort }
    }

    /// Recognizes Docker's empty, omitted, or literal `"0"` `HostPort` TCP bindings
    /// for the stateful Phase 1 allocator. `PublishAllPorts`, raw dynamic host-port
    /// ranges, UDP, invalid address/protocol values, and opaque sibling entries are
    /// rejected rather than silently falling back to an Engine-owned allocation.
    static func dynamicTCPCreatePlan(in body: Data) -> DynamicTCPVerdict {
        guard
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let hostConfig = object["HostConfig"] as? [String: Any]
        else {
            return .notDynamic
        }

        if let publishAllPorts = hostConfig["PublishAllPorts"] as? Bool, publishAllPorts {
            return .rejected(
                message: "dynamic published ports with PublishAllPorts (-P) are not supported yet")
        }

        guard let portBindings = hostConfig["PortBindings"] as? [String: Any] else {
            return .notDynamic
        }

        var dynamicEntries: [(
            containerPortKey: String,
            index: Int,
            hostIP: String,
            containerPort: Int,
            hostPortOrigin: DockerDynamicTCPCreatePlan.DynamicHostPortOrigin
        )] = []
        var sawOpaqueEntry = false
        var sawNonTCPPublication = false
        var unsupportedSiblingMessage: String?

        for containerPortKey in portBindings.keys.sorted() {
            let protocolName = networkProtocol(in: containerPortKey)
            let parsedContainerPort = containerPort(in: containerPortKey)
            guard let bindings = portBindings[containerPortKey] as? [Any] else {
                sawOpaqueEntry = true
                continue
            }

            for (index, rawBinding) in bindings.enumerated() {
                guard let binding = rawBinding as? [String: Any] else {
                    sawOpaqueEntry = true
                    continue
                }
                let rawHostPort = binding["HostPort"] as? String
                let hostPortWasOmitted = binding["HostPort"] == nil
                guard rawHostPort != nil || hostPortWasOmitted else {
                    // The Engine API declares HostPort as a string. A present value
                    // of another type is not equivalent to its zero value, so it
                    // stays opaque instead of being coerced into a publication.
                    unsupportedSiblingMessage = unsupportedSiblingMessage
                        ?? "dynamic published ports require a string or omitted HostPort"
                    continue
                }

                let dynamicHostPortOrigin: DockerDynamicTCPCreatePlan.DynamicHostPortOrigin?
                if hostPortWasOmitted {
                    dynamicHostPortOrigin = .omitted
                } else if rawHostPort == "" {
                    dynamicHostPortOrigin = .empty
                } else if rawHostPort == "0" {
                    dynamicHostPortOrigin = .explicitZero
                } else {
                    dynamicHostPortOrigin = nil
                }

                if let dynamicHostPortOrigin {
                    guard protocolName == "tcp" else {
                        return .rejected(
                            message: "dynamic published \(protocolName.uppercased()) ports are not supported yet")
                    }
                    guard let containerPort = parsedContainerPort,
                          (1...65535).contains(containerPort)
                    else {
                        return .rejected(
                            message: "dynamic published TCP port \(containerPortKey) is not a single valid container port")
                    }
                    let hostIP: String
                    if let value = binding["HostIp"] {
                        guard let string = value as? String else {
                            return .rejected(
                                message: "dynamic published TCP HostIp must be a string")
                        }
                        hostIP = string.trimmingCharacters(in: .whitespaces)
                    } else {
                        hostIP = ""
                    }
                    guard PortForwardPlan.forwardableHostAddresses.contains(hostIP) else {
                        return .rejected(
                            message: "published host address \(hostIP) is not supported; Morbstack forwards TCP only on loopback")
                    }
                    dynamicEntries.append((
                        containerPortKey,
                        index,
                        hostIP,
                        containerPort,
                        dynamicHostPortOrigin))
                } else {
                    // A transaction that rewrites one entry must understand every
                    // sibling. Fixed TCP bindings remain supported, but fixed UDP or
                    // an opaque/invalid sibling would need a second lease contract.
                    guard let rawHostPort,
                          let hostPort = Int(rawHostPort),
                          (1...65535).contains(hostPort)
                    else {
                        unsupportedSiblingMessage = unsupportedSiblingMessage
                            ?? "published \(protocolName.uppercased()) host port \(rawHostPort ?? "missing") is not a concrete port; dynamic host-port ranges are not supported yet"
                        continue
                    }
                    if protocolName != "tcp" { sawNonTCPPublication = true }
                }
            }
        }

        guard !dynamicEntries.isEmpty else { return .notDynamic }
        if let unsupportedSiblingMessage {
            return .rejected(message: unsupportedSiblingMessage)
        }
        guard !sawOpaqueEntry else {
            return .rejected(
                message: "dynamic published TCP ports require a fully understood PortBindings document")
        }
        guard !sawNonTCPPublication else {
            return .rejected(
                message: "dynamic published TCP ports cannot be combined with UDP or another non-TCP publication yet")
        }
        return .supported(DockerDynamicTCPCreatePlan(body: body, entries: dynamicEntries))
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
