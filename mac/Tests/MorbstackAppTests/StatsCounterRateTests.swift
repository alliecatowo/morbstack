// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Network and block-I/O accounting: the counters, and the rates derived from them.
//
// Docker reports both as **cumulative totals since the container started**, never as
// throughput. Charting a total as a rate produces a line that rises forever and looks
// entirely plausible, which is the worst failure mode available here — so the decode
// step and the delta step each get their own coverage, driven by the JSON shape a real
// dockerd sends rather than by hand-built model values.
//
// The `blkio_stats` payloads below are the cgroup v2 shape: dockerd's `statsV2` fills
// `io_service_bytes_recursive` from the kernel's `io.stat` (`rbytes` → `read`,
// `wbytes` → `write`) and leaves every other array null. The cgroup v1 payload is
// included too, because v1 adds `Sync`, `Async`, `Discard` and `Total` rows per device
// and capitalizes its operations — an engine we do not run today, but the array shape
// this app must never sum blindly.

import Foundation
import XCTest

@testable import MorbstackAppCore

// MARK: - Decoding the counters

final class StatsCounterDecodeTests: XCTestCase {

    private func decode(_ json: String) throws -> Wire.Stats {
        try JSONDecoder().decode(Wire.Stats.self, from: Data(json.utf8))
    }

    // MARK: Network

    /// A container attached to two Docker networks. Docker reports one entry per
    /// interface and never a total, so the sum is the app's job.
    func testSumsEveryInterfaceTheEngineReports() throws {
        let stats = try decode("""
            {"networks":{
               "eth0":{"rx_bytes":1000,"rx_packets":9,"rx_errors":0,"rx_dropped":0,
                       "tx_bytes":200,"tx_packets":4,"tx_errors":0,"tx_dropped":0},
               "eth1":{"rx_bytes":250,"rx_packets":2,"rx_errors":0,"rx_dropped":0,
                       "tx_bytes":50,"tx_packets":1,"tx_errors":0,"tx_dropped":0}}}
            """)

        let totals = StatsMath.networkTotals(stats)
        XCTAssertEqual(totals.received, 1_250)
        XCTAssertEqual(totals.transmitted, 250)
    }

    /// `--network none` and host networking both produce a document with no `networks`
    /// key at all. That is "the Engine did not say", not "nothing moved", and the two
    /// must not collapse into the same zero.
    func testAMissingNetworksKeyIsUnreportedRatherThanZero() throws {
        let stats = try decode("""
            {"read":"2026-08-05T09:00:01.100000000Z","memory_stats":{"usage":1024}}
            """)

        let totals = StatsMath.networkTotals(stats)
        XCTAssertNil(totals.received)
        XCTAssertNil(totals.transmitted)
    }

    /// And an interface that has genuinely carried nothing reports zero, which is a
    /// measurement and must survive as one.
    func testAnIdleInterfaceReportsZeroRatherThanNothing() throws {
        let stats = try decode("""
            {"networks":{"eth0":{"rx_bytes":0,"tx_bytes":0}}}
            """)

        let totals = StatsMath.networkTotals(stats)
        XCTAssertEqual(totals.received, 0)
        XCTAssertEqual(totals.transmitted, 0)
    }

