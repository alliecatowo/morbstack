// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Settings › File Sharing — the shared folders, and Rosetta.
//
// Read-only, deliberately. Every other Settings pane edits `config.toml` behind a Save
// button; this one shows what the file says and offers to open it. Three reasons, in
// increasing order of how much they matter:
//
//   1. The list is an array of paths, and the config file's supported value grammar is
//      scalars — the writer cannot round-trip it yet without losing the user's comments.
//   2. Sharing a folder is a security decision. A folder added here is readable and
//      writable by every container the user ever runs, including one pulled from a
//      registry five minutes ago. A path field that takes effect on the next VM start is
//      a large gun to leave lying in a preferences window; sending people to the file
//      makes the decision deliberate.
//   3. It is the one pane whose whole job is diagnosis. What somebody needs here is
//      "which of these did the VM actually mount", and that answer has to be visibly
//      distinct from the wish list — which is exactly what an editable list of text
//      fields would blur.
//
// Both sections read live state from `AppModel` rather than from the settings store,
// because both are answers only the guest can give.

import AppKit
import MorbstackKit
import SwiftUI

struct TrackDSharingSettings: View {

    let model: AppModel
    let store: TrackDSettingsStore

    private var status: MorbShareSurface.Report { model.fileSharing }

    var body: some View {
        Form {
            if let chip = model.fileSharingChip {
                Section {
                    TrackDInlineNotice(
                        symbol: "exclamationmark.triangle.fill",
                        tone: .warn,
                        title: chip.text,
                        message: chip.detail
                    ) {
                        Button("Restart engine") { restartEngine() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(Theme.accent)
                    }
                }
            }

            Section {
                if status.shares.isEmpty {
                    Text("No folders are shared. Containers cannot bind-mount anything on this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(status.shares, id: \.path) { share in
                        TrackDShareRow(
                            share: share,
                            source: status.source,
                            engineRunning: model.engine.isRunning)
                    }
                }
            } header: {
                Text("Shared folders")
            } footer: {
                sharingExplanation
            }

            Section {
                rosettaRow
            } header: {
                Text("Rosetta")
            } footer: {
                rosettaExplanation
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        // Neither answer can change without a VM restart or a config edit, so this is a
        // refresh on open rather than anything resembling a poll.
        .task { await model.refreshFileSharing() }
    }

    // MARK: Explanations

    // The tier-1 semantics, in the fewest words that leave no wrong impression.
    //
    // Held as stored properties rather than written inline in the `VStack`. Not a style
    // preference: as one expression — several `Text`s, a markdown-bearing
    // `LocalizedStringKey`, a nested `HStack` and two modifiers — the type checker gives
    // up ("unable to type-check this expression in reasonable time"). Note also that
    // `samePathText` is a *single* literal: building a `LocalizedStringKey` out of `+`
    // concatenation reintroduces the same explosion on its own.

    private static let sharingScopeText =
        "These folders are visible inside the virtual machine, so containers can "
        + "bind-mount them. Everything else on this Mac is invisible to the VM."

    /// The sentence that has to survive editing.
    ///
    /// People arrive here with a Docker Desktop model in their head, where "file sharing"
    /// is a list of folders and the mapping is an implementation detail. Morbstack's
    /// mapping is the identity, and knowing that is the difference between `-v $(pwd):/app`
    /// being obviously fine and being something you have to test.
    private static let samePathText: LocalizedStringKey =
        "A shared folder appears in the VM at **exactly the same path** it has here — `/Users/you/project` is `/Users/you/project` inside the guest — so `-v /Users/you/project:/app` needs no translation and compose files stay portable. Sharing is over VirtioFS, live rather than copied: a change on either side is visible immediately on the other."

    private static let silentFailureText =
        "A bind mount whose host path is not under one of these folders does not fail. "
        + "Docker creates an empty directory in the guest and the container starts "
        + "normally, with none of your files in it — which is why this pane exists."

    private var sharingExplanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.sharingScopeText)
            Text(Self.samePathText)
            Text(Self.silentFailureText)
                .foregroundStyle(.orange)
            sharingActions
            Text(sharingEditHint)
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var sharingEditHint: String {
        "Edit `\(MorbShareSurface.sharedPathsKey)` in \(store.url.path), then restart the "
            + "engine: shares are attached when the VM boots."
    }

    private var sharingActions: some View {
        HStack(spacing: 12) {
            Button("Edit config.toml") {
                NSWorkspace.shared.activateFileViewerSelecting([store.url])
            }
            .buttonStyle(.link)
            Button("Reload") {
                Task { await model.refreshFileSharing() }
            }
            .buttonStyle(.link)
            Spacer()
        }
    }

    private var rosettaExplanation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                "Rosetta lets the VM run `amd64` (x86-64) container images on Apple silicon by "
                    + "translating their binaries. Images built for `arm64` do not need it and "
                    + "always run faster; Rosetta is for the ones that only ship amd64."
            )
            if model.rosetta.availability == .notInstalled {
                Text(
                    "Install it from a terminal with `morb rosetta install`, which explains what "
                        + "it will do and asks first. Morbstack never accepts Apple's licence for you."
                )
            }
            if model.rosetta.availability == .disabled {
                Text("Set `rosetta = true` in \(store.url.path) and restart the engine.")
            }
            if let note = model.rosetta.note, !note.isEmpty {
                Text(note).foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Rosetta row

    private var rosettaRow: some View {
        LabeledContent {
            HStack(spacing: 6) {
                TrackCStatusDot(tone: rosettaTone)
                Text(model.rosetta.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        } label: {
            Text("amd64 images")
        }
    }

    private var rosettaTone: TrackCTone {
        switch model.rosetta.availability {
        case .active: return .good
        case .ready: return .accent
        case .disabled: return .neutral
        case .notInstalled: return .warn
        case .unsupported: return .neutral
        }
    }

    // MARK: Actions

    private func restartEngine() {
        Task { @MainActor in
            await model.engineAction(.stop)
            await model.engineAction(.start)
            await model.refreshFileSharing()
        }
    }
}

// MARK: - One shared folder

/// A single row in the Shared folders list.
struct TrackDShareRow: View {

    let share: MorbShareState
    /// Whether the row's mount state came from the guest or was reconstructed from the
    /// config file. It decides whether "not mounted" is a fault or just the truth about
    /// a stopped VM.
    let source: MorbShareSurface.Source
    let engineRunning: Bool

    private var summary: (text: String, tone: TrackCTone) {
        TrackEShareStatus.rowSummary(share, source: source, engineRunning: engineRunning)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            TrackCStatusDot(tone: summary.tone)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(share.path)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if share.readOnly {
                        TrackCBadge(text: "read-only", symbol: "lock", tone: .neutral)
                    }
                }
                Text(summary.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // The guest path is shown only when it is not the host path. Under the
                // same-path design it never is, and a duplicated path on every row would
                // quietly teach the wrong mental model to everyone who reads it.
                if !share.isSamePath {
                    Text("in the VM: \(share.guestPath)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 8)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: share.path)])
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Reveal \(share.path) in Finder")
        }
        .padding(.vertical, 2)
    }
}
