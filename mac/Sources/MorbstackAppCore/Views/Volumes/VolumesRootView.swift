// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The Volumes screen.
//
// Volumes are the one resource in this app where a wrong click loses data that cannot be
// pulled again, so the screen is deliberately more cautious than the others: no prune
// button in the header without a preview, no size shown as `0 B` when the truth is "not
// reported", and the mountpoint always one click away.

import SwiftUI

// MARK: - Layout

private enum VolumeColumns {
    static let driver: CGFloat = 92
    static let size: CGFloat = 86
    static let refCount: CGFloat = 78
    static let actions: CGFloat = 52
}

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

// MARK: - Root

struct VolumesRootView: View {

    let model: AppModel

    @State private var query = ""
    @State private var sortKey: TrackCVolumeSortKey = .name
    @State private var ascending = true
    @State private var selection: VolumeSummary.ID?

    @State private var showingUnusedSheet = false
    @State private var removal: VolumeSummary?
    @State private var busy = false
    @State private var toast: TrackCToast?

    private var visible: [VolumeSummary] {
        TrackCVolumeList.sorted(
            model.volumes.filter { TrackCVolumeList.matches($0, query: query) },
            by: sortKey, ascending: ascending)
    }

    private var unusedCount: Int { model.volumes.filter(\.isUnused).count }

    private var subtitle: String {
        var parts = ["\(model.volumes.count) volume\(model.volumes.count == 1 ? "" : "s")"]
        let total = TrackCVolumeList.totalSize(model.volumes)
        if total > 0 { parts.append(Formatters.bytesString(total)) }
        if unusedCount > 0 { parts.append("\(unusedCount) unused") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            TrackCPageHeader(title: "Volumes", subtitle: subtitle) {
                HStack(spacing: 8) {
                    TrackCSearchField(text: $query, prompt: "Filter volumes")
                    Button {
                        showingUnusedSheet = true
                    } label: {
                        Label("Remove Unused", systemImage: "trash")
                    }
                    .disabled(unusedCount == 0 || busy)
                    .help(
                        unusedCount == 0
                            ? "Every volume is attached to a container"
                            : "Review and remove \(unusedCount) unused volume\(unusedCount == 1 ? "" : "s")")
                }
            }

            Divider()

            TrackCHeaderBar {
                TrackCSortHeader(
                    title: "Name", key: TrackCVolumeSortKey.name,
                    active: $sortKey, ascending: $ascending)
                TrackCSortHeader(
                    title: "Driver", key: TrackCVolumeSortKey.driver,
                    active: $sortKey, ascending: $ascending)
                    .frame(width: VolumeColumns.driver)
                TrackCSortHeader(
                    title: "Size", key: TrackCVolumeSortKey.size,
                    active: $sortKey, ascending: $ascending, alignment: .trailing)
                    .frame(width: VolumeColumns.size)
                TrackCSortHeader(
                    title: "In use", key: TrackCVolumeSortKey.refCount,
                    active: $sortKey, ascending: $ascending, alignment: .trailing)
                    .frame(width: VolumeColumns.refCount)
                Color.clear.frame(width: VolumeColumns.actions, height: 1)
            }
            .padding(.top, 8)

            content
        }
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
    }

    @ViewBuilder
    private var content: some View {
        if model.volumes.isEmpty {
            TrackCEmptyState(
                title: "No volumes",
                message: "Volumes appear here as soon as a container asks for persistent storage — "
                    + "either a named volume in a compose file or a `-v` flag on `morb run`.",
                symbol: "externaldrive")
        } else if visible.isEmpty {
            TrackCEmptyState(
                title: "No matches",
                message: "Nothing here matches “\(query)”.",
                symbol: "magnifyingglass",
                action: (title: "Clear Filter", run: { query = "" }))
        } else {
            List(selection: $selection) {
                ForEach(visible) { volume in
                    TrackCVolumeRow(volume: volume, onRemove: { removal = volume })
                        .tag(volume.id)
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
    private func remove(_ volume: VolumeSummary) async {
        busy = true
        defer { busy = false }
        do {
            try await model.client.removeVolume(name: volume.name)
            toast = .success("Removed \(volume.name)", detail: volume.size.map { "Freed \(Formatters.bytesString($0))" })
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

// MARK: - Row

private struct TrackCVolumeRow: View {

    let volume: VolumeSummary
    let onRemove: () -> Void

    @State private var hovering = false
    @State private var showingDetail = false

    var body: some View {
        HStack(spacing: TrackCMetrics.columnGap) {
            HStack(spacing: 6) {
                TrackCStatusDot(tone: volume.isUnused ? .neutral : .good)
                Text(TrackCDiskMath.volumeDisplayName(volume.name))
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(volume.mountpoint.isEmpty ? volume.name : "\(volume.name)\n\(volume.mountpoint)")
                if TrackCDiskMath.isAnonymousVolumeName(volume.name) {
                    TrackCBadge(text: "anonymous")
                }
                Spacer(minLength: 0)
            }

            Text(volume.driver)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: VolumeColumns.driver, alignment: .leading)

            // `nil` is "the engine was not asked for usage data", which is a different
            // fact from "this volume is empty" and must not render as `0 bytes`.
            TrackCNumberCell(
                text: volume.size.map(Formatters.bytesString) ?? "—",
                emphasised: volume.size != nil)
                .frame(width: VolumeColumns.size)
                .help(volume.size == nil ? "Size not reported by the engine" : "On-disk size of this volume")

            refCountCell
                .frame(width: VolumeColumns.refCount, alignment: .trailing)

            TrackCHoverActions(revealed: hovering) {
                TrackCRowButton(symbol: "info.circle", help: "Volume details") { showingDetail = true }
                    .popover(isPresented: $showingDetail, arrowEdge: .bottom) {
                        TrackCVolumeDetail(volume: volume)
                    }
            }
            .frame(width: VolumeColumns.actions)
        }
        .frame(height: TrackCMetrics.rowHeight)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy Name") { trackCCopy(volume.name) }
            if !volume.mountpoint.isEmpty {
                Button("Copy Mount Point") { trackCCopy(volume.mountpoint) }
            }
            Divider()
            Button("Volume Details…") { showingDetail = true }
            Divider()
            Button("Remove…", role: .destructive, action: onRemove)
        }
    }

    @ViewBuilder
    private var refCountCell: some View {
        if let count = volume.refCount, count > 0 {
            TrackCBadge(text: "\(count)", symbol: "shippingbox.fill", tone: .good)
        } else if volume.refCount == nil {
            Text("—").font(.callout).foregroundStyle(.tertiary)
        } else {
            Text("unused").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Detail popover

private struct TrackCVolumeDetail: View {

    let volume: VolumeSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(volume.name)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(volume.size.map(Formatters.bytesString) ?? "size not reported")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                labelled("Driver", volume.driver)
                labelled(
                    "Mount point",
                    volume.mountpoint.isEmpty ? "unknown" : volume.mountpoint,
                    monospaced: true)
                labelled(
                    "In use by",
                    volume.refCount.map { "\($0) container\($0 == 1 ? "" : "s")" } ?? "unreported")
                labelled(
                    "Kind",
                    TrackCDiskMath.isAnonymousVolumeName(volume.name)
                        ? "Anonymous — created implicitly, removed by prune"
                        : "Named — prune leaves it alone")
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }

    private func labelled(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
