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
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Remove \(plan.countLabel)", role: .destructive) {
                        dismiss()
                        onConfirm(plan.items.map(\.id))
                    }
                    .disabled(plan.items.isEmpty)
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
    @State private var busy = false
    @State private var operationAlert: VolumeOperationAlert?
    @State private var volumeArchiveExport: VolumeArchiveExportOperation?
    @State private var volumeArchiveExportCancellation: VolumeArchiveExportCancellation?
    @State private var volumeArchiveExportNotice: VolumeArchiveExportNotice?
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
        busy || volumeArchiveExport != nil
    }

    private var canExportSelectedVolume: Bool {
        guard let selectedVolume else { return false }
        return selectedVolume.driver == "local" && !isPerformingVolumeOperation
    }

    private var volumeArchiveExportHelp: String {
        guard let selectedVolume else { return "Select a local volume to export" }
        guard selectedVolume.driver == "local" else {
            return "Only Docker local-driver volumes can be exported"
        }
        if volumeArchiveExport != nil { return "A volume archive export is already in progress" }
        if busy { return "Wait for the current volume operation to finish" }
        return "Export the selected volume as a tar archive"
    }

    var body: some View {
        lifecycleContent
    }

    private var routeContent: some View {
        content
            .navigationTitle("Volumes")
            .navigationSubtitle(subtitle)
            .searchable(text: $query, placement: .toolbar, prompt: "Name, driver, mount point")
            .toolbar { toolbarContent }
            .sheet(item: $unusedRemovalPlan) { plan in
                VolumeUnusedRemovalReview(plan: plan) { names in
                    Task { await removeUnused(names) }
                }
            }
    }

    private var volumeArchiveExportSheetContent: some View {
        routeContent
            .sheet(item: $volumeArchiveExport) { operation in
                VolumeArchiveExportSheet(operation: operation, cancel: cancelVolumeArchiveExport)
                    .interactiveDismissDisabled()
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
                if volume.isUnused {
                    Text("Everything stored in this volume is deleted permanently.")
                } else if volume.refCount == nil {
                    Text(
                        "Docker did not report whether containers use this volume. The engine will refuse removal if it is still attached.")
                } else {
                    Text(
                        "\(volume.refCount ?? 0) container\((volume.refCount ?? 0) == 1 ? "" : "s") "
                        + "still use this volume. The engine will refuse unless they are removed first.")
                }
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
            // Selects the first row so the inspector opens with something to show —
            // the same "select the first item" convention Mail and Finder use, and the
            // fix for a resource screen that otherwise reads as half its window empty.
            .task {
                if selection == nil { selection = visible.first?.id }
            }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(id: "volumes.removeUnused", placement: .secondaryAction) {
            if busy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Removing volumes")
            } else {
                Button(role: .destructive) {
                    reviewUnusedVolumes()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(unusedCount == 0 || isPerformingVolumeOperation)
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
                Image(systemName: "square.and.arrow.down")
            }
            .accessibilityLabel("Export selected volume")
            .help(volumeArchiveExportHelp)
            .disabled(!canExportSelectedVolume)
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
                .accessibilityLabel(showsInspector ? "Hide inspector" : "Show inspector")
                .help(showsInspector ? "Hide the inspector" : "Show the inspector")
            }
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
                    Task { await model.refreshAll() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button {
                    MorbPasteboard.copy(
                        "docker --host unix://\(MorbPaths.dockerSocket.path) volume create my-data")
                } label: {
                    Label("Copy a Create Command", systemImage: "doc.on.doc")
                }
            }
        } else if visible.isEmpty {
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
    }

    private func nameCell(_ volume: VolumeSummary) -> some View {
        Text(TrackCDiskMath.volumeDisplayName(volume.name))
            .lineLimit(1)
            .truncationMode(.middle)
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
                .accessibilityLabel("Usage unreported")
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

    /// The inspector's contents: a native `Form`, not a stack of hand-drawn cards.
    ///
    /// `Form` + `LabeledContent` gives the system ownership of labels, row spacing, and
    /// the inspector surface. Status and size stay as separate values instead of a
    /// custom badge, keeping this dense like a native macOS inspector.
    @ViewBuilder
    private var detailPane: some View {
        if let volume = selectedVolume {
            Form {
                Section("Volume") {
                    LabeledContent("Name") {
                        Text(TrackCDiskMath.volumeDisplayName(volume.name))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Status", value: volume.usageStatus)
                    LabeledContent("Size", value: volume.size.map(Formatters.bytesString) ?? "Unreported")
                    LabeledContent("Driver", value: volume.driver)
                    LabeledContent("Guest Mount Point") {
                        Text(volume.mountpoint.isEmpty ? "unknown" : volume.mountpoint)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    LabeledContent(
                        "In use by",
                        value: volume.refCount.map { "\($0) container\($0 == 1 ? "" : "s")" }
                            ?? "unreported")
                }

                Section("Kind") {
                    LabeledContent(
                        "Volume",
                        value: TrackCDiskMath.isAnonymousVolumeName(volume.name) ? "Anonymous" : "Named")
                    LabeledContent(
                        "Prune",
                        value: TrackCDiskMath.isAnonymousVolumeName(volume.name) ? "Eligible" : "Retained")
                }

            }
            .formStyle(.columns)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView(
                "No Volume Selected",
                systemImage: "externaldrive",
                description: Text("Pick a volume to see its guest mount point and what is using it."))
        }
    }

    // MARK: Operations

    /// Uses the system save panel for the explicit selected-volume command. The panel
    /// owns destination choice and replacement confirmation; the service repeats the
    /// output safety checks before it ever publishes an archive.
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

        // NSSavePanel owns the system replacement confirmation. The service validates
        // this again and publishes only after its temporary stopped helper is removed.
        let replaceExisting = FileManager.default.fileExists(atPath: outputURL.path)
        let cancellation = VolumeArchiveExportCancellation()
        let operation = VolumeArchiveExportOperation(volumeName: volume.name, outputURL: outputURL)
        volumeArchiveExport = operation
        volumeArchiveExportCancellation = cancellation

        let operationID = operation.id
        let volumeName = volume.name
        let progressRelay = VolumeArchiveExportProgressRelay { progress in
            self.recordVolumeArchiveExportProgress(progress, for: operationID)
        }
        Task.detached(priority: .userInitiated) {
            do {
                let result = try VolumeArchiveExporter.export(
                    volumeName: volumeName,
                    to: outputURL,
                    replaceExisting: replaceExisting,
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
        busy = true
        defer { busy = false }
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
        busy = true
        defer { busy = false }

        var removed = 0
        var failures: [String] = []

        for name in names {
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
                title: "Removed \(removed) of \(names.count) volumes",
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
