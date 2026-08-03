// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The window toolbar — the single biggest thing the app is missing.
//
// Seven of the ten screens draw a fake header bar inside their own content: an `HStack`
// with a title, a `TextField` dressed as a search field, a hand-rolled segmented
// control and a couple of buttons. The consequences are all visible in the renders:
// nothing to drag the window by, no scroll-edge effect, no Liquid Glass grouping, no
// "Customize Toolbar…", and a title that does not participate in the window's own
// typography.
//
// Everything here is macOS 11–14 except the two `ToolbarSpacer` helpers, which are
// gated. `docs/design/SDK-LIQUID-GLASS.md` §1.8 and §2.5 have the exact signatures.

import SwiftUI

// MARK: - Placement groups

/// A named group of toolbar items, so that every screen puts the same *kind* of control
/// in the same place.
///
/// This is the contract the three implementation tracks share. A screen that puts its
/// search field on the left and its filter on the right is a screen that does not look
/// like the one next to it.
enum MorbToolbarGroup {

    /// Navigation and view-mode controls — a segmented All/Running, a layout switch.
    /// Leading side, next to the sidebar toggle.
    static let navigation: ToolbarItemPlacement = .navigation

    /// The screen's own actions: Prune, Refresh, Pull. Trailing side.
    static let actions: ToolbarItemPlacement = .primaryAction

    /// Overflow — anything that belongs in the ⋯ menu.
    static let overflow: ToolbarItemPlacement = .secondaryAction

    /// Non-control status: a spinner, a count. Trailing, and it must opt out of the
    /// shared glass background so it does not read as a button.
    static let status: ToolbarItemPlacement = .status
}

// MARK: - Spacers

/// A gap between toolbar items that breaks the shared Liquid Glass capsule in two.
///
/// Without one, every item in a placement merges into a single blob on macOS 26. With
/// one, related actions cluster and unrelated ones separate — which is the whole reason
/// the container header's four buttons currently read as four unrelated stickers.
///
/// No-op below macOS 26. Legal inside a `@ToolbarContentBuilder` because
/// `ToolbarContentBuilder.buildLimitedAvailability` exists.
struct MorbToolbarGap: ToolbarContent {

    var placement: ToolbarItemPlacement = .primaryAction
    /// `false` for a fixed-width divider between two clusters; `true` to push the rest
    /// of the placement to the far edge.
    var flexible: Bool = false

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(flexible ? .flexible : .fixed, placement: placement)
        } else {
            // Pre-26 toolbars have no spacer primitive and no shared background to
            // break, so the absence is the correct rendering rather than a compromise.
            ToolbarItem(placement: placement) { EmptyView() }
        }
    }
}

// MARK: - Status item

/// A read-only indicator in the toolbar — a line count, a refresh spinner.
///
/// Opts out of the shared glass background via `sharedBackgroundVisibility(.hidden)`
/// (macOS 26) so it does not look like a button that does nothing when clicked. The
/// logs screen's `● 412 lines` is the app's one user.
struct MorbToolbarStatus<Content: View>: ToolbarContent {

    var id: String
    @ViewBuilder var content: Content

    init(id: String, @ViewBuilder content: () -> Content) {
        self.id = id
        self.content = content()
    }

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(id: id, placement: .status) { content }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(id: id, placement: .status) { content }
        }
    }
}

// MARK: - Inspector toggle

/// The trailing-edge control that shows and hides a screen's inspector column.
///
/// One implementation, so that Images, Volumes and Networks all put the same glyph in
/// the same place. `sidebar.right` is the symbol macOS itself uses for this — Finder's
/// preview pane, Xcode's inspector, Notes' attachment browser — and the HIG puts the
/// control on the toolbar's trailing edge, next to search.
struct MorbInspectorToggle: ToolbarContent {

    var id: String
    @Binding var isPresented: Bool

    var body: some ToolbarContent {
        ToolbarItem(id: id, placement: .primaryAction) {
            Button {
                isPresented.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help(isPresented ? "Hide the inspector" : "Show the inspector")
        }
    }
}

// MARK: - Icon buttons

/// A toolbar-sized icon button with a real hit target.
///
/// Every icon-only control in the app is currently an 11–13pt glyph with no padding —
/// see the per-service stop/restart buttons in Stacks, which are 11pt targets pinned to
/// the window edge. ``Theme/minHitTarget`` is 24pt and this is how it gets applied.
struct MorbIconButton: View {

    var systemImage: String
    var help: String
    var role: ButtonRole?
    var action: () -> Void

    @State private var isHovering = false

    init(_ systemImage: String,
         help: String,
         role: ButtonRole? = nil,
         action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: Theme.minHitTarget, height: Theme.minHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .background(isHovering ? Theme.rowHover : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.radiusChip, style: .continuous))
        .onHover { isHovering = $0 }
        .morbAnimation(.fade, value: isHovering)
        .help(help)
        .accessibilityLabel(help)
    }

    /// Destructive affordances are `.secondary` at rest and only turn red on hover.
    ///
    /// The Images table currently paints its trash glyph red whenever the image is
    /// *unused* — that is, whenever deleting it is safe — so the safe rows look like the
    /// dangerous ones.
    private var foreground: Color {
        if role == .destructive { return isHovering ? Theme.statusBad : .secondary }
        return isHovering ? .primary : .secondary
    }
}

// MARK: - Screen chrome

/// The standard modifier every screen root applies.
///
/// Moves the title and subtitle out of content space and into the window's own
/// typography, sets the scroll-edge treatment for the kind of content below, and makes
/// the toolbar customisable.
///
/// ```swift
/// ImagesTable(model: model)
///     .morbScreen(title: "Images",
///                 subtitle: "18 images · 6.93 GB · 2 dangling",
///                 edge: .hard)
///     .toolbar(id: "images") { … }
/// ```
struct MorbScreenChrome: ViewModifier {

    var title: String
    var subtitle: String?
    var edge: MorbScrollEdge

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationSubtitle(subtitle ?? "")
            .morbScrollEdge(edge, for: .top)
    }
}

extension View {

    /// See ``MorbScreenChrome``.
    ///
    /// - Parameter edge: `.hard` above a table or the log viewport; `.soft` above prose
    ///   and the Disk page. See `docs/design/IDENTITY.md` §5.3.
    func morbScreen(title: String, subtitle: String? = nil, edge: MorbScrollEdge = .hard) -> some View {
        modifier(MorbScreenChrome(title: title, subtitle: subtitle, edge: edge))
    }
}
