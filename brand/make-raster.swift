#!/usr/bin/env swift
//
// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Renders the two brand assets that contain TEXT: the social/OG card and a
// fixed-pixel wordmark.
//
//     swift brand/make-raster.swift <mark-1024.png> <output-directory>
//
// Everything else in brand/ is pure geometry and is rasterised straight from SVG by
// brand/render.sh. These two are here instead because they set type, and a headless
// SVG rasteriser on macOS does not resolve the system UI font: rsvg-convert asks
// fontconfig for "SF Pro Display", fontconfig has never heard of it, and the result
// is "Morbstack" set in Hiragino Sans. AppKit asks the OS the way the OS expects to
// be asked, so this script gets the real face.
//
// It takes the already-rasterised mark as an argument rather than re-drawing the
// geometry, so there is exactly one source of truth for the mark (brand/mark.svg)
// and no chance of this file and that one drifting.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Palette
//
// docs/design/IDENTITY.md §2.3. brandDeep to one stop past brandSecondary, the same
// pair the plate and the app's brandGradient use.

let brandDeep = NSColor(srgbRed: 0x2A / 255, green: 0x1F / 255, blue: 0x9E / 255, alpha: 1)
let brandViolet = NSColor(srgbRed: 0x7A / 255, green: 0x3B / 255, blue: 0xE8 / 255, alpha: 1)
let ink = NSColor(srgbRed: 0x12 / 255, green: 0x10 / 255, blue: 0x1F / 255, alpha: 1)

// MARK: - Helpers

enum RasterError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let text): return text }
    }
}

/// The system UI font at a weight, preferring the display face at large sizes the way
/// AppKit itself does. `.systemFont(ofSize:weight:)` already switches between SF Pro
/// Text and SF Pro Display at the 20pt optical-size boundary, so there is nothing to
/// choose here beyond size and weight.
func uiFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    NSFont.systemFont(ofSize: size, weight: weight)
}

/// Draws `text` with its BASELINE at `baseline`, left-aligned at `x`, and returns the
/// advance width. Baseline-relative rather than box-relative because the wordmark's
/// vertical relationship to the mark is set by the baseline, not by a bounding box
/// whose height changes with the descender of whichever face got substituted.
@discardableResult
func draw(
    _ text: String, at x: CGFloat, baseline: CGFloat, font: NSFont, color: NSColor,
    tracking: CGFloat = 0
) -> CGFloat {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .kern: tracking,
    ]
    let string = NSAttributedString(string: text, attributes: attributes)
    // NSAttributedString.draw(at:) positions the TOP-LEFT of the line fragment, so
    // convert from the baseline the caller gave us. In a flipped (top-left origin)
    // context that is baseline minus ascender.
    string.draw(at: NSPoint(x: x, y: baseline - font.ascender))
    return string.size().width
}

/// Renders `draw` into a `pixels`-wide bitmap and writes it as a PNG.
///
/// The context is FLIPPED (top-left origin, y down) because every coordinate in this
/// file is quoted from an SVG viewBox, and switching conventions halfway through a
/// layout is how the type ends up one leading off.
func writePNG(width: Int, height: Int, to url: URL, _ body: (CGContext) -> Void) throws {
    guard
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
        throw RasterError.message("could not create a \(width)x\(height) bitmap context")
    }
    context.setShouldAntialias(true)
    context.setAllowsFontSmoothing(true)
    context.interpolationQuality = .high

    let graphics = NSGraphicsContext(cgContext: context, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    // Match the flip AppKit was just told about, so CoreGraphics drawing agrees with
    // NSAttributedString drawing.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)

    body(context)

    NSGraphicsContext.restoreGraphicsState()

    guard let image = context.makeImage() else {
        throw RasterError.message("could not snapshot \(url.lastPathComponent)")
    }
    let bitmap = NSBitmapImageRep(cgImage: image)
    bitmap.size = NSSize(width: width, height: height)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw RasterError.message("could not encode \(url.lastPathComponent)")
    }
    try data.write(to: url)
}

/// Draws `image` into `rect` in a flipped context.
func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
    context.saveGState()
    context.translateBy(x: rect.minX, y: rect.minY + rect.height)
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
    context.restoreGState()
}

// MARK: - Main

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(
        Data("usage: make-raster.swift <mark-1024.png> <output-directory>\n".utf8))
    exit(2)
}

let markURL = URL(fileURLWithPath: arguments[1])
let outputDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)

