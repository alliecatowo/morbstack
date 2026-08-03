// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// `morb migrate run` is intentionally an images-only structured transaction.
// It owns selection, the explicit confirmation boundary, progress presentation,
// and durable report output; the reusable transfer logic lives in
// ImageMigrationTransaction.swift and emits typed data for the native app.

import Foundation
import MorbFeatures

enum RunImagesCommand {

    static func run(arguments: [String], json: Bool) -> Int32 {
        let parsed: Arguments
        do {
            parsed = try Arguments(arguments)
        } catch {
            return usageError("\(error)")
        }

        // A confirmation prompt on stdout would corrupt machine-readable output. A
        // caller supplying --json must make the same explicit --yes choice an
        // unattended automation would make.
        if json, !parsed.dryRun, !parsed.assumeYes {
            errOut("--json run requires --yes; a confirmation prompt cannot share JSON stdout")
            return 2
        }

        let selection: ImageMigrationSelection = parsed.allImages
            ? .allPlanned : .references(parsed.imageReferences)
        let prepared: PreparedImageMigration
        do {
            prepared = try ImageMigrationTransaction.prepare(from: parsed.source, selection: selection)
        } catch {
            errOut("\(error)")
            return 2
        }

        if parsed.dryRun {
            if json {
                emitCodable(prepared)
            } else {
                renderPrepared(prepared, heading: "Images-only migration dry run")
                out("\n[dry-run] nothing was changed.")
            }
            return 0
        }

        if !json { renderPrepared(prepared, heading: "Prepared images-only migration") }
        if !parsed.assumeYes {
            switch confirmInteractively(
                "\nImport exactly these \(prepared.items.count) image(s), \(Format.bytes(prepared.totalBytes)) total, from \(prepared.source.name) into Morbstack?"
            ) {
            case .yes:
                break
            case .no:
                errOut("cancelled; no image archive was read and neither engine was changed")
                return 2
            case .noTTY:
                errOut("this needs confirmation and stdin is not a terminal — pass --yes after reviewing a dry run")
                return 2
            }
        }

        var progressRenderer = ProgressRenderer(enabled: !json)
        let report: ImageMigrationTransactionReport
        do {
            report = try ImageMigrationTransaction.execute(
                prepared, confirmation: prepared.confirmation(),
                progress: { event in progressRenderer.consume(event) })
        } catch {
            errOut("\(error)")
            return 2
        }

        if json {
            emitCodable(report)
        } else {
            renderReport(report)
        }
        if report.cancellationObserved { return 2 }
        return report.isFullyVerified ? 0 : 1
    }

    // MARK: - Arguments

    private struct Arguments {
        var source: String?
        var imageReferences: [String] = []
        var allImages = false
        var dryRun = false
        var assumeYes = false

