// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Read-only evidence for the explicit host-setup transaction.
//
// This is intentionally not a "make it work" helper. It re-reads the host
// integration after `MorbCliInstallation.install`, then observes an already-running
// daemon. In particular, it does not use the CLI's auto-start path and it will not
// connect to Docker's socket-activation endpoint until the daemon has already reported
// a running, Docker-ready engine.

import Darwin
import Foundation

/// The verified outcome of the host integrations chosen during first-run setup.
///
/// `verify` is safe to use in the graphical first-run completion view and from
/// `morb install-cli`: it writes nothing, registers no background service, and never
/// starts a daemon or VM. A stopped engine is an honest expected outcome of host-only
/// CLI integration, rather than a reason for the verifier to change machine state.
public enum MorbSetupVerification {

    /// Presentation-neutral severity for one observed setup result.
    public enum Status: String, Codable, Equatable, Sendable {
        /// The requested integration is present and points at Morbstack.
        case pass
        /// No change was requested because preserving another user choice was correct.
        case info
        /// A user-controlled setting needs attention, but host setup itself is intact.
        case warning
        /// A reviewed integration is absent or no longer points where it should.
        case failure
    }

    /// One independently useful setup or runtime observation.
    public struct Check: Codable, Equatable, Sendable, Identifiable {
        public let name: String
        public let status: Status
        public let detail: String

        public var id: String { name }

        public init(name: String, status: Status, detail: String) {
            self.name = name
            self.status = status
            self.detail = detail
        }

        var ipcValue: AnyCodableValue {
            .object([
                "name": .string(name),
                "status": .string(status.rawValue),
                "detail": .string(detail),
            ])
        }
    }

    /// The optional background-service choice associated with this review.
    ///
    /// The status is supplied by the caller after an explicitly confirmed registration;
    /// the verifier deliberately never calls `MorbBackgroundService.enable()` itself.
    public enum BackgroundService: Sendable {
        case notRequested
        case status(MorbBackgroundService.Status)
    }

    /// A complete, display-ready setup result. `integrations` names each host change
    /// separately; `runtime` then distinguishes a healthy, already-running engine from
    /// an intentionally unstarted one.
    public struct Report: Codable, Equatable, Sendable {
        public let integrations: [Check]
        public let runtime: [Check]

        public init(integrations: [Check], runtime: [Check]) {
            self.integrations = integrations
            self.runtime = runtime
        }

        /// A conventional response payload for `morb`'s `--json` consumers.
        public var ipcFields: [String: AnyCodableValue] {
            [
                "integrations": .array(integrations.map(\.ipcValue)),
                "runtime": .array(runtime.map(\.ipcValue)),
            ]
        }
    }

    /// Re-reads host integration and, when the daemon already reports Docker ready,
    /// verifies the Docker API with `GET /_ping`.
    ///
    /// `installation` is optional because a person can choose only the optional
    /// background-service registration when the CLI was already configured. When it is
    /// supplied, the report also says whether each link was newly installed or already
    /// correct when the reviewed transaction ran.
    public static func verify(
        installation: MorbCliInstallation.InstallResult? = nil,
        backgroundService: BackgroundService = .notRequested,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        daemonTimeout: TimeInterval = 1,
        dockerTimeout: TimeInterval = 2
    ) -> Report {
        let postInstallPlan = MorbCliInstallation.plan(environment: environment)
        let context = MorbDockerContext.status(environment: environment)

        var integrations = verifyLinks(postInstallPlan, installation: installation)
        integrations.append(verifyPath(postInstallPlan, installation: installation))
        integrations.append(verifyContext(context, installation: installation))
        integrations.append(verifyDirectSocket(postInstallPlan.directSocket))
        if case .status(let status) = backgroundService {
            integrations.append(verifyBackgroundService(status))
        }

        return Report(
            integrations: integrations,
            runtime: verifyRuntime(daemonTimeout: daemonTimeout, dockerTimeout: dockerTimeout))
    }

