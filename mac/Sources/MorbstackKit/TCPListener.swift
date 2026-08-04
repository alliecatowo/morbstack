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
            return "loopback port \(port) is already in use on this Mac"
        case .failed(let message):
            return message
        }
    }

    public var errorDescription: String? { description }
}

/// A TCP listener that hands accepted descriptors to a callback.
///
/// This is the Mac-side half of port publishing: `docker run -p 8080:80` produces one
/// of these on the corresponding Docker host endpoint, and every accepted
/// connection is spliced through to the guest.
///
/// The forwarder supplies an address only after applying the user's explicit port
/// exposure policy. This type never rewrites a wildcard or a specific Docker address
/// to loopback: doing so would acknowledge a Docker publication that clients cannot
/// actually reach.
///
/// Accepted descriptors become the callback's responsibility; the listener never
/// closes them.
public final class TCPListener {

    /// Compatibility spelling for callers that deliberately want one loopback
    /// family. New port-publication code should use ``hostAddress``.
    public enum LoopbackAddress: String, Sendable {
        case ipv4 = "127.0.0.1"
        case ipv6 = "::1"

        var hostAddress: DockerHostAddress {
            switch self {
            case .ipv4: .ipv4("127.0.0.1")
            case .ipv6: .ipv6("::1")
            }
        }
    }

    // The listening descriptor lives in a ``POSIXListenSocket`` (shared with
    // ``UnixSocketServer``), which serialises accept against close and lets
    // ``stop()`` wait for the dispatch cancel handler; see that class for why.

    /// The port this listener binds.
    ///
    /// A listener constructed with port `0` receives an ephemeral port from the
    /// kernel. `start()` replaces that sentinel with the concrete value before it
    /// returns, so a caller can retain an actual dynamic port rather than sampling a
    /// free port and racing another process to it.
    public private(set) var port: Int

    /// The exact host address paired with ``port``.
    public let hostAddress: DockerHostAddress

    /// Retained for focused loopback callers. A non-loopback listener has no
    /// loopback alias, by design.
    public var loopbackAddress: LoopbackAddress? {
        switch hostAddress {
        case .ipv4("127.0.0.1"): .ipv4
        case .ipv6("::1"): .ipv6
        default: nil
        }
    }

    /// Invoked on the listener's queue for every accepted connection, with an owned fd.
    public var onConnection: ((Int32) -> Void)?

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var listenSocket: POSIXListenSocket?
    private var acceptSource: DispatchSourceRead?
    private var running = false

    /// Creates a listener. Nothing is bound until ``start()``.
    ///
    /// - Parameters:
    ///   - port: TCP port on the requested host address.
    ///   - queue: Queue on which the accept loop and ``onConnection`` run.
    ///   - hostAddress: the exact Docker host address to bind.
    public init(
        port: Int,
        queue: DispatchQueue,
        hostAddress: DockerHostAddress = .ipv4("127.0.0.1")
    ) {
        self.port = port
        self.queue = queue
        self.hostAddress = hostAddress
    }

    /// Loopback-focused source compatibility. This does not participate in Docker
    /// host-address mapping and therefore cannot turn a wildcard into loopback.
    public convenience init(
        port: Int,
        queue: DispatchQueue,
        loopbackAddress: LoopbackAddress
    ) {
        self.init(port: port, queue: queue, hostAddress: loopbackAddress.hostAddress)
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

    /// Changes where newly accepted connections go without giving up the bound port.
    ///
    /// A create/start lease starts as a real listener with no forwarding handler, then
    /// PortForwarder installs its stream-dial handler only after Docker acknowledges a
    /// successful start. Serializing this with the accept loop prevents a lease
    /// handoff from racing an accepted connection against a plain stored-property
    /// write.
    public func setConnectionHandler(_ handler: ((Int32) -> Void)?) {
        lock.lock()
        onConnection = handler
        lock.unlock()
    }

    /// Binds the selected host endpoint and starts accepting.
    ///
    /// - Throws: ``TCPListenerError/addressInUse(port:)`` when the port is taken.
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }

