#!/usr/bin/env bash
# Phase 234: prove the shipping Godot client can talk to the shipping Node server.
#
# Pipeline step 10a runs a Node client that shares the server's own framing, so it can stay green
# while the game itself cannot connect — which is exactly what happened once. This script boots the
# real client under headless Godot against a real gateway + game server pair and fails closed if
# the handshake, the authority checks, or the teleport snap-back do not happen.
set -uo pipefail
cd "$(dirname "$0")/.."
. Pipeline/gates.sh

: "${GODOT:=/d/徐浩然/2026-08-29-21-56-21/.tools/Godot441_console.exe}"
GW_PORT="${GW_PORT:-28801}"
GS_PORT="${GS_PORT:-29877}"
DATA="$(mktemp -d 2>/dev/null || echo ./Pipeline/logs/mp-probe-data)"
LOG="Pipeline/logs/mp_probe.log"

command -v node >/dev/null 2>&1 || { echo "GATE-FAIL  未找到 node"; exit 1; }
[ -x "$GODOT" ] || [ -f "$GODOT" ] || { echo "GATE-FAIL  未找到 Godot（用 GODOT=<path> 指定）"; exit 1; }
mkdir -p Pipeline/logs

node backend/server.mjs --port "$GW_PORT" --data "$DATA" --exit-after 240000 \
  >"Pipeline/logs/mp_probe_gateway.log" 2>&1 &
GW=$!
GS_PORT="$GS_PORT" GS_DATA="$DATA" GS_EXIT_AFTER=240000 \
  node server/game_server.mjs >"Pipeline/logs/mp_probe_server.log" 2>&1 &
GS=$!
trap 'kill $GW $GS 2>/dev/null; rm -rf "$DATA"' EXIT

for _ in $(seq 1 40); do
  curl -fsS "http://127.0.0.1:$GW_PORT/v1/ugc/browse" >/dev/null 2>&1 && break
  sleep 0.5
done
if ! curl -fsS "http://127.0.0.1:$GW_PORT/v1/ugc/browse" >/dev/null 2>&1; then
  echo "GATE-FAIL  网关未能在 20 秒内应答"; cat "Pipeline/logs/mp_probe_gateway.log"; exit 1
fi
# The game server has no HTTP surface to poll; a short wait is enough for `listen` on loopback and
# a real failure shows up as a handshake timeout in the probe, not as a silent skip.
sleep 2

# A headless viewport has no rendered texture, so the eye-check mode has to run windowed.
# MP_SHOT is unset in CI and in the default gate run; it exists so "you can actually see the other
# player" can be verified by looking at a frame rather than only by a frustum test.
ARGS=("--backend=http://127.0.0.1:$GW_PORT" "--mp-server=127.0.0.1:$GS_PORT" "--mp-probe")
if [ -n "${MP_SHOT:-}" ]; then
  ARGS+=("--mp-shot=$MP_SHOT")
  "$GODOT" --path . --resolution 1280x720 -- "${ARGS[@]}" --quit-after 20000 >"$LOG" 2>&1
else
  "$GODOT" --headless --path . -- "${ARGS[@]}" --quit-after 20000 >"$LOG" 2>&1
fi
grep -E "^\[mp\]|^(PASS|FAIL)  " "$LOG"

N=$(grep -c '^PASS  ' "$LOG" || true)
[ "$N" -ge "$MIN_MP_ASSERTS" ] \
  || { echo "GATE-FAIL  真实客户端断言 $N < $MIN_MP_ASSERTS"; grep '^FAIL' "$LOG"; exit 1; }
grep -q "multiplayer probe: PASS" "$LOG" \
  || { grep '^FAIL' "$LOG" "$LOG" >/dev/null; echo "GATE-FAIL  客户端-服务器往返存在失败项"; exit 1; }
echo "mp-probe: PASS ($N assertions)"
