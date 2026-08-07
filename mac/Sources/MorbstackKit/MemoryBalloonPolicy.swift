// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Foundation

/// Decides the memory-balloon device's `targetVirtualMachineMemorySize` from the
/// guest's self-reported `/proc/meminfo` sample (UX-17).
///
/// Pure and deliberately conservative — see `docs/design/MEMORY-BALLOON.md` for the
/// full reasoning, including why `VZVirtioTraditionalMemoryBalloonDevice` has no
/// host-visible feedback channel of its own and what that does and does not permit.
/// The three-sentence version: reclaiming too aggressively makes the guest swap or
/// OOM, which is far worse than holding some memory, so growing back is immediate and
/// unthrottled while shrinking is bounded, floored, and only acted on above a noise
/// threshold. This type has no IO, no timer, and no knowledge of `VZVirtualMachine` —
/// ``VMManager`` is the only caller that turns its output into an actual device write.
public enum MemoryBalloonPolicy {

    /// One `/proc/meminfo` reading from the guest, already unwrapped from the wire's
    /// `nil`-means-no-sample / `-1`-sentinel handling (``GuestReply/memTotalKB``,
    /// ``GuestReply/memAvailableKB``).
    public struct Sample: Equatable, Sendable {
        /// `MemTotal`, in kB.
        public var totalKB: Int64
        /// `MemAvailable`, in kB — the kernel's reclaim-aware estimate, not `MemFree`.
        public var availableKB: Int64

        public init(totalKB: Int64, availableKB: Int64) {
            self.totalKB = totalKB
            self.availableKB = availableKB
        }
    }

    /// The conservative constants the policy is tuned by. Every default is argued in
    /// `docs/design/MEMORY-BALLOON.md`; nothing here should move without updating that
    /// reasoning alongside it.
    public struct Configuration: Equatable, Sendable {
        /// The VM's actual configured memory size, in bytes — the hard ceiling. Must
        /// be the boot's clamped `VZVirtualMachineConfiguration.memorySize`, not the
        /// raw `config.toml` value, so the ceiling matches what Virtualization.framework
        /// actually granted.
        public var configuredBytes: UInt64
        /// Floor as a fraction of `configuredBytes`. Default 0.25: the balloon never
        /// asks the guest to run on less than a quarter of what it was configured with,
        /// regardless of how idle `/proc/meminfo` reports it to be.
        public var floorFraction: Double
        /// Absolute floor, in bytes, applied when `floorFraction * configuredBytes`
        /// would be smaller than this. Default 1 GiB.
        public var minimumFloorBytes: UInt64
        /// Extra margin kept on top of the guest's reported usage before computing a
        /// target, as a fraction of that usage. Default 0.35: `MemAvailable` is a
        /// snapshot, not a forecast of the next few minutes of container activity.
        public var headroomFraction: Double
        /// Absolute headroom floor, in bytes, applied when the fractional headroom
        /// would be smaller than this (e.g. a guest reporting very low usage). Default
        /// 512 MiB.
        public var minimumHeadroomBytes: UInt64
        /// Largest fraction of the *current* target the policy will give up in one
        /// evaluation. Default 0.15 — a busy-then-idle guest gives memory back across
        /// several slow-timer ticks, never in one jump.
        public var maxShrinkStepFraction: Double
        /// Smallest change, as a fraction of `configuredBytes`, worth acting on at all
        /// — in either direction. Default 0.03: below this the policy reports "no
        /// change" rather than writing a target that differs from the current one by
        /// an amount indistinguishable from measurement noise.
        public var minimumAdjustmentFraction: Double
        /// Absolute floor for ``minimumAdjustmentFraction``, in bytes. Default 64 MiB.
        public var minimumAdjustmentBytes: UInt64

        public init(
            configuredBytes: UInt64,
            floorFraction: Double = 0.25,
            minimumFloorBytes: UInt64 = 1 << 30,
            headroomFraction: Double = 0.35,
            minimumHeadroomBytes: UInt64 = 512 << 20,
            maxShrinkStepFraction: Double = 0.15,
            minimumAdjustmentFraction: Double = 0.03,
            minimumAdjustmentBytes: UInt64 = 64 << 20
        ) {
            self.configuredBytes = configuredBytes
            self.floorFraction = floorFraction
            self.minimumFloorBytes = minimumFloorBytes
            self.headroomFraction = headroomFraction
            self.minimumHeadroomBytes = minimumHeadroomBytes
            self.maxShrinkStepFraction = maxShrinkStepFraction
            self.minimumAdjustmentFraction = minimumAdjustmentFraction
            self.minimumAdjustmentBytes = minimumAdjustmentBytes
        }
    }

