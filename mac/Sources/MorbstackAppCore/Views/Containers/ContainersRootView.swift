// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The Containers screen: the list on the left, the selected container on the right.
//
// A split rather than a push-navigation stack because the two panes are used together —
// you watch logs while you restart something, and you compare two rows by clicking
// between them. `HSplitView` also gives the divider drag for free, which is the one
// piece of window management a screen like this genuinely needs.

import AppKit
import SwiftUI

// MARK: - Scope

/// The All / Running filter.
enum TrackBScope: String, CaseIterable, Identifiable {
    case all, running

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .running: return "Running"
        }
    }
}

// MARK: - Root

struct ContainersRootView: View {

    let model: AppModel

    /// - Parameters:
    ///   - initialDetailTab: which tab the detail pane opens on. The app always opens
    ///     on Overview; previews and the screenshot harness need to photograph the
    ///     other three, and there is no other way in — the tab is this screen's own
    ///     state by design, so that clicking between containers does not drag the tab
    ///     around with it.
    ///   - initialHub: a stats hub that already holds history. A sparkline only exists
    ///     after a couple of minutes of a live socket, so a render that starts from an
    ///     empty hub draws empty charts no matter how long it waits.
    init(
        model: AppModel,
        initialDetailTab: TrackBDetailTab = .overview,
        initialHub: TrackBStatsHub? = nil
    ) {
        self.model = model
        self.initialDetailTab = initialDetailTab
        _hub = State(initialValue: initialHub ?? TrackBStatsHub())
    }

    private let initialDetailTab: TrackBDetailTab

    // MARK: State

    @State private var search = ""
    @State private var scope: TrackBScope = .all
    @State private var hub: TrackBStatsHub
    @State private var busy: Set<String> = []
    @State private var isPruning = false
    @State private var removalTarget: ContainerSummary?
    @State private var notice: TrackBNotice?
    @FocusState private var searchFocused: Bool

    // MARK: Derived

    private var stoppedCount: Int {
        model.containers.filter { !$0.isRunning }.count
    }

    private var filtered: [ContainerSummary] {
        let needle = TrackBLogFilter.normalize(search)
        return model.containers.filter { container in
            if scope == .running && !container.isRunning { return false }
            guard !needle.isEmpty else { return true }
            return container.displayName.lowercased().contains(needle)
                || container.image.lowercased().contains(needle)
                || (container.composeProject ?? "").lowercased().contains(needle)
                || (container.composeService ?? "").lowercased().contains(needle)
        }
    }

    private var groups: [ComposeGroup] { filtered.groupedByComposeProject() }

    private var selected: ContainerSummary? {
        guard let id = model.selectedContainerID else { return nil }
        return model.containers.first { $0.id == id }
    }

    private var subtitle: String {
        let running = model.containers.filter(\.isRunning).count
        let total = model.containers.count
        if total == 0 { return "No containers" }
        let shown = filtered.count
        let suffix = shown == total ? "" : " · \(shown) shown"
        return "\(running) running · \(total) total\(suffix)"
    }

    /// Selection is a plain binding rather than `@Bindable` so that the tour hook —
    /// `--tour-container`, which writes `selectedContainerID` before this view is even
    /// on screen — stays the single source of truth.
    private var selectionBinding: Binding<String?> {
        Binding(
            get: { model.selectedContainerID },
            set: { model.selectedContainerID = $0 })
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(.background)
        .overlay(alignment: .bottom) { noticeBar }
        .confirmationDialog(
            removalTarget.map { "Remove “\($0.displayName)”?" } ?? "Remove container?",
            isPresented: Binding(
                get: { removalTarget != nil },
                set: { if !$0 { removalTarget = nil } }),
            titleVisibility: .visible,
            presenting: removalTarget
        ) { container in
            Button("Remove", role: .destructive) {
                let id = container.id
                removalTarget = nil
                perform(.remove, on: id)
            }
            Button("Cancel", role: .cancel) { removalTarget = nil }
        } message: { container in
            Text(container.isRunning
                 ? "It is still running. Removing it stops the container and deletes its writable layer and anonymous volumes."
                 : "This deletes its writable layer and anonymous volumes. Named volumes are kept.")
        }
        .onDisappear { hub.stopAll() }
    }

