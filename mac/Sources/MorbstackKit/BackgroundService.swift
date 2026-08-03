// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Per-user background-service decision: docs/background-service.md records the
// primary Apple sources and why Morbstack uses an SMAppService LaunchAgent rather
// than a privileged LaunchDaemon. Do not replace this with a hand-written plist in
// ~/Library/LaunchAgents: SMAppService owns registration, user approval and status.

import CryptoKit
import Foundation
import ServiceManagement

/// Explicit control and diagnostics for Morbstack's per-user launch agent.
///
/// This type does not register a service during initialization, app launch, daemon
/// launch, or status inspection. Registration occurs only through ``enable()``,
/// which is deliberately exposed as an explicit user command. That maps directly to
/// Apple's `SMAppService` user-control model: background helpers appear in Login
/// Items and can be disabled there at any time.
public enum MorbBackgroundService {
    /// The launchd label, stable across app updates.
    public static let label = "dev.morbstack.daemon"
    /// The plist name passed to `SMAppService.agent(plistName:)`.
    public static let plistName = "\(label).plist"

    /// The registration/approval state macOS reports for the bundled LaunchAgent.
    public enum Registration: String, Codable, Equatable, Sendable {
        /// The current executable is not inside a complete app bundle.
        case unavailable
        /// The service has never been registered, or was explicitly disabled.
        case notRegistered = "not-registered"
        /// Registered and allowed to run by macOS.
        case enabled
        /// Registered, but the person must approve it in Login Items.
        case requiresApproval = "requires-approval"
        /// The framework cannot find the registered service.
        case notFound = "not-found"
        /// A future ServiceManagement status this build does not yet know.
        case unknown
    }

    /// The observed state of the daemon control socket when a caller explicitly
    /// requests a liveness probe.
    ///
    /// A LaunchAgent's registration tells us whether macOS may run it, not whether
    /// the currently installed daemon has bound its control socket. Keeping that
    /// distinction explicit makes a no-window service failure diagnosable without
    /// claiming that a socket pathname is a healthy daemon.
    public enum ControlSocketState: String, Codable, Equatable, Sendable {
        /// The caller requested registration-only status, so no connection was attempted.
        case notChecked = "not-checked"
        /// No filesystem entry exists at the expected control socket path.
        case missing
        /// A filesystem entry exists but did not accept a bounded connection.
        case unresponsive
        /// A listener accepted a bounded connection at the expected path.
        case responding
    }

    /// A self-contained report suitable for a CLI or a future native settings pane.
    public struct Status: Codable, Equatable, Sendable {
        public let registration: Registration
        /// The app-bundled plist path, if this executable is part of a complete app.
        public let plistPath: String?
        /// The daemon socket path owned by the per-user service.
        public let controlSocketPath: String
        /// Existence only — this never connects to or starts the daemon.
        public let controlSocketPresent: Bool
        /// Whether an explicitly requested, bounded liveness probe reached a listener.
        ///
        /// ``ControlSocketState/notChecked`` preserves status inspection's original
        /// registration-only behavior for callers such as first-run setup.
        public let controlSocketState: ControlSocketState
        /// An actionable explanation of the registration state.
        public let diagnostic: String

        public init(
            registration: Registration,
            plistPath: String?,
            controlSocketPath: String,
            controlSocketPresent: Bool,
            controlSocketState: ControlSocketState = .notChecked,
            diagnostic: String
        ) {
            self.registration = registration
            self.plistPath = plistPath
            self.controlSocketPath = controlSocketPath
            self.controlSocketPresent = controlSocketPresent
            self.controlSocketState = controlSocketState
            self.diagnostic = diagnostic
        }

        /// A conventional daemon-response payload for the dependency-free CLI.
        public var ipcFields: [String: AnyCodableValue] {
            [
                "registration": .string(registration.rawValue),
                "plist": plistPath.map(AnyCodableValue.string) ?? .null,
                "control_socket": .string(controlSocketPath),
                "control_socket_present": .bool(controlSocketPresent),
                "control_socket_state": .string(controlSocketState.rawValue),
                "diagnostic": .string(diagnostic),
            ]
        }
    }

