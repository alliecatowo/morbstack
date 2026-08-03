// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The command surface for `morb scan`.  The engine owns the side effects; this
// file is deliberately concerned with one thing: making those effects explicit
// before they happen and giving both people and automation a useful result.

import Foundation
import MorbFeatures
import MorbstackKit

enum ScanCLI {

    // MARK: - Dispatch

    static func run(_ arguments: [String], json: Bool) -> Int32 {
        switch parse(arguments) {
        case .failure(let error):
            return usageError(error.description, json: json)
        case .success(.help):
            printUsage()
            return 0
        case .success(.check(let offline)):
            return check(offline: offline, json: json)
        case .success(.scan(let options)):
            return scan(options: options, json: json)
        }
    }

    // MARK: - Preflight

    /// Reports every local prerequisite without touching the engine or network.
    /// A missing database is not itself a failed normal scan: a normal, non-offline
    /// scan deliberately downloads or refreshes it after announcing that action.
    private static func check(offline: Bool, json: Bool) -> Int32 {
        let syft = ToolLocator.locate("syft")
        let grype = ToolLocator.locate("grype")
        let database = grype.map { ScanEngine.databaseStatus(grype: $0) }
        let toolsAvailable = syft != nil && grype != nil
        let offlineReady = toolsAvailable && (database?.present == true && database?.valid == true)

        if json {
            emitJSON([
                "mode": "check",
                "network": "not used",
                "engine": "not contacted",
                "syft": toolJSON(syft),
                "grype": toolJSON(grype),
                "database": database.map { databaseJSON($0) as Any } ?? NSNull(),
                "offline_ready": offlineReady,
                "normal_scan_ready": toolsAvailable,
                "notes": [
                    "A normal scan may explicitly download or refresh Grype's vulnerability database; it does not upload image or SBOM data.",
                    "Pass --offline to scan only with a valid cached database.",
                ],
            ])
        } else {
            out("Local scan prerequisites (no engine or network access):")
            renderTool("syft", tool: syft)
            renderTool("grype", tool: grype)
            renderDatabase(database)
            out()
            if toolsAvailable {
                out("A normal scan is ready to run. It exports the image through Morbstack's local")
                out("Engine socket, builds an SBOM with syft on this Mac, and scans it with grype.")
                if offlineReady {
                    out("A valid cached vulnerability database is available for --offline.")
                } else {
                    out("No valid cached vulnerability database is available for --offline. A normal scan")
                    out("will announce before it downloads or refreshes one; no image or SBOM is uploaded.")
                }
            } else {
                out("Install the missing local tools before scanning. The engine and image were not contacted.")
            }
        }

        if !toolsAvailable { return 2 }
        return offline && !offlineReady ? 2 : 0
    }

    // MARK: - Scan

    private static func scan(options: ScanOptions, json: Bool) -> Int32 {
        guard let syft = ToolLocator.locate("syft") else {
            return commandError(ToolLocator.missingToolMessage("syft"), json: json)
        }
        let grype: LocatedTool?
        if options.sbomOnly {
            grype = nil
        } else {
            guard let found = ToolLocator.locate("grype") else {
                return commandError(ToolLocator.missingToolMessage("grype"), json: json)
            }
            grype = found
        }

        func progress(_ message: String) {
            if !json { out(message) }
        }

        let manager = FileManager.default
        var archiveURL: URL?
        var temporarySBOMURL: URL?
        defer {
            if let archiveURL { try? manager.removeItem(at: archiveURL) }
            if let temporarySBOMURL { try? manager.removeItem(at: temporarySBOMURL) }
        }

        do {
            progress("Scanning local image `\(options.image)`.")
            progress("Exporting it through the Morbstack Engine socket; this does not contact a registry.")
            let exported = try ScanEngine.exportImage(options.image, engine: EngineClient())
            archiveURL = exported.path
            progress("Exported \(Format.bytes(exported.bytes)); generating an SBOM locally with syft.")

            let sbom = try ScanEngine.runSyft(
                archivePath: exported.path.path, syft: syft,
                environment: ScanToolEnvironment.base())
            try manager.createDirectory(at: ScanPaths.tempDirectory, withIntermediateDirectories: true)
            let generatedSBOM = ScanPaths.tempDirectory
                .appendingPathComponent("morb-scan-\(UUID().uuidString).syft.json", isDirectory: false)
            try sbom.write(to: generatedSBOM, options: .atomic)
            temporarySBOMURL = generatedSBOM

            if let requestedPath = options.sbomPath {
                try writeSBOM(sbom, to: requestedPath)
                progress("Wrote the local syft SBOM to \(requestedPath.path).")
            }

            if options.sbomOnly {
                if json {
                    emitJSONData(sbom)
                } else {
                    out("SBOM complete. No vulnerability database was read, updated, or contacted (--sbom-only).")
                }
                return 0
            }

            guard let grype else {
                return commandError("internal error: grype was not resolved", json: json)
            }
            let database = try ScanEngine.ensureDatabase(grype: grype, offline: options.offline, announce: progress)
            progress("Matching the local SBOM against the local vulnerability database with grype.")
            let report = try ScanEngine.runGrype(
                sbomPath: generatedSBOM.path, grype: grype, offline: options.offline)
            let summary = ScanSummary(findings: try GrypeReport.parseFindings(report))

            if json {
                // The complete grype document carries CVSS vectors, descriptions, and
                // match provenance not represented by our short human summary.
                emitJSONData(report)
            } else {
                renderSummary(
                    image: options.image, database: database, summary: summary,
                    showAll: options.showAll, failOn: options.failOn)
            }

            if let failOn = options.failOn, summary.shouldFail(on: failOn) {
                if !json {
                    out()
                    out("Scan failed because at least one finding is \(failOn.rawValue) or higher (--fail-on \(failOn.rawValue.lowercased())).")
                }
                return 2
            }
            return 0
        } catch {
            return commandError(describe(error), json: json)
        }
    }

