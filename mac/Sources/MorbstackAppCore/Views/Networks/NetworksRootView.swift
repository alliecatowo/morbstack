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
// A real `Table` replaces the hand-rolled grid, grouped into the two sections `Table`
// itself supports, and a detail pane gives the screen something to show besides a thin
// row of five short strings — see `docs/design/CRITIQUE.md` on the empty Networks window.
// The pane is a real `.inspector(isPresented:)` trailing column — see the note in
// `VolumesRootView` about why the old `HSplitView` was the screenshot harness talking.

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
        case .name: result = trackCCompareStrings(lhs.name, rhs.name)
        case .driver:
            result = lhs.driver == rhs.driver
                ? trackCCompareStrings(lhs.name, rhs.name)
                : trackCCompareStrings(lhs.driver, rhs.driver)
        case .scope:
            result = lhs.scope == rhs.scope
                ? trackCCompareStrings(lhs.name, rhs.name)
                : trackCCompareStrings(lhs.scope, rhs.scope)
        case .containers: result = trackCCompareInt(lhs.containers, rhs.containers)
        }
        return order == .forward ? result : result.reversed
    }
}

// MARK: - Root

struct NetworksRootView: View {

    let model: AppModel

    @State private var query = ""
    @State private var sortOrder: [TrackCNetworkComparator] = [TrackCNetworkComparator(key: .name)]
    @State private var selection: NetworkSummary.ID?

