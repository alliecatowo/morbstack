// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Turning a SwiftUI view into a PNG, with no display and no permissions.
//
// Screen capture is not an option: `screencapture`, `CGWindowListCreateImage` and
// ScreenCaptureKit are all behind the Screen Recording TCC permission, which an agent
// process cannot be granted. So the views are rasterised directly instead.
//
// **Why not `ImageRenderer`.** It is the obvious tool and it does not work here. It
// walks the SwiftUI view graph only; anything backed by AppKit — and on macOS that
// includes `List`, which is an `NSTableView` — rasterises as the yellow "unsupported
// view" placeholder. Morbstack's Containers, Images, Volumes and Networks screens are
// all built on `List`, so `ImageRenderer` produces a yellow no-entry sign where the
// product is. Measured, not assumed: the first version of this file used it, and the
// first probe render came back as a 1200×960 prohibition symbol.
//
// **What does work.** An `NSHostingView` inside an ordinary offscreen `NSWindow`, drawn
// with `displayIgnoringOpacity(_:in:)` into a bitmap whose logical size is half its
// pixel size — which is exactly what "@2x" means. The window is never ordered on
// screen, never becomes key, and needs no entitlement; AppKit is simply asked to draw a
// view hierarchy into a context, which is the same thing it does for printing.
//
// Three details that are easy to get wrong and produce a subtly wrong picture:
//
//   * **Appearance is an AppKit fact.** Half the app's colours come from
//     `NSColor(name:dynamicProvider:)`, which resolves against the *current drawing
//     appearance*, not against `\.colorScheme`. Both are set: the window's appearance
//     and the drawing appearance for AppKit, the environment value for SwiftUI's own
//     side. Setting only the environment gives dark-mode text on light-mode chrome.
//   * **Control active state.** A view with no key window renders every accent-tinted
//     control in its inactive grey, which makes the whole shot look like a background
//     window. Forced to `.key`.
//   * **Lifecycle really runs here.** Unlike `ImageRenderer`, a hosted view gets
//     `onAppear` and `.task` — which is mostly a gift (entrance states resolve, tables
//     populate) and once a hazard: a `.task` that calls the engine would fail against
//     the fixture's dead socket and wipe the model. `AppModel.isSnapshot` is what stops
//     that, and the settle delay below is deliberately short.

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum ShotRenderer {

    /// One rendered file, for the manifest.
    struct Output {
        var name: String
        var url: URL
        var pixelWidth: Int
        var pixelHeight: Int
        var bytes: Int
        var stats: ShotBitmapStats
    }

    /// How long to let the run loop turn before drawing.
    ///
    /// Not zero: `List` is an `NSTableView`, and it loads its rows on the next turn of
    /// the run loop rather than during `layoutSubtreeIfNeeded`. Not long either — every
    /// millisecond here is spent thirty-four times, and the longer it runs the more
    /// chance an unguarded `.task` has to change what is on screen.
    static let settle: TimeInterval = 0.35

    // MARK: - Rendering

    /// Renders `content` at `size` logical points and writes `<name>-<scheme>@2x.png`.
    @discardableResult
    static func write(
        _ content: some View,
        name: String,
        size: CGSize,
        scheme: ColorScheme,
        scale: CGFloat = 2,
        settle: TimeInterval = settle,
        to directory: URL
    ) throws -> Output {
        let rep = try render(content, size: size, scheme: scheme, scale: scale, settle: settle)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw ShotError.encode(name)
        }
        let url = directory.appendingPathComponent(
            "\(name)-\(scheme == .dark ? "dark" : "light")@\(Int(scale))x.png")
        try png.write(to: url)
        return Output(
            name: url.lastPathComponent,
            url: url,
            pixelWidth: rep.pixelsWide,
            pixelHeight: rep.pixelsHigh,
            bytes: png.count,
            stats: ShotBitmapStats(rep))
    }

    /// Rasterises a view into a bitmap at `scale` device pixels per point.
    static func render(
        _ content: some View,
        size: CGSize,
        scheme: ColorScheme,
        scale: CGFloat = 2,
        settle: TimeInterval = settle
    ) throws -> NSBitmapImageRep {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
        NSApplication.shared.appearance = appearance

        // A height of zero means "as tall as the content wants to be". Used by the menu
        // bar popover, whose height is the sum of however many containers and ports it
        // decided to list; guessing it produced a picture with the header cropped off the
        // top and the footer off the bottom.
        let autoHeight = size.height <= 0
        let root =
            content
            .frame(width: size.width, height: autoHeight ? nil : size.height)
            .environment(\.colorScheme, scheme)
            .environment(\.controlActiveState, .key)

        var result: NSBitmapImageRep?
        var failure: Error?

        appearance.performAsCurrentDrawingAppearance {
            let hosting = NSHostingView(rootView: AnyView(root))
            var size = size
            if autoHeight {
                hosting.frame = CGRect(x: 0, y: 0, width: size.width, height: 1)
                size.height = max(1, hosting.fittingSize.height.rounded(.up))
            }
            hosting.frame = CGRect(origin: .zero, size: size)
            hosting.appearance = appearance

            // A real window, never shown. `NSHostingView` needs one for the responder
            // chain, for effect views to pick an appearance, and for `onAppear` to fire.
            let window = NSWindow(
                contentRect: hosting.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false)
            window.contentView = hosting
            window.appearance = appearance
            window.isReleasedWhenClosed = false
            // Belt and braces: nothing here should ever put a window on screen, and a
            // stray one during a long run would be genuinely disruptive.
            window.setIsVisible(false)

            hosting.layoutSubtreeIfNeeded()
            if settle > 0 {
                RunLoop.main.run(until: Date().addingTimeInterval(settle))
            }
            hosting.layoutSubtreeIfNeeded()

            guard
                let rep = bitmap(size: size, scale: scale),
                let context = NSGraphicsContext(bitmapImageRep: rep)
            else {
                failure = ShotError.bitmap
                return
            }

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            hosting.displayIgnoringOpacity(hosting.bounds, in: context)
            NSGraphicsContext.restoreGraphicsState()

            window.contentView = nil
            window.close()
            result = rep
        }

        if let failure { throw failure }
        guard let result else { throw ShotError.bitmap }
        return result
    }

    /// A bitmap whose pixel dimensions are `scale` times its logical size.
    ///
    /// Setting `rep.size` after construction is the whole mechanism: the graphics
    /// context derived from the rep maps one point onto `scale` pixels, so the view
    /// draws in points and comes out at Retina density with no manual transform and no
    /// resampling.
    private static func bitmap(size: CGSize, scale: CGFloat) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded()),
            pixelsHigh: Int((size.height * scale).rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        rep?.size = NSSize(width: size.width, height: size.height)
        return rep
    }

    enum ShotError: Error, LocalizedError {
        case bitmap
        case encode(String)

        var errorDescription: String? {
            switch self {
            case .bitmap: return "could not create an offscreen bitmap"
            case .encode(let name): return "could not encode \(name) as PNG"
            }
        }
    }
}

