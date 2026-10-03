// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import Foundation
import XCTest

@testable import MorbstackAppCore

/// Pure coverage for the container Files tab. Nothing here needs a daemon: the engine's
/// side of the contract is pinned by bytes captured from a real one (Docker 29.7.1,
/// API 1.55, alpine:3.20), and everything else is the app's own arithmetic about paths,
/// sizes, completeness and what is safe to believe.
final class ContainerFileBrowserTests: XCTestCase {

    // MARK: - The stat header, as the engine really sends it

    /// `HEAD /containers/{id}/archive?path=/etc` on a live engine. Directory, 0755.
    private let liveDirectoryStat =
        "eyJuYW1lIjoiZXRjIiwic2l6ZSI6NDA5NiwibW9kZSI6MjE0NzQ4NDE0MSwibXRpbWUiOiIyMDI2LTA4LTA1VDAxOjA5OjUyLjAzNjAwMDA1N1oiLCJsaW5rVGFyZ2V0IjoiIn0="
    /// The same request for `/etc/hostname`. Regular file, 13 bytes, 0644.
    private let liveFileStat =
        "eyJuYW1lIjoiaG9zdG5hbWUiLCJzaXplIjoxMywibW9kZSI6NDIwLCJtdGltZSI6IjIwMjYtMDgtMDVUMDE6MDk6NDUuNzU2MDAwMDU0WiIsImxpbmtUYXJnZXQiOiIifQ=="
    /// The same request for `/bin/ash`, a symlink to busybox.
    private let liveSymlinkStat =
        "eyJuYW1lIjoiYXNoIiwic2l6ZSI6MTIsIm1vZGUiOjEzNDIxODIzOSwibXRpbWUiOiIyMDI2LTA0LTE1VDE2OjE0OjAzWiIsImxpbmtUYXJnZXQiOiIvYmluL2J1c3lib3gifQ=="

    func testStatHeaderDecodesTheKindOutOfGoModeBits() throws {
        let directory = try XCTUnwrap(ContainerPathStat.decode(headerValue: liveDirectoryStat))
        XCTAssertEqual(directory.name, "etc")
        XCTAssertEqual(directory.kind, .directory)
        XCTAssertEqual(directory.permissions, 0o755)
        // 4096 is the directory inode's size. It is carried, but the kind says it is
        // not a content length, which is what keeps it out of the size column.
        XCTAssertEqual(directory.size, 4096)
        XCTAssertFalse(directory.kind.sizeIsContentLength)
        XCTAssertNil(directory.linkTarget)
        XCTAssertNotNil(directory.modified)

        let file = try XCTUnwrap(ContainerPathStat.decode(headerValue: liveFileStat))
        XCTAssertEqual(file.kind, .regularFile)
        XCTAssertEqual(file.size, 13)
        XCTAssertEqual(file.permissions, 0o644)
        XCTAssertTrue(file.kind.sizeIsContentLength)

        let link = try XCTUnwrap(ContainerPathStat.decode(headerValue: liveSymlinkStat))
        XCTAssertEqual(link.kind, .symbolicLink)
        XCTAssertEqual(link.linkTarget, "/bin/busybox")
        // A symlink's "size" is the length of its target string, never content.
        XCTAssertEqual(link.size, 12)
        XCTAssertFalse(link.kind.sizeIsContentLength)
    }

    func testStatHeaderRefusesAnythingItCannotActuallyRead() {
        XCTAssertNil(ContainerPathStat.decode(headerValue: ""))
        XCTAssertNil(ContainerPathStat.decode(headerValue: "   "))
        XCTAssertNil(ContainerPathStat.decode(headerValue: "not base64 at all !!"))
        // Valid base64 of something that is not the documented document.
        XCTAssertNil(ContainerPathStat.decode(headerValue: Data("hello".utf8).base64EncodedString()))
        // A header longer than the cap never reaches the decoder.
        let oversized = String(repeating: "A", count: ContainerPathStat.maximumHeaderBytes + 4)
        XCTAssertNil(ContainerPathStat.decode(headerValue: oversized))
    }

    func testStatHeaderToleratesMissingBase64Padding() throws {
        let padded = try XCTUnwrap(ContainerPathStat.decode(headerValue: liveFileStat))
        let unpadded = try XCTUnwrap(
            ContainerPathStat.decode(
                headerValue: liveFileStat.replacingOccurrences(of: "=", with: "")))
        XCTAssertEqual(padded, unpadded)
    }

