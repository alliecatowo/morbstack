// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The value types the whole app is written against.
//
// Two layers live here, deliberately kept apart:
//
//   * the **view model** types (`ContainerSummary`, `ImageSummary`, …) — small,
//     `Sendable`, already normalised, and the only thing the UI ever sees;
//   * the **wire** types (`Wire.Container`, `Wire.SystemDF`, …) — a faithful, boring
//     mirror of the Docker Engine API's JSON, with its capitalised keys and its
//     optionals-everywhere shape.
//
// The mapping between them is the one place that knows Docker's vocabulary. Views
// never decode JSON and never see a `nil` they have to interpret; when the engine
// adds a field or renames one, exactly one initialiser changes.

import Foundation

// MARK: - Navigation

/// The top-level sections of the app, in sidebar order.
///
/// `rawValue` doubles as the `--tour-select` argument, so it is part of the
/// screenshot tooling's contract and should not be renamed casually.
enum Nav: String, CaseIterable, Identifiable, Sendable {
    case containers
    case stacks
    case images
    case volumes
    case networks
    case builds
    case kubernetes
    case disk
    case migration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .containers: return "Containers"
        case .stacks: return "Stacks"
        case .images: return "Images"
        case .volumes: return "Volumes"
        case .networks: return "Networks"
        case .builds: return "Builds"
        case .kubernetes: return "Kubernetes"
        case .disk: return "Disk"
        case .migration: return "Migration"
        }
    }

    var symbol: String {
        switch self {
        case .containers: return "shippingbox"
        case .stacks: return "square.stack.3d.up"
        case .images: return "square.on.square"
        case .volumes: return "externaldrive"
        case .networks: return "network"
        case .builds: return "hammer"
        case .kubernetes: return "helm"
        case .disk: return "chart.pie"
        case .migration: return "arrow.left.arrow.right"
        }
    }

    /// The `⌘1`…`⌘9` accelerator for this section.
    var shortcutIndex: Int { (Nav.allCases.firstIndex(of: self) ?? 0) + 1 }
}

// MARK: - Actions

/// A lifecycle operation on a single container.
enum ContainerAction: String, Sendable, CaseIterable {
    case start, stop, restart, remove, pause, unpause

    /// Present-tense verb for buttons and menu items.
    var title: String {
        switch self {
        case .start: return "Start"
        case .stop: return "Stop"
        case .restart: return "Restart"
        case .remove: return "Remove"
        case .pause: return "Pause"
        case .unpause: return "Resume"
        }
    }

    var symbol: String {
        switch self {
        case .start: return "play.fill"
        case .stop: return "stop.fill"
        case .restart: return "arrow.clockwise"
        case .remove: return "trash"
        case .pause: return "pause.fill"
        case .unpause: return "play.fill"
        }
    }

    /// Whether the action destroys something the user cannot get back.
    var isDestructive: Bool { self == .remove }
}

/// The honest phases of the deliberately narrow "Run Local Image" operation.
///
/// The app creates exactly one container from an already-listed local image, then
/// starts it. It does not expose a general container-configuration surface.
enum LocalImageRunProgress: Sendable {
    case creating
    case starting

    var title: String {
        switch self {
        case .creating: return "Creating Container…"
        case .starting: return "Starting Container…"
        }
    }
}

/// The two transport protocols the local-image form can publish. This is deliberately
/// not Docker's open-ended protocol field: the host forwarder has a reviewed TCP/UDP
/// contract, while SCTP and arbitrary Engine create documents need their own work.
enum LocalImagePortTransport: String, CaseIterable, Equatable, Hashable, Sendable {
    case tcp
    case udp

    var displayName: String { rawValue.uppercased() }
}

/// The two explicit IPv4 exposure choices that the host-port preflight understands.
/// The form never relies on Docker's implicit all-interface default.
enum LocalImagePortExposure: String, CaseIterable, Equatable, Hashable, Sendable {
    case thisMac
    case allInterfaces

    var displayName: String {
        switch self {
        case .thisMac: return "This Mac only (127.0.0.1)"
        case .allInterfaces: return "All network interfaces (0.0.0.0)"
        }
    }

    var dockerHostIP: String {
        switch self {
        case .thisMac: return "127.0.0.1"
        case .allInterfaces: return "0.0.0.0"
        }
    }
}

/// One editable, explicit environment declaration in the local-image form. This is
/// only draft state; ``LocalImageRunRequest`` decides whether it becomes a Docker
/// `Env` entry. In particular, no host environment, file, keychain, or secret store
/// can populate this type.
struct LocalImageEnvironmentEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var value: String

    init(id: UUID = UUID(), name: String = "", value: String = "") {
        self.id = id
        self.name = name
        self.value = value
    }
}

/// One checked `NAME=value` declaration that will be sent to Docker. It cannot
/// represent host-environment inheritance because the value is always present,
/// including when it is the intentionally empty string.
struct LocalImageEnvironmentDeclaration: Equatable, Sendable {
    let name: String
    let value: String

    var engineValue: String { "\(name)=\(value)" }
}

/// One editable, fixed published-port declaration in the local-image form. Both
/// port numbers remain strings only while a person is typing; a successful request
/// contains checked integer values, never a raw Docker range or dynamic allocation.
struct LocalImagePortMappingEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    var hostPort: String
    var containerPort: String
    var transport: LocalImagePortTransport
    var exposure: LocalImagePortExposure

    init(
        id: UUID = UUID(),
        hostPort: String = "",
        containerPort: String = "",
        transport: LocalImagePortTransport = .tcp,
        exposure: LocalImagePortExposure = .thisMac
    ) {
        self.id = id
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.transport = transport
        self.exposure = exposure
    }
}

/// A checked, ordinary Docker port publication. The Engine request writes both
/// `ExposedPorts` and `HostConfig.PortBindings` for this value, matching Docker's
/// container-create schema rather than relying on client-only CLI syntax.
struct LocalImagePublishedPort: Equatable, Sendable {
    let hostPort: Int
    let containerPort: Int
    let transport: LocalImagePortTransport
    let exposure: LocalImagePortExposure

