// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Virtualization
import XCTest

@testable import MorbstackKit

/// The guest's MAC address has to be a fixed, valid, locally-administered
/// unicast address.
///
/// Regression: `VZVirtioNetworkDeviceConfiguration` defaults to a *random*
/// MAC, generated afresh every time the configuration is built. Restoring a
/// saved VM builds a new configuration, so a random MAC means the restore
/// configuration never matches the one that was saved, and
/// Virtualization.framework rejects it with a bare "permission denied" that
/// looks like an entitlement problem. Reverting to the default would silently
/// break suspend/resume again, so pin the properties here.
final class GuestMACTests: XCTestCase {

    func testPinnedGuestMACIsParseable() {
        XCTAssertNotNil(
            VZMACAddress(string: VMManager.guestMACAddress),
            "the pinned MAC must parse, or buildConfiguration falls back to a random one")
    }

    func testPinnedGuestMACIsLocallyAdministeredUnicast() throws {
        let octets = VMManager.guestMACAddress.split(separator: ":")
        XCTAssertEqual(octets.count, 6)
        let first = try XCTUnwrap(UInt8(octets[0], radix: 16))
        // Bit 0 clear: unicast, not multicast. A multicast source address is
        // invalid and switches/stacks may drop the frames.
        XCTAssertEqual(first & 0x01, 0, "MAC must be unicast")
        // Bit 1 set: locally administered, so it cannot collide with a real
        // vendor-assigned address.
        XCTAssertEqual(first & 0x02, 0x02, "MAC must be locally administered")
    }

    func testPinnedGuestMACIsStable() {
        // Not a tautology: it asserts the address is a compile-time constant
        // rather than something regenerated per access.
        XCTAssertEqual(VMManager.guestMACAddress, VMManager.guestMACAddress)
        XCTAssertEqual(VMManager.guestMACAddress, "02:4d:52:42:00:01")
    }
}
