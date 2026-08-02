// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The app's visual vocabulary, in one file.
//
// The full rationale — including the exact contrast ratio of every colour below against
// every surface it is drawn on — lives in `docs/design/IDENTITY.md`. This file is the
// executable half of that document; if the two disagree, the document is the spec and
// this file is the bug.
//
// Four rules hold everything here together.
//
// **Semantic, not literal.** Nothing anywhere in the app writes `Color(white: 0.9)`.
// Every colour is either a system semantic colour — which the OS already tuned for
// light, dark, increased contrast and vibrancy — or one of the tokens below, each
// defined as a light/dark pair. That is the whole reason both appearances look
// deliberate rather than one being an inverted afterthought.
//
// **Status is a colour *and* a symbol.** A green dot alone fails for the ~4% of users
// with a red/green deficiency, and fails again in a greyscale screenshot. Every status
// therefore carries a shape as well, and the two are defined together in ``StatusTone``
// so they cannot drift apart.
//
// **Six spacings, four row heights, four radii.** Not five spacings and a 14 that felt
// right. A screen that only ever uses values from these scales looks designed before
// anybody notices the colour; a screen that invents a 10 here and a 14 there looks
// generated no matter how good the palette is.
//
// **Motion goes through ``Theme/animation(_:reduceMotion:)``.** No feature file reads
// `accessibilityReduceMotion` and branches by hand.

import SwiftUI

// MARK: - Status

/// The state a thing is in, reduced to the five the UI actually distinguishes.
///
/// Docker has a dozen container states; the eye has about five useful buckets. Mapping
/// happens once, here, so the containers list, the stacks list and the menu bar cannot
/// disagree about what colour "restarting" is.
///
/// **Why there is no `degraded` case here.** "Up, but not all of it" is a real state and
/// it has a colour (``Theme/statusDegraded``) — but it belongs to *groups*, not to
/// individual things, and it is modelled as ``MorbGroupState`` in `Design/` instead.
/// Adding a sixth case to this enum would break `TrackDTone.init(_:)` in
/// `MenuBar/TrackDChrome.swift`, which switches over it exhaustively and belongs to
/// another track. See `docs/design/REWRITE-PLAN.md` for the one-line follow-up that
/// promotes it, and which agent owns it.
enum StatusTone: Sendable, Hashable {

    /// Up and healthy.
    case running
    /// Deliberately not running — exited cleanly, created, stopped.
    case idle
    /// Mid-transition: restarting, starting, pausing.
    case busy
    /// Paused by the user.
    case paused
    /// Dead, unhealthy, or exited non-zero.
    case bad

    var color: Color {
        switch self {
        case .running: return Theme.statusRunning
        case .idle: return .secondary
        case .busy: return Theme.statusBusy
        case .paused: return Theme.statusPaused
        case .bad: return Theme.statusBad
        }
    }

    /// The redundant, non-colour half of the signal.
    var symbol: String {
        switch self {
        case .running: return "circle.fill"
        case .idle: return "circle"
        case .busy: return "arrow.triangle.2.circlepath"
        case .paused: return "pause.circle.fill"
        case .bad: return "exclamationmark.octagon.fill"
        }
    }

    var label: String {
        switch self {
        case .running: return "Running"
        case .idle: return "Stopped"
        case .busy: return "Restarting"
        case .paused: return "Paused"
        case .bad: return "Unhealthy"
        }
    }

    /// Whether this tone earns the repeating pulse in ``MorbStatusDot``.
    var isTransitional: Bool { self == .busy }

    /// Classifies a Docker container state string.
    static func forContainer(state: String, unhealthy: Bool = false) -> StatusTone {
        switch state {
        case "running": return unhealthy ? .bad : .running
        case "restarting": return .busy
        case "paused": return .paused
        case "dead": return .bad
        case "created", "exited", "removing": return .idle
        default: return .idle
        }
    }

