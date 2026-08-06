#!/usr/bin/env bash
#
# fetch-scan-tools.sh — the first-run fetch `morb scan` and the Images inspector's
# Vulnerabilities section both depend on: anchore/syft (SBOM generation) and
# anchore/grype (vulnerability matching), HOST darwin-arm64 release binaries.
#
#   syft:   1.50.0
#           -> ${MORBSTACK_HOME}/scan/bin/syft
#   grype:  0.116.1
#           -> ${MORBSTACK_HOME}/scan/bin/grype
#
# Same pattern as every third-party asset scripts/fetch-guest-assets.sh fetches:
# downloaded from the tool's own GitHub Release, checked against a sha256 recorded
# in this script, cross-checked against the release's own published checksums.txt
# sidecar (same belt-and-braces treatment as fetch_compose/fetch_buildx there), and
# refused if either check fails. Idempotent: a destination that already hashes
# correctly is skipped.
#
# Deliberately NOT `dist/host-bin/`, unlike the docker/compose/buildx/kubectl host
# binaries that live there: `mise-tasks/app` copies that whole directory into the
# signed app bundle (`cp -R dist/host-bin dist/Morbstack.app/Contents/Resources/host-bin`),
# and CLAUDE.md #1.1 is explicit that extra nested executables inside a signed
# bundle are a code-signing landmine, not a place to add two more Go binaries on a
# whim. This is also a first-run fetch, not a bundled payload, by design: grype's
# vulnerability database (a couple hundred MB, stale within a day) has to be
# downloaded regardless of whether the ~100 MB of syft/grype binaries shipped in
# the DMG, so bundling them would cost every user real megabytes to save a
# download the database already makes unavoidable. Fetching into
# ${MORBSTACK_HOME}/scan/bin — beside the database at
# ${MORBSTACK_HOME}/scan/grype-db (see ScanPaths in MorbScan/ScanEngine.swift) —
# keeps every byte this feature ever touches out of the tree `mise run app`
# assembles, on a repo checkout and a shipped app alike, with no bundling
# ambiguity to reason about later.
#
# `ToolLocator.candidateDirectories()` (mac/Sources/MorbScan/ToolLocator.swift)
# checks this exact directory first, ahead of PATH, so a scan's results are
# reproducible against the version pinned here rather than whatever a developer's
# Homebrew happened to have that week.
#
# Usage:
#   scripts/fetch-scan-tools.sh              # fetch both
#   scripts/fetch-scan-tools.sh --syft-only   # syft only
#   scripts/fetch-scan-tools.sh --grype-only  # grype only
#   scripts/fetch-scan-tools.sh -h            # help
#
# Env:
#   MORBSTACK_HOME   Morbstack runtime root (default ~/.morbstack).
set -euo pipefail

MORBSTACK_HOME="${MORBSTACK_HOME:-${HOME}/.morbstack}"
DEST_DIR="${MORBSTACK_HOME}/scan/bin"

# ---------------------------------------------------------------------------
# Pinned provenance
# ---------------------------------------------------------------------------

# --- syft: anchore/syft, HOST darwin-arm64 ---
#
# Verified 2026-08-06 by downloading the release archive directly and hashing it
# on this machine (`shasum -a 256`); the archive hash and the extracted `syft`
# binary's own hash were both then cross-checked against
# https://github.com/anchore/syft/releases/download/v1.50.0/syft_1.50.0_checksums.txt
# (the "darwin_arm64.tar.gz" line), which agreed with the local computation.
SYFT_VERSION="v1.50.0"
SYFT_RELEASE_URL="https://github.com/anchore/syft/releases/download/v1.50.0/syft_1.50.0_darwin_arm64.tar.gz"
SYFT_CHECKSUMS_URL="https://github.com/anchore/syft/releases/download/v1.50.0/syft_1.50.0_checksums.txt"
SYFT_ARCHIVE_ASSET="syft_1.50.0_darwin_arm64.tar.gz"
SYFT_ARCHIVE_SHA256="e32fdb9d47823fa633748a1efca2528fd77c37469ea93c9e40ab835da44e4cce"
# The extracted `syft` binary's own hash — proves the exact executable that lands
# in ${DEST_DIR}, not only the archive it arrived in.
SYFT_SHA256="5d59c9e6fa641793ddb48bc90b5b7ad63bf7303a52835b75b1beee3757463998"

