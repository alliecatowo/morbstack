// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import XCTest

@testable import MorbstackKit

/// Pure contract coverage for the preparatory FSEvents bridge. These tests do not
/// create an FSEvent stream, boot a VM, or claim that inotify can be injected.
final class LiveShareBridgeTests: XCTestCase {

    private let shares = [
        MorbDirectoryShare(tag: "morbshare0", path: "/Users"),
        MorbDirectoryShare(tag: "morbshare1", path: "/private/tmp"),
    ]

    func testLiveSharePathsAreDefaultOffAndRoundTrip() throws {
        XCTAssertEqual(MorbConfig().liveSharePaths, [])

        var config = MorbConfig()
        config.liveSharePaths = ["/Users/me/work/project"]
        XCTAssertEqual(try MorbConfig.parse(config.toTOML()), config)
    }

    func testPlanRequiresANarrowDescendantOfAnActualShare() throws {
        let plan = try MorbLiveShareBridge.plan(
            paths: ["/Users/me/work/project", "/tmp/morb-project"],
            shares: shares)
        XCTAssertEqual(plan.roots.map(\.path), ["/Users/me/work/project", "/private/tmp/morb-project"])
        XCTAssertEqual(plan.roots.map(\.backingSharePath), ["/Users", "/private/tmp"])

        XCTAssertThrowsError(
            try MorbLiveShareBridge.plan(paths: ["/Users"], shares: shares),
            "the default VirtioFS root must never become a broad FSEvents root")
        XCTAssertThrowsError(
            try MorbLiveShareBridge.plan(paths: ["/opt/project"], shares: shares),
            "a path outside the running share plan cannot leak into a future watcher")
    }

    func testPlanRejectsOverlappingProjectAuthoritiesBeforeOpeningATransport() {
        XCTAssertThrowsError(
            try MorbLiveShareBridge.plan(
                paths: ["/Users/me/project", "/Users/me/project/Sources"],
                shares: shares)
        ) { error in
            XCTAssertTrue("\(error)".contains("overlap"))
        }
    }

    func testExactGuestAdvertisementIsRequiredBeforeConfigurationCanAwaitASession() throws {
        let exact = MorbLiveShareBridge.GuestAdvertisement(
            wireCapability: "ready", contractVersion: MorbLiveShareBridge.contractVersion)
        let pending = MorbLiveShareBridge.diagnose(
            paths: ["/Users/me/project"],
            shares: shares,
            guestShareStates: ["/Users": .mounted],
            guestAdvertisement: exact)
        XCTAssertEqual(pending.state, .waitingForSession)
        XCTAssertFalse(pending.isActive, "configuration and capability are not an authenticated session")

        let omittedVersion = MorbLiveShareBridge.GuestAdvertisement(
            wireCapability: "ready", contractVersion: nil)
        XCTAssertEqual(
            MorbLiveShareBridge.DeliveryAdmission.evaluate(omittedVersion),
            .unsupportedContractVersion(actual: nil))

        let newerVersion = MorbLiveShareBridge.GuestAdvertisement(
            wireCapability: "ready", contractVersion: MorbLiveShareBridge.contractVersion + 1)
        XCTAssertEqual(
            MorbLiveShareBridge.DeliveryAdmission.evaluate(newerVersion),
            .unsupportedContractVersion(actual: MorbLiveShareBridge.contractVersion + 1))

        let waitingForMount = MorbLiveShareBridge.diagnose(
            paths: ["/Users/me/project"],
            shares: shares,
            guestShareStates: [:],
            guestAdvertisement: exact)
        XCTAssertEqual(waitingForMount.state, .waitingForGuestMount)
        XCTAssertFalse(waitingForMount.isActive)
    }

    func testTransportClaimsAreBoundToTheExactNarrowPlan() throws {
        let plan = try MorbLiveShareBridge.plan(paths: ["/Users/me/project"], shares: shares)
        let claims = try MorbLiveShareTransport.makeWireClaims(
            plan: plan, shares: shares, epoch: 41)

        XCTAssertEqual(claims.count, 1)
        XCTAssertTrue(claims[0].rootID.hasPrefix("root_"))
        XCTAssertEqual(claims[0].tag, "morbshare0")
        XCTAssertEqual(claims[0].rootPath, "/Users/me/project")
        XCTAssertEqual(claims[0].backingPath, "/Users")
        XCTAssertFalse(claims[0].readOnly)
        XCTAssertEqual(claims[0].epoch, 41)
        XCTAssertThrowsError(
            try MorbLiveShareTransport.makeWireClaims(plan: plan, shares: shares, epoch: 0))
    }

