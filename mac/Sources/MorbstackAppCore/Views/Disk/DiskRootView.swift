// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The Disk screen.
//
// This is an operational screen, not a storage dashboard. The native rows below answer
// the useful questions directly: how much is used, what is reclaimable, and which
// resources are worth investigating or pruning.

import MorbstackKit
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

private struct DiskGrowthNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// The read-only host facts used to render the VM disk section. This is intentionally
/// separate from Docker's `/system/df` storage attribution: Docker reports its own
/// objects, while these facts describe the VM's RAW capacity and recovery journal.
private struct DiskGrowthLocalFacts: Sendable {
    let capacity: MorbDiskCapacity.Status?
    let journal: MorbDiskGrowth.Journal?
    let errorMessage: String?
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
    @State private var diskCapacity: MorbDiskCapacity.Status?
    @State private var diskResizeDiagnostic: MorbDiskResize.Diagnostic?
    @State private var diskGrowthJournal: MorbDiskGrowth.Journal?
    @State private var diskCapacityError: String?
    @State private var isGrowingDisk = false
    @State private var diskGrowthError: String?
    @State private var showsDiskGrowthConfirmation = false
    @State private var diskGrowthNotice: DiskGrowthNotice?

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

    private var isPerformingDiskOperation: Bool { busy || isGrowingDisk }

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
        .alert(
            diskGrowthNotice?.title ?? "",
            isPresented: diskGrowthNoticeBinding,
            presenting: diskGrowthNotice
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
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
            if model.fixtureProvenance == nil {
                if !footprintIsInjected {
                    await loadFootprint()
                }
                await loadDiskGrowthFacts()
            }
            selectFirstRowIfNeeded()
        }
        .confirmationDialog(
            diskGrowthConfirmationTitle,
            isPresented: $showsDiskGrowthConfirmation,
            titleVisibility: .visible
        ) {
            Button(diskGrowthConfirmationActionTitle, role: .destructive) {
                beginDiskGrowth()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(diskGrowthConfirmationMessage)
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
                    diskGrowthActionControl
                })
        } else if model.disk == nil {
            ContentUnavailableView(
                label: {
                    Label("The Engine Is Not Running", systemImage: "internaldrive")
                },
                description: {
                    Text(engineStoppedDiskDescription)
                },
                actions: {
                    if busy {
                        ProgressView("Starting Engine")
                    } else {
                        Button("Start Engine", systemImage: "play.fill") {
                            Task { await startEngine() }
                        }
                    }
                    diskGrowthActionControl
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
            .disabled(isPerformingDiskOperation)
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
                .disabled(isPerformingDiskOperation || !canPrune(target))
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
                        .disabled(isPerformingDiskOperation || !canPrune(target))
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
                diskGrowthFacts
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

    /// VM disk capacity and Docker storage attribution answer different questions.
    /// This section keeps the RAW-image capacity, its durable recovery record, and the
    /// Engine's exact readiness diagnostic together in a normal inspector Form rather
    /// than presenting another dashboard gauge or a preference editor.
    @ViewBuilder
    private var diskGrowthFacts: some View {
        Section {
            if model.fixtureProvenance != nil {
                Text("VM disk capacity is unavailable in developer fixture data.")
                    .foregroundStyle(.secondary)
            } else if let diskCapacity {
                if let currentBytes = diskCapacity.currentBytes {
                    LabeledContent("Current Raw Capacity") {
                        Text(Formatters.bytesString(currentBytes))
                            .monospacedDigit()
                    }
                } else {
                    LabeledContent("Current Raw Capacity", value: "No disk image")
                }
                LabeledContent("Configured Capacity") {
                    Text(Formatters.bytesString(diskCapacity.configuredBytes))
                        .monospacedDigit()
                }
                LabeledContent("Capacity State", value: capacityStateTitle(diskCapacity.state))
                Text(diskCapacity.summary)
                    .foregroundStyle(.secondary)

                if let inspectionError = diskCapacity.inspectionError {
                    Text(inspectionError)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if let diskResizeDiagnostic {
                    LabeledContent(
                        "Transaction Readiness",
                        value: diskResizeStateTitle(diskResizeDiagnostic.state))
                    LabeledContent(
                        "Guest Resize",
                        value: diskResizeDiagnostic.guestCapability.rawValue.capitalized)
                    Text(diskResizeDiagnostic.summary)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The daemon has not reported disk-growth readiness. Morbstack checks the same preconditions again before any reviewed growth transaction.")
                        .foregroundStyle(.secondary)
                }

                if let diskGrowthJournal {
                    LabeledContent("Recovery Phase", value: diskGrowthJournal.phase.rawValue)
                    LabeledContent("Saved Target") {
                        Text(Formatters.bytesString(diskGrowthJournal.targetBytes))
                            .monospacedDigit()
                    }
                    Text(TrackCDiskGrowthPresentation.journalPhaseDescription(diskGrowthJournal.phase))
                        .foregroundStyle(.secondary)
                }
            } else if let diskCapacityError {
                Text(diskCapacityError)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                ProgressView("Checking VM disk capacity")
            }

            if isGrowingDisk {
                ProgressView("Growing VM disk and verifying the guest filesystem")
            }

            if let diskGrowthError {
                LabeledContent("Last Attempt") {
                    Text(diskGrowthError)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
            }

            diskGrowthActionControl
        } header: {
            Text("VM Disk Capacity")
        } footer: {
            Text("Current raw capacity is the VM block device size. Docker storage totals above are a separate daemon-reported attribution and do not describe all guest filesystem use.")
        }
    }

    @ViewBuilder
    private var diskGrowthActionControl: some View {
        switch diskGrowthAction {
        case .none:
            EmptyView()
        case .refreshReadiness:
            Button("Refresh VM Disk Readiness", systemImage: "arrow.clockwise") {
                Task { await loadDiskGrowthFacts() }
            }
            .disabled(isPerformingDiskOperation)
        case .stopEngine:
            Button("Stop Engine", systemImage: "stop.fill") {
                Task { await stopEngineForDiskGrowth() }
            }
            .disabled(model.isEngineBusy || isGrowingDisk)
            .help("The VM must stop completely before Morbstack can grow its data disk")
        case .reviewGrowth:
            Button("Review Disk Growth…", systemImage: "arrow.up.right") {
                diskGrowthError = nil
                showsDiskGrowthConfirmation = true
            }
            .disabled(isGrowingDisk || diskGrowthTargetGiB == nil)
            .help("Review the grow-only VM disk transaction")
        case .reviewRecovery:
            Button("Review Disk Recovery…", systemImage: "arrow.clockwise") {
                diskGrowthError = nil
                showsDiskGrowthConfirmation = true
            }
            .disabled(isGrowingDisk || diskGrowthTargetGiB == nil)
            .help("Retry the exact saved disk-growth target and verify the guest filesystem")
        }
    }

    private var diskGrowthAction: TrackCDiskGrowthAction {
        guard model.fixtureProvenance == nil else { return .none }
        // Implicit return only applies to single-expression getters; the guard above
        // makes this body multi-statement, so the return must be explicit.
        return TrackCDiskGrowthPresentation.action(
            capacity: diskCapacity,
            diagnostic: diskResizeDiagnostic,
            hasRecoveryJournal: diskGrowthJournal != nil,
            // Docker's ready state is narrower than the VM lifecycle state. A starting,
            // stopping, suspended, or otherwise reachable VM must not be offered a
            // grow transaction merely because dockerd is not ready to list containers.
            engineIsRunning: model.engine.reachable && model.engine.state != "stopped")
    }

    private var diskGrowthTargetGiB: Int? {
        if let diskGrowthJournal {
            let bytes = diskGrowthJournal.targetBytes
            guard bytes > 0, bytes % MorbDiskCapacity.bytesPerGiB == 0 else { return nil }
            return Int(bytes / MorbDiskCapacity.bytesPerGiB)
        }
        return diskCapacity?.configuredGiB
    }

    private var diskGrowthConfirmationTitle: String {
        diskGrowthAction == .reviewRecovery ? "Recover VM Disk Growth?" : "Grow VM Disk?"
    }

    private var diskGrowthConfirmationActionTitle: String {
        guard let targetGiB = diskGrowthTargetGiB else { return "Grow Disk" }
        return diskGrowthAction == .reviewRecovery
            ? "Retry \(targetGiB) GiB Target"
            : "Grow to \(targetGiB) GiB"
    }

    private var diskGrowthConfirmationMessage: String {
        guard let targetGiB = diskGrowthTargetGiB else {
            return "Morbstack could not determine a safe disk-growth target. Refresh VM disk readiness before trying again."
        }
        if diskGrowthAction == .reviewRecovery {
            return "Morbstack will retry the saved \(targetGiB) GiB target. It verifies the recorded disk identity and guest filesystem before completing recovery; it will not shrink the disk or accept a different target."
        }
        let current = diskCapacity?.currentBytes.map(Formatters.bytesString) ?? "the current capacity"
        return "Morbstack will extend the VM disk from \(current) to \(targetGiB) GiB, boot the VM only long enough to resize /var/lib/docker, and require a guest proof before committing the result. Docker is unavailable during the transaction. Disk growth cannot be undone; if verification fails, Morbstack stops the VM and retains recovery information for this exact target."
    }

    private var engineStoppedDiskDescription: String {
        guard let diskCapacity else {
            return "Start the engine to view Docker images, containers, volumes, and build cache on disk. VM disk capacity is checked separately."
        }
        return "Start the engine to view Docker images, containers, volumes, and build cache on disk. VM disk: \(capacityStateTitle(diskCapacity.state))."
    }

    private func capacityStateTitle(_ state: MorbDiskCapacity.State) -> String {
        switch state {
        case .willCreate: return "Created on first start"
        case .matchesConfiguration: return "Matches configuration"
        case .increaseRequiresGuestResize: return "Growth required"
        case .decreaseUnsupported: return "Shrink unsupported"
        case .unavailable: return "Unavailable"
        }
    }

    private func diskResizeStateTitle(_ state: MorbDiskResize.State) -> String {
        switch state {
        case .notNeeded: return "No transaction needed"
        case .decreaseUnsupported: return "Shrink unsupported"
        case .capacityUnavailable: return "Capacity unavailable"
        case .vmMustStop: return "Stop VM first"
        case .guestCapabilityUnknown: return "Guest check required"
        case .guestResizeUnavailable: return "Guest resize unavailable"
        case .recoveryRequired: return "Recovery required"
        case .readyForExplicitTransaction: return "Ready for review"
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

    private var diskGrowthNoticeBinding: Binding<Bool> {
        Binding(
            get: { diskGrowthNotice != nil },
            set: { if !$0 { diskGrowthNotice = nil } })
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
        await loadDiskGrowthFacts()
        selectFirstRowIfNeeded()
    }

    @MainActor
    private func refreshDiskUsage() async {
        busy = true
        defer { busy = false }
        await model.refreshDisk()
        await loadFootprint()
        await loadDiskGrowthFacts()
        selectFirstRowIfNeeded()
    }

    @MainActor
    private func startEngine() async {
        busy = true
        defer { busy = false }
        await model.engineAction(.start)
        await loadDiskGrowthFacts()
    }

    /// Stops the VM only from the explicit Disk action, then reloads the daemon's
    /// disk-growth diagnosis. The grow transaction itself still rechecks that the VM
    /// is completely stopped before it mutates the RAW image.
    @MainActor
    private func stopEngineForDiskGrowth() async {
        await model.engineAction(.stop)
        await loadDiskGrowthFacts()
        await loadFootprint()
    }

    /// Reads capacity/configuration and the durable journal without mutating either.
    /// Fixture mode intentionally supplies neither: presenting the developer machine's
    /// real Morbstack disk beside fixture Docker data would be a false live-data claim.
    private func loadDiskGrowthFacts() async {
        guard model.fixtureProvenance == nil else {
            await MainActor.run {
                diskCapacity = nil
                diskResizeDiagnostic = nil
                diskGrowthJournal = nil
                diskCapacityError = nil
            }
            return
        }

        let localFacts = await Task.detached(priority: .utility) { () -> DiskGrowthLocalFacts in
            do {
                let config = try MorbConfig.load()
                let capacity = MorbDiskCapacity.inspect(configuredGiB: config.diskSizeGiB)
                do {
                    return DiskGrowthLocalFacts(
                        capacity: capacity,
                        journal: try MorbDiskGrowth.loadJournal(),
                        errorMessage: nil)
                } catch {
                    return DiskGrowthLocalFacts(
                        capacity: capacity,
                        journal: nil,
                        errorMessage: MorbErrorMessage.text(for: error))
                }
            } catch {
                return DiskGrowthLocalFacts(
                    capacity: nil,
                    journal: nil,
                    errorMessage: MorbErrorMessage.text(for: error))
            }
        }.value
        let daemonDiagnostic = await model.daemon.diskResizeDiagnostic()

        await MainActor.run {
            diskCapacity = localFacts.capacity
            diskGrowthJournal = localFacts.journal
            diskCapacityError = localFacts.errorMessage
            diskResizeDiagnostic = daemonDiagnostic
        }
    }

    /// Begins only after the native confirmation dialog. The daemon owns all durable
    /// mutation and proof ordering: this view passes one reviewed target and reflects
    /// the final verified state or retained recovery record after it returns.
    private func beginDiskGrowth() {
        guard let targetGiB = diskGrowthTargetGiB, !isGrowingDisk else { return }
        Task { @MainActor in
            isGrowingDisk = true
            diskGrowthError = nil
            defer { isGrowingDisk = false }
            do {
                try await model.daemon.growDisk(targetGiB: targetGiB)
                await model.refreshEngine()
                await loadDiskGrowthFacts()
                await loadFootprint()
                diskGrowthNotice = DiskGrowthNotice(
                    title: "VM Disk Growth Verified",
                    message: "Morbstack completed the \(targetGiB) GiB disk-growth transaction and accepted the guest filesystem proof.")
            } catch {
                let message = MorbErrorMessage.text(for: error)
                diskGrowthError = message
                operationError = message
                await loadDiskGrowthFacts()
                await loadFootprint()
            }
        }
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
            await loadDiskGrowthFacts()
            selectFirstRowIfNeeded()
        } catch {
            operationError = MorbErrorMessage.text(for: error)
        }
    }
}
