// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Anonymous OCI Distribution reference resolution — beside RegistryImageDiscovery.swift,
// and inheriting its discipline (bounded body, no redirects, no ambient config, explicit
// request only). See docs/audit/UI-FEATURE-GAP.md §3 (UX-5 resolved) for why this exists
// instead of a second search surface: OCI Distribution defines no portable registry
// search, but `GET /v2/<repo>/tags/list` and `GET /v2/<repo>/manifests/<ref>` are
// anonymous on every registry that speaks the spec, reached through the spec's own
// anonymous bearer dance (401 → `WWW-Authenticate: Bearer realm=…,service=…,scope=…` →
// fetch the realm → use the token). That token is scoped to one pull and stored nowhere;
// it is not a credential, and the GUI-never-holds-a-credential boundary survives.
//
// What this answers that `TrackCImageArchitecture.swift` cannot: whether a tag has an
// arm64 manifest *before* the pull, not after.
//
// Every network value here is attacker-controlled — the registry answering a 401
// controls `realm`/`service`/`scope`, and the realm's own answer controls the token —
// so every one of them is validated before it is used, never string-interpolated into a
// request line the way MinimalHTTP.percentEncodePath exists to prevent (this transport is
// real HTTPS through URLSession/URLComponents, which encodes query values by
// construction; the discipline here is validating *before* that boundary, not
// re-implementing it).

import Foundation

// MARK: - Reference

/// A parsed, validated OCI reference: `[host[:port]/]repository[:tag]`.
///
/// A single-segment repository with no explicit host resolves to Docker Hub's registry
/// host with the implicit `library/` namespace, matching `docker pull nginx`. A first
/// path segment is treated as a host only when it looks like one — contains `.` or `:`,
/// or is exactly `localhost` — which is the same heuristic `docker`'s own reference
/// parser uses to tell `nginx/nginx` (a Hub repository under the `nginx` org) from
/// `registry.example.com/nginx` (a host).
public struct RegistryReference: Equatable, Sendable {

    /// Docker's own public registry host — distinct from `hub.docker.com`, which serves
    /// the web UI and search API, not the Distribution API.
    public static let dockerHubHost = "registry-1.docker.io"

    /// A DNS host, optionally `host:port`, already lowercased.
    public let registryHost: String
    /// A validated OCI repository path, e.g. `library/alpine` or `owner/repo`.
    public let repository: String
    /// An optional tag parsed from the trailing `:tag` on the last path segment.
    public let tag: String?

    /// `repository` for Docker Hub (its host is implied everywhere else in the UI),
    /// `host/repository` otherwise; `:tag` appended when present.
    public var displayReference: String {
        let base = registryHost == Self.dockerHubHost ? repository : "\(registryHost)/\(repository)"
        guard let tag else { return base }
        return "\(base):\(tag)"
    }

    public init(parsing raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 320,
            !trimmed.contains("@"),  // digest references are not supported by this resolver
            trimmed.unicodeScalars.allSatisfy({ scalar in
                !CharacterSet.controlCharacters.contains(scalar) && !CharacterSet.whitespaces.contains(scalar)
            })
        else {
            throw RegistryReferenceResolverFailure.invalidReference
        }

        var remainder = trimmed
        var tag: String?

        // A tag is a trailing `:value` on the *last path segment only* — scanning the
        // whole string for `:` would mistake a `host:port` for a tag delimiter.
        let lastSlash = remainder.lastIndex(of: "/")
        let tailStart = lastSlash.map { remainder.index(after: $0) } ?? remainder.startIndex
        let tail = remainder[tailStart...]
        if let colon = tail.lastIndex(of: ":") {
            let candidate = String(tail[tail.index(after: colon)...])
            guard RegistryReferenceResolver.isValidTag(candidate) else {
                throw RegistryReferenceResolverFailure.invalidReference
            }
            tag = candidate
            remainder = String(remainder[remainder.startIndex..<colon])
        }

        let firstSlash = remainder.firstIndex(of: "/")
        let hostCandidate = firstSlash.map { String(remainder[remainder.startIndex..<$0]) }
        let looksLikeHost = hostCandidate.map { $0.contains(".") || $0.contains(":") || $0 == "localhost" } ?? false

        let host: String
        let repositoryPath: String
        if let hostCandidate, looksLikeHost, let firstSlash {
            host = hostCandidate
            repositoryPath = String(remainder[remainder.index(after: firstSlash)...])
        } else {
            host = Self.dockerHubHost
            repositoryPath = remainder.contains("/") ? remainder : "library/\(remainder)"
        }
        guard !repositoryPath.isEmpty else {
            throw RegistryReferenceResolverFailure.invalidReference
        }

        // Reuses `OCIRegistryRepository`'s own host/repository grammar rather than a
        // second copy of it, so the two features agree on what a safe name looks like.
        let validated: OCIRegistryRepository
        do {
            validated = try OCIRegistryRepository(registryHost: host, repository: repositoryPath)
        } catch {
            throw RegistryReferenceResolverFailure.invalidReference
        }
        self.registryHost = validated.registryHost
        self.repository = validated.repository
        self.tag = tag
    }
}

