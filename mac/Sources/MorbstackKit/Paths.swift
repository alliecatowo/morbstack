// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Foundation

/// The error type used throughout MorbstackKit.
///
/// Cases are intentionally coarse: the associated `String` is a human-readable
/// message that is safe to print directly to a terminal or return over the
/// control socket.
public enum MorbError: Error, CustomStringConvertible, LocalizedError {
    /// A filesystem or socket level failure.
    case io(String)
    /// The on-disk configuration could not be parsed or is out of range.
    case config(String)
    /// The Virtualization framework refused an operation.
    case vm(String)
    /// A framing or encoding violation on one of the wire protocols.
    case protocolViolation(String)
    /// An operation did not complete within its deadline.
    case timeout(String)
    /// The host or the current build cannot do what was asked.
    case unsupported(String)
    /// A required file or resource is absent.
    case notFound(String)

    public var description: String {
        switch self {
        case .io(let m): return m
        case .config(let m): return m
        case .vm(let m): return m
        case .protocolViolation(let m): return m
        case .timeout(let m): return m
        case .unsupported(let m): return m
        case .notFound(let m): return m
        }
    }

    public var errorDescription: String? { description }
}

/// Well-known on-disk locations for the Morbstack runtime.
///
/// Everything lives under `~/.morbstack`. The root can be redirected with the
/// `MORBSTACK_HOME` environment variable, which is used by the test-suite and by
/// developers who want to run a throwaway stack side-by-side with a real one.
public struct MorbPaths {

