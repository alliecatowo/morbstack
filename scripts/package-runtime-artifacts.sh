#!/usr/bin/env bash
#
# Stage a complete, already-built Morbstack runtime into an app bundle.
#
# This script deliberately has no downloader and no builder. Release automation must
# materialize the pinned kernel, initramfs and Kubernetes payload first; this command
# only hashes those exact bytes, copies them below Contents/Resources/runtime/<version>,
# and writes the manifest the daemon verifies before activation.

set -euo pipefail

usage() {
	cat <<'EOF'
Usage: package-runtime-artifacts.sh --source-root <data-dir> --destination <app-runtime-dir> --version <runtime-version>

The source root must contain:
  kernel/vmlinux
  kernel/initrd.img
  k8s/k3s
  k8s/cri-dockerd

It creates a fresh app Resources/runtime directory containing a versioned payload and
a SHA-256 manifest. It never downloads or builds assets.
EOF
}

SOURCE_ROOT=""
DESTINATION=""
RUNTIME_VERSION=""

while [ "$#" -gt 0 ]; do
	case "$1" in
	--source-root)
		[ "$#" -ge 2 ] || { usage >&2; exit 2; }
		SOURCE_ROOT="$2"
		shift 2
		;;
	--destination)
		[ "$#" -ge 2 ] || { usage >&2; exit 2; }
		DESTINATION="$2"
		shift 2
		;;
	--version)
		[ "$#" -ge 2 ] || { usage >&2; exit 2; }
		RUNTIME_VERSION="$2"
		shift 2
		;;
	--help|-h)
		usage
		exit 0
		;;
	*)
		echo "error: unknown option $1" >&2
		usage >&2
		exit 2
		;;
	esac
done

[ -n "$SOURCE_ROOT" ] && [ -n "$DESTINATION" ] && [ -n "$RUNTIME_VERSION" ] || {
	usage >&2
	exit 2
}

printf '%s' "$RUNTIME_VERSION" | grep -Eq '^[A-Za-z0-9._-]+$' || {
	echo "error: runtime version must contain only letters, digits, dot, underscore, or hyphen" >&2
	exit 2
}

[ ! -e "$DESTINATION" ] || {
	echo "error: runtime destination already exists: $DESTINATION" >&2
	echo "       app assembly must create a fresh Contents/Resources/runtime directory" >&2
	exit 1
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

require_file() {
	[ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ] || {
		echo "error: required runtime artifact is missing or unsafe: $1" >&2
		exit 1
	}
}

KERNEL_SOURCE="$SOURCE_ROOT/kernel/vmlinux"
INITRD_SOURCE="$SOURCE_ROOT/kernel/initrd.img"
K3S_SOURCE="$SOURCE_ROOT/k8s/k3s"
CRI_DOCKERD_SOURCE="$SOURCE_ROOT/k8s/cri-dockerd"

for ARTIFACT in "$KERNEL_SOURCE" "$INITRD_SOURCE" "$K3S_SOURCE" "$CRI_DOCKERD_SOURCE"; do
	require_file "$ARTIFACT"
done

[ -x "$K3S_SOURCE" ] && [ -x "$CRI_DOCKERD_SOURCE" ] || {
	echo "error: Kubernetes runtime binaries must be executable" >&2
	exit 1
}

KERNEL_SHA="$(sha256_of "$KERNEL_SOURCE")"
INITRD_SHA="$(sha256_of "$INITRD_SOURCE")"
K3S_SHA="$(sha256_of "$K3S_SOURCE")"
CRI_DOCKERD_SHA="$(sha256_of "$CRI_DOCKERD_SOURCE")"

VERSION_DIR="$DESTINATION/$RUNTIME_VERSION"
mkdir -p "$VERSION_DIR/kernel" "$VERSION_DIR/k8s"
install -m 0644 "$KERNEL_SOURCE" "$VERSION_DIR/kernel/vmlinux"
install -m 0644 "$INITRD_SOURCE" "$VERSION_DIR/kernel/initrd.img"
install -m 0755 "$K3S_SOURCE" "$VERSION_DIR/k8s/k3s"
install -m 0755 "$CRI_DOCKERD_SOURCE" "$VERSION_DIR/k8s/cri-dockerd"

printf '%s\n' \
	'{' \
	'  "schema_version": 1,' \
	"  \"runtime_version\": \"$RUNTIME_VERSION\"," \
	'  "artifacts": [' \
	"    {\"id\":\"kernel\",\"path\":\"kernel/vmlinux\",\"sha256\":\"$KERNEL_SHA\",\"executable\":false,\"required\":true}," \
	"    {\"id\":\"initrd\",\"path\":\"kernel/initrd.img\",\"sha256\":\"$INITRD_SHA\",\"executable\":false,\"required\":true}," \
	"    {\"id\":\"kubernetes-k3s\",\"path\":\"k8s/k3s\",\"sha256\":\"$K3S_SHA\",\"executable\":true,\"required\":true}," \
	"    {\"id\":\"kubernetes-cri-dockerd\",\"path\":\"k8s/cri-dockerd\",\"sha256\":\"$CRI_DOCKERD_SHA\",\"executable\":true,\"required\":true}" \
	'  ]' \
	'}' >"$DESTINATION/manifest.json"

echo "staged Morbstack runtime $RUNTIME_VERSION at $DESTINATION"
