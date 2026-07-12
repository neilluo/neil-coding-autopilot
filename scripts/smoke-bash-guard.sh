#!/usr/bin/env bash
# Smoke test for hooks/guard-bash-write.sh (controller Bash-write hard-gate).
#
# Token-free: feeds synthetic PreToolUse stdin JSON (tool_name=Bash + a command)
# and asserts exit codes. exit 2 = deny, exit 0 = allow. The critical property
# is NO false-positives on legit orchestration shell (git/verify/log/dev-null),
# only real controller source-writes get denied.
#
# Usage:  bash scripts/smoke-bash-guard.sh   (0 = all pass, 1 = any failure)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/../hooks/guard-bash-write.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

RUN_DIR="$WORK/run"; mkdir -p "$RUN_DIR/autopilot"
printf '%s\npid=%s\n' "$(date +%s)" "$$" > "$RUN_DIR/autopilot/.run-active"
BARE_DIR="$WORK/bare"; mkdir -p "$BARE_DIR"

fail=0

# mk <cwd> <command>  -> PreToolUse JSON (uses python3 for safe JSON escaping)
mk() {
  CWD="$1" CMD="$2" python3 - <<'PY'
import json, os
print(json.dumps({
    "hook_event_name": "PreToolUse",
    "cwd": os.environ["CWD"],
    "tool_name": "Bash",
    "tool_input": {"command": os.environ["CMD"]},
}))
PY
}

# check <expect_exit> <label> <cwd> <command> [role]
check() {
  local expect="$1" label="$2" cwd="$3" cmd="$4" role="${5:-}" json rc
  json="$(mk "$cwd" "$cmd")"
  if [ -n "$role" ]; then
    printf '%s' "$json" | AUTOPILOT_ROLE="$role" bash "$GUARD" >/dev/null 2>&1
  else
    printf '%s' "$json" | env -u AUTOPILOT_ROLE bash "$GUARD" >/dev/null 2>&1
  fi
  rc=$?
  if [ "$rc" = "$expect" ]; then
    echo "PASS: $label (exit $rc)"
  else
    echo "FAIL: $label — expected $expect, got $rc"; fail=1
  fi
}

# ── DENY: controller shell-writes source during a run ────────────────────────
check 2 "cat > src/App.java"                 "$RUN_DIR" 'cat > src/App.java <<EOF
class App {}
EOF'
check 2 "echo >> src/main.py"                "$RUN_DIR" 'echo "x=1" >> src/main.py'
check 2 "pipe | tee lib/mod.go"              "$RUN_DIR" 'echo "package x" | tee lib/mod.go'
check 2 "printf > a/b/Deep.ts"               "$RUN_DIR" 'printf "const x=1" > a/b/Deep.ts'

# ── ALLOW: worker, whitelist, and legit orchestration shell ──────────────────
check 0 "worker cat > src/App.java"          "$RUN_DIR" 'cat > src/App.java' worker
check 0 "controller > notes.md"              "$RUN_DIR" 'echo hi > notes.md'
check 0 "controller > autopilot/spec.md"     "$RUN_DIR" 'echo x > autopilot/changes/x/spec.md'
check 0 "git add + commit (no redirect)"     "$RUN_DIR" 'git add -A && git commit -m "task 1"'
check 0 "verify > /tmp log (.log)"           "$RUN_DIR" 'python3 -m unittest discover > /tmp/verify.log 2>&1'
check 0 "run-track-a > /dev/null"            "$RUN_DIR" 'bash run-track-a.sh --change-dir x > /dev/null 2>&1'
check 0 "echo > output.txt (not source)"     "$RUN_DIR" 'echo done > output.txt'
check 0 "grep redirect 2>&1 only"            "$RUN_DIR" 'grep -R foo . 2>&1 | head'
# ── ALLOW: scope gate — not in a run ─────────────────────────────────────────
check 0 "no sentinel: cat > src/App.java"    "$BARE_DIR" 'cat > src/App.java'

# ── jq-missing degradation: sed fallback must still deny a clear source write ─
if command -v jq >/dev/null 2>&1; then
  MINI="$WORK/minibin"; mkdir -p "$MINI"
  for t in bash sh sed cat date stat env grep head printf dirname python3; do
    p="$(command -v "$t" 2>/dev/null)"; [ -n "$p" ] && ln -sf "$p" "$MINI/$t"
  done
  json="$(mk "$RUN_DIR" 'cat > src/App.java')"
  printf '%s' "$json" | PATH="$MINI" env -u AUTOPILOT_ROLE bash "$GUARD" >/dev/null 2>&1
  rc=$?
  if [ "$rc" = 2 ]; then echo "PASS: jq-missing sed-fallback still denies (exit 2)"; else echo "FAIL: jq-missing — expected 2, got $rc"; fail=1; fi
fi

if [ "$fail" = 0 ]; then echo "SMOKE-BASH-GUARD: ALL PASS"; else echo "SMOKE-BASH-GUARD: FAILED"; exit 1; fi
