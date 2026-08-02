// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Dispatch
import Foundation

/// The two descriptors a relay owns, with a close-exactly-once guard.
///
/// Kept in its own object so the `DispatchIO` cleanup handlers can hold it strongly:
/// they must still close the descriptor even if the relay itself has been released,
/// and they must never close it twice — a double `close(2)` in a daemon that is also
/// opening sockets is how you end up relaying one client's bytes to another client.
final class RelayDescriptors {

    private let lock = NSLock()
    private var fds: [Int32]
    private var closed: [Bool]

    init(_ fdA: Int32, _ fdB: Int32) {
        fds = [fdA, fdB]
        closed = [false, false]
    }

    /// The live descriptor at `index`, or `nil` once it has been closed.
    func descriptor(_ index: Int) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return closed[index] ? nil : fds[index]
    }

    /// Closes the descriptor at `index` if it is still open. Idempotent.
    func close(_ index: Int) {
        lock.lock()
        let alreadyClosed = closed[index]
        closed[index] = true
        let fd = fds[index]
        lock.unlock()
        guard !alreadyClosed else { return }
        Darwin.close(fd)
    }

    /// Shuts down the write half of `index`, if it is still open.
    func shutdownWrite(_ index: Int) {
        lock.lock()
        let fd = closed[index] ? nil : fds[index]
        lock.unlock()
        guard let fd else { return }
        _ = Darwin.shutdown(fd, SHUT_WR)
    }
}

/// A bidirectional byte pump between two file descriptors, with half-close semantics.
///
/// `FDRelay` is what turns `~/.morbstack/run/docker.sock` into the guest's Docker
/// Engine API: one descriptor is the accepted CLI connection, the other is a vsock
/// connection to the VM.
///
/// Each direction is tracked independently. When a source reaches EOF the relay
/// **finishes flushing whatever is still queued towards the opposite descriptor** and
/// only then issues `shutdown(fd, SHUT_WR)` on it, so the peer sees a clean EOF after
/// the last byte rather than a truncated stream. Tearing both halves down on the first
/// EOF — the obvious implementation — silently cuts Docker API responses in half:
/// `dockerd` closes its side as soon as it has written the last chunk of a response,
/// and `DispatchIO.close(flags: .stop)` at that moment discards every write that has
/// not yet drained into the client socket.
///
/// The relay owns both descriptors and closes each exactly once.
public final class FDRelay {

    /// Per-direction bookkeeping, indexed by the *sink* channel.
    private struct Direction {
        /// The source for this direction has reached EOF.
        var sourceAtEOF = false
        /// Writes issued towards the sink that have not completed yet.
        var pendingWrites = 0
        /// `shutdown(sink, SHUT_WR)` has already been issued.
        var halfClosed = false
    }

    private let queue: DispatchQueue
    private let owned: RelayDescriptors
    private var channels: [DispatchIO] = []

    private var completion: (() -> Void)?
    private var finished = false
    private var openChannels = 2

    /// `directions[i]` describes the flow whose **sink** is channel `i`.
    private var directions: [Direction] = [Direction(), Direction()]

    /// Creates a relay. Call ``start()`` to begin pumping.
    ///
    /// - Parameters:
    ///   - fdA: First descriptor; ownership transfers to the relay.
    ///   - fdB: Second descriptor; ownership transfers to the relay.
    ///   - queue: Serial queue used for all I/O callbacks and internal state.
    ///   - completion: Called once, on `queue`, after both descriptors are closed.
    public init(fdA: Int32, fdB: Int32, queue: DispatchQueue, completion: @escaping () -> Void) {
        self.queue = queue
        self.completion = completion
        self.owned = RelayDescriptors(fdA, fdB)

        // Every stored property now has a value, so `self` may be captured below.
        for (index, fd) in [fdA, fdB].enumerated() {
            // A peer that disappears mid-response must produce EPIPE, not SIGPIPE.
            POSIXSocketSupport.suppressSIGPIPE(fd)
            let descriptors = owned
            let channel = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { [weak self] _ in
                // Closing the descriptor must happen whether or not the relay is
                // still alive; the completion bookkeeping only if it is.
                descriptors.close(index)
                self?.channelDidClose()
            }
            // Deliver reads as soon as a single byte is available; this is a proxy,
            // not a batch pipeline, and Docker's API is latency sensitive.
            channel.setLimit(lowWater: 1)
            channels.append(channel)
        }
    }

