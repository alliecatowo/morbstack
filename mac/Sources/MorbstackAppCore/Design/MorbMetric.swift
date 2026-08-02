// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Numbers, rendered so they do not twitch.
//
// The single most common defect in the current build: a value that polls, rendered in a
// proportional font, so the row reflows every two seconds. It happens in the containers
// list (CPU and memory), the menu-bar popover (CPU), the Disk legend (percentages) and
// the Stats tab. Fixing it one call site at a time has already failed twice; the fix is a
// component that cannot be built wrong.
//
// Rule: **if it is right-aligned or it polls, it is monospaced-digit.**

import SwiftUI

// MARK: - Metric

/// One headline number with its unit and caption.
///
/// Replaces the three hand-built metric blocks in `DiskRootView`'s "VM DISK IMAGE" card,
/// which give three numbers three different weights for no stated reason, and the stat
/// tiles in `ContainerStatsTab`.
///
/// Always monospaced-digit; always `.contentTransition(.numericText())` so the value
/// rolls rather than snaps when it updates under the user.
struct MorbMetric: View {

    /// The number, already formatted: `25.15`, `19.38`, `28.2`.
    var value: String
    /// The unit, drawn smaller and quieter: `GB`, `%`, `cores`.
    var unit: String?
    /// What the number is: `used by Docker`, `Actual on APFS`.
    var caption: String?
    /// Tints the value. Use a status colour only when the number *is* the status.
    var tone: Color?
    /// Emphasis inside a row of sibling metrics. Exactly one may be `.leading`.
    var emphasis: Emphasis = .equal

    enum Emphasis: Sendable, Hashable {
        /// One of several peers.
        case equal
        /// The one the eye should land on first.
        case leading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space1) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.space2) {
                Text(value)
                    .font(.system(size: emphasis == .leading ? 28 : 22,
                                  weight: .semibold,
                                  design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(tone ?? .primary)
                if let unit {
                    Text(unit)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .morbAnimation(.fade, value: value)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([caption, value, unit].compactMap { $0 }.joined(separator: " "))
    }
}

// MARK: - Inline number

/// A number inside a row: a CPU percentage, a size, an age.
///
/// The workhorse. Replaces every `Text("\(pct, specifier: "%.1f")%")` in the app, all of
/// which are missing `.monospacedDigit()`.
struct MorbNumber: View {

    var text: String
    var tone: Color?
    /// Right-align inside a fixed column. Pass the column width; `nil` sizes to content.
    var width: CGFloat?
    var font: Font = .subheadline

    init(_ text: String, tone: Color? = nil, width: CGFloat? = nil, font: Font = .subheadline) {
        self.text = text
        self.tone = tone
        self.width = width
        self.font = font
    }

    var body: some View {
        Text(text)
            .font(font)
            .monospacedDigit()
            .contentTransition(.numericText())
            .foregroundStyle(tone ?? Color.secondary)
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
            .morbAnimation(.fade, value: text)
    }
}

// MARK: - Meter

/// A horizontal proportion bar: disk usage, a memory limit, a per-image size.
///
/// Replaces the naked `RoundedRectangle` bars in `DiskRootView`'s "LARGEST IMAGES" and
/// "LARGEST VOLUMES" cards. Two things are fixed here that cannot be fixed at the call
/// site: the track is always drawn (so an empty bar still reads as a bar with a scale),
/// and `total` is explicit, so two meters side by side can be given the *same*
/// denominator. The current cards use independent scales, which makes a 1.49 GB image
/// look bigger than a 3.22 GB volume.
struct MorbMeter: View {

    var value: Double
    var total: Double
    var tone: Color
    /// A second, dimmer portion drawn inside the filled part: the reclaimable share.
    /// Rendered as the same hue at ``Theme/seriesDimAlpha`` — never as hatching, which
    /// reads as a rendering artefact at bar heights.
    var reclaimable: Double = 0
    var height: CGFloat = 6

    private var fraction: Double { total > 0 ? min(max(value / total, 0), 1) : 0 }
    private var reclaimFraction: Double { total > 0 ? min(max(reclaimable / total, 0), fraction) : 0 }

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.quaternary)
                Capsule(style: .continuous)
                    .fill(tone)
                    .frame(width: w * fraction)
                if reclaimFraction > 0 {
                    Capsule(style: .continuous)
                        .fill(tone.opacity(Theme.seriesDimAlpha))
                        .frame(width: w * reclaimFraction)
                        .offset(x: w * (fraction - reclaimFraction))
                }
            }
        }
        .frame(height: height)
        .morbAnimation(.fade, value: fraction)
        .accessibilityValue(Text("\(Int(fraction * 100)) percent"))
    }
}
