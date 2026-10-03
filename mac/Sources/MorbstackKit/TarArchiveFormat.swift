// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The mechanical parts of reading a ustar/GNU/PAX tar header block, shared by every
// tar reader in the app: `ContainerTarHeaderReader` (MorbstackAppCore, arbitrary
// in-container paths), `TarChildWalker` (MorbFeatures, a Docker volume's immediate
// children), and `TarLite` (MorbMigrate, a plain regular-file count). MorbstackKit is
// the only module all three already depend on — MorbFeatures is itself a dependency of
// MorbstackAppCore, so the shared code cannot live in either of them.
//
// Deliberately narrow: this owns only the byte-level format rules that do not change
// between callers — the ustar checksum, octal/base-256 numeric fields, NUL-terminated
// text fields, PAX record framing, and the typeflag→kind table. What a caller does with
// a field that fails to parse, which entries it keeps, how much it is willing to
// buffer, and what error (if any) it raises for its own reader — that is policy, and it
// stays with the caller.
//
// Two real bugs, found by a person reading two of the three readers side by side rather
// than by any test, motivated pulling this out:
//
//  - A base-256 size field's overflow guard existed in one reader and not the other,
//    where a large GNU size field silently wrapped through `<<` instead of being
//    refused. It compiled cleanly.
//  - A GNU long-name entry's trailing NUL — which real writers include in the field's
//    *declared length* — was being decoded into a `String` and only then searched for a
//    NUL in one reader, so the byte was kept, and the control-character check that ran
//    next rejected the entry. Every real-world long-name entry would have vanished from
//    that reader's listing, silently.
//
// Both are `TarFormat.numericField` and `TarFormat.cString` now: tested once, here,
// rather than three times unevenly.

import Foundation

/// What a tar entry's typeflag says it is — the same kinds POSIX ustar plus the
/// GNU/historical extensions can name. Every reader in the app maps its own
/// domain-specific "kind" from this rather than re-reading the typeflag byte itself.
public enum TarEntryKind: String, Equatable, Sendable {
    case directory
    case regularFile
    case symbolicLink
    case hardLink
    case characterDevice
    case blockDevice
    case fifo
    case socket
    case unknown
}

/// One 512-byte tar header block's format rules — checksum, numeric fields, text
/// fields, PAX record framing, typeflag mapping — with no opinion about what a caller
/// does when one of them fails to parse.
public enum TarFormat {

    public static let blockSize = 512

    /// The ustar header checksum, accepting both the (correct) unsigned interpretation
    /// and the historical signed-byte one real-world writers also produce.
    ///
    /// `block` must be exactly ``blockSize`` bytes, 0-indexed from the start of the
    /// header — an `Array`, not an arbitrary slice, since every field offset below is
    /// relative to byte 0 of the block. A mismatch means the reader has lost the
    /// stream, which every caller treats as a real failure rather than something to
    /// paper over with a best guess.
    public static func checksumMatches(_ block: [UInt8]) -> Bool {
        guard block.count == blockSize, let declared = numericField(block[148..<156]) else {
            return false
        }
        var unsigned = 0
        var signed = 0
        for (index, byte) in block.enumerated() {
            let value = (148..<156).contains(index) ? UInt8(ascii: " ") : byte
            unsigned += Int(value)
            signed += Int(Int8(bitPattern: value))
        }
        return declared == Int64(unsigned) || declared == Int64(signed)
    }

    /// Tar numerics are NUL/space-padded ASCII octal, except when the high bit of the
    /// first byte is set — then the field is big-endian base 256, which is how sizes
    /// above 8 GB and times after 2242 are written.
    ///
    /// `nil` means the field could not be read at all: malformed octal text, or a
    /// base-256 magnitude that would overflow `Int64` before all of its bytes were
    /// folded in. Never a wrapped-around guess — that is the difference between
    /// refusing an impossible entry and silently desyncing on whatever comes after it.
    public static func numericField(_ field: some Collection<UInt8>) -> Int64? {
        guard let first = field.first else { return nil }
        if first & 0x80 != 0 {
            var value = Int64(first & 0x7F)
            for byte in field.dropFirst() {
                guard value <= (Int64.max >> 8) else { return nil }
                value = (value << 8) | Int64(byte)
            }
            return value
        }
        let text = String(decoding: field, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        if text.isEmpty { return 0 }
        guard text.allSatisfy({ $0.isASCII && ("0"..."7").contains($0) }) else { return nil }
        return Int64(text, radix: 8)
    }

    /// A fixed-width tar text field, NUL-terminated. The same rule truncates a ustar
    /// `name`/`prefix`/`linkname` field and a GNU long-name/long-link entry's decoded
    /// content: real GNU writers declare that content's length *including* its trailing
    /// NUL, so operating on the raw bytes here — rather than decoding to a `String`
    /// first and only then hunting for a NUL — is what keeps that trailing byte from
    /// ever reaching a caller's control-character check.
    public static func cString(_ field: some Collection<UInt8>) -> String {
        let end = field.firstIndex(of: 0) ?? field.endIndex
        return String(decoding: field[field.startIndex..<end], as: UTF8.self)
    }

    /// Typeflag byte → the kind of entry it names, matching both POSIX ustar and the
    /// GNU/historical extensions real writers still produce (typeflag `0`, and the
    /// pre-POSIX all-NUL typeflag, both mean a regular file; `7` — "contiguous file" —
    /// is a regular file for every practical purpose, and every other tar reader agrees).
    public static func kind(forTypeflag typeflag: UInt8) -> TarEntryKind {
        switch typeflag {
        case 0, UInt8(ascii: "0"), UInt8(ascii: "7"): return .regularFile
        case UInt8(ascii: "1"): return .hardLink
        case UInt8(ascii: "2"): return .symbolicLink
        case UInt8(ascii: "3"): return .characterDevice
        case UInt8(ascii: "4"): return .blockDevice
        case UInt8(ascii: "5"): return .directory
        case UInt8(ascii: "6"): return .fifo
        default: return .unknown
        }
    }

    /// PAX records are `"<decimal length> key=value\n"`, where the decimal prefix is
    /// the length of the whole record including itself — which is what lets a value
    /// contain anything, a newline included, without ambiguity.
    ///
    /// `bytes` is the already length-and-padding-bounded content of one `x`/`X`/`g`
    /// header. A record whose declared length does not fit what remains is dropped
    /// along with everything after it, rather than guessed at.
    public static func parsePaxRecords(_ bytes: [UInt8]) -> [(key: String, value: String)] {
        var records: [(key: String, value: String)] = []
        var index = 0
        while index < bytes.count {
            guard let space = bytes[index...].firstIndex(of: UInt8(ascii: " ")) else { break }
            let digits = String(decoding: bytes[index..<space], as: UTF8.self)
            guard let length = Int(digits), length > 0,
                index + length <= bytes.count, space + 1 <= index + length
            else { break }
            var end = index + length
            // The record ends in a newline; tolerate its absence rather than dropping
            // the record.
            if end > space + 1, bytes[end - 1] == UInt8(ascii: "\n") { end -= 1 }
            let body = String(decoding: bytes[(space + 1)..<end], as: UTF8.self)
            if let equals = body.firstIndex(of: "=") {
                records.append(
                    (
                        key: String(body[body.startIndex..<equals]),
                        value: String(body[body.index(after: equals)...])
                    ))
            }
            index += length
        }
        return records
    }

    /// PAX times are decimal seconds since the epoch, optionally fractional.
    public static func paxTime(_ value: String) -> Date? {
        guard let seconds = Double(value), seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
