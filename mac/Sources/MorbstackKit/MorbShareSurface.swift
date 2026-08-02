// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The surface-side view of shared paths and Rosetta: one row per configured root, with
// everything `morb shares` prints and everything the app draws already folded in.
//
// This is a *presentation* layer over ``MorbShares``, not a second implementation of it.
// Planning, tag assignment, path normalisation and the guest wire format all live in
// `DirectoryShares.swift` and are used from here rather than reimplemented — the tag a
// row displays has to be the tag the guest was actually told, and two functions that
// independently "know" how to number shares would eventually disagree about which
// directory `morbshare1` is.
//
// It exists as its own file because two front ends need identical answers and cannot
// share code any other way: `morb` links `MorbstackKit` and nothing else, and the app
// must not grow a quietly divergent copy.
//
// THE ONE RULE THAT MATTERS: **shares are same-path.** A host directory appears inside
// the guest at its identical absolute path, so `-v /Users/you/proj:/app` needs no
// translation and `dockerd` needs no rewriting. The VirtioFS *tag* is an internal device
// identifier, never a path component, and there is no `/mnt/...` prefix anywhere in this
// design. ``MorbShareState/guestPath`` is carried explicitly rather than assumed — it
// future-proofs a translated mode, and it lets a surface *notice* if the invariant ever
// breaks (see ``MorbShareState/isSamePath``) — but today it always equals the host path,
// and no user-facing string should ever show anything else.

import Foundation

// MARK: - One shared root

/// A single shared host directory, as the CLI and the app need to render it.
///
/// Three independent facts are folded into one row here, because a user asking "why is my
/// bind mount empty" cannot be expected to know which of the three failed:
///
///   * **configured** — the path is in `shared_paths`;
///   * **planned** — the host could actually share it (it exists, it is a readable
///     directory, it is not shadowed by an outer share). ``skippedReason`` says why not;
///   * **mounted** — the guest ran `mount -t virtiofs` and it worked. ``error`` says why
///     not.
public struct MorbShareState: Equatable, Sendable, Codable {

    /// The host path, normalised. In the same-path design this is also the guest mount
    /// point, and it is the only path a user is ever shown.
    public var path: String

    /// The VirtioFS device tag (`morbshare0`, `morbshare1`, …), or `""` for a configured
    /// root that never made it into the plan and so was never given one.
    ///
    /// An internal identifier, surfaced only in JSON output and diagnostics. It is
    /// deliberately *not* a path component: see the file header.
    public var tag: String

    /// Whether the guest mounted this share read-only.
    ///
    /// Daemon-reported and mount-level. Deliberately *not* inferred from host
    /// permissions: `access("/Users", W_OK)` is false on every stock Mac, because nobody
    /// creates files directly in `/Users` — while `/Users/you/project`, the directory
    /// anyone actually bind-mounts, is perfectly writable. Presenting the root's mode as
    /// the share's access mode labels the single most common share on every machine
    /// "read-only" and is simply false. See ``rootWritable`` for the honest, narrower
    /// version of that fact.
    public var readOnly: Bool

    /// Whether the root is named in `shared_paths`.
    ///
    /// Almost always `true`. A `false` means the guest reported a mount the config does
    /// not ask for — worth showing rather than hiding, because it is either a stale guest
    /// or a config edit that has not been applied by a restart.
    public var configured: Bool

    /// Whether the guest currently has it mounted.
    public var mounted: Bool

    /// Where the guest sees it. Equal to ``path`` in the same-path design.
    public var guestPath: String

    /// Whether this process can create entries in the root directory *itself*.
    ///
    /// `nil` when nobody checked. Narrow on purpose, and not the same question as "can a
    /// container write to this bind mount": it says nothing about the directories
    /// underneath, which is where every real bind mount points. Useful as a diagnostic
    /// for a share the guest mounted but cannot write to, and misleading as a headline —
    /// which is why no surface renders it as an access mode.
    public var rootWritable: Bool?

    /// Why the host left this root out of the sharing plan, when it did.
    public var skippedReason: String?

    /// Why the guest failed to mount it, when it said.
    public var error: String?

    public init(
        path: String,
        tag: String = "",
        readOnly: Bool = false,
        configured: Bool = true,
        mounted: Bool = false,
        guestPath: String? = nil,
        rootWritable: Bool? = nil,
        skippedReason: String? = nil,
        error: String? = nil
    ) {
        self.path = path
        self.tag = tag
        self.readOnly = readOnly
        self.configured = configured
        self.mounted = mounted
        self.rootWritable = rootWritable
        // Defaulting to `path` encodes the same-path invariant at the one place a value
        // is created without the daemon having spoken.
        self.guestPath = guestPath ?? path
        self.skippedReason = skippedReason
        self.error = error
    }

