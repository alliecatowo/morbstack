// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import XCTest

@testable import MorbstackAppCore

final class ComposeProjectOperationTests: XCTestCase {

    func testBringUpUsesReviewedNoBuildNoPullArguments() {
        XCTAssertEqual(
            ComposeProjectOperation.up.arguments,
            ["up", "--detach", "--no-build", "--pull", "never"])
    }

    func testBringUpReviewDisclosesThePossibleRecreateBoundary() {
        XCTAssertTrue(
            ComposeProjectOperation.up.effectDescription.contains(
                "recreate an existing service"))
    }

    func testStartUsesOnlyTheBoundedComposeStartCommand() {
        XCTAssertEqual(ComposeProjectOperation.start.arguments, ["start"])
        XCTAssertEqual(
            ComposeProjectOperation.start.commandDescription,
            "docker compose start")
        XCTAssertFalse(ComposeProjectOperation.start.isDestructive)
    }

    func testStopUsesOnlyTheBoundedComposeStopCommand() {
        XCTAssertEqual(ComposeProjectOperation.stop.arguments, ["stop"])
        XCTAssertEqual(
            ComposeProjectOperation.stop.commandDescription,
            "docker compose stop")
        XCTAssertTrue(
            ComposeProjectOperation.stop.effectDescription.contains(
                "without removing them"))
        XCTAssertFalse(ComposeProjectOperation.stop.isDestructive)
    }

    func testRestartDisclosesItsConfigurationBoundary() {
        XCTAssertEqual(ComposeProjectOperation.restart.arguments, ["restart"])
        XCTAssertEqual(
            ComposeProjectOperation.restart.commandDescription,
            "docker compose restart")
        XCTAssertTrue(
            ComposeProjectOperation.restart.effectDescription.contains(
                "not applied by restart"))
        XCTAssertFalse(ComposeProjectOperation.restart.isDestructive)
    }

    func testOnlyDocumentedProviderCommandsShowTheProviderRisk() {
        XCTAssertTrue(ComposeProjectOperation.up.mayRunProvider)
        XCTAssertTrue(ComposeProjectOperation.stop.mayRunProvider)
        XCTAssertTrue(ComposeProjectOperation.down.mayRunProvider)
        XCTAssertFalse(ComposeProjectOperation.build.mayRunProvider)
        XCTAssertFalse(ComposeProjectOperation.start.mayRunProvider)
        XCTAssertFalse(ComposeProjectOperation.restart.mayRunProvider)
    }
}
