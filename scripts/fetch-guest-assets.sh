#!/usr/bin/env bash
#
# fetch-guest-assets.sh — re-materialize every third-party guest asset a
# fresh Morbstack clone needs, from recorded, pinned provenance:
#
#   1. kernel:   kata-containers 3.28.0 arm64 release tarball, digest-pinned,
#                -> $MORBSTACK_HOME/data/kernel/vmlinux
#   2. docker:   Docker 29.7.1 static aarch64 binaries, archive-hash-pinned,
#                -> dist/guest-bin/
#   4. alpine:   Alpine 3.24.1 aarch64 minirootfs, verified against Alpine's
#                own CDN sha256 sidecar (Alpine doesn't publish permanent
#                versioned URLs the way GitHub Releases / download.docker.com
#                do, so this one is sidecar-verified rather than hash-pinned
#                in this script)
#                -> dist/rootfs/
#   5. fsutils:  Alpine 3.24 aarch64 apks for btrfs-progs + e2fsprogs
#                (guest disk formatting, see the persistence design) and
#                iptables-legacy (guest bridge NAT), plus their full
#                transitive .so dependency closure. Archive-hash-pinned,
#                cached -> dist/apks/ (see dist/apks/PROVENANCE.txt for the
#                full package list and the iptables-legacy vs iptables
#                rationale).
#   6. cli:      the `docker` client binary itself, HOST darwin-arm64,
#                version 29.7.1 (matching the guest's dockerd exactly — zero
#                client/server skew). Docker Inc. does not publish a
#                standalone macOS CLI binary through its own release
#                infrastructure (download.docker.com's static tarballs are
#                Linux-only, and docker/cli's GitHub repo has no Releases at
#                all) — the only widely-used, independently-auditable build
#                of just the client for darwin/arm64 is Homebrew core's
#                `docker` formula (Apache-2.0, same as upstream), whose
#                bottle this script fetches directly from Homebrew's ghcr.io
#                mirror. The bottle URL and its expected sha256 are the same
#                value (ghcr.io blobs are content-addressed by digest), so
#                verification is: download, hash, compare to the pin below —
#                see fetch_docker_cli's comments for the full chain.
#                -> dist/host-bin/docker. This is what turns "install
#                Morbstack" into a complete Docker CLI + engine on a Mac
#                that has never had Docker Desktop or Homebrew's docker
#                installed — see docs/parity.md's zero-config-discovery item.
#   7. compose:  docker/compose v5.3.1 CLI plugin binary for the HOST Mac
#                (darwin-aarch64), verified against its GitHub Release
#                sha256 sidecar -> dist/host-bin/cli-plugins/docker-compose.
#   8. buildx:   docker/buildx v0.36.0 CLI plugin binary for the HOST Mac
#                (darwin-arm64). Unlike compose, buildx's GitHub Release does
#                NOT publish darwin binaries in its plain checksums.txt (only
#                the linux/freebsd/netbsd/openbsd builds are listed there) —
#                the darwin binaries' hashes live in the separate
#                checksums-signed.txt asset instead, which this script
#                fetches and checks the pin against exactly the same way.
#                -> dist/host-bin/cli-plugins/docker-buildx. See #14 in
#                docs/parity.md: the guest's BuildKit is already fully
#                functional; shipping this client-side plugin is what turns
#                that into a working `docker build`/`docker buildx build`
#                out of the box.
#   9. kubectl:  Kubernetes v1.36.2 client for the HOST darwin-arm64. This
#                is a deliberately private, optional helper at
#                dist/host-bin/kubernetes/kubectl. It is not installed into
#                PATH, is not part of the ordinary Docker toolchain, and is
#                not fetched by the default asset set while selected-Pod
#                port-forward remains unimplemented. See docs/k8s.md.
#
#   dist/host-bin/ mirrors exactly how Morbstack.app itself bundles these
#   three (Contents/Resources/host-bin/{docker,cli-plugins/docker-compose,
#   cli-plugins/docker-buildx}) — one discovery function, two possible
#   roots (a repo checkout's dist/host-bin/ or a shipped app's
#   Resources/host-bin/), no path special-casing between them. See
#   MorbstackKit/CliPlugins.swift.
#
#   10. k8s:     k3s v1.36.2+k3s1 arm64 server binary and cri-dockerd v0.4.4
#                arm64, both hash-pinned -> dist/guest-k8s/ (the repository's
#                provenance-bearing cache) and $MORBSTACK_HOME/data/k8s/ (the
#                copy morbstackd actually reads). This is the OPTIONAL
#                Kubernetes payload and it is deliberately NOT baked into the
#                initramfs: Kubernetes is off by default, so those 118 MB
#                would be guest RAM spent on every boot for a feature nobody
#                asked for. `morb k8s enable` streams it into the guest over
#                vsock 2377 instead, onto the persistent ext4 disk. Without
#                this step everything else still works and morbinit reports
#                Kubernetes as "not-installed".
#
# Idempotent: each step is skipped (with a checkmark) if its destination
# already exists and hashes correctly. Safe to re-run any time.
#
# Usage:
#   scripts/fetch-guest-assets.sh                 # fetch everything
#   scripts/fetch-guest-assets.sh --kernel-only    # kernel step only
#   scripts/fetch-guest-assets.sh --docker-only    # docker binaries only
#   scripts/fetch-guest-assets.sh --alpine-only    # alpine rootfs only
#   scripts/fetch-guest-assets.sh --fsutils-only   # btrfs/e2fs/iptables apks only
#   scripts/fetch-guest-assets.sh --host-cli       # all three host Docker CLI files
#   scripts/fetch-guest-assets.sh --cli-only       # host docker CLI binary only
#   scripts/fetch-guest-assets.sh --compose-only   # host docker-compose only
#   scripts/fetch-guest-assets.sh --buildx-only    # host docker-buildx only
#   scripts/fetch-guest-assets.sh --host-kubectl-only # private future helper only
#   scripts/fetch-guest-assets.sh --k8s-only       # k3s + cri-dockerd only
#   scripts/fetch-guest-assets.sh -h               # help
#
# Env:
#   MORBSTACK_HOME   Morbstack runtime root (default ~/.morbstack).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MORBSTACK_HOME="${MORBSTACK_HOME:-${HOME}/.morbstack}"

# ---------------------------------------------------------------------------
# Pinned provenance (see dist/rootfs/PROVENANCE.txt, dist/guest-bin/PROVENANCE.txt,
# and $MORBSTACK_HOME/data/kernel/PROVENANCE.txt for the full derivation of
# each of these).
# ---------------------------------------------------------------------------

# --- kernel: kata-containers 3.28.0 arm64 release ---
KERNEL_RELEASE_URL="https://github.com/kata-containers/kata-containers/releases/download/3.28.0/kata-static-3.28.0-arm64.tar.zst"
KERNEL_ARCHIVE_SHA256="f63d54507d1f18635d94475077e4c2330de4d8e05cedf25f7c38f063b0e66a91"
KERNEL_MEMBER_PATH="opt/kata/share/kata-containers/vmlinux-6.18.15-186"
KERNEL_FINAL_SHA256="2fe4a58d2885d623bcb4d705900ac8c1d4f02371152da8126b3b00c8c47fc3a1"

