// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// What the Kubernetes screen needs, and where it comes from.
//
// `MorbstackKit.K8s` carries the wire types for the guest's control channel and the
// daemon exposes those verbs to the app. Nodes and pods come from the *forwarded,
// TLS-authenticated Kubernetes API* instead: their data is deliberately never
// synthesized from the summary counts. The tour fixture is the sole in-memory
// implementation and is injected by `AppModel.forLaunch` only for `--tour-fixtures`.

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
    var age: Date?

    var id: String { name }

    var roleLabel: String { roles.isEmpty ? "—" : roles.joined(separator: ", ") }
}

/// One pod.
struct K8sPodInfo: Identifiable, Equatable, Sendable {

    enum Phase: Sendable, Hashable {
        case running
        case pending
        case crashLoop
        case completed
        case failed
        case unknown(String)

        var label: String {
            switch self {
            case .running: "Running"
            case .pending: "Pending"
            case .crashLoop: "CrashLoopBackOff"
            case .completed: "Completed"
            case .failed: "Failed"
            case .unknown(let value): value
            }
        }
    }

    var name: String
    var namespace: String
    var phase: Phase
    var readyContainers: Int
    var totalContainers: Int
    var restarts: Int
    var node: String
    var age: Date?

    var id: String { "\(namespace)/\(name)" }

    var nodeLabel: String { node.isEmpty ? "—" : node }

    var isReady: Bool { phase == .running && readyContainers == totalContainers }

    /// The operational state this pod carries. The table or inspector decides how the
    /// native system control presents that information; this model supplies no visual
    /// policy of its own.
    var operationalState: OperationalState {
        switch phase {
        case .running: return isReady ? .running : .changing
        case .pending: return .changing
        case .crashLoop, .failed: return .failed
        case .completed: return .stopped
        case .unknown: return .changing
        }
    }
}

// MARK: - Provider

/// A coherent read of both resource endpoints. Keeping the pair together means a
/// refresh cannot publish nodes from one kubeconfig generation and pods from another.
struct K8sClusterResources: Sendable {
    var nodes: [K8sNodeInfo]
    var pods: [K8sPodInfo]
}

/// A truthful reason the app cannot list resources yet.
///
/// The local kubeconfig contains an administrator client credential. The app only
/// reads it after the user generated Morbstack's own config, and never falls back to
/// a user's unrelated `~/.kube/config`.
enum K8sResourceAccessError: LocalizedError, Sendable {
    case kubeconfigRequired
    case malformedKubeconfig
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .kubeconfigRequired:
            "Generate Morbstack’s kubeconfig to connect to the local API server."
        case .malformedKubeconfig:
            "Morbstack’s kubeconfig is incomplete or cannot be used for a TLS-authenticated connection. Generate it again."
        case .unavailable(let message): message
        }
    }
}

/// Everything the Kubernetes screen reads and drives. Production calls the daemon's
/// real `k8s-*` protocol and the forwarded API server. Fixtures exist only for the
/// explicit developer tour.
@MainActor
protocol K8sClusterProviding: AnyObject {
    func currentStatus() async throws -> K8s.Status
    /// Real recovery guidance reconciled by the daemon from the guest status and the
    /// host API-forward/kubeconfig facts. It performs no Kubernetes mutations.
    func diagnosis() async throws -> K8s.Diagnosis
    func setEnabled(_ enabled: Bool) async throws -> K8s.Status
    func resources() async throws -> K8sClusterResources
    /// Writes only Morbstack's private, app-owned kubeconfig. It never edits
    /// `~/.kube/config`; that remains the CLI's separately confirmed merge action.
    func generateKubeconfig() async throws -> URL
}

// MARK: - Production provider

/// The app's production Kubernetes client.
///
/// Lifecycle and kubeconfig operations go through the daemon rather than reaching the
/// guest directly. Resource reads use `KubernetesAPIClient`, which accepts only the
/// loopback endpoint and CA/client credentials written by that explicit kubeconfig
/// action. There is no fabricated fallback when the API is unavailable.
@MainActor
final class K8sDaemonClient: K8sClusterProviding {
    private let daemon: DaemonClient

    init(daemon: DaemonClient) {
        self.daemon = daemon
    }

    func currentStatus() async throws -> K8s.Status {
        try await daemon.kubernetesStatus()
    }

    func diagnosis() async throws -> K8s.Diagnosis {
        try await daemon.diagnoseKubernetes()
    }

    func setEnabled(_ enabled: Bool) async throws -> K8s.Status {
        try await (enabled ? daemon.enableKubernetes() : daemon.disableKubernetes())
    }

    func resources() async throws -> K8sClusterResources {
        let client = try KubernetesAPIClient(kubeconfigURL: K8s.defaultKubeconfigURL)
        return try await client.resources()
    }

    func generateKubeconfig() async throws -> URL {
        try await daemon.writeKubernetesKubeconfig()
    }
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

    func currentStatus() async throws -> K8s.Status { status }

    func diagnosis() async throws -> K8s.Diagnosis {
        K8s.Diagnosis(
            status: status,
            hostAPIServerPort: status.phase == .ready ? K8s.guestAPIServerPort : nil,
            kubeconfigExists: false)
    }

    func setEnabled(_ enabled: Bool) async throws -> K8s.Status {
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

    func resources() async throws -> K8sClusterResources {
        guard status.phase == .ready else { return K8sClusterResources(nodes: [], pods: []) }
        return K8sClusterResources(nodes: allNodes, pods: allPods)
    }

    func generateKubeconfig() async throws -> URL {
        throw K8sResourceAccessError.unavailable(
            "Kubeconfig generation is unavailable in the deterministic tour fixture.")
    }
}

// MARK: - Fixture data

extension [K8sNodeInfo] {
    static let fixture: [K8sNodeInfo] = [
        K8sNodeInfo(
            name: "morbstack-vm",
            roles: ["control-plane", "master"],
            ready: true,
            version: "v1.30.4+k3s1",
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
