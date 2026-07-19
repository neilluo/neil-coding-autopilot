#!/usr/bin/env bash
# kb-path.sh — single source of truth for the global cross-project
# knowledge-base directory (SCHEMA C8: env override -> known default,
# fail-closed, no hardcoded home dir/username).
#
# Usage:
#   kb-path.sh              # print resolved absolute path to stdout
#   kb-path.sh --ensure     # also mkdir -p "$DIR/raw" "$DIR/wiki"
#
# Resolution priority:
#   1. $NEIL_AUTOPILOT_KB_DIR (non-empty)
#   2. $HOME/.neil-autopilot/knowledge
#   Neither available -> error on stderr, exit 1 (fail-closed).
#
# Contract: stdout carries ONLY the resolved path. All diagnostics go to
# stderr, so callers can safely do `DIR="$(kb-path.sh)"`.
set -euo pipefail

ENSURE=0
for arg in "$@"; do
  case "$arg" in
    --ensure) ENSURE=1 ;;
    *)
      echo "ERROR: kb-path.sh: unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

if [ -n "${NEIL_AUTOPILOT_KB_DIR:-}" ]; then
  KB_DIR="$NEIL_AUTOPILOT_KB_DIR"
elif [ -n "${HOME:-}" ]; then
  KB_DIR="$HOME/.neil-autopilot/knowledge"
else
  echo "ERROR: kb-path.sh: neither \$NEIL_AUTOPILOT_KB_DIR nor \$HOME is set; cannot resolve KB path" >&2
  exit 1
fi

if [ "$ENSURE" -eq 1 ]; then
  mkdir -p "$KB_DIR/raw" "$KB_DIR/wiki"
fi

printf '%s\n' "$KB_DIR"
