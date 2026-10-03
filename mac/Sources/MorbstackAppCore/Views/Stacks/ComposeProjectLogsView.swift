// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The Compose-aggregated log document: one merged, per-service-coloured transcript for a
// whole project.
//
// **Why this is a window and not a tab.** The task is "watch what my project is doing
// while I work on it", and the three places it could have gone are each wrong for a
// specific reason:
//
//   * *A pane in the Stacks inspector.* An inspector describes the selected record in
//     340–520pt. A streaming transcript with a timestamp column, a service column and a
//     wrap toggle is a document, not record metadata, and it does not fit.
//   * *A mode inside the container Logs tab.* That tab belongs to one selected
//     container. Showing a whole project underneath a container's record would
//     misdescribe what is selected, and it would still be in the inspector column.
//   * *A sidebar destination.* The sidebar lists resource categories the engine has.
//     "Logs of one project" is a view onto a record, not a tenth category, and opening
//     it would replace the browser the person is working in.
//
// A separate window is the macOS answer to "keep this visible while I do something
// else": non-modal, resizable to the width a merged log actually needs, restorable, and
// several can be open at once for different projects. `openWindow(id:value:)` with the
// project name as the value is exactly the shape `WindowGroup(id:for:)` is documented
// for. See Apple's "Presenting windows and spaces" and `WindowGroup`.
//
// Only the aggregation lives here. The document itself — find/filter, follow, wrap,
// links, export — is `TrackBLogDocumentView`, shared with the single-container tab.

import Foundation
import Observation
import SwiftUI

// MARK: - Session

/// Owns one Docker log stream per service and merges them into a single store.
@MainActor
@Observable
final class ComposeProjectLogSession {

    /// One service the document is following.
    struct Service: Identifiable, Equatable {
        let source: TrackBLogSource
        /// Docker's container name, for the accessibility identifier and the tooltip.
        let containerName: String
        var isStreaming: Bool
        var errorText: String?
        var lineCount: Int
        /// `false` once the container has gone away from the project's membership.
        var isPresent: Bool

        var id: String { source.containerID }
        var name: String { source.service }
    }

    let store = TrackBLogStore()

    private(set) var services: [Service] = []
    private(set) var isPriming = false

    private var merge = ComposeLogMerge()
    private var colors = ComposeServiceColors(services: [])
    private var streamTasks: [String: Task<Void, Never>] = [:]
    private var drainTask: Task<Void, Never>?
    private var nextLineID = 0
    private var client: DockerClient?

    /// Matches the single-container document's publish cadence: fast enough to look
    /// live, slow enough that a firehose cannot force a layout pass per line.
    private let drainInterval = Duration.milliseconds(80)

    // MARK: Tail budget

    /// How much history to request per service.
    ///
    /// The single-container document asks for 1,000 lines; asking every service for
    /// that would blow past the shared 10,000-line scrollback before a project of a
    /// dozen services had finished loading, and the oldest half would be evicted
    /// unread. Half the buffer is reserved for what happens *after* the document opens.
    static func historyTail(serviceCount: Int) -> Int {
        let budget = TrackBLogStore.capacity / 2 / max(1, serviceCount)
        return max(100, min(TrackBLogStore.initialTail, budget))
    }

    // MARK: Lifecycle

