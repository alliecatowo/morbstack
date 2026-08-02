// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Which CPU an image was built for, and whether that is going to hurt.
//
// On Apple silicon an `amd64` image does run — Rosetta translates it — but it is not
// the same as running an `arm64` one, and the difference is invisible everywhere else
// in the tooling. `docker pull nginx` on a Mac fetches the arm64 variant; `docker pull
// some/legacy-tool` may fetch amd64 because that is all the publisher ships, and a
// `docker compose up` inherited from a colleague may pin `platform: linux/amd64`
// explicitly. All three produce a container that starts, works, and is quietly slower
// and occasionally subtly broken — JIT runtimes, anything that reads `/proc/cpuinfo`,
// and a long tail of AVX-dependent binaries.
//
// So the Images list badges it. The badge exists to be *noticed once* and then ignored:
// an arm64 image on an arm64 Mac gets no badge at all, because a badge on every row is
// wallpaper. Only the mismatch is worth ink.
//
// Where the data comes from is a two-step affair, and both steps are here:
//
//   1. `GET /images/json` carries an OCI `Descriptor` whose `platform` is populated for
//      images pulled from a multi-arch index — which is most of them. Free, no extra
//      request, arrives with the list.
//   2. Anything still unknown after that (single-manifest images, images built locally
//      by BuildKit, older engines) is resolved by inspecting the one image the user
//      selected. One request, on demand, for the row they are actually looking at.

import Foundation

// MARK: - Platform

/// The OS/architecture pair an image was built for.
struct ImageArchitecture: Sendable, Hashable, Codable {

    /// `linux`, essentially always.
    var os: String
    /// `arm64`, `amd64`, `arm`, `386`, `s390x`, …
    var arch: String
    /// `v7`, `v8` — the ARM sub-revision, absent for everything else.
    var variant: String?

    init(os: String, arch: String, variant: String? = nil) {
        self.os = os.lowercased()
        self.arch = ImageArchitecture.canonical(arch)
        let trimmed = variant?.lowercased()
        self.variant = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// Docker's own spelling for the values Go and OCI disagree about.
    ///
    /// The engine reports `amd64`/`arm64` in inspect documents, but registries, some
    /// buildx output and `uname` all say `x86_64` and `aarch64`. Two spellings of one
    /// architecture would badge the same image differently depending on which endpoint
    /// answered, which is the sort of inconsistency that makes people distrust the
    /// whole column.
    static func canonical(_ arch: String) -> String {
        switch arch.lowercased() {
        case "x86_64", "x86-64": return "amd64"
        case "aarch64": return "arm64"
        case "i386", "i686", "x86": return "386"
        case "armv7l", "armv7": return "arm"
        default: return arch.lowercased()
        }
    }

    /// `arm64`, `arm/v7`. The OS is left out — everything here is Linux, and a column
    /// of `linux/` prefixes carries no information.
    var shortName: String {
        guard let variant else { return arch }
        return "\(arch)/\(variant)"
    }

    /// `linux/arm64/v8` — the full form, for tooltips and the detail popover, and the
    /// exact string somebody would paste into `--platform`.
    var platformString: String {
        var parts = [os.isEmpty ? "linux" : os, arch]
        if let variant { parts.append(variant) }
        return parts.joined(separator: "/")
    }

    /// The architecture of the Mac this app is running on, in Docker's spelling.
    ///
    /// Resolved at compile time. The app is a native arm64 or x86_64 binary either way,
    /// and a translated app reporting its translated architecture is the right answer:
    /// what matters is what the *guest kernel* is, and the guest matches the silicon.
    static var host: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }
}

// MARK: - Badging

/// Decides what, if anything, to say about an image's architecture.
enum TrackCImageArch {

    /// What the Images list should show for one image.
    enum Badge: Equatable, Sendable {

        /// Built for this Mac. Shown quietly, or not at all in the list.
        case native(String)
        /// Built for x86-64 and will run under Rosetta translation.
        case translated(String)
        /// Neither native nor translatable — `arm/v7`, `386`, `s390x`.
        case foreign(String)

        /// The badge text.
        var text: String {
            switch self {
            case .native(let name), .translated(let name), .foreign(let name): return name
            }
        }

