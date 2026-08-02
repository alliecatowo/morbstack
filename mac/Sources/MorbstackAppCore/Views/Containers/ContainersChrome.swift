// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The small vocabulary of controls the Containers screens are built from: status dots,
// badges, port chips, the page header, the empty states.
//
// These are `TrackB`-prefixed rather than shared because the app contract gives shared
// chrome to Track A's `Theme.swift`; when that lands, most of this file becomes a set
// of thin aliases. Until then it keeps the Containers views free of ad-hoc padding
// numbers and one-off colours, which is the only way a screen this dense stays coherent.

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

    // MARK: Container state

    /// The dot colour for a container state, following the contract's mapping:
    /// running green, exited secondary, restarting orange, dead or unhealthy red.
    static func stateColor(_ state: String, unhealthy: Bool = false) -> Color {
        if unhealthy { return .red }
        switch state {
        case "running": return .green
        case "paused": return .blue
        case "restarting": return .orange
        case "created": return .teal
        case "dead": return .red
        case "removing": return .orange
        default: return .secondary
        }
    }

    static func stateSymbol(_ state: String, unhealthy: Bool = false) -> String {
        if unhealthy { return "exclamationmark.triangle.fill" }
        switch state {
        case "running": return "circle.fill"
        case "paused": return "pause.circle.fill"
        case "restarting": return "arrow.triangle.2.circlepath"
        case "dead": return "xmark.octagon.fill"
        default: return "circle"
        }
    }

    // MARK: Log surface

    /// The log viewer's background. A touch off the window's own colour so the
    /// monospaced block reads as a distinct surface without becoming a black box in
    /// light mode.
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

// MARK: - Status dot

/// The state indicator that leads every container row.
///
/// A dot alone is not enough — colour is the fastest signal but it is also the one some
/// users cannot read — so restarting spins, paused shows its glyph, and unhealthy is a
/// triangle. Everything still reads correctly in greyscale.
struct TrackBStatusDot: View {

    let state: String
    var unhealthy: Bool = false
    var size: CGFloat = 8

    @State private var spinning = false

    private var color: Color { TrackBPalette.stateColor(state, unhealthy: unhealthy) }

    var body: some View {
        Group {
            switch state {
            case "restarting":
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: size + 3, weight: .semibold))
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .animation(
                        .linear(duration: 1.6).repeatForever(autoreverses: false),
                        value: spinning)
                    .onAppear { spinning = true }
            case _ where unhealthy:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: size + 2))
            case "paused":
                Image(systemName: "pause.fill")
                    .font(.system(size: size, weight: .bold))
            case "running":
                Circle()
                    .frame(width: size, height: size)
                    // A soft halo reads as "live" at a glance without animating, which
                    // matters when twenty rows are on screen at once.
                    .shadow(color: color.opacity(0.55), radius: 3)
            default:
                Circle()
                    .strokeBorder(lineWidth: 1.5)
                    .frame(width: size, height: size)
            }
        }
        .foregroundStyle(color)
        .frame(width: size + 5, height: size + 5)
        .accessibilityLabel(unhealthy ? "unhealthy" : state)
    }
}

// MARK: - Badges and chips

enum TrackBBadgeTone {
    case neutral, accent, warning, danger, success

    var tint: Color {
        switch self {
        case .neutral: return .secondary
        case .accent: return Theme.accent
        case .warning: return .orange
        case .danger: return .red
        case .success: return .green
        }
    }
}

/// A small capsule label — compose service names, health, "paused".
struct TrackBBadge: View {

    let text: String
    var tone: TrackBBadgeTone = .neutral
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            }
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tone.tint.opacity(0.14), in: Capsule())
        .foregroundStyle(tone.tint)
    }
}

/// A published port, clickable when there is something a browser could open.
///
/// UDP and unpublished ports render as plain text rather than as a dead link: a chip
/// that looks tappable and does nothing is worse than one that never invited the click.
struct TrackBPortChip: View {

    let port: PortMapping
    @State private var hovering = false

    var body: some View {
        if let url = port.url {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 8, weight: .semibold))
                    Text(port.label).font(.system(size: 10, design: .monospaced))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Theme.accent.opacity(hovering ? 0.25 : 0.13), in: Capsule())
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Open \(url.absoluteString)")
            .accessibilityLabel("Open port \(port.hostPort ?? port.containerPort) in browser")
        } else {
            Text(port.label)
                .font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: Capsule())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Header

