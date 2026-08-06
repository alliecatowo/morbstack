// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import Foundation
import XCTest

@testable import MorbstackAppCore

/// Pure coverage for the stats tab's display contract. Chart rendering itself belongs
/// to the serialized real-window/XCUITest evidence lane; these tests keep the
/// data-to-presentation truth boundaries deterministic and offline.
final class ContainerStatsPresentationTests: XCTestCase {

    func testStoppedContainerNeverPretendsToBeLoadingOrLive() {
        XCTAssertEqual(
            ContainerStatsPresentation.state(
                containerIsRunning: false,
                hasProbe: true,
                isLive: true,
                failure: "stream ended"),
            .containerStopped)
    }

    func testStatisticsSurfaceDistinguishesConnectionWaitingFailureAndReady() {
        XCTAssertEqual(
            ContainerStatsPresentation.state(
                containerIsRunning: true,
                hasProbe: false,
                isLive: false,
                failure: nil),
            .connecting)
        XCTAssertEqual(
            ContainerStatsPresentation.state(
                containerIsRunning: true,
                hasProbe: true,
                isLive: false,
                failure: nil),
            .waitingForFirstReading)
        XCTAssertEqual(
            ContainerStatsPresentation.state(
                containerIsRunning: true,
                hasProbe: true,
                isLive: false,
                failure: "connection reset"),
            .streamFailed("connection reset"))
        XCTAssertEqual(
            ContainerStatsPresentation.state(
                containerIsRunning: true,
                hasProbe: true,
                isLive: true,
                failure: nil),
            .ready)
    }

    func testScalarHistoryRequiresTwoRealReadingsBeforeItBecomesATrend() {
        XCTAssertFalse(ContainerStatsPresentation.hasScalarTrend(sampleCount: 0))
        XCTAssertFalse(ContainerStatsPresentation.hasScalarTrend(sampleCount: 1))
        XCTAssertTrue(ContainerStatsPresentation.hasScalarTrend(sampleCount: 2))
    }

    func testRateHistoryRequiresTwoIntervalsInTheSameDirection() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let inbound = ByteRateSample(
            sequence: 1,
            timestamp: start,
            inboundBytesPerSecond: 64,
            outboundBytesPerSecond: nil)
        let outbound = ByteRateSample(
            sequence: 2,
            timestamp: start.addingTimeInterval(2),
            inboundBytesPerSecond: nil,
            outboundBytesPerSecond: 64)
        let inboundAgain = ByteRateSample(
            sequence: 3,
            timestamp: start.addingTimeInterval(4),
            inboundBytesPerSecond: 128,
            outboundBytesPerSecond: nil)

        XCTAssertFalse(ContainerStatsPresentation.hasRateTrend(samples: []))
        XCTAssertFalse(ContainerStatsPresentation.hasRateTrend(samples: [inbound]))
        XCTAssertFalse(
            ContainerStatsPresentation.hasRateTrend(samples: [inbound, outbound]),
            "One receive interval and one send interval are not either direction's trend.")
        XCTAssertTrue(ContainerStatsPresentation.hasRateTrend(samples: [inbound, inboundAgain]))
    }

    func testMetricPickerOffersOnlyTheSupportedHistoryRepresentations() {
        XCTAssertEqual(ContainerStatsMetric.allCases, [.cpu, .memory, .network, .disk])
        XCTAssertEqual(
            ContainerStatsMetric.allCases.map(\.title),
            ["CPU Usage", "Memory Usage", "Network Activity", "Disk Activity"])
    }

    /// The disk empty state is reached by an idle container as well as by an engine
    /// that does not account block I/O, and the stats payload cannot tell those apart.
    /// The copy therefore states the Engine's listing rule — true in both cases — and
    /// must not acquire the word "unavailable", "failed", or a cause it cannot know.
    func testDiskEmptyStateDescribesTheEngineRuleRatherThanADiagnosis() {
        let disk = ByteRateVocabulary.disk
        XCTAssertEqual(disk.emptyTitle, "No Disk Activity Recorded")
        XCTAssertEqual(
            disk.emptyDescription,
            "The Docker Engine lists a block device only after a container reads from or writes to it, and it listed none for this container.")
        XCTAssertFalse(disk.emptyDescription.localizedCaseInsensitiveContains("unavailable"))
        XCTAssertFalse(disk.emptyDescription.localizedCaseInsensitiveContains("error"))
        XCTAssertFalse(disk.emptyDescription.localizedCaseInsensitiveContains("cgroup"))
    }

    /// Every rate surface addresses the same two directions, so the two vocabularies
    /// must stay structurally identical — a metric that forgets one of the four labels
    /// silently renders a blank `LabeledContent` title.
    func testEveryRateMetricNamesBothDirectionsAndBothRates() {
        for vocabulary in [ByteRateVocabulary.network, .disk] {
            XCTAssertFalse(vocabulary.inboundLabel.isEmpty)
            XCTAssertFalse(vocabulary.outboundLabel.isEmpty)
            XCTAssertFalse(vocabulary.inboundRateLabel.isEmpty)
            XCTAssertFalse(vocabulary.outboundRateLabel.isEmpty)
            XCTAssertNotEqual(vocabulary.inboundLabel, vocabulary.outboundLabel)
            XCTAssertEqual(vocabulary.title, vocabulary.metric.title)
        }
        XCTAssertNotEqual(
            ByteRateVocabulary.network.emptyIdentifier,
            ByteRateVocabulary.disk.emptyIdentifier)
    }
}
