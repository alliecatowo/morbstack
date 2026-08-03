// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Stacks — Compose projects, derived rather than tracked.
//
// Morbstack does not run Compose; the standard `docker compose` CLI does, against
// Morbstack's engine. So there is no stack registry to read: a "stack" here is a group
// of containers that agree on their `com.docker.compose.project` label, exactly the
// grouping the CLI itself uses. That has one real consequence worth knowing — a project
// whose containers have all been removed simply stops existing, because nothing else
// records that it ever did.
//
// The list is built on the same `MorbGroupHeader` + fixed-height rich row the Containers
// screen uses for its compose groups — one row rhythm across the two screens that share
// the concept — plus a summary strip of aggregate `MorbMetric`s, which is what gives this
// screen something to justify its space instead of two thin cards on a mostly-empty
// window (`docs/design/CRITIQUE.md`, `stacks-dark`).
//
// The one thing the labels on the list endpoint do *not* carry is the path to the
// compose file. That lives on the container's full inspect payload, which is why this
// screen makes one extra call per project and caches the answer.

import AppKit
import Foundation
import MorbstackKit
import Observation
import SwiftUI

// MARK: - Compose metadata

/// The compose file paths behind each project, fetched lazily from `/containers/{id}/json`.
@MainActor
@Observable
final class TrackDComposeMetadata {

    /// project → the `config_files` label, already split into paths.
    private(set) var configFiles: [String: [String]] = [:]
    /// project → the directory `docker compose` was run from.
    private(set) var workingDirectories: [String: String] = [:]

    @ObservationIgnored private var inFlight: Set<String> = []

    /// Fetches the compose paths for `project` once. Repeat calls are free.
    func load(project: String, containerID: String, client: DockerClient) {
        guard configFiles[project] == nil, !inFlight.contains(project) else { return }
        inFlight.insert(project)

        Task { @MainActor in
            defer { inFlight.remove(project) }
            guard let json = try? await client.inspectContainer(id: containerID) else { return }
            guard let data = json.data(using: .utf8),
                let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let config = root["Config"] as? [String: Any],
                let labels = config["Labels"] as? [String: String]
            else { return }

            if let files = labels["com.docker.compose.project.config_files"], !files.isEmpty {
                configFiles[project] = files.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
            } else {
                // Cache the miss too, or every refresh re-asks a question already
                // answered "no".
                configFiles[project] = []
            }
            if let directory = labels["com.docker.compose.project.working_dir"], !directory.isEmpty {
                workingDirectories[project] = directory
            }
        }
    }
}

// MARK: - Root

struct StacksRootView: View {

    let model: AppModel

    @State private var metadata = TrackDComposeMetadata()
    @State private var query = ""
    @State private var busyProjects: Set<String> = []
    @State private var toast: TrackCToast?

    /// Compose projects only — the standalone bucket belongs on the Containers screen.
    private var stacks: [ComposeGroup] {
        model.containers.groupedByComposeProject().filter { $0.project != nil }
    }

