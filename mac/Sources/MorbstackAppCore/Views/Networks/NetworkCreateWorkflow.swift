// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Presentation and validation for the one bounded Docker network-create workflow.
// Docker owns name, driver-option, duplicate, and address-pool validation. Morbstack
// owns only a small explicit bridge-network request; it does not imply that it can
// allocate custom IPAM, attach a container, or configure a network plugin.

import Foundation
import SwiftUI

/// The only driver this route offers. Bridge is the documented single-Engine default;
/// drivers installed by a user and swarm-only overlay behavior need their own evidence
/// and are not guessed from a free-text field.
enum NetworkCreateDriver: String, Equatable, Sendable {
    case bridge

    var displayName: String { "Bridge" }
}

/// IPv4 configuration deliberately available through Morbstack's pinned v1.43 API.
/// Docker added `EnableIPv4` to network-create in API v1.48. The app pins its own
/// Engine requests to v1.43, so sending that field would be a false promise. Omitting
/// it preserves Docker's documented default IPv4 allocation behavior.
enum NetworkCreateIPv4Mode: Equatable, Sendable {
    case dockerDefault

    var displayName: String { "Docker default (enabled)" }
}

/// One editable `key=value` entry in labels or bridge-driver options.
struct NetworkCreateKeyValue: Identifiable, Equatable, Sendable {
    let id: UUID
    var key: String
    var value: String

    init(id: UUID = UUID(), key: String = "", value: String = "") {
        self.id = id
        self.key = key
        self.value = value
    }
}

enum NetworkCreateValidation: LocalizedError, Equatable, Sendable {
    case nameRequired
    case labelKeyRequired
    case duplicateLabel(String)
    case optionKeyRequired
    case duplicateOption(String)

    var errorDescription: String? {
        switch self {
        case .nameRequired:
            return "Enter a network name."
        case .labelKeyRequired:
            return "A label value needs a label key."
        case .duplicateLabel(let key):
            return "The label \(key) appears more than once."
        case .optionKeyRequired:
            return "An option value needs an option key."
        case .duplicateOption(let key):
            return "The option \(key) appears more than once."
        }
    }
}

/// A bounded, testable Docker network-create request.
/// `driver` and `ipv4Mode` are modeled explicitly even though they currently have one
/// supported choice. This prevents a later UI from silently inventing IPAM or an
/// arbitrary-driver editor.
struct NetworkCreateRequest: Equatable, Sendable {
    let name: String
    let driver: NetworkCreateDriver
    let ipv4Mode: NetworkCreateIPv4Mode
    let enableIPv6: Bool
    let labels: [String: String]
    let options: [String: String]

    static func make(
        name: String,
        enableIPv6: Bool,
        labels: [NetworkCreateKeyValue],
        options: [NetworkCreateKeyValue]
    ) -> Result<NetworkCreateRequest, NetworkCreateValidation> {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.nameRequired)
        }

        switch normalizedEntries(labels, emptyKey: .labelKeyRequired, duplicate: NetworkCreateValidation.duplicateLabel) {
        case .failure(let error):
            return .failure(error)
        case .success(let normalizedLabels):
            switch normalizedEntries(options, emptyKey: .optionKeyRequired, duplicate: NetworkCreateValidation.duplicateOption) {
            case .failure(let error):
                return .failure(error)
            case .success(let normalizedOptions):
                return .success(
                    NetworkCreateRequest(
                        name: name,
                        driver: .bridge,
                        ipv4Mode: .dockerDefault,
                        enableIPv6: enableIPv6,
                        labels: normalizedLabels,
                        options: normalizedOptions))
            }
        }
    }

    private static func normalizedEntries(
        _ entries: [NetworkCreateKeyValue],
        emptyKey: NetworkCreateValidation,
        duplicate: (String) -> NetworkCreateValidation
    ) -> Result<[String: String], NetworkCreateValidation> {
        var result: [String: String] = [:]
        for entry in entries {
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                // An untouched empty form row has no meaning. A value in that row is
                // materially ambiguous, and must not be dropped silently.
                guard entry.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .failure(emptyKey)
                }
                continue
            }
            guard result[key] == nil else { return .failure(duplicate(key)) }
            result[key] = entry.value
        }
        return .success(result)
    }
}

