// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Foundation

/// Hostname derivation and validation for container domains under `morb.local`.
///
/// This type deliberately has no networking dependency. It does not inspect Docker,
/// register an mDNS record, bind a listener, or issue a certificate. It only validates
/// names, so the DIF-4 mDNS registrar (see `docs/design/DNS-DECISION.md`) can derive
/// exact `A`-record names without guessing at or lossy-normalizing user input.
///
/// The earlier host-loopback routing model that once lived beside this type
/// (`Claim`/`Registry`/`LocalDomainClaimReconciler`) was deleted when SP-2/SP-3 decided
/// against a host HTTP router; see `docs/design/INERT-SUBSYSTEMS-DECISION.md`.
public enum MorbLocalDomain {

    /// The requested developer-domain suffix. `.local` is the mDNS special-use suffix
    /// the decided mechanism registers under (proxy `A` records, `LocalOnly`).
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

    public enum ValidationError: Error, Equatable, Sendable, LocalizedError {
        case invalidSubdomain(String)
        case invalidHostname(String)
        case hostnameTooLong(String)

        public var errorDescription: String? {
            switch self {
            case .invalidSubdomain(let value):
                return "\(value) is not a valid ASCII subdomain below \(MorbLocalDomain.suffix)"
            case .invalidHostname(let value):
                return "\(value) is not a hostname below \(MorbLocalDomain.suffix)"
            case .hostnameTooLong(let value):
                return "\(value) exceeds the DNS hostname length limit"
            }
        }
    }
}
