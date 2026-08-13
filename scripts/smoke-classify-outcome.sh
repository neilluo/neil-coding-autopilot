#!/usr/bin/env bash
# WHAT: Exercise every classify-outcome.sh branch and required boundary case.
# USAGE: smoke-classify-outcome.sh
# EXIT CODES: 0 when all assertions pass; 1 otherwise.
set -uo pipefail

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

printf '%300s' '' | tr ' ' x > "$WORK/exactly-300.log"
assert_classification "exact threshold success" 0 "$WORK/exactly-300.log" OK

{
  printf 'REVIEW_FAIL\n'
  printf 'scripts/foo.sh:42: review found an application-level regression in task orchestration.\n'
  printf '%360s\n' '' | tr ' ' x
} > "$WORK/app.log"
assert_classification "substantive application failure" 1 "$WORK/app.log" APP

printf '%320s' '' | tr ' ' x > "$WORK/ok.log"
assert_classification "substantive success" 0 "$WORK/ok.log" OK

assert_classification "exit 124 timeout" 124 "$WORK/transport.log" TIMEOUT
assert_classification "exit 137 timeout" 137 "$WORK/missing-timeout.log" TIMEOUT

if [ "$FAILED" -eq 0 ]; then
  echo "SMOKE(classify-outcome): ALL PASS"
  exit 0
fi

echo "SMOKE(classify-outcome): FAILURES"
exit 1
