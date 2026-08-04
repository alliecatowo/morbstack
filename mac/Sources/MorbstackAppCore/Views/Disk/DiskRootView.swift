// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The Disk screen.
//
// This is an operational screen, not a storage dashboard. The native rows below answer
// the useful questions directly: how much is used, what is reclaimable, and which
// resources are worth investigating or pruning.

import SwiftUI

// MARK: - Prune targets

extension TrackCDiskCategory {
    /// Docker exposes an exact enough preview for the first three resource families.
    /// Build cache is intentionally excluded: the only Docker operation would prune
    /// every unused cache record globally, which this screen cannot review by record.
    var pruneTarget: TrackCPruneTarget? {
        switch self {
        case .images: return .images
        case .containers: return .containers
        case .volumes: return .volumes
        case .buildCache: return nil
        }
    }
}

// MARK: - Disk table rows

/// An individually sized image or volume for the largest-resources section.
///
/// Docker's category values and individual resource sizes overlap: image categories
/// account for shared layers once, while each image can refer to those same layers. They
/// must therefore remain separate sections in the native table rather than an outline
/// whose parent/child affordance would imply that their values add up.
private struct TrackCDiskLargestItem: Identifiable {

    enum Kind: String {
        case image
        case volume

        var title: String { self == .image ? "Image" : "Volume" }
        var symbol: String { self == .image ? "square.on.square" : "externaldrive" }
    }

    let kind: Kind
    let item: TrackCNamedSize

    var id: String { "\(kind.rawValue):\(item.id)" }
}

private struct TrackCDiskRow: Identifiable {

    enum Content {
        case category(TrackCDiskSegment)
        case resource(TrackCDiskLargestItem)
    }

    let content: Content

    var id: String {
        switch content {
        case .category(let segment): return "category:\(segment.id)"
        case .resource(let resource): return resource.id
        }
    }

    var title: String {
        switch content {
        case .category(let segment): return segment.category.title
        case .resource(let resource): return resource.item.label
        }
    }

    var symbol: String {
        switch content {
        case .category(let segment): return segment.category.symbol
        case .resource(let resource): return resource.kind.symbol
        }
    }

    var type: String {
        switch content {
        case .category: return "Storage category"
        case .resource(let resource): return resource.kind.title
        }
    }

    var bytes: Int64 {
        switch content {
        case .category(let segment): return segment.bytes
        case .resource(let resource): return resource.item.bytes
        }
    }

    var reclaimable: (bytes: Int64, estimated: Bool)? {
        guard case .category(let segment) = content else { return nil }
        return (segment.reclaimableBytes, segment.isEstimate)
    }

    var category: TrackCDiskCategory? {
        guard case .category(let segment) = content else { return nil }
        return segment.category
    }

    var detail: String? {
        guard case .resource(let resource) = content else { return nil }
        return resource.item.detail
    }
}

/// The storage screen contains two deliberately separate accounting collections:
/// aggregate categories and individual resources. The table can still sort each
/// collection by the same native header without suggesting that the two totals add up.
private enum TrackCDiskSortKey: String {
    case name
    case type
    case size
    case reclaimable
}

private struct TrackCDiskComparator: SortComparator {
    var key: TrackCDiskSortKey
    var order: SortOrder = .forward

    func compare(_ lhs: TrackCDiskRow, _ rhs: TrackCDiskRow) -> ComparisonResult {
        let result: ComparisonResult
        switch key {
        case .name:
            result = MorbSort.string(lhs.title, rhs.title)
        case .type:
            result = lhs.type == rhs.type
                ? MorbSort.string(lhs.title, rhs.title)
                : MorbSort.string(lhs.type, rhs.type)
        case .size:
            result = lhs.bytes == rhs.bytes
                ? MorbSort.string(lhs.title, rhs.title)
                : (lhs.bytes < rhs.bytes ? .orderedAscending : .orderedDescending)
        case .reclaimable:
            // Individual images and volumes do not carry an independently reliable
            // reclaimable measurement. Keep that absence after categories with a
            // reported zero, rather than turning it into a false zero.
            let left = lhs.reclaimable?.bytes ?? -1
            let right = rhs.reclaimable?.bytes ?? -1
            result = left == right
                ? MorbSort.string(lhs.title, rhs.title)
                : (left < right ? .orderedAscending : .orderedDescending)
        }
        return order == .forward ? result : result.reversed
    }
}

