// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The permission model for `morb mcp serve`.
//
// The threat this defends against is not a malicious MCP client — it is a
// well-behaved one driven by a compromised or simply mistaken prompt. An agent
// that can list containers is useful and low-risk; an agent that can silently
// remove them because a tool description told it to is a production incident.
// So the whole design optimises for one property: nothing mutating ever happens
// without a grant that a human wrote down somewhere inspectable, and every
// decision this file makes is answerable from `morb mcp permissions`.
//
// Read-only tools sit entirely outside this file's authority: ``ToolSpec/group``
// is `nil` for them, and the dispatcher in Server.swift never consults a
// ``PermissionProfile`` before running one. That is what keeps the zero-config
// case (list what's running) useful on a machine with no `mcp.toml` at all.

import Foundation
import MorbstackKit

// MARK: - Grant keys

/// The permission groups a mutating tool can belong to.
///
/// Grouping exists so a profile can say "this agent may manage container
/// lifecycle" without enumerating `container_start`, `container_stop`,
/// `container_restart` and `container_remove` by hand — and so that adding a
/// fifth container-lifecycle tool later does not require every existing
/// `mcp.toml` in the world to be edited to keep covering it.
///
/// Deliberately *not* one giant "write" group: `exec` (arbitrary command
/// execution inside a running container) and `compose`/`images:write` (pulling
/// and building images, which touches disk and network) are meaningfully
/// different risks from starting a container that is already configured, and a
/// profile author should be able to grant one without the others.
public enum ToolGroup: String, CaseIterable, Sendable {
    case containersWrite = "containers:write"
    case exec = "exec"
    case compose = "compose"
    case imagesWrite = "images:write"
    case prune = "prune"
    case engine = "engine"

    /// A one-line description used in `morb mcp permissions` and the generated
    /// `mcp.toml` template.
    public var summary: String {
        switch self {
        case .containersWrite: return "start, stop, restart, remove containers (not force-remove)"
        case .exec: return "run a command inside a running container"
        case .compose: return "docker compose up/down (not volume removal)"
        case .imagesWrite: return "pull, remove, and build images"
        case .prune: return "reclaim disk (not volumes)"
        case .engine: return "start/stop the Morbstack VM and engine"
        }
    }
}

/// The universal grant that covers every tool and every argument-level guard.
///
/// Kept as a bare string rather than folded into ``ToolGroup`` because it is not
/// a category of risk — it is "skip the categorisation entirely", which is why
/// granting it prints a warning nothing else does.
public let allGrantKey = "all"

// MARK: - Grant entries and provenance

/// Where one grant or denial came from. Printed verbatim by `morb mcp permissions`
/// so a profile is never a black box: every yes/no traces to a line of text a
/// human wrote.
public enum GrantOrigin: Equatable, CustomStringConvertible, Sendable {
    /// Read-only tools need no grant; this is the origin reported for them.
    case builtinReadOnly
    /// `~/.morbstack/mcp.toml`, 1-based line number of the `allow =` / `deny =` entry.
    case configFile(line: Int)
    /// A `--allow` flag on the command line, 1-based across every `--allow` seen.
    case cliFlag(nth: Int)

    public var description: String {
        switch self {
        case .builtinReadOnly: return "default (read-only tools are always available)"
        case .configFile(let line): return "~/.morbstack/mcp.toml:\(line)"
        case .cliFlag(let nth): return "--allow flag #\(nth)"
        }
    }
}

/// One `allow` or `deny` line, resolved to the key it grants/denies and where it
/// came from.
public struct GrantEntry: Equatable, Sendable {
    public var key: String
    public var origin: GrantOrigin

    public init(key: String, origin: GrantOrigin) {
        self.key = key
        self.origin = origin
    }
}

// MARK: - Tool registration the resolver needs

