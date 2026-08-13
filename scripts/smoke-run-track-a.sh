#!/usr/bin/env bash
# smoke-run-track-a.sh — token-free regression test for run-track-a.sh.
#
# Verifies the Track A driver loop end-to-end WITHOUT calling a real model: it
# shims `qodercli` with a stub that echoes controllable status lines and makes a
# trivial file change. Scenarios:
#   1. HAPPY             : verify passes + REVIEW_PASS → all tasks DONE, commits made, exit 0.
#   2. FAIL-CLOSED       : verify always fails → driver stops exit 2, task BLOCKED,
#                          NO commit, NO false DONE.
#   3. COMMIT-FAILURE    : pre-commit hook rejects → exit 2, BLOCKED, no commit.
#   4. TRANSPORT-RETRY   : stub returns exit 1 + "Unable to connect." → 3 retries,
#                          exit 2 BLOCKED, no fixer, -a1/-a2/-a3 logs, round 1 only.
#   5. TIMEOUT-NO-RETRY  : stub sleeps past timeout → exit 2, no retry, wall ≤20s.
#   6. APP-FAIL-CLOSED   : review returns exit 1 + real CR body with REVIEW_FAIL → no
#                          retry, fixer invoked, round advances to 2.
#   7. MARKER-ANCHOR integration: unanchored body verdict fails closed; anchored pass succeeds.
# Also exercises task-state.sh's macOS flock-fallback (stock macOS has no flock).
#
# Usage: bash scripts/smoke-run-track-a.sh    # 0 = all pass, 1 = failure.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RUNNER="$SCRIPT_DIR/run-track-a.sh"
PARSE_MARKERS="$SCRIPT_DIR/parse-markers.sh"
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
# STUB_MODE overrides default behaviour
case "${STUB_MODE:-}" in
  transport)
    echo "Unable to connect."
    exit 1
    ;;
  timeout)
    # trap "" TERM so kill -TERM doesn't kill us, forcing KILL_AFTER
    trap "" TERM
    sleep 30
    exit 0
    ;;
  review_body_unknown)
    if grep -q "代码审查专家" "$attach" 2>/dev/null; then
      printf 'Body mentions REVIEW_FAIL but has no standalone verdict. %0400d\n' 0
      exit 1
    else
      printf 'stub implementation output %0400d\n' 0
      echo "stub work $(date +%s)-$RANDOM" >> "$wdir/stub-proof.txt"
      echo "**Status:** DONE"
    fi
    ;;
  review_app_fail)
    if grep -q "代码审查专家" "$attach" 2>/dev/null; then
      # Return exit 1 with a fat CR body containing REVIEW_FAIL (APP outcome)
      cat <<'CRBODY'
## Code Review

Examining the changes across 5 files, I found several issues that need attention.

### scripts/x.sh:12
MAJOR: The function does not handle empty input. When called with no arguments, it
will dereference a null pointer and crash the entire pipeline. This is a regression
from the previous version which had a guard clause.

### scripts/y.sh:34
MAJOR: SQL injection vulnerability in the query construction — user-supplied data is
concatenated directly without escaping or parameterisation.

### scripts/z.sh:56
CRITICAL: Hard-coded API key "sk-prod-xxxxxxxxxxxxxxxxxxxx" committed to source. This
must be rotated immediately and moved to an environment variable or secrets manager.

### scripts/w.sh:78
MINOR: Variable name shadows a global; rename to avoid confusion.

Overall the implementation logic in scripts/x.sh is sound but the three major/critical
issues listed above must be resolved before this can be merged.

REVIEW_FAIL
CRBODY
      exit 1
    else
      printf 'stub implementation output %0400d\n' 0
      echo "stub work $(date +%s)-$RANDOM" >> "$wdir/stub-proof.txt"
      echo "**Status:** DONE"
    fi
    ;;
  *)
    if grep -q "代码审查专家" "$attach" 2>/dev/null; then
      printf 'review output %0400d\n' 0
      echo "REVIEW_PASS"
    else
      printf 'stub implementation output %0400d\n' 0
      echo "stub work $(date +%s)-$RANDOM" >> "$wdir/stub-proof.txt"
      echo "**Status:** DONE"
    fi
    ;;
esac
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
echo "===== Scenario 4: TRANSPORT-RETRY (stub always exits 1 + 'Unable to connect.') ====="
P4="$(make_project true 1)"
set +e
TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder \
  STUB_MODE=transport \
  AUTOPILOT_TRANSPORT_RETRIES=3 \
  AUTOPILOT_RETRY_BACKOFF_S=0 \
  bash "$RUNNER" --change-dir "$P4/autopilot/changes/smoke" --cwd "$P4" --max-rounds 2 \
  > "$WORK/s4.log" 2>&1
rc4=$?
set -e

