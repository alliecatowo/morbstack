// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The Volumes screen.
//
// Volumes are the one resource in this app where a wrong click loses data that cannot be
// pulled again, so the screen is deliberately more cautious than the others: no prune
// button in the header without a preview, no size shown as `0 B` when the truth is "not
// reported", and the Docker-reported guest mount point available for inspection or copying
// without pretending it is a Finder-accessible location on this Mac.
//
// A real `Table` replaces the hand-rolled column grid, and a detail pane replaces the
// popover: selecting a volume opens its driver, guest mount point and reference count beside the
// list rather than in a transient bubble, which is also what gives this screen something
// to show besides a thin thirty-two-point row — the emptiness `CRITIQUE.md` calls out by
// name. The pane is a real `.inspector(isPresented:)` trailing column (see the note on
// `content` below for why it used not to be).

import AppKit
import Foundation
import MorbFeatures
import MorbstackKit
import SwiftUI

// MARK: - Sorting and filtering

enum TrackCVolumeSortKey: String, Hashable, CaseIterable {
    case name
    case driver
    case size
    case refCount
}

enum TrackCVolumeList {

    static func matches(_ volume: VolumeSummary, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return volume.name.localizedCaseInsensitiveContains(needle)
            || volume.driver.localizedCaseInsensitiveContains(needle)
            || volume.mountpoint.localizedCaseInsensitiveContains(needle)
            || volume.labels.contains { key, value in
                key.localizedCaseInsensitiveContains(needle)
                    || value.localizedCaseInsensitiveContains(needle)
            }
    }

