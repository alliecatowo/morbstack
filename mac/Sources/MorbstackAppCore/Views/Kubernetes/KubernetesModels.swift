// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// What the Kubernetes screen needs, and where it comes from.
//
// `MorbstackKit.K8s` already carries the wire types for the guest's control channel —
// `K8s.Status` is exactly the cluster summary this screen wants (phase, node/pod
// counts, the enable/disable verbs) — but it has no notion of *which* nodes or pods
// exist, because the guest answers that over the Kubernetes API, not the vsock control
// channel `K8s` speaks. `AppModel` has no k3s client to ask either (see
// `docs/design/REWRITE-PLAN.md` — the model layer is out of scope for this pass), so
// this screen is built against a small protocol instead of a concrete client. A real
// implementation — a thin `kubectl`-shaped client over the forwarded API server —
// slots in later by conforming to ``K8sClusterProviding``; nothing in the view changes.

import Foundation
import MorbstackKit

// MARK: - Node and pod summaries

/// One node, as the screen displays it. Not `MorbstackKit.K8s` because a node is a
/// Kubernetes API object, not a control-channel concept — this is the screen's own
/// shape, small enough to fixture and small enough to replace.
struct K8sNodeInfo: Identifiable, Equatable, Sendable {
    var name: String
    var roles: [String]
    var ready: Bool
    var version: String
    var cpuPercent: Double
    var memoryBytes: Int64
    var age: Date

    var id: String { name }

    var roleLabel: String { roles.isEmpty ? "worker" : roles.joined(separator: ", ") }
}

/// One pod.
struct K8sPodInfo: Identifiable, Equatable, Sendable {

    enum Phase: String, Sendable {
        case running = "Running"
        case pending = "Pending"
        case crashLoop = "CrashLoopBackOff"
        case completed = "Completed"
    }

    var name: String
    var namespace: String
    var phase: Phase
    var readyContainers: Int
    var totalContainers: Int
    var restarts: Int
    var node: String
    var age: Date

    var id: String { "\(namespace)/\(name)" }

    var isReady: Bool { phase == .running && readyContainers == totalContainers }

    /// The colour and symbol this pod's status carries. `StatusTone` already has the
    /// four buckets a workload needs — running, transitional, paused, bad — so a pod
    /// is classified onto the same tones the Containers screen uses rather than
    /// inventing a fifth palette for Kubernetes specifically.
    var tone: StatusTone {
        switch phase {
        case .running: return isReady ? .running : .busy
        case .pending: return .busy
        case .crashLoop: return .bad
        case .completed: return .idle
        }
    }
}

// MARK: - Provider

/// Everything the Kubernetes screen reads and drives.
///
/// A real implementation talks to the forwarded API server (`K8sAPIServerForward`,
/// already in `MorbstackKit`) for `nodes()`/`pods()` and to `K8sManager` for
/// `currentStatus()`/`setEnabled(_:)`. Until that client exists, ``K8sFixtureClient``
/// stands in so the screen has something real to render.
@MainActor
protocol K8sClusterProviding: AnyObject {
    func currentStatus() async -> K8s.Status
    func setEnabled(_ enabled: Bool) async -> K8s.Status
    func nodes() async -> [K8sNodeInfo]
    func pods() async -> [K8sPodInfo]
}

// MARK: - Fixture

/// A self-contained, in-memory cluster.
///
/// Enabling transitions through `.starting` for a beat before settling on `.ready`, so
/// the intermediate state in the view is exercised by ordinary interaction rather than
/// only by a fixture parameter nobody sets. Disabling is immediate — a real cluster's
/// shutdown is fast; only bringing k3s up takes visible time.
@MainActor
final class K8sFixtureClient: K8sClusterProviding {

    private var status: K8s.Status
    private let allNodes: [K8sNodeInfo]
    private let allPods: [K8sPodInfo]

