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

import CryptoKit
import Foundation
import Security

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

    /// One complete, verified Docker CLI toolchain from a single source root.
    ///
    /// The Docker client and both plugins must be selected together. Resolving each
    /// file independently could otherwise combine an app-bundled `docker` with a
    /// checkout's Buildx, or install an executable whose bytes no longer match the
    /// release's declared provenance.
    public struct Toolchain: Sendable {
        public let root: URL
        public let docker: URL
        public let compose: URL
        public let buildx: URL

        public func source(for plugin: Plugin) -> URL? {
            if plugin.name == "compose" { return compose }
            if plugin.name == "buildx" { return buildx }
            return nil
        }
    }

    private struct Tool: Decodable {
        let id: String
        let path: String
        let version: String
        let sourceSha256: String
        let sha256: String

        enum CodingKeys: String, CodingKey {
            case id
            case path
            case version
            case sourceSha256 = "source_sha256"
            case sha256
        }
    }

    private struct Manifest: Decodable {
        let schemaVersion: Int
        let platform: String
        let tools: [Tool]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case platform
            case tools
        }
    }

    private struct PinnedTool {
        let id: String
        let path: String
        let version: String
        let sha256: String
    }

    private static let manifestName = "TOOLCHAIN.plist"
    private static let pinnedTools = [
        PinnedTool(
            id: "docker", path: "docker", version: "29.7.1",
            sha256: "49d98ab806e8678cd6341b09dad6389e5bcd8a46513de7651053bee3d8366e8d"),
        PinnedTool(
            id: "compose", path: "cli-plugins/docker-compose", version: "v5.3.1",
            sha256: "32691ba1196d819fa68cbdc0aad9a5569e730a35ae40c6fdd8458110ecd69488"),
        PinnedTool(
            id: "buildx", path: "cli-plugins/docker-buildx", version: "v0.36.0",
            sha256: "82c6a3d9df37790c5bdb0d7ca88986d1d17622fc2b88ebe34b275c6c47acd7a6"),
    ]

    /// Resolves one complete provenance-verified toolchain. A packaged executable
    /// never falls back to a checkout: an invalid signed bundle is a release defect,
    /// not permission to borrow arbitrary developer bytes from elsewhere on disk.
    public static func sourceToolchain() -> Toolchain? {
        if bundledHostBinLocation() != nil { return bundledToolchain }
        return candidateHostBinDirectories().lazy.compactMap { validatedToolchain(at: $0) }.first
    }

    /// Validated once per process for the immutable, signed app-bundle case. Checkout
    /// roots stay uncached so a developer's fetch/replace cycle is immediately seen.
    private static let bundledToolchain: Toolchain? = {
        guard let location = bundledHostBinLocation(), isValidCodeSignature(appURL: location.appURL) else {
            return nil
        }
        return validatedToolchain(at: location.hostBinURL, isSealedBundle: true)
    }()

    /// Whether a resolved symlink target is a binary from a Morbstack bundle or
    /// checkout. This is deliberately about *provenance*, not mere path shape:
    /// `~/.docker/cli-plugins` belongs to the person's Docker client, so an
    /// existing plugin may be replaced only when it is recognizably an older
    /// Morbstack installation. The same predicate is used by the combined CLI
    /// installer and its uninstall path so upgrades and removal agree on what
    /// Morbstack owns.
    static func isManagedInstalledBinaryTarget(_ target: String, binaryName: String) -> Bool {
        let standardTarget = URL(fileURLWithPath: target).standardizedFileURL.path
        let bundleRoot = "/Morbstack.app/Contents/Resources/host-bin/"
        let checkoutRoot = "/dist/host-bin/"
        let comesFromMorbstack = standardTarget.contains(bundleRoot)
            || standardTarget.contains(checkoutRoot)
        guard comesFromMorbstack else { return false }

        return standardTarget.hasSuffix("/host-bin/\(binaryName)")
            || standardTarget.hasSuffix("/host-bin/cli-plugins/\(binaryName)")
    }

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
        sourceToolchain()?.source(for: plugin)
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
        sourceToolchain()?.docker
    }

    private struct BundledHostBinLocation {
        let appURL: URL
        let hostBinURL: URL
    }

    private static func bundledHostBinLocation() -> BundledHostBinLocation? {
        let executable = URL(fileURLWithPath: MorbExecutable.currentPath()).resolvingSymlinksInPath()
        let macOSDirectory = executable.deletingLastPathComponent()
        guard macOSDirectory.lastPathComponent == "MacOS" else { return nil }
        let contents = macOSDirectory.deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents" else { return nil }
        let appURL = contents.deletingLastPathComponent()
        guard appURL.pathExtension == "app" else { return nil }
        return BundledHostBinLocation(
            appURL: appURL,
            hostBinURL: contents
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("host-bin", isDirectory: true))
    }

    private static func validatedToolchain(at root: URL, isSealedBundle: Bool = false) -> Toolchain? {
        guard isRegularDirectory(root) else { return nil }
        let manifestURL = root.appendingPathComponent(manifestName, isDirectory: false)
        guard isRegularFile(manifestURL),
              let data = try? Data(contentsOf: manifestURL, options: .mappedIfSafe),
              let manifest = try? PropertyListDecoder().decode(Manifest.self, from: data),
              manifest.schemaVersion == 1,
              manifest.platform == "darwin-arm64",
              manifest.tools.count == pinnedTools.count
        else { return nil }

        var binaries: [String: URL] = [:]
        for expected in pinnedTools {
            let entries = manifest.tools.filter { $0.id == expected.id }
            guard entries.count == 1, let entry = entries.first,
                  entry.path == expected.path,
                  entry.version == expected.version,
                  entry.sourceSha256 == expected.sha256,
                  isSHA256(entry.sha256)
            else { return nil }
            let binary = root.appendingPathComponent(expected.path, isDirectory: false)
            guard isRegularFile(binary),
                  FileManager.default.isExecutableFile(atPath: binary.path),
                  sha256(of: binary) == entry.sha256,
                  isSealedBundle || entry.sha256 == expected.sha256
            else { return nil }
            binaries[expected.id] = binary
        }

        guard let docker = binaries["docker"],
              let compose = binaries["compose"],
              let buildx = binaries["buildx"]
        else { return nil }
        return Toolchain(root: root, docker: docker, compose: compose, buildx: buildx)
    }

    private static func isRegularDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }

    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
                hasher.update(data: data)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    private static func isValidCodeSignature(appURL: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else { return false }
        return SecStaticCodeCheckValidity(staticCode, SecCSFlags(), nil) == errSecSuccess
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
            /// The existing destination is a positively identified Morbstack link. It
            /// may be replaced during an explicit upgrade; an arbitrary user file or
            /// plugin link is never eligible for replacement.
            public let existingIsManaged: Bool
            /// A Morbstack-owned older link will be updated to this installation.
            public var willReplace: Bool {
                alreadyPresent && !alreadyCorrect && existingIsManaged
            }
            /// An existing file or link belongs to the person or another tool. The
            /// caller must stop and name the conflict instead of deleting it.
            public var hasUnmanagedConflict: Bool {
                alreadyPresent && !alreadyCorrect && !existingIsManaged
            }
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
        let toolchain = sourceToolchain()
        let items: [Plan.Item] = all.map { plugin in
            let source = toolchain?.source(for: plugin)
            let destination = directory.appendingPathComponent(plugin.binaryName, isDirectory: false)
            let existingTarget = try? fm.destinationOfSymbolicLink(atPath: destination.path)
            let present = fm.fileExists(atPath: destination.path) || existingTarget != nil
            let correct: Bool = {
                guard let source, let existingTarget else { return false }
                return resolvedSymlinkTarget(existingTarget, relativeTo: directory) == source.standardizedFileURL.path
            }()
            let existingIsManaged: Bool = {
                guard let existingTarget else { return false }
                return MorbCliPlugins.isManagedInstalledBinaryTarget(
                    resolvedSymlinkTarget(existingTarget, relativeTo: directory),
                    binaryName: plugin.binaryName)
            }()
            return Plan.Item(
                plugin: plugin.name,
                source: source?.path,
                destination: destination.path,
                alreadyPresent: present,
                alreadyCorrect: correct,
                existingIsManaged: existingIsManaged)
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
        /// An existing file or link is not verifiably Morbstack-owned, so it was left
        /// in place. This is an installation conflict, not a successful fallback.
        case preservedExisting(String, String)
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
        let toolchain = sourceToolchain()
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return all.map { .failed($0.name, "could not create \(directory.path): \(error.localizedDescription)") }
        }

        return all.map { plugin in
            guard let source = toolchain?.source(for: plugin) else {
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
                guard let existingTarget,
                      isManagedInstalledBinaryTarget(
                        resolvedSymlinkTarget(existingTarget, relativeTo: directory),
                        binaryName: plugin.binaryName)
                else {
                    return .preservedExisting(plugin.name, destination.path)
                }
                do {
                    try fm.removeItem(at: destination)
                } catch {
                    return .failed(plugin.name, "could not replace Morbstack's previous link: \(error.localizedDescription)")
                }
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
