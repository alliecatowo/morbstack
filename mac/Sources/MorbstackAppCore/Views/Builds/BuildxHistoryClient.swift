// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// A narrow, read-only wrapper around Buildx's active-builder history.
//
// This is intentionally separate from Docker Engine's `/system/df` cache endpoint.
// The latter cannot identify individual completed builds. Buildx documents
// `history ls --format=json` as the builder-scoped completed-build listing, so this
// client shows only records that command returned and never fabricates them from cache
// layers. It may inspect one selected record after an explicit user action, but it does
// not invoke Buildx history deletion, export, import, `open`, or logs.

import Darwin
import Foundation
import MorbstackKit

enum BuildxHistoryClientError: LocalizedError {
    case dockerCLIMissing
    case buildxPluginMissing
    case invalidRecordID
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
        case .invalidRecordID:
            return "Buildx reported a record ID that Morbstack cannot safely inspect."
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

    /// Reads the metadata Buildx reports for exactly one previously listed build record.
    ///
    /// Docker documents `buildx history inspect [REF] --format=json` as a read of one
    /// completed build record. The reference is never typed by the person or inferred
    /// from cache state: it must be the bounded ID of the currently selected result from
    /// `history ls`. This client deliberately does not reach the separate `logs`,
    /// `attachment`, `export`, `import`, `open`, or `rm` subcommands.
    static func inspect(socketPath: String, recordID: String) async throws -> BuildxHistoryDetail {
        guard isInspectableRecordID(recordID) else {
            throw BuildxHistoryClientError.invalidRecordID
        }
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
            arguments: ["buildx", "history", "inspect", "--format=json", recordID])
            .run()
        return try decodeDetail(output)
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

    private static func decodeDetail(_ output: Data) throws -> BuildxHistoryDetail {
        guard let document = try? JSONSerialization.jsonObject(with: output),
              let record = document as? [String: Any]
        else {
            throw BuildxHistoryClientError.decoding(
                "Buildx history did not return the documented JSON detail record.")
        }

        let config = record["Config"] as? [String: Any]
        return BuildxHistoryDetail(
            name: text(record["Name"]),
            reference: text(record["Ref"]),
            context: text(record["Context"]),
            dockerfile: text(record["Dockerfile"]),
            vcsRepository: text(record["VCSRepository"]),
            vcsRevision: text(record["VCSRevision"]),
            target: text(record["Target"]),
            platforms: textArray(record["Platform"]),
            keepsGitDirectory: record["KeepGitDir"] as? Bool,
            startedAt: text(record["StartedAt"]),
            completedAt: text(record["CompletedAt"]),
            duration: text(record["Duration"]),
            status: text(record["Status"]),
            completedSteps: text(record["NumCompletedSteps"]),
            totalSteps: text(record["NumTotalSteps"]),
            cachedSteps: text(record["NumCachedSteps"]),
            imageResolveMode: text(config?["ImageResolveMode"]),
            materials: materials(record["Materials"]),
            attachments: attachments(record["Attachments"]))
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

    private static func textArray(_ value: Any?) -> [String] {
        guard let values = value as? [Any] else { return [] }
        return values.compactMap(text)
    }

    private static func materials(_ value: Any?) -> [BuildxHistoryMaterial] {
        guard let values = value as? [[String: Any]] else { return [] }
        return values.enumerated().compactMap { offset, material in
            guard let uri = text(material["URI"]) else { return nil }
            return BuildxHistoryMaterial(
                id: "material-\(offset)",
                uri: uri,
                digests: textArray(material["Digests"]))
        }
    }

    private static func attachments(_ value: Any?) -> [BuildxHistoryAttachment] {
        guard let values = value as? [[String: Any]] else { return [] }
        return values.enumerated().compactMap { offset, attachment in
            guard let digest = text(attachment["Digest"]) else { return nil }
            return BuildxHistoryAttachment(
                id: "attachment-\(offset)",
                digest: digest,
                platform: text(attachment["Platform"]),
                type: text(attachment["Type"]))
        }
    }

    private static func isInspectableRecordID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        let permitted = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return value.unicodeScalars.allSatisfy(permitted.contains)
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// Exact fields returned by `docker buildx history inspect --format=json` that the
/// Builds inspector can render without deriving any state from Docker Engine cache.
/// Optional fields stay absent when the active Buildx version did not return them.
struct BuildxHistoryDetail: Sendable, Equatable {
    var name: String?
    var reference: String?
    var context: String?
    var dockerfile: String?
    var vcsRepository: String?
    var vcsRevision: String?
    var target: String?
    var platforms: [String]
    var keepsGitDirectory: Bool?
    var startedAt: String?
    var completedAt: String?
    var duration: String?
    var status: String?
    var completedSteps: String?
    var totalSteps: String?
    var cachedSteps: String?
    var imageResolveMode: String?
    var materials: [BuildxHistoryMaterial]
    var attachments: [BuildxHistoryAttachment]

    var hasReportableFields: Bool {
        [
            name, reference, context, dockerfile, vcsRepository, vcsRevision, target,
            startedAt, completedAt, duration, status, completedSteps, totalSteps,
            cachedSteps, imageResolveMode,
        ].contains(where: { $0 != nil })
            || !platforms.isEmpty
            || keepsGitDirectory != nil
            || !materials.isEmpty
            || !attachments.isEmpty
    }
}

struct BuildxHistoryMaterial: Identifiable, Sendable, Equatable {
    var id: String
    var uri: String
    var digests: [String]
}

struct BuildxHistoryAttachment: Identifiable, Sendable, Equatable {
    var id: String
    var digest: String
    var platform: String?
    var type: String?
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
