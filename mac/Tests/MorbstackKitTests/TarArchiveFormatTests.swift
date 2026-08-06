// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// `TarFormat` is the mechanical core promoted out of three independent tar readers
// (`ContainerTarHeaderReader` in MorbstackAppCore, `TarChildWalker` in MorbFeatures,
// `TarLite` in MorbMigrate — see TECH-4 in TASKS.md). Each of those keeps its own tests
// for its own policy (budgets, root membership, payload capture); this file is where
// the byte-level format rules themselves are tested once, properly, instead of three
// times unevenly — including the two fixtures that used to be a real bug found only by
// a person reading two readers side by side: a base-256 size that overflows `Int64`,
// and a GNU long-name entry whose declared length includes its own trailing NUL.

import XCTest

@testable import MorbstackKit

final class TarArchiveFormatTests: XCTestCase {

    // MARK: - Checksum

    func testChecksumMatchesAcceptsTheUnsignedInterpretation() {
        let block = TarFixture.headerBlock(name: "hello.txt", typeflag: "0", size: 0)
        XCTAssertTrue(TarFormat.checksumMatches(block))
    }

    func testChecksumMatchesAcceptsTheHistoricalSignedInterpretationToo() {
        // A name field with high-bit-set bytes makes the unsigned and signed sums
        // disagree; a writer that used the (non-conforming, but real-world) signed
        // convention when it wrote the checksum still needs to be read correctly.
        var block = TarFixture.headerBlock(name: "café", typeflag: "0", size: 0)
        var signedSum = 0
        for (index, byte) in block.enumerated() {
            let value = (148..<156).contains(index) ? UInt8(ascii: " ") : byte
            signedSum += Int(Int8(bitPattern: value))
        }
        TarFixture.writeChecksum(&block, value: signedSum)
        XCTAssertTrue(TarFormat.checksumMatches(block))
    }

    func testChecksumMatchesRejectsACorruptedBlock() {
        var block = TarFixture.headerBlock(name: "hello.txt", typeflag: "0", size: 0)
        block[0] ^= 0xFF
        XCTAssertFalse(TarFormat.checksumMatches(block))
    }

    func testChecksumMatchesRejectsAnythingNotExactlyOneBlock() {
        XCTAssertFalse(TarFormat.checksumMatches([]))
        XCTAssertFalse(TarFormat.checksumMatches(Array(repeating: 0, count: 511)))
        XCTAssertFalse(TarFormat.checksumMatches(Array(repeating: 0, count: 513)))
    }

    // MARK: - Numeric fields: octal

    func testNumericFieldReadsOrdinaryOctalText() {
        XCTAssertEqual(TarFormat.numericField(Array("0000644\0".utf8)), 0o644)
        XCTAssertEqual(TarFormat.numericField(Array("00000000000\0".utf8)), 0)
    }

    func testNumericFieldTrimsSpaceAndNULPadding() {
        XCTAssertEqual(TarFormat.numericField(Array("  17\0\0\0".utf8)), 0o17)
    }

    func testNumericFieldReadsAnEmptyFieldAsZero() {
        XCTAssertEqual(TarFormat.numericField(Array(repeating: UInt8(0), count: 12)), 0)
        XCTAssertEqual(TarFormat.numericField([UInt8]()), nil)  // no `first` at all
    }

    func testNumericFieldRefusesNonOctalText() {
        XCTAssertNil(TarFormat.numericField(Array("99999\0".utf8)))  // 9 is not octal
        XCTAssertNil(TarFormat.numericField(Array("not-a-number".utf8)))
    }

    // MARK: - Numeric fields: base-256 (the first real bug)

    func testNumericFieldDecodesABase256SizeTooLargeForOctal() {
        // 12 GB does not fit in eleven octal digits, so a real writer switches to
        // GNU base-256 for it — the exact fixture that the original bug report used.
        let huge: Int64 = 12 * 1024 * 1024 * 1024
        var field = [UInt8](repeating: 0, count: 12)
        var remaining = UInt64(huge)
        for index in stride(from: 11, through: 1, by: -1) {
            field[index] = UInt8(remaining & 0xFF)
            remaining >>= 8
        }
        field[0] = 0x80
        XCTAssertEqual(TarFormat.numericField(field), huge)
    }