    /// Computes the balloon's next `targetVirtualMachineMemorySize`, or `nil` when
    /// nothing should change.
    ///
    /// - Parameters:
    ///   - previousTargetBytes: What the balloon is currently set to. On a fresh boot
    ///     this should be `configuration.configuredBytes` — an undriven balloon device
    ///     grants the guest everything it was configured with, and that is the correct
    ///     starting point to shrink *from*, not a value this function invents.
    ///   - sample: The guest's latest `/proc/meminfo` reading, or `nil` when none is
    ///     available (unreachable guest, a guest too old to report it, or the wire's
    ///     `-1` sentinel already collapsed to `nil` by ``GuestReply``).
    ///   - configuration: The VM's ceiling plus the tuning constants above.
    /// - Returns: The new target in bytes, or `nil` when the policy has nothing to
    ///   change — either because there is no usable sample, or because the computed
    ///   change does not clear ``Configuration/minimumAdjustmentFraction``.
    public static func nextTarget(
        previousTargetBytes: UInt64,
        sample: Sample?,
        configuration: Configuration
    ) -> UInt64? {
        guard configuration.configuredBytes > 0 else { return nil }
        guard let sample else { return nil }
        // Defensive even though `GuestReply` already folds the wire's `-1` sentinel
        // and mismatched fields into `nil` before this is ever called: a pure
        // function with a public `Sample` initializer should not trust its caller
        // for input this cheap to re-validate.
        guard sample.totalKB > 0, sample.availableKB >= 0, sample.availableKB <= sample.totalKB
        else { return nil }

        let usedKB = sample.totalKB - sample.availableKB
        let usedBytes = UInt64(usedKB) * 1024

        let headroomBytes = max(
            UInt64((Double(usedBytes) * configuration.headroomFraction).rounded()),
            configuration.minimumHeadroomBytes)
        let desiredBeforeClamp = usedBytes.addingReportingOverflow(headroomBytes).partialValue

        let floorBytes = min(
            max(
                UInt64((Double(configuration.configuredBytes) * configuration.floorFraction).rounded()),
                configuration.minimumFloorBytes),
            configuration.configuredBytes)

        let desired = min(max(desiredBeforeClamp, floorBytes), configuration.configuredBytes)
        // A previous target from a config that has since shrunk (e.g. an edited
        // `memory_mib` before the next boot picks it up) cannot be honored past the
        // current ceiling.
        let previous = min(previousTargetBytes, configuration.configuredBytes)

        let minimumAdjustment = max(
            UInt64((Double(configuration.configuredBytes) * configuration.minimumAdjustmentFraction).rounded()),
            configuration.minimumAdjustmentBytes)

        if desired >= previous {
            let delta = desired - previous
            guard delta >= minimumAdjustment else { return nil }
            // Growing back is immediate and unthrottled by design: see the module
            // doc and docs/design/MEMORY-BALLOON.md. Reclaiming too slowly only
            // costs held-but-idle host RAM; restoring too slowly can cost the guest
            // a stall or an OOM kill, so the two directions are not symmetric risks.
            return desired
        }

        let delta = previous - desired
        guard delta >= minimumAdjustment else { return nil }

        let maxStepBytes = max(
            UInt64((Double(previous) * configuration.maxShrinkStepFraction).rounded()), 1)
        let steppedTarget = previous - min(delta, maxStepBytes)
        return max(steppedTarget, floorBytes)
    }

    /// How long the slow-timer evaluator should wait before its *first* tick this
    /// boot. Every tick after the first still uses `interval` unchanged — this only
    /// answers "when does the clock start."
    ///
    /// The problem this solves (found live, see `docs/design/MEMORY-BALLOON.md`):
    /// with a single fixed `interval` and the default `auto_suspend_minutes = 5`,
    /// the VM idle-suspends and the timer is cancelled roughly six times before the
    /// interval's first tick would ever fire. The balloon exists for the guest that
    /// stays busy for hours — a VM idle enough to auto-suspend inside `interval`
    /// never needed ballooning in the first place, since suspend already returns
    /// its memory. So rather than shortening `interval` (which would make the
    /// steady-state busy case re-sample and re-write the balloon target needlessly
    /// often) or coupling suspend to the balloon's readiness (which would delay a
    /// setting the user configured for an unrelated reason), the fix is to make the
    /// first evaluation arrive comfortably before the configured auto-suspend
    /// deadline: at half of it, so a session that turns out to be short-lived still
    /// gets one real evaluation with margin to spare, while a session that turns
    /// out to be busy-all-day only pays that shorter cadence once before settling
    /// into `interval`.
    ///
    /// - Parameters:
    ///   - autoSuspendMinutes: ``MorbConfig/autoSuspendMinutes`` for the running
    ///     daemon. `0` means auto-suspend is off — there is no deadline to beat, so
    ///     this falls back to `defaultDelayWhenAutoSuspendDisabled`.
    ///   - interval: The steady-state repeat interval; the result never exceeds it,
    ///     since firing "early" only makes sense relative to the normal cadence.
    ///   - minimumDelay: A floor so a very short `auto_suspend_minutes` (or a
    ///     misconfigured `0 < n < 1`) cannot make this fire effectively immediately,
    ///     before the guest has had any time to settle post-boot.
    ///   - defaultDelayWhenAutoSuspendDisabled: The first-tick delay used when
    ///     there is no auto-suspend deadline to race. Deliberately shorter than
    ///     `interval` so a long-running, always-on guest still gets its first
    ///     evaluation well before the 30-minute steady-state cadence, not after it.
    public static func firstEvaluationDelay(
        autoSuspendMinutes: Int,
        interval: TimeInterval,
        minimumDelay: TimeInterval = 30,
        defaultDelayWhenAutoSuspendDisabled: TimeInterval = 5 * 60
    ) -> TimeInterval {
        guard autoSuspendMinutes > 0 else {
            return min(interval, defaultDelayWhenAutoSuspendDisabled)
        }
        let autoSuspendSeconds = Double(autoSuspendMinutes) * 60
        return min(interval, max(minimumDelay, autoSuspendSeconds / 2))
    }
}
