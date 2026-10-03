// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The command surface for `morb bench`.  This deliberately has no implicit
// measurement mode: `list`, `history`, and `compare` are read-only, while a
// person must spell `run` before a benchmark can observe, pull, stop, start,
// suspend, or resume anything.

import Foundation
import MorbFeatures
import MorbstackKit

enum BenchCLI {

    // MARK: - Registry

    /// Keep the registry here rather than deriving it from `Targets.all`. A
    /// published target is not automatically a working measurement — `list`
    /// would show every row as available even for a target whose
    /// implementation was silently dropped, which is exactly the gap this
    /// separate registry exists to keep visible.
    private static let benchmarks: [any Benchmark] = [
        ColdBootBenchmark(),
        ResumeBenchmark(),
        IdleCPUBenchmark(),
        IdleWakeupsBenchmark(),
        HostRSSBenchmark(),
        GuestMemoryFloorBenchmark(),
        GitStatusBindmountBenchmark(),
        NpmInstallBindmountVsVolumeBenchmark(),
    ]

    private static var benchmarksByName: [String: any Benchmark] {
        Dictionary(uniqueKeysWithValues: benchmarks.map { ($0.name, $0) })
    }

    // MARK: - Dispatch

    static func run(_ arguments: [String], json: Bool) -> Int32 {
        guard let command = arguments.first else {
            printUsage(to: json ? .standardError : .standardOutput)
            return json ? 2 : 0
        }

        let commandArguments = Array(arguments.dropFirst())
        switch command {
        case "help", "--help", "-h":
            guard commandArguments.isEmpty else { return usageError("help does not take additional arguments") }
            printUsage()
            return 0
        case "list":
            guard commandArguments.isEmpty else { return usageError("list does not take arguments") }
            return list(json: json)
        case "run":
            return runBenchmarks(arguments: commandArguments, json: json)
        case "history":
            return history(arguments: commandArguments, json: json)
        case "compare":
            return compare(arguments: commandArguments, json: json)
        default:
            return usageError("unknown subcommand `\(command)`")
        }
    }

    // MARK: - list

    private static func list(json: Bool) -> Int32 {
        let byName = benchmarksByName
        let rows = Targets.all.map { target -> BenchmarkListRow in
            if let benchmark = byName[target.name] {
                return BenchmarkListRow(
                    name: benchmark.name, target: target.goalDescription, status: "available",
                    summary: benchmark.summary, cost: benchmark.cost)
            }
            return BenchmarkListRow(
                name: target.name, target: target.goalDescription, status: "not implemented",
                summary: "Published target; no benchmark implementation exists yet.",
                cost: "unavailable — this command will not invent a measurement")
        }

        if json {
            emitJSON(BenchmarkListDocument(benchmarks: rows))
            return 0
        }

        var table = TextTable(headers: ["BENCHMARK", "TARGET", "STATUS", "SUMMARY"])
        for row in rows {
            table.add([row.name, row.target, row.status, row.summary])
        }
        out(table.render())
        out()
        out("Run `morb bench run` to measure the available benchmarks. It is never implicit.")
        return 0
    }

    // MARK: - run

