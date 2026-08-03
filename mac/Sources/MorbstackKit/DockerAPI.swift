// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Foundation

/// The host address Docker attached to a published-port binding.
///
/// Docker's empty `HostIp` is not a synonym for loopback: it means the IPv4
/// wildcard address, exactly as `docker run -p 8080:80` does on a native Linux
/// host. Keeping that distinction as a value instead of translating it at the
/// listener boundary prevents an externally reachable Docker publication from
/// quietly becoming a local-only one on the Mac.
public enum DockerHostAddress: Hashable, Sendable {
    case ipv4(String)
    case ipv6(String)

    /// Parses one Engine `HostIp` spelling. The empty spelling is Docker's IPv4
    /// wildcard address. Host names are intentionally not accepted: Engine port
    /// bindings describe socket addresses, not an address lookup that could change
    /// between Docker's create reply and the host listener bind.
    public init?(dockerHostIP: String) {
        let candidate = dockerHostIP.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = candidate.isEmpty ? "0.0.0.0" : candidate

        var ipv4 = in_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 {
            self = .ipv4(address)
            return
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, address, &ipv6) == 1 {
            self = .ipv6(address)
            return
        }
        return nil
    }

    /// The exact (or empty-normalized) spelling the Mac listener binds.
    public var stringValue: String {
        switch self {
        case .ipv4(let address), .ipv6(let address): address
        }
    }

    public var family: Int32 {
        switch self {
        case .ipv4: AF_INET
        case .ipv6: AF_INET6
        }
    }

    /// `127/8` and `::1` stay local even when network exposure is disabled.
    public var isLoopback: Bool {
        switch self {
        case .ipv4(let address):
            var parsed = in_addr()
            guard inet_pton(AF_INET, address, &parsed) == 1 else { return false }
            return (UInt32(bigEndian: parsed.s_addr) & 0xff00_0000) == 0x7f00_0000
        case .ipv6(let address):
            var parsed = in6_addr()
            guard inet_pton(AF_INET6, address, &parsed) == 1 else { return false }
            return withUnsafeBytes(of: parsed) { bytes in
                bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            }
        }
    }
}

/// A transport-specific listener key. IPv4 and IPv6 have separate socket
/// namespaces on macOS when the IPv6 socket is `IPV6_V6ONLY`, so two Docker
/// publications may legitimately use the same numeric port on different families.
public struct DockerHostEndpoint: Hashable, Sendable {
    public let address: DockerHostAddress
    public let port: Int

    public init?(hostIP: String, port: Int) {
        guard (1...65_535).contains(port), let address = DockerHostAddress(dockerHostIP: hostIP) else {
            return nil
        }
        self.address = address
        self.port = port
    }

    public var description: String {
        switch address {
        case .ipv4:
            return "\(address.stringValue):\(port)"
        case .ipv6:
            return "[\(address.stringValue)]:\(port)"
        }
    }
}

/// Whether Docker publications may accept traffic from interfaces beyond the Mac.
///
/// This is an engine-level user preference, not a listener fallback. The default is
/// Docker-compatible (`localNetwork`): a bare `-p 8080:80` owns `0.0.0.0:8080`.
/// Users who want Docker Desktop-style local-only exposure can opt into
/// `loopbackOnly`; requests that need another address are then rejected before
/// dockerd sees a successful create.
public enum MorbPortExposure: String, Codable, CaseIterable, Sendable {
    case localNetwork
    case loopbackOnly

    public func permits(_ address: DockerHostAddress) -> Bool {
        self == .localNetwork || address.isLoopback
    }
}

/// One host port a container has asked Docker to publish.
///
/// This is the *host* view: `hostPort` is the number a `curl` on the Mac connects to,
/// `containerPort` is what the guest-side proxy ultimately reaches. The container
/// identity travels with it purely so the daemon can say which container owns a port
/// in log lines and in `morb status`.
public struct DockerPortBinding: Hashable, Sendable {

    /// The address Docker bound inside the guest: `0.0.0.0`, `127.0.0.1`, `::` or empty.
    public var hostIP: String
    /// The port to publish on the Mac's loopback interface.
    public var hostPort: Int
    /// The port inside the container.
    public var containerPort: Int
    /// `tcp` or `udp`, lowercased.
    public var networkProtocol: String
    /// The full container id.
    public var containerID: String
    /// A display name, without Docker's leading slash.
    public var containerName: String