    func testGoFileModeMapsEveryKindMorbstackNames() {
        XCTAssertEqual(GoFileMode.kind(of: GoFileMode.directory | 0o755), .directory)
        XCTAssertEqual(GoFileMode.kind(of: GoFileMode.symbolicLink | 0o777), .symbolicLink)
        XCTAssertEqual(
            GoFileMode.kind(of: GoFileMode.device | GoFileMode.characterDevice | 0o666),
            .characterDevice)
        XCTAssertEqual(GoFileMode.kind(of: GoFileMode.device | 0o660), .blockDevice)
        XCTAssertEqual(GoFileMode.kind(of: GoFileMode.namedPipe | 0o644), .fifo)
        XCTAssertEqual(GoFileMode.kind(of: GoFileMode.socket | 0o755), .socket)
        XCTAssertEqual(GoFileMode.kind(of: GoFileMode.irregular), .unknown)
        XCTAssertEqual(GoFileMode.kind(of: 0o644), .regularFile)
    }

    // MARK: - Real header blocks off the wire

    /// The single 512-byte header block from `GET …/archive?path=/etc/hostname`.
    private let liveFileHeaderBlock =
        "aG9zdG5hbWUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAwMDA2NDQAMDAwMDAwMAAwMDAwMDAwADAwMDAwMDAwMDE1ADE1MjM0NTA2NTMxADAxMTAwNQAgMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB1c3RhcgAwMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAwMDAwMDAwADAwMDAwMDAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    /// The header block from `GET …/archive?path=/bin/ash`, a symlink entry.
    private let liveSymlinkHeaderBlock =
        "YXNoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAwMDA3NzcAMDAwMDAwMAAwMDAwMDAwADAwMDAwMDAwMDAwADE1MTY3NzM0NTEzADAxMjIyMAAgMi9iaW4vYnVzeWJveAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB1c3RhcgAwMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAwMDAwMDAwADAwMDAwMDAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    func testTheParserAgreesWithRealHeaderBlocksFromTheEngine() throws {
        let fileBlock = [UInt8](try XCTUnwrap(Data(base64Encoded: liveFileHeaderBlock)))
        XCTAssertTrue(ContainerTarHeaderReader.checksumMatches(fileBlock))
        let file = try ContainerTarHeaderReader.parseHeader(fileBlock)
        XCTAssertEqual(file.name, "hostname")
        XCTAssertEqual(file.size, 13)
        XCTAssertEqual(file.permissions, 0o644)
        XCTAssertEqual(ContainerTarHeaderReader.kind(forTypeflag: file.typeflag), .regularFile)