    /// Inspects the service without registering it or launching it.
    ///
    /// The default is deliberately registration-only, so first-run setup can read
    /// Service Management on its main actor without touching the daemon. Callers that
    /// need no-window lifecycle diagnostics can request one bounded Unix-socket
    /// connection; that probe never starts a daemon or VM.
    public static func status(checkControlSocket: Bool = false) -> Status {
        guard let bundle = bundledLaunchAgent() else {
            return report(
                registration: .unavailable,
                plistPath: nil,
                checkControlSocket: checkControlSocket,
                diagnostic: "the Morbstack background service is available only from a complete Morbstack.app bundle")
        }
        let registration = registration(of: service())
        return report(
            registration: registration,
            plistPath: bundle.plistURL.path,
            checkControlSocket: checkControlSocket,
            diagnostic: diagnostic(for: registration, bundle: bundle))
    }

    /// Waits briefly for an already-authorized LaunchAgent to bind its control socket.
    ///
    /// Service Management registration means macOS is allowed to launch the agent; it
    /// does not mean the agent has already reached its first `listen(2)`. Call this
    /// after a person explicitly enables the service when the caller needs to hand off
    /// to a windowless Docker client straight away. It never registers, starts, or
    /// sends a command to `morbstackd`, so it cannot start the VM or containers.
    ///
    /// The timeout deliberately returns a status rather than throwing: Login Items can
    /// be disabled or the helper can have a release-specific launch failure, and those
    /// are actionable diagnostics rather than a reason to change the person's service
    /// selection behind their back.
    public static func waitForControlSocket(
        timeout: TimeInterval = 5,
        pollInterval: TimeInterval = 0.1
    ) -> Status {
        let boundedTimeout = max(0, timeout)
        let boundedPollInterval = max(0.01, pollInterval)
        let deadline = Date().addingTimeInterval(boundedTimeout)
        var current = status(checkControlSocket: true)

        while current.registration == .enabled,
              current.controlSocketState != .responding,
              Date() < deadline
        {
            // This method is invoked from a detached task by SwiftUI callers. The
            // synchronous sleep also keeps the dependency-free CLI implementation
            // simple without tying its service contract to an async runtime.
            Thread.sleep(forTimeInterval: boundedPollInterval)
            current = status(checkControlSocket: true)
        }
        return current
    }

    /// Registers the bundled LaunchAgent, if needed.
    ///
    /// Calling this is an explicit consent-bearing action. The operation is idempotent:
    /// an already-registered service returns its current report instead of treating
    /// Apple's `kSMErrorAlreadyRegistered` result as a user-visible failure.
    @discardableResult
    public static func enable() throws -> Status {
        guard let bundle = bundledLaunchAgent() else {
            throw MorbError.unsupported(
                "the Morbstack background service can only be enabled from a complete Morbstack.app bundle")
        }

        let agent = service()
        let desiredReceipt = try Receipt(bundle: bundle)
        let current = registration(of: agent)

        // A newer macOS can expose a status this build does not understand. An
        // explicit enable request is not authority to tear down an unknown service:
        // preserve the existing registration and send the person to Login Items.
        guard current != .unknown else {
            throw MorbError.unsupported(
                "macOS returned an unrecognized background-service state; inspect Login Items before changing Morbstack's service")
        }

        // Apple requires re-registration when an app updates its helper executable
        // or plist. The receipt makes that explicit operation happen once per changed
        // payload, rather than restarting an already-current agent on every command.
        if (current == .enabled || current == .requiresApproval), receipt() == desiredReceipt {
            return report(
                registration: current, plistPath: bundle.plistURL.path,
                diagnostic: diagnostic(for: current, bundle: bundle))
        }

        if current != .notRegistered && current != .notFound {
            do {
                try agent.unregister()
            } catch {
                guard isNotRegistered(error) else {
                    throw MorbError.io("could not refresh Morbstack background service: \(error.localizedDescription)")
                }
            }
        }
        do {
            try agent.register()
        } catch {
            guard isAlreadyRegistered(error) else {
                throw MorbError.io("could not enable Morbstack background service: \(error.localizedDescription)")
            }
        }
        let registered = registration(of: agent)
        // `register()` returning does not make a stale or rejected agent healthy.
        // Keep the update receipt as evidence of a macOS-confirmed registration,
        // rather than claiming that a launch agent whose state remains unresolved
        // belongs to this bundle.
        guard registered == .enabled || registered == .requiresApproval else {
            removeReceipt()
            return report(
                registration: registered, plistPath: bundle.plistURL.path,
                diagnostic: diagnostic(for: registered, bundle: bundle))
        }
        try write(receipt: desiredReceipt)
        return report(
            registration: registered, plistPath: bundle.plistURL.path,
            diagnostic: diagnostic(for: registered, bundle: bundle))
    }

