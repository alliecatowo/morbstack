// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The Builds screen — distinct BuildKit cache and Buildx completed-build collections.
//
// Docker's classic builder has no notion of "a build" as a first-class object: it keeps
// a graph of cache records shared across every build that has ever run against the
// engine, and `/system/df` is the one endpoint that lists them. There is no per-record
// delete in the Docker Engine API — only `POST /build/prune`, which removes every
// unused record at once — so this screen can inspect the cache in detail but can only
// act on it as a whole, the same constraint the Disk screen's build-cache row already
// lives with.
//
// The two collections remain intentionally separate. `/system/df` cache records are
// shared across builds and do not identify one completed build, while `buildx history
// ls` reports completed-build metadata for its active builder. The history scope shows
// only records returned by that explicit, read-only Buildx query; it never infers a
// build history from cache layers or locally fabricated state.

import AppKit
import MorbstackKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sorting and filtering

enum BuildSortKey: String, CaseIterable, Hashable {
    case description, type, size, lastUsed
}

struct BuildComparator: SortComparator {
    var key: BuildSortKey
    var order: SortOrder = .forward

    func compare(_ lhs: BuildCacheRecord, _ rhs: BuildCacheRecord) -> ComparisonResult {
        let result: ComparisonResult
        switch key {
        case .description:
            result = MorbSort.string(lhs.description, rhs.description)
        case .type:
            result = lhs.type == rhs.type
                ? MorbSort.string(lhs.description, rhs.description)
                : MorbSort.string(lhs.type, rhs.type)
        case .size:
            result = lhs.size == rhs.size
                ? MorbSort.string(lhs.description, rhs.description)
                : (lhs.size < rhs.size ? .orderedAscending : .orderedDescending)
        case .lastUsed:
            let left = lhs.lastUsedAt ?? .distantPast, right = rhs.lastUsedAt ?? .distantPast
            result = left == right
                ? MorbSort.string(lhs.description, rhs.description)
                : MorbSort.date(left, right)
        }
        return order == .forward ? result : result.reversed
    }
}

enum BuildCacheList {
    static func matches(_ record: BuildCacheRecord, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return record.description.localizedCaseInsensitiveContains(needle)
            || record.type.localizedCaseInsensitiveContains(needle)
            || record.shortID.localizedCaseInsensitiveContains(needle)
    }

    /// Cache bytes that Docker attributes to BuildKit rather than an image parent.
    ///
    /// `/system/df` repeats shared cache records for every parent that references
    /// them. Counting those entries in the route subtitle would make it disagree
    /// with Disk and overstate the storage owned by the build cache.
    static func storageSize(_ records: [BuildCacheRecord]) -> Int64 {
        records.reduce(Int64(0)) { total, record in
            total + (record.shared ? 0 : max(0, record.size))
        }
    }

    static func unused(_ records: [BuildCacheRecord]) -> [BuildCacheRecord] {
        records.filter { !$0.inUse }
    }
}

private enum BuildDataScope: Hashable {
    case cache
    case history
}

/// The selected history row deliberately has no eager detail fetch. `history ls` and
/// `history inspect` are independent, builder-scoped reads, so showing inspect output
/// requires this explicit state and a deliberate user command.
private enum BuildHistoryDetailState: Equatable {
    case idle
    case loading
    case loaded(BuildxHistoryDetail)
    case unavailable(String)
}

/// Logs are an independent, explicitly requested Buildx read. They stay separate from
/// inspect state so selecting a row, loading its metadata, or refreshing the history
/// table never starts a potentially large transcript request.
private enum BuildHistoryLogState: Equatable {
    case idle
    case loading
    case loaded(BuildxHistoryLog)
    case unavailable(String)
}

/// Details and output are peer views of one selected completed build. A tab keeps the
/// factual Form separate from the potentially long raw log instead of compressing both
/// into one inspector column.
private enum BuildHistoryInspectorTab: Hashable {
    case details
    case log
}

/// Produces a provenance-bearing document from a Buildx log that is already present in
/// the inspector. Saving must not start another builder command just to obtain more
/// output: a Buildx record can be arbitrarily verbose and this route retains only the
/// bounded text the explicit `history logs` request already returned.
enum BuildHistoryLogExport {

    struct Document: Sendable {
        let text: String
        let suggestedFilename: String
        let panelMessage: String

        var data: Data { Data(text.utf8) }
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func document(
        log: BuildxHistoryLog,
        record: BuildxHistoryRecord,
        capturedAt: Date = Date()
    ) -> Document {
        let createdDescription = record.createdAt.map { timestampFormatter.string(from: $0) }
            ?? "Not reported by Buildx"
        let byteCount = Data(log.output.utf8).count
        let retentionDescription = log.isTruncated
            ? "Morbstack retained the first 4 MB of Buildx stdout; later output was dropped."
            : "Buildx stdout stayed within Morbstack’s 4 MB retained-text limit."
        let header = [
            "# Morbstack Buildx history log snapshot",
            "# Build record: \(record.name) (\(record.id))",
            "# Record status: \(record.status)",
            "# Record created: \(createdDescription)",
            "# Captured: \(timestampFormatter.string(from: capturedAt))",
            "# Source: already-loaded stdout from docker buildx history logs --progress rawjson for this selected record.",
            "# Loaded transcript: \(byteCount) UTF-8 bytes retained by Morbstack.",
            "# Log filter: none; the history-table search does not filter this loaded transcript.",
            "# Retention: \(retentionDescription)",
            "# Scope: this is retained output for one Buildx history record, not complete builder, Docker, CI, or build history. Saving did not rerun Buildx or fetch more output.",
            "#",
        ].joined(separator: "\n") + "\n"
        let name = suggestedFilename(record: record, capturedAt: capturedAt)
        let panelMessage = "Save \(byteCount) bytes of already-loaded Buildx output for \(record.name). The file records selected-record, no-filter, and truncation scope; saving does not rerun Buildx or represent complete build history."
        return Document(text: header + log.output, suggestedFilename: name, panelMessage: panelMessage)
    }

    private static func suggestedFilename(record: BuildxHistoryRecord, capturedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let source = record.name.isEmpty ? record.id : record.name
        let safe = source.map { character -> Character in
            switch character {
            case "/", ":", "\\": return "-"
            default: return character
            }
        }
        return "buildx-\(String(safe))-\(formatter.string(from: capturedAt)).log"
    }
}

private enum BuildHistorySortKey: String, CaseIterable, Hashable {
    case name, status, createdAt, duration
}

private struct BuildHistoryComparator: SortComparator {
    var key: BuildHistorySortKey
    var order: SortOrder = .forward

    func compare(_ lhs: BuildxHistoryRecord, _ rhs: BuildxHistoryRecord) -> ComparisonResult {
        let result: ComparisonResult
        switch key {
        case .name:
            result = MorbSort.string(lhs.name, rhs.name)
        case .status:
            result = lhs.status == rhs.status
                ? MorbSort.string(lhs.name, rhs.name)
                : MorbSort.string(lhs.status, rhs.status)
        case .createdAt:
            let left = lhs.createdAt ?? .distantPast
            let right = rhs.createdAt ?? .distantPast
            result = left == right
                ? MorbSort.string(lhs.name, rhs.name)
                : MorbSort.date(left, right)
        case .duration:
            let left = lhs.duration ?? ""
            let right = rhs.duration ?? ""
            result = left == right
                ? MorbSort.string(lhs.name, rhs.name)
                : MorbSort.string(left, right)
        }
        return order == .forward ? result : result.reversed
    }
}

private enum BuildHistoryList {
    static func matches(_ record: BuildxHistoryRecord, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return record.name.localizedCaseInsensitiveContains(needle)
            || record.status.localizedCaseInsensitiveContains(needle)
            || record.id.localizedCaseInsensitiveContains(needle)
    }
}

// MARK: - Root

struct BuildsRootView: View {

    let model: AppModel

