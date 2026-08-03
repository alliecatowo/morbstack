// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Cards and section headers — the two containers every screen currently invents.
//
// A card is **content**, not chrome. It is opaque, it has a hairline, and it never gets
// glass; see `docs/design/IDENTITY.md` §5. The Stacks screen's current "cards" share a
// fill with their own headers and are separated only by a hairline, which means the card
// contributes a corner radius and nothing else.

import SwiftUI

// MARK: - Section header

/// A section heading: `⌗ PORTS  1`.
///
/// Replaces `SectionLabel` in `Theme.swift` (now a forward to this) *and* the six
/// bespoke `HStack { Image; Text.uppercased(); Text(count) }` blocks in the container
/// inspect tabs, which had already drifted to six different symbol weights.
///
/// The symbol is optional and deliberately drawn at a fixed 10pt semibold regardless of
/// which glyph it is, because SF Symbols do not share an optical weight across families
/// and a clock next to a gear next to a tag at "the same size" is three different sizes.
///
/// **Title case, not `.uppercased()`.** macOS Tahoe moved lists, tables and forms to
/// title-style capitalisation for section headers and no longer shouts them for you —
/// so a header that upper-cases its own string is now the odd one out on screen rather
/// than the one that matches. The tracking went with it: kerning was compensating for
/// the all-caps setting, and without the caps it just looks loose.
struct MorbSectionHeader: View {

    var title: String
    var symbol: String?
    /// A trailing count: the `7` in `ENVIRONMENT 7`.
    var count: Int?
    /// Trailing controls, right-aligned on the same baseline.
    var accessory: AnyView?

    init(_ title: String, symbol: String? = nil, count: Int? = nil) {
        self.title = title
        self.symbol = symbol
        self.count = count
        self.accessory = nil
    }

    init<Accessory: View>(_ title: String,
                          symbol: String? = nil,
                          count: Int? = nil,
                          @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.symbol = symbol
        self.count = count
        self.accessory = AnyView(accessory())
    }

    var body: some View {
        HStack(spacing: Theme.space2 + 2) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 13, alignment: .center)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if let count {
                Text("\(count)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: Theme.space3)
            if let accessory { accessory }
        }
        .frame(minHeight: Theme.rowGroupHeader - Theme.space3)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Card

/// A panel holding a group of related content — drawn by `GroupBox`.
///
/// This used to paint its own `RoundedRectangle` fill and its own hairline stroke at its
/// own radius. `GroupBox` is the system component for exactly this, it already tracks
/// the platform's card fill, border and corner radius (all of which changed in Tahoe, so
/// a hand-drawn card is now visibly a different shape from a real one), and it responds
/// to Increase Contrast without being asked. The wrapper stays because the *layout*
/// decisions — the section header, the internal padding scale — are still ours.
///
/// A card is **never** glass and **never** carries a shadow. On macOS a shadow under a
/// non-floating panel reads as a web component.
struct MorbCard<Content: View>: View {

    /// Optional heading, rendered as a ``MorbSectionHeader`` above the divider.
    var title: String?
    var symbol: String?
    var count: Int?
    /// Internal padding. `Theme.space4` unless the content is itself a list of full-bleed
    /// rows, in which case pass `0` and pad the rows.
    var padding: CGFloat = Theme.space4

    @ViewBuilder var content: Content

    init(_ title: String? = nil,
         symbol: String? = nil,
         count: Int? = nil,
         padding: CGFloat = Theme.space4,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.count = count
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        GroupBox {
            content
                .padding(.top, title == nil ? 0 : Theme.space2)
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            if let title {
                MorbSectionHeader(title, symbol: symbol, count: count)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Key/value row

/// One `Label   Value` line inside a card or a form.
///
/// A thin wrapper over `LabeledContent` so that the label column, the baseline alignment
/// and the value's font are decided once. Replaces the hand-built label/value `Grid` in
/// `ContainerOverviewTab`, which right-aligns its labels at a fixed width computed by
/// eye.
///
/// `LabeledContent` is macOS 13 — no availability gate needed.
struct MorbKeyValue<Value: View>: View {

    var label: String
    /// Render the value monospaced. On for IDs, digests, paths, commands.
    var monospaced: Bool
    @ViewBuilder var value: Value

    init(_ label: String, monospaced: Bool = false, @ViewBuilder value: () -> Value) {
        self.label = label
        self.monospaced = monospaced
        self.value = value()
    }

    var body: some View {
        LabeledContent {
            value
                .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

extension MorbKeyValue where Value == Text {

    /// The common case: a plain string value.
    init(_ label: String, _ text: String, monospaced: Bool = false) {
        self.init(label, monospaced: monospaced) { Text(text) }
    }
}
