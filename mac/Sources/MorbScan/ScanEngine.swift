// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Everything that actually runs syft/grype and moves an image from the Morbstack
// guest to a place they can read it. ScanCLI.swift owns argument parsing and
// printing; this file owns process/network side effects, kept behind small
// functions so ScanTests can exercise the pure pieces (env var construction, DB
// status parsing) without a real syft/grype binary on the test machine.

import Foundation
import MorbFeatures
import MorbstackKit

public enum ScanEngineError: Error, CustomStringConvertible {
    case toolMissing(String)
    case toolFailed(String)
    case engine(String)
    case parse(String)
    case offlineDBUnavailable(String)

    public var description: String {
        switch self {
        case .toolMissing(let m): return m
        case .toolFailed(let m): return m
        case .engine(let m): return m
        case .parse(let m): return m
        case .offlineDBUnavailable(let m): return m
        }
    }
}

// MARK: - Paths

/// On-disk locations `morb scan` owns, all under `~/.morbstack` so `MORBSTACK_HOME`
/// redirects them with everything else.
public enum ScanPaths {
    public static var root: URL { MorbPaths.root.appendingPathComponent("scan", isDirectory: true) }

    /// Where grype's vulnerability database is cached. Explicit rather than letting
    /// grype fall back to its own default (`~/Library/Caches/grype/db`) — the local-
    /// only guarantee this feature makes is worth more when the cache location is
    /// something `morb scan --check` can point at directly, and worth more still
    /// when it is *not* a directory shared with some other grype install on the same
    /// machine that this feature has no control over.
    public static var grypeDBCacheDir: URL { root.appendingPathComponent("grype-db", isDirectory: true) }

    /// Scratch space for exported image tarballs and intermediate SBOMs. Never left
    /// populated after a run — see ``ScanRun/cleanUp()``.
    public static var tempDirectory: URL { root.appendingPathComponent("tmp", isDirectory: true) }
}

// MARK: - Environment

/// The environment variables passed to every syft/grype invocation this feature
/// makes — the mechanism behind the "local only" guarantee.
///
/// Verified by reading `syft config` / `grype config`, not assumed: both tools
/// default `check-for-app-update` to `true`, which is a network call on every
/// invocation to see whether a newer release exists, and grype defaults
/// `db.auto-update` to `true`, which is a network call whenever its cached
/// database looks missing or stale. Neither is a secret upload — it is a version
/// check and a signature-verified database fetch — but "not secret" is not the same
/// promise as "does not happen without the user being told", which is what this
/// feature exists to keep.
public enum ScanToolEnvironment {

    /// Vars applied to every syft/grype call regardless of mode.
    public static func base(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = environment
        env["SYFT_CHECK_FOR_APP_UPDATE"] = "false"
        env["GRYPE_CHECK_FOR_APP_UPDATE"] = "false"
        env["GRYPE_DB_CACHE_DIR"] = ScanPaths.grypeDBCacheDir.path
        return env
    }

    /// Vars added on top of ``base(environment:)`` for the actual `grype sbom:...`
    /// scan call. `GRYPE_DB_AUTO_UPDATE` is always forced off here: this feature
    /// runs its own explicit `grype db update` step first (see
    /// ``ScanEngine/ensureDatabase(grype:offline:)``) specifically so that the
    /// moment a network call might happen is announced on its own, separately from
    /// the scan itself, rather than buried inside a `grype` invocation whose output
    /// is being captured and parsed as JSON.
    ///
    /// In `--offline` mode this also disables the database's age gate
    /// (`GRYPE_DB_VALIDATE_AGE`) and the "fail if we can't check for an update" gate
    /// (`GRYPE_DB_REQUIRE_UPDATE_CHECK`). Both exist upstream to protect a *silent*
    /// auto-updating install from running on a dangerously stale database; a user
    /// who explicitly asked for offline mode has already made the opposite
    /// trade-off on purpose; and the age is printed to them either way (see
    /// ``DatabaseStatus/ageDescription``), so the choice is informed rather than
    /// hidden.
    public static func forScan(offline: Bool, base: [String: String]) -> [String: String] {
        var env = base
        env["GRYPE_DB_AUTO_UPDATE"] = "false"
        if offline {
            env["GRYPE_DB_VALIDATE_AGE"] = "false"
            env["GRYPE_DB_REQUIRE_UPDATE_CHECK"] = "false"
        }
        return env
    }
}

