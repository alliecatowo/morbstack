// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// git-status-bindmount: `git status` on a VirtioFS bind mount, against the
// same repository copied onto guest-native storage (a Docker named volume),
// expressed as a ratio. "vs. native Linux" in the public target table (see
// docs/roadmap.md) means exactly that comparison — the guest is already
// Linux, so the honest baseline for "how much does the Mac-side bind mount
// cost" is the same filesystem call inside the same guest kernel, minus the
// VirtioFS hop, not a comparison against a different OS entirely.
//
// No upstream image ships both `git` and the coreutils this harness already
// leans on (see EngineHelpers.swift's file comment), so this benchmark
// builds one itself with `apk add git` and `commit`s it — the one narrow use
// of `EngineHelpers.commit` in the whole suite — then removes that tag when
// it is done. Every timed sample is one full container create/start/wait/
// remove cycle via `EngineHelpers.runOnce`, deliberately not `exec` into a
// long-lived container (see EngineHelpers.swift: "No attach, no exec"); the
// per-container overhead is identical on both legs, so it washes out of the
// bind-vs-volume *ratio* even though it is not washed out of either leg's
// absolute number.

import Foundation
import MorbFeatures
import MorbstackKit

public struct GitStatusBindmountBenchmark: Benchmark {
    public let name = "git-status-bindmount"
    public let summary =
        "`git status` on a bind-mounted repo vs. the same repo on a named volume, as a ratio."
    public let cost =
        "builds and removes a one-off `git`-capable image (needs network the first time), creates a "
        + "scratch host directory under /private/tmp and a scratch named volume, runs `--runs` (default 5) "
        + "timed containers per leg; needs an idle engine"

    private static let baseImage = "alpine:3.20"
    private static let builtImageRepo = "morbstack-bench-git-status"
    private static let builtImageTag = "bench"
    private static let fileCount = 200

    public init() {}

    public func plan(_ context: BenchContext) -> [String] {
        [
            "confirm the engine is running with no other containers active",
            "pull \(Self.baseImage) if not cached, `apk add --no-cache git`, commit as "
                + "\(Self.builtImageRepo):\(Self.builtImageTag)",
            "create a scratch host directory under /private/tmp with \(Self.fileCount) small files, "
                + "`git init` and commit it there (this is the bind-mount leg's repo)",
            "create a scratch named volume, copy the same repo into it with `cp -a` (this is the "
                + "native-storage leg's repo)",
            "\(context.runs)x `git status` in a throwaway container bind-mounting the host directory",
            "\(context.runs)x `git status` in a throwaway container mounting the named volume",
            "report the ratio of the two medians against the <= 2x native target",
            "remove the scratch host directory, the scratch volume, and the built image",
        ]
    }

    public func run(_ context: BenchContext) -> BenchResult {
        let overallStart = Date()
        let availability = StackGuard.probe()
        if let reason = StackGuard.idleMeasurementBlockReason(availability) {
            return .skipped(name: name, reason: reason)
        }

        let engine = context.engine()
        let hostDirectory = URL(
            fileURLWithPath: "/private/tmp/morbstack-bench-git-\(UUID().uuidString)", isDirectory: true)
        let volumeName = "morbstack-bench-git-\(UUID().uuidString.prefix(8))"
        var builtImage = false
        var notes: [String] = []

        defer {
            try? FileManager.default.removeItem(at: hostDirectory)
            EngineHelpers.removeVolume(engine, name: volumeName)
            if builtImage { EngineHelpers.removeImage(engine, reference: "\(Self.builtImageRepo):\(Self.builtImageTag)") }
        }

        do {
            let pulled = try Self.buildGitImage(engine)
            builtImage = true
            notes.append(
                pulled
                    ? "pulled \(Self.baseImage) and installed git — the guest had not cached it"
                    : "\(Self.baseImage) was already cached in the guest; installing git still needed the network")

            try Self.populateRepo(at: hostDirectory)
            try Self.gitInitAndCommit(engine, image: Self.gitImage, hostDirectory: hostDirectory)
            try EngineHelpers.ensureVolume(engine, name: volumeName)
            try Self.copyIntoVolume(engine, image: Self.gitImage, hostDirectory: hostDirectory, volumeName: volumeName)
        } catch {
            return .skipped(name: name, reason: "setup failed: \(error)", notes: notes)
        }

        let bind: Distribution
        let volume: Distribution
        do {
            bind = try Self.timedRuns(
                engine, count: context.runs, image: Self.gitImage,
                binds: ["\(hostDirectory.path):/repo"], workingDir: "/repo")
            volume = try Self.timedRuns(
                engine, count: context.runs, image: Self.gitImage,
                binds: ["\(volumeName):/repo"], workingDir: "/repo")
        } catch {
            return .skipped(name: name, reason: "timed `git status` run failed: \(error)", notes: notes)
        }

        guard volume.median > 0 else {
            return .skipped(
                name: name, reason: "the native-volume leg measured 0s per run, which cannot be a real "
                    + "duration; refusing to divide by it", notes: notes)
        }
        let ratio = bind.median / volume.median
        notes.append(
            "each sample is one full container create/start/wait/remove cycle (no `exec`); that per-"
                + "container overhead is identical on both legs and is included in both absolute numbers "
                + "below, but cancels out of the ratio to first order")
        notes.append("bind mount leg: " + bind.rendered(formatter: Format.duration))
        notes.append("native volume leg: " + volume.rendered(formatter: Format.duration))

        return .measured(
            name: name, value: ratio, target: Targets.gitStatusBindmount,
            summary: String(format: "%.2fx native (bind median %@ / volume median %@)", ratio,
                Format.duration(bind.median), Format.duration(volume.median)),
            notes: notes,
            createdArtifacts: [
                "one throwaway container per sample (removed after each)",
                "a scratch \(Self.builtImageRepo):\(Self.builtImageTag) image (removed at the end)",
                "a scratch host directory under /private/tmp (removed at the end)",
                "a scratch named volume (removed at the end)",
            ],
            metrics: [
                "bind_median_seconds": .double(bind.median), "volume_median_seconds": .double(volume.median),
            ],
            durationSeconds: Date().timeIntervalSince(overallStart))
    }

