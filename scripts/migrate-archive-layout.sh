#!/usr/bin/env bash
# migrate-archive-layout.sh — deterministic, idempotent, fail-closed one-shot
# migration of legacy FLAT autopilot/archive/<YYYY-MM-DD>-<name> directories
# into the four-level autopilot/archive/<YYYY>/<MM>/<MM-DD>/<YYYY-MM-DD>-<name>
# layout (SCHEMA C7/C8, same derivation as archive-change.sh).
#
# Usage:
#   migrate-archive-layout.sh [--archive-dir DIR] [--dry-run]
#
# Resolution:
#   --archive-dir defaults to <plugin-root>/autopilot/archive, where
#     plugin-root is this script's own directory's parent (pwd -P, symlink
#     free). If that default does not exist, --archive-dir must be passed
#     explicitly — fail-closed, no silent fallback.
#
# Behavior:
#   - Only top-level entries whose basename matches the flat pattern
#     ^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-* are touched. Already
#     nested structures (e.g. a pure-numeric year dir like "2026") never
#     match and are skipped — this is what makes re-runs idempotent.
#   - For each match: derive Y/M/MM-DD from the first 10 chars of the name
#     and move the whole directory (unchanged name) under
#     <archive-dir>/<Y>/<M>/<MM-DD>/<name>. If that target already exists,
#     skip (idempotent). Otherwise mkdir -p the parent, then `git mv`
#     (preferred, inside a git repo) falling back to `mv` — the fallback is
#     guarded by an existence check on the target to refuse nesting.
#   - --dry-run prints the planned "FROM -> TO" moves without touching the
#     filesystem, then exits 0.
#
# bash 3.2 safe (no arrays/mapfile), `pwd -P` for symlink-free resolution,
# no GNU-only flags.
set -euo pipefail

usage() {
  echo "Usage: migrate-archive-layout.sh [--archive-dir DIR] [--dry-run]" >&2
}

abs_lexical() {
  case "$1" in
    /*) printf '%s\n' "${1%/}" ;;
    *) printf '%s\n' "$(pwd -P)/${1%/}" ;;
  esac
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"
DEFAULT_ARCHIVE_DIR="$PLUGIN_ROOT/autopilot/archive"

ARCHIVE_DIR=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --archive-dir)
      [ $# -ge 2 ] || { echo "ERROR: migrate-archive-layout.sh: --archive-dir requires a value" >&2; exit 1; }
      ARCHIVE_DIR="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    *)
      echo "ERROR: migrate-archive-layout.sh: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [ -z "$ARCHIVE_DIR" ]; then
  if [ ! -d "$DEFAULT_ARCHIVE_DIR" ]; then
    echo "ERROR: migrate-archive-layout.sh: could not resolve default archive dir ($DEFAULT_ARCHIVE_DIR does not exist); pass --archive-dir explicitly" >&2
    exit 1
  fi
  ARCHIVE_DIR="$DEFAULT_ARCHIVE_DIR"
fi
ARCHIVE_DIR="$(abs_lexical "$ARCHIVE_DIR")"

if [ ! -d "$ARCHIVE_DIR" ]; then
  echo "ERROR: migrate-archive-layout.sh: --archive-dir does not exist: $ARCHIVE_DIR" >&2
  exit 1
fi

REPO_ROOT="$(git -C "$ARCHIVE_DIR" rev-parse --show-toplevel 2>/dev/null || true)"

for entry in "$ARCHIVE_DIR"/*/; do
  [ -d "$entry" ] || continue
  name="$(basename "$entry")"

  case "$name" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*) ;;
    *) continue ;;
  esac

  DATE_STR="${name:0:10}"
  _Y="${DATE_STR%%-*}"      # YYYY
  _R="${DATE_STR#*-}"       # MM-DD
  _M="${_R%%-*}"            # MM
  _D="${_R#*-}"             # DD
  _MMDD="${_M}-${_D}"       # MM-DD

  TARGET="$ARCHIVE_DIR/${_Y}/${_M}/${_MMDD}/${name}"
  SOURCE="$ARCHIVE_DIR/${name}"

  if [ -d "$TARGET" ]; then
    continue
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "$SOURCE -> $TARGET"
    continue
  fi

  mkdir -p "$(dirname "$TARGET")"

  MOVED=0
  if [ -n "$REPO_ROOT" ]; then
    if (cd "$REPO_ROOT" && git mv "$SOURCE" "$TARGET") >/dev/null 2>&1; then
      MOVED=1
    fi
  fi
  if [ "$MOVED" -eq 0 ]; then
    if [ -e "$TARGET" ]; then
      echo "ERROR: migrate-archive-layout.sh: git mv failed and TARGET already exists, refusing to nest: $TARGET" >&2
      exit 1
    fi
    mv "$SOURCE" "$TARGET"
  fi

  if [ -d "$SOURCE" ]; then
    echo "ERROR: migrate-archive-layout.sh: move failed — source still exists: $SOURCE" >&2
    exit 1
  fi

  echo "migrated: ${name} -> ${_Y}/${_M}/${_MMDD}/${name}"
done

exit 0
