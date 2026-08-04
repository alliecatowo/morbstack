// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import XCTest

@testable import MorbstackAppCore

final class BuildxBuilderSelectionTests: XCTestCase {

    func testDefaultBuilderRecoveryDoesNotBroadenBuildxScope() {
        XCTAssertEqual(
            BuildxHistoryClient.morbstackDefaultBuilderArguments,
            ["buildx", "use", "default"])
        XCTAssertFalse(BuildxHistoryClient.morbstackDefaultBuilderArguments.contains("--default"))
        XCTAssertFalse(BuildxHistoryClient.morbstackDefaultBuilderArguments.contains("--global"))
        XCTAssertFalse(BuildxHistoryClient.morbstackDefaultBuilderArguments.contains("--bootstrap"))
    }
}