// MARK: - Database status

/// `grype db status`, parsed. A pure local read — grype does not reach the network
/// to answer this — so it is safe to call before every scan, and from `--check`,
/// without breaking the local-only guarantee.
public struct DatabaseStatus: Sendable {
    public var present: Bool
    public var valid: Bool
    public var schemaVersion: String?
    public var builtAt: Date?
    public var path: String
    public var errorMessage: String?

    /// `"3h"`, `"6d"`, or `"unknown"` when `builtAt` could not be read.
    public func ageDescription(now: Date = Date()) -> String {
        guard let builtAt else { return "unknown" }
        let seconds = now.timeIntervalSince(builtAt)
        if seconds < 0 { return "just now" }
        let hours = seconds / 3600
        if hours < 48 { return String(format: "%.0fh", hours) }
        return String(format: "%.0fd", hours / 24)
    }

    /// Parses `grype db status -o json`'s document. Tolerant of the "database does
    /// not exist" shape (`valid: false`, no `built`/`schemaVersion`) as well as the
    /// healthy one, since ``ScanEngine/databaseStatus(grype:)`` calls this on grype's
    /// stdout regardless of its exit code — grype exits 1 for a missing database but
    /// still prints the same JSON shape describing that fact.
    public static func parse(_ data: Data) -> DatabaseStatus? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let path = object["path"] as? String ?? ScanPaths.grypeDBCacheDir.path
        let valid = (object["valid"] as? Bool) ?? false
        let schema = object["schemaVersion"] as? String
        var builtAt: Date?
        if let builtRaw = object["built"] as? String, !builtRaw.isEmpty {
            builtAt = ISO8601DateFormatter().date(from: builtRaw)
        }
        let present = builtAt != nil || (schema != nil && !(schema ?? "").isEmpty)
        return DatabaseStatus(
            present: present, valid: valid, schemaVersion: schema, builtAt: builtAt, path: path,
            errorMessage: object["error"] as? String)
    }
}

// MARK: - Image export

public struct ExportedImage {
    public var path: URL
    public var bytes: Int64
}

/// Everything `morb scan` and `morb scan --check` do that is not pure logic:
/// exporting an image out of the Morbstack guest, running syft/grype, and reading
/// grype's local database state.
public enum ScanEngine {

    /// Streams `image` out of the Morbstack engine as a `docker save` tar, so
    /// syft/grype — which run on the Mac, not inside the guest VM the image
    /// actually lives in — have a `docker-archive:` path to point at. This is the
    /// only way these tools can see an image without either running inside the
    /// guest (they do not; they are Mac binaries) or Morbstack exposing the guest's
    /// containerd content store directly (it does not, deliberately: the Engine API
    /// is the one supported surface).
    ///
    /// The caller owns cleanup of the returned path — always, including on every
    /// error path after this returns, since a failed scan is exactly when a
    /// multi-hundred-MB tar is most likely to otherwise be left behind in
    /// `~/.morbstack/scan/tmp`.
    public static func exportImage(
        _ image: String, engine: EngineClient, onProgress: ((Int64) -> Void)? = nil
    ) throws -> ExportedImage {
        try FileManager.default.createDirectory(at: ScanPaths.tempDirectory, withIntermediateDirectories: true)
        let dest = ScanPaths.tempDirectory.appendingPathComponent("morb-scan-\(UUID().uuidString).tar")
        do {
            let (_, bytes) = try engine.download(
                "GET", "/images/\(image)/get", to: dest, timeout: 1800,
                onProgress: { total in
                    onProgress?(total)
                    return true
                })
            return ExportedImage(path: dest, bytes: bytes)
        } catch let error as EngineError {
            throw ScanEngineError.engine("exporting \(image) from the Morbstack engine: \(error.description)")
        }
    }