    /// `true` when the user asked for this root and the guest does not have it.
    ///
    /// The single predicate behind `morb shares`' warning line and the app's status chip.
    /// Deliberately true for a root that was skipped for a perfectly good reason — a
    /// `/Volumes` that does not exist is still a bind mount that will come up empty, and
    /// the reason belongs in the explanation rather than in the decision.
    public var isDegraded: Bool { configured && !mounted }

    /// `true` while the same-path invariant holds, which is always, today.
    ///
    /// Surfaces show ``path`` alone when this is `true` and mention the guest path only
    /// when it is not — so a future translated mode degrades into extra detail rather
    /// than into a lie.
    public var isSamePath: Bool { guestPath == path }

    /// One short phrase for the state column.
    ///
    /// Read-only rides along with the state rather than occupying a column of its own:
    /// with no `read_only` key in the config it is the rare case, and a column that says
    /// `read-write` on every row of every machine is three characters of noise where a
    /// warning should be able to stand out.
    public var stateDescription: String {
        if mounted { return readOnly ? "mounted (read-only)" : "mounted" }
        if skippedReason != nil { return "skipped" }
        return "not mounted"
    }

    /// The fullest one-line explanation available for a root that is not mounted.
    public var explanation: String? {
        if mounted { return nil }
        if let skippedReason, !skippedReason.isEmpty { return skippedReason }
        if let error, !error.isEmpty { return error }
        return nil
    }
}

// MARK: - Rosetta

/// What is known about Rosetta, from the host's point of view and the guest's.
///
/// Four independent facts rather than one enum, because they fail independently and the
/// remedies differ: Rosetta absent from the host is a download, `rosetta = false` in the
/// config is an edit, and a share that is present but whose `binfmt_misc` handler never
/// registered is a guest bug worth reporting rather than something a user can fix.
public struct MorbRosettaState: Equatable, Sendable, Codable {

    /// Whether the host has Rosetta installed and can expose it to a VM.
    public var installed: Bool

    /// Whether `rosetta = true` in `config.toml`.
    public var enabledInConfig: Bool

    /// Whether the guest currently has the Rosetta share mounted, or `nil` when the guest
    /// has not answered — no VM running, or one too old to report it.
    ///
    /// Optional rather than defaulted to `false` for the reason the daemon carries it as
    /// a nullable too: "the VM is not running so we cannot know" and "the VM is running
    /// and Rosetta is broken" call for opposite advice, and collapsing them into `false`
    /// is how a status display tells somebody to reinstall Rosetta when all they have to
    /// do is start the engine.
    public var activeInGuest: Bool?

    /// Whether the guest registered Rosetta as the `x86_64` interpreter, or `nil` when
    /// the guest has not answered. Same tri-state reasoning as ``activeInGuest``.
    public var binfmtRegistered: Bool?

    /// Anything the daemon or the host check wanted to add — typically why one of the
    /// above is `false`.
    public var note: String?

    /// `true` on a host where Rosetta cannot exist at all (Intel, or an OS that does not
    /// offer the directory share). Distinguished from "not installed" because there is
    /// nothing to suggest the user do about it.
    public var supported: Bool

    public init(
        installed: Bool = false,
        enabledInConfig: Bool = true,
        activeInGuest: Bool? = nil,
        binfmtRegistered: Bool? = nil,
        note: String? = nil,
        supported: Bool = true
    ) {
        self.installed = installed
        self.enabledInConfig = enabledInConfig
        self.activeInGuest = activeInGuest
        self.binfmtRegistered = binfmtRegistered
        self.note = note
        self.supported = supported
    }

    /// The one thing worth saying about Rosetta right now.
    public enum Availability: String, Equatable, Sendable {
        /// Mounted in the guest and registered — `amd64` images run.
        case active
        /// Installed on the host and switched on, but the guest is not using it yet
        /// (typically: the VM is not running, or it needs a restart).
        case ready
        /// Installed, but `rosetta = false` in the config.
        case disabled
        /// The host could have it and does not.
        case notInstalled
        /// The host cannot have it.
        case unsupported
    }

    /// Whether the guest has said anything about Rosetta at all.
    public var guestAnswered: Bool { activeInGuest != nil || binfmtRegistered != nil }

