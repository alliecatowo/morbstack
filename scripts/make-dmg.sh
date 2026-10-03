#!/usr/bin/env bash
#
# make-dmg.sh — build a distributable, drag-to-Applications DMG from an
# already-assembled Morbstack.app.
#
# This does NOT build the app: run `mise run app` (or `make app`, the
# compatibility shim) first. That separation matters for scripts/release.sh,
# which needs to build, sign, and notarize the .app *before* it goes anywhere
# near a disk image — notarizing the DMG instead of the .app is a common
# mistake and the wrong order (see docs/RELEASING.md).
#
# Layout produced: a Finder window with the Morbstack.app icon on the left,
# an /Applications symlink on the right, a brand-gradient background image,
# no toolbar, no sidebar, no status bar — the standard "drag left to right"
# installer pattern. Built entirely from base-system tools (hdiutil,
# osascript, sips) — no create-dmg, no node, nothing to `brew install` to run
# this script.
#
# Usage:
#   scripts/make-dmg.sh
#
# Env overrides:
#   APP_PATH               Path to the .app to package (default: dist/Morbstack.app)
#   DMG_PATH                Output DMG path (default: dist/Morbstack-<version>.dmg)
#   VOLUME_NAME              Mounted-volume / window title (default: Morbstack)
#   VERSION                   Version string used in the default DMG_PATH and
#                              volume subtitle (default: read from APP_PATH's
#                              Info.plist CFBundleShortVersionString)
#   MORBSTACK_SIGN_IDENTITY    Developer ID (or ad-hoc "-") to codesign the
#                              final DMG with. Unset: the DMG is built but
#                              left unsigned (see the warning this prints).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PACKAGING_DIR="${REPO_ROOT}/packaging"

APP_PATH="${APP_PATH:-${REPO_ROOT}/dist/Morbstack.app}"
VOLUME_NAME="${VOLUME_NAME:-Morbstack}"

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------

if ! command -v hdiutil >/dev/null 2>&1; then
	echo "error: hdiutil not found; this script only runs on macOS" >&2
	exit 1
fi

if [ ! -d "${APP_PATH}" ]; then
	echo "error: ${APP_PATH} not found" >&2
	echo "       build it first: mise run app   (or: make app)" >&2
	exit 1
fi

APP_INFO_PLIST="${APP_PATH}/Contents/Info.plist"
if [ ! -f "${APP_INFO_PLIST}" ]; then
	echo "error: ${APP_INFO_PLIST} not found — ${APP_PATH} doesn't look like a real .app bundle" >&2
	exit 1
fi

APP_EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "${APP_INFO_PLIST}" 2>/dev/null || true)"
if [ ! -x "${APP_PATH}/Contents/MacOS/${APP_EXECUTABLE_NAME}" ]; then
	echo "error: ${APP_PATH}/Contents/MacOS/${APP_EXECUTABLE_NAME} is missing or not executable" >&2
	echo "       ${APP_PATH} looks incomplete or unsigned; rebuild with: mise run app" >&2
	exit 1
fi

# VERSION defaults to whatever's actually stamped into the bundle (mise run
# app / make app copy this in from MorbstackKit/Version.swift), not the
# source file directly — the DMG should describe the bundle it's actually
# wrapping, even if someone points APP_PATH at an older build.
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_INFO_PLIST}" 2>/dev/null || echo "0.0.0")}"

DMG_PATH="${DMG_PATH:-${REPO_ROOT}/dist/Morbstack-${VERSION}.dmg}"

echo "packaging ${APP_PATH} (version ${VERSION}) -> ${DMG_PATH}"

# ---------------------------------------------------------------------------
# Background image: prefer the pre-rasterized PNGs committed alongside the
# hand-written SVG (packaging/dmg-background.svg is the source of truth; see
# packaging/render-dmg-background.sh for how the PNGs were produced and why
# that's a separate, re-runnable script rather than inline logic here). Only
# fall back to rendering them on the fly if they're somehow missing — a
# fresh clone should be able to build a DMG without a working SVG
# rasterizer. If even that fallback fails (no qlmanage / no swift on this
# machine), warn and build the DMG without a background rather than failing
# the whole release over cosmetics.
# ---------------------------------------------------------------------------

