// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// An explicitly reviewed Compose project operation for one saved, user-selected
// Compose document. This is intentionally not connected to Compose labels in the
// Stacks browser: a running project's metadata is not authority to deploy from a
// person's filesystem.

import AppKit
import Darwin
import Foundation
import MorbstackKit
import Observation
import SwiftUI

/// The only source-driven Compose commands this document review can run. Their
/// arguments are deliberately explicit so the review sheet can describe the exact
/// Docker Compose behavior rather than implying an all-purpose terminal.
enum ComposeProjectOperation: String, Sendable {
    case build
    case up
    case down

    var reviewTitle: String {
        switch self {
        case .build: "Build Project Images"
        case .up: "Bring Up Project"
        case .down: "Stop and Remove Project"
        }
    }

    var confirmationTitle: String {
        switch self {
        case .build: "Build Images"
        case .up: "Bring Up"
        case .down: "Stop and Remove"
        }
    }

    var commandDescription: String {
        switch self {
        case .build: "docker compose build"
        case .up: "docker compose up --detach --no-build --pull never"
        case .down: "docker compose down"
        }
    }

    var arguments: [String] {
        switch self {
        case .build:
            ["build"]
        case .up:
            ["up", "--detach", "--no-build", "--pull", "never"]
        case .down:
            ["down"]
        }
    }

    var effectDescription: String {
        switch self {
        case .build:
            "Builds the services declared by this saved source. Dockerfile instructions and declared build contexts are executable input; they can read the reviewed project context and make the network requests those instructions explicitly request."
        case .up:
            "Creates or starts the resources declared by this saved source. This command does not build images and does not pull images implicitly."
        case .down:
            "Stops and removes this source's Compose containers and networks. It does not pass --volumes, --rmi, or --remove-orphans, so named volumes, images, and containers outside the declared project are not requested for removal."
        }
    }

    var isDestructive: Bool { self == .down }
}

/// Captures the selected document and its exact parent directory as the project root.
/// The runner repeats both checks immediately before starting the bundled Compose
/// client, so browsing a labelled stack or replacing the opened file cannot turn into
/// a deployment.
struct ComposeProjectOperationRequest: Sendable {
    let operation: ComposeProjectOperation
    let sourceURL: URL
    let projectRootURL: URL
    let expectedData: Data

    init(
        operation: ComposeProjectOperation,
        sourceURL: URL,
        expectedData: Data
    ) throws {
        self.operation = operation
        self.sourceURL = sourceURL
        projectRootURL = sourceURL.deletingLastPathComponent().standardizedFileURL
        self.expectedData = expectedData
        try verifyCurrentSource()
    }

    var displayName: String { sourceURL.lastPathComponent }

    func verifyCurrentSource() throws {
        try ComposeFileEditor.validateSourceFile(sourceURL, as: .composeYAML)
        try Self.verifyProjectRoot(projectRootURL, contains: sourceURL)
        let currentData = try ComposeFileEditor.coordinatedRead(sourceURL)
        guard currentData == expectedData else {
            throw ComposeProjectOperationError.sourceChanged
        }
    }

    private static func verifyProjectRoot(_ root: URL, contains source: URL) throws {
        let expectedRoot = source.deletingLastPathComponent().standardizedFileURL
        guard root.standardizedFileURL.path == expectedRoot.path else {
            throw ComposeProjectOperationError.projectRootChanged
        }

        // Do not let an ancestor symlink change where Compose resolves relative paths
        // between source review and execution. A source under such a path can be opened
        // again through its actual directory and reviewed there.
        guard root.resolvingSymlinksInPath().standardizedFileURL.path == root.standardizedFileURL.path else {
            throw ComposeProjectOperationError.projectRootIsSymbolicLink
        }

        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ComposeProjectOperationError.invalidProjectRoot
        }
    }
}

private enum ComposeProjectOperationError: LocalizedError {
    case sourceChanged
    case projectRootChanged
    case projectRootIsSymbolicLink
    case invalidProjectRoot
    case composePluginMissing
    case environmentFailed(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceChanged:
            "This Compose YAML file changed on disk after you opened it. Reopen it to review the current version before running a project command."
        case .projectRootChanged:
            "The Compose project root no longer matches the selected source file. Reopen the source to review its current location."
        case .projectRootIsSymbolicLink:
            "The selected Compose source is inside a symbolic-link project path. Open the source through its actual directory before running a project command."
        case .invalidProjectRoot:
            "The selected Compose source no longer has a safe project directory. Reopen it to review the current location."
        case .composePluginMissing:
            "This Morbstack installation does not include its bundled Compose plugin."
        case .environmentFailed(let detail), .launchFailed(let detail):
            detail
        }
    }
}

