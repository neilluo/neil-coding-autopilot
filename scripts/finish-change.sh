#!/usr/bin/env bash
# finish-change.sh — deterministic branch completion for a finished autopilot change.
#
# WHY THIS IS NOT AN LLM STEP (spec C10: 确定性工作用确定性脚本):
#   The finish flow is entirely mechanical — check every Task is DONE, merge the
#   feature branch into the detected base, move the change dir into archive/,
#   commit, drop the run sentinel. None of it needs judgement, yet routing it
#   through an agent worker made the unattended pipeline a coin flip: measured on
#   a real run, the finish worker produced no verdict 7/7 attempts (it emitted a
#   preamble line and stopped without executing a single tool), so `run-autopilot`
#   died at stage 2/3 *after* the whole loop had succeeded. Multi-step tool
#   sequences are exactly where headless truncation/silence hits hardest, and
#   there is nothing to gain by paying that risk for `git merge`.
#
# USAGE:
#   finish-change.sh --change-dir DIR [--cwd DIR] [--base BRANCH] [--no-merge] [--dry-run]
#
# EXIT CODES:
#   0  finished (prints FINISH_STATUS=DONE)
#   2  fail-closed gate tripped (prints FINISH_STATUS=BLOCKED: <reason>)
#   1  usage / environment error
#
# PORTABILITY: bash 3.2 (macOS stock); no GNU-only tools.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ARCHIVE_CHANGE="$SCRIPT_DIR/archive-change.sh"

usage() { echo "Usage: finish-change.sh --change-dir DIR [--cwd DIR] [--base BRANCH] [--no-merge] [--dry-run]"; }

CHANGE_DIR=""; CWD=""; BASE=""; DO_MERGE=1; DRY_RUN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --change-dir) [ "$#" -ge 2 ] || { usage >&2; exit 1; }; CHANGE_DIR="$2"; shift 2 ;;
    --cwd) [ "$#" -ge 2 ] || { usage >&2; exit 1; }; CWD="$2"; shift 2 ;;
    --base) [ "$#" -ge 2 ] || { usage >&2; exit 1; }; BASE="$2"; shift 2 ;;
    --no-merge) DO_MERGE=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1 (use --help)" >&2; usage >&2; exit 1 ;;
  esac
done

blocked() { echo "FINISH_STATUS=BLOCKED: $1"; exit 2; }

[ -n "$CHANGE_DIR" ] || { usage >&2; exit 1; }
[ -d "$CHANGE_DIR" ] || blocked "change dir not found: $CHANGE_DIR"
[ -x "$ARCHIVE_CHANGE" ] || [ -f "$ARCHIVE_CHANGE" ] || blocked "missing sibling script: $ARCHIVE_CHANGE"
if [ -z "$CWD" ]; then
  # change-dir is expected at <repo>/autopilot/changes/<name>
  CWD="$(cd "$CHANGE_DIR/../../.." && pwd -P)"
fi
[ -d "$CWD" ] || blocked "cwd not a directory: $CWD"
TASKS_FILE="$CHANGE_DIR/tasks.md"
[ -f "$TASKS_FILE" ] || blocked "tasks.md not found in $CHANGE_DIR"

# ── gate 1: every Task must be DONE ─────────────────────────────────────────
# Anything not DONE means the loop did not finish (or fail-closed mid-way), so
# merging would ship unreviewed/unverified work.
NOT_DONE="$(grep -nE '^\*\*Status\*\*:' "$TASKS_FILE" | grep -vE ':[[:space:]]*\*\*Status\*\*:[[:space:]]*(DONE|DONE_WITH_CONCERNS)[[:space:]]*$' || true)"
if [ -n "$NOT_DONE" ]; then
  echo "$NOT_DONE" | sed 's/^/  unfinished: /' >&2
  blocked "tasks.md still has Task(s) that are not DONE"
fi
TASK_COUNT="$(grep -cE '^\*\*Status\*\*:' "$TASKS_FILE" || true)"
[ "${TASK_COUNT:-0}" -ge 1 ] || blocked "tasks.md declares no Task status lines"

cd "$CWD" || blocked "cannot enter cwd: $CWD"
git rev-parse --git-dir >/dev/null 2>&1 || blocked "not a git repository: $CWD"

# ── gate 2: worktree must be clean ──────────────────────────────────────────
# run-track-a commits after every Task, so leftovers mean something unexpected
# happened (a silent worker's half-edit, a stray file). Never merge blind.
DIRTY="$(git status --porcelain 2>/dev/null || true)"
if [ -n "$DIRTY" ]; then
  echo "$DIRTY" | sed 's/^/  dirty: /' >&2
  blocked "worktree has uncommitted changes; commit or discard them first"
fi

CURRENT="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[ -n "$CURRENT" ] && [ "$CURRENT" != HEAD ] || blocked "detached HEAD; cannot finish"

# ── base branch detection (C4: never hardcode the trunk name) ───────────────
if [ -z "$BASE" ]; then
  for candidate in master main; do
    if git show-ref --verify --quiet "refs/heads/$candidate"; then BASE="$candidate"; break; fi
  done
fi
[ -n "$BASE" ] || blocked "cannot detect a base branch (looked for master, main); pass --base"
git show-ref --verify --quiet "refs/heads/$BASE" || blocked "base branch does not exist: $BASE"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY-RUN: would merge '$CURRENT' into '$BASE', archive $CHANGE_DIR, then commit"
  echo "FINISH_STATUS=DONE"
  exit 0
fi

# ── merge feature branch into base (fail-closed on conflict) ────────────────
if [ "$DO_MERGE" -eq 1 ] && [ "$CURRENT" != "$BASE" ]; then
  git checkout "$BASE" >/dev/null 2>&1 || blocked "cannot checkout base branch $BASE"
  if ! git merge --no-ff -m "merge: $(basename "$CHANGE_DIR")" "$CURRENT" >/dev/null 2>&1; then
    git merge --abort >/dev/null 2>&1 || true
    git checkout "$CURRENT" >/dev/null 2>&1 || true
    blocked "merge of '$CURRENT' into '$BASE' conflicted (merge aborted, branch restored)"
  fi
  echo "merged '$CURRENT' into '$BASE'"
else
  echo "merge skipped (current=$CURRENT base=$BASE do_merge=$DO_MERGE)"
fi

# ── archive the change dir (delegated; idempotent + XOR invariant) ──────────
if ! ARCHIVE_OUT="$(bash "$ARCHIVE_CHANGE" --change-dir "$CHANGE_DIR" 2>&1)"; then
  echo "$ARCHIVE_OUT" | sed 's/^/  archive: /' >&2
  blocked "archive-change.sh failed"
fi
echo "$ARCHIVE_OUT" | sed 's/^/  archive: /'
[ ! -d "$CHANGE_DIR" ] || blocked "change dir still exists after archiving (XOR invariant violated): $CHANGE_DIR"

# ── commit the archive move ─────────────────────────────────────────────────
git add -A >/dev/null 2>&1 || true
if git diff --cached --quiet; then
  echo "nothing to commit for the archive move"
else
  git commit -m "chore(autopilot): archive $(basename "$CHANGE_DIR")" >/dev/null 2>&1 \
    || blocked "committing the archive move failed (hook/signing?)"
  echo "committed the archive move"
fi

# ── drop the run sentinel (idempotent) ─────────────────────────────────────
rm -f "$CWD/autopilot/.run-active" 2>/dev/null || true

echo "FINISH_STATUS=DONE"
exit 0
