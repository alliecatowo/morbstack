// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Foundation
import XCTest

@testable import MorbstackAppCore

final class BuildxHistoryLogExportTests: XCTestCase {

    private let capturedAt = Date(timeIntervalSince1970: 1_772_000_000)

    private var record: BuildxHistoryRecord {
        BuildxHistoryRecord(
            id: "qu2gsuo8ejqrwdfii23xkkckt",
            name: "team/api",
            status: "Completed",
            createdAt: capturedAt,
            duration: "4.2s")
    }

    func testPreservesExactlyLoadedOutputAndDisclosesTruncationScope() {
        let output = "{\"id\":\"load\",\"status\":\"START\"}\n{\"id\":\"load\",\"status\":\"COMPLETE\"}\n"
        let document = BuildHistoryLogExport.document(
            log: BuildxHistoryLog(output: output, isTruncated: true),
            record: record,
            capturedAt: capturedAt)

        XCTAssertTrue(document.text.contains("# Build record: team/api (qu2gsuo8ejqrwdfii23xkkckt)"))
        XCTAssertTrue(document.text.contains("# Log filter: none; the history-table search does not filter this loaded transcript."))
        XCTAssertTrue(document.text.contains("# Retention: Morbstack retained the first 4 MB of Buildx stdout; later output was dropped."))
        XCTAssertTrue(document.text.contains("# Scope: this is retained output for one Buildx history record, not complete builder, Docker, CI, or build history. Saving did not rerun Buildx or fetch more output."))
        XCTAssertTrue(document.text.hasSuffix(output), "The retained Buildx text must not be reformatted or re-fetched while saving.")
        XCTAssertEqual(document.data, Data(document.text.utf8))
        XCTAssertTrue(document.suggestedFilename.hasSuffix(".log"))
        XCTAssertFalse(document.suggestedFilename.contains("/"))
        XCTAssertTrue(document.panelMessage.contains("does not rerun Buildx"))
    }

    func testUntruncatedDocumentDoesNotClaimCompleteBuildHistory() {
        let document = BuildHistoryLogExport.document(
            log: BuildxHistoryLog(output: "plain output\n", isTruncated: false),
            record: record,
            capturedAt: capturedAt)

        XCTAssertTrue(document.text.contains("Buildx stdout stayed within Morbstack’s 4 MB retained-text limit."))
        XCTAssertTrue(document.text.contains("not complete builder, Docker, CI, or build history"))
        XCTAssertTrue(document.text.hasSuffix("plain output\n"))
    }
}
