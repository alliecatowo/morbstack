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

    // MARK: - TECH-4: promoted onto MorbstackKit's shared `TarFormat`
    //
    // Before TECH-4, TarLite had no checksum validation and no base-256 support at
    // all — `parseOctal` decoded a base-256 field's bytes as UTF-8 text, which is
    // garbage, and silently fell back to `0`. The tests below are what that gap looks
    // like once there is something to lose: a real file's content under-skipped, or a
    // corrupted header trusted anyway, either of which would desync the count from
    // here on rather than just mis-stating this one entry.

    func testContiguousFileTypeflagIsCountedAsARegularFile() throws {
        // Typeflag '7' ("contiguous file"): the same shared `TarFormat.kind` table
        // `ContainerTarHeaderReader` and `TarChildWalker` use, both of which have
        // always counted it as a regular file.
        var archive = Data()
        archive.append(header(name: "contiguous", typeflag: UInt8(ascii: "7"), size: 0))
        archive.append(endOfArchive())

        XCTAssertEqual(TarLite.countRegularFiles(at: try write(archive)), 1)
    }

    func testBase256SizeIsDecodedRatherThanSilentlyTreatedAsZero() throws {
        // A size of 600 bytes both exceeds one block (exercising real multi-block
        // skipping) and would previously have been read as `0` by `parseOctal`'s
        // UTF-8 misinterpretation of the base-256 bytes — which under-skips the
        // content, so the very next "header" read is actually still this file's data.
        // That desync would have miscounted (or crashed on) every entry after it; the
        // second, ordinary entry below is only reached if the size was read correctly.
        let content = String(repeating: "x", count: 600)
        var fileHeader = header(name: "data/big.bin", typeflag: UInt8(ascii: "0"), size: 0)
        setBase256Size(&fileHeader, value: UInt64(content.utf8.count))
        var archive = Data()
        archive.append(fileHeader)
        archive.append(Data(content.utf8))
        archive.append(Data(repeating: 0, count: paddingLength(for: content.utf8.count)))
        archive.append(entry(name: "data/after.txt", contents: "ok"))
        archive.append(endOfArchive())

        XCTAssertEqual(TarLite.countRegularFiles(at: try write(archive)), 2)
    }

    func testBase256SizeOverflowStopsCountingRatherThanWrapping() throws {
        // All-0xFF magnitude bytes guarantee the running value exceeds Int64.max
        // before the last byte is folded in — the same fixture `TarArchiveFormatTests`
        // and `TarChildWalkerTests` use for the identical field. `TarLite` used to
        // have no guard here at all.
        var fileHeader = header(name: "data/huge.bin", typeflag: UInt8(ascii: "0"), size: 0)
        var sizeField = [UInt8](repeating: 0xFF, count: 12)
        sizeField[0] = 0x80 | 0xFF
        fileHeader.replaceSubrange(124..<136, with: Data(sizeField))
        recomputeChecksum(&fileHeader)
        let archive = fileHeader

        XCTAssertEqual(TarLite.countRegularFiles(at: try write(archive)), 0)
    }

    func testABadHeaderChecksumStopsCountingRatherThanInventingEntries() throws {
        var archive = Data()
        archive.append(entry(name: "counted", contents: "1"))
        var corrupt = header(name: "data/a.txt", typeflag: UInt8(ascii: "0"), size: 0)
        corrupt[corrupt.startIndex] ^= 0xFF  // breaks the checksum, not the typeflag
        archive.append(corrupt)
        archive.append(entry(name: "never-reached", contents: "2"))

        XCTAssertEqual(TarLite.countRegularFiles(at: try write(archive)), 1)
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

    private func paddingLength(for size: Int) -> Int {
        (512 - size % 512) % 512
    }

    private func setBase256Size(_ block: inout Data, value: UInt64) {
        var sizeField = [UInt8](repeating: 0, count: 12)
        var remaining = value
        for index in stride(from: 11, through: 1, by: -1) {
            sizeField[index] = UInt8(remaining & 0xFF)
            remaining >>= 8
        }
        sizeField[0] = 0x80
        block.replaceSubrange(124..<136, with: Data(sizeField))
        recomputeChecksum(&block)
    }

    /// Recomputes the checksum field in place, treating it as spaces while summing —
    /// the same convention `TarFormat.checksumMatches` uses.
    private func recomputeChecksum(_ block: inout Data) {
        block.replaceSubrange(148..<156, with: Data(repeating: UInt8(ascii: " "), count: 8))
        let checksum = block.reduce(0) { $0 + Int($1) }
        let checksumOctal = String(checksum, radix: 8).leftPadded(to: 6) + "\0 "
        block.replaceSubrange(148..<156, with: Data(checksumOctal.utf8))
    }
}

extension String {
    fileprivate func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}
