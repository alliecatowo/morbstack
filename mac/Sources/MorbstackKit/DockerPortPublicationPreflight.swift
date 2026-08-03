// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Admission parsing for explicit `HostConfig.PortBindings` in a Docker
// container-create request. The parser recognizes fixed bindings and Docker's
// host-port range allocation grammar without consuming bytes. `DockerProxy` turns
// the complete set into one held listener lease before dockerd sees the create.

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

    var endpoint: DockerHostEndpoint? { DockerHostEndpoint(hostIP: hostIP, port: hostPort) }
}

/// One fixed UDP publication the Mac can retain. UDP has its own socket namespace,
/// so it deliberately remains a distinct value from ``DockerExplicitTCPPortBinding``
/// even when the numeric host port is the same.
public struct DockerExplicitUDPPortBinding: Hashable, Sendable {
    public let hostIP: String
    public let hostPort: Int
    public let containerPort: Int

    public init(hostIP: String, hostPort: Int, containerPort: Int) {
        self.hostIP = hostIP
        self.hostPort = hostPort
        self.containerPort = containerPort
    }

    var endpoint: DockerHostEndpoint? { DockerHostEndpoint(hostIP: hostIP, port: hostPort) }
}

/// The complete fixed publication set that one Docker create/start lifecycle owns.
///
/// The plan deliberately has separate transport collections. Docker may publish TCP
/// and UDP through the same numerical host port, but the host must bind, activate,
/// pause, recover, and retire those two sockets as one container lifecycle unit.
public enum DockerGuestDialPort: Hashable, Sendable {
    /// Normal bridge networking: dockerd's userland proxy listens on the guest's
    /// published host port, so the existing vsock dialer targets that port.
    case publishedHostPort
    /// Guest host networking: no guest userland proxy exists, so Morbstack must dial
    /// the requested container port directly in the guest network namespace.
    case containerPort

    func resolve(hostPort: Int, containerPort: Int) -> Int {
        switch self {
        case .publishedHostPort: hostPort
        case .containerPort: containerPort
        }
    }
}

public struct DockerFixedPortLeasePlan: Hashable, Sendable {
    public let tcp: [DockerExplicitTCPPortBinding]
    public let udp: [DockerExplicitUDPPortBinding]
    public let guestDialPort: DockerGuestDialPort

    public init(
        tcp: [DockerExplicitTCPPortBinding],
        udp: [DockerExplicitUDPPortBinding],
        guestDialPort: DockerGuestDialPort = .publishedHostPort
    ) {
        self.tcp = tcp
        self.udp = udp
        self.guestDialPort = guestDialPort
    }

    public var isEmpty: Bool { tcp.isEmpty && udp.isEmpty }
}

/// One inclusive Docker host-port allocation range.
///
/// Docker treats `8080-8082:80` as a request to allocate one port from that range
/// for container port 80. It is materially different from an equal-length
/// host/container range, which the CLI expands into one concrete PortBinding per
/// container port before it reaches the Engine API.
struct DockerHostPortRange: Hashable, Sendable {
    let lowerBound: Int
    let upperBound: Int

    init?(string: String) {
        let pieces = string.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              let lower = Int(pieces[0]),
              let upper = Int(pieces[1]),
              (1...65_535).contains(lower),
              (1...65_535).contains(upper),
              lower <= upper
        else { return nil }
        lowerBound = lower
        upperBound = upper
    }

    var stringValue: String { "\(lowerBound)-\(upperBound)" }
    var ports: ClosedRange<Int> { lowerBound...upperBound }
}

/// The transport of one bounded dynamic host-port publication.
///
/// This remains intentionally narrower than Docker's complete port grammar. The
/// held host forwarder supports TCP and UDP on numeric IPv4 and IPv6 host
/// addresses that the Mac can bind under the selected exposure policy.
enum DockerDynamicPortTransport: Hashable, Sendable {
    case tcp
    case udp

    var name: String {
        switch self {
        case .tcp: return "TCP"
        case .udp: return "UDP"
        }
    }
}

/// One dynamic publication that the proxy may rewrite with a held kernel-selected
/// host port before the request reaches the guest Engine.
struct DockerDynamicPortPublication: Hashable, Sendable {
    let transport: DockerDynamicPortTransport
    let hostIP: String
    let hostPort: Int
    let containerPort: Int
    /// `nil` means Docker's ordinary ephemeral allocation. A value means allocate
    /// exactly one port from this inclusive range before create reaches dockerd.
    let requestedHostPortRange: DockerHostPortRange?

    init(
        transport: DockerDynamicPortTransport,
        hostIP: String,
        hostPort: Int,
        containerPort: Int,
        requestedHostPortRange: DockerHostPortRange? = nil
    ) {
        self.transport = transport
        self.hostIP = hostIP
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.requestedHostPortRange = requestedHostPortRange
    }

