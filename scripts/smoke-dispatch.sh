#!/usr/bin/env bash
# Zero-token smoke coverage for scripts/dispatch.sh.
set -euo pipefail
unset AUTOPILOT_RUN_ID
export AUTOPILOT_ALLOW_NESTED=1
unset AUTOPILOT_ROLE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$SCRIPT_DIR/dispatch.sh"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"
mkdir -p "$BIN"
printf 'smoke prompt body\n' > "$ROOT/prompt.md"

make_stub() {
  local bin="$1" body="$2"
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$BIN/$bin"
  chmod +x "$BIN/$bin"
}
make_all_stubs() {
  local body="$1"
  make_stub qodercli "$body"
  make_stub claude "$body"
  make_stub codex "$body"
}

fail=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fail=1; }
assert_contains() {
  local text="$1" expected="$2" label="$3"
  if [[ "$text" == *"$expected"* ]]; then pass "$label"; else fail "$label (missing: $expected)"; printf '%s\n' "$text"; fi
}
run_capture() {
  local stdout_file="$1" stderr_file="$2"; shift 2
  set +e
  "$@" >"$stdout_file" 2>"$stderr_file"
  RUN_RC=$?
  set -e
}
base_dispatch() {
  bash "$DISPATCH" --model TestModel --cwd "$ROOT" --prompt-file "$ROOT/prompt.md" --instruction "reply OK" "$@"
}

# Existing three-platform flags and exit semantics.
make_all_stubs 'echo "CALLED $(basename "$0") $*"'
for spec in 'qoder|CALLED qodercli -m TestModel -w' 'claude|CALLED claude -m TestModel' 'codex|CALLED codex --model TestModel'; do
  plat="${spec%%|*}"; expected="${spec#*|}"
  out="$(AUTOPILOT_PLATFORM="$plat" AUTOPILOT_TIMEOUT=5 PATH="$BIN:$PATH" base_dispatch 2>&1)" || fail "$plat exits zero"
  assert_contains "$out" "$expected" "$plat flags"
done

# Timeout source priority and default stage behavior.
make_all_stubs 'echo OK'
check_timeout() {
  local label="$1" expected="$2"; shift 2
  run_capture "$ROOT/out" "$ROOT/err" env -u AUTOPILOT_TIMEOUT -u AUTOPILOT_TIMEOUT_REVIEW PATH="$BIN:$PATH" AUTOPILOT_PLATFORM=qoder "$@" bash "$DISPATCH" --model TestModel --cwd "$ROOT" --prompt-file "$ROOT/prompt.md" --instruction x
  [ "$RUN_RC" -eq 0 ] || fail "$label exits zero"
  assert_contains "$(<"$ROOT/err")" "stage=review timeout=${expected}s kill-after=30s model=TestModel" "$label"
}
check_timeout 'stage default' 900 AUTOPILOT_STAGE=review
check_timeout 'global timeout' 41 AUTOPILOT_STAGE=review AUTOPILOT_TIMEOUT=41
check_timeout 'stage timeout' 42 AUTOPILOT_STAGE=review AUTOPILOT_TIMEOUT=41 AUTOPILOT_TIMEOUT_REVIEW=42
run_capture "$ROOT/out" "$ROOT/err" env PATH="$BIN:$PATH" AUTOPILOT_PLATFORM=qoder AUTOPILOT_STAGE=review AUTOPILOT_TIMEOUT=41 AUTOPILOT_TIMEOUT_REVIEW=42 bash "$DISPATCH" --model TestModel --cwd "$ROOT" --prompt-file "$ROOT/prompt.md" --instruction x --timeout 43
assert_contains "$(<"$ROOT/err")" 'stage=review timeout=43s kill-after=30s model=TestModel' 'CLI timeout wins'
# Dynamic stage names must not execute or break indirect lookup.
run_capture "$ROOT/out" "$ROOT/err" env -u AUTOPILOT_TIMEOUT -u AUTOPILOT_TIMEOUT_REVIEW PATH="$BIN:$PATH" AUTOPILOT_PLATFORM=qoder 'AUTOPILOT_STAGE=review;false' bash "$DISPATCH" --model TestModel --cwd "$ROOT" --prompt-file "$ROOT/prompt.md" --instruction x
[ "$RUN_RC" -eq 0 ] && pass 'unsafe stage is handled safely' || fail 'unsafe stage is handled safely'
assert_contains "$(<"$ROOT/err")" 'timeout=600s' 'unsafe stage uses other default'

