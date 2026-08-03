// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The app's intentionally small Kubernetes API reader.
//
// Kubernetes resources do not travel over Morbstack's control socket. The daemon
// publishes the local API server only on loopback and writes an app-owned kubeconfig
// when the person explicitly requests one. This client reads that one configuration,
// pins its certificate authority, presents its client identity, and issues the two
// read-only resource requests the native Tables need. It never shells out to `kubectl`,
// never uses `~/.kube/config`, and never fabricates rows from a status summary.

import Foundation
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

    private func request<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        guard let url = URL(string: path, relativeTo: endpoint) else {
            throw K8sResourceAccessError.unavailable("The Kubernetes API endpoint is invalid.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
            do {
                return try KubernetesJSON.makeDecoder().decode(T.self, from: data)
            } catch {
                throw K8sResourceAccessError.unavailable(
                    "The local Kubernetes API returned data Morbstack could not read: \(error.localizedDescription)")
            }
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
        guard let authorityDER = KubernetesPEM.der(from: authority),
              let certificateDER = KubernetesPEM.der(from: certificate),
              let keyDER = KubernetesPEM.der(from: key)
        else {
            throw K8sResourceAccessError.malformedKubeconfig
        }
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
                nil, configuration.clientCertificate as CFData),
            let key = SecKeyCreateWithData(
                configuration.clientKey as CFData,
                [
                    kSecAttrKeyType: kSecAttrKeyTypeRSA,
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

/// K3s stores PEM documents inside base64-encoded kubeconfig scalars. Security APIs
/// accept DER, so strip the PEM envelope without writing administrator credentials to
/// a keychain or a temporary file.
private enum KubernetesPEM {
    static func der(from data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        guard text.contains("-----BEGIN ") else { return data }
        let payload = text
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        return Data(base64Encoded: payload)
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

    struct Container: Decodable {}

    struct Status: Decodable {
        var phase: String?
        var containerStatuses: [ContainerStatus]?
    }

    struct ContainerStatus: Decodable {
        var ready: Bool
        var restartCount: Int
        var state: State?
    }

    struct State: Decodable {
        var waiting: Waiting?
    }

    struct Waiting: Decodable {
        var reason: String?
    }
}

private struct KubernetesMetadata: Decodable {
    var name: String?
    var namespace: String?
    var creationTimestamp: Date?
    var labels: [String: String]?
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
            age: apiObject.metadata.creationTimestamp)
    }
}
