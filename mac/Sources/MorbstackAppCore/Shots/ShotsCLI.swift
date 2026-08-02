// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The screenshot run.
//
// Walks `ShotScenes.all` twice — once light, once dark — rasterises each through
// `ShotRenderer`, and prints a table of what came out. The table is not decoration: the
// per-image statistics are the only automatic check that a scene rendered *something*,
// and a run that quietly wrote thirty-four transparent rectangles would otherwise look
// exactly like a run that worked.
//
//     swift run MorbShots --out ../dist/shots
//
// Options:
//   --out <dir>     where the PNGs go (default: dist/shots beside the package)
//   --only <a,b>    render just these scenes, by name; substring match
//   --scheme <s>    "light", "dark" or "both" (default: both)
//   --scale <n>     device pixels per point (default: 2)

import AppKit
import SwiftUI

public enum MorbShotsCLI {

    // MARK: - Entry point

    @MainActor
    public static func main() {
        let options = Options(CommandLine.arguments)

        // No dock icon, no menu bar, no chance of a window appearing in front of whatever
        // the person running this is doing. The offscreen hosting views do not need an
        // activation policy that puts the process on screen.
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        do {
            try FileManager.default.createDirectory(
                at: options.outputDirectory, withIntermediateDirectories: true)
        } catch {
            fail("cannot create \(options.outputDirectory.path): \(error.localizedDescription)")
        }

        let scenes = ShotScenes.all.filter(options.matches)
        guard !scenes.isEmpty else {
            fail("no scenes matched \(options.only.joined(separator: ", "))")
        }

        print("Morbstack screenshots")
        print("  out    \(options.outputDirectory.path)")
        print("  scenes \(scenes.count)  schemes \(options.schemes.count)  scale \(Int(options.scale))x")
        print("")

        var outputs: [ShotRenderer.Output] = []
        var failures: [String] = []

        for scene in scenes {
            for scheme in options.schemes {
                do {
                    let output = try ShotRenderer.write(
                        scene.build(),
                        name: scene.name,
                        size: scene.size,
                        scheme: scheme,
                        scale: options.scale,
                        settle: scene.settle,
                        to: options.outputDirectory)
                    outputs.append(output)
                    print(row(for: output, scheme: scheme))
                    if output.stats.looksBlank {
                        failures.append("\(output.name): looks blank")
                    }
                    if let mismatch = schemeMismatch(output.stats, scheme: scheme) {
                        failures.append("\(output.name): \(mismatch)")
                    }
                } catch {
                    let label = "\(scene.name)-\(scheme == .dark ? "dark" : "light")"
                    print("  \(label.padded(to: 34))  FAILED  \(error.localizedDescription)")
                    failures.append("\(label): \(error.localizedDescription)")
                }
            }
        }

        print("")
        print("\(outputs.count) image(s), \(byteSize(outputs.reduce(0) { $0 + $1.bytes })) total")

        if failures.isEmpty {
            print("no automatic warnings — now look at them")
        } else {
            print("")
            print("\(failures.count) warning(s):")
            for warning in failures { print("  ! \(warning)") }
        }

        // A run that produced nothing usable should not look like a success to a script.
        if outputs.isEmpty { exit(1) }
    }

    // MARK: - Reporting

    private static func row(for output: ShotRenderer.Output, scheme: ColorScheme) -> String {
        let stats = output.stats
        return "  "
            + output.name.padded(to: 38)
            + "\(stats.width)x\(stats.height)".padded(to: 12)
            + byteSize(output.bytes).padded(to: 10)
            + "lum " + String(format: "%.2f", stats.meanLuminance).padded(to: 7)
            + "colours " + "\(stats.distinctColours)".padded(to: 6)
            + (stats.looksBlank ? "BLANK?" : "")
    }

    /// Catches the appearance not taking: a dark shot should be dark and a light one
    /// light, and the mean luminance of a full window is a blunt but reliable test of it.
    ///
    /// The thresholds are deliberately loose. A dark window with a big white chart in it
    /// still comes out well under 0.5, and a light one well over 0.25; anything between
    /// is not worth an alarm.
    private static func schemeMismatch(_ stats: ShotBitmapStats, scheme: ColorScheme) -> String? {
        switch scheme {
        case .dark where stats.meanLuminance > 0.55:
            return String(format: "dark render is bright (mean luminance %.2f)", stats.meanLuminance)
        case .light where stats.meanLuminance < 0.30:
            return String(format: "light render is dark (mean luminance %.2f)", stats.meanLuminance)
        default:
            return nil
        }
    }

    private static func byteSize(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[unit])
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("MorbShots: \(message)\n".utf8))
        exit(1)
    }

    // MARK: - Options

    private struct Options {

        var outputDirectory: URL
        var only: [String] = []
        var schemes: [ColorScheme] = [.light, .dark]
        var scale: CGFloat = 2

        init(_ arguments: [String]) {
            // Default: `dist/shots` at the repository root, which is two levels up from
            // the package directory the binary is usually run from.
            outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("dist/shots")

            var index = 1
            while index < arguments.count {
                let argument = arguments[index]
                let value = index + 1 < arguments.count ? arguments[index + 1] : nil
                switch argument {
                case "--out", "-o":
                    if let value {
                        outputDirectory = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
                        index += 1
                    }
                case "--only":
                    if let value {
                        only = value.split(separator: ",").map {
                            $0.trimmingCharacters(in: .whitespaces)
                        }
                        index += 1
                    }
                case "--scheme":
                    switch value {
                    case "light": schemes = [.light]
                    case "dark": schemes = [.dark]
                    default: schemes = [.light, .dark]
                    }
                    if value != nil { index += 1 }
                case "--scale":
                    if let value, let parsed = Double(value), parsed > 0 {
                        scale = CGFloat(parsed)
                        index += 1
                    }
                default:
                    break
                }
                index += 1
            }
        }

        func matches(_ scene: ShotScene) -> Bool {
            only.isEmpty || only.contains { scene.name.contains($0) }
        }
    }
}

// MARK: - Column helper

extension String {
    /// Pads for the report table. Not `padding(toLength:)`, which *truncates* a longer
    /// string — a scene name silently cut in half is exactly the sort of small lie that
    /// makes a report useless.
    fileprivate func padded(to width: Int) -> String {
        count >= width ? self + "  " : self + String(repeating: " ", count: width - count)
    }
}
