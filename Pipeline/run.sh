#!/usr/bin/env bash
# Part 6 Phase 33: the development loop as one command.
#   parse -> boot -> self-tests -> benches -> perf gates -> review -> dashboard
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

say "1/7 解析与类注册"
"$GODOT" --headless --editor --quit --path . >"$LOGDIR/parse.log" 2>&1
PE=$(grep -ciE "parse error|script error|failed to load" "$LOGDIR/parse.log" || true)
[ "$PE" = "0" ] && echo "parse: clean" || { grep -iE "parse error|script error" "$LOGDIR/parse.log" | head -5; die "解析错误 $PE 处"; }

say "2/7 无头启动"
"$GODOT" --headless --path . --quit-after 60 >"$LOGDIR/boot.log" 2>&1
BE=$(grep -ciE "^ERROR|SCRIPT ERROR" "$LOGDIR/boot.log" || true)
[ "$BE" = "0" ] && echo "boot: 0 error" || { grep -iE "^ERROR|SCRIPT ERROR" "$LOGDIR/boot.log" | head -5; die "启动错误 $BE 条"; }

say "3/7 功能自测"
"$GODOT" --headless --path . --quit-after 150 -- --create-test >"$LOGDIR/create.log" 2>&1
grep -q "creation self-test: PASS" "$LOGDIR/create.log" && echo "create-test: PASS" || { grep "FAIL" "$LOGDIR/create.log" | head -5; die "create-test"; }
"$GODOT" --path . --resolution 1280x720 -- --validate-test --spawn=1150,300 >"$LOGDIR/validate.log" 2>&1
grep -q "validation self-test: PASS" "$LOGDIR/validate.log" && echo "validate-test: PASS" || { grep "FAIL" "$LOGDIR/validate.log" | head -5; die "validate-test"; }

say "4/7 世界普查"
"$GODOT" --headless --path . --quit-after 60 -- --census >"$LOGDIR/census.log" 2>&1
grep -E "^\[census\] cells" "$LOGDIR/census.log" || die "census 无输出"

say "5/7 性能与压力"
"$GODOT" --path . --resolution 1280x720 -- "--shots=1" "--shot-every=20" \
  "--shot-dir=$(pwd -W 2>/dev/null || pwd)/$LOGDIR" --time=10.0 --spawn=1150,300 >"$LOGDIR/perf.log" 2>&1
CHUNK_MS=$(sum_ms "$LOGDIR/perf.log")
PAIR=$(grep -oE 'chunks=[0-9]+/[0-9]+' "$LOGDIR/perf.log" 2>/dev/null | tail -1)
ALIVE=$(printf '%s' "$PAIR" | cut -d= -f2 | cut -d/ -f1)
WANT=$(printf '%s' "$PAIR" | cut -d/ -f2)
FREED=$(num 'freed=[0-9]+' "$LOGDIR/perf.log")
require "chunk 构建耗时" "$CHUNK_MS"
require "流式 chunk 数" "$ALIVE"
require "freed 计数" "$FREED"
echo "chunk 构建 ${CHUNK_MS} ms   流式 $ALIVE/$WANT   freed=$FREED"
awk -v v="$CHUNK_MS" -v m="$MAX_CHUNK_BUILD_MS" 'BEGIN{exit !(v>m)}' && die "chunk 构建 ${CHUNK_MS}ms > ${MAX_CHUNK_BUILD_MS}ms"
[ "$ALIVE" -ge "$MAX_CHUNKS_ALIVE_THRESHOLD" ] || die "仅流式 $ALIVE chunk"
[ "$FREED" = "0" ] || die "出现 $FREED 次 chunk 卸载（重建抖动回归）"

"$GODOT" --path . --resolution 1280x720 -- --bench-load --spawn=1150,300 >"$LOGDIR/load.log" 2>&1
LOAD_MS=$(num 'in [0-9]+ ms' "$LOGDIR/load.log")
require "全城流式耗时" "$LOAD_MS"
echo "全城流入 ${LOAD_MS} ms (门槛 $MAX_STREAM_MS ms)"
[ "$LOAD_MS" -le "$MAX_STREAM_MS" ] || die "流式耗时 ${LOAD_MS} ms 超门槛"

"$GODOT" --path . --resolution 1280x720 -- "--bench-stress=$STRESS_OBJECTS" --spawn=1150,300 >"$LOGDIR/stress.log" 2>&1
grep -E "^\[stress\] placed|^\[stress\] result" "$LOGDIR/stress.log" || die "压力测试无输出"
PLACED=$(num 'placed=[0-9]+' "$LOGDIR/stress.log")
require "压力放置数" "$PLACED"
[ "$PLACED" -ge $(( STRESS_OBJECTS * 9 / 10 )) ] || die "仅放置 $PLACED/$STRESS_OBJECTS 件"

say "6/7 后端契约测试"
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

say "7/7 静态审查"
bash Pipeline/review.sh | tee "$LOGDIR/review.log"
grep -q "review: PASS" "$LOGDIR/review.log" || die "review.sh"

bash Pipeline/dashboard.sh "$LOGDIR"
echo
if [ "$RUNFAIL" -eq 0 ]; then echo "PIPELINE: PASS"; else echo "PIPELINE: FAIL"; fi
exit $RUNFAIL
