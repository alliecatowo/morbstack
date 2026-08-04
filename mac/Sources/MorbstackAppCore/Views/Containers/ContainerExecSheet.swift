// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

// A bounded command runner for one selected container. This deliberately presents an
// Engine exec as a noninteractive command and result document, not as a decorative
// terminal. Interactive stdin, a TTY, shell parsing, and a generic Docker-request
// editor are separate capabilities that need their own real transport contracts.

import SwiftUI

/// A Docker `Cmd` array constructed without guessing shell quoting. The form presents
/// one executable and one literal argument per text line; a command chain belongs in
/// an explicitly entered shell invocation such as `/bin/sh` with `-c` as its first
/// argument, matching Docker's own exec guidance.
struct ContainerExecCommand: Equatable, Sendable {

    let arguments: [String]

    init?(program: String, argumentLines: String) {
        let executable = program.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !executable.isEmpty,
              !executable.contains("\n"),
              !executable.contains("\r")
        else { return nil }

        let suppliedArguments = argumentLines.isEmpty
            ? []
            : argumentLines.components(separatedBy: .newlines)
        arguments = [executable] + suppliedArguments
    }
}

/// A native document-modal form for a selected container command. Docker receives no
/// stdin and no TTY request. Consequently the result is a finite, selectable output
/// record, never a claim that a person can type into a live shell.
struct ContainerExecSheet: View {

    let container: ContainerSummary
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @FocusState private var programIsFocused: Bool
    @State private var program = ""
    @State private var argumentLines = ""
    @State private var state: ExecutionState = .configuration
    @State private var executionTask: Task<Void, Never>?

    private enum ExecutionState {
        case configuration
        case readingOutput
        case completed(DockerExecResult)
        case failed(String)
        case stoppedReading

        var isExecuting: Bool {
            if case .readingOutput = self { return true }
            return false
        }
    }

    private var currentContainer: ContainerSummary? {
        model.containers.first { $0.id == container.id }
    }

    private var isContainerRunning: Bool {
        currentContainer?.isRunning ?? false
    }

    private var currentStateDescription: String {
        guard let currentContainer else { return "No longer listed" }
        return currentContainer.state.isEmpty ? "Not reported" : currentContainer.state.capitalized
    }

    private var command: ContainerExecCommand? {
        ContainerExecCommand(program: program, argumentLines: argumentLines)
    }

    var body: some View {
        NavigationStack {
            Form {
                targetSection
                availabilitySection
                commandSection
                executionPolicySection
                resultSection
            }
            .formStyle(.automatic)
            .navigationTitle("Run Command")
            .toolbar { toolbarContent }
        }
        .frame(minWidth: 500, idealWidth: 560, minHeight: 430)
        // Escape and a click outside a sheet would otherwise silently close the only
        // socket attachment. The explicit command explains the different Docker
        // consequence before it closes that attachment.
        .interactiveDismissDisabled(state.isExecuting)
        .onAppear { programIsFocused = true }
        .onDisappear { executionTask?.cancel() }
    }

    private var targetSection: some View {
        Section("Container") {
            LabeledContent("Name") {
                monospaced(container.displayName)
            }
            LabeledContent("Container ID") {
                monospaced(container.id)
            }
            LabeledContent("Current State", value: currentStateDescription)
        }
    }

