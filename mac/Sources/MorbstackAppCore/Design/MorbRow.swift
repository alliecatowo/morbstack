// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Row scaffolding — where the app's density is decided.
//
// Measured off the 2× renders, the current build ships seven different row heights: 47pt
// in the Images table, 63pt in Stacks, 60pt in the Disk legend, 62pt in the palette, 80pt
// and 54pt in the menu-bar popover, and **70–100pt** in the containers list depending on
// how many ports a container publishes. A list whose rhythm changes per row cannot be
// counted by eye, and seven rhythms in one app is what "vibe coded" looks like from
// across the desk.
//
// Four heights, declared in `Theme`, applied here, and nowhere else.

import SwiftUI

// MARK: - Row class

/// How dense a row is.
///
/// Every list in the app picks one and every row in that list gets exactly it —
/// including the rows that would like to be taller.
enum MorbRowClass: Sendable, Hashable {

    /// 24pt. Menu-bar popover rows, command-palette results, form rows.
    case compact
    /// 32pt. Every table row: images, volumes, networks, ports, mounts, environment.
    case standard
    /// 44pt. Two-line list rows: containers, stack services.
    case rich

    var height: CGFloat {
        switch self {
        case .compact: return Theme.rowCompact
        case .standard: return Theme.rowStandard
        case .rich: return Theme.rowRich
        }
    }

    /// Horizontal inset from the list's edge.
    var horizontalInset: CGFloat {
        switch self {
        case .compact: return Theme.space3
        case .standard, .rich: return Theme.space4
        }
    }
}

// MARK: - Row chrome

private struct MorbRowModifier: ViewModifier {

    let rowClass: MorbRowClass
    /// `true` only for rows in a container that has **no** system selection of its own —
    /// today that is the command palette, and nothing else.
    let drawsSelection: Bool
    let isSelected: Bool
    let showsHover: Bool

    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .frame(height: rowClass.height)
            .padding(.horizontal, rowClass.horizontalInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill)
            .contentShape(Rectangle())
            .onHover { if showsHover { isHovering = $0 } }
            .morbAnimation(.fade, value: isHovering)
            .morbAnimation(.snappy, value: isSelected)
    }

    private var fill: Color {
        if drawsSelection && isSelected { return Theme.selectionFill }
        return isHovering ? Theme.rowHover : .clear
    }
}

extension View {

    /// Gives this row the design system's fixed height, inset and hover wash.
    ///
    /// It deliberately does **not** draw selection. Every list in the app that has a
    /// selection is a `List(selection:)` or a `Table(selection:)`, and macOS already
    /// draws the selected row: a filled capsule in the user's accent colour, the same one
    /// Finder, Mail and Xcode draw, complete with the focused/unfocused distinction and
    /// the vibrancy that flips the row's label to white. Painting a translucent indigo
    /// wash and a 3pt brand rail *underneath* that did not replace the system's
    /// treatment, it stacked on top of it — which is what "vibecoded" looks like from
    /// across the desk, and the single most-cited thing in the product review.
    ///
    /// Identity does not come from repainting the platform's selection. It comes from
    /// what is *in* the row.
    func morbRow(_ rowClass: MorbRowClass, showsHover: Bool = true) -> some View {
        modifier(MorbRowModifier(rowClass: rowClass, drawsSelection: false,
                                 isSelected: false, showsHover: showsHover))
    }

    /// The one exception: a row in a container the system does not know is a list.
    ///
    /// The command palette is a hand-built results list inside a sheet — there is no
    /// `List(selection:)` for macOS to draw a highlight into, so the highlight has to be
    /// ours. Do not reach for this anywhere a real `List` or `Table` would do.
    func morbUnmanagedRow(_ rowClass: MorbRowClass, isSelected: Bool) -> some View {
        modifier(MorbRowModifier(rowClass: rowClass, drawsSelection: true,
                                 isSelected: isSelected, showsHover: false))
    }
}

// MARK: - Two-line row

/// The standard rich row: title line, detail line, trailing column.
///
/// Replaces `ContainerListRow`'s three-tier layout, which stacks a name, an
/// image·CPU·memory line and a wrapping row of port pills at two levels of weight and no
/// clear reading order.
///
/// The rule the type enforces: **the trailing content is a single column of fixed width.**
/// Ports, ages and percentages all live there, they all truncate there, and none of them
/// can make the row taller.
struct MorbRichRow<Leading: View, Trailing: View>: View {

    var title: String
    var subtitle: String?
    var isSelected: Bool = false
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    init(title: String,
         subtitle: String? = nil,
         isSelected: Bool = false,
         @ViewBuilder leading: () -> Leading,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.isSelected = isSelected
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: Theme.space3) {
            leading
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: Theme.space3)
            trailing
        }
        .morbRow(.rich)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Overflow

/// `+2` — the chip that stands in for content a fixed-height row cannot show.
///
/// The containers list publishes up to three ports per container today and grows the row
/// to fit them. With a fixed 44pt row, the first port is shown and the rest collapse into
/// this, with the full list in the tooltip and in the inspector.
struct MorbOverflowChip: View {

    var hidden: Int
    /// What the hidden items are, for the tooltip: "8443 → 443/tcp, 9000 → 9000/tcp".
    var detail: String?

    var body: some View {
        Text("+\(hidden)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.space2 + 1)
            .padding(.vertical, Theme.space1)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.radiusChip,
                                                          style: .continuous))
            .help(detail ?? "\(hidden) more")
            .accessibilityLabel("\(hidden) more")
    }
}

// MARK: - Divider

/// A row separator inset to the row's own content, not to the window edge.
///
/// The containers list currently draws full-bleed dividers under some rows and not
/// others, which is what makes the group boundaries ambiguous.
struct MorbRowDivider: View {

    var rowClass: MorbRowClass = .standard

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(Theme.hairline(contrast: contrast))
            .frame(height: Theme.hairlineWidth(displayScale))
            .padding(.leading, rowClass.horizontalInset)
            .accessibilityHidden(true)
    }
}
