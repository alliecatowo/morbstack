// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Pure logic only: path validation, name safety, the incremental tar child-walker's
// handling of a synthetic byte stream, and the pre-engine-contact validation branch of
// `VolumeContentBrowser.list(volumeName:)`. Nothing here starts an engine, creates a
// helper container, or touches a real Docker volume — see AGENTS.md/CLAUDE.md on why
// that stays out of a unit test and belongs to a live capture instead.

import XCTest

@testable import MorbFeatures

// MARK: - Path and name validation

final class VolumeContentBrowserPathTests: XCTestCase {

    func testNormalizeAcceptsRootAndOrdinaryAbsolutePaths() throws {
        XCTAssertEqual(try VolumeContentBrowser.normalize(path: "/"), "/")
        XCTAssertEqual(try VolumeContentBrowser.normalize(path: "/logs"), "/logs")
        XCTAssertEqual(try VolumeContentBrowser.normalize(path: "/a/b/c"), "/a/b/c")
    }

    func testNormalizeCollapsesRepeatedSlashes() throws {
        XCTAssertEqual(try VolumeContentBrowser.normalize(path: "/a//b/"), "/a/b")
    }

    func testNormalizeRejectsRelativeAndTraversalPaths() {
        for bad in ["relative", "/a/../b", "/a/./b", "", "not-absolute", "/.."] {
            XCTAssertThrowsError(try VolumeContentBrowser.normalize(path: bad), "expected rejection of \(bad)") {
                error in
                XCTAssertEqual(error as? VolumeContentBrowserError, .invalidPath)
            }
        }
    }

    func testNormalizeRejectsControlCharacters() {
        XCTAssertThrowsError(try VolumeContentBrowser.normalize(path: "/a\u{0}b"))
        XCTAssertThrowsError(try VolumeContentBrowser.normalize(path: "/a\nb"))
    }

    func testNormalizeRejectsOverlongPaths() {
        let long = "/" + String(repeating: "a", count: 5_000)
        XCTAssertThrowsError(try VolumeContentBrowser.normalize(path: long))
    }

    func testSafeChildNameAcceptsOrdinaryNames() {
        XCTAssertTrue(VolumeContentBrowser.isSafeChildName("file.txt"))
        XCTAssertTrue(VolumeContentBrowser.isSafeChildName("a"))
        XCTAssertTrue(VolumeContentBrowser.isSafeChildName("..hidden"))
    }

    func testSafeChildNameRejectsDotAndDotDot() {
        XCTAssertFalse(VolumeContentBrowser.isSafeChildName("."))
        XCTAssertFalse(VolumeContentBrowser.isSafeChildName(".."))
    }

    func testSafeChildNameRejectsSlashAndControlCharacters() {
        XCTAssertFalse(VolumeContentBrowser.isSafeChildName("a/b"))
        XCTAssertFalse(VolumeContentBrowser.isSafeChildName("a\u{0}b"))
        XCTAssertFalse(VolumeContentBrowser.isSafeChildName("a\nb"))
    }

    func testSafeChildNameRejectsEmptyAndOverlong() {
        XCTAssertFalse(VolumeContentBrowser.isSafeChildName(""))
        XCTAssertFalse(VolumeContentBrowser.isSafeChildName(String(repeating: "a", count: 256)))
        XCTAssertTrue(VolumeContentBrowser.isSafeChildName(String(repeating: "a", count: 255)))
    }

    func testChildPathJoinsUnderRoot() throws {
        XCTAssertEqual(try VolumeContentBrowser.childPath(of: "/", name: "etc"), "/etc")
        XCTAssertEqual(try VolumeContentBrowser.childPath(of: "/etc", name: "hosts"), "/etc/hosts")
    }

    func testChildPathRejectsAnUnsafeName() {
        XCTAssertThrowsError(try VolumeContentBrowser.childPath(of: "/", name: "..")) { error in
            XCTAssertEqual(error as? VolumeContentBrowserError, .invalidPath)
        }
        XCTAssertThrowsError(try VolumeContentBrowser.childPath(of: "/", name: "a/b"))
    }