    /// Unregisters the bundled LaunchAgent, if it exists.
    ///
    /// This changes only Service Management registration. It does not terminate a
    /// daemon that was manually started or delete any Docker/VM data; both are
    /// independent user-controlled operations.
    @discardableResult
    public static func disable() throws -> Status {
        guard let bundle = bundledLaunchAgent() else {
            return status()
        }

        let agent = service()
        switch registration(of: agent) {
        case .notRegistered, .notFound:
            removeReceipt()
            return report(
                registration: .notRegistered, plistPath: bundle.plistURL.path,
                diagnostic: diagnostic(for: .notRegistered, bundle: bundle))
        case .unknown:
            // Do not mutate a registration whose meaning this SDK does not know.
            // The owner can review and change it explicitly in Login Items.
            throw MorbError.unsupported(
                "macOS returned an unrecognized background-service state; inspect Login Items before changing Morbstack's service")
        case .enabled, .requiresApproval, .unavailable:
            do {
                try agent.unregister()
            } catch {
                // The state can change in System Settings between the observation and
                // this request. A missing job still satisfies an idempotent disable.
                guard isNotRegistered(error) else {
                    throw MorbError.io("could not disable Morbstack background service: \(error.localizedDescription)")
                }
            }
            removeReceipt()
            return report(
                registration: .notRegistered, plistPath: bundle.plistURL.path,
                diagnostic: diagnostic(for: .notRegistered, bundle: bundle))
        }
    }

    /// Opens Login Items only when a person explicitly asks to manage approval.
    public static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func service() -> SMAppService {
        SMAppService.agent(plistName: plistName)
    }

