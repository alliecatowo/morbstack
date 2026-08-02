// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The Volumes screen.
//
// Volumes are the one resource in this app where a wrong click loses data that cannot be
// pulled again, so the screen is deliberately more cautious than the others: no prune
// button in the header without a preview, no size shown as `0 B` when the truth is "not
// reported", and the mountpoint always one click away.
//
// A real `Table` replaces the hand-rolled column grid, and a detail pane replaces the
// popover: selecting a volume opens its driver, mountpoint and reference count beside the
// list rather than in a transient bubble, which is also what gives this screen something
// to show besides a thin thirty-two-point row — the emptiness `CRITIQUE.md` calls out by
// name. The pane is a plain `HSplitView`, not `.inspector(isPresented:)` — the offscreen
// screenshot harness's `NSHostingView` does not composite `.inspector` content, only real
// view hierarchy (see the note on `content` below).

import AppKit
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
        case .name: result = trackCCompareStrings(lhs.name, rhs.name)
        case .driver:
            result = lhs.driver == rhs.driver
                ? trackCCompareStrings(lhs.name, rhs.name)
                : trackCCompareStrings(lhs.driver, rhs.driver)
        case .size: result = trackCCompareOptionalInt(lhs.size, rhs.size)
        case .refCount:
            result = trackCCompareOptionalInt(
                lhs.refCount.map(Int64.init), rhs.refCount.map(Int64.init))
        }
        return order == .forward ? result : result.reversed
    }
}

// MARK: - Root

struct VolumesRootView: View {

    let model: AppModel

    @State private var query = ""
    @State private var sortOrder: [TrackCVolumeComparator] = [TrackCVolumeComparator(key: .name)]
    @State private var selection: VolumeSummary.ID?

    @State private var showingUnusedSheet = false
    @State private var removal: VolumeSummary?
    @State private var busy = false
    @State private var toast: TrackCToast?

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

