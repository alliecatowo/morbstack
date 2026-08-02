// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Status, rendered.
//
// One rule, and it is the reason these are components rather than call-site `Circle`s:
// **status is never colour alone.** Every tone carries a distinct SF Symbol as well, so
// the signal survives a red/green deficiency, a greyscale screenshot and a print-out.
// ``StatusTone`` defines the pair; these views are the only things allowed to draw it.

import SwiftUI

// MARK: - Dot

/// The coloured dot that marks a status.
///
/// Replaces the free-standing `StatusDot` in `Theme.swift`, which is now a forward to
/// this. Two things are new: the pulse honours Reduce Motion (via ``MorbPulse``), and
/// `showsSymbol` lets a dense surface trade the dot for the tone's glyph without
/// inventing a second component.
///
/// The hairline ring is not decoration — it is what keeps a green dot legible when it
/// lands on a row whose selection fill is a similar luminance.
struct MorbStatusDot: View {

    var tone: StatusTone
    var size: CGFloat = Theme.dotSize
    /// Set for a state that is actively changing. Suppressed under Reduce Motion.
    var pulsing: Bool = false
    /// Draw the tone's symbol instead of a plain disc. Use where the dot is the only
    /// status signal on the row and there is room for 11pt of glyph.
    var showsSymbol: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if showsSymbol {
                Image(systemName: tone.symbol)
                    .font(.system(size: size * 1.35, weight: .semibold))
                    .foregroundStyle(tone.color)
                    .symbolEffectIfRotating(tone: tone, reduceMotion: reduceMotion)
            } else {
                Circle()
                    .fill(tone.color)
                    .frame(width: size, height: size)
                    .overlay {
                        Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    }
            }
        }
        .morphPulse(pulsing || tone.isTransitional)
        .morbAnimation(.fade, value: tone)
        .accessibilityLabel(tone.label)
    }
}

private extension View {

    /// Named separately from `morbPulse` only so the call site above reads as one chain.
    func morphPulse(_ isActive: Bool) -> some View { morbPulse(isActive) }

    /// The transitional tone's symbol turns. `.symbolEffect` is macOS 14 — no gate —
    /// and `.symbolEffectsRemoved()` is the sanctioned way to honour Reduce Motion.
    @ViewBuilder
    func symbolEffectIfRotating(tone: StatusTone, reduceMotion: Bool) -> some View {
        if tone.isTransitional && !reduceMotion {
            self.symbolEffect(.rotate, isActive: true)
        } else {
            self.symbolEffectsRemoved()
        }
    }
}

// MARK: - Badge

/// A status word with its dot, as one unit: `● running · up 12d`.
///
/// Replaces the hand-built `HStack { Circle(); Text(…) }` that the container header, the
/// stacks card header and the engine pill each grew independently — three copies that
/// had already drifted to three different dot sizes and two different fonts.
///
/// The detail suffix is optional and always `.secondary`, so the tone word stays the
/// loudest thing in the badge.
struct MorbStatusBadge: View {

    var tone: StatusTone
    /// Overrides ``StatusTone/label``. Use for a state the tone cannot express on its
    /// own, e.g. "3 of 4 services running".
    var title: String?
    /// The quiet half: `up 12d`, `exited (0) 2 hours ago`.
    var detail: String?
    /// Fill the badge with the tone at ``Theme/chipAlpha``. Off for a badge that already
    /// sits on a card.
    var filled: Bool = true

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: Theme.space2) {
            MorbStatusDot(tone: tone, size: Theme.dotSize)
            Text(title ?? tone.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(tone == .idle ? AnyShapeStyle(.secondary) : AnyShapeStyle(tone.color))
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .lineLimit(1)
        .padding(.horizontal, filled ? Theme.space3 : 0)
        .padding(.vertical, filled ? Theme.space1 + 1 : 0)
        .background {
            if filled {
                Capsule(style: .continuous)
                    .fill(tone == .idle
                          ? AnyShapeStyle(.quaternary)
                          : AnyShapeStyle(tone.color.opacity(Theme.chipAlpha(contrast: contrast))))
            }
        }
        .accessibilityElement(children: .combine)
    }
}
