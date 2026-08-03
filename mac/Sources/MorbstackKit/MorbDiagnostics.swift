// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// A deliberately small, offline support-bundle collector.
//
// This is not a backup or an engine export. It does not contact (and therefore cannot
// start) morbstackd or Docker. Its entire input surface is public host metadata,
// redacted Doctor output, and bounded tails of the two Morbstack-owned text logs.

import Darwin
import Foundation

/// Creates a reviewable, redacted diagnostic directory for a support request.
public enum MorbDiagnostics {

    /// A log can be enormous when a guest is wedged. Reading from the end keeps this
    /// command useful without turning a support bundle into an unbounded data export.
    public static let maximumLogTailBytes = 64 * 1024

    /// The default is deliberately separate from VM data and Docker data. It is a
    /// user-owned directory and a person can inspect or remove each bundle directly.
    public static var defaultOutputDirectory: URL {
        MorbPaths.root.appendingPathComponent("diagnostics", isDirectory: true)
    }

    /// Machine-readable outcome of a successful collection. `directory` is the one
    /// new directory this call created; nothing else on the host was modified.
    public struct Result: Codable, Equatable, Sendable {
        public let directory: String
        public let createdAt: String
        public let files: [String]
        public let warnings: [String]
    }

    /// Collects the redacted support bundle below `outputDirectory`.
    ///
    /// This collector deliberately runs Doctor with live-share probes disabled: it
    /// never opens a control or Docker socket and never uses the CLI's daemon-spawning
    /// path.
    @discardableResult
    public static func collect(
        outputDirectory: URL = defaultOutputDirectory,
        now: Date = Date()
    ) throws -> Result {
        let fm = FileManager.default
        let destination = outputDirectory.standardizedFileURL
        let bundle = uniqueBundleDirectory(in: destination, now: now)
        var createdBundle = false
        do {
            try fm.createDirectory(
                at: destination,
                withIntermediateDirectories: true,
                attributes: privateDirectoryAttributes)
            try fm.createDirectory(at: bundle, withIntermediateDirectories: false, attributes: privateDirectoryAttributes)
            createdBundle = true

            let report = makeReport(createdAt: now)
            try writeJSON(report, named: "report.json", into: bundle)

            let daemonTail = try writeLogTail(
                source: MorbPaths.daemonLog, named: "daemon.log.tail.txt", into: bundle)
            let consoleTail = try writeLogTail(
                source: MorbPaths.consoleLog, named: "console.log.tail.txt", into: bundle)

            let readme = """
            Morbstack diagnostics bundle

            This directory is safe to inspect before sharing. It contains public system
            and version data, redacted Doctor results, and at most \(maximumLogTailBytes) bytes
            from the end of each Morbstack-owned text log.

            It deliberately excludes Docker configuration and credentials, raw
            config.toml, kubeconfig, VM/disk data, mounts and shared-path configuration,
            and all Docker image, container, and volume payloads.
            """
            try writeText(readme + "\n", named: "README.txt", into: bundle)

            var warnings: [String] = []
            if !daemonTail.present { warnings.append("daemon log was unavailable") }
            if !consoleTail.present { warnings.append("console log was unavailable") }
            warnings.append(contentsOf: daemonTail.warnings)
            warnings.append(contentsOf: consoleTail.warnings)

            return Result(
                directory: bundle.path,
                createdAt: timestamp(now),
                files: ["README.txt", "report.json", "daemon.log.tail.txt", "console.log.tail.txt"],
                warnings: warnings)
        } catch {
            // This exact directory name was constructed above and has never existed
            // before this call. Remove a partial bundle rather than leaving someone to
            // guess whether it is safe to share; never touch its parent.
            if createdBundle { try? fm.removeItem(at: bundle) }
            throw MorbError.io("could not create diagnostics bundle: \(error.localizedDescription)")
        }
    }

    // MARK: - Report construction

    private struct SupportReport: Codable {
        let formatVersion: Int
        let createdAt: String
        let product: String
        let system: PublicSystemInfo
        let configuration: ConfigurationHealth
        let doctor: SanitizedDoctorReport
        let collection: CollectionPolicy
    }

