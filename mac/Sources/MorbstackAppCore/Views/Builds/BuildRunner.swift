// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The local Buildx runner used by the native Builds sheet.
//
// Docker Engine's POST /build endpoint can stream real progress and treats a dropped
// client connection as cancellation. It expects a Docker-context tar archive, though.
// Do not recreate that archive in the app: Docker's client owns the precise .dockerignore,
// symlink, and context rules people already rely on. Morbstack ships that client and
// buildx plugin, so the sheet invokes the bundled pair against Morbstack's own socket
// and consumes buildx's documented raw-JSON progress stream.

import Darwin
import Foundation
import MorbstackKit

/// The explicit information a person reviews before starting a local BuildKit build.
///
/// There are deliberately no implicit current-working-directory or remote-context
/// defaults. A build executes arbitrary Dockerfile instructions in the guest, so its
/// source directory has to be selected in the sheet and the confirmation names it.
struct LocalBuildRequest: Equatable, Sendable {
    let contextDirectory: URL
    let tag: String

    init(contextDirectory: URL, tag: String) throws {
        let contextDirectory = contextDirectory.standardizedFileURL
        let values = try contextDirectory.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw BuildRunnerError.invalidContext("Choose a folder containing a Dockerfile.")
        }
        let dockerfile = contextDirectory.appendingPathComponent("Dockerfile", isDirectory: false)
        guard FileManager.default.fileExists(atPath: dockerfile.path) else {
            throw BuildRunnerError.invalidContext(
                "\(contextDirectory.lastPathComponent) does not contain a root-level Dockerfile.")
        }
        self.contextDirectory = contextDirectory
        self.tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A concise display label for confirmation and progress, never a shell argument.
    var displayName: String { tag.isEmpty ? contextDirectory.lastPathComponent : tag }

    /// The exact Buildx command arguments after the bundled `docker` executable.
    ///
    /// `--load` makes this intentionally single-platform, local-image-store workflow
    /// observable in the Images route when it succeeds. It never pushes a registry.
    var arguments: [String] {
        var arguments = ["buildx", "build", "--progress=rawjson", "--load"]
        if !tag.isEmpty { arguments += ["--tag", tag] }
        arguments.append(contextDirectory.path)
        return arguments
    }
}

/// A real line emitted by `docker buildx build --progress=rawjson`.
///
/// BuildKit does not promise a total-step count up front, so a native indeterminate
/// ``ProgressView`` is the truthful progress representation. The `message` is an
/// observed status/name/stream line, never a percentage Morbstack guessed.
struct BuildProgressEvent: Identifiable, Equatable, Sendable {
    let sequence: Int
    let identifier: String?
    let message: String
    let isError: Bool

    var id: Int { sequence }
}

/// Decodes the intentionally loose Buildx raw-JSON stream without claiming a schema
/// that every supported BuildKit version emits. This is pure so fixture/unit coverage
/// can verify progress semantics without starting a build.
enum BuildProgressDecoder {

    static func event(line: String, sequence: Int) -> BuildProgressEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Buildx sometimes writes a human diagnostic alongside raw JSON. Preserve
            // it as observed output rather than discarding the only recovery clue.
            return BuildProgressEvent(sequence: sequence, identifier: nil, message: trimmed, isError: false)
        }

        let identifier = object["id"] as? String
        let error = nonemptyString(object["error"])
        let status = nonemptyString(object["status"])
        let detail = nonemptyString(object["detail"])
        let name = nonemptyString(object["name"])
        let stream = nonemptyString(object["stream"])
        let message = error ?? detail ?? name ?? status ?? stream

        guard let message else { return nil }
        return BuildProgressEvent(
            sequence: sequence,
            identifier: identifier,
            message: message.trimmingCharacters(in: .whitespacesAndNewlines),
            isError: error != nil)
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
    }
}

enum BuildRunnerError: LocalizedError, Equatable {
    case dockerCLIMissing
    case buildxPluginMissing
    case invalidContext(String)
    case launchFailed(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .dockerCLIMissing:
            return "This Morbstack installation does not include its bundled Docker client."
        case .buildxPluginMissing:
            return "This Morbstack installation does not include its bundled Buildx plugin."
        case .invalidContext(let detail), .launchFailed(let detail), .failed(let detail):
            return detail
        }
    }
}