# --- grype: anchore/grype, HOST darwin-arm64 ---
#
# Same verification as syft, same day: downloaded, hashed locally, cross-checked
# against
# https://github.com/anchore/grype/releases/download/v0.116.1/grype_0.116.1_checksums.txt
# (the "darwin_arm64.tar.gz" line), which agreed with the local computation. This
# grype release reports `Syft Version: v1.50.0` and `Supported DB Schema: 6` in its
# own `grype version` output, matching the syft pin above.
GRYPE_VERSION="v0.116.1"
GRYPE_RELEASE_URL="https://github.com/anchore/grype/releases/download/v0.116.1/grype_0.116.1_darwin_arm64.tar.gz"
GRYPE_CHECKSUMS_URL="https://github.com/anchore/grype/releases/download/v0.116.1/grype_0.116.1_checksums.txt"
GRYPE_ARCHIVE_ASSET="grype_0.116.1_darwin_arm64.tar.gz"
GRYPE_ARCHIVE_SHA256="f493f169cbaae48bade169532b20235fc16653d2a044a5bc6fe6f69a3923f975"
GRYPE_SHA256="361b86bc5906fa38ad24cc8a0c2ce9128ac7d8931e82505236a8d0b16bbf2fbe"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

usage() {
	cat <<EOF
Usage: $(basename "$0") [--syft-only|--grype-only] [-h]

Fetch and verify the local scan tools \`morb scan\` and the Images inspector's
Vulnerabilities section need:
  syft   ${SYFT_VERSION}  -> ${DEST_DIR}/syft
  grype  ${GRYPE_VERSION} -> ${DEST_DIR}/grype

Neither is bundled in Morbstack.app or the repository's dist/ tree; this is a
first-run fetch, same as grype's own vulnerability database.

Options:
  --syft-only    Only fetch/verify syft
  --grype-only   Only fetch/verify grype
  -h             Show this help and exit
EOF
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

check() { printf '  \033[32m\xE2\x9C\x93\033[0m %s\n' "$1"; }
info() { printf '  -> %s\n' "$1"; }
fail() {
	echo "error: $1" >&2
	exit 1
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required but not found on PATH"
}

# ---------------------------------------------------------------------------
# Generic fetch: one darwin_arm64 tar.gz release asset containing a single
# top-level binary member of the same name, verified against a pin AND the
# release's own checksums.txt sidecar. Shared by fetch_syft and fetch_grype —
# the two tools have identical release layouts.
# ---------------------------------------------------------------------------

fetch_tool() {
	local tool_name="$1" version="$2" release_url="$3" checksums_url="$4"
	local archive_asset="$5" archive_sha256="$6" tool_sha256="$7"

	echo "== ${tool_name} (${version}, HOST darwin-arm64) =="

	local dest_file="${DEST_DIR}/${tool_name}"

	require_cmd curl
	require_cmd tar

	if [ -x "${dest_file}" ]; then
		local have_sha
		have_sha="$(sha256_of "${dest_file}")"
		if [ "${have_sha}" = "${tool_sha256}" ]; then
			check "${tool_name} already present and verified: ${dest_file}"
			return 0
		fi
		echo "  existing ${dest_file} has sha256 ${have_sha}, expected ${tool_sha256}; re-fetching" >&2
	fi

	mkdir -p "${DEST_DIR}"

	local tmp_archive tmp_extract
	tmp_archive="$(mktemp "${TMPDIR:-/tmp}/morbstack-${tool_name}-archive.XXXXXX")"
	tmp_extract="$(mktemp -d "${TMPDIR:-/tmp}/morbstack-${tool_name}-extract.XXXXXX")"
	trap 'rm -f "${tmp_archive}"; rm -rf "${tmp_extract}"' RETURN

	info "downloading ${release_url}"
	curl --fail --location --show-error --progress-bar --output "${tmp_archive}" "${release_url}" ||
		fail "failed to download ${tool_name}"

	local got_archive_sha
	got_archive_sha="$(sha256_of "${tmp_archive}")"
	[ "${got_archive_sha}" = "${archive_sha256}" ] ||
		fail "${tool_name} archive sha256 mismatch: got ${got_archive_sha}, expected ${archive_sha256} (possible corruption or upstream tamper)"
	check "archive sha256 verified against the pin"

	info "fetching checksums sidecar ${checksums_url}"
	local sidecar_sha
	sidecar_sha="$(curl --fail --location --show-error --silent "${checksums_url}" |
		awk -v want="${archive_asset}" '$2 == want { print $1 }')"
	[ -n "${sidecar_sha}" ] || fail "failed to fetch/parse the ${tool_name} checksums sidecar (no ${archive_asset} line)"
	[ "${sidecar_sha}" = "${archive_sha256}" ] ||
		fail "${tool_name} checksums sidecar (${sidecar_sha}) does not match the pin in this script (${archive_sha256}); upstream release may have changed"
	check "sidecar agrees with the pin"

	tar xzf "${tmp_archive}" -C "${tmp_extract}" "${tool_name}" ||
		fail "expected member ${tool_name} not found inside the ${tool_name} archive"

	local extracted="${tmp_extract}/${tool_name}"
	[ -f "${extracted}" ] || fail "expected member ${tool_name} not found inside the ${tool_name} archive"
	local member_sha
	member_sha="$(sha256_of "${extracted}")"
	[ "${member_sha}" = "${tool_sha256}" ] ||
		fail "extracted ${tool_name} sha256 mismatch: got ${member_sha}, expected ${tool_sha256}"
	check "extracted ${tool_name} sha256 verified against the pin"

	install -m 0755 "${extracted}" "${dest_file}"
	check "installed and verified: ${dest_file}"

	trap - RETURN
	rm -f "${tmp_archive}"
	rm -rf "${tmp_extract}"
}

write_provenance() {
	cat >"${DEST_DIR}/PROVENANCE.txt" <<EOF
Morbstack local scan tools provenance
======================================

Neither binary here is bundled in Morbstack.app or the repository's dist/
tree — see the header comment in scripts/fetch-scan-tools.sh for why. This
directory is a first-run fetch destination, the same way grype's own
vulnerability database (fetched into scan/grype-db beside this one) is.

File: syft
Source: ${SYFT_RELEASE_URL}
Version: ${SYFT_VERSION}
Archive sha256: ${SYFT_ARCHIVE_SHA256}
Binary sha256: ${SYFT_SHA256}
Verification: archive and extracted binary both pinned in
scripts/fetch-scan-tools.sh, archive re-checked on every fetch against
upstream's own release sidecar (${SYFT_CHECKSUMS_URL}).

File: grype
Source: ${GRYPE_RELEASE_URL}
Version: ${GRYPE_VERSION}
Archive sha256: ${GRYPE_ARCHIVE_SHA256}
Binary sha256: ${GRYPE_SHA256}
Verification: archive and extracted binary both pinned in
scripts/fetch-scan-tools.sh, archive re-checked on every fetch against
upstream's own release sidecar (${GRYPE_CHECKSUMS_URL}).

Fetched by scripts/fetch-scan-tools.sh. \`morb scan --check\` reports whether
both are currently present and verified.
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

DO_SYFT=1
DO_GRYPE=1

while [ $# -gt 0 ]; do
	case "$1" in
	--syft-only)
		DO_SYFT=1
		DO_GRYPE=0
		;;
	--grype-only)
		DO_SYFT=0
		DO_GRYPE=1
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "error: unknown argument: $1" >&2
		usage
		exit 1
		;;
	esac
	shift
done

[ "${DO_SYFT}" -eq 1 ] && fetch_tool syft "${SYFT_VERSION}" "${SYFT_RELEASE_URL}" "${SYFT_CHECKSUMS_URL}" \
	"${SYFT_ARCHIVE_ASSET}" "${SYFT_ARCHIVE_SHA256}" "${SYFT_SHA256}"
[ "${DO_GRYPE}" -eq 1 ] && fetch_tool grype "${GRYPE_VERSION}" "${GRYPE_RELEASE_URL}" "${GRYPE_CHECKSUMS_URL}" \
	"${GRYPE_ARCHIVE_ASSET}" "${GRYPE_ARCHIVE_SHA256}" "${GRYPE_SHA256}"

mkdir -p "${DEST_DIR}"
write_provenance
info "see ${DEST_DIR}/PROVENANCE.txt for the pin chain"

echo ""
echo "Done."
