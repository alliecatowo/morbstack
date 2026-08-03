// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Foundation

/// User-facing configuration for the Morbstack VM, persisted as `~/.morbstack/config.toml`.
///
/// The file format is a deliberately small subset of TOML (see ``MorbConfig/parse(_:)``)
/// so that Morbstack can stay dependency-free. Unknown keys and section headers are
/// tolerated and ignored, which keeps older binaries working against newer config files.
public struct MorbConfig: Equatable, Codable, Sendable {

    /// Number of virtual CPUs. `0` means "all host cores".
    public var cpus: Int

    /// Guest RAM in mebibytes.
    public var memoryMiB: Int

    /// Size of the sparse root disk in gibibytes. Only applied when the image is created.
    public var diskSizeGiB: Int

    /// Absolute path to an alternative kernel image; `nil` uses ``MorbPaths/kernel``.
    public var kernelPath: String?

    /// Absolute path to an alternative initramfs; `nil` uses ``MorbPaths/initrd``.
    ///
    /// The file does not have to exist: when it is absent Morbstack falls back to
    /// booting from the root disk (see ``BootMode``).
    public var initrdPath: String?

    /// Kernel command line handed to the Linux boot loader.
    ///
    /// `nil` — the default — means "derive it from the boot mode", which is what makes
    /// a fresh install boot correctly whether or not a managed runtime has been
    /// activated yet. An explicit value in `config.toml` always wins.
    public var kernelCmdline: String?

    /// Whether to expose Rosetta to the guest (when installed on the host).
    public var rosetta: Bool

    /// Idle minutes before the VM is suspended to disk. `0` disables auto-suspend.
    public var autoSuspendMinutes: Int

    /// Whether a Docker wildcard or non-loopback `HostIp` binds that same address on
    /// the Mac. Docker-compatible by default: `docker run -p 8080:80` publishes on
    /// `0.0.0.0`, while people who need local-only development can opt out.
    public var allowLANPortPublishing: Bool

    /// Host directories exposed to the guest over VirtioFS, each mounted inside the
    /// guest at its own absolute path so that `docker run -v <hostpath>:...` resolves
    /// identically on both sides.
    ///
    /// Defaults to ``MorbShares/defaultSharedPaths``. An explicit empty list disables
    /// directory sharing entirely, which is a supported (if inconvenient)
    /// configuration: bind mounts then only see paths that exist inside the guest.
    public var sharedPaths: [String]

    /// Narrow host subdirectories that are eligible for a future file-event bridge.
    ///
    /// This is intentionally empty by default, and it is deliberately distinct from
    /// ``sharedPaths``: the default VirtioFS roots include `/Users` and `/Volumes`,
    /// which are sensible mount roots but dangerously broad FSEvents subscriptions.
    /// Each path must be a strict descendant of a configured shared root; validation
    /// and the bounded event contract live in ``MorbLiveShareBridge``. Naming a path
    /// here does not claim that inotify delivery exists yet.
    public var liveSharePaths: [String]

    /// How the guest is brought up.
    public enum BootMode: String, Equatable, Sendable {
        /// Kernel + initramfs; `morbinit` runs as `/init` and the rootfs lives in RAM.
        case initramfs
        /// Kernel + `/dev/vda` root filesystem; `morbinit` runs as `/sbin/morbinit`.
        case disk
    }

    /// Command line for an initramfs boot. `rdinit=` (not `init=`) is what tells the
    /// kernel to run our PID 1 out of the initramfs instead of mounting a root device.
    public static let initramfsKernelCmdline = "console=hvc0 rdinit=/init"

    /// Command line for a disk-root boot.
    public static let diskKernelCmdline = "console=hvc0 root=/dev/vda rw init=/sbin/morbinit"

    /// The command line used when no initramfs is present.
    ///
    /// Retained as the historical name for ``diskKernelCmdline``; prefer
    /// ``resolvedKernelCmdline(for:)``, which picks the right one for the boot mode.
    public static let defaultKernelCmdline = diskKernelCmdline

