// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// What a container's mounts actually mean, kept out of the view so it can be tested.
//
// The Overview tab used to render `Mounts` as four strings from the inspect document,
// which is honest and nearly useless: the three kinds Docker lumps together behave
// completely differently, and the difference is the thing people are looking at the
// table to find out.
//
//   * A **bind** mount is a directory on the user's Mac. It is the only kind with a
//     path they can open in Finder, and the only kind that can be *silently wrong*: if
//     the host path is not inside one of Morbstack's shared roots, the guest has no
//     such directory, `dockerd` creates an empty one, and the container starts happily
//     with none of the files in it. No error is reported anywhere — not by Docker, not
//     by Morbstack — so this table is the only place that failure can be caught, and
//     detecting it is why this file exists.
//   * A **volume** lives inside the VM's disk image. Its `Source` is a guest path
//     (`/var/lib/docker/volumes/…`) that does not exist on the Mac, so offering to
//     reveal it would open a Finder window on nothing.
//   * A **tmpfs** mount is guest RAM. It has no source at all and nothing survives a
//     restart.
//
// The same-path invariant is what makes the bind case tractable: a shared directory is
// visible in the guest at its identical absolute path, so the `Source` Docker reports
// for a bind mount *is* a host path, with no translation table in between. If that
// invariant ever changes, this file is where it breaks first and visibly.

import Foundation
import MorbstackKit

// MARK: - Kind

/// Docker's mount types, narrowed to the ones a Morbstack user can encounter.
enum TrackBMountKind: String, CaseIterable, Sendable, Hashable {

    /// A directory on the host, shared into the guest.
    case bind
    /// A Docker-managed volume inside the VM's disk image.
    case volume
    /// A RAM-backed filesystem in the guest.
    case tmpfs
    /// A named pipe. Windows-only in practice; carried so it renders as itself rather
    /// than as an unexplained blank.
    case npipe
    /// A Swarm cluster volume.
    case cluster
    /// An image-backed mount (`--mount type=image`), added in Engine 28.
    case image
    /// Something this build has not heard of.
    case unknown

    /// Classifies the `Type` field of an inspect document's mount entry.
    ///
    /// An unrecognised type becomes ``unknown`` rather than being coerced to `bind`,
    /// which is what the previous rendering did by default. Guessing `bind` is the one
    /// wrong answer available: it is the only kind that offers a Finder button, and
    /// offering to reveal a path that is not a host path is worse than saying nothing.
    init(rawKind: String) {
        self = TrackBMountKind(rawValue: rawKind.lowercased()) ?? .unknown
    }

    /// The badge text. Short, lowercase, and the same word Docker uses, so it matches
    /// what `docker inspect` and the compose file say.
    var label: String {
        switch self {
        case .unknown: return "mount"
        default: return rawValue
        }
    }

    var symbol: String {
        switch self {
        case .bind: return "folder"
        case .volume: return "externaldrive"
        case .tmpfs: return "memorychip"
        case .npipe: return "cable.connector"
        case .cluster: return "square.stack.3d.up"
        case .image: return "square.on.square"
        case .unknown: return "questionmark.square.dashed"
        }
    }

    /// The badge tint. Only `bind` is tinted: it is the kind whose contents come from
    /// outside the VM, and the one whose row may carry a warning. Colouring all three
    /// would make the table a fruit salad and cost the distinction its meaning.
    var tone: TrackCTone {
        switch self {
        case .bind: return .accent
        default: return .neutral
        }
    }

    /// Whether ``TrackBMountDisplay/source`` names a directory on the user's Mac.
    var sourceIsHostPath: Bool { self == .bind }

    /// One sentence, for the badge's tooltip.
    var explanation: String {
        switch self {
        case .bind:
            return "A folder on your Mac, shared into the VM at the same path."
        case .volume:
            return "Docker-managed storage inside the VM's disk image. It is not a folder on your Mac."
        case .tmpfs:
            return "A RAM disk inside the VM. Its contents are lost when the container stops."
        case .npipe:
            return "A named pipe."
        case .cluster:
            return "A Swarm cluster volume."
        case .image:
            return "A read-only filesystem taken from an image."
        case .unknown:
            return "A mount type this version of Morbstack does not recognise."
        }
    }
}

// MARK: - One rendered mount

/// Everything the Mounts table needs about one mount, already decided.
struct TrackBMountDisplay: Identifiable, Equatable, Sendable {

    let id: String
    let kind: TrackBMountKind

    /// The badge text: the engine's own word for the type.
    ///
    /// Carried rather than derived from ``kind`` so that a type this build has never
    /// heard of still displays as itself. Rendering a `cluster` mount as `mount` would
    /// hide the one string the user needs in order to go and look it up.
    let kindLabel: String

    /// What to show in the source column: a host path, a volume name, or `—`.
    let source: String

    /// The path inside the container.
    let destination: String

    let readOnly: Bool

    /// The path to hand to Finder, or `nil` when there is nothing on this Mac to open.
    let hostPath: String?

    /// Whether a bind mount's host path is covered by a configured shared root.
    ///
    /// `nil` for every non-bind kind, and for a bind mount when the share list is not
    /// known — which is not the same as `false`. An app that has not yet heard from the
    /// daemon must not accuse a perfectly good mount of being broken.
    let isShared: Bool?

    /// The problem with this mount, when there is one worth interrupting the user for.
    let warning: String?

    var accessDescription: String { readOnly ? "read-only" : "read-write" }
}

// MARK: - Classification

/// Turns inspect-document mounts into rows, given what is known about file sharing.
enum TrackBMountModel {

