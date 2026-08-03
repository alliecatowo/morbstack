// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// A native source-inspection route with a narrow, selected-images transaction.
//
// The public `MigrationReadOnlyPlanner` derives an image comparison only after both
// existing Docker engines respond to read-only requests. The separately labeled
// images-only workflow begins with an empty selection, derives a fresh plan before a
// scoped review, and only calls `ImageMigrationTransaction.execute` from the explicit
// confirmation action. Named volumes have a separate GET-only eligibility comparison;
// this route never creates a helper container or transfers a volume. No route path
// starts a runtime, asks a credential helper, writes Docker configuration, or performs
// an implicit import.

import Foundation
import MorbMigrate
import Observation
import SwiftUI

// MARK: - Read-only migration inspection

struct MigrationRuntime: Identifiable, Sendable, Equatable {
    let name: String
    let installed: Bool
    let installPath: String?
    let socketPath: String?
    let running: Bool
    let engineVersion: String?
    let images: Int?
    let containers: Int?
    let volumes: Int?
    let imageBytes: Int64?
    let notes: [String]

    init(_ report: RuntimeReport) {
        name = report.name
        installed = report.installed
        installPath = report.installPath
        socketPath = report.socketPath
        running = report.running
        engineVersion = report.engineVersion
        images = report.images
        containers = report.containers
        volumes = report.volumes
        imageBytes = report.imageBytes
        notes = report.notes
    }

    var id: String { name }

    var status: String {
        if running { return "Running" }
        return installed ? "Not Running" : "Not Installed"
    }

    var transferSourceToken: String? {
        switch name {
        case "Docker Desktop": return "docker-desktop"
        case "Colima": return "colima"
        case "OrbStack": return "orbstack"
        default: return nil
        }
    }
}

struct MigrationDockerConfiguration: Sendable, Equatable {
    let directory: String
    let isPresent: Bool
    let currentContext: String
    let credentialStore: String?
    let usesDesktopCredentialStore: Bool
    let contexts: [String]
    let registriesWithStoredCredentials: [String]

    init() {
        let directory = DockerCLIConfigReader.dockerConfigDirectory()
        let config = DockerCLIConfigReader.read()
        self.directory = directory.path
        isPresent = config != nil
        currentContext = config?.currentContext ?? "default"
        credentialStore = config?.credsStore
        usesDesktopCredentialStore = config?.credsStoreIsDesktopHelper ?? false
        contexts = DockerContextsStore.readAll(dockerConfigDirectory: directory).map(\.name)
        registriesWithStoredCredentials = config?.registriesWithAuth ?? []
    }
}

struct MigrationInspection: Sendable, Equatable {
    let runtimes: [MigrationRuntime]
    let dockerConfiguration: MigrationDockerConfiguration

    static func collect() -> MigrationInspection {
        MigrationInspection(
            runtimes: [
                RuntimeDetect.detectDockerDesktop(),
                RuntimeDetect.detectColima(),
                RuntimeDetect.detectOrbStack(),
                RuntimeDetect.detectMorbstack(),
            ].map(MigrationRuntime.init),
            dockerConfiguration: MigrationDockerConfiguration())
    }
}

// MARK: - Native route

struct MigrationRootView: View {

    let model: AppModel

    @State private var inspection: MigrationInspection?
    @State private var selection: MigrationRuntime.ID?
    @State private var showsInspector = true
    @State private var isInspecting = false
    @State private var readOnlyPlan: MigrationReadOnlyPlan?
    @State private var plannedRuntimeID: MigrationRuntime.ID?
    @State private var isPlanning = false
    @State private var imageMigration = ImageMigrationWorkflow()

    private var runtimes: [MigrationRuntime] { inspection?.runtimes ?? [] }

    private var runningSourceCount: Int {
        runtimes.filter { $0.running && $0.transferSourceToken != nil }.count
    }

    private var subtitle: String {
        guard inspection != nil else { return isInspecting ? "Inspecting runtimes…" : "Read-only inspection" }
        let source = "\(runningSourceCount) running source\(runningSourceCount == 1 ? "" : "s")"
        guard imageMigration.latestReport != nil else { return "\(source) · No data imported" }
        return "\(source) · \(imageMigration.reportSummary)"
    }

