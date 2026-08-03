// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// These are pure migration-policy tests. They do not open a Unix socket, start an
// engine, create a helper container, or inspect any volume contents.

import Foundation
import XCTest

@testable import MorbMigrate

final class VolumeMigrationPlanTests: XCTestCase {

    func testOnlyNewLocalVolumesAreEligible() {
        let plan = MigrationVolumePlanner.plan(
            source: [
                .init(name: "new-data", driver: "local"),
                .init(name: "already-there", driver: "local"),
                .init(name: "remote-data", driver: "nfs"),
            ],
            destination: [
                .init(name: "already-there", driver: "local"),
            ])

        XCTAssertEqual(plan.items.map(\.name), ["already-there", "new-data", "remote-data"])
        XCTAssertEqual(plan.eligible.map(\.name), ["new-data"])
        XCTAssertEqual(plan.destinationExisting.map(\.name), ["already-there"])
        XCTAssertEqual(plan.unsupported.map(\.name), ["remote-data"])
    }

    func testExistingDestinationIsNeverAssumedEmptyOrOverwritable() throws {
        let plan = MigrationVolumePlanner.plan(
            source: [.init(name: "postgres", driver: "local")],
            destination: [.init(name: "postgres", driver: "local")])
        let item = try XCTUnwrap(plan.items.first)

        XCTAssertEqual(item.disposition, .destinationExists)
        XCTAssertFalse(item.isEligible)
        XCTAssertTrue(item.reason.contains("contents were not inspected"))
        XCTAssertTrue(item.reason.contains("overwrite or merge"))
    }

    func testUnknownDriverCannotAccidentallyBecomeLocalEligibility() throws {
        let plan = MigrationVolumePlanner.plan(
            source: [.init(name: "incomplete", driver: "unknown")],
            destination: [])
        let item = try XCTUnwrap(plan.items.first)

        XCTAssertEqual(item.disposition, .unsupportedDriver)
        XCTAssertFalse(item.isEligible)
        XCTAssertTrue(plan.eligible.isEmpty)
    }

    func testPlanRoundTripsWithoutChangingEligibility() throws {
        let original = MigrationVolumePlanner.plan(
            source: [
                .init(name: "cache", driver: "local"),
                .init(name: "managed", driver: "plugin"),
            ],
            destination: [])

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MigrationVolumePlan.self, from: encoded)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.eligible.map(\.name), ["cache"])
    }
}
