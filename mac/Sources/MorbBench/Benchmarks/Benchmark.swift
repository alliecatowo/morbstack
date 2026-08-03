// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The shared shape every benchmark implements, and the parameters `morb
// bench` hands each one. Kept intentionally small: a benchmark either
// produces a ``BenchResult`` (measured, N/A, or SKIPPED — see
// `RunRecord.swift`) or it does not run at all, and every benchmark decides
// that for itself rather than the harness guessing on its behalf.

import Foundation
import MorbFeatures

/// Parameters shared by every benchmark run, and the knobs `--runs`/`--window` adjust.
public struct BenchContext: Sendable {
    /// Repetitions for timing benchmarks that report a distribution
    /// (cold-boot, resume). Defaults to 5, per the task brief.
    public var runs: Int
    /// Sampling window, in seconds, for the idle-* benchmarks. Defaults to 30.
    public var idleWindowSeconds: Int
    /// Whether this is `--dry-run`: benchmarks must not create or destroy
    /// anything when this is `true`, only describe what they would do.
    public var dryRun: Bool

    public init(runs: Int = 5, idleWindowSeconds: Int = 30, dryRun: Bool = false) {
        self.runs = runs
        self.idleWindowSeconds = idleWindowSeconds
        self.dryRun = dryRun
    }

    /// A fresh client for the Docker socket at the current `MORBSTACK_HOME`.
    /// Fresh rather than cached: `EngineClient` is cheap to construct and a
    /// benchmark that just started or stopped the VM wants a client that
    /// re-resolves the socket path rather than one captured before the VM existed.
    public func engine() -> EngineClient { EngineClient() }
}

/// One entry in the benchmark suite.
public protocol Benchmark {
    /// Stable identifier used by `--only`, `list`, and stored in every ``BenchResult``.
    var name: String { get }
    /// One sentence: what this measures. Shown by `morb bench list`.
    var summary: String { get }
    /// One sentence: what running it costs — time, whether it needs a
    /// private stack, what it creates. Shown by `morb bench list` and as the
    /// basis for `--dry-run`'s per-benchmark plan.
    var cost: String { get }

    /// The exact steps this benchmark will take, for `--dry-run`. Must not
    /// have any side effects — no benchmark may create anything while
    /// answering this.
    func plan(_ context: BenchContext) -> [String]

    /// Runs the benchmark for real. Implementations must leave no created
    /// container, volume, file or directory behind on any path but a crash,
    /// and must return ``BenchResult/skipped(name:reason:notes:)`` rather
    /// than fabricate a number when they cannot honestly measure something.
    func run(_ context: BenchContext) -> BenchResult
}
