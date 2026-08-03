// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Foundation

/// A pure, inactive registry for future `*.morb.local` HTTP routing.
///
/// This type deliberately has no networking dependency. It does not inspect Docker,
/// bind a listener, resolve a hostname, write a macOS DNS setting, or issue a
/// certificate. It only validates a small, unambiguous claim that a future daemon-owned
/// reconciler may publish after it has proved that the target is a currently reachable
/// loopback TCP publication. See `docs/domains.md` for the activation prerequisites.
public enum MorbLocalDomain {

    /// The requested developer-domain suffix. `.local` is an mDNS special-use suffix,
    /// so this constant is a naming contract, not evidence that macOS can resolve it.
    public static let suffix = "morb.local"

    /// One validated hostname below ``suffix``.
    public struct Name: Hashable, Sendable, CustomStringConvertible {

        public let labels: [String]

        /// Validates an ASCII DNS subdomain such as `api.todo` and appends
        /// ``MorbLocalDomain/suffix``. Unicode, wildcards, empty labels, IP literals,
        /// and labels that could not be used unchanged in an HTTP `Host` value are
        /// rejected rather than guessed at or lossy-normalized.
        public init(subdomain: String) throws {
            let candidate = subdomain.lowercased()
            let labels = candidate.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !labels.isEmpty, labels.allSatisfy(Self.isValidLabel) else {
                throw ValidationError.invalidSubdomain(subdomain)
            }

            let hostname = labels.joined(separator: ".") + "." + MorbLocalDomain.suffix
            guard hostname.utf8.count <= 253 else {
                throw ValidationError.hostnameTooLong(hostname)
            }
            self.labels = labels
        }

        /// Parses an absolute developer hostname. A trailing DNS root dot is accepted;
        /// anything outside `*.morb.local` is rejected.
        public init(hostname: String) throws {
            let candidate = hostname.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let unrooted = candidate.hasSuffix(".") ? String(candidate.dropLast()) : candidate
            let parts = unrooted.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            let suffixParts = MorbLocalDomain.suffix.split(separator: ".").map(String.init)
            guard parts.count > suffixParts.count,
                  parts.suffix(suffixParts.count) == suffixParts
            else {
                throw ValidationError.invalidHostname(hostname)
            }
            try self.init(subdomain: parts.dropLast(suffixParts.count).joined(separator: "."))
        }

        public var hostname: String {
            labels.joined(separator: ".") + "." + MorbLocalDomain.suffix
        }

        public var description: String { hostname }

        private static func isValidLabel(_ label: String) -> Bool {
            let bytes = Array(label.utf8)
            guard (1...63).contains(bytes.count),
                  let first = bytes.first, let last = bytes.last,
                  isAlphaNumeric(first), isAlphaNumeric(last)
            else {
                return false
            }
            return bytes.allSatisfy { isAlphaNumeric($0) || $0 == 45 }
        }

        private static func isAlphaNumeric(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (97...122).contains(byte)
        }
    }

    /// A future HTTP router may use a claim only to reach this existing TCP publication
    /// on the same Mac. It must not treat this model as permission to publish a new
    /// Docker port or listen on a non-loopback address.
    public struct Claim: Hashable, Sendable, Identifiable {

        public let ownerID: String
        public let name: Name
        public let targetPort: UInt16

        public init(ownerID: String, subdomain: String, targetPort: Int) throws {
            let owner = ownerID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !owner.isEmpty, owner.utf8.count <= 128,
                  owner.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E })
            else {
                throw ValidationError.invalidOwner(ownerID)
            }
            guard (1...65_535).contains(targetPort) else {
                throw ValidationError.invalidTargetPort(targetPort)
            }