    var allocationIdentity: AllocationIdentity {
        AllocationIdentity(
            transport: transport,
            containerPort: containerPort,
            requestedHostPortRange: requestedHostPortRange)
    }

    struct AllocationIdentity: Hashable, Sendable {
        let transport: DockerDynamicPortTransport
        let containerPort: Int
        let requestedHostPortRange: DockerHostPortRange?
    }
}

/// One effective `PublishAllPorts` mapping emitted by patched Moby at container
/// start. Unlike a create document, this already includes image `EXPOSE` ports;
/// the host must reserve every entry before replying to the guest allocator.
struct DockerPublishAllPortRequest: Hashable, Sendable {
    let transport: DockerDynamicPortTransport
    let hostIP: String
    let requestedHostPort: Int
    let containerPort: Int
}

/// A bounded dynamic-host-port create document that can be transformed before it
/// reaches the guest Engine.
///
/// This is intentionally not a general Docker create model. It remembers only the
/// exact JSON entries the Phase 1 transaction is allowed to replace, and reparses the
/// original body before rewriting so a plan can never be applied to different bytes.
struct DockerDynamicPortCreatePlan {

    /// The exact dynamic spelling admitted from the original JSON document.
    ///
    /// Docker accepts three distinct string-level forms for a dynamically allocated
    /// host port. Keep them distinct so a plan cannot rewrite a later fixed,
    /// whitespace-normalized, or otherwise different binding.
    fileprivate enum DynamicHostPortOrigin: Hashable {
        case omitted
        case empty
        case explicitZero
        case range(DockerHostPortRange)
    }

    private struct Entry: Hashable {
        let containerPortKey: String
        let index: Int
        let transport: DockerDynamicPortTransport
        let hostIP: String
        let containerPort: Int
        /// Keep the request's exact dynamic spelling so a stale plan cannot
        /// overwrite a later fixed or malformed binding.
        let hostPortOrigin: DynamicHostPortOrigin
    }

    let requestedPublications: [DockerDynamicPortPublication]
    let fixedPlan: DockerFixedPortLeasePlan
    private let body: Data
    private let entries: [Entry]

    fileprivate init(
        body: Data,
        entries: [(
            containerPortKey: String,
            index: Int,
            transport: DockerDynamicPortTransport,
            hostIP: String,
            containerPort: Int,
            hostPortOrigin: DynamicHostPortOrigin
        )],
        fixedPlan: DockerFixedPortLeasePlan
    ) {
        self.body = body
        self.entries = entries.map {
            Entry(
                containerPortKey: $0.containerPortKey,
                index: $0.index,
                transport: $0.transport,
                hostIP: $0.hostIP,
                containerPort: $0.containerPort,
                hostPortOrigin: $0.hostPortOrigin)
        }
        self.requestedPublications = entries.map { entry in
            let requestedRange: DockerHostPortRange?
            if case .range(let range) = entry.hostPortOrigin {
                requestedRange = range
            } else {
                requestedRange = nil
            }
            return DockerDynamicPortPublication(
                transport: entry.transport,
                hostIP: entry.hostIP,
                hostPort: 0,
                containerPort: entry.containerPort,
                requestedHostPortRange: requestedRange)
        }
        self.fixedPlan = fixedPlan
    }

    /// Replaces only planned empty, omitted, literal `"0"`, or valid raw range
    /// `HostPort` entries with the host-reserved concrete ports.
    ///
    /// Rechecking every entry is defensive but significant: JSON object graphs are
    /// mutable Foundation values, and a transaction must never turn a stale plan into
    /// a different container's port mapping.
    func rewrittenBody(with publications: [DockerDynamicPortPublication]) throws -> Data {
        guard publications.count == entries.count else {
            throw MorbError.protocolViolation("dynamic published-port allocator returned the wrong number of ports")
        }
        guard
            var object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
            var hostConfig = object["HostConfig"] as? [String: Any],
            var portBindings = hostConfig["PortBindings"] as? [String: Any]
        else {
            throw MorbError.protocolViolation("dynamic published-port create body changed before it could be rewritten")
        }

        for (entry, publication) in zip(entries, publications) {
            let expectedRange: DockerHostPortRange?
            if case .range(let range) = entry.hostPortOrigin {
                expectedRange = range
            } else {
                expectedRange = nil
            }
            guard publication.transport == entry.transport,
                  publication.hostIP == entry.hostIP,
                  publication.containerPort == entry.containerPort,
                  publication.requestedHostPortRange == expectedRange,
                  (1...65535).contains(publication.hostPort),
                  expectedRange.map({ $0.ports.contains(publication.hostPort) }) ?? true,
                  var bindings = portBindings[entry.containerPortKey] as? [Any],
                  bindings.indices.contains(entry.index),
                  var binding = bindings[entry.index] as? [String: Any]
            else {
                throw MorbError.protocolViolation("dynamic published-port create plan no longer matches its request body")
            }
            let originalFormStillMatches: Bool
            switch entry.hostPortOrigin {
            case .omitted:
                originalFormStillMatches = binding["HostPort"] == nil
            case .empty:
                originalFormStillMatches = (binding["HostPort"] as? String) == ""
            case .explicitZero:
                originalFormStillMatches = (binding["HostPort"] as? String) == "0"
            case .range(let range):
                originalFormStillMatches = (binding["HostPort"] as? String) == range.stringValue
            }
            guard originalFormStillMatches else {
                throw MorbError.protocolViolation("dynamic published-port create plan no longer matches its request body")
            }
            binding["HostPort"] = String(publication.hostPort)
            bindings[entry.index] = binding
            portBindings[entry.containerPortKey] = bindings
        }

        hostConfig["PortBindings"] = portBindings
        object["HostConfig"] = hostConfig
        guard JSONSerialization.isValidJSONObject(object) else {
            throw MorbError.protocolViolation("rewritten dynamic published-port create is not valid JSON")
        }
        return try JSONSerialization.data(withJSONObject: object, options: [])
    }
}

