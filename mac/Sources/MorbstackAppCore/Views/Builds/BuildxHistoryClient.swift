// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// A narrow, read-only wrapper around Buildx's active-builder history.
//
// This is intentionally separate from Docker Engine's `/system/df` cache endpoint.
// The latter cannot identify individual completed builds. Buildx documents
// `history ls --format=json` as the builder-scoped completed-build listing, so this
// client shows only records that command returned and never fabricates them from cache
// layers. It does not invoke Buildx history deletion, export, import, or `open`.

import Darwin
import Foundation
import MorbstackKit

enum BuildxHistoryClientError: LocalizedError {
    case dockerCLIMissing
    case buildxPluginMissing
    case launchFailed(String)
    case timedOut(String)
    case failed(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .dockerCLIMissing:
            return "This Morbstack installation does not include its bundled Docker client."
        case .buildxPluginMissing:
            return "This Morbstack installation does not include its bundled Buildx plugin."
        case .launchFailed(let detail), .timedOut(let detail), .failed(let detail), .decoding(let detail):
            return detail
        }
    }
}

/// Reads completed Buildx records for the active builder through Morbstack's socket.
///
/// `DOCKER_HOST`, `DOCKER_CONFIG`, and `BUILDX_CONFIG` come from
/// ``BuildxClientEnvironment``—the same sealed environment a locally confirmed build
/// uses. That makes the current builder and history state app-owned and prevents this
/// display command from silently querying a person's remote Docker context.
enum BuildxHistoryClient {

    static func list(socketPath: String) async throws -> [BuildxHistoryRecord] {
        guard let docker = MorbCliPlugins.sourceDockerCLI() else {
            throw BuildxHistoryClientError.dockerCLIMissing
        }
        guard let buildx = MorbCliPlugins.sourceBinary(for: MorbCliPlugins.buildx) else {
            throw BuildxHistoryClientError.buildxPluginMissing
        }

        let output = try await BuildxHistoryCommand(
            docker: docker,
            buildx: buildx,
            socketPath: socketPath,
            arguments: ["buildx", "history", "ls", "--format=json", "--no-trunc"])
            .run()
        return try decodeList(output)
    }

    private static func decodeList(_ output: Data) throws -> [BuildxHistoryRecord] {
        guard let document = try? JSONSerialization.jsonObject(with: output),
              let rows = document as? [[String: Any]]
        else {
            throw BuildxHistoryClientError.decoding(
                "Buildx history did not return the documented JSON record list.")
        }

        return rows.compactMap { row in
            guard let id = text(row["ID"]), !id.isEmpty else { return nil }
            return BuildxHistoryRecord(
                id: id,
                name: text(row["Name"]) ?? id,
                status: text(row["Status"]) ?? "Unknown",
                createdAt: text(row["CreatedAt"]).flatMap(parseDate),
                duration: text(row["Duration"]))
        }
    }

    private static func text(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// Runs a single read-only Buildx command without a shell or inherited Docker state.
private final class BuildxHistoryCommand: @unchecked Sendable {

    /// A history read backs a screen refresh, not a build. Keep its failure bounded
    /// when a builder is unhealthy or a plugin becomes unresponsive.
    private static let deadline: TimeInterval = 15

    private let docker: URL
    private let buildx: URL
    private let socketPath: String
    private let arguments: [String]

    init(docker: URL, buildx: URL, socketPath: String, arguments: [String]) {
        self.docker = docker
        self.buildx = buildx
        self.socketPath = socketPath
        self.arguments = arguments
    }

    func run() async throws -> Data {
        let execution = BuildxHistoryExecution()
        return try await withTaskCancellationHandler(
            operation: {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        self.launch(continuation: continuation, execution: execution)
                    }
                }
            },
            onCancel: {
                execution.cancel()
            })
    }

    private func launch(
        continuation: CheckedContinuation<Data, Error>,
        execution: BuildxHistoryExecution
    ) {
        let environment: BuildxClientEnvironment
        do {
            environment = try BuildxClientEnvironment.prepare(buildx: buildx, socketPath: socketPath)
        } catch {
            continuation.resume(throwing: BuildxHistoryClientError.launchFailed(error.localizedDescription))
            return
        }
        defer { environment.cleanUp() }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        defer {
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
        }
        process.executableURL = docker
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = environment.environment

        do {
            guard try execution.launch(process) else {
                continuation.resume(throwing: CancellationError())
                return
            }
        } catch {
            continuation.resume(throwing: BuildxHistoryClientError.launchFailed(error.localizedDescription))
            return
        }

        // `Process` duplicates these descriptors into the child. Closing the parent
        // copies is required for the reader queues to receive EOF after Buildx exits.
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        execution.startDeadline(after: Self.deadline)

        // Drain both pipes concurrently. Waiting before reading can deadlock when a
        // builder reports enough diagnostics to fill stderr's pipe buffer.
        let group = DispatchGroup()
        let output = BuildxHistoryOutput()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            output.set(data, for: .stdout)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            output.set(data, for: .stderr)
            group.leave()
        }
        process.waitUntilExit()
        group.wait()
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()

        let (stdoutData, stderrData) = output.contents()
        let failure = String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        switch execution.finish(process) {
        case .timedOut:
            continuation.resume(throwing: BuildxHistoryClientError.timedOut(
                "Buildx history did not respond within \(Int(Self.deadline)) seconds."))
            return
        case .cancelled:
            continuation.resume(throwing: CancellationError())
            return
        case .finished:
            break
        }

        guard process.terminationStatus == 0 else {
            continuation.resume(throwing: BuildxHistoryClientError.failed(
                failure.isEmpty
                    ? "Buildx history exited with status \(process.terminationStatus)."
                    : failure))
            return
        }
        continuation.resume(returning: stdoutData)
    }
}

/// Owns one history child and protects the launch/cancellation/deadline races. The
/// hard kill is deliberately scoped to this exact Docker client PID; it cannot affect
/// the daemon or another build.
private final class BuildxHistoryExecution: @unchecked Sendable {
    enum Result {
        case finished
        case cancelled
        case timedOut
    }

    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false

    /// Starts only when cancellation has not already been requested. Holding the lock
    /// through `Process.run()` closes the race where a late child could otherwise be
    /// launched just after a cancelled task observed no PID to terminate.
    func launch(_ process: Process) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        try process.run()
        self.process = process
        return true
    }

    func startDeadline(after timeout: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.timeOut()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = process
        lock.unlock()
        terminate(process)
    }

    func finish(_ process: Process) -> Result {
        lock.lock()
        defer { lock.unlock() }
        self.process = nil
        if timedOut { return .timedOut }
        if cancelled { return .cancelled }
        return .finished
    }

    private func timeOut() {
        lock.lock()
        guard let process, process.isRunning else {
            lock.unlock()
            return
        }
        timedOut = true
        lock.unlock()
        terminate(process)
    }

    private func terminate(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            guard process.isRunning else { return }
            _ = Darwin.kill(pid, SIGKILL)
        }
    }
}

private final class BuildxHistoryOutput: @unchecked Sendable {
    enum Stream { case stdout, stderr }

    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func set(_ data: Data, for stream: Stream) {
        lock.lock()
        defer { lock.unlock() }
        switch stream {
        case .stdout: stdout = data
        case .stderr: stderr = data
        }
    }

    func contents() -> (Data, Data) {
        lock.lock()
        defer { lock.unlock() }
        return (stdout, stderr)
    }
}
