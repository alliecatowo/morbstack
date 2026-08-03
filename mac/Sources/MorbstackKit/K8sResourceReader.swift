// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// A fixed, certificate-pinned Kubernetes GET reader for selected Pods and Nodes.
//
// This is deliberately narrower than kubectl: it has no arbitrary path, body, verb,
// watch, log, exec, attach, port-forward, or workload-control capability. The daemon
// calls it only after the guest reports Ready and only with Morbstack's app-owned
// kubeconfig, which is created by an explicit user command.

import Foundation
import Security

/// Reads a bounded description for one selected local Kubernetes resource.
///
/// The daemon's control loop is intentionally synchronous, so this reader uses a
/// bounded URLSession request rather than making the control protocol grow a second
/// asynchronous response shape. It performs a single HTTPS GET to the trusted local
/// API forward and returns a small, typed value suitable for the CLI and native app.
public final class K8sResourceReader: @unchecked Sendable {
    private let endpoint: URL
    private let credential: Credential

    public init(kubeconfigURL: URL = K8s.defaultKubeconfigURL) throws {
        let configuration = try Configuration(kubeconfigURL: kubeconfigURL)
        endpoint = configuration.endpoint
        credential = try Credential(configuration: configuration)
    }

    public func describe(_ reference: K8s.ResourceReference) throws -> K8s.ResourceDescription {
        let path = try Self.path(for: reference)
        let data = try get(path)
        do {
            switch reference.kind {
            case .pod:
                return try JSONDecoder().decode(Pod.self, from: data).description(reference: reference)
            case .node:
                return try JSONDecoder().decode(Node.self, from: data).description(reference: reference)
            }
        } catch let error as MorbError {
            throw error
        } catch {
            throw MorbError.protocolViolation(
                "the local Kubernetes API returned a \(reference.kind.displayName.lowercased()) description Morbstack could not read: \(error.localizedDescription)")
        }
    }

    /// Reads the one current Pod identity a daemon-owned local port-forward may
    /// target. This is a fixed authenticated GET, not an arbitrary Kubernetes proxy:
    /// the coordinator supplies a validated namespace and Pod name, then compares the
    /// returned UID and regular-container state with its original selected request.
    public func portForwardTarget(namespace: String, pod name: String) throws -> K8sPodPortForwardTarget {
        try Self.validateSegment(namespace, named: "namespace")
        try Self.validateSegment(name, named: "Pod name")
        let data = try get("api/v1/namespaces/\(namespace)/pods/\(name)")
        do {
            return try JSONDecoder().decode(Pod.self, from: data)
                .portForwardTarget(namespace: namespace, name: name)
        } catch let error as MorbError {
            throw error
        } catch {
            throw MorbError.protocolViolation(
                "the selected Kubernetes Pod changed to a response Morbstack could not validate for port forwarding: \(error.localizedDescription)")
        }
    }

    // MARK: - Fixed request contract

    private static func path(for reference: K8s.ResourceReference) throws -> String {
        try validateSegment(reference.name, named: "resource name")
        switch reference.kind {
        case .pod:
            guard let namespace = reference.namespace else {
                throw MorbError.protocolViolation("a Pod description requires a namespace")
            }
            try validateSegment(namespace, named: "namespace")
            return "api/v1/namespaces/\(namespace)/pods/\(reference.name)"
        case .node:
            guard reference.namespace == nil else {
                throw MorbError.protocolViolation("a Node description must not include a namespace")
            }
            return "api/v1/nodes/\(reference.name)"
        }
    }

    /// Pod, Node, and Namespace names from Kubernetes are DNS-shaped. Requiring that
    /// shape here prevents an IPC caller from smuggling separators, query syntax, or
    /// another API path into an otherwise fixed GET contract.
    private static func validateSegment(_ value: String, named label: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy(allowed.contains),
              value.first?.isLetter == true || value.first?.isNumber == true,
              value.last?.isLetter == true || value.last?.isNumber == true,
              value.count <= 253
        else {
            throw MorbError.protocolViolation("the Kubernetes \(label) is not a supported DNS-style identifier")
        }
    }

    private func get(_ path: String) throws -> Data {
        guard let url = URL(string: path, relativeTo: endpoint)?.absoluteURL else {
            throw MorbError.protocolViolation("the local Kubernetes API request is invalid")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let delegate = SessionDelegate(credential: credential)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let result = SynchronousResult<Data>()
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                result.finish(.failure(error))
            } else if let data, let response = response as? HTTPURLResponse {
                result.finish(.success((data, response)))
            } else {
                result.finish(.failure(MorbError.io("the local Kubernetes API returned no HTTP response")))
            }
        }
        task.resume()
        guard let outcome = result.wait(timeout: 13) else {
            task.cancel()
            throw MorbError.timeout("the local Kubernetes API did not answer within 13 seconds")
        }
        let reply: (Data, HTTPURLResponse)
        do {
            reply = try outcome.get()
        } catch {
            throw MorbError.io("Morbstack could not connect to the local Kubernetes API: \(error.localizedDescription)")
        }
        let (data, response) = reply
        switch response.statusCode {
        case 200..<300:
            return data
        case 404:
            throw MorbError.io("the selected Kubernetes resource no longer exists; refresh the resource table and select it again")
        default:
            throw MorbError.io(
                "the local Kubernetes API returned HTTP \(response.statusCode); generate a new kubeconfig if the cluster was restarted")
        }
    }
}