/// The slice of a tool's identity the permission resolver needs to know about.
/// ``ToolSpec`` (Tools.swift) carries the rest — schema, handler, description.
public struct PermissionSubject: Sendable {
    public var name: String
    /// `nil` for read-only tools, which the resolver never gates.
    public var group: ToolGroup?
    /// Fully-qualified guard keys this tool defines, e.g.
    /// `"container_remove:force"`, `"prune:volumes"`, `"inspect:env"`. Each is
    /// checked independently of the tool's own grant or group — see
    /// ``PermissionProfile/decideGuardKey(_:)``.
    ///
    /// Most guards follow a `"<tool name>:<argument>"` convention, but that is a
    /// convention, not a rule the type enforces: `inspect:env` deliberately
    /// breaks it, because "reveal secrets during inspection" reads as its own
    /// named capability to a profile author, not as an argument of
    /// `container_inspect` — see the doc comment where it is defined
    /// (ReadOnlyTools.swift).
    public var guardKeys: [String]

    public init(name: String, group: ToolGroup?, guardKeys: [String] = []) {
        self.name = name
        self.group = group
        self.guardKeys = guardKeys
    }
}

// MARK: - Resolution result

/// The outcome of checking one key (a tool name or a `"tool:guard"` pair)
/// against a profile.
public struct PermissionDecision: Sendable {
    public var allowed: Bool
    /// The entry that granted it, when `allowed` is true from a grant (not the
    /// read-only default).
    public var allowedBy: GrantEntry?
    /// The entry that denied it, when present — a deny can be why `allowed` is
    /// false, or it can be a deny that lost to nothing (there was no matching
    /// allow) which is still worth surfacing so `morb mcp permissions` can say
    /// "denied, and also explicitly denied here".
    public var deniedBy: GrantEntry?

    /// A human-readable explanation, used both by `morb mcp permissions` and by
    /// the denial text a blocked `tools/call` returns to the agent.
    public var explanation: String
}

/// A resolved, queryable permission profile: everything `morb mcp serve` decided
/// at startup from `mcp.toml` plus `--allow` flags, frozen for the life of the
/// process so a single session behaves consistently even if the file on disk
/// changes underneath it.
public struct PermissionProfile: Sendable {
    public var allow: [GrantEntry]
    public var deny: [GrantEntry]
    /// Keys present in `allow`/`deny` that matched no known tool, group, guard,
    /// or `"all"` — almost always a typo, and a silently-ignored typo in a
    /// permission file is a bug that looks like security until someone reads
    /// the audit log and asks why nothing worked. Surfaced by both `serve`
    /// (stderr, at startup) and `permissions`.
    public var unknownKeys: [GrantEntry]

    /// Unknown keys that came from `deny`. These fail open, so `morb mcp serve`
    /// refuses to start when any exist.
    public var unknownDenyKeys: [GrantEntry] {
        let denyKeys = Set(deny.map(\.key))
        return unknownKeys.filter { denyKeys.contains($0.key) }
    }

    public init(allow: [GrantEntry], deny: [GrantEntry], unknownKeys: [GrantEntry] = []) {
        self.allow = allow
        self.deny = deny
        self.unknownKeys = unknownKeys
    }

    /// Whether any entry in `allow` grants the all-encompassing key, from any
    /// source. `serve` uses this to decide whether to print the startup warning.
    public var grantsAll: [GrantEntry] { allow.filter { $0.key == allGrantKey } }

    /// Decides whether `subject` (a whole tool, no argument guard involved) may run.
    public func decide(_ subject: PermissionSubject) -> PermissionDecision {
        guard let group = subject.group else {
            return PermissionDecision(
                allowed: true, allowedBy: nil, deniedBy: nil,
                explanation: GrantOrigin.builtinReadOnly.description)
        }
        return decideKey(exact: subject.name, group: group.rawValue, toolLabel: subject.name)
    }

    /// Decides whether a specific argument-level guard may be used. `key` is the
    /// guard's fully-qualified key, e.g. `"container_remove:force"` or
    /// `"inspect:env"`. Guards are deliberately not covered by the tool's own
    /// grant or its group — see the doc comment on ``PermissionSubject/guardKeys``
    /// and the guard list in the generated `mcp.toml` template for why each one
    /// exists.
    public func decideGuardKey(_ key: String) -> PermissionDecision {
        // No group fallback: a `containers:write` or even an exact `container_remove`
        // grant must not silently cover `force`. Only the qualified key itself, or
        // the deliberately-everything `all`, reaches this.
        return decideKey(exact: key, group: nil, toolLabel: key)
    }

