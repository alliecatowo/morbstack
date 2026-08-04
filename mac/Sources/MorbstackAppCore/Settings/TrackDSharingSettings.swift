// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Settings › File Sharing presents the configuration and the guest's observed mount
// state. Broad VirtioFS roots remain configuration-file-only because exposing a folder
// is a security decision. The narrower live-reload roots are selected through the
// system directory panel and persisted with the same conflict-preserving writer.

import AppKit
import MorbstackKit
import SwiftUI

struct TrackDSharingSettings: View {

    let model: AppModel
    let store: TrackDSettingsStore
    @State private var liveReloadError: String?

    private var status: MorbShareSurface.Report { model.fileSharing }

    var body: some View {
        Form {
            if let warning = model.fileSharingChip {
                Section("Sharing Status") {
                    Label(warning.text, systemImage: warning.symbol)
                    Text(warning.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Restart Engine", systemImage: "arrow.clockwise") {
                        restartEngine()
                    }
                }
            }

            Section {
                if status.shares.isEmpty {
                    Label("No Shared Folders", systemImage: "folder.badge.plus")
                    Text("Add only folders you want every container to be able to access.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    LabeledContent("Configuration") {
                        Button("Open config.toml", systemImage: "doc.text") {
                            openConfiguration()
                        }
                    }
                } else {
                    ForEach(status.shares, id: \.path) { share in
                        TrackDShareRow(
                            share: share,
                            source: status.source,
                            engineRunning: model.engine.isRunning)
                    }

                    LabeledContent("Configuration") {
                        Button("Open config.toml", systemImage: "doc.text") {
                            openConfiguration()
                        }
                    }
                    Button("Reload Sharing Status", systemImage: "arrow.clockwise") {
                        Task { await model.refreshFileSharing() }
                    }
                }
            } header: {
                Text("Shared Folders")
            } footer: {
                Text(
                    "Shared folders appear in the virtual machine at the same path as on your Mac. Edit shared_paths in config.toml, then restart the engine to apply changes."
                )
            }

            Section {
                if store.draft.liveSharePaths.isEmpty {
                    LabeledContent("Project Folders") {
                        Text("Off")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(store.draft.liveSharePaths, id: \.self) { path in
                        LabeledContent {
                            Button("Remove", systemImage: "minus.circle") {
                                removeLiveReloadPath(path)
                            }
                            .accessibilityLabel("Remove \(path) from live reload")
                        } label: {
                            Text(path)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                }

                Button("Add Project Folder…", systemImage: "plus") {
                    chooseLiveReloadFolder()
                }

                if let liveReloadError {
                    Label(liveReloadError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if store.needsEngineRestart, model.engine.isRunning {
                    Button("Restart Engine", systemImage: "arrow.clockwise") {
                        restartEngine()
                    }
                }
            } header: {
                Text("Live Reload")
            } footer: {
                Text(
                    "Choose only project folders beneath a shared folder. Changes apply after an engine restart. Morbstack emits metadata invalidations (IN_ATTRIB), not synthetic writes, renames, or deletes; run morb shares to confirm delivery after restarting."
                )
            }

            Section {
                LabeledContent("amd64 container images") {
                    Label(model.rosetta.summary, systemImage: rosettaSymbol)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Rosetta")
            } footer: {
                rosettaExplanation
            }
        }
        .formStyle(.automatic)
        // The guest's mount state changes only after a restart or a configuration edit.
        // Refreshing on open is enough; the pane deliberately does not poll.
        .task { await model.refreshFileSharing() }
    }

    @ViewBuilder
    private var rosettaExplanation: some View {
        Text(
            "Rosetta lets the VM run amd64 (x86-64) images on Apple silicon. Native arm64 images don’t need it."
        )
        if model.rosetta.availability == .notInstalled {
            Text("Install it from Terminal with morb rosetta install. Morbstack never accepts Apple’s license for you.")
        }
        if model.rosetta.availability == .disabled {
            Text("Set rosetta = true in config.toml and restart the engine.")
        }
        if let note = model.rosetta.note, !note.isEmpty {
            Text(note)
        }
    }

    private var rosettaSymbol: String {
        switch model.rosetta.availability {
        case .active, .ready:
            return "checkmark.circle"
        case .disabled:
            return "xmark.circle"
        case .notInstalled:
            return "arrow.down.circle"
        case .unsupported:
            return "minus.circle"
        }
    }

    private func openConfiguration() {
        NSWorkspace.shared.open(store.url)
    }

    private func restartEngine() {
        Task { @MainActor in
            await model.engineAction(.stop)
            await model.engineAction(.start)
            await model.refreshFileSharing()
        }
    }

    private func chooseLiveReloadFolder() {
        let panel = NSOpenPanel()
        panel.message = "Choose a project folder for live reload"
        panel.prompt = "Add Project Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        updateLiveReloadPaths(store.draft.liveSharePaths + [url.path])
    }

    private func removeLiveReloadPath(_ path: String) {
        updateLiveReloadPaths(store.draft.liveSharePaths.filter { $0 != path })
    }

    private func updateLiveReloadPaths(_ paths: [String]) {
        var candidate = store.draft
        candidate.liveSharePaths = paths
        do {
            let shares = try candidate.sharePlan().shares
            _ = try MorbLiveShareBridge.plan(paths: candidate.liveSharePaths, shares: shares)
        } catch {
            liveReloadError = (error as? MorbError)?.description ?? error.localizedDescription
            return
        }
        store.draft = candidate
        guard store.save() else {
            liveReloadError = store.saveError ?? "Couldn’t save live reload settings."
            return
        }
        liveReloadError = nil
    }
}

// MARK: - Shared folder

/// A native form row for one configured host folder. The row's status remains textual
/// so the state isn't conveyed by color or a custom badge.
private struct TrackDShareRow: View {

    let share: MorbShareState
    let source: MorbShareSurface.Source
    let engineRunning: Bool

    private var summary: String {
        TrackEShareStatus.rowSummary(share, source: source, engineRunning: engineRunning)
    }

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing) {
                Text(summary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                if share.readOnly {
                    Label("Read-only", systemImage: "lock")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !share.isSamePath {
                    Text("VM path: \(share.guestPath)")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button("Reveal in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: share.path)])
                }
            }
        } label: {
            Text(share.path)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
