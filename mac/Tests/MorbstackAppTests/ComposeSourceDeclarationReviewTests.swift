// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import XCTest

@testable import MorbstackAppCore

final class ComposeSourceDeclarationReviewTests: XCTestCase {

    func testEnvironmentReviewKeepsDraftProvenanceAndRedactsSensitiveValues() {
        let review = ComposeSourceDeclarationReview(
            sourceURL: URL(fileURLWithPath: "/Projects/demo/.env"),
            sourceKind: .projectEnvironment,
            text: """
            PORT=8080
            API_TOKEN=do-not-display
            """,
            isEditorDraft: true)

        XCTAssertEqual(review.provenance, .editorDraft)
        XCTAssertEqual(review.inspection.environmentDeclarations.map(\.key), ["PORT", "API_TOKEN"])
        XCTAssertEqual(review.inspection.environmentDeclarations.map(\.valueDisposition), [.set, .redacted])
        XCTAssertTrue(review.inspection.environmentDeclarations[1].isPotentiallySensitive)
    }

    func testComposeReviewReportsDeclaredSourcesWithoutResolvingThem() {
        let review = ComposeSourceDeclarationReview(
            sourceURL: URL(fileURLWithPath: "/Projects/demo/compose.yaml"),
            sourceKind: .composeYAML,
            text: """
            services:
              app:
                environment:
                  API_TOKEN: do-not-display
                env_file: ./runtime.env
                secrets:
                  - database_password
            secrets:
              database_password:
                file: ./database-password.txt
            """,
            isEditorDraft: false)

        XCTAssertEqual(review.provenance, .selectedFileSnapshot)
        XCTAssertEqual(review.inspection.serviceEnvironmentDeclarations.map(\.key), ["API_TOKEN"])
        XCTAssertEqual(review.inspection.serviceEnvironmentDeclarations.map(\.valueSource), [.declaredInSource])
        XCTAssertEqual(review.inspection.environmentFileDeclarations.map(\.path), ["./runtime.env"])
        XCTAssertEqual(review.inspection.secretDeclarations.map(\.source), [.file(path: "./database-password.txt")])
        XCTAssertEqual(review.inspection.secretGrants.map(\.secretName), ["database_password"])
    }
}