    func start(client: DockerClient, containers: [ContainerSummary]) {
        stop()
        self.client = client
        store.beginHostedStream()
        merge.removeAll()
        nextLineID = 0
        services.removeAll()
        colors = ComposeServiceColors(services: containers.map(Self.serviceName))
        isPriming = !containers.isEmpty

        // Budget the history request against the project's whole membership, not
        // against however many services have been attached so far.
        let tail = Self.historyTail(serviceCount: containers.count)
        for container in containers { attach(container, tail: tail) }

        drainTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.drainInterval ?? .milliseconds(80))
                if Task.isCancelled { return }
                self?.publish()
            }
        }
    }

    /// Starts the document, or follows a change in the project's membership without
    /// discarding what is already on screen.
    ///
    /// A `compose up` that recreates one service must not clear the other three
    /// services' scrollback — that is the moment the merged log is most useful. New
    /// containers get a stream; departed ones stop, keep their lines, and are marked so
    /// the service list can say they are gone rather than silently pretending to follow.
    ///
    /// Starting from here is the ordinary path when the window is restored at launch or
    /// opened before the model has answered: the project has no containers yet, and the
    /// first refresh that produces some is what begins the document.
    func synchronize(client: DockerClient, containers: [ContainerSummary]) {
        guard drainTask != nil else {
            guard !containers.isEmpty else { return }
            start(client: client, containers: containers)
            return
        }
        let desired = Dictionary(uniqueKeysWithValues: containers.map { ($0.id, $0) })

        for index in services.indices where desired[services[index].id] == nil {
            guard services[index].isPresent else { continue }
            services[index].isPresent = false
            services[index].isStreaming = false
            streamTasks[services[index].id]?.cancel()
            streamTasks[services[index].id] = nil
            merge.markReady(services[index].id)
        }

        let tail = Self.historyTail(serviceCount: max(containers.count, services.count))
        for container in containers where !services.contains(where: { $0.id == container.id }) {
            attach(container, tail: tail, client: client)
        }
    }

    func stop() {
        drainTask?.cancel()
        drainTask = nil
        for task in streamTasks.values { task.cancel() }
        streamTasks.removeAll()
        let remaining = merge.flush()
        if !remaining.isEmpty { store.appendHosted(remaining.map(render)) }
        store.finishHostedStream(error: nil)
        for index in services.indices { services[index].isStreaming = false }
        isPriming = false
    }

    // MARK: Visibility

    var hiddenServiceNames: [String] {
        services.filter { store.hiddenSources.contains($0.id) }.map(\.name).sorted()
    }

    var visibleServiceNames: [String] {
        services.filter { !store.hiddenSources.contains($0.id) }.map(\.name).sorted()
    }

    var unavailableServiceNames: [String] {
        services.filter { $0.errorText != nil }.map(\.name).sorted()
    }

    func isHidden(_ service: Service) -> Bool {
        store.hiddenSources.contains(service.id)
    }

    /// Hiding a service is a scope on the document, not an unsubscribe: its lines stay
    /// in the scrollback and its stream stays open, so showing it again is instant and
    /// the history is not full of holes.
    func setHidden(_ hidden: Bool, for service: Service) {
        if hidden {
            store.hiddenSources.insert(service.id)
        } else {
            store.hiddenSources.remove(service.id)
        }
    }

    func showAllServices() {
        store.hiddenSources.removeAll()
    }

    var streamingCount: Int { services.filter(\.isStreaming).count }

    // MARK: Internals

    static func serviceName(for container: ContainerSummary) -> String {
        let service = container.composeService ?? ""
        return service.isEmpty ? container.displayName : service
    }

    private func attach(_ container: ContainerSummary, tail: Int, client: DockerClient? = nil) {
        guard let client = client ?? self.client else { return }
        let name = Self.serviceName(for: container)
        let source = TrackBLogSource(
            containerID: container.id,
            service: name,
            colorIndex: colors.index(for: name))
        services.append(
            Service(
                source: source,
                containerName: container.displayName,
                isStreaming: true,
                errorText: nil,
                lineCount: 0,
                isPresent: true))
        services.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        merge.register(source, at: Date())
        streamTasks[container.id] = Task { [weak self] in
            do {
                for try await line in client.logs(id: container.id, follow: true, tail: tail) {
                    if Task.isCancelled { return }
                    self?.receive(line, from: source)
                }
                if !Task.isCancelled { self?.finish(source, error: nil) }
            } catch {
                if !Task.isCancelled { self?.finish(source, error: error) }
            }
        }
    }

    private func receive(_ line: LogLine, from source: TrackBLogSource) {
        merge.ingest(line, from: source, at: Date())
        if let index = services.firstIndex(where: { $0.id == source.containerID }) {
            services[index].lineCount += 1
        }
    }

    /// A stream ended. That is normal — `follow` returns when a container exits — so it
    /// is reported per service rather than as a failure of the whole document.
    private func finish(_ source: TrackBLogSource, error: Error?) {
        merge.markReady(source.containerID)
        guard let index = services.firstIndex(where: { $0.id == source.containerID }) else { return }
        services[index].isStreaming = false
        if let error { services[index].errorText = TrackBErrorText.short(error) }
        if services.allSatisfy({ !$0.isStreaming }) {
            store.finishHostedStream(error: nil)
        }
    }

    private func publish() {
        let now = Date()
        isPriming = merge.isPriming(at: now)
        let released = merge.drain(now: now)
        guard !released.isEmpty else { return }
        store.appendHosted(released.map(render))
    }

    /// IDs are assigned here, at release, so display order and ID order are the same
    /// sequence. The find navigator binary-searches ascending IDs, and every reader
    /// assumes a log reads downwards.
    private func render(_ pending: ComposeLogMerge.Pending) -> TrackBRenderedLine {
        defer { nextLineID += 1 }
        return TrackBRenderedLine(pending.line, id: nextLineID, source: pending.source)
    }
}

// MARK: - Window

/// The scene content for one project's merged log.
struct ComposeProjectLogsView: View {

    let project: String
    let model: AppModel

    @State private var session = ComposeProjectLogSession()

