// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// A fixture engine, so the real views can be rendered against something.
//
// The harness draws the production views inside a real (offscreen) `NSHostingView`, and
// that means the whole lifecycle runs: `bootstrap()`, `refreshAll()`, `loadInspect()`,
// the Disk screen's `refreshDisk()`. Every one of those calls the engine, and against a
// dead socket every one of them fails — `AppModel.fetch` reads an unreachable error as
// "the VM went away", downgrades the engine to stopped and clears the model. The result
// would be a directory full of pictures of the start-the-engine screen.
//
// The fix is not to suppress the calls but to answer them. These two subclasses return
// the fixture world instead of dialling a socket, so every code path the app would take
// against a live engine runs for real — including the ones that would have caught a
// mistake in the fixtures.

import Foundation

// MARK: - Docker

/// A `DockerClient` that serves `ShotFixtures` instead of `~/.morbstack/run/docker.sock`.
final class ShotDockerClient: DockerClient, @unchecked Sendable {

    private let logLines: [LogLine]

    init(logLines: [LogLine]) {
        self.logLines = logLines
        // A path that cannot exist, so that anything this class fails to override fails
        // loudly and locally rather than quietly talking to the user's real engine.
        super.init(socketPath: "/dev/null/morbshots-fixture.sock")
    }

    // MARK: Lists

    override func listContainers(all: Bool = true) async throws -> [ContainerSummary] {
        all ? ShotFixtures.containers : ShotFixtures.containers.filter(\.isRunning)
    }

    override func listImages() async throws -> [ImageSummary] { ShotFixtures.images }
    override func listVolumes() async throws -> [VolumeSummary] { ShotFixtures.volumes }
    override func listNetworks() async throws -> [NetworkSummary] { ShotFixtures.networks }
    override func diskUsage() async throws -> DiskUsage { ShotFixtures.disk }
    override func buildCacheRecords() async throws -> [BuildCacheRecord] { ShotFixtures.buildCache }

    override func inspectContainer(id: String) async throws -> String {
        guard let container = ShotFixtures.containers.first(where: { $0.id == id }) else {
            throw DockerClientError.http(status: 404, message: "no such container: \(id)")
        }
        return ShotFixtures.inspectJSON(for: container)
    }

    /// The base implementation calls the fake socket and throws, which leaves the
    /// Images detail pane showing "checking…" forever — not a blank the harness can
    /// tell apart from a slow real request, so it never resolves to a picture of the
    /// finished state. `shopfront/api` answers `amd64`, deliberately not arm64: every
    /// other fixture image is native and gets no badge at all (see
    /// `TrackCImageArch.Badge.isNoteworthy`), so an all-native list would never
    /// photograph the translated-badge and Rosetta-advice text this screen exists to
    /// show. Everything else answers the host architecture, i.e. no badge.
    override func imageArchitecture(id: String) async throws -> ImageArchitecture? {
        guard let image = ShotFixtures.images.first(where: { $0.id == id }) else { return nil }
        let arch = image.repoTags.first?.hasPrefix("shopfront/api") == true
            ? "amd64" : ImageArchitecture.host
        return ImageArchitecture(os: "linux", arch: arch)
    }

    override func containerHasTTY(id: String) async -> Bool { false }

    // MARK: Streams

    /// Delivers the canned scrollback and ends.
    ///
    /// Ending rather than hanging matters: the Logs toolbar shows a green "streaming"
    /// dot while a stream is open and "· ended" once it closes, and a screenshot of a
    /// finished stream would undersell what the tab does. The harness therefore preloads
    /// the store instead of relying on this — but this exists so that a scene that
    /// forgets to preload still renders lines rather than "Waiting for output…".
    override func logs(
        id: String, follow: Bool = true, tail: Int = 500
    ) -> AsyncThrowingStream<LogLine, Error> {
        let lines = logLines
        return AsyncThrowingStream { continuation in
            for line in lines.suffix(tail) { continuation.yield(line) }
            if !follow { continuation.finish() }
        }
    }

    /// Replays a fixture series as fast as the consumer will take it.
    ///
    /// The hub throttles to one sample every two seconds of wall clock, so this alone
    /// cannot fill a sixty-slot sparkline inside a render. `ShotFixtures.statsHub()`
    /// seeds the history directly; this keeps a live subscriber from seeing an error.
    override func stats(id: String) -> AsyncThrowingStream<StatsSample, Error> {
        let samples = ShotFixtures.statsByContainer
            .first { ShotFixtures.container($0.name).id == id }?
            .samples ?? []
        return AsyncThrowingStream { continuation in
            for sample in samples { continuation.yield(sample) }
        }
    }

    /// A stream that never yields and never ends — an idle engine, which is what the
    /// event socket looks like in the half second a render takes.
    override func events() -> AsyncThrowingStream<DockerEvent, Error> {
        AsyncThrowingStream { _ in }
    }

    // MARK: Mutations

    // Nothing in a screenshot presses a button, but leaving these to hit the socket
    // would make an accidental invocation slow rather than instant.
    override func startContainer(id: String) async throws {}
    override func stopContainer(id: String) async throws {}
    override func restartContainer(id: String) async throws {}
    override func pauseContainer(id: String) async throws {}
    override func unpauseContainer(id: String) async throws {}
    override func removeContainer(id: String) async throws {}
}

// MARK: - Daemon

/// A `DaemonClient` that reports whatever engine state a scene asked for.
final class ShotDaemonClient: DaemonClient, @unchecked Sendable {

    private let reported: EngineStatus

    init(reporting status: EngineStatus) {
        self.reported = status
        super.init(
            socketPath: "/dev/null/morbshots-fixture-daemon.sock",
            daemonExecutable: nil)
    }

    override func status() async -> EngineStatus { reported }

    override func start() async throws {}
    override func stop() async throws {}
    override func suspend() async throws {}
}
