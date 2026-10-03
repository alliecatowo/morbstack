// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The app's intentionally small Kubernetes API reader.
//
// Resource lists, logs, and Events do not travel over Morbstack's control socket.
// The bounded selected Pod/Node description instead uses the daemon's fixed
// `k8s-describe` payload so the CLI and inspector share one contract. The daemon
// publishes the local API server only on loopback and writes an app-owned kubeconfig
// when the person explicitly requests one. This client reads that configuration,
// pins its certificate authority, presents its client identity, and issues the
// remaining read-only API requests the native Tables and selected-pod inspector need.
// It never shells out to `kubectl`, never uses `~/.kube/config`, and never fabricates
// rows from a status summary.

import Foundation
import MorbstackKit
import Security

/// A narrowly scoped reader for Morbstack's local Kubernetes API.
final class KubernetesAPIClient: @unchecked Sendable {

    private let endpoint: URL
    private let credential: KubernetesAPICredential

    init(kubeconfigURL: URL) throws {
        let configuration = try KubernetesAPIConfiguration(kubeconfigURL: kubeconfigURL)
        endpoint = configuration.endpoint
        credential = try KubernetesAPICredential(configuration: configuration)
    }

    func resources() async throws -> K8sClusterResources {
        async let nodes = request("api/v1/nodes", as: KubernetesNodeList.self)
        async let pods = request("api/v1/pods", as: KubernetesPodList.self)
        let (nodeReply, podReply) = try await (nodes, pods)
        return K8sClusterResources(
            nodes: nodeReply.items.compactMap(K8sNodeInfo.init(apiObject:)),
            pods: podReply.items.compactMap(K8sPodInfo.init(apiObject:)))
    }

    /// A finite core/v1 event read for exactly one pod. Querying by UID is important:
    /// a pod name can be reused after deletion, while the UID cannot.
    func podEvents(namespace: String, uid: String) async throws -> [K8sPodEventInfo] {
        let reply = try await request(
            "api/v1/namespaces/\(namespace)/events",
            queryItems: [URLQueryItem(name: "fieldSelector", value: "involvedObject.uid=\(uid)")],
            as: KubernetesEventList.self)
        return reply.items
            .compactMap(K8sPodEventInfo.init(apiObject:))
            .sorted { lhs, rhs in
                (lhs.lastObserved ?? .distantPast) > (rhs.lastObserved ?? .distantPast)
            }
    }

    /// Reads a small, non-streaming slice of one regular container's current log.
    /// Kubernetes owns rotation and retention; `tailLines` bounds the presentation
    /// request, while omitting `follow` and `previous` prevents a long-lived stream or
    /// an implied restart-history feature.
    func podLog(namespace: String, pod: String, container: String) async throws -> String {
        let data = try await requestData(
            "api/v1/namespaces/\(namespace)/pods/\(pod)/log",
            queryItems: [
                URLQueryItem(name: "container", value: container),
                URLQueryItem(name: "tailLines", value: "200"),
                URLQueryItem(name: "timestamps", value: "true"),
            ],
            accept: "text/plain")
        return String(decoding: data, as: UTF8.self)
    }

    private func request<T: Decodable>(
        _ path: String,
        queryItems: [URLQueryItem] = [],
        as type: T.Type
    ) async throws -> T {
        let data = try await requestData(path, queryItems: queryItems, accept: "application/json")
        do {
            return try KubernetesJSON.makeDecoder().decode(T.self, from: data)
        } catch {
            throw K8sResourceAccessError.unavailable(
                "The local Kubernetes API returned data Morbstack could not read: \(error.localizedDescription)")
        }
    }

