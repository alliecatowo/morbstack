// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Dispatch
import Foundation

/// The guest-initiated port-lease channel, vsock host port 2382
/// (``MorbVsockPorts/hostPortLease``).
///
/// Stock dockerd execs Morbstack's userland-proxy wrapper
/// (`morbstack-docker-proxy`, `guest/morbinit/src/proxy_wrapper.rs`) once per
/// published port, *after* it has resolved the effective port set — including
/// the `-P` allocations only dockerd can compute — and *before* it reports
/// the container start as successful. The wrapper connects here and speaks
/// one bounded ASCII exchange:
///
/// ```text
/// guest -> host:  "LEASE <tcp|udp> <host-ip> <host-port> <container-ip> <container-port>\n"
/// host  -> guest: "OK\n"            Mac endpoint bound and forwarding
///            or:  "ERR <reason>\n"  then the connection closes
/// ```
///
/// The connection then idles for the proxy process's lifetime. EOF — the
/// proxy exiting for any reason: container stop, restart, dockerd shutdown —
/// releases the Mac listener. There is deliberately no release verb to lose
/// track of: process lifetime *is* lease lifetime, which is what makes
/// stop/start/restart and restart-policy-across-VM-boot correct by
/// construction instead of by bookkeeping.
///
/// Fail-closed is the point of the whole channel: an `ERR` (or an unreachable
/// host) makes the wrapper exit non-zero, dockerd surfaces the reason, and
/// the container start fails honestly — identical semantics to a busy port
/// on native Linux, and the opposite of reactive discovery, where a Mac-side
/// collision yields a running container whose published port silently does
/// not answer.
public enum GuestPortLease {

    /// Longest request line accepted, including the newline. The longest
    /// legitimate line is well under 100 bytes; the cap is what stops a
    /// compromised guest from streaming forever.
    public static let maxRequestLineBytes = 256

    /// How long the guest has to deliver its one request line. The wrapper
    /// writes it immediately after connecting, so this is only ever spent on
    /// a broken peer — and it must stay comfortably under dockerd's 16 s
    /// proxy-startup budget so the failure is attributed correctly.
    public static let requestTimeout: TimeInterval = 10

    public enum Transport: String, Sendable {
        case tcp
        case udp
    }

    /// A refusal whose reason becomes the wire `ERR` line.
    public struct Refusal: Error, Equatable, Sendable {
        public let reason: String
        public init(_ reason: String) { self.reason = reason }
    }

    /// One parsed, validated lease request.
    public struct Request: Equatable, Sendable {
        public let transport: Transport
        public let hostIP: String
        public let hostPort: Int
        public let containerIP: String
        public let containerPort: Int
    }

    /// Parses `LEASE <proto> <host-ip> <host-port> <container-ip> <container-port>`.
    ///
    /// Strict by design: this is an untrusted-input surface (the guest could
    /// be running arbitrary containers), so anything but the exact grammar is
    /// rejected with a reason that becomes the wire `ERR`. Addresses are only
    /// shape-checked here — ``DockerHostEndpoint`` re-validates the host
    /// address with `inet_pton` before anything binds.
    public static func parseRequest(line: String) -> Result<Request, Refusal> {
        let body = line.hasSuffix("\n") ? String(line.dropLast()) : line
        let fields = body.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 6, fields[0] == "LEASE" else {
            return .failure(Refusal("expected \"LEASE <proto> <host-ip> <host-port> <container-ip> <container-port>\""))
        }
        guard let transport = Transport(rawValue: fields[1]) else {
            return .failure(Refusal("unsupported transport \(fields[1])"))
        }
        let addressCharacters = CharacterSet(charactersIn: "0123456789abcdefABCDEF.:")
        let hostIP = fields[2]
        let containerIP = fields[4]
        guard !hostIP.isEmpty, hostIP.unicodeScalars.allSatisfy({ addressCharacters.contains($0) }) else {
            return .failure(Refusal("host address is not a numeric IP"))
        }
        guard containerIP == "-"
            || containerIP.unicodeScalars.allSatisfy({ addressCharacters.contains($0) })
        else {
            return .failure(Refusal("container address is not a numeric IP"))
        }
        guard let hostPort = Int(fields[3]), (1...65_535).contains(hostPort) else {
            return .failure(Refusal("host port is not in 1...65535"))
        }
        guard let containerPort = Int(fields[5]), (1...65_535).contains(containerPort) else {
            return .failure(Refusal("container port is not in 1...65535"))
        }
        return .success(Request(
            transport: transport,
            hostIP: hostIP,
            hostPort: hostPort,
            containerIP: containerIP,
            containerPort: containerPort))
    }

    /// Flattens a failure reason to one wire-safe line.
    public static func errLine(_ reason: String) -> Data {
        let flattened = reason.map { $0 == "\n" || $0 == "\r" ? " " : $0 }
        return Data(("ERR " + String(flattened).prefix(maxRequestLineBytes) + "\n").utf8)
    }

    public static let okLine = Data("OK\n".utf8)
}

/// Serves the port-lease channel: one thread-off-queue exchange per accepted
/// guest connection, then an EOF watch whose firing releases the lease.
public final class GuestPortLeaseServer {

