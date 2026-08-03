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

        emit(json: json, data: [
            "runtimes": [dockerDesktop, colima, orbstack, morbstack].map(runtimeJSON),
            "docker_config": [
                "current_context": config?.currentContext ?? "default",
                "creds_store": config?.credsStore ?? NSNull(),
                "creds_store_is_desktop_helper": config?.credsStoreIsDesktopHelper ?? false,
                "contexts": contexts.map { ["name": $0.name, "host": $0.host ?? NSNull()] },
            ],
        ]) {
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
        out("What `morb migrate run` would do:")
        let running = [dockerDesktop, colima, orbstack].filter(\.running)
        if running.isEmpty {
            out("  No other running runtime was found, so there is nothing to migrate from yet.")
            out("  Start Docker Desktop (or Colima, or OrbStack) and run `morb migrate detect` again,")
            out("  or point directly at a socket with `morb migrate run --from <path>`.")
        } else if running.count > 1 {
            out("  More than one other runtime is running (\(running.map(\.name).joined(separator: ", "))).")
            out("  `morb migrate run --from <name>` picks one; nothing runs automatically when it's ambiguous.")
        } else if let only = running.first {
            out("  Copy \(only.images.map(String.init) ?? "?") image(s) and \(only.volumes.map(String.init) ?? "?")")
            out("  volume(s) from \(only.name) into Morbstack, verify each one, and offer (never perform")
            out("  automatically) a switch of the default docker context afterward. Nothing here has")
            out("  changed anything yet — `morb migrate run --dry-run` prints the exact plan without")
            out("  copying anything; `morb migrate run` does the real thing, and still asks before every")
            out("  step that writes something.")
        }
    }
}
