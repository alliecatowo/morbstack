// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// An explicitly reviewed, bounded `docker compose config --quiet` diagnostic for the
// one Compose YAML document the person opened in the source editor. It is not a
// deployment, project loader, environment resolver, or a generic YAML form builder.

import AppKit
import Darwin
import Foundation
import MorbstackKit
import Observation
import SwiftUI

/// The route-level menu action is available only while a saved Compose YAML document
/// has focus. It intentionally has no action for `.env` source files.
struct ComposeSourceValidationCommandActions {
    let validate: () -> Void
    let canValidate: Bool
}

private struct ComposeSourceValidationCommandActionsKey: FocusedValueKey {
    typealias Value = ComposeSourceValidationCommandActions
}

extension FocusedValues {
    var composeSourceValidationCommandActions: ComposeSourceValidationCommandActions? {
        get { self[ComposeSourceValidationCommandActionsKey.self] }
        set { self[ComposeSourceValidationCommandActionsKey.self] = newValue }
    }
}

/// Captures the one on-disk source snapshot a person explicitly reviewed. The
/// executor rechecks this exact byte sequence immediately before it starts the
/// bundled client, so a changed or replaced source is never validated by surprise.
struct ComposeSourceValidationRequest: Sendable {
    let sourceURL: URL
    let expectedData: Data

    var displayName: String { sourceURL.lastPathComponent }
    var snapshotDescription: String { "Saved on-disk snapshot opened in this editor" }

    func verifyCurrentSource() throws {
        try ComposeFileEditor.validateSourceFile(sourceURL, as: .composeYAML)
        let currentData = try ComposeFileEditor.coordinatedRead(sourceURL)
        guard currentData == expectedData else {
            throw ComposeSourceValidationError.sourceChanged
        }
    }
}

private enum ComposeSourceValidationError: LocalizedError {
    case sourceChanged
    case composePluginMissing
    case launchFailed(String)
    case environmentFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceChanged:
            "This Compose YAML file changed on disk after you opened it. Reopen it to review the current version before validating."
        case .composePluginMissing:
            "This Morbstack installation does not include its bundled Compose plugin."
        case .launchFailed(let detail), .environmentFailed(let detail):
            detail
        }
    }
}

struct ComposeSourceValidationOutput: Sendable {
    let text: String
    let isTruncated: Bool
}

enum ComposeSourceValidationResult: Sendable {
    case valid(ComposeSourceValidationOutput)
    case invalid(status: Int32, ComposeSourceValidationOutput)
    case cancelled(ComposeSourceValidationOutput)
    case timedOut(ComposeSourceValidationOutput)

    var title: String {
        switch self {
        case .valid: "Valid"
        case .invalid: "Invalid"
        case .cancelled: "Cancellation Requested"
        case .timedOut: "Timed Out"
        }
    }

    var summary: String {
        switch self {
        case .valid:
            "The bundled Compose client completed its validation command. Nothing was deployed."
        case .invalid(let status, _):
            "Docker Compose exited with status \(status). No deployment was attempted."
        case .cancelled:
            "Morbstack sent a termination request to its bundled Compose client. No deployment was attempted."
        case .timedOut:
            "Morbstack sent a termination request to its bundled Compose client after 15 seconds. No deployment was attempted."
        }
    }

    var output: ComposeSourceValidationOutput {
        switch self {
        case .valid(let output), .invalid(_, let output), .cancelled(let output), .timedOut(let output):
            output
        }
    }
}

/// Owns source-validation presentation state. There is always a separate review before
/// the command starts; cancelling a running command leaves its bounded partial output
/// visible instead of disguising it as a successful validation.
@MainActor
@Observable
final class ComposeSourceValidationModel {
    enum Phase {
        case idle
        case review(ComposeSourceValidationRequest)
        case running(ComposeSourceValidationRequest)
        case result(ComposeSourceValidationRequest, ComposeSourceValidationResult)
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