    private static func registration(of agent: SMAppService) -> Registration {
        switch agent.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    /// A bundle-local check makes source-checkout diagnostics useful and avoids asking
    /// ServiceManagement to register a name that cannot exist in the required bundle
    /// location (`Contents/Library/LaunchAgents`). ServiceManagement independently
    /// validates the signature at registration time.
    private struct BundleAgent {
        let appURL: URL
        let plistURL: URL
        let daemonURL: URL
    }

    private struct Receipt: Codable, Equatable {
        let version: String
        let appPath: String
        let plistSHA256: String
        let daemonSHA256: String

        init(bundle: BundleAgent) throws {
            let data: Data
            do {
                data = try Data(contentsOf: bundle.plistURL, options: .mappedIfSafe)
            } catch {
                throw MorbError.io("could not read bundled launch agent at \(bundle.plistURL.path): \(error.localizedDescription)")
            }
            version = MorbVersion.string
            appPath = bundle.appURL.standardizedFileURL.path
            plistSHA256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            daemonSHA256 = try MorbBackgroundService.sha256(of: bundle.daemonURL)
        }
    }

    private static func bundledLaunchAgent() -> BundleAgent? {
        let executable = URL(fileURLWithPath: MorbExecutable.currentPath()).resolvingSymlinksInPath()
        let macOSDirectory = executable.deletingLastPathComponent()
        guard macOSDirectory.lastPathComponent == "MacOS" else { return nil }
        let contents = macOSDirectory.deletingLastPathComponent()
        let appURL = contents.deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents", appURL.pathExtension == "app"
        else { return nil }
        let plist = contents
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent(plistName, isDirectory: false)
        let daemon = contents
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("morbstackd", isDirectory: false)
        guard FileManager.default.isReadableFile(atPath: plist.path),
              FileManager.default.isExecutableFile(atPath: daemon.path)
        else { return nil }
        return BundleAgent(appURL: appURL, plistURL: plist, daemonURL: daemon)
    }

    private static func report(
        registration: Registration,
        plistPath: String?,
        checkControlSocket: Bool = false,
        diagnostic: String
    ) -> Status {
        let controlSocketPath = MorbPaths.controlSocket.path
        let controlSocketPresent = FileManager.default.fileExists(atPath: controlSocketPath)
        let controlSocketState: ControlSocketState
        if !checkControlSocket {
            controlSocketState = .notChecked
        } else if !controlSocketPresent {
            controlSocketState = .missing
        } else if UnixSocketClient.isAlive(path: controlSocketPath) {
            controlSocketState = .responding
        } else {
            controlSocketState = .unresponsive
        }
        return Status(
            registration: registration,
            plistPath: plistPath,
            controlSocketPath: controlSocketPath,
            controlSocketPresent: controlSocketPresent,
            controlSocketState: controlSocketState,
            diagnostic: diagnostic)
    }

    private static func diagnostic(for registration: Registration, bundle: BundleAgent? = nil) -> String {
        switch registration {
        case .unavailable:
            return "run this command from a complete Morbstack.app bundle"
        case .notRegistered:
            return "not enabled; run `morb service enable` to register the per-user background service"
        case .enabled:
            if let bundle, (try? Receipt(bundle: bundle)) != receipt() {
                return "enabled, but this app update has not been registered; run `morb service enable` to refresh it"
            }
            return "enabled for this signed-in user; it starts at login without starting the VM itself"
        case .requiresApproval:
            if let bundle, (try? Receipt(bundle: bundle)) != receipt() {
                return "registered but this app update has not been registered; run `morb service enable`, then approve it in Login Items"
            }
            return "registered but disabled in Login Items; run `morb service settings` and enable Morbstack"
        case .notFound:
            // A complete bundle with no existing registration commonly presents as
            // `notFound` on a development-signed app. Treat it as actionable setup,
            // while still explaining the other benign cause: a moved app after an
            // earlier registration. Neither case warrants implying that Docker data
            // or another runtime is damaged.
            return "not enabled (or this app was moved after an earlier registration); run `morb service enable` from the installed app bundle"
        case .unknown:
            return "macOS returned an unrecognized background-service state; inspect Login Items"
        }
    }

    private static func isAlreadyRegistered(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SMAppServiceErrorDomain && error.code == kSMErrorAlreadyRegistered
    }

    private static func isNotRegistered(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SMAppServiceErrorDomain && error.code == kSMErrorJobNotFound
    }

    private static func receipt() -> Receipt? {
        guard let data = try? Data(contentsOf: MorbPaths.backgroundServiceReceipt) else { return nil }
        return try? JSONDecoder().decode(Receipt.self, from: data)
    }

    private static func write(receipt: Receipt) throws {
        do {
            try MorbPaths.ensureDirectories()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(receipt).write(to: MorbPaths.backgroundServiceReceipt, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: MorbPaths.backgroundServiceReceipt.path)
        } catch let error as MorbError {
            throw error
        } catch {
            throw MorbError.io("could not record background-service registration: \(error.localizedDescription)")
        }
    }

    private static func removeReceipt() {
        try? FileManager.default.removeItem(at: MorbPaths.backgroundServiceReceipt)
    }

    private static func sha256(of url: URL) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw MorbError.io("could not read bundled daemon at \(url.path)")
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
