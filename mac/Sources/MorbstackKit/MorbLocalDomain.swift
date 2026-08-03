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

        /// The only permitted eventual target. The active router must still re-check
        /// that PortForwarder owns this exact publication before connecting.
        public var loopbackTarget: String { "127.0.0.1:\(targetPort)" }
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