    public init(
        hostIP: String,
        hostPort: Int,
        containerPort: Int,
        networkProtocol: String,
        containerID: String,
        containerName: String
    ) {
        self.hostIP = hostIP
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.networkProtocol = networkProtocol
        self.containerID = containerID
        self.containerName = containerName
    }

    /// `8080 -> web:80/tcp`, for logs and `morb status`.
    public var description: String {
        "\(hostPort) -> \(containerName):\(containerPort)/\(networkProtocol)"
    }
}

/// A container lifecycle event from `GET /events`.
public struct DockerContainerEvent: Equatable, Sendable {

    /// `start`, `die`, `destroy`, …
    public var action: String
    /// The container id the event is about.
    public var containerID: String
    /// The container name, when the event carried one.
    public var containerName: String?

    public init(action: String, containerID: String, containerName: String? = nil) {
        self.action = action
        self.containerID = containerID
        self.containerName = containerName
    }

    /// Whether this event can change the set of published ports.
    ///
    /// `exec_start`, `health_status` and friends fire constantly on a busy host and
    /// never move a port; refreshing on them would turn every `docker exec` into an
    /// Engine API round trip.
    public var affectsPublishedPorts: Bool {
        switch action {
        case "start", "die", "destroy", "stop", "kill", "pause", "unpause", "restart":
            return true
        default:
            return false
        }
    }
}

/// Decoding for the two Docker Engine API documents the port forwarder reads.
///
/// `JSONSerialization` rather than `Codable`: the Engine API is loosely typed in
/// exactly the places that matter (`Ports[].IP` is absent rather than empty when the
/// binding is to all addresses, `PublicPort` is absent for merely-exposed ports), and
/// a `Decodable` model would have to be written entirely in optionals anyway.
public enum DockerAPIDecoding {

    /// The Engine API version Morbstack pins its request paths to.
    ///
    /// Pinned rather than negotiated: an unpinned path makes dockerd answer with its
    /// newest version, and the fields parsed below are stable at 1.43 across every
    /// engine Morbstack ships against.
    public static let apiVersion = "v1.43"

    /// Path for the container listing.
    public static let containersPath = "/\(apiVersion)/containers/json"

    /// Path for the container-only event stream.
    public static var eventsPath: String {
        let filters = #"{"type":["container"]}"#
        return "/\(apiVersion)/events?filters=" + MinimalHTTP.percentEncodeQueryValue(filters)
    }

    /// Path for "just the containers that are actually running".
    ///
    /// Server-side filtering rather than counting `State == "running"` from the full
    /// listing: this is asked on the auto-suspend path, where the answer decides
    /// whether a user's containers keep existing, and the smaller the response and the
    /// less interpretation it needs, the fewer ways there are to get that wrong.
    public static var runningContainersPath: String {
        let filters = #"{"status":["running"]}"#
        return containersPath + "?filters=" + MinimalHTTP.percentEncodeQueryValue(filters)
    }

    /// Includes stopped containers as well as running ones. The normal forward set
    /// must remain based on `containersPath` (stopped containers have no service to
    /// reach), but the create/start lease ledger uses this only to prove a created
    /// container was destroyed and can release its held host listener.
    public static var allContainersPath: String {
        containersPath + "?all=1"
    }

    /// The immutable-container inspect path used by the bounded start-time TCP
    /// lease recovery. Callers admit only a full hexadecimal ID before interpolating
    /// it here, so no name, prefix, or path escaping semantics enter that protocol.
    public static func containerInspectPath(containerID: String) -> String {
        "/\(apiVersion)/containers/\(containerID)/json"
    }

    /// Counts the entries in a `GET /containers/json` response body.
    ///
    /// - Throws: ``MorbError/protocolViolation(_:)`` when the document is not an array.
    public static func containerCount(containersJSON data: Data) throws -> Int {
        let root = try JSONSerialization.jsonObject(with: data, options: [])
        guard let containers = root as? [Any] else {
            throw MorbError.protocolViolation("containers/json did not return a JSON array")
        }
        return containers.count
    }

    /// The full IDs in a `containers/json?all=1` response.
    ///
    /// Missing IDs are ignored rather than converted to an empty string, because an
    /// empty value must never match a held lease by accident.
    public static func containerIDs(containersJSON data: Data) throws -> Set<String> {
        let root = try JSONSerialization.jsonObject(with: data, options: [])
        guard let containers = root as? [Any] else {
            throw MorbError.protocolViolation("containers/json did not return a JSON array")
        }
        return Set(containers.compactMap { entry in
            guard let object = entry as? [String: Any], let id = object["Id"] as? String,
                  !id.isEmpty
            else { return nil }
            return id
        })
    }