BACKGROUND_1X="${PACKAGING_DIR}/dmg-background.png"
BACKGROUND_2X="${PACKAGING_DIR}/dmg-background@2x.png"

if [ ! -f "${BACKGROUND_1X}" ] || [ ! -f "${BACKGROUND_2X}" ]; then
	echo "note: packaging/dmg-background.png(@2x) missing; rendering from the SVG..."
	if ! "${PACKAGING_DIR}/render-dmg-background.sh"; then
		echo "warning: could not render a DMG background image (no qlmanage/swift?)." >&2
		echo "         continuing without one — the DMG will still work, just plainer." >&2
	fi
fi

HAVE_BACKGROUND=0
if [ -f "${BACKGROUND_1X}" ]; then
	HAVE_BACKGROUND=1
fi

# ---------------------------------------------------------------------------
# Stage the DMG contents in a scratch directory: a copy of the .app (hdiutil
# create -srcfolder copies everything under this directory verbatim, so what
# goes in here is exactly what ends up on the volume) plus the /Applications
# symlink and the hidden background-image folder Finder will reference.
# ---------------------------------------------------------------------------

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/morbstack-dmg-stage.XXXXXX")"
RW_DMG="$(mktemp "${TMPDIR:-/tmp}/morbstack-dmg-rw.XXXXXX.dmg")"
rm -f "${RW_DMG}" # hdiutil creates this itself; mktemp only reserves the name
MOUNT_POINT=""

cleanup() {
	if [ -n "${MOUNT_POINT}" ] && [ -d "${MOUNT_POINT}" ]; then
		hdiutil detach "${MOUNT_POINT}" -quiet 2>/dev/null || true
	fi
	rm -rf "${STAGE_DIR}"
	rm -f "${RW_DMG}"
}
trap cleanup EXIT

echo "staging DMG contents in ${STAGE_DIR}..."
cp -R "${APP_PATH}" "${STAGE_DIR}/Morbstack.app"
ln -s /Applications "${STAGE_DIR}/Applications"

if [ "${HAVE_BACKGROUND}" = "1" ]; then
	mkdir -p "${STAGE_DIR}/.background"
	cp "${BACKGROUND_1X}" "${STAGE_DIR}/.background/background.png"
	if [ -f "${BACKGROUND_2X}" ]; then
		cp "${BACKGROUND_2X}" "${STAGE_DIR}/.background/background@2x.png"
	fi
fi

# ---------------------------------------------------------------------------
# Build a read-write disk image from the staged folder, lay it out with
# Finder over AppleScript while it's mounted, then convert to a compressed,
# read-only image for distribution. Two-image approach (RW working copy,
# then convert) because hdiutil cannot resize a compressed UDZO image after
# the fact — the layout step needs room to write .DS_Store etc, and
# compression happens once, at the end, on the final byte layout.
# ---------------------------------------------------------------------------

echo "creating disk image..."
if ! hdiutil create -volname "${VOLUME_NAME}" -srcfolder "${STAGE_DIR}" \
	-fs APFS -format UDRW -ov -quiet "${RW_DMG}"; then
	echo "error: hdiutil create failed" >&2
	exit 1
fi

echo "attaching disk image to lay out the Finder window..."
# Deliberately NOT -nobrowse: Finder's AppleScript "disk" object only
# resolves for volumes mounted the normal, browsable way (confirmed
# empirically — a -nobrowse mount is invisible to `tell application
# "Finder" to get name of every disk`, even though it's on disk and usable
# from the shell). -noautoopen so Finder doesn't pop a window before the
# script below is ready to configure it.
if ! hdiutil attach "${RW_DMG}" -readwrite -noautoopen -quiet; then
	echo "error: hdiutil attach failed" >&2
	exit 1
fi
MOUNT_POINT="/Volumes/${VOLUME_NAME}"
if [ ! -d "${MOUNT_POINT}" ]; then
	echo "error: expected the disk image mounted at ${MOUNT_POINT}" >&2
	exit 1
fi

