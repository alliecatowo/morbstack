#!/usr/bin/env bash
# Fetch the exact Moby source used to build Morbstack's patched guest dockerd.
#
# This deliberately keeps the sizeable upstream checkout out of the worktree.
# The commit, not a moving release branch, is the trust boundary for the
# downstream patch under guest/moby-patches/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MOBY_VERSION="docker-v29.7.1"
# `docker-v29.7.1` is an annotated tag. Pin its peeled source commit, not the
# tag object, so a shallow fetch/check-out verifies the actual Go tree.
MOBY_COMMIT="c5b8ce9274b5c00cb1f8287c8e258edc1f01176d"
MOBY_SOURCE_DIR="${MORBSTACK_MOBY_SOURCE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/morbstack/moby/${MOBY_VERSION}}"

if [ -d "${MOBY_SOURCE_DIR}/.git" ]; then
	actual="$(git -C "${MOBY_SOURCE_DIR}" rev-parse HEAD)"
	if [ "${actual}" = "${MOBY_COMMIT}" ]; then
		echo "Using pinned Moby source: ${MOBY_SOURCE_DIR} (${actual})"
		exit 0
	fi
	echo "error: ${MOBY_SOURCE_DIR} exists at ${actual}, expected ${MOBY_COMMIT}" >&2
	echo "       remove that one cache directory and run this command again" >&2
	exit 1
fi

parent_dir="$(dirname "${MOBY_SOURCE_DIR}")"
mkdir -p "${parent_dir}"
temporary_dir="$(mktemp -d "${parent_dir}/.${MOBY_VERSION}.XXXXXX")"
cleanup() { rm -rf "${temporary_dir}"; }
trap cleanup EXIT

git -C "${temporary_dir}" init -q
git -C "${temporary_dir}" remote add origin https://github.com/moby/moby.git
git -C "${temporary_dir}" fetch --depth 1 origin "${MOBY_COMMIT}"
git -C "${temporary_dir}" checkout --detach -q FETCH_HEAD
actual="$(git -C "${temporary_dir}" rev-parse HEAD)"
if [ "${actual}" != "${MOBY_COMMIT}" ]; then
	echo "error: fetched Moby commit ${actual}, expected ${MOBY_COMMIT}" >&2
	exit 1
fi

mv "${temporary_dir}" "${MOBY_SOURCE_DIR}"
trap - EXIT
echo "Fetched pinned Moby ${MOBY_VERSION} at ${MOBY_SOURCE_DIR}"
echo "Patch input: ${REPO_ROOT}/guest/moby-patches/0001-morbstack-publish-all-host-allocator.patch"
