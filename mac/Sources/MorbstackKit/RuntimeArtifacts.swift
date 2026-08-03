// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import CryptoKit
import Darwin
import Foundation
import Security

/// The immutable runtime payload shipped with a Morbstack release.
///
/// The daemon deliberately never downloads a kernel, initramfs, or Kubernetes payload
/// at launch. A signed app bundle carries a manifest plus the exact bytes it was built
/// with. Before those bytes become the managed runtime, this type validates the
/// app's signature and hashes every payload file against the signed manifest.
///
/// The installed layout is intentionally versioned:
///
/// ```text
/// ~/.morbstack/data/runtime/
///   current  -> 0.1.0-m0
///   previous -> 0.0.9
///   0.1.0-m0/{manifest.json,kernel/vmlinux,kernel/initrd.img,k8s/...}
/// ```
///
/// A release is copied into a private staging directory and renamed into place only
/// after it is complete and verified. Activation is a pair of atomic symlink swaps;
/// `previous` is written before `current`, so an interrupted update can never lose
/// the last runnable runtime.
public struct RuntimeArtifactManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public struct Artifact: Codable, Equatable, Sendable {
        /// Stable role, for example `kernel` or `kubernetes-k3s`.
        public let id: String
        /// A relative path below the version directory. Never accepted outside it.
        public let path: String
        /// Lowercase SHA-256 of the exact payload bytes.
        public let sha256: String
        /// Whether the installed file must have an executable mode.
        public let executable: Bool
        /// Whether a release cannot boot without this file.
        public let required: Bool

        public init(id: String, path: String, sha256: String, executable: Bool, required: Bool) {
            self.id = id
            self.path = path
            self.sha256 = sha256
            self.executable = executable
            self.required = required
        }

        enum CodingKeys: String, CodingKey {
            case id
            case path
            case sha256
            case executable
            case required
        }
    }

    public let schemaVersion: Int
    public let runtimeVersion: String
    public let artifacts: [Artifact]

    public init(schemaVersion: Int, runtimeVersion: String, artifacts: [Artifact]) {
        self.schemaVersion = schemaVersion
        self.runtimeVersion = runtimeVersion
        self.artifacts = artifacts
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case runtimeVersion = "runtime_version"
        case artifacts
    }

    /// Decodes and validates a manifest before any payload file is trusted.
    public static func load(from url: URL) throws -> RuntimeArtifactManifest {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw MorbError.notFound("could not read runtime manifest at \(url.path): \(error.localizedDescription)")
        }
        do {
            let manifest = try JSONDecoder().decode(RuntimeArtifactManifest.self, from: data)
            try manifest.validate()
            return manifest
        } catch let error as MorbError {
            throw error
        } catch {
            throw MorbError.config("runtime manifest at \(url.path) is invalid: \(error.localizedDescription)")
        }
    }

    /// Rejects ambiguous versions, paths and digests before using them as filesystem
    /// input. This is necessary even for a signed bundle because installed manifests
    /// live in a user-writable directory to support rollback.
    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw MorbError.unsupported(
                "runtime manifest schema \(schemaVersion) is unsupported (expected \(Self.currentSchemaVersion))")
        }
        guard Self.isSafePathComponent(runtimeVersion) else {
            throw MorbError.config("runtime manifest has an unsafe runtime version \(runtimeVersion.debugDescription)")
        }
        guard !artifacts.isEmpty else {
            throw MorbError.config("runtime manifest contains no artifacts")
        }

        var ids = Set<String>()
        var paths = Set<String>()
        for artifact in artifacts {
            guard Self.isSafePathComponent(artifact.id), ids.insert(artifact.id).inserted else {
                throw MorbError.config("runtime manifest has a duplicate or unsafe artifact id \(artifact.id.debugDescription)")
            }
            guard Self.isSafeRelativePath(artifact.path), paths.insert(artifact.path).inserted else {
                throw MorbError.config("runtime manifest has a duplicate or unsafe artifact path \(artifact.path.debugDescription)")
            }
            guard Self.isSHA256(artifact.sha256) else {
                throw MorbError.config("runtime manifest has an invalid SHA-256 for \(artifact.id)")
            }
        }
    }

    fileprivate static func isSafePathComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        return value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) ||  // 0-9
            ($0.value >= 65 && $0.value <= 90) ||  // A-Z
            ($0.value >= 97 && $0.value <= 122) || // a-z
            $0 == "-" || $0 == "_" || $0 == "."
        }
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/") else { return false }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            isSafePathComponent(String($0))
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
        }
    }
}

