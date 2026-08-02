// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// One container in the list, and the compose project header above a group of them.

import AppKit
import SwiftUI

// MARK: - Row

struct ContainerListRow: View {

    let container: ContainerSummary
    let hub: TrackBStatsHub
    let client: DockerClient
    let isBusy: Bool
    let onAction: (ContainerAction) -> Void
    let onRequestRemove: () -> Void

    @State private var hovering = false
    @State private var probe: TrackBStatsProbe?

    /// This row's probe, or the last one the hub kept for this container.
    ///
    /// Scrolling a row back into view then shows its previous numbers immediately rather
    /// than blanking for the two seconds until the next sample. It is also what lets the
    /// row render its metrics offscreen — in a preview or in the screenshot harness,
    /// `onAppear` never fires, so `probe` stays `nil` and the hub is the only source.
    private var activeProbe: TrackBStatsProbe? { probe ?? hub.existingProbe(container.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            TrackBStatusDot(state: container.state, unhealthy: container.isUnhealthy)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 3) {
                titleLine
                subtitleLine
                if !container.ports.isEmpty { portLine }
            }

            Spacer(minLength: 8)

            trailing
        }
        .padding(.vertical, 7)
        .padding(.trailing, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { contextMenu }
        .help(container.status.isEmpty ? container.state : container.status)
        .onAppear(perform: subscribe)
        .onDisappear(perform: unsubscribe)
        .onChange(of: container.isRunning) { _, _ in
            unsubscribe()
            subscribe()
        }
    }

    // MARK: Lines

