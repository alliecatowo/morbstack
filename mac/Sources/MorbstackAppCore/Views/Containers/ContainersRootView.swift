// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The Containers screen: the list on the left, the selected container on the right.
//
// A split rather than a push-navigation stack because the two panes are used together —
// you watch logs while you restart something, and you compare two rows by clicking
// between them. `HSplitView` also gives the divider drag for free, which is the one
// piece of window management a screen like this genuinely needs.
//
// The title, subtitle, search field, All/Running scope and Prune action all live in a
// real `.toolbar` now rather than in a hand-drawn header `HStack`: that is what gives
// the window something to drag by, a scroll-edge effect above the first row, and Liquid
// Glass grouping for free on macOS 26. See `docs/design/COMPONENTS.md` §8.
//
// Note for whoever next touches the offscreen screenshot harness: `NSHostingView`
// rendered without an enclosing `NavigationSplitView` does not composite `.toolbar` or
// `.inspector` content at all (verified empirically — both render as nothing, not as a
// degraded fallback). `Shots/ShotScenes.swift`'s `ShotWindow` is a plain `HStack`, so the
// toolbar built here is invisible in `dist/shots`; the list and detail panes below it are
// exactly what ships. See this track's handoff notes for the full writeup.

import AppKit
import MorbstackKit
import SwiftUI

// MARK: - Root

struct ContainersRootView: View {

    let model: AppModel

    /// - Parameters:
    ///   - initialDetailTab: which tab the detail pane opens on. The app always opens
    ///     on Overview; previews and the screenshot harness need to photograph the
    ///     other three, and there is no other way in — the tab is this screen's own
    ///     state by design, so that clicking between containers does not drag the tab
    ///     around with it.
    ///   - initialHub: a stats hub that already holds history. A sparkline only exists
    ///     after a couple of minutes of a live socket, so a render that starts from an
    ///     empty hub draws empty charts no matter how long it waits.
    init(
        model: AppModel,
        initialDetailTab: TrackBDetailTab = .overview,
        initialHub: TrackBStatsHub? = nil
    ) {
        self.model = model
        self.initialDetailTab = initialDetailTab
        _hub = State(initialValue: initialHub ?? TrackBStatsHub())
    }

    private let initialDetailTab: TrackBDetailTab

    // MARK: State

    @State private var search = ""
    @State private var scope: TrackBScope = .all
    @State private var hub: TrackBStatsHub
    @State private var busy: Set<String> = []
    @State private var isPruning = false
    @State private var removalTarget: ContainerSummary?
    @State private var notice: TrackBNotice?

    // MARK: Derived

    private var stoppedCount: Int {
        model.containers.filter { !$0.isRunning }.count
    }

    private var filtered: [ContainerSummary] {
        let needle = TrackBLogFilter.normalize(search)
        return model.containers.filter { container in
            if scope == .running && !container.isRunning { return false }
            guard !needle.isEmpty else { return true }
            return container.displayName.lowercased().contains(needle)
                || container.image.lowercased().contains(needle)
                || (container.composeProject ?? "").lowercased().contains(needle)
                || (container.composeService ?? "").lowercased().contains(needle)
        }
    }

    private var groups: [ComposeGroup] { filtered.groupedByComposeProject() }

    private var selected: ContainerSummary? {
        guard let id = model.selectedContainerID else { return nil }
        return model.containers.first { $0.id == id }
    }

    private var subtitle: String {
        let running = model.containers.filter(\.isRunning).count
        let total = model.containers.count
        if total == 0 { return "No containers" }
        let shown = filtered.count
        let suffix = shown == total ? "" : " · \(shown) shown"
        return "\(running) running · \(total) total\(suffix)"
    }

    /// Selection is a plain binding rather than `@Bindable` so that the tour hook —
    /// `--tour-container`, which writes `selectedContainerID` before this view is even
    /// on screen — stays the single source of truth.
    private var selectionBinding: Binding<String?> {
        Binding(
            get: { model.selectedContainerID },
            set: { model.selectedContainerID = $0 })
    }

    // MARK: Body