    /// An empty dictionary is the same absence as a missing key.
    func testAnEmptyNetworksDictionaryIsUnreported() throws {
        let stats = try decode(#"{"networks":{}}"#)
        XCTAssertNil(StatsMath.networkTotals(stats).received)
    }

    // MARK: Block I/O

    /// The cgroup v2 shape, which is what every Morbstack guest produces: one `read`
    /// and one `write` row per device, every other array null.
    func testSumsBlockCountersAcrossEveryDevice() throws {
        let stats = try decode("""
            {"blkio_stats":{
               "io_service_bytes_recursive":[
                 {"major":254,"minor":0,"op":"read","value":12288},
                 {"major":254,"minor":0,"op":"write","value":4096},
                 {"major":254,"minor":16,"op":"read","value":8192},
                 {"major":254,"minor":16,"op":"write","value":1024}],
               "io_serviced_recursive":null,"io_queue_recursive":null,
               "io_service_time_recursive":null,"io_wait_time_recursive":null,
               "io_merged_recursive":null,"io_time_recursive":null,
               "sectors_recursive":null}}
            """)

        let totals = StatsMath.blockIOTotals(stats)
        XCTAssertEqual(totals.read, 20_480)
        XCTAssertEqual(totals.written, 5_120)
    }

    /// **The double-counting trap.** cgroup v1 emits `Read`, `Write`, `Sync`, `Async`,
    /// `Discard` *and* `Total` per device. Summing the array reports 6 KB of reads as
    /// 12 KB or more; only the two operations that name a direction may be counted, and
    /// the comparison has to survive v1's capitalization.
    func testIgnoresTheOperationsThatWouldDoubleCountTheSameBytes() throws {
        let stats = try decode("""
            {"blkio_stats":{"io_service_bytes_recursive":[
               {"major":8,"minor":0,"op":"Read","value":6144},
               {"major":8,"minor":0,"op":"Write","value":2048},
               {"major":8,"minor":0,"op":"Sync","value":6144},
               {"major":8,"minor":0,"op":"Async","value":2048},
               {"major":8,"minor":0,"op":"Discard","value":0},
               {"major":8,"minor":0,"op":"Total","value":8192}]}}
            """)

        let totals = StatsMath.blockIOTotals(stats)
        XCTAssertEqual(totals.read, 6_144, "Sync/Async/Total restate the same bytes.")
        XCTAssertEqual(totals.written, 2_048)
    }

    /// `blkio_stats` present but the array null — the literal payload dockerd sends for
    /// a cgroup whose `io.stat` is empty.
    func testANullBlockArrayIsUnrecordedRatherThanZero() throws {
        let stats = try decode("""
            {"blkio_stats":{"io_service_bytes_recursive":null,"io_serviced_recursive":null}}
            """)

        let totals = StatsMath.blockIOTotals(stats)
        XCTAssertNil(totals.read)
        XCTAssertNil(totals.written)
    }

    /// An explicitly empty array, and no `blkio_stats` at all, must agree with it.
    func testAnEmptyOrAbsentBlockSectionIsUnrecorded() throws {
        for json in [#"{"blkio_stats":{"io_service_bytes_recursive":[]}}"#, "{}"] {
            let totals = StatsMath.blockIOTotals(try decode(json))
            XCTAssertNil(totals.read, json)
            XCTAssertNil(totals.written, json)
        }
    }

    /// A device that has been read from but never written to. The write direction has
    /// no row, so it has no total — reporting zero would claim a measurement nobody made.
    func testADirectionWithNoRowsHasNoTotal() throws {
        let stats = try decode("""
            {"blkio_stats":{"io_service_bytes_recursive":[
               {"major":254,"minor":0,"op":"read","value":4096}]}}
            """)

        let totals = StatsMath.blockIOTotals(stats)
        XCTAssertEqual(totals.read, 4_096)
        XCTAssertNil(totals.written)
    }

    /// A device listed with zero bytes *has* been measured. This is the case that must
    /// not render like the empty array above.
    func testAListedDeviceWithZeroBytesIsAMeasurementOfZero() throws {
        let stats = try decode("""
            {"blkio_stats":{"io_service_bytes_recursive":[
               {"major":254,"minor":0,"op":"read","value":0},
               {"major":254,"minor":0,"op":"write","value":0}]}}
            """)

        let totals = StatsMath.blockIOTotals(stats)
        XCTAssertEqual(totals.read, 0)
        XCTAssertEqual(totals.written, 0)
    }

    /// Docker's counters are `uint64` on the wire. Anything that arrives negative after
    /// decoding is corrupt, and half a corrupt total is worse than no total.
    func testACorruptCounterDiscardsTheWholeReading() throws {
        let stats = try decode("""
            {"blkio_stats":{"io_service_bytes_recursive":[
               {"major":254,"minor":0,"op":"read","value":4096},
               {"major":254,"minor":0,"op":"write","value":-1}]}}
            """)

        let totals = StatsMath.blockIOTotals(stats)
        XCTAssertNil(totals.read)
        XCTAssertNil(totals.written)
    }

    func testSummingCannotOverflowIntoANegativeTotal() throws {
        let stats = try decode("""
            {"blkio_stats":{"io_service_bytes_recursive":[
               {"major":254,"minor":0,"op":"read","value":9223372036854775807},
               {"major":254,"minor":16,"op":"read","value":9223372036854775807}]}}
            """)

        XCTAssertNil(StatsMath.blockIOTotals(stats).read)
    }

    /// The whole document, end to end: a real second-in-stream payload carries all four
    /// counter families and one `StatsSample` has to come out with every one of them.
    func testAFullStatsDocumentPopulatesEveryCounterOnTheSample() throws {
        let stats = try decode("""
            {"read":"2026-08-05T09:00:01.100000000Z",
             "cpu_stats":{"cpu_usage":{"total_usage":12250000000},
                          "system_cpu_usage":4004000000000,"online_cpus":4},
             "precpu_stats":{"cpu_usage":{"total_usage":12000000000},
                             "system_cpu_usage":4000000000000,"online_cpus":4},
             "memory_stats":{"usage":53477376,"limit":2147483648,
                             "stats":{"inactive_file":2428800}},
             "blkio_stats":{"io_service_bytes_recursive":[
                {"major":254,"minor":0,"op":"read","value":73728},
                {"major":254,"minor":0,"op":"write","value":24576}]},
             "networks":{"eth0":{"rx_bytes":8192,"tx_bytes":2048}}}
            """)

        let sample = StatsMath.sample(stats)
        XCTAssertEqual(sample.cpuPercent, 25, accuracy: 0.001)
        XCTAssertEqual(sample.memBytes, 53_477_376 - 2_428_800)
        XCTAssertEqual(sample.networkReceivedBytes, 8_192)
        XCTAssertEqual(sample.networkTransmittedBytes, 2_048)
        XCTAssertEqual(sample.blockReadBytes, 73_728)
        XCTAssertEqual(sample.blockWrittenBytes, 24_576)
    }
}

// MARK: - Deriving rates from the counters

final class ByteRateDerivationTests: XCTestCase {

