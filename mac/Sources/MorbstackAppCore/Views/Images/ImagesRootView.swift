// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The Images screen: what is on disk, what is pulling, and what can go.
//
// A real `Table` — sortable columns, a real `Dangling` section instead of a floating
// footer band — replaces the hand-rolled grid, the pull field moves off a second bar of
// its own and into the toolbar's `+` control, and a detail pane carries the digest, the
// full tag list and the architecture advice that used to live in a popover. Selection
// reveals those facts in the system `.inspector(isPresented:)` trailing column.

import AppKit
import MorbFeatures
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Table sort
//
// `TrackCImageSortKey` and `TrackCImageList` (search, sort, section split, pull-log
// collapsing) live in `TrackCImageList.swift`, unchanged — `TrackCResourceListTests`
// covers them directly. This file adds only the `Table`-facing comparator.

/// Table sort, keyed by the image-list domain's persisted sort keys.
struct ImageTableComparator: SortComparator {
    var key: TrackCImageSortKey
    var order: SortOrder = .forward

    func compare(_ lhs: ImageSummary, _ rhs: ImageSummary) -> ComparisonResult {
        let result: ComparisonResult
        switch key {
        case .repository:
            result = lhs.repository == rhs.repository
                ? MorbSort.string(lhs.tag, rhs.tag)
                : MorbSort.string(lhs.repository, rhs.repository)
        case .tag:
            result = lhs.tag == rhs.tag
                ? MorbSort.string(lhs.repository, rhs.repository)
                : MorbSort.string(lhs.tag, rhs.tag)
        case .size:
            result = lhs.size == rhs.size
                ? MorbSort.string(lhs.repository, rhs.repository)
                : (lhs.size < rhs.size ? .orderedAscending : .orderedDescending)
        case .created:
            result = lhs.createdAt == rhs.createdAt
                ? MorbSort.string(lhs.repository, rhs.repository)
                : MorbSort.date(lhs.createdAt, rhs.createdAt)
        case .used:
            result = lhs.containersUsing == rhs.containersUsing
                ? MorbSort.string(lhs.repository, rhs.repository)
                : MorbSort.int(lhs.containersUsing, rhs.containersUsing)
        }
        return order == .forward ? result : result.reversed
    }
}

// MARK: - Removal confirmation

/// A pending "are you sure" for one image.
private struct ImageRemovalConfirmation: Identifiable {
    var image: ImageSummary
    var id: String { image.id }

    var inUse: Bool { image.containersUsing > 0 }
    var label: String { image.repoTags.first ?? image.shortID }
}

// MARK: - Root

struct ImagesRootView: View {

    let model: AppModel

    @State private var query = ""
    @State private var sortOrder: [ImageTableComparator] = [ImageTableComparator(key: .created, order: .reverse)]
    @State private var selection: ImageSummary.ID?

    @State private var pullReference = ""
    @State private var pullLines: [String] = []
    @State private var isPulling = false
    @State private var showingPull = false
    @State private var showingPublicImageDiscovery = false
    @FocusState private var pullReferenceIsFocused: Bool
    /// Whether the trailing inspector column is open. SwiftUI restores this across
    /// launches for a trailing-column inspector, so it is not persisted here.
    @State private var showsInspector = true

