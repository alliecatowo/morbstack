#!/usr/bin/env bash
# capture-window.sh — write a PNG of the Morbstack window, and nothing else.
#
#   ./scripts/capture-window.sh out.png
#
# Why this exists, and why the obvious alternatives are wrong:
#
#   * `screencapture -R x,y,w,h` captures a screen REGION. Anything overlapping
#     that rectangle — another app, a system permission dialog, whoever's
#     terminal — lands in the file. On a shared desktop that is a privacy leak,
#     and it has already happened once on this machine: a capture agent caught
#     the operator's own session transcript in three frames and deleted them.
#   * The computer-use `screenshot` tool composites correctly (it filters to the
#     allowlisted app), but its `save_to_disk` does not produce a file anyone has
#     been able to locate. `docs/audit/UI-AUDIT.md` records an earlier pass
#     losing its entire screenshot set to exactly this.
#
# `screencapture -l <windowid>` asks WindowServer for one window's own composited
# content. Overlapping windows cannot appear in it because they were never part
# of that window's buffer. Everything outside the frame is transparent.
#
# Requires Screen Recording permission for the calling process. It does NOT need
# Accessibility, Automation, or Apple Events — this reads a window, it does not
# drive one.
set -euo pipefail

OUT="${1:?usage: capture-window.sh <output.png> [window-title-substring]}"
MATCH="${2:-Morbstack}"
HELPER="${TMPDIR:-/tmp}/morbstack-window-id"

# Tiny Swift helper rather than Python: the system Python has no Quartz
# bindings, so `import Quartz` fails on a clean machine. Built once, cached.
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

WINDOW_ID="$("$HELPER" "$MATCH")"

mkdir -p "$(dirname "$OUT")"
# -x silences the shutter sound; -o omits the window's drop shadow so the image
# is the window itself rather than the window plus a fuzzy margin.
screencapture -x -o -l "$WINDOW_ID" "$OUT"

[ -s "$OUT" ] || { echo "error: screencapture wrote nothing to $OUT" >&2; exit 1; }
echo "$OUT ($(/usr/bin/stat -f%z "$OUT") bytes, window $WINDOW_ID)"
