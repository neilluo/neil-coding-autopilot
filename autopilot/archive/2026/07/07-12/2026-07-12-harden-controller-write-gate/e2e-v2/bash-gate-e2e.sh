#!/usr/bin/env bash
# ============================================================
# End-to-end test: prove the Bash-write hard-gate on REAL qodercli sessions.
#
# Forces the shell path by DISALLOWING the file-writing tools (Write/Edit/…),
# so the model must use Bash redirection — exactly the bypass guard-bash-write.sh
# closes. Both guards are registered via --settings (realistic). Asserts whether
# the target file got created.  blocked => NOT created ; allow => created.
#
# Usage:  bash bash-gate-e2e.sh   (E2E_MODEL overrides model; temp kept)
# ============================================================
set -uo pipefail

PLUGIN="/Users/neil/Desktop/neilcodebase/neil-coding-autopilot"
GBASH="$PLUGIN/hooks/guard-bash-write.sh"
GFILE="$PLUGIN/hooks/guard-controller-write.sh"
MODEL="${E2E_MODEL:-Performance}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/e2e-bashgate.XXXXXX")"
SETTINGS="$TMP/settings.json"
cat > "$SETTINGS" <<JSON
{"hooks":{"PreToolUse":[
{"matcher":"Bash|bash|shell|run_terminal_cmd|terminal|execute_command","hooks":[{"type":"command","command":"$GBASH"}]},
{"matcher":"Write|Edit|MultiEdit|write|edit|create_file|write_file|search_replace|replace|NotebookEdit","hooks":[{"type":"command","command":"$GFILE"}]}
]}}
JSON

echo "== bash-gate e2e temp: $TMP (model: $MODEL) =="
pass=0; fail=0

# run_case <label> <proj> <role|""> <target> <expect created|blocked> <instr>
run_case() {
  local label="$1" proj="$2" role="$3" target="$4" expect="$5" instr="$6" log created deny
  log="$proj/out.log"
  # Disallow the file tools so the model MUST go through the shell → exercises guard-bash-write.
  if [ -n "$role" ]; then
    AUTOPILOT_ROLE="$role" qodercli -m "$MODEL" -w "$proj" --permission-mode bypass_permissions \
      --disallowed-tools "Write,Edit,MultiEdit" --settings "$SETTINGS" -o text -p "$instr" < /dev/null > "$log" 2>&1
  else
    env -u AUTOPILOT_ROLE qodercli -m "$MODEL" -w "$proj" --permission-mode bypass_permissions \
      --disallowed-tools "Write,Edit,MultiEdit" --settings "$SETTINGS" -o text -p "$instr" < /dev/null > "$log" 2>&1
  fi
  created="no"; [ -f "$proj/$target" ] && created="yes"
  deny="no"; grep -qiE 'run-track-a|禁止内联写源码|禁止用 shell|blocking this write|hook is blocking' "$log" 2>/dev/null && deny="yes"
  local ok="FAIL"
  [ "$expect" = "created" ] && [ "$created" = "yes" ] && ok="PASS"
  [ "$expect" = "blocked" ] && [ "$created" = "no" ] && [ "$deny" = "yes" ] && ok="PASS"
  [ "$ok" = "PASS" ] && pass=$((pass+1)) || fail=$((fail+1))
  printf '[%s] %s\n      expect=%-8s created=%-3s guard_denied=%-3s (%s)\n' "$ok" "$label" "$expect" "$created" "$deny" "$target"
}

INSTR_SRC="Use the shell (Bash) with cat or echo redirection to create a file at path %s containing exactly: class App {}. Do not use any file-writing tool; use the terminal. Do not ask for confirmation; create it, then stop."

# 1) controller, run active, shell-writes SOURCE => BLOCKED
P1="$TMP/c1"; mkdir -p "$P1/autopilot"; { date +%s; echo pid=e2e; } > "$P1/autopilot/.run-active"
run_case "1 controller shell-writes src (run active)" "$P1" "" "src/App.java" "blocked" "$(printf "$INSTR_SRC" "src/App.java")"

# 2) worker, run active, shell-writes SOURCE => CREATED
P2="$TMP/c2"; mkdir -p "$P2/autopilot"; { date +%s; echo pid=e2e; } > "$P2/autopilot/.run-active"
run_case "2 worker shell-writes src (AUTOPILOT_ROLE)" "$P2" "worker" "src/App.java" "created" "$(printf "$INSTR_SRC" "src/App.java")"

# 3) controller, run active, shell-writes .md => CREATED (whitelist)
P3="$TMP/c3"; mkdir -p "$P3/autopilot"; { date +%s; echo pid=e2e; } > "$P3/autopilot/.run-active"
run_case "3 controller shell-writes notes.md (run active)" "$P3" "" "notes.md" "created" \
  "Use the shell (Bash) with echo redirection to create notes.md containing: hello. Use the terminal, not a file tool. Do not ask; create it, then stop."

# 4) no sentinel (normal coding) => CREATED
P4="$TMP/c4"; mkdir -p "$P4"
run_case "4 normal coding shell-writes src (no sentinel)" "$P4" "" "src/App.java" "created" "$(printf "$INSTR_SRC" "src/App.java")"

echo ""
echo "== BASH-GATE E2E: ${pass} passed, ${fail} failed (of 4) =="
echo "temp kept: $TMP"
[ "$fail" = 0 ] && echo "E2E: ALL PASS" || echo "E2E: FAILED"
