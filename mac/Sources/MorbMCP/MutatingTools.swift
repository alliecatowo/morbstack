// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The mutating tool surface: everything that changes the state of the engine,
// the guest VM, or the host's compose/build tooling. Every one of these is
// default-denied — see Permissions.swift for the resolver, Server.swift for
// where the grant check actually runs before a handler is ever called.
//
// A tool handler here is only reached once permission has already been
// granted; it does not re-check its own group grant. It *does* still need to
// know about its own argument-level guards, because a guard only blocks the
// specific argument value it defines (e.g. `force:true`), not the whole call —
// the non-force path through `container_remove` runs the same handler.

import Foundation
import MorbFeatures
import MorbstackKit

enum MutatingTools {

    static let all: [ToolSpec] = [
        containerStart, containerStop, containerRestart, containerRemove, containerExec,
        composeUp, composeDown, imagePull, imageRemove, imageBuild,
        prune, engineStart, engineStop,
    ]

    // MARK: - Container lifecycle

    static let containerStart = ToolSpec(
        name: "container_start",
        summary: "Start a stopped container.",
        inputSchema: Schema.object(["id": Schema.string("Container ID or name.")], required: ["id"]),
        readOnly: false, destructive: false, group: .containersWrite
    ) { context, arguments in
        do {
            let id = try Args.requireString(arguments, "id")
            let response = try context.engine.request("POST", "/containers/\(id)/start", timeout: 30)
            return lifecycleResult(id: id, action: "start", response: response, noOpStatus: 304)
        } catch let error as ArgError {
            return .errorText(error.description)
        } catch {
            return .errorText(describeEngineError(error))
        }
    }

    static let containerStop = ToolSpec(
        name: "container_stop",
        summary: "Stop a running container, giving it time to shut down cleanly first.",
        inputSchema: Schema.object(
            [
                "id": Schema.string("Container ID or name."),
                "timeout_seconds": Schema.integer(
                    "Grace period before Docker sends SIGKILL.", minimum: 0, maximum: 120, defaultValue: 10),
            ], required: ["id"]),
        readOnly: false, destructive: false, group: .containersWrite
    ) { context, arguments in
        do {
            let id = try Args.requireString(arguments, "id")
            let graceSeconds = Args.boundedInt(arguments, "timeout_seconds", default: 10, minimum: 0, maximum: 120)
            let response = try context.engine.request(
                "POST", "/containers/\(id)/stop", query: [("t", String(graceSeconds))],
                timeout: TimeInterval(graceSeconds + 15))
            return lifecycleResult(id: id, action: "stop", response: response, noOpStatus: 304)
        } catch let error as ArgError {
            return .errorText(error.description)
        } catch {
            return .errorText(describeEngineError(error))
        }
    }

    static let containerRestart = ToolSpec(
        name: "container_restart",
        summary: "Restart a container (stop, then start).",
        inputSchema: Schema.object(
            [
                "id": Schema.string("Container ID or name."),
                "timeout_seconds": Schema.integer(
                    "Grace period before Docker sends SIGKILL during the stop phase.",
                    minimum: 0, maximum: 120, defaultValue: 10),
            ], required: ["id"]),
        readOnly: false, destructive: false, group: .containersWrite
    ) { context, arguments in
        do {
            let id = try Args.requireString(arguments, "id")
            let graceSeconds = Args.boundedInt(arguments, "timeout_seconds", default: 10, minimum: 0, maximum: 120)
            let response = try context.engine.request(
                "POST", "/containers/\(id)/restart", query: [("t", String(graceSeconds))],
                timeout: TimeInterval(graceSeconds + 15))
            return lifecycleResult(id: id, action: "restart", response: response, noOpStatus: nil)
        } catch let error as ArgError {
            return .errorText(error.description)
        } catch {
            return .errorText(describeEngineError(error))
        }
    }

