// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The container browser uses a selected-record list because the current Tahoe Table
// appearance makes unused rows read as a dashboard/skeleton at this route's typical
// density. The selected row is described in the system-owned trailing inspector.
// One state-appropriate lifecycle command remains in the window toolbar. The complete
// record command set lives in the native contextual menu rather than becoming controls
// embedded in every row or a hand-made toolbar overflow.

import Foundation
import MorbstackKit
import SwiftUI

// MARK: - Root

struct ContainersRootView: View {

    let model: AppModel

    @Environment(\.openURL) private var openURL

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
    @State private var hub: TrackBStatsHub
    @State private var busy: Set<String> = []
    @State private var isPruning = false
    @State private var isShowingPruneConfirmation = false
    @State private var removalTarget: ContainerSummary?
    @State private var commandTarget: ContainerSummary?
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
            .sheet(item: $commandTarget) { container in
                ContainerExecSheet(container: container, model: model)
            }
            .onChange(of: model.selectedContainerID) { _, selection in
                if selection != nil { showsInspector = true }
            }
            .onDisappear { hub.stopAll() }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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
                    .accessibilityLabel("\(action.title) \(selected.displayName)")
                    .help("\(action.title) \(selected.displayName)")
                }
            }

            // A selected-record command belongs in macOS's managed secondary-action
            // area, not in every list row or a hand-built command bar. The sheet itself
            // explains why a stopped selection cannot execute before it can reach Docker.
            ToolbarItem(id: "containers.runCommand", placement: .secondaryAction) {
                Button("Run Command…", systemImage: "terminal") {
                    commandTarget = selected
                }
                .accessibilityLabel("Run command in \(selected.displayName)")
                .help("Run a noninteractive command in \(selected.displayName)")
            }
        }

        // This is a semantic collection-options menu, not a second, manually managed
        // overflow. It keeps filtering, refresh, and the infrequent prune operation
        // together while the selected record's commands stay with that record.
        ToolbarItem(id: "containers.options", placement: .secondaryAction) {
            Menu {
                Picker("Show", selection: $scope) {
                    ForEach(ContainerScope.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }

                Divider()

                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refreshAll() }
                }

                if stoppedCount > 0 {
                    Divider()
                    Button("Remove Stopped Containers…", role: .destructive) {
                        isShowingPruneConfirmation = true
                    }
                    .disabled(isPruning)
                }
            } label: {
                Label("Container options", systemImage: "slider.horizontal.3")
            }
            .accessibilityLabel("Container options")
            .help("Show, refresh, and cleanup options")
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
            containerList
                .inspector(isPresented: $showsInspector) {
                    inspector
                        .inspectorColumnWidth(min: 340, ideal: 400, max: 520)
                }
        }
    }

    private var containerList: some View {
        List(selection: selectionBinding) {
            ForEach(filtered) { container in
                HStack {
                    Label {
                        Text(container.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        Image(systemName: stateSymbol(for: container))
                            .foregroundStyle(stateColor(for: container))
                            .accessibilityHidden(true)
                    }

                    Spacer(minLength: 12)

                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(container.statusDisplay(at: context.date))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .tag(container.id)
                .help(container.statusDisplay())
                .contextMenu {
                    contextMenu(for: container)
                }
                // `List` has no `Table.primaryAction` equivalent. Preserve the former
                // double-click behavior with the standard macOS primary gesture while
                // leaving single-click selection and keyboard focus system-owned.
                .onTapGesture(count: 2) {
                    model.selectedContainerID = container.id
                    showsInspector = true
                }
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
    private func contextMenu(for container: ContainerSummary) -> some View {
        ForEach(container.availableActions.filter { !$0.isDestructive }, id: \.rawValue) { action in
            Button(action.title) { perform(action, on: container.id) }
        }
        Divider()
        Button("Run Command…", systemImage: "terminal") { commandTarget = container }
        Divider()
        Button("Copy Name") { MorbPasteboard.copy(container.displayName) }
        Button("Copy Container ID") { MorbPasteboard.copy(container.id) }
        Button("Copy Image") { MorbPasteboard.copy(container.image) }
        let addresses = browserAddresses(for: container)
        if addresses.count == 1, let address = addresses.first {
            Divider()
            browserAddressActionItems(for: address)
        } else if !addresses.isEmpty {
            Divider()
            Menu("Published Addresses") {
                ForEach(addresses, id: \.absoluteString) { address in
                    Menu(address.absoluteString) {
                        browserAddressActionItems(for: address)
                    }
                }
            }
        }
        Divider()
        Button("Remove…", role: .destructive) { removalTarget = container }
    }

    /// Preserve Docker's individual bindings while keeping the contextual menu's
    /// multi-address order deterministic. Only `PortMapping.browserAddress` is
    /// eligible, so no wildcard, LAN, UDP, host-network, or incomplete mapping gets
    /// a deceptively concrete browser command.
    private func browserAddresses(for container: ContainerSummary) -> [URL] {
        Array(Set(container.ports.compactMap(\.browserAddress)))
            .sorted { $0.absoluteString.localizedStandardCompare($1.absoluteString) == .orderedAscending }
    }

    @ViewBuilder
    private func browserAddressActionItems(for address: URL) -> some View {
        Button("Copy Address") { MorbPasteboard.copy(address.absoluteString) }
        Button("Open in Browser") { openURL(address) }
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
