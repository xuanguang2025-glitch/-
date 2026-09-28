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
  # Trailing newline matters: callers concatenate several calls and feed the result to median.
  printf '%s\n' "$line" | grep -oE '[0-9]+\.[0-9]+' | awk '{s+=$1} END{printf "%.1f\n", s}'
}

# count_pat <pattern> <file> -> integer, 0 when the file or pattern is absent
count_pat() { local n; n=$(grep -cE "$1" "$2" 2>/dev/null); [ -n "$n" ] || n=0; printf '%s' "$n"; }

# median 3 2 1 -> 2. Single-sample performance gates on a laptop produced a 32.6 ms reading
# against a 17.8 ms median for the same build; the outlier was machine load, not code.
# Taking the median measures the code instead of the moment.
median() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }

# require <name> <value> -> hard failure when the number could not be read. It routes through
# die() (defined by the caller before any require runs) rather than printing on its own: a
# previous version printed GATE-FAIL and left the exit status untouched, so an unparseable
# metric reported "PIPELINE: PASS" one line below its own failure.
require() {
  if [ -z "$2" ]; then die "无法从日志解析 $1（门禁拒绝在未知数值上判定）"; return 1; fi
  return 0
}
