// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The Disk screen.
//
// One question, asked and answered above the fold: *where did my disk go, and how much
// of it can I have back?* A stacked bar answers the first at a glance, a hatched overlay
// answers the second in the same pixels, and four prune buttons act on it — each behind
// a sheet that names what it is about to delete.
//
// A sunburst was the obvious first idea and the wrong one: four categories with a
// three-orders-of-magnitude spread render as one circle and three invisible slivers, and
// a ring cannot show "of this, that much is garbage" without a second ring nobody can
// read. A single bar with a reclaimable hatch shows both facts in one shape.
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
        VStack(spacing: 0) {
            TrackCPageHeader(title: "Disk", subtitle: subtitle) {
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(busy)
                .help("Recalculate disk usage — the engine walks every layer, so this is not instant")
            }

            Divider()

            if model.disk == nil {
                TrackCEmptyState(
                    title: "No usage data yet",
                    message: "Disk usage comes from the engine. Start it and this fills in — the first "
                        + "calculation walks every layer, so give it a moment.",
                    symbol: "chart.pie")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        barCard
                        legend
                        biggest
                        footnote
                    }
                    .padding(.horizontal, TrackCMetrics.gutter)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
            }
        }
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

    // MARK: The bar

    private var barCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Formatters.bytesString(usage.total))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("used by Docker")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                if usage.reclaimable > 0 {
                    HStack(spacing: 6) {
                        TrackCHatchSwatch()
                        Text("\(Formatters.bytesString(usage.reclaimable)) reclaimable")
                            .font(.callout.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            TrackCStackedBar(segments: segments, highlighted: highlighted)
                .frame(height: 36)
                .animation(.easeOut(duration: 0.18), value: highlighted)

            HStack(spacing: 4) {
                Text("Layers on disk")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(Formatters.bytesString(usage.layersSize))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("— shared base layers are counted once, so this is smaller than the sum of image sizes.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(TrackCMetrics.gutter)
        .background(.quaternary.opacity(0.16), in: .rect(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        }
    }

    // MARK: Legend

    private var legend: some View {
        VStack(spacing: 0) {
            ForEach(segments) { segment in
                TrackCLegendRow(
                    segment: segment,
                    total: usage.total,
                    isHighlighted: highlighted == segment.category,
                    isBusy: busy,
                    onPrune: { pruning = segment.category.pruneTarget })
                    .onHover { hovering in
                        highlighted = hovering ? segment.category : (highlighted == segment.category ? nil : highlighted)
                    }
                if segment.id != segments.last?.id {
                    Divider().padding(.leading, 26)
                }
            }
        }
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.12), in: .rect(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        }
    }

    // MARK: Biggest items

    /// The named offenders behind two of the four bars.
    ///
    /// The categories answer *where* the disk went; they cannot answer *what to delete*,
    /// which is the question anybody who opened this screen actually has. "Volumes,
    /// 13.26 GB" is a fact you can do nothing with. "shopfront_uploads, 3.22 GB" is a
    /// decision.
    ///
    /// Images and volumes only: containers and build cache are aggregates the engine
    /// reports as a lump, and inventing a per-item breakdown for them would mean
    /// inventing the numbers.
    @ViewBuilder
    private var biggest: some View {
        let topImages = TrackCDiskMath.largestImages(model.images, limit: Self.biggestRows)
        let topVolumes = TrackCDiskMath.largestVolumes(model.volumes, limit: Self.biggestRows)

        if !topImages.isEmpty || !topVolumes.isEmpty {
            HStack(alignment: .top, spacing: 20) {
                if !topImages.isEmpty {
                    biggestColumn(
                        title: "Largest images",
                        symbol: "shippingbox",
                        tint: TrackCPalette.images,
                        items: topImages)
                }
                if !topVolumes.isEmpty {
                    biggestColumn(
                        title: "Largest volumes",
                        symbol: "externaldrive",
                        tint: TrackCPalette.volumes,
                        items: topVolumes)
                }
            }
        }
    }

    /// How many rows each column shows. Five is what fits beside the other three cards
    /// in the shortest window the app allows without the page starting to scroll.
    private static let biggestRows = 5

    private func biggestColumn(
        title: String,
        symbol: String,
        tint: Color,
        items: [TrackCNamedSize]
    ) -> some View {
        // Scaled against the largest item *in this column*, not against the disk total:
        // a bar that is 4% wide for every row conveys nothing, and the absolute figure
        // is already printed beside it for anyone who wants the real proportion.
        let peak = max(1, items.map(\.bytes).max() ?? 1)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 9) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.label)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(item.detail ?? item.label)
                            Spacer(minLength: 8)
                            Text(Formatters.bytesString(item.bytes))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(tint.opacity(0.14))
                                Capsule()
                                    .fill(tint)
                                    .frame(
                                        width: max(
                                            2,
                                            geometry.size.width
                                                * CGFloat(Double(item.bytes) / Double(peak))))
                            }
                        }
                        .frame(height: 4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(TrackCMetrics.gutter)
        .background(.quaternary.opacity(0.12), in: .rect(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        }
    }

    // MARK: Footnote

    @ViewBuilder
    private var footnote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("VM disk image")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if let footprint {
                HStack(alignment: .top, spacing: 16) {
                    figure("Apparent", Formatters.bytesString(footprint.apparentBytes), tone: .secondary)
                    figure("Actual on APFS", Formatters.bytesString(footprint.actualBytes), tone: .primary)
                    figure(
                        "Allocated",
                        Formatters.percent(footprint.occupancy * 100),
                        tone: .secondary)
                    Spacer(minLength: 8)
                }

                Text(footnoteExplanation(footprint))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(footprint.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.quaternary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } else {
                Text("No disk image yet — one is created the first time the engine starts.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(TrackCMetrics.gutter)
        .background(.quaternary.opacity(0.1), in: .rect(cornerRadius: 12, style: .continuous))
    }

    private func footnoteExplanation(_ footprint: TrackCDiskImageFootprint) -> String {
        if footprint.isSparse {
            return """
                The image is a sparse file: it is created at its full size but only consumes blocks the \
                guest has written. Finder, `ls -l` and `du --apparent-size` all report the apparent \
                figure — the actual one is `st_blocks × 512`, and it is \
                \(Formatters.bytesString(footprint.savedBytes)) smaller right now.
                """
        }
        return """
            This image is close to fully allocated, so the apparent and actual figures agree. Space \
            freed inside the guest is not automatically returned to APFS — the file keeps its blocks \
            until it is trimmed or recreated.
            """
    }

    private func figure(_ label: String, _ value: String, tone: HierarchicalShapeStyle) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.title3.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(tone)
        }
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
/// A `Canvas` rather than an `HStack` of rectangles: the reclaimable hatch has to be
/// clipped to a sub-rectangle of each segment and drawn with a stroke pattern, which is
/// a dozen views and two mask layers in SwiftUI primitives and about fifteen lines here.
struct TrackCStackedBar: View {

    let segments: [TrackCDiskSegment]
    var highlighted: TrackCDiskCategory?

    /// Corner radius of the whole bar. The bar is clipped to this, so segments never
    /// need rounding of their own.
    private let radius: CGFloat = 9

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
                let fill = segment.category.color.opacity(dimmed ? 0.34 : 1)
                context.fill(Path(rect), with: .color(fill))

                // The reclaimable share sits at the tail of its own segment, so the eye
                // reads "this much of *this* is garbage" rather than having to compare
                // against a separate bar.
                if segment.reclaimableBytes > 0, segment.bytes > 0 {
                    let share = min(1, Double(segment.reclaimableBytes) / Double(segment.bytes))
                    let hatchWidth = width * CGFloat(share)
                    if hatchWidth > 0.5 {
                        let hatchRect = CGRect(
                            x: rect.maxX - hatchWidth, y: 0, width: hatchWidth, height: size.height)
                        drawHatch(in: hatchRect, context: &context, dimmed: dimmed)
                    }
                }

                // A hairline between neighbours, so two similar colours never merge.
                if x < size.width {
                    context.fill(
                        Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)),
                        with: .color(.black.opacity(0.16)))
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        }
        .accessibilityElement()
        .accessibilityLabel("Disk usage by category")
        .accessibilityValue(
            segments
                .filter { $0.bytes > 0 }
                .map { "\($0.category.title) \(Formatters.bytesString($0.bytes))" }
                .joined(separator: ", "))
    }

    /// Diagonal 45° hatching, the conventional "this is slack" texture.
    ///
    /// Drawn in its own layer so the clip does not leak into the next segment, and in
    /// white-over-black pairs so it stays visible on both the light and the dark end of
    /// every segment colour.
    private func drawHatch(in rect: CGRect, context: inout GraphicsContext, dimmed: Bool) {
        context.drawLayer { layer in
            layer.clip(to: Path(rect))
            let spacing: CGFloat = 7
            let alpha = dimmed ? 0.16 : 0.42
            var offset = rect.minX - rect.height
            while offset < rect.maxX {
                var stripe = Path()
                stripe.move(to: CGPoint(x: offset, y: rect.maxY))
                stripe.addLine(to: CGPoint(x: offset + rect.height, y: rect.minY))
                layer.stroke(stripe, with: .color(.white.opacity(alpha)), lineWidth: 1.6)
                offset += spacing
            }
        }
    }
}

