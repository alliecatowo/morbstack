// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Settings is a native macOS preferences window over `~/.morbstack/config.toml`.
// The file remains the source of truth for `morb`, `morbstackd`, and people who edit
// it directly. This view only chooses appropriate system controls and commits the
// existing store's safe, preserving writes.

import AppKit
import MorbstackKit
import SwiftUI

// MARK: - Preferences

enum TrackDPreferences {
    static let showMenuBarIcon = "morb.showMenuBarIcon"
    static let selectedSettingsPane = "morb.selectedSettingsPane"
    /// Suppresses only automatic first-run CLI presentation. The Morbstack app menu
    /// always offers a deliberate way to return to the same review sheet.
    static let firstRunCLISetupDeferred = "morb.firstRunCLISetupDeferred"
}

// MARK: - Root

struct MorbSettingsView: View {

    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case general, resources, sharing, advanced

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .resources: return "Resources"
            case .sharing: return "File Sharing"
            case .advanced: return "Advanced"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .resources: return "cpu"
            case .sharing: return "folder.badge.gearshape"
            case .advanced: return "wrench.and.screwdriver"
            }
        }
    }

    let model: AppModel

    /// A caller can name a pane for an intentional deep link or fixture. Ordinary
    /// Settings opens restore the last pane, as macOS users expect.
    var initialTab: Tab = .general

    @AppStorage(TrackDPreferences.selectedSettingsPane) private var storedTabRawValue = Tab.general.rawValue
    @State private var store = TrackDSettingsStore()
    @State private var tab: Tab

    init(
        model: AppModel,
        initialTab: Tab = .general,
        // Kept as a source-compatible fixture argument. Native Settings must use the
        // system tab toolbar, so the old hand-drawn segmented strip is intentionally
        // ignored.
        drawsOwnTabStrip _: Bool = false
    ) {
        self.model = model
        self.initialTab = initialTab
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $tab) {
            pane(.general).tabItem { label(.general) }.tag(Tab.general)
            pane(.resources).tabItem { label(.resources) }.tag(Tab.resources)
            pane(.sharing).tabItem { label(.sharing) }.tag(Tab.sharing)
            pane(.advanced).tabItem { label(.advanced) }.tag(Tab.advanced)
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 440, idealHeight: 540)
        .navigationTitle(tab.title)
        .onAppear {
            guard initialTab == .general, let restoredTab = Tab(rawValue: storedTabRawValue) else {
                return
            }
            tab = restoredTab
        }
        .onChange(of: tab) { _, selectedTab in
            storedTabRawValue = selectedTab.rawValue
        }
        .onChange(of: model.engine.isRunning) { _, running in
            store.engineStateChanged(running: running)
        }
        .task {
            store.engineStateChanged(running: model.engine.isRunning)
        }
    }

    private func label(_ tab: Tab) -> some View {
        Label(tab.title, systemImage: tab.symbol)
    }

    @ViewBuilder
    private func pane(_ tab: Tab) -> some View {
        switch tab {
        case .general: TrackDGeneralSettings()
        case .resources: TrackDResourceSettings(model: model, store: store)
        case .sharing: TrackDSharingSettings(model: model, store: store)
        case .advanced: TrackDAdvancedSettings(store: store)
        }
    }
}

// MARK: - General

private struct TrackDGeneralSettings: View {

    @AppStorage(TrackDPreferences.showMenuBarIcon) private var showMenuBarIcon = true
    @State private var backgroundServiceStatus: MorbBackgroundService.Status?
    @State private var isBackgroundServiceEnabled = false
    @State private var isUpdatingBackgroundService = false
    @State private var backgroundServiceError: String?