    func testSortedEntriesPutsDirectoriesFirstThenAlphabetical() {
        let entries: [VolumeContentEntry] = [
            .init(name: "zeta.txt", kind: .file, size: 0, modificationDate: nil, linkTarget: nil),
            .init(name: "beta", kind: .directory, size: 0, modificationDate: nil, linkTarget: nil),
            .init(name: "alpha.txt", kind: .file, size: 0, modificationDate: nil, linkTarget: nil),
            .init(name: "alpha", kind: .directory, size: 0, modificationDate: nil, linkTarget: nil),
        ]
        let sorted = VolumeContentBrowser.sortedEntries(entries)
        XCTAssertEqual(sorted.map(\.name), ["alpha", "beta", "alpha.txt", "zeta.txt"])
    }
}

// MARK: - X-Docker-Container-Path-Stat header decoding

final class VolumeContentBrowserPathStatTests: XCTestCase {

    func testDecodePathStatReadsTheDocumentedShape() throws {
        // mode 2147483648 == 0x8000_0000 == Go's os.ModeDir.
        let json = """
            {"name":"logs","size":4096,"mode":2147483648,"mtime":"2026-01-01T00:00:00Z","linkTarget":""}
            """
        let header = Data(json.utf8).base64EncodedString()
        let stat = try VolumeContentBrowser.decodePathStat(header)
        XCTAssertEqual(stat.name, "logs")
        XCTAssertTrue(stat.isDirectory)
        XCTAssertFalse(stat.isSymlink)
    }

    func testDecodePathStatRecognizesSymlinkBit() throws {
        // mode 134217728 == 0x0800_0000 == Go's os.ModeSymlink.
        let json = """
            {"name":"current","size":7,"mode":134217728,"mtime":"2026-01-01T00:00:00Z","linkTarget":"v1"}
            """
        let header = Data(json.utf8).base64EncodedString()
        let stat = try VolumeContentBrowser.decodePathStat(header)
        XCTAssertTrue(stat.isSymlink)
        XCTAssertFalse(stat.isDirectory)
        XCTAssertEqual(stat.linkTarget, "v1")
    }

    func testDecodePathStatRejectsInvalidBase64() {
        XCTAssertThrowsError(try VolumeContentBrowser.decodePathStat("not base64!!! "))
    }

    func testDecodePathStatRejectsNonJSON() {
        let header = Data("not json".utf8).base64EncodedString()
        XCTAssertThrowsError(try VolumeContentBrowser.decodePathStat(header))
    }

    func testDecodePathStatRejectsMissingName() {
        let header = Data("{\"size\":0}".utf8).base64EncodedString()
        XCTAssertThrowsError(try VolumeContentBrowser.decodePathStat(header))
    }

    func testDecodePathStatRejectsOverlongHeader() {
        let huge = String(repeating: "A", count: VolumeContentBrowser.maximumStatHeaderBytes + 100)
        XCTAssertThrowsError(try VolumeContentBrowser.decodePathStat(huge))
    }
}

// MARK: - `list(volumeName:)` pre-engine-contact validation

/// These exercise only the branch of `list` that runs before the first byte reaches a
/// socket: an invalid volume name is rejected before `engine` is ever asked to do
/// anything, so pointing it at a socket path that cannot exist proves that.
final class VolumeContentBrowserListValidationTests: XCTestCase {

    private func unreachableEngine() -> EngineClient {
        EngineClient(socketPath: "/private/tmp/morbstack-tests-no-such-socket-\(UUID().uuidString)")
    }

    func testRejectsAnEmptyVolumeNameBeforeContactingTheEngine() {
        XCTAssertThrowsError(
            try VolumeContentBrowser.list(volumeName: "", engine: unreachableEngine())
        ) { error in
            XCTAssertEqual(error as? VolumeContentBrowserError, .invalidVolumeName)
        }
    }

