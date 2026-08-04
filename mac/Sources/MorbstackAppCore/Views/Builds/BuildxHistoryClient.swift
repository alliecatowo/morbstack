// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// A narrow wrapper around Buildx's active-builder history and one explicitly
// confirmed local-builder recovery command.
//
// This is intentionally separate from Docker Engine's `/system/df` cache endpoint.
// The latter cannot identify individual completed builds. Buildx documents
// `history ls --format=json` as the builder-scoped completed-build listing, so this
// client shows only records that command returned and never fabricates them from cache
// layers. It may inspect one selected record and read that inspected record's raw Buildx
// log after explicit user actions, but it does not invoke history deletion, export,
// import, or `open`.

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

    /// The only builder-selection command Morbstack exposes.
    ///
    /// It deliberately names Buildx's implicit `default` builder and omits both
    /// `--default` and `--global`. With ``BuildxClientEnvironment`` this updates only
    /// Morbstack's private Buildx configuration for its local Unix socket; it neither
    /// reads a shell's builder selection nor creates, starts, removes, or connects a
    /// remote builder. Keep the argument list directly testable so later UI work
    /// cannot quietly broaden this recovery action.
    static let morbstackDefaultBuilderArguments = ["buildx", "use", "default"]

    /// Reads the identity and current node state of the active Buildx builder.
    ///
    /// `buildx inspect` is deliberately invoked without `--bootstrap`: Docker
    /// documents that flag as starting a `docker-container` builder. The Builds route
    /// needs to report the current state, not change it merely because it was opened.
    static func currentBuilder(socketPath: String) async throws -> BuildxCurrentBuilder {
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
            arguments: ["buildx", "inspect", "--timeout=10s"])
            .run()
        guard !output.stdoutWasTruncated else {
            throw BuildxHistoryClientError.decoding(
                "Buildx builder inspection returned more data than Morbstack can safely display.")
        }
        return try decodeCurrentBuilder(output.stdout)
    }

    /// Restores Buildx's implicit local builder for later Morbstack builds.
    ///
    /// This command is never run while opening a view. Its caller must collect an
    /// explicit confirmation and re-read Buildx afterwards. Docker documents
    /// `buildx use` as selecting the builder used by subsequent builds; unlike
    /// `buildx inspect --bootstrap`, it has no builder-start flag.
    static func useMorbstackDefaultBuilder(socketPath: String) async throws {
        guard let docker = MorbCliPlugins.sourceDockerCLI() else {
            throw BuildxHistoryClientError.dockerCLIMissing
        }
        guard let buildx = MorbCliPlugins.sourceBinary(for: MorbCliPlugins.buildx) else {
            throw BuildxHistoryClientError.buildxPluginMissing
        }

        _ = try await BuildxHistoryCommand(
            docker: docker,
            buildx: buildx,
            socketPath: socketPath,
            arguments: morbstackDefaultBuilderArguments)
            .run()
    }

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
        guard !output.stdoutWasTruncated else {
            throw BuildxHistoryClientError.decoding(
                "Buildx history returned more data than Morbstack can safely display.")
        }
        return try decodeList(output.stdout)
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
        guard !output.stdoutWasTruncated else {
            throw BuildxHistoryClientError.decoding(
                "Buildx history detail returned more data than Morbstack can safely display.")
        }
        return try decodeDetail(output.stdout)
    }

    /// Reads raw progress output for one record that the person has already inspected.
    ///
    /// `history logs` is a separate Buildx read. It is deliberately neither coupled to
    /// history selection nor used to fill metadata: a person must first explicitly load
    /// the selected record's details, then choose **Load Logs**. The returned text is the
    /// command's stdout without cache-derived lines or app-authored progress messages.
    static func logs(socketPath: String, recordID: String) async throws -> BuildxHistoryLog {
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
            arguments: ["buildx", "history", "logs", "--progress", "rawjson", recordID])
            .run()
        return BuildxHistoryLog(
            output: String(decoding: output.stdout, as: UTF8.self),
            isTruncated: output.stdoutWasTruncated)
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

    /// `buildx inspect` intentionally has no JSON mode. Docker documents its concise
    /// labeled representation, so parse only those documented labels and leave every
    /// absent field absent rather than deriving state from another Buildx command.
    static func decodeCurrentBuilder(_ output: Data) throws -> BuildxCurrentBuilder {
        let text = String(decoding: output, as: UTF8.self)
        var name: String?
        var driver: String?
        var lastActivity: String?
        var isReadingNodes = false
        var currentNode: BuildxCurrentBuilder.Node?
        var nodes: [BuildxCurrentBuilder.Node] = []

        func finishCurrentNode() {
            guard let currentNode else { return }
            nodes.append(currentNode)
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard let separator = line.firstIndex(of: ":") else { continue }

            let label = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                if label == "Nodes" { isReadingNodes = true }
                continue
            }

            if label == "Nodes" {
                isReadingNodes = true
                continue
            }

            if !isReadingNodes {
                switch label {
                case "Name": name = value
                case "Driver": driver = value
                case "Last Activity": lastActivity = value
                default: break
                }
                continue
            }

            switch label {
            case "Name":
                finishCurrentNode()
                currentNode = BuildxCurrentBuilder.Node(
                    name: value,
                    endpoint: nil,
                    status: nil,
                    buildKitVersion: nil,
                    platforms: nil,
                    error: nil)
            case "Endpoint":
                currentNode?.endpoint = value
            case "Status":
                currentNode?.status = value
            case "BuildKit":
                currentNode?.buildKitVersion = value
            case "Platforms":
                currentNode?.platforms = value
            case "Error":
                currentNode?.error = value
            default:
                break
            }
        }
        finishCurrentNode()

        guard let name else {
            throw BuildxHistoryClientError.decoding(
                "Buildx did not report a current builder name.")
        }
        return BuildxCurrentBuilder(
            name: name,
            driver: driver,
            lastActivity: lastActivity,
            nodes: nodes)
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

