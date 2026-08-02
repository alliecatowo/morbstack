// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The Images screen: what is on disk, what is pulling, and what can go.

import SwiftUI

// MARK: - Layout constants

/// Fixed column widths for the Images table.
///
/// Repository takes the slack; everything else is fixed so the numeric columns stay in a
/// straight line down the table and do not twitch as rows come and go. Multiples of two
/// on an 8pt-ish grid, sized to the widest realistic content (`12 characters` of image
/// id, `999.9 MB` of size) plus breathing room.
private enum ImageColumns {
    static let tag: CGFloat = 118
    static let identifier: CGFloat = 98
    static let size: CGFloat = 78
    static let created: CGFloat = 104
    static let used: CGFloat = 64
    static let actions: CGFloat = 74
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
    @State private var sortKey: TrackCImageSortKey = .created
    @State private var ascending = false
    @State private var selection: ImageSummary.ID?

    @State private var pullReference = ""
    @State private var pullLines: [String] = []
    @State private var isPulling = false
    @State private var pullLogExpanded = false

    @State private var removal: TrackCImageRemoval?
    @State private var busy = false
    @State private var toast: TrackCToast?

    private var sections: (tagged: [ImageSummary], dangling: [ImageSummary]) {
        TrackCImageList.sections(
            images: model.images, query: query, sortKey: sortKey, ascending: ascending)
    }

    private var subtitle: String {
        let total = TrackCImageList.totalSize(model.images)
        let dangling = model.images.filter(\.isDangling).count
        var parts = ["\(model.images.count) image\(model.images.count == 1 ? "" : "s")"]
        parts.append(Formatters.bytesString(total))
        if dangling > 0 { parts.append("\(dangling) dangling") }
        // Only when there is at least one, and never a "0 non-native": the absence of a
        // problem does not need a counter.
        let nonNative = TrackCImageArch.nonNativeCount(model.images)
        if nonNative > 0 { parts.append("\(nonNative) not native") }
        return parts.joined(separator: " · ")
    }

    private var danglingBytes: Int64 {
        TrackCImageList.totalSize(model.images.filter { $0.isDangling && $0.containersUsing <= 0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            TrackCPageHeader(title: "Images", subtitle: subtitle) {
                HStack(spacing: 8) {
                    TrackCSearchField(text: $query, prompt: "Filter images")
                    pruneDanglingButton
                }
            }

            pullBar

            Divider()

            TrackCHeaderBar {
                TrackCSortHeader(
                    title: "Repository", key: TrackCImageSortKey.repository,
                    active: $sortKey, ascending: $ascending)
                TrackCSortHeader(
                    title: "Tag", key: TrackCImageSortKey.tag,
                    active: $sortKey, ascending: $ascending)
                    .frame(width: ImageColumns.tag)
                TrackCPlainHeader(title: "Image ID")
                    .frame(width: ImageColumns.identifier)
                TrackCSortHeader(
                    title: "Size", key: TrackCImageSortKey.size,
                    active: $sortKey, ascending: $ascending, alignment: .trailing)
                    .frame(width: ImageColumns.size)
                TrackCSortHeader(
                    title: "Created", key: TrackCImageSortKey.created,
                    active: $sortKey, ascending: $ascending, alignment: .trailing)
                    .frame(width: ImageColumns.created)
                TrackCSortHeader(
                    title: "In use", key: TrackCImageSortKey.used,
                    active: $sortKey, ascending: $ascending, alignment: .trailing)
                    .frame(width: ImageColumns.used)
                Color.clear.frame(width: ImageColumns.actions, height: 1)
            }
            .padding(.top, 8)

            content
        }
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
        // The platform for one image, fetched when it is selected.
        //
        // `GET /images/json` already carries it for anything pulled from a multi-arch
        // index, so this only fires for the remainder — locally built images, mostly.
        // Doing it for the whole list on every refresh would be one inspect per row
        // through the vsock relay to fill in a column that is already mostly populated.
        //
        // Keyed on the selection so arrowing through the list resolves each row as it is
        // reached and cancels the previous request when it is not.
        .task(id: selection) {
            guard let selection else { return }
            await model.resolveArchitecture(for: selection)
        }
    }

    // MARK: Header actions

    @ViewBuilder
    private var pruneDanglingButton: some View {
        let count = model.images.filter { $0.isDangling && $0.containersUsing <= 0 }.count
        Button {
            Task { await pruneDangling() }
        } label: {
            Label("Prune Dangling", systemImage: "wand.and.sparkles")
        }
        .disabled(count == 0 || busy)
        .help(
            count == 0
                ? "No dangling layers to reclaim"
                : "Remove \(count) dangling layer\(count == 1 ? "" : "s"), freeing about \(Formatters.bytesString(danglingBytes))")
    }

    // MARK: Pull bar

    private var pullBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                    .font(.callout)

                TextField("nginx:alpine", text: $pullReference)
                    .textFieldStyle(.plain)
                    .font(.callout.monospaced())
                    .disabled(isPulling)
                    .onSubmit { Task { await pull() } }

                if isPulling {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                }

                Button(isPulling ? "Pulling…" : "Pull") {
                    Task { await pull() }
                }
                .keyboardShortcut(.return, modifiers: [])
                // The default button is filled with the accent by AppKit. Tinted so the
                // one saturated control on the screen is the app's indigo rather than
                // whatever this Mac is set to.
                .tint(Theme.accent)
                .disabled(isPulling || pullReference.trimmingCharacters(in: .whitespaces).isEmpty)

                if !pullLines.isEmpty {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            pullLogExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: pullLogExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(pullLogExpanded ? "Hide pull output" : "Show pull output")
                }
            }
            .padding(.horizontal, TrackCMetrics.gutter)
            .padding(.vertical, 8)

