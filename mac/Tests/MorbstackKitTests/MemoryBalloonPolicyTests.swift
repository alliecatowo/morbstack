// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import XCTest

@testable import MorbstackKit

/// UX-17: every asymmetry `docs/design/MEMORY-BALLOON.md` argues for — no guess
/// without a sample, a floor the policy never crosses, unthrottled growth,
/// step-limited shrink, and a noise threshold in both directions — pinned here so
/// none of it is just a comment somebody has to trust.
final class MemoryBalloonPolicyTests: XCTestCase {

    private let GiB: UInt64 = 1 << 30
    private let MiB: UInt64 = 1 << 20

    private func configuration(configuredGiB: UInt64 = 8) -> MemoryBalloonPolicy.Configuration {
        MemoryBalloonPolicy.Configuration(configuredBytes: configuredGiB * GiB)
    }

    /// The actual noise threshold `nextTarget` applies for `cfg` — the larger of the
    /// fractional and absolute floors, exactly as the implementation computes it.
    /// Deriving it here (rather than assuming the fractional or the absolute term
    /// wins) keeps the hysteresis tests correct if either default ever changes.
    private func effectiveMinimumAdjustment(_ cfg: MemoryBalloonPolicy.Configuration) -> UInt64 {
        max(
            UInt64((Double(cfg.configuredBytes) * cfg.minimumAdjustmentFraction).rounded()),
            cfg.minimumAdjustmentBytes)
    }

    // MARK: - No sample, no guess

    func testNoSampleMeansNoChange() {
        XCTAssertNil(
            MemoryBalloonPolicy.nextTarget(
                previousTargetBytes: 8 * GiB, sample: nil, configuration: configuration()))
    }

    func testAnInconsistentSampleIsIgnoredRatherThanActedOn() {
        let cfg = configuration()
        // available > total: cannot happen honestly, must not be trusted.
        XCTAssertNil(
            MemoryBalloonPolicy.nextTarget(
                previousTargetBytes: 8 * GiB,
                sample: .init(totalKB: 100, availableKB: 200),
                configuration: cfg))
        // Non-positive total.
        XCTAssertNil(
            MemoryBalloonPolicy.nextTarget(
                previousTargetBytes: 8 * GiB,
                sample: .init(totalKB: 0, availableKB: 0),
                configuration: cfg))
        // Negative available.
        XCTAssertNil(
            MemoryBalloonPolicy.nextTarget(
                previousTargetBytes: 8 * GiB,
                sample: .init(totalKB: 100, availableKB: -1),
                configuration: cfg))
    }

    func testAZeroConfiguredSizeNeverProducesATarget() {
        let cfg = MemoryBalloonPolicy.Configuration(configuredBytes: 0)
        XCTAssertNil(
            MemoryBalloonPolicy.nextTarget(
                previousTargetBytes: 0,
                sample: .init(totalKB: 8_388_608, availableKB: 4_194_304),
                configuration: cfg))
    }

    // MARK: - Floor

    func testTheFirstShrinkNeverGoesBelowTheFloorEvenWhenUsageIsTiny() {
        // 8 GiB configured, guest reports 512 MiB used (7.5 GiB available) — usage is
        // small enough that used+headroom alone would undercut the floor.
        let cfg = configuration()
        let sample = MemoryBalloonPolicy.Sample(
            totalKB: Int64(8 * GiB / 1024), availableKB: Int64((8 * GiB - 512 * MiB) / 1024))
        let target = MemoryBalloonPolicy.nextTarget(
            previousTargetBytes: 8 * GiB, sample: sample, configuration: cfg)
        XCTAssertNotNil(target)
        // Step-limited (see below), but must never undercut the floor even on a
        // single very large step.
        XCTAssertGreaterThanOrEqual(target!, 2 * GiB, "must never cross the 25%-of-configured floor")
    }