    @State private var query = ""
    @State private var scope: BuildDataScope = .cache
    @State private var sortOrder: [BuildComparator] = [BuildComparator(key: .size, order: .reverse)]
    @State private var selection: BuildCacheRecord.ID?
    @State private var historySortOrder: [BuildHistoryComparator] = [
        BuildHistoryComparator(key: .createdAt, order: .reverse),
    ]
    @State private var historySelection: BuildxHistoryRecord.ID?
    @State private var historyDetailState: BuildHistoryDetailState = .idle
    @State private var historyDetailTask: Task<Void, Never>?
    @State private var historyLogState: BuildHistoryLogState = .idle
    @State private var historyLogTask: Task<Void, Never>?
    @State private var historyInspectorTab: BuildHistoryInspectorTab = .details
    @State private var showsInspector = true
    @State private var isRefreshing = false
    @State private var isPruning = false
    @State private var showsPruneConfirmation = false
    @State private var pruneError: String?
    @State private var lastPrunedBytes: Int64?
    @State private var showsBuildSheet = false
    @State private var showsContextPicker = false
    @State private var draftContextDirectory: URL?
    @State private var draftTag = ""
    @State private var buildPreparationError: String?
    @State private var pendingBuildRequest: LocalBuildRequest?
    @State private var buildPhase: BuildSheetPhase = .configuration
    @State private var buildEvents: [BuildProgressEvent] = []
    @State private var buildTask: Task<Void, Never>?
    @State private var showsBuilderSheet = false
    @State private var builderSheetState: BuildxCurrentBuilderLoadState = .idle
    @State private var builderSheetBuilder: BuildxCurrentBuilder?
    @State private var builderSheetTask: Task<Void, Never>?
    @State private var isSelectingMorbstackDefaultBuilder = false
    @State private var showsDefaultBuilderConfirmation = false
    @State private var defaultBuilderError: String?
    @State private var pendingHistoryLogExport: BuildHistoryLogExport.Document?
    @State private var historyLogExportError: String?

    private var records: [BuildCacheRecord] { model.buildCache }

    private var visible: [BuildCacheRecord] {
        records.filter { BuildCacheList.matches($0, query: query) }.sorted(using: sortOrder)
    }

    private var visibleHistory: [BuildxHistoryRecord] {
        model.buildHistory
            .filter { BuildHistoryList.matches($0, query: query) }
            .sorted(using: historySortOrder)
    }

    private var unusedCount: Int { BuildCacheList.unused(records).count }

    private var sharedCacheRecordCount: Int { records.filter(\.shared).count }

    /// `/system/df` repeats shared BuildKit records for each parent that references
    /// them. The route total intentionally excludes those records so it cannot
    /// overstate cache storage; this explanation stays alongside the displayed total.
    private var cacheStorageExplanation: String {
        if sharedCacheRecordCount == 0 {
            return "The cache total contains only records Docker does not mark shared. No shared records are currently excluded."
        }
        return "The cache total excludes \(sharedCacheRecordCount) record\(sharedCacheRecordCount == 1 ? "" : "s") Docker marks shared, so the same storage is not counted more than once."
    }

    private var cacheSubtitle: String {
        if case .running(let request) = buildPhase { return "Building \(request.displayName)…" }
        if isPruning { return "Pruning unused cache…" }

        guard !records.isEmpty else {
            guard let lastPrunedBytes else { return "No cache" }
            return lastPrunedBytes > 0
                ? "No cache · \(Formatters.bytesString(lastPrunedBytes)) reclaimed"
                : "No cache · No space reclaimed"
        }
        var parts = ["\(records.count) record\(records.count == 1 ? "" : "s")"]
        parts.append("\(Formatters.bytesString(BuildCacheList.storageSize(records))) deduplicated")
        if unusedCount > 0 { parts.append("\(unusedCount) unused") }
        if let lastPrunedBytes {
            let outcome = lastPrunedBytes > 0
                ? "\(Formatters.bytesString(lastPrunedBytes)) reclaimed"
                : "No space reclaimed"
            parts.append(outcome)
        }
        return parts.joined(separator: " · ")
    }

    private var selectedRecord: BuildCacheRecord? {
        guard let selection else { return nil }
        return records.first { $0.id == selection }
    }

    private var selectedHistoryRecord: BuildxHistoryRecord? {
        guard let historySelection else { return nil }
        return model.buildHistory.first { $0.id == historySelection }
    }

    private var subtitle: String {
        scope == .cache ? cacheSubtitle : historySubtitle
    }

    private var historySubtitle: String {
        let history: String
        switch model.buildHistoryState {
        case .idle:
            history = "Buildx history not loaded"
        case .loading:
            history = "Loading Buildx history…"
        case .loaded:
            let count = model.buildHistory.count
            history = count == 0
                ? "No completed builds"
                : "\(count) completed build\(count == 1 ? "" : "s")"
        case .unavailable:
            history = "Buildx history unavailable"
        }

        switch model.buildxCurrentBuilderState {
        case .loaded:
            guard let builder = model.buildxCurrentBuilder else { return history }
            return [builder.name, builder.driver, builder.reportedNodeStatus]
                .compactMap { $0 }
                .joined(separator: " · ")
                + " · " + history
        case .loading:
            return "Checking active Buildx builder… · \(history)"
        case .unavailable:
            return "Active Buildx builder unavailable · \(history)"
        case .idle:
            return history
        }
    }

    private var isHistoryRefreshing: Bool {
        if case .loading = model.buildHistoryState { return true }
        return false
    }

    private var isRefreshingCurrentScope: Bool {
        scope == .cache ? isRefreshing : isHistoryRefreshing
    }

    /// Build cache fixture data can be browsed safely through the injected Docker
    /// client. Buildx history, builder inspection/selection, and a local build each
    /// launch a bundled client or use a direct socket, so they must remain unavailable
    /// in the deliberately disconnected fixture window.
    private var externalBuildOperationsAreAvailable: Bool {
        model.permitsExternalOperations
    }

    private var fixtureBuildOperationMessage: String {
        "Buildx commands and local build selection are unavailable in developer fixture data. This window is not connected to a Docker Engine."
    }

    // As one literal expression this modifier chain exceeded what the type checker
    // could solve in reasonable time. The chain is split into staged helpers applied
    // in the original order — no modifier was added, removed, or reordered.
    var body: some View {
        withLifecycleHandlers(
            withOperationAlerts(
                withBuildDialogs(
                    withSheetsAndImporter(
                        content
                            .navigationTitle("Builds")
                            .navigationSubtitle(subtitle)
                            .toolbar { toolbarContent }
                            // The menu-bar mirror of the options menu's prune command,
                            // so it stays reachable when the toolbar overflows.
                            .focusedSceneValue(
                                \.routeMaintenanceCommand,
                                RouteMaintenanceCommand(
                                    title: "Prune Unused Build Cache…",
                                    isEnabled: scope == .cache && externalBuildOperationsAreAvailable
                                        && unusedCount > 0 && !isPruning && !isRefreshing,
                                    perform: { showsPruneConfirmation = true }))))))
    }

    private func withSheetsAndImporter(_ view: some View) -> some View {
        view
            .sheet(isPresented: $showsBuildSheet, onDismiss: resetBuildSheetIfIdle) {
                buildSheet
            }
            .sheet(isPresented: $showsBuilderSheet, onDismiss: cancelActiveBuilderInspection) {
                builderSheet
            }
            .fileImporter(
                isPresented: $showsContextPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    draftContextDirectory = urls.first
                    buildPreparationError = nil
                case .failure(let error):
                    buildPreparationError = MorbErrorMessage.text(for: error)
                }
            }
    }

