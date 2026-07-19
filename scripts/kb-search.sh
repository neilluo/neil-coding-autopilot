#!/usr/bin/env bash
# kb-search.sh — deterministic, fail-safe "prior-art" search over local +
# global knowledge bases, for explore/analyze to consult before starting work.
#
# Usage:
#   kb-search.sh --query "kw1 kw2 ..." [--cwd DIR] [--limit N]
#     --cwd   defaults to $PWD
#     --limit defaults to 20
#
# Sources searched (read-only, never modified):
#   LOCAL:  <cwd>/autopilot/knowledge/{raw,wiki}
#   GLOBAL: $(kb-path.sh) (same directory as this script), if resolvable and
#           the resulting directory exists.
#
# Output: one line per hit, "[LOCAL] <relpath>: <first matching line>" or
# "[GLOBAL] <relpath>: <first matching line>", deduplicated by path, capped
# at --limit lines.
#
# fail-safe: no KB dirs / no hits -> print "(no prior-art hits)" and exit 0.
# Never fails just because there's nothing to find.
#
# bash 3.2 safe (no arrays/mapfile), `pwd -P`, set -euo pipefail with `|| true`
# around grep (which returns 1 on no-match).
set -euo pipefail

usage() {
  echo "Usage: kb-search.sh --query \"kw1 kw2 ...\" [--cwd DIR] [--limit N]" >&2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

QUERY=""
CWD_ARG=""
LIMIT=20

while [ $# -gt 0 ]; do
  case "$1" in
    --query)
      [ $# -ge 2 ] || { echo "ERROR: kb-search.sh: --query requires a value" >&2; exit 1; }
      QUERY="$2"
      shift 2
      ;;
    --cwd)
      [ $# -ge 2 ] || { echo "ERROR: kb-search.sh: --cwd requires a value" >&2; exit 1; }
      CWD_ARG="$2"
      shift 2
      ;;
    --limit)
      [ $# -ge 2 ] || { echo "ERROR: kb-search.sh: --limit requires a value" >&2; exit 1; }
      LIMIT="$2"
      shift 2
      ;;
    *)
      echo "ERROR: kb-search.sh: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [ -z "$QUERY" ]; then
  echo "ERROR: kb-search.sh: --query is required" >&2
  usage
  exit 1
fi

case "$LIMIT" in
  ''|*[!0-9]*)
    echo "ERROR: kb-search.sh: --limit must be a non-negative integer, got '$LIMIT'" >&2
    exit 1
    ;;
esac

if [ -z "$CWD_ARG" ]; then
  CWD_ARG="$PWD"
fi
if [ ! -d "$CWD_ARG" ]; then
  echo "ERROR: kb-search.sh: --cwd does not exist: $CWD_ARG" >&2
  exit 1
fi
CWD_ABS="$(cd "$CWD_ARG" && pwd -P)"

LOCAL_KB="$CWD_ABS/autopilot/knowledge"

GLOBAL_KB=""
if [ -x "$SCRIPT_DIR/kb-path.sh" ]; then
  GLOBAL_KB="$("$SCRIPT_DIR/kb-path.sh" 2>/dev/null || true)"
fi

# Build the grep -E alternation pattern from whitespace-separated keywords.
PATTERN=""
for kw in $QUERY; do
  if [ -z "$PATTERN" ]; then
    PATTERN="$kw"
  else
    PATTERN="$PATTERN|$kw"
  fi
done

if [ -z "$PATTERN" ]; then
  echo "(no prior-art hits)"
  exit 0
fi

RESULTS_FILE="$(mktemp)"
trap 'rm -f "$RESULTS_FILE"' EXIT

search_source() {
  local label="$1" dir="$2" base_for_relpath="$3"
  [ -n "$dir" ] || return 0
  [ -d "$dir" ] || return 0

  local files
  files="$(grep -rilE "$PATTERN" "$dir" 2>/dev/null || true)"
  [ -n "$files" ] || return 0

  local f relpath firstline
  printf '%s\n' "$files" | while IFS= read -r f; do
    [ -n "$f" ] || continue
    relpath="${f#"$base_for_relpath"/}"
    firstline="$(grep -m 1 -iE "$PATTERN" "$f" 2>/dev/null || true)"
    firstline="$(printf '%s' "$firstline" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    printf '[%s] %s: %s\n' "$label" "$relpath" "$firstline" >> "$RESULTS_FILE"
  done
}

search_source "LOCAL" "$LOCAL_KB" "$LOCAL_KB"
search_source "GLOBAL" "$GLOBAL_KB" "$GLOBAL_KB"

if [ ! -s "$RESULTS_FILE" ]; then
  echo "(no prior-art hits)"
  exit 0
fi

# Dedup by whole line while preserving first-seen order, then cap at LIMIT.
# `|| true` guards against SIGPIPE(141) when `head` closes the pipe early
# (hits > LIMIT): without it, `set -o pipefail` would propagate that as the
# script's exit code, violating the fail-safe/exit-0 contract.
awk '!seen[$0]++' "$RESULTS_FILE" | head -n "$LIMIT" || true
