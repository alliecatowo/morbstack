#!/bin/sh
#
# Copyright 2026 The Morbstack Authors.
# Licensed under the Apache License, Version 2.0 (the "License").
#
# Rasterises every brand asset from its vector source into brand/out/.
#
#     brand/render.sh
#
# The SVGs in brand/ are the source of truth; brand/out/ is generated and is
# checked in only because the website and the README have to work for someone who
# has not installed a rasteriser. Re-run this after editing any SVG.
#
# Two rasterisers, for one reason: text.
#
#   * Pure geometry (the mark, the favicons, the icon layers, the menu-bar template)
#     goes through rsvg-convert, which is exact, fast, and reproducible.
#   * Anything that SETS TYPE (the OG card, the fixed-pixel wordmark) goes through
#     brand/make-raster.swift, because fontconfig on macOS has never heard of the
#     system UI font. Ask rsvg-convert for "SF Pro Display" and it will hand back
#     Hiragino Sans without complaint. AppKit asks the OS properly.
#
# rsvg-convert is the one build-time dependency in this directory and it is
# deliberately confined to it: nothing in the app, the daemon or the guest needs it,
# and the checked-in outputs mean nothing in the website needs it either.

set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd)
out="$here/out"
mkdir -p "$out"

if ! command -v rsvg-convert >/dev/null 2>&1; then
	echo "error: rsvg-convert not found." >&2
	echo "       brew install librsvg" >&2
	echo "" >&2
	echo "       The checked-in contents of brand/out/ are what this script would" >&2
	echo "       produce, so nothing downstream is blocked on installing it -- but" >&2
	echo "       the outputs cannot be REgenerated without it." >&2
	exit 1
fi

svg() {
	# svg <source.svg> <width-in-px> <output-name>
	rsvg-convert -w "$2" -h "$2" "$here/$1" -o "$out/$3"
	echo "  $3 (${2}x${2})"
}

echo "mark:"
# 1024 is the app-icon canvas and the source for everything downstream that wants a
# raster mark; 512 and 256 are for READMEs and slides.
svg mark.svg 1024 mark-1024.png
svg mark.svg 512 mark-512.png
svg mark.svg 256 mark-256.png

echo "favicon:"
# The compact (two-slab) detail level, because a browser picks the favicon size and
# the three-slab stack greys out below 64px. See docs/design/IDENTITY.md §1.4.
svg mark-compact.svg 16 favicon-16.png
svg mark-compact.svg 32 favicon-32.png
svg mark-compact.svg 48 favicon-48.png
# Apple touch icon: 180 is the current iOS home-screen size, and iOS applies its own
# corner mask over whatever it is given.
svg mark.svg 180 apple-touch-icon.png

echo "menu-bar template:"
# Template images are black plus alpha; AppKit recolours them. Rendered at 1x and 2x
# with the @2x naming AppKit expects so the pair can be dropped straight into a
# bundle's Resources as MorbTemplate.png / MorbTemplate@2x.png.
rsvg-convert -w 18 -h 17 "$here/mark-template.svg" -o "$out/MorbTemplate.png"
rsvg-convert -w 36 -h 34 "$here/mark-template.svg" -o "$out/MorbTemplate@2x.png"
echo "  MorbTemplate.png, MorbTemplate@2x.png"

echo "Icon Composer layers:"
# Flat PNG fallbacks for the layered artwork, for anyone importing into a tool that
# will not take SVG. Icon Composer itself prefers the vectors -- see brand/icon/README.md.
rsvg-convert -w 1024 -h 1024 "$here/icon/background.svg" -o "$out/icon-background-1024.png"
rsvg-convert -w 1024 -h 1024 "$here/icon/foreground.svg" -o "$out/icon-foreground-1024.png"
echo "  icon-background-1024.png, icon-foreground-1024.png"

echo "type-setting assets (AppKit):"
# Needs the rasterised mark above, which is why this runs last.
swift "$here/make-raster.swift" "$out/mark-1024.png" "$out"

echo ""
echo "wrote $(ls -1 "$out" | wc -l | tr -d ' ') files to brand/out/"
