// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Small pieces shared by more than one tool: parsing the Docker Engine API's
// newline-delimited JSON streams (`/events`, `/images/create`), path validation
// for tools that take a directory argument, and resolving the `docker compose`
// CLI plugin the way Morbstack's own setup script installs it.

import Foundation
import MorbFeatures

/// Feeds raw stream chunks in and yields complete JSON objects out, buffering
/// any partial line across calls. The Engine API delivers `/events` and
/// `/images/create` as one JSON object per line, but nothing guarantees a line
/// lands in a single TCP read — a line split across two chunks is routine on a
/// busy stream, not an edge case.
struct NDJSONBuffer {
    private var buffer = Data()

    mutating func feed(_ chunk: Data) -> [Any] {
        buffer.append(chunk)
        var objects: [Any] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if !lineData.isEmpty, let object = try? JSONSerialization.jsonObject(with: Data(lineData)) {
                objects.append(object)
            }
        }
        return objects
    }
}

// MARK: - Path validation

enum PathValidationError: Error, CustomStringConvertible {
    case notAbsolute(String)
    case containsDotDot(String)
    case doesNotExist(String)
    case notDirectory(String)

    var description: String {
        switch self {
        case .notAbsolute(let path): return "`\(path)` must be an absolute path"
        case .containsDotDot(let path): return "`\(path)` must not contain a \"..\" path segment"
        case .doesNotExist(let path): return "`\(path)` does not exist"
        case .notDirectory(let path): return "`\(path)` is not a directory"
        }
    }
}

/// Validates a directory argument for `compose_up`, `compose_down`, and
/// `image_build`'s build context.
///
/// Absolute-and-no-`..` is not primarily about sandbox escape (the shelled-out
/// `docker`/`docker compose` process has the same filesystem access this whole
/// process does either way) — it is about an agent being handed a tool whose
/// docstring says "project directory" and being unable to make it operate
/// somewhere other than the path it was plainly told, which is what a relative
/// path resolved against whatever `serve`'s current directory happens to be, or
/// a `..` climbing out of an intended project root, would allow.
func validateProjectDirectory(_ path: String) throws -> String {
    guard path.hasPrefix("/") else { throw PathValidationError.notAbsolute(path) }
    guard !path.split(separator: "/").contains(Substring("..")) else {
        throw PathValidationError.containsDotDot(path)
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
        throw PathValidationError.doesNotExist(path)
    }
    guard isDirectory.boolValue else { throw PathValidationError.notDirectory(path) }
    return path
}

// MARK: - docker compose resolution

/// Looks for the `docker compose` CLI plugin exactly where
/// `README.md`'s "Running" section documents installing it, plus the ordinary
/// `PATH` lookup for anyone who put a standalone `docker-compose` elsewhere.
///
/// Deliberately does *not* rely on the `docker compose` subcommand-plugin
/// resolution mechanism: that resolver looks under `$DOCKER_CONFIG/cli-plugins`,
/// and this server's shell-outs point `DOCKER_CONFIG` at its own scratch
/// directory (see ``ToolContext/shellOutEnvironment()``) rather than
/// `~/.docker` — exactly so a compose/build call can never read the user's real
/// registry credentials. Finding the plugin binary directly and invoking it as
/// a standalone program (which it fully supports; `docker-compose up` and
/// `docker compose up` run the same code) sidesteps that mismatch entirely.
func resolveComposeBinary() -> String? {
    let userPluginPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".docker/cli-plugins/docker-compose").path
    if FileManager.default.isExecutableFile(atPath: userPluginPath) { return userPluginPath }
    return Subprocess.which("docker-compose")
}

let composeMissingMessage = """
    docker compose is not installed for this host. This is a one-time step \
    documented in README.md under "Running", and the compose binary itself is \
    already fetched by scripts/fetch-guest-assets.sh — this only needs to be \
    linked into the docker CLI's plugin directory once:

      mkdir -p ~/.docker/cli-plugins
      ln -sf "$(pwd)/dist/host-bin/docker-compose" ~/.docker/cli-plugins/docker-compose
      docker compose version
    """

/// Splits an image reference into the `fromImage` and `tag` (or digest) query
/// parameters `POST /images/create` expects. Handles `name:tag`, `name@digest`,
/// and bare `name` (Docker defaults the tag to `latest` server-side).
func splitImageReference(_ reference: String) -> (fromImage: String, tag: String?) {
    if let atIndex = reference.lastIndex(of: "@") {
        return (String(reference[reference.startIndex..<atIndex]), String(reference[reference.index(after: atIndex)...]))
    }
    // A colon before the last "/" is a registry port (`host:5000/name`), not a
    // tag separator — only a colon after the last slash names a tag.
    let lastSlash = reference.lastIndex(of: "/")
    let searchStart = lastSlash.map { reference.index(after: $0) } ?? reference.startIndex
    if let colonIndex = reference[searchStart...].lastIndex(of: ":") {
        return (String(reference[reference.startIndex..<colonIndex]), String(reference[reference.index(after: colonIndex)...]))
    }
    return (reference, nil)
}

