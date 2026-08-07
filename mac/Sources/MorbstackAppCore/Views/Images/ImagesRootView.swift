// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The Images screen: what is on disk, what is pulling, and what can go.
//
// A real `Table` — sortable columns, a real `Dangling` section instead of a floating
// footer band — replaces the hand-rolled grid, the pull field moves off a second bar of
// its own and into the toolbar's `+` control, and a detail pane carries the image ID,
// full tag list and the architecture advice that used to live in a popover. Selection
// reveals those facts in the system `.inspector(isPresented:)` trailing column.

import AppKit
import MorbFeatures
import SwiftUI
import UniformTypeIdentifiers

/// Keep file choice in the native open panel. The engine, rather than the app,
/// validates archive contents; these types merely expose Docker-supported tar and
/// compressed-tar filename forms in the system file browser.
private let imageArchiveImportContentTypes: [UTType] = {
    var types: [UTType] = [.tarArchive]
    for filenameExtension in ImageArchiveImportSelectionPolicy.supportedFilenameExtensions
    where filenameExtension != "tar" {
        guard let type = UTType(filenameExtension: filenameExtension), !types.contains(type) else {
            continue
        }
        types.append(type)
    }
    return types
}()

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

    var label: String { image.repoTags.first ?? image.shortID }

    var explanation: String {
        let identity = "Morbstack will ask Docker to remove this image by immutable ID \(image.shortID), not only the displayed repository tag."
        switch image.containersUsing {
        case let count where count > 0:
            return "\(identity) Docker reports \(count) dependent container\(count == 1 ? "" : "s"). Morbstack never forces image removal or removes containers; Docker will refuse while dependencies or additional tags remain, and its exact response will be shown."
        case 0:
            return "\(identity) Docker can still refuse if a container or another tag appeared since this list was refreshed. Morbstack does not force removal."
        default:
            return "\(identity) Docker did not report current container usage. Morbstack does not force removal; Docker will verify dependencies and report any refusal."
        }
    }
}

// MARK: - Root

struct ImagesRootView: View {

    let model: AppModel

    @State private var query = ""
    // UI-051: search is a glyph in the trailing group until someone asks for it.
    // `RouteSearchModifier` attaches the system field while this is true.
    @State private var searchIsActive = false
    @State private var sortOrder: [ImageTableComparator] = [ImageTableComparator(key: .created, order: .reverse)]
    @State private var selection: ImageSummary.ID?

    @State private var pullReference = ""
    @State private var pullLines: [String] = []
    @State private var pullState: TrackCImagePullState = .ready
    @State private var showingPull = false
    @State private var showingPublicImageDiscovery = false
    /// A public discovery result can fill the existing Pull Image form only after its
    /// read-only discovery sheet has dismissed. This avoids overlapping system sheets
    /// and keeps the eventual Engine action explicit.
    @State private var pendingDiscoveredPullReference: String?
    @FocusState private var pullReferenceIsFocused: Bool
    /// Whether the trailing inspector column is open. SwiftUI restores this across
    /// launches for a trailing-column inspector, so it is not persisted here.
    @State private var showsInspector = true
    /// Tags are supporting metadata. Keep them collapsed until a person asks for the
    /// full set of current references rather than making every selected image read as a list.
    @State private var repoTagsExpanded = false

    @State private var removal: ImageRemovalConfirmation?
    @State private var imageTagTarget: ImageSummary?
    @State private var operationFailure: ImageOperationFailure?
    @State private var showsPruneConfirmation = false
    @State private var busy = false
    @State private var imageArchiveExport: ImageArchiveExportOperation?
    @State private var imageArchiveExportCancellation: ImageArchiveExportCancellation?
    @State private var imageArchiveExportNotice: ImageArchiveExportNotice?
    @State private var imageArchiveImportReview: ImageArchiveImportRequest?
    @State private var pendingImageArchiveImport: ImageArchiveImportRequest?
    @State private var imageArchiveImport: ImageArchiveImportOperation?
    @State private var imageArchiveImportCancellation: ImageArchiveImportCancellation?
    @State private var imageArchiveImportNotice: ImageArchiveImportNotice?
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

    private var isPulling: Bool { pullState.isWorking }

