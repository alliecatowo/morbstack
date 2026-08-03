// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The container browser deliberately follows the Finder/Xcode data-browser shape:
// one sortable table is the content surface and the selected row is described in the
// system-owned trailing inspector.  Lifecycle commands live in the window toolbar and
// contextual menu rather than becoming controls embedded in every row.

import AppKit
import MorbstackKit
import SwiftUI

// MARK: - Table sorting

private enum ContainerSortKey: Hashable {
    case name, project, image, state, ports, created
}

private struct ContainerComparator: SortComparator {
    typealias Compared = ContainerSummary

    var key: ContainerSortKey
    var order: SortOrder = .forward

    func compare(_ lhs: ContainerSummary, _ rhs: ContainerSummary) -> ComparisonResult {
        let result: ComparisonResult
        switch key {
        case .name:
            result = compare(lhs.displayName, rhs.displayName)
        case .project:
            result = compare(lhs.composeProject ?? "", rhs.composeProject ?? "")
        case .image:
            result = compare(lhs.image, rhs.image)
        case .state:
            result = compare(lhs.state, rhs.state)
        case .ports:
            result = compare(portText(lhs), portText(rhs))
        case .created:
            result = lhs.createdAt == rhs.createdAt
                ? compare(lhs.displayName, rhs.displayName)
                : (lhs.createdAt < rhs.createdAt ? .orderedAscending : .orderedDescending)
        }
        return order == .forward ? result : result.reversed
    }

    private func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.localizedStandardCompare(rhs)
    }

    private func portText(_ container: ContainerSummary) -> String {
        container.ports.map(\.label).joined(separator: ", ")
    }
}

// MARK: - Root

struct ContainersRootView: View {

    let model: AppModel

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

