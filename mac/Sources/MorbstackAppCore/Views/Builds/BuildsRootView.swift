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
        parts.append(Formatters.bytesString(BuildCacheList.storageSize(records)))
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
        switch model.buildHistoryState {
        case .idle:
            return "Buildx history not loaded"
        case .loading:
            return "Loading Buildx history…"
        case .loaded:
            let count = model.buildHistory.count
            return count == 0
                ? "No completed builds"
                : "\(count) completed build\(count == 1 ? "" : "s")"
        case .unavailable:
            return "Buildx history unavailable"
        }
    }

    private var isHistoryRefreshing: Bool {
        if case .loading = model.buildHistoryState { return true }
        return false
    }

    private var isRefreshingCurrentScope: Bool {
        scope == .cache ? isRefreshing : isHistoryRefreshing
    }

    var body: some View {
        content
            .navigationTitle("Builds")
            .navigationSubtitle(subtitle)
            .searchable(text: $query, placement: .toolbar, prompt: searchPrompt)
            .toolbar { toolbarContent }
            .sheet(isPresented: $showsBuildSheet, onDismiss: resetBuildSheetIfIdle) {
                buildSheet
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
            }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(id: "builds.scope", placement: .automatic) {
            Picker("Build data", selection: $scope) {
                Text("Cache").tag(BuildDataScope.cache)
                Text("History").tag(BuildDataScope.history)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Build data")
            .help("Choose BuildKit cache or Buildx history")
        }
        if scope == .cache {
            ToolbarItem(id: "builds.start", placement: .primaryAction) {
                Button {
                    showsBuildSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Build an image")
                .help("Build an image from a local Dockerfile")
                .disabled(isPruning)
            }
        }
        ToolbarItem(id: "builds.refresh", placement: .secondaryAction) {
            Button {
                Task { await refreshCurrentScope() }
            } label: {
                if isRefreshingCurrentScope {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing \(scope == .cache ? "build cache" : "Buildx history")")
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .accessibilityLabel(scope == .cache ? "Refresh build cache" : "Refresh Buildx history")
            .help(scope == .cache ? "Refresh the BuildKit cache records" : "Refresh completed builds reported by Buildx")
            .disabled(isRefreshingCurrentScope || isPruning)
        }
        if scope == .cache {
            ToolbarItem(id: "builds.prune", placement: .secondaryAction) {
                Button(role: .destructive) {
                    showsPruneConfirmation = true
                } label: {
                    if isPruning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "trash")
                    }
                }
                .accessibilityLabel(isPruning ? "Pruning unused build cache" : "Prune unused build cache")
                .help(
                    unusedCount == 0
                        ? "No unused build cache to prune"
                        : "Prune \(unusedCount) unused cache record\(unusedCount == 1 ? "" : "s")")
                .disabled(unusedCount == 0 || isPruning || isRefreshing)
            }
        }
        if scope == .cache ? !records.isEmpty : !model.buildHistory.isEmpty {
            ToolbarItem(id: "builds.inspector", placement: .secondaryAction) {
                Button {
                    showsInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .accessibilityLabel(showsInspector ? "Hide inspector" : "Show inspector")
                .help(showsInspector ? "Hide the inspector" : "Show the inspector")
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if scope == .cache {
            cacheContent
        } else {
            historyContent
        }
    }

    @ViewBuilder
    private var cacheContent: some View {
        if records.isEmpty {
            ContentUnavailableView {
                Label("No Build Cache", systemImage: "hammer")
            } description: {
                Text("Build an image to create local BuildKit cache records.")
            } actions: {
                Button {
                    showsBuildSheet = true
                } label: {
                    Label("Build Image", systemImage: "plus")
                }
                Button {
                    Task { await refreshBuildCache() }
                } label: {
                    Label(isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshing)
            }
        } else if visible.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            table
                .inspector(isPresented: $showsInspector) {
                    detailPane
                        .inspectorColumnWidth(
                            min: 340,
                            ideal: 400,
                            max: 460)
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
                Text(record.lastUsedAt.map { Formatters.compactDuration(since: $0) } ?? "Never")
                    .monospacedDigit()
                    .help(record.lastUsedAt.map(Formatters.absoluteDate) ?? "Never used")
            }
            .width(min: 72, ideal: 88, max: 120)
        }
        .tableStyle(.automatic)
        .contextMenu(forSelectionType: BuildCacheRecord.ID.self) { ids in
            if let id = ids.first, let record = records.first(where: { $0.id == id }) {
                Button("Copy Description") { MorbPasteboard.copy(record.description) }
                Button("Copy Record ID") { MorbPasteboard.copy(record.id) }
            }
        }
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
            }
        case .loading:
            ContentUnavailableView {
                Label("Loading Build History", systemImage: "clock.arrow.circlepath")
            } description: {
                ProgressView("Checking the active Buildx builder…")
            }
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
                .disabled(isHistoryRefreshing)
            }
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
                    .disabled(isHistoryRefreshing)
                }
            } else if visibleHistory.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                historyTable
                    .inspector(isPresented: $showsInspector) {
                        historyDetailPane
                            .inspectorColumnWidth(
                                min: 340,
                                ideal: 400,
                                max: 460)
                    }
            }
        }
    }

    private func descriptionCell(_ record: BuildCacheRecord) -> some View {
        Text(record.description)
            .font(.system(.callout, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.tail)
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
            }
            TableColumn("Status", sortUsing: BuildHistoryComparator(key: .status)) { record in
                Text(record.status)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 90, ideal: 120, max: 180)
            TableColumn("Created", sortUsing: BuildHistoryComparator(key: .createdAt)) { record in
                Text(record.createdAt.map { Formatters.compactDuration(since: $0) } ?? "Not reported")
                    .monospacedDigit()
                    .help(record.createdAt.map(Formatters.absoluteDate) ?? "Buildx did not report a creation time")
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
        .contextMenu(forSelectionType: BuildxHistoryRecord.ID.self) { ids in
            if let id = ids.first, let record = model.buildHistory.first(where: { $0.id == id }) {
                Button("Copy Build ID") { MorbPasteboard.copy(record.id) }
            }
        }
    }

    // MARK: Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let record = selectedRecord {
            Form {
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
                    LabeledContent("Storage", value: record.shared ? "Shared" : "Not shared")
                }
            }
            .formStyle(.columns)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView(
                "No Record Selected",
                systemImage: "hammer",
                description: Text("Pick a cache record to see what produced it and when it was last used."))
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
                        historyLogPane(for: record.id)
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
        .formStyle(.columns)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func historyLogPane(for recordID: BuildxHistoryRecord.ID) -> some View {
        switch historyLogState {
        case .idle:
            ContentUnavailableView {
                Label("Build Log Not Loaded", systemImage: "text.alignleft")
            } description: {
                Text("Load the raw output Buildx reports for this completed build.")
            } actions: {
                Button("Load Logs") {
                    loadHistoryLogs(for: recordID)
                }
            }
        case .loading:
            ContentUnavailableView {
                Label("Loading Build Log", systemImage: "text.alignleft")
            } description: {
                ProgressView("Reading the selected Buildx log…")
            } actions: {
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
                    loadHistoryLogs(for: recordID)
                }
            }
        case .loaded(let log):
            if log.hasOutput {
                historyLogViewport(log)
            } else {
                ContentUnavailableView(
                    "No Log Output",
                    systemImage: "text.alignleft",
                    description: Text("Buildx returned no raw output for this build."))
            }
        }
    }

    private func historyLogViewport(_ log: BuildxHistoryLog) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if log.isTruncated {
                Text("Showing the first 4 MB returned by Buildx.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                Divider()
            }
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

    // MARK: Operations

    @MainActor
    private func loadHistoryDetails(for recordID: BuildxHistoryRecord.ID) {
        guard historySelection == recordID else { return }
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
        guard historySelection == recordID,
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
        await model.refreshBuildHistory()
    }

    @MainActor
    private func refreshCurrentScope() async {
        if scope == .cache {
            await refreshBuildCache()
        } else {
            await refreshBuildHistory()
        }
    }

    @MainActor
    private func pruneUnusedCache() async {
        guard unusedCount > 0, !isPruning else { return }

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

    // MARK: Local build workflow

    private var buildSheet: some View {
        NavigationStack {
            Group {
                switch buildPhase {
                case .configuration:
                    buildConfigurationForm
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
                    if case .running = buildPhase {
                        Button("Cancel Build") { buildTask?.cancel() }
                    } else {
                        Button("Done") { showsBuildSheet = false }
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

    private func buildProgressForm(for request: LocalBuildRequest) -> some View {
        Form {
            Section("Build") {
                LabeledContent("Image", value: request.displayName)
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
            Section("Recent Output") {
                if buildEvents.isEmpty {
                    Text("Waiting for BuildKit…")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(buildEvents.suffix(8)) { event in
                        Text(event.message)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(event.isError ? .red : .primary)
                            .lineLimit(2)
                    }
                }
            }
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
                LabeledContent("Image", value: request.displayName)
                Text(
                    "The result was loaded into Morbstack's local image store. Images and build-cache "
                        + "records update independently, so either list can still show its last successful refresh.")
                    .foregroundStyle(.secondary)
            }
            buildResultActions
        }
        .formStyle(.automatic)
    }

    private func buildCancelledForm(for request: LocalBuildRequest) -> some View {
        Form {
            Section {
                Label("Build Canceled", systemImage: "xmark.circle")
                LabeledContent("Image", value: request.displayName)
                Text("The client connection was closed. Refresh after retrying to inspect any cache BuildKit kept before cancellation.")
                    .foregroundStyle(.secondary)
            }
            buildResultActions
        }
        .formStyle(.automatic)
    }

    private func buildFailureForm(for request: LocalBuildRequest, detail: String) -> some View {
        Form {
            Section {
                Label("Build Failed", systemImage: "exclamationmark.triangle")
                LabeledContent("Image", value: request.displayName)
                Text(detail)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            buildResultActions
        }
        .formStyle(.automatic)
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
        guard let draftContextDirectory else { return }
        do {
            pendingBuildRequest = try LocalBuildRequest(contextDirectory: draftContextDirectory, tag: draftTag)
            buildPreparationError = nil
        } catch {
            buildPreparationError = MorbErrorMessage.text(for: error)
        }
    }

    private func startBuild(_ request: LocalBuildRequest) {
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
        if buildEvents.count > 32 { buildEvents.removeFirst(buildEvents.count - 32) }
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
