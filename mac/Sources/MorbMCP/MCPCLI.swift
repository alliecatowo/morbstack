// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Foundation
import MorbFeatures
import MorbstackKit

/// Command-line surface for Morbstack's stdio MCP server.
///
/// The command deliberately has only three entry points. `serve` is the long-lived
/// protocol process; `init` writes a conservative, inspectable profile; and
/// `permissions` explains the effective policy before a person starts a server.
/// Keeping policy inspection outside the server is important: a client should not
/// need to connect first to discover that its requested writes will be denied.
enum MCPCLI {

    private struct CommandError: Error, CustomStringConvertible {
        let description: String
    }

    private static let usage = """
    Usage: morb mcp <subcommand> [options]

    Subcommands:
      serve [--allow <permission>]...
          Run a Model Context Protocol server over stdin/stdout. Read-only tools are
          available by default; every mutating tool needs an explicit grant.
      init [--force]
          Create ~/.morbstack/mcp.toml with an empty, read-only-by-default profile.
      permissions [--allow <permission>]...
          Show every tool's effective permission and where that decision came from.

    Permission grants:
      Grant a tool name (for example container_start), a group (for example
      containers:write), or an argument-level guard (for example inspect:env).
      `all` grants every tool and guard and is intentionally warned about.

    The profile lives at ~/.morbstack/mcp.toml. Run `morb mcp init` to create a
    commented template, then inspect `morb mcp permissions` before using `serve`.
    """

    static func run(_ arguments: [String], json: Bool) -> Int32 {
        guard let subcommand = arguments.first else {
            printUsage()
            return 0
        }

        let residual = Array(arguments.dropFirst())
        switch subcommand {
        case "help", "--help", "-h":
            guard residual.isEmpty else { return usageError("help does not take additional arguments") }
            printUsage()
            return 0

        case "serve":
            guard !json else {
                return usageError("`morb mcp serve` already speaks JSON-RPC on stdout; do not pass --json")
            }
            return serve(residual)

        case "init":
            return initializeProfile(residual, json: json)

        case "permissions":
            return showPermissions(residual, json: json)

        default:
            return usageError("unknown subcommand `\(subcommand)`")
        }
    }

    // MARK: - `morb mcp serve`

    private static func serve(_ arguments: [String]) -> Int32 {
        let profile: PermissionProfile
        switch loadProfile(arguments) {
        case .success(let loaded):
            profile = loaded
        case .failure(let message):
            return commandError(message.description)
        }

        let warnings = profileWarnings(profile)
        for warning in warnings { writeError("warning: \(warning)") }

        let audit: AuditLog
        do {
            audit = try AuditLog()
        } catch {
            // Mutating decisions must be auditable. Continuing without a writable log
            // would make a transient filesystem problem quietly weaken the safety
            // model, so fail before the server has accepted a single request.
            return commandError("could not initialise MCP audit log: \((error as? MorbError)?.description ?? "\(error)")")
        }

        audit.recordServerStart(allow: profile.allow, deny: profile.deny, warnings: warnings)
        defer { audit.recordServerStop() }

        let server = MCPServer(profile: profile, context: ToolContext(engine: EngineClient()), audit: audit)
        return MCPStdioServer(server: server).run()
    }

    // MARK: - `morb mcp init`

    private static func initializeProfile(_ arguments: [String], json: Bool) -> Int32 {
        let force: Bool
        switch arguments {
        case []:
            force = false
        case ["--force"]:
            force = true
        default:
            return usageError("init accepts only --force")
        }

        let configURL = MorbFeaturePaths.mcpConfig
        let replacingExistingProfile = FileManager.default.fileExists(atPath: configURL.path)
        if replacingExistingProfile, !force {
            return commandError(
                "\(configURL.path) already exists; refusing to overwrite it. Review it with "
                    + "`morb mcp permissions`, or pass --force to replace it with the empty template.")
        }

        guard MorbFeaturePaths.ensureDirectory(configURL.deletingLastPathComponent()) else {
            return commandError("could not create \(configURL.deletingLastPathComponent().path)")
        }

        do {
            try Data(profileTemplate.utf8).write(to: configURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: configURL.path)
        } catch {
            return commandError("could not write \(configURL.path): \(error.localizedDescription)")
        }

        let payload: [String: Any] = [
            "path": configURL.path,
            "created": true,
            "overwrote_existing_profile": replacingExistingProfile,
            "default": "read-only",
        ]
        emit(payload, text: "Created \(configURL.path) (read-only tools remain available; mutating tools are denied until granted).", json: json)
        return 0
    }

    // MARK: - `morb mcp permissions`

