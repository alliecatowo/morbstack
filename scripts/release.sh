#!/usr/bin/env bash
#
# release.sh — build, package, and verify a distributable Morbstack.app DMG,
# runnable locally (not CI-only). Drives the existing pieces in the right
# order:
#
#   1. scripts/fetch-guest-assets.sh   pinned, sha256-verified upstream assets
#   2. mise run guest-image            cross-compiled morbinit + initramfs
#   3. mise run app                    swift release build, bundle assembly,
#                                       inside-out ad-hoc signing (see
#                                       mise-tasks/app; never touched here)
#   4. scripts/make-dmg.sh             drag-to-Applications DMG
#   5. an independent entitlement check against the DMG's own contents
#
# `mise run app` already ends with a hard post-check that morbstackd did not
# lose com.apple.security.virtualization during signing (CLAUDE.md §1.1).
# Step 5 here is a SEPARATE check against the bytes actually inside the
# built DMG — copying into the DMG stage directory and running it through
# hdiutil is itself a step that could (in principle) disturb what got
# verified in step 3, so this script does not take that on faith.
#
# What this script deliberately does NOT do: sign with a Developer ID, or
# notarize. The bundle is ad-hoc signed only (mise-tasks/app hardcodes
# `codesign --sign -`). See docs/RELEASING.md for exactly what that means —
# short version: com.apple.security.virtualization is a *restricted*
# entitlement, and an ad-hoc signature carries no provisioning profile to
# authorize it anywhere but the Mac that built it. Developer ID signing and
# notarization are tracked separately (REL-2, SP-9) and are out of scope
# here.
#
# Usage:
#   scripts/release.sh
#
# Env overrides:
#   MORBSTACK_HOME
#       Scratch runtime root this script fetches/builds the kernel, initrd,
#       and Kubernetes payloads into before handing them to `mise run app`
#       (which stages them into the bundle — see scripts/package-runtime-
#       artifacts.sh). Defaults to <repo>/dist/.release-home, a directory
#       under dist/ that .gitignore already excludes (dist/*/* ), so this
#       script's runs are hermetic by default and never touch a real
#       ~/.morbstack a running daemon might own.
#
#       Point this at an already-populated MORBSTACK_HOME (e.g. a normal
#       dev checkout's ~/.morbstack) to skip re-fetching ~300MB of pinned
#       upstream assets that dev checkout already has. Do not point it at
#       a MORBSTACK_HOME any currently-running morbstackd is using — this
#       script's fetch and guest-image steps write into
#       $MORBSTACK_HOME/data/kernel and $MORBSTACK_HOME/data/k8s.
#
#   MORBSTACK_SIGN_IDENTITY
#       Passed through unchanged to scripts/make-dmg.sh, which signs the
#       DMG file itself (not the app inside it — that signing is fixed
#       ad-hoc by mise-tasks/app, see above). Unset by default: the DMG is
#       built but left unsigned, same as running make-dmg.sh directly.
#
#   SKIP_FETCH=1
#       Skip scripts/fetch-guest-assets.sh entirely. For fast iteration
#       once MORBSTACK_HOME and dist/{guest-bin,rootfs,apks,host-bin} are
#       already populated and current — fetch-guest-assets.sh is itself
#       idempotent (each asset is skipped once present and hash-verified),
#       so this is a convenience, not a requirement.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

if ! command -v mise >/dev/null 2>&1; then
	echo "error: mise not found on PATH — see README.md / CLAUDE.md for setup (mise trust && mise install)" >&2
	exit 1
fi

# Hermetic by default (see the env-override comment above); an explicit
# MORBSTACK_HOME from the caller's environment always wins.
MORBSTACK_HOME="${MORBSTACK_HOME:-${REPO_ROOT}/dist/.release-home}"
export MORBSTACK_HOME
mkdir -p "${MORBSTACK_HOME}"
echo "using MORBSTACK_HOME=${MORBSTACK_HOME}"

# ---------------------------------------------------------------------------
# 1. Pinned, sha256-verified third-party guest + host-CLI assets.
#
# Every third-party asset this repo fetches is hash-pinned in
# scripts/fetch-guest-assets.sh's own source (see its header comment for the
# full list and provenance chain) — this step preserves that property rather
# than re-implementing it. No arguments = every asset except the optional,
# not-yet-wired kubectl helper (see --host-kubectl-only in that script).
# ---------------------------------------------------------------------------

if [ "${SKIP_FETCH:-0}" = "1" ]; then
	echo "==> [1/5] SKIP_FETCH=1: skipping scripts/fetch-guest-assets.sh"
else
	echo "==> [1/5] fetching pinned guest + host-CLI assets"
	scripts/fetch-guest-assets.sh
fi

# ---------------------------------------------------------------------------
# 2. The bootable guest initramfs. This is the step CLAUDE.md §1.5 warns
# `mise run app` does NOT do on its own — skip it and the DMG ships a stale
# or absent guest.
# ---------------------------------------------------------------------------

echo "==> [2/5] mise run guest-image"
mise run guest-image

