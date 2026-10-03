#!/usr/bin/env bash
# capture-gif.sh — write an animated GIF of one window's own composited
# content, frame by frame, and nothing else.
#
#   ./scripts/capture-gif.sh out.gif [window-title-substring] [frames] \
#       [trigger-after-frame] [trigger-cmd] [max-width-px]
#
# Same safety property as capture-window.sh, extended to motion. Every frame
# is `screencapture -x -o -l <windowid>` — WindowServer's own buffer for one
# window, nothing else can be in it. There is no `-R` (region: anything
# overlapping the rectangle lands in the file — this bit the operator once,
# catching their own session transcript in three frames) and no `-V` (records
# the whole display) anywhere in this script. Read capture-window.sh's header
# for the full history; the reasoning is identical here, just looped.
#
# `screencapture -l` is slow: every call is a fresh process asking
# WindowServer to composite and PNG-encode a window, on the order of a few
# hundred ms each on this machine. This script MEASURES the per-frame time it
# actually achieves over the real capture run and writes that measured
# average as the GIF's frame delay, rather than a hoped-for rate — a GIF
# whose declared delay disagrees with its real capture cadence plays at the
# wrong speed. If the achieved rate is too low for a motion to read well,
# that is a real limit of this approach worth stating, not something to
# paper over with a faster declared delay.
#
# `trigger-cmd`, if given, runs once via `eval` right after frame number
# `trigger-after-frame` is captured — e.g. to send the keystroke that opens
# an inspector partway through the loop, so the before/after state lands in
# the same GIF. Mouse clicks from automation do not reach this app; keyboard
# input (AppleScript's Accessibility bridge, `System Events keystroke`/`key
# code`) does. `trigger-cmd` is intentionally free-form shell, not a second
# argument-parsing scheme — callers already have their own keystroke idiom.
#
# `max-width-px`, if given, downscales every frame to at most that many
# pixels wide before it is added to the GIF (ImageIO thumbnailing, still one
# process, still no new dependency). A real estate window captured at
# 2x-Retina resolution produces a GIF too large to justify in a README
# otherwise; this trades sharpness the format cannot really deliver anyway
# (GIF is palette-quantized) for a byte size worth shipping.
set -euo pipefail

OUT="${1:?usage: capture-gif.sh <output.gif> [window-title-substring] [frames] [trigger-after-frame] [trigger-cmd] [max-width-px]}"
MATCH="${2:-Morbstack}"
FRAMES="${3:-24}"
TRIGGER_AFTER="${4:-0}"
TRIGGER_CMD="${5:-}"
MAX_WIDTH="${6:-960}"

HELPER="${TMPDIR:-/tmp}/morbstack-window-id"
ENCODER="${TMPDIR:-/tmp}/morbstack-gif-encode"

# Identical helper capture-window.sh builds and caches at the same path —
# whichever script runs first pays the one-time swiftc cost, the other reuses
# the binary. Kept as a literal copy rather than a shared sourced file so
# each script stays a single, independently readable unit (the project's
# existing pattern for these tiny capture helpers).
if [ ! -x "$HELPER" ]; then
	SRC="${TMPDIR:-/tmp}/morbstack-window-id.swift"
	cat >"$SRC" <<'SWIFT'
import CoreGraphics
import Foundation

let needle = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Morbstack"
let windows =
    CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []

for window in windows {
    guard let owner = window[kCGWindowOwnerName as String] as? String, owner.contains(needle),
        let number = window[kCGWindowNumber as String] as? Int,
        let bounds = window[kCGWindowBounds as String] as? [String: Any]
    else { continue }
    // Skip the menu-bar extra and any other small auxiliary window; the document
    // window is the only one wide enough to be worth capturing.
    let width = (bounds["Width"] as? Double) ?? 0
    if width > 400 {
        print(number)
        exit(0)
    }
}
FileHandle.standardError.write(Data("no on-screen \(needle) window wider than 400pt\n".utf8))
exit(1)
SWIFT
	swiftc -O "$SRC" -o "$HELPER"
