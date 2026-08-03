// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Host Docker CLI plugin binaries Morbstack ships (docker-compose, docker-buildx) and
// the machinery to symlink them into `~/.docker/cli-plugins/` on explicit request.
//
// This type never touches disk under `~/.docker` on its own — ``plan(environment:)`` is
// pure and side-effect free, and ``install(environment:)`` is only ever called after a
// caller (today, only `morb install-cli-plugins`) has gotten explicit confirmation from
// the person at the keyboard, or `--force`. See dist/host-bin/PROVENANCE.txt for where
// the binaries themselves come from and how their hashes were verified.

import Foundation

public enum MorbCliPlugins {

    /// One plugin binary this repo can install.
    ///
    /// `name` is docker's own plugin-naming convention: a `docker-<name>` binary on
    /// `PATH` or in a cli-plugins directory becomes the `docker <name>` subcommand.
    public struct Plugin: Equatable, Sendable {
        public let name: String
        public init(name: String) { self.name = name }

        /// The file name docker's resolver looks for.
        public var binaryName: String { "docker-\(name)" }
    }

    public static let compose = Plugin(name: "compose")
    public static let buildx = Plugin(name: "buildx")
    public static let all: [Plugin] = [compose, buildx]

    /// Where docker's own cli-plugins resolver looks.
    ///
    /// Honours `DOCKER_CONFIG` exactly the way the `docker` CLI itself does, rather than
    /// hardcoding `~/.docker` — a user who has redirected their Docker config (as
    /// `scripts/live-app-check.sh` does for its own isolated test runs, and as this
    /// project's own contributor docs recommend to avoid a live `credsStore` hang) must
    /// get plugins installed where their CLI will actually look for them.
    public static func cliPluginsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["DOCKER_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("cli-plugins", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".docker", isDirectory: true)
            .appendingPathComponent("cli-plugins", isDirectory: true)
    }

