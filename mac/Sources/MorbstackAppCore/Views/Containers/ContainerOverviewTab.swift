// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The overview is a selected-record inspector. `Form`, `Section`, and
// `LabeledContent` keep its facts in the system's compact metadata hierarchy; the main
// Containers route owns the operational table. There are no dashboard cards, chips,
// nested scroll views, or miniature tables here.

import Foundation
import MorbstackKit
import SwiftUI

struct ContainerOverviewTab: View {

    let container: ContainerSummary
    let details: TrackBInspectDetails?
    let isLoading: Bool
    let errorText: String?
    var fileSharing: MorbShareSurface.Report = .empty
    var onRetry: (() -> Void)?

    @Environment(\.openURL) private var openURL

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
                } actions: {
                    if let onRetry {
                        Button("Try Again", action: onRetry)
                            .accessibilityIdentifier("containers.overview.empty.unavailable.retry")
                    }
                }
                .accessibilityIdentifier("containers.overview.empty.unavailable")
            } else {
                ContentUnavailableView {
                    Label("No Container Information", systemImage: "shippingbox")
                } description: {
                    Text("Docker did not return inspect information for this container.")
                } actions: {
                    if let onRetry {
                        Button("Reload", action: onRetry)
                            .accessibilityIdentifier("containers.overview.empty.noInformation.reload")
                    }
                }
                .accessibilityIdentifier("containers.overview.empty.noInformation")
            }
        }
    }

    private func loadedContent(_ details: TrackBInspectDetails) -> some View {
        Form {
            configurationSections(details)
            portsSection
            environmentSection(details)
            mountsSection(details)
            labelsSection(details)
        }
        // Explicitly `.grouped`, not `.automatic`. In the routes whose inspector
        // hosts a Form directly (Volumes, Images), automatic already resolves to the
        // grouped rendering: leading labels, values truncating inside the column.
        // Inside this `TabView`, automatic instead resolved to the columns grid,
        // which takes its natural width and clips both edges of a 270–460pt
        // inspector — verified in the real window 2026-08-05 ("Container ID"
        // rendered as "ntainer ID", values cut at the window edge) after the
        // `.formStyle(.columns)` removal elsewhere had already landed. Grouped is
        // the same system style the accepted inspectors get from automatic; it is
        // pinned here because the context resolves automatic differently.
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Identity, Lifecycle, and Configuration used to be three separate `Section`s.
    /// Half the nine section headers on this tab held one or two rows each — more
    /// skeleton than body — and these three describe one thing: the selected
    /// container. One "Container" group, in the same identity → lifecycle →
    /// configuration reading order the three sections already used.
    @ViewBuilder
    private func configurationSections(_ details: TrackBInspectDetails) -> some View {
        Section("Container") {
            LabeledContent("Name") {
                monospaced(details.name.isEmpty ? container.displayName : details.name)
            }
            LabeledContent("Container ID") {
                monospaced(details.id.isEmpty ? container.id : details.id)
            }
            if let created = details.created {
                LabeledContent("Created") {
                    Text(Formatters.relativeDate(created))
                        .help(Formatters.absoluteDate(created))
                }
            } else {
                LabeledContent("Created", value: "Not reported")
            }

            LabeledContent("Status") {
                Text(statusText(details))
            }
            LabeledContent("Health", value: details.health?.capitalized ?? "Not reported")
            if let startedAt = details.startedAt, startedAt.timeIntervalSince1970 > 0 {
                LabeledContent("Started") {
                    Text(Formatters.relativeDate(startedAt))
                        .help(Formatters.absoluteDate(startedAt))
                }
            } else {
                LabeledContent("Started", value: "Not reported")
            }
            if let finishedAt = details.finishedAt, finishedAt.timeIntervalSince1970 > 0,
               details.status != "running", details.status != "restarting"
            {
                LabeledContent("Exited") {
                    Text(Formatters.relativeDate(finishedAt))
                        .help(Formatters.absoluteDate(finishedAt))
                }
            }
            if let exitCode = details.exitCode,
               details.status != "running", details.status != "restarting"
            {
                LabeledContent("Exit Code") { monospaced(Formatters.identifier(exitCode)) }
            }
            if details.restartCount > 0 {
                LabeledContent("Restarts") { Text(details.restartCount, format: .number) }
            }
            if let policy = details.restartPolicy {
                LabeledContent("Restart Policy") { Text(policy) }
            }

            LabeledContent("Image") {
                monospaced(details.imageRef.isEmpty ? container.image : details.imageRef)
            }
            if !details.imageID.isEmpty {
                LabeledContent("Image ID") { monospaced(details.imageID) }
            }
            LabeledContent("Command") {
                monospaced(details.command.isEmpty ? "Not reported" : details.command)
            }
            if let entrypoint = details.entrypoint {
                LabeledContent("Entrypoint") { monospaced(entrypoint) }
            }
            if let workingDir = details.workingDir {
                LabeledContent("Working Directory") { monospaced(workingDir) }
            }
            if let user = details.user {
                LabeledContent("User") { monospaced(user) }
            }
            if let platform = details.platform, !platform.isEmpty {
                LabeledContent("Platform") { Text(platform) }
            }
            if let readOnly = details.resourceLimits.readOnlyRootFilesystem {
                LabeledContent("Read-only Root Filesystem", value: readOnly ? "Yes" : "No")
            }
        }

        resourceLimitsSection(details.resourceLimits)
        networksSection(details)
    }

    /// Every technical value on this tab — IDs, digests, image references, commands,
    /// paths — goes through here. `lineLimit(2)` with `truncationMode(.middle)` is
    /// the Volumes "Guest Mount Point" pattern (`VolumesRootView.detailPane`): in a
    /// `Form`, a `LabeledContent` value that can wrap instead of being forced onto
    /// one line breaks onto its own full-width row below the label rather than
    /// fighting the label for a ~300pt trailing column. A short value like a status
    /// word or a container name still renders on one line; only long identifiers pay
    /// for the second line they actually need. `textSelection(.enabled)` makes every
    /// one of them copyable via the system's normal select-and-Copy, the same as
    /// every other identifier in the app.
    private func monospaced(_ text: String) -> some View {
        Text(text)
            .font(.system(.body, design: .monospaced))
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(text)
    }

    private func statusText(_ details: TrackBInspectDetails) -> String {
        let status = details.status.isEmpty ? container.state : details.status
        return status.isEmpty ? "Not reported" : status.capitalized
    }

    private func resourceLimitsSection(_ limits: TrackBInspectDetails.ResourceLimits) -> some View {
        Section("Resource Limits") {
            LabeledContent("Memory", value: limits.memoryLimitDescription)
            LabeledContent("CPUs", value: limits.cpuLimitDescription)
            LabeledContent("CPU Shares", value: limits.cpuSharesDescription)
            LabeledContent("PIDs", value: limits.pidsLimitDescription)
        }
    }

    @ViewBuilder
    private func networksSection(_ details: TrackBInspectDetails) -> some View {
        Section("Networks") {
            if let networkMode = details.networkMode {
                LabeledContent("Mode", value: networkMode)
            } else {
                LabeledContent("Mode", value: "Not reported")
            }

            if details.networkEndpoints.isEmpty {
                Text("Docker did not report any network endpoints for this container.")
                    .foregroundStyle(.secondary)
            } else {
                DisclosureGroup("Endpoints (\(details.networkEndpoints.count))") {
                    ForEach(details.networkEndpoints) { endpoint in
                        DisclosureGroup(endpoint.name) {
                            if let address = endpoint.ipAddress {
                                LabeledContent("IPv4 Address") { monospaced(address) }
                            }
                            if let address = endpoint.globalIPv6Address {
                                LabeledContent("IPv6 Address") { monospaced(address) }
                            }
                            if let gateway = endpoint.gateway {
                                LabeledContent("Gateway") { monospaced(gateway) }
                            }
                            if let gateway = endpoint.ipv6Gateway {
                                LabeledContent("IPv6 Gateway") { monospaced(gateway) }
                            }
                            if let macAddress = endpoint.macAddress {
                                LabeledContent("MAC Address") { monospaced(macAddress) }
                            }
                            if let endpointID = endpoint.endpointID {
                                LabeledContent("Endpoint ID") { monospaced(endpointID) }
                            }
                            if let networkID = endpoint.networkID {
                                LabeledContent("Network ID") { monospaced(networkID) }
                            }
                            if !endpoint.aliases.isEmpty {
                                LabeledContent("Aliases") {
                                    Text(endpoint.aliases.joined(separator: ", "))
                                        .textSelection(.enabled)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var portsSection: some View {
        Section {
            if container.ports.isEmpty {
                Text("No published ports reported for this container.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(container.ports) { port in
                    LabeledContent(port.containerDisplay) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(port.hostDisplay ?? "Not Published")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(port.hostPort == nil ? .secondary : .primary)
                            if let address = port.browserAddress {
                                HStack(spacing: 8) {
                                    Text(address.absoluteString)
                                        .font(.system(.body, design: .monospaced))
                                        .textSelection(.enabled)
                                    browserAddressActions(for: address)
                                }
                            } else if let reason = port.browserAddressUnavailableReason {
                                Text(reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Ports")
        } footer: {
            // One sentence: which bindings a browser action will open, and that
            // Morbstack never probes the service to decide. Was two.
            Text("Browser actions open only Docker-reported TCP bindings on loopback addresses — Morbstack never probes the service.")
        }
    }

    private func browserAddressActions(for address: URL) -> some View {
        Menu("Address Actions") {
            Button("Copy Address") { MorbPasteboard.copy(address.absoluteString) }
            Button("Open in Browser") { openURL(address) }
        }
        .accessibilityLabel("Address actions for \(address.absoluteString)")
        .help("Copy or open \(address.absoluteString)")
    }

    @ViewBuilder
    private func environmentSection(_ details: TrackBInspectDetails) -> some View {
        let variables = TrackBLogFilter.filter(
            details.env,
            needle: TrackBLogFilter.normalize(envQuery),
            lowered: \.lowered)

        Section("Environment") {
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
        Section("Mounts") {
            if rows.isEmpty {
                Text("Docker did not report any mounts for this container.")
                    .foregroundStyle(.secondary)
            } else {
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
        Section("Labels") {
            if details.labels.isEmpty {
                Text("This container declares no labels.")
                    .foregroundStyle(.secondary)
            } else {
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
