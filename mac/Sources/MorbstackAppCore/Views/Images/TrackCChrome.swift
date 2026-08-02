// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Shared chrome for the resource screens (Images, Volumes, Networks, Disk).
//
// Everything here is `TrackC`-prefixed on purpose: these are private conveniences for
// one track's four screens, not a bid to become the app's design system. When the same
// need shows up in two more tracks the right move is to promote a real component into
// Theme.swift and delete the copy here, not to widen this file.

import AppKit
import SwiftUI

// MARK: - Palette

/// The four colours the resource screens agree on.
///
/// Deliberately SwiftUI's semantic system colours rather than hard-coded hexes: they
/// are the ones that already shift correctly between light and dark and pick up the
/// user's "increase contrast" setting, which a hand-rolled palette would not.
enum TrackCPalette {
    // The four disk categories, taken from `Theme`'s categorical sequence rather than
    // from `.blue` / `.teal` / `.purple` / `.orange`. The system colours are each fine
    // on their own and terrible together: no shared saturation, no shared lightness, and
    // a stacked bar built out of them reads as decoration instead of data.
    //
    // The assignment is chosen for the *bar*, which always draws them in this order.
    // Indigo and violet are the two closest hues in the set, so they are put at opposite
    // ends where they can never touch: images → containers → volumes → build cache reads
    // indigo, amber, teal, violet, and every adjacent pair is at least 90° apart. The
    // first attempt ran indigo, teal, violet, amber, and because containers are usually a
    // sliver the eye saw indigo abutting violet across a 5% gap.
    static let images = Theme.seriesIndigo
    static let containers = Theme.seriesAmber
    static let volumes = Theme.seriesTeal
    static let buildCache = Theme.seriesViolet

    /// Ink for the reclaimable hatch. Drawn over the coloured bar, so it needs to read
    /// against every segment colour at once — plain foreground at low alpha does.
    static let reclaimable = Color.primary
}

// MARK: - Page header

/// The title block every resource screen starts with.
///
/// Fixed 16pt gutters and a 2pt title/subtitle gap keep the four screens on the same
/// baseline grid, which is the difference between "four views" and "one app".
struct TrackCPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 16)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }
}

// MARK: - Search field

/// A search field that looks like the sidebar's, not like a form control.
struct TrackCSearchField: View {
    @Binding var text: String
    var prompt: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($focused)
                .onSubmit { focused = false }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(focused ? 0.55 : 0.35), in: .rect(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.accent.opacity(focused ? 0.65 : 0), lineWidth: 1.5)
        }
        .animation(.easeOut(duration: 0.14), value: focused)
        .frame(width: 210)
    }
}

// MARK: - Badges and dots

enum TrackCTone {
    case neutral, good, warn, bad, accent

    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .good: return .green
        case .warn: return .orange
        case .bad: return .red
        case .accent: return Theme.accent
        }
    }
}

/// A small capsule used for counts and states inside table rows.
struct TrackCBadge: View {
    let text: String
    var symbol: String?
    var tone: TrackCTone = .neutral

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(.caption2.weight(.medium))
                .monospacedDigit()
        }
        .foregroundStyle(tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(tone.color))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            (tone == .neutral ? Color.secondary : tone.color).opacity(0.14),
            in: .capsule
        )
    }
}

/// The 7pt status dot the whole app uses, with a faint halo so it survives on the
/// alternating row backgrounds of an inset table.
struct TrackCStatusDot: View {
    var tone: TrackCTone

    var body: some View {
        Circle()
            .fill(tone.color)
            .frame(width: 7, height: 7)
            .overlay { Circle().strokeBorder(tone.color.opacity(0.28), lineWidth: 3).blur(radius: 0.6) }
            .padding(1)
    }
}

// MARK: - Toasts

/// A transient, non-blocking result message — "Reclaimed 1.2 GB", "Removed nginx:alpine".
///
/// Prune and remove are the two operations on these screens that succeed silently and
/// invisibly (the row simply vanishes), so they are exactly the ones that need to say
/// how many bytes came back.
struct TrackCToast: Identifiable, Equatable {
    let id = UUID()
    var symbol: String
    var message: String
    var detail: String?
    var tone: TrackCTone = .good

    static func success(_ message: String, detail: String? = nil) -> TrackCToast {
        TrackCToast(symbol: "checkmark.circle.fill", message: message, detail: detail, tone: .good)
    }

    static func failure(_ message: String, detail: String? = nil) -> TrackCToast {
        TrackCToast(symbol: "exclamationmark.triangle.fill", message: message, detail: detail, tone: .bad)
    }

    static func info(_ message: String, detail: String? = nil) -> TrackCToast {
        TrackCToast(symbol: "info.circle.fill", message: message, detail: detail, tone: .accent)
    }

    static func == (lhs: TrackCToast, rhs: TrackCToast) -> Bool { lhs.id == rhs.id }
}

struct TrackCToastView: View {
    let toast: TrackCToast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.symbol)
                .foregroundStyle(toast.tone.color)
                .font(.callout)
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.message)
                    .font(.callout.weight(.medium))
                if let detail = toast.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .rect(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(.separator.opacity(0.7), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .frame(maxWidth: 420)
    }
}

private struct TrackCToastModifier: ViewModifier {
    @Binding var toast: TrackCToast?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast {
                    TrackCToastView(toast: toast)
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: toast.id) {
                            // Cancelled automatically when the toast is replaced or the
                            // view goes away, so a burst of prunes can't leave a stale
                            // timer that clears a newer message.
                            try? await Task.sleep(for: .seconds(4))
                            guard !Task.isCancelled else { return }
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                                self.toast = nil
                            }
                        }
                }
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: toast)
    }
}