    private func requestData(
        _ path: String,
        queryItems: [URLQueryItem],
        accept: String
    ) async throws -> Data {
        guard let relativeURL = URL(string: path, relativeTo: endpoint),
              var components = URLComponents(url: relativeURL, resolvingAgainstBaseURL: true)
        else {
            throw K8sResourceAccessError.unavailable("The Kubernetes API endpoint is invalid.")
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw K8sResourceAccessError.unavailable("The Kubernetes API request is invalid.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12

        let delegate = KubernetesAPISessionDelegate(credential: credential)
        let session = URLSession(
            configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw K8sResourceAccessError.unavailable("The local Kubernetes API returned no HTTP response.")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw K8sResourceAccessError.unavailable(
                    "The local Kubernetes API returned HTTP \(http.statusCode). Generate a new kubeconfig if the cluster was restarted.")
            }
            return data
        } catch let error as K8sResourceAccessError {
            throw error
        } catch {
            throw K8sResourceAccessError.unavailable(
                "Morbstack could not connect to the local Kubernetes API: \(error.localizedDescription)")
        }
    }
}

// MARK: - Kubeconfig credentials

private struct KubernetesAPIConfiguration {
    let endpoint: URL
    let certificateAuthority: Data
    let clientCertificate: Data
    let clientKey: Data
    /// k3s (and most modern issuers) hand out ECDSA client keys by default; only
    /// older setups issue RSA. Read from the PEM header rather than assuming one
    /// algorithm — assuming RSA here previously made every real k3s cluster's
    /// client key fail `SecKeyCreateWithData` and the whole route report a
    /// generic "kubeconfig … cannot be used for a TLS-authenticated connection"
    /// even though the file and the cluster were both fine.
    let clientKeyType: CFString

    init(kubeconfigURL: URL) throws {
        guard FileManager.default.fileExists(atPath: kubeconfigURL.path) else {
            throw K8sResourceAccessError.kubeconfigRequired
        }
        let contents: Data
        do {
            contents = try Data(contentsOf: kubeconfigURL, options: .mappedIfSafe)
        } catch {
            throw K8sResourceAccessError.unavailable(
                "Morbstack could not read its kubeconfig: \(error.localizedDescription)")
        }
        guard let text = String(data: contents, encoding: .utf8) else {
            throw K8sResourceAccessError.malformedKubeconfig
        }

        func scalar(_ key: String) -> String? {
            for rawLine in text.split(whereSeparator: \.isNewline) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("\(key):") else { continue }
                let value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { continue }
                return String(value)
            }
            return nil
        }

        /// Kubeconfig embeds these PEM documents as strict base64 scalars. Decode
        /// them explicitly rather than passing an overloaded initializer through
        /// `Optional.flatMap`, which loses its result type under Swift 6 inference.
        func embeddedData(_ key: String) -> Data? {
            guard let encoded = scalar(key) else { return nil }
            return Data(base64Encoded: encoded, options: [])
        }

        guard let server = scalar("server"),
              let parsedEndpoint = URL(string: server),
              parsedEndpoint.scheme == "https",
              parsedEndpoint.host == "127.0.0.1",
              parsedEndpoint.port != nil,
              let authority = embeddedData("certificate-authority-data"),
              let certificate = embeddedData("client-certificate-data"),
              let key = embeddedData("client-key-data")
        else {
            throw K8sResourceAccessError.malformedKubeconfig
        }

        // Add a trailing slash so a relative `api/v1/pods` path is rooted at the
        // API server rather than replacing a final path component.
        endpoint = parsedEndpoint.absoluteString.hasSuffix("/")
            ? parsedEndpoint
            : URL(string: parsedEndpoint.absoluteString + "/")!
        guard let authorityDER = KubernetesClientTLS.der(from: authority),
              let certificateDER = KubernetesClientTLS.der(from: certificate),
              let keyDER = KubernetesClientTLS.der(from: key)
        else {
            throw K8sResourceAccessError.malformedKubeconfig
        }
        clientKeyType = KubernetesClientTLS.keyType(from: key)
        certificateAuthority = authorityDER
        clientCertificate = certificateDER
        clientKey = keyDER
    }
}

private struct KubernetesAPICredential {
    let certificateAuthority: SecCertificate
    let clientCertificate: SecCertificate
    let identity: SecIdentity

