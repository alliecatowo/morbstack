// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Zero-config discovery: writes (and only ever writes on explicit request — see `morb
// context` in mac/Sources/morb/main.swift) a standard Docker CLI context named
// "morbstack" pointing at ``MorbPaths/dockerSocket``, in exactly the on-disk format the
// real `docker` CLI itself uses. Verified against a real `docker context create`/`docker
// context use` run (Docker CLI 27.4.0) rather than assumed from memory:
//
//   ~/.docker/contexts/meta/<sha256-hex of the context name>/meta.json
//     {"Name":"morbstack","Metadata":{},"Endpoints":{"docker":{"Host":"unix://<socket>","SkipTLSVerify":false}}}
//
//   ~/.docker/config.json — "currentContext" key: absent (or "default") means the
//   classic env-var-based default; `docker context use <name>` sets it to that name,
//   and `docker context use default` *removes the key entirely* rather than writing the
//   literal string "default". This module matches both behaviours exactly.
//
// The one rule everything here answers to (docs/compat.md: "Docker contexts are
// respected, never stomped"): ``use(force:environment:)`` refuses to touch
// `currentContext` when it is already set to some *other* explicit context, unless the
// caller passes `force: true` — and even then, only after the CLI has asked the person
// at the keyboard. Nothing in this file ever runs without that gate; see
// `morb context use`.

import CryptoKit
import Foundation

public enum MorbDockerContext {

    /// The context name Morbstack registers itself under.
    public static let name = "morbstack"

    // MARK: - Locations

    /// `$DOCKER_CONFIG`, or `~/.docker` — exactly what the `docker` CLI itself resolves,
    /// so a context written here is a context the CLI will actually find.
    public static func dockerConfigDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["DOCKER_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".docker", isDirectory: true)
    }

    /// `<docker config dir>/config.json`.
    public static func configFile(dockerConfigDirectory: URL) -> URL {
        dockerConfigDirectory.appendingPathComponent("config.json", isDirectory: false)
    }

