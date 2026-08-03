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

    /// Inspects bind mounts expressed by `HostConfig.Binds`, `HostConfig.Mounts`,
    /// and the legacy top-level `Mounts` shape.
    ///
    /// Invalid JSON and shapes owned by the Engine are allowed through so dockerd
    /// remains the authority for Docker's full create grammar. A legacy `Binds`
    /// source may be absent, because Docker's `-v` form creates that directory. An
    /// explicit `Mounts` bind source must already exist, matching Docker's `--mount`
    /// behavior. Read-only, recursive, propagation, and volume options remain opaque
    /// to this host-share check and are relayed unchanged for dockerd to implement.
    ///
    /// - Parameters:
    ///   - body: The JSON document from `POST /containers/create`.
    ///   - shares: The directories attached to the running VM, not prospective config.
    ///   - guestShareStates: The guest's report for those attached share roots.
    ///   - guestTmpAliasMounted: Whether the guest confirmed its literal `/tmp`
    ///     alias to the live `/private/tmp` share. `nil` is an older guest that
    ///     cannot prove the alias; it is not treated as a successful alias.
    ///   - sourceExists: Injected for deterministic tests. It is only used for
    ///     explicit `Mounts` bind sources, which Docker itself requires to exist.
    ///   - sourcePathResolving: Resolves symlinks through the nearest existing
    ///     ancestor. It is injected so the preflight's escape behavior is testable
    ///     without depending on this process's filesystem.
    public static func inspectContainerCreate(
        body: Data,
        shares: [MorbDirectoryShare],
        guestShareStates: [String: MorbShares.GuestMountState],
        guestTmpAliasMounted: Bool? = nil,
        sourceExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        sourcePathResolving: ((String) -> String)? = nil
    ) -> Verdict {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return .allowed
        }
        let sourcePathResolving = sourcePathResolving ?? resolveSourcePathThroughExistingAncestor

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

        if let hostConfig = object["HostConfig"] as? [String: Any] {
            bindSources.append(contentsOf: explicitBindSources(in: hostConfig["Mounts"]))
        }

        // Keep accepting the older top-level shape as a compatibility backstop. The
        // current Engine API places these under HostConfig, and missing that field
        // would let an unshared source reach dockerd and become guest-local.
        bindSources.append(contentsOf: explicitBindSources(in: object["Mounts"]))

        for bindSource in bindSources {
            // Docker's API does not expand `~`; a command shell does that before it
            // sends the request. Check absoluteness first so an API client cannot
            // have a literal `~/project` silently treated as this daemon's home.
            guard bindSource.path.hasPrefix("/") else {
                return .rejected(
                    message: "invalid mount config for type \"bind\": bind source path must be absolute: \(bindSource.path)")
            }

            // `docker-outside-of-docker` and ordinary Docker-in-Docker tooling bind
            // the daemon host's standard socket into a container. Here the daemon
            // host is the guest, not macOS: `/var/run` resolves there to `/run`, where
            // dockerd owns the socket. Do not reinterpret this exact guest resource as
            // the Mac's `/private/var` alias or demand a VirtioFS share/source file on
            // the Mac. Every other `/var` source remains below the explicit alias
            // rejection, so this does not create a general guest-system escape hatch.
            if isGuestDockerSocket(bindSource.path) {
                continue
            }

            // `/tmp` is a macOS symlink to `/private/tmp`, while the guest starts
            // with its own tmpfs at the literal `/tmp`. The guest can mirror the
            // alias only after its `/private/tmp` VirtioFS share mounts; a successful
            // share alone is not proof that that second bind mount worked. Do not
            // relay a literal `/tmp` request to a guest that has not proved the
            // alias, because dockerd would create a guest-local source instead.
            if isBareTmpAlias(bindSource.path), guestTmpAliasMounted != true {
                return .rejected(
                    message: "invalid mount config for type \"bind\": bind source path uses macOS /tmp, but the running VM has not confirmed its /tmp alias to the shared /private/tmp directory; repair that share and restart Morbstack")
            }

            // macOS also aliases `/var` and `/etc` through `/private`, but those
            // literal guest paths are part of the Docker VM's own system. Unlike
            // `/tmp`, they cannot safely be aliased without hiding the guest's
            // runtime or configuration. Require the caller to choose the real
            // `/private/...` spelling instead of approving a request that dockerd
            // would resolve against guest-local system data.
            if let alias = unsupportedBareSystemAlias(bindSource.path) {
                return .rejected(
                    message: "invalid mount config for type \"bind\": bind source path uses the macOS /\(alias) alias, but /\(alias) is a guest system path; use the explicit /private/\(alias) source path after sharing it")
            }
            let source = MorbShares.canonicalBindSource(bindSource.path)

            // The original spelling has to enter through a live share. A source
            // under an unshared root could happen to point at a shared directory by
            // symlink on the host, but the guest cannot even begin that traversal.
            guard coveringShare(for: source, in: shares) != nil else {
                return .rejected(
                    message: "invalid mount config for type \"bind\": bind source path is not shared with the Morbstack VM: \(bindSource.path) (add a shared_paths root that contains it, then restart Morbstack)")
            }

            // A symlink inside a shared root can point outside it. dockerd resolves
            // that symlink in the guest, where an unshared destination is exactly
            // the empty guest-local directory this preflight exists to prevent. For
            // a missing legacy `-v` source, resolving its nearest existing ancestor
            // also checks where Docker would create it.
            let resolvedSource = MorbShares.canonicalHostPath(sourcePathResolving(bindSource.path))
            guard let share = coveringShare(for: resolvedSource, in: shares) else {
                return .rejected(
                    message: "invalid mount config for type \"bind\": bind source path resolves outside directories shared with the Morbstack VM: \(bindSource.path) -> \(resolvedSource) (add the resolved root to shared_paths, then restart Morbstack)")
            }

            guard let mountState = guestShareStates[share.path] else {
                return .rejected(
                    message: "invalid mount config for type \"bind\": Morbstack cannot verify that \(share.path) is mounted in the running VM; restart Morbstack to use a guest that reports VirtioFS share state")
            }
            guard mountState == .mounted else {
                return .rejected(
                    message: "invalid mount config for type \"bind\": share \(share.path) is not mounted in the running VM; repair the share and restart Morbstack")
            }

            if bindSource.mustExist, !sourceExists(bindSource.path) {
                return .rejected(
                    message: "invalid mount config for type \"bind\": bind source path does not exist: \(bindSource.path)")
            }
        }
        return .allowed
    }

    /// Extracts explicit `--mount type=bind` style sources from one Engine API
    /// location. Docker currently uses `HostConfig.Mounts`; the caller retains the
    /// top-level form as a defensive compatibility path.
    private static func explicitBindSources(in value: Any?) -> [BindSource] {
        guard let mounts = value as? [Any] else { return [] }
        return mounts.compactMap { rawMount in
            guard let mount = rawMount as? [String: Any],
                  (mount["Type"] as? String)?.lowercased() == "bind",
                  let source = mount["Source"] as? String
            else { return nil }
            return BindSource(path: source, mustExist: true)
        }
    }

    private struct BindSource {
        var path: String
        var mustExist: Bool
    }

    private static func isBareTmpAlias(_ source: String) -> Bool {
        source == "/tmp" || source.hasPrefix("/tmp/")
    }

    private static func isGuestDockerSocket(_ source: String) -> Bool {
        source == "/var/run/docker.sock" || source == "/run/docker.sock"
    }

    private static func unsupportedBareSystemAlias(_ source: String) -> String? {
        for alias in ["var", "etc"] {
            let path = "/\(alias)"
            if source == path || source.hasPrefix(path + "/") {
                return alias
            }
        }
        return nil
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