    static let containerRemove = ToolSpec(
        name: "container_remove",
        summary: "Remove a container. Refuses a running container unless force:true is also granted.",
        inputSchema: Schema.object(
            [
                "id": Schema.string("Container ID or name."),
                "force": Schema.boolean(
                    "Kill the container first if it is running. Requires the container_remove:force "
                        + "guard in addition to containers:write.", defaultValue: false),
                "remove_volumes": Schema.boolean(
                    "Also remove anonymous volumes associated with the container.", defaultValue: false),
            ], required: ["id"]),
        readOnly: false, destructive: true, group: .containersWrite,
        guards: [
            ToolGuard(
                key: "container_remove:force",
                description: "container_remove with force:true — kills a running container before "
                    + "removing it. A plain containers:write grant covers removing an already-stopped "
                    + "container; it does not cover force-killing a running one.",
                appliesTo: { JSONRead.bool($0, "force") == true }),
        ]
    ) { context, arguments in
        do {
            let id = try Args.requireString(arguments, "id")
            let force = Args.optionalBool(arguments, "force", default: false)
            let removeVolumes = Args.optionalBool(arguments, "remove_volumes", default: false)
            let response = try context.engine.request(
                "DELETE", "/containers/\(id)",
                query: [("force", force ? "1" : "0"), ("v", removeVolumes ? "1" : "0")], timeout: 30)
            return lifecycleResult(id: id, action: "remove", response: response, noOpStatus: nil)
        } catch let error as ArgError {
            return .errorText(error.description)
        } catch {
            return .errorText(describeEngineError(error))
        }
    }

    /// Common shape for start/stop/restart/remove: 2xx is success, an optional
    /// `noOpStatus` (304, "already in that state") is success-shaped too, and
    /// anything else is the engine's own error message verbatim.
    private static func lifecycleResult(id: String, action: String, response: EngineResponse, noOpStatus: Int?) -> ToolCallResult {
        if response.isSuccess {
            return .text(["id": id, "action": action, "status": "ok"])
        }
        if let noOpStatus, response.status == noOpStatus {
            return .text(["id": id, "action": action, "status": "no-op", "detail": "already in the requested state"])
        }
        return .errorText("container \(action) failed: \(response.engineMessage)")
    }

    // MARK: - container_exec

    static let containerExec = ToolSpec(
        name: "container_exec",
        summary: "Run a command inside a running container and return its stdout/stderr/exit code.",
        inputSchema: Schema.object(
            [
                "id": Schema.string("Container ID or name."),
                "cmd": Schema.stringArray("Command and arguments, e.g. [\"ls\", \"-la\", \"/\"]."),
                "workdir": Schema.string("Working directory inside the container."),
                "user": Schema.string("User to run as, e.g. \"root\" or \"1000:1000\"."),
                "env": Schema.stringMap("Extra environment variables for the command."),
                "timeout_seconds": Schema.integer(
                    "Deadline for the command to finish.", minimum: 1, maximum: 120, defaultValue: 30),
            ], required: ["id", "cmd"]),
        readOnly: false, destructive: false, group: .exec
    ) { context, arguments in
        do {
            let id = try Args.requireString(arguments, "id")
            let cmd = try Args.requireStringArray(arguments, "cmd")
            let workdir = Args.optionalString(arguments, "workdir")
            let user = Args.optionalString(arguments, "user")
            let env = Args.optionalStringMap(arguments, "env")
            let timeoutSeconds = Args.boundedInt(arguments, "timeout_seconds", default: 30, minimum: 1, maximum: 120)

            var createBody: [String: Any] = [
                "Cmd": cmd, "AttachStdout": true, "AttachStderr": true, "Tty": false,
            ]
            if let workdir { createBody["WorkingDir"] = workdir }
            if let user { createBody["User"] = user }
            if !env.isEmpty { createBody["Env"] = env.map { "\($0.key)=\($0.value)" } }

            let created = try context.engine.jsonObject("POST", "/containers/\(id)/exec", body: createBody, timeout: 15)
            guard let execID = JSONRead.string(created, "Id") else {
                return .errorText("exec create did not return an Id: \(JSONRead.compact(created))")
            }

            let startBody: [String: Any] = ["Detach": false, "Tty": false]
            let startResponse = try context.engine.request(
                "POST", "/exec/\(execID)/start",
                body: try JSONSerialization.data(withJSONObject: startBody),
                contentType: "application/json", timeout: TimeInterval(timeoutSeconds))
            guard startResponse.isSuccess else {
                return .errorText("exec start failed: \(startResponse.engineMessage)")
            }

            let demuxed = DockerStreamDemux.split(startResponse.body)
            let cap = 100_000
            let stdoutText = LogRedactor.redact(String(decoding: demuxed.stdout, as: UTF8.self))
            let stderrText = LogRedactor.redact(String(decoding: demuxed.stderr, as: UTF8.self))

            let inspected = try context.engine.jsonObject("GET", "/exec/\(execID)/json", timeout: 15)
            let exitCode = JSONRead.int(inspected, "ExitCode")

            return .text([
                "id": id, "exit_code": exitCode as Any,
                "stdout": Format.truncate(stdoutText, cap), "stderr": Format.truncate(stderrText, cap),
                "truncated": stdoutText.utf8.count > cap || stderrText.utf8.count > cap,
                "redaction": "best_effort_pattern_match — see docs/mcp.md; not a guarantee",
            ])
        } catch let error as ArgError {
            return .errorText(error.description)
        } catch {
            return .errorText(describeEngineError(error))
        }
    }

