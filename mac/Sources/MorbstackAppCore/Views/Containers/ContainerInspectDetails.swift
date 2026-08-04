// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Turns the inspect document into the handful of facts the Overview tab shows.
//
// `DockerClient.inspectContainer(id:)` hands back pretty-printed JSON — the exact text
// the Inspect tab displays — so this decodes from that same string rather than making a
// second request. One fetch feeds both tabs, and the two can never disagree about what
// the engine said.
//
// Everything is optional on the wire and nothing here throws on a missing field: an
// inspect document from an older engine, or from a container that has never run, is a
// normal thing to be looking at.

import Foundation

/// The parsed inspect document.
struct TrackBInspectDetails: Equatable {

    // MARK: Nested types

    struct EnvVar: Identifiable, Equatable {
        let id: Int
        let key: String
        let value: String

        /// Lowercased `key=value`, for the search field.
        let lowered: String

        init(id: Int, key: String, value: String) {
            self.id = id
            self.key = key
            self.value = value
            self.lowered = "\(key)=\(value)".lowercased()
        }
    }

    struct Label: Identifiable, Equatable {
        var id: String { key }
        let key: String
        let value: String
    }

    struct Mount: Identifiable, Equatable {
        let id: String
        /// `bind`, `volume`, `tmpfs`.
        let kind: String
        /// The volume name, for a named volume.
        let name: String?
        let source: String
        let destination: String
        let readOnly: Bool

        var symbol: String {
            switch kind {
            case "volume": return "externaldrive"
            case "bind": return "folder"
            case "tmpfs": return "memorychip"
            default: return "arrow.left.arrow.right"
            }
        }
    }

    /// One network endpoint reported by `NetworkSettings.Networks` in Docker's inspect
    /// document. A network name alone is enough for the inventory list, but the
    /// selected-record inspector needs to keep its actual endpoint addresses and
    /// aliases attached to that exact network instead of flattening them into a string.
    struct NetworkEndpoint: Identifiable, Equatable {
        let name: String
        let networkID: String?
        let endpointID: String?
        let gateway: String?
        let ipAddress: String?
        let ipv6Gateway: String?
        let globalIPv6Address: String?
        let macAddress: String?
        let aliases: [String]

        var id: String { name }
    }

    /// Resource settings as configured in Docker. These are limits, not live
    /// consumption; the Statistics tab owns measured CPU and memory use over time.
    struct ResourceLimits: Equatable {
        let memoryBytes: Int64?
        let nanoCPUs: Int64?
        let cpuShares: Int64?
        let pidsLimit: Int64?
        let readOnlyRootFilesystem: Bool?

        var memoryLimitDescription: String {
            guard let memoryBytes else { return "Not reported" }
            return memoryBytes > 0 ? Formatters.bytesString(memoryBytes) : "No limit"
        }

        var cpuLimitDescription: String {
            guard let nanoCPUs else { return "Not reported" }
            guard nanoCPUs > 0 else { return "No limit" }
            let cpus = Double(nanoCPUs) / 1_000_000_000
            return String(format: "%.2f CPU%@", cpus, cpus == 1 ? "" : "s")
        }

        var cpuSharesDescription: String {
            guard let cpuShares else { return "Not reported" }
            return cpuShares > 0 ? "\(cpuShares) shares" : "Default"
        }

        var pidsLimitDescription: String {
            guard let pidsLimit else { return "Not reported" }
            return pidsLimit > 0 ? "\(pidsLimit) processes" : "No limit"
        }
    }

    // MARK: Fields

    var id: String
    var name: String
    var imageRef: String
    var imageID: String
    var platform: String?

    /// `nginx -g daemon off;` — entrypoint and args joined the way the CLI shows them.
    var command: String
    var entrypoint: String?
    var workingDir: String?
    var user: String?

    var created: Date?
    var startedAt: Date?
    var finishedAt: Date?
    var exitCode: Int?
    var restartCount: Int
    var restartPolicy: String?
    /// `healthy`, `unhealthy`, `starting`, or `nil` when the image declares no check.
    var health: String?
    var status: String
    var resourceLimits: ResourceLimits

    var env: [EnvVar]
    var labels: [Label]
    var mounts: [Mount]
    var networks: [String]
    var networkMode: String?
    var networkEndpoints: [NetworkEndpoint]

