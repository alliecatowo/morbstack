// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// STATS: two sparklines and the numbers behind them.
//
// The charts are drawn with `Canvas` rather than assembled from views. Sixty samples
// times two charts is a hundred and twenty shapes, and at that count a `Path` per sample
// costs more in view identity and diffing than the drawing itself ever will. `Canvas`
// hands the whole series to one draw call.
//
// The samples arrive through the same `TrackBStatsHub` the list rows use, so opening
// this tab for a container already visible in the list joins its existing stream instead
// of opening a second one — and the sparkline starts with whatever history the row has
// already collected rather than from an empty chart.

import SwiftUI

struct ContainerStatsTab: View {

    let container: ContainerSummary
    let hub: TrackBStatsHub
    let client: DockerClient

    @State private var probe: TrackBStatsProbe?
    /// The pane's height, fed back so the charts can divide it between them.
    @State private var viewportHeight: CGFloat = 0

    /// Falls back to whatever the hub already knows about this container.
    ///
    /// Two payoffs. In the app, a container whose row has been streaming draws its
    /// sparkline on the very first frame of the tab instead of after `.task` has run.
    /// Offscreen — previews, the screenshot harness — `.task` never runs at all, so a
    /// hub seeded with `TrackBStatsHub.seed(_:samples:)` is the only thing there is.
    private var activeProbe: TrackBStatsProbe? { probe ?? hub.existingProbe(container.id) }

    var body: some View {
        Group {
            if !container.isRunning {
                notRunning
            } else if let probe = activeProbe {
                content(probe: probe)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: container.id) { subscribe() }
        .onDisappear { unsubscribe() }
        .onChange(of: container.isRunning) { _, running in
            if running { subscribe() } else { unsubscribe() }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(probe: TrackBStatsProbe) -> some View {
        ScrollView {
            // The two charts share whatever vertical room is left over instead of
            // sitting at a fixed 64pt each with a third of the pane empty underneath
            // them. A sparkline is one of the few things in the app that is strictly
            // better larger: the same series over twice the height resolves detail that
            // a 64pt strip flattens into a ruled line.
            VStack(alignment: .leading, spacing: 20) {
                if let failure = probe.failure {
                    TrackBInlineError(text: "Stats stream stopped: \(failure)")
                } else if !probe.isLive {
                    waiting
                }

                TrackBChartCard(
                    title: "CPU",
                    symbol: "cpu",
                    reading: Formatters.percent(probe.latest?.cpuPercent ?? 0),
                    caption: cpuCaption(probe),
                    tint: cpuTint(probe.latest?.cpuPercent ?? 0),
                    values: probe.cpuSeries,
                    // A CPU chart pinned to 100% makes a 3% idle container look flat and
                    // a 30% one look identical. The axis grows to fit instead, with a
                    // floor so small numbers do not fill the frame.
                    upperBound: max(10, (probe.cpuSeries.max() ?? 0) * 1.2),
                    axisLabel: { Formatters.percent($0) })
                    .frame(maxHeight: .infinity)

                TrackBChartCard(
                    title: "Memory",
                    symbol: "memorychip",
                    reading: Formatters.bytesString(probe.latest?.memBytes ?? 0),
                    caption: memoryCaption(probe),
                    tint: memoryTint(probe.latest),
                    values: probe.memorySeries,
                    upperBound: memoryUpperBound(probe),
                    axisLabel: { Formatters.bytesString(Int64($0)) })
                    .frame(maxHeight: .infinity)

                if let sample = probe.latest, sample.memLimit > 0 {
                    memoryGauge(sample)
                }

                footnote(probe)
            }
            .padding(18)
            .frame(
                maxWidth: .infinity,
                minHeight: viewportHeight > 0 ? viewportHeight : nil,
                alignment: .topLeading)
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, height in
            if abs(height - viewportHeight) > 0.5 { viewportHeight = height }
        }
    }

    private var waiting: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Waiting for the first sample…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var notRunning: some View {
        TrackBEmptyState(
            symbols: ["waveform.path.ecg"],
            title: "No live statistics",
            message: "The engine only reports CPU and memory for a running container."
        ) {
            EmptyView()
        }
    }

    private func memoryGauge(_ sample: StatsSample) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Of limit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Formatters.memoryString(used: sample.memBytes, limit: sample.memLimit))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(memoryTint(sample).gradient)
                        .frame(width: max(3, geometry.size.width * sample.memFraction))
                }
            }
            .frame(height: 6)
        }
    }

    private func footnote(_ probe: TrackBStatsProbe) -> some View {
        Text(probe.history.count < 2
             ? "Sampled every \(Int(hub.minimumInterval)) seconds."
             : "Last \(probe.history.count) samples, one every \(Int(hub.minimumInterval)) seconds.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    // MARK: - Derived

    private func cpuCaption(_ probe: TrackBStatsProbe) -> String {
        let series = probe.cpuSeries
        guard !series.isEmpty else { return "—" }
        let peak = series.max() ?? 0
        let mean = series.reduce(0, +) / Double(series.count)
        return "avg \(Formatters.percent(mean))  ·  peak \(Formatters.percent(peak))"
    }

    private func memoryCaption(_ probe: TrackBStatsProbe) -> String {
        guard let sample = probe.latest else { return "—" }
        guard sample.memLimit > 0 else { return "no limit set" }
        return "\(Formatters.percent(sample.memFraction * 100)) of "
            + Formatters.bytesString(sample.memLimit)
    }

    /// Warm colours past the point where a container is the reason the fan is on.
    private func cpuTint(_ value: Double) -> Color {
        switch value {
        case ..<60: return Theme.accent
        case ..<85: return .orange
        default: return .red
        }
    }

    private func memoryTint(_ sample: StatsSample?) -> Color {
        guard let sample, sample.memLimit > 0 else { return Theme.seriesTeal }
        switch sample.memFraction {
        case ..<0.75: return Theme.seriesTeal
        case ..<0.92: return .orange
        // Past ninety-something percent of the limit the kernel is about to OOM-kill
        // this container, which is worth shouting about.
        default: return .red
        }
    }

    /// The memory axis tracks the limit when there is a meaningful one, so the curve
    /// reads as "how close to being killed am I" rather than as an abstract shape.
    private func memoryUpperBound(_ probe: TrackBStatsProbe) -> Double {
        let peak = probe.memorySeries.max() ?? 0
        guard let limit = probe.latest?.memLimit, limit > 0 else {
            return max(peak * 1.2, 1024 * 1024)
        }
        let limitValue = Double(limit)
        // A limit orders of magnitude above actual use (the common "limit is the whole
        // VM" case) would flatten the curve to nothing, so it is only used as the axis
        // when the container is actually working within sight of it.
        return peak > limitValue * 0.2 ? limitValue : max(peak * 1.25, 1024 * 1024)
    }

    // MARK: - Subscription

    private func subscribe() {
        guard container.isRunning, probe == nil else { return }
        probe = hub.retain(container.id, client: client)
    }

    private func unsubscribe() {
        guard probe != nil else { return }
        hub.release(container.id)
        probe = nil
    }
}

// MARK: - Chart card

/// A titled sparkline with its current reading.
struct TrackBChartCard: View {

    let title: String
    let symbol: String
    let reading: String
    let caption: String
    let tint: Color
    let values: [Double]
    let upperBound: Double
    let axisLabel: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.4)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(reading)
                    // Monospaced digits are not a nicety here: a proportional font
                    // reflows the whole reading every time a digit changes, and at one
                    // update every two seconds that reads as a twitch.
                    .font(.system(size: 22, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.25), value: reading)
            }

            TrackBSparkline(values: values, upperBound: upperBound, tint: tint)
                .frame(minHeight: 64, maxHeight: .infinity)

            HStack {
                Text(caption)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                // The axis maximum. `.quaternary` put it at roughly 1.8:1 against the
                // card — technically present, practically invisible, which is the worst
                // of both worlds for a label that tells you what the top of the chart
                // means.
                Text(axisLabel(upperBound))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.32),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5))
    }
}