    var body: some View {
        content
            .morbScreen(title: "Volumes", subtitle: subtitle, edge: .hard)
            .searchable(text: $query, placement: .toolbar, prompt: "Name, driver, mount point")
            .toolbar { toolbarContent }
            .trackCToast($toast)
            .sheet(isPresented: $showingUnusedSheet) {
                let plan = TrackCVolumeList.unusedPlan(model.volumes)
                TrackCConfirmSheet(
                    title: "Remove unused volumes",
                    symbol: "externaldrive.badge.minus",
                    explanation:
                        "These volumes are not attached to any container. Their contents are deleted "
                        + "immediately and cannot be recovered — a database that lives in a named volume "
                        + "looks exactly like this while its stack is stopped.",
                    items: plan.items,
                    knownBytes: plan.knownBytes,
                    hasUnknownSizes: plan.hasUnknownSizes,
                    confirmTitle: "Remove \(plan.items.count)",
                    onConfirm: { Task { await removeUnused(plan.items.map(\.id)) } })
            }
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
                } else {
                    Text(
                        "\(volume.refCount ?? 0) container\((volume.refCount ?? 0) == 1 ? "" : "s") "
                        + "still use this volume. The engine will refuse unless they are removed first.")
                }
            }
            .onDeleteCommand {
                guard let selection, let volume = model.volumes.first(where: { $0.id == selection }) else { return }
                removal = volume
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
        ToolbarItem(id: "removeUnused", placement: MorbToolbarGroup.actions) {
            Button {
                showingUnusedSheet = true
            } label: {
                HStack(spacing: Theme.space2) {
                    Image(systemName: "trash")
                    Text("Remove Unused")
                    if unusedCount > 0 { MorbCountBadge(count: unusedCount) }
                }
            }
            .disabled(unusedCount == 0 || busy)
            .help(
                unusedCount == 0
                    ? "Every volume is attached to a container"
                    : "Review and remove \(unusedCount) unused volume\(unusedCount == 1 ? "" : "s")")
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.volumes.isEmpty {
            MorbEmptyState(
                "No volumes",
                systemImage: "externaldrive",
                description: "Volumes appear here as soon as a container asks for persistent storage — "
                    + "either a named volume in a compose file or a -v flag on morb run.")
        } else if visible.isEmpty {
            MorbNoMatches(query: query)
        } else {
            // A manual split rather than `.inspector(isPresented:)`: the offscreen
            // screenshot harness's `NSHostingView` does not composite `.inspector`
            // content at all (verified empirically, same as `.toolbar` — see
            // `ContainersRootView`'s note), so an `.inspector` here would render as a
            // blank pane in every `dist/shots` capture. An `HSplitView` is real content,
            // draggable, and photographs.
            HSplitView {
                table
                    .frame(minWidth: 480, maxWidth: .infinity)
                detailPane
                    .frame(minWidth: Theme.inspectorMinWidth, idealWidth: Theme.inspectorWidth,
                           maxWidth: Theme.inspectorWidth)
            }
        }
    }

    private var table: some View {
        Table(visible, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", sortUsing: TrackCVolumeComparator(key: .name)) { volume in
                nameCell(volume)
                    .frame(height: Theme.rowStandard, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            TableColumn("Driver", sortUsing: TrackCVolumeComparator(key: .driver)) { volume in
                Text(volume.driver)
                    .foregroundStyle(.secondary)
                    .frame(height: Theme.rowStandard, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 88, ideal: 108, max: 160)
            TableColumn("Size", sortUsing: TrackCVolumeComparator(key: .size)) { volume in
                MorbNumber(volume.size.map(Formatters.bytesString) ?? "—", font: .callout)
                    .frame(height: Theme.rowStandard, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 72, ideal: 92, max: 130)
            TableColumn("In use", sortUsing: TrackCVolumeComparator(key: .refCount)) { volume in
                refCountCell(volume)
                    .frame(height: Theme.rowStandard, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 64, ideal: 88, max: 110)
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds()
        .contextMenu(forSelectionType: VolumeSummary.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            if let id = ids.first { selection = id }
        }
    }

    private func nameCell(_ volume: VolumeSummary) -> some View {
        HStack(spacing: Theme.space2) {
            MorbStatusDot(tone: volume.isUnused ? .idle : .running)
            Text(TrackCDiskMath.volumeDisplayName(volume.name))
                .lineLimit(1)
                .truncationMode(.middle)
            if TrackCDiskMath.isAnonymousVolumeName(volume.name) {
                MorbChip("anonymous", rank: .quiet)
            }
        }
    }

    @ViewBuilder
    private func refCountCell(_ volume: VolumeSummary) -> some View {
        // `nil` is "the engine was not asked for usage data", which is a different fact
        // from "this volume is unused" and must not render as a confident zero.
        if let count = volume.refCount, count > 0 {
            MorbCountBadge(count: count, tone: .running)
        } else if volume.refCount == nil {
            Text("—").foregroundStyle(.tertiary)
        } else {
            Text("unused").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<VolumeSummary.ID>) -> some View {
        if let id = ids.first, let volume = model.volumes.first(where: { $0.id == id }) {
            Button("Copy Name") { trackCCopy(volume.name) }
            if !volume.mountpoint.isEmpty {
                Button("Copy Mount Point") { trackCCopy(volume.mountpoint) }
            }
            Divider()
            Button("Remove…", role: .destructive) { removal = volume }
        }
    }

    // MARK: Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let volume = selectedVolume {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.space5) {
                    VStack(alignment: .leading, spacing: Theme.space2) {
                        Text(TrackCDiskMath.volumeDisplayName(volume.name))
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                            .truncationMode(.middle)
                        MorbStatusBadge(
                            tone: volume.isUnused ? .idle : .running,
                            title: volume.isUnused ? "Unused" : "In use",
                            detail: volume.size.map(Formatters.bytesString),
                            filled: false)
                    }

                    MorbCard {
                        VStack(alignment: .leading, spacing: Theme.space4) {
                            MorbKeyValue("Driver", volume.driver)
                            MorbKeyValue(
                                "Mount point",
                                volume.mountpoint.isEmpty ? "unknown" : volume.mountpoint,
                                monospaced: true)
                            MorbKeyValue(
                                "In use by",
                                volume.refCount.map { "\($0) container\($0 == 1 ? "" : "s")" } ?? "unreported")
                            MorbKeyValue(
                                "Kind",
                                TrackCDiskMath.isAnonymousVolumeName(volume.name)
                                    ? "Anonymous — created implicitly, removed by prune"
                                    : "Named — prune leaves it alone")
                        }
                    }

                    VStack(spacing: Theme.space3) {
                        Button {
                            revealInFinder(volume)
                        } label: {
                            Label("Reveal in Finder", systemImage: "folder")
                                .frame(maxWidth: .infinity)
                        }
                        .morbButton(.standard)
                        .disabled(volume.mountpoint.isEmpty)

                        Button(role: .destructive) {
                            removal = volume
                        } label: {
                            Label("Remove Volume", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .morbButton(.standard)
                    }
                }
                .padding(Theme.pagePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.contentBackground)
        } else {
            MorbEmptyState("No volume selected", systemImage: "externaldrive")
                .background(Theme.contentBackground)
        }
    }

    private func revealInFinder(_ volume: VolumeSummary) {
        guard !volume.mountpoint.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: volume.mountpoint)])
    }

    // MARK: Operations

    @MainActor
    private func remove(_ volume: VolumeSummary) async {
        busy = true
        defer { busy = false }
        do {
            try await model.client.removeVolume(name: volume.name)
            toast = .success("Removed \(volume.name)", detail: volume.size.map { "Freed \(Formatters.bytesString($0))" })
            if selection == volume.id { selection = nil }
            await model.refreshAll()
        } catch {
            toast = .failure("Could not remove \(volume.name)", detail: trackCErrorText(error))
        }
    }

    @MainActor
    private func removeUnused(_ names: [String]) async {
        guard !names.isEmpty else { return }
        busy = true
        defer { busy = false }

        // Sizes are read before the removals, because afterwards there is nothing left to
        // ask. Volumes with an unreported size contribute nothing to the total rather
        // than a guess, so the toast can undercount but never overstate.
        let sizeByName = Dictionary(
            model.volumes.map { ($0.name, $0.size ?? 0) }, uniquingKeysWith: { first, _ in first })

        var removed = 0
        var reclaimed: Int64 = 0
        var failures: [String] = []

        for name in names {
            do {
                try await model.client.removeVolume(name: name)
                removed += 1
                reclaimed += max(0, sizeByName[name] ?? 0)
                if selection == name { selection = nil }
            } catch {
                failures.append(name)
            }
        }

        if failures.isEmpty {
            toast = .success(
                "Removed \(removed) volume\(removed == 1 ? "" : "s")",
                detail: reclaimed > 0 ? "Reclaimed \(Formatters.bytesString(reclaimed))" : nil)
        } else if removed > 0 {
            toast = .info(
                "Removed \(removed) of \(names.count)",
                detail: "Still in use: \(failures.prefix(3).joined(separator: ", "))")
        } else {
            toast = .failure("Nothing could be removed", detail: "The engine still holds every volume in the list.")
        }
        await model.refreshAll()
    }
}