# O4: normal return and TERM-resistant worker killed after grace period.
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  make_stub qodercli 'exit 0'
  start=$(date +%s); run_capture "$ROOT/out" "$ROOT/err" env PATH="$BIN:$PATH" AUTOPILOT_PLATFORM=qoder AUTOPILOT_TIMEOUT=2 AUTOPILOT_KILL_AFTER_S=1 bash "$DISPATCH" --model TestModel --cwd "$ROOT" --prompt-file "$ROOT/prompt.md" --instruction x; elapsed=$(( $(date +%s) - start ))
  [ "$RUN_RC" -eq 0 ] && [ "$elapsed" -lt 5 ] && pass 'normal worker exits promptly' || fail "normal worker rc=$RUN_RC elapsed=${elapsed}s"
  make_stub qodercli 'trap "" TERM; sleep 30'
  TIMEOUT_LOG="$ROOT/log-timeout"; mkdir -p "$TIMEOUT_LOG"
  start=$(date +%s); run_capture "$ROOT/out" "$ROOT/err" env PATH="$BIN:$PATH" HOME="$ROOT" NEIL_AUTOPILOT_LOG_DIR="$TIMEOUT_LOG" AUTOPILOT_RUN_ID=timeout AUTOPILOT_ATTEMPT=3 AUTOPILOT_PLATFORM=qoder AUTOPILOT_TIMEOUT=2 AUTOPILOT_KILL_AFTER_S=1 bash "$DISPATCH" --model TestModel --cwd "$ROOT" --prompt-file "$ROOT/prompt.md" --instruction x; elapsed=$(( $(date +%s) - start ))
  [ "$RUN_RC" -eq 124 ] && [ "$elapsed" -le 8 ] && pass 'TERM-resistant worker is force-killed' || fail "TERM-resistant worker rc=$RUN_RC elapsed=${elapsed}s"
  assert_contains "$(<"$ROOT/err")" 'kill-after=1s' 'kill-after is logged'
  if command -v jq >/dev/null 2>&1; then
    timeout_jsonl="$(ls "$TIMEOUT_LOG/runs"/*.jsonl | head -1)"
    if jq -e -s '.[-1] | .failure_class=="TIMEOUT" and .attempt==3 and .prompt_bytes==18 and has("output_bytes")' "$timeout_jsonl" >/dev/null; then pass 'timeout telemetry is classified'; else fail 'timeout telemetry is classified'; fi
  fi
else
  echo 'SKIP: timeout/gtimeout unavailable; force-kill scenario cannot run'
fi