/// Checks the portion of a normal Docker container-create document Morbstack can
/// verify before it relays the request to the guest Engine.
public enum DockerPortPublicationPreflight {

    /// Maximum number of distinct concrete fixed host endpoints one recognized create
    /// may reserve across TCP and UDP.
    ///
    /// Docker CLI normalizes a fixed equal-length range into a collection of ordinary
    /// bindings, so this is intentionally a lease-size limit rather than a second
    /// range parser. Holding listeners runs under the forwarder's ledger lock before
    /// a guest create; beyond this bounded amount, refusing the request is safer than
    /// creating a container while only some of its requested endpoints are held.
    public static let maximumSynchronousFixedPortBindings = 128

    /// Compatibility spelling for the original TCP-only boundary. New code must use
    /// ``maximumSynchronousFixedPortBindings`` so a mixed TCP+UDP request cannot grow
    /// beyond the same bounded lease transaction.
    public static let maximumSynchronousFixedTCPBindings = maximumSynchronousFixedPortBindings

    /// Proves that an inspect response belongs to the immutable ID in a pending
    /// start/restart request and uses Engine-owned `PublishAllPorts` allocation.
    /// No image metadata is inferred on the host: patched Moby expands `EXPOSE`
    /// inside the guest and calls back only after this narrow proof succeeds.
    static func stoppedContainerUsesPublishAllPorts(in body: Data, expectedContainerID: String) -> Bool {
        guard
            isFullContainerID(expectedContainerID),
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            (object["Id"] as? String) == expectedContainerID,
            let state = object["State"] as? [String: Any],
            (state["Running"] as? Bool) == false,
            let hostConfig = object["HostConfig"] as? [String: Any],
            !networkModeHasContainerNamespace(in: hostConfig),
            !isGuestHostNetwork(in: hostConfig),
            (hostConfig["PublishAllPorts"] as? Bool) == true
        else {
            return false
        }
        return true
    }

    /// A persisted Engine restart policy may start this container before a user
    /// issues another Docker API request after a VM boot. Register a durable host
    /// allocator session for those `-P` containers during forwarder recovery.
    static func restartPolicyUsesPublishAllPorts(in body: Data, expectedContainerID: String) -> Bool {
        guard
            isFullContainerID(expectedContainerID),
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            (object["Id"] as? String) == expectedContainerID,
            let hostConfig = object["HostConfig"] as? [String: Any],
            !networkModeHasContainerNamespace(in: hostConfig),
            !isGuestHostNetwork(in: hostConfig),
            (hostConfig["PublishAllPorts"] as? Bool) == true,
            let restartPolicy = hostConfig["RestartPolicy"] as? [String: Any],
            let policyName = restartPolicy["Name"] as? String
        else {
            return false
        }
        return ["always", "unless-stopped", "on-failure"].contains(policyName)
    }

    public enum Verdict: Equatable, Sendable {
        case allowed
        case rejected(message: String)
    }

    /// The Phase 1 dynamic allocator either receives a fully understood TCP/UDP
    /// request or does not run at all. `rejected` is deliberately precise: forwarding
    /// one of these shapes dynamically would let guest dockerd choose a port after
    /// the host had already committed to a different endpoint.
    enum DynamicPortVerdict {
        case notDynamic
        case supported(DockerDynamicPortCreatePlan)
        case rejected(message: String)
    }

