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
    @State private var isCLISetupPresented = false

    /// Track D's General settings toggle. Bound to `MenuBarExtra(isInserted:)` so the
    /// switch actually removes the status item rather than just recording a preference.
    @AppStorage(TrackDPreferences.showMenuBarIcon) private var showMenuBarIcon = true

    private let options: LaunchOptions

    public init() {
        // Morbstack has separate windows (the main operations window and Settings),
        // not a tabbed-document model. Letting AppKit synthesize tab commands advertises
        // actions with no meaningful destination, so opt out before WindowGroup creates
        // its first window while retaining the normal New Window behavior.
        NSWindow.allowsAutomaticWindowTabbing = false

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
            RootWindow(
                model: model,
                options: options,
                isPalettePresented: $isPalettePresented,
                isCLISetupPresented: $isCLISetupPresented)
                // A forced appearance is a tour switch, so `nil` — the ordinary case —
                // must leave the system's own choice completely alone.
                .preferredColorScheme(options.appearance)
        }
        .defaultSize(
            width: options.windowSize?.width ?? 1180,
            height: options.windowSize?.height ?? 760)
        .commands {
            MorbCommands(
                model: model,
                isPalettePresented: $isPalettePresented,
                isCLISetupPresented: $isCLISetupPresented)
        }
        // Tahoe owns the titlebar and the standard-window controls.  Request its
        // automatic toolbar style rather than freezing the app into a pre-Tahoe
        // unified metric: AppKit can then select the system's current titlebar height,
        // traffic-light sizing, title/subtitle treatment, and toolbar arrangement.
        // This still deliberately avoids `.unifiedCompact(showsTitle: false)`, whose
        // hidden title also suppresses the route subtitle.
        .windowToolbarStyle(.automatic)

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

/// The current route's refresh command, exposed to the menu bar without coupling the
/// app command graph to an individual route view. A route with a more specific refresh
/// operation can publish this same focused value at its root and replace the shell
/// fallback below.
private struct RouteRefreshActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var routeRefreshAction: (() -> Void)? {
        get { self[RouteRefreshActionKey.self] }
        set { self[RouteRefreshActionKey.self] = newValue }
    }
}

/// One route-scoped collection-maintenance command (prune / remove unused), published
/// by the route that owns it so the menu bar can mirror the toolbar.
///
/// The standing rule is that every important toolbar command has a menu-bar
/// equivalent. Without this, the prune commands lived only in a route's toolbar
/// options menu — and a command that exists only in the toolbar becomes unreachable
/// the moment the system overflows it away at a narrow width.
struct RouteMaintenanceCommand {
    let title: String
    let isEnabled: Bool
    let perform: () -> Void
}

private struct RouteMaintenanceCommandKey: FocusedValueKey {
    typealias Value = RouteMaintenanceCommand
}

extension FocusedValues {
    var routeMaintenanceCommand: RouteMaintenanceCommand? {
        get { self[RouteMaintenanceCommandKey.self] }
        set { self[RouteMaintenanceCommandKey.self] = newValue }
    }
}

/// The selected container's two record commands, published by the Containers route.
///
/// Both live in the toolbar's secondary-action area, which the system is free to
/// overflow away at a narrow width — the same exposure `RouteMaintenanceCommand` exists
/// to close. `canOpenTerminal` is `ContainerTerminalAvailability`'s answer, so the menu
/// item's enablement can never disagree with the toolbar button's.
struct ContainerRecordCommands {
    let canOpenTerminal: Bool
    let openTerminal: () -> Void
    let runCommand: () -> Void
}

private struct ContainerRecordCommandsKey: FocusedValueKey {
    typealias Value = ContainerRecordCommands
}

extension FocusedValues {
    var containerRecordCommands: ContainerRecordCommands? {
        get { self[ContainerRecordCommandsKey.self] }
        set { self[ContainerRecordCommandsKey.self] = newValue }
    }
}

/// The menu bar's own commands, and with them every keyboard shortcut in the app.
///
/// Shortcuts live here rather than on the views they act on so that they work from
/// anywhere in the window — including while a text field has focus, which is exactly
/// when you most want ⌘R to still mean refresh.
struct MorbCommands: Commands {

