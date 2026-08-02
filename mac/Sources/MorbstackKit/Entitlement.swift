// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Foundation
import MachO
import Security

/// Code-signing entitlement inspection.
///
/// Creating a `VZVirtualMachine` without `com.apple.security.virtualization` does not
/// throw: the process is killed by the kernel with `EXC_CRASH (SIGKILL) — Code
/// Signature Invalid`. From the user's side that looks like "the daemon vanished and
/// there is nothing in the log", which is one of the worst first-run experiences we
/// could ship. So both `morbstackd` and `morb doctor` check the entitlement *before*
/// anything touches Virtualization.framework, and say `make sign` out loud.
public enum MorbEntitlements {

    /// The entitlement Virtualization.framework requires for Linux VMs.
    public static let virtualization = "com.apple.security.virtualization"

    /// The remedy printed whenever the entitlement is missing.
    public static let signHint =
        "run `make sign` (codesign --force --sign - "
        + "--entitlements mac/Resources/morbstackd.entitlements <path-to-morbstackd>)"

    /// Whether the *current process* carries `com.apple.security.virtualization`.
    ///
    /// Uses `SecTaskCreateFromSelf`, which reads the entitlements the kernel actually
    /// granted this task — not what the on-disk signature claims.
    public static func currentProcessHasVirtualization() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        var error: Unmanaged<CFError>?
        let value = SecTaskCopyValueForEntitlement(task, virtualization as CFString, &error)
        error?.release()
        // CFBoolean bridges to NSNumber, so this covers both `<true/>` and `1`.
        guard let number = value as? NSNumber else { return false }
        return number.boolValue
    }

    /// Whether the signed binary at `path` carries `com.apple.security.virtualization`.
    ///
    /// Used by `morb` before it auto-spawns a sibling `morbstackd`, and by
    /// ``Doctor`` so the report can point at the exact binary that needs signing.
    /// An unsigned or unreadable binary answers `false`.
    public static func binaryHasVirtualization(at path: String) -> Bool {
        guard let entitlements = entitlements(ofBinaryAt: path) else { return false }
        if let flag = entitlements[virtualization] as? Bool { return flag }
        if let number = entitlements[virtualization] as? NSNumber { return number.boolValue }
        return false
    }

    /// Reads the entitlement dictionary embedded in the signature of `path`.
    ///
    /// - Returns: `nil` when the file does not exist, is not signed, or the signature
    ///   cannot be read.
    public static func entitlements(ofBinaryAt path: String) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        var staticCode: SecStaticCode?
        let url = URL(fileURLWithPath: path) as CFURL
        guard SecStaticCodeCreateWithPath(url, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }

        // kSecCSRequirementInformation is the flag that makes the entitlement
        // dictionary appear in the returned info; without it the key is absent.
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any]
        else { return nil }

        return dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
    }
}

/// Locating the binaries that make up an installed Morbstack.
///
/// `morb` and `morbstackd` are built and shipped side by side, so "the daemon" is
/// simply the sibling of whichever executable is currently running.
public enum MorbExecutable {

    /// The absolute path of the running executable, resolved through symlinks.
    public static func currentPath() -> String {
        var size = UInt32(4096)
        var buffer = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buffer, &size) != 0 {
            buffer = [CChar](repeating: 0, count: Int(size))
            guard _NSGetExecutablePath(&buffer, &size) == 0 else {
                return CommandLine.arguments.first ?? ""
            }
        }
        let raw = String(cString: buffer)
        return URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
    }

    /// The directory holding the running executable.
    public static func currentDirectory() -> URL {
        URL(fileURLWithPath: currentPath()).deletingLastPathComponent()
    }

    /// The sibling `morbstackd`, when one exists next to the running executable.
    public static func siblingDaemonURL() -> URL? {
        let candidate = currentDirectory().appendingPathComponent("morbstackd")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else { return nil }
        return candidate
    }
}
