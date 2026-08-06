// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The menu-bar extra: the part of Morbstack that is always on screen.
//
// A menu-bar extra is a status object first and a launcher second. It shows the engine,
// a bounded amount of live context, and paths out to the document window. The
// MenuBarExtra window owns its material and dismissal behavior; this file intentionally
// contains no panel material, fake menu-row selection, hover chrome, or hand-drawn
// status glyphs.

import AppKit
import Observation
import SwiftUI

// MARK: - Label

/// A monochrome template symbol for the status bar. State is described in the popover
/// and accessibility label rather than competing with other system status-item colours.
struct MorbMenuBarLabel: View {
    let model: AppModel

    var body: some View {
        Image(systemName: "shippingbox")
            .symbolRenderingMode(.hierarchical)
            .accessibilityLabel("Morbstack — \(model.engine.headline)")
            .help("Morbstack — \(model.engine.headline)")
    }
}

// MARK: - Live CPU

/// Streams `/stats` for the containers visible while the extra is open.
///
/// The work is scoped to the extra's lifetime. A closed status item must not leave a
/// background stream running merely to paint data nobody can see.
@MainActor
@Observable
final class TrackDMenuBarStats {

    private(set) var cpu: [String: Double] = [:]

    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    func sync(ids: [String], client: DockerClient) {
        let wanted = Set(ids)
        for (id, task) in tasks where !wanted.contains(id) {
            task.cancel()
            tasks[id] = nil
            cpu[id] = nil
        }
        for id in ids where tasks[id] == nil {
            tasks[id] = Task { [weak self] in
                do {
                    for try await sample in client.stats(id: id) {
                        if Task.isCancelled { return }
                        self?.cpu[id] = sample.cpuPercent
                    }
                } catch {
                    // An exiting container is normal; the next model refresh removes it.
                }
            }
        }
    }

    func stopAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        cpu.removeAll()
    }
}

// MARK: - The running list

/// The bounded, grouped "Running" list the extra shows.
///
/// Eight rows drawn alphabetically from three Compose projects read as eight unrelated
/// processes. Grouping is the whole change: the same records, in the relationship that
/// explains them, using the grouping the Containers route already established
/// (`TrackBContainerGrouping`) rather than a second idiom invented here.
///
/// Pure and `Equatable` so the truncation arithmetic — which decides both what is drawn
/// and which stats streams are opened — is testable without a window.
struct TrackDMenuBarList: Equatable {

    /// Which screen owns a group's records. The header points at it, so the symbol and
    /// the destination are one decision rather than two that can disagree.
    enum GroupKind: Equatable {
        case project(String)
        case standalone
        case kubernetes

        var destination: Nav {
            switch self {
            case .project: return .stacks
            case .standalone: return .containers
            case .kubernetes: return .kubernetes
            }
        }
    }

    struct Group: Identifiable, Equatable {
        let kind: GroupKind
        let title: String
        /// Running members, already truncated to what fits in the extra.
        let containers: [ContainerSummary]
        /// Running members before truncation.
        let runningCount: Int
        /// Every member, running or not — the denominator that makes a partly-up
        /// project visible without listing its stopped services.
        let memberCount: Int

        var id: String {
            switch kind {
            case .project(let name): return "project:\(name)"
            case .standalone: return "standalone"
            case .kubernetes: return "kubernetes"
            }
        }

        var symbol: String { kind.destination.symbol }

        var subtitle: String { "\(runningCount) of \(memberCount) running" }
    }

    var groups: [Group] = []
    /// Running containers that did not fit inside the row budget.
    var hiddenCount: Int = 0

    var isEmpty: Bool { groups.isEmpty }

    /// Exactly the rows on screen. The stats streams follow this, so the extra never
    /// opens a socket to paint a container it decided not to draw.
    var visibleIDs: [String] { groups.flatMap { $0.containers.map(\.id) } }

    /// One group needs no header: the section is already titled "Running", and a lone
    /// "Standalone — 3 of 3 running" line above three rows is a label for nothing.
    var showsGroupHeaders: Bool { groups.count > 1 }