    /// A minimal error carrier for this file's setup/timing helpers — `BenchError`
    /// (RunRecord.swift) is scoped to `compare`'s stored-run resolution and its
    /// messages would be misleading here.
    private struct StepFailed: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static var gitImage: String { "\(builtImageRepo):\(builtImageTag)" }

    /// Builds the one-off `git`-capable image this benchmark needs, since no
    /// upstream image ships both `git` and the shell/coreutils used elsewhere
    /// in this harness. Returns whether the base image had to be pulled.
    private static func buildGitImage(_ engine: EngineClient) throws -> Bool {
        let (pulled, _) = try EngineHelpers.ensureImage(engine, reference: baseImage)
        let id = try EngineHelpers.createAndStart(
            engine, image: baseImage, command: ["sh", "-c", "apk add --no-cache git >/dev/null 2>&1"])
        let exitCode = try EngineHelpers.wait(engine, id: id)
        guard exitCode == 0 else {
            let logs = try? EngineHelpers.collectLogs(engine, id: id)
            EngineHelpers.removeContainer(engine, id: id)
            throw StepFailed(
                message: "apk add git exited \(exitCode): \(Format.truncate(logs?.stderr ?? "", 200))")
        }
        try EngineHelpers.commit(engine, container: id, repo: builtImageRepo, tag: builtImageTag)
        EngineHelpers.removeContainer(engine, id: id)
        return pulled
    }

    /// Writes a small synthetic source tree directly from the host side —
    /// the scratch directory is VirtioFS-shared into the guest by default
    /// (`/private/tmp` is in `MorbShares.defaultSharedPaths`), so nothing
    /// guest-side needs to run to create the files themselves.
    private static func populateRepo(at directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<fileCount {
            let subdirectory = directory.appendingPathComponent("dir\(index % 20)", isDirectory: true)
            if !manager.fileExists(atPath: subdirectory.path) {
                try manager.createDirectory(at: subdirectory, withIntermediateDirectories: true)
            }
            let file = subdirectory.appendingPathComponent("file\(index).txt")
            try "synthetic benchmark content \(index)\n".write(to: file, atomically: true, encoding: .utf8)
        }
    }

    private static func gitInitAndCommit(_ engine: EngineClient, image: String, hostDirectory: URL) throws {
        let command = [
            "sh", "-c",
            "git init -q && git add -A && "
                + "git -c user.email=bench@morbstack.local -c user.name=morbstack-bench commit -q -m init",
        ]
        let outcome = try EngineHelpers.runOnce(
            engine, image: image, command: command, binds: ["\(hostDirectory.path):/repo"], workingDir: "/repo")
        guard outcome.exitCode == 0 else {
            throw StepFailed(message: "git init/commit exited \(outcome.exitCode): \(Format.truncate(outcome.stderr, 200))")
        }
    }

    private static func copyIntoVolume(_ engine: EngineClient, image: String, hostDirectory: URL, volumeName: String) throws {
        let outcome = try EngineHelpers.runOnce(
            engine, image: image, command: ["sh", "-c", "cp -a /repo/. /native/"],
            binds: ["\(hostDirectory.path):/repo:ro", "\(volumeName):/native"])
        guard outcome.exitCode == 0 else {
            throw StepFailed(message: "copy into volume exited \(outcome.exitCode): \(Format.truncate(outcome.stderr, 200))")
        }
    }

    /// Times `count` independent `git status` runs, each its own throwaway
    /// container. See the file comment for why per-container overhead is an
    /// accepted, and cancelling, cost here.
    private static func timedRuns(
        _ engine: EngineClient, count: Int, image: String, binds: [String], workingDir: String
    ) throws -> Distribution {
        var samples: [Double] = []
        samples.reserveCapacity(count)
        for _ in 0..<count {
            let started = Date()
            let outcome = try EngineHelpers.runOnce(
                engine, image: image, command: ["git", "status"], binds: binds, workingDir: workingDir)
            let elapsed = Date().timeIntervalSince(started)
            guard outcome.exitCode == 0 else {
                throw StepFailed(message: "git status exited \(outcome.exitCode): \(Format.truncate(outcome.stderr, 200))")
            }
            samples.append(elapsed)
        }
        guard let distribution = Distribution(samples: samples) else {
            throw StepFailed(message: "no samples collected")
        }
        return distribution
    }
}