    /// `<docker config dir>/contexts/meta/<sha256-hex of `name`>/meta.json`.
    ///
    /// The directory name is the context store's own addressing scheme (moby/cli's
    /// `contextdir()`): the hex SHA-256 digest of the context's name, nothing else. Two
    /// different Morbstack installs computing this independently always agree, because
    /// it depends on nothing but the fixed string ``name``.
    public static func metaFile(dockerConfigDirectory: URL) -> URL {
        let digest = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        return dockerConfigDirectory
            .appendingPathComponent("contexts", isDirectory: true)
            .appendingPathComponent("meta", isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
            .appendingPathComponent("meta.json", isDirectory: false)
    }

    // MARK: - meta.json

    /// The exact bytes `docker context create morbstack --docker host=unix://<socket>`
    /// would write, byte-for-byte compatible with what a real `docker` CLI parses back.
    static func metaJSON(socketPath: String) throws -> Data {
        let object: [String: Any] = [
            "Name": name,
            "Metadata": [String: Any](),
            "Endpoints": [
                "docker": [
                    "Host": "unix://\(socketPath)",
                    "SkipTLSVerify": false,
                ]
            ],
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Reads back the `Endpoints.docker.Host` field of an existing meta.json, or `nil`
    /// if the file is absent or not shaped the way this module expects (never guessed
    /// at — an unrecognised file is reported as "no host", not misread as one).
    static func readHost(metaFile: URL) -> String? {
        guard let data = try? Data(contentsOf: metaFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let endpoints = object["Endpoints"] as? [String: Any],
              let docker = endpoints["docker"] as? [String: Any],
              let host = docker["Host"] as? String
        else { return nil }
        return host
    }

    // MARK: - Status

    /// A complete answer to "is the `morbstack` context registered and current".
    public struct Status: Equatable, Sendable {
        /// `~/.docker/contexts/meta/<digest>/meta.json` exists for the `morbstack` name.
        public var registered: Bool
        /// The `Host` the registered context points at, if any.
        public var registeredHost: String?
        /// `registeredHost` equals `unix://<the real Morbstack socket>` — a stale
        /// context (e.g. from before `MORBSTACK_HOME` was changed) reports `registered:
        /// true, matchesSocket: false` rather than being conflated with "not set up".
        public var matchesSocket: Bool
        /// The docker CLI's current context: the literal value of `currentContext` in
        /// `config.json`, or `"default"` when the key is absent (config.json's own
        /// convention — see the module header).
        public var currentContext: String
        /// `currentContext == "morbstack"`.
        public var isCurrent: Bool
        public var dockerConfigDirectory: String
        public var socketPath: String

        /// Whether `use(force: false, ...)` would be refused right now — i.e. some
        /// *other* explicit context already owns default. Mirrors the exact condition
        /// ``use(force:environment:)`` checks, so a caller can explain the situation
        /// before attempting the switch.
        public var wouldRefuseUse: Bool { currentContext != "default" && currentContext != name }
    }

    /// Builds ``Status`` by reading disk. Never writes anything.
    public static func status(
        socketPath: String = MorbPaths.dockerSocket.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Status {
        let configDir = dockerConfigDirectory(environment: environment)
        let meta = metaFile(dockerConfigDirectory: configDir)
        let host = readHost(metaFile: meta)
        let current = currentContextName(dockerConfigDirectory: configDir)
        return Status(
            registered: host != nil,
            registeredHost: host,
            matchesSocket: host == "unix://\(socketPath)",
            currentContext: current,
            isCurrent: current == name,
            dockerConfigDirectory: configDir.path,
            socketPath: socketPath)
    }

    /// `config.json`'s `currentContext`, or `"default"` when absent — see the module
    /// header for why absence is not "unknown", it is Docker's own spelling of
    /// "default".
    static func currentContextName(dockerConfigDirectory: URL) -> String {
        guard let data = try? Data(contentsOf: configFile(dockerConfigDirectory: dockerConfigDirectory)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["currentContext"] as? String,
              !value.isEmpty
        else { return "default" }
        return value
    }

    // MARK: - Mutating operations

    /// `true` when this call actually wrote the file; `false` when it was already
    /// correct and nothing changed.
    ///
    /// Callers (only `morb context create`) are responsible for confirmation before
    /// calling this — it writes unconditionally once invoked.
    @discardableResult
    public static func create(
        socketPath: String = MorbPaths.dockerSocket.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Bool {
        let configDir = dockerConfigDirectory(environment: environment)
        let meta = metaFile(dockerConfigDirectory: configDir)
        if readHost(metaFile: meta) == "unix://\(socketPath)" {
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: meta.deletingLastPathComponent(), withIntermediateDirectories: true)
            try metaJSON(socketPath: socketPath).write(to: meta, options: .atomic)
        } catch {
            throw MorbError.io("could not write \(meta.path): \(error.localizedDescription)")
        }
        return true
    }

    /// The outcome of a `use` attempt.
    public enum UseResult: Equatable, Sendable {
        /// `currentContext` was written (or already equalled `morbstack`).
        case current
        /// Some other explicit context already owns default, and `force` was not set —
        /// nothing was written. Carries the context that was left alone.
        case refused(current: String)
    }

    /// Sets `currentContext` to `morbstack` in `config.json`, preserving every other key
    /// byte-for-byte (this is the file with `credHelpers`/`credsStore`/registry
    /// `mirrors` docs/compat.md commits to honouring — rewriting it from scratch would
    /// silently drop all of that).
    ///
    /// Refuses when another *explicit* context already owns default — the "never stomp"
    /// rule — unless `force` is `true`. `docs/compat.md`'s own definition of "explicit":
    /// absent, or literally `"default"`, does not count (that is the classic env-var
    /// default nobody chose Morbstack away from); anything else does.
    ///
    /// Callers (only `morb context use`) are responsible for confirmation before calling
    /// this — it writes unconditionally once invoked (subject to the refusal above).
    public static func use(
        force: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> UseResult {
        let configDir = dockerConfigDirectory(environment: environment)
        let current = currentContextName(dockerConfigDirectory: configDir)
        if current != "default", current != name, !force {
            return .refused(current: current)
        }
        let file = configFile(dockerConfigDirectory: configDir)
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: file), !data.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // A config.json we cannot parse is not a config.json we will silently
                // overwrite — that is exactly the kind of file this project's own tooling
                // warns about (docs/parity.md's `credsStore: "desktop"` hang). Fail loudly
                // instead of guessing.
                throw MorbError.config(
                    "\(file.path) exists but is not valid JSON — refusing to modify it; "
                        + "edit it by hand (or run `docker context use morbstack` yourself)")
            }
            object = parsed
        }
        object["currentContext"] = name
        do {
            try FileManager.default.createDirectory(
                at: configDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: file, options: .atomic)
        } catch {
            throw MorbError.io("could not write \(file.path): \(error.localizedDescription)")
        }
        return .current
    }

    // MARK: - /var/run/docker.sock (manual, never automatic)

    /// The conventional path several tools (older Testcontainers configurations,
    /// scripts that hardcode it, some IDE defaults) look for before trying
    /// `DOCKER_HOST` or a context at all.
    ///
    /// Morbstack never creates this itself — `/var/run` is a system directory owned by
    /// root, and *any* write there (even a symlink) is a system-level change this
    /// project's own safety rules put squarely in "the user does this themselves, not
    /// us." ``suggestedSymlinkCommand(socketPath:)`` exists so `morb context status` can
    /// tell the user the exact, correct command rather than leaving them to guess it.
    public static let systemSocketPath = "/var/run/docker.sock"

    /// The exact command to hand the user for the optional `/var/run/docker.sock`
    /// symlink, gated entirely behind them choosing to run it.
    public static func suggestedSymlinkCommand(socketPath: String = MorbPaths.dockerSocket.path) -> String {
        "sudo ln -sf \(socketPath) \(systemSocketPath)"
    }
}