# --- docker: 29.7.1 static aarch64 ---
DOCKER_RELEASE_URL="https://download.docker.com/linux/static/stable/aarch64/docker-29.7.1.tgz"
DOCKER_ARCHIVE_SHA256="4eb4d1b21131897ed3990aac31039161bf4bdd07fcfb733e996010319ff4e069"
DOCKER_BIN_NAMES="containerd containerd-shim-runc-v2 ctr docker docker-init docker-proxy dockerd runc"

# --- alpine: 3.24.1 aarch64 minirootfs ---
ALPINE_RELEASE_URL="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/alpine-minirootfs-3.24.1-aarch64.tar.gz"
ALPINE_SHA256_SIDECAR_URL="${ALPINE_RELEASE_URL}.sha256"

# --- fsutils: Alpine v3.24 aarch64 apks (btrfs-progs + e2fsprogs +
# iptables-legacy and their full transitive so:-dependency closure). See
# dist/apks/PROVENANCE.txt for how this list was derived and why
# iptables-legacy (not the default nft-backed iptables apk) was chosen.
# "musl" and "zlib" are deliberately excluded: dist/rootfs/alpine-minirootfs.tar.gz
# already ships matching versions of both.
#
# The plain "iptables" apk is in the list too, but ONLY as the carrier for
# /usr/lib/xtables/libxt_*.so — the match/target extension modules that
# libxtables dlopen()s while parsing a rule. Alpine ships those in the main
# package and nowhere else, and they are frontend-agnostic (their whole
# DT_NEEDED closure is libc.musl + libxtables.so.12), so the legacy-not-nft
# decision still holds: scripts/mkinitramfs.sh stages that one directory out
# of this apk and drops its usr/sbin nft binaries on the floor. Without it,
# dockerd dies on its first NAT rule with "Couldn't load match `addrtype'".
FSUTILS_APK_REPO_URL="https://dl-cdn.alpinelinux.org/alpine/v3.24/main/aarch64"
# name:version-release:sha256, one per line (name-version-release.apk under
# FSUTILS_APK_REPO_URL).
FSUTILS_APKS="
btrfs-progs:6.17.1-r1:56af3270c687b8e819566ff1c0f88c9e24cb4666d57c703d63d4283cb90fea88
e2fsprogs:1.47.4-r0:52fd401e79ce6b0ff7648733ba4de3135083cd0132543534e72106e7ea767a00
e2fsprogs-libs:1.47.4-r0:52124971ae397d599aadd79263fcd68fc9e271922ccf8185b124f35fe24c60c8
eudev-libs:3.2.14-r6:330022dcf23de371d8df9b08f9bf9c9e98ced062b7352b518ee977dcaf977956
iptables:1.8.13-r0:9d22aef2e74346e9d537f6dc964786ab14b35580e3ccc0e4001dc3a725e8fe77
iptables-legacy:1.8.13-r0:9fa392fcd54aa737c8d998a8bbec39c376a58f6587755726532ac6075f557409
libblkid:2.42.3-r1:9d0f24976c575c53c12526b6e078edf34c980c153bc8e5f1c1053cbece5b8cfa
libcom_err:1.47.4-r0:a75b5955ff57046e33fc2842cfe466dc77d8e68305d5c86c6646b38a069490a2
libeconf:0.8.3-r0:cf0899d49ded0a6891e3cdf1b37887f2ecd77293afe1d8f3cb8937763c83f183
libip4tc:1.8.13-r0:09d044b760836e8b26056a91e8794349fedf6c7ddeeed4e95640e4fe67cb9d66
libip6tc:1.8.13-r0:c5f41026c9ed74b1575d203ba9773cfebffd790ea84ef16ae9a4c030cb56ba94
libuuid:2.42.3-r1:9ce20c7ffe2ccaa7c321893c10564abbca13c3f2edb82f60a35f1f68e004f86c
libxtables:1.8.13-r0:7535f18d9c7229178bc5e3809e5fea171033e33dfa054d88846512e1f25eefa8
lzo:2.10-r5:a4d2dc5c6174527784244aff061c330f5c66f28d45fa8588c8076d83f0d2822c
zstd-libs:1.5.7-r2:2bb5136c89f5b0bbe1554c8915a3b520d5aa63ae2a51d4d821eb81698db5a818
"

# --- k8s: k3s + cri-dockerd, GUEST aarch64 ---
#
# Two binaries, because the two jobs are genuinely separate and morbinit
# supervises them separately (SIGTERM ladder and restart backoff each):
#
#   k3s          the whole Kubernetes control plane and kubelet in one static
#                Go binary. Pointed at an external CRI, so its embedded
#                containerd is never started — the cluster runs on the same
#                dockerd every `docker build` writes to, which is the entire
#                ergonomic point (no registry push, no `kind load`).
#   cri-dockerd  the CRI shim that translates kubelet's CRI calls into Docker
#                Engine API calls. Upstream's supported replacement for the
#                dockershim that Kubernetes 1.24 removed.
#
# k3s bundles a copy of cri-dockerd internally (`k3s server --docker`), and
# using that would save ~49 MB. It is deliberately not used: an embedded shim
# is a child of the k3s process, so it cannot be restarted, backed off, or
# reported on independently, and a cri-dockerd that wedges takes the whole
# control plane with it. A separate binary costs bytes and buys supervision.
#
# k3s ships a `sha256sum-arm64.txt` sidecar covering every release asset; the
# k3s pin below is the `k3s-arm64` line from
# https://github.com/k3s-io/k3s/releases/download/v1.36.2%2Bk3s1/sha256sum-arm64.txt
# and is re-verified against that sidecar on every fetch (same belt-and-braces
# treatment as docker-compose above). cri-dockerd publishes no sidecar, so its
# archive hash is pinned here outright, plus the hash of the single binary
# extracted from it — an archive can verify while its member is not the file
# a previous run installed.
K3S_VERSION="v1.36.2+k3s1"
# The `+` has to be percent-encoded in the release URL path.
K3S_RELEASE_URL="https://github.com/k3s-io/k3s/releases/download/v1.36.2%2Bk3s1/k3s-arm64"
K3S_SHA256_SIDECAR_URL="https://github.com/k3s-io/k3s/releases/download/v1.36.2%2Bk3s1/sha256sum-arm64.txt"
K3S_SHA256="1dc5fc17f15c28fa0a3f011cee28ad613f918c3d967a426e5a05d43ddb239817"

CRI_DOCKERD_VERSION="v0.4.4"
CRI_DOCKERD_RELEASE_URL="https://github.com/Mirantis/cri-dockerd/releases/download/v0.4.4/cri-dockerd-0.4.4.arm64.tgz"
CRI_DOCKERD_ARCHIVE_SHA256="4f96b4e9b7fcb1c90f78470325c2197a67fa28c0e0c901509437b791f5588a37"
CRI_DOCKERD_MEMBER_PATH="cri-dockerd/cri-dockerd"
CRI_DOCKERD_SHA256="d52b7a79376560d7dcb5490e16dcb78578bd0f040c1e70dec220824fae74ae7e"