# Volume icon: reuse the app's own .icns if `mise run app`/`make app` built
# one, so the mounted DMG and its icon in Finder read as the same product as
# the Dock icon it installs. Best-effort — a missing icon is not a reason to
# fail the whole DMG.
APP_ICON="${APP_PATH}/Contents/Resources/AppIcon.icns"
if [ -f "${APP_ICON}" ]; then
	cp "${APP_ICON}" "${MOUNT_POINT}/.VolumeIcon.icns"
	SetFile -a C "${MOUNT_POINT}" 2>/dev/null || true
fi

# Window/icon layout via Finder, over AppleScript. This is the one part of
# this script that needs the calling process to have Automation permission
# for Finder (System Settings > Privacy & Security > Automation) — on a
# machine that hasn't granted it, macOS shows a permission prompt the first
# time and osascript otherwise times out. Either way, treat it as
# best-effort: a DMG without the pretty layout still installs Morbstack
# correctly (plain Finder icon view, default positions), so warn and
# continue rather than aborting the release over window dressing.
#
# Icon positions {180,170} / {480,170} and the window bounds below are the
# single source of truth for packaging/dmg-background.svg's icon-guide
# circles and arrow — see that file if either one needs to move; they must
# move together.
set +e
osascript <<APPLESCRIPT
tell application "Finder"
	tell disk "${VOLUME_NAME}"
		open
		set current view of container window to icon view
		set toolbar visible of container window to false
		set statusbar visible of container window to false
		set the bounds of container window to {400, 100, 1060, 500}
		set theViewOptions to the icon view options of container window
		set arrangement of theViewOptions to not arranged
		set icon size of theViewOptions to 128
		if ${HAVE_BACKGROUND} = 1 then
			set background picture of theViewOptions to file ".background:background.png"
		end if
		set position of item "Morbstack.app" of container window to {180, 170}
		set position of item "Applications" of container window to {480, 170}
		close
		open
		update without registering applications
		delay 1
	end tell
end tell
APPLESCRIPT
OSASCRIPT_STATUS=$?
set -e

if [ "${OSASCRIPT_STATUS}" -ne 0 ]; then
	echo "warning: Finder window layout via osascript failed (exit ${OSASCRIPT_STATUS})." >&2
	echo "         The DMG will still work — Morbstack.app and an Applications" >&2
	echo "         alias are both on it — just without the custom background/" >&2
	echo "         icon layout. This usually means the calling app (Terminal," >&2
	echo "         iTerm, CI runner, ...) has not been granted Automation" >&2
	echo "         access to Finder: System Settings > Privacy & Security >" >&2
	echo "         Automation." >&2
fi

# Give Finder a moment to flush .DS_Store before detaching — `close`/`open`
# above already forces one write, but detaching too eagerly right after has
# been observed (elsewhere, same pattern) to race Finder's own writeback.
sleep 1
hdiutil detach "${MOUNT_POINT}" -quiet
MOUNT_POINT=""

# ---------------------------------------------------------------------------
# Convert to the final compressed, read-only image.
# ---------------------------------------------------------------------------

mkdir -p "$(dirname "${DMG_PATH}")"
rm -f "${DMG_PATH}"
echo "compressing final image..."
if ! hdiutil convert "${RW_DMG}" -format UDZO -imagekey zlib-level=9 \
	-o "${DMG_PATH}" -ov -quiet; then
	echo "error: hdiutil convert failed" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Sign, or warn loudly that this DMG is unsigned.
# ---------------------------------------------------------------------------

if [ -n "${MORBSTACK_SIGN_IDENTITY:-}" ]; then
	echo "signing ${DMG_PATH} with identity: ${MORBSTACK_SIGN_IDENTITY}"
	if ! codesign --force --sign "${MORBSTACK_SIGN_IDENTITY}" "${DMG_PATH}"; then
		echo "error: codesign failed on ${DMG_PATH}" >&2
		exit 1
	fi
else
	cat >&2 <<EOF
warning: MORBSTACK_SIGN_IDENTITY is not set — ${DMG_PATH} is UNSIGNED.
         Gatekeeper will quarantine it on any Mac it's downloaded to
         (translocation / "cannot be opened because it is from an
         unidentified developer"), and it has not been notarized either.
         This is fine for local testing; it is not something to publish as
         a release asset. See docs/RELEASING.md for the signing +
         notarization steps scripts/release.sh drives.
EOF
fi

echo "built ${DMG_PATH}"
