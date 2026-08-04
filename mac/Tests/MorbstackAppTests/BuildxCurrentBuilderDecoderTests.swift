// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Foundation
import XCTest

@testable import MorbstackAppCore

/// The current-builder command has no JSON mode. These fixtures cover only the
/// documented labels we render, so an unfamiliar Buildx format fails unavailable
/// instead of becoming an invented builder state.
final class BuildxCurrentBuilderDecoderTests: XCTestCase {

    func testDecodesCurrentBuilderAndLiteralNodeState() throws {
        let builder = try BuildxHistoryClient.decodeCurrentBuilder(Data("""
        Name:          morbstack
        Driver:        docker
        Last Activity: 2026-08-03 12:34:56 +0000 UTC

        Nodes:
        Name:      morbstack
        Endpoint:  default
        Status:    running
        BuildKit:  v0.32.0
        Platforms: linux/arm64
        """.utf8))

        XCTAssertEqual(builder.name, "morbstack")
        XCTAssertEqual(builder.driver, "docker")
        XCTAssertEqual(builder.lastActivity, "2026-08-03 12:34:56 +0000 UTC")
        XCTAssertEqual(builder.nodes.count, 1)
        XCTAssertEqual(builder.nodes.first?.endpoint, "default")
        XCTAssertEqual(builder.nodes.first?.reportedFacts, "running · v0.32.0 · linux/arm64")
        XCTAssertEqual(builder.reportedNodeStatus, "running")
        XCTAssertEqual(builder.reportedBuildKitVersions, "v0.32.0")
        XCTAssertEqual(builder.reportedPlatforms, "linux/arm64")
    }

    func testPreservesMixedNodeStatesWithoutInventingAnOverallHealth() throws {
        let builder = try BuildxHistoryClient.decodeCurrentBuilder(Data("""
        Name:   multiarch
        Driver: docker-container
        Nodes:
        Name:      multiarch0
        Endpoint:  unix:///var/run/docker.sock
        Status:    running
        BuildKit:  v0.32.0
        Platforms: linux/arm64
        Name:      multiarch1
        Endpoint:  ssh://builder.example.invalid
        Status:    inactive
        Error:     context deadline exceeded
        Platforms: linux/amd64
        """.utf8))

        XCTAssertEqual(builder.nodes.map(\.name), ["multiarch0", "multiarch1"])
        XCTAssertEqual(builder.reportedNodeStatus, "running, inactive")
        XCTAssertEqual(builder.nodes.last?.error, "context deadline exceeded")
        XCTAssertEqual(builder.reportedPlatforms, "linux/arm64, linux/amd64")
    }

    func testRejectsInspectionWithoutAReportedBuilderName() {
        XCTAssertThrowsError(
            try BuildxHistoryClient.decodeCurrentBuilder(Data("Status: running\n".utf8)))
    }
}
