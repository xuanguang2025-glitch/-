#!/usr/bin/env bash
# Part 6 Phase 43: the project dashboard, generated from the logs the last run produced.
# Deliberately has no hand-typed percentages: every bar has a real denominator (assertions
# passed, gates passed, tools implemented, chunks streamed), so it cannot drift into fiction.
set -uo pipefail
cd "$(dirname "$0")/.."
LOG="${1:-Pipeline/logs}"
. Pipeline/gates.sh
. Pipeline/lib.sh
[ -d "$LOG" ] || { echo "没有日志目录 $LOG，先跑 Pipeline/run.sh"; exit 2; }

bar() { # done total width
  local d=$1 t=$2 w=20 n=0
  [ "$t" -gt 0 ] && n=$(( d * w / t ))
  local s="" i
  for i in $(seq 1 $w); do [ "$i" -le "$n" ] && s="$s█" || s="$s░"; done
  printf '%s %s/%s' "$s" "$d" "$t"
}

CA=$(count_pat '^\[test\] (PASS|FAIL)' "$LOG/create.log"); CF=$(count_pat '^\[test\] FAIL' "$LOG/create.log")
VA=$(count_pat '^\[test\] (PASS|FAIL)' "$LOG/validate.log"); VF=$(count_pat '^\[test\] FAIL' "$LOG/validate.log")
TA=$(( CA + VA )); TF=$(( CF + VF ))

PE=$(count_pat 'parse error|script error|failed to load' "$LOG/parse.log")
BE=$(count_pat '^ERROR|SCRIPT ERROR' "$LOG/boot.log")
CHUNK_MS=$(sum_ms "$LOG/perf.log")
PAIR=$(grep -oE 'chunks=[0-9]+/[0-9]+' "$LOG/perf.log" 2>/dev/null | tail -1)
ALIVE=$(printf '%s' "$PAIR" | cut -d= -f2 | cut -d/ -f1)
WANT=$(printf '%s' "$PAIR" | cut -d/ -f2)
TRIS=$(num 'tris=[0-9]+' "$LOG/perf.log")
FPS=$(num 'fps=[0-9.]+' "$LOG/perf.log")
FREED=$(num 'freed=[0-9]+' "$LOG/perf.log")
LOAD_MS=$(num 'in [0-9]+ ms' "$LOG/load.log")
PLACED=$(num 'placed=[0-9]+' "$LOG/stress.log")
MEM=$(num 'static_mem=[0-9.]+' "$LOG/stress.log")
PER_OBJ=$(num 'per_object=[0-9.]+' "$LOG/stress.log")
REV=$(grep -oE 'review: (PASS|FAIL)' "$LOG/review.log" 2>/dev/null | tail -1)
CEN=$(grep -oE 'cells=[0-9]+ +plates=[0-9]+ +edges=[0-9]+' "$LOG/census.log" 2>/dev/null | tail -1)
[ -n "$ALIVE" ] || ALIVE=0
[ -n "$WANT" ] || WANT=1
[ -n "$REV" ] || REV="review: 未运行"

GATES=0; GTOT=0
ok() { GTOT=$((GTOT+1)); if eval "$2"; then GATES=$((GATES+1)); printf -- '- [x] %s\n' "$1"; else printf -- '- [ ] %s\n' "$1"; fi; }

{
echo "# PROJECT DASHBOARD"
echo
echo "> 由 \`Pipeline/dashboard.sh\` 从最近一次 \`Pipeline/run.sh\` 的日志生成，请勿手改。"
echo "> 生成时间：$(date '+%Y-%m-%d %H:%M:%S')"
echo
echo "## 门禁"
echo
ok "解析零错误（当前 $PE）"                                  "[ \"$PE\" = \"0\" ]"
ok "无头启动零报错（当前 $BE）"                               "[ \"$BE\" = \"$BOOT_ERRORS_ALLOWED\" ]"
ok "自测断言全通过（$((TA-TF))/$TA）"                         "[ \"$TF\" = \"0\" ] && [ \"$TA\" -gt 0 ]"
ok "chunk 构建 ≤ ${MAX_CHUNK_BUILD_MS} ms（当前 ${CHUNK_MS:-未解析}）" \
   "[ -n \"$CHUNK_MS\" ] && awk -v v=\"$CHUNK_MS\" -v m=$MAX_CHUNK_BUILD_MS 'BEGIN{exit !(v<=m)}'"
ok "全城流式 ≤ ${MAX_STREAM_MS} ms（当前 ${LOAD_MS:-未解析}）" \
   "[ -n \"$LOAD_MS\" ] && [ \"$LOAD_MS\" -le \"$MAX_STREAM_MS\" ]"
ok "创造压力 ≥ $(( STRESS_OBJECTS * 9 / 10 )) 件（当前 ${PLACED:-未解析}）" \
   "[ -n \"$PLACED\" ] && [ \"$PLACED\" -ge $(( STRESS_OBJECTS * 9 / 10 )) ]"
ok "无 chunk 卸载抖动（freed=${FREED:-未解析}）"              "[ \"$FREED\" = \"0\" ]"
ok "静态审查 $REV"                                           "printf '%s' \"$REV\" | grep -q PASS"
echo
echo "## 模块"
echo
printf -- '- %-12s %s chunk 流式到位\n' "城市生成" "$(bar "$ALIVE" "$WANT")"
printf -- '- %-12s %s 已接入（建筑、道路；地形/装饰/车辆/NPC/任务未做）\n' "创造工具" "$(bar 2 7)"
printf -- '- %-12s %s 通过\n' "自测断言" "$(bar $((TA-TF)) "$TA")"
printf -- '- %-12s %s 达标\n' "性能门禁" "$(bar "$GATES" "$GTOT")"
echo
echo "## 实测"
echo
echo '```'
echo "三角面          ${TRIS:-?}"
echo "稳态 FPS        ${FPS:-?}"
echo "chunk 构建      ${CHUNK_MS:-?} ms   （门槛 ${MAX_CHUNK_BUILD_MS} ms；7 ms 帧预算仍未达 = BUG-002）"
echo "全城流式        ${LOAD_MS:-?} ms"
echo "压力放置        ${PLACED:-?}/${STRESS_OBJECTS}  单件 ${PER_OBJ:-?} ms  静态内存 ${MEM:-?} MB"
echo "世界普查        ${CEN:-?}"
echo '```'
echo
echo "> 内存列为 1000 件玩家作品在场时的静态内存，说明 BUG-008（作品不参与流式卸载）真实存在。"
echo
echo "## 已知未修"
echo
echo "见 [Docs/KNOWN_ISSUES.md](KNOWN_ISSUES.md) 与 [Bugs/LEDGER.md](../Bugs/LEDGER.md)。"
} > Docs/PROJECT_DASHBOARD.md

echo "已生成 Docs/PROJECT_DASHBOARD.md（门禁 $GATES/$GTOT）"
[ "$GATES" = "$GTOT" ]
