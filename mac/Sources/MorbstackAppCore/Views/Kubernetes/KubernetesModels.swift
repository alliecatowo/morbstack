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

/// One regular container reported by a pod's `spec.containers` and status.
///
/// Kubernetes also has init and ephemeral containers. This small observability surface
/// deliberately starts with regular containers because they are the containers exposed
/// by the normal pod-log API workflow; it does not imply that the other kinds do not
/// exist.
struct K8sPodContainerInfo: Identifiable, Equatable, Sendable {
    var name: String
    var image: String
    var state: String
    var ready: Bool
    var restarts: Int

    var id: String { name }
}

/// One retained core/v1 Event associated with a selected pod.
///
/// Event retention is owned by Kubernetes. `lastObserved` may be absent on older
/// events, so the inspector shows that fact rather than manufacturing a timestamp.
struct K8sPodEventInfo: Identifiable, Equatable, Sendable {
    var id: String
    var type: String
    var reason: String
    var message: String
    var count: Int
    var lastObserved: Date?
}

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
    /// Kubernetes assigns this immutable value. It scopes the event query so events
    /// for a deleted-and-recreated pod with the same name never bleed into its detail.
    var uid: String? = nil
    var containers: [K8sPodContainerInfo] = []

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
    /// Lists retained core/v1 events for this exact pod. It never watches or mutates
    /// the cluster, and a failure is surfaced separately from pod logs.
    func podEvents(for pod: K8sPodInfo) async throws -> [K8sPodEventInfo]
    /// Reads a bounded, non-following log snapshot for one regular container. It
    /// deliberately never invokes exec, attaches a stream, or requests previous logs.
    func podLog(for pod: K8sPodInfo, container: String) async throws -> String
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

    func podEvents(for pod: K8sPodInfo) async throws -> [K8sPodEventInfo] {
        guard let uid = pod.uid, !uid.isEmpty else {
            throw K8sResourceAccessError.unavailable(
                "The Kubernetes API did not return an identity for this pod, so Morbstack cannot scope its events safely.")
        }
        let client = try KubernetesAPIClient(kubeconfigURL: K8s.defaultKubeconfigURL)
        return try await client.podEvents(namespace: pod.namespace, uid: uid)
    }

    func podLog(for pod: K8sPodInfo, container: String) async throws -> String {
        let client = try KubernetesAPIClient(kubeconfigURL: K8s.defaultKubeconfigURL)
        return try await client.podLog(namespace: pod.namespace, pod: pod.name, container: container)
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

    func podEvents(for pod: K8sPodInfo) async throws -> [K8sPodEventInfo] {
        guard status.phase == .ready else {
            throw K8sResourceAccessError.unavailable("Kubernetes is not ready.")
        }
        return .fixture.filter { $0.id.hasPrefix("\(pod.id):") }
    }

    func podLog(for pod: K8sPodInfo, container: String) async throws -> String {
        guard status.phase == .ready else {
            throw K8sResourceAccessError.unavailable("Kubernetes is not ready.")
        }
        guard pod.containers.contains(where: { $0.name == container }) else {
            throw K8sResourceAccessError.unavailable(
                "The selected container is no longer reported by this pod. Refresh Kubernetes resources and try again.")
        }
        return Self.fixtureLog(for: pod, container: container)
    }

    func generateKubeconfig() async throws -> URL {
        throw K8sResourceAccessError.unavailable(
            "Kubeconfig generation is unavailable in the deterministic tour fixture.")
    }

    private static func fixtureLog(for pod: K8sPodInfo, container: String) -> String {
        """
        2026-01-01T12:00:00.000000000Z fixture \(container) started in \(pod.namespace)/\(pod.name)
        2026-01-01T12:00:01.000000000Z serving deterministic tour traffic
        """
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
            age: Date(timeIntervalSinceNow: -6 * 86_400), uid: "fixture-coredns",
            containers: [K8sPodContainerInfo(name: "coredns", image: "rancher/mirrored-coredns-coredns:1.11.1", state: "Running", ready: true, restarts: 0)]),
        K8sPodInfo(
            name: "local-path-provisioner-6c5cb99958-8jz2p", namespace: "kube-system", phase: .running,
            readyContainers: 1, totalContainers: 1, restarts: 0, node: "morbstack-vm",
            age: Date(timeIntervalSinceNow: -6 * 86_400), uid: "fixture-local-path",
            containers: [K8sPodContainerInfo(name: "local-path-provisioner", image: "rancher/local-path-provisioner:v0.0.28", state: "Running", ready: true, restarts: 0)]),
        K8sPodInfo(
            name: "metrics-server-648b5df564-k7vnh", namespace: "kube-system", phase: .running,
            readyContainers: 1, totalContainers: 1, restarts: 1, node: "morbstack-vm",
            age: Date(timeIntervalSinceNow: -6 * 86_400), uid: "fixture-metrics-server",
            containers: [K8sPodContainerInfo(name: "metrics-server", image: "rancher/mirrored-metrics-server:v0.7.1", state: "Running", ready: true, restarts: 1)]),
        K8sPodInfo(
            name: "svclb-shopfront-web-6f2c9", namespace: "kube-system", phase: .running,
            readyContainers: 1, totalContainers: 1, restarts: 0, node: "morbstack-vm",
            age: Date(timeIntervalSinceNow: -3 * 3600), uid: "fixture-shopfront",
            containers: [K8sPodContainerInfo(name: "lb-tcp-8080", image: "rancher/klipper-lb:v0.4.13", state: "Running", ready: true, restarts: 0)]),
        K8sPodInfo(
            name: "hello-web-6d9c8f7b7-x4n2q", namespace: "default", phase: .running,
            readyContainers: 1, totalContainers: 1, restarts: 0, node: "morbstack-vm",
            age: Date(timeIntervalSinceNow: -2 * 3600), uid: "fixture-hello-web",
            containers: [K8sPodContainerInfo(name: "hello-web", image: "local/hello-web:v1", state: "Running", ready: true, restarts: 0)]),
        K8sPodInfo(
            name: "migrate-schema-28j4k", namespace: "default", phase: .completed,
            readyContainers: 0, totalContainers: 1, restarts: 0, node: "morbstack-vm",
            age: Date(timeIntervalSinceNow: -2 * 3600 - 600), uid: "fixture-migrate-schema",
            containers: [K8sPodContainerInfo(name: "migrate", image: "local/hello-web:v1", state: "Completed", ready: false, restarts: 0)]),
        K8sPodInfo(
            name: "flaky-worker-7d8f9c6b5-p2m9v", namespace: "default", phase: .crashLoop,
            readyContainers: 0, totalContainers: 1, restarts: 14, node: "morbstack-vm",
            age: Date(timeIntervalSinceNow: -3 * 3600), uid: "fixture-flaky-worker",
            containers: [K8sPodContainerInfo(name: "worker", image: "local/worker:v1", state: "CrashLoopBackOff", ready: false, restarts: 14)]),
    ]
}

extension [K8sPodEventInfo] {
    static let fixture: [K8sPodEventInfo] = [
        K8sPodEventInfo(
            id: "kube-system/coredns-7f9c69d9d8-4wqxr:scheduled", type: "Normal", reason: "Scheduled",
            message: "Successfully assigned kube-system/coredns-7f9c69d9d8-4wqxr to morbstack-vm",
            count: 1, lastObserved: Date(timeIntervalSinceNow: -6 * 86_400)),
        K8sPodEventInfo(
            id: "default/flaky-worker-7d8f9c6b5-p2m9v:backoff", type: "Warning", reason: "BackOff",
            message: "Back-off restarting failed container worker in pod flaky-worker-7d8f9c6b5-p2m9v_default",
            count: 14, lastObserved: Date(timeIntervalSinceNow: -15 * 60)),
    ]
}
