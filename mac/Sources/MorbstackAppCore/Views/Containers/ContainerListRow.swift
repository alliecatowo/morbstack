// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// One container in the list, and the compose project header above a group of them.
//
// The row is fixed at `Theme.rowRich` (44pt) regardless of how many ports a container
// publishes — the previous build swelled from 70pt to 100pt per row, which is why the
// list could not be counted by eye. The trailing column is a single fixed-width slot:
// CPU and memory when the container is running, the first published port plus an
// overflow chip for the rest, and the lifecycle actions on hover. Nothing in it can make
// the row taller.

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
    /// Defaults to `false` so the offscreen screenshot harness's own copy of this call
    /// site (`Shots/ShotScenes.swift`, which predates this parameter) keeps compiling.
    /// The shipping list — `ContainersRootView` — passes the real selection state.
    var isSelected: Bool = false

    @State private var hovering = false
    @State private var probe: TrackBStatsProbe?

    /// This row's probe, or the last one the hub kept for this container.
    ///
    /// Scrolling a row back into view then shows its previous numbers immediately rather
    /// than blanking for the two seconds until the next sample. It is also what lets the
    /// row render its metrics offscreen — in a preview or in the screenshot harness,
    /// `onAppear` never fires, so `probe` stays `nil` and the hub is the only source.
    private var activeProbe: TrackBStatsProbe? { probe ?? hub.existingProbe(container.id) }

    private var tone: StatusTone { StatusTone.forContainer(state: container.state, unhealthy: container.isUnhealthy) }

    var body: some View {
        HStack(spacing: Theme.space3) {
            MorbStatusDot(tone: tone, pulsing: tone.isTransitional)

            VStack(alignment: .leading, spacing: Theme.space1) {
                titleLine
                Text(container.image)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: Theme.space3)

            trailing
        }
        .morbRow(.rich, showsHover: true)
        .onHover { hovering = $0 }
        .help(tooltip)
        .onAppear(perform: subscribe)
        .onDisappear(perform: unsubscribe)
        .onChange(of: container.isRunning) { _, _ in
            unsubscribe()
            subscribe()
        }
    }

    // MARK: Title

    private var titleLine: some View {
        HStack(spacing: Theme.space2) {
            Text(container.displayName)
                .font(.body.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)

            if let service = container.composeService, service != container.displayName {
                MorbChip(service, rank: .quiet)
            }
            if container.isUnhealthy {
                MorbChip("unhealthy", symbol: "exclamationmark.octagon.fill", rank: .status(.bad))
            } else if container.state == "paused" {
                MorbChip("paused", symbol: "pause.fill", rank: .status(.paused))
            }
        }
    }

    private var tooltip: String {
        let base = container.status.isEmpty ? container.state : container.status
        guard container.isRunning else { return base }
        return "\(base) · up \(Formatters.compactDuration(since: container.createdAt))"
    }

    // MARK: Trailing

    private static let trailingWidth: CGFloat = 168

    @ViewBuilder
    private var trailing: some View {
        if isBusy {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.65)
                .frame(width: Self.trailingWidth, alignment: .trailing)
        } else if hovering {
            hoverActions
                .frame(width: Self.trailingWidth, alignment: .trailing)
        } else {
            restingTrailing
                .frame(width: Self.trailingWidth, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var restingTrailing: some View {
        VStack(alignment: .trailing, spacing: Theme.space1) {
            metricsLine
            portsLine
        }
    }

    @ViewBuilder
    private var metricsLine: some View {
        if container.isRunning, let sample = activeProbe?.latest {
            HStack(spacing: Theme.space2) {
                MorbNumber(Formatters.percent(sample.cpuPercent), width: 42)
                MorbNumber(Formatters.bytesString(sample.memBytes), width: 60)
            }
        } else {
            Text(shortStatus)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var portsLine: some View {
        if let first = container.ports.first {
            HStack(spacing: Theme.space1 + 1) {
                if container.ports.count > 1 {
                    MorbOverflowChip(
                        hidden: container.ports.count - 1,
                        detail: container.ports.dropFirst().map(\.label).joined(separator: ", "))
                }
                MorbPortChip(
                    host: first.hostPort.map(String.init) ?? first.label,
                    container: "\(first.containerPort)/\(first.proto)",
                    isOpenable: first.url != nil)
            }
        }
    }

    private var hoverActions: some View {
        HStack(spacing: Theme.space1) {
            if container.isRunning {
                MorbIconButton("stop.fill", help: "Stop") { onAction(.stop) }
                MorbIconButton("arrow.clockwise", help: "Restart") { onAction(.restart) }
            } else if container.state == "paused" {
                MorbIconButton("play.fill", help: "Resume") { onAction(.unpause) }
            } else {
                MorbIconButton("play.fill", help: "Start") { onAction(.start) }
            }
            MorbIconButton("trash", help: "Remove", role: .destructive) { onRequestRemove() }
        }
    }

    // MARK: Text

    /// `Exited (0) 4 minutes ago` shortened to what fits: Docker's own prose, minus the
    /// repetition of the state that the dot already shows.
    private var shortStatus: String {
        container.status.isEmpty ? container.state : container.status
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

    private var state: MorbGroupState {
        MorbGroupState.from(running: group.runningCount, total: group.containers.count,
                            transitioning: busyCount)
    }

    var body: some View {
        MorbGroupHeader(
            group.title,
            state: state,
            running: group.runningCount,
            total: group.containers.count,
            symbol: group.project == nil ? nil : "square.3.layers.3d"
        ) {
            if busyCount > 0 {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 20)
            } else if group.project != nil, hovering {
                HStack(spacing: Theme.space1) {
                    MorbIconButton("play.fill", help: "Start every service in \(group.title)") {
                        onUp()
                    }
                    .disabled(allRunning)
                    MorbIconButton("stop.fill", help: "Stop every service in \(group.title)") {
                        onDown()
                    }
                    .disabled(noneRunning)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