            self.ownerID = owner
            name = try Name(subdomain: subdomain)
            self.targetPort = UInt16(targetPort)
        }

        public var id: String { "\(ownerID)|\(name.hostname)|\(targetPort)" }

        /// The selected host TCP port of the only permitted eventual target. A future
        /// router must still re-check that PortForwarder owns this exact publication
        /// before connecting.
        public var loopbackTarget: String { "127.0.0.1:\(targetPort)" }
    }

    /// One concrete TCP listener that Morbstack owns on the Mac loopback interface.
    ///
    /// This is deliberately a small value type rather than a listener reference or a
    /// Docker response. A domain reconciler can prove only an exact owner and host
    /// port from one atomic daemon snapshot; it cannot use this model to bind, open,
    /// or route a connection.
    public struct LoopbackTCPForward: Hashable, Sendable {

        /// Immutable Docker container ID that owns the forwarded publication.
        public let ownerID: String
        /// The TCP port on `127.0.0.1` owned by Morbstack's forwarder.
        public let hostPort: UInt16

        public init(ownerID: String, hostPort: UInt16) {
            self.ownerID = ownerID
            self.hostPort = hostPort
        }
    }

    /// A single point-in-time view of the forwarder's TCP ownership.
    ///
    /// ``PortForwarder/localDomainForwardSnapshot`` builds this value while holding
    /// its state lock, so a caller cannot combine a listener from one forwarder
    /// generation with a failure or conflict from another. This snapshot has no
    /// listener handles and grants no permission to alter the forwarder.
    public struct LoopbackTCPForwardSnapshot: Sendable {

        /// `false` when the daemon has stopped the forwarder or has not started it.
        public let forwarderIsRunning: Bool
        /// TCP listeners currently active and owned by Morbstack on loopback.
        public let activeForwards: [LoopbackTCPForward]
        /// Ports Docker published but Morbstack could not bind.
        public let failedHostPorts: Set<UInt16>
        /// Ports Docker described with competing TCP targets.
        public let conflictingHostPorts: Set<UInt16>

        public init(
            forwarderIsRunning: Bool,
            activeForwards: [LoopbackTCPForward],
            failedHostPorts: Set<UInt16> = [],
            conflictingHostPorts: Set<UInt16> = []
        ) {
            self.forwarderIsRunning = forwarderIsRunning
            self.activeForwards = activeForwards
            self.failedHostPorts = failedHostPorts
            self.conflictingHostPorts = conflictingHostPorts
        }
    }

    /// Resolves only an exact hostname from one in-memory snapshot. Collisions are
    /// rejected at construction time so a later router never chooses a container based
    /// on event order.
    public struct Registry: Sendable {

        public let claims: [Claim]
        private let claimsByName: [Name: Claim]

        public init(claims: [Claim]) throws {
            var indexed: [Name: Claim] = [:]
            for claim in claims {
                if indexed[claim.name] != nil {
                    throw ValidationError.duplicateHostname(claim.name.hostname)
                }
                indexed[claim.name] = claim
            }
            claimsByName = indexed
            self.claims = claims.sorted { $0.name.hostname < $1.name.hostname }
        }

        /// Returns a claim only when `hostname` is an exact valid name in this snapshot.
        /// There is intentionally no wildcard, suffix, case-insensitive dictionary, or
        /// fallback behavior at this boundary.
        public func claim(for hostname: String) -> Claim? {
            guard let name = try? Name(hostname: hostname) else { return nil }
            return claimsByName[name]
        }
    }

    public enum ValidationError: Error, Equatable, Sendable, LocalizedError {
        case invalidSubdomain(String)
        case invalidHostname(String)
        case hostnameTooLong(String)
        case invalidOwner(String)
        case invalidTargetPort(Int)
        case duplicateHostname(String)

        public var errorDescription: String? {
            switch self {
            case .invalidSubdomain(let value):
                return "\(value) is not a valid ASCII subdomain below \(MorbLocalDomain.suffix)"
            case .invalidHostname(let value):
                return "\(value) is not a hostname below \(MorbLocalDomain.suffix)"
            case .hostnameTooLong(let value):
                return "\(value) exceeds the DNS hostname length limit"
            case .invalidOwner(let value):
                return "\(value) is not a valid domain-claim owner"
            case .invalidTargetPort(let value):
                return "\(value) is not a valid loopback TCP target port"
            case .duplicateHostname(let value):
                return "multiple containers claimed \(value)"
            }
        }
    }
}