    func testNumericFieldRefusesABase256OverflowRatherThanWrapping() {
        // All-0xFF magnitude bytes guarantee the running value exceeds Int64.max
        // before the last byte is folded in — the exact shape of the bug that shipped
        // in one reader and not the other: a `<<` that wrapped around instead of being
        // refused.
        var field = [UInt8](repeating: 0xFF, count: 12)
        field[0] = 0x80 | 0xFF
        XCTAssertNil(TarFormat.numericField(field))
    }

    func testNumericFieldBase256TopBitOnlyMarksTheEncodingNotAMagnitudeByte() {
        // The high bit of byte 0 is the marker; its remaining 7 bits are real
        // magnitude, not a byte to discard. `0x80` alone (all other bytes zero) is 0,
        // not garbage.
        var field = [UInt8](repeating: 0, count: 12)
        field[0] = 0x80
        XCTAssertEqual(TarFormat.numericField(field), 0)
    }

    // MARK: - cString (the second real bug)

    func testCStringTruncatesAtTheFirstNUL() {
        XCTAssertEqual(TarFormat.cString(Array("hello\0world".utf8)), "hello")
    }

    func testCStringUsesTheWholeFieldWhenThereIsNoNUL() {
        XCTAssertEqual(TarFormat.cString(Array("hello".utf8)), "hello")
    }

    func testCStringOfAnEmptyOrAllNULFieldIsEmpty() {
        XCTAssertEqual(TarFormat.cString([UInt8]()), "")
        XCTAssertEqual(TarFormat.cString(Array(repeating: UInt8(0), count: 8)), "")
    }

    func testCStringOperatesOnRawBytesSoATrailingNULDeclaredInTheLengthNeverSurvives() {
        // This is the exact shape of the second bug: a GNU long-name writer declares
        // the field's size *including* the trailing NUL. A reader that decoded the
        // bytes into a `String` first and only *then* looked for a NUL would keep that
        // byte — a control character — and fail whatever check ran on the name next.
        // Operating on the bytes directly, as every caller now does, cannot reproduce
        // that: the NUL is gone before a `String` exists at all.
        let longName = "src/" + String(repeating: "deep/", count: 40) + "index.ts"
        var bytes = Array(longName.utf8)
        bytes.append(0)  // the writer's declared length includes this byte
        let decoded = TarFormat.cString(bytes)
        XCTAssertEqual(decoded, longName)
        XCTAssertFalse(decoded.unicodeScalars.contains { $0.value == 0 })
    }

    // MARK: - Typeflag → kind

    func testKindMapsEveryTypeflagIncludingTheHistoricalOnes() {
        XCTAssertEqual(TarFormat.kind(forTypeflag: UInt8(ascii: "0")), .regularFile)
        XCTAssertEqual(TarFormat.kind(forTypeflag: 0), .regularFile)  // pre-POSIX v7
        XCTAssertEqual(TarFormat.kind(forTypeflag: UInt8(ascii: "7")), .regularFile)  // contiguous file
        XCTAssertEqual(TarFormat.kind(forTypeflag: UInt8(ascii: "1")), .hardLink)
        XCTAssertEqual(TarFormat.kind(forTypeflag: UInt8(ascii: "2")), .symbolicLink)
        XCTAssertEqual(TarFormat.kind(forTypeflag: UInt8(ascii: "3")), .characterDevice)
        XCTAssertEqual(TarFormat.kind(forTypeflag: UInt8(ascii: "4")), .blockDevice)
        XCTAssertEqual(TarFormat.kind(forTypeflag: UInt8(ascii: "5")), .directory)
        XCTAssertEqual(TarFormat.kind(forTypeflag: UInt8(ascii: "6")), .fifo)
        XCTAssertEqual(TarFormat.kind(forTypeflag: UInt8(ascii: "x")), .unknown)
        XCTAssertEqual(TarFormat.kind(forTypeflag: UInt8(ascii: "L")), .unknown)
    }

    // MARK: - PAX records

