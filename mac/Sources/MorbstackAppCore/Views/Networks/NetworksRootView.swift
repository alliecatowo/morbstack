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

import SwiftUI

// MARK: - Layout

private enum NetworkColumns {
    static let driver: CGFloat = 96
    static let scope: CGFloat = 78
    static let containers: CGFloat = 88
    static let actions: CGFloat = 52
}

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

// MARK: - Root

struct NetworksRootView: View {

    let model: AppModel

    @State private var query = ""
    @State private var sortKey: TrackCNetworkSortKey = .name
    @State private var ascending = true
    @State private var selection: NetworkSummary.ID?

    @State private var removal: NetworkSummary?
    @State private var showingPruneSheet = false
    @State private var busy = false
    @State private var toast: TrackCToast?

    private var sections: (custom: [NetworkSummary], builtIn: [NetworkSummary]) {
        TrackCNetworkList.sections(
            networks: model.networks, query: query, sortKey: sortKey, ascending: ascending)
    }

    private var unusedCount: Int { TrackCNetworkList.unused(model.networks).count }

    private var subtitle: String {
        let custom = model.networks.filter { !$0.isBuiltIn }.count
        var parts = ["\(model.networks.count) network\(model.networks.count == 1 ? "" : "s")"]
        parts.append("\(custom) user-defined")
        if unusedCount > 0 { parts.append("\(unusedCount) unused") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            TrackCPageHeader(title: "Networks", subtitle: subtitle) {
                HStack(spacing: 8) {
                    TrackCSearchField(text: $query, prompt: "Filter networks")
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
            }

            Divider()

            TrackCHeaderBar {
                TrackCSortHeader(
                    title: "Name", key: TrackCNetworkSortKey.name,
                    active: $sortKey, ascending: $ascending)
                TrackCSortHeader(
                    title: "Driver", key: TrackCNetworkSortKey.driver,
                    active: $sortKey, ascending: $ascending)
                    .frame(width: NetworkColumns.driver)
                TrackCSortHeader(
                    title: "Scope", key: TrackCNetworkSortKey.scope,
                    active: $sortKey, ascending: $ascending)
                    .frame(width: NetworkColumns.scope)
                TrackCSortHeader(
                    title: "Containers", key: TrackCNetworkSortKey.containers,
                    active: $sortKey, ascending: $ascending, alignment: .trailing)
                    .frame(width: NetworkColumns.containers)
                Color.clear.frame(width: NetworkColumns.actions, height: 1)
            }
            .padding(.top, 8)

            content
        }
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
    }

    @ViewBuilder
    private var content: some View {
        let split = sections
        if model.networks.isEmpty {
            TrackCEmptyState(
                title: "No networks",
                message: "Start the engine and Docker's three built-in networks will appear here.",
                symbol: "network")
        } else if split.custom.isEmpty && split.builtIn.isEmpty {
            TrackCEmptyState(
                title: "No matches",
                message: "Nothing here matches “\(query)”.",
                symbol: "magnifyingglass",
                action: (title: "Clear Filter", run: { query = "" }))
        } else {
            List(selection: $selection) {
                if !split.custom.isEmpty {
                    Section {
                        ForEach(split.custom) { network in
                            TrackCNetworkRow(network: network, onRemove: { removal = network })
                                .tag(network.id)
                        }
                    }
                } else {
                    Section {
                        Text("No user-defined networks yet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(height: TrackCMetrics.rowHeight)
                    }
                }

                if !split.builtIn.isEmpty {
                    Section {
                        ForEach(split.builtIn) { network in
                            TrackCNetworkRow(network: network, onRemove: {})
                                .tag(network.id)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.fill").font(.system(size: 9))
                            Text("Built in").font(.caption.weight(.semibold))
                            Spacer()
                        }
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                    }
                }
            }
            .listStyle(.inset)
            // No `.alternatingRowBackgrounds()`. AppKit stripes the whole viewport, not the
            // rows that exist, so six networks in a 900pt window are followed by ten empty
            // bands and the screen reads as a half-loaded skeleton. The hairline separators
            // `List` draws anyway are enough to track a row across four columns, and they
            // stop where the data does.
            .environment(\.defaultMinListRowHeight, TrackCMetrics.rowHeight)
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

// MARK: - Row

private struct TrackCNetworkRow: View {

    let network: NetworkSummary
    let onRemove: () -> Void

    @State private var hovering = false

    private var tone: TrackCTone {
        if network.isBuiltIn { return .neutral }
        return network.containers > 0 ? .good : .neutral
    }

    var body: some View {
        HStack(spacing: TrackCMetrics.columnGap) {
            HStack(spacing: 6) {
                TrackCStatusDot(tone: tone)
                Text(network.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if network.isBuiltIn {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .help("Built-in network — Docker will not let this be removed")
                }
                Spacer(minLength: 0)
            }

            Text(network.driver)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: NetworkColumns.driver, alignment: .leading)

            Text(network.scope)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: NetworkColumns.scope, alignment: .leading)

            containersCell
                .frame(width: NetworkColumns.containers, alignment: .trailing)

            TrackCHoverActions(revealed: hovering && !network.isBuiltIn) {
                if network.isBuiltIn {
                    // A disabled trash can invites a click and then says nothing. An
                    // explicit lock says why before the pointer gets there.
                    Image(systemName: "lock")
                        .font(.system(size: 11))
                        .foregroundStyle(.quaternary)
                        .frame(width: 22, height: 20)
                        .help("Docker's built-in networks cannot be removed")
                } else {
                    TrackCRowButton(symbol: "trash", help: "Remove this network", tone: .bad, action: onRemove)
                }
            }
            .frame(width: NetworkColumns.actions)
        }
        .frame(height: TrackCMetrics.rowHeight)
        // The whole built-in row recedes, not just its name: it is context, not content.
        // Built-in networks are demoted, not disabled: `bridge` really does have two
        // containers on it and that number has to stay readable. At 0.62 the whole row
        // fell under 3:1 in both appearances and looked like a control you could not
        // click, which is only half true — you cannot remove them, but everything else
        // about them is live.
        .opacity(network.isBuiltIn ? 0.8 : 1)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy Name") { trackCCopy(network.name) }
            Button("Copy Network ID") { trackCCopy(network.id) }
            if !network.isBuiltIn {
                Divider()
                Button("Remove…", role: .destructive, action: onRemove)
            }
        }
    }

    @ViewBuilder
    private var containersCell: some View {
        if network.containers > 0 {
            TrackCBadge(text: "\(network.containers)", symbol: "shippingbox.fill", tone: .good)
        } else {
            Text("none").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
