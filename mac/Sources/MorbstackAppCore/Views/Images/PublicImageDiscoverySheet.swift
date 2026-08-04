// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The explicit, read-only public-repository discovery task for Images.
//
// This is intentionally a document-modal task, not an extension of the local-image
// table's `.searchable` filter. Local images are an operational inventory; public
// repository results are a small, narrative collection that a person deliberately
// asks Docker Hub to search. Selection reveals factual public metadata and can copy a
// repository name or prepare the separate explicit pull form, but cannot pull or
// contact Docker itself.

import MorbstackKit
import SwiftUI

private enum PublicImageDiscoveryPresentation: Equatable {
    case ready
    case searching(RegistryImageSearchRequest)
    case results(RegistryImageSearchPage)
    case failure(RegistryImageDiscoveryFailure)
}

/// A system sheet for one explicit public Docker Hub discovery request.
///
/// `PublicImageDiscovery` owns URL/credential/response safety. This view owns only
/// transient UI state and ensures a result from an earlier cancelled/replaced request
/// cannot overwrite the current presentation.
struct PublicImageDiscoverySheet: View {
    @Environment(\.dismiss) private var dismiss

    /// The parent owns the pull sheet. Discovery passes only the reported public
    /// repository name back after the person requests the next step; it never asks
    /// Docker to pull from inside this read-only sheet.
    let onPreparePull: (String) -> Void

    @State private var query = ""
    @State private var presentation: PublicImageDiscoveryPresentation = .ready
    @State private var selection: RegistryImageSearchResult.ID?
    @State private var searchTask: Task<Void, Never>?
    @State private var currentRequestID: UUID?
    @FocusState private var searchFieldIsFocused: Bool

    private var isSearching: Bool {
        if case .searching = presentation { return true }
        return false
    }