    @State private var removal: NetworkSummary?
    @State private var showingPruneSheet = false
    @State private var busy = false
    @State private var toast: TrackCToast?
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
            .morbScreen(title: "Networks", subtitle: subtitle, edge: .hard)
            .searchable(text: $query, placement: .toolbar, prompt: "Name, driver, ID")
            .toolbar { toolbarContent }
            .trackCToast($toast)
            .sheet(isPresented: $showingPruneSheet) {
                let unused = TrackCNetworkList.unused(model.networks)
                TrackCConfirmSheet(
                    title: "Remove unused networks",
                    symbol: "network.badge.shield.half.filled",
                    explanation:
                        "These user-defined networks have no containers attached. Removing one is cheap — "
                        + "a compose stack recreates its network the next time it comes up.",
                    items: unused.map {
                        TrackCPruneItem(id: $0.id, title: $0.name, detail: "\($0.driver) · \($0.scope)", bytes: nil)
                    },
                    knownBytes: 0,
                    hasUnknownSizes: false,
                    confirmTitle: "Remove \(unused.count)",
                    onConfirm: { Task { await pruneUnused() } })
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
            .onDeleteCommand {
                guard let selection,
                      let network = model.networks.first(where: { $0.id == selection }),
                      !network.isBuiltIn
                else { return }
                removal = network
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
        ToolbarItem(id: "networks.removeUnused", placement: MorbToolbarGroup.actions) {
            Button {
                showingPruneSheet = true
            } label: {
                Label("Remove Unused", systemImage: "trash")
            }
            .disabled(unusedCount == 0 || busy)
            .help(
                unusedCount == 0
                    ? "Every user-defined network has containers attached"
                    : "Review and remove \(unusedCount) unused network\(unusedCount == 1 ? "" : "s")")
        }
        MorbInspectorToggle(id: "networks.inspector", isPresented: $showsInspector)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let split = sections
        if model.networks.isEmpty {
            MorbEmptyState(
                "No networks",
                systemImage: "network",
                description: "Start the engine and Docker's three built-in networks will appear here.")
        } else if split.custom.isEmpty && split.builtIn.isEmpty {
            MorbNoMatches(query: query)
        } else {
            table(split)
                .inspector(isPresented: $showsInspector) {
                    detailPane
                        .inspectorColumnWidth(
                            min: Theme.inspectorMinWidth,
                            ideal: Theme.inspectorWidth,
                            max: 460)
                }
        }
    }

    private func table(_ split: (custom: [NetworkSummary], builtIn: [NetworkSummary])) -> some View {
        Table(of: NetworkSummary.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", sortUsing: TrackCNetworkComparator(key: .name)) { network in
                nameCell(network)
                    .frame(height: Theme.rowStandard, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            TableColumn("Driver", sortUsing: TrackCNetworkComparator(key: .driver)) { network in
                Text(network.driver)
                    .foregroundStyle(.secondary)
                    .frame(height: Theme.rowStandard, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(network.isBuiltIn ? 0.8 : 1)
            }
            .width(min: 84, ideal: 100, max: 140)
            TableColumn("Scope", sortUsing: TrackCNetworkComparator(key: .scope)) { network in
                Text(network.scope)
                    .foregroundStyle(.secondary)
                    .frame(height: Theme.rowStandard, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(network.isBuiltIn ? 0.8 : 1)
            }
            .width(min: 64, ideal: 78, max: 110)
            TableColumn("Containers", sortUsing: TrackCNetworkComparator(key: .containers)) { network in
                containersCell(network)
                    .frame(height: Theme.rowStandard, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 76, ideal: 92, max: 120)
        } rows: {
            if !split.custom.isEmpty {
                Section("User-defined") {
                    ForEach(split.custom) { TableRow($0) }
                }
            }
            if !split.builtIn.isEmpty {
                Section("Built in") {
                    ForEach(split.builtIn) { TableRow($0) }
                }
            }
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds()
        .contextMenu(forSelectionType: NetworkSummary.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            if let id = ids.first { selection = id }
        }
    }

    private func nameCell(_ network: NetworkSummary) -> some View {
        HStack(spacing: Theme.space2) {
            MorbStatusDot(tone: network.isBuiltIn ? .idle : (network.containers > 0 ? .running : .idle))
            Text(network.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if network.isBuiltIn {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .help("Built-in network — Docker will not let this be removed")
            }
        }
        .opacity(network.isBuiltIn ? 0.8 : 1)
    }

    @ViewBuilder
    private func containersCell(_ network: NetworkSummary) -> some View {
        if network.containers > 0 {
            MorbCountBadge(count: network.containers, tone: .running)
        } else {
            Text("none").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<NetworkSummary.ID>) -> some View {
        if let id = ids.first, let network = model.networks.first(where: { $0.id == id }) {
            Button("Copy Name") { trackCCopy(network.name) }
            Button("Copy Network ID") { trackCCopy(network.id) }
            if !network.isBuiltIn {
                Divider()
                Button("Remove…", role: .destructive) { removal = network }
            }
        }
    }

    // MARK: Detail pane

    /// A grouped `Form`, not a stack of hand-drawn cards — see the note on
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
                    LabeledContent("Status") {
                        MorbStatusBadge(
                            tone: network.containers > 0 ? .running : .idle,
                            title: network.containers > 0
                                ? "\(network.containers) container\(network.containers == 1 ? "" : "s") attached"
                                : "No containers attached",
                            filled: false)
                    }
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
                    Text(network.isBuiltIn
                         ? "Built in — created by the engine, and cannot be removed."
                         : "User-defined — created by compose, or by morb network create.")
                        .foregroundStyle(.secondary)
                }

                if !network.isBuiltIn {
                    Section {
                        Button(role: .destructive) {
                            removal = network
                        } label: {
                            Label("Remove Network", systemImage: "trash")
                        }
                        .disabled(network.containers > 0)
                        .help(
                            network.containers > 0
                                ? "Disconnect every attached container first"
                                : "Remove this network")
                    }
                }
            }
            .formStyle(.grouped)
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
        guard !network.isBuiltIn else { return }
        busy = true
        defer { busy = false }
        do {
            try await model.client.removeNetwork(id: network.id)
            toast = .success("Removed \(network.name)")
            if selection == network.id { selection = nil }
            await model.refreshAll()
        } catch {
            toast = .failure("Could not remove \(network.name)", detail: trackCErrorText(error))
        }
    }

    @MainActor
    private func pruneUnused() async {
        busy = true
        defer { busy = false }
        let before = unusedCount
        do {
            // `/networks/prune` reclaims no bytes worth reporting, so the toast counts
            // networks instead of pretending a disk saving happened.
            _ = try await model.client.pruneNetworks()
            await model.refreshAll()
            let after = TrackCNetworkList.unused(model.networks).count
            let removed = max(0, before - after)
            toast = removed > 0
                ? .success("Removed \(removed) network\(removed == 1 ? "" : "s")")
                : .info("Nothing was removed", detail: "The engine kept every unused network.")
        } catch {
            toast = .failure("Prune failed", detail: trackCErrorText(error))
        }
    }
}