            if let latest = pullLines.last, !pullLogExpanded {
                Text(latest)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, TrackCMetrics.gutter + 22)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }

            if pullLogExpanded, !pullLines.isEmpty {
                pullLog
                    .padding(.horizontal, TrackCMetrics.gutter)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(.quaternary.opacity(0.18))
    }

    private var pullLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(pullLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(8)
            }
            .frame(height: 132)
            .background(.background.opacity(0.5), in: .rect(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
            }
            // Follow the tail while it grows. Keyed on the count rather than on the
            // content so a rewritten last line (the per-layer collapse) does not scroll.
            .onChange(of: pullLines.count) {
                withAnimation(.easeOut(duration: 0.15)) {
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
            TrackCEmptyState(
                title: "No images yet",
                message: "Pull one with the field above, or run a container and Morbstack will fetch it for you.",
                symbol: "square.on.square")
        } else if split.tagged.isEmpty && split.dangling.isEmpty {
            TrackCEmptyState(
                title: "No matches",
                message: "Nothing here matches “\(query)”.",
                symbol: "magnifyingglass",
                action: (title: "Clear Filter", run: { query = "" }))
        } else {
            List(selection: $selection) {
                if !split.tagged.isEmpty {
                    Section {
                        ForEach(split.tagged) { image in
                            TrackCImageRow(
                                image: image,
                                rosettaAvailable: model.rosetta.availability == .active,
                                onNeedArchitecture: {
                                    Task { await model.resolveArchitecture(for: image.id) }
                                },
                                onRemove: { removal = TrackCImageRemoval(image: image) })
                                .tag(image.id)
                        }
                    }
                }

                if !split.dangling.isEmpty {
                    Section {
                        ForEach(split.dangling) { image in
                            TrackCImageRow(
                                image: image,
                                rosettaAvailable: model.rosetta.availability == .active,
                                onNeedArchitecture: {
                                    Task { await model.resolveArchitecture(for: image.id) }
                                },
                                onRemove: { removal = TrackCImageRemoval(image: image) })
                                .tag(image.id)
                        }
                    } header: {
                        danglingHeader(count: split.dangling.count)
                    }
                }
            }
            .listStyle(.inset)
            // No `.alternatingRowBackgrounds()`. AppKit stripes the whole viewport, not the
            // rows that exist, so six networks in a 900pt window are followed by ten empty
            // bands and the screen reads as a half-loaded skeleton. The hairline separators
            // `List` draws anyway are enough to track a row across four columns, and they
            // stop where the data does.
            .environment(\.defaultMinListRowHeight, TrackCMetrics.rowHeight)
        }
    }

    private func danglingHeader(count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "questionmark.square.dashed")
                .font(.caption2)
            Text("Dangling")
                .font(.caption.weight(.semibold))
            TrackCBadge(text: "\(count)", tone: .warn)
            Text(Formatters.bytesString(TrackCImageList.totalSize(model.images.filter(\.isDangling))))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    // MARK: Operations

    @MainActor
    private func pull() async {
        let reference = pullReference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty, !isPulling else { return }

        isPulling = true
        pullLines = []
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { pullLogExpanded = true }

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

// MARK: - Row

private struct TrackCImageRow: View {

    let image: ImageSummary
    /// Whether an amd64 image on this Mac would actually run. Passed down rather than
    /// probed here so every row agrees, and so the detail popover can tell "slower" from
    /// "will not start at all".
    let rosettaAvailable: Bool
    /// Resolves this image's platform if it is not known yet. Called when the detail
    /// popover opens, which is a way of asking about an image that does not go through
    /// the list's selection.
    let onNeedArchitecture: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false
    @State private var showingDetail = false

    private var extraTagCount: Int { max(0, image.repoTags.count - 1) }

    var body: some View {
        HStack(spacing: TrackCMetrics.columnGap) {
            HStack(spacing: 6) {
                TrackCStatusDot(tone: image.isDangling ? .warn : (image.containersUsing > 0 ? .good : .neutral))
                Text(image.isDangling ? "<none>" : image.repository)
                    .font(.callout)
                    .foregroundStyle(image.isDangling ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if extraTagCount > 0 {
                    TrackCBadge(text: "+\(extraTagCount)", tone: .accent)
                        .help(image.repoTags.dropFirst().joined(separator: "\n"))
                }
                architectureCell
                Spacer(minLength: 0)
            }

            Text(image.isDangling ? "—" : image.tag)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: ImageColumns.tag, alignment: .leading)

            Text(image.shortID)
                .font(.callout.monospaced())
                .foregroundStyle(.tertiary)
                .frame(width: ImageColumns.identifier, alignment: .leading)

            TrackCNumberCell(text: Formatters.bytesString(image.size), emphasised: true)
                .frame(width: ImageColumns.size)

            TrackCNumberCell(text: Formatters.compactDuration(since: image.createdAt))
                .frame(width: ImageColumns.created)
                .help(Formatters.absoluteDate(image.createdAt))

            usageCell
                .frame(width: ImageColumns.used, alignment: .trailing)

            TrackCHoverActions(revealed: hovering) {
                TrackCRowButton(symbol: "info.circle", help: "Image details") {
                    if image.architecture == nil { onNeedArchitecture() }
                    showingDetail = true
                }
                .popover(isPresented: $showingDetail, arrowEdge: .bottom) {
                    TrackCImageDetail(image: image, rosettaAvailable: rosettaAvailable)
                }
                TrackCRowButton(symbol: "trash", help: removeHelp, tone: image.containersUsing > 0 ? .neutral : .bad) {
                    onRemove()
                }
            }
            .frame(width: ImageColumns.actions)
        }
        .frame(height: TrackCMetrics.rowHeight)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy Image ID") { trackCCopy(image.id) }
            if let reference = image.repoTags.first {
                Button("Copy Reference") { trackCCopy(reference) }
            }
            Divider()
            Button("Image Details…") {
                if image.architecture == nil { onNeedArchitecture() }
                showingDetail = true
            }
            Divider()
            Button("Remove…", role: .destructive, action: onRemove)
        }
    }

    private var removeHelp: String {
        image.containersUsing > 0
            ? "In use by \(image.containersUsing) container\(image.containersUsing == 1 ? "" : "s") — removal needs a force"
            : "Remove this image"
    }

    /// The architecture, sitting inline in the repository column.
    ///
    /// Inline rather than a column of its own because the table's fixed columns already
    /// add up to more than the detail pane's minimum width; a seventh would squeeze the
    /// repository name — the thing people actually scan — towards nothing on a narrow
    /// window. The repository cell is the flexible one, so the badge costs space only
    /// where there is space to give.
    ///
    /// A native image gets plain tertiary text and a non-native one gets a tinted
    /// capsule. Both are shown, so the column always answers "what is this built for",
    /// but only the answer that warrants action carries any visual weight — a badge on
    /// every row is wallpaper by the second screenful.
    @ViewBuilder
    private var architectureCell: some View {
        if let badge = TrackCImageArch.badge(for: image.architecture) {
            if badge.isNoteworthy {
                TrackCBadge(text: badge.text, symbol: badge.symbol, tone: badge.tone)
                    .help(architectureHelp(badge))
            } else {
                Text(badge.text)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help(image.architecture?.platformString ?? badge.text)
            }
        }
    }

    private func architectureHelp(_ badge: TrackCImageArch.Badge) -> String {
        var lines = [image.architecture?.platformString ?? badge.text]
        // The advice is written for the good case; the row cannot see whether Rosetta is
        // actually available, and the detail popover — which can — says so properly.
        if let advice = TrackCImageArch.advice(for: badge, rosettaAvailable: true) {
            lines.append(advice)
        }
        return lines.joined(separator: "\n\n")
    }

    @ViewBuilder
    private var usageCell: some View {
        // `-1` is the engine declining to say, which is not the same as zero and should
        // not be rendered as a confident "unused".
        if image.containersUsing < 0 {
            Text("—").font(.callout).foregroundStyle(.tertiary)
        } else if image.containersUsing == 0 {
            Text("0").font(.callout.monospacedDigit()).foregroundStyle(.tertiary)
        } else {
            TrackCBadge(text: "\(image.containersUsing)", symbol: "shippingbox.fill", tone: .good)
        }
    }
}

// MARK: - Detail popover

private struct TrackCImageDetail: View {

    let image: ImageSummary
    var rosettaAvailable: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(image.repoTags.first ?? "Untagged layer")
                    .font(.headline)
                Text(Formatters.bytesString(image.size))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                architectureField
                field("Content digest", value: image.id, monospaced: true, copyable: true)
                field("Created", value: Formatters.absoluteDate(image.createdAt))
                field(
                    "In use by",
                    value: image.containersUsing < 0
                        ? "unreported"
                        : "\(image.containersUsing) container\(image.containersUsing == 1 ? "" : "s")")

                if image.repoTags.isEmpty {
                    field("Repo tags", value: "none — this layer is dangling")
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Repo tags")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        ForEach(image.repoTags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }

    /// The platform row, with the nudge towards an arm64 variant underneath it.
    ///
    /// This is the one place the advice is spelled out in full. The list row's tooltip
    /// has to guess that Rosetta is available; here the answer is known, which is the
    /// difference between "this will be slower" and "this will not start".
    @ViewBuilder
    private var architectureField: some View {
        let badge = TrackCImageArch.badge(for: image.architecture)
        VStack(alignment: .leading, spacing: 3) {
            Text("Architecture")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            if let badge, let architecture = image.architecture {
                HStack(spacing: 6) {
                    Text(architecture.platformString)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    if let consequence = badge.consequenceLabel {
                        TrackCBadge(text: consequence, symbol: badge.symbol, tone: badge.tone)
                    }
                }
                if let advice = TrackCImageArch.advice(for: badge, rosettaAvailable: rosettaAvailable) {
                    Text(advice)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 1)
                }
            } else {
                // The lookup is one request and it is in flight; saying "unknown" for the
                // half-second it takes would read as a defect rather than as latency.
                Text("checking…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func field(_ label: String, value: String, monospaced: Bool = false, copyable: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            HStack(spacing: 6) {
                Text(value)
                    .font(monospaced ? .caption.monospaced() : .caption)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if copyable {
                    Button {
                        trackCCopy(value)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 9))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Copy")
                }
            }
        }
    }
}
