#!/usr/bin/env bash
#
# mkinitramfs.sh — build the guest initramfs for Morbstack's VZ boot path.
#
# Assembles a gzipped newc cpio archive containing:
#   - the Alpine 3.24.1 aarch64 minirootfs (dist/rootfs/alpine-minirootfs.tar.gz)
#   - morbinit (cross-compiled Rust PID 1) installed as /init
#   - the static Docker 29.7.1 aarch64 engine binaries (dist/guest-bin/*)
#     installed into /usr/local/bin
#   - /usr/share/udhcpc/default.script (Alpine ships one; we only write a
#     fallback if it's somehow missing)
#   - empty var/lib/docker, run, etc directories for the guest to use
#   - (optional) a baked-in hello-world OCI image tarball, if
#     dist/images/hello-world-oci.tar exists (see fetch-image-oci.sh), so the
#     boot gate works even if guest DHCP/registry pull fails
#
# Output: $(MORBSTACK_HOME)/data/kernel/initrd.img (default ~/.morbstack).
#
# Usage:
#   scripts/mkinitramfs.sh
#
# Env:
#   MORBSTACK_HOME   Morbstack runtime root (default ~/.morbstack). Mirrors
#                     the override honoured by morbstackd/morb and the other
#                     scripts/ tools.
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

# Repo root: this script lives in scripts/, so its parent's parent is the
# repo root regardless of the caller's cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MORBSTACK_HOME="${MORBSTACK_HOME:-${HOME}/.morbstack}"
DEST_DIR="${MORBSTACK_HOME}/data/kernel"
DEST_FILE="${DEST_DIR}/initrd.img"

ROOTFS_TARBALL="${REPO_ROOT}/dist/rootfs/alpine-minirootfs.tar.gz"
GUEST_BIN_DIR="${REPO_ROOT}/dist/guest-bin"
APKS_DIR="${REPO_ROOT}/dist/apks"
MORBINIT_DIR="${REPO_ROOT}/guest/morbinit"
MORBINIT_BIN="${MORBINIT_DIR}/target/aarch64-unknown-linux-musl/release/morbinit"
HELLO_OCI_TAR="${REPO_ROOT}/dist/images/hello-world-oci.tar"

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------

if ! command -v bsdtar >/dev/null 2>&1; then
	echo "error: bsdtar is required but not found on PATH" >&2
	exit 1
fi

if ! command -v cpio >/dev/null 2>&1; then
	echo "error: cpio is required but not found on PATH" >&2
	exit 1
fi

if ! command -v gzip >/dev/null 2>&1; then
	echo "error: gzip is required but not found on PATH" >&2
	exit 1
fi

if [ ! -f "${ROOTFS_TARBALL}" ]; then
	echo "error: ${ROOTFS_TARBALL} not found" >&2
	echo "       run scripts/fetch-guest-assets.sh first" >&2
	exit 1
fi

if [ ! -d "${GUEST_BIN_DIR}" ] || [ -z "$(ls -A "${GUEST_BIN_DIR}" 2>/dev/null)" ]; then
	echo "error: ${GUEST_BIN_DIR} is missing or empty" >&2
	echo "       run scripts/fetch-guest-assets.sh first" >&2
	exit 1
fi

if [ ! -d "${APKS_DIR}" ] || [ -z "$(ls -A "${APKS_DIR}"/*.apk 2>/dev/null)" ]; then
	echo "error: ${APKS_DIR} is missing or has no .apk files" >&2
	echo "       run scripts/fetch-guest-assets.sh --fsutils-only first" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# morbinit: build it if the cross-compiled release binary isn't there yet.
# We only ever read guest/morbinit (never write into it) — the cross build
# is driven entirely by env vars, matching `make cross-build-guest`.
# ---------------------------------------------------------------------------