/// A validated runtime source inside a signed `.app` bundle.
public struct BundledRuntimeArtifacts: Sendable {
    public let appURL: URL
    public let resourceDirectory: URL
    public let manifestURL: URL
    public let manifest: RuntimeArtifactManifest

    public init(appURL: URL, resourceDirectory: URL, manifestURL: URL, manifest: RuntimeArtifactManifest) {
        self.appURL = appURL
        self.resourceDirectory = resourceDirectory
        self.manifestURL = manifestURL
        self.manifest = manifest
    }
}

/// Finds runtime resources beside the executable rather than relying on PATH or a
/// repository checkout. The same code works for MorbstackApp, morbstackd and morb,
/// which are all sibling executables in `Contents/MacOS`.
public enum RuntimeArtifactResolver {

    /// Returns the signed runtime carried by this app, or `nil` outside an app bundle.
    /// A malformed or unsigned adjacent bundle is an error, never a silent fallback to
    /// bytes sitting elsewhere on disk.
    public static func bundledRuntimeIfPresent() throws -> BundledRuntimeArtifacts? {
        let executable = URL(fileURLWithPath: MorbExecutable.currentPath()).resolvingSymlinksInPath()
        let macOSDirectory = executable.deletingLastPathComponent()
        guard macOSDirectory.lastPathComponent == "MacOS" else { return nil }
        let contents = macOSDirectory.deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents" else { return nil }
        let appURL = contents.deletingLastPathComponent()
        guard appURL.pathExtension == "app" else { return nil }

        let resourceDirectory = contents
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
        let manifestURL = resourceDirectory.appendingPathComponent("manifest.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }

        try validateCodeSignature(of: appURL)
        let manifest = try RuntimeArtifactManifest.load(from: manifestURL)
        return BundledRuntimeArtifacts(
            appURL: appURL,
            resourceDirectory: resourceDirectory,
            manifestURL: manifestURL,
            manifest: manifest)
    }

    /// CodeResources seals ordinary files under `Contents/Resources`. Checking the
    /// app root therefore validates both the manifest and the runtime payload as the
    /// release signer shipped them; the hash pass during installation independently
    /// validates the individual bytes before they are activated.
    private static func validateCodeSignature(of appURL: URL) throws {
        var staticCode: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(appURL as CFURL, SecCSFlags(), &staticCode)
        guard status == errSecSuccess, let staticCode else {
            throw MorbError.io("could not inspect the code signature of \(appURL.path) (status \(status))")
        }
        let valid = SecStaticCodeCheckValidity(staticCode, SecCSFlags(), nil)
        guard valid == errSecSuccess else {
            throw MorbError.io(
                "the Morbstack app bundle at \(appURL.path) failed code-signature validation "
                    + "(status \(valid)); refusing its runtime artifacts")
        }
    }
}

/// The result of atomically installing and activating one runtime release.
public struct RuntimeArtifactInstallation: Equatable, Sendable {
    public let version: String
    public let directory: URL
    public let wasAlreadyInstalled: Bool
    /// Whether an installed release under this same version carried different bytes
    /// and was superseded by the signed bundle's payload.
    public let wasReplaced: Bool

    public init(version: String, directory: URL, wasAlreadyInstalled: Bool, wasReplaced: Bool = false) {
        self.version = version
        self.directory = directory
        self.wasAlreadyInstalled = wasAlreadyInstalled
        self.wasReplaced = wasReplaced
    }
}

/// Installs signed bundle resources into Morbstack's mutable runtime data area.
public final class RuntimeArtifactStore {
    private let fileManager: FileManager
    private let directory: URL

