// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The launch rescue: making sure the app actually has a window.
//
// This file exists because of a real failure mode on a real machine. macOS keeps a
// per-bundle-identifier window restoration store, and that store can get wedged: the
// launch logs `hasPersistentStateToRestore=1`, AppKit decides restoration will produce
// the windows, SwiftUI's `WindowGroup` therefore does not create one, restoration then
// produces nothing, and the app sits in the Dock with no window and no way back other
// than quitting. The same bytes under a different bundle identifier show a window on
// every launch, so it is state, not code — but "it is the operating system's fault" is
// not something a user can act on, so the app has to defend itself.
//
// The defence has three layers, in the order they run:
//
//   1. `NSQuitAlwaysKeepsWindows = false` in Info.plist, so the app stops feeding the
//      restoration store in the first place.
//   2. A post-launch sweep (this file). A short while after launch, if no presentable
//      window exists, force one open — existing-window first, then the SwiftUI
//      `openWindow` action, then the File menu's New Window item. Retried a few times
//      because "restoration produced zero windows" resolves later than
//      `applicationDidFinishLaunching`.
//   3. If the sweep had to intervene, delete *our own* saved-state directory, so the
//      next launch starts from a clean store. That directory is the app's own data,
//      keyed by its own bundle identifier; nothing here touches user configuration.
//
// The decision logic is deliberately expressed over a plain value type
// (``MorbWindowSnapshot``) rather than over `NSWindow`, so the rules that decide "is
// there a window?" and "which directory may we delete?" are unit-testable without an
// `NSApplication`.

import AppKit
import SwiftUI

// MARK: - Window snapshot

/// What the rescue needs to know about one `NSWindow`.
///
/// A value type on purpose: the interesting part of this file is a handful of
/// predicates, and predicates over `NSWindow` can only be exercised by launching a GUI.
struct MorbWindowSnapshot: Equatable, Sendable {

    var identifier: String
    var title: String
    var isVisible: Bool
    var canBecomeMain: Bool
    var isMiniaturized: Bool
    var width: Double
    var height: Double

    init(
        identifier: String = "",
        title: String = "",
        isVisible: Bool = false,
        canBecomeMain: Bool = false,
        isMiniaturized: Bool = false,
        width: Double = 0,
        height: Double = 0
    ) {
        self.identifier = identifier
        self.title = title
        self.isVisible = isVisible
        self.canBecomeMain = canBecomeMain
        self.isMiniaturized = isMiniaturized
        self.width = width
        self.height = height
    }

    @MainActor
    init(_ window: NSWindow) {
        self.init(
            identifier: window.identifier?.rawValue ?? "",
            title: window.title,
            isVisible: window.isVisible,
            canBecomeMain: window.canBecomeMain,
            isMiniaturized: window.isMiniaturized,
            width: Double(window.frame.width),
            height: Double(window.frame.height))
    }

    /// The Settings scene's window, which must never be mistaken for the main window.
    ///
    /// Settings can legitimately be the only window on screen (⌘, from the menu bar with
    /// the main window closed); treating it as "the app has a window" would make the
    /// rescue a no-op in exactly the case it is meant to fix, and treating it as a window
    /// to bring forward would fight the user.
    var isSettingsWindow: Bool {
        let identifier = identifier.lowercased()
        if identifier.contains("com_apple_swiftui_settings") { return true }
        if identifier.contains("settings") { return true }
        return title == "Settings"
    }

    /// Big enough to be a real UI rather than a zero-sized placeholder.
    ///
    /// AppKit keeps several offscreen 0×0 or tiny utility windows around (the
    /// `MenuBarExtra` host among them), and counting one of those as the main window
    /// would let a windowless launch report success.
    var isUsableSize: Bool { width >= 200 && height >= 200 }

    /// `true` when this window is, right now, the thing the user came for.
    var isPresentableMainWindow: Bool {
        canBecomeMain && isVisible && !isMiniaturized && !isSettingsWindow && isUsableSize
    }

    /// `true` when this window could be brought back without creating a new one.
    ///
    /// Wider than ``isPresentableMainWindow``: a hidden, miniaturised or not-yet-ordered
    /// window is a window, and `makeKeyAndOrderFront` is cheaper and less surprising than
    /// opening a second one.
    var isRevivableMainWindow: Bool {
        canBecomeMain && !isSettingsWindow && isUsableSize
    }
}