    // MARK: - compose

    static let composeUp = ToolSpec(
        name: "compose_up",
        summary: "`docker compose up -d` against a project directory, pointed at the Morbstack "
            + "engine. Note: this runs Dockerfiles and compose-file build/command directives, which "
            + "is arbitrary code execution inside the guest VM — granting `compose` is granting that, "
            + "not merely \"bring up some containers\".",
        inputSchema: Schema.object(
            [
                "project_directory": Schema.string(
                    "Absolute path to the directory containing docker-compose.yml. Must exist; must "
                        + "not contain a \"..\" segment."),
                "timeout_seconds": Schema.integer(
                    "Deadline for the whole command.", minimum: 10, maximum: 600, defaultValue: 180),
            ], required: ["project_directory"]),
        readOnly: false, destructive: false, group: .compose
    ) { context, arguments in
        do {
            let rawPath = try Args.requireString(arguments, "project_directory")
            let path = try validateProjectDirectory(rawPath)
            guard let compose = resolveComposeBinary() else { return .errorText(composeMissingMessage) }
            let timeout = TimeInterval(Args.boundedInt(arguments, "timeout_seconds", default: 180, minimum: 10, maximum: 600))
            let result = try Subprocess.run(
                compose, ["up", "-d"], environment: context.shellOutEnvironment(),
                currentDirectory: path, timeout: timeout)
            return shellCommandResult(action: "compose up", result: result)
        } catch let error as ArgError {
            return .errorText(error.description)
        } catch let error as PathValidationError {
            return .errorText(error.description)
        } catch {
            return .errorText("compose up failed: \(error)")
        }
    }

    static let composeDown = ToolSpec(
        name: "compose_down",
        summary: "`docker compose down` against a project directory, pointed at the Morbstack engine.",
        inputSchema: Schema.object(
            [
                "project_directory": Schema.string(
                    "Absolute path to the directory containing docker-compose.yml. Must exist; must "
                        + "not contain a \"..\" segment."),
                "remove_volumes": Schema.boolean(
                    "Also remove named volumes declared by the compose file (-v). Destroys their "
                        + "data irrecoverably; requires the compose_down:remove_volumes guard.",
                    defaultValue: false),
                "timeout_seconds": Schema.integer(
                    "Deadline for the whole command.", minimum: 10, maximum: 600, defaultValue: 180),
            ], required: ["project_directory"]),
        readOnly: false, destructive: true, group: .compose,
        guards: [
            ToolGuard(
                key: "compose_down:remove_volumes",
                description: "compose_down with remove_volumes:true — deletes the named volumes a "
                    + "compose project declared, which is where a database container's actual data "
                    + "usually lives. A plain compose grant tears down containers and networks, "
                    + "which are trivially recreated; it does not cover deleting data that is not.",
                appliesTo: { JSONRead.bool($0, "remove_volumes") == true }),
        ]
    ) { context, arguments in
        do {
            let rawPath = try Args.requireString(arguments, "project_directory")
            let path = try validateProjectDirectory(rawPath)
            guard let compose = resolveComposeBinary() else { return .errorText(composeMissingMessage) }
            let removeVolumes = Args.optionalBool(arguments, "remove_volumes", default: false)
            var args = ["down"]
            if removeVolumes { args.append("-v") }
            let timeout = TimeInterval(Args.boundedInt(arguments, "timeout_seconds", default: 180, minimum: 10, maximum: 600))
            let result = try Subprocess.run(
                compose, args, environment: context.shellOutEnvironment(), currentDirectory: path, timeout: timeout)
            return shellCommandResult(action: "compose down", result: result)
        } catch let error as ArgError {
            return .errorText(error.description)
        } catch let error as PathValidationError {
            return .errorText(error.description)
        } catch {
            return .errorText("compose down failed: \(error)")
        }
    }

    // MARK: - images