    private var canSearch: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSearching
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchForm
                Divider()
                resultContent
            }
            .navigationTitle("Explore Public Images")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        cancelSearch(resetPresentation: false)
                        dismiss()
                    }
                    .accessibilityIdentifier("images.discoverySheet.done")
                }
            }
        }
        .frame(minWidth: 720, idealWidth: 840, minHeight: 480, idealHeight: 560)
        .onAppear { searchFieldIsFocused = true }
        .onDisappear { cancelSearch(resetPresentation: false) }
    }

    // MARK: Explicit input and scope disclosure

    private var searchForm: some View {
        Form {
            Section("Docker Hub") {
                TextField(
                    "Search public repositories",
                    text: $query,
                    prompt: Text("alpine"))
                    .focused($searchFieldIsFocused)
                    .disabled(isSearching)
                    .onSubmit { submitSearch() }
                    .accessibilityIdentifier("images.discoverySheet.search")

                if isSearching {
                    Button("Cancel Search", role: .cancel) {
                        cancelSearch(resetPresentation: false)
                    }
                    .accessibilityIdentifier("images.discoverySheet.cancelSearch")
                } else {
                    Button("Search Docker Hub", action: submitSearch)
                        .disabled(!canSearch)
                        .accessibilityIdentifier("images.discoverySheet.submit")
                }
            }

            Section {
                Text(
                    "Search terms are sent to Docker Hub. Morbstack searches public repositories only; it does not pull images or use Docker or registry credentials.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Results as a rich native collection

    @ViewBuilder
    private var resultContent: some View {
        switch presentation {
        case .ready:
            ContentUnavailableView {
                Label("Search Public Images", systemImage: "magnifyingglass")
            } description: {
                Text("Enter a repository name, then explicitly search Docker Hub.")
            }
        case .searching(let request):
            ContentUnavailableView {
                Label("Searching Docker Hub", systemImage: "magnifyingglass")
            } description: {
                Text("Searching public repositories for “\(request.query)”.")
            } actions: {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Searching Docker Hub")
            }
        case .results(let page):
            if page.results.isEmpty {
                ContentUnavailableView.search(text: page.request.query)
            } else {
                resultsSplitView(page)
            }
        case .failure(let failure):
            ContentUnavailableView {
                Label("Couldn’t Search Docker Hub", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure.localizedDescription)
            } actions: {
                Button("Try Again", action: submitSearch)
                    .disabled(!canSearch)
                    .accessibilityIdentifier("images.discoverySheet.submit")
            }
        }
    }

    private func resultsSplitView(_ page: RegistryImageSearchPage) -> some View {
        NavigationSplitView {
            List(page.results, selection: $selection) { result in
                PublicImageDiscoveryResultRow(result: result)
                    .tag(result.id)
                    // Row identity is the engine-facing reference — the repository name
                    // a pull would use — per docs/design/ACCESSIBILITY-IDENTIFIERS.md.
                    .accessibilityIdentifier("images.discoverySheet.row.\(result.repository)")
            }
            .accessibilityLabel("Public Docker Hub repositories")
            .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 420)
        } detail: {
            if let selectedResult = page.results.first(where: { $0.id == selection }) {
                PublicImageDiscoveryResultDetail(
                    result: selectedResult,
                    hasMoreResults: page.hasMoreResults,
                    onPreparePull: requestPull)
            } else {
                ContentUnavailableView {
                    Label("No Repository Selected", systemImage: "magnifyingglass")
                } description: {
                    Text("Select a public repository to view its reported details.")
                }
            }
        }
    }

    // MARK: Search lifecycle

    @MainActor
    private func submitSearch() {
        guard !isSearching else { return }

        let request: RegistryImageSearchRequest
        do {
            request = try RegistryImageSearchRequest(query: query)
        } catch let failure as RegistryImageDiscoveryFailure {
            presentation = .failure(failure)
            selection = nil
            return
        } catch {
            presentation = .failure(.transport(error.localizedDescription))
            selection = nil
            return
        }

        cancelSearch(resetPresentation: false)
        let requestID = UUID()
        currentRequestID = requestID
        presentation = .searching(request)
        selection = nil

        let discovery = PublicImageDiscovery()
        searchTask = Task { @MainActor in
            do {
                let page = try await discovery.search(request)
                guard !Task.isCancelled, currentRequestID == requestID else { return }
                presentation = .results(page)
                selection = page.results.first?.id
            } catch let failure as RegistryImageDiscoveryFailure {
                guard !Task.isCancelled, currentRequestID == requestID else { return }
                presentation = .failure(failure)
            } catch is CancellationError {
                guard currentRequestID == requestID else { return }
                presentation = .failure(.cancelled)
            } catch {
                guard !Task.isCancelled, currentRequestID == requestID else { return }
                presentation = .failure(.transport(error.localizedDescription))
            }
            guard currentRequestID == requestID else { return }
            searchTask = nil
        }
    }

    @MainActor
    private func cancelSearch(resetPresentation: Bool) {
        let wasSearching = isSearching
        searchTask?.cancel()
        searchTask = nil
        currentRequestID = nil
        if wasSearching {
            presentation = resetPresentation ? .ready : .failure(.cancelled)
        }
    }

    private func requestPull(_ repository: String) {
        onPreparePull(repository)
        dismiss()
    }
}

/// A `List` row is intentional here. Remote repository search returns a short
/// description and provider-supplied public context, which is narrative selection
/// data rather than a wide, sortable local operational record.
private struct PublicImageDiscoveryResultRow: View {
    let result: RegistryImageSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(result.repository)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)

            if let summary = result.summary {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if result.isOfficial || result.isAutomated {
                HStack {
                    if result.isOfficial {
                        Label("Official", systemImage: "checkmark.seal")
                    }
                    if result.isAutomated {
                        Label("Automated", systemImage: "gearshape")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows reported public repository details.")
    }
}

/// The selected public result's plain system inspector-style facts. Copy is useful
/// because it prepares an explicit future pull command without invoking one.
private struct PublicImageDiscoveryResultDetail: View {
    let result: RegistryImageSearchResult
    let hasMoreResults: Bool
    let onPreparePull: (String) -> Void

    var body: some View {
        Form {
            Section("Repository") {
                LabeledContent("Name") {
                    Text(result.repository)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                LabeledContent("Official", value: result.isOfficial ? "Yes" : "No")
                LabeledContent("Automated", value: result.isAutomated ? "Yes" : "No")
            }

            if let summary = result.summary {
                Section("Description") {
                    Text(summary)
                        .textSelection(.enabled)
                }
            }

            if result.starCount != nil || result.pullCount != nil {
                Section("Reported by Docker Hub") {
                    if let starCount = result.starCount {
                        LabeledContent("Stars", value: starCount.formatted())
                    }
                    if let pullCount = result.pullCount {
                        LabeledContent("Pulls", value: pullCount.formatted())
                    }
                }
            }

            Section("Next Step") {
                Button("Prepare Pull…", systemImage: "arrow.down.circle") {
                    onPreparePull(result.repository)
                }
                .accessibilityIdentifier("images.discoverySheet.preparePull")
                .accessibilityLabel("Prepare pull of \(result.repository)")
                .help("Open Pull Image with \(result.repository)")
                Button("Copy Repository", systemImage: "doc.on.doc") {
                    MorbPasteboard.copy(result.repository)
                }
                .accessibilityIdentifier("images.discoverySheet.copyRepository")
                Text("Preparing a pull opens Pull Image with this repository. Morbstack does not download it until you choose Pull.")
                    .foregroundStyle(.secondary)
            }

            if hasMoreResults {
                Section("Search") {
                    Text("Docker Hub reported more matches. Refine the search to narrow the public result list.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
