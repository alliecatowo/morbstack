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

// Presentation for the narrow, Docker-backed named-volume creation command. The
// Engine remains responsible for name validation and duplicate-name semantics; this
// workflow only refuses a blank request and makes the exact request visible before it
// reaches Docker.

import Foundation
import SwiftUI

struct VolumeCreateRequest: Equatable, Sendable {
    let name: String

    init?(name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        self.name = name
    }
}

/// A document-modal form for one local-driver named volume. The dialog deliberately
/// exposes the omission of labels and driver options instead of presenting a generic
/// volume-driver editor with behavior Morbstack cannot validate.
struct VolumeCreateSheet: View {
    @Binding var name: String
    let progressLabel: String?
    let failureMessage: String?
    let create: (VolumeCreateRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var requestForConfirmation: VolumeCreateRequest?

    private var requestedVolume: VolumeCreateRequest? {
        VolumeCreateRequest(name: name)
    }

    private var isCreating: Bool { progressLabel != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("New Volume") {
                    TextField("Name", text: $name)
                        .disabled(isCreating)
                        .accessibilityIdentifier("volumes.createSheet.name")
                        .accessibilityHint("Docker validates the exact name when you create the volume.")

                    Text("Morbstack sends the name to Docker unchanged.")
                        .foregroundStyle(.secondary)
                }

                Section("Create Behavior") {
                    LabeledContent("Driver", value: "local")
                    LabeledContent("Labels", value: "None")
                    LabeledContent("Driver Options", value: "None")

                    Text("Docker makes a named volume available. It does not import or copy files, attach the volume to a container, or replace an existing volume’s contents.")
                        .foregroundStyle(.secondary)
                }

                if let progressLabel {
                    Section("Progress") {
                        ProgressView(progressLabel)
                    }
                }

                if let failureMessage {
                    Section("Couldn’t Create Volume") {
                        Text(failureMessage)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.automatic)
            .navigationTitle("Create Volume")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isCreating)
                        .accessibilityIdentifier("volumes.createSheet.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        requestForConfirmation = requestedVolume
                    }
                    .disabled(requestedVolume == nil || isCreating)
                    .accessibilityIdentifier("volumes.createSheet.create")
                }
            }
        }
        .confirmationDialog(
            "Create \(requestForConfirmation?.name ?? "Volume")?",
            isPresented: Binding(
                get: { requestForConfirmation != nil },
                set: { if !$0 { requestForConfirmation = nil } }
            ),
            presenting: requestForConfirmation
        ) { request in
            Button("Create Volume") {
                requestForConfirmation = nil
                create(request)
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text("Docker makes \(request.name) available with the local driver. If a local volume with this name already exists, Docker returns it unchanged; no data is replaced.")
        }
        .interactiveDismissDisabled(isCreating)
        .frame(minWidth: 460, idealWidth: 520)
    }
}
