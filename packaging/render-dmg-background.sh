#!/usr/bin/env bash
#
# render-dmg-background.sh — rasterize packaging/dmg-background.svg into the
# @1x and @2x PNGs scripts/make-dmg.sh embeds in the installer DMG.
#
# Why this exists as its own script rather than inline in make-dmg.sh: the
# two @1x/@2x PNGs are committed to the repo (see packaging/dmg-background.png
# and packaging/dmg-background@2x.png) so a fresh clone can build a DMG with
# no rasterizer installed at all. This script is what produced those commits
# and is how to reproduce or update them after editing the SVG — run it and
# commit the result, the same way `make app-icon` / `mise run app-icon`
# regenerates AppIcon.icns from make-icon.swift. make-dmg.sh calls it only as
# a fallback, if the committed PNGs are somehow missing.
#
# The approach: NO external SVG rasterizer (rsvg-convert, resvg, Inkscape,
# etc.) is assumed to exist, because the project's whole packaging story is
# base-system-only (see scripts/make-dmg.sh). The one thing on every Mac that
# can rasterize an SVG is Quick Look — its SVG generator is what draws the
# thumbnail in Finder icon view and Cover Flow — so this shells out to
# `qlmanage -t`, which renders through that same generator headlessly.
#
# qlmanage's quirk, worked around below: `-t` always produces a SQUARE
# thumbnail of side `-s SIZE`, regardless of the source's aspect ratio. The
# source is scaled to fill the square's full width and top-aligned (verified
# empirically: a 660x400 source rendered at -s 1320 produces a 1320x1320 PNG
# whose content occupies rows 0-799, i.e. exactly 1320 * (400/660), with the
# remainder below opaque white). That part is deterministic, so what's left
# is a plain top-left crop back to the source aspect ratio.
#
# That crop is NOT done with `sips -c/--cropOffset`: empirically, on this
# machine (sips-316, macOS 26), `sips -c H W --cropOffset Y X` silently
# ignores small offset values and always falls back to a *centered* crop
# instead of the documented "offset from top left corner" — confirmed by
# round-tripping known per-row pixel values through it before trusting it.
# crop-top.swift does the same crop with CoreGraphics instead, which does
# exactly what it is told; see that file for how its own coordinate-origin
# assumption was verified the same way.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SVG_SRC="${SCRIPT_DIR}/dmg-background.svg"
CROP_TOOL="${SCRIPT_DIR}/crop-top.swift"
OUT_1X="${SCRIPT_DIR}/dmg-background.png"
OUT_2X="${SCRIPT_DIR}/dmg-background@2x.png"

# Logical (points) size of the background, i.e. the @1x dimensions. Must
# match the SVG's own width/height and the window bounds scripts/make-dmg.sh
# sets — all three are one layout, not three independent numbers.
WIDTH=660
HEIGHT=400

usage() {
	cat <<EOF
Usage: $(basename "$0")

Rasterize ${SVG_SRC} into:
  ${OUT_1X}       (${WIDTH}x${HEIGHT})
  ${OUT_2X}  ($((WIDTH * 2))x$((HEIGHT * 2)))

Uses qlmanage (Quick Look's own SVG renderer) plus sips, both part of the
base macOS install — nothing to brew-install. Exits non-zero with an
actionable message if either tool is missing; this script only runs on
macOS.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
	usage
	exit 0
fi

if [ ! -f "${SVG_SRC}" ]; then
	echo "error: ${SVG_SRC} not found" >&2
	exit 1
fi

if ! command -v qlmanage >/dev/null 2>&1; then
	echo "error: qlmanage not found (expected at /usr/bin/qlmanage on macOS)" >&2
	echo "       this script only runs on macOS; there is no supported Linux path" >&2
	exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
	echo "error: swift not found on PATH" >&2
	echo "       needed to run ${CROP_TOOL} (see that file for why sips can't" >&2
	echo "       be trusted to do this crop); install Xcode / the Xcode" >&2
	echo "       Command Line Tools" >&2
	exit 1
fi

# Rasterize one scale factor. $1 = point size (660 for @1x, 1320 for @2x),
# $2 = output path.
render_scale() {
	local square_side="$1" out_path="$2"
	local content_height=$(( square_side * HEIGHT / WIDTH ))

	local work_dir
	work_dir="$(mktemp -d "${TMPDIR:-/tmp}/morbstack-dmg-bg.XXXXXX")"
	trap 'rm -rf "${work_dir}"' RETURN

	# qlmanage names its output "<input-basename>.png" inside -o's directory
	# and, unhelpfully, prints a human-readable status line to stdout with no
	# quiet flag — redirect it so this script's own output stays readable.
	if ! qlmanage -t -s "${square_side}" -o "${work_dir}" "${SVG_SRC}" >/dev/null 2>&1; then
		echo "error: qlmanage failed to render ${SVG_SRC} at size ${square_side}" >&2
		return 1
	fi

	local rendered="${work_dir}/$(basename "${SVG_SRC}").png"
	if [ ! -f "${rendered}" ]; then
		echo "error: qlmanage reported success but ${rendered} is missing" >&2
		echo "       (Quick Look's SVG generator may be disabled or unavailable" >&2
		echo "       on this machine; try 'qlmanage -r' to reload it and retry)" >&2
		return 1
	fi

	# Crop the square thumbnail's top-left content_height rows back to the
	# source aspect ratio. See the header comment for why this is
	# crop-top.swift and not `sips -c/--cropOffset`.
	if ! swift "${CROP_TOOL}" "${rendered}" "${square_side}" "${content_height}" "${out_path}" >/dev/null; then
		echo "error: crop-top.swift failed to crop ${rendered} to ${square_side}x${content_height}" >&2
		return 1
	fi

	echo "wrote ${out_path} (${square_side}x${content_height})"
}

render_scale "${WIDTH}" "${OUT_1X}"
render_scale $((WIDTH * 2)) "${OUT_2X}"
