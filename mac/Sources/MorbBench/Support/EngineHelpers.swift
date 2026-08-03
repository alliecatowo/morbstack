// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The narrow slice of the Engine API this harness needs: pull an image if it
// is not already present, run commands in throwaway containers, and — for
// `git-status-bindmount`, which needs `git` inside the guest and no upstream
// image ships exactly that — commit a container into a reusable local image.
// No attach, no exec, no compose; every benchmark that needs more than this
// is not one of the eight the task defines.

import Foundation
import MorbFeatures

public enum EngineHelpers {

    public struct RunOutcome {
        public var exitCode: Int
        public var stdout: String
        public var stderr: String
    }

    /// `true` plus how long it took, when `reference` had to be pulled;
    /// `false, 0` when it was already present. Every benchmark that calls
    /// this reports the duration in its notes when a pull happened, per the
    /// task brief's "if the network is needed, say so".
    @discardableResult
    public static func ensureImage(_ engine: EngineClient, reference: String, timeout: TimeInterval = 300) throws
        -> (pulled: Bool, duration: TimeInterval)
    {
        if (try? engine.jsonObject("GET", "/images/\(reference)/json")) != nil {
            return (false, 0)
        }
        let (name, tag) = splitReference(reference)
        let started = Date()
        var pullError: Error?
        try engine.stream(
            "POST", "/images/create", query: [("fromImage", name), ("tag", tag)], timeout: timeout,
            onChunk: { chunk, _ in
                // Docker reports layer-pull failures as 200-with-an-"error"-field
                // JSON lines inside an otherwise-successful stream, not as an
                // HTTP error status — so the only way to see one is to look.
                if let text = String(data: chunk, encoding: .utf8), text.contains("\"error\"") {
                    pullError = EngineError.malformed("image pull reported an error: \(Format.truncate(text, 200))")
                }
                return true
            })
        if let pullError { throw pullError }
        return (true, Date().timeIntervalSince(started))
    }

    /// Creates and starts a container, returning its id without waiting for it to finish.
    public static func createAndStart(
        _ engine: EngineClient, image: String, command: [String]?, env: [String]? = nil,
        binds: [String]? = nil, workingDir: String? = nil, timeout: TimeInterval = 120
    ) throws -> String {
        var body: [String: Any] = ["Image": image, "Tty": false]
        if let command { body["Cmd"] = command }
        if let env { body["Env"] = env }
        if let workingDir { body["WorkingDir"] = workingDir }
        if let binds { body["HostConfig"] = ["Binds": binds] }
        let created = try engine.jsonObject("POST", "/containers/create", body: body, timeout: timeout)
        guard let id = created["Id"] as? String else {
            throw EngineError.malformed("container create did not return an Id")
        }
        try engine.request("POST", "/containers/\(id)/start", timeout: timeout)
        return id
    }

    /// Blocks until `id` exits, returning its status code.
    public static func wait(_ engine: EngineClient, id: String, timeout: TimeInterval = 120) throws -> Int {
        let waited = try engine.jsonObject("POST", "/containers/\(id)/wait", timeout: timeout)
        return JSONRead.int(waited, "StatusCode") ?? -1
    }

    /// Reads the complete (non-streamed) stdout/stderr of a finished container.
    public static func collectLogs(_ engine: EngineClient, id: String, timeout: TimeInterval = 60) throws -> (
        stdout: String, stderr: String
    ) {
        let response = try engine.request(
            "GET", "/containers/\(id)/logs", query: [("stdout", "true"), ("stderr", "true")], timeout: timeout)
        let demuxed = DockerStreamDemux.split(response.body)
        return (String(decoding: demuxed.stdout, as: UTF8.self), String(decoding: demuxed.stderr, as: UTF8.self))
    }

    /// Force-removes a container, ignoring "already gone".
    public static func removeContainer(_ engine: EngineClient, id: String) {
        _ = try? engine.request("DELETE", "/containers/\(id)", query: [("force", "true")], timeout: 30)
    }

    /// Creates, starts, waits for, and removes a container running `command`
    /// in `image`. The container is always removed, success or failure — a
    /// throw from this function still means no container was left behind,
    /// because removal happens in a `defer` around the whole body.
    public static func runOnce(
        _ engine: EngineClient, image: String, command: [String]?, env: [String]? = nil,
        binds: [String]? = nil, workingDir: String? = nil, timeout: TimeInterval = 120
    ) throws -> RunOutcome {
        let id = try createAndStart(
            engine, image: image, command: command, env: env, binds: binds, workingDir: workingDir,
            timeout: timeout)
        defer { removeContainer(engine, id: id) }
        let exitCode = try wait(engine, id: id, timeout: timeout)
        let logs = try collectLogs(engine, id: id, timeout: timeout)
        return RunOutcome(exitCode: exitCode, stdout: logs.stdout, stderr: logs.stderr)
    }

    /// Commits a (normally already-exited) container into a local image tag.
    public static func commit(_ engine: EngineClient, container: String, repo: String, tag: String) throws {
        _ = try engine.jsonObject(
            "POST", "/commit", query: [("container", container), ("repo", repo), ("tag", tag)], timeout: 60)
    }

    /// Force-removes an image, ignoring "already gone" and "in use by a
    /// dangling reference" — this harness owns every tag it creates.
    public static func removeImage(_ engine: EngineClient, reference: String) {
        _ = try? engine.request("DELETE", "/images/\(reference)", query: [("force", "true")], timeout: 30)
    }

    /// Creates a named volume, ignoring "already exists".
    public static func ensureVolume(_ engine: EngineClient, name: String) throws {
        _ = try engine.jsonObject("POST", "/volumes/create", body: ["Name": name])
    }

    /// Removes a named volume, ignoring "does not exist".
    public static func removeVolume(_ engine: EngineClient, name: String) {
        _ = try? engine.request("DELETE", "/volumes/\(name)", query: [("force", "true")])
    }

    private static func splitReference(_ reference: String) -> (name: String, tag: String) {
        guard let colon = reference.lastIndex(of: ":"), !reference[reference.index(after: colon)...].contains("/")
        else { return (reference, "latest") }
        return (String(reference[..<colon]), String(reference[reference.index(after: colon)...]))
    }
}
