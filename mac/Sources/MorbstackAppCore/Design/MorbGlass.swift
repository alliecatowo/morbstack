// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Liquid Glass, wrapped once.
//
// `mac/Package.swift` declares `.macOS(.v15)`. **Every Liquid Glass API is macOS 26.0.**
// A bare `.glassEffect(…)` in a feature file does not compile at our deployment target,
// and an `@available(macOS 26.0, *)` on a view poisons every call site above it. So the
// availability branch is taken exactly once, here, and everything else in the app calls
// these wrappers.
//
// Every signature used below was read out of this machine's SDK; the line numbers and
// exact availability attributes are recorded in `docs/design/SDK-LIQUID-GLASS.md`. If you
// want to add an API to this file, grep the `.swiftinterface` first and add it to that
// document with a line number. An invented API is worse than a missing one.
//
// Where glass belongs and where it must never go is prescribed per surface in
// `docs/design/IDENTITY.md` §5. The short version: glass floats, content sits. If the
// user scrolls it, it is opaque. Never behind the log viewport, never behind a table,
// never behind a chart.

import SwiftUI

// MARK: - Roles

/// What kind of floating surface is asking for glass.
///
/// The role picks both the `Glass` variant on macOS 26 and the `Material` fallback below
/// it, so that a surface looks like the same *kind* of thing on both.
enum MorbGlassRole: Sendable, Hashable {

    /// A free-floating panel over arbitrary content: the command palette, the menu-bar
    /// popover. Reads as a solid object with depth.
    case panel

    /// A bar pinned to an edge of a scrolling region: the engine pill under the sidebar.
    /// Thinner, so the content sliding under it stays legible.
    case bar

    /// A single small control or a cluster of them floating over content.
    case control

    /// The `Material` used below macOS 26, and used at *every* version when the user has
    /// asked for increased contrast — glass has no increased-contrast variant we can
    /// rely on, and a low-contrast blur is worse than an honest opaque material.
    var fallbackMaterial: Material {
        switch self {
        case .panel: return .regularMaterial
        case .bar: return .thinMaterial
        case .control: return .regularMaterial
        }
    }
}

// MARK: - The wrapper

private struct MorbGlassModifier: ViewModifier {

    let role: MorbGlassRole
    let radius: CGFloat
    let tint: Color?
    let isInteractive: Bool

    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        if #available(macOS 26.0, *), contrast != .increased {
            // `Glass` has exactly three variants — `.regular`, `.clear`, `.identity` —
            // and two decorators, `.tint(_:)` and `.interactive(_:)`. There is no
            // `.thin` or `.prominent`; see SDK-LIQUID-GLASS.md §3.
            //
            // `.clear` is deliberately unused: it is the variant for glass over
            // photographic content, and Morbstack's backdrop is text.
            content.glassEffect(glass, in: shape)
        } else {
            content.background(role.fallbackMaterial, in: shape)
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if isInteractive { g = g.interactive() }
        return g
    }
}

extension View {

    /// Puts this view on Liquid Glass, degrading to the role's `Material` below
    /// macOS 26 and whenever Increase Contrast is on.
    ///
    /// The only sanctioned way to get glass in this app. Do not write `.glassEffect`
    /// in a feature file — it will not compile at our deployment target.
    ///
    /// - Parameters:
    ///   - role: What kind of floating surface this is. Picks the material fallback.
    ///   - radius: Corner radius. Use `Theme.radiusPanel` for a panel,
    ///     `Theme.radiusControl` for a control, `Theme.radiusCard` for a bar.
    ///   - tint: A brand or status colour to tint the glass toward. Use sparingly —
    ///     tinted glass reads as "selected", so it should mean that.
    ///   - interactive: Whether the glass should respond to pointer pressure. Only for
    ///     surfaces that are themselves a control.
    func morbGlass(_ role: MorbGlassRole,
                   radius: CGFloat,
                   tint: Color? = nil,
                   interactive: Bool = false) -> some View {
        modifier(MorbGlassModifier(role: role, radius: radius, tint: tint,
                                   isInteractive: interactive))
    }

    /// A floating panel: the command palette, the menu-bar popover.
    ///
    /// Equivalent to `.morbGlass(.panel, radius: Theme.radiusPanel)`, spelled out because
    /// it is the shape two surfaces in the app need and neither should have to remember
    /// the radius.
    func morbGlassPanel(radius: CGFloat = Theme.radiusPanel) -> some View {
        morbGlass(.panel, radius: radius)
    }
}

// MARK: - Clusters

/// Groups adjacent glass surfaces so the system merges them into one capsule as they
/// approach each other, and renders them in a single pass.
///
/// Wraps `GlassEffectContainer(spacing:)` (macOS 26) and is a plain passthrough below.
/// Use it around a row of related actions — Stop / Restart / Pause / Remove — so the
/// group reads as one control rather than four stickers.
///
/// ```swift
/// MorbGlassCluster(spacing: Theme.space3) {
///     HStack(spacing: Theme.space3) {
///         Button("Stop")    { … }.morbGlassButton()
///         Button("Restart") { … }.morbGlassButton()
///     }
/// }
/// ```
struct MorbGlassCluster<Content: View>: View {