    private var visibleStacks: [ComposeGroup] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return stacks }
        return stacks.filter { group in
            if group.title.localizedCaseInsensitiveContains(needle) { return true }
            return group.containers.contains { container in
                (container.composeService ?? container.displayName).localizedCaseInsensitiveContains(needle)
                    || container.image.localizedCaseInsensitiveContains(needle)
            }
        }
    }

    private var totalServices: Int { stacks.reduce(0) { $0 + $1.containers.count } }
    private var runningServices: Int { stacks.reduce(0) { $0 + $1.runningCount } }

    private var degradedCount: Int {
        stacks.filter { $0.runningCount > 0 && $0.runningCount < $0.containers.count }.count
    }

    /// Everything the deleted summary band used to say, in the one line macOS already
    /// reserves for it. See `content` for why the band is gone.
    private var subtitle: String {
        var parts = ["\(stacks.count) project\(stacks.count == 1 ? "" : "s")",
                     "\(runningServices) of \(totalServices) services running"]
        if degradedCount > 0 {
            parts.append("\(degradedCount) degraded")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        content
            .morbScreen(title: "Stacks", subtitle: subtitle, edge: .hard)
            .searchable(text: $query, placement: .toolbar, prompt: "Project, service, image")
            .trackCToast($toast)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if stacks.isEmpty {
            emptyState
        } else if visibleStacks.isEmpty {
            MorbNoMatches(query: query)
        } else {
            // Just the list. The three-metric summary band that used to sit above it is
            // gone: every number it showed — projects, services running, stacks degraded
            // — is now in the window subtitle, which is where macOS puts a screen's
            // aggregate line. A painted dashboard strip inside the content area was the
            // same information in a second, non-native place.
            list
        }
    }

    // MARK: List

    private var list: some View {
        List {
            ForEach(visibleStacks) { stack in
                Section {
                    ForEach(stack.containers) { container in
                        serviceRow(container, project: stack.title)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    groupHeader(stack)
                        .listRowInsets(EdgeInsets())
                }
            }
        }
        .listStyle(.inset)
        .environment(\.defaultMinListRowHeight, Theme.rowRich)
        .scrollContentBackground(.hidden)
        .background(.background)
    }

    private func groupHeader(_ stack: ComposeGroup) -> some View {
        let project = stack.title
        let busy = busyProjects.contains(stack.id)
        let state = MorbGroupState.from(
            running: stack.runningCount, total: stack.containers.count,
            transitioning: busy ? stack.containers.count : 0)

        return MorbGroupHeader(
            project, state: state, running: stack.runningCount, total: stack.containers.count,
            symbol: "square.3.layers.3d"
        ) {
            if busy {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 20)
            } else {
                HStack(spacing: Theme.space1) {
                    MorbIconButton("play.fill", help: "Start every stopped service in \(project)") {
                        run(.start, on: stack)
                    }
                    .disabled(stack.isFullyRunning)
                    MorbIconButton("arrow.clockwise", help: "Restart every service in \(project)") {
                        run(.restart, on: stack)
                    }
                    .disabled(stack.runningCount == 0)
                    MorbIconButton("stop.fill", help: "Stop every running service in \(project)") {
                        run(.stop, on: stack)
                    }
                    .disabled(stack.runningCount == 0)
                    if let file = configFileLabel(project) {
                        MorbIconButton("doc.text", help: "Copy the Compose file path\n\(file)") {
                            trackCCopy(file)
                        }
                    }
                }
            }
        }
        .task(id: stack.id) {
            guard let first = stack.containers.first else { return }
            metadata.load(project: project, containerID: first.id, client: model.client)
        }
    }

    /// The compose file, shortened to the last two path components — the full path is in
    /// the tooltip and on the clipboard, and `…/checkout/docker-compose.yml` is what
    /// actually tells two projects apart.
    private func configFileLabel(_ project: String) -> String? {
        guard let files = metadata.configFiles[project], let first = files.first else { return nil }
        let parts = first.split(separator: "/")
        guard parts.count > 2 else { return first }
        return "…/" + parts.suffix(2).joined(separator: "/")
    }

    // MARK: Service row

    private static let trailingWidth: CGFloat = 168

    private func serviceRow(_ container: ContainerSummary, project: String) -> some View {
        MorbRichRow(
            title: container.composeService ?? container.displayName,
            subtitle: container.image
        ) {
            MorbStatusDot(
                tone: StatusTone.forContainer(state: container.state, unhealthy: container.isUnhealthy),
                pulsing: container.state == "restarting")
        } trailing: {
            serviceTrailing(container)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            TrackDAppBridge.reveal(containerID: container.id, in: model)
        }
        .contextMenu {
            Button("Open in Containers") {
                TrackDAppBridge.reveal(containerID: container.id, in: model)
            }
            Button("View Logs") {
                TrackDAppBridge.reveal(containerID: container.id, in: model, showingLogs: true)
            }
            Divider()
            ForEach(container.availableActions, id: \.self) { action in
                Button(action.title, role: action.isDestructive ? .destructive : nil) {
                    act(action, container)
                }
            }
        }
    }

    @ViewBuilder
    private func serviceTrailing(_ container: ContainerSummary) -> some View {
        HStack(spacing: Theme.space1) {
            if container.isRunning {
                MorbIconButton("stop.fill", help: "Stop") { act(.stop, container) }
                MorbIconButton("arrow.clockwise", help: "Restart") { act(.restart, container) }
            } else {
                MorbIconButton("play.fill", help: "Start") { act(.start, container) }
            }
            portsLine(container)
        }
        .frame(width: Self.trailingWidth, alignment: .trailing)
    }

    @ViewBuilder
    private func portsLine(_ container: ContainerSummary) -> some View {
        let publishable = container.ports.filter { $0.hostPort != nil }
        if let first = publishable.first {
            HStack(spacing: Theme.space1 + 1) {
                if publishable.count > 1 {
                    MorbOverflowChip(
                        hidden: publishable.count - 1,
                        detail: publishable.dropFirst().map(\.label).joined(separator: ", "))
                }
                MorbPortChip(
                    host: first.hostPort.map(String.init) ?? first.label,
                    container: "\(first.containerPort)/\(first.proto)",
                    isOpenable: first.url != nil)
            }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        MorbEmptyState(
            "No Compose stacks",
            systemImage: "square.stack.3d.up",
            description: "Anything started with docker compose up against the Morbstack engine shows up "
                + "here, grouped by project. Morbstack reads the standard Compose labels, so the regular "
                + "CLI is all you need — point it at the Morbstack socket and run it."
        ) {
            VStack(spacing: Theme.space3) {
                Button {
                    trackCCopy(TrackDLinks.dockerContextCommand(socketPath: MorbPaths.dockerSocket.path))
                } label: {
                    Label("Copy docker context command", systemImage: "doc.on.doc")
                }
                .morbButton(.standard)

                Text(TrackDLinks.dockerHostExport(socketPath: MorbPaths.dockerSocket.path))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: Actions

    private func run(_ action: ContainerAction, on stack: ComposeGroup) {
        let targets: [ContainerSummary]
        switch action {
        case .start: targets = stack.containers.filter { !$0.isRunning }
        case .stop: targets = stack.containers.filter(\.isRunning)
        default: targets = stack.containers
        }
        guard !targets.isEmpty else { return }

        busyProjects.insert(stack.id)
        Task { @MainActor in
            // Sequential rather than concurrent: compose services have start-order
            // dependencies, and hammering the engine with eight simultaneous starts is
            // how a database ends up racing the thing that connects to it.
            for container in targets {
                await model.containerAction(action, id: container.id)
            }
            busyProjects.remove(stack.id)
        }
    }

    private func act(_ action: ContainerAction, _ container: ContainerSummary) {
        Task { @MainActor in
            await model.containerAction(action, id: container.id)
        }
    }
}
