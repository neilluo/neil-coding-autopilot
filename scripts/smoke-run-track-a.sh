#!/usr/bin/env bash
# smoke-run-track-a.sh — token-free regression test for run-track-a.sh.
#
# Verifies the Track A driver loop end-to-end WITHOUT calling a real model: it
# shims `qodercli` with a stub that echoes controllable status lines and makes a
# trivial file change. Two scenarios:
#   1. HAPPY       : verify passes + REVIEW_PASS → all tasks DONE, commits made, exit 0.
#   2. FAIL-CLOSED : verify always fails → driver stops exit 2, task BLOCKED,
#                    NO commit, NO false DONE.
# Also exercises task-state.sh's macOS flock-fallback (stock macOS has no flock).
#
# Usage: bash scripts/smoke-run-track-a.sh    # 0 = all pass, 1 = failure.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RUNNER="$SCRIPT_DIR/run-track-a.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0

# ── stub qodercli: reviewer→REVIEW_PASS; implementer/fixer→change file + DONE ──
STUB_BIN="$WORK/bin"; mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/qodercli" <<'STUB'
#!/usr/bin/env bash
wdir=""; attach=""
while [ $# -gt 0 ]; do
  case "$1" in
    -w) wdir="$2"; shift 2;;
    --attachment) attach="$2"; shift 2;;
    -m|-p|--permission-mode) shift 2;;
    *) shift;;
  esac
done
if grep -q "代码审查专家" "$attach" 2>/dev/null; then
  echo "REVIEW_PASS"
else
  echo "stub work $(date +%s)-$RANDOM" >> "$wdir/stub-proof.txt"
  echo "**Status:** DONE"
fi
STUB
chmod +x "$STUB_BIN/qodercli"

# ── helper: fresh temp git project (under WORK) with a canonical tasks.md ──────
make_project() {  # $1=verify-cmd  $2=num-tasks  → echoes project dir
  local verify="$1" ntasks="$2" proj chg n
  proj="$(mktemp -d "$WORK/proj.XXXXXX")"
  ( cd "$proj" && git init -q && git config user.email t@t && git config user.name t )
  chg="$proj/autopilot/changes/smoke"; mkdir -p "$chg"
  {
    echo "# Implementation Tasks — smoke"
    echo "> Verify command: \`$verify\`"
    echo "> Total tasks: $ntasks"
    echo
    n=1
    while [ "$n" -le "$ntasks" ]; do
      echo "## Task $n: smoke task $n"
      echo "**Files**: stub-proof.txt"
      echo "**Description**: append a line to stub-proof.txt."
      echo "**Verify**: \`$verify\`"
      echo "**Status**: PENDING"
      echo; echo "---"; echo
      n=$((n + 1))
    done
  } > "$chg/tasks.md"
  echo "$proj"
}

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILED=1; }

echo "===== Scenario 1: HAPPY (verify=true, 2 tasks) ====="
P1="$(make_project true 2)"
set +e
TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder \
  bash "$RUNNER" --change-dir "$P1/autopilot/changes/smoke" --cwd "$P1" --max-rounds 2 \
  > "$WORK/s1.log" 2>&1
rc1=$?
set -e
[ "$rc1" -eq 0 ] && pass "exit 0" || { fail "exit=$rc1 (expected 0)"; tail -15 "$WORK/s1.log" | sed 's/^/    | /'; }
d1=$(grep -c '^\*\*Status\*\*: DONE$' "$P1/autopilot/changes/smoke/tasks.md" || true)
[ "$d1" -eq 2 ] && pass "2 tasks DONE" || fail "DONE count=$d1 (expected 2)"
c1=$( cd "$P1" && git log --oneline 2>/dev/null | grep -c 'autopilot(track-a)' || true )
[ "$c1" -eq 2 ] && pass "2 commits" || fail "commit count=$c1 (expected 2)"

echo ""
echo "===== Scenario 2: FAIL-CLOSED (verify=false, 1 task) ====="
P2="$(make_project false 1)"
set +e
TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder \
  bash "$RUNNER" --change-dir "$P2/autopilot/changes/smoke" --cwd "$P2" --max-rounds 1 \
  > "$WORK/s2.log" 2>&1
rc2=$?
set -e
[ "$rc2" -eq 2 ] && pass "exit 2 (BLOCKED)" || { fail "exit=$rc2 (expected 2)"; tail -15 "$WORK/s2.log" | sed 's/^/    | /'; }
b2=$(grep -c '^\*\*Status\*\*: BLOCKED$' "$P2/autopilot/changes/smoke/tasks.md" || true)
[ "$b2" -eq 1 ] && pass "task BLOCKED" || fail "BLOCKED count=$b2 (expected 1)"
c2=$( cd "$P2" && git log --oneline 2>/dev/null | grep -c 'autopilot(track-a)' || true )
[ "$c2" -eq 0 ] && pass "no false commit" || fail "commit count=$c2 (expected 0)"

echo ""
echo "===== Scenario 3: COMMIT-FAILURE (pre-commit hook rejects) ====="
P3="$(make_project true 1)"
cat > "$P3/.git/hooks/pre-commit" <<'HOOK'
#!/bin/sh
exit 1
HOOK
chmod +x "$P3/.git/hooks/pre-commit"
set +e
TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder \
  bash "$RUNNER" --change-dir "$P3/autopilot/changes/smoke" --cwd "$P3" --max-rounds 1 \
  > "$WORK/s3.log" 2>&1
rc3=$?
set -e
[ "$rc3" -eq 2 ] && pass "exit 2 (commit failure → BLOCKED)" || { fail "exit=$rc3 (expected 2)"; tail -15 "$WORK/s3.log" | sed 's/^/    | /'; }
b3=$(grep -c '^\*\*Status\*\*: BLOCKED$' "$P3/autopilot/changes/smoke/tasks.md" || true)
[ "$b3" -eq 1 ] && pass "task BLOCKED (not DONE)" || fail "BLOCKED count=$b3 (expected 1)"
d3=$(grep -c '^\*\*Status\*\*: DONE$' "$P3/autopilot/changes/smoke/tasks.md" || true)
[ "$d3" -eq 0 ] && pass "not falsely DONE" || fail "false DONE count=$d3 (expected 0)"
c3=$( cd "$P3" && git log --oneline 2>/dev/null | grep -c 'autopilot(track-a)' || true )
[ "$c3" -eq 0 ] && pass "no commit" || fail "commit count=$c3 (expected 0)"

echo ""
if [ "$FAILED" -eq 0 ]; then echo "SMOKE(run-track-a): ALL PASS"; exit 0; fi
echo "SMOKE(run-track-a): FAILURES"; exit 1
