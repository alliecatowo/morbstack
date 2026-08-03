// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Kubernetes is operational data, so its primary surface is a standard macOS table.
// The navigation split view owns the surrounding chrome; this file deliberately owns
// only resource selection, data presentation, and lifecycle commands.

import Foundation
import MorbstackKit
import SwiftUI

private enum KubernetesResource: String, CaseIterable, Identifiable {
    case pods = "Pods"
    case nodes = "Nodes"

    var id: Self { self }
}

private enum KubernetesLifecycleRequest: Hashable, Identifiable {
    case enable
    case disable

    var id: Self { self }

    var title: String {
        switch self {
        case .enable: "Enable Kubernetes?"
        case .disable: "Disable Kubernetes?"
        }
    }

    var message: String {
        switch self {
        case .enable:
            "Morbstack will start its local single-node k3s cluster. The first start downloads the k3s payload."
        case .disable:
            "This stops the local k3s control plane. Docker containers that Kubernetes does not manage keep running."
        }
    }
}

/// A standard sheet for the daemon's read-only recovery diagnosis. This is a Form,
/// not an alert: the user can inspect several persistent facts and choose a real next
/// action without an interruption designed for an immediate confirmation.
private struct KubernetesDiagnosisSheet: View {

    let diagnosis: K8s.Diagnosis
    let performAction: (K8s.Diagnosis.RecommendedAction) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Cluster") {
                LabeledContent("Phase", value: diagnosis.status.phase.summary)
                LabeledContent("Nodes", value: "\(diagnosis.status.nodesReady) of \(diagnosis.status.nodes) ready")
                LabeledContent("Pods", value: "\(diagnosis.status.podsReady) of \(diagnosis.status.pods) ready")
                LabeledContent("API Forward") {
                    Text(diagnosis.hostAPIServerPort.map { "127.0.0.1:\($0)" } ?? "Not published")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("Kubeconfig", value: diagnosis.kubeconfigExists ? "Available" : "Not generated")
            }

            Section("Recovery") {
                LabeledContent("Recommended Action", value: diagnosis.recommendedAction.displayName)
                Text(diagnosis.summary)
                Text(diagnosis.guidance)
                    .foregroundStyle(.secondary)
                if let warning = diagnosis.persistenceWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
                if let title = diagnosis.recommendedAction.buttonTitle {
                    Button(title) {
                        performAction(diagnosis.recommendedAction)
                        dismiss()
                    }
                }
            }
        }
        .formStyle(.automatic)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 310, idealHeight: 360)
        .navigationTitle("Kubernetes Recovery")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

private enum KubernetesNodeSortKey {
    case name
    case ready
    case role
    case version
    case age
}

private struct KubernetesNodeComparator: SortComparator {
    var key: KubernetesNodeSortKey
    var order: SortOrder = .forward

    func compare(_ lhs: K8sNodeInfo, _ rhs: K8sNodeInfo) -> ComparisonResult {
        let result: ComparisonResult
        switch key {
        case .name:
            result = lhs.name.localizedStandardCompare(rhs.name)
        case .ready:
            result = lhs.ready == rhs.ready
                ? lhs.name.localizedStandardCompare(rhs.name)
                : (lhs.ready ? .orderedDescending : .orderedAscending)
        case .role:
            result = lhs.roleLabel.localizedStandardCompare(rhs.roleLabel)
        case .version:
            result = lhs.version.localizedStandardCompare(rhs.version)
        case .age:
            result = optionalComparison(lhs.age, rhs.age, tieBreak: lhs.name.localizedStandardCompare(rhs.name))
        }
        return order == .forward ? result : result.reversed
    }
}

private enum KubernetesPodSortKey {
    case name
    case namespace
    case phase
    case ready
    case restarts
    case node
    case age
}

private struct KubernetesPodComparator: SortComparator {
    var key: KubernetesPodSortKey
    var order: SortOrder = .forward

    func compare(_ lhs: K8sPodInfo, _ rhs: K8sPodInfo) -> ComparisonResult {
        let result: ComparisonResult
        switch key {
        case .name:
            result = lhs.name.localizedStandardCompare(rhs.name)
        case .namespace:
            result = lhs.namespace.localizedStandardCompare(rhs.namespace)
        case .phase:
            result = lhs.phase.label.localizedStandardCompare(rhs.phase.label)
        case .ready:
            result = comparison(lhs.readyContainers, rhs.readyContainers, tieBreak: lhs.name.localizedStandardCompare(rhs.name))
        case .restarts:
            result = comparison(lhs.restarts, rhs.restarts, tieBreak: lhs.name.localizedStandardCompare(rhs.name))
        case .node:
            result = lhs.nodeLabel.localizedStandardCompare(rhs.nodeLabel)
        case .age:
            result = optionalComparison(lhs.age, rhs.age, tieBreak: lhs.name.localizedStandardCompare(rhs.name))
        }
        return order == .forward ? result : result.reversed
    }
}

