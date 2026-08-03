// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// guest-memory-floor: memory actually in use inside the guest with no
// containers running.
//
// The task brief says to ask the guest via `morb status`/the MRB0 `info`
// reply first. `GuestReply` (IPC.swift) does not carry a memory field at
// all — only uptime, versions, docker/share/rosetta state — so there is
// nothing to read there. The fallback the brief names explicitly is a
// container reading `/proc/meminfo`, which is what this does; the method is
// recorded in the result's notes so nobody mistakes it for a
// zero-overhead reading.

import Foundation
import MorbFeatures
import MorbstackKit

public struct GuestMemoryFloorBenchmark: Benchmark {
    public let name = "guest-memory-floor"
    public let summary = "Memory in use inside the guest with no containers running (MemTotal - MemAvailable)."
    public let cost =
        "pulls alpine:3.19 if not already cached in the guest, runs and removes one throwaway container; "
        + "needs an idle engine"

    /// Pinned so the benchmark is reproducible; a floating `latest` would let
    /// the reading drift with an unrelated base-image update.
    static let image = "alpine:3.19"

    public init() {}

    public func plan(_ context: BenchContext) -> [String] {
        [
            "confirm the engine is running with no containers active",
            "pull \(Self.image) if the guest does not already have it cached",
            "run `cat /proc/meminfo` in one throwaway --rm container, then remove it",
            "compute MemTotal - MemAvailable from its output; the container's own brief presence is the "
                + "one caveat — see the note in the result",
        ]
    }

    public func run(_ context: BenchContext) -> BenchResult {
        let started = Date()
        let availability = StackGuard.probe()
        if let reason = StackGuard.idleMeasurementBlockReason(availability) {
            return .skipped(name: name, reason: reason)
        }

        let engine = context.engine()
        do {
            let (pulled, pullDuration) = try EngineHelpers.ensureImage(engine, reference: Self.image)
            let outcome = try EngineHelpers.runOnce(engine, image: Self.image, command: ["cat", "/proc/meminfo"])
            guard outcome.exitCode == 0 else {
                return .skipped(
                    name: name,
                    reason: "the /proc/meminfo container exited \(outcome.exitCode): "
                        + Format.truncate(outcome.stderr, 200))
            }
            guard let usedBytes = Self.parseUsedBytes(outcome.stdout) else {
                return .skipped(
                    name: name, reason: "could not parse MemTotal/MemAvailable from /proc/meminfo output")
            }
            let notes = [
                "measured via a throwaway container running `cat /proc/meminfo`, since morbinit's "
                    + "guest-control `info` reply (GuestReply, IPC.swift) does not expose a memory field; "
                    + "the container's own brief presence is included in this reading, which is the "
                    + "honest floor of 'the guest with the measurement method itself running', not a "
                    + "perfectly zero-container state",
                pulled
                    ? "pulled \(Self.image) in \(Format.duration(pullDuration)) — the guest had not cached it"
                    : "\(Self.image) was already cached in the guest; no network use",
            ]
            return .measured(
                name: name, value: Double(usedBytes), target: Targets.guestMemoryFloor,
                summary: "\(Format.bytes(usedBytes)) in use (MemTotal - MemAvailable)",
                notes: notes, createdArtifacts: ["one throwaway \(Self.image) container (removed after)"],
                durationSeconds: Date().timeIntervalSince(started))
        } catch {
            return .skipped(name: name, reason: "\(error)")
        }
    }

    /// Parses `/proc/meminfo`'s `Key:  <value> kB` lines for the two fields needed.
    static func parseUsedBytes(_ text: String) -> Int64? {
        var totalKB: Int64?
        var availableKB: Int64?
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let numberToken =
                parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
            guard let value = Int64(numberToken) else { continue }
            if key == "MemTotal" { totalKB = value }
            if key == "MemAvailable" { availableKB = value }
        }
        guard let totalKB, let availableKB else { return nil }
        return (totalKB - availableKB) * 1024
    }
}
