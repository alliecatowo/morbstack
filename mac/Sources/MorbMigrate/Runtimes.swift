// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// `morb migrate detect` and everything else in this module that needs to know what
// else is on the machine. Every probe here is read-only and every probe here is
// allowed to fail quietly: "Colima is not installed" and "Docker Desktop is installed
// but not running" are both completely ordinary answers, not errors to surface.
//
// This file never writes anything. The one function that touches disk at all
// (`ensureDirectory`, used elsewhere) lives in MorbFeatures, not here.

import Foundation
import MorbFeatures
import MorbstackKit

/// What is known about one container runtime after probing it.
///
/// `running`/`engineVersion`/counts are only meaningful when `installed` is true and a
/// socket actually answered; a runtime that is merely installed but not running reports
/// zeros for those fields rather than `nil`, because "0 images" and "did not ask" need
/// to stay visibly different — hence `running` gates whether the count fields were
/// populated at all, not just whether they are non-zero.
public struct RuntimeReport: Sendable {
    public var name: String
    public var installed: Bool
    public var installPath: String?
    /// Every socket path this runtime was looked for at, in probe order.
    public var socketCandidates: [String]
    /// The one that actually answered `_ping`, if any.
    public var socketPath: String?
    public var running: Bool
    public var engineVersion: String?
    public var apiVersion: String?
    public var images: Int?
    public var containers: Int?
    public var volumes: Int?
    public var imageBytes: Int64?
    /// Free-form observations worth printing — "credsStore is desktop", "colima binary
    /// not on PATH", and the like. Never a substitute for a proper field; used for the
    /// things that are genuinely one-offs.
    public var notes: [String] = []

    static func absent(_ name: String, socketCandidates: [String] = []) -> RuntimeReport {
        RuntimeReport(
            name: name, installed: false, installPath: nil,
            socketCandidates: socketCandidates, socketPath: nil, running: false,
            engineVersion: nil, apiVersion: nil, images: nil, containers: nil,
            volumes: nil, imageBytes: nil)
    }
}

public enum RuntimeDetect {

    /// Probes every socket in `candidates` in order and returns the first that answers
    /// `_ping`, alongside its version document. Every candidate is tried — a stale
    /// socket file left behind by a crashed daemon does not stop the next one from
    /// being checked.
    static func firstLiveSocket(_ candidates: [String]) -> (path: String, client: EngineClient)? {
        for path in candidates {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let client = EngineClient(socketPath: path)
            if client.ping(timeout: 3) {
                return (path, client)
            }
        }
        return nil
    }

    /// Fills in the `running`/count fields of an already-`installed` report from a live
    /// engine. Any single failed call (a `/system/df` that times out on a busy daemon)
    /// degrades that one field to `nil` rather than failing detection outright.
    private static func populateLiveStats(_ report: inout RuntimeReport, client: EngineClient, socketPath: String) {
        report.socketPath = socketPath
        report.running = true
        if let version = client.version() {
            report.engineVersion = JSONRead.string(version, "Version")
            report.apiVersion = JSONRead.string(version, "ApiVersion")
        }
        if let df = try? client.jsonObject("GET", "/system/df", timeout: 10) {
            let images = JSONRead.array(df, "Images") ?? []
            let containers = JSONRead.array(df, "Containers") ?? []
            let volumes = JSONRead.array(df, "Volumes") ?? []
            report.images = images.count
            report.containers = containers.count
            report.volumes = volumes.count
            report.imageBytes = images.reduce(Int64(0)) { total, entry in
                total + Int64(JSONRead.int(entry, "Size") ?? 0)
            }
        }
    }

    // MARK: - Docker Desktop

