// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// `morb migrate images` — streams images engine-to-engine via docker-save/docker-load
// semantics (`GET /images/get` on the source, `POST /images/load` on Morbstack), never
// re-pulling from a registry and never touching the source engine's image store.
//
// The transfer is a temp-file hop, not a socket-to-socket splice: `EngineClient.download`
// (mac/Sources/MorbFeatures/EngineClient.swift) streams the source tar straight to a
// file under `MorbFeaturePaths.migrateDirectory` without ever holding it in memory, and
// `EngineClient.upload` streams that file back out with a real `Content-Length` —
// so peak *memory* use is one read buffer regardless of image size, but peak *disk*
// use is briefly the size of one batch's tar. That is reported and the file is always
// deleted afterward; see ``ImagesCommand/run(arguments:json:)``.

import Foundation
import MorbFeatures

struct ImageCopyItem {
    var reference: String
    var id: String
    var size: Int64
    var status: String  // "planned" | "skipped-present" | "copied" | "failed"
    var detail: String?
}

enum ImagesCommand {

    /// Images per `/images/get` call. "A handful" per the design brief: large enough
    /// that a full-speed migration is not one HTTP round trip per image, small enough
    /// that one failed batch loses a handful of images, not the whole run.
    static let batchSize = 4

    static func run(arguments: [String], json: Bool) -> Int32 {
        let args = parseArgs(arguments, valueFlags: ["from", "filter"])
        let dryRun = args.flag("dry-run")
        let assumeYes = args.flag("yes")
        let includeAll = args.flag("all")
        let filter = args.option("filter")

        let source: MigrationSource
        do {
            source = try SourceResolver.resolve(from: args.option("from"))
        } catch {
            errOut("\(error)")
            return 2
        }

        let (items, planError) = plan(source: source, destination: EngineClient(), filter: filter, includeAll: includeAll)
        if let planError {
            errOut(planError)
            return 2
        }

        let toCopy = items.filter { $0.status == "planned" }
        let totalBytes = toCopy.reduce(Int64(0)) { $0 + $1.size }

        printPlan(items: items, source: source.label)

        if dryRun {
            emit(json: json, data: [
                "dry_run": true,
                "source": source.label,
                "would_copy": toCopy.count,
                "would_copy_bytes": totalBytes,
                "skipped_already_present": items.filter { $0.status == "skipped-present" }.count,
            ]) { out("\n[dry-run] nothing was changed.") }
            return 0
        }

        guard !toCopy.isEmpty else {
            out("\nNothing to copy — Morbstack already has every matching image.")
            return 0
        }

        if !assumeYes {
            switch confirmInteractively(
                "\nCopy \(toCopy.count) image(s), \(Format.bytes(totalBytes)) total, from \(source.label) into Morbstack?"
            ) {
            case .yes: break
            case .no: errOut("cancelled; nothing was changed"); return 2
            case .noTTY: errOut("this needs confirmation and stdin is not a terminal — pass --yes to skip it"); return 2
            }
        }

        MorbFeaturePaths.ensureDirectory(MorbFeaturePaths.migrateDirectory)
        let (results, peakDiskBytes) = copy(items: toCopy, source: source, destination: EngineClient())
        let failed = results.filter { $0.status == "failed" }

        out("")
        out("Peak temporary disk used: \(Format.bytes(peakDiskBytes)) under \(MorbFeaturePaths.migrateDirectory.path)")
        out("(the source tar is written there one batch at a time, then deleted — see docs/migrate.md)")

        emit(json: json, data: [
            "source": source.label,
            "copied": results.filter { $0.status == "copied" }.count,
            "failed": failed.count,
            "skipped_already_present": items.filter { $0.status == "skipped-present" }.count,
            "peak_disk_bytes": peakDiskBytes,
            "items": results.map {
                ["reference": $0.reference, "id": $0.id, "status": $0.status, "detail": $0.detail ?? NSNull()] as [String: Any]
            },
        ]) {
            out("")
            out(failed.isEmpty ? "[ok] all images copied" : "[!!] \(failed.count) image(s) failed to copy:")
            for item in failed {
                out("  \(item.reference): \(item.detail ?? "unknown error")")
            }
        }
        return failed.isEmpty ? 0 : 1
    }

    // MARK: - Planning

