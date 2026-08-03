// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Idle CPU, idle wakeups and RSS all come from the same place: `top -l`,
// sampled once a second over a window, restricted to the process(es) we
// care about. `top` is what the task brief specifically calls out as "the
// accessible one without root" for idle wakeups (`powermetrics` needs sudo),
// so it is the one source used for all three numbers rather than mixing
// `ps` for CPU/RSS and `top` for wakeups — one tool, one set of sampling
// artefacts to reason about.

import Foundation
import MorbFeatures

/// One second's reading for one process from `top -l ... -s 1`.
public struct ProcessSample: Sendable {
    public var pid: Int32
    public var cpuPercent: Double
    public var residentBytes: Int64
    /// Idle wakeups in the sampling interval (effectively a rate, since the
    /// interval is fixed at one second by ``ProcessSampler``). `nil` when the
    /// column was not present in `top`'s output — an older macOS `top`
    /// without `idlew` support, in which case the caller must say so rather
    /// than reporting `0`.
    public var idleWakeups: Double?
}

/// Repeated `top` samples for one process, with the known-unreliable first
/// sample already dropped.
public struct ProcessSampleWindow: Sendable {
    public var samples: [ProcessSample]
    public var droppedFirstSample: Bool

    public var cpuPercent: Distribution? { Distribution(samples: samples.map(\.cpuPercent)) }
    public var residentBytes: Distribution? { Distribution(samples: samples.map { Double($0.residentBytes) }) }
    public var idleWakeups: Distribution? {
        let values = samples.compactMap(\.idleWakeups)
        guard values.count == samples.count, !values.isEmpty else { return nil }
        return Distribution(samples: values)
    }
}

public enum ProcessSampler {

    public enum SamplingError: Error, CustomStringConvertible {
        case topNotFound
        case processExited
        case parseFailure(String)

        public var description: String {
            switch self {
            case .topNotFound: return "`top` was not found on PATH"
            case .processExited: return "the sampled process exited during the sampling window"
            case .parseFailure(let detail): return "could not parse `top` output: \(detail)"
            }
        }
    }

    /// Samples `pid` once a second for `windowSeconds`, discarding the first
    /// reading (top's first `-l` sample is a since-launch average, not an
    /// interval delta, and mixing it in would understate every rate).
    ///
    /// - Parameter timeoutMargin: extra time given to `top` beyond the window
    ///   itself, to absorb process-launch and formatting overhead before
    ///   this is treated as a hang rather than a slow sample.
    public static func sample(
        pid: Int32, windowSeconds: Int, timeoutMargin: TimeInterval = 15
    ) throws -> ProcessSampleWindow {
        guard let top = Subprocess.which("top") else { throw SamplingError.topNotFound }
        // -stats restricts (and orders) the columns; parsing below depends on
        // exactly this order. -l N takes N samples, 1 second apart (-s 1).
        let arguments = [
            "-l", String(windowSeconds + 1), "-s", "1", "-pid", String(pid),
            "-stats", "pid,cpu,rsize,idlew",
        ]
        let result = try Subprocess.run(
            top, arguments, timeout: Double(windowSeconds) + timeoutMargin)
        guard result.succeeded else {
            throw SamplingError.parseFailure(result.failureSummary)
        }
        let rows = try parse(result.stdoutText, expectedPID: pid)
        guard rows.count > 1 else {
            // A process that exited between the check and the first sample
            // shows up here as "top produced only its own since-launch row".
            throw rows.isEmpty ? SamplingError.processExited : SamplingError.parseFailure("only one sample")
        }
        return ProcessSampleWindow(samples: Array(rows.dropFirst()), droppedFirstSample: true)
    }

    /// Parses the `-stats pid,cpu,rsize,idlew` table. `top` repeats the
    /// column header before every sample block, so this scans for data rows
    /// (the ones that literally start with the pid we asked for) rather than
    /// trying to segment the output by header.
    static func parse(_ text: String, expectedPID: Int32) throws -> [ProcessSample] {
        var rows: [ProcessSample] = []
        var sawIdlewColumn = false
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 3, let pid = Int32(fields[0]), pid == expectedPID else { continue }
            guard let cpu = Double(fields[1]) else { continue }
            let residentBytes = parseByteCount(fields[2])
            var idleWakeups: Double?
            if fields.count >= 4, let value = Double(fields[3]) {
                idleWakeups = value
                sawIdlewColumn = true
            }
            rows.append(ProcessSample(pid: pid, cpuPercent: cpu, residentBytes: residentBytes, idleWakeups: idleWakeups))
        }
        if !rows.isEmpty, !sawIdlewColumn {
            // Leave idleWakeups nil on every row (already the case) rather
            // than throwing — CPU and RSS are still honest measurements even
            // when this macOS's `top` omits IDLEW.
        }
        return rows
    }

    /// `top`'s `RSIZE`/`MEM` formatting: a number followed by K/M/G/T (binary units).
    private static func parseByteCount(_ token: String) -> Int64 {
        guard let unitChar = token.last, "KMGT".contains(unitChar) else {
            return Int64(Double(token) ?? 0)
        }
        let numberPart = String(token.dropLast())
        guard let value = Double(numberPart) else { return 0 }
        let multiplier: Double
        switch unitChar {
        case "K": multiplier = 1024
        case "M": multiplier = 1024 * 1024
        case "G": multiplier = 1024 * 1024 * 1024
        case "T": multiplier = 1024 * 1024 * 1024 * 1024
        default: multiplier = 1
        }
        return Int64(value * multiplier)
    }
}
