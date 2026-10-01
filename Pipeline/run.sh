#!/usr/bin/env bash
# Part 6 Phase 33: the development loop as one command.
#   parse -> boot -> self-tests -> benches -> perf gates -> sim gates -> backend -> review
# Every gate compares a measured number against Pipeline/gates.sh, so a threshold change is a
# one-line diff in one file rather than an edit scattered through test code.
set -uo pipefail
cd "$(dirname "$0")/.."
. Pipeline/gates.sh
. Pipeline/lib.sh

: "${GODOT:=/d/徐浩然/2026-08-29-21-56-21/.tools/Godot441_console.exe}"
LOGDIR="Pipeline/logs"
mkdir -p "$LOGDIR"
RUNFAIL=0
say() { printf '\n=== %s ===\n' "$1"; }
die() { RUNFAIL=1; printf 'GATE-FAIL  %s\n' "$1"; }

if [ ! -f "$GODOT" ]; then echo "找不到 Godot：$GODOT（用 GODOT=<path> 指定）"; exit 2; fi

# Refuse to measure while a previous run's engine is still alive. Killing a backgrounded child
# under Git Bash on Windows does not always take, and a leftover Godot or game server silently
# inflates every number in step 5 — the same build read 10 ms and then 66 ms on identical code.
# A gate that cannot tell "regression" from "someone else was using the machine" is not a gate.
count_stray() {
  if ps -W >/dev/null 2>&1; then
    ps -W 2>/dev/null | grep -icE 'Godot441|Godot_v4|game_server' || true
  elif command -v pgrep >/dev/null 2>&1; then
    pgrep -f 'Godot441|Godot_v4|game_server\.mjs' 2>/dev/null | wc -l | tr -d ' ' || true
  else
    echo 0
  fi
}
STRAY=$(count_stray)
if [ "${ALLOW_STRAY:-}" != "1" ] && [ "${STRAY:-0}" != "0" ]; then
  echo "GATE-FAIL  检测到 $STRAY 个残留的 Godot / 游戏服务器进程"
  echo "           并发测量得到的数字没有意义。先清干净再跑；确需忽略时用 ALLOW_STRAY=1。"
  exit 2
fi

say "1/10 解析与类注册"
"$GODOT" --headless --editor --quit --path . >"$LOGDIR/parse.log" 2>&1
PE=$(grep -ciE "parse error|script error|failed to load" "$LOGDIR/parse.log" || true)
[ "$PE" = "0" ] && echo "parse: clean" || { grep -iE "parse error|script error" "$LOGDIR/parse.log" | head -5; die "解析错误 $PE 处"; }

say "2/10 无头启动"
"$GODOT" --headless --path . --quit-after 60 >"$LOGDIR/boot.log" 2>&1
BE=$(grep -ciE "^ERROR|SCRIPT ERROR" "$LOGDIR/boot.log" || true)
[ "$BE" = "0" ] && echo "boot: 0 error" || { grep -iE "^ERROR|SCRIPT ERROR" "$LOGDIR/boot.log" | head -5; die "启动错误 $BE 条"; }

say "3/10 功能自测"
"$GODOT" --headless --path . --quit-after 150 -- --create-test >"$LOGDIR/create.log" 2>&1
grep -q "creation self-test: PASS" "$LOGDIR/create.log" && echo "create-test: PASS" || { grep "FAIL" "$LOGDIR/create.log" | head -5; die "create-test"; }
"$GODOT" --path . --resolution 1280x720 -- --validate-test --spawn=1150,300 >"$LOGDIR/validate.log" 2>&1
grep -q "validation self-test: PASS" "$LOGDIR/validate.log" && echo "validate-test: PASS" || { grep "FAIL" "$LOGDIR/validate.log" | head -5; die "validate-test"; }
# The menu is driven through the same entry points a click uses (choose / set_quality) rather than
# through the mouse, so a button that exists and does nothing fails here instead of in the field.
"$GODOT" --headless --path . --quit-after 4000 -- --menu-test >"$LOGDIR/menu.log" 2>&1
grep -q "main menu self-test: PASS" "$LOGDIR/menu.log" || { grep "FAIL" "$LOGDIR/menu.log" | head -5; die "menu-test"; }
MA=$(num '\([0-9]+ checks' "$LOGDIR/menu.log")
MF=$(num '[0-9]+ failures' "$LOGDIR/menu.log")
require "菜单断言数" "$MA"
[ "$MA" -ge "$MIN_MENU_ASSERTS" ] || die "主菜单断言仅 $MA 条（门槛 $MIN_MENU_ASSERTS）"
[ "$MF" = "0" ] || die "主菜单自测报告 $MF 处失败"
echo "menu-test: PASS ($MA checks)"