    // MARK: - Host integration

    private static func verifyLinks(
        _ plan: MorbCliInstallation.Plan,
        installation: MorbCliInstallation.InstallResult?
    ) -> [Check] {
        ([plan.docker] + plan.plugins).map { item in
            let action: String
            switch installation?.links[item.name] {
            case .some(.linked):
                action = "Installed and verified"
            case .some(.alreadyCorrect):
                action = "Already installed and verified"
            case nil:
                action = "Verified"
            }
            if item.alreadyCorrect {
                return Check(
                    name: item.name,
                    status: .pass,
                    detail: "\(action) at \(item.destination).")
            }
            return Check(
                name: item.name,
                status: .failure,
                detail: "The expected Morbstack link is not present at \(item.destination).")
        }
    }

    private static func verifyPath(
        _ plan: MorbCliInstallation.Plan,
        installation: MorbCliInstallation.InstallResult?
    ) -> Check {
        let reviewed = installation?.pathRegistration
        switch (reviewed, plan.pathRegistration) {
        case (.some(.addToProfile(let expected)), .profileAlreadyManaged(let actual)) where expected == actual:
            return Check(
                name: "PATH",
                status: .pass,
                detail: "The managed Morbstack PATH block is present in \(actual); it applies in new login shells.")
        case (.some(.profileAlreadyManaged(let expected)), .profileAlreadyManaged(let actual)) where expected == actual:
            return Check(
                name: "PATH",
                status: .pass,
                detail: "The managed Morbstack PATH block remains present in \(actual).")
        case (.some(.alreadyReachable), _):
            return Check(
                name: "PATH",
                status: .pass,
                detail: "Morbstack’s command-line directory is already reachable in this environment.")
        case (.some(.preservesExistingDocker(let existing)), _):
            return Check(
                name: "PATH",
                status: .info,
                detail: "Left \(existing) first on PATH by design; Morbstack did not replace another Docker client.")
        case (.some(.skippedForHomeOverride), _):
            return Check(
                name: "PATH",
                status: .info,
                detail: "No persistent PATH change was made because MORBSTACK_HOME is overridden.")
        case (.some(.unsupportedShell), _):
            return Check(
                name: "PATH",
                status: .info,
                detail: "No persistent PATH change was made because this shell cannot be configured safely.")
        case (.some(.malformedExistingBlock(let profile)), _):
            return Check(
                name: "PATH",
                status: .warning,
                detail: "\(profile) has a hand-edited Morbstack block; it was preserved for review.")
        case (nil, .profileAlreadyManaged(let profile)):
            return Check(
                name: "PATH",
                status: .pass,
                detail: "The managed Morbstack PATH block is present in \(profile).")
        case (nil, .alreadyReachable):
            return Check(
                name: "PATH",
                status: .pass,
                detail: "Morbstack’s command-line directory is already reachable in this environment.")
        case (nil, .preservesExistingDocker(let existing)):
            return Check(
                name: "PATH",
                status: .info,
                detail: "\(existing) remains first on PATH by design.")
        case (nil, .skippedForHomeOverride):
            return Check(name: "PATH", status: .info, detail: "Not persisted while MORBSTACK_HOME is overridden.")
        case (nil, .unsupportedShell):
            return Check(name: "PATH", status: .info, detail: "This shell is not configured automatically.")
        case (nil, .malformedExistingBlock(let profile)):
            return Check(name: "PATH", status: .warning, detail: "\(profile) has a hand-edited Morbstack block.")
        default:
            return Check(
                name: "PATH",
                status: .warning,
                detail: "The reviewed PATH state changed before it could be re-read; inspect your shell profile before using a new Terminal.")
        }
    }

