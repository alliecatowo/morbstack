// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Command surface for user-directed local Docker archives. This target has no
// AppKit/SwiftUI dependency: the CLI is the truthful public boundary until a standard
// macOS save-panel flow is wired through the native app's existing selection context.

import Foundation
import MorbFeatures

enum ExportCLI {

    static func run(_ arguments: [String], json: Bool) -> Int32 {
        guard let subcommand = arguments.first else {
            printUsage(to: json ? .standardError : .standardOutput)
            return json ? 2 : 0
        }
        switch subcommand {
        case "help", "--help", "-h":
            guard arguments.count == 1 else {
                return usageError("help does not take additional arguments", json: json)
            }
            printUsage()
            return 0
        case "image":
            return exportImage(arguments: Array(arguments.dropFirst()), json: json)
        case "volume":
            return exportVolume(arguments: Array(arguments.dropFirst()), json: json)
        case "--all":
            // Unlike `image`/`volume`, `--all` is a flag on `morb export` itself, not
            // a subcommand name — it needs the full, undropped argument list so it can
            // parse its own `--output`/`--replace` the same way the other two do.
            return exportAll(arguments: arguments, json: json)
        default:
            return usageError("unknown export subcommand `\(subcommand)`", json: json)
        }
    }

    /// `morb export --all --output <directory>` — every currently local tagged image,
    /// written as one archive per image into a directory a stock `docker load`
    /// restores. This is the bulk sibling of `image`; it reuses
    /// `ImageArchiveExporter.exportAll`, not a second export implementation, so it
    /// keeps that function's per-file atomic publish and no-clobber guarantees.
    private static func exportAll(arguments: [String], json: Bool) -> Int32 {
        let request: AllRequest
        do {
            request = try AllRequest(arguments)
        } catch {
            return usageError(describe(error), json: json)
        }

        if !json {
            out("Exporting every local tagged image (no registry or credentials access)")
            out("  output       \(terminalSafe(request.output.path))")
            out("  replace      \(request.replaceExisting ? "yes, per file, after a complete download" : "no")")
            out("  engine       GET /images/json, then one GET /images/get per image")
        }

        do {
            let result = try ImageArchiveExporter.exportAll(
                to: request.output, replaceExisting: request.replaceExisting,
                onItem: { reference in if !json { out("  exporting \(terminalSafe(reference))…") } })
            let failed = result.failed
            if json {
                emitJSON([
                    "ok": failed.isEmpty,
                    "directory": result.directory.path,
                    "manifest": result.manifestPath.path,
                    "exported": result.succeeded.count,
                    "failed": failed.count,
                    "items": result.items.map {
                        [
                            "reference": $0.reference,
                            "file": $0.result?.destination.lastPathComponent ?? NSNull(),
                            "bytes": $0.result?.bytes ?? NSNull(),
                            "error": $0.error ?? NSNull(),
                        ] as [String: Any]
                    },
                    "engine_mutated": false,
                    "network_access": "not used",
                    "credentials_access": "not used",
                ])
            } else {
                out("")
                out("[ok] exported \(result.succeeded.count) image(s) to \(terminalSafe(result.directory.path))")
                if !failed.isEmpty {
                    out("[!!] \(failed.count) image(s) failed:")
                    for item in failed { out("  \(terminalSafe(item.reference)): \(item.error ?? "unknown error")") }
                }
                out("Manifest: \(terminalSafe(result.manifestPath.path))")
                out("Restore any archive on a stock Docker install with: docker load -i <file>.tar")
            }
            return failed.isEmpty ? 0 : 1
        } catch {
            let message = describe(error)
            if json {
                emitJSON([
                    "ok": false, "output": request.output.path, "error": message,
                    "engine_mutated": false, "network_access": "not used", "credentials_access": "not used",
                ])
            } else {
                err("morb export --all: \(message)")
            }
            return 2
        }
    }

    private static func exportImage(arguments: [String], json: Bool) -> Int32 {
        let request: ImageRequest
        do {
            request = try ImageRequest(arguments)
        } catch {
            return usageError(describe(error), json: json)
        }

        if !json {
            out("Exporting a local image archive (no registry or credentials access)")
            out("  image        \(terminalSafe(request.reference))")
            out("  output       \(terminalSafe(request.output.path))")
            out("  replace      \(request.replaceExisting ? "yes, after a complete download" : "no")")
            out("  engine       GET /images/get?names=<image-reference>")
        }

        do {
            let result = try ImageArchiveExporter.export(
                imageReference: request.reference,
                to: request.output,
                replaceExisting: request.replaceExisting)
            if json {
                emitJSON([
                    "ok": true,
                    "reference": result.reference,
                    "output": result.destination.path,
                    "bytes": result.bytes,
                    "engine_request": result.engineRequest,
                    "engine_mutated": false,
                    "network_access": "not used",
                    "credentials_access": "not used",
                ])
            } else {
                out("")
                out("[ok] exported \(Format.bytes(result.bytes)) to \(terminalSafe(result.destination.path))")
                out("The archive may include image configuration and layer contents; keep it in a location appropriate for that data.")
            }
            return 0
        } catch {
            let message = describe(error)
            if json {
                emitJSON([
                    "ok": false,
                    "reference": request.reference,
                    "output": request.output.path,
                    "error": message,
                    "engine_mutated": false,
                    "network_access": "not used",
                    "credentials_access": "not used",
                ])
            } else {
                err("morb export image: \(message)")
                err("No completed archive was published; any private partial staging file was discarded.")
            }
            return 2
        }
    }

