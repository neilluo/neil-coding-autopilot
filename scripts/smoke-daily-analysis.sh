#!/usr/bin/env bash
# smoke-daily-analysis.sh — token-free regression test for scripts/daily-analysis.sh.
#
# Verifies, WITHOUT calling any real LLM/model (qodercli is shimmed):
#   1. fixture runs/*.jsonl → a valid metrics/<date>.json with correct aggregation
#      (malformed lines skipped, rates computed, LC_ALL=C decimal points).
#   2. categories backfill: after the stub agent writes a categories fragment,
#      numeric fields in metrics.json are byte-for-byte unchanged and only
#      top_problem_categories is replaced.
#   3. missing / empty / non-array categories fragment → merge skipped, the
#      PREVIOUS metrics.json content (numeric fields + categories) survives untouched.
#   4. no new runs for the day → the analysis agent is never dispatched (token-free
#      short-circuit) and no report is written.
#   5. --dry-run → no metrics/report files are written at all.
#
# Usage: bash scripts/smoke-daily-analysis.sh   # 0 = all pass, 1 = failure.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RUNNER="$SCRIPT_DIR/daily-analysis.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILED=1; }

if [ ! -f "$RUNNER" ]; then
  echo "FAIL: $RUNNER not found"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq not found (required for smoke assertions)"
  exit 1
fi

DATE="2026-07-18"

# ── stub qodercli: analysis agent writes report + categories fragment ───────
# STUB_MODE (env, read by the stub) toggles what the fake "analysis agent" does:
#   fragment   -> write a valid categories array + report (happy path)
#   none       -> write nothing (missing-fragment scenario)
#   nonarray   -> write a JSON object, not an array (rejected-fragment scenario)
#   marker     -> just record that it was invoked (used to prove "never called")
STUB_BIN="$WORK/bin"; mkdir -p "$STUB_BIN"
CALL_MARKER="$WORK/qodercli-was-called"
cat > "$STUB_BIN/qodercli" <<'STUB'
#!/usr/bin/env bash
attach=""
while [ $# -gt 0 ]; do
  case "$1" in
    --attachment) attach="$2"; shift 2;;
    -w|-m|-p|--permission-mode) shift 2;;
    *) shift;;
  esac
done
: > "$CALL_MARKER"
if ! grep -q "数据分析 agent" "$attach" 2>/dev/null; then
  echo "unexpected prompt" >&2
  exit 1
fi
root="${NEIL_AUTOPILOT_LOG_DIR:-}"
d="${AUTOPILOT_RUN_ID:-}"
mkdir -p "$root/reports" "$root/metrics"
echo "# stub report for $d" > "$root/reports/$d.md"
case "${STUB_MODE:-fragment}" in
  fragment) echo '[{"category":"stub-category","count":2}]' > "$root/metrics/$d.categories.json" ;;
  none) : ;;
  nonarray) echo '{"category":"not-an-array"}' > "$root/metrics/$d.categories.json" ;;
esac
echo "**Status:** DONE"
STUB
chmod +x "$STUB_BIN/qodercli"
export CALL_MARKER

write_fixture_runs() {  # $1=log_root
  local root="$1"
  mkdir -p "$root/runs" "$root/metrics" "$root/reports"
  cat > "$root/runs/$DATE.jsonl" <<EOF
{"ts":"${DATE}T01:00:00Z","run_id":"r1","event":"dispatch","stage":"implement","model":"Performance","duration_s":40,"exit_code":0,"input_tokens":100,"output_tokens":20,"cache_read_tokens":30,"cost_usd":0.1}
{"ts":"${DATE}T01:01:00Z","run_id":"r1","event":"dispatch","stage":"review","model":"Ultimate","duration_s":25,"exit_code":0,"input_tokens":200,"output_tokens":40,"cache_read_tokens":50,"cost_usd":0.2}
{"ts":"${DATE}T01:02:00Z","run_id":"r1","event":"dispatch","stage":"fix","model":"Performance","duration_s":30,"exit_code":1}
{"ts":"${DATE}T01:03:00Z","run_id":"r1","event":"round","task":"1","round":1,"verify":"pass","review":"REVIEW_FAIL"}
{"ts":"${DATE}T01:04:00Z","run_id":"r1","event":"round","task":"1","round":2,"verify":"pass","review":"REVIEW_PASS"}
{"ts":"${DATE}T01:05:00Z","run_id":"r1","event":"task","task":"1","title":"t1","final_status":"DONE","rounds":2,"committed":true}
{"ts":"${DATE}T01:06:00Z","run_id":"r1","event":"round","task":"2","round":1,"verify":"fail","review":"UNKNOWN"}
{"ts":"${DATE}T01:07:00Z","run_id":"r1","event":"task","task":"2","title":"t2","final_status":"BLOCKED","rounds":1,"committed":false}
this is not json, must be skipped
{"ts":"${DATE}T01:08:00Z","run_id":"r1","event":"run","change":"smoke","outcome":"blocked","duration_s":100}
EOF
}

