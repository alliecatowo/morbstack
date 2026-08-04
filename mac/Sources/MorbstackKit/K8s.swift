// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Foundation

/// The host half of Morbstack's Kubernetes support.
///
/// The guest runs k3s wired to the existing dockerd through cri-dockerd (see
/// `guest/morbinit/src/k8s.rs`). This file is everything the Mac side of that needs:
///
/// * the control-channel client for `enable` / `disable` / `status` / `kubeconfig`
///   (MRB0 on vsock 1024, the same channel `ping` and `info` use),
/// * the payload installer, which streams k3s and cri-dockerd into the guest over
///   vsock 2377 the first time a cluster is asked for,
/// * kubeconfig rewriting, so the file k3s wrote for a client running *inside* the
///   guest becomes one that works from the Mac,
/// * and merging that kubeconfig into `~/.kube/config` — which happens only when a
///   human explicitly asks for it, and never as a side effect of enabling.
///
/// **The kubeconfig rule.** `~/.kube/config` is not Morbstack's file. It routinely
/// holds production clusters, and a tool that rewrites it because you switched a
/// local toggle on is a tool that will one day point `kubectl delete` at the wrong
/// cluster. So the default is to write `~/.morbstack/kubeconfig` and print the
/// one-line command to use it; merging is a separate, explicit
/// `morb k8s kubeconfig --merge`, and even that takes a timestamped backup first.
public enum K8s {

    // MARK: - Pinned payload

    /// The payload files, with the digests `scripts/fetch-guest-assets.sh` pinned.
    ///
    /// Duplicated from the fetch script deliberately rather than read out of
    /// `PROVENANCE.txt` at runtime: this is the value the *guest* is asked to prove
    /// it has, so it must come from the binary doing the asking. A provenance file
    /// sitting next to the payload would be rewritten by whatever rewrote the
    /// payload. ``payloadDigestsMatchTheFetchScript`` keeps the two in step.
    public struct PayloadFile: Sendable, Equatable {
        public let name: String
        public let sha256: String
    }

    public static let payloadFiles: [PayloadFile] = [
        PayloadFile(
            name: "k3s",
            sha256: "1dc5fc17f15c28fa0a3f011cee28ad613f918c3d967a426e5a05d43ddb239817"),
        PayloadFile(
            name: "cri-dockerd",
            sha256: "d52b7a79376560d7dcb5490e16dcb78578bd0f040c1e70dec220824fae74ae7e"),
    ]

    /// vsock port the payload is streamed over.
    ///
    /// An alias into ``MorbVsockPorts`` — the one registry of guest vsock ports —
    /// kept here for the K8s-flavoured name and doc trail. Defining a literal here
    /// instead would quietly fork the registry.
    public static let installPort: UInt32 = MorbVsockPorts.k8sInstall

    /// The apiserver's port inside the guest. Mirrors `k8s::APISERVER_PORT`.
    public static let guestAPIServerPort = 6443

    /// The context, cluster and user name Morbstack claims in a kubeconfig.
    ///
    /// One name for all three, and a distinctive one: a merge has to be able to find
    /// and replace exactly the entries it wrote last time, and must never collide
    /// with a name a real cluster might plausibly use.
    public static let contextName = "morbstack"

    // MARK: - Status

    /// A phase the cluster can be in, as reported by the guest.
    public enum Phase: String, Codable, Sendable {
        /// The payload has never been streamed in; there is nothing to run.
        case notInstalled = "not-installed"
        /// Installed, toggle off. The resting state, and the default.
        case stopped
        /// Enabled; the control plane is coming up but no node is Ready yet.
        case starting
        /// Enabled and a node reports Ready.
        case ready

        /// A short human rendering for the CLI.
        public var summary: String {
            switch self {
            case .notInstalled: return "not installed"
            case .stopped: return "stopped"
            case .starting: return "starting"
            case .ready: return "ready"
            }
        }
    }

    /// The guest's `k8s_status` reply.
    ///
    /// Every count is optional-with-a-default rather than required: this struct is
    /// decoded from a guest that may be older than this host, and a missing field
    /// must degrade to "zero" rather than failing the whole decode and leaving the
    /// CLI unable to report anything at all.
    public struct Status: Codable, Equatable, Sendable {
        public var type: String
        public var installed: Bool
        public var enabled: Bool
        /// Whether an install and an enable survive a restart. False when the guest's
        /// data root fell back to tmpfs.
        public var persistent: Bool
        public var phase: Phase
        public var nodes: Int
        public var nodesReady: Int
        public var pods: Int
        public var podsReady: Int
        public var apiserverPort: Int
        public var message: String