    /// Docker Desktop's two documented socket locations, in the order it prefers them:
    /// `~/.docker/run/docker.sock` since Desktop 4.13, falling back to the classic
    /// `/var/run/docker.sock` for older installs or the "default Docker socket" setting.
    /// Never assumed — both are probed with a real `_ping`, per this module's brief.
    public static func dockerDesktopSocketCandidates() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.docker/run/docker.sock", "/var/run/docker.sock"]
    }

    public static func detectDockerDesktop() -> RuntimeReport {
        let appPath = "/Applications/Docker.app"
        let installed = FileManager.default.fileExists(atPath: appPath)
        var report = RuntimeReport.absent("Docker Desktop", socketCandidates: dockerDesktopSocketCandidates())
        report.installed = installed
        report.installPath = installed ? appPath : nil

        if let (path, client) = firstLiveSocket(dockerDesktopSocketCandidates()) {
            populateLiveStats(&report, client: client, socketPath: path)
            if !installed {
                // Something is answering on Desktop's socket even though the app bundle
                // is not where it usually lives — worth a note rather than silently
                // reporting `installed: false, running: true`, which reads like a bug.
                report.notes.append("a docker engine is answering at \(path) even though \(appPath) was not found")
            }
        } else if installed {
            report.notes.append("installed but not running (no socket answered a ping)")
        }
        return report
    }

    // MARK: - Colima

    public static func colimaSocketCandidates() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.colima/default/docker.sock"]
    }

    public static func detectColima() -> RuntimeReport {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let colimaDir = "\(home)/.colima"
        let installed = FileManager.default.fileExists(atPath: colimaDir) || Subprocess.which("colima") != nil
        var report = RuntimeReport.absent("Colima", socketCandidates: colimaSocketCandidates())
        report.installed = installed
        report.installPath = Subprocess.which("colima")
        if Subprocess.which("colima") == nil, FileManager.default.fileExists(atPath: colimaDir) {
            report.notes.append("~/.colima exists but the `colima` binary is not on PATH")
        }

        if let (path, client) = firstLiveSocket(colimaSocketCandidates()) {
            populateLiveStats(&report, client: client, socketPath: path)
        } else if installed {
            report.notes.append("installed but not running (no socket answered a ping)")
        }
        return report
    }

    // MARK: - OrbStack

    public static func orbStackSocketCandidates() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.orbstack/run/docker.sock"]
    }

    public static func detectOrbStack() -> RuntimeReport {
        let appPath = "/Applications/OrbStack.app"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let installed = FileManager.default.fileExists(atPath: appPath)
            || FileManager.default.fileExists(atPath: "\(home)/.orbstack")
        var report = RuntimeReport.absent("OrbStack", socketCandidates: orbStackSocketCandidates())
        report.installed = installed
        report.installPath = installed ? appPath : nil

        if let (path, client) = firstLiveSocket(orbStackSocketCandidates()) {
            populateLiveStats(&report, client: client, socketPath: path)
        } else if installed {
            report.notes.append("installed but not running (no socket answered a ping)")
        }
        return report
    }

    // MARK: - Morbstack itself

    public static func detectMorbstack() -> RuntimeReport {
        var report = RuntimeReport.absent("Morbstack", socketCandidates: [MorbPaths.dockerSocket.path])
        report.installed = true  // this binary would not be running otherwise
        let daemonUp = UnixSocketClient.isAlive(path: MorbPaths.controlSocket.path, timeout: 1)
        if !daemonUp {
            report.notes.append("morbstackd is not running — `morb start` before migrating anything into it")
            return report
        }
        let client = EngineClient()
        if client.ping(timeout: 3) {
            populateLiveStats(&report, client: client, socketPath: MorbPaths.dockerSocket.path)
        } else {
            report.notes.append("morbstackd is running but its docker engine is not answering yet")
        }
        return report
    }
}

// MARK: - ~/.docker/contexts/meta/*/meta.json

/// One entry from the docker CLI's context store, read directly off disk.
///
/// `docker context ls` gets this by shelling out to a running `docker` binary this
/// module has no reason to require; parsing the same files the CLI itself reads is the
/// zero-dependency equivalent, and it is read-only by construction — there is no write
/// path through this type at all.
public struct DockerContextEntry: Sendable {
    public var name: String
    public var host: String?
    public var metaFile: String
}