run_daily() {  # $1=log_root; remaining args passed through to daily-analysis.sh
  local root="$1"; shift
  rm -f "$CALL_MARKER"
  PATH="$STUB_BIN:$PATH" AUTOPILOT_PLATFORM=qoder AUTOPILOT_TIMEOUT=20 \
    NEIL_AUTOPILOT_LOG_DIR="$root" bash "$RUNNER" --date "$DATE" "$@"
}

# ── scenario 1: fixture runs -> valid, correctly-aggregated metrics.json ─────
run_scenario_aggregation() {
  local root="$WORK/s1"
  write_fixture_runs "$root"
  STUB_MODE=none
  export STUB_MODE
  local out rc
  out="$(run_daily "$root" 2>&1)"
  rc=$?
  local metrics="$root/metrics/$DATE.json"

  [ "$rc" -eq 0 ] && pass "aggregation: exit 0" || { fail "aggregation: exit=$rc"; echo "$out" | sed 's/^/    | /'; }
  if [ ! -f "$metrics" ]; then
    fail "aggregation: $metrics not created"
    return
  fi
  if jq -e . "$metrics" >/dev/null 2>&1; then
    pass "aggregation: metrics.json is valid JSON"
  else
    fail "aggregation: metrics.json is NOT valid JSON"
  fi

  # malformed line skipped (10 lines in fixture, 1 malformed -> 9 counted)
  local runs tasks_total tasks_done tasks_blocked verify_fail_rate review_fail_rate dispatch_err dispatch_to
  runs=$(jq -r '.runs' "$metrics")
  tasks_total=$(jq -r '.tasks_total' "$metrics")
  tasks_done=$(jq -r '.tasks_done' "$metrics")
  tasks_blocked=$(jq -r '.tasks_blocked' "$metrics")
  verify_fail_rate=$(jq -r '.verify_fail_rate' "$metrics")
  review_fail_rate=$(jq -r '.review_fail_rate' "$metrics")
  dispatch_err=$(jq -r '.dispatch_error_count' "$metrics")
  dispatch_to=$(jq -r '.dispatch_timeout_count' "$metrics")

  [ "$runs" = "1" ] && pass "aggregation: runs=1" || fail "aggregation: runs=$runs (expected 1)"
  [ "$tasks_total" = "2" ] && pass "aggregation: tasks_total=2" || fail "aggregation: tasks_total=$tasks_total (expected 2)"
  [ "$tasks_done" = "1" ] && pass "aggregation: tasks_done=1" || fail "aggregation: tasks_done=$tasks_done (expected 1)"
  [ "$tasks_blocked" = "1" ] && pass "aggregation: tasks_blocked=1" || fail "aggregation: tasks_blocked=$tasks_blocked (expected 1)"
  [ "$verify_fail_rate" = "0.33" ] && pass "aggregation: verify_fail_rate=0.33 (1 fail / 3 attempts)" || fail "aggregation: verify_fail_rate=$verify_fail_rate (expected 0.33)"
  [ "$review_fail_rate" = "0.33" ] && pass "aggregation: review_fail_rate=0.33 (1 fail / 3 rounds)" || fail "aggregation: review_fail_rate=$review_fail_rate (expected 0.33)"
  [ "$dispatch_err" = "1" ] && pass "aggregation: dispatch_error_count=1" || fail "aggregation: dispatch_error_count=$dispatch_err (expected 1)"
  [ "$dispatch_to" = "0" ] && pass "aggregation: dispatch_timeout_count=0" || fail "aggregation: dispatch_timeout_count=$dispatch_to (expected 0)"

  local usage_values by_stage by_model
  usage_values=$(jq -r '[.tokens_input_total, .tokens_output_total, .tokens_cache_read_total, .cost_usd_total, .dispatch_with_usage_count, .dispatch_total_count] | @tsv' "$metrics")
  [ "$usage_values" = $'300\t60\t80\t0.3\t2\t3' ] && pass "aggregation: token/cost totals and usage coverage correct" || fail "aggregation: usage totals=$usage_values (expected 300/60/80/0.3/2/3)"

  by_stage=$(jq -c '.by_stage' "$metrics")
  [ "$by_stage" = '{"implement":{"count":1,"duration_s":40,"input_tokens":100,"output_tokens":20,"cost_usd":0.1},"review":{"count":1,"duration_s":25,"input_tokens":200,"output_tokens":40,"cost_usd":0.2},"fix":{"count":1,"duration_s":30,"input_tokens":0,"output_tokens":0,"cost_usd":0}}' ] && pass "aggregation: by_stage correct" || fail "aggregation: by_stage=$by_stage"

  by_model=$(jq -c '.by_model' "$metrics")
  [ "$by_model" = '{"Performance":{"count":2,"duration_s":70,"input_tokens":100,"output_tokens":20,"cost_usd":0.1},"Ultimate":{"count":1,"duration_s":25,"input_tokens":200,"output_tokens":40,"cost_usd":0.2}}' ] && pass "aggregation: by_model correct" || fail "aggregation: by_model=$by_model"

  if [ -f "$CALL_MARKER" ]; then
    pass "aggregation: analysis agent WAS dispatched (new runs present)"
  else
    fail "aggregation: analysis agent was NOT dispatched despite new runs"
  fi
  unset STUB_MODE
}
run_scenario_aggregation

