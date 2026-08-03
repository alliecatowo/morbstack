// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The right-hand pane: one container, four tabs.
//
// The inspect document is fetched once here and shared by Overview and Inspect. Doing
// it in the parent rather than in each tab means switching tabs is instantaneous and
// the two views can never show different snapshots of the same container.
//
// The lifecycle actions (Stop / Restart / Pause / Remove) live in a real `.toolbar`
// rather than four hand-styled buttons in the header — grouped with `MorbToolbarGap` so
// the destructive one reads as separate from the lifecycle cluster, per
// `docs/design/COMPONENTS.md` §8. There is deliberately no `.primary` button on this
// screen: Start/Resume gets the same `.floating` emphasis as Stop/Restart, because
// nothing here is *the* reason the screen exists the way Start Engine is on the empty
// state.

import AppKit
import SwiftUI

// MARK: - Tabs

enum TrackBDetailTab: String, CaseIterable, Identifiable {
    case overview, logs, stats, inspect

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .logs: return "Logs"
        case .stats: return "Stats"
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

// MARK: - Detail

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

    /// A store handed in already full, for the Logs tab. See `ContainerLogsTab.init`.
    private let preloadedLogs: TrackBLogStore?

    /// - Parameters:
    ///   - initialTab: which tab to open on. The app always opens on Overview; previews
    ///     and the offscreen screenshot harness need to name a specific one.
    ///   - preloadedInspectJSON: the inspect document, when the caller already has it.
    ///     `loadInspect()` runs from `.task`, which never fires under `ImageRenderer`, so
    ///     without this every offscreen render of Overview and Inspect would be a
    ///     placeholder.
    ///   - preloadedLogs: forwarded to `ContainerLogsTab`.
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

    private var tone: StatusTone {
        StatusTone.forContainer(state: container.state, unhealthy: container.isUnhealthy)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabBody(for: tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.contentBackground)
        .toolbar { toolbarContent }
        .task(id: container.id) { await loadInspect() }
        // A restart rewrites the whole document — new PID, new start time, possibly a
        // new exit code — so the snapshot is refetched rather than left to go stale.
        .onChange(of: container.state) { _, _ in
            Task { await loadInspect() }
        }
        // "View logs of X" from the command palette or the menu bar. The request is
        // consumed so it fires once; the tab is otherwise entirely this view's own.
        .onChange(of: model.logsTabRequest) { _, _ in
            if model.consumeLogsTabRequest(for: container.id) { tab = .logs }
        }
        .onAppear {
            if model.consumeLogsTabRequest(for: container.id) { tab = .logs }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            HStack(spacing: Theme.space3) {
                Text(container.displayName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let project = container.composeProject {
                    MorbChip(project, symbol: "square.3.layers.3d", rank: .brand)
                }
                Spacer(minLength: 0)
            }

            MorbStatusBadge(
                tone: tone,
                detail: "\(container.shortID) · \(statusDetail)")

            if !container.ports.isEmpty {
                HStack(spacing: Theme.space2) {
                    ForEach(container.ports) { port in
                        MorbPortChip(
                            host: port.hostPort.map(String.init) ?? port.label,
                            container: "\(port.containerPort)/\(port.proto)",
                            isOpenable: port.url != nil)
                    }
                }
            }

            tabBar
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.top, Theme.space4)
        .padding(.bottom, Theme.space3)
    }

    private var statusDetail: String {
        container.status.isEmpty ? container.state : container.status
    }

    // MARK: Toolbar

    /// The lifecycle actions, as real toolbar items.
    ///
    /// What used to be here: one `ToolbarItem` containing a `MorbGlassCluster` wrapping
    /// an `HStack` of `.buttonStyle(.glass)` buttons. That is glass on glass — a macOS 26
    /// toolbar already puts its items on a shared Liquid Glass background, so the cluster
    /// was a second sheet of glass sampling the first, which Apple's guidance calls out
    /// as a mistake rather than a preference. It also defeated the toolbar's own
    /// grouping: four buttons welded into one opaque item cannot be regrouped, spaced or
    /// moved to the overflow menu when the window narrows.
    ///
    /// Now it is a `ToolbarItemGroup` of plain buttons. The system supplies the
    /// background, groups them into one capsule because they are all push buttons, and
    /// the `ToolbarSpacer` below breaks the destructive action out into its own capsule
    /// so Remove can never be mistaken for part of the run/stop cluster.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isBusy {
            MorbToolbarStatus(id: "container.busy") {
                ProgressView().controlSize(.small)
            }
        } else {
            ToolbarItemGroup(placement: MorbToolbarGroup.actions) {
                if container.isRunning {
                    Button { onAction(.stop) } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    Button { onAction(.restart) } label: {
                        Label("Restart", systemImage: "arrow.clockwise")
                    }
                    Button { onAction(.pause) } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                } else if container.state == "paused" {
                    Button { onAction(.unpause) } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                } else {
                    Button { onAction(.start) } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                }
            }
        }
        MorbToolbarGap(placement: MorbToolbarGroup.actions)
        ToolbarItem(id: "container.remove", placement: MorbToolbarGroup.actions) {
            Button(role: .destructive) {
                onRequestRemove()
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .help("Remove this container…")
        }
        ToolbarItem(id: "container.more", placement: MorbToolbarGroup.actions) {
            Menu {
                Button("Copy Container ID") { TrackBClipboard.copy(container.id) }
                Button("Copy Image") { TrackBClipboard.copy(container.image) }
                if !inspectJSON.isEmpty {
                    Button("Copy Inspect JSON") { TrackBClipboard.copy(inspectJSON) }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .help("More actions")
        }
    }

    // MARK: Tab bar

    private var tabBar: some View {
        Picker("", selection: $tab) {
            ForEach(TrackBDetailTab.allCases) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 360)
    }

    // MARK: Tab bodies

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
            ContainerStatsTab(container: container, hub: hub, client: model.client)
        case .inspect:
            ContainerInspectTab(json: inspectJSON, isLoading: isLoadingInspect, errorText: inspectError)
        }
    }

    // MARK: Loading

    private func loadInspect() async {
        isLoadingInspect = inspectJSON.isEmpty
        do {
            let json = try await model.client.inspectContainer(id: container.id)
            inspectJSON = json
            details = TrackBInspectDetails(json: json)
            inspectError = details == nil ? "The engine returned something that is not JSON." : nil
        } catch {
            inspectError = TrackBErrorText.short(error)
        }
        isLoadingInspect = false
    }
}
