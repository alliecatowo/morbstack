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

    /// Host addresses whose bindings Morbstack mirrors onto the Mac's loopback.
    ///
    /// `0.0.0.0` and the empty string are "all interfaces"; `127.0.0.1` is explicitly
    /// loopback. `::` and `::1` are the IPv6 halves Docker publishes alongside the
    /// IPv4 ones — accepted so that a container published *only* on IPv6 still gets a
    /// listener, and harmless otherwise because the map below is keyed by host port.
    /// Anything else is a binding to a specific guest interface address, which does
    /// not correspond to anything on the Mac.
    public static let forwardableHostAddresses: Set<String> = ["", "0.0.0.0", "127.0.0.1", "::", "::1"]

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
            && forwardableHostAddresses.contains(binding.hostIP)
            && binding.hostPort > 0
            && binding.hostPort <= 65535
    }

    /// Reduces raw bindings to one desired listener per host port.
    ///
    /// Docker reports the same host port twice when it binds both `0.0.0.0` and `::`;
    /// keying by host port collapses that, preferring the IPv4 entry so the recorded
    /// `hostIP` matches what the user typed.
    public static func desiredListeners(_ bindings: [DockerPortBinding]) -> [Int: DockerPortBinding] {
        var desired: [Int: DockerPortBinding] = [:]
        for binding in bindings where isForwardable(binding) {
            if let existing = desired[binding.hostPort] {
                let existingIsIPv6 = existing.hostIP.contains(":")
                let candidateIsIPv6 = binding.hostIP.contains(":")
                if existingIsIPv6 && !candidateIsIPv6 { desired[binding.hostPort] = binding }
            } else {
                desired[binding.hostPort] = binding
            }
        }
        return desired
    }

    /// Reduces event-confirmed UDP publications to one listener per UDP host port.
    ///
    /// Docker reports dual-stack bindings separately. Morbstack binds the safe IPv4
    /// loopback endpoint once, preferring Docker's IPv4 spelling for diagnostics just
    /// as the TCP plan does. If two different containers claim the same UDP endpoint,
    /// Docker owns the malformed state; this method never invents a winner beyond its
    /// stable first-seen/IPv4 preference.
    public static func desiredUDPListeners(_ bindings: [DockerPortBinding]) -> [Int: DockerPortBinding] {
        var desired: [Int: DockerPortBinding] = [:]
        for binding in bindings where isForwardableUDP(binding) {
            if let existing = desired[binding.hostPort] {
                let existingIsIPv6 = existing.hostIP.contains(":")
                let candidateIsIPv6 = binding.hostIP.contains(":")
                if existingIsIPv6 && !candidateIsIPv6 { desired[binding.hostPort] = binding }
            } else {
                desired[binding.hostPort] = binding
            }
        }
        return desired
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
