// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The status-footer warning chip, and the Settings row wording.
//
// Almost every test here asserts that the chip stays *hidden*. That is the hard part: a
// warning about unmounted shares is trivially easy to show and worth nothing if it is lit
// most of the time, because a chip that is usually on is furniture and stops being read.
// The two gates — a daemon must have said so, and the engine must be running — are what
// keep it meaningful, and they are what these tests defend.

import Foundation
import MorbstackKit
import XCTest

@testable import MorbstackAppCore

final class TrackEShareStatusTests: XCTestCase {

    // MARK: - Fixtures

    private func share(
        _ path: String,
        mounted: Bool,
        readOnly: Bool = false,
        configured: Bool = true,
        skippedReason: String? = nil,
        error: String? = nil
    ) -> MorbShareState {
        MorbShareState(
            path: path,
            tag: "morbshare0",
            readOnly: readOnly,
            configured: configured,
            mounted: mounted,
            skippedReason: skippedReason,
            error: error)
    }

    private func report(
        _ shares: [MorbShareState],
        source: MorbShareSurface.Source
    ) -> MorbShareSurface.Report {
        MorbShareSurface.Report(shares: shares, source: source)
    }

    // MARK: - When the chip stays hidden

    func testNoChipWhenEverythingIsMounted() {
        let live = report([share("/Users", mounted: true)], source: .daemon)
        XCTAssertNil(TrackEShareStatus.chip(live, engineRunning: true))
    }

    /// A stopped VM has nothing mounted. That is correct, uninteresting, and the state
    /// the app spends most of its life in.
    func testNoChipWhenTheEngineIsNotRunning() {
        let live = report([share("/Users", mounted: false)], source: .daemon)
        XCTAssertNil(TrackEShareStatus.chip(live, engineRunning: false))
    }

    /// Rows reconstructed from `config.toml` report every root as unmounted because
    /// nobody asked the guest. Warning on those would light the chip on a perfectly
    /// healthy machine that simply has no daemon yet.
    func testNoChipWhenTheRowsCameFromTheConfigFile() {
        let configOnly = report([share("/Users", mounted: false)], source: .config)
        XCTAssertNil(TrackEShareStatus.chip(configOnly, engineRunning: true))
        XCTAssertFalse(configOnly.hasWarning)
    }

    func testNoChipWhenNothingIsConfigured() {
        XCTAssertNil(TrackEShareStatus.chip(report([], source: .daemon), engineRunning: true))
    }

    /// A root the guest mounted that the config no longer lists is not degraded — it is
    /// working, just stale. It is worth showing in Settings, not worth a warning.
    func testNoChipForAnUnconfiguredButMountedRoot() {
        let live = report([share("/Users", mounted: true, configured: false)], source: .daemon)
        XCTAssertNil(TrackEShareStatus.chip(live, engineRunning: true))
    }

    // MARK: - When the chip appears

    func testChipAppearsForOneDegradedRoot() {
        let live = report(
            [share("/Users", mounted: true), share("/Volumes", mounted: false)],
            source: .daemon)
        let chip = TrackEShareStatus.chip(live, engineRunning: true)

        XCTAssertEqual(chip?.text, "1 folder not shared")
        XCTAssertEqual(chip?.tone, .warn)
        XCTAssertTrue(chip?.detail.contains("/Volumes") ?? false)
        XCTAssertFalse(chip?.detail.contains("/Users") ?? true, "a healthy root must not be listed")
    }

    func testChipPluralisesAndListsEveryDegradedRoot() {
        let live = report(
            [share("/Users", mounted: false), share("/Volumes", mounted: false)],
            source: .daemon)
        let chip = TrackEShareStatus.chip(live, engineRunning: true)

        XCTAssertEqual(chip?.text, "2 folders not shared")
        XCTAssertTrue(chip?.detail.contains("/Users") ?? false)
        XCTAssertTrue(chip?.detail.contains("/Volumes") ?? false)
    }

    /// The remedies differ completely — a `/Volumes` that does not exist versus a
    /// virtiofs mount that failed — so the per-root reason has to reach the tooltip.
    func testChipCarriesThePerRootReason() {
        let live = report(
            [share("/Volumes", mounted: false, skippedReason: "no such directory")],
            source: .daemon)
        let chip = TrackEShareStatus.chip(live, engineRunning: true)
        XCTAssertTrue(chip?.detail.contains("no such directory") ?? false)
    }

    func testChipExplainsTheSilentFailure() {
        let live = report([share("/Users", mounted: false)], source: .daemon)
        let chip = TrackEShareStatus.chip(live, engineRunning: true)
        // The sentence that makes the chip worth clicking: an empty directory, not an error.
        XCTAssertTrue(chip?.detail.contains("empty directory") ?? false)
    }

