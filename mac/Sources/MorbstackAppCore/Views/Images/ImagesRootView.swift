// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The Images screen: what is on disk, what is pulling, and what can go.
//
// A real `Table` — sortable columns, a real `Dangling` section instead of a floating
// footer band — replaces the hand-rolled grid, the pull field moves off a second bar of
// its own and into the toolbar's `+` control, and a detail pane carries the digest, the
// full tag list and the architecture advice that used to live in a popover. The pane is a
// real `.inspector(isPresented:)` trailing column — see the note in `VolumesRootView`
// about why the old `HSplitView` was the screenshot harness talking, not the design.

import AppKit
import SwiftUI

// MARK: - Table sort
//
// `TrackCImageSortKey` and `TrackCImageList` (search, sort, section split, pull-log
// collapsing) live in `TrackCImageList.swift`, unchanged — `TrackCResourceListTests`
// covers them directly. This file adds only the `Table`-facing comparator.

/// Table sort, keyed by ``TrackCImageSortKey``.
struct TrackCImageComparator: SortComparator {
    var key: TrackCImageSortKey
    var order: SortOrder = .forward

    func compare(_ lhs: ImageSummary, _ rhs: ImageSummary) -> ComparisonResult {
        let result: ComparisonResult
        switch key {
        case .repository:
            result = lhs.repository == rhs.repository
                ? trackCCompareStrings(lhs.tag, rhs.tag)
                : trackCCompareStrings(lhs.repository, rhs.repository)
        case .tag:
            result = lhs.tag == rhs.tag
                ? trackCCompareStrings(lhs.repository, rhs.repository)
                : trackCCompareStrings(lhs.tag, rhs.tag)
        case .size:
            result = lhs.size == rhs.size
                ? trackCCompareStrings(lhs.repository, rhs.repository)
                : (lhs.size < rhs.size ? .orderedAscending : .orderedDescending)
        case .created:
            result = lhs.createdAt == rhs.createdAt
                ? trackCCompareStrings(lhs.repository, rhs.repository)
                : trackCCompareDate(lhs.createdAt, rhs.createdAt)
        case .used:
            result = lhs.containersUsing == rhs.containersUsing
                ? trackCCompareStrings(lhs.repository, rhs.repository)
                : trackCCompareInt(lhs.containersUsing, rhs.containersUsing)
        }
        return order == .forward ? result : result.reversed
    }
}

// MARK: - Removal confirmation

/// A pending "are you sure" for one image.
private struct TrackCImageRemoval: Identifiable {
    var image: ImageSummary
    var id: String { image.id }

    var inUse: Bool { image.containersUsing > 0 }
    var label: String { image.repoTags.first ?? image.shortID }
}

// MARK: - Root

struct ImagesRootView: View {

    let model: AppModel

    @State private var query = ""
    @State private var sortOrder: [TrackCImageComparator] = [TrackCImageComparator(key: .created, order: .reverse)]
    @State private var selection: ImageSummary.ID?

    @State private var pullReference = ""
    @State private var pullLines: [String] = []
    @State private var isPulling = false
    @State private var showingPull = false
    /// Whether the trailing inspector column is open. SwiftUI restores this across
    /// launches for a trailing-column inspector, so it is not persisted here.
    @State private var showsInspector = true

    @State private var removal: TrackCImageRemoval?
    @State private var busy = false
    @State private var toast: TrackCToast?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sections: (tagged: [ImageSummary], dangling: [ImageSummary]) {
        let key = sortOrder.first?.key ?? .created
        let ascending = (sortOrder.first?.order ?? .reverse) == .forward
        return TrackCImageList.sections(images: model.images, query: query, sortKey: key, ascending: ascending)
    }

    private var subtitle: String {
        let total = TrackCImageList.totalSize(model.images)
        let dangling = model.images.filter(\.isDangling).count
        var parts = ["\(model.images.count) image\(model.images.count == 1 ? "" : "s")"]
        parts.append(Formatters.bytesString(total))
        if dangling > 0 { parts.append("\(dangling) dangling") }
        let nonNative = TrackCImageArch.nonNativeCount(model.images)
        if nonNative > 0 { parts.append("\(nonNative) not native") }
        return parts.joined(separator: " · ")
    }

    private var danglingBytes: Int64 {
        TrackCImageList.totalSize(model.images.filter { $0.isDangling && $0.containersUsing <= 0 })
    }

    private var selectedImage: ImageSummary? {
        guard let selection else { return nil }
        return model.images.first { $0.id == selection }
    }

