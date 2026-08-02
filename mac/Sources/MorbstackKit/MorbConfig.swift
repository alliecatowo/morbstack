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
    /// a fresh install boot correctly whether or not `data/kernel/initrd.img` has been
    /// built yet. An explicit value in `config.toml` always wins.
    public var kernelCmdline: String?

    /// Whether to expose Rosetta to the guest (when installed on the host).
    public var rosetta: Bool

    /// Idle minutes before the VM is suspended to disk. `0` disables auto-suspend.
    public var autoSuspendMinutes: Int

    /// Host directories exposed to the guest over VirtioFS, each mounted inside the
    /// guest at its own absolute path so that `docker run -v <hostpath>:...` resolves
    /// identically on both sides.
    ///
    /// Defaults to ``MorbShares/defaultSharedPaths``. An explicit empty list disables
    /// directory sharing entirely, which is a supported (if inconvenient)
    /// configuration: bind mounts then only see paths that exist inside the guest.
    public var sharedPaths: [String]

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
        sharedPaths: [String] = MorbShares.defaultSharedPaths
    ) {
        self.cpus = cpus
        self.memoryMiB = memoryMiB
        self.diskSizeGiB = diskSizeGiB
        self.kernelPath = kernelPath
        self.initrdPath = initrdPath
        self.kernelCmdline = kernelCmdline
        self.rosetta = rosetta
        self.autoSuspendMinutes = autoSuspendMinutes
        self.sharedPaths = sharedPaths
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
            out += "# Override the kernel image path (defaults to data/kernel/vmlinux).\n"
            out += "# kernel_path = \"\"\n"
        }
        out += "\n"
        if let initrdPath, !initrdPath.isEmpty {
            out += "# Override the initramfs path.\n"
            out += "initrd_path = \(MorbConfig.quote(initrdPath))\n"
        } else {
            out += "# Override the initramfs path (defaults to data/kernel/initrd.img).\n"
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
        out += "# Host directories exposed to the guest over VirtioFS. Each one is mounted\n"
        out += "# inside the guest at the same absolute path, so `docker run -v /Users/me/app:/app`\n"
        out += "# sees the real directory. Paths that do not exist are skipped. Set to [] to\n"
        out += "# turn directory sharing off. Must be written on one line.\n"
        out += "shared_paths = \(MorbConfig.quoteArray(sharedPaths))\n"
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
    /// Unknown keys are ignored. Known keys with the wrong value type are an error, because
    /// silently ignoring `memory_mib = "lots"` would be far more confusing than failing.
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
            let value = try parseValue(stripTrailingComment(rest), line: lineNumber)

            switch key {
            case "cpus":
                config.cpus = try requireInt(value, key: key, line: lineNumber, minimum: 0)
            case "memory_mib":
                config.memoryMiB = try requireInt(value, key: key, line: lineNumber, minimum: 1)
            case "disk_size_gib":
                config.diskSizeGiB = try requireInt(value, key: key, line: lineNumber, minimum: 1)
            case "kernel_path":
                let path = try requireString(value, key: key, line: lineNumber)
                config.kernelPath = path.isEmpty ? nil : path
            case "initrd_path":
                let path = try requireString(value, key: key, line: lineNumber)
                config.initrdPath = path.isEmpty ? nil : path
            case "kernel_cmdline":
                // An empty string means "use the boot-mode default", matching the
                // commented-out placeholder the canonical writer emits.
                let cmdline = try requireString(value, key: key, line: lineNumber)
                config.kernelCmdline = cmdline.isEmpty ? nil : cmdline
            case "rosetta":
                config.rosetta = try requireBool(value, key: key, line: lineNumber)
            case "auto_suspend_minutes":
                config.autoSuspendMinutes = try requireInt(value, key: key, line: lineNumber, minimum: 0)
            case "shared_paths":
                // An explicit `[]` really does mean "share nothing"; only an absent key
                // falls back to the defaults, which `MorbConfig()` already installed.
                config.sharedPaths = try requireStringArray(value, key: key, line: lineNumber)
            default:
                continue  // forward compatibility
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