    private static func writeSBOM(_ data: Data, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else {
            throw ScanCLIError.message("the parent directory for --sbom does not exist: \(parent.path)")
        }
        try data.write(to: destination, options: .atomic)
    }

    // MARK: - Presentation

    private static func renderSummary(
        image: String, database: DatabaseStatus, summary: ScanSummary, showAll: Bool, failOn: Severity?
    ) {
        out()
        out("Scan result")
        let severityCounts = summary.countsBySeverity.map { "\($0.count) \($0.severity.rawValue.lowercased())" }
        printAligned([
            ("image", image),
            ("database", databaseDescription(database)),
            ("findings", summary.total == 0 ? "none" : "\(summary.total) (\(severityCounts.joined(separator: ", ")))"),
            ("fail-on", failOn?.rawValue.lowercased() ?? "not set"),
        ])

        guard summary.total > 0 else { return }
        let limit: Int? = showAll ? nil : 20
        let findings = summary.worstFindings(limit: limit)
        var table = TextTable(headers: ["SEVERITY", "VULNERABILITY", "PACKAGE", "VERSION", "FIX STATE", "FIXED IN"])
        for finding in findings {
            table.add([
                finding.severity.rawValue,
                finding.vulnerabilityID,
                finding.packageName,
                finding.packageVersion.isEmpty ? "-" : finding.packageVersion,
                finding.fixState,
                finding.fixedInDisplay,
            ])
        }
        out()
        out(table.render())
        if findings.count < summary.total {
            out()
            out("Showing the \(findings.count) highest-severity findings; pass --all to print all \(summary.total).")
        }
    }

    private static func renderTool(_ name: String, tool: LocatedTool?) {
        guard let tool else {
            out("  \(name): missing — \(ToolLocator.missingToolMessage(name))")
            return
        }
        let version = tool.version.map { " version \($0)" } ?? " (version could not be read)"
        out("  \(name): available\(version) — \(tool.path)")
    }

    private static func renderDatabase(_ database: DatabaseStatus?) {
        guard let database else {
            out("  database: unavailable because grype is not installed")
            return
        }
        if database.present && database.valid {
            out("  database: valid, built \(database.builtAt.map { ISO8601DateFormatter().string(from: $0) } ?? "at an unknown time") (\(database.ageDescription()) old) — \(database.path)")
        } else if database.present {
            out("  database: present but not valid — \(database.errorMessage ?? database.path)")
        } else {
            out("  database: not cached yet — \(database.path)")
        }
    }

    private static func databaseDescription(_ database: DatabaseStatus) -> String {
        let timestamp = database.builtAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown build time"
        return "\(database.valid ? "valid" : "not valid"), built \(timestamp) (\(database.ageDescription()) old)"
    }

    // MARK: - Arguments

    private enum ParsedCommand {
        case help
        case check(offline: Bool)
        case scan(ScanOptions)
    }

    private struct ScanOptions {
        var image: String
        var offline: Bool
        var sbomOnly: Bool
        var sbomPath: URL?
        var failOn: Severity?
        var showAll: Bool
    }

    private enum ScanCLIError: Error, CustomStringConvertible, ExpressibleByStringLiteral {
        case message(String)

        init(stringLiteral value: String) {
            self = .message(value)
        }

        var description: String {
            switch self {
            case .message(let message): return message
            }
        }
    }

