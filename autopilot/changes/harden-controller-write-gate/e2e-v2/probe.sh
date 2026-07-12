#!/usr/bin/env bash
# Quick 2-case probe to confirm the guard's deny/allow mechanism on THIS host
# via REAL qodercli sessions, and to capture the exact "denied" output signature
# (so the full suite's detection grep is correct). Not the real suite.
set -uo pipefail

PLUGIN="/Users/neil/Desktop/neilcodebase/neil-coding-autopilot"
GUARD="$PLUGIN/hooks/guard-controller-write.sh"
MODEL="${E2E_MODEL:-Performance}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/e2e-guard-probe.XXXXXX")"
echo "== probe temp: $TMP =="
echo "== guard: $GUARD =="
echo "== model: $MODEL =="

SETTINGS="$TMP/settings.json"
cat > "$SETTINGS" <<JSON
{"hooks":{"PreToolUse":[{"matcher":"Write|Edit|MultiEdit|write|edit|create_file|write_file|search_replace|replace|NotebookEdit","hooks":[{"type":"command","command":"$GUARD"}]}]}}
JSON

INSTR="Use ONLY your file-writing tool to create a file at path src/App.java containing exactly: class App {}. Do not use the shell/Bash/terminal. Do not ask for confirmation. Create it, then stop."

# --- deny case: controller (no role) writes source during an active run ---
P1="$TMP/deny-controller-src"; mkdir -p "$P1/autopilot"
{ date +%s; echo "pid=probe"; } > "$P1/autopilot/.run-active"
echo ""; echo "── CASE A: controller writes src (run active, NO role, Bash disallowed) → expect BLOCKED ──"
env -u AUTOPILOT_ROLE qodercli -m "$MODEL" -w "$P1" \
  --permission-mode bypass_permissions --disallowed-tools Bash \
  --settings "$SETTINGS" -o text -p "$INSTR" < /dev/null > "$P1/out.log" 2>&1
createdA="no"; [ -f "$P1/src/App.java" ] && createdA="yes"
echo "   file_created=$createdA (expect: no)"
echo "   ---- raw output (first 40 lines) ----"
sed -n '1,40p' "$P1/out.log" | sed 's/^/   | /'
echo "   -------------------------------------"

# --- allow case: worker writes source during an active run ---
P2="$TMP/allow-worker-src"; mkdir -p "$P2/autopilot"
{ date +%s; echo "pid=probe"; } > "$P2/autopilot/.run-active"
echo ""; echo "── CASE B: worker writes src (run active, AUTOPILOT_ROLE=worker, Bash disallowed) → expect CREATED ──"
AUTOPILOT_ROLE=worker qodercli -m "$MODEL" -w "$P2" \
  --permission-mode bypass_permissions --disallowed-tools Bash \
  --settings "$SETTINGS" -o text -p "$INSTR" < /dev/null > "$P2/out.log" 2>&1
createdB="no"; [ -f "$P2/src/App.java" ] && createdB="yes"
echo "   file_created=$createdB (expect: yes)"
echo "   ---- raw output (first 40 lines) ----"
sed -n '1,40p' "$P2/out.log" | sed 's/^/   | /'
echo "   -------------------------------------"

echo ""; echo "== PROBE DONE: A(deny) file_created=$createdA ; B(allow) file_created=$createdB =="
echo "== temp kept: $TMP =="
