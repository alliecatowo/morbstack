#!/usr/bin/env bash
# run-perf-matrix.sh — run a list of PerfProbe shapes, several fresh processes
# each, and print one row per shape.
#
#   ./run-perf-matrix.sh reps < specs.txt
#   printf '%s\n' "a=1" "b=2" | ./run-perf-matrix.sh 5
#
# Reps are INTERLEAVED (rep-major, not spec-major) because the first reveal in a
# freshly launched process gets cheaper as the machine warms: measured 523ms,
# then 362ms, then 92/61/47ms across consecutive launches of the same binary.
# Running all reps of one spec before the next would hand the later specs a
# warmer machine and manufacture a difference that is not there.
#
# Each line of stdin is a `--perf` spec. Blank lines and `#` comments are skipped.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPS="${1:-5}"
CYCLES="${CYCLES:-4}"
SETTLE="${SETTLE:-2.5}"
WORK="$(mktemp -d /tmp/mb-perfmx.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# `mapfile` is bash 4; /bin/bash on macOS is 3.2.
SPECS=()
while IFS= read -r line; do
	case "$line" in "" | \#*) continue ;; esac
	SPECS+=("$line")
done
echo "specs: ${#SPECS[@]}  reps: $REPS  cycles: $CYCLES" >&2

# Build once, up front, so no rep pays for a compile.
"$HERE/run-perf.sh" "detail=text,insp=none,tb=none" --cycles 0 --settle 0.2 >/dev/null 2>&1 || true

for ((r = 1; r <= REPS; r++)); do
	for i in "${!SPECS[@]}"; do
		echo "  rep $r/$REPS  spec $((i + 1))/${#SPECS[@]}" >&2
		"$HERE/run-perf.sh" "${SPECS[$i]}" --cycles "$CYCLES" --settle "$SETTLE" \
			>>"$WORK/spec-$i.log" 2>/dev/null || true
	done
done

printf '%-52s %9s %9s %9s %8s %8s\n' \
	"spec" "lead1" "leadN" "hide1" "frames%" "cpu"
for i in "${!SPECS[@]}"; do
	python3 - "$WORK/spec-$i.log" "${SPECS[$i]}" <<'PY'
import re, sys, statistics
log, spec = sys.argv[1], sys.argv[2]
rows = []
pat = re.compile(r'^(reveal|hide)#(\d+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+(\d+)\s+(\d+)/(\d+)\s+([\d.]+)')
for line in open(log):
    m = pat.match(line)
    if m:
        rows.append(dict(dir=m.group(1), n=int(m.group(2)), lead=float(m.group(3)),
                         seen=int(m.group(7)), exp=int(m.group(8)), cpu=float(m.group(9))))
def med(v): return statistics.median(v) if v else float('nan')
lead1 = med([r['lead'] for r in rows if r['dir'] == 'reveal' and r['n'] == 1])
leadN = med([r['lead'] for r in rows if r['dir'] == 'reveal' and r['n'] > 1])
hide1 = med([r['lead'] for r in rows if r['dir'] == 'hide' and r['n'] == 1])
fr = [100 * r['seen'] / r['exp'] for r in rows if r['exp'] and r['n'] > 1]
cpu = med([r['cpu'] for r in rows if r['n'] > 1])
print('%-52s %9.1f %9.1f %9.1f %7.0f%% %8.1f' % (spec[:52], lead1, leadN, hide1, med(fr), cpu))
PY
done