    private static func exportVolume(arguments: [String], json: Bool) -> Int32 {
        let request: VolumeRequest
        do {
            request = try VolumeRequest(arguments)
        } catch {
            return usageError(describe(error), json: json)
        }

        if !json {
            out("Exporting one local named-volume archive (no pull, registry, or credentials access)")
            out("  volume       \(terminalSafe(request.name))")
            out("  output       \(terminalSafe(request.output.path))")
            out("  replace      \(request.replaceExisting ? "yes, after helper cleanup and a complete stream" : "no")")
            out("  helper       one already-local image; stopped with /data mounted read-only")
            out("  engine       inspect volume, inspect local images, create/read/remove owned helper")
        }

        do {
            let result = try VolumeArchiveExporter.export(
                volumeName: request.name,
                to: request.output,
                replaceExisting: request.replaceExisting)
            if json {
                emitJSON([
                    "ok": true,
                    "volume": result.volumeName,
                    "driver": result.driver,
                    "output": result.destination.path,
                    "bytes": result.bytes,
                    "helper_image": result.helperImage,
                    "engine_requests": result.engineRequests,
                    "selected_volume_mutated": false,
                    "temporary_helper_created_and_removed": true,
                    "network_access": "not used",
                    "credentials_access": "not used",
                ])
            } else {
                out("")
                out("[ok] exported \(Format.bytes(result.bytes)) from \(terminalSafe(result.volumeName)) to \(terminalSafe(result.destination.path))")
                out("The tar contains the selected volume filesystem data. It was not imported, mounted in Finder, or written back to Docker.")
            }
            return 0
        } catch {
            let message = describe(error)
            if json {
                emitJSON([
                    "ok": false,
                    "volume": request.name,
                    "output": request.output.path,
                    "error": message,
                    "selected_volume_mutated": false,
                    "network_access": "not used",
                    "credentials_access": "not used",
                ])
            } else {
                err("morb export volume: \(message)")
                err("No completed archive was published; any private partial staging file was discarded and owned-helper cleanup was attempted.")
            }
            return 2
        }
    }

    private struct ImageRequest {
        let reference: String
        let output: URL
        let replaceExisting: Bool

