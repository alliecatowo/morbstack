// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Dispatch
import Foundation

/// The guest-initiated SSH-agent forwarding channel, vsock host port 2383
/// (``MorbVsockPorts/sshAgentForward``). UX-19.
///
/// Docker Desktop's documented contract for `docker run -v
/// /run/host-services/ssh-auth.sock:/run/host-services/ssh-auth.sock -e
/// SSH_AUTH_SOCK=/run/host-services/ssh-auth.sock ...` is a fixed guest path
/// that always exists. Morbstack's guest (`ssh_agent_forward.rs`) always
/// listens at that path so a Compose file copied from a Docker Desktop setup
/// does not fail to *find* the socket — but every connection to it is a
/// request this server can refuse, and it refuses by default.
///
/// ```text
/// guest -> host:  "SSHAUTH\n"
/// host  -> guest: "OK\n"             then the connection splices to the host's SSH agent
///            or:  "ERR <reason>\n"   then the connection closes
/// ```
///
/// **Security note.** Once enabled (``MorbConfig/sshAgentForwarding``), every
/// container in the guest that bind-mounts `/run/host-services/ssh-auth.sock`
/// can ask the host's SSH agent to sign with the user's own keys for as long
/// as this daemon is running — identical in shape to what Docker Desktop and
/// OrbStack both already expose, but worth restating because nothing about
/// starting a container implies "and it can now use my SSH keys." Off by
/// default. See `docs/design/SSH-AGENT-FORWARDING.md`.
public enum SSHAgentForward {

    /// The fixed guest-side path `morbinit` always listens on, matching
    /// `ssh_agent_forward::SSH_AUTH_SOCK_PATH` in the guest and Docker
    /// Desktop's own documented path. This is a resource the guest itself
    /// creates, not a Mac directory — ``DockerBindMountPreflight`` must not
    /// apply the "add a shared_paths root" bind-source rule to it, since no
    /// Mac-side root could ever contain it.
    public static let guestSocketPath = "/run/host-services/ssh-auth.sock"

    /// The only request line this channel accepts. There is nothing to
    /// parametrize — the mapping is always "the one host SSH agent" — so
    /// unlike ``GuestPortLease`` the grammar carries no fields.
    public static let preamble = "SSHAUTH"

    /// Longest request line accepted, including the newline. `"SSHAUTH\n"` is
    /// 8 bytes; the slack stops a confused or hostile guest from streaming
    /// forever while it waits for a `\n` that never comes.
    public static let maxRequestLineBytes = 64

    /// How long the guest has to deliver its one request line.
    public static let requestTimeout: TimeInterval = 10

    public static let okLine = Data("OK\n".utf8)

    /// A refusal whose reason becomes the wire `ERR` line — same shape as
    /// ``GuestPortLease/Refusal``.
    public struct Refusal: Error, Equatable, Sendable {
        public let reason: String
        public init(_ reason: String) { self.reason = reason }
    }

    /// Flattens a failure reason to one wire-safe line, the same discipline
    /// ``GuestPortLease/errLine(_:)`` uses.
    public static func errLine(_ reason: String) -> Data {
        let flattened = reason.map { $0 == "\n" || $0 == "\r" ? " " : $0 }
        return Data(("ERR " + String(flattened).prefix(maxRequestLineBytes) + "\n").utf8)
    }
}

/// Serves the SSH-agent forward channel: negotiate the fixed preamble, decide
/// whether forwarding is allowed, then either splice to the host's SSH agent
/// or refuse with a specific reason.
public final class SSHAgentForwardServer {

    /// Whether forwarding is currently permitted. A closure rather than a plain
    /// `Bool` parameter so tests can flip it per call; `Daemon.swift` captures its
    /// loaded `MorbConfig.sshAgentForwarding` once, matching every other setting
    /// here — changing it means editing `config.toml` and restarting, not a live
    /// reload this closure would need to observe.
    private let isEnabled: () -> Bool
    /// Resolves the Mac-side agent socket to dial, fresh per connection —
    /// injectable for tests, defaulting to the daemon process's own
    /// `SSH_AUTH_SOCK` environment variable.
    private let sshAuthSocketPath: () -> String?
    private let log: MorbLog
    /// Concurrent: several containers may open forwarded connections at once,
    /// and each negotiation briefly blocks on its preamble read and on
    /// dialing the host agent.
    private let queue = DispatchQueue(
        label: "dev.morbstack.sshagentforward", qos: .userInitiated, attributes: .concurrent)
    /// Where an accepted relay's two copy workers actually run; kept separate
    /// from the negotiation queue so a slow-draining forward cannot starve a
    /// new connection's preamble read.
    private let relayQueue = DispatchQueue(
        label: "dev.morbstack.sshagentforward.relay", attributes: .concurrent)
    private let lock = NSLock()
    /// Live relays, keyed by the guest-side descriptor, so the server can
    /// bound concurrency and prove it never leaks one.
    private var activeRelays: [Int32: FDRelay] = [:]
    /// Generous but bounded: each forward costs two threads (``FDRelay``'s
    /// copy workers) for as long as the container holds the connection open.
    static let maxConcurrentForwards = 64

