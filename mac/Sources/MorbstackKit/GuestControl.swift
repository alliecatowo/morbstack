// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Dispatch
import Foundation

/// The "MRB0" wire framing used on the guest control vsock port (1024).
///
/// Every frame is:
///
/// ```text
/// +--------+---------------------+------------------------+
/// | "MRB0" | big-endian uint32 N | N bytes of UTF-8 JSON  |
/// +--------+---------------------+------------------------+
/// ```
///
/// Frames are capped at 1 MiB so a confused guest cannot make the daemon allocate
/// unbounded memory.
public enum MRB0 {

    /// The four magic bytes that open every frame.
    public static let magic: [UInt8] = Array("MRB0".utf8)

    /// Fixed header size: 4 magic bytes + 4 length bytes.
    public static let headerSize = 8

    /// Largest accepted payload, in bytes.
    public static let maxPayloadSize = 1 << 20

    /// Wraps `payload` in a frame.
    ///
    /// - Throws: ``MorbError/protocolViolation(_:)`` when the payload exceeds ``maxPayloadSize``.
    public static func encode(payload: Data) throws -> Data {
        guard payload.count <= maxPayloadSize else {
            throw MorbError.protocolViolation(
                "frame payload of \(payload.count) bytes exceeds the \(maxPayloadSize) byte cap")
        }
        var frame = Data(capacity: headerSize + payload.count)
        frame.append(contentsOf: magic)
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    /// Validates an 8-byte header and returns the announced payload length.
    ///
    /// - Throws: ``MorbError/protocolViolation(_:)`` on a bad magic or an oversize length.
    public static func decodeHeader(_ header: Data) throws -> Int {
        guard header.count == headerSize else {
            throw MorbError.protocolViolation("frame header must be \(headerSize) bytes, got \(header.count)")
        }
        let bytes = [UInt8](header)
        guard Array(bytes[0..<4]) == magic else {
            throw MorbError.protocolViolation("bad frame magic")
        }
        let length =
            (UInt32(bytes[4]) << 24) | (UInt32(bytes[5]) << 16) | (UInt32(bytes[6]) << 8) | UInt32(bytes[7])
        guard length <= UInt32(maxPayloadSize) else {
            throw MorbError.protocolViolation(
                "frame announces \(length) bytes, above the \(maxPayloadSize) byte cap")
        }
        return Int(length)
    }

    /// Decodes a complete frame from a buffer.
    ///
    /// - Returns: The payload and the number of bytes consumed, or `nil` when
    ///   `buffer` does not yet hold a whole frame.
    public static func decode(from buffer: Data) throws -> (payload: Data, consumed: Int)? {
        guard buffer.count >= headerSize else { return nil }
        let header = buffer.prefix(headerSize)
        let length = try decodeHeader(Data(header))
        guard buffer.count >= headerSize + length else { return nil }
        let start = buffer.index(buffer.startIndex, offsetBy: headerSize)
        let end = buffer.index(start, offsetBy: length)
        return (Data(buffer[start..<end]), headerSize + length)
    }
}

/// A reply from `morbinit` running as PID 1 in the guest.
///
/// Only `type` is always present; the remaining fields are populated per message kind.
public struct GuestReply: Codable, Equatable, Sendable {
    /// `pong`, `info`, `ok` or `error`.
    public var type: String
    /// Guest uptime in milliseconds — present on `pong`.
    public var uptimeMilliseconds: Int?
    /// The `morbinit` version — present on `info`.
    public var morbinitVersion: String?
    /// `uname` output — present on `info`.
    public var kernel: String?
    /// `true` once dockerd's socket accepts connections — present on `info`.
    ///
    /// Optional rather than defaulted because "an older guest that never sends the
    /// field" and "a guest that says `false`" mean very different things to the boot
    /// probe: the first must not be waited on, the second must.
    public var dockerReady: Bool?
    /// `true` when `/var/lib/docker` is backed by the virtio disk rather than a
    /// tmpfs — present on `info` from guests that format `/dev/vda`.
    public var dockerDataOnDisk: Bool?
    /// What the guest did with each VirtioFS share it was told about — present on
    /// `info` from guests that mount host directories.
    ///
    /// Encoded as `"<percent-encoded-path>:<mounted|failed>"` entries joined with
    /// `,`; decode it with ``MorbShares/parseGuestShares(_:)``. A flat string rather
    /// than a nested object because MRB0's JSON is single-level by construction (see
    /// `jsonlite.rs` in the guest).
    public var shares: String?
    /// Whether the guest successfully made literal `/tmp` resolve to the mounted
    /// `/private/tmp` VirtioFS share. `nil` denotes an older guest that cannot prove
    /// this additional mount; callers must not treat absence as success.
    public var tmpAliasMounted: Bool?
    /// `true` when the guest mounted the host's Rosetta share *and* registered it
    /// with `binfmt_misc` — present on `info` from guests that do amd64 setup.
    ///
    /// Deliberately stricter than the host's own
    /// ``RosettaSupport/state``: the host can only say "I offered a share", and
    /// everything after that — virtiofs mounting, the interpreter being present,
    /// the registration being accepted — happens where the host cannot see. A
    /// host that reports ``RosettaState/installed`` while the guest reports
    /// `false` is the signature of a broken share rather than a missing one.
    ///
    /// Absent means "an older guest that does not report it", which is not the
    /// same as `false`; same convention as ``dockerReady``.
    public var rosetta: Bool?
    /// Which interpreter x86-64 ELF is registered to inside the guest:
    /// `"rosetta"`, `"qemu"`, or `"none"` — present on `info`.
    ///
    /// Separate from ``rosetta`` because the two answer different questions and
    /// can disagree: a guest that fell back to user-mode qemu reports
    /// `rosetta: false, binfmt_amd64: "qemu"`, which is a working amd64 setup on
    /// a host where the Rosetta path did not come together. Absent means an
    /// older guest, not `"none"`.
    public var binfmtAmd64: String?
    /// Whether the guest can accept the future bounded host file-event contract.
    ///
    /// "unavailable" is a positive statement that this guest has no kernel/filesystem
    /// endpoint capable of delivering host-originated notifications to container
    /// watchers; it is not a transient failure. `nil` means an older guest did not
    /// report the additive capability. Neither state claims hot reload.
    public var shareEventBridge: String?
    /// Version of the future acknowledged share-event record schema.
    ///
    /// The current guest reports version `1` while its capability remains
    /// `"unavailable"`; that reserves a record shape, not an event receiver. `nil`
    /// is never treated as version `1` for an older or incomplete guest.
    public var shareEventBridgeContractVersion: Int?
    /// Whether the guest can execute the complete stop-only VM disk-growth contract.
    ///
    /// `"unavailable"` means this guest has no explicit target request, filesystem
    /// identification, resize operation, and post-resize proof. `nil` means an older
    /// guest did not report the additive capability. Neither permits the host to
    /// truncate an existing data image.
    public var diskResize: String?
    /// Failure detail — present on `error`.
    public var message: String?