struct ComposeProjectOperationOutput: Sendable {
    let text: String
    let isTruncated: Bool
    let redactionCount: Int
}

enum ComposeProjectOperationResult: Sendable {
    case succeeded(ComposeProjectOperationOutput)
    case failed(status: Int32, ComposeProjectOperationOutput)
    case cancelled(ComposeProjectOperationOutput)

    var title: String {
        switch self {
        case .succeeded: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancellation Requested"
        }
    }

    var output: ComposeProjectOperationOutput {
        switch self {
        case .succeeded(let output), .failed(_, let output), .cancelled(let output):
            output
        }
    }

    func summary(for operation: ComposeProjectOperation) -> String {
        switch self {
        case .succeeded:
            "The bundled Compose client completed \(operation.commandDescription). Refreshing Docker state."
        case .failed(let status, _):
            "Docker Compose exited with status \(status). Docker state is being refreshed because the command may have made partial changes."
        case .cancelled:
            "Morbstack sent a termination request to its direct Compose client. Compose work already accepted by Docker or helper processes may continue, so Docker state is being refreshed."
        }
    }
}

/// Keeps the document-modal confirmation, progress, and result distinct. A completed
/// operation always asks the Stacks route to refresh because Compose can make partial
/// changes even when it returns a nonzero exit status or is cancelled.
@MainActor
@Observable
final class ComposeProjectOperationModel {
    enum Phase {
        case idle
        case review(ComposeProjectOperationRequest)
        case running(ComposeProjectOperationRequest)
        case result(ComposeProjectOperationRequest, ComposeProjectOperationResult)
    }

    var phase: Phase = .idle
    var liveDiagnostics = ""
    var requestError: String?
    private var task: Task<Void, Never>?
    private(set) var isCancellationRequested = false

    var isPresented: Bool {
        if case .idle = phase { return false }
        return true
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var canRequestOperation: Bool {
        if case .idle = phase { return true }
        return false
    }

    func request(_ operation: ComposeProjectOperation, using editor: ComposeFileEditor) {
        guard canRequestOperation else { return }
        do {
            phase = .review(try editor.projectOperationRequest(operation))
            requestError = nil
        } catch {
            requestError = error.localizedDescription
        }
    }

    func approve(refreshStacks: @escaping @MainActor () async -> Void) {
        guard case .review(let request) = phase else { return }
        liveDiagnostics = ""
        isCancellationRequested = false
        phase = .running(request)
        let diagnostics = ComposeProjectOperationDiagnosticsRelay { [weak self] chunk in
            self?.append(chunk)
        }
        task = Task { [weak self, diagnostics] in
            let result = await ComposeProjectOperationRunner.run(request) { chunk in
                diagnostics.send(chunk)
            }
            guard let self else { return }
            phase = .result(request, result)
            task = nil
            // The command task may have been cancelled. Refresh in a new main-actor
            // task so a cancellation result still reconciles Docker state instead of
            // silently skipping that necessary read-back.
            Task { @MainActor in
                await refreshStacks()
            }
        }
    }

    func cancel() {
        guard isRunning else { return }
        isCancellationRequested = true
        task?.cancel()
    }

    func retry() {
        guard case .result(let request, _) = phase else { return }
        liveDiagnostics = ""
        phase = .review(request)
    }

    func requestDismissal() {
        if isRunning {
            cancel()
        } else {
            phase = .idle
            liveDiagnostics = ""
            isCancellationRequested = false
        }
    }

    private func append(_ chunk: String) {
        guard isRunning else { return }
        liveDiagnostics += chunk
    }
}

/// Sends only redacted result text to the main actor. It avoids showing a pipe chunk
/// before the whole retained diagnostic stream can be redacted consistently.
private final class ComposeProjectOperationDiagnosticsRelay: Sendable {
    private let append: @MainActor @Sendable (String) -> Void

    init(append: @escaping @MainActor @Sendable (String) -> Void) {
        self.append = append
    }

    func send(_ chunk: String) {
        let append = append
        Task { @MainActor in
            append(chunk)
        }
    }
}

/// Runs a single direct bundled Compose process. The process owns no general shell,
/// ambient Docker context, credential helper, environment file, Git configuration, or
/// SSH agent. Explicit Compose references remain a trusted-source boundary presented in
/// the review sheet.
enum ComposeProjectOperationRunner {
    private static let maximumDiagnosticBytes = 256 * 1024

