// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The legacy combined-migration report shape. Earlier explicit `images`/`volumes`
// commands did not write it, but `morb migrate verify --report` still understands it
// for compatibility with any report a development checkout produced. The executable
// images-only transaction writes the typed `ImageMigrationTransactionReport` in
// ImageMigrationTransaction.swift instead; it has its own scoped verification and
// rollback guidance and does not imply a volume/config migration.

import Foundation
import MorbFeatures

struct MigrateReportImageItem: Codable {
    var reference: String
    var id: String
    var status: String
}

struct MigrateReportVolumeItem: Codable {
    var name: String
    var status: String
    var bytes: Int64
    var files: Int
}

struct MigrateReport: Codable {
    var timestamp: String
    var source: String
    var sourceSocket: String
    var images: [MigrateReportImageItem]
    var volumes: [MigrateReportVolumeItem]
    var verifyMatch: Int
    var verifyDiffer: Int
    var verifyMissing: Int
    /// Retained solely for decoding legacy reports. No current `morb migrate run`
    /// operation changes Docker CLI context or writes this field.
    var previousDockerContext: String

    enum CodingKeys: String, CodingKey {
        case timestamp, source, sourceSocket, images, volumes
        case verifyMatch, verifyDiffer, verifyMissing, previousDockerContext
    }

    /// Not part of the JSON — set by ``load(from:)`` so a report keeps track of where it
    /// came from without that path being a fact about the migration itself.
    var path: URL?

    func write() throws -> URL {
        MorbFeaturePaths.ensureDirectory(MorbFeaturePaths.migrateDirectory)
        let fileName = timestamp.replacingOccurrences(of: ":", with: "-") + ".json"
        let url = MorbFeaturePaths.migrateDirectory.appendingPathComponent(fileName, isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        return url
    }

    static func load(from url: URL) -> MigrateReport? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var report = try? JSONDecoder().decode(MigrateReport.self, from: data)
        report?.path = url
        return report
    }

    /// The newest report under `MorbFeaturePaths.migrateDirectory`, by filename — file
    /// names are the ISO-8601 timestamp with colons turned to hyphens, which sorts the
    /// same as time, so a plain string sort is enough.
    static func mostRecent() -> MigrateReport? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: MorbFeaturePaths.migrateDirectory, includingPropertiesForKeys: nil)
        else { return nil }
        guard let newest = files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).first
        else { return nil }
        return load(from: newest)
    }
}