    public init(
        directory: URL = MorbPaths.runtimeArtifactsDirectory,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Installs the current executable's signed runtime, when there is one.
    ///
    /// Development executables outside a bundle return `nil` and retain the legacy
    /// asset paths used by `scripts/fetch-guest-assets.sh`. A release bundle with a
    /// manifest must install successfully; callers get the validation failure instead
    /// of accidentally booting an older or unverified runtime.
    @discardableResult
    public static func installBundledRuntimeIfPresent() throws -> RuntimeArtifactInstallation? {
        guard let bundled = try RuntimeArtifactResolver.bundledRuntimeIfPresent() else { return nil }
        return try RuntimeArtifactStore().install(bundled)
    }

    /// Copies a complete release from a verified bundle into an immutable version
    /// directory, then changes `current` only after the new directory is complete.
    @discardableResult
    public func install(_ bundled: BundledRuntimeArtifacts) throws -> RuntimeArtifactInstallation {
        let manifest = bundled.manifest
        try manifest.validate()
        try ensureDirectory(directory)

        // Verify every source first. A source modified between this pass and copy is
        // caught by the equivalent staging verification below, before activation.
        try verify(manifest: manifest, in: bundled.resourceDirectory.appendingPathComponent(manifest.runtimeVersion))

        let destination = directory.appendingPathComponent(manifest.runtimeVersion, isDirectory: true)
        var alreadyInstalled = false
        var replaced = false
        // A release is identified by its bytes, never by its version string alone.
        // The installed manifest lives in a user-writable directory and is exactly
        // the file that a stale respin or a tampered runtime would also rewrite, so
        // it cannot be its own authority: agreement is measured against the signed
        // bundle's manifest. Without this, an installed 0.1.0-m0 stays frozen even
        // though the bundle now carries different bytes under that same version --
        // which silently boots a guest image nobody built.
        let existed = fileManager.fileExists(atPath: destination.path)
        if existed, (try? verify(manifest: manifest, in: destination)) != nil {
            alreadyInstalled = true
        } else {
            replaced = existed
            let staging = directory.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
            defer { try? fileManager.removeItem(at: staging) }
            try fileManager.createDirectory(
                at: staging,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])

            for artifact in manifest.artifacts {
                let source = bundled.resourceDirectory
                    .appendingPathComponent(manifest.runtimeVersion, isDirectory: true)
                    .appendingPathComponent(artifact.path, isDirectory: false)
                let installed = staging.appendingPathComponent(artifact.path, isDirectory: false)
                try ensureDirectory(installed.deletingLastPathComponent())
                try fileManager.copyItem(at: source, to: installed)
                try fileManager.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(artifact.executable ? 0o755 : 0o644))],
                    ofItemAtPath: installed.path)
            }
            // Persist the manifest we already decoded and validated, rather than a
            // second read of a mutable bundle file after the signature check above.
            try write(manifest: manifest, to: staging.appendingPathComponent("manifest.json"))
            try verifyInstalledRelease(at: staging, expectedVersion: manifest.runtimeVersion)

