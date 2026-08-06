// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Container statistics are a time-series question — "how has this resource changed
// while the container runs?" — so this is the one place in the inspector where a
// chart is more useful than a table alone.  All other information stays in ordinary
// native controls: `LabeledContent` for the current reading, `Form` for limits, and
// a `Table` as the precise textual alternative to every plotted sample.

import Accessibility
import Charts
import Foundation
import SwiftUI

/// The one statistic a person is currently investigating. These are peer
/// representations of the same Docker stats stream, so a standard picker is clearer
/// than treating three changing charts as equal-weight dashboard furniture.
enum ContainerStatsMetric: String, CaseIterable, Identifiable, Sendable {
    case cpu
    case memory
    case network
    case disk

    var id: Self { self }

    var title: String {
        switch self {
        case .cpu: return "CPU Usage"
        case .memory: return "Memory Usage"
        case .network: return "Network Activity"
        case .disk: return "Disk Activity"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .network: return "network"
        case .disk: return "internaldrive"
        }
    }
}

/// The words one cumulative-counter metric uses.
///
/// Network and disk are the same measurement performed on different counters: two
/// monotonic totals, two derived rates, the same reset and missing-reading discipline.
/// Keeping their copy in one value keeps the two charts from drifting apart, and keeps
/// the difference between them where a reader can see it side by side rather than
/// spread across two near-identical view bodies.
struct ByteRateVocabulary: Sendable {
    let metric: ContainerStatsMetric
    /// Names what the Engine is counting, for the chart's spoken summary.
    let counterNoun: String
    let caption: String
    let inboundLabel: String
    let outboundLabel: String
    let inboundRateLabel: String
    let outboundRateLabel: String
    let totalsFootnote: String
    let emptyTitle: String
    let emptySymbol: String
    let emptyDescription: String
    let emptyIdentifier: String
    let collectingLabel: String
    let sampleTableTitle: String

    var title: String { metric.title }
    var symbol: String { metric.symbol }

    static let network = ByteRateVocabulary(
        metric: .network,
        counterNoun: "interface",
        caption: "Recent receive and send rates derived from Docker interface counters.",
        inboundLabel: "Received",
        outboundLabel: "Sent",
        inboundRateLabel: "Receive Rate",
        outboundRateLabel: "Send Rate",
        totalsFootnote: "Received and sent are cumulative values reported by the Docker Engine.",
        emptyTitle: "Network Statistics Unavailable",
        emptySymbol: "network.slash",
        emptyDescription: "The Docker Engine did not report complete interface counters for this container.",
        emptyIdentifier: "containers.stats.empty.networkUnavailable",
        collectingLabel: "Collecting another complete network reading",
        sampleTableTitle: "Network Rate Samples")

    /// The disk empty state is deliberately *not* worded as a failure. The Engine lists
    /// a block device only once the container has moved bytes over it, so an idle
    /// container produces an empty array through no fault of anything — and a container
    /// on an engine that does not account block I/O produces the same empty array. The
    /// sentence states the mechanism, which is true in both cases, instead of picking a
    /// cause the stats payload cannot distinguish.
    static let disk = ByteRateVocabulary(
        metric: .disk,
        counterNoun: "block-device",
        caption: "Recent read and write rates derived from Docker block-device counters.",
        inboundLabel: "Read",
        outboundLabel: "Written",
        inboundRateLabel: "Read Rate",
        outboundRateLabel: "Write Rate",
        totalsFootnote: "Read and written are cumulative block-device totals reported by the Docker Engine. Reads and writes served from memory never reach a block device and do not appear here.",
        emptyTitle: "No Disk Activity Recorded",
        emptySymbol: "internaldrive",
        emptyDescription: "The Docker Engine lists a block device only after a container reads from or writes to it, and it listed none for this container.",
        emptyIdentifier: "containers.stats.empty.diskUnrecorded",
        collectingLabel: "Collecting another complete disk reading",
        sampleTableTitle: "Disk Rate Samples")
}

/// Pure display decisions for the resource-history surface. Keeping the truth gates out
/// of the view body makes it impossible for a single reading to silently become a
/// trend, or for an ended stream to keep masquerading as a loading state.
enum ContainerStatsPresentation {
    enum State: Equatable, Sendable {
        case containerStopped
        case connecting
        case waitingForFirstReading
        case streamFailed(String)
        case ready
    }

