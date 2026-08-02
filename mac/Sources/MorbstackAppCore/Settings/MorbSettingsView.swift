// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Settings.
//
// Three tabs, and a rule: this window edits `~/.morbstack/config.toml` and nothing
// else. The file is the source of truth for `morb`, for `morbstackd` and for anyone who
// prefers a text editor, so Settings is a view onto it rather than a parallel store —
// which is why there is a Save button instead of live-applying writes, and why the
// Advanced tab shows the path.

import AppKit
import MorbstackKit
import SwiftUI

// MARK: - Preferences

/// `UserDefaults` keys shared with the rest of the app.
///
/// Track A reads ``showMenuBarIcon`` to decide whether to insert the `MenuBarExtra`:
///
///     @AppStorage(TrackDPreferences.showMenuBarIcon) private var showMenuBarIcon = true
///     MenuBarExtra(isInserted: $showMenuBarIcon) { … }
enum TrackDPreferences {
    static let showMenuBarIcon = "morb.showMenuBarIcon"
    static let launchAtLogin = "morb.launchAtLogin"
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

    /// Which pane opens first. The app always opens on General; the screenshot harness
    /// names one so it can photograph the others.
    var initialTab: Tab = .general

    /// Draw the tab strip in SwiftUI instead of letting `TabView` draw it.
    ///
    /// `TabView`'s macOS tab strip is an AppKit control on a vibrant backing, and a
    /// vibrant control rasterised into an offscreen bitmap comes out as a blank white
    /// slab — no icons, no labels, glaringly wrong in dark mode. This substitutes the
    /// equivalent segmented control, which is plain SwiftUI and draws correctly.
    /// Only the screenshot harness sets it.
    var drawsOwnTabStrip: Bool = false

    @State private var store = TrackDSettingsStore()
    @State private var tab: Tab

