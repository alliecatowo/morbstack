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
        }
        .formStyle(.grouped)
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