// MARK: - Results

/// One repository's tags, from the first page the registry returned.
public struct RegistryTagPage: Equatable, Sendable {
    public let reference: RegistryReference
    public let tags: [String]
    /// `true` when the registry reported more tags than this page carries (a `Link`
    /// header, or more tags than the requested page size). Never a cursor to follow —
    /// this resolver asks the person to narrow the reference rather than paginating an
    /// unauthenticated crawl.
    public let hasMoreTags: Bool
}

/// One CPU/OS platform an image manifest was built for.
public struct RegistryPlatform: Equatable, Hashable, Sendable {
    public let os: String
    public let architecture: String
    public let variant: String?

    /// `arm64`, `arm/v7` — the same short form `ImageArchitecture.shortName` uses, kept
    /// independent here since `MorbstackKit` does not depend on the app's image-list
    /// presentation types.
    public var shortName: String {
        guard let variant, !variant.isEmpty else { return architecture }
        return "\(architecture)/\(variant)"
    }
}

/// Whether a tag publishes a multi-platform manifest, and if so, for which platforms.
///
/// `isMultiPlatform == false` is a real, distinct answer from "no platforms found": a
/// single-architecture manifest does not carry its own platform in the manifest body
/// (that lives in the image config blob, a second fetch this resolver does not make), so
/// the honest statement is "this tag does not publish a multi-platform manifest" rather
/// than an empty list that reads as "built for nothing".
public struct RegistryPlatformResolution: Equatable, Sendable {
    public let tag: String
    public let isMultiPlatform: Bool
    public let platforms: [RegistryPlatform]
    /// The `Docker-Content-Digest` response header, when the registry sent one.
    public let manifestDigest: String?
}

// MARK: - Failures

public enum RegistryReferenceResolverFailure: Error, Equatable, Sendable, LocalizedError {
    case invalidReference
    case invalidTag
    case cancelled
    case timedOut
    case responseTooLarge
    case redirected
    case rateLimited(retryAfterSeconds: Int?)
    case unauthorized
    case notFound
    case unavailable(statusCode: Int)
    case insecureAuthEndpoint
    case malformedChallenge
    case malformedTokenResponse
    case malformedResponse
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidReference:
            return "Enter a reference like `nginx`, `nginx:1.27`, or `ghcr.io/owner/repo:tag`."
        case .invalidTag:
            return "Enter a tag to look up its platforms."
        case .cancelled:
            return "The registry lookup was cancelled."
        case .timedOut:
            return "The registry did not answer in time. Try again."
        case .responseTooLarge:
            return "The registry returned a response that was too large to read safely."
        case .redirected:
            return "The registry redirected the request, so Morbstack stopped it."
        case .rateLimited(let retryAfterSeconds):
            if let retryAfterSeconds {
                return "The registry is rate-limiting anonymous requests. Try again in about \(retryAfterSeconds) seconds."
            }
            return "The registry is rate-limiting anonymous requests. Try again later."
        case .unauthorized:
            return "This repository is not readable anonymously. Morbstack never holds a registry credential; pull it with the docker CLI instead."
        case .notFound:
            return "The registry has no repository or tag matching that reference."
        case .unavailable(let statusCode):
            return "The registry is unavailable (HTTP \(statusCode))."
        case .insecureAuthEndpoint:
            return "The registry's authentication endpoint did not use HTTPS, so Morbstack refused it."
        case .malformedChallenge, .malformedTokenResponse, .malformedResponse:
            return "The registry returned data Morbstack could not read."
        case .transport(let message):
            return "Morbstack could not reach the registry: \(message)"
        }
    }
}

