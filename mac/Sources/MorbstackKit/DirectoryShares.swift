// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").

import Darwin
import Foundation

/// One host directory exposed to the guest over VirtioFS.
///
/// The guest mounts `path` at *the same absolute path* it has on the host. That is
/// the whole trick behind working bind mounts: `docker run -v /Users/me/app:/app`
/// sends the literal string `/Users/me/app` to dockerd, and dockerd — which has no
/// idea it is inside a VM — resolves it against the guest's own filesystem. Mount
/// the host's `/Users` at the guest's `/Users` and the two resolve to the same
/// bytes, so no path translation is needed anywhere in the stack.
public struct MorbDirectoryShare: Equatable, Codable, Sendable {

    /// The VirtioFS tag naming the device inside the guest, e.g. `morbshare0`.
    public var tag: String

    /// The absolute host path, which is also the guest mount point.
    public var path: String

    /// Whether the guest gets it read-only.
    ///
    /// Always `false` for the user's `shared_paths` — a bind mount you cannot write
    /// to is not what anybody means by `-v $PWD:/app`. The flag exists for shares
    /// Morbstack makes for its own purposes: handing the guest a directory of host
    /// payload (an image tarball, a set of binaries) to copy out of is a read-only
    /// share by nature, and wiring one up should be a call to this initialiser rather
    /// than a change to the protocol. The whole path — planner, command line, guest
    /// mount flags — already carries it.
    public var readOnly: Bool

    public init(tag: String, path: String, readOnly: Bool = false) {
        self.tag = tag
        self.path = path
        self.readOnly = readOnly
    }
}

/// Turns a list of configured host paths into a VirtioFS sharing plan, and encodes
/// that plan onto the kernel command line so the guest can mount it.
///
/// Everything here is a pure function of its inputs (the filesystem is reached only
/// through an injected probe), so the plan the daemon boots with, the plan `morb
/// doctor` reports, and the plan the tests assert on are all produced by the same
/// code path.
///
/// ## Why the kernel command line
///
/// The guest needs the tag → path map before it does anything else, and the two
/// obvious channels both have problems. A control-channel query inverts the boot
/// order (the host would have to answer a question from a guest that has not
/// finished coming up, and morbinit would have to defer mounting until after the
/// vsock listener exists). A file baked into the initramfs makes the share list
/// part of the image, so changing `shared_paths` in `config.toml` would mean
/// rebuilding the guest image. The command line is neither: it is set by the host at
/// VM-configuration time, it is visible to PID 1 in `/proc/cmdline` from its very
/// first instruction, and it survives no state at all between boots.
public enum MorbShares {

    /// The host directories shared by default, matching what Docker Desktop and
    /// OrbStack expose. Roots that do not exist are skipped rather than fatal.
    ///
    /// `/private/tmp` rather than `/tmp`: on macOS `/tmp` is a symlink to
    /// `/private/tmp`, and the guest's own `/tmp` is a tmpfs that morbinit needs for
    /// service scratch space. See ``tmpAliasWarning``.
    public static let defaultSharedPaths = ["/Users", "/Volumes", "/private/tmp"]

    /// Prefix for generated VirtioFS tags; the share's index is appended.
    public static let tagPrefix = "morbshare"

    /// The kernel command-line key carrying one `tag:path` pair.
    public static let cmdlineKey = "morb.share"

    /// Ceiling on the number of VirtioFS devices Morbstack will configure.
    ///
    /// This is *our* limit, not the framework's: measured on macOS 26.4,
    /// `VZVirtualMachineConfiguration.validate()` accepts at least 32
    /// `VZVirtioFileSystemDeviceConfiguration`s. The cap exists so that a
    /// `shared_paths` list with fifty entries produces a legible error from us
    /// rather than a wall of virtio devices and a kernel command line that grows
    /// without bound. One slot is left spare for the Rosetta share, which is also a
    /// directory sharing device.
    public static let maximumShares = 8

    /// Conservative ceiling on the whole kernel command line.
    ///
    /// arm64's `COMMAND_LINE_SIZE` is 2048 bytes and the kernel silently truncates
    /// anything longer, which would present as "the last share mysteriously did not
    /// mount". Refuse to build such a command line instead.
    public static let maximumCmdlineBytes = 2048

    /// What a host path looks like right now.
    public enum RootStatus: Equatable, Sendable {
        /// A readable directory: shareable.
        case ok
        /// Nothing at that path.
        case missing
        /// Something is there, but it is not a directory.
        case notDirectory
        /// A directory that this process cannot read.
        case unreadable
    }

