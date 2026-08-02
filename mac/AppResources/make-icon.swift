#!/usr/bin/env swift
//
// Copyright 2026 The Morbstack Authors.
// Licensed under the Apache License, Version 2.0 (the "License").
//
// Renders Morbstack's app icon.
//
//     swift mac/AppResources/make-icon.swift <output-directory>
//
// Writes `icon_16x16.png` … `icon_512x512@2x.png` in the layout `iconutil` expects,
// so the caller can turn the directory into an `.icns` with one command. Everything is
// drawn with CoreGraphics — no asset catalog, no design tool, no checked-in binaries,
// which means the icon is diffable and regenerates identically on any Mac.
//
// The drawing is resolution-independent: all geometry is expressed as a fraction of the
// canvas, so the 16pt icon is the same picture as the 1024pt one rather than a separate
// asset that drifts. The only size-dependent decision is the shadow, which is dropped
// below 64pt where it would smear the glyph into mush.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Palette
//
// The same indigo→violet pair as `Theme.brand` / `Theme.brandSecondary` in the app, so
// the icon and the app's accents are visibly the same colour rather than nearly.

let indigoTop = CGColor(red: 0.20, green: 0.16, blue: 0.66, alpha: 1)
let violetBottom = CGColor(red: 0.57, green: 0.28, blue: 0.94, alpha: 1)

// MARK: - Drawing

/// Draws the icon into `context` at `size` × `size` points.
func drawIcon(in context: CGContext, size: CGFloat) {

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    context.clear(rect)

    // macOS icons do not fill their canvas: the grid leaves a margin so that icons of
    // different shapes look the same weight next to each other in the Dock. ~9% a side
    // is what the Big Sur–era template uses for a full-bleed rounded square.
    let inset = size * 0.088
    let plate = rect.insetBy(dx: inset, dy: inset)
    // The squircle radius on the same template is a shade under a quarter of the width.
    let radius = plate.width * 0.235

    let plateShape = CGPath(
        roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Drop shadow, on the sizes big enough to hold one.
    if size >= 64 {
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -size * 0.012),
            blur: size * 0.035,
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.30))
        context.addPath(plateShape)
        context.setFillColor(indigoTop)
        context.fillPath()
        context.restoreGState()
    }

    // The gradient body.
    context.saveGState()
    context.addPath(plateShape)
    context.clip()
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [indigoTop, violetBottom] as CFArray,
        locations: [0, 1])
    {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: plate.minX, y: plate.maxY),
            end: CGPoint(x: plate.maxX, y: plate.minY),
            options: [])
    }

    // A soft highlight across the top-left, which is what keeps a flat gradient from
    // looking like a swatch. Radial and very low contrast — at 4% it reads as "lit"
    // rather than as a visible blob.
    if let sheen = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray,
        locations: [0, 1])
    {
        context.drawRadialGradient(
            sheen,
            startCenter: CGPoint(x: plate.minX + plate.width * 0.28, y: plate.maxY - plate.height * 0.18),
            startRadius: 0,
            endCenter: CGPoint(x: plate.minX + plate.width * 0.28, y: plate.maxY - plate.height * 0.18),
            endRadius: plate.width * 0.72,
            options: [])
    }
    context.restoreGState()

    // Inner rim: a hairline of white along the top edge, the trick that makes a flat
    // shape read as a physical object with a lit edge.
    context.saveGState()
    context.addPath(plateShape)
    context.setLineWidth(max(0.75, size * 0.006))
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
    context.strokePath()
    context.restoreGState()

    drawGlyph(in: context, plate: plate, size: size)
}

