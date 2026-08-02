#!/usr/bin/env bash
#
# fetch-image-oci.sh — fetch a small image from Docker Hub via plain curl
# (no docker/skopeo/crane dependency) and write it out as an OCI image
# layout tar that `docker load` can import.
#
# Pipeline: anonymous auth.docker.io bearer token -> registry-1.docker.io
# manifest list (or OCI index) -> pick the linux/arm64 child manifest ->
# download its config + layer blobs -> assemble a spec-compliant OCI image
# layout directory (oci-layout, index.json, blobs/sha256/*) -> tar it.
#
# Registry API version pins (Docker Registry HTTP API V2 / OCI Distribution
# Spec, both stable and unversioned-but-de-facto-frozen; media types below
# are what's actually pinned):
#   Manifest list:  application/vnd.docker.distribution.manifest.list.v2+json
#                   application/vnd.oci.image.index.v1+json
#   Child manifest: application/vnd.docker.distribution.manifest.v2+json
#                   application/vnd.oci.image.manifest.v1+json
#   OCI image layout version: 1.0.0
#
# Output: dist/images/<name>-oci.tar (default dist/images/hello-world-oci.tar)
#
# Usage:
#   scripts/fetch-image-oci.sh                       # hello-world:latest
#   scripts/fetch-image-oci.sh -i library/alpine:3.20 -o dist/images/alpine-oci.tar
#   scripts/fetch-image-oci.sh -h
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Default image: hello-world:latest. This is the M0 boot-gate image (see
# the shared contract: `docker run --rm hello-world` must print its banner),
# and it's tiny (~kilobytes per layer), which keeps this fetch fast and the
# baked-in initramfs copy small.
IMAGE="library/hello-world"
TAG="latest"
OUT_FILE="${REPO_ROOT}/dist/images/hello-world-oci.tar"
PLATFORM_ARCH="arm64"
PLATFORM_OS="linux"

REGISTRY_AUTH_URL="https://auth.docker.io/token"
REGISTRY_SERVICE="registry.docker.io"
REGISTRY_BASE="https://registry-1.docker.io/v2"

ACCEPT_INDEX="application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.manifest.v1+json"
ACCEPT_MANIFEST="application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.manifest.v1+json"

usage() {
	cat <<EOF
Usage: $(basename "$0") [-i NAMESPACE/REPO[:TAG]] [-o OUTPUT_TAR] [-h]

Fetch a (default: small, multi-arch) image from Docker Hub via curl and
write it out as an OCI image layout tar.

Options:
  -i IMAGE   Docker Hub image, "namespace/repo" or "namespace/repo:tag"
             (default: library/hello-world:latest)
  -o FILE    Output tar path (default: dist/images/hello-world-oci.tar)
  -h         Show this help and exit
EOF
}

while getopts "i:o:h" opt; do
	case "${opt}" in
	i)
		IMAGE="${OPTARG%%:*}"
		if [[ "${OPTARG}" == *:* ]]; then
			TAG="${OPTARG##*:}"
		else
			TAG="latest"
		fi
		;;
	o) OUT_FILE="${OPTARG}" ;;
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

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "error: $1 is required but not found on PATH" >&2
		exit 1
	}
}
require_cmd curl
require_cmd jq
require_cmd tar

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

echo "Image: ${IMAGE}:${TAG}  (platform ${PLATFORM_OS}/${PLATFORM_ARCH})"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/morbstack-oci.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

LAYOUT_DIR="${WORK_DIR}/layout"
BLOBS_DIR="${LAYOUT_DIR}/blobs/sha256"
mkdir -p "${BLOBS_DIR}"

# ---------------------------------------------------------------------------
# 1. Anonymous pull token.
# ---------------------------------------------------------------------------

echo "Requesting anonymous pull token..."
TOKEN="$(curl --fail --silent --show-error \
	"${REGISTRY_AUTH_URL}?service=${REGISTRY_SERVICE}&scope=repository:${IMAGE}:pull" |
	jq -r '.token')"
[ -n "${TOKEN}" ] && [ "${TOKEN}" != "null" ] || {
	echo "error: failed to obtain registry auth token" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# 2. Manifest list / index for the tag.
# ---------------------------------------------------------------------------

echo "Fetching manifest index for ${IMAGE}:${TAG}..."
INDEX_HEADERS="${WORK_DIR}/index.headers"
INDEX_JSON="${WORK_DIR}/index.json.raw"
curl --fail --silent --show-error \
	-H "Authorization: Bearer ${TOKEN}" \
	-H "Accept: ${ACCEPT_INDEX}" \
	-D "${INDEX_HEADERS}" \
	-o "${INDEX_JSON}" \
	"${REGISTRY_BASE}/${IMAGE}/manifests/${TAG}"

INDEX_MEDIA_TYPE="$(jq -r '.mediaType // empty' "${INDEX_JSON}")"

# Some single-arch repos serve a plain manifest directly for the tag rather
# than a list/index. Detect that and skip straight to step 3's manifest
# handling by treating the fetched document as the child manifest itself.
case "${INDEX_MEDIA_TYPE}" in
*.manifest.v2+json | *.image.manifest.v1+json)
	echo "Tag resolves directly to a single-platform manifest (no index); using it as-is."
	CHILD_MANIFEST_JSON="${INDEX_JSON}"
	CHILD_MANIFEST_MEDIA_TYPE="${INDEX_MEDIA_TYPE}"
	CHILD_DIGEST="sha256:$(sha256_of "${INDEX_JSON}")"
	;;
