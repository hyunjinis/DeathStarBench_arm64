
#!/usr/bin/env bash
set -Eeuo pipefail

# Configuration
URL="${URL:-http://192.168.0.8:30001/}"
WRK2="${WRK2:-$HOME/DeathStarBench/socialNetwork/wrk2/wrk}"
LUA="${LUA:-$HOME/DeathStarBench/socialNetwork/wrk2/scripts/social-network/mixed-workload.lua}"
SSH_TARGET="${SSH_TARGET:-rpi2@192.168.0.8}"

RATE="${RATE:-500}"
THREADS="${THREADS:-24}"
CONNS="${CONNS:-24}"
DURATION="${DURATION:-30}"
REPEAT="${REPEAT:-10}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-5}"

OUTDIR="${OUTDIR:-$HOME/micro_wrk2_${RATE}rps_$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"

[[ -x "$WRK2" ]] || { echo "[ERR] wrk2 not found: $WRK2"; exit 1; }
[[ -r "$LUA" ]] || { echo "[ERR] Lua script not found: $LUA"; exit 1; }

# Verify remote CPU monitoring.
ssh -o BatchMode=yes -o ConnectTimeout=5 \
  "$SSH_TARGET" 'LC_ALL=C mpstat -P ALL 1 1 >/dev/null' \
  || { echo "[ERR] Remote mpstat unavailable"; exit 1; }

printf 'url=%s\nrate=%s\nthreads=%s\nconnections=%s\nduration=%s\nrepeats=%s\nlua=%s\n' \
  "$URL" "$RATE" "$THREADS" "$CONNS" "$DURATION" "$REPEAT" "$LUA" \
  > "$OUTDIR/config.txt"

# Preflight: 15 seconds to accommodate wrk2 calibration.
echo "[CHECK] wrk2 preflight"

"$WRK2" -t1 -c1 -d15s -R50 -L \
  -s "$LUA" "$URL" \
  > "$OUTDIR/preflight.txt" 2>&1 \
  || { cat "$OUTDIR/preflight.txt"; exit 1; }

if grep -Eq 'Non-2xx or 3xx responses: [1-9]|Socket errors:.*[1-9]' \
  "$OUTDIR/preflight.txt"; then
  cat "$OUTDIR/preflight.txt"
  echo "[ERR] Preflight HTTP/socket errors"
  exit 1
fi

cat "$OUTDIR/preflight.txt"

echo 'run,wrk2_exit,mpstat_exit,requests,samples,status' \
  > "$OUTDIR/run_status.csv"

echo 'run,latency_us,count' \
  > "$OUTDIR/latency_hist_all.csv"

for ((i=1; i<=REPEAT; i++)); do
  echo "========== WRK2 RUN $i/$REPEAT =========="

  RUNDIR="$OUTDIR/run${i}"
  mkdir -p "$RUNDIR"

  ssh -o BatchMode=yes -o ConnectTimeout=5 \
    "$SSH_TARGET" 'LC_ALL=C mpstat -P ALL 10 3' \
    > "$RUNDIR/mpstat.log" 2>&1 &
  MP_PID=$!

  set +e
  (
    cd "$RUNDIR"
    "$WRK2" \
      -t"$THREADS" \
      -c"$CONNS" \
      -d"${DURATION}s" \
      -R"$RATE" \
      -L -P \
      -s "$LUA" \
      "$URL"
  ) > "$RUNDIR/wrk2.log" 2>&1
  WRK_EXIT=$?

  wait "$MP_PID"
  MP_EXIT=$?
  set -e

  cat "$RUNDIR/wrk2.log"

  if (( WRK_EXIT != 0 || MP_EXIT != 0 )) || \
     grep -Eq 'Non-2xx or 3xx responses: [1-9]|Socket errors:.*[1-9]' \
       "$RUNDIR/wrk2.log"; then
    echo "$i,$WRK_EXIT,$MP_EXIT,0,0,INVALID" \
      >> "$OUTDIR/run_status.csv"
    echo "[ERR] Run $i failed"
    exit 1
  fi

  # Aggregate raw per-thread latency files into a histogram.
  python3 - "$RUNDIR" "$OUTDIR/latency_hist_all.csv" "$i" <<'PY'
from collections import Counter
from pathlib import Path
import csv
import sys

run_dir = Path(sys.argv[1])
output = Path(sys.argv[2])
run = int(sys.argv[3])

hist = Counter()
files = list(run_dir.glob("[0-9]*.txt"))

if not files:
    raise SystemExit("[ERR] No wrk2 -P latency files")

for file in files:
    with file.open() as f:
        for line in f:
            line = line.strip()
            if line:
                value = int(line)
                if value >= 0:
                    hist[value] += 1

if not hist:
    raise SystemExit("[ERR] Empty wrk2 histogram")

with output.open("a", newline="") as f:
    writer = csv.writer(f)
    for latency, count in sorted(hist.items()):
        writer.writerow([run, latency, count])

print(f"[INFO] Histogram samples: {sum(hist.values())}")
PY

  REQS=$(awk '/ requests in / {print $1; exit}' "$RUNDIR/wrk2.log")
  REQS="${REQS:-0}"

  SAMPLES=$(awk -F, -v run="$i" \
    '$1==run {total+=$3} END {printf "%.0f", total+0}' \
    "$OUTDIR/latency_hist_all.csv")

  echo "$i,$WRK_EXIT,$MP_EXIT,$REQS,$SAMPLES,OK" \
    >> "$OUTDIR/run_status.csv"

  if (( i < REPEAT )); then
    sleep "$SLEEP_BETWEEN"
  fi
done

echo "[DONE] $OUTDIR"
