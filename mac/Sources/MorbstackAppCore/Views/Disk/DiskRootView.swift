// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The Disk screen.
//
// This is an operational screen, not a storage dashboard. The native rows below answer
// the useful questions directly: how much is used, what is reclaimable, and which
// resources are worth investigating or pruning.

import SwiftUI

// MARK: - Category colour

extension TrackCDiskCategory {
    var color: Color {
        switch self {
        case .images: return TrackCPalette.images
        case .containers: return TrackCPalette.containers
        case .volumes: return TrackCPalette.volumes
        case .buildCache: return TrackCPalette.buildCache
        }
    }

    var pruneTarget: TrackCPruneTarget {
        switch self {
        case .images: return .images
        case .containers: return .containers
        case .volumes: return .volumes
        case .buildCache: return .buildCache
        }
    }
}

// MARK: - Largest items

/// A named resource in the disk screen's single, size-ordered list.
///
/// Keeping images and volumes in one table avoids the dashboard-like pair of miniature
/// tables that used to compete for attention below the usage bar. The source stays
/// visible, but the one question here is simply "what is largest?".
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

// MARK: - Root

struct DiskRootView: View {

    let model: AppModel

    @State private var pruning: TrackCPruneTarget?
    @State private var footprint: TrackCDiskImageFootprint?
    @State private var busy = false
    @State private var toast: TrackCToast?

    /// Whether the footprint was handed in, in which case this view does not go and
    /// `stat` the real disk image over the top of it.
    private let footprintIsInjected: Bool