    /// Classifies the engine itself.
    static func forEngine(_ status: EngineStatus) -> StatusTone {
        guard status.reachable else { return .idle }
        switch status.state {
        case "running": return .running
        case "starting", "stopping", "pausing": return .busy
        case "suspended": return .paused
        case "error": return .bad
        default: return .idle
        }
    }
}

// MARK: - Palette

/// Colours, metrics and motion.
enum Theme {

    // MARK: Brand
    //
    // Four values, and each has exactly one job. Spending the brand colour on data —
    // which is what the current build does with port chips — is what leaves an app with
    // no identity: the colour is everywhere, so it means nothing.

    /// The indigo the mark is built from. Identity only: the logo, the sidebar selection
    /// rail, the focus ring, and the single primary action on a screen.
    ///
    /// Contrast: 7.59:1 on white, 5.43:1 on the dark content background. White on the
    /// light value is 7.59:1; black on the dark value is 6.84:1.
    static let brand = Color(light: Color(red: 0.267, green: 0.212, blue: 0.847),
                             dark: Color(red: 0.545, green: 0.518, blue: 1.000))

    /// The origin of the icon's gradient, and the pressed state of anything filled with
    /// ``brand``. 11.74:1 on white, 8.21:1 on the dark content background.
    static let brandDeep = Color(light: Color(red: 0.165, green: 0.122, blue: 0.620),
                                 dark: Color(red: 0.702, green: 0.678, blue: 1.000))

    /// The violet terminus of the icon's gradient. Appears in the UI *only* as the far
    /// end of ``brandGradient`` — never on its own, or the app acquires a second accent.
    static let brandSecondary = Color(light: Color(red: 0.478, green: 0.231, blue: 0.910),
                                      dark: Color(red: 0.773, green: 0.545, blue: 0.941))

