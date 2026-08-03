// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// cold-boot: stopped VM to a usable Docker API, repeated.
//
// `VMManager.start(completion:)` fires its completion once the hypervisor
// reports the guest as running — *not* once dockerd is reachable; the
// guest-control handshake and dockerd's own startup continue afterwards (see
// the doc comment on `start` in VMManager.swift). So the number this
// benchmark reports is not "how long did the `start` control call take" —
// that would understate the real number — it is "how long from issuing
// `start` until `GET /_ping` answers", measured by this process polling the
// Docker socket itself after the control call returns.

import Darwin
import Foundation
import MorbFeatures
import MorbstackKit

public struct ColdBootBenchmark: Benchmark {
    public let name = "cold-boot"
    public let summary =
        "Time from a stopped VM, no warm state, to a usable Docker API (GET /_ping answering)."
    public let cost = "stops and boots the VM `--runs` times (default 5); needs a private MORBSTACK_HOME"

    public init() {}

    public func plan(_ context: BenchContext) -> [String] {
        [
            "stop the VM if it is running (no warm state to start from)",
            "\(context.runs)x: send `start`, then poll GET /_ping until it answers or 60s elapses",
            "stop the VM again at the end",
            "creates nothing on disk; no containers or images are involved",
        ]
    }

    public func run(_ context: BenchContext) -> BenchResult {
        let overallStart = Date()
        let availability = StackGuard.probe()
        if let reason = StackGuard.disruptiveOperationBlockReason(availability) {
            return .skipped(name: name, reason: reason)
        }

        var samples: [Double] = []
        var failure: String?
        for run in 1...context.runs {
            _ = controlCall("stop", args: ["force": "true"], timeout: 100)
            let t0 = Date()
            let startResponse = controlCall("start", timeout: 100)
            guard startResponse?.ok == true else {
                failure = "run \(run)/\(context.runs): `start` failed — \(startResponse?.error ?? "no reply")"
                break
            }
            guard let elapsed = pollForReady(from: t0, deadline: 60) else {
                failure = "run \(run)/\(context.runs): GET /_ping did not answer within 60s of `start` completing"
                break
            }
            samples.append(elapsed)
        }
        // Leave the VM stopped either way — a benchmark should not change what state it found things in.
        _ = controlCall("stop", args: ["force": "true"], timeout: 100)

        guard failure == nil, let distribution = Distribution(samples: samples) else {
            return BenchResult(
                name: name, verdict: .skipped,
                summary: "SKIPPED — \(failure ?? "no samples collected")",
                skippedReason: failure, notes: ["\(samples.count)/\(context.runs) runs completed before the failure"],
                durationSeconds: Date().timeIntervalSince(overallStart))
        }

        return .measured(
            name: name, value: distribution.median, target: Targets.coldBoot,
            summary: "median \(Format.duration(distribution.median)) over \(context.runs) runs — "
                + distribution.rendered(formatter: Format.duration),
            distribution: distribution, durationSeconds: Date().timeIntervalSince(overallStart))
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
