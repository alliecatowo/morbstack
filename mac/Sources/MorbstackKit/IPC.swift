// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Foundation

/// A minimal dynamic JSON value, used for the untyped `data` payload of ``DaemonResponse``.
///
/// The control protocol is newline-delimited JSON, and the daemon returns a small
/// bag of key/value pairs whose shape depends on the command. Rather than pull in a
/// dependency, MorbstackKit ships this seven-case enum.
public enum AnyCodableValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([AnyCodableValue])
    case object([String: AnyCodableValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Order matters: `bool` must be attempted before the numeric cases, and
        // `int` before `double`, otherwise JSON `true` / `1` decode ambiguously.
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AnyCodableValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AnyCodableValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// A compact, human-friendly rendering used by the CLI's non-JSON output.
    public var displayString: String {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "-"
        case .array(let values): return values.map(\.displayString).joined(separator: ", ")
        case .object(let values):
            return values.keys.sorted().map { "\($0)=\(values[$0]?.displayString ?? "-")" }
                .joined(separator: " ")
        }
    }
}

/// A request sent by the `morb` CLI to `morbstackd` over the control socket.
///
/// One JSON object per line. `cmd` is one of
/// `status`, `start`, `stop`, `suspend`, `resume`, `version`.
public struct DaemonRequest: Codable, Equatable, Sendable {
    /// The command name.
    public var cmd: String
    /// Optional command arguments, e.g. `["force": "true"]` for `stop`.
    public var args: [String: String]?

    /// Creates a request.
    public init(cmd: String, args: [String: String]? = nil) {
        self.cmd = cmd
        self.args = args
    }
}

/// Policy for when the `morb` CLI may bring a daemon up by itself.
///
/// `morb` auto-starts a sibling `morbstackd` when the control socket does not
/// answer. That is right for commands whose entire purpose is "make the engine
/// available", and wrong — sometimes badly wrong — for everything else:
///
///   * `stop` launching a daemon in order to stop it is absurd on its face,
///     and in practice it makes a fresh daemon appear moments after anyone
///     kills one. An ordinary shutdown then looks like something respawning
///     behind your back, which is exactly the illusion that cost real time
///     during the M1 gate run.
///   * `status` should report that nothing is running, not create the thing it
///     was asked to describe. An observation that changes what it observes is
///     not an observation.
///   * `suspend` has nothing to suspend.
///
/// `resume` does qualify: it is how a suspended VM gets back to running, and
/// the daemon owns the saved state.
///
/// This governs only the *control* socket. The docker socket keeps its own
/// on-demand activation — that is the socket-activation design, and `docker ps`
/// genuinely does want an engine.
public enum MorbCommandPolicy {

    /// Commands that may start a daemon when none is listening.
    /// `k8s-enable` qualifies for the same reason `start` does: asking for a cluster
    /// is asking for the engine it runs on, and refusing to start one would make the
    /// command fail with "the VM is stopped" every single time from a cold machine.
    /// The other three `k8s-*` commands do not — `k8s-status` describing a stopped
    /// stack is a correct answer, and conjuring a VM to produce a kubeconfig for a
    /// cluster that is not running would be worse than saying so.
    public static let autoStartingCommands: Set<String> = ["start", "resume", "k8s-enable"]

    /// Commands the CLI answers itself, with the daemon consulted only if it happens
    /// to be there.
    ///
    /// Listed explicitly rather than left to fall through the allow-list, because
    /// these are the commands where accidentally spawning a daemon would be actively
    /// harmful rather than merely surprising: `doctor` exists to diagnose a host on
    /// which the daemon may be the broken thing, and `reset-disk` deletes the Docker
    /// data disk — conjuring a daemon that immediately opens that disk is the one
    /// thing it must never do.
    ///
    /// `shares` and `rosetta` join them for the `status` reason rather than the
    /// `reset-disk` one: both have a complete, useful answer with nothing running —
    /// `shares` reads `config.toml` and runs the same plan the daemon would, `rosetta`
    /// asks Virtualization.framework about the host — so booting a VM to answer them
    /// would change the world in order to describe it. `rosetta` additionally must never
    /// spawn anything: `morb rosetta install` puts a system software-installation dialog
    /// on screen, and a background daemon must never be what causes that.
    public static let selfServedCommands: Set<String> = [
        "doctor", "reset-disk", "shares", "rosetta",
    ]

    /// Whether `command` is allowed to auto-start `morbstackd`.
    public static func mayAutoStartDaemon(_ command: String) -> Bool {
        guard !selfServedCommands.contains(command) else { return false }
        return autoStartingCommands.contains(command)
    }
}

/// The daemon's reply to a ``DaemonRequest``.
///
/// Exactly one of `data` (on success) or `error` (on failure) is meaningful.
public struct DaemonResponse: Codable, Equatable, Sendable {
    /// Whether the command succeeded.
    public var ok: Bool
    /// Command-specific result payload; present when ``ok`` is `true`.
    public var data: [String: AnyCodableValue]?
    /// Human-readable failure message; present when ``ok`` is `false`.
    public var error: String?

    /// Creates a response.
    public init(ok: Bool, data: [String: AnyCodableValue]? = nil, error: String? = nil) {
        self.ok = ok
        self.data = data
        self.error = error
    }

    /// Convenience constructor for a successful reply.
    public static func success(_ data: [String: AnyCodableValue] = [:]) -> DaemonResponse {
        DaemonResponse(ok: true, data: data, error: nil)
    }

    /// Convenience constructor for a failed reply.
    public static func failure(_ message: String) -> DaemonResponse {
        DaemonResponse(ok: false, data: nil, error: message)
    }
}

/// Encoding helpers for the newline-delimited JSON control protocol.
public enum IPCCodec {

    /// A JSON encoder configured to emit a single line (no pretty printing).
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Encodes `value` as one JSON line terminated by `\n`.
    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try makeEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    /// Decodes one JSON line (a trailing newline is tolerated).
    public static func decodeLine<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        var slice = data
        while let last = slice.last, last == 0x0A || last == 0x0D {
            slice.removeLast()
        }
        guard !slice.isEmpty else {
            throw MorbError.protocolViolation("empty control message")
        }
        do {
            return try JSONDecoder().decode(T.self, from: slice)
        } catch {
            throw MorbError.protocolViolation("malformed control message: \(error.localizedDescription)")
        }
    }

    /// Pretty-prints any `Encodable` for `--json` CLI output.
    public static func prettyJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}
