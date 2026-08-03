// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Volumes and verify both need to get *inside* an engine's view of a named volume, and
// the Docker Engine API has no "read a volume" endpoint — only "read a path inside a
// container". So both operations create a small, throwaway container with the volume
// mounted, do their work through it, and remove it again. That container is
// infrastructure this module owns end to end: created here, removed here, never left
// behind even when the step it was for fails.
//
// This is the one place `morb migrate` creates anything on a *source* engine (which may
// be Docker Desktop). It is a deliberate, narrow exception to "read-only" — reading a
// volume's bytes is impossible without it — and every container it creates is removed
// again in the same function, success or failure. Nothing here ever touches an image,
// a volume, or a container the user did not ask this migration to touch.

import Foundation
import MorbFeatures

enum HelperContainerError: Error, CustomStringConvertible {
    case noImageAvailable
    case commandFailed(exitCode: Int, stderr: String)

    var description: String {
        switch self {
        case .noImageAvailable:
            return "no image is available on this engine to run a helper container from"
        case .commandFailed(let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "helper container exited \(code)" + (trimmed.isEmpty ? "" : ": \(trimmed)")
        }
    }
}

enum HelperImage {

    /// Repo name fragments known to ship `find` and `sha256sum` in a base install,
    /// checked in this order. A heuristic, not a guarantee — an image tagged `alpine`
    /// that was rebuilt without coreutils would fool it — but it is the same kind of
    /// heuristic `docker.io/library/*` tagging conventions make reliable in practice,
    /// and ``runAndCollectOutput`` surfaces a clear error the moment the command it
    /// actually runs does not exist, rather than trusting the guess silently.
    private static let coreutilsHints = ["alpine", "busybox", "debian", "ubuntu", "fedora"]

    /// The first already-present image, by any reference that resolves — used by the
    /// pure archive-copy path in ``VolumeMigrationTransaction``, which never executes a command
    /// inside the container it creates and so does not care what the image contains.
    static func existingAny(on client: EngineClient) throws -> String? {
        let images = try client.jsonArray("GET", "/images/json", timeout: 15)
        for image in images {
            if let tags = JSONRead.array(image, "RepoTags") as? [String],
                let first = tags.first, first != "<none>:<none>" {
                return first
            }
        }
        // Every image is dangling (untagged) — still usable by digest.
        if let first = images.first, let id = JSONRead.string(first, "Id") {
            return id
        }
        return nil
    }

    /// Best-effort compatibility wrapper for older CLI paths that cannot yet
    /// distinguish a failed image inventory from an empty one. New transactions use
    /// ``existingAny(on:)`` so they never turn an unavailable Engine into an implicit
    /// network pull decision.
    static func anyExisting(on client: EngineClient) -> String? {
        try? existingAny(on: client)
    }

    /// An already-present image likely to have `find`/`sha256sum` — used by
    /// ``VerifyCommand``, which does execute a command.
    static func existingWithCoreutils(on client: EngineClient) -> String? {
        guard let images = try? client.jsonArray("GET", "/images/json", timeout: 15) else { return nil }
        for hint in coreutilsHints {
            for image in images {
                guard let tags = JSONRead.array(image, "RepoTags") as? [String] else { continue }
                if tags.contains(where: { $0.lowercased().hasPrefix(hint) }) {
                    return tags.first(where: { $0.lowercased().hasPrefix(hint) })
                }
            }
        }
        return nil
    }

    /// `POST /images/create?fromImage=...&tag=...` — a real pull from the configured
    /// registry. Only ever called after the caller has obtained the user's explicit
    /// consent; see ``VolumesCommand`` and ``VerifyCommand`` for the prompts.
    static func pull(_ reference: String, on client: EngineClient, timeout: TimeInterval = 300) throws {
        let parts = reference.split(separator: ":", maxSplits: 1)
        let repo = String(parts[0])
        let tag = parts.count > 1 ? String(parts[1]) : "latest"
        let response = try client.request(
            "POST", "/images/create",
            query: [("fromImage", repo), ("tag", tag)],
            timeout: timeout)
        guard response.isSuccess else {
            throw EngineError.engine(status: response.status, message: response.engineMessage)
        }
        // The pull stream is JSON-lines progress; a failure partway through still comes
        // back 200 with an `"error"` field in one of the lines rather than a non-2xx.
        if response.text.contains("\"error\"") {
            throw EngineError.malformed("pulling \(reference) reported an error mid-stream")
        }
    }
}

/// One throwaway container: mounts named volumes, optionally runs a command, and is
/// always removed by the same function that created it.
enum HelperContainer {

