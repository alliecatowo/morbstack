// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Deliberately small, public image discovery for a future native Images route.
//
// This is *not* a Docker client operation. It never contacts the Docker daemon,
// reads Docker config, credentials, cookies, or Keychain items, and it cannot pull
// an image. The only implemented provider is Docker Hub's credential-free public
// repository search endpoint, invoked only when a caller explicitly calls
// ``PublicImageDiscovery/search(_:)``.

import Foundation

/// A user-entered, bounded public image-discovery request.
///
/// The app should create one only after an explicit search command. Keeping the
/// scope with the query makes a future search field unable to silently turn a
/// Docker Hub search into a request to a custom registry.
public struct RegistryImageSearchRequest: Equatable, Sendable {

    /// Where the caller wants to search.
    ///
    /// OCI Distribution deliberately does not standardize registry-wide search.
    /// The repository case reserves a typed, explicit provider boundary for a
    /// future registry that has its own documented discovery API. It is not
    /// implemented by ``PublicImageDiscovery`` and never triggers a request.
    public enum Scope: Equatable, Sendable {
        /// Docker Hub's unauthenticated public repository search.
        case dockerHubPublic
        /// A known OCI repository for a future, registry-specific provider.
        case ociRepository(OCIRegistryRepository)
    }

    /// The normalized text sent as Docker Hub's `query` parameter.
    public let query: String
    public let scope: Scope

    /// Accepts one to 128 visible characters (and at most 512 UTF-8 bytes). Query syntax is not
    /// interpreted locally; it is percent-encoded as one URL query value.
    public init(query rawQuery: String, scope: Scope = .dockerHubPublic) throws {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              query.count <= Self.maximumQueryCharacters,
              query.utf8.count <= Self.maximumQueryUTF8Bytes,
              query.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw RegistryImageDiscoveryFailure.invalidQuery
        }
        self.query = query
        self.scope = scope
    }

    /// A deliberately small upper bound for a discoverability request, not an
    /// image-name parser. Docker Hub owns search grammar and relevance.
    public static let maximumQueryCharacters = 128
    public static let maximumQueryUTF8Bytes = 512
}

/// An explicit OCI registry/repository identity reserved for a future provider.
///
/// This value is intentionally not a URL and carries neither credentials nor a
/// scheme/path/query. The current discovery client rejects this scope before it
/// can make a connection. A future provider must define its own authentication,
/// trust, pagination, rate-limit, and registry compatibility contract instead of
/// treating the Docker Hub search API as a portable OCI capability.
public struct OCIRegistryRepository: Equatable, Sendable {
    public let registryHost: String
    public let repository: String

    public init(registryHost rawHost: String, repository rawRepository: String) throws {
        guard let host = Self.normalizedRegistryHost(rawHost),
              Self.isRepositoryName(rawRepository)
        else {
            throw RegistryImageDiscoveryFailure.invalidRegistryRepository
        }
        registryHost = host
        repository = rawRepository
    }

    private static func normalizedRegistryHost(_ rawHost: String) -> String? {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, host.utf8.count <= 253,
              !host.contains("/"), !host.contains("@"), !host.contains("?")
        else { return nil }

        let parts = host.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2,
              let hostname = parts.first,
              isDNSHost(String(hostname))
        else { return nil }

        if parts.count == 2 {
            guard let port = Int(parts[1]), (1...65_535).contains(port) else { return nil }
        }
        return host
    }

    private static func isDNSHost(_ hostname: String) -> Bool {
        guard !hostname.isEmpty, hostname.utf8.count <= 253 else { return false }
        let labels = hostname.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        return labels.allSatisfy { label in
            guard !label.isEmpty, label.utf8.count <= 63,
                  let first = label.utf8.first, let last = label.utf8.last,
                  isASCIIAlphaNumeric(first), isASCIIAlphaNumeric(last)
            else { return false }
            return label.utf8.allSatisfy { isASCIIAlphaNumeric($0) || $0 == 0x2D }
        }
    }

    fileprivate static func isRepositoryName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 255,
              !value.hasPrefix("/"), !value.hasSuffix("/")
        else { return false }
        let segments = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.isEmpty else { return false }
        return segments.allSatisfy { segment in
            guard !segment.isEmpty, segment.utf8.count <= 128,
                  let first = segment.utf8.first, let last = segment.utf8.last,
                  isASCIIAlphaNumeric(first), isASCIIAlphaNumeric(last)
            else { return false }
            return segment.utf8.allSatisfy {
                isASCIIAlphaNumeric($0) || $0 == 0x2D || $0 == 0x2E || $0 == 0x5F
            }
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39)
            || (byte >= 0x61 && byte <= 0x7A)
    }
}