# --- cli: the docker client itself, HOST darwin-arm64, via Homebrew core's
# bottle mirror on ghcr.io (see the header comment for why: Docker Inc.
# publishes no standalone macOS CLI binary of its own). The bottle version
# (29.7.1) matches dist/guest-bin/docker's engine version exactly.
#
# ghcr.io blobs are addressed by their own sha256 digest, so the "sidecar"
# here is the digest embedded in the URL itself, cross-checked against
# Homebrew's formula API (`https://formulae.brew.sh/api/formula/docker.json`,
# `.bottle.stable.files.arm64_tahoe.sha256`) at pin time — both agreed.
# `CLI_BOTTLE_SHA256` is what's actually checked at fetch time; the URL
# containing the same value is corroborating, not load-bearing on its own.
CLI_VERSION="29.7.1"
CLI_BOTTLE_SHA256="1bc0f3ce68c682ff23050b964f9a721b15fa1524ae29129c02c96d3966e98dcd"
# Hash of the exact `docker/${CLI_VERSION}/bin/docker` member shipped in the
# bottle. The bottle hash proves the archive; this pin proves the extracted
# executable that will enter `dist/host-bin` and, eventually, a signed app.
CLI_SHA256="49d98ab806e8678cd6341b09dad6389e5bcd8a46513de7651053bee3d8366e8d"
CLI_BOTTLE_URL="https://ghcr.io/v2/homebrew/core/docker/blobs/sha256:${CLI_BOTTLE_SHA256}"
# Path inside the bottle's own tar layout (Cellar-style:
# <formula>/<version>/bin/<binary>) to the one file this script keeps.
CLI_BOTTLE_MEMBER="docker/${CLI_VERSION}/bin/docker"

# --- compose: docker/compose v5.3.1 CLI plugin, HOST darwin-aarch64 ---
COMPOSE_RELEASE_URL="https://github.com/docker/compose/releases/download/v5.3.1/docker-compose-darwin-aarch64"
COMPOSE_SHA256_SIDECAR_URL="${COMPOSE_RELEASE_URL}.sha256"
COMPOSE_VERSION="v5.3.1"
COMPOSE_SHA256="32691ba1196d819fa68cbdc0aad9a5569e730a35ae40c6fdd8458110ecd69488"

# --- buildx: docker/buildx v0.36.0 CLI plugin, HOST darwin-arm64 ---
#
# docker/buildx's plain checksums.txt release asset only lists linux/free|
# net|openbsd builds; the darwin (and windows) hashes live in the separate
# checksums-signed.txt asset for that same release. Both this pin and the
# sidecar URL below point at that file. Independently cross-checked at
# pin time against the GitHub Releases API's own per-asset "digest" field
# for buildx-v0.36.0.darwin-arm64, which agreed exactly.
BUILDX_VERSION="v0.36.0"
BUILDX_RELEASE_URL="https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.darwin-arm64"
BUILDX_SHA256_SIDECAR_URL="https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/checksums-signed.txt"
BUILDX_SHA256="82c6a3d9df37790c5bdb0d7ca88986d1d17622fc2b88ebe34b275c6c47acd7a6"

# --- kubectl: Kubernetes client, HOST darwin-arm64 ---
#
# This is intentionally kept separate from the Docker CLI and its plugins. A
# future selected-Pod port-forward may execute only this absolute, hash-verified
# app-bundled path with a Morbstack-private ephemeral credential. It must never
# substitute a user-installed client or configuration. The official release page
# publishes both this exact binary and the one-line sha256 sidecar.
KUBECTL_VERSION="v1.36.2"
KUBECTL_RELEASE_URL="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/darwin/arm64/kubectl"
KUBECTL_SHA256_SIDECAR_URL="${KUBECTL_RELEASE_URL}.sha256"
KUBECTL_SHA256="4408c85c83fd3a31adaa555bdf3c7a6c81f74b19449a9060ba31ab91926f023d"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

