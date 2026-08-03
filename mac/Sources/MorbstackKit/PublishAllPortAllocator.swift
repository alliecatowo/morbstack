// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Dispatch
import Foundation

/// Host endpoint for patched Moby's `PublishAllPorts` allocation protocol.
///
/// A session is registered before an exact-ID start/restart reaches the guest.
/// Moby then sends one all-or-nothing request through morbinit; this class holds
/// the corresponding Mac listeners until DockerProxy observes the start reply.
final class PublishAllPortAllocator {

    final class Session {
        private let fd: Int32
        private let containerID: String
        private let forwarder: PortForwarder
        private let log: MorbLog
        private let queue = DispatchQueue(label: "dev.morbstack.publish-all")
        private let lock = NSLock()
        private var lease: PortForwarder.PortLease?
        private var finished = false

        init(fd: Int32, containerID: String, forwarder: PortForwarder, log: MorbLog) {
            self.fd = fd
            self.containerID = containerID
            self.forwarder = forwarder
            self.log = log
        }

        deinit { Darwin.close(fd) }

        /// Performs the registration handshake before the Docker lifecycle relay
        /// begins. The blocking allocator work itself runs on a dedicated queue.
        func start() throws {
            guard POSIXSocketSupport.writeAll(fd, Data("REGISTER \(containerID)\n".utf8)),
                  try Self.readLine(fd, timeout: 5) == "READY"
            else {
                throw MorbError.protocolViolation("the guest publish-all allocator did not accept the host session")
            }
            queue.async { [weak self] in self?.serve() }
        }

        func complete(succeeded: Bool) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let lease = self.lease
            lock.unlock()
            if let lease {
                if succeeded {
                    _ = forwarder.completeStart(lease, succeeded: true)
                } else {
                    forwarder.abandon(lease, reason: "Docker publish-all start did not succeed")
                }
            }
        }

        private func serve() {
            do {
                let header = try Self.readLine(fd, timeout: 20)
                let fields = header.split(separator: " ", omittingEmptySubsequences: false)
                guard fields.count == 3,
                      fields[0] == "ALLOC",
                      String(fields[1]) == containerID,
                      let count = Int(fields[2]),
                      (1...DockerPortPublicationPreflight.maximumSynchronousFixedPortBindings).contains(count)
                else {
                    throw MorbError.protocolViolation("guest publish-all allocator sent an invalid request header")
                }
                var requests: [DockerPublishAllPortRequest] = []
                requests.reserveCapacity(count)
                for _ in 0..<count {
                    requests.append(try Self.parseRequest(try Self.readLine(fd, timeout: 5)))
                }
                let ports = try forwarder.reservePublishAllPorts(containerID: containerID, requests: requests)
                lock.lock()
                guard !finished else {
                    lock.unlock()
                    forwarder.releaseLease(
                        forContainerID: containerID,
                        reason: "publish-all lifecycle finished before allocation completed")
                    throw MorbError.protocolViolation("publish-all start finished before allocation completed")
                }
                let activeLease = forwarder.claimStartLease(containerIdentifier: containerID)
                // `claimStartLease` marks the record, which gives a failed start the
                // normal cleanup path. It must be the lease just created above.
                guard let activeLease else {
                    lock.unlock()
                    throw MorbError.protocolViolation("publish-all allocation lost its held port lease")
                }
                lease = activeLease
                lock.unlock()

                var reply = "OK \(ports.count)\n"
                for port in ports { reply += "PORT \(port)\n" }
                guard POSIXSocketSupport.writeAll(fd, Data(reply.utf8)) else {
                    throw MorbError.io("could not return the publish-all allocation to the guest")
                }
            } catch {
                let message = error.localizedDescription
                    .replacingOccurrences(of: "\n", with: " ")
                _ = POSIXSocketSupport.writeAll(fd, Data("ERR \(message)\n".utf8))
                complete(succeeded: false)
                log.warn("publish-all allocator for \(String(containerID.prefix(12))) failed: \(message)")
            }
        }

        private static func parseRequest(_ line: String) throws -> DockerPublishAllPortRequest {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count == 4,
                  let containerPort = Int(fields[1]),
                  let requestedHostPort = Int(fields[3]),
                  (1...65535).contains(containerPort),
                  (0...65535).contains(requestedHostPort)
            else {
                throw MorbError.protocolViolation("guest publish-all allocator sent an invalid port binding")
            }
            let transport: DockerDynamicPortTransport
            switch fields[0] {
            case "tcp": transport = .tcp
            case "udp": transport = .udp
            default: throw MorbError.protocolViolation("guest publish-all allocator requested an unsupported transport")
            }
            let hostIP = fields[2] == "-" ? "" : String(fields[2])
            return DockerPublishAllPortRequest(
                transport: transport,
                hostIP: hostIP,
                requestedHostPort: requestedHostPort,
                containerPort: containerPort)
        }

        private static func readLine(_ fd: Int32, timeout: TimeInterval) throws -> String {
            let deadline = Date().addingTimeInterval(timeout)
            var bytes: [UInt8] = []
            while bytes.count < 512 {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw MorbError.timeout("the guest publish-all allocator did not reply in time") }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = POSIXSocketSupport.retryOnInterrupt {
                    withUnsafeMutablePointer(to: &descriptor) { poll($0, 1, Int32(remaining * 1_000)) }
                }
                guard ready > 0 else { throw MorbError.io("the guest publish-all allocator disconnected") }
                var byte: UInt8 = 0
                let read = withUnsafeMutablePointer(to: &byte) {
                    POSIXSocketSupport.readSome(fd, into: UnsafeMutableRawPointer($0), count: 1)
                }
                guard read == 1 else { throw MorbError.io("could not read the guest publish-all allocator") }
                if byte == 0x0A { return String(decoding: bytes, as: UTF8.self) }
                guard byte != 0x0D, byte.isASCII else {
                    throw MorbError.protocolViolation("the guest publish-all allocator sent an invalid line")
                }
                bytes.append(byte)
            }
            throw MorbError.protocolViolation("the guest publish-all allocator sent an oversized line")
        }
    }
}