    var canRequestValidation: Bool {
        if case .idle = phase { return true }
        return false
    }

    func commandActions(
        using editor: ComposeFileEditor,
        isProjectOperationPresented: Bool
    ) -> ComposeSourceValidationCommandActions? {
        guard editor.isPresented, editor.sourceKind == .composeYAML else { return nil }
        return ComposeSourceValidationCommandActions(
            validate: {
                self.requestValidation(
                    using: editor,
                    isProjectOperationPresented: isProjectOperationPresented)
            },
            canValidate: canRequestValidation && !editor.isDirty && !isProjectOperationPresented)
    }

    func requestValidation(
        using editor: ComposeFileEditor,
        isProjectOperationPresented: Bool = false
    ) {
        guard canRequestValidation else { return }
        guard !isProjectOperationPresented else {
            requestError = "Finish the current reviewed Compose project command before validating this document."
            return
        }
        do {
            phase = .review(try editor.validationRequest())
            requestError = nil
        } catch {
            requestError = error.localizedDescription
        }
    }

    func approve() {
        guard case .review(let request) = phase else { return }
        liveDiagnostics = ""
        isCancellationRequested = false
        phase = .running(request)
        let diagnostics = ComposeSourceValidationDiagnosticsRelay { [weak self] chunk in
            self?.append(chunk)
        }
        task = Task { [weak self, diagnostics] in
            let result = await ComposeSourceValidationRunner.run(request) { chunk in
                diagnostics.send(chunk)
            }
            guard let self else { return }
            phase = .result(request, result)
            task = nil
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

/// Bridges a worker's Sendable output callback to the validation model's main-actor
/// state. The immutable closure can only be invoked on the main actor, so the relay
/// has no mutable state shared with the Compose process worker.
private final class ComposeSourceValidationDiagnosticsRelay: Sendable {
    private let append: @MainActor @Sendable (String) -> Void

    init(append: @escaping @MainActor @Sendable (String) -> Void) {
        self.append = append
    }

    func send(_ chunk: String) {
        let handler = append
        Task { @MainActor in
            handler(chunk)
        }
    }
}

/// Runs exactly one bundled Compose `config` command. Docker documents `--quiet` as
/// validation-only; the remaining flags deliberately suppress interpolation, service
/// env-file resolution, and path resolution. `COMPOSE_DISABLE_ENV_FILE=1` prevents a
/// default sibling `.env` from being loaded. Compose includes and other file references
/// remain an explicit trust boundary presented to the person before this runner starts.
enum ComposeSourceValidationRunner {
    private static let deadline: TimeInterval = 15
    private static let maximumDiagnosticBytes = 256 * 1024

    /// One deliberately fixed validation invocation. Keeping this separate from launch
    /// lets focused tests guard against lifecycle, image-resolution, output, or source-
    /// selection flags being added to the saved-document validation command.
    static func arguments(for sourceURL: URL) -> [String] {
        [
            "--project-directory", sourceURL.deletingLastPathComponent().path,
            "-f", sourceURL.path,
            "config",
            "--quiet",
            "--no-interpolate",
            "--no-env-resolution",
            "--no-path-resolution",
        ]
    }

    static func run(
        _ request: ComposeSourceValidationRequest,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> ComposeSourceValidationResult {
        let execution = ComposeSourceValidationExecution()
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
        _ request: ComposeSourceValidationRequest,
        execution: ComposeSourceValidationExecution,
        onOutput: @escaping @Sendable (String) -> Void,
        continuation: CheckedContinuation<ComposeSourceValidationResult, Never>
    ) {
        do {
            try request.verifyCurrentSource()
            guard let compose = MorbCliPlugins.sourceBinary(for: MorbCliPlugins.compose) else {
                throw ComposeSourceValidationError.composePluginMissing
            }
            let environment = try ComposeSourceValidationEnvironment.prepare(
                socketPath: MorbPaths.dockerSocket.path)
            defer { environment.cleanUp() }

            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            let collector = ComposeSourceValidationCollector(limit: maximumDiagnosticBytes)
            // Launch the bundled Compose binary directly. This makes the owned child
            // the actual Compose client rather than a Docker CLI parent that may have
            // launched a plugin child before cancellation reaches it.
            process.executableURL = compose
            process.arguments = arguments(for: request.sourceURL)
            process.currentDirectoryURL = request.sourceURL.deletingLastPathComponent()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdout
            process.standardError = stderr
            process.environment = environment.environment

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                collector.consume(data, fromStandardError: false, onOutput: onOutput)
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                collector.consume(data, fromStandardError: true, onOutput: onOutput)
            }

            do {
                try process.run()
            } catch {
                clearAndClose(stdout: stdout, stderr: stderr)
                throw ComposeSourceValidationError.launchFailed(error.localizedDescription)
            }
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()

            let shouldStop = execution.install(process)
            if shouldStop { execution.stop(process) }
            let deadlineWork = DispatchWorkItem { execution.timeOut() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deadline, execute: deadlineWork)
            process.waitUntilExit()
            deadlineWork.cancel()

            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            collector.consume(stdout.fileHandleForReading.readDataToEndOfFile(), fromStandardError: false, onOutput: onOutput)
            collector.consume(stderr.fileHandleForReading.readDataToEndOfFile(), fromStandardError: true, onOutput: onOutput)
            clearAndClose(stdout: stdout, stderr: stderr)

            let output = collector.result()
            switch execution.finish() {
            case .cancelled:
                continuation.resume(returning: .cancelled(output))
            case .timedOut:
                continuation.resume(returning: .timedOut(output))
            case .finished:
                if process.terminationStatus == 0 {
                    continuation.resume(returning: .valid(output))
                } else {
                    continuation.resume(returning: .invalid(status: process.terminationStatus, output))
                }
            }
        } catch {
            let output = ComposeSourceValidationOutput(text: error.localizedDescription, isTruncated: false)
            onOutput("\(error.localizedDescription)\n")
            switch execution.finish() {
            case .cancelled:
                continuation.resume(returning: .cancelled(output))
            case .timedOut:
                continuation.resume(returning: .timedOut(output))
            case .finished:
                continuation.resume(returning: .invalid(status: -1, output))
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

/// A clean, short-lived client environment. It names Morbstack's socket directly and
/// gives Compose an empty temporary Docker configuration, so this command never
/// inherits a user's Docker context/config/credential helpers, environment files, SSH
/// agent, Git configuration, or proxy credentials. The temporary directory is created
/// only after the person confirms validation and is removed once that client exits.
struct ComposeSourceValidationEnvironment {
    let environment: [String: String]
    private let directory: URL

    static func prepare(socketPath: String) throws -> ComposeSourceValidationEnvironment {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("morbstack-compose-validate-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw ComposeSourceValidationError.environmentFailed(error.localizedDescription)
        }

        return ComposeSourceValidationEnvironment(
            environment: values(socketPath: socketPath, homeDirectoryPath: directory.path),
            directory: directory)
    }

    /// This whitelist intentionally starts empty rather than inheriting the GUI's
    /// environment. Compose receives no ambient Docker endpoint, context, credentials,
    /// default environment file, proxy, Git config, or SSH authentication. Explicit
    /// Compose-file references remain Compose's separate trust boundary; this map does
    /// not represent a filesystem sandbox for those sources.
    static func values(socketPath: String, homeDirectoryPath: String) -> [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": homeDirectoryPath,
            "DOCKER_HOST": "unix://\(socketPath)",
            "DOCKER_CONFIG": homeDirectoryPath,
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
        ]
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class ComposeSourceValidationExecution: @unchecked Sendable {
    enum Completion { case finished, cancelled, timedOut }

    private let lock = NSLock()
    private var process: Process?
    private var cancellationRequested = false
    private var timedOut = false

    func install(_ process: Process) -> Bool {
        lock.lock()
        self.process = process
        let shouldStop = cancellationRequested || timedOut
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

    func timeOut() {
        lock.lock()
        guard !cancellationRequested else {
            lock.unlock()
            return
        }
        let process = process
        guard let process, process.isRunning else {
            lock.unlock()
            return
        }
        timedOut = true
        lock.unlock()
        stop(process)
    }

    func stop(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        let processIdentifier = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if process.isRunning { _ = Darwin.kill(processIdentifier, SIGKILL) }
        }
    }

    func finish() -> Completion {
        lock.lock()
        defer { lock.unlock() }
        process = nil
        if cancellationRequested { return .cancelled }
        if timedOut { return .timedOut }
        return .finished
    }
}

/// Drains both child pipes while retaining a fixed prefix. It deliberately continues
/// reading after the display limit so a malformed source cannot deadlock the client on
/// a full stderr pipe. No diagnostics are written anywhere outside the active sheet.
private final class ComposeSourceValidationCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var wasTruncated = false
    private var emittedTruncationNotice = false

    init(limit: Int) { self.limit = limit }

    func consume(
        _ incoming: Data,
        fromStandardError: Bool,
        onOutput: @escaping @Sendable (String) -> Void
    ) {
        guard !incoming.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        var chunk = fromStandardError ? Data("[stderr] ".utf8) : Data()
        chunk.append(incoming)
        let remaining = max(0, limit - data.count)
        if remaining > 0 {
            let retained = chunk.prefix(remaining)
            data.append(retained)
            onOutput(String(decoding: retained, as: UTF8.self))
        }
        if chunk.count > remaining {
            wasTruncated = true
            if !emittedTruncationNotice {
                emittedTruncationNotice = true
                onOutput("\n[Diagnostics truncated after \(limit / 1024) KiB]\n")
            }
        }
    }

    func result() -> ComposeSourceValidationOutput {
        lock.lock()
        defer { lock.unlock() }
        var text = String(decoding: data, as: UTF8.self)
        if wasTruncated {
            text += "\n[Diagnostics truncated after \(limit / 1024) KiB]"
        }
        return ComposeSourceValidationOutput(text: text, isTruncated: wasTruncated)
    }
}

/// The standard document-modal review and diagnostics flow. It intentionally renders
/// the actual client text in a scrolling monospaced viewport, not a hand-drawn status
/// card or a guessed validation summary.
struct ComposeSourceValidationSheet: View {
    @Bindable var validation: ComposeSourceValidationModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(navigationTitle)
                .toolbar { toolbarContent }
        }
        .frame(minWidth: 620, idealWidth: 820, minHeight: 460, idealHeight: 620)
        .interactiveDismissDisabled(validation.isRunning)
    }

    @ViewBuilder
    private var content: some View {
        switch validation.phase {
        case .idle:
            EmptyView()
        case .review(let request):
            review(request)
        case .running(let request):
            diagnostics(
                request: request,
                title: "Validating \(request.displayName)",
                detail: "The bundled Compose client is checking the saved source. No deploy, build, pull, or provider operation is running.",
                output: validation.liveDiagnostics)
        case .result(let request, let result):
            resultView(request: request, result: result)
        }
    }

    private var navigationTitle: String {
        switch validation.phase {
        case .review: "Validate Compose Document"
        case .running: "Validating Compose Document"
        case .result(_, let result): "Compose Document: \(result.title)"
        case .idle: "Compose Document Validation"
        }
    }

    private func review(_ request: ComposeSourceValidationRequest) -> some View {
        Form {
            Section("Selected Source") {
                LabeledContent("File") {
                    Text(request.sourceURL.path)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                LabeledContent("Snapshot", value: request.snapshotDescription)
                LabeledContent("Before Launch", value: "File type and exact bytes rechecked")
                LabeledContent("Operation", value: "Bundled Compose config --quiet")
                LabeledContent("Context", value: "Morbstack local socket")
            }
            Section("What This Checks") {
                Text("The bundled Docker Compose client parses and checks the saved source. It does not run up, create, deploy, build, pull, resolve image digests, or run a provider.")
            }
            Section("Trust Review") {
                Text("Docker Compose treats Compose files as trusted input. During configuration loading, include, extends, config, and secret file references can load other local or remote sources. Review this project and every referenced source before continuing.")
                Text("Morbstack disables default .env loading, interpolation, service env-file resolution, and path resolution for this command. It uses an isolated temporary Docker configuration and does not use your Docker context, credential helpers, Keychain, Git configuration, SSH agent, or proxy environment.")
                Text("This is not a source-file sandbox: Docker documents that Compose configuration loading can read declared include, extends, config, and secret file references. This view does not request rendered configuration output or a secret viewer; validate untrusted source only after a dedicated security review.")
                Text("Cancel and timeout terminate Morbstack’s direct Compose client only. They do not claim to terminate external helpers Compose might start while resolving a referenced source.")
            }
        }
        .formStyle(.automatic)
    }

    private func resultView(
        request: ComposeSourceValidationRequest,
        result: ComposeSourceValidationResult
    ) -> some View {
        VStack(spacing: 0) {
            Form {
                Section("Validation") {
                    LabeledContent("Source", value: request.displayName)
                    LabeledContent("Snapshot", value: "Saved selected-file snapshot")
                    LabeledContent("Result", value: result.title)
                    if result.output.isTruncated {
                        LabeledContent("Diagnostics", value: "Truncated at 256 KiB")
                    }
                }
            }
            .formStyle(.automatic)
            .frame(maxHeight: result.output.isTruncated ? 122 : 92)
            diagnosticsText(
                title: result.summary,
                output: result.output.text)
        }
    }

    // `request` was referenced in the body but never passed in; the only caller (the
    // `.running(let request)` case above) has it in scope, and the sibling
    // `resultView(request:result:)` follows the same shape, so threading it through
    // as a parameter is the evident intent.
    private func diagnostics(
        request: ComposeSourceValidationRequest,
        title: String,
        detail: String,
        output: String
    ) -> some View {
        VStack(spacing: 0) {
            Form {
                Section("Validation") {
                    LabeledContent("Status") {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(title)
                        }
                    }
                    LabeledContent("Action", value: "config --quiet")
                    LabeledContent("Snapshot", value: request.snapshotDescription)
                }
            }
            .formStyle(.automatic)
            .frame(maxHeight: 92)
            diagnosticsText(title: detail, output: output)
        }
    }

    private func diagnosticsText(title: String, output: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
            ComposeValidationDiagnosticsTextView(
                text: output.isEmpty ? "No diagnostics reported yet." : output)
                .accessibilityLabel("Compose validation diagnostics")
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if case .review = validation.phase {
            ToolbarItem(placement: .cancellationAction) {
                Button { validation.requestDismissal() } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Cancel Compose source validation")
                .help("Cancel validation")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Validate") { validation.approve() }
            }
        } else if case .running = validation.phase {
            ToolbarItem(placement: .cancellationAction) {
                Button(validation.isCancellationRequested ? "Cancelling…" : "Cancel") {
                    validation.cancel()
                }
                .disabled(validation.isCancellationRequested)
            }
        } else if case .result = validation.phase {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { validation.requestDismissal() }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button { validation.retry() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Validate again")
                .help("Review and validate this source again")
            }
        }
    }
}

/// AppKit's noneditable text view gives streamed diagnostics native selection, Find,
/// scrolling, text colors, and VoiceOver behavior. This is a plain system viewport,
/// not a custom terminal or a hand-drawn status surface.
private struct ComposeValidationDiagnosticsTextView: NSViewRepresentable {
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
