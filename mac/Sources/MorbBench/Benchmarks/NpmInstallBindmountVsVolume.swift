// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// npm-install-bindmount-vs-volume: `npm install` writing into a VirtioFS
// bind mount, against the same install writing into a Docker named volume
// (guest-native storage), expressed as a ratio — the same "vs. native
// Linux" methodology `git-status-bindmount` uses (see that file's comment
// for why the guest's own filesystem, not a different OS, is the honest
// baseline).
//
// `npm install` is dominated by many small file writes (`node_modules` is
// notoriously file-count-heavy), which is a different I/O shape than
// `git status`'s reads — that is deliberately why the public target table
// carries both rather than one standing in for the other.
//
// The one thing this benchmark controls for that git-status-bindmount does
// not need to: network access to the npm registry would make "how much does
// the bind mount cost" indistinguishable from "how fast is the registry
// today". So the registry is only ever contacted once, to warm a persistent
// npm cache volume shared by every timed sample on both legs; every timed
// `npm install` runs `--offline` against that warm cache.

import Foundation
import MorbFeatures
import MorbstackKit

public struct NpmInstallBindmountVsVolumeBenchmark: Benchmark {
    public let name = "npm-install-bindmount-vs-volume"
    public let summary =
        "`npm install` writing into a bind-mounted project vs. the same install writing into a "
        + "named volume, as a ratio."
    public let cost =
        "pulls \(nodeImage) if not cached, does one real `npm install` against the npm registry to warm "
        + "a persistent cache volume, then runs `--runs` (default 5) offline, cache-warm timed installs "
        + "per leg into fresh node_modules; needs an idle engine and, for the one-time cache warm, network"

    private static let nodeImage = "node:22-alpine"
    /// Small, pure-JS, no native (`node-gyp`) build step — a native build's
    /// compile time would swamp the filesystem-I/O signal this benchmark
    /// exists to isolate. Pinned to exact versions, not `^`, so the warmed
    /// cache and every timed install resolve to the same content every run.
    private static let packageJSON = """
        {
          "name": "morbstack-bench-npm-install",
          "version": "1.0.0",
          "private": true,
          "dependencies": {
            "lodash": "4.17.21",
            "chalk": "4.1.2",
            "commander": "11.1.0"
          }
        }

        """

    public init() {}

