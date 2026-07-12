#!/usr/bin/env bash
# ============================================================
# End-to-end test: prove the controller write hard-gate on REAL qodercli sessions.
#
# Launches real `qodercli -p` sessions (headless, bypass mode) with the guard
# registered via --settings, in fake projects that vary (sentinel present?,
# AUTOPILOT_ROLE=worker?), and asserts whether the target file got created.
#
#   deny  => file must NOT be created ; allow => file must be created
#
# Usage:  bash e2e-test.sh   (creates a temp folder, kept for inspection)
# ============================================================
set -uo pipefail

PLUGIN="/Users/neil/Desktop/neilcodebase/neil-coding-autopilot"
GUARD="$PLUGIN/hooks/guard-controller-write.sh"
MODEL="${E2E_MODEL:-Performance}"

TMP="$(mktemp -d)"
echo "== e2e temp folder: $TMP =="
echo "== model: $MODEL =="
echo ""

# Shared test settings: register the guard as a PreToolUse hook (absolute path).
SETTINGS="$TMP/test-settings.json"
cat > "$SETTINGS" <<JSON
{"hooks":{"PreToolUse":[{"matcher":"Write|Edit|MultiEdit|write|edit|create_file|write_file|search_replace|replace|NotebookEdit","hooks":[{"type":"command","command":"$GUARD"}]}]}}
JSON

pass=0; fail=0

# run_case <label> <projdir> <role|""> <target_rel> <expect: created|blocked> <instruction>
run_case() {
  local label="$1" proj="$2" role="$3" target="$4" expect="$5" instr="$6"
  local log="$proj/.qodercli.out"
  if [ -n "$role" ]; then
    AUTOPILOT_ROLE="$role" qodercli -m "$MODEL" -w "$proj" \
      --permission-mode bypass_permissions --settings "$SETTINGS" -o text -p "$instr" < /dev/null > "$log" 2>&1
  else
    env -u AUTOPILOT_ROLE qodercli -m "$MODEL" -w "$proj" \
      --permission-mode bypass_permissions --settings "$SETTINGS" -o text -p "$instr" < /dev/null > "$log" 2>&1
  fi
  local created="no"; [ -f "$proj/$target" ] && created="yes"
  local guard_denied="no"; grep -qi "禁止内联写源码\|run-track-a.sh\|hook block" "$log" 2>/dev/null && guard_denied="yes"
  local ok="FAIL"
  if [ "$expect" = "created" ] && [ "$created" = "yes" ]; then ok="PASS"; fi
  if [ "$expect" = "blocked" ] && [ "$created" = "no" ]; then ok="PASS"; fi
  if [ "$ok" = "PASS" ]; then pass=$((pass+1)); else fail=$((fail+1)); fi
  echo "[$ok] $label"
  echo "      expect=$expect  file_created=$created  guard_denied_in_log=$guard_denied  ($target)"
}

INSTR_SRC="Use ONLY your file-writing tool (not shell/Bash) to create a file at path %s with the exact content: class App {}. Do not ask for confirmation; create it, then stop."
INSTR_MD="Use ONLY your file-writing tool (not shell/Bash) to create a file at path notes.md with the exact content: hello. Do not ask for confirmation; create it, then stop."

# --- Case 1: controller writes SOURCE during a run => BLOCKED ---
P1="$TMP/c1-controller-src"; mkdir -p "$P1/autopilot"; date +%s > "$P1/autopilot/.run-active"; echo "pid=e2e" >> "$P1/autopilot/.run-active"
run_case "1 controller writes src (run active, NO role)" "$P1" "" "src/App.java" "blocked" \
  "$(printf "$INSTR_SRC" "src/App.java")"

# --- Case 2: worker writes SOURCE during a run => CREATED ---
P2="$TMP/c2-worker-src"; mkdir -p "$P2/autopilot"; date +%s > "$P2/autopilot/.run-active"; echo "pid=e2e" >> "$P2/autopilot/.run-active"
run_case "2 worker writes src (run active, AUTOPILOT_ROLE=worker)" "$P2" "worker" "src/App.java" "created" \
  "$(printf "$INSTR_SRC" "src/App.java")"

# --- Case 3: controller writes .md during a run => CREATED (whitelist) ---
P3="$TMP/c3-controller-md"; mkdir -p "$P3/autopilot"; date +%s > "$P3/autopilot/.run-active"; echo "pid=e2e" >> "$P3/autopilot/.run-active"
run_case "3 controller writes notes.md (run active, NO role)" "$P3" "" "notes.md" "created" \
  "$INSTR_MD"

# --- Case 4: normal coding, NO run (no sentinel) => CREATED ---
P4="$TMP/c4-normal-src"; mkdir -p "$P4"
run_case "4 normal coding writes src (NO sentinel)" "$P4" "" "src/App.java" "created" \
  "$(printf "$INSTR_SRC" "src/App.java")"

echo ""
echo "== E2E SUMMARY: ${pass} passed, ${fail} failed (of 4) =="
echo "temp folder kept for inspection: $TMP"
if [ "$fail" = 0 ]; then echo "E2E: ALL PASS"; else echo "E2E: FAILED"; fi
