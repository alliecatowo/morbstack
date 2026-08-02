// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// What is left of the resource screens' own vocabulary once the shared `Design/` system
// covers status, chips, rows, cards, empty states and the toolbar: a palette shared by
// the four screens, a transient toast (not something `Design/` has an opinion on), a
// pasteboard helper and an error-text helper.
//
// `TrackCTone`, `TrackCStatusDot` and `TrackCBadge` stay here — and stay exactly as they
// were — because they are load-bearing outside this track: `Settings/TrackDSharingSettings.swift`
// and `Sharing/FileSharingStatus.swift` (both owned by UI-3) already depend on them at the
// base commit. Everything else that used to live here (the hand-drawn page header, search
// field, sort header, table row helpers) is gone: Images, Volumes, Networks and Disk now
// get their chrome from `.morbScreen`, `.searchable`, a real `.toolbar` and a real `Table`,
// per `docs/design/COMPONENTS.md`.

import AppKit
import SwiftUI

// MARK: - Palette

/// The four colours the resource screens agree on for the disk category breakdown.
///
/// Deliberately `Theme`'s categorical sequence rather than `.blue` / `.teal` / `.purple` /
/// `.orange`: the system colours are each fine on their own and terrible together, and a
/// stacked bar built out of them reads as decoration instead of data.
enum TrackCPalette {
    // Indigo and violet are the two closest hues in the set, so they sit at opposite ends
    // where they can never touch: images, containers, volumes, build cache reads indigo,
    // amber, teal, violet, and every adjacent pair is at least 90° apart.
    static let images = Theme.seriesIndigo
    static let containers = Theme.seriesAmber
    static let volumes = Theme.seriesTeal
    static let buildCache = Theme.seriesViolet
}

// MARK: - Legacy tone (kept for cross-track compatibility)

/// A small, free-form status colour.
///
/// New code in this track uses `StatusTone` and `MorbChipRank` instead — see
/// `docs/design/COMPONENTS.md` §3–4. This type stays because two files outside this
/// track's ownership already depend on it at the base commit:
/// `Settings/TrackDSharingSettings.swift` and `Sharing/FileSharingStatus.swift`, both
/// owned by UI-3. Forking a second copy or renaming this one would break their build for
/// a cross-file rename this change is not allowed to make.
enum TrackCTone {
    case neutral, good, warn, bad, accent

    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .good: return Theme.statusRunning
        case .warn: return Theme.statusBusy
        case .bad: return Theme.statusBad
        case .accent: return Theme.accent
        }
    }
}

/// The status dot `TrackDSharingSettings` and `FileSharingStatus` already call.
///
/// Restyled onto `Theme.dotSize` and a hairline ring so it reads as the same object as
/// `MorbStatusDot` even though it takes the legacy `TrackCTone` rather than `StatusTone`.
struct TrackCStatusDot: View {
    var tone: TrackCTone

    var body: some View {
        Circle()
            .fill(tone.color)
            .frame(width: Theme.dotSize, height: Theme.dotSize)
            .overlay { Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5) }
    }
}

/// The small pill `TrackDSharingSettings` already calls for "read-only".
///
/// Restyled onto `MorbChip`'s metrics (`Theme.radiusChip`, `Theme.chipAlpha`) so it reads
/// as the same object even though its colour comes from the legacy `TrackCTone`.
struct TrackCBadge: View {
    let text: String
    var symbol: String?
    var tone: TrackCTone = .neutral

    var body: some View {
        HStack(spacing: Theme.space1 + 1) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            }
            Text(text).font(.caption2.weight(.medium))
        }
        .monospacedDigit()
        .foregroundStyle(tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(tone.color))
        .padding(.horizontal, Theme.space3 - 2)
        .padding(.vertical, Theme.space1)
        .background(
            (tone == .neutral ? Color.secondary : tone.color).opacity(Theme.chipAlpha),
            in: RoundedRectangle(cornerRadius: Theme.radiusChip, style: .continuous))
    }
}

// MARK: - Sort comparators

/// The direction-aware reverse of a `ComparisonResult`.
extension ComparisonResult {
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}