// MARK: - Decision rules

/// The pure half of the launch rescue.
enum MorbLaunchRescue {

    /// `true` when the app has no window the user can see and needs one made.
    static func needsRescue(_ windows: [MorbWindowSnapshot]) -> Bool {
        !windows.contains(where: \.isPresentableMainWindow)
    }

    /// The window to bring forward, if the app already has one to bring forward.
    ///
    /// Prefers a window that is already on screen; among the rest, the first is as good
    /// a choice as any, because a `WindowGroup` that has produced two hidden windows is
    /// already in a state nobody designed.
    static func revivableIndex(_ windows: [MorbWindowSnapshot]) -> Int? {
        let revivable = windows.indices.filter { windows[$0].isRevivableMainWindow }
        return revivable.first(where: { windows[$0].isVisible && !windows[$0].isMiniaturized })
            ?? revivable.first
    }
}

// MARK: - Saved state

/// The app's own window-restoration store.
///
/// Everything here is guarded on the bundle identifier: the only directories this type
/// will ever name are `<identifier>.savedState`, for the identifier the running bundle
/// declares. It cannot be pointed at another app's state, and it cannot be pointed at a
/// directory whose name it did not construct itself.
enum MorbSavedState {

    /// The suffix AppKit gives every restoration store.
    static let suffix = ".savedState"

    /// Rejects anything that is not a plausible bundle identifier.
    ///
    /// The check is not cosmetic: this string is about to become the last component of a
    /// path passed to `removeItem`, so a `..`, a `/`, or an empty value has to be
    /// impossible rather than merely unlikely.
    static func isSafeBundleIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty, identifier.count <= 200 else { return false }
        guard !identifier.hasPrefix("."), !identifier.hasSuffix(".") else { return false }
        guard !identifier.contains("..") else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        return identifier.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Every place this app's restoration store is known to live, most likely first.
    ///
    /// Three candidates rather than one because the location is not stable across macOS
    /// configurations: an ordinary app's store is under `~/Library/Saved Application
    /// State`, but on this machine the failing store lives in the per-user darwin temp
    /// directory, and code signed differently again can land one level up from it.
    /// Naming all three costs nothing — each is an exact-name match that either exists or
    /// does not.
    static func candidateDirectories(
        bundleID: String,
        temporaryDirectory: URL,
        homeDirectory: URL
    ) -> [URL] {
        guard isSafeBundleIdentifier(bundleID) else { return [] }
        let name = bundleID + suffix
        let temporary = temporaryDirectory.standardizedFileURL
        return [
            temporary.appendingPathComponent(name, isDirectory: true),
            temporary.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true),
            homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Saved Application State", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true),
        ]
    }

    /// Last line of defence before `removeItem`: the path must be a directory whose name
    /// is exactly this bundle's `<identifier>.savedState`.
    static func isRemovable(_ url: URL, bundleID: String) -> Bool {
        guard isSafeBundleIdentifier(bundleID) else { return false }
        return url.standardizedFileURL.lastPathComponent == bundleID + suffix
    }

    /// Deletes this app's restoration store wherever it is, and returns what it deleted.
    @discardableResult
    static func purge(
        bundleID: String,
        temporaryDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        fileManager: FileManager = .default
    ) -> [String] {
        var removed: [String] = []
        for url in candidateDirectories(
            bundleID: bundleID, temporaryDirectory: temporaryDirectory, homeDirectory: homeDirectory)
        {
            guard isRemovable(url, bundleID: bundleID) else { continue }
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
                removed.append(url.path)
            } catch {
                MorbLaunchLog.write("saved-state purge failed for \(url.path): \(error)")
            }
        }
        return removed
    }
}

// MARK: - Logging

/// Launch diagnostics, on stderr.
///
/// stderr rather than `os_log` so that `Contents/MacOS/MorbstackApp --tour-dump-window`
/// run straight from a shell is self-explaining, which is the whole point of that flag.
enum MorbLaunchLog {

    static let prefix = "morbstack-launch:"

    static func write(_ message: String) {
        FileHandle.standardError.write(Data("\(prefix) \(message)\n".utf8))
    }
}

// MARK: - Opening a window

/// The imperative half of the launch rescue.
@MainActor
enum MorbWindowOpener {