    func testRejectsAVolumeNameWithPathSeparatorsBeforeContactingTheEngine() {
        XCTAssertThrowsError(
            try VolumeContentBrowser.list(volumeName: "../etc", engine: unreachableEngine())
        ) { error in
            XCTAssertEqual(error as? VolumeContentBrowserError, .invalidVolumeName)
        }
    }

    func testRejectsAnInvalidRequestPathBeforeContactingTheEngine() {
        XCTAssertThrowsError(
            try VolumeContentBrowser.list(volumeName: "myvolume", path: "not-absolute", engine: unreachableEngine())
        ) { error in
            XCTAssertEqual(error as? VolumeContentBrowserError, .invalidPath)
        }
    }
}

// MARK: - TarChildWalker

final class TarChildWalkerTests: XCTestCase {

    func testWalksImmediateChildrenOnlyAndStopsAtEndOfArchive() throws {
        var archive = Data()
        archive.append(header(name: "data/", typeflag: directoryType, size: 0))  // the root itself
        archive.append(entry(name: "data/a.txt", contents: "hi"))
        archive.append(header(name: "data/sub/", typeflag: directoryType, size: 0))
        archive.append(entry(name: "data/sub/nested.txt", contents: "grandchild"))
        archive.append(endOfArchive())

        var walker = makeWalker()
        try walker.feed(archive)

        XCTAssertTrue(walker.isFinished)
        XCTAssertFalse(walker.isTruncated)
        XCTAssertEqual(walker.rejectedCount, 0)
        XCTAssertEqual(Set(walker.children.map(\.name)), ["a.txt", "sub"])
        XCTAssertEqual(walker.children.first(where: { $0.name == "sub" })?.kind, .directory)
        XCTAssertEqual(walker.children.first(where: { $0.name == "a.txt" })?.kind, .file)
    }

    func testASiblingDirectorySharingAPrefixIsNotMistakenForAChild() throws {
        var archive = Data()
        archive.append(entry(name: "data-old/file.txt", contents: "not mine"))
        archive.append(entry(name: "data/keep.txt", contents: "mine"))
        archive.append(endOfArchive())

        var walker = makeWalker()
        try walker.feed(archive)

        XCTAssertEqual(walker.children.map(\.name), ["keep.txt"])
        XCTAssertEqual(walker.rejectedCount, 0, "an out-of-root entry is skipped, not counted as rejected")
    }

    func testALiteralDotDotChildIsRejectedAndCounted() throws {
        var archive = Data()
        archive.append(header(name: "data/..", typeflag: directoryType, size: 0))
        archive.append(entry(name: "data/ok.txt", contents: "fine"))
        archive.append(endOfArchive())

        var walker = makeWalker()
        try walker.feed(archive)

        XCTAssertEqual(walker.children.map(\.name), ["ok.txt"])
        XCTAssertEqual(walker.rejectedCount, 1)
    }

    func testAPaxOverriddenPathCarryingAControlCharacterIsRejected() throws {
        var archive = Data()
        archive.append(paxHeader(records: [("path", "data/bad\u{7}name")]))
        archive.append(header(name: "data/placeholder", typeflag: fileType, size: 0))
        archive.append(endOfArchive())

        var walker = makeWalker()
        try walker.feed(archive)

        XCTAssertEqual(walker.children, [])
        XCTAssertEqual(walker.rejectedCount, 1)
    }

    func testGNULongNameEntryIsUsedInPlaceOfTheTruncatedUstarName() throws {
        let longName = "data/" + String(repeating: "n", count: 150) + ".txt"
        var archive = Data()
        archive.append(gnuLongNameHeader(longName: longName, includeTrailingNUL: false))
        archive.append(header(name: "data/short", typeflag: fileType, size: 0))
        archive.append(endOfArchive())

        var walker = makeWalker()
        try walker.feed(archive)

        XCTAssertEqual(walker.children.count, 1)
        XCTAssertEqual(walker.children.first?.name, String(repeating: "n", count: 150) + ".txt")
    }