/// The mark itself: a white orb with three slats through it.
///
/// It reads as a container — the slats are a crate's boards — and as a sphere, which is
/// the "one machine holding everything" idea the product is about. Both readings are
/// intentional, and the shape survives being 16 pixels wide, which most literal
/// container drawings do not.
func drawGlyph(in context: CGContext, plate: CGRect, size: CGFloat) {

    let centre = CGPoint(x: plate.midX, y: plate.midY)
    let orbRadius = plate.width * 0.255
    let orb = CGRect(
        x: centre.x - orbRadius, y: centre.y - orbRadius,
        width: orbRadius * 2, height: orbRadius * 2)

    // Ring rather than disc: a solid white circle at Dock size is a headlight. The
    // stroke keeps the plate's colour visible through the middle, which is where the
    // slats then have something to sit on.
    let ringWidth = orbRadius * 0.30
    context.saveGState()
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.setLineWidth(ringWidth)
    context.strokeEllipse(in: orb.insetBy(dx: ringWidth / 2, dy: ringWidth / 2))
    context.restoreGState()

    // Three slats inside the ring.
    //
    // Each one's length comes from the circle's own chord at that height, so the outer
    // two are shorter than the middle and the group traces the sphere — latitude lines,
    // and equally the boards of a crate seen head on. Clipping a full-width bar to the
    // circle would produce the same silhouette but with the ends jammed against the
    // ring; solving for the chord and then pulling in by a margin leaves visible air on
    // every side, which is the whole difference between "sphere" and "stripes".
    let innerRadius = orb.width / 2 - ringWidth
    // Gaps wider than the slats. The other way round the group fills in and the mark
    // reads as a striped ball rather than as boards with space between them.
    let slatHeight = innerRadius * 2 * 0.135
    let gap = innerRadius * 2 * 0.150
    let offsets: [CGFloat] = [slatHeight + gap, 0, -(slatHeight + gap)]
    let margin = ringWidth * 0.55

    context.saveGState()
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    for offset in offsets {
        // Measure the chord at the slat's *outer* edge, so its corners clear the ring
        // rather than only its centre line.
        let extreme = abs(offset) + slatHeight / 2
        let halfChord = (innerRadius * innerRadius - extreme * extreme).squareRoot()
        guard halfChord.isFinite, halfChord > margin else { continue }
        let halfWidth = halfChord - margin

        let slat = CGRect(
            x: centre.x - halfWidth, y: centre.y + offset - slatHeight / 2,
            width: halfWidth * 2, height: slatHeight)
        let slatRadius = min(slatHeight / 2, size * 0.024)
        context.addPath(
            CGPath(
                roundedRect: slat, cornerWidth: slatRadius, cornerHeight: slatRadius,
                transform: nil))
        context.fillPath()
    }
    context.restoreGState()
}

// MARK: - Export

/// Renders one PNG at `pixels` × `pixels`.
func renderPNG(pixels: Int, to url: URL) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
        throw IconError.message("could not create a \(pixels)×\(pixels) bitmap context")
    }

    drawIcon(in: context, size: CGFloat(pixels))

    guard let image = context.makeImage() else {
        throw IconError.message("could not snapshot the \(pixels)×\(pixels) context")
    }
    let bitmap = NSBitmapImageRep(cgImage: image)
    bitmap.size = NSSize(width: pixels, height: pixels)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw IconError.message("could not encode \(url.lastPathComponent)")
    }
    try data.write(to: url)
}

enum IconError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let text): return text }
    }
}

/// The `.iconset` contents: each point size at 1× and 2×.
let variants: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

// MARK: - Main

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(
        Data("usage: make-icon.swift <output-directory>\n".utf8))
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)

do {
    try FileManager.default.createDirectory(
        at: outputDirectory, withIntermediateDirectories: true)

    for variant in variants {
        let pixels = variant.points * variant.scale
        let suffix = variant.scale == 1 ? "" : "@\(variant.scale)x"
        let name = "icon_\(variant.points)x\(variant.points)\(suffix).png"
        try renderPNG(pixels: pixels, to: outputDirectory.appendingPathComponent(name))
    }

    // A standalone 1024 for README screenshots and for anywhere that wants a plain PNG
    // rather than an icns. Not part of the iconset — `iconutil` rejects unexpected
    // filenames — so it goes next to it.
    try renderPNG(
        pixels: 1024,
        to: outputDirectory.deletingLastPathComponent().appendingPathComponent("AppIcon-1024.png"))

    print("wrote \(variants.count) icon sizes to \(outputDirectory.path)")
} catch {
    FileHandle.standardError.write(Data("make-icon: \(error)\n".utf8))
    exit(1)
}
