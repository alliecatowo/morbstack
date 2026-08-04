// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Coverage for the Settings screen's config handling.
//
// Two things are actually load-bearing here and neither of them is a view:
//
//   * the slider ↔ config mapping, including the `cpus = 0` sentinel — a slider that
//     silently converts "all cores" into "the eight this Mac happens to have today" is
//     a data-loss bug wearing a UI costume;
//   * the round trip. `~/.morbstack/config.toml` is hand-editable and shared with the
//     daemon and the CLI, so Settings writing it must not lose a key it does not show.
//
// Every test writes to its own temporary directory. Nothing here touches
// `~/.morbstack`, and nothing here talks to a running daemon.

import Foundation
import MorbstackKit
import XCTest

@testable import MorbstackAppCore

final class TrackDCommandLineToolsStatusTests: XCTestCase {

    func testProcessSelectionNamesTheWinningDockerSourceWithoutLeakingDockerHost() {
        XCTAssertEqual(
            TrackDCommandLineToolsStatus.processSelectionSummary(
                for: .environmentContext("remote-builder")),
            "DOCKER_CONTEXT=remote-builder")
        XCTAssertEqual(
            TrackDCommandLineToolsStatus.processSelectionSummary(for: .dockerHost),
            "DOCKER_HOST")
        XCTAssertEqual(
            TrackDCommandLineToolsStatus.processSelectionSummary(for: .savedContext("morbstack")),
            "Saved context: morbstack")
    }
}

final class TrackDConfigEditorTests: XCTestCase {

    private let limits = TrackDResourceLimits(hostCores: 8, hostMemoryGiB: 16)

    // MARK: - CPU

    func testSentinelResolvesToHostCoresOnTheSlider() {
        var config = MorbConfig()
        config.cpus = 0
        XCTAssertEqual(TrackDConfigEditor.cpuSliderValue(config, limits: limits), 8)
        XCTAssertTrue(TrackDConfigEditor.isTrackingHostCores(config))
    }

    func testSliderShowsAnExplicitCoreCount() {
        var config = MorbConfig()
        config.cpus = 3
        XCTAssertEqual(TrackDConfigEditor.cpuSliderValue(config, limits: limits), 3)
        XCTAssertFalse(TrackDConfigEditor.isTrackingHostCores(config))
    }

    func testSliderClampsAConfigFromABiggerMachine() {
        var config = MorbConfig()
        config.cpus = 64
        XCTAssertEqual(TrackDConfigEditor.cpuSliderValue(config, limits: limits), 8)
    }

    func testApplyCPUWritesAnExplicitCountAndClamps() {
        var config = MorbConfig()
        TrackDConfigEditor.applyCPU(4.4, to: &config, limits: limits)
        XCTAssertEqual(config.cpus, 4)

        TrackDConfigEditor.applyCPU(99, to: &config, limits: limits)
        XCTAssertEqual(config.cpus, 8)

        TrackDConfigEditor.applyCPU(0, to: &config, limits: limits)
        XCTAssertEqual(config.cpus, 1, "the slider never means zero; zero is the sentinel")
    }

    func testMatchHostCoresRestoresTheSentinel() {
        var config = MorbConfig()
        config.cpus = 5
        TrackDConfigEditor.matchHostCores(&config)
        XCTAssertEqual(config.cpus, 0)
        XCTAssertTrue(TrackDConfigEditor.isTrackingHostCores(config))
    }

    // MARK: - Memory

    func testMemorySliderIsInGibibytes() {
        var config = MorbConfig()
        config.memoryMiB = 8192
        XCTAssertEqual(TrackDConfigEditor.memorySliderGiB(config, limits: limits), 8)
    }

    func testApplyMemoryRoundTripsThroughTheSlider() {
        var config = MorbConfig()
        TrackDConfigEditor.applyMemoryGiB(12, to: &config, limits: limits)
        XCTAssertEqual(config.memoryMiB, 12 * 1024)
        XCTAssertEqual(TrackDConfigEditor.memorySliderGiB(config, limits: limits), 12)
    }

    func testMemoryIsClampedToTheHostAndToTheFloor() {
        var config = MorbConfig()
        TrackDConfigEditor.applyMemoryGiB(512, to: &config, limits: limits)
        XCTAssertEqual(config.memoryMiB, 16 * 1024)

        TrackDConfigEditor.applyMemoryGiB(0, to: &config, limits: limits)
        XCTAssertEqual(config.memoryMiB, TrackDConfigEditor.minimumMemoryGiB * 1024)
    }