    func testGNULongNameWithARealWriterSTrailingNULIsNotPoisoned() throws {
        // Real GNU writers declare the field's size *including* the NUL terminator.
        // Keeping that byte in the name would make every long-named entry fail
        // `isSafeChildName`'s control-character check.
        let longName = "data/" + String(repeating: "m", count: 120) + ".bin"
        var archive = Data()
        archive.append(gnuLongNameHeader(longName: longName, includeTrailingNUL: true))
        archive.append(header(name: "data/short", typeflag: fileType, size: 0))
        archive.append(endOfArchive())

        var walker = makeWalker()
        try walker.feed(archive)

        XCTAssertEqual(walker.rejectedCount, 0)
        XCTAssertEqual(walker.children.first?.name, String(repeating: "m", count: 120) + ".bin")
    }

    func testPAXExtendedHeaderOverridesTheUstarPath() throws {
        var archive = Data()
        archive.append(paxHeader(records: [("path", "data/pax-name.txt")]))
        archive.append(header(name: "data/wrong-name.txt", typeflag: fileType, size: 0))
        archive.append(endOfArchive())

        var walker = makeWalker()
        try walker.feed(archive)

        XCTAssertEqual(walker.children.map(\.name), ["pax-name.txt"])
    }

    func testUstarPrefixFieldIsPrependedToTheName() throws {
        var archive = Data()
        archive.append(header(name: "short.txt", typeflag: fileType, size: 0, prefix: "data"))
        archive.append(endOfArchive())

        var walker = makeWalker()
        try walker.feed(archive)

        XCTAssertEqual(walker.children.map(\.name), ["short.txt"])
    }

    func testBase256SizeIsDecodedCorrectly() throws {
        let size = 600  // > 512, so this also exercises multi-block padding.
        var archive = Data()
        var fileHeader = header(name: "data/big.bin", typeflag: fileType, size: 0)
        setBase256Size(&fileHeader, value: UInt64(size))
        archive.append(fileHeader)
        archive.append(Data(repeating: 0x41, count: size))
        archive.append(Data(repeating: 0, count: paddingLength(for: size)))
        archive.append(endOfArchive())

        var walker = makeWalker()
        try walker.feed(archive)

        XCTAssertEqual(walker.children.count, 1)
        XCTAssertEqual(walker.children.first?.size, Int64(size))
    }

    func testBase256SizeOverflowIsRefusedRatherThanWrapped() throws {
        var fileHeader = header(name: "data/huge.bin", typeflag: fileType, size: 0)
        // All-0xFF magnitude bytes guarantee the running value exceeds Int64.max before
        // the last byte is folded in.
        var sizeField = [UInt8](repeating: 0xFF, count: 12)
        sizeField[0] = 0x80 | 0xFF
        fileHeader.replaceSubrange(124..<136, with: Data(sizeField))
        recomputeChecksum(&fileHeader)
        var archive = Data()
        archive.append(fileHeader)

        var walker = makeWalker()
        XCTAssertThrowsError(try walker.feed(archive)) { error in
            XCTAssertEqual(error as? TarChildWalker.Failure, .malformedNumericField("size"))
        }
    }

    func testABadHeaderChecksumStopsTheReadCleanlyRatherThanInventingEntries() throws {
        var corrupt = header(name: "data/a.txt", typeflag: fileType, size: 0)
        // Flip a byte in the (already checksummed) name field.
        corrupt[0] = corrupt[0] ^ 0xFF
        var archive = Data()
        archive.append(corrupt)

        var walker = makeWalker()
        XCTAssertThrowsError(try walker.feed(archive)) { error in
            XCTAssertEqual(error as? TarChildWalker.Failure, .badChecksum)
        }
        XCTAssertEqual(walker.children, [])
    }

    func testATruncatedStreamDoesNotInventEntriesAndDoesNotThrow() throws {
        let full = header(name: "data/a.txt", typeflag: fileType, size: 0)
        var walker = makeWalker()
        try walker.feed(full.prefix(300))  // fewer than one full 512-byte header block

        XCTAssertEqual(walker.children, [])
        XCTAssertFalse(walker.isFinished)
        XCTAssertFalse(walker.isTruncated)
    }