    /// Containers Docker currently reports for this project, ordered by service name.
    private var containers: [ContainerSummary] {
        model.containers
            .filter { $0.composeProject == project }
            .sorted {
                ComposeProjectLogSession.serviceName(for: $0)
                    .localizedStandardCompare(ComposeProjectLogSession.serviceName(for: $1))
                    == .orderedAscending
            }
    }

    private var subtitle: String {
        let total = session.services.count
        guard total > 0 else { return "No services" }
        let streaming = session.streamingCount
        var parts = ["\(streaming) of \(total) service\(total == 1 ? "" : "s") streaming"]
        let hidden = session.hiddenServiceNames.count
        if hidden > 0 { parts.append("\(hidden) hidden") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        content
            .navigationTitle("\(project) — Logs")
            .navigationSubtitle(subtitle)
            .frame(minWidth: 720, minHeight: 400)
            .task(id: project) {
                session.synchronize(client: model.client, containers: containers)
            }
            // A restored window, or one opened before the model has answered, starts
            // here; an ordinary membership change adds and retires streams in place.
            .onChange(of: containers.map(\.id)) { _, _ in
                session.synchronize(client: model.client, containers: containers)
            }
            .onDisappear { session.stop() }
    }

    @ViewBuilder
    private var content: some View {
        if containers.isEmpty && session.services.isEmpty {
            // Honest, not a placeholder: the window may have been restored after the
            // project was removed, or opened against an engine that is not running.
            ContentUnavailableView {
                Label("No Containers for “\(project)”", systemImage: "square.stack.3d.up")
            } description: {
                Text(model.engine.isRunning
                    ? "Docker reports no containers labelled with this Compose project. Start the project and its services’ output appears here."
                    : "The Morbstack engine isn’t running, so there are no container logs to merge.")
            }
            .accessibilityIdentifier("stacks.projectLogs.empty")
        } else {
            TrackBLogDocumentView(
                store: session.store,
                scope: "stacks.projectLogs",
                showsSourceColumn: true,
                exportFilename: TrackBLogExport.suggestedFilename(container: project),
                makeExportDocument: {
                    session.store.exportProjectDocument(
                        project: project,
                        includedServices: session.visibleServiceNames,
                        hiddenServices: session.hiddenServiceNames,
                        unavailableServices: session.unavailableServiceNames)
                },
                additionalOptions: { servicesMenu },
                emptyOverlay: { emptyOverlay })
        }
    }

    /// Per-service show/hide, with the colour swatch beside the name it belongs to.
    private var servicesMenu: some View {
        Group {
            Menu("Services") {
                ForEach(session.services) { service in
                    Toggle(isOn: Binding(
                        get: { !session.isHidden(service) },
                        set: { session.setHidden(!$0, for: service) }))
                    {
                        Label {
                            Text(serviceMenuTitle(service))
                        } icon: {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(
                                    ComposeServicePalette.color(at: service.source.colorIndex))
                        }
                    }
                    .accessibilityIdentifier("stacks.projectLogs.service.\(service.containerName)")
                }

                Divider()

                Button("Show All Services") { session.showAllServices() }
                    .accessibilityIdentifier("stacks.projectLogs.showAllServices")
                    .disabled(session.hiddenServiceNames.isEmpty)
            }
            .accessibilityIdentifier("stacks.projectLogs.services")

            Divider()
        }
    }

    /// The menu row states the service's own condition: a stopped or unreachable
    /// service must not read as one that is simply quiet.
    private func serviceMenuTitle(_ service: ComposeProjectLogSession.Service) -> String {
        var detail: [String] = ["\(service.lineCount) line\(service.lineCount == 1 ? "" : "s")"]
        if !service.isPresent {
            detail.append("no longer in the project")
        } else if service.errorText != nil {
            detail.append("stream unavailable")
        } else if !service.isStreaming {
            detail.append("ended")
        }
        return "\(service.name) — \(detail.joined(separator: ", "))"
    }

    @ViewBuilder
    private var emptyOverlay: some View {
        if session.store.isFiltering {
            ContentUnavailableView.search(text: session.store.query)
        } else if session.store.hasHiddenSources && !session.store.lines.isEmpty {
            ContentUnavailableView {
                Label("Every Service Is Hidden", systemImage: "eye.slash")
            } description: {
                Text("The project has \(session.store.lines.count) buffered lines. Show a service in the log options menu to read them.")
            }
        } else if session.isPriming {
            // Not a fake progress bar: the document really is holding lines back until
            // every service has answered, so that the first screen is in timestamp
            // order rather than in whichever order the sockets happened to reply.
            ProgressView("Merging Service Output")
        } else if session.store.isStreaming {
            ProgressView("Loading Logs")
        } else {
            ContentUnavailableView {
                Label("No Output", systemImage: "text.alignleft")
            } description: {
                Text("None of this project’s services has written to standard output or standard error.")
            }
        }
    }
}
