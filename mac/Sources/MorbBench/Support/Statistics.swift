// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The one honesty rule this whole harness rests on: a benchmark is a
// distribution, not a number. Anything that reports a single timing without
// also reporting its spread is hiding the run it got unlucky (or lucky) on.
// This file is the pure arithmetic behind that rule, kept separate from I/O
// so it can be pinned with plain unit tests against known inputs.

import Foundation

/// Percentile and summary-statistic helpers over a fixed sample.
public enum Statistics {

    /// Linear-interpolation percentile (the "type 7" method — the same one
    /// `numpy.percentile`'s default and Excel's `PERCENTILE.INC` use), so a
    /// reader who wants to check our math by hand gets the same answer with
    /// the tool they already have.
    ///
    /// - Parameter sorted: values already sorted ascending. Passing unsorted
    ///   input silently produces a wrong answer, so callers go through
    ///   ``Distribution/init(samples:)`` rather than this directly.
    /// - Parameter percent: 0...100.
    public static func percentile(sorted: [Double], _ percent: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        guard sorted.count > 1 else { return sorted[0] }
        let clamped = min(max(percent, 0), 100)
        let rank = (clamped / 100.0) * Double(sorted.count - 1)
        let lowerIndex = Int(rank.rounded(.down))
        let upperIndex = Int(rank.rounded(.up))
        if lowerIndex == upperIndex { return sorted[lowerIndex] }
        let fraction = rank - Double(lowerIndex)
        return sorted[lowerIndex] + (sorted[upperIndex] - sorted[lowerIndex]) * fraction
    }
}

/// A summarised set of samples from repeating one measurement N times.
///
/// Every timing-based benchmark in this harness reports one of these instead
/// of a mean, because a mean alone erases exactly the tail behaviour ("boots
/// in 1.8s nineteen times out of twenty, then once in 6s because Spotlight
/// decided to reindex") that a reader most needs to know about.
public struct Distribution: Codable, Equatable, Sendable {
    /// Every sample, in the order they were taken — kept so a suspicious
    /// reader can recompute anything below from the raw numbers.
    public var samples: [Double]
    public var min: Double
    public var median: Double
    public var p95: Double
    public var max: Double
    public var mean: Double

    /// - Returns: `nil` for an empty sample set; there is nothing honest to
    ///   report about zero measurements.
    public init?(samples: [Double]) {
        guard !samples.isEmpty else { return nil }
        self.samples = samples
        let sorted = samples.sorted()
        self.min = sorted.first!
        self.max = sorted.last!
        self.mean = samples.reduce(0, +) / Double(samples.count)
        self.median = Statistics.percentile(sorted: sorted, 50)
        self.p95 = Statistics.percentile(sorted: sorted, 95)
    }

    /// `min/median/p95/max` on one line, in the caller-supplied unit.
    public func rendered(formatter: (Double) -> String) -> String {
        "min \(formatter(min))  median \(formatter(median))  p95 \(formatter(p95))  max \(formatter(max))"
            + "  (n=\(samples.count))"
    }
}
