// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import CryptoKit
import Foundation

/// The host-side envelope and state model for a future acknowledged share-event
/// channel.
///
/// This is deliberately *not* a file synchronizer, cache, FSEvents adapter, or
/// transport. ``MorbLiveShareBridge`` remains the only current planner and
/// diagnostic, and it continues to report delivery unavailable for the shipping
/// guest. This type starts no watcher, opens no connection, creates no session key,
/// and retains no file contents.
///
/// A future transport implementation must first authenticate its peer and derive a
/// fresh, private 32-byte session key from that authenticated handshake. Only then
/// may that implementation create the internal ``VerifiedTransport`` authority and
/// use the state machine below. An HMAC is a binding for an already authenticated
/// channel; it is not a substitute for peer authentication, encryption, or a guest
/// receiver.
public enum MorbShareSyncProtocol {

    /// The wire/schema version for the `MSYN` envelope and typed payloads.
    /// Compatibility is exact: unknown versions are rejected, never downgraded.
    public static let version: UInt16 = 1

    /// `MSYN` identifies this private channel. It is intentionally distinct from
    /// MRB0: MRB0 is a request/reply control protocol, not a stream transport.
    public static let magic: [UInt8] = Array("MSYN".utf8)

    /// The envelope carries a fixed 36-byte canonical UUID session identifier.
    public static let headerSize = 56

    /// HMAC-SHA256 output length. The tag follows the payload in every envelope.
    public static let authenticationTagSize = 32

    /// A frame is bounded below MRB0's one-megabyte maximum. The bound applies
    /// before a receiver allocates its payload buffer.
    public static let maximumPayloadBytes = 256 * 1_024

    /// Root ids and VirtioFS tags share the guest validator's deliberately small,
    /// ASCII-only identifier budget. They are labels, never paths or display names.
    public static let maximumRootIdentifierBytes = 64

    /// The guest and host independently reject paths above this before a proposed
    /// claim reaches a filesystem API. This is a protocol allocation limit, not a
    /// path-normalization routine.
    public static let maximumPathBytes = 4_096

    /// Direction is part of the authenticated bytes, so a valid guest acknowledgement
    /// cannot be replayed as a host event batch (or the reverse).
    public enum Direction: UInt8, Codable, Equatable, Sendable {
        case hostToGuest = 1
        case guestToHost = 2
    }

    /// The only envelope payload kinds reserved by version 1.
    public enum Kind: UInt8, Codable, Equatable, Sendable {
        /// Host `Hello`, matching the guest's typed `live_share::Hello` input.
        case hello = 1
        /// Guest proof that it accepted the exact `Hello` root claims.
        case ready = 2
        /// Host-to-guest record carrying the guest's complete RecordHeader fields.
        case record = 3
        /// Guest-to-host acknowledgement of one complete host record.
        case acknowledgement = 4
        /// A terminal, non-reconnecting session close.
        case close = 5
    }

    /// A strict, authenticated envelope before its payload is interpreted.
    ///
    /// The exact pre-HMAC byte sequence is:
    ///
    /// ```text
    /// +------+---------+-----+------+----------------+----------+----------+---------+
    /// | MSYN | version | dir | kind | UUID (36 ASCII) | sequence | payloadN | payload |
    /// +------+---------+-----+------+----------------+----------+----------+---------+
    ///    4       2       1      1           36             8          4          N
    /// ```
    ///
    /// The 32-byte HMAC-SHA256 tag is appended after `payload`. Integers are
    /// big-endian; UUID text must exactly equal `UUID.uuidString`, so alternative
    /// spellings are rejected. A stream implementation must delimit this envelope
    /// without accepting more than one complete envelope at a time.
    public struct Frame: Equatable, Sendable {
        public let version: UInt16
        public let direction: Direction
        public let kind: Kind
        public let sessionID: UUID
        public let sequence: UInt64
        public let payload: Data