    func testFSEventsMustScanBecomesARootRescan() throws {
        let plan = try MorbLiveShareBridge.plan(paths: ["/Users/me/project"], shares: shares)
        let buffer = MorbLiveShareBridge.EventBuffer(plan: plan, capacity: 1)

        XCTAssertEqual(
            buffer.recordFSEvent(
                sourceEventID: 41,
                path: "/Users/me/project/src",
                flags: MorbLiveShareBridge.FSEventFlag.mustScanSubdirectories),
            .rescanQueued)
        XCTAssertEqual(
            buffer.drain(),
            [
                MorbLiveShareBridge.Event(
                    sourceEventID: 41,
                    rootPath: "/Users/me/project",
                    path: "/Users/me/project",
                    kind: .rescan,
                    rescanReason: .fseventsMustScanSubdirectories),
            ])
    }

    func testQueueOverflowReplacesIncrementalRecordsWithBoundedRescans() throws {
        let plan = try MorbLiveShareBridge.plan(
            paths: ["/Users/me/a", "/Users/me/b"], shares: shares)
        let buffer = MorbLiveShareBridge.EventBuffer(plan: plan, capacity: 2)

        XCTAssertEqual(buffer.recordFSEvent(sourceEventID: 1, path: "/Users/me/a/a.swift", flags: 0), .enqueued)
        XCTAssertEqual(buffer.recordFSEvent(sourceEventID: 2, path: "/Users/me/a/b.swift", flags: 0), .enqueued)
        XCTAssertEqual(
            buffer.recordFSEvent(
                sourceEventID: 3,
                path: "/Users/me/b",
                flags: MorbLiveShareBridge.FSEventFlag.mustScanSubdirectories),
            .rescanQueued)

        let delivered = buffer.drain()
        XCTAssertEqual(delivered.count, 2)
        XCTAssertEqual(Set(delivered.map(\.rootPath)), Set(["/Users/me/a", "/Users/me/b"]))
        XCTAssertTrue(delivered.allSatisfy { $0.kind == .rescan && $0.rescanReason == .queueOverflow })
    }

    func testDroppedFSEventsRequireEverySelectedRootToRescan() throws {
        let plan = try MorbLiveShareBridge.plan(
            paths: ["/Users/me/a", "/Users/me/b"], shares: shares)
        let buffer = MorbLiveShareBridge.EventBuffer(plan: plan, capacity: 2)

        XCTAssertEqual(
            buffer.recordFSEvent(
                sourceEventID: 99,
                path: "/",
                flags: MorbLiveShareBridge.FSEventFlag.kernelDropped),
            .rescanQueued)
        let delivered = buffer.drain()
        XCTAssertEqual(delivered.count, 2)
        XCTAssertTrue(delivered.allSatisfy { $0.rescanReason == .fseventsDropped })
    }

    func testDiagnosticDoesNotClaimDeliveryWhenGuestSaysUnavailable() throws {
        let diagnostic = MorbLiveShareBridge.diagnose(
            paths: ["/Users/me/project"],
            shares: shares,
            guestShareStates: ["/Users": .mounted],
            guestCapability: .unavailable)
        XCTAssertEqual(diagnostic.state, .deliveryUnavailable)
        XCTAssertFalse(diagnostic.isActive)
        XCTAssertTrue(diagnostic.detail.contains("no inotify injection endpoint"))
    }

    func testDisabledDiagnosticExplainsTheNarrowConfigAndRestartBoundary() {
        let diagnostic = MorbLiveShareBridge.diagnose(
            paths: [],
            shares: shares,
            guestShareStates: [:],
            guestAdvertisement: .init(wireCapability: nil, contractVersion: nil))

        XCTAssertEqual(diagnostic.state, .disabled)
        XCTAssertFalse(diagnostic.isActive)
        XCTAssertTrue(diagnostic.detail.contains("live_share_paths"))
        XCTAssertTrue(diagnostic.detail.contains("restart"))
    }
}