    static func run(
        _ request: ComposeProjectOperationRequest,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> ComposeProjectOperationResult {
        let execution = ComposeProjectOperationExecution()
        return await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        launch(request, execution: execution, onOutput: onOutput, continuation: continuation)
                    }
                }
            },
            onCancel: {
                execution.cancel()
            })
    }

    private static func launch(
        _ request: ComposeProjectOperationRequest,
        execution: ComposeProjectOperationExecution,
        onOutput: @escaping @Sendable (String) -> Void,
        continuation: CheckedContinuation<ComposeProjectOperationResult, Never>
    ) {
        do {
            try request.verifyCurrentSource()
            guard let compose = MorbCliPlugins.sourceBinary(for: MorbCliPlugins.compose) else {
                throw ComposeProjectOperationError.composePluginMissing
            }
            let environment = try ComposeProjectOperationEnvironment.prepare(
                socketPath: MorbPaths.dockerSocket.path)
            defer { environment.cleanUp() }

            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            let collector = ComposeProjectOperationCollector(limit: maximumDiagnosticBytes)
            process.executableURL = compose
            process.arguments = [
                "--project-directory", request.projectRootURL.path,
                "-f", request.sourceURL.path,
            ] + request.operation.arguments
            process.currentDirectoryURL = request.projectRootURL
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdout
            process.standardError = stderr
            process.environment = environment.environment

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                collector.consume(data, fromStandardError: false)
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                collector.consume(data, fromStandardError: true)
            }

            do {
                try process.run()
            } catch {
                clearAndClose(stdout: stdout, stderr: stderr)
                throw ComposeProjectOperationError.launchFailed(error.localizedDescription)
            }
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()

            if execution.install(process) {
                execution.stop(process)
            }
            process.waitUntilExit()

            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            collector.consume(stdout.fileHandleForReading.readDataToEndOfFile(), fromStandardError: false)
            collector.consume(stderr.fileHandleForReading.readDataToEndOfFile(), fromStandardError: true)
            clearAndClose(stdout: stdout, stderr: stderr)

            let output = collector.result()
            if !output.text.isEmpty {
                onOutput(output.text)
            }
            switch execution.finish() {
            case .cancelled:
                continuation.resume(returning: .cancelled(output))
            case .finished:
                if process.terminationStatus == 0 {
                    continuation.resume(returning: .succeeded(output))
                } else {
                    continuation.resume(returning: .failed(status: process.terminationStatus, output))
                }
            }
        } catch {
            let redacted = ComposeProjectOperationRedactor.redact(error.localizedDescription)
            let output = ComposeProjectOperationOutput(
                text: redacted.text,
                isTruncated: false,
                redactionCount: redacted.count)
            onOutput("\(redacted.text)\n")
            switch execution.finish() {
            case .cancelled:
                continuation.resume(returning: .cancelled(output))
            case .finished:
                continuation.resume(returning: .failed(status: -1, output))
            }
        }
    }

    private static func clearAndClose(stdout: Pipe, stderr: Pipe) {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
    }
}

/// A blank Docker configuration and small environment prevent the command from reading
/// a host Docker context, credential helpers, default `.env`, proxy, Git config, or SSH
/// configuration. The directory is 0700, exists only after review, and is removed once
/// the owned Compose client exits.
private struct ComposeProjectOperationEnvironment {
    let environment: [String: String]
    private let directory: URL

    static func prepare(socketPath: String) throws -> ComposeProjectOperationEnvironment {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("morbstack-compose-operation-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw ComposeProjectOperationError.environmentFailed(error.localizedDescription)
        }

        return ComposeProjectOperationEnvironment(
            environment: [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": directory.path,
                "DOCKER_HOST": "unix://\(socketPath)",
                "DOCKER_CONFIG": directory.path,
                "COMPOSE_DISABLE_ENV_FILE": "1",
                "COMPOSE_ANSI": "never",
                "COMPOSE_PROGRESS": "plain",
                "COMPOSE_MENU": "0",
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_TERMINAL_PROMPT": "0",
                "GIT_ASKPASS": "/usr/bin/false",
                "SSH_ASKPASS": "/usr/bin/false",
                "GIT_SSH_COMMAND": "/usr/bin/ssh -F /dev/null -oBatchMode=yes -oIdentitiesOnly=yes -oIdentityAgent=none",
            ],
            directory: directory)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Cancellation terminates the direct child then sends SIGKILL after a grace period.
/// It intentionally makes no claim about Docker work already accepted by the daemon or
/// helper processes a trusted Compose source may have started.
private final class ComposeProjectOperationExecution: @unchecked Sendable {
    enum Completion { case finished, cancelled }

    private let lock = NSLock()
    private var process: Process?
    private var cancellationRequested = false

    func install(_ process: Process) -> Bool {
        lock.lock()
        self.process = process
        let shouldStop = cancellationRequested
        lock.unlock()
        return shouldStop
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let process = process
        lock.unlock()
        stop(process)
    }

    func stop(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        let processIdentifier = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if process.isRunning {
                _ = Darwin.kill(processIdentifier, SIGKILL)
            }
        }
    }

    func finish() -> Completion {
        lock.lock()
        defer { lock.unlock() }
        process = nil
        return cancellationRequested ? .cancelled : .finished
    }
}

/// Retains a bounded stream in memory so redaction can inspect complete key/value and
/// URL credentials before text reaches the sheet. It continues draining pipes after the
/// display limit to prevent a verbose client from deadlocking. Nothing writes output to
/// disk, logs, or the pasteboard.
private final class ComposeProjectOperationCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var wasTruncated = false

