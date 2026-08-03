// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Dispatch
import Foundation

/// A UDP endpoint that delivers complete datagrams with their sender.
///
/// The listener owns exactly the address Docker requested. It does not set either
/// reuse option: sharing a published UDP port would let another local process
/// receive a container's traffic, which is neither Docker-like nor a safe fallback
/// after a bind conflict.
public final class UDPListener {

    /// The largest ordinary IPv6 UDP payload. It also safely contains every IPv4 UDP
    /// payload, so a single receive buffer preserves both address families.
    public static let maximumDatagramBytes = 65_527

    /// A stable key for one UDP client. Family, port, and raw address bytes identify
    /// the return destination without relying on reverse DNS or a presentation
    /// spelling that could vary across packets.
    public struct Client: Hashable, Sendable {
        fileprivate let family: Int32
        fileprivate let address: [UInt8]
        fileprivate let port: UInt16

        fileprivate init(_ socketAddress: sockaddr_in) {
            family = AF_INET
            address = withUnsafeBytes(of: socketAddress.sin_addr) { Array($0) }
            port = socketAddress.sin_port
        }

        fileprivate init(_ socketAddress: sockaddr_in6) {
            family = AF_INET6
            address = withUnsafeBytes(of: socketAddress.sin6_addr) { Array($0) }
            port = socketAddress.sin6_port
        }

        public var description: String {
            let text = numericAddress ?? "unknown"
            return family == AF_INET6
                ? "[\(text)]:\(UInt16(bigEndian: port))"
                : "\(text):\(UInt16(bigEndian: port))"
        }