usage() {
	cat <<EOF
Usage: $(basename "$0") [--kernel-only|--docker-only|--alpine-only|--fsutils-only|--host-cli|--cli-only|--compose-only|--buildx-only|--host-kubectl-only|--k8s-only] [-h]

Fetch and verify all pinned third-party guest assets:
  kernel   -> ${MORBSTACK_HOME}/data/kernel/vmlinux
  docker   -> ${REPO_ROOT}/dist/guest-bin/
  alpine   -> ${REPO_ROOT}/dist/rootfs/
  fsutils  -> ${REPO_ROOT}/dist/apks/
  cli      -> ${REPO_ROOT}/dist/host-bin/docker
  compose  -> ${REPO_ROOT}/dist/host-bin/cli-plugins/docker-compose
  buildx   -> ${REPO_ROOT}/dist/host-bin/cli-plugins/docker-buildx
  kubectl  -> ${REPO_ROOT}/dist/host-bin/kubernetes/kubectl (optional; not fetched by default)
  k8s      -> ${REPO_ROOT}/dist/guest-k8s/  and  ${MORBSTACK_HOME}/data/k8s/

Options:
  --kernel-only    Only fetch/verify the kernel
  --docker-only    Only fetch/verify the Docker engine binaries
  --alpine-only    Only fetch/verify the Alpine minirootfs
  --fsutils-only   Only fetch/verify the btrfs-progs/e2fsprogs/iptables-legacy apks
  --host-cli       Fetch/verify docker, docker-compose and docker-buildx for the host Mac
  --cli-only       Only fetch/verify the host docker CLI binary
  --compose-only   Only fetch/verify the host docker-compose CLI plugin
  --buildx-only    Only fetch/verify the host docker-buildx CLI plugin
  --host-kubectl-only
                    Only fetch/verify the private host kubectl helper for a future
                    selected-Pod port-forward; it does not enable that feature
  --k8s-only       Only fetch/verify the k3s + cri-dockerd Kubernetes payload
  -h               Show this help and exit
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
# Step: kernel
# ---------------------------------------------------------------------------

fetch_kernel() {
	echo "== kernel (kata-containers 3.28.0, vmlinux-6.18.15-186) =="

	local dest_dir="${MORBSTACK_HOME}/data/kernel"
	local dest_file="${dest_dir}/vmlinux"
	local prov_file="${dest_dir}/PROVENANCE.txt"

	if [ -f "${dest_file}" ]; then
		local have_sha
		have_sha="$(sha256_of "${dest_file}")"
		if [ "${have_sha}" = "${KERNEL_FINAL_SHA256}" ]; then
			check "vmlinux already present and verified: ${dest_file}"
			return 0
		fi
		echo "  existing ${dest_file} has sha256 ${have_sha}, expected ${KERNEL_FINAL_SHA256}; re-fetching" >&2
	fi

	require_cmd curl

	mkdir -p "${dest_dir}"

	local tmp_archive
	tmp_archive="$(mktemp "${TMPDIR:-/tmp}/morbstack-kernel-archive.XXXXXX")"
	local tmp_extract
	tmp_extract="$(mktemp -d "${TMPDIR:-/tmp}/morbstack-kernel-extract.XXXXXX")"
	trap 'rm -f "${tmp_archive}"; rm -rf "${tmp_extract}"' RETURN

	info "downloading ${KERNEL_RELEASE_URL}"
	curl --fail --location --show-error --progress-bar --output "${tmp_archive}" "${KERNEL_RELEASE_URL}" ||
		fail "failed to download kernel archive"

	local archive_sha
	archive_sha="$(sha256_of "${tmp_archive}")"
	[ "${archive_sha}" = "${KERNEL_ARCHIVE_SHA256}" ] ||
		fail "kernel archive sha256 mismatch: got ${archive_sha}, expected ${KERNEL_ARCHIVE_SHA256} (possible corruption or upstream tamper)"
	check "archive sha256 verified"

	# Prefer tar's own native .zst support (libarchive/bsdtar and modern GNU
	# tar both auto-detect zstd from the archive's magic bytes) and extract
	# just the one member we need directly. Piping through an external
	# zstd/unzstd via --use-compress-program is deliberately NOT used for
	# single-member extraction: tar stops reading as soon as it has the
	# member it wants, which closes the read end of the pipe while the
	# external decompressor is still writing the rest of a ~600MB archive —
	# on this Mac's bsdtar that reliably produces a SIGPIPE / "Broken pipe"
	# failure from the child zstd process.
	if tar -xf "${tmp_archive}" -C "${tmp_extract}" "${KERNEL_MEMBER_PATH}" 2>/dev/null; then
		:
	elif command -v zstd >/dev/null 2>&1 || command -v unzstd >/dev/null 2>&1; then
		# Fallback for a tar without built-in zstd support: decompress the
		# whole archive to a plain .tar first (no pipe involved, so no
		# early-close/SIGPIPE risk), then extract the single member from
		# that regular file.
		local tmp_plain_tar="${tmp_extract}.plain.tar"
		if command -v unzstd >/dev/null 2>&1; then
			unzstd -f -o "${tmp_plain_tar}" "${tmp_archive}"
		else
			zstd -d -f -o "${tmp_plain_tar}" "${tmp_archive}"
		fi
		tar -xf "${tmp_plain_tar}" -C "${tmp_extract}" "${KERNEL_MEMBER_PATH}"
		rm -f "${tmp_plain_tar}"
	else
		fail "no zstd support found (need a tar built with zstd support, or 'zstd'/'unzstd' on PATH) to extract the kata kernel archive"
	fi

	local extracted="${tmp_extract}/${KERNEL_MEMBER_PATH}"
	[ -f "${extracted}" ] || fail "expected member ${KERNEL_MEMBER_PATH} not found in kernel archive"

	local final_sha
	final_sha="$(sha256_of "${extracted}")"
	[ "${final_sha}" = "${KERNEL_FINAL_SHA256}" ] ||
		fail "extracted vmlinux sha256 mismatch: got ${final_sha}, expected ${KERNEL_FINAL_SHA256}"

	cp "${extracted}" "${dest_file}"
	chmod 644 "${dest_file}"
	check "installed and verified: ${dest_file}"

	cat >"${prov_file}" <<EOF
Morbstack guest kernel provenance
==================================

File: vmlinux
Source: ${KERNEL_RELEASE_URL}
Archive sha256: ${KERNEL_ARCHIVE_SHA256}
Member: ${KERNEL_MEMBER_PATH}
Final sha256: ${KERNEL_FINAL_SHA256}

Fetched by scripts/fetch-guest-assets.sh (--kernel-only). See that script
for the full pin chain / rationale for this particular kata-containers
release being used as the vz-bootable arm64 kernel.
EOF

	trap - RETURN
	rm -f "${tmp_archive}"
	rm -rf "${tmp_extract}"
}

# ---------------------------------------------------------------------------
# Step: docker static binaries
# ---------------------------------------------------------------------------

fetch_docker() {
	echo "== docker (29.7.1 static aarch64) =="

	local dest_dir="${REPO_ROOT}/dist/guest-bin"
	local all_present=1
	local name
	for name in ${DOCKER_BIN_NAMES}; do
		[ -x "${dest_dir}/${name}" ] || all_present=0
	done

	if [ "${all_present}" -eq 1 ]; then
		check "all 8 docker binaries already present: ${dest_dir}"
		return 0
	fi

	require_cmd curl
	require_cmd tar

	mkdir -p "${dest_dir}"

	local tmp_archive
	tmp_archive="$(mktemp "${TMPDIR:-/tmp}/morbstack-docker-archive.XXXXXX")"
	local tmp_extract
	tmp_extract="$(mktemp -d "${TMPDIR:-/tmp}/morbstack-docker-extract.XXXXXX")"
	trap 'rm -f "${tmp_archive}"; rm -rf "${tmp_extract}"' RETURN

	info "downloading ${DOCKER_RELEASE_URL}"
	curl --fail --location --show-error --progress-bar --output "${tmp_archive}" "${DOCKER_RELEASE_URL}" ||
		fail "failed to download docker archive"

	local archive_sha
	archive_sha="$(sha256_of "${tmp_archive}")"
	[ "${archive_sha}" = "${DOCKER_ARCHIVE_SHA256}" ] ||
		fail "docker archive sha256 mismatch: got ${archive_sha}, expected ${DOCKER_ARCHIVE_SHA256} (possible corruption or upstream tamper)"
	check "archive sha256 verified"

	tar xzf "${tmp_archive}" -C "${tmp_extract}"
	[ -d "${tmp_extract}/docker" ] || fail "expected docker/ directory not found inside archive"

	for name in ${DOCKER_BIN_NAMES}; do
		[ -f "${tmp_extract}/docker/${name}" ] || fail "expected binary docker/${name} not found inside archive"
		install -m 0755 "${tmp_extract}/docker/${name}" "${dest_dir}/${name}"
	done
	check "installed 8 binaries: ${dest_dir}"

	trap - RETURN
	rm -f "${tmp_archive}"
	rm -rf "${tmp_extract}"
}

# ---------------------------------------------------------------------------
# Step: alpine minirootfs
# ---------------------------------------------------------------------------

fetch_alpine() {
	echo "== alpine (3.24.1 aarch64 minirootfs) =="

	local dest_dir="${REPO_ROOT}/dist/rootfs"
	local dest_file="${dest_dir}/alpine-minirootfs.tar.gz"

	require_cmd curl

	# Fetch the sidecar checksum first regardless of whether the tarball is
	# already present, since it's tiny and lets us confirm a cached tarball
	# is still trustworthy without re-downloading 4MB every run.
	local sidecar_sha
	sidecar_sha="$(curl --fail --location --show-error --silent "${ALPINE_SHA256_SIDECAR_URL}" | awk '{print $1}')"
	[ -n "${sidecar_sha}" ] || fail "failed to fetch/parse Alpine sha256 sidecar from ${ALPINE_SHA256_SIDECAR_URL}"

	if [ -f "${dest_file}" ]; then
		local have_sha
		have_sha="$(sha256_of "${dest_file}")"
		if [ "${have_sha}" = "${sidecar_sha}" ]; then
			check "alpine-minirootfs.tar.gz already present and verified: ${dest_file}"
			return 0
		fi
		echo "  existing ${dest_file} has sha256 ${have_sha}, sidecar says ${sidecar_sha}; re-fetching" >&2
	fi

	mkdir -p "${dest_dir}"

	local tmp_file
	tmp_file="$(mktemp "${TMPDIR:-/tmp}/morbstack-alpine.XXXXXX")"
	trap 'rm -f "${tmp_file}"' RETURN

	info "downloading ${ALPINE_RELEASE_URL}"
	curl --fail --location --show-error --progress-bar --output "${tmp_file}" "${ALPINE_RELEASE_URL}" ||
		fail "failed to download alpine minirootfs"

	local got_sha
	got_sha="$(sha256_of "${tmp_file}")"
	[ "${got_sha}" = "${sidecar_sha}" ] ||
		fail "alpine minirootfs sha256 mismatch: got ${got_sha}, sidecar says ${sidecar_sha} (possible corruption or upstream tamper)"
	check "sha256 verified against Alpine CDN sidecar"

	mv "${tmp_file}" "${dest_file}"
	chmod 644 "${dest_file}"
	check "installed: ${dest_file}"

	cat >"${dest_dir}/PROVENANCE.txt" <<EOF
Morbstack base rootfs provenance
==================================

File: alpine-minirootfs.tar.gz
Source: ${ALPINE_RELEASE_URL}
sha256: ${sidecar_sha}

Verification: sha256 fetched fresh from Alpine's own CDN sidecar
(${ALPINE_SHA256_SIDECAR_URL}) and matched the locally computed hash.
Alpine's "latest-stable" directory doesn't offer a permanently pinned
version URL the way GitHub Releases / download.docker.com do, so this
asset is sidecar-verified on every fetch rather than hash-pinned in
scripts/fetch-guest-assets.sh itself.

Fetched by scripts/fetch-guest-assets.sh (--alpine-only).
EOF

	trap - RETURN
	rm -f "${tmp_file}"
}

# ---------------------------------------------------------------------------
# Step: fsutils apks (btrfs-progs, e2fsprogs, iptables-legacy + deps)
# ---------------------------------------------------------------------------

fetch_fsutils() {
	echo "== fsutils (Alpine v3.24 aarch64 apks: btrfs-progs, e2fsprogs, iptables-legacy) =="

	local dest_dir="${REPO_ROOT}/dist/apks"
	require_cmd curl

	mkdir -p "${dest_dir}"

	local entry name ver sha fname dest all_present
	all_present=1
	for entry in ${FSUTILS_APKS}; do
		name="$(echo "${entry}" | cut -d: -f1)"
		ver="$(echo "${entry}" | cut -d: -f2)"
		fname="${name}-${ver}.apk"
		[ -f "${dest_dir}/${fname}" ] || all_present=0
	done

	if [ "${all_present}" -eq 1 ]; then
		# Still verify hashes even when "present" — cheap (apks are small)
		# and catches local corruption/tampering, matching the checkmark
		# semantics of the other steps.
		local mismatch=0
		for entry in ${FSUTILS_APKS}; do
			name="$(echo "${entry}" | cut -d: -f1)"
			ver="$(echo "${entry}" | cut -d: -f2)"
			sha="$(echo "${entry}" | cut -d: -f3)"
			fname="${name}-${ver}.apk"
			local have_sha
			have_sha="$(sha256_of "${dest_dir}/${fname}")"
			if [ "${have_sha}" != "${sha}" ]; then
				echo "  existing ${fname} has sha256 ${have_sha}, expected ${sha}; re-fetching" >&2
				mismatch=1
			fi
		done
		if [ "${mismatch}" -eq 0 ]; then
			check "all $(echo "${FSUTILS_APKS}" | grep -c ':') apks already present and verified: ${dest_dir}"
			return 0
		fi
	fi

	for entry in ${FSUTILS_APKS}; do
		name="$(echo "${entry}" | cut -d: -f1)"
		ver="$(echo "${entry}" | cut -d: -f2)"
		sha="$(echo "${entry}" | cut -d: -f3)"
		fname="${name}-${ver}.apk"
		dest="${dest_dir}/${fname}"

		if [ -f "${dest}" ]; then
			local have_sha
			have_sha="$(sha256_of "${dest}")"
			[ "${have_sha}" = "${sha}" ] && continue
		fi

		info "downloading ${fname}"
		local tmp
		tmp="$(mktemp "${TMPDIR:-/tmp}/morbstack-apk.XXXXXX")"
		curl --fail --location --show-error --silent --output "${tmp}" "${FSUTILS_APK_REPO_URL}/${fname}" ||
			fail "failed to download ${fname}"

		local got_sha
		got_sha="$(sha256_of "${tmp}")"
		if [ "${got_sha}" != "${sha}" ]; then
			rm -f "${tmp}"
			fail "${fname} sha256 mismatch: got ${got_sha}, expected ${sha} (possible corruption or upstream tamper)"
		fi

		mv "${tmp}" "${dest}"
		chmod 644 "${dest}"
	done
	check "downloaded and verified $(echo "${FSUTILS_APKS}" | grep -c ':') apks: ${dest_dir}"
	info "see ${dest_dir}/PROVENANCE.txt for the package list and iptables-legacy rationale"
}

# ---------------------------------------------------------------------------
# Step: docker CLI client itself (HOST darwin-arm64), via Homebrew's bottle
# mirror on ghcr.io — see the header comment and the CLI_* variables above
# for why there is no official Docker Inc. release to pull this from.
# ---------------------------------------------------------------------------

fetch_docker_cli() {
	echo "== cli (docker client ${CLI_VERSION}, HOST darwin-arm64, via Homebrew's ghcr.io bottle mirror) =="

	local dest_dir="${REPO_ROOT}/dist/host-bin"
	local dest_file="${dest_dir}/docker"

	require_cmd curl
	require_cmd tar

	if [ -x "${dest_file}" ]; then
		local have_sha
		have_sha="$(sha256_of "${dest_file}")"
		# The extracted binary's own hash is not the bottle archive's hash
		# (the archive also contains completions, man pages, the formula's
		# own LICENSE/NOTICE/sbom.spdx.json). Verify that exact member as
		# well as its reported version so a same-version replacement cannot
		# silently become the candidate for a signed release.
		if [ "${have_sha}" = "${CLI_SHA256}" ] \
			&& "${dest_file}" --version 2>/dev/null | grep -q "version ${CLI_VERSION}"; then
			check "docker CLI already present and verified: ${dest_file} ($(${dest_file} --version))"
			return 0
		fi
		echo "  existing ${dest_file} did not match the pinned hash and version; re-fetching" >&2
	fi

	mkdir -p "${dest_dir}"

	local tmp_bottle
	tmp_bottle="$(mktemp "${TMPDIR:-/tmp}/morbstack-docker-cli-bottle.XXXXXX")"
	local tmp_extract
	tmp_extract="$(mktemp -d "${TMPDIR:-/tmp}/morbstack-docker-cli-extract.XXXXXX")"
	trap 'rm -f "${tmp_bottle}"; rm -rf "${tmp_extract}"' RETURN

	info "downloading ${CLI_BOTTLE_URL}"
	curl --fail --location --show-error --progress-bar \
		-H "Authorization: Bearer QQ==" \
		--output "${tmp_bottle}" "${CLI_BOTTLE_URL}" ||
		fail "failed to download the docker CLI bottle"

	local got_sha
	got_sha="$(sha256_of "${tmp_bottle}")"
	[ "${got_sha}" = "${CLI_BOTTLE_SHA256}" ] ||
		fail "docker CLI bottle sha256 mismatch: got ${got_sha}, expected ${CLI_BOTTLE_SHA256} (possible corruption or upstream tamper)"
	check "sha256 verified against the pin (self-describing: the ghcr.io blob URL and this hash are the same value)"

	tar xzf "${tmp_bottle}" -C "${tmp_extract}" "${CLI_BOTTLE_MEMBER}" ||
		fail "expected member ${CLI_BOTTLE_MEMBER} not found inside the docker CLI bottle"

	local extracted="${tmp_extract}/${CLI_BOTTLE_MEMBER}"
	[ -f "${extracted}" ] || fail "expected member ${CLI_BOTTLE_MEMBER} not found inside the docker CLI bottle"
	local member_sha
	member_sha="$(sha256_of "${extracted}")"
	[ "${member_sha}" = "${CLI_SHA256}" ] ||
		fail "docker CLI member sha256 mismatch: got ${member_sha}, expected ${CLI_SHA256}"
	check "extracted docker CLI sha256 verified against the pin"

	mv "${extracted}" "${dest_file}"
	chmod 755 "${dest_file}"
	local got_version
	got_version="$("${dest_file}" --version 2>&1)"
	case "${got_version}" in
	*"version ${CLI_VERSION}"*) ;;
	*) fail "installed docker CLI reports unexpected version: ${got_version} (expected ${CLI_VERSION})" ;;
	esac
	check "installed and verified: ${dest_file} (${got_version})"

	trap - RETURN
	rm -f "${tmp_bottle}"
	rm -rf "${tmp_extract}"
}