    init(limit: Int) { self.limit = limit }

    func consume(_ incoming: Data, fromStandardError: Bool) {
        guard !incoming.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        var chunk = fromStandardError ? Data("[stderr] ".utf8) : Data()
        chunk.append(incoming)
        let remaining = max(0, limit - data.count)
        if remaining > 0 {
            data.append(chunk.prefix(remaining))
        }
        if chunk.count > remaining {
            wasTruncated = true
        }
    }

    func result() -> ComposeProjectOperationOutput {
        lock.lock()
        defer { lock.unlock() }
        let redacted = ComposeProjectOperationRedactor.redact(String(decoding: data, as: UTF8.self))
        var text = redacted.text
        if wasTruncated {
            text += "\n[Diagnostics truncated after \(limit / 1024) KiB]"
        }
        return ComposeProjectOperationOutput(
            text: text,
            isTruncated: wasTruncated,
            redactionCount: redacted.count)
    }
}

/// Best-effort presentation redaction for common key/value and URL credential forms.
/// It is deliberately described as a display guard, not a promise to detect every
/// secret a tool might print.
private enum ComposeProjectOperationRedactor {
    struct Result: Sendable {
        let text: String
        let count: Int
    }

    private static let assignment = try! NSRegularExpression(
        pattern: #"(?im)(\b(?:password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|credential|authorization|auth|session|cookie)\b\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#)
    private static let quotedJSONAssignment = try! NSRegularExpression(
        pattern: #"(?im)(\"(?:password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|credential|authorization|auth|session|cookie)\"\s*:\s*)\"[^\"]*\""#)
    private static let URLCredentials = try! NSRegularExpression(
        pattern: #"(?i)(://[^\s:/@]+:)([^@\s/]+)(@)"#)

    static func redact(_ text: String) -> Result {
        var text = text
        var count = 0
        for expression in [assignment, quotedJSONAssignment, URLCredentials] {
            let range = NSRange(text.startIndex..., in: text)
            let matches = expression.numberOfMatches(in: text, range: range)
            guard matches > 0 else { continue }
            let template = expression === URLCredentials ? "$1[redacted]$3" : "$1[redacted]"
            text = expression.stringByReplacingMatches(in: text, range: range, withTemplate: template)
            count += matches
        }
        return Result(text: text, count: count)
    }
}

/// A standard document-modal review sheet. Forms communicate scope and effects, native
/// toolbar actions confirm/cancel, ProgressView reports real work, and the system text
/// view exposes only the redacted result for selection and Find.
struct ComposeProjectOperationSheet: View {
    @Bindable var operations: ComposeProjectOperationModel
    let refreshStacks: @MainActor () async -> Void

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(navigationTitle)
                .toolbar { toolbarContent }
        }
        .frame(minWidth: 640, idealWidth: 820, minHeight: 500, idealHeight: 650)
        .interactiveDismissDisabled(operations.isRunning)
    }

    @ViewBuilder
    private var content: some View {
        switch operations.phase {
        case .idle:
            EmptyView()
        case .review(let request):
            review(request)
        case .running(let request):
            diagnostics(
                request: request,
                title: "Running \(request.operation.commandDescription)",
                detail: operations.isCancellationRequested
                    ? "Morbstack requested termination of its direct Compose client. Docker work already accepted by the daemon may continue."
                    : "Compose output is retained only in this sheet and redacted before it is displayed.",
                output: operations.liveDiagnostics)
        case .result(let request, let result):
            resultView(request: request, result: result)
        }
    }

    private var navigationTitle: String {
        switch operations.phase {
        case .idle: "Compose Project"
        case .review(let request): request.operation.reviewTitle
        case .running(let request): "Running \(request.operation.reviewTitle)"
        case .result(let request, let result): "\(request.operation.reviewTitle): \(result.title)"
        }
    }

    private func review(_ request: ComposeProjectOperationRequest) -> some View {
        Form {
            Section("Selected Source") {
                LabeledContent("File") {
                    Text(request.sourceURL.path)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                LabeledContent("Project Root") {
                    Text(request.projectRootURL.path)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                LabeledContent("Provenance", value: "Saved selected-file snapshot")
                LabeledContent("Command", value: request.operation.commandDescription)
                LabeledContent("Docker Context", value: "Morbstack local socket")
            }
            Section("What Will Happen") {
                Text(request.operation.effectDescription)
            }
            Section("Environment and Secret Sources") {
                LabeledContent("Host Environment", value: "Not inherited")
                LabeledContent("Default .env", value: "Disabled")
                LabeledContent("Keychain Credentials", value: "Not copied or read")
                Text("Declared service env_file entries and file: secret sources remain Compose source references. The bundled Compose client may read them while processing this reviewed project; Morbstack does not open, copy, or display their contents.")
                Text("An environment: secret source requires a host environment variable. This reviewed command has no inherited host variables, so that source is unavailable here. Use a reviewed file: or external: secret source when the project needs unattended source-driven operation.")
            }
            Section("Trust and Cancellation") {
                Text("Compose files and their explicit include, extends, config, secret, build-context, and provider references are trusted input. Review this project and every referenced source before continuing.")
                Text("Morbstack verifies the same saved source bytes and the exact non-symbolic-link project root immediately before launch. It disables ambient Docker contexts, credential helpers, default .env loading, Git configuration, SSH agent, and proxy environment.")
                Text("Cancel terminates Morbstack’s direct Compose client, then force-stops that client if needed. It cannot roll back Docker work already accepted by the daemon or promise to stop external helpers a trusted source may start.")
            }
        }
        .formStyle(.automatic)
    }

    private func resultView(
        request: ComposeProjectOperationRequest,
        result: ComposeProjectOperationResult
    ) -> some View {
        VStack(spacing: 0) {
            Form {
                Section("Project Command") {
                    LabeledContent("Source", value: request.displayName)
                    LabeledContent("Command", value: request.operation.commandDescription)
                    LabeledContent("Result", value: result.title)
                    if result.output.isTruncated {
                        LabeledContent("Diagnostics", value: "Truncated at 256 KiB")
                    }
                    if result.output.redactionCount > 0 {
                        LabeledContent("Display Redactions", value: "\(result.output.redactionCount)")
                    }
                }
            }
            .formStyle(.automatic)
            .frame(maxHeight: result.output.isTruncated || result.output.redactionCount > 0 ? 150 : 118)
            diagnosticsText(
                title: result.summary(for: request.operation),
                output: result.output.text)
        }
    }

    private func diagnostics(
        request: ComposeProjectOperationRequest,
        title: String,
        detail: String,
        output: String
    ) -> some View {
        VStack(spacing: 0) {
            Form {
                Section("Project Command") {
                    LabeledContent("Status") {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(title)
                        }
                    }
                    LabeledContent("Source", value: request.displayName)
                    LabeledContent("Project Root", value: request.projectRootURL.path)
                }
            }
            .formStyle(.automatic)
            .frame(maxHeight: 126)
            diagnosticsText(title: detail, output: output)
        }
    }

    private func diagnosticsText(title: String, output: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
            ComposeProjectOperationDiagnosticsTextView(
                text: output.isEmpty ? "No redacted diagnostics are available yet." : output)
                .accessibilityLabel("Redacted Compose project diagnostics")
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if case .review(let request) = operations.phase {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { operations.requestDismissal() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if request.operation.isDestructive {
                    Button(request.operation.confirmationTitle, role: .destructive) {
                        operations.approve(refreshStacks: refreshStacks)
                    }
                } else {
                    Button(request.operation.confirmationTitle) {
                        operations.approve(refreshStacks: refreshStacks)
                    }
                }
            }
        } else if case .running = operations.phase {
            ToolbarItem(placement: .cancellationAction) {
                Button(operations.isCancellationRequested ? "Cancelling…" : "Cancel") {
                    operations.cancel()
                }
                .disabled(operations.isCancellationRequested)
            }
        } else if case .result = operations.phase {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { operations.requestDismissal() }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button { operations.retry() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Review Compose project command again")
                .help("Review this Compose project command again")
            }
        }
    }
}

/// AppKit's system text view provides selection, Find, scrollbars, Dynamic Type-aware
/// colors, and VoiceOver semantics without creating a custom terminal surface.
private struct ComposeProjectOperationDiagnosticsTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text
        else { return }
        textView.string = text
    }
}