/// Validates one explicitly opted-in prospective local-domain claim against fresh,
/// daemon-owned facts.
///
/// This is a pure reconciliation boundary. It does not retain a claim, talk to the
/// Engine, bind a socket, configure a resolver, produce a URL, issue TLS material, or
/// start a watcher. Until a future feature deliberately consumes a ``Result/validated(_:)``
/// result, all `*.morb.local` names remain unclaimed and inactive.
public enum LocalDomainClaimReconciler {

    /// A request made through an explicit product opt-in. The domain and TCP port are
    /// already exact because ``MorbLocalDomain/Claim`` validates both at construction.
    public struct Request: Hashable, Sendable {

        public let isExplicitlyOptedIn: Bool
        public let claim: MorbLocalDomain.Claim

        public init(isExplicitlyOptedIn: Bool, claim: MorbLocalDomain.Claim) {
            self.isExplicitlyOptedIn = isExplicitlyOptedIn
            self.claim = claim
        }
    }

    /// One owner from a fresh Engine `running`-container response.
    ///
    /// Engine callers must pass only containers whose current state is `running`.
    /// A stopped or deleted owner is consequently absent and can never be treated as
    /// a routable target by this model.
    public struct RunningContainerCandidate: Hashable, Sendable {

        public let ownerID: String

        public init(ownerID: String) {
            self.ownerID = ownerID
        }
    }

    /// Why a prospective claim is not validated. `rejected` is intentionally the
    /// default for incomplete or inconsistent facts: a future router must not infer
    /// availability from a name, label, or stale prior result.
    public enum Rejection: Hashable, Sendable {
        case explicitOptInRequired
        case forwarderStopped
        case ownerNotRunning
        case failedForward
        case conflictingForward
        case forwardMissing
        case forwardOwnerMismatch
        case ambiguousForward
    }

    /// The outcome for one independent reconciliation. `validated` only means the
    /// passed snapshots prove the existing loopback publication; it does not activate
    /// DNS, HTTP routing, HTTPS, or any user-visible domain feature.
    public enum Result: Hashable, Sendable {
        case validated(MorbLocalDomain.Claim)
        case rejected(Rejection)
    }

    /// Revalidates an exact opted-in domain claim from one fresh Engine list and one
    /// atomic PortForwarder snapshot.
    ///
    /// The selected host TCP port is denied whenever its forward is failed or
    /// conflicted, even if a stale active-forward entry also exists. The owner must
    /// appear in the current Engine `running` list and the one active listener for
    /// that port must name that same immutable owner ID.
    public static func reconcile(
        request: Request,
        runningContainers: [RunningContainerCandidate],
        forwards: MorbLocalDomain.LoopbackTCPForwardSnapshot
    ) -> Result {
        guard request.isExplicitlyOptedIn else {
            return .rejected(.explicitOptInRequired)
        }
        guard forwards.forwarderIsRunning else {
            return .rejected(.forwarderStopped)
        }

        let ownerIsRunning = runningContainers.contains { candidate in
            candidate.ownerID == request.claim.ownerID
        }
        guard ownerIsRunning else {
            return .rejected(.ownerNotRunning)
        }

        let port = request.claim.targetPort
        guard !forwards.failedHostPorts.contains(port) else {
            return .rejected(.failedForward)
        }
        guard !forwards.conflictingHostPorts.contains(port) else {
            return .rejected(.conflictingForward)
        }

        let candidates = forwards.activeForwards.filter { forward in
            forward.hostPort == port
        }
        guard candidates.count == 1 else {
            return .rejected(candidates.isEmpty ? .forwardMissing : .ambiguousForward)
        }
        guard candidates[0].ownerID == request.claim.ownerID else {
            return .rejected(.forwardOwnerMismatch)
        }
        return .validated(request.claim)
    }
}
