// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// OVERVIEW: everything about a container that is not a number changing over time.
//
// The environment table is the one part with a real policy behind it. Values are hidden
// by default and revealed one at a time, because an environment block is where database
// passwords, API tokens and signing keys live, and this pane is the single most
// screenshotted view in an app like this. Redaction is not paternalism here; it is the
// difference between a bug report and an incident.

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
    @State private var revealAll = false

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 22) {
                if let details {
                    timeline(details)
                    configuration(details)
                    if !container.ports.isEmpty { portsSection }
                    environment(details)
                    if !details.mounts.isEmpty { mounts(details) }
                    if !details.labels.isEmpty { labels(details) }
                } else if isLoading {
                    loadingPlaceholder
                } else if let errorText {
                    TrackBInlineError(text: errorText)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: Timeline

    private func timeline(_ details: TrackBInspectDetails) -> some View {
        TrackBSection(title: "State", symbol: "clock") {
            HStack(spacing: 8) {
                stateChip(details)
                ForEach(Array(details.timeline.enumerated()), id: \.offset) { _, chip in
                    TrackBTimelineChip(
                        label: chip.label,
                        detail: chip.detail,
                        symbol: chip.symbol)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func stateChip(_ details: TrackBInspectDetails) -> some View {
        let unhealthy = details.health == "unhealthy" || container.isUnhealthy
        let tint = TrackBPalette.stateColor(container.state, unhealthy: unhealthy)
        var text = container.state
        if let health = details.health { text += " · \(health)" }
        if let uptime = details.uptime { text += " · up \(uptime)" }

        return HStack(spacing: 5) {
            TrackBStatusDot(state: container.state, unhealthy: unhealthy, size: 7)
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tint.opacity(0.13), in: Capsule())
        .foregroundStyle(tint)
    }

    // MARK: Configuration

    private func configuration(_ details: TrackBInspectDetails) -> some View {
        TrackBSection(title: "Configuration", symbol: "gearshape") {
            VStack(alignment: .leading, spacing: 7) {
                TrackBFieldRow(label: "Image") {
                    HStack(spacing: 6) {
                        TrackBMonoText(text: container.image)
                        TrackBCopyDot(value: container.image)
                    }
                }
                if !details.imageID.isEmpty {
                    TrackBFieldRow(label: "Image ID") {
                        TrackBMonoText(text: details.imageID, tint: .secondary)
                    }
                }
                TrackBFieldRow(label: "Command") {
                    HStack(spacing: 6) {
                        TrackBMonoText(text: details.command.isEmpty ? "—" : details.command)
                        if !details.command.isEmpty { TrackBCopyDot(value: details.command) }
                    }
                }
                if let entrypoint = details.entrypoint {
                    TrackBFieldRow(label: "Entrypoint") {
                        TrackBMonoText(text: entrypoint, tint: .secondary)
                    }
                }
                if let workingDir = details.workingDir {
                    TrackBFieldRow(label: "Working dir") {
                        TrackBMonoText(text: workingDir, tint: .secondary)
                    }
                }
                if let user = details.user {
                    TrackBFieldRow(label: "User") {
                        TrackBMonoText(text: user, tint: .secondary)
                    }
                }
                if let policy = details.restartPolicy {
                    TrackBFieldRow(label: "Restart policy") {
                        Text(policy).font(.callout)
                    }
                }
                TrackBFieldRow(label: "Created") {
                    Text(Formatters.relativeDate(container.createdAt))
                        .help(Formatters.absoluteDate(container.createdAt))
                }
                if !details.networks.isEmpty {
                    TrackBFieldRow(label: "Networks") {
                        HStack(spacing: 4) {
                            ForEach(details.networks, id: \.self) { network in
                                TrackBBadge(text: network, tone: .neutral, symbol: "network")
                            }
                        }
                    }
                }
                if let platform = details.platform, !platform.isEmpty {
                    TrackBFieldRow(label: "Platform") {
                        Text(platform).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Ports

    private var portsSection: some View {
        TrackBSection(title: "Ports", symbol: "point.3.connected.trianglepath.dotted",
                      count: container.ports.count) {
            TrackBTable(columns: [
                TrackBTableColumn(title: "Host", width: 150),
                TrackBTableColumn(title: "Container", width: 110),
                TrackBTableColumn(title: "Protocol", width: 80),
                TrackBTableColumn(title: "", width: nil),
            ]) {
                ForEach(container.ports) { port in
                    TrackBTableRow {
                        // `verbatim:` on both, and not by accident. `Text("\(anInt)")`
                        // resolves to the `LocalizedStringKey` initialiser, which formats
                        // the number for the locale — so port 3000 renders as "3,000".
                        Text(verbatim: port.hostPort.map { "\(port.hostIP ?? "0.0.0.0"):\($0)" }
                            ?? "not published")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(port.hostPort == nil ? .secondary : .primary)
                            .frame(width: 150, alignment: .leading)
                        Text(verbatim: "\(port.containerPort)")
                            .font(.system(size: 11.5, design: .monospaced).monospacedDigit())
                            .frame(width: 110, alignment: .leading)
                        Text(port.proto.uppercased())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .leading)
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
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: Environment

    private func environment(_ details: TrackBInspectDetails) -> some View {
        let matches = TrackBLogFilter.filter(
            details.env,
            needle: TrackBLogFilter.normalize(envQuery),
            lowered: \.lowered)

        return TrackBSection(
            title: "Environment", symbol: "list.bullet.rectangle", count: details.env.count
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    TrackBSearchField(
                        text: $envQuery,
                        prompt: "Filter variables",
                        width: 200,
                        caption: "\(matches.count)")
                    Toggle(isOn: $revealAll) {
                        Label(
                            revealAll ? "Values shown" : "Values hidden",
                            systemImage: revealAll ? "eye" : "eye.slash")
                            .font(.caption)
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .tint(Theme.accent)
                    .help("Environment values are hidden by default because they routinely contain secrets")
                    Spacer(minLength: 0)
                }

                if details.env.isEmpty {
                    TrackBQuietNote(text: "This container declares no environment variables.")
                } else if matches.isEmpty {
                    TrackBQuietNote(text: "No variable matches “\(envQuery)”.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(matches) { variable in
                            TrackBEnvRow(
                                variable: variable,
                                isRevealed: revealAll || revealed.contains(variable.id),
                                onToggleReveal: {
                                    if revealed.contains(variable.id) {
                                        revealed.remove(variable.id)
                                    } else {
                                        revealed.insert(variable.id)
                                    }
                                })
                            if variable.id != matches.last?.id { Divider().opacity(0.4) }
                        }
                    }
                    .background(.quaternary.opacity(0.35),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    // MARK: Mounts

    /// The two path columns are elastic. A bind mount's source is an absolute path on the
    /// user's disk and its destination an absolute path in the image; between them they
    /// are longer than any fixed pair of columns that also fits a narrow pane, so they
    /// take what is available and `TrackBMonoText` elides the middle — which keeps both
    /// ends of a path, the two parts anyone reads.
    ///
    /// The arrow between them is a column of its own rather than a prefix on the
    /// destination, so the arrowheads line up down the table instead of drifting with
    /// each path's length. The trailing column holds the Finder button and is sized for
    /// it whether or not the row has one — a column that collapses on volume rows would
    /// pull the access text out of register.
    private static let mountColumns = [
        TrackBTableColumn(title: "Kind", width: 74),
        TrackBTableColumn(title: "Source", width: nil, minWidth: 120),
        TrackBTableColumn(title: "", width: 10),
        TrackBTableColumn(title: "In container", width: nil, minWidth: 110),
        TrackBTableColumn(title: "Access", width: 74),
        TrackBTableColumn(title: "", width: 16),
    ]

    /// The mounts, classified.
    ///
    /// Recomputed with the view rather than cached: it is a `map` over at most a handful
    /// of rows, and caching it in `@State` would need invalidating on both the inspect
    /// document and the share table, which is two more ways to show stale warnings.
    private func mountRows(_ details: TrackBInspectDetails) -> [TrackBMountDisplay] {
        TrackBMountModel.rows(
            mounts: details.mounts,
            shares: fileSharing.shares,
            sharesAreKnown: TrackEShareStatus.canJudgeBindMounts(fileSharing))
    }

    private func mounts(_ details: TrackBInspectDetails) -> some View {
        let rows = mountRows(details)
        let bindCount = rows.filter { $0.kind == .bind }.count

        return TrackBSection(title: "Mounts", symbol: "externaldrive.connected.to.line.below",
                             count: rows.count) {
            VStack(alignment: .leading, spacing: 8) {
                TrackBTable(columns: Self.mountColumns) {
                    ForEach(rows) { row in
                        TrackBMountRow(row: row, columns: Self.mountColumns)
                    }
                }

                // One line of orientation, and only when there is a bind mount to
                // orient. On a container with nothing but volumes it would be a
                // paragraph about a feature that is not in use.
                if bindCount > 0, rows.contains(where: { $0.warning == nil && $0.kind == .bind }) {
                    Text(
                        "Bind mounts are folders on this Mac, visible to the VM at the same path. "
                            + "Only folders under a shared root can be mounted; manage them in "
                            + "Settings › File Sharing."
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Labels

    private func labels(_ details: TrackBInspectDetails) -> some View {
        TrackBSection(title: "Labels", symbol: "tag", count: details.labels.count) {
            VStack(spacing: 0) {
                ForEach(details.labels) { label in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(label.key)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 260, alignment: .leading)
                            .textSelection(.enabled)
                        Text(label.value.isEmpty ? "—" : label.value)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    if label.id != details.labels.last?.id { Divider().opacity(0.4) }
                }
            }
            .background(.quaternary.opacity(0.35),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    // MARK: Placeholder

    private var loadingPlaceholder: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<5, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
                    .frame(height: 14)
                    .frame(maxWidth: .infinity)
            }
        }
        .redacted(reason: .placeholder)
        .padding(.top, 4)
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
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(spacing: 4) {
                if sensitive {
                    Image(systemName: "key.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.orange)
                        .help("The name suggests this is a secret")
                }
                Text(variable.key)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)
            }
            .frame(width: 230, alignment: .leading)

            valueText
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isRevealed ? .primary : .secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 1) {
                TrackBIconButton(
                    symbol: isRevealed ? "eye.slash" : "eye",
                    help: isRevealed ? "Hide value" : "Reveal value",
                    tint: sensitive ? .orange : Theme.accent,
                    action: onToggleReveal)
                TrackBIconButton(
                    symbol: "doc.on.doc",
                    help: "Copy value",
                    tint: Theme.accent) {
                        TrackBClipboard.copy(variable.value)
                    }
                    .opacity(hovering ? 1 : 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Small pieces

struct TrackBTimelineChip: View {

    let label: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                // Both lines were a step dimmer than this and the chip read as a
                // disabled control sitting next to a live one — a 9pt semibold label at
                // `.tertiary` on a `.quaternary` fill is under 3:1 in either appearance.
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .kerning(0.4)
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct TrackBQuietNote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
    }
}

struct TrackBInlineError: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A copy affordance small enough to sit inline beside a value.
struct TrackBCopyDot: View {

    let value: String
    @State private var copied = false

    var body: some View {
        Button {
            TrackBClipboard.copy(value)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(copied ? Color.green : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copy")
    }
}

// MARK: - Table

/// A very small table: a header row of fixed-width columns and whatever rows are handed
/// to it. `Table` proper wants a homogeneous collection and a selection model, neither
/// of which these four-row read-only listings need.
struct TrackBTableColumn {
    let title: String
    /// A fixed width, or `nil` for a column that takes whatever is left.
    ///
    /// Flexible columns exist because the detail pane is a splitter away from being 460
    /// points wide, and a table of fixed columns wider than that does not clip — SwiftUI
    /// centres content it cannot fit, so an over-wide table loses a slice off *both*
    /// edges of the scroll view and takes the rest of the pane's layout with it.
    let width: CGFloat?
    /// How narrow a flexible column may get before it starts truncating.
    var minWidth: CGFloat = 120
}

struct TrackBTable<Rows: View>: View {

    let columns: [TrackBTableColumn]
    @ViewBuilder var rows: Rows

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    Text(column.title.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .kerning(0.5)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .modifier(TrackBColumnWidth(column: column))
                }
                // A flexible column already fills the row; a second flexible element
                // would take a share of the space away from it and break the alignment
                // between this header and the rows under it.
                if columns.allSatisfy({ $0.width != nil }) { Spacer(minLength: 0) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

            Divider().opacity(0.5)

            rows
        }
        .background(.quaternary.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Applies one column's sizing rule, so a header cell and the body cells under it are
/// laid out by the same code and cannot drift apart.
struct TrackBColumnWidth: ViewModifier {

    let column: TrackBTableColumn

    func body(content: Content) -> some View {
        if let width = column.width {
            content.frame(width: width, alignment: .leading)
        } else {
            content.frame(minWidth: column.minWidth, maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension View {
    /// Sizes a table cell to its column.
    func trackBColumn(_ column: TrackBTableColumn) -> some View {
        modifier(TrackBColumnWidth(column: column))
    }
}

struct TrackBTableRow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 12) {
            content
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}
