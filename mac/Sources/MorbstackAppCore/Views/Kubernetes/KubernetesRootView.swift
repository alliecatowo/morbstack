// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Kubernetes — a single-node k3s cluster living in the same VM as the containers.
//
// The screen has four states, and the state is the whole design: off (nothing has been
// asked for), starting (the payload is streaming in or the control plane is coming up),
// ready (a real cluster with nodes and pods to look at), and "the engine itself is not
// running" (Kubernetes cannot exist without the VM it lives in). Each is one clear
// picture rather than a table of zeroes pretending to be data — the same rule
// `EngineStoppedView` follows for the whole app.
//
// See `KubernetesModels.swift` for why this reads from a small protocol instead of a
// concrete client.

import MorbstackKit
import SwiftUI

struct KubernetesRootView: View {

    let model: AppModel
    var provider: any K8sClusterProviding = K8sFixtureClient()

    @State private var status = K8s.Status(phase: .stopped)
    @State private var nodes: [K8sNodeInfo] = []
    @State private var pods: [K8sPodInfo] = []
    @State private var podQuery = ""
    @State private var kubeconfigCopied = false

    /// Which row is selected — a node or a pod, never both. Two independent `Table`
    /// selections would leave the inspector unable to say which one is current, and the
    /// underlying bug this whole feature exists to fix is that neither table had a
    /// selection at all.
    @State private var selectedNodeID: K8sNodeInfo.ID?
    @State private var selectedPodID: K8sPodInfo.ID?
    @State private var showsInspector = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var filteredPods: [K8sPodInfo] {
        let needle = podQuery.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return pods }
        return pods.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
                || $0.namespace.localizedCaseInsensitiveContains(needle)
                || $0.node.localizedCaseInsensitiveContains(needle)
        }
    }

    private var subtitle: String {
        guard model.engine.isRunning else { return "Needs the engine" }
        switch status.phase {
        case .ready:
            return "\(status.nodesReady) of \(status.nodes) nodes ready · "
                + "\(status.podsReady) of \(status.pods) pods ready"
        case .starting: return "Starting the cluster…"
        case .stopped, .notInstalled: return "Off"
        }
    }

    var body: some View {
        content
            .morbScreen(title: "Kubernetes", subtitle: subtitle, edge: .hard)
            .searchable(text: $podQuery, placement: .toolbar, prompt: "Pod, namespace, node")
            .toolbar { toolbarContent }
            .task {
                status = await provider.currentStatus()
                await reloadResources()
            }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // A plain text button rather than a `Toggle(.switch)`: the system switch at its
        // default control size reads as an enormous, brightly-tinted control sitting
        // alone in the toolbar — the exact complaint. "Enable"/"Disable" says the same
        // thing a symbol cannot, at the size every other toolbar button is.
        ToolbarItem(id: "kubernetes.enable", placement: MorbToolbarGroup.actions) {
            Button {
                toggle(!status.enabled)
            } label: {
                Text(status.enabled ? "Disable" : "Enable")
            }
            .disabled(!model.engine.isRunning || status.phase == .starting)
            .help(model.engine.isRunning
                ? "Turn the local cluster on or off"
                : "Start the Morbstack engine first")
        }
        ToolbarItem(id: "kubernetes.kubeconfig", placement: MorbToolbarGroup.secondary) {
            MorbIconButton(
                kubeconfigCopied ? "checkmark" : "doc.on.doc",
                help: "Copy the kubeconfig path (\(K8s.defaultKubeconfigURL.path))"
            ) {
                trackDCopy(K8s.defaultKubeconfigURL.path)
                kubeconfigCopied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    kubeconfigCopied = false
                }
            }
            .disabled(status.phase != .ready)
        }
        if status.phase == .ready {
            MorbInspectorToggle(id: "kubernetes.inspector", isPresented: $showsInspector)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { status.enabled }, set: { toggle($0) })
    }

    private func toggle(_ enabled: Bool) {
        Task {
            status = await provider.setEnabled(enabled)
            await settle()
        }
    }

    /// Polls while the cluster is coming up, the same shape `EngineStoppedView` uses
    /// for the VM itself — a short, bounded loop rather than an open-ended stream,
    /// because "is a node Ready yet" is cheap to ask and does not need a socket held
    /// open for it.
    private func settle() async {
        while status.phase == .starting {
            try? await Task.sleep(for: .milliseconds(350))
            status = await provider.currentStatus()
        }
        await reloadResources()
    }

    private func reloadResources() async {
        guard status.phase == .ready else {
            nodes = []
            pods = []
            return
        }
        nodes = await provider.nodes()
        pods = await provider.pods()
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !model.engine.isRunning {
            MorbEmptyState(
                "Kubernetes needs the engine",
                systemImage: "cube.transparent",
                description: "The cluster runs inside the same virtual machine as your containers. "
                    + "Start the engine first, then come back here.")
        } else {
            switch status.phase {
            case .notInstalled, .stopped: offState
            case .starting: startingState
            case .ready: readyState
            }
        }
    }

    private var offState: some View {
        MorbEmptyState(
            "Kubernetes is off",
            systemImage: "cube.transparent",
            description: "Turn it on to run a single-node k3s cluster on the same dockerd your "
                + "containers already use. The first enable streams about 122\u{00A0}MB into the VM.",
            footnote: "Pods are ordinary containers underneath — Logs and Stats work on them from "
                + "the Containers screen too."
        ) {
            Button {
                toggle(true)
            } label: {
                Label("Enable Kubernetes", systemImage: "power")
            }
            .morbButton(.primary)
        }
    }

    private var startingState: some View {
        MorbEmptyState(
            "Starting the cluster",
            systemImage: "cube.transparent",
            description: "Bringing up k3s and waiting for a node to report Ready. A first-ever "
                + "start also streams the payload into the guest, which takes a minute."
        ) {
            ProgressView()
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var readyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            MorbRowDivider(rowClass: .rich)
            nodesSection
            MorbRowDivider(rowClass: .rich)
            podsSection
        }
        .inspector(isPresented: $showsInspector) {
            detailPane
                .inspectorColumnWidth(
                    min: Theme.inspectorMinWidth,
                    ideal: Theme.inspectorWidth,
                    max: 460)
        }
    }

    // MARK: Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let node = nodes.first(where: { $0.id == selectedNodeID }) {
            Form {
                Section("Node") {
                    LabeledContent("Name") {
                        Text(node.name).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    }
                    LabeledContent("Status") {
                        MorbStatusBadge(
                            tone: node.ready ? .running : .bad,
                            title: node.ready ? "Ready" : "Not Ready",
                            filled: false)
                    }
                    LabeledContent("Role", value: node.roleLabel)
                    LabeledContent("Version") {
                        Text(node.version).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    }
                    LabeledContent("CPU", value: Formatters.percent(node.cpuPercent))
                    LabeledContent("Memory", value: Formatters.bytesString(node.memoryBytes))
                    LabeledContent("Age", value: Formatters.absoluteDate(node.age))
                }
            }
            .formStyle(.grouped)
        } else if let pod = pods.first(where: { $0.id == selectedPodID }) {
            Form {
                Section("Pod") {
                    LabeledContent("Name") {
                        Text(pod.name).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    }
                    LabeledContent("Status") {
                        MorbStatusBadge(tone: pod.tone, title: pod.phase.rawValue, filled: false)
                    }
                    LabeledContent("Namespace", value: pod.namespace)
                    LabeledContent("Containers", value: "\(pod.readyContainers) of \(pod.totalContainers) ready")
                    LabeledContent("Restarts", value: "\(pod.restarts)")
                    LabeledContent("Node", value: pod.node)
                    LabeledContent("Age", value: Formatters.absoluteDate(pod.age))
                }
                Section {
                    Text("Pods are ordinary containers underneath — Logs and Stats work on them from the Containers screen too.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "cube.transparent",
                description: Text("Pick a node or a pod to see its detail."))
        }
    }

    // MARK: Summary

    private var summary: some View {
        HStack(spacing: Theme.space6) {
            MorbMetric(
                value: "\(status.nodesReady)",
                unit: "of \(status.nodes)",
                caption: status.nodesReady == 1 ? "node ready" : "nodes ready",
                tone: status.nodesReady == status.nodes ? Theme.statusRunning : Theme.statusDegraded,
                emphasis: .leading)
            MorbMetric(
                value: "\(status.podsReady)",
                unit: "of \(status.pods)",
                caption: "pods ready",
                tone: status.podsReady == status.pods ? nil : Theme.statusDegraded)
            if let version = nodes.first?.version {
                MorbMetric(value: version, caption: "k3s version")
            }
            Spacer(minLength: Theme.space4)
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.vertical, Theme.space4)
    }

    // MARK: Nodes

    private var nodesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MorbSectionHeader("Nodes", symbol: "server.rack", count: nodes.count)
                .padding(.horizontal, Theme.pagePadding)
                .padding(.top, Theme.space4)
                .padding(.bottom, Theme.space2)
            Table(nodes, selection: $selectedNodeID) {
                TableColumn("Name") { node in
                    nodeNameCell(node)
                        .frame(height: Theme.rowStandard, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                TableColumn("Role") { node in
                    Text(node.roleLabel)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(height: Theme.rowStandard, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .width(min: 96, ideal: 140, max: 220)
                TableColumn("Version") { node in
                    Text(node.version)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(height: Theme.rowStandard, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .width(min: 90, ideal: 120, max: 160)
                TableColumn("CPU") { node in
                    MorbNumber(Formatters.percent(node.cpuPercent), font: .callout)
                        .frame(height: Theme.rowStandard, alignment: .trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 56, ideal: 64, max: 84)
                TableColumn("Memory") { node in
                    MorbNumber(Formatters.bytesString(node.memoryBytes), font: .callout)
                        .frame(height: Theme.rowStandard, alignment: .trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 72, ideal: 92, max: 120)
                TableColumn("Age") { node in
                    MorbNumber(Formatters.compactDuration(since: node.age), font: .callout)
                        .frame(height: Theme.rowStandard, alignment: .trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(Formatters.absoluteDate(node.age))
                }
                .width(min: 52, ideal: 64, max: 90)
            }
            .tableStyle(.inset)
            .alternatingRowBackgrounds()
            .frame(height: nodesTableHeight)
            .contextMenu(forSelectionType: K8sNodeInfo.ID.self) { ids in
                if let id = ids.first, let node = nodes.first(where: { $0.id == id }) {
                    Button("Copy Name") { trackDCopy(node.name) }
                }
            } primaryAction: { ids in
                if let id = ids.first {
                    selectedNodeID = id
                    selectedPodID = nil
                    showsInspector = true
                }
            }
            .onChange(of: selectedNodeID) { _, newValue in
                guard newValue != nil else { return }
                selectedPodID = nil
            }
        }
    }

    /// Header plus up to four rows before the table scrolls internally — one control
    /// node is the common case, and this keeps that case from wasting the vertical
    /// space the pod table below needs more.
    private var nodesTableHeight: CGFloat {
        Theme.rowGroupHeader + CGFloat(min(max(nodes.count, 1), 4)) * Theme.rowStandard
    }

    private func nodeNameCell(_ node: K8sNodeInfo) -> some View {
        HStack(spacing: Theme.space2) {
            MorbStatusDot(tone: node.ready ? .running : .bad)
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: Pods

    private var podsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MorbSectionHeader("Pods", symbol: "shippingbox", count: pods.count)
                .padding(.horizontal, Theme.pagePadding)
                .padding(.top, Theme.space4)
                .padding(.bottom, Theme.space2)
            if filteredPods.isEmpty {
                MorbNoMatches(query: podQuery)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                podsTable
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var podsTable: some View {
        Table(filteredPods, selection: $selectedPodID) {
            TableColumn("Name") { pod in
                podNameCell(pod)
                    .frame(height: Theme.rowStandard, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            TableColumn("Namespace") { pod in
                MorbChip(pod.namespace, rank: .quiet)
                    .frame(height: Theme.rowStandard, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 92, ideal: 116, max: 160)
            TableColumn("Status") { pod in
                MorbStatusBadge(tone: pod.tone, title: pod.phase.rawValue, filled: false)
                    .frame(height: Theme.rowStandard, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 118, ideal: 148, max: 190)
            TableColumn("Restarts") { pod in
                MorbNumber(
                    "\(pod.restarts)",
                    tone: pod.restarts > 0 ? Theme.statusDegraded : nil,
                    font: .callout)
                    .frame(height: Theme.rowStandard, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 72, max: 92)
            TableColumn("Node") { pod in
                Text(pod.node)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(height: Theme.rowStandard, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 90, ideal: 120, max: 180)
            TableColumn("Age") { pod in
                MorbNumber(Formatters.compactDuration(since: pod.age), font: .callout)
                    .frame(height: Theme.rowStandard, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(Formatters.absoluteDate(pod.age))
            }
            .width(min: 52, ideal: 64, max: 90)
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds()
        .contextMenu(forSelectionType: K8sPodInfo.ID.self) { ids in
            if let id = ids.first, let pod = pods.first(where: { $0.id == id }) {
                Button("Copy Name") { trackDCopy(pod.name) }
                Button("Copy Namespace") { trackDCopy(pod.namespace) }
                if let container = matchingContainer(for: pod) {
                    Divider()
                    Button("View in Containers") {
                        TrackDAppBridge.reveal(containerID: container.id, in: model, showingLogs: true)
                    }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first {
                selectedPodID = id
                selectedNodeID = nil
                showsInspector = true
            }
        }
        .onChange(of: selectedPodID) { _, newValue in
            guard newValue != nil else { return }
            selectedNodeID = nil
        }
    }

    /// The ordinary container backing a pod, when one exists.
    ///
    /// k3s runs every pod as a plain container on the same `dockerd` the Containers
    /// screen already lists, named `k8s_<container>_<pod>_<namespace>_...` by
    /// convention. Matching on that prefix is what lets "View in Containers" jump
    /// straight to a pod's real logs instead of promising a Kubernetes-native log
    /// viewer this build does not have.
    private func matchingContainer(for pod: K8sPodInfo) -> ContainerSummary? {
        model.containers.first { $0.displayName.contains(pod.name) }
    }

    private func podNameCell(_ pod: K8sPodInfo) -> some View {
        HStack(spacing: Theme.space2) {
            Text(pod.name)
                .lineLimit(1)
                .truncationMode(.middle)
            MorbChip("\(pod.readyContainers)/\(pod.totalContainers)", rank: .quiet, monospaced: true)
        }
    }
}
