// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Self-capture: the real running window, photographed by itself.
//
// `ShotRenderer.swift` explains why the offscreen harness cannot show the toolbar, the
// titlebar or the sidebar's Liquid Glass: its window is `.borderless`, which cannot have
// a titlebar or an `NSToolbar` attached at all, and a real screen capture
// (`screencapture`, `CGWindowListCreateImage`, ScreenCaptureKit) needs the Screen
// Recording TCC permission an agent process cannot be granted.
//
// This file sidesteps both by never using either. `--tour-capture <dir>` runs the real
// `MorbstackMainApp`, lets its real `NSWindow` come up with its real toolbar and real
// titlebar, and asks that window to render *itself* into a bitmap — `NSView.cacheDisplay`
// is how a well-behaved app draws its own content for printing or a PDF, and it needs no
// entitlement because the app is reading its own window, not the screen.
//
// The one thing worth getting right is *which* view to cache. `window.contentView` is
// the SwiftUI content only — with `.unified`/`.unifiedCompact` toolbar styles the
// titlebar and toolbar are drawn by the window's theme frame, a private AppKit view that
// sits one level up: `window.contentView?.superview`. That is tried first; `contentView`
// is the fallback, and which one actually worked is recorded per shot (see
// `LiveCaptureRunner.Output.strategy`) rather than assumed, because the answer changes
// with the window's style mask and is worth a human being able to check.

import AppKit
import SwiftUI

// MARK: - Palette bridge

/// Lets ``LiveCaptureRunner`` toggle the command palette sheet without owning
/// `App.swift`'s `@State`.
///
/// Same shape as `TrackDAppBridge`'s hooks: `App.swift` installs the setter from
/// `RootWindow.onAppear`, and this stays `nil` — a harmless no-op — on every launch that
/// is not `--tour-capture`.
@MainActor
enum LiveCaptureBridge {
    static var setPalettePresented: ((Bool) -> Void)?
}

// MARK: - Runner

/// Walks every screen against the real window and writes a PNG per screen.
@MainActor
enum LiveCaptureRunner {

    /// Which view actually got cached for a shot.
    enum Strategy: String {
        /// `window.contentView?.superview` — the theme frame. Includes the titlebar and
        /// the toolbar along with the content, because both are drawn there rather than
        /// inside `contentView` under a unified toolbar style.
        case themeFrame
        /// `window.contentView` alone — content only, no titlebar, no toolbar. Only used
        /// when the theme frame could not be cached.
        case contentView
    }

    struct Output {
        var name: String
        var pixelWidth: Int
        var pixelHeight: Int
        var bytes: Int
        var strategy: Strategy
        var stats: ShotBitmapStats
    }

    enum LiveCaptureError: Error, LocalizedError {
        case noWindow
        case bitmap
        case encode(String)

        var errorDescription: String? {
            switch self {
            case .noWindow: return "no presentable window to capture"
            case .bitmap: return "could not cache the window's view into a bitmap"
            case .encode(let name): return "could not encode \(name) as PNG"
            }
        }
    }

    /// How long to let SwiftUI settle after a model mutation before capturing.
    ///
    /// This is a *real* window on a *real* run loop — unlike `ShotRenderer`'s offscreen
    /// harness there is no need to spin `RunLoop.main` by hand; sleeping the task is
    /// enough to hand control back to the app's own event loop between frames.
    static let settle: TimeInterval = 1.2

