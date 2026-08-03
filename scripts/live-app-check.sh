#!/bin/sh
# Copyright 2026 The Morbstack Authors.
# Licensed under the Apache License, Version 2.0 (the "License").
#
# Run the app's data layer against the real engine.
#
# Builds nothing and starts nothing: the engine must already be up, because a script
# that boots a VM behind your back is exactly the sort of thing that leaves an orphaned
# daemon holding a disk image when it fails halfway. Bring the engine up yourself —
#
#     mise run sign && mac/.build/debug/morbstackd --foreground     # in its own terminal
#     mac/.build/debug/morb start
#
# — and then run this. It puts a small workload in place, runs the `MorbLive` harness
# against it, prints the PASS/FAIL table, and removes what it created.
#
# Fixtures are *reused* when they are already there and already match, rather than
# rebuilt every run. Two reasons. Pulling and recreating an nginx container to ask the
# same twelve questions of it is a minute of wall time per run, which is enough to
# discourage running the check. And the interesting fixture is the exited one: recreating
# it throws away its exit code and its age, both of which the list screen renders and
# this harness asserts on. Reuse is conditional on the container still matching the spec
# below — image, compose labels, port binding, mount, and for the logger a hash of its
# command — because silently checking against a fixture from an older version of this
# script is worse than the minute it saves. `--recreate` forces the long way round.
#
# A plain run still removes the workload at the end, so the engine is left as it was
# found; reuse is what makes the *next* run cheap after `--keep`, and what lets a run
# interrupted halfway pick up the fixtures it left behind instead of rebuilding them.
#
# Everything here is foreground and sequential. No `nohup`, no `&`, no sleep-and-hope:
# each step's own exit status is the signal that it finished.
#
# Usage:
#   scripts/live-app-check.sh              # reuse or create workload, check, tear down
#   scripts/live-app-check.sh --keep       # leave the workload up afterwards
#   scripts/live-app-check.sh --recreate   # rebuild the fixtures even if they match
#   scripts/live-app-check.sh --teardown   # only remove the workload, then exit

set -eu

PREFIX="${MORBLIVE_PREFIX:-morbshot}"
WEB="$PREFIX-web"
LOGGER="$PREFIX-logger"
EXITED="$PREFIX-exit"
VOLUME="$PREFIX-vol"
PROJECT="$PREFIX"

# The published port the web fixture binds. Parameterised alongside MORBLIVE_PREFIX:
# a second fixture namespace is useless if both namespaces fight over one host port,
# and "port is already allocated" is a confusing way to learn that.
PORT="${MORBLIVE_PORT:-18080}"

NGINX_IMAGE="${MORBLIVE_NGINX_IMAGE:-nginx:alpine}"
ALPINE_IMAGE="${MORBLIVE_ALPINE_IMAGE:-alpine:latest}"

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD_DIR="$REPO_ROOT/mac/.build/debug"
MORB="$BUILD_DIR/morb"
MORBLIVE="$BUILD_DIR/MorbLive"
SOCKET="${MORBSTACK_HOME:-$HOME/.morbstack}/run/docker.sock"

MODE=check
RECREATE=0
for argument in "$@"; do
  case "$argument" in
    --keep) MODE=keep ;;
    --teardown) MODE=teardown ;;
    --recreate) RECREATE=1 ;;
    *) echo "usage: $0 [--keep] [--recreate] | $0 --teardown" >&2; exit 2 ;;
  esac
done

# The user's own ~/.docker is off limits: it configures a `credsStore` that hangs when
# no Docker Desktop is running, and every `docker` call below would block on it. A
# throwaway config directory is both the fix and the guarantee that this script cannot
# perturb the user's real Docker setup.
DOCKER_CONFIG=$(mktemp -d "${TMPDIR:-/tmp}/morblive-dockercfg.XXXXXXXX")
export DOCKER_CONFIG
export DOCKER_HOST="unix://$SOCKET"

cleanup_config() {
  rm -rf "$DOCKER_CONFIG"
}
trap cleanup_config EXIT