    /// Extracts every published port from a `GET /containers/json` response body.
    ///
    /// - Throws: ``MorbError/protocolViolation(_:)`` when the document is not the
    ///   array of objects the Engine API is documented to return.
    public static func publishedPorts(containersJSON data: Data) throws -> [DockerPortBinding] {
        let root = try JSONSerialization.jsonObject(with: data, options: [])
        guard let containers = root as? [Any] else {
            throw MorbError.protocolViolation("containers/json did not return a JSON array")
        }

        var bindings: [DockerPortBinding] = []
        for entry in containers {
            guard let container = entry as? [String: Any] else { continue }
            let id = (container["Id"] as? String) ?? ""
            let name = displayName(id: id, names: container["Names"] as? [Any])
            guard let ports = container["Ports"] as? [Any] else { continue }

            for portEntry in ports {
                guard let port = portEntry as? [String: Any] else { continue }
                // No PublicPort means the port is merely EXPOSEd, not published.
                guard let publicPort = integer(port["PublicPort"]), publicPort > 0,
                      publicPort <= 65535
                else { continue }
                let privatePort = integer(port["PrivatePort"]) ?? publicPort
                let networkProtocol = ((port["Type"] as? String) ?? "tcp").lowercased()
                bindings.append(
                    DockerPortBinding(
                        hostIP: (port["IP"] as? String) ?? "",
                        hostPort: publicPort,
                        containerPort: privatePort,
                        networkProtocol: networkProtocol,
                        containerID: id,
                        containerName: name))
            }
        }
        return bindings
    }

    /// Decodes one line of the `/events` stream, or `nil` when it is not a container
    /// event this forwarder cares about.
    public static func containerEvent(line: Data) -> DockerContainerEvent? {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line, options: []),
              let event = object as? [String: Any]
        else { return nil }

        // `Type` is absent on very old engines, in which case the filter we asked for
        // is the only guarantee we have that this is a container event.
        if let type = event["Type"] as? String, type != "container" { return nil }

        // Modern engines send `Action`; `status` is the pre-1.22 spelling and is still
        // populated for compatibility.
        let action = (event["Action"] as? String) ?? (event["status"] as? String) ?? ""
        guard !action.isEmpty else { return nil }
        // `exec_create: /bin/sh` and `health_status: healthy` carry their detail after
        // a colon; only the verb matters here.
        let verb = String(action.split(separator: ":", maxSplits: 1)[0])
            .trimmingCharacters(in: .whitespaces)

        let actor = event["Actor"] as? [String: Any]
        let id = (event["id"] as? String) ?? (actor?["ID"] as? String) ?? ""
        guard !id.isEmpty else { return nil }

        var name: String?
        if let attributes = actor?["Attributes"] as? [String: Any] {
            name = attributes["name"] as? String
        }
        return DockerContainerEvent(action: verb, containerID: id, containerName: name)
    }

    /// `Names` is an array of `/`-prefixed strings; the first is the canonical one.
    private static func displayName(id: String, names: [Any]?) -> String {
        if let first = names?.compactMap({ $0 as? String }).first, !first.isEmpty {
            return first.hasPrefix("/") ? String(first.dropFirst()) : first
        }
        return id.isEmpty ? "?" : String(id.prefix(12))
    }

    /// JSON numbers arrive as `NSNumber`, but a permissive engine may send a string.
    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }
}

/// Turns a set of published ports into the listeners the Mac should actually have.
public enum PortForwardPlan {

    /// One host endpoint Docker described with more than one target.
    ///
    /// A Mac listener has no Docker-level routing information after it accepts a
    /// connection: it can reach exactly one container port. `containers/json` will
    /// normally contain two records for one dual-stack publication, and those are
    /// safe to collapse only when they prove the same container identity and target
    /// port. Every other duplicate is withheld rather than letting the order of a
    /// daemon response decide which service receives local traffic.
    public struct ListenerConflict: Hashable, Sendable {
        /// The exact Mac endpoint that cannot be represented safely.
        public let endpoint: DockerHostEndpoint
        /// `tcp` or `udp`.
        public let networkProtocol: String
        /// Every Docker record that competed for this endpoint, in stable order.
        public let bindings: [DockerPortBinding]