    static let imagePull = ToolSpec(
        name: "image_pull",
        summary: "Pull an image from a registry into the Morbstack engine.",
        inputSchema: Schema.object(
            [
                "reference": Schema.string(
                    "Image reference, e.g. `nginx:latest` or `ghcr.io/org/app@sha256:...`."),
            ], required: ["reference"]),
        readOnly: false, destructive: false, group: .imagesWrite
    ) { context, arguments in
        do {
            let reference = try Args.requireString(arguments, "reference")
            let (fromImage, tagOrDigest) = splitImageReference(reference)
            var query: [(String, String)] = [("fromImage", fromImage)]
            if let tagOrDigest { query.append(("tag", tagOrDigest)) }

            var buffer = NDJSONBuffer()
            var progress: [Any] = []
            var errorMessage: String?
            try context.engine.stream(
                "POST", "/images/create", query: query, timeout: 300,
                onChunk: { chunk, _ in
                    for object in buffer.feed(chunk) {
                        progress.append(object)
                        if let dictionary = object as? [String: Any], let error = dictionary["error"] as? String {
                            errorMessage = error
                        }
                    }
                    return true
                })
            if let errorMessage {
                return .errorText("image pull failed: \(errorMessage)")
            }
            return .text(["reference": reference, "status": "ok", "progress_tail": Array(progress.suffix(5))])
        } catch let error as ArgError {
            return .errorText(error.description)
        } catch {
            return .errorText(describeEngineError(error))
        }
    }

    static let imageRemove = ToolSpec(
        name: "image_remove",
        summary: "Remove an image from the Morbstack engine. Not separately guarded from "
            + "force-remove the way container_remove is: images are reproducible by re-pulling or "
            + "rebuilding, so images:write covers force here.",
        inputSchema: Schema.object(
            [
                "id": Schema.string("Image ID, or a name:tag reference."),
                "force": Schema.boolean("Remove even if referenced by stopped containers.", defaultValue: false),
            ], required: ["id"]),
        readOnly: false, destructive: true, group: .imagesWrite
    ) { context, arguments in
        do {
            let id = try Args.requireString(arguments, "id")
            let force = Args.optionalBool(arguments, "force", default: false)
            let response = try context.engine.request(
                "DELETE", "/images/\(id)", query: [("force", force ? "1" : "0")], timeout: 30)
            guard response.isSuccess else {
                return .errorText("image remove failed: \(response.engineMessage)")
            }
            let removed = (try? JSONSerialization.jsonObject(with: response.body)) ?? []
            return .text(["id": id, "status": "ok", "detail": removed])
        } catch let error as ArgError {
            return .errorText(error.description)
        } catch {
            return .errorText(describeEngineError(error))
        }
    }

    static let imageBuild = ToolSpec(
        name: "image_build",
        summary: "`docker build` a directory, pointed at the Morbstack engine. Note: building an "
            + "image runs every instruction in the Dockerfile, which is arbitrary code execution "
            + "inside the guest VM — granting images:write is granting that, not merely \"the "
            + "ability to build images\".",
        inputSchema: Schema.object(
            [
                "context_directory": Schema.string(
                    "Absolute path to the build context. Must exist; must not contain a \"..\" segment."),
                "dockerfile": Schema.string("Path to the Dockerfile, relative to context_directory.", defaultValue: "Dockerfile"),
                "tag": Schema.string("Tag to apply to the built image, e.g. \"myapp:dev\"."),
                "build_args": Schema.stringMap("Build arguments (--build-arg KEY=VALUE)."),
                "no_cache": Schema.boolean("Disable the build cache.", defaultValue: false),
                "timeout_seconds": Schema.integer(
                    "Deadline for the whole build.", minimum: 10, maximum: 900, defaultValue: 300),
            ], required: ["context_directory"]),
        readOnly: false, destructive: false, group: .imagesWrite
    ) { context, arguments in
        do {
            let rawPath = try Args.requireString(arguments, "context_directory")
            let path = try validateProjectDirectory(rawPath)
            guard let docker = Subprocess.which("docker") else {
                return .errorText(
                    "the `docker` CLI is not on PATH. It ships with the fetched assets — see "
                        + "README.md \"Running\" — or install Docker's CLI separately.")
            }
            var args = ["build"]
            if let dockerfile = Args.optionalString(arguments, "dockerfile") { args += ["-f", dockerfile] }
            if let tag = Args.optionalString(arguments, "tag") { args += ["-t", tag] }
            for (key, value) in Args.optionalStringMap(arguments, "build_args") {
                args += ["--build-arg", "\(key)=\(value)"]
            }
            if Args.optionalBool(arguments, "no_cache", default: false) { args.append("--no-cache") }
            args.append(path)

            let timeout = TimeInterval(Args.boundedInt(arguments, "timeout_seconds", default: 300, minimum: 10, maximum: 900))
            let result = try Subprocess.run(
                docker, args, environment: context.shellOutEnvironment(), currentDirectory: path, timeout: timeout)
            return shellCommandResult(action: "image build", result: result)
        } catch let error as ArgError {
            return .errorText(error.description)
        } catch let error as PathValidationError {
            return .errorText(error.description)
        } catch {
            return .errorText("image build failed: \(error)")
        }
    }