        enum CodingKeys: String, CodingKey {
            case type
            case installed
            case enabled
            case persistent
            case phase
            case nodes
            case nodesReady = "nodes_ready"
            case pods
            case podsReady = "pods_ready"
            case apiserverPort = "apiserver_port"
            case message
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decodeIfPresent(String.self, forKey: .type) ?? "k8s_status"
            installed = try c.decodeIfPresent(Bool.self, forKey: .installed) ?? false
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            persistent = try c.decodeIfPresent(Bool.self, forKey: .persistent) ?? false
            // An unrecognised phase string is reported as `starting` rather than
            // throwing: a newer guest inventing a phase must not make `morb k8s
            // status` fail outright.
            let raw = try c.decodeIfPresent(String.self, forKey: .phase) ?? "stopped"
            phase = Phase(rawValue: raw) ?? .starting
            nodes = try c.decodeIfPresent(Int.self, forKey: .nodes) ?? 0
            nodesReady = try c.decodeIfPresent(Int.self, forKey: .nodesReady) ?? 0
            pods = try c.decodeIfPresent(Int.self, forKey: .pods) ?? 0
            podsReady = try c.decodeIfPresent(Int.self, forKey: .podsReady) ?? 0
            apiserverPort =
                try c.decodeIfPresent(Int.self, forKey: .apiserverPort) ?? K8s.guestAPIServerPort
            message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        }

        /// Memberwise init, for tests and for synthesising a status when the VM is
        /// not running at all.
        public init(
            type: String = "k8s_status", installed: Bool = false, enabled: Bool = false,
            persistent: Bool = false, phase: Phase = .stopped, nodes: Int = 0,
            nodesReady: Int = 0, pods: Int = 0, podsReady: Int = 0,
            apiserverPort: Int = K8s.guestAPIServerPort, message: String = ""
        ) {
            self.type = type
            self.installed = installed
            self.enabled = enabled
            self.persistent = persistent
            self.phase = phase
            self.nodes = nodes
            self.nodesReady = nodesReady
            self.pods = pods
            self.podsReady = podsReady
            self.apiserverPort = apiserverPort
            self.message = message
        }

        /// The `data` bag for a `--json` CLI reply or a daemon response.
        public var ipcFields: [String: AnyCodableValue] {
            [
                "installed": .bool(installed),
                "enabled": .bool(enabled),
                "persistent": .bool(persistent),
                "phase": .string(phase.rawValue),
                "nodes": .int(nodes),
                "nodes_ready": .int(nodesReady),
                "pods": .int(pods),
                "pods_ready": .int(podsReady),
                "apiserver_port": .int(apiserverPort),
                "message": .string(message),
            ]
        }
    }

    /// The next safe recovery step derived from the guest's current cluster status
    /// and two host facts the daemon owns: its loopback API forward and Morbstack's
    /// private kubeconfig.
    ///
    /// This is intentionally guidance, not a second Kubernetes control plane. The
    /// guest remains the authority for installation, enablement, readiness, and its
    /// explanatory message. A recommendation can only name an operation Morbstack
    /// already performs truthfully (`enable`, `status`, or writing its own
    /// kubeconfig); it never invents workload repair, pod deletion, or restart
    /// commands that the daemon cannot constrain safely.
    public struct Diagnosis: Equatable, Sendable {

        /// The one concrete, reversible next step that is safe for the reported state.
        public enum RecommendedAction: String, Equatable, Sendable {
            /// Install (when needed) and start the local cluster.
            case enableKubernetes = "enable-kubernetes"
            /// Ask the existing guest monitor for a newer readiness reading.
            case refreshStatus = "refresh-status"
            /// Write Morbstack's private kubeconfig from the ready guest.
            case generateKubeconfig = "generate-kubeconfig"
            /// The status already supplies all required recovery actions.
            case none

            /// A system-button label for the actual action, when one is needed.
            public var buttonTitle: String? {
                switch self {
                case .enableKubernetes: "Enable Kubernetes"
                case .refreshStatus: "Refresh Status"
                case .generateKubeconfig: "Generate Kubeconfig"
                case .none: nil
                }
            }

            /// A factual, noun-free description for an inspector or Form row.
            public var displayName: String {
                buttonTitle ?? "No action required"
            }
        }

        /// The guest's latest authoritative status reply.
        public var status: Status
        /// Host loopback port that currently forwards the ready API server, if any.
        public var hostAPIServerPort: Int?
        /// Whether Morbstack's app-owned kubeconfig currently exists on the host.
        public var kubeconfigExists: Bool
        /// A warning that must not be hidden behind a lifecycle recommendation.
        public var persistenceWarning: String?
        /// The one safe next action for this state.
        public var recommendedAction: RecommendedAction
        /// Short result suitable for a CLI row or a native Form section header.
        public var summary: String
        /// Specific recovery guidance, including the guest's own message when present.
        public var guidance: String

