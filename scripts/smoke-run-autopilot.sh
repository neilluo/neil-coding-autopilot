#!/usr/bin/env bash
# smoke-run-autopilot.sh — token-free regression test for run-autopilot.sh.
#
# Verifies the Track A end-to-end orchestrator (loop → finish → evolve)
# WITHOUT calling a real model: shims `qodercli` with a stub that routes on
# attachment content (reviewer / finish / evolve / implementer-fixer) and
# drops hit-files for finish/evolve so the test can assert whether they ran.
#   1. HAPPY       : verify passes + REVIEW_PASS → loop DONE, finish + evolve
#                     both invoked (hit files exist), exit 0.
#   2. FAIL-CLOSED : verify always fails, --max-rounds 1 → loop BLOCKED exit 2,
#                     finish/evolve NEVER invoked (no hit files — no relay
#                     after a fail-closed stop).
#
# Usage: bash scripts/smoke-run-autopilot.sh    # 0 = all pass, 1 = failure.
set -uo pipefail
unset AUTOPILOT_RUN_ID
export AUTOPILOT_ALLOW_NESTED=1
unset AUTOPILOT_ROLE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RUNNER="$SCRIPT_DIR/run-autopilot.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0

# ── stub qodercli: reviewer→REVIEW_PASS; finish/evolve→hit-file + status;
#    otherwise (implementer/fixer)→change file + DONE ────────────────────────
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
  printf 'review output %0400d\n' 0
  echo "REVIEW_PASS"
elif grep -q "autopilot-finish" "$attach" 2>/dev/null; then
  touch "$WORK/finish.hit"
  printf 'finish output %0400d\n' 0
  echo "**Status:** DONE"
elif grep -q "autopilot-evolve" "$attach" 2>/dev/null; then
  touch "$WORK/evolve.hit"
  printf 'evolve output %0400d\n' 0
  echo "**Status:** DONE"
else
  echo "stub work $(date +%s)-$RANDOM" >> "$wdir/stub-proof.txt"
  printf 'worker output %0400d\n' 0
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

echo "===== Scenario 1: HAPPY (verify=true, 1 task) ====="
P1="$(make_project true 1)"
rm -f "$WORK/finish.hit" "$WORK/evolve.hit"
set +e
WORK="$WORK" TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder \
  bash "$RUNNER" --change-dir "$P1/autopilot/changes/smoke" --cwd "$P1" \
  > "$WORK/s1.log" 2>&1
rc1=$?
set -e
[ "$rc1" -eq 0 ] && pass "exit 0" || { fail "exit=$rc1 (expected 0)"; tail -15 "$WORK/s1.log" | sed 's/^/    | /'; }
[ -f "$WORK/finish.hit" ] && pass "finish.hit exists (finish invoked)" || fail "finish.hit missing"
[ -f "$WORK/evolve.hit" ] && pass "evolve.hit exists (evolve invoked)" || fail "evolve.hit missing"

echo ""
echo "===== Scenario 2: FAIL-CLOSED (verify=false, 1 task, --max-rounds 1) ====="
P2="$(make_project false 1)"
rm -f "$WORK/finish.hit" "$WORK/evolve.hit"
set +e
WORK="$WORK" TMPDIR="$WORK" PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder \
  bash "$RUNNER" --change-dir "$P2/autopilot/changes/smoke" --cwd "$P2" --max-rounds 1 \
  > "$WORK/s2.log" 2>&1
rc2=$?
set -e
[ "$rc2" -eq 2 ] && pass "exit 2 (loop BLOCKED)" || { fail "exit=$rc2 (expected 2)"; tail -15 "$WORK/s2.log" | sed 's/^/    | /'; }
[ ! -f "$WORK/finish.hit" ] && pass "finish.hit NOT created (no relay after BLOCKED)" || fail "finish.hit unexpectedly exists"
[ ! -f "$WORK/evolve.hit" ] && pass "evolve.hit NOT created (no relay after BLOCKED)" || fail "evolve.hit unexpectedly exists"

echo ""
if [ "$FAILED" -eq 0 ]; then echo "SMOKE(run-autopilot): ALL PASS"; exit 0; fi
echo "SMOKE(run-autopilot): FAILURES"; exit 1