# ── scenario 2: categories backfill preserves numeric fields exactly ────────
run_scenario_backfill() {
  local root="$WORK/s2"
  write_fixture_runs "$root"
  STUB_MODE=fragment
  export STUB_MODE
  local metrics="$root/metrics/$DATE.json" before_numeric after_numeric cats
  run_daily "$root" >/dev/null 2>&1

  # capture the full object MINUS top_problem_categories as the "numeric/shape" baseline
  before_numeric="$(jq 'del(.top_problem_categories)' "$metrics")"
  cats="$(jq -c '.top_problem_categories' "$metrics")"

  if [ "$cats" = '[{"category":"stub-category","count":2}]' ]; then
    pass "backfill: top_problem_categories populated from fragment"
  else
    fail "backfill: top_problem_categories=$cats (expected stub-category fragment)"
  fi

  # re-run the SAME date with a stub that writes NOTHING this time -> must not
  # touch numeric fields, and must not reset categories back to [].
  STUB_MODE=none
  run_daily "$root" >/dev/null 2>&1
  after_numeric="$(jq 'del(.top_problem_categories)' "$metrics")"
  if [ "$before_numeric" = "$after_numeric" ]; then
    pass "backfill: numeric fields unchanged across re-run"
  else
    fail "backfill: numeric fields CHANGED across re-run"
  fi
  cats="$(jq -c '.top_problem_categories' "$metrics")"
  if [ "$cats" = '[{"category":"stub-category","count":2}]' ]; then
    pass "backfill: previous categories preserved when no new fragment"
  else
    fail "backfill: categories=$cats (expected previous fragment to survive)"
  fi
  unset STUB_MODE
}
run_scenario_backfill

# ── scenario 3: non-array fragment is rejected, metrics untouched ──────────
run_scenario_nonarray() {
  local root="$WORK/s3"
  write_fixture_runs "$root"
  STUB_MODE=none
  export STUB_MODE
  local metrics="$root/metrics/$DATE.json" before after
  run_daily "$root" >/dev/null 2>&1
  before="$(cat "$metrics")"

  STUB_MODE=nonarray
  run_daily "$root" >/dev/null 2>&1
  after="$(cat "$metrics")"

  if [ "$before" = "$after" ]; then
    pass "nonarray fragment: metrics.json byte-identical (merge skipped)"
  else
    fail "nonarray fragment: metrics.json CHANGED (should have been rejected)"
  fi
  unset STUB_MODE
}
run_scenario_nonarray

# ── scenario 4: no new runs for the day -> agent never dispatched ──────────
run_scenario_no_new_runs() {
  local root="$WORK/s4"
  mkdir -p "$root/runs" "$root/metrics" "$root/reports"
  # no runs/$DATE.jsonl at all
  STUB_MODE=fragment
  export STUB_MODE
  local out rc
  out="$(run_daily "$root" 2>&1)"
  rc=$?
  [ "$rc" -eq 0 ] && pass "no-new-runs: exit 0" || fail "no-new-runs: exit=$rc"
  if [ -f "$CALL_MARKER" ]; then
    fail "no-new-runs: analysis agent WAS dispatched (should be skipped, saves tokens)"
  else
    pass "no-new-runs: analysis agent NOT dispatched"
  fi
  if [ -f "$root/reports/$DATE.md" ]; then
    fail "no-new-runs: report was written despite no new runs"
  else
    pass "no-new-runs: no report written"
  fi
  # metrics.json is still produced (rotate+aggregate always run), just all-zero
  if [ -f "$root/metrics/$DATE.json" ] && jq -e . "$root/metrics/$DATE.json" >/dev/null 2>&1; then
    pass "no-new-runs: metrics.json still written (valid, zeroed)"
  else
    fail "no-new-runs: metrics.json missing or invalid"
  fi
  unset STUB_MODE
}
run_scenario_no_new_runs

# ── scenario 5: --dry-run writes nothing ────────────────────────────────────
run_scenario_dry_run() {
  local root="$WORK/s5"
  write_fixture_runs "$root"
  STUB_MODE=fragment
  export STUB_MODE
  run_daily "$root" --dry-run >/dev/null 2>&1
  if [ -f "$root/metrics/$DATE.json" ]; then
    fail "dry-run: metrics.json was written (should be untouched)"
  else
    pass "dry-run: no metrics.json written"
  fi
  if [ -f "$CALL_MARKER" ]; then
    fail "dry-run: analysis agent WAS dispatched"
  else
    pass "dry-run: analysis agent not dispatched"
  fi
  unset STUB_MODE
}
run_scenario_dry_run

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "SMOKE(daily-analysis): ALL PASS"
  exit 0
fi
echo "SMOKE(daily-analysis): FAILURES"
exit 1
