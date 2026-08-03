// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// `morb migrate config` — reads `~/.docker/config.json` and the docker CLI's context
// store, and reports what it finds. Strictly read-only: this file has no write path at
// all, on purpose.
//
// Registering the `morbstack` docker context is a separate, already-existing command
// (`morb context create`/`morb context use`, mac/Sources/morb/main.swift, backed by
// MorbstackKit's `MorbDockerContext`) that does its own confirmation dance and its own
// careful preserve-every-other-key write. This command never duplicates that logic or
// calls it directly — it only ever tells the user which of those commands to run and
// why. Two independent code paths that can both decide to rewrite
// `~/.docker/config.json` is exactly the kind of thing that ends up corrupting it one
// day; one path that everything else points at is safer than two paths kept carefully
// in sync by hand.

import Foundation
import MorbFeatures

enum ConfigCommand {

    static func run(arguments: [String], json: Bool) -> Int32 {
        let contextsDir = DockerCLIConfigReader.dockerConfigDirectory()
        let contexts = DockerContextsStore.readAll(dockerConfigDirectory: contextsDir)
        let config = DockerCLIConfigReader.read()

        if json {
            emit(json: true, data: [
                "docker_config_directory": contextsDir.path,
                "config_present": config != nil,
                "current_context": config?.currentContext ?? "default",
                "creds_store": config?.credsStore ?? NSNull(),
                "creds_store_is_desktop_helper": config?.credsStoreIsDesktopHelper ?? false,
                "cred_helper_registries": config?.credHelperRegistries ?? [],
                "registries_with_auth": config?.registriesWithAuth ?? [],
                "proxy_keys": config?.proxies ?? [],
                "cli_plugins_extra_dirs": config?.cliPluginsExtraDirs ?? [],
                "contexts": contexts.map { ["name": $0.name, "host": $0.host ?? NSNull()] as [String: Any] },
            ]) {}
            return 0
        }

        out("Docker config directory: \(contextsDir.path)")
        guard let config else {
            out("  (no config.json there, or it is empty/unparseable — nothing to report)")
            printRecommendation()
            return 0
        }

        out("  current context: \(config.currentContext)")
        out("")
        out("Registered contexts:")
        if contexts.isEmpty {
            out("  (none)")
        } else {
            var table = TextTable(headers: ["NAME", "HOST"])
            for context in contexts { table.add([context.name, context.host ?? "?"]) }
            out(table.render())
        }

        out("")
        out("Registries with stored credentials (never the credentials themselves):")
        out(config.registriesWithAuth.isEmpty ? "  (none)" : config.registriesWithAuth.map { "  \($0)" }.joined(separator: "\n"))
        out("To re-authenticate against these after switching to Morbstack's engine, run")
        out("`docker login <registry>` again once the `morbstack` context is current — credentials")
        out("live with the docker CLI config, not with any particular engine, so Morbstack cannot")
        out("and does not copy them.")

        if !config.credHelperRegistries.isEmpty {
            out("")
            out("credHelpers configured for: \(config.credHelperRegistries.joined(separator: ", "))")
        }
        if !config.proxies.isEmpty {
            out("")
            out("proxies configured for: \(config.proxies.joined(separator: ", "))")
        }
        if !config.cliPluginsExtraDirs.isEmpty {
            out("")
            out("cliPluginsExtraDirs: \(config.cliPluginsExtraDirs.joined(separator: ", "))")
        }

        if config.credsStoreIsDesktopHelper {
            out("")
            out("[!!] credsStore is \"desktop\" — this is the documented hang in README.md's")
            out("     Troubleshooting section. Once Docker Desktop is no longer the thing running")
            out("     in the background, every `docker` command that needs a registry credential")
            out("     will hang forever waiting on `docker-credential-desktop`, which only answers")
            out("     while Desktop itself is running. Fix: remove the \"credsStore\" line from")
            out("     \(contextsDir.appendingPathComponent("config.json").path), or point $DOCKER_CONFIG")
            out("     at a directory whose config.json omits it. Morbstack does not edit this file")
            out("     for you — see the note above about why.")
        }

        printRecommendation()
        return 0
    }

    private static func printRecommendation() {
        out("")
        out("To point the docker CLI at Morbstack:")
        out("  morb context create   — registers a \"morbstack\" context (asks first)")
        out("  morb context use      — makes it the default (asks first, never stomps another")
        out("                          explicit context without --force)")
        out("`morb migrate` does not run these for you; see docs/migrate.md for why.")
    }
}
