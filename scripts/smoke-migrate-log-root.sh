#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

make_source() {
  local root="$1" count="$2" i
  mkdir -p "$root/runs/run-1" "$root/metrics" "$root/reports"
  printf 'metric\n' > "$root/metrics/daily.json"
  i=1
  while [ "$i" -le "$count" ]; do
    printf '{"line":1}\n{"line":2}\n' > "$root/runs/$i.jsonl"
    i=$((i + 1))
  done
  printf 'nested\n' > "$root/runs/run-1/detail.txt"
}

for count in 0 1 3; do
  source_dir="$TMP/source-$count"
  target_dir="$TMP/target-$count"
  make_source "$source_dir" "$count"
  "$SCRIPT_DIR/migrate-log-root.sh" --from "$source_dir" --to "$target_dir" >/dev/null
  [ -d "$source_dir" ]
  [ -f "$target_dir/metrics/daily.json" ]
  [ -f "$target_dir/runs/run-1/detail.txt" ]
  source_lines="$(find "$source_dir/runs" -type f -name '*.jsonl' -exec cat {} \; | wc -l | tr -d ' ')"
  target_lines="$(find "$target_dir/runs" -type f -name '*.jsonl' -exec cat {} \; | wc -l | tr -d ' ')"
  [ "$target_lines" -ge "$source_lines" ]
  before="$(cksum "$target_dir/metrics/daily.json")"
  "$SCRIPT_DIR/migrate-log-root.sh" --from "$source_dir" --to "$target_dir" >/dev/null
  [ "$(cksum "$target_dir/metrics/daily.json")" = "$before" ]
done

dry_source="$TMP/dry-source"
dry_target="$TMP/dry-target"
make_source "$dry_source" 1
"$SCRIPT_DIR/migrate-log-root.sh" --from "$dry_source" --to "$dry_target" --dry-run >/dev/null
[ ! -e "$dry_target" ]

echo "smoke-migrate-log-root: PASS"