# ---------------------------------------------------------------------------
# Step: docker compose CLI plugin (HOST darwin-aarch64)
# ---------------------------------------------------------------------------

fetch_compose() {
	echo "== compose (docker/compose ${COMPOSE_VERSION}, HOST darwin-aarch64) =="

	local dest_dir="${REPO_ROOT}/dist/host-bin/cli-plugins"
	local dest_file="${dest_dir}/docker-compose"

	require_cmd curl

	if [ -x "${dest_file}" ]; then
		local have_sha
		have_sha="$(sha256_of "${dest_file}")"
		if [ "${have_sha}" = "${COMPOSE_SHA256}" ]; then
			check "docker-compose already present and verified: ${dest_file}"
			return 0
		fi
		echo "  existing ${dest_file} has sha256 ${have_sha}, expected ${COMPOSE_SHA256}; re-fetching" >&2
	fi

	mkdir -p "${dest_dir}"

	local tmp
	tmp="$(mktemp "${TMPDIR:-/tmp}/morbstack-compose.XXXXXX")"
	trap 'rm -f "${tmp}"' RETURN

	info "downloading ${COMPOSE_RELEASE_URL}"
	curl --fail --location --show-error --progress-bar --output "${tmp}" "${COMPOSE_RELEASE_URL}" ||
		fail "failed to download docker-compose"

	info "fetching sha256 sidecar ${COMPOSE_SHA256_SIDECAR_URL}"
	local sidecar_sha
	sidecar_sha="$(curl --fail --location --show-error --silent "${COMPOSE_SHA256_SIDECAR_URL}" | awk '{print $1}')"
	[ -n "${sidecar_sha}" ] || fail "failed to fetch/parse docker-compose sha256 sidecar"
	[ "${sidecar_sha}" = "${COMPOSE_SHA256}" ] ||
		fail "docker-compose sha256 sidecar (${sidecar_sha}) does not match the pin in this script (${COMPOSE_SHA256}); upstream release may have changed"

	local got_sha
	got_sha="$(sha256_of "${tmp}")"
	[ "${got_sha}" = "${COMPOSE_SHA256}" ] ||
		fail "docker-compose sha256 mismatch: got ${got_sha}, expected ${COMPOSE_SHA256} (possible corruption or upstream tamper)"
	check "sha256 verified against pin and GitHub Release sidecar"

	mv "${tmp}" "${dest_file}"
	chmod 755 "${dest_file}"
	check "installed: ${dest_file}"

	trap - RETURN
	rm -f "${tmp}"
}