    /// Runs the whole tour — every screen in ``steps``, then Settings, then the command
    /// palette — and exits the process. Never returns.
    static func run(model: AppModel, options: LaunchOptions) async {
        guard let rawDirectory = options.tourCapture else { return }
        let directory = URL(fileURLWithPath: (rawDirectory as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scheme = options.appearance == .dark ? "dark" : "light"

        NSApp.activate()
        await waitForMainWindow()

        var outputs: [Output] = []
        var notes: [String] = []

        for step in steps {
            step.apply(model)
            try? await Task.sleep(nanoseconds: UInt64(step.settle * 1_000_000_000))
            do {
                outputs.append(try captureMainWindow(name: step.name, scheme: scheme, to: directory))
            } catch {
                notes.append("\(step.name): \(error.localizedDescription)")
            }
        }

        if let output = await captureSettings(scheme: scheme, to: directory) {
            outputs.append(output)
        } else {
            notes.append("settings: could not locate the Settings scene's window")
        }

        if let output = await capturePalette(scheme: scheme, to: directory) {
            outputs.append(output)
        } else {
            notes.append(
                "command-palette: LiveCaptureBridge.setPalettePresented was not installed "
                    + "(App.swift wires it from RootWindow.onAppear)")
        }

        notes.append(
            "menubar-popover: not captured — showing it needs the NSStatusItem that backs "
                + "MenuBarExtra, which MenuBar/MorbMenuBar.swift does not expose a handle "
                + "to capture from outside that file")
        notes.append(
            "container-logs, container-inspect: SKIPPED — model.requestLogsTab(for:) "
                + "reproducibly crashes the real window (SIGTRAP in "
                + "-[NSToolbar _insertNewItemWithItemIdentifier:...]): ContainersRootView "
                + "and ContainerLogsTab/ContainerInspectTab each attach their own "
                + ".searchable(placement: .toolbar), and both are on screen at once in this "
                + "state. Real bug, not a capture artifact — see the `steps` doc comment.")

        report(outputs: outputs, notes: notes, directory: directory)
        exit(0)
    }

    // MARK: - Screens

    private struct Step {
        var name: String
        var settle: TimeInterval = LiveCaptureRunner.settle
        var apply: (AppModel) -> Void
    }

    /// The fixture container the container-detail steps open.
    ///
    /// Looked up by name at capture time rather than baked in as an id: against
    /// `--tour-fixtures` this is always present (`ShotFixtures.containers`), and against
    /// a real, fixture-less engine (`--tour-capture` without `--tour-fixtures`) it
    /// degrades to whatever the engine actually has running rather than failing to find
    /// a name that was never going to exist.
    private static func detailContainerID(_ model: AppModel) -> String? {
        model.containers.first { $0.displayName == "shopfront-api-1" || $0.names.contains("shopfront-api-1") }?.id
            ?? model.containers.first?.id
    }

    private static var steps: [Step] {
        [
            Step(name: "containers") { model in
                model.selection = .containers
                model.selectedContainerID = nil
            },
            Step(name: "container-overview") { model in
                model.selection = .containers
                model.selectedContainerID = detailContainerID(model)
            },
            // Not "container-logs", "container-inspect": both crash the real window.
            // `ContainersRootView` (the list beside the detail pane) and
            // `ContainerLogsTab`/`ContainerInspectTab` each carry their own
            // `.searchable(text:placement:.toolbar)`, and when both are on screen at
            // once — the ordinary "Containers selected, a container's Logs/Inspect tab
            // open" state — AppKit's real `NSToolbar` gets two contributions for the
            // one reserved search-item identifier and throws
            // `-[NSToolbar _insertNewItemWithItemIdentifier:...]`, which
            // `+[NSApplication _crashOnException:]` turns into a hard crash (SIGTRAP).
            // Reproduced from a bare launch with nothing but
            // `model.requestLogsTab(for:)` — the exact call `TrackDAppBridge.showLogs`
            // makes for the menu bar's and command palette's "View logs of X" — so this
            // is not a `--tour-capture` artifact; it is a real crash in the shipping
            // toolbar composition that the offscreen `MorbShots` harness could never
            // have caught, because its `.borderless` window cannot have a real
            // `NSToolbar` at all. Filed rather than routed around in silence — see the
            // `LiveCaptureRunner.run` note below and the final report.
            Step(name: "stacks") { model in model.selection = .stacks },
            Step(name: "images") { model in model.selection = .images },
            Step(name: "volumes") { model in model.selection = .volumes },
            Step(name: "networks") { model in model.selection = .networks },
            Step(name: "disk", settle: 0.8) { model in model.selection = .disk },
            Step(name: "kubernetes") { model in model.selection = .kubernetes },
        ]
    }

    // MARK: - Waiting for a window

    private static func waitForMainWindow(timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while mainWindow() == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// The window `MorbLaunchRescue` would consider presentable — same test the launch
    /// rescue and `--tour-dump-window` use, so "the window this captures" and "the
    /// window the app itself thinks is its main window" cannot disagree.
    private static func mainWindow() -> NSWindow? {
        let windows = NSApp.windows
        let snapshots = windows.map(MorbWindowSnapshot.init)
        guard let index = snapshots.firstIndex(where: \.isPresentableMainWindow) else { return nil }
        return windows[index]
    }

    // MARK: - Settings and the palette

    /// Opens the `Settings` scene the same way `SettingsLink`/⌘, does — `sendAction`
    /// against the standard selector, which needs no reference to the scene or its view.
    private static func captureSettings(scheme: String, to directory: URL) async -> Output? {
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)

        guard let window = await waitForNewWindow(notIn: before) else { return nil }
        try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
        let output = try? captureWindow(window, name: "settings", scheme: scheme, to: directory)
        window.close()
        NSApp.activate()
        mainWindow()?.makeKeyAndOrderFront(nil)
        return output
    }

    /// Toggles the palette sheet via ``LiveCaptureBridge`` and captures whatever new
    /// window SwiftUI presented it in.
    ///
    /// A macOS `.sheet` is its own child `NSWindow`, layered by the window server rather
    /// than drawn inside the parent's view hierarchy — so capturing the main window here
    /// would show it dimmed and empty, not the palette. The new window has to be found
    /// and cached on its own.
    private static func capturePalette(scheme: String, to directory: URL) async -> Output? {
        guard let setPalette = LiveCaptureBridge.setPalettePresented else { return nil }
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        setPalette(true)
        defer { setPalette(false) }

        guard let window = await waitForNewWindow(notIn: before) else { return nil }
        try? await Task.sleep(nanoseconds: 300_000_000)
        return try? captureWindow(window, name: "command-palette", scheme: scheme, to: directory)
    }

    private static func waitForNewWindow(notIn before: Set<ObjectIdentifier>, timeout: TimeInterval = 3) async -> NSWindow? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let found = NSApp.windows.first(where: { !before.contains(ObjectIdentifier($0)) && $0.isVisible }) {
                return found
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    // MARK: - Capture

    private static func captureMainWindow(name: String, scheme: String, to directory: URL) throws -> Output {
        guard let window = mainWindow() else { throw LiveCaptureError.noWindow }
        return try captureWindow(window, name: name, scheme: scheme, to: directory)
    }

    private static func captureWindow(_ window: NSWindow, name: String, scheme: String, to directory: URL) throws -> Output {
        window.makeKeyAndOrderFront(nil)
        let (rep, strategy) = try renderedBitmap(of: window)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw LiveCaptureError.encode(name)
        }
        let url = directory.appendingPathComponent("\(name)-\(scheme)@2x.png")
        try png.write(to: url)
        return Output(
            name: url.lastPathComponent,
            pixelWidth: rep.pixelsWide,
            pixelHeight: rep.pixelsHigh,
            bytes: png.count,
            strategy: strategy,
            stats: ShotBitmapStats(rep))
    }

    /// Tries the theme frame first (titlebar + toolbar + content), then falls back to
    /// `contentView` alone. Which one actually worked travels with the output rather than
    /// being assumed.
    private static func renderedBitmap(of window: NSWindow) throws -> (NSBitmapImageRep, Strategy) {
        if let themeFrame = window.contentView?.superview, let rep = bitmap(of: themeFrame) {
            return (rep, .themeFrame)
        }
        if let content = window.contentView, let rep = bitmap(of: content) {
            return (rep, .contentView)
        }
        throw LiveCaptureError.bitmap
    }

    /// `NSView.cacheDisplay` — an ordinary AppKit view drawing its own already-composited
    /// content into a bitmap. `bitmapImageRepForCachingDisplay` sizes the rep for the
    /// view's own backing scale factor, so a Retina window comes out at 2x with no manual
    /// transform.
    private static func bitmap(of view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    // MARK: - Reporting

    private static func report(outputs: [Output], notes: [String], directory: URL) {
        print("Morbstack live capture")
        print("  out \(directory.path)")
        print("")
        for output in outputs {
            let blank = output.stats.looksBlank ? "  BLANK?" : ""
            print(
                "  \(output.name)  \(output.strategy.rawValue)  "
                    + "\(output.pixelWidth)x\(output.pixelHeight)  \(output.bytes) bytes\(blank)")
        }
        print("")
        print("\(outputs.count) image(s)")
        if !notes.isEmpty {
            print("")
            print("\(notes.count) note(s):")
            for note in notes { print("  ! \(note)") }
        }
    }
}
