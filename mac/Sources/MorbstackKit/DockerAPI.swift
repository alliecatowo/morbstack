// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Foundation

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

    /// One host loopback endpoint Docker described with more than one target.
    ///
    /// A Mac listener has no Docker-level routing information after it accepts a
    /// connection: it can reach exactly one container port. `containers/json` will
    /// normally contain two records for one dual-stack publication, and those are
    /// safe to collapse only when they prove the same container identity and target
    /// port. Every other duplicate is withheld rather than letting the order of a
    /// daemon response decide which service receives local traffic.
    public struct ListenerConflict: Hashable, Sendable {
        /// The numeric Mac loopback endpoint that cannot be represented safely.
        public let hostPort: Int
        /// `tcp` or `udp`.
        public let networkProtocol: String
        /// Every Docker record that competed for this endpoint, in stable order.
        public let bindings: [DockerPortBinding]

        public init(hostPort: Int, networkProtocol: String, bindings: [DockerPortBinding]) {
            self.hostPort = hostPort
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
                + "local loopback port \(hostPort) (\(targets)); Morbstack is not forwarding this host port"
        }
    }

    /// The safe listener set plus Docker publications that cannot be represented by
    /// one Mac loopback listener.
    public struct ListenerReconciliation: Sendable {
        public let listeners: [Int: DockerPortBinding]
        public let conflicts: [Int: ListenerConflict]

        public init(
            listeners: [Int: DockerPortBinding],
            conflicts: [Int: ListenerConflict]
        ) {
            self.listeners = listeners
            self.conflicts = conflicts
        }
    }

    /// Host addresses whose bindings Morbstack mirrors onto the Mac's loopback.
    ///
    /// `0.0.0.0` and the empty string are "all interfaces"; `127.0.0.1` is explicitly
    /// loopback. `::` and `::1` are the IPv6 spellings Docker may return. A
    /// publication described only by one of them receives a local `[::1]` TCP
    /// listener; a same-port dual-family pair still collapses to one listener below.
    /// Anything else is a binding to a specific guest interface address, which does
    /// not correspond to anything on the Mac.
    public static let forwardableHostAddresses: Set<String> = ["", "0.0.0.0", "127.0.0.1", "::", "::1"]

    /// The datagram listener is still IPv4-only. Keep IPv6 out of this set rather
    /// than reporting a successful Docker UDP publication which only an IPv4 socket
    /// can receive. TCP's IPv6 loopback lease is intentionally separate.
    public static let forwardableUDPHostAddresses: Set<String> = ["", "0.0.0.0", "127.0.0.1"]

    /// Whether a binding should get a listener on the Mac.
    public static func isForwardable(_ binding: DockerPortBinding) -> Bool {
        binding.networkProtocol == "tcp"
            && forwardableHostAddresses.contains(binding.hostIP)
            && binding.hostPort > 0
            && binding.hostPort <= 65535
    }

    /// Whether an event-confirmed UDP publication can be represented by one Mac
    /// loopback datagram endpoint. This is intentionally separate from
    /// ``isForwardable(_:)`` because TCP and UDP may share one numeric host port.
    public static func isForwardableUDP(_ binding: DockerPortBinding) -> Bool {
        binding.networkProtocol == "udp"
            && forwardableUDPHostAddresses.contains(binding.hostIP)
            && binding.hostPort > 0
            && binding.hostPort <= 65535
    }

    /// Produces the complete TCP reconciliation result.
    ///
    /// Docker reports the same host port twice when it binds both `0.0.0.0` and `::`.
    /// Those records collapse only when they name the same nonempty container ID and
    /// container port, preferring IPv4 because the current lease ledger owns one
    /// local listener per numeric port. Different or unidentified targets are
    /// reported as conflicts and are deliberately absent from `listeners`.
    public static func reconcileTCPListeners(_ bindings: [DockerPortBinding]) -> ListenerReconciliation {
        reconcileListeners(bindings, including: isForwardable)
    }

    /// Reduces raw TCP bindings to one desired listener per host port.
    ///
    /// Compatibility convenience for callers that only need the safe listener set.
    /// New reconciliation callers should use ``reconcileTCPListeners(_:)`` so a
    /// withheld conflicting publication can be reported rather than disappearing.
    public static func desiredListeners(_ bindings: [DockerPortBinding]) -> [Int: DockerPortBinding] {
        reconcileTCPListeners(bindings).listeners
    }

    /// Produces the complete UDP reconciliation result.
    ///
    /// TCP and UDP have independent host-port spaces, but a UDP endpoint has the same
    /// single-target constraint within its own transport. See
    /// ``reconcileTCPListeners(_:)`` for the dual-stack and conflict policy.
    public static func reconcileUDPListeners(_ bindings: [DockerPortBinding]) -> ListenerReconciliation {
        reconcileListeners(bindings, including: isForwardableUDP)
    }

    /// Reduces event-confirmed UDP publications to one listener per UDP host port.
    ///
    /// Compatibility convenience for callers that only need safe listener entries.
    public static func desiredUDPListeners(_ bindings: [DockerPortBinding]) -> [Int: DockerPortBinding] {
        reconcileUDPListeners(bindings).listeners
    }

    /// Groups one transport's concrete bindings by the one Mac endpoint Morbstack
    /// can actually bind. Foundation's dictionary iteration order must not choose a
    /// production target, so candidates and diagnostics use an explicit stable order.
    private static func reconcileListeners(
        _ bindings: [DockerPortBinding],
        including isEligible: (DockerPortBinding) -> Bool
    ) -> ListenerReconciliation {
        var candidatesByPort: [Int: [DockerPortBinding]] = [:]
        for binding in bindings where isEligible(binding) {
            candidatesByPort[binding.hostPort, default: []].append(binding)
        }

        var listeners: [Int: DockerPortBinding] = [:]
        var conflicts: [Int: ListenerConflict] = [:]
        for port in candidatesByPort.keys.sorted() {
            guard let unsortedCandidates = candidatesByPort[port] else { continue }
            let candidates = unsortedCandidates.sorted(by: stableBindingOrder)
            guard let first = candidates.first else { continue }

            // An Engine list entry without an ID cannot prove a duplicated record
            // shares a target with another entry. Withhold it instead of routing a
            // malformed answer by list order.
            let sameProvenTarget = !first.containerID.isEmpty && candidates.allSatisfy {
                $0.containerID == first.containerID && $0.containerPort == first.containerPort
            }
            guard sameProvenTarget else {
                conflicts[port] = ListenerConflict(
                    hostPort: port,
                    networkProtocol: first.networkProtocol,
                    bindings: candidates)
                continue
            }
            listeners[port] = preferredBinding(candidates)
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

    /// Computes the listener changes needed to go from `current` to `desired`.
    ///
    /// A host port whose *binding* changed — the container behind it was replaced —
    /// appears in both lists; callers must close before opening or the rebind fails
    /// with `EADDRINUSE` against themselves.
    public static func diff(
        current: [Int: DockerPortBinding],
        desired: [Int: DockerPortBinding]
    ) -> (close: [Int], open: [DockerPortBinding]) {
        var close: Set<Int> = []
        var open: [DockerPortBinding] = []

        for (port, binding) in desired where current[port] != binding {
            if current[port] != nil { close.insert(port) }
            open.append(binding)
        }
        for port in current.keys where desired[port] == nil {
            close.insert(port)
        }
        return (close.sorted(), open.sorted { $0.hostPort < $1.hostPort })
    }
}