// MARK: - Resolver

/// Resolves one explicit reference at a time: no automatic refresh, no debounce, no
/// prefetch, no background task, no credential lookup, no image pull, no daemon call.
/// The caller owns when a user action invokes ``tags(for:)``/``platforms(for:tag:)`` and
/// can cancel its enclosing `Task`.
public final class RegistryReferenceResolver: @unchecked Sendable {

    public static let maximumTags = 100
    static let maximumListResponseBytes = 256 * 1024
    static let maximumManifestResponseBytes = 256 * 1024
    static let maximumTokenResponseBytes = 16 * 1024
    static let requestTimeout: TimeInterval = 12

    public init() {}

    /// `GET /v2/<repo>/tags/list`, anonymous, first page only.
    public func tags(for reference: RegistryReference) async throws -> RegistryTagPage {
        try Task.checkCancellation()
        let result = try await authenticatedGET(
            host: reference.registryHost,
            path: "/v2/\(reference.repository)/tags/list",
            query: [URLQueryItem(name: "n", value: String(Self.maximumTags))],
            accept: ["application/json"],
            scopeRepository: reference.repository,
            maximumResponseBytes: Self.maximumListResponseBytes)
        try Self.requireSuccess(result)
        return try Self.tagPage(from: result.body, reference: reference, linkHeader: result.headers["link"])
    }

    /// `GET /v2/<repo>/manifests/<tag>`, anonymous, asking first for an OCI image index
    /// or Docker manifest list so a multi-platform tag's whole platform set arrives in
    /// one request.
    public func platforms(for reference: RegistryReference, tag explicitTag: String? = nil) async throws
        -> RegistryPlatformResolution
    {
        guard let tag = explicitTag ?? reference.tag, Self.isValidTag(tag) else {
            throw RegistryReferenceResolverFailure.invalidTag
        }
        try Task.checkCancellation()
        let result = try await authenticatedGET(
            host: reference.registryHost,
            path: "/v2/\(reference.repository)/manifests/\(tag)",
            query: [],
            accept: [
                "application/vnd.oci.image.index.v1+json",
                "application/vnd.docker.distribution.manifest.list.v2+json",
                "application/vnd.oci.image.manifest.v1+json",
                "application/vnd.docker.distribution.manifest.v2+json",
            ],
            scopeRepository: reference.repository,
            maximumResponseBytes: Self.maximumManifestResponseBytes)
        try Self.requireSuccess(result)
        return try Self.platformResolution(
            from: result.body,
            contentType: result.headers["content-type"] ?? "",
            tag: tag,
            digest: result.headers["docker-content-digest"])
    }

    // MARK: - Pure, fixture-testable parsing