    static func state(
        containerIsRunning: Bool,
        hasProbe: Bool,
        isLive: Bool,
        failure: String?
    ) -> State {
        guard containerIsRunning else { return .containerStopped }
        guard hasProbe else { return .connecting }
        if let failure { return .streamFailed(failure) }
        return isLive ? .ready : .waitingForFirstReading
    }

    static func hasScalarTrend(sampleCount: Int) -> Bool {
        sampleCount >= 2
    }

    /// A rate chart needs two readings *in one direction* before it is a trend. One
    /// receive interval and one send interval are two points on two different series,
    /// and drawing them is drawing a slope that was never measured.
    static func hasRateTrend(samples: [ByteRateSample]) -> Bool {
        let inbound = samples.lazy.filter { $0.inboundBytesPerSecond != nil }.count
        let outbound = samples.lazy.filter { $0.outboundBytesPerSecond != nil }.count
        return inbound >= 2 || outbound >= 2
    }

    /// Tick labels must resolve the window they describe. A 30-second window labelled
    /// at minute resolution prints the same "3:16 PM" at every tick — six identical
    /// labels carry no information. Windows shorter than 2.5 minutes get seconds.
    static func timeAxisFormat(first: Date?, last: Date?) -> Date.FormatStyle {
        guard let first, let last, last.timeIntervalSince(first) >= 150 else {
            return .dateTime.hour().minute().second()
        }
        return .dateTime.hour().minute()
    }
}

struct ContainerStatsTab: View {

    let container: ContainerSummary
    let hub: TrackBStatsHub
    let client: DockerClient

    @State private var probe: TrackBStatsProbe?
    @State private var selectedMetric: ContainerStatsMetric = .cpu

    private var activeProbe: TrackBStatsProbe? {
        probe ?? hub.existingProbe(container.id)
    }

    private var presentationState: ContainerStatsPresentation.State {
        let activeProbe = activeProbe
        return ContainerStatsPresentation.state(
            containerIsRunning: container.isRunning,
            hasProbe: activeProbe != nil,
            isLive: activeProbe?.isLive == true,
            failure: activeProbe?.failure)
    }

