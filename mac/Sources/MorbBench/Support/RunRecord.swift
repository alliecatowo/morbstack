// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The persisted shape of one `morb bench` invocation. Everything a benchmark
// produces funnels into a ``BenchResult``, and every run's results plus its
// ``RunMetadata`` funnel into one ``RunRecord`` written to
// `~/.morbstack/bench/<timestamp>-<id>.json`. `morb bench compare` reads two
// of these back; nothing else in the harness needs a bespoke file format.

import Foundation
import MorbFeatures
import MorbstackKit

/// The outcome of running exactly one named benchmark.
public struct BenchResult: Codable, Equatable, Sendable {
    public var name: String
    public var verdict: Verdict
    /// One line, always present, suitable for the default table's rightmost column.
    public var summary: String
    /// The number ``verdict`` and `compare` are computed from — already
    /// converted into the target's unit (seconds, percent, wakeups/s, bytes,
    /// or a bare ratio). `nil` for a SKIPPED benchmark.
    public var primaryValue: Double?
    public var unit: String?
    /// The full spread, when the benchmark repeats a timing (cold-boot,
    /// resume). `nil` for single-shot measurements like host-rss.
    public var distribution: Distribution?
    public var targetGoal: Double?
    public var deltaPercent: Double?
    /// Present only when ``verdict`` is ``Verdict/skipped``.
    public var skippedReason: String?
    /// Anything worth saying that does not fit the fields above — the
    /// resume-is-a-degraded-cold-boot note, "measured via a container
    /// reading /proc/meminfo", etc.
    public var notes: [String]
    /// What this benchmark created on disk or in the engine, stated before
    /// creation and repeated here for the record — the honesty check for
    /// "did it actually clean up".
    public var createdArtifacts: [String]
    /// Anything else worth keeping that is not the primary value — e.g. both
    /// legs of a ratio benchmark, or per-process breakdowns.
    public var metrics: [String: AnyCodableValue]
    public var durationSeconds: Double

    public init(
        name: String, verdict: Verdict, summary: String, primaryValue: Double? = nil, unit: String? = nil,
        distribution: Distribution? = nil, targetGoal: Double? = nil, deltaPercent: Double? = nil,
        skippedReason: String? = nil, notes: [String] = [], createdArtifacts: [String] = [],
        metrics: [String: AnyCodableValue] = [:], durationSeconds: Double
    ) {
        self.name = name
        self.verdict = verdict
        self.summary = summary
        self.primaryValue = primaryValue
        self.unit = unit
        self.distribution = distribution
        self.targetGoal = targetGoal
        self.deltaPercent = deltaPercent
        self.skippedReason = skippedReason
        self.notes = notes
        self.createdArtifacts = createdArtifacts
        self.metrics = metrics
        self.durationSeconds = durationSeconds
    }

    /// Builds a SKIPPED result — the one constructor every benchmark reaches
    /// for the moment it cannot honestly produce a number.
    public static func skipped(name: String, reason: String, notes: [String] = []) -> BenchResult {
        BenchResult(
            name: name, verdict: .skipped, summary: "SKIPPED — \(reason)", skippedReason: reason,
            notes: notes, durationSeconds: 0)
    }

    /// Builds a result from a target comparison, filling in verdict/delta consistently.
    public static func measured(
        name: String, value: Double, target: Target?, summary: String, distribution: Distribution? = nil,
        notes: [String] = [], createdArtifacts: [String] = [], metrics: [String: AnyCodableValue] = [:],
        durationSeconds: Double
    ) -> BenchResult {
        guard let target else {
            return BenchResult(
                name: name, verdict: .notApplicable, summary: summary, primaryValue: value,
                distribution: distribution, notes: notes, createdArtifacts: createdArtifacts,
                metrics: metrics, durationSeconds: durationSeconds)
        }
        let (verdict, delta) = target.evaluate(value)
        return BenchResult(
            name: name, verdict: verdict, summary: summary, primaryValue: value, unit: target.unit,
            distribution: distribution, targetGoal: target.goal, deltaPercent: delta, notes: notes,
            createdArtifacts: createdArtifacts, metrics: metrics, durationSeconds: durationSeconds)
    }
}

/// One complete `morb bench` invocation, as written to disk.
public struct RunRecord: Codable, Equatable, Sendable {
    public var id: String
    /// ISO-8601, UTC, second precision — see ``Format/timestamp(_:)``.
    public var timestamp: String
    public var morbstackVersion: String
    public var metadata: RunMetadata
    /// The exact parameters this run used (runs=N, window=Ns, --only=...),
    /// so a MISS can be checked against the same conditions that produced it.
    public var parameters: [String: String]
    public var results: [BenchResult]

    public init(
        id: String = RunRecord.newID(), timestamp: String = Format.timestamp(), metadata: RunMetadata,
        parameters: [String: String], results: [BenchResult]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.morbstackVersion = metadata.morbstackVersion
        self.metadata = metadata
        self.parameters = parameters
        self.results = results
    }

    public static func newID() -> String {
        String(format: "%06x", UInt32.random(in: 0..<0xFFFFFF))
    }

    /// The filesystem-safe name this run is stored under: the timestamp with
    /// `:` replaced (APFS accepts colons but Finder mangles them into `/`,
    /// which makes the file impossible to reference by eye) plus the id.
    public var filenameStem: String {
        "\(timestamp.replacingOccurrences(of: ":", with: "-"))-\(id)"
    }
}

/// Reading and writing run records under ``MorbFeaturePaths/benchDirectory``.
public enum BenchStorage {

    @discardableResult
    public static func save(_ record: RunRecord) throws -> URL {
        MorbFeaturePaths.ensureDirectory(MorbFeaturePaths.benchDirectory)
        let url = MorbFeaturePaths.benchDirectory.appendingPathComponent("\(record.filenameStem).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
        return url
    }

    /// Every stored run, newest first.
    public static func listAll() -> [(url: URL, record: RunRecord)] {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: MorbFeaturePaths.benchDirectory, includingPropertiesForKeys: nil)
        else { return [] }
        let decoder = JSONDecoder()
        var out: [(URL, RunRecord)] = []
        for url in entries where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let record = try? decoder.decode(RunRecord.self, from: data)
            else { continue }
            out.append((url, record))
        }
        return out.sorted { $0.1.timestamp > $1.1.timestamp }
    }

    /// Resolves a `compare` token: an on-disk path, an id/timestamp prefix, or
    /// the special tokens `latest`/`previous` (the two newest runs).
    public static func resolve(_ token: String) throws -> RunRecord {
        if FileManager.default.fileExists(atPath: token) {
            let data = try Data(contentsOf: URL(fileURLWithPath: token))
            return try JSONDecoder().decode(RunRecord.self, from: data)
        }
        let all = listAll()
        switch token {
        case "latest":
            guard let first = all.first else { throw BenchError.noRuns }
            return first.record
        case "previous":
            guard all.count > 1 else { throw BenchError.notEnoughRuns }
            return all[1].record
        default:
            if let match = all.first(where: { $0.record.id == token || $0.record.filenameStem.contains(token) }) {
                return match.record
            }
            throw BenchError.unknownRun(token)
        }
    }
}

public enum BenchError: Error, CustomStringConvertible {
    case noRuns
    case notEnoughRuns
    case unknownRun(String)

    public var description: String {
        switch self {
        case .noRuns: return "no stored runs in \(MorbFeaturePaths.benchDirectory.path)"
        case .notEnoughRuns: return "need at least two stored runs to resolve `previous`"
        case .unknownRun(let token): return "no run matches `\(token)` — try a file path, an id, or `latest`"
        }
    }
}