    /// Creates a configuration, defaulting every field to the shipped values.
    public init(
        cpus: Int = 0,
        memoryMiB: Int = 8192,
        diskSizeGiB: Int = 64,
        kernelPath: String? = nil,
        initrdPath: String? = nil,
        kernelCmdline: String? = nil,
        rosetta: Bool = true,
        autoSuspendMinutes: Int = 5,
        allowLANPortPublishing: Bool = true,
        sharedPaths: [String] = MorbShares.defaultSharedPaths,
        liveSharePaths: [String] = []
    ) {
        self.cpus = cpus
        self.memoryMiB = memoryMiB
        self.diskSizeGiB = diskSizeGiB
        self.kernelPath = kernelPath
        self.initrdPath = initrdPath
        self.kernelCmdline = kernelCmdline
        self.rosetta = rosetta
        self.autoSuspendMinutes = autoSuspendMinutes
        self.allowLANPortPublishing = allowLANPortPublishing
        self.sharedPaths = sharedPaths
        self.liveSharePaths = liveSharePaths
    }

    /// The concrete CPU count to hand to the hypervisor, resolving the `0` sentinel.
    public var resolvedCPUCount: Int {
        cpus > 0 ? cpus : ProcessInfo.processInfo.activeProcessorCount
    }

    /// The kernel image to boot, honouring ``kernelPath`` when set.
    public var resolvedKernelURL: URL {
        if let kernelPath, !kernelPath.isEmpty {
            return URL(fileURLWithPath: (kernelPath as NSString).expandingTildeInPath)
        }
        return MorbPaths.kernel
    }

    /// The initramfs to attach, honouring ``initrdPath`` when set.
    public var resolvedInitrdURL: URL {
        if let initrdPath, !initrdPath.isEmpty {
            return URL(fileURLWithPath: (initrdPath as NSString).expandingTildeInPath)
        }
        return MorbPaths.initrd
    }

    /// The boot mode implied by what is actually on disk right now.
    ///
    /// An initramfs is preferred whenever one exists: it is the only mode that boots
    /// a guest with no prepared root filesystem, which is the state of every fresh
    /// install.
    public var detectedBootMode: BootMode {
        FileManager.default.fileExists(atPath: resolvedInitrdURL.path) ? .initramfs : .disk
    }

    /// The kernel command line for `mode`, with an explicit config override winning.
    ///
    /// This is the *base* line, without the VirtioFS share arguments — see
    /// ``resolvedKernelCmdline(for:shares:)`` for the one the guest actually boots
    /// with.
    public func resolvedKernelCmdline(for mode: BootMode) -> String {
        if let kernelCmdline, !kernelCmdline.isEmpty { return kernelCmdline }
        switch mode {
        case .initramfs: return MorbConfig.initramfsKernelCmdline
        case .disk: return MorbConfig.diskKernelCmdline
        }
    }

    /// The full kernel command line: the base line for `mode` plus one
    /// `morb.share=<tag>:<path>` argument per VirtioFS share.
    ///
    /// The share arguments are appended even when `kernel_cmdline` is overridden in
    /// `config.toml`. An override exists to change how the guest *boots* (a different
    /// init, extra console options); silently dropping the share map because somebody
    /// set `console=ttyAMA0` would break every bind mount for a reason nothing in the
    /// config file hints at.
    public func resolvedKernelCmdline(for mode: BootMode, shares: [MorbDirectoryShare]) throws -> String {
        try MorbShares.appendToCmdline(resolvedKernelCmdline(for: mode), shares: shares)
    }

    /// The VirtioFS sharing plan implied by ``sharedPaths``.
    ///
    /// - Parameter probe: Filesystem classifier, injected for testing.
    public func sharePlan(
        probe: (String) -> MorbShares.RootStatus = MorbShares.probeRoot
    ) throws -> MorbShares.Plan {
        try MorbShares.plan(paths: sharedPaths, probe: probe)
    }

    // MARK: - Persistence

    /// A field persisted in `config.toml`.
    ///
    /// The Settings window uses this to make a narrow edit to a hand-maintained
    /// configuration file. Keeping the field list here, next to the parser and
    /// renderer, makes it impossible for the UI to invent a second persistence
    /// contract.
    public enum PersistedKey: String, CaseIterable, Hashable, Sendable {
        case cpus
        case memoryMiB = "memory_mib"
        case diskSizeGiB = "disk_size_gib"
        case kernelPath = "kernel_path"
        case initrdPath = "initrd_path"
        case kernelCmdline = "kernel_cmdline"
        case rosetta
        case autoSuspendMinutes = "auto_suspend_minutes"
        case allowLANPortPublishing = "allow_lan_port_publishing"
        case sharedPaths = "shared_paths"
        case liveSharePaths = "live_share_paths"
    }