# qoder JSON result restoration, raw retention, usage metadata, and is_error exit.
if command -v jq >/dev/null 2>&1; then
  make_stub qodercli 'printf '\''%s\n'\'' '\''{"result":"report\\n**Status:** DONE","usage":{"input_tokens":101,"output_tokens":202,"cache_read_input_tokens":303,"context_usage_ratio":0.25},"total_cost_usd":0.0123,"num_turns":4,"duration_api_ms":567,"is_error":false}'\'''
  LOG="$ROOT/log"; mkdir -p "$LOG"
  run_capture "$ROOT/out" "$ROOT/err" env PATH="$BIN:$PATH" HOME="$ROOT" NEIL_AUTOPILOT_LOG_DIR="$LOG" NEIL_AUTOPILOT_RUN_ID=smoke AUTOPILOT_RUN_ID=smoke AUTOPILOT_PLATFORM=qoder AUTOPILOT_STAGE=review AUTOPILOT_ATTEMPT=2 AUTOPILOT_RAW_JSON="$ROOT/raw.json" bash "$DISPATCH" --model TestModel --cwd "$ROOT" --prompt-file "$ROOT/prompt.md" --instruction x --timeout 5
  assert_contains "$(<"$ROOT/out")" '**Status:** DONE' 'JSON result restored to stdout'
  jq -e '.result | contains("**Status:** DONE")' "$ROOT/raw.json" >/dev/null && pass 'raw JSON retained' || fail 'raw JSON retained'
  jsonl="$(ls "$LOG/runs"/*.jsonl | head -1)"
  jq -e -s '.[-1] | .input_tokens==101 and .output_tokens==202 and .cache_read_tokens==303 and .cost_usd==0.0123 and .context_ratio==0.25 and .num_turns==4 and .api_ms==567 and .attempt==2 and .prompt_bytes==18 and .output_bytes>0 and (.failure_class|not)' "$jsonl" >/dev/null && pass 'usage and always-on metadata emitted' || fail 'usage and always-on metadata emitted'
  make_stub qodercli 'printf '\''%s\n'\'' '\''{"result":"bad","is_error":true}'\'''
  run_capture "$ROOT/out" "$ROOT/err" env PATH="$BIN:$PATH" AUTOPILOT_PLATFORM=qoder bash "$DISPATCH" --model TestModel --cwd "$ROOT" --prompt-file "$ROOT/prompt.md" --instruction x --timeout 5
  [ "$RUN_RC" -eq 1 ] && pass 'is_error forces exit 1' || fail "is_error forces exit 1 (rc=$RUN_RC)"
else
  echo 'SKIP: jq unavailable; JSON extraction scenario cannot run'
fi

# jq-unavailable degradation: qoder must retain stdout and telemetry sans usage.
NOJQ="$ROOT/nojq"; mkdir -p "$NOJQ"; make_stub qodercli 'printf '\''%s\n'\'' '\''{"result":"**Status:** DONE","usage":{"input_tokens":999}}'\'''; cp "$BIN/qodercli" "$NOJQ/qodercli"
for utility in bash dirname date mkdir mktemp rm wc basename tr cp cat; do path="$(command -v "$utility" || true)"; [ -z "$path" ] || ln -sf "$path" "$NOJQ/$utility"; done
LOG="$ROOT/log-nojq"; mkdir -p "$LOG"
run_capture "$ROOT/out" "$ROOT/err" env PATH="$NOJQ" HOME="$ROOT" NEIL_AUTOPILOT_LOG_DIR="$LOG" AUTOPILOT_RUN_ID=nojq AUTOPILOT_PLATFORM=qoder bash "$DISPATCH" --model TestModel --cwd "$ROOT" --prompt-file "$ROOT/prompt.md" --instruction x --timeout 0
assert_contains "$(<"$ROOT/out")" '**Status:** DONE' 'jq-missing degradation preserves stdout'
if command -v jq >/dev/null 2>&1; then
  jsonl="$(ls "$LOG/runs"/*.jsonl | head -1)"
  if PATH="$BIN:$PATH" jq -e -s '.[-1] | has("prompt_bytes") and has("output_bytes") and has("attempt") and (has("input_tokens")|not)' "$jsonl" >/dev/null; then pass 'jq-missing telemetry omits usage'; else fail 'jq-missing telemetry omits usage'; fi
else
  echo 'SKIP: host jq unavailable; jq-missing telemetry JSONL structure cannot be asserted'
fi

[ "$fail" -eq 0 ] && echo 'SMOKE: ALL PASS' || { echo 'SMOKE: FAILED'; exit 1; }