    let model: AppModel
    @Binding var isPalettePresented: Bool
    @Binding var isCLISetupPresented: Bool
    @FocusedValue(\.routeRefreshAction) private var routeRefreshAction
    @FocusedValue(\.routeMaintenanceCommand) private var routeMaintenanceCommand
    @FocusedValue(\.containerRecordCommands) private var containerRecordCommands
    @FocusedValue(\.imageArchiveExportAction) private var imageArchiveExportAction
    @FocusedValue(\.imageArchiveImportAction) private var imageArchiveImportAction
    @FocusedValue(\.runLocalImageAction) private var runLocalImageAction
    @FocusedValue(\.composeFileEditorCommandActions) private var composeFileEditorCommandActions
    @FocusedValue(\.composeSourceValidationCommandActions) private var composeSourceValidationCommandActions

    /// Keep the Engine menu's enablement aligned with the status extra and the daemon
    /// lifecycle. A reachable control socket does not by itself make every transition
    /// meaningful: a second Start while the VM is already starting, or a Stop after it
    /// has stopped, must not be presented as an available command.
    private var canStartEngine: Bool {
        !model.isEngineBusy && !model.engine.isRunning && !model.engine.isTransitional
    }

    private var canSuspendEngine: Bool {
        !model.isEngineBusy && model.engine.isRunning
    }

    private var canStopEngine: Bool {
        !model.isEngineBusy
            && model.engine.reachable
            && !model.engine.isTransitional
            && (model.engine.state == "running" || model.engine.state == "suspended")
    }

    var body: some Commands {
        // A deferred setup remains available from the standard application menu. This
        // is a command, not an onboarding overlay, and it presents the same scoped
        // document-modal review sheet when someone asks to return to it.
        CommandGroup(after: .appInfo) {
            Button("Set Up Command-Line Tools…") {
                isCLISetupPresented = true
            }
        }

        // Register the platform-owned View commands before extending their group.
        // `NavigationSplitView` and `.inspector` then supply the stateful Show/Hide
        // Sidebar and Show/Hide Inspector actions themselves — including their normal
        // keyboard equivalents and menu enablement — rather than making our toolbar
        // glyphs the only way to recover space at a narrow width.
        SidebarCommands()
        InspectorCommands()

        // Add document navigation after the system sidebar command. This preserves the
        // normal View menu while keeping every top-level destination discoverable even
        // when Tahoe places less-important toolbar controls in its overflow menu.
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
                routeRefreshAction?()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(routeRefreshAction == nil)

            // The selected route's prune command, mirrored from its toolbar options
            // menu so it stays reachable when the toolbar overflows.
            Button(routeMaintenanceCommand?.title ?? "Remove Unused Items…") {
                routeMaintenanceCommand?.perform()
            }
            .disabled(routeMaintenanceCommand?.isEnabled != true)

            Divider()

            Button("Start Engine") { Task { await model.engineAction(.start) } }
                .disabled(!canStartEngine)
            Button("Free Engine Memory") { Task { await model.engineAction(.suspend) } }
                .disabled(!canSuspendEngine)
            Button("Stop Engine") { Task { await model.engineAction(.stop) } }
                .disabled(!canStopEngine)
        }

        // The selected container's own commands, alongside Image's and Compose's. Both
        // items are also in the route's toolbar and its contextual menu; this is the
        // copy that survives toolbar overflow and carries the keyboard shortcut.
        CommandMenu("Container") {
            Button("Open Terminal") {
                containerRecordCommands?.openTerminal()
            }
            // ⌃⌘T rather than ⌘T: ⌘T is the system's Show Fonts equivalent and is the
            // shortcut a person's muscle memory reaches for in a browser tab, neither of
            // which should collide with opening a shell inside a container.
            .keyboardShortcut("t", modifiers: [.control, .command])
            .disabled(containerRecordCommands?.canOpenTerminal != true)

            Button("Run Command…") {
                containerRecordCommands?.runCommand()
            }
            .disabled(containerRecordCommands == nil)
        }

        CommandMenu("Image") {
            Button("Load Image Archive…") {
                imageArchiveImportAction?()
            }
            .disabled(imageArchiveImportAction == nil)

            Button("Run Selected Local Image…") {
                runLocalImageAction?()
            }
            .disabled(runLocalImageAction == nil)

            Divider()

            Button("Export Selected Image…") {
                imageArchiveExportAction?()
            }
            .disabled(imageArchiveExportAction == nil)
        }

