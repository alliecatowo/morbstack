// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Bounded passive interpretation of the two Docker replies a fixed-port lease needs.
//
// DockerProxy still relays every byte through FDRelay. This helper only watches a
// normal response already headed to the client, and gives up rather than pretending a
// chunked, oversized, pipelined, or malformed exchange has an identity it can lease.

import Foundation

final class DockerPortLeaseResponseObserver {

    enum Kind {
        case create
        case start
    }

    enum Outcome: Equatable {
        case created(containerID: String)
        case startSucceeded
        case failed
        case unrecognized
    }

    private static let maximumHeadBytes = 64 * 1024
    private static let maximumCreateResponseBytes = 128 * 1024

    private let kind: Kind
    private let report: (Outcome) -> Void
    private var buffer = Data()
    private var completed = false

    init(kind: Kind, report: @escaping (Outcome) -> Void) {
        self.kind = kind
        self.report = report
    }

    /// Observes guest-to-client bytes. The owning FDRelay calls this on one serial
    /// relay queue, so no additional synchronization can reorder a response head and
    /// its JSON body.
    func receive(_ data: Data) {
        guard !completed else { return }
        buffer.append(data)

        while !completed {
            guard buffer.count <= Self.maximumHeadBytes + Self.maximumCreateResponseBytes else {
                finish(.unrecognized)
                return
            }
            let parsed: (head: HTTPResponseHead, consumed: Int)?
            do {
                parsed = try MinimalHTTP.parseHead(buffer)
            } catch {
                finish(.unrecognized)
                return
            }
            guard let parsed else {
                if buffer.count > Self.maximumHeadBytes { finish(.unrecognized) }
                return
            }

            // `100 Continue` is not a create/start verdict. Discard that complete
            // interim head and wait for the final response without touching payload
            // bytes in FDRelay.
            if (100..<200).contains(parsed.head.statusCode) {
                buffer.removeFirst(parsed.consumed)
                continue
            }

            switch kind {
            case .start:
                // Docker's documented start success is exactly 204. A 304 already
                // started reply leaves the existing lease held; it is not proof that
                // this request performed a handoff.
                finish(parsed.head.statusCode == 204 ? .startSucceeded : .failed)

            case .create:
                guard (200..<300).contains(parsed.head.statusCode) else {
                    finish(.failed)
                    return
                }
                guard !parsed.head.isChunked,
                      let bodyLength = parsed.head.contentLength,
                      (1...Self.maximumCreateResponseBytes).contains(bodyLength)
                else {
                    finish(.unrecognized)
                    return
                }
                let bodyEnd = parsed.consumed + bodyLength
                guard buffer.count >= bodyEnd else { return }
                let body = Data(buffer[parsed.consumed..<bodyEnd])
                guard
                    let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                    let containerID = object["Id"] as? String,
                    !containerID.isEmpty
                else {
                    finish(.unrecognized)
                    return
                }
                finish(.created(containerID: containerID))
            }
        }
    }

    /// The relay ended before this bounded parser saw a usable final response.
    func relayFinished() {
        guard !completed else { return }
        finish(.unrecognized)
    }

    private func finish(_ outcome: Outcome) {
        guard !completed else { return }
        completed = true
        buffer.removeAll(keepingCapacity: false)
        report(outcome)
    }
}
