// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// What is left of the Containers screens' own vocabulary once the shared `Design/`
// system covers status, chips, rows, cards and empty states: the ANSI/log palette (kept
// exactly as it was — it is the terminal's contract with the program that wrote the
// bytes, not a UI colour), the All/Running scope, a clipboard helper, and two small
// legacy views (`TrackBPageHeader`, `TrackBSearchField`) that the offscreen screenshot
// harness (`Shots/ShotScenes.swift`, owned by the merge) still constructs directly for
// its own tab-specific compositions. They are restyled onto `Theme` tokens here so they
// stay visually coherent with the rest of the redesign, but the *shipping* Containers
// screen no longer uses either — see `ContainersRootView`'s real `.toolbar` +
// `.searchable` instead.

import AppKit
import SwiftUI

// MARK: - Palette

enum TrackBPalette {

    /// A colour that resolves differently in light and dark.
    ///
    /// The AppKit dynamic provider is used rather than two SwiftUI `Color`s behind a
    /// `colorScheme` check because it also does the right thing in the parts of the
    /// window SwiftUI does not own — menus, popovers, and the vibrancy behind a
    /// material sidebar all ask AppKit, not the environment.
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    // MARK: Log surface

    /// The log viewer's background. A touch off the window's own colour so the
    /// monospaced block reads as a distinct surface without becoming a black box in
    /// light mode. Flat, never a material — see `docs/design/IDENTITY.md` §5.
    static let logSurface = adaptive(
        light: NSColor(calibratedWhite: 0.99, alpha: 1),
        dark: NSColor(calibratedWhite: 0.10, alpha: 1))

    static let stderrWash = adaptive(
        light: NSColor(calibratedRed: 0.85, green: 0.20, blue: 0.16, alpha: 0.07),
        dark: NSColor(calibratedRed: 1.00, green: 0.35, blue: 0.30, alpha: 0.10))

    /// The sixteen ANSI foregrounds, tuned per appearance.
    ///
    /// Terminal palettes are designed for dark backgrounds, and pasting one onto white
    /// gives unreadable yellow and near-invisible bright-white. The light column is
    /// therefore darkened to hold roughly 4.5:1 against the light log surface, and the
    /// dark column brightened for the same reason in reverse.
    ///
    /// Not restyled as part of this pass: the ANSI palette is the terminal's contract
    /// with the program that wrote the bytes, not a Morbstack UI colour.
    static func ansi(_ color: TrackBAnsiColor) -> Color {
        switch color {
        case .black:
            return adaptive(light: NSColor(calibratedWhite: 0.20, alpha: 1),
                            dark: NSColor(calibratedWhite: 0.45, alpha: 1))
        case .red:
            return adaptive(light: NSColor(calibratedRed: 0.72, green: 0.11, blue: 0.09, alpha: 1),
                            dark: NSColor(calibratedRed: 1.00, green: 0.42, blue: 0.38, alpha: 1))
        case .green:
            return adaptive(light: NSColor(calibratedRed: 0.11, green: 0.47, blue: 0.16, alpha: 1),
                            dark: NSColor(calibratedRed: 0.45, green: 0.90, blue: 0.50, alpha: 1))
        case .yellow:
            return adaptive(light: NSColor(calibratedRed: 0.56, green: 0.40, blue: 0.02, alpha: 1),
                            dark: NSColor(calibratedRed: 0.95, green: 0.82, blue: 0.35, alpha: 1))
        case .blue:
            return adaptive(light: NSColor(calibratedRed: 0.10, green: 0.32, blue: 0.78, alpha: 1),
                            dark: NSColor(calibratedRed: 0.48, green: 0.68, blue: 1.00, alpha: 1))
        case .magenta:
            return adaptive(light: NSColor(calibratedRed: 0.60, green: 0.14, blue: 0.60, alpha: 1),
                            dark: NSColor(calibratedRed: 0.90, green: 0.55, blue: 0.95, alpha: 1))
        case .cyan:
            return adaptive(light: NSColor(calibratedRed: 0.05, green: 0.44, blue: 0.50, alpha: 1),
                            dark: NSColor(calibratedRed: 0.45, green: 0.85, blue: 0.90, alpha: 1))
        case .white:
            return adaptive(light: NSColor(calibratedWhite: 0.35, alpha: 1),
                            dark: NSColor(calibratedWhite: 0.85, alpha: 1))
        case .brightBlack:
            return adaptive(light: NSColor(calibratedWhite: 0.42, alpha: 1),
                            dark: NSColor(calibratedWhite: 0.60, alpha: 1))
        case .brightRed:
            return adaptive(light: NSColor(calibratedRed: 0.82, green: 0.18, blue: 0.14, alpha: 1),
                            dark: NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.50, alpha: 1))
        case .brightGreen:
            return adaptive(light: NSColor(calibratedRed: 0.16, green: 0.56, blue: 0.20, alpha: 1),
                            dark: NSColor(calibratedRed: 0.60, green: 1.00, blue: 0.62, alpha: 1))
        case .brightYellow:
            return adaptive(light: NSColor(calibratedRed: 0.64, green: 0.47, blue: 0.05, alpha: 1),
                            dark: NSColor(calibratedRed: 1.00, green: 0.90, blue: 0.50, alpha: 1))
        case .brightBlue:
            return adaptive(light: NSColor(calibratedRed: 0.18, green: 0.42, blue: 0.88, alpha: 1),
                            dark: NSColor(calibratedRed: 0.62, green: 0.78, blue: 1.00, alpha: 1))
        case .brightMagenta:
            return adaptive(light: NSColor(calibratedRed: 0.70, green: 0.22, blue: 0.70, alpha: 1),
                            dark: NSColor(calibratedRed: 1.00, green: 0.70, blue: 1.00, alpha: 1))
        case .brightCyan:
            return adaptive(light: NSColor(calibratedRed: 0.09, green: 0.52, blue: 0.58, alpha: 1),
                            dark: NSColor(calibratedRed: 0.62, green: 0.94, blue: 1.00, alpha: 1))
        case .brightWhite:
            return adaptive(light: NSColor(calibratedWhite: 0.15, alpha: 1),
                            dark: NSColor(calibratedWhite: 1.00, alpha: 1))
        }
    }
}

