// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Shared chrome for the Track D surfaces: menu bar, command palette, settings,
// stacks and the two roadmap placeholders.
//
// `TrackD`-prefixed on purpose. These are conveniences for one track's screens, not a
// bid to become the app's design system — when the same need appears in a third track
// the right move is to promote a real component into Theme.swift and delete the copy
// here, not to widen this file.

import AppKit
import MorbstackKit
import SwiftUI

// MARK: - Tone

/// The tones these screens speak in.
///
/// Every colour comes from ``Theme`` rather than from the system palette: Track A
/// hand-tuned those pairs for a material sidebar in both appearances, and a menu bar
/// dot in `.green` next to a sidebar dot in `Theme.statusRunning` is exactly the kind
/// of half-millimetre mismatch that makes an app feel assembled rather than designed.
enum TrackDTone: Hashable {
    case neutral, good, warn, paused, bad, accent

    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .good: return Theme.statusRunning
        case .warn: return Theme.statusBusy
        case .paused: return Theme.statusPaused
        case .bad: return Theme.statusBad
        // Deliberately the *system* accent, not `Theme.brand`: the indigo is reserved
        // for the sidebar selection, and everything clickable should follow whatever
        // accent colour the user picked in System Settings.
        case .accent: return Theme.accent
        }
    }

    init(_ status: StatusTone) {
        switch status {
        case .running: self = .good
        case .idle: self = .neutral
        case .busy: self = .warn
        case .paused: self = .paused
        case .bad: self = .bad
        }
    }

    /// The tone for a container's `state`, with health folded in.
    static func container(state: String, unhealthy: Bool = false) -> TrackDTone {
        TrackDTone(StatusTone.forContainer(state: state, unhealthy: unhealthy))
    }

    /// The tone for the engine as a whole.
    static func engine(_ status: EngineStatus) -> TrackDTone {
        TrackDTone(StatusTone.forEngine(status))
    }
}

// MARK: - Dots and pills

/// The status dot, in ``TrackDTone`` terms.
///
/// Same geometry and the same hairline ring as ``StatusDot`` — this exists only so the
/// Track D surfaces can pass a `TrackDTone` without converting at every call site.
struct TrackDStatusDot: View {
    var tone: TrackDTone
    var size: CGFloat = 7
    /// Set for transitional states; a slow pulse says "this is still moving".
    var pulsing: Bool = false

    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(tone.color)
            .frame(width: size, height: size)
            .overlay {
                Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
            .opacity(pulsing && pulse ? 0.35 : 1)
            .animation(
                pulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                value: pulse
            )
            .onAppear { if pulsing { pulse = true } }
            .padding(1)
    }
}

/// A small pill for counts and states — ``Chip`` with a `TrackDTone`.
struct TrackDBadge: View {
    let text: String
    var symbol: String?
    var tone: TrackDTone = .neutral

    var body: some View {
        Chip(text: text, tone: tone.color, symbol: symbol)
    }
}

// MARK: - Buttons

/// A full-width row that lights up on hover and on keyboard focus.
///
/// Focus gets the accent wash rather than the system focus ring: inside a menu-bar
/// popover the ring is clipped by the window's rounded corner and reads as a glitch,
/// while a filled row reads the way a highlighted menu item does.
struct TrackDRowButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 6
    var horizontalPadding: CGFloat = 8
    var verticalPadding: CGFloat = 5

    func makeBody(configuration: Configuration) -> some View {
        TrackDRowButtonBody(
            configuration: configuration,
            cornerRadius: cornerRadius,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding)
    }
}

private struct TrackDRowButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let cornerRadius: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat

    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    private var highlighted: Bool { (hovering || focused) && enabled }

    var body: some View {
        configuration.label
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.accent.opacity(configuration.isPressed ? 0.26 : (highlighted ? 0.16 : 0)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(focused ? 0.55 : 0), lineWidth: 1)
            }
            .contentShape(.rect(cornerRadius: cornerRadius, style: .continuous))
            .opacity(enabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.12), value: highlighted)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

/// A borderless icon button sized for a 20pt row — used for the per-row stop/start
/// affordances that appear on hover.
struct TrackDIconButton: View {
    let symbol: String
    let help: String
    var tone: TrackDTone = .neutral
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovering ? AnyShapeStyle(tone.color) : AnyShapeStyle(.secondary))
                .frame(width: 20, height: 18)
                .background(
                    (tone == .neutral ? Color.secondary : tone.color).opacity(hovering ? 0.16 : 0),
                    in: .rect(cornerRadius: 5, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Section headers

/// The all-caps micro heading that separates popover and card sections, with an
/// optional count on the right.
struct TrackDSectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(spacing: 6) {
            SectionLabel(text: title)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Empty state

/// The centred "nothing here yet" block, shared by Stacks and the placeholders.
struct TrackDEmptyState<Accessory: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 38, weight: .ultraLight))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)
            VStack(spacing: 5) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .fixedSize(horizontal: false, vertical: true)
            }
            accessory
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

extension TrackDEmptyState where Accessory == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message, accessory: { EmptyView() })
    }
}

// MARK: - Monospaced path row

/// A path with a copy button — used all over Settings' Advanced tab.
struct TrackDPathRow: View {
    let label: String
    let path: String
    var symbol: String = "folder"

    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.callout)
                Text(path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button {
                trackDCopy(path)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .help("Copy \(label.lowercased())")
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(1.6))
                guard !Task.isCancelled else { return }
                copied = false
            }
        }
    }
}

// MARK: - Helpers

/// Copies `string` to the general pasteboard.
@MainActor
func trackDCopy(_ string: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
}

/// Opens `url` in the user's browser.
@MainActor
func trackDOpen(_ url: URL) {
    NSWorkspace.shared.open(url)
}

/// A short, human-facing rendering of anything thrown by the clients.
///
/// `MorbError` and `DockerClientError` both already produce a printable sentence;
/// everything else falls back to `localizedDescription`. Note the order — a blanket
/// `as? CustomStringConvertible` would succeed for every `Error` and hand back
/// `Error Domain=NSPOSIXErrorDomain Code=2 …` for an ordinary missing socket.
func trackDErrorText(_ error: Error) -> String {
    if let morb = error as? MorbError { return morb.description }
    if let localized = error as? LocalizedError, let text = localized.errorDescription, !text.isEmpty {
        return text
    }
    return error.localizedDescription
}
