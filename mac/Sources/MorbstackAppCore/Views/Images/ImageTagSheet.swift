// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// A focused local image-tagging workflow.

import SwiftUI

/// The exact, bounded Docker request made by the Images route.
///
/// A target reference is deliberately split into its repository and tag fields so the
/// source image's immutable ID cannot be mistaken for the visible alias being created.
/// Docker remains the authority for repository and tag syntax; this value only removes
/// outer whitespace and refuses an empty field before a request can begin.
struct ImageTagRequest: Equatable, Sendable {
    let sourceImageID: String
    let repository: String
    let tag: String

    init?(sourceImageID: String, repository: String, tag: String) {
        let repository = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceImageID.isEmpty, !repository.isEmpty, !tag.isEmpty else { return nil }

        self.sourceImageID = sourceImageID
        self.repository = repository
        self.tag = tag
    }

    var targetReference: String { "\(repository):\(tag)" }
}

/// A document-modal form for creating one additional local tag for a selected image.
/// It does not browse a registry, authenticate, pull, or push; the sole Engine request
/// names the selected immutable image ID and one person-entered target alias.
struct ImageTagSheet: View {

    let image: ImageSummary
    let submit: (ImageTagRequest) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var repository = ""
    @State private var tag = "latest"
    @State private var isTagging = false
    @State private var failure: String?
    @FocusState private var repositoryIsFocused: Bool

    private var request: ImageTagRequest? {
        ImageTagRequest(sourceImageID: image.id, repository: repository, tag: tag)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Image ID") {
                        Text(image.id)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Current Tags", value: currentTagsDescription)
                } header: {
            Text("Source Image")
        } footer: {
                    Text("This immutable ID is the source. Tagging adds a local name; it does not duplicate image layers.")
                }

                Section {
                    TextField("Repository", text: $repository, prompt: Text("registry.example/team/app"))
                        .font(.system(.body, design: .monospaced))
                        .disabled(isTagging)
                        .focused($repositoryIsFocused)
                        .accessibilityIdentifier("images.tagSheet.repository")

                    TextField("Tag", text: $tag, prompt: Text("latest"))
                        .font(.system(.body, design: .monospaced))
                        .disabled(isTagging)
                        .onSubmit { beginTagging() }
                        .accessibilityIdentifier("images.tagSheet.tag")

                    if let request {
                        LabeledContent("Creates") {
                            Text(request.targetReference)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                } header: {
            Text("New Reference")
        } footer: {
                    Text("Docker validates the repository and tag. Morbstack does not pull, push, authenticate, or contact a registry.")
                }

                if isTagging {
                    Section {
                        ProgressView("Creating Local Tag")
                    }
                }

                if let failure {
                    Section("Couldn’t Tag Image") {
                        Text(failure)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .navigationTitle("Tag Image")
            .toolbar {
                // Keep Cancel visible even while tagging, rather than hiding it, so the
                // sheet is never left with zero controls; it is disabled instead of
                // removed because the request is already in flight.
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isTagging)
                        .accessibilityIdentifier("images.tagSheet.cancel")
                }
                if !isTagging {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(failure == nil ? "Tag" : "Try Again") {
                            beginTagging()
                        }
                        .disabled(request == nil)
                        .accessibilityIdentifier("images.tagSheet.confirm")
                    }
                }
            }
        }
        .frame(minWidth: 440, idealWidth: 500, minHeight: 300)
        .interactiveDismissDisabled(isTagging)
        .onAppear { repositoryIsFocused = true }
        .onChange(of: repository) { _, _ in clearFailureIfNeeded() }
        .onChange(of: tag) { _, _ in clearFailureIfNeeded() }
    }

    private var currentTagsDescription: String {
        guard !image.isDangling else { return "No repository tags" }
        return image.repoTags.count == 1 ? "1 tag" : "\(image.repoTags.count) tags"
    }

    private func clearFailureIfNeeded() {
        guard !isTagging, failure != nil else { return }
        failure = nil
    }

    private func beginTagging() {
        guard let request, !isTagging else { return }
        Task { @MainActor in
            isTagging = true
            failure = nil
            defer { isTagging = false }
            do {
                try await submit(request)
                dismiss()
            } catch {
                failure = MorbErrorMessage.text(for: error)
            }
        }
    }
}