    var containerPortKey: String { "\(containerPort)/\(transport.rawValue)" }
    var hostIP: String { exposure.dockerHostIP }
}

/// A correctable validation problem in the small typed local-image form. Docker
/// remains the authority for container names, image state, port availability, and
/// every Engine-side create/start error; these cases only prevent an incomplete form
/// row from being silently omitted or turned into a different request.
enum LocalImageRunValidation: LocalizedError, Equatable, Sendable {
    case environmentNameRequired(entry: Int)
    case environmentNameContainsEquals(entry: Int)
    case duplicateEnvironmentName(String)
    case portMappingIncomplete(entry: Int)
    case invalidHostPort(entry: Int)
    case invalidContainerPort(entry: Int)

    var errorDescription: String? {
        switch self {
        case .environmentNameRequired(let entry):
            return "Environment variable \(entry) needs a name."
        case .environmentNameContainsEquals(let entry):
            return "Environment variable \(entry)'s name cannot contain =."
        case .duplicateEnvironmentName(let name):
            return "Environment variable \(name) appears more than once."
        case .portMappingIncomplete(let entry):
            return "Published port \(entry) needs both a host port and a container port."
        case .invalidHostPort(let entry):
            return "Published port \(entry)'s host port must be a number from 1 through 65535."
        case .invalidContainerPort(let entry):
            return "Published port \(entry)'s container port must be a number from 1 through 65535."
        }
    }
}

/// The complete, intentionally small create contract for the Images route. It has no
/// generic dictionary or escape hatch: a request is an optional container name,
/// literal `NAME=value` environment declarations, and fixed TCP/UDP publications.
///
/// A new UI field must be modeled here, reviewed against the Docker Engine schema,
/// and sent explicitly by ``DockerClient``. That keeps unreviewed Docker fields from
/// becoming invisible defaults in an otherwise safe form.
struct LocalImageRunRequest: Equatable, Sendable {
    let requestedName: String?
    let environment: [LocalImageEnvironmentDeclaration]
    let publishedPorts: [LocalImagePublishedPort]

    static func make(
        requestedName: String,
        environment entries: [LocalImageEnvironmentEntry],
        publishedPorts portEntries: [LocalImagePortMappingEntry]
    ) -> Result<LocalImageRunRequest, LocalImageRunValidation> {
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        var environment: [LocalImageEnvironmentDeclaration] = []
        var environmentNames: Set<String> = []

        for (offset, entry) in entries.enumerated() {
            let trimmedName = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedName.isEmpty {
                // An untouched Add row does not declare anything. A value without a
                // name would be ambiguous, so it is a correctable form error.
                guard entry.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .failure(.environmentNameRequired(entry: offset + 1))
                }
                continue
            }
            guard !trimmedName.contains("=") else {
                return .failure(.environmentNameContainsEquals(entry: offset + 1))
            }
            guard environmentNames.insert(trimmedName).inserted else {
                return .failure(.duplicateEnvironmentName(trimmedName))
            }
            environment.append(LocalImageEnvironmentDeclaration(name: trimmedName, value: entry.value))
        }

        var publishedPorts: [LocalImagePublishedPort] = []
        for (offset, entry) in portEntries.enumerated() {
            let rawHostPort = entry.hostPort.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawContainerPort = entry.containerPort.trimmingCharacters(in: .whitespacesAndNewlines)
            if rawHostPort.isEmpty && rawContainerPort.isEmpty {
                // Like a blank environment row, a blank port row makes no request.
                continue
            }
            guard !rawHostPort.isEmpty, !rawContainerPort.isEmpty else {
                return .failure(.portMappingIncomplete(entry: offset + 1))
            }
            guard let hostPort = Int(rawHostPort), (1...65_535).contains(hostPort) else {
                return .failure(.invalidHostPort(entry: offset + 1))
            }
            guard let containerPort = Int(rawContainerPort), (1...65_535).contains(containerPort) else {
                return .failure(.invalidContainerPort(entry: offset + 1))
            }
            publishedPorts.append(
                LocalImagePublishedPort(
                    hostPort: hostPort,
                    containerPort: containerPort,
                    transport: entry.transport,
                    exposure: entry.exposure))
        }

        return .success(
            LocalImageRunRequest(
                requestedName: name.isEmpty ? nil : name,
                environment: environment,
                publishedPorts: publishedPorts))
    }
}

/// The Engine identity of one container created and started by the local-image flow.
struct LocalImageRunResult: Sendable, Equatable {
    let containerID: String
    /// A requested name, not an asserted final Engine name. Docker remains the
    /// authority for validating and assigning it.
    let requestedName: String?
}

/// A result that preserves whether Docker confirmed the bounded create/start request.
enum LocalImageRunError: LocalizedError {
    case imageIsNoLongerLocal
    case createOutcomeUnknown(message: String)
    case startNotConfirmed(containerID: String, message: String)

    var errorDescription: String? {
        switch self {
        case .imageIsNoLongerLocal:
            return "The selected image is no longer available locally. Refresh Images and choose it again."
        case .createOutcomeUnknown(let message):
            return "Morbstack could not confirm whether Docker created the container: \(message). A new container may exist; inspect Containers before retrying."
        case .startNotConfirmed(let containerID, let message):
            return "Docker did not confirm this start request for \(containerID): \(message). The container was left in place; inspect it in Containers before retrying."
        }
    }
}

/// A lifecycle operation on the engine VM itself.
enum EngineAction: String, Sendable {
    case start, stop, suspend
}

// MARK: - Engine

/// A snapshot of what `morbstackd` says about itself.
struct EngineStatus: Sendable, Equatable {

    /// The daemon's own state token: `stopped`, `starting`, `running`, `suspended`, …
    var state: String
    /// The human-readable VM state, for the status pill's tooltip.
    var vmState: String
    /// Daemon version, when it answered.
    var version: String?
    /// Whether the control socket answered at all.
    var reachable: Bool

    static let unknown = EngineStatus(state: "stopped", vmState: "not running", version: nil, reachable: false)

    /// `true` when containers can actually be listed.
    var isRunning: Bool { reachable && state == "running" }

    /// `true` while the VM is moving between states on its own.
    var isTransitional: Bool {
        reachable && (state == "starting" || state == "stopping" || state == "pausing")
    }