// MARK: - Scope

/// The All / Running filter.
enum TrackBScope: String, CaseIterable, Identifiable {
    case all, running

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .running: return "Running"
        }
    }
}

// MARK: - Legacy header (screenshot-harness compatibility only)

/// The page header the screen used to draw inside its own content, before the toolbar.
///
/// `ContainersRootView` no longer uses this — its title, subtitle, search field and
/// scope control are real `.navigationTitle` / `.navigationSubtitle` / `.searchable` /
/// `Picker(.segmented)` content inside a `.toolbar`, per `docs/design/COMPONENTS.md` §8.
/// This type stays only because `Shots/ShotScenes.swift` (owned by the merge) builds a
/// standalone copy of the containers split to photograph a specific detail tab, and
/// constructs this directly. Restyled onto `Theme` tokens so it does not look like a
/// regression in the screenshots that still show it.
struct TrackBPageHeader<Trailing: View>: View {

    let title: String
    let subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.space4) {
            VStack(alignment: .leading, spacing: Theme.space1) {
                Text(title).font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: Theme.space4)
            trailing
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.top, Theme.space5)
        .padding(.bottom, Theme.space4)
    }
}

/// A search field that does not need a `.searchable` container.
///
/// Superseded in the shipping screen by `.searchable(text:placement:prompt:)`; kept for
/// the same reason as `TrackBPageHeader` above.
struct TrackBSearchField: View {

    @Binding var text: String
    var prompt: String = "Search"
    var width: CGFloat = 220
    /// Optional trailing caption, e.g. a match count.
    var caption: String?
    /// Supplied when something outside needs to focus this field — a ⌘F shortcut, say.
    /// `@FocusState` cannot be reached through a wrapper view from the outside, so the
    /// binding has to be handed in rather than applied on top.
    var externalFocus: FocusState<Bool>.Binding?

    @FocusState private var internalFocus: Bool

    private var isFocused: Bool { externalFocus?.wrappedValue ?? internalFocus }

    var body: some View {
        HStack(spacing: Theme.space3) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused(externalFocus ?? $internalFocus)
                .onExitCommand {
                    text = ""
                    externalFocus?.wrappedValue = false
                    internalFocus = false
                }
            if let caption, !text.isEmpty {
                Text(caption)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, Theme.space2 + 1)
        .background(.quaternary.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                .strokeBorder(Theme.brand.opacity(isFocused ? 0.8 : 0), lineWidth: 2))
        .frame(width: width)
        .morbAnimation(.snappy, value: isFocused)
    }
}

// MARK: - Utilities

enum TrackBClipboard {
    static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
