// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Fixture-backed live-window route probe.
//
// This is intentionally not a screenshot implementation.  WindowServer composites a
// macOS titlebar, toolbar, sidebar material, sheets, inspectors, focus, and Liquid Glass
// after AppKit has produced its view tree.  `NSView.cacheDisplay`, ImageRenderer, and a
// borderless hosting window cannot reproduce that composition faithfully.  Do not add a
// substitute image path here: use Computer Use for present-day full-window approval and
// an XCUITest host for automated accessibility/screenshot assertions.

import AppKit
import SwiftUI

/// Lets ``LiveCaptureRunner`` present the real command-palette sheet without duplicating
/// the root window's state. `App.swift` supplies the closure from the live scene.
@MainActor
enum LiveCaptureBridge {
    static var setPalettePresented: ((Bool) -> Void)?
}

/// Visits fixture-backed primary routes in a genuine app window.
///
/// The probe proves only that the process stayed alive, a presentable main window existed,
/// and each deterministic model state was reached. It makes **no** claim about the
/// appearance, layout, accessibility, input handling, or compositor-owned window chrome.
@MainActor
enum LiveCaptureRunner {

    private static let settle: TimeInterval = 0.6

    private struct Step {
        let name: String
        let apply: (AppModel) -> Void
    }

    private struct Result {
        let name: String
        let passed: Bool
        let detail: String
    }

    /// Runs the non-visual fixture route probe requested by `--tour-capture`.
    ///
    /// `<directory>/fixture-route-probe-<appearance>.txt` is a text-only execution
    /// record, never an image artifact and never full-window evidence.
    static func run(model: AppModel, options: LaunchOptions) async {
        guard let rawDirectory = options.tourCapture else { return }
        let directory = URL(fileURLWithPath: (rawDirectory as NSString).expandingTildeInPath)
        let appearanceName = options.appearance == .dark ? "dark" : "light"
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        NSApp.activate()
        await waitForMainWindow()

        var results: [Result] = []
        for step in steps {
            step.apply(model)
            try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
            if mainWindow() == nil {
                results.append(Result(
                    name: step.name,
                    passed: false,
                    detail: "no presentable main window after fixture state change"))
            } else {
                results.append(Result(
                    name: step.name,
                    passed: true,
                    detail: "fixture state reached; visual and accessibility review not performed"))
            }
        }

        results.append(commandPaletteProbe())

        let report = renderReport(results, appearance: appearanceName)
        print(report)
        try? report.write(
            to: directory.appendingPathComponent("fixture-route-probe-\(appearanceName).txt"),
            atomically: true,
            encoding: .utf8)
        exit(results.allSatisfy(\.passed) ? 0 : 1)
    }

    // MARK: - Routes

    private static var steps: [Step] {
        [
            Step(name: "containers") { model in
                model.selection = .containers
                model.selectedContainerID = nil
            },
            Step(name: "container-selection") { model in
                model.selection = .containers
                model.selectedContainerID = detailContainerID(model)
            },
            Step(name: "stacks") { $0.selection = .stacks },
            Step(name: "images") { $0.selection = .images },
            Step(name: "volumes") { $0.selection = .volumes },
            Step(name: "networks") { $0.selection = .networks },
            Step(name: "builds") { $0.selection = .builds },
            Step(name: "disk") { $0.selection = .disk },
            Step(name: "kubernetes") { $0.selection = .kubernetes },
        ]
    }

    private static func detailContainerID(_ model: AppModel) -> String? {
        model.containers.first(where: { $0.displayName == "shopfront-api-1" })?.id
            ?? model.containers.first?.id
    }

    // MARK: - Real-window liveness

    private static func waitForMainWindow(timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while mainWindow() == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Uses the same presentable-window predicate as launch rescue, avoiding a private
    /// view hierarchy or any attempt to inspect/composite window surfaces.
    private static func mainWindow() -> NSWindow? {
        let windows = NSApp.windows
        let snapshots = windows.map(MorbWindowSnapshot.init)
        guard let index = snapshots.firstIndex(where: \.isPresentableMainWindow) else { return nil }
        return windows[index]
    }

    private static func commandPaletteProbe() -> Result {
        guard let setPalettePresented = LiveCaptureBridge.setPalettePresented else {
            return Result(
                name: "command-palette-host",
                passed: false,
                detail: "the live root did not install its presentation bridge")
        }
        setPalettePresented(true)
        setPalettePresented(false)
        return Result(
            name: "command-palette-host",
            passed: true,
            detail: "live presentation bridge is installed; sheet appearance and focus were not reviewed")
    }

    // MARK: - Reporting

    private static func renderReport(_ results: [Result], appearance: String) -> String {
        let passed = results.filter(\.passed).count
        let rows = results.map { result in
            let marker = result.passed ? "✓" : "✗"
            return "  \(marker) \(result.name): \(result.detail)"
        }
        return ([
            "Morbstack fixture route probe (\(appearance)) — not a visual test",
            "  No screenshot, bitmap, view-cache, compositor, accessibility, or interaction assertion ran.",
            "  Full-window approval requires Computer Use now and XCUITest when a UI-test host exists.",
            "",
        ] + rows + ["", "\(passed)/\(results.count) route-probe checks passed"]).joined(separator: "\n")
    }
}
