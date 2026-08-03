// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// The mark, in SwiftUI.
//
// **More Orb, open Stack**: a solid orb resting on a stack of full-width slabs, with the
// topmost slab passing *behind* it — interrupted by a hard gradient-coloured gap and
// resuming on the other side. The gap is the whole drawing: without it the two shapes fuse
// into a lollipop, which is what the current icon does below about 36 px.
//
// The compositions that were tried and rejected — a right-staggered stack (reads as an
// avatar over lines of text), slabs narrowing upward (a trophy), and slabs crossing the
// orb's middle (a striped ball, i.e. the current icon's failure) — are recorded in
// `IDENTITY.md` §1.1b so nobody re-derives them.
//
// The geometry here is the *same* geometry as `mac/AppResources/make-icon.swift`, stated
// once in `docs/design/IDENTITY.md` §1 and implemented twice: once in CoreGraphics for
// the `.icns`, once here for the sidebar header, the About box and the engine-stopped
// state. If the two ever disagree, the document is the spec.
//
// This is the only place in the app that draws the logo. Nobody re-implements it, and
// nothing else uses `Theme.brandGradient`.

import SwiftUI

// MARK: - Geometry

/// The mark's unit geometry. Fractions of the plate, origin **top-left** (SwiftUI's
/// convention — `make-icon.swift` uses CoreGraphics' bottom-left origin and flips `v`).
enum MorbMarkGeometry {

    /// Orb centre. Bottom-up `v = 0.650`, flipped for SwiftUI.
    static let orbCentre = CGPoint(x: 0.500, y: 1 - 0.650)

    /// Orb radius, as a fraction of the plate width.
    ///
    /// `0.235`, not `0.240`: at `0.240` the halo (radius `R + gap`) cuts a shallow notch
    /// into the *middle* slab's top edge, which reads as a rendering fault rather than as
    /// depth. See `IDENTITY.md` §1.5 for the arithmetic.
    static let orbRadius: CGFloat = 0.235

    /// Slabs run nearly the full plate width and are all centred. Full-bleed and equal is
    /// what makes them read as plates; ragged lengths read as lines of text.
    static let slabCentreX: CGFloat = 0.500
    static let slabWidth: CGFloat = 0.860

    /// The gradient-coloured gap between the orb and the slab it crosses, as a fraction
    /// of the plate width — floored at one device pixel by the caller.
    static let gapFraction: CGFloat = 0.028

    /// Detail level. Three slabs at large sizes, two at small, so the same composition
    /// survives 16 pt without turning grey. Both occupy the band `v ≈ [0.10, 0.55]`, so
    /// the silhouette does not jump when the level changes.
    enum Detail: Sendable {
        case full, compact

        /// 64 px canvas ≈ 52.7 pt plate. Below that, three slabs are under 3 px tall.
        static func forPlateWidth(_ w: CGFloat) -> Detail {
            w >= 52 ? .full : .compact
        }

        var slabCount: Int { self == .full ? 3 : 2 }
        var slabHeight: CGFloat { self == .full ? 0.105 : 0.150 }
        var slabPitch: CGFloat { self == .full ? 0.170 : 0.285 }
        var lowestCentre: CGFloat { self == .full ? 0.155 : 0.185 }
    }

    /// Slab `i`, 0 = bottom, in unit space with a top-left origin.
    static func slab(_ i: Int, detail: Detail) -> CGRect {
        let h = detail.slabHeight
        let centreUp = detail.lowestCentre + CGFloat(i) * detail.slabPitch
        return CGRect(x: slabCentreX - slabWidth / 2,
                      y: (1 - centreUp) - h / 2,
                      width: slabWidth,
                      height: h)
    }
}

// MARK: - Shapes

/// The three (or two) staggered slabs.
struct MorbStackShape: Shape {