    /// Runs syft against an exported image archive, producing syft's own JSON SBOM
    /// document (the "syft-json" format grype's `sbom:` source scheme reads). Writes
    /// it to `sbomOutPath` when the caller wants to keep the SBOM around, but always
    /// returns the bytes too so a `--sbom-only` run does not have to re-read the
    /// file it just asked syft to write.
    public static func runSyft(
        archivePath: String, syft: LocatedTool, environment: [String: String]
    ) throws -> Data {
        let args = ["scan", "docker-archive:\(archivePath)", "-o", "json", "-q"]
        let result = try Subprocess.run(syft.path, args, environment: environment, timeout: 900)
        guard result.succeeded else {
            throw ScanEngineError.toolFailed("syft " + result.failureSummary)
        }
        guard !result.stdout.isEmpty else {
            throw ScanEngineError.toolFailed("syft produced no output for \(archivePath)")
        }
        return result.stdout
    }

    /// `grype db status`, read without ever touching the network — the vulnerability
    /// database is either on disk under ``ScanPaths/grypeDBCacheDir`` or it is not;
    /// this only looks.
    public static func databaseStatus(grype: LocatedTool) -> DatabaseStatus {
        let env = ScanToolEnvironment.base()
        let result = try? Subprocess.run(grype.path, ["db", "status", "-o", "json"], environment: env, timeout: 15)
        guard let result, let parsed = DatabaseStatus.parse(result.stdout) else {
            return DatabaseStatus(
                present: false, valid: false, schemaVersion: nil, builtAt: nil,
                path: ScanPaths.grypeDBCacheDir.path, errorMessage: "could not read grype db status")
        }
        return parsed
    }

    /// Makes sure a usable vulnerability database is on disk before the scan proper
    /// runs, and is the one place this feature's network call is made — the rest of
    /// a scan (image export aside, which talks to the Morbstack engine, not the
    /// internet) never touches the network.
    ///
    /// - Parameter announce: called with a one-line status the caller should print
    ///   immediately, before the (possibly slow) update runs — this is the
    ///   "explicit" half of "no telemetry, no silent fetches": the fetch still
    ///   happens, but never without the user seeing why.
    /// - Returns: the database status *after* the update attempt.
    public static func ensureDatabase(
        grype: LocatedTool, offline: Bool, announce: (String) -> Void
    ) throws -> DatabaseStatus {
        let statusBefore = databaseStatus(grype: grype)

        if offline {
            guard statusBefore.present else {
                throw ScanEngineError.offlineDBUnavailable(
                    "no cached vulnerability database at \(statusBefore.path) and --offline was given; "
                        + "run `morb scan` once without --offline to fetch one, or `morb scan --check` for details")
            }
            announce(
                "[offline] using the cached vulnerability database as-is (built "
                    + "\(statusBefore.builtAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"), "
                    + "\(statusBefore.ageDescription()) old) — no network call")
            return statusBefore
        }

        if !statusBefore.present {
            announce(
                "[net] no local vulnerability database found; fetching from grype's database service "
                    + "(this downloads data, nothing is uploaded) into \(ScanPaths.grypeDBCacheDir.path) ...")
        } else {
            announce(
                "[net] checking for a newer vulnerability database (cached copy is "
                    + "\(statusBefore.ageDescription()) old; checking https://grype.anchore.io) ...")
        }

        let env = ScanToolEnvironment.base()
        let result = try Subprocess.run(grype.path, ["db", "update"], environment: env, timeout: 600)
        guard result.succeeded else {
            throw ScanEngineError.toolFailed("grype db update " + result.failureSummary)
        }
        let message = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty { announce("      " + message) }

        return databaseStatus(grype: grype)
    }

    /// Runs grype against a syft SBOM already on disk, returning its parsed
    /// `-o json` document. Always called with `GRYPE_DB_AUTO_UPDATE=false` — the
    /// database was already handled by ``ensureDatabase(grype:offline:announce:)`` —
    /// so this step touches no network in either mode.
    public static func runGrype(
        sbomPath: String, grype: LocatedTool, offline: Bool
    ) throws -> Data {
        let env = ScanToolEnvironment.forScan(offline: offline, base: ScanToolEnvironment.base())
        let args = ["sbom:\(sbomPath)", "-o", "json", "-q"]
        let result = try Subprocess.run(grype.path, args, environment: env, timeout: 600)
        guard result.exitCode == 0 else {
            throw ScanEngineError.toolFailed("grype " + result.failureSummary)
        }
        return result.stdout
    }
}