    enum CodingKeys: String, CodingKey {
        case type
        case uptimeMilliseconds = "uptime_ms"
        case morbinitVersion = "morbinit_version"
        case kernel
        case dockerReady = "docker_ready"
        case dockerDataOnDisk = "docker_data_on_disk"
        case shares
        case tmpAliasMounted = "tmp_alias_mounted"
        case rosetta
        case binfmtAmd64 = "binfmt_amd64"
        case shareEventBridge = "share_event_bridge"
        case shareEventBridgeContractVersion = "share_event_bridge_contract_version"
        case diskResize = "disk_resize"
        case message
    }
}

/// A request sent to `morbinit`.
///
/// `unixNanos` is only populated for `clock_sync`; it is omitted from the wire form
/// for every other message type.
public struct GuestRequest: Codable, Equatable, Sendable {
    /// `ping`, `info`, `clock_sync`, `disk_resize` or `shutdown`.
    public var type: String
    /// Host wall clock for `clock_sync`.
    public var unixNanos: Int64?
    /// The exact RAW capacity the guest must observe before it may resize the
    /// filesystem mounted at `/var/lib/docker`. Only populated for `disk_resize`.
    public var targetBytes: Int64?

    public init(type: String, unixNanos: Int64? = nil, targetBytes: Int64? = nil) {
        self.type = type
        self.unixNanos = unixNanos
        self.targetBytes = targetBytes
    }