*)
	CHILD_DIGEST="$(jq -r --arg arch "${PLATFORM_ARCH}" --arg os "${PLATFORM_OS}" \
		'.manifests[] | select(.platform.architecture == $arch and .platform.os == $os) | .digest' \
		"${INDEX_JSON}" | head -n1)"
	[ -n "${CHILD_DIGEST}" ] || {
		echo "error: no ${PLATFORM_OS}/${PLATFORM_ARCH} manifest found in index for ${IMAGE}:${TAG}" >&2
		jq -r '.manifests[] | "  found: \(.platform.os)/\(.platform.architecture)"' "${INDEX_JSON}" >&2 || true
		exit 1
	}
	echo "Selected child manifest digest: ${CHILD_DIGEST}"

	echo "Fetching child manifest..."
	CHILD_MANIFEST_JSON="${WORK_DIR}/manifest.json.raw"
	curl --fail --silent --show-error \
		-H "Authorization: Bearer ${TOKEN}" \
		-H "Accept: ${ACCEPT_MANIFEST}" \
		-o "${CHILD_MANIFEST_JSON}" \
		"${REGISTRY_BASE}/${IMAGE}/manifests/${CHILD_DIGEST}"

	GOT_DIGEST="sha256:$(sha256_of "${CHILD_MANIFEST_JSON}")"
	[ "${GOT_DIGEST}" = "${CHILD_DIGEST}" ] || {
		echo "error: child manifest content digest mismatch: got ${GOT_DIGEST}, expected ${CHILD_DIGEST}" >&2
		exit 1
	}
	CHILD_MANIFEST_MEDIA_TYPE="$(jq -r '.mediaType' "${CHILD_MANIFEST_JSON}")"
	;;
esac

# ---------------------------------------------------------------------------
# 3. Download blob helper: fetch by digest into blobs/sha256/<hash>,
#    verifying content hash matches the digest we asked for.
# ---------------------------------------------------------------------------

fetch_blob() {
	local digest="$1" # "sha256:<hex>"
	local hex="${digest#sha256:}"
	local dest="${BLOBS_DIR}/${hex}"

	if [ -f "${dest}" ]; then
		return 0
	fi

	curl --fail --silent --show-error \
		-H "Authorization: Bearer ${TOKEN}" \
		-L \
		-o "${dest}" \
		"${REGISTRY_BASE}/${IMAGE}/blobs/${digest}"

	local got
	got="sha256:$(sha256_of "${dest}")"
	[ "${got}" = "${digest}" ] || {
		echo "error: blob digest mismatch for ${digest}: got ${got}" >&2
		exit 1
	}
}

# ---------------------------------------------------------------------------
# 4. Config blob.
# ---------------------------------------------------------------------------

CONFIG_DIGEST="$(jq -r '.config.digest' "${CHILD_MANIFEST_JSON}")"
echo "Downloading config blob ${CONFIG_DIGEST}..."
fetch_blob "${CONFIG_DIGEST}"

# ---------------------------------------------------------------------------
# 5. Layer blobs.
# ---------------------------------------------------------------------------

LAYER_COUNT="$(jq '.layers | length' "${CHILD_MANIFEST_JSON}")"
echo "Downloading ${LAYER_COUNT} layer blob(s)..."
for i in $(seq 0 $((LAYER_COUNT - 1))); do
	layer_digest="$(jq -r ".layers[${i}].digest" "${CHILD_MANIFEST_JSON}")"
	echo "  layer ${i}: ${layer_digest}"
	fetch_blob "${layer_digest}"
done

# ---------------------------------------------------------------------------
# 6. Manifest blob itself goes into the layout too, referenced by index.json.
# ---------------------------------------------------------------------------

MANIFEST_HEX="$(sha256_of "${CHILD_MANIFEST_JSON}")"
cp "${CHILD_MANIFEST_JSON}" "${BLOBS_DIR}/${MANIFEST_HEX}"
MANIFEST_SIZE="$(wc -c <"${CHILD_MANIFEST_JSON}" | tr -d ' ')"

# ---------------------------------------------------------------------------
# 7. Assemble the OCI image layout: oci-layout + index.json.
# ---------------------------------------------------------------------------

cat >"${LAYOUT_DIR}/oci-layout" <<'EOF'
{"imageLayoutVersion":"1.0.0"}
EOF