// MARK: - App-owned kubeconfig and TLS identity

private struct Configuration {
    let endpoint: URL
    let certificateAuthority: Data
    let clientCertificate: Data
    let clientKey: Data

    init(kubeconfigURL: URL) throws {
        guard FileManager.default.fileExists(atPath: kubeconfigURL.path) else {
            throw MorbError.io(
                "Morbstack’s kubeconfig is missing. Run `morb k8s kubeconfig` before describing cluster resources.")
        }
        let text: String
        do {
            text = try String(contentsOf: kubeconfigURL, encoding: .utf8)
        } catch {
            throw MorbError.io("Morbstack could not read its kubeconfig: \(error.localizedDescription)")
        }

        func scalar(_ key: String) -> String? {
            text.split(whereSeparator: \.isNewline).lazy.compactMap { rawLine in
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("\(key):") else { return nil }
                let value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : String(value)
            }.first
        }
        func embeddedData(_ key: String) -> Data? {
            scalar(key).flatMap { Data(base64Encoded: $0, options: []) }
        }

        guard let server = scalar("server"),
              let parsedEndpoint = URL(string: server),
              parsedEndpoint.scheme == "https",
              parsedEndpoint.host == "127.0.0.1",
              parsedEndpoint.port != nil,
              let authority = embeddedData("certificate-authority-data"),
              let certificate = embeddedData("client-certificate-data"),
              let key = embeddedData("client-key-data"),
              let authorityDER = PEM.der(from: authority),
              let certificateDER = PEM.der(from: certificate),
              let keyDER = PEM.der(from: key)
        else {
            throw MorbError.protocolViolation("Morbstack’s kubeconfig is incomplete or not a trusted loopback configuration")
        }

        endpoint = parsedEndpoint.absoluteString.hasSuffix("/")
            ? parsedEndpoint : URL(string: parsedEndpoint.absoluteString + "/")!
        certificateAuthority = authorityDER
        clientCertificate = certificateDER
        clientKey = keyDER
    }
}

private struct Credential {
    let certificateAuthority: SecCertificate
    let clientCertificate: SecCertificate
    let identity: SecIdentity

    init(configuration: Configuration) throws {
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
            throw MorbError.protocolViolation("Morbstack’s kubeconfig credentials could not establish a TLS identity")
        }
        certificateAuthority = authority
        clientCertificate = certificate
        self.identity = identity
    }
}

