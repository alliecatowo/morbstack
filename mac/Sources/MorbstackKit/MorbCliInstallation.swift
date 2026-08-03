// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The consented first-run setup for the host Docker toolchain.
//
// A packaged Morbstack carries an upstream `docker` client plus the compose and buildx
// plugins under Contents/Resources/host-bin.  This module deliberately contains no UI
// and no prompt: callers show ``Plan`` first, obtain consent in their own surface, then
// call ``install(environment:makeDefault:)``.  That makes it usable from the app's
// eventual first-run sheet *and* from `morb install-cli`, while keeping the side effects
// small, auditable and reversible.

import Foundation

public enum MorbCliInstallation {

    // MARK: - Managed locations

    /// The unprivileged directory in which Morbstack exposes its `docker` client.
    ///
    /// `/usr/local/bin` needs administrator authority and may already belong to another
    /// Docker installation.  A per-user directory lets first run work without a helper
    /// tool or a password, and the exact one-line shell profile block below makes it
    /// visible to new Terminal sessions on a clean macOS installation.
    public static func binDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        root(environment: environment).appendingPathComponent("bin", isDirectory: true)
    }

    public static func dockerDestination(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        binDirectory(environment: environment).appendingPathComponent("docker", isDirectory: false)
    }

    /// The unique block this installer may add to the user's login profile.  It is both
    /// deliberately tiny and byte-stable so uninstallation can remove *only* what this
    /// installer owns instead of attempting to interpret arbitrary shell code.
    public static let profileBlock = """
    # >>> Morbstack CLI >>>
    export PATH="$HOME/.morbstack/bin:$PATH"
    # <<< Morbstack CLI <<<

    """

    private static let profileStart = "# >>> Morbstack CLI >>>"
    private static let profileEnd = "# <<< Morbstack CLI <<<"

    /// macOS's stock shell is zsh.  Bash remains supported for people who explicitly
    /// selected it; shells with their own configuration grammar are never guessed at.
    public static func loginProfile(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let shell = URL(fileURLWithPath: environment["SHELL"] ?? "/bin/zsh").lastPathComponent
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch shell {
        case "zsh": return home.appendingPathComponent(".zprofile", isDirectory: false)
        case "bash": return home.appendingPathComponent(".bash_profile", isDirectory: false)
        default: return nil
        }
    }

    // MARK: - Planning

    public struct LinkItem: Equatable, Sendable {
        public let name: String
        public let source: String?
        public let destination: String
        public let alreadyPresent: Bool
        public let alreadyCorrect: Bool
        /// Only a positively identified older Morbstack link may be updated. A
        /// destination supplied by another Docker installation remains untouched.
        public let existingIsManaged: Bool
        public var willReplace: Bool {
            alreadyPresent && !alreadyCorrect && existingIsManaged
        }
        public var hasUnmanagedConflict: Bool {
            alreadyPresent && !alreadyCorrect && !existingIsManaged
        }
    }

    public enum PathRegistration: Equatable, Sendable {
        /// The runtime bin is already on this process's PATH, so no profile edit is
        /// necessary (and none is made).
        case alreadyReachable
        /// A different docker client resolves first.  We leave that choice alone unless
        /// the person explicitly opts into `--make-default`.
        case preservesExistingDocker(String)
        /// A supported shell profile will receive exactly ``profileBlock``.
        case addToProfile(String)
        /// The same complete managed block is already present.
        case profileAlreadyManaged(String)
        /// `MORBSTACK_HOME` is a developer/test isolation override.  Persisting that
        /// temporary path into a real profile would be surprising, so do not do it.
        case skippedForHomeOverride
        /// A shell we cannot safely configure (fish, custom shell, etc.).
        case unsupportedShell
        /// One marker is present but the managed block has been hand-edited; never try
        /// to repair or remove ambiguous user shell code automatically.
        case malformedExistingBlock(String)
    }

    public enum ContextRegistration: Equatable, Sendable {
        case willCreateAndUse
        case willCreateWithoutChangingCurrent(String)
        case alreadyCurrent
        case alreadyRegisteredWithoutChangingCurrent(String)
        /// A context using Morbstack's reserved name already points at a different
        /// endpoint. Its provenance cannot be determined from Docker's meta.json, so
        /// setup must leave it alone and name the repair rather than overwriting it.
        case conflictingRegistration(String)
    }

    public struct Plan: Equatable, Sendable {
        public let docker: LinkItem
        public let plugins: [LinkItem]
        public let pathRegistration: PathRegistration
        public let contextRegistration: ContextRegistration
        /// The conventional per-user Docker socket location. The installer creates
        /// only a missing, user-owned link and preserves every existing path.
        public let directSocket: MorbDockerContext.DirectSocketStatus

        /// Every binary that the clean-machine contract requires is available from this
        /// app bundle or this checkout.  Callers must refuse to install a partial
        /// toolchain: having `docker` but not `docker buildx` recreates parity #13.
        public var hasCompleteToolchain: Bool {
            docker.source != nil && plugins.allSatisfy { $0.source != nil }
        }

        /// The bundle contains the complete toolchain *and* every target is either
        /// absent, already correct, or a recognisable Morbstack upgrade target.
        /// This stays distinct from ``hasCompleteToolchain`` so callers can tell a
        /// broken bundle from a deliberately preserved user installation.
        public var isInstallable: Bool {
            hasCompleteToolchain && !([docker] + plugins).contains(where: \.hasUnmanagedConflict)
        }
    }

    /// Computes the exact first-run work without writing any files.
    public static func plan(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        makeDefault: Bool = false
    ) -> Plan {
        let toolchain = MorbCliPlugins.sourceToolchain()
        let docker = linkItem(
            name: "docker",
            source: toolchain?.docker,
            destination: dockerDestination(environment: environment))
        let plugins = MorbCliPlugins.all.map { plugin in
            linkItem(
                name: plugin.binaryName,
                source: toolchain?.source(for: plugin),
                destination: MorbCliPlugins.cliPluginsDirectory(environment: environment)
                    .appendingPathComponent(plugin.binaryName, isDirectory: false))
        }

        let pathRegistration = pathRegistration(
            environment: environment, makeDefault: makeDefault)
        let directSocket = MorbDockerContext.directSocketStatus(environment: environment)
        let context = MorbDockerContext.status(environment: environment)
        let contextRegistration: ContextRegistration
        if context.registered && context.matchesSocket {
            contextRegistration = context.isCurrent
                ? .alreadyCurrent
                : .alreadyRegisteredWithoutChangingCurrent(context.currentContext)
        } else if context.registered {
            contextRegistration = .conflictingRegistration(context.registeredHost ?? "an unrecognized endpoint")
        } else {
            contextRegistration = context.wouldRefuseUse
                ? .willCreateWithoutChangingCurrent(context.currentContext)
                : .willCreateAndUse
        }

        return Plan(
            docker: docker,
            plugins: plugins,
            pathRegistration: pathRegistration,
            contextRegistration: contextRegistration,
            directSocket: directSocket)
    }

    // MARK: - Installation

    public struct InstallResult: Equatable, Sendable {
        public let links: [String: LinkResult]
        public let pathRegistration: PathRegistration
        /// The verified post-install state of `~/.docker/run/docker.sock`. A non-ready
        /// state is never treated as an error when it belongs to another tool; it is
        /// reported so the caller can explain that Morbstack left it untouched.
        public let directSocket: MorbDockerContext.DirectSocketStatus
        public let contextCreated: Bool
        public let contextBecameCurrent: Bool
        /// Context setup has a useful partial-success state: links/profile were safely
        /// installed, but an invalid user-owned Docker config prevented switching the
        /// default.  Keep it explicit rather than hiding it behind a failed install.
        public let contextError: String?
    }

    public enum LinkResult: Equatable, Sendable {
        case linked
        case alreadyCorrect
    }

    /// Installs the entire host toolchain after the caller has shown the plan and
    /// obtained consent.  `makeDefault` changes profile precedence only; it never
    /// overrides another explicit Docker *context* (docs/compat.md's no-stomping rule).
    @discardableResult
    public static func install(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        makeDefault: Bool = false,
        reviewedPlan: Plan? = nil
    ) throws -> InstallResult {
        let installPlan = plan(environment: environment, makeDefault: makeDefault)
        if let reviewedPlan, reviewedPlan != installPlan {
            throw MorbError.config(
                "Docker CLI setup changed since it was reviewed; inspect the new plan and confirm it again")
        }
        guard installPlan.hasCompleteToolchain else {
            throw MorbError.notFound(
                "the bundled Docker CLI toolchain is incomplete; expected docker, docker-compose, and docker-buildx")
        }
        let conflicts = ([installPlan.docker] + installPlan.plugins)
            .filter(\.hasUnmanagedConflict)
            .map(\.destination)
        guard conflicts.isEmpty else {
            throw MorbError.config(
                "refusing to replace an existing non-Morbstack Docker tool link at "
                    + conflicts.joined(separator: ", ")
                    + "; move or remove it yourself, then review setup again")
        }

        var results: [String: LinkResult] = [:]
        guard let toolchain = MorbCliPlugins.sourceToolchain() else {
            throw MorbError.notFound(
                "the bundled Docker CLI toolchain disappeared or no longer passed provenance verification while first-run setup was starting")
        }
        results["docker"] = try installLink(
            source: toolchain.docker, destination: dockerDestination(environment: environment))

        for plugin in MorbCliPlugins.all {
            guard let source = toolchain.source(for: plugin) else {
                throw MorbError.notFound(
                    "the verified Docker CLI toolchain omitted \(plugin.binaryName) while first-run setup was starting")
            }
            let destination = MorbCliPlugins.cliPluginsDirectory(environment: environment)
                .appendingPathComponent(plugin.binaryName, isDirectory: false)
            results[plugin.binaryName] = try installLink(source: source, destination: destination)
        }

        try installPathRegistration(installPlan.pathRegistration)
        let directSocket = try MorbDockerContext.installDirectSocket(environment: environment)

        var created = false
        var becameCurrent = false
        var contextError: String?
        switch installPlan.contextRegistration {
        case .conflictingRegistration(let endpoint):
            contextError = "the existing \(MorbDockerContext.name) context points at \(endpoint); Morbstack preserved it. Rename or remove that context, then run setup again."
        default:
            do {
                created = try MorbDockerContext.create(environment: environment)
                // `use(force: false)` only writes when the current context is Docker's
                // ordinary default.  A remote/desktop/etc. context remains untouched.
                if case .current = try MorbDockerContext.use(force: false, environment: environment) {
                    becameCurrent = true
                }
            } catch {
                contextError = (error as? MorbError)?.description ?? error.localizedDescription
            }
        }

        return InstallResult(
            links: results,
            pathRegistration: installPlan.pathRegistration,
            directSocket: directSocket,
            contextCreated: created,
            contextBecameCurrent: becameCurrent,
            contextError: contextError)
    }

    // MARK: - Uninstallation

    public struct UninstallResult: Equatable, Sendable {
        public let removedLinks: [String]
        public let preservedLinks: [String]
        public let removedProfileBlock: Bool
        public let directSocket: MorbDockerContext.DirectSocketRemoveResult
        public let context: MorbDockerContext.RemoveResult
    }

    /// Removes only symlinks and shell text that this installer can positively identify
    /// as its own.  It intentionally does not remove `~/.morbstack/data`, the app
    /// bundle, an unrelated Docker client, or an unrelated context; those have broader
    /// ownership and require a separately-worded destructive uninstall flow.
    @discardableResult
    public static func uninstall(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> UninstallResult {
        var removed: [String] = []
        var preserved: [String] = []
        let destinations = [dockerDestination(environment: environment)]
            + MorbCliPlugins.all.map {
                MorbCliPlugins.cliPluginsDirectory(environment: environment)
                    .appendingPathComponent($0.binaryName, isDirectory: false)
            }
        for destination in destinations {
            if try removeManagedLink(at: destination) {
                removed.append(destination.lastPathComponent)
            } else if FileManager.default.fileExists(atPath: destination.path)
                        || (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) != nil {
                preserved.append(destination.lastPathComponent)
            }
        }

        let removedProfileBlock = try removeProfileBlock(environment: environment)
        let directSocket = try MorbDockerContext.removeDirectSocket(environment: environment)
        let context = try MorbDockerContext.remove(environment: environment)
        return UninstallResult(
            removedLinks: removed.sorted(), preservedLinks: preserved.sorted(),
            removedProfileBlock: removedProfileBlock, directSocket: directSocket, context: context)
    }

    // MARK: - Details

    private static func root(environment: [String: String]) -> URL {
        if let override = environment["MORBSTACK_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".morbstack", isDirectory: true)
    }

    private static func linkItem(name: String, source: URL?, destination: URL) -> LinkItem {
        let fm = FileManager.default
        let rawTarget = try? fm.destinationOfSymbolicLink(atPath: destination.path)
        let present = fm.fileExists(atPath: destination.path) || rawTarget != nil
        let correct: Bool = {
            guard let source, let rawTarget else { return false }
            return resolvedLink(rawTarget, relativeTo: destination.deletingLastPathComponent())
                == source.standardizedFileURL.path
        }()
        let existingIsManaged: Bool = {
            guard let rawTarget else { return false }
            return MorbCliPlugins.isManagedInstalledBinaryTarget(
                resolvedLink(rawTarget, relativeTo: destination.deletingLastPathComponent()),
                binaryName: name)
        }()
        return LinkItem(
            name: name, source: source?.path, destination: destination.path,
            alreadyPresent: present, alreadyCorrect: correct,
            existingIsManaged: existingIsManaged)
    }

    private static func pathRegistration(
        environment: [String: String], makeDefault: Bool
    ) -> PathRegistration {
        // Do not leak temporary/test `MORBSTACK_HOME` values into a persistent shell
        // profile.  The caller can set PATH itself for that intentionally isolated run.
        if let homeOverride = environment["MORBSTACK_HOME"], !homeOverride.isEmpty {
            return .skippedForHomeOverride
        }
        let bin = binDirectory(environment: environment)
        if pathContains(bin, environment: environment) { return .alreadyReachable }
        guard let profile = loginProfile(environment: environment) else { return .unsupportedShell }
        let contents = (try? String(contentsOf: profile, encoding: .utf8)) ?? ""
        let hasStart = contents.contains(profileStart)
        let hasEnd = contents.contains(profileEnd)
        if hasStart || hasEnd {
            return contents.contains(profileBlock)
                ? .profileAlreadyManaged(profile.path)
                : .malformedExistingBlock(profile.path)
        }
        if !makeDefault, let existing = dockerOnPath(excluding: bin, environment: environment) {
            return .preservesExistingDocker(existing)
        }
        return .addToProfile(profile.path)
    }

    private static func pathContains(_ wanted: URL, environment: [String: String]) -> Bool {
        guard let path = environment["PATH"] else { return false }
        let normalized = wanted.standardizedFileURL.path
        return path.split(separator: ":").contains { component in
            URL(fileURLWithPath: String(component)).standardizedFileURL.path == normalized
        }
    }

    private static func dockerOnPath(excluding excluded: URL, environment: [String: String]) -> String? {
        guard let path = environment["PATH"] else { return nil }
        let excludedPath = excluded.standardizedFileURL.path
        for component in path.split(separator: ":") {
            let directory = URL(fileURLWithPath: String(component)).standardizedFileURL
            if directory.path == excludedPath { continue }
            let candidate = directory.appendingPathComponent("docker", isDirectory: false)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.path }
        }
        return nil
    }

    private static func installLink(source: URL, destination: URL) throws -> LinkResult {
        let fm = FileManager.default
        let directory = destination.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw MorbError.io("could not create \(directory.path): \(error.localizedDescription)")
        }
        if let raw = try? fm.destinationOfSymbolicLink(atPath: destination.path),
           resolvedLink(raw, relativeTo: directory) == source.standardizedFileURL.path
        {
            return .alreadyCorrect
        }
        do {
            if fm.fileExists(atPath: destination.path)
                || (try? fm.destinationOfSymbolicLink(atPath: destination.path)) != nil
            {
                guard let raw = try? fm.destinationOfSymbolicLink(atPath: destination.path),
                      MorbCliPlugins.isManagedInstalledBinaryTarget(
                        resolvedLink(raw, relativeTo: directory),
                        binaryName: destination.lastPathComponent)
                else {
                    throw MorbError.config(
                        "refusing to replace non-Morbstack file or link at \(destination.path)")
                }
                try fm.removeItem(at: destination)
            }
            try fm.createSymbolicLink(at: destination, withDestinationURL: source)
            return .linked
        } catch let error as MorbError {
            throw error
        } catch {
            throw MorbError.io("could not link \(destination.path) to \(source.path): \(error.localizedDescription)")
        }
    }

    private static func installPathRegistration(_ registration: PathRegistration) throws {
        guard case .addToProfile(let path) = registration else { return }
        let profile = URL(fileURLWithPath: path, isDirectory: false)
        let old = (try? String(contentsOf: profile, encoding: .utf8)) ?? ""
        guard !old.contains(profileStart), !old.contains(profileEnd) else {
            throw MorbError.config("\(profile.path) contains an incomplete Morbstack CLI profile block; refusing to edit it")
        }
        let separator = old.isEmpty || old.hasSuffix("\n") ? "" : "\n"
        do {
            try (old + separator + profileBlock).write(to: profile, atomically: true, encoding: .utf8)
        } catch {
            throw MorbError.io("could not write \(profile.path): \(error.localizedDescription)")
        }
    }

    private static func removeManagedLink(at destination: URL) throws -> Bool {
        let fm = FileManager.default
        guard let raw = try? fm.destinationOfSymbolicLink(atPath: destination.path) else { return false }
        let resolved = resolvedLink(raw, relativeTo: destination.deletingLastPathComponent())
        // The source may already be gone because the app was moved to Trash. Match
        // the exact managed layout, including the nested CLI-plugin directory, rather
        // than requiring the old target to still exist.
        guard MorbCliPlugins.isManagedInstalledBinaryTarget(
            resolved, binaryName: destination.lastPathComponent)
        else { return false }
        do {
            try fm.removeItem(at: destination)
            return true
        } catch {
            throw MorbError.io("could not remove \(destination.path): \(error.localizedDescription)")
        }
    }

    private static func removeProfileBlock(environment: [String: String]) throws -> Bool {
        guard environment["MORBSTACK_HOME"]?.isEmpty != false,
              let profile = loginProfile(environment: environment),
              let old = try? String(contentsOf: profile, encoding: .utf8),
              old.contains(profileBlock)
        else { return false }
        let new = old.replacingOccurrences(of: profileBlock, with: "")
        do {
            try new.write(to: profile, atomically: true, encoding: .utf8)
            return true
        } catch {
            throw MorbError.io("could not update \(profile.path): \(error.localizedDescription)")
        }
    }

    private static func resolvedLink(_ raw: String, relativeTo directory: URL) -> String {
        if raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw).standardizedFileURL.path
        }
        return directory.appendingPathComponent(raw).standardizedFileURL.path
    }
}
