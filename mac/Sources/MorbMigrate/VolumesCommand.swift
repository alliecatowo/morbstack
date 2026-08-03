// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// `morb migrate volumes` — copies named volumes between engines via a helper-container
// tar pipe (the same mechanism `docker cp` itself uses): a throwaway container mounts
// the volume, `GET .../archive` reads it out as a tar, the mirror container on the
// destination gets the same tar `PUT` back in. See mac/Sources/MorbMigrate/
// HelperContainer.swift for why this needs a container at all, and its doc comment for
// why creating one on the *source* engine — which may be Docker Desktop — is the one
// narrow exception to this module's read-only stance on other runtimes.
//
// Bind mounts are deliberately out of scope: they are host paths, already visible to
// Morbstack through `shared_paths` (docs/sharing.md), and copying them would be copying
// a directory that is already right there under a different name.

import Foundation
import MorbFeatures

struct VolumeCopyItem {
    var name: String
    var driver: String
    var status: String  // "planned" | "skipped-exists-non-empty" | "copied" | "failed" | "skipped-unsupported-driver"
    var bytes: Int64 = 0
    var files: Int = 0
    var detail: String?
}

enum VolumesCommand {

    static func run(arguments: [String], json: Bool) -> Int32 {
        let args = parseArgs(arguments, valueFlags: ["from", "filter"])
        let dryRun = args.flag("dry-run")
        let assumeYes = args.flag("yes")
        let overwrite = args.flag("overwrite")
        let filter = args.option("filter")
        let destination = EngineClient()

        let source: MigrationSource
        do {
            source = try SourceResolver.resolve(from: args.option("from"))
        } catch {
            errOut("\(error)")
            return 2
        }

        out("Bind mounts are not volumes and are not copied by this command — the host")
        out("paths they point at are already visible to Morbstack via shared_paths (see")
        out("docs/sharing.md). Only named volumes are handled here.\n")

        let sourceVolumes: [[String: Any]]
        do {
            sourceVolumes = JSONRead.array(try source.client.jsonObject("GET", "/volumes", timeout: 30), "Volumes") as? [[String: Any]] ?? []
        } catch {
            errOut("could not list volumes on \(source.label): \(error)")
            return 2
        }
        let destVolumeNames = Set(
            (JSONRead.array((try? destination.jsonObject("GET", "/volumes", timeout: 30)) ?? [:], "Volumes") as? [[String: Any]] ?? [])
                .compactMap { JSONRead.string($0, "Name") })

        var items: [VolumeCopyItem] = []
        for volume in sourceVolumes {
            guard let name = JSONRead.string(volume, "Name") else { continue }
            if let filter, !name.localizedCaseInsensitiveContains(filter) { continue }
            let driver = JSONRead.string(volume, "Driver") ?? "local"
            var item = VolumeCopyItem(name: name, driver: driver, status: "planned")
            if driver != "local" {
                item.status = "skipped-unsupported-driver"
                item.detail = "driver \(driver) is not \"local\"; migrate volumes only understands local volumes"
            } else if destVolumeNames.contains(name) {
                let empty = isDestinationVolumeEmpty(destination: destination, name: name)
                if empty == false && !overwrite {
                    item.status = "skipped-exists-non-empty"
                    item.detail = "destination volume already has content — pass --overwrite to replace it"
                }
            }
            items.append(item)
        }

        printPlan(items: items, source: source.label)

        let toCopy = items.filter { $0.status == "planned" }
        if dryRun {
            emit(json: json, data: [
                "dry_run": true, "source": source.label, "would_copy": toCopy.count,
            ]) { out("\n[dry-run] nothing was changed.") }
            return 0
        }
        guard !toCopy.isEmpty else {
            out("\nNothing to copy.")
            return 0
        }

        if overwrite {
            out("\n--overwrite is set: any destination volume above with existing content will have that")
            out("content merged with (and any same-named files replaced by) the source volume's content.")
            out("Nothing outside the volumes listed as \"planned\" is touched, and no volume is ever deleted.")
        }
        if !assumeYes {
            switch confirmInteractively("\nCopy \(toCopy.count) volume(s) from \(source.label) into Morbstack?") {
            case .yes: break
            case .no: errOut("cancelled; nothing was changed"); return 2
            case .noTTY: errOut("this needs confirmation and stdin is not a terminal — pass --yes to skip it"); return 2
            }
        }

        MorbFeaturePaths.ensureDirectory(MorbFeaturePaths.migrateDirectory)
        guard let sourceImage = ensureHelperImage(client: source.client, label: source.label, needsCoreutils: false, assumeYes: assumeYes) else {
            errOut("no helper image available on \(source.label); cannot read volume contents")
            return 2
        }
        guard let destImage = ensureHelperImage(client: destination, label: "Morbstack", needsCoreutils: false, assumeYes: assumeYes) else {
            errOut("no helper image available on Morbstack; cannot write volume contents")
            return 2
        }

        var results: [VolumeCopyItem] = []
        for item in toCopy {
            out("\n\(item.name):")
            results.append(copyVolume(item: item, source: source, sourceImage: sourceImage, destination: destination, destImage: destImage))
        }

        let failed = results.filter { $0.status == "failed" }
        emit(json: json, data: [
            "source": source.label,
            "copied": results.filter { $0.status == "copied" }.count,
            "failed": failed.count,
            "items": results.map {
                [
                    "name": $0.name, "status": $0.status, "bytes": $0.bytes, "files": $0.files,
                    "detail": $0.detail ?? NSNull(),
                ] as [String: Any]
            },
        ]) {
            out("")
            out(failed.isEmpty ? "[ok] all volumes copied" : "[!!] \(failed.count) volume(s) failed:")
            for item in failed { out("  \(item.name): \(item.detail ?? "unknown error")") }
        }
        return failed.isEmpty ? 0 : 1
    }