        public init(endpoint: DockerHostEndpoint, networkProtocol: String, bindings: [DockerPortBinding]) {
            self.endpoint = endpoint
            self.networkProtocol = networkProtocol
            self.bindings = bindings
        }

        /// A status/log diagnostic that names the denied host endpoint and targets.
        public var diagnostic: String {
            let targets = bindings
                .map { binding in
                    let identity = binding.containerID.isEmpty
                        ? "unidentified container"
                        : String(binding.containerID.prefix(12))
                    return "\(binding.containerName) [\(identity)]:\(binding.containerPort)"
                }
                .reduce(into: [String]()) { result, target in
                    if !result.contains(target) { result.append(target) }
                }
                .joined(separator: ", ")
            return "Docker reports competing \(networkProtocol.uppercased()) targets for "
                + "\(endpoint.description) (\(targets)); Morbstack is not forwarding this host endpoint"
        }
    }

    /// The safe listener set plus Docker publications that cannot be represented by
    /// one Mac listener.
    public struct ListenerReconciliation: Sendable {
        public let listeners: [DockerHostEndpoint: DockerPortBinding]
        public let conflicts: [DockerHostEndpoint: ListenerConflict]

        public init(
            listeners: [DockerHostEndpoint: DockerPortBinding],
            conflicts: [DockerHostEndpoint: ListenerConflict]
        ) {
            self.listeners = listeners
            self.conflicts = conflicts
        }
    }

    /// The exact Mac endpoint a Docker binding requests, after Docker's empty
    /// `HostIp` spelling is normalized to its real `0.0.0.0` meaning.
    public static func endpoint(for binding: DockerPortBinding) -> DockerHostEndpoint? {
        DockerHostEndpoint(hostIP: binding.hostIP, port: binding.hostPort)
    }

    /// Whether a binding gets a listener under the selected, explicit exposure
    /// policy. This admits both transports and both IP families; UDP is no longer
    /// silently restricted to IPv4.
    public static func isForwardable(
        _ binding: DockerPortBinding,
        exposure: MorbPortExposure
    ) -> Bool {
        guard binding.networkProtocol == "tcp" || binding.networkProtocol == "udp",
              let endpoint = endpoint(for: binding)
        else { return false }
        return exposure.permits(endpoint.address)
    }

    /// Produces the complete TCP reconciliation result.
    ///
    /// IPv4 and IPv6 bindings have independent native listener endpoints. They are
    /// therefore reconciled separately, even when Docker used the same port number.
    public static func reconcileTCPListeners(
        _ bindings: [DockerPortBinding],
        exposure: MorbPortExposure
    ) -> ListenerReconciliation {
        reconcileListeners(bindings) { binding in
            binding.networkProtocol == "tcp" && isForwardable(binding, exposure: exposure)
        }
    }

    /// Reduces raw TCP bindings to one desired listener per host port.
    ///
    /// Compatibility convenience for callers that only need the safe listener set.
    /// New reconciliation callers should use ``reconcileTCPListeners(_:)`` so a
    /// withheld conflicting publication can be reported rather than disappearing.
    public static func desiredListeners(
        _ bindings: [DockerPortBinding], exposure: MorbPortExposure
    ) -> [DockerHostEndpoint: DockerPortBinding] {
        reconcileTCPListeners(bindings, exposure: exposure).listeners
    }

    /// Produces the complete UDP reconciliation result.
    ///
    /// TCP and UDP have independent host-port spaces, but a UDP endpoint has the same
    /// single-target constraint within its own transport. See
    /// ``reconcileTCPListeners(_:)`` for the dual-stack and conflict policy.
    public static func reconcileUDPListeners(
        _ bindings: [DockerPortBinding],
        exposure: MorbPortExposure
    ) -> ListenerReconciliation {
        reconcileListeners(bindings) { binding in
            binding.networkProtocol == "udp" && isForwardable(binding, exposure: exposure)
        }
    }

    /// Reduces event-confirmed UDP publications to one listener per UDP host port.
    ///
    /// Compatibility convenience for callers that only need safe listener entries.
    public static func desiredUDPListeners(
        _ bindings: [DockerPortBinding], exposure: MorbPortExposure
    ) -> [DockerHostEndpoint: DockerPortBinding] {
        reconcileUDPListeners(bindings, exposure: exposure).listeners
    }