    /// Shared precedence: an exact key match beats a group match beats `"all"`,
    /// for both allow and deny independently, and deny always wins the final
    /// answer. Precedence exists only to pick which single entry gets *cited* as
    /// the reason — several entries can all technically apply.
    private func decideKey(exact: String, group: String?, toolLabel: String) -> PermissionDecision {
        let candidates = [exact, group, allGrantKey].compactMap { $0 }
        let allowMatch = firstMatch(in: allow, candidates: candidates)
        let denyMatch = firstMatch(in: deny, candidates: candidates)
        let allowed = allowMatch != nil && denyMatch == nil

        let explanation: String
        if let denyMatch, allowMatch != nil {
            explanation = "denied: \(denyMatch.origin) denies `\(denyMatch.key)`, which overrides "
                + "the grant at \(allowMatch!.origin) (deny always wins)"
        } else if let denyMatch {
            explanation = "denied: \(denyMatch.origin) denies `\(denyMatch.key)`"
        } else if let allowMatch {
            explanation = "allowed by \(allowMatch.origin) (`\(allowMatch.key)`)"
        } else {
            explanation = "denied: no grant for `\(toolLabel)`. Add it to the `allow` list in "
                + "~/.morbstack/mcp.toml (see `morb mcp init`), or start the server with "
                + "`--allow \(toolLabel)`."
        }
        return PermissionDecision(allowed: allowed, allowedBy: allowMatch, deniedBy: denyMatch, explanation: explanation)
    }

    private func firstMatch(in entries: [GrantEntry], candidates: [String]) -> GrantEntry? {
        for candidate in candidates {
            if let hit = entries.first(where: { $0.key == candidate }) { return hit }
        }
        return nil
    }

    /// Builds a profile from parsed config-file entries plus CLI `--allow` flags.
    /// `--allow` is always additive to the file (the file can never be used to
    /// *remove* something a flag grants) — callers achieve that simply by
    /// concatenating file entries before CLI entries; ``decideKey`` only cares
    /// about set membership, not order, except for which single entry gets cited.
    public static func build(
        configAllow: [GrantEntry], configDeny: [GrantEntry], cliAllow: [GrantEntry],
        knownKeys: Set<String>
    ) -> PermissionProfile {
        let allow = configAllow + cliAllow
        let deny = configDeny
        let unknown = (allow + deny).filter { !knownKeys.contains($0.key) }
        return PermissionProfile(allow: allow, deny: deny, unknownKeys: unknown)
    }
}

/// The full set of keys a profile is allowed to mention: every tool name, every
/// group, every guard's qualified key, and `"all"`. Used to flag typos.
public func knownPermissionKeys(subjects: [PermissionSubject]) -> Set<String> {
    var keys: Set<String> = [allGrantKey]
    for group in ToolGroup.allCases { keys.insert(group.rawValue) }
    for subject in subjects {
        keys.insert(subject.name)
        keys.formUnion(subject.guardKeys)
    }
    return keys
}

// MARK: - mcp.toml parsing

/// The two arrays `mcp.toml` can define. A minimal, purpose-built reader rather
/// than a reuse of ``MorbConfig``'s TOML subset: that parser's key handling is
/// wired to `MorbConfig`'s own fixed field set (see `MorbstackKit/MorbConfig.swift`),
/// and forking it to recognise `allow`/`deny` instead would mean carrying a
/// second, unrelated schema inside a type named for VM configuration. The actual
/// parsing primitive — quoted, comma-separated strings inside `[...]`, with a
/// `#` comment stripped first — is small enough to own here outright.
public struct MCPConfigFile: Sendable {
    public var allow: [GrantEntry] = []
    public var deny: [GrantEntry] = []