            if replaced {
                // Both directories exist, so supersede the stale payload with a single
                // atomic exchange: `current` never observes a missing version directory,
                // and the superseded release is discarded only after the swap succeeds.
                guard renamex_np(staging.path, destination.path, UInt32(RENAME_SWAP)) == 0 else {
                    let code = errno
                    throw MorbError.io(
                        "could not replace runtime \(manifest.runtimeVersion): \(String(cString: strerror(code)))")
                }
                try? fileManager.removeItem(at: staging)
                try activate(version: manifest.runtimeVersion)
                return RuntimeArtifactInstallation(
                    version: manifest.runtimeVersion,
                    directory: destination,
                    wasAlreadyInstalled: false,
                    wasReplaced: true)
            }
            do {
                // Staging and destination share `directory`, so this is an atomic
                // rename rather than a cross-volume copy.
                try fileManager.moveItem(at: staging, to: destination)
            } catch {
                // Another Morbstack process may have installed this exact immutable
                // release while this one was copying. Trust it only after rechecking.
                guard fileManager.fileExists(atPath: destination.path) else {
                    throw MorbError.io(
                        "could not install runtime \(manifest.runtimeVersion): \(error.localizedDescription)")
                }
                try verifyInstalledRelease(at: destination, expectedVersion: manifest.runtimeVersion)
                alreadyInstalled = true
            }
        }

        try activate(version: manifest.runtimeVersion)
        return RuntimeArtifactInstallation(
            version: manifest.runtimeVersion, directory: destination, wasAlreadyInstalled: alreadyInstalled)
    }

    /// Makes `previous` current again. This is intentionally a service primitive;
    /// policy/UI can expose it later without inventing a second filesystem protocol.
    @discardableResult
    public func rollback() throws -> RuntimeArtifactInstallation {
        guard let previous = symlinkTarget(named: "previous") else {
            throw MorbError.notFound("there is no previous Morbstack runtime to roll back to")
        }
        let previousDirectory = directory.appendingPathComponent(previous, isDirectory: true)
        try verifyInstalledRelease(at: previousDirectory, expectedVersion: previous)
        let current = symlinkTarget(named: "current")
        if let current {
            let currentDirectory = directory.appendingPathComponent(current, isDirectory: true)
            try verifyInstalledRelease(at: currentDirectory, expectedVersion: current)
            try replaceSymlink(named: "previous", destination: current)
        }
        try replaceSymlink(named: "current", destination: previous)
        return RuntimeArtifactInstallation(version: previous, directory: previousDirectory, wasAlreadyInstalled: true)
    }

    private func verifyInstalledRelease(at release: URL, expectedVersion: String) throws {
        let manifest = try RuntimeArtifactManifest.load(from: release.appendingPathComponent("manifest.json"))
        guard manifest.runtimeVersion == expectedVersion else {
            throw MorbError.config(
                "runtime directory \(release.path) contains manifest version \(manifest.runtimeVersion), "
                    + "not \(expectedVersion)")
        }
        try verify(manifest: manifest, in: release)
    }

    private func verify(manifest: RuntimeArtifactManifest, in root: URL) throws {
        for artifact in manifest.artifacts {
            let file = root.appendingPathComponent(artifact.path, isDirectory: false)
            let values: URLResourceValues
            do {
                values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            } catch {
                throw MorbError.notFound("runtime artifact \(artifact.id) is missing at \(file.path)")
            }
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw MorbError.io("runtime artifact \(artifact.id) at \(file.path) is not a regular file")
            }
            let digest = try sha256(of: file)
            guard digest == artifact.sha256 else {
                throw MorbError.io(
                    "runtime artifact \(artifact.id) at \(file.path) failed SHA-256 validation "
                        + "(got \(digest), expected \(artifact.sha256))")
            }
        }
    }

    private func activate(version: String) throws {
        if symlinkTarget(named: "current") == version { return }
        if let current = symlinkTarget(named: "current") {
            try replaceSymlink(named: "previous", destination: current)
        }
        try replaceSymlink(named: "current", destination: version)
    }

    /// Reads only a single safe relative directory name. Invalid symlinks are ignored
    /// rather than ever becoming a source for a write outside the runtime root.
    private func symlinkTarget(named name: String) -> String? {
        let link = directory.appendingPathComponent(name, isDirectory: false)
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: link.path),
              RuntimeArtifactManifest.isSafePathComponent(target)
        else { return nil }
        return target
    }

    private func replaceSymlink(named name: String, destination: String) throws {
        guard RuntimeArtifactManifest.isSafePathComponent(name),
              RuntimeArtifactManifest.isSafePathComponent(destination)
        else {
            throw MorbError.config("refusing unsafe runtime symlink update")
        }
        let temporary = directory.appendingPathComponent(".\(name)-\(UUID().uuidString)")
        let final = directory.appendingPathComponent(name)
        try fileManager.createSymbolicLink(atPath: temporary.path, withDestinationPath: destination)
        if Darwin.rename(temporary.path, final.path) != 0 {
            let code = errno
            try? fileManager.removeItem(at: temporary)
            throw MorbError.io("could not activate runtime \(destination): \(String(cString: strerror(code)))")
        }
    }

    private func ensureDirectory(_ url: URL) throws {
        do {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: url.path)
        } catch {
            throw MorbError.io("could not create runtime directory \(url.path): \(error.localizedDescription)")
        }
    }

    private func write(manifest: RuntimeArtifactManifest, to url: URL) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(manifest).write(to: url, options: .atomic)
        } catch {
            throw MorbError.io("could not write installed runtime manifest at \(url.path): \(error.localizedDescription)")
        }
    }

    private func sha256(of url: URL) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw MorbError.io("could not open runtime artifact at \(url.path)")
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