extension View {
    /// Presents `toast` at the bottom of the view and clears it after four seconds.
    func trackCToast(_ toast: Binding<TrackCToast?>) -> some View {
        modifier(TrackCToastModifier(toast: toast))
    }
}

// MARK: - Empty state

struct TrackCEmptyState: View {
    let title: String
    let message: String
    let symbol: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(.bordered)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

// MARK: - Table cell helpers

/// Right-aligned monospaced figures. Used for every byte and count column so the
/// digits line up down the table instead of dancing.
struct TrackCNumberCell: View {
    let text: String
    var emphasised: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Text(text)
                .font(.callout.monospacedDigit())
                .foregroundStyle(emphasised ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .padding(.trailing, 2)
    }
}

/// Row actions that brighten on hover but stay reachable without one.
///
/// `revealed` comes from the *row's* hover state rather than the buttons' own, so the
/// controls light up as soon as the pointer is anywhere on the row — hovering a 14pt
/// glyph to discover that it was clickable is not a discovery mechanism. They stay at
/// 42% and fully hit-testable at rest so keyboard and trackpad users are not chasing an
/// invisible target, and every caller duplicates them into a context menu.
struct TrackCHoverActions<Content: View>: View {
    var revealed: Bool
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 2) {
            Spacer(minLength: 0)
            content
        }
        .buttonStyle(.borderless)
        .opacity(revealed ? 1 : 0.42)
        .animation(.easeOut(duration: 0.12), value: revealed)
    }
}

/// A symbol-only row action.
///
/// Fixed 22×20 so a row of them keeps a rhythm regardless of glyph width, and always
/// carries a `help` string: an icon with no tooltip is a puzzle.
struct TrackCRowButton: View {
    let symbol: String
    let help: String
    var tone: TrackCTone = .neutral
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 20)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(tone.color))
        .help(help)
    }
}

// MARK: - Column headers

/// A clickable column header carrying the sort caret.
///
/// The four resource screens roll their own tables on top of `List` rather than using
/// SwiftUI's `Table`: they need grouped sections (tagged versus dangling images),
/// row-level hover reveal, and mixed sortable/unsortable columns, and `Table` gives up
/// at least one of those. The cost is that column widths live in a per-screen constant
/// and the header has to be drawn by hand — this is that header.
struct TrackCSortHeader<Key: Equatable>: View {
    let title: String
    let key: Key
    @Binding var active: Key
    @Binding var ascending: Bool
    var alignment: Alignment = .leading

    private var isActive: Bool { active == key }

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.14)) {
                if isActive { ascending.toggle() } else { active = key; ascending = true }
            }
        } label: {
            HStack(spacing: 3) {
                if alignment == .trailing { Spacer(minLength: 0) }
                // On a right-aligned column the chevron goes *before* the title, so the
                // title's right edge lands on the same pixel as the digits underneath
                // it. With the chevron trailing — and it reserves its width even when
                // hidden — every numeric header sat about 13pt left of its own column
                // and the table read as slightly out of register all the way down.
                if alignment == .trailing { chevron }
                Text(title)
                    .font(.caption.weight(isActive ? .semibold : .regular))
                if alignment != .trailing { chevron }
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var chevron: some View {
        Image(systemName: ascending ? "chevron.up" : "chevron.down")
            .font(.system(size: 7, weight: .bold))
            .opacity(isActive ? 1 : 0)
    }
}

/// A non-interactive column label, for columns there is no sensible sort for.
struct TrackCPlainHeader: View {
    let title: String
    var alignment: Alignment = .leading

    var body: some View {
        HStack(spacing: 0) {
            if alignment == .trailing { Spacer(minLength: 0) }
            Text(title).font(.caption).foregroundStyle(.secondary)
            if alignment == .leading { Spacer(minLength: 0) }
        }
    }
}

/// The strip that holds a screen's column headers, aligned to the list's insets.
///
/// The 20pt leading pad matches `List`'s own inset-style gutter, which is what keeps the
/// header text sitting directly above its column instead of a few points to the left.
struct TrackCHeaderBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: TrackCMetrics.columnGap) {
            content
        }
        .padding(.leading, 20)
        .padding(.trailing, 26)
        .padding(.bottom, 5)
    }
}

/// The handful of numbers the four screens agree on, so the 8pt grid survives edits.
enum TrackCMetrics {
    /// Space between adjacent columns, in both the header and every row.
    static let columnGap: CGFloat = 12
    /// Height of a table row's content, before List's own padding.
    static let rowHeight: CGFloat = 26
    /// Gutter used by page headers, toolbars and footers.
    static let gutter: CGFloat = 16
}

// MARK: - Pasteboard

/// Copies `string` to the general pasteboard.
@MainActor
func trackCCopy(_ string: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
}

// MARK: - Error text

/// A short, human-facing rendering of anything thrown by `DockerClient`.
///
/// `DockerClientError` and `MorbError` both spell out a real sentence in
/// `errorDescription`; a plain `Error`'s `localizedDescription` tends to produce the
/// "The operation couldn't be completed" boilerplate, so prefer the former where it
/// exists. Casting to `LocalizedError` rather than `CustomStringConvertible`, because
/// every `Error` satisfies the latter and the cast would never fall through.
func trackCErrorText(_ error: Error) -> String {
    if let described = (error as? LocalizedError)?.errorDescription, !described.isEmpty {
        return described
    }
    return error.localizedDescription
}
