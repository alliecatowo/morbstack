// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The app's visual vocabulary, in one file.
//
// Two rules hold everything here together.
//
// **Semantic, not literal.** Nothing anywhere in the app writes `Color(white: 0.9)`.
// Every colour is either a system semantic colour — which the OS already tuned for
// light, dark, increased contrast and vibrancy — or one of the handful of accents
// below, each defined as a light/dark pair. That is the whole reason both appearances
// look deliberate rather than one being an inverted afterthought.
//
// **Status is a colour *and* a symbol.** A green dot alone fails for the ~4% of users
// with a red/green deficiency, and fails again in a greyscale screenshot. Every status
// therefore carries a shape as well, and the two are defined together in ``StatusTone``
// so they cannot drift apart.

import SwiftUI

// MARK: - Status

/// The state a thing is in, reduced to the five the UI actually distinguishes.
///
/// Docker has a dozen container states; the eye has about five useful buckets. Mapping
/// happens once, here, so the containers list, the stacks list and the menu bar cannot
/// disagree about what colour "restarting" is.
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
        case .bad: return "exclamationmark.circle.fill"
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

    /// The deep indigo the icon is built from — used for the sidebar selection tint
    /// and nothing else, so it stays a signature rather than becoming wallpaper.
    static let brand = Color(light: Color(red: 0.30, green: 0.27, blue: 0.85),
                             dark: Color(red: 0.51, green: 0.47, blue: 0.98))

    /// The violet end of the icon's gradient.
    static let brandSecondary = Color(light: Color(red: 0.55, green: 0.29, blue: 0.90),
                                      dark: Color(red: 0.71, green: 0.51, blue: 1.00))

    static var brandGradient: LinearGradient {
        LinearGradient(colors: [brand, brandSecondary], startPoint: .topLeading, endPoint: .bottomTrailing)
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
    /// Drawn from the same indigo as ``brand``, a shade lighter so it stays legible at
    /// caption size on a chip tinted with 13% of itself.
    static let accent = Color(light: Color(red: 0.29, green: 0.26, blue: 0.80),
                              dark: Color(red: 0.60, green: 0.57, blue: 1.00))

    // MARK: Categorical series
    //
    // Four hues for the four things that can eat a disk. They are a *sequence*, not four
    // colours picked one at a time: `.blue`, `.teal`, `.purple`, `.orange` straight from
    // the system share no common saturation or lightness, and a stacked bar built from
    // them looks like a fruit machine rather than a chart.
    //
    // Hue is spaced far enough apart to survive both a 10pt legend swatch and a
    // red/green deficiency, and the two that sit closest — indigo and violet — are never
    // adjacent in the bar, because teal is always between them.

    static let seriesIndigo = Color(light: Color(red: 0.31, green: 0.28, blue: 0.82),
                                    dark: Color(red: 0.55, green: 0.51, blue: 0.98))
    static let seriesTeal = Color(light: Color(red: 0.05, green: 0.50, blue: 0.55),
                                  dark: Color(red: 0.32, green: 0.80, blue: 0.86))
    static let seriesViolet = Color(light: Color(red: 0.62, green: 0.28, blue: 0.80),
                                    dark: Color(red: 0.80, green: 0.56, blue: 1.00))
    static let seriesAmber = Color(light: Color(red: 0.74, green: 0.48, blue: 0.05),
                                   dark: Color(red: 0.98, green: 0.74, blue: 0.32))

    // MARK: Status
    //
    // Hand-tuned rather than `.green` / `.orange` / `.red` straight from the system.
    // The system greens are a shade too acid against a dark material sidebar, and the
    // system red is loud enough that a single unhealthy container makes the whole
    // window feel like an incident. Each pair is darkened for light mode (where the
    // background is bright) and lifted for dark mode (where saturated hues muddy).

    static let statusRunning = Color(light: Color(red: 0.13, green: 0.60, blue: 0.30),
                                     dark: Color(red: 0.30, green: 0.85, blue: 0.48))
    static let statusBusy = Color(light: Color(red: 0.80, green: 0.50, blue: 0.05),
                                  dark: Color(red: 1.00, green: 0.70, blue: 0.25))
    static let statusPaused = Color(light: Color(red: 0.30, green: 0.45, blue: 0.75),
                                    dark: Color(red: 0.52, green: 0.68, blue: 0.98))
    static let statusBad = Color(light: Color(red: 0.75, green: 0.18, blue: 0.20),
                                 dark: Color(red: 1.00, green: 0.44, blue: 0.44))

    // MARK: Surfaces

    /// The detail pane's backdrop.
    static var contentBackground: Color { Color(nsColor: .textBackgroundColor) }

    /// A raised card sitting on ``contentBackground``.
    static var cardBackground: Color { Color(nsColor: .controlBackgroundColor) }

    /// Hairlines between rows and around cards.
    static var hairline: Color { Color(nsColor: .separatorColor) }

    /// The wash behind a hovered row. Deliberately barely-there: a row highlight that
    /// reads as a selection makes the actual selection ambiguous.
    static var rowHover: Color { Color.primary.opacity(0.055) }

    // MARK: Metrics

    /// Standard inset for detail-pane content.
    static let pagePadding: CGFloat = 20
    /// Vertical padding inside a list row.
    static let rowPadding: CGFloat = 7
    /// Corner radius for cards and tiles. Matches the concentric feel of Tahoe's own
    /// panels — square enough to look structural, round enough to look soft.
    static let cornerRadius: CGFloat = 10
    /// Corner radius for small inline chips and badges.
    static let chipRadius: CGFloat = 5
    /// Diameter of a status dot.
    static let dotSize: CGFloat = 8
    /// Default sidebar width.
    static let sidebarWidth: CGFloat = 216

    // MARK: Motion
    //
    // Two springs and one fade, used everywhere. Restraint is the point: an app where
    // every element has its own bespoke timing feels unsettled, and a list that
    // bounces when a container dies feels flippant about the event.

    /// For content that appears, disappears, or changes size.
    static let springSubtle = Animation.spring(response: 0.32, dampingFraction: 0.86)
    /// For a direct response to a click — slightly quicker, so it feels attached to
    /// the finger rather than trailing it.
    static let springSnappy = Animation.spring(response: 0.22, dampingFraction: 0.80)
    /// For state that changes underneath the user without their asking, such as an
    /// event-driven row update. No spring: motion the user did not initiate should not
    /// draw the eye.
    static let fade = Animation.easeInOut(duration: 0.18)
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

// MARK: - Shared small views

/// The coloured dot that marks a status, with its symbol underneath for accessibility.
///
/// Renders as a filled circle at the usual size; the symbol carries the redundant
/// signal for VoiceOver and for anyone who cannot separate the hues.
struct StatusDot: View {

    var tone: StatusTone
    var size: CGFloat = Theme.dotSize
    /// Set for a state that is actively changing, which earns a gentle pulse.
    var animated: Bool = false

    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(tone.color)
            .frame(width: size, height: size)
            .overlay {
                // A hairline ring keeps the dot legible where it lands on a colour of
                // similar luminance — a green dot on a green-tinted selected row.
                Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
            .opacity(animated && pulsing ? 0.35 : 1)
            .animation(
                animated
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : .default,
                value: pulsing
            )
            .onAppear { if animated { pulsing = true } }
            .accessibilityLabel(tone.label)
    }
}

/// A small pill: a count, a driver name, a compose project.
struct Chip: View {

    var text: String
    var tone: Color = .secondary
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            }
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .monospacedDigit()
        .foregroundStyle(tone)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tone.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous))
    }
}

/// A section heading inside the detail pane.
struct SectionLabel: View {

    var text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .kerning(0.6)
            .foregroundStyle(.tertiary)
    }
}
