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

    func testNetworkHistoryRequiresTwoIntervalsInTheSameDirection() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let received = NetworkRateSample(
            sequence: 1,
            timestamp: start,
            receivedBytesPerSecond: 64,
            transmittedBytesPerSecond: nil)
        let sent = NetworkRateSample(
            sequence: 2,
            timestamp: start.addingTimeInterval(2),
            receivedBytesPerSecond: nil,
            transmittedBytesPerSecond: 64)
        let receivedAgain = NetworkRateSample(
            sequence: 3,
            timestamp: start.addingTimeInterval(4),
            receivedBytesPerSecond: 128,
            transmittedBytesPerSecond: nil)

        XCTAssertFalse(ContainerStatsPresentation.hasNetworkTrend(samples: []))
        XCTAssertFalse(ContainerStatsPresentation.hasNetworkTrend(samples: [received]))
        XCTAssertFalse(
            ContainerStatsPresentation.hasNetworkTrend(samples: [received, sent]),
            "One receive interval and one send interval are not either direction's trend.")
        XCTAssertTrue(ContainerStatsPresentation.hasNetworkTrend(samples: [received, receivedAgain]))
    }

    func testMetricPickerOffersOnlyTheSupportedHistoryRepresentations() {
        XCTAssertEqual(ContainerStatsMetric.allCases, [.cpu, .memory, .network])
        XCTAssertEqual(
            ContainerStatsMetric.allCases.map(\.title),
            ["CPU Usage", "Memory Usage", "Network Activity"])
    }
}
