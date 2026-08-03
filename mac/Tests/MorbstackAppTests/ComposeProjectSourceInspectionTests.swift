// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import XCTest

@testable import MorbstackAppCore

final class ComposeProjectSourceInspectionTests: XCTestCase {

    func testEnvironmentInspectionReportsNamesAndRedactsPotentialSecrets() {
        let inspection = ComposeProjectSourceInspection.inspect(
            text: """
            PORT=8080
            API_TOKEN=not-for-display
            EMPTY=
            export FEATURE_FLAG=true
            not an assignment
            """,
            sourceKind: .projectEnvironment)

        XCTAssertEqual(inspection.secretDeclarations, [])
        XCTAssertEqual(
            inspection.environmentDeclarations.map(\.key),
            ["PORT", "API_TOKEN", "EMPTY", "FEATURE_FLAG"])
        XCTAssertEqual(inspection.environmentDeclarations.map(\.line), [1, 2, 3, 4])
        XCTAssertEqual(inspection.environmentDeclarations[0].valueDisposition, .set)
        XCTAssertEqual(inspection.environmentDeclarations[1].valueDisposition, .redacted)
        XCTAssertTrue(inspection.environmentDeclarations[1].isPotentiallySensitive)
        XCTAssertEqual(inspection.environmentDeclarations[2].valueDisposition, .empty)
    }

    func testComposeInspectionOnlyRecognizesTopLevelBlockSecretNames() {
        let inspection = ComposeProjectSourceInspection.inspect(
            text: """
            name: demo
            secrets:
              database_password:
                file: ./database-password.txt
              external_api:
                external: true
            services:
              app:
                secrets:
                  - database_password
            """,
            sourceKind: .composeYAML)

        XCTAssertEqual(inspection.environmentDeclarations, [])
        XCTAssertEqual(inspection.secretDeclarations.map(\.name), ["database_password", "external_api"])
        XCTAssertEqual(inspection.secretDeclarations.map(\.line), [3, 5])
    }
}