    init(
        model: AppModel,
        initialTab: Tab = .general,
        drawsOwnTabStrip: Bool = false
    ) {
        self.model = model
        self.initialTab = initialTab
        self.drawsOwnTabStrip = drawsOwnTabStrip
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        Group {
            if drawsOwnTabStrip {
                substitutedChrome
            } else {
                TabView(selection: $tab) {
                    pane(.general).tabItem { label(.general) }.tag(Tab.general)
                    pane(.resources).tabItem { label(.resources) }.tag(Tab.resources)
                    pane(.sharing).tabItem { label(.sharing) }.tag(Tab.sharing)
                    pane(.advanced).tabItem { label(.advanced) }.tag(Tab.advanced)
                }
            }
        }
        .frame(width: 560, height: 440)
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

    private var substitutedChrome: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { item in
                    Label(item.title, systemImage: item.symbol).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, Theme.space4)
            .padding(.bottom, Theme.space3)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            pane(tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - General

private struct TrackDGeneralSettings: View {

    @AppStorage(TrackDPreferences.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(TrackDPreferences.launchAtLogin) private var launchAtLogin = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch Morbstack at login", isOn: $launchAtLogin)
                Text(
                    "Not active yet. The login item is registered with `SMAppService.mainApp` "
                        + "once Morbstack ships as a signed bundle; this switch records the "
                        + "preference so it takes effect the moment it does."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Startup")
            }

            Section {
                Toggle("Show Morbstack in the menu bar", isOn: $showMenuBarIcon)
                Text(
                    "The menu bar item shows engine state, the containers that are running "
                        + "and their published ports. Turning it off does not stop the engine."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Menu bar")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // TODO(SMAppService): once the app is packaged and signed, wire the toggle to
    //
    //     import ServiceManagement
    //     let service = SMAppService.mainApp
    //     launchAtLogin ? try service.register() : try service.unregister()
    //
    // reading `service.status` on appear so the switch reflects reality rather than the
    // last thing this app believed. Registering an unsigned development build throws
    // `kSMErrorInvalidSignature`, which is why this is not live today.
}

// MARK: - Resources

private struct TrackDResourceSettings: View {

    let model: AppModel
    let store: TrackDSettingsStore

    var body: some View {
        Form {
            if let error = store.loadError {
                Section {
                    TrackDInlineNotice(
                        symbol: "exclamationmark.triangle.fill",
                        tone: .warn,
                        title: "config.toml could not be read",
                        message: error)
                }
            }

            if let error = store.saveError {
                Section {
                    TrackDInlineNotice(
                        symbol: "exclamationmark.triangle.fill",
                        tone: .bad,
                        title: "Could not save",
                        message: error)
                }
            }

            if store.needsEngineRestart && model.engine.isRunning {
                Section {
                    TrackDInlineNotice(
                        symbol: "arrow.clockwise.circle.fill",
                        tone: .accent,
                        title: "Restart the engine to apply",
                        message: store.restartSummary
                    ) {
                        Button("Restart engine") { restartEngine() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(Theme.accent)
                    }
                }
            }

            Section {
                cpuRow
            } header: {
                Text("Processors")
            }

            Section {
                memoryRow
            } header: {
                Text("Memory")
            }

            Section {
                suspendRow
            } header: {
                Text("Idle behaviour")
            }

            Section {
                LabeledContent("Root disk") {
                    Text("\(store.draft.diskSizeGiB) GiB")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text(
                    "Applied when the sparse disk image is first created. Changing it later "
                        + "has no effect on an existing image, so it is not editable here."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Storage")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: Rows

    private var cpuRow: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            HStack {
                Text("Virtual CPUs")
                Spacer()
                Text(cpuValueText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            // macOS settings apply on change — no Save button, so the write happens
            // when the drag ends (`onEditingChanged`) rather than on every tick, which
            // would otherwise spam the config file dozens of times per drag.
            Slider(
                value: Binding(
                    get: { TrackDConfigEditor.cpuSliderValue(store.draft, limits: store.limits) },
                    set: { TrackDConfigEditor.applyCPU($0, to: &store.draft, limits: store.limits) }
                ),
                in: 1...Double(max(1, store.limits.hostCores)),
                step: 1
            ) {
                EmptyView()
            } minimumValueLabel: {
                Text("1").font(.caption2).foregroundStyle(.tertiary)
            } maximumValueLabel: {
                Text("\(store.limits.hostCores)").font(.caption2).foregroundStyle(.tertiary)
            } onEditingChanged: { editing in
                if !editing { store.save() }
            }

            HStack(spacing: Theme.space2) {
                Text("This Mac has \(store.limits.hostCores) cores.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !TrackDConfigEditor.isTrackingHostCores(store.draft) {
                    Button("Match host") {
                        TrackDConfigEditor.matchHostCores(&store.draft)
                        store.save()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Write cpus = 0, which means “every core, whatever this Mac has”")
                }
            }
        }
        .padding(.vertical, Theme.space1)
    }

    private var cpuValueText: String {
        if TrackDConfigEditor.isTrackingHostCores(store.draft) {
            return "All cores (\(store.limits.hostCores))"
        }
        return "\(store.draft.cpus)"
    }

    private var memoryRow: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            HStack {
                Text("Memory")
                Spacer()
                Text("\(store.draft.memoryMiB / 1024) GiB")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Slider(
                value: Binding(
                    get: { TrackDConfigEditor.memorySliderGiB(store.draft, limits: store.limits) },
                    set: { TrackDConfigEditor.applyMemoryGiB($0, to: &store.draft, limits: store.limits) }
                ),
                in: Double(TrackDConfigEditor.minimumMemoryGiB)...Double(max(1, store.limits.hostMemoryGiB)),
                step: 1
            ) {
                EmptyView()
            } minimumValueLabel: {
                Text("1").font(.caption2).foregroundStyle(.tertiary)
            } maximumValueLabel: {
                Text("\(store.limits.hostMemoryGiB)").font(.caption2).foregroundStyle(.tertiary)
            } onEditingChanged: { editing in
                if !editing { store.save() }
            }
            Text(
                "A cap, not an allocation. The VM only takes the memory the guest actually "
                    + "touches — this is the ceiling it may grow to, out of \(store.limits.hostMemoryGiB) GiB on this Mac."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Theme.space1)
    }

    private var suspendRow: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            Stepper(
                value: Binding(
                    get: { store.draft.autoSuspendMinutes },
                    set: {
                        TrackDConfigEditor.applyAutoSuspend($0, to: &store.draft)
                        // A stepper's steps are discrete clicks, not a continuous drag,
                        // so each one is its own committed change — unlike the sliders
                        // above, there is no "still editing" moment to wait out.
                        store.save()
                    }
                ),
                in: TrackDConfigEditor.autoSuspendRange,
                step: 5
            ) {
                HStack {
                    Text("Suspend when idle")
                    Spacer()
                    Text(TrackDConfigEditor.describeSuspend(store.draft))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            Text(
                "Morbstack saves the VM to disk after this long with no Docker activity, and "
                    + "restores it on the next command. Set it to zero to keep the VM resident."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Theme.space1)
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
            Section {
                TrackDPathRow(label: "MORBSTACK_HOME", path: MorbPaths.root.path)
                if homeIsOverridden {
                    Label(
                        "Overridden by the MORBSTACK_HOME environment variable in this process.",
                        systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TrackDPathRow(label: "Configuration", path: store.url.path, symbol: "doc.text")
            } header: {
                Text("Locations")
            } footer: {
                HStack(spacing: Theme.space4) {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.url])
                    }
                    .buttonStyle(.link)
                    Button("Reload from disk") { store.reload() }
                        .buttonStyle(.link)
                    Spacer()
                }
                .font(.caption)
            }

            Section {
                TrackDPathRow(label: "Docker Engine API", path: MorbPaths.dockerSocket.path, symbol: "network")
                TrackDPathRow(label: "Daemon control", path: MorbPaths.controlSocket.path, symbol: "gearshape.2")
                LabeledContent("Docker CLI") {
                    Button {
                        trackDCopy(TrackDLinks.dockerContextCommand(socketPath: MorbPaths.dockerSocket.path))
                    } label: {
                        Label("Copy context command", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            } header: {
                Text("Sockets")
            }

            Section {
                LabeledContent("Logs") {
                    Button {
                        NSWorkspace.shared.open(MorbPaths.logsDirectory)
                    } label: {
                        Label("Open folder", systemImage: "folder")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                TrackDPathRow(label: "Daemon log", path: MorbPaths.daemonLog.path, symbol: "doc.text.magnifyingglass")
                TrackDPathRow(label: "Guest console", path: MorbPaths.consoleLog.path, symbol: "terminal")
            } header: {
                Text("Diagnostics")
            }

            Section {
                LabeledContent("Morbstack") {
                    Text(MorbVersion.string)
                        .monospacedDigit()
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Version")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Notice

/// The banner used for the restart prompt and for config-file errors.
struct TrackDInlineNotice<Accessory: View>: View {

    let symbol: String
    let tone: TrackDTone
    let title: String
    let message: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: Theme.space3) {
            Image(systemName: symbol)
                .font(.callout)
                .foregroundStyle(tone.color)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: Theme.space1) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.space3)
            accessory
        }
        .padding(.vertical, Theme.space2)
    }
}

extension TrackDInlineNotice where Accessory == EmptyView {
    init(symbol: String, tone: TrackDTone, title: String, message: String) {
        self.init(symbol: symbol, tone: tone, title: title, message: message, accessory: { EmptyView() })
    }
}