/// Starts one Buildx process and converts its real raw-JSON output into build events.
///
/// The runner has no mutable engine state and starts nothing until ``run(_:socketPath:
/// onEvent:)`` is called after the view's explicit confirmation. Cancelling the Swift
/// task terminates the client process; the Engine API defines that closed build client
/// connection as cancellation. A short SIGKILL fallback handles a wedged CLI so the
/// socket cannot remain held open indefinitely.
enum BuildRunner {

    static func isAvailable() -> Bool {
        MorbCliPlugins.sourceDockerCLI() != nil && MorbCliPlugins.sourceBinary(for: .buildx) != nil
    }

    static func run(
        _ request: LocalBuildRequest,
        socketPath: String,
        onEvent: @escaping @Sendable (BuildProgressEvent) -> Void
    ) async throws {
        guard let docker = MorbCliPlugins.sourceDockerCLI() else {
            throw BuildRunnerError.dockerCLIMissing
        }
        guard let buildx = MorbCliPlugins.sourceBinary(for: .buildx) else {
            throw BuildRunnerError.buildxPluginMissing
        }

        let run = BuildProcessRun(
            docker: docker,
            buildx: buildx,
            request: request,
            socketPath: socketPath,
            onEvent: onEvent)
        // A folder picked through SwiftUI's file importer may carry a security-scoped
        // URL when the app is sandboxed. Hold that scope across the child process; on a
        // normal unsandboxed build this simply returns false and does nothing.
        let accessedSecurityScope = request.contextDirectory.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope { request.contextDirectory.stopAccessingSecurityScopedResource() }
        }
        try await withTaskCancellationHandler(
            operation: { try await run.waitForExit() },
            onCancel: { run.cancel() })
    }
}

// MARK: - Process plumbing

/// Owns exactly one child process and its two output pipes. The lock protects the
/// cancellation/termination race: a user can press Cancel while `Process.run()` is
/// still opening the executable, and a late child must be terminated immediately.
private final class BuildProcessRun: @unchecked Sendable {

    private let lock = NSLock()
    private var process: Process?
    private var cancellationRequested = false
    private let docker: URL
    private let buildx: URL
    private let request: LocalBuildRequest
    private let socketPath: String
    private let onEvent: @Sendable (BuildProgressEvent) -> Void
    private let output = BuildOutputCollector()

    init(
        docker: URL,
        buildx: URL,
        request: LocalBuildRequest,
        socketPath: String,
        onEvent: @escaping @Sendable (BuildProgressEvent) -> Void
    ) {
        self.docker = docker
        self.buildx = buildx
        self.request = request
        self.socketPath = socketPath
        self.onEvent = onEvent
    }