    /// One short phrase for the sidebar pill.
    var headline: String {
        guard reachable else { return "Engine stopped" }
        switch state {
        case "running": return "Engine running"
        case "starting": return "Starting…"
        case "stopping": return "Stopping…"
        case "pausing": return "Suspending…"
        case "suspended": return "Suspended"
        case "error": return "Engine error"
        default: return state.capitalized
        }
    }
}

// MARK: - Ports

/// One published port, as the UI needs it.
struct PortMapping: Hashable, Sendable, Identifiable {

    /// Host interface the port is bound on; `nil` for an unpublished port.
    var hostIP: String?
    /// Host-side port; `nil` when the container port is exposed but not published.
    var hostPort: Int?
    /// The port inside the container.
    var containerPort: Int
    /// `tcp` or `udp`.
    var proto: String

    var id: String { "\(hostIP ?? "")|\(hostPort.map(String.init) ?? "")|\(containerPort)|\(proto)" }

    /// The URL that opens this port in a browser, when there is one to open.
    ///
    /// Always loopback rather than the reported `hostIP`: Morbstack forwards published
    /// ports onto the Mac's loopback, and a binding reported as `0.0.0.0` is reachable
    /// at `127.0.0.1` — which is both true and the address a user actually wants
    /// clicked. UDP has no browser story, so it gets no link.
    var url: URL? {
        guard let hostPort, proto.lowercased() == "tcp" else { return nil }
        return URL(string: "http://127.0.0.1:\(hostPort)")
    }

    /// A browser address only when Docker reported one literal loopback TCP binding.
    ///
    /// `url` predates the selected-container address actions and reflects
    /// Morbstack's forwarding assumption. Those actions are intentionally stricter:
    /// they must not turn a wildcard/LAN, host-network, UDP, incomplete, or malformed
    /// Docker mapping into a plausible browser destination. The URL is derived from
    /// the exact reported loopback host and port, using HTTP as the explicit browser
    /// scheme; it is an address to try, not a health or protocol probe.
    var browserAddress: URL? {
        guard let hostIP = browserAddressHost,
              let hostPort,
              (1...65_535).contains(hostPort),
              proto.caseInsensitiveCompare("tcp") == .orderedSame
        else { return nil }

        var components = URLComponents()
        components.scheme = "http"
        components.host = hostIP
        components.port = hostPort
        return components.url
    }

    /// The factual reason selected-container browser actions are unavailable.
    /// This is deliberately not a service diagnosis: it describes only the mapping
    /// Docker reported, and never attempts a connection.
    var browserAddressUnavailableReason: String? {
        guard browserAddress == nil else { return nil }
        guard hostPort != nil else { return "No host port was reported." }
        guard (1...65_535).contains(hostPort ?? 0) else {
            return "Docker reported an invalid host port."
        }
        guard proto.caseInsensitiveCompare("tcp") == .orderedSame else {
            return "Browser actions require a TCP mapping."
        }
        guard let hostIP else { return "Docker did not report a concrete host address." }
        return "Browser actions require a literal loopback binding; Docker reported \(hostIP)."
    }

    private var browserAddressHost: String? {
        switch hostIP {
        case "127.0.0.1", "::1": hostIP
        default: nil
        }
    }

    /// `8080 → 80/tcp`, or `80/tcp` when unpublished.
    var label: String {
        if let hostPort {
            return "\(Formatters.identifier(hostPort)) → \(Formatters.identifier(containerPort))/\(proto)"
        }
        return "\(Formatters.identifier(containerPort))/\(proto)"
    }

    /// `80/TCP`. This is a `String`, rather than a `LocalizedStringKey`, because a
    /// port is an identifier and must never acquire locale grouping.
    var containerDisplay: String {
        "\(Formatters.identifier(containerPort))/\(proto.uppercased())"
    }

    /// `0.0.0.0:18099`, or `nil` when unpublished.
    ///
    /// Deliberately `String`-typed. Handing the interpolation to SwiftUI's `Text`
    /// lets it resolve as a `LocalizedStringKey`, whose `Int` interpolation applies
    /// locale grouping — which is how a port once rendered as `18,099`. A port is an
    /// identifier, not a quantity; it is never grouped.
    var hostDisplay: String? {
        hostPort.map { "\(hostIP ?? "0.0.0.0"):\(Formatters.identifier($0))" }
    }
}

// MARK: - Containers

/// One row in the containers list.
struct ContainerSummary: Identifiable, Sendable, Hashable {

    var id: String
    /// Every name Docker knows this container by, leading slashes stripped.
    var names: [String]
    /// The name to show. Falls back to a short id for an unnamed container.
    var displayName: String
    var image: String
    /// `running`, `exited`, `paused`, `restarting`, `created`, `dead`.
    var state: String
    /// The engine's own prose, e.g. `Up 4 minutes (healthy)`.
    var status: String
    var composeProject: String?
    var composeService: String?
    var ports: [PortMapping]
    var createdAt: Date
    /// Exact Docker `State.StartedAt`, obtained from the inspect response when the
    /// container is running. `nil` means the app has not received that fact and must
    /// retain Docker's original status prose instead of estimating a start time.
    var startedAt: Date? = nil
    /// Named volumes listed by Docker as mounts on this container. This is a compact
    /// relationship index for the Volumes inspector, not a substitute for the
    /// container's full inspect document.
    var volumeNames: [String] = []

    var isRunning: Bool { state == "running" }

    /// The first 12 hex characters, the way every Docker tool shows an id.
    var shortID: String { String(id.prefix(12)) }

    /// `true` when the engine's status string reports a failing health check.
    ///
    /// Health lives in the status prose rather than in a field on the list endpoint,
    /// so this is a substring test — but it is the same substring the CLI prints.
    var isUnhealthy: Bool { status.localizedCaseInsensitiveContains("(unhealthy)") }

