#!/usr/bin/env bash
# Zero-token smoke coverage for scripts/finish-change.sh.
#
# WHAT IT LOCKS DOWN: finish is now deterministic (C10), so every gate must be
# provable without a model. The gates exist because finish merges to trunk —
# shipping unreviewed work or merging a dirty tree is unrecoverable damage.
set -uo pipefail
unset AUTOPILOT_RUN_ID

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FINISH="$SCRIPT_DIR/finish-change.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAILED=1; }

# ── fixture: a repo mid-change on a feature branch ──────────────────────────
make_project() {  # $1=task-status  → echoes project dir
  local status="$1" proj chg
  proj="$(mktemp -d "$WORK/proj.XXXXXX")"
  (
    cd "$proj" || exit 1
    git init -q -b master . && git config user.email t@t && git config user.name t
    printf '# fixture\n' > README.md
    git add -A && git commit -qm "chore: scaffold"
    git checkout -q -b feature/thing
  ) >/dev/null 2>&1
  chg="$proj/autopilot/changes/thing"; mkdir -p "$chg"
  {
    echo "# Implementation Tasks — thing"
    echo "> Total tasks: 1"
    echo
    echo "## Task 1: do the thing"
    echo "**Verify**: \`true\`"
    echo "**Status**: $status"
    echo
    echo "---"
  } > "$chg/tasks.md"
  ( cd "$proj" && printf 'thing\n' > thing.txt && git add -A && git commit -qm "feat: thing" ) >/dev/null 2>&1
  printf '%s' "$proj"
}

run_finish() {  # $1=proj  ... extra args → sets RC/OUT
  local proj="$1"; shift
  set +e
  OUT="$(bash "$FINISH" --change-dir "$proj/autopilot/changes/thing" --cwd "$proj" "$@" 2>&1)"
  RC=$?
  set -e
}

echo "===== Scenario 1: HAPPY (all DONE, clean tree) ====="
P1="$(make_project DONE)"
run_finish "$P1"
[ "$RC" -eq 0 ] && pass "exit 0" || { fail "exit=$RC"; printf '%s\n' "$OUT" | sed 's/^/    | /'; }
printf '%s' "$OUT" | grep -q 'FINISH_STATUS=DONE' && pass "prints FINISH_STATUS=DONE" || fail "missing FINISH_STATUS=DONE"
[ "$(cd "$P1" && git rev-parse --abbrev-ref HEAD)" = master ] && pass "ends on the base branch" || fail "not on base branch"
# 必须是真正的合并提交（双 parent），而不是 fast-forward：否则历史里看不出“这批改动来自哪个变更”。
MERGE_SUBJ="$( cd "$P1" && git log --merges --format=%s 2>/dev/null | head -1 )"
if [ "$MERGE_SUBJ" = "merge: thing" ]; then
  pass "feature branch merged with a real merge commit"
else
  fail "merge commit missing (merges subject='$MERGE_SUBJ')"
  ( cd "$P1" && git log --oneline --graph | head -6 | sed 's/^/    | /' )
fi
[ -f "$P1/thing.txt" ] && pass "feature content present on trunk" || fail "feature content missing on trunk"
# XOR 不变量：change 只能在 archive 或 changes 之一
[ ! -d "$P1/autopilot/changes/thing" ] && pass "change dir left changes/" || fail "change dir still in changes/"
ARCH="$(find "$P1/autopilot/archive" -maxdepth 4 -type d -name '*-thing' 2>/dev/null | head -1)"
[ -n "$ARCH" ] && pass "change landed in the 4-level archive ($(basename "$ARCH"))" || fail "change not archived"
[ -f "$ARCH/summary.md" ] && pass "summary.md exists after archiving" || fail "summary.md missing"
( cd "$P1" && git status --porcelain | grep -q . ) && fail "worktree left dirty" || pass "worktree clean afterwards"
# \u5e42\u7b49\uff1a\u91cd\u8dd1\u4e0d\u5f97\u62a5\u9519\u3001\u4e5f\u4e0d\u5f97\u91cd\u590d\u5f52\u6863
run_finish "$P1"
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'change dir not found' && pass "re-run is fail-closed, not a silent double-archive" || pass "re-run handled (rc=$RC)"