    // MARK: Header

    private var header: some View {
        TrackBPageHeader(title: "Containers", subtitle: subtitle) {
            HStack(spacing: 10) {
                TrackBSearchField(
                    text: $search,
                    prompt: "Name, image, project",
                    width: 240,
                    externalFocus: $searchFocused)

                Picker("", selection: $scope) {
                    ForEach(TrackBScope.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Show all containers or only running ones")

                pruneButton
            }
        }
        // ⌘F focuses search from anywhere on the screen; the button is invisible and
        // zero-sized, which is the only way to bind a shortcut to a non-menu action
        // without owning the window's command set.
        .background {
            Button("Search") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    private var pruneButton: some View {
        Button {
            pruneStopped()
        } label: {
            HStack(spacing: 5) {
                if isPruning {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12)
                } else {
                    Image(systemName: "trash")
                }
                Text("Prune stopped")
                if stoppedCount > 0 {
                    Text("\(stoppedCount)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.2), in: Capsule())
                }
            }
        }
        .disabled(stoppedCount == 0 || isPruning)
        .help("Remove every stopped container")
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !model.engine.isRunning && model.containers.isEmpty {
            engineEmptyState
        } else if model.containers.isEmpty {
            noContainersEmptyState
        } else {
            HSplitView {
                // `HSplitView` ignores `idealWidth` and simply halves the space it is
                // given, so the ceiling is what actually decides the proportion: at 620
                // a 1440-point window put the divider dead centre and left the detail
                // pane too narrow for its own tables. 480 gets the intended shape — a
                // list wide enough for a long compose name, and the rest to the pane
                // that has something to say.
                listPane
                    .frame(minWidth: 320, idealWidth: 400, maxWidth: 480)
                detailPane
                    .frame(minWidth: 460, maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var listPane: some View {
        if filtered.isEmpty {
            TrackBEmptyState(
                symbols: ["magnifyingglass"],
                title: "No matches",
                message: scope == .running
                    ? "Nothing running matches “\(search)”."
                    : "No container matches “\(search)”.",
                snippet: nil
            ) {
                Button("Clear filters") {
                    search = ""
                    scope = .all
                }
                .buttonStyle(.borderless)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
        } else {
            List(selection: selectionBinding) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.containers) { container in
                            ContainerListRow(
                                container: container,
                                hub: hub,
                                client: model.client,
                                isBusy: busy.contains(container.id),
                                onAction: { perform($0, on: container.id) },
                                onRequestRemove: { removalTarget = container })
                            .tag(container.id)
                        }
                    } header: {
                        if showsHeader(for: group) {
                            ComposeGroupHeader(
                                group: group,
                                busyCount: group.containers.filter { busy.contains($0.id) }.count,
                                onUp: { startAll(in: group) },
                                onDown: { stopAll(in: group) })
                        }
                    }
                }
            }
            .listStyle(.inset)
            .environment(\.defaultMinListRowHeight, 30)
            .scrollContentBackground(.hidden)
            .background(.background)
        }
    }

    /// A single ungrouped bucket needs no header — the screen is already called
    /// "Containers", and a lone "Standalone" band is pure chrome.
    private func showsHeader(for group: ComposeGroup) -> Bool {
        group.project != nil || groups.count > 1
    }

    @ViewBuilder
    private var detailPane: some View {
        if let selected {
            ContainerDetailView(
                container: selected,
                model: model,
                hub: hub,
                isBusy: busy.contains(selected.id),
                onAction: { perform($0, on: selected.id) },
                onRequestRemove: { removalTarget = selected })
            .id(selected.id)
        } else {
            TrackBEmptyState(
                symbols: ["shippingbox", "sidebar.right", "text.alignleft"],
                title: "Select a container",
                message: "Pick a container to see its configuration, follow its logs, watch CPU and memory, or read the full inspect document.",
                snippet: nil
            ) {
                EmptyView()
            }
            .background(.background.secondary)
        }
    }

    // MARK: Empty states

    private var engineEmptyState: some View {
        TrackBEmptyState(
            symbols: ["bolt.horizontal", "shippingbox", "power"],
            title: "The engine is not running",
            message: "Morbstack's VM is \(model.engine.reachable ? model.engine.state : "stopped"). Start it to see and manage containers.",
            snippet: nil
        ) {
            Button {
                Task { await model.engineAction(.start) }
            } label: {
                Label("Start engine", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Theme.brand)
            .disabled(model.engine.isTransitional)
        }
    }

    private var noContainersEmptyState: some View {
        TrackBEmptyState(
            symbols: ["cube.transparent", "shippingbox.fill", "cube.transparent"],
            title: "No containers yet",
            message: "Nothing is running on this engine. Start something from a terminal and it will show up here the moment it exists.",
            snippet: "docker run -d -p 8080:80 nginx"
        ) {
            Button {
                Task { await model.refreshAll() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: Notice

    @ViewBuilder
    private var noticeBar: some View {
        if let notice {
            HStack(spacing: 8) {
                Image(systemName: notice.symbol)
                    .foregroundStyle(notice.isError ? Color.red : Color.green)
                Text(notice.text).font(.callout)
                Spacer(minLength: 8)
                Button {
                    self.notice = nil
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 460)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func show(_ text: String, isError: Bool = false) {
        let notice = TrackBNotice(text: text, isError: isError)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            self.notice = notice
        }
        Task {
            try? await Task.sleep(for: .seconds(isError ? 6 : 3))
            if self.notice?.id == notice.id {
                withAnimation(.easeOut(duration: 0.2)) { self.notice = nil }
            }
        }
    }

    // MARK: Intents

    /// Runs one lifecycle action, keeping the row's spinner honest for its duration.
    private func perform(_ action: ContainerAction, on id: String) {
        guard !busy.contains(id) else { return }
        busy.insert(id)
        Task {
            await model.containerAction(action, id: id)
            busy.remove(id)
            if action == .remove {
                hub.forget(id)
                if model.selectedContainerID == id { model.selectedContainerID = nil }
            }
        }
    }

    /// Compose "up": every member that is not already running gets started.
    ///
    /// Concurrently, because a stack's services are independent from the engine's point
    /// of view and starting six of them one at a time is six round trips of waiting.
    private func startAll(in group: ComposeGroup) {
        let targets = group.containers.filter { !$0.isRunning }.map(\.id)
        runBatch(targets) { id in
            await model.containerAction(.start, id: id)
        }
    }

    private func stopAll(in group: ComposeGroup) {
        let targets = group.containers.filter(\.isRunning).map(\.id)
        runBatch(targets) { id in
            await model.containerAction(.stop, id: id)
        }
    }

    private func runBatch(_ ids: [String], _ body: @escaping (String) async -> Void) {
        guard !ids.isEmpty else { return }
        busy.formUnion(ids)
        Task {
            await withTaskGroup(of: Void.self) { group in
                for id in ids {
                    group.addTask { await body(id) }
                }
            }
            busy.subtract(ids)
        }
    }

    private func pruneStopped() {
        guard !isPruning else { return }
        isPruning = true
        Task {
            do {
                let reclaimed = try await model.client.pruneContainers()
                await model.refreshAll()
                show(reclaimed > 0
                     ? "Pruned stopped containers · \(Formatters.bytesString(reclaimed)) reclaimed"
                     : "Pruned stopped containers")
            } catch {
                show(TrackBErrorText.short(error), isError: true)
            }
            isPruning = false
        }
    }
}

// MARK: - Notice

struct TrackBNotice: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var isError: Bool = false

    var symbol: String { isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill" }
}