    static func build(_ containers: [ContainerSummary], limit: Int) -> TrackDMenuBarList {
        let grouped = TrackBContainerGrouping.groups(of: containers)

        // Projects first and alphabetically (`TrackBContainerGrouping` already sorts
        // them), then the two buckets that are not projects. Keeping the unnamed
        // buckets last holds their position steady as projects come and go.
        var candidates: [(kind: GroupKind, title: String, members: [ContainerSummary])] =
            grouped.projects.map { (.project($0.name), $0.name, $0.containers) }
        if !grouped.standalone.isEmpty {
            candidates.append((.standalone, "Standalone", grouped.standalone))
        }
        if !grouped.kubernetes.isEmpty {
            candidates.append((.kubernetes, "Kubernetes-Managed", grouped.kubernetes))
        }

        var list = TrackDMenuBarList()
        var budget = max(0, limit)
        for candidate in candidates {
            let running = candidate.members
                .filter(\.isRunning)
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            guard !running.isEmpty else { continue }

            let shown = Array(running.prefix(budget))
            budget -= shown.count
            list.hiddenCount += running.count - shown.count
            guard !shown.isEmpty else { continue }

            list.groups.append(
                Group(
                    kind: candidate.kind,
                    title: candidate.title,
                    containers: shown,
                    runningCount: running.count,
                    memberCount: candidate.members.count))
        }
        return list
    }
}

// MARK: - Content

/// A compact, system-control-only status popover.
struct MorbMenuBarContent: View {

    let model: AppModel

    /// A menu-bar extra is deliberately a glanceable surface, not a second resource
    /// browser. More entries always lead to the main window.
    private static let containerLimit = 8
    private static let portLimit = 6