    var spacing: CGFloat = Theme.space3
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension View {

    /// Marks this view as part of a named glass union inside a ``MorbGlassCluster``.
    ///
    /// Wraps `glassEffectUnion(id:namespace:)`. Note the argument labels: the SDK spells
    /// this one `(id:namespace:)` and the *identity* one `(_:in:)` — they are not
    /// symmetric, which is exactly the sort of thing this wrapper exists to hide.
    func morbGlassUnion(id: some Hashable & Sendable, namespace: Namespace.ID) -> some View {
        Group {
            if #available(macOS 26.0, *) {
                self.glassEffectUnion(id: id, namespace: namespace)
            } else {
                self
            }
        }
    }

    /// Gives this glass surface a morph identity, so it animates between positions
    /// rather than cross-fading.
    ///
    /// Wraps `glassEffectID(_:in:)`.
    func morbGlassID(_ id: some Hashable & Sendable, in namespace: Namespace.ID) -> some View {
        Group {
            if #available(macOS 26.0, *) {
                self.glassEffectID(id, in: namespace)
            } else {
                self
            }
        }
    }
}

// MARK: - Buttons

/// How much emphasis a button carries.
///
/// Three levels, and a screen gets **at most one** `.primary`. That constraint is the
/// difference between the current containers detail header — four buttons in four
/// treatments, with the destructive one least emphasised — and a hierarchy.
enum MorbButtonEmphasis: Sendable, Hashable {

    /// The one action the screen exists for: Start Engine, Pull.
    case primary
    /// An ordinary action on floating chrome: Stop, Restart.
    case floating
    /// An ordinary action on flat content.
    case standard
}

private struct MorbButtonStyleModifier: ViewModifier {

    let emphasis: MorbButtonEmphasis

    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        // `.buttonStyle(.glass)` and `.glassProminent` are macOS 26.0. The *tinted*
        // form, `.glass(_:)`, resolves to `GlassButtonStyle.init(_:)` which is macOS
        // **26.1** — so it is deliberately not offered here.
        if #available(macOS 26.0, *), contrast != .increased {
            switch emphasis {
            case .primary: content.buttonStyle(.glassProminent)
            case .floating: content.buttonStyle(.glass)
            case .standard: content.buttonStyle(.bordered)
            }
        } else {
            switch emphasis {
            case .primary: content.buttonStyle(.borderedProminent)
            case .floating, .standard: content.buttonStyle(.bordered)
            }
        }
    }
}

extension View {

    /// Applies the app's button style for a given emphasis, with the macOS 26 glass
    /// styles where they exist and the bordered styles below.
    ///
    /// Replaces the four ad-hoc treatments in the container detail header.
    func morbButton(_ emphasis: MorbButtonEmphasis) -> some View {
        modifier(MorbButtonStyleModifier(emphasis: emphasis))
    }

    /// Shorthand for `.morbButton(.floating)` — a button living on glass chrome.
    func morbGlassButton() -> some View { morbButton(.floating) }
}

// MARK: - Scroll edges

extension View {

    /// The treatment where scrolling content meets fixed chrome.
    ///
    /// `.hard` above a table or the log viewport — a crisp division, because those have
    /// a first row that must not look half-erased. `.soft` above prose and the Disk
    /// page. See `docs/design/IDENTITY.md` §5.3.
    ///
    /// No-op below macOS 26.
    func morbScrollEdge(_ style: MorbScrollEdge, for edges: Edge.Set = .top) -> some View {
        Group {
            if #available(macOS 26.0, *) {
                self.scrollEdgeEffectStyle(style.resolved, for: edges)
            } else {
                self
            }
        }
    }
}

/// A version-independent spelling of `ScrollEdgeEffectStyle`.
///
/// Exists so that a feature file can name the style it wants without importing an API
/// that does not exist at our deployment target.
enum MorbScrollEdge: Sendable, Hashable {

    /// A crisp division. Above tables and the log viewport.
    case hard
    /// A fade. Above prose.
    case soft
    /// Let the system decide.
    case automatic

    @available(macOS 26.0, *)
    fileprivate var resolved: ScrollEdgeEffectStyle {
        switch self {
        case .hard: return .hard
        case .soft: return .soft
        case .automatic: return .automatic
        }
    }
}

// MARK: - Edge bars

/// A bar pinned to the bottom of a scrolling region, on the system's own bar treatment.
///
/// `safeAreaBar(edge:alignment:spacing:content:)` is macOS 26 and gets the glass and the
/// edge effect for free; `safeAreaInset` is the pre-26 equivalent without them. The
/// engine pill is the app's only user.
extension View {

    func morbBottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        let content = bar()
        return Group {
            if #available(macOS 26.0, *) {
                self.safeAreaBar(edge: .bottom, spacing: 0) { content }
            } else {
                self.safeAreaInset(edge: .bottom, spacing: 0) { content }
            }
        }
    }
}
