#!/usr/bin/env bash
# smoke-kb-path.sh — token-free regression test for scripts/kb-path.sh.
#
# Verifies, WITHOUT calling any LLM/model:
#   1. NEIL_AUTOPILOT_KB_DIR set -> stdout is exactly that path (catches the
#      "still prints the default" regression).
#   2. env unset -> stdout contains ".neil-autopilot/knowledge".
#   3. --ensure creates raw/ and wiki/ subdirectories.
#
# Usage: bash scripts/smoke-kb-path.sh   # 0 = all pass, 1 = failure.
set -uo pipefail
unset AUTOPILOT_RUN_ID

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
KB_PATH="$SCRIPT_DIR/kb-path.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0

fail() { echo "FAIL: $1"; FAILED=1; }
pass() { echo "PASS: $1"; }

if [ ! -f "$KB_PATH" ]; then
  echo "FAIL: $KB_PATH not found"
  exit 1
fi

# ── scenario 1: env override -> stdout is exactly that path ────────────────
run_env_override_scenario() {
  local expect="$WORK/kbp-x" out
  out="$(NEIL_AUTOPILOT_KB_DIR="$expect" bash "$KB_PATH")"
  if [ "$out" != "$expect" ]; then
    fail "env override: expected exactly '$expect', got '$out'"
  else
    pass "env override: stdout is exactly \$NEIL_AUTOPILOT_KB_DIR"
  fi
}
run_env_override_scenario

# ── scenario 2: no env -> default under .neil-autopilot/knowledge ─────────
run_default_scenario() {
  local out
  out="$(env -u NEIL_AUTOPILOT_KB_DIR bash "$KB_PATH")"
  if ! printf '%s' "$out" | grep -q '\.neil-autopilot/knowledge'; then
    fail "default: expected output to contain '.neil-autopilot/knowledge', got '$out'"
  else
    pass "default: stdout contains .neil-autopilot/knowledge"
  fi
}
run_default_scenario

# ── scenario 3: --ensure creates raw/ and wiki/ ─────────────────────────────
run_ensure_scenario() {
  local dir="$WORK/kbp-ensure"
  NEIL_AUTOPILOT_KB_DIR="$dir" bash "$KB_PATH" --ensure >/dev/null
  if [ ! -d "$dir/raw" ] || [ ! -d "$dir/wiki" ]; then
    fail "--ensure: raw/ and/or wiki/ not created under '$dir'"
  else
    pass "--ensure: raw/ and wiki/ subdirectories exist"
  fi
}
run_ensure_scenario

if [ "$FAILED" = 0 ]; then
  echo "SMOKE(kb-path): ALL PASS"
  exit 0
else
  echo "SMOKE(kb-path): FAILED"
  exit 1
fi