if [ ! -x "${MORBINIT_BIN}" ]; then
	echo "morbinit (aarch64-unknown-linux-musl release) not built yet; building..."

	CROSS_TOOLCHAIN_BIN="/opt/homebrew/opt/aarch64-unknown-linux-musl/bin"
	CROSS_GCC="${CROSS_TOOLCHAIN_BIN}/aarch64-unknown-linux-musl-gcc"

	if [ ! -x "${CROSS_GCC}" ]; then
		echo "error: aarch64-unknown-linux-musl cross toolchain not found at ${CROSS_TOOLCHAIN_BIN}" >&2
		echo "       see dist/CROSS_COMPILE.md for the install recipe, or run" >&2
		echo "       'make cross-build-guest' directly for a clearer error." >&2
		exit 1
	fi

	if ! command -v cargo >/dev/null 2>&1; then
		echo "error: cargo not found on PATH; cannot build morbinit" >&2
		echo "       install Rust (see mise.toml) and add the" >&2
		echo "       aarch64-unknown-linux-musl target: rustup target add aarch64-unknown-linux-musl" >&2
		exit 1
	fi

	if ! (
		cd "${MORBINIT_DIR}" &&
			PATH="${CROSS_TOOLCHAIN_BIN}:${PATH}" \
				CC_aarch64_unknown_linux_musl="${CROSS_GCC}" \
				CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER="${CROSS_GCC}" \
				cargo build --release --target aarch64-unknown-linux-musl
	); then
		echo "error: cross-compiling morbinit failed" >&2
		echo "       see dist/CROSS_COMPILE.md for toolchain setup" >&2
		exit 1
	fi

	if [ ! -x "${MORBINIT_BIN}" ]; then
		echo "error: cargo build reported success but ${MORBINIT_BIN} is missing" >&2
		exit 1
	fi
fi

echo "Using morbinit: ${MORBINIT_BIN}"

# ---------------------------------------------------------------------------
# Stage the rootfs
# ---------------------------------------------------------------------------

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/morbstack-initramfs.XXXXXX")"
TMP_OUT=""
cleanup() {
	rm -rf "${STAGE_DIR}"
	if [ -n "${TMP_OUT}" ]; then
		rm -f "${TMP_OUT}"
	fi
}
trap cleanup EXIT

echo "Staging rootfs in ${STAGE_DIR}..."

# Extract as the current (unprivileged) user. Device nodes can't be created
# without root, and we don't need them baked in anyway — devtmpfs covers
# /dev once the kernel mounts it at boot, so we just skip ./dev/* here.
bsdtar -xzf "${ROOTFS_TARBALL}" -C "${STAGE_DIR}" --exclude "./dev/*"

# /init: morbinit, our Rust PID 1.
install -m 0755 "${MORBINIT_BIN}" "${STAGE_DIR}/init"