    /// Tagging and image removal are Docker Engine mutations. Stale inventory is still
    /// useful to inspect while the engine is stopped, but it must not expose commands
    /// that cannot reach their only backing implementation.
    private var canMutateImages: Bool {
        model.fixtureProvenance == nil && model.engine.isRunning && !busy && !imageArchiveTransferIsActive
    }

    /// Export reads a potentially large archive through Morbstack's current local
    /// Engine socket. Fixture data is intentionally not backed by that Engine, so it
    /// must never be allowed to fall through to the real archive exporter. Unlike a
    /// fixture-aware `DockerClient` command, that service opens its own stream.
    private var canExportImages: Bool {
        model.fixtureProvenance == nil
            && model.engine.isRunning
            && imageArchiveExport == nil
            && imageArchiveImport == nil
            && imageArchiveImportReview == nil
    }

    private var canExportSelectedImage: Bool {
        selectedImage != nil && canExportImages
    }

    /// Import, like export, opens its own Engine stream rather than using the
    /// fixture-aware app client. Fixture documents therefore must never reach a live
    /// local Engine through this document workflow.
    private var canImportImages: Bool {
        model.fixtureProvenance == nil
            && model.engine.isRunning
            && imageArchiveExport == nil
            && imageArchiveImport == nil
            && imageArchiveImportReview == nil
    }

    private var imageArchiveTransferIsActive: Bool {
        imageArchiveExport != nil || imageArchiveImport != nil
    }

    private func imageMutationHelp(_ availableAction: String) -> String {
        if model.fixtureProvenance != nil {
            return "Image mutations are unavailable in developer fixture data"
        }
        return model.engine.isRunning
            ? availableAction
            : "Start the Engine to change an image"
    }

    private func imageExportHelp(_ availableAction: String) -> String {
        if model.fixtureProvenance != nil {
            return "Image archive export is unavailable in developer fixture data"
        }
        if !model.engine.isRunning {
            return "Start the Engine to export an image archive"
        }
        if imageArchiveExport != nil || imageArchiveImport != nil {
            return "An image archive transfer is already in progress"
        }
        return availableAction
    }

    private func imageImportHelp(_ availableAction: String) -> String {
        if model.fixtureProvenance != nil {
            return "Image archive loading is unavailable in developer fixture data"
        }
        if !model.engine.isRunning {
            return "Start the Engine to load an image archive"
        }
        if imageArchiveTransferIsActive {
            return "An image archive transfer is already in progress"
        }
        return availableAction
    }

