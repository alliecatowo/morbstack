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

    /// The result of validating a container-create document before it reaches the
    /// guest Engine.
    ///
    /// The body is returned unchanged unless a verified macOS system alias must be
    /// made explicit for the Linux guest. In that case, the rewritten JSON preserves
    /// every semantic field except the affected bind source; the destination and
    /// every Docker-owned mount option remain untouched.
    public enum Preparation {
        case allowed(body: Data, wasRewritten: Bool)
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
    ///   - hostDockerSocketPath: The Mac-side Unix socket this daemon publishes the
    ///     Docker API at (``MorbPaths/dockerSocket`` in the running daemon). A bind
    ///     source that names it — directly, or through a symlink such as the
    ///     `~/.docker/run/docker.sock` discovery link — is the same resource the
    ///     guest owns at `/var/run/docker.sock`, and is rewritten to that guest
    ///     spelling. `nil` disables the rewrite.
    ///   - sourceExists: Injected for deterministic tests. It is used for explicit
    ///     `Mounts` bind sources, which Docker itself requires to exist, and for
    ///     `/etc` or `/var` aliases before Morbstack can safely rewrite them.
    ///   - sourcePathResolving: Resolves symlinks through the nearest existing
    ///     ancestor. It is injected so the preflight's escape behavior is testable
    ///     without depending on this process's filesystem.
    public static func inspectContainerCreate(
        body: Data,
        shares: [MorbDirectoryShare],
        guestShareStates: [String: MorbShares.GuestMountState],
        guestTmpAliasMounted: Bool? = nil,
        hostDockerSocketPath: String? = nil,
        sourceExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        sourcePathResolving: ((String) -> String)? = nil
    ) -> Verdict {
        switch prepareContainerCreate(
            body: body,
            shares: shares,
            guestShareStates: guestShareStates,
            guestTmpAliasMounted: guestTmpAliasMounted,
            hostDockerSocketPath: hostDockerSocketPath,
            sourceExists: sourceExists,
            sourcePathResolving: sourcePathResolving)
        {
        case .allowed:
            return .allowed
        case .rejected(let message):
            return .rejected(message: message)
        }
    }

    /// Validates the document and makes bare macOS `/etc` and `/var` aliases safe
    /// for the Linux guest.
    ///
    /// The VM cannot mount host `/etc` or `/var` over its own system directories:
    /// doing so would hide guest configuration or Docker's runtime. Instead, an
    /// existing alias source is resolved on macOS, proved to sit below a mounted
    /// VirtioFS share, and rewritten to that verified guest-visible host path. This
    /// is intentionally narrower than Docker's legacy `-v` directory-creation
    /// behavior: an absent system alias has no host inode whose identity can be
    /// preserved, so it is rejected rather than allowed to become a guest path.
    public static func prepareContainerCreate(
        body: Data,
        shares: [MorbDirectoryShare],
        guestShareStates: [String: MorbShares.GuestMountState],
        guestTmpAliasMounted: Bool? = nil,
        hostDockerSocketPath: String? = nil,
        sourceExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        sourcePathResolving: ((String) -> String)? = nil
    ) -> Preparation {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return .allowed(body: body, wasRewritten: false)
        }
        let sourcePathResolving = sourcePathResolving ?? resolveSourcePathThroughExistingAncestor
        // The daemon socket's own canonical identity, resolved through the same
        // machinery as bind sources so a `MORBSTACK_HOME` under `/tmp` (a macOS
        // `/private` alias) or a symlinked home compares equal to what a client
        // derived from `DOCKER_HOST` or a discovery link.
        let canonicalHostDockerSocket = hostDockerSocketPath.map {
            MorbShares.canonicalHostPath(sourcePathResolving($0))
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

        if let hostConfig = object["HostConfig"] as? [String: Any] {
            bindSources.append(contentsOf: explicitBindSources(in: hostConfig["Mounts"]))
        }

        // Keep accepting the older top-level shape as a compatibility backstop. The
        // current Engine API places these under HostConfig, and missing that field
        // would let an unshared source reach dockerd and become guest-local.
        bindSources.append(contentsOf: explicitBindSources(in: object["Mounts"]))

        var aliasRewrites: [String: String] = [:]

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

            // Testcontainers-style clients derive "the Docker socket" from their
            // discovery result — `DOCKER_HOST`, or the per-user
            // `~/.docker/run/docker.sock` link — and bind that Mac-side path into
            // helper containers (Ryuk, docker-outside-of-docker). That path names
            // this daemon's own API socket, a resource the guest already owns at
            // `/var/run/docker.sock`; a VirtioFS share could never carry the live
            // socket inode across. Rewrite the source to the guest spelling of the
            // same endpoint. The match is an exact, symlink-resolved identity with
            // the daemon's published socket, so an unrelated engine's socket (for
            // example a live Docker Desktop `~/.docker/run/docker.sock`) is never
            // silently redirected to Morbstack.
            if let canonicalHostDockerSocket,
               MorbShares.canonicalHostPath(sourcePathResolving(bindSource.path))
                   == canonicalHostDockerSocket
            {
                aliasRewrites[bindSource.path] = "/var/run/docker.sock"
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
            // literal guest paths are part of the Docker VM's own system. They
            // cannot be made guest aliases without hiding the guest runtime or
            // configuration. Rewrite them only after proving the exact existing
            // Mac source resolves beneath a live share. That lets `-v /etc/hosts`
            // preserve the Mac file's identity without ever letting dockerd see
            // the guest's own `/etc/hosts`.
            if let alias = unsupportedBareSystemAlias(bindSource.path) {
                guard sourceExists(bindSource.path) else {
                    return .rejected(
                        message: "invalid mount config for type \"bind\": macOS /\(alias) alias source must exist before Morbstack can safely bind it: \(bindSource.path)")
                }

                let resolvedSource = MorbShares.canonicalHostPath(
                    sourcePathResolving(bindSource.path))
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

                aliasRewrites[bindSource.path] = resolvedSource
                continue
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
        guard !aliasRewrites.isEmpty else {
            return .allowed(body: body, wasRewritten: false)
        }

        var rewrittenObject = object
        rewriteAliasSources(in: &rewrittenObject, aliases: aliasRewrites)
        guard let rewrittenBody = try? JSONSerialization.data(withJSONObject: rewrittenObject) else {
            return .rejected(
                message: "invalid mount config for type \"bind\": Morbstack could not safely prepare the verified macOS bind source")
        }
        return .allowed(body: rewrittenBody, wasRewritten: true)
    }

    /// Replaces exact source fields only in the three create-document locations
    /// already inspected above. A volume or an opaque field whose string happens to
    /// look like a path is deliberately left alone.
    private static func rewriteAliasSources(
        in object: inout [String: Any],
        aliases: [String: String]
    ) {
        if var hostConfig = object["HostConfig"] as? [String: Any] {
            if var rawBinds = hostConfig["Binds"] as? [Any] {
                rawBinds = rawBinds.map { rawBind in
                    guard let rawBind = rawBind as? String,
                          let source = legacyBindSource(in: rawBind),
                          let replacement = aliases[source],
                          let separator = rawBind.firstIndex(of: ":")
                    else { return rawBind }
                    return replacement + String(rawBind[separator...])
                }
                hostConfig["Binds"] = rawBinds
            }
            rewriteExplicitAliasSources(in: &hostConfig, key: "Mounts", aliases: aliases)
            object["HostConfig"] = hostConfig
        }
        rewriteExplicitAliasSources(in: &object, key: "Mounts", aliases: aliases)
    }

    private static func rewriteExplicitAliasSources(
        in object: inout [String: Any],
        key: String,
        aliases: [String: String]
    ) {
        guard var mounts = object[key] as? [Any] else { return }
        mounts = mounts.map { rawMount in
            guard var mount = rawMount as? [String: Any],
                  (mount["Type"] as? String)?.lowercased() == "bind",
                  let source = mount["Source"] as? String,
                  let replacement = aliases[source]
            else { return rawMount }
            mount["Source"] = replacement
            return mount
        }
        object[key] = mounts
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
    /// then append the still-missing components. For ordinary sources the result is
    /// used exclusively for share coverage validation. An existing bare macOS `/etc`
    /// or `/var` alias is the deliberately narrow exception: its verified resolved
    /// path becomes the source relayed to the guest so it cannot be substituted with
    /// guest system content.
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
