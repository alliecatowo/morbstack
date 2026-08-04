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

// Native, selected-network membership commands. Docker owns endpoint, driver, and
// alias validation. This route offers only documented aliases; it never promises a
// static address, gateway priority, driver options, links, or endpoint sysctls.

import SwiftUI

/// A running container that is not already present in the selected network's inspected
/// member map. This small presentation value keeps the chosen Docker identity and the
/// shown name together through the connect review/result flow.
struct NetworkMembershipCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let status: String

    init(_ container: ContainerSummary) {
        id = container.id
        name = container.displayName
        status = container.status.isEmpty ? container.state.capitalized : container.status
    }
}

enum NetworkMembershipCandidates {

    /// The Engine API permits a connect only for local-scoped networks or for a
    /// swarm-scoped network explicitly marked attachable. The inspector supplies both
    /// facts, so the route can avoid presenting an Engine command Docker documents as
    /// unavailable for this record.
    static func canConnect(to network: NetworkInspection) -> Bool {
        network.scope == "local" || (network.scope == "swarm" && network.isAttachable == true)
    }

    static func connectUnavailableReason(for network: NetworkInspection) -> String {
        if network.scope == "swarm" {
            return "Docker allows manual connections to a swarm network only when it is attachable."
        }
        return "Docker allows manual connections only to local networks or attachable swarm networks."
    }

    /// The inspector and contextual menu share this one explanation, so a disabled
    /// connect action never gives a different reason from the one VoiceOver announces.
    static func connectAvailabilityReason(
        for network: NetworkInspection,
        candidates: [NetworkMembershipCandidate]
    ) -> String? {
        guard canConnect(to: network) else {
            return connectUnavailableReason(for: network)
        }
        guard !candidates.isEmpty else {
            return "No running container is available to connect to this network."
        }
        return nil
    }

    /// Docker documents the non-forced disconnect endpoint as unsupported for swarm
    /// networks. Avoid offering a command that can only fail for this selected record.
    static func canDisconnect(from network: NetworkInspection) -> Bool {
        network.scope != "swarm"
    }


    /// Docker documents `network connect` for a running container. A member shown by
    /// the selected network inspection is already connected, even when another list
    /// refresh has not yet caught up, so it cannot be selected again.
    static func connectable(
        containers: [ContainerSummary],
        members: [NetworkInspection.Member]
    ) -> [NetworkMembershipCandidate] {
        let attachedIDs = Set(members.map(\.id))
        return containers
            .filter { $0.isRunning && !attachedIDs.contains($0.id) }
            .map(NetworkMembershipCandidate.init)
            .sorted { lhs, rhs in
                let names = lhs.name.localizedStandardCompare(rhs.name)
                return names == .orderedSame
                    ? lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
                    : names == .orderedAscending
            }
    }

    /// The documented non-forced disconnect path requires a running container. A
    /// stopped member is still displayed by the inspection, but this UI deliberately
    /// does not invent a force-disconnect control.
    static func disconnectable(
        members: [NetworkInspection.Member],
        containers: [ContainerSummary]
    ) -> [NetworkInspection.Member] {
        let runningIDs = Set(containers.filter(\.isRunning).map(\.id))
        return members.filter { runningIDs.contains($0.id) }
    }

    /// Explains why a displayed membership has no non-forced disconnect command. An
    /// empty member list needs no explanation because there is no member to act on.
    static func disconnectUnavailableReason(
        for network: NetworkInspection,
        members: [NetworkInspection.Member],
        containers: [ContainerSummary]
    ) -> String? {
        guard !members.isEmpty else { return nil }
        guard canDisconnect(from: network) else {
            return "Docker does not support disconnecting containers from a swarm-scoped network through this endpoint."
        }
        guard !disconnectable(members: members, containers: containers).isEmpty else {
            return "Docker disconnects running containers. Stopped attached containers remain listed but are not offered for force-disconnect."
        }
        return nil
    }