private func comparison<T: Comparable>(_ lhs: T, _ rhs: T, tieBreak: ComparisonResult) -> ComparisonResult {
    if lhs == rhs { return tieBreak }
    return lhs < rhs ? .orderedAscending : .orderedDescending
}

private func optionalComparison<T: Comparable>(
    _ lhs: T?, _ rhs: T?, tieBreak: ComparisonResult
) -> ComparisonResult {
    switch (lhs, rhs) {
    case (nil, nil): tieBreak
    case (nil, _): .orderedAscending
    case (_, nil): .orderedDescending
    case let (left?, right?): comparison(left, right, tieBreak: tieBreak)
    }
}

struct KubernetesRootView: View {

    let model: AppModel
    private var provider: any K8sClusterProviding { model.kubernetes }

    @State private var status = K8s.Status(phase: .stopped)
    @State private var nodes: [K8sNodeInfo] = []
    @State private var pods: [K8sPodInfo] = []
    @State private var resource: KubernetesResource = .pods
    @State private var query = ""
    @State private var nodeSortOrder: [KubernetesNodeComparator] = [
        KubernetesNodeComparator(key: .name),
    ]
    @State private var podSortOrder: [KubernetesPodComparator] = [
        KubernetesPodComparator(key: .namespace),
        KubernetesPodComparator(key: .name),
    ]
    @State private var selectedNodeID: K8sNodeInfo.ID?
    @State private var selectedPodID: K8sPodInfo.ID?
    @State private var selectedPodContainerName = ""
    @State private var podEvents: [K8sPodEventInfo] = []
    @State private var podEventsError: String?
    @State private var isLoadingPodEvents = false
    @State private var podEventsRequestID = UUID()
    @State private var podLog = ""
    @State private var podLogError: String?
    @State private var isLoadingPodLog = false
    @State private var podLogRequestID = UUID()
    @State private var resourceDescription: K8s.ResourceDescription?
    @State private var resourceDescriptionError: String?
    @State private var isLoadingResourceDescription = false
    @State private var resourceDescriptionRequestID = UUID()
    @State private var showsInspector = true
    @State private var lifecycleRequest: KubernetesLifecycleRequest?
    /// A confirmed enable/disable request is still in progress until the daemon
    /// replies with its authoritative status. Keep that short transition separate
    /// from the guest-reported `.starting` phase: the former prevents duplicate
    /// mutations, while the latter describes real k3s readiness after the request.
    @State private var lifecycleInFlight: KubernetesLifecycleRequest?
    @State private var kubeconfigCopied = false
    @State private var hasKubeconfig = false
    @State private var isGeneratingKubeconfig = false
    @State private var diagnosis: K8s.Diagnosis?
    @State private var showsRecoveryGuidance = false
    @State private var isDiagnosing = false
    @State private var clusterError: String?
    @State private var resourceError: String?
    @State private var resourceNeedsKubeconfig = false

    private var subtitle: String {
        guard model.engine.isRunning else { return "Engine stopped" }
        switch status.phase {
        case .ready:
            return "\(status.nodesReady) of \(status.nodes) nodes ready · \(status.podsReady) of \(status.pods) pods ready"
        case .starting:
            return "Starting Kubernetes"
        case .stopped, .notInstalled:
            return "Off"
        }
    }

    /// The guest's status message is the authoritative explanation for a cluster
    /// that is still starting (for example, an API server that has not answered or a
    /// node that has not become Ready). Keep it in the system unavailable state
    /// instead of replacing it with generic progress copy.
    private var startingDetail: String {
        let detail = status.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else {
            return "Setting up k3s and waiting for its node to report ready."
        }
        return "Kubernetes is still starting. \(detail)"
    }

    /// Pods, nodes, and their search scope are meaningful only after the guest has
    /// reported a Ready cluster. The explicit lifecycle state also keeps the old
    /// ready-table controls out of the toolbar while a disable is being confirmed.
    private var resourceControlsAreAvailable: Bool {
        model.engine.isRunning && status.phase == .ready && lifecycleInFlight == nil
    }

    private var lifecycleProgressTitle: String {
        switch lifecycleInFlight {
        case .enable:
            "Enabling Kubernetes"
        case .disable:
            "Disabling Kubernetes"
        case nil:
            "Updating Kubernetes"
        }
    }

    private var lifecycleProgressDetail: String {
        switch lifecycleInFlight {
        case .enable:
            "Morbstack is waiting for the guest daemon to confirm that the local k3s cluster was enabled."
        case .disable:
            "Morbstack is waiting for the guest daemon to confirm that the local k3s control plane stopped."
        case nil:
            "Morbstack is waiting for the guest daemon to report Kubernetes status."
        }
    }

