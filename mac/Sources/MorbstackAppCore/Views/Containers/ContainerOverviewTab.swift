// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The overview is a selected-record inspector. `Form`, `Section`, and
// `LabeledContent` keep its facts in the system's compact metadata hierarchy; the main
// Containers route owns the operational table. There are no dashboard cards, chips,
// nested scroll views, or miniature tables here.

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
    @State private var isEnvironmentExpanded = false
    @State private var areMountsExpanded = false
    @State private var areLabelsExpanded = false

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
        Form {
            configurationSections(details)
            if !container.ports.isEmpty { portsSection }
            environmentSection(details)
            if !details.mounts.isEmpty { mountsSection(details) }
            if !details.labels.isEmpty { labelsSection(details) }
        }
        .formStyle(.automatic)
    }

    @ViewBuilder
    private func configurationSections(_ details: TrackBInspectDetails) -> some View {
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

    private var portsSection: some View {
        Section("Ports") {
            ForEach(container.ports) { port in
                LabeledContent("\(port.containerPort)/\(port.proto.uppercased())") {
                    HStack(spacing: 8) {
                        Text(port.hostPort.map { "\(port.hostIP ?? "0.0.0.0"):\($0)" } ?? "Not Published")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(port.hostPort == nil ? .secondary : .primary)
                        if let url = port.url {
                            Link("Open", destination: url)
                            .accessibilityLabel("Open \(url.absoluteString)")
                            .help("Open \(url.absoluteString)")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func environmentSection(_ details: TrackBInspectDetails) -> some View {
        let variables = TrackBLogFilter.filter(
            details.env,
            needle: TrackBLogFilter.normalize(envQuery),
            lowered: \.lowered)

        Section {
            DisclosureGroup(
                "Environment (\(details.env.count) \(details.env.count == 1 ? "variable" : "variables"))",
                isExpanded: $isEnvironmentExpanded)
            {
                if !details.env.isEmpty {
                    TextField("Filter variables", text: $envQuery)
                }
                if details.env.isEmpty {
                    Text("This container declares no environment variables.")
                        .foregroundStyle(.secondary)
                } else if variables.isEmpty {
                    ContentUnavailableView.search(text: envQuery)
                } else {
                    ForEach(variables) { variable in
                        environmentRow(variable)
                    }
                }
            }
        }
    }

    private func environmentRow(_ variable: TrackBInspectDetails.EnvVar) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                environmentValue(variable)
                Button {
                    if revealed.contains(variable.id) {
                        revealed.remove(variable.id)
                    } else {
                        revealed.insert(variable.id)
                    }
                } label: {
                    Image(systemName: revealed.contains(variable.id) ? "eye.slash" : "eye")
                }
                .accessibilityLabel(
                    revealed.contains(variable.id)
                        ? "Hide \(variable.key) value"
                        : "Reveal \(variable.key) value")
                .help(
                    revealed.contains(variable.id)
                        ? "Hide \(variable.key) value"
                        : "Reveal \(variable.key) value")

                Button {
                    MorbPasteboard.copy(variable.value)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel("Copy \(variable.key) value")
                .help("Copy \(variable.key) value")
            }
        } label: {
            environmentLabel(variable)
        }
    }

    @ViewBuilder
    private func environmentLabel(_ variable: TrackBInspectDetails.EnvVar) -> some View {
        if TrackBSecretHeuristic.looksSensitive(key: variable.key) {
            Label(variable.key, systemImage: "key.fill")
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .help("The variable name suggests this value may be sensitive")
        } else {
            Text(variable.key)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .help(variable.key)
        }
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

    @ViewBuilder
    private func mountsSection(_ details: TrackBInspectDetails) -> some View {
        let rows = mountRows(details)
        Section {
            DisclosureGroup(
                "Mounts (\(rows.count) \(rows.count == 1 ? "mount" : "mounts"))",
                isExpanded: $areMountsExpanded)
            {
                ForEach(rows) { row in
                    LabeledContent {
                        HStack(spacing: 8) {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(row.destination)
                                    .font(.system(.body, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(row.accessDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let hostPath = row.hostPath {
                                Button("Reveal", systemImage: "arrow.up.forward.app") {
                                    TrackBFinder.reveal(hostPath)
                                }
                                .accessibilityLabel("Reveal \(hostPath) in Finder")
                                .help("Reveal in Finder")
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(row.kindLabel.capitalized, systemImage: row.kind.symbol)
                            mountSource(row)
                        }
                    }
                    .contextMenu {
                        mountContextMenu(row: row)
                    }
                }

                if rows.contains(where: { $0.kind == .bind && $0.warning == nil }) {
                    Text("Bind mounts are folders on this Mac shared into the VM at the same path. Manage shared folders in Settings › File Sharing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
    private func mountContextMenu(row: TrackBMountDisplay) -> some View {
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

    private func labelsSection(_ details: TrackBInspectDetails) -> some View {
        Section {
            DisclosureGroup(
                "Labels (\(details.labels.count) \(details.labels.count == 1 ? "label" : "labels"))",
                isExpanded: $areLabelsExpanded)
            {
                ForEach(details.labels) { label in
                    LabeledContent {
                        Text(label.value.isEmpty ? "—" : label.value)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .textSelection(.enabled)
                    } label: {
                        Text(label.key)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .textSelection(.enabled)
                    }
                }
            }
        }
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