    // MARK: - Auto-suspend

    func testAutoSuspendClampsToItsRange() {
        var config = MorbConfig()
        TrackDConfigEditor.applyAutoSuspend(-5, to: &config)
        XCTAssertEqual(config.autoSuspendMinutes, 0)

        TrackDConfigEditor.applyAutoSuspend(600, to: &config)
        XCTAssertEqual(config.autoSuspendMinutes, TrackDConfigEditor.autoSuspendRange.upperBound)

        TrackDConfigEditor.applyAutoSuspend(15, to: &config)
        XCTAssertEqual(config.autoSuspendMinutes, 15)
        XCTAssertEqual(TrackDConfigEditor.describeSuspend(config), "15 min")

        TrackDConfigEditor.applyAutoSuspend(0, to: &config)
        XCTAssertEqual(TrackDConfigEditor.describeSuspend(config), "off")
    }

    // MARK: - Clamping

    func testClampedLeavesTheSentinelAlone() {
        var config = MorbConfig()
        config.cpus = 0
        XCTAssertEqual(TrackDConfigEditor.clamped(config, limits: limits).cpus, 0)
    }

    func testClampedBringsAnOversizedConfigInsideTheHost() {
        var config = MorbConfig()
        config.cpus = 32
        config.memoryMiB = 64 * 1024
        config.autoSuspendMinutes = 9999

        let clamped = TrackDConfigEditor.clamped(config, limits: limits)
        XCTAssertEqual(clamped.cpus, 8)
        XCTAssertEqual(clamped.memoryMiB, 16 * 1024)
        XCTAssertEqual(clamped.autoSuspendMinutes, TrackDConfigEditor.autoSuspendRange.upperBound)
    }

    func testClampedPreservesFieldsItDoesNotOwn() {
        var config = MorbConfig()
        config.kernelPath = "/tmp/vmlinux"
        config.kernelCmdline = "console=hvc0 quiet"
        config.diskSizeGiB = 128
        config.rosetta = false

        let clamped = TrackDConfigEditor.clamped(config, limits: limits)
        XCTAssertEqual(clamped.kernelPath, "/tmp/vmlinux")
        XCTAssertEqual(clamped.kernelCmdline, "console=hvc0 quiet")
        XCTAssertEqual(clamped.diskSizeGiB, 128)
        XCTAssertFalse(clamped.rosetta)
    }

    // MARK: - Restart detection

    func testRestartIsRequiredForVMShapeChanges() {
        let applied = MorbConfig()
        var pending = applied
        pending.memoryMiB = 4096
        XCTAssertTrue(TrackDConfigEditor.requiresEngineRestart(from: applied, to: pending))
        XCTAssertTrue(TrackDConfigEditor.restartSummary(from: applied, to: pending).contains("memory"))
    }

    func testRestartIsNotRequiredForDiskSize() {
        // The disk image is sized once, when it is created. Telling somebody a restart
        // will apply a new size would be a lie.
        let applied = MorbConfig()
        var pending = applied
        pending.diskSizeGiB = 256
        XCTAssertFalse(TrackDConfigEditor.requiresEngineRestart(from: applied, to: pending))
    }

    func testRestartIsNotRequiredWhenNothingChanged() {
        let config = MorbConfig()
        XCTAssertFalse(TrackDConfigEditor.requiresEngineRestart(from: config, to: config))
    }

    func testRestartIsRequiredForHostNetworkPortForwarding() {
        let applied = MorbConfig()
        var pending = applied
        pending.allowHostNetworkPortPublishing = true

        XCTAssertTrue(TrackDConfigEditor.requiresEngineRestart(from: applied, to: pending))
        XCTAssertTrue(TrackDConfigEditor.restartSummary(from: applied, to: pending).contains("host-network"))
    }

    func testRestartIsRequiredForLiveReloadPathChanges() {
        let applied = MorbConfig()
        var pending = applied
        pending.liveSharePaths = ["/Users/me/project"]

        XCTAssertTrue(TrackDConfigEditor.requiresEngineRestart(from: applied, to: pending))
        XCTAssertTrue(TrackDConfigEditor.restartSummary(from: applied, to: pending).contains("live reload"))
    }

    func testRestartSummaryNamesTheSentinel() {
        var applied = MorbConfig()
        applied.cpus = 0
        var pending = applied
        pending.cpus = 2
        XCTAssertEqual(TrackDConfigEditor.describeCPUs(applied), "all")
        XCTAssertTrue(TrackDConfigEditor.restartSummary(from: applied, to: pending).contains("all → 2"))
    }
}