    /// Loads a configuration from disk, returning defaults when the file does not exist.
    ///
    /// - Throws: ``MorbError/config(_:)`` when the file exists but cannot be parsed.
    public static func load(from url: URL = MorbPaths.configFile) throws -> MorbConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return MorbConfig() }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw MorbError.config("could not read \(url.path): \(error.localizedDescription)")
        }
        return try parse(text)
    }

    /// Writes the canonical TOML rendering of this configuration.
    public func save(to url: URL = MorbPaths.configFile) throws {
        do {
            try toTOML().write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
        } catch let error as MorbError {
            throw error
        } catch {
            throw MorbError.io("could not write \(url.path): \(error.localizedDescription)")
        }
    }

    /// The persisted fields whose values differ between two configurations.
    ///
    /// This deliberately considers only concrete configuration values, not a
    /// textual representation. It is used to distinguish an edit made in Settings
    /// from an unrelated change a person made in their editor.
    public static func changedKeys(from baseline: MorbConfig, to candidate: MorbConfig) -> Set<PersistedKey> {
        var changed: Set<PersistedKey> = []
        if baseline.cpus != candidate.cpus { changed.insert(.cpus) }
        if baseline.memoryMiB != candidate.memoryMiB { changed.insert(.memoryMiB) }
        if baseline.diskSizeGiB != candidate.diskSizeGiB { changed.insert(.diskSizeGiB) }
        if baseline.kernelPath != candidate.kernelPath { changed.insert(.kernelPath) }
        if baseline.initrdPath != candidate.initrdPath { changed.insert(.initrdPath) }
        if baseline.kernelCmdline != candidate.kernelCmdline { changed.insert(.kernelCmdline) }
        if baseline.rosetta != candidate.rosetta { changed.insert(.rosetta) }
        if baseline.autoSuspendMinutes != candidate.autoSuspendMinutes { changed.insert(.autoSuspendMinutes) }
        if baseline.allowLANPortPublishing != candidate.allowLANPortPublishing { changed.insert(.allowLANPortPublishing) }
        if baseline.sharedPaths != candidate.sharedPaths { changed.insert(.sharedPaths) }
        if baseline.liveSharePaths != candidate.liveSharePaths { changed.insert(.liveSharePaths) }
        return changed
    }

    /// Applies selected fields to a hand-maintained config without discarding the rest.
    ///
    /// `expected` is the configuration that the caller originally loaded. Before
    /// writing, this method parses the current file again. Edits to keys outside
    /// `keys` are merged; an edit to the same key is surfaced as a conflict rather
    /// than silently overwritten. Comments, blank lines, unknown keys, and unknown
    /// sections are retained byte-for-byte except for the assignment lines selected
    /// by `keys`.
    ///
    /// The replacement is made from a same-directory temporary file. The source is
    /// re-read immediately before replacement, which catches an external edit made
    /// after the three-way comparison. A non-cooperating editor can still race the
    /// filesystem replacement itself, but it cannot cause a partial config file.
    ///
    /// Use ``save(to:)`` when a caller intentionally wants the canonical full-file
    /// rendering, such as first-run creation. Interactive editors should use this
    /// method instead.
    @discardableResult
    public func savePreservingFile(
        to url: URL = MorbPaths.configFile,
        expected: MorbConfig,
        changing keys: Set<PersistedKey>
    ) throws -> MorbConfig {
        let fileManager = FileManager.default
        let source: String?
        if fileManager.fileExists(atPath: url.path) {
            do {
                source = try String(contentsOf: url, encoding: .utf8)
            } catch {
                throw MorbError.config("could not read \(url.path): \(error.localizedDescription)")
            }
        } else {
            source = nil
        }

        let current: MorbConfig
        do {
            current = try source.map { try Self.parse($0) } ?? MorbConfig()
        } catch {
            throw error
        }

        let conflicts = keys.filter {
            current.value(for: $0) != expected.value(for: $0)
                && current.value(for: $0) != value(for: $0)
        }
        guard conflicts.isEmpty else {
            let names = conflicts.map(\.rawValue).sorted().joined(separator: ", ")
            throw MorbError.config(
                "configuration changed on disk for \(names); reload Settings before saving your edit")
        }

        var merged = current
        for key in keys {
            merged.setValue(value(for: key), for: key)
        }

        guard let source else {
            try Self.replaceAtomically(merged.toTOML(), at: url, expecting: nil)
            return merged
        }

        let updated = Self.render(source, replacing: merged, keys: keys)
        guard updated != source else { return merged }
        try Self.replaceAtomically(updated, at: url, expecting: source)
        return merged
    }

    private func value(for key: PersistedKey) -> TOMLValue {
        switch key {
        case .cpus: .integer(cpus)
        case .memoryMiB: .integer(memoryMiB)
        case .diskSizeGiB: .integer(diskSizeGiB)
        case .kernelPath: .string(kernelPath ?? "")
        case .initrdPath: .string(initrdPath ?? "")
        case .kernelCmdline: .string(kernelCmdline ?? "")
        case .rosetta: .boolean(rosetta)
        case .autoSuspendMinutes: .integer(autoSuspendMinutes)
        case .allowLANPortPublishing: .boolean(allowLANPortPublishing)
        case .sharedPaths: .stringArray(sharedPaths)
        case .liveSharePaths: .stringArray(liveSharePaths)
        }
    }

    private mutating func setValue(_ value: TOMLValue, for key: PersistedKey) {
        switch (key, value) {
        case (.cpus, .integer(let value)): cpus = value
        case (.memoryMiB, .integer(let value)): memoryMiB = value
        case (.diskSizeGiB, .integer(let value)): diskSizeGiB = value
        case (.kernelPath, .string(let value)): kernelPath = value.isEmpty ? nil : value
        case (.initrdPath, .string(let value)): initrdPath = value.isEmpty ? nil : value
        case (.kernelCmdline, .string(let value)): kernelCmdline = value.isEmpty ? nil : value
        case (.rosetta, .boolean(let value)): rosetta = value
        case (.autoSuspendMinutes, .integer(let value)): autoSuspendMinutes = value
        case (.allowLANPortPublishing, .boolean(let value)): allowLANPortPublishing = value
        case (.sharedPaths, .stringArray(let value)): sharedPaths = value
        case (.liveSharePaths, .stringArray(let value)): liveSharePaths = value
        default:
            assertionFailure("PersistedKey and TOMLValue no longer agree")
        }
    }

    private static func render(
        _ source: String,
        replacing configuration: MorbConfig,
        keys: Set<PersistedKey>
    ) -> String {
        var lines = source.components(separatedBy: "\n")
        var lastAssignment: [PersistedKey: Int] = [:]
        var firstSection: Int?

        for index in lines.indices {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if firstSection == nil, trimmed.hasPrefix("[") { firstSection = index }
            if let key = persistedKey(in: line) { lastAssignment[key] = index }
        }

        for key in keys {
            if let index = lastAssignment[key] {
                lines[index] = replacingValue(in: lines[index], with: configuration.tomlValue(for: key))
            }
        }

        let missing = keys.filter { lastAssignment[$0] == nil }.sorted { $0.rawValue < $1.rawValue }
        if !missing.isEmpty {
            let assignments = missing.map { "\($0.rawValue) = \(configuration.tomlValue(for: $0))" }
            let insertionIndex = firstSection ?? max(0, lines.count - (source.hasSuffix("\n") ? 1 : 0))
            lines.insert(contentsOf: assignments, at: insertionIndex)
        }
        return lines.joined(separator: "\n")
    }

    private static func persistedKey(in line: String) -> PersistedKey? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else {
            return nil
        }
        let rawKey = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
        return PersistedKey(rawValue: String(rawKey))
    }

    private static func replacingValue(in line: String, with value: String) -> String {
        guard let equals = line.firstIndex(of: "=") else { return line }
        let prefix = String(line[...equals])
        let fragment = String(line[line.index(after: equals)...])
        return "\(prefix) \(value)\(trailingComment(in: fragment))"
    }

    private static func trailingComment(in fragment: String) -> String {
        var inString = false
        var escaped = false

        for index in fragment.indices {
            let character = fragment[index]
            if escaped {
                escaped = false
                continue
            }
            switch character {
            case "\\" where inString:
                escaped = true
            case "\"":
                inString.toggle()
            case "#" where !inString:
                var start = index
                while start > fragment.startIndex {
                    let previous = fragment.index(before: start)
                    guard fragment[previous].isWhitespace else { break }
                    start = previous
                }
                return String(fragment[start...])
            default:
                continue
            }
        }
        return ""
    }

    private func tomlValue(for key: PersistedKey) -> String {
        switch value(for: key) {
        case .string(let value): Self.quote(value)
        case .integer(let value): String(value)
        case .boolean(let value): String(value)
        case .stringArray(let value): Self.quoteArray(value)
        }
    }

    private static func replaceAtomically(_ text: String, at url: URL, expecting source: String?) throws {
        let fileManager = FileManager.default
        do {
            if let source {
                guard fileManager.fileExists(atPath: url.path) else {
                    throw MorbError.config("configuration was removed while Settings was open")
                }
                let latest = try String(contentsOf: url, encoding: .utf8)
                guard latest == source else {
                    throw MorbError.config("configuration changed on disk; reload Settings before saving your edit")
                }
            } else if fileManager.fileExists(atPath: url.path) {
                throw MorbError.config("configuration was created while Settings was open; reload before saving")
            }

            let directory = url.deletingLastPathComponent()
            let temporary = directory.appendingPathComponent(
                ".\(url.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: false)
            defer { try? fileManager.removeItem(at: temporary) }

            try text.write(to: temporary, atomically: false, encoding: .utf8)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: temporary.path)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary, backupItemName: nil, options: [])
            } else {
                try fileManager.moveItem(at: temporary, to: url)
            }
        } catch let error as MorbError {
            throw error
        } catch {
            throw MorbError.io("could not write \(url.path): \(error.localizedDescription)")
        }
    }

    /// Renders the configuration in canonical form. Round-trips through ``parse(_:)``.
    public func toTOML() -> String {
        var out = ""
        out += "# Morbstack configuration (\(MorbVersion.string))\n"
        out += "# Regenerate defaults by deleting this file.\n"
        out += "\n"
        out += "# Virtual CPUs; 0 means every host core.\n"
        out += "cpus = \(cpus)\n"
        out += "\n"
        out += "# Guest RAM in MiB.\n"
        out += "memory_mib = \(memoryMiB)\n"
        out += "\n"
        out += "# Root disk size in GiB. Applied when the sparse image is first created.\n"
        out += "disk_size_gib = \(diskSizeGiB)\n"
        out += "\n"
        if let kernelPath, !kernelPath.isEmpty {
            out += "# Override the kernel image path.\n"
            out += "kernel_path = \(MorbConfig.quote(kernelPath))\n"
        } else {
            out += "# Override the kernel image path (defaults to the managed runtime).\n"
            out += "# kernel_path = \"\"\n"
        }
        out += "\n"
        if let initrdPath, !initrdPath.isEmpty {
            out += "# Override the initramfs path.\n"
            out += "initrd_path = \(MorbConfig.quote(initrdPath))\n"
        } else {
            out += "# Override the initramfs path (defaults to the managed runtime).\n"
            out += "# An absent file means Morbstack boots from the root disk instead.\n"
            out += "# initrd_path = \"\"\n"
        }
        out += "\n"
        if let kernelCmdline, !kernelCmdline.isEmpty {
            out += "# Kernel command line (overrides the boot-mode default).\n"
            out += "kernel_cmdline = \(MorbConfig.quote(kernelCmdline))\n"
        } else {
            out += "# Kernel command line. Unset means it is derived from the boot mode:\n"
            out += "#   with an initramfs: \(MorbConfig.initramfsKernelCmdline)\n"
            out += "#   from the disk:     \(MorbConfig.diskKernelCmdline)\n"
            out += "# kernel_cmdline = \"\"\n"
        }
        out += "\n"
        out += "# Expose Rosetta to the guest when it is installed on the host.\n"
        out += "rosetta = \(rosetta)\n"
        out += "\n"
        out += "# Suspend the VM after this many idle minutes; 0 disables auto-suspend.\n"
        out += "auto_suspend_minutes = \(autoSuspendMinutes)\n"
        out += "\n"
        out += "# Let Docker wildcard and non-loopback published ports accept local-network traffic.\n"
        out += "# Set false to keep container ports on loopback only.\n"
        out += "allow_lan_port_publishing = \(allowLANPortPublishing)\n"
        out += "\n"
        out += "# Host directories exposed to the guest over VirtioFS. Each one is mounted\n"
        out += "# inside the guest at the same absolute path, so `docker run -v /Users/me/app:/app`\n"
        out += "# sees the real directory. Paths that do not exist are skipped. Set to [] to\n"
        out += "# turn directory sharing off. Must be written on one line.\n"
        out += "shared_paths = \(MorbConfig.quoteArray(sharedPaths))\n"
        out += "\n"
        out += "# Narrow project directories eligible for the future file-event bridge. This is\n"
        out += "# off by default and does not enable hot reload today. Each path must be a\n"
        out += "# strict descendant of one shared_paths root. Must be written on one line.\n"
        out += "live_share_paths = \(MorbConfig.quoteArray(liveSharePaths))\n"
        return out
    }

    // MARK: - Minimal TOML subset

    /// A single parsed scalar from the TOML subset.
    enum TOMLValue: Equatable {
        case string(String)
        case integer(Int)
        case boolean(Bool)
        /// A single-line array of double-quoted strings. Arrays of anything else, and
        /// arrays split across lines, are not part of the supported subset.
        case stringArray([String])
    }

    /// Parses the supported TOML subset into a configuration.
    ///
    /// Supported syntax:
    /// * `# comment` lines, and trailing comments after a value
    /// * `[section]` headers — accepted and ignored, so the file can grow sections later
    /// * `key = value` where *value* is a double-quoted string, an integer, `true`/`false`,
    ///   or a single-line array of double-quoted strings
    ///
    /// Unknown keys are ignored without parsing their value syntax. That is important
    /// for forward compatibility: a newer version can add a TOML value this small
    /// parser does not understand, and an older version can still safely preserve it.
    /// Known keys with the wrong value type are an error, because silently ignoring
    /// memory_mib = "lots" would be far more confusing than failing.
    public static func parse(_ text: String) throws -> MorbConfig {
        var config = MorbConfig()
        var lineNumber = 0

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") { continue }  // section header: tolerated, ignored

            guard let equals = line.firstIndex(of: "=") else {
                throw MorbError.config("line \(lineNumber): expected `key = value`, got `\(line)`")
            }
            let key = line[line.startIndex..<equals].trimmingCharacters(in: .whitespaces)
            let rest = String(line[line.index(after: equals)...])
            guard !key.isEmpty else {
                throw MorbError.config("line \(lineNumber): empty key")
            }
            guard let knownKey = PersistedKey(rawValue: String(key)) else {
                continue  // Forward compatibility: leave an unknown TOML value untouched.
            }
            let value = try parseValue(stripTrailingComment(rest), line: lineNumber)

            switch knownKey {
            case .cpus:
                config.cpus = try requireInt(value, key: key, line: lineNumber, minimum: 0)
            case .memoryMiB:
                config.memoryMiB = try requireInt(value, key: key, line: lineNumber, minimum: 1)
            case .diskSizeGiB:
                config.diskSizeGiB = try requireInt(value, key: key, line: lineNumber, minimum: 1)
            case .kernelPath:
                let path = try requireString(value, key: key, line: lineNumber)
                config.kernelPath = path.isEmpty ? nil : path
            case .initrdPath:
                let path = try requireString(value, key: key, line: lineNumber)
                config.initrdPath = path.isEmpty ? nil : path
            case .kernelCmdline:
                // An empty string means "use the boot-mode default", matching the
                // commented-out placeholder the canonical writer emits.
                let cmdline = try requireString(value, key: key, line: lineNumber)
                config.kernelCmdline = cmdline.isEmpty ? nil : cmdline
            case .rosetta:
                config.rosetta = try requireBool(value, key: key, line: lineNumber)
            case .autoSuspendMinutes:
                config.autoSuspendMinutes = try requireInt(value, key: key, line: lineNumber, minimum: 0)
            case .allowLANPortPublishing:
                config.allowLANPortPublishing = try requireBool(value, key: key, line: lineNumber)
            case .sharedPaths:
                // An explicit `[]` really does mean "share nothing"; only an absent key
                // falls back to the defaults, which `MorbConfig()` already installed.
                config.sharedPaths = try requireStringArray(value, key: key, line: lineNumber)
            case .liveSharePaths:
                // This remains opt-in even though shared_paths has broad defaults. A
                // future event bridge validates strict containment before it creates a
                // watcher; parsing only preserves the person's declared selection.
                config.liveSharePaths = try requireStringArray(value, key: key, line: lineNumber)
            }
        }
        return config
    }

    /// Removes an unquoted trailing `#` comment from a value fragment.
    private static func stripTrailingComment(_ fragment: String) -> String {
        var inString = false
        var escaped = false
        var result = ""
        for character in fragment {
            if escaped {
                result.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\" where inString:
                result.append(character)
                escaped = true
            case "\"":
                inString.toggle()
                result.append(character)
            case "#" where !inString:
                return result.trimmingCharacters(in: .whitespaces)
            default:
                result.append(character)
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func parseValue(_ raw: String, line: Int) throws -> TOMLValue {
        let token = raw.trimmingCharacters(in: .whitespaces)
        if token.isEmpty {
            throw MorbError.config("line \(line): missing value")
        }
        if token.hasPrefix("[") {
            guard token.hasSuffix("]") else {
                throw MorbError.config(
                    "line \(line): unterminated array — Morbstack's TOML subset only supports "
                        + "arrays written on a single line")
            }
            return .stringArray(try parseStringArray(String(token.dropFirst().dropLast()), line: line))
        }
        if token.hasPrefix("\"") {
            guard token.count >= 2, token.hasSuffix("\"") else {
                throw MorbError.config("line \(line): unterminated string")
            }
            let inner = token.dropFirst().dropLast()
            var out = ""
            var escaped = false
            for character in inner {
                if escaped {
                    switch character {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    default:
                        throw MorbError.config("line \(line): unsupported escape `\\\(character)`")
                    }
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    throw MorbError.config("line \(line): unescaped quote inside string")
                } else {
                    out.append(character)
                }
            }
            if escaped { throw MorbError.config("line \(line): trailing backslash in string") }
            return .string(out)
        }
        if token == "true" { return .boolean(true) }
        if token == "false" { return .boolean(false) }
        if let integer = Int(token) { return .integer(integer) }
        throw MorbError.config("line \(line): unsupported value `\(token)` (expected string, integer or bool)")
    }

    /// Splits the inside of a `[...]` on top-level commas and parses each element as
    /// a double-quoted string.
    ///
    /// Commas inside a quoted element are not separators — `["/Volumes/a,b"]` is one
    /// path, not two — so the split tracks quoting and escaping rather than calling
    /// `split(separator:)`. A trailing comma is accepted, as TOML allows.
    private static func parseStringArray(_ body: String, line: Int) throws -> [String] {
        var elements: [String] = []
        var current = ""
        var inString = false
        var escaped = false

        for character in body {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\" where inString:
                current.append(character)
                escaped = true
            case "\"":
                inString.toggle()
                current.append(character)
            case "," where !inString:
                elements.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        if inString { throw MorbError.config("line \(line): unterminated string in array") }
        elements.append(current)

        var out: [String] = []
        for element in elements {
            let trimmed = element.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                // The empty tail of `["a",]`, or the whole body of `[]`.
                continue
            }
            guard case .string(let string) = try parseValue(trimmed, line: line) else {
                throw MorbError.config(
                    "line \(line): array elements must be quoted strings, got `\(trimmed)`")
            }
            out.append(string)
        }
        return out
    }

    private static func requireInt(_ value: TOMLValue, key: String, line: Int, minimum: Int) throws -> Int {
        guard case .integer(let integer) = value else {
            throw MorbError.config("line \(line): `\(key)` must be an integer")
        }
        guard integer >= minimum else {
            throw MorbError.config("line \(line): `\(key)` must be >= \(minimum)")
        }
        return integer
    }

    private static func requireString(_ value: TOMLValue, key: String, line: Int) throws -> String {
        guard case .string(let string) = value else {
            throw MorbError.config("line \(line): `\(key)` must be a quoted string")
        }
        return string
    }

    private static func requireBool(_ value: TOMLValue, key: String, line: Int) throws -> Bool {
        guard case .boolean(let boolean) = value else {
            throw MorbError.config("line \(line): `\(key)` must be true or false")
        }
        return boolean
    }

    private static func requireStringArray(_ value: TOMLValue, key: String, line: Int) throws -> [String] {
        guard case .stringArray(let strings) = value else {
            throw MorbError.config(
                "line \(line): `\(key)` must be an array of quoted strings, e.g. "
                    + "[\"/Users\", \"/Volumes\"]")
        }
        return strings
    }

    /// Renders a list of strings as a single-line TOML array. Round-trips through
    /// ``parse(_:)``.
    private static func quoteArray(_ strings: [String]) -> String {
        "[" + strings.map(quote).joined(separator: ", ") + "]"
    }

    /// Renders a Swift string as a double-quoted TOML basic string.
    private static func quote(_ string: String) -> String {
        var out = "\""
        for character in string {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default: out.append(character)
            }
        }
        out += "\""
        return out
    }
}