    /// Orders volumes by one column.
    ///
    /// Unknown sizes and unknown reference counts sort as if they were zero but keep
    /// their tie broken by name, so the "we do not know" rows cluster together at one end
    /// instead of scattering through the table.
    static func sorted(
        _ volumes: [VolumeSummary],
        by key: TrackCVolumeSortKey,
        ascending: Bool
    ) -> [VolumeSummary] {
        let ordered = volumes.sorted { lhs, rhs in
            switch key {
            case .name:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .driver:
                if lhs.driver != rhs.driver {
                    return lhs.driver.localizedStandardCompare(rhs.driver) == .orderedAscending
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .size:
                let left = lhs.size ?? 0, right = rhs.size ?? 0
                if left != right { return left < right }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .refCount:
                let left = lhs.refCount ?? 0, right = rhs.refCount ?? 0
                if left != right { return left < right }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
        return ascending ? ordered : ordered.reversed()
    }

    /// The volumes a "Remove Unused" would delete, and what that frees.
    ///
    /// Deliberately *not* `POST /volumes/prune`: that endpoint skips named volumes, so a
    /// button labelled "Remove Unused" backed by it would leave rows on screen that the
    /// user just asked to be rid of. Removing each one by name does what the label says,
    /// and the preview sheet lists every name before anything happens.
    static func unusedPlan(_ volumes: [VolumeSummary]) -> (items: [TrackCPruneItem], knownBytes: Int64, hasUnknownSizes: Bool) {
        // Biggest first: the whole reason to open this sheet is to find out what is
        // actually costing disk, and an alphabetical list buries that.
        let unused = volumes.filter(\.isUnused).sorted { lhs, rhs in
            let left = lhs.size ?? 0, right = rhs.size ?? 0
            if left != right { return left > right }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        let items = unused.map { volume in
            TrackCPruneItem(
                id: volume.name,
                title: volume.name,
                detail: TrackCDiskMath.isAnonymousVolumeName(volume.name)
                    ? "anonymous · \(volume.driver)"
                    : "named · \(volume.driver)",
                bytes: volume.size)
        }
        return (
            items,
            unused.reduce(Int64(0)) { $0 + max(0, $1.size ?? 0) },
            unused.contains { $0.size == nil }
        )
    }

    /// Total bytes across volumes whose size the engine reported.
    static func totalSize(_ volumes: [VolumeSummary]) -> Int64 {
        volumes.reduce(Int64(0)) { $0 + max(0, $1.size ?? 0) }
    }
}

/// Table sort, keyed by ``TrackCVolumeSortKey``.
struct TrackCVolumeComparator: SortComparator {
    var key: TrackCVolumeSortKey
    var order: SortOrder = .forward

    func compare(_ lhs: VolumeSummary, _ rhs: VolumeSummary) -> ComparisonResult {
        let result: ComparisonResult
        switch key {
        case .name: result = MorbSort.string(lhs.name, rhs.name)
        case .driver:
            result = lhs.driver == rhs.driver
                ? MorbSort.string(lhs.name, rhs.name)
                : MorbSort.string(lhs.driver, rhs.driver)
        case .size: result = MorbSort.optionalInt64(lhs.size, rhs.size)
        case .refCount:
            result = MorbSort.optionalInt64(
                lhs.refCount.map(Int64.init), rhs.refCount.map(Int64.init))
        }
        return order == .forward ? result : result.reversed
    }
}

/// One volume label, sorted once for the selected-record inspector rather than relying
/// on the dictionary's intentionally unspecified iteration order.
struct TrackCVolumeLabel: Identifiable, Equatable, Sendable {
    let key: String
    let value: String

    var id: String { key }
}

/// A container currently listed by Docker as mounting a selected named volume.
/// `VolumeSummary.refCount` remains the Engine's authoritative count; this is the
/// human-readable relationship projection that the current container inventory can
/// support without an inspect request per row.
struct TrackCVolumeContainerReference: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let state: String
    let image: String
}

/// Whether the names in the current container inventory agree with Docker's volume
/// usage count. Neither an absent count nor a missing name is turned into a confident
/// "unused" result.
enum TrackCVolumeUsageEvidence: Equatable {
    case unreported
    case unused
    case matches
    case incomplete(reported: Int, listed: Int)
    case inconsistent(reported: Int, listed: Int)
}

/// Pure selected-volume presentation decisions. Keeping this small makes the route's
/// truthfulness rules testable without a Docker daemon or a hosted SwiftUI view.
enum TrackCVolumeInspector {

    static func labels(for volume: VolumeSummary) -> [TrackCVolumeLabel] {
        volume.labels
            .map { TrackCVolumeLabel(key: $0.key, value: $0.value) }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }

    static func referencedContainers(
        for volume: VolumeSummary,
        in containers: [ContainerSummary]
    ) -> [TrackCVolumeContainerReference] {
        containers
            .filter { $0.volumeNames.contains(volume.name) }
            .map {
                TrackCVolumeContainerReference(
                    id: $0.id,
                    name: $0.displayName,
                    state: $0.state,
                    image: $0.image)
            }
            .sorted { lhs, rhs in
                let comparison = lhs.name.localizedStandardCompare(rhs.name)
                return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
            }
    }

    static func usageEvidence(
        reportedReferenceCount: Int?,
        listedReferences: Int
    ) -> TrackCVolumeUsageEvidence {
        guard let reportedReferenceCount else { return .unreported }
        if reportedReferenceCount == 0 {
            return listedReferences == 0 ? .unused : .inconsistent(
                reported: reportedReferenceCount, listed: listedReferences)
        }
        if listedReferences == reportedReferenceCount { return .matches }
        if listedReferences < reportedReferenceCount {
            return .incomplete(reported: reportedReferenceCount, listed: listedReferences)
        }
        return .inconsistent(reported: reportedReferenceCount, listed: listedReferences)
    }

    /// The single row that answers "what is using this volume". Docker's own
    /// `In use` / `Unused` wording is derived from this same count, so printing both
    /// states one fact twice; the count is the one that also carries how many.
    static func referenceRowValue(for reportedReferenceCount: Int?) -> String {
        guard let reportedReferenceCount else { return unscannedValue }
        return reportedReferenceCount == 1 ? "1 container" : "\(reportedReferenceCount) containers"
    }

    /// True when Docker reported neither number. Both rows would then carry the same
    /// non-value, so the section collapses them into one and the footnote names what a
    /// scan would fill in — the absence is stated once instead of twice.
    static func usageIsUnscanned(size: Int64?, reportedReferenceCount: Int?) -> Bool {
        size == nil && reportedReferenceCount == nil
    }

    /// Shown wherever a number would be if the Disk scan had run. Deliberately not
    /// "Not reported", "Unknown" or an em dash: those read as "Docker has no answer",
    /// when the truth is that nobody has asked it yet and the reader can.
    static let unscannedValue = "Not scanned yet"

    /// At most one footnote for the Storage and Use section, or none.
    ///
    /// Docker fills a volume's `UsageData` only when something asks it to — the Disk
    /// route's scan — so a missing size and a missing reference count are the same
    /// fact, and the section says it once and names what changes it. When both numbers
    /// are real, the rows already state agreement; a footnote earns its space only by
    /// reporting a disagreement the rows cannot show.
    static func usageFootnote(
        size: Int64?,
        reportedReferenceCount: Int?,
        evidence: TrackCVolumeUsageEvidence
    ) -> String? {
        switch (size, reportedReferenceCount) {
        case (nil, nil):
            return "Size and container references come from the Disk scan. Open Disk to compute them."
        case (nil, _):
            return "Sizes come from the Disk scan. Open Disk to compute them."
        case (_, nil):
            return "Container references come from the Disk scan. Open Disk to compute them."
        default:
            break
        }
        switch evidence {
        case .unreported, .unused, .matches:
            return nil
        case .incomplete(let reported, let listed):
            return
                "Docker reports \(reported) container \(reported == 1 ? "reference" : "references"), but \(listed) name\(listed == 1 ? " is" : "s are") in the current inventory."
        case .inconsistent(let reported, let listed):
            return
                "The current container inventory lists \(listed) mounts, while Docker reports \(reported) references. Refresh before removing this volume."
        }
    }

    static func removalConsequence(for volume: VolumeSummary) -> String {
        switch volume.refCount {
        case 0:
            return "Removing permanently deletes this volume’s contents. Docker reports no container references."
        case let count?:
            let referenceDescription = count == 1
                ? "1 container references"
                : "\(count) containers reference"
            return "Removing permanently deletes this volume’s contents. Docker will refuse while \(referenceDescription) it."
        case nil:
            return "Removing permanently deletes this volume’s contents. Docker did not report current usage and will refuse if the volume is attached."
        }
    }
}

private struct VolumeOperationAlert {
    var title: String
    var message: String
    var focusID: VolumeSummary.ID?
}

/// The reviewed, exact set for the multi-volume destructive operation.
///
/// A captured plan matters here: the sheet tells the person which names will be passed to
/// Docker, instead of recalculating an opaque count when they confirm. If Docker's state
/// changes while the sheet is open, removal still uses its normal non-forcing API and a
/// newly attached volume is kept.
private struct VolumeUnusedRemovalPlan: Identifiable {
    let id = UUID()
    let items: [TrackCPruneItem]
    let knownBytes: Int64
    let hasUnknownSizes: Bool

    init(volumes: [VolumeSummary]) {
        let plan = TrackCVolumeList.unusedPlan(volumes)
        items = plan.items
        knownBytes = plan.knownBytes
        hasUnknownSizes = plan.hasUnknownSizes
    }

    var countLabel: String {
        "\(items.count) unused volume\(items.count == 1 ? "" : "s")"
    }

    var reclaimedSpaceLabel: String {
        guard knownBytes > 0 else {
            return hasUnknownSizes
                ? "The engine does not report every volume size in advance."
                : "The engine did not report reclaimable space in advance."
        }
        let amount = Formatters.bytesString(knownBytes)
        return hasUnknownSizes ? "Frees at least \(amount)." : "Frees \(amount)."
    }
}

/// A standard document-modal review for the exact set of volumes that will be removed.
private struct VolumeUnusedRemovalReview: View {
    let plan: VolumeUnusedRemovalPlan
    let onConfirm: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Review the volumes before removing them. Their contents are deleted permanently.")
                }

                Section("Will Be Removed") {
                    ForEach(plan.items) { item in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading) {
                                Text(item.title)
                                    .font(.body.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(item.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(item.bytes.map(Formatters.bytesString) ?? "—")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Text(plan.reclaimedSpaceLabel)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Remove Unused Volumes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("volumes.removeUnusedSheet.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Remove \(plan.countLabel)", role: .destructive) {
                        dismiss()
                        onConfirm(plan.items.map(\.id))
                    }
                    .disabled(plan.items.isEmpty)
                    .accessibilityIdentifier("volumes.removeUnusedSheet.remove")
                }
            }
        }
        .frame(minWidth: 460, minHeight: 340)
    }
}

// MARK: - Root

struct VolumesRootView: View {

    let model: AppModel

    @State private var query = ""
    @State private var sortOrder: [TrackCVolumeComparator] = [TrackCVolumeComparator(key: .name)]
    @State private var selection: VolumeSummary.ID?

    @State private var unusedRemovalPlan: VolumeUnusedRemovalPlan?
    @State private var removal: VolumeSummary?
    @State private var removalProgress: String?
    @State private var operationAlert: VolumeOperationAlert?
    @State private var isVolumeCreatePresented = false
    @State private var newVolumeName = ""
    @State private var volumeCreateProgress: String?
    @State private var volumeCreateFailure: String?
    @State private var volumeArchiveExportReview: VolumeArchiveExportReview?
    @State private var volumeArchiveExport: VolumeArchiveExportOperation?
    @State private var volumeArchiveExportCancellation: VolumeArchiveExportCancellation?
    @State private var volumeArchiveExportNotice: VolumeArchiveExportNotice?
    @State private var areLabelsExpanded = false
    @State private var areContainerReferencesExpanded = false
    /// Whether the trailing inspector column is open. SwiftUI restores this across
    /// launches for a trailing-column inspector, so it is not persisted here.
    @State private var showsInspector = true

    private var visible: [VolumeSummary] {
        model.volumes
            .filter { TrackCVolumeList.matches($0, query: query) }
            .sorted(using: sortOrder)
    }

    private var unusedCount: Int { model.volumes.filter(\.isUnused).count }

    private var subtitle: String {
        var parts = ["\(model.volumes.count) volume\(model.volumes.count == 1 ? "" : "s")"]
        let total = TrackCVolumeList.totalSize(model.volumes)
        if total > 0 { parts.append(Formatters.bytesString(total)) }
        if unusedCount > 0 { parts.append("\(unusedCount) unused") }
        return parts.joined(separator: " · ")
    }

    private var selectedVolume: VolumeSummary? {
        guard let selection else { return nil }
        return model.volumes.first { $0.id == selection }
    }

    private var isPerformingVolumeOperation: Bool {
        removalProgress != nil || volumeCreateProgress != nil || volumeArchiveExport != nil
    }

    private var canExportSelectedVolume: Bool {
        selectedVolume.map { canExport($0) } ?? false
    }

    private func canExport(_ volume: VolumeSummary) -> Bool {
        volume.driver == "local" && !isPerformingVolumeOperation
    }

    private var volumeArchiveExportHelp: String {
        guard let selectedVolume else { return "Select a local volume to export" }
        return volumeArchiveExportHelp(for: selectedVolume)
    }

    private func volumeArchiveExportHelp(for volume: VolumeSummary) -> String {
        guard volume.driver == "local" else {
            return "Only Docker local-driver volumes can be exported"
        }
        if volumeArchiveExport != nil { return "A volume archive export is already in progress" }
        if removalProgress != nil { return "Wait for the current volume removal to finish" }
        return "Export the selected volume as a tar archive"
    }

    var body: some View {
        lifecycleContent
    }

    private var routeContent: some View {
        content
            .navigationTitle("Volumes")
            .navigationSubtitle(subtitle)
            // The menu-bar mirror of the toolbar's remove-unused command, so it stays
            // reachable when the toolbar overflows at narrow widths.
            .focusedSceneValue(
                \.routeMaintenanceCommand,
                RouteMaintenanceCommand(
                    title: "Remove Unused Volumes…",
                    isEnabled: unusedCount > 0 && !isPerformingVolumeOperation && removalProgress == nil,
                    perform: { reviewUnusedVolumes() }))
            .toolbar { toolbarContent }
            .sheet(item: $unusedRemovalPlan) { plan in
                VolumeUnusedRemovalReview(plan: plan) { names in
                    Task { await removeUnused(names) }
                }
            }
    }

    private var volumeArchiveExportSheetContent: some View {
        volumeArchiveExportReviewContent
            .sheet(item: $volumeArchiveExport) { operation in
                VolumeArchiveExportSheet(operation: operation, cancel: cancelVolumeArchiveExport)
                    .interactiveDismissDisabled()
            }
    }

    private var volumeArchiveExportReviewContent: some View {
        routeContent
            .sheet(isPresented: $isVolumeCreatePresented) {
                VolumeCreateSheet(
                    name: $newVolumeName,
                    progressLabel: volumeCreateProgress,
                    failureMessage: volumeCreateFailure
                ) { request in
                    Task { await createVolume(request) }
                }
            }
            .sheet(item: $volumeArchiveExportReview) { review in
                VolumeArchiveExportReviewSheet(review: review) {
                    volumeArchiveExportReview = nil
                    beginVolumeArchiveExport(review)
                }
            }
    }

    private var volumeArchiveExportNoticeContent: some View {
        volumeArchiveExportSheetContent
            .alert(
                volumeArchiveExportNotice?.title ?? "",
                isPresented: volumeArchiveExportNoticePresented,
                presenting: volumeArchiveExportNotice
            ) { notice in
                if let destination = notice.destination {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([destination])
                    }
                }
                Button("OK", role: .cancel) {}
            } message: { notice in
                Text(notice.message)
            }
    }

    private var removalConfirmationContent: some View {
        volumeArchiveExportNoticeContent
            .alert(
                removal.map { "Remove \($0.name)?" } ?? "",
                isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
                presenting: removal
            ) { volume in
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) { Task { await remove(volume) } }
            } message: { volume in
                Text(TrackCVolumeInspector.removalConsequence(for: volume))
            }
    }

