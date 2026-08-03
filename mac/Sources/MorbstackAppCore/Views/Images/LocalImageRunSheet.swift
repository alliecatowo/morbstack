// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// One deliberately bounded way to run an image already in the local Engine.
//
// This is a record-scoped command, not a container builder. The only mutable input is
// an optional container name; all runtime configuration continues to be the selected
// image's own Docker configuration and the Engine's defaults.

import SwiftUI

/// Exposes the selected-image run command to the standard Image menu while the Images
/// route is active. A focused value keeps the menu bar coupled to native selection,
/// rather than inventing a second global image-selection model.
private struct RunLocalImageActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var runLocalImageAction: (() -> Void)? {
        get { self[RunLocalImageActionKey.self] }
        set { self[RunLocalImageActionKey.self] = newValue }
    }
}

/// A native, document-modal review and result sheet for the one selected local image.
struct LocalImageRunSheet: View {

    let image: ImageSummary
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var requestedName = ""
    @State private var showsConfirmation = false
    @State private var state: RunState = .review
    @FocusState private var nameIsFocused: Bool

    private enum RunState {
        case review
        case working(LocalImageRunProgress)
        case succeeded(LocalImageRunResult)
        case failed(message: String, containerID: String?)

        var isWorking: Bool {
            if case .working = self { return true }
            return false
        }
    }

    private var imageLabel: String {
        image.repoTags.first ?? image.shortID
    }

    private var normalizedName: String? {
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Image") {
                    LabeledContent("Selected image") {
                        Text(imageLabel)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    LabeledContent("Image ID") {
                        Text(image.id)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                Section {
                    TextField("Name (Optional)", text: $requestedName)
                        .font(.system(.body, design: .monospaced))
                        .focused($nameIsFocused)
                        .disabled(state.isWorking || !isReviewing)
                } header: {
                    Text("Container")
                } footer: {
                    Text("Leave the name empty to let Docker assign one. Docker validates any name you enter.")
                }

                Section("Authority") {
                    Text(
                        "Creates and starts one new container from this local image ID. Docker uses the image’s configured entrypoint, command, user, working directory, and environment.")
                    Text(
                        "Morbstack does not pull an image or configure ports, bind mounts, custom networking, privilege, environment variables, or secrets.")
                }

                stateSection
            }
            .navigationTitle("Run Local Image")
            .toolbar {
                if !state.isWorking {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(closeTitle) { dismiss() }
                    }
                }
                if isReviewing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Run") { showsConfirmation = true }
                    }
                }
            }
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 390)
        .interactiveDismissDisabled(state.isWorking)
        .confirmationDialog(
            "Run \(imageLabel)?",
            isPresented: $showsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Run") {
                Task { await run() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
        .onAppear { nameIsFocused = true }
    }

    private var isReviewing: Bool {
        if case .review = state { return true }
        return false
    }

    private var closeTitle: String {
        switch state {
        case .review: return "Cancel"
        case .working: return "Cancel"
        case .succeeded, .failed: return "Done"
        }
    }

    private var confirmationMessage: String {
        var message = "This creates and starts one container using the selected local image and its default Docker configuration."
        if let normalizedName {
            message += " Docker will be asked to name it \(normalizedName)."
        }
        message += " No image will be pulled and no host ports, mounts, custom network, privilege, environment variables, or secrets will be configured."
        return message
    }

    @ViewBuilder
    private var stateSection: some View {
        switch state {
        case .review:
            EmptyView()
        case .working(let progress):
            Section {
                ProgressView(progress.title)
                    .controlSize(.small)
                    .accessibilityLabel(progress.title)
                Text("This operation cannot be safely cancelled after Docker receives the create request.")
                    .foregroundStyle(.secondary)
            }
        case .succeeded(let result):
            Section("Result") {
                Label("Container created and started", systemImage: "checkmark.circle")
                LabeledContent("Container ID") {
                    Text(result.containerID)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let name = result.requestedName {
                    LabeledContent("Requested name", value: name)
                }
                Button("Show in Containers") {
                    model.showContainer(id: result.containerID)
                    dismiss()
                }
            }
        case .failed(let message, let containerID):
            Section("Couldn’t Run Image") {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                if let containerID {
                    Button("Show in Containers") {
                        model.showContainer(id: containerID)
                        dismiss()
                    }
                }
            }
        }
    }

    @MainActor
    private func run() async {
        guard isReviewing else { return }
        state = .working(.creating)
        do {
            let result = try await model.runLocalImage(
                imageID: image.id,
                requestedName: normalizedName,
                progress: { state = .working($0) })
            state = .succeeded(result)
        } catch {
            let containerID: String?
            if let runError = error as? LocalImageRunError,
               case let .startNotConfirmed(id, _) = runError {
                containerID = id
            } else {
                containerID = nil
            }
            state = .failed(
                message: MorbErrorMessage.text(for: error),
                containerID: containerID)
        }
    }
}
