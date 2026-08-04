// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import XCTest

@testable import MorbstackKit

/// `MorbVersion.isOlder(_:than:)` is the entire host-side mechanism behind the
/// protocol's `morbinit_version` compatibility probe (PROTO-1): the boot probe
/// compares the guest's reported version against
/// `MorbVersion.minimumCompatibleMorbinit` and warns in the log, `morb status`
/// and `morb doctor`. These tests pin the ordering rules the comparison relies
/// on, in particular that a milestone suffix precedes its bare core and that an
/// unparseable string is never treated as "older".
final class MorbVersionCompatibilityTests: XCTestCase {

    func testDottedCoreOrdersNumerically() {
        XCTAssertTrue(MorbVersion.isOlder("0.1.0", than: "0.2.0"))
        XCTAssertTrue(MorbVersion.isOlder("0.9.9", than: "1.0.0"))
        XCTAssertTrue(MorbVersion.isOlder("1.2.3", than: "1.2.10"))  // numeric, not lexical
        XCTAssertFalse(MorbVersion.isOlder("0.2.0", than: "0.1.0"))
        XCTAssertFalse(MorbVersion.isOlder("0.1.0", than: "0.1.0"))
    }

    func testShorterCoresPadWithZeros() {
        XCTAssertFalse(MorbVersion.isOlder("0.1", than: "0.1.0"))
        XCTAssertFalse(MorbVersion.isOlder("0.1.0", than: "0.1"))
        XCTAssertTrue(MorbVersion.isOlder("0.1", than: "0.1.1"))
    }

    func testMilestoneSuffixPrecedesBareCore() {
        // Semver prerelease convention: 0.1.0-m1 < 0.1.0.
        XCTAssertTrue(MorbVersion.isOlder("0.1.0-m1", than: "0.1.0"))
        XCTAssertFalse(MorbVersion.isOlder("0.1.0", than: "0.1.0-m1"))
    }

    func testMilestonesOrderNumerically() {
        XCTAssertTrue(MorbVersion.isOlder("0.1.0-m0", than: "0.1.0-m1"))
        XCTAssertTrue(MorbVersion.isOlder("0.1.0-m2", than: "0.1.0-m10"))
        XCTAssertFalse(MorbVersion.isOlder("0.1.0-m1", than: "0.1.0-m1"))
        // A newer core beats any milestone comparison.
        XCTAssertFalse(MorbVersion.isOlder("0.2.0-m0", than: "0.1.0"))
    }

    func testUnparseableVersionsAreNeverOlder() {
        // An unknown format is a different failure from an out-of-date guest; the
        // compatibility gate must not fire on it in either position.
        XCTAssertFalse(MorbVersion.isOlder("garbage", than: "0.1.0-m0"))
        XCTAssertFalse(MorbVersion.isOlder("0.1.0-m0", than: "garbage"))
        XCTAssertFalse(MorbVersion.isOlder("", than: "0.1.0-m0"))
        XCTAssertFalse(MorbVersion.isOlder("1.2.x", than: "0.1.0-m0"))
        XCTAssertFalse(MorbVersion.isOlder("0.1.0-rc1", than: "0.1.0-m0"))  // foreign suffix
        XCTAssertFalse(MorbVersion.isOlder("0.1.0-m", than: "0.1.0-m0"))
        XCTAssertFalse(MorbVersion.isOlder("0..1", than: "0.1.0-m0"))
    }

    func testShippedConstantsAreSelfConsistent() {
        // The daemon's own version must never be older than the minimum guest it
        // demands — the two are built from the same tree.
        XCTAssertFalse(
            MorbVersion.isOlder(MorbVersion.string, than: MorbVersion.minimumCompatibleMorbinit))
        // And the minimum itself must parse, or the gate is dead again.
        XCTAssertTrue(
            MorbVersion.isOlder("0.0.1", than: MorbVersion.minimumCompatibleMorbinit),
            "minimumCompatibleMorbinit must parse; a typo here would silently disable the gate")
    }
}