# ---------------------------------------------------------------------------
# 3. Swift release build, bundle assembly, inside-out ad-hoc signing. All of
# this — including the hard "did morbstackd keep its entitlement" gate — is
# mise-tasks/app; nothing about signing order or --deep is reimplemented
# here (CLAUDE.md §1.1 is explicit about why that would be dangerous).
#
# mise-tasks/app stages the runtime it packages from
# ${MORBSTACK_RUNTIME_SOURCE_ROOT:-${MORBSTACK_HOME}/data} — which is
# exactly the MORBSTACK_HOME this script exported above, so the kernel/
# initrd/k8s payloads step 1 and step 2 just produced are the ones that end
# up sealed inside the signed bundle.
# ---------------------------------------------------------------------------

echo "==> [3/5] mise run app"
mise run app

APP_PATH="${REPO_ROOT}/dist/Morbstack.app"
APP_INFO_PLIST="${APP_PATH}/Contents/Info.plist"
[ -f "${APP_INFO_PLIST}" ] || {
	echo "error: ${APP_INFO_PLIST} not found after 'mise run app' — bundle assembly did not produce it" >&2
	exit 1
}
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_INFO_PLIST}" 2>/dev/null || echo "0.0.0")"
DMG_PATH="${DMG_PATH:-${REPO_ROOT}/dist/Morbstack-${VERSION}.dmg}"
export DMG_PATH

# ---------------------------------------------------------------------------
# 4. Package the DMG. scripts/make-dmg.sh does not build or sign the app —
# see its own header comment for why that separation matters here.
# ---------------------------------------------------------------------------

echo "==> [4/5] scripts/make-dmg.sh"
scripts/make-dmg.sh

[ -f "${DMG_PATH}" ] || {
	echo "error: expected DMG at ${DMG_PATH} after make-dmg.sh but it is missing" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# 5. Verify the entitlement survived packaging, against the DMG's own bytes
# — not against dist/Morbstack.app, which mise-tasks/app already checked.
# Mounted read-only so this step cannot itself alter the artifact it is
# validating.
# ---------------------------------------------------------------------------

VERIFY_MOUNT_POINT=""
cleanup() {
	if [ -n "${VERIFY_MOUNT_POINT}" ] && [ -d "${VERIFY_MOUNT_POINT}" ]; then
		hdiutil detach "${VERIFY_MOUNT_POINT}" -quiet 2>/dev/null || true
	fi
}
trap cleanup EXIT

echo "==> [5/5] verifying the virtualization entitlement inside ${DMG_PATH}"
VERIFY_MOUNT_POINT="$(mktemp -d "${TMPDIR:-/tmp}/morbstack-release-verify.XXXXXX")"
rmdir "${VERIFY_MOUNT_POINT}"
if ! hdiutil attach "${DMG_PATH}" -mountpoint "${VERIFY_MOUNT_POINT}" -readonly -nobrowse -quiet; then
	echo "error: could not attach ${DMG_PATH} for verification" >&2
	exit 1
fi

MOUNTED_APP="${VERIFY_MOUNT_POINT}/Morbstack.app"
MOUNTED_DAEMON="${MOUNTED_APP}/Contents/MacOS/morbstackd"

for required in "${MOUNTED_APP}/Contents/MacOS/MorbstackApp" "${MOUNTED_APP}/Contents/MacOS/morb" "${MOUNTED_DAEMON}"; do
	[ -x "${required}" ] || {
		echo "error: ${required} missing or not executable inside the mounted DMG" >&2
		exit 1
	}
done

# Read-only signature verification (NOT signing — `--deep` is safe here,
# unlike the codesign --sign --deep landmine CLAUDE.md §1.1 warns about;
# `--verify --deep` recursively checks existing signatures, it does not
# re-sign anything).
if ! codesign --verify --deep --strict "${MOUNTED_APP}" 2>&1; then
	echo "error: code signature verification failed for ${MOUNTED_APP}" >&2
	exit 1
fi

if ! codesign -d --entitlements - "${MOUNTED_DAEMON}" 2>&1 | grep -q "com.apple.security.virtualization"; then
	echo "error: morbstackd inside the packaged DMG does not carry com.apple.security.virtualization" >&2
	echo "       this DMG's engine can never boot a VM, on this Mac or any other — do not ship it" >&2
	exit 1
fi

hdiutil detach "${VERIFY_MOUNT_POINT}" -quiet
VERIFY_MOUNT_POINT=""

# Harmless outside GitHub Actions: only written when a workflow step already
# exported GITHUB_OUTPUT, so a plain local run never touches this file.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
	printf 'dmg_path=%s\n' "${DMG_PATH}" >>"${GITHUB_OUTPUT}"
	printf 'version=%s\n' "${VERSION}" >>"${GITHUB_OUTPUT}"
fi

echo
echo "built and verified: ${DMG_PATH}"
echo "version: ${VERSION}"
echo
echo "This bundle is ad-hoc signed, not Developer ID signed or notarized."
echo "See docs/RELEASING.md for what that does and does not let a downloaded"
echo "copy do on a different Mac."
