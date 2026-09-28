#!/usr/bin/env bash
# End-to-end proof that the game client and the backend agree on a save round-trip.
# Spins up a throwaway server on a private data dir, points Godot at it, tears it down.
# Fails closed: if the server never answers, or Godot reports any FAIL, this exits non-zero.
set -uo pipefail
cd "$(dirname "$0")/.."
. Pipeline/gates.sh

: "${GODOT:=/d/徐浩然/2026-08-29-21-56-21/.tools/Godot441_console.exe}"
PORT="${PORT:-8799}"
DATA="$(mktemp -d 2>/dev/null || echo ./Pipeline/logs/backend-sync-data)"
mkdir -p Pipeline/logs
LOG="Pipeline/logs/backend_sync.log"

command -v node >/dev/null 2>&1 || { echo "GATE-FAIL  未找到 node"; exit 1; }
[ -x "$GODOT" ] || [ -f "$GODOT" ] || { echo "GATE-FAIL  未找到 Godot（用 GODOT=<path> 指定）"; exit 1; }

# --exit-after is the reliable teardown: a backgrounded child survives `kill` under Git Bash
# on Windows, and stray servers contaminated a later performance run.
node backend/server.mjs --port "$PORT" --data "$DATA" --exit-after 240000 \
  >"Pipeline/logs/backend_sync_server.log" 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; rm -rf "$DATA"' EXIT

for _ in $(seq 1 40); do
  curl -fsS "http://127.0.0.1:$PORT/v1/ugc/browse" >/dev/null 2>&1 && break
  sleep 0.5
done
if ! curl -fsS "http://127.0.0.1:$PORT/v1/ugc/browse" >/dev/null 2>&1; then
  echo "GATE-FAIL  后端未能在 20 秒内应答"; cat "Pipeline/logs/backend_sync_server.log"; exit 1
fi

"$GODOT" --headless --path . -- "--backend=http://127.0.0.1:$PORT" --backend-sync-test >"$LOG" 2>&1
grep -E "^\[backend\]|^\[sync\]" "$LOG"
grep -q "backend sync test: PASS" "$LOG" || { echo "GATE-FAIL  客户端-后端往返不一致"; exit 1; }
echo "backend-sync: PASS"
