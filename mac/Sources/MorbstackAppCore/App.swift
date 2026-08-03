// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The app shell: scenes, the split view, the sidebar, and the keyboard map.
//
// Everything below the sidebar's selection belongs to another track. This file's whole
// job is to give those views a window that feels like it was made by people who use
// macOS: a material sidebar that gets out of the way, a detail pane with room to
// breathe, an engine state that is legible at a glance from across the desk, and a
// keyboard path to every screen. If the app is ugly, it is ugly here first.

import AppKit
import SwiftUI

// MARK: - Entry point

/// Scene identifiers.
///
/// The main window needs a stable id so that `openWindow(id:)` can bring it back after
/// the user has closed it — the menu bar's "Open Morbstack" is otherwise a dead end,
/// because a `WindowGroup` with no identifier cannot be addressed.
enum MorbWindowID {
    static let main = "morbstack.main"
}

/// The app scene graph.
///
/// `public`, and without `@main`, because the entry point lives in the thin
/// `MorbstackApp` executable target that links this library: `MorbstackMainApp.main()`.
/// `@main` here would be an entry point in a library, which SwiftPM will not accept.
public struct MorbstackMainApp: App {

    /// The launch-resilience delegate. See `AppLaunchRescue.swift` for why an otherwise
    /// delegate-free SwiftUI app has one: macOS can hand this bundle a wedged window
    /// restoration store, and the only place to notice that and recover is an
    /// `applicationDidFinishLaunching` callback.
    @NSApplicationDelegateAdaptor(MorbAppDelegate.self) private var appDelegate

    /// Captured so the rescue can create a window before any view has ever appeared.
    ///
    /// `RootWindow.onAppear` also installs this, but by definition that never runs in the
    /// failure being defended against — there is no window, so nothing appears.
    @Environment(\.openWindow) private var openWindow

    @State private var model: AppModel
    @State private var isPalettePresented = false

    /// Track D's General settings toggle. Bound to `MenuBarExtra(isInserted:)` so the
    /// switch actually removes the status item rather than just recording a preference.
    @AppStorage(TrackDPreferences.showMenuBarIcon) private var showMenuBarIcon = true

    private let options: LaunchOptions

    public init() {
        let options = LaunchOptions()
        self.options = options
        // `.forLaunch` picks fixture-backed clients under `--tour-fixtures` — see
        // `AppModel.forLaunch(_:)` — so this stays a one-line call regardless of what
        // that flag ends up wiring in.
        _model = State(initialValue: AppModel.forLaunch(options))
    }

    /// The binding behind `MenuBarExtra(isInserted:)`.
    ///
    /// Idempotent on purpose. Handing `$showMenuBarIcon` straight to `MenuBarExtra`
    /// spins a core: the scene writes the same value back to the binding on every
    /// update, `@AppStorage` treats each write as a change, and the resulting
    /// defaults-changed notification invalidates the scene again — a closed loop that
    /// keeps SwiftUI rebuilding the main menu forever. Dropping writes that do not
    /// change the value breaks the cycle while leaving the Settings toggle live.
    private var menuBarInserted: Binding<Bool> {
        Binding(
            get: { showMenuBarIcon },
            set: { newValue in
                guard newValue != showMenuBarIcon else { return }
                showMenuBarIcon = newValue
            })
    }

    public var body: some Scene {
        // Hand the launch rescue a way to make a window. Evaluating the scene graph is
        // the earliest point at which `openWindow` exists, and it happens during launch
        // whether or not a window is ever produced — which is exactly the case that needs
        // it. Assigning from `body` is a side effect, but an idempotent one that stores a
        // closure and reads no state.
        let _ = MorbWindowOpener.installOpenWindow { openWindow(id: MorbWindowID.main) }

        WindowGroup(id: MorbWindowID.main) {
            RootWindow(model: model, options: options, isPalettePresented: $isPalettePresented)
                // A forced appearance is a tour switch, so `nil` — the ordinary case —
                // must leave the system's own choice completely alone.
                .preferredColorScheme(options.appearance)
        }
        .defaultSize(
            width: options.windowSize?.width ?? 1180,
            height: options.windowSize?.height ?? 760)
        .commands {
            MorbCommands(model: model, isPalettePresented: $isPalettePresented)
        }
        // `.unified`, and emphatically **not** `.unifiedCompact(showsTitle: false)`,
        // which is what shipped before this pass.
        //
        // Measured on the real window rather than inferred: `showsTitle: false` sets
        // `NSWindow.titleVisibility = .hidden`, and that suppresses the *subtitle* as
        // well as the title. Every screen was dutifully setting `.navigationTitle` and
        // `.navigationSubtitle` and the window was throwing both away, which is the
        // whole reason the titlebar read as empty. `.unified` is what Finder, Mail and
        // System Settings use: one bar carrying title, subtitle and toolbar items.
        .windowToolbarStyle(.unified)

        // `.window` rather than the default `.menu`: the popover is a laid-out SwiftUI
        // view with its own header, rows and footer, and `.menu` would try to render it
        // as a list of menu items and mangle it.
        MenuBarExtra(isInserted: menuBarInserted) {
            MorbMenuBarContent(model: model)
        } label: {
            MorbMenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            MorbSettingsView(model: model)
                .preferredColorScheme(options.appearance)
        }
    }
}

