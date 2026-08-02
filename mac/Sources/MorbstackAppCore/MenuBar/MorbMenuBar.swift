// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The menu bar extra: the part of Morbstack that is always on screen.
//
// Design brief for this surface, since it is easy to get wrong: it is a *status*
// object first and a launcher second. It shows the engine, the handful of containers
// that are actually running, and the ports you can click — and then gets out of the
// way. Everything destructive or open-ended lives in the main window; this popover
// only ever navigates to it.
//
// Track A wires `MorbMenuBarLabel(model:)` and `MorbMenuBarContent(model:)` into a
// `MenuBarExtra` with `.menuBarExtraStyle(.window)`.

import AppKit
import Observation
import SwiftUI

// MARK: - Label

/// The status-item glyph: a small crate with a state dot.
///
/// Redrawn whenever the engine state or the system appearance changes — the glyph body
/// is stroked in `labelColor`, so it has to be regenerated when the menu bar flips
/// between light and dark, and `colorScheme` is what tells SwiftUI to do that.
struct MorbMenuBarLabel: View {
    let model: AppModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: MorbMenuBarGlyph.image(for: model.engine, scheme: colorScheme))
            .accessibilityLabel("Morbstack — \(model.engine.headline)")
            .help("Morbstack — \(model.engine.headline)")
    }
}

/// Draws the status-item image.
///
/// Hand-drawn rather than an SF Symbol: at 16pt the stock box symbols are noticeably
/// heavier than the rest of the menu bar, and none of them leave a clean corner for the
/// state dot. The body is stroked in `NSColor.labelColor` so it inverts with the menu
/// bar the way a template image would, while the dot keeps its colour.
enum MorbMenuBarGlyph {

    static func image(for status: EngineStatus, scheme: ColorScheme) -> NSImage {
        let tone = TrackDTone.engine(status)
        let dotColor = nsColor(for: tone)
        let size = NSSize(width: 18, height: 16)

        let image = NSImage(size: size, flipped: false) { _ in
            let ink = NSColor.labelColor

            // Crate body.
            let body = NSRect(x: 1.6, y: 2.6, width: 11.6, height: 11.0)
            let outline = NSBezierPath(roundedRect: body, xRadius: 2.6, yRadius: 2.6)
            outline.lineWidth = 1.4
            ink.setStroke()
            outline.stroke()

            // Lid seam plus the little centre tab: two strokes are all it takes for the
            // shape to read as a box rather than as an empty rounded square.
            let seamY = body.maxY - 3.3
            let seam = NSBezierPath()
            seam.move(to: NSPoint(x: body.minX + 0.7, y: seamY))
            seam.line(to: NSPoint(x: body.maxX - 0.7, y: seamY))
            seam.lineWidth = 1.3
            ink.withAlphaComponent(0.85).setStroke()
            seam.stroke()

            let tab = NSBezierPath()
            tab.move(to: NSPoint(x: body.midX, y: seamY))
            tab.line(to: NSPoint(x: body.midX, y: seamY - 2.4))
            tab.lineWidth = 1.3
            ink.withAlphaComponent(0.55).setStroke()
            tab.stroke()

            // State dot, punched out of the body so it never touches the stroke.
            let dotCentre = NSPoint(x: 14.0, y: 3.9)
            if let context = NSGraphicsContext.current {
                context.saveGraphicsState()
                context.compositingOperation = .clear
                NSBezierPath(ovalIn: circle(at: dotCentre, radius: 3.5)).fill()
                context.restoreGraphicsState()
            }
            dotColor.setFill()
            NSBezierPath(ovalIn: circle(at: dotCentre, radius: 2.4)).fill()

            return true
        }
        // The dot carries colour, so this cannot be a template image; the body is drawn
        // in a dynamic colour instead, which gets us the same light/dark behaviour.
        image.isTemplate = false
        image.accessibilityDescription = "Morbstack"
        return image
    }

    private static func circle(at centre: NSPoint, radius: CGFloat) -> NSRect {
        NSRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
    }

    /// The dot colour.
    ///
    /// The same `Theme` pairs the sidebar's engine pill uses, so the two dots on screen
    /// at once are the same green — and slightly softened, because a saturated traffic
    /// light in the menu bar is louder than a background utility has any right to be.
    private static func nsColor(for tone: TrackDTone) -> NSColor {
        if tone == .neutral { return NSColor.tertiaryLabelColor }
        return NSColor(tone.color).withAlphaComponent(0.95)
    }
}

// MARK: - Focus

/// Every keyboard stop in the popover, in visual order.
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

/// Streams `/stats` for the containers the popover is currently showing.
///
/// Scoped to the popover's lifetime on purpose: each stream is a held-open connection
/// to the engine, and eight of them running behind a closed popover would be a
/// background cost nobody asked for.
@MainActor
@Observable
final class TrackDMenuBarStats {

