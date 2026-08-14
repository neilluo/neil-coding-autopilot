#!/usr/bin/env bash
# Smoke test for hooks/guard-controller-write.sh (controller write hard-gate).
#
# Verifies — WITHOUT burning LLM tokens — the guard's allow/deny decisions by
# feeding it synthetic PreToolUse stdin JSON and asserting exit codes:
#   exit 2 = deny, exit 0 = allow.
# Intended for CI and post-install self-check.
#
# Usage:  bash scripts/smoke-guard.sh
# Exit:   0 = all cases pass, 1 = any failure.
set -uo pipefail
unset AUTOPILOT_RUN_ID

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/../hooks/guard-controller-write.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Fake project WITH an active-run sentinel (= inside an autopilot run).
RUN_DIR="$WORK/run"; mkdir -p "$RUN_DIR/autopilot"
printf '%s\npid=%s\n' "$(date +%s)" "$$" > "$RUN_DIR/autopilot/.run-active"
# Fake project WITHOUT a sentinel (= normal, non-autopilot coding).
BARE_DIR="$WORK/bare"; mkdir -p "$BARE_DIR"

fail=0

# Build a PreToolUse JSON.  $1=cwd $2=tool_name $3=file_path $4=permission_mode
mk() {
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"%s","permission_mode":"%s","tool_input":{"file_path":"%s"}}' \
    "$1" "$2" "$4" "$3"
}

# check <expect_exit> <label> <json> [role]
check() {
  local expect="$1" label="$2" json="$3" role="${4:-}" rc
  if [ -n "$role" ]; then
    printf '%s' "$json" | AUTOPILOT_ROLE="$role" bash "$GUARD" >/dev/null 2>&1
  else
    printf '%s' "$json" | env -u AUTOPILOT_ROLE bash "$GUARD" >/dev/null 2>&1
  fi
  rc=$?
  if [ "$rc" = "$expect" ]; then
    echo "PASS: $label (exit $rc)"
  else
    echo "FAIL: $label — expected exit $expect, got $rc"; fail=1
  fi
}

# 1. run-time controller writes SOURCE => deny
check 2 "controller writes src during run"       "$(mk "$RUN_DIR" Write "$RUN_DIR/src/App.java" "")"
# 2. worker writes source (AUTOPILOT_ROLE) => allow
check 0 "worker writes src (AUTOPILOT_ROLE)"      "$(mk "$RUN_DIR" Write "$RUN_DIR/src/App.java" "")" worker
# 3. bypass mode but NO worker role => STILL denied (bypass alone grants nothing)
check 2 "bypass-but-no-role writes src => deny"   "$(mk "$RUN_DIR" Write "$RUN_DIR/src/App.java" bypassPermissions)"
# 4. controller writes autopilot artifact => allow
check 0 "controller writes autopilot/spec.md"     "$(mk "$RUN_DIR" Write "$RUN_DIR/autopilot/changes/x/spec.md" "")"
# 5. controller writes .md => allow
check 0 "controller writes README.md"             "$(mk "$RUN_DIR" Write "$RUN_DIR/README.md" "")"
# 6. NOT in a run (no sentinel) => allow even for source
check 0 "normal coding (no sentinel)"             "$(mk "$BARE_DIR" Write "$BARE_DIR/src/App.java" "")"
# 7. IDE alias create_file is also gated => deny
check 2 "controller create_file src during run"   "$(mk "$RUN_DIR" create_file "$RUN_DIR/src/Main.py" "")"
# 7b. NotebookEdit is also gated => deny
check 2 "controller NotebookEdit ipynb during run" "$(mk "$RUN_DIR" NotebookEdit "$RUN_DIR/nb/Analysis.ipynb" "")"

# 8. jq-missing degradation: run under a PATH without jq; sed fallback must still deny.
if command -v jq >/dev/null 2>&1; then
  MINI="$WORK/minibin"; mkdir -p "$MINI"
  for tool in bash sh sed cat date stat env grep head printf dirname; do
    p="$(command -v "$tool" 2>/dev/null)"; [ -n "$p" ] && ln -sf "$p" "$MINI/$tool"
  done
  json8="$(mk "$RUN_DIR" Write "$RUN_DIR/src/App.java" "")"
  printf '%s' "$json8" | PATH="$MINI" env -u AUTOPILOT_ROLE bash "$GUARD" >/dev/null 2>&1
  rc=$?
  if [ "$rc" = 2 ]; then echo "PASS: jq-missing sed-fallback still denies (exit 2)"; else echo "FAIL: jq-missing — expected exit 2, got $rc"; fail=1; fi
else
  echo "INFO: jq not installed; sed fallback is the only code path (already exercised above)"
fi

if [ "$fail" = 0 ]; then echo "SMOKE-GUARD: ALL PASS"; else echo "SMOKE-GUARD: FAILED"; exit 1; fi
