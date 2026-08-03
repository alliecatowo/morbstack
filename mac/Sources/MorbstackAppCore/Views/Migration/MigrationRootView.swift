// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// A read-only view of the migration sources `morb migrate` can inspect.
//
// `MorbMigrate` deliberately makes detection and Docker CLI configuration public,
// read-only APIs. Its transfer commands are intentionally not reused here: images
// expose terminal-rendered plan output rather than a structured plan, and volume dry
// runs can create a temporary helper container while checking destination contents.
// An app action that guessed at either result would make its scope look safer than it
// is, so this route inspects real runtimes and hands off the explicitly typed CLI dry
// run command instead. It never starts a runtime, writes Docker configuration, or
// imports data.

import MorbMigrate
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

    private var runtimes: [MigrationRuntime] { inspection?.runtimes ?? [] }

    private var runningSourceCount: Int {
        runtimes.filter { $0.running && $0.transferSourceToken != nil }.count
    }

    private var subtitle: String {
        guard inspection != nil else { return isInspecting ? "Inspecting runtimes…" : "Read-only inspection" }
        let source = "\(runningSourceCount) running source\(runningSourceCount == 1 ? "" : "s")"
        return "\(source) · No data is imported"
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
            .task {
                await inspect()
            }
            .onChange(of: runtimes) { _, _ in
                selectFirstRuntimeIfNeeded()
            }
            .onChange(of: selection) { _, newValue in
                if newValue != nil { showsInspector = true }
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
            .accessibilityLabel(isInspecting ? "Inspecting migration sources" : "Inspect migration sources")
            .help("Inspect local container runtimes and Docker CLI configuration")
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
        Section("Migration") {
            if let source = runtime.transferSourceToken {
                LabeledContent("Image Plan", value: imagePlanStatus(for: runtime))
                Button {
                    MorbPasteboard.copy("morb migrate images --from \(source) --dry-run")
                } label: {
                    Label("Copy Image Dry-Run Command", systemImage: "doc.on.doc")
                }
                .disabled(!runtime.running || !model.engine.isRunning)

                LabeledContent("Volume Plan", value: "CLI only")
                Text(
                    "The current volume dry run can create a temporary helper container to inspect the destination. "
                        + "Morbstack keeps that operation in the CLI until the migration service exposes a structured, side-effect-free plan.")
                    .foregroundStyle(.secondary)
            } else {
                Text(
                    "Morbstack is the migration destination. Select a running Docker Desktop, Colima, or OrbStack source to review its readiness.")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text(
                "This app route only inspects local runtimes and configuration. It does not start a runtime, write Docker configuration, or import images or volumes.")
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
        if !runtime.running { return "Start the source runtime" }
        if !model.engine.isRunning { return "Start Morbstack" }
        return "Copy CLI dry-run command"
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
    }

    private func selectFirstRuntimeIfNeeded() {
        if let selection, runtimes.contains(where: { $0.id == selection }) { return }
        selection = runtimes.first(where: { $0.running && $0.transferSourceToken != nil })?.id
            ?? runtimes.first(where: { $0.transferSourceToken != nil })?.id
            ?? runtimes.first?.id
    }
}
