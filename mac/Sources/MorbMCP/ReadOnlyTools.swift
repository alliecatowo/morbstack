// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The read-only tool surface: everything an agent can call with no grant at
// all, because none of it can change anything. This is what makes `morb mcp
// serve` useful the moment it starts, with an empty `mcp.toml` and no `--allow`
// flags — the zero-config case the rest of the permission model is built
// around protecting rather than gatekeeping.

import Foundation
import MorbFeatures
import MorbstackKit

enum ReadOnlyTools {

    static let all: [ToolSpec] = [
        containersList, containerInspect, containerLogs, imagesList,
        volumesList, networksList, diskUsage, engineStatus, eventsSubscribe,
    ]

    // MARK: - containers_list

    static let containersList = ToolSpec(
        name: "containers_list",
        summary: "List containers on the Morbstack engine.",
        inputSchema: Schema.object([
            "all": Schema.boolean("Include stopped containers, not just running ones.", defaultValue: true),
        ]),
        readOnly: true, destructive: false, group: nil
    ) { context, arguments in
        let includeStopped = Args.optionalBool(arguments, "all", default: true)
        do {
            let containers = try context.engine.jsonArray(
                "GET", "/containers/json", query: [("all", includeStopped ? "1" : "0")])
            return .text(containers)
        } catch {
            return .errorText(describeEngineError(error))
        }
    }

    // MARK: - container_inspect

    static let containerInspect = ToolSpec(
        name: "container_inspect",
        summary: "Full inspect document for one container: config, state, mounts, networks.",
        inputSchema: Schema.object(
            ["id": Schema.string("Container ID or name.")], required: ["id"]),
        readOnly: true, destructive: false, group: nil
    ) { context, arguments in
        do {
            let id = try Args.requireString(arguments, "id")
            let details = try context.engine.jsonObject("GET", "/containers/\(id)/json")
            return .text(details)
        } catch let error as ArgError {
            return .errorText(error.description)
        } catch {
            return .errorText(describeEngineError(error))
        }
    }

    // MARK: - container_logs

    static let containerLogs = ToolSpec(
        name: "container_logs",
        summary: "Tail a container's stdout/stderr, demultiplexed.",
        inputSchema: Schema.object(
            [
                "id": Schema.string("Container ID or name."),
                "tail": Schema.integer("Number of lines from the end to return.", minimum: 1, maximum: 10_000, defaultValue: 200),
                "since": Schema.string("Only return logs after this Unix timestamp (seconds)."),
                "timestamps": Schema.boolean("Prefix each line with its RFC3339 timestamp.", defaultValue: false),
            ], required: ["id"]),
        readOnly: true, destructive: false, group: nil
    ) { context, arguments in
        do {
            let id = try Args.requireString(arguments, "id")
            let tail = Args.boundedInt(arguments, "tail", default: 200, minimum: 1, maximum: 10_000)
            let timestamps = Args.optionalBool(arguments, "timestamps", default: false)

            // The container's TTY setting decides whether Docker's stdcopy
            // framing is present on the log stream; guessing wrong prints raw
            // frame headers as if they were log text, so ask rather than guess.
            let inspected = try context.engine.jsonObject("GET", "/containers/\(id)/json")
            let hasTTY = JSONRead.bool(JSONRead.dictionary(inspected, "Config"), "Tty") ?? false

            var query: [(String, String)] = [
                ("stdout", "1"), ("stderr", "1"), ("tail", String(tail)),
                ("timestamps", timestamps ? "1" : "0"),
            ]
            if let since = Args.optionalString(arguments, "since") { query.append(("since", since)) }

            let response = try context.engine.request("GET", "/containers/\(id)/logs", query: query, timeout: 30)
            guard response.isSuccess else {
                return .errorText("container logs failed: \(response.engineMessage)")
            }

            let cap = 200_000
            if hasTTY {
                let text = String(decoding: response.body, as: UTF8.self)
                return .text([
                    "stdout": Format.truncate(text, cap), "stderr": "",
                    "truncated": text.utf8.count > cap, "tty": true,
                ])
            }
            let demuxed = DockerStreamDemux.split(response.body)
            let stdoutText = String(decoding: demuxed.stdout, as: UTF8.self)
            let stderrText = String(decoding: demuxed.stderr, as: UTF8.self)
            return .text([
                "stdout": Format.truncate(stdoutText, cap),
                "stderr": Format.truncate(stderrText, cap),
                "truncated": stdoutText.utf8.count > cap || stderrText.utf8.count > cap,
                "tty": false,
            ])
        } catch let error as ArgError {
            return .errorText(error.description)
        } catch {
            return .errorText(describeEngineError(error))
        }
    }

    // MARK: - images_list

    static let imagesList = ToolSpec(
        name: "images_list",
        summary: "List images cached on the Morbstack engine.",
        inputSchema: Schema.object(["all": Schema.boolean("Include intermediate build layers.", defaultValue: false)]),
        readOnly: true, destructive: false, group: nil
    ) { context, arguments in
        let includeAll = Args.optionalBool(arguments, "all", default: false)
        do {
            let images = try context.engine.jsonArray("GET", "/images/json", query: [("all", includeAll ? "1" : "0")])
            return .text(images)
        } catch {
            return .errorText(describeEngineError(error))
        }
    }