    /// Groups one transport's concrete bindings by the exact Mac endpoint Morbstack
    /// can actually bind. Foundation's dictionary iteration order must not choose a
    /// production target, so candidates and diagnostics use an explicit stable order.
    private static func reconcileListeners(
        _ bindings: [DockerPortBinding],
        including isEligible: (DockerPortBinding) -> Bool
    ) -> ListenerReconciliation {
        var candidatesByEndpoint: [DockerHostEndpoint: [DockerPortBinding]] = [:]
        for binding in bindings where isEligible(binding) {
            guard let endpoint = endpoint(for: binding) else { continue }
            candidatesByEndpoint[endpoint, default: []].append(binding)
        }

        var listeners: [DockerHostEndpoint: DockerPortBinding] = [:]
        var conflicts: [DockerHostEndpoint: ListenerConflict] = [:]
        for endpoint in candidatesByEndpoint.keys.sorted(by: stableEndpointOrder) {
            guard let unsortedCandidates = candidatesByEndpoint[endpoint] else { continue }
            let candidates = unsortedCandidates.sorted(by: stableBindingOrder)
            guard let first = candidates.first else { continue }

            // An Engine list entry without an ID cannot prove a duplicated record
            // shares a target with another entry. Withhold it instead of routing a
            // malformed answer by list order.
            let sameProvenTarget = !first.containerID.isEmpty && candidates.allSatisfy {
                $0.containerID == first.containerID && $0.containerPort == first.containerPort
            }
            guard sameProvenTarget else {
                conflicts[endpoint] = ListenerConflict(
                    endpoint: endpoint,
                    networkProtocol: first.networkProtocol,
                    bindings: candidates)
                continue
            }
            listeners[endpoint] = preferredBinding(candidates)
        }
        return ListenerReconciliation(listeners: listeners, conflicts: conflicts)
    }

    /// Chooses presentation metadata only after the target identity was proven equal.
    private static func preferredBinding(_ candidates: [DockerPortBinding]) -> DockerPortBinding {
        candidates.min { lhs, rhs in
            let lhsIsIPv6 = lhs.hostIP.contains(":")
            let rhsIsIPv6 = rhs.hostIP.contains(":")
            if lhsIsIPv6 != rhsIsIPv6 { return !lhsIsIPv6 }
            return stableBindingOrder(lhs, rhs)
        } ?? candidates[0]
    }

    private static func stableBindingOrder(_ lhs: DockerPortBinding, _ rhs: DockerPortBinding) -> Bool {
        if lhs.containerID != rhs.containerID { return lhs.containerID < rhs.containerID }
        if lhs.containerPort != rhs.containerPort { return lhs.containerPort < rhs.containerPort }
        if lhs.containerName != rhs.containerName { return lhs.containerName < rhs.containerName }
        if lhs.hostIP != rhs.hostIP { return lhs.hostIP < rhs.hostIP }
        if lhs.hostPort != rhs.hostPort { return lhs.hostPort < rhs.hostPort }
        return lhs.networkProtocol < rhs.networkProtocol
    }

    private static func stableEndpointOrder(_ lhs: DockerHostEndpoint, _ rhs: DockerHostEndpoint) -> Bool {
        if lhs.port != rhs.port { return lhs.port < rhs.port }
        if lhs.address.family != rhs.address.family { return lhs.address.family < rhs.address.family }
        return lhs.address.stringValue < rhs.address.stringValue
    }

    /// Computes the listener changes needed to go from `current` to `desired`.
    ///
    /// A host port whose *binding* changed — the container behind it was replaced —
    /// appears in both lists; callers must close before opening or the rebind fails
    /// with `EADDRINUSE` against themselves.
    public static func diff(
        current: [DockerHostEndpoint: DockerPortBinding],
        desired: [DockerHostEndpoint: DockerPortBinding]
    ) -> (close: [DockerHostEndpoint], open: [DockerPortBinding]) {
        var close: Set<DockerHostEndpoint> = []
        var open: [DockerPortBinding] = []

        for (port, binding) in desired where current[port] != binding {
            if current[port] != nil { close.insert(port) }
            open.append(binding)
        }
        for port in current.keys where desired[port] == nil {
            close.insert(port)
        }
        return (
            close.sorted(by: stableEndpointOrder),
            open.sorted {
                guard let lhs = endpoint(for: $0), let rhs = endpoint(for: $1) else {
                    return stableBindingOrder($0, $1)
                }
                return stableEndpointOrder(lhs, rhs)
            })
    }
}