    private var pullReferenceToSubmit: String? {
        TrackCImagePullState.reference(from: pullReference)
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
                repoTagsExpanded = false
                guard let selection else { return }
                await model.resolveArchitecture(for: selection)
            }
    }

    private var pruneConfirmationScreen: some View {
        imageArchiveImportNoticeScreen
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

    private var imageArchiveImportNoticeScreen: some View {
        imageArchiveNoticeScreen
            .alert(
                imageArchiveImportNotice?.title ?? "",
                isPresented: imageArchiveImportNoticePresented,
                presenting: imageArchiveImportNotice
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
                Button("Remove", role: .destructive) {
                    Task { await remove(target.image) }
                }
            } message: { target in
                Text(target.explanation)
            }
            .onDeleteCommand(perform: stageSelectedImageForRemoval)
    }

    private var sheetScreen: some View {
        baseScreen
            .sheet(isPresented: $showingPull) {
                pullSheet
            }
            .sheet(
                isPresented: $showingPublicImageDiscovery,
                onDismiss: presentDiscoveredPullIfNeeded)
            {
                PublicImageDiscoverySheet { repository in
                    pendingDiscoveredPullReference = repository
                }
            }
            .sheet(item: $localImageRun) { image in
                LocalImageRunSheet(image: image, model: model)
            }
            .sheet(item: $imageTagTarget) { image in
                ImageTagSheet(image: image) { request in
                    try await tagImage(request)
                }
            }
            .sheet(item: $imageArchiveExport) { operation in
                ImageArchiveExportSheet(operation: operation, cancel: cancelImageArchiveExport)
                    .interactiveDismissDisabled()
            }
            .sheet(item: $imageArchiveImportReview, onDismiss: beginPendingImageArchiveImport) { request in
                ImageArchiveImportReviewSheet(request: request) {
                    pendingImageArchiveImport = request
                    imageArchiveImportReview = nil
                }
            }
            .sheet(item: $imageArchiveImport) { operation in
                ImageArchiveImportSheet(operation: operation, cancel: cancelImageArchiveImport)
                    .interactiveDismissDisabled()
            }
    }

    private var baseScreen: some View {
        content
            .navigationTitle("Images")
            .navigationSubtitle(subtitle)
            // The menu-bar mirror of the toolbar's prune command, so it stays
            // reachable when the toolbar overflows at narrow widths.
            .focusedSceneValue(
                \.routeMaintenanceCommand,
                RouteMaintenanceCommand(
                    title: "Prune Dangling Layers…",
                    isEnabled: reclaimableDanglingCount > 0 && !busy,
                    perform: { showsPruneConfirmation = true }))
            .toolbar { toolbarContent }
            .focusedSceneValue(
                \.imageArchiveExportAction,
                imageArchiveExportAction)
            .focusedSceneValue(
                \.imageArchiveImportAction,
                imageArchiveImportAction)
            .focusedSceneValue(
                \.runLocalImageAction,
                runLocalImageAction)
    }

    private var imageArchiveExportAction: (() -> Void)? {
        guard canExportSelectedImage else { return nil }
        return chooseImageArchiveDestination
    }

    private var imageArchiveImportAction: (() -> Void)? {
        guard canImportImages else { return nil }
        return chooseImageArchiveForLoading
    }

    private var runLocalImageAction: (() -> Void)? {
        guard let selectedImage, model.engine.isRunning, !imageArchiveTransferIsActive, localImageRun == nil else {
            return nil
        }
        return { localImageRun = selectedImage }
    }

    private var removalAlertTitle: String {
        guard let removal else { return "" }
        return "Remove \(removal.label)?"
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

    private var imageArchiveImportNoticePresented: Binding<Bool> {
        Binding(
            get: { imageArchiveImportNotice != nil },
            set: dismissImageArchiveImportNotice)
    }

    private func dismissImageArchiveImportNotice(_ isPresented: Bool) {
        guard !isPresented else { return }
        imageArchiveImportNotice = nil
    }

    private func stageSelectedImageForRemoval() {
        guard canMutateImages else { return }
        guard let selectedID = selection else { return }
        guard let image = model.images.first(where: { $0.id == selectedID }) else { return }
        removal = ImageRemovalConfirmation(image: image)
    }

    /// See the note on `VolumesRootView.trailingCommandItems`: mounted on the
    /// inspector content while a table is on screen, and in the window toolbar on
    /// the inspector-less empty screen.
    @ToolbarContentBuilder
    private var trailingCommandItems: some ToolbarContent {
        if !model.images.isEmpty {
            // Identifiers follow docs/design/ACCESSIBILITY-IDENTIFIERS.md: a toolbar
            // control reuses its `ToolbarItem(id:)` string verbatim, and the label —
            // never the identifier — carries the user-facing state.
            RouteSearchToolbarItem(
                id: "images.search", subject: "images", isActive: $searchIsActive)
            ToolbarItem(id: "images.inspector", placement: .primaryAction) {
                Button {
                    showsInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .accessibilityIdentifier("images.inspector")
                .accessibilityLabel(showsInspector ? "Hide inspector" : "Show inspector")
                .help(showsInspector ? "Hide the inspector" : "Show the inspector")
            }
        }
    }

    /// Slots 1–3 of the toolbar grammar — see `VolumesRootView.toolbarContent` and
    /// `docs/design/NATIVE-MACOS-PLAYBOOK.md`.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // 1 · record actions — act on the selected image.
        ToolbarItem(id: "images.runLocal", placement: .primaryAction) {
            Button {
                runLocalImageAction?()
            } label: {
                Image(systemName: "play")
            }
            .accessibilityIdentifier("images.runLocal")
            .accessibilityLabel("Run selected local image")
            .help(
                runLocalImageAction == nil
                    ? "Select a local image while the engine is running"
                    : "Create and start one container using the selected local image")
            .disabled(runLocalImageAction == nil)
        }
        // 2 · collection actions, destructive first so it is never adjacent to "pull".
        ToolbarItem(id: "images.pruneDangling", placement: .primaryAction) {
            pruneDanglingButton
        }
        ToolbarItem(id: "images.explorePublic", placement: .primaryAction) {
            Button {
                showingPublicImageDiscovery = true
            } label: {
                // Not `magnifyingglass`: slot 4 of this route's own toolbar is now the
                // local filter's magnifying glass, and two identical glyphs in one
                // capsule meaning "filter what you have" and "browse a remote registry"
                // is exactly the ambiguity the HIG's "make the meaning of each control
                // clear" is about. A globe says remote.
                Image(systemName: "globe")
            }
            .accessibilityIdentifier("images.explorePublic")
            .accessibilityLabel("Explore public images")
            .help("Search public Docker Hub repositories")
        }
        ToolbarItem(id: "images.pull", placement: .primaryAction) {
            Button {
                presentPull()
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityIdentifier("images.pull")
            .accessibilityLabel("Pull an image")
            .help("Pull an image")
        }
        // 3 · the route's menu. Import and export are two document operations in one
        // small, native Menu. Grouping them keeps the toolbar from accumulating
        // unrelated one-off glyphs; the full commands remain discoverable in the Image
        // menu and inspector.
        ToolbarItem(id: "images.archive", placement: .primaryAction) {
            Menu {
                Button("Load Image Archive…") {
                    chooseImageArchiveForLoading()
                }
                .disabled(!canImportImages)

                Divider()

                Button("Export Selected Image…") {
                    chooseImageArchiveDestination()
                }
                .disabled(!canExportSelectedImage)
            } label: {
                Image(systemName: "archivebox")
            }
            .accessibilityIdentifier("images.archive")
            .accessibilityLabel("Image archive actions")
            .help(imageArchiveMenuHelp)
        }
        if model.images.isEmpty {
            trailingCommandItems
        }
    }

    private var imageArchiveMenuHelp: String {
        if canImportImages {
            return "Load a Docker image archive or export the selected image"
        }
        if selectedImage == nil, model.engine.isRunning, model.fixtureProvenance == nil {
            return "Load a Docker image archive"
        }
        return imageImportHelp("Load or export a Docker image archive")
    }

    @ViewBuilder
    private var pruneDanglingButton: some View {
        Button {
            showsPruneConfirmation = true
        } label: {
            Image(systemName: "trash")
        }
        .accessibilityIdentifier("images.pruneDangling")
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
        NavigationStack {
            Form {
                Section("Image") {
                    TextField(
                        "Reference",
                        text: $pullReference,
                        prompt: Text("nginx:alpine"))
                        .font(.system(.body, design: .monospaced))
                        .disabled(isPulling || !pullState.allowsPull)
                        .focused($pullReferenceIsFocused)
                        .onSubmit { Task { await pull() } }
                        .accessibilityIdentifier("images.pullSheet.reference")
                }

                pullStateSection

                if !pullLines.isEmpty {
                    Section("Docker Output") {
                        pullLog
                    }
                }
            }
            .navigationTitle("Pull Image")
            .toolbar { pullSheetToolbar }
        }
        // Docker's pull stream has no cancellation contract in this screen. Keep
        // the system sheet visible while it is active instead of offering a Cancel
        // control that cannot cancel the engine request.
        .interactiveDismissDisabled(isPulling)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 260)
        .onAppear { pullReferenceIsFocused = true }
        .onChange(of: pullReference) { _, _ in
            guard !isPulling else { return }
            if pullState != .ready {
                pullState = .ready
                // Output belongs to the reference that just completed. Once the person
                // edits it, retaining that transcript would falsely make it look like
                // Docker had attempted the new reference.
                pullLines = []
            }
        }
    }

    @ToolbarContentBuilder
    private var pullSheetToolbar: some ToolbarContent {
        if !isPulling {
            ToolbarItem(placement: .cancellationAction) {
                Button(pullState == .ready ? "Cancel" : "Done") {
                    showingPull = false
                }
                .accessibilityIdentifier("images.pullSheet.cancel")
            }
        }

        if pullState.allowsPull {
            ToolbarItem(placement: .confirmationAction) {
                Button(pullState.failureMessage == nil ? "Pull" : "Try Again") {
                    Task { await pull() }
                }
                .disabled(pullReferenceToSubmit == nil)
                .accessibilityIdentifier("images.pullSheet.pull")
            }
        }
    }

    @ViewBuilder
    private var pullStateSection: some View {
        switch pullState {
        case .ready:
            Section("Scope") {
                Text(
                    "Pulls exactly the reference you enter through the local Docker engine. "
                        + "Registry access and authentication remain Docker's responsibility.")
                    .foregroundStyle(.secondary)
            }
        case .pulling(let reference):
            Section("Status") {
                ProgressView("Pulling \(reference)")
                    .controlSize(.small)
                    .accessibilityLabel("Pulling \(reference)")
                Text("Docker does not provide a safe cancellation contract for this request.")
                    .foregroundStyle(.secondary)
            }
        case .succeeded(let reference):
            Section("Result") {
                Label("Image Pulled", systemImage: "checkmark.circle")
                LabeledContent("Reference") {
                    Text(reference)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Text("Docker completed the pull stream. Local images were refreshed.")
                    .foregroundStyle(.secondary)
            }
        case .failed(let reference, let message):
            Section("Couldn’t Pull Image") {
                LabeledContent("Reference") {
                    Text(reference)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Text(message)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
                Text("No local Docker images are available yet.")
            } actions: {
                Button("Pull an Image") {
                    presentPull()
                }
                .accessibilityIdentifier("images.empty.noImages.pull")
                Button("Refresh") {
                    Task { await model.refreshAll() }
                }
                .accessibilityIdentifier("images.empty.noImages.refresh")
            }
            .accessibilityIdentifier("images.empty.noImages")
        } else {
            Group {
                if split.tagged.isEmpty && split.dangling.isEmpty {
                    // The inspector stays mounted behind the no-results state so the
                    // search field — declared on the inspector content below —
                    // remains on screen to clear or edit the query.
                    ContentUnavailableView.search(text: query)
                } else {
                    table(split)
                }
            }
            .inspector(isPresented: $showsInspector) {
                detailPane
                    // See the note on `VolumesRootView`: the trailing commands and
                    // search ride the inspector's toolbar region and remain present
                    // while the inspector is closed.
                    .toolbar { trailingCommandItems }
                    .routeSearchable(
                        isActive: $searchIsActive,
                        text: $query,
                        prompt: "Repository, tag, digest")
                    // Must be the outermost modifier on the inspector's content —
                    // see the note in `ContainersRootView`: applied beneath
                    // `.toolbar`/`.searchable` its preferred width was silently
                    // discarded.
                    .inspectorColumnWidth(min: 340, ideal: 400, max: 460)
            }
        }
    }

    private func table(_ split: (tagged: [ImageSummary], dangling: [ImageSummary])) -> some View {
        Table(of: ImageSummary.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Repository", sortUsing: ImageTableComparator(key: .repository)) { image in
                repositoryCell(image)
            }
            // Repository is the primary identity for this inventory. It must retain a
            // readable minimum when the trailing system inspector is visible; the
            // native Table can then manage any remaining overflow rather than reducing
            // each record to a single character.
            .width(min: 180, ideal: 260)
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
                // A minute tick is enough here — image ages are hours and days — but
                // it keeps a long-lived window from showing last week's "2h".
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(Formatters.compactDuration(since: image.createdAt, at: context.date))
                        .monospacedDigit()
                        .help(Formatters.absoluteDate(image.createdAt))
                }
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
        // Native `BorderedTableStyle` was adopted for the repeated rounded empty-row
        // bands in the automatic appearance and reviewed as correct. Its own subtler
        // edge-to-edge striping still continued past the last record, so the striping
        // is disabled here like every other record table — the table visibly ends at
        // its data (see the note on `VolumesRootView.table`).
        .tableStyle(.bordered)
        .alternatingRowBackgrounds(.disabled)
        .accessibilityIdentifier("images.table")
        .contextMenu(forSelectionType: ImageSummary.ID.self) { ids in
            contextMenu(for: ids)
        }
    }

    /// The engine-facing reference for a row, per
    /// docs/design/ACCESSIBILITY-IDENTIFIERS.md: the `repo:tag` a `docker` command
    /// would accept, or the short image ID for an untagged (dangling) layer.
    private func rowReference(for image: ImageSummary) -> String {
        image.isDangling ? image.shortID : (image.repoTags.first ?? image.shortID)
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
        // Row identity per docs/design/ACCESSIBILITY-IDENTIFIERS.md. `Table` has no
        // row-level accessibility-identifier modifier (unlike `List`), so the
        // identifier is carried by the primary (Repository) column's cell.
        .accessibilityIdentifier("images.row.\(rowReference(for: image))")
    }

    /// The architecture, sitting inline in the repository column.
    ///
    /// A native image gets no chip at all — a badge on every row is wallpaper by the
    /// second screenful — and only the mismatch that costs something is worth ink.
    @ViewBuilder
    private func architectureLabel(_ image: ImageSummary) -> some View {
        if let badge = TrackCImageArch.badge(for: image.architecture), badge.isNoteworthy {
            Image(systemName: badge.symbol ?? "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Architecture mismatch: \(badge.text)")
                .accessibilityHint("This image is not built for this Mac’s native architecture.")
                .help("This image is built for \(badge.text), not this Mac's native architecture")
        }
    }

    @ViewBuilder
    private func usageCell(_ image: ImageSummary) -> some View {
        // `-1` means `/images/json` didn't carry a count and the Disk scan hasn't
        // filled it in yet (`AppModel.mergeImageUsageFromDisk`) — not the same fact as
        // zero, and it must not render as a confident "unused". Same vocabulary as the
        // Volumes "In use" column, which has the identical two-source shape.
        if image.containersUsing < 0 {
            Text("—")
                .foregroundStyle(.tertiary)
                .accessibilityLabel(TrackCImageInspector.unscannedValue)
                .help("In-use counts come from the Disk scan. Open Disk to compute them.")
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
            Button("Tag Image…") {
                imageTagTarget = image
            }
            .disabled(!canMutateImages)
            .help(imageMutationHelp("Create an additional local tag"))
            Divider()
            Button("Run Local Image…") {
                localImageRun = image
            }
            .disabled(runLocalImageAction == nil)
            Divider()
            Button("Export Image Archive…") {
                chooseImageArchiveDestination(for: image)
            }
            .disabled(!canExportImages)
            .help(imageExportHelp("Export this image as a Docker archive"))
            Divider()
            Button("Remove…", role: .destructive) { removal = ImageRemovalConfirmation(image: image) }
                .disabled(!canMutateImages)
                .help(imageMutationHelp("Remove the selected image"))
        }
    }

    // MARK: Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let image = selectedImage {
            Form {
                Section("Image") {
                    LabeledContent("Reference") {
                        Text(image.repoTags.first ?? "Untagged layer")
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Image ID") {
                        Text(image.id)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Size", value: Formatters.bytesString(image.size))
                    architectureField(image)
                }

                Section("History") {
                    LabeledContent("Created", value: Formatters.absoluteDate(image.createdAt))
                }

                // Tags are secondary facts for the selected image. A direct system
                // disclosure avoids wrapping one control in an empty form section.
                if !image.isDangling, !image.repoTags.isEmpty {
                    DisclosureGroup("Repo Tags (\(image.repoTags.count))", isExpanded: $repoTagsExpanded) {
                        ForEach(image.repoTags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }

                containerReferencesSection(for: image)
                compatibilitySection(for: image)

                Section("Archive") {
                    Button {
                        chooseImageArchiveForLoading()
                    } label: {
                        // SF Symbol convention: up = export/share, down = import/save.
                        Label("Load Image Archive…", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!canImportImages)
                    .help(imageImportHelp("Load a local Docker image archive"))

                    Button {
                        chooseImageArchiveDestination(for: image)
                    } label: {
                        // SF Symbol convention: up = export/share, down = import/save.
                        Label("Export Image Archive…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!canExportImages)
                    .help(imageExportHelp("Export this image as a Docker archive"))
                }

                Section("Actions") {
                    Button("Tag Image…") {
                        imageTagTarget = image
                    }
                    .disabled(!canMutateImages)
                    .help(imageMutationHelp("Create an additional local tag"))
                    Button("Remove Image…", role: .destructive) {
                        removal = ImageRemovalConfirmation(image: image)
                    }
                    .disabled(!canMutateImages)
                    .help(imageMutationHelp("Remove the selected image"))
                }
            }
            // The automatic system Form chooses the current macOS inspector alignment.
            // There is no custom surface, card, background, property grid, or row
            // treatment here.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView {
                Label("No Image Selected", systemImage: "square.on.square")
            } description: {
                Text("Select a local image to inspect its identity, history, tags, and container references.")
            } actions: {
                // Offer a goal, not a workaround: "select the first row" is not a task
                // anyone has. Pulling an image is.
                Button("Pull an Image") {
                    presentPull()
                }
            }
        }
    }

    /// Image-list `Containers` is the source of truth for the count. Container names
    /// are shown only when the separate inventory still has an exact image ID or tag
    /// reference; retagging and refresh skew become an honest reconciliation message.
    @ViewBuilder
    private func containerReferencesSection(for image: ImageSummary) -> some View {
        let usage = TrackCImageInspector.containerUsage(for: image, in: model.containers)

        Section("Container References") {
            switch usage {
            case .unreported(let known):
                // `image.containersUsing < 0` means the Disk scan that fills it in
                // (`AppModel.mergeImageUsageFromDisk`, TASTE-5) has not run yet — a
                // remedy, not a dead end, so this uses the same word and the same
                // one-footnote-naming-the-remedy shape as Volumes' unscanned Usage row.
                LabeledContent("Reported use", value: TrackCImageInspector.unscannedValue)
                if !known.isEmpty {
                    containerReferenceRows(known)
                }
                Text("Container references come from the Disk scan. Open Disk to compute them.")
                    .foregroundStyle(.secondary)

            case .none:
                LabeledContent("Reported use", value: "No containers")

            case .complete(let known):
                LabeledContent("Reported use", value: containerCountDescription(known.count))
                containerReferenceRows(known)

            case .incomplete(let known, let reported):
                LabeledContent("Reported use", value: containerCountDescription(reported))
                containerReferenceRows(known)
                Text("\(reported - known.count) referenced container\(reported - known.count == 1 ? "" : "s") are not present in the current container inventory. Refresh to reconcile the two Docker responses.")
                    .foregroundStyle(.secondary)

            case .inconsistent(let known, let reported):
                LabeledContent("Reported use", value: containerCountDescription(reported))
                containerReferenceRows(known)
                Text("The current container inventory has \(containerCountDescription(known.count)), but Docker's image inventory reports \(containerCountDescription(reported)). Refresh to reconcile the two Docker responses.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func containerReferenceRows(_ containers: [ContainerSummary]) -> some View {
        ForEach(containers) { container in
            LabeledContent("Container") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(container.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(container.statusDisplay())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    private func containerCountDescription(_ count: Int) -> String {
        "\(count) container\(count == 1 ? "" : "s")"
    }

    /// The platform is a single selected-record fact; compatibility guidance has its
    /// own Form section instead of becoming a small custom dashboard inside this value.
    @ViewBuilder
    private func architectureField(_ image: ImageSummary) -> some View {
        LabeledContent("Architecture") {
            if let architecture = image.architecture {
                Text(architecture.platformString)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            } else {
                // A missing image-list descriptor is not evidence of the native
                // architecture. The selection task triggers a bounded inspection, but
                // that request can fail or an older engine can omit the fact entirely.
                Text("Not reported")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func compatibilitySection(for image: ImageSummary) -> some View {
        if let badge = TrackCImageArch.badge(for: image.architecture), badge.isNoteworthy {
            Section("Compatibility") {
                if let consequence = badge.consequenceLabel {
                    LabeledContent("Status", value: consequence)
                }
                if let advice = TrackCImageArch.advice(
                    for: badge,
                    rosettaAvailable: model.rosetta.availability == .active)
                {
                    Label(advice, systemImage: badge.symbol ?? "info.circle")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Operations

    /// Starts one fresh, explicit pull review. A public discovery result may prefill
    /// the reference, but no request reaches Docker until the person confirms from the
    /// standard Pull Image form.
    @MainActor
    private func presentPull(reference: String? = nil) {
        guard !isPulling else { return }
        pullReference = reference ?? ""
        pullLines = []
        pullState = .ready
        showingPull = true
    }

    @MainActor
    private func presentDiscoveredPullIfNeeded() {
        guard let reference = pendingDiscoveredPullReference else { return }
        pendingDiscoveredPullReference = nil
        presentPull(reference: reference)
    }

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
        guard canExportImages else { return }

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

    /// Begins with the system-owned document chooser rather than a text field or an
    /// inferred default path. The review sheet is a separate explicit boundary before
    /// any bytes reach Docker. `NSOpenPanel` offers Docker-supported tar and compressed
    /// tar filename forms; the typed service deliberately does not inspect contents.
    @MainActor
    private func chooseImageArchiveForLoading() {
        guard canImportImages else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = imageArchiveImportContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.message = "Choose a local Docker image archive (.tar, .tar.gz, .tar.bz2, .tar.xz, or .tar.zst) to load into Morbstack."
        panel.prompt = "Choose"

        guard panel.runModal() == .OK, let archiveURL = panel.url else { return }
        do {
            imageArchiveImportReview = try ImageArchiveImportRequest(archiveURL: archiveURL)
        } catch {
            imageArchiveImportNotice = .failure(error)
        }
    }

    /// The review sheet dismisses before this begins so the system never stacks two
    /// independent document sheets. A source is validated again by the importer just
    /// before opening the Engine request, which catches a changed file after review.
    @MainActor
    private func beginPendingImageArchiveImport() {
        guard let request = pendingImageArchiveImport else { return }
        pendingImageArchiveImport = nil
        guard canImportImages else { return }

        let cancellation = ImageArchiveImportCancellation()
        let operation = ImageArchiveImportOperation(request: request)
        imageArchiveImport = operation
        imageArchiveImportCancellation = cancellation

        let operationID = operation.id
        let progressRelay = ImageArchiveImportProgressRelay { progress in
            self.recordImageArchiveImportProgress(progress, for: operationID)
        }
        Task.detached(priority: .userInitiated) {
            do {
                let result = try ImageArchiveImporter.load(
                    request,
                    onProgress: { progress in
                        switch progress {
                        case .uploading:
                            progressRelay.send(progress)
                        case .waitingForDocker:
                            progressRelay.sendImmediately(progress)
                        }
                    },
                    isCancelled: { cancellation.isRequested })
                await self.finishImageArchiveImport(.success(result), for: operationID)
            } catch {
                await self.finishImageArchiveImport(.failure(error), for: operationID)
            }
        }
    }

    @MainActor
    private func cancelImageArchiveImport() {
        guard var operation = imageArchiveImport, operation.canCancel else { return }
        operation.isCancellationRequested = true
        imageArchiveImport = operation
        imageArchiveImportCancellation?.request()
    }

    @MainActor
    private func recordImageArchiveImportProgress(
        _ progress: ImageArchiveImportProgress,
        for operationID: UUID
    ) {
        guard var operation = imageArchiveImport, operation.id == operationID else { return }
        operation.record(progress)
        imageArchiveImport = operation
    }

    @MainActor
    private func finishImageArchiveImport(
        _ result: Result<ImageArchiveImportResult, Error>,
        for operationID: UUID
    ) async {
        guard imageArchiveImport?.id == operationID else { return }
        imageArchiveImport = nil
        imageArchiveImportCancellation = nil

        // Any socket failure or cancellation can arrive after Docker consumed a prefix
        // of the tar. Refreshing is safe and gives the next view the Engine's current
        // inventory without treating that refresh as proof of a particular tag.
        await model.refreshAll()

        switch result {
        case .success(let imported):
            imageArchiveImportNotice = .success(result: imported)
        case .failure(let error):
            if let importError = error as? ImageArchiveImportError,
               case .cancelled(let bytesSent, let totalBytes) = importError
            {
                imageArchiveImportNotice = .cancelled(bytesSent: bytesSent, totalBytes: totalBytes)
            } else {
                imageArchiveImportNotice = .failure(error)
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
        guard let reference = pullReferenceToSubmit, pullState.allowsPull else { return }

        pullReference = reference
        pullState = .pulling(reference: reference)
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
            await model.refreshAll()
            pullState = .succeeded(reference: reference)
        } catch {
            pump.cancel()
            pullLines = TrackCPullLog.appending(contentsOf: buffer.drain(), to: pullLines)
            pullState = .failed(reference: reference, message: MorbErrorMessage.text(for: error))
        }
    }

    @MainActor
    private func tagImage(_ request: ImageTagRequest) async throws {
        try await model.client.tagImage(request)
        await model.refreshAll()
    }

    @MainActor
    private func remove(_ image: ImageSummary) async {
        busy = true
        defer { busy = false }
        do {
            try await model.client.removeImage(id: image.id)
            if selection == image.id { selection = nil }
            await model.refreshAll()
        } catch {
            operationFailure = removalFailure(for: error)
        }
    }

    private func removalFailure(for error: Error) -> ImageOperationFailure {
        let title: String
        if let clientError = error as? DockerClientError,
           case .http = clientError {
            title = "Docker Refused to Remove Image"
        } else {
            title = "Couldn’t Remove Image"
        }
        return ImageOperationFailure(title: title, message: MorbErrorMessage.text(for: error))
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