    func testConvergesToWithinTheNoiseThresholdOfTheFloorAndThenStops() {
        // Same idle sample every tick, simulating repeated slow-timer evaluations.
        // Convergence deliberately does not have to land on the floor to the byte:
        // once the remaining gap drops below the hysteresis threshold, that gap is
        // noise by definition and the policy correctly stops adjusting rather than
        // chasing the last few MiB tick after tick forever.
        let cfg = configuration()
        let sample = MemoryBalloonPolicy.Sample(
            totalKB: Int64(8 * GiB / 1024), availableKB: Int64((8 * GiB - 512 * MiB) / 1024))

        var previous = 8 * GiB
        var iterations = 0
        while let next = MemoryBalloonPolicy.nextTarget(
            previousTargetBytes: previous, sample: sample, configuration: cfg)
        {
            XCTAssertLessThan(next, previous, "each step must move toward the floor, never away from it")
            XCTAssertGreaterThanOrEqual(next, 2 * GiB, "must never cross the floor mid-convergence")
            previous = next
            iterations += 1
            XCTAssertLessThan(iterations, 100, "convergence must terminate in a bounded number of ticks")
        }
        XCTAssertGreaterThan(iterations, 1, "a floor this far from 8 GiB must take more than one step")
        XCTAssertLessThan(
            previous - 2 * GiB, effectiveMinimumAdjustment(cfg),
            "must converge to within the noise threshold of the floor")

        // Once converged, the same sample produces no further change.
        XCTAssertNil(
            MemoryBalloonPolicy.nextTarget(previousTargetBytes: previous, sample: sample, configuration: cfg))
    }

    // MARK: - Shrink is bounded per step

    func testASingleEvaluationNeverGivesUpMoreThanTheConfiguredMaxShrinkStep() {
        let cfg = configuration()
        let sample = MemoryBalloonPolicy.Sample(
            totalKB: Int64(8 * GiB / 1024), availableKB: Int64((8 * GiB - 512 * MiB) / 1024))
        let target = MemoryBalloonPolicy.nextTarget(
            previousTargetBytes: 8 * GiB, sample: sample, configuration: cfg)!
        let givenUp = 8 * GiB - target
        let maxStep = UInt64((Double(8 * GiB) * cfg.maxShrinkStepFraction).rounded())
        XCTAssertLessThanOrEqual(givenUp, maxStep)
    }

    // MARK: - Growth is immediate and unthrottled

    func testGrowingBackIsImmediateNotStepLimited() {
        // The balloon has already shrunk to the floor; the guest is now busy.
        let cfg = configuration()
        let busySample = MemoryBalloonPolicy.Sample(
            totalKB: Int64(8 * GiB / 1024), availableKB: Int64(1 * GiB / 1024))
        let target = MemoryBalloonPolicy.nextTarget(
            previousTargetBytes: 2 * GiB, sample: busySample, configuration: cfg)
        // 7 GiB used + 35% headroom exceeds the 8 GiB ceiling, so the exact expected
        // value is the ceiling itself — reached in this one call, not approached via
        // several `maxShrinkStepFraction`-sized ticks the way a shrink of the same
        // magnitude would be.
        XCTAssertEqual(target, 8 * GiB)
    }

    func testDesiredNeverExceedsConfiguredMemoryEvenUnderHeavyReportedUsage() {
        let cfg = configuration()
        // Guest reports almost everything in use; used + headroom alone would exceed
        // the 8 GiB ceiling.
        let sample = MemoryBalloonPolicy.Sample(totalKB: Int64(8 * GiB / 1024), availableKB: 1024)
        let target = MemoryBalloonPolicy.nextTarget(
            previousTargetBytes: 2 * GiB, sample: sample, configuration: cfg)
        XCTAssertEqual(target, 8 * GiB)
    }

    // MARK: - Hysteresis (noise threshold), both directions

