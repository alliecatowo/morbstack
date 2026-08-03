// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The bounded transaction for one explicit-empty-TCP Docker create.

import Darwin
import Dispatch
import Foundation

/// Owns the one request shape that may change while crossing the Docker proxy.
///
/// Ordinary Engine traffic still belongs to ``FDRelay``. This transaction exists
/// only because an empty `HostPort` cannot be made truthful by passively observing a
/// later response: it sends a host-rewritten create document, waits for the complete
/// bounded `201`, associates the already-held dynamic-TCP lease, and only then releases any
/// `201` byte to the Docker client. It consumes the create's exact known length and
/// hands the client socket back to DockerProxy afterwards, so a following keep-alive
/// or already-pipelined request is never forwarded before that association.
final class DockerDynamicCreateTransaction {

    private static let maximumHeadBytes = 64 * 1024
    private static let maximumResponseBodyBytes = 128 * 1024
    private static let responseTimeout: TimeInterval = 60

    private struct Response {
        let head: HTTPResponseHead
        let raw: Data
        let body: Data
    }

    private let queue: DispatchQueue
    private let request: Data
    private let closeClientAfterResponse: Bool
    private let lock = NSLock()
    private var clientFD: Int32
    private var guestFD: Int32
    private var cancelled = false
    private var completed = false
    private var handOffClient = false

    /// Returns `false` when the returned ID cannot own this lease. It is called while
    /// the full create response remains private to this transaction.
    private let associate: (String) -> Bool
    private let abandon: (String) -> Void
    private let reportTransactionError: (String) -> Void
    /// Receives the client descriptor only after a successful associated `201`.
    /// `nil` means this transaction has closed its client connection.
    private let completion: (Int32?) -> Void

    init(
        clientFD: Int32,
        guestFD: Int32,
        request: Data,
        closeClientAfterResponse: Bool,
        queue: DispatchQueue,
        associate: @escaping (String) -> Bool,
        abandon: @escaping (String) -> Void,
        reportTransactionError: @escaping (String) -> Void,
        completion: @escaping (Int32?) -> Void
    ) {
        self.clientFD = clientFD
        self.guestFD = guestFD
        self.request = request
        self.closeClientAfterResponse = closeClientAfterResponse
        self.queue = queue
        self.associate = associate
        self.abandon = abandon
        self.reportTransactionError = reportTransactionError
        self.completion = completion
        POSIXSocketSupport.suppressSIGPIPE(clientFD)
        POSIXSocketSupport.suppressSIGPIPE(guestFD)
    }

    func start() {
        queue.async { [weak self] in
            self?.run()
        }
    }