    private var operationAlertContent: some View {
        removalConfirmationContent
            .alert(
                operationAlert?.title ?? "",
                isPresented: Binding(
                    get: { operationAlert != nil },
                    set: { if !$0 { operationAlert = nil } }
                ),
                presenting: operationAlert
            ) { alert in
                if let id = alert.focusID {
                    Button("Show Volume") {
                        selection = id
                        showsInspector = true
                    }
                }
                Button("OK", role: .cancel) {}
            } message: { alert in
                Text(alert.message)
            }
    }

    private var volumeArchiveExportNoticePresented: Binding<Bool> {
        Binding(
            get: { volumeArchiveExportNotice != nil },
            set: { if !$0 { volumeArchiveExportNotice = nil } })
    }

    private var lifecycleContent: some View {
        operationAlertContent
            .onDeleteCommand {
                guard !isPerformingVolumeOperation,
                      let selection,
                      let volume = model.volumes.first(where: { $0.id == selection })
                else { return }
                removal = volume
            }
            .onChange(of: query) { _, _ in
                if let selection,
                   !visible.contains(where: { $0.id == selection }) {
                    self.selection = visible.first?.id
                }
            }
            .onChange(of: selection) { _, _ in
                areLabelsExpanded = false
                areContainerReferencesExpanded = false
            }
            // Selects the first row so the inspector opens with something to show —
            // the same "select the first item" convention Mail and Finder use, and the
            // fix for a resource screen that otherwise reads as half its window empty.
            .task {
                if selection == nil { selection = visible.first?.id }
            }
    }