    /// Docker's API accepts aliases as an array; the system form has one predictable
    /// comma-separated text field. Empty comma segments are not aliases and are left
    /// out, while all non-empty values remain Docker-validated exactly as entered.
    static func aliases(from input: String) -> [String] {
        input
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// One explicit Docker network-connect request. Its target and aliases are preserved
/// for the review/result UI; `DockerClient` encodes only the Engine-supported IDs and
/// aliases in its fixed request body.
struct NetworkConnectRequest: Equatable, Sendable {
    let networkID: String
    let networkName: String
    let containerID: String
    let containerName: String
    let aliases: [String]

    init(network: NetworkInspection, container: NetworkMembershipCandidate, aliasesInput: String) {
        networkID = network.id
        networkName = network.name
        containerID = container.id
        containerName = container.name
        aliases = NetworkMembershipCandidates.aliases(from: aliasesInput)
    }
}

/// One explicit Docker network-disconnect request. `force` is purposefully absent:
/// this route offers only the documented running-container path after confirmation.
struct NetworkDisconnectRequest: Equatable, Sendable {
    let networkID: String
    let networkName: String
    let containerID: String
    let containerName: String

    init(network: NetworkInspection, container: NetworkInspection.Member) {
        networkID = network.id
        networkName = network.name
        containerID = container.id
        containerName = container.name
    }
}

/// The membership endpoint is authoritative for the mutation. A follow-up inspect is
/// a separate read: keep its result separate so a successful Docker change is never
/// misreported as a failed connect/disconnect merely because the refresh was unavailable.
struct NetworkMembershipRefreshResult: Equatable, Sendable {
    let inspectionWasRefreshed: Bool
    let warning: String?
}

/// A document-modal `Form` for one selected network and one eligible running container.
/// It is deliberately not a generic endpoint editor: aliases are the sole optional
/// endpoint field exposed here.
struct NetworkConnectSheet: View {
    let network: NetworkInspection
    let candidates: [NetworkMembershipCandidate]
    let connect: @MainActor (NetworkConnectRequest) async throws -> NetworkMembershipRefreshResult

    @Environment(\.dismiss) private var dismiss
    @State private var selectedCandidateID: String?
    @State private var aliasesInput = ""
    @State private var state: Phase = .editing
    @FocusState private var focusedField: FocusTarget?

    private enum FocusTarget: Hashable {
        case container
        case aliases
    }

    /// Named `Phase`, not `State`: a nested type called `State` shadows SwiftUI's
    /// `@State` inside this type's scope, so every `@State` attribute below it
    /// resolves to the enum and fails with "enum 'State' cannot be used as an
    /// attribute" — which then cascades into unrelated-looking errors in other
    /// files in the module.
    private enum Phase {
        case editing
        case connecting
        case succeeded(NetworkConnectRequest, NetworkMembershipRefreshResult)
        case failed(String)

        var isConnecting: Bool {
            if case .connecting = self { return true }
            return false
        }

        var isSuccessful: Bool {
            if case .succeeded = self { return true }
            return false
        }
    }

    init(
        network: NetworkInspection,
        candidates: [NetworkMembershipCandidate],
        connect: @escaping @MainActor (NetworkConnectRequest) async throws -> NetworkMembershipRefreshResult
    ) {
        self.network = network
        self.candidates = candidates
        self.connect = connect
        _selectedCandidateID = SwiftUI.State(initialValue: candidates.first?.id)
    }

    private var selectedCandidate: NetworkMembershipCandidate? {
        guard let selectedCandidateID else { return nil }
        return candidates.first { $0.id == selectedCandidateID }
    }

    private var isEditingEnabled: Bool {
        !state.isConnecting && !state.isSuccessful
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Network") {
                    LabeledContent("Name") {
                        Text(network.name)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Driver", value: network.driver)
                }

                Section("Container") {
                    Picker("Container", selection: $selectedCandidateID) {
                        ForEach(candidates) { candidate in
                            Text(candidate.name)
                                .tag(Optional(candidate.id))
                        }
                    }
                    .focused($focusedField, equals: .container)
                    .disabled(!isEditingEnabled)
                    .accessibilityHint("Choose a running container to connect to \(network.name).")

                    if let selectedCandidate {
                        LabeledContent("Status", value: selectedCandidate.status)
                        LabeledContent("Container ID") {
                            Text(selectedCandidate.id)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Text("Only running containers that are not already attached are available.")
                        .foregroundStyle(.secondary)
                }

                Section("Network Aliases") {
                    TextField("Aliases (optional)", text: $aliasesInput)
                        .focused($focusedField, equals: .aliases)
                        .disabled(!isEditingEnabled)
                        .accessibilityLabel("Network aliases")
                        .accessibilityHint("Optionally enter comma-separated aliases for the selected container on \(network.name).")
                    Text("Separate aliases with commas. Docker validates each alias for this network.")
                        .foregroundStyle(.secondary)
                }

                switch state {
                case .editing:
                    EmptyView()
                case .connecting:
                    Section {
                        ProgressView("Connecting Container")
                    }
                case .succeeded(let request, let result):
                    Section("Result") {
                        LabeledContent("Container", value: request.containerName)
                        LabeledContent("Network", value: request.networkName)
                        LabeledContent(
                            "Aliases",
                            value: request.aliases.isEmpty ? "None" : request.aliases.joined(separator: ", "))
                        if let warning = result.warning {
                            Text(warning)
                                .foregroundStyle(.secondary)
                        } else if result.inspectionWasRefreshed {
                            Text("Docker connected the container and Morbstack refreshed the network details.")
                                .foregroundStyle(.secondary)
                        }
                    }
                case .failed(let message):
                    Section("Could Not Connect") {
                        Text(message)
                        Button("Try Again") {
                            submit()
                        }
                    }
                }
            }
            .formStyle(.automatic)
            .navigationTitle("Connect Container")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(state.isSuccessful ? "Close" : "Cancel") {
                        dismiss()
                    }
                    .disabled(state.isConnecting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if state.isSuccessful {
                        Button("Done") { dismiss() }
                    } else {
                        Button("Connect") {
                            submit()
                        }
                        .disabled(selectedCandidate == nil || state.isConnecting)
                        .accessibilityLabel("Connect selected container to \(network.name)")
                        .help(
                            selectedCandidate == nil
                                ? "No running container is available to connect to this network"
                                : "Connect \(selectedCandidate!.name) to \(network.name)")
                    }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 400)
        .interactiveDismissDisabled(state.isConnecting)
        .onAppear {
            focusedField = candidates.count > 1 ? .container : .aliases
        }
    }

    private func submit() {
        guard let selectedCandidate, !state.isConnecting else { return }
        let request = NetworkConnectRequest(
            network: network,
            container: selectedCandidate,
            aliasesInput: aliasesInput)
        state = .connecting
        Task {
            do {
                let result = try await connect(request)
                guard !Task.isCancelled else { return }
                state = .succeeded(request, result)
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(MorbErrorMessage.text(for: error))
            }
        }
    }
}
