// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The trailing inspector for the selected container.  The window toolbar owns
// lifecycle commands; this view is deliberately an information inspector, not a
// second hand-built application chrome.

import SwiftUI

enum TrackBDetailTab: String, CaseIterable, Identifiable {
    case overview, logs, files, stats, inspect

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .logs: return "Logs"
        case .files: return "Files"
        case .stats: return "Statistics"
        case .inspect: return "Inspect"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "info.circle"
        case .logs: return "text.alignleft"
        case .files: return "folder"
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
    @State private var filesStore = ContainerFileTreeStore()

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
        // A selected container is an inspector with five peer representations.
        // Apple's own inspectors — Xcode's, measured — put a segmented control at
        // the top of the column and the selected pane below it; they do not use a
        // `TabView`. UI-055 (docs/design/NATIVE-MACOS-PLAYBOOK.md §8) found why: a
        // `TabView` draws a bordered content box, and inside `.inspector` that
        // border overdraws chrome the window already draws — its leading edge
        // overdraws the inspector's own divider from the toolbar's lower edge down.
        // Measured at that seam: `444f51` constant for a `Form` or this `Picker`,
        // `444f51` → `61686b` for a `TabView`, reproduced in stock SwiftUI
        // (`docs/design/probes/ToolProbe.swift`, `inspectorTabView` vs.
        // `inspectorPickerIdentified`) and in this view before this change
        // (`435054` → `646a6c`). No SDK modifier suppresses the box; a segmented
        // `Picker` is the shape Apple's own inspectors already use.
        //
        // The identifiers below stay byte-identical to the `Tab`s they replace.
        // `MorbstackFixtureUITests` queries them via
        // `app.descendants(matching: .any)[identifier]`, which does not care what
        // control produced the element — and a segmented `Picker`'s options do
        // carry their own `AXIdentifier`, verified with the Accessibility API
        // against `inspectorPickerIdentified` (each option surfaces as its own
        // `AXRadioButton` with the identifier attached, the same resolution
        // XCUITest uses), contrary to this file's previous assumption.
        VStack(spacing: 0) {
            Picker("Detail", selection: $tab) {
                ForEach(TrackBDetailTab.allCases) { candidate in
                    Label(candidate.title, systemImage: candidate.symbol)
                        .tag(candidate)
                        .accessibilityIdentifier("containers.detail.tab.\(candidate.rawValue)")
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 8)

            tabBody(for: tab)
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
        case .files:
            // The tree lives with the detail view rather than with the tab, so flipping
            // between tabs does not re-read the container's filesystem — a root listing
            // can be hundreds of megabytes off the socket.
            ContainerFilesTab(container: container, client: model.client, store: filesStore)
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
