#!/usr/bin/env bash
# Records one knights-archers episode as a .replay fixture, using the real
# entrypoints — the same game binary and the same seat registrar the production
# image runs, so a recording can never drift from what the platform plays.
#
#   tools/record_fixture.sh <out.replay> <seed> [maxTicks] [extraConfigJson]
#
# The recorded bytes are what `tools/replay_summary.py` reads and what the
# static wasm bundle plays back.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$1"; SEED="$2"; MAXTICKS="${3:-2304}"; EXTRA="${4:-}"; PORT="${PORT:-21000}"
[ -z "$EXTRA" ] && EXTRA='{}'

BIN="${BIN:-./knights-archers}"
PLAYER_BIN="${PLAYER_BIN:-./knights-archers-player}"
if [ ! -x "$BIN" ]; then
  nim c -d:release --path:src --out:"$BIN" src/knights_archers.nim
fi
if [ ! -x "$PLAYER_BIN" ]; then
  nim c -d:release --path:src --out:"$PLAYER_BIN" src/knights_archers_player.nim
fi

CFG=$(mktemp /tmp/knights-archers-fixture-cfg-$$-XXXXXX)
python3 - "$CFG" "$SEED" "$MAXTICKS" "$EXTRA" <<'PY'
import json, sys
cfg = json.load(open("config.json"))
cfg["seed"] = int(sys.argv[2])
cfg["maxTicks"] = int(sys.argv[3])
cfg["turnSpacingMs"] = 0
cfg.update(json.loads(sys.argv[4]))
json.dump(cfg, open(sys.argv[1], "w"))
PY

LOG="${LOG:-/tmp/knights-archers-fixture-$$.log}"
COGAME_HOST=127.0.0.1 COGAME_PORT=$PORT \
COGAME_CONFIG_URI="file://$CFG" \
COGAME_SAVE_REPLAY_URI="file://$PWD/$OUT" \
"$BIN" > "$LOG" 2>&1 &
SERVER_PID=$!

# Wait for the port to actually listen before starting seats: a slow start
# would otherwise strand them and hang the lobby forever, silently.
for _ in $(seq 1 60); do
  (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && break
  if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "server died during startup; log tail:" >&2
    tail -20 "$LOG" >&2
    exit 1
  fi
  sleep 0.5
done

SEAT_PIDS=()
for i in $(seq 0 3); do
  PLAYER_SCRIPTED="${PLAYER_SCRIPTED:-phalanx}" \
  COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$PORT/player?slot=$i&token=0xBADA55_$i" \
    "$PLAYER_BIN" >/dev/null 2>&1 &
  SEAT_PIDS+=($!)
done

# Bounded wait: the engine's own wall-clock stop is 690 s, so anything past
# 900 s is a hang, and hangs must be loud rather than silent.
DEADLINE=$((SECONDS + 900))
while kill -0 $SERVER_PID 2>/dev/null; do
  if [ $SECONDS -ge $DEADLINE ]; then
    echo "server still running after 15 minutes — killing; log tail:" >&2
    tail -20 "$LOG" >&2
    kill $SERVER_PID 2>/dev/null || true
    for p in "${SEAT_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
    exit 1
  fi
  sleep 2
done
wait $SERVER_PID || { echo "server exited non-zero; log tail:" >&2; tail -20 "$LOG" >&2; }
for p in "${SEAT_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
rm -f "$CFG"

SIZE=$(stat -c%s "$OUT" 2>/dev/null || stat -f%z "$OUT" 2>/dev/null || echo 0)
if [ "$SIZE" -lt 10000 ]; then
  echo "replay missing or truncated ($SIZE bytes); server log tail:" >&2
  tail -20 "$LOG" >&2
  exit 1
fi
ls -la "$OUT"
