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
                        "Removing a network does not delete containers. To attach a container later, "
                            + "create a network and connect the container to it.")
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
                        .accessibilityIdentifier("networks.removeUnusedSheet.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Remove \(plan.countLabel)", role: .destructive) {
                        dismiss()
                        onConfirm(plan.targets)
                    }
                    .disabled(plan.targets.isEmpty)
                    .accessibilityIdentifier("networks.removeUnusedSheet.remove")
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
    @State private var isShowingNetworkCreate = false
    @State private var isCreatingNetwork = false
    @State private var networkForConnection: NetworkInspection?
    @State private var disconnectTarget: NetworkDisconnectRequest?
    @State private var isChangingNetworkMembership = false
    @State private var inspection: NetworkInspection?
    @State private var inspectionError: String?
    @State private var isLoadingInspection = false
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

    private var isPerformingNetworkOperation: Bool {
        busy || isCreatingNetwork || isChangingNetworkMembership
    }

    // As one literal expression this modifier chain exceeded what the type checker
    // could solve in reasonable time. The chain is split into staged helpers applied
    // in the original order — no modifier was added, removed, or reordered.
    var body: some View {
        withSelectionAndLifecycle(
            withOperationAlerts(
                withSheetsAndDialogs(
                    content
                        .navigationTitle("Networks")
                        .navigationSubtitle(subtitle)
                        .toolbar { toolbarContent }
                        // The menu-bar mirror of the toolbar's remove-unused command,
                        // so it stays reachable when the toolbar overflows.
                        .focusedSceneValue(
                            \.routeMaintenanceCommand,
                            RouteMaintenanceCommand(
                                title: "Remove Unused Networks…",
                                isEnabled: unusedCount > 0 && !isPerformingNetworkOperation,
                                perform: { reviewUnusedNetworks() })))))
    }

    private func withSheetsAndDialogs(_ view: some View) -> some View {
        view
            .sheet(item: $unusedRemovalPlan) { plan in
                UnusedNetworkRemovalReview(plan: plan) { targets in
                    Task { await removeUnused(targets) }
                }
            }
            .sheet(isPresented: $isShowingNetworkCreate) {
                NetworkCreateSheet { request in
                    try await createNetwork(request)
                }
            }
            .sheet(item: $networkForConnection) { network in
                NetworkConnectSheet(
                    network: network,
                    candidates: NetworkMembershipCandidates.connectable(
                        containers: model.containers,
                        members: network.members)
                ) { request in
                    try await connect(request)
                }
            }
            .confirmationDialog(
                disconnectTarget.map { "Disconnect \($0.containerName)?" } ?? "",
                isPresented: Binding(
                    get: { disconnectTarget != nil },
                    set: { if !$0 { disconnectTarget = nil } }
                ),
                titleVisibility: .visible,
                presenting: disconnectTarget
            ) { target in
                Button("Disconnect", role: .destructive) {
                    disconnectTarget = nil
                    Task { await disconnect(target) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { target in
                Text(
                    "Docker will detach \(target.containerName) from \(target.networkName). "
                        + "It does not stop or remove the container, and it does not change its other network attachments.")
            }
    }

    private func withOperationAlerts(_ view: some View) -> some View {
        view
            .alert(
                removal.map { "Remove \($0.name)?" } ?? "",
                isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
                presenting: removal
            ) { network in
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) { Task { await remove(network) } }
            } message: { network in
                Text(
                    "Docker will permanently remove \(network.name). It does not delete containers. "
                        + "Docker will refuse the removal if a container becomes attached before it completes.")
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
    }

    private func withSelectionAndLifecycle(_ view: some View) -> some View {
        view
            .onDeleteCommand {
                guard !isPerformingNetworkOperation,
                      let selection,
                      let network = model.networks.first(where: { $0.id == selection }),
                      canOfferRemoval(of: network)
                else { return }
                removal = network
            }
            .onChange(of: query) { _, _ in
                if let selection,
                   !visibleNetworks.contains(where: { $0.id == selection }) {
                    self.selection = visibleNetworks.first?.id
                }
            }
            .onChange(of: selection) { _, selectedID in
                if selectedID != nil { showsInspector = true }
            }
            // Selects the first row so the inspector opens with something to show — see
            // the identical note in `VolumesRootView`.
            .task {
                if selection == nil { selection = visibleNetworks.first?.id }
            }
            .task(id: selection) {
                await loadSelectedNetworkInspection()
            }
    }

    // MARK: Toolbar

    /// The trailing commands, mounted on the inspector content while the inspector
    /// is available so the system carries them with the inspector's edge, and in the
    /// window toolbar only on the inspector-less empty screen — see the note on
    /// `VolumesRootView.trailingCommandItems`.
    @ToolbarContentBuilder
    private var trailingCommandItems: some ToolbarContent {
        ToolbarItem(id: "networks.create", placement: .primaryAction) {
            Button {
                isShowingNetworkCreate = true
            } label: {
                Image(systemName: "plus")
            }
            .disabled(isPerformingNetworkOperation)
            .accessibilityIdentifier("networks.create")
            .accessibilityLabel("Create network")
            .help(
                isPerformingNetworkOperation
                    ? "Wait for the current network operation to finish"
                    : "Create a bridge network")
        }
        if !model.networks.isEmpty {
            // Creating is the primary task; the inspector still changes navigation
            // layout and remains system-placed with the other view controls.
            ToolbarItem(id: "networks.inspector", placement: .automatic) {
                Button {
                    showsInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .accessibilityIdentifier("networks.inspector")
                .accessibilityLabel(showsInspector ? "Hide inspector" : "Show inspector")
                .help(showsInspector ? "Hide the inspector" : "Show the inspector")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if model.networks.isEmpty {
            trailingCommandItems
        }
        ToolbarItem(id: "networks.removeUnused", placement: .secondaryAction) {
            if busy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityIdentifier("networks.removeUnused")
                    .accessibilityLabel("Removing networks")
            } else {
                Button(role: .destructive) {
                    reviewUnusedNetworks()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(unusedCount == 0 || isPerformingNetworkOperation)
                .accessibilityIdentifier("networks.removeUnused")
                .accessibilityLabel("Remove unused networks")
                .help(
                    unusedCount == 0
                        ? "Every user-defined network has containers attached"
                        : "Review and remove \(unusedCount) unused network\(unusedCount == 1 ? "" : "s")")
            }
        }
        if isChangingNetworkMembership {
            ToolbarItem(id: "networks.membershipProgress", placement: .secondaryAction) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityIdentifier("networks.membershipProgress")
                    .accessibilityLabel("Updating network membership")
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
                    isShowingNetworkCreate = true
                } label: {
                    Label("Create Network", systemImage: "plus")
                }
                .disabled(isPerformingNetworkOperation)
                .accessibilityIdentifier("networks.empty.noNetworks.create")
                Button {
                    Task { await model.refreshAll() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("networks.empty.noNetworks.refresh")
            }
            .accessibilityIdentifier("networks.empty.noNetworks")
        } else {
            Group {
                if visibleNetworks.isEmpty {
                    // The inspector stays mounted behind the no-results state so the
                    // search field — declared on the inspector content below — remains
                    // on screen to clear or edit the query.
                    ContentUnavailableView.search(text: query)
                } else {
                    table
                }
            }
            .inspector(isPresented: $showsInspector) {
                detailPane
                    .inspectorColumnWidth(min: 340, ideal: 400, max: 460)
                    // See the note on `VolumesRootView`: the trailing commands and
                    // search ride the inspector's toolbar region and remain present
                    // while the inspector is closed.
                    .toolbar { trailingCommandItems }
                    .searchable(text: $query, placement: .toolbar, prompt: "Name, driver, ID")
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
        // See the striping note on `VolumesRootView.table`: system striping past the
        // last record reads as broken placeholder rows at this route's density.
        .alternatingRowBackgrounds(.disabled)
        .accessibilityIdentifier("networks.table")
    }

    private func nameCell(_ network: NetworkSummary) -> some View {
        // `Table` exposes no row-level accessibility modifier, so the row's identity —
        // the engine-facing network name, per docs/design/ACCESSIBILITY-IDENTIFIERS.md —
        // is carried by its Name column cell.
        Text(network.name)
            .lineLimit(1)
            .truncationMode(.middle)
            .accessibilityIdentifier("networks.row.\(network.name)")
    }

    private func containersCell(_ network: NetworkSummary) -> some View {
        // A count column says a number, including zero — "None" beside "3" makes the
        // reader parse two different kinds of value in the same column.
        Text(network.containers, format: .number)
            .monospacedDigit()
            .foregroundStyle(network.containers > 0 ? .primary : .secondary)
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<NetworkSummary.ID>) -> some View {
        if let id = ids.first, let network = model.networks.first(where: { $0.id == id }) {
            Button("Copy Name") { MorbPasteboard.copy(network.name) }
            Button("Copy Network ID") { MorbPasteboard.copy(network.id) }

            // A context menu is the selected-record command path when a narrow window
            // has hidden the trailing inspector. Show only operations Docker can accept
            // for this inspected record; the inspector retains the full explanation for
            // unavailable commands.
            if let inspection, inspection.id == network.id {
                let connectableContainers = NetworkMembershipCandidates.connectable(
                    containers: model.containers,
                    members: inspection.members)
                let connectUnavailableReason = NetworkMembershipCandidates.connectAvailabilityReason(
                    for: inspection,
                    candidates: connectableContainers)
                let disconnectableMembers = NetworkMembershipCandidates.disconnectable(
                    members: inspection.members,
                    containers: model.containers)
                let disconnectUnavailableReason = NetworkMembershipCandidates.disconnectUnavailableReason(
                    for: inspection,
                    members: inspection.members,
                    containers: model.containers)

                if connectUnavailableReason == nil
                    || (disconnectUnavailableReason == nil && !disconnectableMembers.isEmpty)
                {
                    Divider()
                    if connectUnavailableReason == nil {
                        Button("Connect Container…") {
                            networkForConnection = inspection
                        }
                        .disabled(isPerformingNetworkOperation)
                        .accessibilityLabel("Connect a container to \(inspection.name)")
                        .help("Choose a running container that is not already attached to \(inspection.name)")
                    }
                    if disconnectUnavailableReason == nil, !disconnectableMembers.isEmpty {
                        disconnectMenu(for: inspection, members: disconnectableMembers)
                    }
                }
            }

            if !network.isBuiltIn {
                let removable = canOfferRemoval(of: network)
                Divider()
                Button("Remove…", role: .destructive) { removal = network }
                    .disabled(!removable || isPerformingNetworkOperation)
                    .accessibilityLabel("Remove network \(network.name)")
                    .help(
                        !removable
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
            if let inspection, inspection.id == network.id {
                inspectionForm(inspection, summary: network)
            } else if isLoadingInspection {
                ProgressView("Loading Network Details")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let inspectionError {
                ContentUnavailableView {
                    Label("Network Details Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(inspectionError)
                } actions: {
                    Button("Try Again") {
                        Task { await loadSelectedNetworkInspection() }
                    }
                }
            } else {
                ProgressView("Loading Network Details")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ContentUnavailableView(
                "No Network Selected",
                systemImage: "network",
                description: Text("Select a network to see its driver, scope and what is attached to it."))
        }
    }

    private func inspectionForm(_ inspection: NetworkInspection, summary: NetworkSummary) -> some View {
        Form {
            Section("Network") {
                LabeledContent("Name") {
                    Text(inspection.name)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                LabeledContent("Driver", value: inspection.driver)
                LabeledContent("Scope", value: inspection.scope)
                LabeledContent("Kind", value: TrackCNetworkList.kindLabel(for: summary))
                LabeledContent("Status", value: inspection.members.isEmpty ? "Unused" : "In use")
                LabeledContent(
                    "Containers",
                    value: "\(inspection.members.count) attached")
                LabeledContent("Network ID") {
                    Text(inspection.id)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            networkCapabilities(inspection)
            addressManagement(inspection)
            networkOptions(inspection)
            networkLabels(inspection)
            networkMembers(inspection)
            networkActions(inspection, summary: summary)
        }
        // Automatic system Form — see the clipping note on
        // `VolumesRootView.detailPane`: `.formStyle(.columns)` overflows and clips
        // a 340–460pt inspector when any value is wide.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func networkCapabilities(_ inspection: NetworkInspection) -> some View {
        if inspection.enableIPv6 != nil || inspection.isInternal != nil
            || inspection.isAttachable != nil || inspection.isIngress != nil
            || inspection.isConfigOnly != nil || inspection.configFrom != nil
        {
            Section("Capabilities") {
                if let enabled = inspection.enableIPv6 {
                    LabeledContent("IPv6", value: enabled ? "Enabled" : "Disabled")
                }
                if let internalNetwork = inspection.isInternal {
                    LabeledContent("Internal", value: internalNetwork ? "Yes" : "No")
                }
                if let attachable = inspection.isAttachable {
                    LabeledContent("Attachable", value: attachable ? "Yes" : "No")
                }
                if let ingress = inspection.isIngress {
                    LabeledContent("Ingress", value: ingress ? "Yes" : "No")
                }
                if let configOnly = inspection.isConfigOnly {
                    LabeledContent("Config Only", value: configOnly ? "Yes" : "No")
                }
                if let configFrom = inspection.configFrom {
                    LabeledContent("Configuration From") {
                        Text(configFrom)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func addressManagement(_ inspection: NetworkInspection) -> some View {
        Section("IP Address Management") {
            LabeledContent("Driver", value: inspection.ipamDriver ?? "Not reported")
            if inspection.ipamConfigurations.isEmpty {
                Text("Docker did not report an address pool for this network.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(inspection.ipamConfigurations.enumerated()), id: \.offset) { index, configuration in
                    DisclosureGroup("Address Pool \(index + 1)") {
                        if let subnet = configuration.subnet {
                            LabeledContent("Subnet") {
                                selectableNetworkValue(subnet)
                            }
                        }
                        if let gateway = configuration.gateway {
                            LabeledContent("Gateway") {
                                selectableNetworkValue(gateway)
                            }
                        }
                        if let range = configuration.ipRange {
                            LabeledContent("IP Range") {
                                selectableNetworkValue(range)
                            }
                        }
                        if !configuration.auxiliaryAddresses.isEmpty {
                            DisclosureGroup("Auxiliary Addresses (\(configuration.auxiliaryAddresses.count))") {
                                ForEach(configuration.auxiliaryAddresses) { item in
                                    LabeledContent(item.key) {
                                        selectableNetworkValue(item.value)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func networkOptions(_ inspection: NetworkInspection) -> some View {
        if !inspection.options.isEmpty {
            Section("Options") {
                DisclosureGroup("Network Options (\(inspection.options.count))") {
                    ForEach(inspection.options) { option in
                        LabeledContent(option.key) {
                            selectableNetworkValue(option.value)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func networkLabels(_ inspection: NetworkInspection) -> some View {
        if !inspection.labels.isEmpty {
            Section("Labels") {
                DisclosureGroup("Network Labels (\(inspection.labels.count))") {
                    ForEach(inspection.labels) { label in
                        LabeledContent(label.key) {
                            selectableNetworkValue(label.value)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func networkMembers(_ inspection: NetworkInspection) -> some View {
        Section("Attached Containers") {
            if inspection.members.isEmpty {
                Text("No containers are attached to this network.")
                    .foregroundStyle(.secondary)
            } else {
                DisclosureGroup("Members (\(inspection.members.count))") {
                    ForEach(inspection.members) { member in
                        DisclosureGroup(member.name) {
                            LabeledContent("Container ID") {
                                selectableNetworkValue(member.id)
                            }
                            if let ipv4 = member.ipv4Address {
                                LabeledContent("IPv4 Address") {
                                    selectableNetworkValue(ipv4)
                                }
                            }
                            if let ipv6 = member.ipv6Address {
                                LabeledContent("IPv6 Address") {
                                    selectableNetworkValue(ipv6)
                                }
                            }
                            if let macAddress = member.macAddress {
                                LabeledContent("MAC Address") {
                                    selectableNetworkValue(macAddress)
                                }
                            }
                            if let endpointID = member.endpointID {
                                LabeledContent("Endpoint ID") {
                                    selectableNetworkValue(endpointID)
                                }
                            }
                            if !member.aliases.isEmpty {
                                LabeledContent("Aliases") {
                                    Text(member.aliases.joined(separator: ", "))
                                        .textSelection(.enabled)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                    }
                }

                let knownMembers = inspection.members.filter { member in
                    model.containers.contains { $0.id == member.id }
                }
                if !knownMembers.isEmpty {
                    Menu("Show in Containers", systemImage: "shippingbox") {
                        ForEach(knownMembers) { member in
                            Button(member.name) {
                                model.selectedContainerID = member.id
                                model.selection = .containers
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func networkActions(_ inspection: NetworkInspection, summary: NetworkSummary) -> some View {
        Section("Actions") {
            let connectableContainers = NetworkMembershipCandidates.connectable(
                containers: model.containers,
                members: inspection.members)
            let disconnectableMembers = NetworkMembershipCandidates.disconnectable(
                members: inspection.members,
                containers: model.containers)
            let connectUnavailableReason = NetworkMembershipCandidates.connectAvailabilityReason(
                for: inspection,
                candidates: connectableContainers)
            let disconnectUnavailableReason = NetworkMembershipCandidates.disconnectUnavailableReason(
                for: inspection,
                members: inspection.members,
                containers: model.containers)

            Button("Connect Container…") {
                networkForConnection = inspection
            }
            .disabled(connectUnavailableReason != nil || isPerformingNetworkOperation)
            .accessibilityLabel("Connect a container to \(inspection.name)")
            .help(
                connectUnavailableReason
                    ?? "Connect a running container that is not already attached")

            if let connectUnavailableReason {
                Text(connectUnavailableReason)
                    .foregroundStyle(.secondary)
            }

            if disconnectUnavailableReason == nil, !disconnectableMembers.isEmpty {
                disconnectMenu(for: inspection, members: disconnectableMembers)
            } else if let disconnectUnavailableReason {
                Text(disconnectUnavailableReason)
                    .foregroundStyle(.secondary)
            }

            if summary.isBuiltIn {
                Text("Docker manages this built-in network and does not allow removal.")
                    .foregroundStyle(.secondary)
            } else if !inspection.members.isEmpty {
                Text("Disconnect every attached container before removing this network.")
                    .foregroundStyle(.secondary)
            } else {
                Button("Remove Network…", role: .destructive) {
                    removal = summary
                }
                .disabled(isPerformingNetworkOperation)
                .accessibilityLabel("Remove network \(summary.name)")
                .help("Review permanent removal of \(summary.name)")
            }
        }
    }

    @ViewBuilder
    private func disconnectMenu(
        for inspection: NetworkInspection,
        members: [NetworkInspection.Member]
    ) -> some View {
        Menu("Disconnect Container…", systemImage: "network.badge.minus") {
            ForEach(members) { member in
                Button(member.name, role: .destructive) {
                    disconnectTarget = NetworkDisconnectRequest(network: inspection, container: member)
                }
                .accessibilityLabel("Disconnect \(member.name) from \(inspection.name)")
                .help("Review detaching \(member.name) from \(inspection.name)")
            }
        }
        .disabled(isPerformingNetworkOperation)
        .accessibilityLabel("Disconnect a container from \(inspection.name)")
        .help("Choose a running container currently attached to \(inspection.name)")
    }

    private func selectableNetworkValue(_ value: String) -> some View {
        Text(value)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(2)
            .truncationMode(.middle)
    }

    // MARK: Operations

    /// A selected-record inspection is newer than the list's attachment count. The
    /// delete endpoint is still authoritative and will reject an in-use network, but
    /// this avoids making an already-empty inspected network silently unavailable
    /// because the inventory refresh was a moment behind.
    private func canOfferRemoval(of network: NetworkSummary) -> Bool {
        guard !network.isBuiltIn else { return false }
        if inspection?.id == network.id, let inspection {
            return inspection.members.isEmpty
        }
        return network.containers == 0
    }

    @MainActor
    private func loadSelectedNetworkInspection() async {
        guard let network = selectedNetwork else {
            inspection = nil
            inspectionError = nil
            isLoadingInspection = false
            return
        }

        let id = network.id
        inspection = nil
        inspectionError = nil
        isLoadingInspection = true
        do {
            let result = try await model.client.inspectNetwork(id: id)
            guard !Task.isCancelled, selection == id else { return }
            inspection = result
            isLoadingInspection = false
        } catch {
            guard !Task.isCancelled, selection == id else { return }
            inspectionError = MorbErrorMessage.text(for: error)
            isLoadingInspection = false
        }
    }

    private func reviewUnusedNetworks() {
        let plan = UnusedNetworkRemovalPlan(networks: model.networks)
        guard !plan.targets.isEmpty else { return }
        unusedRemovalPlan = plan
    }

    /// The membership POST is the mutation authority. An inspection immediately after
    /// it gives the selected-record pane Docker's new member map instead of guessing
    /// locally; a failed refresh is reported separately from the already-successful
    /// mutation.
    @MainActor
    private func refreshMembershipTruth(for networkID: String) async -> NetworkMembershipRefreshResult {
        do {
            let refreshed = try await model.client.inspectNetwork(id: networkID)
            if selection == networkID {
                inspection = refreshed
                inspectionError = nil
            }
            await model.refreshAll()
            return NetworkMembershipRefreshResult(inspectionWasRefreshed: true, warning: nil)
        } catch {
            await model.refreshAll()
            return NetworkMembershipRefreshResult(
                inspectionWasRefreshed: false,
                warning: "Docker completed the change, but Morbstack could not refresh this network's details: \(MorbErrorMessage.text(for: error))")
        }
    }

    @MainActor
    private func connect(_ request: NetworkConnectRequest) async throws -> NetworkMembershipRefreshResult {
        guard !isPerformingNetworkOperation else {
            throw DockerClientError.transport("another network operation is already in progress")
        }
        isChangingNetworkMembership = true
        defer { isChangingNetworkMembership = false }

        try await model.client.connectNetwork(request)
        return await refreshMembershipTruth(for: request.networkID)
    }

    @MainActor
    private func disconnect(_ request: NetworkDisconnectRequest) async {
        guard !isPerformingNetworkOperation else { return }
        isChangingNetworkMembership = true
        defer { isChangingNetworkMembership = false }

        do {
            try await model.client.disconnectNetwork(request)
            let refreshed = await refreshMembershipTruth(for: request.networkID)
            operationAlert = NetworkOperationAlert(
                title: "Disconnected \(request.containerName)",
                message: refreshed.warning
                    ?? "Docker disconnected \(request.containerName) from \(request.networkName), and Morbstack refreshed the network details.",
                focusID: request.networkID)
        } catch {
            operationAlert = NetworkOperationAlert(
                title: "Could not disconnect \(request.containerName)",
                message: MorbErrorMessage.text(for: error),
                focusID: request.networkID)
        }
    }

    @MainActor
    private func remove(_ network: NetworkSummary) async {
        guard !network.isBuiltIn, !isPerformingNetworkOperation else { return }
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
        guard !targets.isEmpty, !isPerformingNetworkOperation else { return }
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
                title: "Removed \(removed) of \(targets.count) network\(targets.count == 1 ? "" : "s")",
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

    @MainActor
    private func createNetwork(_ request: NetworkCreateRequest) async throws -> NetworkCreateResult {
        guard !isPerformingNetworkOperation else {
            throw DockerClientError.transport("another network operation is already in progress")
        }
        isCreatingNetwork = true
        defer { isCreatingNetwork = false }

        let result = try await model.client.createNetwork(request)
        // Docker's response ID is authoritative. Refresh the table to obtain its
        // current summary and attachment count, then select that exact returned ID.
        await model.refreshAll()
        selection = result.id
        showsInspector = true
        return result
    }
}