private final class SessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private let credential: Credential

    init(credential: Credential) {
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

private final class SynchronousResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var value: Result<(Value, HTTPURLResponse), Error>?

    func finish(_ result: Result<(Value, HTTPURLResponse), Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard value == nil else { return }
        value = result
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> Result<(Value, HTTPURLResponse), Error>? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private enum PEM {
    static func der(from data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN ") else {
            return data
        }
        return Data(base64Encoded: text
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined())
    }
}

// MARK: - Bounded Kubernetes response decoding

private struct Metadata: Decodable {
    var uid: String?
    var creationTimestamp: String?
    var deletionTimestamp: String?
    var name: String?
    var namespace: String?
    var labels: [String: String]?
    var annotations: [String: String]?
}

private struct Pod: Decodable {
    var metadata: Metadata
    var spec: Spec?
    var status: Status?

    struct Spec: Decodable {
        var nodeName: String?
        var serviceAccountName: String?
        var hostNetwork: Bool?
        var containers: [Container]?

        struct Container: Decodable {
            var name: String?
        }
    }

    struct Status: Decodable {
        var phase: String?
        var podIP: String?
        var hostIP: String?
        var qosClass: String?
        var conditions: [Condition]?
        var containerStatuses: [ContainerStatus]?

        struct ContainerStatus: Decodable {
            var name: String?
            var ready: Bool?
            var state: ContainerState?
        }

        struct ContainerState: Decodable {
            var running: Running?

            struct Running: Decodable {}
        }
    }

    struct Condition: Decodable {
        var type: String?
        var status: String?
        var reason: String?
        var message: String?
    }

    func description(reference: K8s.ResourceReference) -> K8s.ResourceDescription {
        K8s.ResourceDescription(
            reference: reference,
            uid: Bound.text(metadata.uid),
            createdAt: Bound.text(metadata.creationTimestamp),
            facts: Bound.facts([
                ("Phase", status?.phase),
                ("Node", spec?.nodeName),
                ("Pod IP", status?.podIP),
                ("Host IP", status?.hostIP),
                ("Service Account", spec?.serviceAccountName),
                ("QoS Class", status?.qosClass),
                ("Host Network", spec?.hostNetwork.map { $0 ? "Yes" : "No" }),
            ]),
            conditions: Bound.conditions(status?.conditions ?? []),
            labels: Bound.metadata(metadata.labels),
            annotations: Bound.metadata(metadata.annotations))
    }

    func portForwardTarget(namespace: String, name: String) throws -> K8sPodPortForwardTarget {
        guard metadata.name == name, metadata.namespace == namespace,
              let uid = Bound.text(metadata.uid)
        else {
            throw MorbError.protocolViolation(
                "the Kubernetes API returned a Pod whose identity did not match the selected Pod")
        }
        var statuses: [String: Bool] = [:]
        for status in status?.containerStatuses ?? [] {
            guard let name = Bound.text(status.name) else { continue }
            statuses[name] = status.ready == true && status.state?.running != nil
        }
        let containers = (spec?.containers ?? []).compactMap { container -> K8sPodPortForwardTarget.Container? in
            guard let name = Bound.text(container.name) else { return nil }
            return K8sPodPortForwardTarget.Container(name: name, isRunning: statuses[name] == true)
        }
        return K8sPodPortForwardTarget(
            namespace: namespace,
            name: name,
            uid: uid,
            isRunning: status?.phase == "Running",
            isDeleting: metadata.deletionTimestamp != nil,
            containers: containers)
    }
}

private struct Node: Decodable {
    var metadata: Metadata
    var spec: Spec?
    var status: Status?

    struct Spec: Decodable { var unschedulable: Bool? }

    struct Status: Decodable {
        var conditions: [Condition]?
        var addresses: [Address]?
        var nodeInfo: NodeInfo?
    }

    struct Condition: Decodable {
        var type: String?
        var status: String?
        var reason: String?
        var message: String?
    }

    struct Address: Decodable { var type: String?; var address: String? }

    struct NodeInfo: Decodable {
        var kubeletVersion: String?
        var kernelVersion: String?
        var osImage: String?
        var operatingSystem: String?
        var architecture: String?
    }

    func description(reference: K8s.ResourceReference) -> K8s.ResourceDescription {
        let addresses = (status?.addresses ?? []).compactMap { address -> (String, String?)? in
            guard let type = Bound.text(address.type) else { return nil }
            return ("\(type) IP", address.address)
        }
        return K8s.ResourceDescription(
            reference: reference,
            uid: Bound.text(metadata.uid),
            createdAt: Bound.text(metadata.creationTimestamp),
            facts: Bound.facts([
                ("Scheduling", spec?.unschedulable == true ? "Disabled" : "Allowed"),
                ("Kubelet", status?.nodeInfo?.kubeletVersion),
                ("Kernel", status?.nodeInfo?.kernelVersion),
                ("OS Image", status?.nodeInfo?.osImage),
                ("Operating System", status?.nodeInfo?.operatingSystem),
                ("Architecture", status?.nodeInfo?.architecture),
            ] + addresses),
            conditions: Bound.conditions(status?.conditions ?? []),
            labels: Bound.metadata(metadata.labels),
            annotations: Bound.metadata(metadata.annotations))
    }
}

private enum Bound {
    static let maximumTextLength = 512
    static let maximumMetadataEntries = 24
    static let maximumConditions = 12

    static func text(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return String(trimmed.prefix(maximumTextLength))
    }

    static func facts(_ values: [(String, String?)]) -> [K8s.ResourceField] {
        values.compactMap { name, value in
            text(value).map { K8s.ResourceField(name: name, value: $0) }
        }
    }

    static func metadata(_ values: [String: String]?) -> [K8s.ResourceField] {
        (values ?? [:]).keys.sorted().prefix(maximumMetadataEntries).compactMap { key in
            guard let name = text(key), let value = text(values?[key]) else { return nil }
            return K8s.ResourceField(name: name, value: value)
        }
    }

    static func conditions(_ values: [Pod.Condition]) -> [K8s.ResourceCondition] {
        values.prefix(maximumConditions).compactMap { value in
            guard let type = text(value.type), let status = text(value.status) else { return nil }
            return K8s.ResourceCondition(
                type: type, status: status, reason: text(value.reason), message: text(value.message))
        }
    }

    static func conditions(_ values: [Node.Condition]) -> [K8s.ResourceCondition] {
        values.prefix(maximumConditions).compactMap { value in
            guard let type = text(value.type), let status = text(value.status) else { return nil }
            return K8s.ResourceCondition(
                type: type, status: status, reason: text(value.reason), message: text(value.message))
        }
    }
}