    enum CodingKeys: String, CodingKey {
        case type
        case unixNanos = "unix_nanos"
        case targetBytes = "target_bytes"
    }
}

/// A post-fact statement from the guest's explicit mounted-filesystem grow action.
///
/// The host accepts this only when it also matches the durable RAW-image journal;
/// see ``MorbDiskGrowth/validateGuestProof(_:journal:)``. Keeping it separate from
/// ``GuestReply`` prevents unrelated control callers from receiving a bag of optional
/// disk fields and makes the transaction response impossible to mistake for `info`.
public struct GuestDiskResizeProof: Codable, Equatable, Sendable {
    public let type: String
    public let device: String
    public let mountPoint: String
    public let filesystem: String
    public let deviceBytes: Int64
    public let beforeFilesystemBytes: Int64
    public let afterFilesystemBytes: Int64
    public let resized: Bool
    /// `true` when the guest is replaying a durable receipt from a grow that
    /// completed before a host crash could record its MRB0 proof.
    public let previouslyProved: Bool
    public let message: String?

    enum CodingKeys: String, CodingKey {
        case type
        case device
        case mountPoint = "mount_point"
        case filesystem
        case deviceBytes = "device_bytes"
        case beforeFilesystemBytes = "before_filesystem_bytes"
        case afterFilesystemBytes = "after_filesystem_bytes"
        case resized
        case previouslyProved = "previously_proved"
        case message
    }

    /// Converts the wire response into the journal's deliberately host-owned schema.
    public var journalProof: MorbDiskGrowth.GuestProof {
        MorbDiskGrowth.GuestProof(
            device: device,
            mountPoint: mountPoint,
            filesystem: filesystem,
            deviceBytes: deviceBytes,
            beforeFilesystemBytes: beforeFilesystemBytes,
            afterFilesystemBytes: afterFilesystemBytes,
            resized: resized,
            previouslyProved: previouslyProved)
    }
}

/// The discriminant shared by the two legal replies to `disk_resize`.
///
/// A refusal deliberately has only `type` and `message`; it is not a partial
/// success proof. Decode this envelope before the strict success schema so an
/// honest guest refusal cannot be misreported as a missing `device` field.
private struct GuestDiskResizeReplyEnvelope: Decodable {
    let type: String
    let message: String?
}

/// A synchronous request/response client for the guest control channel.
///
/// The caller supplies a connected vsock file descriptor (see
/// ``VMManager/connectVsock(port:completion:)``); ``closeOwnedDescriptor()`` hands
/// its lifetime to this object.
///
/// **A control channel is single-in-flight by construction.** MRB0 has no request
/// identifiers, so a reply can only be matched to a request by arrival order: there
/// is exactly one outstanding exchange at a time, enforced by an internal lock, and
/// callers that want concurrency open a second connection.
///
/// That is also why a timed-out or malformed exchange *poisons* the channel. If a
/// slow guest answers after ``send(_:timeout:)`` has already given up, the reply is
/// still sitting in the socket buffer, and the next `send` would read it as the answer
/// to a different question — a `ping` returning the previous `shutdown`'s `ok`, and
/// every subsequent exchange off by one. Once poisoned, the descriptor is shut down
/// and closed and every later call fails fast so the caller reconnects instead.
public final class GuestControl {

    private let fd: Int32
    private let ioQueue = DispatchQueue(label: "dev.morbstack.guestcontrol.io")
    private let sendLock = NSLock()

    private let stateLock = NSLock()
    private var closeRequested = false
    private var poisonReason: String?

    /// Wraps a connected guest-control descriptor.
    public init(fd: Int32) {
        self.fd = fd
        // A guest that went away mid-exchange must produce EPIPE, not SIGPIPE.
        POSIXSocketSupport.suppressSIGPIPE(fd)
    }

    /// `true` once the channel has been poisoned or closed; every ``send(_:timeout:)``
    /// on it will fail from here on.
    public var isUsable: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return poisonReason == nil && !closeRequested
    }

    /// Closes the wrapped descriptor. Idempotent and safe to call concurrently.
    ///
    /// The descriptor is shut down first and only closed on ``ioQueue``, which is the
    /// same serial queue the reader runs on: closing it out from under a reader that
    /// is parked in `poll(2)` would risk the number being recycled by another socket
    /// before the reader noticed.
    public func closeOwnedDescriptor() {
        stateLock.lock()
        let alreadyRequested = closeRequested
        closeRequested = true
        stateLock.unlock()
        guard !alreadyRequested else { return }

        _ = Darwin.shutdown(fd, SHUT_RDWR)  // wakes a blocked reader with EOF
        ioQueue.async { [fd] in
            Darwin.close(fd)
        }
    }

    /// Marks the channel unusable and closes it.
    private func poison(_ reason: String) {
        stateLock.lock()
        if poisonReason == nil { poisonReason = reason }
        stateLock.unlock()
        closeOwnedDescriptor()
    }

    // MARK: - Convenience messages

