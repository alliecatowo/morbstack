// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Coverage for the launch rescue — the code that makes sure Morbstack.app has a window.
//
// The rescue itself has to run inside a live NSApplication, which no unit test has. What
// a unit test can pin down is the part that is actually easy to get wrong:
//
//   * the "is there a window?" predicate. Every AppKit app carries offscreen and
//     zero-sized windows around, and a rescue that counts one of those as the main
//     window is a rescue that never fires — silently, on the machine it was written for;
//   * the saved-state path rules. This is the only code in Morbstack that calls
//     `removeItem` on a directory it computed, so "can it ever be aimed at something
//     that is not our own restoration store?" deserves an adversarial test rather than a
//     careful read;
//   * the `--tour-dump-window` report, which is the evidence the fix is verified with.
//     If its format drifts, the verification silently stops verifying.
//
// Nothing here touches the real saved-state directory: the purge tests build their own
// tree in a temporary directory and pass it in.

import Foundation
import XCTest

@testable import MorbstackAppCore

final class TrackALaunchRescueTests: XCTestCase {

    // MARK: - Fixtures

    /// A healthy main window: on screen, main-capable, big enough to be real.
    private func mainWindow(
        identifier: String = "morbstack.main-AppWindow-1",
        title: String = "Containers",
        visible: Bool = true,
        miniaturized: Bool = false,
        width: Double = 1180,
        height: Double = 760
    ) -> MorbWindowSnapshot {
        MorbWindowSnapshot(
            identifier: identifier,
            title: title,
            isVisible: visible,
            canBecomeMain: true,
            isMiniaturized: miniaturized,
            width: width,
            height: height)
    }

    /// The `MenuBarExtra` host: always present, never a window the user can work in.
    private var statusItemWindow: MorbWindowSnapshot {
        MorbWindowSnapshot(
            identifier: "", title: "", isVisible: true, canBecomeMain: false,
            isMiniaturized: false, width: 32, height: 22)
    }

    private var settingsWindow: MorbWindowSnapshot {
        MorbWindowSnapshot(
            identifier: "com_apple_SwiftUI_Settings_window", title: "Settings",
            isVisible: true, canBecomeMain: true, isMiniaturized: false,
            width: 620, height: 440)
    }

    // MARK: - needsRescue

    func testNoWindowsAtAllNeedsRescue() {
        XCTAssertTrue(MorbLaunchRescue.needsRescue([]))
    }

    func testAHealthyMainWindowNeedsNoRescue() {
        XCTAssertFalse(MorbLaunchRescue.needsRescue([statusItemWindow, mainWindow()]))
    }

    /// The exact shape of the bug: AppKit is holding windows, none of them is the app.
    func testOnlyTheStatusItemWindowNeedsRescue() {
        XCTAssertTrue(MorbLaunchRescue.needsRescue([statusItemWindow]))
    }

    func testAnInvisibleMainWindowNeedsRescue() {
        XCTAssertTrue(MorbLaunchRescue.needsRescue([mainWindow(visible: false)]))
    }

    func testAMiniaturizedMainWindowNeedsRescue() {
        XCTAssertTrue(MorbLaunchRescue.needsRescue([mainWindow(miniaturized: true)]))
    }

    /// Settings on its own is not "the app has a window". Counting it would disable the
    /// rescue for anybody who opened Preferences from the menu bar.
    func testSettingsAloneNeedsRescue() {
        XCTAssertTrue(MorbLaunchRescue.needsRescue([settingsWindow, statusItemWindow]))
    }

    func testSettingsIsRecognisedByIdentifierWithoutATitle() {
        let window = MorbWindowSnapshot(
            identifier: "com_apple_SwiftUI_Settings_window", title: "",
            isVisible: true, canBecomeMain: true, isMiniaturized: false,
            width: 620, height: 440)
        XCTAssertTrue(window.isSettingsWindow)
        XCTAssertFalse(window.isPresentableMainWindow)
    }