    private static func showPermissions(_ arguments: [String], json: Bool) -> Int32 {
        let profile: PermissionProfile
        switch loadProfile(arguments) {
        case .success(let loaded):
            profile = loaded
        case .failure(let message):
            return commandError(message.description)
        }

        let warnings = profileWarnings(profile)
        let toolPayloads = ToolRegistry.all.map { tool -> [String: Any] in
            let decision = profile.decide(tool.permissionSubject)
            let guards = tool.guards.map { guardSpec -> [String: Any] in
                let guardDecision = profile.decideGuardKey(guardSpec.key)
                return [
                    "key": guardSpec.key,
                    "description": guardSpec.description,
                    "allowed": guardDecision.allowed,
                    "decision": guardDecision.explanation,
                ]
            }
            return [
                "name": tool.name,
                "summary": tool.summary,
                "read_only": tool.readOnly,
                "destructive": tool.destructive,
                "group": tool.group?.rawValue ?? NSNull(),
                "allowed": decision.allowed,
                "decision": decision.explanation,
                "guards": guards,
            ]
        }

        if json {
            emit([
                "config": MorbFeaturePaths.mcpConfig.path,
                "allow": profile.allow.map { grantPayload($0) },
                "deny": profile.deny.map { grantPayload($0) },
                "warnings": warnings,
                "tools": toolPayloads,
            ], text: "", json: true)
            return 0
        }

        print("MCP permission profile: \(MorbFeaturePaths.mcpConfig.path)")
        print("Read-only tools are always available. Mutating tools and guarded arguments need explicit grants.\n")

        var table = TextTable(headers: ["TOOL", "ACCESS", "DECISION"])
        for tool in ToolRegistry.all {
            let decision = profile.decide(tool.permissionSubject)
            let access: String
            if tool.readOnly { access = "read-only" }
            else { access = decision.allowed ? "allowed" : "denied" }
            table.add([tool.name, access, decision.explanation])
            for guardSpec in tool.guards {
                let guardDecision = profile.decideGuardKey(guardSpec.key)
                table.add(["  ↳ \(guardSpec.key)", guardDecision.allowed ? "allowed" : "denied", guardDecision.explanation])
            }
        }
        print(table.render())

        if !warnings.isEmpty {
            print("\nWarnings:")
            for warning in warnings { print("  - \(warning)") }
        }
        return 0
    }

    // MARK: - Shared profile/output helpers

    private static func loadProfile(_ arguments: [String]) -> Result<PermissionProfile, CommandError> {
        let cliAllow: [GrantEntry]
        switch parseAllowFlags(arguments) {
        case .success(let entries):
            cliAllow = entries
        case .failure(let message):
            return .failure(CommandError(description: message.description))
        }

        do {
            let config = try MCPConfigFile.load(from: MorbFeaturePaths.mcpConfig)
            return .success(PermissionProfile.build(
                configAllow: config.allow, configDeny: config.deny, cliAllow: cliAllow,
                knownKeys: ToolRegistry.knownKeys))
        } catch {
            return .failure(CommandError(description: (error as? MorbError)?.description ?? "\(error)"))
        }
    }

    private static func profileWarnings(_ profile: PermissionProfile) -> [String] {
        var warnings = profile.unknownKeys.map {
            "unknown permission key `\($0.key)` at \($0.origin); it has no effect"
        }
        warnings.append(contentsOf: profile.grantsAll.map {
            "`all` was granted at \($0.origin); every mutating tool and argument guard is enabled"
        })
        return warnings
    }

    private static func grantPayload(_ entry: GrantEntry) -> [String: Any] {
        ["key": entry.key, "origin": entry.origin.description]
    }

    private static func emit(_ payload: Any, text: String, json: Bool) {
        if json {
            print(JSONRead.pretty(payload))
        } else if !text.isEmpty {
            print(text)
        }
    }

    private static func printUsage(to output: FileHandle = .standardOutput) {
        output.write(Data((usage + "\n").utf8))
    }

    private static func usageError(_ message: String) -> Int32 {
        writeError(message)
        FileHandle.standardError.write(Data("\n".utf8))
        printUsage(to: .standardError)
        return 2
    }

    private static func commandError(_ message: String) -> Int32 {
        writeError(message)
        return 2
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data(("morb mcp: " + message + "\n").utf8))
    }

    private static let profileTemplate = """
    # Morbstack Model Context Protocol permissions.
    #
    # Read-only tools (containers_list, images_list, disk_usage, and similar)
    # are always available. Mutating tools stay denied unless you list a grant
    # below. Use `morb mcp permissions` to inspect the effective policy.
    #
    # You can grant a specific tool, a group, or a sensitive argument guard:
    #   allow = ["container_start"]
    #   allow = ["containers:write"]
    #   allow = ["inspect:env"]
    #
    # `all` enables every tool and guard. It is supported for deliberate local
    # automation but is warned about whenever the server starts.
    allow = []

    # Deny always wins, including over a command-line --allow flag.
    deny = []
    """ + "\n"
}
