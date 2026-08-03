// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import CryptoKit
import Foundation

/// The one host-side Kubernetes helper the daemon-owned selected-Pod port-forward
/// boundary may use.
///
/// This is deliberately a packaging and provenance boundary, not a port-forward
/// implementation. `morb k8s port-forward start` reaches it only through the
/// coordinator, which calls ``bundledKubectl()`` before it creates a listener or a
/// temporary credential file. The resolver admits only the exact, hash-pinned file
/// carried by this app (or the equivalent checked-out build input); it never searches
/// `PATH`, accepts a user's `kubectl`, or discovers a kubeconfig.
public enum MorbKubernetesKubectl {
    /// Kubernetes client version chosen to match Morbstack's current k3s minor.
    public static let version = "v1.36.2"

    /// SHA-256 published beside the exact Darwin arm64 release artifact.
    public static let expectedSHA256 = "4408c85c83fd3a31adaa555bdf3c7a6c81f74b19449a9060ba31ab91926f023d"

    /// Private bundle location. It is intentionally outside Docker's plugin
    /// directory, so first-run Docker setup can neither install nor expose it.
    public static let relativePath = "kubernetes/kubectl"

    /// Finds and verifies Morbstack's private `kubectl` helper.
    ///
    /// A missing artifact is an explicit unavailable state. It must never be
    /// papered over with a user-installed binary, `PATH`, `KUBECONFIG`, or
    /// `~/.kube/config` fallback.
    public static func bundledKubectl() throws -> URL {
        for hostBin in MorbCliPlugins.candidateHostBinDirectories() {
            let candidate = hostBin.appendingPathComponent(relativePath, isDirectory: false)
            var isDirectory: ObjCBool = false
            let fileManager = FileManager.default
            let exists = fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
            let isSymbolicLink = (try? fileManager.destinationOfSymbolicLink(atPath: candidate.path)) != nil
            guard exists || isSymbolicLink else {
                continue
            }
            guard !isSymbolicLink else {
                throw MorbError.config(unavailable("is a symbolic link"))
            }
            guard !isDirectory.boolValue else {
                throw MorbError.config(unavailable("is a directory, not an executable file"))
            }
            let values: URLResourceValues
            do {
                values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            } catch {
                throw MorbError.io(unavailable("could not be inspected: \(error.localizedDescription)"))
            }
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  fileManager.isExecutableFile(atPath: candidate.path)
            else {
                throw MorbError.config(unavailable("is not an executable regular file"))
            }
            let digest: String
            do {
                digest = try sha256(of: candidate)
            } catch {
                throw MorbError.io(unavailable("could not be SHA-256 verified: \(error.localizedDescription)"))
            }
            guard digest == expectedSHA256 else {
                throw MorbError.io(
                    unavailable("failed SHA-256 verification (got \(digest), expected \(expectedSHA256))"))
            }
            return candidate
        }
        throw MorbError.notFound(
            unavailable("is not packaged in this build; no user-installed kubectl or kubeconfig will be used"))
    }

    private static func unavailable(_ reason: String) -> String {
        "Kubernetes selected-Pod port forwarding is unavailable because Morbstack's bundled kubectl \(version) \(reason)."
    }

    private static func sha256(of url: URL) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw MorbError.io("could not open bundled kubectl at \(url.path)")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