    /// Search order for a plugin's source binary.
    ///
    /// A shipped `.app` bundles `dist/host-bin` under `Contents/Resources/host-bin` (see
    /// the `app` target in the Makefile); a repo checkout has `morb` at
    /// `mac/.build/debug/morb` (or `.build/release/morb`) with `dist/host-bin` a few
    /// directories up. Both are tried, bundle location first, so an installed app never
    /// accidentally reads out of a developer's repo checkout instead of its own bundle.
    public static func sourceBinary(for plugin: Plugin) -> URL? {
        for dir in candidateHostBinDirectories() {
            // `host-bin` is the root of the *toolchain*, not Docker's plugin search
            // directory.  Keeping plugins one level down is what lets the packaged
            // layout exactly mirror a normal Docker config directory:
            //
            //   Contents/Resources/host-bin/docker
            //   Contents/Resources/host-bin/cli-plugins/docker-compose
            //   Contents/Resources/host-bin/cli-plugins/docker-buildx
            //
            // Looking directly under `host-bin` made every plan report its sources as
            // missing even after the fetcher had verified the real files.  That was
            // especially bad on a clean machine: first-run could look complete while
            // `docker compose` and `docker buildx` were not actually installed.
            let candidate = dir
                .appendingPathComponent("cli-plugins", isDirectory: true)
                .appendingPathComponent(plugin.binaryName, isDirectory: false)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func candidateHostBinDirectories() -> [URL] {
        let exeDir = MorbExecutable.currentDirectory()
        var dirs: [URL] = [
            // Shipped .app: Contents/MacOS/morb -> Contents/Resources/host-bin.
            exeDir.deletingLastPathComponent()
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("host-bin", isDirectory: true),
            // Flat layout, in case a future packaging puts everything side by side.
            exeDir.appendingPathComponent("host-bin", isDirectory: true),
        ]
        // Dev checkout: walk up from the executable looking for dist/host-bin
        // (mac/.build/debug/morb -> mac/.build -> mac -> <repo root>/dist/host-bin).
        var probe = exeDir
        for _ in 0..<8 {
            dirs.append(
                probe.appendingPathComponent("dist", isDirectory: true)
                    .appendingPathComponent("host-bin", isDirectory: true))
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { break }
            probe = parent
        }
        return dirs
    }

    /// The bundled, unmodified `docker` client binary, if this build carries one.
    ///
    /// The client and its plugins deliberately share the same lookup roots.  A first
    /// public binary must not borrow Docker Desktop's client from `/usr/local/bin` on
    /// the development machine: the app bundle itself is the source of all three host
    /// executables.
    public static func sourceDockerCLI() -> URL? {
        for dir in candidateHostBinDirectories() {
            let candidate = dir.appendingPathComponent("docker", isDirectory: false)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Planning (pure, no disk writes)

    /// What ``install(environment:)`` would do, computed without touching disk (beyond
    /// reading the existing state of the destination, to describe it honestly).
    public struct Plan: Equatable, Sendable {
        public struct Item: Equatable, Sendable {
            public let plugin: String
            public let source: String?
            public let destination: String
            /// The destination already exists (file, or symlink of any kind, dangling or not).
            public let alreadyPresent: Bool
            /// The destination is already a symlink pointing at exactly `source`.
            public let alreadyCorrect: Bool
            /// The destination exists and is something other than a symlink to `source`
            /// — installing will replace it. Distinguished from `alreadyPresent` because
            /// the confirmation prompt owes the user this specific fact.
            public var willReplace: Bool { alreadyPresent && !alreadyCorrect }
        }
        public var directory: String
        public var items: [Item]

        /// Nothing here can be done — no source binaries were found at all (e.g. a dev
        /// checkout that has not run `scripts/fetch-guest-assets.sh` yet).
        public var isEmpty: Bool { items.allSatisfy { $0.source == nil } }
    }

    /// Builds the plan. Side-effect free.
    public static func plan(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Plan {
        let directory = cliPluginsDirectory(environment: environment)
        let fm = FileManager.default
        let items: [Plan.Item] = all.map { plugin in
            let source = sourceBinary(for: plugin)
            let destination = directory.appendingPathComponent(plugin.binaryName, isDirectory: false)
            let existingTarget = try? fm.destinationOfSymbolicLink(atPath: destination.path)
            let present = fm.fileExists(atPath: destination.path) || existingTarget != nil
            let correct: Bool = {
                guard let source, let existingTarget else { return false }
                return resolvedSymlinkTarget(existingTarget, relativeTo: directory) == source.standardizedFileURL.path
            }()
            return Plan.Item(
                plugin: plugin.name,
                source: source?.path,
                destination: destination.path,
                alreadyPresent: present,
                alreadyCorrect: correct)
        }
        return Plan(directory: directory.path, items: items)
    }

    private static func resolvedSymlinkTarget(_ raw: String, relativeTo directory: URL) -> String {
        if raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw).standardizedFileURL.path
        }
        return directory.appendingPathComponent(raw).standardizedFileURL.path
    }

    // MARK: - Installing

    /// One plugin's install outcome.
    public enum InstallOutcome: Equatable, Sendable {
        /// A new (or replacement) symlink was created.
        case linked(String)
        /// The destination already pointed at the right place; nothing changed.
        case alreadyCorrect(String)
        /// No source binary was found for this plugin (see ``sourceBinary(for:)``).
        case sourceMissing(String)
        /// The symlink could not be created.
        case failed(String, String)
    }

    /// Creates the symlinks for every plugin whose source binary is present.
    ///
    /// Has no opinion on confirmation — that decision belongs entirely to the caller
    /// (`morb install-cli-plugins`, which always asks first, or `--force`). Calling this
    /// directly performs the write immediately.
    public static func install(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [InstallOutcome] {
        let directory = cliPluginsDirectory(environment: environment)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return all.map { .failed($0.name, "could not create \(directory.path): \(error.localizedDescription)") }
        }

        return all.map { plugin in
            guard let source = sourceBinary(for: plugin) else {
                return .sourceMissing(plugin.name)
            }
            let destination = directory.appendingPathComponent(plugin.binaryName, isDirectory: false)
            let existingTarget = try? fm.destinationOfSymbolicLink(atPath: destination.path)
            if let existingTarget,
                resolvedSymlinkTarget(existingTarget, relativeTo: directory) == source.standardizedFileURL.path
            {
                return .alreadyCorrect(plugin.name)
            }
            if fm.fileExists(atPath: destination.path) || existingTarget != nil {
                try? fm.removeItem(at: destination)
            }
            do {
                try fm.createSymbolicLink(at: destination, withDestinationURL: source)
                return .linked(plugin.name)
            } catch {
                return .failed(plugin.name, error.localizedDescription)
            }
        }
    }
}