    static let empty = TrackBInspectDetails(
        id: "", name: "", imageRef: "", imageID: "", platform: nil,
        command: "", entrypoint: nil, workingDir: nil, user: nil,
        created: nil, startedAt: nil, finishedAt: nil, exitCode: nil,
        restartCount: 0, restartPolicy: nil, health: nil, status: "",
        resourceLimits: .init(
            memoryBytes: nil, nanoCPUs: nil, cpuShares: nil, pidsLimit: nil,
            readOnlyRootFilesystem: nil),
        env: [], labels: [], mounts: [], networks: [], networkMode: nil,
        networkEndpoints: [])

}

// MARK: - Parsing
//
// The initialisers live in an extension so that the struct keeps its memberwise
// initialiser — `TrackBInspectDetails.empty` and the tests both build values field by
// field, and declaring an `init` in the main body would silently take that away.

extension TrackBInspectDetails {

    /// Decodes an inspect document. Returns `nil` only when the text is not JSON at all.
    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode(Raw.self, from: data)
        else { return nil }
        self.init(raw)
    }

    private init(_ raw: Raw) {
        id = raw.id ?? ""
        name = raw.name.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 } ?? ""
        imageRef = raw.config?.image ?? ""
        imageID = raw.image ?? ""
        platform = raw.platform

        // Docker's own `docker ps` COMMAND column is entrypoint + args; `Path`/`Args` is
        // the resolved form, which is the honest one to show — it reflects what actually
        // runs, including an entrypoint the image supplied rather than the user.
        let parts = [raw.path].compactMap { $0 } + (raw.args ?? [])
        command = parts.map(Self.shellQuote).joined(separator: " ")
        entrypoint = (raw.config?.entrypoint).flatMap { $0.isEmpty ? nil : $0.joined(separator: " ") }
        workingDir = (raw.config?.workingDir).flatMap { $0.isEmpty ? nil : $0 }
        user = (raw.config?.user).flatMap { $0.isEmpty ? nil : $0 }

        created = Self.date(raw.created)
        startedAt = Self.date(raw.state?.startedAt)
        finishedAt = Self.date(raw.state?.finishedAt)
        exitCode = raw.state?.exitCode
        restartCount = raw.restartCount ?? 0
        restartPolicy = (raw.hostConfig?.restartPolicy?.name).flatMap {
            ($0.isEmpty || $0 == "no") ? nil : $0
        }
        health = raw.state?.health?.status.flatMap { $0.isEmpty ? nil : $0 }
        status = raw.state?.status ?? ""
        resourceLimits = ResourceLimits(
            memoryBytes: raw.hostConfig?.memory,
            nanoCPUs: raw.hostConfig?.nanoCPUs,
            cpuShares: raw.hostConfig?.cpuShares,
            pidsLimit: raw.hostConfig?.pidsLimit,
            readOnlyRootFilesystem: raw.hostConfig?.readOnlyRootFilesystem)

        env = (raw.config?.env ?? []).enumerated().map { index, entry in
            guard let separator = entry.firstIndex(of: "=") else {
                return EnvVar(id: index, key: entry, value: "")
            }
            return EnvVar(
                id: index,
                key: String(entry[entry.startIndex..<separator]),
                value: String(entry[entry.index(after: separator)...]))
        }

        labels = (raw.config?.labels ?? [:])
            .map { Label(key: $0.key, value: $0.value) }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }

        mounts = (raw.mounts ?? []).enumerated().map { index, mount in
            Mount(
                id: mount.destination ?? "mount-\(index)",
                kind: mount.kind ?? "bind",
                name: mount.name,
                source: mount.source ?? mount.name ?? "",
                destination: mount.destination ?? "",
                readOnly: !(mount.writable ?? true))
        }

        networkMode = raw.hostConfig?.networkMode.flatMap { $0.isEmpty ? nil : $0 }
        networkEndpoints = (raw.networkSettings?.networks ?? [:])
            .map { name, endpoint in
                NetworkEndpoint(
                    name: name,
                    networkID: Self.nonEmpty(endpoint.networkID),
                    endpointID: Self.nonEmpty(endpoint.endpointID),
                    gateway: Self.nonEmpty(endpoint.gateway),
                    ipAddress: Self.nonEmpty(endpoint.ipAddress),
                    ipv6Gateway: Self.nonEmpty(endpoint.ipv6Gateway),
                    globalIPv6Address: Self.nonEmpty(endpoint.globalIPv6Address),
                    macAddress: Self.nonEmpty(endpoint.macAddress),
                    aliases: (endpoint.aliases ?? []).filter { !$0.isEmpty }.sorted())
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        networks = networkEndpoints.map(\.name)
    }

    // MARK: Derived

    /// The chip sequence for the state timeline: created → started → (exited).
    var timeline: [(label: String, detail: String, symbol: String)] {
        var chips: [(label: String, detail: String, symbol: String)] = []
        if let created {
            chips.append(("Created", Formatters.relativeDate(created), "plus.circle"))
        }
        if let startedAt, startedAt.timeIntervalSince1970 > 0 {
            chips.append(("Started", Formatters.relativeDate(startedAt), "play.circle"))
        }
        if let finishedAt, finishedAt.timeIntervalSince1970 > 0,
           status != "running", status != "restarting"
        {
            let code = exitCode.map { " · exit \($0)" } ?? ""
            chips.append(("Exited", Formatters.relativeDate(finishedAt) + code, "stop.circle"))
        }
        if restartCount > 0 {
            chips.append(("Restarts", "\(restartCount)", "arrow.clockwise.circle"))
        }
        return chips
    }

    /// How long the container has been up, when it is.
    var uptime: String? {
        guard status == "running", let startedAt, startedAt.timeIntervalSince1970 > 0 else {
            return nil
        }
        return Formatters.compactDuration(since: startedAt)
    }

    // MARK: Helpers

    /// Quotes an argument only when it needs it, the way a shell transcript would.
    static func shellQuote(_ argument: String) -> String {
        guard !argument.isEmpty else { return "''" }
        let safe = argument.allSatisfy { character in
            character.isLetter || character.isNumber
                || "-_./:=@+,".contains(character)
        }
        if safe { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Docker writes `0001-01-01T00:00:00Z` for "never", which is not a date anyone
    /// wants rendered as "2,025 years ago".
    static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty, !text.hasPrefix("0001-01-01") else { return nil }
        return parseRFC3339(text)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        value.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Docker stamps nine fractional digits; `ISO8601DateFormatter` accepts three, so
    /// the fraction is truncated before it is handed over. Same trick the log stream's
    /// timestamp parser uses, kept local so this file depends on nothing but Foundation.
    static func parseRFC3339(_ text: String) -> Date? {
        guard let dot = text.firstIndex(of: ".") else { return iso8601Whole.date(from: text) }
        let head = String(text[text.startIndex..<dot])
        let rest = text[text.index(after: dot)...]
        let digits = String(rest.prefix(while: \.isNumber))
        let suffix = String(rest.dropFirst(digits.count))
        let millis = String((digits + "000").prefix(3))
        return iso8601Fractional.date(from: "\(head).\(millis)\(suffix)")
            ?? iso8601Whole.date(from: head + suffix)
    }

    // MARK: Wire

    /// A mirror of `/containers/{id}/json`, narrowed to the fields the Overview tab reads.
    ///
    /// Every property is a normal lowerCamelCase Swift name mapped to Docker's
    /// capitalised key through `CodingKeys`, rather than a property spelled the way the
    /// JSON spells it. Mirroring the wire names directly is tempting and wrong twice
    /// over: `Type` is not even a legal property name (it collides with the `foo.Type`
    /// metatype expression), and a property named `State` sitting next to a nested type
    /// named `State` makes every later mention of `State` ambiguous to read, if not to
    /// the compiler.
    private struct Raw: Decodable {

        struct StateBlock: Decodable {
            struct HealthBlock: Decodable {
                var status: String?
                enum CodingKeys: String, CodingKey { case status = "Status" }
            }

            var status: String?
            var running: Bool?
            var paused: Bool?
            var startedAt: String?
            var finishedAt: String?
            var exitCode: Int?
            var health: HealthBlock?

            enum CodingKeys: String, CodingKey {
                case status = "Status"
                case running = "Running"
                case paused = "Paused"
                case startedAt = "StartedAt"
                case finishedAt = "FinishedAt"
                case exitCode = "ExitCode"
                case health = "Health"
            }
        }

        struct ConfigBlock: Decodable {
            var env: [String]?
            var labels: [String: String]?
            var cmd: [String]?
            var entrypoint: [String]?
            var workingDir: String?
            var user: String?
            var image: String?
            var tty: Bool?

            enum CodingKeys: String, CodingKey {
                case env = "Env"
                case labels = "Labels"
                case cmd = "Cmd"
                case entrypoint = "Entrypoint"
                case workingDir = "WorkingDir"
                case user = "User"
                case image = "Image"
                case tty = "Tty"
            }
        }

        struct MountPoint: Decodable {
            var kind: String?
            var name: String?
            var source: String?
            var destination: String?
            var mode: String?
            var writable: Bool?

            enum CodingKeys: String, CodingKey {
                case kind = "Type"
                case name = "Name"
                case source = "Source"
                case destination = "Destination"
                case mode = "Mode"
                case writable = "RW"
            }
        }

        struct HostConfigBlock: Decodable {
            struct RestartPolicyBlock: Decodable {
                var name: String?
                enum CodingKeys: String, CodingKey { case name = "Name" }
            }

            var restartPolicy: RestartPolicyBlock?
            var memory: Int64?
            var nanoCPUs: Int64?
            var cpuShares: Int64?
            var pidsLimit: Int64?
            var readOnlyRootFilesystem: Bool?
            var networkMode: String?

            enum CodingKeys: String, CodingKey {
                case restartPolicy = "RestartPolicy"
                case memory = "Memory"
                case nanoCPUs = "NanoCpus"
                case cpuShares = "CpuShares"
                case pidsLimit = "PidsLimit"
                case readOnlyRootFilesystem = "ReadonlyRootfs"
                case networkMode = "NetworkMode"
            }
        }

        struct NetworkSettingsBlock: Decodable {
            struct Endpoint: Decodable {
                var networkID: String?
                var endpointID: String?
                var gateway: String?
                var ipAddress: String?
                var ipv6Gateway: String?
                var globalIPv6Address: String?
                var macAddress: String?
                var aliases: [String]?

                enum CodingKeys: String, CodingKey {
                    case networkID = "NetworkID"
                    case endpointID = "EndpointID"
                    case gateway = "Gateway"
                    case ipAddress = "IPAddress"
                    case ipv6Gateway = "IPv6Gateway"
                    case globalIPv6Address = "GlobalIPv6Address"
                    case macAddress = "MacAddress"
                    case aliases = "Aliases"
                }
            }

            var networks: [String: Endpoint]?
            enum CodingKeys: String, CodingKey { case networks = "Networks" }
        }

        var id: String?
        var name: String?
        var created: String?
        var path: String?
        var args: [String]?
        var image: String?
        var platform: String?
        var restartCount: Int?
        var state: StateBlock?
        var config: ConfigBlock?
        var mounts: [MountPoint]?
        var hostConfig: HostConfigBlock?
        var networkSettings: NetworkSettingsBlock?

        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case name = "Name"
            case created = "Created"
            case path = "Path"
            case args = "Args"
            case image = "Image"
            case platform = "Platform"
            case restartCount = "RestartCount"
            case state = "State"
            case config = "Config"
            case mounts = "Mounts"
            case hostConfig = "HostConfig"
            case networkSettings = "NetworkSettings"
        }
    }
}

// MARK: - Redaction

/// Whether an environment variable's value should be hidden until asked for.
///
/// The Overview tab redacts *everything* by default — a screenshot of a container's
/// environment is a credential leak far more often than it is a debugging aid, and
/// guessing which variables are secret gets it wrong in both directions. What this does
/// decide is whether revealing one is worth a second thought, which drives the warning
/// colour on the reveal control.
enum TrackBSecretHeuristic {

    private static let markers = [
        "secret", "password", "passwd", "token", "apikey", "api_key",
        "access_key", "private_key", "credential", "auth", "session",
    ]

    static func looksSensitive(key: String) -> Bool {
        let lowered = key.lowercased()
        return markers.contains { lowered.contains($0) }
    }

    /// A fixed-width mask. Fixed rather than proportional on purpose: the *length* of a
    /// password is information too.
    static let mask = "••••••••"
}
