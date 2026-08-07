#!/usr/bin/env bash
# run-perf.sh — build PerfProbe into a real app bundle and run one shape.
#
#   ./run-perf.sh "detail=table40,insp=form3,tb=full,mount=insp,inspw=range"
#   ./run-perf.sh "detail=text,insp=text,tb=none" --cycles 6
#   ./run-perf.sh "…" --hold          # print blocks live, drive it yourself
#
# Why a bundle: without an Info.plist and a bundle identifier NSApplication is
# not given a real titlebar, and the toolbar is half the hypothesis.
#
# The probe is its own app (dev.morbstack.perfprobe). It never touches
# dist/Morbstack.app and is only ever killed by its own exact binary path.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="${TMPDIR:-/tmp}/perfprobe"
APP="$BUILD/PerfProbe.app"

SPEC="${1:?usage: run-perf.sh <perf-spec> [extra args...]}"
shift

mkdir -p "$APP/Contents/MacOS"
cat >"$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>PerfProbe</string>
  <key>CFBundleIdentifier</key><string>dev.morbstack.perfprobe</string>
  <key>CFBundleName</key><string>PerfProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

BIN="$APP/Contents/MacOS/PerfProbe"
if [ ! -x "$BIN" ] || [ "$HERE/PerfProbe.swift" -nt "$BIN" ]; then
	echo "building PerfProbe…" >&2
	# -O so the measurement is of AppKit, not of unoptimised Swift.
	swiftc -parse-as-library -O "$HERE/PerfProbe.swift" -o "$BIN"
	codesign -f -s - "$APP" >/dev/null 2>&1 || true
fi

# Only ever this probe, by its exact binary path. Never a broad pkill.
pkill -f "^$BIN" 2>/dev/null || true
sleep 0.4

# Run in the foreground so stdout is the report. `open -n` would detach it, and
# a detached probe is exactly what accumulates.
"$BIN" --perf "$SPEC" "$@"
