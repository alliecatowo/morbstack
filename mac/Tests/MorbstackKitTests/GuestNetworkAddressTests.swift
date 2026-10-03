// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Pure parsing only — `GuestNetworkAddressLookup.parse(_:macAddress:)` and
// `normalizeMAC(_:)` against fixture text shaped like the real
// `/var/db/dhcpd_leases`. `currentAddress()` itself (the file read) is not exercised
// here: it opens no fixture seam and reads a real, root-owned system path (see
// `GuestNetworkAddress.swift`'s doc comment and the DIF-4 step 0 report for what was
// verified against the live file on 2026-08-06).

import XCTest

@testable import MorbstackKit

final class GuestNetworkAddressLookupTests: XCTestCase {

    /// The exact `hw_address` form macOS writes today (no leading zeros), for the
    /// pinned guest MAC `02:4d:52:42:00:01` — captured verbatim from
    /// `/var/db/dhcpd_leases` on this host while a Morbstack guest was running.
    private let pinnedGuestMACAsWrittenByMacOS = "2:4d:52:42:0:1"
    private let pinnedGuestMACCanonicalForm = "02:4d:52:42:00:01"

    func testParsesTheSingleMatchingEntry() {
        let leases = """
            {
            \thw_address=1,ea:6a:7:cb:15:45
            \tip_address=192.168.64.26
            \tidentifier=1,ea:6a:7:cb:15:45
            \tlease=0x6a6ea00b
            }
            {
            \tip_address=192.168.64.27
            \thw_address=1,\(pinnedGuestMACAsWrittenByMacOS)
            \tidentifier=1,\(pinnedGuestMACAsWrittenByMacOS)
            \tlease=0x6a74c4bc
            }
            """
        let result = GuestNetworkAddressLookup.parse(leases, macAddress: pinnedGuestMACCanonicalForm)
        XCTAssertEqual(result?.ipv4, "192.168.64.27")
        XCTAssertEqual(result?.leaseExpiry, Date(timeIntervalSince1970: 0x6a74c4bc))
    }

    /// macOS omits leading zeros in `hw_address`; the lookup normalizes both sides so
    /// the pinned canonical form (as `VMManager.guestMACAddress` stores it) still
    /// matches.
    func testMatchesDespiteMacOSsUnpaddedHexOctets() {
        let leases = """
            {
            \tip_address=192.168.64.5
            \thw_address=1,\(pinnedGuestMACAsWrittenByMacOS)
            \tlease=0x1
            }
            """
        let result = GuestNetworkAddressLookup.parse(leases, macAddress: pinnedGuestMACCanonicalForm)
        XCTAssertEqual(result?.ipv4, "192.168.64.5")
    }

    /// A guest that has been assigned different addresses across restarts leaves every
    /// prior lease in the file; the entry with the numerically greatest lease epoch —
    /// the newest grant — must win, regardless of file order.
    func testWhenMultipleEntriesMatchTheNewestLeaseWins() {
        let leases = """
            {
            \tip_address=192.168.64.9
            \thw_address=1,\(pinnedGuestMACAsWrittenByMacOS)
            \tlease=0x2
            }
            {
            \tip_address=192.168.64.27
            \thw_address=1,\(pinnedGuestMACAsWrittenByMacOS)
            \tlease=0x6a74c4bc
            }
            {
            \tip_address=192.168.64.3
            \thw_address=1,\(pinnedGuestMACAsWrittenByMacOS)
            \tlease=0x1
            }
            """
        let result = GuestNetworkAddressLookup.parse(leases, macAddress: pinnedGuestMACCanonicalForm)
        XCTAssertEqual(result?.ipv4, "192.168.64.27")
    }

    func testReturnsNilWhenNoEntryMatchesTheTargetMAC() {
        let leases = """
            {
            \tip_address=192.168.64.9
            \thw_address=1,ea:6a:7:cb:15:45
            \tlease=0x2
            }
            """
        XCTAssertNil(GuestNetworkAddressLookup.parse(leases, macAddress: pinnedGuestMACCanonicalForm))
    }

    func testReturnsNilForEmptyOrMalformedInput() {
        XCTAssertNil(GuestNetworkAddressLookup.parse("", macAddress: pinnedGuestMACCanonicalForm))
        XCTAssertNil(GuestNetworkAddressLookup.parse("not a lease file at all", macAddress: pinnedGuestMACCanonicalForm))
        // A record missing `ip_address` entirely must not surface a nil-coalesced
        // placeholder address.
        let missingIP = """
            {
            \thw_address=1,\(pinnedGuestMACAsWrittenByMacOS)
            \tlease=0x1
            }
            """
        XCTAssertNil(GuestNetworkAddressLookup.parse(missingIP, macAddress: pinnedGuestMACCanonicalForm))
    }

    /// `lease=` is optional in principle; a matching entry with no parseable lease
    /// value is still a real answer, just with no known expiry, and it must not crash
    /// the `UInt32(_:radix:)` parse.
    func testMissingOrUnparseableLeaseYieldsNoExpiryNotAFailure() {
        let leases = """
            {
            \tip_address=192.168.64.7
            \thw_address=1,\(pinnedGuestMACAsWrittenByMacOS)
            \tlease=not-hex
            }
            """
        let result = GuestNetworkAddressLookup.parse(leases, macAddress: pinnedGuestMACCanonicalForm)
        XCTAssertEqual(result?.ipv4, "192.168.64.7")
        XCTAssertNil(result?.leaseExpiry)
    }

    /// An unrecognized target MAC (wrong octet count, non-hex) must fail closed rather
    /// than matching everything.
    func testInvalidTargetMACAlwaysReturnsNil() {
        let leases = """
            {
            \tip_address=192.168.64.7
            \thw_address=1,\(pinnedGuestMACAsWrittenByMacOS)
            \tlease=0x1
            }
            """
        XCTAssertNil(GuestNetworkAddressLookup.parse(leases, macAddress: "not-a-mac"))
        XCTAssertNil(GuestNetworkAddressLookup.parse(leases, macAddress: "aa:bb:cc"))
    }

    func testNormalizeMACPadsAndLowercases() {
        XCTAssertEqual(
            GuestNetworkAddressLookup.normalizeMAC("2:4D:52:42:0:1"),
            "02:4d:52:42:00:01")
        XCTAssertEqual(
            GuestNetworkAddressLookup.normalizeMAC("02:4d:52:42:00:01"),
            "02:4d:52:42:00:01")
        XCTAssertNil(GuestNetworkAddressLookup.normalizeMAC("02:4d:52"))
        XCTAssertNil(GuestNetworkAddressLookup.normalizeMAC("zz:4d:52:42:00:01"))
        XCTAssertNil(GuestNetworkAddressLookup.normalizeMAC(""))
    }

    /// A record count far beyond anything a real `/24` lease file would contain must
    /// not hang or exhaust memory — the parser stops honoring new `{ ... }` records
    /// past the cap rather than growing unbounded.
    func testEntryCountIsBounded() {
        var leases = ""
        for index in 0..<5000 {
            leases += """
                {
                \tip_address=10.0.0.\(index % 250)
                \thw_address=1,aa:bb:cc:dd:ee:\(String(format: "%02x", index % 256))
                \tlease=0x1
                }

                """
        }
        // The target MAC never appears, so this only proves the parser terminates
        // promptly on a pathological entry count.
        XCTAssertNil(GuestNetworkAddressLookup.parse(leases, macAddress: pinnedGuestMACCanonicalForm))
    }
}
