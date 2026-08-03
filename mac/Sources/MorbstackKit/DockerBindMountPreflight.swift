// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Read-only admission checks for bind sources in a Docker container-create request.
// The check deliberately only reasons about the live VM share contract; it never
// adds a share, edits configuration, or substitutes a guest-local directory.

import Foundation

/// Checks bind sources in the portion of a normal Docker container-create document
/// Morbstack can verify before it relays the request to the guest Engine.
public enum DockerBindMountPreflight {

    public enum Verdict: Equatable, Sendable {
        case allowed
        case rejected(message: String)
    }

    /// Inspects bind mounts expressed by `HostConfig.Binds` and top-level `Mounts`.
    ///
    /// Invalid JSON and shapes owned by the Engine are allowed through so dockerd
    /// remains the authority for Docker's full create grammar. A legacy `Binds`
    /// source may be absent, because Docker's `-v` form creates that directory. An
    /// explicit `Mounts` bind source must already exist, matching Docker's `--mount`
    /// behavior.
    ///
    /// - Parameters:
    ///   - body: The JSON document from `POST /containers/create`.
    ///   - shares: The directories attached to the running VM, not prospective config.
    ///   - guestShareStates: The guest's report for those attached share roots.
    ///   - sourceExists: Injected for deterministic tests. It is only used for
    ///     explicit `Mounts` bind sources, which Docker itself requires to exist.
    ///   - sourcePathResolving: Resolves symlinks through the nearest existing
    ///     ancestor. It is injected so the preflight's escape behavior is testable
    ///     without depending on this process's filesystem.
    public static func inspectContainerCreate(
        body: Data,
        shares: [MorbDirectoryShare],
        guestShareStates: [String: MorbShares.GuestMountState],
        sourceExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        sourcePathResolving: (String) -> String = resolveSourcePathThroughExistingAncestor
    ) -> Verdict {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return .allowed
        }

        var bindSources: [BindSource] = []
        if let hostConfig = object["HostConfig"] as? [String: Any],
           let rawBinds = hostConfig["Binds"] as? [Any]
        {
            for rawBind in rawBinds {
                guard let rawBind = rawBind as? String,
                      let source = legacyBindSource(in: rawBind)
                else { continue }
                bindSources.append(BindSource(path: source, mustExist: false))
            }
        }

        if let mounts = object["Mounts"] as? [Any] {
            for mount in mounts {
                guard let mount = mount as? [String: Any],
                      (mount["Type"] as? String)?.lowercased() == "bind",
                      let source = mount["Source"] as? String
                else { continue }
                bindSources.append(BindSource(path: source, mustExist: true))
            }
        }

        for bindSource in bindSources {
            // Docker's API does not expand `~`; a command shell does that before it
            // sends the request. Check absoluteness first so an API client cannot
            // have a literal `~/project` silently treated as this daemon's home.
            guard bindSource.path.hasPrefix("/") else {
                return .rejected(
                    message: "invalid mount config for type \"bind\": bind source path must be absolute: \(bindSource.path)")
            }
            let source = MorbShares.canonicalBindSource(bindSource.path)

            // The original spelling has to enter through a live share. A source
            // under an unshared root could happen to point at a shared directory by
            // symlink on the host, but the guest cannot even begin that traversal.
            guard coveringShare(for: source, in: shares) != nil else {
                return .rejected(
                    message: "invalid mount config for type \"bind\": bind source path is not shared with the Morbstack VM: \(source) (add a shared_paths root that contains it, then restart Morbstack)")
            }

            // A symlink inside a shared root can point outside it. dockerd resolves
            // that symlink in the guest, where an unshared destination is exactly
            // the empty guest-local directory this preflight exists to prevent. For
            // a missing legacy `-v` source, resolving its nearest existing ancestor
            // also checks where Docker would create it.
            let resolvedSource = MorbShares.canonicalHostPath(sourcePathResolving(source))
            guard let share = coveringShare(for: resolvedSource, in: shares) else {
                return .rejected(
                    message: "invalid mount config for type \"bind\": bind source path resolves outside directories shared with the Morbstack VM: \(source) -> \(resolvedSource) (add the resolved root to shared_paths, then restart Morbstack)")
            }

            guard let mountState = guestShareStates[share.path] else {
                return .rejected(
                    message: "invalid mount config for type \"bind\": Morbstack cannot verify that \(share.path) is mounted in the running VM; restart Morbstack to use a guest that reports VirtioFS share state")
            }
            guard mountState == .mounted else {
                return .rejected(
                    message: "invalid mount config for type \"bind\": share \(share.path) is not mounted in the running VM; repair the share and restart Morbstack")
            }

            if bindSource.mustExist, !sourceExists(source) {
                return .rejected(
                    message: "invalid mount config for type \"bind\": bind source path does not exist: \(source)")
            }
        }
        return .allowed
    }

    private struct BindSource {
        var path: String
        var mustExist: Bool
    }

    /// Returns the host path from Docker's legacy `source:target[:options]` form.
    /// Non-absolute sources are named volumes rather than host binds, so the Engine
    /// owns them. A malformed entry is also left to Docker to diagnose.
    private static func legacyBindSource(in rawBind: String) -> String? {
        guard rawBind.hasPrefix("/"),
              let separator = rawBind.firstIndex(of: ":")
        else { return nil }
        let source = String(rawBind[..<separator])
        let remainder = rawBind[rawBind.index(after: separator)...]
        guard remainder.hasPrefix("/") else { return nil }
        return source
    }

    private static func coveringShare(
        for source: String,
        in shares: [MorbDirectoryShare]
    ) -> MorbDirectoryShare? {
        // Prefer the narrowest root if a malformed/legacy VM configuration has
        // nested entries. The normal planner collapses them, but the live list is
        // the truth this check must safely handle.
        shares
            .filter { share in
                let root = MorbShares.canonicalHostPath(share.path)
                return source == root || source.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            }
            .max { lhs, rhs in
                MorbShares.canonicalHostPath(lhs.path).count < MorbShares.canonicalHostPath(rhs.path).count
            }
    }

    /// Resolves existing symlinks without falsely treating a missing legacy `-v`
    /// source as absent from its host share. `URL.resolvingSymlinksInPath()` resolves
    /// only paths that exist; walk up to the nearest existing ancestor, resolve that,
    /// then append the still-missing components. The result is used exclusively for
    /// share coverage validation and is never substituted into the Docker request.
    private static func resolveSourcePathThroughExistingAncestor(_ source: String) -> String {
        var candidate = source
        var missingComponents: [String] = []

        while candidate != "/", !FileManager.default.fileExists(atPath: candidate) {
            let url = URL(fileURLWithPath: candidate)
            missingComponents.insert(url.lastPathComponent, at: 0)
            candidate = url.deletingLastPathComponent().path
        }

        var resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath()
        for component in missingComponents {
            resolved.appendPathComponent(component)
        }
        return resolved.path
    }
}
