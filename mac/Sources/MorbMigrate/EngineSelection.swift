// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Turning `--from <runtime|socket-path>` into an actual engine to read from.
// `morb migrate` only ever writes to Morbstack's own engine — the destination is never
// a flag, precisely so there is no argument order a user can get backwards that would
// send Morbstack's images *into* Docker Desktop.

import Foundation
import MorbFeatures

/// A resolved migration source: something to read images/volumes/config out of.
struct MigrationSource {
    var label: String
    var client: EngineClient
    var socketPath: String
}

enum SourceResolutionError: Error, CustomStringConvertible {
    case notFound(String)
    case notRunning(String)
    case ambiguous([String])

    var description: String {
        switch self {
        case .notFound(let m): return m
        case .notRunning(let m): return m
        case .ambiguous(let names):
            return "more than one other runtime is running (\(names.joined(separator: ", "))); "
                + "pick one with --from"
        }
    }
}

enum SourceResolver {

    /// Resolves `--from`, or auto-picks the one other runtime that is actually running
    /// when no `--from` was given.
    ///
    /// Accepts the well-known runtime names (case-insensitive, a couple of aliases for
    /// the ones people actually type) or a bare socket path / `unix://` URL, so
    /// `--from /path/to/some/other/docker.sock` works for a runtime this module has
    /// never heard of.
    static func resolve(from token: String?) throws -> MigrationSource {
        if let token {
            return try resolveNamed(token)
        }
        return try autoDetect()
    }

    private static func resolveNamed(_ token: String) throws -> MigrationSource {
        let lower = token.lowercased()
        switch lower {
        case "docker-desktop", "desktop", "docker":
            let report = RuntimeDetect.detectDockerDesktop()
            return try require(report)
        case "colima":
            let report = RuntimeDetect.detectColima()
            return try require(report)
        case "orbstack", "orb":
            let report = RuntimeDetect.detectOrbStack()
            return try require(report)
        case "morbstack":
            let report = RuntimeDetect.detectMorbstack()
            return try require(report)
        default:
            // Not a known name — treat it as a socket path. `unix://` is stripped so
            // `--from unix:///path/to/docker.sock` (what a docker context's Host field
            // looks like) works without the caller having to know that detail.
            var path = token
            if path.hasPrefix("unix://") { path = String(path.dropFirst("unix://".count)) }
            path = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else {
                throw SourceResolutionError.notFound("no socket at \(path)")
            }
            let client = EngineClient(socketPath: path)
            guard client.ping(timeout: 5) else {
                throw SourceResolutionError.notRunning("\(path) exists but did not answer a ping")
            }
            return MigrationSource(label: path, client: client, socketPath: path)
        }
    }

    private static func require(_ report: RuntimeReport) throws -> MigrationSource {
        guard report.installed else {
            throw SourceResolutionError.notFound("\(report.name) does not appear to be installed on this Mac")
        }
        guard report.running, let socketPath = report.socketPath else {
            throw SourceResolutionError.notRunning(
                "\(report.name) is installed but not running (no socket answered a ping) — start it and retry")
        }
        return MigrationSource(label: report.name, client: EngineClient(socketPath: socketPath), socketPath: socketPath)
    }

    /// With no `--from`, the obvious choice when exactly one of Docker Desktop / Colima
    /// / OrbStack is actually running. Two or more running at once is not this module's
    /// call to make silently — it asks.
    private static func autoDetect() throws -> MigrationSource {
        let candidates = [
            RuntimeDetect.detectDockerDesktop(),
            RuntimeDetect.detectColima(),
            RuntimeDetect.detectOrbStack(),
        ].filter(\.running)

        guard !candidates.isEmpty else {
            throw SourceResolutionError.notFound(
                "no other running container runtime was found (checked Docker Desktop, Colima, OrbStack) — "
                    + "pass --from <runtime|socket-path> if it's somewhere this didn't look")
        }
        guard candidates.count == 1, let only = candidates.first, let socketPath = only.socketPath else {
            throw SourceResolutionError.ambiguous(candidates.map(\.name))
        }
        return MigrationSource(label: only.name, client: EngineClient(socketPath: socketPath), socketPath: socketPath)
    }
}
