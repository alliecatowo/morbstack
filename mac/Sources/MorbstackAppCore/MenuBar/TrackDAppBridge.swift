// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The one place Track D reaches outside its own views.
//
// Two Track D surfaces — the menu bar and the command palette — have to be able to say
// "show me that container in the main window". That means (a) mutating the same
// `selection` / `selectedContainerID` the `--tour-*` launch arguments drive, and
// (b) getting a possibly-closed, possibly-hidden main window back in front.
//
// (a) is just `AppModel`. (b) needs a `WindowGroup` id that Track A owns, so it is
// expressed as an optional hook: `App.swift` may install `openMainWindow` from a
// `@Environment(\.openWindow)` action, and if it does not, the AppKit fallback below
// still does the right thing for any window that merely got hidden or buried.

import AppKit
import SwiftUI

/// Cross-track hooks and the app-wide reveal path.
@MainActor
enum TrackDAppBridge {

    // MARK: - Optional hooks

    /// Installed by `App.swift` (Track A) as
    /// `TrackDAppBridge.openMainWindow = { openWindow(id: <main window id>) }`.
    ///
    /// Optional by design: Track D must not depend on a window identifier it does not
    /// own, and every caller degrades to ``revealMainWindow()`` when this is `nil`.
    static var openMainWindow: (() -> Void)?

    /// Installed by whichever track owns the container detail's log pane, as
    /// `TrackDAppBridge.showLogs = { id in … }`.
    ///
    /// The palette's "View logs of X" command selects the container either way; this
    /// hook is what additionally switches the detail view to its Logs tab.
    static var showLogs: ((String) -> Void)?

    // MARK: - Reveal

    /// Brings the app's main window forward, activating the app first.
    ///
    /// The AppKit fallback deliberately skips the status-bar window that hosts
    /// `MenuBarExtra` and the Settings scene: both can be frontmost when this runs, and
    /// re-ordering either of them in front of itself is not what anybody asked for.
    static func revealMainWindow() {
        NSApp.activate()

        if let window = candidateMainWindow() {
            window.makeKeyAndOrderFront(nil)
            return
        }

        // Nothing suitable is open: only the `WindowGroup` can make a new one.
        if let openMainWindow {
            openMainWindow()
            return
        }

        // No hook installed. SwiftUI's own app delegate restores a closed `WindowGroup`
        // window in response to a Dock re-open, and that entry point is callable
        // directly — which is what makes "Open Morbstack" work from the menu bar even
        // when `App.swift` has told us nothing about its window identifier.
        if let delegate = NSApp.delegate,
            delegate.responds(
                to: #selector(NSApplicationDelegate.applicationShouldHandleReopen(_:hasVisibleWindows:))) {
            _ = delegate.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
            candidateMainWindow()?.makeKeyAndOrderFront(nil)
        }
    }

    private static func candidateMainWindow() -> NSWindow? {
        let windows = NSApp.windows.filter { window in
            guard window.canBecomeMain else { return false }
            let identifier = window.identifier?.rawValue.lowercased() ?? ""
            if identifier.contains("settings") || identifier.contains("com_apple_swiftui_settings") {
                return false
            }
            if window.title == "Settings" { return false }
            return true
        }
        // A window that is already on screen beats a closed one that AppKit is still
        // holding on to, and among those the key window is the user's own last choice.
        return windows.first(where: { $0.isKeyWindow })
            ?? windows.first(where: { $0.isVisible })
            ?? windows.first
    }

    /// Selects `nav` and brings the main window forward.
    static func reveal(_ nav: Nav, in model: AppModel) {
        model.selection = nav
        revealMainWindow()
    }

    /// Selects a container in the Containers section and brings the window forward.
    ///
    /// This is the same state the `--tour-container` launch argument sets, which is
    /// what makes the menu bar's row click and the screenshot tooling agree.
    static func reveal(containerID: String, in model: AppModel, showingLogs: Bool = false) {
        model.selection = .containers
        model.selectedContainerID = containerID
        revealMainWindow()
        if showingLogs { showLogs?(containerID) }
    }

    /// Selects a Compose project on the Stacks screen and brings the window forward.
    ///
    /// This is the menu bar's whole answer to project-level work. A Compose project's
    /// lifecycle actions live on Stacks behind a confirmation that names how many
    /// services it touches and what it deliberately does not do; the extra points at
    /// that, rather than carrying a second, weaker copy of it.
    static func reveal(composeProject: String, in model: AppModel) {
        model.stackSelectionRequest = composeProject
        model.selection = .stacks
        revealMainWindow()
    }
}

// MARK: - Well-known strings

/// Paths and commands Track D shows or copies.
enum TrackDLinks {

    /// The `docker context` incantation that points the Docker CLI at Morbstack.
    ///
    /// Two statements rather than one: creating a context that nothing selects is a
    /// papercut people hit once each, and the second half is what makes `docker ps`
    /// work in the terminal they paste this into.
    static func dockerContextCommand(socketPath: String) -> String {
        "docker context create morbstack --docker host=unix://\(socketPath) && docker context use morbstack"
    }

    /// The environment-variable form, for shells and CI where a context is overkill.
    static func dockerHostExport(socketPath: String) -> String {
        "export DOCKER_HOST=unix://\(socketPath)"
    }

    /// The roadmap document, when this build can find it on disk.
    ///
    /// Checked rather than hard-coded to a URL: Morbstack has no published docs site
    /// yet, and a button that opens a 404 is worse than no button. `MORBSTACK_REPO`
    /// covers the from-source case, the bundle covers a packaged app that ships docs.
    static func roadmapFile() -> URL? {
        let candidates: [URL?] = [
            ProcessInfo.processInfo.environment["MORBSTACK_REPO"].map {
                URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
                    .appendingPathComponent("docs/roadmap.md")
            },
            Bundle.main.url(forResource: "roadmap", withExtension: "md"),
            Bundle.main.resourceURL?.appendingPathComponent("docs/roadmap.md"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
