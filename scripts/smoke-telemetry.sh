#!/usr/bin/env bash
# smoke-telemetry.sh — token-free regression test for scripts/telemetry.sh.
#
# Verifies, WITHOUT calling any LLM/model:
#   1. telemetry_emit produces one valid JSON line per call (jq -e . passes),
#      including values with \r, Chinese characters, and tabs.
#   2. telemetry_rotate deletes an aged, NON-EMPTY runs/<dir> (and old .jsonl),
#      but keeps fresh ones — covering both BSD (`date -v-4d`) and GNU
#      (`date -d '4 days ago'`) mtime-backdating via `touch -t`.
#   3. NEIL_AUTOPILOT_TELEMETRY=0 results in zero disk writes.
#   4. telemetry_emit never writes to stdout (parse-status.sh reads stdout —
#      pollution there is a correctness bug, not a cosmetic one).
#   5. NEIL_AUTOPILOT_LOG_SINK=<name> routes telemetry_emit to a
#      caller-defined `_telemetry_sink_<name>` function instead of the file
#      backend (the pluggable sink seam, spec.md §3.2-3.3).
#   6. An unrecognized NEIL_AUTOPILOT_LOG_SINK value falls back to the file
#      backend (fail-safe) and stdout stays clean.
#
# Usage: bash scripts/smoke-telemetry.sh   # 0 = all pass, 1 = failure.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TELEMETRY="$SCRIPT_DIR/telemetry.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0

fail() { echo "FAIL: $1"; FAILED=1; }
pass() { echo "PASS: $1"; }

if [ ! -f "$TELEMETRY" ]; then
  echo "FAIL: $TELEMETRY not found"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq not found (required for smoke assertions)"
  exit 1
fi

# ── scenario 1: emit produces valid JSON, incl. \r / Chinese / tabs ─────────
run_emit_scenario() {
  local root="$WORK/s1"
  mkdir -p "$root"
  (
    NEIL_AUTOPILOT_LOG_DIR="$root"
    export NEIL_AUTOPILOT_LOG_DIR
    . "$TELEMETRY"
    telemetry_emit_dispatch 0 "$(date +%s)"
    telemetry_emit_round "run-1" "Task 1" 1 "pass" "REVIEW_PASS"
    weird=$'带\r回车\n换行\t制表 中文 "quote" \\backslash'
    telemetry_emit_task "run-1" "Task 1" "$weird" "DONE" 1 "true"
    telemetry_emit_run "run-1" "smoke-change" "complete" 12
  )

  local jsonl="$root/runs/$(date +%F).jsonl"
  if [ ! -f "$jsonl" ]; then
    fail "emit scenario: $jsonl not created"
    return
  fi
  local lines=0 bad=0
  while IFS= read -r line; do
    lines=$((lines + 1))
    if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
      bad=$((bad + 1))
    fi
  done < "$jsonl"
  if [ "$lines" -ne 4 ]; then
    fail "emit scenario: expected 4 lines, got $lines"
  elif [ "$bad" -ne 0 ]; then
    fail "emit scenario: $bad/$lines lines are not valid JSON"
  else
    pass "emit scenario: $lines/$lines lines are valid JSON (incl. \\r/中文/tab)"
  fi
}
run_emit_scenario

# ── scenario 2: rotate deletes aged non-empty dir + old jsonl, keeps fresh ──
run_rotate_scenario() {
  local root="$WORK/s2"
  mkdir -p "$root/runs"

  # Backdate helper: BSD `date -v-Nd` (macOS) or GNU `date -d 'N days ago'`.
  local old_stamp=""
  if date -v-4d +%Y%m%d%H%M >/dev/null 2>&1; then
    old_stamp="$(date -v-4d +%Y%m%d%H%M)"
  else
    old_stamp="$(date -d '4 days ago' +%Y%m%d%H%M)"
  fi

  local old_dir="$root/runs/old-run" new_dir="$root/runs/new-run"
  mkdir -p "$old_dir" "$new_dir"
  echo "leftover worker output" > "$old_dir/review.log"
  echo "leftover worker output" > "$new_dir/review.log"
  echo '{"a":1}' > "$root/runs/old.jsonl"
  echo '{"a":1}' > "$root/runs/$(date +%F).jsonl"

  touch -t "$old_stamp" "$old_dir" "$old_dir/review.log" "$root/runs/old.jsonl"

  (
    NEIL_AUTOPILOT_LOG_DIR="$root"
    export NEIL_AUTOPILOT_LOG_DIR
    . "$TELEMETRY"
    telemetry_rotate 3
  )

  if [ -e "$old_dir" ]; then
    fail "rotate scenario: aged non-empty dir '$old_dir' was NOT deleted"
  elif [ -e "$root/runs/old.jsonl" ]; then
    fail "rotate scenario: aged old.jsonl was NOT deleted"
  elif [ ! -d "$new_dir" ] || [ ! -f "$root/runs/$(date +%F).jsonl" ]; then
    fail "rotate scenario: fresh dir/jsonl were incorrectly deleted"
  else
    pass "rotate scenario: aged non-empty dir + old .jsonl deleted, fresh kept"
  fi
}
run_rotate_scenario