    init(configuration: KubernetesAPIConfiguration) throws {
        guard let authority = SecCertificateCreateWithData(
            nil, configuration.certificateAuthority as CFData),
            let certificate = SecCertificateCreateWithData(
                nil, configuration.clientCertificate as CFData)
        else {
            throw K8sResourceAccessError.malformedKubeconfig
        }
        // Fixing the RSA/EC algorithm mismatch (see `clientKeyType` above) was not
        // enough on its own: `SecKeyCreateWithData` does not take the same byte
        // layout for every key type. `KubernetesClientTLS.der(from:)` produces the
        // SEC1 ASN.1 DER a PEM `-----BEGIN EC PRIVATE KEY-----` document actually
        // contains — correct as-is for RSA, whose PKCS#1 DER *is* the layout
        // `SecKeyCreateWithData` wants, but wrong for EC, which needs Apple's own
        // ANSI X9.63 external representation instead. Feeding it SEC1 bytes made
        // `SecKeyCreateWithData` fail outright, which is what was still producing
        // "cannot be used for a TLS-authenticated connection" after the RSA/EC fix.
        guard let keyData = KubernetesClientTLS.secKeyExternalRepresentation(
            der: configuration.clientKey,
            keyType: configuration.clientKeyType,
            certificate: certificate)
        else {
            throw K8sResourceAccessError.malformedKubeconfig
        }
        guard let key = SecKeyCreateWithData(
                keyData as CFData,
                [
                    kSecAttrKeyType: configuration.clientKeyType,
                    kSecAttrKeyClass: kSecAttrKeyClassPrivate,
                ] as CFDictionary,
                nil),
            let identity = SecIdentityCreate(nil, certificate, key)
        else {
            throw K8sResourceAccessError.malformedKubeconfig
        }
        certificateAuthority = authority
        clientCertificate = certificate
        self.identity = identity
    }
}

private final class KubernetesAPISessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private let credential: KubernetesAPICredential

    init(credential: KubernetesAPICredential) {
        self.credential = credential
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust,
                  SecTrustSetAnchorCertificates(trust, [credential.certificateAuthority] as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
                  SecTrustEvaluateWithError(trust, nil)
            else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))

        case NSURLAuthenticationMethodClientCertificate:
            completionHandler(
                .useCredential,
                URLCredential(
                    identity: credential.identity,
                    certificates: [credential.clientCertificate],
                    persistence: .forSession))

        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - Kubernetes JSON

private enum KubernetesJSON {
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ordinary = ISO8601DateFormatter()
        ordinary.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = fractional.date(from: value) ?? ordinary.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "invalid Kubernetes timestamp")
        }
        return decoder
    }
}


private struct KubernetesNodeList: Decodable {
    var items: [KubernetesNodeObject]
}

private struct KubernetesNodeObject: Decodable {
    var metadata: KubernetesMetadata
    var status: Status?

    struct Status: Decodable {
        var conditions: [Condition]?
        var nodeInfo: NodeInfo?
    }

    struct Condition: Decodable {
        var type: String
        var status: String
    }

    struct NodeInfo: Decodable {
        var kubeletVersion: String?
    }
}

private struct KubernetesPodList: Decodable {
    var items: [KubernetesPodObject]
}

private struct KubernetesPodObject: Decodable {
    var metadata: KubernetesMetadata
    var spec: Spec?
    var status: Status?

    struct Spec: Decodable {
        var nodeName: String?
        var containers: [Container]?
    }

    struct Container: Decodable {
        var name: String?
        var image: String?
    }

    struct Status: Decodable {
        var phase: String?
        var containerStatuses: [ContainerStatus]?
    }

    struct ContainerStatus: Decodable {
        var name: String?
        var ready: Bool
        var restartCount: Int
        var state: State?
    }

    struct State: Decodable {
        var waiting: Waiting?
        var running: Running?
        var terminated: Terminated?
    }

    struct Running: Decodable {}

    struct Waiting: Decodable {
        var reason: String?
    }

    struct Terminated: Decodable {
        var reason: String?
    }
}

private struct KubernetesMetadata: Decodable {
    var name: String?
    var namespace: String?
    var uid: String?
    var creationTimestamp: Date?
    var labels: [String: String]?
}

private struct KubernetesEventList: Decodable {
    var items: [KubernetesEventObject]
}

