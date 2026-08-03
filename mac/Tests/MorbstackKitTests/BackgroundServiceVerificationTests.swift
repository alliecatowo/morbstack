// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import XCTest

@testable import MorbstackKit

/// A Login Items authorization and a reachable windowless Docker host are separate
/// facts. Keep that distinction in the pure verification layer so the first-run
/// sheet and `morb service enable` cannot accidentally present registration alone as
/// app-window independence.
final class BackgroundServiceVerificationTests: XCTestCase {

    func testRespondingEnabledServicePassesReadinessCheck() {
        let check = MorbSetupVerification.backgroundServiceCheck(status(
            registration: .enabled,
            socketState: .responding))

        XCTAssertEqual(check.status, .pass)
        XCTAssertTrue(check.detail.contains("control socket is responding"))
    }

    func testUnprobedEnabledServiceIsNotReportedAsReady() {
        let check = MorbSetupVerification.backgroundServiceCheck(status(
            registration: .enabled,
            socketState: .notChecked))

        XCTAssertEqual(check.status, .info)
        XCTAssertTrue(check.detail.contains("did not check"))
    }

    func testUnreachableEnabledServiceWarnsBeforeWindowlessUse() {
        for socketState in [
            MorbBackgroundService.ControlSocketState.missing,
            .unresponsive,
        ] {
            let check = MorbSetupVerification.backgroundServiceCheck(status(
                registration: .enabled,
                socketState: socketState))

            XCTAssertEqual(check.status, .warning)
            XCTAssertTrue(check.detail.contains("before relying on Docker with no app window"))
        }
    }

    private func status(
        registration: MorbBackgroundService.Registration,
        socketState: MorbBackgroundService.ControlSocketState
    ) -> MorbBackgroundService.Status {
        MorbBackgroundService.Status(
            registration: registration,
            plistPath: "/Applications/Morbstack.app/Contents/Library/LaunchAgents/dev.morbstack.daemon.plist",
            controlSocketPath: "/Users/example/.morbstack/run/morbstackd.sock",
            controlSocketPresent: socketState != .missing,
            controlSocketState: socketState,
            diagnostic: "enabled for this signed-in user")
    }
}
