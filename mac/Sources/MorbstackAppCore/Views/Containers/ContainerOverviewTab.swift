// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// OVERVIEW: everything about a container that is not a number changing over time.
//
// State and Configuration are one `Form(.formStyle(.grouped))` of `MorbKeyValue` rows —
// the system's own key/value idiom, which gets the label column and the baseline right
// for free. Ports, Mounts and Labels are real `Table`s. The environment table is the one
// part with a real policy behind it: values are hidden by default and revealed one at a
// time, because an environment block is where database passwords, API tokens and
// signing keys live, and this pane is the single most screenshotted view in an app like
// this. Redaction is not paternalism here; it is the difference between a bug report and
// an incident. There is exactly one reveal mechanism — the per-row eye button — not the
// per-row-eye-plus-global-toggle the previous build shipped.

import AppKit
import MorbstackKit
import SwiftUI

struct ContainerOverviewTab: View {

    let container: ContainerSummary
    let details: TrackBInspectDetails?
    let isLoading: Bool
    let errorText: String?

    /// What the app knows about shared folders, so a bind mount pointing at a folder
    /// the VM cannot see can be called out rather than rendered as a working mount.
    var fileSharing: MorbShareSurface.Report = .empty

    @State private var envQuery = ""
    @State private var revealed: Set<Int> = []
    @State private var mountSelection: Set<TrackBMountDisplay.ID> = []

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Theme.space6) {
                if let details {
                    configurationForm(details)
                    if !container.ports.isEmpty { portsSection }
                    environment(details)
                    if !details.mounts.isEmpty { mounts(details) }
                    if !details.labels.isEmpty { labels(details) }
                } else if isLoading {
                    loadingPlaceholder
                } else if let errorText {
                    TrackBInlineError(text: errorText)
                        .padding(.horizontal, Theme.pagePadding)
                }
            }
            .padding(.vertical, Theme.space5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .morbScrollEdge(.soft, for: .top)
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: State + Configuration
    //
    // `Form(.formStyle(.grouped))`, per `docs/design/COMPONENTS.md` §6 — `LabeledContent`
    // only shares a label column across sibling rows when it is inside a real `Form` or
    // `List`; built by hand inside a plain `MorbCard` each row sizes its own label to its
    // own text, and "Restart policy" no longer lines up under "Image".
    //
    // `Form` is a scroll view of its own, though, so nested inside this tab's outer
    // `ScrollView` it needs a bounded height — the first version of this file guessed one
    // from the row count and silently clipped the last row whenever a container's
    // Configuration section was one row taller than the guess. `.fixedSize(vertical:)`
    // asks the form for its own ideal height instead of proposing one, which is the
    // correct fix rather than a better guess.

    private func configurationForm(_ details: TrackBInspectDetails) -> some View {
        Form {
            Section("State") {
                MorbKeyValue("Status") {
                    MorbStatusBadge(
                        tone: StatusTone.forContainer(state: container.state, unhealthy: details.health == "unhealthy" || container.isUnhealthy),
                        title: details.health.map { "\(container.state) · \($0)" },
                        filled: false)
                }
                if let created = details.created {
                    MorbKeyValue("Created", Formatters.relativeDate(created))
                }
                if let startedAt = details.startedAt, startedAt.timeIntervalSince1970 > 0 {
                    MorbKeyValue("Started", Formatters.relativeDate(startedAt))
                }
                if let finishedAt = details.finishedAt, finishedAt.timeIntervalSince1970 > 0,
                   container.state != "running", container.state != "restarting" {
                    let code = details.exitCode.map { " (exit \($0))" } ?? ""
                    MorbKeyValue("Exited", Formatters.relativeDate(finishedAt) + code)
                }
                if details.restartCount > 0 {
                    MorbKeyValue("Restarts", "\(details.restartCount)")
                }
            }

            Section("Configuration") {
                MorbKeyValue("Image", monospaced: true) { truncating(container.image) }
                if !details.imageID.isEmpty {
                    MorbKeyValue("Image ID", monospaced: true) { truncating(details.imageID) }
                }
                MorbKeyValue("Command", monospaced: true) {
                    truncating(details.command.isEmpty ? "—" : details.command)
                }
                if let entrypoint = details.entrypoint {
                    MorbKeyValue("Entrypoint", monospaced: true) { truncating(entrypoint) }
                }
                if let workingDir = details.workingDir {
                    MorbKeyValue("Working dir", monospaced: true) { truncating(workingDir) }
                }
                if let user = details.user {
                    MorbKeyValue("User", monospaced: true) { truncating(user) }
                }
                if let policy = details.restartPolicy {
                    MorbKeyValue("Restart policy", policy)
                }
                if !details.networks.isEmpty {
                    MorbKeyValue("Networks") {
                        HStack(spacing: Theme.space2) {
                            ForEach(details.networks, id: \.self) { network in
                                MorbChip(network, symbol: "network", rank: .quiet)
                            }
                        }
                    }
                }
                if let platform = details.platform, !platform.isEmpty {
                    MorbKeyValue("Platform", platform)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func truncating(_ text: String) -> some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(text)
    }

    // MARK: Ports

    private var portsSection: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            MorbSectionHeader("Ports", symbol: "point.3.connected.trianglepath.dotted",
                              count: container.ports.count)
            Table(container.ports) {
                TableColumn("Host") { port in
                    Text(verbatim: port.hostPort.map { "\(port.hostIP ?? "0.0.0.0"):\($0)" } ?? "not published")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(port.hostPort == nil ? .secondary : .primary)
                }
                TableColumn("Container") { port in
                    Text(verbatim: "\(port.containerPort)")
                        .font(.system(.callout, design: .monospaced))
                        .monospacedDigit()
                }
                TableColumn("Protocol") { port in
                    Text(port.proto.uppercased())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TableColumn("") { port in
                    if let url = port.url {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label("Open", systemImage: "arrow.up.forward.app")
                                .font(.caption)
                        }
                        .buttonStyle(.link)
                    } else {
                        Text("—").foregroundStyle(.tertiary).font(.caption)
                    }
                }
            }
            .tableStyle(.inset)
            .alternatingRowBackgrounds()
            .frame(height: tableHeight(rows: container.ports.count))
        }
        .padding(.horizontal, Theme.pagePadding)
    }

    // MARK: Environment

    private func environment(_ details: TrackBInspectDetails) -> some View {
        let matches = TrackBLogFilter.filter(
            details.env,
            needle: TrackBLogFilter.normalize(envQuery),
            lowered: \.lowered)

        return VStack(alignment: .leading, spacing: Theme.space3) {
            MorbSectionHeader("Environment", symbol: "list.bullet.rectangle", count: details.env.count)

            if !details.env.isEmpty {
                TrackBSearchField(text: $envQuery, prompt: "Filter variables", width: 220,
                                  caption: "\(matches.count)")
            }

            if details.env.isEmpty {
                TrackBQuietNote(text: "This container declares no environment variables.")
            } else if matches.isEmpty {
                MorbNoMatches(query: envQuery)
                    .frame(height: Theme.rowRich * 3)
            } else {
                VStack(spacing: 0) {
                    ForEach(matches) { variable in
                        TrackBEnvRow(
                            variable: variable,
                            isRevealed: revealed.contains(variable.id),
                            onToggleReveal: {
                                if revealed.contains(variable.id) {
                                    revealed.remove(variable.id)
                                } else {
                                    revealed.insert(variable.id)
                                }
                            })
                        if variable.id != matches.last?.id { MorbRowDivider(rowClass: .standard) }
                    }
                }
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                }
            }
        }
        .padding(.horizontal, Theme.pagePadding)
    }

    // MARK: Mounts

    private func mountRows(_ details: TrackBInspectDetails) -> [TrackBMountDisplay] {
        TrackBMountModel.rows(
            mounts: details.mounts,
            shares: fileSharing.shares,
            sharesAreKnown: TrackEShareStatus.canJudgeBindMounts(fileSharing))
    }

    private func mounts(_ details: TrackBInspectDetails) -> some View {
        let rows = mountRows(details)

        return VStack(alignment: .leading, spacing: Theme.space3) {
            MorbSectionHeader("Mounts", symbol: "externaldrive.connected.to.line.below", count: rows.count)

            Table(rows, selection: $mountSelection) {
                TableColumn("Kind") { row in
                    MorbChip(row.kindLabel, symbol: row.kind.symbol,
                            rank: row.kind == .bind ? .actionable : .quiet)
                        .help(row.kind.explanation)
                }
                TableColumn("Source") { row in
                    HStack(spacing: Theme.space2) {
                        if row.warning != nil {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.statusDegraded)
                        }
                        Text(row.source)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(row.warning == nil ? .primary : Theme.statusDegraded)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .help(row.warning ?? row.source)
                }
                TableColumn("In container") { row in
                    Text(row.destination)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                TableColumn("Access") { row in
                    Text(row.accessDescription)
                        .font(.caption)
                        .foregroundStyle(row.readOnly ? .secondary : .primary)
                }
                TableColumn("") { row in
                    if let hostPath = row.hostPath {
                        MorbIconButton("arrow.up.forward.app", help: "Reveal \(hostPath) in Finder") {
                            TrackBFinder.reveal(hostPath)
                        }
                    }
                }
            }
            .tableStyle(.inset)
            .alternatingRowBackgrounds()
            .frame(height: tableHeight(rows: rows.count))
            .contextMenu(forSelectionType: TrackBMountDisplay.ID.self) { ids in
                mountsContextMenu(ids: ids, rows: rows)
            }

            let bindCount = rows.filter { $0.kind == .bind }.count
            if bindCount > 0, rows.contains(where: { $0.warning == nil && $0.kind == .bind }) {
                Text(
                    "Bind mounts are folders on this Mac, visible to the VM at the same path. "
                        + "Only folders under a shared root can be mounted; manage them in "
                        + "Settings › File Sharing."
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Theme.pagePadding)
    }

    @ViewBuilder
    private func mountsContextMenu(ids: Set<TrackBMountDisplay.ID>, rows: [TrackBMountDisplay]) -> some View {
        if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
            if let hostPath = row.hostPath {
                Button("Reveal in Finder") { TrackBFinder.reveal(hostPath) }
                Button("Copy Host Path") { TrackBClipboard.copy(hostPath) }
            } else if row.source != "—" {
                Button(row.kind == .volume ? "Copy Volume Name" : "Copy Source") {
                    TrackBClipboard.copy(row.source)
                }
            }
            Button("Copy Container Path") { TrackBClipboard.copy(row.destination) }
        }
    }

    // MARK: Labels

    private func labels(_ details: TrackBInspectDetails) -> some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            MorbSectionHeader("Labels", symbol: "tag", count: details.labels.count)
            Table(details.labels) {
                TableColumn("Key") { label in
                    Text(label.key)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
                TableColumn("Value") { label in
                    Text(label.value.isEmpty ? "—" : label.value)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
            }
            .tableStyle(.inset)
            .alternatingRowBackgrounds()
            .frame(height: tableHeight(rows: details.labels.count))
        }
        .padding(.horizontal, Theme.pagePadding)
    }

    // MARK: Table sizing

    /// `Table` has no intrinsic height inside a `ScrollView` — it is a scroll view of its
    /// own — so every table here is given a fixed height that fits its rows exactly,
    /// capped so a container with forty labels does not push the rest of the tab off the
    /// bottom of the window.
    private func tableHeight(rows: Int) -> CGFloat {
        let header: CGFloat = 28
        let capped = min(max(rows, 1), 8)
        return header + CGFloat(capped) * Theme.rowStandard
    }

    // MARK: Placeholder

    private var loadingPlaceholder: some View {
        VStack(alignment: .leading, spacing: Theme.space4) {
            ForEach(0..<5, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Theme.radiusChip, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
                    .frame(height: 14)
                    .frame(maxWidth: .infinity)
            }
        }
        .redacted(reason: .placeholder)
        .padding(.horizontal, Theme.pagePadding)
        .padding(.top, Theme.space2)
    }
}

// MARK: - Env row

struct TrackBEnvRow: View {

    let variable: TrackBInspectDetails.EnvVar
    let isRevealed: Bool
    let onToggleReveal: () -> Void

    @State private var hovering = false

    private var sensitive: Bool { TrackBSecretHeuristic.looksSensitive(key: variable.key) }

    /// Selection is enabled only while the value is revealed: a masked value that can be
    /// dragged into another window would make the mask decorative rather than real.
    @ViewBuilder
    private var valueText: some View {
        if isRevealed {
            Text(variable.value.isEmpty ? "—" : variable.value).textSelection(.enabled)
        } else {
            Text(TrackBSecretHeuristic.mask)
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.space4) {
            HStack(spacing: Theme.space2) {
                if sensitive {
                    Image(systemName: "key.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.statusDegraded)
                        .help("The name suggests this is a secret")
                }
                Text(variable.key)
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            .frame(width: 220, alignment: .leading)

            valueText
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(isRevealed ? .primary : .secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: Theme.space1) {
                MorbIconButton(
                    isRevealed ? "eye.slash" : "eye",
                    help: isRevealed ? "Hide value" : "Reveal value",
                    action: onToggleReveal)
                MorbIconButton("doc.on.doc", help: "Copy value") {
                    TrackBClipboard.copy(variable.value)
                }
                .opacity(hovering ? 1 : 0)
            }
        }
        .morbRow(.standard)
        .onHover { hovering = $0 }
    }
}

// MARK: - Small pieces

struct TrackBQuietNote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, Theme.space3)
    }
}

struct TrackBInlineError: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: Theme.space3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.statusDegraded)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(Theme.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.statusDegraded.opacity(Theme.chipAlpha),
                    in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
    }
}