    /// Wakes blocking reads and writes without racing a close against a syscall on
    /// the transaction worker. The worker performs the final close exactly once.
    func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let client = clientFD
        let guest = guestFD
        lock.unlock()
        // DockerProxy uses cancellation only for daemon/proxy teardown. Match the
        // ordinary relay's early-finish behavior: no create (even one whose worker
        // has not started yet) may keep a host listener alive after that teardown.
        abandon("the dynamic TCP create transaction was cancelled")
        if client >= 0 { _ = Darwin.shutdown(client, SHUT_RDWR) }
        if guest >= 0 { _ = Darwin.shutdown(guest, SHUT_RDWR) }
    }

    // MARK: - One create exchange

    private func run() {
        defer { finish() }
        guard !isCancelled else { return }

        guard POSIXSocketSupport.writeAll(currentGuestFD, request) else {
            abandon("the dynamic TCP create request could not reach the guest Engine")
            reportIfActive("morbstack could not send the dynamic port allocation to the Docker Engine")
            return
        }

        let response: Response
        do {
            response = try readResponse(from: currentGuestFD)
        } catch {
            abandon("the dynamic TCP create response was not a bounded HTTP response: \(error.localizedDescription)")
            reportIfActive("morbstack could not verify the Docker Engine response for the dynamic port allocation")
            return
        }
        guard !isCancelled else {
            abandon("the Docker client disconnected while its dynamic TCP create was in flight")
            return
        }

        guard response.head.statusCode == 201 else {
            abandon("Docker create returned HTTP \(response.head.statusCode)")
            if (200..<300).contains(response.head.statusCode) {
                reportIfActive("morbstack requires HTTP 201 before it can confirm a dynamic TCP port allocation")
                return
            }
            // A non-201 create cannot own a lease. Its bounded Engine response is
            // still the most useful diagnosis, and sending it does not violate the
            // success-before-association rule.
            _ = POSIXSocketSupport.writeAll(currentClientFD, response.raw)
            return
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
            let containerID = object["Id"] as? String,
            !containerID.isEmpty
        else {
            abandon("Docker create returned 201 without a usable container identity")
            reportIfActive("morbstack could not associate the dynamic TCP port allocation with Docker's create response")
            return
        }

        guard associate(containerID) else {
            abandon("Docker create returned an already-leased or unusable container identity")
            reportIfActive("morbstack could not retain the dynamic TCP port allocation for Docker's created container")
            return
        }

        // This is intentionally the first point any 201 bytes are released. The
        // existing start observer can now find the same held lease on a later request.
        guard POSIXSocketSupport.writeAll(currentClientFD, response.raw) else { return }
        if !closeClientAfterResponse { prepareClientHandoff() }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private var currentClientFD: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return clientFD
    }

    private var currentGuestFD: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return guestFD
    }

    private func reportIfActive(_ message: String) {
        guard !isCancelled else { return }
        reportTransactionError(message)
    }

    /// The original create has been read with an exact cap, and the guest connection
    /// has no second request on it. Preserve the client descriptor for DockerProxy to
    /// inspect afresh; this gives a same-connection `/start` the normal lease response
    /// observer instead of treating a keep-alive stream as opaque bytes.
    private func prepareClientHandoff() {
        lock.lock()
        if !cancelled { handOffClient = true }
        lock.unlock()
    }

    private func finish() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let client = clientFD
        let guest = guestFD
        let handoff = handOffClient && !cancelled
        clientFD = -1
        guestFD = -1
        lock.unlock()

        if client >= 0, !handoff { Darwin.close(client) }
        if guest >= 0 { Darwin.close(guest) }
        completion(handoff ? client : nil)
    }

    // MARK: - Bounded response framing

    private func readResponse(from fd: Int32) throws -> Response {
        let deadline = Date().addingTimeInterval(Self.responseTimeout)
        var buffer = Data()
        var parsed: (head: HTTPResponseHead, consumed: Int)?

        while true {
            if parsed == nil {
                guard buffer.count <= Self.maximumHeadBytes else {
                    throw MorbError.protocolViolation("the Docker Engine sent an oversized create response head")
                }
                parsed = try MinimalHTTP.parseHead(buffer)
            }

            if let parsed {
                guard !(100..<200).contains(parsed.head.statusCode) else {
                    throw MorbError.protocolViolation("the Docker Engine sent an interim response to a bounded dynamic create")
                }
                guard !parsed.head.isChunked,
                      let contentLength = parsed.head.contentLength,
                      (0...Self.maximumResponseBodyBytes).contains(contentLength)
                else {
                    throw MorbError.protocolViolation("the Docker Engine sent an unbounded dynamic create response")
                }

                let responseLength = parsed.consumed + contentLength
                if buffer.count >= responseLength {
                    guard buffer.count == responseLength else {
                        throw MorbError.protocolViolation("the Docker Engine sent bytes after a bounded dynamic create response")
                    }
                    let raw = buffer
                    let body = Data(raw.dropFirst(parsed.consumed))
                    return Response(head: parsed.head, raw: raw, body: body)
                }
            }

            guard Date() < deadline else {
                throw MorbError.timeout("the Docker Engine did not finish the dynamic create response")
            }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = max(1, Int32((deadline.timeIntervalSinceNow * 1_000).rounded(.up)))
            let polled = POSIXSocketSupport.retryOnInterrupt {
                withUnsafeMutablePointer(to: &poller) { poll($0, 1, remaining) }
            }
            if polled == 0 {
                throw MorbError.timeout("the Docker Engine did not finish the dynamic create response")
            }
            if polled < 0 {
                throw MorbError.io("polling the Docker Engine response failed: \(String(cString: strerror(errno)))")
            }

            var bytes = [UInt8](repeating: 0, count: 16 * 1024)
            let count = bytes.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return POSIXSocketSupport.readSome(fd, into: base, count: raw.count)
            }
            guard count > 0 else {
                if count == 0 {
                    throw MorbError.protocolViolation("the Docker Engine closed a dynamic create response early")
                }
                throw MorbError.io("reading the Docker Engine response failed: \(String(cString: strerror(errno)))")
            }
            buffer.append(contentsOf: bytes[0..<count])
            guard buffer.count <= Self.maximumHeadBytes + Self.maximumResponseBodyBytes else {
                throw MorbError.protocolViolation("the Docker Engine sent an oversized dynamic create response")
            }
        }
    }

    /// Replaces exactly one `Content-Length` header while retaining every other
    /// request-head byte (including header spelling and line endings). The caller has
    /// already proved a single valid numeric content length with `MinimalHTTP`.
    static func rewritingContentLength(in head: Data, bodyLength: Int) -> Data? {
        guard bodyLength >= 0 else { return nil }
        let bytes = [UInt8](head)
        var cursor = 0
        var foundContentLength = false
        var rewritten = Data()

        while let (contentEnd, next) = MinimalHTTP.lineBounds(bytes, from: cursor) {
            let line = String(decoding: bytes[cursor..<contentEnd], as: UTF8.self)
            if line.isEmpty {
                rewritten.append(contentsOf: bytes[cursor..<next])
                return foundContentLength ? rewritten : nil
            }

            if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                if name == "content-length" {
                    guard !foundContentLength else { return nil }
                    foundContentLength = true
                    rewritten.append(Data("Content-Length: \(bodyLength)".utf8))
                    rewritten.append(contentsOf: bytes[contentEnd..<next])
                    cursor = next
                    continue
                }
            }
            rewritten.append(contentsOf: bytes[cursor..<next])
            cursor = next
        }
        return nil
    }
}