    /// Sends `{"type":"ping"}` and returns the guest uptime in milliseconds.
    @discardableResult
    public func ping(timeout: TimeInterval = 5) throws -> Int {
        let reply = try send(GuestRequest(type: "ping"), timeout: timeout)
        guard reply.type == "pong" else { throw Self.unexpected(reply, expected: "pong") }
        return reply.uptimeMilliseconds ?? 0
    }

    /// Sends `{"type":"info"}` and returns the guest's self-description.
    public func info(timeout: TimeInterval = 5) throws -> GuestReply {
        let reply = try send(GuestRequest(type: "info"), timeout: timeout)
        guard reply.type == "info" else { throw Self.unexpected(reply, expected: "info") }
        return reply
    }

    /// Pushes the host wall clock into the guest, which has no RTC across suspends.
    public func clockSync(unixNanos: Int64 = Int64(Date().timeIntervalSince1970 * 1_000_000_000),
                          timeout: TimeInterval = 5) throws {
        let reply = try send(GuestRequest(type: "clock_sync", unixNanos: unixNanos), timeout: timeout)
        guard reply.type == "ok" else { throw Self.unexpected(reply, expected: "ok") }
    }

    /// Asks the guest to shut down cleanly.
    public func shutdown(timeout: TimeInterval = 10) throws {
        let reply = try send(GuestRequest(type: "shutdown"), timeout: timeout)
        guard reply.type == "ok" else { throw Self.unexpected(reply, expected: "ok") }
    }

    /// Runs the guest half of a journalled grow-only transaction.
    ///
    /// `targetBytes` is not advisory: the guest must prove `/dev/vda` reports exactly
    /// this capacity before it runs a filesystem tool. The caller must validate the
    /// returned proof against the host journal before considering the operation done.
    public func diskResize(targetBytes: Int64, timeout: TimeInterval = 45) throws -> GuestDiskResizeProof {
        guard targetBytes > 0 else {
            throw MorbError.config("disk resize requires a positive target capacity")
        }
        let payload = try JSONEncoder().encode(
            GuestRequest(type: "disk_resize", targetBytes: targetBytes))
        let reply = try sendRaw(payload: payload, describing: "disk_resize", timeout: timeout)
        return try Self.decodeDiskResizeReply(reply)
    }

    /// Decodes the exact two-variant MRB0 `disk_resize` reply schema.
    ///
    /// Kept separately testable from a live vsock exchange so the host remains
    /// compatible with the guest's intentional, compact error response:
    /// `{"type":"error","message":"…"}`. A successful response remains strict
    /// and must carry every field in ``GuestDiskResizeProof``.
    static func decodeDiskResizeReply(_ payload: Data) throws -> GuestDiskResizeProof {
        let decoder = JSONDecoder()
        let envelope: GuestDiskResizeReplyEnvelope
        do {
            envelope = try decoder.decode(GuestDiskResizeReplyEnvelope.self, from: payload)
        } catch {
            throw MorbError.protocolViolation(
                "guest returned a malformed disk_resize reply: \(error.localizedDescription)")
        }

        if envelope.type == "error" {
            guard let message = envelope.message?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !message.isEmpty
            else {
                throw MorbError.protocolViolation(
                    "guest returned a malformed disk_resize error without a message")
            }
            throw MorbError.protocolViolation("guest reported: \(message)")
        }
        guard envelope.type == "disk_resize" else {
            throw MorbError.protocolViolation("expected `disk_resize` reply, got `\(envelope.type)`")
        }

        do {
            return try decoder.decode(GuestDiskResizeProof.self, from: payload)
        } catch {
            throw MorbError.protocolViolation(
                "guest returned a malformed disk_resize proof: \(error.localizedDescription)")
        }
    }

    // MARK: - Framing

    /// Writes one frame and blocks for exactly one reply frame.
    ///
    /// The read happens on a private queue and the caller waits on a semaphore, so a
    /// wedged guest surfaces as ``MorbError/timeout(_:)`` rather than a hung daemon.
    ///
    /// Only one exchange runs at a time. Any timeout, framing violation or I/O error
    /// poisons the channel — see the type documentation for why a late reply must
    /// never be allowed to become the next call's answer.
    public func send(_ request: GuestRequest, timeout: TimeInterval) throws -> GuestReply {
        let reply = try sendRaw(
            payload: try JSONEncoder().encode(request),
            describing: request.type,
            timeout: timeout)
        return try JSONDecoder().decode(GuestReply.self, from: reply)
    }