    private var titleLine: some View {
        HStack(spacing: 5) {
            Text(container.displayName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            if let service = container.composeService, service != container.displayName {
                // Neutral, not accent. The accent means "this is a thing you can click"
                // — the port chip one line below opens a browser. A service name is a
                // label, and when eleven rows each carry a tinted label the accent stops
                // meaning anything and simply becomes the loudest colour on the screen,
                // ahead of the status dots that are the reason to look at the list.
                TrackBBadge(text: service, tone: .neutral)
            }
            if container.isUnhealthy {
                TrackBBadge(text: "unhealthy", tone: .danger, symbol: "heart.slash")
            }
            if container.state == "paused" {
                TrackBBadge(text: "paused", tone: .warning, symbol: "pause.fill")
            }
        }
    }

    private var subtitleLine: some View {
        HStack(spacing: 6) {
            Text(container.image)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if container.isRunning, let sample = activeProbe?.latest {
                Text(verbatim: "·").font(.caption).foregroundStyle(.quaternary)
                metrics(sample)
            } else if !container.isRunning {
                Text(verbatim: "·").font(.caption).foregroundStyle(.quaternary)
                Text(shortStatus)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    /// The live microtext. Monospaced digits so the row does not shimmy sideways twice
    /// a second as the numbers change width.
    private func metrics(_ sample: StatsSample) -> some View {
        HStack(spacing: 8) {
            Label {
                Text(Formatters.percent(sample.cpuPercent))
            } icon: {
                Image(systemName: "cpu")
            }
            Label {
                Text(Formatters.bytesString(sample.memBytes))
            } icon: {
                Image(systemName: "memorychip")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .labelStyle(TrackBTightLabelStyle())
        .transition(.opacity)
    }

    private var portLine: some View {
        // A row with a dozen published ports should not push the actions off screen, so
        // the overflow collapses into a count rather than wrapping onto a third line.
        HStack(spacing: 4) {
            ForEach(container.ports.prefix(4)) { port in
                TrackBPortChip(port: port)
            }
            if container.ports.count > 4 {
                Text("+\(container.ports.count - 4)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .help(container.ports.map(\.label).joined(separator: ", "))
            }
        }
        .padding(.top, 1)
    }

    // MARK: Trailing

    @ViewBuilder
    private var trailing: some View {
        if isBusy {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.65)
                .frame(width: 24, height: 22)
        } else if hovering {
            HStack(spacing: 1) {
                if container.isRunning {
                    TrackBIconButton(symbol: "stop.fill", help: "Stop", tint: .orange) {
                        onAction(.stop)
                    }
                    TrackBIconButton(symbol: "arrow.clockwise", help: "Restart", tint: Theme.accent) {
                        onAction(.restart)
                    }
                } else if container.state == "paused" {
                    TrackBIconButton(symbol: "play.fill", help: "Resume", tint: .green) {
                        onAction(.unpause)
                    }
                } else {
                    TrackBIconButton(symbol: "play.fill", help: "Start", tint: .green) {
                        onAction(.start)
                    }
                }
                TrackBIconButton(symbol: "trash", help: "Remove", tint: .red) {
                    onRequestRemove()
                }
            }
            .transition(.opacity)
        } else {
            Text(uptimeText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(minWidth: 30, alignment: .trailing)
        }
    }

    // MARK: Menu

    @ViewBuilder
    private var contextMenu: some View {
        if container.isRunning {
            Button("Stop") { onAction(.stop) }
            Button("Restart") { onAction(.restart) }
            Button("Pause") { onAction(.pause) }
        } else if container.state == "paused" {
            Button("Resume") { onAction(.unpause) }
            Button("Stop") { onAction(.stop) }
        } else {
            Button("Start") { onAction(.start) }
        }
        Divider()
        Button("Copy name") { TrackBClipboard.copy(container.displayName) }
        Button("Copy container ID") { TrackBClipboard.copy(container.id) }
        if let url = container.ports.compactMap(\.url).first {
            Button("Open \(url.absoluteString)") { NSWorkspace.shared.open(url) }
        }
        Divider()
        Button("Remove…", role: .destructive) { onRequestRemove() }
    }

    // MARK: Text

    /// `Exited (0) 4 minutes ago` shortened to what fits: Docker's own prose, minus the
    /// repetition of the state that the dot already shows.
    private var shortStatus: String {
        container.status.isEmpty ? container.state : container.status
    }

    private var uptimeText: String {
        container.isRunning ? Formatters.compactDuration(since: container.createdAt) : ""
    }

    // MARK: Stats subscription

    /// Subscribes only while the row is on screen *and* the container is running.
    ///
    /// `LazyVStack`-backed `List` rows call `onDisappear` as they scroll out of view, so
    /// a hundred-row list keeps open only as many stats connections as fit in the
    /// window — which is the whole reason this is reference-counted rather than a single
    /// subscription per container held for the life of the screen.
    private func subscribe() {
        guard container.isRunning, probe == nil else { return }
        probe = hub.retain(container.id, client: client)
    }

    private func unsubscribe() {
        guard probe != nil else { return }
        probe = nil
        hub.release(container.id)
    }
}

/// `Label` with the icon tucked right against the text — the default spacing is built
/// for menus and is far too airy for a metric read at caption size.
struct TrackBTightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9))
            configuration.title
        }
    }
}

// MARK: - Compose group header

/// The band above a compose project's containers.
///
/// The up/down buttons are compose *intents* expressed through the per-container API:
/// Morbstack's engine socket is plain Docker, so "up" means starting each member and
/// "down" means stopping each one. That is exactly what `docker compose start` and
/// `stop` do to an already-created project, which is the state anything visible here is
/// necessarily in.
struct ComposeGroupHeader: View {

    let group: ComposeGroup
    let busyCount: Int
    let onUp: () -> Void
    let onDown: () -> Void

    @State private var hovering = false

    private var allRunning: Bool { group.isFullyRunning }
    private var noneRunning: Bool { group.runningCount == 0 }

    private var aggregateColor: Color {
        if allRunning { return .green }
        if noneRunning { return .secondary }
        return .orange
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: group.project == nil ? "square.dashed" : "square.stack.3d.up.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(group.project == nil ? Color.secondary : aggregateColor)

            Text(group.title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)

            Text("\(group.runningCount)/\(group.containers.count)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(aggregateColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(aggregateColor.opacity(0.14), in: Capsule())

            Spacer(minLength: 6)

            if busyCount > 0 {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 20)
            } else if group.project != nil, hovering {
                HStack(spacing: 1) {
                    TrackBIconButton(
                        symbol: "play.fill",
                        help: "Start every service in \(group.title)",
                        tint: .green,
                        action: onUp)
                    .disabled(allRunning)
                    TrackBIconButton(
                        symbol: "stop.fill",
                        help: "Stop every service in \(group.title)",
                        tint: .orange,
                        action: onDown)
                    .disabled(noneRunning)
                }
                .transition(.opacity)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