        public init(
            status: Status,
            hostAPIServerPort: Int?,
            kubeconfigExists: Bool
        ) {
            self.status = status
            self.hostAPIServerPort = hostAPIServerPort
            self.kubeconfigExists = kubeconfigExists
            persistenceWarning = status.persistent
                ? nil
                : "The guest reports RAM-backed Docker data, so Kubernetes state will be lost when the engine stops."

            let guestMessage = status.message.trimmingCharacters(in: .whitespacesAndNewlines)

            // `enabled` is the persisted intent that the guest updates synchronously
            // for an enable or disable request. `phase`, in contrast, is a monitor
            // snapshot that is intentionally refreshed later. Do not let a stale
            // `.ready` snapshot claim a cluster is reachable immediately after it
            // was disabled, or let a stale `.stopped` snapshot tell someone to enable
            // a cluster that the guest has already accepted for startup.
            guard status.enabled else {
                recommendedAction = .enableKubernetes
                if status.installed {
                    summary = "Kubernetes is installed but turned off."
                    guidance = "Enable Kubernetes to start the local k3s control plane."
                } else {
                    summary = "Kubernetes is not installed in the guest."
                    guidance = "Enable Kubernetes to transfer Morbstack’s pinned payload and start the local k3s control plane."
                }
                return
            }

            // The enabled flag and the payload inventory normally move together.
            // Keep a damaged or older guest from being presented as ready when they
            // disagree, while still recommending the one operation that can repair
            // the missing, pinned payload.
            guard status.installed else {
                recommendedAction = .enableKubernetes
                summary = "Kubernetes is enabled, but its payload is not installed in the guest."
                guidance = "Enable Kubernetes again to transfer Morbstack’s pinned payload and start the local k3s control plane."
                return
            }

            switch status.phase {
            case .notInstalled, .stopped:
                recommendedAction = .refreshStatus
                summary = "Kubernetes is enabled, but the guest has not reported startup yet."
                guidance = guestMessage.isEmpty
                    ? "Wait for the guest monitor to report startup progress, then refresh status."
                    : guestMessage

            case .starting:
                recommendedAction = .refreshStatus
                summary = "Kubernetes has not reported a ready node yet."
                guidance = guestMessage.isEmpty
                    ? "Wait for the guest monitor to report a ready node, then refresh status."
                    : guestMessage

            case .ready:
                if !kubeconfigExists {
                    recommendedAction = .generateKubeconfig
                    summary = "Kubernetes is ready, but Morbstack’s kubeconfig has not been generated."
                    guidance = "Generate Morbstack’s private kubeconfig before connecting to the local API from this Mac."
                } else if hostAPIServerPort == nil {
                    recommendedAction = .refreshStatus
                    summary = "Kubernetes is ready, and the API forward is still reconciling."
                    guidance = "Refresh status. Morbstack only publishes the loopback API endpoint after the guest reports a ready node."
                } else {
                    recommendedAction = .none
                    summary = "Kubernetes is ready and reachable through Morbstack’s local API forward."
                    guidance = "No recovery action is required. Inspect cluster resources or use the generated kubeconfig."
                }
            }
        }

        /// Decodes the daemon-owned diagnosis contract without re-deriving recovery
        /// guidance in a client. The loopback-forward and kubeconfig facts belong to
        /// the daemon; fabricating a recommendation from only the status fields can
        /// make an older or malformed daemon look safe after an app update.
        public init(ipcFields: [String: AnyCodableValue]) throws {
            let status: Status
            do {
                status = try JSONDecoder().decode(Status.self, from: JSONEncoder().encode(ipcFields))
            } catch {
                throw MorbError.protocolViolation(
                    "morbstackd returned an invalid Kubernetes diagnosis status: \(error.localizedDescription)")
            }

            guard case .bool(let kubeconfigExists)? = ipcFields["kubeconfig_exists"] else {
                throw MorbError.protocolViolation("morbstackd returned no kubeconfig status in its Kubernetes diagnosis")
            }

            let hostAPIServerPort: Int?
            switch ipcFields["host_api_port"] {
            case .int(let port)? where (1...65_535).contains(port):
                hostAPIServerPort = port
            case .null?:
                hostAPIServerPort = nil
            default:
                throw MorbError.protocolViolation("morbstackd returned an invalid API forward in its Kubernetes diagnosis")
            }

            guard case .string(let rawAction)? = ipcFields["recovery_action"],
                  let recommendedAction = RecommendedAction(rawValue: rawAction),
                  case .string(let summary)? = ipcFields["summary"], !summary.isEmpty,
                  case .string(let guidance)? = ipcFields["guidance"], !guidance.isEmpty
            else {
                throw MorbError.protocolViolation(
                    "morbstackd returned an incomplete Kubernetes diagnosis; restart Morbstack, then try again")
            }

            let persistenceWarning: String?
            switch ipcFields["persistence_warning"] {
            case .string(let warning)? where !warning.isEmpty:
                persistenceWarning = warning
            case .null?:
                persistenceWarning = nil
            default:
                throw MorbError.protocolViolation("morbstackd returned an invalid persistence warning in its Kubernetes diagnosis")
            }

            self.status = status
            self.hostAPIServerPort = hostAPIServerPort
            self.kubeconfigExists = kubeconfigExists
            self.persistenceWarning = persistenceWarning
            self.recommendedAction = recommendedAction
            self.summary = summary
            self.guidance = guidance
        }

