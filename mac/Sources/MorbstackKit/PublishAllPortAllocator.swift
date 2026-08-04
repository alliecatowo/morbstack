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
        private let remainsAvailableForRestartPolicy: Bool
        /// An opt-in correlation ID shared with morbinit for one diagnostic run.
        ///
        /// `-P` normally uses the original two-field registration grammar.  The
        /// extension is sent only when the daemon starts with
        /// `MORBSTACK_PUBLISH_ALL_TRACE=1`, so ordinary allocation behaviour and
        /// compatibility remain unchanged.  The guest accepts the extension and
        /// includes the same token in its PID-1 log, which lets one reproduction
        /// establish whether the host closed the vsock fd or the guest did.
        private let traceID: String?
        private let queue = DispatchQueue(label: "dev.morbstack.publish-all")
        private let lock = NSLock()
        private var lease: PortForwarder.PortLease?
        private var finished = false

        init(
            fd: Int32,
            containerID: String,
            forwarder: PortForwarder,
            log: MorbLog,
            remainsAvailableForRestartPolicy: Bool = false
        ) {
            self.fd = fd
            self.containerID = containerID
            self.forwarder = forwarder
            self.log = log
            self.remainsAvailableForRestartPolicy = remainsAvailableForRestartPolicy
            self.traceID = Self.makeTraceID()
        }

        deinit {
            trace("event=deinit-close fd=\(fd)")
            Darwin.close(fd)
        }

        /// Performs the registration handshake before the Docker lifecycle relay
        /// begins. The blocking allocator work itself runs on a dedicated queue.
        func start() throws {
            let registration = Self.registrationLine(containerID: containerID, traceID: traceID)
            trace("event=register-send fd=\(fd) durable=\(remainsAvailableForRestartPolicy)")
            guard POSIXSocketSupport.writeAll(fd, Data(registration.utf8)) else {
                trace("event=register-write-failed errno=\(Self.errnoDescription())")
                throw MorbError.protocolViolation("the guest publish-all allocator did not accept the host session")
            }
            let reply = try Self.readLine(fd, timeout: 5) { [weak self] event in
                self?.trace(event)
            }
            trace("event=register-reply value=\(reply)")
            guard reply == "READY" else {
                throw MorbError.protocolViolation("the guest publish-all allocator did not accept the host session")
            }
            trace("event=serve-scheduled")
            queue.async { [weak self] in self?.serve() }
        }

        /// The original two-field registration remains the default wire grammar.
        /// The diagnostic extension is deliberately opt-in so an uninstrumented
        /// guest accepts exactly the same registration it did before SP-6.
        static func registrationLine(containerID: String, traceID: String?) -> String {
            if let traceID {
                return "REGISTER \(containerID) TRACE \(traceID)\n"
            }
            return "REGISTER \(containerID)\n"
        }

        func complete(succeeded: Bool) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                trace("event=lifecycle-complete-ignored succeeded=\(succeeded) reason=already-finished")
                return
            }
            // Only a session created by restart-policy recovery remains registered
            // after a successful lifecycle observation. A direct DockerProxy start
            // owns one request/response transaction and must release its guest fd
            // before reconciliation decides whether a persisted policy needs a
            // separate durable session.
            let closesAfterOutcome = !remainsAvailableForRestartPolicy
            if !succeeded || closesAfterOutcome {
                finished = true
            }
            let lease = self.lease
            let retained = !finished
            lock.unlock()
            trace("event=lifecycle-complete succeeded=\(succeeded) session-retained=\(retained)")
            if let lease {
                if succeeded {
                    _ = forwarder.completeStart(lease, succeeded: true)
                } else {
                    forwarder.abandon(lease, reason: "Docker publish-all start did not succeed")
                }
            }
            // The relay may keep an observed HTTP/1.1 connection alive after its
            // 204.  A one-shot session cannot rely on observer deallocation for
            // teardown: the guest would otherwise retain an open route to a host
            // worker that has already returned from `serve()`.
            if closesAfterOutcome {
                trace("event=direct-lifecycle-close fd=\(fd)")
                _ = Darwin.shutdown(fd, SHUT_RDWR)
            }
        }

        /// The only intentional host-side close.  A reason makes the opt-in trace
        /// distinguish a PortForwarder lifecycle teardown from a peer EOF.
        func invalidate(reason: String) {
            lock.lock()
            finished = true
            lock.unlock()
            trace("event=host-initiated-shutdown fd=\(fd) reason=\(reason)")
            _ = Darwin.shutdown(fd, SHUT_RDWR)
        }

        var isLive: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !finished
        }

        private func serve() {
            while !isFinished {
                do {
                    trace("event=await-alloc fd=\(fd)")
                    let header = try Self.readLine(
                        fd,
                        timeout: remainsAvailableForRestartPolicy ? 86_400 : 20
                    ) { [weak self] event in
                        self?.trace(event)
                    }
                    let fields = header.split(separator: " ", omittingEmptySubsequences: false)
                    guard fields.count == 3,
                          fields[0] == "ALLOC",
                          String(fields[1]) == containerID,
                          let count = Int(fields[2]),
                          (1...DockerPortPublicationPreflight.maximumSynchronousFixedPortBindings).contains(count)
                    else {
                        throw MorbError.protocolViolation("guest publish-all allocator sent an invalid request header")
                    }
                    trace("event=alloc-received count=\(count)")
                    var requests: [DockerPublishAllPortRequest] = []
                    requests.reserveCapacity(count)
                    for _ in 0..<count {
                        let request = try Self.readLine(fd, timeout: 5) { [weak self] event in
                            self?.trace(event)
                        }
                        requests.append(try Self.parseRequest(request))
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
                        trace("event=alloc-reply-write-failed errno=\(Self.errnoDescription())")
                        throw MorbError.io("could not return the publish-all allocation to the guest")
                    }
                    trace("event=alloc-reply-sent count=\(ports.count) session-retained=\(remainsAvailableForRestartPolicy)")
                } catch {
                    let message = error.localizedDescription
                        .replacingOccurrences(of: "\n", with: " ")
                    _ = POSIXSocketSupport.writeAll(fd, Data("ERR \(message)\n".utf8))
                    complete(succeeded: false)
                    trace("event=serve-failed error=\(message)")
                    log.warn("publish-all allocator for \(String(containerID.prefix(12))) failed: \(message)")
                    return
                }
                if !remainsAvailableForRestartPolicy { return }
            }
        }

        private var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished
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

        private static func readLine(
            _ fd: Int32,
            timeout: TimeInterval,
            trace: ((String) -> Void)? = nil
        ) throws -> String {
            let deadline = Date().addingTimeInterval(timeout)
            var bytes: [UInt8] = []
            while bytes.count < 512 {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw MorbError.timeout("the guest publish-all allocator did not reply in time") }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = POSIXSocketSupport.retryOnInterrupt {
                    withUnsafeMutablePointer(to: &descriptor) { poll($0, 1, Int32(remaining * 1_000)) }
                }
                if ready <= 0 {
                    trace?("event=poll-unready result=\(ready) errno=\(Self.errnoDescription())")
                }
                guard ready > 0 else { throw MorbError.io("the guest publish-all allocator disconnected") }
                if descriptor.revents & ~Int16(POLLIN) != 0 {
                    trace?("event=poll-nonread revents=0x\(String(Int(descriptor.revents), radix: 16))")
                }
                var byte: UInt8 = 0
                let read = withUnsafeMutablePointer(to: &byte) {
                    POSIXSocketSupport.readSome(fd, into: UnsafeMutableRawPointer($0), count: 1)
                }
                if read == 0 {
                    trace?("event=read-eof peer=guest")
                } else if read < 0 {
                    trace?("event=read-error errno=\(Self.errnoDescription())")
                }
                guard read == 1 else { throw MorbError.io("could not read the guest publish-all allocator") }
                if byte == 0x0A { return String(decoding: bytes, as: UTF8.self) }
                // Keep the wire protocol intentionally printable-ASCII only. Swift's
                // UInt8 API does not expose `isASCII` on every supported toolchain.
                guard (0x20...0x7E).contains(byte) else {
                    throw MorbError.protocolViolation("the guest publish-all allocator sent an invalid line")
                }
                bytes.append(byte)
            }
            throw MorbError.protocolViolation("the guest publish-all allocator sent an oversized line")
        }

        private static func makeTraceID() -> String? {
            guard ProcessInfo.processInfo.environment["MORBSTACK_PUBLISH_ALL_TRACE"] == "1" else {
                return nil
            }
            return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }

        private func trace(_ message: String) {
            guard let traceID else { return }
            log.info(
                "publish-all trace=\(traceID) endpoint=host container=\(String(containerID.prefix(12))) \(message)")
        }

        private static func errnoDescription() -> String {
            "\(errno) \(String(cString: strerror(errno)))"
        }
    }
}