    private static func parse(_ arguments: [String]) -> Result<ParsedCommand, ScanCLIError> {
        if arguments == ["help"] || arguments == ["--help"] || arguments == ["-h"] {
            return .success(.help)
        }

        var check = false
        var offline = false
        var sbomOnly = false
        var sbomPath: URL?
        var failOn: Severity?
        var showAll = false
        var image: String?
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--check":
                guard !check else { return .failure("--check was passed more than once") }
                check = true
                index += 1
            case "--offline":
                guard !offline else { return .failure("--offline was passed more than once") }
                offline = true
                index += 1
            case "--sbom-only":
                guard !sbomOnly else { return .failure("--sbom-only was passed more than once") }
                sbomOnly = true
                index += 1
            case "--all":
                guard !showAll else { return .failure("--all was passed more than once") }
                showAll = true
                index += 1
            case "--sbom":
                guard sbomPath == nil else { return .failure("--sbom was passed more than once") }
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    return .failure("--sbom requires a destination path")
                }
                sbomPath = URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath)
                index += 2
            case "--fail-on":
                guard failOn == nil else { return .failure("--fail-on was passed more than once") }
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    return .failure("--fail-on requires negligible, low, medium, high, or critical")
                }
                guard let threshold = Severity(failOnArgument: arguments[index + 1]) else {
                    return .failure("--fail-on must be negligible, low, medium, high, or critical")
                }
                failOn = threshold
                index += 2
            default:
                guard !argument.hasPrefix("--") else {
                    return .failure(.message("unknown option `\(argument)`"))
                }
                guard image == nil else { return .failure("scan accepts exactly one local image reference") }
                guard !argument.isEmpty else { return .failure("image reference cannot be empty") }
                image = argument
                index += 1
            }
        }

        if check {
            guard image == nil else { return .failure("--check does not take an image reference") }
            guard !sbomOnly, sbomPath == nil, failOn == nil, !showAll else {
                return .failure("--check only accepts the optional --offline flag")
            }
            return .success(.check(offline: offline))
        }
        guard let image else { return .failure("an image reference is required (or pass --check)") }
        if sbomOnly {
            guard !offline else { return .failure("--offline has no effect with --sbom-only") }
            guard failOn == nil else { return .failure("--fail-on requires vulnerability scanning; remove --sbom-only") }
            guard !showAll else { return .failure("--all requires vulnerability scanning; remove --sbom-only") }
        }
        return .success(.scan(ScanOptions(
            image: image, offline: offline, sbomOnly: sbomOnly, sbomPath: sbomPath,
            failOn: failOn, showAll: showAll)))
    }

    // MARK: - Output

    private static func out(_ message: String = "") { print(message) }

    private static func printAligned(_ rows: [(String, String)]) {
        let width = rows.map(\.0.count).max() ?? 0
        for (key, value) in rows {
            out("  \(key)\(String(repeating: " ", count: max(0, width - key.count)))   \(value)")
        }
    }

    private static func commandError(_ message: String, json: Bool) -> Int32 {
        if json {
            emitJSON(["error": message])
        } else {
            FileHandle.standardError.write(Data(("morb scan: \(message)\n").utf8))
        }
        return 2
    }

    private static func usageError(_ message: String, json: Bool) -> Int32 {
        if json {
            emitJSON(["error": message, "usage": "morb scan [options] <image> | morb scan --check"])
        } else {
            FileHandle.standardError.write(Data(("morb scan: \(message)\n\n").utf8))
            printUsage(to: .standardError)
        }
        return 2
    }

    private static func printUsage(to output: FileHandle = .standardOutput) {
        let text = """
        Usage: morb scan [options] <local-image>
               morb scan --check [--offline]

        Export a local Morbstack image through the Engine socket, generate its SBOM with
        syft on this Mac, then scan it with grype on this Mac. Image and SBOM data are
        never uploaded. A normal scan may download or refresh Grype's public
        vulnerability database only after announcing that network operation.

        Options:
          --check                 Report local syft/grype/database prerequisites only;
                                  never contacts the engine or network.
          --offline               Require a valid cached Grype database; never updates it.
          --sbom-only             Stop after the local syft SBOM is generated.
          --sbom <path>           Also write the generated syft JSON SBOM to this path.
          --fail-on <severity>    Exit 2 for negligible, low, medium, high, or critical findings.
          --all                   Show every finding (the human summary shows 20 by default).

        `syft` and `grype` are optional local tools. Run scripts/fetch-scan-tools.sh,
        or install both yourself and put them on PATH. `morb scan --check` shows the
        exact state. Pass --json before `scan` for the raw syft or grype JSON report.
        """
        output.write(Data((text + "\n").utf8))
    }

    private static func emitJSONData(_ data: Data) {
        // Syft and Grype already produced a JSON document. Pretty-print it only when
        // it is parseable, preserving their actual document rather than a lossy model.
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            emitJSON(["error": "scanner produced invalid JSON"])
            return
        }
        emitJSON(value)
    }

    private static func emitJSON(_ value: Any) {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else {
            FileHandle.standardError.write(Data("morb scan: could not encode JSON output\n".utf8))
            return
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func toolJSON(_ tool: LocatedTool?) -> Any {
        guard let tool else { return ["available": false] }
        return [
            "available": true,
            "path": tool.path,
            "version": tool.version.map { $0 as Any } ?? NSNull(),
        ]
    }

    private static func databaseJSON(_ database: DatabaseStatus) -> [String: Any] {
        [
            "present": database.present,
            "valid": database.valid,
            "path": database.path,
            "schema_version": database.schemaVersion ?? NSNull(),
            "built_at": database.builtAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
            "age": database.ageDescription(),
            "error": database.errorMessage ?? NSNull(),
        ]
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? ScanEngineError { return error.description }
        if let error = error as? ScanParseError { return error.description }
        if let error = error as? ScanCLIError { return error.description }
        if let error = error as? EngineError { return error.description }
        if let error = error as? CommandError { return error.description }
        return error.localizedDescription
    }
}