    private let origin = Date(timeIntervalSinceReferenceDate: 800_000)

    /// A sample at `second`, carrying the four cumulative totals the Engine would have
    /// reported at that instant.
    private func sample(
        second: TimeInterval,
        received: Int64? = nil,
        transmitted: Int64? = nil,
        read: Int64? = nil,
        written: Int64? = nil
    ) -> StatsSample {
        StatsSample(
            cpuPercent: 0,
            memBytes: 0,
            memLimit: 0,
            networkReceivedBytes: received,
            networkTransmittedBytes: transmitted,
            blockReadBytes: read,
            blockWrittenBytes: written,
            ts: origin.addingTimeInterval(second))
    }

    // MARK: The first sample

    /// The first reading of a stream has no predecessor, so there is no interval and
    /// therefore no rate. Emitting one would mean dividing a lifetime total by an
    /// invented duration.
    func testTheFirstSampleProducesNoInterval() {
        let single = [sample(second: 0, received: 10_000, transmitted: 5_000)]
        XCTAssertTrue(StatsSample.networkRates(in: single).isEmpty)
        XCTAssertTrue(StatsSample.networkRates(in: []).isEmpty)
    }

    /// n samples yield n − 1 intervals, each timestamped at the *later* of its pair —
    /// a rate describes the window that just ended, not the one about to start.
    func testEachAdjacentPairYieldsExactlyOneIntervalStampedAtItsEnd() {
        let samples = [
            sample(second: 0, received: 0, transmitted: 0),
            sample(second: 2, received: 2_048, transmitted: 512),
            sample(second: 4, received: 6_144, transmitted: 1_536),
        ]

        let rates = StatsSample.networkRates(in: samples)
        XCTAssertEqual(rates.count, 2)
        XCTAssertEqual(rates[0].timestamp, origin.addingTimeInterval(2))
        XCTAssertEqual(rates[0].inboundBytesPerSecond, 1_024)
        XCTAssertEqual(rates[0].outboundBytesPerSecond, 256)
        XCTAssertEqual(rates[1].timestamp, origin.addingTimeInterval(4))
        XCTAssertEqual(rates[1].inboundBytesPerSecond, 2_048)
        XCTAssertEqual(rates[1].outboundBytesPerSecond, 512)
        XCTAssertEqual(Set(rates.map(\.id)).count, rates.count, "Chart identity must be unique.")
    }

    /// The rate is per *real elapsed second*, not per sample. A throttled or stalled
    /// stream that skips a beat must not report double the throughput.
    func testTheRateDividesByRealElapsedTimeNotBySampleCount() {
        let steady = StatsSample.networkRates(in: [
            sample(second: 0, received: 0, transmitted: 0),
            sample(second: 2, received: 4_096, transmitted: 0),
        ])
        let stalled = StatsSample.networkRates(in: [
            sample(second: 0, received: 0, transmitted: 0),
            sample(second: 8, received: 4_096, transmitted: 0),
        ])

        XCTAssertEqual(steady.first?.inboundBytesPerSecond, 2_048)
        XCTAssertEqual(stalled.first?.inboundBytesPerSecond, 512)
    }

    // MARK: Zero and negative elapsed time

