// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The data model `morb scan` operates on, and the pure logic (severity ordering,
// the `--fail-on` decision, grype's JSON parsed into something this module owns)
// that the rest of the feature is built on. Kept separate from anything that talks
// to a socket or spawns a process so it can be unit tested without either.

import Foundation

// MARK: - Severity

/// A grype/NVD-style severity, ordered the same way grype's own `--fail-on` flag
/// orders them: `negligible < low < medium < high < critical`.
///
/// `unknown` exists because grype does report it (a match whose vulnerability record
/// has no severity assigned at all — not rare for a fresh CVE) but it is deliberately
/// kept **out** of the ordered comparison grype's `--fail-on` performs: an unscored
/// finding is not known to be *at or above* any threshold, so treating it as such
/// would fail builds on data absence rather than on a scored risk. Verified against
/// grype's own behaviour by running `grype --fail-on negligible` against a fixture
/// containing only an "Unknown" match and confirming the exit code stayed 0.
public enum Severity: String, CaseIterable, Sendable {
    case unknown = "Unknown"
    case negligible = "Negligible"
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case critical = "Critical"

    /// Parses grype's severity string, which is capitalized (`"High"`) but is matched
    /// case-insensitively here since nothing in the Engine API/grype contract
    /// guarantees that will never change.
    public init(raw: String) {
        self = Severity.allCases.first { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame } ?? .unknown
    }

    /// Parses a `--fail-on` argument. Case-insensitive, `nil` for anything that is
    /// not one of grype's own five ordered levels — `unknown` is deliberately not a
    /// valid threshold, the same way it is not a valid value for grype's own flag.
    public init?(failOnArgument raw: String) {
        switch raw.lowercased() {
        case "negligible": self = .negligible
        case "low": self = .low
        case "medium": self = .medium
        case "high": self = .high
        case "critical": self = .critical
        default: return nil
        }
    }

    /// Position in the ordering used for `--fail-on` and for sorting the findings
    /// table worst-first. `unknown` sorts below `negligible` — it is not "less risky
    /// than negligible", it is simply excluded from the ordered comparison entirely
    /// (see ``meetsOrExceeds(_:)``) and has to sort *somewhere* for a stable table.
    var rank: Int {
        switch self {
        case .unknown: return 0
        case .negligible: return 1
        case .low: return 2
        case .medium: return 3
        case .high: return 4
        case .critical: return 5
        }
    }

    /// `true` when `self` is at or above `threshold` in the ordered severities —
    /// the `--fail-on` predicate. `unknown` never meets any threshold, including
    /// `--fail-on negligible`.
    public func meetsOrExceeds(_ threshold: Severity) -> Bool {
        guard self != .unknown else { return false }
        return rank >= threshold.rank
    }
}

extension Severity: Comparable {
    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
}

// MARK: - Findings

/// One `package + vulnerability` match from grype's report — the fields the summary
/// table and `--fail-on` decision need, not the full grype schema (which also
/// carries CVSS vectors, descriptions, and match provenance `morb scan`'s human
/// output has no use for; `--json` re-emits grype's own document verbatim for
/// anyone who wants that).
public struct Finding: Equatable, Sendable {
    public var vulnerabilityID: String
    public var packageName: String
    public var packageVersion: String
    public var severity: Severity
    /// Versions grype says fix this; empty when none is known yet.
    public var fixedVersions: [String]
    /// grype's fix state: `"fixed"`, `"not-fixed"`, `"unknown"`, or `"wont-fix"`.
    public var fixState: String

    public init(
        vulnerabilityID: String, packageName: String, packageVersion: String,
        severity: Severity, fixedVersions: [String], fixState: String
    ) {
        self.vulnerabilityID = vulnerabilityID
        self.packageName = packageName
        self.packageVersion = packageVersion
        self.severity = severity
        self.fixedVersions = fixedVersions
        self.fixState = fixState
    }