    /// A 1×1 offscreen window is not a UI. AppKit keeps several.
    func testATinyWindowDoesNotCount() {
        XCTAssertTrue(MorbLaunchRescue.needsRescue([mainWindow(width: 1, height: 1)]))
    }

    // MARK: - revivableIndex

    func testNothingToReviveWhenThereAreNoWindows() {
        XCTAssertNil(MorbLaunchRescue.revivableIndex([]))
    }

    func testAHiddenMainWindowIsWorthReviving() {
        let windows = [statusItemWindow, mainWindow(visible: false)]
        XCTAssertEqual(MorbLaunchRescue.revivableIndex(windows), 1)
    }

    func testAVisibleWindowIsPreferredOverAHiddenOne() {
        let windows = [
            mainWindow(identifier: "hidden", visible: false),
            mainWindow(identifier: "shown", visible: true),
        ]
        XCTAssertEqual(MorbLaunchRescue.revivableIndex(windows), 1)
    }

    func testSettingsIsNeverRevivedAsTheMainWindow() {
        XCTAssertNil(MorbLaunchRescue.revivableIndex([settingsWindow, statusItemWindow]))
    }

    // MARK: - Saved-state identifier guard

    func testTheRealBundleIdentifierIsAccepted() {
        XCTAssertTrue(MorbSavedState.isSafeBundleIdentifier("dev.morbstack.app"))
    }

    func testHostileBundleIdentifiersAreRejected() {
        let hostile = [
            "",
            "..",
            "../../../../etc",
            "dev.morbstack.app/../../Library",
            "/absolute",
            ".leadingdot",
            "trailingdot.",
            "has space",
            "has\nnewline",
            "~",
            String(repeating: "a", count: 201),
        ]
        for identifier in hostile {
            XCTAssertFalse(
                MorbSavedState.isSafeBundleIdentifier(identifier),
                "should have rejected \(identifier.debugDescription)")
        }
    }

    // MARK: - Saved-state paths

    func testCandidateDirectoriesAreAllOurOwnSavedState() {
        let candidates = MorbSavedState.candidateDirectories(
            bundleID: "dev.morbstack.app",
            temporaryDirectory: URL(fileURLWithPath: "/var/folders/zp/abc/T", isDirectory: true),
            homeDirectory: URL(fileURLWithPath: "/Users/someone", isDirectory: true))

        XCTAssertEqual(candidates.count, 3)
        for url in candidates {
            XCTAssertEqual(url.lastPathComponent, "dev.morbstack.app.savedState")
        }
        XCTAssertEqual(candidates[0].path, "/var/folders/zp/abc/T/dev.morbstack.app.savedState")
        XCTAssertEqual(candidates[1].path, "/var/folders/zp/abc/dev.morbstack.app.savedState")
        XCTAssertEqual(
            candidates[2].path,
            "/Users/someone/Library/Saved Application State/dev.morbstack.app.savedState")
    }

    func testAnUnsafeIdentifierYieldsNoCandidatesAtAll() {
        let candidates = MorbSavedState.candidateDirectories(
            bundleID: "../../../Users/someone/Documents",
            temporaryDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            homeDirectory: URL(fileURLWithPath: "/Users/someone", isDirectory: true))
        XCTAssertTrue(candidates.isEmpty)
    }

    func testIsRemovableOnlyAcceptsOurOwnDirectoryName() {
        let id = "dev.morbstack.app"
        XCTAssertTrue(
            MorbSavedState.isRemovable(
                URL(fileURLWithPath: "/tmp/dev.morbstack.app.savedState"), bundleID: id))
        // Another app's store, the enclosing directory, and a near-miss name.
        XCTAssertFalse(
            MorbSavedState.isRemovable(
                URL(fileURLWithPath: "/tmp/com.apple.Safari.savedState"), bundleID: id))
        XCTAssertFalse(
            MorbSavedState.isRemovable(URL(fileURLWithPath: "/tmp"), bundleID: id))
        XCTAssertFalse(
            MorbSavedState.isRemovable(
                URL(fileURLWithPath: "/tmp/dev.morbstack.appXsavedState"), bundleID: id))
        // A traversal that resolves out of the store is caught by standardisation.
        XCTAssertFalse(
            MorbSavedState.isRemovable(
                URL(fileURLWithPath: "/tmp/dev.morbstack.app.savedState/.."), bundleID: id))
    }