// MARK: - Round trip

final class TrackDConfigRoundTripTests: XCTestCase {

    private let limits = TrackDResourceLimits(hostCores: 8, hostMemoryGiB: 16)
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("morb-settings-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    private var configURL: URL { directory.appendingPathComponent("config.toml") }

    @MainActor
    func testEditedConfigSurvivesAWriteAndAReload() throws {
        let store = TrackDSettingsStore(url: configURL, limits: limits)
        TrackDConfigEditor.applyCPU(3, to: &store.draft, limits: limits)
        TrackDConfigEditor.applyMemoryGiB(6, to: &store.draft, limits: limits)
        TrackDConfigEditor.applyAutoSuspend(20, to: &store.draft)

        XCTAssertTrue(store.isDirty)
        XCTAssertTrue(store.save())
        XCTAssertFalse(store.isDirty)

        let reloaded = try MorbConfig.load(from: configURL)
        XCTAssertEqual(reloaded.cpus, 3)
        XCTAssertEqual(reloaded.memoryMiB, 6 * 1024)
        XCTAssertEqual(reloaded.autoSuspendMinutes, 20)
        XCTAssertEqual(reloaded, store.saved)
    }

    @MainActor
    func testSavingPreservesCommentsAndForwardCompatibleContent() throws {
        // A hand-written file, complete with comments, a section, and values the
        // Settings window has no control for.
        let original = """
            # my machine
            cpus = 2 # deliberately conservative
            memory_mib = 4096
            disk_size_gib = 128
            kernel_cmdline = "console=hvc0 quiet"
            rosetta = false
            auto_suspend_minutes = 30

            [future-runtime]
            keep_this = "yes"
            nested_limit = 12
            advanced = { cache = true, replicas = 2 }
            """
        try original.write(to: configURL, atomically: true, encoding: .utf8)

        let store = TrackDSettingsStore(url: configURL, limits: limits)
        XCTAssertNil(store.loadError)
        TrackDConfigEditor.applyMemoryGiB(9, to: &store.draft, limits: limits)
        XCTAssertTrue(store.save())

        let reloaded = try MorbConfig.load(from: configURL)
        XCTAssertEqual(reloaded.memoryMiB, 9 * 1024, "the edit landed")
        XCTAssertEqual(reloaded.diskSizeGiB, 128, "disk size survived")
        XCTAssertEqual(reloaded.kernelCmdline, "console=hvc0 quiet", "cmdline survived")
        XCTAssertFalse(reloaded.rosetta, "rosetta survived")
        XCTAssertEqual(reloaded.autoSuspendMinutes, 30, "auto-suspend survived")

        let written = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(written.contains("# my machine"))
        XCTAssertTrue(written.contains("cpus = 2 # deliberately conservative"))
        XCTAssertTrue(written.contains("[future-runtime]"))
        XCTAssertTrue(written.contains("keep_this = \"yes\""))
        XCTAssertTrue(written.contains("nested_limit = 12"))
        XCTAssertTrue(written.contains("advanced = { cache = true, replicas = 2 }"))
    }

    @MainActor
    func testSavingMergesAnExternalEditToAnUntouchedKey() throws {
        try """
            # keep this note
            cpus = 2
            memory_mib = 4096
            rosetta = true
            [future]
            feature = "still here"
            """.write(to: configURL, atomically: true, encoding: .utf8)

        let store = TrackDSettingsStore(url: configURL, limits: limits)
        TrackDConfigEditor.applyMemoryGiB(9, to: &store.draft, limits: limits)

        // Another editor changed Rosetta after Settings loaded the document.
        try """
            # keep this note
            cpus = 2
            memory_mib = 4096
            rosetta = false
            [future]
            feature = "still here"
            """.write(to: configURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(store.save())
        let reloaded = try MorbConfig.load(from: configURL)
        XCTAssertEqual(reloaded.memoryMiB, 9 * 1024)
        XCTAssertFalse(reloaded.rosetta, "an untouched external edit must win")
        let written = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(written.contains("# keep this note"))
        XCTAssertTrue(written.contains("[future]"))
        XCTAssertTrue(written.contains("feature = \"still here\""))
    }

    @MainActor
    func testSavingRejectsAnExternalEditToTheSameKey() throws {
        try "memory_mib = 4096\nrosetta = true\n".write(
            to: configURL, atomically: true, encoding: .utf8)
        let store = TrackDSettingsStore(url: configURL, limits: limits)
        TrackDConfigEditor.applyMemoryGiB(9, to: &store.draft, limits: limits)

        try "memory_mib = 7168\nrosetta = true\n".write(
            to: configURL, atomically: true, encoding: .utf8)

        XCTAssertFalse(store.save())
        XCTAssertNotNil(store.saveError)
        XCTAssertEqual(
            try String(contentsOf: configURL, encoding: .utf8),
            "memory_mib = 7168\nrosetta = true\n",
            "a conflicting external edit must remain untouched")
    }

    @MainActor
    func testWrittenFileIsIdempotent() throws {
        let store = TrackDSettingsStore(url: configURL, limits: limits)
        store.draft.kernelPath = "/tmp/vmlinux"
        TrackDConfigEditor.applyCPU(5, to: &store.draft, limits: limits)
        XCTAssertTrue(store.save())

        let firstPass = try String(contentsOf: configURL, encoding: .utf8)
        let parsed = try MorbConfig.parse(firstPass)
        XCTAssertEqual(parsed.toTOML(), firstPass, "the canonical writer must be a fixed point")
        XCTAssertEqual(parsed, store.saved)
    }

    @MainActor
    func testMissingFileYieldsDefaultsRatherThanAnError() {
        let store = TrackDSettingsStore(
            url: directory.appendingPathComponent("does-not-exist.toml"), limits: limits)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.saved, TrackDConfigEditor.clamped(MorbConfig(), limits: limits))
        XCTAssertFalse(store.isDirty)
    }

    @MainActor
    func testMalformedFileIsReportedAndNotOverwritten() throws {
        try "cpus = \"lots\"\n".write(to: configURL, atomically: true, encoding: .utf8)

        let store = TrackDSettingsStore(url: configURL, limits: limits)
        XCTAssertNotNil(store.loadError, "the parse failure must reach the user")
        XCTAssertFalse(store.isDirty, "and must not present itself as an unsaved edit")

        let onDisk = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertEqual(onDisk, "cpus = \"lots\"\n", "loading must never rewrite the file")
    }

    @MainActor
    func testRevertDiscardsTheDraft() {
        let store = TrackDSettingsStore(url: configURL, limits: limits)
        let before = store.draft
        TrackDConfigEditor.applyCPU(7, to: &store.draft, limits: limits)
        XCTAssertTrue(store.isDirty)
        store.revert()
        XCTAssertEqual(store.draft, before)
        XCTAssertFalse(store.isDirty)
    }

    @MainActor
    func testRestartBannerAppearsOnSaveAndClearsWhenTheEngineStops() {
        let store = TrackDSettingsStore(url: configURL, limits: limits)
        XCTAssertFalse(store.needsEngineRestart)

        TrackDConfigEditor.applyMemoryGiB(5, to: &store.draft, limits: limits)
        XCTAssertFalse(store.needsEngineRestart, "an unsaved draft has not diverged from the VM yet")

        XCTAssertTrue(store.save())
        XCTAssertTrue(store.needsEngineRestart)
        XCTAssertTrue(store.restartSummary.contains("memory"))

        // A stopped engine re-reads the file on its next start, so there is nothing
        // left to restart for.
        store.engineStateChanged(running: false)
        XCTAssertFalse(store.needsEngineRestart)
    }

    @MainActor
    func testReloadPicksUpAnExternalEdit() throws {
        let store = TrackDSettingsStore(url: configURL, limits: limits)
        XCTAssertTrue(store.save())

        var edited = store.saved
        edited.autoSuspendMinutes = 45
        try edited.save(to: configURL)

        store.reload()
        XCTAssertEqual(store.saved.autoSuspendMinutes, 45)
        XCTAssertEqual(store.draft.autoSuspendMinutes, 45)
        XCTAssertFalse(store.isDirty)
    }

    @MainActor
    func testLiveReloadPathsUseThePreservingConfigWriter() throws {
        try "# keep this note\nshared_paths = [\"/Users\"]\n[future]\nfeature = \"still here\"\n".write(
            to: configURL, atomically: true, encoding: .utf8)
        let store = TrackDSettingsStore(url: configURL, limits: limits)
        store.draft.liveSharePaths = ["/Users/me/project"]

        XCTAssertTrue(store.save())
        XCTAssertEqual(try MorbConfig.load(from: configURL).liveSharePaths, ["/Users/me/project"])
        let written = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(written.contains("# keep this note"))
        XCTAssertTrue(written.contains("[future]"))
        XCTAssertTrue(written.contains("feature = \"still here\""))
    }
}
