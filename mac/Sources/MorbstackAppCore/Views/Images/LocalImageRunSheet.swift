// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// One deliberately bounded way to run an image already in the local Engine.
//
// This is a record-scoped command, not a container builder. Its only configurable
// Docker fields are a name, literal environment declarations, and fixed TCP/UDP
// published ports; all other runtime configuration remains the selected image's own
// Docker configuration and the Engine's defaults.

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
    @State private var environment: [LocalImageEnvironmentEntry] = []
    @State private var publishedPorts: [LocalImagePortMappingEntry] = []
    @State private var requestForConfirmation: LocalImageRunRequest?
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

    private var requestResult: Result<LocalImageRunRequest, LocalImageRunValidation> {
        LocalImageRunRequest.make(
            requestedName: requestedName,
            environment: environment,
            publishedPorts: publishedPorts)
    }

    private var requestedRun: LocalImageRunRequest? {
        guard case .success(let request) = requestResult else { return nil }
        return request
    }

    private var validationMessage: String? {
        guard case .failure(let error) = requestResult else { return nil }
        return error.localizedDescription
    }

    private var isEditingEnabled: Bool {
        guard !state.isWorking else { return false }
        if case .succeeded = state { return false }
        return true
    }

    // The Form's sections are extracted into computed properties below. As one
    // literal expression the body exceeded what the type checker could solve in
    // reasonable time ("unable to type-check this expression"); the split is purely
    // structural — every section keeps its exact content and order.
    var body: some View {
        withRunConfirmationAndEditObservers(
            NavigationStack {
                runForm
                    .navigationTitle("Run Local Image")
                    .toolbar { sheetToolbar }
            }
            .frame(minWidth: 500, idealWidth: 560, minHeight: 460)
            .interactiveDismissDisabled(state.isWorking))
    }

    private var runForm: some View {
        Form {
            imageSection
            containerSection
            environmentSection
            publishedPortsSection
            authoritySection
            if let validationMessage, isEditingEnabled {
                Section("Check the Request") {
                    Text(validationMessage)
                        .foregroundStyle(.secondary)
                }
            }

            stateSection
        }
    }

    @ToolbarContentBuilder
    private var sheetToolbar: some ToolbarContent {
        if !state.isWorking {
            ToolbarItem(placement: .cancellationAction) {
                Button(closeTitle) { dismiss() }
            }
        }
        if isEditingEnabled {
            ToolbarItem(placement: .confirmationAction) {
                Button(runButtonTitle) { requestForConfirmation = requestedRun }
                    .disabled(requestedRun == nil)
            }
        }
    }

    private func withRunConfirmationAndEditObservers(_ view: some View) -> some View {
        view
            .confirmationDialog(
                "Run \(imageLabel)?",
                isPresented: Binding(
                    get: { requestForConfirmation != nil },
                    set: { if !$0 { requestForConfirmation = nil } }
                ),
                // The real overload is confirmationDialog(_:isPresented:titleVisibility:
                // presenting:actions:message:); with the two arguments swapped the call
                // matched no overload, which is what drove the original
                // "unable to type-check in reasonable time" on this body.
                titleVisibility: .visible,
                presenting: requestForConfirmation
            ) { request in
                Button("Run") {
                    requestForConfirmation = nil
                    Task { await run(request) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { request in
                Text(confirmationMessage(for: request))
            }
            .onAppear { nameIsFocused = true }
            .onChange(of: requestedName) { _, _ in clearFailureAfterEdit() }
            .onChange(of: environment) { _, _ in clearFailureAfterEdit() }
            .onChange(of: publishedPorts) { _, _ in clearFailureAfterEdit() }
    }

    // MARK: Form sections (extracted verbatim from `body`; see note there)

    private var imageSection: some View {
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
    }

    private var containerSection: some View {
        Section {
            TextField("Name (Optional)", text: $requestedName)
                .font(.system(.body, design: .monospaced))
                .focused($nameIsFocused)
                .disabled(!isEditingEnabled)
        } header: {
            Text("Container")
        } footer: {
            Text("Leave the name empty to let Docker assign one. Docker validates any name you enter.")
        }
    }

    private var environmentSection: some View {
        Section {
            DisclosureGroup("Environment Variables (\(environment.count))") {
                ForEach(environment.indices, id: \.self) { index in
                    environmentRow(at: index)
                }
                Button("Add Environment Variable", systemImage: "plus") {
                    environment.append(LocalImageEnvironmentEntry())
                }
                .disabled(!isEditingEnabled)
            }
        } header: {
            Text("Environment")
        } footer: {
            Text("Values are sent literally as entered. Morbstack does not read your Mac environment, .env files, keychain, or a secret store.")
        }
    }

    @ViewBuilder
    private func environmentRow(at index: Int) -> some View {
        Text("Environment Variable \(index + 1)")
            .font(.headline)
        TextField("Name", text: $environment[index].name, prompt: Text("LOG_LEVEL"))
            .font(.system(.body, design: .monospaced))
            .disabled(!isEditingEnabled)
            .accessibilityLabel("Environment variable \(index + 1) name")
        TextField("Value", text: $environment[index].value, prompt: Text("debug"))
            .font(.system(.body, design: .monospaced))
            .disabled(!isEditingEnabled)
            .accessibilityLabel("Environment variable \(index + 1) value")
        Button("Remove Environment Variable \(index + 1)", role: .destructive) {
            environment.remove(at: index)
        }
        .disabled(!isEditingEnabled)
    }

    private var publishedPortsSection: some View {
        Section {
            DisclosureGroup("Published Ports (\(publishedPorts.count))") {
                ForEach(publishedPorts.indices, id: \.self) { index in
                    publishedPortRow(at: index)
                }
                Button("Add Published Port", systemImage: "plus") {
                    publishedPorts.append(LocalImagePortMappingEntry())
                }
                .disabled(!isEditingEnabled)
            }
        } header: {
            Text("Published Ports")
        } footer: {
            Text("Each mapping is one fixed TCP or UDP host port. Docker and Morbstack's normal port preflight report current binding conflicts; this form does not create dynamic ports, ranges, or publish-all mappings.")
        }
    }

    @ViewBuilder
    private func publishedPortRow(at index: Int) -> some View {
        Text("Published Port \(index + 1)")
            .font(.headline)
        TextField("Host Port", text: $publishedPorts[index].hostPort, prompt: Text("8080"))
            .font(.system(.body, design: .monospaced))
            .disabled(!isEditingEnabled)
            .accessibilityLabel("Published port \(index + 1) host port")
        TextField("Container Port", text: $publishedPorts[index].containerPort, prompt: Text("80"))
            .font(.system(.body, design: .monospaced))
            .disabled(!isEditingEnabled)
            .accessibilityLabel("Published port \(index + 1) container port")
        Picker("Protocol", selection: $publishedPorts[index].transport) {
            ForEach(LocalImagePortTransport.allCases, id: \.self) { transport in
                Text(transport.displayName).tag(transport)
            }
        }
        .pickerStyle(.menu)
        .disabled(!isEditingEnabled)
        Picker("Exposure", selection: $publishedPorts[index].exposure) {
            ForEach(LocalImagePortExposure.allCases, id: \.self) { exposure in
                Text(exposure.displayName).tag(exposure)
            }
        }
        .pickerStyle(.menu)
        .disabled(!isEditingEnabled)
        Button("Remove Published Port \(index + 1)", role: .destructive) {
            publishedPorts.remove(at: index)
        }
        .disabled(!isEditingEnabled)
    }

    private var authoritySection: some View {
        Section("Authority") {
            Text(
                "Creates and starts one new container from this local image ID. Docker uses the image’s configured entrypoint, command, user, and working directory; literal declarations here may override the image environment.")
            Text(
                "Morbstack does not pull an image or configure bind mounts, custom networking, privilege, capabilities, credentials, secrets, host networking, or arbitrary Docker JSON.")
        }
    }

    private var closeTitle: String {
        switch state {
        case .review: return "Cancel"
        case .working: return "Cancel"
        case .succeeded, .failed: return "Done"
        }
    }

    private var runButtonTitle: String {
        if case .failed = state { return "Try Again" }
        return "Run"
    }

    private func confirmationMessage(for request: LocalImageRunRequest) -> String {
        var message = "This creates and starts one container from the selected local image ID."
        if let name = request.requestedName {
            message += " Docker will be asked to name it \(name)."
        } else {
            message += " Docker will assign its name."
        }
        let environmentCount = request.environment.count
        message += " It will receive \(environmentCount) explicit environment declaration\(environmentCount == 1 ? "" : "s"); none are copied from this Mac."
        if request.publishedPorts.isEmpty {
            message += " It will not publish a host port."
        } else {
            message += " It will publish \(request.publishedPorts.count) fixed host port\(request.publishedPorts.count == 1 ? "" : "s"): \(request.publishedPorts.map(portDescription).joined(separator: ", "))."
        }
        message += " No image will be pulled and no mounts, custom network, privilege, capability, credential, secret, host-networking, or arbitrary Docker configuration will be added."
        return message
    }

    private func portDescription(_ port: LocalImagePublishedPort) -> String {
        "\(port.hostIP):\(port.hostPort) → \(port.containerPort)/\(port.transport.displayName)"
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
    private func run(_ request: LocalImageRunRequest) async {
        guard isEditingEnabled else { return }
        state = .working(.creating)
        do {
            let result = try await model.runLocalImage(
                imageID: image.id,
                request: request,
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

    private func clearFailureAfterEdit() {
        if case .failed = state { state = .review }
    }
}