    @State private var removal: ImageRemovalConfirmation?
    @State private var operationFailure: ImageOperationFailure?
    @State private var showsPruneConfirmation = false
    @State private var busy = false
    @State private var imageArchiveExport: ImageArchiveExportOperation?
    @State private var imageArchiveExportCancellation: ImageArchiveExportCancellation?
    @State private var imageArchiveExportNotice: ImageArchiveExportNotice?
    /// The selected local image snapshot for the one bounded create/start flow.
    @State private var localImageRun: ImageSummary?

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
        initializedScreen
    }

    // Opaque view boundaries deliberately keep each native presentation concern small.
    // Besides making these lifecycles readable, they avoid asking the Swift type checker
    // to infer one enormous generic modifier chain on this feature-rich screen.
    private var initializedScreen: some View {
        selectionResolutionScreen
            .task {
                initializeSelectionIfNeeded()
            }
    }

    private var selectionResolutionScreen: some View {
        pruneConfirmationScreen
            // The platform for one image, fetched when it is selected. `GET /images/json`
            // already carries it for anything pulled from a multi-arch index; this only
            // fires for the remainder — locally built images, mostly.
            .task(id: selection) {
                guard let selection else { return }
                await model.resolveArchitecture(for: selection)
            }
    }

    private var pruneConfirmationScreen: some View {
        imageArchiveNoticeScreen
            .confirmationDialog(
                "Remove dangling images?",
                isPresented: $showsPruneConfirmation,
                titleVisibility: .visible
            ) {
                Button(
                    "Remove \(reclaimableDanglingCount) Dangling Image\(reclaimableDanglingCount == 1 ? "" : "s")",
                    role: .destructive
                ) {
                    Task { await pruneDangling() }
                }
            } message: {
                Text(
                    "This removes unused image layers and frees about \(Formatters.bytesString(danglingBytes)). "
                        + "Images used by containers are kept.")
            }
    }

    private var imageArchiveNoticeScreen: some View {
        operationFailureScreen
            .alert(
                imageArchiveExportNotice?.title ?? "",
                isPresented: imageArchiveExportNoticePresented,
                presenting: imageArchiveExportNotice
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { notice in
                Text(notice.message)
            }
    }

    private var operationFailureScreen: some View {
        removalConfirmationScreen
            .alert(
                operationFailure?.title ?? "",
                isPresented: operationFailurePresented,
                presenting: operationFailure
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { failure in
                Text(failure.message)
            }
    }

    private var removalConfirmationScreen: some View {
        sheetScreen
            .alert(
                removalAlertTitle,
                isPresented: removalPresented,
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
            .onDeleteCommand(perform: stageSelectedImageForRemoval)
    }

    private var sheetScreen: some View {
        baseScreen
            .sheet(isPresented: $showingPull) {
                pullSheet
            }
            .sheet(isPresented: $showingPublicImageDiscovery) {
                PublicImageDiscoverySheet()
            }
            .sheet(item: $localImageRun) { image in
                LocalImageRunSheet(image: image, model: model)
            }
            .sheet(item: $imageArchiveExport) { operation in
                ImageArchiveExportSheet(operation: operation, cancel: cancelImageArchiveExport)
                    .interactiveDismissDisabled()
            }
    }

    private var baseScreen: some View {
        content
            .navigationTitle("Images")
            .navigationSubtitle(subtitle)
            .searchable(text: $query, placement: .toolbar, prompt: "Repository, tag, digest")
            .toolbar { toolbarContent }
            .focusedSceneValue(
                \.imageArchiveExportAction,
                imageArchiveExportAction)
            .focusedSceneValue(
                \.runLocalImageAction,
                runLocalImageAction)
    }

    private var imageArchiveExportAction: (() -> Void)? {
        guard selectedImage != nil, imageArchiveExport == nil else { return nil }
        return chooseImageArchiveDestination
    }

    private var runLocalImageAction: (() -> Void)? {
        guard let selectedImage, model.engine.isRunning, imageArchiveExport == nil, localImageRun == nil else {
            return nil
        }
        return { localImageRun = selectedImage }
    }

    private var removalAlertTitle: String {
        guard let removal else { return "" }
        return removal.inUse ? "\(removal.label) is in use" : "Remove \(removal.label)?"
    }

    // MARK: Toolbar

    /// Keep alert bindings out of `body`: Swift's type checker otherwise has to infer
    /// nested optional-state mutations while it is building the long modifier chain.
    private var removalPresented: Binding<Bool> {
        Binding(get: { removal != nil }, set: dismissRemoval)
    }

    private func dismissRemoval(_ isPresented: Bool) {
        guard !isPresented else { return }
        removal = nil
    }

    private var operationFailurePresented: Binding<Bool> {
        Binding(get: { operationFailure != nil }, set: dismissOperationFailure)
    }

    private func dismissOperationFailure(_ isPresented: Bool) {
        guard !isPresented else { return }
        operationFailure = nil
    }

    private var imageArchiveExportNoticePresented: Binding<Bool> {
        Binding(
            get: { imageArchiveExportNotice != nil },
            set: dismissImageArchiveExportNotice)
    }

    private func dismissImageArchiveExportNotice(_ isPresented: Bool) {
        guard !isPresented else { return }
        imageArchiveExportNotice = nil
    }

    private func stageSelectedImageForRemoval() {
        guard let selectedID = selection else { return }
        guard let image = model.images.first(where: { $0.id == selectedID }) else { return }
        removal = ImageRemovalConfirmation(image: image)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(id: "images.pull", placement: .primaryAction) {
            Button {
                showingPull = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Pull an image")
            .help("Pull an image")
        }
        ToolbarItem(id: "images.pruneDangling", placement: .secondaryAction) {
            pruneDanglingButton
        }
        ToolbarItem(id: "images.explorePublic", placement: .secondaryAction) {
            Button {
                showingPublicImageDiscovery = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel("Explore public images")
            .help("Search public Docker Hub repositories")
        }
        ToolbarItem(id: "images.export", placement: .secondaryAction) {
            Button {
                chooseImageArchiveDestination()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .accessibilityLabel("Export selected image")
            .help(
                selectedImage == nil
                    ? "Select an image to export"
                    : "Export selected image as a Docker archive")
            .disabled(selectedImage == nil || imageArchiveExport != nil)
        }
        ToolbarItem(id: "images.runLocal", placement: .secondaryAction) {
            Button {
                runLocalImageAction?()
            } label: {
                Image(systemName: "play")
            }
            .accessibilityLabel("Run selected local image")
            .help(
                runLocalImageAction == nil
                    ? "Select a local image while the engine is running"
                    : "Create and start one container using the selected local image")
            .disabled(runLocalImageAction == nil)
        }
        if !model.images.isEmpty {
            ToolbarItem(id: "images.inspector", placement: .automatic) {
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

    @ViewBuilder
    private var pruneDanglingButton: some View {
        Button {
            showsPruneConfirmation = true
        } label: {
            Image(systemName: "trash")
        }
        .accessibilityLabel("Prune dangling layers")
        .disabled(reclaimableDanglingCount == 0 || busy)
        .help(
            reclaimableDanglingCount == 0
                ? "No dangling layers to reclaim"
                : "Remove \(reclaimableDanglingCount) dangling layer\(reclaimableDanglingCount == 1 ? "" : "s"), "
                    + "freeing about \(Formatters.bytesString(danglingBytes))")
    }

    // MARK: Pull sheet

    private var pullSheet: some View {
        Form {
            Section {
                TextField(
                    "Image Reference",
                    text: $pullReference,
                    prompt: Text("nginx:alpine"))
                    .font(.system(.body, design: .monospaced))
                    .disabled(isPulling)
                    .focused($pullReferenceIsFocused)
                    .onSubmit { Task { await pull() } }
            }

            if isPulling {
                Section {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Pulling image")
                }
            }

            if !pullLines.isEmpty {
                Section("Pull Progress") {
                    pullLog
                }
            }

            Section {
                Button(isPulling ? "Pulling…" : "Pull") {
                    Task { await pull() }
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(isPulling || pullReference.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        // Docker's pull stream has no cancellation contract in this screen. Keep
        // the system sheet visible while it is active instead of offering a Cancel
        // control that cannot cancel the engine request.
        .interactiveDismissDisabled(isPulling)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 260)
        .onAppear { pullReferenceIsFocused = true }
    }

    private var pullLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading) {
                    ForEach(Array(pullLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
            }
            .frame(height: 132)
            .onChange(of: pullLines.count) {
                proxy.scrollTo(pullLines.count - 1, anchor: .bottom)
            }
        }
    }

    // MARK: Table

    @ViewBuilder
    private var content: some View {
        let split = sections
        if model.images.isEmpty {
            ContentUnavailableView {
                Label("No Images", systemImage: "square.on.square")
            } description: {
                Text("Pull an image to inspect it here, or run a container and Docker fetches it automatically.")
            } actions: {
                Button("Pull an Image") {
                    showingPull = true
                }
                Button("Refresh") {
                    Task { await model.refreshAll() }
                }
            }
        } else if split.tagged.isEmpty && split.dangling.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            table(split)
                .inspector(isPresented: $showsInspector) {
                    detailPane
                        .inspectorColumnWidth(
                            min: 340,
                            ideal: 400,
                            max: 460)
                }
        }
    }

    private func table(_ split: (tagged: [ImageSummary], dangling: [ImageSummary])) -> some View {
        Table(of: ImageSummary.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Repository", sortUsing: ImageTableComparator(key: .repository)) { image in
                repositoryCell(image)
            }
            TableColumn("Tag", sortUsing: ImageTableComparator(key: .tag)) { image in
                Text(image.isDangling ? "—" : image.tag)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 80, ideal: 110, max: 180)
            TableColumn("Image ID") { image in
                Text(image.shortID)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .width(min: 84, ideal: 98, max: 120)
            TableColumn("Size", sortUsing: ImageTableComparator(key: .size)) { image in
                Text(Formatters.bytesString(image.size))
                    .monospacedDigit()
            }
            .width(min: 68, ideal: 82, max: 110)
            TableColumn("Created", sortUsing: ImageTableComparator(key: .created)) { image in
                Text(Formatters.compactDuration(since: image.createdAt))
                    .monospacedDigit()
                    .help(Formatters.absoluteDate(image.createdAt))
            }
            .width(min: 80, ideal: 96, max: 130)
            TableColumn("In use", sortUsing: ImageTableComparator(key: .used)) { image in
                usageCell(image)
            }
            .width(min: 56, ideal: 68, max: 90)
        } rows: {
            // Tagged images are the table's primary data, not a second level of
            // hierarchy. Giving the only data set a Section repeated the screen
            // title in the first row and caused Tahoe to reserve a grouped-table
            // treatment for a group that does not exist. Keep a Section only when
            // tagged and dangling images are both present, and name both groups by
            // their actual relationship rather than repeating the route title.
            if split.dangling.isEmpty {
                ForEach(split.tagged) { TableRow($0) }
            } else if !split.tagged.isEmpty {
                Section("Tagged Images") {
                    ForEach(split.tagged) { TableRow($0) }
                }
            }
            if !split.dangling.isEmpty {
                Section("Dangling Images") {
                    ForEach(split.dangling) { TableRow($0) }
                }
            }
        }
        // Native `BorderedTableStyle` is the narrow system-style hypothesis for the
        // repeated rounded empty-row bands seen in the current automatic appearance.
        // It requires current-bundle Computer Use review before visual acceptance.
        .tableStyle(.bordered)
        .contextMenu(forSelectionType: ImageSummary.ID.self) { ids in
            contextMenu(for: ids)
        }
    }

    private func repositoryCell(_ image: ImageSummary) -> some View {
        HStack {
            if image.isDangling {
                Image(systemName: "tag.slash")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Dangling layer")
            }
            Text(image.isDangling ? "<none>" : image.repository)
                .foregroundStyle(image.isDangling ? .secondary : .primary)
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
                .foregroundStyle(.secondary)
                .accessibilityLabel("Architecture mismatch: \(badge.text)")
                .accessibilityHint("This image is not built for this Mac’s native architecture.")
                .help("This image is built for \(badge.text), not this Mac's native architecture")
        }
    }

    @ViewBuilder
    private func usageCell(_ image: ImageSummary) -> some View {
        // `-1` is the engine declining to say, which is not the same as zero and should
        // not be rendered as a confident "unused".
        if image.containersUsing < 0 {
            Text("—")
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Container usage not reported")
        } else if image.containersUsing == 0 {
            Text("0")
                .monospacedDigit()
                .accessibilityLabel("Used by no containers")
                .help("Used by no containers")
        } else {
            Text("\(image.containersUsing)")
                .monospacedDigit()
                .help("Used by \(image.containersUsing) container\(image.containersUsing == 1 ? "" : "s")")
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<ImageSummary.ID>) -> some View {
        if let id = ids.first, let image = model.images.first(where: { $0.id == id }) {
            Button("Copy Image ID") { MorbPasteboard.copy(image.id) }
            if let reference = image.repoTags.first {
                Button("Copy Reference") { MorbPasteboard.copy(reference) }
            }
            Divider()
            Button("Run Local Image…") {
                localImageRun = image
            }
            .disabled(!model.engine.isRunning || imageArchiveExport != nil)
            Divider()
            Button("Export Image Archive…") {
                chooseImageArchiveDestination(for: image)
            }
            .disabled(imageArchiveExport != nil)
            Divider()
            Button("Remove…", role: .destructive) { removal = ImageRemovalConfirmation(image: image) }
        }
    }

    // MARK: Detail pane

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

                Section("Archive") {
                    Button {
                        chooseImageArchiveDestination(for: image)
                    } label: {
                        Label("Export Image Archive…", systemImage: "square.and.arrow.down")
                    }
                    .disabled(imageArchiveExport != nil)
                }

                Section("Container") {
                    Button {
                        localImageRun = image
                    } label: {
                        Label("Run Local Image…", systemImage: "play")
                    }
                    .disabled(!model.engine.isRunning || imageArchiveExport != nil)
                }

                Section {
                    Button(role: .destructive) {
                        removal = ImageRemovalConfirmation(image: image)
                    } label: {
                        Label("Remove Image", systemImage: "trash")
                    }
                    .disabled(busy)
                }
            }
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
            VStack(alignment: .leading) {
                if let badge, let architecture = image.architecture {
                    HStack {
                        Text(architecture.platformString)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        if let consequence = badge.consequenceLabel {
                            Label(consequence, systemImage: badge.symbol ?? "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    // The lookup is one request and it is in flight; saying "unknown" for
                    // the half-second it takes would read as a defect rather than latency.
                    HStack {
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
    private func initializeSelectionIfNeeded() {
        guard selection == nil else { return }
        let split = sections
        let firstTaggedImage = split.tagged.first
        let firstDanglingImage = split.dangling.first
        selection = firstTaggedImage?.id ?? firstDanglingImage?.id
    }

    /// Presents the system's save location and replacement flow. There is deliberately
    /// no app-defined destination: an image archive can contain layer and configuration
    /// data, so the person exporting it chooses where it belongs every time.
    @MainActor
    private func chooseImageArchiveDestination() {
        guard let selectedImage else { return }
        chooseImageArchiveDestination(for: selectedImage)
    }

    @MainActor
    private func chooseImageArchiveDestination(for image: ImageSummary) {
        guard imageArchiveExport == nil else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.tarArchive]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "morbstack-image-\(image.shortID).tar"
        panel.message = "Save a local Docker image archive. The image remains in Morbstack."
        panel.prompt = "Export"

        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        // NSSavePanel supplies the system replacement confirmation. The exporter validates
        // the destination again at atomic commit time, so a partial stream never replaces
        // an existing archive.
        let replaceExisting = FileManager.default.fileExists(atPath: outputURL.path)
        let cancellation = ImageArchiveExportCancellation()
        let operation = ImageArchiveExportOperation(
            imageLabel: image.isDangling ? image.shortID : (image.repoTags.first ?? image.shortID),
            outputURL: outputURL)
        imageArchiveExport = operation
        imageArchiveExportCancellation = cancellation

        let operationID = operation.id
        let imageID = image.id
        let progressRelay = ImageArchiveExportProgressRelay { progress in
            self.recordImageArchiveExportProgress(progress, for: operationID)
        }
        Task.detached(priority: .userInitiated) {
            do {
                let result = try ImageArchiveExporter.export(
                    imageReference: imageID,
                    to: outputURL,
                    replaceExisting: replaceExisting,
                    onProgress: { progress in
                        guard !cancellation.isRequested else { return false }
                        progressRelay.send(progress)
                        return true
                    })
                await self.finishImageArchiveExport(.success(result), for: operationID)
            } catch {
                await self.finishImageArchiveExport(.failure(error), for: operationID)
            }
        }
    }

    @MainActor
    private func cancelImageArchiveExport() {
        guard var operation = imageArchiveExport, !operation.isCancellationRequested else { return }
        operation.isCancellationRequested = true
        imageArchiveExport = operation
        imageArchiveExportCancellation?.request()
    }

    @MainActor
    private func recordImageArchiveExportProgress(
        _ progress: ImageArchiveExportProgress,
        for operationID: UUID
    ) {
        guard var operation = imageArchiveExport, operation.id == operationID else { return }
        operation.record(progress)
        imageArchiveExport = operation
    }

    @MainActor
    private func finishImageArchiveExport(
        _ result: Result<ImageArchiveExportResult, Error>,
        for operationID: UUID
    ) {
        guard imageArchiveExport?.id == operationID else { return }
        imageArchiveExport = nil
        imageArchiveExportCancellation = nil

        switch result {
        case .success(let export):
            imageArchiveExportNotice = .success(result: export)
        case .failure(let error):
            if let exportError = error as? ImageArchiveExportError, exportError == .cancelled {
                imageArchiveExportNotice = .cancelled()
            } else {
                imageArchiveExportNotice = .failure(error)
            }
        }
    }

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
            pullReference = ""
            showingPull = false
            await model.refreshAll()
        } catch {
            pump.cancel()
            pullLines = TrackCPullLog.appending(contentsOf: buffer.drain(), to: pullLines)
            let detail = MorbErrorMessage.text(for: error)
            pullLines = TrackCPullLog.appending("error: \(detail)", to: pullLines)
        }
        isPulling = false
    }

    @MainActor
    private func remove(_ image: ImageSummary, force: Bool) async {
        busy = true
        defer { busy = false }
        do {
            try await model.client.removeImage(id: image.id, force: force)
            if selection == image.id { selection = nil }
            await model.refreshAll()
        } catch {
            operationFailure = ImageOperationFailure(
                title: "Couldn’t Remove Image",
                message: MorbErrorMessage.text(for: error))
        }
    }

    @MainActor
    private func pruneDangling() async {
        busy = true
        defer { busy = false }
        do {
            _ = try await model.client.pruneImages()
            await model.refreshAll()
        } catch {
            operationFailure = ImageOperationFailure(
                title: "Couldn’t Remove Dangling Images",
                message: MorbErrorMessage.text(for: error))
        }
    }

    private var reclaimableDanglingCount: Int {
        model.images.filter { $0.isDangling && $0.containersUsing <= 0 }.count
    }
}

/// An operation failure is domain state for a standard, actionable system alert; it has
/// no visual styling of its own.
private struct ImageOperationFailure: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