// MARK: - Secret redaction for inspect and logs

/// Redacts the parts of a `container_inspect` document that routinely carry
/// secrets, so the always-available default reveals *shape* (which variables
/// are set, how long each value is) without revealing the values themselves.
///
/// This exists because "read-only" and "safe to hand to an untrusted prompt"
/// are not the same property: `Config.Env` is where `DATABASE_URL`,
/// `AWS_SECRET_ACCESS_KEY` and every other container credential typically
/// lives, and a tool that can only *look* is still a full secrets exfiltration
/// path if what it looks at includes those values. See docs/mcp.md's threat
/// model for the fuller argument; the `inspect:env` guard is what opts back
/// into the unredacted document.
func redactedInspect(_ raw: [String: Any]) -> [String: Any] {
    var result = raw
    if var config = result["Config"] as? [String: Any] {
        if let env = config["Env"] as? [Any] {
            config["Env"] = env.map { entry -> String in
                guard let string = entry as? String, let equals = string.firstIndex(of: "=") else {
                    return "\(entry)"
                }
                let name = string[string.startIndex..<equals]
                let valueLength = string[string.index(after: equals)...].utf8.count
                return "\(name)=<redacted:\(valueLength) chars>"
            }
        }
        if let labels = config["Labels"] as? [String: Any] {
            config["Labels"] = Redactor.redact(labels)
        }
        result["Config"] = config
    }
    if let mounts = result["Mounts"] as? [Any] {
        result["Mounts"] = mounts.map { Redactor.redact($0) }
    }
    result["_morbstack_mcp"] = [
        "secrets_redacted": true,
        "reveal_with": "call again with reveal_secrets:true, which requires the `inspect:env` grant",
    ]
    return result
}

/// A best-effort scrubber for high-confidence secret shapes in free-text log
/// output: AWS access key ids, bearer tokens, and `scheme://user:pass@host`
/// credentials embedded in a connection string.
///
/// This is explicitly a seatbelt, not a boundary — read that as a warning, not
/// reassurance. Log lines are unstructured text an application chose to write;
/// no fixed set of regular expressions catches every shape a secret can take,
/// and this one does not try to. It exists to stop the *routine* case (an app
/// logging its own connection string or an SDK logging its bearer token at
/// debug level) from being handed to an agent by a tool with no grant at all,
/// not to make `container_logs` safe against a container that logs secrets in
/// some other form. `docs/mcp.md` says this plainly; do not read the presence
/// of this function as "logs are sanitized".
enum LogRedactor {
    private static let patterns: [(regex: NSRegularExpression, template: String)] = [
        // AWS access key ids: fixed `AKIA`/`ASIA` prefix plus 16 base32 characters.
        try! (NSRegularExpression(pattern: #"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#), "$1****REDACTED_AWS_KEY****"),
        // `Authorization: Bearer <token>` and bare `Bearer <token>` mentions.
        try! (NSRegularExpression(pattern: #"(?i)\bBearer\s+[A-Za-z0-9\-_\.=]{10,}"#), "Bearer <redacted>"),
        // `scheme://user:password@host` connection strings; the username and
        // scheme are kept because they carry debugging value the password does not.
        try! (
            NSRegularExpression(pattern: #"([a-zA-Z][a-zA-Z0-9+.\-]*://)([^/\s:@]+):([^/\s@]+)@"#),
            "$1$2:<redacted>@"),
        // `key = value` / `key: "value"` where the key name looks credential-shaped.
        try! (
            NSRegularExpression(
                pattern: #"(?i)\b([\w\-]*(?:password|passwd|secret|token|api[_\-]?key)[\w\-]*)\s*[:=]\s*"?([^\s"'&]{6,})"?"#),
            "$1=<redacted>"),
    ]

    static func redact(_ text: String) -> String {
        var result = text
        for (regex, template) in patterns {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
        }
        return result
    }
}

/// Renders a `CommandResult` from a shelled-out `docker`/`docker compose` run
/// as a tool result, with output capped so a runaway build log cannot blow past
/// what an agent's context window (or this server's stdout pipe) should carry.
func shellCommandResult(action: String, result: CommandResult) -> ToolCallResult {
    let cap = 20_000
    let payload: [String: Any] = [
        "action": action,
        "command": result.commandLine,
        "exit_code": result.exitCode,
        "timed_out": result.timedOut,
        "stdout": Format.truncate(result.stdoutText, cap),
        "stderr": Format.truncate(result.stderrText, cap),
    ]
    return .text(payload, isError: !result.succeeded)
}