    // MARK: - volumes_list

    static let volumesList = ToolSpec(
        name: "volumes_list",
        summary: "List named volumes on the Morbstack engine.",
        inputSchema: Schema.object([:]),
        readOnly: true, destructive: false, group: nil
    ) { context, _ in
        do {
            let volumes = try context.engine.jsonObject("GET", "/volumes")
            return .text(volumes)
        } catch {
            return .errorText(describeEngineError(error))
        }
    }

    // MARK: - networks_list

    static let networksList = ToolSpec(
        name: "networks_list",
        summary: "List Docker networks on the Morbstack engine.",
        inputSchema: Schema.object([:]),
        readOnly: true, destructive: false, group: nil
    ) { context, _ in
        do {
            let networks = try context.engine.jsonArray("GET", "/networks")
            return .text(networks)
        } catch {
            return .errorText(describeEngineError(error))
        }
    }

    // MARK: - disk_usage

    static let diskUsage = ToolSpec(
        name: "disk_usage",
        summary: "Disk space used by images, containers, volumes and the build cache.",
        inputSchema: Schema.object([:]),
        readOnly: true, destructive: false, group: nil
    ) { context, _ in
        do {
            let usage = try context.engine.jsonObject("GET", "/system/df")
            return .text(usage)
        } catch {
            return .errorText(describeEngineError(error))
        }
    }

    // MARK: - engine_status

    static let engineStatus = ToolSpec(
        name: "engine_status",
        summary: "VM and daemon state from morbstackd, plus the Docker Engine API's own version and reachability.",
        inputSchema: Schema.object([:]),
        readOnly: true, destructive: false, group: nil
    ) { context, _ in
        var result: [String: Any] = [:]

        do {
            let response = try UnixSocketClient.roundTrip(
                path: MorbPaths.controlSocket.path, request: DaemonRequest(cmd: "status"), timeout: 10)
            let data = try IPCCodec.makeEncoder().encode(response)
            result["vm"] = (try? JSONSerialization.jsonObject(with: data)) ?? NSNull()
        } catch {
            result["vm"] = ["reachable": false, "error": "\((error as? MorbError)?.description ?? "\(error)")"]
        }

        let reachable = context.engine.ping(timeout: 5)
        var engineInfo: [String: Any] = ["reachable": reachable, "socket": context.engine.socketPath]
        if reachable, let version = context.engine.version(timeout: 5) {
            engineInfo["version"] = version
        }
        result["engine"] = engineInfo

        return .text(result)
    }

    // MARK: - events_subscribe

    static let eventsSubscribe = ToolSpec(
        name: "events_subscribe",
        summary: "Watch the Docker event stream for a bounded window and return what happened.",
        inputSchema: Schema.object([
            "duration_seconds": Schema.integer(
                "How long to watch, in seconds. Capped at 60 so a tool call always terminates.",
                minimum: 1, maximum: 60, defaultValue: 5),
            "max_events": Schema.integer(
                "Stop early once this many events have arrived.", minimum: 1, maximum: 500, defaultValue: 50),
        ]),
        readOnly: true, destructive: false, group: nil
    ) { context, arguments in
        let duration = Args.boundedInt(arguments, "duration_seconds", default: 5, minimum: 1, maximum: 60)
        let maxEvents = Args.boundedInt(arguments, "max_events", default: 50, minimum: 1, maximum: 500)

        var events: [Any] = []
        var buffer = Data()
        let start = Date()
        var stoppedReason = "idle_timeout"

        do {
            try context.engine.stream(
                "GET", "/events", timeout: TimeInterval(duration),
                onChunk: { chunk, _ in
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer[buffer.startIndex..<newline]
                        buffer.removeSubrange(buffer.startIndex...newline)
                        if !lineData.isEmpty, let object = try? JSONSerialization.jsonObject(with: Data(lineData)) {
                            events.append(object)
                        }
                    }
                    if events.count >= maxEvents {
                        stoppedReason = "max_events"
                        return false
                    }
                    if Date().timeIntervalSince(start) >= Double(duration) {
                        stoppedReason = "duration"
                        return false
                    }
                    return true
                })
        } catch let error as EngineError {
            if case .timedOut = error {
                // `/events` blocks forever when nothing has happened; the timeout
                // firing with zero (or a few) events collected is the expected way
                // an idle observation window ends, not a failure.
                stoppedReason = "idle_timeout"
            } else {
                return .errorText("docker events: \(error.description)")
            }
        } catch {
            return .errorText("docker events: \(error)")
        }

        return .text([
            "events": Array(events.prefix(maxEvents)),
            "count": events.count,
            "duration_seconds": duration,
            "max_events": maxEvents,
            "stopped_reason": stoppedReason,
        ])
    }
}

/// A consistent, agent-readable rendering of whatever this call's error was.
func describeEngineError(_ error: Error) -> String {
    if let engineError = error as? EngineError { return engineError.description }
    if let morbError = error as? MorbError { return morbError.description }
    return "\(error)"
}