fi

# ImageIO GIF assembly: CGImageDestinationCreateWithURL with a GIF UTType,
# each frame's delay set via kCGImagePropertyGIFDictionary/GIFDelayTime.
# Foundation + ImageIO + UniformTypeIdentifiers only — no ImageMagick, no
# ffmpeg, matching this project's zero-dependency rule.
if [ ! -x "$ENCODER" ]; then
	SRC="${TMPDIR:-/tmp}/morbstack-gif-encode.swift"
	cat >"$SRC" <<'SWIFT'
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("morbstack-gif-encode: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 5 else {
    fail("usage: morbstack-gif-encode <out.gif> <delay-centiseconds> <max-width-px> <frame1.png> [frame2.png ...]")
}

let outPath = args[1]
guard let delayCS = Int(args[2]), delayCS > 0 else { fail("invalid delay-centiseconds '\(args[2])'") }
guard let maxWidth = Int(args[3]), maxWidth >= 0 else { fail("invalid max-width-px '\(args[3])'") }
let framePaths = Array(args[4...])
guard !framePaths.isEmpty else { fail("no input frames given") }

let delaySeconds = Double(delayCS) / 100.0
let outURL = URL(fileURLWithPath: outPath)

guard
    let destination = CGImageDestinationCreateWithURL(
        outURL as CFURL, UTType.gif.identifier as CFString, framePaths.count, nil)
else { fail("could not create GIF destination at \(outPath)") }

CGImageDestinationSetProperties(
    destination,
    [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)

let frameProperties: CFDictionary =
    [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delaySeconds]] as CFDictionary

for path in framePaths {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
        fail("could not open \(path)")
    }
    let image: CGImage?
    if maxWidth > 0 {
        let thumbOptions: CFDictionary =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxWidth,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary
        image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions)
    } else {
        image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    guard let image else { fail("could not decode \(path)") }
    CGImageDestinationAddImage(destination, image, frameProperties)
}

guard CGImageDestinationFinalize(destination) else { fail("could not finalize \(outPath)") }
print("\(outPath): \(framePaths.count) frames, \(delayCS)cs delay each")
SWIFT
	swiftc -O "$SRC" -o "$ENCODER"
fi

WINDOW_ID="$("$HELPER" "$MATCH")"

FRAME_DIR="$(mktemp -d)"
trap 'rm -rf "$FRAME_DIR"' EXIT

DIGITS=${#FRAMES}
TOTAL_MS=0
FRAME=1
while [ "$FRAME" -le "$FRAMES" ]; do
	PADDED=$(printf "%0${DIGITS}d" "$FRAME")
	START_NS=$(date +%s%N)
	screencapture -x -o -l "$WINDOW_ID" "$FRAME_DIR/frame-$PADDED.png"
	END_NS=$(date +%s%N)
	TOTAL_MS=$((TOTAL_MS + (END_NS - START_NS) / 1000000))

	if [ "$TRIGGER_AFTER" != "0" ] && [ "$FRAME" -eq "$TRIGGER_AFTER" ] && [ -n "$TRIGGER_CMD" ]; then
		eval "$TRIGGER_CMD"
	fi

	FRAME=$((FRAME + 1))
done

AVG_MS=$((TOTAL_MS / FRAMES))
DELAY_CS=$((AVG_MS / 10))
[ "$DELAY_CS" -ge 2 ] || DELAY_CS=2
echo "measured ${AVG_MS}ms/frame over ${FRAMES} frames -> ${DELAY_CS}cs GIF delay" >&2

mkdir -p "$(dirname "$OUT")"
"$ENCODER" "$OUT" "$DELAY_CS" "$MAX_WIDTH" "$FRAME_DIR"/frame-*.png

[ -s "$OUT" ] || { echo "error: capture-gif.sh wrote nothing to $OUT" >&2; exit 1; }
echo "$OUT ($(/usr/bin/stat -f%z "$OUT") bytes, window $WINDOW_ID)"
