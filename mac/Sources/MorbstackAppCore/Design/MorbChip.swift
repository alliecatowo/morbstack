// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Chips: the small pills that carry a count, a driver name, a compose project, a port.
//
// Chips are where the current build loses its hierarchy. Thirty-three indigo port pills
// are visible in one screenshot of the containers list, and they are the loudest thing on
// the screen — louder than the one unhealthy container, which is the only fact on that
// screen anybody urgently needs. So this file offers *ranked* chips, and the ranking is
// the API: you cannot make a quiet fact loud without typing the word `.loud`.

import SwiftUI

// MARK: - Rank

/// How much attention a chip is allowed to take.
///
/// Replaces `Chip(text:tone:symbol:)`'s single free-form `tone`, which let any call site
/// paint any chip any colour and is how the port pills ended up shouting.
enum MorbChipRank: Sendable, Hashable {

    /// Metadata: a compose service name, a network driver, a tag. `.secondary` text on a
    /// `.quaternary` fill. **This is the default and most chips should be this.**
    case quiet

    /// A fact the user might act on: a published port, an architecture that needs
    /// emulation. `Theme.accent` on a 12% tint of itself.
    case actionable

    /// A status. The tone's colour on a 12% tint of itself.
    case status(StatusTone)

    /// Identity: the mark, the selected thing. `Theme.brand`.
    case brand

    /// Escape hatch for the legacy `Chip(text:tone:)` call sites, which chose their own
    /// colour. Not for new code — a chip whose colour is picked locally is a chip outside
    /// the hierarchy, and thirty-three of them is how the containers list ended up
    /// shouting about ports.
    case custom(Color)
}

// MARK: - Chip

/// A small pill: a count, a driver name, a compose project, a port mapping.
///
/// Replaces the free-standing `Chip` in `Theme.swift`, which is now a forward to this.
/// Three things are new: the rank system above, the mandatory monospaced digits, and a
/// height that is derived from ``Theme/rowStandard`` rather than from whatever padding
/// looked right, so a chip inside a 32pt table row never makes it 34pt.
struct MorbChip: View {

    var text: String
    var symbol: String?
    var rank: MorbChipRank = .quiet
    /// Render `text` monospaced. On for anything containing a number the user might read
    /// character by character: a port, a short digest, a count.
    var monospaced: Bool = false

    @Environment(\.colorSchemeContrast) private var contrast

    init(_ text: String,
         symbol: String? = nil,
         rank: MorbChipRank = .quiet,
         monospaced: Bool = false) {
        self.text = text
        self.symbol = symbol
        self.rank = rank
        self.monospaced = monospaced
    }

    /// Compatibility initialiser for the legacy `Chip(text:tone:symbol:)` call sites.
    ///
    /// Maps a free-form colour onto ``MorbChipRank/quiet`` unless it is one the design
    /// system recognises. New code names a rank.
    init(_ text: String, symbol: String? = nil, tone: Color) {
        self.text = text
        self.symbol = symbol
        self.rank = .custom(tone)
        self.monospaced = false
    }

    var body: some View {
        HStack(spacing: Theme.space1 + 1) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(monospaced
                      ? .system(.caption2, design: .monospaced)
                      : .caption2.weight(.medium))
        }
        .monospacedDigit()
        .lineLimit(1)
        .foregroundStyle(foreground)
        .padding(.horizontal, Theme.space3 - 2)
        .padding(.vertical, Theme.space1)
        .background(background, in: RoundedRectangle(cornerRadius: Theme.radiusChip,
                                                     style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var foreground: AnyShapeStyle {
        switch rank {
        case .quiet: return AnyShapeStyle(.secondary)
        case .actionable: return AnyShapeStyle(Theme.accent)
        case .status(let tone): return tone == .idle
            ? AnyShapeStyle(.secondary) : AnyShapeStyle(tone.color)
        case .brand: return AnyShapeStyle(Theme.brand)
        case .custom(let color): return AnyShapeStyle(color)
        }
    }

    private var background: AnyShapeStyle {
        let alpha = Theme.chipAlpha(contrast: contrast)
        switch rank {
        case .quiet: return AnyShapeStyle(.quaternary)
        case .actionable: return AnyShapeStyle(Theme.accent.opacity(alpha))
        case .status(let tone): return tone == .idle
            ? AnyShapeStyle(.quaternary) : AnyShapeStyle(tone.color.opacity(alpha))
        case .brand: return AnyShapeStyle(Theme.brand.opacity(alpha))
        case .custom(let color): return AnyShapeStyle(color.opacity(alpha))
        }
    }
}

// MARK: - Port chip

/// A published port, as one chip: `8080 → 80/tcp`.
///
/// Split out from ``MorbChip`` because the containers list draws up to three of these per
/// row and they need to be *quiet*: only the host half — the part that opens a browser —
/// is `.actionable`; the container half is metadata.
///
/// Replaces the hand-built port pill in `ContainerListRow`, `ContainersChrome` and
/// `StacksRootView`, which are three copies at two different fonts.
struct MorbPortChip: View {

    var host: String
    var container: String
    /// Whether the host side is reachable from a browser — only then does it earn the
    /// accent colour.
    var isOpenable: Bool = true

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: Theme.space2) {
            Text(host)
                .foregroundStyle(isOpenable ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
            Image(systemName: "arrow.right")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(container)
                .foregroundStyle(.secondary)
        }
        .font(.system(.caption2, design: .monospaced))
        .lineLimit(1)
        .padding(.horizontal, Theme.space3 - 2)
        .padding(.vertical, Theme.space1)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.radiusChip,
                                                      style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Port \(host) to \(container)")
    }
}

// MARK: - Count badge

/// The little number on the right of a sidebar row or a section header.
///
/// Replaces three separate implementations: `NavRow`'s badge, the group header's `3/4`,
/// and the section header's trailing count.
struct MorbCountBadge: View {

    var count: Int
    /// A denominator, for `3/4`. `nil` for a bare count.
    var of: Int?
    var tone: StatusTone?

    var body: some View {
        Text(of.map { "\(count)/\($0)" } ?? "\(count)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(tone.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.secondary))
            .padding(.horizontal, Theme.space2 + 1)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule(style: .continuous))
            .accessibilityLabel(of.map { "\(count) of \($0)" } ?? "\(count)")
    }
}