    /// The Engine timestamps two documents identically often enough to matter. There is
    /// no rate over a zero-length window, and dividing by it would put an infinity on
    /// the axis.
    func testAZeroLengthIntervalIsDroppedRatherThanDividedBy() {
        let rates = StatsSample.networkRates(in: [
            sample(second: 5, received: 1_000, transmitted: 100),
            sample(second: 5, received: 9_000, transmitted: 900),
        ])
        XCTAssertTrue(rates.isEmpty)
    }

    /// A clock that steps backwards between two documents is not a negative-duration
    /// transfer either.
    func testAnIntervalThatGoesBackwardsInTimeIsDropped() {
        let rates = StatsSample.networkRates(in: [
            sample(second: 10, received: 1_000, transmitted: 100),
            sample(second: 4, received: 9_000, transmitted: 900),
        ])
        XCTAssertTrue(rates.isEmpty)
    }

    /// A zero-length interval must not poison the readings on either side of it.
    func testASurroundedZeroLengthIntervalDoesNotLoseTheGoodOnes() {
        let rates = StatsSample.networkRates(in: [
            sample(second: 0, received: 0, transmitted: 0),
            sample(second: 2, received: 2_048, transmitted: 0),
            sample(second: 2, received: 2_048, transmitted: 0),
            sample(second: 4, received: 4_096, transmitted: 0),
        ])

        XCTAssertEqual(rates.count, 2)
        XCTAssertEqual(rates.map(\.inboundBytesPerSecond), [1_024, 1_024])
    }

    // MARK: Counter resets

    /// A restarted container starts its counters over. The delta is negative, which is
    /// a reset, not a negative transfer — the direction reports nothing for that one
    /// interval and resumes at the next.
    func testACounterResetOmitsOneIntervalAndThenRecovers() {
        let rates = StatsSample.blockIORates(in: [
            sample(second: 0, read: 100_000, written: 50_000),
            sample(second: 2, read: 104_096, written: 52_048),
            sample(second: 4, read: 0, written: 0),      // restart
            sample(second: 6, read: 2_048, written: 1_024),
        ])

        XCTAssertEqual(rates.count, 2)
        XCTAssertEqual(rates[0].timestamp, origin.addingTimeInterval(2))
        XCTAssertEqual(rates[0].inboundBytesPerSecond, 2_048)
        XCTAssertEqual(rates[1].timestamp, origin.addingTimeInterval(6))
        XCTAssertEqual(rates[1].inboundBytesPerSecond, 1_024)
        XCTAssertFalse(
            rates.contains { $0.timestamp == self.origin.addingTimeInterval(4) },
            "The reset interval has no defined rate and must not be plotted as zero.")
    }

    /// One direction can reset while the other does not — a partial reset must not take
    /// the healthy direction down with it.
    func testOnlyTheDirectionThatResetLosesItsReading() {
        let rates = StatsSample.blockIORates(in: [
            sample(second: 0, read: 100_000, written: 50_000),
            sample(second: 2, read: 90_000, written: 52_048),
        ])

        XCTAssertEqual(rates.count, 1)
        XCTAssertNil(rates[0].inboundBytesPerSecond)
        XCTAssertEqual(rates[0].outboundBytesPerSecond, 1_024)
    }

    // MARK: Missing counters

    /// A container the Engine reports no interfaces for yields no network intervals at
    /// all — an empty series, which the inspector renders as its "no counters" state
    /// rather than as a flat line at zero.
    func testAContainerWithNoReportedCountersYieldsNoIntervals() {
        let rates = StatsSample.networkRates(in: [
            sample(second: 0, read: 4_096, written: 1_024),
            sample(second: 2, read: 8_192, written: 2_048),
        ])
        XCTAssertTrue(rates.isEmpty, "No interface counters means no network series.")

        // The same samples do produce disk intervals: the two metrics are independent.
        XCTAssertEqual(StatsSample.blockIORates(in: [
            sample(second: 0, read: 4_096, written: 1_024),
            sample(second: 2, read: 8_192, written: 2_048),
        ]).count, 1)
    }

    /// A counter that is present in one document and missing from the next has no
    /// interval either — the delta would be measured against nothing.
    func testACounterThatDisappearsMidStreamStopsProducingRates() {
        let rates = StatsSample.networkRates(in: [
            sample(second: 0, received: 1_000, transmitted: 100),
            sample(second: 2, received: nil, transmitted: 300),
        ])

        XCTAssertEqual(rates.count, 1)
        XCTAssertNil(rates[0].inboundBytesPerSecond)
        XCTAssertEqual(rates[0].outboundBytesPerSecond, 100)
    }