    /// Loads and parses `url`. Returns an empty file (not an error) when nothing
    /// exists there yet — the zero-config, fully-denied state is a valid state,
    /// not a missing one.
    public static func load(from url: URL) throws -> MCPConfigFile {
        guard FileManager.default.fileExists(atPath: url.path) else { return MCPConfigFile() }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw MorbError.config("could not read \(url.path): \(error.localizedDescription)")
        }
        return try parse(text)
    }

    /// Parses the `allow`/`deny` subset. `allow` and `deny` may each appear more
    /// than once; occurrences accumulate rather than overwrite, so a profile can
    /// be written as one grant per commented line instead of one dense array —
    /// which is what makes `morb mcp permissions`' per-line provenance actually
    /// useful instead of every grant pointing at the same line number.
    public static func parse(_ text: String) throws -> MCPConfigFile {
        var file = MCPConfigFile()
        var lineNumber = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") { continue }  // section header: tolerated, ignored

            guard let equals = line.firstIndex(of: "=") else {
                throw MorbError.config("mcp.toml line \(lineNumber): expected `key = value`, got `\(line)`")
            }
            let key = line[line.startIndex..<equals].trimmingCharacters(in: .whitespaces)
            let rest = stripTrailingComment(String(line[line.index(after: equals)...]))
            switch key {
            case "allow":
                let entries = try parseStringArray(rest, line: lineNumber)
                file.allow.append(contentsOf: entries.map { GrantEntry(key: $0, origin: .configFile(line: lineNumber)) })
            case "deny":
                let entries = try parseStringArray(rest, line: lineNumber)
                file.deny.append(contentsOf: entries.map { GrantEntry(key: $0, origin: .configFile(line: lineNumber)) })
            default:
                continue  // forward compatibility, same policy as MorbConfig
            }
        }
        return file
    }

    private static func stripTrailingComment(_ fragment: String) -> String {
        var inString = false
        var escaped = false
        var result = ""
        for character in fragment {
            if escaped { result.append(character); escaped = false; continue }
            switch character {
            case "\\" where inString: result.append(character); escaped = true
            case "\"": inString.toggle(); result.append(character)
            case "#" where !inString: return result.trimmingCharacters(in: .whitespaces)
            default: result.append(character)
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func parseStringArray(_ raw: String, line: Int) throws -> [String] {
        let token = raw.trimmingCharacters(in: .whitespaces)
        guard token.hasPrefix("["), token.hasSuffix("]") else {
            throw MorbError.config(
                "mcp.toml line \(line): expected a single-line array like [\"containers:write\"], got `\(token)`")
        }
        let body = token.dropFirst().dropLast()

        var elements: [String] = []
        var current = ""
        var inString = false
        var escaped = false
        for character in body {
            if escaped { current.append(character); escaped = false; continue }
            switch character {
            case "\\" where inString: current.append(character); escaped = true
            case "\"": inString.toggle(); current.append(character)
            case "," where !inString: elements.append(current); current = ""
            default: current.append(character)
            }
        }
        if inString { throw MorbError.config("mcp.toml line \(line): unterminated string in array") }
        elements.append(current)

        var out: [String] = []
        for element in elements {
            let trimmed = element.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }  // trailing comma, or `[]`
            guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 else {
                throw MorbError.config("mcp.toml line \(line): array elements must be quoted strings, got `\(trimmed)`")
            }
            out.append(String(trimmed.dropFirst().dropLast()))
        }
        return out
    }
}

// MARK: - `--allow` flag parsing

public struct MCPArgumentError: Error, CustomStringConvertible, Equatable, Sendable {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// Parses repeated `--allow <key>` flags from a subcommand's residual arguments.
/// Any other argument is returned as an error string naming it, so `serve` can
/// fail fast on a typo'd flag instead of silently ignoring it.
public func parseAllowFlags(_ arguments: [String]) -> Result<[GrantEntry], MCPArgumentError> {
    var entries: [GrantEntry] = []
    var index = 0
    var nth = 0
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--allow" {
            guard index + 1 < arguments.count else {
                return .failure(MCPArgumentError("--allow requires a value, e.g. --allow containers:write"))
            }
            nth += 1
            entries.append(GrantEntry(key: arguments[index + 1], origin: .cliFlag(nth: nth)))
            index += 2
            continue
        }
        if argument.hasPrefix("--allow=") {
            nth += 1
            entries.append(GrantEntry(key: String(argument.dropFirst("--allow=".count)), origin: .cliFlag(nth: nth)))
            index += 1
            continue
        }
        return .failure(MCPArgumentError("unrecognized argument `\(argument)`"))
    }
    return .success(entries)
}