    private static func runBenchmarks(arguments: [String], json: Bool) -> Int32 {
        guard let options = parseRunOptions(arguments) else { return 2 }
        let selected: [any Benchmark]
        switch resolveBenchmarks(only: options.only) {
        case .success(let benchmarks): selected = benchmarks
        case .failure(let error): return usageError(error.description)
        }

        let context = BenchContext(
            runs: options.runs, idleWindowSeconds: options.windowSeconds, dryRun: options.dryRun)
        if options.dryRun {
            let plan = BenchmarkPlanDocument(
                runs: context.runs, windowSeconds: context.idleWindowSeconds,
                benchmarks: selected.map {
                    BenchmarkPlanRow(name: $0.name, summary: $0.summary, cost: $0.cost, steps: $0.plan(context))
                })
            if json {
                emitJSON(plan)
            } else {
                out("Dry run — no measurements or host changes were made.")
                for item in plan.benchmarks {
                    out()
                    out("\(item.name): \(item.summary)")
                    out("  cost: \(item.cost)")
                    for step in item.steps { out("  - \(step)") }
                }
            }
            return 0
        }

        // Every concrete benchmark does its own precondition check immediately
        // before its side effects.  Keeping the checks in the benchmark is what
        // prevents a future caller from accidentally bypassing StackGuard.
        let metadata = RunMetadata.collectHost()
        let results = selected.map { $0.run(context) }
        let parameters = [
            "runs": "\(context.runs)",
            "window": "\(context.idleWindowSeconds)s",
            "only": options.only.isEmpty ? "all implemented benchmarks" : options.only.joined(separator: ","),
        ]
        let record = RunRecord(metadata: metadata, parameters: parameters, results: results)

        do {
            let location = try BenchStorage.save(record)
            if json {
                emitJSON(BenchmarkRunDocument(record: record, storedAt: location.path))
            } else {
                render(record: record, storedAt: location.path)
            }
        } catch {
            // Results were collected, but claiming they were saved would make a
            // later comparison look reproducible when it is not.
            if json {
                emitJSON(BenchmarkRunDocument(record: record, storedAt: nil, storageError: "\(error)"))
            } else {
                render(record: record, storedAt: nil)
                errOut("could not save this run: \(error)")
            }
            return 2
        }

        // A skipped metric is not a pass.  Exit nonzero so an automated public
        // target check cannot publish a partial run as green.
        return results.allSatisfy { $0.verdict == .pass || $0.verdict == .notApplicable } ? 0 : 2
    }

