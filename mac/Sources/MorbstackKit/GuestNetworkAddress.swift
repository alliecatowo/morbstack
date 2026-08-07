// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// UX-15: the guest VM's own address on the `vmnet`-managed NAT segment. DIF-4 step 0
// (`docs/design/DNS-DECISION.md`) proved, on this host, that the Mac can reach that
// address at the network layer: ICMP echo and TCP SYN both round-trip to the guest
// kernel over `bridge100`/`vmenet0`, and an unleased address on the same segment times
// out instead — the response is coming from the live guest, not from a NAT device
// answering on its behalf. Docker's own userland-proxy already binds every published
// port on the guest's real interface (`0.0.0.0`, not loopback — see
// `guest/morbinit/src/proxy_wrapper.rs` and its `-host-ip 0.0.0.0` contract), so once
// this address is known, every already-published port is reachable at
// `<address>:<hostPort>` from the Mac with no additional guest or engine work. This
// file only has to answer one question: what is that address right now.

import Foundation

/// The guest's current address on the NAT segment, and how long macOS granted it.
public struct GuestNetworkAddress: Equatable, Sendable {
    /// Dotted-quad IPv4 address, e.g. `192.168.64.27`. `vmnet` hands out IPv4 only;
    /// there is no guest-reachable IPv6 story to report here.
    public let ipv4: String
    /// When the DHCP lease macOS granted this address expires, if the lease record
    /// carried a value morbstackd could parse.
    public let leaseExpiry: Date?

    public init(ipv4: String, leaseExpiry: Date?) {
        self.ipv4 = ipv4
        self.leaseExpiry = leaseExpiry
    }
}

/// Resolves ``GuestNetworkAddress`` by reading the lease file macOS's `vmnet`
/// framework maintains for every VM it hands an address to, filtered to the MAC
/// Morbstack pins for its own guest NIC (``VMManager/guestMACAddress``).
///
/// This is deliberately *not* asked of the guest itself over vsock: the whole point is
/// a host-side fact ("what address would a Mac process use to reach the guest"), and
/// the lease file is authoritative for that regardless of what the guest believes its
/// own address is.
public enum GuestNetworkAddressLookup {

    /// Where `vmnet`'s DHCP server records leases. Shared across every `vmnet`
    /// consumer on the Mac — other virtualization software included — so callers must
    /// always filter by MAC and never assume every entry belongs to Morbstack.
    public static let leasesFilePath = "/var/db/dhcpd_leases"

    /// Refuses to read a lease file larger than this. Root-owned and world-readable
    /// only (`-rw-r--r-- root wheel`) on a normal install, and bounded in practice to
    /// one `/24` of entries at a few hundred bytes each — but `status` is on the
    /// control-socket hot path, and a read with no upper bound is exactly the shape
    /// CLAUDE.md's read discipline forbids, file-backed or not.
    public static let maxFileBytes = 1 << 20  // 1 MiB

    /// Reads the system lease file and returns the guest's current address, if the
    /// file exists, is within the size bound, decodes as UTF-8, and contains at least
    /// one entry for `macAddress`.
    ///
    /// Not `public`: the default `macAddress` value names `VMManager.guestMACAddress`,
    /// which is `internal`, and a default argument value can be no more restrictive
    /// than the declaration it belongs to. Every caller today (`Daemon.swift`) is in
    /// this module, so `internal` costs nothing; if a future caller outside
    /// `MorbstackKit` needs this, it should call it with an explicit `macAddress`
    /// rather than the pinned default, since only `MorbstackKit` knows the pinned MAC.
    static func currentAddress(
        macAddress: String = VMManager.guestMACAddress,
        leasesFilePath: String = GuestNetworkAddressLookup.leasesFilePath
    ) -> GuestNetworkAddress? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: leasesFilePath),
            let size = attributes[.size] as? Int, size <= maxFileBytes
        else { return nil }
        guard let data = FileManager.default.contents(atPath: leasesFilePath) else { return nil }
        guard data.count <= maxFileBytes, let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return parse(text, macAddress: macAddress)
    }

    /// Pure parser for macOS's `dhcpd_leases(5)` brace-delimited text format, matched
    /// on `hw_address`. Internal (not `private`) so `GuestNetworkAddressLookupTests`
    /// can drive it directly with fixture text instead of the real system file.
    ///
    /// macOS writes MAC octets without leading zeros (`2:4d:52:42:0:1`, not
    /// `02:4d:52:42:00:01`), so comparison normalizes both sides. When more than one
    /// entry matches the target MAC — a guest that has held different addresses over
    /// its lifetime, all still present in the file — the entry with the numerically
    /// greatest `lease=` epoch (the newest grant) wins.
    static func parse(_ contents: String, macAddress: String) -> GuestNetworkAddress? {
        guard let targetMAC = normalizeMAC(macAddress) else { return nil }

        var best: (ip: String, lease: UInt32)?

        var currentIP: String?
        var currentMACMatches = false
        var currentLease: UInt32?

        // A well-formed file has well under 254 entries (one `/24`). This caps how
        // many `{ ... }` records are honored so a corrupted or hostile-length file
        // cannot make a `status` call do unbounded work.
        let maxEntries = 4096
        var entriesSeen = 0

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line == "{" {
                guard entriesSeen < maxEntries else { break }
                entriesSeen += 1
                currentIP = nil
                currentMACMatches = false
                currentLease = nil
                continue
            }
            if line == "}" {
                if currentMACMatches, let ip = currentIP {
                    let lease = currentLease ?? 0
                    if best == nil || lease > best!.lease {
                        best = (ip, lease)
                    }
                }
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq]
            let value = line[line.index(after: eq)...]

            switch key {
            case "ip_address":
                currentIP = String(value)
            case "hw_address":
                // Form: "1,2:4d:52:42:0:1" — a link-layer-type byte, a comma, the MAC.
                if let comma = value.firstIndex(of: ",") {
                    let mac = String(value[value.index(after: comma)...])
                    if normalizeMAC(mac) == targetMAC { currentMACMatches = true }
                }
            case "lease":
                // Form: "0x6a74c4bc" — a hex Unix epoch. `UInt32(_:radix:)` returns
                // `nil` rather than trapping on anything out of range or malformed.
                let hex = value.hasPrefix("0x") ? value.dropFirst(2) : value[...]
                currentLease = UInt32(hex, radix: 16)
            default:
                break
            }
        }

        guard let winner = best else { return nil }
        let expiry = winner.lease > 0 ? Date(timeIntervalSince1970: TimeInterval(winner.lease)) : nil
        return GuestNetworkAddress(ipv4: winner.ip, leaseExpiry: expiry)
    }

    /// Normalizes a MAC address to lowercase, zero-padded two-digit octets so
    /// `2:4d:52:42:0:1` and `02:4d:52:42:00:01` compare equal. `nil` for anything that
    /// is not exactly six colon-separated hex octets.
    static func normalizeMAC(_ raw: String) -> String? {
        let octets = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard octets.count == 6 else { return nil }
        var normalized: [String] = []
        normalized.reserveCapacity(6)
        for octet in octets {
            guard octet.count <= 2, let value = UInt8(octet, radix: 16) else { return nil }
            normalized.append(String(format: "%02x", value))
        }
        return normalized.joined(separator: ":")
    }
}