    var body: some View {
        Group {
            switch presentationState {
            case .containerStopped:
                ContentUnavailableView {
                    Label("No Live Statistics", systemImage: "waveform.path.ecg")
                } description: {
                    Text("This container is not running. Its resource history is available only while it runs.")
                }
                .accessibilityIdentifier("containers.stats.empty.stopped")
            case .connecting:
                ProgressView("Connecting to statistics")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .waitingForFirstReading:
                ProgressView("Waiting for the first statistic")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .streamFailed(let failure):
                ContentUnavailableView {
                    Label("Statistics Stream Stopped", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Reconnect", action: reconnect)
                        .accessibilityIdentifier("containers.stats.empty.streamFailed.reconnect")
                }
                .accessibilityIdentifier("containers.stats.empty.streamFailed")
            case .ready:
                if let probe = activeProbe {
                    content(probe)
                } else {
                    // The state transition is evaluated on the main actor, but retain a
                    // truthful loading fallback if another observer releases a probe in
                    // the same update cycle.
                    ProgressView("Connecting to statistics")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: container.id) { subscribe() }
        .onDisappear { unsubscribe() }
        .onChange(of: container.isRunning) { _, running in
            if running {
                hub.reset(container.id)
                subscribe()
            } else {
                unsubscribe()
            }
        }
        .onChange(of: container.id) { _, _ in
            // A newly selected container begins on the most broadly useful measure;
            // network availability varies by Engine response and must not surprise a
            // person with a stale picker choice from another record.
            selectedMetric = .cpu
        }
    }

    private func content(_ probe: TrackBStatsProbe) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Picker("Metric", selection: $selectedMetric) {
                    ForEach(ContainerStatsMetric.allCases) { metric in
                        Label(metric.title, systemImage: metric.symbol)
                            .tag(metric)
                    }
                }
                .accessibilityLabel("Resource history metric")
                .accessibilityHint("Selects the Docker resource statistic shown below")
                .accessibilityIdentifier("containers.stats.metric")
                .padding(.bottom, 8)

                selectedMetricContent(probe)

                Text(sampleCadenceDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func selectedMetricContent(_ probe: TrackBStatsProbe) -> some View {
        switch selectedMetric {
        case .cpu:
            let samples = probe.history.enumerated().map { index, sample in
                StatsChartSample(index: index, timestamp: sample.ts, value: sample.cpuPercent)
            }
            StatsChartSection(
                title: ContainerStatsMetric.cpu.title,
                symbol: ContainerStatsMetric.cpu.symbol,
                currentValue: probe.latest.map { Formatters.percent($0.cpuPercent) },
                samples: samples,
                yAxisTitle: "CPU (%)",
                yAxisRange: 0...cpuUpperBound(probe),
                valueLabel: Formatters.percent,
                spokenValueLabel: { "\(Formatters.percent($0)) CPU usage" })

        case .memory:
            let samples = probe.history.enumerated().map { index, sample in
                StatsChartSample(index: index, timestamp: sample.ts, value: Double(sample.memBytes))
            }
            let memoryLimit = probe.latest?.memLimit ?? 0
            StatsChartSection(
                title: ContainerStatsMetric.memory.title,
                symbol: ContainerStatsMetric.memory.symbol,
                currentValue: probe.latest.map { memoryValueLabel(Double($0.memBytes)) },
                samples: samples,
                yAxisTitle: "Memory",
                yAxisRange: 0...memoryUpperBound(probe),
                valueLabel: memoryValueLabel,
                spokenValueLabel: spokenMemoryValueLabel,
                reference: memoryLimit > 0
                    ? StatsChartReference(value: Double(memoryLimit), label: "Memory limit")
                    : nil)

            if let sample = probe.latest, sample.memLimit > 0 {
                Form {
                    Section("Memory Limit") {
                        LabeledContent("In Use") {
                            Text(memoryValueLabel(Double(sample.memBytes)))
                                .monospacedDigit()
                        }
                        LabeledContent("Limit") {
                            Text(memoryValueLabel(Double(sample.memLimit)))
                                .monospacedDigit()
                        }
                        LabeledContent("Percent") {
                            Text(Formatters.percent(sample.memFraction * 100))
                                .monospacedDigit()
                        }
                    }
                }
                .formStyle(.automatic)
                .scrollDisabled(true)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top)
            }

        case .network:
            if let latest = probe.latest {
                ByteRateSection(
                    vocabulary: .network,
                    latestTimestamp: latest.ts,
                    inboundTotal: latest.networkReceivedBytes,
                    outboundTotal: latest.networkTransmittedBytes,
                    samples: probe.networkRates)
            } else {
                ProgressView("Waiting for the first network statistic")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical)
            }

        case .disk:
            if let latest = probe.latest {
                ByteRateSection(
                    vocabulary: .disk,
                    latestTimestamp: latest.ts,
                    inboundTotal: latest.blockReadBytes,
                    outboundTotal: latest.blockWrittenBytes,
                    samples: probe.blockIORates)
            } else {
                ProgressView("Waiting for the first disk statistic")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical)
            }
        }
    }

    /// CPU is a magnitude: a zero baseline makes relative usage legible.  Docker can
    /// report more than 100% when a container uses more than one logical CPU, so this
    /// uses a dynamic, rounded upper bound instead of pretending CPU is capped at 100.
    private func cpuUpperBound(_ probe: TrackBStatsProbe) -> Double {
        roundedUpperBound(max(10, (probe.cpuSeries.max() ?? 0) * 1.2))
    }

    /// Memory scales to the data, not the limit.  A container using 1 MB under a
    /// 256 MB limit must not render as a flat line pinned to the axis — that hides
    /// every real change in the series.  The limit stays on screen as the dashed
    /// reference rule while it is close enough to the data to be legible; when it is
    /// orders of magnitude away, the rule clips out and the Memory Limit form below
    /// carries the exact figure instead.
    private func memoryUpperBound(_ probe: TrackBStatsProbe) -> Double {
        let peak = probe.memorySeries.max() ?? 0
        let dataBound = roundedUpperBound(peak * 1.2, minimum: 1_024 * 1_024)
        if let limit = probe.latest?.memLimit, limit > 0 {
            let limitBound = roundedUpperBound(Double(limit) * 1.05, minimum: 1)
            // Peak above the limit is an anomaly worth keeping visible; a limit
            // within 4x of the data is context worth drawing to scale.
            if Double(limit) <= dataBound * 4 { return max(dataBound, limitBound) }
        }
        return dataBound
    }

    private func roundedUpperBound(_ value: Double, minimum: Double = 10) -> Double {
        let target = max(value, minimum)
        let magnitude = pow(10, floor(log10(target)))
        let normalized = target / magnitude
        let step: Double
        switch normalized {
        case ...1: step = 1
        case ...2: step = 2
        case ...5: step = 5
        default: step = 10
        }
        return step * magnitude
    }

    /// The interval only — how many readings and over what span is already stated once,
    /// directly under the selected chart's own headline (`StatsChartSection.windowDescription`).
    /// Restating the count here duplicated it three sections apart for no reader benefit.
    private var sampleCadenceDescription: String {
        let seconds = Int(hub.minimumInterval)
        return "Statistics update about every \(seconds) second\(seconds == 1 ? "" : "s")."
    }

    private func subscribe() {
        guard container.isRunning, probe == nil else { return }
        probe = hub.retain(container.id, client: client)
    }

    private func unsubscribe() {
        guard probe != nil else { return }
        hub.release(container.id)
        probe = nil
    }

    private func reconnect() {
        hub.reset(container.id)
        unsubscribe()
        subscribe()
    }
}

/// The Engine API gives the app cumulative counters — per interface for the network, per
/// block device for disk — not a ready-made throughput measurement. This section keeps
/// the two facts distinct: totals are shown as reported, while the chart and its table
/// only show rates that can be derived from a pair of complete, monotonic readings.
///
/// One view serves both metrics. The alternative — a second, nearly identical section —
/// is how the reset handling, the axis rounding and the "two readings in one direction"
/// rule end up subtly different between two charts that must mean the same thing.
private struct ByteRateSection: View {
    let vocabulary: ByteRateVocabulary
    /// The timestamp of the newest sample, used to decide whether the newest derived
    /// interval actually describes the reading currently on screen.
    let latestTimestamp: Date
    let inboundTotal: Int64?
    let outboundTotal: Int64?
    let samples: [ByteRateSample]