/// A tiny hatched square, so the legend's word "reclaimable" is tied to the texture in
/// the bar rather than left to be guessed at.
struct TrackCHatchSwatch: View {
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(
                Path(roundedRect: rect, cornerRadius: 2.5, style: .continuous),
                with: .color(.secondary.opacity(0.35)))
            context.drawLayer { layer in
                layer.clip(to: Path(roundedRect: rect, cornerRadius: 2.5, style: .continuous))
                var offset = -size.height
                while offset < size.width {
                    var stripe = Path()
                    stripe.move(to: CGPoint(x: offset, y: size.height))
                    stripe.addLine(to: CGPoint(x: offset + size.height, y: 0))
                    layer.stroke(stripe, with: .color(.primary.opacity(0.55)), lineWidth: 1.2)
                    offset += 4
                }
            }
        }
        .frame(width: 12, height: 12)
    }
}

// MARK: - Legend row

private struct TrackCLegendRow: View {

    let segment: TrackCDiskSegment
    let total: Int64
    let isHighlighted: Bool
    let isBusy: Bool
    let onPrune: () -> Void

    private var shareText: String {
        guard total > 0 else { return "0%" }
        return Formatters.percent(segment.fraction(of: total) * 100)
    }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(segment.category.color)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 1) {
                Text(segment.category.title)
                    .font(.callout.weight(.medium))
                HStack(spacing: 4) {
                    Text(shareText)
                        .font(.caption2.monospacedDigit())
                    if segment.reclaimableBytes > 0 {
                        Text("·")
                            .font(.caption2)
                        Text(
                            "\(Formatters.bytesString(segment.reclaimableBytes)) reclaimable"
                            + (segment.isEstimate ? " (approx.)" : ""))
                            .font(.caption2.monospacedDigit())
                    }
                }
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Text(Formatters.bytesString(segment.bytes))
                .font(.callout.monospacedDigit())
                .contentTransition(.numericText())

            Button("Prune", action: onPrune)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isBusy)
                .help(segment.category.pruneSummary)
        }
        .padding(.horizontal, TrackCMetrics.gutter)
        .padding(.vertical, 9)
        .background(isHighlighted ? AnyShapeStyle(.quaternary.opacity(0.4)) : AnyShapeStyle(.clear))
        .contentShape(.rect)
    }
}
