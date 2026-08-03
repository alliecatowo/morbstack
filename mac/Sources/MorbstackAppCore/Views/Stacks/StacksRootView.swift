// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Stacks are Docker Compose projects inferred from the standard
// `com.docker.compose.project` container label. The resource browser follows the
// same macOS pattern as Finder and Xcode: one native outline table with a
// system-owned trailing inspector. A Compose project is the real parent of its
// service rows, never a decorative card or a repeated string column.

import AppKit
import Foundation
import MorbstackKit
import Observation
import SwiftUI

// MARK: - Compose metadata

/// Compose metadata is absent from Docker's summary endpoint. It is loaded from one
/// container inspect response for a selected project, then cached for the session.
@MainActor
@Observable
final class TrackDComposeMetadata {

    private(set) var configFiles: [String: [String]] = [:]
    private(set) var workingDirectories: [String: String] = [:]

    @ObservationIgnored private var inFlight: Set<String> = []

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
                // Cache a negative response too; repeated refreshes should not make the
                // same inspect request only to rediscover that Docker omitted the label.
                configFiles[project] = []
            }

            if let directory = labels["com.docker.compose.project.working_dir"], !directory.isEmpty {
                workingDirectories[project] = directory
            }
        }
    }
}

private enum StackOutlineID: Hashable {
    case project(String)
    case service(ContainerSummary.ID)
}

/// A single value type lets `OutlineGroup` express the Compose relationship through
/// the system list's native disclosure, selection, accessibility, and keyboard behavior.
private struct StackOutlineRow: Identifiable, Hashable {

    enum Kind: Hashable {
        case project(ComposeGroup)
        case service(ContainerSummary)
    }

    let kind: Kind
    let children: [StackOutlineRow]?

    var id: StackOutlineID {
        switch kind {
        case .project(let stack): .project(stack.id)
        case .service(let service): .service(service.id)
        }
    }

    var service: ContainerSummary? {
        guard case .service(let service) = kind else { return nil }
        return service
    }

    var displayName: String {
        switch kind {
        case .project(let stack): stack.title
        case .service(let service): service.composeService ?? service.displayName
        }
    }
}

/// A reviewed operation on the existing Docker containers that currently make up one
/// Compose-labelled project. The captured IDs make the confirmation's scope stable:
/// a new service that appears while the dialog is open cannot be acted on implicitly.
private struct ProjectLifecycleReview: Identifiable {
    let action: ContainerAction
    let projectID: String
    let projectName: String
    let targetIDs: Set<ContainerSummary.ID>

    var id: String { "\(projectID):\(action.rawValue)" }
    var targetCount: Int { targetIDs.count }
}

// MARK: - Root

struct StacksRootView: View {

    let model: AppModel

    @State private var metadata = TrackDComposeMetadata()
    @State private var query = ""
    @State private var selection: StackOutlineID?
    @State private var showsInspector = true
    /// Compose files are supporting metadata, not equal-weight inspector facts.
    @State private var composeFilesExpanded = false
    @State private var busyProjects: Set<String> = []
    @State private var busyServices: Set<ContainerSummary.ID> = []
    @State private var removalTarget: ContainerSummary?
    @State private var projectLifecycleReview: ProjectLifecycleReview?
    /// A user-selected project source document is intentionally separate from Compose
    /// metadata inferred from running containers. Labels can describe a project, but
    /// they never authorize Morbstack to open or write a file from the person's tree.
    @State private var composeFileEditor = ComposeFileEditor()
    @State private var composeSourceValidation = ComposeSourceValidationModel()
    @State private var composeProjectOperations = ComposeProjectOperationModel()

    /// Compose projects only. Unmanaged containers belong to the Containers browser.
    private var stacks: [ComposeGroup] {
        model.containers.groupedByComposeProject().filter { $0.project != nil }
    }

    private var services: [ContainerSummary] {
        stacks.flatMap(\.containers)
    }