    private var inboundRates: [Double] { samples.compactMap(\.inboundBytesPerSecond) }
    private var outboundRates: [Double] { samples.compactMap(\.outboundBytesPerSecond) }
    private var hasTrend: Bool { ContainerStatsPresentation.hasRateTrend(samples: samples) }

    private var latestInboundRate: Double? {
        guard samples.last?.timestamp == latestTimestamp else { return nil }
        return samples.last?.inboundBytesPerSecond
    }

    private var latestOutboundRate: Double? {
        guard samples.last?.timestamp == latestTimestamp else { return nil }
        return samples.last?.outboundBytesPerSecond
    }

    private var yAxisRange: ClosedRange<Double> {
        let peak = (inboundRates + outboundRates).max() ?? 0
        return 0...roundedUpperBound(max(1_024, peak * 1.2))
    }

    private var chartSummary: String {
        let intervalDescription = samples.count == 1 ? "1 interval" : "\(samples.count) intervals"
        return "\(intervalDescription) calculated from Docker's cumulative \(vocabulary.counterNoun) counters. "
            + "Current \(vocabulary.inboundRateLabel.lowercased()) is \(spokenByteRateLabel(latestInboundRate)). "
            + "Current \(vocabulary.outboundRateLabel.lowercased()) is \(spokenByteRateLabel(latestOutboundRate))."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Label(vocabulary.title, systemImage: vocabulary.symbol)
                    .font(.headline)
                    .accessibilityHeading(.h2)
                Text(vocabulary.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let inboundTotal, let outboundTotal {
                LabeledContent(vocabulary.inboundLabel) {
                    Text(Formatters.bytesString(inboundTotal))
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
                LabeledContent(vocabulary.outboundLabel) {
                    Text(Formatters.bytesString(outboundTotal))
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
                LabeledContent(vocabulary.inboundRateLabel) {
                    Text(byteRateLabel(latestInboundRate))
                        .monospacedDigit()
                }
                LabeledContent(vocabulary.outboundRateLabel) {
                    Text(byteRateLabel(latestOutboundRate))
                        .monospacedDigit()
                }

                Text(vocabulary.totalsFootnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if hasTrend {
                    Chart {
                        ForEach(samples) { sample in
                            if let inbound = sample.inboundBytesPerSecond {
                                PointMark(
                                    x: .value("Time", sample.timestamp),
                                    y: .value("Throughput", inbound))
                                    .foregroundStyle(by: .value("Direction", vocabulary.inboundLabel))
                            }
                            if let outbound = sample.outboundBytesPerSecond {
                                PointMark(
                                    x: .value("Time", sample.timestamp),
                                    y: .value("Throughput", outbound))
                                    .foregroundStyle(by: .value("Direction", vocabulary.outboundLabel))
                            }
                        }
                    }
                    .chartXScale(domain: samples.first!.timestamp...samples.last!.timestamp)
                    .chartYScale(domain: yAxisRange)
                    .chartLegend(position: .bottom)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel(format: ContainerStatsPresentation.timeAxisFormat(
                                first: samples.first?.timestamp, last: samples.last?.timestamp))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel {
                                if let number = value.as(Double.self) {
                                    Text(byteRateLabel(number))
                                }
                            }
                        }
                    }
                    .frame(height: 180)
                    // Each mark is one exact interval derived from the Engine counters.
                    // Points deliberately do not connect across an omitted reset/missing
                    // interval. The category colour and legend distinguish the two
                    // directions, rather than supplying dashboard decoration.
                    .accessibilityChartDescriptor(
                        ByteRateChartDescriptor(
                            vocabulary: vocabulary,
                            samples: samples,
                            yAxisRange: yAxisRange,
                            summary: chartSummary))
                } else {
                    ProgressView(vocabulary.collectingLabel)
                        .controlSize(.small)
                }

                if !samples.isEmpty {
                    DisclosureGroup(vocabulary.sampleTableTitle) {
                        Table(samples) {
                            TableColumn("Time") { sample in
                                Text(sample.timestamp, format: .dateTime.hour().minute().second())
                                    .monospacedDigit()
                            }
                            TableColumn(vocabulary.inboundLabel) { sample in
                                Text(byteRateLabel(sample.inboundBytesPerSecond))
                                    .monospacedDigit()
                            }
                            TableColumn(vocabulary.outboundLabel) { sample in
                                Text(byteRateLabel(sample.outboundBytesPerSecond))
                                    .monospacedDigit()
                            }
                        }
                        .frame(height: min(max(CGFloat(samples.count) * 24 + 28, 96), 220))
                        .accessibilityLabel("\(vocabulary.title) sample values")
                    }
                }
            } else {
                ContentUnavailableView {
                    Label(vocabulary.emptyTitle, systemImage: vocabulary.emptySymbol)
                } description: {
                    Text(vocabulary.emptyDescription)
                }
                .accessibilityIdentifier(vocabulary.emptyIdentifier)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func roundedUpperBound(_ value: Double) -> Double {
        let magnitude = pow(10, floor(log10(value)))
        let normalized = value / magnitude
        let step: Double
        switch normalized {
        case ...1: step = 1
        case ...2: step = 2
        case ...5: step = 5
        default: step = 10
        }
        return step * magnitude
    }
}

/// A two-series Audio Graph and VoiceOver representation of the exact rate samples in
/// `ByteRateSection`. It gives the category colours a textual meaning too.
private struct ByteRateChartDescriptor: AXChartDescriptorRepresentable {
    let vocabulary: ByteRateVocabulary
    let samples: [ByteRateSample]
    let yAxisRange: ClosedRange<Double>
    let summary: String

    func makeChartDescriptor() -> AXChartDescriptor {
        let first = samples.first?.timestamp ?? .now
        let last = samples.last?.timestamp ?? first.addingTimeInterval(1)
        let xLowerBound = first.timeIntervalSinceReferenceDate
        let xUpperBound = max(last.timeIntervalSinceReferenceDate, xLowerBound + 1)
        let xAxis = AXNumericDataAxisDescriptor(
            title: "Time",
            range: xLowerBound...xUpperBound,
            gridlinePositions: [],
            valueDescriptionProvider: { value in
                Date(timeIntervalSinceReferenceDate: value)
                    .formatted(.dateTime.hour().minute().second())
            })
        let yAxis = AXNumericDataAxisDescriptor(
            title: "Throughput",
            range: yAxisRange,
            gridlinePositions: [],
            valueDescriptionProvider: { spokenByteRateLabel($0) })

        func makeSeries(
            _ name: String,
            values: (ByteRateSample) -> Double?
        ) -> AXDataSeriesDescriptor? {
            let points = samples.compactMap { sample -> AXDataPoint? in
                guard let value = values(sample) else { return nil }
                return AXDataPoint(
                    x: sample.timestamp.timeIntervalSinceReferenceDate,
                    y: value,
                    label: "\(sample.timestamp.formatted(.dateTime.hour().minute().second())): \(spokenByteRateLabel(value))")
            }
            guard !points.isEmpty else { return nil }
            return AXDataSeriesDescriptor(name: name, isContinuous: true, dataPoints: points)
        }

        let chartSeries = [
            makeSeries(vocabulary.inboundLabel, values: \.inboundBytesPerSecond),
            makeSeries(vocabulary.outboundLabel, values: \.outboundBytesPerSecond),
        ].compactMap { $0 }

        let descriptor = AXChartDescriptor(
            title: vocabulary.title,
            summary: summary,
            xAxis: xAxis,
            yAxis: yAxis,
            series: chartSeries)
        descriptor.contentDirection = .leftToRight
        return descriptor
    }
}

private struct StatsChartSample: Identifiable {
    let index: Int
    let timestamp: Date
    let value: Double
    var id: Int { index }
}

private struct StatsChartReference {
    let value: Double
    let label: String
}

private struct StatsChartSection: View {
    let title: String
    let symbol: String
    let currentValue: String?
    let samples: [StatsChartSample]
    let yAxisTitle: String
    let yAxisRange: ClosedRange<Double>
    let valueLabel: (Double) -> String
    let spokenValueLabel: (Double) -> String
    var reference: StatsChartReference?

    private var hasTrend: Bool { ContainerStatsPresentation.hasScalarTrend(sampleCount: samples.count) }

    private var windowDescription: String {
        guard let first = samples.first, let last = samples.last else {
            return "Waiting for enough readings to show a time trend."
        }
        let duration = max(0, Int(last.timestamp.timeIntervalSince(first.timestamp).rounded()))
        return "\(samples.count) reading\(samples.count == 1 ? "" : "s") over \(durationDescription(duration))."
    }

    private var chartSummary: String {
        guard let first = samples.first, let last = samples.last else {
            return "No statistics have arrived yet."
        }
        let minimum = samples.map(\.value).min() ?? 0
        let maximum = samples.map(\.value).max() ?? 0
        return "\(samples.count) reading\(samples.count == 1 ? "" : "s") from \(spokenTimestamp(first.timestamp)) to \(spokenTimestamp(last.timestamp)). "
            + "The current value is \(spokenValueLabel(last.value)). "
            + "Values range from \(spokenValueLabel(minimum)) to \(spokenValueLabel(maximum))."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: symbol)
                    .font(.headline)
                    .accessibilityHeading(.h2)
                Text(windowDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Current") {
                Text(currentValue ?? "—")
                    .monospacedDigit()
                    .textSelection(.enabled)
            }

            if hasTrend {
                // There is a single, explicitly named series, so a legend would only
                // repeat the title.  Position encodes the data; colour carries no
                // additional meaning and relies on the system chart appearance.
                Chart {
                    ForEach(samples) { sample in
                        LineMark(
                            x: .value("Time", sample.timestamp),
                            y: .value(yAxisTitle, sample.value))
                            .interpolationMethod(.linear)
                    }

                    if let reference {
                        RuleMark(y: .value(reference.label, reference.value))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(.secondary)
                            // Inside the plot area: a trailing annotation renders
                            // beyond the right edge and gets clipped to "Me…" at
                            // inspector widths.
                            .annotation(position: .top, alignment: .leading) {
                                Text(reference.label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .chartLegend(.hidden)
                .chartXScale(domain: samples.first!.timestamp...samples.last!.timestamp)
                .chartYScale(domain: yAxisRange)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(format: ContainerStatsPresentation.timeAxisFormat(
                            first: samples.first?.timestamp, last: samples.last?.timestamp))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(valueLabel(number))
                            }
                        }
                    }
                }
                .frame(height: 180)
                // Swift Charts supplies default accessible elements for its marks.
                // This descriptor adds the chart's purpose, a factual summary, axes,
                // and one precisely labeled data point per real Docker sample for
                // Audio Graphs and VoiceOver exploration.
                .accessibilityChartDescriptor(
                    StatsChartAccessibilityDescriptor(
                        title: title,
                        summary: chartSummary,
                        samples: samples,
                        yAxisTitle: yAxisTitle,
                        yAxisRange: yAxisRange,
                        spokenValueLabel: spokenValueLabel))
            } else {
                ProgressView("Collecting another reading")
                    .controlSize(.small)
            }

            if !samples.isEmpty {
                DisclosureGroup("Sample Values") {
                    // This is not a hand-built data card: it is the same system Table
                    // used elsewhere for operational data.  It preserves exact values
                    // for sighted, keyboard, and assistive-technology users alike.
                    Table(samples) {
                        TableColumn("Time") { sample in
                            Text(sample.timestamp, format: .dateTime.hour().minute().second())
                                .monospacedDigit()
                        }
                        TableColumn(yAxisTitle) { sample in
                            Text(valueLabel(sample.value))
                                .monospacedDigit()
                        }
                    }
                    .frame(height: min(max(CGFloat(samples.count) * 24 + 28, 96), 220))
                    .accessibilityLabel("\(title) sample values")
                }
            }
        }
        .padding(.vertical)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func durationDescription(_ seconds: Int) -> String {
        switch seconds {
        case 0...1:
            return "1 second"
        case ..<60:
            return "\(seconds) seconds"
        case ..<120:
            return "1 minute"
        default:
            return "\(seconds / 60) minutes"
        }
    }

    private func spokenTimestamp(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().second())
    }
}

/// A SwiftUI bridge to the Accessibility framework's chart descriptor.  Swift Charts
/// already exposes its marks, while this object gives VoiceOver an Audio Graph with
/// explicitly named units and a neutral, data-derived summary.
private struct StatsChartAccessibilityDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let summary: String
    let samples: [StatsChartSample]
    let yAxisTitle: String
    let yAxisRange: ClosedRange<Double>
    let spokenValueLabel: (Double) -> String

    func makeChartDescriptor() -> AXChartDescriptor {
        let first = samples.first?.timestamp ?? .now
        let last = samples.last?.timestamp ?? first.addingTimeInterval(1)
        let xLowerBound = first.timeIntervalSinceReferenceDate
        let xUpperBound = max(last.timeIntervalSinceReferenceDate, xLowerBound + 1)

        let xAxis = AXNumericDataAxisDescriptor(
            title: "Time",
            range: xLowerBound...xUpperBound,
            gridlinePositions: [],
            valueDescriptionProvider: { value in
                Date(timeIntervalSinceReferenceDate: value)
                    .formatted(.dateTime.hour().minute().second())
            })
        let yAxis = AXNumericDataAxisDescriptor(
            title: yAxisTitle,
            range: yAxisRange,
            gridlinePositions: [],
            valueDescriptionProvider: spokenValueLabel)
        let points = samples.map { sample in
            AXDataPoint(
                x: sample.timestamp.timeIntervalSinceReferenceDate,
                y: sample.value,
                label: "\(sample.timestamp.formatted(.dateTime.hour().minute().second())): \(spokenValueLabel(sample.value))")
        }
        let series = AXDataSeriesDescriptor(name: title, isContinuous: true, dataPoints: points)

        let descriptor = AXChartDescriptor(
            title: title,
            summary: summary,
            xAxis: xAxis,
            yAxis: yAxis,
            series: [series])
        descriptor.contentDirection = .leftToRight
        return descriptor
    }
}

private func memoryValueLabel(_ value: Double) -> String {
    Formatters.bytesString(Int64(value.rounded()))
}

private func spokenMemoryValueLabel(_ value: Double) -> String {
    let bytes = Int64(value.rounded())
    return "\(Formatters.bytesString(bytes)), \(bytes.formatted()) bytes"
}

/// An em dash for an interval the Engine gave no usable pair of counters for. A rate of
/// zero is a measurement; a missing rate is not, and the two must not print the same.
private func byteRateLabel(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "—" }
    return Formatters.byteRateString(value)
}

private func spokenByteRateLabel(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "unavailable" }
    return "\(Formatters.bytesString(Formatters.clampedByteCount(value))) per second"
}
