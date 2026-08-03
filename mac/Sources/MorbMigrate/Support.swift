// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The small pieces every migrate subcommand needs and none of them owns:
// argument parsing that does not pull in a dependency, a confirmation prompt
// that matches the one `morb context create`/`use` already trained users on
// (mac/Sources/morb/main.swift), and JSON emission that follows the same
// snake_case-keys-over-a-dictionary convention as the rest of `morb`.

import Darwin
import Foundation
import MorbFeatures

// MARK: - Output

func out(_ message: String = "") {
    print(message)
}

func errOut(_ message: String) {
    FileHandle.standardError.write(Data(("morb migrate: " + message + "\n").utf8))
}

/// Prints `data` as sorted, pretty JSON when `--json` was requested, otherwise runs
/// `render`. Every subcommand's success path goes through this so the two output modes
/// can never drift apart on what information they carry.
func emit(json: Bool, data: [String: Any], render: () -> Void) {
    if json {
        out(JSONRead.pretty(data))
    } else {
        render()
    }
}

// MARK: - Argument parsing

/// A hand-parsed argument list.
///
/// Not a general parser — it knows the flags this module's subcommands use and treats
/// anything else starting with `--` as a boolean switch, which is enough for a CLI with
/// six subcommands and no nested subcommands of its own.
struct ParsedArgs {
    var positional: [String] = []
    var flags: Set<String> = []
    var options: [String: String] = [:]

    func flag(_ name: String) -> Bool { flags.contains(name) }
    func option(_ name: String) -> String? { options[name] }
}

/// Splits `arguments` into flags, `--key value` options, and positionals.
///
/// - Parameter valueFlags: the `--name`s that consume the following token as a value
///   rather than being booleans themselves. `--from docker-desktop` needs to know
///   `--from` is one of these or it would swallow `docker-desktop` as a positional.
func parseArgs(_ arguments: [String], valueFlags: Set<String>) -> ParsedArgs {
    var result = ParsedArgs()
    var index = 0
    while index < arguments.count {
        let token = arguments[index]
        if token.hasPrefix("--") {
            let name = String(token.dropFirst(2))
            if valueFlags.contains(name), index + 1 < arguments.count {
                result.options[name] = arguments[index + 1]
                index += 2
                continue
            }
            result.flags.insert(name)
            index += 1
            continue
        }
        result.positional.append(token)
        index += 1
    }
    return result
}

// MARK: - Confirmation

/// The three ways asking "are you sure?" can go.
enum Confirmation {
    /// The person at the keyboard said yes.
    case yes
    /// The person at the keyboard said no, or anything that isn't yes.
    case no
    /// stdin is not a terminal, so there was nobody to ask.
    case noTTY
}

/// Prints `prompt`, then reads a `y`/`yes` answer from a real terminal.
///
/// Mirrors the exact dance `morb context create`/`morb context use` already use
/// (mac/Sources/morb/main.swift): a plain `isatty` check rather than trying to detect
/// "being run from a script" any other way, because that check is the one this
/// codebase's own confirmation prompts already committed to and users already know.
func confirmInteractively(_ prompt: String) -> Confirmation {
    guard isatty(STDIN_FILENO) == 1 else { return .noTTY }
    FileHandle.standardOutput.write(Data((prompt + " [y/N] ").utf8))
    let answer = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespaces)
    return answer.lowercased() == "y" || answer.lowercased() == "yes" ? .yes : .no
}

// MARK: - Byte-rate formatting

/// `Format.bytes` per second, for the live progress lines the image/volume copy loops
/// print — a rate is the one number `Format` (MorbFeatures/FeatureSupport.swift) does
/// not already have a formatter for.
func formatRate(bytes: Int64, seconds: Double) -> String {
    guard seconds > 0.05 else { return "-" }
    return Format.bytes(Int64(Double(bytes) / seconds)) + "/s"
}
