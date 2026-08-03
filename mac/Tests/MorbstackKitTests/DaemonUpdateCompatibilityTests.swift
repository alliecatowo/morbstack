// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import XCTest

@testable import MorbstackKit

/// Update continuity must remain a pure interpretation of a daemon reply. The
/// application and CLI own transport; this suite pins that neither path needs to
/// start, stop, or register anything merely to explain an old daemon.
final class DaemonUpdateCompatibilityTests: XCTestCase {

    private let request = DaemonRequest(cmd: "k8s-diagnose")

    func testRecognizesStructuredUnknownCommandForKnownAdditiveCommand() {
        let requirement = DaemonUpdateCompatibility.restartRequirement(
            for: request,
            rejectedBy: .unknownCommand(request.cmd),
            daemonVersion: "0.1.0-m0")

        XCTAssertEqual(requirement?.command, request.cmd)
        XCTAssertEqual(requirement?.feature, "Kubernetes diagnosis")
        XCTAssertTrue(requirement?.message.contains("Restart Morbstack") == true)
        XCTAssertTrue(requirement?.message.contains("did not start, stop, or change the engine") == true)
        XCTAssertEqual(requirement?.response.errorCode, DaemonResponse.ErrorCode.restartRequired.rawValue)
    }

    func testRecognizesOnlyCanonicalLegacyUnknownCommand() {
        let legacyDaemon = DaemonResponse(
            ok: false,
            error: "unknown command `k8s-diagnose`")
        let requirement = DaemonUpdateCompatibility.restartRequirement(
            for: request,
            rejectedBy: legacyDaemon)

        XCTAssertNotNil(requirement)
    }

    func testDoesNotInterpretOtherDaemonErrorsOrCommands() {
        XCTAssertNil(DaemonUpdateCompatibility.restartRequirement(
            for: request,
            rejectedBy: .failure("the VM is stopped")))
        XCTAssertNil(DaemonUpdateCompatibility.restartRequirement(
            for: DaemonRequest(cmd: "future-command"),
            rejectedBy: .unknownCommand("future-command")))
        XCTAssertNil(DaemonUpdateCompatibility.restartRequirement(
            for: request,
            rejectedBy: .failure("unknown Kubernetes command `k8s-diagnose`")))
    }
}
