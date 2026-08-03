// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The Disk screen.
//
// One question, asked and answered above the fold: *where did my disk go, and how much
// of it can I have back?* A stacked bar answers the first at a glance, a same-hue dimmed
// tail answers the second in the same pixels, and four prune buttons act on it — each
// behind a sheet that names what it is about to delete.
//
// A sunburst was the obvious first idea and the wrong one: four categories with a
// three-orders-of-magnitude spread render as one circle and three invisible slivers, and
// a ring cannot show "of this, that much is garbage" without a second ring nobody can
// read. A single bar with a dimmed tail shows both facts in one shape, and — per
// `docs/design/IDENTITY.md` §2.5 — without the diagonal hatching the previous build used,
// which reads as a moiré artefact rather than as "reclaimable" at the sizes this bar
// actually renders at.
//
// All the arithmetic lives in `TrackCDiskMath`; this file is only the drawing.

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

// MARK: - Root

struct DiskRootView: View {

    let model: AppModel

    @State private var highlighted: TrackCDiskCategory?
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
        guard model.disk != nil else { return "Waiting for the engine" }
        return "\(Formatters.bytesString(usage.total)) in use · \(Formatters.bytesString(usage.reclaimable)) reclaimable"
    }

    var body: some View {
        Group {
            if model.disk == nil {
                MorbEmptyState(
                    "No usage data yet",
                    systemImage: "chart.pie",
                    description: "Disk usage comes from the engine. Start it and this fills in — the first "
                        + "calculation walks every layer, so give it a moment.")
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
                Label("Recalculate", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(busy)
            .help("Recalculate disk usage — the engine walks every layer, so this is not instant")
        }
    }

    // MARK: Usage summary
    //
    // The one thing on this screen that earns a custom drawing rather than a system
    // container: a real chart, not a card. `TrackCStackedBar` is a `Canvas`, not a
    // painted panel — it carries no fill, no hairline border and no card chrome of its
    // own, so it is not what the "delete the cards" instruction is about. It sits
    // directly on the window's content background, restrained to two numbers and one
    // bar rather than the four-card spread this replaces.

    private var usageSummary: some View {
        VStack(alignment: .leading, spacing: Theme.space4) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.space6) {
                let total = splitBytes(usage.total)
                MorbMetric(value: total.value, unit: total.unit, caption: "used by Docker", emphasis: .leading)
                if usage.reclaimable > 0 {
                    let reclaim = splitBytes(usage.reclaimable)
                    MorbMetric(value: reclaim.value, unit: reclaim.unit, caption: "reclaimable", tone: Theme.statusBusy)
                }
                Spacer(minLength: Theme.space3)
            }

            TrackCStackedBar(segments: segments, highlighted: highlighted)
                .frame(height: 30)
                .morbAnimation(.fade, value: highlighted)

            HStack(spacing: Theme.space2) {
                Text("Layers on disk")
                    .foregroundStyle(.tertiary)
                MorbNumber(Formatters.bytesString(usage.layersSize))
                Text("— shared base layers are counted once, so this is smaller than the sum of image sizes.")
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .font(.caption2)
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
                    Button("Prune", role: .destructive) {
                        pruning = segment.category.pruneTarget
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(busy)
                    .help(segment.category.pruneSummary)
                    .frame(height: Theme.rowStandard, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 50, ideal: 60, max: 70)
            }
            .tableStyle(.inset)
            .alternatingRowBackgrounds()
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
        .contentShape(Rectangle())
        .onHover { hovering in
            highlighted = hovering ? segment.category : (highlighted == segment.category ? nil : highlighted)
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

    // MARK: Biggest items
    //
    // The named offenders behind two of the four categories. The categories answer
    // *where* the disk went; they cannot answer *what to delete*. "Volumes, 13.26 GB" is
    // a fact you can do nothing with. "shopfront_uploads, 3.22 GB" is a decision. Images
    // and volumes only: containers and build cache are aggregates the engine reports as
    // a lump. Real `Table`s, not hand-drawn progress bars — the size column, already
    // sorted largest first, says everything a bar underneath it would have repeated.

    /// How many rows each table shows before it would rather scroll than grow.
    private static let biggestRows = 5

    @ViewBuilder
    private var biggestSection: some View {
        let topImages = TrackCDiskMath.largestImages(model.images, limit: Self.biggestRows)
        let topVolumes = TrackCDiskMath.largestVolumes(model.volumes, limit: Self.biggestRows)

        if !topImages.isEmpty || !topVolumes.isEmpty {
            HStack(alignment: .top, spacing: Theme.space5) {
                if !topImages.isEmpty {
                    biggestTable(title: "Largest Images", symbol: "shippingbox", items: topImages)
                }
                if !topVolumes.isEmpty {
                    biggestTable(title: "Largest Volumes", symbol: "externaldrive", items: topVolumes)
                }
            }
        }
    }

    private func biggestTable(title: String, symbol: String, items: [TrackCNamedSize]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MorbSectionHeader(title, symbol: symbol)
                .padding(.bottom, Theme.space2)
            Table(items) {
                TableColumn("Name") { item in
                    Text(item.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.detail ?? item.label)
                        .frame(height: Theme.rowStandard, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                TableColumn("Size") { item in
                    MorbNumber(Formatters.bytesString(item.bytes), tone: .primary, font: .callout)
                        .frame(height: Theme.rowStandard, alignment: .trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 76, ideal: 92, max: 120)
            }
            .tableStyle(.inset)
            .alternatingRowBackgrounds()
            .frame(height: Theme.rowGroupHeader + CGFloat(items.count) * Theme.rowStandard)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: VM disk image
    //
    // A `GroupBox` of `LabeledContent` rows rather than a nested `Form`: the rest of the
    // screen already lives inside one `ScrollView`, and a `Form` — List-backed, like
    // every SwiftUI form — fights an enclosing scroll view for the gesture unless it is
    // given a hand-measured fixed height. Four static rows do not need List's machinery;
    // `GroupBox` gives the same grouped, boxed look `Form` would without the conflict,
    // which is what item 1 of the design brief means by "`GroupBox` only where a genuine
    // box is warranted" — a self-contained footnote panel is exactly that case.

    @ViewBuilder
    private var diskImageSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MorbSectionHeader("VM Disk Image", symbol: "internaldrive")
                .padding(.bottom, Theme.space2)
            GroupBox {
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
                    .padding(Theme.space4)
                } else {
                    Text("No disk image yet — one is created the first time the engine starts.")
                        .foregroundStyle(.secondary)
                        .padding(Theme.space4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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

    /// Splits a formatted byte string (`"25.15 GB"`) at its last space so the value and
    /// unit can be handed to `MorbMetric` at their two different type ranks.
    private func splitBytes(_ bytes: Int64) -> (value: String, unit: String?) {
        let full = Formatters.bytesString(bytes)
        guard let space = full.lastIndex(of: " ") else { return (full, nil) }
        return (String(full[full.startIndex..<space]), String(full[full.index(after: space)...]))
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

// MARK: - The stacked bar

/// The stacked usage bar, drawn in one `Canvas` pass.
///
/// A `Canvas` rather than an `HStack` of rectangles: the reclaimable tail has to sit
/// flush against its segment's trailing edge with a hairline between neighbours, which is
/// fiddlier to get pixel-exact in SwiftUI layout primitives than in fifteen lines here.
struct TrackCStackedBar: View {

    let segments: [TrackCDiskSegment]
    var highlighted: TrackCDiskCategory?

    /// Corner radius of the whole bar. The bar is clipped to this, so segments never
    /// need rounding of their own.
    private let radius: CGFloat = Theme.radiusControl + 1

    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            let clip = Path(roundedRect: bounds, cornerRadius: radius, style: .continuous)

            let widths = TrackCDiskMath.barWidths(
                byteValues: segments.map(\.bytes),
                totalWidth: Double(size.width),
                minimumSegmentWidth: 6)

            guard widths.contains(where: { $0 > 0 }) else {
                context.stroke(clip, with: .color(.secondary.opacity(0.35)), style: .init(lineWidth: 1, dash: [4, 4]))
                return
            }

            context.clip(to: clip)

            var x: CGFloat = 0
            for (index, segment) in segments.enumerated() {
                let width = CGFloat(widths[index])
                guard width > 0 else { continue }
                let rect = CGRect(x: x, y: 0, width: width, height: size.height)
                x += width

                let dimmed = highlighted != nil && highlighted != segment.category

                // The reclaimable share is drawn as its own disjoint rectangle at the
                // tail, at `Theme.seriesDimAlpha`, rather than as an overlay on top of an
                // already-opaque fill of the same hue — translucent colour composited
                // over an opaque fill of the *same* colour is a no-op regardless of
                // alpha, which is why the previous drawing used a hatch texture instead.
                // Disjoint rects make the dimming actually visible against the card
                // behind the bar.
                let reclaimShare = segment.bytes > 0
                    ? min(1, Double(segment.reclaimableBytes) / Double(segment.bytes)) : 0
                let reclaimWidth = width * CGFloat(reclaimShare)
                let solidWidth = width - reclaimWidth

                let baseAlpha: CGFloat = dimmed ? 0.34 : 1
                if solidWidth > 0 {
                    let solidRect = CGRect(x: rect.minX, y: 0, width: solidWidth, height: size.height)
                    context.fill(Path(solidRect), with: .color(segment.category.color.opacity(baseAlpha)))
                }
                if reclaimWidth > 0.5 {
                    let reclaimRect = CGRect(x: rect.maxX - reclaimWidth, y: 0, width: reclaimWidth, height: size.height)
                    context.fill(
                        Path(reclaimRect),
                        with: .color(segment.category.color.opacity(Theme.seriesDimAlpha * baseAlpha)))
                }

                // A hairline between neighbours, so two similar colours never merge.
                if x < size.width {
                    context.fill(
                        Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)),
                        with: .color(.black.opacity(0.16)))
                }
            }
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        }
        .accessibilityElement()
        .accessibilityLabel("Disk usage by category")
        .accessibilityValue(
            segments
                .filter { $0.bytes > 0 }
                .map { "\($0.category.title) \(Formatters.bytesString($0.bytes))" }
                .joined(separator: ", "))
    }
}
