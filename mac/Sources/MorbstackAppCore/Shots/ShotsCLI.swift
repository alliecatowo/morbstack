// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Fixture diagnostics entry point.
//
// `MorbShots` is retained as a compatibility product name, but it no longer makes
// screenshots.  A headless SwiftUI/AppKit render cannot validate a native macOS window:
// WindowServer owns the titlebar, toolbar, sidebar material, sheets, inspectors, focus,
// and Liquid Glass composition.  Making a PNG from a private approximation caused the
// visual test rig to drive product architecture in the wrong direction.
//
// Use this command to validate the deterministic demo data that backs `--tour-fixtures`:
//
//     swift run MorbShots
//
// It writes no images.  Review a fixture-backed window through Computer Use today; add
// XCUITest assertions and screenshots when the project has an approved UI-test host.

import Foundation

public enum MorbShotsCLI {

    @MainActor
    public static func main() {
        let options = Options(arguments: CommandLine.arguments)
        if options.helpRequested {
            print(Options.usage)
            return
        }

        if let rejected = options.rejectedOutputPath {
            fail("--out \(rejected) is no longer supported: this command writes no images. "
                + "Use --tour-fixtures with Computer Use for full-window review.")
        }

        let checks = FixtureDiagnostics.run()
        let failures = checks.filter { !$0.passed }

        print("Morbstack fixture diagnostics — not screenshots")
        print("  Deterministic data only; no SwiftUI/AppKit window or bitmap was rendered.")
        print("  Full-window approval: Computer Use now; XCUITest when a UI-test host exists.")
        print("")
        for check in checks {
            let marker = check.passed ? "✓" : "✗"
            print("  \(marker) \(check.name): \(check.detail)")
        }
        print("")
        print("\(checks.count - failures.count)/\(checks.count) fixture checks passed")

        if !failures.isEmpty {
            exit(1)
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("MorbShots: \(message)\n".utf8))
        exit(2)
    }

    private struct Options {
        var helpRequested = false
        var rejectedOutputPath: String?

        init(arguments: [String]) {
            var index = 1
            while index < arguments.count {
                switch arguments[index] {
                case "--help", "-h":
                    helpRequested = true
                case "--out", "-o":
                    if index + 1 < arguments.count {
                        index += 1
                        rejectedOutputPath = arguments[index]
                    } else {
                        rejectedOutputPath = "<missing path>"
                    }
                default:
                    break
                }
                index += 1
            }
        }

        static let usage = """
        Usage: swift run MorbShots

        Validate the deterministic --tour-fixtures data. This command intentionally
        writes no screenshots and cannot approve titlebars, toolbars, sidebars, materials,
        inspectors, focus, or other WindowServer-composited macOS behavior.
        """
    }
}
