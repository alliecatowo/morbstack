// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import XCTest

@testable import MorbstackKit

/// Regression coverage for the competing-Docker-socket warning in `morb doctor`.
/// These stay pure: a test must never inspect, create, or replace a developer's real
/// `~/.docker` socket while establishing the exact Testcontainers migration hazard.
final class DoctorDiscoveryTests: XCTestCase {

    func testRootlessCandidatesCoverTheDockerDesktopAndLegacyLocations() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        XCTAssertEqual(
            Doctor.rootlessDockerSocketCandidates(homeDirectory: home),
            [
                "/Users/example/.docker/run/docker.sock",
                "/Users/example/.docker/desktop/docker.sock",
            ])
    }

    func testExistingDesktopSocketIsReportedAsACompetingDiscoveryEndpoint() {
        let morbstack = "/Users/example/.morbstack/run/docker.sock"
        let desktop = "/Users/example/.docker/run/docker.sock"
        let conflicts = Doctor.dockerAutoDiscoveryConflicts(
            morbstackSocketPath: morbstack,
            candidates: [desktop, "/Users/example/.docker/desktop/docker.sock"],
            fileExists: { $0 == desktop },
            canonicalPath: { $0 })

        XCTAssertEqual(conflicts, [desktop])
    }

    func testSymlinkToMorbstackIsNotReportedAsACompetingSocket() {
        let morbstack = "/Users/example/.morbstack/run/docker.sock"
        let discoverySocket = "/Users/example/.docker/run/docker.sock"
        let conflicts = Doctor.dockerAutoDiscoveryConflicts(
            morbstackSocketPath: morbstack,
            candidates: [discoverySocket],
            fileExists: { $0 == discoverySocket },
            canonicalPath: { path in path == discoverySocket ? morbstack : path })

        XCTAssertTrue(conflicts.isEmpty)
    }

    func testMissingCandidatesDoNotProduceAConflict() {
        let conflicts = Doctor.dockerAutoDiscoveryConflicts(
            morbstackSocketPath: "/Users/example/.morbstack/run/docker.sock",
            candidates: ["/Users/example/.docker/run/docker.sock"],
            fileExists: { _ in false },
            canonicalPath: { $0 })

        XCTAssertTrue(conflicts.isEmpty)
    }
}
