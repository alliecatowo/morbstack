// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Dispatch
import Foundation

/// Why a ``TCPListener`` could not bind.
///
/// `addressInUse` is separated out because it is the one failure with a good user
/// story attached — something else on the Mac already owns that port — and the port
/// forwarder logs it differently from a genuine fault.
public enum TCPListenerError: Error, CustomStringConvertible, LocalizedError {

    /// Another process on the Mac is already listening on this port.
    case addressInUse(port: Int)
    /// Any other socket-level failure.
    case failed(String)

    public var description: String {
        switch self {
        case .addressInUse(let port):
            return "127.0.0.1:\(port) is already in use on this Mac"
        case .failed(let message):
            return message
        }
    }

    public var errorDescription: String? { description }
}

/// A loopback TCP listener that hands accepted descriptors to a callback.
///
/// This is the Mac-side half of port publishing: `docker run -p 8080:80` produces one
/// of these on `127.0.0.1:8080`, and every accepted connection is spliced through to
/// the guest.
///
/// Loopback only, deliberately. Binding `0.0.0.0` because the container asked for it
/// would put a container that a user believes is local onto every network the Mac is
/// attached to — including whatever coffee-shop Wi-Fi it is on. Docker Desktop makes
/// the same choice, and a user who genuinely wants the port exposed can forward it
/// themselves.
///
/// Accepted descriptors become the callback's responsibility; the listener never
/// closes them.
public final class TCPListener {

    /// How long ``stop()`` waits for the accept source's cancel handler before closing
    /// the descriptor itself.
    ///
    /// Only reached if the listener's queue is wedged; the handler normally runs in
    /// well under a millisecond. The fallback exists so a stuck queue degrades into a
    /// late close rather than a descriptor — and a bound port — leaked forever.
    private static let cancelHandlerGrace: TimeInterval = 2

    /// The listening descriptor, with accept and close serialised against each other.
    ///
    /// The serialisation is the point. `stop()` has to close the socket *synchronously*
    /// (see ``TCPListener/stop()``), and a bare `close(2)` racing an in-flight
    /// `accept(2)` on the same number is the classic descriptor-reuse bug: the accept
    /// lands on whatever the process opened next. Funnelling both through one lock
    /// makes "closed" a state the accept loop observes rather than a race it runs into.
    private final class ListenSocket {

        private let lock = NSLock()
        private let fd: Int32
        private var closed = false

        /// Signalled exactly once, by whichever caller performs the close.
        let closedSignal = DispatchSemaphore(value: 0)

        init(_ fd: Int32) { self.fd = fd }

        /// Closes the socket if it is still open. Idempotent.
        func close() {
            lock.lock()
            let alreadyClosed = closed
            closed = true
            lock.unlock()
            guard !alreadyClosed else { return }
            Darwin.close(fd)
            closedSignal.signal()
        }

        /// One non-blocking `accept(2)`, or `-1` once the socket has been closed.
        func acceptOne() -> Int32 {
            lock.lock()
            defer { lock.unlock() }
            guard !closed else { return -1 }
            return POSIXSocketSupport.retryOnInterrupt { Darwin.accept(fd, nil, nil) }
        }
    }

    /// The loopback port this listener binds.
    public let port: Int

    /// Invoked on the listener's queue for every accepted connection, with an owned fd.
    public var onConnection: ((Int32) -> Void)?

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var listenSocket: ListenSocket?
    private var acceptSource: DispatchSourceRead?
    private var running = false

    /// Creates a listener. Nothing is bound until ``start()``.
    ///
    /// - Parameters:
    ///   - port: TCP port on `127.0.0.1`.
    ///   - queue: Queue on which the accept loop and ``onConnection`` run.
    public init(port: Int, queue: DispatchQueue) {
        self.port = port
        self.queue = queue
    }

    deinit {
        stop()
    }

    /// `true` between a successful ``start()`` and ``stop()``.
    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// Binds `127.0.0.1:port` and starts accepting.
    ///
    /// - Throws: ``TCPListenerError/addressInUse(port:)`` when the port is taken.
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw TCPListenerError.failed("socket(AF_INET) failed: \(String(cString: strerror(errno)))")
        }

        // SO_REUSEADDR only lets us re-bind a port stuck in TIME_WAIT from our own
        // previous listener; it does *not* let two live listeners share the port on
        // Darwin (that needs SO_REUSEPORT), so a genuine conflict still surfaces as
        // EADDRINUSE, which is exactly what we want to report.
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(truncatingIfNeeded: port).bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)  // 127.0.0.1

        let length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                POSIXSocketSupport.retryOnInterrupt { Darwin.bind(fd, generic, length) }
            }
        }
        guard bindResult == 0 else {
            let code = errno
            Darwin.close(fd)
            if code == EADDRINUSE { throw TCPListenerError.addressInUse(port: port) }
            throw TCPListenerError.failed("bind(127.0.0.1:\(port)) failed: \(String(cString: strerror(code)))")
        }

        guard POSIXSocketSupport.retryOnInterrupt({ listen(fd, 128) }) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw TCPListenerError.failed("listen(127.0.0.1:\(port)) failed: \(message)")
        }

        POSIXSocketSupport.setNonBlocking(fd, true)
        let bound = ListenSocket(fd)
        listenSocket = bound

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drainAccepts()
        }
        source.setCancelHandler { [bound] in
            bound.close()
        }
        acceptSource = source
        running = true
        source.resume()
    }

    /// Stops accepting and closes the listening socket. Idempotent.
    ///
    /// **Synchronous by contract.** The port is free the moment this returns, because
    /// the caller's very next act is usually to bind it again: ``PortForwarder`` closes
    /// and reopens the same host port whenever a container is recreated, and rebinds
    /// the whole set on every suspend/resume. Letting the descriptor be closed by the
    /// dispatch cancel handler alone made that a race the forwarder lost regularly —
    /// the rebind hit `EADDRINUSE` against our own not-yet-closed listener and the
    /// published port stayed dark until something unrelated triggered another refresh.
    ///
    /// So: cancel the source, then *wait* for its handler to close the socket, and
    /// close it here if that wait runs out. ``ListenSocket`` closes exactly once no
    /// matter which of the two paths gets there first.
    public func stop() {
        lock.lock()
        let source = acceptSource
        let bound = listenSocket
        let wasRunning = running
        acceptSource = nil
        listenSocket = nil
        running = false
        onConnection = nil
        lock.unlock()

        guard wasRunning, let bound else { return }
        source?.cancel()
        if bound.closedSignal.wait(timeout: .now() + TCPListener.cancelHandlerGrace) == .timedOut {
            // The listener's queue is not draining. Closing from here is still safe:
            // the accept loop takes the same lock the close does, so it cannot be
            // holding a descriptor this call is about to invalidate.
            bound.close()
        }
    }

    private func drainAccepts() {
        while true {
            lock.lock()
            let bound = listenSocket
            let handler = onConnection
            lock.unlock()
            guard let bound else { return }

            let client = bound.acceptOne()
            if client < 0 { return }  // EAGAIN, or the listener was stopped

            POSIXSocketSupport.setNonBlocking(client, false)
            POSIXSocketSupport.suppressSIGPIPE(client)
            // Nagle would add up to 40 ms to every small request/response exchange,
            // which is most of what goes through a published port.
            var on: Int32 = 1
            _ = setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))

            if let handler {
                handler(client)
            } else {
                Darwin.close(client)
            }
        }
    }
}
