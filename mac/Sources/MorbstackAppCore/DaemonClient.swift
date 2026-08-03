// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The app's side of the `morbstackd` control protocol.
//
// One newline-delimited JSON object each way over ~/.morbstack/run/morbstackd.sock,
// exactly as the `morb` CLI speaks it — `UnixSocketClient.roundTrip` is shared with the
// CLI so there is only ever one implementation of the framing.
//
// The rule that shapes this file: **`status()` never brings a daemon into existence.**
// `MorbCommandPolicy` spells out why — an observation that creates the thing it
// observes is not an observation — and the app is the worst possible place to break it,
// because the app polls status at launch, on wake, and after every engine action. A
// menu-bar item that silently boots a VM because somebody glanced at it would be a
// genuinely alarming piece of software. So `status()` returns "unreachable" when nobody
// answers, and only the explicit `start()` — a button the user pressed — may spawn.

import Darwin
import Foundation
import MorbstackKit

/// Talks to `morbstackd` over its control socket.
///
/// Not `@MainActor`: every call blocks on socket I/O and is hopped onto a background
/// queue. The class holds two paths and nothing mutable, which is what makes concurrent
/// calls from the model safe.
/// Non-`final` so deterministic fixture clients can support developer route probes
/// without a running daemon. See `Shots/ShotClients.swift`.
class DaemonClient: @unchecked Sendable {

    /// How long to wait for a reply to a cheap, non-mutating command.
    private static let statusTimeout: TimeInterval = 5
    /// How long to wait for a VM lifecycle command.
    ///
    /// Matches the `morb` CLI's own budget. `stop` nests a 90 s daemon-side deadline
    /// inside this, and the nesting is load-bearing: an outer layer that gives up first
    /// leaves the guest's dirty pages outstanding.
    private static let lifecycleTimeout: TimeInterval = 120
    /// Kubernetes enablement can include a one-time payload transfer; status and
    /// kubeconfig commands use the same daemon-side budget so the UI does not give up
    /// while the daemon is still honestly working.
    private static let kubernetesTimeout: TimeInterval = 120

    let socketPath: String

    /// Where a daemon would be launched from, when the user asks for one.
    ///
    /// Resolved next to the running app rather than from `PATH`: a bundled app has no
    /// useful `PATH`, and picking up a stray `morbstackd` from a shell profile is how
    /// you end up running a version that does not match the UI.
    let daemonExecutable: URL?

    init(
        socketPath: String = MorbPaths.controlSocket.path,
        daemonExecutable: URL? = DaemonClient.locateDaemonExecutable()
    ) {
        self.socketPath = socketPath
        self.daemonExecutable = daemonExecutable
    }

    // MARK: - Status

    /// Asks the daemon how it is doing.
    ///
    /// Never throws and never spawns: the failure mode this has to represent is "the
    /// engine is not running", which is an ordinary state of the world rather than an
    /// error, and the UI renders it as a start button. Returning ``EngineStatus/unknown``
    /// is how that state reaches the model.
    func status() async -> EngineStatus {
        guard FileManager.default.fileExists(atPath: socketPath) else { return .unknown }
        guard let response = try? await roundTrip(DaemonRequest(cmd: "status"), timeout: Self.statusTimeout),
              response.ok, let data = response.data
        else {
            return .unknown
        }

        func string(_ key: String) -> String? {
            if case .string(let value) = data[key] { return value }
            return nil
        }
        func bool(_ key: String) -> Bool? {
            if case .bool(let value) = data[key] { return value }
            return nil
        }

        let state = string("state") ?? "stopped"
        // `state == running` means the VM is executing; it does not yet mean dockerd
        // has finished coming up inside it. Listing containers against a VM that is
        // still booting produces a connection error the user cannot act on, so the
        // guest's own readiness flag is what the app treats as "running".
        let dockerReady = bool("docker_ready") ?? false
        let effectiveState = (state == "running" && !dockerReady) ? "starting" : state

        return EngineStatus(
            state: effectiveState,
            vmState: string("vm_state") ?? effectiveState,
            version: string("version"),
            reachable: true)
    }