# ---------------------------------------------------------------------------
# Step: docker buildx CLI plugin (HOST darwin-arm64)
# ---------------------------------------------------------------------------

fetch_buildx() {
	echo "== buildx (docker/buildx ${BUILDX_VERSION}, HOST darwin-arm64) =="

	local dest_dir="${REPO_ROOT}/dist/host-bin/cli-plugins"
	local dest_file="${dest_dir}/docker-buildx"

	require_cmd curl

	if [ -x "${dest_file}" ]; then
		local have_sha
		have_sha="$(sha256_of "${dest_file}")"
		if [ "${have_sha}" = "${BUILDX_SHA256}" ]; then
			check "docker-buildx already present and verified: ${dest_file}"
			return 0
		fi
		echo "  existing ${dest_file} has sha256 ${have_sha}, expected ${BUILDX_SHA256}; re-fetching" >&2
	fi

	mkdir -p "${dest_dir}"

	local tmp
	tmp="$(mktemp "${TMPDIR:-/tmp}/morbstack-buildx.XXXXXX")"
	trap 'rm -f "${tmp}"' RETURN

	info "downloading ${BUILDX_RELEASE_URL}"
	curl --fail --location --show-error --progress-bar --output "${tmp}" "${BUILDX_RELEASE_URL}" ||
		fail "failed to download docker-buildx"

	# See the BUILDX_SHA256_SIDECAR_URL comment above: darwin hashes are only
	# in checksums-signed.txt, not the plain checksums.txt this release also
	# publishes, so the sidecar line is matched by exact asset filename
	# rather than assumed to be the only line in the file.
	info "fetching sha256 sidecar ${BUILDX_SHA256_SIDECAR_URL}"
	local sidecar_sha
	sidecar_sha="$(curl --fail --location --show-error --silent "${BUILDX_SHA256_SIDECAR_URL}" |
		awk -v want="buildx-${BUILDX_VERSION}.darwin-arm64" '$2 == "*"want || $2 == want { print $1 }')"
	[ -n "${sidecar_sha}" ] || fail "failed to fetch/parse the docker-buildx sha256 sidecar (no darwin-arm64 line)"
	[ "${sidecar_sha}" = "${BUILDX_SHA256}" ] ||
		fail "docker-buildx sha256 sidecar (${sidecar_sha}) does not match the pin in this script (${BUILDX_SHA256}); upstream release may have changed"

	local got_sha
	got_sha="$(sha256_of "${tmp}")"
	[ "${got_sha}" = "${BUILDX_SHA256}" ] ||
		fail "docker-buildx sha256 mismatch: got ${got_sha}, expected ${BUILDX_SHA256} (possible corruption or upstream tamper)"
	check "sha256 verified against pin and GitHub Release sidecar"

	mv "${tmp}" "${dest_file}"
	chmod 755 "${dest_file}"
	check "installed: ${dest_file}"

	trap - RETURN
	rm -f "${tmp}"
}