    private static func parseRunOptions(_ arguments: [String]) -> RunOptions? {
        var runs = 5
        var windowSeconds = 30
        var only: [String] = []
        var dryRun = false
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--dry-run":
                guard !dryRun else { usageError("`--dry-run` was passed more than once"); return nil }
                dryRun = true
                index += 1
            case "--runs":
                guard index + 1 < arguments.count else { usageError("`--runs` requires a positive integer"); return nil }
                guard let value = Int(arguments[index + 1]), value > 0 else {
                    usageError("`--runs` must be a positive integer")
                    return nil
                }
                runs = value
                index += 2
            case "--window":
                guard index + 1 < arguments.count else { usageError("`--window` requires a positive number of seconds"); return nil }
                guard let value = Int(arguments[index + 1]), value > 0 else {
                    usageError("`--window` must be a positive integer number of seconds")
                    return nil
                }
                windowSeconds = value
                index += 2
            case "--only":
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    usageError("`--only` requires one or more comma-separated benchmark names")
                    return nil
                }
                let names = arguments[index + 1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                guard names.allSatisfy({ !$0.isEmpty }) else {
                    usageError("`--only` cannot contain an empty benchmark name")
                    return nil
                }
                for name in names where !only.contains(name) { only.append(name) }
                index += 2
            default:
                usageError("unknown run option `\(arguments[index])`")
                return nil
            }
        }
        return RunOptions(runs: runs, windowSeconds: windowSeconds, only: only, dryRun: dryRun)
    }

    private static func resolveBenchmarks(only: [String]) -> Result<[any Benchmark], BenchmarkSelectionError> {
        guard !only.isEmpty else { return .success(benchmarks) }
        let byName = benchmarksByName
        var selected: [any Benchmark] = []
        for name in only {
            guard let benchmark = byName[name] else {
                if Targets.target(for: name) != nil {
                    return .failure(.message(
                        "`\(name)` has a published target but no benchmark implementation yet; "
                            + "run `morb bench list` to see availability"))
                }
                return .failure(.message("unknown benchmark `\(name)`; run `morb bench list` to see available names"))
            }
            selected.append(benchmark)
        }
        return .success(selected)
    }

    // MARK: - history

    private static func history(arguments: [String], json: Bool) -> Int32 {
        guard let limit = parseHistoryOptions(arguments) else { return 2 }
        let entries = Array(BenchStorage.listAll().prefix(limit))
        if json {
            emitJSON(BenchmarkHistoryDocument(runs: entries.map(\.record)))
            return 0
        }
        guard !entries.isEmpty else {
            out("No stored benchmark runs in \(MorbFeaturePaths.benchDirectory.path).")
            return 0
        }
        var table = TextTable(headers: ["TIMESTAMP", "ID", "RESULTS", "OUTCOME"])
        for entry in entries {
            let counts = Dictionary(grouping: entry.record.results, by: \.verdict).mapValues(\.count)
            let resultText = "\(entry.record.results.count) measured"
            let outcome = [
                counts[.pass].map { "\($0) PASS" },
                counts[.miss].map { "\($0) MISS" },
                counts[.skipped].map { "\($0) SKIPPED" },
                counts[.notApplicable].map { "\($0) N/A" },
            ].compactMap { $0 }.joined(separator: ", ")
            table.add([entry.record.timestamp, entry.record.id, resultText, outcome])
        }
        out(table.render())
        return 0
    }

    private static func parseHistoryOptions(_ arguments: [String]) -> Int? {
        guard !arguments.isEmpty else { return 20 }
        guard arguments.count == 2, arguments[0] == "--limit" else {
            usageError("history accepts only `--limit <positive integer>`")
            return nil
        }
        guard let limit = Int(arguments[1]), limit > 0 else {
            usageError("`--limit` must be a positive integer")
            return nil
        }
        return limit
    }

    // MARK: - compare

    private static func compare(arguments: [String], json: Bool) -> Int32 {
        guard arguments.count == 2 else {
            return usageError("compare requires two stored runs: `morb bench compare <baseline> <candidate>`")
        }
        let baseline: RunRecord
        let candidate: RunRecord
        do {
            baseline = try BenchStorage.resolve(arguments[0])
            candidate = try BenchStorage.resolve(arguments[1])
        } catch {
            errOut("\(error)")
            return 2
        }

        let comparison = compare(baseline: baseline, candidate: candidate)
        if json {
            emitJSON(comparison)
        } else {
            render(comparison: comparison)
        }
        return comparison.rows.contains { $0.classification == RegressionPolicy.Classification.regression.rawValue } ? 2 : 0
    }

    private static func compare(baseline: RunRecord, candidate: RunRecord) -> BenchmarkComparisonDocument {
        let older = Dictionary(uniqueKeysWithValues: baseline.results.map { ($0.name, $0) })
        let newer = Dictionary(uniqueKeysWithValues: candidate.results.map { ($0.name, $0) })
        let names = baseline.results.map(\.name) + candidate.results.map(\.name).filter { !older.keys.contains($0) }
        let rows = names.map { name -> BenchmarkComparisonRow in
            let oldResult = older[name]
            let newResult = newer[name]
            let verdict = RegressionPolicy.classify(oldValue: oldResult?.primaryValue, newValue: newResult?.primaryValue)
            return BenchmarkComparisonRow(
                name: name,
                baselineValue: oldResult?.primaryValue,
                candidateValue: newResult?.primaryValue,
                unit: newResult?.unit ?? oldResult?.unit,
                classification: verdict.0.rawValue,
                deltaPercent: verdict.1,
                baselineVerdict: oldResult?.verdict,
                candidateVerdict: newResult?.verdict)
        }
        return BenchmarkComparisonDocument(baseline: baseline, candidate: candidate, rows: rows)
    }

    // MARK: - Rendering

    private static func render(record: RunRecord, storedAt: String?) {
        out("Benchmark run \(record.id) — \(record.timestamp)")
        var metadata = TextTable(headers: ["HOST", "VALUE"])
        for (key, value) in record.metadata.summaryRows() { metadata.add([key, value]) }
        out(metadata.render())
        out()

        var table = TextTable(headers: ["BENCHMARK", "VALUE", "TARGET", "VERDICT", "SUMMARY"], rightAligned: [1, 2])
        for result in record.results {
            let target = Targets.target(for: result.name)?.goalDescription ?? "—"
            table.add([result.name, renderValue(result), target, result.verdict.rawValue, result.summary])
        }
        out(table.render())
        if let storedAt {
            out()
            out("Saved: \(storedAt)")
        }
    }

    private static func render(comparison: BenchmarkComparisonDocument) {
        out("Comparing \(comparison.baseline.id) (\(comparison.baseline.timestamp)) → "
            + "\(comparison.candidate.id) (\(comparison.candidate.timestamp))")
        out("Lower is better. Changes under \(String(format: "%.0f", RegressionPolicy.noiseThresholdPercent))% are noise.")
        var table = TextTable(headers: ["BENCHMARK", "BASELINE", "CANDIDATE", "CHANGE", "CLASSIFICATION"], rightAligned: [1, 2, 3])
        for row in comparison.rows {
            table.add([
                row.name,
                renderValue(row.baselineValue, unit: row.unit),
                renderValue(row.candidateValue, unit: row.unit),
                row.deltaPercent.map { String(format: "%+.1f%%", $0) } ?? "—",
                row.classification,
            ])
        }
        out(table.render())
    }

    private static func renderValue(_ result: BenchResult) -> String {
        renderValue(result.primaryValue, unit: result.unit)
    }

    private static func renderValue(_ value: Double?, unit: String?) -> String {
        guard let value else { return "—" }
        switch unit {
        case "s": return Format.duration(value)
        case "%": return String(format: "%.2f%%", value)
        case "wakeups/s": return String(format: "%.1f/s", value)
        case "bytes": return Format.bytes(Int64(value))
        case "x native": return String(format: "%.2fx", value)
        default: return String(format: "%.4g", value)
        }
    }

    // MARK: - Output and usage

    private static func out(_ message: String = "") { print(message) }

    private static func errOut(_ message: String) {
        FileHandle.standardError.write(Data(("morb bench: " + message + "\n").utf8))
    }

    @discardableResult
    private static func usageError(_ message: String) -> Int32 {
        errOut(message)
        FileHandle.standardError.write(Data("\n".utf8))
        printUsage(to: .standardError)
        return 2
    }

    private static func printUsage(to output: FileHandle = .standardOutput) {
        let usage = """
        Usage: morb bench <subcommand> [options]

        Read-only subcommands:
          list                         Show published targets and implementation status.
          history [--limit <count>]    Show saved benchmark runs (default: 20).
          compare <baseline> <candidate>
                                       Compare two saved runs (paths, ids, `latest`, or `previous`).

        Measurement (explicit only):
          run [--only <name,...>] [--runs <count>] [--window <seconds>] [--dry-run]
                                       Run every implemented benchmark, or named ones only.

        `run` is the only command that measures anything. Some measurements create a
        throwaway container or cycle a private VM; `--dry-run` prints each exact plan.
        Benchmarks refuse unsafe conditions rather than fabricating a result.
        """
        output.write(Data((usage + "\n").utf8))
    }

    private static func emitJSON<T: Encodable>(_ value: T) {
        do {
            out(try IPCCodec.prettyJSON(value))
        } catch {
            // The documents here are all value types. If encoding ever fails, say
            // so rather than emitting malformed or partial JSON.
            errOut("could not encode JSON output: \(error)")
        }
    }
}