// MARK: - Commands

/// The menu bar's own commands, and with them every keyboard shortcut in the app.
///
/// Shortcuts live here rather than on the views they act on so that they work from
/// anywhere in the window — including while a text field has focus, which is exactly
/// when you most want ⌘R to still mean refresh.
struct MorbCommands: Commands {

    let model: AppModel
    @Binding var isPalettePresented: Bool
    @FocusedValue(\.imageArchiveExportAction) private var imageArchiveExportAction

    var body: some Commands {
        // Keep the system's View > Show Sidebar command and add document navigation
        // immediately after it.  That gives every toolbar/sidebar command a standard
        // menu and keyboard equivalent without replacing a system command group.
        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(Nav.allCases) { nav in
                Button {
                    model.selection = nav
                } label: {
                    Label(nav.title, systemImage: nav.symbol)
                }
                .keyboardShortcut(
                    KeyEquivalent(Character("\(nav.shortcutIndex)")), modifiers: .command)
            }
        }

        CommandMenu("Engine") {
            Button("Refresh") {
                Task { await model.refreshAll() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!model.engine.isRunning)

            Divider()

            Button("Start Engine") { Task { await model.engineAction(.start) } }
                .disabled(model.engine.isRunning || model.isEngineBusy)
            Button("Free Engine Memory") { Task { await model.engineAction(.suspend) } }
                .disabled(!model.engine.isRunning || model.isEngineBusy)
            Button("Stop Engine") { Task { await model.engineAction(.stop) } }
                .disabled(!model.engine.reachable || model.isEngineBusy)
        }

        CommandMenu("Image") {
            Button("Export Selected Image…") {
                imageArchiveExportAction?()
            }
            .disabled(imageArchiveExportAction == nil)
        }

        CommandGroup(after: .newItem) {
            Button("Command Palette…") { isPalettePresented = true }
                .keyboardShortcut("k", modifiers: .command)
        }
    }
}

// MARK: - Root window

struct RootWindow: View {

    @Bindable var model: AppModel
    let options: LaunchOptions
    @Binding var isPalettePresented: Bool