    private static func verifyContext(
        _ context: MorbDockerContext.Status,
        installation: MorbCliInstallation.InstallResult?
    ) -> Check {
        if let error = installation?.contextError {
            return Check(
                name: "Docker context",
                status: .failure,
                detail: "CLI links were installed, but Docker context setup needs attention: \(error)")
        }
        guard context.registered, context.matchesSocket else {
            return Check(
                name: "Docker context",
                status: .failure,
                detail: "The morbstack context is not registered for \(context.socketPath).")
        }
        if context.hasDockerHostOverride {
            return Check(
                name: "Docker context",
                status: .info,
                detail: "The morbstack context points at Morbstack, but DOCKER_HOST is set in this process and overrides the saved context. Unset it to use the configured Morbstack context.")
        }
        if let environmentContext = context.environmentContext {
            if environmentContext == MorbDockerContext.name {
                return Check(
                    name: "Docker context",
                    status: .pass,
                    detail: "The morbstack context points at Morbstack and is selected by DOCKER_CONTEXT for this process.")
            }
            return Check(
                name: "Docker context",
                status: .info,
                detail: "The morbstack context points at Morbstack, but DOCKER_CONTEXT=\(environmentContext) overrides the saved context for this process.")
        }
        if context.isCurrent {
            return Check(
                name: "Docker context",
                status: .pass,
                detail: "The morbstack context points at Morbstack and is current.")
        }
        return Check(
            name: "Docker context",
            status: .pass,
            detail: "The morbstack context points at Morbstack; the explicit \(context.currentContext) context remains current.")
    }

    private static func verifyDirectSocket(_ status: MorbDockerContext.DirectSocketStatus) -> Check {
        switch status.state {
        case .correct:
            return Check(
                name: "Docker discovery socket",
                status: .pass,
                detail: "\(status.path) points at Morbstack’s Docker socket.")
        case .missing:
            return Check(
                name: "Docker discovery socket",
                status: .failure,
                detail: "The reviewed discovery link is no longer present at \(status.path).")
        case .pointsElsewhere(let destination):
            return Check(
                name: "Docker discovery socket",
                status: .info,
                detail: "Preserved the existing discovery link to \(destination).")
        case .occupied(let kind):
            return Check(
                name: "Docker discovery socket",
                status: .info,
                detail: "Preserved the existing \(kind) at \(status.path).")
        case .unavailable(let reason):
            return Check(
                name: "Docker discovery socket",
                status: .info,
                detail: "Not changed: \(reason).")
        }
    }

    private static func verifyBackgroundService(_ status: MorbBackgroundService.Status) -> Check {
        switch status.registration {
        case .enabled:
            return Check(name: "Background service", status: .pass, detail: status.diagnostic)
        case .requiresApproval:
            return Check(name: "Background service", status: .warning, detail: status.diagnostic)
        case .notRegistered, .notFound, .unknown:
            return Check(name: "Background service", status: .warning, detail: status.diagnostic)
        case .unavailable:
            return Check(name: "Background service", status: .failure, detail: status.diagnostic)
        }
    }

    // MARK: - Runtime observation