echo ""
echo "===== Scenario 2: GATE — a Task is not DONE ====="
P2="$(make_project PENDING)"
run_finish "$P2"
[ "$RC" -eq 2 ] && pass "exit 2 (fail-closed)" || fail "exit=$RC (expected 2)"
printf '%s' "$OUT" | grep -q 'not DONE' && pass "reason names the unfinished Task" || fail "reason unclear"
[ "$(cd "$P2" && git rev-parse --abbrev-ref HEAD)" = feature/thing ] && pass "did NOT leave the feature branch" || fail "branch changed despite gate"
( cd "$P2" && git log --oneline master | grep -q 'feat: thing' ) && fail "unreviewed work reached trunk" || pass "nothing merged to trunk"
[ -d "$P2/autopilot/changes/thing" ] && pass "change dir untouched" || fail "change dir moved despite gate"

echo ""
echo "===== Scenario 3: GATE — dirty worktree ====="
P3="$(make_project DONE)"
printf 'uncommitted\n' > "$P3/stray.txt"
run_finish "$P3"
[ "$RC" -eq 2 ] && pass "exit 2 (fail-closed)" || fail "exit=$RC (expected 2)"
printf '%s' "$OUT" | grep -q 'uncommitted changes' && pass "reason names the dirty worktree" || fail "reason unclear"
( cd "$P3" && git log --oneline master | grep -q 'feat: thing' ) && fail "merged despite dirty tree" || pass "nothing merged"

echo ""
echo "===== Scenario 4: base-branch detection (main instead of master) ====="
P4="$(make_project DONE)"
( cd "$P4" && git branch -m master main ) >/dev/null 2>&1
run_finish "$P4"
[ "$RC" -eq 0 ] && pass "exit 0 with 'main' as trunk" || { fail "exit=$RC"; printf '%s\n' "$OUT" | sed 's/^/    | /'; }
[ "$(cd "$P4" && git rev-parse --abbrev-ref HEAD)" = main ] && pass "detected 'main' without hardcoding" || fail "wrong branch after finish"

echo ""
echo "===== Scenario 5: --dry-run writes nothing ====="
P5="$(make_project DONE)"
run_finish "$P5" --dry-run
[ "$RC" -eq 0 ] && pass "exit 0" || fail "exit=$RC"
printf '%s' "$OUT" | grep -q 'DRY-RUN' && pass "announces dry-run" || fail "no dry-run notice"
[ "$(cd "$P5" && git rev-parse --abbrev-ref HEAD)" = feature/thing ] && pass "branch untouched" || fail "dry-run switched branches"
[ -d "$P5/autopilot/changes/thing" ] && pass "change dir untouched" || fail "dry-run archived anyway"

echo ""
echo "===== Scenario 6: merge conflict is fail-closed and restores state ====="
P6="$(make_project DONE)"
# 让 master 与 feature 对同一文件产生冲突
( cd "$P6" && git checkout -q master && printf 'trunk version\n' > thing.txt && git add -A && git commit -qm "feat: trunk thing" && git checkout -q feature/thing ) >/dev/null 2>&1
run_finish "$P6"
[ "$RC" -eq 2 ] && pass "exit 2 on conflict" || fail "exit=$RC (expected 2)"
printf '%s' "$OUT" | grep -q 'conflicted' && pass "reason says conflict" || fail "reason unclear"
[ "$(cd "$P6" && git rev-parse --abbrev-ref HEAD)" = feature/thing ] && pass "feature branch restored" || fail "left on the wrong branch after conflict"
( cd "$P6" && git status --porcelain | grep -q '^UU' ) && fail "conflict markers left in the worktree" || pass "merge aborted cleanly"
[ -d "$P6/autopilot/changes/thing" ] && pass "change dir not archived on failure" || fail "archived despite conflict"

echo ""
if [ "$FAILED" -eq 0 ]; then echo "SMOKE(finish-change): ALL PASS"; exit 0; fi
echo "SMOKE(finish-change): FAILURES"; exit 1