        let linkBlock = [UInt8](try XCTUnwrap(Data(base64Encoded: liveSymlinkHeaderBlock)))
        let link = try ContainerTarHeaderReader.parseHeader(linkBlock)
        XCTAssertEqual(link.name, "ash")
        XCTAssertEqual(link.linkName, "/bin/busybox")
        XCTAssertEqual(ContainerTarHeaderReader.kind(forTypeflag: link.typeflag), .symbolicLink)
        // A symlink's header size field is zero; the target lives in `linkname`.
        XCTAssertEqual(link.size, 0)
    }

    // MARK: - Tar reading

    func testReaderWalksHeadersAndSkipsContentAcrossChunkBoundaries() throws {
        var archive = Data()
        archive += TarFixture.entry(name: "etc/", typeflag: "5", mode: 0o755)
        archive += TarFixture.entry(name: "etc/hosts", contents: Data(repeating: 0x41, count: 1_100))
        archive += TarFixture.entry(name: "etc/apk/", typeflag: "5", mode: 0o755)
        archive += TarFixture.entry(name: "etc/apk/arch", contents: Data("aarch64\n".utf8))
        archive += TarFixture.endOfArchive()

        // 37 is deliberately coprime with 512 so every boundary lands mid-structure.
        var reader = ContainerTarHeaderReader()
        var entries: [ContainerTarEntry] = []
        var sawEnd = false
        for chunk in TarFixture.chunks(archive, size: 37) {
            for event in try reader.feed(chunk) {
                switch event {
                case .entry(let entry): entries.append(entry)
                case .endOfArchive: sawEnd = true
                case .payload: XCTFail("payload was emitted without being asked for")
                }
            }
        }

        XCTAssertTrue(sawEnd)
        XCTAssertTrue(reader.isComplete)
        XCTAssertEqual(entries.map(\.name), ["etc/", "etc/hosts", "etc/apk/", "etc/apk/arch"])
        XCTAssertEqual(entries.map(\.kind), [.directory, .regularFile, .directory, .regularFile])
        XCTAssertEqual(entries[1].size, 1_100)
        XCTAssertEqual(entries[3].size, 8)
    }

    func testReaderJoinsTheUstarPrefixFieldOntoTheName() throws {
        let deep = String(repeating: "segment/", count: 12) + "leaf.json"
        var archive = TarFixture.entry(name: deep, contents: Data("{}".utf8))
        archive += TarFixture.endOfArchive()

        var reader = ContainerTarHeaderReader()
        let events = try reader.feed(archive)
        guard case .entry(let entry)? = events.first else { return XCTFail("no entry") }
        // Ignoring `prefix` would silently produce a shorter, wrong path — a listing
        // that looks right and puts files in the wrong folder.
        XCTAssertEqual(entry.name, deep)
        XCTAssertGreaterThan(deep.count, 100)
    }

    func testReaderAppliesPaxPathSizeAndTimeToTheFollowingEntry() throws {
        let longPath = "app/" + String(repeating: "x", count: 180) + "/config.yaml"
        let records =
            TarFixture.paxRecord("path", longPath)
            + TarFixture.paxRecord("mtime", "1750000000.5")
        var archive = TarFixture.entry(
            name: "PaxHeaders/config.yaml", typeflag: "x", contents: Data(records.utf8))
        archive += TarFixture.entry(name: "app/config.yaml", contents: Data("a: 1\n".utf8))
        archive += TarFixture.endOfArchive()

        var reader = ContainerTarHeaderReader()
        var entries: [ContainerTarEntry] = []
        for chunk in TarFixture.chunks(archive, size: 101) {
            for event in try reader.feed(chunk) {
                if case .entry(let entry) = event { entries.append(entry) }
            }
        }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.name, longPath)
        XCTAssertEqual(entries.first?.modified, Date(timeIntervalSince1970: 1_750_000_000.5))
    }

    func testReaderAppliesGnuLongNameRecords() throws {
        let longPath = "src/" + String(repeating: "deep/", count: 40) + "index.ts"
        var archive = TarFixture.entry(
            name: "././@LongLink", typeflag: "L", contents: Data((longPath + "\0").utf8))
        archive += TarFixture.entry(name: "src/index.ts", contents: Data("export {}\n".utf8))
        archive += TarFixture.endOfArchive()

        var reader = ContainerTarHeaderReader()
        var names: [String] = []
        for event in try reader.feed(archive) {
            if case .entry(let entry) = event { names.append(entry.name) }
        }
        XCTAssertEqual(names, [longPath])
    }

    func testReaderDecodesBase256SizesTooLargeForOctal() throws {
        // 12 GB does not fit in eleven octal digits, so tar writes base 256.
        let huge: Int64 = 12 * 1024 * 1024 * 1024
        let block = TarFixture.headerBlock(
            name: "var/lib/big.db", typeflag: "0", mode: 0o644, size: huge, base256Size: true)
        let parsed = try ContainerTarHeaderReader.parseHeader(block)
        XCTAssertEqual(parsed.size, huge)
    }

    func testReaderRefusesABase256SizeOverflowRatherThanWrapping() throws {
        // The same malformed field, byte for byte, that `TarChildWalkerTests` and
        // `TarLiteTests` also refuse (see TECH-4) — worth proving here too, now that
        // all three readers share one decoder, `TarFormat.numericField`, instead of
        // each carrying (or, in one real case, not carrying) its own overflow guard.
        let block = TarFixture.headerBlock(
            name: "huge.bin", typeflag: "0", mode: 0o644, size: -1, base256Size: true)
        var reader = ContainerTarHeaderReader()
        XCTAssertThrowsError(try reader.feed(Data(block))) { error in
            guard case ContainerTarHeaderReader.Failure.malformedArchive(let reason) = error else {
                return XCTFail("expected a malformed-archive failure, got \(error)")
            }
            XCTAssertTrue(reason.contains("length"))
        }
    }

    func testReaderStopsRatherThanInventEntriesWhenTheStreamDesyncs() {
        var archive = TarFixture.entry(name: "etc/", typeflag: "5", mode: 0o755)
        // Corrupt a byte inside the name so the checksum no longer matches.
        archive[4] = 0x5A
        var reader = ContainerTarHeaderReader()
        XCTAssertThrowsError(try reader.feed(archive)) { error in
            guard case ContainerTarHeaderReader.Failure.malformedArchive(let reason) = error else {
                return XCTFail("expected a malformed-archive failure, got \(error)")
            }
            XCTAssertTrue(reason.contains("tar format"))
        }
    }

    func testReaderRefusesAnAbsurdExtendedHeaderLengthBeforeAllocating() {
        let block = TarFixture.headerBlock(
            name: "PaxHeaders/x", typeflag: "x", mode: 0o644,
            size: Int64(ContainerTarHeaderReader.maximumExtendedRecordBytes) + 1)
        var reader = ContainerTarHeaderReader()
        XCTAssertThrowsError(try reader.feed(Data(block)))
    }

    func testReaderCapturesPayloadOnlyWhenAsked() throws {
        var archive = TarFixture.entry(name: "hostname", contents: Data("morbstack\n".utf8))
        archive += TarFixture.endOfArchive()

        var reader = ContainerTarHeaderReader(capturesPayload: true)
        var payload = Data()
        for chunk in TarFixture.chunks(archive, size: 7) {
            for event in try reader.feed(chunk) {
                if case .payload(let bytes) = event { payload += bytes }
            }
        }
        XCTAssertEqual(String(decoding: payload, as: UTF8.self), "morbstack\n")
    }

    func testReaderNeverTreatsALinkEntrysSizeFieldAsPayload() throws {
        // A hostile or unusual writer can put a size on a symlink entry. Following it
        // would consume the next header as though it were file content, and every
        // entry after that would be fiction.
        var archive = TarFixture.headerBlockData(
            name: "bin/sh", typeflag: "2", mode: 0o777, size: 512, linkName: "/bin/busybox")
        archive += TarFixture.entry(name: "bin/busybox", contents: Data("ELF".utf8))
        archive += TarFixture.endOfArchive()

        var reader = ContainerTarHeaderReader()
        var names: [String] = []
        for event in try reader.feed(archive) {
            if case .entry(let entry) = event { names.append(entry.name) }
        }
        XCTAssertEqual(names, ["bin/sh", "bin/busybox"])
    }

    // MARK: - Rebasing entry names, which are untrusted

    func testEntryNamesRebaseTheWayTheEngineActuallyNamesThem() {
        // Confirmed live: `/etc` yields `etc/…`, `/` yields `/…`, a single file yields
        // its bare base name.
        XCTAssertEqual(
            try? ContainerFilePath.absolutePath(forEntryName: "etc/", requestedPath: "/etc").get(),
            "/etc")
        XCTAssertEqual(
            try? ContainerFilePath.absolutePath(forEntryName: "etc/hosts", requestedPath: "/etc").get(),
            "/etc/hosts")
        XCTAssertEqual(
            try? ContainerFilePath.absolutePath(forEntryName: "/", requestedPath: "/").get(),
            "/")
        XCTAssertEqual(
            try? ContainerFilePath.absolutePath(forEntryName: "/bin/busybox", requestedPath: "/").get(),
            "/bin/busybox")
        XCTAssertEqual(
            try? ContainerFilePath.absolutePath(forEntryName: "hostname", requestedPath: "/etc/hostname")
                .get(),
            "/etc/hostname")
        XCTAssertEqual(
            try? ContainerFilePath.absolutePath(forEntryName: "apk/keys/a.pub", requestedPath: "/etc/apk")
                .get(),
            "/etc/apk/keys/a.pub")
    }

    func testATraversingEntryNameIsRefusedAndNeverRepaired() {
        let cases: [(String, String, ContainerFilePath.Rejection)] = [
            ("etc/../../root/.ssh/id_rsa", "/etc", .relativeComponent),
            ("etc/./hosts", "/etc", .relativeComponent),
            ("/../etc/shadow", "/", .relativeComponent),
            ("etc//hosts", "/etc", .emptyComponent),
            // A sibling whose name merely starts with the requested base.
            ("etcd/config", "/etc", .outsideRequestedPath),
            ("elsewhere/file", "/etc", .outsideRequestedPath),
            // The root archive prefixes with `/`; anything else is not from this read.
            ("bin/sh", "/", .outsideRequestedPath),
            ("etc/\u{0}passwd", "/etc", .containsNUL),
            ("etc/" + String(repeating: "n", count: 256), "/etc", .componentTooLong),
        ]
        for (name, requested, expected) in cases {
            let result = ContainerFilePath.absolutePath(forEntryName: name, requestedPath: requested)
            guard case .failure(let rejection) = result else {
                return XCTFail("\(name) under \(requested) was accepted as \((try? result.get()) ?? "?")")
            }
            XCTAssertEqual(rejection, expected, "for \(name)")
        }
    }

    func testAnOverlongRebasedPathIsRefusedRatherThanTruncated() {
        let deep = "etc/" + Array(repeating: "abcdefgh", count: 600).joined(separator: "/")
        let result = ContainerFilePath.absolutePath(forEntryName: deep, requestedPath: "/etc")
        guard case .failure(let rejection) = result else { return XCTFail("accepted") }
        XCTAssertEqual(rejection, .pathTooLong)
    }

    func testTypedPathsAreNormalisedOrRefused() {
        XCTAssertEqual(ContainerFilePath.normalizeTyped("/"), "/")
        XCTAssertEqual(ContainerFilePath.normalizeTyped("  /var//log/ "), "/var/log")
        XCTAssertEqual(ContainerFilePath.normalizeTyped("/var/log/"), "/var/log")
        XCTAssertEqual(ContainerFilePath.normalizeTyped("/./usr/./bin"), "/usr/bin")
        // Relative and parent-walking input is refused: this app never resolves a `..`
        // the engine would resolve against a different tree.
        XCTAssertNil(ContainerFilePath.normalizeTyped("var/log"))
        XCTAssertNil(ContainerFilePath.normalizeTyped("/var/../etc"))
        XCTAssertNil(ContainerFilePath.normalizeTyped(""))
        XCTAssertNil(ContainerFilePath.normalizeTyped("/a\u{0}b"))
        XCTAssertNil(
            ContainerFilePath.normalizeTyped("/" + String(repeating: "x", count: 5000)))
    }

    func testPathArithmetic() {
        XCTAssertNil(ContainerFilePath.parent(of: "/"))
        XCTAssertEqual(ContainerFilePath.parent(of: "/etc"), "/")
        XCTAssertEqual(ContainerFilePath.parent(of: "/etc/apk/arch"), "/etc/apk")
        XCTAssertEqual(ContainerFilePath.displayName(of: "/"), "/")
        XCTAssertEqual(ContainerFilePath.displayName(of: "/etc/apk"), "apk")
        XCTAssertEqual(ContainerFilePath.ancestry(of: "/var/log"), ["/", "/var", "/var/log"])
        XCTAssertEqual(ContainerFilePath.join("/", "bin/sh"), "/bin/sh")
        XCTAssertEqual(ContainerFilePath.join("/etc", "apk/arch"), "/etc/apk/arch")
    }

    func testSymlinkTargetsResolveTheWayTheGuestWould() {
        XCTAssertEqual(
            ContainerFilePath.resolveLinkTarget("/bin/busybox", from: "/bin/ash"), "/bin/busybox")
        XCTAssertEqual(
            ContainerFilePath.resolveLinkTarget("busybox", from: "/bin/ash"), "/bin/busybox")
        XCTAssertEqual(
            ContainerFilePath.resolveLinkTarget("../lib/libc.so", from: "/bin/ash"), "/lib/libc.so")
        // `..` above the root clamps at the root, exactly as the kernel does.
        XCTAssertEqual(
            ContainerFilePath.resolveLinkTarget("../../../etc/hosts", from: "/bin/ash"), "/etc/hosts")
        XCTAssertNil(ContainerFilePath.resolveLinkTarget("", from: "/bin/ash"))
    }

    // MARK: - Entries and ordering

    func testAnEntryOnlyCarriesASizeWhereSizeMeansContentBytes() {
        let directory = ContainerFileEntry(
            path: "/etc",
            entry: ContainerTarEntry(
                name: "etc/", kind: .directory, size: 4096, permissions: 0o755,
                modified: nil, linkTarget: nil))
        // Not zero, and not an em dash standing in for a fact: absent.
        XCTAssertNil(directory.size)

        let link = ContainerFileEntry(
            path: "/bin/ash",
            entry: ContainerTarEntry(
                name: "bin/ash", kind: .symbolicLink, size: 12, permissions: 0o777,
                modified: nil, linkTarget: "/bin/busybox"))
        XCTAssertNil(link.size)
        XCTAssertEqual(link.linkTarget, "/bin/busybox")

        let file = ContainerFileEntry(
            path: "/etc/hostname",
            entry: ContainerTarEntry(
                name: "etc/hostname", kind: .regularFile, size: 13, permissions: 0o644,
                modified: nil, linkTarget: nil))
        XCTAssertEqual(file.size, 13)
        XCTAssertEqual(file.name, "hostname")
    }

    func testOrderingPutsFoldersFirstAndReadsNumbersLikeAPerson() {
        var entries: [ContainerFileEntry] = []
        for entry in [
            ContainerFileEntry(path: "/a/file10.log", kind: .regularFile, size: 1),
            ContainerFileEntry(path: "/a/File2.log", kind: .regularFile, size: 1),
            ContainerFileEntry(path: "/a/zeta", kind: .directory),
            ContainerFileEntry(path: "/a/file9.log", kind: .regularFile, size: 1),
            ContainerFileEntry(path: "/a/alpha", kind: .directory),
        ] {
            ContainerFileEntry.insertSorted(entry, into: &entries)
        }
        XCTAssertEqual(entries.map(\.name), ["alpha", "zeta", "File2.log", "file9.log", "file10.log"])
    }

    // MARK: - Which directories a budgeted scan actually finished

    private func tarEntry(
        _ name: String, _ kind: ContainerFileKind = .regularFile, size: Int64 = 0
    ) -> ContainerTarEntry {
        ContainerTarEntry(
            name: name, kind: kind, size: size, permissions: 0o644, modified: nil, linkTarget: nil)
    }

    func testACompleteStreamMakesEveryDirectoryItSawComplete() {
        var scan = ContainerDirectoryScan(requestedPath: "/etc", entryBudget: 100)
        _ = scan.admit(tarEntry("etc/", .directory))
        _ = scan.admit(tarEntry("etc/apk/", .directory))
        _ = scan.admit(tarEntry("etc/apk/arch", size: 8))
        _ = scan.admit(tarEntry("etc/hosts", size: 30))

        XCTAssertEqual(scan.entryCount, 3)
        XCTAssertTrue(scan.orderingWasSequential)
        let completed = scan.completedDirectories(streamCompleted: true)
        XCTAssertEqual(completed, ["/etc", "/etc/apk"])
    }

    func testAnInterruptedScanOnlyClaimsTheDirectoriesItProvablyLeft() {
        var scan = ContainerDirectoryScan(requestedPath: "/", entryBudget: 100)
        _ = scan.admit(tarEntry("/", .directory))
        _ = scan.admit(tarEntry("/bin/", .directory))
        _ = scan.admit(tarEntry("/bin/sh", size: 100))
        _ = scan.admit(tarEntry("/etc/", .directory))
        _ = scan.admit(tarEntry("/etc/hosts", size: 30))
        // The stream stops here, inside /etc.

        let completed = scan.completedDirectories(streamCompleted: false)
        // `/bin` was left behind, so it is finished. `/etc` and `/` are still open and
        // must not be presented as complete listings.
        XCTAssertEqual(completed, ["/bin"])
        XCTAssertFalse(completed.contains("/etc"))
        XCTAssertFalse(completed.contains("/"))
    }

    func testOneOutOfOrderEntryWithdrawsEveryCompletenessClaim() {
        var scan = ContainerDirectoryScan(requestedPath: "/", entryBudget: 100)
        _ = scan.admit(tarEntry("/", .directory))
        _ = scan.admit(tarEntry("/bin/", .directory))
        _ = scan.admit(tarEntry("/bin/sh", size: 1))
        _ = scan.admit(tarEntry("/etc/", .directory))
        // A second entry for a directory the walk already left: the ordering the
        // closure bookkeeping depends on is not holding.
        _ = scan.admit(tarEntry("/bin/dash", size: 1))

        XCTAssertFalse(scan.orderingWasSequential)
        XCTAssertTrue(scan.completedDirectories(streamCompleted: false).isEmpty)
        // A stream that genuinely reached the end is still trustworthy: nothing can be
        // missing from an archive that ended.
        XCTAssertTrue(scan.completedDirectories(streamCompleted: true).contains("/bin"))
    }

    func testAChildWithNoDirectoryEntryOfItsOwnAlsoWithdrawsTheClaim() {
        var scan = ContainerDirectoryScan(requestedPath: "/etc", entryBudget: 100)
        _ = scan.admit(tarEntry("etc/", .directory))
        _ = scan.admit(tarEntry("etc/apk/arch", size: 8))
        XCTAssertFalse(scan.orderingWasSequential)
        XCTAssertTrue(scan.completedDirectories(streamCompleted: false).isEmpty)
    }

    func testTheEntryBudgetStopsTheScanAndIsReported() {
        var scan = ContainerDirectoryScan(requestedPath: "/etc", entryBudget: 2)
        XCTAssertEqual(scan.admit(tarEntry("etc/", .directory)), .requestedPath(
            ContainerFileEntry(path: "/etc", kind: .directory, permissions: 0o644)))
        if case .entry = scan.admit(tarEntry("etc/a", size: 1)) {} else { XCTFail("expected an entry") }
        if case .entry = scan.admit(tarEntry("etc/b", size: 1)) {} else { XCTFail("expected an entry") }
        XCTAssertEqual(scan.admit(tarEntry("etc/c", size: 1)), .budgetExhausted)
        XCTAssertEqual(scan.entryCount, 2)
    }

    func testRejectedEntriesAreCountedRatherThanQuietlyDropped() {
        var scan = ContainerDirectoryScan(requestedPath: "/etc", entryBudget: 100)
        _ = scan.admit(tarEntry("etc/", .directory))
        _ = scan.admit(tarEntry("etc/../../root/.bashrc", size: 1))
        _ = scan.admit(tarEntry("somewhere-else/file", size: 1))
        XCTAssertEqual(scan.rejectedEntryCount, 2)
        XCTAssertEqual(scan.entryCount, 0)
    }

    func testAFileAskedAboutAsAFolderIsNeverReportedAsAnEmptyFolder() {
        // `GET …/archive?path=/etc/hostname` is a valid request that answers with one
        // file entry. Treating that as "a folder with nothing in it" would be a lie
        // about somebody's file.
        var scan = ContainerDirectoryScan(requestedPath: "/etc/hostname", entryBudget: 100)
        _ = scan.admit(tarEntry("hostname", .regularFile, size: 13))
        XCTAssertEqual(scan.requestedPathKind, .regularFile)
        XCTAssertTrue(scan.completedDirectories(streamCompleted: true).isEmpty)

        var directory = ContainerDirectoryScan(requestedPath: "/", entryBudget: 100)
        _ = directory.admit(tarEntry("/", .directory))
        XCTAssertEqual(directory.requestedPathKind, .directory)
        XCTAssertEqual(directory.completedDirectories(streamCompleted: true), ["/"])
    }

    func testStrictAncestryRespectsThePathBoundary() {
        XCTAssertTrue(ContainerDirectoryScan.isStrictAncestor("/var", of: "/var/log"))
        XCTAssertFalse(ContainerDirectoryScan.isStrictAncestor("/var", of: "/variable"))
        XCTAssertFalse(ContainerDirectoryScan.isStrictAncestor("/var", of: "/var"))
        XCTAssertTrue(ContainerDirectoryScan.isStrictAncestor("/", of: "/var"))
        XCTAssertFalse(ContainerDirectoryScan.isStrictAncestor("/", of: "/"))
    }

    // MARK: - What a partial listing says

    func testEveryIncompleteListingNamesSomethingTheReaderCanDo() {
        let stops: [ContainerFileScanStop] = [
            .byteBudget(512 << 20),
            .entryBudget(200_000),
            .stoppedByPerson(bytesRead: 12_345),
            .interrupted("the connection closed"),
        ]
        for stop in stops {
            let sentence = stop.sentence(entriesListed: 42)
            XCTAssertFalse(sentence.isEmpty)
            // No error codes, and never a bare statement of failure.
            XCTAssertFalse(sentence.contains("error"))
        }
        XCTAssertTrue(
            ContainerFileScanStop.byteBudget(512 << 20)
                .sentence(entriesListed: 3).contains("Open a folder below"))

        // The stop reason carries the bytes it actually read, so the sentence cannot
        // report a confident zero after the progress readout has gone away.
        let stopped = ContainerFileScanStop.stoppedByPerson(bytesRead: 1_500_000)
            .sentence(entriesListed: 3)
        XCTAssertTrue(stopped.contains("Reload"))
        XCTAssertTrue(stopped.contains(Formatters.bytesString(1_500_000)))
    }

    func testEngineFailuresBecomeSentencesAboutThisContainer() {
        XCTAssertEqual(
            ContainerFileErrorText.sentence(
                DockerClientError.http(
                    status: 404, message: "Could not find the file /nope in container abc"),
                path: "/nope"),
            "There is nothing at /nope in this container now.")
        XCTAssertEqual(
            ContainerFileErrorText.sentence(
                DockerClientError.http(status: 404, message: "No such container: abc"),
                path: "/etc"),
            "This container no longer exists on the engine.")
        XCTAssertTrue(
            ContainerFileErrorText.sentence(
                DockerClientError.engineUnreachable("connection refused"), path: "/etc")
                .contains("could not reach the Docker engine"))
    }

    // MARK: - Text, binary, and too large

    func testTextIsShownAndNonTextIsNamedRatherThanGuessedAt() {
        XCTAssertEqual(ContainerFileText.interpret(Data(), truncated: false), .empty)

        XCTAssertEqual(
            ContainerFileText.interpret(Data("hello\n".utf8), truncated: false),
            .text("hello\n", truncated: false))

        let withNull = Data([0x7F, 0x45, 0x4C, 0x46, 0x00, 0x01])
        XCTAssertEqual(
            ContainerFileText.interpret(withNull, truncated: false),
            .notText(.containsNullBytes))

        // Invalid UTF-8 with no NUL byte: a real distinction, and one worth telling
        // apart in the sentence the reader gets.
        let invalid = Data([0xE4, 0xF6, 0xFC, 0x21])
        XCTAssertEqual(
            ContainerFileText.interpret(invalid, truncated: false),
            .notText(.notValidUTF8))
    }

    func testATruncatedReadDoesNotFailOnTheCharacterItCutInHalf() {
        // "日本語" cut after the first byte of the last character.
        let full = Data("日本語".utf8)
        let cut = full.prefix(full.count - 2)
        XCTAssertNil(String(data: cut, encoding: .utf8))
        XCTAssertEqual(
            ContainerFileText.interpret(Data(cut), truncated: true),
            .text("日本", truncated: true))
    }

    func testNonTextSentencesSayWhichFactStoppedThemAndWhatToDo() {
        let nulls = ContainerFileText.sentence(for: .containsNullBytes, size: 4096)
        XCTAssertTrue(nulls.contains("not text"))
        XCTAssertTrue(nulls.contains("4 KB"))
        XCTAssertTrue(nulls.contains("Save it to the host"))

        let invalid = ContainerFileText.sentence(for: .notValidUTF8, size: nil)
        XCTAssertTrue(invalid.contains("not valid UTF-8"))
        XCTAssertFalse(invalid.contains("bytes."))  // no invented size
    }

    // MARK: - Saving out

    func testTheSuggestedHostFileNameCannotBeSteeredFromInsideTheContainer() {
        XCTAssertEqual(
            ContainerFileTransfers.suggestedFileName(for: "/etc/hostname", isDirectory: false),
            "hostname")
        XCTAssertEqual(
            ContainerFileTransfers.suggestedFileName(for: "/etc", isDirectory: true),
            "etc.tar")
        // A container-side name is untrusted; separators and control characters cannot
        // survive into a host file name.
        XCTAssertEqual(
            ContainerFileTransfers.suggestedFileName(
                for: "/tmp/evil\u{0}:name\u{7}", isDirectory: false),
            "evil-:name-".replacingOccurrences(of: ":", with: "-"))
        XCTAssertEqual(
            ContainerFileTransfers.suggestedFileName(for: "/tmp/...", isDirectory: false),
            "container-file")
        XCTAssertEqual(
            ContainerFileTransfers.suggestedFileName(for: "/", isDirectory: true),
            "container-file.tar")
    }

    func testPermissionsRenderAsTheModeTheEngineReported() {
        XCTAssertEqual(ContainerFilesTab.permissionString(0o755), "rwxr-xr-x (755)")
        XCTAssertEqual(ContainerFilesTab.permissionString(0o644), "rw-r--r-- (644)")
        XCTAssertEqual(ContainerFilesTab.permissionString(0o000), "--------- (000)")
    }
}

