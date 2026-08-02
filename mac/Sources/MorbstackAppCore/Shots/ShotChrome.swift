// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The bits of window chrome AppKit refuses to draw into a bitmap.
//
// A `NSVisualEffectView` samples what is *behind the window* on the display server. An
// offscreen window has nothing behind it, and `displayIgnoringOpacity(_:in:)` never gets
// as far as asking: the effect view contributes nothing at all, and — because a vibrant
// sidebar draws its labels with a blend mode that composites against that missing
// backdrop — neither do its contents. The first run of the harness produced a window with
// a hole where the sidebar should be, in both appearances.
//
// So the materials are substituted, not faked around. Each constant below is the colour
// the corresponding material actually resolves to on a default desktop, measured rather
// than guessed, so a reader of the screenshot sees the same sidebar they would see on
// their own machine — just without the wallpaper bleeding through it.

import AppKit
import SwiftUI

enum ShotChrome {

    /// What `.listStyle(.sidebar)`'s material resolves to over a neutral desktop.
    static let sidebarBackground = Color(
        light: Color(red: 0.910, green: 0.910, blue: 0.922),
        dark: Color(red: 0.153, green: 0.153, blue: 0.165))

    /// What `.thinMaterial` toolbars and popover backdrops resolve to.
    static let barBackground = Color(
        light: Color(red: 0.957, green: 0.957, blue: 0.965),
        dark: Color(red: 0.196, green: 0.196, blue: 0.208))

    /// The popover body: `.regularMaterial` over the menu bar.
    static let popoverBackground = Color(
        light: Color(red: 0.965, green: 0.965, blue: 0.973),
        dark: Color(red: 0.169, green: 0.169, blue: 0.180))

    /// The desktop a menu-bar popover hangs over. Not a photograph — a screenshot of the
    /// popover wants the popover to be the subject, and a wallpaper behind it is noise —
    /// but not flat grey either, because the popover's shadow and rounded corners need
    /// something to sit on to read as a floating panel at all.
    static var desktop: LinearGradient {
        LinearGradient(
            colors: [
                Color(light: Color(red: 0.42, green: 0.45, blue: 0.60),
                      dark: Color(red: 0.13, green: 0.14, blue: 0.22)),
                Color(light: Color(red: 0.62, green: 0.58, blue: 0.72),
                      dark: Color(red: 0.22, green: 0.18, blue: 0.30)),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
    }
}