    /// `true` only when the guest positively confirmed both halves. An unanswered guest
    /// is not a broken one.
    public var isActive: Bool { activeInGuest == true && binfmtRegistered == true }

    public var availability: Availability {
        guard supported else { return .unsupported }
        guard installed else { return .notInstalled }
        guard enabledInConfig else { return .disabled }
        return isActive ? .active : .ready
    }

    /// `true` when the host is ready, the config wants it, and the guest is running but
    /// reports it is *not* working.
    ///
    /// The one combination that is a real fault rather than a missing step, and the one
    /// whose remedy is not `morb rosetta install`: the share is attached and something
    /// downstream of it failed. Worth calling out separately wherever advice is given.
    public var isBrokenInGuest: Bool {
        availability == .ready && guestAnswered && !isActive
    }

    /// A short human phrase for a status row.
    public var summary: String {
        switch availability {
        case .active: return "active — amd64 images run under Rosetta"
        case .ready:
            return isBrokenInGuest
                ? "installed and enabled, but the guest reports it is not working"
                : "installed, not yet active in the guest"
        case .disabled: return "installed, but disabled in config.toml"
        case .notInstalled: return "not installed — amd64 images will not run"
        case .unsupported: return "not supported on this Mac"
        }
    }

    /// What to actually do about it, or `nil` when there is nothing to do.
    ///
    /// Kept next to ``summary`` so the diagnosis and the remedy cannot drift apart. The
    /// distinction that earns this its own property: a guest that says Rosetta is broken
    /// must *not* be told to install Rosetta, which is already installed.
    public var remedy: String? {
        switch availability {
        case .active: return nil
        case .ready:
            if isBrokenInGuest {
                return "Rosetta is installed and enabled, so this is not an installation "
                    + "problem. Restart the engine; if it persists, please report it."
            }
            return "Start the engine — Rosetta is attached when the VM boots."
        case .disabled:
            return "Set `rosetta = true` in config.toml, or run `morb rosetta install`, "
                + "then restart the engine."
        case .notInstalled:
            return "Run `morb rosetta install` to download Apple's Rosetta runtime."
        case .unsupported:
            return nil
        }
    }
}

// MARK: - Building the surface view

/// Assembles ``MorbShareState`` rows from the config, the sharing plan and the daemon.
public enum MorbShareSurface {

    /// Where a set of rows came from, which changes what "not mounted" means.
    ///
    /// Not cosmetic: with no daemon, *every* root reads as not mounted, and a surface
    /// that failed to distinguish "the guest says it is missing" from "there is no guest"
    /// would show three red warnings on a perfectly healthy stopped machine.
    public enum Source: String, Equatable, Sendable {
        /// The daemon answered; mount state is live.
        case daemon
        /// Reconstructed from `config.toml`; mount state is unknown and reported `false`.
        case config
    }

    /// A complete answer to "what is shared right now".
    public struct Report: Equatable, Sendable {
        public var shares: [MorbShareState]
        public var source: Source
        /// Set when `config.toml` could not be read or the plan could not be built.
        /// The rows are still populated as best they can be.
        public var configError: String?

        public init(shares: [MorbShareState], source: Source, configError: String? = nil) {
            self.shares = shares
            self.source = source
            self.configError = configError
        }

        /// The pre-bootstrap value: nothing known, and therefore nothing to warn about.
        ///
        /// `.config` rather than `.daemon` is what makes that true — an empty report from
        /// a daemon would mean "the guest has no shares", which is a claim, whereas this
        /// is the absence of one.
        public static let empty = Report(shares: [], source: .config)

        /// How many configured roots the guest does not have mounted.
        public var degradedCount: Int { shares.filter(\.isDegraded).count }

        /// How many are live.
        public var mountedCount: Int { shares.filter(\.mounted).count }

        /// `true` when there is a real warning to show — which requires a daemon to have
        /// said so. A stopped engine is not a degraded engine.
        public var hasWarning: Bool { source == .daemon && degradedCount > 0 }
    }

    /// The `config.toml` key listing the shared roots.
    ///
    /// Named here so the CLI's hint text and Settings' "edit this key" line cannot drift
    /// from what ``MorbConfig`` actually parses.
    public static let sharedPathsKey = "shared_paths"

    // MARK: Host-side reconstruction

