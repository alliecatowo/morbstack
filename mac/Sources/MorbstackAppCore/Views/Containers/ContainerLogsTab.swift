// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// One container's transcript. Everything visual — the query bar, find/filter, follow,
// wrap, links, export — lives in `TrackBLogDocumentView`, which the Compose-aggregated
// document shares. What is left here is exactly what makes this document *this*
// container's: which stream to open, when to reopen it, and what "nothing to show"
// means for a container that may not even be running.

import SwiftUI

struct ContainerLogsTab: View {

    let container: ContainerSummary
    let client: DockerClient

    @State private var store: TrackBLogStore

    private let streamsLive: Bool

    init(container: ContainerSummary, client: DockerClient, preloadedStore: TrackBLogStore? = nil) {
        self.container = container
        self.client = client
        self.streamsLive = preloadedStore == nil
        _store = State(initialValue: preloadedStore ?? TrackBLogStore())
    }

    var body: some View {
        TrackBLogDocumentView(
            store: store,
            scope: "containers.logs",
            exportFilename: TrackBLogExport.suggestedFilename(container: container.displayName),
            makeExportDocument: {
                store.exportDocument(
                    containerName: container.displayName,
                    containerID: container.id)
            },
            additionalOptions: { EmptyView() },
            emptyOverlay: { emptyOverlay })
        .onAppear { if streamsLive { start() } }
        .onDisappear { if streamsLive { store.stop() } }
        .onChange(of: container.isRunning) { _, isRunning in
            if streamsLive, isRunning, !store.isStreaming { start() }
        }
    }

    private func start() {
        store.start(client: client, containerID: container.id)
    }

    @ViewBuilder
    private var emptyOverlay: some View {
        if store.isFiltering {
            ContentUnavailableView.search(text: store.query)
        } else if store.isStreaming {
            ProgressView("Loading Logs")
        } else if let errorText = store.errorText {
            ContentUnavailableView {
                Label("Log Stream Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorText)
            }
        } else {
            ContentUnavailableView {
                Label("No Output", systemImage: "text.alignleft")
            } description: {
                Text(container.isRunning
                    ? "This container has not written anything to standard output or standard error yet."
                    : "This container is not running and produced no output.")
            }
        }
    }
}
