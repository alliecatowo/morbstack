// swift-tools-version: 6.0
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
        .macOS(.v15)
    ],
    products: [
        .library(name: "MorbstackKit", targets: ["MorbstackKit"]),
        // The app, as a library. Both the `.app` executable and the offscreen
        // screenshot harness link this, which is what keeps the screenshots pictures
        // of the shipping views rather than of a parallel copy of them.
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
        .executableTarget(
            name: "morb",
            dependencies: ["MorbstackKit"],
            swiftSettings: commonSwiftSettings
        ),
        // The SwiftUI app. Same zero-dependency rule as everything else: SwiftUI +
        // Foundation + MorbstackKit, no web views, no packages to resolve.
        //
        // A library rather than the executable itself: `MorbShots` renders these exact
        // views offscreen, and SwiftPM cannot link an executable target into another
        // target. The executable below is a three-line shim over it.
        .target(
            name: "MorbstackAppCore",
            dependencies: ["MorbstackKit"],
            swiftSettings: commonSwiftSettings
        ),
        .executableTarget(
            name: "MorbstackApp",
            dependencies: ["MorbstackAppCore"],
            swiftSettings: commonSwiftSettings
        ),
        // The offscreen screenshot harness. Renders the production views through
        // `ImageRenderer`, which needs no window, no display and no screen-recording
        // permission — see Sources/MorbstackAppCore/Shots.
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
    ]
)
