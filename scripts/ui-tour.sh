#!/usr/bin/env bash
# ui-tour.sh — launch Morbstack for a UI click-through.
#
# Companion to the `ui-tour` agent workflow: this script only gets the app on
# screen in a known state; a computer-use agent does the clicking and capturing.
# Kept deliberately dumb so it stays correct as the UI grows.
#
#   ./scripts/ui-tour.sh                      # containers, dark, 1440x900
#   ./scripts/ui-tour.sh disk light 1600x1000
#   ./scripts/ui-tour.sh --fixtures           # populated UI with no engine
#   ./scripts/ui-tour.sh --stop               # close any running instance
#
# Views: containers stacks images volumes networks builds kubernetes disk
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="${REPO}/dist/Morbstack.app"
BIN="${BUNDLE}/Contents/MacOS/MorbstackApp"

stop_app() {
	# Kill by exact binary path so we never touch an unrelated process.
	pkill -f "^${BIN}" 2>/dev/null || true
	sleep 1
}

if [ "${1:-}" = "--stop" ]; then
	stop_app
	echo "stopped"
	exit 0
fi

FIXTURES=""
if [ "${1:-}" = "--fixtures" ]; then
	FIXTURES="--tour-fixtures"
	shift
fi

VIEW="${1:-containers}"
APPEARANCE="${2:-dark}"
SIZE="${3:-1440x900}"
# Anything past the first three positional args is forwarded verbatim to the app
# as extra `--tour-*` switches (`--tour-container`, `--tour-tab`,
# `--tour-open-terminal`, `--tour-project-logs`) — the deep-link surfaces that
# route selection alone cannot reach. Kept to a plain pass-through, not a second
# copy of `LaunchOptions`' parsing, so this script does not need to change again
# the next time that contract grows.
EXTRA_ARGS=("${@:4}")

if [ ! -x "$BIN" ]; then
	echo "error: ${BUNDLE} not built." >&2
	echo "Run 'mise run app' first (do NOT run it while another agent is building)." >&2
	exit 1
fi

stop_app

# -n forces a new instance even if one is already registered.
open -n "$BUNDLE" --args \
	--tour-select "$VIEW" \
	--appearance "$APPEARANCE" \
	--window-size "$SIZE" \
	$FIXTURES \
	${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}

# Give SwiftUI time to lay out, and the window-rescue delegate time to run its
# retry sweeps (0.35/0.9/1.5s) on machines with wedged restoration state.
sleep 4

if pgrep -f "^${BIN}" >/dev/null; then
	echo "running: view=${VIEW} appearance=${APPEARANCE} size=${SIZE}${FIXTURES:+ fixtures}"
else
	echo "error: app exited immediately — check Console.app for a crash report" >&2
	exit 1
fi