    private struct PublicSystemInfo: Codable {
        let macOS: String
        let kernel: String
        let architecture: String
        let logicalCPUCount: Int
    }

    private struct ConfigurationHealth: Codable {
        let state: String
        let detail: String
    }

    private struct SanitizedDoctorReport: Codable {
        let healthy: Bool
        let checks: [DoctorCheck]
    }

    private struct CollectionPolicy: Codable {
        let logTailLimitBytes: Int
        let included: [String]
        let excluded: [String]
    }

    private static func makeReport(createdAt: Date) -> SupportReport {
        let doctor = Doctor.run(
            includeLiveShares: false,
            includeDockerIntegrationChecks: false,
            includeDaemonChecks: false)
        return SupportReport(
            formatVersion: 1,
            createdAt: timestamp(createdAt),
            product: "Morbstack \(MorbVersion.string)",
            system: publicSystemInfo(),
            configuration: configurationHealth(),
            doctor: SanitizedDoctorReport(
                healthy: doctor.healthy,
                checks: sanitizeDoctorChecks(doctor.checks)),
            collection: CollectionPolicy(
                logTailLimitBytes: maximumLogTailBytes,
                included: [
                    "public macOS and architecture metadata",
                    "Morbstack version",
                    "configuration health without configuration contents",
                    "redacted Doctor checks without shared-path or Docker-config checks",
                    "bounded redacted Morbstack daemon and console log tails",
                ],
                excluded: [
                    "Docker configuration and credential helpers",
                    "raw config.toml",
                    "kubeconfig and Kubernetes credentials",
                    "mounts, shared paths, and boot command lines",
                    "VM disks and runtime data",
                    "Docker images, containers, volumes, and their payloads",
                ]))
    }

    private static func publicSystemInfo() -> PublicSystemInfo {
        var machine = utsname()
        uname(&machine)
        let systemName = withUnsafeBytes(of: &machine.sysname) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let release = withUnsafeBytes(of: &machine.release) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let architecture = withUnsafeBytes(of: &machine.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return PublicSystemInfo(
            macOS: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            kernel: "\(systemName) \(release)",
            architecture: architecture,
            logicalCPUCount: ProcessInfo.processInfo.processorCount)
    }

    private static func configurationHealth() -> ConfigurationHealth {
        let exists = FileManager.default.fileExists(atPath: MorbPaths.configFile.path)
        do {
            _ = try MorbConfig.load()
            return ConfigurationHealth(
                state: exists ? "valid" : "defaults",
                detail: exists ? "Configuration parsed successfully." : "No configuration file; built-in defaults are in use.")
        } catch {
            return ConfigurationHealth(
                state: "invalid",
                detail: "Configuration could not be parsed; its contents are not included.")
        }
    }

    /// Exclude every Doctor check that can expose Docker configuration, host shares,
    /// or a boot command line containing mount arguments. The remaining checks are
    /// path-sanitized because home-directory names are not useful support data.
    private static func sanitizeDoctorChecks(_ checks: [DoctorCheck]) -> [DoctorCheck] {
        let excludedExactNames: Set<String> = [
            "shares", "shares-config", "shares-tmp", "boot-cmdline",
            "docker-contexts", "docker-credentials",
        ]
        return checks.compactMap { check in
            guard !excludedExactNames.contains(check.name), !check.name.hasPrefix("share ") else {
                return nil
            }
            if check.name == "config" {
                return DoctorCheck(
                    name: "config",
                    status: check.status,
                    detail: check.status == .fail
                        ? "Configuration is invalid; contents are not included."
                        : "Configuration health recorded separately; contents are not included.")
            }
            return DoctorCheck(
                name: check.name,
                status: check.status,
                detail: redactHomePath(in: check.detail))
        }
    }

    // MARK: - Bounded, redacted logs

    private struct LogTailOutcome {
        let present: Bool
        let warnings: [String]
    }

    private static func writeLogTail(source: URL, named name: String, into directory: URL) throws -> LogTailOutcome {
        let tail = readTail(source)
        let header = "# Morbstack support log tail\n# Content is bounded and redacted.\n\n"
        try writeText(header + tail.text, named: name, into: directory)
        return LogTailOutcome(present: tail.present, warnings: tail.warnings)
    }

    private static func readTail(_ source: URL) -> (text: String, present: Bool, warnings: [String]) {
        guard FileManager.default.fileExists(atPath: source.path) else {
            return ("<log not present>\n", false, [])
        }
        do {
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            let start = end > UInt64(maximumLogTailBytes) ? end - UInt64(maximumLogTailBytes) : 0
            try handle.seek(toOffset: start)
            let data = try handle.readToEnd() ?? Data()
            var text = String(decoding: data, as: UTF8.self)
            if start > 0, let firstNewline = text.firstIndex(of: "\n") {
                text.removeSubrange(...firstNewline)
            }
            let redacted = redactLog(text)
            // Redaction can change UTF-8 width. Enforce the same bound on emitted text.
            let bounded = Data(redacted.utf8).prefix(maximumLogTailBytes)
            return (String(decoding: bounded, as: UTF8.self), true, [])
        } catch {
            return ("<log could not be read>\n", false, ["a Morbstack log could not be read"])
        }
    }

    private static func redactLog(_ text: String) -> String {
        var result = redactHomePath(in: text)
        for (pattern, replacement) in redactionRules {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
        }
        return result
    }

    private static func redactHomePath(in text: String) -> String {
        text.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path,
            with: "$HOME")
    }

