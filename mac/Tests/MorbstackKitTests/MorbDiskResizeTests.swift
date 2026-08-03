// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import XCTest

@testable import MorbstackKit

/// Pure policy coverage for the intentionally non-mutating disk-growth gate.
final class MorbDiskResizeTests: XCTestCase {

    private func capacity(
        current: Int64?,
        configuredGiB: Int = 128
    ) -> MorbDiskCapacity.Status {
        MorbDiskCapacity.status(
            imagePath: "/tmp/disk.img",
            configuredGiB: configuredGiB,
            currentBytes: current)
    }

    func testGrowthRequiresAStoppedVMBeforeGuestCapabilityMatters() {
        let diagnostic = MorbDiskResize.diagnose(
            capacity: capacity(current: 64 * MorbDiskCapacity.bytesPerGiB),
            vmState: .running,
            guestCapability: .ready)

        XCTAssertEqual(diagnostic.state, .vmMustStop)
    }

    func testCurrentGuestExplicitlyBlocksAStoppedGrowthRequest() {
        let diagnostic = MorbDiskResize.diagnose(
            capacity: capacity(current: 64 * MorbDiskCapacity.bytesPerGiB),
            vmState: .stopped,
            guestCapability: .unavailable)

        XCTAssertEqual(diagnostic.state, .guestResizeUnavailable)
        XCTAssertTrue(diagnostic.summary.contains("will not enlarge"))
    }

    func testAnOlderGuestNeverBecomesReadyByDefault() {
        XCTAssertEqual(MorbDiskResize.GuestCapability(wireValue: nil), .unknown)
        XCTAssertEqual(MorbDiskResize.GuestCapability(wireValue: "not-a-capability"), .unknown)

        let diagnostic = MorbDiskResize.diagnose(
            capacity: capacity(current: 64 * MorbDiskCapacity.bytesPerGiB),
            vmState: .stopped,
            guestCapability: .unknown)
        XCTAssertEqual(diagnostic.state, .guestCapabilityUnknown)
    }

    func testAConfiguredShrinkIsRejectedWithoutConsultingTheGuest() {
        let diagnostic = MorbDiskResize.diagnose(
            capacity: capacity(current: 128 * MorbDiskCapacity.bytesPerGiB, configuredGiB: 64),
            vmState: .stopped,
            guestCapability: .ready)

        XCTAssertEqual(diagnostic.state, .decreaseUnsupported)
    }
}