        let family = hostAddress.family
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw TCPListenerError.failed(
                "socket(\(hostAddress.stringValue)) failed: \(String(cString: strerror(errno)))")
        }

        // SO_REUSEADDR only lets us re-bind a port stuck in TIME_WAIT from our own
        // previous listener; it does *not* let two live listeners share the port on
        // Darwin (that needs SO_REUSEPORT), so a genuine conflict still surfaces as
        // EADDRINUSE, which is exactly what we want to report.
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))

        let bindResult: Int32
        switch hostAddress {
        case .ipv4(let hostAddress):
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(truncatingIfNeeded: port).bigEndian
            guard inet_pton(AF_INET, hostAddress, &address.sin_addr) == 1 else {
                Darwin.close(fd)
                throw TCPListenerError.failed("invalid IPv4 host address \(hostAddress)")
            }
            bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    POSIXSocketSupport.retryOnInterrupt {
                        Darwin.bind(fd, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        case .ipv6(let hostAddress):
            // Never accept IPv4-mapped traffic on the IPv6 listener. The endpoint is
            // exactly the requested IPv6 endpoint, so IPv4 and IPv6 publication
            // semantics remain independent even when they share a port number.
            var v6Only: Int32 = 1
            _ = setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &v6Only, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = UInt16(truncatingIfNeeded: port).bigEndian
            guard inet_pton(AF_INET6, hostAddress, &address.sin6_addr) == 1 else {
                Darwin.close(fd)
                throw TCPListenerError.failed("invalid IPv6 host address \(hostAddress)")
            }
            bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    POSIXSocketSupport.retryOnInterrupt {
                        Darwin.bind(fd, generic, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }
            }
        }
        guard bindResult == 0 else {
            let code = errno
            Darwin.close(fd)
            if code == EADDRINUSE { throw TCPListenerError.addressInUse(port: port) }
            throw TCPListenerError.failed(
                "bind(\(hostAddress.stringValue):\(port)) failed: \(String(cString: strerror(code)))")
        }

        // `port == 0` asks the kernel to allocate a free ephemeral port. Read the
        // bound address while this descriptor is still private and before exposing
        // the accept source; a later `getsockname` would merely report a port we had
        // already made observable rather than proving which one is reserved.
        let boundPort: Int
        let nameResult: Int32
        switch hostAddress {
        case .ipv4:
            var address = sockaddr_in()
            var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            nameResult = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    POSIXSocketSupport.retryOnInterrupt {
                        Darwin.getsockname(fd, generic, &addressLength)
                    }
                }
            }
            boundPort = Int(UInt16(bigEndian: address.sin_port))
        case .ipv6:
            var address = sockaddr_in6()
            var addressLength = socklen_t(MemoryLayout<sockaddr_in6>.size)
            nameResult = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    POSIXSocketSupport.retryOnInterrupt {
                        Darwin.getsockname(fd, generic, &addressLength)
                    }
                }
            }
            boundPort = Int(UInt16(bigEndian: address.sin6_port))
        }
        guard nameResult == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw TCPListenerError.failed("getsockname(\(hostAddress.stringValue)) failed: \(message)")
        }
        guard (1...65535).contains(boundPort) else {
            Darwin.close(fd)
            throw TCPListenerError.failed(
                "getsockname(\(hostAddress.stringValue)) returned invalid port \(boundPort)")
        }
        port = boundPort

        guard POSIXSocketSupport.retryOnInterrupt({ listen(fd, 128) }) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw TCPListenerError.failed(
                "listen(\(hostAddress.stringValue):\(port)) failed: \(message)")
        }

        POSIXSocketSupport.setNonBlocking(fd, true)
        let bound = POSIXListenSocket(fd)
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
    /// close it here if that wait runs out. ``POSIXListenSocket`` closes exactly once no
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
        if bound.closedSignal.wait(timeout: .now() + POSIXListenSocket.cancelHandlerGrace) == .timedOut {
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