        public init(
            version: UInt16 = MorbShareSyncProtocol.version,
            direction: Direction,
            kind: Kind,
            sessionID: UUID,
            sequence: UInt64,
            payload: Data
        ) throws {
            guard version == MorbShareSyncProtocol.version else {
                throw MorbError.protocolViolation(
                    "share-sync frame version \(version) is unsupported (expected \(MorbShareSyncProtocol.version))")
            }
            guard payload.count <= MorbShareSyncProtocol.maximumPayloadBytes else {
                throw MorbError.protocolViolation(
                    "share-sync frame payload of \(payload.count) bytes exceeds the \(MorbShareSyncProtocol.maximumPayloadBytes) byte cap")
            }
            switch (direction, kind) {
            case (.hostToGuest, .hello), (.guestToHost, .ready):
                guard sequence == 0 else {
                    throw MorbError.protocolViolation(
                        "share-sync \(kind) frames must use sequence zero")
                }
            case (.hostToGuest, .record), (.guestToHost, .acknowledgement),
                 (.hostToGuest, .close):
                guard sequence > 0 else {
                    throw MorbError.protocolViolation(
                        "share-sync \(kind) frames must use a nonzero sequence")
                }
            default:
                throw MorbError.protocolViolation(
                    "share-sync frame direction is invalid for \(kind)")
            }
            self.version = version
            self.direction = direction
            self.kind = kind
            self.sessionID = sessionID
            self.sequence = sequence
            self.payload = payload
        }

        fileprivate var authenticatedBytes: Data {
            var result = Data(capacity: MorbShareSyncProtocol.headerSize + payload.count)
            result.append(contentsOf: MorbShareSyncProtocol.magic)
            MorbShareSyncProtocol.append(version, to: &result)
            result.append(direction.rawValue)
            result.append(kind.rawValue)
            result.append(contentsOf: sessionID.uuidString.utf8)
            MorbShareSyncProtocol.append(sequence, to: &result)
            MorbShareSyncProtocol.append(UInt32(payload.count), to: &result)
            result.append(payload)
            return result
        }
    }

    /// A frame plus its HMAC-SHA256 tag. This type is internal because the shipping
    /// app has no authenticated data plane that could safely produce or consume one.
    internal struct AuthenticatedFrame: Equatable, Sendable {
        let frame: Frame
        let tag: Data

        init(frame: Frame, tag: Data) throws {
            guard tag.count == MorbShareSyncProtocol.authenticationTagSize else {
                throw MorbError.protocolViolation(
                    "share-sync authentication tag must be \(MorbShareSyncProtocol.authenticationTagSize) bytes")
            }
            self.frame = frame
            self.tag = tag
        }
    }

    /// A 128-bit opaque identifier written as an exact JSON byte array. The envelope
    /// uses the equivalent canonical UUID text only so its fixed header is simple to
    /// inspect; ``Identifier`` is the 16-byte form consumed by `live_share::Hello`.
    public struct Identifier: Codable, Equatable, Hashable, Sendable {
        public static let byteCount = 16

        public let bytes: [UInt8]

        public init(bytes: [UInt8]) throws {
            guard bytes.count == Self.byteCount, bytes.contains(where: { $0 != 0 }) else {
                throw MorbError.protocolViolation(
                    "share-sync identifiers must contain \(Self.byteCount) nonzero bytes")
            }
            self.bytes = bytes
        }

        public init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            var bytes: [UInt8] = []
            while !container.isAtEnd {
                bytes.append(try container.decode(UInt8.self))
            }
            try self.init(bytes: bytes)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            for byte in bytes { try container.encode(byte) }
        }