    var body: some View {
        Form {
            Section("Menu Bar") {
                Toggle("Show Morbstack in the menu bar", isOn: $showMenuBarIcon)
                    .toggleStyle(.checkbox)
                Text(
                    "Shows engine status, running containers, and published ports. Turning it off doesn’t stop the engine."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            backgroundServiceSection
        }
        .formStyle(.grouped)
        .task {
            await refreshBackgroundServiceStatus()
        }
    }

    @ViewBuilder
    private var backgroundServiceSection: some View {
        if let backgroundServiceStatus {
            Section("Background Service") {
                if backgroundServiceStatus.registration == .unavailable {
                    LabeledContent("Status") {
                        Text("Available from an installed app")
                    }
                } else {
                    Toggle(
                        "Run Morbstack’s host service at login",
                        isOn: Binding(
                            get: { isBackgroundServiceEnabled },
                            set: { requested in
                                Task { await updateBackgroundService(enabled: requested) }
                            }))
                    .toggleStyle(.checkbox)
                    .disabled(isUpdatingBackgroundService)

                    Text(
                        "Registers a per-user service in Login Items. macOS may run it now and after sign-in; it doesn’t start Morbstack’s VM or containers."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                LabeledContent("Status") {
                    Text(backgroundServiceStatus.registration.settingsTitle)
                }
                Text(backgroundServiceStatus.diagnostic)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if backgroundServiceStatus.registration == .requiresApproval {
                    Button("Open Login Items…") {
                        MorbBackgroundService.openLoginItemsSettings()
                    }
                }

                if isUpdatingBackgroundService {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Updating Login Item…")
                    }
                    .accessibilityElement(children: .combine)
                }

                if let backgroundServiceError {
                    Label(backgroundServiceError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func refreshBackgroundServiceStatus() async {
        let status = await Task.detached(priority: .userInitiated) {
            MorbBackgroundService.status()
        }.value
        backgroundServiceStatus = status
        isBackgroundServiceEnabled = status.registration.isRegistered
    }

    private func updateBackgroundService(enabled: Bool) async {
        guard !isUpdatingBackgroundService else { return }
        isUpdatingBackgroundService = true
        backgroundServiceError = nil
        defer { isUpdatingBackgroundService = false }

        do {
            let status = try await Task.detached(priority: .userInitiated) {
                try (enabled ? MorbBackgroundService.enable() : MorbBackgroundService.disable())
            }.value
            backgroundServiceStatus = status
            isBackgroundServiceEnabled = status.registration.isRegistered
        } catch {
            backgroundServiceError = (error as? MorbError)?.description ?? error.localizedDescription
            await refreshBackgroundServiceStatus()
        }
    }
}

private extension MorbBackgroundService.Registration {

    var isRegistered: Bool {
        self == .enabled || self == .requiresApproval
    }

    var settingsTitle: String {
        switch self {
        case .unavailable: return "Unavailable"
        case .notRegistered, .notFound: return "Off"
        case .enabled: return "On"
        case .requiresApproval: return "Needs Approval"
        case .unknown: return "Unknown"
        }
    }
}

// MARK: - Resources

private struct TrackDResourceSettings: View {

    let model: AppModel
    let store: TrackDSettingsStore
    @State private var diskCapacity: MorbDiskCapacity.Status?

    var body: some View {
        Form {
            if let error = store.loadError {
                configurationMessage(
                    title: "Couldn’t read config.toml",
                    message: error,
                    symbol: "exclamationmark.triangle"
                )
            }

            if let error = store.saveError {
                configurationMessage(
                    title: "Couldn’t save config.toml",
                    message: error,
                    symbol: "exclamationmark.triangle"
                )
            }

            if store.needsEngineRestart && model.engine.isRunning {
                Section("Apply Changes") {
                    Label("Restart Morbstack to apply resource changes", systemImage: "arrow.clockwise")
                    Text(store.restartSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Restart Engine", systemImage: "arrow.clockwise") { restartEngine() }
                }
            }

            Section("Virtual Machine") {
                cpuSetting
                memorySetting
                suspendSetting
            }

            Section("Storage") {
                if let diskCapacity {
                    LabeledContent("New disk capacity") {
                        Text("\(diskCapacity.configuredGiB) GiB")
                            .monospacedDigit()
                    }
                    if let currentBytes = diskCapacity.currentBytes {
                        LabeledContent("Current capacity") {
                            Text(Formatters.bytesString(currentBytes))
                                .monospacedDigit()
                        }
                    }
                    Text(diskCapacity.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let inspectionError = diskCapacity.inspectionError {
                        Text(inspectionError)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } else {
                    LabeledContent("New disk capacity") {
                        Text("\(store.draft.diskSizeGiB) GiB")
                            .monospacedDigit()
                    }
                    Text("Checking the existing disk image…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: store.draft.diskSizeGiB) {
            diskCapacity = MorbDiskCapacity.inspect(configuredGiB: store.draft.diskSizeGiB)
        }
    }

    @ViewBuilder
    private func configurationMessage(title: String, message: String, symbol: String) -> some View {
        Section("Configuration") {
            Label(title, systemImage: symbol)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var cpuSetting: some View {
        VStack(alignment: .leading) {
            LabeledContent("Virtual CPUs") {
                Text(cpuValueText)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { TrackDConfigEditor.cpuSliderValue(store.draft, limits: store.limits) },
                    set: { TrackDConfigEditor.applyCPU($0, to: &store.draft, limits: store.limits) }
                ),
                in: 1...Double(max(1, store.limits.hostCores)),
                step: 1
            ) {
                Text("Virtual CPUs")
            } minimumValueLabel: {
                Text("1")
            } maximumValueLabel: {
                Text("\(store.limits.hostCores)")
            } onEditingChanged: { editing in
                if !editing { store.save() }
            }
            .labelsHidden()
            .accessibilityLabel("Virtual CPUs")
            .accessibilityValue(cpuValueText)

            Text("This Mac has \(store.limits.hostCores) cores.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if !TrackDConfigEditor.isTrackingHostCores(store.draft) {
                Button("Use All Cores") {
                    TrackDConfigEditor.matchHostCores(&store.draft)
                    store.save()
                }
                .help("Writes cpus = 0 so the VM tracks this Mac’s available cores")
            }
        }
    }

    private var cpuValueText: String {
        if TrackDConfigEditor.isTrackingHostCores(store.draft) {
            return "All cores (\(store.limits.hostCores))"
        }
        return "\(store.draft.cpus)"
    }

    private var memorySetting: some View {
        VStack(alignment: .leading) {
            LabeledContent("Memory") {
                Text("\(store.draft.memoryMiB / 1024) GiB")
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { TrackDConfigEditor.memorySliderGiB(store.draft, limits: store.limits) },
                    set: { TrackDConfigEditor.applyMemoryGiB($0, to: &store.draft, limits: store.limits) }
                ),
                in: Double(TrackDConfigEditor.minimumMemoryGiB)...Double(max(1, store.limits.hostMemoryGiB)),
                step: 1
            ) {
                Text("Memory")
            } minimumValueLabel: {
                Text("1 GiB")
            } maximumValueLabel: {
                Text("\(store.limits.hostMemoryGiB) GiB")
            } onEditingChanged: { editing in
                if !editing { store.save() }
            }
            .labelsHidden()
            .accessibilityLabel("Memory")
            .accessibilityValue("\(store.draft.memoryMiB / 1024) GiB")

            Text(
                "A limit, not an allocation. The VM grows only as the guest needs memory, up to this value."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var suspendSetting: some View {
        VStack(alignment: .leading) {
            Stepper(
                "Stop when idle: \(TrackDConfigEditor.describeSuspend(store.draft))",
                value: Binding(
                    get: { store.draft.autoSuspendMinutes },
                    set: {
                        TrackDConfigEditor.applyAutoSuspend($0, to: &store.draft)
                        store.save()
                    }
                ),
                in: TrackDConfigEditor.autoSuspendRange,
                step: 5
            )
            Text(
                "Morbstack stops the engine after this much Docker inactivity. The next Docker command starts it from persisted Docker data; don’t rely on running containers surviving. Set the value to zero to keep it running."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func restartEngine() {
        Task { @MainActor in
            await model.engineAction(.stop)
            await model.engineAction(.start)
        }
    }
}

// MARK: - Advanced

private struct TrackDAdvancedSettings: View {

    let store: TrackDSettingsStore
    /// This snapshot reads existing CLI integration state only. It is deliberately
    /// separate from first-run setup: Settings explains what is present, while the
    /// reviewed setup sheet owns every file-system change.
    @State private var commandLineTools = TrackDCommandLineToolsStatus.inspect()

    private var homeIsOverridden: Bool {
        !(ProcessInfo.processInfo.environment["MORBSTACK_HOME"] ?? "").isEmpty
    }

    var body: some View {
        Form {
            Section("Locations") {
                pathValue("MORBSTACK_HOME", path: MorbPaths.root.path)
                if homeIsOverridden {
                    Label(
                        "MORBSTACK_HOME is overridden for this process.",
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                pathValue("Configuration", path: store.url.path)
                Button("Reveal Configuration in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.url])
                }
                Button("Reload Configuration", systemImage: "arrow.clockwise") {
                    store.reload()
                }
            }

            Section("Sockets") {
                pathValue("Docker Engine API", path: MorbPaths.dockerSocket.path)
                pathValue("Daemon control", path: MorbPaths.controlSocket.path)
                LabeledContent("Docker CLI") {
                    Button("Copy Context Command", systemImage: "doc.on.doc") {
                        MorbPasteboard.copy(TrackDLinks.dockerContextCommand(socketPath: MorbPaths.dockerSocket.path))
                    }
                }
            }

            commandLineToolsSection

            Section("Diagnostics") {
                LabeledContent("Logs") {
                    Button("Open Folder", systemImage: "folder") {
                        NSWorkspace.shared.open(MorbPaths.logsDirectory)
                    }
                }
                pathValue("Daemon log", path: MorbPaths.daemonLog.path)
                pathValue("Guest console", path: MorbPaths.consoleLog.path)
            }

            Section("Version") {
                LabeledContent("Morbstack") {
                    Text(MorbVersion.string)
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var commandLineToolsSection: some View {
        Section("Command-Line Tools") {
            LabeledContent("Morbstack context") {
                Text(commandLineTools.contextSummary)
            }
            LabeledContent("Saved selection") {
                commandLineValue(commandLineTools.context.currentContext)
            }
            LabeledContent("Context endpoint") {
                commandLineValue(commandLineTools.context.registeredHost ?? "Not registered")
            }
            Text(commandLineTools.contextGuidance)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Discovery socket") {
                commandLineValue(commandLineTools.directSocket.path)
            }
            LabeledContent("Discovery status") {
                Text(commandLineTools.directSocketSummary)
            }
            Text(commandLineTools.directSocketGuidance)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Bundled toolchain") {
                Text(commandLineTools.toolchainSummary)
            }
            Text(commandLineTools.toolchainGuidance)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Shell overrides") {
                commandLineValue(commandLineTools.environmentSummary)
            }
            Text(commandLineTools.environmentGuidance)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Refresh", systemImage: "arrow.clockwise") {
                commandLineTools = .inspect()
            }
            .help("Re-read Docker context and bundled command-line tool status")
        } footer: {
            Text(
                "Settings only reads this status. Choose Morbstack > Set Up Command-Line Tools… "
                    + "to review any context, socket, or CLI-link changes before applying them."
            )
        }
    }

    private func commandLineValue(_ value: String) -> some View {
        Text(value)
            .font(.system(.body, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }

    @ViewBuilder
    private func pathValue(_ label: String, path: String) -> some View {
        LabeledContent(label) {
            HStack {
                Text(path)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button("Copy \(label)", systemImage: "doc.on.doc") {
                    MorbPasteboard.copy(path)
                }
                .labelStyle(.iconOnly)
                .help("Copy \(label.lowercased())")
            }
        }
    }
}

/// A read-only snapshot of the standard Docker integration locations.  All three
/// source APIs inspect the current process and file system; no command is spawned and
/// none of the mutating installer/context APIs is reachable from this type.
private struct TrackDCommandLineToolsStatus {
    let context: MorbDockerContext.Status
    let installationPlan: MorbCliInstallation.Plan
    let pluginPlan: MorbCliPlugins.Plan

    static func inspect() -> Self {
        Self(
            context: MorbDockerContext.status(),
            installationPlan: MorbCliInstallation.plan(),
            pluginPlan: MorbCliPlugins.plan())
    }

    var directSocket: MorbDockerContext.DirectSocketStatus {
        installationPlan.directSocket
    }

    var contextSummary: String {
        guard context.registered else { return "Not registered" }
        guard context.matchesSocket else { return "Needs repair" }
        return context.isCurrent ? "Current" : "Registered"
    }

    var contextGuidance: String {
        if !context.registered {
            return "No morbstack Docker context is registered. Re-enter command-line setup to review creating it."
        }
        if !context.matchesSocket {
            let endpoint = context.registeredHost ?? "an unrecognized endpoint"
            return "The existing morbstack context points at \(endpoint). Morbstack leaves it unchanged; repair or rename that context, then review setup again."
        }
        if !context.isCurrent {
            return "The morbstack context is registered, but Docker’s saved selection is \(context.currentContext). Setup preserves a non-default selection."
        }
        return "The saved morbstack context points at this installation’s Docker Engine API socket."
    }

    var directSocketSummary: String {
        switch directSocket.state {
        case .correct: return "Linked to Morbstack"
        case .missing: return "Not linked"
        case .pointsElsewhere: return "Points elsewhere"
        case .occupied: return "Occupied"
        case .unavailable: return "Unavailable"
        }
    }

    var directSocketGuidance: String {
        switch directSocket.state {
        case .correct:
            return "The standard per-user Docker discovery path resolves to this installation’s Docker socket."
        case .missing:
            return "The standard per-user discovery link is absent. Re-enter command-line setup to review creating only that user-owned link."
        case .pointsElsewhere(let destination):
            return "This path points at \(destination). Morbstack preserves that existing link; choose its owner deliberately before changing it."
        case .occupied(let kind):
            return "A \(kind) already occupies this path. Morbstack will not replace it automatically."
        case .unavailable(let reason):
            return "The discovery path could not be used safely: \(reason)"
        }
    }

    var toolchainSummary: String {
        guard installationPlan.hasCompleteToolchain else { return "Incomplete" }
        let managedItems = [installationPlan.docker] + installationPlan.plugins
        return managedItems.allSatisfy(\.alreadyCorrect) && pluginPlan.items.allSatisfy(\.alreadyCorrect)
            ? "Available and linked"
            : "Available"
    }

    var toolchainGuidance: String {
        guard installationPlan.hasCompleteToolchain else {
            let missing = [installationPlan.docker] + installationPlan.plugins
            let names = missing.filter { $0.source == nil }.map(\.name).joined(separator: ", ")
            return "This Morbstack installation is missing \(names). Reinstall or repair the app bundle, then refresh this status."
        }
        let managedItems = [installationPlan.docker] + installationPlan.plugins
        if managedItems.allSatisfy(\.alreadyCorrect) {
            return "The bundled docker client, Compose plugin, and Buildx plugin are linked where Docker will discover them."
        }
        let unresolvedPlugins = pluginPlan.items
            .filter { !$0.alreadyCorrect }
            .map { "docker-\($0.plugin)" }
            .joined(separator: ", ")
        if unresolvedPlugins.isEmpty {
            return "The bundled docker client is available. Re-enter command-line setup to review its missing or user-owned link."
        }
        return "The bundled docker client, Compose plugin, and Buildx plugin are available. Re-enter command-line setup to review \(unresolvedPlugins)."
    }

    var environmentSummary: String {
        var entries: [String] = []
        if let environmentContext = context.environmentContext {
            entries.append("DOCKER_CONTEXT=\(environmentContext)")
        }
        if context.hasDockerHostOverride {
            entries.append("DOCKER_HOST is set")
        }
        return entries.isEmpty ? "None" : entries.joined(separator: ", ")
    }

    var environmentGuidance: String {
        if let environmentContext = context.environmentContext {
            return "DOCKER_CONTEXT selects \(environmentContext) for commands launched with this environment. Docker gives it precedence over DOCKER_HOST and the saved context."
        }
        if context.hasDockerHostOverride {
            return "DOCKER_HOST overrides the saved Docker context for commands launched with this environment. Clear it in the shell that set it to use the saved selection."
        }
        return "A shell that sets DOCKER_CONTEXT or DOCKER_HOST can target a different endpoint than the saved Docker context."
    }
}
