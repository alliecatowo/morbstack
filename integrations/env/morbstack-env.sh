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

# Testcontainers (all languages) computes the socket path it bind-mounts
# into Ryuk/DinD-style helper containers from DOCKER_HOST unless this is
# set. Since DOCKER_HOST above is a Mac-side path that does not exist
# inside the guest VM's filesystem, that bind mount fails (HTTP 500,
# "operation not supported") without this override. The guest's own
# dockerd always listens on /var/run/docker.sock inside the guest — that
# is the correct value here, not a Morbstack-specific path. See
# ecosystem.md, Testcontainers section, for the verified repro/fix.
if [ -S "$sock" ]; then
    echo "export TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock"
    echo "# morbstack-env: TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE -> /var/run/docker.sock (in-guest path, see ecosystem.md)" >&2
fi

if [ -f "$kubeconfig" ]; then
    echo "export KUBECONFIG=$kubeconfig"
    echo "# morbstack-env: KUBECONFIG -> $kubeconfig" >&2
else
    echo "# morbstack-env: no kubeconfig at $kubeconfig — run 'morb k8s enable' first if you need it" >&2
fi