    /// The diagonal the mark is drawn with. Same two stops as `make-icon.swift`, so the
    /// in-app mark and the Dock icon are visibly the same object.
    static var brandGradient: LinearGradient {
        LinearGradient(colors: [brandDeep, brandSecondary],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The colour of *anything the user can act on inside the content*: a published port
    /// that opens a browser, a matched substring in the palette, a copy button.
    ///
    /// Deliberately **not** the system accent. `Color.accentColor` is the right answer
    /// for AppKit's own controls — a push button, a checkbox, a text selection — and the
    /// app leaves those alone. It is the wrong answer for content, for two reasons that
    /// only become obvious when you look at the screenshots.
    ///
    /// The first is that it is not ours. On a Mac set to the pink accent every port chip,
    /// every service badge and the whole command palette turn hot pink, which reads as
    /// louder than the status dots — the one thing on the screen that genuinely needs to
    /// shout — and clashes with the indigo the icon and the Start Engine button are built
    /// from. The second is that it is not reproducible: the same build photographs
    /// differently on two machines, so no screenshot, design review or regression image
    /// can be trusted.
    ///
    /// 7.31:1 on white, 6.34:1 on the dark content background.
    static let accent = Color(light: Color(red: 0.290, green: 0.255, blue: 0.780),
                              dark: Color(red: 0.604, green: 0.576, blue: 1.000))

    // MARK: Selection

    /// The wash behind a selected sidebar row or list row.
    ///
    /// 16% of ``brand``: `#E1DFF9` in light, `#2F2E42` in dark. Primary label on those is
    /// 15.6:1 and 12.8:1, so the row stays perfectly legible while reading as *ours*
    /// rather than as the system's neutral grey.
    static var selectionFill: Color { brand.opacity(0.16) }

    /// The 3pt capsule on the leading edge of a selected sidebar row. The half of the
    /// selection that survives Increase Contrast and a greyscale screenshot.
    static var selectionRail: Color { brand }

    // MARK: Status
    //
    // Four hues, hand-tuned rather than `.green` / `.orange` / `.red` straight from the
    // system. The system greens are a shade too acid against a dark material sidebar,
    // and the system red is loud enough that a single unhealthy container makes the
    // whole window feel like an incident. Each pair is darkened for light mode (where
    // the background is bright) and lifted for dark mode (where saturated hues muddy).
    //
    // Every value below clears 4.5:1 against white, against the dark content background,
    // against the sidebar material in both appearances, and against its own 12% chip
    // fill. The tightest is `statusDegraded` on the light sidebar, at 4.95:1.

    /// 6.14:1 on white · 8.60:1 on the dark content background.
    static let statusRunning = Color(light: Color(red: 0.090, green: 0.439, blue: 0.235),
                                     dark: Color(red: 0.247, green: 0.827, blue: 0.494))

    /// Mid-transition. 5.86:1 on white · 8.17:1 on the dark content background.
    static let statusBusy = Color(light: Color(red: 0.604, green: 0.322, blue: 0.000),
                                  dark: Color(red: 1.000, green: 0.624, blue: 0.271))

    /// Up, but not all of it. 5.84:1 on white · 10.18:1 on the dark content background.
    static let statusDegraded = Color(light: Color(red: 0.494, green: 0.380, blue: 0.000),
                                      dark: Color(red: 0.937, green: 0.776, blue: 0.247))

    /// 7.27:1 on white · 7.16:1 on the dark content background.
    static let statusPaused = Color(light: Color(red: 0.216, green: 0.337, blue: 0.561),
                                    dark: Color(red: 0.529, green: 0.663, blue: 0.961))

    /// 6.54:1 on white · 5.97:1 on the dark content background.
    static let statusBad = Color(light: Color(red: 0.702, green: 0.149, blue: 0.118),
                                 dark: Color(red: 1.000, green: 0.420, blue: 0.376))

    // MARK: Categorical series
    //
    // Five hues for the things that can eat a disk. They are a *sequence*, not five
    // colours picked one at a time: `.blue`, `.teal`, `.purple`, `.orange` straight from
    // the system share no common saturation or lightness, and a stacked bar built from
    // them looks like a fruit machine rather than a chart.
    //
    // Hue is spaced far enough apart to survive both a 10pt legend swatch and a
    // red/green deficiency, and the two that sit closest — indigo and violet — are never
    // adjacent in the bar, because teal is always between them.
    //
    // Reclaimable space is **not** a second texture. Diagonal hatching inside a 30pt bar
    // reads as a rendering artefact; the same hue at `seriesDimAlpha` reads as "less" at
    // a glance and survives greyscale.

    static let seriesIndigo = Color(light: Color(red: 0.294, green: 0.255, blue: 0.788),
                                    dark: Color(red: 0.549, green: 0.522, blue: 0.949))
    static let seriesTeal = Color(light: Color(red: 0.039, green: 0.431, blue: 0.459),
                                  dark: Color(red: 0.247, green: 0.780, blue: 0.808))
    static let seriesViolet = Color(light: Color(red: 0.545, green: 0.247, blue: 0.749),
                                    dark: Color(red: 0.773, green: 0.545, blue: 0.941))
    static let seriesAmber = Color(light: Color(red: 0.604, green: 0.384, blue: 0.027),
                                   dark: Color(red: 0.941, green: 0.675, blue: 0.259))
    static let seriesRose = Color(light: Color(red: 0.651, green: 0.184, blue: 0.388),
                                  dark: Color(red: 0.933, green: 0.494, blue: 0.675))

    /// The drawing order for a stacked bar or a legend. Never index these by hand.
    static let series: [Color] = [seriesIndigo, seriesTeal, seriesViolet, seriesAmber, seriesRose]

    /// Opacity for the reclaimable portion of a series segment.
    static let seriesDimAlpha: Double = 0.45

    // MARK: Surfaces

    /// The detail pane's backdrop.
    static var contentBackground: Color { Color(nsColor: .textBackgroundColor) }

    /// A raised card sitting on ``contentBackground``. Never glass — see
    /// `docs/design/IDENTITY.md` §5.
    static var cardBackground: Color { Color(nsColor: .controlBackgroundColor) }

    /// Hairlines between rows and around cards.
    static var hairline: Color { Color(nsColor: .separatorColor) }

    /// ``hairline``, but honouring Increase Contrast — `separatorColor` stays faint even
    /// when the user has asked for edges they can see.
    static func hairline(contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? Color.primary.opacity(0.35) : hairline
    }

    /// The wash behind a hovered row. Deliberately barely-there: a row highlight that
    /// reads as a selection makes the actual selection ambiguous.
    static var rowHover: Color { Color.primary.opacity(0.055) }

    /// The alpha a status or brand colour is filled at when it becomes a chip.
    ///
    /// 12% is not arbitrary: it is the highest value at which *every* token still clears
    /// 4.5:1 against its own chip in dark mode. ``brand`` is the binding constraint, at
    /// 4.58:1.
    static let chipAlpha: Double = 0.12

    /// ``chipAlpha``, raised for users who asked for more contrast.
    static func chipAlpha(contrast: ColorSchemeContrast) -> Double {
        contrast == .increased ? 0.20 : chipAlpha
    }

    // MARK: Spacing
    //
    // Six values. No literal spacing anywhere in the app that is not one of these. If a
    // gap wants to be 10, it is 8; if it wants to be 14, it is 12.

    /// 2 — hairline separations inside a single control.
    static let space1: CGFloat = 2
    /// 4 — an icon and the label it belongs to.
    static let space2: CGFloat = 4
    /// 8 — between related controls; the horizontal padding of a chip.
    static let space3: CGFloat = 8
    /// 12 — between rows of a form; a card's internal padding.
    static let space4: CGFloat = 12
    /// 16 — between cards.
    static let space5: CGFloat = 16
    /// 24 — between major sections of a screen.
    static let space6: CGFloat = 24

    /// Standard inset for detail-pane content.
    static let pagePadding: CGFloat = 20

    /// Vertical padding inside a legacy hand-built list row.
    ///
    /// Superseded by the ``rowStandard`` / ``rowRich`` heights: a row should declare the
    /// height it is, not the padding it has, or the list ends up ragged the moment one
    /// row has more content than another.
    static let rowPadding: CGFloat = 7

    // MARK: Row heights
    //
    // Four, and every list in the app picks one. The containers list currently swells
    // from 70pt to 100pt depending on how many ports a container publishes, which is why
    // it is impossible to count containers by eye.

    /// 24 — menu-bar popover rows, command-palette results, form rows.
    static let rowCompact: CGFloat = 24
    /// 32 — every table row: images, volumes, networks, ports, mounts, environment.
    static let rowStandard: CGFloat = 32
    /// 44 — two-line list rows: containers, stack services. **Fixed**, regardless of how
    /// much the row would like to say.
    static let rowRich: CGFloat = 44
    /// 28 — a group header inside a list.
    static let rowGroupHeader: CGFloat = 28

    // MARK: Radii
    //
    // Concentric: a chip inside a card is `radiusCard - space3` = 4, which rounds to
    // `radiusChip`. All `.continuous`.

    /// 5 — chips and badges.
    static let radiusChip: CGFloat = 5
    /// 8 — buttons, fields, small tiles.
    static let radiusControl: CGFloat = 8
    /// 12 — ``MorbCard`` and inspector sections.
    static let radiusCard: CGFloat = 12
    /// 16 — floating panels: the command palette, the menu-bar popover.
    static let radiusPanel: CGFloat = 16

    /// Legacy alias for ``radiusCard``, kept so existing call sites keep compiling.
    /// New code uses ``radiusCard``.
    static let cornerRadius: CGFloat = radiusCard
    /// Legacy alias for ``radiusChip``. New code uses ``radiusChip``.
    static let chipRadius: CGFloat = radiusChip

    // MARK: Metrics

    /// Diameter of a status dot.
    static let dotSize: CGFloat = 8
    /// Default sidebar width.
    static let sidebarWidth: CGFloat = 216
    /// Ideal width of the container inspector.
    static let inspectorWidth: CGFloat = 460
    /// Minimum width of the container inspector.
    static let inspectorMinWidth: CGFloat = 380
    /// Maximum width of the container inspector.
    static let inspectorMaxWidth: CGFloat = 640

    /// The smallest square an icon-only button may occupy.
    ///
    /// Every `Image`-labelled button gets `.frame(minWidth:minHeight:)` and a
    /// `.contentShape(Rectangle())`. The stacks screen currently ships 11pt glyphs with
    /// no padding at all, which is a 11×11 target 1,600pt from the row it acts on.
    static let minHitTarget: CGFloat = 24

    /// One device pixel, never thinner than a half point.
    static func hairlineWidth(_ displayScale: CGFloat) -> CGFloat {
        max(0.5, 1 / max(displayScale, 1))
    }

    // MARK: Motion
    //
    // Four curves, used everywhere. Restraint is the identity: an app where every
    // element has its own bespoke timing feels unsettled, and a list that bounces when a
    // container dies feels flippant about the event. Damping is 0.86/0.90 rather than
    // 0.80/0.86 for exactly that reason — at 0.80 a spring visibly overshoots.
    //
    // Do not reach for these directly if the view can see the environment. Go through
    // ``animation(_:reduceMotion:)``, which is the only thing that honours Reduce Motion.

    /// For a direct response to a click — quick, so it feels attached to the finger
    /// rather than trailing it.
    static let springSnappy = Animation.spring(response: 0.22, dampingFraction: 0.86)
    /// For content that appears, disappears, or changes size.
    static let springSubtle = Animation.spring(response: 0.32, dampingFraction: 0.90)
    /// For state that changes underneath the user without their asking, such as an
    /// event-driven row update. No spring: motion the user did not initiate should not
    /// draw the eye.
    static let fade = Animation.easeInOut(duration: 0.18)
    /// For `glassEffectID` / `glassEffectUnion` morphs, and nothing else.
    static let glassMorph = Animation.spring(response: 0.38, dampingFraction: 0.92)
    /// The repeating breath on a transitional status dot.
    static let pulse = Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true)
}

// MARK: - Appearance-aware colours

extension Color {

