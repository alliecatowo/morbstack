// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Empty states, built on the system's own.
//
// `ContentUnavailableView` is macOS 14 — it is available at our deployment target, needs
// no gate, and already gets the icon size, the type ranks, the vertical rhythm and the
// dynamic-type behaviour right. The current build reimplements it by hand in
// `EngineStoppedView` (a 110pt lavender disc, roughly three times the system's icon, and
// a fully-rounded capsule primary button, which macOS does not use) and reimplements it
// *differently* in `PlaceholderView`.
//
// So this file is deliberately thin. It exists to stop anyone building a third one.

import SwiftUI

// MARK: - Empty state

/// The app's empty state. A `ContentUnavailableView` with the design system's button
/// treatment applied to the primary action.
///
/// Replaces the hand-built empty state in `Views/Placeholders/PlaceholderView.swift` and
/// the one inside `App.swift`'s `EngineStoppedView`.
///
/// ```swift
/// MorbEmptyState(
///     "The engine isn’t running",
///     systemImage: "shippingbox",
///     description: "Start it to see your containers, images and volumes.",
///     actionTitle: "Start Engine",
///     action: { Task { await model.engineAction(.start) } })
/// ```
struct MorbEmptyState<Actions: View>: View {

    var title: String
    var systemImage: String
    var description: String?
    /// A quiet line pinned under the actions: the "Morbstack runs Docker in a lightweight
    /// virtual machine." footnote. Kept *inside* the empty state's stack rather than
    /// bottom-anchored to the window, where it is currently floating 450pt away from
    /// anything it relates to.
    var footnote: String?
    @ViewBuilder var actions: Actions

    init(_ title: String,
         systemImage: String,
         description: String? = nil,
         footnote: String? = nil,
         @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.footnote = footnote
        self.actions = actions()
    }

    var body: some View {
        ContentUnavailableView {
            // The tint goes on the *icon*, not on the whole view. A `foregroundStyle` on
            // `ContentUnavailableView` colours the title and the description too, which
            // turns the headline indigo and destroys the type hierarchy.
            Label {
                Text(title)
            } icon: {
                MorbBrandSymbol(systemImage: systemImage)
            }
        } description: {
            if let description { Text(description) }
        } actions: {
            VStack(spacing: Theme.space4) {
                actions
                if let footnote {
                    Text(footnote)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.top, Theme.space2)
        }
    }
}

/// An SF Symbol in the brand colour, rendered as a gradient on macOS 26.
///
/// `symbolColorRenderingMode(.gradient)` is macOS 26.0 — verified in
/// `docs/design/SDK-LIQUID-GLASS.md` §2.14 — so it is gated here rather than at every call
/// site. Below 26 the symbol is flat `Theme.brand`, which is the correct-looking fallback
/// rather than a degraded one.
struct MorbBrandSymbol: View {

    var systemImage: String

    var body: some View {
        if #available(macOS 26.0, *) {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.brand)
                .symbolColorRenderingMode(.gradient)
        } else {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.brand)
        }
    }
}

extension MorbEmptyState where Actions == EmptyView {

    /// No action — for a screen that is empty because nothing has happened yet.
    init(_ title: String, systemImage: String, description: String? = nil, footnote: String? = nil) {
        self.init(title, systemImage: systemImage, description: description,
                  footnote: footnote) { EmptyView() }
    }
}

extension MorbEmptyState where Actions == Button<Text> {

    /// The common case: one primary action.
    init(_ title: String,
         systemImage: String,
         description: String? = nil,
         footnote: String? = nil,
         actionTitle: String,
         action: @escaping () -> Void) {
        self.init(title, systemImage: systemImage, description: description,
                  footnote: footnote) {
            Button(actionTitle, action: action)
        }
    }
}

// MARK: - Filter empty state

/// "Nothing matches your filter."
///
/// `ContentUnavailableView.search(text:)` localises itself and matches Finder and Mail.
/// Every list in the app that has a filter field needs one of these and none of them has
/// one — filtering to zero results currently shows an empty table.
struct MorbNoMatches: View {

    var query: String

    var body: some View {
        ContentUnavailableView.search(text: query)
    }
}

// MARK: - Loading

/// The one loading state. Deliberately not a full-screen spinner: a spinner that fills a
/// window reads as "broken" after about a second.
struct MorbLoading: View {

    var label: String?

    var body: some View {
        VStack(spacing: Theme.space4) {
            ProgressView()
                .controlSize(.small)
            if let label {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(label ?? "Loading")
    }
}