        /// The `data` bag for `morb k8s diagnose --json` and the native app client.
        public var ipcFields: [String: AnyCodableValue] {
            var fields = status.ipcFields
            fields["host_api_port"] = hostAPIServerPort.map { .int($0) } ?? .null
            fields["kubeconfig_exists"] = .bool(kubeconfigExists)
            fields["persistence_warning"] = persistenceWarning.map { .string($0) } ?? .null
            fields["recovery_action"] = .string(recommendedAction.rawValue)
            fields["summary"] = .string(summary)
            fields["guidance"] = .string(guidance)
            return fields
        }
    }

    // MARK: - Bounded resource descriptions

    /// The two Kubernetes API resource kinds Morbstack can describe today.
    ///
    /// This is intentionally not a generic `kubectl describe` proxy. The daemon
    /// permits only a selected Pod or Node, with a fixed GET endpoint and a bounded
    /// response model. Workload mutation, arbitrary API paths, exec, watch, logs, and
    /// port forwarding remain outside this contract.
    public enum ResourceKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
        case pod
        case node

        public var displayName: String {
            switch self {
            case .pod: "Pod"
            case .node: "Node"
            }
        }
    }

    /// A selected Kubernetes resource. Pod identity includes a namespace; nodes are
    /// cluster-scoped and deliberately reject one.
    public struct ResourceReference: Codable, Equatable, Hashable, Sendable {
        public var kind: ResourceKind
        public var name: String
        public var namespace: String?

        public init(kind: ResourceKind, name: String, namespace: String? = nil) {
            self.kind = kind
            self.name = name
            self.namespace = namespace
        }

        /// A concise, user-facing identity suitable for a native table inspector or
        /// CLI heading. It is not used to construct an API URL.
        public var displayName: String {
            switch kind {
            case .pod: "\(namespace ?? "default")/\(name)"
            case .node: name
            }
        }
    }

    /// One bounded, textual value from a Kubernetes object. The API reader truncates
    /// unbounded server values before constructing these rows, keeping a selected
    /// describe response useful without turning the daemon protocol into a bulk export.
    public struct ResourceField: Codable, Equatable, Identifiable, Sendable {
        public var name: String
        public var value: String

        public var id: String { name }

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    /// A Kubernetes condition. `reason` and `message` are optional because the API
    /// routinely omits either one; absence is preserved instead of inventing a value.
    public struct ResourceCondition: Codable, Equatable, Identifiable, Sendable {
        public var type: String
        public var status: String
        public var reason: String?
        public var message: String?

        public var id: String { type }

        public init(type: String, status: String, reason: String?, message: String?) {
            self.type = type
            self.status = status
            self.reason = reason
            self.message = message
        }
    }

    /// A selected-resource description returned by the local Kubernetes API through
    /// the daemon. It contains real object metadata, a small kind-specific fact set,
    /// and bounded conditions/labels/annotations; it never includes Secret objects or
    /// an arbitrary object body.
    public struct ResourceDescription: Codable, Equatable, Sendable {
        public var reference: ResourceReference
        public var uid: String?
        public var createdAt: String?
        public var facts: [ResourceField]
        public var conditions: [ResourceCondition]
        public var labels: [ResourceField]
        public var annotations: [ResourceField]

        public init(
            reference: ResourceReference,
            uid: String?,
            createdAt: String?,
            facts: [ResourceField],
            conditions: [ResourceCondition],
            labels: [ResourceField],
            annotations: [ResourceField]
        ) {
            self.reference = reference
            self.uid = uid
            self.createdAt = createdAt
            self.facts = facts
            self.conditions = conditions
            self.labels = labels
            self.annotations = annotations
        }

        enum CodingKeys: String, CodingKey {
            case reference, uid
            case createdAt = "created_at"
            case facts, conditions, labels, annotations
        }

        /// The daemon's typed payload, which stays equivalent to the JSON emitted by
        /// `morb k8s describe --json` so app and CLI cannot drift into two descriptions.
        public var ipcFields: [String: AnyCodableValue] {
            [
                "reference": .object([
                    "kind": .string(reference.kind.rawValue),
                    "name": .string(reference.name),
                    "namespace": reference.namespace.map(AnyCodableValue.string) ?? .null,
                ]),
                "uid": uid.map(AnyCodableValue.string) ?? .null,
                "created_at": createdAt.map(AnyCodableValue.string) ?? .null,
                "facts": .array(facts.map { .object(["name": .string($0.name), "value": .string($0.value)]) }),
                "conditions": .array(conditions.map {
                    .object([
                        "type": .string($0.type),
                        "status": .string($0.status),
                        "reason": $0.reason.map(AnyCodableValue.string) ?? .null,
                        "message": $0.message.map(AnyCodableValue.string) ?? .null,
                    ])
                }),
                "labels": .array(labels.map { .object(["name": .string($0.name), "value": .string($0.value)]) }),
                "annotations": .array(annotations.map { .object(["name": .string($0.name), "value": .string($0.value)]) }),
            ]
        }

        /// Decodes the exact typed control payload, rejecting malformed data rather
        /// than presenting a partial resource as if it were current API evidence.
        public init(ipcFields: [String: AnyCodableValue]) throws {
            do {
                self = try JSONDecoder().decode(
                    Self.self, from: JSONEncoder().encode(ipcFields))
            } catch {
                throw MorbError.protocolViolation(
                    "morbstackd returned an invalid Kubernetes resource description: \(error.localizedDescription)")
            }
        }
    }

    /// The guest's `k8s_kubeconfig` reply.
    public struct KubeconfigReply: Codable, Equatable, Sendable {
        public var type: String
        public var kubeconfig: String
        public var apiserverPort: Int

        enum CodingKeys: String, CodingKey {
            case type
            case kubeconfig
            case apiserverPort = "apiserver_port"
        }
    }

    /// An `{"type":"error","message":...}` reply from the guest.
    private struct ErrorReply: Codable {
        var type: String
        var message: String?
    }

    // MARK: - Control-channel requests

    private struct Request: Codable {
        var type: String
        var action: String
    }

    /// Sends one `k8s` action and decodes the reply as a ``Status``.
    ///
    /// - Throws: ``MorbError/protocolViolation(_:)`` carrying the guest's own message
    ///   when the guest answers `error`, which is what surfaces "the payload is not
    ///   installed" as a sentence rather than a decode failure.
    public static func requestStatus(
        _ control: GuestControl, action: String, timeout: TimeInterval = 15
    ) throws -> Status {
        let data = try exchange(control, action: action, timeout: timeout)
        return try JSONDecoder().decode(Status.self, from: data)
    }

    /// Fetches the guest's admin kubeconfig, verbatim.
    public static func requestKubeconfig(
        _ control: GuestControl, timeout: TimeInterval = 15
    ) throws -> KubeconfigReply {
        let data = try exchange(control, action: "kubeconfig", timeout: timeout)
        return try JSONDecoder().decode(KubeconfigReply.self, from: data)
    }

    private static func exchange(
        _ control: GuestControl, action: String, timeout: TimeInterval
    ) throws -> Data {
        let payload = try JSONEncoder().encode(Request(type: "k8s", action: action))
        let reply = try control.sendRaw(payload: payload, describing: "k8s \(action)", timeout: timeout)
        // Peek at the type before committing to a shape: an `error` reply decodes
        // cleanly into neither Status nor KubeconfigReply, and the guest's message is
        // the only useful thing in it.
        if let error = try? JSONDecoder().decode(ErrorReply.self, from: reply), error.type == "error" {
            throw MorbError.protocolViolation(error.message ?? "the guest refused the request")
        }
        return reply
    }

    // MARK: - Kubeconfig rewriting

    /// Rewrites the guest's kubeconfig so it works from the Mac.
    ///
    /// k3s writes `server: https://127.0.0.1:6443` for a client running inside the
    /// guest. The Mac reaches that apiserver through a forwarded loopback port, so
    /// **only the port changes** — the host stays `127.0.0.1`. That is not an
    /// accident: k3s's serving certificate carries `127.0.0.1` as a SAN, so keeping
    /// the address means TLS verification still passes end to end, with no
    /// `insecure-skip-tls-verify` and no certificate surgery. Rewriting the address
    /// to anything else would force one or the other.
    ///
    /// The context, cluster and user are renamed to ``contextName`` so a merged
    /// config has a recognisable, stable entry rather than k3s's generic `default`,
    /// which would collide with every other k3s config a user has.
    ///
    /// Line-oriented rather than a YAML parse: the input is a file k3s generated to a
    /// fixed template, the transformation is four token substitutions, and adding a
    /// YAML parser to a zero-dependency project to do it would be a great deal of
    /// machinery for no additional correctness. Any line that is not one of the four
    /// passes through untouched.
    public static func rewriteKubeconfig(_ source: String, hostPort: Int) -> String {
        var out: [String] = []
        out.reserveCapacity(source.split(separator: "\n", omittingEmptySubsequences: false).count)

        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            let indent = String(text.prefix(while: { $0 == " " || $0 == "\t" }))
            var body = text.trimmingCharacters(in: .whitespaces)

            // A YAML list item can carry its first key on the same line as the
            // dash — `- name: default` is how k3s writes the users list, and
            // missing that form leaves a `default`-named user behind while the
            // cluster and context get renamed. The merge then cannot find our user
            // entry at all, so a merged config references a user that is not there.
            // Strip the marker, transform the key, and put the marker back.
            let listMarker = body.hasPrefix("- ") ? "- " : ""
            if !listMarker.isEmpty { body = String(body.dropFirst(2)) }

            /// `key: value` split, or nil for anything that is not a scalar mapping.
            func keyed() -> (key: String, value: String)? {
                guard let colon = body.firstIndex(of: ":") else { return nil }
                let key = String(body[body.startIndex..<colon])
                let value = String(body[body.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                return (key, value)
            }

            guard let (key, value) = keyed() else {
                out.append(text)
                continue
            }

            /// Rebuild the line with a new value, keeping indent and list marker.
            func rebuilt(_ newValue: String) -> String {
                "\(indent)\(listMarker)\(key): \(newValue)"
            }

            switch key {
            case "server":
                out.append(rebuilt("https://127.0.0.1:\(hostPort)"))
            case "current-context":
                out.append(rebuilt(contextName))
            // Exact-match `default`, never a prefix. A user whose own cluster is
            // genuinely called `default-staging` must not have it silently renamed
            // by a tool they pointed at a local Kubernetes toggle.
            case "name" where value == "default",
                 "cluster" where value == "default",
                 "user" where value == "default":
                out.append(rebuilt(contextName))
            default:
                out.append(text)
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Merging into ~/.kube/config

    /// What a merge did, so the caller can report it precisely.
    public struct MergeOutcome: Equatable, Sendable {
        /// Where the merged config was written.
        public let path: String
        /// The backup taken first, or `nil` when there was no existing file to back up.
        public let backupPath: String?
        /// Whether a previous `morbstack` entry was replaced rather than added.
        public let replacedExisting: Bool
        /// Whether `current-context` was switched to `morbstack`.
        public let switchedContext: Bool
    }

    /// The default location Morbstack writes its own kubeconfig to.
    public static var defaultKubeconfigURL: URL { MorbPaths.kubeconfig }

    /// Merges `morbstackConfig` into the kubeconfig text `existing`.
    ///
    /// Pure, so it is tested against fixture kubeconfigs and never against the real
    /// `~/.kube/config`. The strategy is deliberately the conservative one:
    ///
    /// * every `morbstack`-named cluster, context and user in `existing` is dropped,
    ///   then the ones from `morbstackConfig` are appended. Replace-by-name, so
    ///   merging twice is idempotent rather than accumulating duplicates.
    /// * **nothing else is touched.** Other clusters keep their entries, their order,
    ///   and their formatting.
    /// * `current-context` is switched to `morbstack` only when `switchContext` is
    ///   set. Enabling a local cluster must not silently retarget a `kubectl` that
    ///   was pointing at production.
    ///
    /// Returns the merged text and whether an existing entry was replaced.
    public static func mergeKubeconfig(
        existing: String, morbstackConfig: String, switchContext: Bool
    ) -> (text: String, replacedExisting: Bool) {
        // An empty or whitespace-only existing config means there is nothing to
        // preserve, and emitting our own file as-is is both simpler and produces a
        // cleaner result than splicing into an empty skeleton.
        guard !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (morbstackConfig, false)
        }

        let existingDoc = KubeconfigDocument(text: existing)
        let ourDoc = KubeconfigDocument(text: morbstackConfig)

        let hadOurs = existingDoc.hasEntry(named: contextName)
        var merged = existingDoc
        merged.removeEntries(named: contextName)
        merged.appendEntries(from: ourDoc, named: contextName)
        if switchContext {
            merged.setCurrentContext(contextName)
        }
        return (merged.rendered(), hadOurs)
    }

    /// Writes `text` to `~/.kube/config`, backing up whatever was there first.
    ///
    /// The backup is unconditional and timestamped, and its path is returned so the
    /// caller can print it. This function is the only thing in Morbstack that writes
    /// to `~/.kube/config`, and it is reached only from an explicit
    /// `morb k8s kubeconfig --merge`.
    public static func writeMergedKubeconfig(
        _ text: String, to url: URL, replacedExisting: Bool, switchedContext: Bool,
        now: Date = Date()
    ) throws -> MergeOutcome {
        let fm = FileManager.default
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])

        var backupPath: String?
        if fm.fileExists(atPath: url.path) {
            let stamp = ISO8601DateFormatter()
            stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
            let suffix = stamp.string(from: now)
                .replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: "-", with: "")
            var backup = url.appendingPathExtension("morbstack-backup-\(suffix)")
            var collision = 2
            while fm.fileExists(atPath: backup.path) {
                backup = url.appendingPathExtension("morbstack-backup-\(suffix)-\(collision)")
                collision += 1
            }
            // Copy rather than move: if the write below fails, the original must
            // still be exactly where kubectl expects it. Never replace an earlier
            // backup: two explicit merges can legitimately happen in one second.
            try fm.copyItem(at: url, to: backup)
            backupPath = backup.path
        }

        try Data(text.utf8).write(to: url, options: .atomic)
        // kubeconfigs hold credentials; 0600 regardless of what was there before.
        try? fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)

        return MergeOutcome(
            path: url.path, backupPath: backupPath, replacedExisting: replacedExisting,
            switchedContext: switchedContext)
    }

    /// Writes Morbstack's own kubeconfig to `~/.morbstack/kubeconfig` (0600).
    @discardableResult
    public static func writeStandaloneKubeconfig(_ text: String, to url: URL = K8s.defaultKubeconfigURL)
        throws -> URL
    {
        try MorbPaths.ensureDirectories()
        try Data(text.utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
        return url
    }

    // MARK: - Streaming the payload into the guest

    /// Where a payload file lives on the host.
    public static func payloadURL(for name: String) -> URL {
        MorbPaths.k8sPayloadDirectory.appendingPathComponent(name, isDirectory: false)
    }

    /// Which payload files are missing from the host altogether.
    ///
    /// Checked before a transfer is attempted so the failure is "run
    /// `scripts/fetch-guest-assets.sh --k8s-only`" rather than a vsock error.
    public static func missingHostPayloads() -> [String] {
        payloadFiles
            .filter { !FileManager.default.fileExists(atPath: payloadURL(for: $0.name).path) }
            .map(\.name)
    }

    /// Streams any payload file the guest does not already have, over vsock 2377.
    ///
    /// The `HAVE` probe is what makes this cheap on every run after the first: the
    /// guest re-hashes what it has and says whether it matches, and a match skips the
    /// transfer entirely. So `morb k8s enable` costs ~122 MB once per machine, and
    /// nothing thereafter.
    ///
    /// - Parameter progress: called with `(name, bytesSent, totalBytes)` as the body
    ///   is written, so a CLI or the app can render a bar. Called on this thread.
    /// - Returns: the names actually transferred, which is empty on a repeat run.
    @discardableResult
    public static func installPayload(
        vm: VMManager, log: MorbLog? = nil, progress: ((String, Int64, Int64) -> Void)? = nil
    ) throws -> [String] {
        let missing = missingHostPayloads()
        guard missing.isEmpty else {
            throw MorbError.notFound(
                "the Kubernetes payload is not on this Mac: \(missing.joined(separator: ", ")) "
                    + "missing from \(MorbPaths.k8sPayloadDirectory.path). "
                    + "Run `scripts/fetch-guest-assets.sh --k8s-only` to fetch it.")
        }

        var transferred: [String] = []
        for file in payloadFiles {
            let fd: Int32
            switch vm.connectVsockBlocking(port: installPort, timeout: 20) {
            case .success(let descriptor): fd = descriptor
            case .failure(let error):
                throw MorbError.io("could not open the payload channel (vsock \(installPort)): \(error)")
            }
            defer { Darwin.close(fd) }
            POSIXSocketSupport.suppressSIGPIPE(fd)

            // Ask before sending. A guest that already has the exact bytes answers
            // YES and 74 MB stays on the host.
            try writeLine(fd, "HAVE \(file.name) \(file.sha256)")
            let have = try readLine(fd, timeout: 120)
            if have == "YES" {
                log?.info("k8s: guest already has \(file.name); skipping transfer")
                continue
            }
            guard have == "NO" else {
                throw MorbError.protocolViolation(
                    "unexpected reply to HAVE \(file.name): \(have)")
            }

            let url = payloadURL(for: file.name)
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size]
                as? NSNumber)?.int64Value ?? 0
            log?.info("k8s: streaming \(file.name) (\(size) bytes) to the guest")

            try writeLine(fd, "PUT \(file.name) \(size) \(file.sha256)")
            let ready = try readLine(fd, timeout: 60)
            guard ready == "OK" else {
                throw MorbError.protocolViolation("guest refused \(file.name): \(ready)")
            }

            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var sent: Int64 = 0
            while true {
                guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
                guard POSIXSocketSupport.writeAll(fd, chunk) else {
                    throw MorbError.io(
                        "the payload channel closed \(sent) bytes into \(file.name)")
                }
                sent += Int64(chunk.count)
                progress?(file.name, sent, size)
            }

            // The guest verifies the digest before answering, so this reply is the
            // real result of the install, not an acknowledgement of the write.
            let result = try readLine(fd, timeout: 300)
            guard result == "OK" else {
                throw MorbError.io("guest rejected \(file.name): \(result)")
            }
            log?.info("k8s: installed \(file.name) in the guest")
            transferred.append(file.name)
        }
        return transferred
    }

    /// Writes one `\n`-terminated line to a connected descriptor.
    private static func writeLine(_ fd: Int32, _ line: String) throws {
        guard POSIXSocketSupport.writeAll(fd, Data((line + "\n").utf8)) else {
            throw MorbError.io("could not write to the payload channel")
        }
    }

    /// Reads one `\n`-terminated line, one byte at a time.
    ///
    /// Byte-at-a-time because the body that follows a `PUT` reply is raw and must not
    /// be consumed into a read-ahead buffer. The lines are a dozen bytes each and
    /// there are at most four per file, so the syscall count is irrelevant.
    private static func readLine(_ fd: Int32, timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var bytes: [UInt8] = []
        while bytes.count < 4096 {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw MorbError.timeout("the guest did not reply in time") }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = POSIXSocketSupport.retryOnInterrupt {
                withUnsafeMutablePointer(to: &poller) { poll($0, 1, Int32(remaining * 1000)) }
            }
            if ready == 0 { throw MorbError.timeout("the guest did not reply in time") }
            if ready < 0 { throw MorbError.io("poll failed on the payload channel") }

            var byte: UInt8 = 0
            let n = withUnsafeMutablePointer(to: &byte) {
                POSIXSocketSupport.readSome(fd, into: UnsafeMutableRawPointer($0), count: 1)
            }
            if n == 0 { break }
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw MorbError.io("read failed on the payload channel")
            }
            if byte == 0x0A { break }
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - A very small kubeconfig document model