        fileprivate init(uuid: UUID) throws {
            let text = uuid.uuidString.replacingOccurrences(of: "-", with: "")
            var bytes: [UInt8] = []
            bytes.reserveCapacity(Self.byteCount)
            for offset in stride(from: 0, to: text.count, by: 2) {
                let start = text.index(text.startIndex, offsetBy: offset)
                let end = text.index(start, offsetBy: 2)
                guard let byte = UInt8(text[start..<end], radix: 16) else {
                    throw MorbError.protocolViolation("could not encode share-sync UUID as bytes")
                }
                bytes.append(byte)
            }
            try self.init(bytes: bytes)
        }
    }

    /// Exact root authority accepted by the guest's `live_share::RootClaim`.
    ///
    /// `rootID` is a deterministic opaque label, not a path. `backingShareTag`, mount path,
    /// access mode, and epoch are included so the guest can reject a stale or changed
    /// VirtioFS mount before it considers a record for the selected project.
    public struct RootClaim: Codable, Equatable, Hashable, Sendable {
        public let rootID: String
        public let backingShareTag: String
        public let guestPath: String
        public let backingSharePath: String
        public let readOnly: Bool
        public let epoch: UInt64

        public init(
            rootID: String,
            backingShareTag: String,
            guestPath: String,
            backingSharePath: String,
            readOnly: Bool,
            epoch: UInt64
        ) {
            self.rootID = rootID
            self.backingShareTag = backingShareTag
            self.guestPath = guestPath
            self.backingSharePath = backingSharePath
            self.readOnly = readOnly
            self.epoch = epoch
        }

        private enum CodingKeys: String, CodingKey {
            case rootID = "root_id"
            case backingShareTag = "backing_share_tag"
            case guestPath = "guest_path"
            case backingSharePath = "backing_share_path"
            case readOnly = "read_only"
            case epoch
        }
    }

    /// Builds the exact claims the current guest validator accepts from a narrow-root
    /// plan and one atomic VirtioFS mount generation. It performs no VM query itself.
    /// A future owner must source `shares` and `epoch` from the same daemon snapshot.
    public static func rootClaims(
        plan: MorbLiveShareBridge.Plan,
        shares: [MorbDirectoryShare],
        epoch: UInt64
    ) throws -> [RootClaim] {
        guard epoch > 0 else {
            throw MorbError.protocolViolation("share-sync mount epoch must be nonzero")
        }
        guard plan.roots.count <= MorbLiveShareBridge.maximumRoots else {
            throw MorbError.protocolViolation("share-sync plan exceeds the narrow-root limit")
        }
        var tags = Set<String>()
        var sharePaths = Set<String>()
        for share in shares {
            guard isValidLabel(share.tag), tags.insert(share.tag).inserted,
                  isValidAbsolutePath(share.path), sharePaths.insert(share.path).inserted
            else {
                throw MorbError.protocolViolation("share-sync mount snapshot contains an invalid or duplicate VirtioFS share")
            }
        }

        var claims: [RootClaim] = []
        var ids = Set<String>()
        for root in plan.roots.sorted(by: { $0.path < $1.path }) {
            guard isValidAbsolutePath(root.path), isValidAbsolutePath(root.backingSharePath),
                  isStrictDescendant(root.path, of: root.backingSharePath),
                  let share = shares.first(where: { $0.path == root.backingSharePath })
            else {
                throw MorbError.protocolViolation(
                    "share-sync root \(root.path) is not covered by the supplied VirtioFS mount snapshot")
            }
            let rootID = try rootIdentifier(
                tag: share.tag,
                rootPath: root.path,
                backingSharePath: share.path,
                readOnly: share.readOnly)
            guard ids.insert(rootID).inserted else {
                throw MorbError.protocolViolation("share-sync root claims generated a duplicate root identifier")
            }
            claims.append(
                RootClaim(
                    rootID: rootID,
                    backingShareTag: share.tag,
                    guestPath: root.path,
                    backingSharePath: share.path,
                    readOnly: share.readOnly,
                    epoch: epoch))
        }
        for (index, claim) in claims.enumerated() {
            for other in claims.dropFirst(index + 1) where
                isEqualOrDescendant(claim.guestPath, of: other.guestPath)
                    || isEqualOrDescendant(other.guestPath, of: claim.guestPath)
            {
                throw MorbError.protocolViolation(
                    "share-sync roots \(claim.guestPath) and \(other.guestPath) overlap")
            }
        }
        return claims
    }

    /// Host's first typed message, field-for-field aligned with the guest's inert
    /// `live_share::Hello`. Its construction alone is not an activation signal.
    public struct Hello: Codable, Equatable, Sendable {
        public let contractVersion: Int64
        public let sessionID: Identifier
        public let guestBootID: Identifier
        public let peerCapability: [UInt8]
        public let roots: [RootClaim]

        public init(
            contractVersion: Int64,
            sessionID: Identifier,
            guestBootID: Identifier,
            peerCapability: [UInt8],
            roots: [RootClaim]
        ) {
            self.contractVersion = contractVersion
            self.sessionID = sessionID
            self.guestBootID = guestBootID
            self.peerCapability = peerCapability
            self.roots = roots
        }

        private enum CodingKeys: String, CodingKey {
            case contractVersion = "contract_version"
            case sessionID = "session_id"
            case guestBootID = "guest_boot_id"
            case peerCapability = "peer_capability"
            case roots
        }
    }

    /// The future guest proof mapping. Guest code does not emit this today; when it
    /// does, it must echo the complete Hello authority after checking actual mounts.
    /// The host accepts no subset, superset, reordering, or path normalization.
    public struct Ready: Codable, Equatable, Sendable {
        public let contractVersion: Int64
        public let sessionID: Identifier
        public let guestBootID: Identifier
        public let roots: [RootClaim]

        public init(
            contractVersion: Int64,
            sessionID: Identifier,
            guestBootID: Identifier,
            roots: [RootClaim]
        ) {
            self.contractVersion = contractVersion
            self.sessionID = sessionID
            self.guestBootID = guestBootID
            self.roots = roots
        }

        private enum CodingKeys: String, CodingKey {
            case contractVersion = "contract_version"
            case sessionID = "session_id"
            case guestBootID = "guest_boot_id"
            case roots
        }
    }

    /// Header fields intentionally match guest `live_share::RecordHeader`. A future
    /// owner must provide them from an acknowledged file-content lifecycle; the host
    /// cannot turn an FSEvents hint into one of these records by itself.
    public struct RecordHeader: Codable, Equatable, Sendable {
        public let contractVersion: Int64
        public let sessionID: Identifier
        public let guestBootID: Identifier
        public let rootID: String
        public let epoch: UInt64
        public let direction: Direction
        public let sequence: UInt64
        public let baseRevision: UInt64

        public init(
            contractVersion: Int64,
            sessionID: Identifier,
            guestBootID: Identifier,
            rootID: String,
            epoch: UInt64,
            direction: Direction,
            sequence: UInt64,
            baseRevision: UInt64
        ) {
            self.contractVersion = contractVersion
            self.sessionID = sessionID
            self.guestBootID = guestBootID
            self.rootID = rootID
            self.epoch = epoch
            self.direction = direction
            self.sequence = sequence
            self.baseRevision = baseRevision
        }

        private enum CodingKeys: String, CodingKey {
            case contractVersion = "contract_version"
            case sessionID = "session_id"
            case guestBootID = "guest_boot_id"
            case rootID = "root_id"
            case epoch
            case direction
            case sequence
            case baseRevision = "base_revision"
        }
    }

    /// A generic record envelope that intentionally has no file-content payload.
    /// The future content format belongs beside the guest durable journal, not here.
    public struct Record: Codable, Equatable, Sendable {
        public let header: RecordHeader

        public init(header: RecordHeader) {
            self.header = header
        }
    }

    /// An acknowledgement is valid only for one pending host sequence. A disposition
    /// other than `applied` closes the host session because this foundation has no
    /// file-content reconciliation mechanism to repair a partial delivery.
    public enum AcknowledgementDisposition: String, Codable, Equatable, Sendable {
        case applied
        case requiresRescan = "requires-rescan"
        case rejected
    }

    public struct Acknowledgement: Codable, Equatable, Sendable {
        public let contractVersion: Int64
        public let sessionID: Identifier
        public let guestBootID: Identifier
        public let acknowledgedHostSequence: UInt64
        public let disposition: AcknowledgementDisposition

        public init(
            contractVersion: Int64,
            sessionID: Identifier,
            guestBootID: Identifier,
            acknowledgedHostSequence: UInt64,
            disposition: AcknowledgementDisposition
        ) {
            self.contractVersion = contractVersion
            self.sessionID = sessionID
            self.guestBootID = guestBootID
            self.acknowledgedHostSequence = acknowledgedHostSequence
            self.disposition = disposition
        }

        private enum CodingKeys: String, CodingKey {
            case contractVersion = "contract_version"
            case sessionID = "session_id"
            case guestBootID = "guest_boot_id"
            case acknowledgedHostSequence = "acknowledged_host_sequence"
            case disposition
        }
    }

    /// A terminal reason is deliberately an enum rather than arbitrary peer text so
    /// diagnostic or untrusted payloads cannot become a control surface.
    public enum CloseReason: String, Codable, Equatable, Sendable {
        case hostStopped = "host-stopped"
        case acknowledgementRejected = "acknowledgement-rejected"
        case protocolViolation = "protocol-violation"
    }

    public struct Close: Codable, Equatable, Sendable {
        public let sessionID: Identifier
        public let guestBootID: Identifier
        public let reason: CloseReason

        public init(sessionID: Identifier, guestBootID: Identifier, reason: CloseReason) {
            self.sessionID = sessionID
            self.guestBootID = guestBootID
            self.reason = reason
        }

        private enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case guestBootID = "guest_boot_id"
            case reason
        }
    }

    /// A private authority minted only by a future, peer-authenticated transport.
    ///
    /// There is intentionally no public initializer and no random-key convenience.
    /// The current app has no code path that constructs this type, so merely enabling
    /// a root in config cannot open a transport or cause a watcher to start.
    internal struct VerifiedTransport: @unchecked Sendable {
        fileprivate let sessionID: UUID
        fileprivate let sessionIdentifier: Identifier
        fileprivate let guestBootID: Identifier
        fileprivate let peerCapability: [UInt8]
        fileprivate let key: SymmetricKey

        /// Call only after authenticating the guest peer and deriving the material
        /// from that authenticated, fresh handshake. It must never be sourced from
        /// config, an environment variable, a persistent preference, or a reused key.
        internal init(
            sessionID: UUID,
            guestBootID: Identifier,
            peerCapability: [UInt8],
            keyMaterial: Data
        ) throws {
            guard keyMaterial.count == authenticationTagSize,
                  keyMaterial.contains(where: { $0 != 0 }),
                  peerCapability.count == authenticationTagSize,
                  peerCapability.contains(where: { $0 != 0 })
            else {
                throw MorbError.protocolViolation(
                    "share-sync peer capability and session key must each contain \(authenticationTagSize) nonzero bytes")
            }
            self.sessionID = sessionID
            sessionIdentifier = try Identifier(uuid: sessionID)
            self.guestBootID = guestBootID
            self.peerCapability = peerCapability
            key = SymmetricKey(data: keyMaterial)
        }
    }

    /// Encodes a bounded typed payload. The JSON bytes are covered verbatim by the
    /// HMAC; sorted keys make host-produced records deterministic for diagnostics.
    /// Unknown envelope versions are rejected before any payload decoder runs.
    internal static func encodePayload<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw MorbError.protocolViolation(
                "could not encode share-sync payload: \(error.localizedDescription)")
        }
        guard data.count <= maximumPayloadBytes else {
            throw MorbError.protocolViolation(
                "share-sync payload of \(data.count) bytes exceeds the \(maximumPayloadBytes) byte cap")
        }
        return data
    }

    /// Decodes one payload only after a caller has verified its envelope's HMAC,
    /// version, direction, kind, session, and sequence. The payload must be exactly
    /// one JSON object with the supplied top-level schema; additive fields require a
    /// protocol-version change rather than being silently ignored.
    internal static func decodePayload<Value: Decodable>(
        _ type: Value.Type,
        from payload: Data,
        exactTopLevelKeys: Set<String>
    ) throws -> Value {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: payload, options: [])
        } catch {
            throw MorbError.protocolViolation(
                "share-sync payload is not valid JSON: \(error.localizedDescription)")
        }
        guard let dictionary = object as? [String: Any], Set(dictionary.keys) == exactTopLevelKeys else {
            throw MorbError.protocolViolation("share-sync payload has an unexpected top-level schema")
        }
        do {
            return try JSONDecoder().decode(Value.self, from: payload)
        } catch {
            throw MorbError.protocolViolation(
                "could not decode share-sync payload: \(error.localizedDescription)")
        }
    }

    /// Signs a fully validated envelope with the transport's fresh session key.
    internal static func sign(_ frame: Frame, over transport: VerifiedTransport) throws -> AuthenticatedFrame {
        guard frame.sessionID == transport.sessionID else {
            throw MorbError.protocolViolation("share-sync frame session does not match the authenticated transport")
        }
        let tag = Data(HMAC<SHA256>.authenticationCode(for: frame.authenticatedBytes, using: transport.key))
        return try AuthenticatedFrame(frame: frame, tag: tag)
    }

    /// Verifies the HMAC before a caller may read a peer-controlled payload.
    internal static func verify(
        _ authenticated: AuthenticatedFrame,
        over transport: VerifiedTransport
    ) throws -> Frame {
        let frame = authenticated.frame
        guard frame.sessionID == transport.sessionID else {
            throw MorbError.protocolViolation("share-sync frame session does not match the authenticated transport")
        }
        let expected = Data(HMAC<SHA256>.authenticationCode(for: frame.authenticatedBytes, using: transport.key))
        guard constantTimeEqual(authenticated.tag, expected) else {
            throw MorbError.protocolViolation("share-sync frame failed HMAC verification")
        }
        return frame
    }

    /// Serializes a complete envelope. A future stream transport may write exactly
    /// these bytes only after applying its own bounded message framing.
    internal static func encode(_ authenticated: AuthenticatedFrame) -> Data {
        var result = authenticated.frame.authenticatedBytes
        result.append(authenticated.tag)
        return result
    }

    /// Decodes exactly one complete envelope. It does not buffer partial data or open
    /// a stream; that remains the responsibility of a future authenticated transport.
    internal static func decode(_ bytes: Data) throws -> AuthenticatedFrame {
        guard bytes.count >= headerSize + authenticationTagSize else {
            throw MorbError.protocolViolation("share-sync envelope is shorter than its fixed header and tag")
        }
        let byte = [UInt8](bytes)
        guard Array(byte[0..<4]) == magic else {
            throw MorbError.protocolViolation("bad share-sync frame magic")
        }
        let version = (UInt16(byte[4]) << 8) | UInt16(byte[5])
        guard version == Self.version else {
            throw MorbError.protocolViolation(
                "share-sync frame version \(version) is unsupported (expected \(Self.version))")
        }
        guard let direction = Direction(rawValue: byte[6]), let kind = Kind(rawValue: byte[7]) else {
            throw MorbError.protocolViolation("share-sync frame has an unknown direction or kind")
        }
        let sessionText = String(bytes: byte[8..<44], encoding: .ascii)
        guard let sessionText, let sessionID = UUID(uuidString: sessionText),
              sessionID.uuidString == sessionText
        else {
            throw MorbError.protocolViolation("share-sync frame has a noncanonical session UUID")
        }
        let sequence = readUInt64(byte, at: 44)
        let payloadLength = Int(readUInt32(byte, at: 52))
        guard payloadLength <= maximumPayloadBytes else {
            throw MorbError.protocolViolation(
                "share-sync frame announces \(payloadLength) bytes, above the \(maximumPayloadBytes) byte cap")
        }
        let expectedCount = headerSize + payloadLength + authenticationTagSize
        guard byte.count == expectedCount else {
            throw MorbError.protocolViolation(
                "share-sync envelope length \(byte.count) does not match its announced payload length")
        }
        let payload = Data(byte[headerSize..<(headerSize + payloadLength)])
        let frame = try Frame(
            version: version,
            direction: direction,
            kind: kind,
            sessionID: sessionID,
            sequence: sequence,
            payload: payload)
        return try AuthenticatedFrame(
            frame: frame,
            tag: Data(byte[(headerSize + payloadLength)..<expectedCount]))
    }

    /// A one-session host state machine. It is pure bookkeeping: it owns neither an
    /// FSEvent stream nor a socket, and every method that advances toward `active`
    /// requires a ``VerifiedTransport`` unavailable to current production code.
    public final class HostSession: @unchecked Sendable {
        public enum State: Equatable, Sendable {
            /// No narrow project roots were selected.
            case disabled
            /// Existing guest-advertisement validation refused delivery.
            case denied(MorbLiveShareBridge.DeliveryAdmission)
            /// A compatible future guest was observed, but no authenticated transport
            /// and no receiver implementation has been attached.
            case requiresAuthenticatedTransport
            /// A verified future transport sent an exact host Hello; awaiting its
            /// matching guest `ready` proof.
            case awaitingReady
            /// Exactly one host event batch may be outstanding at a time.
            case active
            /// The session will not reconnect or retarget automatically.
            case closed
        }

        private let roots: [RootClaim]
        private var stateStorage: State
        private var hello: Hello?
        private var nextHostSequence: UInt64 = 1
        private var nextGuestSequence: UInt64 = 1
        private var outstandingHostSequence: UInt64?

        /// Evaluates only a previously observed guest advertisement and an atomic
        /// caller-supplied VirtioFS snapshot. It has no filesystem, VM, FSEvents, or
        /// network effect of its own.
        public init(
            plan: MorbLiveShareBridge.Plan,
            shares: [MorbDirectoryShare],
            mountEpoch: UInt64,
            guestAdvertisement: MorbLiveShareBridge.GuestAdvertisement
        ) throws {
            if plan.isEnabled {
                roots = try rootClaims(plan: plan, shares: shares, epoch: mountEpoch)
            } else {
                roots = []
            }
            guard plan.isEnabled else {
                stateStorage = .disabled
                return
            }
            let admission = MorbLiveShareBridge.DeliveryAdmission.evaluate(guestAdvertisement)
            switch admission {
            case .compatibleReceiverRequiresTransport:
                stateStorage = .requiresAuthenticatedTransport
            default:
                stateStorage = .denied(admission)
            }
        }

        public var state: State { stateStorage }

        /// Emits the first signed message only after a future transport has already
        /// authenticated the guest and created a fresh, in-memory authority.
        internal func begin(over transport: VerifiedTransport) throws -> AuthenticatedFrame {
            guard stateStorage == .requiresAuthenticatedTransport else {
                throw MorbError.protocolViolation("share-sync session cannot send Hello from state \(stateDescription)")
            }
            let hello = Hello(
                contractVersion: Int64(version),
                sessionID: transport.sessionIdentifier,
                guestBootID: transport.guestBootID,
                peerCapability: transport.peerCapability,
                roots: roots)
            let frame = try Frame(
                direction: .hostToGuest,
                kind: .hello,
                sessionID: transport.sessionID,
                sequence: 0,
                payload: try encodePayload(hello))
            self.hello = hello
            stateStorage = .awaitingReady
            return try sign(frame, over: transport)
        }

        /// Accepts the guest's signed proof only when it echoes the exact Hello root
        /// claims and guest boot identity. It does not start a watcher or send data.
        internal func acceptReady(
            _ authenticated: AuthenticatedFrame,
            over transport: VerifiedTransport
        ) throws {
            guard stateStorage == .awaitingReady, let hello else {
                throw MorbError.protocolViolation("share-sync ready arrived outside the hello state")
            }
            let frame = try verify(authenticated, over: transport)
            guard frame.direction == .guestToHost, frame.kind == .ready, frame.sequence == 0 else {
                throw MorbError.protocolViolation("share-sync expected a guest ready frame at sequence zero")
            }
            let ready = try decodePayload(
                Ready.self,
                from: frame.payload,
                exactTopLevelKeys: ["contract_version", "session_id", "guest_boot_id", "roots"])
            guard ready.contractVersion == Int64(version),
                  ready.sessionID == hello.sessionID,
                  ready.guestBootID == hello.guestBootID,
                  ready.roots == hello.roots
            else {
                stateStorage = .closed
                throw MorbError.protocolViolation(
                    "share-sync ready did not echo this session's exact hello authority")
            }
            stateStorage = .active
        }

        /// Signs one fully specified future record. This layer deliberately cannot
        /// derive a record from FSEvents; a later durable-content owner must supply
        /// the guest-compatible header and wait for `applied` acknowledgement.
        internal func sendRecord(
            _ record: Record,
            over transport: VerifiedTransport
        ) throws -> AuthenticatedFrame {
            guard stateStorage == .active, let hello else {
                throw MorbError.protocolViolation("share-sync cannot send a record outside an active session")
            }
            guard outstandingHostSequence == nil else {
                throw MorbError.protocolViolation("share-sync cannot send a second record before acknowledgement")
            }
            guard nextHostSequence < UInt64.max else {
                stateStorage = .closed
                throw MorbError.protocolViolation("share-sync host sequence space is exhausted")
            }
            guard isAuthorizedRecord(record, hello: hello, expectedSequence: nextHostSequence) else {
                throw MorbError.protocolViolation("share-sync record is outside its exact hello authority")
            }
            let sequence = nextHostSequence
            let frame = try Frame(
                direction: .hostToGuest,
                kind: .record,
                sessionID: transport.sessionID,
                sequence: sequence,
                payload: try encodePayload(record))
            outstandingHostSequence = sequence
            nextHostSequence += 1
            return try sign(frame, over: transport)
        }

        /// Consumes exactly one signed acknowledgement. Only `applied` releases the
        /// outstanding batch. A request to rescan is terminal here because this code
        /// does not own a file-content reconciliation mechanism.
        internal func acceptAcknowledgement(
            _ authenticated: AuthenticatedFrame,
            over transport: VerifiedTransport
        ) throws {
            guard stateStorage == .active, let hello, let outstandingHostSequence else {
                throw MorbError.protocolViolation("share-sync acknowledgement arrived without an outstanding record")
            }
            let frame = try verify(authenticated, over: transport)
            guard frame.direction == .guestToHost,
                  frame.kind == .acknowledgement,
                  frame.sequence == nextGuestSequence
            else {
                throw MorbError.protocolViolation("share-sync acknowledgement has an unexpected direction, kind, or sequence")
            }
            let acknowledgement = try decodePayload(
                Acknowledgement.self,
                from: frame.payload,
                exactTopLevelKeys: ["contract_version", "session_id", "guest_boot_id", "acknowledged_host_sequence", "disposition"])
            guard acknowledgement.contractVersion == Int64(version),
                  acknowledgement.sessionID == hello.sessionID,
                  acknowledgement.guestBootID == hello.guestBootID,
                  acknowledgement.acknowledgedHostSequence == outstandingHostSequence
            else {
                stateStorage = .closed
                throw MorbError.protocolViolation("share-sync acknowledgement does not match the outstanding host batch")
            }
            guard acknowledgement.disposition == .applied else {
                stateStorage = .closed
                throw MorbError.protocolViolation(
                    "share-sync guest did not apply host record \(outstandingHostSequence); session is closed")
            }
            guard nextGuestSequence < UInt64.max else {
                stateStorage = .closed
                throw MorbError.protocolViolation("share-sync guest sequence space is exhausted")
            }
            self.outstandingHostSequence = nil
            nextGuestSequence += 1
        }

        /// Produces a final signed close record for a future transport, then disables
        /// this in-memory session. It never reconnects, retargets, or persists state.
        internal func close(
            reason: CloseReason = .hostStopped,
            over transport: VerifiedTransport
        ) throws -> AuthenticatedFrame? {
            guard let hello else {
                stateStorage = .closed
                return nil
            }
            guard stateStorage != .closed, nextHostSequence < UInt64.max else {
                stateStorage = .closed
                return nil
            }
            let sequence = nextHostSequence
            nextHostSequence += 1
            stateStorage = .closed
            let frame = try Frame(
                direction: .hostToGuest,
                kind: .close,
                sessionID: transport.sessionID,
                sequence: sequence,
                payload: try encodePayload(
                    Close(sessionID: hello.sessionID, guestBootID: hello.guestBootID, reason: reason)))
            return try sign(frame, over: transport)
        }

        private var stateDescription: String {
            switch stateStorage {
            case .disabled:
                return "disabled"
            case .denied:
                return "denied"
            case .requiresAuthenticatedTransport:
                return "requires-authenticated-transport"
            case .awaitingReady:
                return "awaiting-ready"
            case .active:
                return "active"
            case .closed:
                return "closed"
            }
        }

        private func isAuthorizedRecord(
            _ record: Record,
            hello: Hello,
            expectedSequence: UInt64
        ) -> Bool {
            let header = record.header
            return header.contractVersion == Int64(version)
                && header.sessionID == hello.sessionID
                && header.guestBootID == hello.guestBootID
                && header.direction == .hostToGuest
                && header.sequence == expectedSequence
                && roots.contains(where: {
                    $0.rootID == header.rootID && $0.epoch == header.epoch
                })
        }
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        (UInt64(bytes[offset]) << 56)
            | (UInt64(bytes[offset + 1]) << 48)
            | (UInt64(bytes[offset + 2]) << 40)
            | (UInt64(bytes[offset + 3]) << 32)
            | (UInt64(bytes[offset + 4]) << 24)
            | (UInt64(bytes[offset + 5]) << 16)
            | (UInt64(bytes[offset + 6]) << 8)
            | UInt64(bytes[offset + 7])
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }

    private static func rootIdentifier(
        tag: String,
        rootPath: String,
        backingSharePath: String,
        readOnly: Bool
    ) throws -> String {
        var material = Data()
        material.append(contentsOf: tag.utf8)
        material.append(0)
        material.append(contentsOf: rootPath.utf8)
        material.append(0)
        material.append(contentsOf: backingSharePath.utf8)
        material.append(0)
        material.append(readOnly ? 1 : 0)
        let hex = SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
        let identifier = "root_" + String(hex.prefix(maximumRootIdentifierBytes - 5))
        guard isValidLabel(identifier) else {
            throw MorbError.protocolViolation("could not derive a valid share-sync root identifier")
        }
        return identifier
    }

    private static func isValidLabel(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumRootIdentifierBytes else { return false }
        return bytes.allSatisfy { byte in
            (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
                || byte == 45
                || byte == 95
        }
    }

    private static func isValidAbsolutePath(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard value != "/", value.hasPrefix("/"), !value.hasSuffix("/"),
              (2...maximumPathBytes).contains(bytes.count), !bytes.contains(0)
        else {
            return false
        }
        return value.dropFirst().split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            component in
            !component.isEmpty && component != "." && component != ".."
                && component.utf8.count <= 255
        }
    }

    private static func isStrictDescendant(_ path: String, of root: String) -> Bool {
        path.hasPrefix(root + "/")
    }

    private static func isEqualOrDescendant(_ path: String, of root: String) -> Bool {
        path == root || isStrictDescendant(path, of: root)
    }
}