    /// Builds a colour from an explicit light/dark pair.
    ///
    /// `NSColor(name:dynamicProvider:)` is what makes this resolve *live*: the colour
    /// re-evaluates when the user flips appearance, so nothing has to be rebuilt and
    /// no view needs to read `@Environment(\.colorScheme)` just to pick a shade.
    init(light: Color, dark: Color) {
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(isDark ? dark : light)
            })
    }
}

// MARK: - Legacy shared views
//
// The three small views the app was built on. Each is now a thin forward to its
// replacement in `Design/`, kept so that the ~23 existing call sites keep compiling
// while the three implementation tracks migrate their own screens.
//
// New code uses the `Morb*` component directly. These will be deleted once the last
// call site is gone.

/// The coloured dot that marks a status.
///
/// Superseded by ``MorbStatusDot``, which adds the Reduce Motion path and the optional
/// symbol overlay.
struct StatusDot: View {

    var tone: StatusTone
    var size: CGFloat = Theme.dotSize
    /// Set for a state that is actively changing, which earns a gentle pulse.
    var animated: Bool = false

    var body: some View {
        MorbStatusDot(tone: tone, size: size, pulsing: animated)
    }
}

/// A small pill: a count, a driver name, a compose project.
///
/// Superseded by ``MorbChip``.
struct Chip: View {

    var text: String
    var tone: Color = .secondary
    var symbol: String?

    var body: some View {
        MorbChip(text, symbol: symbol, tone: tone)
    }
}

/// A section heading inside the detail pane.
///
/// Superseded by ``MorbSectionHeader``, which adds the optional symbol and trailing
/// count that every screen currently hand-rolls next to this.
struct SectionLabel: View {

    var text: String

    var body: some View {
        MorbSectionHeader(text)
    }
}