// MARK: - Fixtures

/// A minimal tar writer, only as much as these tests need. Building archives here
/// rather than checking in binaries keeps every edge case — long names, PAX records,
/// base-256 sizes, a corrupted checksum — visible in the test that depends on it.
private enum TarFixture {

    static func chunks(_ data: Data, size: Int) -> [Data] {
        stride(from: 0, to: data.count, by: size).map { start in
            data.subdata(in: start..<min(start + size, data.count))
        }
    }

    static func paxRecord(_ key: String, _ value: String) -> String {
        let body = "\(key)=\(value)\n"
        var length = body.utf8.count + 1
        while "\(length) ".utf8.count + body.utf8.count != length {
            length = "\(length) ".utf8.count + body.utf8.count
        }
        return "\(length) \(body)"
    }

    static func entry(
        name: String,
        typeflag: Character = "0",
        mode: UInt16 = 0o644,
        contents: Data = Data(),
        linkName: String = ""
    ) -> Data {
        var data = headerBlockData(
            name: name, typeflag: typeflag, mode: mode, size: Int64(contents.count),
            linkName: linkName)
        guard !contents.isEmpty else { return data }
        data += contents
        let padding = (512 - contents.count % 512) % 512
        if padding > 0 { data += Data(repeating: 0, count: padding) }
        return data
    }