    func testEntryCountBeyondMaxEntriesTruncatesRatherThanGrowingWithoutBound() throws {
        var archive = Data()
        archive.append(entry(name: "data/a.txt", contents: "1"))
        archive.append(entry(name: "data/b.txt", contents: "2"))
        archive.append(entry(name: "data/c.txt", contents: "3"))
        archive.append(endOfArchive())

        var walker = makeWalker(maxEntries: 2)
        try walker.feed(archive)

        XCTAssertEqual(walker.children.count, 2)
        XCTAssertTrue(walker.isTruncated)
        XCTAssertTrue(walker.isFinished)
    }

    func testHeadersScannedBeyondMaxScannedStopsAPathologicalArchive() throws {
        var archive = Data()
        archive.append(entry(name: "data/a.txt", contents: "1"))
        archive.append(entry(name: "data/b.txt", contents: "2"))
        archive.append(endOfArchive())

        var walker = makeWalker(maxScanned: 1)
        try walker.feed(archive)

        XCTAssertEqual(walker.children.map(\.name), ["a.txt"])
        XCTAssertTrue(walker.isTruncated)
        XCTAssertTrue(walker.isFinished)
    }

    func testAnImplausibleAuxHeaderLengthIsSkippedRatherThanBuffered() throws {
        var archive = Data()
        // Declares a GNU long-name payload far larger than maxAuxDataBytes; the walker
        // must not hold that many bytes, and the following entry keeps its own literal
        // ustar name rather than hanging or crashing.
        let longNameHeader = header(name: "", typeflag: UInt8(ascii: "L"), size: 4_096)
        archive.append(longNameHeader)
        // The full padded data section this "L" header declares — not just trailing
        // pad bytes — since `TarChildWalker` skips `paddedSize(size)` bytes whole.
        archive.append(Data(repeating: UInt8(ascii: "x"), count: 4_096 + paddingLength(for: 4_096)))
        archive.append(header(name: "data/direct.txt", typeflag: fileType, size: 0))
        archive.append(endOfArchive())

        var walker = makeWalker(maxAuxDataBytes: 8)
        try walker.feed(archive)

        XCTAssertEqual(walker.children.map(\.name), ["direct.txt"])
    }

    func testSymlinkCarriesItsLinkTargetAndOtherKindsNeverDo() throws {
        var archive = Data()
        var symlinkHeader = header(name: "data/current", typeflag: symlinkType, size: 0)
        symlinkHeader.replaceSubrange(157..<(157 + "../shared/target".utf8.count), with: Data("../shared/target".utf8))
        recomputeChecksum(&symlinkHeader)
        archive.append(symlinkHeader)

        var dirHeaderWithStrayLinkname = header(name: "data/dir", typeflag: directoryType, size: 0)
        dirHeaderWithStrayLinkname.replaceSubrange(157..<161, with: Data("junk".utf8))
        recomputeChecksum(&dirHeaderWithStrayLinkname)
        archive.append(dirHeaderWithStrayLinkname)
        archive.append(endOfArchive())

        var walker = makeWalker()
        try walker.feed(archive)

        let symlink = walker.children.first(where: { $0.name == "current" })
        let directory = walker.children.first(where: { $0.name == "dir" })
        XCTAssertEqual(symlink?.kind, .symlink)
        XCTAssertEqual(symlink?.linkTarget, "../shared/target")
        XCTAssertEqual(directory?.kind, .directory)
        XCTAssertNil(directory?.linkTarget)
    }

    func testDirectorySizeIsAlwaysZeroRegardlessOfTheHeaderSField() throws {
        var archive = Data()
        archive.append(header(name: "data/dir", typeflag: directoryType, size: 4_096))
        archive.append(endOfArchive())

        var walker = makeWalker()
        try walker.feed(archive)

        XCTAssertEqual(walker.children.first?.size, 0)
    }

