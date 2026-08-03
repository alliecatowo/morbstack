// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Dispatch
import Foundation

/// A loopback UDP endpoint that delivers complete datagrams with their sender.
///
/// The listener deliberately owns one ordinary `127.0.0.1:<port>` UDP socket. It
/// does not set either reuse option: sharing a published UDP port would let another
/// local process receive a container's traffic, which is neither Docker-like nor a
/// safe fallback after a bind conflict.
public final class UDPListener {

    /// The largest payload that an IPv4 UDP datagram can carry. A packet larger than
    /// this cannot exist, so using it as the receive buffer cannot truncate a valid
    /// IPv4 datagram merely because it crossed the host/guest bridge.
    public static let maximumDatagramBytes = 65_507

    /// A stable key for one local UDP client. The listener binds IPv4 loopback, so a
    /// port plus IPv4 address fully identifies the return destination.
    public struct Client: Hashable, Sendable {
        fileprivate let address: UInt32
        fileprivate let port: UInt16

        fileprivate init(_ socketAddress: sockaddr_in) {
            address = socketAddress.sin_addr.s_addr
            port = socketAddress.sin_port
        }

        public var description: String {
            let hostOrder = UInt32(bigEndian: address)
            let text = [
                String((hostOrder >> 24) & 0xff),
                String((hostOrder >> 16) & 0xff),
                String((hostOrder >> 8) & 0xff),
                String(hostOrder & 0xff),
            ].joined(separator: ".")
            return "\(text):\(UInt16(bigEndian: port))"
        }

        fileprivate var socketAddress: sockaddr_in {
            var result = sockaddr_in()
            result.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            result.sin_family = sa_family_t(AF_INET)
            result.sin_port = port
            result.sin_addr = in_addr(s_addr: address)
            return result
        }
    }

    public enum Error: LocalizedError {
        case addressInUse(port: Int)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .addressInUse(let port):
                "127.0.0.1:\(port) is already in use on this Mac"
            case .failed(let message):
                message
            }
        }
    }

    /// The loopback port this endpoint owns.
    ///
    /// A dynamic listener is constructed with `0`; after the kernel binds it, this
    /// contains the concrete endpoint selected for the held Docker lease.
    public private(set) var port: Int

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

    public init(port: Int, queue: DispatchQueue) {
        self.port = port
        self.queue = queue
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

    /// Binds `127.0.0.1:port` and begins draining datagrams.
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }

        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else {
            throw Error.failed("socket(AF_INET, SOCK_DGRAM) failed: \(String(cString: strerror(errno)))")
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(truncatingIfNeeded: port).bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
        let length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                POSIXSocketSupport.retryOnInterrupt { Darwin.bind(descriptor, generic, length) }
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == EADDRINUSE { throw Error.addressInUse(port: port) }
            throw Error.failed(
                "bind(127.0.0.1:\(port)/udp) failed: \(String(cString: strerror(code)))")
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                POSIXSocketSupport.retryOnInterrupt { Darwin.getsockname(descriptor, generic, &boundLength) }
            }
        }
        guard named == 0, boundAddress.sin_family == sa_family_t(AF_INET) else {
            let detail = named == 0
                ? "unexpected address family"
                : String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw Error.failed("getsockname(127.0.0.1/udp) failed: \(detail)")
        }
        let boundPort = Int(UInt16(bigEndian: boundAddress.sin_port))
        guard (1...65_535).contains(boundPort) else {
            Darwin.close(descriptor)
            throw Error.failed("getsockname(127.0.0.1/udp) returned invalid port \(boundPort)")
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
        var address = client.socketAddress
        let result: Int = datagram.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    Darwin.sendto(fd, bytes.baseAddress, bytes.count, 0, generic,
                                 socklen_t(MemoryLayout<sockaddr_in>.size))
                }
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
            var sender = sockaddr_in()
            var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
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
            guard sender.sin_family == sa_family_t(AF_INET) else { continue }
            handler?(Data(storage.prefix(received)), Client(sender))
        }
    }
}
