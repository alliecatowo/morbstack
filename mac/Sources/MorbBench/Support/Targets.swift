// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The public performance target table (docs/roadmap.md, "Public performance
// target table") reproduced here as data, because a benchmark that cannot say
// PASS or MISS against a published number is just a stopwatch. Every target
// below is copied from that table; if the table changes, this must change
// with it — there is deliberately no third source of truth.

import Foundation

/// The outcome of comparing one measurement against its target.
public enum Verdict: String, Codable, Equatable, Sendable {
    case pass = "PASS"
    case miss = "MISS"
    /// The benchmark has no published target (e.g. `disk-apparent-vs-actual`,
    /// which is diagnostic rather than a commitment).
    case notApplicable = "N/A"
    /// The benchmark could not run at all — see ``BenchResult/skippedReason``.
    case skipped = "SKIPPED"
}

/// One row of the published target table, expressed as a `value <= goal`
/// (lower-is-better) comparison. Every current target is lower-is-better —
/// times, percentages, wakeup rates, byte counts and the two bind-mount
/// ratios all read "smaller is closer to native/instant" — so a single
/// comparison direction covers the whole table without inventing a case that
/// nothing here exercises.
public struct Target: Sendable {
    /// Matches the benchmark name it belongs to.
    public var name: String
    /// Human string for the target itself, e.g. `"<= 2.0s"`.
    public var goalDescription: String
    public var goal: Double
    public var unit: String

    public init(name: String, goal: Double, unit: String, goalDescription: String) {
        self.name = name
        self.goal = goal
        self.unit = unit
        self.goalDescription = goalDescription
    }

    /// Compares `value` (already in ``unit``) against ``goal``.
    ///
    /// The boundary is inclusive: a value exactly equal to the goal is a
    /// PASS, matching "cold boot ≤ 2.0s" read literally.
    public func evaluate(_ value: Double) -> (verdict: Verdict, deltaPercent: Double) {
        guard value.isFinite else { return (.skipped, .nan) }
        let delta = goal == 0 ? (value == 0 ? 0 : Double.infinity) : (value - goal) / goal * 100
        return (value <= goal ? .pass : .miss, delta)
    }
}

/// The table itself — one entry per row in docs/roadmap.md, keyed by the
/// benchmark name that measures it.
public enum Targets {
    public static let coldBoot = Target(name: "cold-boot", goal: 2.0, unit: "s", goalDescription: "<= 2.0s")
    public static let resume = Target(name: "resume", goal: 0.5, unit: "s", goalDescription: "<= 500ms")
    public static let idleCPU = Target(name: "idle-cpu", goal: 0.1, unit: "%", goalDescription: "<= 0.1%")
    public static let idleWakeups = Target(
        name: "idle-wakeups", goal: 20.0, unit: "wakeups/s", goalDescription: "< 20/s")
    public static let hostRSS = Target(
        name: "host-rss", goal: 120_000_000, unit: "bytes", goalDescription: "<= 120 MB")
    public static let guestMemoryFloor = Target(
        name: "guest-memory-floor", goal: 256_000_000, unit: "bytes", goalDescription: "<= 256 MB")
    public static let gitStatusBindmount = Target(
        name: "git-status-bindmount", goal: 2.0, unit: "x native", goalDescription: "<= 2x native")
    public static let npmInstall = Target(
        name: "npm-install-bindmount-vs-volume", goal: 1.5, unit: "x native",
        goalDescription: "<= 1.5x native")

    /// All published targets, for `morb bench list`.
    public static let all: [Target] = [
        coldBoot, resume, idleCPU, idleWakeups, hostRSS, guestMemoryFloor, gitStatusBindmount, npmInstall,
    ]

    public static func target(for benchmarkName: String) -> Target? {
        all.first { $0.name == benchmarkName }
    }
}

/// The threshold used by `morb bench compare` to tell a real regression from
/// run-to-run noise.
///
/// 5%, not the 2% the task brief singles out as too tight: cold boot and
/// resume both touch a VZVirtualMachine boot path that shares the host with
/// Spotlight, Time Machine and whatever else macOS decides to do, and 5
/// repeated cold-boot runs on this development machine (see
/// docs/benchmarks.md) already show several percent of spread with nothing
/// else changing between them. Flagging every run-to-run wobble under that
/// spread as a "regression" would make the comparison useless within a day.
/// 5% is still tight enough to catch a real slowdown — the kind introduced by
/// an accidental extra guest-control round trip — well before it reaches the
/// published target's own margin.
public enum RegressionPolicy {
    public static let noiseThresholdPercent = 5.0

    /// Classifies the change from `oldValue` to `newValue` for a lower-is-better metric.
    public enum Classification: String, Sendable {
        case regression
        case improvement
        case noise
        case unavailable
    }

    public static func classify(oldValue: Double?, newValue: Double?) -> (Classification, Double?) {
        guard let oldValue, let newValue, oldValue.isFinite, newValue.isFinite else {
            return (.unavailable, nil)
        }
        guard oldValue != 0 else {
            return (newValue == 0 ? .noise : .regression, nil)
        }
        let deltaPercent = (newValue - oldValue) / oldValue * 100
        if abs(deltaPercent) < noiseThresholdPercent { return (.noise, deltaPercent) }
        return (deltaPercent > 0 ? .regression : .improvement, deltaPercent)
    }
}