    @Environment(\.openWindow) private var openWindow
    @State private var cliSetup = FirstRunCLISetupModel()
    @State private var isCLISetupPresented = false

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(
                    min: 180, ideal: 220, max: 280)
        } detail: {
            DetailHost(model: model)
                .frame(minWidth: 620, minHeight: 420)
        }
        // No `.navigationTitle` here. The window's title belongs to whatever is in the
        // detail column, and setting it at the split view as well produced a window
        // whose title never changed with the content and whose subtitle was always
        // empty — see `DetailHost`, which now owns both for every state it can be in.
        //
        // No `.navigationSplitViewStyle` either: the default is the two-column macOS
        // behaviour every first-party app uses, and `.balanced` was buying nothing.
        //
        // The sidebar's material comes from the split view itself. Asking for it again
        // on the `List` would double the blur and make the sidebar visibly murkier than
        // every other app on screen.
        .frame(minWidth: 880, minHeight: 540)
        .background(WindowConfigurator(size: options.windowSize))
        .task {
            await model.bootstrap()
            // `--tour-capture <dir>`: exercise the real window after `bootstrap()` so
            // a `--tour-fixtures` run has populated the model before the probe walks
            // each screen. It rejects AppKit's incomplete view-cache route rather than
            // pretending to photograph Tahoe window chrome. See `Shots/LiveCapture.swift`.
            if options.tourCapture != nil {
                await LiveCaptureRunner.run(model: model, options: options)
            }
        }
        // Capture and fixture runs must remain deterministic route probes, not an
        // installation prompt whose visibility depends on the host's
        // shell profile.  Ordinary launches calculate the plan before presenting this
        // sheet; calculating it makes no changes to the machine.
        .task {
            guard !suppressesFirstRunSetup else { return }
            await cliSetup.prepare()
            if cliSetup.requiresConsent {
                isCLISetupPresented = true
            }
        }
        .sheet(isPresented: $isPalettePresented) {
            // ⌘K is not initiated by a stable source control, so an anchored popover
            // would be semantically false.  A document-modal sheet keeps the command
            // surface attached to the window it operates on and lets AppKit supply the
            // dimming, focus, Escape handling, sizing, and Tahoe material treatment.
            CommandPalette(model: model, isPresented: $isPalettePresented)
                .frame(minWidth: 480, idealWidth: 560, minHeight: 360, idealHeight: 520)
        }
        .sheet(isPresented: $isCLISetupPresented) {
            FirstRunCLISetupSheet(model: cliSetup, isPresented: $isCLISetupPresented)
        }
        // The two cross-track hooks Track D asked for. Installed from the window rather
        // than from `init` because `openWindow` is an environment action and only exists
        // inside a scene's view tree.
        .onAppear {
            TrackDAppBridge.openMainWindow = { openWindow(id: MorbWindowID.main) }
            TrackDAppBridge.showLogs = { id in model.requestLogsTab(for: id) }
            // `--tour-capture`'s palette screen: see `Shots/LiveCapture.swift`. `nil` —
            // a no-op — on every launch that never asks `LiveCaptureBridge` to fire it.
            LiveCaptureBridge.setPalettePresented = { isPalettePresented = $0 }
        }
    }

    /// Tour fixtures, captures and window diagnostics run in developer automation.
    /// They should never invite that automation to change its own real user account.
    private var suppressesFirstRunSetup: Bool {
        options.isTour || options.tourCapture != nil || options.tourFixtures
            || options.dumpWindow || options.dumpFile != nil
    }
}

// MARK: - Sidebar

/// The one section boundary in the app that reflects how someone actually thinks about
/// the product: things you run, and things that back them.
private enum SidebarSection: String, CaseIterable, Identifiable {
    case workloads = "Workloads"
    case resources = "Resources"
    case utilities = "Utilities"

    var id: String { rawValue }

    var items: [Nav] {
        switch self {
        case .workloads: return [.containers, .stacks, .kubernetes]
        case .resources: return [.images, .volumes, .networks, .builds, .disk]
        case .utilities: return [.migration]
        }
    }
}

/// The sidebar, drawn entirely by the system.
///
/// Everything this used to do by hand is gone, and the deletions are the feature:
///
/// - **No branded header.** A "Morbstack v0.4.2" card at the top is chrome no first-party
///   app has; the app's name lives in the menu bar and the Dock. It also broke the window:
///   wrapping the `List` in a `VStack` meant the sidebar's material stopped at the top of
///   the header instead of running up behind the traffic lights, which is what put a dead
///   opaque strip across the top of the window.
/// - **No `NavRow`.** Selection is `List(selection:)` + `.listStyle(.sidebar)`, so macOS
///   draws its own capsule in the user's accent colour — the same selection Finder, Mail
///   and Xcode draw. We do not tint it to brand indigo: sidebar selection is system
///   chrome, and following the user's accent is the native behaviour.
/// - **No hand-drawn count pills.** `.badge()` is the sidebar count macOS already has.
struct Sidebar: View {

    @Bindable var model: AppModel

    var body: some View {
        sidebarWithStatus
    }

