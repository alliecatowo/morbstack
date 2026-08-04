// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import MorbFeatures
import XCTest

final class ImageArchiveImportRequestTests: XCTestCase {

    private func temporaryFile(named name: String, data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("morb-image-import-\(UUID().uuidString)-\(name)")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testRegularNonemptyFileBecomesReviewedRequestWithoutInspectingContents() throws {
        let archive = try temporaryFile(named: "image.tar", data: Data(repeating: 0xA5, count: 1_337))

        let request = try ImageArchiveImportRequest(archiveURL: archive)

        XCTAssertEqual(request.archiveURL, archive)
        XCTAssertEqual(request.bytes, 1_337)
        XCTAssertNotEqual(request.fileIdentity.inode, 0)
        XCTAssertEqual(ImageArchiveImporter.engineRequestDescription, "POST /images/load?quiet=1")
    }

    func testSelectionPolicyAdmitsDockerTarAndCompressedTarFilenameForms() {
        [
            "image.tar", "image.tar.gz", "image.tgz", "image.tar.bz2", "image.tbz",
            "image.tbz2", "image.tar.xz", "image.txz", "image.tar.zst", "image.tzst",
        ].forEach { filename in
            XCTAssertTrue(ImageArchiveImportSelectionPolicy.accepts(filename: filename), filename)
        }
        ["image.zip", "image.tar.gz.backup", "image", "image.tar.zstd"].forEach { filename in
            XCTAssertFalse(ImageArchiveImportSelectionPolicy.accepts(filename: filename), filename)
        }
    }

    func testEmptyFileIsRejectedBeforeAnyEngineConnection() throws {
        let archive = try temporaryFile(named: "empty.tar", data: Data())

        XCTAssertThrowsError(try ImageArchiveImportRequest(archiveURL: archive)) { error in
            XCTAssertEqual(error as? ImageArchiveImportError, .archiveIsEmpty)
        }
    }

    func testDirectoryIsRejectedBeforeAnyEngineConnection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("morb-image-import-directory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try ImageArchiveImportRequest(archiveURL: directory)) { error in
            XCTAssertEqual(error as? ImageArchiveImportError, .archiveIsNotAFile)
        }
    }

    func testChangedFileSizeIsRejectedBeforeOpeningEngineSocket() throws {
        let archive = try temporaryFile(named: "changed.tar", data: Data([0x01]))
        let reviewed = try ImageArchiveImportRequest(archiveURL: archive)
        try Data([0x01, 0x02]).write(to: archive, options: .atomic)

        XCTAssertThrowsError(
            try ImageArchiveImporter.load(
                reviewed,
                engine: EngineClient(socketPath: "/tmp/morbstack-import-test-no-socket"))
        ) { error in
            XCTAssertEqual(error as? ImageArchiveImportError, .archiveSizeChanged)
        }
    }

    func testSameSizeReplacementIsRejectedBeforeOpeningEngineSocket() throws {
        let archive = try temporaryFile(named: "same-size.tar", data: Data([0x01]))
        let reviewed = try ImageArchiveImportRequest(archiveURL: archive)
        try Data([0x02]).write(to: archive, options: .atomic)

        XCTAssertThrowsError(
            try ImageArchiveImporter.load(
                reviewed,
                engine: EngineClient(socketPath: "/tmp/morbstack-import-test-no-socket"))
        ) { error in
            XCTAssertEqual(error as? ImageArchiveImportError, .archiveIdentityChanged)
        }
    }
}
