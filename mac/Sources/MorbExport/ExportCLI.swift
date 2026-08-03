// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Command surface for a user-directed Docker image archive. This target has no
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
        default:
            return usageError("unknown export subcommand `\(subcommand)`", json: json)
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

    private enum ArgumentError: Error, CustomStringConvertible {
        case referenceRequired
        case outputRequired
        case missingValue(String)
        case repeatedOption(String)
        case unknownOption(String)
        case unexpectedArgument(String)

        var description: String {
            switch self {
            case .referenceRequired:
                return "an image reference or image ID is required"
            case .outputRequired:
                return "--output <path> is required; image archives are never written to a default location"
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
                "usage": "morb export image <reference> --output <path> [--replace]",
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
        Usage: morb export image <reference> --output <path> [--replace]

        Save one already-local Morbstack image as a Docker archive. This uses exactly
        one current-engine GET /images/get request; it does not pull, push, inspect,
        load, tag, delete, start a container, access a registry, or read credentials.

        The parent directory must already exist. `--output` is required, may be an
        absolute, ~/ or relative path, and must not be inside Morbstack-owned data.
        Existing files are refused unless `--replace` is explicit. The completed
        archive is atomically published only after its private sibling staging file
        has fully downloaded and synced.

        There is no native export screen in this CLI slice. A future app action must
        use the standard macOS save panel and this same service contract.
        """
        output.write(Data((text + "\n").utf8))
    }

    private static func describe(_ error: Error) -> String {
        if let exportError = error as? ImageArchiveExportError { return exportError.description }
        if let engineError = error as? EngineError { return engineError.description }
        if let argumentError = error as? ArgumentError { return argumentError.description }
        return error.localizedDescription
    }

    private static func terminalSafe(_ value: String) -> String {
        let bidirectionalControls = CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")
        value.unicodeScalars.map {
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