# ① attempt 1/3 .. 3/3 in log
a1=$(grep -c 'transport failure (attempt 1/3)' "$WORK/s4.log" || true)
a3=$(grep -c 'transport failure (attempt 3/3)' "$WORK/s4.log" || true)
[ "$a1" -ge 1 ] && pass "transport failure attempt 1/3 logged" || { fail "attempt 1/3 not found in log"; grep 'transport failure' "$WORK/s4.log" | sed 's/^/    | /'; }
[ "$a3" -ge 1 ] && pass "transport failure attempt 3/3 logged" || { fail "attempt 3/3 not found in log"; grep 'transport failure' "$WORK/s4.log" | sed 's/^/    | /'; }
backoff4=$(grep -c 'transport failure (attempt 1/3) → retry in 0s' "$WORK/s4.log" || true)
[ "$backoff4" -eq 1 ] && pass "AUTOPILOT_RETRY_BACKOFF_S=0 honored" || fail "zero retry backoff was not honored"

# ② round 1 only once, round 2 never
r1=$(grep -c 'round 1' "$WORK/s4.log" || true)
r2=$(grep -c 'round 2' "$WORK/s4.log" || true)
[ "$r1" -eq 1 ] && pass "round 1 appears exactly once" || fail "round 1 count=$r1 (expected 1)"
[ "$r2" -eq 0 ] && pass "round 2 never appears" || fail "round 2 appeared (should not)"

# ③ exit=2, task BLOCKED
[ "$rc4" -eq 2 ] && pass "exit 2 (transport exhausted)" || { fail "exit=$rc4 (expected 2)"; tail -10 "$WORK/s4.log" | sed 's/^/    | /'; }
b4=$(grep -c '^\*\*Status\*\*: BLOCKED$' "$P4/autopilot/changes/smoke/tasks.md" || true)
[ "$b4" -ge 1 ] && pass "task BLOCKED" || fail "BLOCKED count=$b4 (expected ≥1)"

# ④ no fixer dispatched — no "fix" dispatch line in driver log
fix4=$(grep -c '→ dispatch.*fix\|fix.*→ dispatch\|dispatch(.*fix\|fix.*dispatch' "$WORK/s4.log" || true)
[ "$fix4" -eq 0 ] && pass "no fixer dispatched" || { fail "fixer was dispatched ($fix4 times)"; grep -i 'fix' "$WORK/s4.log" | sed 's/^/    | /'; }

# ⑤ -a1/-a2/-a3 log files generated (look inside the driver log dir captured in TMPDIR)
# The driver logs to $TMPDIR/autopilot-track-a/<change>-<ts>/; find the dir
logdir4="$(ls -1td "$WORK"/autopilot-track-a/smoke-* 2>/dev/null | head -1 || true)"
if [ -n "$logdir4" ]; then
  a1f=$(ls "$logdir4"/task-1-impl-a1.log 2>/dev/null | wc -l | tr -d ' ')
  a2f=$(ls "$logdir4"/task-1-impl-a2.log 2>/dev/null | wc -l | tr -d ' ')
  a3f=$(ls "$logdir4"/task-1-impl-a3.log 2>/dev/null | wc -l | tr -d ' ')
  [ "$a1f" -ge 1 ] && pass "-a1 log exists" || fail "-a1 log missing in $logdir4"
  [ "$a2f" -ge 1 ] && pass "-a2 log exists" || fail "-a2 log missing in $logdir4"
  [ "$a3f" -ge 1 ] && pass "-a3 log exists" || fail "-a3 log missing in $logdir4"
else
  fail "cannot find driver log dir under $WORK/autopilot-track-a/"
fi

echo ""
echo "===== Scenario 5: TIMEOUT-NO-RETRY ====="
P5="$(make_project true 1)"
t5_start="$(date +%s)"
set +e
TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder \
  STUB_MODE=timeout \
  AUTOPILOT_TIMEOUT=2 AUTOPILOT_KILL_AFTER_S=1 \
  AUTOPILOT_RETRY_BACKOFF_S=0 \
  bash "$RUNNER" --change-dir "$P5/autopilot/changes/smoke" --cwd "$P5" --max-rounds 1 \
  > "$WORK/s5.log" 2>&1
rc5=$?
set -e
t5_end="$(date +%s)"
t5_wall=$(( t5_end - t5_start ))

retry5=$(grep -c 'retry in' "$WORK/s5.log" || true)
[ "$retry5" -eq 0 ] && pass "no 'retry in' (timeout not retried)" || fail "'retry in' found ($retry5 times)"
[ "$rc5" -eq 2 ] && pass "exit 2" || { fail "exit=$rc5 (expected 2)"; tail -10 "$WORK/s5.log" | sed 's/^/    | /'; }
[ "$t5_wall" -le 20 ] && pass "wall clock ≤ 20s (actual ${t5_wall}s)" || fail "wall clock ${t5_wall}s > 20s"