    /// Inspects only explicit published ports in `HostConfig.PortBindings`.
    ///
    /// Invalid JSON and shapes the Engine owns are allowed through for dockerd to
    /// diagnose. This avoids turning a host-side advisory into a second, incompatible
    /// implementation of Docker's create validator.
    /// How this preflight learns whether a concrete host endpoint is free.
    ///
    /// Injectable for one reason: the default implementation performs a **real
    /// bind**, so any test naming a concrete port silently depends on what happens
    /// to be listening on the machine running it. (5353/udp belongs to
    /// mDNSResponder on every normal Mac, which is how this was noticed.) Production
    /// callers must keep the default — an advisory that does not actually try the
    /// bind is not an advisory.
    public typealias HostPortAvailabilityProbe =
        (Int, HostPortPreflight.Transport, DockerHostAddress) -> HostPortPreflight.Result

    public static func inspectContainerCreate(
        body: Data,
        hostNetworkPortPublishing: Bool = false,
        availability: HostPortAvailabilityProbe = HostPortPreflight.check(port:transport:hostAddress:)
    ) -> Verdict {
        guard
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let hostConfig = object["HostConfig"] as? [String: Any]
        else {
            return .allowed
        }
        // A container namespace remains an unmodified Moby error. Guest host
        // networking is different: when the explicit policy is enabled, a `-p`
        // declaration is the one truthful way to name a guest listener that should
        // be reachable from this Mac through VZNAT and vsock.
        guard guestDialPort(
            in: hostConfig,
            hostNetworkPortPublishing: hostNetworkPortPublishing) != nil,
              let portBindings = hostConfig["PortBindings"] as? [String: Any]
        else {
            return .allowed
        }

        var examined: Set<String> = []
        var fixedHostEndpoints: Set<String> = []
        // Morbstack has exactly one listener per transport/address/port endpoint.
        // IPv4 and IPv6 each keep their own endpoint key, so native Docker dual-stack
        // publications do not overwrite each other.
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
                let rawHostPort = string(entry["HostPort"])?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                // The dynamic transaction validates this exact string spelling
                // below. It has no fixed host endpoint to preflight here.
                if rawHostPort == "0" || DockerHostPortRange(string: rawHostPort) != nil
                {
                    continue
                }
                let hostPort = rawHostPort
                guard !hostPort.isEmpty else {
                    // Docker will allocate this later. No host endpoint exists yet to
                    // check, and treating it as a fixed port would be a false claim.
                    continue
                }
                let hostIP = string(entry["HostIp"])?.trimmingCharacters(in: .whitespaces) ?? ""
                // The dedup key has to include the container port. Two *different*
                // container ports published to ONE host endpoint is exactly the
                // ambiguity the `containerTargetByEndpoint` check below exists to
                // reject; keying only on the host side made the second declaration
                // look already-examined and skipped that check entirely, so
                // `-p 8080:80 -p 8080:81` was admitted and reached the Engine.
                // Identical repeated declarations still collapse to one probe.
                let key = "\(protocolName)|\(hostIP)|\(hostPort)|\(containerPort)"
                guard examined.insert(key).inserted else { continue }

                guard protocolName == "tcp" || protocolName == "udp" else {
                    return .rejected(
                        message: "published \(protocolName.uppercased()) port \(hostPort) is not supported by Morbstack's host forwarder")
                }

                guard let address = DockerHostAddress(dockerHostIP: hostIP) else {
                    return .rejected(
                        message: "published host address \(hostIP) is not a numeric IPv4 or IPv6 address")
                }
                guard let port = Int(hostPort) else {
                    // A valid host range belongs to the same host-first dynamic
                    // transaction as an omitted port; the later parser retains the
                    // exact spelling and rewrites it to the atomically held port.
                    if DockerHostPortRange(string: hostPort) != nil { continue }
                    return .rejected(
                        message: "published \(protocolName.uppercased()) host port \(hostPort) is not a valid port or port range")
                }

                let endpoint = DockerHostEndpoint(hostIP: hostIP, port: port)!
                if fixedHostEndpoints.insert("\(protocolName)|\(endpoint.description)").inserted,
                   fixedHostEndpoints.count > maximumSynchronousFixedPortBindings {
                    return .rejected(
                        message: "published mapping has more than \(maximumSynchronousFixedPortBindings) concrete fixed host endpoints; Morbstack refuses a partial port lease")
                }

                if let targetPort = Self.containerPort(in: containerPort) {
                    let targetEndpoint = "\(protocolName)|\(endpoint.description)"
                    if let existingTarget = containerTargetByEndpoint[targetEndpoint], existingTarget != targetPort {
                        return .rejected(
                            message: "published \(protocolName.uppercased()) endpoint \(endpoint.description) maps to more than one container port")
                    }
                    containerTargetByEndpoint[targetEndpoint] = targetPort
                }

                let transport: HostPortPreflight.Transport = protocolName == "tcp" ? .tcp : .udp
                let result = availability(port, transport, address)
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
                guard DockerHostAddress(dockerHostIP: hostIP) != nil else { continue }

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

    /// Returns the fixed UDP publications that can be retained by the IPv4 loopback
    /// UDP data plane. This is intentionally separate from the TCP extractor: the
    /// same numeric port is legal once for each transport, but one UDP socket cannot
    /// represent two different guest UDP targets.
    public static func explicitUDPBindings(in body: Data) -> [DockerExplicitUDPPortBinding] {
        guard
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let hostConfig = object["HostConfig"] as? [String: Any],
            let portBindings = hostConfig["PortBindings"] as? [String: Any]
        else {
            return []
        }

        var byHostPort: [Int: DockerExplicitUDPPortBinding] = [:]
        var ambiguousHostPorts: Set<Int> = []
        for containerPortKey in portBindings.keys.sorted() {
            guard networkProtocol(in: containerPortKey) == "udp",
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
                guard DockerHostAddress(dockerHostIP: hostIP) != nil else { continue }

                let candidate = DockerExplicitUDPPortBinding(
                    hostIP: hostIP, hostPort: hostPort, containerPort: containerPort)
                guard !ambiguousHostPorts.contains(hostPort) else { continue }
                if let existing = byHostPort[hostPort] {
                    guard existing.containerPort == candidate.containerPort else {
                        byHostPort.removeValue(forKey: hostPort)
                        ambiguousHostPorts.insert(hostPort)
                        continue
                    }
                } else {
                    byHostPort[hostPort] = candidate
                }
            }
        }
        return byHostPort.values.sorted { $0.hostPort < $1.hostPort }
    }

