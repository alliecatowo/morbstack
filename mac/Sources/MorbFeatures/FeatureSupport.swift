// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Small shared pieces: table rendering, JSON reading, byte formatting, and the
// on-disk locations the new feature modules use.

import Foundation
import MorbstackKit

// MARK: - Paths

/// Where the feature modules keep their state.
///
/// All under `MorbPaths.root`, so `MORBSTACK_HOME` redirects them together with
/// everything else and a throwaway stack stays genuinely throwaway.
public enum MorbFeaturePaths {

    /// `~/.morbstack/mcp.toml` — the MCP permission profile.
    public static var mcpConfig: URL { MorbPaths.root.appendingPathComponent("mcp.toml", isDirectory: false) }

    /// `~/.morbstack/logs/mcp-audit.jsonl` — one JSON object per MCP tool invocation.
    public static var mcpAuditLog: URL {
        MorbPaths.root.appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("mcp-audit.jsonl", isDirectory: false)
    }

    /// `~/.morbstack/bench/` — benchmark run records, one JSON file per run.
    public static var benchDirectory: URL { MorbPaths.root.appendingPathComponent("bench", isDirectory: true) }

    /// `~/.morbstack/migrate/` — migration reports and manifests.
    public static var migrateDirectory: URL { MorbPaths.root.appendingPathComponent("migrate", isDirectory: true) }

    /// Creates a directory if it is missing, ignoring "already exists".
    @discardableResult
    public static func ensureDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil
            || FileManager.default.fileExists(atPath: url.path)
    }
}

// MARK: - JSON reading

/// Type-narrowing accessors for `JSONSerialization` output.
///
/// The Docker Engine API's documents are wide, deeply optional and inconsistently
/// capitalised across endpoints; modelling all of them as `Codable` structs would be
/// a large amount of code that mostly exists to be wrong about one field. These
/// helpers read the handful of fields each feature actually needs and return `nil`
/// rather than throwing, because "the engine did not include `SizeRootFs`" is
/// routinely a normal answer.
public enum JSONRead {

    public static func string(_ object: Any?, _ key: String) -> String? {
        guard let dictionary = object as? [String: Any] else { return nil }
        if let value = dictionary[key] as? String { return value }
        if let value = dictionary[key] as? NSNumber { return value.stringValue }
        return nil
    }

    public static func int(_ object: Any?, _ key: String) -> Int? {
        guard let dictionary = object as? [String: Any] else { return nil }
        if let value = dictionary[key] as? NSNumber { return value.intValue }
        if let value = dictionary[key] as? String { return Int(value) }
        return nil
    }

    public static func double(_ object: Any?, _ key: String) -> Double? {
        guard let dictionary = object as? [String: Any] else { return nil }
        if let value = dictionary[key] as? NSNumber { return value.doubleValue }
        if let value = dictionary[key] as? String { return Double(value) }
        return nil
    }

    public static func bool(_ object: Any?, _ key: String) -> Bool? {
        guard let dictionary = object as? [String: Any] else { return nil }
        if let value = dictionary[key] as? NSNumber { return value.boolValue }
        return nil
    }

    public static func array(_ object: Any?, _ key: String) -> [Any]? {
        (object as? [String: Any])?[key] as? [Any]
    }

    public static func dictionary(_ object: Any?, _ key: String) -> [String: Any]? {
        (object as? [String: Any])?[key] as? [String: Any]
    }

    public static func strings(_ object: Any?, _ key: String) -> [String] {
        (array(object, key) as? [String]) ?? []
    }

    /// Pretty-prints a JSON-serialisable value with stable key ordering.
    public static func pretty(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    /// Compact single-line JSON, for log records.
    public static func compact(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}

// MARK: - Formatting

public enum Format {

    /// `1.2 GB`, decimal units — the same units `docker system df` prints, so the two
    /// can be compared without a conversion step in the reader's head.
    public static func bytes(_ count: Int64) -> String {
        let units = ["B", "kB", "MB", "GB", "TB", "PB"]
        var value = Double(count)
        var index = 0
        while abs(value) >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        if index == 0 { return "\(count) B" }
        return String(format: "%.1f %@", value, units[index])
    }

    /// `1.234s`, `812ms`, `3m 12s` — chosen by magnitude so a table of timings stays
    /// readable when the entries span four orders of magnitude, which benchmark
    /// tables always do.
    public static func duration(_ seconds: Double) -> String {
        if seconds.isNaN || seconds.isInfinite { return "-" }
        if seconds < 1 { return String(format: "%.0fms", seconds * 1000) }
        if seconds < 60 { return String(format: "%.3fs", seconds) }
        let minutes = Int(seconds) / 60
        let remainder = seconds - Double(minutes * 60)
        return String(format: "%dm %.1fs", minutes, remainder)
    }

    /// An ISO-8601 timestamp in UTC, second precision.
    public static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Truncates to `limit` characters with a trailing ellipsis.
    public static func truncate(_ text: String, _ limit: Int) -> String {
        guard text.count > limit, limit > 1 else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }
}

/// A fixed-width text table.
///
/// Every feature here prints one, and every ad-hoc implementation of one gets the
/// same two things wrong: a column sized to the header rather than the widest cell,
/// and a trailing run of spaces on the last column that makes `diff` noisy in the
/// docs.
public struct TextTable {

    public var headers: [String]
    public var rows: [[String]] = []
    /// Columns whose contents are right-aligned, by index. Numbers read better that way.
    public var rightAligned: Set<Int>

    public init(headers: [String], rightAligned: Set<Int> = []) {
        self.headers = headers
        self.rightAligned = rightAligned
    }

    public mutating func add(_ row: [String]) { rows.append(row) }

    public func render(indent: String = "  ") -> String {
        let all = [headers] + rows
        let columnCount = all.map(\.count).max() ?? 0
        var widths = [Int](repeating: 0, count: columnCount)
        for row in all {
            for (index, cell) in row.enumerated() {
                widths[index] = max(widths[index], cell.count)
            }
        }
        func format(_ row: [String]) -> String {
            var parts: [String] = []
            for index in 0..<columnCount {
                let cell = index < row.count ? row[index] : ""
                let padding = String(repeating: " ", count: max(0, widths[index] - cell.count))
                parts.append(rightAligned.contains(index) ? padding + cell : cell + padding)
            }
            // Trailing whitespace serves nobody and shows up in every diff.
            return (indent + parts.joined(separator: "  "))
                .replacingOccurrences(of: "[ ]+$", with: "", options: .regularExpression)
        }
        var lines = [format(headers)]
        lines.append(indent + widths.map { String(repeating: "-", count: $0) }.joined(separator: "  "))
        lines.append(contentsOf: rows.map(format))
        return lines.joined(separator: "\n")
    }
}