        var tone: TrackCTone {
            switch self {
            case .native: return .neutral
            case .translated: return .warn
            case .foreign: return .bad
            }
        }

        var symbol: String? {
            switch self {
            case .native: return nil
            case .translated: return "arrow.triangle.2.circlepath"
            case .foreign: return "exclamationmark.triangle.fill"
            }
        }

        /// A word for the *consequence* rather than the platform.
        ///
        /// Used where the platform string is already on screen — the detail popover
        /// shows `linux/amd64`, so a badge repeating `amd64` next to it would be noise;
        /// what it needs to add is what that costs.
        var consequenceLabel: String? {
            switch self {
            case .native: return nil
            case .translated: return "translated"
            case .foreign: return "unsupported"
            }
        }

        /// Whether the list row draws a badge at all.
        ///
        /// A native image is the overwhelming majority and gets plain text: the badge
        /// exists to flag the exceptions, and one that appears on every row stops
        /// being read by the second screenful.
        var isNoteworthy: Bool {
            switch self {
            case .native: return false
            case .translated, .foreign: return true
            }
        }
    }

    /// The set of architectures Rosetta can translate for a Linux guest.
    ///
    /// Just the one. Rosetta translates x86-64 user-space binaries and nothing else —
    /// not 32-bit x86, not any flavour of ARM that is not the host's.
    static let translatableArchitectures: Set<String> = ["amd64"]

    /// The badge for `architecture`, or `nil` when it is not known yet.
    ///
    /// `nil` in, `nil` out, on purpose: an image whose platform has not been fetched
    /// must render as *nothing*, never as "native". Assuming the common case would put
    /// a reassuring blank where the amd64 warning belongs, on exactly the rows that are
    /// slowest to resolve.
    static func badge(
        for architecture: ImageArchitecture?,
        hostArch: String = ImageArchitecture.host
    ) -> Badge? {
        guard let architecture, !architecture.arch.isEmpty else { return nil }
        let host = ImageArchitecture.canonical(hostArch)
        if architecture.arch == host {
            // A variant mismatch within the same architecture is not worth a warning:
            // arm64/v8 and bare arm64 are the same thing to the kernel.
            return .native(architecture.shortName)
        }
        if translatableArchitectures.contains(architecture.arch) {
            return .translated(architecture.shortName)
        }
        return .foreign(architecture.shortName)
    }

    /// The sentence shown under the badge in the image detail popover.
    ///
    /// The `rosettaAvailable` argument is what turns a performance note into a hard
    /// warning: an amd64 image on a Mac without Rosetta does not run slowly, it does not
    /// run at all, and it fails with `exec format error` — a message that tells the user
    /// nothing about what to do.
    static func advice(
        for badge: Badge?,
        rosettaAvailable: Bool
    ) -> String? {
        switch badge {
        case .none:
            return nil
        case .native:
            return nil
        case .translated(let name):
            if rosettaAvailable {
                return "This image is \(name) and runs through Rosetta translation. It works, "
                    + "but it starts slower and runs slower than a native arm64 build, and a few "
                    + "runtimes misbehave under translation. If the publisher ships an arm64 "
                    + "variant, prefer it."
            }
            return "This image is \(name) and Rosetta is not available, so it will fail to "
                + "start with `exec format error`. Run `morb rosetta install`, or use an arm64 "
                + "variant of the image."
        case .foreign(let name):
            return "This image is \(name), which this Mac cannot run natively and Rosetta "
                + "cannot translate. Containers created from it will fail with "
                + "`exec format error`."
        }
    }

    /// How many images in a list are not native to this Mac.
    ///
    /// Drives the Images header's subtitle. Images with an unknown architecture are not
    /// counted — a number that grows as lazily-fetched rows resolve would look like the
    /// situation is deteriorating while the user watches.
    static func nonNativeCount(
        _ images: [ImageSummary],
        hostArch: String = ImageArchitecture.host
    ) -> Int {
        images.filter { image in
            guard let badge = badge(for: image.architecture, hostArch: hostArch) else { return false }
            return badge.isNoteworthy
        }.count
    }
}