    private var filteredNodes: [K8sNodeInfo] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nodes }
        return nodes.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
                || $0.roleLabel.localizedCaseInsensitiveContains(needle)
                || $0.version.localizedCaseInsensitiveContains(needle)
        }
    }

    private var filteredPods: [K8sPodInfo] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return pods }
        return pods.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
                || $0.namespace.localizedCaseInsensitiveContains(needle)
                || $0.node.localizedCaseInsensitiveContains(needle)
                || $0.phase.label.localizedCaseInsensitiveContains(needle)
        }
    }

    private var selectedNode: K8sNodeInfo? {
        nodes.first { $0.id == selectedNodeID }
    }

    private var selectedPod: K8sPodInfo? {
        pods.first { $0.id == selectedPodID }
    }

    private var selectedResourceReference: K8s.ResourceReference? {
        if let pod = selectedPod {
            return K8s.ResourceReference(kind: .pod, name: pod.name, namespace: pod.namespace)
        }
        if let node = selectedNode {
            return K8s.ResourceReference(kind: .node, name: node.name)
        }
        return nil
    }

    /// Search scopes the active table, not merely its visible cells. When a selected
    /// record is outside that scope, clear the native selection so the inspector shows
    /// its normal no-selection state instead of metadata for a hidden row.
    private func reconcileSelectionWithVisibleResource() {
        switch resource {
        case .pods:
            guard let selectedPodID,
                !filteredPods.contains(where: { $0.id == selectedPodID })
            else { return }
            self.selectedPodID = nil
        case .nodes:
            guard let selectedNodeID,
                !filteredNodes.contains(where: { $0.id == selectedNodeID })
            else { return }
            self.selectedNodeID = nil
        }
    }

    var body: some View {
        contentWithAvailableResourceControls
            .navigationTitle("Kubernetes")
            .navigationSubtitle(subtitle)
            .toolbar { toolbarContent }
            .confirmationDialog(
                lifecycleRequest?.title ?? "",
                isPresented: Binding(
                    get: { lifecycleRequest != nil },
                    set: { if !$0 { lifecycleRequest = nil } }
                ),
                titleVisibility: .visible,
                presenting: lifecycleRequest
            ) { request in
                switch request {
                case .enable:
                    Button("Enable Kubernetes") { confirmLifecycle(request) }
                case .disable:
                    Button("Disable Kubernetes", role: .destructive) { confirmLifecycle(request) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { request in
                Text(request.message)
            }
            .sheet(isPresented: $showsRecoveryGuidance) {
                if let diagnosis {
                    KubernetesDiagnosisSheet(diagnosis: diagnosis, performAction: performRecoveryAction)
                }
            }
            .task(id: model.engine.isRunning) {
                await refreshCluster()
            }
            // Opening this route after the engine has already begun bringing k3s up
            // should not leave a static “Starting” screen. The guest's phase remains
            // authoritative; this task only polls while it says the transition is in
            // progress and is cancelled automatically when the route or phase changes.
            .task(id: "\(model.engine.isRunning)-\(status.phase.rawValue)") {
                guard model.engine.isRunning, status.phase == .starting else { return }
                await settle()
            }
            .onChange(of: resource) {
                selectedNodeID = nil
                selectedPodID = nil
                clearPodObservation()
            }
            .onChange(of: query) {
                reconcileSelectionWithVisibleResource()
            }
    }

    /// Search is a scoped control for the active ready-cluster table. Do not leave a
    /// disabled-looking search field or resource picker above an unavailable state.
    @ViewBuilder
    private var contentWithAvailableResourceControls: some View {
        if resourceControlsAreAvailable {
            content.searchable(
                text: $query,
                placement: .toolbar,
                prompt: "Search \(resource.rawValue.lowercased())")
        } else {
            content
        }
    }

    // MARK: - System toolbar commands

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if resourceControlsAreAvailable {
            ToolbarItem(id: "kubernetes.resources", placement: .navigation) {
                Picker("Kubernetes resource", selection: $resource) {
                    ForEach(KubernetesResource.allCases) { resource in
                        Text(resource.rawValue).tag(resource)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Kubernetes resource")
            }
        }

        ToolbarItem(id: "kubernetes.refresh", placement: .secondaryAction) {
            Button {
                Task { await refreshCluster() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("Refresh Kubernetes resources")
            .help("Refresh Kubernetes resources")
            .disabled(!model.engine.isRunning)
        }

        ToolbarItem(id: "kubernetes.actions", placement: .secondaryAction) {
            Menu {
                if status.enabled {
                    Button("Disable Kubernetes", role: .destructive) {
                        lifecycleRequest = .disable
                    }
                } else {
                    Button("Enable Kubernetes") {
                        lifecycleRequest = .enable
                    }
                }
                Divider()
                Button("Diagnose Kubernetes") {
                    Task { await presentRecoveryGuidance() }
                }
                .disabled(isDiagnosing)
                Button("Generate Kubeconfig") {
                    Task { await generateKubeconfig() }
                }
                .disabled(status.phase != .ready || isGeneratingKubeconfig)
                Button("Copy Kubeconfig Path") {
                    copyKubeconfigPath()
                }
                .disabled(!hasKubeconfig)
            } label: {
                Image(systemName: kubeconfigCopied ? "checkmark" : "ellipsis.circle")
            }
            .accessibilityLabel("Kubernetes actions")
            .help("Kubernetes actions")
            // The request-in-flight unavailable state already owns lifecycle feedback.
            // Re-enable this menu after the daemon replies so a cluster that remains
            // in `.starting` still exposes its real, reversible disable action.
            .disabled(!model.engine.isRunning || lifecycleInFlight != nil)
        }

        if resourceControlsAreAvailable {
            ToolbarItem(id: "kubernetes.inspector", placement: .primaryAction) {
                Button {
                    showsInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .accessibilityLabel(showsInspector ? "Hide inspector" : "Show inspector")
                .help(showsInspector ? "Hide inspector" : "Show inspector")
            }
        }
    }

    private func confirmLifecycle(_ request: KubernetesLifecycleRequest) {
        guard lifecycleInFlight == nil else { return }
        lifecycleRequest = nil
        clusterError = nil
        lifecycleInFlight = request
        Task {
            defer { lifecycleInFlight = nil }
            do {
                status = try await provider.setEnabled(request == .enable)
                clusterError = nil
                await refreshCluster()
            } catch {
                clusterError = MorbErrorMessage.text(for: error)
            }
        }
    }

    private func copyKubeconfigPath() {
        guard hasKubeconfig else { return }
        MorbPasteboard.copy(K8s.defaultKubeconfigURL.path)
        kubeconfigCopied = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            kubeconfigCopied = false
        }
    }

    private func generateKubeconfig() async {
        guard !isGeneratingKubeconfig else { return }
        isGeneratingKubeconfig = true
        defer { isGeneratingKubeconfig = false }
        do {
            let path = try await provider.generateKubeconfig()
            hasKubeconfig = FileManager.default.fileExists(atPath: path.path)
            resourceError = nil
            resourceNeedsKubeconfig = false
            await refreshCluster()
        } catch {
            resourceError = MorbErrorMessage.text(for: error)
        }
    }

    private func refreshCluster() async {
        do {
            let diagnosis = try await provider.diagnosis()
            self.diagnosis = diagnosis
            status = diagnosis.status
            hasKubeconfig = diagnosis.kubeconfigExists
            clusterError = nil
            await reloadResources()
        } catch {
            nodes = []
            pods = []
            selectedNodeID = nil
            selectedPodID = nil
            clearPodObservation()
            diagnosis = nil
            clusterError = MorbErrorMessage.text(for: error)
        }
    }

    /// Poll only while the provider reports an in-progress transition. The provider is
    /// authoritative for readiness; the view does not invent a second lifecycle state.
    private func settle() async {
        while !Task.isCancelled, status.phase == .starting {
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            do {
                let diagnosis = try await provider.diagnosis()
                self.diagnosis = diagnosis
                status = diagnosis.status
                hasKubeconfig = diagnosis.kubeconfigExists
                clusterError = nil
            } catch {
                diagnosis = nil
                clusterError = MorbErrorMessage.text(for: error)
                return
            }
        }
        guard !Task.isCancelled else { return }
        await reloadResources()
    }

    /// Request a fresh, daemon-authored recovery report before presenting it. The app
    /// never derives actions from stale table data or starts/stops Kubernetes merely
    /// because the user asked to inspect its state.
    private func presentRecoveryGuidance() async {
        guard !isDiagnosing else { return }
        isDiagnosing = true
        defer { isDiagnosing = false }
        await refreshCluster()
        guard diagnosis != nil, clusterError == nil else { return }
        showsRecoveryGuidance = true
    }

    private func performRecoveryAction(_ action: K8s.Diagnosis.RecommendedAction) {
        switch action {
        case .enableKubernetes:
            lifecycleRequest = .enable
        case .refreshStatus:
            Task { await refreshCluster() }
        case .generateKubeconfig:
            Task { await generateKubeconfig() }
        case .none:
            break
        }
    }

    private func reloadResources() async {
        guard status.phase == .ready else {
            nodes = []
            pods = []
            selectedNodeID = nil
            selectedPodID = nil
            clearPodObservation()
            return
        }
        do {
            let resources = try await provider.resources()
            nodes = resources.nodes
            pods = resources.pods
            resourceError = nil
            resourceNeedsKubeconfig = false
        } catch let error as K8sResourceAccessError {
            nodes = []
            pods = []
            clearPodObservation()
            resourceError = error.localizedDescription
            if case .kubeconfigRequired = error {
                resourceNeedsKubeconfig = true
            } else {
                resourceNeedsKubeconfig = false
            }
        } catch {
            nodes = []
            pods = []
            clearPodObservation()
            resourceError = MorbErrorMessage.text(for: error)
            resourceNeedsKubeconfig = false
        }
        if !nodes.contains(where: { $0.id == selectedNodeID }) { selectedNodeID = nil }
        if !pods.contains(where: { $0.id == selectedPodID }) {
            selectedPodID = nil
            clearPodObservation()
        } else if let pod = selectedPod {
            preparePodObservation(for: pod)
        } else if let node = selectedNode {
            prepareResourceDescription(
                for: K8s.ResourceReference(kind: .node, name: node.name))
        } else {
            clearResourceDescription()
        }
        reconcileSelectionWithVisibleResource()
    }

    // MARK: - Selected-pod observability

    /// The list is the source of the selected record's identity and regular-container
    /// inventory. Logs and events remain independent reads so one unavailable
    /// Kubernetes subresource never hides the other or turns a read into a mutation.
    private func preparePodObservation(for pod: K8sPodInfo) {
        podEventsRequestID = UUID()
        podLogRequestID = UUID()
        selectedPodContainerName = pod.containers.first?.name ?? ""
        podEvents = []
        podEventsError = nil
        podLog = ""
        podLogError = nil
        isLoadingPodEvents = false
        isLoadingPodLog = false

        prepareResourceDescription(
            for: K8s.ResourceReference(kind: .pod, name: pod.name, namespace: pod.namespace))
        Task { await loadPodEvents(for: pod) }
        if let container = pod.containers.first {
            Task { await loadPodLog(for: pod, container: container.name) }
        }
    }

    private func clearPodObservation() {
        podEventsRequestID = UUID()
        podLogRequestID = UUID()
        selectedPodContainerName = ""
        podEvents = []
        podEventsError = nil
        isLoadingPodEvents = false
        podLog = ""
        podLogError = nil
        isLoadingPodLog = false
        clearResourceDescription()
    }

    // MARK: - Selected-resource description

    /// The record selected in the native Table supplies the only describe target. The
    /// daemon accepts a fixed Pod/Node GET contract and revalidates that target; the
    /// app never constructs arbitrary Kubernetes paths or falls back to stale details.
    private func prepareResourceDescription(for reference: K8s.ResourceReference) {
        resourceDescriptionRequestID = UUID()
        resourceDescription = nil
        resourceDescriptionError = nil
        isLoadingResourceDescription = false
        Task { await loadResourceDescription(for: reference) }
    }

    private func clearResourceDescription() {
        resourceDescriptionRequestID = UUID()
        resourceDescription = nil
        resourceDescriptionError = nil
        isLoadingResourceDescription = false
    }

    private func loadResourceDescription(for reference: K8s.ResourceReference) async {
        let requestID = resourceDescriptionRequestID
        guard selectedResourceReference == reference else { return }
        isLoadingResourceDescription = true
        resourceDescriptionError = nil
        defer {
            if resourceDescriptionRequestID == requestID {
                isLoadingResourceDescription = false
            }
        }
        do {
            let description = try await provider.describe(reference)
            guard resourceDescriptionRequestID == requestID,
                  selectedResourceReference == reference,
                  description.reference == reference
            else { return }
            resourceDescription = description
        } catch {
            guard resourceDescriptionRequestID == requestID,
                  selectedResourceReference == reference
            else { return }
            resourceDescriptionError = MorbErrorMessage.text(for: error)
        }
    }

    private func retryResourceDescription() {
        guard let reference = selectedResourceReference else { return }
        prepareResourceDescription(for: reference)
    }

    private func loadPodEvents(for pod: K8sPodInfo) async {
        let requestID = podEventsRequestID
        guard selectedPodID == pod.id else { return }
        isLoadingPodEvents = true
        podEventsError = nil
        defer {
            if selectedPodID == pod.id, podEventsRequestID == requestID {
                isLoadingPodEvents = false
            }
        }
        do {
            let events = try await provider.podEvents(for: pod)
            guard selectedPodID == pod.id, podEventsRequestID == requestID else { return }
            podEvents = events
        } catch {
            guard selectedPodID == pod.id, podEventsRequestID == requestID else { return }
            podEventsError = MorbErrorMessage.text(for: error)
        }
    }

    private func loadPodLog(for pod: K8sPodInfo, container: String) async {
        let requestID = podLogRequestID
        guard selectedPodID == pod.id, selectedPodContainerName == container else { return }
        isLoadingPodLog = true
        podLogError = nil
        defer {
            if selectedPodID == pod.id, selectedPodContainerName == container, podLogRequestID == requestID {
                isLoadingPodLog = false
            }
        }
        do {
            let log = try await provider.podLog(for: pod, container: container)
            guard selectedPodID == pod.id, selectedPodContainerName == container, podLogRequestID == requestID else { return }
            podLog = log
        } catch {
            guard selectedPodID == pod.id, selectedPodContainerName == container, podLogRequestID == requestID else { return }
            podLogError = MorbErrorMessage.text(for: error)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !model.engine.isRunning {
            ContentUnavailableView {
                Label("Kubernetes Needs the Engine", systemImage: "cube.transparent")
            } description: {
                Text("The cluster runs inside the same virtual machine as your containers. Start the engine to use Kubernetes.")
            } actions: {
                Button("Start Engine") {
                    Task { await model.engineAction(.start) }
                }
                .disabled(model.isEngineBusy)
            }
        } else if lifecycleInFlight != nil {
            lifecycleProgressState
        } else if let clusterError {
            ContentUnavailableView {
                Label("Kubernetes Is Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(clusterError)
            } actions: {
                Button("Refresh") { Task { await refreshCluster() } }
            }
        } else {
            switch status.phase {
            case .notInstalled, .stopped:
                kubernetesOffState
            case .starting:
                startingState
            case .ready:
                resourceTable
                    .inspector(isPresented: $showsInspector) {
                        inspector
                            .inspectorColumnWidth(min: 280, ideal: 340, max: 460)
                    }
            }
        }
    }

    /// The confirmation dialog has already received explicit user consent; this is
    /// the system unavailable/progress state while the daemon performs that one
    /// requested lifecycle write. It deliberately offers no second lifecycle action.
    private var lifecycleProgressState: some View {
        ContentUnavailableView {
            Label(lifecycleProgressTitle, systemImage: "cube.transparent")
        } description: {
            Text(lifecycleProgressDetail)
        } actions: {
            ProgressView()
                .controlSize(.small)
        }
    }

    private var kubernetesOffState: some View {
        ContentUnavailableView {
            Label("Kubernetes Is Off", systemImage: "cube.transparent")
        } description: {
            Text("Enable a local single-node k3s cluster in Morbstack’s virtual machine.")
        } actions: {
            Button("Enable Kubernetes") {
                lifecycleRequest = .enable
            }
        }
    }

    private var startingState: some View {
        ContentUnavailableView {
            Label("Starting Kubernetes", systemImage: "cube.transparent")
        } description: {
            Text(startingDetail)
        } actions: {
            ProgressView()
                .controlSize(.small)
            Button("View Recovery Guidance") { Task { await presentRecoveryGuidance() } }
        }
    }

    @ViewBuilder
    private var resourceTable: some View {
        if let resourceError {
            ContentUnavailableView {
                Label("Kubernetes Resources Are Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(resourceError)
            } actions: {
                Button("Refresh") { Task { await refreshCluster() } }
                Button(resourceNeedsKubeconfig ? "Generate Kubeconfig" : "Generate New Kubeconfig") {
                    Task { await generateKubeconfig() }
                }
                .disabled(isGeneratingKubeconfig)
            }
        } else {
            switch resource {
        case .pods:
            if filteredPods.isEmpty {
                emptyPodsState
            } else {
                podsTable
            }
        case .nodes:
            if filteredNodes.isEmpty {
                emptyNodesState
            } else {
                nodesTable
            }
        }
        }
    }

    @ViewBuilder
    private var emptyPodsState: some View {
        if query.isEmpty {
            ContentUnavailableView {
                Label("No Pods", systemImage: "shippingbox")
            } description: {
                Text("No pods are currently reported by this cluster.")
            } actions: {
                Button("Refresh") { Task { await refreshCluster() } }
            }
        } else {
            ContentUnavailableView.search(text: query)
        }
    }

    @ViewBuilder
    private var emptyNodesState: some View {
        if query.isEmpty {
            ContentUnavailableView {
                Label("No Nodes", systemImage: "server.rack")
            } description: {
                Text("No nodes are currently reported by this cluster.")
            } actions: {
                Button("Refresh") { Task { await refreshCluster() } }
            }
        } else {
            ContentUnavailableView.search(text: query)
        }
    }

    // MARK: - Tables

    private var podsTable: some View {
        Table(filteredPods, selection: $selectedPodID, sortOrder: $podSortOrder) {
            TableColumn("Name", sortUsing: KubernetesPodComparator(key: .name)) { pod in
                Text(pod.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 220, ideal: 280, max: 480)
            TableColumn("Namespace", sortUsing: KubernetesPodComparator(key: .namespace)) { pod in
                Text(pod.namespace)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 88, ideal: 110, max: 150)
            TableColumn("Status", sortUsing: KubernetesPodComparator(key: .phase)) { pod in
                Text(pod.phase.label)
            }
            .width(min: 120, ideal: 128, max: 180)
            TableColumn("Ready", sortUsing: KubernetesPodComparator(key: .ready)) { pod in
                Text("\(pod.readyContainers)/\(pod.totalContainers)")
                    .monospacedDigit()
            }
            .width(min: 48, ideal: 56, max: 64)
            TableColumn("Restarts", sortUsing: KubernetesPodComparator(key: .restarts)) { pod in
                Text(pod.restarts, format: .number)
                    .monospacedDigit()
            }
            .width(min: 56, ideal: 64, max: 72)
            TableColumn("Node", sortUsing: KubernetesPodComparator(key: .node)) { pod in
                Text(pod.nodeLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 92, ideal: 110, max: 150)
            TableColumn("Age", sortUsing: KubernetesPodComparator(key: .age)) { pod in
                if let age = pod.age {
                    Text(Formatters.compactDuration(since: age))
                        .monospacedDigit()
                        .help(Formatters.absoluteDate(age))
                } else {
                    Text("—")
                        .accessibilityLabel("Age unavailable")
                }
            }
            .width(min: 56, ideal: 64, max: 72)
        }
        .contextMenu(forSelectionType: K8sPodInfo.ID.self) { ids in
            if let id = ids.first, let pod = pods.first(where: { $0.id == id }) {
                Button("Copy Pod Name") { MorbPasteboard.copy(pod.name) }
                Button("Copy Namespace") { MorbPasteboard.copy(pod.namespace) }
            }
        } primaryAction: { ids in
            if let id = ids.first {
                selectedPodID = id
                selectedNodeID = nil
                showsInspector = true
            }
        }
        .onChange(of: selectedPodID) { _, selectedID in
            guard let selectedID, let pod = pods.first(where: { $0.id == selectedID }) else {
                clearPodObservation()
                return
            }
            selectedNodeID = nil
            showsInspector = true
            preparePodObservation(for: pod)
        }
    }

    private var nodesTable: some View {
        Table(filteredNodes, selection: $selectedNodeID, sortOrder: $nodeSortOrder) {
            TableColumn("Name", sortUsing: KubernetesNodeComparator(key: .name)) { node in
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 180, ideal: 260, max: 480)
            TableColumn("Status", sortUsing: KubernetesNodeComparator(key: .ready)) { node in
                Text(node.ready ? "Ready" : "Not Ready")
            }
            .width(min: 80, ideal: 96, max: 120)
            TableColumn("Role", sortUsing: KubernetesNodeComparator(key: .role)) { node in
                Text(node.roleLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 100, ideal: 150, max: 240)
            TableColumn("Version", sortUsing: KubernetesNodeComparator(key: .version)) { node in
                Text(node.version)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 130, ideal: 160, max: 220)
            TableColumn("Age", sortUsing: KubernetesNodeComparator(key: .age)) { node in
                if let age = node.age {
                    Text(Formatters.compactDuration(since: age))
                        .monospacedDigit()
                        .help(Formatters.absoluteDate(age))
                } else {
                    Text("—")
                        .accessibilityLabel("Age unavailable")
                }
            }
            .width(min: 70, ideal: 88, max: 110)
        }
        .contextMenu(forSelectionType: K8sNodeInfo.ID.self) { ids in
            if let id = ids.first, let node = nodes.first(where: { $0.id == id }) {
                Button("Copy Node Name") { MorbPasteboard.copy(node.name) }
            }
        } primaryAction: { ids in
            if let id = ids.first {
                selectedNodeID = id
                selectedPodID = nil
                showsInspector = true
            }
        }
        .onChange(of: selectedNodeID) { _, selectedID in
            guard let selectedID, let node = nodes.first(where: { $0.id == selectedID }) else {
                clearPodObservation()
                return
            }
            selectedPodID = nil
            clearPodObservation()
            prepareResourceDescription(for: K8s.ResourceReference(kind: .node, name: node.name))
            showsInspector = true
        }
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspector: some View {
        if let pod = selectedPod {
            Form {
                Section("Pod") {
                    LabeledContent("Name") {
                        Text(pod.name)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Namespace", value: pod.namespace)
                    LabeledContent("Status", value: pod.phase.label)
                    LabeledContent("Ready", value: "\(pod.readyContainers) of \(pod.totalContainers) containers")
                    LabeledContent("Restarts", value: "\(pod.restarts)")
                    LabeledContent("Node", value: pod.node.isEmpty ? "Not scheduled" : pod.node)
                    LabeledContent("Age", value: pod.age.map(Formatters.absoluteDate) ?? "Unavailable")
                }
                podContainersSection(for: pod)
                resourceDescriptionSections
                podLogSection(for: pod)
                podEventsSection
                Section("Actions") {
                    Button("Copy Pod Name") { MorbPasteboard.copy(pod.name) }
                    Button("Copy Namespace") { MorbPasteboard.copy(pod.namespace) }
                }
            }
            .formStyle(.columns)
        } else if let node = selectedNode {
            Form {
                Section("Node") {
                    LabeledContent("Name") {
                        Text(node.name)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Status", value: node.ready ? "Ready" : "Not Ready")
                    LabeledContent("Role", value: node.roleLabel)
                    LabeledContent("Version") {
                        Text(node.version)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    LabeledContent("Age", value: node.age.map(Formatters.absoluteDate) ?? "Unavailable")
                }
                resourceDescriptionSections
                Section("Actions") {
                    Button("Copy Node Name") { MorbPasteboard.copy(node.name) }
                }
            }
            .formStyle(.columns)
        } else {
            ContentUnavailableView {
                Label("No Selection", systemImage: "sidebar.right")
            } description: {
                Text("Select a row to view its details.")
            }
        }
    }

    /// A standard inspector Form for the daemon's fixed, real Kubernetes API GET.
    /// The Table's selection owns the identity; this section owns only the bounded
    /// description state, so an unavailable description never hides table metadata,
    /// logs, or events that came from different read-only endpoints.
    @ViewBuilder
    private var resourceDescriptionSections: some View {
        Section("Kubernetes API") {
            if isLoadingResourceDescription {
                ProgressView("Reading selected resource")
                    .controlSize(.small)
            } else if let resourceDescriptionError {
                Label(resourceDescriptionError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Button("Retry Description", action: retryResourceDescription)
            } else if let resourceDescription {
                LabeledContent("Kind", value: resourceDescription.reference.kind.displayName)
                LabeledContent("Name") {
                    Text(resourceDescription.reference.displayName)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                if let uid = resourceDescription.uid {
                    LabeledContent("UID") {
                        Text(uid)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                if let createdAt = resourceDescription.createdAt {
                    LabeledContent("Created", value: createdAt)
                }
                ForEach(resourceDescription.facts) { fact in
                    LabeledContent(fact.name) {
                        Text(fact.value)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            } else {
                Text("Select a Kubernetes resource to read its API description.")
                    .foregroundStyle(.secondary)
            }
        }

        if let resourceDescription, !resourceDescription.conditions.isEmpty {
            Section("Conditions") {
                ForEach(resourceDescription.conditions) { condition in
                    LabeledContent(condition.type, value: condition.status)
                    if let reason = condition.reason {
                        Text(reason)
                            .foregroundStyle(.secondary)
                    }
                    if let message = condition.message {
                        Text(message)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        if let resourceDescription, !resourceDescription.labels.isEmpty {
            Section("Labels") {
                ForEach(resourceDescription.labels) { label in
                    LabeledContent(label.name) {
                        Text(label.value)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            }
        }

        if let resourceDescription, !resourceDescription.annotations.isEmpty {
            Section("Annotations") {
                ForEach(resourceDescription.annotations) { annotation in
                    LabeledContent(annotation.name) {
                        Text(annotation.value)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func podContainersSection(for pod: K8sPodInfo) -> some View {
        Section("Containers") {
            if pod.containers.isEmpty {
                Text("No regular containers were returned by the Kubernetes API.")
                    .foregroundStyle(.secondary)
            } else {
                Picker(
                    "Container",
                    selection: Binding(
                        get: { selectedPodContainerName },
                        set: { container in
                            guard container != selectedPodContainerName else { return }
                            selectedPodContainerName = container
                            podLogRequestID = UUID()
                            podLog = ""
                            podLogError = nil
                            Task { await loadPodLog(for: pod, container: container) }
                        }
                    )
                ) {
                    ForEach(pod.containers) { container in
                        Text(container.name).tag(container.name)
                    }
                }
                .accessibilityLabel("Pod container")

                if let container = pod.containers.first(where: { $0.name == selectedPodContainerName }) {
                    LabeledContent("Image") {
                        Text(container.image)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Status", value: container.state)
                    LabeledContent("Ready", value: container.ready ? "Yes" : "No")
                    LabeledContent("Restarts", value: "\(container.restarts)")
                }
            }
        }
    }

    @ViewBuilder
    private func podLogSection(for pod: K8sPodInfo) -> some View {
        Section("Recent Log") {
            if pod.containers.isEmpty {
                Text("Logs are unavailable because the pod has no reported regular container.")
                    .foregroundStyle(.secondary)
            } else if isLoadingPodLog {
                ProgressView("Loading recent log")
                    .controlSize(.small)
            } else if let podLogError {
                Label(podLogError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Button("Retry Log") {
                    Task { await loadPodLog(for: pod, container: selectedPodContainerName) }
                }
                .disabled(selectedPodContainerName.isEmpty)
            } else if podLog.isEmpty {
                Text("No recent log output was returned by Kubernetes.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Most recent 200 lines. Kubernetes log retention applies.")
                    .foregroundStyle(.secondary)
                ScrollView([.horizontal, .vertical]) {
                    Text(podLog)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                }
                .frame(minHeight: 96, maxHeight: 220)
                .accessibilityLabel("Recent log for \(selectedPodContainerName)")
            }
        }
    }

    @ViewBuilder
    private var podEventsSection: some View {
        Section("Recent Events") {
            if isLoadingPodEvents {
                ProgressView("Loading recent events")
                    .controlSize(.small)
            } else if let podEventsError {
                Label(podEventsError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Button("Retry Events") {
                    guard let pod = selectedPod else { return }
                    Task { await loadPodEvents(for: pod) }
                }
            } else if podEvents.isEmpty {
                Text("No retained events were returned by Kubernetes for this pod.")
                    .foregroundStyle(.secondary)
            } else {
                if podEvents.count > 20 {
                    Text("Showing the 20 most recent of \(podEvents.count) retained events.")
                        .foregroundStyle(.secondary)
                }
                Table(podEvents.prefix(20)) {
                    TableColumn("Reason") { event in
                        Text(event.reason)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .width(min: 96, ideal: 128, max: 180)

                    TableColumn("Message") { event in
                        Text(event.message)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                    .width(min: 180, ideal: 280)

                    TableColumn("Type") { event in
                        Text(event.type)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .width(min: 60, ideal: 76, max: 100)

                    TableColumn("Times") { event in
                        Text(event.count, format: .number)
                            .monospacedDigit()
                    }
                    .width(min: 48, ideal: 56, max: 68)

                    TableColumn("Last Observed") { event in
                        Text(event.lastObserved.map(Formatters.absoluteDate) ?? "Unavailable")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .width(min: 120, ideal: 156, max: 220)
                }
                .tableStyle(.automatic)
                .frame(minHeight: 120, idealHeight: 180, maxHeight: 260)
                .accessibilityLabel("20 most recent Kubernetes events")
            }
        }
    }
}
