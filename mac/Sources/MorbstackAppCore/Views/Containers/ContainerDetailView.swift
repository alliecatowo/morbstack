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
        initialTab: TrackBDetailTab = .overview,
        preloadedInspectJSON: String? = nil,
        preloadedLogs: TrackBLogStore? = nil
    ) {
        self.container = container
        self.model = model
        self.hub = hub
        self.preloadedLogs = preloadedLogs
        _tab = State(initialValue: initialTab)
        _inspectJSON = State(initialValue: preloadedInspectJSON ?? "")
        _details = State(initialValue: preloadedInspectJSON.flatMap(TrackBInspectDetails.init(json:)))
    }

    var body: some View {
        // A selected container is an inspector with four peer representations, not a
        // custom-header detail page. `TabView` supplies the macOS tab behavior,
        // keyboard focus, accessibility, and Tahoe appearance for that choice.
        TabView(selection: $tab) {
            Tab(
                TrackBDetailTab.overview.title,
                systemImage: TrackBDetailTab.overview.symbol,
                value: .overview)
            {
                tabBody(for: .overview)
            }
            // Identifies the tab picker's own button, per rule 4 of
            // docs/design/ACCESSIBILITY-IDENTIFIERS.md, not the pane it displays.
            .accessibilityIdentifier("containers.detail.tab.overview")

            Tab(
                TrackBDetailTab.logs.title,
                systemImage: TrackBDetailTab.logs.symbol,
                value: .logs)
            {
                tabBody(for: .logs)
            }
            .accessibilityIdentifier("containers.detail.tab.logs")

            Tab(
                TrackBDetailTab.stats.title,
                systemImage: TrackBDetailTab.stats.symbol,
                value: .stats)
            {
                tabBody(for: .stats)
            }
            .accessibilityIdentifier("containers.detail.tab.stats")

            Tab(
                TrackBDetailTab.inspect.title,
                systemImage: TrackBDetailTab.inspect.symbol,
                value: .inspect)
            {
                tabBody(for: .inspect)
            }
            .accessibilityIdentifier("containers.detail.tab.inspect")
        }
        // Container state changes require a fresh inspect document.  Giving the task a
        // state-aware identity lets SwiftUI cancel the superseded read rather than
        // allowing an older response to overwrite the current inspector.
        .task(id: "\(container.id):\(container.state)") { await loadInspect() }
        .onChange(of: model.logsTabRequest) { _, _ in
            if model.consumeLogsTabRequest(for: container.id) { tab = .logs }
        }
        .onAppear {
            if model.consumeLogsTabRequest(for: container.id) { tab = .logs }
        }
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
                fileSharing: model.fileSharing,
                onRetry: {
                    Task { await loadInspect() }
                })
        case .logs:
            ContainerLogsTab(container: container, client: model.client, preloadedStore: preloadedLogs)
        case .stats:
            ContainerStatsTab(
                container: container,
                hub: hub,
                client: model.client)
        case .inspect:
            ContainerInspectTab(json: inspectJSON, isLoading: isLoadingInspect, errorText: inspectError)
        }
    }

    private func loadInspect() async {
        isLoadingInspect = true
        inspectError = nil
        do {
            let json = try await model.client.inspectContainer(id: container.id)
            guard !Task.isCancelled else { return }
            inspectJSON = json
            details = TrackBInspectDetails(json: json)
            inspectError = details == nil ? "The engine's response was not valid JSON." : nil
        } catch {
            guard !Task.isCancelled else { return }
            // A previously loaded document describes an earlier engine state.  Do not
            // leave it visible as though this refresh had succeeded.
            inspectJSON = ""
            details = nil
            inspectError = TrackBErrorText.short(error)
        }
        guard !Task.isCancelled else { return }
        isLoadingInspect = false
    }
}
