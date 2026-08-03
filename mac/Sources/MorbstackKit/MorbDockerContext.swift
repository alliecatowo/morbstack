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
import Darwin
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
        /// `~/.docker/contexts/meta/<digest>/meta.json` exists for the `morbstack` name,
        /// even when its contents cannot be parsed as a Docker endpoint.  Existence
        /// must not be inferred from `registeredHost`: a malformed same-named context
        /// is user-owned data to preserve, not permission to overwrite it.
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
        let registered = FileManager.default.fileExists(atPath: meta.path)
        let current = currentContextName(dockerConfigDirectory: configDir)
        return Status(
            registered: registered,
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
    /// calling this. It creates a missing context, but refuses to overwrite an
    /// existing same-named endpoint whose ownership cannot be established.
    @discardableResult
    public static func create(
        socketPath: String = MorbPaths.dockerSocket.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Bool {
        let configDir = dockerConfigDirectory(environment: environment)
        let meta = metaFile(dockerConfigDirectory: configDir)
        let expectedHost = "unix://\(socketPath)"
        let existingHost = readHost(metaFile: meta)
        if existingHost == expectedHost {
            return false
        }
        if let existingHost {
            throw MorbError.config(
                "\(meta.path) already registers the \(name) Docker context for \(existingHost); refusing to overwrite it. Rename or remove that context, then retry.")
        }
        if FileManager.default.fileExists(atPath: meta.path) {
            throw MorbError.config(
                "\(meta.path) already contains an unreadable \(name) Docker context; refusing to overwrite it. Repair, rename, or remove that context, then retry.")
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

    // MARK: - Removing a Morbstack-owned context

    /// The outcome of a conservative context cleanup.
    public enum RemoveResult: Equatable, Sendable {
        /// The context pointed at Morbstack's socket and was removed.  If it had been
        /// current, `currentContext` was removed from config.json first so Docker falls
        /// back to its ordinary default rather than retaining a dead context name.
        case removed(wasCurrent: Bool)
        /// No context with this name was registered.
        case notRegistered
        /// A context named `morbstack` exists but points at a different host.  It may
        /// have been made by a user for another engine, so leave it untouched.
        case pointsElsewhere(String)
    }

    /// Removes the standard Morbstack context only when its endpoint is our current
    /// relay socket.  This is used by the explicit CLI toolchain uninstall path; normal
    /// app operation never calls it.  It intentionally does not remove any unrelated
    /// context or overwrite malformed user-owned Docker configuration.
    @discardableResult
    public static func remove(
        socketPath: String = MorbPaths.dockerSocket.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> RemoveResult {
        let configDir = dockerConfigDirectory(environment: environment)
        let meta = metaFile(dockerConfigDirectory: configDir)
        guard let host = readHost(metaFile: meta) else { return .notRegistered }
        guard host == "unix://\(socketPath)" else { return .pointsElsewhere(host) }

        let file = configFile(dockerConfigDirectory: configDir)
        let current = currentContextName(dockerConfigDirectory: configDir)
        if current == name {
            var object: [String: Any] = [:]
            if let data = try? Data(contentsOf: file), !data.isEmpty {
                guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw MorbError.config(
                        "\(file.path) exists but is not valid JSON — refusing to remove its currentContext key")
                }
                object = parsed
            }
            object.removeValue(forKey: "currentContext")
            do {
                try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
                let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: file, options: .atomic)
            } catch {
                throw MorbError.io("could not update \(file.path): \(error.localizedDescription)")
            }
        }

        do {
            try FileManager.default.removeItem(at: meta)
        } catch {
            throw MorbError.io("could not remove \(meta.path): \(error.localizedDescription)")
        }
        return .removed(wasCurrent: current == name)
    }

    // MARK: - User-owned direct Docker discovery

    /// Docker Desktop established this per-user location as the conventional socket
    /// for tools that do not honour Docker contexts. Unlike `/var/run/docker.sock`, it
    /// lives below the current user's home directory and therefore needs neither a
    /// helper nor administrator authority.
    public static func directDiscoverySocketPath(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent(".docker", isDirectory: true)
            .appendingPathComponent("run", isDirectory: true)
            .appendingPathComponent("docker.sock", isDirectory: false)
    }

    /// The complete state of the conventional user-owned discovery socket. Its
    /// `state` deliberately distinguishes a stale or occupied path from an absent
    /// path: callers may create only `missing`, and must preserve every other case.
    public struct DirectSocketStatus: Equatable, Sendable {
        public enum State: Equatable, Sendable {
            /// The path and its parents are safe for Morbstack to create.
            case missing
            /// A user-owned symlink already points at this Morbstack runtime.
            case correct
            /// A symlink exists but points at another runtime or location.
            case pointsElsewhere(String)
            /// A non-symlink node occupies the conventional path.
            case occupied(String)
            /// A parent or the existing link is not safely user-owned.
            case unavailable(String)
        }

        public let path: String
        public let expectedDestination: String
        public let state: State

        public var isManaged: Bool {
            if case .correct = state { return true }
            return false
        }

        public var canCreate: Bool {
            if case .missing = state { return true }
            return false
        }
    }

    /// Reads the standard `~/.docker/run/docker.sock` location without touching the
    /// filesystem. The directory must be owned by the effective user and not pass
    /// through a symlink before the installer will create or remove anything there.
    public static func directSocketStatus(
        socketPath: String = MorbPaths.dockerSocket.path,
        discoverySocketPath: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DirectSocketStatus {
        let discovery = discoverySocketPath ?? directDiscoverySocketPath()
        let expected = URL(fileURLWithPath: socketPath).standardizedFileURL.path
        // MORBSTACK_HOME is deliberately a throwaway/developer isolation override.
        // Publishing it through the real user's conventional Docker path would leave a
        // durable link to a temporary engine after that run ends. A caller supplying a
        // concrete discovery path is an explicit test/integration seam, so it remains
        // available for isolated verification.
        if discoverySocketPath == nil,
           let homeOverride = environment["MORBSTACK_HOME"], !homeOverride.isEmpty
        {
            return DirectSocketStatus(
                path: discovery.path,
                expectedDestination: expected,
                state: .unavailable("MORBSTACK_HOME is overridden; the real user Docker path is not modified"))
        }
        if let issue = directSocketParentIssue(for: discovery) {
            return DirectSocketStatus(
                path: discovery.path, expectedDestination: expected, state: .unavailable(issue))
        }

        let fm = FileManager.default
        guard let metadata = fileStatus(at: discovery) else {
            if errno == ENOENT {
                return DirectSocketStatus(
                    path: discovery.path, expectedDestination: expected, state: .missing)
            }
            return DirectSocketStatus(
                path: discovery.path, expectedDestination: expected,
                state: .unavailable("could not inspect the existing path: \(posixErrorDescription())"))
        }

        guard metadata.st_uid == geteuid() else {
            return DirectSocketStatus(
                path: discovery.path, expectedDestination: expected,
                state: .unavailable("the existing path is not owned by the current user"))
        }

        if isSymbolicLink(metadata) {
            guard let rawDestination = try? fm.destinationOfSymbolicLink(atPath: discovery.path) else {
                return DirectSocketStatus(
                    path: discovery.path, expectedDestination: expected,
                    state: .unavailable("could not read the existing symbolic link"))
            }
            let resolved = resolvedLink(
                rawDestination, relativeTo: discovery.deletingLastPathComponent())
            return DirectSocketStatus(
                path: discovery.path,
                expectedDestination: expected,
                state: resolved == expected ? .correct : .pointsElsewhere(resolved))
        }

        return DirectSocketStatus(
            path: discovery.path, expectedDestination: expected,
            state: .occupied(fileKind(metadata)))
    }

    /// Creates the conventional user-owned link only when the read-only status says it
    /// is absent. Existing links, files, sockets, directories, and unsafe parents are
    /// all preserved; a concurrent creator is re-read and reported rather than removed.
    @discardableResult
    public static func installDirectSocket(
        socketPath: String = MorbPaths.dockerSocket.path,
        discoverySocketPath: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> DirectSocketStatus {
        let discovery = discoverySocketPath ?? directDiscoverySocketPath()
        let before = directSocketStatus(
            socketPath: socketPath, discoverySocketPath: discoverySocketPath, environment: environment)
        guard before.canCreate else { return before }

        let runDirectory = discovery.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: runDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        } catch {
            throw MorbError.io("could not create \(runDirectory.path): \(error.localizedDescription)")
        }

        // Directory creation can race with another tool. Re-check every ownership and
        // symlink condition before creating the final link, which itself never replaces
        // a node at the destination.
        let ready = directSocketStatus(
            socketPath: socketPath, discoverySocketPath: discoverySocketPath, environment: environment)
        guard ready.canCreate else { return ready }
        do {
            try FileManager.default.createSymbolicLink(
                at: discovery, withDestinationURL: URL(fileURLWithPath: socketPath))
        } catch {
            let afterFailure = directSocketStatus(
                socketPath: socketPath, discoverySocketPath: discoverySocketPath, environment: environment)
            if afterFailure.isManaged { return afterFailure }
            throw MorbError.io(
                "could not link \(discovery.path) to \(socketPath): \(error.localizedDescription)")
        }

        let after = directSocketStatus(
            socketPath: socketPath, discoverySocketPath: discoverySocketPath, environment: environment)
        guard after.isManaged else {
            throw MorbError.io(
                "created \(discovery.path), but it could not be verified as Morbstack-owned")
        }
        return after
    }

    /// The outcome of an explicit CLI integration uninstall. Only the exact,
    /// user-owned link back to this runtime is removed; parent directories and every
    /// other path at the conventional location remain untouched.
    public enum DirectSocketRemoveResult: Equatable, Sendable {
        case removed
        case notPresent
        case pointsElsewhere(String)
        case occupied(String)
        case unavailable(String)
    }

    @discardableResult
    public static func removeDirectSocket(
        socketPath: String = MorbPaths.dockerSocket.path,
        discoverySocketPath: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> DirectSocketRemoveResult {
        let discovery = discoverySocketPath ?? directDiscoverySocketPath()
        let status = directSocketStatus(
            socketPath: socketPath, discoverySocketPath: discoverySocketPath, environment: environment)
        switch status.state {
        case .missing:
            return .notPresent
        case .pointsElsewhere(let destination):
            return .pointsElsewhere(destination)
        case .occupied(let kind):
            return .occupied(kind)
        case .unavailable(let reason):
            return .unavailable(reason)
        case .correct:
            do {
                try FileManager.default.removeItem(at: discovery)
            } catch {
                throw MorbError.io("could not remove \(discovery.path): \(error.localizedDescription)")
            }
            return .removed
        }
    }

    private enum DirectDirectoryStatus {
        case missing
        case safe
        case unavailable(String)
    }

    private static func directSocketParentIssue(for discovery: URL) -> String? {
        let runDirectory = discovery.deletingLastPathComponent()
        let dockerDirectory = runDirectory.deletingLastPathComponent()
        for directory in [dockerDirectory, runDirectory] {
            switch userOwnedDirectoryStatus(at: directory) {
            case .missing, .safe:
                continue
            case .unavailable(let reason):
                return "\(directory.path) \(reason)"
            }
        }
        return nil
    }

    private static func userOwnedDirectoryStatus(at directory: URL) -> DirectDirectoryStatus {
        guard let metadata = fileStatus(at: directory) else {
            if errno == ENOENT { return .missing }
            return .unavailable("could not be inspected: \(posixErrorDescription())")
        }
        if isSymbolicLink(metadata) {
            return .unavailable("is a symbolic link")
        }
        if !isDirectory(metadata) {
            return .unavailable("is not a directory")
        }
        if metadata.st_uid != geteuid() {
            return .unavailable("is not owned by the current user")
        }
        if metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) != 0 {
            return .unavailable("is writable by group or other users")
        }
        return .safe
    }

    private static func fileStatus(at url: URL) -> stat? {
        var metadata = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &metadata)
        }
        return result == 0 ? metadata : nil
    }

    private static func isDirectory(_ metadata: stat) -> Bool {
        (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
    }

    private static func isSymbolicLink(_ metadata: stat) -> Bool {
        (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK)
    }

    private static func fileKind(_ metadata: stat) -> String {
        let type = metadata.st_mode & mode_t(S_IFMT)
        switch type {
        case mode_t(S_IFSOCK): return "socket"
        case mode_t(S_IFREG): return "file"
        case mode_t(S_IFDIR): return "directory"
        default: return "non-symlink filesystem node"
        }
    }

    private static func posixErrorDescription() -> String {
        String(cString: strerror(errno))
    }

    private static func resolvedLink(_ raw: String, relativeTo directory: URL) -> String {
        if raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw).standardizedFileURL.path
        }
        return directory.appendingPathComponent(raw).standardizedFileURL.path
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