say() { printf '\n=== %s\n' "$1"; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

[ -x "$MORB" ] || { echo "error: $MORB not built — run 'mise run build'" >&2; exit 1; }
[ -x "$MORBLIVE" ] || { echo "error: $MORBLIVE not built — run 'mise run build'" >&2; exit 1; }
[ -S "$SOCKET" ] || { echo "error: no engine socket at $SOCKET — start the daemon first" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "error: the docker CLI is not on PATH" >&2; exit 1; }

say "engine status"
# `morb status` never spawns a daemon, so this is a safe observation rather than a
# side effect. If it says anything but running, stop here: every check below would
# fail for the same uninteresting reason.
"$MORB" status
"$MORB" status --json | grep -q '"docker_ready" *: *true' || {
  echo "error: dockerd is not ready inside the guest yet — wait for 'morb status' to say so" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Teardown, used both to clean up afterwards and to clear a stale run first
# ---------------------------------------------------------------------------

teardown() {
  say "teardown"
  # `|| true` per line rather than around the group: a fixture that was never created
  # must not stop the rest from being removed.
  docker rm -f "$WEB" >/dev/null 2>&1 || true
  docker rm -f "$LOGGER" >/dev/null 2>&1 || true
  docker rm -f "$EXITED" >/dev/null 2>&1 || true
  docker volume rm -f "$VOLUME" >/dev/null 2>&1 || true
  echo "removed $WEB, $LOGGER, $EXITED, $VOLUME"
}

if [ "$MODE" = teardown ]; then
  teardown
  exit 0
fi

# ---------------------------------------------------------------------------
# Workload
# ---------------------------------------------------------------------------

if [ "$RECREATE" = 1 ]; then
  teardown
fi

say "images"
for image in "$NGINX_IMAGE" "$ALPINE_IMAGE"; do
  if docker image inspect "$image" >/dev/null 2>&1; then
    echo "have $image"
  else
    echo "pulling $image"
    docker pull "$image"
  fi
done

say "workload"

# Does a container by this name exist at all, in any state?
exists() { docker inspect --type container "$1" >/dev/null 2>&1; }

# One `docker inspect -f` field, or the empty string. Command substitution strips the
# trailing newline, so both sides of every comparison below are stripped the same way.
field() { docker inspect -f "$2" "$1" 2>/dev/null || true; }

# Reuse or rebuild one container. `$1` name, `$2` the spec it must currently match,
# `$3` how to read that spec back off the running object.
#
# Returns 0 when the caller still has to create it, 1 when it is already right. The
# inverted sense reads oddly but keeps the call sites to a single `if`.
needs_create() {
  name=$1
  wanted=$2
  template=$3
  exists "$name" || return 0
  actual=$(field "$name" "$template")
  if [ "$actual" = "$wanted" ]; then
    echo "reusing $name"
    return 1
  fi
  echo "recreating $name — spec drifted"
  echo "  want: $wanted"
  echo "  have: $actual"
  docker rm -f "$name" >/dev/null 2>&1 || true
  return 0
}

if docker volume inspect "$VOLUME" >/dev/null 2>&1; then
  echo "reusing volume $VOLUME"
else
  docker volume create "$VOLUME" >/dev/null
  echo "created volume $VOLUME"
fi

# A published port and compose labels: the labels are applied by hand rather than by
# `docker compose` on purpose — the app reads attribution from these three labels and
# nothing else, so setting them directly tests exactly what the sidebar depends on
# without making the harness depend on a compose binary.
WEB_SPEC="$NGINX_IMAGE|$PROJECT|web|80/tcp=$PORT|$VOLUME:/morbshot"
WEB_TEMPLATE='{{.Config.Image}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{range $p, $b := .HostConfig.PortBindings}}{{$p}}={{range $b}}{{.HostPort}}{{end}}{{end}}|{{range .Mounts}}{{.Name}}:{{.Destination}}{{end}}'

if needs_create "$WEB" "$WEB_SPEC" "$WEB_TEMPLATE"; then
  docker run -d \
    --name "$WEB" \
    --label com.docker.compose.project="$PROJECT" \
    --label com.docker.compose.service=web \
    --label com.docker.compose.config-hash=morblive \
    -p "$PORT":80 \
    -v "$VOLUME":/morbshot \
    "$NGINX_IMAGE" >/dev/null
  echo "started $WEB on 127.0.0.1:$PORT"
else
  # A reused container is stopped after a VM restart, and the harness needs it up.
  # `docker start` on an already-running container is a no-op, not an error.
  docker start "$WEB" >/dev/null
  echo "started $WEB on 127.0.0.1:$PORT"
fi

# The log fixture. Three things matter about what it prints:
#
#   * SGR colour, so the harness can prove escape sequences survive the pipeline;
#   * a numbered tick, so a byte dropped or duplicated at a chunk boundary shows up as
#     a gap in the sequence rather than as output that merely looks plausible;
#   * every third line, 20 000 filler characters — comfortably more than arrives in one
#     read — so stdcopy frame reassembly across reads is exercised, and every fourth
#     line on stderr, so the demultiplexer has two streams to keep apart.
#
# No single quotes anywhere in LOGGER_CMD: it is passed through one layer of shell
# quoting here and another inside the container.
LOGGER_CMD='s=x; while [ ${#s} -lt 20000 ]; do s=$s$s; done;
i=0
while :; do
  i=$((i+1))
  printf "\033[32m[morbshot] tick %s\033[0m\n" "$i"
  if [ $((i % 4)) -eq 0 ]; then printf "\033[31m[morbshot] err %s\033[0m\n" "$i" >&2; fi
  if [ $((i % 3)) -eq 0 ]; then printf "[morbshot] long %s %.20000s\n" "$i" "$s"; fi
  sleep 1
done'

# The logger's identity is its command, so that is what reuse turns on: image and
# labels are not enough, because a fixture built by an older version of this script
# prints a different sequence and the log assertions would fail against it for reasons
# that have nothing to do with the app. Both sides of the comparison go through
# `shasum` the same way — `docker inspect -f` emits a trailing newline and so does
# `printf '%s\n'` — which keeps a multi-line command comparable without quoting it twice.
LOGGER_CMD_SHA=$(printf '%s\n' "$LOGGER_CMD" | shasum | cut -d' ' -f1)
LOGGER_SPEC="$ALPINE_IMAGE|$PROJECT|logger|$LOGGER_CMD_SHA"
LOGGER_TEMPLATE='{{.Config.Image}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}'

logger_actual() {
  printf '%s|%s' \
    "$(field "$LOGGER" "$LOGGER_TEMPLATE")" \
    "$(field "$LOGGER" '{{index .Config.Cmd 2}}' | shasum | cut -d' ' -f1)"
}

if exists "$LOGGER" && [ "$(logger_actual)" = "$LOGGER_SPEC" ]; then
  echo "reusing $LOGGER"
  docker start "$LOGGER" >/dev/null
else
  if exists "$LOGGER"; then
    echo "recreating $LOGGER — its command no longer matches this script's"
    docker rm -f "$LOGGER" >/dev/null 2>&1 || true
  fi
  docker run -d \
    --name "$LOGGER" \
    --label com.docker.compose.project="$PROJECT" \
    --label com.docker.compose.service=logger \
    "$ALPINE_IMAGE" sh -c "$LOGGER_CMD" >/dev/null
fi
echo "started $LOGGER"

# The exited fixture, deliberately *not* compose-labelled so the standalone bucket in
# `groupedByComposeProject()` has something in it. Started and then stopped rather than
# `docker create`d, because `created` and `exited` are different states and the list
# screen renders them differently.
#
# Reused as-is when it is already there and already exited — including its exit code and
# its age, which the list screen renders and which recreating would reset. The harness
# starts and stops it itself to make the events check something happens; that leaves it
# exited again, so a reused one is in the right state by construction.
EXIT_SPEC="$ALPINE_IMAGE|sleep 300 "
EXIT_TEMPLATE='{{.Config.Image}}|{{range .Config.Cmd}}{{.}} {{end}}'

if needs_create "$EXITED" "$EXIT_SPEC" "$EXIT_TEMPLATE"; then
  docker run -d --name "$EXITED" "$ALPINE_IMAGE" sleep 300 >/dev/null
  docker stop -t 1 "$EXITED" >/dev/null
  echo "created $EXITED and stopped it"
elif [ "$(field "$EXITED" '{{.State.Running}}')" = true ]; then
  # Left running by an interrupted run; the list screen needs it exited.
  docker stop -t 1 "$EXITED" >/dev/null
  echo "stopped $EXITED"
fi

say "container inventory"
docker ps -a --filter "name=$PREFIX-" --format 'table {{.Names}}\t{{.State}}\t{{.Ports}}'

# ---------------------------------------------------------------------------
# The harness
# ---------------------------------------------------------------------------

say "MorbLive"
set +e
MORBLIVE_PREFIX="$PREFIX" MORBLIVE_PORT="$PORT" MORBLIVE_SOCKET="$SOCKET" \
  MORB_BIN="$MORB" "$MORBLIVE"
STATUS=$?
set -e

if [ "$MODE" = keep ]; then
  say "workload left running (--keep); remove it with $0 --teardown"
else
  teardown
fi

exit "$STATUS"
