// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import XCTest

@testable import MorbMigrate

/// TarLite feeds one report line — the per-volume archive file count `morb migrate
/// volumes` records after an export. It must count regular files exactly on a
/// well-formed ustar stream and degrade to `0` on anything else, because the copy
/// already succeeded or failed independently of this count.
final class TarLiteTests: XCTestCase {

    func testCountsRegularFilesAndSkipsDirectories() throws {
        var archive = Data()
        archive.append(header(name: "data/", typeflag: UInt8(ascii: "5"), size: 0))
        archive.append(entry(name: "data/a.txt", contents: "hello"))
        archive.append(entry(name: "data/b.bin", contents: String(repeating: "x", count: 600)))
        archive.append(endOfArchive())

        XCTAssertEqual(TarLite.countRegularFiles(at: try write(archive)), 2)
    }

    func testCountsHistoricalNulTypeflagAsRegularFile() throws {
        var archive = Data()
        archive.append(entry(name: "old-style", contents: "v7", typeflag: 0))
        archive.append(endOfArchive())

        XCTAssertEqual(TarLite.countRegularFiles(at: try write(archive)), 1)
    }

    func testSymlinksAndHardlinksAreNotCounted() throws {
        var archive = Data()
        archive.append(header(name: "link", typeflag: UInt8(ascii: "2"), size: 0))
        archive.append(header(name: "hard", typeflag: UInt8(ascii: "1"), size: 0))
        archive.append(entry(name: "real", contents: "1"))
        archive.append(endOfArchive())

        XCTAssertEqual(TarLite.countRegularFiles(at: try write(archive)), 1)
    }

    func testNonTarInputReturnsZeroInsteadOfThrowing() throws {
        XCTAssertEqual(TarLite.countRegularFiles(at: try write(Data("not a tar".utf8))), 0)
        XCTAssertEqual(TarLite.countRegularFiles(at: try write(Data())), 0)
    }

    func testMissingFileReturnsZero() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("tarlite-missing-\(UUID().uuidString)")
        XCTAssertEqual(TarLite.countRegularFiles(at: missing), 0)
    }

    func testTruncatedArchiveCountsOnlyCompleteHeaders() throws {
        var archive = Data()
        archive.append(entry(name: "complete", contents: "ok"))
        // A header that promises more data than the file contains.
        archive.append(header(name: "truncated", typeflag: UInt8(ascii: "0"), size: 4096))
        archive.append(Data(repeating: 0x41, count: 100))

        XCTAssertEqual(TarLite.countRegularFiles(at: try write(archive)), 2)
    }

    // MARK: - ustar construction

    private func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tarlite-test-\(UUID().uuidString).tar")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func entry(name: String, contents: String, typeflag: UInt8 = UInt8(ascii: "0")) -> Data {
        let body = Data(contents.utf8)
        var data = header(name: name, typeflag: typeflag, size: body.count)
        data.append(body)
        let padding = (512 - body.count % 512) % 512
        data.append(Data(repeating: 0, count: padding))
        return data
    }

    private func header(name: String, typeflag: UInt8, size: Int) -> Data {
        var block = Data(repeating: 0, count: 512)
        block.replaceSubrange(0..<min(100, name.utf8.count), with: Data(name.utf8.prefix(100)))
        // mode / uid / gid — octal ASCII, NUL-terminated.
        block.replaceSubrange(100..<108, with: Data("0000644\0".utf8))
        block.replaceSubrange(108..<116, with: Data("0000000\0".utf8))
        block.replaceSubrange(116..<124, with: Data("0000000\0".utf8))
        let sizeOctal = String(String(size, radix: 8).leftPadded(to: 11)) + "\0"
        block.replaceSubrange(124..<136, with: Data(sizeOctal.utf8))
        block.replaceSubrange(136..<148, with: Data("00000000000\0".utf8))
        block[156] = typeflag
        block.replaceSubrange(257..<263, with: Data("ustar\0".utf8))
        block.replaceSubrange(263..<265, with: Data("00".utf8))
        // Checksum over the block with the checksum field treated as spaces.
        block.replaceSubrange(148..<156, with: Data(repeating: UInt8(ascii: " "), count: 8))
        let checksum = block.reduce(0) { $0 + Int($1) }
        let checksumOctal = String(checksum, radix: 8).leftPadded(to: 6) + "\0 "
        block.replaceSubrange(148..<156, with: Data(checksumOctal.utf8))
        return block
    }

    private func endOfArchive() -> Data {
        Data(repeating: 0, count: 1024)
    }
}

extension String {
    fileprivate func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}