    /// Zero throughput between two real readings is a measurement of zero and must be
    /// plotted. This is the twin of the test above and the distinction the whole
    /// optional-per-direction design exists to preserve.
    func testAnUnchangedCounterIsAMeasuredZeroAndIsKept() {
        let rates = StatsSample.blockIORates(in: [
            sample(second: 0, read: 8_192, written: 4_096),
            sample(second: 2, read: 8_192, written: 4_096),
        ])

        XCTAssertEqual(rates.count, 1)
        XCTAssertEqual(rates[0].inboundBytesPerSecond, 0)
        XCTAssertEqual(rates[0].outboundBytesPerSecond, 0)
    }

    // MARK: End to end, from the wire

    /// The whole path a live inspector takes: five stats documents off the socket,
    /// through the priming-document drop, into four derived intervals whose values are
    /// arithmetic on the JSON above them.
    func testDerivesRatesFromAStreamOfRealStatsDocuments() throws {
        func document(second: Int, rx: Int, tx: Int, read: Int, write: Int, priming: Bool = false) -> String {
            let previousSystem = priming ? 0 : 4_000_000_000_000
            return """
                {"read":"2026-08-05T09:00:0\(second).000000000Z",
                 "cpu_stats":{"cpu_usage":{"total_usage":12250000000},
                              "system_cpu_usage":4004000000000,"online_cpus":4},
                 "precpu_stats":{"cpu_usage":{"total_usage":12000000000},
                                 "system_cpu_usage":\(previousSystem),"online_cpus":4},
                 "memory_stats":{"usage":1048576,"limit":2147483648},
                 "blkio_stats":{"io_service_bytes_recursive":[
                    {"major":254,"minor":0,"op":"read","value":\(read)},
                    {"major":254,"minor":0,"op":"write","value":\(write)}]},
                 "networks":{"eth0":{"rx_bytes":\(rx),"tx_bytes":\(tx)}}}
                """
        }

        let stream = [
            document(second: 0, rx: 1_000, tx: 100, read: 4_096, write: 1_024, priming: true),
            document(second: 1, rx: 3_000, tx: 300, read: 8_192, write: 3_072),
            document(second: 2, rx: 7_000, tx: 500, read: 8_192, write: 5_120),
            document(second: 3, rx: 9_000, tx: 900, read: 12_288, write: 5_120),
        ]

        var decoder = StatsStreamDecoder()
        var samples: [StatsSample] = []
        for json in stream {
            let wire = try JSONDecoder().decode(Wire.Stats.self, from: Data(json.utf8))
            if let sample = decoder.admit(wire) { samples.append(sample) }
        }

        // Document 0 is the engine's baseline and never reaches the chart, so the
        // first plotted interval is 1→2, not 0→1.
        XCTAssertEqual(samples.count, 3)

        let network = StatsSample.networkRates(in: samples)
        XCTAssertEqual(network.map(\.inboundBytesPerSecond), [4_000, 2_000])
        XCTAssertEqual(network.map(\.outboundBytesPerSecond), [200, 400])

        let disk = StatsSample.blockIORates(in: samples)
        XCTAssertEqual(disk.map(\.inboundBytesPerSecond), [0, 4_096])
        XCTAssertEqual(disk.map(\.outboundBytesPerSecond), [2_048, 0])
    }
}

// MARK: - Rate formatting

final class ByteRateFormattingTests: XCTestCase {

    /// Throughput is formatted with the same units as the cumulative total it came
    /// from, so a reader can compare the two without rescaling in their head.
    func testAByteRateUsesTheSameUnitsAsAByteTotal() {
        XCTAssertEqual(Formatters.byteRateString(0), Formatters.bytesString(0) + "/s")
        XCTAssertEqual(Formatters.byteRateString(1_500_000), Formatters.bytesString(1_500_000) + "/s")
    }

    /// A corrupt counter can produce a non-finite or absurd quotient; the inspector
    /// must print something rather than trap converting it.
    func testAnImpossibleRateIsClampedRatherThanCrashing() {
        XCTAssertEqual(Formatters.byteRateString(.infinity), Formatters.bytesString(0) + "/s")
        XCTAssertEqual(Formatters.byteRateString(.nan), Formatters.bytesString(0) + "/s")
        XCTAssertEqual(Formatters.byteRateString(-5), Formatters.bytesString(0) + "/s")
        XCTAssertFalse(Formatters.byteRateString(.greatestFiniteMagnitude).isEmpty)
    }
}
