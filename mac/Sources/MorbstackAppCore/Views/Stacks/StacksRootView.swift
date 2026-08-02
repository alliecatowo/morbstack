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
    @State private var busyProjects: Set<String> = []

    /// Compose projects only — the standalone bucket belongs on the Containers screen.
    private var stacks: [ComposeGroup] {
        model.containers.groupedByComposeProject().filter { $0.project != nil }
    }

    var body: some View {
        Group {
            if stacks.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(stacks) { stack in
                        TrackDStackCard(
                            stack: stack,
                            model: model,
                            metadata: metadata,
                            busy: busyProjects.contains(stack.id),
                            runProject: { action in run(action, on: stack) })
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.9), value: stacks.map(\.id))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Stacks")
                    .font(.title2.weight(.semibold))
                Text(summary)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 16)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var summary: String {
        let services = stacks.reduce(0) { $0 + $1.containers.count }
        let running = stacks.reduce(0) { $0 + $1.runningCount }
        let projects = stacks.count
        return "\(projects) project\(projects == 1 ? "" : "s") · \(running) of \(services) services running"
    }

    private var emptyState: some View {
        TrackDEmptyState(
            symbol: "square.stack.3d.up",
            title: "No Compose stacks",
            message:
                "Anything started with `docker compose up` against the Morbstack engine shows up "
                + "here, grouped by project. Morbstack reads the standard Compose labels, so the "
                + "regular CLI is all you need — point it at the Morbstack socket and run it."
        ) {
            VStack(spacing: 8) {
                Button {
                    trackDCopy(TrackDLinks.dockerContextCommand(socketPath: MorbPaths.dockerSocket.path))
                } label: {
                    Label("Copy docker context command", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)

                Text(TrackDLinks.dockerHostExport(socketPath: MorbPaths.dockerSocket.path))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
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
}

// MARK: - Card

private struct TrackDStackCard: View {

    let stack: ComposeGroup
    let model: AppModel
    let metadata: TrackDComposeMetadata
    let busy: Bool
    let runProject: (ContainerAction) -> Void

    @State private var hoveredService: String?

    private var project: String { stack.project ?? "" }

    private var tone: TrackDTone {
        if stack.containers.contains(where: { $0.isUnhealthy || $0.state == "dead" }) { return .bad }
        if stack.isFullyRunning { return .good }
        if stack.runningCount > 0 { return .warn }
        return .neutral
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader
            Divider().opacity(0.6)
            VStack(spacing: 0) {
                ForEach(stack.containers) { container in
                    serviceRow(container)
                    if container.id != stack.containers.last?.id {
                        Divider().opacity(0.35).padding(.leading, 26)
                    }
                }
            }
        }
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: .rect(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator.opacity(0.65), lineWidth: 0.5)
        }
        .opacity(busy ? 0.65 : 1)
        .animation(.easeOut(duration: 0.18), value: busy)
        .task(id: stack.id) {
            guard let first = stack.containers.first else { return }
            metadata.load(project: project, containerID: first.id, client: model.client)
        }
    }

    // MARK: Header

    private var cardHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            TrackDStatusDot(tone: tone, size: 9)

            VStack(alignment: .leading, spacing: 2) {
                Text(project)
                    .font(.headline)
                HStack(spacing: 6) {
                    Text(statusLine)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if let file = configFileLabel {
                        Text("·").font(.caption).foregroundStyle(.tertiary)
                        Button {
                            trackDCopy(file)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 9))
                                Text(file)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                            .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy the Compose file path\n\(file)")
                    }
                }
            }

            Spacer(minLength: 12)

            if busy {
                ProgressView().controlSize(.small)
            }

            HStack(spacing: 6) {
                Button {
                    runProject(.start)
                } label: {
                    Label("Up", systemImage: "play.fill")
                }
                .disabled(busy || stack.isFullyRunning)
                .help("Start every stopped service in \(project)")

                Button {
                    runProject(.restart)
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                .disabled(busy || stack.runningCount == 0)
                .help("Restart every service in \(project)")

                Button {
                    runProject(.stop)
                } label: {
                    Label("Down", systemImage: "stop.fill")
                }
                .disabled(busy || stack.runningCount == 0)
                .help("Stop every running service in \(project)")
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var statusLine: String {
        let total = stack.containers.count
        if stack.isFullyRunning {
            return "All \(total) service\(total == 1 ? "" : "s") running"
        }
        if stack.runningCount == 0 {
            return "Stopped · \(total) service\(total == 1 ? "" : "s")"
        }
        return "\(stack.runningCount) of \(total) services running"
    }

    /// The compose file, shortened to the last two path components — the full path is
    /// in the tooltip and on the clipboard, and `…/checkout/docker-compose.yml` is what
    /// actually tells two projects apart.
    private var configFileLabel: String? {
        guard let files = metadata.configFiles[project], let first = files.first else { return nil }
        let parts = first.split(separator: "/")
        guard parts.count > 2 else { return first }
        return "…/" + parts.suffix(2).joined(separator: "/")
    }

    // MARK: Services

    private func serviceRow(_ container: ContainerSummary) -> some View {
        let hovering = hoveredService == container.id
        let publishable = container.ports.filter { $0.hostPort != nil }

        return HStack(spacing: 9) {
            TrackDStatusDot(
                tone: .container(state: container.state, unhealthy: container.isUnhealthy),
                pulsing: container.state == "restarting")

            VStack(alignment: .leading, spacing: 1) {
                Text(container.composeService ?? container.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(container.image)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // A fixed name column rather than a flexible one. With `Spacer` between the
            // name and the ports, the chips were pinned to the right edge and a wide
            // window opened a 600pt river of nothing between a service called `redis`
            // and the one fact about it worth reading. Fixed width puts every row's
            // ports on the same left edge, close enough to the name to be read as
            // belonging to it, and the slack collects at the right where it is quiet.
            .frame(width: 260, alignment: .leading)

            HStack(spacing: 4) {
                ForEach(publishable.prefix(3)) { port in
                    portChip(port)
                }
                if publishable.count > 3 {
                    Text("+\(publishable.count - 3)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(container.status.isEmpty ? container.state : container.status)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 132, alignment: .trailing)

            HStack(spacing: 2) {
                if container.isRunning {
                    TrackDIconButton(symbol: "stop.fill", help: "Stop this service", tone: .warn) {
                        act(.stop, container)
                    }
                    TrackDIconButton(symbol: "arrow.clockwise", help: "Restart this service", tone: .accent) {
                        act(.restart, container)
                    }
                } else {
                    TrackDIconButton(symbol: "play.fill", help: "Start this service", tone: .good) {
                        act(.start, container)
                    }
                }
            }
            .opacity(hovering ? 1 : 0.32)
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(.rect)
        .background(hovering ? Color.primary.opacity(0.035) : .clear)
        .onHover { inside in
            if inside { hoveredService = container.id } else if hovering { hoveredService = nil }
        }
        .onTapGesture(count: 2) {
            TrackDAppBridge.reveal(containerID: container.id, in: model)
        }
        .contextMenu {
            Button("Open in Containers") {
                TrackDAppBridge.reveal(containerID: container.id, in: model)
            }
            Button("View logs") {
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

    private func portChip(_ port: PortMapping) -> some View {
        Button {
            if let url = port.url { trackDOpen(url) }
        } label: {
            Text(port.label)
                .font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Theme.accent.opacity(0.14), in: .capsule)
                .foregroundStyle(port.url == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.accent))
        }
        .buttonStyle(.plain)
        .disabled(port.url == nil)
        .help(port.url.map { "Open \($0.absoluteString)" } ?? "Published on \(port.proto.uppercased())")
    }

    private func act(_ action: ContainerAction, _ container: ContainerSummary) {
        Task { @MainActor in
            await model.containerAction(action, id: container.id)
        }
    }
}