echo ""
echo "===== Scenario 6: APP-FAIL-CLOSED (review returns exit 1 + fat REVIEW_FAIL body) ====="
P6="$(make_project true 1)"
set +e
TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder \
  STUB_MODE=review_app_fail \
  AUTOPILOT_RETRY_BACKOFF_S=0 \
  bash "$RUNNER" --change-dir "$P6/autopilot/changes/smoke" --cwd "$P6" --max-rounds 2 \
  > "$WORK/s6.log" 2>&1
rc6=$?
set -e

# ① no retry (APP outcome → no retry, goes straight to fixer)
retry6=$(grep -c 'retry in' "$WORK/s6.log" || true)
[ "$retry6" -eq 0 ] && pass "no 'retry in' (APP not retried)" || fail "'retry in' found ($retry6 times)"

# ② fixer is dispatched (the review failure triggered the fixer path)
fix6=$(grep -c 'fix.*dispatch\|dispatch.*fix' "$WORK/s6.log" || true)
[ "$fix6" -ge 1 ] && pass "fixer dispatched" || { fail "fixer not dispatched"; tail -20 "$WORK/s6.log" | sed 's/^/    | /'; }

# ③ round advances to 2
r2_6=$(grep -c 'round 2' "$WORK/s6.log" || true)
[ "$r2_6" -ge 1 ] && pass "round advances to 2" || { fail "round 2 never appears"; grep 'round' "$WORK/s6.log" | sed 's/^/    | /'; }

echo ""
echo "===== Scenario 7: MARKER-ANCHOR integration ====="


# Driver integration: body mention without anchored verdict must be UNKNOWN and go to fixer.
P7="$(make_project true 1)"
set +e
TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder \
  STUB_MODE=review_body_unknown AUTOPILOT_RETRY_BACKOFF_S=0 \
  bash "$RUNNER" --change-dir "$P7/autopilot/changes/smoke" --cwd "$P7" --max-rounds 2 \
  > "$WORK/s7.log" 2>&1
rc7=$?
set -e
grep -q 'review = UNKNOWN.*fixer' "$WORK/s7.log" && pass "unanchored body verdict → UNKNOWN/fixer" || fail "unanchored body verdict did not fail closed"
retry7=$(grep -c 'retry in' "$WORK/s7.log" || true)
[ "$retry7" -eq 0 ] && pass "unanchored APP outcome is not transport-retried" || fail "unanchored APP outcome retried $retry7 times"

# Fixture A: body mentions REVIEW_FAIL but no anchored verdict at end → UNKNOWN
FIXTURE_A="$WORK/fixture-a.log"
cat > "$FIXTURE_A" <<'EOF'
This code review found many problems. In fact REVIEW_FAIL appears in this paragraph
as part of a sentence, and again here: REVIEW_FAIL is mentioned, and REVIEW_FAIL
is in the middle of text. There is no anchored verdict at the very end.
Some trailing lines with no verdict.
Another line.
Yet another line.
EOF
rv_a="$("$PARSE_MARKERS" review "$FIXTURE_A")"
[ "$rv_a" = "UNKNOWN" ] && pass "fixture-A (body REVIEW_FAIL, no anchor) → UNKNOWN" || fail "fixture-A expected UNKNOWN, got $rv_a"

# Fixture B: last anchored line is REVIEW_PASS → REVIEW_PASS
FIXTURE_B="$WORK/fixture-b.log"
cat > "$FIXTURE_B" <<'EOF'
Detailed review of the changes.
Everything looks good. The implementation is correct and follows the coding standards.
No CRITICAL or MAJOR issues found.

REVIEW_PASS
EOF
rv_b="$("$PARSE_MARKERS" review "$FIXTURE_B")"
[ "$rv_b" = "REVIEW_PASS" ] && pass "fixture-B (anchored REVIEW_PASS at end) → REVIEW_PASS" || fail "fixture-B expected REVIEW_PASS, got $rv_b"

# Fixture C: anchored Status at end → DONE
FIXTURE_C="$WORK/fixture-c.log"
cat > "$FIXTURE_C" <<'EOF'
Did some work. Status: mentioned in passing earlier in the body.
More text here.

**Status:** DONE
EOF
st_c="$("$PARSE_MARKERS" status "$FIXTURE_C")"
[ "$st_c" = "DONE" ] && pass "fixture-C (anchored **Status:** DONE) → DONE" || fail "fixture-C expected DONE, got $st_c"

# Fixture D: body mentions DONE but no anchored status → UNKNOWN
FIXTURE_D="$WORK/fixture-d.log"
cat > "$FIXTURE_D" <<'EOF'
I am going to mark this as DONE in the middle of a sentence.
The work is clearly DONE from my perspective but no final marker.
EOF
st_d="$("$PARSE_MARKERS" status "$FIXTURE_D")"
[ "$st_d" = "UNKNOWN" ] && pass "fixture-D (body DONE, no anchor) → UNKNOWN" || fail "fixture-D expected UNKNOWN, got $st_d"

echo ""
if [ "$FAILED" -eq 0 ]; then echo "SMOKE(run-track-a): ALL PASS"; exit 0; fi
echo "SMOKE(run-track-a): FAILURES"; exit 1