/// Docker's successful network-create result. An engine warning is preserved as a
/// separate fact rather than conflated with success or fabricated into a local status.
struct NetworkCreateResult: Equatable, Sendable {
    let id: String
    let warning: String?
}

/// A document-modal form for a single local bridge network.
struct NetworkCreateSheet: View {
    let create: @MainActor (NetworkCreateRequest) async throws -> NetworkCreateResult

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var enableIPv6 = false
    @State private var labels: [NetworkCreateKeyValue] = []
    @State private var options: [NetworkCreateKeyValue] = []
    @State private var requestForConfirmation: NetworkCreateRequest?
    @State private var state: CreationState = .editing
    @FocusState private var nameIsFocused: Bool

    private enum CreationState {
        case editing
        case creating
        case succeeded(NetworkCreateResult)
        case failed(String)

        var isCreating: Bool {
            if case .creating = self { return true }
            return false
        }

        var isTerminalSuccess: Bool {
            if case .succeeded = self { return true }
            return false
        }
    }

    private var requestResult: Result<NetworkCreateRequest, NetworkCreateValidation> {
        NetworkCreateRequest.make(
            name: name,
            enableIPv6: enableIPv6,
            labels: labels,
            options: options)
    }

    private var requestedNetwork: NetworkCreateRequest? {
        guard case .success(let request) = requestResult else { return nil }
        return request
    }

    private var validationMessage: String? {
        guard case .failure(let error) = requestResult else { return nil }
        return error.localizedDescription
    }

    private var isEditingEnabled: Bool {
        !state.isCreating && !state.isTerminalSuccess
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Network") {
                    TextField("Name", text: $name, prompt: Text("my-network"))
                        .font(.system(.body, design: .monospaced))
                        .focused($nameIsFocused)
                        .disabled(!isEditingEnabled)
                        .accessibilityLabel("Network name")
                        .accessibilityHint("Docker validates the exact network name when you create it.")

                    LabeledContent("Driver", value: NetworkCreateDriver.bridge.displayName)
                    LabeledContent("IPv4 Addressing", value: NetworkCreateIPv4Mode.dockerDefault.displayName)
                    Toggle("Enable IPv6", isOn: $enableIPv6)
                        .disabled(!isEditingEnabled)

                    Text(
                        "Docker selects a non-overlapping address pool. This form does not configure custom IPAM, subnets, gateways, or address ranges.")
                        .foregroundStyle(.secondary)
                }

                Section("Advanced") {
                    keyValueEditor(
                        title: "Labels",
                        entries: $labels,
                        addLabel: "Add Label",
                        keyPrompt: "Label Key",
                        valuePrompt: "Label Value")
                    keyValueEditor(
                        title: "Bridge Options",
                        entries: $options,
                        addLabel: "Add Bridge Option",
                        keyPrompt: "Option Key",
                        valuePrompt: "Option Value")

                    Text(
                        "Labels and options are sent only as entered to Docker's bridge driver. Docker validates unsupported keys and values.")
                        .foregroundStyle(.secondary)
                }

                if let validationMessage, isEditingEnabled {
                    Section("Check the Request") {
                        Text(validationMessage)
                            .foregroundStyle(.secondary)
                    }
                }