public enum DockerContextsStore {

    /// Reads every `meta.json` under `<dockerConfigDir>/contexts/meta/*/`.
    ///
    /// A directory that fails to parse is skipped, not fatal — one context some other
    /// tool wrote in a shape this does not expect should not hide every other context
    /// from the report.
    public static func readAll(dockerConfigDirectory: URL) -> [DockerContextEntry] {
        let metaRoot = dockerConfigDirectory.appendingPathComponent("contexts", isDirectory: true)
            .appendingPathComponent("meta", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: metaRoot, includingPropertiesForKeys: nil)
        else { return [] }

        var results: [DockerContextEntry] = []
        for directory in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let metaFile = directory.appendingPathComponent("meta.json", isDirectory: false)
            guard let data = try? Data(contentsOf: metaFile),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = object["Name"] as? String
            else { continue }
            let endpoints = object["Endpoints"] as? [String: Any]
            let docker = endpoints?["docker"] as? [String: Any]
            let host = docker?["Host"] as? String
            results.append(DockerContextEntry(name: name, host: host, metaFile: metaFile.path))
        }
        return results
    }
}

// MARK: - ~/.docker/config.json

/// The fields of `~/.docker/config.json` migrate cares about, and nothing more —
/// deliberately not a general model of the file. Every field here is either purely
/// informational (`currentContext`, `proxies`) or reported by *presence* only
/// (`registriesWithAuth` is the auth map's keys; the credential values are never read
/// into this struct, let alone printed — see ``ConfigCommand``).
public struct DockerCLIConfig: Sendable {
    public var path: String
    public var currentContext: String
    public var credsStore: String?
    public var credHelperRegistries: [String]
    /// Names of proxy contexts in Docker's configuration. Values are deliberately
    /// never retained: this report needs to say that proxy configuration exists,
    /// not read or expose proxy endpoints.
    public var proxies: [String]
    public var cliPluginsExtraDirs: [String]
    public var registriesWithAuth: [String]

    /// Docker Desktop's credential helper. When this is the active `credsStore` and
    /// Desktop is not running, every `docker` invocation that needs a registry
    /// credential hangs forever waiting on `docker-credential-desktop` — the exact
    /// failure mode README.md's Troubleshooting section documents, and precisely the
    /// moment a migration should be shouting about it rather than after the fact.
    public var credsStoreIsDesktopHelper: Bool { credsStore == "desktop" }
}

public enum DockerCLIConfigReader {

    /// `$DOCKER_CONFIG`, or `~/.docker` — matches `MorbDockerContext.dockerConfigDirectory`
    /// (mac/Sources/MorbstackKit/MorbDockerContext.swift) exactly, so a report produced
    /// here and a context write performed by `morb context` are always talking about the
    /// same file.
    public static func dockerConfigDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["DOCKER_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".docker", isDirectory: true)
    }

    /// Reads and parses `config.json`. `nil` when the file is absent, empty, or not
    /// valid JSON — all three are normal for a machine that has never run `docker`
    /// pointed anywhere but its default socket.
    public static func read(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DockerCLIConfig? {
        let dir = dockerConfigDirectory(environment: environment)
        let file = dir.appendingPathComponent("config.json", isDirectory: false)
        guard let data = try? Data(contentsOf: file), !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let credHelpers = (object["credHelpers"] as? [String: Any])?.keys.sorted() ?? []
        let auths = (object["auths"] as? [String: Any])?.keys.sorted() ?? []
        let pluginDirs = (object["cliPluginsExtraDirs"] as? [Any])?.compactMap { $0 as? String } ?? []
        let current = (object["currentContext"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "default"

        return DockerCLIConfig(
            path: file.path,
            currentContext: current,
            credsStore: object["credsStore"] as? String,
            credHelperRegistries: credHelpers,
            proxies: (object["proxies"] as? [String: Any])?.keys.sorted() ?? [],
            cliPluginsExtraDirs: pluginDirs,
            registriesWithAuth: auths)
    }
}
