#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: migrate-log-root.sh --from <dir> [--to <dir>] [--dry-run]"
}

FROM=""
TO="${HOME:-}/Library/Logs/neil-autopilot"
DRY_RUN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --from) [ "$#" -ge 2 ] || { usage >&2; exit 1; }; FROM="$2"; shift 2 ;;
    --to) [ "$#" -ge 2 ] || { usage >&2; exit 1; }; TO="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[ -n "$FROM" ] || { echo "ERROR: --from is required" >&2; usage >&2; exit 1; }
[ -d "$FROM" ] || { echo "ERROR: source directory does not exist: $FROM" >&2; exit 1; }

copy_tree() {
  local section="$1" src="$FROM/$section" dst="$TO/$section" path relative target
  [ -e "$src" ] || return 0
  if [ ! -e "$dst" ]; then
    echo "COPY: $src -> $TO/"
    [ "$DRY_RUN" -eq 1 ] || { mkdir -p "$TO"; cp -R "$src" "$TO/"; }
    return 0
  fi
  find "$src" -type d | while IFS= read -r path; do
    relative="${path#$src}"
    [ "$DRY_RUN" -eq 1 ] || mkdir -p "$dst$relative"
  done
  find "$src" -type f | while IFS= read -r path; do
    relative="${path#$src/}"
    target="$dst/$relative"
    if [ -e "$target" ] && { [ "$target" -nt "$path" ] || [ "$target" -ef "$path" ]; }; then
      echo "SKIP target is newer: $target"
    else
      echo "COPY: $path -> $target"
      [ "$DRY_RUN" -eq 1 ] || { mkdir -p "$(dirname "$target")"; cp -p "$path" "$target"; }
    fi
  done
}

for section in runs metrics reports; do
  copy_tree "$section"
done

count_jsonl_lines() {
  local runs_dir="$1"
  if [ ! -d "$runs_dir" ]; then
    echo 0
    return
  fi
  find "$runs_dir" -type f -name '*.jsonl' -exec cat {} \; | wc -l | tr -d ' '
}

if [ "$DRY_RUN" -eq 0 ]; then
  source_lines="$(count_jsonl_lines "$FROM/runs")"
  target_lines="$(count_jsonl_lines "$TO/runs")"
  if [ "$target_lines" -lt "$source_lines" ]; then
    echo "ERROR: validation failed: target jsonl lines ($target_lines) < source ($source_lines)" >&2
    exit 1
  fi
  echo "Validation passed: target jsonl lines $target_lines >= source $source_lines"
fi

echo "Next steps:"
echo "  Add this line to ~/.zshrc:"
echo "  export NEIL_AUTOPILOT_LOG_DIR=\"$TO\""
echo "  After verifying scheduled and interactive runs, you may delete the old directory manually: $FROM"
