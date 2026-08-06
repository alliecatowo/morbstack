// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// A fixture engine for real-window route probes and future UI tests.
//
// A fixture-backed application still runs normal lifecycle work: `bootstrap()`,
// `refreshAll()`, inspect loading, disk refresh, logs, and stats all use the client.
// Against a dead socket that would make the model report a stopped engine and erase the
// deterministic data before a human or XCUITest can inspect the real app window.
//
// These subclasses answer from `ShotFixtures` instead of dialling a socket. They never
// reach the user's Docker engine, and normal data paths remain exercised without an
// invented rendering surface.

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

    override func inspectNetwork(id: String) async throws -> NetworkInspection {
        guard let inspection = ShotFixtures.networkInspection(id: id) else {
            throw DockerClientError.http(status: 404, message: "no such network: \(id)")
        }
        return inspection
    }

    /// Resolve architecture deterministically. `shopfront/api` deliberately answers
    /// `amd64`; the remaining fixture images answer the host architecture. That gives
    /// the real Images feature an honest foreign-architecture branch to exercise.
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
    /// The stream yields deterministic lines. A live fixture window may choose to preload
    /// the store, but this endpoint remains useful to exercise normal log loading.
    ///
    /// `shopfront-api-1` gets the corpus verbatim — it is the container every existing
    /// capture and the fixture diagnostics use. Every other container gets a
    /// deterministic slice of it, offset in time, so the Compose-aggregated document has
    /// several genuinely different, genuinely interleaved streams to merge instead of
    /// four identical copies of one log arriving at the same instants.
    override func logs(
        id: String, follow: Bool = true, tail: Int = 500
    ) -> AsyncThrowingStream<LogLine, Error> {
        let lines = Self.lines(logLines, for: id)
        return AsyncThrowingStream { continuation in
            for line in lines.suffix(tail) { continuation.yield(line) }
            if !follow { continuation.finish() }
        }
    }

    static func lines(_ corpus: [LogLine], for containerID: String) -> [LogLine] {
        guard containerID != ShotFixtures.container("shopfront-api-1").id else { return corpus }
        // A stable per-container seed: the same container always produces the same
        // slice, so two fixture runs are comparable.
        var seed: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in containerID.utf8 {
            seed ^= UInt64(byte)
            seed = seed &* 0x100_0000_01b3
        }
        let stride = 3 + Int(seed % 4)
        let shift = Double(seed % 900) / 1_000
        return corpus.enumerated()
            .filter { index, _ in index % stride == Int(seed % UInt64(stride)) }
            .enumerated()
            .map { position, element in
                LogLine(
                    id: position,
                    text: element.element.text,
                    stream: element.element.stream,
                    timestamp: element.element.timestamp?.addingTimeInterval(shift))
            }
    }

    /// Replays a fixture series as fast as the consumer will take it.
    ///
    /// The normal consumer may throttle the stream; this source only guarantees that a
    /// deterministic nonempty series is available and that a live subscriber sees no
    /// socket error.
    override func stats(id: String) -> AsyncThrowingStream<StatsSample, Error> {
        let samples = ShotFixtures.statsByContainer
            .first { ShotFixtures.container($0.name).id == id }?
            .samples ?? []
        return AsyncThrowingStream { continuation in
            for sample in samples { continuation.yield(sample) }
        }
    }

    /// A stream that never yields and never ends — the fixture equivalent of an idle
    /// engine event socket.
    override func events() -> AsyncThrowingStream<DockerEvent, Error> {
        AsyncThrowingStream { _ in }
    }

    // MARK: Mutations

    // Fixture automation must never mutate a user's Docker engine. Existing lifecycle
    // calls are safe no-ops for future confirmation tests; a new container creation
    // instead fails explicitly so a fixture review cannot mistake an invented result
    // for a real Engine action.
    override func createLocalImageContainer(imageID: String, request: LocalImageRunRequest) async throws -> String {
        throw DockerClientError.http(
            status: 503,
            message: "Run Local Image is unavailable in fixture mode; no Docker action was performed.")
    }
    override func executeContainerCommand(id: String, command: [String]) async throws -> DockerExecResult {
        throw DockerClientError.http(
            status: 503,
            message: "Run Command is unavailable in fixture mode; no Docker command was performed.")
    }
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