    private var sidebarList: some View {
        List(selection: $model.selection) {
            ForEach(SidebarSection.allCases) { section in
                Section(section.rawValue) {
                    ForEach(section.items) { nav in
                        Label(nav.title, systemImage: nav.symbol)
                            .badge(badge(for: nav))
                            .tag(nav)
                            .help("\(nav.title) (⌘\(nav.shortcutIndex))")
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var sidebarWithStatus: some View {
        if #available(macOS 26.0, *) {
            sidebarList.safeAreaBar(edge: .bottom, spacing: 0) {
                EngineFooter(model: model)
            }
        } else {
            sidebarList.safeAreaInset(edge: .bottom, spacing: 0) {
                EngineFooter(model: model)
            }
        }
    }

    /// The trailing count on a row, when there is a number worth knowing.
    ///
    /// Only sections whose count changes on its own get one. A badge on Networks that
    /// permanently reads "3" is furniture, not information.
    private func badge(for nav: Nav) -> Text? {
        guard model.engine.isRunning else { return nil }
        switch nav {
        case .containers:
            return model.runningCount > 0 ? Text(model.runningCount, format: .number) : nil
        case .stacks:
            let count = model.composeGroups.filter { $0.project != nil }.count
            return count > 0 ? Text(count, format: .number) : nil
        default: return nil
        }
    }
}

// MARK: - Engine footer

/// The status command in the sidebar's system-owned bottom bar.
///
/// This is deliberately a native `Menu`, not a custom status pill. The label gives the
/// current engine state a concise, textual representation; the menu is the appropriate
/// home for secondary lifecycle actions and the sharing warning. `safeAreaBar` supplies
/// the Tahoe bar treatment, and `safeAreaInset` is the native fallback on older macOS.
struct EngineFooter: View {

    @Bindable var model: AppModel

    var body: some View {
        Menu {
            Text(subtitle)

            if let chip = model.fileSharingChip {
                Divider()
                SettingsLink {
                    Text(chip.text)
                }
            }

            if !availableActions.isEmpty {
                Divider()
                ForEach(availableActions, id: \.rawValue) { action in
                    Button(engineActionTitle(action)) {
                        Task { await model.engineAction(action) }
                    }
                    .disabled(model.isEngineBusy)
                }
            }
        } label: {
            Label(model.engine.headline, systemImage: statusSymbol)
                .lineLimit(1)
                .monospacedDigit()
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .help(tooltip)
        .accessibilityHint("Shows engine details and actions")
    }

    private var availableActions: [EngineAction] {
        guard model.engine.reachable else { return [.start] }
        switch model.engine.state {
        case "running": return [.suspend, .stop]
        case "suspended": return [.start, .stop]
        case "starting", "stopping", "pausing": return []
        default: return [.start]
        }
    }

    private var statusSymbol: String {
        switch model.engine.state {
        case "running": return "checkmark.circle"
        case "suspended": return "pause.circle"
        case "starting", "stopping", "pausing": return "arrow.triangle.2.circlepath.circle"
        case "error": return "exclamationmark.triangle"
        default: return "stop.circle"
        }
    }

    private func engineActionTitle(_ action: EngineAction) -> String {
        switch action {
        case .start: return "Start Engine"
        case .suspend: return "Free Engine Memory"
        case .stop: return "Stop Engine"
        }
    }

    private var subtitle: String {
        var details = ["VM: \(model.engine.vmState)"]
        if let version = model.engine.version { details.append("morbstackd \(version)") }
        if let chip = model.fileSharingChip { details.append(chip.detail) }
        return details.joined(separator: "\n")
    }

    private var tooltip: String {
        let socket = model.engine.reachable ? "Control socket: connected" : "Control socket: unavailable"
        return "\(subtitle)\n\(socket)"
    }
}

// MARK: - Detail host

/// Chooses what fills the detail pane.
///
/// Three cases, in priority order, and the order is the point: an app that shows an
/// empty containers table when the engine is off has told the user something false.
struct DetailHost: View {

    @Bindable var model: AppModel

    var body: some View {
        // No painted background. The detail column of a `NavigationSplitView` already
        // owns the content surface; adding another opaque layer makes the column read
        // as a web panel instead of part of the window.
        Group {
            if !model.hasLoaded {
                // Titled even here, so the window is never chrome-less for the few
                // milliseconds before the daemon answers.
                LoadingView()
                    .navigationTitle(model.selection.title)
                    .navigationSubtitle("Connecting…")
            } else if !model.engine.isRunning && model.selection != .migration {
                EngineStoppedView(model: model)
                    .navigationTitle(model.selection.title)
                    .navigationSubtitle(model.engine.headline)
            } else {
                // Each screen sets its own title, subtitle, search field and actions.
                content
            }
        }
        // The one toolbar item that is true on every screen in every state. It is a
        // standard toolbar command rather than a separately drawn control, so AppKit
        // can collapse it with the screen's contextual actions as the window narrows.
        .toolbar { refreshItem }
        .alert("Unable to Complete Operation", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.lastError ?? "An unknown error occurred.")
        }
        // `refreshAll` deliberately skips `/system/df` — it can take tens of seconds on
        // a large store — so the Disk screen has to ask for its own data when it is
        // opened. Doing it here rather than inside the screen keeps the rule ("the
        // expensive endpoint is fetched only when it is being looked at") in the same
        // file as the decision not to include it in the ordinary refresh.
        .task(id: model.selection) {
            guard model.selection == .disk else { return }
            await model.refreshDisk()
        }
        .task(id: model.selection) {
            guard model.selection == .builds else { return }
            await model.refreshBuildCache()
        }
    }

    /// Refresh, in the toolbar, on every screen.
    ///
    /// `.primaryAction` rather than `.automatic` so it lands with the screens' own
    /// actions rather than beside the sidebar toggle, and a `Label` rather than a bare
    /// `Image` so it has an accessibility name and a Customize Toolbar title.
    @ToolbarContentBuilder
    private var refreshItem: some ToolbarContent {
        ToolbarItem(id: "app.refresh", placement: .primaryAction) {
            Button {
                Task { await model.refreshAll() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(!model.engine.isRunning)
            .help("Refresh everything (⌘R)")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.selection {
        case .containers: ContainersRootView(model: model)
        case .stacks: StacksRootView(model: model)
        case .images: ImagesRootView(model: model)
        case .volumes: VolumesRootView(model: model)
        case .networks: NetworksRootView(model: model)
        case .disk: DiskRootView(model: model)
        case .kubernetes: KubernetesRootView(model: model)
        case .builds: BuildsRootView(model: model)
        case .migration: MigrationRootView(model: model)
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { model.lastError != nil },
            set: { isPresented in
                if !isPresented { model.dismissError() }
            })
    }
}

/// The brief moment before the daemon has answered.
///
/// Bootstrap is usually quick, but waiting for a guest can be visible. A standard
/// progress indicator communicates work without fabricating a content surface.
private struct LoadingView: View {
    var body: some View {
        ProgressView("Connecting…")
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Engine stopped

/// What fills the window when there is no engine.
///
/// The most important screen in the app, because it is the first one a new user sees,
/// and it is the only one whose job is to make somebody press a button. So: one
/// sentence explaining the situation, one obvious control, and no table of zeroes
/// pretending to be data.
struct EngineStoppedView: View {

    @Bindable var model: AppModel

    private var isStarting: Bool { model.isEngineBusy || model.engine.isTransitional }

    var body: some View {
        ContentUnavailableView(
            label: {
                Label(title, systemImage: "server.rack")
            },
            description: {
                Text(explanation)
            },
            actions: {
                if isStarting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task { await model.engineAction(.start) }
                    } label: {
                        Label(
                            "Start Engine",
                            systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
                }
            })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        if isStarting { return "Starting the engine…" }
        switch model.engine.state {
        case "suspended": return "Engine suspended"
        case "error": return "The engine hit a problem"
        default: return "The engine isn’t running"
        }
    }

    private var explanation: String {
        if isStarting {
            return "Booting the virtual machine and waiting for Docker to come up. This usually takes a few seconds."
        }
        switch model.engine.state {
        case "suspended":
            return "The engine is not running. Start it from persisted Docker data; images, containers and volumes remain, but don’t rely on running containers surviving."
        case "error":
            return "Morbstack could not bring the virtual machine up. Run morb doctor in a terminal for a full diagnosis."
        default:
            return "Start it to see your containers, images and volumes. Nothing runs on your Mac until you do."
        }
    }
}

// MARK: - Window configuration

/// Applies `--window-size` to the real `NSWindow`.
///
/// SwiftUI's `.defaultSize` only applies to a window with no saved frame, which makes it
/// unsuitable for repeatable review: the second run inherits the first run's size from
/// the restoration store. Reaching for the `NSWindow` is the only way to apply the
/// explicit size requested by developer automation.
private struct WindowConfigurator: NSViewRepresentable {

    let size: CGSize?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        guard let size else { return view }
        // The view has no window until it is in the hierarchy, which happens after
        // `makeNSView` returns.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.setContentSize(size)
            window.center()
            // Restoration would otherwise overwrite the requested size on the next
            // launch with whatever the user last dragged the window to.
            window.isRestorable = false
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