    private static func printPlan(items: [VolumeCopyItem], source: String) {
        var table = TextTable(headers: ["VOLUME", "DRIVER", "STATUS"])
        for item in items { table.add([item.name, item.driver, item.status]) }
        out("Volumes on \(source):")
        out(items.isEmpty ? "  (none matched)" : table.render())
    }

    /// `true`/`false` when the check could run, `nil` when it could not (no image
    /// available yet, or the read failed) — callers treat `nil` like "assume non-empty",
    /// the conservative direction for a check that exists to avoid clobbering data.
    private static func isDestinationVolumeEmpty(destination: EngineClient, name: String) -> Bool? {
        guard let image = HelperImage.anyExisting(on: destination) else { return nil }
        guard let id = try? HelperContainer.createMounted(on: destination, image: image, volumeName: name, readOnly: true) else {
            return nil
        }
        defer { _ = HelperContainer.remove(on: destination, id: id) }
        let tempFile = MorbFeaturePaths.migrateDirectory.appendingPathComponent("empty-check-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: tempFile) }
        MorbFeaturePaths.ensureDirectory(MorbFeaturePaths.migrateDirectory)
        guard (try? destination.download("GET", "/containers/\(id)/archive", query: [("path", "/data")], to: tempFile, timeout: 60)) != nil
        else { return nil }
        return TarLite.countRegularFiles(at: tempFile) == 0
    }

    private static func ensureHelperImage(client: EngineClient, label: String, needsCoreutils: Bool, assumeYes: Bool) -> String? {
        if let existing = needsCoreutils ? HelperImage.existingWithCoreutils(on: client) : HelperImage.anyExisting(on: client) {
            return existing
        }
        out("\nNo suitable image is present on \(label) to run a helper container from.")
        out("morb migrate would pull `alpine:3.20` (about 3 MB) onto \(label) for this purpose.")
        if !assumeYes {
            guard case .yes = confirmInteractively("Pull alpine:3.20 onto \(label) now?") else { return nil }
        }
        do {
            try HelperImage.pull("alpine:3.20", on: client)
            return "alpine:3.20"
        } catch {
            errOut("could not pull alpine:3.20 onto \(label): \(error)")
            return nil
        }
    }

    private static func copyVolume(
        item: VolumeCopyItem, source: MigrationSource, sourceImage: String, destination: EngineClient, destImage: String
    ) -> VolumeCopyItem {
        var result = item
        let tempFile = MorbFeaturePaths.migrateDirectory
            .appendingPathComponent("volume-\(item.name)-\(UUID().uuidString).tar", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        do {
            // Create the destination volume up front, preserving the source's labels —
            // this is the only volume-mutating call in this whole path that is not
            // through the helper container, and it is additive: `POST /volumes/create`
            // is a no-op (200, unchanged) when a volume with this name already exists.
            let sourceInfo = try source.client.jsonObject("GET", "/volumes/\(item.name)", timeout: 15)
            let labels = JSONRead.dictionary(sourceInfo, "Labels") ?? [:]
            try destination.request(
                "POST", "/volumes/create",
                body: try JSONSerialization.data(withJSONObject: ["Name": item.name, "Labels": labels], options: []),
                contentType: "application/json", timeout: 30)

            let sourceContainer = try HelperContainer.createMounted(
                on: source.client, image: sourceImage, volumeName: item.name, readOnly: true)
            defer { _ = HelperContainer.remove(on: source.client, id: sourceContainer) }

            let (_, bytes) = try source.client.download(
                "GET", "/containers/\(sourceContainer)/archive", query: [("path", "/data")], to: tempFile, timeout: 900)
            result.bytes = bytes
            result.files = TarLite.countRegularFiles(at: tempFile)
            out("  read \(Format.bytes(bytes)), \(result.files) file(s) from \(source.label)")

            let destContainer = try HelperContainer.createMounted(
                on: destination, image: destImage, volumeName: item.name, readOnly: false)
            defer { _ = HelperContainer.remove(on: destination, id: destContainer) }

            // The archive was read at path=/data, so its entries are rooted at "data/…";
            // extracting at "/" puts them back at exactly /data on the destination
            // container — the same mount point, same relative layout.
            _ = try destination.upload(
                "PUT", "/containers/\(destContainer)/archive", query: [("path", "/")], from: tempFile, timeout: 900)
            out("  wrote \(Format.bytes(bytes)) into Morbstack's \"\(item.name)\"")
            result.status = "copied"
        } catch {
            result.status = "failed"
            result.detail = "\(error)"
        }
        return result
    }
}
