#!/usr/bin/env bash
# axpress-cost.sh — how much CPU a real toolbar click costs another process.
#
#   ./axpress-cost.sh <process-name> <AXIdentifier|#toolbar-index> [presses]
#
# Why CPU time and not a timer: PerfProbe can measure its own main-thread block
# because we compile it. The shipped app cannot be measured that way without
# rebuilding it, and rebuilding `dist/Morbstack.app` takes it away from whoever
# is using it. Cumulative process CPU is readable from outside with `ps`, at
# 10ms resolution, and a synchronous main-thread block of N ms burns N ms of
# CPU. Validated against PerfProbe, where the in-process meter gives ground
# truth for the same clicks.
#
# Reads Δcpu across each press. Interpret against the idle baseline it prints
# first, not against zero.
set -euo pipefail

PROC="${1:?usage: axpress-cost.sh <process> <AXIdentifier|#index> [presses]}"
TARGET="${2:?}"
PRESSES="${3:-6}"
SETTLE="${SETTLE:-0.9}"

pid="$(pgrep -x "$PROC" | head -1)"
[ -n "$pid" ] || { echo "no process named $PROC" >&2; exit 1; }

cpu() { ps -p "$pid" -o time= | tr -d ' ' | awk -F: '{s=0; for(i=1;i<=NF;i++) s=s*60+$i; print s}'; }

press() {
	if [[ "$TARGET" == \#* ]]; then
		osascript -e "tell application \"System Events\" to tell process \"$PROC\" to perform action \"AXPress\" of UI element ${TARGET#\#} of toolbar 1 of window 1" >/dev/null
	else
		osascript -e "
tell application \"System Events\" to tell process \"$PROC\"
  repeat with el in (entire contents of window 1)
    try
      if value of attribute \"AXIdentifier\" of el is \"$TARGET\" then
        perform action \"AXPress\" of el
        exit repeat
      end if
    end try
  end repeat
end tell" >/dev/null
	fi
}

a="$(cpu)"; sleep "$SETTLE"; b="$(cpu)"
printf 'idle baseline over %ss: %.2fs cpu\n' "$SETTLE" "$(echo "$b - $a" | bc -l)"
printf '%-8s %10s\n' press "dcpu(ms)"

for ((i = 1; i <= PRESSES; i++)); do
	a="$(cpu)"
	press
	sleep "$SETTLE"
	b="$(cpu)"
	printf '%-8s %10.0f\n' "$i" "$(echo "($b - $a) * 1000" | bc -l)"
done
