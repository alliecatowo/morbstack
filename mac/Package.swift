// swift-tools-version: 6.2
//
// Morbstack — a Docker Desktop replacement for macOS.
// Copyright 2026 The Morbstack Authors. Licensed under the Apache License, Version 2.0.
//
// Deliberately dependency-free: everything is Foundation + system frameworks so that
// `swift build` works on a fresh machine with no network access.

import PackageDescription

// Swift 5 language mode keeps strict-concurrency pragmatic: the Virtualization
// framework's completion handlers are explicitly non-Sendable, and the daemon is
// structured around serial dispatch queues rather than actors.
let commonSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5)
]

let package = Package(
    name: "morbstack",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "MorbstackKit", targets: ["MorbstackKit"]),
        // The app core is a library so the bundle executable, deterministic tour
        // fixtures, and fixture diagnostics share the shipping models and views.
        .library(name: "MorbstackAppCore", targets: ["MorbstackAppCore"]),
        .executable(name: "morbstackd", targets: ["morbstackd"]),
        .executable(name: "morb", targets: ["morb"]),
        .executable(name: "MorbstackApp", targets: ["MorbstackApp"]),
        .executable(name: "MorbLive", targets: ["MorbLive"]),
        .executable(name: "MorbShots", targets: ["MorbShots"]),
    ],
    targets: [
        .target(
            name: "MorbstackKit",
            swiftSettings: commonSwiftSettings
        ),
        .executableTarget(
            name: "morbstackd",
            dependencies: ["MorbstackKit"],
            swiftSettings: commonSwiftSettings
        ),
        // Shared plumbing for the feature modules below: a general-purpose Docker
        // Engine API client, a subprocess runner with a deadline, and the table/format
        // helpers they all print through. Built on MorbstackKit's HTTP framing so the
        // repository has one chunked-transfer decoder rather than two.
        .target(
            name: "MorbFeatures",
            dependencies: ["MorbstackKit"],
            swiftSettings: commonSwiftSettings
        ),
        // `morb mcp serve` — a Model Context Protocol server over stdio, read-only by
        // default. See docs/mcp.md.
        .target(
            name: "MorbMCP",
            dependencies: ["MorbFeatures", "MorbstackKit"],
            swiftSettings: commonSwiftSettings
        ),
        // `morb migrate` — Docker Desktop / Colima / OrbStack migration. Never
        // destructive, never writes to another runtime's state. See docs/migrate.md.
        .target(
            name: "MorbMigrate",
            dependencies: ["MorbFeatures", "MorbstackKit"],
            swiftSettings: commonSwiftSettings
        ),
        // `morb bench` — the open benchmark harness. See docs/benchmarks.md.
        .target(
            name: "MorbBench",
            dependencies: ["MorbFeatures", "MorbstackKit"],
            swiftSettings: commonSwiftSettings
        ),
        // `morb scan` and `morb debug` — local-only SBOM/CVE scanning and the
        // read-only foundation for a future container toolbox. See docs/scanning.md,
        // docs/debug.md.
        .target(
            name: "MorbScan",
            dependencies: ["MorbFeatures", "MorbstackKit"],
            swiftSettings: commonSwiftSettings
        ),
        // `morb export` — an explicit, local Docker image archive writer. Kept
        // separate from scan/migration so it owns one current-engine, user-selected
        // export contract rather than inheriting either feature's broader policy.
        .target(
            name: "MorbExport",
            dependencies: ["MorbFeatures", "MorbstackKit"],
            swiftSettings: commonSwiftSettings
        ),
        .executableTarget(
            name: "morb",
            dependencies: ["MorbstackKit", "MorbMCP", "MorbMigrate", "MorbBench", "MorbScan", "MorbExport"],
            swiftSettings: commonSwiftSettings
        ),
        // The SwiftUI app. Same zero-dependency rule as everything else: SwiftUI +
        // Foundation + MorbstackKit, no web views, no packages to resolve.
        //
        // A library rather than the executable itself lets the small bundle entry point
        // and fixture-diagnostics executable share one implementation. The app target
        // below remains a three-line shim over it.
        .target(
            name: "MorbstackAppCore",
            dependencies: ["MorbstackKit", "MorbFeatures", "MorbMigrate"],
            swiftSettings: commonSwiftSettings
        ),
        .executableTarget(
            name: "MorbstackApp",
            dependencies: ["MorbstackAppCore"],
            swiftSettings: commonSwiftSettings
        ),
        // Deterministic fixture diagnostics. `MorbShots` is a compatibility product
        // name; it checks fixture invariants and produces no visual evidence. Native
        // window validation belongs to XCUITest and Computer Use.
        .executableTarget(
            name: "MorbShots",
            dependencies: ["MorbstackAppCore"],
            swiftSettings: commonSwiftSettings
        ),
        // The live engine harness. Drives the real `DockerClient` against a real
        // dockerd over ~/.morbstack/run/docker.sock and prints a PASS/FAIL table.
        //
        // An executable rather than a test target on purpose: `swift test` runs in CI
        // and on every `make test`, where there is no VM, no engine and no containers
        // to look at. A check that needs a booted guest must be something a human (or
        // scripts/live-app-check.sh) chooses to run, not something that turns the
        // suite red on a laptop with the engine stopped.
        .executableTarget(
            name: "MorbLive",
            dependencies: ["MorbstackAppCore", "MorbstackKit"],
            swiftSettings: commonSwiftSettings
        ),
        .testTarget(
            name: "MorbstackKitTests",
            dependencies: ["MorbstackKit"],
            swiftSettings: commonSwiftSettings
        ),
        .testTarget(
            name: "MorbstackAppTests",
            dependencies: ["MorbstackAppCore"],
            swiftSettings: commonSwiftSettings
        ),
        // One suite for all four feature modules. They share the same helpers and the
        // same "pure logic is unit-tested, anything needing a booted VM is a live
        // check" split, so splitting them into four test targets would multiply build
        // time without separating anything that is actually separate.
        .testTarget(
            name: "MorbFeaturesTests",
            dependencies: ["MorbFeatures", "MorbMCP", "MorbMigrate", "MorbBench", "MorbScan"],
            swiftSettings: commonSwiftSettings
        ),
    ]
)