    /// SwiftUI's `openWindow(id:)`, captured from a scene.
    ///
    /// Installed as early as the scene graph is evaluated — before any window exists —
    /// which is what makes it usable from `applicationDidFinishLaunching`.
    private(set) static var openMainWindow: (() -> Void)?

    static func installOpenWindow(_ action: @escaping () -> Void) {
        openMainWindow = action
        // The Track D hooks and this one are the same capability; keeping them in step
        // means the menu bar's "Open Morbstack" also works before the first window has
        // ever appeared, instead of only after `RootWindow.onAppear` has run.
        if TrackDAppBridge.openMainWindow == nil {
            TrackDAppBridge.openMainWindow = action
        }
    }

    static func snapshots() -> [MorbWindowSnapshot] {
        NSApp.windows.map(MorbWindowSnapshot.init)
    }

    /// Brings the app's main window back, creating one if there is nothing to bring back.
    ///
    /// Three strategies, cheapest first. The last one exists because the first two can
    /// both be unavailable in the failure this file is about: there is no window to
    /// revive, and if the scene graph never ran, no `openWindow` action was captured
    /// either. The File menu's New Window item is installed by AppKit from the
    /// `WindowGroup` itself and survives both.
    @discardableResult
    static func reveal() -> Bool {
        NSApp.activate()

        let windows = NSApp.windows
        let snapshots = windows.map(MorbWindowSnapshot.init)
        if let index = MorbLaunchRescue.revivableIndex(snapshots) {
            let window = windows[index]
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            MorbLaunchLog.write("revealed existing window \(snapshots[index].identifier)")
            return true
        }

        if let openMainWindow {
            openMainWindow()
            MorbLaunchLog.write("opened main window via openWindow(id:)")
            return true
        }

        if performNewWindowMenuItem() {
            MorbLaunchLog.write("opened main window via the File ▸ New Window menu item")
            return true
        }

        MorbLaunchLog.write("no way to open a window: no live window, no openWindow action, no menu item")
        return false
    }

    /// Fires the `WindowGroup`'s own New Window command.
    ///
    /// Matched on ⌘N rather than on a title, because the title is localised and the key
    /// equivalent is not.
    static func performNewWindowMenuItem() -> Bool {
        guard let mainMenu = NSApp.mainMenu else { return false }
        guard let item = newWindowMenuItem(in: mainMenu) else { return false }
        guard let menu = item.menu, let index = menu.items.firstIndex(of: item) else { return false }
        menu.performActionForItem(at: index)
        return true
    }

    private static func newWindowMenuItem(in menu: NSMenu, depth: Int = 0) -> NSMenuItem? {
        guard depth < 4 else { return nil }
        menu.update()
        for item in menu.items {
            if item.keyEquivalent == "n",
                item.keyEquivalentModifierMask == [.command],
                item.action != nil
            {
                return item
            }
            if let submenu = item.submenu, let found = newWindowMenuItem(in: submenu, depth: depth + 1) {
                return found
            }
        }
        return nil
    }
}

// MARK: - Window dump

/// `--tour-dump-window`: proof, on stdout, that the app has a window.
///
/// Verifying this any other way means a screen recording or an accessibility client.
/// The app already knows the answer exactly, so it may as well say so: two seconds after
/// launch — long enough for the rescue sweeps to have finished — print every window it
/// has and exit.
enum MorbWindowDump {

    static let prefix = "morbstack-window-dump:"

    /// The report, as a deterministic multi-line string.
    ///
    /// Rendered from snapshots rather than printed inline so the format is pinned by a
    /// test instead of by whoever next edits the print statement.
    static func render(_ windows: [MorbWindowSnapshot]) -> String {
        let presentable = windows.filter(\.isPresentableMainWindow)
        var lines = [
            "\(prefix) windows=\(windows.count) presentable=\(presentable.count)"
        ]
        for (index, window) in windows.enumerated() {
            lines.append(
                "\(prefix) [\(index)]"
                    + " id=\(window.identifier.isEmpty ? "-" : window.identifier)"
                    + " title=\"\(window.title)\""
                    + " visible=\(window.isVisible ? 1 : 0)"
                    + " canBecomeMain=\(window.canBecomeMain ? 1 : 0)"
                    + " miniaturized=\(window.isMiniaturized ? 1 : 0)"
                    + " frame=\(Int(window.width.rounded()))x\(Int(window.height.rounded()))"
                    + " presentable=\(window.isPresentableMainWindow ? 1 : 0)")
        }
        lines.append("\(prefix) result=\(presentable.isEmpty ? "NO-WINDOW" : "OK")")
        return lines.joined(separator: "\n")
    }