                stateSection
            }
            .navigationTitle("Create Network")
            .toolbar { toolbarContent }
        }
        .confirmationDialog(
            "Create \(requestForConfirmation?.name ?? "Network")?",
            isPresented: Binding(
                get: { requestForConfirmation != nil },
                set: { if !$0 { requestForConfirmation = nil } }
            ),
            presenting: requestForConfirmation
        ) { request in
            Button("Create Network") {
                requestForConfirmation = nil
                Task { await submit(request) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(confirmationMessage(for: request))
        }
        .interactiveDismissDisabled(state.isCreating)
        .frame(minWidth: 500, idealWidth: 560, minHeight: 420)
        .onAppear { nameIsFocused = true }
        .onChange(of: name) { _, _ in clearFailureAfterEdit() }
        .onChange(of: enableIPv6) { _, _ in clearFailureAfterEdit() }
        .onChange(of: labels) { _, _ in clearFailureAfterEdit() }
        .onChange(of: options) { _, _ in clearFailureAfterEdit() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !state.isCreating {
            ToolbarItem(placement: .cancellationAction) {
                Button(state.isTerminalSuccess ? "Done" : "Cancel") { dismiss() }
            }
        }
        if isEditingEnabled {
            ToolbarItem(placement: .confirmationAction) {
                Button(createButtonTitle) {
                    requestForConfirmation = requestedNetwork
                }
                .disabled(requestedNetwork == nil)
                .accessibilityLabel(
                    createButtonTitle == "Create" ? "Review network creation" : "Review network creation again")
                .help("Review the exact network configuration before Docker receives the create request")
            }
        }
    }

    private var createButtonTitle: String {
        if case .failed = state { return "Try Again" }
        return "Create"
    }

    @ViewBuilder
    private var stateSection: some View {
        switch state {
        case .editing:
            EmptyView()
        case .creating:
            Section("Progress") {
                ProgressView("Creating network")
                Text("Docker has received the create request. The request cannot be safely cancelled from this sheet.")
                    .foregroundStyle(.secondary)
            }
        case .succeeded(let result):
            Section("Result") {
                Label("Network Created", systemImage: "checkmark.circle")
                LabeledContent("Network ID") {
                    Text(result.id)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let warning = result.warning, !warning.isEmpty {
                    LabeledContent("Docker Warning") {
                        Text(warning)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Docker created the network. Morbstack requested an inventory refresh; no containers were attached.")
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            Section("Couldn’t Create Network") {
                Text(message)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func keyValueEditor(
        title: String,
        entries: Binding<[NetworkCreateKeyValue]>,
        addLabel: String,
        keyPrompt: String,
        valuePrompt: String
    ) -> some View {
        DisclosureGroup("\(title) (\(entries.wrappedValue.count))") {
            ForEach(entries) { $entry in
                HStack {
                    TextField(keyPrompt, text: $entry.key)
                        .font(.system(.body, design: .monospaced))
                        .disabled(!isEditingEnabled)
                    TextField(valuePrompt, text: $entry.value)
                        .font(.system(.body, design: .monospaced))
                        .disabled(!isEditingEnabled)
                    Button(role: .destructive) {
                        entries.wrappedValue.removeAll { $0.id == entry.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .disabled(!isEditingEnabled)
                    .accessibilityLabel(
                        entry.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "Remove \(title.dropLast())"
                            : "Remove \(title.dropLast()) \(entry.key)")
                    .help("Remove this \(title.dropLast().lowercased()) from the create request")
                }
            }
            Button(addLabel, systemImage: "plus") {
                entries.wrappedValue.append(NetworkCreateKeyValue())
            }
            .disabled(!isEditingEnabled)
        }
    }

    private func confirmationMessage(for request: NetworkCreateRequest) -> String {
        let ipv6 = request.enableIPv6 ? "enabled" : "disabled"
        return "Docker will create \(request.name) using the bridge driver with Docker-default IPv4 addressing and IPv6 \(ipv6). It will receive \(request.labels.count) label\(request.labels.count == 1 ? "" : "s") and \(request.options.count) bridge option\(request.options.count == 1 ? "" : "s"). No custom IPAM is configured and no containers will be attached."
    }

    @MainActor
    private func submit(_ request: NetworkCreateRequest) async {
        guard isEditingEnabled else { return }
        state = .creating
        do {
            state = .succeeded(try await create(request))
        } catch {
            state = .failed(MorbErrorMessage.text(for: error))
        }
    }

    private func clearFailureAfterEdit() {
        if case .failed = state { state = .editing }
    }
}