/// Natural string order — `nginx:9` before `nginx:10` — the comparison every text column
/// in these tables wants.
func trackCCompareStrings(_ lhs: String, _ rhs: String) -> ComparisonResult {
    lhs.localizedStandardCompare(rhs)
}

/// Orders an optional integer, treating "not reported" as the lowest value so the unknown
/// rows cluster at one end instead of scattering through the table.
func trackCCompareOptionalInt(_ lhs: Int64?, _ rhs: Int64?) -> ComparisonResult {
    let left = lhs ?? -1, right = rhs ?? -1
    if left == right { return .orderedSame }
    return left < right ? .orderedAscending : .orderedDescending
}

func trackCCompareInt(_ lhs: Int, _ rhs: Int) -> ComparisonResult {
    if lhs == rhs { return .orderedSame }
    return lhs < rhs ? .orderedAscending : .orderedDescending
}

func trackCCompareDate(_ lhs: Date, _ rhs: Date) -> ComparisonResult {
    if lhs == rhs { return .orderedSame }
    return lhs < rhs ? .orderedAscending : .orderedDescending
}

// MARK: - Toasts

/// A transient, non-blocking result message — "Reclaimed 1.2 GB", "Removed nginx:alpine".
///
/// Prune and remove are the two operations on these screens that succeed silently and
/// invisibly (the row simply vanishes), so they are exactly the ones that need to say how
/// many bytes came back. Not something `Design/` has an opinion on, so it stays local.
struct TrackCToast: Identifiable, Equatable {
    let id = UUID()
    var symbol: String
    var message: String
    var detail: String?
    var tone: StatusTone = .running

    static func success(_ message: String, detail: String? = nil) -> TrackCToast {
        TrackCToast(symbol: "checkmark.circle.fill", message: message, detail: detail, tone: .running)
    }

    static func failure(_ message: String, detail: String? = nil) -> TrackCToast {
        TrackCToast(symbol: "exclamationmark.triangle.fill", message: message, detail: detail, tone: .bad)
    }

    static func info(_ message: String, detail: String? = nil) -> TrackCToast {
        TrackCToast(symbol: "info.circle.fill", message: message, detail: detail, tone: .idle)
    }

    static func == (lhs: TrackCToast, rhs: TrackCToast) -> Bool { lhs.id == rhs.id }
}

struct TrackCToastView: View {
    let toast: TrackCToast

    var body: some View {
        HStack(spacing: Theme.space3) {
            Image(systemName: toast.symbol)
                .foregroundStyle(toast.tone == .idle ? AnyShapeStyle(.secondary) : AnyShapeStyle(toast.tone.color))
                .font(.callout)
            VStack(alignment: .leading, spacing: Theme.space1) {
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
        .padding(.horizontal, Theme.space4 + 2)
        .padding(.vertical, Theme.space3 + 2)
        .morbGlass(.control, radius: Theme.radiusCard)
        .frame(maxWidth: 420)
    }
}

private struct TrackCToastModifier: ViewModifier {
    @Binding var toast: TrackCToast?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast {
                    TrackCToastView(toast: toast)
                        .padding(.bottom, Theme.space5 + 2)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: toast.id) {
                            // Cancelled automatically when the toast is replaced or the
                            // view goes away, so a burst of prunes can't leave a stale
                            // timer that clears a newer message.
                            try? await Task.sleep(for: .seconds(4))
                            guard !Task.isCancelled else { return }
                            withAnimation(Theme.animation(.subtle, reduceMotion: reduceMotion)) {
                                self.toast = nil
                            }
                        }
                }
            }
            .morbAnimation(.subtle, value: toast)
    }
}

extension View {
    /// Presents `toast` at the bottom of the view and clears it after four seconds.
    func trackCToast(_ toast: Binding<TrackCToast?>) -> some View {
        modifier(TrackCToastModifier(toast: toast))
    }
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
/// `errorDescription`; a plain `Error`'s `localizedDescription` tends to produce the "The
/// operation couldn't be completed" boilerplate, so prefer the former where it exists.
func trackCErrorText(_ error: Error) -> String {
    if let described = (error as? LocalizedError)?.errorDescription, !described.isEmpty {
        return described
    }
    return error.localizedDescription
}