# ---------------------------------------------------------------------------
# Step: kubectl (HOST darwin-arm64, private future port-forward helper)
# ---------------------------------------------------------------------------

fetch_kubectl() {
	echo "== kubectl (${KUBECTL_VERSION}, HOST darwin-arm64, optional private helper) =="

	local dest_dir="${REPO_ROOT}/dist/host-bin/kubernetes"
	local dest_file="${dest_dir}/kubectl"

	require_cmd curl

	if [ -x "${dest_file}" ]; then
		local have_sha
		have_sha="$(sha256_of "${dest_file}")"
		if [ "${have_sha}" = "${KUBECTL_SHA256}" ]; then
			check "private kubectl already present and verified: ${dest_file}"
			return 0
		fi
		echo "  existing kubectl has sha256 ${have_sha}, expected ${KUBECTL_SHA256}; re-fetching" >&2
	fi

	mkdir -p "${dest_dir}"
	local tmp
	tmp="$(mktemp "${TMPDIR:-/tmp}/morbstack-kubectl.XXXXXX")"
	trap 'rm -f "${tmp}"' RETURN

	info "fetching sha256 sidecar ${KUBECTL_SHA256_SIDECAR_URL}"
	local sidecar_sha
	sidecar_sha="$(curl --fail --location --show-error --silent "${KUBECTL_SHA256_SIDECAR_URL}" | tr -d '[:space:]')"
	[ "${sidecar_sha}" = "${KUBECTL_SHA256}" ] ||
		fail "kubectl sha256 sidecar (${sidecar_sha}) does not match the pin in this script (${KUBECTL_SHA256}); upstream release may have changed"

	info "downloading ${KUBECTL_RELEASE_URL}"
	curl --fail --location --show-error --progress-bar --output "${tmp}" "${KUBECTL_RELEASE_URL}" ||
		fail "failed to download kubectl"

	local got_sha
	got_sha="$(sha256_of "${tmp}")"
	[ "${got_sha}" = "${KUBECTL_SHA256}" ] ||
		fail "kubectl sha256 mismatch: got ${got_sha}, expected ${KUBECTL_SHA256} (possible corruption or upstream tamper)"

	install -m 0755 "${tmp}" "${dest_file}"
	check "installed and verified private helper: ${dest_file}"
	info "this only stages a future helper; it does not enable or expose Kubernetes port-forwarding"

	trap - RETURN
	rm -f "${tmp}"
}

# ---------------------------------------------------------------------------
# Step: k8s (k3s + cri-dockerd, GUEST aarch64)
# ---------------------------------------------------------------------------

fetch_k8s() {
	echo "== k8s (k3s ${K3S_VERSION} + cri-dockerd ${CRI_DOCKERD_VERSION}, guest aarch64) =="

	local dest_dir="${REPO_ROOT}/dist/guest-k8s"
	local k3s_dest="${dest_dir}/k3s"
	local cri_dest="${dest_dir}/cri-dockerd"

	require_cmd curl
	require_cmd tar

	mkdir -p "${dest_dir}"

	# --- k3s ---------------------------------------------------------------
	local need_k3s=1
	if [ -x "${k3s_dest}" ]; then
		local have_sha
		have_sha="$(sha256_of "${k3s_dest}")"
		if [ "${have_sha}" = "${K3S_SHA256}" ]; then
			check "k3s already present and verified: ${k3s_dest}"
			need_k3s=0
		else
			echo "  existing ${k3s_dest} has sha256 ${have_sha}, expected ${K3S_SHA256}; re-fetching" >&2
		fi
	fi

	if [ "${need_k3s}" -eq 1 ]; then
		info "fetching sha256 sidecar ${K3S_SHA256_SIDECAR_URL}"
		# The sidecar covers every arm64 asset in the release, one
		# "<sha256>  <filename>" line each; pick out the k3s-arm64 row.
		local sidecar_sha
		sidecar_sha="$(curl --fail --location --show-error --silent "${K3S_SHA256_SIDECAR_URL}" |
			awk '$2 == "k3s-arm64" { print $1 }')"
		[ -n "${sidecar_sha}" ] || fail "failed to fetch/parse the k3s sha256 sidecar (no k3s-arm64 line)"
		[ "${sidecar_sha}" = "${K3S_SHA256}" ] ||
			fail "k3s sha256 sidecar (${sidecar_sha}) does not match the pin in this script (${K3S_SHA256}); upstream release may have been re-cut"
		check "sidecar agrees with the pin"

		local tmp_k3s
		tmp_k3s="$(mktemp "${TMPDIR:-/tmp}/morbstack-k3s.XXXXXX")"

		info "downloading ${K3S_RELEASE_URL}"
		if ! curl --fail --location --show-error --progress-bar --output "${tmp_k3s}" "${K3S_RELEASE_URL}"; then
			rm -f "${tmp_k3s}"
			fail "failed to download the k3s binary"
		fi

		local got_sha
		got_sha="$(sha256_of "${tmp_k3s}")"
		if [ "${got_sha}" != "${K3S_SHA256}" ]; then
			rm -f "${tmp_k3s}"
			fail "k3s sha256 mismatch: got ${got_sha}, expected ${K3S_SHA256} (possible corruption or upstream tamper)"
		fi
		check "sha256 verified against pin and release sidecar"

		install -m 0755 "${tmp_k3s}" "${k3s_dest}"
		rm -f "${tmp_k3s}"
		check "installed: ${k3s_dest}"
	fi

	# --- cri-dockerd -------------------------------------------------------
	local need_cri=1
	if [ -x "${cri_dest}" ]; then
		local have_sha
		have_sha="$(sha256_of "${cri_dest}")"
		if [ "${have_sha}" = "${CRI_DOCKERD_SHA256}" ]; then
			check "cri-dockerd already present and verified: ${cri_dest}"
			need_cri=0
		else
			echo "  existing ${cri_dest} has sha256 ${have_sha}, expected ${CRI_DOCKERD_SHA256}; re-fetching" >&2
		fi
	fi

	if [ "${need_cri}" -eq 1 ]; then
		local tmp_archive tmp_extract
		tmp_archive="$(mktemp "${TMPDIR:-/tmp}/morbstack-cri-dockerd.XXXXXX")"
		tmp_extract="$(mktemp -d "${TMPDIR:-/tmp}/morbstack-cri-dockerd-extract.XXXXXX")"

		info "downloading ${CRI_DOCKERD_RELEASE_URL}"
		if ! curl --fail --location --show-error --progress-bar --output "${tmp_archive}" "${CRI_DOCKERD_RELEASE_URL}"; then
			rm -f "${tmp_archive}"
			rm -rf "${tmp_extract}"
			fail "failed to download the cri-dockerd archive"
		fi

		local archive_sha
		archive_sha="$(sha256_of "${tmp_archive}")"
		if [ "${archive_sha}" != "${CRI_DOCKERD_ARCHIVE_SHA256}" ]; then
			rm -f "${tmp_archive}"
			rm -rf "${tmp_extract}"
			fail "cri-dockerd archive sha256 mismatch: got ${archive_sha}, expected ${CRI_DOCKERD_ARCHIVE_SHA256} (possible corruption or upstream tamper)"
		fi
		check "archive sha256 verified"

		tar xzf "${tmp_archive}" -C "${tmp_extract}"
		local extracted="${tmp_extract}/${CRI_DOCKERD_MEMBER_PATH}"
		if [ ! -f "${extracted}" ]; then
			rm -f "${tmp_archive}"
			rm -rf "${tmp_extract}"
			fail "expected member ${CRI_DOCKERD_MEMBER_PATH} not found in the cri-dockerd archive"
		fi

		# The member is hash-pinned in its own right, not just the archive it
		# arrived in: that is what makes "already present and verified" above
		# a statement about the installed file rather than about a download
		# that happened once, some time ago, on some other machine.
		local member_sha
		member_sha="$(sha256_of "${extracted}")"
		if [ "${member_sha}" != "${CRI_DOCKERD_SHA256}" ]; then
			rm -f "${tmp_archive}"
			rm -rf "${tmp_extract}"
			fail "extracted cri-dockerd sha256 mismatch: got ${member_sha}, expected ${CRI_DOCKERD_SHA256}"
		fi

		install -m 0755 "${extracted}" "${cri_dest}"
		rm -f "${tmp_archive}"
		rm -rf "${tmp_extract}"
		check "installed and verified: ${cri_dest}"
	fi

	# Second copy, into the runtime tree the daemon actually reads.
	#
	# dist/ is the repository's provenance-bearing cache; it is not present on
	# a machine that installed Morbstack.app rather than cloning. The daemon
	# therefore loads the payload from ${MORBSTACK_HOME}/data/k8s, exactly as
	# it loads the kernel from ${MORBSTACK_HOME}/data/kernel, and this step
	# populates it. Both copies are hash-checked, so a half-written runtime
	# copy is re-installed rather than trusted.
	local runtime_dir="${MORBSTACK_HOME}/data/k8s"
	mkdir -p "${runtime_dir}"
	local name src want
	for name in k3s cri-dockerd; do
		src="${dest_dir}/${name}"
		if [ "${name}" = "k3s" ]; then want="${K3S_SHA256}"; else want="${CRI_DOCKERD_SHA256}"; fi
		if [ -x "${runtime_dir}/${name}" ] && [ "$(sha256_of "${runtime_dir}/${name}")" = "${want}" ]; then
			continue
		fi
		install -m 0755 "${src}" "${runtime_dir}/${name}"
	done
	check "staged for the daemon: ${runtime_dir}"

	cat >"${dest_dir}/PROVENANCE.txt" <<EOF
