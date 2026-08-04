// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// `morb migrate volumes` is presentation and terminal consent around the reusable
// VolumeMigrationTransaction. It must not regain its own helper-container or copy
// path: the CLI and a future native workflow need the same selected-volume contract.

import Foundation
import MorbFeatures

enum VolumesCommand {

    static func run(arguments: [String], json: Bool) -> Int32 {
        let args = parseArgs(arguments, valueFlags: ["from", "filter"])
        let dryRun = args.flag("dry-run")
        let assumeYes = args.flag("yes")
        if args.flag("overwrite") {
            errOut("--overwrite is not supported: selected volume migration only creates missing destination volumes and never merges existing contents")
            return 2
        }
        if json, !dryRun, !assumeYes {
            errOut("--json volumes requires --yes; a confirmation prompt cannot share JSON stdout")
            return 2
        }

        let initialPlan = MigrationReadOnlyPlanner.inspect(from: args.option("from"))
        guard initialPlan.source.readiness == .ready, initialPlan.destination.readiness == .ready,
              let volumePlan = initialPlan.volumePlan
        else {
            errOut(initialPlan.volumeUnavailableReason ?? initialPlan.source.detail ?? initialPlan.destination.detail
                ?? "source and destination must both be ready before volume migration")
            return 2
        }

        let visibleItems = volumePlan.items.filter { item in
            guard let filter = args.option("filter"), !filter.isEmpty else { return true }
            return item.name.localizedCaseInsensitiveContains(filter)
        }
        renderInitialPlan(items: visibleItems, source: initialPlan.source.name)
        let eligibleNames = visibleItems.filter(\.isEligible).map(\.name)
        guard !eligibleNames.isEmpty else {
            out("\nNothing is eligible for an additive named-volume transfer.")
            return 0
        }

        let prepared: PreparedVolumeMigration
        do {
            prepared = try VolumeMigrationTransaction.prepare(
                from: args.option("from"), selection: .names(eligibleNames))
        } catch {
            errOut("\(error)")
            return 2
        }

        if dryRun {
            if json {
                emitCodable(prepared)
            } else {
                renderPrepared(prepared, heading: "Named-volume migration dry run")
                out("\n[dry-run] no helper container, image pull, archive, or destination volume was created.")
            }
            return 0
        }

        if !json { renderPrepared(prepared, heading: "Prepared named-volume migration") }
        if !assumeYes {
            switch confirmInteractively(
                "\nCopy exactly these \(prepared.items.count) new local volume(s) from \(prepared.source.name) into Morbstack?"
            ) {
            case .yes: break
            case .no:
                errOut("cancelled; no helper container, archive, or destination volume was created")
                return 2
            case .noTTY:
                errOut("this needs confirmation and stdin is not a terminal — pass --yes after reviewing a dry run")
                return 2
            }
        }

        let networkConsent: VolumeMigrationNetworkConsent?
        if prepared.helperImageNetworkConsentRequired {
            if assumeYes {
                networkConsent = prepared.networkConsent()
            } else {
                out("\nA suitable helper image is absent on \(missingHelperTargets(prepared).joined(separator: " and ")).")
                out("Morbstack would pull alpine:3.20 (about 3 MB) only onto those engine(s).")
                switch confirmInteractively("Allow this network pull now?") {
                case .yes: networkConsent = prepared.networkConsent()
                case .no:
                    errOut("cancelled; helper images were not pulled and no volume was created")
                    return 2
                case .noTTY:
                    errOut("this needs explicit helper-image network consent — pass --yes after reviewing the dry run")
                    return 2
                }
            }
        } else {
            networkConsent = nil
        }

        var renderer = ProgressRenderer(enabled: !json)
        let report: VolumeMigrationTransactionReport
        do {
            report = try VolumeMigrationTransaction.execute(
                prepared, confirmation: prepared.confirmation(), networkConsent: networkConsent,
                progress: { event in renderer.consume(event) })
        } catch {
            errOut("\(error)")
            return 2
        }

        if json {
            emitCodable(report)
        } else {
            renderReport(report)
        }
        return report.isFullyCopied ? 0 : 1
    }

    private static func renderInitialPlan(items: [MigrationVolumePlanItem], source: String) {
        out("Named-volume eligibility on \(source) (read-only — nothing was changed):")
        var table = TextTable(headers: ["VOLUME", "DRIVER", "PLAN"])
        for item in items {
            table.add([item.name, item.driver, planText(item.disposition)])
        }
        out(items.isEmpty ? "  (no named volumes matched)" : table.render())
        out("Existing Morbstack volumes are never inspected, merged, or overwritten.")
    }

    private static func renderPrepared(_ prepared: PreparedVolumeMigration, heading: String) {
        out("\(heading) (confirmation required):")
        out("  source       \(prepared.source.name)")
        out("  destination  \(prepared.destination.name)")
        out("  selection    \(prepared.selectionDescription)")
        out("  volumes      \(prepared.items.count) new local named volume(s)")
        out("  source       creates one stopped, read-only helper per selected volume, then removes it")
        out("  destination  creates only selected missing volumes; existing names are refused")
        if prepared.helperImageNetworkConsentRequired {
            out("  network      explicit consent is required before a missing alpine:3.20 helper image can be pulled")
        } else {
            out("  network      existing local helper images are available; no pull is planned")
        }
        out("")
        var table = TextTable(headers: ["VOLUME", "DRIVER"])
        for item in prepared.items { table.add([item.name, item.driver]) }
        out(table.render())
    }

    private static func renderReport(_ report: VolumeMigrationTransactionReport) {
        out("\nNamed-volume migration report:")
        var table = TextTable(headers: ["VOLUME", "RESULT", "DESTINATION", "ARCHIVE", "FILES", "DETAIL"], rightAligned: [3, 4])
        for item in report.items {
            table.add([
                item.name,
                item.outcome.rawValue,
                item.destinationState.rawValue,
                Format.bytes(item.archiveBytes),
                item.archiveFileCount.map(String.init) ?? "—",
                item.detail ?? "—",
            ])
        }
        out(table.render())
        if let path = report.reportPath { out("\nReport: \(path)") }
        if let error = report.reportWriteError { out("\nReport was not written: \(error)") }
        if !report.isFullyCopied {
            out("\nReview every destination volume marked requires_review before any manual cleanup.")
        }
    }

    private static func missingHelperTargets(_ prepared: PreparedVolumeMigration) -> [String] {
        var labels: [String] = []
        if !prepared.sourceHasHelperImage { labels.append(prepared.source.name) }
        if !prepared.destinationHasHelperImage { labels.append("Morbstack") }
        return labels
    }

    private static func planText(_ disposition: MigrationVolumePlanDisposition) -> String {
        switch disposition {
        case .eligible: return "eligible"
        case .destinationExists: return "destination exists"
        case .unsupportedDriver: return "unsupported driver"
        }
    }

    private static func emitCodable<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            errOut("could not encode migration result as JSON")
            return
        }
        out(text)
    }

    private struct ProgressRenderer {
        let enabled: Bool

        mutating func consume(_ event: VolumeMigrationProgress) {
            guard enabled else { return }
            guard let volume = event.volumeName else { return }
            switch event.phase {
            case .exporting:
                out("  \(volume): reading \(event.bytesTransferred.map(Format.bytes) ?? "archive")")
            case .creatingDestination:
                out("  \(volume): creating destination volume")
            case .importing:
                out("  \(volume): writing \(event.bytesTransferred.map(Format.bytes) ?? "archive")")
            case .completedVolume:
                out("  \(volume): \(event.detail ?? "completed")")
            default:
                break
            }
        }
    }
}