# ── scenario 3: NEIL_AUTOPILOT_TELEMETRY=0 -> zero disk writes ─────────────
run_disabled_scenario() {
  local root="$WORK/s3"
  # Do NOT mkdir root ourselves — a real "first use" should not create it.
  (
    NEIL_AUTOPILOT_LOG_DIR="$root"
    NEIL_AUTOPILOT_TELEMETRY=0
    export NEIL_AUTOPILOT_LOG_DIR NEIL_AUTOPILOT_TELEMETRY
    . "$TELEMETRY"
    telemetry_emit_dispatch 0 "$(date +%s)"
    telemetry_emit_round "run-1" "Task 1" 1 "pass" "REVIEW_PASS"
  )
  if [ -e "$root" ]; then
    fail "disabled scenario: $root was created despite NEIL_AUTOPILOT_TELEMETRY=0"
  else
    pass "disabled scenario: zero disk writes with NEIL_AUTOPILOT_TELEMETRY=0"
  fi
}
run_disabled_scenario

# ── scenario 4: telemetry_emit never writes to stdout ───────────────────────
run_stdout_scenario() {
  local root="$WORK/s4" out=""
  mkdir -p "$root"
  out="$(
    NEIL_AUTOPILOT_LOG_DIR="$root"
    export NEIL_AUTOPILOT_LOG_DIR
    . "$TELEMETRY"
    telemetry_emit_dispatch 1 "$(date +%s)"
    telemetry_emit_task "run-1" "Task 1" "t" "BLOCKED" 2 "false"
  )"
  if [ -n "$out" ]; then
    fail "stdout scenario: telemetry_emit leaked to stdout: '$out'"
  else
    pass "stdout scenario: telemetry_emit stdout is empty"
  fi
}
run_stdout_scenario

# ── scenario 5: custom sink seam is pluggable via NEIL_AUTOPILOT_LOG_SINK ───
run_custom_sink_scenario() {
  local root="$WORK/s5"
  mkdir -p "$root"
  (
    NEIL_AUTOPILOT_LOG_DIR="$root"
    export NEIL_AUTOPILOT_LOG_DIR
    . "$TELEMETRY"
    _telemetry_sink_capture() { printf '%s\n' "${1:-}" >> "$root/captured"; }
    NEIL_AUTOPILOT_LOG_SINK=capture
    export NEIL_AUTOPILOT_LOG_SINK
    telemetry_emit_run "run-1" "smoke-change" "complete" 5
  )

  local jsonl="$root/runs/$(date +%F).jsonl"
  if [ ! -f "$root/captured" ]; then
    fail "custom sink scenario: $root/captured not created"
  elif [ -e "$jsonl" ]; then
    fail "custom sink scenario: $jsonl was created (should have gone to custom sink only)"
  elif ! grep -q '"event":"run"' "$root/captured"; then
    fail "custom sink scenario: captured file missing expected event line"
  else
    pass "custom sink scenario: custom _telemetry_sink_capture received the line, file sink untouched"
  fi
}
run_custom_sink_scenario

# ── scenario 6: unknown sink falls back to file, stdout stays clean ────────
run_unknown_sink_scenario() {
  local root="$WORK/s6" out=""
  mkdir -p "$root"
  out="$(
    NEIL_AUTOPILOT_LOG_DIR="$root"
    NEIL_AUTOPILOT_LOG_SINK=bogus
    export NEIL_AUTOPILOT_LOG_DIR NEIL_AUTOPILOT_LOG_SINK
    . "$TELEMETRY"
    telemetry_emit_run "run-1" "smoke-change" "complete" 5
  )"

  local jsonl="$root/runs/$(date +%F).jsonl"
  if [ -n "$out" ]; then
    fail "unknown sink scenario: stdout leaked: '$out'"
  elif [ ! -f "$jsonl" ]; then
    fail "unknown sink scenario: $jsonl not created (fallback to file did not happen)"
  elif ! jq -e . < "$jsonl" >/dev/null 2>&1; then
    fail "unknown sink scenario: $jsonl is not valid JSON"
  else
    pass "unknown sink scenario: unknown sink fell back to file, stdout clean"
  fi
}
run_unknown_sink_scenario

if [ "$FAILED" = 0 ]; then
  echo "SMOKE: ALL PASS"
  exit 0
else
  echo "SMOKE: FAILED"
  exit 1
fi