say "4/10 世界普查"
"$GODOT" --headless --path . --quit-after 60 -- --census >"$LOGDIR/census.log" 2>&1
grep -E "^\[census\] cells" "$LOGDIR/census.log" || die "census 无输出"

say "5/10 性能与压力"
# Median of PERF_SAMPLES runs: a single sample reported 32.6 ms against a 17.8 ms median for
# the identical build, so one-shot timing measures whatever else the machine is doing.
CM="" LM="" ALIVE=0 WANT=0 FREED=""
for k in $(seq 1 "$PERF_SAMPLES"); do
  "$GODOT" --path . --resolution 1280x720 -- "--shots=1" "--shot-every=20" \
    "--shot-dir=$(pwd -W 2>/dev/null || pwd)/$LOGDIR" --time=10.0 --spawn=1150,300 \
    >"$LOGDIR/perf$k.log" 2>&1
  v=$(sum_ms "$LOGDIR/perf$k.log"); [ -n "$v" ] && CM="$CM $v"
  p=$(grep -oE 'chunks=[0-9]+/[0-9]+' "$LOGDIR/perf$k.log" 2>/dev/null | tail -1)
  ALIVE=$(printf '%s' "$p" | cut -d= -f2 | cut -d/ -f1)
  WANT=$(printf '%s' "$p" | cut -d/ -f2)
  f=$(num 'freed=[0-9]+' "$LOGDIR/perf$k.log"); [ -n "$f" ] && FREED="$FREED $f"
  "$GODOT" --path . --resolution 1280x720 -- --bench-load --spawn=1150,300 \
    >"$LOGDIR/load$k.log" 2>&1
  l=$(num 'in [0-9]+ ms' "$LOGDIR/load$k.log"); [ -n "$l" ] && LM="$LM $l"
done
cp "$LOGDIR/perf$PERF_SAMPLES.log" "$LOGDIR/perf.log"
cp "$LOGDIR/load$PERF_SAMPLES.log" "$LOGDIR/load.log"
CHUNK_MS=$(median $CM); LOAD_MS=$(median $LM)
FREED_MAX=$(printf '%s\n' $FREED | sort -n | tail -1)
require "chunk 构建耗时" "$CHUNK_MS"
require "全城流式耗时" "$LOAD_MS"
require "流式 chunk 数" "$ALIVE"
require "freed 计数" "$FREED_MAX"
echo "chunk 构建中位数 ${CHUNK_MS} ms（样本:${CM}）"
echo "全城流式中位数 ${LOAD_MS} ms（样本:${LM}）   流式 $ALIVE/$WANT   freed max=$FREED_MAX"
awk -v v="$CHUNK_MS" -v m="$MAX_CHUNK_BUILD_MS" 'BEGIN{exit !(v>m)}' && die "chunk 构建 ${CHUNK_MS}ms > ${MAX_CHUNK_BUILD_MS}ms"
[ "$ALIVE" -ge "$MAX_CHUNKS_ALIVE_THRESHOLD" ] || die "仅流式 $ALIVE chunk"
[ "$FREED_MAX" = "0" ] || die "出现 $FREED_MAX 次 chunk 卸载（重建抖动回归）"
[ "$LOAD_MS" -le "$MAX_STREAM_MS" ] || die "流式耗时 ${LOAD_MS} ms 超门槛"

"$GODOT" --path . --resolution 1280x720 -- "--bench-stress=$STRESS_OBJECTS" --spawn=1150,300 >"$LOGDIR/stress.log" 2>&1
grep -E "^\[stress\] placed|^\[stress\] result" "$LOGDIR/stress.log" || die "压力测试无输出"
PLACED=$(num 'placed=[0-9]+' "$LOGDIR/stress.log")
require "压力放置数" "$PLACED"
[ "$PLACED" -ge $(( STRESS_OBJECTS * 9 / 10 )) ] || die "仅放置 $PLACED/$STRESS_OBJECTS 件"

say "6/10 城市模拟闭环"
"$GODOT" --path . --resolution 1280x720 -- --sim-test --spawn=1150,300 >"$LOGDIR/sim.log" 2>&1
grep -q "city simulation self-test: PASS" "$LOGDIR/sim.log" \
  || { grep "FAIL" "$LOGDIR/sim.log" | head -8; die "城市模拟自测"; }