    static func plan(
        source: MigrationSource, destination: EngineClient, filter: String?, includeAll: Bool
    ) -> ([ImageCopyItem], String?) {
        let sourceImages: [[String: Any]]
        do {
            sourceImages = try source.client.jsonArray("GET", "/images/json", query: [("all", "0")], timeout: 30)
        } catch {
            return ([], "could not list images on \(source.label): \(error)")
        }
        let destImages = (try? destination.jsonArray("GET", "/images/json", query: [("all", "0")], timeout: 30)) ?? []
        let destIds = Set(destImages.compactMap { JSONRead.string($0, "Id") })

        var items: [ImageCopyItem] = []
        for image in sourceImages {
            guard let id = JSONRead.string(image, "Id") else { continue }
            let tags = (JSONRead.array(image, "RepoTags") as? [String] ?? []).filter { $0 != "<none>:<none>" }
            let size = Int64(JSONRead.int(image, "Size") ?? 0)

            if tags.isEmpty, !includeAll {
                continue  // dangling image, excluded by default
            }
            let reference = tags.first ?? id
            if let filter, !tags.contains(where: { $0.localizedCaseInsensitiveContains(filter) }) {
                continue
            }
            let status = destIds.contains(id) ? "skipped-present" : "planned"
            items.append(ImageCopyItem(reference: reference, id: id, size: size, status: status, detail: nil))
        }
        return (items, nil)
    }

    private static func printPlan(items: [ImageCopyItem], source: String) {
        var table = TextTable(headers: ["IMAGE", "SIZE", "STATUS"], rightAligned: [1])
        for item in items {
            table.add([item.reference, Format.bytes(item.size), item.status])
        }
        out("Images on \(source):")
        out(items.isEmpty ? "  (none matched)" : table.render())
    }

    // MARK: - Copying

    private static func copy(
        items: [ImageCopyItem], source: MigrationSource, destination: EngineClient
    ) -> (results: [ImageCopyItem], peakDiskBytes: Int64) {
        var results: [ImageCopyItem] = []
        var peak: Int64 = 0
        let batches = stride(from: 0, to: items.count, by: batchSize).map {
            Array(items[$0..<min($0 + batchSize, items.count)])
        }

        for (index, batch) in batches.enumerated() {
            let batchBytes = batch.reduce(Int64(0)) { $0 + $1.size }
            out("\nBatch \(index + 1)/\(batches.count) — \(batch.count) image(s), \(Format.bytes(batchBytes)):")
            for item in batch { out("  \(item.reference)  \(Format.bytes(item.size))") }

            let tempFile = MorbFeaturePaths.migrateDirectory
                .appendingPathComponent("images-batch-\(UUID().uuidString).tar", isDirectory: false)
            defer { try? FileManager.default.removeItem(at: tempFile) }

            let started = Date()
            do {
                let query = batch.map { ("names", $0.reference) }
                let (_, bytes) = try source.client.download("GET", "/images/get", query: query, to: tempFile, timeout: 900)
                peak = max(peak, bytes)
                let downloadElapsed = Date().timeIntervalSince(started)
                out("  downloaded \(Format.bytes(bytes)) in \(Format.duration(downloadElapsed))"
                    + " (\(formatRate(bytes: bytes, seconds: downloadElapsed)))")

                let uploadStarted = Date()
                let response = try destination.upload("POST", "/images/load", query: [("quiet", "0")], from: tempFile, timeout: 1800)
                let uploadElapsed = Date().timeIntervalSince(uploadStarted)
                out("  loaded into Morbstack in \(Format.duration(uploadElapsed))"
                    + " (\(formatRate(bytes: bytes, seconds: uploadElapsed)))")

                if response.text.contains("\"errorDetail\"") || response.text.lowercased().contains("\"error\"") {
                    throw EngineError.malformed("/images/load reported an error: \(Format.truncate(response.text, 400))")
                }
                for item in batch {
                    var copied = item
                    copied.status = "copied"
                    results.append(copied)
                }
            } catch {
                out("  [!!] batch failed: \(error)")
                for item in batch {
                    var failedItem = item
                    failedItem.status = "failed"
                    failedItem.detail = "\(error)"
                    results.append(failedItem)
                }
            }
        }
        return (results, peak)
    }
}