        init(_ arguments: [String]) throws {
            var reference: String?
            var outputPath: String?
            var replaceExisting = false
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                switch argument {
                case "--output":
                    guard index + 1 < arguments.count,
                          !arguments[index + 1].isEmpty,
                          !arguments[index + 1].hasPrefix("--")
                    else {
                        throw ArgumentError.missingValue("--output")
                    }
                    guard outputPath == nil else { throw ArgumentError.repeatedOption("--output") }
                    outputPath = arguments[index + 1]
                    index += 2
                case "--replace":
                    guard !replaceExisting else { throw ArgumentError.repeatedOption("--replace") }
                    replaceExisting = true
                    index += 1
                default:
                    guard !argument.hasPrefix("-") else { throw ArgumentError.unknownOption(argument) }
                    guard reference == nil else { throw ArgumentError.unexpectedArgument(argument) }
                    reference = argument
                    index += 1
                }
            }
            guard let reference else { throw ArgumentError.referenceRequired }
            guard let outputPath else { throw ArgumentError.outputRequired }
            self.reference = reference
            self.output = resolvedOutputURL(outputPath)
            self.replaceExisting = replaceExisting
        }
    }

    private struct AllRequest {
        let output: URL
        let replaceExisting: Bool

        init(_ arguments: [String]) throws {
            var outputPath: String?
            var replaceExisting = false
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                switch argument {
                case "--all":
                    index += 1
                case "--output":
                    guard index + 1 < arguments.count,
                          !arguments[index + 1].isEmpty,
                          !arguments[index + 1].hasPrefix("--")
                    else {
                        throw ArgumentError.missingValue("--output")
                    }
                    guard outputPath == nil else { throw ArgumentError.repeatedOption("--output") }
                    outputPath = arguments[index + 1]
                    index += 2
                case "--replace":
                    guard !replaceExisting else { throw ArgumentError.repeatedOption("--replace") }
                    replaceExisting = true
                    index += 1
                default:
                    throw ArgumentError.unexpectedArgument(argument)
                }
            }
            guard let outputPath else { throw ArgumentError.outputRequired }
            output = resolvedOutputURL(outputPath)
            self.replaceExisting = replaceExisting
        }
    }

    private struct VolumeRequest {
        let name: String
        let output: URL
        let replaceExisting: Bool

        init(_ arguments: [String]) throws {
            var name: String?
            var outputPath: String?
            var replaceExisting = false
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                switch argument {
                case "--output":
                    guard index + 1 < arguments.count,
                          !arguments[index + 1].isEmpty,
                          !arguments[index + 1].hasPrefix("--")
                    else {
                        throw ArgumentError.missingValue("--output")
                    }
                    guard outputPath == nil else { throw ArgumentError.repeatedOption("--output") }
                    outputPath = arguments[index + 1]
                    index += 2
                case "--replace":
                    guard !replaceExisting else { throw ArgumentError.repeatedOption("--replace") }
                    replaceExisting = true
                    index += 1
                default:
                    guard !argument.hasPrefix("-") else { throw ArgumentError.unknownOption(argument) }
                    guard name == nil else { throw ArgumentError.unexpectedArgument(argument) }
                    name = argument
                    index += 1
                }
            }
            guard let name else { throw ArgumentError.volumeRequired }
            guard let outputPath else { throw ArgumentError.outputRequired }
            self.name = name
            output = resolvedOutputURL(outputPath)
            self.replaceExisting = replaceExisting
        }
    }

    private enum ArgumentError: Error, CustomStringConvertible {
        case referenceRequired
        case volumeRequired
        case outputRequired
        case missingValue(String)
        case repeatedOption(String)
        case unknownOption(String)
        case unexpectedArgument(String)

        var description: String {
            switch self {
            case .referenceRequired:
                return "an image reference or image ID is required"
            case .volumeRequired:
                return "an explicit named volume is required"
            case .outputRequired:
                return "--output <path> is required; archives are never written to a default location"
            case .missingValue(let option):
                return "\(option) requires a path"
            case .repeatedOption(let option):
                return "\(option) may be passed only once"
            case .unknownOption(let option):
                return "unknown option \(option)"
            case .unexpectedArgument(let value):
                return "unexpected argument \(value)"
            }
        }
    }

    private static func resolvedOutputURL(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded, isDirectory: false)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(expanded, isDirectory: false)
    }

    private static func usageError(_ message: String, json: Bool) -> Int32 {
        if json {
            emitJSON([
                "ok": false,
                "error": message,
                "usage": "morb export <image|volume> <name> --output <path> [--replace]",
            ])
        } else {
            err("morb export: \(message)")
            err("")
            printUsage(to: .standardError)
        }
        return 2
    }

    private static func printUsage(to output: FileHandle = .standardOutput) {
        let text = """
        Usage:
          morb export image <reference> --output <path> [--replace]
          morb export volume <name> --output <path> [--replace]
          morb export --all --output <directory> [--replace]

        `image` saves one already-local Morbstack image through one GET /images/get
        request. `volume` archives one explicit existing Docker local-driver volume
        through one owned stopped read-only helper container. Volume export requires
        an already-local helper image and never pulls one. `--all` writes every local
        tagged image as one archive per image into a directory, plus a MANIFEST.txt;
        a stock Docker CLI restores any of them with `docker load -i <file>.tar`, no
        Morbstack required on the receiving machine.

        The parent directory must already exist. `--output` is required, may be an
        absolute, ~/ or relative path, and must not be inside Morbstack-owned data.
        Existing files are refused unless `--replace` is explicit. The completed
        archive is atomically published only after its private sibling staging file
        has fully downloaded and synced.

        Neither command imports, writes back, mounts files in Finder, accesses a
        registry or credential helper, or creates a default output path. There is no
        native volume export screen in this CLI slice; a future app action must use
        the standard macOS save panel and this same service contract.
        """
        output.write(Data((text + "\n").utf8))
    }

    private static func describe(_ error: Error) -> String {
        if let exportError = error as? ImageArchiveExportError { return exportError.description }
        if let exportError = error as? VolumeArchiveExportError { return exportError.description }
        if let engineError = error as? EngineError { return engineError.description }
        if let argumentError = error as? ArgumentError { return argumentError.description }
        return error.localizedDescription
    }

    private static func terminalSafe(_ value: String) -> String {
        let bidirectionalControls = CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")
        return value.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || bidirectionalControls.contains($0) ? "�" : String($0)
        }.joined()
    }

    private static func emitJSON(_ value: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else {
            err("morb export: could not encode JSON output")
            return
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func out(_ message: String) { print(message) }

    private static func err(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