/// One public repository result. It is a discovery hint only: no tag, digest,
/// vulnerability, provenance, compatibility, or pull availability is implied.
public struct RegistryImageSearchResult: Equatable, Sendable, Identifiable {
    public var id: String { repository }
    /// A repository name such as `library/alpine`, suitable to prefill—not execute—a
    /// future pull flow after that flow independently resolves a tag/digest.
    public let repository: String
    /// Docker Hub's short description after bounded control-character removal.
    public let summary: String?
    /// Docker Hub's reported star count when it is a nonnegative integer.
    public let starCount: Int?
    /// Docker Hub's reported pull count when it is a nonnegative integer.
    public let pullCount: Int?
    /// Docker Hub's reported official-image flag.
    public let isOfficial: Bool
    /// Docker Hub's reported automated-build flag.
    public let isAutomated: Bool
}

/// One bounded, first-page discovery result.
///
/// `hasMoreResults` deliberately does not contain a provider URL or cursor. The
/// initial native UI should ask the person to refine the query rather than following
/// an untrusted pagination URL or turning typing into an unbounded crawl.
public struct RegistryImageSearchPage: Equatable, Sendable {
    public let request: RegistryImageSearchRequest
    public let results: [RegistryImageSearchResult]
    public let hasMoreResults: Bool
}

/// States a native UI can present without guessing whether a query was cancelled,
/// limited by Docker Hub, unavailable, or structurally unsafe to display.
public enum RegistryImageDiscoveryFailure: Error, Equatable, Sendable, LocalizedError {
    case invalidQuery
    case invalidRegistryRepository
    case unsupportedScope
    case cancelled
    case timedOut
    case responseTooLarge
    case redirected
    case rateLimited(retryAfterSeconds: Int?)
    case unavailable(statusCode: Int)
    case malformedResponse
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidQuery:
            return "Enter one to \(RegistryImageSearchRequest.maximumQueryCharacters) characters of visible search text."
        case .invalidRegistryRepository:
            return "Use a DNS-style registry host and a Docker-style repository name."
        case .unsupportedScope:
            return "Morbstack can currently search public Docker Hub repositories only."
        case .cancelled:
            return "Image search was cancelled."
        case .timedOut:
            return "Docker Hub did not answer in time. Try the search again."
        case .responseTooLarge:
            return "Docker Hub returned a response that was too large to display safely."
        case .redirected:
            return "Docker Hub redirected the search request, so Morbstack stopped it."
        case .rateLimited(let retryAfterSeconds):
            if let retryAfterSeconds {
                return "Docker Hub is rate-limiting public search. Try again in about \(retryAfterSeconds) seconds."
            }
            return "Docker Hub is rate-limiting public search. Try again later."
        case .unavailable(let statusCode):
            return "Docker Hub search is unavailable (HTTP \(statusCode))."
        case .malformedResponse:
            return "Docker Hub returned search data Morbstack could not read."
        case .transport(let message):
            return "Morbstack could not reach Docker Hub: \(message)"
        }
    }
}

/// Searches public Docker Hub repositories with an explicit, bounded request.
///
/// There is no automatic refresh, debounce, prefetch, background task, credential
/// lookup, image pull, daemon call, or custom-registry fallback. The caller owns
/// when a user action invokes ``search(_:)`` and can cancel its enclosing `Task`.
public final class PublicImageDiscovery: @unchecked Sendable {
    /// Docker Hub permits a larger `page_size`; Morbstack intentionally asks for and
    /// returns at most this many records.
    public static let maximumResults = 25
    /// Includes the full JSON document, before decoding. This prevents an unexpected
    /// public endpoint response from becoming a large in-memory UI payload.
    public static let maximumResponseBytes = 512 * 1024
    public static let requestTimeout: TimeInterval = 12

    public init() {}