SA=$(count_pat '^\[test\] PASS' "$LOGDIR/sim.log")
require "模拟断言数" "$SA"
[ "$SA" -ge "$MIN_SIM_ASSERTS" ] || die "城市模拟断言仅 $SA 条（门槛 $MIN_SIM_ASSERTS）"
"$GODOT" --path . --resolution 1280x720 -- "--sim-soak=$SIM_SOAK_HOURS" --spawn=1150,300 \
  >"$LOGDIR/soak.log" 2>&1
SOAK_LINE=$(grep -E '^\[soak\] hours' "$LOGDIR/soak.log")
[ -n "$SOAK_LINE" ] || die "soak 无输出"
printf '%s\n' "$SOAK_LINE"
grep -q "sim soak: PASS" "$LOGDIR/soak.log" \
  || { grep "FAIL" "$LOGDIR/soak.log" | head -6; die "soak 断言"; }
PH=$(num 'per_hour=[0-9.]+' "$LOGDIR/soak.log")
require "每小时推进耗时" "$PH"
awk -v v="$PH" -v m="$MAX_SIM_HOUR_MS" 'BEGIN{exit !(v>m)}' \
  && die "每小时 ${PH} ms > ${MAX_SIM_HOUR_MS} ms"
# The economy only counts as live if it advances while the world is being played, not merely
# under a test flag, so this drives the clock across an hour boundary in a real session and
# requires the tick to have happened.
"$GODOT" --path . --resolution 1280x720 --quit-after 1500 -- --time=23.4 --spawn=1150,300 \
  >"$LOGDIR/live.log" 2>&1
LT=$(count_pat '^\[sim\] day' "$LOGDIR/live.log")
require "实时推进次数" "$LT"
[ "$LT" -ge "$SIM_LIVE_MIN_HOURS" ] || die "实时运行中城市模拟只推进了 $LT 个小时"
echo "模拟断言 $SA 条   一年每小时 ${PH} ms (门槛 ${MAX_SIM_HOUR_MS} ms)   实时推进 $LT 小时"

say "7/10 后端契约测试"
if command -v node >/dev/null 2>&1; then
  node backend/test.mjs >"$LOGDIR/backend.log" 2>&1
  tail -1 "$LOGDIR/backend.log"
  # grep -E has no back-references, so compare the two numbers explicitly and fail closed
  # when either is missing.
  BT=$(num 'backend: [0-9]+' "$LOGDIR/backend.log")
  BT_TOTAL=$(grep -oE 'backend: [0-9]+/[0-9]+' "$LOGDIR/backend.log" | cut -d/ -f2)
  require "后端断言数" "$BT"
  require "后端断言总数" "$BT_TOTAL"
  { [ -n "$BT" ] && [ "$BT" = "$BT_TOTAL" ] && [ "$BT" != "0" ]; } \
    || { grep '^FAIL' "$LOGDIR/backend.log" | head -8; die "后端契约测试 $BT/$BT_TOTAL"; }
else
  die "未找到 node，后端契约测试无法执行（该门禁不可跳过）"
fi

say "8/10 客户端-后端往返"
bash Pipeline/backend_sync.sh || die "客户端与后端存档往返不一致"

say "9/10 静态审查"
bash Pipeline/review.sh | tee "$LOGDIR/review.log"
grep -q "review: PASS" "$LOGDIR/review.log" || die "review.sh"

say "10/10 多人同步契约"
if command -v node >/dev/null 2>&1; then
  rm -f backend/data_test_mp/world_creations.json
  node server/multiplayer_test.mjs >"$LOGDIR/multiplayer.log" 2>&1
  tail -1 "$LOGDIR/multiplayer.log"
  MP=$(num 'multiplayer: [0-9]+' "$LOGDIR/multiplayer.log")
  MP_TOTAL=$(grep -oE 'multiplayer: [0-9]+/[0-9]+' "$LOGDIR/multiplayer.log" | cut -d/ -f2)
  require "多人断言数" "$MP"
  { [ -n "$MP" ] && [ "$MP" = "$MP_TOTAL" ] && [ "$MP" != "0" ]; } \
    || { grep '^FAIL' "$LOGDIR/multiplayer.log" | head -8; die "多人同步契约 $MP/$MP_TOTAL"; }
  # 10b is the half that can fail independently: 10a's client shares the server's framing, so a
  # transport or encoding disagreement between the *game* and the server is invisible to it.
  bash Pipeline/mp_probe.sh || die "真实客户端未能与游戏服务器互通"
else
  die "未找到 node，多人契约测试无法执行"
fi

bash Pipeline/dashboard.sh "$LOGDIR"
echo
if [ "$RUNFAIL" -eq 0 ]; then echo "PIPELINE: PASS"; else echo "PIPELINE: FAIL"; fi
exit $RUNFAIL