    private var selectedRuntime: MigrationRuntime? {
        guard let selection else { return nil }
        return runtimes.first { $0.id == selection }
    }

    var body: some View {
        content
            .navigationTitle("Migration")
            .navigationSubtitle(subtitle)
            .toolbar { toolbarContent }
            .sheet(isPresented: $imageMigration.isPresented) {
                imageMigrationSheet
                    .interactiveDismissDisabled(imageMigration.stage == .transferring)
            }
            .alert(
                "Image Migration Couldn’t Continue",
                isPresented: Binding(
                    get: { imageMigration.errorMessage != nil },
                    set: { if !$0 { imageMigration.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {
                    imageMigration.errorMessage = nil
                }
            } message: {
                Text(imageMigration.errorMessage ?? "")
            }
            .task {
                await inspect()
            }
            .onChange(of: runtimes) { _, _ in
                selectFirstRuntimeIfNeeded()
            }
            .onChange(of: selection) { _, newValue in
                if newValue != nil {
                    showsInspector = true
                    Task { await inspectPlanForSelectedRuntime() }
                }
            }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(id: "migration.refresh", placement: .primaryAction) {
            Button {
                Task { await inspect() }
            } label: {
                if isInspecting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .accessibilityLabel(isInspecting ? "Inspecting migration sources" : "Refresh migration inspection")
            .help("Refresh local runtime readiness and the selected image comparison")
            .disabled(isInspecting || model.launchOptions.tourFixtures)
        }

        if !runtimes.isEmpty {
            ToolbarItem(id: "migration.inspector", placement: .primaryAction) {
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
    private var content: some View {
        if model.launchOptions.tourFixtures {
            ContentUnavailableView {
                Label("Migration Inspection Is Unavailable in Fixtures", systemImage: "arrow.left.arrow.right")
            } description: {
                Text("Migration inspection reads local runtime sockets and Docker configuration, so fixture launches never run it against your Mac.")
            }
        } else if inspection == nil {
            ProgressView("Inspecting local container runtimes…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(runtimes, selection: $selection) {
                TableColumn("Runtime") { runtime in
                    Text(runtime.name)
                }
                .width(min: 140, ideal: 180, max: 260)
                TableColumn("Status") { runtime in
                    Text(runtime.status)
                        .foregroundStyle(.secondary)
                }
                .width(min: 92, ideal: 108, max: 132)
                TableColumn("Images") { runtime in
                    count(runtime.images)
                }
                .width(min: 66, ideal: 76, max: 96)
                TableColumn("Volumes") { runtime in
                    count(runtime.volumes)
                }
                .width(min: 72, ideal: 82, max: 104)
                TableColumn("Image Storage") { runtime in
                    Text(runtime.imageBytes.map(Formatters.bytesString) ?? "—")
                        .monospacedDigit()
                }
                .width(min: 92, ideal: 112, max: 144)
            }
            .tableStyle(.automatic)
            .inspector(isPresented: $showsInspector) {
                detailPane
                    .inspectorColumnWidth(min: 280, ideal: 340, max: 460)
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let runtime = selectedRuntime, let inspection {
            Form {
                Section("Runtime") {
                    LabeledContent("Status", value: runtime.status)
                    LabeledContent("Engine Version", value: runtime.engineVersion ?? "—")
                    LabeledContent("Images", value: runtime.images.map(String.init) ?? "—")
                    LabeledContent("Containers", value: runtime.containers.map(String.init) ?? "—")
                    LabeledContent("Volumes", value: runtime.volumes.map(String.init) ?? "—")
                    LabeledContent("Image Storage", value: runtime.imageBytes.map(Formatters.bytesString) ?? "—")
                    if let installPath = runtime.installPath {
                        LabeledContent("Installed At") {
                            Text(installPath)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                    if let socketPath = runtime.socketPath {
                        LabeledContent("Active Socket") {
                            Text(socketPath)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                    ForEach(runtime.notes, id: \.self) { note in
                        Text(note)
                            .foregroundStyle(.secondary)
                    }
                }

                transferSection(for: runtime)
                latestImageMigrationSection
                dockerConfigurationSection(inspection.dockerConfiguration)
            }
        } else {
            ContentUnavailableView(
                "No Runtime Selected",
                systemImage: "arrow.left.arrow.right",
                description: Text("Select a container runtime to review its migration readiness."))
        }
    }

    @ViewBuilder
    private func transferSection(for runtime: MigrationRuntime) -> some View {
        Section {
            if runtime.transferSourceToken != nil {
                LabeledContent("Image Plan", value: imagePlanStatus(for: runtime))
                if isPlanning && plannedRuntimeID != runtime.id {
                    ProgressView("Comparing image inventories…")
                        .controlSize(.small)
                } else if let plan = plan(for: runtime), let images = plan.imagePlan {
                    LabeledContent(
                        "Would Copy",
                        value: "\(images.wouldCopy.count) images · \(Formatters.bytesString(images.wouldCopyBytes))")
                    LabeledContent("Already Present", value: "\(images.alreadyPresent.count) images")
                    Text(
                        images.items.isEmpty
                            ? "No tagged images matched this comparison."
                            : "The selected source and the running Morbstack engine were compared directly. No image data was imported.")
                        .foregroundStyle(.secondary)

                    if !images.wouldCopy.isEmpty {
                        Button("Select Images to Import…") {
                            presentImageMigration(for: runtime, candidates: images.wouldCopy)
                        }
                        Text(
                            "Choose one or more images for review. Morbstack never selects every image automatically."
                        )
                        .foregroundStyle(.secondary)
                    }
                } else if let unavailableReason = plan(for: runtime)?.unavailableReason {
                    Text(unavailableReason)
                        .foregroundStyle(.secondary)
                } else if runtime.running {
                    Text("Select Refresh to derive a comparison from the two running engines.")
                        .foregroundStyle(.secondary)
                }

                if isPlanning && plannedRuntimeID != runtime.id {
                    LabeledContent("Named Volume Eligibility", value: "Inspecting…")
                    ProgressView("Reading named-volume inventories…")
                        .controlSize(.small)
                } else if let volumes = plan(for: runtime)?.volumePlan {
                    LabeledContent("Named Volume Eligibility", value: "Read Only")
                    LabeledContent("Eligible", value: "\(volumes.eligible.count) volumes")
                    LabeledContent("Destination Exists", value: "\(volumes.destinationExisting.count) volumes")
                    LabeledContent("Unsupported Driver", value: "\(volumes.unsupported.count) volumes")

                    if volumes.items.isEmpty {
                        ContentUnavailableView {
                            Label("No Named Volumes", systemImage: "externaldrive")
                        } description: {
                            Text("The selected source reported no named volumes.")
                        }
                        .frame(height: 128)
                    } else {
                        Table(volumes.items) {
                            TableColumn("Volume") { volume in
                                Text(volume.name)
                                    .font(.body.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .width(min: 120, ideal: 160)

                            TableColumn("Driver") { volume in
                                Text(volume.driver)
                                    .lineLimit(1)
                            }
                            .width(min: 72, ideal: 96)

                            TableColumn("Eligibility") { volume in
                                VStack(alignment: .leading, spacing: 2) {
                                    switch volume.disposition {
                                    case .eligible:
                                        Text("Eligible")
                                    case .destinationExists:
                                        Text("Destination Exists")
                                    case .unsupportedDriver:
                                        Text("Unsupported Driver")
                                    }
                                    Text(volume.reason)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .width(min: 180, ideal: 260)
                        }
                        .frame(minHeight: 120, idealHeight: 180, maxHeight: 260)
                        .accessibilityLabel("Read-only named volume eligibility")
                    }

                    Text(
                        "Eligibility compares names and drivers only. Volume contents, free space, overwrite safety, and merge behavior were not inspected.")
                        .foregroundStyle(.secondary)
                } else if let unavailableReason = plan(for: runtime)?.volumeUnavailableReason {
                    LabeledContent("Named Volume Eligibility", value: "Unavailable")
                    Text(unavailableReason)
                        .foregroundStyle(.secondary)
                } else if runtime.running {
                    LabeledContent("Named Volume Eligibility", value: "Not Inspected")
                    Text("Select Refresh to compare named-volume inventories from the two running engines.")
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Named Volume Eligibility", value: "Source Not Running")
                    Text("Start the selected source runtime before requesting a read-only inventory comparison.")
                        .foregroundStyle(.secondary)
                }

            } else {
                Text(
                    "Morbstack is the migration destination. Select a running Docker Desktop, Colima, or OrbStack source to review its readiness.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Migration")
        } footer: {
            Text(
                "Inspection stays read-only. The separately labeled import action transfers only the images you select after a second review; named-volume eligibility does not transfer a volume. This route never starts a runtime or writes Docker configuration.")
        }
    }

    private func dockerConfigurationSection(_ configuration: MigrationDockerConfiguration) -> some View {
        Section("Docker CLI") {
            LabeledContent("Configuration", value: configuration.isPresent ? "Found" : "Not Found")
            LabeledContent("Current Context", value: configuration.currentContext)
            LabeledContent("Credential Store", value: configuration.credentialStore ?? "None")
            LabeledContent("Registered Contexts", value: configuration.contexts.isEmpty ? "None" : configuration.contexts.joined(separator: ", "))
            LabeledContent(
                "Stored Registry Entries",
                value: configuration.registriesWithStoredCredentials.isEmpty
                    ? "None" : configuration.registriesWithStoredCredentials.joined(separator: ", "))
            if configuration.usesDesktopCredentialStore {
                Text(
                    "The Docker Desktop credential helper may stop answering after Docker Desktop is no longer running. Morbstack only reports this setting; it never edits your Docker configuration.")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Directory") {
                Text(configuration.directory)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    private func count(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "—")
            .monospacedDigit()
    }

    private func imagePlanStatus(for runtime: MigrationRuntime) -> String {
        guard runtime.running else { return "Source not running" }
        guard plannedRuntimeID == runtime.id, let plan = readOnlyPlan else {
            return isPlanning ? "Comparing…" : "Not inspected"
        }
        guard let images = plan.imagePlan else { return "Unavailable" }
        return "\(images.wouldCopy.count) to copy"
    }

    private func plan(for runtime: MigrationRuntime) -> MigrationReadOnlyPlan? {
        plannedRuntimeID == runtime.id ? readOnlyPlan : nil
    }

    @MainActor
    private func inspect() async {
        guard !isInspecting, !model.launchOptions.tourFixtures else { return }
        isInspecting = true
        defer { isInspecting = false }

        let report = await Task.detached(priority: .utility) {
            MigrationInspection.collect()
        }.value
        inspection = report
        selectFirstRuntimeIfNeeded()
        await inspectPlanForSelectedRuntime()
    }

    @MainActor
    private func inspectPlanForSelectedRuntime() async {
        guard !model.launchOptions.tourFixtures, !isPlanning else { return }
        guard let runtime = selectedRuntime, let source = runtime.transferSourceToken else {
            readOnlyPlan = nil
            plannedRuntimeID = nil
            return
        }

        isPlanning = true
        defer { isPlanning = false }
        readOnlyPlan = nil
        plannedRuntimeID = nil
        let plan = await Task.detached(priority: .utility) {
            MigrationReadOnlyPlanner.inspect(from: source)
        }.value
        guard selection == runtime.id else { return }
        readOnlyPlan = plan
        plannedRuntimeID = runtime.id
    }

    private func selectFirstRuntimeIfNeeded() {
        if let selection, runtimes.contains(where: { $0.id == selection }) { return }
        selection = runtimes.first(where: { $0.running && $0.transferSourceToken != nil })?.id
            ?? runtimes.first(where: { $0.transferSourceToken != nil })?.id
            ?? runtimes.first?.id
    }

    // MARK: - Images-only transaction workflow

    @ViewBuilder
    private var imageMigrationSheet: some View {
        switch imageMigration.stage {
        case .selection:
            MigrationImageSelectionSheet(
                source: imageMigration.source?.name ?? "Migration source",
                destination: "Morbstack",
                candidates: imageMigration.candidates,
                selectedIDs: $imageMigration.selectedIDs,
                isPreparing: imageMigration.isPreparing,
                onCancel: imageMigration.close,
                onReview: imageMigration.prepareSelection)

        case .review:
            if let prepared = imageMigration.prepared {
                MigrationImageReviewSheet(
                    prepared: prepared,
                    onBack: imageMigration.returnToSelection,
                    onConfirm: imageMigration.executePreparedSelection)
            }

        case .transferring:
            MigrationImageProgressSheet(
                progress: imageMigration.progress,
                cancellationRequested: imageMigration.cancellationRequested,
                onCancelRemaining: imageMigration.requestCancellation)

        case .report:
            if let report = imageMigration.latestReport {
                MigrationImageReportSheet(
                    report: report,
                    retryCount: imageMigration.retryableItemCount,
                    onDone: imageMigration.close,
                    onRetry: imageMigration.retryLastReport)
            }
        }
    }

    @ViewBuilder
    private var latestImageMigrationSection: some View {
        if let report = imageMigration.latestReport {
            Section("Latest Image Import") {
                LabeledContent("Result", value: imageMigration.reportSummary)
                LabeledContent("Source", value: report.source.name)
                LabeledContent("Destination", value: report.destination.name)
                LabeledContent("Report") {
                    if let reportPath = report.reportPath {
                        Text(reportPath)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    } else {
                        Text(report.reportWriteError ?? "Not written")
                            .foregroundStyle(.secondary)
                    }
                }

                if report.hasFailuresOrReview || report.cancellationObserved {
                    Text(
                        "Inspect items that require review before cleanup. Morbstack never assumes a failed or cancelled transfer left the destination unchanged.")
                        .foregroundStyle(.secondary)
                }

                if imageMigration.retryableItemCount > 0 {
                    Button("Retry Unfinished Images…") {
                        imageMigration.retryLastReport()
                    }
                    Text(
                        "Retry opens a new selection and review. It does not resume or import anything automatically."
                    )
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func presentImageMigration(
        for runtime: MigrationRuntime,
        candidates: [MigrationImagePlanItem]
    ) {
        imageMigration.begin(source: runtime, candidates: candidates)
    }
}

// MARK: - Images-only migration sheets

/// A document-modal selection step. A standard multi-select `Table` makes the exact
/// record set visible and keyboard-accessible without inventing checkbox cards or a
/// separate selection control. It always starts empty; retry is the one explicit,
/// report-backed exception and still comes back through this review screen.
private struct MigrationImageSelectionSheet: View {
    let source: String
    let destination: String
    let candidates: [MigrationImagePlanItem]
    @Binding var selectedIDs: Set<MigrationImagePlanItem.ID>
    let isPreparing: Bool
    let onCancel: () -> Void
    let onReview: () -> Void

    private var selectedItems: [MigrationImagePlanItem] {
        candidates.filter { selectedIDs.contains($0.id) }
    }

    private var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section("Transfer") {
                        LabeledContent("Source", value: source)
                        LabeledContent("Destination", value: destination)
                        LabeledContent(
                            "Selected",
                            value: "\(selectedItems.count) of \(candidates.count) images")
                        LabeledContent("Estimated Size", value: Formatters.bytesString(selectedBytes))
                    }

                    Section {
                        Text(
                            "Select the exact local images to review. Morbstack does not infer an all-images selection, contact a registry, or use stored credentials.")
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Selection")
                    }
                }

                Table(candidates, selection: $selectedIDs) {
                    TableColumn("Image") { image in
                        Text(image.reference)
                            .font(.body.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .width(min: 220, ideal: 320)

                    TableColumn("Size") { image in
                        Text(Formatters.bytesString(image.sizeBytes))
                            .monospacedDigit()
                    }
                    .width(min: 84, ideal: 100, max: 120)

                    TableColumn("Image ID") { image in
                        Text(image.imageID)
                            .font(.body.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 130, ideal: 180)
                }
                .tableStyle(.automatic)
                .accessibilityLabel("Images available to import")
            }
            .navigationTitle("Select Images to Import")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onReview) {
                        if isPreparing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Review Selected Images")
                        }
                    }
                    .disabled(selectedItems.isEmpty || isPreparing)
                    .accessibilityLabel(
                        isPreparing ? "Rechecking selected images" : "Review selected images before import")
                }
            }
        }
        .frame(minWidth: 620, minHeight: 470)
    }
}

/// The second, scoped review is the native confirmation boundary for a state-changing
/// operation. `ImageMigrationTransaction.prepare` has just recomputed this exact set
/// from both engines; this sheet is deliberately not an alert because it must show
/// the selected records, endpoint, exclusions, and cancellation contract together.
private struct MigrationImageReviewSheet: View {
    let prepared: PreparedImageMigration
    let onBack: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section("Images to Import") {
                        LabeledContent("Source", value: prepared.source.name)
                        LabeledContent("Destination", value: prepared.destination.name)
                        LabeledContent(
                            "Selection",
                            value: "\(prepared.items.count) image\(prepared.items.count == 1 ? "" : "s")")
                        LabeledContent("Estimated Size", value: Formatters.bytesString(prepared.totalBytes))
                        LabeledContent("Source Access", value: prepared.sourceUntouched ? "Read-only" : "Changed")
                        Text(
                            "Before each import, Morbstack checks that the source tag still resolves to this image ID and that the destination tag has not changed.")
                            .foregroundStyle(.secondary)
                    }

                    Section("Not Included") {
                        ForEach(prepared.excludedScopes, id: \.self) { scope in
                            Text(scope)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Cancellation") {
                        Text(
                            "You can stop remaining images while the transfer runs. If an image is already loading into Morbstack, its load and verification finish before the remaining selected images stop.")
                            .foregroundStyle(.secondary)
                    }
                }

                Table(prepared.items) {
                    TableColumn("Image") { image in
                        Text(image.reference)
                            .font(.body.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .width(min: 220, ideal: 320)

                    TableColumn("Size") { image in
                        Text(Formatters.bytesString(image.sizeBytes))
                            .monospacedDigit()
                    }
                    .width(min: 84, ideal: 100, max: 120)

                    TableColumn("Prepared Image ID") { image in
                        Text(image.imageID)
                            .font(.body.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 150, ideal: 190)
                }
                .tableStyle(.automatic)
                .accessibilityLabel("Images confirmed for import")
            }
            .navigationTitle("Review Image Import")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back", action: onBack)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        "Import \(prepared.items.count) Image\(prepared.items.count == 1 ? "" : "s")",
                        action: onConfirm)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 520)
    }
}

private struct MigrationImageProgressSheet: View {
    let progress: ImageMigrationProgress?
    let cancellationRequested: Bool
    let onCancelRemaining: () -> Void

    private var total: Int { progress?.totalImageCount ?? 0 }
    private var completed: Int { progress?.completedImageCount ?? 0 }

    private var phaseTitle: String {
        switch progress?.phase {
        case .checkingPreconditions: return "Checking selected image"
        case .exporting: return "Exporting source archive"
        case .importing: return "Importing into Morbstack"
        case .verifying: return "Verifying image IDs"
        case .completedImage: return "Completed image"
        case .writingReport: return "Writing migration report"
        case .cancelled: return "Stopping remaining imports"
        case .completed: return "Finalizing import"
        case .prepared, .none: return "Preparing selected images"
        }
    }

    private var detail: String? {
        if let image = progress?.imageReference { return image }
        return progress?.detail
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Transfer Progress") {
                    if total > 0 {
                        ProgressView(value: Double(completed), total: Double(total)) {
                            Text(phaseTitle)
                        } currentValueLabel: {
                            Text("\(completed) of \(total) images")
                                .monospacedDigit()
                        }
                    } else {
                        ProgressView(phaseTitle)
                    }

                    if let detail {
                        LabeledContent("Current Item") {
                            Text(detail)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }

                    if let bytes = progress?.bytesTransferred {
                        LabeledContent("Transferred", value: Formatters.bytesString(bytes))
                    }
                }

                Section("Cancellation") {
                    Text(
                        cancellationRequested
                            ? "Morbstack will stop before the next image. An image already loading is allowed to finish and is verified before the report is written."
                            : "Stopping does not roll back a destination image. Review the final report before retrying or removing any tag.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Importing Images")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        cancellationRequested ? "Stopping Remaining Images" : "Stop Remaining Images",
                        role: .cancel,
                        action: onCancelRemaining)
                    .disabled(cancellationRequested)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 300)
    }
}

private struct MigrationImageReportSheet: View {
    let report: ImageMigrationTransactionReport
    let retryCount: Int
    let onDone: () -> Void
    let onRetry: () -> Void

    private var result: String {
        if report.isFullyVerified { return "All selected images verified" }
        if report.cancellationObserved { return "Stopped before all selected images finished" }
        return "Review required"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section("Result") {
                        LabeledContent("Status", value: result)
                        LabeledContent("Source", value: report.source.name)
                        LabeledContent("Destination", value: report.destination.name)
                        LabeledContent("Source State", value: report.sourceUntouched ? "Unchanged" : "Unknown")
                        LabeledContent("Report") {
                            if let path = report.reportPath {
                                Text(path)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            } else {
                                Text(report.reportWriteError ?? "Not written")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if report.hasFailuresOrReview || report.cancellationObserved {
                        Section("Follow-up") {
                            Text(
                                "A failed or review-required item is not proof that the destination is unchanged. Inspect its recorded result before cleanup. Items that require review are never retried automatically.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Table(report.items) {
                    TableColumn("Image") { item in
                        Text(item.reference)
                            .font(.body.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .width(min: 180, ideal: 260)

                    TableColumn("Result") { item in
                        Text(item.outcome.displayName)
                    }
                    .width(min: 104, ideal: 124, max: 150)

                    TableColumn("Verification") { item in
                        Text(item.verification.displayName)
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 110, ideal: 150, max: 190)

                    TableColumn("Archive") { item in
                        Text(Formatters.bytesString(item.archiveBytes))
                            .monospacedDigit()
                    }
                    .width(min: 78, ideal: 90, max: 110)

                    TableColumn("Detail") { item in
                        Text(item.detail ?? "—")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .width(min: 170, ideal: 250)
                }
                .tableStyle(.automatic)
                .accessibilityLabel("Image import report")
            }
            .navigationTitle("Image Import Report")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onDone)
                }
                if retryCount > 0 {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Retry Unfinished Images", action: onRetry)
                    }
                }
            }
        }
        .frame(minWidth: 650, minHeight: 500)
    }
}

private extension ImageMigrationItemOutcome {
    var displayName: String {
        switch self {
        case .verified: return "Verified"
        case .alreadyPresent: return "Already Present"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .requiresReview: return "Requires Review"
        }
    }
}

private extension ImageMigrationVerification {
    var displayName: String {
        switch self {
        case .notRun: return "Not Run"
        case .matched: return "Matched"
        case .sourceChanged: return "Source Changed"
        case .destinationMissing: return "Destination Missing"
        case .destinationDifferent: return "Destination Changed"
        case .destinationMatchesAfterLoadError: return "Matches After Error"
        case .unavailable: return "Unavailable"
        }
    }
}

// MARK: - Transaction state

/// Main-actor state for a single user-initiated migration workflow. The service
/// already owns the write contract; this object only manages native presentation,
/// selected-row identity, and a bounded progress stream back to the main actor.
@MainActor
@Observable
private final class ImageMigrationWorkflow {
    enum Stage {
        case selection
        case review
        case transferring
        case report
    }

    private enum PreparationResult: Sendable {
        case prepared(PreparedImageMigration)
        case failed(String)
    }

    private enum ExecutionResult: Sendable {
        case completed(ImageMigrationTransactionReport)
        case failed(String)
    }

    var isPresented = false
    var stage: Stage = .selection
    var source: MigrationRuntime?
    var candidates: [MigrationImagePlanItem] = []
    var selectedIDs: Set<MigrationImagePlanItem.ID> = []
    var prepared: PreparedImageMigration?
    var progress: ImageMigrationProgress?
    var isPreparing = false
    var cancellationRequested = false
    var errorMessage: String?
    var latestReport: ImageMigrationTransactionReport?

    private var latestSource: MigrationRuntime?
    private var latestCandidates: [MigrationImagePlanItem] = []
    private var cancellation: MigrationCancellationSignal?
    private var progressPump: Task<Void, Never>?

    var retryableItemCount: Int {
        latestReport?.items.filter(Self.isRetryable).count ?? 0
    }

    var reportSummary: String {
        guard let latestReport else { return "Not available" }
        if latestReport.isFullyVerified { return "All selected images verified" }
        if latestReport.cancellationObserved { return "Stopped before all images finished" }
        return "Review required"
    }

    func begin(source: MigrationRuntime, candidates: [MigrationImagePlanItem]) {
        self.source = source
        self.candidates = candidates
        selectedIDs = []
        prepared = nil
        progress = nil
        isPreparing = false
        cancellationRequested = false
        errorMessage = nil
        stage = .selection
        isPresented = true
    }

    func close() {
        guard stage != .transferring else { return }
        isPresented = false
        source = nil
        candidates = []
        selectedIDs = []
        prepared = nil
        progress = nil
        isPreparing = false
        cancellationRequested = false
        cancellation = nil
        stage = .selection
    }

    func returnToSelection() {
        guard stage == .review else { return }
        prepared = nil
        stage = .selection
    }

    func prepareSelection() {
        guard !isPreparing,
              let sourceToken = source?.transferSourceToken
        else {
            errorMessage = "Select a running Docker Desktop, Colima, or OrbStack source before importing images."
            return
        }

        let references = candidates
            .filter { selectedIDs.contains($0.id) }
            .map(\.reference)
        guard !references.isEmpty else {
            errorMessage = "Select one or more images before reviewing the import."
            return
        }

        isPreparing = true
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                do {
                    return PreparationResult.prepared(
                        try ImageMigrationTransaction.prepare(
                            from: sourceToken,
                            selection: .references(references)))
                } catch {
                    return PreparationResult.failed(String(describing: error))
                }
            }.value

            guard let self else { return }
            self.isPreparing = false
            switch result {
            case .prepared(let prepared):
                self.prepared = prepared
                self.stage = .review
            case .failed(let message):
                self.errorMessage = message
            }
        }
    }

    func executePreparedSelection() {
        guard stage == .review, let prepared else {
            errorMessage = "Review the selected images again before importing."
            return
        }

        let cancellation = MigrationCancellationSignal()
        self.cancellation = cancellation
        progress = nil
        cancellationRequested = false
        stage = .transferring

        var continuation: AsyncStream<ImageMigrationProgress>.Continuation?
        let updates = AsyncStream<ImageMigrationProgress>(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        guard let continuation else {
            errorMessage = "Could not start migration progress reporting."
            stage = .selection
            return
        }

        progressPump?.cancel()
        progressPump = Task { @MainActor [weak self] in
            for await update in updates {
                self?.progress = update
            }
        }

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                defer { continuation.finish() }
                do {
                    return ExecutionResult.completed(
                        try ImageMigrationTransaction.execute(
                            prepared,
                            confirmation: prepared.confirmation(),
                            progress: { continuation.yield($0) },
                            isCancelled: { cancellation.isRequested }))
                } catch {
                    return ExecutionResult.failed(String(describing: error))
                }
            }.value

            guard let self else { return }
            self.cancellation = nil
            switch result {
            case .completed(let report):
                self.latestReport = report
                self.latestSource = self.source
                self.latestCandidates = self.candidates
                self.stage = .report
            case .failed(let message):
                self.prepared = nil
                self.stage = .selection
                self.errorMessage = message
            }
        }
    }

    func requestCancellation() {
        guard stage == .transferring, !cancellationRequested else { return }
        cancellationRequested = true
        cancellation?.request()
    }

    func retryLastReport() {
        guard let latestReport, let latestSource else {
            errorMessage = "The source used for the last image import is no longer available for retry."
            return
        }
        let retryReferences = Set(latestReport.items.filter(Self.isRetryable).map(\.reference))
        guard !retryReferences.isEmpty else { return }

        source = latestSource
        candidates = latestCandidates
        selectedIDs = Set(
            latestCandidates
                .filter { retryReferences.contains($0.reference) }
                .map(\.id))
        prepared = nil
        progress = nil
        cancellationRequested = false
        errorMessage = nil
        stage = .selection
        isPresented = true
    }

    private static func isRetryable(_ item: ImageMigrationItemReport) -> Bool {
        item.outcome == .failed || item.outcome == .cancelled
    }
}

/// The transaction checks this callback from a synchronous EngineClient stream, so the
/// signal must be small, lock-protected, and usable from that non-main execution lane.
private final class MigrationCancellationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    var isRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    func request() {
        lock.lock()
        requested = true
        lock.unlock()
    }
}
