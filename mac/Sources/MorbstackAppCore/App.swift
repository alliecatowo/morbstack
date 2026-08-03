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

    var body: some Commands {
        // Replacing the sidebar group rather than adding to it: the stock group's
        // "Show Sidebar" item stays available through the toolbar, and ⌘1…⌘8 read as
        // navigation, which is what this menu is for.
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
            Button("Suspend Engine") { Task { await model.engineAction(.suspend) } }
                .disabled(!model.engine.isRunning || model.isEngineBusy)
            Button("Stop Engine") { Task { await model.engineAction(.stop) } }
                .disabled(!model.engine.reachable || model.isEngineBusy)
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

    /// How far the command palette sits from the top of the window — a Spotlight-ish
    /// ~22% on the window sizes the app actually opens at, not dead centre. Matches the
    /// offset the screenshot harness's `paletteScene()` uses, so the real app and
    /// `command-palette-*.png` agree.
    private static let paletteTopInset: CGFloat = 96

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(
                    min: 180, ideal: Theme.sidebarWidth, max: 280)
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
            // `--tour-capture <dir>`: self-capture the real window instead of running
            // the app for a person. Chained after `bootstrap()` so a `--tour-fixtures`
            // run has already populated the model before the first screen is
            // photographed. See `Shots/LiveCapture.swift`.
            if options.tourCapture != nil {
                await LiveCaptureRunner.run(model: model, options: options)
            }
        }
        .sheet(isPresented: $isPalettePresented) {
            // `CommandPalette`'s own root is just the sized panel — the merge-owned
            // screenshot harness composes it the same way for `paletteScene()`, so the
            // scrim and the top anchor live here rather than inside the palette itself.
            // `.presentationBackground(.clear)`, applied inside `CommandPalette`, is a
            // presentation-preference modifier and reaches the sheet from here just the
            // same, so the scrim below is the only thing behind the panel.
            ZStack(alignment: .top) {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { isPalettePresented = false }
                CommandPalette(model: model, isPresented: $isPalettePresented)
                    .padding(.top, Self.paletteTopInset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
}

// MARK: - Sidebar

/// The one section boundary in the app that reflects how someone actually thinks about
/// the product: things you run, and things that back them.
private enum SidebarSection: String, CaseIterable, Identifiable {
    case workloads = "Workloads"
    case resources = "Resources"

    var id: String { rawValue }

    var items: [Nav] {
        switch self {
        case .workloads: return [.containers, .stacks, .kubernetes]
        case .resources: return [.images, .volumes, .networks, .builds, .disk]
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
        // `.morbBottomBar`, not `.safeAreaInset`: on macOS 26 this is what gets the
        // footer the system's own bar treatment (glass plus the scroll-edge effect) for
        // free, and it degrades to `safeAreaInset` below that — see `Design/MorbGlass.swift`.
        .morbBottomBar { EngineFooter(model: model) }
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

/// The status footer under the sidebar.
///
/// The one piece of chrome that is always visible, so it carries the answer to the
/// question the app exists to answer: is the engine up? Colour, symbol and words all
/// say the same thing, which is what makes it readable at a glance and still readable
/// in a greyscale screenshot.
///
/// Note what is deliberately absent: **no material and no divider of its own.** It is
/// hosted by `safeAreaBar`, which on macOS 26 already gives it the system's bar
/// treatment. Painting `.thinMaterial` underneath as well put glass on glass — the one
/// thing Apple's Liquid Glass guidance names as an outright mistake rather than a matter
/// of taste — and it is why the footer used to read as a paler rectangle glued to the
/// bottom of the sidebar instead of part of it.
struct EngineFooter: View {

    @Bindable var model: AppModel
    @State private var isHovering = false

    private var tone: StatusTone { .forEngine(model.engine) }

    var body: some View {
        HStack(spacing: Theme.space3) {
            MorbStatusDot(
                tone: tone, size: 9,
                pulsing: model.engine.isTransitional || model.isEngineBusy)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.engine.headline)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Text(model.summaryLine == model.engine.headline ? subtitle : model.summaryLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }

            Spacer(minLength: 0)

            sharingWarning

            if model.isEngineBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.75)
            } else if model.engine.isRunning {
                Button {
                    Task { await model.engineAction(.suspend) }
                } label: {
                    Image(systemName: "pause.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Suspend the engine")
                .opacity(isHovering ? 1 : 0)
            }
        }
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, Theme.space3)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .morbAnimation(.fade, value: isHovering)
        .morbAnimation(.subtle, value: model.engine)
        .help(tooltip)
    }

    /// A shared folder the user configured that the VM has not mounted.
    ///
    /// Sits in the one piece of chrome that is always on screen, because the failure it
    /// reports is invisible everywhere else: a bind mount into an unmounted share does
    /// not error, it silently reads an empty directory. Opening Settings is one click
    /// from here, which is where the explanation and the restart button live.
    ///
    /// Only ever appears while the engine is running — see `TrackEShareStatus.chip`. A
    /// chip that is lit whenever the VM is off would be lit most of the time, and a
    /// warning that is usually on is not a warning.
    @ViewBuilder
    private var sharingWarning: some View {
        if let chip = model.fileSharingChip {
            SettingsLink {
                Image(systemName: chip.symbol)
                    .foregroundStyle(chip.tone.color)
            }
            .buttonStyle(.borderless)
            .help("\(chip.text). \(chip.detail)")
            .accessibilityLabel(chip.text)
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
            .morbAnimation(.subtle, value: chip)
        }
    }

    private var subtitle: String {
        if let version = model.engine.version { return "morbstackd \(version)" }
        return model.engine.reachable ? model.engine.vmState : "Not running"
    }

    private var tooltip: String {
        var lines = ["VM state: \(model.engine.vmState)"]
        if let version = model.engine.version { lines.append("Daemon: \(version)") }
        lines.append(model.engine.reachable ? "Control socket: connected" : "Control socket: no answer")
        return lines.joined(separator: "\n")
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
        // has the system's own content background, and `Theme.contentBackground` on top
        // of it was a second opaque surface doing the same job slightly differently.
        Group {
            if !model.hasLoaded {
                // Titled even here, so the window is never chrome-less for the few
                // milliseconds before the daemon answers.
                LoadingView()
                    .navigationTitle(model.selection.title)
                    .navigationSubtitle("Connecting…")
            } else if !model.engine.isRunning {
                EngineStoppedView(model: model)
                    .navigationTitle(model.selection.title)
                    .navigationSubtitle(model.engine.headline)
            } else {
                // Each screen sets its own title, subtitle, search field and actions.
                content
                    .transition(.opacity)
            }
        }
        // The one toolbar item that is true on every screen in every state. It also
        // guarantees the window always has something in its toolbar: an `NSToolbar`
        // with nothing but the sidebar toggle in it is what "unfinished" looks like.
        .toolbar { refreshItem }
        .animation(Theme.springSubtle, value: model.engine.isRunning)
        .animation(Theme.fade, value: model.hasLoaded)
        .overlay(alignment: .top) { errorBanner }
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
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = model.lastError {
            HStack(spacing: Theme.space3) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.statusBad)
                Text(message)
                    .font(.callout)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: Theme.space3)
                Button {
                    model.dismissError()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.space4)
            .padding(.vertical, Theme.space3)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.statusBad.opacity(0.35), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            .padding(Theme.pagePadding)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(Theme.springSubtle, value: model.lastError)
        }
    }
}

/// The brief moment before the daemon has answered.
///
/// No spinner: `bootstrap` normally resolves in a few milliseconds, and a spinner that
/// flashes for one frame is worse than nothing.
private struct LoadingView: View {
    var body: some View {
        Color.clear
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
        // The one screen in the app that carries the mark — see the note at the bottom
        // of `Design/MorbBrand.swift`. Everywhere else the identity is carried by symbol
        // choice, accent discipline and copy, not by the logo.
        MorbBrandedEmptyState(
            title,
            description: explanation,
            footnote: "Morbstack runs Docker in a lightweight virtual machine."
        ) {
            if isStarting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    Task { await model.engineAction(.start) }
                } label: {
                    Label(
                        model.engine.state == "suspended" ? "Resume Engine" : "Start Engine",
                        systemImage: "play.fill")
                        .frame(minWidth: 132)
                }
                .morbButton(.primary)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
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
            return "The virtual machine is saved to disk. Resuming restores it exactly where it left off — your containers are still there."
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
/// useless for repeatable screenshots: the second run inherits the first run's size from
/// the restoration store. Reaching for the `NSWindow` is the only way to get the exact
/// pixels asked for, every time.
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