    init(
        startsEnabled: Bool = true,
        nodes: [K8sNodeInfo] = .fixture,
        pods: [K8sPodInfo] = .fixture
    ) {
        self.allNodes = nodes
        self.allPods = pods
        let readyNodes = nodes.filter(\.ready).count
        let readyPods = nodes.isEmpty ? 0 : pods.filter(\.isReady).count
        self.status = K8s.Status(
            installed: true,
            enabled: startsEnabled,
            persistent: true,
            phase: startsEnabled ? .ready : .stopped,
            nodes: startsEnabled ? nodes.count : 0,
            nodesReady: startsEnabled ? readyNodes : 0,
            pods: startsEnabled ? pods.count : 0,
            podsReady: startsEnabled ? readyPods : 0)
    }

    func currentStatus() async -> K8s.Status { status }

    func setEnabled(_ enabled: Bool) async -> K8s.Status {
        guard enabled != status.enabled else { return status }
        if enabled {
            status = K8s.Status(installed: true, enabled: true, persistent: true, phase: .starting)
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1100))
                guard let self, self.status.phase == .starting else { return }
                let readyNodes = self.allNodes.filter(\.ready).count
                let readyPods = self.allPods.filter(\.isReady).count
                self.status = K8s.Status(
                    installed: true, enabled: true, persistent: true, phase: .ready,
                    nodes: self.allNodes.count, nodesReady: readyNodes,
                    pods: self.allPods.count, podsReady: readyPods)
            }
        } else {
            status = K8s.Status(installed: true, enabled: false, persistent: true, phase: .stopped)
        }
        return status
    }

    func nodes() async -> [K8sNodeInfo] { status.phase == .ready ? allNodes : [] }
    func pods() async -> [K8sPodInfo] { status.phase == .ready ? allPods : [] }
}

// MARK: - Fixture data

extension [K8sNodeInfo] {
    static let fixture: [K8sNodeInfo] = [
        K8sNodeInfo(
            name: "morbstack-vm",
            roles: ["control-plane", "master"],
            ready: true,
            version: "v1.30.4+k3s1",
            cpuPercent: 11.8,
            memoryBytes: Int64(1.86 * 1_073_741_824),
            age: Date(timeIntervalSinceNow: -6 * 86_400 - 3 * 3600)),
    ]
}

extension [K8sPodInfo] {
    static let fixture: [K8sPodInfo] = [
        K8sPodInfo(
            name: "coredns-7f9c69d9d8-4wqxr", namespace: "kube-system", phase: .running,
            readyContainers: 1, totalContainers: 1, restarts: 0, node: "morbstack-vm",
            age: Date(timeIntervalSinceNow: -6 * 86_400)),
        K8sPodInfo(
            name: "local-path-provisioner-6c5cb99958-8jz2p", namespace: "kube-system", phase: .running,
            readyContainers: 1, totalContainers: 1, restarts: 0, node: "morbstack-vm",
            age: Date(timeIntervalSinceNow: -6 * 86_400)),
        K8sPodInfo(
            name: "metrics-server-648b5df564-k7vnh", namespace: "kube-system", phase: .running,
            readyContainers: 1, totalContainers: 1, restarts: 1, node: "morbstack-vm",
            age: Date(timeIntervalSinceNow: -6 * 86_400)),
        K8sPodInfo(
            name: "svclb-shopfront-web-6f2c9", namespace: "kube-system", phase: .running,
            readyContainers: 1, totalContainers: 1, restarts: 0, node: "morbstack-vm",
            age: Date(timeIntervalSinceNow: -3 * 3600)),
        K8sPodInfo(
            name: "hello-web-6d9c8f7b7-x4n2q", namespace: "default", phase: .running,
            readyContainers: 1, totalContainers: 1, restarts: 0, node: "morbstack-vm",
            age: Date(timeIntervalSinceNow: -2 * 3600)),
        K8sPodInfo(
            name: "migrate-schema-28j4k", namespace: "default", phase: .completed,
            readyContainers: 0, totalContainers: 1, restarts: 0, node: "morbstack-vm",
            age: Date(timeIntervalSinceNow: -2 * 3600 - 600)),
        K8sPodInfo(
            name: "flaky-worker-7d8f9c6b5-p2m9v", namespace: "default", phase: .crashLoop,
            readyContainers: 0, totalContainers: 1, restarts: 14, node: "morbstack-vm",
            age: Date(timeIntervalSinceNow: -3 * 3600)),
    ]
}
