// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The Networks screen.
//
// Mostly a read-only inventory. The one interesting design problem is `bridge`, `host`
// and `none`: they are always present, they are never what the user came here to look
// at, and the engine will refuse to delete them. Rather than let them sit at the top of
// the list looking like ordinary rows with a broken delete button, they are pushed to
// their own section, drawn at reduced emphasis, and carry a lock instead of a trash can.
//
// A standard `Table` presents the two operational groups, while selection reveals the
// chosen network's facts in the system inspector. This keeps inventory, selection, and
// detail as distinct macOS interactions instead of a hand-built split layout.

import AppKit
import SwiftUI

// MARK: - Sorting and filtering

enum TrackCNetworkSortKey: String, Hashable, CaseIterable {
    case name
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

    /// Splits into the user's own networks and Docker's three permanent ones.
    ///
    /// Built-ins keep a fixed `bridge, host, none` order rather than following the
    /// table's sort: they are a footnote, and a footnote that reorders itself when you
    /// click a column header is just noise.
    static func sections(
        networks: [NetworkSummary],
        query: String,
        sortKey: TrackCNetworkSortKey,
        ascending: Bool
    ) -> (custom: [NetworkSummary], builtIn: [NetworkSummary]) {
        let visible = networks.filter { matches($0, query: query) }
        let custom = sorted(visible.filter { !$0.isBuiltIn }, by: sortKey, ascending: ascending)
        let order = ["bridge", "host", "none"]
        let builtIn = visible.filter(\.isBuiltIn).sorted {
            (order.firstIndex(of: $0.name) ?? order.count) < (order.firstIndex(of: $1.name) ?? order.count)
        }
        return (custom, builtIn)
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

// MARK: - Root

struct NetworksRootView: View {

    let model: AppModel

    @State private var query = ""
    @State private var sortOrder: [TrackCNetworkComparator] = [TrackCNetworkComparator(key: .name)]
    @State private var selection: NetworkSummary.ID?

    @State private var removal: NetworkSummary?
    @State private var showingPruneConfirmation = false
    @State private var busy = false
    @State private var operationAlert: NetworkOperationAlert?
    /// Whether the trailing inspector column is open. SwiftUI restores this across
    /// launches for a trailing-column inspector, so it is not persisted here.
    @State private var showsInspector = true

    private var sections: (custom: [NetworkSummary], builtIn: [NetworkSummary]) {
        let key = sortOrder.first?.key ?? .name
        let ascending = (sortOrder.first?.order ?? .forward) == .forward
        return TrackCNetworkList.sections(
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
            .confirmationDialog(
                "Remove unused networks?",
                isPresented: $showingPruneConfirmation,
                titleVisibility: .visible
            ) {
                let unused = TrackCNetworkList.unused(model.networks)
                Button(
                    "Remove \(unused.count) Unused Network\(unused.count == 1 ? "" : "s")",
                    role: .destructive
                ) {
                    Task { await pruneUnused() }
                }
            } message: {
                let unused = TrackCNetworkList.unused(model.networks)
                Text(
                    "These \(unused.count) user-defined network\(unused.count == 1 ? "" : "s") have no "
                        + "attached containers. Compose recreates a network the next time its stack starts.")
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
                      !network.isBuiltIn
                else { return }
                removal = network
            }
            .onChange(of: query) { _, _ in
                let split = sections
                let visible = split.custom + split.builtIn
                if let selection,
                   !visible.contains(where: { $0.id == selection }) {
                    self.selection = visible.first?.id
                }
            }
            // Selects the first row so the inspector opens with something to show — see
            // the identical note in `VolumesRootView`.
            .task {
                if selection == nil { selection = sections.custom.first?.id ?? sections.builtIn.first?.id }
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
                    showingPruneConfirmation = true
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
            ToolbarItem(id: "networks.inspector", placement: .primaryAction) {
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
        let split = sections
        if model.networks.isEmpty {
            ContentUnavailableView {
                Label("No Networks", systemImage: "network")
            } description: {
                Text("Docker's built-in networks appear here once the engine has started.")
            } actions: {
                Button {
                    Task { await model.refreshAll() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        } else if split.custom.isEmpty && split.builtIn.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            table(split)
                .inspector(isPresented: $showsInspector) {
                    detailPane
                }
        }
    }

    private func table(_ split: (custom: [NetworkSummary], builtIn: [NetworkSummary])) -> some View {
        Table(of: NetworkSummary.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", sortUsing: TrackCNetworkComparator(key: .name)) { network in
                nameCell(network)
            }
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
            if !split.custom.isEmpty {
                Section("User-defined") {
                    ForEach(split.custom) { TableRow($0) }
                }
            }
            if !split.builtIn.isEmpty {
                Section("Built-in") {
                    ForEach(split.builtIn) { TableRow($0) }
                }
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
                    .disabled(busy)
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
                    LabeledContent("Network", value: network.isBuiltIn ? "Built in" : "User-defined")
                    LabeledContent(
                        "Removal",
                        value: network.isBuiltIn
                            ? "Managed by Docker"
                            : (network.containers > 0 ? "Detach containers first" : "Available"))
                }

                if !network.isBuiltIn {
                    Section {
                        Button(role: .destructive) {
                            removal = network
                        } label: {
                            Label("Remove Network", systemImage: "trash")
                        }
                        .disabled(network.containers > 0 || busy)
                        .help(
                            network.containers > 0
                                ? "Disconnect every attached container first"
                                : "Remove this network")
                    }
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

    @MainActor
    private func remove(_ network: NetworkSummary) async {
        guard !network.isBuiltIn, !busy else { return }
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
    private func pruneUnused() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            // `/networks/prune` reclaims no bytes worth reporting, so the toast counts
            // networks instead of pretending a disk saving happened.
            _ = try await model.client.pruneNetworks()
            await model.refreshAll()
        } catch {
            operationAlert = NetworkOperationAlert(
                title: "Could not remove unused networks",
                message: MorbErrorMessage.text(for: error),
                focusID: TrackCNetworkList.unused(model.networks).first?.id)
        }
    }
}