    @State private var stats = TrackDMenuBarStats()
    @State private var busy: Set<String> = []

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            engineHeader
            Divider()
            containersSection
            if !ports.isEmpty {
                Divider()
                portsSection
            }
            Divider()
            footer
        }
        .padding()
        .frame(width: 320)
        .task {
            // The status extra is uniquely sensitive to stale state: refresh once on
            // open, then retain the ordinary model polling cadence.
            await model.refreshAll()
        }
        .task(id: runningIDs) {
            stats.sync(ids: runningIDs, client: model.client)
        }
        .onDisappear { stats.stopAll() }
    }

    // MARK: Engine

    private var engineHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.engine.headline)
                        .font(.headline)
                    Text(engineSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: engineStatusSymbol)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
            }
            .accessibilityLabel("Engine: \(model.engine.headline). \(engineSubtitle)")

            Spacer()

            if model.engine.isTransitional {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Engine state is changing")
            }

            ControlGroup {
                ForEach(engineActions, id: \.self) { action in
                    engineButton(action)
                }
            }
        }
    }

    private var engineSubtitle: String {
        let version = model.engine.version.map { "v\($0)" } ?? "version unknown"
        return "\(version) · VM \(model.engine.vmState)"
    }

    private var engineStatusSymbol: String {
        OperationalState.engine(model.engine).symbol
    }

    private var engineActions: [EngineAction] {
        guard model.engine.reachable else { return [.start] }
        switch model.engine.state {
        case "running": return [.suspend, .stop]
        case "suspended": return [.start, .stop]
        case "starting", "stopping", "pausing": return []
        default: return [.start]
        }
    }

    private func engineButton(_ action: EngineAction) -> some View {
        Button {
            run(engine: action)
        } label: {
            Label(engineTitle(action), systemImage: engineSymbol(action))
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .disabled(busy.contains("engine"))
        .help(engineTitle(action))
        .accessibilityLabel(engineTitle(action))
        // Symbol-only, and three of them side by side: exactly the case
        // ACCESSIBILITY-IDENTIFIERS §3 makes mandatory rather than optional.
        .accessibilityIdentifier("app.menuBar.engine.\(action.rawValue)")
    }

    private func engineTitle(_ action: EngineAction) -> String {
        switch action {
        case .start: return "Start engine"
        case .stop: return "Stop engine"
        case .suspend: return "Free engine memory"
        }
    }

    private func engineSymbol(_ action: EngineAction) -> String {
        switch action {
        case .start: return "play.fill"
        case .stop: return "stop.fill"
        case .suspend: return "moon.zzz.fill"
        }
    }

    // MARK: Containers

    private var running: TrackDMenuBarList {
        TrackDMenuBarList.build(model.containers, limit: Self.containerLimit)
    }

    private var runningIDs: [String] { running.visibleIDs }

    private var containersSection: some View {
        let list = running
        return VStack(alignment: .leading, spacing: 6) {
            Text("Running")
                .font(.headline)

            if list.isEmpty {
                Text(model.engine.isRunning ? "No containers are running." : "Start the engine to see containers.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(list.groups) { group in
                    if list.showsGroupHeaders {
                        groupHeader(group)
                    }
                    ForEach(group.containers) { container in
                        containerRow(container)
                            .padding(.leading, list.showsGroupHeaders ? 10 : 0)
                    }
                }
                if list.hiddenCount > 0 {
                    Button("\(list.hiddenCount) more in Morbstack…") {
                        TrackDAppBridge.reveal(.containers, in: model)
                    }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("app.menuBar.moreContainers")
                }
            }
        }
    }

    /// A group header is a way in, not a section rule: it names the project and hands
    /// the person to the screen that owns those records — Stacks for a Compose project,
    /// where its lifecycle actions live with the confirmation that explains their scope.
    private func groupHeader(_ group: TrackDMenuBarList.Group) -> some View {
        Button {
            switch group.kind {
            case .project(let name): TrackDAppBridge.reveal(composeProject: name, in: model)
            case .standalone, .kubernetes: TrackDAppBridge.reveal(group.kind.destination, in: model)
            }
        } label: {
            HStack(spacing: 6) {
                Label(group.title, systemImage: group.symbol)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(group.subtitle)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help(groupTooltip(group))
        .accessibilityLabel("\(group.title), \(group.subtitle)")
        .accessibilityHint(groupTooltip(group))
        .accessibilityIdentifier("app.menuBar.group.\(group.id)")
    }

    private func groupTooltip(_ group: TrackDMenuBarList.Group) -> String {
        switch group.kind {
        case .project: return "Open this Compose project on the Stacks screen"
        case .standalone: return "Open Containers in the Morbstack main window"
        case .kubernetes: return "Open Kubernetes in the Morbstack main window"
        }
    }

    private func containerRow(_ container: ContainerSummary) -> some View {
        HStack(spacing: 6) {
            Button {
                TrackDAppBridge.reveal(containerID: container.id, in: model)
            } label: {
                Label {
                    HStack {
                        Text(container.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(cpuText(container))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: containerStatusSymbol(container))
                        .symbolRenderingMode(.hierarchical)
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)
            .help(rowTooltip(container))
            .accessibilityLabel("Open \(container.displayName), \(container.status), CPU \(cpuText(container))")
            .accessibilityIdentifier("app.menuBar.row.\(container.displayName)")

            // The menu is titled by the container, so its items are plain verbs. Its
            // contents are the three things worth doing without opening the app: read
            // the output, put the process back on its feet or stop it, and get its
            // name or id into a terminal. Anything that needs a confirmation, a sheet,
            // or a second screen belongs on the screen that already has one.
            Menu {
                Button("View Logs", systemImage: "text.alignleft") {
                    TrackDAppBridge.reveal(containerID: container.id, in: model, showingLogs: true)
                }
                .accessibilityIdentifier("app.menuBar.viewLogs.\(container.displayName)")

                Divider()

                Button(ContainerAction.restart.title, systemImage: ContainerAction.restart.symbol) {
                    run(container: .restart, id: container.id)
                }
                .accessibilityIdentifier("app.menuBar.restart.\(container.displayName)")

                Button(ContainerAction.stop.title, systemImage: ContainerAction.stop.symbol) {
                    run(container: .stop, id: container.id)
                }
                .accessibilityIdentifier("app.menuBar.stop.\(container.displayName)")

                Divider()

                // The same two titles the Containers context menu uses, copying the
                // same two values — the full id, because that is what `docker` takes.
                Button("Copy Name", systemImage: "doc.on.doc") {
                    MorbPasteboard.copy(container.displayName)
                }
                .accessibilityIdentifier("app.menuBar.copyName.\(container.displayName)")

                Button("Copy Container ID", systemImage: "doc.on.doc") {
                    MorbPasteboard.copy(container.id)
                }
                .accessibilityIdentifier("app.menuBar.copyID.\(container.displayName)")
            } label: {
                Label("Actions for \(container.displayName)", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .disabled(busy.contains(container.id))
            .help("Actions for \(container.displayName)")
            .accessibilityLabel("Actions for \(container.displayName)")
            .accessibilityIdentifier("app.menuBar.actions.\(container.displayName)")
        }
    }

    private func containerStatusSymbol(_ container: ContainerSummary) -> String {
        OperationalState.container(state: container.state, unhealthy: container.isUnhealthy).symbol
    }

    private func rowTooltip(_ container: ContainerSummary) -> String {
        if let service = container.composeService, let project = container.composeProject {
            return "\(project) · \(service) — \(container.status)"
        }
        return container.status
    }

    private func cpuText(_ container: ContainerSummary) -> String {
        guard let value = stats.cpu[container.id] else { return "—" }
        return Formatters.percent(value)
    }

    // MARK: Ports

    private struct PortEntry: Identifiable {
        let id: String
        let url: URL
        let hostPort: Int
        let containerPort: Int
        let owner: String
    }

    private var allPorts: [PortEntry] {
        var seen = Set<Int>()
        var out: [PortEntry] = []
        // Every running container, not only the ones the row budget left room for: a
        // published port is worth reaching even when its container is below the fold.
        let byRecency = model.containers.filter(\.isRunning).sorted { $0.createdAt > $1.createdAt }
        for container in byRecency {
            for mapping in container.ports {
                guard let hostPort = mapping.hostPort, let url = mapping.url else { continue }
                guard seen.insert(hostPort).inserted else { continue }
                out.append(PortEntry(
                    id: "\(container.id):\(hostPort)",
                    url: url,
                    hostPort: hostPort,
                    containerPort: mapping.containerPort,
                    owner: container.displayName))
            }
        }
        return out
    }

    private var ports: [PortEntry] { Array(allPorts.prefix(Self.portLimit)) }

    private var portsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Published Ports")
                .font(.headline)

            ForEach(ports) { port in
                Link(destination: port.url) {
                    Label {
                        HStack {
                            Text("127.0.0.1:\(String(port.hostPort))")
                                .font(.body.monospacedDigit())
                            Spacer()
                            Text(port.owner)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } icon: {
                        Image(systemName: "arrow.up.forward.app")
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
                // Interpolating an `Int` into these literals selects the
                // `LocalizedStringKey` overload, which groups digits — and a port is
                // an identifier, so the tooltip would read "18,099" and VoiceOver
                // would speak "eighteen thousand ninety-nine".
                .help("Open http://127.0.0.1:\(Formatters.identifier(port.hostPort)) — container port \(Formatters.identifier(port.containerPort))")
                .accessibilityLabel("Open port \(Formatters.identifier(port.hostPort)) for \(port.owner)")
                .accessibilityIdentifier("app.menuBar.port.\(Formatters.identifier(port.hostPort))")
            }

            if allPorts.count > ports.count {
                Button("\(allPorts.count - ports.count) more in Morbstack…") {
                    TrackDAppBridge.reveal(.containers, in: model)
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("app.menuBar.morePorts")
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Open Morbstack", systemImage: "macwindow") {
                TrackDAppBridge.revealMainWindow()
            }
            .buttonStyle(.plain)
            // No keyboard shortcut here: ⌘O is File > Open at app scope, and this footer
            // row shadowing it would silently steal the shortcut from the real command.
            .help("Open the Morbstack main window")
            .accessibilityHint("Opens the main Morbstack window")
            .accessibilityIdentifier("app.menuBar.openMainWindow")

            // No ellipsis: this navigates straight to the Disk screen, it does not open a
            // dialog.
            Button("Review Disk Cleanup", systemImage: "trash") {
                TrackDAppBridge.reveal(.disk, in: model)
            }
            .buttonStyle(.plain)
            .help("Review reclaimable disk in the main window")
            .accessibilityHint("Opens Disk in the Morbstack main window")
            .accessibilityIdentifier("app.menuBar.reviewDisk")

            Button("Settings…", systemImage: "gearshape") {
                NSApp.activate()
                openSettings()
            }
            .buttonStyle(.plain)
            .help("Open Morbstack settings")
            .accessibilityHint("Opens Morbstack settings")
            .accessibilityIdentifier("app.menuBar.settings")

            Button("Quit Morbstack", systemImage: "power") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .help("Quit Morbstack")
            .accessibilityHint("Quits Morbstack")
            .accessibilityIdentifier("app.menuBar.quit")
        }
    }

    // MARK: Actions

    private func run(engine action: EngineAction) {
        busy.insert("engine")
        Task {
            await model.engineAction(action)
            busy.remove("engine")
        }
    }

    private func run(container action: ContainerAction, id: String) {
        busy.insert(id)
        Task {
            await model.containerAction(action, id: id)
            busy.remove(id)
        }
    }
}