/// The page header: title, subtitle, and whatever controls the screen needs.
///
/// Lives inside the view rather than in the window toolbar so that the Containers
/// screen owns its own chrome — the window toolbar belongs to the app shell, and two
/// tracks writing into it is how toolbars end up with three search fields.
struct TrackBPageHeader<Trailing: View>: View {

    let title: String
    let subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
}

/// A search field that does not need a `.searchable` container.
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
        HStack(spacing: 6) {
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
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.accent.opacity(isFocused ? 0.8 : 0), lineWidth: 2))
        .frame(width: width)
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

// MARK: - Empty states

/// The "nothing here yet" screen, built out of SF Symbols rather than an image asset.
struct TrackBEmptyState<Actions: View>: View {

    let symbols: [String]
    let title: String
    let message: String
    /// A shell command the user can copy to get somewhere.
    var snippet: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 16) {
            TrackBSymbolStack(symbols: symbols)
                .padding(.bottom, 4)

            VStack(spacing: 6) {
                Text(title).font(.title3.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            if let snippet {
                TrackBSnippet(command: snippet)
            }

            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// Three symbols fanned out behind each other — the closest thing to illustration that
/// stays honest about being made of system glyphs.
struct TrackBSymbolStack: View {

    let symbols: [String]
    @State private var appeared = false

    var body: some View {
        ZStack {
            ForEach(Array(symbols.enumerated()), id: \.offset) { index, symbol in
                let middle = Double(symbols.count - 1) / 2
                let offset = Double(index) - middle
                Image(systemName: symbol)
                    .font(.system(size: index == Int(middle.rounded()) ? 46 : 34, weight: .light))
                    .foregroundStyle(
                        index == Int(middle.rounded())
                            ? AnyShapeStyle(Theme.accent.gradient)
                            : AnyShapeStyle(Color.secondary.opacity(0.35)))
                    .rotationEffect(.degrees(offset * 12))
                    .offset(x: offset * 46, y: abs(offset) * 8)
                    .scaleEffect(appeared ? 1 : 0.82)
                    .opacity(appeared ? 1 : 0)
                    .animation(
                        .spring(response: 0.45, dampingFraction: 0.75)
                            .delay(Double(index) * 0.06),
                        value: appeared)
            }
        }
        .frame(height: 74)
        .onAppear { appeared = true }
    }
}

/// A copyable one-line shell command.
struct TrackBSnippet: View {

    let command: String
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: "$")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(command)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
            Button {
                TrackBClipboard.copy(command)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.6))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(copied ? Color.green : Theme.accent)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy command")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(hovering ? 0.8 : 0.5),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5))
        .onHover { hovering = $0 }
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

/// One row of a key/value table, used by the Overview tab.
struct TrackBFieldRow<Value: View>: View {

    let label: String
    var labelWidth: CGFloat = 116
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .trailing)
            value
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A titled group of rows, with the hairline card treatment used across the detail pane.
struct TrackBSection<Content: View>: View {

    let title: String
    var symbol: String?
    var count: Int?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            content
        }
    }
}

/// Text that never wraps and shows the whole value on hover — paths, image digests,
/// command lines, all the things that are too long for the pane but must stay exact.
struct TrackBMonoText: View {

    let text: String
    var size: CGFloat = 11.5
    var tint: Color = .primary

    var body: some View {
        Text(text)
            .font(.system(size: size, design: .monospaced))
            .foregroundStyle(tint)
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(text)
    }
}

/// A compact, borderless icon button — the hover actions on a row and the little
/// controls in the log toolbar.
struct TrackBIconButton: View {

    let symbol: String
    let help: String
    var tint: Color = .primary
    var isProminent: Bool = false
    var shortcut: KeyEquivalent?
    var modifiers: EventModifiers = .command
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering || isProminent ? tint : Color.secondary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(tint.opacity(hovering ? 0.16 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .modifier(TrackBOptionalShortcut(key: shortcut, modifiers: modifiers))
    }
}

/// `keyboardShortcut` has no "maybe" form, so this supplies one.
private struct TrackBOptionalShortcut: ViewModifier {
    let key: KeyEquivalent?
    let modifiers: EventModifiers

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(key, modifiers: modifiers)
        } else {
            content
        }
    }
}
