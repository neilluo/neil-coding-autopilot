#!/usr/bin/env bash
# archive-change.sh — deterministic, idempotent, fail-closed migration of a
# completed autopilot change from autopilot/changes/<name> to
# autopilot/archive/<DATE>-<name> (SCHEMA C7/C8).
#
# Usage:
#   archive-change.sh --change-dir DIR [--archive-dir DIR] [--date YYYY-MM-DD]
#
# Resolution:
#   --archive-dir defaults to <change-dir's parent's parent>/archive
#     (i.e. autopilot/archive, derived from change-dir; change-dir is
#     expected to live at .../autopilot/changes/<name>).
#   --date defaults to `date +%Y-%m-%d`.
#
# Behavior:
#   - Idempotent: if <archive-dir>/<DATE>-<name> already exists, print its
#     path and exit 0 (no re-move, no error) — checked BEFORE the
#     --change-dir existence check, so re-running the exact same command
#     after a successful move (source now gone) still exits 0.
#   - Move: prefer `git mv` when change-dir is inside a git repo; fall back
#     to `mv` for non-git repos or if `git mv` fails.
#   - If change-dir lacks summary.md, a skeleton is generated before moving.
#
# INVARIANT: after this script exits 0, the change exists in archive XOR
# changes — never in both, never in neither. Any violation is fail-closed
# (stderr + exit 1); callers (autopilot-finish) must treat exit 1 as BLOCKED.
#
# bash 3.2 safe (no arrays/mapfile), `pwd -P` for symlink-free resolution,
# no GNU-only flags.
set -euo pipefail

usage() {
  echo "Usage: archive-change.sh --change-dir DIR [--archive-dir DIR] [--date YYYY-MM-DD]" >&2
}

# Absolutize a path lexically (no symlink resolution, no existence check) —
# used for paths that may not exist yet (e.g. an --archive-dir override).
abs_lexical() {
  case "$1" in
    /*) printf '%s\n' "${1%/}" ;;
    *) printf '%s\n' "$(pwd -P)/${1%/}" ;;
  esac
}

CHANGE_DIR=""
ARCHIVE_DIR=""
DATE_STR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --change-dir)
      [ $# -ge 2 ] || { echo "ERROR: archive-change.sh: --change-dir requires a value" >&2; exit 1; }
      CHANGE_DIR="$2"
      shift 2
      ;;
    --archive-dir)
      [ $# -ge 2 ] || { echo "ERROR: archive-change.sh: --archive-dir requires a value" >&2; exit 1; }
      ARCHIVE_DIR="$2"
      shift 2
      ;;
    --date)
      [ $# -ge 2 ] || { echo "ERROR: archive-change.sh: --date requires a value" >&2; exit 1; }
      DATE_STR="$2"
      shift 2
      ;;
    *)
      echo "ERROR: archive-change.sh: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [ -z "$CHANGE_DIR" ]; then
  echo "ERROR: archive-change.sh: --change-dir is required" >&2
  usage
  exit 1
fi

# Derive name/parent from the *argument string*, not from `cd`-ing into
# change-dir itself: on the idempotent re-run, change-dir no longer exists
# (it was already moved), so resolution must not require its presence.
CHANGE_DIR_INPUT="${CHANGE_DIR%/}"
CHANGE_NAME="$(basename "$CHANGE_DIR_INPUT")"
PARENT_DIR="$(dirname "$CHANGE_DIR_INPUT")"

if [ ! -d "$PARENT_DIR" ]; then
  echo "ERROR: archive-change.sh: --change-dir does not exist: $CHANGE_DIR" >&2
  exit 1
fi

# The parent (autopilot/changes) always survives the move, so it's safe to
# resolve symlinks via pwd -P; the leaf name is appended lexically.
PARENT_ABS="$(cd "$PARENT_DIR" && pwd -P)"
CHANGE_DIR_ABS="$PARENT_ABS/$CHANGE_NAME"
AUTOPILOT_ROOT="$(dirname "$PARENT_ABS")"

if [ -z "$ARCHIVE_DIR" ]; then
  ARCHIVE_DIR="$AUTOPILOT_ROOT/archive"
fi
ARCHIVE_DIR="$(abs_lexical "$ARCHIVE_DIR")"

if [ -z "$DATE_STR" ]; then
  DATE_STR="$(date +%Y-%m-%d)"
fi

TARGET="$ARCHIVE_DIR/${DATE_STR}-${CHANGE_NAME}"

# ── idempotent: already archived (checked before existence of change-dir) ──
if [ -d "$TARGET" ]; then
  printf '%s\n' "$TARGET"
  exit 0
fi

# ── fail-closed: change-dir must actually exist to be archived ─────────────
if [ ! -d "$CHANGE_DIR_ABS" ]; then
  echo "ERROR: archive-change.sh: --change-dir does not exist: $CHANGE_DIR" >&2
  exit 1
fi

# ── generate summary.md skeleton if missing, before the move ───────────────
if [ ! -f "$CHANGE_DIR_ABS/summary.md" ]; then
  cat > "$CHANGE_DIR_ABS/summary.md" << EOF
# ${CHANGE_NAME} — 完成摘要

- 完成日期: ${DATE_STR}
- 变更名: ${CHANGE_NAME}
- Task 数: [TODO]
- 关键决策: [TODO]
EOF
fi

mkdir -p "$ARCHIVE_DIR"

# ── move: prefer git mv inside a git repo, fall back to mv ─────────────────
MOVED=0
REPO_ROOT="$(git -C "$CHANGE_DIR_ABS" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$REPO_ROOT" ]; then
  if (cd "$REPO_ROOT" && git mv "$CHANGE_DIR_ABS" "$TARGET") >/dev/null 2>&1; then
    MOVED=1
  fi
fi
if [ "$MOVED" -eq 0 ]; then
  mv "$CHANGE_DIR_ABS" "$TARGET"
fi

# ── fail-closed: post-condition — source must be gone (XOR invariant) ──────
if [ -d "$CHANGE_DIR_ABS" ]; then
  echo "ERROR: archive-change.sh: move failed — source still exists: $CHANGE_DIR_ABS (XOR invariant violated)" >&2
  exit 1
fi

printf '%s\n' "$TARGET"