    /// Creates a container with `volumeName` mounted at `/data`, does not start it, and
    /// hands back its id. Used by the pure archive-copy path, which reads/writes
    /// through `/containers/{id}/archive` on a container that never runs a process —
    /// `docker cp` semantics work on a created-but-not-started container, so there is
    /// no image content or entrypoint this depends on at all.
    static func createMounted(
        on client: EngineClient, image: String, volumeName: String, readOnly: Bool
    ) throws -> String {
        let bind = readOnly ? "\(volumeName):/data:ro" : "\(volumeName):/data"
        let body: [String: Any] = [
            "Image": image,
            "Cmd": ["true"],
            "HostConfig": ["Binds": [bind]],
        ]
        let response = try client.jsonObject("POST", "/containers/create", body: body, timeout: 30)
        guard let id = JSONRead.string(response, "Id") else {
            throw EngineError.malformed("container create did not return an Id")
        }
        return id
    }

    /// Removes a container this module created. Best-effort: a helper container that
    /// fails to remove is a small amount of clutter on the engine it was created on,
    /// never data loss, so this logs rather than throws — the caller's actual result
    /// (did the copy/checksum succeed) should not be masked by cleanup failing.
    @discardableResult
    static func remove(on client: EngineClient, id: String) -> String? {
        do {
            let response = try client.request("DELETE", "/containers/\(id)", query: [("force", "1"), ("v", "1")], timeout: 30)
            if !response.isSuccess {
                return "could not remove helper container \(String(id.prefix(12))): \(response.engineMessage)"
            }
        } catch {
            return "could not remove helper container \(String(id.prefix(12))): \(error)"
        }
        return nil
    }

    /// Creates a container with `volumeName` mounted at `/data`, runs `cmd` to
    /// completion, and returns its stdout — used only by ``VerifyCommand``'s checksum
    /// manifest, the one place this module executes anything inside a container rather
    /// than just reading its filesystem through the archive endpoint.
    ///
    /// - Throws: ``HelperContainerError/commandFailed(exitCode:stderr:)`` when the
    ///   command exits non-zero — most commonly "sha256sum: not found", which is
    ///   exactly the wrong-image-guessed case ``HelperImage/existingWithCoreutils(on:)``
    ///   cannot rule out in advance.
    static func run(
        on client: EngineClient, image: String, volumeName: String, cmd: [String], timeout: TimeInterval = 120
    ) throws -> String {
        let body: [String: Any] = [
            "Image": image,
            "Cmd": cmd,
            "Tty": false,
            "HostConfig": ["Binds": ["\(volumeName):/data:ro"]],
        ]
        let created = try client.jsonObject("POST", "/containers/create", body: body, timeout: 30)
        guard let id = JSONRead.string(created, "Id") else {
            throw EngineError.malformed("container create did not return an Id")
        }
        defer { _ = remove(on: client, id: id) }

        try client.request("POST", "/containers/\(id)/start", timeout: 30)
        let waited = try client.jsonObject("POST", "/containers/\(id)/wait", timeout: timeout)
        let exitCode = JSONRead.int(waited, "StatusCode") ?? -1

        let logs = try client.request(
            "GET", "/containers/\(id)/logs", query: [("stdout", "1"), ("stderr", "1")], timeout: 30)
        let demuxed = DockerStreamDemux.split(logs.body)

        guard exitCode == 0 else {
            throw HelperContainerError.commandFailed(exitCode: exitCode, stderr: demuxed.stderr.isEmpty
                ? String(decoding: demuxed.stdout, as: UTF8.self) : String(decoding: demuxed.stderr, as: UTF8.self))
        }
        return String(decoding: demuxed.stdout, as: UTF8.self)
    }
}
