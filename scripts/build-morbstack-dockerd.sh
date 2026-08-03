#!/usr/bin/env bash
# Build Morbstack's version-pinned, publish-all-aware guest dockerd.
#
# Moby's supported Buildx/Bake path runs its Linux toolchain in BuildKit. This
# is required on macOS: invoking Moby's internal `hack/make.sh` directly would
# execute its GNU-userland assumptions (including GNU `date`) on the Mac.
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
cleanup() {
	git -C "${MOBY_SOURCE_DIR}" worktree remove --force "${build_dir}" 2>/dev/null || true
	rm -rf "${build_dir}"
}
trap cleanup EXIT
git -C "${MOBY_SOURCE_DIR}" worktree add --detach -q "${build_dir}" "${MOBY_COMMIT}"
git -C "${build_dir}" apply --check "${PATCH_FILE}"
git -C "${build_dir}" apply "${PATCH_FILE}"

# `docker buildx bake binary` is Moby's documented supported build route. The
# destination is an explicit host directory, while the target platform makes
# an accidental macOS/arm64 binary impossible. `SOURCE_DATE_EPOCH` comes from
# Git's commit metadata, not BSD/GNU-incompatible `date` flags on the host.
if ! docker buildx version >/dev/null 2>&1; then
	echo "error: Docker Buildx with a usable BuildKit builder is required" >&2
	echo "       install/enable Docker Buildx, then retry mise run guest-image" >&2
	exit 1
fi
source_date_epoch="$(git -C "${build_dir}" show -s --format=%ct "${MOBY_COMMIT}")"
output_dir="${build_dir}/morbstack-output"
(
	cd "${build_dir}"
	DESTDIR="${output_dir}" \
		SOURCE_DATE_EPOCH="${source_date_epoch}" \
		docker buildx bake binary --set "*.platform=linux/arm64"
)

candidate="${output_dir}/dockerd"
if [ ! -x "${candidate}" ]; then
	echo "error: Moby binary target completed without ${candidate}" >&2
	exit 1
fi
mkdir -p "$(dirname "${OUTPUT}")"
install -m 0755 "${candidate}" "${OUTPUT}"
echo "Installed patched Linux/arm64 dockerd: ${OUTPUT}"