    func testTypeflagMapping() throws {
        var archive = Data()
        archive.append(header(name: "data/regular", typeflag: UInt8(ascii: "0"), size: 0))
        archive.append(header(name: "data/legacy", typeflag: 0, size: 0))
        archive.append(header(name: "data/dev", typeflag: UInt8(ascii: "3"), size: 0))
        archive.append(endOfArchive())

        var walker = makeWalker()
        try walker.feed(archive)

        XCTAssertEqual(walker.children.first(where: { $0.name == "regular" })?.kind, .file)
        XCTAssertEqual(walker.children.first(where: { $0.name == "legacy" })?.kind, .file)
        XCTAssertEqual(walker.children.first(where: { $0.name == "dev" })?.kind, .other)
    }

    func testContiguousFileTypeflagIsTreatedAsARegularFile() throws {
        // Typeflag '7' ("contiguous file") is a regular file for every practical
        // purpose, and `ContainerTarHeaderReader`/`TarLite` have always agreed — this
        // walker's own inline typeflag switch did not, and would have shown a
        // contiguous-file entry as "other" until it adopted the shared
        // `TarFormat.kind(forTypeflag:)` table.
        var archive = Data()
        archive.append(header(name: "data/contiguous", typeflag: UInt8(ascii: "7"), size: 0))
        archive.append(endOfArchive())

        var walker = makeWalker()
        try walker.feed(archive)

        XCTAssertEqual(walker.children.first?.kind, .file)
    }

    func testGNULongLinkOverridesTheTruncatedUstarLinkname() throws {
        // A symlink target longer than the ustar `linkname` field's 100 bytes needs a
        // GNU `K` (long link) entry the same way a long name needs `L`. This walker
        // used to skip `K` entirely ("not needed for listing"), which was wrong: it
        // does show a symlink's target, so a long one was silently truncated to 100
        // bytes instead of read in full.
        let longTarget = "../" + String(repeating: "shared/", count: 20) + "target"
        XCTAssertGreaterThan(longTarget.utf8.count, 100)

        var archive = Data()
        archive.append(gnuLongLinkHeader(longLink: longTarget, includeTrailingNUL: true))
        archive.append(header(name: "data/current", typeflag: symlinkType, size: 0))
        archive.append(endOfArchive())

        var walker = makeWalker()
        try walker.feed(archive)

        XCTAssertEqual(walker.children.first?.linkTarget, longTarget)
    }

    func testPaxGlobalHeaderDoesNotLeakIntoTheNextEntrysOverrides() throws {
        // A `g` (PAX global) header applies to the whole archive, not to the single
        // entry that happens to follow it. This walker used to collect `g` the same
        // way as a per-entry `x` header and apply its records to the very next entry —
        // so a global `path` override would have silently renamed one file. The
        // archive below has no legitimate `x` header at all, so if this passes, the
        // global's `path` record was correctly dropped rather than applied.
        var archive = Data()
        archive.append(paxGlobalHeader(records: [("path", "data/should-not-apply")]))
        archive.append(header(name: "data/real-name.txt", typeflag: fileType, size: 0))
        archive.append(endOfArchive())

        var walker = makeWalker()
        try walker.feed(archive)

        XCTAssertEqual(walker.children.map(\.name), ["real-name.txt"])
    }

    // MARK: - Fixture construction

    private let fileType = UInt8(ascii: "0")
    private let directoryType = UInt8(ascii: "5")
    private let symlinkType = UInt8(ascii: "2")

    private func makeWalker(
        rootName: String = "data", maxEntries: Int = 1_000, maxScanned: Int = 200_000,
        maxAuxDataBytes: Int = 64 * 1_024
    ) -> TarChildWalker {
        TarChildWalker(
            rootName: rootName, maxEntries: maxEntries, maxScanned: maxScanned,
            maxAuxDataBytes: maxAuxDataBytes)
    }

    private func entry(name: String, contents: String, typeflag: UInt8? = nil) -> Data {
        let body = Data(contents.utf8)
        var data = header(name: name, typeflag: typeflag ?? UInt8(ascii: "0"), size: body.count)
        data.append(body)
        data.append(Data(repeating: 0, count: paddingLength(for: body.count)))
        return data
    }