    // MARK: Toolbar

    /// The trailing commands — create, and the inspector toggle — declared once and
    /// mounted in one of two places. While the inspector is open they are declared on
    /// its content, which puts them in the inspector's own toolbar section so the
    /// system slides them in and out *with* the inspector — the same absorb behavior
    /// the sidebar toggle gets on the leading edge. When the inspector is closed they
    /// return to the window toolbar's trailing region so both commands stay reachable.
    /// Identifiers are identical in both mounts.
    @ToolbarContentBuilder
    private var trailingCommandItems: some ToolbarContent {
        ToolbarItem(id: "volumes.create", placement: .primaryAction) {
            Button {
                presentVolumeCreateSheet()
            } label: {
                Image(systemName: "plus")
            }
            .disabled(isPerformingVolumeOperation)
            .accessibilityIdentifier("volumes.create")
            .accessibilityLabel("Create volume")
            .help(
                isPerformingVolumeOperation
                    ? "Wait for the current volume operation to finish"
                    : "Create a named local Docker volume")
        }
        if !model.volumes.isEmpty {
            // The inspector changes the window's navigation layout; it is not the
            // primary task on a volume inventory screen.  Let the system place it
            // with other view controls instead of promoting it above record actions.
            ToolbarItem(id: "volumes.inspector", placement: .automatic) {
                Button {
                    showsInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .accessibilityIdentifier("volumes.inspector")
                .accessibilityLabel(showsInspector ? "Hide inspector" : "Show inspector")
                .help(showsInspector ? "Hide the inspector" : "Show the inspector")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if model.volumes.isEmpty {
            // The inspector is not mounted on the no-volumes screen, so the trailing
            // commands need their ordinary window-toolbar home here.
            trailingCommandItems
        }
        ToolbarItem(id: "volumes.removeUnused", placement: .secondaryAction) {
            if let removalProgress {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityIdentifier("volumes.removeUnused")
                    .accessibilityLabel(removalProgress)
            } else {
                Button(role: .destructive) {
                    reviewUnusedVolumes()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(unusedCount == 0 || isPerformingVolumeOperation)
                .accessibilityIdentifier("volumes.removeUnused")
                .accessibilityLabel("Remove unused volumes")
                .help(
                    unusedCount == 0
                        ? "Every volume is attached to a container"
                        : "Review and remove \(unusedCount) unused volume\(unusedCount == 1 ? "" : "s")")
            }
        }
        ToolbarItem(id: "volumes.export", placement: .secondaryAction) {
            Button {
                chooseVolumeArchiveDestination()
            } label: {
                // SF Symbol convention: up = export/share, down = import/save.
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityIdentifier("volumes.export")
            .accessibilityLabel("Export selected volume")
            .help(volumeArchiveExportHelp)
            .disabled(!canExportSelectedVolume)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.volumes.isEmpty {
            ContentUnavailableView {
                Label("No Volumes", systemImage: "externaldrive")
            } description: {
                Text("No Docker volumes are reported by the engine.")
            } actions: {
                Button {
                    presentVolumeCreateSheet()
                } label: {
                    Label("Create Volume", systemImage: "plus")
                }
                .disabled(isPerformingVolumeOperation)
                .accessibilityIdentifier("volumes.empty.noVolumes.create")
                Button {
                    Task { await model.refreshAll() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("volumes.empty.noVolumes.refresh")
            }
            .accessibilityIdentifier("volumes.empty.noVolumes")
        } else {
            Group {
                if visible.isEmpty {
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
                    // Mounting the trailing commands and search on the inspector
                    // content hands them to the inspector's region of the unified
                    // toolbar: at rest they sit against the inspector's edge instead
                    // of hovering detached above it, and while the inspector slides
                    // they travel with its divider — the trailing mirror of the
                    // sidebar absorbing its own toggle. Verified against the real
                    // window: they remain present and clickable while the inspector
                    // is closed.
                    .toolbar { trailingCommandItems }
                    .searchable(
                        text: $query,
                        placement: .toolbar,
                        prompt: "Name, driver, label, or mount point")
            }
        }
    }

    private var table: some View {
        Table(visible, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", sortUsing: TrackCVolumeComparator(key: .name)) { volume in
                nameCell(volume)
            }
            TableColumn("Driver", sortUsing: TrackCVolumeComparator(key: .driver)) { volume in
                Text(volume.driver)
                    .foregroundStyle(.secondary)
            }
            .width(min: 88, ideal: 108, max: 160)
            TableColumn("Size", sortUsing: TrackCVolumeComparator(key: .size)) { volume in
                Text(volume.size.map(Formatters.bytesString) ?? "—")
                    .monospacedDigit()
                    .help(volume.size == nil
                        ? "Sizes come from the Disk scan. Open Disk to compute them."
                        : "Bytes on disk, from the most recent Disk scan")
            }
            .width(min: 72, ideal: 92, max: 130)
            TableColumn("In use", sortUsing: TrackCVolumeComparator(key: .refCount)) { volume in
                refCountCell(volume)
            }
            .width(min: 64, ideal: 88, max: 110)
        }
        .contextMenu(forSelectionType: VolumeSummary.ID.self) { ids in
            contextMenu(for: ids)
        }
        // Without this, Tahoe's automatic table striping continues past the last
        // record and a four-row inventory reads as twenty broken placeholder rows.
        // Disabling the system striping makes the table visibly end at its data;
        // selection and hover remain system-drawn.
        .alternatingRowBackgrounds(.disabled)
        .accessibilityIdentifier("volumes.table")
    }

    private func nameCell(_ volume: VolumeSummary) -> some View {
        // `Table` exposes no row-level accessibility modifier, so the row's identity —
        // the engine-facing volume name, per docs/design/ACCESSIBILITY-IDENTIFIERS.md —
        // is carried by its Name column cell.
        Text(TrackCDiskMath.volumeDisplayName(volume.name))
            .lineLimit(1)
            .truncationMode(.middle)
            .accessibilityIdentifier("volumes.row.\(volume.name)")
    }

    @ViewBuilder
    private func refCountCell(_ volume: VolumeSummary) -> some View {
        // `nil` is "the engine was not asked for usage data", which is a different fact
        // from "this volume is unused" and must not render as a confident zero.
        if let count = volume.refCount, count > 0 {
            Text(count, format: .number)
                .monospacedDigit()
        } else if volume.refCount == nil {
            Text("—")
                .accessibilityLabel(TrackCVolumeInspector.unscannedValue)
                .help("Usage comes from the Disk scan. Open Disk to compute it.")
        } else {
            Text("Unused")
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<VolumeSummary.ID>) -> some View {
        if let id = ids.first, let volume = model.volumes.first(where: { $0.id == id }) {
            Button("Copy Name") { MorbPasteboard.copy(volume.name) }
            if !volume.mountpoint.isEmpty {
                Button("Copy Guest Mount Point") { MorbPasteboard.copy(volume.mountpoint) }
            }
            Divider()
            Button("Export Volume Archive…") {
                chooseVolumeArchiveDestination(for: volume)
            }
            .disabled(volume.driver != "local" || isPerformingVolumeOperation)
            Divider()
            Button("Remove…", role: .destructive) { removal = volume }
                .disabled(isPerformingVolumeOperation)
        }
    }

    // MARK: Detail pane

    /// The inspector keeps selected-volume identity, real Docker usage evidence, and
    /// consequential commands in one native `Form`. It deliberately does not imply
    /// that a guest mount point can open in Finder or that a missing usage count means
    /// a volume is safe to delete.
    @ViewBuilder
    private var detailPane: some View {
        if let volume = selectedVolume {
            let labels = TrackCVolumeInspector.labels(for: volume)
            let references = TrackCVolumeInspector.referencedContainers(
                for: volume, in: model.containers)
            let usageEvidence = TrackCVolumeInspector.usageEvidence(
                reportedReferenceCount: volume.refCount,
                listedReferences: references.count)

            Form {
                Section("Identity") {
                    LabeledContent("Docker Name") {
                        Text(TrackCDiskMath.volumeDisplayName(volume.name))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Driver", value: volume.driver)
                    LabeledContent(
                        "Volume",
                        value: TrackCDiskMath.isAnonymousVolumeName(volume.name) ? "Anonymous" : "Named")
                    LabeledContent(
                        "Prune",
                        value: TrackCDiskMath.isAnonymousVolumeName(volume.name) ? "Eligible" : "Retained")
                }

                if !labels.isEmpty {
                    DisclosureGroup(
                        "Labels (\(labels.count))",
                        isExpanded: $areLabelsExpanded
                    ) {
                        ForEach(labels) { label in
                            LabeledContent {
                                Text(label.value.isEmpty ? "Empty" : label.value)
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            } label: {
                                Text(label.key)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }

                Section("Storage and Use") {
                    if TrackCVolumeInspector.usageIsUnscanned(
                        size: volume.size, reportedReferenceCount: volume.refCount)
                    {
                        LabeledContent("Usage", value: TrackCVolumeInspector.unscannedValue)
                    } else {
                        LabeledContent(
                            "Size",
                            value: volume.size.map(Formatters.bytesString)
                                ?? TrackCVolumeInspector.unscannedValue)
                        LabeledContent("Used By") {
                            Text(TrackCVolumeInspector.referenceRowValue(for: volume.refCount))
                                .monospacedDigit()
                        }
                    }
                    LabeledContent("Guest Mount Point") {
                        Text(volume.mountpoint.isEmpty ? "Not reported" : volume.mountpoint)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }

                    // One footnote at most. Absence is already stated by the rows; this
                    // exists to name the remedy, or to report a disagreement the rows
                    // cannot show. See TrackCVolumeInspector.usageFootnote.
                    if let footnote = TrackCVolumeInspector.usageFootnote(
                        size: volume.size,
                        reportedReferenceCount: volume.refCount,
                        evidence: usageEvidence)
                    {
                        Text(footnote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !references.isEmpty {
                    DisclosureGroup(
                        "Containers in Current Inventory (\(references.count))",
                        isExpanded: $areContainerReferencesExpanded
                    ) {
                        ForEach(references) { reference in
                            LabeledContent {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(reference.state.capitalized)
                                    Text(reference.image)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            } label: {
                                Text(reference.name)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }

                if let removalProgress {
                    Section("Operation") {
                        ProgressView(removalProgress)
                            .controlSize(.small)
                    }
                }

                Section("Actions") {
                    Button("Export Archive…") {
                        chooseVolumeArchiveDestination(for: volume)
                    }
                    .disabled(!canExport(volume))
                    .help(volumeArchiveExportHelp(for: volume))

                    Button("Remove…", role: .destructive) {
                        removal = volume
                    }
                    .disabled(isPerformingVolumeOperation)
                    .help(
                        isPerformingVolumeOperation
                            ? "Wait for the current volume operation to finish"
                            : TrackCVolumeInspector.removalConsequence(for: volume))

                    Text(TrackCVolumeInspector.removalConsequence(for: volume))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // The automatic system Form, exactly as the Images inspector uses it.
            // `.formStyle(.columns)` is a defect in a 340–460pt inspector: the
            // two-column grid takes its own natural width, and any wide value —
            // a monospaced mount point, a caption sentence — pushes the grid past
            // the column and clips *both* edges ("Docker Name" rendered as
            // "ocker Name"). The automatic style lays labels at the leading edge
            // and truncates values inside the available width.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView(
                "No Volume Selected",
                systemImage: "externaldrive",
                description: Text("Select a volume to see its guest mount point and what is using it."))
        }
    }

    // MARK: Operations

    @MainActor
    private func presentVolumeCreateSheet() {
        guard !isPerformingVolumeOperation else { return }
        newVolumeName = ""
        volumeCreateFailure = nil
        isVolumeCreatePresented = true
    }

    /// Sends the exact reviewed name through the narrow `POST /volumes/create` client
    /// operation. Docker owns validation and same-driver duplicate behavior, so the
    /// completion wording does not pretend it can distinguish a new volume from an
    /// existing local volume that Docker returned unchanged.
    @MainActor
    private func createVolume(_ request: VolumeCreateRequest) async {
        guard volumeCreateProgress == nil else { return }
        volumeCreateFailure = nil
        volumeCreateProgress = "Creating \(request.name)…"
        defer { volumeCreateProgress = nil }

        do {
            _ = try await model.client.createVolume(name: request.name)
            await model.refreshAll()
            selection = request.name
            showsInspector = true
            isVolumeCreatePresented = false
            operationAlert = VolumeOperationAlert(
                title: "Volume Available",
                message: "Docker returned \(request.name). If a local volume with this name already existed, Docker kept its contents unchanged; otherwise it is a new empty volume.",
                focusID: request.name)
        } catch {
            volumeCreateFailure = MorbErrorMessage.text(for: error)
        }
    }

    /// Uses the system save panel for destination choice, then presents a native review
    /// sheet with the selected source, destination, and replacement consequence. The
    /// service repeats output safety checks before it ever publishes an archive.
    @MainActor
    private func chooseVolumeArchiveDestination() {
        guard let selectedVolume else { return }
        chooseVolumeArchiveDestination(for: selectedVolume)
    }

    @MainActor
    private func chooseVolumeArchiveDestination(for volume: VolumeSummary) {
        guard volume.driver == "local", !isPerformingVolumeOperation else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.tarArchive]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "morbstack-volume-\(volume.name).tar"
        panel.message = "Save an archive of the selected local Docker volume. The volume remains unchanged."
        panel.prompt = "Export"

        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        // NSSavePanel owns the standard system replacement confirmation. The review
        // states that result in-app, and the service validates it again before
        // publishing only after its temporary stopped helper is removed.
        let replaceExisting = FileManager.default.fileExists(atPath: outputURL.path)
        volumeArchiveExportReview = VolumeArchiveExportReview(
            volumeName: volume.name,
            outputURL: outputURL,
            replacesExisting: replaceExisting)
    }

    @MainActor
    private func beginVolumeArchiveExport(_ review: VolumeArchiveExportReview) {
        guard !isPerformingVolumeOperation else { return }

        let cancellation = VolumeArchiveExportCancellation()
        let operation = VolumeArchiveExportOperation(
            volumeName: review.volumeName,
            outputURL: review.outputURL)
        volumeArchiveExport = operation
        volumeArchiveExportCancellation = cancellation

        let operationID = operation.id
        let volumeName = review.volumeName
        let progressRelay = VolumeArchiveExportProgressRelay { progress in
            self.recordVolumeArchiveExportProgress(progress, for: operationID)
        }
        Task.detached(priority: .userInitiated) {
            do {
                let result = try VolumeArchiveExporter.export(
                    volumeName: volumeName,
                    to: review.outputURL,
                    replaceExisting: review.replacesExisting,
                    onProgress: { progress in
                        guard !cancellation.isRequested else { return false }
                        progressRelay.send(progress)
                        return true
                    })
                await self.finishVolumeArchiveExport(.success(result), for: operationID)
            } catch {
                await self.finishVolumeArchiveExport(.failure(error), for: operationID)
            }
        }
    }

    @MainActor
    private func cancelVolumeArchiveExport() {
        guard var operation = volumeArchiveExport, !operation.isCancellationRequested else { return }
        operation.isCancellationRequested = true
        volumeArchiveExport = operation
        volumeArchiveExportCancellation?.request()
    }

    @MainActor
    private func recordVolumeArchiveExportProgress(
        _ progress: VolumeArchiveExportProgress,
        for operationID: UUID
    ) {
        guard var operation = volumeArchiveExport, operation.id == operationID else { return }
        operation.record(progress)
        volumeArchiveExport = operation
    }

    @MainActor
    private func finishVolumeArchiveExport(
        _ result: Result<VolumeArchiveExportResult, Error>,
        for operationID: UUID
    ) {
        guard volumeArchiveExport?.id == operationID else { return }
        volumeArchiveExport = nil
        volumeArchiveExportCancellation = nil

        switch result {
        case .success(let export):
            volumeArchiveExportNotice = .success(result: export)
        case .failure(let error):
            if let exportError = error as? VolumeArchiveExportError, exportError == .cancelled {
                volumeArchiveExportNotice = .cancelled()
            } else {
                volumeArchiveExportNotice = .failure(error)
            }
        }
    }

    private func reviewUnusedVolumes() {
        let plan = VolumeUnusedRemovalPlan(volumes: model.volumes)
        guard !plan.items.isEmpty else { return }
        unusedRemovalPlan = plan
    }

    @MainActor
    private func remove(_ volume: VolumeSummary) async {
        guard !isPerformingVolumeOperation else { return }
        removalProgress = "Removing \(TrackCDiskMath.volumeDisplayName(volume.name))…"
        defer { removalProgress = nil }
        do {
            try await model.client.removeVolume(name: volume.name)
            if selection == volume.id { selection = nil }
            await model.refreshAll()
        } catch {
            operationAlert = VolumeOperationAlert(
                title: "Could not remove \(volume.name)",
                message: MorbErrorMessage.text(for: error),
                focusID: volume.id)
        }
    }

    @MainActor
    private func removeUnused(_ names: [String]) async {
        guard !names.isEmpty, !isPerformingVolumeOperation else { return }
        removalProgress = "Removing 0 of \(names.count) volumes…"
        defer { removalProgress = nil }

        var removed = 0
        var failures: [String] = []

        for (index, name) in names.enumerated() {
            removalProgress = "Removing \(index + 1) of \(names.count) volume\(names.count == 1 ? "" : "s")…"
            do {
                try await model.client.removeVolume(name: name)
                removed += 1
                if selection == name { selection = nil }
            } catch {
                failures.append(name)
            }
        }

        if failures.isEmpty {
            // The rows disappear and the window subtitle updates after refresh, which
            // is the native acknowledgement for a completed destructive operation.
        } else if removed > 0 {
            operationAlert = VolumeOperationAlert(
                title: "Removed \(removed) of \(names.count) volume\(names.count == 1 ? "" : "s")",
                message: "Still in use: \(failures.prefix(3).joined(separator: ", ")).",
                focusID: failures.first)
        } else {
            operationAlert = VolumeOperationAlert(
                title: "No volumes were removed",
                message: "The engine still holds every selected volume in the list.",
                focusID: failures.first)
        }
        await model.refreshAll()
    }
}