    func path(in rect: CGRect) -> Path {
        let w = min(rect.width, rect.height)
        let detail = MorbMarkGeometry.Detail.forPlateWidth(w)
        let radius = min(detail.slabHeight / 2, 0.030) * w
        var path = Path()
        for i in 0..<detail.slabCount {
            let u = MorbMarkGeometry.slab(i, detail: detail)
            let r = CGRect(x: rect.minX + u.minX * w,
                           y: rect.minY + u.minY * w,
                           width: u.width * w,
                           height: u.height * w)
            path.addRoundedRect(in: r, cornerSize: CGSize(width: radius, height: radius),
                                style: .continuous)
        }
        return path
    }
}

/// The orb.
struct MorbOrbShape: Shape {

    /// Grow the disc by this many points — used to punch the gap out of the stack.
    var inflate: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let w = min(rect.width, rect.height)
        let r = MorbMarkGeometry.orbRadius * w + inflate
        let c = CGPoint(x: rect.minX + MorbMarkGeometry.orbCentre.x * w,
                        y: rect.minY + MorbMarkGeometry.orbCentre.y * w)
        return Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }
}

/// Everything except a disc — the mask that carves the gap out of the stack.
private struct MorbOrbHalo: Shape {

    var inflate: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addPath(MorbOrbShape(inflate: inflate).path(in: rect))
        return path
    }
}

// MARK: - The mark

/// The Morbstack mark, drawn at any size.
///
/// Two flavours:
/// - `plated: true` — the full app icon: squircle plate, brand gradient, orb and stack in
///   white. For the About box and anywhere the logo stands alone.
/// - `plated: false` — the glyph only, in `Theme.brand`. For the sidebar header, where a
///   plated icon next to a list of SF Symbols reads as a foreign object.
struct MorbMark: View {

    var size: CGFloat = 24
    var plated: Bool = false

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            if plated {
                RoundedRectangle(cornerRadius: plateWidth * 0.235, style: .continuous)
                    .fill(Theme.brandGradient)
                    .frame(width: plateWidth, height: plateWidth)
            }
            glyph
                .frame(width: plateWidth, height: plateWidth)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Morbstack")
    }

    /// The plate is inset from the canvas by 8.8 % a side — the Big Sur icon grid — but
    /// only when there *is* a plate. Unplated, the glyph fills its frame.
    private var plateWidth: CGFloat { plated ? size * (1 - 2 * 0.088) : size }

    private var gap: CGFloat {
        max(1 / max(displayScale, 1), plateWidth * MorbMarkGeometry.gapFraction)
    }

    private var tint: AnyShapeStyle {
        plated ? AnyShapeStyle(Color.white) : AnyShapeStyle(Theme.brandGradient)
    }

    private var glyph: some View {
        ZStack {
            MorbStackShape()
                .fill(tint)
                .mask {
                    // Everything outside a disc of radius (R + gap) — this is the gap.
                    MorbOrbHalo(inflate: gap).fill(style: FillStyle(eoFill: true))
                }
            MorbOrbShape()
                .fill(tint)
        }
    }
}

// MARK: - Where the mark is allowed to appear
//
// `MorbSidebarHeader` used to live here: the mark plus a "Morbstack v0.4.2" wordmark,
// pinned above the sidebar list. It is deleted, not restyled, for two reasons.
//
// The structural one: it forced the sidebar column to be a `VStack { header; List }`
// rather than a bare `List`, so the sidebar's material stopped at the top of the header
// instead of running up behind the traffic lights. That is what put a dead opaque strip
// across the top of the window and made the whole app read as unfinished.
//
// The design one: no first-party Mac app writes its own name inside its own window. The
// name is in the menu bar, the Dock, the About box and the window's title. A branded
// card in the sidebar is the single clearest tell that a Mac app was designed by someone
// thinking in web pages.
//
// The mark still has exactly one place in the running app — the engine-stopped state,
// which is the first screen a new user sees and the one screen whose entire job is to
// be about Morbstack. See `EngineStoppedView` in `App.swift`. Everywhere else, identity
// comes from symbol choice, accent discipline and copy.