    // MARK: - Saved-state purge

    func testPurgeRemovesOurStoreAndLeavesEverythingElseAlone() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("morb-savedstate-test-\(UUID().uuidString)", isDirectory: true)
        let temporary = root.appendingPathComponent("T", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let manager = FileManager.default

        let ours = temporary.appendingPathComponent("dev.morbstack.app.savedState", isDirectory: true)
        let theirs = temporary.appendingPathComponent("com.apple.Safari.savedState", isDirectory: true)
        let oursInLibrary = home
            .appendingPathComponent("Library/Saved Application State/dev.morbstack.app.savedState",
                                    isDirectory: true)
        for directory in [ours, theirs, oursInLibrary] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: directory.appendingPathComponent("windows.plist"))
        }
        defer { try? manager.removeItem(at: root) }

        let removed = MorbSavedState.purge(
            bundleID: "dev.morbstack.app", temporaryDirectory: temporary, homeDirectory: home)

        XCTAssertEqual(removed.count, 2)
        XCTAssertFalse(manager.fileExists(atPath: ours.path))
        XCTAssertFalse(manager.fileExists(atPath: oursInLibrary.path))
        XCTAssertTrue(manager.fileExists(atPath: theirs.path), "another app's state must survive")
        XCTAssertTrue(manager.fileExists(atPath: temporary.path), "the enclosing directory must survive")
    }

    func testPurgeIsAQuietNoOpWhenThereIsNothingToRemove() {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("morb-savedstate-missing-\(UUID().uuidString)", isDirectory: true)
        let removed = MorbSavedState.purge(
            bundleID: "dev.morbstack.app",
            temporaryDirectory: temporary,
            homeDirectory: temporary)
        XCTAssertTrue(removed.isEmpty)
    }

    func testPurgeRefusesAnUnsafeIdentifier() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("morb-savedstate-unsafe-\(UUID().uuidString)", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let removed = MorbSavedState.purge(
            bundleID: "../..", temporaryDirectory: root, homeDirectory: root)

        XCTAssertTrue(removed.isEmpty)
        XCTAssertTrue(manager.fileExists(atPath: root.path))
    }

    // MARK: - Launch options

    func testDumpWindowFlagParses() {
        let options = LaunchOptions(arguments: ["MorbstackApp", "--tour-dump-window"])
        XCTAssertTrue(options.dumpWindow)
    }

    func testDumpWindowIsOffByDefault() {
        XCTAssertFalse(LaunchOptions(arguments: ["MorbstackApp"]).dumpWindow)
        XCTAssertFalse(LaunchOptions.none.dumpWindow)
    }

    func testDumpWindowComposesWithTheOtherTourSwitches() {
        let options = LaunchOptions(arguments: [
            "MorbstackApp", "--tour-select", "images", "--window-size", "1180x760",
            "--tour-dump-window",
        ])
        XCTAssertTrue(options.dumpWindow)
        XCTAssertEqual(options.select, .images)
        XCTAssertEqual(options.windowSize, CGSize(width: 1180, height: 760))
    }

    /// `open -n Morbstack.app --args …` is the launch path the fix is verified through,
    /// and it neither keeps stdout nor forwards the shell's environment, so the report
    /// has to be addressable by a flag.
    func testDumpFileFlagParses() {
        let options = LaunchOptions(arguments: [
            "MorbstackApp", "--tour-dump-window", "--tour-dump-file", "/tmp/dump.txt",
        ])
        XCTAssertTrue(options.dumpWindow)
        XCTAssertEqual(options.dumpFile, "/tmp/dump.txt")
    }

    func testDumpFileFlagWithNoValueIsIgnoredRatherThanFatal() {
        let options = LaunchOptions(arguments: ["MorbstackApp", "--tour-dump-file"])
        XCTAssertNil(options.dumpFile)
    }

    // MARK: - Window dump report

    func testDumpReportsNoWindow() {
        let report = MorbWindowDump.render([statusItemWindow])
        XCTAssertTrue(report.contains("windows=1 presentable=0"), report)
        XCTAssertTrue(report.contains("result=NO-WINDOW"), report)
    }

    func testDumpReportsTheWindowAndItsFrame() {
        let report = MorbWindowDump.render([statusItemWindow, mainWindow()])
        XCTAssertTrue(report.contains("windows=2 presentable=1"), report)
        XCTAssertTrue(report.contains("frame=1180x760"), report)
        XCTAssertTrue(report.contains("title=\"Containers\""), report)
        XCTAssertTrue(report.contains("result=OK"), report)
    }

    /// One line per window plus a header and a verdict, so a script can grep either the
    /// summary or an individual window without parsing.
    func testDumpHasOneLinePerWindowPlusHeaderAndVerdict() {
        let lines = MorbWindowDump.render([statusItemWindow, mainWindow(), settingsWindow])
            .split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 5)
        for line in lines {
            XCTAssertTrue(line.hasPrefix(MorbWindowDump.prefix), String(line))
        }
    }

    func testDumpAlsoWritesToTheFileTheEnvironmentNames() throws {
        let path = NSTemporaryDirectory() + "morb-dump-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let report = MorbWindowDump.render([mainWindow()])
        MorbWindowDump.emit(report, environment: ["MORB_TOUR_DUMP_FILE": path])

        let written = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(written, report + "\n")
    }

    func testDumpAlsoWritesToTheFileTheFlagNames() throws {
        let path = NSTemporaryDirectory() + "morb-dump-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let report = MorbWindowDump.render([mainWindow()])
        MorbWindowDump.emit(report, file: path, environment: [:])

        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), report + "\n")
    }

    /// The flag wins: it was passed for this run, the environment variable may just be
    /// left over in the shell.
    func testTheFlagBeatsTheEnvironmentVariable() throws {
        let wanted = NSTemporaryDirectory() + "morb-dump-\(UUID().uuidString).txt"
        let unwanted = NSTemporaryDirectory() + "morb-dump-\(UUID().uuidString).txt"
        defer {
            try? FileManager.default.removeItem(atPath: wanted)
            try? FileManager.default.removeItem(atPath: unwanted)
        }

        let report = MorbWindowDump.render([mainWindow()])
        MorbWindowDump.emit(report, file: wanted, environment: ["MORB_TOUR_DUMP_FILE": unwanted])

        XCTAssertEqual(try String(contentsOfFile: wanted, encoding: .utf8), report + "\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: unwanted))
    }

    func testDumpWritesNoFileWhenNobodyAskedForOne() {
        // Just has to not throw or write anywhere; stdout is the only destination.
        MorbWindowDump.emit(MorbWindowDump.render([mainWindow()]), file: nil, environment: [:])
        MorbWindowDump.emit(
            MorbWindowDump.render([mainWindow()]), file: "", environment: ["MORB_TOUR_DUMP_FILE": ""])
    }

    // MARK: - Sweep timing

    /// The sweeps have to finish before `--tour-dump-window` reports, or the flag would
    /// print a verdict from before the rescue and the whole verification would be a lie.
    func testEverySweepRunsBeforeTheWindowDump() {
        XCTAssertFalse(MorbAppDelegate.sweepDelays.isEmpty)
        for delay in MorbAppDelegate.sweepDelays {
            XCTAssertLessThan(delay, MorbAppDelegate.dumpDelay)
        }
        XCTAssertEqual(MorbAppDelegate.sweepDelays, MorbAppDelegate.sweepDelays.sorted())
    }
}
