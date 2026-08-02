// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Shared chrome for the Track D surfaces: menu bar, command palette, settings and the
// one remaining roadmap placeholder.
//
// `TrackD`-prefixed on purpose. These are conveniences for one track's screens, not a
// bid to become the app's design system — when the same need appears in a third track
// the right move is to promote a real component into Theme.swift and delete the copy
// here, not to widen this file. Several already made that move during the Liquid Glass
// rewrite: the dot, the icon button, the section header and the empty state that used
// to live here are now ``MorbStatusDot``, ``MorbIconButton``, ``MorbSectionHeader`` and
// ``MorbEmptyState`` in `Design/`. What is left is what genuinely does not generalise —
// `TrackDTone`'s mapping from a container/engine state to a colour, the popover's own
// hover/focus row style, and the path row Settings uses six times.

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

// MARK: - Buttons

/// A full-width row that lights up on hover and on keyboard focus.
///
/// Focus gets the accent wash rather than the system focus ring: inside a menu-bar
/// popover the ring is clipped by the window's rounded corner and reads as a glitch,
/// while a filled row reads the way a highlighted menu item does.
///
/// `verticalPadding` defaults to zero on purpose: every row this style is applied to
/// already declares its own exact height via `.frame(height: Theme.rowCompact)`, so a
/// style-level vertical pad would silently re-inflate the 24pt rhythm the popover was
/// rebuilt to have — which is exactly how it grew to 80pt rows the first time.
struct TrackDRowButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = Theme.radiusChip + 1
    var horizontalPadding: CGFloat = Theme.space3
    var verticalPadding: CGFloat = 0

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

// MARK: - Monospaced path row

/// A path with a copy button — used all over Settings' Advanced tab.
struct TrackDPathRow: View {
    let label: String
    let path: String
    var symbol: String = "folder"

    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.space3) {
            VStack(alignment: .leading, spacing: Theme.space1) {
                Text(label)
                    .font(.callout)
                Text(path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Theme.space3)
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
