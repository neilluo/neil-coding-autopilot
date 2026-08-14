#!/usr/bin/env bash
# WHAT: Run project smoke scripts sequentially with fail-fast reporting.
# USAGE: smoke-all.sh [--only <pattern>] [--list]
# EXIT CODES: 0 when selected smokes pass or are listed; 1 on usage or smoke failure.
set -uo pipefail
unset AUTOPILOT_RUN_ID

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SELF="$SCRIPT_DIR/$(basename "$0")"
ONLY=""
LIST=0

usage() {
  echo "Usage: smoke-all.sh [--only <pattern>] [--list]"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --only)
      if [ "$#" -lt 2 ]; then
        echo "Usage: smoke-all.sh [--only <pattern>] [--list]" >&2
        exit 1
      fi
      ONLY="$2"
      shift 2
      ;;
    --list)
      LIST=1
      shift
      ;;
    *)
      echo "Usage: smoke-all.sh [--only <pattern>] [--list]" >&2
      exit 1
      ;;
  esac
done

SMOKE_LIST="$(mktemp)"
SMOKE_OUTPUT="$(mktemp)"
trap 'rm -f "$SMOKE_LIST" "$SMOKE_OUTPUT"' EXIT

for smoke in "$SCRIPT_DIR"/smoke-*.sh; do
  [ -f "$smoke" ] || continue
  [ "$smoke" = "$SELF" ] && continue
  name="$(basename "$smoke")"
  case "$name" in
    *"$ONLY"*) printf '%s\n' "$smoke" ;;
  esac
done | LC_ALL=C sort > "$SMOKE_LIST"

if [ "$LIST" -eq 1 ]; then
  while IFS= read -r smoke; do
    basename "$smoke"
  done < "$SMOKE_LIST"
  exit 0
fi

while IFS= read -r smoke; do
  [ -n "$smoke" ] || continue
  name="$(basename "$smoke")"
  started="$(date +%s)"
  if bash "$smoke" > "$SMOKE_OUTPUT" 2>&1; then
    elapsed=$(( $(date +%s) - started ))
    echo "PASS $name (${elapsed}s)"
  else
    elapsed=$(( $(date +%s) - started ))
    echo "FAIL $name (${elapsed}s)"
    tail -n 30 "$SMOKE_OUTPUT"
    exit 1
  fi
done < "$SMOKE_LIST"

exit 0