    // MARK: - prune

    static let allowedPruneTargets: Set<String> = ["containers", "images", "volumes", "networks", "build_cache"]

    static let prune = ToolSpec(
        name: "prune",
        summary: "Reclaim disk space by pruning one or more resource kinds. Never defaults to "
            + "\"everything\" — targets must be named explicitly.",
        inputSchema: Schema.object(
            [
                "targets": Schema.stringArray(
                    "Which resource kinds to prune.",
                    enumValues: Array(allowedPruneTargets).sorted()),
            ], required: ["targets"]),
        readOnly: false, destructive: true, group: .prune,
        guards: [
            ToolGuard(
                key: "prune:volumes",
                description: "prune with \"volumes\" in targets — deletes every volume not "
                    + "currently attached to a container. Volume data is not reproducible the way a "
                    + "pulled image or a stopped container is, so a plain prune grant does not cover it.",
                appliesTo: { JSONRead.strings($0, "targets").contains("volumes") }),
        ]
    ) { context, arguments in
        do {
            let targets = try Args.requireStringArray(arguments, "targets")
            let unknown = Set(targets).subtracting(allowedPruneTargets)
            guard unknown.isEmpty else {
                return .errorText(
                    "unknown prune target(s) \(unknown.sorted().joined(separator: ", ")); "
                        + "expected one or more of \(allowedPruneTargets.sorted().joined(separator: ", "))")
            }
            var results: [String: Any] = [:]
            for target in targets {
                do {
                    switch target {
                    case "containers":
                        results[target] = try context.engine.jsonObject("POST", "/containers/prune", timeout: 60)
                    case "images":
                        results[target] = try context.engine.jsonObject("POST", "/images/prune", timeout: 120)
                    case "volumes":
                        results[target] = try context.engine.jsonObject("POST", "/volumes/prune", timeout: 60)
                    case "networks":
                        results[target] = try context.engine.jsonObject("POST", "/networks/prune", timeout: 60)
                    case "build_cache":
                        results[target] = try context.engine.jsonObject("POST", "/build/prune", timeout: 120)
                    default:
                        break
                    }
                } catch {
                    results[target] = ["error": describeEngineError(error)]
                }
            }
            return .text(results)
        } catch let error as ArgError {
            return .errorText(error.description)
        } catch {
            return .errorText("could not validate prune arguments: \(error.localizedDescription)")
        }
    }

    // MARK: - engine lifecycle

    static let engineStart = ToolSpec(
        name: "engine_start",
        summary: "Boot the Morbstack VM via morbstackd's control socket.",
        inputSchema: Schema.object([:]),
        readOnly: false, destructive: false, group: .engine
    ) { _, _ in daemonCommandResult(cmd: "start") }

    static let engineStop = ToolSpec(
        name: "engine_stop",
        summary: "Shut the Morbstack VM down via morbstackd's control socket.",
        inputSchema: Schema.object(["force": Schema.boolean("Skip asking the guest to shut down cleanly first.", defaultValue: false)]),
        readOnly: false, destructive: false, group: .engine
    ) { _, arguments in
        let force = Args.optionalBool(arguments, "force", default: false)
        return daemonCommandResult(cmd: "stop", args: force ? ["force": "true"] : nil)
    }

    /// Round-trips a command to `morbstackd` over the control socket and
    /// renders its `DaemonResponse` as the tool result.
    private static func daemonCommandResult(cmd: String, args: [String: String]? = nil) -> ToolCallResult {
        do {
            let response = try UnixSocketClient.roundTrip(
                path: MorbPaths.controlSocket.path, request: DaemonRequest(cmd: cmd, args: args), timeout: 90)
            let data = try IPCCodec.makeEncoder().encode(response)
            let object = (try? JSONSerialization.jsonObject(with: data)) ?? NSNull()
            return .text(object, isError: !response.ok)
        } catch {
            return .errorText("morbstackd \(cmd) failed: \((error as? MorbError)?.description ?? "\(error)")")
        }
    }
}