/// Just enough structure to add and remove named entries in a kubeconfig.
///
/// This is not a YAML parser and does not try to be. A kubeconfig has exactly three
/// top-level sequences that matter here — `clusters`, `contexts`, `users` — each a
/// list of `- ` items at a known indentation, and the operation is "drop the items
/// whose `name:` is X, then append these". Working line-by-line over the original
/// text means every byte we are not deliberately changing survives untouched:
/// comments, key order, quoting style, and any field a future kubectl adds.
///
/// A real YAML round-trip would normalise all of that, and normalising somebody's
/// production kubeconfig as a side effect of adding a local cluster is precisely the
/// harm this whole module is arranged to avoid.
struct KubeconfigDocument {
    /// Every line of the original document.
    private var lines: [String]

    init(text: String) {
        lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // A trailing newline produces a final empty element; drop it so appends land
        // in the right place, and `rendered()` puts it back.
        if lines.last == "" { lines.removeLast() }
    }

    /// The line ranges of each `- ...` item in the top-level `section` list.
    ///
    /// An item starts at a line whose first non-space character is `-` at the
    /// section's item indentation, and runs until the next such line or the end of
    /// the section (the next line at column 0 that is not blank).
    private func itemRanges(inSection section: String) -> [Range<Int>] {
        guard let sectionLine = lines.firstIndex(where: { $0.hasPrefix("\(section):") }) else {
            return []
        }
        var ranges: [Range<Int>] = []
        var currentStart: Int?
        var index = sectionLine + 1

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isTopLevel = !line.isEmpty && line.first != " " && line.first != "\t" && line.first != "-"
            if isTopLevel {
                break  // next top-level key; the section is over
            }
            if trimmed.hasPrefix("- ") || trimmed == "-" {
                if let start = currentStart { ranges.append(start..<index) }
                currentStart = index
            }
            index += 1
        }
        if let start = currentStart { ranges.append(start..<index) }
        return ranges
    }

    /// The value of the `name:` key inside an item, if it has one.
    private func itemName(_ range: Range<Int>) -> String? {
        for i in range {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            let candidate = trimmed.hasPrefix("- ") ? String(trimmed.dropFirst(2)) : trimmed
            if candidate.hasPrefix("name:") {
                return candidate.dropFirst("name:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static let sections = ["clusters", "contexts", "users"]

    /// Whether any section already holds an entry called `name`.
    func hasEntry(named name: String) -> Bool {
        for section in Self.sections {
            for range in itemRanges(inSection: section) where itemName(range) == name {
                return true
            }
        }
        return false
    }

    /// Drop every entry called `name` from all three sections.
    mutating func removeEntries(named name: String) {
        for section in Self.sections {
            // Back to front, so earlier ranges stay valid as later ones are removed.
            for range in itemRanges(inSection: section).reversed() where itemName(range) == name {
                lines.removeSubrange(range)
            }
        }
    }

    /// Copy the entries called `name` out of `other` and append them to the matching
    /// sections here, creating a section that does not exist yet.
    mutating func appendEntries(from other: KubeconfigDocument, named name: String) {
        for section in Self.sections {
            let incoming = other.itemRanges(inSection: section)
                .filter { other.itemName($0) == name }
                .flatMap { Array(other.lines[$0]) }
            guard !incoming.isEmpty else { continue }

            if let sectionLine = lines.firstIndex(where: { $0.hasPrefix("\(section):") }) {
                // Insert at the end of the existing section rather than immediately
                // after the header, so the file reads in the order entries were added.
                let existing = itemRanges(inSection: section)
                let insertAt = existing.last?.upperBound ?? (sectionLine + 1)
                lines.insert(contentsOf: incoming, at: insertAt)
            } else {
                lines.append("\(section):")
                lines.append(contentsOf: incoming)
            }
        }
    }

    /// Point `current-context` at `name`, adding the key if it is absent.
    mutating func setCurrentContext(_ name: String) {
        if let index = lines.firstIndex(where: { $0.hasPrefix("current-context:") }) {
            lines[index] = "current-context: \(name)"
        } else {
            lines.append("current-context: \(name)")
        }
    }

    func rendered() -> String {
        lines.joined(separator: "\n") + "\n"
    }
}