    /// The guest's view of the shared host paths, or `nil` when nothing answered.
    ///
    /// `nil` and `[]` are different answers and both are used: `nil` means "no daemon,
    /// or a daemon that does not implement this", and the caller falls back to the
    /// config file and reports every root as unmounted-because-nothing-is-running. `[]`
    /// means a live daemon that shares nothing, which is a real configuration.
    ///
    /// Same rule as ``status()``: never spawns. The Settings pane and the status chip
    /// both read this, and neither is a place a VM should be able to appear from.
    func shares() async -> [MorbShareState]? {
        guard FileManager.default.fileExists(atPath: socketPath) else { return nil }
        guard let response = try? await roundTrip(DaemonRequest(cmd: "shares"), timeout: Self.statusTimeout),
              response.ok
        else { return nil }
        return MorbShareSurface.decodeShares(response.data)
    }

    /// The guest's Rosetta state, or `nil` when nothing answered.
    ///
    /// `supported` is the host's own answer, which the caller already has and this
    /// cannot determine — the daemon reports what the guest is doing, not whether this
    /// Mac is capable of Rosetta at all.
    func rosetta(supported: Bool) async -> MorbRosettaState? {
        guard FileManager.default.fileExists(atPath: socketPath) else { return nil }
        guard let response = try? await roundTrip(DaemonRequest(cmd: "rosetta"), timeout: Self.statusTimeout),
              response.ok
        else { return nil }
        return MorbShareSurface.decodeRosetta(response.data, supported: supported)
    }

    /// The daemon's version string, or `nil` when nothing answered.
    func version() async -> String? {
        guard let response = try? await roundTrip(DaemonRequest(cmd: "version"), timeout: Self.statusTimeout),
              response.ok, case .string(let value)? = response.data?["version"]
        else { return nil }
        return value
    }

    // MARK: - Kubernetes

    /// Reads the daemon's real `k8s-status` reply. Like `status()`, this never starts
    /// the engine: describing a cluster must not create one.
    func kubernetesStatus() async throws -> K8s.Status {
        try await decodeKubernetesStatus(command: "k8s-status")
    }

    /// Reads the daemon's read-only Kubernetes recovery diagnosis. The daemon derives
    /// it from the same guest status used by ``kubernetesStatus()``, plus its actual
    /// loopback API forward and Morbstack-owned kubeconfig; the app does not infer a
    /// recovery action from fixture-style assumptions.
    func diagnoseKubernetes() async throws -> K8s.Diagnosis {
        let fields = try await kubernetesCommand("k8s-diagnose")
        let status = try decodeKubernetesStatus(fields)
        let port: Int?
        if case .int(let value)? = fields["host_api_port"] {
            port = value
        } else {
            port = nil
        }
        let kubeconfigExists: Bool
        if case .bool(let value)? = fields["kubeconfig_exists"] {
            kubeconfigExists = value
        } else {
            throw MorbError.protocolViolation("morbstackd returned no kubeconfig status")
        }
        return K8s.Diagnosis(
            status: status, hostAPIServerPort: port, kubeconfigExists: kubeconfigExists)
    }

    /// Explicitly enables the local cluster. The app only exposes this after the
    /// engine is running, so unlike the CLI it does not need to spawn a daemon here.
    func enableKubernetes() async throws -> K8s.Status {
        try await decodeKubernetesStatus(command: "k8s-enable")
    }

    /// Explicitly disables the local cluster.
    func disableKubernetes() async throws -> K8s.Status {
        try await decodeKubernetesStatus(command: "k8s-disable")
    }

    /// Asks the daemon to write Morbstack's own 0600 kubeconfig and returns only the
    /// expected app-owned path. This command deliberately has no merge argument: the
    /// UI must never edit a person's `~/.kube/config` as a side effect of browsing a
    /// local cluster.
    func writeKubernetesKubeconfig() async throws -> URL {
        let fields = try await kubernetesCommand("k8s-kubeconfig")
        guard case .string(let path)? = fields["path"], !path.isEmpty else {
            throw MorbError.protocolViolation("morbstackd returned no kubeconfig path")
        }
        let received = URL(fileURLWithPath: path).standardizedFileURL
        let expected = MorbPaths.kubeconfig.standardizedFileURL
        guard received == expected else {
            throw MorbError.protocolViolation(
                "morbstackd returned an unexpected kubeconfig path `\(path)`")
        }
        return received
    }

    private func decodeKubernetesStatus(command: String) async throws -> K8s.Status {
        let fields = try await kubernetesCommand(command)
        return try decodeKubernetesStatus(fields)
    }

    private func decodeKubernetesStatus(_ fields: [String: AnyCodableValue]) throws -> K8s.Status {
        do {
            return try JSONDecoder().decode(K8s.Status.self, from: JSONEncoder().encode(fields))
        } catch {
            throw MorbError.protocolViolation(
                "morbstackd returned an invalid Kubernetes status: \(error.localizedDescription)")
        }
    }

