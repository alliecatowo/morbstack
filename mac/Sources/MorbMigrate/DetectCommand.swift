// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// `morb migrate detect` (and the default when `morb migrate` is run with no
// subcommand at all) — a read-only survey of every other container runtime on this
// Mac, Morbstack's own state, and the docker CLI's configuration. Detection never
// fails hard: a runtime that is not installed, or installed but not running, is a
// completely normal answer, not an error.

import Foundation
import MorbFeatures

enum DetectCommand {

    static func run(json: Bool) -> Int32 {
        let dockerDesktop = RuntimeDetect.detectDockerDesktop()
        let colima = RuntimeDetect.detectColima()
        let orbstack = RuntimeDetect.detectOrbStack()
        let morbstack = RuntimeDetect.detectMorbstack()
        let config = DockerCLIConfigReader.read()
        let contexts = DockerContextsStore.readAll(dockerConfigDirectory: DockerCLIConfigReader.dockerConfigDirectory())

        let runtimes: [[String: Any]] = [dockerDesktop, colima, orbstack, morbstack].map(runtimeJSON)
        let contextPayloads: [[String: Any]] = contexts.map { context in
            ["name": context.name, "host": context.host ?? NSNull()]
        }
        let dockerConfig: [String: Any] = [
            "current_context": config?.currentContext ?? "default",
            "creds_store": config?.credsStore ?? NSNull(),
            "creds_store_is_desktop_helper": config?.credsStoreIsDesktopHelper ?? false,
            "contexts": contextPayloads,
        ]
        let payload: [String: Any] = [
            "runtimes": runtimes,
            "docker_config": dockerConfig,
        ]

        emit(json: json, data: payload) {
            printHuman(dockerDesktop: dockerDesktop, colima: colima, orbstack: orbstack, morbstack: morbstack,
                       config: config, contexts: contexts)
        }
        return 0
    }

    private static func runtimeJSON(_ r: RuntimeReport) -> [String: Any] {
        [
            "name": r.name,
            "installed": r.installed,
            "install_path": r.installPath ?? NSNull(),
            "socket_candidates": r.socketCandidates,
            "socket_path": r.socketPath ?? NSNull(),
            "running": r.running,
            "engine_version": r.engineVersion ?? NSNull(),
            "api_version": r.apiVersion ?? NSNull(),
            "images": r.images ?? NSNull(),
            "containers": r.containers ?? NSNull(),
            "volumes": r.volumes ?? NSNull(),
            "image_bytes": r.imageBytes ?? NSNull(),
            "notes": r.notes,
        ]
    }

    private static func printHuman(
        dockerDesktop: RuntimeReport, colima: RuntimeReport, orbstack: RuntimeReport, morbstack: RuntimeReport,
        config: DockerCLIConfig?, contexts: [DockerContextEntry]
    ) {
        var table = TextTable(headers: ["RUNTIME", "INSTALLED", "RUNNING", "VERSION", "IMAGES", "CONTAINERS", "VOLUMES", "IMAGE SIZE"], rightAligned: [4, 5, 6, 7])
        for report in [dockerDesktop, colima, orbstack, morbstack] {
            table.add([
                report.name,
                report.installed ? "yes" : "no",
                report.running ? "yes" : "no",
                report.engineVersion ?? "-",
                report.images.map(String.init) ?? "-",
                report.containers.map(String.init) ?? "-",
                report.volumes.map(String.init) ?? "-",
                report.imageBytes.map(Format.bytes) ?? "-",
            ])
        }
        out("Container runtimes on this Mac:")
        out(table.render())
        for report in [dockerDesktop, colima, orbstack, morbstack] where !report.notes.isEmpty {
            for note in report.notes { out("  \(report.name): \(note)") }
        }

        out("")
        out("Docker CLI configuration (\(DockerCLIConfigReader.dockerConfigDirectory().path)):")
        if let config {
            out("  current context: \(config.currentContext)")
            if config.credsStoreIsDesktopHelper {
                out("  [!!] credsStore is \"desktop\" — this hangs every docker command needing a")
                out("       registry credential once Desktop stops running. Run `morb migrate config`")
                out("       for the fix, or see README.md's Troubleshooting section.")
            }
        } else {
            out("  no config.json found (or it is empty) — nothing configured yet")
        }
        if !contexts.isEmpty {
            out("  registered contexts: " + contexts.map(\.name).joined(separator: ", "))
        }

        out("")
        out("Suggested next step:")
        let running = [dockerDesktop, colima, orbstack].filter(\.running)
        if running.isEmpty {
            out("  No other running runtime was found, so there is nothing to migrate from yet.")
            out("  Start Docker Desktop (or Colima, or OrbStack) and run `morb migrate detect` again,")
            out("  or inspect an explicit source with `morb migrate plan --from <runtime-or-socket>`.")
        } else if running.count > 1 {
            out("  More than one other runtime is running (\(running.map(\.name).joined(separator: ", "))).")
            out("  Pick one explicitly with `morb migrate plan --from <runtime>`; nothing runs automatically.")
        } else if let only = running.first {
            let source = sourceToken(for: only)
            out("  \(only.name) has \(only.images.map(String.init) ?? "?") image(s) and \(only.volumes.map(String.init) ?? "?") volume(s).")
            out("  Review the image plan with `morb migrate plan --from \(source)`, then run")
            out("  `morb migrate run --from \(source) --image <reference>` for each selected image")
            out("  (or the explicitly broad `--all-images`). This transaction verifies its selected")
            out("  images and writes a report. Volumes remain a separate, explicitly reviewed workflow.")
        }
    }

    private static func sourceToken(for report: RuntimeReport) -> String {
        switch report.name {
        case "Docker Desktop": return "docker-desktop"
        case "OrbStack": return "orbstack"
        default: return report.name.lowercased()
        }
    }
}
