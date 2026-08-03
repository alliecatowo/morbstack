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

    func testComposeInspectionReportsSourceMetadataWithoutEvaluatingValues() {
        let inspection = ComposeProjectSourceInspection.inspect(
            text: """
            name: demo
            services:
              app:
                image: "example:${IMAGE}:${TAG:-latest}"
                environment:
                  PORT: "8080"
                  API_TOKEN:
                env_file:
                  - path: ./base.env
                    required: true
                    format: raw
                  - ./override.env
                secrets:
                  - database_password
                  - source: external_api
                    target: /run/project-api
            secrets:
              database_password:
                file: ./database-password.txt
              external_api:
                external: true
              project_token:
                environment: OAUTH_TOKEN
            """,
            sourceKind: .composeYAML)

        XCTAssertEqual(inspection.environmentDeclarations, [])
        XCTAssertEqual(
            inspection.serviceEnvironmentDeclarations.map { ($0.service, $0.key, $0.valueSource) },
            [("app", "PORT", .declaredInSource), ("app", "API_TOKEN", .requiresComposeResolution)])
        XCTAssertTrue(inspection.serviceEnvironmentDeclarations[1].isPotentiallySensitive)
        XCTAssertEqual(
            inspection.environmentFileDeclarations.map { ($0.service, $0.path, $0.required, $0.format) },
            [("app", "./base.env", true, "raw"), ("app", "./override.env", nil, nil)])
        XCTAssertEqual(inspection.interpolationReferences.map(\.name), ["IMAGE", "TAG"])
        XCTAssertEqual(inspection.secretDeclarations.map(\.name), ["database_password", "external_api", "project_token"])
        XCTAssertEqual(inspection.secretDeclarations[0].source, .file(path: "./database-password.txt"))
        XCTAssertEqual(inspection.secretDeclarations[1].source, .external)
        XCTAssertEqual(inspection.secretDeclarations[2].source, .environment(variable: "OAUTH_TOKEN"))
        XCTAssertEqual(
            inspection.secretGrants.map { ($0.service, $0.secretName, $0.syntax, $0.target) },
            [("app", "database_password", .short, nil), ("app", "external_api", .long, "/run/project-api")])
    }
}