    private func kubernetesCommand(_ command: String) async throws -> [String: AnyCodableValue] {
        let response = try await roundTrip(
            DaemonRequest(cmd: command), timeout: Self.kubernetesTimeout)
        guard response.ok else {
            throw MorbError.vm(response.error ?? "morbstackd rejected \(command)")
        }
        return response.data ?? [:]
    }

    // MARK: - Lifecycle

    /// Boots the engine VM, launching a daemon first if none is listening.
    ///
    /// This is the one entry point allowed to spawn, and only because it is reached
    /// exclusively from a button the user pressed. After spawning it waits for the
    /// control socket to appear rather than assuming it is instantly there: the daemon
    /// binds its socket a beat after `exec`, and a request sent into that gap fails for
    /// a reason that has nothing to do with the VM.
    func start() async throws {
        if !UnixSocketClient.isAlive(path: socketPath, timeout: 0.5) {
            try spawnDaemon()
            guard await waitForSocket(deadline: 10) else {
                throw MorbError.timeout("morbstackd did not open its control socket")
            }
        }
        try await call(DaemonRequest(cmd: "start"), timeout: Self.lifecycleTimeout)
    }

    /// Shuts the VM down cleanly.
    func stop() async throws {
        try await call(DaemonRequest(cmd: "stop"), timeout: Self.lifecycleTimeout)
    }

    /// Pauses the VM and saves its memory to disk.
    func suspend() async throws {
        try await call(DaemonRequest(cmd: "suspend"), timeout: Self.lifecycleTimeout)
    }

    /// Restores a suspended VM.
    func resume() async throws {
        try await call(DaemonRequest(cmd: "resume"), timeout: Self.lifecycleTimeout)
    }

    /// Sends a command and turns a `{"ok":false}` reply into a thrown error.
    private func call(_ request: DaemonRequest, timeout: TimeInterval) async throws {
        let response = try await roundTrip(request, timeout: timeout)
        guard response.ok else {
            throw MorbError.vm(response.error ?? "morbstackd rejected \(request.cmd)")
        }
    }

    /// One request/response exchange, off the cooperative pool.
    private func roundTrip(_ request: DaemonRequest, timeout: TimeInterval) async throws -> DaemonResponse {
        let path = socketPath
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let response = try UnixSocketClient.roundTrip(path: path, request: request, timeout: timeout)
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Spawning

    /// Finds the `morbstackd` binary that belongs to this build.
    ///
    /// Checked in order of how confident we are that the answer matches this app:
    /// an explicit override, then the app bundle's own `Contents/MacOS`, then the
    /// SwiftPM build directory the executable is sitting in during development, then
    /// the two conventional install prefixes. `PATH` is deliberately not consulted.
    static func locateDaemonExecutable() -> URL? {
        let fm = FileManager.default

        if let override = ProcessInfo.processInfo.environment["MORBSTACKD_PATH"], !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            if fm.isExecutableFile(atPath: url.path) { return url }
        }

        var candidates: [URL] = []
        // `Morbstack.app/Contents/MacOS/MorbstackApp` → sibling `morbstackd`, and the
        // same expression covers `.build/release/MorbstackApp` during development.
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        candidates.append(executableDirectory.appendingPathComponent("morbstackd"))
        candidates.append(
            executableDirectory
                .deletingLastPathComponent()  // Contents/
                .appendingPathComponent("Helpers/morbstackd"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/morbstackd"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/morbstackd"))

        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// Launches a detached `morbstackd`.
    private func spawnDaemon() throws {
        guard let daemonExecutable else {
            throw MorbError.notFound(
                "could not find the morbstackd binary — install it alongside Morbstack.app, "
                    + "or start the engine with morb start")
        }
        let process = Process()
        process.executableURL = daemonExecutable
        process.arguments = ["--foreground"]
        // The daemon outlives this app: it owns the VM, and quitting the UI must not
        // take a running engine with it. Detaching stdio keeps the child from being
        // wedged on a pipe nobody drains once the app exits.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw MorbError.io("could not launch morbstackd: \(error.localizedDescription)")
        }
    }

    /// Polls for the control socket to start answering, up to `deadline` seconds.
    private func waitForSocket(deadline: TimeInterval) async -> Bool {
        let expiry = Date().addingTimeInterval(deadline)
        while Date() < expiry {
            if UnixSocketClient.isAlive(path: socketPath, timeout: 0.3) { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }
}