    private(set) var cpu: [String: Double] = [:]

    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    /// Starts streams for `ids`, cancelling any that are no longer wanted.
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
                    // A container that exits mid-stream is the common case here, and the
                    // list is about to drop the row anyway. Nothing to report.
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

/// The menu bar popover.
struct MorbMenuBarContent: View {

    let model: AppModel

    /// How many running containers the popover will list before it gives up and points
    /// at the main window. Eight is roughly one screenful of stack.
    private static let containerLimit = 8
    /// Published ports are the same story, and duplicate more heavily.
    private static let portLimit = 6

    @State private var stats = TrackDMenuBarStats()
    @State private var hoveredRow: String?
    @State private var busy: Set<String> = []
    @FocusState private var focus: TrackDMenuFocus?

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            engineHeader
            Divider().padding(.vertical, 6)
            containersSection
            if !ports.isEmpty {
                Divider().padding(.vertical, 6)
                portsSection
            }
            Divider().padding(.vertical, 6)
            footer
        }
        .padding(10)
        .frame(width: 300)
        .buttonStyle(TrackDRowButtonStyle())
        // Focusable, but with no default focus: the popover opens with nothing
        // selected, so a stray Return cannot suspend the engine. The first arrow key
        // is what starts the walk (see `moveFocus`).
        .focusable()
        .focusEffectDisabled()
        .task {
            // The popover is the one place a stale list is immediately obvious, so pay
            // for one refresh on open rather than trusting whatever the last poll saw.
            await model.refreshAll()
        }
        .task(id: runningIDs) {
            stats.sync(ids: runningIDs, client: model.client)
        }
        .onDisappear { stats.stopAll() }
        .onKeyPress(.downArrow) { moveFocus(by: 1); return .handled }
        .onKeyPress(.upArrow) { moveFocus(by: -1); return .handled }
    }

    // MARK: Engine

    private var engineHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            TrackDStatusDot(
                tone: .engine(model.engine),
                size: 8,
                pulsing: model.engine.isTransitional)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.engine.headline)
                    .font(.callout.weight(.semibold))
                Text(engineSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            HStack(spacing: 4) {
                if model.engine.isTransitional {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 2)
                }
                ForEach(engineActions, id: \.self) { action in
                    engineButton(action)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: model.engine)
    }

    private var engineSubtitle: String {
        let version = model.engine.version.map { "v\($0)" } ?? "version unknown"
        return "\(version) · VM \(model.engine.vmState)"
    }

    /// Which engine buttons make sense right now.
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
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.borderless)
        .focusable()
        .focused($focus, equals: .engine(action.rawValue))
        .disabled(busy.contains("engine"))
        .help(engineTitle(action))
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
        VStack(alignment: .leading, spacing: 2) {
            TrackDSectionHeader(
                title: "Running",
                trailing: running.isEmpty ? nil : "\(running.count)")
                .padding(.horizontal, 4)
                .padding(.bottom, 2)

            if running.isEmpty {
                Text(model.engine.isRunning ? "No containers running." : "Start the engine to see containers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            } else {
                ForEach(running.prefix(Self.containerLimit)) { container in
                    containerRow(container)
                }
                if running.count > Self.containerLimit {
                    Button {
                        TrackDAppBridge.reveal(.containers, in: model)
                    } label: {
                        Text("\(running.count - Self.containerLimit) more…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .focusable()
                    .focused($focus, equals: .openApp)
                }
            }
        }
    }

    private func containerRow(_ container: ContainerSummary) -> some View {
        let showAction = hoveredRow == container.id || focus == .container(container.id)
        return Button {
            TrackDAppBridge.reveal(containerID: container.id, in: model)
        } label: {
            HStack(spacing: 7) {
                TrackDStatusDot(tone: .container(state: container.state, unhealthy: container.isUnhealthy))
                VStack(alignment: .leading, spacing: 0) {
                    Text(container.displayName)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let service = container.composeService, let project = container.composeProject {
                        // 10pt secondary, not 9pt tertiary. A popover is read at arm's
                        // length off a menu bar; nine points of tertiary grey is a
                        // texture, not a word.
                        Text("\(project) · \(service)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                // `.secondary`, not `.tertiary`. This is the only number in the popover
                // and the reason half the people who open it opened it; at tertiary on a
                // vibrant background it sat around 2.5:1 and read as disabled.
                Text(cpuText(container))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .opacity(showAction ? 0 : 1)
                    .frame(minWidth: 34, alignment: .trailing)
            }
        }
        .focusable()
        .focused($focus, equals: .container(container.id))
        .overlay(alignment: .trailing) {
            if showAction {
                TrackDIconButton(symbol: "stop.fill", help: "Stop \(container.displayName)", tone: .bad) {
                    run(container: .stop, id: container.id)
                }
                .padding(.trailing, 6)
                .transition(.opacity)
            }
        }
        .opacity(busy.contains(container.id) ? 0.5 : 1)
        .onHover { inside in
            if inside { hoveredRow = container.id } else if hoveredRow == container.id { hoveredRow = nil }
        }
        .animation(.easeOut(duration: 0.12), value: showAction)
        .help(container.status)
    }

    private func cpuText(_ container: ContainerSummary) -> String {
        guard let value = stats.cpu[container.id] else { return "—" }
        return Formatters.percent(value)
    }

    // MARK: Ports

    /// One clickable published port.
    private struct PortEntry: Identifiable {
        let id: String
        let url: URL
        let hostPort: Int
        let containerPort: Int
        let owner: String
        let created: Date
    }

    /// Published, browser-openable ports across the running containers.
    ///
    /// Newest container first — the port you just published is the one you want to
    /// click — and deduplicated by host port, since two containers cannot both own one
    /// and a stale list showing both would be a lie.
    /// Every distinct published port, newest container first.
    private var allPorts: [PortEntry] {
        var seen = Set<Int>()
        var out: [PortEntry] = []
        let byRecency = running.sorted { $0.createdAt > $1.createdAt }
        for container in byRecency {
            for mapping in container.ports {
                guard let hostPort = mapping.hostPort, let url = mapping.url else { continue }
                guard seen.insert(hostPort).inserted else { continue }
                out.append(
                    PortEntry(
                        id: "\(container.id):\(hostPort)",
                        url: url,
                        hostPort: hostPort,
                        containerPort: mapping.containerPort,
                        owner: container.displayName,
                        created: container.createdAt))
            }
        }
        return out
    }

    private var ports: [PortEntry] { Array(allPorts.prefix(Self.portLimit)) }

    private var portsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            TrackDSectionHeader(title: "Published ports")
                .padding(.horizontal, 4)
                .padding(.bottom, 2)

            ForEach(ports) { port in
                Button {
                    trackDOpen(port.url)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(width: 9)
                        // The address is the link; the container is the label for it.
                        // Bold monospaced address against tertiary owner had the
                        // hierarchy the wrong way round — the port number shouted louder
                        // than the container names in the list above it.
                        Text("127.0.0.1:\(String(port.hostPort))")
                            .font(.system(size: 12, design: .monospaced))
                            .monospacedDigit()
                        Spacer(minLength: 6)
                        Text(port.owner)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 120, alignment: .trailing)
                    }
                }
                .focusable()
                .focused($focus, equals: .port(port.id))
                .help("Open http://127.0.0.1:\(port.hostPort) — container port \(port.containerPort)")
            }

            // A list that stops at six without saying so is a list that lies. The count
            // is the whole point: "six ports" and "six of eleven ports" are different
            // facts about your machine, and only one of them was on screen.
            if allPorts.count > ports.count {
                Text("+\(allPorts.count - ports.count) more in the main window")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                TrackDAppBridge.revealMainWindow()
            } label: {
                footerLabel("Open Morbstack", symbol: "macwindow", shortcut: "⌘O")
            }
            .focusable()
            .focused($focus, equals: .openApp)
            .keyboardShortcut("o", modifiers: .command)

            Button {
                TrackDAppBridge.reveal(.disk, in: model)
            } label: {
                footerLabel("Prune…", symbol: "trash", shortcut: nil)
            }
            .focusable()
            .focused($focus, equals: .prune)
            .help("Review reclaimable disk in the main window")

            Button {
                NSApp.activate()
                openSettings()
            } label: {
                footerLabel("Settings…", symbol: "gearshape", shortcut: "⌘,")
            }
            .focusable()
            .focused($focus, equals: .settings)

            Button {
                NSApp.terminate(nil)
            } label: {
                footerLabel("Quit Morbstack", symbol: "power", shortcut: "⌘Q")
            }
            .focusable()
            .focused($focus, equals: .quit)
        }
    }

    /// The shortcut text on the Settings and Quit rows is a *hint*, not a binding: the
    /// app's own main menu already owns ⌘, and ⌘Q, and claiming them a second time from
    /// inside the popover gets one of the two handlers dropped at random.
    private func footerLabel(_ title: String, symbol: String, shortcut: String?) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(title)
                .font(.callout)
            Spacer(minLength: 6)
            if let shortcut {
                Text(shortcut)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Keyboard

    /// Every focusable stop, in the order they appear on screen.
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
        let next = (index + delta + order.count) % order.count
        focus = order[next]
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