// MARK: - Sparkline

/// A filled line chart over a fixed-width window of samples.
///
/// The series is always plotted against `TrackBStatsProbe.historyLimit` slots rather
/// than against its own count, so a chart that is still filling up grows from the right
/// instead of stretching two points across the whole card and then squashing them as
/// more arrive.
struct TrackBSparkline: View {

    let values: [Double]
    let upperBound: Double
    let tint: Color

    private var slots: Int { TrackBStatsProbe.historyLimit }

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            guard values.count >= 2, upperBound > 0 else {
                drawBaseline(context: context, size: size)
                return
            }

            let step = size.width / CGFloat(max(1, slots - 1))
            // Right-align: the newest sample is always at the right edge.
            let firstIndex = slots - values.count

            func point(_ index: Int) -> CGPoint {
                let clamped = min(max(values[index] / upperBound, 0), 1)
                return CGPoint(
                    x: CGFloat(firstIndex + index) * step,
                    y: size.height - (CGFloat(clamped) * (size.height - 2)) - 1)
            }

            var line = Path()
            line.move(to: point(0))
            for index in 1..<values.count { line.addLine(to: point(index)) }

            var fill = line
            fill.addLine(to: CGPoint(x: point(values.count - 1).x, y: size.height))
            fill.addLine(to: CGPoint(x: point(0).x, y: size.height))
            fill.closeSubpath()

            context.fill(
                fill,
                with: .linearGradient(
                    Gradient(colors: [tint.opacity(0.34), tint.opacity(0.02)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)))

            context.stroke(
                line,
                with: .color(tint),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

            // A dot on the newest sample; the eye needs somewhere to land.
            let head = point(values.count - 1)
            context.fill(
                Path(ellipseIn: CGRect(x: head.x - 2.5, y: head.y - 2.5, width: 5, height: 5)),
                with: .color(tint))
        }
        .drawingGroup()
        .accessibilityLabel("\(values.count) samples")
    }

    private func drawBaseline(context: GraphicsContext, size: CGSize) {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height - 1))
        path.addLine(to: CGPoint(x: size.width, y: size.height - 1))
        context.stroke(
            path,
            with: .color(.secondary.opacity(0.3)),
            style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }
}