# Docker engine binaries -> /usr/local/bin.
mkdir -p "${STAGE_DIR}/usr/local/bin"
for f in "${GUEST_BIN_DIR}"/*; do
	base="$(basename "${f}")"
	[ "${base}" = "PROVENANCE.txt" ] && continue
	install -m 0755 "${f}" "${STAGE_DIR}/usr/local/bin/${base}"
done

# ---------------------------------------------------------------------------
# fsutils: btrfs-progs, e2fsprogs, iptables-legacy + their full .so
# dependency closure, from the apks cached by
# scripts/fetch-guest-assets.sh --fsutils-only (see dist/apks/PROVENANCE.txt
# for the package list and the iptables-legacy vs iptables rationale).
#
# Each .apk is a concatenation of gzip streams (signature.tar.gz +
# control.tar.gz + data.tar.gz, per the apk v2 format) that a plain
# `tar xzf` decompresses and interleaves transparently, extracting every
# member from all three streams into one directory. We only want the
# installed files (from data.tar.gz), so everything from the control/
# signature streams — .PKGINFO and .SIGN.* — is filtered out below.
#
# One package is staged only in part. The plain "iptables" apk is the
# nft-backed frontend we deliberately did not choose, but it is also the only
# place Alpine ships /usr/lib/xtables/libxt_*.so: the match and target
# extension modules that libxtables dlopen()s while parsing a rule
# (addrtype, MASQUERADE, conntrack, comment, multiport, ...). Those modules
# are frontend-agnostic — their entire DT_NEEDED closure is libc.musl plus
# libxtables.so.12 — so taking that one directory costs nothing and changes
# no dependency, while taking its usr/sbin would drop xtables-nft-multi into
# the image (needing libmnl/libnftnl, which we do not ship) and clobber the
# iptables/ip6tables symlinks created further down. Hence: extensions yes,
# binaries no. Without the extensions dockerd's very first NAT rule fails
# with "iptables v1.8.13 (legacy): Couldn't load match `addrtype'" and the
# daemon never finishes starting.
# ---------------------------------------------------------------------------

echo "Staging fsutils apks (btrfs-progs, e2fsprogs, iptables-legacy)..."
APK_EXTRACT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/morbstack-apk-extract.XXXXXX")"
for apk in "${APKS_DIR}"/*.apk; do
	base="$(basename "${apk}")"
	pkg_extract="${APK_EXTRACT_DIR}/${base%.apk}"
	mkdir -p "${pkg_extract}"
	tar -xzf "${apk}" -C "${pkg_extract}"

	# Which subtree of this package to stage. "." means all of it. The glob
	# below matches iptables-<digit>… so it selects the main iptables apk
	# without also catching iptables-legacy-*.
	apk_subtree="."
	case "${base}" in
	iptables-[0-9]*)
		apk_subtree="./usr/lib/xtables"
		if [ ! -d "${pkg_extract}/usr/lib/xtables" ]; then
			echo "error: ${base} has no usr/lib/xtables (upstream layout changed?)" >&2
			exit 1
		fi
		;;
	esac

	# Copy everything except apk control/signature metadata
	# (.PKGINFO, .SIGN.RSA.*) into the staged rootfs, preserving paths
	# (usr/sbin, usr/lib, sbin, etc — whatever the apk itself uses).
	( cd "${pkg_extract}" && find "${apk_subtree}" -mindepth 1 \( -name '.PKGINFO' -o -name '.SIGN.*' \) -prune -o -print ) |
		while IFS= read -r rel; do
			src="${pkg_extract}/${rel#./}"
			dst="${STAGE_DIR}/${rel#./}"
			if [ -d "${src}" ] && [ ! -L "${src}" ]; then
				mkdir -p "${dst}"
			elif [ -L "${src}" ]; then
				mkdir -p "$(dirname "${dst}")"
				ln -sf "$(readlink "${src}")" "${dst}"
			else
				mkdir -p "$(dirname "${dst}")"
				install -m "$(stat -f '%OLp' "${src}" 2>/dev/null || stat -c '%a' "${src}")" "${src}" "${dst}"
			fi
		done
done
rm -rf "${APK_EXTRACT_DIR}"

# iptables-legacy ships xtables-legacy-multi plus symlinks named
# iptables-legacy / ip6tables-legacy / iptables-legacy-{save,restore} /
# ip6tables-legacy-{save,restore} (see dist/apks/PROVENANCE.txt) but never
# anything literally named "iptables" or "ip6tables" — that naming is
# reserved by Alpine's default (nft-backed) iptables package, which we
# deliberately did not install. dockerd execs a program named exactly
# "iptables"/"ip6tables" on PATH, so create those names ourselves,
# alongside the *-save/-restore forms dockerd's userland-proxy/iptables
# driver also shells out to.
XTABLES_MULTI="${STAGE_DIR}/usr/sbin/xtables-legacy-multi"
if [ ! -e "${XTABLES_MULTI}" ]; then
	echo "error: ${XTABLES_MULTI} not found after staging iptables-legacy apk" >&2
	exit 1
fi
for name in iptables ip6tables iptables-save iptables-restore ip6tables-save ip6tables-restore; do
	ln -sf xtables-legacy-multi "${STAGE_DIR}/usr/sbin/${name}"
done

# udhcpc hook script: Alpine's minirootfs ships one at
# usr/share/udhcpc/default.script already; only write a fallback if it's
# somehow missing so `ip udhcpc` still has something to call on renew/bound.
UDHCPC_SCRIPT="${STAGE_DIR}/usr/share/udhcpc/default.script"
if [ ! -e "${UDHCPC_SCRIPT}" ]; then
	echo "warning: ${UDHCPC_SCRIPT} missing from rootfs; writing a minimal fallback"
	mkdir -p "$(dirname "${UDHCPC_SCRIPT}")"
	cat >"${UDHCPC_SCRIPT}" <<'EOF'
#!/bin/sh
# Minimal udhcpc bound/renew/deconfig hook: configures the interface address
# and default route from the udhcpc-supplied environment variables, and
# writes /etc/resolv.conf. Fallback only — Alpine's own default.script (from
# the busybox-udhcpc-scripts / busybox package in the minirootfs) is far more
# complete and should be present; this exists so the guest still gets basic
# connectivity if that file is ever absent.
set -- $router

case "$1" in
deconfig)
	ip addr flush dev "$interface" 2>/dev/null
	ip link set "$interface" up
	;;
bound | renew)
	ip addr flush dev "$interface" 2>/dev/null
	ip addr add "${ip}/${mask:-24}" dev "$interface"
	ip link set "$interface" up
	if [ -n "$1" ]; then
		ip route replace default via "$1" dev "$interface"
	fi
	{
		for dns in $dns; do
			echo "nameserver $dns"
		done
		echo "nameserver 1.1.1.1"
	} >/etc/resolv.conf
	;;
esac

exit 0
EOF
fi
chmod 0755 "${UDHCPC_SCRIPT}"

# ---------------------------------------------------------------------------
# The Kubernetes payload is deliberately NOT staged here.
#
# dist/guest-k8s/ holds k3s (74 MB) and cri-dockerd (49 MB), and it is tempting
# to install them into /usr/local/bin alongside the Docker binaries. Do not.
# This archive is unpacked into the kernel's initial `rootfs`, which is a ramfs:
# its pages are never reclaimed and there is no way to free them short of
# deleting the files, so every byte in here is guest RAM held for the entire
# life of the VM. Kubernetes is off by default, so that would be 122 MB spent on
# every boot for a feature most boots never use — and it would grow the initrd
# from ~84 MB to ~130 MB, slowing the load on every start.
#
# Instead morbstackd streams the payload in over vsock 2377 the first time
# `morb k8s enable` runs, and morbinit writes it to the persistent ext4 disk
# (see guest/morbinit/src/k8s.rs). A guest that has never been asked for a
# cluster carries none of it. If you are here because you want an air-gapped
# image with Kubernetes pre-installed, add it to the DISK, not to this cpio.
# ---------------------------------------------------------------------------

# Empty runtime dirs the guest expects at boot.
mkdir -p "${STAGE_DIR}/var/lib/docker" "${STAGE_DIR}/run" "${STAGE_DIR}/etc"

# Bake in the hello-world OCI image tarball, if fetch-image-oci.sh has
# produced one, so the M0 boot gate (`docker run hello-world`) works even if
# the guest can't reach the network / registry at boot.
if [ -f "${HELLO_OCI_TAR}" ]; then
	echo "Baking in hello-world OCI image: ${HELLO_OCI_TAR}"
	mkdir -p "${STAGE_DIR}/usr/share/morb"
	install -m 0644 "${HELLO_OCI_TAR}" "${STAGE_DIR}/usr/share/morb/hello-world-oci.tar"
else
	echo "note: ${HELLO_OCI_TAR} not found; skipping bake-in (run scripts/fetch-image-oci.sh first if wanted)"
fi

# ---------------------------------------------------------------------------
# Pack as gzipped newc cpio, owned by root (uid/gid 0) regardless of the
# unprivileged uid that extracted/staged these files.
# ---------------------------------------------------------------------------

mkdir -p "${DEST_DIR}"
TMP_OUT="$(mktemp "${DEST_DIR}/.initrd.img.XXXXXX")"

echo "Packing cpio archive..."
(
	cd "${STAGE_DIR}" &&
		find . -mindepth 1 -print0 | cpio --null -o -H newc -R 0:0 2>/dev/null
) | gzip -6 >"${TMP_OUT}"

if [ ! -s "${TMP_OUT}" ]; then
	echo "error: produced empty initramfs archive" >&2
	exit 1
fi

# Sanity-check: gzip -t validates the gzip container itself.
if ! gzip -t "${TMP_OUT}"; then
	echo "error: ${TMP_OUT} is not a valid gzip archive" >&2
	exit 1
fi

mv "${TMP_OUT}" "${DEST_FILE}"
TMP_OUT=""
chmod 0644 "${DEST_FILE}"

SIZE_BYTES="$(wc -c <"${DEST_FILE}" | tr -d ' ')"
SIZE_HUMAN="$(du -h "${DEST_FILE}" | cut -f1)"
if command -v sha256sum >/dev/null 2>&1; then
	SHA256="$(sha256sum "${DEST_FILE}" | cut -d' ' -f1)"
else
	SHA256="$(shasum -a 256 "${DEST_FILE}" | cut -d' ' -f1)"
fi

echo ""
echo "Built: ${DEST_FILE}"
echo "Size:  ${SIZE_HUMAN} (${SIZE_BYTES} bytes)"
echo "sha256: ${SHA256}"

LIMIT_BYTES=$((300 * 1024 * 1024))
if [ "${SIZE_BYTES}" -ge "${LIMIT_BYTES}" ]; then
	echo "warning: initrd.img is >= 300MB (target budget); consider trimming dist/guest-bin or the rootfs" >&2
fi