    /// Executes exactly one unauthenticated `GET` to Docker Hub after explicit caller
    /// intent. It follows no redirects and sends no cookies or credentials.
    public func search(_ request: RegistryImageSearchRequest) async throws -> RegistryImageSearchPage {
        guard request.scope == .dockerHubPublic else {
            throw RegistryImageDiscoveryFailure.unsupportedScope
        }
        try Task.checkCancellation()

        var components = URLComponents()
        components.scheme = "https"
        components.host = "hub.docker.com"
        components.path = "/v2/search/repositories/"
        components.queryItems = [
            URLQueryItem(name: "query", value: request.query),
            URLQueryItem(name: "page_size", value: String(Self.maximumResults)),
        ]
        guard let url = components.url else {
            throw RegistryImageDiscoveryFailure.malformedResponse
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = Self.requestTimeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("morbstack/\(MorbVersion.string)", forHTTPHeaderField: "User-Agent")

        let task = BoundedPublicGET(maximumResponseBytes: Self.maximumResponseBytes)
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await task.execute(urlRequest, timeout: Self.requestTimeout)
        } catch let failure as RegistryImageDiscoveryFailure {
            throw failure
        } catch is CancellationError {
            throw RegistryImageDiscoveryFailure.cancelled
        } catch let error as URLError where error.code == .timedOut {
            throw RegistryImageDiscoveryFailure.timedOut
        } catch let error as URLError where error.code == .cancelled {
            throw RegistryImageDiscoveryFailure.cancelled
        } catch {
            throw RegistryImageDiscoveryFailure.transport(error.localizedDescription)
        }

        switch response.statusCode {
        case 200..<300:
            break
        case 429:
            throw RegistryImageDiscoveryFailure.rateLimited(
                retryAfterSeconds: Self.retryAfterSeconds(response.value(forHTTPHeaderField: "Retry-After")))
        default:
            throw RegistryImageDiscoveryFailure.unavailable(statusCode: response.statusCode)
        }

        let document: DockerHubSearchDocument
        do {
            document = try JSONDecoder().decode(DockerHubSearchDocument.self, from: data)
        } catch {
            throw RegistryImageDiscoveryFailure.malformedResponse
        }

        var seen = Set<String>()
        let results = document.results.prefix(Self.maximumResults).compactMap { item -> RegistryImageSearchResult? in
            guard OCIRegistryRepository.isRepositoryName(item.repository), seen.insert(item.repository).inserted else {
                return nil
            }
            return RegistryImageSearchResult(
                repository: item.repository,
                summary: Self.boundedSummary(item.summary),
                starCount: item.starCount.flatMap { $0 >= 0 ? $0 : nil },
                pullCount: item.pullCount.flatMap { $0 >= 0 ? $0 : nil },
                isOfficial: item.isOfficial ?? false,
                isAutomated: item.isAutomated ?? false)
        }
        return RegistryImageSearchPage(
            request: request,
            results: results,
            hasMoreResults: document.next != nil || document.results.count > Self.maximumResults)
    }

    private static func retryAfterSeconds(_ value: String?) -> Int? {
        guard let value, let seconds = Int(value.trimmingCharacters(in: .whitespaces)),
              (1...86_400).contains(seconds)
        else { return nil }
        return seconds
    }

    private static func boundedSummary(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let visible = String(raw.filter { character in
            !character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visible.isEmpty else { return nil }
        return String(visible.prefix(512))
    }
}

// MARK: - Docker Hub response boundary

private struct DockerHubSearchDocument: Decodable {
    let results: [DockerHubSearchRecord]
    let next: String?
}

private struct DockerHubSearchRecord: Decodable {
    let repository: String
    let summary: String?
    let starCount: Int?
    let pullCount: Int?
    let isOfficial: Bool?
    let isAutomated: Bool?

    private enum CodingKeys: String, CodingKey {
        case repository = "repo_name"
        case summary = "short_description"
        case starCount = "star_count"
        case pullCount = "pull_count"
        case isOfficial = "is_official"
        case isAutomated = "is_automated"
    }
}

// MARK: - Bounded credential-free HTTPS transport

/// One-shot transport that rejects redirects and credential challenges, disables
/// cookies/cache/credential storage, and stops receiving once the response crosses
/// the caller's byte budget. It intentionally has no generic URL entry point.
private final class BoundedPublicGET: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
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
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                start(request, session: session, continuation: continuation)
            }
        }, onCancel: {
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
            setTerminalError(RegistryImageDiscoveryFailure.malformedResponse)
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > Int64(maximumResponseBytes) {
            setTerminalError(RegistryImageDiscoveryFailure.responseTooLarge)
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
                terminalError = RegistryImageDiscoveryFailure.responseTooLarge
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
        setTerminalError(RegistryImageDiscoveryFailure.redirected)
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
            // Do not consult credential storage or prompt: public discovery is
            // credential-free by contract.
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
            reply = .failure(RegistryImageDiscoveryFailure.malformedResponse)
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
