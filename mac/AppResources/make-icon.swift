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
    // rather than as a visible blob. `docs/design/IDENTITY.md` §1.3: only ≥ 64px.
    if size >= 64,
        let sheen = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.20),
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
    // shape read as a physical object with a lit edge. `docs/design/IDENTITY.md` §1.3:
    // only ≥ 32px, width and alpha keyed to the *plate*, not the canvas.
    if size >= 32 {
        context.saveGState()
        context.addPath(plateShape)
        context.setLineWidth(max(0.75, plate.width * 0.006))
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
        context.strokePath()
        context.restoreGState()
    }

    drawGlyph(in: context, plate: plate, size: size)
}

/// The mark: a solid orb resting on a stack of full-width slabs, the topmost slab
/// passing *behind* the orb through a hard gradient-coloured gap.
///
/// Geometry is `docs/design/IDENTITY.md` §1, stated once there and implemented twice —
/// this file in CoreGraphics for the `.icns`, `Design/MorbBrand.swift` in SwiftUI for
/// the in-app mark. **CoreGraphics is bottom-left origin**, so every `v` coordinate
/// below is exactly the value the spec tables give; `MorbBrand.swift` stores `1 − v` to
/// account for SwiftUI's top-left origin. If this file and that one ever disagree,
/// `IDENTITY.md` is the tie-breaker.
///
/// The gap is rendered by clipping, not by stroking a second time over the slabs: an
/// even-odd clip to "the plate minus a disc of radius `R + gap`" is applied before the
/// slabs are filled, so there is no double-drawn edge where the two shapes meet.
func drawGlyph(in context: CGContext, plate: CGRect, size: CGFloat) {

    let plateW = plate.width  // == plate.height

    func px(_ u: CGFloat) -> CGFloat { plate.minX + u * plateW }
    func py(_ v: CGFloat) -> CGFloat { plate.minY + v * plateW }
    func ulen(_ f: CGFloat) -> CGFloat { f * plateW }

    // MARK: Orb — §1.5

    let orbCentre = CGPoint(x: px(0.500), y: py(0.650))
    let orbRadius = ulen(0.235)
    let orbRect = CGRect(
        x: orbCentre.x - orbRadius, y: orbCentre.y - orbRadius,
        width: orbRadius * 2, height: orbRadius * 2)

    // MARK: The gap — §1.6. The 1 device-pixel floor is the whole point: without it the
    // gap disappears below ~36px and the orb fuses with the slab into a lollipop.
    let gap = max(1.0, plateW * 0.028)
    let haloRadius = orbRadius + gap
    let haloRect = CGRect(
        x: orbCentre.x - haloRadius, y: orbCentre.y - haloRadius,
        width: haloRadius * 2, height: haloRadius * 2)

    // MARK: Slabs — §1.4. Three at ≥ 64px, two below — both occupy the same band so the
    // silhouette does not jump when the detail level changes.
    let isFullDetail = size >= 64
    let slabCount = isFullDetail ? 3 : 2
    let slabHeight = isFullDetail ? 0.105 : 0.150
    let slabPitch = isFullDetail ? 0.170 : 0.285
    let lowestCentre = isFullDetail ? 0.155 : 0.185
    let slabWidth: CGFloat = 0.860
    let slabCornerRadius = min(ulen(slabHeight) / 2, plateW * 0.030)

    // 1. Clip to the plate, minus the halo disc — this is the gap. Even-odd with the
    //    plate as the outer subpath and the halo as the inner one leaves exactly
    //    "everything outside the halo, inside the plate".
    context.saveGState()
    context.addPath(CGPath(roundedRect: plate, cornerWidth: plateW * 0.235, cornerHeight: plateW * 0.235, transform: nil))
    context.addEllipse(in: haloRect)
    context.clip(using: .evenOdd)

    // 2. The slabs, filled solid white, clipped by the gap above.
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    for i in 0..<slabCount {
        let centreV = lowestCentre + CGFloat(i) * slabPitch
        let rect = CGRect(
            x: px(0.500 - slabWidth / 2), y: py(centreV) - ulen(slabHeight) / 2,
            width: ulen(slabWidth), height: ulen(slabHeight))
        context.addPath(
            CGPath(
                roundedRect: rect, cornerWidth: slabCornerRadius, cornerHeight: slabCornerRadius,
                transform: nil))
    }
    context.fillPath()
    context.restoreGState()

    // 3. The orb itself, on top: a filled disc with a faint lens gradient — a sphere,
    //    not a ring. White at the disc's top-left to 92% white at its bottom-right.
    context.saveGState()
    context.addEllipse(in: orbRect)
    context.clip()
    if let lens = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            CGColor(red: 0.92, green: 0.92, blue: 0.92, alpha: 1),
        ] as CFArray,
        locations: [0, 1])
    {
        // Top-left → bottom-right in this bottom-left-origin space is (minX, maxY) →
        // (maxX, minY).
        context.drawLinearGradient(
            lens,
            start: CGPoint(x: orbRect.minX, y: orbRect.maxY),
            end: CGPoint(x: orbRect.maxX, y: orbRect.minY),
            options: [])
    } else {
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(orbRect)
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
