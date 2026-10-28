#!/usr/bin/env bash
set -Eeuo pipefail

# DeathStarBench Social Network mixed workload client-side CDF.
# The exact API mix in the original IEEE IoT paper is not specified.
URL="${URL:-http://192.168.0.8:30001/}"
REQUEST_SCRIPT="${REQUEST_SCRIPT:-/home/oslab2/DeathStarBench/socialNetwork/wrk2/scripts/social-network/mixed-workload.lua}"
SSH_TARGET="${SSH_TARGET:-rpi2@192.168.0.8}" # change SSH user when needed
THREADS="${THREADS:-24}"
CONNS="${CONNS:-24}"
DURATION="${DURATION:-30}"
REPEAT="${REPEAT:-10}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-5}"
NS="social-network"
OUTDIR="${OUTDIR:-$HOME/micro_mixed_cdf_$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"

for bin in wrk ssh kubectl python3 awk grep; do
  command -v "$bin" >/dev/null || { echo "[ERR] Missing command: $bin"; exit 1; }
done
[[ -r "$REQUEST_SCRIPT" ]] || { echo "[ERR] Missing Lua: $REQUEST_SCRIPT"; exit 1; }

# Preserve original Lua and rewrite only its *absolute* request targets.
# The destination URL is provided by wrk's final CLI argument.
LUA="$OUTDIR/wrk_mixed_cdf.lua"
python3 - "$REQUEST_SCRIPT" "$LUA" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text(encoding='utf-8')
needle = 'http://localhost:8080/wrk2-api/'
count = source.count(needle)
if count not in (0, 3):
    raise SystemExit(f'[ERR] Unexpected absolute API path count: {count}')
source = source.replace(needle, '/wrk2-api/')
if 'request = function()' not in source:
    raise SystemExit('[ERR] Missing request() function in Lua.')
Path(sys.argv[2]).write_text(source + '\n', encoding='utf-8')
print(f'[INFO] Replaced {count} absolute Lua URLs with /wrk2-api/ paths.')
PY
cat >> "$LUA" <<'LUA'
-- Exports wrk's corrected client-side latency histogram in microseconds.
function done(summary, latency, requests)
  io.write("\nCDF_BEGIN\n")
  for i = 1, #latency do
    local us, count = latency(i)
    if us and count and count > 0 then
      io.write(string.format("CDF_BUCKET,%.0f,%.0f\n", us, count))
    end
  end
  io.write("CDF_END\n")
end
LUA

{
  printf 'URL=%s\n' "$URL"
  printf 'SCRIPT=%s\n' "$REQUEST_SCRIPT"
  printf 'PARAMS=threads:%s connections:%s duration:%ss repeats:%s\n' "$THREADS" "$CONNS" "$DURATION" "$REPEAT"
  printf 'MIX=home60%%,user30%%,compose10%%\n'
  printf 'HIST=wrk corrected client-side latency histogram (us)\n'
} > "$OUTDIR/config.txt"

kubectl get pods -n "$NS" -l name=nginx-thrift -o wide > "$OUTDIR/nginx_pod.txt" 2>&1 || true

# Fail closed: never collect an API-error CDF as valid data.
PREFLIGHT="$OUTDIR/preflight.txt"
echo "[CHECK] Mixed workload API preflight: 1 thread, 1 connection, 3s"
if ! wrk -t1 -c1 -d3s --latency -s "$LUA" "$URL" > "$PREFLIGHT" 2>&1; then
  awk '/^CDF_BEGIN$/{exit} {print}' "$PREFLIGHT"
  echo "[ERR] Preflight could not execute; see $PREFLIGHT"
  exit 1
fi
awk '/^CDF_BEGIN$/{exit} {print}' "$PREFLIGHT"
if grep -Eq '^  Non-2xx or 3xx responses: [1-9]|^  Socket errors:|^Non-2xx or 3xx responses: [1-9]|^Socket errors:' "$PREFLIGHT"; then
  echo "[ERR] Preflight returned HTTP/socket errors. Diagnose API/backends before benchmarking."
  exit 1
fi
if ! grep -q '^CDF_END$' "$PREFLIGHT" || ! grep -q '^CDF_BUCKET,' "$PREFLIGHT"; then
  echo "[ERR] No complete client-side CDF histogram in preflight."
  exit 1
fi

printf 'run,wrk_exit,mpstat_exit,requests,histogram_samples,buckets,status\n' > "$OUTDIR/run_status.csv"
printf 'run,latency_us,count\n' > "$OUTDIR/latency_hist_all.csv"
echo "[INFO] Output: $OUTDIR"
for ((i=1;i<=REPEAT;i++)); do
  echo "========== RUN $i/$REPEAT =========="
  WRK_LOG="$OUTDIR/wrk_run${i}.txt"
  CPU_LOG="$OUTDIR/mpstat_run${i}.log"
  HIST="$OUTDIR/latency_hist_run${i}.csv"

  ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_TARGET" 'LC_ALL=C mpstat -P ALL 10 3' > "$CPU_LOG" 2>&1 &
  MP_PID=$!
  set +e
  wrk -t"$THREADS" -c"$CONNS" -d"${DURATION}s" --latency -s "$LUA" "$URL" > "$WRK_LOG" 2>&1
  WRK_EXIT=$?
  wait "$MP_PID"
  MP_EXIT=$?
  set -e
  awk '/^CDF_BEGIN$/{exit} {print}' "$WRK_LOG"

  if (( WRK_EXIT != 0 )) || grep -Eq '^  Non-2xx or 3xx responses: [1-9]|^  Socket errors:|^Non-2xx or 3xx responses: [1-9]|^Socket errors:' "$WRK_LOG" || ! grep -q '^CDF_END$' "$WRK_LOG"; then
    printf '%d,%d,%d,0,0,0,INVALID\n' "$i" "$WRK_EXIT" "$MP_EXIT" >> "$OUTDIR/run_status.csv"
    echo "[ERR] Run $i has HTTP/socket/histogram errors; stopping. Data not merged. See $WRK_LOG"
    exit 1
  fi
  printf 'latency_us,count\n' > "$HIST"
  awk -F, '$1=="CDF_BUCKET" && $2~/^[0-9]+$/ && $3~/^[0-9]+$/ {print $2 "," $3}' "$WRK_LOG" >> "$HIST"
  COUNT=$(awk -F, 'NR>1 {s+=$2} END {printf "%.0f",s+0}' "$HIST")
  BUCKETS=$(awk 'END{print NR-1}' "$HIST")
  if (( BUCKETS == 0 )); then echo "[ERR] Empty histogram on run $i"; exit 1; fi
  REQS=$(awk '/ requests in / {print $1; exit}' "$WRK_LOG")
  REQS=${REQS:-0}
  awk -F, -v i="$i" 'NR>1 {print i "," $1 "," $2}' "$HIST" >> "$OUTDIR/latency_hist_all.csv"
  printf '%d,%d,%d,%s,%s,%s,OK\n' "$i" "$WRK_EXIT" "$MP_EXIT" "$REQS" "$COUNT" "$BUCKETS" >> "$OUTDIR/run_status.csv"
  echo "[INFO] run=$i requests=$REQS histogram_samples=$COUNT buckets=$BUCKETS mpstat_exit=$MP_EXIT"
  if (( i<REPEAT )); then sleep "$SLEEP_BETWEEN"; fi
done
kubectl get pods -n "$NS" -l name=nginx-thrift -o wide > "$OUTDIR/nginx_pod_after.txt" 2>&1 || true
echo "[DONE] Valid runs merged to $OUTDIR/latency_hist_all.csv"

