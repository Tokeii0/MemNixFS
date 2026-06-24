#!/usr/bin/env bash
set -u

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
memnixfs="${MEMNIXFS:-$repo/build/wsl-debug/memnixfs}"
dump_dir="${DUMP_DIR:-$repo/../Test dumps}"
out_dir="${OUT_DIR:-$repo/build/dump-regression-$(date +%Y%m%d-%H%M%S)}"
case_timeout="${CASE_TIMEOUT:-180}"

if [[ ! -x "$memnixfs" ]]; then
  echo "memnixfs executable not found or not executable: $memnixfs" >&2
  exit 2
fi
if [[ ! -d "$dump_dir" ]]; then
  echo "dump directory not found: $dump_dir" >&2
  exit 2
fi

mkdir -p "$out_dir"
cache="$out_dir/symbols"
mkdir -p "$cache"
summary="$out_dir/summary.tsv"
printf 'dump\tcase\texit_code\tstdout_bytes\tstderr_bytes\tzero_bytes\tnonzero_bytes\tprintable_bytes\tdiagnostic\n' > "$summary"

common_args=("--no-http-cache")
if [[ "${USE_DEFAULT_CACHE:-0}" != "1" ]]; then
  common_args=("--symbol-cache" "$cache" "${common_args[@]}")
fi
case_filter=",${CASE_FILTER:-list,tree,banner,users,pagecache,recovery,path-quality,fs-etc-passwd,fs-os-release,fs-hostname,fs-bash,kallsyms-init-task},"

measure_output() {
  local file="$1"
  python3 - "$file" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
if not p.exists():
    print("0\t0\t0\tmissing-output")
    raise SystemExit
b = p.read_bytes()
zero = b.count(0)
nonzero = len(b) - zero
printable = sum(1 for x in b if x in (9, 10, 13) or 32 <= x <= 126)
sample = b[:4096].decode("utf-8", "replace")
diagnostic = "yes" if sample.startswith(("unavailable:", "partial:", "unsupported:")) else "no"
print(f"{zero}\t{nonzero}\t{printable}\t{diagnostic}")
PY
}

run_case() {
  local dump="$1"
  local name="$2"
  shift 2
  local base safe stdout stderr rc
  safe="$(basename "$dump" | tr -c 'A-Za-z0-9_.-' '_')"
  base="$out_dir/$safe.$name"
  stdout="$base.out.txt"
  stderr="$base.err.txt"
  timeout "$case_timeout" "$memnixfs" --dump "$dump" "$@" >"$stdout" 2>"$stderr"
  rc=$?
  metrics="$(measure_output "$stdout")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(basename "$dump")" "$name" "$rc" \
    "$(wc -c <"$stdout")" "$(wc -c <"$stderr")" "$metrics" >> "$summary"
}

while IFS= read -r -d '' dump; do
  [[ "$case_filter" == *,list,* ]] && run_case "$dump" list "${common_args[@]}" list
  [[ "$case_filter" == *,tree,* ]] && run_case "$dump" tree "${common_args[@]}" tree
  [[ "$case_filter" == *,banner,* ]] && run_case "$dump" banner "${common_args[@]}" cat /sys/banner.txt
  [[ "$case_filter" == *,users,* ]] && run_case "$dump" users "${common_args[@]}" cat /sys/users.txt
  [[ "$case_filter" == *,pagecache,* ]] && run_case "$dump" pagecache "${common_args[@]}" cat /sys/pagecache/index.txt
  [[ "$case_filter" == *,recovery,* ]] && run_case "$dump" recovery "${common_args[@]}" cat /sys/pagecache/recovery.txt
  [[ "$case_filter" == *,path-quality,* ]] && run_case "$dump" path-quality "${common_args[@]}" cat /sys/pagecache/path_quality.txt
  [[ "$case_filter" == *,fs-etc-passwd,* ]] && run_case "$dump" fs-etc-passwd "${common_args[@]}" cat /fs/etc/passwd
  [[ "$case_filter" == *,fs-os-release,* ]] && run_case "$dump" fs-os-release "${common_args[@]}" cat /fs/etc/os-release
  [[ "$case_filter" == *,fs-hostname,* ]] && run_case "$dump" fs-hostname "${common_args[@]}" cat /fs/etc/hostname
  [[ "$case_filter" == *,fs-bash,* ]] && run_case "$dump" fs-bash "${common_args[@]}" cat /fs/usr/bin/bash
  [[ "$case_filter" == *,kallsyms-init-task,* ]] && run_case "$dump" kallsyms-init-task kallsyms init_task
done < <(find "$dump_dir" -maxdepth 1 -type f -print0 | sort -z)

echo "Regression summary: $summary"