    public init(
        isEnabled: @escaping () -> Bool,
        sshAuthSocketPath: @escaping () -> String? = {
            ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
        },
        log: MorbLog
    ) {
        self.isEnabled = isEnabled
        self.sshAuthSocketPath = sshAuthSocketPath
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
        let saturated = activeRelays.count >= Self.maxConcurrentForwards
        lock.unlock()
        if saturated {
            refuse(fd: fd, reason: "too many concurrent ssh-agent forwards")
            return
        }

        switch readRequestLine(fd: fd) {
        case .failure(let refusal):
            log.warn("ssh-agent forward request rejected: \(refusal.reason)")
            refuse(fd: fd, reason: refusal.reason)
            return
        case .success(let line):
            let body = line.hasSuffix("\n") ? String(line.dropLast()) : line
            guard body == SSHAgentForward.preamble else {
                refuse(fd: fd, reason: "expected \"\(SSHAgentForward.preamble)\"")
                return
            }
        }

        guard isEnabled() else {
            refuse(
                fd: fd,
                reason: "ssh agent forwarding is disabled; set ssh_agent_forwarding = true "
                    + "in ~/.morbstack/config.toml to enable it")
            return
        }

        guard let path = sshAuthSocketPath(), !path.isEmpty else {
            refuse(fd: fd, reason: "no SSH agent is available on the host (SSH_AUTH_SOCK is not set)")
            return
        }

        let agentFD: Int32
        do {
            agentFD = try UnixSocketClient.connect(path: path, timeout: 3)
        } catch {
            refuse(fd: fd, reason: "could not reach the host SSH agent at \(path): \(error)")
            return
        }

        guard writeAll(fd: fd, SSHAgentForward.okLine) else {
            // The guest vanished between asking and hearing the answer.
            Darwin.close(agentFD)
            Darwin.close(fd)
            return
        }

        let relay = FDRelay(fdA: fd, fdB: agentFD, queue: relayQueue) { [weak self] in
            self?.forget(fd: fd)
        }
        lock.lock()
        activeRelays[fd] = relay
        lock.unlock()
        relay.start()
    }

    private func forget(fd: Int32) {
        lock.lock()
        activeRelays.removeValue(forKey: fd)
        lock.unlock()
    }

    private func refuse(fd: Int32, reason: String) {
        _ = writeAll(fd: fd, SSHAgentForward.errLine(reason))
        Darwin.close(fd)
    }

    /// One byte at a time, bounded in size and time — the same discipline
    /// ``GuestPortLeaseServer`` uses for its own request line.
    private func readRequestLine(fd: Int32) -> Result<String, SSHAgentForward.Refusal> {
        var buffer: [UInt8] = []
        buffer.reserveCapacity(16)
        let deadline = Date().addingTimeInterval(SSHAgentForward.requestTimeout)
        while buffer.count < SSHAgentForward.maxRequestLineBytes {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                return .failure(.init("timed out waiting for the request line"))
            }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = POSIXSocketSupport.retryOnInterrupt {
                withUnsafeMutablePointer(to: &poller) {
                    poll($0, 1, Int32(min(remaining * 1000, 1000)))
                }
            }
            if ready < 0 {
                return .failure(.init("poll failed: \(String(cString: strerror(errno)))"))
            }
            if ready == 0 { continue }
            var byte: UInt8 = 0
            let n = withUnsafeMutablePointer(to: &byte) {
                POSIXSocketSupport.readSome(fd, into: $0, count: 1)
            }
            if n == 0 {
                return .failure(.init("the guest closed the channel before its request"))
            }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return .failure(.init("read failed: \(String(cString: strerror(errno)))"))
            }
            if byte == UInt8(ascii: "\n") {
                guard let line = String(bytes: buffer, encoding: .utf8) else {
                    return .failure(.init("the request line is not UTF-8"))
                }
                return .success(line)
            }
            buffer.append(byte)
        }
        return .failure(
            .init("the request line had no newline within \(SSHAgentForward.maxRequestLineBytes) bytes"))
    }

    private func writeAll(fd: Int32, _ data: Data) -> Bool {
        POSIXSocketSupport.writeAll(fd, data)
    }
}