// MARK: - CLI documents

private struct RunOptions {
    var runs: Int
    var windowSeconds: Int
    var only: [String]
    var dryRun: Bool
}

private enum BenchmarkSelectionError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let message): return message
        }
    }
}

private struct BenchmarkListRow: Codable {
    var name: String
    var target: String
    var status: String
    var summary: String
    var cost: String
}

private struct BenchmarkListDocument: Codable {
    var benchmarks: [BenchmarkListRow]
}

private struct BenchmarkPlanRow: Codable {
    var name: String
    var summary: String
    var cost: String
    var steps: [String]
}

private struct BenchmarkPlanDocument: Codable {
    var dryRun = true
    var runs: Int
    var windowSeconds: Int
    var benchmarks: [BenchmarkPlanRow]
}

private struct BenchmarkRunDocument: Codable {
    var record: RunRecord
    var storedAt: String?
    var storageError: String?

    init(record: RunRecord, storedAt: String?, storageError: String? = nil) {
        self.record = record
        self.storedAt = storedAt
        self.storageError = storageError
    }
}

private struct BenchmarkHistoryDocument: Codable {
    var runs: [RunRecord]
}

private struct BenchmarkComparisonRow: Codable {
    var name: String
    var baselineValue: Double?
    var candidateValue: Double?
    var unit: String?
    var classification: String
    var deltaPercent: Double?
    var baselineVerdict: Verdict?
    var candidateVerdict: Verdict?
}

private struct BenchmarkComparisonDocument: Codable {
    var baseline: RunRecord
    var candidate: RunRecord
    var rows: [BenchmarkComparisonRow]
}
