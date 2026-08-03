// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import XCTest

@testable import MorbstackKit

/// Which `morb` subcommands may conjure a daemon out of nothing.
///
/// These are regression tests for a real confusion from the M1 functional gate
/// run: `morb stop` used to auto-start a daemon in order to stop it, so every
/// `pkill morbstackd` was followed seconds later by a fresh daemon, and the
/// obvious (wrong) conclusion was that another operator was relaunching it.
final class CommandPolicyTests: XCTestCase {

    func testStopNeverStartsADaemon() {
        // The headline case. Starting a process so that it can be told to stop
        // is not a defensible reading of any user's intent.
        XCTAssertFalse(MorbCommandPolicy.mayAutoStartDaemon("stop"))
    }

    func testStatusNeverStartsADaemon() {
        // `status` must be safe to poll. If asking changes the answer, every
        // monitoring script silently becomes a daemon launcher.
        XCTAssertFalse(MorbCommandPolicy.mayAutoStartDaemon("status"))
    }

    func testSuspendNeverStartsADaemon() {
        XCTAssertFalse(MorbCommandPolicy.mayAutoStartDaemon("suspend"))
    }

    func testStartAndResumeMayStartADaemon() {
        // Both exist to end up with a running VM, so bringing the daemon up is
        // the whole point rather than a side effect.
        XCTAssertTrue(MorbCommandPolicy.mayAutoStartDaemon("start"))
        XCTAssertTrue(MorbCommandPolicy.mayAutoStartDaemon("resume"))
    }

    func testUnknownCommandsDoNotStartADaemon() {
        // Fail closed: a typo, or a command added later without thinking about
        // this policy, must not inherit the power to spawn processes.
        XCTAssertFalse(MorbCommandPolicy.mayAutoStartDaemon("version"))
        XCTAssertFalse(MorbCommandPolicy.mayAutoStartDaemon("doctor"))
        XCTAssertFalse(MorbCommandPolicy.mayAutoStartDaemon(""))
        XCTAssertFalse(MorbCommandPolicy.mayAutoStartDaemon("sotp"))
    }

    /// Neither Rosetta command may bring a daemon (and therefore a VM) up.
    ///
    /// `rosetta` is an observation — asking whether amd64 translation is available
    /// must not be the thing that boots a VM, for the same reason `status` must not.
    /// `rosetta_install` is worse: it is mutating and interactive, it puts Apple's
    /// own system installation dialog on screen, and a daemon conjured to service it
    /// would be a background process making the OS ask the user to install a system
    /// component.
    ///
    /// Both currently get this for free — `mayAutoStartDaemon` fails closed for
    /// anything outside `autoStartingCommands` — so this test is here to make that
    /// *stay* true: it is the thing that fails if somebody widens that set later.
    func testRosettaCommandsNeverStartADaemon() {
        XCTAssertFalse(MorbCommandPolicy.mayAutoStartDaemon("rosetta"))
        XCTAssertFalse(MorbCommandPolicy.mayAutoStartDaemon("rosetta_install"))
        XCTAssertFalse(MorbCommandPolicy.autoStartingCommands.contains("rosetta"))
        XCTAssertFalse(MorbCommandPolicy.autoStartingCommands.contains("rosetta_install"))
    }

    /// `reset-disk` deletes the Docker data disk. A daemon spawned to answer it would
    /// open that disk on the way up, which is the one thing this command must never
    /// cause — and it refuses to run against a live VM anyway, so a daemon it started
    /// itself would just make it refuse.
    func testResetDiskNeverStartsADaemon() {
        XCTAssertFalse(MorbCommandPolicy.mayAutoStartDaemon("reset-disk"))
        XCTAssertTrue(MorbCommandPolicy.selfServedCommands.contains("reset-disk"))
    }

    /// `doctor` exists to diagnose a host on which the daemon may be the broken part.
    func testDoctorNeverStartsADaemon() {
        XCTAssertFalse(MorbCommandPolicy.mayAutoStartDaemon("doctor"))
        XCTAssertTrue(MorbCommandPolicy.selfServedCommands.contains("doctor"))
    }

    /// The two lists must not overlap: a command cannot be both self-served and
    /// allowed to spawn a daemon, and the predicate would silently pick a winner.
    func testTheSelfServedAndAutoStartingListsAreDisjoint() {
        XCTAssertTrue(
            MorbCommandPolicy.selfServedCommands
                .isDisjoint(with: MorbCommandPolicy.autoStartingCommands))
    }

    func testTheAllowListIsExactlyTheCommandsThatAskForAnEngine() {
        // Pinning the set itself, not just the predicate: adding a command to
        // the allow-list should be a deliberate act that breaks this test and
        // makes someone justify it.
        //
        // The justification for each of the four: `start` and `resume` exist to
        // make the engine available, and `k8s-enable` asks for a cluster, which
        // is asking for the engine it runs on — refusing to start one would make
        // it fail with "the VM is stopped" every time from a cold machine. The
        // other `k8s-*` commands are observations and are deliberately absent.
        // `disk-grow` is an explicit state-changing request that ends in its own
        // proof-only VM boot (Daemon.swift routes it through the same
        // `awaitVMOperation` path as `start`), so it too is asking for an engine
        // rather than merely observing one. `disk status` stays a local
        // observation and is deliberately absent.
        XCTAssertEqual(
            MorbCommandPolicy.autoStartingCommands,
            ["start", "resume", "k8s-enable", "disk-grow"])
    }
}