do {
    try FileManager.default.createDirectory(
        at: outputDirectory, withIntermediateDirectories: true)

    guard let markData = try? Data(contentsOf: markURL),
        let markRep = NSBitmapImageRep(data: markData),
        let mark = markRep.cgImage
    else {
        throw RasterError.message(
            "could not read the rasterised mark at \(markURL.path) -- run brand/render.sh, "
                + "which produces it from brand/mark.svg before calling this script")
    }

    // ---------------------------------------------------------------------------
    // The social / Open Graph card. 1200x630 is the size every scraper crops to.
    //
    // Deliberately not a screenshot: a 1200x630 crop of a container list is
    // unreadable in a link preview at the ~500px most timelines actually render it
    // at. Mark, name, one line of positioning, and the licence -- four things, each
    // legible at a third of this size.
    // ---------------------------------------------------------------------------
    let ogWidth = 1200
    let ogHeight = 630
    try writePNG(width: ogWidth, height: ogHeight, to: outputDirectory.appendingPathComponent("og-image.png")) { context in
        // The plate gradient, corner to corner, same axis as the mark's.
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [brandDeep.cgColor, brandViolet.cgColor] as CFArray,
            locations: [0, 1])
        {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0), end: CGPoint(x: ogWidth, y: ogHeight),
                options: [])
        }

        // A single soft sheen in the top-left, the same device the plate uses to stop
        // a flat gradient reading as a swatch. IDENTITY.md §1.3's 20% is tuned for a
        // 1024 square; at this aspect ratio it is halved so it does not become a
        // visible blob across the top edge.
        if let sheen = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                NSColor(white: 1, alpha: 0.10).cgColor,
                NSColor(white: 1, alpha: 0).cgColor,
            ] as CFArray,
            locations: [0, 1])
        {
            context.drawRadialGradient(
                sheen,
                startCenter: CGPoint(x: 300, y: 140), startRadius: 0,
                endCenter: CGPoint(x: 300, y: 140), endRadius: 760,
                options: [])
        }

        // The mark, top-left, at 176. Drawn from the rasterised SVG, which already
        // carries its own 8.8% inset, so the visual mark is ~144 inside a 176 box.
        drawImage(mark, in: CGRect(x: 84, y: 96, width: 176, height: 176), context: context)

        draw(
            "Morbstack", at: 250, baseline: 214,
            font: uiFont(96, .semibold), color: .white, tracking: -2.0)

        draw(
            "A Docker Desktop replacement for macOS.", at: 88, baseline: 372,
            font: uiFont(52, .medium), color: NSColor(white: 1, alpha: 0.96))
        // 34pt, not 38: at 38 this line measures ~1110px and ends 2px from the right
        // edge, which reads as an overflow rather than as a measure.
        draw(
            "One shared VM. Unmodified upstream Docker Engine. Native SwiftUI.",
            at: 88, baseline: 436,
            font: uiFont(34, .regular), color: NSColor(white: 1, alpha: 0.78))

        // The licence line is the pitch, so it is set as type rather than tucked into
        // a badge: it is the one fact about this project that no competitor can match
        // by shipping a feature.
        draw(
            "Free forever  ·  Apache-2.0  ·  No account  ·  No telemetry",
            at: 88, baseline: 546,
            font: uiFont(30, .semibold), color: NSColor(white: 1, alpha: 0.72),
            tracking: 0.4)
    }

    // ---------------------------------------------------------------------------
    // The fixed-pixel wordmark, light and dark. brand/wordmark.svg is the vector
    // original and should be preferred anywhere it renders (any browser, any Mac
    // app); these exist for the places that need a PNG and cannot resolve a system
    // font -- a GitHub README rendered on Linux, a slide, a conference programme.
    // ---------------------------------------------------------------------------
    for (suffix, color, background) in [
        ("wordmark.png", ink, NSColor.clear),
        ("wordmark-dark.png", NSColor.white, NSColor.clear),
    ] as [(String, NSColor, NSColor)] {
        try writePNG(width: 1120, height: 256, to: outputDirectory.appendingPathComponent(suffix)) { context in
            if background != .clear {
                context.setFillColor(background.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: 1120, height: 256))
            }
            drawImage(mark, in: CGRect(x: 0, y: 0, width: 256, height: 256), context: context)
            draw(
                "Morbstack", at: 280, baseline: 172,
                font: uiFont(136, .semibold), color: color, tracking: -2.8)
        }
    }

    print("wrote og-image.png, wordmark.png, wordmark-dark.png to \(outputDirectory.path)")
} catch {
    FileHandle.standardError.write(Data("make-raster: \(error)\n".utf8))
    exit(1)
}