    /// Returns the complete fixed transport-indexed publication set from a create
    /// body, or `nil` if any sibling is absent, dynamic, opaque, unsupported, or
    /// ambiguous. This prevents a known fixed TCP/UDP endpoint from becoming a
    /// partial lease beside a shape Morbstack cannot own transactionally.
    public static func fixedPortLeasePlan(
        in body: Data,
        hostNetworkPortPublishing: Bool = false
    ) -> DockerFixedPortLeasePlan? {
        guard
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let hostConfig = object["HostConfig"] as? [String: Any],
            let portBindings = hostConfig["PortBindings"] as? [String: Any],
            !portBindings.isEmpty
        else {
            return nil
        }
        guard let guestDialPort = guestDialPort(
            in: hostConfig,
            hostNetworkPortPublishing: hostNetworkPortPublishing) else {
            return nil
        }
        guard (hostConfig["PublishAllPorts"] as? Bool) != true else {
            // The proxy rejects -P before it reaches this parser. Keep the plan
            // independently strict as well: an explicit sibling cannot be held
            // while the Engine owns another publication selected from image config.
            return nil
        }

        var tcpByEndpoint: [DockerHostEndpoint: DockerExplicitTCPPortBinding] = [:]
        var udpByEndpoint: [DockerHostEndpoint: DockerExplicitUDPPortBinding] = [:]
        var ambiguousTCPEndpoints: Set<DockerHostEndpoint> = []
        var ambiguousUDPEndpoints: Set<DockerHostEndpoint> = []

        for containerPortKey in portBindings.keys.sorted() {
            let protocolName = networkProtocol(in: containerPortKey)
            guard protocolName == "tcp" || protocolName == "udp",
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
                    return nil
                }
                let hostIP = string(entry["HostIp"])?.trimmingCharacters(in: .whitespaces) ?? ""

                switch protocolName {
                case "tcp":
                    guard DockerHostAddress(dockerHostIP: hostIP) != nil else {
                        return nil
                    }
                    let candidate = DockerExplicitTCPPortBinding(
                        hostIP: hostIP, hostPort: hostPort, containerPort: containerPort)
                    guard let endpoint = candidate.endpoint,
                          !ambiguousTCPEndpoints.contains(endpoint)
                    else { continue }
                    if let existing = tcpByEndpoint[endpoint] {
                        guard existing.containerPort == candidate.containerPort else {
                            tcpByEndpoint.removeValue(forKey: endpoint)
                            ambiguousTCPEndpoints.insert(endpoint)
                            continue
                        }
                    } else {
                        tcpByEndpoint[endpoint] = candidate
                    }

                case "udp":
                    guard DockerHostAddress(dockerHostIP: hostIP) != nil else {
                        return nil
                    }
                    let candidate = DockerExplicitUDPPortBinding(
                        hostIP: hostIP, hostPort: hostPort, containerPort: containerPort)
                    guard let endpoint = candidate.endpoint,
                          !ambiguousUDPEndpoints.contains(endpoint)
                    else { continue }
                    if let existing = udpByEndpoint[endpoint] {
                        guard existing.containerPort == candidate.containerPort else {
                            udpByEndpoint.removeValue(forKey: endpoint)
                            ambiguousUDPEndpoints.insert(endpoint)
                            continue
                        }
                    } else {
                        udpByEndpoint[endpoint] = candidate
                    }

                default:
                    return nil
                }
            }
        }

        let tcp = tcpByEndpoint.values.sorted { $0.hostPort == $1.hostPort ? $0.hostIP < $1.hostIP : $0.hostPort < $1.hostPort }
        let udp = udpByEndpoint.values.sorted { $0.hostPort == $1.hostPort ? $0.hostIP < $1.hostIP : $0.hostPort < $1.hostPort }
        guard ambiguousTCPEndpoints.isEmpty,
              ambiguousUDPEndpoints.isEmpty,
              !tcp.isEmpty || !udp.isEmpty,
              tcp.count + udp.count <= maximumSynchronousFixedPortBindings
        else {
            return nil
        }
        return DockerFixedPortLeasePlan(tcp: tcp, udp: udp, guestDialPort: guestDialPort)
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

    /// Returns the fully understood fixed TCP/UDP publications in a stopped-container
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
    static func stoppedContainerFixedPortLeasePlan(
        in inspectBody: Data,
        expectedContainerID: String,
        hostNetworkPortPublishing: Bool = false
    ) -> DockerFixedPortLeasePlan? {
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
        guard let guestDialPort = guestDialPort(
            in: hostConfig,
            hostNetworkPortPublishing: hostNetworkPortPublishing) else {
            return nil
        }
        guard (hostConfig["PublishAllPorts"] as? Bool) != true else {
            return nil
        }

        var tcpByEndpoint: [DockerHostEndpoint: DockerExplicitTCPPortBinding] = [:]
        var udpByEndpoint: [DockerHostEndpoint: DockerExplicitUDPPortBinding] = [:]
        var ambiguousTCPEndpoints: Set<DockerHostEndpoint> = []
        var ambiguousUDPEndpoints: Set<DockerHostEndpoint> = []

        for containerPortKey in portBindings.keys.sorted() {
            let protocolName = networkProtocol(in: containerPortKey)
            guard protocolName == "tcp" || protocolName == "udp",
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
                    // Empty, zero, missing, and raw host-port ranges are Engine-owned
                    // allocation forms. Recovery may not reserve only their siblings.
                    return nil
                }
                let hostIP = string(entry["HostIp"])?.trimmingCharacters(in: .whitespaces) ?? ""

                switch protocolName {
                case "tcp":
                    guard DockerHostAddress(dockerHostIP: hostIP) != nil else {
                        return nil
                    }
                    let candidate = DockerExplicitTCPPortBinding(
                        hostIP: hostIP, hostPort: hostPort, containerPort: containerPort)
                    guard let endpoint = candidate.endpoint,
                          !ambiguousTCPEndpoints.contains(endpoint)
                    else { continue }
                    if let existing = tcpByEndpoint[endpoint] {
                        guard existing.containerPort == candidate.containerPort else {
                            tcpByEndpoint.removeValue(forKey: endpoint)
                            ambiguousTCPEndpoints.insert(endpoint)
                            continue
                        }
                    } else {
                        tcpByEndpoint[endpoint] = candidate
                    }

                case "udp":
                    guard DockerHostAddress(dockerHostIP: hostIP) != nil else {
                        return nil
                    }
                    let candidate = DockerExplicitUDPPortBinding(
                        hostIP: hostIP, hostPort: hostPort, containerPort: containerPort)
                    guard let endpoint = candidate.endpoint,
                          !ambiguousUDPEndpoints.contains(endpoint)
                    else { continue }
                    if let existing = udpByEndpoint[endpoint] {
                        guard existing.containerPort == candidate.containerPort else {
                            udpByEndpoint.removeValue(forKey: endpoint)
                            ambiguousUDPEndpoints.insert(endpoint)
                            continue
                        }
                    } else {
                        udpByEndpoint[endpoint] = candidate
                    }

                default:
                    return nil
                }
            }
        }

        let tcp = tcpByEndpoint.values.sorted { $0.hostPort == $1.hostPort ? $0.hostIP < $1.hostIP : $0.hostPort < $1.hostPort }
        let udp = udpByEndpoint.values.sorted { $0.hostPort == $1.hostPort ? $0.hostIP < $1.hostIP : $0.hostPort < $1.hostPort }
        guard ambiguousTCPEndpoints.isEmpty,
              ambiguousUDPEndpoints.isEmpty,
              !tcp.isEmpty || !udp.isEmpty,
              tcp.count + udp.count <= maximumSynchronousFixedPortBindings
        else {
            return nil
        }
        return DockerFixedPortLeasePlan(tcp: tcp, udp: udp, guestDialPort: guestDialPort)
    }

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
                guard DockerHostAddress(dockerHostIP: hostIP) != nil else {
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

    /// Recognizes Docker's empty, omitted, literal `"0"`, or bounded host-range TCP
    /// and UDP bindings for the stateful Phase 1 allocator. `PublishAllPorts`,
    /// invalid address/protocol values, and opaque sibling entries are rejected rather
    /// than silently falling back to an Engine-owned allocation.
    static func dynamicPortCreatePlan(
        in body: Data,
        hostNetworkPortPublishing: Bool = false
    ) -> DynamicPortVerdict {
        guard
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let hostConfig = object["HostConfig"] as? [String: Any]
        else {
            return .notDynamic
        }

        // `-P` is allocated at guest start after Moby merges image EXPOSE ports.
        // It must not enter this create-time rewrite path: the patched Engine asks
        // the host allocator for the complete effective set atomically instead.
        if let publishAllPorts = hostConfig["PublishAllPorts"] as? Bool, publishAllPorts {
            return .notDynamic
        }
        guard let guestDialPort = guestDialPort(
            in: hostConfig,
            hostNetworkPortPublishing: hostNetworkPortPublishing) else {
            return .notDynamic
        }

        guard let portBindings = hostConfig["PortBindings"] as? [String: Any] else {
            return .notDynamic
        }

        var dynamicEntries: [(
            containerPortKey: String,
            index: Int,
            transport: DockerDynamicPortTransport,
            hostIP: String,
            containerPort: Int,
            hostPortOrigin: DockerDynamicPortCreatePlan.DynamicHostPortOrigin
        )] = []
        var sawOpaqueEntry = false
        var unsupportedSiblingMessage: String?
        var fixedTCPByEndpoint: [DockerHostEndpoint: DockerExplicitTCPPortBinding] = [:]
        var fixedUDPByEndpoint: [DockerHostEndpoint: DockerExplicitUDPPortBinding] = [:]
        var ambiguousTCPEndpoints: Set<DockerHostEndpoint> = []
        var ambiguousUDPEndpoints: Set<DockerHostEndpoint> = []

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

                let dynamicHostPortOrigin: DockerDynamicPortCreatePlan.DynamicHostPortOrigin?
                if hostPortWasOmitted {
                    dynamicHostPortOrigin = .omitted
                } else if rawHostPort == "" {
                    dynamicHostPortOrigin = .empty
                } else if rawHostPort == "0" {
                    dynamicHostPortOrigin = .explicitZero
                } else if let rawHostPort, let range = DockerHostPortRange(string: rawHostPort) {
                    dynamicHostPortOrigin = .range(range)
                } else {
                    dynamicHostPortOrigin = nil
                }

                if let dynamicHostPortOrigin {
                    let transport: DockerDynamicPortTransport
                    switch protocolName {
                    case "tcp": transport = .tcp
                    case "udp": transport = .udp
                    default:
                        return .rejected(
                            message: "dynamic published \(protocolName.uppercased()) ports are not supported yet")
                    }
                    guard let containerPort = parsedContainerPort,
                          (1...65535).contains(containerPort)
                    else {
                        return .rejected(
                            message: "dynamic published \(transport.name) port \(containerPortKey) is not a single valid container port")
                    }
                    let hostIP: String
                    if let value = binding["HostIp"] {
                        guard let string = value as? String else {
                            return .rejected(
                                message: "dynamic published \(transport.name) HostIp must be a string")
                        }
                        hostIP = string.trimmingCharacters(in: .whitespaces)
                    } else {
                        hostIP = ""
                    }
                    guard DockerHostAddress(dockerHostIP: hostIP) != nil else {
                        return .rejected(
                            message: "published host address \(hostIP) is not a numeric IPv4 or IPv6 address")
                    }
                    dynamicEntries.append((
                        containerPortKey,
                        index,
                        transport,
                        hostIP,
                        containerPort,
                        dynamicHostPortOrigin))
                } else {
                    guard let rawHostPort,
                          let hostPort = Int(rawHostPort),
                          (1...65535).contains(hostPort)
                    else {
                        unsupportedSiblingMessage = unsupportedSiblingMessage
                            ?? "published \(protocolName.uppercased()) host port \(rawHostPort ?? "missing") is not a valid port or port range"
                        continue
                    }
                    let hostIP: String
                    if let value = binding["HostIp"] {
                        guard let string = value as? String else {
                            unsupportedSiblingMessage = unsupportedSiblingMessage
                                ?? "published \(protocolName.uppercased()) HostIp must be a string"
                            continue
                        }
                        hostIP = string.trimmingCharacters(in: .whitespaces)
                    } else {
                        hostIP = ""
                    }
                    guard let containerPort = parsedContainerPort,
                          (1...65535).contains(containerPort)
                    else {
                        unsupportedSiblingMessage = unsupportedSiblingMessage
                            ?? "published \(protocolName.uppercased()) port \(containerPortKey) is not a single valid container port"
                        continue
                    }

                    switch protocolName {
                    case "tcp":
                        guard DockerHostAddress(dockerHostIP: hostIP) != nil else {
                            unsupportedSiblingMessage = unsupportedSiblingMessage
                                ?? "published host address \(hostIP) is not a numeric IPv4 or IPv6 address"
                            continue
                        }
                        let candidate = DockerExplicitTCPPortBinding(
                            hostIP: hostIP, hostPort: hostPort, containerPort: containerPort)
                        guard let endpoint = candidate.endpoint,
                              !ambiguousTCPEndpoints.contains(endpoint)
                        else { continue }
                        if let existing = fixedTCPByEndpoint[endpoint] {
                            guard existing.containerPort == candidate.containerPort else {
                                fixedTCPByEndpoint.removeValue(forKey: endpoint)
                                ambiguousTCPEndpoints.insert(endpoint)
                                continue
                            }
                        } else {
                            fixedTCPByEndpoint[endpoint] = candidate
                        }

                    case "udp":
                        guard DockerHostAddress(dockerHostIP: hostIP) != nil else {
                            unsupportedSiblingMessage = unsupportedSiblingMessage
                                ?? "published host address \(hostIP) is not a numeric IPv4 or IPv6 address"
                            continue
                        }
                        let candidate = DockerExplicitUDPPortBinding(
                            hostIP: hostIP, hostPort: hostPort, containerPort: containerPort)
                        guard let endpoint = candidate.endpoint,
                              !ambiguousUDPEndpoints.contains(endpoint)
                        else { continue }
                        if let existing = fixedUDPByEndpoint[endpoint] {
                            guard existing.containerPort == candidate.containerPort else {
                                fixedUDPByEndpoint.removeValue(forKey: endpoint)
                                ambiguousUDPEndpoints.insert(endpoint)
                                continue
                            }
                        } else {
                            fixedUDPByEndpoint[endpoint] = candidate
                        }

                    default:
                        unsupportedSiblingMessage = unsupportedSiblingMessage
                            ?? "published \(protocolName.uppercased()) ports are not supported by Morbstack's host forwarder"
                    }
                }
            }
        }

        guard !dynamicEntries.isEmpty else { return .notDynamic }
        if let unsupportedSiblingMessage {
            return .rejected(message: unsupportedSiblingMessage)
        }
        guard !sawOpaqueEntry else {
            return .rejected(
                message: "dynamic published ports require a fully understood PortBindings document")
        }
        guard ambiguousTCPEndpoints.isEmpty, ambiguousUDPEndpoints.isEmpty else {
            return .rejected(
                message: "dynamic published ports cannot map one host endpoint to multiple container targets")
        }
        let fixedPlan = DockerFixedPortLeasePlan(
            tcp: fixedTCPByEndpoint.values.sorted {
                $0.hostPort == $1.hostPort ? $0.hostIP < $1.hostIP : $0.hostPort < $1.hostPort
            },
            udp: fixedUDPByEndpoint.values.sorted {
                $0.hostPort == $1.hostPort ? $0.hostIP < $1.hostIP : $0.hostPort < $1.hostPort
            },
            guestDialPort: guestDialPort)
        guard dynamicEntries.count + fixedPlan.tcp.count + fixedPlan.udp.count
            <= maximumSynchronousFixedPortBindings
        else {
            return .rejected(
                message: "published mapping has more than \(maximumSynchronousFixedPortBindings) host endpoints; Morbstack refuses a partial port lease")
        }
        return .supported(
            DockerDynamicPortCreatePlan(
                body: body,
                entries: dynamicEntries,
                fixedPlan: fixedPlan))
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

    private static func guestDialPort(
        in hostConfig: [String: Any],
        hostNetworkPortPublishing: Bool
    ) -> DockerGuestDialPort? {
        guard !networkModeHasContainerNamespace(in: hostConfig) else { return nil }
        guard isGuestHostNetwork(in: hostConfig) else { return .publishedHostPort }
        return hostNetworkPortPublishing ? .containerPort : nil
    }

    /// `container:<id-or-name>` joins another container's namespace. Moby must own
    /// that incompatibility error; reserving a Mac endpoint first would make a
    /// rejected create externally observable.
    private static func networkModeHasContainerNamespace(in hostConfig: [String: Any]) -> Bool {
        guard let networkMode = hostConfig["NetworkMode"] as? String else { return false }
        return networkMode.hasPrefix("container:")
    }

    private static func isGuestHostNetwork(in hostConfig: [String: Any]) -> Bool {
        (hostConfig["NetworkMode"] as? String) == "host"
    }

    private static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