    /// - Parameter initialFootprint: the VM disk image's `stat` figures, when the caller
    ///   already has them. The app leaves this `nil` and reads them in `.task`; previews
    ///   and the offscreen screenshot harness pass a value, because a hosted view *does*
    ///   run `.task` and the real `~/.morbstack/data/disk.img` on the machine taking the
    ///   screenshot is not the one the screenshot is meant to describe.
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
            return model.engine.isRunning ? "Calculating usage…" : "Engine isn't running"
        }
        return "\(Formatters.bytesString(usage.total)) in use · \(Formatters.bytesString(usage.reclaimable)) reclaimable"
    }

    var body: some View {
        Group {
            if model.disk == nil, model.engine.isRunning {
                MorbEmptyState(
                    "Calculating disk usage",
                    systemImage: "internaldrive",
                    description: "Morbstack is reading the engine's storage records. This can take a little longer on a large image store.",
                    actionTitle: "Try Again"
                ) {
                    Task { await model.refreshDisk() }
                }
            } else if model.disk == nil {
                MorbEmptyState(
                    "The engine isn't running",
                    systemImage: "internaldrive",
                    description: "Start the engine to see Docker images, containers, volumes and build cache on disk.",
                    actionTitle: model.engine.state == "suspended" ? "Resume Engine" : "Start Engine"
                ) {
                    Task { await model.engineAction(.start) }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.space6) {
                        usageSummary
                        categorySection
                        biggestSection
                        diskImageSection
                    }
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.top, Theme.space5)
                    .padding(.bottom, Theme.space6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .morbScreen(title: "Disk", subtitle: subtitle, edge: .soft)
        .toolbar { toolbarContent }
        .trackCToast($toast)
        .sheet(item: $pruning) { target in
            let preview = TrackCDiskMath.prunePreview(
                target: target,
                usage: model.disk,
                containers: model.containers,
                images: model.images,
                volumes: model.volumes)
            TrackCConfirmSheet(
                title: "Prune \(target.category.title.lowercased())",
                symbol: target.category.symbol,
                explanation: target.category.pruneSummary,
                items: preview.items,
                kept: preview.kept,
                knownBytes: preview.knownBytes,
                hasUnknownSizes: preview.hasUnknownSizes,
                confirmTitle: "Prune \(preview.countLabel)",
                onConfirm: { Task { await prune(target) } })
        }
        .task {
            guard !footprintIsInjected else { return }
            await loadFootprint()
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Deliberately *not* called "Refresh" and deliberately not `arrow.clockwise`:
        // the window already carries a shared Refresh, and two identical circular arrows
        // sitting next to each other would be two buttons that look like one mistake.
        // This one is a different, much more expensive operation and says so.
        ToolbarItem(id: "disk.recalculate", placement: MorbToolbarGroup.actions) {
            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .accessibilityLabel("Recalculate disk usage")
            .disabled(busy)
            .help("Recalculate disk usage — the engine walks every layer, so this is not instant")
        }
    }

    // MARK: Usage summary
    //
    // The previous full-width, multi-colour canvas read as a dashboard hero rather than
    // an operational fact. The category table below already has the useful breakdown;
    // a compact native key/value summary lets that table carry the visual hierarchy.

    private var usageSummary: some View {
        VStack(alignment: .leading, spacing: Theme.space4) {
            MorbSectionHeader("Storage", symbol: "internaldrive")
            LabeledContent("Shared image layers") {
                MorbNumber(Formatters.bytesString(usage.layersSize))
            }
            LabeledContent("Used by Docker") {
                MorbNumber(Formatters.bytesString(usage.total), tone: .primary, font: .body)
            }
            if usage.reclaimable > 0 {
                LabeledContent("Reclaimable") {
                    MorbNumber(Formatters.bytesString(usage.reclaimable), tone: Theme.statusBusy, font: .body)
                }
            }
            Text("Shared base layers are counted once, so their total can be smaller than the sum of image sizes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Category breakdown

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MorbSectionHeader("By Category", symbol: "chart.pie")
                .padding(.bottom, Theme.space2)
            Table(segments) {
                TableColumn("Category") { segment in
                    categoryCell(segment)
                        .frame(height: Theme.rowStandard, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                TableColumn("Size") { segment in
                    MorbNumber(Formatters.bytesString(segment.bytes), tone: .primary, font: .callout)
                        .frame(height: Theme.rowStandard, alignment: .trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 76, ideal: 96, max: 130)
                TableColumn("Reclaimable") { segment in
                    reclaimableCell(segment)
                        .frame(height: Theme.rowStandard, alignment: .trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 96, ideal: 130, max: 180)
                TableColumn("") { segment in
                    Button(role: .destructive) {
                        pruning = segment.category.pruneTarget
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .accessibilityLabel("Prune \(segment.category.title)")
                    .disabled(busy)
                    .help(segment.category.pruneSummary)
                    .frame(height: Theme.rowStandard, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 50, ideal: 60, max: 70)
            }
            .tableStyle(.automatic)
            .frame(height: Theme.rowGroupHeader + CGFloat(segments.count) * Theme.rowStandard)
        }
    }

    private func categoryCell(_ segment: TrackCDiskSegment) -> some View {
        HStack(spacing: Theme.space3) {
            Circle()
                .fill(segment.category.color)
                .frame(width: Theme.dotSize, height: Theme.dotSize)
            Text(segment.category.title)
            Text(shareText(segment))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func reclaimableCell(_ segment: TrackCDiskSegment) -> some View {
        if segment.reclaimableBytes > 0 {
            Text(Formatters.bytesString(segment.reclaimableBytes) + (segment.isEstimate ? " (approx.)" : ""))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    private func shareText(_ segment: TrackCDiskSegment) -> String {
        guard usage.total > 0 else { return "0%" }
        return Formatters.percent(segment.fraction(of: usage.total) * 100)
    }

    // MARK: Largest items
    //
    // The category table answers where the bytes went; this one answers what is actually
    // large enough to investigate. A single `Table` gives the content hierarchy of a Mac
    // utility rather than a two-card dashboard.

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

    @ViewBuilder
    private var biggestSection: some View {
        let items = largestItems
        if !items.isEmpty {
            largestTable(items)
        }
    }

    private func largestTable(_ items: [TrackCDiskLargestItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MorbSectionHeader("Largest Items", symbol: "arrow.up.right")
                .padding(.bottom, Theme.space2)
            Table(items) {
                TableColumn("Name") { entry in
                    Text(entry.item.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(entry.item.detail ?? entry.item.label)
                        .frame(height: Theme.rowStandard, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                TableColumn("Kind") { entry in
                    Label(entry.kind.title, systemImage: entry.kind.symbol)
                        .foregroundStyle(.secondary)
                        .frame(height: Theme.rowStandard, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .width(min: 84, ideal: 102, max: 128)
                TableColumn("Size") { entry in
                    MorbNumber(Formatters.bytesString(entry.item.bytes), tone: .primary, font: .callout)
                        .frame(height: Theme.rowStandard, alignment: .trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 76, ideal: 92, max: 120)
            }
            .tableStyle(.automatic)
            .frame(height: Theme.rowGroupHeader + CGFloat(items.count) * Theme.rowStandard)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: VM disk image
    //
    // `LabeledContent` keeps these facts legible without a second rounded, material-like
    // panel inside the already-scrolling content area. The disk file is a detail, not a
    // dashboard card.

    @ViewBuilder
    private var diskImageSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MorbSectionHeader("VM Disk Image", symbol: "internaldrive")
                .padding(.bottom, Theme.space2)
            if let footprint {
                VStack(alignment: .leading, spacing: Theme.space3) {
                    LabeledContent("Apparent", value: Formatters.bytesString(footprint.apparentBytes))
                    LabeledContent("Actual on APFS", value: Formatters.bytesString(footprint.actualBytes))
                    LabeledContent("Allocated", value: Formatters.percent(footprint.occupancy * 100))
                    LabeledContent("Path") {
                        Text(footprint.path)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Divider()
                    footnoteExplanation(footprint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, Theme.space2)
            } else {
                Text("No VM disk image yet. Morbstack creates one when the engine starts.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, Theme.space2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Inline code rendered as a monospaced run rather than as literal backtick
    /// characters — see `docs/design/IDENTITY.md` §3.3. Built as one `Text`
    /// concatenation so the whole paragraph still wraps as a single block.
    private func footnoteExplanation(_ footprint: TrackCDiskImageFootprint) -> Text {
        func plain(_ string: String) -> Text {
            Text(string).font(.caption).foregroundColor(.secondary)
        }
        func code(_ string: String) -> Text {
            Text(string).font(.system(.caption, design: .monospaced)).foregroundColor(.primary)
        }
        guard footprint.isSparse else {
            return plain(
                "This image is close to fully allocated, so the apparent and actual figures agree. "
                + "Space freed inside the guest is not automatically returned to APFS — the file keeps "
                + "its blocks until it is trimmed or recreated.")
        }
        return plain("The image is a sparse file: it is created at its full size but only consumes blocks "
                      + "the guest has written. Finder, ")
            + code("ls -l")
            + plain(" and ")
            + code("du --apparent-size")
            + plain(" all report the apparent figure — the actual one is ")
            + code("st_blocks × 512")
            + plain(", and it is \(Formatters.bytesString(footprint.savedBytes)) smaller right now.")
    }

    // MARK: Operations

    @MainActor
    private func refresh() async {
        busy = true
        defer { busy = false }
        await model.refreshAll()
        await loadFootprint()
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
            let reclaimed: Int64
            switch target {
            case .containers: reclaimed = try await model.client.pruneContainers()
            case .images: reclaimed = try await model.client.pruneImages()
            case .volumes: reclaimed = try await model.client.pruneVolumes()
            case .buildCache: reclaimed = try await model.client.pruneBuildCache()
            }
            toast = reclaimed > 0
                ? .success(
                    "Reclaimed \(Formatters.bytesString(reclaimed))",
                    detail: "\(target.category.title) pruned")
                : .info("Nothing to reclaim", detail: "\(target.category.title) were already clean")
            await model.refreshAll()
            await loadFootprint()
        } catch {
            toast = .failure("Prune failed", detail: trackCErrorText(error))
        }
    }
}