    func testParsePaxRecordsReadsOneRecord() {
        let record = TarFixture.paxRecord("path", "app/config.yaml")
        let parsed = TarFormat.parsePaxRecords(Array(record.utf8))
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].key, "path")
        XCTAssertEqual(parsed[0].value, "app/config.yaml")
    }

    func testParsePaxRecordsReadsSeveralRecordsInSequence() {
        let body = TarFixture.paxRecord("path", "a/b.txt") + TarFixture.paxRecord("mtime", "1750000000.5")
        let parsed = TarFormat.parsePaxRecords(Array(body.utf8))
        XCTAssertEqual(parsed.map(\.key), ["path", "mtime"])
        XCTAssertEqual(parsed.map(\.value), ["a/b.txt", "1750000000.5"])
    }

    func testParsePaxRecordsToleratesAMissingTrailingNewline() {
        // The record ends in `\n` per spec; a writer that omitted it should not lose
        // the record. Same fixed-point length computation as `TarFixture.paxRecord`,
        // just without the trailing newline in the suffix.
        let suffix = " path=short"
        var length = suffix.utf8.count + 1
        while true {
            let candidate = "\(length)\(suffix)"
            if candidate.utf8.count == length { break }
            length = candidate.utf8.count
        }
        let record = "\(length)\(suffix)"
        let parsed = TarFormat.parsePaxRecords(Array(record.utf8))
        XCTAssertEqual(parsed.first?.key, "path")
        XCTAssertEqual(parsed.first?.value, "short")
    }

    func testParsePaxRecordsAllowsAnEqualsSignInsideTheValue() {
        let record = TarFixture.paxRecord("comment", "a=b=c")
        let parsed = TarFormat.parsePaxRecords(Array(record.utf8))
        XCTAssertEqual(parsed.first?.value, "a=b=c")
    }

    func testParsePaxRecordsStopsAtAMalformedLengthRatherThanGuessing() {
        // A declared length longer than what remains cannot be honored; the parser
        // stops (dropping this and everything after it) instead of reading past the
        // buffer or resynchronizing on a guess.
        let malformed = "999 path=x\n"
        XCTAssertTrue(TarFormat.parsePaxRecords(Array(malformed.utf8)).isEmpty)
    }

    // MARK: - PAX mtime

    func testPaxTimeParsesFractionalAndWholeSeconds() {
        XCTAssertEqual(TarFormat.paxTime("1750000000.5"), Date(timeIntervalSince1970: 1_750_000_000.5))
        XCTAssertEqual(TarFormat.paxTime("0"), Date(timeIntervalSince1970: 0))
    }

    func testPaxTimeRejectsNonNumericOrNonFiniteText() {
        XCTAssertNil(TarFormat.paxTime("not-a-time"))
        XCTAssertNil(TarFormat.paxTime("nan"))
    }
}

// MARK: - Fixtures

/// A minimal ustar block writer, only as much as this file needs.
enum TarFixture {

    static func headerBlock(name: String, typeflag: Character, size: Int64) -> [UInt8] {
        var block = [UInt8](repeating: 0, count: TarFormat.blockSize)
        write(&block, String(name.prefix(100)), at: 0, length: 100)
        write(&block, octal(0o644, width: 7), at: 100, length: 8)
        write(&block, octal(0, width: 7), at: 108, length: 8)
        write(&block, octal(0, width: 7), at: 116, length: 8)
        write(&block, octal(UInt64(size), width: 11), at: 124, length: 12)
        write(&block, octal(0, width: 11), at: 136, length: 12)
        block[156] = typeflag.asciiValue ?? UInt8(ascii: "0")
        write(&block, "ustar", at: 257, length: 6)
        write(&block, "00", at: 263, length: 2)

        for offset in 148..<156 { block[offset] = UInt8(ascii: " ") }
        let sum = block.reduce(0) { $0 + Int($1) }
        writeChecksum(&block, value: sum)
        return block
    }

    /// Overwrites the checksum field with a given (already-computed) sum, matching the
    /// standard six-octal-digit-plus-NUL-plus-space layout.
    static func writeChecksum(_ block: inout [UInt8], value: Int) {
        write(&block, octal(UInt64(value), width: 6), at: 148, length: 7)
        block[154] = 0
        block[155] = UInt8(ascii: " ")
    }

    /// A PAX record: `"<len> key=value\n"`, where `len` counts the whole record
    /// including itself.
    static func paxRecord(_ key: String, _ value: String) -> String {
        let suffix = " \(key)=\(value)\n"
        var length = suffix.utf8.count + 1
        while true {
            let candidate = "\(length)\(suffix)"
            if candidate.utf8.count == length { return candidate }
            length = candidate.utf8.count
        }
    }

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
