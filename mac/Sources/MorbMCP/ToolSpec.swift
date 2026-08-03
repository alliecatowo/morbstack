// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The shared shape every MCP tool is described and implemented with: its JSON
// Schema (so a client can validate arguments before ever calling us, and so an
// agent can discover what a tool wants without trial and error), its permission
// metadata (Permissions.swift decides whether a call proceeds; this file only
// declares which group and which argument guards a tool has), and its handler.

import Foundation
import MorbFeatures
import MorbstackKit

/// What a tool handler hands back to `tools/call`.
///
/// MCP's `CallToolResult` always succeeds at the JSON-RPC layer — a denied
/// permission, a Docker Engine error, and a malformed argument are all reported
/// as `isError: true` content the agent can read and react to, never as a
/// JSON-RPC error. JSON-RPC errors are reserved for the protocol itself being
/// misused (Server.swift handles those); a tool doing its job and reporting
/// failure is not a protocol violation.
public struct ToolCallResult {
    public var content: [[String: Any]]
    public var isError: Bool

    /// One structured JSON result as the tool's text content, pretty-printed so
    /// an agent (or a human reading the transcript) can read it directly rather
    /// than through a minifier.
    public static func text(_ json: Any, isError: Bool = false) -> ToolCallResult {
        ToolCallResult(content: [["type": "text", "text": JSONRead.pretty(wrapIfNeeded(json))]], isError: isError)
    }

    /// A plain-text error message — used for permission denials and failures
    /// that are not themselves JSON documents (a Docker error string, a missing
    /// binary, a bad path).
    public static func errorText(_ message: String) -> ToolCallResult {
        ToolCallResult(content: [["type": "text", "text": message]], isError: true)
    }

    private static func wrapIfNeeded(_ value: Any) -> Any {
        JSONSerialization.isValidJSONObject(value) ? value : ["value": value]
    }
}

/// Shared state every tool handler can reach: the Engine API client and the
/// scratch locations that keep CLI shell-outs from ever touching the user's
/// real `~/.docker`.
public final class ToolContext {
    public let engine: EngineClient

    public init(engine: EngineClient) {
        self.engine = engine
    }

    /// `unix://` + the engine's socket path, for `DOCKER_HOST` when shelling
    /// out to the real `docker` / `docker compose` CLI (compose_up, compose_down,
    /// image_build). The CLI has no other way to find Morbstack's engine — it
    /// defaults to `/var/run/docker.sock`, which does not exist on this host.
    public var dockerHostURL: String { "unix://\(engine.socketPath)" }

    /// `~/.morbstack/mcp-docker-config` — a `DOCKER_CONFIG` directory owned
    /// entirely by the MCP server, never the user's `~/.docker`.
    ///
    /// The CLI plugins system, credential helpers, and `docker login` state all
    /// live under `DOCKER_CONFIG`. Letting a compose/build shell-out default to
    /// the user's real `~/.docker` would mean an MCP tool call can read whatever
    /// registry credentials are stored there and can write files into a
    /// directory the user's own `docker` CLI trusts — neither of which an agent
    /// asking to bring up a compose project has any business touching.
    public var dockerConfigDirectory: URL {
        MorbPaths.root.appendingPathComponent("mcp-docker-config", isDirectory: true)
    }

    /// Ensures the scratch `DOCKER_CONFIG` directory exists with a minimal,
    /// empty config so the CLI does not try (and fail, or worse, succeed by
    /// falling back to `~/.docker`) to bootstrap one itself.
    @discardableResult
    public func ensureDockerConfigDirectory() -> URL {
        let directory = dockerConfigDirectory
        _ = MorbFeaturePaths.ensureDirectory(directory)
        let configFile = directory.appendingPathComponent("config.json", isDirectory: false)
        if !FileManager.default.fileExists(atPath: configFile.path) {
            try? Data("{}\n".utf8).write(to: configFile)
        }
        return directory
    }

    /// The environment a `docker` / `docker compose` shell-out should run with:
    /// the parent process's environment (so `PATH`, `HOME`, locale, etc. all
    /// still work) with `DOCKER_HOST` and `DOCKER_CONFIG` overridden to point at
    /// Morbstack, and `DOCKER_CONTEXT` removed so a context the user has active
    /// in their real Docker config cannot override the socket we just set.
    public func shellOutEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["DOCKER_HOST"] = dockerHostURL
        environment["DOCKER_CONFIG"] = ensureDockerConfigDirectory().path
        environment.removeValue(forKey: "DOCKER_CONTEXT")
        return environment
    }
}

/// One tool's complete description and implementation.
public struct ToolSpec {
    public var name: String
    /// Base description, before any "currently denied" suffix `tools/list` adds.
    public var summary: String
    public var inputSchema: [String: Any]
    public var readOnly: Bool
    public var destructive: Bool
    /// `nil` for read-only tools. Permissions.swift's ``PermissionSubject`` is
    /// derived from this at registration time (ToolRegistry.swift) rather than
    /// stored redundantly here.
    public var group: ToolGroup?
    /// Argument-level guard names this tool defines (e.g. `container_remove`
    /// defines `"force"`). Each guard's predicate decides, from the call's
    /// arguments, whether the guard applies to *this* call.
    public var guards: [(name: String, appliesTo: ([String: Any]) -> Bool)]
    public var handler: (ToolContext, [String: Any]) -> ToolCallResult

    public init(
        name: String, summary: String, inputSchema: [String: Any],
        readOnly: Bool, destructive: Bool, group: ToolGroup?,
        guards: [(name: String, appliesTo: ([String: Any]) -> Bool)] = [],
        handler: @escaping (ToolContext, [String: Any]) -> ToolCallResult
    ) {
        self.name = name
        self.summary = summary
        self.inputSchema = inputSchema
        self.readOnly = readOnly
        self.destructive = destructive
        self.group = group
        self.guards = guards
        self.handler = handler
    }

    public var permissionSubject: PermissionSubject {
        PermissionSubject(name: name, group: group, guards: guards.map(\.name))
    }
}

// MARK: - JSON Schema construction

/// Tiny builders for the JSON Schema objects `tools/list` advertises. Kept
/// intentionally small — every schema here is a flat object of scalars, arrays
/// of strings, or a small nested object, which is all these tools need and all
/// these helpers support.
public enum Schema {
    public static func object(
        _ properties: [String: Any], required: [String] = [], additionalProperties: Bool = false
    ) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        schema["additionalProperties"] = additionalProperties
        return schema
    }

    public static func string(_ description: String, enumValues: [String]? = nil, defaultValue: String? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "string", "description": description]
        if let enumValues { schema["enum"] = enumValues }
        if let defaultValue { schema["default"] = defaultValue }
        return schema
    }

    public static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil, defaultValue: Int? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "integer", "description": description]
        if let minimum { schema["minimum"] = minimum }
        if let maximum { schema["maximum"] = maximum }
        if let defaultValue { schema["default"] = defaultValue }
        return schema
    }

    public static func boolean(_ description: String, defaultValue: Bool? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "boolean", "description": description]
        if let defaultValue { schema["default"] = defaultValue }
        return schema
    }

    public static func stringArray(_ description: String, enumValues: [String]? = nil) -> [String: Any] {
        var items: [String: Any] = ["type": "string"]
        if let enumValues { items["enum"] = enumValues }
        return ["type": "array", "description": description, "items": items]
    }

    public static func stringMap(_ description: String) -> [String: Any] {
        ["type": "object", "description": description, "additionalProperties": ["type": "string"]]
    }
}