    static func isValidTag(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count), let first = value.utf8.first else { return false }
        let firstIsWordChar =
            (first >= 0x30 && first <= 0x39) || (first >= 0x41 && first <= 0x5A) || (first >= 0x61 && first <= 0x7A)
            || first == 0x5F
        guard firstIsWordChar else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x5F || byte == 0x2E || byte == 0x2D
        }
    }

    /// A base64url-ish charset with the JWT `.` separator; nothing whitespace or control
    /// ever reaches an `Authorization` header built from this.
    static func isSafeBearerToken(_ token: String) -> Bool {
        guard (1...8_192).contains(token.utf8.count) else { return false }
        return token.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2D || byte == 0x5F || byte == 0x2E || byte == 0x3D || byte == 0x2B || byte == 0x2F
        }
    }

    struct BearerChallenge: Equatable {
        let realm: String
        let service: String?
        let scope: String?
    }

    /// Parses `WWW-Authenticate: Bearer realm="…",service="…",scope="…"` (RFC 9110
    /// framing). The realm is the only field that becomes a request destination; it is
    /// required to be `https`, and everything else here is used only as an already-
    /// percent-encoded query *value* (see ``fetchToken``), never interpolated into a path.
    static func parseBearerChallenge(_ header: String) throws -> BearerChallenge {
        guard header.utf8.count <= 4_096 else { throw RegistryReferenceResolverFailure.malformedChallenge }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bearer") else {
            throw RegistryReferenceResolverFailure.malformedChallenge
        }

        var values: [String: String] = [:]
        let pattern = "([A-Za-z0-9_]+)=\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            throw RegistryReferenceResolverFailure.malformedChallenge
        }
        let ns = trimmed as NSString
        regex.enumerateMatches(in: trimmed, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges == 3 else { return }
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            values[key] = ns.substring(with: match.range(at: 2))
        }

        guard let realm = values["realm"], realm.utf8.count <= 2_048,
            let realmURL = URL(string: realm), realmURL.scheme == "https",
            let host = realmURL.host, !host.isEmpty
        else {
            throw RegistryReferenceResolverFailure.malformedChallenge
        }
        return BearerChallenge(realm: realm, service: values["service"], scope: values["scope"])
    }

    /// `{"token": "…"}` or the legacy `{"access_token": "…"}` some registries still send.
    static func extractBearerToken(from body: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw RegistryReferenceResolverFailure.malformedTokenResponse
        }
        let raw = (object["token"] as? String) ?? (object["access_token"] as? String)
        guard let raw, isSafeBearerToken(raw) else {
            throw RegistryReferenceResolverFailure.malformedTokenResponse
        }
        return raw
    }

    private struct TagsDocument: Decodable {
        let tags: [String]?
    }

    static func tagPage(from body: Data, reference: RegistryReference, linkHeader: String?) throws -> RegistryTagPage
    {
        guard let document = try? JSONDecoder().decode(TagsDocument.self, from: body) else {
            throw RegistryReferenceResolverFailure.malformedResponse
        }
        let all = document.tags ?? []
        let page = Array(all.prefix(maximumTags))
        let hasMore = all.count > maximumTags || (linkHeader?.contains("rel=\"next\"") ?? false)
        return RegistryTagPage(reference: reference, tags: page, hasMoreTags: hasMore)
    }

    private struct ManifestListDocument: Decodable {
        struct Entry: Decodable {
            struct Platform: Decodable {
                let os: String
                let architecture: String
                let variant: String?
            }
            let platform: Platform?
        }
        let manifests: [Entry]?
    }

    /// `os`/`architecture` of `"unknown"` marks a buildx attestation or SBOM manifest,
    /// not a runnable platform; including it would misreport what the tag can run on.
    static func platformResolution(
        from body: Data, contentType: String, tag: String, digest: String?
    ) throws -> RegistryPlatformResolution {
        let mediaType = contentType.lowercased()
        guard mediaType.contains("manifest.list") || mediaType.contains("image.index") else {
            return RegistryPlatformResolution(tag: tag, isMultiPlatform: false, platforms: [], manifestDigest: digest)
        }
        guard let document = try? JSONDecoder().decode(ManifestListDocument.self, from: body) else {
            throw RegistryReferenceResolverFailure.malformedResponse
        }
        let platforms =
            (document.manifests ?? [])
            .compactMap(\.platform)
            .filter { $0.os.lowercased() != "unknown" && $0.architecture.lowercased() != "unknown" }
            .map { RegistryPlatform(os: $0.os, architecture: $0.architecture, variant: $0.variant) }
        return RegistryPlatformResolution(tag: tag, isMultiPlatform: true, platforms: platforms, manifestDigest: digest)
    }

    private static func requireSuccess(_ result: RegistryHTTPResult) throws {
        switch result.status {
        case 200..<300: return
        case 401: throw RegistryReferenceResolverFailure.unauthorized
        case 404: throw RegistryReferenceResolverFailure.notFound
        case 429:
            throw RegistryReferenceResolverFailure.rateLimited(
                retryAfterSeconds: retryAfterSeconds(result.headers["retry-after"]))
        default: throw RegistryReferenceResolverFailure.unavailable(statusCode: result.status)
        }
    }

    private static func retryAfterSeconds(_ value: String?) -> Int? {
        guard let value, let seconds = Int(value.trimmingCharacters(in: .whitespaces)),
            (1...86_400).contains(seconds)
        else { return nil }
        return seconds
    }

    private static func splitHostPort(_ host: String) -> (hostname: String, port: Int?) {
        let parts = host.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, let port = Int(parts[1]) { return (String(parts[0]), port) }
        return (host, nil)
    }

    // MARK: - Transport

    /// One anonymous GET, retried once with a bearer token when the first attempt
    /// answers `401` and carries a `WWW-Authenticate: Bearer` challenge. A registry that
    /// serves a public repository with no challenge at all (some do) is handled by the
    /// first attempt succeeding outright.
    private func authenticatedGET(
        host: String, path: String, query: [URLQueryItem], accept: [String],
        scopeRepository: String, maximumResponseBytes: Int
    ) async throws -> RegistryHTTPResult {
        let first = try await rawGET(
            host: host, path: path, query: query, accept: accept, authorization: nil,
            maximumResponseBytes: maximumResponseBytes)
        guard first.status == 401, let challengeHeader = first.headers["www-authenticate"] else {
            return first
        }
        let challenge = try Self.parseBearerChallenge(challengeHeader)
        let scope = challenge.scope ?? "repository:\(scopeRepository):pull"
        let token = try await fetchToken(challenge: challenge, fallbackScope: scope)
        return try await rawGET(
            host: host, path: path, query: query, accept: accept, authorization: "Bearer \(token)",
            maximumResponseBytes: maximumResponseBytes)
    }

    private func fetchToken(challenge: BearerChallenge, fallbackScope: String) async throws -> String {
        guard let realmURL = URL(string: challenge.realm), realmURL.scheme == "https" else {
            throw RegistryReferenceResolverFailure.insecureAuthEndpoint
        }
        guard var components = URLComponents(url: realmURL, resolvingAgainstBaseURL: false) else {
            throw RegistryReferenceResolverFailure.malformedChallenge
        }
        var items = components.queryItems ?? []
        if let service = challenge.service { items.append(URLQueryItem(name: "service", value: service)) }
        items.append(URLQueryItem(name: "scope", value: challenge.scope ?? fallbackScope))
        components.queryItems = items
        guard let tokenURL = components.url else { throw RegistryReferenceResolverFailure.malformedChallenge }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("morbstack/\(MorbVersion.string)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await Self.runBoundedGET(
            request, maximumResponseBytes: Self.maximumTokenResponseBytes)
        guard (200..<300).contains(response.statusCode) else {
            throw RegistryReferenceResolverFailure.unauthorized
        }
        return try Self.extractBearerToken(from: data)
    }

    private func rawGET(
        host: String, path: String, query: [URLQueryItem], accept: [String],
        authorization: String?, maximumResponseBytes: Int
    ) async throws -> RegistryHTTPResult {
        var components = URLComponents()
        components.scheme = "https"
        let (hostname, port) = Self.splitHostPort(host)
        components.host = hostname
        components.port = port
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw RegistryReferenceResolverFailure.malformedResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        for value in accept { request.addValue(value, forHTTPHeaderField: "Accept") }
        request.setValue("morbstack/\(MorbVersion.string)", forHTTPHeaderField: "User-Agent")
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }

        let (data, response) = try await Self.runBoundedGET(request, maximumResponseBytes: maximumResponseBytes)
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String else { continue }
            headers[key.lowercased()] = "\(value)"
        }
        return RegistryHTTPResult(status: response.statusCode, headers: headers, body: data)
    }

    private static func runBoundedGET(
        _ request: URLRequest, maximumResponseBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await BoundedRegistryGET(maximumResponseBytes: maximumResponseBytes)
                .execute(request, timeout: requestTimeout)
        } catch let failure as RegistryReferenceResolverFailure {
            throw failure
        } catch is CancellationError {
            throw RegistryReferenceResolverFailure.cancelled
        } catch let error as URLError where error.code == .timedOut {
            throw RegistryReferenceResolverFailure.timedOut
        } catch let error as URLError where error.code == .cancelled {
            throw RegistryReferenceResolverFailure.cancelled
        } catch {
            throw RegistryReferenceResolverFailure.transport(error.localizedDescription)
        }
    }
}

