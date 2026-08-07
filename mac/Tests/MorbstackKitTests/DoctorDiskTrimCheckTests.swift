// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import XCTest

@testable import MorbstackKit

/// Coverage for `Doctor.diskTrimCheck` (TECH-3 / UX-16): the `morb doctor` line that
/// reports whether the guest's periodic background `fstrim` sweep has real evidence
/// that deleted images/containers are coming back to the Mac.
///
/// This is deliberately a pure-function test over `Doctor`'s check builder, not an
/// end-to-end run against a live daemon and guest — the same split the rest of
/// `Doctor`'s check-builders (e.g. `proxyLiveCheck`) leave untested end-to-end but
/// could use exactly this kind of unit coverage for.
final class DoctorDiskTrimCheckTests: XCTestCase {

    func testNoReportedBytesIsInfoNotAFailureOrWarning() {
        // The sweep runs on a slow, deliberately staggered cadence (10-minute warmup,
        // hourly thereafter) — "nothing yet" is the ordinary state for a VM that has
        // been up only briefly, not a problem to flag as `.warn`/`.fail`.
        let check = Doctor.diskTrimCheck(reportedBytes: nil)

        XCTAssertEqual(check.name, "disk-trim")
        XCTAssertEqual(check.status, .info)
    }

    func testNoReportedBytesNamesEveryLegitimateCauseWithoutClaimingWhichOneApplies() {
        let check = Doctor.diskTrimCheck(reportedBytes: nil)

        // `nil` collapses three different real states (no sweep yet, a RAM-backed data
        // root, an older guest image); the detail must not overclaim which one is true.
        XCTAssertTrue(check.detail.contains("none has run yet"))
        XCTAssertTrue(check.detail.contains("RAM-backed"))
        XCTAssertTrue(check.detail.contains("predates"))
    }

    func testAZeroByteSweepIsStillAPassNotAnAbsence() {
        // Zero is a real answer ("nothing to reclaim this sweep"), not the "no sweep
        // yet" sentinel — `nil` and `Optional(0)` must produce different checks.
        let check = Doctor.diskTrimCheck(reportedBytes: 0)

        XCTAssertEqual(check.status, .pass)
        XCTAssertFalse(check.detail.contains("none has run yet"))
        XCTAssertTrue(check.detail.contains("0 B"), "sub-1024-byte counts print as a bare byte count: \(check.detail)")
    }

    func testARealSweepResultNamesTheExactByteCountReturnedToTheMac() {
        // The exact figure the TECH-3 spike measured live
        // (`docs/design/DISK-RECLAIM-DECISION.md` §4 step 8): 59,050,795,008 bytes is
        // 54.995… GiB, which `Doctor`'s binary-unit formatter rounds to "55.0 GiB".
        let check = Doctor.diskTrimCheck(reportedBytes: 59_050_795_008)

        XCTAssertEqual(check.status, .pass)
        XCTAssertTrue(
            check.detail.contains("55.0 GiB"),
            "the check must name the real figure, not a rounded-differently or invented one: \(check.detail)")
        XCTAssertTrue(check.detail.contains("returned"))
    }

    func testNeverFailsOrWarnsRegardlessOfTheReportedByteCount() {
        // No shape of `reportedBytes` should ever surface as `.warn`/`.fail` — a
        // reclaim sweep result is evidence, never itself a problem to block on.
        for bytes: Int64? in [nil, 0, 1, 59_050_795_008, Int64.max] {
            let check = Doctor.diskTrimCheck(reportedBytes: bytes)
            XCTAssertTrue(
                check.status == .pass || check.status == .info,
                "\(String(describing: bytes)) produced \(check.status)")
        }
    }
}
