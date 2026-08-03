// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The trailing inspector for the selected container.  The window toolbar owns
// lifecycle commands; this view is deliberately an information inspector, not a
// second hand-built application chrome.

import SwiftUI

enum TrackBDetailTab: String, CaseIterable, Identifiable {
    case overview, logs, stats, inspect

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .logs: return "Logs"
        case .stats: return "Statistics"
        case .inspect: return "Inspect"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "info.circle"
        case .logs: return "text.alignleft"
        case .stats: return "waveform.path.ecg"
        case .inspect: return "curlybraces"
        }
    }
}

struct ContainerDetailView: View {

    let container: ContainerSummary
    let model: AppModel
    let hub: TrackBStatsHub
    let isBusy: Bool
    let onAction: (ContainerAction) -> Void
    let onRequestRemove: () -> Void

    @State private var tab: TrackBDetailTab
    @State private var inspectJSON: String
    @State private var details: TrackBInspectDetails?
    @State private var inspectError: String?
    @State private var isLoadingInspect = false

    private let preloadedLogs: TrackBLogStore?

    init(
        container: ContainerSummary,
        model: AppModel,
        hub: TrackBStatsHub,
        isBusy: Bool,
        onAction: @escaping (ContainerAction) -> Void,
        onRequestRemove: @escaping () -> Void,
        initialTab: TrackBDetailTab = .overview,
        preloadedInspectJSON: String? = nil,
        preloadedLogs: TrackBLogStore? = nil
    ) {
        self.container = container
        self.model = model
        self.hub = hub
        self.isBusy = isBusy
        self.onAction = onAction
        self.onRequestRemove = onRequestRemove
        self.preloadedLogs = preloadedLogs
        _tab = State(initialValue: initialTab)
        _inspectJSON = State(initialValue: preloadedInspectJSON ?? "")
        _details = State(initialValue: preloadedInspectJSON.flatMap(TrackBInspectDetails.init(json:)))
    }

    var body: some View {
        VStack(spacing: 0) {
            inspectorHeader
            Picker("View", selection: $tab) {
                ForEach(TrackBDetailTab.allCases) { item in
                    Label(item.title, systemImage: item.symbol).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .bottom])

            Divider()

            tabBody(for: tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: container.id) { await loadInspect() }
        .onChange(of: container.state) { _, _ in
            Task { await loadInspect() }
        }
        .onChange(of: model.logsTabRequest) { _, _ in
            if model.consumeLogsTabRequest(for: container.id) { tab = .logs }
        }
        .onAppear {
            if model.consumeLogsTabRequest(for: container.id) { tab = .logs }
        }
    }

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(container.displayName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text(container.status.isEmpty ? container.state.capitalized : container.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(container.image)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    @ViewBuilder
    private func tabBody(for tab: TrackBDetailTab) -> some View {
        switch tab {
        case .overview:
            ContainerOverviewTab(
                container: container,
                details: details,
                isLoading: isLoadingInspect,
                errorText: inspectError,
                fileSharing: model.fileSharing)
        case .logs:
            ContainerLogsTab(container: container, client: model.client, preloadedStore: preloadedLogs)
        case .stats:
            ContainerStatsTab(
                container: container,
                hub: hub,
                client: model.client,
                onStart: { onAction(.start) },
                isActionInProgress: isBusy)
        case .inspect:
            ContainerInspectTab(json: inspectJSON, isLoading: isLoadingInspect, errorText: inspectError)
        }
    }

    private func loadInspect() async {
        isLoadingInspect = inspectJSON.isEmpty
        do {
            let json = try await model.client.inspectContainer(id: container.id)
            inspectJSON = json
            details = TrackBInspectDetails(json: json)
            inspectError = details == nil ? "The engine returned a document that is not JSON." : nil
        } catch {
            inspectError = TrackBErrorText.short(error)
        }
        isLoadingInspect = false
    }
}