    /// The list's locally ticking status, when Docker has supplied an actual start
    /// instant. This never parses or extrapolates the human-oriented `/containers/json`
    /// `Status` string: when `StartedAt` is absent, the engine's text remains the only
    /// truthful answer.
    func statusDisplay(at now: Date = .now) -> String {
        let fallback = status.isEmpty ? state.capitalized : status
        guard isRunning,
              let startedAt,
              startedAt.timeIntervalSince1970 > 0
        else { return fallback }

        return "Up \(Formatters.uptime(since: startedAt, now: now))\(statusQualifier)"
    }

    /// Docker's list endpoint exposes health as a suffix inside `Status`, while the
    /// exact start instant comes from inspect. Preserve that engine-authored qualifier
    /// when replacing only the elapsed-time portion.
    private var statusQualifier: String {
        guard let range = status.range(of: " (", options: .backwards) else { return "" }
        return String(status[range.lowerBound...])
    }

    /// Which actions make sense right now.
    var availableActions: [ContainerAction] {
        switch state {
        case "running": return [.stop, .restart, .pause]
        case "paused": return [.unpause, .stop]
        case "restarting": return [.stop]
        // Docker documents `dead` as a defunct container that cannot be started
        // again.  Treating it like an ordinary stopped container makes a recovery
        // action fail after it has already changed other services in the stack.
        case "dead": return [.remove]
        case "created", "exited": return [.start, .remove]
        // `removing` and an unrecognised daemon state are not safe guesses.  A
        // refresh can turn either into a known state; an invented action cannot.
        default: return []
        }
    }
}

// MARK: - Images, volumes, networks

struct ImageSummary: Identifiable, Sendable, Hashable {

    var id: String
    /// `["nginx:latest"]`; empty or `<none>:<none>` for a dangling layer.
    var repoTags: [String]
    var size: Int64
    var createdAt: Date
    /// How many containers reference this image (`-1` when the engine did not say).
    var containersUsing: Int

    /// The platform the image was built for, when it is known.
    ///
    /// `nil` means "not fetched yet", never "native". `GET /images/json` only carries a
    /// platform for images that came from a multi-arch index, so the rest stay `nil`
    /// until the Images screen inspects them — see `ImagesRootView.resolveArchitecture`.
    /// Rendering `nil` as anything other than blank would put a confident answer where
    /// the honest one is silence.
    var architecture: ImageArchitecture?

    var shortID: String {
        let stripped = id.hasPrefix("sha256:") ? String(id.dropFirst(7)) : id
        return String(stripped.prefix(12))
    }

    /// `true` for an untagged leftover layer.
    var isDangling: Bool {
        repoTags.isEmpty || repoTags.allSatisfy { $0 == "<none>:<none>" || $0.isEmpty }
    }

    /// `nginx` from `nginx:latest`.
    var repository: String {
        guard let first = repoTags.first, !isDangling else { return "<none>" }
        guard let colon = first.lastIndex(of: ":") else { return first }
        // A registry host may carry a port — `host:5000/img` has a colon before the
        // last slash, and that colon is not a tag separator.
        let afterColon = first[first.index(after: colon)...]
        return afterColon.contains("/") ? first : String(first[first.startIndex..<colon])
    }

    var tag: String {
        guard let first = repoTags.first, !isDangling else { return "<none>" }
        guard let colon = first.lastIndex(of: ":") else { return "latest" }
        let afterColon = String(first[first.index(after: colon)...])
        return afterColon.contains("/") ? "latest" : afterColon
    }
}

struct VolumeSummary: Identifiable, Sendable, Hashable {

    /// The volume name, which is also its identity in the Docker API.
    var name: String
    var driver: String
    var mountpoint: String
    /// Bytes on disk; `nil` unless usage data was requested.
    var size: Int64?
    /// Containers holding a reference; `nil` when unknown.
    var refCount: Int?
    /// Docker-managed labels reported by the volume list endpoint. An empty map means
    /// no labels were reported, not that labels were intentionally hidden.
    var labels: [String: String] = [:]

    var id: String { name }

    /// Docker omits `UsageData.RefCount` when usage was not requested or could not be
    /// reported. That is not evidence that a volume is unused, and it must never make
    /// the volume eligible for a bulk destructive operation.
    var isUnused: Bool { refCount == 0 }

    var usageStatus: String {
        guard let refCount else { return "Usage unreported" }
        return refCount == 0 ? "Unused" : "In use"
    }
}

struct NetworkSummary: Identifiable, Sendable, Hashable {
    var id: String
    var name: String
    var driver: String
    var scope: String
    var containers: Int

    /// Docker's three built-ins, which cannot be removed.
    var isBuiltIn: Bool { ["bridge", "host", "none"].contains(name) }
}

/// The selected network's complete inspect document, normalized into facts that can be
/// shown in a native inspector. This stays separate from ``NetworkSummary`` so the
/// inventory does not issue an expensive inspection for every row merely to fill a
/// detail column that may never be opened.
struct NetworkInspection: Identifiable, Sendable, Hashable {

    struct KeyValue: Identifiable, Sendable, Hashable {
        let key: String
        let value: String

        var id: String { key }
    }

    struct IPAMConfiguration: Identifiable, Sendable, Hashable {
        let subnet: String?
        let gateway: String?
        let ipRange: String?
        let auxiliaryAddresses: [KeyValue]

        var id: String {
            [subnet, gateway, ipRange].compactMap { $0 }.joined(separator: "|")
        }
    }

    struct Member: Identifiable, Sendable, Hashable {
        let id: String
        let name: String
        let endpointID: String?
        let macAddress: String?
        let ipv4Address: String?
        let ipv6Address: String?
        /// Docker does not normally include aliases in a network inspection, but keep
        /// an explicitly returned field instead of inventing aliases from a container
        /// name when an Engine implementation does supply one.
        let aliases: [String]
    }

    let id: String
    let name: String
    let driver: String
    let scope: String
    let enableIPv6: Bool?
    let isInternal: Bool?
    let isAttachable: Bool?
    let isIngress: Bool?
    let isConfigOnly: Bool?
    let configFrom: String?
    let ipamDriver: String?
    let ipamConfigurations: [IPAMConfiguration]
    let options: [KeyValue]
    let labels: [KeyValue]
    let members: [Member]