    /// Begins pumping in both directions.
    public func start() {
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.pump(sourceIndex: 0)
            self.pump(sourceIndex: 1)
        }
    }

    /// Tears the relay down early; the completion handler still fires exactly once.
    public func cancel() {
        queue.async { [weak self] in
            self?.finish()
        }
    }

    // MARK: - Pumping

    private func pump(sourceIndex: Int) {
        let sinkIndex = 1 - sourceIndex
        let source = channels[sourceIndex]
        let sink = channels[sinkIndex]

        // `length: .max` with a streaming channel means "call me whenever bytes arrive".
        source.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, data, error in
            guard let self, !self.finished else { return }

            if let data, !data.isEmpty {
                self.directions[sinkIndex].pendingWrites += 1
                sink.write(offset: 0, data: data, queue: self.queue) { [weak self] writeDone, _, writeError in
                    // The handler is called repeatedly as the write drains; only the
                    // final invocation retires the outstanding-write count.
                    guard writeDone, let self else { return }
                    self.writeDidComplete(sinkIndex: sinkIndex, error: writeError)
                }
            }

            if error != 0 {
                // A read error is not a graceful close: there is nothing sensible to
                // flush, so tear the whole relay down.
                self.finish()
                return
            }
            if done {
                // Any `done` is EOF. `DispatchIO` is documented to be allowed to
                // deliver the final bytes *and* `done` in one callback, and today's
                // Darwin implementation happens not to for a stream channel read with
                // `length: .max` — it always closes with a separate empty delivery.
                // Gating the half-close on that empty delivery therefore works by
                // luck: the day a final chunk arrives alongside `done`, the shutdown
                // is never issued and the opposite peer waits forever for an
                // end-of-stream, which for a response with no Content-Length means a
                // hung `docker` client. Treating `done` as EOF outright costs nothing
                // — the write above has already bumped `pendingWrites`, and
                // `halfCloseIfDrained` refuses to act until that drains, so the flush
                // still strictly precedes the shutdown.
                self.sourceDidReachEOF(sinkIndex: sinkIndex)
            }
        }
    }

    /// One direction's source hit EOF. Must run on `queue`.
    private func sourceDidReachEOF(sinkIndex: Int) {
        guard !directions[sinkIndex].sourceAtEOF else { return }
        directions[sinkIndex].sourceAtEOF = true
        halfCloseIfDrained(sinkIndex: sinkIndex)
    }

    /// A write towards `sinkIndex` finished. Must run on `queue`.
    private func writeDidComplete(sinkIndex: Int, error: Int32) {
        directions[sinkIndex].pendingWrites = max(0, directions[sinkIndex].pendingWrites - 1)
        if error != 0 {
            // The peer is gone or the socket broke; further flushing is pointless.
            finish()
            return
        }
        halfCloseIfDrained(sinkIndex: sinkIndex)
    }

    /// Issues the half-close once the source is at EOF and every queued write drained.
    private func halfCloseIfDrained(sinkIndex: Int) {
        guard !finished else { return }
        guard directions[sinkIndex].sourceAtEOF,
              directions[sinkIndex].pendingWrites == 0,
              !directions[sinkIndex].halfClosed
        else { return }
        directions[sinkIndex].halfClosed = true

        // SHUT_WR, not close: the opposite direction may still be carrying data.
        owned.shutdownWrite(sinkIndex)

        // Only when both halves are done is the connection really over.
        if directions[0].halfClosed && directions[1].halfClosed {
            finish()
        }
    }

    /// Idempotently closes both channels. Must run on `queue`.
    private func finish() {
        guard !finished else { return }
        finished = true
        for channel in channels { channel.close(flags: .stop) }
    }

    /// Called from each cleanup handler; fires the completion after the second one.
    private func channelDidClose() {
        openChannels -= 1
        guard openChannels <= 0 else { return }
        let handler = completion
        completion = nil  // break the retain on whatever captured the relay
        handler?()
    }
}
