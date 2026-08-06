// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// `morb migrate --to <runtime|socket>` — the migration path OrbStack does not have
// (their "how do I leave" issue, #2517, is still open). This command deliberately
// does not introduce a second, weaker transfer implementation: it drives the exact
// same ``ImageMigrationTransaction`` and ``VolumeMigrationTransaction`` services that
// `morb migrate run`/`morb migrate volumes` already use, just prepared with `to:`
// instead of `from:` so Morbstack is the source and the named runtime or socket is
// the destination. Verification after the transfer reuses the identical config-ID
// and sha256sum-manifest comparisons `morb migrate verify` uses — see
// VerifyCommand.swift — so "leaving is tested" is the same tested code, not a new
// weaker check bolted on for this one command.

import Foundation
import MorbFeatures

enum MigrateOutCommand {

    static func run(arguments: [String], json: Bool) -> Int32 {
        let args = parseArgs(arguments, valueFlags: ["to"])
        guard let target = args.option("to") else {
            return usageError("--to <runtime|socket> is required")
        }
        let dryRun = args.flag("dry-run")
        let assumeYes = args.flag("yes")
        if json, !dryRun, !assumeYes {
            errOut("--json --to requires --yes; a confirmation prompt cannot share JSON stdout")
            return 2
        }

        let imagePrepared: PreparedImageMigration?
        do {
            imagePrepared = try ImageMigrationTransaction.prepare(to: target, selection: .allPlanned)
        } catch ImageMigrationTransactionError.emptySelection {
            imagePrepared = nil
        } catch {
            errOut("images: \(error)")
            return 2
        }

        let volumePrepared: PreparedVolumeMigration?
        do {
            volumePrepared = try VolumeMigrationTransaction.prepare(to: target, selection: .allEligible)
        } catch VolumeMigrationTransactionError.emptySelection {
            volumePrepared = nil
        } catch {
            errOut("volumes: \(error)")
            return 2
        }

        guard imagePrepared != nil || volumePrepared != nil else {
            if json {
                emitJSON(["ok": true, "nothing_to_migrate": true, "destination": target])
            } else {
                out("Nothing to migrate out — \(target) already has every tagged image and eligible named volume Morbstack has.")
            }
            return 0
        }

        if !json { renderPrepared(images: imagePrepared, volumes: volumePrepared, target: target) }

        if dryRun {
            if json {
                emitJSON([
                    "ok": true,
                    "dry_run": true,
                    "destination": target,
                    "images": imagePrepared.map(codableJSON) ?? NSNull(),
                    "volumes": volumePrepared.map(codableJSON) ?? NSNull(),
                ])
            } else {
                out("\n[dry-run] nothing was changed; no archive was read and no destination volume was created.")
            }
            return 0
        }

        if !assumeYes {
            let imageCount = imagePrepared?.items.count ?? 0
            let volumeCount = volumePrepared?.items.count ?? 0
            switch confirmInteractively(
                "\nCopy \(imageCount) image(s) and \(volumeCount) new local volume(s) from Morbstack out to \(target)?"
            ) {
            case .yes: break
            case .no:
                errOut("cancelled; nothing was changed")
                return 2
            case .noTTY:
                errOut("this needs confirmation and stdin is not a terminal — pass --yes after reviewing a dry run")
                return 2
            }
        }

        var imageReport: ImageMigrationTransactionReport?
        if let imagePrepared {
            do {
                var renderer = ImageProgressRenderer(enabled: !json)
                imageReport = try ImageMigrationTransaction.execute(
                    imagePrepared, confirmation: imagePrepared.confirmation(),
                    progress: { renderer.consume($0) })
            } catch {
                errOut("images: \(error)")
                return 2
            }
        }

        var volumeReport: VolumeMigrationTransactionReport?
        if let volumePrepared {
            let networkConsent: VolumeMigrationNetworkConsent?
            if volumePrepared.helperImageNetworkConsentRequired {
                if assumeYes {
                    networkConsent = volumePrepared.networkConsent()
                } else {
                    out("\nA suitable helper image is absent on \(missingHelperTargets(volumePrepared, target: target).joined(separator: " and ")).")
                    out("Morbstack would pull alpine:3.20 (about 3 MB) only onto those engine(s).")
                    switch confirmInteractively("Allow this network pull now?") {
                    case .yes: networkConsent = volumePrepared.networkConsent()
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
            do {
                var renderer = VolumeProgressRenderer(enabled: !json)
                volumeReport = try VolumeMigrationTransaction.execute(
                    volumePrepared, confirmation: volumePrepared.confirmation(), networkConsent: networkConsent,
                    progress: { renderer.consume($0) })
            } catch {
                errOut("volumes: \(error)")
                return 2
            }
        }

        if !json {
            if let imageReport { renderImageReport(imageReport) }
            if let volumeReport { renderVolumeReport(volumeReport) }
        }

        // Verification reuses VerifyCommand's exact config-ID and sha256sum-manifest
        // comparisons, run in the outbound direction: Morbstack is the known-good
        // "source" and the just-written target is the "destination" being checked.
        let verifyResults = verify(
            imagePrepared: imagePrepared, imageReport: imageReport,
            volumePrepared: volumePrepared, volumeReport: volumeReport, assumeYes: assumeYes)

        if !json {
            out("\nVerification (config-ID and sha256sum comparison, same as `morb migrate verify`):")
            VerifyCommand.printResults(verifyResults)
        }

        let transferOK = (imageReport?.isFullyVerified ?? true) && (volumeReport?.isFullyCopied ?? true)
        let verifyOK = verifyResults.allSatisfy { $0.outcome == .match }

        if json {
            emitJSON([
                "ok": transferOK && verifyOK,
                "destination": target,
                "images": imageReport.map(codableJSON) ?? NSNull(),
                "volumes": volumeReport.map(codableJSON) ?? NSNull(),
                "verify": [
                    "match": verifyResults.filter { $0.outcome == .match }.count,
                    "differ": verifyResults.filter { $0.outcome == .differ }.count,
                    "missing": verifyResults.filter { $0.outcome == .missing }.count,
                    "error": verifyResults.filter { $0.outcome == .error }.count,
                    "items": verifyResults.map {
                        ["kind": $0.kind, "name": $0.name, "outcome": $0.outcome.rawValue, "detail": $0.detail ?? NSNull()] as [String: Any]
                    },
                ],
            ])
        } else {
            out("")
            if transferOK, verifyOK {
                out("[ok] every selected image and volume was copied to \(target) and independently verified there.")
            } else {
                out("[!!] review the tables above before treating this as a complete migration out.")
            }
        }
        return transferOK && verifyOK ? 0 : 1
    }

    // MARK: - Verification

    private static func verify(
        imagePrepared: PreparedImageMigration?, imageReport: ImageMigrationTransactionReport?,
        volumePrepared: PreparedVolumeMigration?, volumeReport: VolumeMigrationTransactionReport?,
        assumeYes: Bool
    ) -> [VerifyItem] {
        var results: [VerifyItem] = []

        if let imagePrepared, let imageReport,
           let sourceSocket = imagePrepared.source.socketPath,
           let destinationSocket = imagePrepared.destination.socketPath
        {
            let source = EngineClient.forUnixSocket(sourceSocket)
            let destination = EngineClient.forUnixSocket(destinationSocket)
            let verifiedRefs = imageReport.items
                .filter { $0.outcome == .verified || $0.outcome == .alreadyPresent }
                .map(\.reference)
            for reference in verifiedRefs {
                results.append(VerifyCommand.verifyImage(reference: reference, source: source, destination: destination))
            }
        }

        if let volumePrepared, let volumeReport,
           let sourceSocket = volumePrepared.source.socketPath,
           let destinationSocket = volumePrepared.destination.socketPath
        {
            let source = EngineClient.forUnixSocket(sourceSocket)
            let destination = EngineClient.forUnixSocket(destinationSocket)
            let copiedNames = volumeReport.items.filter { $0.outcome == .copied }.map(\.name)
            if !copiedNames.isEmpty {
                let sourceImage = VerifyCommand.ensureVerifyImage(client: source, label: volumePrepared.source.name, assumeYes: assumeYes)
                let destImage = VerifyCommand.ensureVerifyImage(client: destination, label: volumePrepared.destination.name, assumeYes: assumeYes)
                for name in copiedNames {
                    results.append(VerifyCommand.verifyVolume(
                        name: name, source: source, sourceImage: sourceImage, destination: destination, destImage: destImage))
                }
            }
        }
        return results
    }

    // MARK: - Presentation

    private static func renderPrepared(images: PreparedImageMigration?, volumes: PreparedVolumeMigration?, target: String) {
        out("Prepared outbound migration to \(target) (confirmation required):")
        out("  source       Morbstack")
        out("  destination  \(target)")
        if let images {
            out("")
            out("Images — \(images.items.count) image(s), \(Format.bytes(images.totalBytes)) estimated:")
            var table = TextTable(headers: ["IMAGE", "IMAGE ID", "SIZE"], rightAligned: [2])
            for item in images.items {
                table.add([item.reference, Format.truncate(item.imageID, 20), Format.bytes(item.sizeBytes)])
            }
            out(table.render())
        } else {
            out("\nImages: nothing to copy — \(target) already has every tagged image Morbstack has.")
        }
        if let volumes {
            out("")
            out("Named volumes — \(volumes.items.count) new local volume(s):")
            var table = TextTable(headers: ["VOLUME", "DRIVER"])
            for item in volumes.items { table.add([item.name, item.driver]) }
            out(table.render())
            if volumes.helperImageNetworkConsentRequired {
                out("  network      explicit consent is required before a missing alpine:3.20 helper image can be pulled")
            }
        } else {
            out("\nNamed volumes: nothing eligible for an additive transfer.")
        }
        out("\nMorbstack's own images and volumes are never changed by this command.")
    }

    private static func renderImageReport(_ report: ImageMigrationTransactionReport) {
        out("\nImages migrated out:")
        var table = TextTable(headers: ["IMAGE", "RESULT", "VERIFY", "ARCHIVE", "DETAIL"], rightAligned: [3])
        for item in report.items {
            table.add([
                item.reference, item.outcome.rawValue, item.verification.rawValue,
                Format.bytes(item.archiveBytes), Format.truncate(item.detail ?? "", 60),
            ])
        }
        out(table.render())
    }

    private static func renderVolumeReport(_ report: VolumeMigrationTransactionReport) {
        out("\nVolumes migrated out:")
        var table = TextTable(headers: ["VOLUME", "RESULT", "DESTINATION", "ARCHIVE", "DETAIL"], rightAligned: [3])
        for item in report.items {
            table.add([
                item.name, item.outcome.rawValue, item.destinationState.rawValue,
                Format.bytes(item.archiveBytes), Format.truncate(item.detail ?? "", 60),
            ])
        }
        out(table.render())
    }

    private static func missingHelperTargets(_ prepared: PreparedVolumeMigration, target: String) -> [String] {
        var labels: [String] = []
        if !prepared.sourceHasHelperImage { labels.append("Morbstack") }
        if !prepared.destinationHasHelperImage { labels.append(target) }
        return labels
    }

    private struct ImageProgressRenderer {
        let enabled: Bool
        var lastKey = ""
        mutating func consume(_ event: ImageMigrationProgress) {
            guard enabled, let image = event.imageReference else { return }
            let key = "\(event.completedImageCount)|\(image)|\(event.phase.rawValue)"
            guard key != lastKey else { return }
            lastKey = key
            switch event.phase {
            case .checkingPreconditions:
                out("\n[\(event.completedImageCount + 1)/\(event.totalImageCount)] \(image)")
            case .exporting: out("  Reading from Morbstack…")
            case .importing: out("  Writing to the destination…")
            case .verifying: out("  Verifying image IDs…")
            case .completedImage: out("  Result: \(event.detail ?? "unknown")")
            default: break
            }
        }
    }

    private struct VolumeProgressRenderer {
        let enabled: Bool
        mutating func consume(_ event: VolumeMigrationProgress) {
            guard enabled, let volume = event.volumeName else { return }
            switch event.phase {
            case .exporting: out("  \(volume): reading \(event.bytesTransferred.map(Format.bytes) ?? "archive") from Morbstack")
            case .creatingDestination: out("  \(volume): creating destination volume")
            case .importing: out("  \(volume): writing \(event.bytesTransferred.map(Format.bytes) ?? "archive")")
            case .completedVolume: out("  \(volume): \(event.detail ?? "completed")")
            default: break
            }
        }
    }

    private static func codableJSON<T: Encodable>(_ value: T) -> Any {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return NSNull() }
        return object
    }

    private static func emitJSON(_ value: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        else {
            errOut("could not encode JSON output")
            return
        }
        out(String(decoding: data, as: UTF8.self))
    }

    private static func usageError(_ message: String) -> Int32 {
        errOut(message)
        errOut("usage: morb migrate --to <runtime|socket> [--dry-run] [--yes]")
        return 2
    }
}