    var body: some View {
        content
            .morbScreen(title: "Images", subtitle: subtitle, edge: .hard)
            .searchable(text: $query, placement: .toolbar, prompt: "Repository, tag, digest")
            .toolbar { toolbarContent }
            .trackCToast($toast)
            .alert(
                removal.map { $0.inUse ? "\($0.label) is in use" : "Remove \($0.label)?" } ?? "",
                isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
                presenting: removal
            ) { target in
                Button("Cancel", role: .cancel) {}
                Button(target.inUse ? "Force Remove" : "Remove", role: .destructive) {
                    Task { await remove(target.image, force: target.inUse) }
                }
            } message: { target in
                if target.inUse {
                    Text(
                        """
                        \(target.image.containersUsing) container\(target.image.containersUsing == 1 ? "" : "s") \
                        still reference this image. Forcing the removal untags it now; the layers are only \
                        freed once the last container using them is gone.
                        """)
                } else {
                    Text("This frees \(Formatters.bytesString(target.image.size)). Any container created from it later will have to pull it again.")
                }
            }
            .onDeleteCommand {
                guard let selection, let image = model.images.first(where: { $0.id == selection }) else { return }
                removal = TrackCImageRemoval(image: image)
            }
            // The platform for one image, fetched when it is selected. `GET /images/json`
            // already carries it for anything pulled from a multi-arch index; this only
            // fires for the remainder — locally built images, mostly.
            .task(id: selection) {
                guard let selection else { return }
                await model.resolveArchitecture(for: selection)
            }
            // Selects the first row so the inspector opens with something to show — see
            // the identical note in `VolumesRootView`.
            .task {
                if selection == nil { selection = sections.tagged.first?.id ?? sections.dangling.first?.id }
            }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(id: "images.pull", placement: MorbToolbarGroup.actions) {
            Button {
                showingPull = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Pull an image")
            .help("Pull an image")
            .popover(isPresented: $showingPull, arrowEdge: .bottom) { pullPopover }
        }
        // Center, not trailing: this is the screen's secondary action, so it is the one
        // that should yield first when the inspector opens and the toolbar tightens —
        // the pull button and the inspector toggle are what must stay reachable at
        // every width.
        ToolbarItem(id: "images.pruneDangling", placement: MorbToolbarGroup.secondary) {
            pruneDanglingButton
        }
        MorbInspectorToggle(id: "images.inspector", isPresented: $showsInspector)
    }

    @ViewBuilder
    private var pruneDanglingButton: some View {
        let count = model.images.filter { $0.isDangling && $0.containersUsing <= 0 }.count
        // Symbol only, no forced text — a toolbar item that always shows both an icon
        // and a label reads as glued-together stickers, and "wand.and.sparkles" implies
        // this does something clever rather than what it actually does: delete unused
        // layers. `trash` says that plainly; the count and the reason live in the
        // tooltip, which is where the honest, longer explanation belongs.
        Button {
            Task { await pruneDangling() }
        } label: {
            Image(systemName: "trash")
        }
        .accessibilityLabel("Prune dangling layers")
        .disabled(count == 0 || busy)
        .help(
            count == 0
                ? "No dangling layers to reclaim"
                : "Remove \(count) dangling layer\(count == 1 ? "" : "s"), freeing about \(Formatters.bytesString(danglingBytes))")
    }

    // MARK: Pull popover

    private var pullPopover: some View {
        VStack(spacing: 0) {
            Form {
                Section("Image Reference") {
                    HStack(spacing: Theme.space3) {
                        TextField("nginx:alpine", text: $pullReference)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                            .disabled(isPulling)
                            .onSubmit { Task { await pull() } }
                        if isPulling {
                            ProgressView().controlSize(.small)
                        }
                    }
                }

                if !pullLines.isEmpty {
                    Section("Pull Progress") {
                        pullLog
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button(isPulling ? "Pulling…" : "Pull") {
                    Task { await pull() }
                }
                .keyboardShortcut(.return, modifiers: [])
                .morbButton(.primary)
                .disabled(isPulling || pullReference.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(Theme.space4)
        }
        .frame(width: 380)
    }

    private var pullLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.space1) {
                    ForEach(Array(pullLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(Theme.space3)
            }
            .frame(height: 132)
            .onChange(of: pullLines.count) {
                withAnimation(Theme.animation(.fade, reduceMotion: reduceMotion)) {
                    proxy.scrollTo(pullLines.count - 1, anchor: .bottom)
                }
            }
        }
    }

    // MARK: Table

    @ViewBuilder
    private var content: some View {
        let split = sections
        if model.images.isEmpty {
            MorbEmptyState(
                "No images yet",
                systemImage: "square.on.square",
                description: "Pull one, or run a container and Morbstack fetches it for you.",
                actionTitle: "Pull an Image"
            ) {
                showingPull = true
            }
        } else if split.tagged.isEmpty && split.dangling.isEmpty {
            ContentUnavailableView {
                Label("No Images Found", systemImage: "magnifyingglass")
            } description: {
                Text("No image matches \(query).")
            } actions: {
                Button("Clear Search") { query = "" }
            }
        } else {
            table(split)
                .inspector(isPresented: $showsInspector) {
                    detailPane
                        .inspectorColumnWidth(
                            min: Theme.inspectorMinWidth,
                            ideal: Theme.inspectorWidth,
                            max: 460)
                }
        }
    }

    private func table(_ split: (tagged: [ImageSummary], dangling: [ImageSummary])) -> some View {
        Table(of: ImageSummary.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Repository", sortUsing: TrackCImageComparator(key: .repository)) { image in
                repositoryCell(image)
                    .frame(height: Theme.rowStandard, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            TableColumn("Tag", sortUsing: TrackCImageComparator(key: .tag)) { image in
                Text(image.isDangling ? "—" : image.tag)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(height: Theme.rowStandard, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 80, ideal: 110, max: 180)
            TableColumn("Image ID") { image in
                Text(image.shortID)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(height: Theme.rowStandard, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 84, ideal: 98, max: 120)
            TableColumn("Size", sortUsing: TrackCImageComparator(key: .size)) { image in
                MorbNumber(Formatters.bytesString(image.size), tone: .primary, font: .callout)
                    .frame(height: Theme.rowStandard, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 68, ideal: 82, max: 110)
            TableColumn("Created", sortUsing: TrackCImageComparator(key: .created)) { image in
                MorbNumber(Formatters.compactDuration(since: image.createdAt), font: .callout)
                    .frame(height: Theme.rowStandard, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(Formatters.absoluteDate(image.createdAt))
            }
            .width(min: 80, ideal: 96, max: 130)
            TableColumn("In use", sortUsing: TrackCImageComparator(key: .used)) { image in
                usageCell(image)
                    .frame(height: Theme.rowStandard, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 56, ideal: 68, max: 90)
        } rows: {
            if !split.tagged.isEmpty {
                Section("Images") {
                    ForEach(split.tagged) { TableRow($0) }
                }
            }
            if !split.dangling.isEmpty {
                Section("Dangling · \(Formatters.bytesString(TrackCImageList.totalSize(split.dangling)))") {
                    ForEach(split.dangling) { TableRow($0) }
                }
            }
        }
        .tableStyle(.automatic)
        .contextMenu(forSelectionType: ImageSummary.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            if let id = ids.first { selection = id }
        }
    }

    private func repositoryCell(_ image: ImageSummary) -> some View {
        HStack(spacing: Theme.space2) {
            if image.isDangling {
                Image(systemName: "tag.slash")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Dangling layer")
            }
            Text(image.isDangling ? "<none>" : image.repository)
                .foregroundStyle(image.isDangling ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.middle)
            if image.repoTags.count > 1 {
                Text("+\(image.repoTags.count - 1)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            architectureLabel(image)
        }
    }

    /// The architecture, sitting inline in the repository column.
    ///
    /// A native image gets no chip at all — a badge on every row is wallpaper by the
    /// second screenful — and only the mismatch that costs something is worth ink.
    @ViewBuilder
    private func architectureLabel(_ image: ImageSummary) -> some View {
        if let badge = TrackCImageArch.badge(for: image.architecture), badge.isNoteworthy {
            Label(badge.text, systemImage: badge.symbol ?? "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(badge.tone.color)
                .help("This image is built for \(badge.text), not this Mac's native architecture")
        }
    }

    @ViewBuilder
    private func usageCell(_ image: ImageSummary) -> some View {
        // `-1` is the engine declining to say, which is not the same as zero and should
        // not be rendered as a confident "unused".
        if image.containersUsing < 0 {
            Text("—").foregroundStyle(.tertiary)
        } else if image.containersUsing == 0 {
            Text("—").foregroundStyle(.tertiary)
        } else {
            Text("\(image.containersUsing)")
                .monospacedDigit()
                .help("Used by \(image.containersUsing) container\(image.containersUsing == 1 ? "" : "s")")
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<ImageSummary.ID>) -> some View {
        if let id = ids.first, let image = model.images.first(where: { $0.id == id }) {
            Button("Copy Image ID") { trackCCopy(image.id) }
            if let reference = image.repoTags.first {
                Button("Copy Reference") { trackCCopy(reference) }
            }
            Divider()
            Button("Remove…", role: .destructive) { removal = TrackCImageRemoval(image: image) }
        }
    }

    // MARK: Detail pane

    /// A grouped `Form`, not a stack of hand-drawn cards — see the note on
    /// `VolumesRootView.detailPane`.
    @ViewBuilder
    private var detailPane: some View {
        if let image = selectedImage {
            Form {
                Section("Image") {
                    LabeledContent("Repository") {
                        Text(image.repoTags.first ?? "Untagged layer")
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Size", value: Formatters.bytesString(image.size))
                    LabeledContent(
                        "Used by",
                        value: image.containersUsing < 0
                            ? "not reported"
                            : image.containersUsing == 0
                                ? "no containers"
                                : "\(image.containersUsing) container\(image.containersUsing == 1 ? "" : "s")")
                    architectureField(image)
                    LabeledContent("Content digest") {
                        Text(image.id)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Created", value: Formatters.absoluteDate(image.createdAt))
                }

                if !image.repoTags.isEmpty {
                    Section("Repo Tags") {
                        ForEach(image.repoTags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        removal = TrackCImageRemoval(image: image)
                    } label: {
                        Label("Remove Image", systemImage: "trash")
                    }
                }
            }
            .formStyle(.columns)
        } else {
            ContentUnavailableView {
                Label("No Image Selected", systemImage: "square.on.square")
            } description: {
                Text("Pick an image to see its platform, digest and tags.")
            } actions: {
                Button("Select First Image") {
                    selection = sections.tagged.first?.id ?? sections.dangling.first?.id
                }
            }
        }
    }

    /// The platform row, with the nudge towards an arm64 variant underneath it.
    @ViewBuilder
    private func architectureField(_ image: ImageSummary) -> some View {
        let badge = TrackCImageArch.badge(for: image.architecture)
        LabeledContent("Architecture") {
            VStack(alignment: .leading, spacing: Theme.space1) {
                if let badge, let architecture = image.architecture {
                    HStack(spacing: Theme.space2) {
                        Text(architecture.platformString)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        if let consequence = badge.consequenceLabel {
                            Label(consequence, systemImage: badge.symbol ?? "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(badge.tone.color)
                        }
                    }
                } else {
                    // The lookup is one request and it is in flight; saying "unknown" for
                    // the half-second it takes would read as a defect rather than latency.
                    HStack(spacing: Theme.space2) {
                        ProgressView().controlSize(.small)
                        Text("Checking…").font(.callout).foregroundStyle(.tertiary)
                    }
                }
                if let badge, let advice = TrackCImageArch.advice(
                    for: badge, rosettaAvailable: model.rosetta.availability == .active
                ) {
                    Label {
                        Text(advice)
                    } icon: {
                        Image(systemName: badge.symbol ?? "info.circle")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Operations

    @MainActor
    private func pull() async {
        let reference = pullReference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty, !isPulling else { return }

        isPulling = true
        pullLines = []

        let buffer = TrackCPullBuffer()
        // Drain on a timer rather than hopping every progress line onto the main actor:
        // see `TrackCPullBuffer` for why ordering makes that the wrong shape.
        let pump = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                let batch = buffer.drain()
                if !batch.isEmpty {
                    pullLines = TrackCPullLog.appending(contentsOf: batch, to: pullLines)
                }
            }
        }

        do {
            try await model.client.pull(ref: reference) { line in buffer.append(line) }
            pump.cancel()
            pullLines = TrackCPullLog.appending(contentsOf: buffer.drain(), to: pullLines)
            toast = .success("Pulled \(reference)")
            pullReference = ""
            showingPull = false
            await model.refreshAll()
        } catch {
            pump.cancel()
            pullLines = TrackCPullLog.appending(contentsOf: buffer.drain(), to: pullLines)
            let detail = trackCErrorText(error)
            pullLines = TrackCPullLog.appending("error: \(detail)", to: pullLines)
            toast = .failure("Could not pull \(reference)", detail: detail)
        }
        isPulling = false
    }

    @MainActor
    private func remove(_ image: ImageSummary, force: Bool) async {
        busy = true
        defer { busy = false }
        do {
            try await model.client.removeImage(id: image.id, force: force)
            toast = .success(
                "Removed \(image.repoTags.first ?? image.shortID)",
                detail: "Freed up to \(Formatters.bytesString(image.size))")
            if selection == image.id { selection = nil }
            await model.refreshAll()
        } catch {
            toast = .failure("Could not remove image", detail: trackCErrorText(error))
        }
    }

    @MainActor
    private func pruneDangling() async {
        busy = true
        defer { busy = false }
        do {
            let reclaimed = try await model.client.pruneImages()
            toast = reclaimed > 0
                ? .success("Reclaimed \(Formatters.bytesString(reclaimed))", detail: "Dangling layers removed")
                : .info("Nothing to reclaim", detail: "Every layer is still referenced")
            await model.refreshAll()
        } catch {
            toast = .failure("Prune failed", detail: trackCErrorText(error))
        }
    }
}
