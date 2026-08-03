// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Dispatch
import Foundation

/// The two descriptors a relay owns, with a close-exactly-once guard.
///
/// Kept in its own object so the two copy workers can independently finish or abort
/// without closing the other side twice. A double `close(2)` in a daemon that is also
/// opening sockets is how one client's stream is relayed to another client.
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

    /// Shuts down one half of a descriptor if it is still open.
    func shutdown(_ index: Int, how: Int32) {
        lock.lock()
        let fd = closed[index] ? nil : fds[index]
        lock.unlock()
        guard let fd else { return }
        _ = Darwin.shutdown(fd, how)
    }

    /// Shuts down the write half of `index`, if it is still open.
    func shutdownWrite(_ index: Int) {
        shutdown(index, how: SHUT_WR)
    }

    /// Wakes both copy workers after an unrecoverable error or cancellation.
    ///
    /// Descriptors are deliberately not closed here: closing an FD from another
    /// thread can race a blocked syscall with descriptor reuse. `shutdown` wakes the
    /// operation, and the last exiting worker owns the final close.
    func shutdownAll() {
        shutdown(0, how: SHUT_RDWR)
        shutdown(1, how: SHUT_RDWR)
    }
}

/// A bidirectional, backpressured byte pump between two file descriptors.
///
/// `FDRelay` turns `~/.morbstack/run/docker.sock` into the guest's Docker Engine
/// API: one descriptor is the accepted CLI connection and the other is a vsock
/// connection to the VM. It deliberately knows nothing about HTTP. That preserves
/// Engine connection upgrades (`exec`/`attach`), `logs --follow`, keep-alive reuse,
/// and the tar streams used by `docker cp`.
///
/// Each direction has one blocking copy worker and a fixed 64 KiB buffer. A write
/// must drain before that worker reads again, which lets the kernel apply ordinary
/// socket backpressure instead of collecting an unbounded `DispatchIO` write queue
/// when a client pauses a large archive or follow stream. The guest caps proxy
/// connections separately; this class bounds memory per live connection.
///
/// EOF is directional. Once all bytes from one source have reached its sink, the
/// relay sends `shutdown(fd, SHUT_WR)` to that sink but continues copying the opposite
/// direction. This preserves the Docker pattern of closing stdin while still reading
/// an exec/build response.
public final class FDRelay {

    /// Maximum bytes retained by either directional worker at one time.
    ///
    /// Kept small enough that a full guest-side connection cap cannot turn a stalled
    /// `docker cp` or `logs -f` consumer into a host-memory spike, while still large
    /// enough to avoid per-packet syscall churn for tar streams.
    public static let copyBufferBytes = 64 * 1024

    /// Direction metadata for an optional passive byte observer.
    ///
    /// Observers are notification-only: they receive a copy of bytes immediately
    /// before the relay writes them and have no way to alter or suppress the stream.
    /// DockerProxy uses this narrow hook to recognize normal create/start responses
    /// while preserving every Engine byte for the client.
    public enum Direction: Sendable {
        case firstToSecond
        case secondToFirst
    }

    private let queue: DispatchQueue
    private let owned: RelayDescriptors
    private let observer: ((Direction, Data) -> Void)?
    private let stateLock = NSLock()
    private var completion: (() -> Void)?
    private var started = false
    private var cancellationRequested = false
    private var terminal = false
    private var completedWorkers = 0

    /// Creates a relay. Call ``start()`` to begin pumping.
    ///
    /// - Parameters:
    ///   - fdA: First descriptor; ownership transfers to the relay.
    ///   - fdB: Second descriptor; ownership transfers to the relay.
    ///   - queue: Queue on which completion runs after both descriptors close.
    ///   - observer: Optional notification of each byte chunk before its relay write.
    ///   - completion: Called once, on `queue`, after both descriptors are closed.
    public init(
        fdA: Int32,
        fdB: Int32,
        queue: DispatchQueue,
        observer: ((Direction, Data) -> Void)? = nil,
        completion: @escaping () -> Void
    ) {
        self.queue = queue
        self.completion = completion
        self.owned = RelayDescriptors(fdA, fdB)
        self.observer = observer

        for fd in [fdA, fdB] {
            // A peer that disappears mid-response must produce EPIPE, not SIGPIPE.
            POSIXSocketSupport.suppressSIGPIPE(fd)
            // The workers use ordinary blocking reads and writes so the socket
            // buffers, rather than an unbounded userspace queue, enforce flow control.
            POSIXSocketSupport.setNonBlocking(fd, false)
        }
    }

