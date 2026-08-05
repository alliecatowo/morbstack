#!/bin/sh
# Copyright 2026 The Morbstack Authors.
# Licensed under the Apache License, Version 2.0 (the "License").
#
# Prepare one isolated Docker-context environment for an ecosystem acceptance
# probe, then run that probe.  This script deliberately does not build, sign,
# start, stop, or otherwise manage Morbstack: the evidence owner brings an
# already-running disposable engine and an already-installed, locked client
# probe.  See docs/ecosystem-acceptance.md.

set -eu

usage() {
    cat >&2 <<'EOF'
usage: scripts/ecosystem-acceptance.sh <suite> -- <locked probe command...>

suites:
  testcontainers-node    Direct DOCKER_HOST, no Ryuk socket override
  testcontainers-python  Direct DOCKER_HOST, no Ryuk socket override
  testcontainers-java    Direct DOCKER_HOST, no Ryuk socket override
  testcontainers-go      Direct DOCKER_HOST, no Ryuk socket override
  devcontainers-cli      Isolated Docker context, no Docker host override

required environment:
  MORBSTACK_HOME         Absolute, dedicated, already-running Morbstack home
  MORBSTACK_DOCKER_BIN   Candidate Docker CLI (defaults to dist/Morbstack.app)

The script creates and removes an isolated DOCKER_CONFIG. It never creates,
starts, stops, or deletes the engine named by MORBSTACK_HOME.
EOF
    exit 2
}

fail() {
    printf 'ecosystem acceptance: %s\n' "$*" >&2
    exit 2
}

[ "$#" -ge 3 ] || usage
SUITE=$1
shift
[ "${1:-}" = "--" ] || usage
shift
[ "$#" -gt 0 ] || usage

case "$SUITE" in
    testcontainers-node|testcontainers-python|testcontainers-java|testcontainers-go|devcontainers-cli) ;;
    *) fail "unknown suite: $SUITE" ;;
esac

: "${MORBSTACK_HOME:?set MORBSTACK_HOME to a dedicated, already-running engine home}"
case "$MORBSTACK_HOME" in
    /*) ;;
    *) fail "MORBSTACK_HOME must be an absolute path (use a short /tmp/mb-* path)" ;;
esac

SOCKET="$MORBSTACK_HOME/run/docker.sock"
[ "${#SOCKET}" -lt 104 ] || fail "socket path is too long for Darwin sockaddr_un: $SOCKET"
[ -S "$SOCKET" ] || fail "no ready Morbstack Docker socket at $SOCKET; start the dedicated engine first"

# CDPATH='' (not the bare `CDPATH= cd` idiom, which trips shellcheck SC1007)
# keeps a user's exported CDPATH from redirecting the cd.
REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
DOCKER_BIN=${MORBSTACK_DOCKER_BIN:-"$REPO_ROOT/dist/Morbstack.app/Contents/Resources/host-bin/docker"}
[ -x "$DOCKER_BIN" ] || fail "candidate Docker CLI is not executable: $DOCKER_BIN"

# Never inherit a context, host override, credential helper, or plugin from the
# person's normal Docker installation. `mktemp` returns a directory we own; the
# EXIT trap removes only that exact directory.
DOCKER_CONFIG=$(mktemp -d "${TMPDIR:-/tmp}/mb-ecosystem-docker.XXXXXX")
export DOCKER_CONFIG
cleanup_config() {
    rm -rf "$DOCKER_CONFIG"
}
trap cleanup_config EXIT HUP INT TERM

unset DOCKER_HOST DOCKER_CONTEXT
CONTEXT="morbstack-acceptance-$$"
EXPECTED_HOST="unix://$SOCKET"

"$DOCKER_BIN" context create "$CONTEXT" --docker "host=$EXPECTED_HOST" >/dev/null
export DOCKER_CONTEXT="$CONTEXT"

ACTUAL_HOST=$("$DOCKER_BIN" context inspect "$CONTEXT" --format '{{(index .Endpoints "docker").Host}}')
[ "$ACTUAL_HOST" = "$EXPECTED_HOST" ] || fail "scratch context resolved $ACTUAL_HOST, expected $EXPECTED_HOST"
SERVER_VERSION=$("$DOCKER_BIN" version --format '{{.Server.Version}}')

# A command invoked through this wrapper can attach a unique label to resources
# it creates. The wrapper intentionally does not make Docker objects itself and
# cannot safely infer how a third-party Testcontainers/Dev Containers probe cleans
# up, so cleanup remains explicit in that locked probe.
MORBSTACK_ECOSYSTEM_RUN_ID="${SUITE}-$$"
MORBSTACK_ECOSYSTEM_LABEL="dev.morbstack.acceptance=$MORBSTACK_ECOSYSTEM_RUN_ID"
export MORBSTACK_ECOSYSTEM_RUN_ID MORBSTACK_ECOSYSTEM_LABEL

case "$SUITE" in
    testcontainers-node|testcontainers-java|testcontainers-go)
        # These clients do not reliably read Docker CLI contexts. Keep the
        # context preflight above as provenance evidence, then use their documented
        # direct endpoint.
        #
        # TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE is deliberately NOT set (and is
        # unset below): the engine now rewrites a bind mount of its own Mac-side
        # socket to the guest's /var/run/docker.sock (DockerBindMountPreflight),
        # so Ryuk works with no override. Setting it here would hide a
        # regression in exactly the path this suite exists to prove.
        unset DOCKER_CONTEXT TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE
        export DOCKER_HOST="$EXPECTED_HOST"
        ;;
    testcontainers-python)
        # Testcontainers Python delegates client construction to docker-py's
        # `from_env`, which reads DOCKER_HOST rather than Docker CLI contexts.
        # Keep the context preflight as evidence that the bundled CLI reaches
        # this engine, then exercise Python's actual discovery path. As above,
        # no Ryuk socket override: the engine's socket rewrite makes it moot.
        unset DOCKER_CONTEXT TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE
        export DOCKER_HOST="$EXPECTED_HOST"
        ;;
    devcontainers-cli)
        # The Dev Containers CLI shells out to Docker. Prove context discovery,
        # rather than hiding it under a host override.
        unset DOCKER_HOST
        unset TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE
        ;;
esac

printf '%s\n' "ecosystem acceptance suite=$SUITE server=$SERVER_VERSION"
printf '%s\n' "  socket=$SOCKET"
printf '%s\n' "  docker-config=$DOCKER_CONFIG (temporary)"
printf '%s\n' "  docker-context=${DOCKER_CONTEXT:-<not used by this client>}"
printf '%s\n' "  docker-host=${DOCKER_HOST:-<not set>}"
printf '%s\n' "  testcontainers-socket=${TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE:-<not set>}"
printf '%s\n' "  resource-label=$MORBSTACK_ECOSYSTEM_LABEL"

"$@"
