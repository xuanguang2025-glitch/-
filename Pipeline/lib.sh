# Pipeline/lib.sh - shared metric extraction. Lives in one file on purpose: the first run of
# run.sh reported "chunk build 0.0 ms" because of a typo'd tr, and the performance gate then
# passed by comparing 0 against the limit. A gate that cannot read its number must fail, not
# default to zero, so every helper here returns empty on failure and callers treat empty as
# a hard error.

# num <regex-with-one-number> <file>   -> the number, or empty
num() { grep -oE "$1" "$2" 2>/dev/null | tail -1 | grep -oE '[0-9]+\.?[0-9]*' | tail -1; }

# sum_ms <file>  -> total of the four "phase=12.3ms" fields on the last [prof] line, or empty
sum_ms() {
  local line
  line=$(grep -oE 'blocks=[0-9.]+ms +streets=[0-9.]+ms +ground=[0-9.]+ms +furniture=[0-9.]+ms' "$1" 2>/dev/null | tail -1)
  [ -n "$line" ] || return 0
  printf '%s' "$line" | grep -oE '[0-9]+\.[0-9]+' | awk '{s+=$1} END{printf "%.1f", s}'
}

# count_pat <pattern> <file> -> integer, 0 when the file or pattern is absent
count_pat() { local n; n=$(grep -cE "$1" "$2" 2>/dev/null); [ -n "$n" ] || n=0; printf '%s' "$n"; }

# require <name> <value> -> non-zero exit and a message when the value is empty
require() {
  if [ -z "$2" ]; then printf 'GATE-FAIL  无法从日志解析 %s（门禁拒绝在未知数值上判定）\n' "$1"; return 1; fi
  return 0
}
