#!/usr/bin/env bash
# WHAT: Exercise every classify-outcome.sh branch and required boundary case.
# USAGE: smoke-classify-outcome.sh
# EXIT CODES: 0 when all assertions pass; 1 otherwise.
set -uo pipefail
unset AUTOPILOT_RUN_ID

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  echo "Usage: smoke-classify-outcome.sh"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CLASSIFIER="$SCRIPT_DIR/classify-outcome.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1 (expected=$2 actual=$3)"; FAILED=1; }

assert_classification() {
  local name="$1"
  local exit_code="$2"
  local log_file="$3"
  local expected="$4"
  local actual
  local rc

  actual="$(bash "$CLASSIFIER" "$exit_code" "$log_file")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "$name exit code" "0" "$rc"
  elif [ "$actual" = "$expected" ]; then
    pass "$name"
  else
    fail "$name" "$expected" "$actual"
  fi
}

printf 'Unable to connect.\n' > "$WORK/transport.log"
assert_classification "transport regex" 1 "$WORK/transport.log" TRANSPORT

printf 'brief failure\n' > "$WORK/short-failure.log"
assert_classification "short nonzero log" 1 "$WORK/short-failure.log" TRANSPORT

assert_classification "missing successful log" 0 "$WORK/missing.log" EMPTY

{ printf '%300s' '' | tr ' ' x; printf '\n**Status:** DONE\n'; } > "$WORK/exactly-300.log"
assert_classification "exact threshold success" 0 "$WORK/exactly-300.log" OK

{
  printf 'REVIEW_FAIL\n'
  printf 'scripts/foo.sh:42: review found an application-level regression in task orchestration.\n'
  printf '%360s\n' '' | tr ' ' x
} > "$WORK/app.log"
assert_classification "substantive application failure" 1 "$WORK/app.log" APP

{ printf '%320s' '' | tr ' ' x; printf '\n**Status:** DONE\n'; } > "$WORK/ok.log"
assert_classification "substantive success" 0 "$WORK/ok.log" OK

assert_classification "exit 124 timeout" 124 "$WORK/transport.log" TIMEOUT
assert_classification "exit 137 timeout" 137 "$WORK/missing-timeout.log" TIMEOUT

# 125 = 工具调用被截断（dispatch.sh 设的）。必须与 TRANSPORT 分开：它不可重试（实测原样
# 重试 3 次全部复现），而 TRANSPORT 会被上层退避重试到耗尽 —— 等于把一次注定失败的
# 调用按全价买三遍。两个断言成对：光有退出码不够，`timeout(1)` 也用 125 表示自身启动失败，
# 那种情况不能被当成截断（否则真的环境问题会拿到一段误导的 hint）。
printf 'ERROR: TRUNCATED_TOOL_USE - worker stopped at a tool call without executing it (no files changed).\n' > "$WORK/truncated.log"
assert_classification "exit 125 with truncation anchor" 125 "$WORK/truncated.log" TRUNCATED
assert_classification "exit 125 without anchor stays transport" 125 "$WORK/transport.log" TRANSPORT

# New cases (D18/D19 anchor-parse rules)

# Case 1: exit 1 + >300B body with "Unable to connect" text + REVIEW_FAIL marker → APP (not TRANSPORT)
{
  printf '%310s\n' '' | tr ' ' x
  printf 'Unable to connect to the remote service during processing.\n'
  printf '**REVIEW_FAIL**\n'
} > "$WORK/app-with-connect.log"
assert_classification "long log with transport text and REVIEW_FAIL marker" 1 "$WORK/app-with-connect.log" APP

# Case 2: short log with only "Unable to connect." → TRANSPORT
printf 'Unable to connect.\n' > "$WORK/short-transport.log"
assert_classification "short log Unable to connect only" 1 "$WORK/short-transport.log" TRANSPORT

# Case 3: 6KB body, tail -20 contains "502 Bad Gateway", no anchor marker → APP (exceeds transport length gate)
{
  python3 -c "print('x' * 6144)"
  printf '502 Bad Gateway\n'
} > "$WORK/long-gateway.log"
assert_classification "6KB log tail has 502 but no marker exceeds gate" 1 "$WORK/long-gateway.log" APP

# Case 4: 250B body, last line "**Status:** DONE", exit 0 → OK (anchor present, not EMPTY)
{
  printf '%230s\n' '' | tr ' ' x
  printf '**Status:** DONE\n'
} > "$WORK/short-done.log"
assert_classification "250B log with Status DONE exit 0" 0 "$WORK/short-done.log" OK

# Task 14: no anchored marker + exit 0 => EMPTY regardless of byte count
{
  printf '%s\n' "- Add verdict marker check (REVIEW_PASS/REVIEW_FAIL/**Status:** DONE/**Status:** BLOCKED) before transport"
  i=0; while [ "$i" -lt 8 ]; do printf 'padding %s to exceed threshold aaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' "$i"; i=$((i+1)); done
} > "$WORK/t14-truncated.log"
assert_classification "Task14: no-marker truncated exit0 is EMPTY" 0 "$WORK/t14-truncated.log" EMPTY

# Task 14: same log but toggle off => falls back to OK (byte-only behavior)
t14_off_actual="$(AUTOPILOT_NO_MARKER_IS_EMPTY=0 bash "$CLASSIFIER" 0 "$WORK/t14-truncated.log")"
if [ "$t14_off_actual" = "OK" ]; then
  echo "PASS: Task14 toggle off restores OK"
else
  echo "FAIL: Task14 toggle off expected OK got $t14_off_actual"; FAILED=$((FAILED+1))
fi

# Task 14: 5KB body with trailing Status DONE => OK (marker present, not EMPTY)
{
  python3 -c "print('x' * 5120)"
  printf '**Status:** DONE\n'
} > "$WORK/t14-longdone.log"
assert_classification "Task14: 5KB body with DONE marker is OK" 0 "$WORK/t14-longdone.log" OK

if [ "$FAILED" -eq 0 ]; then
  echo "SMOKE(classify-outcome): ALL PASS"
  exit 0
fi

echo "SMOKE(classify-outcome): FAILURES"
exit 1
