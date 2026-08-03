// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Kubernetes is operational data, so its primary surface is a standard macOS table.
// The navigation split view owns the surrounding chrome; this file deliberately owns
// only resource selection, data presentation, and lifecycle commands.

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
    @State private var showsInspector = true
    @State private var lifecycleRequest: KubernetesLifecycleRequest?
    @State private var kubeconfigCopied = false
    @State private var hasKubeconfig = false
    @State private var isGeneratingKubeconfig = false
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
        content
            .navigationTitle("Kubernetes")
            .navigationSubtitle(subtitle)
            .searchable(text: $query, placement: .toolbar, prompt: "Search \(resource.rawValue.lowercased())")
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
            .task(id: model.engine.isRunning) {
                await refreshCluster()
            }
            .onChange(of: resource) {
                selectedNodeID = nil
                selectedPodID = nil
            }
            .onChange(of: query) {
                reconcileSelectionWithVisibleResource()
            }
    }

    // MARK: - System toolbar commands

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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

        ToolbarItem(id: "kubernetes.refresh", placement: .secondaryAction) {
            Button {
                Task { await refreshCluster() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("Refresh Kubernetes resources")
            .help("Refresh Kubernetes resources")
            .disabled(!model.engine.isRunning || status.phase == .starting)
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
            .disabled(!model.engine.isRunning || status.phase == .starting)
        }

        if status.phase == .ready {
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
        lifecycleRequest = nil
        Task {
            do {
                status = try await provider.setEnabled(request == .enable)
                clusterError = nil
                await settle()
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
            await reloadResources()
        } catch {
            resourceError = MorbErrorMessage.text(for: error)
        }
    }

    private func refreshCluster() async {
        hasKubeconfig = FileManager.default.fileExists(atPath: K8s.defaultKubeconfigURL.path)
        do {
            status = try await provider.currentStatus()
            clusterError = nil
            await reloadResources()
        } catch {
            nodes = []
            pods = []
            selectedNodeID = nil
            selectedPodID = nil
            clusterError = MorbErrorMessage.text(for: error)
        }
    }

    /// Poll only while the provider reports an in-progress transition. The provider is
    /// authoritative for readiness; the view does not invent a second lifecycle state.
    private func settle() async {
        while status.phase == .starting {
            try? await Task.sleep(for: .milliseconds(350))
            do {
                status = try await provider.currentStatus()
                clusterError = nil
            } catch {
                clusterError = MorbErrorMessage.text(for: error)
                return
            }
        }
        await reloadResources()
    }

    private func reloadResources() async {
        guard status.phase == .ready else {
            nodes = []
            pods = []
            selectedNodeID = nil
            selectedPodID = nil
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
            resourceError = error.localizedDescription
            if case .kubeconfigRequired = error {
                resourceNeedsKubeconfig = true
            } else {
                resourceNeedsKubeconfig = false
            }
        } catch {
            nodes = []
            pods = []
            resourceError = MorbErrorMessage.text(for: error)
            resourceNeedsKubeconfig = false
        }
        if !nodes.contains(where: { $0.id == selectedNodeID }) { selectedNodeID = nil }
        if !pods.contains(where: { $0.id == selectedPodID }) { selectedPodID = nil }
        reconcileSelectionWithVisibleResource()
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
                Button(model.engine.state == "suspended" ? "Resume Engine" : "Start Engine") {
                    Task { await model.engineAction(.start) }
                }
                .disabled(model.isEngineBusy)
            }
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
            Text("Setting up k3s and waiting for its node to report ready.")
        } actions: {
            ProgressView()
                .controlSize(.small)
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
            TableColumn("Namespace", sortUsing: KubernetesPodComparator(key: .namespace)) { pod in
                Text(pod.namespace)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 100, ideal: 140, max: 220)
            TableColumn("Status", sortUsing: KubernetesPodComparator(key: .phase)) { pod in
                Text(pod.phase.label)
            }
            .width(min: 110, ideal: 140, max: 190)
            TableColumn("Ready", sortUsing: KubernetesPodComparator(key: .ready)) { pod in
                Text("\(pod.readyContainers)/\(pod.totalContainers)")
                    .monospacedDigit()
            }
            .width(min: 56, ideal: 64, max: 80)
            TableColumn("Restarts", sortUsing: KubernetesPodComparator(key: .restarts)) { pod in
                Text(pod.restarts, format: .number)
                    .monospacedDigit()
            }
            .width(min: 64, ideal: 76, max: 96)
            TableColumn("Node", sortUsing: KubernetesPodComparator(key: .node)) { pod in
                Text(pod.nodeLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 100, ideal: 140, max: 220)
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
            .width(min: 70, ideal: 88, max: 110)
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
            guard selectedID != nil else { return }
            selectedNodeID = nil
            showsInspector = true
        }
    }

    private var nodesTable: some View {
        Table(filteredNodes, selection: $selectedNodeID, sortOrder: $nodeSortOrder) {
            TableColumn("Name", sortUsing: KubernetesNodeComparator(key: .name)) { node in
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
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
            guard selectedID != nil else { return }
            selectedPodID = nil
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
}
