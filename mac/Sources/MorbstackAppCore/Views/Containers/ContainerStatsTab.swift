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

    var id: Self { self }

    var title: String {
        switch self {
        case .cpu: return "CPU Usage"
        case .memory: return "Memory Usage"
        case .network: return "Network Activity"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .network: return "network"
        }
    }
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

    static func hasNetworkTrend(samples: [NetworkRateSample]) -> Bool {
        let receivedCount = samples.lazy.filter { $0.receivedBytesPerSecond != nil }.count
        let transmittedCount = samples.lazy.filter { $0.transmittedBytesPerSecond != nil }.count
        return receivedCount >= 2 || transmittedCount >= 2
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
                }
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
                .padding(.bottom, 8)

                selectedMetricContent(probe)

                Text(sampleCadenceDescription(probe))
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
                NetworkActivitySection(
                    latest: latest,
                    samples: probe.networkRates)
            } else {
                ProgressView("Waiting for the first network statistic")
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

    /// A memory limit is semantically meaningful, so it anchors the scale whenever
    /// Docker reports one.  The scale expands only if Docker reports usage above its
    /// own limit, keeping the anomalous reading visible rather than clipping it.
    private func memoryUpperBound(_ probe: TrackBStatsProbe) -> Double {
        let peak = probe.memorySeries.max() ?? 0
        if let limit = probe.latest?.memLimit, limit > 0 {
            return max(Double(limit), roundedUpperBound(peak * 1.1, minimum: 1))
        }
        return roundedUpperBound(peak * 1.2, minimum: 1_024 * 1_024)
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

    private func sampleCadenceDescription(_ probe: TrackBStatsProbe) -> String {
        let seconds = Int(hub.minimumInterval)
        if probe.history.count < 2 {
            return "Statistics update about every \(seconds) seconds."
        }
        return "Showing \(probe.history.count) readings, sampled about every \(seconds) seconds."
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

/// The Engine API gives the app cumulative counters for every container interface, not
/// a ready-made throughput measurement. This section keeps the two facts distinct:
/// totals are shown as reported, while the chart and its table only show rates that can
/// be derived from a pair of complete, monotonic readings.
private struct NetworkActivitySection: View {
    let latest: StatsSample
    let samples: [NetworkRateSample]

    private var receivedRates: [Double] { samples.compactMap(\.receivedBytesPerSecond) }
    private var transmittedRates: [Double] { samples.compactMap(\.transmittedBytesPerSecond) }
    private var hasTrend: Bool { ContainerStatsPresentation.hasNetworkTrend(samples: samples) }

    private var latestReceivedRate: Double? {
        guard samples.last?.timestamp == latest.ts else { return nil }
        return samples.last?.receivedBytesPerSecond
    }

    private var latestTransmittedRate: Double? {
        guard samples.last?.timestamp == latest.ts else { return nil }
        return samples.last?.transmittedBytesPerSecond
    }

    private var yAxisRange: ClosedRange<Double> {
        let peak = (receivedRates + transmittedRates).max() ?? 0
        return 0...roundedUpperBound(max(1_024, peak * 1.2))
    }

    private var chartSummary: String {
        let intervalDescription = samples.count == 1 ? "1 interval" : "\(samples.count) intervals"
        return "\(intervalDescription) calculated from Docker's cumulative interface counters. "
            + "Current receive rate is \(spokenNetworkRateLabel(latestReceivedRate)). "
            + "Current send rate is \(spokenNetworkRateLabel(latestTransmittedRate))."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Network Activity", systemImage: "network")
                    .font(.headline)
                    .accessibilityHeading(.h2)
                Text("Recent receive and send rates derived from Docker interface counters.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let received = latest.networkReceivedBytes,
               let transmitted = latest.networkTransmittedBytes
            {
                LabeledContent("Received") {
                    Text(Formatters.bytesString(received))
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
                LabeledContent("Sent") {
                    Text(Formatters.bytesString(transmitted))
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
                LabeledContent("Receive Rate") {
                    Text(networkRateLabel(latestReceivedRate))
                        .monospacedDigit()
                }
                LabeledContent("Send Rate") {
                    Text(networkRateLabel(latestTransmittedRate))
                        .monospacedDigit()
                }

                Text("Received and sent are cumulative values reported by the Docker Engine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if hasTrend {
                    Chart {
                        ForEach(samples) { sample in
                            if let received = sample.receivedBytesPerSecond {
                                PointMark(
                                    x: .value("Time", sample.timestamp),
                                    y: .value("Throughput", received))
                                    .foregroundStyle(by: .value("Direction", "Received"))
                            }
                            if let transmitted = sample.transmittedBytesPerSecond {
                                PointMark(
                                    x: .value("Time", sample.timestamp),
                                    y: .value("Throughput", transmitted))
                                    .foregroundStyle(by: .value("Direction", "Sent"))
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
                            AxisValueLabel(format: .dateTime.hour().minute())
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel {
                                if let number = value.as(Double.self) {
                                    Text(networkRateLabel(number))
                                }
                            }
                        }
                    }
                    .frame(height: 180)
                    // Each mark is one exact interval derived from the Engine counters.
                    // Points deliberately do not connect across an omitted reset/missing
                    // interval. The category colour and legend distinguish receive from
                    // send, rather than supplying dashboard decoration.
                    .accessibilityChartDescriptor(
                        NetworkActivityChartDescriptor(
                            samples: samples,
                            yAxisRange: yAxisRange,
                            summary: chartSummary))
                } else {
                    ProgressView("Collecting another complete network reading")
                        .controlSize(.small)
                }

                if !samples.isEmpty {
                    DisclosureGroup("Network Rate Samples") {
                        Table(samples) {
                            TableColumn("Time") { sample in
                                Text(sample.timestamp, format: .dateTime.hour().minute().second())
                                    .monospacedDigit()
                            }
                            TableColumn("Received") { sample in
                                Text(networkRateLabel(sample.receivedBytesPerSecond))
                                    .monospacedDigit()
                            }
                            TableColumn("Sent") { sample in
                                Text(networkRateLabel(sample.transmittedBytesPerSecond))
                                    .monospacedDigit()
                            }
                        }
                        .frame(height: min(max(CGFloat(samples.count) * 24 + 28, 96), 220))
                        .accessibilityLabel("Network activity sample values")
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Network Statistics Unavailable", systemImage: "network.slash")
                } description: {
                    Text("The Docker Engine did not report complete interface counters for this container.")
                }
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
/// `NetworkActivitySection`. It gives the category colours a textual meaning too.
private struct NetworkActivityChartDescriptor: AXChartDescriptorRepresentable {
    let samples: [NetworkRateSample]
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
            valueDescriptionProvider: { spokenNetworkRateLabel($0) })

        func makeSeries(
            _ name: String,
            values: (NetworkRateSample) -> Double?
        ) -> AXDataSeriesDescriptor? {
            let points = samples.compactMap { sample -> AXDataPoint? in
                guard let value = values(sample) else { return nil }
                return AXDataPoint(
                    x: sample.timestamp.timeIntervalSinceReferenceDate,
                    y: value,
                    label: "\(sample.timestamp.formatted(.dateTime.hour().minute().second())): \(spokenNetworkRateLabel(value))")
            }
            guard !points.isEmpty else { return nil }
            return AXDataSeriesDescriptor(name: name, isContinuous: true, dataPoints: points)
        }

        let chartSeries = [
            makeSeries("Received", values: \.receivedBytesPerSecond),
            makeSeries("Sent", values: \.transmittedBytesPerSecond),
        ].compactMap { $0 }

        let descriptor = AXChartDescriptor(
            title: "Network Activity",
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
        return "\(samples.count) readings over \(durationDescription(duration))."
    }

    private var chartSummary: String {
        guard let first = samples.first, let last = samples.last else {
            return "No statistics have arrived yet."
        }
        let minimum = samples.map(\.value).min() ?? 0
        let maximum = samples.map(\.value).max() ?? 0
        return "\(samples.count) readings from \(spokenTimestamp(first.timestamp)) to \(spokenTimestamp(last.timestamp)). "
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
                            .annotation(position: .trailing, alignment: .bottom) {
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
                        AxisValueLabel(format: .dateTime.hour().minute())
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

private func networkRateLabel(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "—" }
    return "\(Formatters.bytesString(Int64(value.rounded())))/s"
}

private func spokenNetworkRateLabel(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "unavailable" }
    return "\(Formatters.bytesString(Int64(value.rounded()))) per second"
}