        init(_ arguments: [String]) throws {
            var index = 0
            while index < arguments.count {
                switch arguments[index] {
                case "--from":
                    guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                        throw ArgumentError.missingValue("--from")
                    }
                    source = arguments[index + 1]
                    index += 2
                case "--image":
                    guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                        throw ArgumentError.missingValue("--image")
                    }
                    imageReferences.append(arguments[index + 1])
                    index += 2
                case "--all-images":
                    allImages = true
                    index += 1
                case "--dry-run":
                    dryRun = true
                    index += 1
                case "--yes":
                    assumeYes = true
                    index += 1
                default:
                    throw ArgumentError.unknown(arguments[index])
                }
            }
            guard allImages != imageReferences.isEmpty else {
                throw ArgumentError.selectionRequired
            }
            guard source != nil else { throw ArgumentError.sourceRequired }
        }
    }

    private enum ArgumentError: Error, CustomStringConvertible {
        case missingValue(String)
        case unknown(String)
        case selectionRequired
        case sourceRequired

        var description: String {
            switch self {
            case .missingValue(let option): return "\(option) requires a value"
            case .unknown(let argument): return "unknown option \(argument)"
            case .selectionRequired:
                return "select one or more --image references, or pass --all-images (but not both)"
            case .sourceRequired:
                return "--from is required for an executable migration; inspect first with `morb migrate plan`"
            }
        }
    }

    // MARK: - Presentation

    private static func renderPrepared(_ prepared: PreparedImageMigration, heading: String) {
        out("\(heading) (confirmation required):")
        out("  source       \(prepared.source.name)")
        out("  destination  \(prepared.destination.name)")
        out("  selection    \(prepared.selectionDescription)")
        out("  source       read-only Docker GET requests only")
        out("  total        \(prepared.items.count) image(s), \(Format.bytes(prepared.totalBytes)) estimated source image size")
        out("")
        var table = TextTable(headers: ["IMAGE", "IMAGE ID", "SIZE"], rightAligned: [2])
        for item in prepared.items {
            table.add([item.reference, Format.truncate(item.imageID, 20), Format.bytes(item.sizeBytes)])
        }
        out(table.render())
        out("")
        out("Excluded from this transaction:")
        for scope in prepared.excludedScopes { out("  - \(scope)") }
        out("No registry, credential helper, Docker configuration, helper container, or volume operation is used.")
    }

    private static func renderReport(_ report: ImageMigrationTransactionReport) {
        out("")
        out("Images-only migration report")
        out("  source        \(report.source.name)")
        out("  destination   \(report.destination.name)")
        out("  source state  unchanged (Docker GET requests only)")
        out("  report        \(report.reportPath ?? report.reportWriteError ?? "not written")")
        out("")
        var table = TextTable(headers: ["IMAGE", "RESULT", "VERIFY", "ARCHIVE", "DETAIL"], rightAligned: [3])
        for item in report.items {
            table.add([
                item.reference,
                item.outcome.rawValue,
                item.verification.rawValue,
                Format.bytes(item.archiveBytes),
                Format.truncate(item.detail ?? "", 72),
            ])
        }
        out(table.render())
        out("")
        if report.isFullyVerified {
            out("[ok] every selected image is present under its selected tag with the prepared image ID.")
        } else if report.cancellationObserved {
            out("[!!] cancellation was observed. Read the report before retrying or cleaning up any destination image.")
        } else {
            out("[!!] one or more images failed or require review; do not assume the destination is unchanged.")
        }
        out("Rollback guidance:")
        for line in report.rollbackGuidance { out("  - \(line)") }
    }

    /// Keeps interactive output compact even though the service reports every byte
    /// update. Native UI callers receive all events and can bind them to ProgressView.
    private struct ProgressRenderer {
        let enabled: Bool
        var lastPhaseKey = ""

        mutating func consume(_ event: ImageMigrationProgress) {
            guard enabled else { return }
            let key = "\(event.completedImageCount)|\(event.imageReference ?? "")|\(event.phase.rawValue)"
            guard key != lastPhaseKey else { return }
            lastPhaseKey = key
            guard let image = event.imageReference else { return }
            switch event.phase {
            case .checkingPreconditions:
                out("\n[\(event.completedImageCount + 1)/\(event.totalImageCount)] Checking \(image)")
            case .exporting:
                out("  Exporting local source archive…")
            case .importing:
                out("  Loading archive into Morbstack…")
            case .verifying:
                out("  Verifying Docker image IDs…")
            case .completedImage:
                out("  Result: \(event.detail ?? "unknown")")
            case .cancelled:
                out("  Cancelled before destination import.")
            case .prepared, .writingReport, .completed:
                break
            }
        }
    }

    private static func emitCodable<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            errOut("could not encode structured migration output")
            return
        }
        out(text)
    }

    private static func usageError(_ message: String) -> Int32 {
        errOut(message)
        errOut("usage: morb migrate run --from <runtime|socket> (--image <reference>... | --all-images) [--dry-run] [--yes]")
        return 2
    }
}