    @ViewBuilder
    private var availabilitySection: some View {
        if !isContainerRunning {
            Section("Unavailable") {
                Label(
                    "Commands can run only while the container is running.",
                    systemImage: "exclamationmark.triangle")
                Text("Start this container, refresh its state, then run the command again.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var commandSection: some View {
        Section {
            TextField("Program", text: $program)
                .font(.system(.body, design: .monospaced))
                .focused($programIsFocused)
                .disabled(state.isExecuting || !isContainerRunning)
                .accessibilityIdentifier("containers.execSheet.program")
                .accessibilityHint("Enter one executable path or program name.")

            TextEditor(text: $argumentLines)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 72)
                .disabled(state.isExecuting || !isContainerRunning)
                .accessibilityIdentifier("containers.execSheet.arguments")
                .accessibilityLabel("Command arguments")
                .accessibilityHint("Enter one literal argument per line. Spaces within a line are passed unchanged.")
        } header: {
            Text("Command")
        } footer: {
            Text("Enter one literal argument per line. Morbstack does not split shell quotes or evaluate command chains. To use a shell, enter it as the program and supply its arguments explicitly.")
        }
    }

    private var executionPolicySection: some View {
        Section("Execution") {
            LabeledContent("Standard Input", value: "Closed")
            LabeledContent("Terminal", value: "Not allocated")
            Text("Docker attaches standard output and standard error separately. This is a finite command result, not an interactive shell.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        switch state {
        case .configuration:
            EmptyView()
        case .readingOutput:
            Section("Command") {
                ProgressView("Reading command output…")
                    .accessibilityLabel("Reading command output")
                Text("Stop Reading Output closes Morbstack’s attachment. Docker may continue the command after that connection closes.")
                    .foregroundStyle(.secondary)
            }
        case .completed(let result):
            Section("Result") {
                LabeledContent("Exit Status", value: result.exitStatusDescription)
                if result.exitCode == nil {
                    Text("Docker did not report an exit status after the output connection closed.")
                        .foregroundStyle(.secondary)
                }
            }
            outputSection(
                title: "Standard Output",
                output: result.standardOutput,
                wasTruncated: result.standardOutputWasTruncated)
            outputSection(
                title: "Standard Error",
                output: result.standardError,
                wasTruncated: result.standardErrorWasTruncated)
        case .failed(let message):
            Section("Couldn’t Run Command") {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Docker may have accepted the command before this connection failed. Refresh the container before assuming its process state.")
                    .foregroundStyle(.secondary)
            }
        case .stoppedReading:
            Section("Output Reading Stopped") {
                Text("Morbstack closed its output attachment. Docker may continue the command; no command completion or exit status was recorded.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func outputSection(title: String, output: String, wasTruncated: Bool) -> some View {
        Section(title) {
            if output.isEmpty {
                Text("Docker returned no \(title.lowercased()).")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.vertical) {
                    Text(output)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 72, maxHeight: 180)
            }
            if wasTruncated {
                Text("Only the first 2 MB of this stream is retained. Docker output beyond that limit is not shown.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if state.isExecuting {
            // `.destructiveAction`, not `.cancellationAction`: Escape resolves to whatever
            // sits in the cancellation slot, and stopping a live output read is a real,
            // named consequence that must never happen silently from a keypress.
            ToolbarItem(placement: .destructiveAction) {
                Button("Stop Reading Output") { stopReadingOutput() }
                    .accessibilityIdentifier("containers.execSheet.stopReading")
            }
        } else {
            ToolbarItem(placement: .cancellationAction) {
                // One identifier across the Cancel/Done title swap: the identifier
                // names the role; the visible title carries the state.
                Button(closeTitle) { dismiss() }
                    .accessibilityIdentifier("containers.execSheet.close")
            }
        }
        if !state.isExecuting {
            ToolbarItem(placement: .confirmationAction) {
                Button("Run Command") { runCommand() }
                    .accessibilityIdentifier("containers.execSheet.run")
                    .disabled(command == nil || !isContainerRunning)
            }
        }
    }

    private var closeTitle: String {
        switch state {
        case .configuration: return "Cancel"
        case .readingOutput: return "Stop Reading Output"
        case .completed, .failed, .stoppedReading: return "Done"
        }
    }

    private func monospaced(_ value: String) -> some View {
        Text(value)
            .font(.system(.body, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(value)
    }

    @MainActor
    private func runCommand() {
        guard !state.isExecuting,
              isContainerRunning,
              let command
        else { return }

        state = .readingOutput
        let containerID = container.id
        let client = model.client
        executionTask = Task { @MainActor in
            do {
                let result = try await client.executeContainerCommand(id: containerID, command: command.arguments)
                guard !Task.isCancelled else { return }
                state = .completed(result)
            } catch is CancellationError {
                // `stopReadingOutput()` names the Engine boundary before cancelling.
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(MorbErrorMessage.text(for: error))
            }
            executionTask = nil
        }
    }

    @MainActor
    private func stopReadingOutput() {
        guard state.isExecuting else { return }
        executionTask?.cancel()
        executionTask = nil
        state = .stoppedReading
    }
}