# The reference `docker load` will tag the imported image with. Strip only a
# leading "library/" (Docker's implicit namespace for official images), so
# library/hello-world -> hello-world:latest while foo/bar stays foo/bar:tag.
REPO_TAG="${IMAGE#library/}:${TAG}"

jq -n \
	--arg mediaType "${CHILD_MANIFEST_MEDIA_TYPE}" \
	--arg digest "sha256:${MANIFEST_HEX}" \
	--argjson size "${MANIFEST_SIZE}" \
	--arg arch "${PLATFORM_ARCH}" \
	--arg os "${PLATFORM_OS}" \
	--arg ref "${REPO_TAG}" \
	'{
		schemaVersion: 2,
		manifests: [
			{
				mediaType: $mediaType,
				digest: $digest,
				size: $size,
				platform: { architecture: $arch, os: $os },
				annotations: { "org.opencontainers.image.ref.name": $ref }
			}
		]
	}' >"${LAYOUT_DIR}/index.json"

# ---------------------------------------------------------------------------
# 7b. manifest.json — the legacy "docker save" index, alongside the OCI one.
#
# A pure OCI layout is only loadable by a daemon running the containerd image
# store. The classic graphdriver loader (what dockerd uses by default, and
# what the guest runs) reads manifest.json and nothing else:
#
#   invalid archive: does not contain a manifest.json
#
# Real `docker save` output carries both for exactly this reason, so we do
# too — same blobs, two indexes. Layer paths point straight at the (gzipped)
# blobs; the loader decompresses transparently and verifies what it gets
# against the config's rootfs.diff_ids.
# ---------------------------------------------------------------------------

jq -n \
	--arg config "blobs/sha256/${CONFIG_DIGEST#sha256:}" \
	--arg repoTag "${REPO_TAG}" \
	--argjson layers "$(jq '[.layers[].digest | "blobs/sha256/" + sub("^sha256:"; "")]' \
		"${CHILD_MANIFEST_JSON}")" \
	'[
		{
			Config: $config,
			RepoTags: [ $repoTag ],
			Layers: $layers
		}
	]' >"${LAYOUT_DIR}/manifest.json"

# ---------------------------------------------------------------------------
# 8. Tar it up.
# ---------------------------------------------------------------------------

mkdir -p "$(dirname "${OUT_FILE}")"
TMP_TAR="$(mktemp "${WORK_DIR}/oci-tar.XXXXXX")"

# --no-xattrs / --no-mac-metadata / COPYFILE_DISABLE: strip macOS-only
# metadata. Without them this tar is unloadable in the guest. macOS tags files
# it creates with a `com.apple.provenance` extended attribute, bsdtar stores
# xattrs by default, and the guest's untar then fails hard:
#
#   lsetxattr /oci-layout: xattr "com.apple.provenance": operation not supported
#
# which takes down the whole `docker load` — this is the *offline* fallback for
# the boot gate, so it has to work on a machine that can't reach the registry.
# COPYFILE_DISABLE additionally suppresses the ._AppleDouble sidecar entries.
(cd "${LAYOUT_DIR}" && COPYFILE_DISABLE=1 tar \
	--no-xattrs --no-mac-metadata \
	-cf "${TMP_TAR}" oci-layout index.json manifest.json blobs)

# Sanity check: the tar should contain exactly the layout root entries.
for required in index.json manifest.json oci-layout; do
	if ! tar -tf "${TMP_TAR}" | grep -qx "${required}"; then
		echo "error: assembled tar is missing ${required} at its root" >&2
		exit 1
	fi
done

# Sanity check: no macOS metadata survived. `tar -tvf` lists xattr-carrying
# entries with a trailing metadata line and AppleDouble files as `._name`;
# both are fatal to `docker load` in the guest, so catch them here rather
# than at boot-gate time.
if tar -tf "${TMP_TAR}" | grep -qE '(^|/)\._|^\./\._'; then
	echo "error: assembled tar contains macOS AppleDouble entries" >&2
	exit 1
fi

mv "${TMP_TAR}" "${OUT_FILE}"
chmod 0644 "${OUT_FILE}"

SIZE_HUMAN="$(du -h "${OUT_FILE}" | cut -f1)"
OUT_SHA256="$(sha256_of "${OUT_FILE}")"

echo ""
echo "Built: ${OUT_FILE}"
echo "Size:  ${SIZE_HUMAN}"
echo "sha256: ${OUT_SHA256}"
echo "Manifest: ${CHILD_MANIFEST_MEDIA_TYPE} sha256:${MANIFEST_HEX} (${PLATFORM_OS}/${PLATFORM_ARCH})"
echo ""
echo "This is a docker-load-compatible OCI archive. mkinitramfs.sh bakes it"
echo "into the initramfs at /usr/share/morb/hello-world-oci.tar automatically"
echo "if present at dist/images/hello-world-oci.tar."