    private func header(
        name: String, typeflag: UInt8, size: Int, prefix: String = ""
    ) -> Data {
        var block = Data(repeating: 0, count: 512)
        block.replaceSubrange(0..<min(100, name.utf8.count), with: Data(name.utf8.prefix(100)))
        block.replaceSubrange(100..<108, with: Data("0000644\0".utf8))
        block.replaceSubrange(108..<116, with: Data("0000000\0".utf8))
        block.replaceSubrange(116..<124, with: Data("0000000\0".utf8))
        let sizeOctal = String(size, radix: 8).leftPadded(to: 11) + "\0"
        block.replaceSubrange(124..<136, with: Data(sizeOctal.utf8))
        block.replaceSubrange(136..<148, with: Data("00000000000\0".utf8))
        block[156] = typeflag
        block.replaceSubrange(257..<263, with: Data("ustar\0".utf8))
        block.replaceSubrange(263..<265, with: Data("00".utf8))
        if !prefix.isEmpty {
            block.replaceSubrange(345..<(345 + min(155, prefix.utf8.count)), with: Data(prefix.utf8.prefix(155)))
        }
        recomputeChecksum(&block)
        return block
    }

    /// A GNU `L` (long name) header, followed by its padded content block.
    private func gnuLongNameHeader(longName: String, includeTrailingNUL: Bool) -> Data {
        var nameBytes = Data(longName.utf8)
        if includeTrailingNUL { nameBytes.append(0) }
        var data = header(name: "", typeflag: UInt8(ascii: "L"), size: nameBytes.count)
        data.append(nameBytes)
        data.append(Data(repeating: 0, count: paddingLength(for: nameBytes.count)))
        return data
    }

    /// A GNU `K` (long link) header, followed by its padded content block — the
    /// long-target counterpart to `gnuLongNameHeader`.
    private func gnuLongLinkHeader(longLink: String, includeTrailingNUL: Bool) -> Data {
        var linkBytes = Data(longLink.utf8)
        if includeTrailingNUL { linkBytes.append(0) }
        var data = header(name: "", typeflag: UInt8(ascii: "K"), size: linkBytes.count)
        data.append(linkBytes)
        data.append(Data(repeating: 0, count: paddingLength(for: linkBytes.count)))
        return data
    }

    /// A PAX (`x`) extended header carrying the given records, followed by its padded
    /// content block. Record framing matches the spec: `"<len> key=value\n"`, where
    /// `len` counts the whole record including itself.
    private func paxHeader(records: [(String, String)]) -> Data {
        var body = ""
        for (key, value) in records {
            body += paxRecord(key: key, value: value)
        }
        let bodyData = Data(body.utf8)
        var data = header(name: "", typeflag: UInt8(ascii: "x"), size: bodyData.count)
        data.append(bodyData)
        data.append(Data(repeating: 0, count: paddingLength(for: bodyData.count)))
        return data
    }

    /// A PAX (`g`) *global* header — same record framing as `paxHeader`, but a
    /// distinct typeflag: it applies to the whole archive, never to the one entry
    /// that happens to follow it.
    private func paxGlobalHeader(records: [(String, String)]) -> Data {
        var body = ""
        for (key, value) in records {
            body += paxRecord(key: key, value: value)
        }
        let bodyData = Data(body.utf8)
        var data = header(name: "", typeflag: UInt8(ascii: "g"), size: bodyData.count)
        data.append(bodyData)
        data.append(Data(repeating: 0, count: paddingLength(for: bodyData.count)))
        return data
    }

    private func paxRecord(key: String, value: String) -> String {
        let suffix = " \(key)=\(value)\n"
        var length = suffix.utf8.count + 1
        while true {
            let candidate = "\(length)\(suffix)"
            if candidate.utf8.count == length { return candidate }
            length = candidate.utf8.count
        }
    }

    private func endOfArchive() -> Data {
        Data(repeating: 0, count: 1_024)
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
    /// the same convention the tar format and `TarChildWalker.checksumMatches` use.
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