    private static func verifyRuntime(
        daemonTimeout: TimeInterval,
        dockerTimeout: TimeInterval
    ) -> [Check] {
        let controlSocket = MorbPaths.controlSocket.path
        guard FileManager.default.fileExists(atPath: controlSocket) else {
            return [
                Check(
                    name: "Daemon control socket",
                    status: .info,
                    detail: "Not running; verification did not start morbstackd or the VM."),
                Check(
                    name: "Docker engine",
                    status: .info,
                    detail: "Not checked because the engine is not already running."),
            ]
        }

        let response: DaemonResponse
        do {
            response = try UnixSocketClient.roundTrip(
                path: controlSocket,
                request: DaemonRequest(cmd: "status"),
                timeout: daemonTimeout)
        } catch {
            return [
                Check(
                    name: "Daemon control socket",
                    status: .warning,
                    detail: "A socket exists at \(controlSocket), but it did not answer: \(errorDescription(error))."),
                Check(
                    name: "Docker engine",
                    status: .info,
                    detail: "Not checked because morbstackd did not answer."),
            ]
        }

        guard response.ok, let data = response.data else {
            return [
                Check(
                    name: "Daemon control socket",
                    status: .warning,
                    detail: response.error ?? "morbstackd returned an invalid status response."),
                Check(
                    name: "Docker engine",
                    status: .info,
                    detail: "Not checked because morbstackd did not return usable status."),
            ]
        }

        let state = stringValue(data["state"]) ?? "unknown"
        let dockerReady = boolValue(data["docker_ready"]) ?? false
        var checks = [
            Check(
                name: "Daemon control socket",
                status: .pass,
                detail: "Responding at \(controlSocket) (state: \(state))."),
        ]

        guard state == "running", dockerReady else {
            checks.append(
                Check(
                    name: "Docker engine",
                    status: .info,
                    detail: "Not ready (state: \(state)); verification did not probe the Docker socket or start the VM."))
            return checks
        }

        let dockerSocket = MorbPaths.dockerSocket.path
        switch pingDocker(socketPath: dockerSocket, timeout: dockerTimeout) {
        case .success:
            checks.append(
                Check(
                    name: "Docker engine",
                    status: .pass,
                    detail: "The already-running engine answered GET /_ping."))
            checks.append(
                Check(
                    name: "Docker API socket",
                    status: .pass,
                    detail: "Responding at \(dockerSocket)."))
        case .failure(let detail):
            checks.append(
                Check(
                    name: "Docker engine",
                    status: .warning,
                    detail: "morbstackd reported Docker ready, but GET /_ping did not succeed: \(detail)."))
            checks.append(
                Check(
                    name: "Docker API socket",
                    status: .warning,
                    detail: "Could not verify \(dockerSocket)."))
        }
        return checks
    }

    /// Issues a read-only Docker Engine API probe after the daemon has reported the
    /// engine ready. Calling it any earlier could wake Docker's socket activation, so
    /// this function is intentionally private to the guarded runtime path above.
    private static func pingDocker(socketPath: String, timeout: TimeInterval) -> DockerPingResult {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return .failure("no socket at \(socketPath)")
        }
        let fd: Int32
        do {
            fd = try UnixSocketClient.connect(path: socketPath, timeout: timeout)
        } catch {
            return .failure(errorDescription(error))
        }
        defer { Darwin.close(fd) }

        var deadline = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
        POSIXSocketSupport.suppressSIGPIPE(fd)

        let request = MinimalHTTP.request(method: "GET", path: "/_ping", closeWhenDone: true)
        guard POSIXSocketSupport.writeAll(fd, request) else {
            return .failure("could not write the _ping request")
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while response.count < 16 * 1024 {
            let read = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let address = raw.baseAddress else { return -1 }
                return POSIXSocketSupport.readSome(fd, into: address, count: raw.count)
            }
            if read == 0 { break }
            if read < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return .failure("timed out waiting for a response")
                }
                return .failure(String(cString: strerror(errno)))
            }
            response.append(contentsOf: buffer[0..<read])
            do {
                if let parsed = try MinimalHTTP.parseHead(response) {
                    guard parsed.head.statusCode == 200 else {
                        return .failure("HTTP \(parsed.head.statusCode) \(parsed.head.reason)")
                    }
                    return .success
                }
            } catch {
                return .failure(errorDescription(error))
            }
        }
        return .failure("connection closed before a valid HTTP response")
    }

    private static func stringValue(_ value: AnyCodableValue?) -> String? {
        guard case .string(let value)? = value else { return nil }
        return value
    }

    private static func boolValue(_ value: AnyCodableValue?) -> Bool? {
        guard case .bool(let value)? = value else { return nil }
        return value
    }

    private static func errorDescription(_ error: Error) -> String {
        (error as? MorbError)?.description ?? error.localizedDescription
    }

    private enum DockerPingResult {
        case success
        case failure(String)
    }
}
