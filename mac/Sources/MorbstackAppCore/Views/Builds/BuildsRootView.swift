// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The Builds screen — BuildKit's cache, which is the closest thing to build history the
// engine exposes.
//
// Docker's classic builder has no notion of "a build" as a first-class object: it keeps
// a graph of cache records shared across every build that has ever run against the
// engine, and `/system/df` is the one endpoint that lists them. There is no per-record
// delete in the Docker Engine API — only `POST /build/prune`, which removes every
// unused record at once — so this screen can inspect the cache in detail but can only
// act on it as a whole, the same constraint the Disk screen's build-cache row already
// lives with.
//
// What is NOT here, and why: a build's step-by-step log, its duration, and which image
// tag it produced are BuildKit solver-session data that `docker buildx history` reads
// from BuildKit's own `~/.docker/buildx/history` store, over a gRPC API this app has no
// client for — `/system/df`'s cache records are shared across every build that ever
// ran and do not group into "builds." If that history is wanted, the backend work is a
// `buildx history`-shaped client added to `MorbstackKit`; this screen reads real data
// (`AppModel.buildCache`, backed by `DockerClient.buildCacheRecords()`) rather than a
// fixture, because unlike Kubernetes' cluster state, the cache list genuinely is
// available today — it was just being discarded after `diskUsage()` folded it into a
// single total.

import SwiftUI

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

    static func totalSize(_ records: [BuildCacheRecord]) -> Int64 {
        records.reduce(Int64(0)) { $0 + max(0, $1.size) }
    }

    static func unused(_ records: [BuildCacheRecord]) -> [BuildCacheRecord] {
        records.filter { !$0.inUse }
    }
}

// MARK: - Root

struct BuildsRootView: View {

    let model: AppModel

    @State private var query = ""
    @State private var sortOrder: [BuildComparator] = [BuildComparator(key: .size, order: .reverse)]
    @State private var selection: BuildCacheRecord.ID?
    @State private var showsInspector = true
    @State private var isRefreshing = false
    @State private var isPruning = false
    @State private var showsPruneConfirmation = false
    @State private var pruneError: String?
    @State private var lastPrunedBytes: Int64?

    private var records: [BuildCacheRecord] { model.buildCache }

    private var visible: [BuildCacheRecord] {
        records.filter { BuildCacheList.matches($0, query: query) }.sorted(using: sortOrder)
    }

    private var unusedCount: Int { BuildCacheList.unused(records).count }

    private var subtitle: String {
        if isPruning { return "Pruning unused cache…" }

        guard !records.isEmpty else {
            guard let lastPrunedBytes else { return "No cache" }
            return lastPrunedBytes > 0
                ? "No cache · \(Formatters.bytesString(lastPrunedBytes)) reclaimed"
                : "No cache · No space reclaimed"
        }
        var parts = ["\(records.count) record\(records.count == 1 ? "" : "s")"]
        parts.append(Formatters.bytesString(BuildCacheList.totalSize(records)))
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

    var body: some View {
        content
            .navigationTitle("Builds")
            .navigationSubtitle(subtitle)
            .searchable(text: $query, placement: .toolbar, prompt: "Description, type, ID")
            .toolbar { toolbarContent }
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
                selectFirstVisibleRecordIfNeeded()
            }
            .onChange(of: records) { _, _ in
                selectFirstVisibleRecordIfNeeded()
            }
            .onChange(of: selection) { _, newValue in
                if newValue != nil { showsInspector = true }
            }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(id: "builds.refresh", placement: .primaryAction) {
            Button {
                Task { await refreshBuildCache() }
            } label: {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing build cache")
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .accessibilityLabel("Refresh build cache")
            .help("Refresh the BuildKit cache records")
            .disabled(isRefreshing || isPruning)
        }
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
        if !records.isEmpty {
            ToolbarItem(id: "builds.inspector", placement: .primaryAction) {
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
        if records.isEmpty {
            ContentUnavailableView {
                Label("No Build Cache", systemImage: "hammer")
            } description: {
                Text("Build an image, then refresh to see the BuildKit cache it created.")
            } actions: {
                Button {
                    copyBuildCommand()
                } label: {
                    Label("Copy Build Command", systemImage: "doc.on.doc")
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
                            min: 280,
                            ideal: 340,
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
        } primaryAction: { ids in
            if let id = ids.first { selection = id }
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
                    if record.shared {
                        LabeledContent("Shared") {
                            Text("Counted once for each image that references it")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Actions") {
                    Button {
                        MorbPasteboard.copy(record.id)
                    } label: {
                        Label("Copy Record ID", systemImage: "doc.on.doc")
                    }
                    if !record.inUse {
                        LabeledContent("Removal", value: "All unused cache")
                        Text(
                            "Docker can only prune every unused cache record at once; it cannot remove the "
                                + "reviewed record by ID. Use Prune Unused Cache to run that engine-wide cleanup.")
                            .foregroundStyle(.secondary)
                    }
                }
                cacheMaintenance
            }
        } else {
            ContentUnavailableView(
                "No Record Selected",
                systemImage: "hammer",
                description: Text("Pick a cache record to see what produced it and when it was last used."))
        }
    }

    // MARK: Operations

    @MainActor
    private func refreshBuildCache() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await model.refreshBuildCache()
    }

    @ViewBuilder
    private var cacheMaintenance: some View {
        Section("Cache Maintenance") {
            if isPruning {
                ProgressView("Pruning unused cache…")
            }

            Button("Prune Unused Cache…", role: .destructive) {
                showsPruneConfirmation = true
            }
            .disabled(unusedCount == 0 || isPruning || isRefreshing)

            if let lastPrunedBytes {
                LabeledContent("Last Prune") {
                    Text(
                        lastPrunedBytes > 0
                            ? "\(Formatters.bytesString(lastPrunedBytes)) reclaimed"
                            : "No space reclaimed")
                }
            }
        } footer: {
            if unusedCount > 0 {
                Text(
                    "Docker decides which unused cache records are eligible when pruning begins. "
                        + "The list is for review only; individual cache records cannot be deleted.")
            } else {
                Text("There are no unused cache records to prune.")
            }
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

    private func copyBuildCommand() {
        MorbPasteboard.copy("docker build -t my-image .")
    }

    private func selectFirstVisibleRecordIfNeeded() {
        guard let selection else {
            self.selection = visible.first?.id
            return
        }
        if !visible.contains(where: { $0.id == selection }) {
            self.selection = visible.first?.id
        }
    }

}
