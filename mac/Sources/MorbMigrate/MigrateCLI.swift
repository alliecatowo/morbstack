// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The small command router for `morb migrate`.  The migration operations live in
// their own files so that each has one narrow responsibility; this file deliberately
// only decides which one receives a validated argument list.

import Foundation

enum MigrateCLI {

    static func run(_ arguments: [String], json: Bool) -> Int32 {
        guard let command = arguments.first else {
            // Detection is the documented, read-only default.  It gives a person an
            // answer before any command that could create data is considered.
            return DetectCommand.run(json: json)
        }

        let commandArguments = Array(arguments.dropFirst())
        switch command {
        case "help", "--help", "-h":
            guard commandArguments.isEmpty else {
                return usageError("help does not take additional arguments")
            }
            printUsage()
            return 0

        case "detect":
            guard commandArguments.isEmpty else {
                return usageError("detect does not take arguments")
            }
            return DetectCommand.run(json: json)

        case "config":
            guard commandArguments.isEmpty else {
                return usageError("config does not take arguments")
            }
            return ConfigCommand.run(arguments: [], json: json)

        case "images":
            guard let error = validate(
                commandArguments,
                flags: ["all", "dry-run", "yes"],
                options: ["filter", "from"]
            ) else {
                return ImagesCommand.run(arguments: commandArguments, json: json)
            }
            return usageError(error)

        case "volumes":
            guard let error = validate(
                commandArguments,
                flags: ["dry-run", "overwrite", "yes"],
                options: ["filter", "from"]
            ) else {
                return VolumesCommand.run(arguments: commandArguments, json: json)
            }
            return usageError(error)

        case "verify":
            guard let error = validate(
                commandArguments,
                flags: ["yes"],
                options: ["from", "images", "report", "volumes"]
            ) else {
                return VerifyCommand.run(arguments: commandArguments, json: json)
            }
            return usageError(error)

        case "run":
            return unavailableRun()

        default:
            return usageError("unknown subcommand `\(command)`")
        }
    }

    /// Validates only this module's intentionally small flag vocabulary before the
    /// individual commands parse it.  `parseArgs` is permissive for its callers, but
    /// accepting a misspelled write flag here would be dangerous: for example,
    /// `--from` without a value could otherwise fall back to auto-selection.
    private static func validate(
        _ arguments: [String], flags: Set<String>, options: Set<String>
    ) -> String? {
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            guard token.hasPrefix("--") else {
                return "unexpected argument `\(token)`"
            }

            let name = String(token.dropFirst(2))
            guard !name.isEmpty else { return "invalid option `--`" }
            if token.contains("=") {
                return "`\(token)` is not supported; pass option values as `--name value`"
            }
            if flags.contains(name) {
                index += 1
                continue
            }
            if options.contains(name) {
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    return "`--\(name)` requires a value"
                }
                index += 2
                continue
            }
            return "unknown option `\(token)`"
        }
        return nil
    }

    /// `ImagesCommand` and `VolumesCommand` do not expose the copied item lists;
    /// `VerifyCommand` therefore cannot be limited to the objects a combined command
    /// just transferred, and `MigrateReport` cannot be written accurately.  Calling
    /// them in sequence would look like the documented all-in-one migration while
    /// omitting its essential report and verification guarantees.  Keep that gap
    /// visible until those primitives have a shared result model.
    private static func unavailableRun() -> Int32 {
        errOut("`run` is not available yet: the existing image and volume commands do not expose the results needed to write an accurate migration report and verify exactly what was copied")
        errOut("run `morb migrate images`, `morb migrate volumes`, then `morb migrate verify` explicitly")
        return 2
    }

    private static func usageError(_ message: String) -> Int32 {
        errOut(message)
        FileHandle.standardError.write(Data("\n".utf8))
        printUsage(to: .standardError)
        return 2
    }

    private static func printUsage(to output: FileHandle = .standardOutput) {
        let usage = """
        Usage: morb migrate <subcommand> [options]

        Subcommands:
          detect                 Survey local container runtimes (the default).
          config                 Inspect Docker CLI configuration, read-only.
          images [options]       Copy images into Morbstack.
          volumes [options]      Copy named volumes into Morbstack.
          verify [options]       Compare images and volumes between engines.

        Image options:
          --from <runtime|socket>  Docker Desktop, Colima, OrbStack, or a socket path.
          --filter <text>          Copy matching tagged images only.
          --all                    Include dangling images.
          --dry-run                Print the copy plan without changing anything.
          --yes                    Skip the copy confirmation.

        Volume options:
          --from <runtime|socket>  Docker Desktop, Colima, OrbStack, or a socket path.
          --filter <text>          Copy matching named volumes only.
          --overwrite              Allow merging into a non-empty destination volume.
          --dry-run                Print the copy plan without changing anything.
          --yes                    Skip confirmations, including helper-image pulls.

        Verify options:
          --from <runtime|socket>  Source runtime or socket path.
          --images <ref,...>       Image references to compare.
          --volumes <name,...>     Named volumes to compare.
          --report <path>          Read copied items from a migration report.
          --yes                    Allow required helper-image pulls.

        Pass --json before the subcommand for machine-readable output.
        """
        output.write(Data((usage + "\n").utf8))
    }
}