    static func headerBlockData(
        name: String,
        typeflag: Character,
        mode: UInt16,
        size: Int64,
        linkName: String = "",
        base256Size: Bool = false
    ) -> Data {
        Data(
            headerBlock(
                name: name, typeflag: typeflag, mode: mode, size: size, linkName: linkName,
                base256Size: base256Size))
    }

    static func headerBlock(
        name: String,
        typeflag: Character,
        mode: UInt16,
        size: Int64,
        linkName: String = "",
        base256Size: Bool = false
    ) -> [UInt8] {
        var block = [UInt8](repeating: 0, count: 512)

        // ustar splits a long name at a `/` into prefix + name, exactly as Go does.
        var shortName = name
        var prefix = ""
        if name.utf8.count > 100 {
            let bytes = Array(name.utf8)
            var split = min(155, bytes.count - 1)
            while split > 0 && bytes[split] != UInt8(ascii: "/") { split -= 1 }
            prefix = String(decoding: bytes[0..<split], as: UTF8.self)
            shortName = String(decoding: bytes[(split + 1)...], as: UTF8.self)
        }

        write(&block, String(shortName.prefix(100)), at: 0, length: 100)
        write(&block, octal(UInt64(mode), width: 7), at: 100, length: 8)
        write(&block, octal(0, width: 7), at: 108, length: 8)
        write(&block, octal(0, width: 7), at: 116, length: 8)
        if base256Size {
            block[124] = 0x80
            var value = UInt64(bitPattern: size)
            for offset in stride(from: 135, through: 125, by: -1) {
                block[offset] = UInt8(value & 0xFF)
                value >>= 8
            }
        } else {
            write(&block, octal(UInt64(size), width: 11), at: 124, length: 12)
        }
        write(&block, octal(0, width: 11), at: 136, length: 12)
        block[156] = typeflag.asciiValue ?? UInt8(ascii: "0")
        write(&block, linkName, at: 157, length: 100)
        write(&block, "ustar", at: 257, length: 6)
        write(&block, "00", at: 263, length: 2)
        write(&block, prefix, at: 345, length: 155)

        // The checksum field is spaces while the sum is taken.
        for offset in 148..<156 { block[offset] = UInt8(ascii: " ") }
        let sum = block.reduce(0) { $0 + Int($1) }
        write(&block, octal(UInt64(sum), width: 6), at: 148, length: 7)
        block[154] = 0
        block[155] = UInt8(ascii: " ")
        return block
    }

    static func endOfArchive() -> Data { Data(repeating: 0, count: 1024) }

    private static func octal(_ value: UInt64, width: Int) -> String {
        let digits = String(value, radix: 8)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    private static func write(_ block: inout [UInt8], _ text: String, at offset: Int, length: Int) {
        for (index, byte) in Array(text.utf8).prefix(length).enumerated() {
            block[offset + index] = byte
        }
    }
}