    private let forwarder: PortForwarder
    private let log: MorbLog
    /// Concurrent: each connection blocks briefly on its preamble read, and
    /// several proxies start at once for a multi-port container.
    private let queue = DispatchQueue(
        label: "dev.morbstack.portlease", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    /// Live EOF watchers, keyed by descriptor, so the server can prove it
    /// never leaks a source. Values are the release closures.
    private var watchers: [Int32: DispatchSourceRead] = [:]
    /// Connections currently negotiating plus watching; bounded so a
    /// misbehaving guest cannot mint unlimited Mac listeners or GCD sources.
    /// dockerd itself needs one per published port, so the cap is generous.
    static let maxConcurrentLeases = 256

    public init(forwarder: PortForwarder, log: MorbLog) {
        self.forwarder = forwarder
        self.log = log
    }

    /// Entry point wired to ``VMManager/setGuestInitiatedConnectionHandler``.
    /// Called on the VM queue; must not block it.
    public func handleConnection(fd: Int32) {
        queue.async { [weak self] in
            guard let self else {
                Darwin.close(fd)
                return
            }
            self.negotiate(fd: fd)
        }
    }

    private func negotiate(fd: Int32) {
        POSIXSocketSupport.suppressSIGPIPE(fd)

        lock.lock()
        let saturated = watchers.count >= Self.maxConcurrentLeases
        lock.unlock()
        if saturated {
            refuse(fd: fd, reason: "too many concurrent port leases")
            return
        }

        let line: String
        switch readRequestLine(fd: fd) {
        case .failure(let refusal):
            log.warn("port-lease request rejected: \(refusal.reason)")
            refuse(fd: fd, reason: refusal.reason)
            return
        case .success(let value):
            line = value
        }

        let request: GuestPortLease.Request
        switch GuestPortLease.parseRequest(line: line) {
        case .failure(let refusal):
            log.warn("port-lease request rejected: \(refusal.reason)")
            refuse(fd: fd, reason: refusal.reason)
            return
        case .success(let parsed):
            request = parsed
        }

        let token: UInt64
        do {
            token = try forwarder.leaseGuestProxyPort(request)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            log.info("port-lease refused for \(request.hostIP):\(request.hostPort)/\(request.transport.rawValue): \(reason)")
            refuse(fd: fd, reason: reason)
            return
        }

        guard writeAll(fd: fd, GuestPortLease.okLine) else {
            // The guest vanished between asking and hearing the answer; the
            // proxy process cannot be holding the lease it never learned of.
            forwarder.releaseGuestProxyPort(token, reason: "the lease reply could not be delivered")
            Darwin.close(fd)
            return
        }

        watchForRelease(fd: fd, token: token, request: request)
    }

    /// Parks a read source on the held connection. Any readability is
    /// terminal: EOF is the proxy exiting, and data would be a protocol
    /// violation — the channel carries exactly one line each way.
    private func watchForRelease(fd: Int32, token: UInt64, request: GuestPortLease.Request) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var probe = [UInt8](repeating: 0, count: 64)
            let n = probe.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return POSIXSocketSupport.readSome(fd, into: base, count: raw.count)
            }
            if n > 0 {
                // Drain and keep waiting? No: one line each way is the whole
                // contract, so extra bytes mean a peer this server does not
                // understand. Fail the lease rather than half-trust it.
                self.release(fd: fd, token: token, reason: "the guest wrote after the lease was granted")
                return
            }
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                return
            }
            self.release(fd: fd, token: token,
                         reason: "the guest proxy exited")
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }

        lock.lock()
        watchers[fd] = source
        lock.unlock()

        // Non-blocking so the probe read above cannot park a queue worker.
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        source.resume()
    }

    private func release(fd: Int32, token: UInt64, reason: String) {
        lock.lock()
        let source = watchers.removeValue(forKey: fd)
        lock.unlock()
        guard let source else { return }
        forwarder.releaseGuestProxyPort(token, reason: reason)
        source.cancel()
    }

    private func refuse(fd: Int32, reason: String) {
        _ = writeAll(fd: fd, GuestPortLease.errLine(reason))
        Darwin.close(fd)
    }

    /// One byte at a time, bounded in size and time — the same discipline as
    /// every other preamble reader in this codebase. Byte-at-a-time is cheap
    /// here (the line arrives once per container start) and removes any
    /// question of buffering past the newline.
    private func readRequestLine(fd: Int32) -> Result<String, GuestPortLease.Refusal> {
        var buffer: [UInt8] = []
        buffer.reserveCapacity(64)
        let deadline = Date().addingTimeInterval(GuestPortLease.requestTimeout)
        while buffer.count < GuestPortLease.maxRequestLineBytes {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                return .failure(GuestPortLease.Refusal("timed out waiting for the lease request"))
            }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = POSIXSocketSupport.retryOnInterrupt {
                withUnsafeMutablePointer(to: &poller) {
                    poll($0, 1, Int32(min(remaining * 1000, 1000)))
                }
            }
            if ready < 0 {
                return .failure(GuestPortLease.Refusal("poll failed: \(String(cString: strerror(errno)))"))
            }
            if ready == 0 { continue }
            var byte: UInt8 = 0
            let n = withUnsafeMutablePointer(to: &byte) {
                POSIXSocketSupport.readSome(fd, into: $0, count: 1)
            }
            if n == 0 {
                return .failure(GuestPortLease.Refusal("the guest closed the channel before its request"))
            }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return .failure(GuestPortLease.Refusal("read failed: \(String(cString: strerror(errno)))"))
            }
            if byte == UInt8(ascii: "\n") {
                guard let line = String(bytes: buffer, encoding: .utf8) else {
                    return .failure(GuestPortLease.Refusal("the lease request is not UTF-8"))
                }
                return .success(line)
            }
            buffer.append(byte)
        }
        return .failure(GuestPortLease.Refusal("the lease request had no newline within \(GuestPortLease.maxRequestLineBytes) bytes"))
    }

    private func writeAll(fd: Int32, _ data: Data) -> Bool {
        POSIXSocketSupport.writeAll(fd, data)
    }
}
