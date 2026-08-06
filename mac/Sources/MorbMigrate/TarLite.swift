// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Just enough of the ustar format to count regular files in an archive already on
// disk, for the "file counts" `morb migrate volumes` reports. Not a general tar reader:
// it walks headers and skips data blocks, and it does not extract anything — but the
// header fields it does read (the checksum, the size) go through MorbstackKit's
// `TarFormat`, the same code `ContainerTarHeaderReader` and `TarChildWalker` use, so a
// corrupted or hostile archive desyncs this reader no more quietly than it does theirs.
// A project already committed to zero external dependencies is not going to hand-roll a
// full tar implementation for a line in a progress report — but "zero dependencies"
// never meant "its own, unvetted copy of the size-field overflow check."

import Foundation
import MorbstackKit

enum TarLite {

    /// Counts regular-file entries in a tar file, without holding the whole thing in
    /// memory.
    ///
    /// Returns whatever it counted so far — `0` on the first header — for anything
    /// that stops looking like a ustar stream, rather than throwing: this feeds a
    /// report line ("N files"), not a correctness check, and the copy already
    /// succeeded or failed independently of whether this count is exact. What it will
    /// not do is keep reading past a header whose checksum does not match or whose size
    /// field cannot be read at all — either one means this is no longer reliably a
    /// sequence of headers, and guessing a size (the previous behavior: an unreadable
    /// field silently became `0`, which under-skips and starts parsing file content as
    /// though it were the next header) is how a reader invents entries instead of
    /// admitting it lost the stream.
    static func countRegularFiles(at url: URL) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }

        var count = 0
        var zeroBlocksInARow = 0

        while true {
            let headerData = handle.readData(ofLength: TarFormat.blockSize)
            guard headerData.count == TarFormat.blockSize else { break }
            let header = [UInt8](headerData)
            if header.allSatisfy({ $0 == 0 }) {
                zeroBlocksInARow += 1
                // Two consecutive all-zero blocks is the end-of-archive marker.
                if zeroBlocksInARow >= 2 { break }
                continue
            }
            zeroBlocksInARow = 0

            guard TarFormat.checksumMatches(header) else { break }
            guard let size = TarFormat.numericField(header[124..<136]), size >= 0 else { break }

            if TarFormat.kind(forTypeflag: header[156]) == .regularFile {
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
}