/// Raw stdout returned by an explicitly requested `buildx history logs` command.
///
/// The command can produce arbitrary-length output, so the subprocess always drains
/// it but retains at most a documented prefix. `isTruncated` makes that limit visible
/// instead of claiming that the text is a complete build transcript.
struct BuildxHistoryLog: Sendable, Equatable {
    var output: String
    var isTruncated: Bool

    var hasOutput: Bool { !output.isEmpty }
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

    func run() async throws -> BuildxHistoryCommandOutput {
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
        continuation: CheckedContinuation<BuildxHistoryCommandOutput, Error>,
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
            output.drain(stdout.fileHandleForReading, stream: .stdout)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            output.drain(stderr.fileHandleForReading, stream: .stderr)
            group.leave()
        }
        process.waitUntilExit()
        group.wait()
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()

        let commandOutput = output.result()
        var failure = String(decoding: commandOutput.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if commandOutput.stderrWasTruncated {
            failure += failure.isEmpty ? "Output was truncated." : "\nOutput was truncated."
        }

        switch execution.finish(process) {
        case .timedOut:
            continuation.resume(throwing: BuildxHistoryClientError.timedOut(
                "Buildx did not respond within \(Int(Self.deadline)) seconds."))
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
                    ? "Buildx exited with status \(process.terminationStatus)."
                    : failure))
            return
        }
        continuation.resume(returning: commandOutput)
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

private struct BuildxHistoryCommandOutput: Sendable {
    let stdout: Data
    let stderr: Data
    let stdoutWasTruncated: Bool
    let stderrWasTruncated: Bool
}

private final class BuildxHistoryOutput: @unchecked Sendable {
    enum Stream { case stdout, stderr }

    /// Retaining a bounded prefix keeps an unexpectedly verbose builder from making a
    /// read-only inspector command consume unbounded application memory. Both pipes
    /// continue to drain after the cap so the child cannot block on a full descriptor.
    private static let maximumRetainedBytesPerStream = 4 * 1024 * 1024
    private static let readChunkSize = 64 * 1024

    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var stdoutWasTruncated = false
    private var stderrWasTruncated = false

    func drain(_ handle: FileHandle, stream: Stream) {
        while true {
            let data = handle.readData(ofLength: Self.readChunkSize)
            guard !data.isEmpty else { return }
            append(data, for: stream)
        }
    }

    private func append(_ data: Data, for stream: Stream) {
        lock.lock()
        defer { lock.unlock() }
        switch stream {
        case .stdout:
            append(data, to: &stdout, truncated: &stdoutWasTruncated)
        case .stderr:
            append(data, to: &stderr, truncated: &stderrWasTruncated)
        }
    }

    private func append(_ data: Data, to destination: inout Data, truncated: inout Bool) {
        let remaining = Self.maximumRetainedBytesPerStream - destination.count
        guard remaining > 0 else {
            truncated = true
            return
        }
        let retained = data.prefix(remaining)
        destination.append(contentsOf: retained)
        if retained.count < data.count {
            truncated = true
        }
    }

    func result() -> BuildxHistoryCommandOutput {
        lock.lock()
        defer { lock.unlock() }
        return BuildxHistoryCommandOutput(
            stdout: stdout,
            stderr: stderr,
            stdoutWasTruncated: stdoutWasTruncated,
            stderrWasTruncated: stderrWasTruncated)
    }
}
