// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Foundation
import XCTest

@testable import MorbstackKit

/// Hermetic coverage for the durable recovery record. These tests intentionally
/// decode bytes only; they never create, extend, or inspect a disk image.
final class MorbDiskGrowthTests: XCTestCase {

    private let originalBytes: Int64 = 64 * MorbDiskCapacity.bytesPerGiB
    private let targetBytes: Int64 = 128 * MorbDiskCapacity.bytesPerGiB

    private func proof(resized: Bool = true, previouslyProved: Bool = false) -> MorbDiskGrowth.GuestProof {
        MorbDiskGrowth.GuestProof(
            device: "/dev/vda",
            mountPoint: "/var/lib/docker",
            filesystem: "ext4",
            deviceBytes: targetBytes,
            beforeFilesystemBytes: originalBytes,
            afterFilesystemBytes: targetBytes,
            resized: resized,
            previouslyProved: previouslyProved)
    }

    private func journal(
        phase: MorbDiskGrowth.Phase,
        proof: MorbDiskGrowth.GuestProof? = nil
    ) -> MorbDiskGrowth.Journal {
        MorbDiskGrowth.Journal(
            imagePath: "/private/tmp/hermetic-disk.img",
            identity: .init(device: 101, inode: 202),
            originalBytes: originalBytes,
            targetBytes: targetBytes,
            phase: phase,
            proof: proof)
    }

    func testHostGrownJournalCodecPreservesRecoveryState() throws {
        let expected = journal(phase: .hostGrown)
        let decoded = try MorbDiskGrowth.decodeJournal(JSONEncoder().encode(expected))

        XCTAssertEqual(decoded, expected)
        XCTAssertEqual(decoded.phase, .hostGrown)
        XCTAssertNil(decoded.proof)
    }

    func testGuestProvedJournalCodecPreservesProofForRetry() throws {
        let expected = journal(phase: .guestProved, proof: proof())
        let decoded = try MorbDiskGrowth.decodeJournal(JSONEncoder().encode(expected))

        XCTAssertEqual(decoded, expected)
        XCTAssertEqual(decoded.proof, proof())
    }

    func testGuestProvedJournalWithoutProofIsRejected() throws {
        let malformed = journal(phase: .guestProved)

        XCTAssertThrowsError(try MorbDiskGrowth.decodeJournal(JSONEncoder().encode(malformed))) { error in
            XCTAssertTrue("\(error)".contains("guest-proved without a guest proof"))
        }
    }

    func testPreProofJournalCannotCarryAGuestProof() throws {
        let malformed = journal(phase: .hostGrown, proof: proof())

        XCTAssertThrowsError(try MorbDiskGrowth.decodeJournal(JSONEncoder().encode(malformed))) { error in
            XCTAssertTrue("\(error)".contains("before the guest-proved phase"))
        }
    }

    func testGuestProvedJournalRejectsAnUnprovenNoOp() throws {
        let malformed = journal(
            phase: .guestProved,
            proof: proof(resized: false, previouslyProved: false))

        XCTAssertThrowsError(try MorbDiskGrowth.decodeJournal(JSONEncoder().encode(malformed))) { error in
            XCTAssertTrue("\(error)".contains("no filesystem growth"))
        }
    }

    func testUnknownJournalVersionIsRejected() {
        let payload = Data(#"""
            {"version":99,"imagePath":"/private/tmp/hermetic-disk.img",
             "identity":{"device":101,"inode":202},"originalBytes":68719476736,
             "targetBytes":137438953472,"phase":"prepared"}
            """#.utf8)

        XCTAssertThrowsError(try MorbDiskGrowth.decodeJournal(payload)) { error in
            XCTAssertTrue("\(error)".contains("unsupported disk-grow journal version"))
        }
    }
}
