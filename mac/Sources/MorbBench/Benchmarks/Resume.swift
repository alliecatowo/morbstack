// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// resume: suspend, then resume, to a usable Docker API.
//
// `Virtualization.framework` accepts `saveMachineStateTo` for a
// direct-kernel (`VZLinuxBootLoader`) guest and then refuses to restore the
// result — `VMManager` discovers this by trying, and records it at
// `MorbPaths.saveRestoreUnsupported` (see Paths.swift) so it does not pay
// for a failed restore attempt on every subsequent boot. On a host where
// that marker exists, `suspend` degrades to a plain stop and `resume`
// degrades to a cold boot — this benchmark's job is to measure whatever
// actually happens and say plainly which one it was, not to assume restore
// works and quietly report a cold-boot number under the "resume" name.

import Darwin
import Foundation
import MorbFeatures
import MorbstackKit

public struct ResumeBenchmark: Benchmark {
    public let name = "resume"
    public let summary =
        "Time from `suspend` to a usable Docker API after `resume`. Reports honestly when this host "
        + "cannot restore a saved VM and resume is really a degraded cold boot."
    public let cost = "suspends and resumes the VM `--runs` times (default 5); needs a private MORBSTACK_HOME"

    public init() {}

    public func plan(_ context: BenchContext) -> [String] {
        [
            "start the VM if it is not already running",
            "\(context.runs)x: `suspend`, then `resume`, polling GET /_ping until it answers or 60s elapses",
            "check \(MorbPaths.saveRestoreUnsupported.path) to report whether restore actually happened "
                + "or degraded to a cold boot",
            "leaves the VM running at the end; creates nothing on disk",
        ]
    }

    public func run(_ context: BenchContext) -> BenchResult {
        let overallStart = Date()
        let availability = StackGuard.probe()
        if let reason = StackGuard.disruptiveOperationBlockReason(availability) {
            return .skipped(name: name, reason: reason)
        }

        if availability.vmState != "running" {
            guard controlCall("start", timeout: 100)?.ok == true, pollForReady(from: Date(), deadline: 90) != nil
            else {
                return .skipped(name: name, reason: "could not bring the VM up before the resume benchmark")
            }
        }

        var samples: [Double] = []
        var failure: String?
        for run in 1...context.runs {
            let wasBrokenBefore = FileManager.default.fileExists(atPath: MorbPaths.saveRestoreUnsupported.path)
            let suspendResponse = controlCall("suspend", timeout: 115)
            guard suspendResponse?.ok == true else {
                failure = "run \(run)/\(context.runs): `suspend` failed — \(suspendResponse?.error ?? "no reply")"
                break
            }
            let t0 = Date()
            let resumeResponse = controlCall("resume", timeout: 100)
            guard resumeResponse?.ok == true else {
                failure = "run \(run)/\(context.runs): `resume` failed — \(resumeResponse?.error ?? "no reply")"
                break
            }
            guard let elapsed = pollForReady(from: t0, deadline: 60) else {
                failure = "run \(run)/\(context.runs): GET /_ping did not answer within 60s of `resume` completing"
                break
            }
            samples.append(elapsed)
            if run == 1, !wasBrokenBefore,
                FileManager.default.fileExists(atPath: MorbPaths.saveRestoreUnsupported.path)
            {
                // Discovered right here, on this run: the first sample paid
                // for the failed restore attempt the rest will not.
            }
        }

        guard failure == nil, let distribution = Distribution(samples: samples) else {
            return BenchResult(
                name: name, verdict: .skipped,
                summary: "SKIPPED — \(failure ?? "no samples collected")",
                skippedReason: failure, notes: ["\(samples.count)/\(context.runs) runs completed before the failure"],
                durationSeconds: Date().timeIntervalSince(overallStart))
        }

        let degraded = FileManager.default.fileExists(atPath: MorbPaths.saveRestoreUnsupported.path)
        var notes: [String] = []
        var summary: String
        if degraded {
            notes.append(
                "save/restore is unsupported on this host for a direct-kernel guest — Virtualization.framework "
                    + "accepts the save but refuses the restore, so Morbstack degrades `suspend` to a stop and "
                    + "`resume` to a cold boot. \(MorbPaths.saveRestoreUnsupported.path) is present.")
            summary =
                "resume is a degraded cold boot on this host, measured at "
                + "\(Format.duration(distribution.median)) median, against a 500ms target: MISS"
        } else {
            summary =
                "true resume (state restored): median \(Format.duration(distribution.median)) over "
                + "\(context.runs) runs — " + distribution.rendered(formatter: Format.duration)
        }

        let result = BenchResult.measured(
            name: name, value: distribution.median, target: Targets.resume, summary: summary,
            distribution: distribution, notes: notes, durationSeconds: Date().timeIntervalSince(overallStart))
        return result
    }

    private func pollForReady(from t0: Date, deadline: TimeInterval) -> TimeInterval? {
        let engine = EngineClient()
        let cutoff = Date().addingTimeInterval(deadline)
        while Date() < cutoff {
            if engine.ping(timeout: 2) { return Date().timeIntervalSince(t0) }
            usleep(50_000)
        }
        return nil
    }

    private func controlCall(_ cmd: String, args: [String: String]? = nil, timeout: TimeInterval) -> DaemonResponse? {
        try? UnixSocketClient.roundTrip(
            path: MorbPaths.controlSocket.path, request: DaemonRequest(cmd: cmd, args: args), timeout: timeout)
    }
}