/// The classic core/v1 Event endpoint remains widely available to a local k3s
/// cluster. It reports the object relation as `involvedObject`, unlike the newer
/// `events.k8s.io/v1` shape, so use the core endpoint deliberately here.
private struct KubernetesEventObject: Decodable {
    var metadata: KubernetesMetadata
    var type: String?
    var reason: String?
    var message: String?
    var count: Int?
    var eventTime: Date?
    var lastTimestamp: Date?
    var firstTimestamp: Date?
}

private extension K8sNodeInfo {
    init?(apiObject: KubernetesNodeObject) {
        guard let name = apiObject.metadata.name, !name.isEmpty else { return nil }
        let labels = apiObject.metadata.labels ?? [:]
        let rolePrefix = "node-role.kubernetes.io/"
        let roles = labels.keys.compactMap { key -> String? in
            guard key.hasPrefix(rolePrefix) else { return nil }
            let role = String(key.dropFirst(rolePrefix.count))
            return role.isEmpty ? nil : role
        }.sorted()
        let ready = apiObject.status?.conditions?.contains {
            $0.type == "Ready" && $0.status == "True"
        } ?? false
        self.init(
            name: name,
            roles: roles,
            ready: ready,
            version: apiObject.status?.nodeInfo?.kubeletVersion ?? "—",
            age: apiObject.metadata.creationTimestamp)
    }
}

private extension K8sPodInfo {
    init?(apiObject: KubernetesPodObject) {
        guard let name = apiObject.metadata.name, !name.isEmpty else { return nil }
        let statuses = apiObject.status?.containerStatuses ?? []
        let statusByName = Dictionary(
            uniqueKeysWithValues: statuses.compactMap { status in
                status.name.map { ($0, status) }
            })
        let waitingReasons = statuses.compactMap { $0.state?.waiting?.reason }
        let phase: Phase
        if waitingReasons.contains("CrashLoopBackOff") {
            phase = .crashLoop
        } else {
            switch apiObject.status?.phase {
            case "Running": phase = .running
            case "Pending": phase = .pending
            case "Succeeded": phase = .completed
            case "Failed": phase = .failed
            case let value?: phase = .unknown(value)
            case nil: phase = .unknown("Unknown")
            }
        }
        self.init(
            name: name,
            namespace: apiObject.metadata.namespace ?? "default",
            phase: phase,
            readyContainers: statuses.filter(\.ready).count,
            totalContainers: max(statuses.count, apiObject.spec?.containers?.count ?? 0),
            restarts: statuses.reduce(into: 0) { $0 += $1.restartCount },
            node: apiObject.spec?.nodeName ?? "",
            age: apiObject.metadata.creationTimestamp,
            uid: apiObject.metadata.uid,
            containers: (apiObject.spec?.containers ?? []).compactMap { container in
                guard let name = container.name, !name.isEmpty else { return nil }
                let status = statusByName[name]
                return K8sPodContainerInfo(
                    name: name,
                    image: container.image ?? "Unavailable",
                    state: Self.stateLabel(for: status),
                    ready: status?.ready ?? false,
                    restarts: status?.restartCount ?? 0)
            })
    }

    private static func stateLabel(for status: KubernetesPodObject.ContainerStatus?) -> String {
        guard let status else { return "Unknown" }
        if let reason = status.state?.waiting?.reason, !reason.isEmpty { return reason }
        if status.state?.running != nil { return "Running" }
        if let reason = status.state?.terminated?.reason, !reason.isEmpty { return reason }
        if status.state?.terminated != nil { return "Terminated" }
        return status.ready ? "Running" : "Unknown"
    }
}

private extension K8sPodEventInfo {
    init?(apiObject: KubernetesEventObject) {
        guard let id = apiObject.metadata.uid ?? apiObject.metadata.name, !id.isEmpty else { return nil }
        self.init(
            id: id,
            type: apiObject.type?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Normal",
            reason: apiObject.reason?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Event",
            message: apiObject.message?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "No message was returned by Kubernetes.",
            count: max(1, apiObject.count ?? 1),
            lastObserved: apiObject.eventTime ?? apiObject.lastTimestamp ?? apiObject.firstTimestamp ?? apiObject.metadata.creationTimestamp)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