struct RegistryHTTPResult {
    let status: Int
    /// Lowercased header names; `HTTPURLResponse.value(forHTTPHeaderField:)` is already
    /// case-insensitive, but this resolver reads headers as a plain dictionary in the
    /// pure-parsing helpers above so they stay testable without an `HTTPURLResponse`.
    let headers: [String: String]
    let body: Data
}

// MARK: - Bounded credential-free HTTPS transport

/// One-shot transport that rejects redirects and credential challenges, disables
/// cookies/cache/credential storage, and stops receiving once the response crosses the
/// caller's byte budget. Deliberately has no generic URL entry point — every call site in
/// this file already decided exactly which host, path and headers it wants.
private final class BoundedRegistryGET: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable
{
    typealias Reply = Result<(Data, HTTPURLResponse), Error>

    private let lock = NSLock()
    private let maximumResponseBytes: Int
    private var body = Data()
    private var response: HTTPURLResponse?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var terminalError: Error?
    private var finished = false
    private var cancellationRequested = false

    init(maximumResponseBytes: Int) {
        self.maximumResponseBytes = maximumResponseBytes
    }

    func execute(_ request: URLRequest, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    start(request, session: session, continuation: continuation)
                }
            },
            onCancel: {
                cancel()
            })
    }

    private func start(
        _ request: URLRequest,
        session: URLSession,
        continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
    ) {
        var cancelImmediately = false
        lock.lock()
        self.session = session
        self.continuation = continuation
        cancelImmediately = cancellationRequested
        if !cancelImmediately {
            let task = session.dataTask(with: request)
            self.task = task
            lock.unlock()
            task.resume()
            return
        }
        lock.unlock()
        finish(.failure(CancellationError()))
    }

    private func cancel() {
        let task: URLSessionDataTask?
        lock.lock()
        cancellationRequested = true
        task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            setTerminalError(RegistryReferenceResolverFailure.malformedResponse)
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > Int64(maximumResponseBytes) {
            setTerminalError(RegistryReferenceResolverFailure.responseTooLarge)
            completionHandler(.cancel)
            return
        }
        lock.lock()
        self.response = httpResponse
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var exceedsLimit = false
        lock.lock()
        if !finished, terminalError == nil {
            if data.count > maximumResponseBytes - body.count {
                terminalError = RegistryReferenceResolverFailure.responseTooLarge
                exceedsLimit = true
            } else {
                body.append(data)
            }
        }
        lock.unlock()
        if exceedsLimit { dataTask.cancel() }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        setTerminalError(RegistryReferenceResolverFailure.redirected)
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            // Do not consult credential storage or prompt: this transport is
            // credential-free by contract. Authentication for a registry happens only
            // through the bearer token this file fetches itself and attaches explicitly.
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let reply: Reply
        lock.lock()
        if let terminalError {
            reply = .failure(terminalError)
        } else if cancellationRequested {
            reply = .failure(CancellationError())
        } else if let error {
            reply = .failure(error)
        } else if let response {
            reply = .success((body, response))
        } else {
            reply = .failure(RegistryReferenceResolverFailure.malformedResponse)
        }
        lock.unlock()
        finish(reply)
    }

    private func setTerminalError(_ error: Error) {
        lock.lock()
        if terminalError == nil { terminalError = error }
        lock.unlock()
    }

    private func finish(_ reply: Reply) {
        let continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        let session: URLSession?
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        continuation = self.continuation
        self.continuation = nil
        session = self.session
        self.session = nil
        self.task = nil
        lock.unlock()

        session?.finishTasksAndInvalidate()
        continuation?.resume(with: reply)
    }
}