    init(
        id: String,
        name: String,
        driver: String,
        scope: String,
        enableIPv6: Bool?,
        isInternal: Bool?,
        isAttachable: Bool?,
        isIngress: Bool?,
        isConfigOnly: Bool?,
        configFrom: String?,
        ipamDriver: String?,
        ipamConfigurations: [IPAMConfiguration],
        options: [KeyValue],
        labels: [KeyValue],
        members: [Member]
    ) {
        self.id = id
        self.name = name
        self.driver = driver
        self.scope = scope
        self.enableIPv6 = enableIPv6
        self.isInternal = isInternal
        self.isAttachable = isAttachable
        self.isIngress = isIngress
        self.isConfigOnly = isConfigOnly
        self.configFrom = configFrom
        self.ipamDriver = ipamDriver
        self.ipamConfigurations = ipamConfigurations
        self.options = options
        self.labels = labels
        self.members = members
    }

    init(_ wire: Wire.Network) {
        id = wire.Id
        name = wire.Name
        driver = wire.Driver ?? "bridge"
        scope = wire.Scope ?? "local"
        enableIPv6 = wire.EnableIPv6
        isInternal = wire.Internal
        isAttachable = wire.Attachable
        isIngress = wire.Ingress
        isConfigOnly = wire.ConfigOnly
        configFrom = wire.ConfigFrom?.Network.flatMap { $0.isEmpty ? nil : $0 }
        ipamDriver = wire.IPAM?.Driver.flatMap { $0.isEmpty ? nil : $0 }
        ipamConfigurations = (wire.IPAM?.Config ?? []).map(IPAMConfiguration.init)
        options = Self.keyValues(wire.Options)
        labels = Self.keyValues(wire.Labels)
        members = (wire.Containers ?? [:])
            .map { id, member in Member(id: id, member) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func keyValues(_ values: [String: String]?) -> [KeyValue] {
        (values ?? [:])
            .map { KeyValue(key: $0.key, value: $0.value) }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }
}

extension NetworkInspection.IPAMConfiguration {
    init(_ wire: Wire.Network.IPAM.Configuration) {
        subnet = wire.Subnet.flatMap { $0.isEmpty ? nil : $0 }
        gateway = wire.Gateway.flatMap { $0.isEmpty ? nil : $0 }
        ipRange = wire.IPRange.flatMap { $0.isEmpty ? nil : $0 }
        auxiliaryAddresses = (wire.AuxAddress ?? [:])
            .map { NetworkInspection.KeyValue(key: $0.key, value: $0.value) }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }
}

extension NetworkInspection.Member {
    init(id: String, _ wire: Wire.Network.Container) {
        self.id = id
        name = wire.Name?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .flatMap { $0.isEmpty ? nil : $0 } ?? String(id.prefix(12))
        endpointID = wire.EndpointID.flatMap { $0.isEmpty ? nil : $0 }
        macAddress = wire.MacAddress.flatMap { $0.isEmpty ? nil : $0 }
        ipv4Address = wire.IPv4Address.flatMap { $0.isEmpty ? nil : $0 }
        ipv6Address = wire.IPv6Address.flatMap { $0.isEmpty ? nil : $0 }
        aliases = (wire.Aliases ?? []).filter { !$0.isEmpty }.sorted()
    }
}

// MARK: - Disk

/// `docker system df`, folded into the six numbers the Disk screen shows.
struct DiskUsage: Sendable, Equatable {
    var layersSize: Int64
    var imagesTotal: Int64
    var volumesTotal: Int64
    var buildCacheTotal: Int64
    var containersTotal: Int64
    var reclaimable: Int64

    static let zero = DiskUsage(
        layersSize: 0, imagesTotal: 0, volumesTotal: 0,
        buildCacheTotal: 0, containersTotal: 0, reclaimable: 0)

    var total: Int64 { imagesTotal + volumesTotal + buildCacheTotal + containersTotal }
}

// MARK: - Build cache

/// One record from `/system/df`'s `BuildCache` array — a single BuildKit cache layer.
///
/// This is the closest thing the engine exposes to build history: the classic Docker
/// build cache has no notion of "a build," only a graph of cache records shared across
/// every build that ever ran, so `Description` (a snippet of the instruction that
/// produced it, e.g. `RUN pip install -r requirements.txt`) is the closest thing to a
/// name any record has. There is no per-record delete in the Docker Engine API — only
/// `POST /build/prune`, which removes every unused record at once — so the Builds
/// screen can inspect these but can only prune all of them together.
struct BuildCacheRecord: Identifiable, Sendable, Equatable {
    var id: String
    var description: String
    var type: String
    var size: Int64
    var inUse: Bool
    var shared: Bool
    var createdAt: Date
    var lastUsedAt: Date?
    var usageCount: Int

    var shortID: String { String(id.prefix(12)) }
}

// MARK: - Buildx history

/// One completed-build record reported by `docker buildx history ls --format=json`.
///
/// Buildx owns these records, and scopes them to its active builder. They are
/// deliberately not derived from `/system/df`: a BuildKit cache layer can be shared by
/// many builds, while a history record identifies one completed build.
struct BuildxHistoryRecord: Identifiable, Sendable, Equatable, Hashable {
    var id: String
    var name: String
    var status: String
    var createdAt: Date?
    /// Docker formats this value (for example `1.4s`). Keeping the CLI's display value
    /// avoids pretending every Buildx version uses the same duration representation.
    var duration: String?
}

/// Loading state for the independent, read-only Buildx history collection.
enum BuildxHistoryLoadState: Equatable {
    case idle
    case loading
    case loaded
    case unavailable(String)
}

/// The current Buildx builder as reported by `docker buildx inspect`.
///
/// History records are scoped to this builder, but the Docker Engine API cannot
/// identify it. Keeping the builder's own reported node status separate from history
/// means the Builds route never tries to infer a healthy builder from a nonempty
/// cache or a previously completed build.
struct BuildxCurrentBuilder: Sendable, Equatable {
    struct Node: Sendable, Equatable, Identifiable {
        var name: String
        var endpoint: String?
        var status: String?
        var buildKitVersion: String?
        var platforms: String?
        var error: String?

        var id: String { name }

        /// Fields observed for this exact node, in Buildx's own vocabulary. Missing
        /// fields remain absent; the inspector does not infer that a node is healthy.
        var reportedFacts: String? {
            let values = [status, buildKitVersion, platforms, error].compactMap { $0 }
            return values.isEmpty ? nil : values.joined(separator: " · ")
        }
    }

    var name: String
    var driver: String?
    var lastActivity: String?
    var nodes: [Node]

    /// The status tokens that Buildx reported for the builder's nodes. This remains
    /// deliberately literal: the UI does not convert a missing or mixed node status
    /// into an invented overall health claim.
    var reportedNodeStatus: String? {
        let statuses = orderedUnique(nodes.compactMap(\.status))
        return statuses.isEmpty ? nil : statuses.joined(separator: ", ")
    }

    var reportedBuildKitVersions: String? {
        let versions = orderedUnique(nodes.compactMap(\.buildKitVersion))
        return versions.isEmpty ? nil : versions.joined(separator: ", ")
    }

    var reportedPlatforms: String? {
        let platforms = orderedUnique(nodes.compactMap(\.platforms))
        return platforms.isEmpty ? nil : platforms.joined(separator: ", ")
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}

/// Loading state for the independent current-builder read. A history list can still
/// succeed when an older Buildx cannot report builder inspection details, so this must
/// not be folded into `BuildxHistoryLoadState`.
enum BuildxCurrentBuilderLoadState: Equatable {
    case idle
    case loading
    case loaded
    case unavailable(String)
}

// MARK: - Logs and stats

/// Which pipe a log line came out of.
enum StdStream: Sendable, Hashable {
    case stdout
    case stderr
}

/// One line of container output.
///
/// `id` is a per-stream sequence number, not anything from Docker: log lines are not
/// unique by content and `List` needs stable identity for smooth appends.
struct LogLine: Identifiable, Sendable, Hashable {
    var id: Int
    var text: String
    var stream: StdStream
    var timestamp: Date?
}

/// One sample from the stats stream.
struct StatsSample: Sendable, Hashable {
    var cpuPercent: Double
    var memBytes: Int64
    var memLimit: Int64
    /// Cumulative bytes received across all interfaces the engine reports. `nil` means
    /// the stats response did not contain a complete receive counter, not zero traffic.
    var networkReceivedBytes: Int64? = nil
    /// Cumulative bytes sent across all interfaces the engine reports. `nil` means the
    /// stats response did not contain a complete transmit counter, not zero traffic.
    var networkTransmittedBytes: Int64? = nil
    var ts: Date

    static let empty = StatsSample(cpuPercent: 0, memBytes: 0, memLimit: 0, ts: .distantPast)

    /// Memory as a fraction of the container's limit, clamped to `0...1`.
    var memFraction: Double {
        guard memLimit > 0 else { return 0 }
        return min(1, max(0, Double(memBytes) / Double(memLimit)))
    }

    /// Derives interval throughput from Docker's cumulative interface counters.
    ///
    /// A counter that goes backwards is a reset, not a negative transfer. Omitting that
    /// interval preserves the distinction between an unavailable reading and no traffic.
    static func networkRates(in samples: [StatsSample]) -> [NetworkRateSample] {
        guard samples.count > 1 else { return [] }

        return zip(samples, samples.dropFirst()).enumerated().compactMap { offset, pair in
            let previous = pair.0
            let current = pair.1
            let elapsed = current.ts.timeIntervalSince(previous.ts)
            guard elapsed > 0 else { return nil }

            func rate(from oldCounter: Int64?, to newCounter: Int64?) -> Double? {
                guard let oldCounter, let newCounter,
                      oldCounter >= 0, newCounter >= oldCounter
                else { return nil }
                let value = Double(newCounter - oldCounter) / elapsed
                return value.isFinite && value >= 0 ? value : nil
            }

            let received = rate(from: previous.networkReceivedBytes, to: current.networkReceivedBytes)
            let transmitted = rate(from: previous.networkTransmittedBytes, to: current.networkTransmittedBytes)
            guard received != nil || transmitted != nil else { return nil }

            return NetworkRateSample(
                sequence: offset + 1,
                timestamp: current.ts,
                receivedBytesPerSecond: received,
                transmittedBytesPerSecond: transmitted)
        }
    }
}

/// One rate interval truthfully derived from two Docker stats documents.
///
/// Docker reports cumulative bytes per interface, rather than throughput. This model is
/// deliberately optional per direction so a missing/reset counter never becomes a
/// plausible-looking zero in the inspector chart or its textual table.
struct NetworkRateSample: Identifiable, Sendable, Hashable {
    let sequence: Int
    let timestamp: Date
    let receivedBytesPerSecond: Double?
    let transmittedBytesPerSecond: Double?

    var id: Int { sequence }
}

// MARK: - Events

/// One line off `/events`.
struct DockerEvent: Sendable, Hashable {
    var type: String
    var action: String
    var actorID: String
    var attributes: [String: String]
    var time: Date

    /// `true` for the container transitions that change a row's state dot.
    var isContainerLifecycle: Bool {
        guard type == "container" else { return false }
        return [
            "create", "start", "stop", "die", "kill", "destroy",
            "pause", "unpause", "restart", "rename", "health_status",
        ].contains(where: { action == $0 || action.hasPrefix($0 + ":") })
    }
}

// MARK: - Wire types

/// Codable mirrors of the Docker Engine API payloads.
///
/// Namespaced so the names can stay close to the JSON without colliding with the view
/// model types above, and so it is obvious at a glance which layer a type belongs to.
enum Wire {

    /// Docker spells this field `Type`, which Swift will not accept as a member name —
    /// it would shadow the `foo.Type` metatype expression. Hence the `CodingKeys` here
    /// and on ``Event``: the wire name is preserved exactly, the Swift name is not.
    struct Port: Codable, Sendable {
        var IP: String?
        var PrivatePort: Int
        var PublicPort: Int?
        var proto: String?

        enum CodingKeys: String, CodingKey {
            case IP, PrivatePort, PublicPort
            case proto = "Type"
        }
    }

    struct Container: Codable, Sendable {
        var Id: String
        var Names: [String]?
        var Image: String?
        var ImageID: String?
        var State: String?
        var Status: String?
        var Created: Double?
        var Ports: [Port]?
        var Labels: [String: String]?
        var Mounts: [ContainerMount]?
    }

    /// The small mount projection the container list endpoint includes. The complete
    /// mount contract stays in `TrackBInspectDetails`; this just lets Volumes name the
    /// containers currently known to mount a selected named volume.
    struct ContainerMount: Codable, Sendable {
        var Name: String?
        var type: String?

        enum CodingKeys: String, CodingKey {
            case Name
            case type = "Type"
        }
    }

    /// An OCI platform block, as it appears inside `Descriptor` and at the top level of
    /// an image inspect document.
    struct Platform: Codable, Sendable {
        var architecture: String?
        var os: String?
        var variant: String?
    }

    struct Image: Codable, Sendable {
        var Id: String
        var RepoTags: [String]?
        var Size: Int64?
        var Created: Double?
        var Containers: Int?

        /// The OCI descriptor the image was pulled by.
        ///
        /// Present from API 1.45 and populated for anything fetched from a multi-arch
        /// index, which is most images from Docker Hub. Absent for locally built images
        /// and for single-manifest repositories — hence the lazy inspect fallback.
        var Descriptor: Descriptor?

        struct Descriptor: Codable, Sendable {
            var platform: Platform?
        }
    }

    /// The slice of `GET /images/{id}/json` the architecture badge needs.
    ///
    /// A separate type from ``Image`` because the inspect document spells the same facts
    /// differently: top-level `Architecture`/`Os`/`Variant` rather than a nested
    /// lowercase descriptor.
    struct ImageInspect: Codable, Sendable {
        var Architecture: String?
        var Os: String?
        var Variant: String?
    }

    struct VolumeUsage: Codable, Sendable {
        var Size: Int64?
        var RefCount: Int?
    }

    struct Volume: Codable, Sendable {
        var Name: String
        var Driver: String?
        var Mountpoint: String?
        var Labels: [String: String]?
        var UsageData: VolumeUsage?
    }

    struct VolumeList: Codable, Sendable {
        var Volumes: [Volume]?
    }

    struct Network: Codable, Sendable {
        var Id: String
        var Name: String
        var Driver: String?
        var Scope: String?
        var EnableIPv6: Bool?
        var Internal: Bool?
        var Attachable: Bool?
        var Ingress: Bool?
        var ConfigOnly: Bool?
        var ConfigFrom: ConfigFrom?
        var IPAM: IPAM?
        var Options: [String: String]?
        var Labels: [String: String]?
        var Containers: [String: Container]?

        struct ConfigFrom: Codable, Sendable {
            var Network: String?
        }

        struct IPAM: Codable, Sendable {
            var Driver: String?
            var Config: [Configuration]?

            struct Configuration: Codable, Sendable {
                var Subnet: String?
                var Gateway: String?
                var IPRange: String?
                var AuxAddress: [String: String]?
            }
        }

        struct Container: Codable, Sendable {
            var Name: String?
            var EndpointID: String?
            var MacAddress: String?
            var IPv4Address: String?
            var IPv6Address: String?
            var Aliases: [String]?
        }
    }

    struct BuildCacheRecord: Codable, Sendable {
        var Size: Int64?
        var InUse: Bool?
        var Shared: Bool?
    }

    struct SystemDF: Codable, Sendable {
        var LayersSize: Int64?
        var Images: [Image]?
        var Containers: [Container]?
        var Volumes: [Volume]?
        var BuildCache: [BuildCacheRecord]?

        /// `SizeRw` is only present on `/system/df`, not on `/containers/json`, so it
        /// rides along here instead of on `Wire.Container`.
        struct ContainerSize: Codable, Sendable {
            var SizeRw: Int64?
            var State: String?
        }
        var containerSizes: [ContainerSize]?
    }

    struct EventActor: Codable, Sendable {
        var ID: String?
        var Attributes: [String: String]?
    }

    struct Event: Codable, Sendable {
        var eventType: String?
        var Action: String?
        var Actor: EventActor?
        var time: Double?
        var timeNano: Double?
        // Pre-1.22 shape, still emitted by some proxies.
        var status: String?
        var id: String?
        var from: String?

        enum CodingKeys: String, CodingKey {
            case eventType = "Type"
            case Action, Actor, time, timeNano, status, id, from
        }
    }

    struct CPUUsage: Codable, Sendable {
        var total_usage: Double?
        var percpu_usage: [Double]?
    }

    struct CPUStats: Codable, Sendable {
        var cpu_usage: CPUUsage?
        var system_cpu_usage: Double?
        var online_cpus: Int?
    }

    struct MemoryStats: Codable, Sendable {
        var usage: Int64?
        var limit: Int64?
        var stats: [String: Double]?
    }

    /// One interface entry from `/containers/{id}/stats`. Docker's network counters
    /// are cumulative, and a container can have more than one interface, so callers
    /// must aggregate the entries rather than presenting a convenient but incomplete
    /// `eth0` reading.
    struct NetworkStats: Codable, Sendable {
        var rx_bytes: Int64?
        var tx_bytes: Int64?
    }

    struct Stats: Codable, Sendable {
        var read: String?
        var cpu_stats: CPUStats?
        var precpu_stats: CPUStats?
        var memory_stats: MemoryStats?
        var networks: [String: NetworkStats]?
    }

    struct PullProgress: Codable, Sendable {
        var status: String?
        var id: String?
        var progress: String?
        var error: String?
    }

    struct ErrorBody: Codable, Sendable {
        var message: String?
    }

    struct PruneReport: Codable, Sendable {
        var SpaceReclaimed: Int64?
    }

    struct InspectTTY: Codable, Sendable {
        struct Config: Codable, Sendable { var Tty: Bool? }
        var Config: Config?
    }
}

// MARK: - Wire → view model

extension PortMapping {
    init(_ wire: Wire.Port) {
        self.init(
            hostIP: wire.IP,
            hostPort: wire.PublicPort,
            containerPort: wire.PrivatePort,
            proto: wire.proto ?? "tcp")
    }
}

extension ContainerSummary {
    init(_ wire: Wire.Container) {
        let names = (wire.Names ?? []).map { name -> String in
            name.hasPrefix("/") ? String(name.dropFirst()) : name
        }
        let labels = wire.Labels ?? [:]

        // Deduplicate on the way in: Docker reports one entry per binding, and a
        // container published on both IPv4 and IPv6 otherwise shows every port twice.
        var seen = Set<String>()
        var ports: [PortMapping] = []
        for mapping in (wire.Ports ?? []).map(PortMapping.init) {
            let key = "\(mapping.hostPort.map(String.init) ?? "-")/\(mapping.containerPort)/\(mapping.proto)"
            if seen.insert(key).inserted { ports.append(mapping) }
        }
        ports.sort { ($0.hostPort ?? Int.max, $0.containerPort) < ($1.hostPort ?? Int.max, $1.containerPort) }

        let volumeNames = Array(Set((wire.Mounts ?? []).compactMap { mount -> String? in
            guard mount.type?.lowercased() == "volume",
                  let name = mount.Name,
                  !name.isEmpty
            else { return nil }
            return name
        })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        self.init(
            id: wire.Id,
            names: names,
            displayName: names.first ?? String(wire.Id.prefix(12)),
            image: wire.Image ?? wire.ImageID ?? "<unknown>",
            state: wire.State ?? "unknown",
            status: wire.Status ?? "",
            composeProject: labels["com.docker.compose.project"],
            composeService: labels["com.docker.compose.service"],
            ports: ports,
            createdAt: Date(timeIntervalSince1970: wire.Created ?? 0),
            volumeNames: volumeNames)
    }
}

extension ImageSummary {
    init(_ wire: Wire.Image) {
        self.init(
            id: wire.Id,
            repoTags: (wire.RepoTags ?? []).filter { !$0.isEmpty },
            size: wire.Size ?? 0,
            createdAt: Date(timeIntervalSince1970: wire.Created ?? 0),
            containersUsing: wire.Containers ?? -1,
            architecture: ImageArchitecture(wire.Descriptor?.platform))
    }
}

extension ImageArchitecture {

    /// Builds a platform from a wire block, returning `nil` when the architecture is
    /// missing — which is the only field the badge cannot work without.
    init?(_ wire: Wire.Platform?) {
        guard let wire, let architecture = wire.architecture, !architecture.isEmpty else {
            return nil
        }
        self.init(os: wire.os ?? "linux", arch: architecture, variant: wire.variant)
    }

    /// Builds a platform from an image inspect document.
    init?(_ wire: Wire.ImageInspect) {
        guard let architecture = wire.Architecture, !architecture.isEmpty else { return nil }
        self.init(os: wire.Os ?? "linux", arch: architecture, variant: wire.Variant)
    }
}

extension VolumeSummary {
    init(_ wire: Wire.Volume) {
        self.init(
            name: wire.Name,
            driver: wire.Driver ?? "local",
            mountpoint: wire.Mountpoint ?? "",
            size: wire.UsageData?.Size.flatMap { $0 < 0 ? nil : $0 },
            refCount: wire.UsageData?.RefCount.flatMap { $0 < 0 ? nil : $0 },
            labels: wire.Labels ?? [:])
    }
}

extension NetworkSummary {
    init(_ wire: Wire.Network) {
        self.init(
            id: wire.Id,
            name: wire.Name,
            driver: wire.Driver ?? "bridge",
            scope: wire.Scope ?? "local",
            containers: wire.Containers?.count ?? 0)
    }
}

extension DockerEvent {
    /// Builds an event from either the modern or the legacy payload shape.
    ///
    /// Returns `nil` only when neither shape yields an action, which is the one case
    /// where there is nothing to act on.
    init?(_ wire: Wire.Event) {
        let action = wire.Action ?? wire.status
        guard let action else { return nil }
        let seconds = wire.timeNano.map { $0 / 1_000_000_000 } ?? wire.time ?? Date().timeIntervalSince1970
        self.init(
            type: wire.eventType ?? "container",
            action: action,
            actorID: wire.Actor?.ID ?? wire.id ?? "",
            attributes: wire.Actor?.Attributes ?? [:],
            time: Date(timeIntervalSince1970: seconds))
    }
}

// MARK: - Compose grouping

/// A compose project and the containers that belong to it.
struct ComposeGroup: Identifiable, Sendable, Hashable {

    /// The project name, or `nil` for the bucket of unmanaged containers.
    var project: String?
    var containers: [ContainerSummary]

    var id: String { project ?? "\u{0}ungrouped" }

    var title: String { project ?? "Standalone" }

    var runningCount: Int { containers.filter(\.isRunning).count }

    /// A project is "up" only when every one of its containers is.
    var isFullyRunning: Bool { !containers.isEmpty && runningCount == containers.count }
}

extension Array where Element == ContainerSummary {

    /// Groups containers by their compose project.
    ///
    /// Projects come first in alphabetical order, and the standalone bucket last —
    /// which reads better than interleaving it, and keeps its position stable as
    /// projects come and go. Within a group, containers are ordered by service name
    /// so a stack does not reshuffle every time one member restarts.
    func groupedByComposeProject() -> [ComposeGroup] {
        var buckets: [String?: [ContainerSummary]] = [:]
        for container in self {
            buckets[container.composeProject, default: []].append(container)
        }
        let sortKey: (ContainerSummary, ContainerSummary) -> Bool = { lhs, rhs in
            let left = lhs.composeService ?? lhs.displayName
            let right = rhs.composeService ?? rhs.displayName
            if left == right { return lhs.displayName < rhs.displayName }
            return left.localizedStandardCompare(right) == .orderedAscending
        }
        let named = buckets
            .compactMap { key, value -> ComposeGroup? in
                guard let key else { return nil }
                return ComposeGroup(project: key, containers: value.sorted(by: sortKey))
            }
            .sorted { ($0.project ?? "").localizedStandardCompare($1.project ?? "") == .orderedAscending }

        guard let loose = buckets[String?.none], !loose.isEmpty else { return named }
        return named + [ComposeGroup(project: nil, containers: loose.sorted(by: sortKey))]
    }
}