Morbstack Kubernetes payload provenance
=======================================

This directory holds the OPTIONAL Kubernetes payload. It is NOT baked into
the initramfs: Kubernetes is off by default, and a 118 MB payload in the
initramfs would be paid for in guest RAM on every boot including the common
one where nobody wants a cluster. Instead morbstackd reads the copy under
\${MORBSTACK_HOME}/data/k8s and streams it into the guest over vsock port
2377 the first time \`morb k8s enable\` runs, where morbinit writes it to the
persistent ext4 disk. A guest that has never been enabled reports
Kubernetes as "not-installed" and carries none of these bytes.

File: k3s
Source: ${K3S_RELEASE_URL}
Version: ${K3S_VERSION}
sha256: ${K3S_SHA256}
Verification: sha256 pinned in scripts/fetch-guest-assets.sh AND re-checked
on every fetch against upstream's own release sidecar
(${K3S_SHA256_SIDECAR_URL}, the "k3s-arm64" line).

File: cri-dockerd
Source: ${CRI_DOCKERD_RELEASE_URL}
Version: ${CRI_DOCKERD_VERSION}
Archive sha256: ${CRI_DOCKERD_ARCHIVE_SHA256}
Member: ${CRI_DOCKERD_MEMBER_PATH}
Final sha256: ${CRI_DOCKERD_SHA256}
Verification: both the archive and the single extracted binary are pinned.
Mirantis publishes no sha256 sidecar for these assets, so unlike k3s there
is no upstream-provided second opinion to cross-check against.

Why two binaries rather than k3s's embedded shim
------------------------------------------------
k3s vendors cri-dockerd and can run it in-process (\`k3s server --docker\`),
which would save ~49 MB. Morbstack deliberately ships the standalone binary
instead: morbinit supervises cri-dockerd as a service in its own right, with
its own SIGTERM/SIGKILL ladder and its own restart backoff, so a shim that
wedges is restarted on its own instead of taking the control plane with it.

Why cri-dockerd at all
----------------------
The cluster is wired to the SAME dockerd the Docker socket relay serves, so
an image produced by \`docker build\` is immediately runnable in the cluster
with no registry push and no \`kind load\`. That is the whole reason this is
not just an embedded containerd.

Fetched by scripts/fetch-guest-assets.sh (--k8s-only).
EOF
	info "see ${dest_dir}/PROVENANCE.txt for the pin chain and the design rationale"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

DO_KERNEL=1
DO_DOCKER=1
DO_ALPINE=1
DO_FSUTILS=1
DO_CLI=1
DO_COMPOSE=1
DO_BUILDX=1
DO_KUBECTL=0
DO_K8S=1

disable_all_fetches() {
	DO_KERNEL=0
	DO_DOCKER=0
	DO_ALPINE=0
	DO_FSUTILS=0
	DO_CLI=0
	DO_COMPOSE=0
	DO_BUILDX=0
	DO_KUBECTL=0
	DO_K8S=0
}

while [ $# -gt 0 ]; do
	case "$1" in
	--kernel-only)
		disable_all_fetches
		DO_KERNEL=1
		;;
	--docker-only)
		disable_all_fetches
		DO_DOCKER=1
		;;
	--alpine-only)
		disable_all_fetches
		DO_ALPINE=1
		;;
	--fsutils-only)
		disable_all_fetches
		DO_FSUTILS=1
		;;
	--host-cli)
		disable_all_fetches
		DO_CLI=1
		DO_COMPOSE=1
		DO_BUILDX=1
		;;
	--cli-only)
		disable_all_fetches
		DO_CLI=1
		;;
	--compose-only)
		disable_all_fetches
		DO_COMPOSE=1
		;;
	--buildx-only)
		disable_all_fetches
		DO_BUILDX=1
		;;
	--host-kubectl-only)
		disable_all_fetches
		DO_KUBECTL=1
		;;
	--k8s-only)
		disable_all_fetches
		DO_K8S=1
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

[ "${DO_KERNEL}" -eq 1 ] && fetch_kernel
[ "${DO_DOCKER}" -eq 1 ] && fetch_docker
[ "${DO_ALPINE}" -eq 1 ] && fetch_alpine
[ "${DO_FSUTILS}" -eq 1 ] && fetch_fsutils
[ "${DO_CLI}" -eq 1 ] && fetch_docker_cli
[ "${DO_COMPOSE}" -eq 1 ] && fetch_compose
[ "${DO_BUILDX}" -eq 1 ] && fetch_buildx
[ "${DO_KUBECTL}" -eq 1 ] && fetch_kubectl
[ "${DO_K8S}" -eq 1 ] && fetch_k8s

echo ""
echo "Done."
