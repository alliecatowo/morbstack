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

enum TrackFBuildSortKey: String, CaseIterable, Hashable {
    case description, type, size, lastUsed
}

struct TrackFBuildComparator: SortComparator {
    var key: TrackFBuildSortKey
    var order: SortOrder = .forward

    func compare(_ lhs: BuildCacheRecord, _ rhs: BuildCacheRecord) -> ComparisonResult {
        let result: ComparisonResult
        switch key {
        case .description:
            result = trackCCompareStrings(lhs.description, rhs.description)
        case .type:
            result = lhs.type == rhs.type
                ? trackCCompareStrings(lhs.description, rhs.description)
                : trackCCompareStrings(lhs.type, rhs.type)
        case .size:
            result = lhs.size == rhs.size
                ? trackCCompareStrings(lhs.description, rhs.description)
                : (lhs.size < rhs.size ? .orderedAscending : .orderedDescending)
        case .lastUsed:
            let left = lhs.lastUsedAt ?? .distantPast, right = rhs.lastUsedAt ?? .distantPast
            result = left == right
                ? trackCCompareStrings(lhs.description, rhs.description)
                : trackCCompareDate(left, right)
        }
        return order == .forward ? result : result.reversed
    }
}

enum TrackFBuildList {
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
    @State private var sortOrder: [TrackFBuildComparator] = [TrackFBuildComparator(key: .size, order: .reverse)]
    @State private var selection: BuildCacheRecord.ID?
    @State private var showsInspector = true
    @State private var busy = false
    @State private var toast: TrackCToast?

    private var records: [BuildCacheRecord] { model.buildCache }

    private var visible: [BuildCacheRecord] {
        records.filter { TrackFBuildList.matches($0, query: query) }.sorted(using: sortOrder)
    }

    private var unusedCount: Int { TrackFBuildList.unused(records).count }
    private var unusedBytes: Int64 { TrackFBuildList.totalSize(TrackFBuildList.unused(records)) }

    private var subtitle: String {
        guard !records.isEmpty else { return "No cache" }
        var parts = ["\(records.count) record\(records.count == 1 ? "" : "s")"]
        parts.append(Formatters.bytesString(TrackFBuildList.totalSize(records)))
        if unusedCount > 0 { parts.append("\(unusedCount) unused") }
        return parts.joined(separator: " · ")
    }

    private var selectedRecord: BuildCacheRecord? {
        guard let selection else { return nil }
        return records.first { $0.id == selection }
    }

    var body: some View {
        content
            .morbScreen(title: "Builds", subtitle: subtitle, edge: .hard)
            .searchable(text: $query, placement: .toolbar, prompt: "Description, type, ID")
            .toolbar { toolbarContent }
            .trackCToast($toast)
            .task {
                if selection == nil { selection = visible.first?.id }
            }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(id: "builds.pruneUnused", placement: MorbToolbarGroup.secondary) {
            Button {
                Task { await pruneUnused() }
            } label: {
                Label("Prune Unused Cache", systemImage: "trash")
            }
            .disabled(unusedCount == 0 || busy)
            .help(unusedCount == 0
                  ? "Every cache record is in use"
                  : "Remove \(unusedCount) unused record\(unusedCount == 1 ? "" : "s"), freeing about \(Formatters.bytesString(unusedBytes))")
        }
        MorbInspectorToggle(id: "builds.inspector", isPresented: $showsInspector)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if records.isEmpty {
            MorbEmptyState(
                "No Build Cache",
                systemImage: "hammer",
                description: "BuildKit fills this in the first time an image is built against Morbstack's engine — "
                    + "point docker build or docker compose build at it and cache records appear here."
            ) {
                Button {
                    Task { await model.refreshBuildCache() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .morbButton(.standard)
            }
        } else if visible.isEmpty {
            MorbNoMatches(query: query)
        } else {
            table
                .inspector(isPresented: $showsInspector) {
                    detailPane
                        .inspectorColumnWidth(
                            min: Theme.inspectorMinWidth,
                            ideal: Theme.inspectorWidth,
                            max: 460)
                }
        }
    }

    private var table: some View {
        Table(visible, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Description", sortUsing: TrackFBuildComparator(key: .description)) { record in
                descriptionCell(record)
                    .frame(height: Theme.rowStandard, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            TableColumn("Type", sortUsing: TrackFBuildComparator(key: .type)) { record in
                Text(record.type)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(height: Theme.rowStandard, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 90, ideal: 120, max: 160)
            TableColumn("Size", sortUsing: TrackFBuildComparator(key: .size)) { record in
                MorbNumber(Formatters.bytesString(record.size), tone: .primary, font: .callout)
                    .frame(height: Theme.rowStandard, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 72, ideal: 88, max: 120)
            TableColumn("Last Used", sortUsing: TrackFBuildComparator(key: .lastUsed)) { record in
                MorbNumber(
                    record.lastUsedAt.map { Formatters.compactDuration(since: $0) } ?? "never",
                    font: .callout)
                    .frame(height: Theme.rowStandard, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(record.lastUsedAt.map(Formatters.absoluteDate) ?? "Never used")
            }
            .width(min: 72, ideal: 88, max: 120)
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds()
        .contextMenu(forSelectionType: BuildCacheRecord.ID.self) { ids in
            if let id = ids.first, let record = records.first(where: { $0.id == id }) {
                Button("Copy Description") { trackCCopy(record.description) }
                Button("Copy Record ID") { trackCCopy(record.id) }
            }
        } primaryAction: { ids in
            if let id = ids.first { selection = id }
        }
    }

    private func descriptionCell(_ record: BuildCacheRecord) -> some View {
        HStack(spacing: Theme.space2) {
            MorbStatusDot(tone: record.inUse ? .running : .idle)
            Text(record.description)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            if record.shared {
                MorbChip("shared", rank: .quiet)
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
                    LabeledContent("Status") {
                        MorbStatusBadge(
                            tone: record.inUse ? .running : .idle,
                            title: record.inUse ? "In Use" : "Unused",
                            detail: Formatters.bytesString(record.size),
                            filled: false)
                    }
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
                            Text("Counted once across every image that references it")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView(
                "No Record Selected",
                systemImage: "hammer",
                description: Text("Pick a cache record to see what produced it and when it was last used."))
        }
    }

    // MARK: Operations

    @MainActor
    private func pruneUnused() async {
        busy = true
        defer { busy = false }
        do {
            let reclaimed = try await model.client.pruneBuildCache()
            toast = reclaimed > 0
                ? .success("Reclaimed \(Formatters.bytesString(reclaimed))", detail: "Unused cache removed")
                : .info("Nothing to reclaim", detail: "Every record was still in use")
            await model.refreshBuildCache()
        } catch {
            toast = .failure("Prune failed", detail: trackCErrorText(error))
        }
    }
}