    @State private var search = ""
    @State private var scope: ContainerScope = .all
    @State private var sortOrder: [ContainerComparator] = [
        ContainerComparator(key: .name)
    ]
    @State private var hub: TrackBStatsHub
    @State private var busy: Set<String> = []
    @State private var isPruning = false
    @State private var isShowingPruneConfirmation = false
    @State private var removalTarget: ContainerSummary?
    @State private var showsInspector = true
    @State private var pruneError: String?

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
        .sorted(using: sortOrder)
    }

    private var selected: ContainerSummary? {
        guard let id = model.selectedContainerID else { return nil }
        return model.containers.first { $0.id == id }
    }

    private var subtitle: String {
        let running = model.containers.filter(\.isRunning).count
        let total = model.containers.count
        guard total > 0 else { return "No containers" }
        let shown = filtered.count
        return shown == total
            ? "\(running) running · \(total) total"
            : "\(running) running · \(shown) of \(total) shown"
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { model.selectedContainerID },
            set: { model.selectedContainerID = $0 })
    }

    var body: some View {
        content
            .navigationTitle("Containers")
            .navigationSubtitle(subtitle)
            .searchable(text: $search, placement: .toolbar, prompt: "Name, image, or project")
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
                    ? "This stops the container and deletes its writable layer and anonymous volumes. Named volumes are kept."
                    : "This deletes its writable layer and anonymous volumes. Named volumes are kept.")
            }
            .confirmationDialog(
                "Remove \(stoppedCount) Stopped Container\(stoppedCount == 1 ? "" : "s")?",
                isPresented: $isShowingPruneConfirmation,
                titleVisibility: .visible
            ) {
                Button("Remove Stopped Containers", role: .destructive) {
                    pruneStopped()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes stopped containers and their writable layers. Named volumes are kept.")
            }
            .alert(
                "Couldn’t Prune Containers",
                isPresented: Binding(
                    get: { pruneError != nil },
                    set: { if !$0 { pruneError = nil } })
            ) {
                Button("OK", role: .cancel) { pruneError = nil }
            } message: {
                Text(pruneError ?? "")
            }
            .onChange(of: model.selectedContainerID) { _, selection in
                if selection != nil { showsInspector = true }
            }
            .onDisappear { hub.stopAll() }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(id: "containers.scope", placement: .automatic) {
            Picker("Show", selection: $scope) {
                ForEach(ContainerScope.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .help("Show all containers or only running containers")
        }

        ToolbarItem(id: "containers.refresh", placement: .secondaryAction) {
            Button {
                Task { await model.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("Refresh containers")
            .help("Refresh containers")
        }

        if !model.containers.isEmpty {
            ToolbarItem(id: "containers.inspector", placement: .automatic) {
                Button { showsInspector.toggle() } label: {
                    Image(systemName: "sidebar.right")
                }
                .accessibilityLabel(showsInspector ? "Hide inspector" : "Show inspector")
                .help(showsInspector ? "Hide inspector" : "Show inspector")
            }
        }

        if let selected {
            ToolbarItem(id: "containers.primaryLifecycle", placement: .primaryAction) {
                if busy.contains(selected.id) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Updating \(selected.displayName)")
                } else if let action = primaryLifecycleAction(for: selected) {
                    Button { perform(action, on: selected.id) } label: {
                        Image(systemName: action.symbol)
                    }
                    .accessibilityLabel(action.title)
                    .help("\(action.title) \(selected.displayName)")
                }
            }

            ToolbarItem(id: "containers.more", placement: .secondaryAction) {
                Menu {
                    ForEach(secondaryLifecycleActions(for: selected), id: \.rawValue) { action in
                        Button(action.title, systemImage: action.symbol) {
                            perform(action, on: selected.id)
                        }
                    }
                    if !secondaryLifecycleActions(for: selected).isEmpty {
                        Divider()
                    }
                    Button("Copy Container ID") { MorbPasteboard.copy(selected.id) }
                    Button("Copy Image") { MorbPasteboard.copy(selected.image) }
                    if let url = selected.ports.compactMap(\.url).first {
                        Button("Open in Browser…") { NSWorkspace.shared.open(url) }
                    }
                    Divider()
                    Button("Remove…", role: .destructive) { removalTarget = selected }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More container actions")
                .help("More actions for \(selected.displayName)")
            }
        }

        ToolbarItem(id: "containers.prune", placement: .secondaryAction) {
            Button(role: .destructive) { isShowingPruneConfirmation = true } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Prune stopped containers")
            .disabled(stoppedCount == 0 || isPruning)
            .help(
                stoppedCount == 0
                    ? "No stopped containers to remove"
                    : "Remove \(stoppedCount) stopped container\(stoppedCount == 1 ? "" : "s")")
        }
    }

    /// One selected container gets one obvious toolbar command. All other lifecycle
    /// actions remain in the system-managed secondary menu, where they do not crowd
    /// search, the inspector control, or the route's toolbar at narrow widths.
    private func primaryLifecycleAction(for container: ContainerSummary) -> ContainerAction? {
        switch container.state {
        case "running", "restarting": return container.availableActions.contains(.stop) ? .stop : nil
        case "paused": return container.availableActions.contains(.unpause) ? .unpause : nil
        default: return container.availableActions.contains(.start) ? .start : nil
        }
    }

    private func secondaryLifecycleActions(for container: ContainerSummary) -> [ContainerAction] {
        container.availableActions.filter {
            !$0.isDestructive && $0 != primaryLifecycleAction(for: container)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !model.engine.isRunning && model.containers.isEmpty {
            engineEmptyState
        } else if model.containers.isEmpty {
            noContainersEmptyState
        } else if filtered.isEmpty {
            if search.isEmpty {
                ContentUnavailableView {
                    Label("No Running Containers", systemImage: "play.circle")
                } description: {
                    Text("No containers match the Running scope.")
                }
            } else {
                ContentUnavailableView.search(text: search)
            }
        } else {
            containerTable
                .inspector(isPresented: $showsInspector) {
                    inspector
                        .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
                }
        }
    }

    private var containerTable: some View {
        Table(filtered, selection: selectionBinding, sortOrder: $sortOrder) {
            TableColumn("Name", sortUsing: ContainerComparator(key: .name)) { container in
                HStack(spacing: 6) {
                    Image(systemName: stateSymbol(for: container))
                        .foregroundStyle(stateColor(for: container))
                        .accessibilityHidden(true)
                    Text(container.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(container.status.isEmpty ? container.state : container.status)
            }
            .width(min: 180, ideal: 260)

            TableColumn("Project", sortUsing: ContainerComparator(key: .project)) { container in
                Text(container.composeProject ?? "—")
                    .foregroundStyle(container.composeProject == nil ? .tertiary : .secondary)
                    .lineLimit(1)
            }
            .width(min: 100, ideal: 150)

            TableColumn("Image", sortUsing: ContainerComparator(key: .image)) { container in
                Text(container.image)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 180, ideal: 280)

            TableColumn("State", sortUsing: ContainerComparator(key: .state)) { container in
                Text(container.status.isEmpty ? container.state.capitalized : container.status)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 170)

            TableColumn("Ports", sortUsing: ContainerComparator(key: .ports)) { container in
                Text(portDescription(for: container))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(container.ports.isEmpty ? .tertiary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .width(min: 90, ideal: 150)

            TableColumn("Created", sortUsing: ContainerComparator(key: .created)) { container in
                Text(Formatters.compactDuration(since: container.createdAt))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help(Formatters.absoluteDate(container.createdAt))
            }
            .width(min: 86, ideal: 106)
        }
        // The automatic Tahoe table style renders empty rows as inset, rounded bands
        // in this dense operations pane. Bordered is the system's non-inset macOS
        // table treatment; it preserves native selection, sorting, resizing, and
        // accessibility without introducing a Morbstack row style.
        .tableStyle(.bordered)
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            if let id = ids.first {
                model.selectedContainerID = id
                showsInspector = true
            }
        }
        .onDeleteCommand {
            if let selected { removalTarget = selected }
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let selected {
            ContainerDetailView(
                container: selected,
                model: model,
                hub: hub,
                initialTab: initialDetailTab)
            .id(selected.id)
        } else {
            ContentUnavailableView {
                Label("No Container Selected", systemImage: "shippingbox")
            } description: {
                Text("Select a container to see its configuration, logs, statistics, and inspect document.")
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<String>) -> some View {
        if let id = ids.first, let container = model.containers.first(where: { $0.id == id }) {
            ForEach(container.availableActions.filter { !$0.isDestructive }, id: \.rawValue) { action in
                Button(action.title) { perform(action, on: id) }
            }
            Divider()
            Button("Copy Name") { MorbPasteboard.copy(container.displayName) }
            Button("Copy Container ID") { MorbPasteboard.copy(container.id) }
            if let url = container.ports.compactMap(\.url).first {
                Button("Open in Browser…") { NSWorkspace.shared.open(url) }
            }
            Divider()
            Button("Remove…", role: .destructive) { removalTarget = container }
        }
    }

    private var engineEmptyState: some View {
        ContentUnavailableView {
            Label("The Engine Isn’t Running", systemImage: "bolt.horizontal")
        } description: {
            Text("Start the Morbstack engine to see and manage its containers.")
        } actions: {
            Button("Start Engine") {
                Task { await model.engineAction(.start) }
            }
            .disabled(model.engine.isTransitional)
        }
    }

    private var noContainersEmptyState: some View {
        ContentUnavailableView {
            Label("No Containers", systemImage: "shippingbox")
        } description: {
            Text("Run a container through the Morbstack Docker socket and it appears here automatically.")
        } actions: {
            Button("Refresh") {
                Task { await model.refreshAll() }
            }
            Button("Copy Example Run Command") {
                MorbPasteboard.copy(
                    "docker --host unix://\(MorbPaths.dockerSocket.path) run --rm -it alpine sh")
            }
        }
    }

    private func stateSymbol(for container: ContainerSummary) -> String {
        switch container.state {
        case "running": return "play.circle.fill"
        case "paused": return "pause.circle.fill"
        case "restarting": return "arrow.triangle.2.circlepath.circle.fill"
        case "dead": return "xmark.circle.fill"
        default: return "stop.circle.fill"
        }
    }

    private func stateColor(for container: ContainerSummary) -> Color {
        if container.isUnhealthy || container.state == "dead" { return .red }
        switch container.state {
        case "running": return .green
        case "paused", "restarting": return .orange
        default: return .secondary
        }
    }

    private func portDescription(for container: ContainerSummary) -> String {
        guard !container.ports.isEmpty else { return "—" }
        return container.ports.map(\.label).joined(separator: ", ")
    }

    // MARK: Intents

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

    private func pruneStopped() {
        guard !isPruning else { return }
        isPruning = true
        Task {
            do {
                _ = try await model.client.pruneContainers()
                await model.refreshAll()
            } catch {
                pruneError = TrackBErrorText.short(error)
            }
            isPruning = false
        }
    }
}
