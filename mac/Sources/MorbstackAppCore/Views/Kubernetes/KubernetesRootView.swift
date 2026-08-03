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
        ToolbarItem(id: "kubernetes.enable", placement: MorbToolbarGroup.actions) {
            Toggle("Kubernetes", isOn: enabledBinding)
                .toggleStyle(.switch)
                .disabled(!model.engine.isRunning || status.phase == .starting)
                .help(model.engine.isRunning
                    ? "Turn the local cluster on or off"
                    : "Start the Morbstack engine first")
        }
        MorbToolbarGap(placement: MorbToolbarGroup.actions)
        ToolbarItem(id: "kubernetes.kubeconfig", placement: MorbToolbarGroup.actions) {
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
            Table(nodes) {
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
        Table(filteredPods) {
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
