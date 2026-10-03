// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

// When "Open Terminal" is offered, and what it says when it is not.
//
// The three places the command appears — the toolbar's secondary-action item, the row's
// contextual menu, and the Container menu — all read the same two functions, so this
// file is the whole enablement contract. It also covers the sentence a terminal window
// shows once its session has ended, including the case that motivates the affordance's
// disabled state: the container stopping while a shell is open.

import Foundation
import XCTest

@testable import MorbstackAppCore

final class ContainerTerminalAvailabilityTests: XCTestCase {

    private func container(state: String, name: String = "pg-main") -> ContainerSummary {
        ContainerSummary(
            id: "c-\(name)",
            names: ["/\(name)"],
            displayName: name,
            image: "postgres:16",
            state: state,
            status: state.capitalized,
            composeProject: nil,
            composeService: nil,
            ports: [],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: Enablement

    func testOnlyARunningContainerCanBeExecInto() {
        XCTAssertTrue(ContainerTerminalAvailability.isAvailable(for: container(state: "running")))
        for state in ["exited", "created", "paused", "restarting", "dead", "removing", ""] {
            XCTAssertFalse(
                ContainerTerminalAvailability.isAvailable(for: container(state: state)),
                "\(state.isEmpty ? "<empty>" : state) must not offer a terminal")
        }
    }

    func testEachNonRunningStateGetsItsOwnReason() {
        XCTAssertEqual(ContainerTerminalAvailability.reason(for: container(state: "running")), .ready)
        XCTAssertEqual(ContainerTerminalAvailability.reason(for: container(state: "paused")), .paused)
        XCTAssertEqual(ContainerTerminalAvailability.reason(for: container(state: "restarting")), .restarting)
        XCTAssertEqual(ContainerTerminalAvailability.reason(for: container(state: "exited")), .notStarted)
        XCTAssertEqual(ContainerTerminalAvailability.reason(for: container(state: "created")), .notStarted)
        XCTAssertEqual(ContainerTerminalAvailability.reason(for: container(state: "dead")), .dead)
        XCTAssertEqual(
            ContainerTerminalAvailability.reason(for: container(state: "removing")),
            .indeterminate(state: "removing"))
    }

    /// A fixture window renders Docker-shaped records with no engine behind them, and a
    /// terminal opens a socket outside `DockerClient`. Offering it there would produce a
    /// window whose only possible outcome is a connection error.
    func testAFixtureWindowNeverOffersATerminalEvenForARunningRecord() {
        let running = container(state: "running")
        XCTAssertTrue(ContainerTerminalAvailability.isAvailable(for: running, permitsExternalOperations: true))
        XCTAssertFalse(ContainerTerminalAvailability.isAvailable(for: running, permitsExternalOperations: false))
        XCTAssertEqual(
            ContainerTerminalAvailability.reason(for: running, permitsExternalOperations: false),
            .fixtureWindow)
    }

    // MARK: Copy

    /// The register TASTE-4 and TASTE-6 set: when something is unavailable, say what the
    /// reader can do — not what our internal state is called.
    func testUnavailableCopyNamesTheRemedyAndNotOurState() {
        let paused = ContainerTerminalAvailability.helpText(for: container(state: "paused"))
        XCTAssertEqual(paused, "Unpause pg-main to open a terminal in it.")

        let exited = ContainerTerminalAvailability.helpText(for: container(state: "exited"))
        XCTAssertEqual(exited, "Start pg-main to open a terminal in it.")
    }

    /// `dead` is the state with no remedy: Docker documents it as unstartable, so the
    /// copy must not tell the reader to start it.
    func testDeadCopyOffersNoRemedyBecauseThereIsNone() {
        let text = ContainerTerminalAvailability.helpText(for: container(state: "dead"))
        XCTAssertTrue(text.contains("cannot be started again"), text)
        XCTAssertFalse(text.hasPrefix("Start "), "a dead container cannot be started; do not say so")
    }

    func testRunningCopyDescribesTheCommandRatherThanARemedy() {
        XCTAssertEqual(
            ContainerTerminalAvailability.helpText(for: container(state: "running")),
            "Open an interactive shell in pg-main")
    }

    func testEveryReasonProducesNonEmptyCopyThatNamesTheContainer() {
        for state in ["running", "paused", "restarting", "exited", "created", "dead", "removing"] {
            let text = ContainerTerminalAvailability.helpText(for: container(state: state))
            XCTAssertFalse(text.isEmpty, state)
            XCTAssertTrue(text.contains("pg-main"), "\(state): \(text)")
        }
    }

    /// An empty state string is a real shape — Docker's list endpoint can omit it — and
    /// it must not produce a sentence with a hole in it.
    func testAnEmptyStateStillReadsAsASentence() {
        let text = ContainerTerminalAvailability.helpText(for: container(state: ""))
        XCTAssertTrue(text.contains("in no reported state"), text)
        XCTAssertFalse(text.contains("“”"), text)
    }

    // MARK: The status line a finished session leaves behind

    func testEveryTerminationReasonHasItsOwnSentence() {
        XCTAssertEqual(ContainerTerminalStatus.text(for: .exited(code: 0)), "The shell exited.")
        XCTAssertEqual(ContainerTerminalStatus.text(for: .exited(code: 130)), "The shell exited with status 130.")
        XCTAssertEqual(
            ContainerTerminalStatus.text(for: .exited(code: nil)),
            "The session ended. Docker did not report an exit status.")
        XCTAssertEqual(
            ContainerTerminalStatus.text(for: .transportFailure("the engine closed the connection")),
            "the engine closed the connection")
    }

    /// The case the disabled affordance cannot prevent: the container stops while a
    /// shell is open. The session ends, the scrollback stays readable, and the one line
    /// at the bottom says both what happened and what would produce a working terminal.
    func testAContainerStoppingMidSessionSaysWhatHappenedAndWhatToDo() {
        let text = ContainerTerminalStatus.text(for: .containerStopped)
        XCTAssertEqual(text, "The container stopped, which ended this session. Start it again to open a new terminal.")
    }

    /// Closing the window is the one ending with nothing to say: the window is already
    /// going away, so a status line would be addressed to no one.
    func testClosingTheWindowProducesNoStatusLine() {
        XCTAssertNil(ContainerTerminalStatus.text(for: .closedByUser))
    }

    /// A transport failure surfaces the engine's own words. That string originates with
    /// dockerd, not with a container's stdout, but it still reaches an `NSTextField`, so
    /// this pins the fact that it is passed through verbatim and reviewed as such.
    func testTransportFailureIsPassedThroughVerbatim() {
        let message = "Container 7f3a is not running"
        XCTAssertEqual(ContainerTerminalStatus.text(for: .transportFailure(message)), message)
    }
}