    var body: some View {
        content
            .background(.background)
            .overlay(alignment: .bottom) { noticeBar }
            .morbScreen(title: "Containers", subtitle: subtitle, edge: .hard)
            .searchable(text: $search, placement: .toolbar, prompt: "Name, image, project")
            .toolbar { toolbarContent }
            .confirmationDialog(
                removalTarget.map { "Remove “\($0.displayName)”?" } ?? "Remove container?",
                isPresented: Binding(
                    get: { removalTarget != nil },
                    set: { if !$0 { removalTarget = nil } }),
                titleVisibility: .visible,
                presenting: removalTarget
            ) { container in
                Button("Remove", role: .destructive) {
                    let id = container.id
                    removalTarget = nil
                    perform(.remove, on: id)
                }
                Button("Cancel", role: .cancel) { removalTarget = nil }
            } message: { container in
                Text(container.isRunning
                     ? "It is still running. Removing it stops the container and deletes its writable layer and anonymous volumes."
                     : "This deletes its writable layer and anonymous volumes. Named volumes are kept.")
            }
            .onDisappear { hub.stopAll() }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(id: "containers.scope", placement: MorbToolbarGroup.navigation) {
            Picker("Scope", selection: $scope) {
                ForEach(TrackBScope.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show all containers or only running ones")
        }
        ToolbarItem(id: "containers.prune", placement: MorbToolbarGroup.secondary) {
            pruneButton
        }
    }

    /// Symbol only — the count and the "stopped" qualifier live in the tooltip, not
    /// welded onto the button as permanent text. A spinner replaces the glyph while the
    /// prune is in flight rather than sitting beside it, since a toolbar item shows one
    /// glyph at a time on macOS.
    private var pruneButton: some View {
        Button {
            pruneStopped()
        } label: {
            if isPruning {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16, height: 16)
            } else {
                Label("Prune Stopped Containers", systemImage: "trash")
            }
        }
        .disabled(stoppedCount == 0 || isPruning)
        .help(stoppedCount == 0
              ? "No stopped containers to remove"
              : "Remove \(stoppedCount) stopped container\(stoppedCount == 1 ? "" : "s")")
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !model.engine.isRunning && model.containers.isEmpty {
            engineEmptyState
        } else if model.containers.isEmpty {
            noContainersEmptyState
        } else {
            HSplitView {
                // `HSplitView` ignores `idealWidth` and simply halves the space it is
                // given, so the ceiling is what actually decides the proportion: at 620
                // a 1440-point window put the divider dead centre and left the detail
                // pane too narrow for its own tables. 480 gets the intended shape — a
                // list wide enough for a long compose name, and the rest to the pane
                // that has something to say.
                listPane
                    .frame(minWidth: 320, idealWidth: 400, maxWidth: 480)
                detailPane
                    .frame(minWidth: 460, maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var listPane: some View {
        if filtered.isEmpty {
            MorbNoMatches(query: search)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
        } else {
            List(selection: selectionBinding) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.containers) { container in
                            ContainerListRow(
                                container: container,
                                hub: hub,
                                client: model.client,
                                isBusy: busy.contains(container.id),
                                onAction: { perform($0, on: container.id) },
                                onRequestRemove: { removalTarget = container },
                                isSelected: model.selectedContainerID == container.id)
                                .tag(container.id)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        if showsHeader(for: group) {
                            ComposeGroupHeader(
                                group: group,
                                busyCount: group.containers.filter { busy.contains($0.id) }.count,
                                onUp: { startAll(in: group) },
                                onDown: { stopAll(in: group) })
                                .listRowInsets(EdgeInsets())
                        }
                    }
                }
            }
            .listStyle(.inset)
            .environment(\.defaultMinListRowHeight, Theme.rowRich)
            .scrollContentBackground(.hidden)
            .background(.background)
            .contextMenu(forSelectionType: String.self) { ids in
                contextMenu(for: ids)
            } primaryAction: { ids in
                if let id = ids.first { model.selectedContainerID = id }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<String>) -> some View {
        if let id = ids.first, let container = model.containers.first(where: { $0.id == id }) {
            if container.isRunning {
                Button("Stop") { perform(.stop, on: id) }
                Button("Restart") { perform(.restart, on: id) }
                Button("Pause") { perform(.pause, on: id) }
            } else if container.state == "paused" {
                Button("Resume") { perform(.unpause, on: id) }
                Button("Stop") { perform(.stop, on: id) }
            } else {
                Button("Start") { perform(.start, on: id) }
            }
            Divider()
            Button("Copy name") { TrackBClipboard.copy(container.displayName) }
            Button("Copy container ID") { TrackBClipboard.copy(container.id) }
            if let url = container.ports.compactMap(\.url).first {
                Button("Open \(url.absoluteString)") { NSWorkspace.shared.open(url) }
            }
            Divider()
            Button("Remove…", role: .destructive) { removalTarget = container }
        }
    }

    /// A single ungrouped bucket needs no header — the screen is already called
    /// "Containers", and a lone "Standalone" band is pure chrome.
    private func showsHeader(for group: ComposeGroup) -> Bool {
        group.project != nil || groups.count > 1
    }

    @ViewBuilder
    private var detailPane: some View {
        if let selected {
            ContainerDetailView(
                container: selected,
                model: model,
                hub: hub,
                isBusy: busy.contains(selected.id),
                onAction: { perform($0, on: selected.id) },
                onRequestRemove: { removalTarget = selected })
            .id(selected.id)
        } else {
            MorbEmptyState(
                "Select a container",
                systemImage: "shippingbox",
                description: "Pick a container to see its configuration, follow its logs, watch CPU and memory, or read the full inspect document."
            )
            .background(Theme.contentBackground)
        }
    }

    // MARK: Empty states

    private var engineEmptyState: some View {
        MorbEmptyState(
            "The engine isn’t running",
            systemImage: "bolt.horizontal",
            description: "Morbstack's VM is \(model.engine.reachable ? model.engine.state : "stopped"). Start it to see and manage containers.",
            footnote: "Morbstack runs Docker in a lightweight virtual machine.",
            actionTitle: "Start Engine"
        ) {
            Task { await model.engineAction(.start) }
        }
        .disabled(model.engine.isTransitional)
    }

    private var noContainersEmptyState: some View {
        MorbEmptyState(
            "No containers yet",
            systemImage: "shippingbox",
            description: "Nothing is running on this engine. Point the Docker CLI at it and start something — it shows up here the moment it exists."
        ) {
            VStack(spacing: Theme.space3) {
                Button {
                    Task { await model.refreshAll() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .morbButton(.standard)

                Button {
                    TrackBClipboard.copy(
                        "docker --host unix://\(MorbPaths.dockerSocket.path) run --rm -it alpine sh")
                } label: {
                    Label("Copy an Example Run Command", systemImage: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption)

                Text("docker --host unix://\(MorbPaths.dockerSocket.path) run --rm -it alpine sh")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    // MARK: Notice

    @ViewBuilder
    private var noticeBar: some View {
        if let notice {
            HStack(spacing: Theme.space3) {
                Image(systemName: notice.symbol)
                    .foregroundStyle(notice.isError ? Theme.statusBad : Theme.statusRunning)
                Text(notice.text).font(.callout)
                Spacer(minLength: Theme.space3)
                Button {
                    self.notice = nil
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.space4)
            .padding(.vertical, Theme.space3)
            .frame(maxWidth: 460)
            .morbGlass(.control, radius: Theme.radiusCard)
            .padding(.bottom, Theme.space5)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func show(_ text: String, isError: Bool = false) {
        let notice = TrackBNotice(text: text, isError: isError)
        withAnimation(Theme.springSubtle) {
            self.notice = notice
        }
        Task {
            try? await Task.sleep(for: .seconds(isError ? 6 : 3))
            if self.notice?.id == notice.id {
                withAnimation(Theme.fade) { self.notice = nil }
            }
        }
    }

    // MARK: Intents

    /// Runs one lifecycle action, keeping the row's spinner honest for its duration.
    private func perform(_ action: ContainerAction, on id: String) {
        guard !busy.contains(id) else { return }
        busy.insert(id)
        Task {
            await model.containerAction(action, id: id)
            busy.remove(id)
            if action == .remove {
                hub.forget(id)
                if model.selectedContainerID == id { model.selectedContainerID = nil }
            }
        }
    }

    /// Compose "up": every member that is not already running gets started.
    ///
    /// Concurrently, because a stack's services are independent from the engine's point
    /// of view and starting six of them one at a time is six round trips of waiting.
    private func startAll(in group: ComposeGroup) {
        let targets = group.containers.filter { !$0.isRunning }.map(\.id)
        runBatch(targets) { id in
            await model.containerAction(.start, id: id)
        }
    }

    private func stopAll(in group: ComposeGroup) {
        let targets = group.containers.filter(\.isRunning).map(\.id)
        runBatch(targets) { id in
            await model.containerAction(.stop, id: id)
        }
    }

    private func runBatch(_ ids: [String], _ body: @escaping (String) async -> Void) {
        guard !ids.isEmpty else { return }
        busy.formUnion(ids)
        Task {
            await withTaskGroup(of: Void.self) { group in
                for id in ids {
                    group.addTask { await body(id) }
                }
            }
            busy.subtract(ids)
        }
    }

    private func pruneStopped() {
        guard !isPruning else { return }
        isPruning = true
        Task {
            do {
                let reclaimed = try await model.client.pruneContainers()
                await model.refreshAll()
                show(reclaimed > 0
                     ? "Pruned stopped containers · \(Formatters.bytesString(reclaimed)) reclaimed"
                     : "Pruned stopped containers")
            } catch {
                show(TrackBErrorText.short(error), isError: true)
            }
            isPruning = false
        }
    }
}

// MARK: - Notice

struct TrackBNotice: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var isError: Bool = false

    var symbol: String { isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill" }
}
