// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import XCTest

@testable import MorbstackKit

/// `MorbLocalDomain.Name` is the name-derivation boundary the DIF-4 mDNS registrar
/// consumes (see `docs/design/DNS-DECISION.md`): every registered `A` record name must
/// be an exact, ASCII, `Host`-header-safe hostname below `morb.local`. These tests pin
/// the reject-don't-normalize contract.
final class MorbLocalDomainNameTests: XCTestCase {

    func testSubdomainProducesHostnameBelowSuffix() throws {
        let name = try MorbLocalDomain.Name(subdomain: "api.todo")
        XCTAssertEqual(name.hostname, "api.todo.morb.local")
        XCTAssertEqual(name.labels, ["api", "todo"])
    }

    func testUppercaseIsLowercasedNotRejected() throws {
        let name = try MorbLocalDomain.Name(subdomain: "API.Todo")
        XCTAssertEqual(name.hostname, "api.todo.morb.local")
    }

    func testHostnameParsingAcceptsTrailingRootDot() throws {
        let name = try MorbLocalDomain.Name(hostname: "web.demo.morb.local.")
        XCTAssertEqual(name.hostname, "web.demo.morb.local")
    }

    func testHostnameOutsideSuffixIsRejected() {
        XCTAssertThrowsError(try MorbLocalDomain.Name(hostname: "web.demo.example.com"))
        XCTAssertThrowsError(try MorbLocalDomain.Name(hostname: "morb.local"))
        XCTAssertThrowsError(try MorbLocalDomain.Name(hostname: "evil-morb.local"))
    }

    func testWildcardsEmptyLabelsAndUnicodeAreRejected() {
        XCTAssertThrowsError(try MorbLocalDomain.Name(subdomain: "*.todo"))
        XCTAssertThrowsError(try MorbLocalDomain.Name(subdomain: "api..todo"))
        XCTAssertThrowsError(try MorbLocalDomain.Name(subdomain: ""))
        XCTAssertThrowsError(try MorbLocalDomain.Name(subdomain: "café"))
        XCTAssertThrowsError(try MorbLocalDomain.Name(subdomain: "a_b"))
    }

    func testHyphenPlacementFollowsDNSLabelRules() throws {
        XCTAssertEqual(try MorbLocalDomain.Name(subdomain: "my-app").hostname, "my-app.morb.local")
        XCTAssertThrowsError(try MorbLocalDomain.Name(subdomain: "-app"))
        XCTAssertThrowsError(try MorbLocalDomain.Name(subdomain: "app-"))
    }

    func testLabelAndHostnameLengthLimits() {
        let longLabel = String(repeating: "a", count: 64)
        XCTAssertThrowsError(try MorbLocalDomain.Name(subdomain: longLabel))
        XCTAssertNoThrow(try MorbLocalDomain.Name(subdomain: String(repeating: "a", count: 63)))

        let nearLimit = Array(repeating: String(repeating: "a", count: 60), count: 4)
            .joined(separator: ".")
        XCTAssertThrowsError(try MorbLocalDomain.Name(subdomain: nearLimit))
    }
}
