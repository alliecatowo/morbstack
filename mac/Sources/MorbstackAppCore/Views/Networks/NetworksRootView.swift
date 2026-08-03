// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The Networks screen.
//
// Mostly a read-only inventory. `bridge`, `host`, and `none` are always present and
// Docker manages their lifetime, but they remain records in the same flat collection as
// user-defined networks. Their Kind value makes that policy clear without breaking the
// table's native all-record sort behavior.
//
// A standard flat `Table` presents the operational collection, while selection reveals
// the chosen network's facts in the system inspector. This keeps inventory, selection,
// and detail as distinct macOS interactions instead of a hand-built split layout.

import AppKit
import MorbstackKit
import SwiftUI

// MARK: - Sorting and filtering

enum TrackCNetworkSortKey: String, Hashable, CaseIterable {
    case name
    case kind
    case driver
    case scope
    case containers
}

enum TrackCNetworkList {

    static func matches(_ network: NetworkSummary, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return network.name.localizedCaseInsensitiveContains(needle)
            || network.driver.localizedCaseInsensitiveContains(needle)
            || network.id.localizedCaseInsensitiveContains(needle)
    }

    static func sorted(
        _ networks: [NetworkSummary],
        by key: TrackCNetworkSortKey,
        ascending: Bool
    ) -> [NetworkSummary] {
        let ordered = networks.sorted { lhs, rhs in
            switch key {
            case .name:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .kind:
                let lhsKind = kindLabel(for: lhs)
                let rhsKind = kindLabel(for: rhs)
                if lhsKind != rhsKind {
                    return lhsKind.localizedStandardCompare(rhsKind) == .orderedAscending
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .driver:
                if lhs.driver != rhs.driver {
                    return lhs.driver.localizedStandardCompare(rhs.driver) == .orderedAscending
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .scope:
                if lhs.scope != rhs.scope {
                    return lhs.scope.localizedStandardCompare(rhs.scope) == .orderedAscending
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .containers:
                if lhs.containers != rhs.containers { return lhs.containers < rhs.containers }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
        return ascending ? ordered : ordered.reversed()
    }

    /// Returns every network matching the query in the table's current sort order.
    ///
    /// A network's Docker-managed status is a column value, not a second table section:
    /// clicking a native column header always orders the entire visible collection.
    static func visible(
        networks: [NetworkSummary],
        query: String,
        sortKey: TrackCNetworkSortKey,
        ascending: Bool
    ) -> [NetworkSummary] {
        sorted(networks.filter { matches($0, query: query) }, by: sortKey, ascending: ascending)
    }

    static func kindLabel(for network: NetworkSummary) -> String {
        network.isBuiltIn ? "Built-in" : "User-defined"
    }

    /// Custom networks with nothing attached — what a prune would take.
    static func unused(_ networks: [NetworkSummary]) -> [NetworkSummary] {
        networks.filter { !$0.isBuiltIn && $0.containers == 0 }
    }
}

/// Table sort, keyed by ``TrackCNetworkSortKey``.
struct TrackCNetworkComparator: SortComparator {
    var key: TrackCNetworkSortKey
    var order: SortOrder = .forward

    func compare(_ lhs: NetworkSummary, _ rhs: NetworkSummary) -> ComparisonResult {
        let result: ComparisonResult
        switch key {
        case .name: result = MorbSort.string(lhs.name, rhs.name)
        case .kind:
            let lhsKind = TrackCNetworkList.kindLabel(for: lhs)
            let rhsKind = TrackCNetworkList.kindLabel(for: rhs)
            result = lhsKind == rhsKind
                ? MorbSort.string(lhs.name, rhs.name)
                : MorbSort.string(lhsKind, rhsKind)
        case .driver:
            result = lhs.driver == rhs.driver
                ? MorbSort.string(lhs.name, rhs.name)
                : MorbSort.string(lhs.driver, rhs.driver)
        case .scope:
            result = lhs.scope == rhs.scope
                ? MorbSort.string(lhs.name, rhs.name)
                : MorbSort.string(lhs.scope, rhs.scope)
        case .containers: result = MorbSort.int(lhs.containers, rhs.containers)
        }
        return order == .forward ? result : result.reversed
    }
}

private struct NetworkOperationAlert {
    var title: String
    var message: String
    var focusID: NetworkSummary.ID?
}

/// One precisely identified network captured before a multi-network removal starts.
///
/// Docker's single-network delete endpoint accepts this ID. Keeping it alongside the
/// displayed name ensures confirmation and execution describe the same records, even
/// if the network list changes while the review sheet is open.
private struct UnusedNetworkRemovalTarget: Identifiable, Hashable {
    let id: NetworkSummary.ID
    let name: String
    let driver: String
    let scope: String
}

/// The exact set of currently-unused user-defined networks that the review sheet shows.
private struct UnusedNetworkRemovalPlan: Identifiable {
    let id = UUID()
    let targets: [UnusedNetworkRemovalTarget]

    init(networks: [NetworkSummary]) {
        targets = TrackCNetworkList.unused(networks)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map {
                UnusedNetworkRemovalTarget(
                    id: $0.id,
                    name: $0.name,
                    driver: $0.driver,
                    scope: $0.scope)
            }
    }

    var countLabel: String {
        "\(targets.count) unused network\(targets.count == 1 ? "" : "s")"
    }
}

/// A system sheet that reviews the exact network IDs passed to Docker for removal.
private struct UnusedNetworkRemovalReview: View {
    let plan: UnusedNetworkRemovalPlan
    let onConfirm: ([UnusedNetworkRemovalTarget]) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(
                        "Review these networks before removing them. Containers created on a removed "
                            + "network will need it recreated.")
                }

                Section("Will Be Removed") {
                    ForEach(plan.targets) { target in
                        VStack(alignment: .leading) {
                            Text(target.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(target.driver) · \(target.scope) · \(String(target.id.prefix(12)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            .navigationTitle("Remove Unused Networks")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Remove \(plan.countLabel)", role: .destructive) {
                        dismiss()
                        onConfirm(plan.targets)
                    }
                    .disabled(plan.targets.isEmpty)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 340)
    }
}

// MARK: - Root

struct NetworksRootView: View {

    let model: AppModel

    @State private var query = ""
    @State private var sortOrder: [TrackCNetworkComparator] = [TrackCNetworkComparator(key: .name)]
    @State private var selection: NetworkSummary.ID?

    @State private var unusedRemovalPlan: UnusedNetworkRemovalPlan?
    @State private var removal: NetworkSummary?
    @State private var busy = false
    @State private var operationAlert: NetworkOperationAlert?
    /// Whether the trailing inspector column is open. SwiftUI restores this across
    /// launches for a trailing-column inspector, so it is not persisted here.
    @State private var showsInspector = true

    private var visibleNetworks: [NetworkSummary] {
        let key = sortOrder.first?.key ?? .name
        let ascending = (sortOrder.first?.order ?? .forward) == .forward
        return TrackCNetworkList.visible(
            networks: model.networks, query: query, sortKey: key, ascending: ascending)
    }

    private var unusedCount: Int { TrackCNetworkList.unused(model.networks).count }

    private var subtitle: String {
        let custom = model.networks.filter { !$0.isBuiltIn }.count
        var parts = ["\(model.networks.count) network\(model.networks.count == 1 ? "" : "s")"]
        parts.append("\(custom) user-defined")
        if unusedCount > 0 { parts.append("\(unusedCount) unused") }
        return parts.joined(separator: " · ")
    }

    private var selectedNetwork: NetworkSummary? {
        guard let selection else { return nil }
        return model.networks.first { $0.id == selection }
    }

    var body: some View {
        content
            .navigationTitle("Networks")
            .navigationSubtitle(subtitle)
            .searchable(text: $query, placement: .toolbar, prompt: "Name, driver, ID")
            .toolbar { toolbarContent }
            .sheet(item: $unusedRemovalPlan) { plan in
                UnusedNetworkRemovalReview(plan: plan) { targets in
                    Task { await removeUnused(targets) }
                }
            }
            .alert(
                removal.map { "Remove \($0.name)?" } ?? "",
                isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
                presenting: removal
            ) { network in
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) { Task { await remove(network) } }
            } message: { network in
                if network.containers > 0 {
                    Text(
                        "\(network.containers) container\(network.containers == 1 ? "" : "s") "
                        + "are attached. The engine will refuse until they are disconnected or removed.")
                } else {
                    Text("Containers created on this network later will need it recreated.")
                }
            }
            .alert(
                operationAlert?.title ?? "",
                isPresented: Binding(
                    get: { operationAlert != nil },
                    set: { if !$0 { operationAlert = nil } }
                ),
                presenting: operationAlert
            ) { alert in
                if let id = alert.focusID {
                    Button("Show Network") {
                        selection = id
                        showsInspector = true
                    }
                }
                Button("OK", role: .cancel) {}
            } message: { alert in
                Text(alert.message)
            }
            .onDeleteCommand {
                guard !busy,
                      let selection,
                      let network = model.networks.first(where: { $0.id == selection }),
                      !network.isBuiltIn,
                      network.containers == 0
                else { return }
                removal = network
            }
            .onChange(of: query) { _, _ in
                if let selection,
                   !visibleNetworks.contains(where: { $0.id == selection }) {
                    self.selection = visibleNetworks.first?.id
                }
            }
            // Selects the first row so the inspector opens with something to show — see
            // the identical note in `VolumesRootView`.
            .task {
                if selection == nil { selection = visibleNetworks.first?.id }
            }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(id: "networks.removeUnused", placement: .secondaryAction) {
            if busy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Removing networks")
            } else {
                Button(role: .destructive) {
                    reviewUnusedNetworks()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(unusedCount == 0)
                .accessibilityLabel("Remove unused networks")
                .help(
                    unusedCount == 0
                        ? "Every user-defined network has containers attached"
                        : "Review and remove \(unusedCount) unused network\(unusedCount == 1 ? "" : "s")")
            }
        }
        if !model.networks.isEmpty {
            // Network inventory has no universal primary task.  Keep the inspector
            // as a navigation affordance and reserve the primary region for a future
            // contextual operation rather than turning this toggle into one.
            ToolbarItem(id: "networks.inspector", placement: .automatic) {
                Button {
                    showsInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .accessibilityLabel(showsInspector ? "Hide inspector" : "Show inspector")
                .help(showsInspector ? "Hide the inspector" : "Show the inspector")
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.networks.isEmpty {
            ContentUnavailableView {
                Label("No Networks", systemImage: "network")
            } description: {
                Text("No Docker networks are reported by the engine.")
            } actions: {
                Button {
                    Task { await model.refreshAll() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button {
                    MorbPasteboard.copy(
                        "docker --host unix://\(MorbPaths.dockerSocket.path) network create my-network")
                } label: {
                    Label("Copy a Create Command", systemImage: "doc.on.doc")
                }
            }
        } else if visibleNetworks.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            table
                .inspector(isPresented: $showsInspector) {
                    detailPane
                        .inspectorColumnWidth(min: 340, ideal: 400, max: 460)
                }
        }
    }

    private var table: some View {
        Table(of: NetworkSummary.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", sortUsing: TrackCNetworkComparator(key: .name)) { network in
                nameCell(network)
            }
            TableColumn("Kind", sortUsing: TrackCNetworkComparator(key: .kind)) { network in
                Text(TrackCNetworkList.kindLabel(for: network))
                    .foregroundStyle(.secondary)
            }
            .width(min: 96, ideal: 108, max: 136)
            TableColumn("Driver", sortUsing: TrackCNetworkComparator(key: .driver)) { network in
                Text(network.driver)
                    .foregroundStyle(.secondary)
            }
            .width(min: 84, ideal: 100, max: 140)
            TableColumn("Scope", sortUsing: TrackCNetworkComparator(key: .scope)) { network in
                Text(network.scope)
                    .foregroundStyle(.secondary)
            }
            .width(min: 64, ideal: 78, max: 110)
            TableColumn("Containers", sortUsing: TrackCNetworkComparator(key: .containers)) { network in
                containersCell(network)
            }
            .width(min: 76, ideal: 92, max: 120)
        } rows: {
            ForEach(visibleNetworks) { network in
                TableRow(network)
            }
        }
        .contextMenu(forSelectionType: NetworkSummary.ID.self) { ids in
            contextMenu(for: ids)
        }
    }

    private func nameCell(_ network: NetworkSummary) -> some View {
        Text(network.name)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    @ViewBuilder
    private func containersCell(_ network: NetworkSummary) -> some View {
        if network.containers > 0 {
            Text(network.containers, format: .number)
                .monospacedDigit()
        } else {
            Text("None")
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<NetworkSummary.ID>) -> some View {
        if let id = ids.first, let network = model.networks.first(where: { $0.id == id }) {
            Button("Copy Name") { MorbPasteboard.copy(network.name) }
            Button("Copy Network ID") { MorbPasteboard.copy(network.id) }
            if !network.isBuiltIn {
                Divider()
                Button("Remove…", role: .destructive) { removal = network }
                    .disabled(network.containers > 0 || busy)
                    .help(
                        network.containers > 0
                            ? "Disconnect every attached container first"
                            : "Remove this network")
            }
        }
    }

    // MARK: Detail pane

    /// A native `Form`, not a stack of hand-drawn cards — see the note on
    /// `VolumesRootView.detailPane`.
    @ViewBuilder
    private var detailPane: some View {
        if let network = selectedNetwork {
            Form {
                Section("Network") {
                    LabeledContent("Name") {
                        Text(network.name)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Status", value: network.containers > 0 ? "In use" : "Unused")
                    LabeledContent(
                        "Containers",
                        value: "\(network.containers) attached")
                    LabeledContent("Driver", value: network.driver)
                    LabeledContent("Scope", value: network.scope)
                    LabeledContent("Network ID") {
                        Text(network.id)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Section("Kind") {
                    LabeledContent("Network", value: TrackCNetworkList.kindLabel(for: network))
                    LabeledContent(
                        "Removal",
                        value: network.isBuiltIn
                            ? "Managed by Docker"
                            : (network.containers > 0 ? "Detach containers first" : "Available"))
                }

            }
        } else {
            ContentUnavailableView(
                "No Network Selected",
                systemImage: "network",
                description: Text("Pick a network to see its driver, scope and what is attached to it."))
        }
    }

    // MARK: Operations

    private func reviewUnusedNetworks() {
        let plan = UnusedNetworkRemovalPlan(networks: model.networks)
        guard !plan.targets.isEmpty else { return }
        unusedRemovalPlan = plan
    }

    @MainActor
    private func remove(_ network: NetworkSummary) async {
        guard !network.isBuiltIn, network.containers == 0, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await model.client.removeNetwork(id: network.id)
            if selection == network.id { selection = nil }
            await model.refreshAll()
        } catch {
            operationAlert = NetworkOperationAlert(
                title: "Could not remove \(network.name)",
                message: MorbErrorMessage.text(for: error),
                focusID: network.id)
        }
    }

    @MainActor
    private func removeUnused(_ targets: [UnusedNetworkRemovalTarget]) async {
        guard !targets.isEmpty, !busy else { return }
        busy = true
        defer { busy = false }

        var removed = 0
        var failures: [UnusedNetworkRemovalTarget] = []

        for target in targets {
            do {
                try await model.client.removeNetwork(id: target.id)
                removed += 1
                if selection == target.id { selection = nil }
            } catch {
                failures.append(target)
            }
        }

        if failures.isEmpty {
            // The refreshed table and subtitle provide the native acknowledgement.
        } else if removed > 0 {
            operationAlert = NetworkOperationAlert(
                title: "Removed \(removed) of \(targets.count) networks",
                message: "Still in use or unavailable: \(failures.prefix(3).map(\.name).joined(separator: ", ")).",
                focusID: failures.first?.id)
        } else {
            operationAlert = NetworkOperationAlert(
                title: "No networks were removed",
                message: "The selected networks are still in use or unavailable.",
                focusID: failures.first?.id)
        }
        await model.refreshAll()
    }
}