    /// Why a configured root did not make it into the plan.
    public struct SkippedRoot: Equatable, Sendable {
        public var path: String
        public var reason: String

        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }

    /// The result of planning: what will be shared, and what was dropped and why.
    public struct Plan: Equatable, Sendable {
        public var shares: [MorbDirectoryShare]
        public var skipped: [SkippedRoot]

        public init(shares: [MorbDirectoryShare] = [], skipped: [SkippedRoot] = []) {
            self.shares = shares
            self.skipped = skipped
        }
    }

    /// The note `morb doctor` prints about the `/tmp` alias, kept here so the daemon
    /// log and the report cannot drift apart.
    public static let tmpAliasWarning =
        "when /private/tmp is mounted, the guest attempts to alias /tmp to it; the Docker "
        + "proxy admits `-v /tmp/x:/y` only after the guest confirms that alias, so an "
        + "omitted or failed share receives a bind-mount error instead of guest-local data"

    // MARK: - Planning

    /// Builds the sharing plan for `paths`.
    ///
    /// - Parameters:
    ///   - paths: Host paths as written in `config.toml`, in priority order.
    ///   - probe: Classifies a normalised absolute path. Injected so the planner is
    ///     testable without touching the real filesystem; defaults to ``probeRoot(_:)``.
    /// - Throws: ``MorbError/config(_:)`` for a path that can never work (relative,
    ///   `/`, more than ``maximumShares`` of them) and ``MorbError/io(_:)`` for a
    ///   directory that exists but cannot be read.
    ///
    /// A path that is simply *absent* is not an error: `/Volumes` is empty on a Mac
    /// with nothing mounted and `/private/tmp` can be missing in a stripped
    /// environment, and neither should stop the engine from booting.
    public static func plan(
        paths: [String],
        probe: (String) -> RootStatus = MorbShares.probeRoot
    ) throws -> Plan {
        var plan = Plan()
        var accepted: [String] = []

        for raw in paths {
            let path = canonicalHostPath(raw)
            guard !path.isEmpty else { continue }

            guard !reservedGuestRoots.contains(path) else {
                throw MorbError.config(
                    "shared_paths may not contain \"\(path)\": a share is mounted in the guest "
                        + "at its host path, and the guest's own \(path) is part of the system "
                        + "that runs your containers — mounting the Mac's over it would break "
                        + "the engine")
            }
            guard path.hasPrefix("/") else {
                throw MorbError.config(
                    "shared_paths entry \"\(raw)\" is not an absolute path; "
                        + "shares are mounted in the guest at their host path, so a relative "
                        + "path has no meaning")
            }
            guard path != "/" else {
                throw MorbError.config(
                    "shared_paths may not contain \"/\": sharing the whole root filesystem "
                        + "would mount the Mac over the guest's own / and break the boot")
            }
            if accepted.contains(path) {
                plan.skipped.append(SkippedRoot(path: path, reason: "listed more than once"))
                continue
            }
            if let parent = accepted.first(where: { isDescendant(path, of: $0) }) {
                // The outer share already covers it, and mounting the inner one on top
                // would shadow the very directory it duplicates.
                plan.skipped.append(
                    SkippedRoot(path: path, reason: "already covered by the \(parent) share"))
                continue
            }

            switch probe(path) {
            case .ok:
                break
            case .missing:
                plan.skipped.append(SkippedRoot(path: path, reason: "does not exist on this Mac"))
                continue
            case .notDirectory:
                plan.skipped.append(SkippedRoot(path: path, reason: "is not a directory"))
                continue
            case .unreadable:
                // Unlike "missing", this one is reported rather than swallowed: the
                // user asked for this directory and silently booting without it turns
                // every bind mount against it into an empty directory inside the
                // container, which is far more confusing than a refusal to start.
                throw MorbError.io(
                    "shared path \(path) exists but is not readable by this process — "
                        + "grant Full Disk Access to morbstackd, or remove it from "
                        + "shared_paths in \(MorbPaths.configFile.path)")
            }

            guard plan.shares.count < maximumShares else {
                throw MorbError.config(
                    "too many shared_paths: Morbstack configures at most \(maximumShares) "
                        + "VirtioFS devices (got \(paths.count) entries)")
            }
            accepted.append(path)
            plan.shares.append(MorbDirectoryShare(tag: tag(at: plan.shares.count), path: path))
        }
        return plan
    }

    /// The tag for the share at `index`.
    public static func tag(at index: Int) -> String { "\(tagPrefix)\(index)" }