        fileprivate func withSocketAddress<T>(
            _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
        ) -> T {
            switch family {
            case AF_INET:
                var result = sockaddr_in()
                result.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                result.sin_family = sa_family_t(AF_INET)
                result.sin_port = port
                withUnsafeMutableBytes(of: &result.sin_addr) { destination in
                    destination.copyBytes(from: address)
                }
                return withUnsafePointer(to: &result) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        body($0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            case AF_INET6:
                var result = sockaddr_in6()
                result.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                result.sin6_family = sa_family_t(AF_INET6)
                result.sin6_port = port
                withUnsafeMutableBytes(of: &result.sin6_addr) { destination in
                    destination.copyBytes(from: address)
                }
                return withUnsafePointer(to: &result) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        body($0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }
            default:
                preconditionFailure("UDP client has an unsupported address family")
            }
        }

        private var numericAddress: String? {
            switch family {
            case AF_INET:
                var value = in_addr()
                withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: address) }
                return Self.numericString(family: AF_INET, value: &value)
            case AF_INET6:
                var value = in6_addr()
                withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: address) }
                return Self.numericString(family: AF_INET6, value: &value)
            default:
                return nil
            }
        }

        private static func numericString<T>(family: Int32, value: inout T) -> String? {
            var storage = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            return storage.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress,
                      let pointer = inet_ntop(family, &value, base, socklen_t(buffer.count))
                else { return nil }
                return String(cString: pointer)
            }
        }
    }

    public enum Error: LocalizedError {
        case addressInUse(port: Int)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .addressInUse(let port):
                "published UDP port \(port) is already in use on this Mac"
            case .failed(let message):
                message
            }
        }
    }

    /// The port this endpoint owns.
    ///
    /// A dynamic listener is constructed with `0`; after the kernel binds it, this
    /// contains the concrete endpoint selected for the held Docker lease.
    public private(set) var port: Int

    /// The exact Docker host address this endpoint owns.
    public let hostAddress: DockerHostAddress

    /// Called on `queue` for every complete datagram. A received `Data()` is valid:
    /// UDP permits zero-length datagrams and the bridge preserves them. Access stays
    /// private so a held lease can safely switch from drain-only to forwarding without
    /// racing the listener's read queue.
    private var onDatagram: ((Data, Client) -> Void)?

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var running = false

    public init(
        port: Int,
        queue: DispatchQueue,
        hostAddress: DockerHostAddress = .ipv4("127.0.0.1")
    ) {
        self.port = port
        self.queue = queue
        self.hostAddress = hostAddress
    }

    deinit { stop() }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// Atomically installs or clears the datagram delivery handler.
    ///
    /// A fixed UDP lease starts with no handler: the exclusive socket drains and
    /// discards datagrams until Docker's exact successful start handoff proves a
    /// guest endpoint. The same lock serializes the handler transition with receive;
    /// a callback already in flight is still checked against the forwarder's locked
    /// active-forward map before it can create or use a guest flow.
    public func setDatagramHandler(_ handler: ((Data, Client) -> Void)?) {
        lock.lock()
        onDatagram = handler
        lock.unlock()
    }

    /// Binds the requested Docker host address and begins draining datagrams.
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }

        let descriptor = socket(hostAddress.family, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else {
            throw Error.failed("socket(\(hostAddress.stringValue), SOCK_DGRAM) failed: \(String(cString: strerror(errno)))")
        }

        let bound: Int32
        switch hostAddress {
        case .ipv4(let hostAddress):
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(truncatingIfNeeded: port).bigEndian
            guard inet_pton(AF_INET, hostAddress, &address.sin_addr) == 1 else {
                Darwin.close(descriptor)
                throw Error.failed("invalid IPv4 host address \(hostAddress)")
            }
            bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    POSIXSocketSupport.retryOnInterrupt {
                        Darwin.bind(descriptor, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        case .ipv6(let hostAddress):
            var v6Only: Int32 = 1
            _ = setsockopt(descriptor, IPPROTO_IPV6, IPV6_V6ONLY, &v6Only, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = UInt16(truncatingIfNeeded: port).bigEndian
            guard inet_pton(AF_INET6, hostAddress, &address.sin6_addr) == 1 else {
                Darwin.close(descriptor)
                throw Error.failed("invalid IPv6 host address \(hostAddress)")
            }
            bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    POSIXSocketSupport.retryOnInterrupt {
                        Darwin.bind(descriptor, generic, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == EADDRINUSE { throw Error.addressInUse(port: port) }
            throw Error.failed(
                "bind(\(hostAddress.stringValue):\(port)/udp) failed: \(String(cString: strerror(code)))")
        }

        let named: Int32
        let boundPort: Int
        switch hostAddress {
        case .ipv4:
            var boundAddress = sockaddr_in()
            var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            named = withUnsafeMutablePointer(to: &boundAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    POSIXSocketSupport.retryOnInterrupt { Darwin.getsockname(descriptor, $0, &boundLength) }
                }
            }
            boundPort = Int(UInt16(bigEndian: boundAddress.sin_port))
        case .ipv6:
            var boundAddress = sockaddr_in6()
            var boundLength = socklen_t(MemoryLayout<sockaddr_in6>.size)
            named = withUnsafeMutablePointer(to: &boundAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    POSIXSocketSupport.retryOnInterrupt { Darwin.getsockname(descriptor, $0, &boundLength) }
                }
            }
            boundPort = Int(UInt16(bigEndian: boundAddress.sin6_port))
        }
        guard named == 0 else {
            let detail = named == 0
                ? "unexpected address family"
                : String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw Error.failed("getsockname(\(hostAddress.stringValue)/udp) failed: \(detail)")
        }
        guard (1...65_535).contains(boundPort) else {
            Darwin.close(descriptor)
            throw Error.failed("getsockname(\(hostAddress.stringValue)/udp) returned invalid port \(boundPort)")
        }
        port = boundPort

        POSIXSocketSupport.setNonBlocking(descriptor, true)
        fd = descriptor
        let readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        readSource.setEventHandler { [weak self] in self?.drainDatagrams() }
        // `stop()` closes under the same lock that recvfrom uses, so cancelling can
        // never race a descriptor number being reused for another socket.
        readSource.setCancelHandler { }
        source = readSource
        running = true
        readSource.resume()
    }

    /// Releases the bound endpoint synchronously. The port is available when this
    /// method returns, which matters when Docker replaces a container behind it.
    public func stop() {
        lock.lock()
        let descriptor = fd
        let readSource = source
        fd = -1
        source = nil
        running = false
        onDatagram = nil
        if descriptor >= 0 { Darwin.close(descriptor) }
        lock.unlock()
        readSource?.cancel()
    }

    /// Sends one complete reply to a client that previously addressed this endpoint.
    /// A false return means the endpoint disappeared or the send failed; callers use
    /// it only to retire a now-useless flow, never to reinterpret a UDP packet.
    @discardableResult
    public func send(_ datagram: Data, to client: Client) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return false }
        let result: Int = datagram.withUnsafeBytes { bytes in
            client.withSocketAddress { address, length in
                Darwin.sendto(fd, bytes.baseAddress, bytes.count, 0, address, length)
            }
        }
        return result == datagram.count
    }

    private func drainDatagrams() {
        var storage = [UInt8](repeating: 0, count: UDPListener.maximumDatagramBytes)
        while true {
            lock.lock()
            let descriptor = fd
            let handler = onDatagram
            guard descriptor >= 0 else {
                lock.unlock()
                return
            }
            var sender = sockaddr_storage()
            var senderLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let received: Int = storage.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &sender) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                        Int(POSIXSocketSupport.retryOnInterrupt {
                            Int32(clamping: Darwin.recvfrom(
                                descriptor, bytes.baseAddress, bytes.count, 0,
                                generic, &senderLength))
                        })
                    }
                }
            }
            lock.unlock()

            if received < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            // A zero-length UDP datagram is a real packet, unlike read(2) on a stream.
            let client: Client?
            switch Int32(sender.ss_family) {
            case AF_INET:
                let address = withUnsafePointer(to: &sender) { pointer in
                    pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                }
                client = Client(address)
            case AF_INET6:
                let address = withUnsafePointer(to: &sender) { pointer in
                    pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                }
                client = Client(address)
            default:
                client = nil
            }
            if let client { handler?(Data(storage.prefix(received)), client) }
        }
    }
}