    func waitForExit() async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                self.launch(continuation: continuation)
            }
        }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let process = process
        lock.unlock()
        terminate(process)
    }

    private func launch(continuation: CheckedContinuation<Void, Error>) {
        let dockerConfig: URL
        do {
            dockerConfig = try makeEphemeralDockerConfig()
        } catch {
            continuation.resume(throwing: BuildRunnerError.launchFailed(error.localizedDescription))
            return
        }
        defer { try? FileManager.default.removeItem(at: dockerConfig) }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = docker
        process.arguments = request.arguments
        process.currentDirectoryURL = request.contextDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr

        var environment = ProcessInfo.processInfo.environment
        // Never inherit a different Docker context/host from the GUI process. The
        // operation must be aimed at the same engine the Morbstack window observes.
        environment["DOCKER_HOST"] = "unix://\(socketPath)"
        environment.removeValue(forKey: "DOCKER_CONTEXT")
        // Use Docker's documented `cliPluginsExtraDirs` configuration rather than a
        // private environment-variable convention. The temporary config contains only
        // the reviewed bundled Buildx path and is removed after this one build; no
        // ~/.docker configuration, plugin symlink, or credential helper is modified.
        environment["DOCKER_CONFIG"] = dockerConfig.path
        process.environment = environment

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let self else { return }
            self.output.consume(data, source: .stdout, onEvent: self.onEvent)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let self else { return }
            self.output.consume(data, source: .stderr, onEvent: self.onEvent)
        }

        lock.lock()
        self.process = process
        let shouldCancel = cancellationRequested
        lock.unlock()

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            lock.lock()
            self.process = nil
            lock.unlock()
            continuation.resume(throwing: BuildRunnerError.launchFailed(error.localizedDescription))
            return
        }
        // `Process` duplicated each write descriptor into the child. Closing the
        // parent's copies is what allows the reader pipes to reach EOF after Buildx
        // exits; retaining them would make a final `readDataToEndOfFile()` wait forever.
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        lock.lock()
        let cancelledAfterLaunch = cancellationRequested
        lock.unlock()
        if shouldCancel || cancelledAfterLaunch { terminate(process) }

        process.waitUntilExit()
        finishPipes(stdout: stdout, stderr: stderr)

        lock.lock()
        let cancelled = cancellationRequested
        self.process = nil
        lock.unlock()
        if cancelled {
            continuation.resume(throwing: CancellationError())
        } else if process.terminationStatus == 0 {
            continuation.resume()
        } else {
            let detail = output.failureDetail
            continuation.resume(throwing: BuildRunnerError.failed(
                detail.isEmpty ? "Buildx exited with status \(process.terminationStatus)." : detail))
        }
    }

    private func finishPipes(stdout: Pipe, stderr: Pipe) {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        // The readable handlers can be scheduled just after `waitUntilExit` wakes.
        // Drain their final bytes synchronously so the last BuildKit error cannot be
        // lost in that race.
        let stdoutTail = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrTail = stderr.fileHandleForReading.readDataToEndOfFile()
        if !stdoutTail.isEmpty { output.consume(stdoutTail, source: .stdout, onEvent: onEvent) }
        if !stderrTail.isEmpty { output.consume(stderrTail, source: .stderr, onEvent: onEvent) }
        output.finish(onEvent: onEvent)
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
    }

    private func makeEphemeralDockerConfig() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("morbstack-buildx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        do {
            let configuration: [String: Any] = [
                "cliPluginsExtraDirs": [buildx.deletingLastPathComponent().path],
            ]
            let data = try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
            try data.write(
                to: directory.appendingPathComponent("config.json", isDirectory: false),
                options: .atomic)
            return directory
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func terminate(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            guard process.isRunning else { return }
            // If SIGTERM did not stop Buildx, kill only this explicit child. Closing
            // the client is the documented Engine cancellation mechanism; no unrelated
            // build or engine process is targeted.
            _ = Darwin.kill(pid, SIGKILL)
        }
    }
}

private final class BuildOutputCollector: @unchecked Sendable {

    enum Source: Equatable { case stdout, stderr }

    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var nextSequence = 0
    private var failureLines: [String] = []

    func consume(
        _ data: Data,
        source: Source,
        onEvent: (@Sendable (BuildProgressEvent))?
    ) {
        lock.lock()
        defer { lock.unlock() }
        switch source {
        case .stdout:
            stdoutBuffer.append(data)
            emitLines(from: &stdoutBuffer, source: source, onEvent: onEvent)
        case .stderr:
            stderrBuffer.append(data)
            emitLines(from: &stderrBuffer, source: source, onEvent: onEvent)
        }
    }

    func finish(onEvent: @escaping @Sendable (BuildProgressEvent) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        emitRemainder(from: &stdoutBuffer, source: .stdout, onEvent: onEvent)
        emitRemainder(from: &stderrBuffer, source: .stderr, onEvent: onEvent)
    }

    var failureDetail: String {
        lock.lock()
        defer { lock.unlock() }
        return failureLines.joined(separator: "\n")
    }

    private func emitLines(
        from buffer: inout Data,
        source: Source,
        onEvent: (@Sendable (BuildProgressEvent))?
    ) {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[..<newline], as: UTF8.self)
            buffer.removeSubrange(...newline)
            emit(line: line, source: source, onEvent: onEvent)
        }
    }

    private func emitRemainder(
        from buffer: inout Data,
        source: Source,
        onEvent: @escaping @Sendable (BuildProgressEvent) -> Void
    ) {
        guard !buffer.isEmpty else { return }
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        emit(line: line, source: source, onEvent: onEvent)
    }

    private func emit(
        line: String,
        source: Source,
        onEvent: (@Sendable (BuildProgressEvent))?
    ) {
        defer { nextSequence += 1 }
        guard var event = BuildProgressDecoder.event(line: line, sequence: nextSequence) else { return }
        if source == .stderr { event = BuildProgressEvent(
            sequence: event.sequence,
            identifier: event.identifier,
            message: event.message,
            isError: true)
        }
        if event.isError { failureLines.append(event.message) }
        onEvent?(event)
    }
}
