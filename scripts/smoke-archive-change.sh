#!/usr/bin/env bash
# smoke-archive-change.sh — token-free regression test for
# scripts/archive-change.sh.
#
# Verifies, WITHOUT calling any LLM/model, in a scratch git repo:
#   1. Move: autopilot/archive/<DATE>-foo exists AND autopilot/changes/foo
#      is gone (O1 main invariant, XOR).
#   2. Idempotent re-run: exit 0, state unchanged (no re-move, no error).
#   3. --change-dir pointing at a nonexistent dir: exit 1 (discriminator:
#      silent success = FAIL).
#
# Usage: bash scripts/smoke-archive-change.sh   # 0 = all pass, 1 = failure.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ARCHIVE_CHANGE="$SCRIPT_DIR/archive-change.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0

fail() { echo "FAIL: $1"; FAILED=1; }
pass() { echo "PASS: $1"; }

if [ ! -f "$ARCHIVE_CHANGE" ]; then
  echo "FAIL: $ARCHIVE_CHANGE not found"
  exit 1
fi

REPO="$WORK/repo"
mkdir -p "$REPO/autopilot/changes/foo"
(
  cd "$REPO" && \
  git init -q && \
  git config user.email "smoke@test.local" && \
  git config user.name "smoke" && \
  echo "spec" > autopilot/changes/foo/spec.md && \
  git add -A && \
  git commit -q -m "init"
) >/dev/null

DATE_STR="2099-01-01"

# ── scenario 1: move — archive/<DATE>-foo appears, changes/foo disappears ──
run_move_scenario() {
  local out
  out="$(cd "$REPO" && bash "$ARCHIVE_CHANGE" --change-dir "autopilot/changes/foo" --date "$DATE_STR" 2>&1)"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "move: expected exit 0, got $rc (output: $out)"
    return
  fi
  if [ ! -d "$REPO/autopilot/archive/${DATE_STR}-foo" ]; then
    fail "move: autopilot/archive/${DATE_STR}-foo does not exist"
  elif [ -d "$REPO/autopilot/changes/foo" ]; then
    fail "move: autopilot/changes/foo still exists (XOR invariant violated)"
  else
    pass "move: archive/${DATE_STR}-foo exists AND changes/foo is gone"
  fi
  if [ ! -f "$REPO/autopilot/archive/${DATE_STR}-foo/summary.md" ]; then
    fail "move: summary.md skeleton not generated"
  else
    pass "move: summary.md skeleton generated"
  fi
}
run_move_scenario

# ── scenario 2: idempotent re-run — exit 0, state unchanged ────────────────
run_idempotent_scenario() {
  local out rc
  out="$(cd "$REPO" && bash "$ARCHIVE_CHANGE" --change-dir "autopilot/changes/foo" --date "$DATE_STR" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "idempotent: expected exit 0 on re-run, got $rc (output: $out)"
  elif [ ! -d "$REPO/autopilot/archive/${DATE_STR}-foo" ]; then
    fail "idempotent: archive dir vanished after re-run"
  elif [ -d "$REPO/autopilot/changes/foo" ]; then
    fail "idempotent: changes/foo reappeared after re-run"
  else
    pass "idempotent: re-run exits 0, state unchanged"
  fi
}
run_idempotent_scenario

# ── scenario 3: nonexistent --change-dir -> exit 1 (fail-closed) ───────────
run_missing_dir_scenario() {
  local rc
  (cd "$REPO" && bash "$ARCHIVE_CHANGE" --change-dir "autopilot/changes/does-not-exist" --date "$DATE_STR") >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "missing dir: expected exit 1 (silent success = FAIL), got 0"
  else
    pass "missing dir: exits non-zero (fail-closed)"
  fi
}
run_missing_dir_scenario

if [ "$FAILED" = 0 ]; then
  echo "SMOKE(archive-change): ALL PASS"
  exit 0
else
  echo "SMOKE(archive-change): FAILED"
  exit 1
fi