    private static let redactionRules: [(NSRegularExpression, String)] = [
        // Header-shaped secrets need their whole value removed because Bearer and Basic
        // credentials include a space after the colon.
        (regex("(?im)^(\\s*(?:authorization|proxy-authorization|x-registry-auth|cookie|set-cookie)\\s*:\\s*).*$"), "$1<redacted>"),
        // Secret-ish key/value assignments in text, JSON fragments, and environment
        // dumps. Deliberately leaves the key visible so a support engineer can see the
        // kind of failure without receiving the value.
        (regex("(?im)(\\b(?:token|access[_-]?token|refresh[_-]?token|api[_-]?key|password|passwd|secret|client[_-]?secret|credential)\\b\\s*[:=]\\s*)(?:\\\"[^\\\"]*\\\"|'[^']*'|[^\\s,;]+)"), "$1<redacted>"),
        (regex("(?i)([?&](?:token|access_token|api_key|password|secret)=)[^&\\s]+"), "$1<redacted>"),
        (regex("(?i)(\\b(?:bearer|basic)\\s+)[A-Za-z0-9._~+/=-]+"), "$1<redacted>"),
    ]

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // These literals are maintained next to the privacy policy above and are
        // compile-time constants. A failure here is a programming error, not input.
        try! NSRegularExpression(pattern: pattern)
    }

    // MARK: - Files

    private static let privateDirectoryAttributes: [FileAttributeKey: Any] = [
        .posixPermissions: NSNumber(value: Int16(0o700)),
    ]

    private static let privateFileAttributes: [FileAttributeKey: Any] = [
        .posixPermissions: NSNumber(value: Int16(0o600)),
    ]

    private static func writeJSON(_ value: some Encodable, named name: String, into directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try writeData(try encoder.encode(value), named: name, into: directory)
    }

    private static func writeText(_ text: String, named name: String, into directory: URL) throws {
        try writeData(Data(text.utf8), named: name, into: directory)
    }

    private static func writeData(_ data: Data, named name: String, into directory: URL) throws {
        let file = directory.appendingPathComponent(name, isDirectory: false)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes(privateFileAttributes, ofItemAtPath: file.path)
    }

    private static func uniqueBundleDirectory(in output: URL, now: Date) -> URL {
        let base = "morbstack-diagnostics-\(timestamp(now))"
        let candidate = output.appendingPathComponent(base, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: candidate.path) else {
            return output.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        }
        return candidate
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss'Z'"
        return formatter.string(from: date)
    }
}