private struct DiskPruneConfirmation: View {

    let target: TrackCPruneTarget
    let preview: TrackCPrunePreview
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var reclaimedSpaceLabel: String {
        if preview.knownBytes == 0, preview.hasUnknownSizes {
            return "The engine does not report reclaimable space in advance."
        }
        let amount = Formatters.bytesString(preview.knownBytes)
        return preview.hasUnknownSizes ? "Frees at least \(amount)." : "Frees \(amount)."
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(target.category.pruneSummary, systemImage: target.category.symbol)
                }

                if preview.items.isEmpty {
                    ContentUnavailableView(
                        "Nothing to Prune",
                        systemImage: "trash.slash",
                        description: Text("There are no eligible \(target.category.title.lowercased()) to remove."))
                } else {
                    Section("Will Be Removed") {
                        ForEach(preview.items) { item in
                            pruneItem(item)
                        }
                    }
                }

                if !preview.kept.isEmpty {
                    Section("Kept") {
                        ForEach(preview.kept) { item in
                            pruneItem(item)
                        }
                    }
                }

                Section {
                    Text(reclaimedSpaceLabel)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Prune \(target.category.title)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Prune \(preview.countLabel)", role: .destructive) {
                        dismiss()
                        onConfirm()
                    }
                    .disabled(preview.items.isEmpty)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 340)
    }

    private func pruneItem(_ item: TrackCPruneItem) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading) {
                Text(item.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(item.bytes.map(Formatters.bytesString) ?? "—")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Root

struct DiskRootView: View {

    let model: AppModel

    @State private var pruning: TrackCPruneTarget?
    @State private var footprint: TrackCDiskImageFootprint?
    @State private var busy = false
    @State private var selection: TrackCDiskRow.ID?
    @State private var sortOrder: [TrackCDiskComparator] = [
        TrackCDiskComparator(key: .size, order: .reverse)
    ]
    @State private var showsInspector = true
    @State private var operationError: String?

    /// Whether the footprint was handed in, in which case this view does not go and
    /// `stat` the real disk image over the top of it.
    private let footprintIsInjected: Bool

    /// - Parameter initialFootprint: the VM disk image's `stat` figures, when the caller
    ///   already has them. The app leaves this `nil` and reads them in `.task`; previews
    ///   and deterministic fixture runs inject a known value so they do not report the
    ///   host machine's `~/.morbstack/data/disk.img`.
    init(model: AppModel, initialFootprint: TrackCDiskImageFootprint? = nil) {
        self.model = model
        self.footprintIsInjected = initialFootprint != nil
        _footprint = State(initialValue: initialFootprint)
    }

    private var usage: DiskUsage { model.disk ?? .zero }

    private var segments: [TrackCDiskSegment] {
        TrackCDiskMath.segments(
            usage: usage,
            containers: model.containers,
            images: model.images,
            volumes: model.volumes)
    }

    private var subtitle: String {
        guard model.disk != nil else {
            if model.engine.isRunning {
                return busy ? "Calculating usage…" : "Usage unavailable"
            }
            return "Engine isn't running"
        }
        return "\(Formatters.bytesString(usage.total)) in use · \(Formatters.bytesString(usage.reclaimable)) reclaimable"
    }

    var body: some View {
        content
        .navigationTitle("Disk")
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .alert("Disk Operation Failed", isPresented: operationErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(operationError ?? "An unknown error occurred.")
        }
        .sheet(item: $pruning) { target in
            let preview = TrackCDiskMath.prunePreview(
                target: target,
                usage: model.disk,
                containers: model.containers,
                images: model.images,
                volumes: model.volumes)
            DiskPruneConfirmation(target: target, preview: preview) {
                Task { await prune(target) }
            }
        }
        .task {
            if !footprintIsInjected {
                await loadFootprint()
            }
            selectFirstRowIfNeeded()
        }
    }

    // MARK: Content

    /// The platform owns persistent content surfaces: one standard table for storage
    /// data and, when useful, a system inspector. Empty states use the platform's
    /// purpose-built view instead of leaving a homemade placeholder in the table area.
    @ViewBuilder
    private var content: some View {
        if model.disk == nil, model.engine.isRunning {
            ContentUnavailableView(
                label: {
                    Label("Disk Usage Is Unavailable", systemImage: "internaldrive")
                },
                description: {
                    Text("The engine is running, but has not reported its storage figures yet.")
                },
                actions: {
                    if busy {
                        ProgressView("Calculating Disk Usage")
                    } else {
                        Button("Calculate Disk Usage", systemImage: "arrow.triangle.2.circlepath") {
                            Task { await refreshDiskUsage() }
                        }
                    }
                })
        } else if model.disk == nil {
            ContentUnavailableView(
                label: {
                    Label("The Engine Is Not Running", systemImage: "internaldrive")
                },
                description: {
                    Text("Start the engine to view Docker images, containers, volumes, and build cache on disk.")
                },
                actions: {
                    if busy {
                        ProgressView("Starting Engine")
                    } else {
                        Button("Start Engine", systemImage: "play.fill") {
                            Task { await startEngine() }
                        }
                    }
                })
        } else {
            diskTable
                // The table's four semantic columns need a readable leading-content
                // width when the system presents its trailing inspector. Keeping that
                // constraint on the system Table lets the inspector collapse through
                // its own native adaptation instead of allowing either surface to
                // encroach on the other at narrow window widths.
                .frame(minWidth: 520)
                .inspector(isPresented: $showsInspector) {
                    inspector
                        .inspectorColumnWidth(min: 340, ideal: 400, max: 460)
                }
                .onChange(of: model.disk) { _, disk in
                    if disk != nil { selectFirstRowIfNeeded() }
                }
                .onChange(of: selection) { _, selectedID in
                    if selectedID != nil { showsInspector = true }
                }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(id: "disk.recalculate", placement: .primaryAction) {
            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .accessibilityLabel("Recalculate disk usage")
            .disabled(busy)
            .help("Recalculate disk usage — the engine walks every layer, so this is not instant")
        }
        if model.disk != nil {
            // Showing a trailing column changes the window's navigation layout; it is
            // not the primary task on a storage review screen. Let the system place
            // this view control alongside the standard toolbar affordances.
            ToolbarItem(id: "disk.inspector", placement: .automatic) {
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

    // MARK: Storage table

    /// These are distinct measurements, not a hierarchy. The table retains two sections
    /// so its native selection and columns do not imply that aggregate category totals
    /// can be added to individual image and volume sizes.
    private var categoryRows: [TrackCDiskRow] {
        segments
            .map { TrackCDiskRow(content: .category($0)) }
            .sorted(using: sortOrder)
    }

    private var resourceRows: [TrackCDiskRow] {
        largestItems
            .map { TrackCDiskRow(content: .resource($0)) }
            .sorted(using: sortOrder)
    }

    private var diskRows: [TrackCDiskRow] { categoryRows + resourceRows }

    private var selectedRow: TrackCDiskRow? {
        guard let selection else { return nil }
        return diskRows.first { $0.id == selection }
    }

    private var diskTable: some View {
        Table(of: TrackCDiskRow.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", sortUsing: TrackCDiskComparator(key: .name)) { row in
                Label(row.title, systemImage: row.symbol)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 150, ideal: 210)

            TableColumn("Type", sortUsing: TrackCDiskComparator(key: .type)) { row in
                Text(row.type)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 120, ideal: 148, max: 180)

            TableColumn("Size", sortUsing: TrackCDiskComparator(key: .size)) { row in
                Text(Formatters.bytesString(row.bytes))
                    .monospacedDigit()
            }
            .width(min: 78, ideal: 94, max: 128)

            TableColumn("Reclaimable", sortUsing: TrackCDiskComparator(key: .reclaimable)) { row in
                reclaimableCell(for: row)
            }
            .width(min: 112, ideal: 138, max: 180)
        } rows: {
            Section("Storage Categories") {
                ForEach(categoryRows) { TableRow($0) }
            }
            if !resourceRows.isEmpty {
                Section("Largest Individual Resources") {
                    ForEach(resourceRows) { TableRow($0) }
                }
            }
        }
        .tableStyle(.automatic)
        .contextMenu(forSelectionType: TrackCDiskRow.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            if let id = ids.first { selection = id }
        }
    }

    @ViewBuilder
    private func reclaimableCell(for row: TrackCDiskRow) -> some View {
        if let reclaimable = row.reclaimable {
            Text(reclaimableText(bytes: reclaimable.bytes, estimated: reclaimable.estimated))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } else {
            Text("—")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Reclaimable storage not reported for this individual resource")
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<TrackCDiskRow.ID>) -> some View {
        if let id = ids.first, let row = diskRows.first(where: { $0.id == id }) {
            if let category = row.category, let target = category.pruneTarget {
                Button("Prune \(category.title)…", role: .destructive) {
                    pruning = target
                }
                .disabled(busy || !canPrune(target))
                .help(category.pruneSummary)
            } else if case .some(.buildCache) = row.category {
                Button("Show Build Cache") {
                    model.selection = .builds
                }
            }
        }
    }

    private func reclaimableText(bytes: Int64, estimated: Bool) -> String {
        guard bytes > 0 else { return "None" }
        let text = Formatters.bytesString(bytes)
        return estimated ? "\(text) (estimated)" : text
    }

    private func canPrune(_ target: TrackCPruneTarget) -> Bool {
        !TrackCDiskMath.prunePreview(
            target: target,
            usage: model.disk,
            containers: model.containers,
            images: model.images,
            volumes: model.volumes).items.isEmpty
    }

    // MARK: Largest resources

    /// How many image and volume candidates to consider for the combined table.
    private static let biggestRows = 5

    private var largestItems: [TrackCDiskLargestItem] {
        let images = TrackCDiskMath.largestImages(model.images, limit: Self.biggestRows)
            .map { TrackCDiskLargestItem(kind: .image, item: $0) }
        let volumes = TrackCDiskMath.largestVolumes(model.volumes, limit: Self.biggestRows)
            .map { TrackCDiskLargestItem(kind: .volume, item: $0) }
        return (images + volumes).sorted {
            ($0.item.bytes, $0.item.id) > ($1.item.bytes, $1.item.id)
        }
    }

    // MARK: Inspector

    @ViewBuilder
    private var inspector: some View {
        if let selectedRow {
            Form {
                Section {
                    LabeledContent("Type", value: selectedRow.type)
                    LabeledContent("Size", value: Formatters.bytesString(selectedRow.bytes))
                    if let reclaimable = selectedRow.reclaimable {
                        LabeledContent(
                            "Reclaimable",
                            value: reclaimableText(bytes: reclaimable.bytes, estimated: reclaimable.estimated))
                    }
                    if let detail = selectedRow.detail {
                        LabeledContent("Details") {
                            Text(detail)
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                } header: {
                    Label(selectedRow.title, systemImage: selectedRow.symbol)
                } footer: {
                    if selectedRow.category != nil {
                        Text("Shared image layers are counted once, so category totals can differ from the sum of individual image sizes.")
                    }
                }

                if let category = selectedRow.category, let target = category.pruneTarget {
                    Section {
                        Button("Prune \(category.title)…", role: .destructive) {
                            pruning = target
                        }
                        .disabled(busy || !canPrune(target))
                        .help(category.pruneSummary)
                    } footer: {
                        Text(category.pruneSummary)
                    }
                } else if case .some(.buildCache) = selectedRow.category {
                    Section {
                        Button("Show Build Cache") {
                            model.selection = .builds
                        }
                    } footer: {
                        Text(
                            "Docker can only remove every unused cache record at once. "
                                + "Review individual records in Builds; Morbstack does not run that broader cleanup here.")
                    }
                }

                diskImageFacts
            }
            // Keep selected storage facts in the system inspector's aligned form
            // columns. The Form remains responsible for all spacing and appearance.
            .formStyle(.columns)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView(
                label: {
                    Label("Select a Storage Item", systemImage: "internaldrive")
                },
                description: {
                    Text("Choose a category or resource to inspect its details.")
                })
        }
    }

    @ViewBuilder
    private var diskImageFacts: some View {
        if let footprint {
            Section {
                LabeledContent("Apparent", value: Formatters.bytesString(footprint.apparentBytes))
                LabeledContent("Actual on APFS", value: Formatters.bytesString(footprint.actualBytes))
                ProgressView(value: footprint.occupancy) {
                    Text("Allocated")
                } currentValueLabel: {
                    Text(Formatters.percent(footprint.occupancy * 100))
                        .monospacedDigit()
                }
                LabeledContent("Path") {
                    Text(footprint.path)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            } header: {
                Text("Virtual Machine Disk")
            } footer: {
                Text(footprintExplanation(footprint))
            }
        } else {
            Section {
                Text("No disk image yet.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Virtual Machine Disk")
            } footer: {
                Text("Morbstack creates the VM disk image when the engine starts.")
            }
        }
    }

    private func footprintExplanation(_ footprint: TrackCDiskImageFootprint) -> String {
        if footprint.isSparse {
            return "This sparse file reserves \(Formatters.bytesString(footprint.apparentBytes)) but currently uses \(Formatters.bytesString(footprint.actualBytes)) on APFS."
        }
        return "This image is close to fully allocated. Space freed inside the guest remains allocated on APFS until the file is trimmed or recreated."
    }

    // MARK: Operations

    private var operationErrorBinding: Binding<Bool> {
        Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } })
    }

    private func selectFirstRowIfNeeded() {
        guard selection == nil else { return }
        selection = diskRows.first?.id
    }

    @MainActor
    private func refresh() async {
        busy = true
        defer { busy = false }
        await model.refreshAll()
        await loadFootprint()
        selectFirstRowIfNeeded()
    }

    @MainActor
    private func refreshDiskUsage() async {
        busy = true
        defer { busy = false }
        await model.refreshDisk()
        await loadFootprint()
        selectFirstRowIfNeeded()
    }

    @MainActor
    private func startEngine() async {
        busy = true
        defer { busy = false }
        await model.engineAction(.start)
    }

    /// Reads `disk.img`'s real footprint off the main actor.
    ///
    /// `stat(2)` on a local file is fast, but it is still a synchronous filesystem call
    /// and the disk it lives on may be spun down or busy; nothing here is worth a frame
    /// hitch on the main thread.
    private func loadFootprint() async {
        let read = await Task.detached(priority: .utility) {
            TrackCDiskMath.readFootprint()
        }.value
        await MainActor.run { footprint = read }
    }

    @MainActor
    private func prune(_ target: TrackCPruneTarget) async {
        busy = true
        defer { busy = false }
        do {
            switch target {
            case .containers: _ = try await model.client.pruneContainers()
            case .images: _ = try await model.client.pruneImages()
            case .volumes: _ = try await model.client.pruneVolumes()
            }
            await model.refreshAll()
            await loadFootprint()
            selectFirstRowIfNeeded()
        } catch {
            operationError = MorbErrorMessage.text(for: error)
        }
    }
}