// MARK: - Bitmap probing

/// A cheap look at what came out, so the harness can flag a blank shot without a human
/// opening it.
///
/// Not a substitute for looking at the images — it cannot tell a good layout from a bad
/// one — but it catches the three failures that are common and invisible in a manifest:
/// a fully transparent render, a flat rectangle of one colour, and a dark-mode shot that
/// came out light (or the reverse) because an appearance did not take.
struct ShotBitmapStats {

    var width: Int
    var height: Int
    /// Fraction of sampled pixels that are fully opaque.
    var opaqueFraction: Double
    /// How many distinct quantised colours appeared. A handful means a flat fill.
    var distinctColours: Int
    /// Mean luminance in `0...1`.
    var meanLuminance: Double

    var looksBlank: Bool { distinctColours < 8 || opaqueFraction < 0.9 }

    init(_ rep: NSBitmapImageRep) {
        width = rep.pixelsWide
        height = rep.pixelsHigh

        var opaque = 0
        var sampled = 0
        var luminance = 0.0
        var buckets = Set<Int>()

        // Every 7th pixel in both directions: enough to characterise a 2880×1800 bitmap,
        // fast enough to run on every shot.
        guard let data = rep.bitmapData else {
            opaqueFraction = 0
            distinctColours = 0
            meanLuminance = 0
            return
        }
        let rowBytes = rep.bytesPerRow
        let pixelBytes = rep.bitsPerPixel / 8

        for y in stride(from: 0, to: rep.pixelsHigh, by: 7) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 7) {
                let offset = y * rowBytes + x * pixelBytes
                let r = Double(data[offset]) / 255
                let g = Double(data[offset + 1]) / 255
                let b = Double(data[offset + 2]) / 255
                let a = pixelBytes > 3 ? data[offset + 3] : 255
                sampled += 1
                if a == 255 { opaque += 1 }
                luminance += 0.2126 * r + 0.7152 * g + 0.0722 * b
                buckets.insert((Int(r * 15) << 8) | (Int(g * 15) << 4) | Int(b * 15))
            }
        }

        opaqueFraction = sampled == 0 ? 0 : Double(opaque) / Double(sampled)
        meanLuminance = sampled == 0 ? 0 : luminance / Double(sampled)
        distinctColours = buckets.count
    }
}