    public func plan(_ context: BenchContext) -> [String] {
        [
            "confirm the engine is running with no other containers active",
            "pull \(Self.nodeImage) if not cached",
            "create a scratch host directory under /private/tmp with a small pinned package.json",
            "create a scratch npm-cache named volume and a scratch project named volume",
            "one real `npm install` (network) against the npm-cache volume to warm it, then remove the "
                + "resulting node_modules so both legs start from an identical pre-install state",
            "copy the warmed package.json/package-lock.json into the project volume",
            "\(context.runs)x offline `npm install` into a bind-mounted node_modules",
            "\(context.runs)x offline `npm install` into the project named volume",
            "report the ratio of the two medians against the <= 1.5x native target",
            "remove the scratch host directory, both scratch volumes, and leave the pulled image cached",
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
            fileURLWithPath: "/private/tmp/morbstack-bench-npm-\(UUID().uuidString)", isDirectory: true)
        let suffix = UUID().uuidString.prefix(8)
        let cacheVolume = "morbstack-bench-npm-cache-\(suffix)"
        let projectVolume = "morbstack-bench-npm-project-\(suffix)"
        var notes: [String] = []

        defer {
            try? FileManager.default.removeItem(at: hostDirectory)
            EngineHelpers.removeVolume(engine, name: cacheVolume)
            EngineHelpers.removeVolume(engine, name: projectVolume)
        }

        do {
            let pulled = try Self.ensureNodeImage(engine)
            notes.append(
                pulled ? "pulled \(Self.nodeImage) — the guest had not cached it"
                    : "\(Self.nodeImage) was already cached in the guest")

            try FileManager.default.createDirectory(at: hostDirectory, withIntermediateDirectories: true)
            try Self.packageJSON.write(
                to: hostDirectory.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
            try EngineHelpers.ensureVolume(engine, name: cacheVolume)
            try EngineHelpers.ensureVolume(engine, name: projectVolume)

            try Self.warmCache(engine, hostDirectory: hostDirectory, cacheVolume: cacheVolume)
            notes.append("npm cache warmed with one online `npm install`; every timed sample below runs `--offline`")
            try Self.copyProjectFiles(engine, hostDirectory: hostDirectory, projectVolume: projectVolume)
        } catch {
            return .skipped(name: name, reason: "setup failed: \(error)", notes: notes)
        }

        let bind: Distribution
        let volume: Distribution
        do {
            bind = try Self.timedInstalls(
                engine, count: context.runs, binds: ["\(hostDirectory.path):/repo", "\(cacheVolume):/root/.npm"])
            volume = try Self.timedInstalls(
                engine, count: context.runs, binds: ["\(projectVolume):/repo", "\(cacheVolume):/root/.npm"])
        } catch {
            return .skipped(name: name, reason: "timed `npm install` run failed: \(error)", notes: notes)
        }

        guard volume.median > 0 else {
            return .skipped(
                name: name, reason: "the native-volume leg measured 0s per run, which cannot be a real "
                    + "duration; refusing to divide by it", notes: notes)
        }
        let ratio = bind.median / volume.median
        notes.append(
            "each sample is one full container create/start/wait/remove cycle running "
                + "`rm -rf node_modules && npm install --offline`; the npm cache volume (mounted at "
                + "/root/.npm) is shared by both legs and by every sample, so only filesystem I/O for "
                + "node_modules itself differs between legs, not registry or extraction cost")
        notes.append("bind mount leg: " + bind.rendered(formatter: Format.duration))
        notes.append("native volume leg: " + volume.rendered(formatter: Format.duration))

        return .measured(
            name: name, value: ratio, target: Targets.npmInstall,
            summary: String(
                format: "%.2fx native (bind median %@ / volume median %@)", ratio,
                Format.duration(bind.median), Format.duration(volume.median)),
            notes: notes,
            createdArtifacts: [
                "one throwaway container per sample (removed after each)",
                "a scratch host directory under /private/tmp (removed at the end)",
                "two scratch named volumes: an npm cache and a project volume (removed at the end)",
            ],
            metrics: [
                "bind_median_seconds": .double(bind.median), "volume_median_seconds": .double(volume.median),
            ],
            durationSeconds: Date().timeIntervalSince(overallStart))
    }

    /// A minimal error carrier for this file's setup/timing helpers — see the
    /// identical note in GitStatusBindmount.swift.
    private struct StepFailed: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func ensureNodeImage(_ engine: EngineClient) throws -> Bool {
        let (pulled, _) = try EngineHelpers.ensureImage(engine, reference: nodeImage, timeout: 600)
        return pulled
    }

    /// One real, online `npm install` so `/root/.npm` in `cacheVolume` has every
    /// tarball this package.json needs, then removes the `node_modules` this
    /// produced in `hostDirectory` — leaving only `package.json` and the
    /// `package-lock.json` npm generated, an identical pre-install state to what
    /// every timed sample below starts from.
    private static func warmCache(_ engine: EngineClient, hostDirectory: URL, cacheVolume: String) throws {
        let outcome = try EngineHelpers.runOnce(
            engine, image: nodeImage,
            command: ["sh", "-c", "npm install --no-audit --no-fund --loglevel=error && rm -rf node_modules"],
            binds: ["\(hostDirectory.path):/repo", "\(cacheVolume):/root/.npm"], workingDir: "/repo",
            timeout: 600)
        guard outcome.exitCode == 0 else {
            throw StepFailed(message: "cache warm-up `npm install` exited \(outcome.exitCode): \(Format.truncate(outcome.stderr, 200))")
        }
    }

    /// Copies the warmed `package.json`/`package-lock.json` (no `node_modules`,
    /// already removed by ``warmCache``) into the volume-backed leg's project.
    private static func copyProjectFiles(_ engine: EngineClient, hostDirectory: URL, projectVolume: String) throws {
        let outcome = try EngineHelpers.runOnce(
            engine, image: nodeImage, command: ["sh", "-c", "cp -a /repo/. /native/"],
            binds: ["\(hostDirectory.path):/repo:ro", "\(projectVolume):/native"])
        guard outcome.exitCode == 0 else {
            throw StepFailed(message: "copy into project volume exited \(outcome.exitCode): \(Format.truncate(outcome.stderr, 200))")
        }
    }

    /// Times `count` independent offline installs, each its own throwaway
    /// container — see GitStatusBindmount.swift's file comment for why
    /// per-container overhead is an accepted, ratio-cancelling cost here.
    private static func timedInstalls(_ engine: EngineClient, count: Int, binds: [String]) throws -> Distribution {
        var samples: [Double] = []
        samples.reserveCapacity(count)
        for _ in 0..<count {
            let started = Date()
            let outcome = try EngineHelpers.runOnce(
                engine, image: nodeImage,
                command: ["sh", "-c", "rm -rf node_modules && npm install --offline --no-audit --no-fund --loglevel=error"],
                binds: binds, workingDir: "/repo", timeout: 300)
            let elapsed = Date().timeIntervalSince(started)
            guard outcome.exitCode == 0 else {
                throw StepFailed(message: "npm install --offline exited \(outcome.exitCode): \(Format.truncate(outcome.stderr, 200))")
            }
            samples.append(elapsed)
        }
        guard let distribution = Distribution(samples: samples) else {
            throw StepFailed(message: "no samples collected")
        }
        return distribution
    }
}