    /// The Morbstack root directory (`~/.morbstack` unless overridden).
    public static var root: URL {
        if let override = ProcessInfo.processInfo.environment["MORBSTACK_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".morbstack", isDirectory: true)
    }

    /// `~/.morbstack/config.toml`
    public static var configFile: URL { root.appendingPathComponent("config.toml", isDirectory: false) }

    /// `~/.morbstack/run` — holds the two unix-domain sockets.
    public static var runDirectory: URL { root.appendingPathComponent("run", isDirectory: true) }

    /// `~/.morbstack/run/docker.sock` — the Docker Engine API relay endpoint.
    public static var dockerSocket: URL { runDirectory.appendingPathComponent("docker.sock", isDirectory: false) }

    /// `~/.morbstack/run/morbstackd.sock` — the daemon control endpoint used by `morb`.
    public static var controlSocket: URL { runDirectory.appendingPathComponent("morbstackd.sock", isDirectory: false) }

    /// `~/.morbstack/run/morbstackd.lock` — the single-instance `flock(2)` file.
    ///
    /// Never unlinked: the lock lives on the open file description, so the kernel
    /// releases it when the daemon exits or crashes, and keeping one stable inode is
    /// what makes two racing daemons contend for the *same* lock.
    public static var lockFile: URL { runDirectory.appendingPathComponent("morbstackd.lock", isDirectory: false) }

    /// `~/.morbstack/data` — persistent VM state.
    public static var dataDirectory: URL { root.appendingPathComponent("data", isDirectory: true) }

    /// `~/.morbstack/data/debug-toolbox` — reserved for an explicitly acquired,
    /// verified debug-toolbox asset and its receipt. Merely reading this location must
    /// never create it, pull an image, or contact Docker; that keeps `morb debug check`
    /// a safe offline diagnostic while the executor remains unavailable.
    public static var debugToolboxDirectory: URL {
        dataDirectory.appendingPathComponent("debug-toolbox", isDirectory: true)
    }

    /// `~/.morbstack/data/debug-toolbox/asset-manifest.json` — the local, declarative
    /// asset descriptor. A manifest at this path is not trusted merely because it is
    /// present; `DebugToolboxAsset` validates its schema, then a future verifier must
    /// prove the local image and provenance bundle before an executor can use it.
    public static var debugToolboxManifest: URL {
        debugToolboxDirectory.appendingPathComponent("asset-manifest.json", isDirectory: false)
    }

    /// `~/.morbstack/data/runtime` — immutable, versioned release runtime payloads.
    ///
    /// A signed app bundle is copied here before it becomes active. `current` and
    /// `previous` below are relative symlinks into this directory, so a release can
    /// move the kernel/initramfs as one coherent unit and still roll back safely.
    public static var runtimeArtifactsDirectory: URL {
        dataDirectory.appendingPathComponent("runtime", isDirectory: true)
    }

    /// `~/.morbstack/data/runtime/current` — active versioned runtime release.
    public static var currentRuntimeDirectory: URL {
        runtimeArtifactsDirectory.appendingPathComponent("current", isDirectory: true)
    }

    /// `~/.morbstack/data/runtime/previous` — the release available for rollback.
    public static var previousRuntimeDirectory: URL {
        runtimeArtifactsDirectory.appendingPathComponent("previous", isDirectory: true)
    }

    /// `~/.morbstack/data/disk.img` — the sparse raw root disk.
    public static var diskImage: URL { dataDirectory.appendingPathComponent("disk.img", isDirectory: false) }

    /// `~/.morbstack/data/vmstate.bin` — Virtualization.framework save/restore blob.
    public static var vmState: URL { dataDirectory.appendingPathComponent("vmstate.bin", isDirectory: false) }

    /// `~/.morbstack/data/background-service-receipt.json` — records which signed
    /// app payload was last registered with Service Management. It lets an explicit
    /// `morb service enable` re-register a changed helper after an app update without
    /// restarting an already-current service on every invocation.
    public static var backgroundServiceReceipt: URL {
        dataDirectory.appendingPathComponent("background-service-receipt.json", isDirectory: false)
    }

    /// `~/.morbstack/data/save-restore-unsupported` — written when a restore has failed.
    ///
    /// Virtualization.framework accepts `saveMachineStateTo` for a direct-kernel
    /// (`VZLinuxBootLoader`) guest and then refuses to restore the result, and
    /// `validateSaveRestoreSupport()` does not predict it. The only way to know is to
    /// try, so the answer is remembered here rather than rediscovered — at the cost of
    /// a slow shutdown and a wasted 150 MB — on every single daemon restart.
    /// Delete this file to make Morbstack try suspend-to-disk again.
    public static var saveRestoreUnsupported: URL {
        dataDirectory.appendingPathComponent("save-restore-unsupported", isDirectory: false)
    }

    /// `~/.morbstack/data/kernel` — legacy development asset location used by
    /// `scripts/fetch-kernel.sh`. Release bundles use ``runtimeArtifactsDirectory``.
    public static var kernelDirectory: URL { dataDirectory.appendingPathComponent("kernel", isDirectory: true) }

    /// The uncompressed guest kernel image.
    ///
    /// Prefer the digest-checked release under `runtime/current`; retain the legacy
    /// fetch-script location for source checkouts and explicit developer workflows.
    public static var kernel: URL {
        let managed = currentRuntimeDirectory
            .appendingPathComponent("kernel", isDirectory: true)
            .appendingPathComponent("vmlinux", isDirectory: false)
        return FileManager.default.isReadableFile(atPath: managed.path)
            ? managed
            : kernelDirectory.appendingPathComponent("vmlinux", isDirectory: false)
    }

    /// The gzipped newc cpio initramfs holding `morbinit` and the Docker binaries.
    public static var initrd: URL {
        let managed = currentRuntimeDirectory
            .appendingPathComponent("kernel", isDirectory: true)
            .appendingPathComponent("initrd.img", isDirectory: false)
        return FileManager.default.isReadableFile(atPath: managed.path)
            ? managed
            : kernelDirectory.appendingPathComponent("initrd.img", isDirectory: false)
    }

    /// `~/.morbstack/data/k8s` — the Kubernetes payload the daemon streams into the
    /// guest on `morb k8s enable`, put there by
    /// `scripts/fetch-guest-assets.sh --k8s-only`.
    ///
    /// Alongside the kernel rather than inside the guest image on purpose: the two
    /// binaries are 122 MB and Kubernetes is off by default, so baking them into the
    /// initramfs would spend that much guest RAM on every boot for a feature nobody
    /// asked for. Absent on a machine that never fetched them, which is exactly the
    /// state `morb k8s status` reports as `not-installed`.
    public static var k8sPayloadDirectory: URL {
        let managed = currentRuntimeDirectory.appendingPathComponent("k8s", isDirectory: true)
        return FileManager.default.fileExists(atPath: managed.path)
            ? managed
            : dataDirectory.appendingPathComponent("k8s", isDirectory: true)
    }

    /// `~/.morbstack/kubeconfig` — where Morbstack writes the cluster's kubeconfig.
    ///
    /// Deliberately *not* `~/.kube/config`. Rewriting a file that other clusters,
    /// other tools and other people's scripts all depend on is not something a
    /// `enable` should do behind the user's back; `morb k8s kubeconfig --merge` does
    /// it on request, after confirmation, and after taking a backup.
    public static var kubeconfig: URL { root.appendingPathComponent("kubeconfig", isDirectory: false) }

    /// `~/.kube/config` — the user's own kubeconfig. Only ever read, backed up, and
    /// written by an explicit `morb k8s kubeconfig --merge`.
    public static var userKubeconfig: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kube", isDirectory: true)
            .appendingPathComponent("config", isDirectory: false)
    }

    /// `~/.morbstack/logs`
    public static var logsDirectory: URL { root.appendingPathComponent("logs", isDirectory: true) }

    /// `~/.morbstack/logs/console.log` — raw guest serial console output.
    public static var consoleLog: URL { logsDirectory.appendingPathComponent("console.log", isDirectory: false) }

    /// `~/.morbstack/logs/daemon.log` — structured daemon log.
    public static var daemonLog: URL { logsDirectory.appendingPathComponent("daemon.log", isDirectory: false) }

    /// Creates the full directory tree with owner-only permissions.
    ///
    /// Safe to call repeatedly; existing directories are left untouched apart from
    /// a permission refresh, which guards against a previously over-permissive run.
    public static func ensureDirectories() throws {
        let fm = FileManager.default
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: NSNumber(value: Int16(0o700))]
        for directory in [
            root, runDirectory, dataDirectory, runtimeArtifactsDirectory, kernelDirectory, logsDirectory,
        ] {
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
                try fm.setAttributes(attributes, ofItemAtPath: directory.path)
            } catch {
                throw MorbError.io("could not create \(directory.path): \(error.localizedDescription)")
            }
        }
    }
}