    /// Writes the report to stdout, and to a file when one was asked for.
    ///
    /// The file copy is not redundancy for its own sake: `open -n Morbstack.app` — the
    /// way the app is actually launched — discards stdout and does not pass the shell's
    /// environment through, so a run started that way has nowhere else to leave its
    /// evidence and no way to be told where. Hence both a flag and an environment
    /// variable: `--tour-dump-file` survives `open --args`, `MORB_TOUR_DUMP_FILE` is
    /// the convenient form for a direct exec.
    static func emit(
        _ report: String,
        file: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        FileHandle.standardOutput.write(Data((report + "\n").utf8))
        let candidates = [file, environment["MORB_TOUR_DUMP_FILE"]]
        guard let path = candidates.compactMap({ $0 }).first(where: { !$0.isEmpty }) else { return }
        try? (report + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}

// MARK: - App delegate

/// The app delegate, which exists for exactly one reason: launch resilience.
///
/// SwiftUI does not need a delegate to run this app. It needs one to promise secure
/// state restoration, to be told about Dock re-opens, and to get a callback late enough
/// after launch to notice that restoration produced nothing.
final class MorbAppDelegate: NSObject, NSApplicationDelegate {

    /// When the sweeps run, in seconds after `applicationDidFinishLaunching`.
    ///
    /// Three of them, ending comfortably before the two-second window dump. The first is
    /// as early as is useful (a healthy launch has its window well before then, so the
    /// common case does nothing at all); the later two cover a restoration that finishes
    /// late and then produces no window.
    static let sweepDelays: [Double] = [0.35, 0.9, 1.5]

    /// How long `--tour-dump-window` waits before reporting.
    static let dumpDelay: Double = 2.0

    private let options: LaunchOptions
    private var didPurgeSavedState = false
    private var didRescue = false

    override init() {
        options = LaunchOptions()
        super.init()
    }

    init(options: LaunchOptions) {
        self.options = options
        super.init()
    }

    // MARK: NSApplicationDelegate

    /// Required on macOS 14+; without it AppKit logs a warning and falls back to the
    /// insecure coder. Restoration is not something this app relies on, but the app is
    /// signed and should not be asking for the legacy path.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        for delay in Self.sweepDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.sweep()
            }
        }
        if options.dumpWindow {
            let dumpFile = options.dumpFile
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.dumpDelay) {
                MorbWindowDump.emit(
                    MorbWindowDump.render(MorbWindowOpener.snapshots()), file: dumpFile)
                exit(0)
            }
        }
    }

    /// Clicking the Dock icon must always produce a window, including when the reason
    /// there is no window is the bug this file is about.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if MorbLaunchRescue.needsRescue(MorbWindowOpener.snapshots()) {
            MorbWindowOpener.reveal()
        }
        return true
    }

    // MARK: Sweep

    /// One pass of "does this app have a window, and if not, get one".
    @MainActor
    private func sweep() {
        let snapshots = MorbWindowOpener.snapshots()
        guard MorbLaunchRescue.needsRescue(snapshots) else { return }

        MorbLaunchLog.write(
            "no presentable window after launch (\(snapshots.count) NSWindow(s)); forcing one open")
        didRescue = true
        purgeSavedStateOnce()
        MorbWindowOpener.reveal()
    }

    /// Deletes this app's restoration store, once per launch.
    ///
    /// Only reached when the app has already established that restoration left it with
    /// no window, and only ever names `<our bundle id>.savedState`. It does not fix the
    /// launch it runs on — that is the sweep's job — it stops the next one from starting
    /// in the same hole.
    private func purgeSavedStateOnce() {
        guard !didPurgeSavedState else { return }
        didPurgeSavedState = true
        guard let bundleID = Bundle.main.bundleIdentifier else {
            MorbLaunchLog.write("no bundle identifier; not touching any saved state")
            return
        }
        let removed = MorbSavedState.purge(bundleID: bundleID)
        if removed.isEmpty {
            MorbLaunchLog.write("no saved state found for \(bundleID)")
        } else {
            for path in removed { MorbLaunchLog.write("purged own saved state: \(path)") }
        }
    }
}
