#!/usr/bin/env bash
# run-probe.sh — build ToolProbe into a real app bundle, launch one variant, and
# capture the window.
#
#   ./run-probe.sh <variant> [WxH] [extra probe args...]
#   ./run-probe.sh principal 1600x1000
#   ./run-probe.sh inspectorToolbar 1600x1000 --closed
#
# Why a bundle: a bare `swiftc` binary gets no toolbar chrome worth looking at.
# NSApplication needs a bundle identifier and an Info.plist to be given a real
# titlebar, and `screencapture -l` needs a real window to read.
#
# Captures land in /tmp/mrbcap/probe-<variant>[-suffix].png. The probe is its own
# app, so it never conflicts with the machine lane (`dist/Morbstack.app`).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
BUILD="${TMPDIR:-/tmp}/toolprobe"
APP="$BUILD/ToolProbe.app"
OUTDIR="${PROBE_OUT:-/tmp/mrbcap}"

VARIANT="${1:?usage: run-probe.sh <variant> [WxH] [args...]}"
SIZE="${2:-1600x1000}"
shift 2 2>/dev/null || shift 1

mkdir -p "$APP/Contents/MacOS" "$OUTDIR"
cat >"$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>ToolProbe</string>
  <key>CFBundleIdentifier</key><string>dev.morbstack.toolprobe</string>
  <key>CFBundleName</key><string>ToolProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Rebuild only when the source is newer than the binary.
if [ ! -x "$APP/Contents/MacOS/ToolProbe" ] || [ "$HERE/ToolProbe.swift" -nt "$APP/Contents/MacOS/ToolProbe" ]; then
	echo "building ToolProbe…"
	swiftc -parse-as-library -O "$HERE/ToolProbe.swift" -o "$APP/Contents/MacOS/ToolProbe"
	codesign -f -s - "$APP" >/dev/null 2>&1 || true
fi

# Only ever kill this probe, by its exact binary path. Never a broad pkill.
pkill -f "^$APP/Contents/MacOS/ToolProbe" 2>/dev/null || true
sleep 0.5

SUFFIX=""
for a in "$@"; do
	case "$a" in
	--closed) SUFFIX="${SUFFIX}-closed" ;;
	--sidebar-closed) SUFFIX="${SUFFIX}-nosidebar" ;;
	--light) SUFFIX="${SUFFIX}-light" ;;
	esac
done
OUT="$OUTDIR/probe-${VARIANT}-${SIZE}${SUFFIX}.png"

open -n "$APP" --args --variant "$VARIANT" --size "$SIZE" "$@"
sleep 2.5
"$REPO/scripts/capture-window.sh" "$OUT" ToolProbe
pkill -f "^$APP/Contents/MacOS/ToolProbe" 2>/dev/null || true