    private func withBuildDialogs(_ view: some View) -> some View {
        view
            .confirmationDialog(
                pendingBuildRequest.map { "Build \($0.displayName)?" } ?? "Build image?",
                isPresented: Binding(
                    get: { pendingBuildRequest != nil && buildPhase == .configuration },
                    set: { if !$0 { pendingBuildRequest = nil } }),
                titleVisibility: .visible
            ) {
                Button("Build Image") {
                    guard let request = pendingBuildRequest else { return }
                    pendingBuildRequest = nil
                    startBuild(request)
                }
                Button("Cancel", role: .cancel) { pendingBuildRequest = nil }
            } message: {
                if let pendingBuildRequest {
                    Text(
                        "Buildx will read \(pendingBuildRequest.contextDirectory.path), honor its .dockerignore "
                            + "file, and run the Dockerfile's instructions inside Morbstack's Linux VM. "
                            + "This build loads an image locally and does not push to a registry.")
                }
            }
            .confirmationDialog(
                "Prune unused build cache?",
                isPresented: $showsPruneConfirmation,
                titleVisibility: .visible
            ) {
                Button("Prune Unused Cache", role: .destructive) {
                    Task { await pruneUnusedCache() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "Docker will remove unused build cache across this engine, not only the selected "
                        + "record. It keeps cache that is in use. Docker decides the final eligible "
                        + "records when the cleanup runs.")
            }
    }

    private func withOperationAlerts(_ view: some View) -> some View {
        view
            .alert(
                "Couldn’t Prune Build Cache",
                isPresented: Binding(
                    get: { pruneError != nil },
                    set: { if !$0 { pruneError = nil } })
            ) {
                Button("Try Again") {
                    pruneError = nil
                    showsPruneConfirmation = true
                }
                Button("Cancel", role: .cancel) { pruneError = nil }
            } message: {
                Text(pruneError ?? "")
            }
            .alert(
                "Couldn’t Save Build Log",
                isPresented: Binding(
                    get: { historyLogExportError != nil },
                    set: { if !$0 { historyLogExportError = nil } })
            ) {
                Button("Choose Another Location…") {
                    guard let pendingHistoryLogExport else { return }
                    historyLogExportError = nil
                    chooseHistoryLogExportDestination(for: pendingHistoryLogExport)
                }
                Button("Cancel", role: .cancel) {
                    historyLogExportError = nil
                    pendingHistoryLogExport = nil
                }
            } message: {
                Text(historyLogExportError ?? "")
            }
    }

    private func withLifecycleHandlers(_ view: some View) -> some View {
        view
            .task {
                if selection == nil { selection = visible.first?.id }
            }
            .onChange(of: query) { _, _ in
                selectFirstVisibleRecordIfNeeded(for: scope)
            }
            .onChange(of: records) { _, _ in
                selectFirstVisibleRecordIfNeeded(for: .cache)
            }
            .onChange(of: model.buildHistory) { _, _ in
                selectFirstVisibleRecordIfNeeded(for: .history)
                resetHistoryDetails()
            }
            .onChange(of: scope) { _, newScope in
                // The History view starts an explicit Buildx query. Keep a fixture
                // window on its injected cache records even if state restoration or an
                // accessibility action attempts to select the unavailable segment.
                guard externalBuildOperationsAreAvailable || newScope != .history else {
                    scope = .cache
                    return
                }
                query = ""
                selectFirstVisibleRecordIfNeeded(for: newScope)
                resetHistoryDetails()
                if newScope == .history {
                    Task { await refreshBuildHistory() }
                }
            }
            .onChange(of: selection) { _, newValue in
                if newValue != nil { showsInspector = true }
            }
            .onChange(of: historySelection) { _, newValue in
                resetHistoryDetails()
                if newValue != nil { showsInspector = true }
            }
            .onDisappear {
                // A build has one client connection. Cancelling its task closes that
                // client rather than leaving an unseen build running after navigation.
                buildTask?.cancel()
                historyDetailTask?.cancel()
                historyLogTask?.cancel()
                cancelActiveBuilderInspection()
            }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // `.principal` — the scope choice is what this window is showing, so it
        // belongs in the center region, not sharing a glass group with commands.
        ToolbarItem(id: "builds.scope", placement: .principal) {
            Picker("Build data", selection: $scope) {
                Text("Cache").tag(BuildDataScope.cache)
                // Fixture windows omit the segment entirely: `.disabled` on a
                // segmented-picker tag does not render as disabled, so it looked
                // live and silently snapped back.
                if externalBuildOperationsAreAvailable {
                    Text("History").tag(BuildDataScope.history)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("builds.scope")
            .accessibilityLabel("Build data")
            .help(
                externalBuildOperationsAreAvailable
                    ? "Choose BuildKit cache or Buildx history"
                    : "Buildx history is unavailable in developer fixture data")
        }
        // One semantic options menu instead of three loose glyphs — refresh, the
        // builder sheet, and the infrequent destructive prune stay together.
        ToolbarItem(id: "builds.options", placement: .primaryAction) {
            Menu {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await refreshCurrentScope() }
                }
                .disabled(isRefreshingCurrentScope || isPruning)

                Button("View Active Builder…", systemImage: "hammer") {
                    openBuilderSheet()
                }
                .disabled(!externalBuildOperationsAreAvailable || isBuilding || isSelectingMorbstackDefaultBuilder)

                if scope == .cache {
                    Divider()
                    Button("Prune Unused Build Cache…", systemImage: "trash", role: .destructive) {
                        showsPruneConfirmation = true
                    }
                    .disabled(!externalBuildOperationsAreAvailable || unusedCount == 0 || isPruning || isRefreshing)
                }
            } label: {
                if isRefreshingCurrentScope || isPruning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Build options", systemImage: "slider.horizontal.3")
                }
            }
            .accessibilityIdentifier("builds.options")
            .accessibilityLabel("Build options")
            .help("Refresh, builder, and cleanup options")
        }
        // No `ToolbarSpacer` here, unlike Volumes/Networks/Images: this route's
        // destructive command is an item *inside* the options menu, not a bare
        // trash button that would sit in the same capsule as "build".
        if !inspectorIsMounted {
            // The inspector-less empty screens still need the trailing commands in
            // the window toolbar; when a table is on screen they ride the inspector
            // content instead — see `VolumesRootView.trailingCommandItems`.
            trailingCommandItems
        }
    }

    /// Whether the current scope's content branch mounts the system inspector —
    /// the exact complement of the states where `toolbarContent` must supply the
    /// trailing commands itself.
    private var inspectorIsMounted: Bool {
        if !externalBuildOperationsAreAvailable, scope == .history { return false }
        if scope == .cache { return !records.isEmpty }
        if case .loaded = model.buildHistoryState { return !model.buildHistory.isEmpty }
        return false
    }

