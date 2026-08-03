// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// `morb migrate verify` — the credibility check. Everything else in this module can
// print "[ok]" and be wrong; this is the one command whose entire job is comparing two
// independently-computed answers and being willing to print "DIFFER" or "MISSING" when
// they disagree. It exits non-zero the moment anything does, on purpose — a verify
// command a script can't gate a decision on is decoration, not verification.
//
// Images are compared by config digest (`Id`), which is exactly what `docker save`/
// `docker load` preserve byte-for-byte and what changes the instant a layer differs.
// Volumes have no equivalent single hash from the Engine API, so this computes one: a
// helper container on each side runs `find . -type f -exec sha256sum {} +`, and the
// sorted manifests are compared line by line. See HelperContainer.swift for why that
// needs a container at all.

import Foundation
import MorbFeatures

enum VerifyOutcome: String { case match = "MATCH", differ = "DIFFER", missing = "MISSING", error = "ERROR" }

struct VerifyItem {
    var kind: String  // "image" | "volume"
    var name: String
    var outcome: VerifyOutcome
    var detail: String?
}

enum VerifyCommand {

    static func run(arguments: [String], json: Bool) -> Int32 {
        let args = parseArgs(arguments, valueFlags: ["from", "images", "volumes", "report"])
        let assumeYes = args.flag("yes")
        let destination = EngineClient()

        let source: MigrationSource
        do {
            source = try SourceResolver.resolve(from: args.option("from"))
        } catch {
            errOut("\(error)")
            return 2
        }

        var imageRefs: [String] = []
        var volumeNames: [String] = []

        if let reportPath = args.option("report") {
            guard let report = MigrateReport.load(from: URL(fileURLWithPath: reportPath)) else {
                errOut("could not read report at \(reportPath)")
                return 2
            }
            imageRefs = report.images.filter { $0.status == "copied" }.map(\.reference)
            volumeNames = report.volumes.filter { $0.status == "copied" }.map(\.name)
        } else if let mostRecent = MigrateReport.mostRecent(), args.option("images") == nil, args.option("volumes") == nil {
            imageRefs = mostRecent.images.filter { $0.status == "copied" }.map(\.reference)
            volumeNames = mostRecent.volumes.filter { $0.status == "copied" }.map(\.name)
            out("Using the most recent migration report: \(mostRecent.path?.path ?? "?")\n")
        }
        if let explicit = args.option("images") {
            imageRefs = explicit.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        if let explicit = args.option("volumes") {
            volumeNames = explicit.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        if imageRefs.isEmpty, volumeNames.isEmpty {
            // Nothing named explicitly and no report to read — fall back to "everything
            // present under the same name on both sides", so `morb migrate verify` is
            // still useful standing alone.
            imageRefs = intersectingImageTags(source: source.client, destination: destination)
            volumeNames = intersectingVolumeNames(source: source.client, destination: destination)
        }

        var results: [VerifyItem] = []
        for ref in imageRefs { results.append(verifyImage(reference: ref, source: source.client, destination: destination)) }

        if !volumeNames.isEmpty {
            let sourceImage = ensureVerifyImage(client: source.client, label: source.label, assumeYes: assumeYes)
            let destImage = ensureVerifyImage(client: destination, label: "Morbstack", assumeYes: assumeYes)
            for name in volumeNames {
                results.append(verifyVolume(name: name, source: source.client, sourceImage: sourceImage, destination: destination, destImage: destImage))
            }
        }

        printResults(results)
        emit(json: json, data: [
            "match": results.filter { $0.outcome == .match }.count,
            "differ": results.filter { $0.outcome == .differ }.count,
            "missing": results.filter { $0.outcome == .missing }.count,
            "error": results.filter { $0.outcome == .error }.count,
            "items": results.map {
                ["kind": $0.kind, "name": $0.name, "outcome": $0.outcome.rawValue, "detail": $0.detail ?? NSNull()] as [String: Any]
            },
        ]) {}

        return results.allSatisfy { $0.outcome == .match } ? 0 : 1
    }

    // MARK: - Images

    private static func verifyImage(reference: String, source: EngineClient, destination: EngineClient) -> VerifyItem {
        let sourceInfo = try? source.jsonObject("GET", "/images/\(reference)/json", timeout: 15)
        let destInfo = try? destination.jsonObject("GET", "/images/\(reference)/json", timeout: 15)
        guard let sourceID = sourceInfo.flatMap({ JSONRead.string($0, "Id") }) else {
            return VerifyItem(kind: "image", name: reference, outcome: .missing, detail: "not found on \(reference)'s source")
        }
        guard let destID = destInfo.flatMap({ JSONRead.string($0, "Id") }) else {
            return VerifyItem(kind: "image", name: reference, outcome: .missing, detail: "not found on Morbstack")
        }
        if sourceID == destID {
            return VerifyItem(kind: "image", name: reference, outcome: .match, detail: sourceID)
        }
        return VerifyItem(kind: "image", name: reference, outcome: .differ, detail: "\(sourceID) != \(destID)")
    }

    private static func intersectingImageTags(source: EngineClient, destination: EngineClient) -> [String] {
        let sourceTags = Set((try? source.jsonArray("GET", "/images/json", timeout: 15))?.flatMap {
            (JSONRead.array($0, "RepoTags") as? [String] ?? []).filter { $0 != "<none>:<none>" }
        } ?? [])
        let destTags = Set((try? destination.jsonArray("GET", "/images/json", timeout: 15))?.flatMap {
            (JSONRead.array($0, "RepoTags") as? [String] ?? []).filter { $0 != "<none>:<none>" }
        } ?? [])
        return Array(sourceTags.intersection(destTags)).sorted()
    }

    // MARK: - Volumes

    private static let manifestCmd = ["sh", "-c", "cd /data && find . -type f -exec sha256sum {} + 2>/dev/null | sort"]

    private static func verifyVolume(
        name: String, source: EngineClient, sourceImage: String?, destination: EngineClient, destImage: String?
    ) -> VerifyItem {
        guard let sourceImage else {
            return VerifyItem(kind: "volume", name: name, outcome: .error, detail: "no helper image available on the source")
        }
        guard let destImage else {
            return VerifyItem(kind: "volume", name: name, outcome: .error, detail: "no helper image available on Morbstack")
        }
        let sourceManifest: String
        let destManifest: String
        do {
            sourceManifest = try HelperContainer.run(on: source, image: sourceImage, volumeName: name, cmd: manifestCmd)
        } catch {
            return VerifyItem(kind: "volume", name: name, outcome: .missing, detail: "reading source: \(error)")
        }
        do {
            destManifest = try HelperContainer.run(on: destination, image: destImage, volumeName: name, cmd: manifestCmd)
        } catch {
            return VerifyItem(kind: "volume", name: name, outcome: .missing, detail: "reading Morbstack copy: \(error)")
        }

        if sourceManifest == destManifest {
            let lines = sourceManifest.split(separator: "\n").count
            return VerifyItem(kind: "volume", name: name, outcome: .match, detail: "\(lines) file(s) match")
        }

        let sourceLines = Set(sourceManifest.split(separator: "\n").map(String.init))
        let destLines = Set(destManifest.split(separator: "\n").map(String.init))
        let onlyInSource = sourceLines.subtracting(destLines).sorted().prefix(5)
        let onlyInDest = destLines.subtracting(sourceLines).sorted().prefix(5)
        var detail = "manifests differ"
        if !onlyInSource.isEmpty { detail += "; only on source: " + onlyInSource.joined(separator: "; ") }
        if !onlyInDest.isEmpty { detail += "; only on Morbstack: " + onlyInDest.joined(separator: "; ") }
        return VerifyItem(kind: "volume", name: name, outcome: .differ, detail: detail)
    }

    private static func intersectingVolumeNames(source: EngineClient, destination: EngineClient) -> [String] {
        let sourceNames = Set((JSONRead.array((try? source.jsonObject("GET", "/volumes", timeout: 15)) ?? [:], "Volumes") as? [[String: Any]] ?? [])
            .compactMap { JSONRead.string($0, "Name") })
        let destNames = Set((JSONRead.array((try? destination.jsonObject("GET", "/volumes", timeout: 15)) ?? [:], "Volumes") as? [[String: Any]] ?? [])
            .compactMap { JSONRead.string($0, "Name") })
        return Array(sourceNames.intersection(destNames)).sorted()
    }

    private static func ensureVerifyImage(client: EngineClient, label: String, assumeYes: Bool) -> String? {
        if let existing = HelperImage.existingWithCoreutils(on: client) { return existing }
        out("No image with find/sha256sum is present on \(label); verify would pull `alpine:3.20` there.")
        if !assumeYes {
            guard case .yes = confirmInteractively("Pull alpine:3.20 onto \(label) now?") else { return nil }
        }
        return (try? HelperImage.pull("alpine:3.20", on: client)).map { "alpine:3.20" }
    }

    private static func printResults(_ results: [VerifyItem]) {
        var table = TextTable(headers: ["KIND", "NAME", "RESULT", "DETAIL"])
        for item in results {
            table.add([item.kind, item.name, item.outcome.rawValue, Format.truncate(item.detail ?? "", 60)])
        }
        out(results.isEmpty ? "Nothing to verify." : table.render())
    }
}
