#!/usr/bin/env bash
# Static review gate (Part 6 Phase 35). Every rule here exists because that pattern actually
# broke this project at least once; none of them are stylistic preferences.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
note() { printf '%-5s %s\n' "$1" "$2"; }
hit()  { FAIL=1; printf 'FAIL  %s\n      %s\n' "$1" "$2"; }

SRC="src"
MAX_LINES="${FILE_MAX_LINES:-900}"

# R1  GDScript binds % tighter than +, so print("a" + "b" % [..]) feeds the argument list to
#     only the last fragment. This bit three separate call sites.
bad=$(grep -rnE 'print\("[^"]*"[[:space:]]*\+[[:space:]]*$' "$SRC" 2>/dev/null \
      | grep -v 'print(("' || true)
if [ -n "$bad" ]; then hit "R1 多行格式化字符串缺少外层括号" "$(echo "$bad" | head -3)"; else note pass "R1 格式化字符串括号配对"; fi

# R2  Debug scaffolding must not survive into a commit.
bad=$(grep -rnE 'print\("\[dbg' "$SRC" 2>/dev/null || true)
if [ -n "$bad" ]; then hit "R2 残留调试打印" "$bad"; else note pass "R2 无调试残留"; fi

# R3  Dictionary.get(key, []) allocates the default on every miss. In a per-sample spatial
#     scan that is one allocation per empty bucket, which dominated chunk builds here.
bad=$(grep -rnE '\.get\([^)]*,[[:space:]]*\[\][[:space:]]*\)' "$SRC/city" 2>/dev/null || true)
if [ -n "$bad" ]; then hit "R3 热路径中 .get(k, []) 分配空数组" "$bad"; else note pass "R3 空间索引无默认值分配"; fi

# R4  File size ceiling keeps modules reviewable by the next agent.
bad=$(awk 'END{}' /dev/null; find "$SRC" -name '*.gd' -exec wc -l {} + 2>/dev/null \
      | awk -v m="$MAX_LINES" '$1>m && $2!="total"{print $1" "$2}' || true)
if [ -n "$bad" ]; then hit "R4 单文件超过 ${MAX_LINES} 行" "$bad"; else note pass "R4 文件规模在限内"; fi

# R5  A deferred item must be traceable to the bug ledger.
bad=$(grep -rnE '(TODO|FIXME)' "$SRC" 2>/dev/null | grep -v 'BUG-' || true)
if [ -n "$bad" ]; then hit "R5 TODO/FIXME 未挂 BUG ID" "$bad"; else note pass "R5 无未登记的技术债"; fi

# R6  _init on a Node subclass shadows the constructor and fails only at runtime.
bad=$(grep -rln 'extends Node' "$SRC" 2>/dev/null | xargs grep -ln 'func _init(' 2>/dev/null || true)
if [ -n "$bad" ]; then hit "R6 Node 子类使用 _init" "$bad"; else note pass "R6 构造函数命名安全"; fi

# R7  _check(what, got, want) compares two values; _check_that(what, cond, detail) asserts a
#     condition. Handing _check a formatted detail compares "true" against "69407 -> 69411" and
#     fails a passing test — the same call was misused twice in two sessions, so it is a rule.
#     The shape is a format string followed by the % operator inside a _check( call; a plain
#     string want-value such as _check("tpl stored", got, "road") stays legal, and the GDScript
#     `->` in a signature must not be mistaken for it.
bad=$(awk '
  /_check\("/ {
    buf=$0
    d=gsub(/\(/,"(",buf)-gsub(/\)/,")",buf)
    while(d>0 && (getline nl)>0){ buf=buf " " nl; d+=gsub(/\(/,"(",nl)-gsub(/\)/,")",nl) }
    if(buf ~ /"[^"]*%[ds][^"]*"[ \t]*%/) print FILENAME": "substr(buf,1,110)
  }' $(find "$SRC" -name '*.gd' -print) 2>/dev/null || true)
if [ -n "$bad" ]; then hit "R7 _check 被当成 _check_that 使用" "$bad"; else note pass "R7 断言函数用法正确"; fi

# R8  The message-id table is written twice, in two languages, and must agree digit-for-digit.
#     A divergence is invisible to any test whose client reuses the server's own encoder — which is
#     how an entire multiplayer slice passed 19 assertions while the real client never connected.
if [ -f server/game_server.mjs ] && [ -f src/net/SyncProtocol.gd ]; then
	gd=$(sed -n '/^enum Msg {/,/^}/p' src/net/SyncProtocol.gd \
		| grep -oE '[A-Z0-9_]+ *= *[0-9]+' | sed -E 's/ *= *([0-9]+)/=\1/' | sort)
	js=$(sed -n '/^const Msg = {/,/^};/p' server/game_server.mjs \
		| grep -oE '[A-Z0-9_]+: *[0-9]+' | sed -E 's/: *([0-9]+)/=\1/' | sort)
	if [ -z "$gd" ] || [ "$gd" != "$js" ]; then
		hit "R8 两端消息表不一致（gd=$(echo "$gd" | wc -l) js=$(echo "$js" | wc -l)）" \
			"$(diff <(echo "$gd") <(echo "$js") | head -6)"
	else
		note pass "R8 两端消息表一致（$(echo "$gd" | wc -l) 条）"
	fi
else
	note skip "R8 缺少协议文件，未检查"
fi

echo "-----"
if [ "$FAIL" -eq 0 ]; then echo "review: PASS (8 rules)"; else echo "review: FAIL"; fi
exit $FAIL
