#!/usr/bin/env bash
#
# fetch-kernel.sh — download the vz-bootable arm64 Linux kernel for local
# Morbstack development.
#
# This is now a thin wrapper around scripts/fetch-guest-assets.sh, which
# fetches the kernel (along with the other guest assets) from a pinned
# source URL and verifies it against a recorded sha256 digest chain
# end-to-end: the downloaded archive's own hash, and the hash of the
# vmlinux member extracted from it. See fetch-guest-assets.sh for the full
# pin chain and rationale.
#
# (Earlier versions of this script pulled an unpinned, unverified kernel
# from "latest" GitHub release URLs. That's what this rewrite fixes.)
#
# Usage:
#   scripts/fetch-kernel.sh    # fetch and verify the pinned kernel
#   scripts/fetch-kernel.sh -h # show help
#
# Env:
#   MORBSTACK_HOME   Morbstack runtime root (default ~/.morbstack).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
	cat <<EOF
Usage: $(basename "$0") [-h]

Download and verify the pinned vz-bootable arm64 kernel into:
  \${MORBSTACK_HOME:-\$HOME/.morbstack}/data/kernel/vmlinux

This is a thin wrapper around:
  scripts/fetch-guest-assets.sh --kernel-only

which carries the actual pinned source URL and sha256 digest chain. No
-u/override flag any more — the whole point of pinning is that this script
always fetches and verifies the one recorded-good kernel. If you need a
different kernel, edit the pins in fetch-guest-assets.sh (and re-verify the
new digest chain) rather than passing an ad hoc URL here.

Options:
  -h   Show this help and exit
EOF
}

while getopts "h" opt; do
	case "${opt}" in
	h)
		usage
		exit 0
		;;
	*)
		usage
		exit 1
		;;
	esac
done

exec "${SCRIPT_DIR}/fetch-guest-assets.sh" --kernel-only
