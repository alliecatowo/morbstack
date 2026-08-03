// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The MCP audit log: one JSON object per line, appended to
// `~/.morbstack/logs/mcp-audit.jsonl` for every `tools/call` the server sees —
// granted or denied — plus server start/stop bookends.
//
// What this log proves and does not prove matters, so it is written down here
// rather than left to be inferred: it proves that this process, running with
// this grant set, received a request to run this tool with these arguments and
// reached this outcome. It does not prove the *agent's* intent, and it cannot
// prove the request came from the human sitting at the keyboard rather than
// from a prompt-injected instruction the agent followed in good faith — the
// trust boundary for that is the MCP client, not this server. See docs/mcp.md
// for the full threat model.

import Darwin
import Foundation
import MorbFeatures
import MorbstackKit

/// Redacts values under keys that look like credentials, so an audit log that
/// exists to help debug "why did the agent do that" does not itself become a
/// second place secrets leak from.
public enum Redactor {

    /// Substrings matched case-insensitively against argument keys. Deliberately
    /// broad — "key" alone catches `api_key`, `ssh_key`, and plenty of harmless
    /// names too, but an audit log that over-redacts is merely less convenient to
    /// read; one that under-redacts has already done the damage.
    private static let sensitiveSubstrings = ["password", "token", "secret", "key", "auth"]

    /// Redacts `value` recursively. `key` is the JSON key `value` was found
    /// under in its parent object, `nil` at the root.
    public static func redact(_ value: Any, key: String? = nil) -> Any {
        if let dictionary = value as? [String: Any] {
            // An `env` map is redacted wholesale rather than per-name: secrets in
            // environment variables live under names a keyword list will never
            // fully anticipate (`DATABASE_URL`, `NPM_TOKEN`, a bespoke deploy
            // credential), and every one of those values is exactly as sensitive
            // as the ones the substring list happens to catch.
            if let key, key.lowercased() == "env" {
                return dictionary.mapValues { _ in "[redacted]" }
            }
            var out: [String: Any] = [:]
            for (dictionaryKey, dictionaryValue) in dictionary {
                out[dictionaryKey] = looksSensitive(dictionaryKey)
                    ? "[redacted]" : redact(dictionaryValue, key: dictionaryKey)
            }
            return out
        }
        if let array = value as? [Any] {
            return array.map { redact($0, key: key) }
        }
        return value
    }

    private static func looksSensitive(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return sensitiveSubstrings.contains { lowered.contains($0) }
    }
}

/// Appends newline-delimited JSON audit records to disk.
///
/// Every write is `fsync`'d before returning: an audit log that a crash can
/// silently truncate is not an audit log, it is a debugging convenience that
/// happens to usually work. The cost — one syscall per tool call — is
/// irrelevant next to the multi-millisecond Docker Engine API round trip every
/// audited action already makes.
public final class AuditLog {
    private var fileDescriptor: Int32 = -1
    public let url: URL

    public init(url: URL = MorbFeaturePaths.mcpAuditLog) throws {
        self.url = url
        MorbFeaturePaths.ensureDirectory(url.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: url.path) {
            let created = FileManager.default.createFile(
                atPath: url.path, contents: nil,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o600))])
            guard created else {
                throw MorbError.io("could not create audit log at \(url.path)")
            }
        } else {
            // Re-assert 0600 on an existing file: a log that started under a
            // looser umask, or was copied in from somewhere else, should not go
            // on being world-readable just because this run didn't create it.
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
        }
        let fd = open(url.path, O_WRONLY | O_APPEND, 0o600)
        guard fd >= 0 else {
            throw MorbError.io("could not open audit log at \(url.path): \(String(cString: strerror(errno)))")
        }
        self.fileDescriptor = fd
    }

    deinit {
        if fileDescriptor >= 0 { close(fileDescriptor) }
    }

    /// Appends one record. Failures to serialise or write are swallowed rather
    /// than thrown: a tool call that already succeeded or failed on its own
    /// terms must not be re-reported to the MCP client as broken because the
    /// *logging* of it hit a snag. The record is still lost, which is a real
    /// gap — see docs/mcp.md's limitations section.
    public func append(_ record: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(record),
              var data = try? JSONSerialization.data(
                withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return }
        data.append(0x0A)
        guard fileDescriptor >= 0 else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var remaining = raw.count
            var pointer = base
            while remaining > 0 {
                let written = write(fileDescriptor, pointer, remaining)
                if written <= 0 { break }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
        fsync(fileDescriptor)
    }

    // MARK: - Record builders

    /// Records one `tools/call` outcome.
    public func recordToolCall(
        tool: String, decision: PermissionDecision, arguments: [String: Any],
        durationMS: Double, ok: Bool, resultSummary: String
    ) {
        let cappedArguments = capped(Redactor.redact(arguments))
        var record: [String: Any] = [
            "ts": Format.timestamp(),
            "kind": "tool_call",
            "tool": tool,
            "decision": decision.allowed ? "allowed" : "denied",
            "arguments": cappedArguments,
            "duration_ms": (durationMS * 100).rounded() / 100,
            "ok": ok,
            "result_summary": Format.truncate(resultSummary, 500),
        ]
        if !decision.allowed { record["reason"] = decision.explanation }
        append(record)
    }

    /// Records the server coming up, with the effective grant set — so the log
    /// itself answers "what was this session permitted to do", not just "what
    /// did it try to do".
    public func recordServerStart(allow: [GrantEntry], deny: [GrantEntry], warnings: [String]) {
        append([
            "ts": Format.timestamp(),
            "kind": "server_start",
            "allow": allow.map { "\($0.key) (\($0.origin))" },
            "deny": deny.map { "\($0.key) (\($0.origin))" },
            "warnings": warnings,
        ])
    }

    public func recordServerStop() {
        append(["ts": Format.timestamp(), "kind": "server_stop"])
    }

    /// Renders `value` as compact JSON and truncates it to `limit` bytes-ish
    /// (character count, which is close enough for a debugging aid and avoids
    /// splitting multi-byte UTF-8 the way a byte-count truncation would).
    private func capped(_ value: Any, limit: Int = 4096) -> Any {
        let compact = JSONRead.compact(wrapIfNeeded(value))
        guard compact.count > limit else { return value }
        return ["_truncated": true, "_original_size": compact.count, "_preview": Format.truncate(compact, limit)]
    }

    /// `JSONRead.compact` requires a valid top-level JSON object or array;
    /// arguments are always a dictionary in practice, but this keeps the helper
    /// honest if that ever changes.
    private func wrapIfNeeded(_ value: Any) -> Any {
        if JSONSerialization.isValidJSONObject(value) { return value }
        return ["value": value]
    }

    // MARK: - Reading, for `morb mcp audit`

    /// Reads every well-formed record in file order. Malformed lines (there
    /// should never be any, given `append` always fsyncs a complete line) are
    /// skipped rather than aborting the read, so one corrupted record — e.g.
    /// from a `kill -9` mid-write — does not hide every record around it.
    public func readAll() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        var records: [[String: Any]] = []
        for lineData in data.split(separator: 0x0A) {
            guard !lineData.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any]
            else { continue }
            records.append(object)
        }
        return records
    }
}