    /// Classifies a real path on this Mac.
    public static func probeRoot(_ path: String) -> RootStatus {
        var info = stat()
        guard stat(path, &info) == 0 else { return .missing }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return .notDirectory }
        // R_OK *and* X_OK: a directory you cannot traverse is no more shareable than
        // one you cannot list, and virtiofs needs both.
        guard access(path, R_OK | X_OK) == 0 else { return .unreadable }
        return .ok
    }

    /// Whether this process can create entries in `path` **itself**.
    ///
    /// A narrow diagnostic, not a verdict on the share. It says nothing about the
    /// directories underneath, which is where every real bind mount points:
    /// `access("/Users", W_OK)` is false on a stock Mac because nobody creates files
    /// directly in `/Users`, while `/Users/you/project` — the thing anyone actually
    /// mounts — is perfectly writable. Presenting this as the share's access mode
    /// labels the most common share on every machine "read-only" and is simply
    /// wrong, so no surface may render it that way; ``MorbShareState/readOnly``, which
    /// is the mount flag the guest reports, is the authoritative answer.
    public static func isWritable(_ path: String) -> Bool {
        access(path, W_OK) == 0
    }

    /// Guest paths a share must never be mounted over, because the guest's own
    /// filesystem lives there.
    ///
    /// The same-path design means a configured host path *is* a guest mount point, so
    /// sharing the Mac's `/usr` would hide dockerd, containerd and busybox behind the
    /// Mac's copy and leave a guest that cannot run a container. Refused rather than
    /// skipped: this is a config that can never do what its author intended.
    ///
    /// `/tmp`, `/var` and `/etc` are listed as a backstop only. They are rewritten to
    /// their `/private` form before this check is reached (see
    /// ``resolveMacOSPrivateAlias(_:)``), which is both what the user meant and safe,
    /// so in practice they are upgraded rather than refused. They stay in the set so a
    /// change to the alias list cannot silently reopen the hole.
    static let reservedGuestRoots: Set<String> = [
        "/bin", "/dev", "/etc", "/lib", "/proc", "/run", "/sbin", "/sys", "/tmp",
        "/usr", "/var",
    ]

    /// Rewrites the three macOS `/private` symlinks to the real directory they point at.
    ///
    /// `/tmp`, `/var` and `/etc` are symlinks into `/private` on macOS, and every tool
    /// that reports a resolved path (`getcwd`, `realpath`, `$PWD` after a `cd -P`)
    /// already says `/private/tmp`. Sharing them under their symlink names would be
    /// actively destructive, because the same-path design would mount them over the
    /// guest's *own* `/tmp`, `/var` and `/etc`: the guest's `/tmp` is the tmpfs
    /// `early_mounts` creates for service scratch space, and `/var/lib/docker` is the
    /// entire layer store. So they are mapped forward, to the path the rest of the
    /// system agrees is real and that the guest has nothing at.
    ///
    /// Note this is the *opposite* direction from `NSString.standardizingPath`, which
    /// collapses `/private/tmp` to `/tmp` and would walk straight into the failure
    /// above — see ``normalise(_:)``.
    static func resolveMacOSPrivateAlias(_ path: String) -> String {
        for alias in ["/tmp", "/var", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            return "/private" + path
        }
        return path
    }

    /// Collapses a configured path to the canonical form used everywhere else:
    /// tilde expanded, redundant separators and `.`/`..` segments removed, no
    /// trailing slash.
    ///
    /// Hand-rolled rather than `NSString.standardizingPath`, which is wrong for this
    /// job in a way that is invisible until you read the guest's mount table:
    /// **it rewrites `/private/tmp` to `/tmp`** (and `/private/var` to `/var`),
    /// because those are symlinks on macOS. The share would then be mounted inside
    /// the guest at `/tmp` — on top of the tmpfs `early_mounts` put there for service
    /// scratch space — so dockerd's temporary files would land on the Mac's `/tmp`,
    /// and a path the user did not write would appear in `/proc/mounts`. The whole
    /// design rests on the guest mount point being *exactly* the configured host
    /// path, so nothing here may quietly resolve symlinks.
    ///
    /// `..` is resolved lexically, which is not symlink-correct in general but is
    /// both correct and predictable for the top-level directories that can be share
    /// roots — and predictability is the property that matters when the result
    /// becomes a mount point inside another kernel.
    public static func normalise(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let trimmed = expanded.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        let absolute = trimmed.hasPrefix("/")

        var segments: [String] = []
        for segment in trimmed.split(separator: "/", omittingEmptySubsequences: true) {
            switch segment {
            case ".":
                continue
            case "..":
                // Never pop past the root: "/.." is "/", as the kernel has it.
                if let last = segments.last, last != ".." {
                    segments.removeLast()
                } else if !absolute {
                    segments.append("..")
                }
            default:
                segments.append(String(segment))
            }
        }
        let joined = segments.joined(separator: "/")
        if absolute { return "/" + joined }
        return joined
    }

    /// Returns the lexical host-path spelling Morbstack uses for VirtioFS matching.
    ///
    /// This intentionally does not resolve arbitrary symlinks: the guest receives
    /// the literal bind source, so turning a user path into some other path here
    /// could make a host-side check claim a share that dockerd cannot see. The one
    /// exception is macOS's three documented `/private` aliases, which must be
    /// rewritten before comparing against a VirtioFS mount point for the same reason
    /// they are rewritten while planning shares.
    public static func canonicalHostPath(_ path: String) -> String {
        resolveMacOSPrivateAlias(normalise(path))
    }

    /// Maps only macOS's `/private` aliases in a Docker bind source.
    ///
    /// Unlike ``canonicalHostPath(_:)``, this deliberately preserves `..`, `.` and
    /// whitespace. Those are part of the source path dockerd will resolve, and
    /// normalising them before symlink resolution can turn `/Users/link/../x` into a
    /// different path from the one the guest kernel follows. It is used only as the
    /// first, same-path VirtioFS comparison; a bind preflight subsequently resolves
    /// symlinks through the original path before making its final coverage decision.
    static func canonicalBindSource(_ path: String) -> String {
        resolveMacOSPrivateAlias(path)
    }

    /// Whether `path` sits inside `ancestor` (and is not `ancestor` itself).
    static func isDescendant(_ path: String, of ancestor: String) -> Bool {
        path.hasPrefix(ancestor.hasSuffix("/") ? ancestor : ancestor + "/")
    }

    // MARK: - Kernel command line

    /// The command-line suffix marking a share read-only.
    public static let readOnlyFlag = "ro"

    /// The command-line fragments describing `shares`, one per share.
    ///
    /// e.g. `["morb.share=morbshare0:/Users", "morb.share=payload:/x/y:ro"]`. The
    /// `:ro` suffix is emitted only for a read-only share, so the common line stays
    /// short and an older guest that ignores the suffix still mounts the path.
    public static func cmdlineArguments(for shares: [MorbDirectoryShare]) -> [String] {
        shares.map {
            "\(cmdlineKey)=\($0.tag):\(encode($0.path))" + ($0.readOnly ? ":\(readOnlyFlag)" : "")
        }
    }

    /// `base` with the share arguments appended.
    ///
    /// - Throws: ``MorbError/config(_:)`` if the result would exceed
    ///   ``maximumCmdlineBytes`` — the kernel would truncate it and the missing
    ///   shares would look like a guest bug.
    public static func appendToCmdline(_ base: String, shares: [MorbDirectoryShare]) throws -> String {
        guard !shares.isEmpty else { return base }
        // A hand-written `morb.share=` in `kernel_cmdline` plus the generated ones is
        // not additive, it is a collision: the tags are positional (`morbshare0`,
        // `morbshare1`, …), so a hand-written `morbshare2` names a device the host
        // configured for a *different* path. The guest then mounts whichever entry it
        // reaches first and silently drops the other — observed in the wild as a share
        // that mounted read-only when nothing in `shared_paths` asked for that.
        // `shared_paths` is the one source of truth; say so rather than boot a guest
        // whose mount table disagrees with its own configuration.
        if !parseCmdline(base).isEmpty {
            throw MorbError.config(
                "kernel_cmdline already contains \(cmdlineKey)= arguments, which would collide "
                    + "with the \(shares.count) share(s) derived from shared_paths (the VirtioFS "
                    + "tags are positional and would name the wrong device). Remove them from "
                    + "kernel_cmdline and configure shares through shared_paths, or set "
                    + "shared_paths = [] to hand the share map over to kernel_cmdline entirely.")
        }
        let combined = ([base] + cmdlineArguments(for: shares)).joined(separator: " ")
        let byteCount = combined.utf8.count
        guard byteCount <= maximumCmdlineBytes else {
            throw MorbError.config(
                "the kernel command line would be \(byteCount) bytes with \(shares.count) "
                    + "shared path(s), over the \(maximumCmdlineBytes)-byte limit the kernel "
                    + "silently truncates at — shorten or shorten the list of shared_paths")
        }
        return combined
    }

    /// Recovers the shares encoded in a kernel command line.
    ///
    /// This is the host-side twin of morbinit's `shares::parse_cmdline`; the two are
    /// held together by ``MorbShares`` round-trip tests on this side and
    /// `shares::tests` on the other. Malformed entries are skipped, matching the
    /// guest's tolerance.
    public static func parseCmdline(_ cmdline: String) -> [MorbDirectoryShare] {
        var shares: [MorbDirectoryShare] = []
        for token in cmdline.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
            guard token.hasPrefix(cmdlineKey + "=") else { continue }
            let value = token.dropFirst(cmdlineKey.count + 1)
            guard let colon = value.firstIndex(of: ":") else { continue }
            let tag = String(value[value.startIndex..<colon])
            var rest = String(value[value.index(after: colon)...])
            var readOnly = false
            if rest.hasSuffix(":" + readOnlyFlag) {
                readOnly = true
                rest = String(rest.dropLast(readOnlyFlag.count + 1))
            }
            guard !tag.isEmpty, let path = decode(rest), path.hasPrefix("/") else { continue }
            shares.append(MorbDirectoryShare(tag: tag, path: path, readOnly: readOnly))
        }
        return shares
    }

    // MARK: - Path encoding

    /// Bytes that survive ``encode(_:)`` unescaped.
    ///
    /// Everything else — spaces, quotes, `:`, `%`, anything non-ASCII — is
    /// percent-escaped. Spaces are the reason this exists at all: the kernel command
    /// line is whitespace-separated, so `/Volumes/My Disk` would otherwise arrive in
    /// the guest as two unrelated arguments. `:` is escaped because it separates the
    /// tag from the path, and `%` because it introduces an escape. The surviving set
    /// is chosen so that ordinary paths (`/Users`, `/private/tmp`) stay readable in
    /// `/proc/cmdline`, which matters the first time somebody debugs this by eye.
    private static let unescaped: Set<UInt8> = {
        var set = Set<UInt8>()
        for byte in UInt8(ascii: "a")...UInt8(ascii: "z") { set.insert(byte) }
        for byte in UInt8(ascii: "A")...UInt8(ascii: "Z") { set.insert(byte) }
        for byte in UInt8(ascii: "0")...UInt8(ascii: "9") { set.insert(byte) }
        for character in "/._-+" { set.insert(character.asciiValue!) }
        return set
    }()

    /// Percent-encodes a path for the kernel command line.
    public static func encode(_ path: String) -> String {
        var out = ""
        for byte in Array(path.utf8) {
            if unescaped.contains(byte) {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// Reverses ``encode(_:)``. Returns `nil` on a malformed escape or on bytes that
    /// are not valid UTF-8.
    public static func decode(_ encoded: String) -> String? {
        var bytes: [UInt8] = []
        var iterator = Array(encoded.utf8).makeIterator()
        while let byte = iterator.next() {
            guard byte == UInt8(ascii: "%") else {
                bytes.append(byte)
                continue
            }
            guard let high = iterator.next(), let low = iterator.next(),
                  let highValue = hexValue(high), let lowValue = hexValue(low)
            else { return nil }
            bytes.append(highValue << 4 | lowValue)
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    // MARK: - Guest-reported state

    /// What the guest did with one advertised share.
    public enum GuestMountState: String, Equatable, Sendable, Codable {
        /// `mount -t virtiofs` succeeded and the path is live.
        case mounted
        /// The mount failed; the console log has the errno.
        case failed
    }

    /// The inverse of ``parseGuestShares(_:)``, used to hand the guest's report on
    /// through the daemon's control socket without inventing a second encoding.
    ///
    /// Sorted by path so the same guest state always renders the same string, which
    /// keeps `morb status --json` diffable.
    public static func encodeGuestShares(_ states: [String: GuestMountState]) -> String {
        states.keys.sorted()
            .map { "\(encode($0)):\(states[$0]!.rawValue)" }
            .joined(separator: ",")
    }

    /// Decodes the `shares` field of an MRB0 `info` reply.
    ///
    /// Wire form is `"<encoded-path>:<state>"` entries joined with `,` — the same
    /// percent encoding as the command line, so a path with a comma or a colon in it
    /// cannot be mistaken for a separator. An entry that does not parse is dropped:
    /// a newer guest reporting a state this build does not know about should not
    /// take the whole report down with it.
    public static func parseGuestShares(_ field: String) -> [String: GuestMountState] {
        var states: [String: GuestMountState] = [:]
        for entry in field.split(separator: ",") {
            guard let colon = entry.lastIndex(of: ":") else { continue }
            guard let path = decode(String(entry[entry.startIndex..<colon])),
                  let state = GuestMountState(rawValue: String(entry[entry.index(after: colon)...]))
            else { continue }
            states[path] = state
        }
        return states
    }
}
