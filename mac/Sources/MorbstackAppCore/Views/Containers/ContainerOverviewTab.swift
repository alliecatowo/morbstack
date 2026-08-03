// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The overview is an inspector: `Form` and `LabeledContent` describe one selected
// container, while the variable-length operational collections use ordinary macOS
// tables.  There are no dashboard cards, chips, or custom list rows here.

import AppKit
import MorbstackKit
import SwiftUI

struct ContainerOverviewTab: View {

    let container: ContainerSummary
    let details: TrackBInspectDetails?
    let isLoading: Bool
    let errorText: String?
    var fileSharing: MorbShareSurface.Report = .empty

    @State private var envQuery = ""
    @State private var revealed: Set<Int> = []
    @State private var mountSelection: Set<TrackBMountDisplay.ID> = []

    var body: some View {
        overviewContent
    }

    @ViewBuilder
    private var overviewContent: some View {
        Group {
            if let details {
                loadedContent(details)
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorText {
                ContentUnavailableView {
                    Label("Container Information Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorText)
                }
            }
        }
    }

    private func loadedContent(_ details: TrackBInspectDetails) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                configurationForm(details)
                if !container.ports.isEmpty { portsTable }
                environment(details)
                if !details.mounts.isEmpty { mountsTable(details) }
                if !details.labels.isEmpty { labelsTable(details) }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func configurationForm(_ details: TrackBInspectDetails) -> some View {
        Form {
            Section("State") {
                LabeledContent("Status") {
                    Text(statusText(details))
                }
                if let created = details.created {
                    LabeledContent("Created") {
                        Text(Formatters.relativeDate(created))
                            .help(Formatters.absoluteDate(created))
                    }
                }
                if let startedAt = details.startedAt, startedAt.timeIntervalSince1970 > 0 {
                    LabeledContent("Started") {
                        Text(Formatters.relativeDate(startedAt))
                            .help(Formatters.absoluteDate(startedAt))
                    }
                }
                if let finishedAt = details.finishedAt, finishedAt.timeIntervalSince1970 > 0,
                   container.state != "running", container.state != "restarting"
                {
                    let code = details.exitCode.map { " (exit \($0))" } ?? ""
                    LabeledContent("Exited") {
                        Text(Formatters.relativeDate(finishedAt) + code)
                            .help(Formatters.absoluteDate(finishedAt))
                    }
                }
                if details.restartCount > 0 {
                    LabeledContent("Restarts") { Text("\(details.restartCount)") }
                }
            }

            Section("Configuration") {
                LabeledContent("Image") { monospaced(container.image) }
                if !details.imageID.isEmpty {
                    LabeledContent("Image ID") { monospaced(details.imageID) }
                }
                LabeledContent("Command") { monospaced(details.command.isEmpty ? "—" : details.command) }
                if let entrypoint = details.entrypoint {
                    LabeledContent("Entrypoint") { monospaced(entrypoint) }
                }
                if let workingDir = details.workingDir {
                    LabeledContent("Working Directory") { monospaced(workingDir) }
                }
                if let user = details.user {
                    LabeledContent("User") { monospaced(user) }
                }
                if let policy = details.restartPolicy {
                    LabeledContent("Restart Policy") { Text(policy) }
                }
                if !details.networks.isEmpty {
                    LabeledContent("Networks") { Text(details.networks.joined(separator: ", ")) }
                }
                if let platform = details.platform, !platform.isEmpty {
                    LabeledContent("Platform") { Text(platform) }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func monospaced(_ text: String) -> some View {
        Text(text)
            .font(.system(.body, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(text)
    }

    private func statusText(_ details: TrackBInspectDetails) -> String {
        let status = details.status.isEmpty ? container.state : details.status
        guard let health = details.health, !health.isEmpty else { return status.capitalized }
        return "\(status.capitalized) · \(health)"
    }

    private var portsTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ports")
                .font(.headline)

            Table(container.ports) {
                TableColumn("Host") { port in
                    Text(port.hostPort.map { "\(port.hostIP ?? "0.0.0.0"):\($0)" } ?? "Not Published")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(port.hostPort == nil ? .secondary : .primary)
                }
                TableColumn("Container") { port in
                    Text("\(port.containerPort)")
                        .font(.system(.body, design: .monospaced))
                }
                TableColumn("Protocol") { port in
                    Text(port.proto.uppercased())
                        .foregroundStyle(.secondary)
                }
                TableColumn("") { port in
                    if let url = port.url {
                        Button { NSWorkspace.shared.open(url) } label: {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .accessibilityLabel("Open \(url.absoluteString)")
                        .help("Open \(url.absoluteString)")
                    }
                }
                .width(28)
            }
            .frame(height: tableHeight(rows: container.ports.count))
        }
    }

    private func environment(_ details: TrackBInspectDetails) -> some View {
        let variables = TrackBLogFilter.filter(
            details.env,
            needle: TrackBLogFilter.normalize(envQuery),
            lowered: \.lowered)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Environment")
                    .font(.headline)
                Spacer()
                if !details.env.isEmpty {
                    DocumentSearchField(text: $envQuery, prompt: "Filter variables", width: 180)
                }
            }

            if details.env.isEmpty {
                Text("This container declares no environment variables.")
                    .foregroundStyle(.secondary)
            } else if variables.isEmpty {
                ContentUnavailableView.search(text: envQuery)
                    .frame(height: 120)
            } else {
                environmentTable(variables)
            }
        }
    }

    private func environmentTable(_ variables: [TrackBInspectDetails.EnvVar]) -> some View {
        Table(variables) {
            TableColumn("Name") { variable in
                HStack(spacing: 6) {
                    if TrackBSecretHeuristic.looksSensitive(key: variable.key) {
                        Image(systemName: "key.fill")
                            .foregroundStyle(.orange)
                            .help("The variable name suggests this value may be sensitive")
                    }
                    Text(variable.key)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
            }
            .width(min: 120, ideal: 170)

            TableColumn("Value") { variable in
                environmentValue(variable)
            }

            TableColumn("") { variable in
                HStack(spacing: 4) {
                    Button {
                        if revealed.contains(variable.id) {
                            revealed.remove(variable.id)
                        } else {
                            revealed.insert(variable.id)
                        }
                    } label: {
                        Image(systemName: revealed.contains(variable.id) ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(revealed.contains(variable.id) ? "Hide value" : "Reveal value")
                    .help(revealed.contains(variable.id) ? "Hide value" : "Reveal value")

                    Button {
                        MorbPasteboard.copy(variable.value)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel("Copy value")
                    .help("Copy value")
                }
            }
            .width(54)
        }
        .frame(height: tableHeight(rows: variables.count))
    }

    @ViewBuilder
    private func environmentValue(_ variable: TrackBInspectDetails.EnvVar) -> some View {
        if revealed.contains(variable.id) {
            Text(variable.value.isEmpty ? "—" : variable.value)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        } else {
            Text(TrackBSecretHeuristic.mask)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func mountRows(_ details: TrackBInspectDetails) -> [TrackBMountDisplay] {
        TrackBMountModel.rows(
            mounts: details.mounts,
            shares: fileSharing.shares,
            sharesAreKnown: TrackEShareStatus.canJudgeBindMounts(fileSharing))
    }

    private func mountsTable(_ details: TrackBInspectDetails) -> some View {
        let rows = mountRows(details)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Mounts")
                .font(.headline)

            Table(rows, selection: $mountSelection) {
                TableColumn("Kind") { row in
                    Label(row.kindLabel.capitalized, systemImage: row.kind.symbol)
                        .help(row.kind.explanation)
                }
                .width(min: 86, ideal: 104)
                TableColumn("Source") { row in
                    mountSource(row)
                }
                TableColumn("Container Path") { row in
                    Text(row.destination)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                TableColumn("Access") { row in
                    Text(row.accessDescription)
                        .foregroundStyle(.secondary)
                }
                TableColumn("") { row in
                    if let hostPath = row.hostPath {
                        Button { TrackBFinder.reveal(hostPath) } label: {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .accessibilityLabel("Reveal \(hostPath) in Finder")
                        .help("Reveal in Finder")
                    }
                }
                .width(28)
            }
            .frame(height: tableHeight(rows: rows.count))
            .contextMenu(forSelectionType: TrackBMountDisplay.ID.self) { ids in
                mountContextMenu(ids: ids, rows: rows)
            }

            if rows.contains(where: { $0.kind == .bind && $0.warning == nil }) {
                Text("Bind mounts are folders on this Mac shared into the VM at the same path. Manage shared folders in Settings › File Sharing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func mountSource(_ row: TrackBMountDisplay) -> some View {
        HStack(spacing: 6) {
            if row.warning != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            }
            if row.warning == nil {
                Text(row.source)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(row.source)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .help(row.warning ?? row.source)
    }

    @ViewBuilder
    private func mountContextMenu(ids: Set<TrackBMountDisplay.ID>, rows: [TrackBMountDisplay]) -> some View {
        if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
            if let hostPath = row.hostPath {
                Button("Reveal in Finder") { TrackBFinder.reveal(hostPath) }
                Button("Copy Host Path") { MorbPasteboard.copy(hostPath) }
            } else if row.source != "—" {
                Button(row.kind == .volume ? "Copy Volume Name" : "Copy Source") {
                    MorbPasteboard.copy(row.source)
                }
            }
            Button("Copy Container Path") { MorbPasteboard.copy(row.destination) }
        }
    }

    private func labelsTable(_ details: TrackBInspectDetails) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Labels")
                .font(.headline)
            Table(details.labels) {
                TableColumn("Key") { label in
                    Text(label.key)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
                TableColumn("Value") { label in
                    Text(label.value.isEmpty ? "—" : label.value)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
            }
            .frame(height: tableHeight(rows: details.labels.count))
        }
    }

    private func tableHeight(rows: Int) -> CGFloat {
        28 + CGFloat(min(max(rows, 1), 8)) * 26
    }
}

struct TrackBQuietNote: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
    }
}

struct TrackBInlineError: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
}