    /// The exact "desired" value the policy computes for `sample` (floor/ceiling
    /// clamped, but never step-limited): calling from a `previousTargetBytes` of `0`
    /// always takes the unthrottled growth branch, so the result is precisely what a
    /// step-limited call would be working *toward* — the value the two tests below
    /// perturb `previousTargetBytes` around.
    private func desiredTarget(
        for sample: MemoryBalloonPolicy.Sample, configuration cfg: MemoryBalloonPolicy.Configuration
    ) -> UInt64 {
        MemoryBalloonPolicy.nextTarget(previousTargetBytes: 0, sample: sample, configuration: cfg)!
    }

    func testATinyShrinkBelowTheNoiseThresholdProducesNoChange() {
        let cfg = configuration()
        // Comfortably between the floor (2 GiB) and the ceiling (8 GiB), so a small
        // perturbation of `previousTargetBytes` cannot accidentally hit either clamp.
        let sample = MemoryBalloonPolicy.Sample(
            totalKB: Int64(8 * GiB / 1024), availableKB: Int64((8 * GiB - 3 * GiB) / 1024))
        let desired = desiredTarget(for: sample, configuration: cfg)
        XCTAssertGreaterThan(desired, 2 * GiB + 500 * MiB)
        XCTAssertLessThan(desired, 8 * GiB - 500 * MiB)

        let smallDelta = effectiveMinimumAdjustment(cfg) / 2
        XCTAssertNil(
            MemoryBalloonPolicy.nextTarget(
                previousTargetBytes: desired + smallDelta, sample: sample, configuration: cfg),
            "a shrink smaller than the noise threshold must not produce a change")
    }

    func testATinyGrowthBelowTheNoiseThresholdProducesNoChange() {
        let cfg = configuration()
        let sample = MemoryBalloonPolicy.Sample(
            totalKB: Int64(8 * GiB / 1024), availableKB: Int64((8 * GiB - 3 * GiB) / 1024))
        let desired = desiredTarget(for: sample, configuration: cfg)
        XCTAssertGreaterThan(desired, 2 * GiB + 500 * MiB)
        XCTAssertLessThan(desired, 8 * GiB - 500 * MiB)

        let smallDelta = effectiveMinimumAdjustment(cfg) / 2
        XCTAssertNil(
            MemoryBalloonPolicy.nextTarget(
                previousTargetBytes: desired - smallDelta, sample: sample, configuration: cfg),
            "a growth smaller than the noise threshold must not produce a change")
    }

    func testAShrinkAtOrAboveTheNoiseThresholdDoesProduceAChange() {
        let cfg = configuration()
        let sample = MemoryBalloonPolicy.Sample(
            totalKB: Int64(8 * GiB / 1024), availableKB: Int64((8 * GiB - 3 * GiB) / 1024))
        let desired = desiredTarget(for: sample, configuration: cfg)
        let largeDelta = effectiveMinimumAdjustment(cfg) * 2
        XCTAssertNotNil(
            MemoryBalloonPolicy.nextTarget(
                previousTargetBytes: desired + largeDelta, sample: sample, configuration: cfg))
    }

    // MARK: - A shrunk configuration clamps a stale previous target

    func testAPreviousTargetAboveTheCurrentCeilingIsClampedBeforeStepMath() {
        // Simulates memory_mib having been edited down since the balloon's last
        // recorded target — the stale previous value must not let a single step
        // "shrink" from a number the guest was never actually given.
        let cfg = configuration()  // 8 GiB configured
        let sample = MemoryBalloonPolicy.Sample(
            totalKB: Int64(8 * GiB / 1024), availableKB: Int64((8 * GiB - 512 * MiB) / 1024))
        let target = MemoryBalloonPolicy.nextTarget(
            previousTargetBytes: 100 * GiB, sample: sample, configuration: cfg)!
        XCTAssertLessThanOrEqual(target, 8 * GiB)
        // Step math ran from the clamped 8 GiB, not the stale 100 GiB, so the result
        // matches the ordinary first-shrink case exactly.
        let expected = MemoryBalloonPolicy.nextTarget(
            previousTargetBytes: 8 * GiB, sample: sample, configuration: cfg)!
        XCTAssertEqual(target, expected)
    }
}
