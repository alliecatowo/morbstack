#!/usr/bin/env bash
# Build Morbstack's version-pinned, publish-all-aware guest dockerd.
#
# Moby's own binary target runs in a Linux build environment. On macOS use a
# Linux/arm64 builder (for example Docker buildx); this script intentionally
# fails rather than silently installing a host-architecture daemon.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MOBY_VERSION="docker-v29.7.1"
# Peeled commit for the annotated `docker-v29.7.1` tag.
MOBY_COMMIT="c5b8ce9274b5c00cb1f8287c8e258edc1f01176d"
MOBY_SOURCE_DIR="${MORBSTACK_MOBY_SOURCE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/morbstack/moby/${MOBY_VERSION}}"
PATCH_FILE="${REPO_ROOT}/guest/moby-patches/0001-morbstack-publish-all-host-allocator.patch"
OUTPUT="${REPO_ROOT}/dist/guest-bin/morbstack-dockerd"

if [ ! -d "${MOBY_SOURCE_DIR}/.git" ]; then
	"${SCRIPT_DIR}/fetch-moby-source.sh"
fi
actual="$(git -C "${MOBY_SOURCE_DIR}" rev-parse HEAD)"
if [ "${actual}" != "${MOBY_COMMIT}" ]; then
	echo "error: Moby source is ${actual}, expected ${MOBY_COMMIT}" >&2
	exit 1
fi
if [ ! -f "${PATCH_FILE}" ]; then
	echo "error: missing Moby patch ${PATCH_FILE}" >&2
	exit 1
fi

build_dir="$(mktemp -d "${TMPDIR:-/tmp}/morbstack-moby-build.XXXXXX")"
cleanup() { rm -rf "${build_dir}"; }
trap cleanup EXIT
git -C "${MOBY_SOURCE_DIR}" worktree add --detach -q "${build_dir}" "${MOBY_COMMIT}"
git -C "${build_dir}" apply --check "${PATCH_FILE}"
git -C "${build_dir}" apply "${PATCH_FILE}"

# Moby's documented binary target owns its toolchain and output layout. The
# explicit platform prevents an Apple-host `dockerd` from entering guest-bin.
(
	cd "${build_dir}"
	PLATFORM="linux/arm64" hack/make.sh binary
)

candidate="${build_dir}/bundles/binary-daemon/dockerd"
if [ ! -x "${candidate}" ]; then
	echo "error: Moby binary target completed without ${candidate}" >&2
	exit 1
fi
mkdir -p "$(dirname "${OUTPUT}")"
install -m 0755 "${candidate}" "${OUTPUT}"
echo "Installed patched Linux/arm64 dockerd: ${OUTPUT}"