    /// `"1.2.3, 1.2.4"`, or `"-"` when grype has no fix on record.
    public var fixedInDisplay: String {
        fixedVersions.isEmpty ? "-" : fixedVersions.joined(separator: ", ")
    }
}

public enum ScanParseError: Error, CustomStringConvertible {
    case malformed(String)
    public var description: String {
        switch self {
        case .malformed(let m): return "could not read grype's output: \(m)"
        }
    }
}

/// Parses grype's `-o json` document into ``Finding`` values.
///
/// grype's schema is a top-level object with a `matches` array; each match nests a
/// `vulnerability` object (id, severity, optional `fix`) and an `artifact` object
/// (name, version). Read with `JSONSerialization` rather than `Codable`, matching
/// this codebase's existing convention for Docker/anchore documents that are wide
/// and only partially needed (see `JSONRead` in MorbFeatures) — modelling grype's
/// entire schema as `Codable` structs would be a lot of code that exists mainly to
/// be wrong about some field this feature never reads.
public enum GrypeReport {

    public static func parseFindings(_ data: Data) throws -> [Finding] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ScanParseError.malformed("not a JSON object")
        }
        guard let matches = root["matches"] as? [[String: Any]] else {
            throw ScanParseError.malformed("no \"matches\" array")
        }
        return matches.compactMap(parseMatch)
    }

    /// `nil` for a match missing the handful of fields this feature actually reads —
    /// dropped rather than failing the whole scan, since grype's schema has grown
    /// fields before and a scan that surfaces 119 of 121 findings is far more useful
    /// than one that refuses to run at all over two odd entries.
    private static func parseMatch(_ match: [String: Any]) -> Finding? {
        guard let vulnerability = match["vulnerability"] as? [String: Any],
            let id = vulnerability["id"] as? String,
            let artifact = match["artifact"] as? [String: Any],
            let name = artifact["name"] as? String
        else { return nil }

        let version = artifact["version"] as? String ?? ""
        let severity = Severity(raw: vulnerability["severity"] as? String ?? "")

        var fixedVersions: [String] = []
        var fixState = "unknown"
        if let fix = vulnerability["fix"] as? [String: Any] {
            fixState = fix["state"] as? String ?? "unknown"
            fixedVersions = (fix["versions"] as? [String]) ?? []
        }

        return Finding(
            vulnerabilityID: id, packageName: name, packageVersion: version,
            severity: severity, fixedVersions: fixedVersions, fixState: fixState)
    }
}

// MARK: - Summary

/// Counts and a worst-first ordering over a set of findings — what `morb scan`'s
/// human-readable summary is built from.
public struct ScanSummary: Sendable {
    public var findings: [Finding]

    public init(findings: [Finding]) {
        self.findings = findings
    }

    /// Counts keyed by severity, in display order (critical first).
    public var countsBySeverity: [(severity: Severity, count: Int)] {
        let order: [Severity] = [.critical, .high, .medium, .low, .negligible, .unknown]
        return order.compactMap { severity in
            let count = findings.filter { $0.severity == severity }.count
            return count > 0 ? (severity, count) : nil
        }
    }

    public var total: Int { findings.count }

    /// The findings worth printing in the human summary table, worst severity first
    /// and then alphabetically by vulnerability id within a severity so re-running a
    /// scan against the same image produces a stable diff.
    ///
    /// - Parameter limit: caps the table length; `nil` prints everything. The
    ///   default CLI path caps this because an old base image can have hundreds of
    ///   matches and a wall of text is not a summary.
    public func worstFindings(limit: Int?) -> [Finding] {
        let sorted = findings.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            return lhs.vulnerabilityID < rhs.vulnerabilityID
        }
        guard let limit else { return sorted }
        return Array(sorted.prefix(limit))
    }

    /// The `--fail-on` decision: `true` when any finding is at or above `threshold`.
    public func shouldFail(on threshold: Severity) -> Bool {
        findings.contains { $0.severity.meetsOrExceeds(threshold) }
    }
}