    /// Builds rows from a configuration alone, with no guest to ask.
    ///
    /// Runs the same ``MorbShares/plan(paths:probe:)`` the daemon boots with, so the tags
    /// and the skip reasons shown here are the ones that would be used for real. Anything
    /// the planner rejected outright (a relative path, `/`, too many entries) is reported
    /// against every row through ``Report/configError`` rather than silently dropping the
    /// list — a surface must never be the thing that fails.
    public static func configuredShares(
        config: MorbConfig,
        probe: (String) -> MorbShares.RootStatus = MorbShares.probeRoot,
        writable: (String) -> Bool = MorbShares.isWritable
    ) -> Report {
        let normalised = config.sharedPaths.map(MorbShares.normalise).filter { !$0.isEmpty }

        let plan: MorbShares.Plan
        var configError: String?
        do {
            plan = try MorbShares.plan(paths: config.sharedPaths, probe: probe)
        } catch {
            // A config the daemon would refuse to boot. Still worth rendering: this is
            // precisely when somebody opens Settings or runs `morb shares` to find out
            // what is wrong, and an empty list would tell them nothing.
            configError = (error as? MorbError)?.description ?? error.localizedDescription
            plan = MorbShares.Plan()
        }

        let tags = Dictionary(uniqueKeysWithValues: plan.shares.map { ($0.path, $0.tag) })
        let skips = Dictionary(plan.skipped.map { ($0.path, $0.reason) }, uniquingKeysWith: { first, _ in first })

        var seen = Set<String>()
        let rows = normalised.compactMap { path -> MorbShareState? in
            guard seen.insert(path).inserted else { return nil }
            return MorbShareState(
                path: path,
                tag: tags[path] ?? "",
                configured: true,
                mounted: false,
                rootWritable: writable(path),
                skippedReason: skips[path])
        }
        return Report(shares: rows, source: .config, configError: configError)
    }

    /// Builds rows from `config.toml` on disk.
    public static func configuredShares(fromFile url: URL = MorbPaths.configFile) -> Report {
        do {
            return configuredShares(config: try MorbConfig.load(from: url))
        } catch {
            var report = configuredShares(config: MorbConfig())
            report.configError = (error as? MorbError)?.description ?? error.localizedDescription
            return report
        }
    }

    // MARK: Daemon replies

    /// Decodes the daemon's `shares` reply.
    ///
    /// Returns `nil` when the payload carries no `shares` array at all, which a caller
    /// reads as "this daemon does not know about shares" and answers from the config
    /// instead. An empty array is a real answer and comes back as `[]`.
    public static func decodeShares(_ data: [String: AnyCodableValue]?) -> [MorbShareState]? {
        guard let data, case .array(let entries)? = data["shares"] else { return nil }
        return entries.compactMap { entry in
            guard case .object(let fields) = entry else { return nil }
            func string(_ key: String) -> String? {
                if case .string(let value)? = fields[key], !value.isEmpty { return value }
                return nil
            }
            func flag(_ key: String, default fallback: Bool) -> Bool {
                if case .bool(let value)? = fields[key] { return value }
                return fallback
            }
            guard let path = string("path") else { return nil }
            return MorbShareState(
                path: path,
                tag: string("tag") ?? "",
                readOnly: flag("read_only", default: false),
                configured: flag("configured", default: true),
                mounted: flag("mounted", default: false),
                guestPath: string("guest_path"),
                rootWritable: { if case .bool(let value)? = fields["root_writable"] { return value }; return nil }(),
                skippedReason: string("skipped_reason"),
                error: string("error"))
        }
    }

    /// Combines what the host knows about Rosetta with what the guest reported.
    ///
    /// The host is authoritative about installation and the config is authoritative about
    /// intent — the daemon can only ever be echoing those two back — so a live reply
    /// contributes just the two facts it alone has: whether the share is mounted and
    /// whether `binfmt_misc` took. That ordering matters after `morb rosetta install`,
    /// when the host has Rosetta and a still-running daemon booted without it.
    ///
    /// ``RosettaState/unknown`` is folded into "not supported": the enum's own contract is
    /// that an availability this build does not recognise is assumed not to work, and
    /// offering an install for it would be offering something that cannot succeed.
    public static func rosetta(
        host: RosettaState,
        enabledInConfig: Bool,
        live: MorbRosettaState?
    ) -> MorbRosettaState {
        MorbRosettaState(
            installed: host == .installed,
            enabledInConfig: enabledInConfig,
            activeInGuest: live?.activeInGuest,
            binfmtRegistered: live?.binfmtRegistered,
            note: live?.note ?? (host == .installed ? nil : host.detail),
            supported: host != .notSupported && host != .unknown)
    }