    /// See the note on `VolumesRootView.trailingCommandItems`.
    @ToolbarContentBuilder
    private var trailingCommandItems: some ToolbarContent {
        if scope == .cache {
            ToolbarItem(id: "builds.start", placement: .primaryAction) {
                Button {
                    showsBuildSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("builds.start")
                .accessibilityLabel("Build an image")
                .help(
                    externalBuildOperationsAreAvailable
                        ? "Build an image from a local Dockerfile"
                        : fixtureBuildOperationMessage)
                .disabled(!externalBuildOperationsAreAvailable || isPruning)
            }
        }
        if scope == .cache ? !records.isEmpty : !model.buildHistory.isEmpty {
            // `.automatic`, matching every other route's inspector toggle placement.
            ToolbarItem(id: "builds.inspector", placement: .automatic) {
                Button {
                    showsInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .accessibilityIdentifier("builds.inspector")
                .accessibilityLabel(showsInspector ? "Hide inspector" : "Show inspector")
                .help(showsInspector ? "Hide the inspector" : "Show the inspector")
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !externalBuildOperationsAreAvailable, scope == .history {
            fixtureHistoryUnavailable
        } else if scope == .cache {
            cacheContent
        } else {
            historyContent
        }
    }

    private var fixtureHistoryUnavailable: some View {
        ContentUnavailableView {
            Label("Buildx History Unavailable", systemImage: "clock.arrow.circlepath")
        } description: {
            Text(fixtureBuildOperationMessage)
        }
        .accessibilityIdentifier("builds.empty.historyFixtureUnavailable")
    }

    @ViewBuilder
    private var cacheContent: some View {
        if records.isEmpty {
            ContentUnavailableView {
                Label("No Build Cache", systemImage: "hammer")
            } description: {
                Text("Build an image to create local BuildKit cache records. Shared records are kept out of the route's storage total so the same bytes are not counted twice.")
            } actions: {
                Button {
                    showsBuildSheet = true
                } label: {
                    Label("Build Image", systemImage: "plus")
                }
                .accessibilityIdentifier("builds.empty.noCache.build")
                .disabled(!externalBuildOperationsAreAvailable)
                .help(
                    externalBuildOperationsAreAvailable
                        ? "Build an image from a local Dockerfile"
                        : fixtureBuildOperationMessage)
                Button {
                    Task { await refreshBuildCache() }
                } label: {
                    Label(isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("builds.empty.noCache.refresh")
                .disabled(isRefreshing)
            }
            .accessibilityIdentifier("builds.empty.noCache")
        } else {
            Group {
                if visible.isEmpty {
                    // The inspector stays mounted behind the no-results state so the
                    // search field — declared on the inspector content below —
                    // remains on screen to clear or edit the query.
                    ContentUnavailableView.search(text: query)
                } else {
                    table
                }
            }
            .inspector(isPresented: $showsInspector) {
                detailPane
                    // See the note on `VolumesRootView`: the trailing commands and
                    // search ride the inspector's toolbar region and remain present
                    // while the inspector is closed.
                    .toolbar { trailingCommandItems }
                    .searchable(text: $query, placement: .toolbarPrincipal, prompt: searchPrompt)
                    // `.inspectorColumnWidth` must be the outermost modifier on the
                    // inspector's content — applied beneath `.toolbar`/`.searchable`
                    // its preferred width was silently discarded and every route
                    // fell back to the system default (~270pt), clipping every
                    // value regardless of the min/ideal/max declared here. Verified
                    // empirically against the real window 2026-08-06.
                    .inspectorColumnWidth(min: 340, ideal: 400, max: 460)
            }
        }
    }

    private var table: some View {
        Table(visible, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Description", sortUsing: BuildComparator(key: .description)) { record in
                descriptionCell(record)
            }
            TableColumn("Status") { record in
                statusCell(record)
            }
            .width(min: 78, ideal: 104, max: 132)
            TableColumn("Type", sortUsing: BuildComparator(key: .type)) { record in
                Text(record.type)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 90, ideal: 120, max: 160)
            TableColumn("Size", sortUsing: BuildComparator(key: .size)) { record in
                Text(Formatters.bytesString(record.size))
                    .monospacedDigit()
            }
            .width(min: 72, ideal: 88, max: 120)
            TableColumn("Last Used", sortUsing: BuildComparator(key: .lastUsed)) { record in
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(record.lastUsedAt.map { Formatters.compactDuration(since: $0, at: context.date) } ?? "Never")
                        .monospacedDigit()
                        .help(record.lastUsedAt.map(Formatters.absoluteDate) ?? "Never used")
                }
            }
            .width(min: 72, ideal: 88, max: 120)
        }
        .tableStyle(.automatic)
        // See the striping note on `VolumesRootView.table`: system striping past the
        // last record reads as broken placeholder rows at this route's density.
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: BuildCacheRecord.ID.self) { ids in
            if let id = ids.first, let record = records.first(where: { $0.id == id }) {
                Button("Copy Description") { MorbPasteboard.copy(record.description) }
                Button("Copy Record ID") { MorbPasteboard.copy(record.id) }
            }
        }
        .accessibilityIdentifier("builds.table")
    }

    @ViewBuilder
    private var historyContent: some View {
        switch model.buildHistoryState {
        case .idle:
            ContentUnavailableView {
                Label("Build History Not Loaded", systemImage: "clock.arrow.circlepath")
            } description: {
                Text("Load completed builds reported by Buildx for Morbstack’s active builder.")
            } actions: {
                Button {
                    Task { await refreshBuildHistory() }
                } label: {
                    Label("Load Build History", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("builds.empty.historyIdle.load")
            }
            .accessibilityIdentifier("builds.empty.historyIdle")
        case .loading:
            ContentUnavailableView {
                Label("Loading Build History", systemImage: "clock.arrow.circlepath")
            } description: {
                Text("Checking the active Buildx builder…")
            } actions: {
                // The spinner belongs in the actions slot; `description:` expects
                // text and renders an embedded ProgressView inconsistently.
                ProgressView()
                    .controlSize(.small)
            }
            .accessibilityIdentifier("builds.empty.historyLoading")
        case .unavailable(let detail):
            ContentUnavailableView {
                Label("Build History Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(detail)
            } actions: {
                Button {
                    Task { await refreshBuildHistory() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("builds.empty.historyUnavailable.retry")
                .disabled(isHistoryRefreshing)
            }
            .accessibilityIdentifier("builds.empty.historyUnavailable")
        case .loaded:
            if model.buildHistory.isEmpty {
                ContentUnavailableView {
                    Label("No Completed Builds", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("The active Buildx builder has not reported any completed builds.")
                } actions: {
                    Button {
                        Task { await refreshBuildHistory() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("builds.empty.noCompletedBuilds.refresh")
                    .disabled(isHistoryRefreshing)
                }
                .accessibilityIdentifier("builds.empty.noCompletedBuilds")
            } else {
                Group {
                    if visibleHistory.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        historyTable
                    }
                }
                .inspector(isPresented: $showsInspector) {
                    historyDetailPane
                        // See the note on `VolumesRootView`.
                        .toolbar { trailingCommandItems }
                        .searchable(text: $query, placement: .toolbarPrincipal, prompt: searchPrompt)
                        // See the note above this pattern's other use in this file:
                        // must be outermost or its width is silently discarded.
                        .inspectorColumnWidth(min: 340, ideal: 400, max: 460)
                }
            }
        }
    }

    private func descriptionCell(_ record: BuildCacheRecord) -> some View {
        Text(record.description)
            .font(.system(.callout, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.tail)
            // Row identity is the engine-facing cache record ID, per
            // docs/design/ACCESSIBILITY-IDENTIFIERS.md.
            .accessibilityIdentifier("builds.row.\(record.id)")
    }

    private func statusCell(_ record: BuildCacheRecord) -> some View {
        Text(record.shared
            ? (record.inUse ? "In Use · Shared" : "Unused · Shared")
            : (record.inUse ? "In Use" : "Unused"))
            .foregroundStyle(.secondary)
    }

    private var historyTable: some View {
        Table(visibleHistory, selection: $historySelection, sortOrder: $historySortOrder) {
            TableColumn("Name", sortUsing: BuildHistoryComparator(key: .name)) { record in
                Text(record.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Row identity is the engine-facing Buildx history record ID, per
                    // docs/design/ACCESSIBILITY-IDENTIFIERS.md.
                    .accessibilityIdentifier("builds.historyRow.\(record.id)")
            }
            TableColumn("Status", sortUsing: BuildHistoryComparator(key: .status)) { record in
                Text(record.status)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 90, ideal: 120, max: 180)
            TableColumn("Created", sortUsing: BuildHistoryComparator(key: .createdAt)) { record in
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(record.createdAt.map { Formatters.compactDuration(since: $0, at: context.date) } ?? "Not reported")
                        .monospacedDigit()
                        .help(record.createdAt.map(Formatters.absoluteDate) ?? "Buildx did not report a creation time")
                }
            }
            .width(min: 100, ideal: 122, max: 154)
            TableColumn("Duration", sortUsing: BuildHistoryComparator(key: .duration)) { record in
                Text(record.duration ?? "Not reported")
                    .monospacedDigit()
                    .foregroundStyle(record.duration == nil ? .secondary : .primary)
            }
            .width(min: 88, ideal: 104, max: 132)
        }
        .tableStyle(.automatic)
        // See the striping note on `VolumesRootView.table`.
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: BuildxHistoryRecord.ID.self) { ids in
            if let id = ids.first, let record = model.buildHistory.first(where: { $0.id == id }) {
                Button("Copy Build ID") { MorbPasteboard.copy(record.id) }
            }
        }
        .accessibilityIdentifier("builds.historyTable")
    }

    // MARK: Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let record = selectedRecord {
            Form {
                if !externalBuildOperationsAreAvailable {
                    Section("Developer Fixture Data") {
                        Text(fixtureBuildOperationMessage)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Cache Storage") {
                    LabeledContent("Deduplicated Total", value: Formatters.bytesString(BuildCacheList.storageSize(records)))
                    LabeledContent("Records", value: "\(records.count)")
                    LabeledContent("Unused", value: "\(unusedCount)")
                    LabeledContent("Shared", value: "\(sharedCacheRecordCount)")
                    Text(cacheStorageExplanation)
                        .foregroundStyle(.secondary)
                }
                Section("Cache Record") {
                    LabeledContent("Description") {
                        Text(record.description)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }
                    LabeledContent("Status", value: record.inUse ? "In Use" : "Unused")
                    LabeledContent("Size", value: Formatters.bytesString(record.size))
                    LabeledContent("Type", value: record.type)
                    LabeledContent("Record ID") {
                        Text(record.id)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Created", value: Formatters.absoluteDate(record.createdAt))
                    LabeledContent(
                        "Last Used",
                        value: record.lastUsedAt.map(Formatters.absoluteDate) ?? "Never")
                    LabeledContent("Used", value: "\(record.usageCount) time\(record.usageCount == 1 ? "" : "s")")
                    LabeledContent(
                        "Storage",
                        value: record.shared
                            ? "Shared — excluded from deduplicated total"
                            : "Included in deduplicated total")
                }
            }
            // Automatic system Form — see the clipping note on
            // `VolumesRootView.detailPane`. This pane happened to fit at 400pt, but
            // it carried the same `.formStyle(.columns)` overflow defect for any
            // wider cache description.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView(
                "No Record Selected",
                systemImage: "hammer",
                description: Text("Select a cache record to see what produced it and when it was last used."))
        }
    }

    @ViewBuilder
    private var historyDetailPane: some View {
        if let record = selectedHistoryRecord {
            switch historyDetailState {
            case .idle:
                ContentUnavailableView {
                    Label("Details Not Loaded", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("Load the metadata Buildx reports for this completed build record.")
                } actions: {
                    Button("Load Details") {
                        loadHistoryDetails(for: record.id)
                    }
                }
            case .loading:
                ContentUnavailableView {
                    Label("Loading Build Details", systemImage: "doc.text.magnifyingglass")
                } description: {
                    ProgressView("Reading the selected Buildx record…")
                } actions: {
                    Button("Cancel Loading") {
                        historyDetailTask?.cancel()
                    }
                }
            case .unavailable(let detail):
                ContentUnavailableView {
                    Label("Build Details Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(detail)
                } actions: {
                    Button("Load Details Again") {
                        loadHistoryDetails(for: record.id)
                    }
                }
            case .loaded(let detail):
                // These are two representations of one selected record. The native
                // TabView owns peer-destination behavior and keeps raw output outside
                // the factual Form.
                TabView(selection: $historyInspectorTab) {
                    Tab(
                        "Details",
                        systemImage: "doc.text",
                        value: BuildHistoryInspectorTab.details)
                    {
                        historyDetailsTab(detail)
                    }
                    Tab(
                        "Log",
                        systemImage: "text.alignleft",
                        value: BuildHistoryInspectorTab.log)
                    {
                        historyLogPane(for: record)
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "No Build Selected",
                systemImage: "clock.arrow.circlepath",
                description: Text("Select a completed build, then choose Load Details to inspect it."))
        }
    }

    @ViewBuilder
    private func historyDetailsTab(_ detail: BuildxHistoryDetail) -> some View {
        if detail.hasReportableFields {
            historyDetailsForm(detail)
        } else {
            ContentUnavailableView(
                "No Build Details Reported",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Buildx returned this record without fields Morbstack can show."))
        }
    }

    private func historyDetailsForm(_ detail: BuildxHistoryDetail) -> some View {
        Form {
            if let builder = model.buildxCurrentBuilder,
               case .loaded = model.buildxCurrentBuilderState {
                Section("Active Builder") {
                    LabeledContent("Name", value: builder.name)
                    if let driver = builder.driver { LabeledContent("Driver", value: driver) }
                    if let lastActivity = builder.lastActivity {
                        LabeledContent("Last Activity", value: lastActivity)
                    }
                }
                if !builder.nodes.isEmpty {
                    Section("Builder Nodes") {
                        ForEach(builder.nodes) { node in
                            LabeledContent(node.name) {
                                Text(node.reportedFacts ?? "No state reported")
                                    .textSelection(.enabled)
                                    .lineLimit(3)
                            }
                        }
                    }
                }
            }
            if detail.name != nil || detail.reference != nil || detail.status != nil {
                Section("Build") {
                    if let name = detail.name { LabeledContent("Name", value: name) }
                    if let reference = detail.reference {
                        LabeledContent("Reference") {
                            Text(reference)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }
                    }
                    if let status = detail.status { LabeledContent("Status", value: status) }
                }
            }
            if detail.startedAt != nil || detail.completedAt != nil || detail.duration != nil {
                Section("Timing") {
                    if let startedAt = detail.startedAt { LabeledContent("Started", value: startedAt) }
                    if let completedAt = detail.completedAt { LabeledContent("Completed", value: completedAt) }
                    if let duration = detail.duration { LabeledContent("Duration", value: duration) }
                }
            }
            if detail.completedSteps != nil || detail.totalSteps != nil || detail.cachedSteps != nil {
                Section("Build Steps") {
                    if let completedSteps = detail.completedSteps {
                        LabeledContent("Completed", value: completedSteps)
                    }
                    if let totalSteps = detail.totalSteps { LabeledContent("Total", value: totalSteps) }
                    if let cachedSteps = detail.cachedSteps { LabeledContent("Cached", value: cachedSteps) }
                }
            }
            if detail.context != nil || detail.dockerfile != nil || detail.target != nil || !detail.platforms.isEmpty {
                Section("Inputs") {
                    if let context = detail.context {
                        LabeledContent("Context") {
                            Text(context)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                    }
                    if let dockerfile = detail.dockerfile {
                        LabeledContent("Dockerfile") {
                            Text(dockerfile)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                    }
                    if let target = detail.target { LabeledContent("Target", value: target) }
                    if !detail.platforms.isEmpty {
                        LabeledContent("Platforms", value: detail.platforms.joined(separator: ", "))
                    }
                }
            }
            if detail.vcsRepository != nil || detail.vcsRevision != nil || detail.keepsGitDirectory != nil {
                Section("Version Control") {
                    if let repository = detail.vcsRepository {
                        LabeledContent("Repository") {
                            Text(repository)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                    }
                    if let revision = detail.vcsRevision {
                        LabeledContent("Revision") {
                            Text(revision)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }
                    }
                    if let keepsGitDirectory = detail.keepsGitDirectory {
                        LabeledContent("Keep Git Directory", value: keepsGitDirectory ? "true" : "false")
                    }
                }
            }
            if let imageResolveMode = detail.imageResolveMode {
                Section("Configuration") {
                    LabeledContent("Image Resolve Mode", value: imageResolveMode)
                }
            }
            if !detail.materials.isEmpty {
                Section("Materials") {
                    ForEach(detail.materials) { material in
                        LabeledContent("URI") {
                            Text(material.uri)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                        if !material.digests.isEmpty {
                            LabeledContent("Digests") {
                                Text(material.digests.joined(separator: ", "))
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineLimit(3)
                            }
                        }
                    }
                }
            }
            if !detail.attachments.isEmpty {
                Section("Attachments") {
                    ForEach(detail.attachments) { attachment in
                        LabeledContent("Digest") {
                            Text(attachment.digest)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                        if let platform = attachment.platform {
                            LabeledContent("Platform", value: platform)
                        }
                        if let type = attachment.type { LabeledContent("Type", value: type) }
                    }
                }
            }
        }
        // Automatic system Form — see the clipping note on
        // `VolumesRootView.detailPane`; digests here are exactly the wide
        // monospaced values that overflow a columns-style grid.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func historyLogPane(for record: BuildxHistoryRecord) -> some View {
        switch historyLogState {
        case .idle:
            ContentUnavailableView {
                Label("Build Log Not Loaded", systemImage: "text.alignleft")
            } description: {
                Text("Load the raw output Buildx reports for this completed build.")
            } actions: {
                Button("Load Logs") {
                    loadHistoryLogs(for: record.id)
                }
            }
        case .loading:
            ContentUnavailableView {
                Label("Loading Build Log", systemImage: "text.alignleft")
            } description: {
                Text("Reading the selected Buildx log…")
            } actions: {
                ProgressView()
                    .controlSize(.small)
                Button("Cancel Loading") {
                    historyLogTask?.cancel()
                }
            }
        case .unavailable(let detail):
            ContentUnavailableView {
                Label("Build Log Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(detail)
            } actions: {
                Button("Load Logs Again") {
                    loadHistoryLogs(for: record.id)
                }
            }
        case .loaded(let log):
            if log.hasOutput {
                historyLogViewport(log, record: record)
            } else {
                ContentUnavailableView(
                    "No Log Output",
                    systemImage: "text.alignleft",
                    description: Text("Buildx returned no raw output for this build."))
            }
        }
    }

    private func historyLogViewport(_ log: BuildxHistoryLog, record: BuildxHistoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The log document's own bar. Injecting this command into the window
            // toolbar from a detail pane made the route's toolbar mutate with the
            // selection — the same churn defect the container inspector tabs had.
            HStack(spacing: 8) {
                if log.isTruncated {
                    Text("Showing the first 4 MB returned by Buildx.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    saveHistoryLog(log, for: record)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Save Visible Build Log")
                .help("Save the already-loaded bounded Buildx log")
            }
            .padding(8)
            Divider()
            ScrollView(.vertical) {
                Text(log.output)
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
            .accessibilityLabel("Build log")
        }
    }

    @MainActor
    private func saveHistoryLog(_ log: BuildxHistoryLog, for record: BuildxHistoryRecord) {
        guard log.hasOutput else { return }
        chooseHistoryLogExportDestination(
            for: BuildHistoryLogExport.document(log: log, record: record))
    }

    /// The document is constructed from one retained log value before `NSSavePanel`
    /// opens. That keeps save/retry separate from the explicit Buildx load operation and
    /// prevents a destination choice from reaching the builder a second time.
    @MainActor
    private func chooseHistoryLogExportDestination(for document: BuildHistoryLogExport.Document) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.suggestedFilename
        panel.allowedContentTypes = [UTType.log, UTType.plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.message = document.panelMessage
        panel.prompt = "Save"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try document.data.write(to: url, options: .atomic)
            pendingHistoryLogExport = nil
        } catch {
            pendingHistoryLogExport = document
            historyLogExportError = "Morbstack could not save the selected Buildx log to \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: Operations

    @MainActor
    private func loadHistoryDetails(for recordID: BuildxHistoryRecord.ID) {
        guard externalBuildOperationsAreAvailable, historySelection == recordID else { return }
        historyDetailTask?.cancel()
        resetHistoryLogs()
        historyDetailState = .loading
        let socketPath = MorbPaths.dockerSocket.path
        historyDetailTask = Task { @MainActor [recordID, socketPath] in
            do {
                let details = try await BuildxHistoryClient.inspect(
                    socketPath: socketPath,
                    recordID: recordID)
                guard !Task.isCancelled, historySelection == recordID else { return }
                historyDetailState = .loaded(details)
            } catch is CancellationError {
                guard historySelection == recordID else { return }
                historyDetailState = .idle
            } catch {
                guard !Task.isCancelled, historySelection == recordID else { return }
                historyDetailState = .unavailable(MorbErrorMessage.text(for: error))
            }
            if historySelection == recordID {
                historyDetailTask = nil
            }
        }
    }

    @MainActor
    private func resetHistoryDetails() {
        historyDetailTask?.cancel()
        historyDetailTask = nil
        historyDetailState = .idle
        historyInspectorTab = .details
        resetHistoryLogs()
    }

    @MainActor
    private func loadHistoryLogs(for recordID: BuildxHistoryRecord.ID) {
        guard externalBuildOperationsAreAvailable,
              historySelection == recordID,
              case .loaded = historyDetailState
        else { return }
        historyLogTask?.cancel()
        historyInspectorTab = .log
        historyLogState = .loading
        let socketPath = MorbPaths.dockerSocket.path
        historyLogTask = Task { @MainActor [recordID, socketPath] in
            do {
                let log = try await BuildxHistoryClient.logs(
                    socketPath: socketPath,
                    recordID: recordID)
                guard !Task.isCancelled,
                      historySelection == recordID,
                      case .loaded = historyDetailState
                else { return }
                historyLogState = .loaded(log)
            } catch is CancellationError {
                guard historySelection == recordID else { return }
                historyLogState = .idle
            } catch {
                guard !Task.isCancelled,
                      historySelection == recordID,
                      case .loaded = historyDetailState
                else { return }
                historyLogState = .unavailable(MorbErrorMessage.text(for: error))
            }
            if historySelection == recordID {
                historyLogTask = nil
            }
        }
    }

    @MainActor
    private func resetHistoryLogs() {
        historyLogTask?.cancel()
        historyLogTask = nil
        historyLogState = .idle
    }

    // MARK: Operations

    @MainActor
    private func refreshBuildCache() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await model.refreshBuildCache()
    }

    @MainActor
    private func refreshBuildHistory() async {
        guard externalBuildOperationsAreAvailable else { return }
        await model.refreshBuildHistory()
    }

    @MainActor
    private func refreshCurrentScope() async {
        if scope == .cache {
            await refreshBuildCache()
        } else if externalBuildOperationsAreAvailable {
            await refreshBuildHistory()
        }
    }

    @MainActor
    private func pruneUnusedCache() async {
        guard externalBuildOperationsAreAvailable, unusedCount > 0, !isPruning else { return }

        isPruning = true
        lastPrunedBytes = nil
        defer { isPruning = false }

        do {
            lastPrunedBytes = try await model.client.pruneBuildCache()
            await model.refreshBuildCache()
            await model.refreshDisk()
        } catch {
            pruneError = MorbErrorMessage.text(for: error)
        }
    }

    private func selectFirstVisibleRecordIfNeeded(for scope: BuildDataScope) {
        switch scope {
        case .cache:
            guard let selection else {
                self.selection = visible.first?.id
                return
            }
            if !visible.contains(where: { $0.id == selection }) {
                self.selection = visible.first?.id
            }
        case .history:
            guard let historySelection else {
                self.historySelection = visibleHistory.first?.id
                return
            }
            if !visibleHistory.contains(where: { $0.id == historySelection }) {
                self.historySelection = visibleHistory.first?.id
            }
        }
    }

    private var searchPrompt: String {
        scope == .cache ? "Description, type, ID" : "Name, status, ID"
    }

    // MARK: Active builder

    /// Builder listing is intentionally not an app feature. Docker documents
    /// `buildx ls` as loading every configured builder node; the bundled v0.36
    /// implementation does that concurrently, so an app-owned configuration changed
    /// outside Morbstack could make a seemingly read-only inventory contact a remote
    /// endpoint. This sheet reports only one explicitly requested active-builder
    /// inspection and offers the fixed local-default recovery below.
    private var builderSheet: some View {
        NavigationStack {
            Group {
                switch builderSheetState {
                case .idle:
                    ContentUnavailableView {
                        Label("Active Builder Not Checked", systemImage: "hammer")
                    } description: {
                        Text("Check the builder used by Morbstack’s next local build. Morbstack does not enumerate or select remote builders; if its private configuration was manually changed, Buildx may contact only that configured active builder.")
                    } actions: {
                        Button("Check Active Builder") { inspectActiveBuilder() }
                            .disabled(isHistoryRefreshing || isBuilding)
                        Button("Use Morbstack Default Builder…") {
                            showsDefaultBuilderConfirmation = true
                        }
                        .disabled(isSelectingMorbstackDefaultBuilder || isHistoryRefreshing || isBuilding)
                    }
                case .loading:
                    ContentUnavailableView {
                        Label("Checking Active Builder", systemImage: "hammer")
                    } description: {
                        Text("Morbstack is reading Buildx without the bootstrap flag, so opening this view does not start a builder.")
                    } actions: {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Checking active Buildx builder")
                    }
                case .loaded:
                    if let builder = builderSheetBuilder {
                        builderDetailsForm(builder)
                    } else {
                        ContentUnavailableView(
                            "Active Builder Unavailable",
                            systemImage: "exclamationmark.triangle",
                            description: Text("Buildx did not provide a builder record Morbstack can show."))
                    }
                case .unavailable(let detail):
                    ContentUnavailableView {
                        Label("Active Builder Unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(detail)
                    } actions: {
                        Button("Try Again") { inspectActiveBuilder() }
                            .disabled(isHistoryRefreshing || isBuilding)
                        Button("Use Morbstack Default Builder…") {
                            showsDefaultBuilderConfirmation = true
                        }
                        .disabled(isSelectingMorbstackDefaultBuilder || isHistoryRefreshing || isBuilding)
                    }
                }
            }
            .navigationTitle("Active Builder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showsBuilderSheet = false }
                        .accessibilityIdentifier("builds.builderSheet.done")
                        .disabled(isSelectingMorbstackDefaultBuilder)
                }
            }
            .confirmationDialog(
                "Use Morbstack’s Default Builder?",
                isPresented: $showsDefaultBuilderConfirmation,
                titleVisibility: .visible
            ) {
                Button("Use Local Builder") {
                    Task { await useMorbstackDefaultBuilder() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "Morbstack will run its bundled docker buildx use default command with the app’s "
                        + "private Buildx configuration and local Unix socket. This changes only the builder "
                        + "used by later Morbstack builds. It does not start or restart the engine or a builder, "
                        + "create or remove builders, use a shell Docker context, or connect Build Cloud.")
            }
            .alert(
                "Couldn’t Use Morbstack’s Default Builder",
                isPresented: Binding(
                    get: { defaultBuilderError != nil },
                    set: { if !$0 { defaultBuilderError = nil } })
            ) {
                Button("Try Again") {
                    defaultBuilderError = nil
                    showsDefaultBuilderConfirmation = true
                }
                Button("Cancel", role: .cancel) { defaultBuilderError = nil }
            } message: {
                Text(defaultBuilderError ?? "")
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .interactiveDismissDisabled(isSelectingMorbstackDefaultBuilder)
    }

    private func builderDetailsForm(_ builder: BuildxCurrentBuilder) -> some View {
        Form {
            Section("Active Builder") {
                LabeledContent("Name", value: builder.name)
                if let driver = builder.driver { LabeledContent("Driver", value: driver) }
                if let lastActivity = builder.lastActivity {
                    LabeledContent("Last Activity", value: lastActivity)
                }
            }
            if !builder.nodes.isEmpty {
                Section("Builder Nodes") {
                    ForEach(builder.nodes) { node in
                        LabeledContent(node.name) {
                            Text(node.reportedFacts ?? "No state reported")
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                    }
                }
            }
            Section {
                Button("Check Active Builder") { inspectActiveBuilder() }
                    .disabled(isSelectingMorbstackDefaultBuilder || isHistoryRefreshing || isBuilding)
            }
            Section("Morbstack Scope") {
                LabeledContent("Docker endpoint", value: "Morbstack local socket")
                LabeledContent("Buildx configuration", value: "Morbstack-managed")
                Text("This check uses Morbstack’s bundled Docker and Buildx tools. It does not inherit a shell Docker context, credential helper, or builder selection. If this private configuration was manually changed to select a remote builder, Buildx may contact that one active builder while reporting its state.")
                    .foregroundStyle(.secondary)
            }
            Section("Builder Selection") {
                Text("Morbstack offers only its local default builder. It does not list or select remote builders, create or remove builders, start a builder, or connect Build Cloud.")
                    .foregroundStyle(.secondary)
                Button("Use Morbstack Default Builder…") {
                    showsDefaultBuilderConfirmation = true
                }
                .disabled(isSelectingMorbstackDefaultBuilder || isBuilding || isHistoryRefreshing)
            }
        }
        .formStyle(.automatic)
    }

    @MainActor
    private func openBuilderSheet() {
        guard externalBuildOperationsAreAvailable else { return }
        if case .loaded = model.buildxCurrentBuilderState,
           let builder = model.buildxCurrentBuilder
        {
            builderSheetBuilder = builder
            builderSheetState = .loaded
        } else {
            builderSheetBuilder = nil
            builderSheetState = .idle
        }
        showsBuilderSheet = true
    }

    @MainActor
    private func inspectActiveBuilder() {
        guard externalBuildOperationsAreAvailable, !isSelectingMorbstackDefaultBuilder else { return }
        builderSheetTask?.cancel()
        builderSheetState = .loading
        builderSheetBuilder = nil
        let socketPath = MorbPaths.dockerSocket.path
        builderSheetTask = Task { @MainActor [socketPath] in
            do {
                let builder = try await BuildxHistoryClient.currentBuilder(socketPath: socketPath)
                guard !Task.isCancelled else { return }
                builderSheetBuilder = builder
                builderSheetState = .loaded
            } catch is CancellationError {
                guard !Task.isCancelled else { return }
                builderSheetState = .idle
            } catch {
                guard !Task.isCancelled else { return }
                builderSheetState = .unavailable(MorbErrorMessage.text(for: error))
            }
            if !Task.isCancelled {
                builderSheetTask = nil
            }
        }
    }

    @MainActor
    private func cancelActiveBuilderInspection() {
        builderSheetTask?.cancel()
        builderSheetTask = nil
        if case .loading = builderSheetState {
            builderSheetState = .idle
        }
    }

    @MainActor
    private func useMorbstackDefaultBuilder() async {
        guard externalBuildOperationsAreAvailable,
              !isSelectingMorbstackDefaultBuilder,
              !isBuilding,
              !isHistoryRefreshing
        else { return }
        cancelActiveBuilderInspection()
        isSelectingMorbstackDefaultBuilder = true
        defaultBuilderError = nil
        defer { isSelectingMorbstackDefaultBuilder = false }

        do {
            try await BuildxHistoryClient.useMorbstackDefaultBuilder(
                socketPath: MorbPaths.dockerSocket.path)
            await model.refreshBuildHistory()
            builderSheetBuilder = model.buildxCurrentBuilder
            builderSheetState = model.buildxCurrentBuilderState
        } catch is CancellationError {
            builderSheetState = .idle
        } catch {
            defaultBuilderError = MorbErrorMessage.text(for: error)
        }
    }

    // MARK: Local build workflow

    private var buildSheet: some View {
        NavigationStack {
            Group {
                switch buildPhase {
                case .configuration:
                    if externalBuildOperationsAreAvailable {
                        buildConfigurationForm
                    } else {
                        fixtureBuildOperationUnavailable
                    }
                case .running(let request):
                    buildProgressForm(for: request)
                case .succeeded(let request):
                    buildCompletionForm(for: request)
                case .cancelled(let request):
                    buildCancelledForm(for: request)
                case .failed(let request, let detail):
                    buildFailureForm(for: request, detail: detail)
                }
            }
            .navigationTitle("Build Image")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // One identifier across the Cancel Build/Done title swap, matching
                    // ContainerExecSheet's close-button convention.
                    if case .running = buildPhase {
                        Button("Cancel Build") { buildTask?.cancel() }
                            .accessibilityIdentifier("builds.buildSheet.close")
                    } else {
                        Button("Done") { showsBuildSheet = false }
                            .accessibilityIdentifier("builds.buildSheet.close")
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .interactiveDismissDisabled(isBuilding)
    }

    private var buildConfigurationForm: some View {
        Form {
            if !BuildRunner.isAvailable() {
                Section {
                    Label(
                        "The bundled Docker and Buildx tools are required to build from the app.",
                        systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Build Context") {
                LabeledContent("Folder") {
                    HStack {
                        Text(draftContextDirectory?.path ?? "No folder selected")
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(draftContextDirectory == nil ? .secondary : .primary)
                        Spacer(minLength: 12)
                        Button("Choose…") { showsContextPicker = true }
                    }
                }
                Text("The selected folder must contain a root-level Dockerfile.")
                    .foregroundStyle(.secondary)
            }
            Section("Image") {
                TextField("Tag (optional)", text: $draftTag)
                Text("Leave the tag blank to load an untagged local image. This workflow never pushes to a registry.")
                    .foregroundStyle(.secondary)
            }
            if let buildPreparationError {
                Section {
                    Text(buildPreparationError)
                        .foregroundStyle(.red)
                }
            }
            Section {
                Button("Build Image…") { prepareBuild() }
                    .disabled(draftContextDirectory == nil || !BuildRunner.isAvailable())
            } footer: {
                Text(
                    "Buildx creates the context using Docker's own .dockerignore and symlink rules, then "
                        + "streams real BuildKit status here. Dockerfile instructions can run arbitrary code in the VM. "
                        + "This initial workflow does not import Docker credential helpers, so private base images may fail.")
            }
        }
        .formStyle(.automatic)
    }

    private var fixtureBuildOperationUnavailable: some View {
        ContentUnavailableView {
            Label("Build Image Unavailable", systemImage: "hammer")
        } description: {
            Text(fixtureBuildOperationMessage)
        }
    }

    private func buildProgressForm(for request: LocalBuildRequest) -> some View {
        Form {
            Section("Build") {
                LabeledContent("Build Request", value: request.displayName)
                LabeledContent("Context") {
                    Text(request.contextDirectory.path)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                ProgressView("Building image…")
                Text("BuildKit does not provide a reliable total step count before it runs, so this progress indicator is indeterminate.")
                    .foregroundStyle(.secondary)
            }
            buildOutputSection(emptyMessage: "Waiting for BuildKit…")
            Section {
                Button("Cancel Build", role: .cancel) { buildTask?.cancel() }
            } footer: {
                Text("Cancel closes this build's client connection. Docker cancels a build when its client disconnects.")
            }
        }
        .formStyle(.automatic)
    }

    private func buildCompletionForm(for request: LocalBuildRequest) -> some View {
        Form {
            Section {
                Label("Build Completed", systemImage: "checkmark.circle")
                LabeledContent("Build Request", value: request.displayName)
                LabeledContent(
                    "Result",
                    value: request.tag.isEmpty
                        ? "Loaded an untagged image locally"
                        : "Loaded locally as \(request.tag)")
                Text(
                    "The result was loaded into Morbstack's local image store. Images and build-cache "
                        + "records update independently, so either list can still show its last successful refresh.")
                    .foregroundStyle(.secondary)
            }
            buildOutputSection(emptyMessage: "Buildx produced no displayable progress lines.")
            buildResultActions
        }
        .formStyle(.automatic)
    }

    private func buildCancelledForm(for request: LocalBuildRequest) -> some View {
        Form {
            Section {
                Label("Build Canceled", systemImage: "xmark.circle")
                LabeledContent("Build Request", value: request.displayName)
                Text("The client connection was closed. Refresh after retrying to inspect any cache BuildKit kept before cancellation.")
                    .foregroundStyle(.secondary)
            }
            buildOutputSection(emptyMessage: "Buildx produced no displayable progress lines before cancellation.")
            buildResultActions
        }
        .formStyle(.automatic)
    }

    private func buildFailureForm(for request: LocalBuildRequest, detail: String) -> some View {
        Form {
            Section {
                Label("Build Failed", systemImage: "exclamationmark.triangle")
                LabeledContent("Build Request", value: request.displayName)
                Text(detail)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            buildOutputSection(emptyMessage: "Buildx did not produce a displayable progress line before it failed.")
            buildResultActions
        }
        .formStyle(.automatic)
    }

    /// A bounded, literal view of the raw-JSON messages observed for this one local
    /// build. The terminal forms keep it visible for recovery instead of replacing a
    /// BuildKit diagnostic with app-authored prose or silently discarding it on exit.
    @ViewBuilder
    private func buildOutputSection(emptyMessage: String) -> some View {
        Section("Observed Buildx Output") {
            if buildEvents.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(buildEvents.suffix(12)) { event in
                    Text(event.message)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(event.isError ? .red : .primary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                if buildEvents.count > 12 {
                    Text("Showing the latest 12 of \(buildEvents.count) observed Buildx messages.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var buildResultActions: some View {
        Section {
            Button("Build Again") {
                guard let request = currentBuildRequest else { return }
                startBuild(request)
            }
            Button("Build Another Image") { resetBuildSheet() }
        }
    }

    private var currentBuildRequest: LocalBuildRequest? {
        switch buildPhase {
        case .configuration: return nil
        case .running(let request), .succeeded(let request), .cancelled(let request), .failed(let request, _):
            return request
        }
    }

    private var isBuilding: Bool {
        if case .running = buildPhase { return true }
        return false
    }

    private func prepareBuild() {
        guard externalBuildOperationsAreAvailable, let draftContextDirectory else { return }
        do {
            pendingBuildRequest = try LocalBuildRequest(contextDirectory: draftContextDirectory, tag: draftTag)
            buildPreparationError = nil
        } catch {
            buildPreparationError = MorbErrorMessage.text(for: error)
        }
    }

    private func startBuild(_ request: LocalBuildRequest) {
        guard externalBuildOperationsAreAvailable else { return }
        buildEvents = []
        buildPreparationError = nil
        buildPhase = .running(request)
        buildTask?.cancel()
        buildTask = Task {
            do {
                try await BuildRunner.run(request, socketPath: model.client.socketPath) { event in
                    Task { @MainActor in appendBuildEvent(event) }
                }
                guard !Task.isCancelled else { return }
                buildPhase = .succeeded(request)
                await model.refreshAll()
                await model.refreshBuildCache()
                await model.refreshDisk()
            } catch is CancellationError {
                buildPhase = .cancelled(request)
                await model.refreshAll()
                await model.refreshBuildCache()
                await model.refreshDisk()
            } catch {
                buildPhase = .failed(request, MorbErrorMessage.text(for: error))
                await model.refreshBuildCache()
                await model.refreshDisk()
            }
            buildTask = nil
        }
    }

    private func appendBuildEvent(_ event: BuildProgressEvent) {
        guard isBuilding else { return }
        buildEvents.append(event)
        // Progress can be arbitrarily verbose. Keep a useful bounded recovery window
        // and state the displayed limit in the Form rather than passing it off as a
        // complete build log; completed-build logs remain the explicit inspector read.
        if buildEvents.count > 128 { buildEvents.removeFirst(buildEvents.count - 128) }
    }

    private func resetBuildSheetIfIdle() {
        guard !isBuilding else { return }
        resetBuildSheet()
    }

    private func resetBuildSheet() {
        buildTask?.cancel()
        buildTask = nil
        buildPhase = .configuration
        buildEvents = []
        pendingBuildRequest = nil
        buildPreparationError = nil
    }

}

private enum BuildSheetPhase: Equatable {
    case configuration
    case running(LocalBuildRequest)
    case succeeded(LocalBuildRequest)
    case cancelled(LocalBuildRequest)
    case failed(LocalBuildRequest, String)
}
