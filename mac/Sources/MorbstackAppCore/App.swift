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
        _model = State(initialValue: AppModel(launchOptions: options))
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

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(
                    min: 180, ideal: Theme.sidebarWidth, max: 280)
        } detail: {
            DetailHost(model: model)
                .frame(minWidth: 620, minHeight: 420)
        }
        .navigationTitle(model.selection.title)
        // The sidebar's own material comes from the split view; asking for it again on
        // the List would double the blur and make the sidebar noticeably murkier than
        // every other macOS app on screen.
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 880, minHeight: 540)
        .background(WindowConfigurator(size: options.windowSize))
        .task { await model.bootstrap() }
        .sheet(isPresented: $isPalettePresented) {
            CommandPalette(model: model, isPresented: $isPalettePresented)
        }
        // The two cross-track hooks Track D asked for. Installed from the window rather
        // than from `init` because `openWindow` is an environment action and only exists
        // inside a scene's view tree.
        .onAppear {
            TrackDAppBridge.openMainWindow = { openWindow(id: MorbWindowID.main) }
            TrackDAppBridge.showLogs = { id in model.requestLogsTab(for: id) }
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {

    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.selection) {
                Section {
                    ForEach(Nav.allCases) { nav in
                        NavRow(nav: nav, badge: badge(for: nav))
                            .tag(nav)
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                EnginePill(model: model)
            }
        }
    }

    /// The count shown on the right of a row, when there is a number worth knowing.
    ///
    /// Only sections whose count changes on its own get one. A badge on Networks that
    /// permanently reads "3" is furniture, not information.
    private func badge(for nav: Nav) -> Int? {
        guard model.engine.isRunning else { return nil }
        switch nav {
        case .containers: return model.runningCount > 0 ? model.runningCount : nil
        case .stacks:
            let count = model.composeGroups.filter { $0.project != nil }.count
            return count > 0 ? count : nil
        default: return nil
        }
    }
}

/// One sidebar row.
private struct NavRow: View {

    let nav: Nav
    let badge: Int?

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(nav.title)
                Spacer(minLength: 4)
                if let badge {
                    Text("\(badge)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .transition(.opacity.combined(with: .scale(scale: 0.7)))
                }
            }
        } icon: {
            Image(systemName: nav.symbol)
        }
        .animation(Theme.springSubtle, value: badge)
        .help("\(nav.title) (⌘\(nav.shortcutIndex))")
    }
}

// MARK: - Engine pill

/// The status footer under the sidebar.
///
/// The one piece of chrome that is always visible, so it carries the answer to the
/// question the app exists to answer: is the engine up? Colour, symbol and words all
/// say the same thing, which is what makes it readable at a glance and still readable
/// in a greyscale screenshot.
struct EnginePill: View {

    @Bindable var model: AppModel
    @State private var isHovering = false

    private var tone: StatusTone { .forEngine(model.engine) }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                StatusDot(tone: tone, size: 9, animated: model.engine.isTransitional || model.isEngineBusy)

                VStack(alignment: .leading, spacing: 1) {
                    Text(model.engine.headline)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(model.summaryLine == model.engine.headline ? subtitle : model.summaryLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
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
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(Theme.fade, value: isHovering)
            .animation(Theme.springSubtle, value: model.engine)
        }
        .background(.thinMaterial)
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
                HStack(spacing: 4) {
                    Image(systemName: chip.symbol)
                        .font(.system(size: 10, weight: .semibold))
                    Text(chip.text)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                }
                .foregroundStyle(chip.tone.color)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(chip.tone.color.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain)
            .help(chip.detail)
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
            .animation(Theme.springSubtle, value: chip)
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
        ZStack {
            Theme.contentBackground.ignoresSafeArea()

            if !model.hasLoaded {
                LoadingView()
            } else if !model.engine.isRunning {
                EngineStoppedView(model: model)
            } else {
                content
                    .transition(.opacity)
            }
        }
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
        case .builds, .kubernetes: PlaceholderView(nav: model.selection)
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = model.lastError {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.statusBad)
                Text(message)
                    .font(.callout)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button {
                    model.dismissError()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
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
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Theme.brandGradient)
                    .frame(width: 84, height: 84)
                    .opacity(isStarting ? 0.9 : 0.16)
                    .blur(radius: isStarting ? 0 : 0.5)
                Image(systemName: isStarting ? "gearshape.2" : "shippingbox")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(isStarting ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.brand))
                    .symbolEffect(.pulse, isActive: isStarting)
            }
            .animation(Theme.springSubtle, value: isStarting)

            Text(title)
                .font(.title2.weight(.semibold))
                .padding(.top, 20)

            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.top, 6)

            if isStarting {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 22)
            } else {
                Button {
                    Task { await model.engineAction(.start) }
                } label: {
                    Label(model.engine.state == "suspended" ? "Resume Engine" : "Start Engine",
                          systemImage: "play.fill")
                        .frame(minWidth: 132)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Theme.brand)
                .keyboardShortcut(.return, modifiers: [])
                .padding(.top, 22)
            }

            Spacer()

            Text("Morbstack runs Docker in a lightweight virtual machine.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, Theme.pagePadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.pagePadding)
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
            return "Morbstack could not bring the virtual machine up. Run `morb doctor` in a terminal for a full diagnosis."
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