    /// Decodes the daemon's `rosetta` reply.
    ///
    /// `supported` is not on the wire — the daemon reports it only indirectly, by saying
    /// Rosetta is not installed on a host that could never have it — so callers pass what
    /// the host check told them and this preserves it.
    public static func decodeRosetta(
        _ data: [String: AnyCodableValue]?,
        supported: Bool = true
    ) -> MorbRosettaState? {
        guard let data else { return nil }
        // Any one of the four keys makes this a real answer; a reply with none of them is
        // a daemon that does not implement the command.
        let keys = ["installed", "enabled_in_config", "active_in_guest", "binfmt_registered"]
        guard keys.contains(where: { data[$0] != nil }) else { return nil }

        func flag(_ key: String, default fallback: Bool) -> Bool {
            if case .bool(let value)? = data[key] { return value }
            return fallback
        }
        // Tri-state on purpose. The daemon sends `null` for these two when the guest has
        // not answered, and reading that as `false` would turn "the VM is not running"
        // into "Rosetta is broken" — the one misreading that sends a user off to
        // reinstall software that is already installed.
        func triState(_ key: String) -> Bool? {
            if case .bool(let value)? = data[key] { return value }
            return nil
        }
        var note: String?
        if case .string(let value)? = data["note"], !value.isEmpty { note = value }

        return MorbRosettaState(
            installed: flag("installed", default: false),
            enabledInConfig: flag("enabled_in_config", default: true),
            activeInGuest: triState("active_in_guest"),
            binfmtRegistered: triState("binfmt_registered"),
            note: note,
            supported: supported)
    }

    /// Lays the daemon's live view over the configured one.
    ///
    /// The configured list is the spine: a root the user asked for must appear even if
    /// the guest never mentioned it, because *that is the interesting case* — it is
    /// exactly the "configured but not mounted" state the warning exists for. A root the
    /// guest reports and the config does not ask for is appended with `configured: false`
    /// rather than dropped.
    public static func merge(configured: [MorbShareState], live: [MorbShareState]) -> [MorbShareState] {
        var byPath: [String: MorbShareState] = [:]
        for share in live { byPath[share.path] = share }

        var merged: [MorbShareState] = configured.map { base in
            guard var found = byPath.removeValue(forKey: base.path) else { return base }
            found.configured = true
            // The daemon's tag is what the guest was actually told; the config-derived
            // one is a reconstruction. Prefer the daemon's whenever it said one, and keep
            // the host-side skip reason, which the guest has no way to know.
            if found.tag.isEmpty { found.tag = base.tag }
            if found.skippedReason == nil { found.skippedReason = base.skippedReason }
            if found.rootWritable == nil { found.rootWritable = base.rootWritable }
            return found
        }
        merged.append(contentsOf: byPath.values.sorted { $0.path < $1.path })
        return merged
    }

    /// Folds a live reply into a configured report, producing the answer a surface shows.
    public static func report(
        configured: Report,
        live: [MorbShareState]?
    ) -> Report {
        guard let live else { return configured }
        return Report(
            shares: merge(configured: configured.shares, live: live),
            source: .daemon,
            configError: configured.configError)
    }

    /// Turns rows back into the daemon's wire shape, for `morb shares --json`.
    ///
    /// The CLI's JSON output is the same document whether it came from a daemon or from
    /// the config, which is what lets a script treat `morb shares --json` as one format
    /// rather than two.
    public static func encode(_ shares: [MorbShareState]) -> AnyCodableValue {
        .array(shares.map { share in
            .object([
                "path": .string(share.path),
                "tag": .string(share.tag),
                "read_only": .bool(share.readOnly),
                "configured": .bool(share.configured),
                "mounted": .bool(share.mounted),
                "guest_path": .string(share.guestPath),
                "root_writable": share.rootWritable.map { AnyCodableValue.bool($0) } ?? .null,
                "skipped_reason": share.skippedReason.map { AnyCodableValue.string($0) } ?? .null,
                "error": share.error.map { AnyCodableValue.string($0) } ?? .null,
            ])
        })
    }

    /// The `shares_degraded` count the daemon puts in its `status` reply.
    ///
    /// The app polls `status` anyway, so this is the whole warning chip for the price of
    /// a field already on the wire. Returns `nil` when the daemon did not say, which must
    /// not be rendered as zero: "no warning" and "no information" look identical on
    /// screen and are not the same thing.
    public static func degradedCount(inStatus data: [String: AnyCodableValue]?) -> Int? {
        guard let data else { return nil }
        switch data["shares_degraded"] {
        case .int(let value): return value
        case .double(let value): return Int(value)
        default: return nil
        }
    }
}