        CommandMenu("Compose") {
            Button("Save Project Source File") {
                composeFileEditorCommandActions?.save()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(composeFileEditorCommandActions?.canSave != true)

            Button("Discard Project Source Changes") {
                composeFileEditorCommandActions?.discard()
            }
            .disabled(composeFileEditorCommandActions?.canDiscard != true)

            Divider()

            Button("Validate Compose File…") {
                composeSourceValidationCommandActions?.validate()
            }
            .disabled(composeSourceValidationCommandActions?.canValidate != true)
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
    @Binding var isCLISetupPresented: Bool

    @Environment(\.openWindow) private var openWindow
    @State private var cliSetup = FirstRunCLISetupModel()
    @AppStorage(TrackDPreferences.firstRunCLISetupDeferred)
    private var isCLISetupDeferred = false

    /// Owned here so every launch starts with the sidebar visible. Left to the
    /// system, a collapsed sidebar can be restored across launches — which hides the
    /// engine footer and, under `--tour-fixtures`, the provenance marker with it.
    /// View ▸ Hide Sidebar still works; the choice just does not leak into the next
    /// launch's evidence.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        // The fixture marker that cannot be cropped, collapsed, or mistaken: fixture
        // launches carry a persistent banner across the full window width, laid out
        // ABOVE the split view so no column's content can render beneath it. The
        // window title and sidebar footer also state provenance, but the title is
        // not drawn by Tahoe's toolbar (it shows the route's navigation title) and
        // the footer disappears with the sidebar — a screenshot of either state must
        // still be impossible to file as live evidence.
        VStack(spacing: 0) {
            if let fixture = model.fixtureProvenance {
                FixtureDataBanner(provenance: fixture)
            }
            NavigationSplitView(columnVisibility: $columnVisibility) {
                Sidebar(model: model)
                    .navigationSplitViewColumnWidth(
                        min: 180, ideal: 220, max: 280)
            } detail: {
                DetailHost(model: model)
                    .frame(minWidth: 620, minHeight: 420)
            }
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
        .background(
            WindowConfigurator(
                size: options.windowSize,
                forcedTitle: model.fixtureProvenance?.windowTitle))
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
            guard !suppressesFirstRunSetup, !isCLISetupDeferred else { return }
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
        .sheet(isPresented: $isCLISetupPresented, onDismiss: persistFirstRunDeferralIfNeeded) {
            FirstRunCLISetupSheet(
                model: cliSetup,
                isPresented: $isCLISetupPresented,
                deferFirstRunSetup: { isCLISetupDeferred = true })
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

    private func persistFirstRunDeferralIfNeeded() {
        if cliSetup.shouldPersistFirstRunDeferral {
            isCLISetupDeferred = true
        }
    }
}

// MARK: - Fixture banner

/// The non-dismissible marker on every `--tour-fixtures` window.
///
/// Fixture data is Docker-shaped but fabricated, and a fixture window has already been
/// mistaken for live evidence once. Color is supplemental per the design rulings — the
/// words carry the meaning — but the tinted band survives cropping, sidebar collapse,
/// and a glance from across the desk, which is the whole job.
private struct FixtureDataBanner: View {

    let provenance: FixtureProvenance

    var body: some View {
        Label(provenance.detail, systemImage: "testtube.2")
            .font(.callout)
            .padding(.vertical, 5)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(.yellow.opacity(0.22))
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityIdentifier("app.fixtureBanner")
            .accessibilityLabel(provenance.accessibilityLabel)
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
                            // Automation handle per docs/design/ACCESSIBILITY-IDENTIFIERS.md;
                            // the visible title remains the VoiceOver-facing name.
                            .accessibilityIdentifier("app.sidebar.\(nav.rawValue)")
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

/// Concise engine status in the sidebar's system-owned bottom bar.
///
/// The native bar supplies Tahoe's presentation and the sidebar's collapse behavior;
/// this view supplies only truthful, noninteractive status. Engine lifecycle commands
/// live in the app's Engine menu, where they remain available when the sidebar's bottom
/// edge is not visible. `safeAreaInset` is the native fallback on older macOS.
struct EngineFooter: View {

    let model: AppModel

    var body: some View {
        Label(title, systemImage: symbol)
            .lineLimit(1)
            .monospacedDigit()
            .controlSize(.small)
            .help(tooltip)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(subtitle)
            .accessibilityHint(accessibilityHint)
    }

    private var title: String {
        model.fixtureProvenance?.footerTitle ?? model.engine.headline
    }

    private var symbol: String {
        model.fixtureProvenance == nil ? statusSymbol : "testtube.2"
    }

    private var accessibilityLabel: String {
        model.fixtureProvenance?.accessibilityLabel ?? model.engine.headline
    }

    private var accessibilityHint: String {
        model.fixtureProvenance == nil ? "Engine status" : "Fixture data provenance"
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

    private var subtitle: String {
        if let fixture = model.fixtureProvenance { return fixture.detail }
        var details = ["VM: \(model.engine.vmState)"]
        if let version = model.engine.version { details.append("morbstackd \(version)") }
        if let chip = model.fileSharingChip { details.append(chip.detail) }
        return details.joined(separator: "\n")
    }

    private var tooltip: String {
        if let fixture = model.fixtureProvenance { return fixture.detail }
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
    @State private var diagnosticsWorkflow = DiagnosticsBundleWorkflow()

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
                EngineStoppedView(model: model, diagnostics: diagnosticsWorkflow)
                    .navigationTitle(model.selection.title)
                    .navigationSubtitle(model.engine.headline)
            } else {
                // Each screen sets its own title, subtitle, search field and actions.
                content
            }
        }
        // Routes own the toolbar command for their current collection. A second
        // app-wide refresh beside it is visually redundant and, on Builds, can imply
        // that the expensive cache endpoint is part of a normal refresh. The focused
        // value keeps ⌘R and Engine > Refresh available without duplicating the native
        // toolbar item.
        .focusedSceneValue(\.routeRefreshAction, routeRefreshAction)
        .alert("Unable to Complete Operation", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.lastError ?? "An unknown error occurred.")
        }
        .alert(
            diagnosticsWorkflow.notice?.title ?? "",
            isPresented: Binding(
                get: { diagnosticsWorkflow.notice != nil },
                set: { if !$0 { diagnosticsWorkflow.notice = nil } }),
            presenting: diagnosticsWorkflow.notice
        ) { notice in
            if let directory = notice.directory {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([directory])
                }
            }
            Button("Done", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
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

    /// The menu/keyboard refresh follows the selected route's data boundary. The
    /// toolbar remains route-owned, so the command is not drawn twice in the system
    /// chrome.
    private var routeRefreshAction: (() -> Void)? {
        guard model.engine.isRunning else { return nil }
        switch model.selection {
        case .builds:
            return { Task { await model.refreshBuildCache() } }
        case .disk:
            return { Task { await model.refreshDisk() } }
        default:
            return { Task { await model.refreshAll() } }
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
    let diagnostics: DiagnosticsBundleWorkflow

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

                if model.engine.state == "error" {
                    if diagnostics.isCollecting {
                        ProgressView("Creating Diagnostics Bundle…")
                            .controlSize(.small)
                    } else {
                        Button("Create Diagnostics Bundle…") {
                            diagnostics.chooseParentFolderAndCollect()
                        }
                        .help("Create a local redacted diagnostics bundle without contacting the engine")
                    }
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
            return "Morbstack could not bring the virtual machine up. Create a redacted diagnostics bundle to review before sharing; it doesn’t start or contact the engine."
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
    /// Fixtures replace the route title with a system-window provenance title. Ordinary
    /// launches leave SwiftUI's route-owned navigation title entirely untouched.
    let forcedTitle: String?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        guard size != nil || forcedTitle != nil else { return view }
        // The view has no window until it is in the hierarchy, which happens after
        // `makeNSView` returns.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if let size {
                window.setContentSize(size)
                window.center()
                // Restoration would otherwise overwrite the requested size on the next
                // launch with whatever the user last dragged the window to.
                window.isRestorable = false
            }
            if let forcedTitle { window.title = forcedTitle }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // A route's navigation title can update after the view has entered the window.
        // Reassert provenance for fixture launches only; ordinary route titles stay
        // system-owned and unchanged.
        guard let forcedTitle else { return }
        DispatchQueue.main.async {
            nsView.window?.title = forcedTitle
        }
    }
}
