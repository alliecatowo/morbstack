// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Settings › File Sharing presents the configuration and the guest's observed mount
// state. It is intentionally read-only: the writer cannot safely round-trip the shared
// paths array yet, and sharing a host folder is a security decision. The config file is
// therefore the deliberate editing surface.

import AppKit
import MorbstackKit
import SwiftUI

struct TrackDSharingSettings: View {

    let model: AppModel
    let store: TrackDSettingsStore

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
