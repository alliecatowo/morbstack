#!/bin/sh
# morbstack-env.sh — print export statements for the environment variables
# that ecosystem tools which DO NOT read Docker CLI contexts need in order
# to find Morbstack. Intended usage:
#
#   eval "$(/Users/allie/Develop/morbstack/integrations/env/morbstack-env.sh)"
#
# or, once this repo is on PATH:
#
#   eval "$(morbstack-env.sh)"
#
# This script is NOT a replacement for `docker context create/use` — for the
# `docker` CLI itself (and anything else that honours contexts, see
# integrations/ecosystem.md), a context is the right, durable fix and this
# script deliberately does not create or touch one. This script exists for
# the tools that only ever look at DOCKER_HOST/KUBECONFIG/TESTCONTAINERS_*
# env vars and ignore contexts entirely (Tilt, act, the Go SDK's
# client.FromEnv, Testcontainers' socket-mount path, etc — see
# ecosystem.md for the per-tool breakdown of who reads what).
#
# All human-readable status output goes to stderr so `eval "$(...)"` only
# ever evaluates the export lines on stdout.

set -eu

morbstack_home="${MORBSTACK_HOME:-$HOME/.morbstack}"
sock="$morbstack_home/run/docker.sock"
kubeconfig="$morbstack_home/kubeconfig"

if [ -S "$sock" ]; then
    echo "export DOCKER_HOST=unix://$sock"
    echo "# morbstack-env: DOCKER_HOST -> $sock" >&2
else
    echo "# morbstack-env: WARNING: no socket at $sock — is the Morbstack engine running? (morb start)" >&2
fi

# TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE is intentionally no longer emitted
# (since ECO-2, 2026-08-04). Testcontainers bind-mounts the Mac-side
# DOCKER_HOST path into Ryuk/DinD helper containers, and the Morbstack
# engine now rewrites that exact daemon-socket source to the guest's
# /var/run/docker.sock itself (DockerBindMountPreflight), so the override
# is unnecessary against any current Morbstack. Exporting it anyway would
# be harmless against Morbstack but can misdirect the socket mount when
# the same shell later talks to a different engine. See
# docs/design/ZERO-CONFIG-DISCOVERY.md and ecosystem.md.

if [ -f "$kubeconfig" ]; then
    echo "export KUBECONFIG=$kubeconfig"
    echo "# morbstack-env: KUBECONFIG -> $kubeconfig" >&2
else
    echo "# morbstack-env: no kubeconfig at $kubeconfig — run 'morb k8s enable' first if you need it" >&2
fi
