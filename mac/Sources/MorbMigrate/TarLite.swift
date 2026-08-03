// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Just enough of the ustar format to count regular files in an archive already on
// disk, for the "file counts" `morb migrate volumes` reports. Not a general tar reader:
// it walks headers and skips data blocks, and it does not extract or verify anything,
// because a project already committed to zero external dependencies is not going to
// hand-roll a full tar implementation for a line in a progress report.

import Foundation

enum TarLite {

    /// Counts regular-file entries (`typeflag` `'0'` or the historical NUL) in a tar
    /// file, without holding the whole thing in memory.
    ///
    /// Returns `0` for anything that does not parse as a ustar stream rather than
    /// throwing — this feeds a report line ("N files"), not a correctness check, and
    /// the copy already succeeded or failed independently of whether this count is
    /// exact.
    static func countRegularFiles(at url: URL) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }

        var count = 0
        var zeroBlocksInARow = 0

        while true {
            let header = handle.readData(ofLength: 512)
            guard header.count == 512 else { break }
            if header.allSatisfy({ $0 == 0 }) {
                zeroBlocksInARow += 1
                // Two consecutive all-zero blocks is the end-of-archive marker.
                if zeroBlocksInARow >= 2 { break }
                continue
            }
            zeroBlocksInARow = 0

            let typeflag = header[header.startIndex + 156]
            let sizeField = header.subdata(in: (header.startIndex + 124)..<(header.startIndex + 136))
            let size = parseOctal(sizeField)

            if typeflag == UInt8(ascii: "0") || typeflag == 0 {
                count += 1
            }

            // Data is padded up to the next 512-byte boundary.
            let paddedSize = ((size + 511) / 512) * 512
            if paddedSize > 0 {
                handle.seek(toFileOffset: handle.offsetInFile + UInt64(paddedSize))
            }
        }
        return count
    }

    /// Tar's numeric header fields are ASCII octal, NUL/space padded.
    private static func parseOctal(_ data: Data) -> Int {
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        guard !text.isEmpty else { return 0 }
        return Int(text, radix: 8) ?? 0
    }
}
