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
}