    /// Builds the display rows for a container's mounts.
    ///
    /// - Parameters:
    ///   - mounts: the parsed `Mounts` array from the inspect document.
    ///   - shares: the configured shared roots, or an empty array when unknown.
    ///   - sharesAreKnown: whether `shares` is a real answer. `false` suppresses every
    ///     "not shared" warning, because the app cannot tell the difference between a
    ///     path outside the shares and a share list it has not been told yet.
    static func rows(
        mounts: [TrackBInspectDetails.Mount],
        shares: [MorbShareState],
        sharesAreKnown: Bool
    ) -> [TrackBMountDisplay] {
        mounts.map { row(for: $0, shares: shares, sharesAreKnown: sharesAreKnown) }
    }

    /// Builds one row.
    static func row(
        for mount: TrackBInspectDetails.Mount,
        shares: [MorbShareState],
        sharesAreKnown: Bool
    ) -> TrackBMountDisplay {
        let kind = TrackBMountKind(rawKind: mount.kind)
        let kindLabel = kind == .unknown && !mount.kind.isEmpty ? mount.kind : kind.label

        switch kind {
        case .bind:
            let path = normalise(mount.source)
            let covering = sharesAreKnown ? coveringShare(for: path, in: shares) : nil
            let isShared = sharesAreKnown ? (covering != nil) : nil

            var warning: String?
            if path.isEmpty {
                warning = "This bind mount has no source path."
            } else if sharesAreKnown, covering == nil {
                warning =
                    "\(path) is not inside a shared folder, so the VM cannot see it. "
                    + "The container is reading an empty directory, and anything it writes "
                    + "there stays inside the VM. Add the folder in Settings › File Sharing "
                    + "and restart the engine."
            } else if let covering, covering.readOnly, !mount.readOnly {
                warning =
                    "\(covering.path) is shared read-only, so writes from the container "
                    + "will fail even though the mount asks for read-write."
            } else if let covering, !covering.mounted, covering.configured {
                warning =
                    "\(covering.path) is configured for sharing but is not mounted in the "
                    + "VM right now, so this directory is empty inside the container."
            }

            return TrackBMountDisplay(
                id: mount.id,
                kind: kind,
                kindLabel: kindLabel,
                source: path.isEmpty ? "—" : path,
                destination: mount.destination,
                readOnly: mount.readOnly,
                // Offered even for an unshared path: the folder exists on the Mac and
                // opening it is exactly how somebody checks whether it is the one they
                // meant. The warning explains why the container cannot see it.
                hostPath: path.isEmpty ? nil : path,
                isShared: isShared,
                warning: warning)

        case .volume:
            // The name, not the mountpoint: `/var/lib/docker/volumes/pgdata/_data` is a
            // path inside the VM, and showing it invites people to look for it on their
            // Mac. The name is also what `docker volume` commands take.
            let name = mount.name ?? mount.source
            return TrackBMountDisplay(
                id: mount.id,
                kind: kind,
                kindLabel: kindLabel,
                source: name.isEmpty ? "—" : name,
                destination: mount.destination,
                readOnly: mount.readOnly,
                hostPath: nil,
                isShared: nil,
                warning: nil)

        case .tmpfs:
            return TrackBMountDisplay(
                id: mount.id,
                kind: kind,
                kindLabel: kindLabel,
                source: "—",
                destination: mount.destination,
                readOnly: mount.readOnly,
                hostPath: nil,
                isShared: nil,
                warning: nil)

        default:
            let name = mount.name ?? mount.source
            return TrackBMountDisplay(
                id: mount.id,
                kind: kind,
                kindLabel: kindLabel,
                source: name.isEmpty ? "—" : name,
                destination: mount.destination,
                readOnly: mount.readOnly,
                hostPath: nil,
                isShared: nil,
                warning: nil)
        }
    }

    // MARK: Paths

    /// Expands `~` and standardises, without touching the filesystem.
    ///
    /// Symlinks are deliberately *not* resolved here: this runs on every row of every
    /// container's detail pane, and `resolvingSymlinksInPath` is a `stat` per component.
    /// The daemon resolves the share list, and the engine reports bind sources already
    /// resolved, so both sides of the comparison are normally resolved anyway.
    static func normalise(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        var expanded = (path as NSString).expandingTildeInPath
        expanded = (expanded as NSString).standardizingPath
        while expanded.count > 1, expanded.hasSuffix("/") { expanded.removeLast() }
        return expanded
    }

    /// Whether `path` is `root` or lives underneath it.
    ///
    /// Compares whole path components. A plain `hasPrefix` says `/Users/al/Dev` is
    /// inside `/Users/al/De`, which would report a perfectly broken mount as fine.
    static func path(_ path: String, isWithin root: String) -> Bool {
        let path = normalise(path)
        let root = normalise(root)
        guard !path.isEmpty, !root.isEmpty else { return false }
        if path == root { return true }
        if root == "/" { return path.hasPrefix("/") }
        return path.hasPrefix(root + "/")
    }

    /// The shared root covering `path`, preferring the most specific one.
    ///
    /// Specificity matters when roots nest: with `/Users` and `/Users/you/work` both
    /// shared and only the latter read-only, a mount under `work` must be judged against
    /// `work`, not against `/Users`.
    static func coveringShare(for path: String, in shares: [MorbShareState]) -> MorbShareState? {
        shares
            .filter { self.path(path, isWithin: $0.path) }
            .max { $0.path.count < $1.path.count }
    }

    /// The mounts worth drawing attention to, in table order.
    static func warnings(_ rows: [TrackBMountDisplay]) -> [TrackBMountDisplay] {
        rows.filter { $0.warning != nil }
    }
}