    /// Sends an arbitrary JSON payload and returns the raw reply payload bytes.
    ///
    /// The escape hatch for message families whose replies do not fit ``GuestReply``.
    /// ``K8s`` uses it: a Kubernetes status reply carries a dozen fields that mean
    /// nothing to `ping`, and widening the shared reply struct with them would make
    /// every caller carry a bag of optionals belonging to a subsystem they never
    /// touch. Callers decode into a type of their own.
    ///
    /// All the channel's guarantees still apply — one exchange at a time, and a
    /// timeout or I/O failure poisons the channel — because this *is* the
    /// implementation ``send(_:timeout:)`` runs on, not a parallel path around it.
    ///
    /// - Parameter describing: the message name used in the timeout message, since
    ///   the payload is opaque here.
    public func sendRaw(payload: Data, describing: String, timeout: TimeInterval) throws -> Data {
        sendLock.lock()
        defer { sendLock.unlock() }

        stateLock.lock()
        let reason = poisonReason
        let isClosed = closeRequested
        stateLock.unlock()
        if let reason {
            throw MorbError.io("guest control channel is unusable (\(reason)); reconnect")
        }
        if isClosed {
            throw MorbError.io("guest control channel is closed; reconnect")
        }

        let frame = try MRB0.encode(payload: payload)
        guard POSIXSocketSupport.writeAll(fd, frame) else {
            let message = "guest control write failed: \(String(cString: strerror(errno)))"
            poison(message)
            throw MorbError.io(message)
        }

        let semaphore = DispatchSemaphore(value: 0)
        // The worker and the waiter can both touch the box when a timeout fires, so
        // the handoff is guarded rather than relying on the semaphore alone.
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: Result<Data, Error>?
            func set(_ value: Result<Data, Error>) {
                lock.lock()
                stored = value
                lock.unlock()
            }
            func take() -> Result<Data, Error>? {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }
        }
        let box = Box()

        let deadline = Date().addingTimeInterval(timeout)
        ioQueue.async { [fd] in
            defer { semaphore.signal() }
            do {
                let header = try GuestControl.readExactly(fd: fd, count: MRB0.headerSize, deadline: deadline)
                let length = try MRB0.decodeHeader(header)
                let payload = length == 0
                    ? Data()
                    : try GuestControl.readExactly(fd: fd, count: length, deadline: deadline)
                box.set(.success(payload))
            } catch {
                box.set(.failure(error))
            }
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            let message = "guest did not answer `\(describing)` within \(Int(timeout))s"
            poison(message)
            throw MorbError.timeout(message)
        }
        guard let result = box.take() else {
            poison("guest control produced no result")
            throw MorbError.protocolViolation("guest control produced no result")
        }
        do {
            return try result.get()
        } catch {
            // A framing failure means the byte stream is no longer aligned.
            poison("\(error)")
            throw error
        }
    }

    /// Reads exactly `count` bytes, honouring `deadline` via `poll(2)`.
    static func readExactly(fd: Int32, count: Int, deadline: Date) throws -> Data {
        guard count >= 0, count <= MRB0.maxPayloadSize + MRB0.headerSize else {
            throw MorbError.protocolViolation("refusing to read \(count) bytes")
        }
        var out = Data(capacity: count)
        var buffer = [UInt8](repeating: 0, count: min(count, 64 * 1024))

        while out.count < count {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw MorbError.timeout("guest control read timed out")
            }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = POSIXSocketSupport.retryOnInterrupt {
                withUnsafeMutablePointer(to: &poller) { poll($0, 1, Int32(remaining * 1000)) }
            }
            if ready == 0 { throw MorbError.timeout("guest control read timed out") }
            if ready < 0 {
                throw MorbError.io("poll failed: \(String(cString: strerror(errno)))")
            }

            let want = min(buffer.count, count - out.count)
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return POSIXSocketSupport.readSome(fd, into: base, count: want)
            }
            if n == 0 {
                throw MorbError.io("guest closed the control channel")
            }
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw MorbError.io("guest control read failed: \(String(cString: strerror(errno)))")
            }
            out.append(contentsOf: buffer[0..<n])
        }
        return out
    }

    private static func unexpected(_ reply: GuestReply, expected: String) -> MorbError {
        if reply.type == "error" {
            return .protocolViolation("guest reported: \(reply.message ?? "unknown error")")
        }
        return .protocolViolation("expected `\(expected)` reply, got `\(reply.type)`")
    }
}
