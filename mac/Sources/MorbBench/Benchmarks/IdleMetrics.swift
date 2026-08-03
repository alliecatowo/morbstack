// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// idle-cpu, idle-wakeups, host-rss: three separately-selectable benchmarks
// that all read the same `top -l` sample of morbstackd's pid over a window.
// They are kept as three `Benchmark` conformers (so `--only idle-cpu` works
// on its own) but share ``sampleDaemon(_:)`` rather than three copies of the
// same sampling logic.

import Foundation
import MorbFeatures
import MorbstackKit

/// Runs the shared `top` sample, or produces the shared SKIPPED reason —
/// used by all three benchmarks below so they refuse identically rather than
/// with three subtly different messages for the same underlying problem.
private func sampleDaemon(_ context: BenchContext) -> Result<ProcessSampleWindow, String> {
    let availability = StackGuard.probe()
    if let reason = StackGuard.idleMeasurementBlockReason(availability) {
        return .failure(reason)
    }
    guard let pid = DaemonProcess.morbstackdPID() else {
        return .failure("could not determine morbstackd's pid from \(MorbPaths.lockFile.path)")
    }
    do {
        let window = try ProcessSampler.sample(pid: pid, windowSeconds: context.idleWindowSeconds)
        return .success(window)
    } catch {
        return .failure("\(error)")
    }
}

public struct IdleCPUBenchmark: Benchmark {
    public let name = "idle-cpu"
    public let summary = "Host CPU used by morbstackd (which hosts the VM in-process) with nothing running in it."
    public let cost = "observes only — samples `top` for `--window` seconds (default 30); needs an idle engine"

    public init() {}

    public func plan(_ context: BenchContext) -> [String] {
        [
            "confirm the engine is running with no containers active",
            "sample `top -l` for morbstackd's pid, once a second, for \(context.idleWindowSeconds)s "
                + "(the first sample is discarded — it is a since-launch average, not an interval delta)",
            "creates and stops nothing",
        ]
    }

    public func run(_ context: BenchContext) -> BenchResult {
        let started = Date()
        switch sampleDaemon(context) {
        case .failure(let reason):
            return .skipped(name: name, reason: reason)
        case .success(let window):
            guard let distribution = window.cpuPercent else {
                return .skipped(name: name, reason: "top produced no CPU samples")
            }
            return .measured(
                name: name, value: distribution.mean, target: Targets.idleCPU,
                summary: "mean \(String(format: "%.2f%%", distribution.mean)) over \(window.samples.count)s — "
                    + distribution.rendered(formatter: { String(format: "%.2f%%", $0) })
                    + " (morbstackd hosts the VM in-process; no separate VM helper process exists to sample)",
                distribution: distribution, durationSeconds: Date().timeIntervalSince(started))
        }
    }
}

public struct IdleWakeupsBenchmark: Benchmark {
    public let name = "idle-wakeups"
    public let summary = "Idle wakeups/second for morbstackd with nothing running in the guest."
    public let cost = "observes only — samples `top` for `--window` seconds (default 30); needs an idle engine"

    public init() {}

    public func plan(_ context: BenchContext) -> [String] {
        [
            "confirm the engine is running with no containers active",
            "sample `top -l -stats pid,cpu,rsize,idlew` for morbstackd's pid, once a second, "
                + "for \(context.idleWindowSeconds)s",
            "creates and stops nothing",
        ]
    }

    public func run(_ context: BenchContext) -> BenchResult {
        let started = Date()
        switch sampleDaemon(context) {
        case .failure(let reason):
            return .skipped(name: name, reason: reason)
        case .success(let window):
            guard let distribution = window.idleWakeups else {
                // Exactly the "say so precisely rather than inventing a number" case
                // from the task brief: this macOS's `top` did not report IDLEW at all.
                return .skipped(
                    name: name,
                    reason: "this macOS's `top` did not report an IDLEW column for the sampled process — "
                        + "idle wakeups are not available without elevated privileges "
                        + "(powermetrics needs sudo) on this host")
            }
            return .measured(
                name: name, value: distribution.mean, target: Targets.idleWakeups,
                summary: "mean \(String(format: "%.1f", distribution.mean))/s over \(window.samples.count)s — "
                    + distribution.rendered(formatter: { String(format: "%.1f/s", $0) }),
                distribution: distribution, durationSeconds: Date().timeIntervalSince(started))
        }
    }
}

public struct HostRSSBenchmark: Benchmark {
    public let name = "host-rss"
    public let summary = "Resident set size of morbstackd (which hosts the VM in-process) at idle."
    public let cost = "observes only — samples `top` for `--window` seconds (default 30); needs an idle engine"

    public init() {}

    public func plan(_ context: BenchContext) -> [String] {
        [
            "confirm the engine is running with no containers active",
            "sample `top -l` for morbstackd's pid, once a second, for \(context.idleWindowSeconds)s, and report RSIZE",
            "creates and stops nothing",
        ]
    }

    public func run(_ context: BenchContext) -> BenchResult {
        let started = Date()
        switch sampleDaemon(context) {
        case .failure(let reason):
            return .skipped(name: name, reason: reason)
        case .success(let window):
            guard let distribution = window.residentBytes else {
                return .skipped(name: name, reason: "top produced no RSIZE samples")
            }
            return .measured(
                name: name, value: distribution.mean, target: Targets.hostRSS,
                summary: "mean \(Format.bytes(Int64(distribution.mean))) over \(window.samples.count)s — "
                    + distribution.rendered(formatter: { Format.bytes(Int64($0)) })
                    + " (morbstackd hosts the VM in-process; this includes the VM's own working set, not "
                    + "just the Swift process's own allocations)",
                distribution: distribution, durationSeconds: Date().timeIntervalSince(started))
        }
    }
}
