#!/usr/bin/env bash
#
# mkdisk.sh — create a sparse raw disk image for the Morbstack guest VM.
#
# Usage:
#   scripts/mkdisk.sh [SIZE_GIB]
#
# SIZE_GIB defaults to 64. The image is created sparse (allocated on
# write), so a 64 GiB image costs ~0 bytes of actual disk space until the
# guest writes to it.
set -euo pipefail

SIZE_GIB="${1:-64}"

case "${SIZE_GIB}" in
'' | *[!0-9]*)
	echo "error: size must be a positive integer number of GiB, got '${SIZE_GIB}'" >&2
	exit 1
	;;
esac

if [ "${SIZE_GIB}" -le 0 ]; then
	echo "error: size must be greater than zero" >&2
	exit 1
fi

# MORBSTACK_HOME mirrors the override honoured by morbstackd/morb (see
# MorbPaths in mac/Sources/MorbstackKit/Paths.swift).
MORBSTACK_HOME="${MORBSTACK_HOME:-${HOME}/.morbstack}"
DEST_DIR="${MORBSTACK_HOME}/data"
DEST_FILE="${DEST_DIR}/disk.img"

if [ -e "${DEST_FILE}" ]; then
	echo "error: ${DEST_FILE} already exists; refusing to overwrite" >&2
	echo "       remove it yourself first if you really want a fresh disk." >&2
	exit 1
fi

mkdir -p "${DEST_DIR}"

echo "Creating sparse ${SIZE_GIB} GiB disk image at ${DEST_FILE}..."

if command -v mkfile >/dev/null 2>&1; then
	# mkfile -n: create the file with the given size without actually
	# allocating/zeroing blocks, i.e. a sparse file. This is the standard
	# macOS way to do this.
	mkfile -n "${SIZE_GIB}g" "${DEST_FILE}"
else
	# Fallback for systems without mkfile: seek to (size - 1 byte) and write
	# a single byte there. The filesystem allocates blocks lazily, so this
	# also produces a sparse file.
	dd if=/dev/zero of="${DEST_FILE}" bs=1g seek="${SIZE_GIB}" count=0 2>/dev/null
fi

echo "Created: ${DEST_FILE} ($(du -h "${DEST_FILE}" | cut -f1) actual, ${SIZE_GIB}G logical)"
