// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// What each screenshot is a picture of.
//
// Every scene here composes *production* views — `Sidebar`, `DetailHost`,
// `ContainerDetailView`, `MorbMenuBarContent`, `CommandPalette`. The only thing this
// file adds is the window frame around them, because `RootWindow` itself cannot be used
// directly: its `.task` calls `AppModel.bootstrap()`, which would re-derive the engine
// state from the daemon and (with a fixture daemon that is *not* asked first) briefly
// flip every shot to the start screen. `ShotWindow` below is `RootWindow`'s body minus
// that one modifier, and it is deliberately kept a few lines long so the divergence
// stays obvious.

import AppKit
import SwiftUI

// MARK: - Window chrome

/// The app's window, without the bootstrap task.
///
/// Mirrors `RootWindow.body`. If that gains a piece of chrome, this should too — the
/// point of the harness is that the pictures are of the shipping window.
struct ShotWindow: View {

    @Bindable var model: AppModel

    /// Replaces the detail pane entirely, for scenes that need a specific tab open.
    var detail: AnyView?

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
                .frame(width: Theme.sidebarWidth)
                .background(ShotChrome.sidebarBackground)
            Divider()
            Group {
                if let detail {
                    detail
                } else {
                    DetailHost(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Scene catalogue

/// One entry in the run: a name, a size, and how to build the view.
struct ShotScene {

    var name: String
    var size: CGSize
    /// Built fresh per appearance so that no `@State` is shared between the light and
    /// dark renders of the same screen.
    var build: @MainActor () -> AnyView
    /// Longer for screens whose content arrives on a later run-loop turn.
    var settle: TimeInterval = ShotRenderer.settle

    static let windowSize = CGSize(width: 1440, height: 900)
    static let heroSize = CGSize(width: 1600, height: 1000)
}

@MainActor
enum ShotScenes {

    // MARK: Shared fixtures

    /// The log scrollback, built once — four hundred lines of ANSI parsing is not free,
    /// and every logs scene wants the same lines.
    private static let logLines = ShotLogs.apiLog()

    private static func client() -> ShotDockerClient {
        ShotDockerClient(logLines: logLines)
    }

    /// A model wired to the fixture engine, populated as if a refresh had just landed.
    private static func model(
        engine: EngineStatus = ShotFixtures.engineRunning,
        selection: Nav = .containers,
        selected: String? = nil
    ) -> AppModel {
        let model = AppModel(
            client: client(),
            daemon: ShotDaemonClient(reporting: engine),
            launchOptions: .none)
        model.engine = engine
        model.hasLoaded = true
        model.selection = selection
        guard engine.isRunning else { return model }
        model.containers = ShotFixtures.displayOrderedContainers
        model.images = ShotFixtures.images
        model.volumes = ShotFixtures.volumes
        model.networks = ShotFixtures.networks
        model.disk = ShotFixtures.disk
        model.selectedContainerID = selected.map { ShotFixtures.container($0).id }
        return model
    }

    /// A log store already full of the fixture scrollback.
    private static func logStore(query: String = "") -> TrackBLogStore {
        let store = TrackBLogStore()
        store.seed(logLines)
        store.query = query
        return store
    }

    // MARK: The catalogue

    static var all: [ShotScene] {
        screens + heroes
    }

    static var screens: [ShotScene] {
        [
            ShotScene(name: "containers-list", size: ShotScene.windowSize) {
                AnyView(fullWindow(selection: .containers, selected: "shopfront-web-1"))
            },
            ShotScene(name: "container-overview", size: ShotScene.windowSize) {
                AnyView(containerWindow("shopfront-api-1", tab: .overview))
            },
            ShotScene(name: "container-logs", size: ShotScene.windowSize) {
                // "checkout" matches enough lines to fill the pane — a filter with a
                // dozen hits leaves half the viewer empty, which photographs as a bug —
                // and the lines it matches are varied: coloured access rows, a yellow
                // WARN, and the red traceback that ends the sequence.
                AnyView(containerWindow("shopfront-api-1", tab: .logs, logQuery: "checkout"))
            },
            ShotScene(name: "container-stats", size: ShotScene.windowSize) {
                AnyView(containerWindow("analytics-clickhouse-1", tab: .stats))
            },
            ShotScene(name: "container-inspect", size: ShotScene.windowSize) {
                AnyView(containerWindow("shopfront-postgres-1", tab: .inspect))
            },
            ShotScene(name: "stacks", size: ShotScene.windowSize) {
                AnyView(fullWindow(selection: .stacks))
            },
            ShotScene(name: "images", size: ShotScene.windowSize) {
                AnyView(fullWindow(selection: .images))
            },
            ShotScene(name: "volumes", size: ShotScene.windowSize) {
                AnyView(fullWindow(selection: .volumes))
            },
            ShotScene(name: "networks", size: ShotScene.windowSize) {
                AnyView(fullWindow(selection: .networks))
            },
            ShotScene(name: "disk", size: ShotScene.windowSize) {
                AnyView(diskWindow(size: ShotScene.windowSize))
            },
            ShotScene(name: "placeholder-builds", size: ShotScene.windowSize) {
                AnyView(fullWindow(selection: .builds))
            },
            ShotScene(name: "engine-stopped", size: ShotScene.windowSize) {
                AnyView(fullWindow(engine: ShotFixtures.engineStopped, selection: .containers))
            },
            ShotScene(name: "settings", size: CGSize(width: 640, height: 520)) {
                AnyView(settingsScene())
            },
            // Same canvas as `settings`: `MorbSettingsView` is a fixed 560×440 window and
            // the Form scrolls inside it, so a taller scene buys empty desktop rather than
            // more pane. The Rosetta section genuinely is below the fold here, exactly as
            // it is in the shipping app.
            ShotScene(name: "settings-sharing", size: CGSize(width: 640, height: 520)) {
                AnyView(settingsScene(tab: .sharing))
            },
            // Height 0: fit the popover, whose height depends on how many containers and
            // ports it listed. See `ShotRenderer.render`.
            ShotScene(name: "menubar-popover", size: CGSize(width: 368, height: 0)) {
                AnyView(menuBarScene())
            },
            ShotScene(name: "command-palette", size: ShotScene.windowSize) {
                AnyView(paletteScene())
            },
        ]
    }

    static var heroes: [ShotScene] {
        [
            ShotScene(name: "hero-containers", size: ShotScene.heroSize) {
                AnyView(containerWindow("shopfront-postgres-1", tab: .overview, size: ShotScene.heroSize))
            },
            ShotScene(name: "hero-logs", size: ShotScene.heroSize) {
                AnyView(heroLogs())
            },
            ShotScene(name: "hero-disk", size: ShotScene.heroSize) {
                AnyView(diskWindow(size: ShotScene.heroSize))
            },
        ]
    }

    // MARK: Builders

    /// The whole window, letting `DetailHost` pick the screen from the sidebar selection.
    private static func fullWindow(
        engine: EngineStatus = ShotFixtures.engineRunning,
        selection: Nav,
        selected: String? = nil
    ) -> some View {
        let model = model(engine: engine, selection: selection, selected: selected)
        return ShotWindow(model: model)
            .environment(\.shotStatsHub, ShotFixtures.statsHub())
    }

    /// The Containers screen with the detail pane forced onto one tab.
    ///
    /// The tab is `ContainerDetailView`'s own `@State`, so the only way to name one from
    /// outside is to build the pane here rather than let `ContainersRootView` do it.
    /// The list beside it is still the production list, driven by the same model.
    private static func containerWindow(
        _ name: String,
        tab: TrackBDetailTab,
        logQuery: String = "",
        size: CGSize = ShotScene.windowSize
    ) -> some View {
        let model = model(selection: .containers, selected: name)
        let hub = ShotFixtures.statsHub()
        let container = ShotFixtures.container(name)

        return ShotWindow(
            model: model,
            detail: AnyView(
                ShotContainersSplit(
                    model: model,
                    hub: hub,
                    container: container,
                    tab: tab,
                    logStore: tab == .logs ? logStore(query: logQuery) : nil)))
    }

    /// The Disk screen, with the sparse-image footprint pre-read.
    private static func diskWindow(size: CGSize) -> some View {
        let model = model(selection: .disk)
        return ShotWindow(
            model: model,
            detail: AnyView(
                DiskRootView(model: model, initialFootprint: ShotFixtures.diskFootprint)
                    .background(Theme.contentBackground)))
    }

    /// The Logs tab, full bleed — no sidebar, no list, just the viewer.
    private static func heroLogs() -> some View {
        let model = model(selection: .containers, selected: "shopfront-api-1")
        return ContainerLogsTab(
            container: ShotFixtures.container("shopfront-api-1"),
            client: model.client,
            preloadedStore: logStore())
            .background(Theme.contentBackground)
    }

    /// Settings at its natural size, on the desktop it opens over.
    ///
    /// The Resources tab rather than General: it is the one with something to look at —
    /// the CPU and memory allocation, the disk size, and the restart-required notice the
    /// engine puts up when you change them.
    private static func settingsScene(
        tab: MorbSettingsView.Tab = .resources
    ) -> some View {
        let model = model()
        return ZStack {
            ShotChrome.desktop
            MorbSettingsView(model: model, initialTab: tab, drawsOwnTabStrip: true)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.35), radius: 26, y: 12)
        }
    }

    /// The menu bar popover at its own width, over the desktop-ish backdrop it hangs on.
    ///
    /// The popover's real chrome is an `NSPopover` frame the app does not draw, so this
    /// approximates it: the same rounded, bordered, shadowed card AppKit puts around it.
    private static func menuBarScene() -> some View {
        let model = model()
        return ZStack {
            ShotChrome.desktop

            MorbMenuBarContent(model: model)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(ShotChrome.popoverBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.34), radius: 22, y: 10)
                .padding(24)
        }
    }

    /// The palette over the window it was summoned from, dimmed the way a sheet dims it.
    private static func paletteScene() -> some View {
        let model = model(selection: .containers, selected: "shopfront-web-1")
        return ZStack {
            ShotWindow(model: model)
            Color.black.opacity(0.28)
            VStack {
                CommandPalette(
                    model: model,
                    isPresented: .constant(true),
                    preloadedQuery: "logs post")
                    .padding(.top, 96)
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Containers split with a chosen tab

/// The Containers screen's own split, with the detail pane opened on a named tab.
///
/// `ContainersRootView` owns which tab is showing (correctly — it is view state), so a
/// scene that wants the Logs tab has to assemble the two panes itself. Both halves are
/// the production views; only the `HSplitView` around them is written here, and it is
/// copied from `ContainersRootView.content` so the proportions match.
private struct ShotContainersSplit: View {

    let model: AppModel
    let hub: TrackBStatsHub
    let container: ContainerSummary
    let tab: TrackBDetailTab
    let logStore: TrackBLogStore?

    var body: some View {
        VStack(spacing: 0) {
            TrackBPageHeader(title: "Containers", subtitle: subtitle) {
                HStack(spacing: 10) {
                    TrackBSearchField(text: .constant(""), prompt: "Name, image, project", width: 240)
                    Picker("", selection: .constant(TrackBScope.all)) {
                        ForEach(TrackBScope.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Button {
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "trash")
                            Text("Prune stopped")
                            Text("\(model.containers.filter { !$0.isRunning }.count)")
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.2), in: Capsule())
                        }
                    }
                }
            }
            Divider()
            HSplitView {
                list
                    .frame(minWidth: 320, idealWidth: 400, maxWidth: 480)
                ContainerDetailView(
                    container: container,
                    model: model,
                    hub: hub,
                    isBusy: false,
                    onAction: { _ in },
                    onRequestRemove: {},
                    initialTab: tab,
                    preloadedInspectJSON: ShotFixtures.inspectJSON(for: container),
                    preloadedLogs: logStore)
                    .frame(minWidth: 460, maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
    }

    private var subtitle: String {
        let running = model.containers.filter(\.isRunning).count
        return "\(running) running · \(model.containers.count) total"
    }

    private var list: some View {
        List(selection: .constant(container.id)) {
            ForEach(model.containers.groupedByComposeProject()) { group in
                Section {
                    ForEach(group.containers) { row in
                        ContainerListRow(
                            container: row,
                            hub: hub,
                            client: model.client,
                            isBusy: false,
                            onAction: { _ in },
                            onRequestRemove: {})
                            .tag(row.id)
                    }
                } header: {
                    ComposeGroupHeader(group: group, busyCount: 0, onUp: {}, onDown: {})
                }
            }
        }
        .listStyle(.inset)
        .environment(\.defaultMinListRowHeight, 30)
        .scrollContentBackground(.hidden)
        .background(.background)
    }
}

// MARK: - Environment plumbing

private struct ShotStatsHubKey: EnvironmentKey {
    static let defaultValue: TrackBStatsHub? = nil
}

extension EnvironmentValues {
    /// A pre-seeded stats hub, so that a screen built by `DetailHost` (which makes its
    /// own hub) can still show live-looking CPU and memory numbers. Only the harness
    /// ever sets it.
    var shotStatsHub: TrackBStatsHub? {
        get { self[ShotStatsHubKey.self] }
        set { self[ShotStatsHubKey.self] = newValue }
    }
}
