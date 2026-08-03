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

// MARK: - Focus

/// Keyboard stops in the popover, in visual order. The system still draws the focus
/// treatment; this enum only lets Up/Down move through a mixed group of controls.
enum TrackDMenuFocus: Hashable {
    case engine(String)
    case container(String)
    case port(String)
    case openApp
    case prune
    case settings
    case quit
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
    @FocusState private var focus: TrackDMenuFocus?

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
        .focusable()
        .onKeyPress(.downArrow) { moveFocus(by: 1); return .handled }
        .onKeyPress(.upArrow) { moveFocus(by: -1); return .handled }
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
        .focused($focus, equals: .engine(action.rawValue))
        .disabled(busy.contains("engine"))
        .help(engineTitle(action))
        .accessibilityLabel(engineTitle(action))
    }

    private func engineTitle(_ action: EngineAction) -> String {
        switch action {
        case .start: return "Start engine"
        case .stop: return "Stop engine"
        case .suspend: return "Suspend engine"
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

    private var running: [ContainerSummary] {
        model.containers
            .filter(\.isRunning)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var runningIDs: [String] { running.prefix(Self.containerLimit).map(\.id) }

    private var containersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Running")
                .font(.headline)

            if running.isEmpty {
                Text(model.engine.isRunning ? "No containers are running." : "Start the engine to see containers.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(running.prefix(Self.containerLimit)) { container in
                    containerRow(container)
                }
                if running.count > Self.containerLimit {
                    Button("\(running.count - Self.containerLimit) more in Morbstack…") {
                        TrackDAppBridge.reveal(.containers, in: model)
                    }
                    .buttonStyle(.link)
                    .focused($focus, equals: .openApp)
                }
            }
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
            .focused($focus, equals: .container(container.id))
            .help(rowTooltip(container))
            .accessibilityLabel("Open \(container.displayName), \(container.status), CPU \(cpuText(container))")

            Menu {
                Button("Stop \(container.displayName)", systemImage: "stop.fill") {
                    run(container: .stop, id: container.id)
                }
            } label: {
                Label("Actions for \(container.displayName)", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .disabled(busy.contains(container.id))
        }
        .opacity(busy.contains(container.id) ? 0.5 : 1)
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
        let byRecency = running.sorted { $0.createdAt > $1.createdAt }
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
                .focused($focus, equals: .port(port.id))
                .help("Open http://127.0.0.1:\(port.hostPort) — container port \(port.containerPort)")
                .accessibilityLabel("Open port \(port.hostPort) for \(port.owner)")
            }

            if allPorts.count > ports.count {
                Button("\(allPorts.count - ports.count) more in Morbstack…") {
                    TrackDAppBridge.reveal(.containers, in: model)
                }
                .buttonStyle(.link)
                .focused($focus, equals: .openApp)
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
            .focused($focus, equals: .openApp)
            .keyboardShortcut("o", modifiers: .command)

            Button("Review Disk Cleanup…", systemImage: "trash") {
                TrackDAppBridge.reveal(.disk, in: model)
            }
            .buttonStyle(.plain)
            .focused($focus, equals: .prune)
            .help("Review reclaimable disk in the main window")

            Button("Settings…", systemImage: "gearshape") {
                NSApp.activate()
                openSettings()
            }
            .buttonStyle(.plain)
            .focused($focus, equals: .settings)

            Button("Quit Morbstack", systemImage: "power") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .focused($focus, equals: .quit)
        }
    }

    // MARK: Keyboard

    private var focusOrder: [TrackDMenuFocus] {
        var order: [TrackDMenuFocus] = engineActions.map { TrackDMenuFocus.engine($0.rawValue) }
        order += running.prefix(Self.containerLimit).map { TrackDMenuFocus.container($0.id) }
        order += ports.map { TrackDMenuFocus.port($0.id) }
        order += [.openApp, .prune, .settings, .quit]
        return order
    }

    private func moveFocus(by delta: Int) {
        let order = focusOrder
        guard !order.isEmpty else { return }
        guard let current = focus, let index = order.firstIndex(of: current) else {
            focus = delta > 0 ? order.first : order.last
            return
        }
        focus = order[(index + delta + order.count) % order.count]
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