    /// A searched service remains below its Compose project so the native outline
    /// preserves the relationship that gives its lifecycle actions their meaning.
    private var visibleRows: [StackOutlineRow] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return stacks.compactMap { stack in
            let projectMatches = needle.isEmpty || stack.title.localizedCaseInsensitiveContains(needle)
            let matchingServices = stack.containers.filter { service in
                projectMatches || serviceMatchesQuery(service, needle: needle)
            }
            guard !matchingServices.isEmpty else { return nil }

            return StackOutlineRow(
                kind: .project(stack),
                children: matchingServices
                    .map { StackOutlineRow(kind: .service($0), children: nil) }
                    .sorted { outlineRowsAreAscending($0, $1) })
        }
        // Alphabetizing each level aids discovery without flattening the Compose
        // parent → service relationship into an unrelated operational-record table.
        .sorted { outlineRowsAreAscending($0, $1) }
    }

    private func outlineRowsAreAscending(_ lhs: StackOutlineRow, _ rhs: StackOutlineRow) -> Bool {
        lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }

    /// A list selection must always describe a row that is presently in the outline.
    /// Keeping this separate from `stacks` is intentional: a search can hide a live
    /// service without removing it from Docker, and its inspector must not continue to
    /// describe that hidden result.
    private var visibleRowIDs: Set<StackOutlineID> {
        Set(visibleRows.flatMap { row in
            [row.id] + (row.children ?? []).map(\.id)
        })
    }

    private var selectedService: ContainerSummary? {
        guard case .service(let id) = selection else { return nil }
        return services.first { $0.id == id }
    }

    private var selectedStack: ComposeGroup? {
        switch selection {
        case .project(let id):
            return stacks.first { $0.id == id }
        case .service(let id):
            return services
                .first { $0.id == id }
                .flatMap { service in stacks.first { $0.project == service.composeProject } }
        case nil:
            return nil
        }
    }

    private var totalServices: Int { services.count }
    private var runningServices: Int { services.filter(\.isRunning).count }

    private var degradedCount: Int {
        stacks.filter { $0.runningCount > 0 && $0.runningCount < $0.containers.count }.count
    }

    private var subtitle: String {
        var parts = [
            "\(stacks.count) project\(stacks.count == 1 ? "" : "s")",
            "\(runningServices) of \(totalServices) services running",
        ]
        if degradedCount > 0 { parts.append("\(degradedCount) degraded") }
        let visibleServiceCount = visibleRows.reduce(into: 0) { count, row in
            count += row.children?.count ?? 0
        }
        if visibleServiceCount != totalServices {
            parts.append("\(visibleServiceCount) shown")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        content
            .navigationTitle("Stacks")
            .navigationSubtitle(subtitle)
            .searchable(text: $query, placement: .toolbar, prompt: "Project, service, image")
            .toolbar { toolbarContent }
            .confirmationDialog(
                removalTarget.map { "Remove \($0.composeService ?? $0.displayName)?" } ?? "Remove service?",
                isPresented: Binding(
                    get: { removalTarget != nil },
                    set: { if !$0 { removalTarget = nil } }),
                titleVisibility: .visible,
                presenting: removalTarget
            ) { service in
                Button("Remove", role: .destructive) {
                    removalTarget = nil
                    // The record can change while the confirmation is visible. Re-read
                    // it from the current list data so a completed confirmation never
                    // turns into a silently unavailable lifecycle request.
                    if let currentService = services.first(where: { $0.id == service.id }),
                        canRemove(currentService)
                    {
                        perform(.remove, on: currentService)
                    }
                }
                Button("Cancel", role: .cancel) { removalTarget = nil }
            } message: { service in
                Text(
                    "This deletes the service’s writable layer and any anonymous volumes. "
                        + "Named volumes are kept.")
            }
            .confirmationDialog(
                projectLifecycleReview.map { projectLifecycleReviewTitle($0) } ?? "Update Project?",
                isPresented: Binding(
                    get: { projectLifecycleReview != nil },
                    set: { if !$0 { projectLifecycleReview = nil } }),
                titleVisibility: .visible,
                presenting: projectLifecycleReview
            ) { review in
                Button(review.action.title) {
                    projectLifecycleReview = nil
                    confirmProjectLifecycleAction(review)
                }
                Button("Cancel", role: .cancel) { projectLifecycleReview = nil }
            } message: { review in
                Text(projectLifecycleReviewMessage(review))
            }
            .onChange(of: selection) { _, newValue in
                composeFilesExpanded = false
                if newValue != nil { showsInspector = true }
            }
            .onChange(of: visibleRowIDs) { _, _ in
                reconcileSelectionWithVisibleRows()
            }
            .sheet(
                isPresented: Binding(
                    get: { composeFileEditor.isPresented },
                    set: { isPresented in
                        if !isPresented { composeFileEditor.requestClose() }
                    })
            ) {
                ComposeFileEditorSheet(
                    editor: composeFileEditor,
                    validation: composeSourceValidation,
                    projectOperations: composeProjectOperations,
                    refreshStacks: { await model.refreshAll() })
            }
            .alert(
                composeFileEditor.openErrorTitle,
                isPresented: Binding(
                    get: { composeFileEditor.openError != nil },
                    set: { if !$0 { composeFileEditor.openError = nil } })
            ) {
                Button("OK", role: .cancel) { composeFileEditor.openError = nil }
            } message: {
                Text(composeFileEditor.openError ?? "")
            }
            .focusedSceneValue(
                \.composeFileEditorCommandActions,
                composeFileEditor.commandActions)
            .focusedSceneValue(
                \.composeSourceValidationCommandActions,
                composeSourceValidation.commandActions(using: composeFileEditor))
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // A Compose project has no one universal primary command: the useful action
        // depends on the selected project or service and already lives in its
        // contextual menu below.  Refresh is utility work, so macOS may overflow it.
        ToolbarItem(id: "stacks.refresh", placement: .secondaryAction) {
            Button {
                Task { await model.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("Refresh stacks")
            .help("Refresh Compose projects")
        }

        if !services.isEmpty {
            ToolbarItem(id: "stacks.inspector", placement: .automatic) {
                Button { showsInspector.toggle() } label: {
                    Image(systemName: "sidebar.right")
                }
                .accessibilityLabel(showsInspector ? "Hide inspector" : "Show inspector")
                .help(showsInspector ? "Hide inspector" : "Show inspector")
            }
        }

        if selectedStack != nil {
            ToolbarItem(id: "stacks.editComposeFile", placement: .secondaryAction) {
                Button { chooseComposeFile() } label: {
                    Image(systemName: "doc.text")
                }
                .disabled(composeFileEditor.isPresented)
                .accessibilityLabel("Edit Compose file")
                .help("Choose and edit a Compose YAML file")
            }
        }

        if let stack = selectedStack {
            if let service = selectedService,
                isServiceBusy(service) || isProjectBusy(for: service)
            {
                ToolbarItem(id: "stacks.primaryLifecycle", placement: .primaryAction) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Updating \(service.composeService ?? service.displayName)")
                        .help("Updating \(service.composeService ?? service.displayName)")
                }
            } else if let service = selectedService {
                if let action = primaryLifecycleAction(for: service) {
                    ToolbarItem(id: "stacks.primaryLifecycle", placement: .primaryAction) {
                        Button { perform(action, on: service) } label: {
                            Image(systemName: action.symbol)
                        }
                        .accessibilityLabel(action.title)
                        .help("\(action.title) \(service.composeService ?? service.displayName)")
                    }
                }
                ToolbarItem(id: "stacks.actions", placement: .secondaryAction) {
                    selectionActionsMenu(service: service, stack: stack)
                }
            } else if busyProjects.contains(stack.id) {
                ToolbarItem(id: "stacks.project-progress", placement: .secondaryAction) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Updating \(stack.title)")
                        .help("Updating \(stack.title)")
                }
            } else {
                ToolbarItem(id: "stacks.project-actions", placement: .secondaryAction) {
                    projectActionsMenu(for: stack)
                }
            }
        }
    }

    /// A selected service gets the same single, state-appropriate lifecycle command
    /// as its container record. Other lifecycle and project operations remain in the
    /// system-managed secondary menu, so they do not crowd search or the inspector
    /// control at narrow widths.
    private func primaryLifecycleAction(for service: ContainerSummary) -> ContainerAction? {
        switch service.state {
        case "running", "restarting":
            return service.availableActions.contains(.stop) ? .stop : nil
        case "paused":
            return service.availableActions.contains(.unpause) ? .unpause : nil
        default:
            return service.availableActions.contains(.start) ? .start : nil
        }
    }

    /// The primary action is intentionally absent from the secondary toolbar menu
    /// and inspector. A context menu remains the complete record-local command list.
    private func secondaryLifecycleActions(for service: ContainerSummary) -> [ContainerAction] {
        service.availableActions.filter {
            !$0.isDestructive && $0 != primaryLifecycleAction(for: service)
        }
    }

    /// A destructive command is only exposed while Docker reports it as available and
    /// neither this service nor its Compose project is already changing state.
    private func canRemove(_ service: ContainerSummary) -> Bool {
        service.availableActions.contains(.remove)
            && !isServiceBusy(service)
            && !isProjectBusy(for: service)
    }

    private func selectionActionsMenu(service: ContainerSummary, stack: ComposeGroup) -> some View {
        Menu {
            let secondaryActions = secondaryLifecycleActions(for: service)
            if isServiceBusy(service) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Updating \(service.composeService ?? service.displayName)")
            } else {
                ForEach(secondaryActions, id: \.rawValue) { action in
                    Button(action.title, systemImage: action.symbol) {
                        perform(action, on: service)
                    }
                    .disabled(isProjectBusy(for: service))
                }
            }
            if isServiceBusy(service) || !secondaryActions.isEmpty {
                Divider()
            }
            Menu("Project Actions") {
                projectActionItems(for: stack)
            }
            Divider()
            Button("Open in Containers") {
                TrackDAppBridge.reveal(containerID: service.id, in: model)
            }
            Button("View Logs") {
                TrackDAppBridge.reveal(containerID: service.id, in: model, showingLogs: true)
            }
            if canRemove(service) {
                Divider()
                Button("Remove Service…", role: .destructive) { removalTarget = service }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("Actions for \(service.composeService ?? service.displayName)")
        .help("Actions for \(service.composeService ?? service.displayName)")
    }

    private func projectActionsMenu(for stack: ComposeGroup) -> some View {
        Menu {
            projectActionItems(for: stack)
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("Actions for \(stack.title)")
        .help("Actions for \(stack.title)")
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !model.engine.isRunning && model.containers.isEmpty {
            engineEmptyState
        } else if services.isEmpty {
            noStacksEmptyState
        } else if visibleRows.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            outline
                .inspector(isPresented: $showsInspector) {
                    inspector
                        .inspectorColumnWidth(min: 340, ideal: 400, max: 520)
                }
        }
    }

    private var outline: some View {
        List(selection: $selection) {
            OutlineGroup(visibleRows, children: \.children) { row in
                Label(
                    row.displayName,
                    systemImage: row.service.map { stateSymbol(for: $0) } ?? "square.stack.3d.up")
                    .tag(row.id)
                    .help(row.service.map { $0.status.isEmpty ? $0.state : $0.status } ?? "Compose project")
            }
        }
        .contextMenu(forSelectionType: StackOutlineID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            if case .service(let id) = ids.first {
                TrackDAppBridge.reveal(containerID: id, in: model)
            }
        }
        .onDeleteCommand {
            if let selectedService, canRemove(selectedService) {
                removalTarget = selectedService
            }
        }
    }

    // MARK: Inspector

    @ViewBuilder
    private var inspector: some View {
        if let service = selectedService, let stack = selectedStack, let project = stack.project {
            serviceInspector(service: service, stack: stack, project: project)
        } else if let stack = selectedStack, let project = stack.project {
            projectInspector(stack: stack, project: project)
        } else {
            ContentUnavailableView {
                Label("No Stack Selected", systemImage: "square.stack.3d.up")
            } description: {
                Text("Select a Compose project or service to inspect its Docker-reported configuration.")
            }
        }
    }

    private func serviceInspector(
        service: ContainerSummary,
        stack: ComposeGroup,
        project: String
    ) -> some View {
        Form {
            Section("Service") {
                LabeledContent("Name") {
                    Text(service.composeService ?? service.displayName)
                        .textSelection(.enabled)
                }
                LabeledContent("Project", value: project)
                LabeledContent("Container ID") {
                    Text(service.shortID)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("Image") {
                    Text(service.image)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                LabeledContent("Status", value: service.status.isEmpty ? service.state.capitalized : service.status)
                LabeledContent("Created", value: Formatters.absoluteDate(service.createdAt))
            }

            composeMetadataSection(project: project)

            if !service.ports.isEmpty {
                Section("Ports") {
                    ForEach(service.ports) { port in
                        LabeledContent("\(port.containerPort)/\(port.proto)", value: port.hostPort.map(String.init) ?? "Not published")
                    }
                }
            }
        }
        .task(id: stack.id) {
            metadata.load(project: project, containerID: service.id, client: model.client)
        }
    }

    private func projectInspector(stack: ComposeGroup, project: String) -> some View {
        Form {
            Section("Project") {
                LabeledContent("Name", value: project)
                LabeledContent("Services", value: "\(stack.containers.count)")
                LabeledContent("Running", value: "\(stack.runningCount) of \(stack.containers.count)")
            }

            composeMetadataSection(project: project)
        }
        .task(id: stack.id) {
            if let service = stack.containers.first {
                metadata.load(project: project, containerID: service.id, client: model.client)
            }
        }
    }

    @ViewBuilder
    private func composeMetadataSection(project: String) -> some View {
        Section("Compose") {
            if let directory = metadata.workingDirectories[project] {
                LabeledContent("Working directory") {
                    Text(directory)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
            }
            if let files = metadata.configFiles[project], !files.isEmpty {
                DisclosureGroup("Compose Files (\(files.count))", isExpanded: $composeFilesExpanded) {
                    ForEach(files, id: \.self) { file in
                        Text(file)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            } else if metadata.configFiles[project] != nil {
                LabeledContent("Compose files", value: "Not reported")
            }
        }
    }

    // MARK: Native menus and action items

    @ViewBuilder
    private func contextMenu(for ids: Set<StackOutlineID>) -> some View {
        if let selected = ids.first {
            switch selected {
            case .project(let id):
                if let stack = stacks.first(where: { $0.id == id }) {
                    projectActionItems(for: stack, hidingUnavailableActions: true)
                }
            case .service(let id):
                if let service = services.first(where: { $0.id == id }),
                    let stack = stacks.first(where: { $0.project == service.composeProject })
                {
                    if !isServiceBusy(service), !isProjectBusy(for: service) {
                        serviceActionItems(for: service)
                        Menu("Project Actions") {
                            projectActionItems(for: stack, hidingUnavailableActions: true)
                        }
                        Divider()
                    }
                    Button("Open in Containers") {
                        TrackDAppBridge.reveal(containerID: service.id, in: model)
                    }
                    Button("View Logs") {
                        TrackDAppBridge.reveal(containerID: service.id, in: model, showingLogs: true)
                    }
                    if let url = service.ports.compactMap(\.url).first {
                        Button("Open Published Port") { NSWorkspace.shared.open(url) }
                    }
                    if canRemove(service) {
                        Divider()
                        Button("Remove Service…", role: .destructive) { removalTarget = service }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func serviceActionItems(for service: ContainerSummary) -> some View {
        if isServiceBusy(service) {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Updating \(service.composeService ?? service.displayName)")
        } else {
            ForEach(service.availableActions.filter { !$0.isDestructive }, id: \.rawValue) { action in
                Button(action.title) { perform(action, on: service) }
                    .disabled(isProjectBusy(for: service))
            }
        }
    }

    @ViewBuilder
    private func projectActionItems(
        for stack: ComposeGroup,
        hidingUnavailableActions: Bool = false
    ) -> some View {
        if busyProjects.contains(stack.id) {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Updating \(stack.title)")
        } else {
            let startTargets = projectLifecycleTargets(.start, in: stack)
            let runningTargets = projectLifecycleTargets(.stop, in: stack)
            if !hidingUnavailableActions || !startTargets.isEmpty {
                Button(projectLifecycleMenuTitle(.start, count: startTargets.count)) {
                    requestProjectLifecycleAction(.start, on: stack)
                }
                .disabled(startTargets.isEmpty)
            }
            if !hidingUnavailableActions || !runningTargets.isEmpty {
                Button(projectLifecycleMenuTitle(.restart, count: runningTargets.count)) {
                    requestProjectLifecycleAction(.restart, on: stack)
                }
                .disabled(runningTargets.isEmpty)
                Button(projectLifecycleMenuTitle(.stop, count: runningTargets.count)) {
                    requestProjectLifecycleAction(.stop, on: stack)
                }
                .disabled(runningTargets.isEmpty)
            }

            if let project = stack.project,
                let file = metadata.configFiles[project]?.first
            {
                Divider()
                Button("Copy Compose File Path") { MorbPasteboard.copy(file) }
            }
            Divider()
            Button("Edit Compose File…") { chooseComposeFile() }
                .disabled(composeFileEditor.isPresented)
            Button("Edit Project Environment File…") { chooseProjectEnvironmentFile() }
                .disabled(composeFileEditor.isPresented)
        }
    }

    // MARK: Empty states

    private var engineEmptyState: some View {
        ContentUnavailableView {
            Label("The Engine Isn’t Running", systemImage: "bolt.horizontal")
        } description: {
            Text("Start the Morbstack engine to discover Compose projects and manage their services.")
        } actions: {
            Button("Start Engine") {
                Task { await model.engineAction(.start) }
            }
            .disabled(model.engine.isTransitional)
        }
    }

    private var noStacksEmptyState: some View {
        ContentUnavailableView {
            Label("No Compose Stacks", systemImage: "square.stack.3d.up")
        } description: {
            Text("Services started with docker compose appear here automatically, grouped by their standard Compose project label.")
        } actions: {
            Button("Refresh") {
                Task { await model.refreshAll() }
            }
            Menu("Source and Context") {
                Button("Choose Compose File…") {
                    chooseComposeFile()
                }
                .disabled(composeFileEditor.isPresented)
                Button("Choose Project Environment File…") {
                    chooseProjectEnvironmentFile()
                }
                .disabled(composeFileEditor.isPresented)
                Divider()
                Button("Copy Docker Context Command") {
                    MorbPasteboard.copy(TrackDLinks.dockerContextCommand(socketPath: MorbPaths.dockerSocket.path))
                }
            }
        }
    }

    // MARK: Actions

    private func perform(_ action: ContainerAction, on service: ContainerSummary) {
        guard service.availableActions.contains(action), !isServiceBusy(service), !isProjectBusy(for: service) else { return }
        busyServices.insert(service.id)
        Task { @MainActor in
            await model.containerAction(action, id: service.id)
            busyServices.remove(service.id)
            if action == .remove, selection == .service(service.id) { selection = nil }
        }
    }

    private func projectLifecycleTargets(
        _ action: ContainerAction,
        in stack: ComposeGroup
    ) -> [ContainerSummary] {
        switch action {
        case .start:
            // `dead`, `paused`, and `restarting` are not stopped services Docker can
            // start.  Selecting by the single-container contract prevents one
            // defunct member from failing a project recovery after earlier members
            // have already started.
            return stack.containers.filter { $0.availableActions.contains(.start) }
        case .stop, .restart:
            // Docker's restart endpoint applies only to a currently running
            // container. Treating stopped services as restart targets produced a
            // misleading partial project operation.
            return stack.containers.filter(\.isRunning)
        default:
            return []
        }
    }

    private func projectLifecycleMenuTitle(_ action: ContainerAction, count: Int) -> String {
        let service = count == 1 ? "Service" : "Services"
        switch action {
        case .start: return "Start \(count) Stopped \(service)"
        case .stop: return "Stop \(count) Running \(service)"
        case .restart: return "Restart \(count) Running \(service)"
        default: return action.title
        }
    }

    private func requestProjectLifecycleAction(_ action: ContainerAction, on stack: ComposeGroup) {
        let targets = projectLifecycleTargets(action, in: stack)
        guard !targets.isEmpty, !busyProjects.contains(stack.id) else { return }
        projectLifecycleReview = ProjectLifecycleReview(
            action: action,
            projectID: stack.id,
            projectName: stack.title,
            targetIDs: Set(targets.map(\.id)))
    }

    private func projectLifecycleReviewTitle(_ review: ProjectLifecycleReview) -> String {
        projectLifecycleMenuTitle(review.action, count: review.targetCount) + "?"
    }

    private func projectLifecycleReviewMessage(_ review: ProjectLifecycleReview) -> String {
        let service = review.targetCount == 1 ? "service" : "services"
        switch review.action {
        case .start:
            return "This starts \(review.targetCount) existing stopped \(service) in \(review.projectName). It does not run docker compose, read source files, build or pull images, or create and recreate services."
        case .stop:
            return "This stops \(review.targetCount) currently running \(service) in \(review.projectName). Their containers, images, networks, and named volumes are kept."
        case .restart:
            return "This restarts \(review.targetCount) currently running \(service) in \(review.projectName). Stopped, paused, and defunct services are not included."
        default:
            return "This updates the reviewed services in \(review.projectName)."
        }
    }

    private func confirmProjectLifecycleAction(_ review: ProjectLifecycleReview) {
        guard let stack = stacks.first(where: { $0.id == review.projectID }) else { return }
        run(review.action, on: stack, limitingTo: review.targetIDs)
    }

    private func run(
        _ action: ContainerAction,
        on stack: ComposeGroup,
        limitingTo targetIDs: Set<ContainerSummary.ID>? = nil
    ) {
        let targets = projectLifecycleTargets(action, in: stack).filter { service in
            targetIDs?.contains(service.id) ?? true
        }
        guard !targets.isEmpty, !busyProjects.contains(stack.id) else { return }

        busyProjects.insert(stack.id)
        Task { @MainActor in
            // Compose services may have start-order dependencies. Keep this sequence
            // deterministic rather than racing every request against the engine.
            for service in targets {
                await model.containerAction(action, id: service.id)
            }
            busyProjects.remove(stack.id)
        }
    }

    private func isServiceBusy(_ service: ContainerSummary) -> Bool {
        busyServices.contains(service.id)
    }

    private func isProjectBusy(for service: ContainerSummary) -> Bool {
        guard let project = service.composeProject else { return false }
        return busyProjects.contains(project)
    }

    private func stateSymbol(for service: ContainerSummary) -> String {
        switch service.state {
        case "running": "play.circle.fill"
        case "paused": "pause.circle.fill"
        case "restarting": "arrow.triangle.2.circlepath.circle.fill"
        case "dead": "xmark.circle.fill"
        default: "stop.circle.fill"
        }
    }

    private func serviceMatchesQuery(_ service: ContainerSummary, needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        return service.displayName.localizedCaseInsensitiveContains(needle)
            || (service.composeService ?? "").localizedCaseInsensitiveContains(needle)
            || service.image.localizedCaseInsensitiveContains(needle)
            || service.status.localizedCaseInsensitiveContains(needle)
    }

    private func reconcileSelectionWithVisibleRows() {
        guard let selection, !visibleRowIDs.contains(selection) else { return }
        self.selection = nil
    }

    /// The project label shown in the inspector is observational Docker metadata. A
    /// native Open panel is the only way this app obtains a source URL, and choosing it
    /// never runs Compose, reloads a stack, deploys changes, or writes any file. The
    /// editor revalidates this selection before opening it.
    private func chooseComposeFile() {
        guard !composeFileEditor.isPresented else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ComposeFileEditor.yamlContentTypes
        panel.allowsOtherFileTypes = false
        panel.message = "Choose one Compose YAML source file to edit. Morbstack will not deploy or run it."
        panel.prompt = "Edit"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        composeFileEditor.open(url, as: .composeYAML)
    }

    /// A `.env` document is never presumed to be the selected stack's sibling. Docker
    /// Compose can use an explicit `--env-file`, project-directory discovery, or other
    /// precedence inputs, so only a person-chosen literal `.env` file enters this
    /// local editor. Opening it is not an interpolation, credentials, or deployment
    /// operation.
    private func chooseProjectEnvironmentFile() {
        guard !composeFileEditor.isPresented else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        // A literal `.env` is hidden by Finder defaults. This panel exists only for
        // that explicit document choice, so show dotfiles rather than requiring a
        // separate Finder shortcut that could make the action look unavailable.
        panel.showsHiddenFiles = true
        panel.message = "Choose one project's .env file to inspect or edit. Morbstack will not apply, interpolate, or run it."
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        composeFileEditor.open(url, as: .projectEnvironment)
    }

    private func portDescription(for service: ContainerSummary) -> String {
        guard !service.ports.isEmpty else { return "—" }
        return service.ports.map(\.label).joined(separator: ", ")
    }
}