    deinit {
        // Normal users retain the relay through completion. This only covers an
        // abandoned relay before `start()` and remains safe after normal completion.
        owned.shutdownAll()
        owned.close(0)
        owned.close(1)
    }

    /// Begins pumping in both directions.
    public func start() {
        stateLock.lock()
        guard !started, !terminal else {
            stateLock.unlock()
            return
        }
        started = true
        stateLock.unlock()

        // A serial callback queue is intentional at the call sites. The copy workers
        // must nevertheless run concurrently: a full stdout socket must not prevent
        // stdin from reaching an interactive `docker exec -it` session.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            copy(sourceIndex: 0, sinkIndex: 1, direction: .firstToSecond)
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            copy(sourceIndex: 1, sinkIndex: 0, direction: .secondToFirst)
        }
    }

    /// Tears the relay down early; the completion handler still fires exactly once.
    public func cancel() {
        stateLock.lock()
        guard !terminal else {
            stateLock.unlock()
            return
        }
        cancellationRequested = true
        let completeImmediately = !started
        if completeImmediately { terminal = true }
        stateLock.unlock()

        if completeImmediately {
            owned.close(0)
            owned.close(1)
            deliverCompletion()
        } else {
            owned.shutdownAll()
        }
    }

    // MARK: - Backpressured copying

    private func copy(sourceIndex: Int, sinkIndex: Int, direction: Direction) {
        defer { workerDidFinish() }
        guard let source = owned.descriptor(sourceIndex),
              let sink = owned.descriptor(sinkIndex)
        else { return }

        var buffer = [UInt8](repeating: 0, count: Self.copyBufferBytes)
        while !isCancellationRequested {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                while true {
                    let result = Darwin.read(source, base, raw.count)
                    if result < 0, errno == EINTR { continue }
                    return result
                }
            }

            if count > 0 {
                // This copy exists only on the narrow response-observer paths. The
                // raw transport itself writes directly from its fixed worker buffer.
                if let observer {
                    observer(direction, Data(buffer[0..<count]))
                }
                let wrote = buffer.withUnsafeBytes { raw -> Bool in
                    guard let base = raw.baseAddress else { return false }
                    return writeAll(sink, bytes: base, count: count)
                }
                if !wrote {
                    if !isCancellationRequested { requestAbort() }
                    return
                }
                continue
            }

            if count == 0 {
                // Every already-read byte has reached `sink`, so this is the one
                // safe point to propagate EOF without truncating the reverse stream.
                if !isCancellationRequested { owned.shutdownWrite(sinkIndex) }
                return
            }

            if !isCancellationRequested { requestAbort() }
            return
        }
    }

    /// Writes a complete buffer or reports a socket failure. The caller owns a
    /// fixed-size buffer, so this never allocates in proportion to a tar/log stream.
    private func writeAll(_ fd: Int32, bytes: UnsafeRawPointer, count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let written = Darwin.write(fd, bytes.advanced(by: offset), count - offset)
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EINTR { continue }
            return false
        }
        return true
    }

    private var isCancellationRequested: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancellationRequested
    }

    /// Fails both directions together after an actual read/write failure.
    private func requestAbort() {
        stateLock.lock()
        let shouldWake = !terminal && !cancellationRequested
        cancellationRequested = true
        stateLock.unlock()
        if shouldWake { owned.shutdownAll() }
    }

    private func workerDidFinish() {
        stateLock.lock()
        guard !terminal else {
            stateLock.unlock()
            return
        }
        completedWorkers += 1
        let completeNow = completedWorkers == 2
        if completeNow { terminal = true }
        stateLock.unlock()

        guard completeNow else { return }
        owned.close(0)
        owned.close(1)
        deliverCompletion()
    }

    /// Runs completion on the caller-supplied queue and breaks its retained closure.
    private func deliverCompletion() {
        queue.async { [self] in
            stateLock.lock()
            let handler = completion
            completion = nil
            stateLock.unlock()
            handler?()
        }
    }
}