    // MARK: - Bind-mount judgement

    /// Judging a container's bind mount against a config-file reconstruction would flag
    /// working mounts as broken whenever the running VM predates a config edit.
    func testBindMountsAreOnlyJudgedAgainstALiveAnswer() {
        XCTAssertTrue(TrackEShareStatus.canJudgeBindMounts(report([], source: .daemon)))
        XCTAssertFalse(TrackEShareStatus.canJudgeBindMounts(report([], source: .config)))
    }

    // MARK: - Settings row wording

    func testMountedRowIsGood() {
        let (text, tone) = TrackEShareStatus.rowSummary(
            share("/Users", mounted: true), source: .daemon, engineRunning: true)
        XCTAssertEqual(text, "mounted")
        XCTAssertEqual(tone, .good)
    }

    func testMountedReadOnlyRowSaysSo() {
        let (text, tone) = TrackEShareStatus.rowSummary(
            share("/Users", mounted: true, readOnly: true), source: .daemon, engineRunning: true)
        XCTAssertEqual(text, "mounted, read-only")
        XCTAssertEqual(tone, .good)
    }

    /// "Not mounted because nothing is running" and "not mounted and something is wrong"
    /// are identical in the data and opposite in meaning. Only the second is a fault, and
    /// only the second gets a warning colour.
    func testStoppedEngineRowIsNeutralNotAWarning() {
        let (text, tone) = TrackEShareStatus.rowSummary(
            share("/Users", mounted: false), source: .config, engineRunning: false)
        XCTAssertTrue(text.contains("engine is not running"))
        XCTAssertEqual(tone, .neutral)
    }

    func testRunningEngineWithAnUnmountedRootIsAWarning() {
        let (text, tone) = TrackEShareStatus.rowSummary(
            share("/Users", mounted: false), source: .daemon, engineRunning: true)
        XCTAssertEqual(text, "not mounted")
        XCTAssertEqual(tone, .warn)
    }

    func testRowSummaryPrefersTheReasonWhenThereIsOne() {
        let (text, tone) = TrackEShareStatus.rowSummary(
            share("/Volumes", mounted: false, error: "virtiofs mount failed"),
            source: .daemon,
            engineRunning: true)
        XCTAssertTrue(text.contains("virtiofs mount failed"))
        XCTAssertEqual(tone, .warn)
    }

    /// A root the host planner skipped is reported even with the engine down: the reason
    /// is a host fact, and it is the same reason the guest will not have it next boot.
    func testSkippedRootIsExplainedEvenWithTheEngineStopped() {
        let (text, tone) = TrackEShareStatus.rowSummary(
            share("/nope", mounted: false, skippedReason: "does not exist"),
            source: .config,
            engineRunning: false)
        XCTAssertTrue(text.contains("does not exist"))
        XCTAssertEqual(tone, .warn)
    }

    func testStaleRootIsCalledOut() {
        let (text, tone) = TrackEShareStatus.rowSummary(
            share("/Users", mounted: true, configured: false),
            source: .daemon,
            engineRunning: true)
        XCTAssertTrue(text.contains("no longer listed"))
        XCTAssertEqual(tone, .warn)
    }

    // MARK: - Rosetta, before any daemon answers

    /// The guest has not been asked, so both guest facts stay `nil`. `false` here would
    /// make the Settings row report Rosetta broken on a machine whose only problem is a
    /// stopped engine, and send the user off to reinstall software they already have.
    func testLocalRosettaStateLeavesGuestFactsUnknown() {
        let state = TrackERosettaHost.localState(enabledInConfig: true)
        XCTAssertNil(state.activeInGuest)
        XCTAssertNil(state.binfmtRegistered)
        XCTAssertFalse(state.guestAnswered)
        XCTAssertFalse(state.isActive)
        XCTAssertFalse(state.isBrokenInGuest, "an unanswered guest is not a broken one")
    }

    func testLocalRosettaStateCarriesTheConfigIntent() {
        XCTAssertFalse(TrackERosettaHost.localState(enabledInConfig: false).enabledInConfig)
        XCTAssertTrue(TrackERosettaHost.localState(enabledInConfig: true).enabledInConfig)
    }

    /// The probe reads this machine, so the only stable assertion is internal
    /// consistency: nothing can be installed on a host that cannot support it.
    func testRosettaProbeIsSelfConsistent() {
        let (installed, supported) = TrackERosettaHost.probe()
        if installed { XCTAssertTrue(supported) }
    }
}
