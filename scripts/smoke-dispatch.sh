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
# 遥测隔离：本文件共 19 处 dispatch 调用，之前只有 3 处在命令行上内联了 NEIL_AUTOPILOT_LOG_DIR，
# 其余 16 处直接往**真实日志根** `$HOME/Library/Logs/neil-autopilot/runs/` 写 TestModel 事件。
# 已实测取证：真实 runs/<今天>.jsonl 里出现 40 条 model=TestModel 的 dispatch 事件，
# stage 包括 `unknown` / `review` / `review;false`（后者是本文件 stage 清洗用例的专属输入，
# 全仓只有这一处，因此可直接定位到本文件）。
# 但**不能无条件覆盖**：smoke-all.sh 是遥测沙箱的单一收口点，它靠“沙箱里确实有事件”
# 做泄露 canary（smoke-all.sh:86）；如果这里无条件改指自己的目录，canary 就报
# “no events landed in the smoke sandbox”（已实测到这个回归）。
# 所以：上游已沙箱化（AUTOPILOT_SMOKE_SANDBOX=1）则继承；否则（单跑本文件，
# 此时 NEIL_AUTOPILOT_LOG_DIR 可能是用户 .zshrc 里指向生产日志根的值）强制自己隔离。
# 单个用例如需断言遥测内容，仍可在命令行上内联该变量覆盖。
if [ "${AUTOPILOT_SMOKE_SANDBOX:-0}" != 1 ]; then
  export NEIL_AUTOPILOT_LOG_DIR="$ROOT/telemetry"
fi
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

# qoder JSON path (opt-in via AUTOPILOT_USAGE_JSON=1): result restoration, raw
# retention, usage metadata, is_error exit. NOTE: json is OFF by default because
# `-o json` breaks agentic tool execution (see dispatch.sh comment); these cases
# therefore must enable it explicitly.
if command -v jq >/dev/null 2>&1; then
  # `report\n**Status:** DONE` must decode to a REAL newline so the fixture mirrors a
  # genuine worker report whose verdict sits at the start of its own line. Written
  # with `\\n` it decoded to a literal backslash-n, i.e. a single unanchored line —
  # which the verdict parser rightly refuses, tagging a "passing" fixture as silent.
  make_stub qodercli 'printf '\''%s\n'\'' '\''{"result":"report\n**Status:** DONE","usage":{"input_tokens":101,"output_tokens":202,"cache_read_input_tokens":303,"context_usage_ratio":0.25},"total_cost_usd":0.0123,"num_turns":4,"duration_api_ms":567,"is_error":false}'\'''
  LOG="$ROOT/log"; mkdir -p "$LOG"
  run_capture "$ROOT/out" "$ROOT/err" env PATH="$BIN:$PATH" HOME="$ROOT" NEIL_AUTOPILOT_LOG_DIR="$LOG" NEIL_AUTOPILOT_RUN_ID=smoke AUTOPILOT_RUN_ID=smoke AUTOPILOT_PLATFORM=qoder AUTOPILOT_STAGE=review AUTOPILOT_ATTEMPT=2 AUTOPILOT_USAGE_JSON=1 AUTOPILOT_RAW_JSON="$ROOT/raw.json" bash "$DISPATCH" --model TestModel --cwd "$ROOT" --prompt-file "$ROOT/prompt.md" --instruction x --timeout 5
  assert_contains "$(<"$ROOT/out")" '**Status:** DONE' 'JSON result restored to stdout'
  jq -e '.result | contains("**Status:** DONE")' "$ROOT/raw.json" >/dev/null && pass 'raw JSON retained' || fail 'raw JSON retained'
  jsonl="$(ls "$LOG/runs"/*.jsonl | head -1)"
  jq -e -s '.[-1] | .input_tokens==101 and .output_tokens==202 and .cache_read_tokens==303 and .cost_usd==0.0123 and .context_ratio==0.25 and .num_turns==4 and .api_ms==567 and .attempt==2 and .prompt_bytes==18 and .output_bytes>0 and (.failure_class|not)' "$jsonl" >/dev/null && pass 'usage and always-on metadata emitted' || fail 'usage and always-on metadata emitted'
  make_stub qodercli 'printf '\''%s\n'\'' '\''{"result":"bad","is_error":true}'\'''
  run_capture "$ROOT/out" "$ROOT/err" env PATH="$BIN:$PATH" AUTOPILOT_PLATFORM=qoder AUTOPILOT_USAGE_JSON=1 bash "$DISPATCH" --model TestModel --cwd "$ROOT" --prompt-file "$ROOT/prompt.md" --instruction x --timeout 5
  [ "$RUN_RC" -eq 1 ] && pass 'is_error forces exit 1' || fail "is_error forces exit 1 (rc=$RUN_RC)"
else
  echo 'SKIP: jq unavailable; JSON extraction scenario cannot run'
fi

# --- Regression guards for the `-o json` tool-execution defect -----------------
# Root cause (measured on qodercli 1.0.16, 5 runs each on one file-creating task):
#   with `-o json`  0/5 succeeded (all num_turns=1 / stop_reason=tool_use, zero files
#                   changed) ; without it 3/5 ; without it + no-preamble prompt 5/5.
# So json must stay opt-in, and the worker contract must always reach the worker.
ARGLOG="$ROOT/argv.log"
make_stub qodercli 'printf "%s\n" "$*" >> "'"$ARGLOG"'"; printf "%s\n" "**Status:** DONE"'
: > "$ARGLOG"
run_capture "$ROOT/out" "$ROOT/err" env PATH="$BIN:$PATH" AUTOPILOT_PLATFORM=qoder bash "$DISPATCH" --model TestModel --cwd "$ROOT" --prompt-file "$ROOT/prompt.md" --instruction "reply OK" --timeout 5
if grep -q -- '-o json' "$ARGLOG"; then fail 'json output is OFF by default'; else pass 'json output is OFF by default'; fi
# The contract has two halves and they must not contradict each other: forbid the
# preamble *before* acting, but mandate the verdict line *after* acting. A blanket
# "output no summary text" once made thinking-capable models end their turn inside
# thinking/redacted_thinking with no text block at all -> empty stdout -> the loop
# scored a finished task as a dropped worker and retried it to exhaustion.
assert_contains "$(<"$ARGLOG")" '动手之前严禁输出' 'no-preamble half reaches worker'
assert_contains "$(<"$ARGLOG")" '结论标记行' 'mandatory-verdict half reaches worker'
if printf '%s' "$(<"$ARGLOG")" | grep -q '严禁输出任何[^。]*总结'; then
  fail 'contract no longer forbids the verdict line'
else
  pass 'contract no longer forbids the verdict line'
fi
# A reviewer's deliverable IS prose, so the contract must never claim the verdict
# line is the only permitted output -- that wording made reviewers fall silent.
if printf '%s' "$(<"$ARGLOG")" | grep -q '唯一允许'; then
  fail 'contract does not forbid a review body'
else
  pass 'contract does not forbid a review body'
fi
# Read-only stages may need no tools at all; the contract must leave them a path.
assert_contains "$(<"$ARGLOG")" '无需工具' 'contract allows a tool-free conclusion'
# `--tools default` guards against a narrowed tool set, but it is a variadic option:
# it must be terminated by the very next flag, otherwise it swallows the query.
assert_contains "$(<"$ARGLOG")" '--tools default -p' 'tools default is passed and terminated by -p'

# Stage-aware contract: measured silent rates on one real day were implement 2/24
# (8.3%) vs review 4/7 (57%) -- a 7x gap. Cause: a reviewer's deliverable IS the
# prose, so "no preamble" muzzles the channel it must deliver through and the turn
# stays inside thinking. Prose-deliverable stages therefore must NOT inherit the
# act-first clause, while tool-driven stages must keep it.
: > "$ARGLOG"
run_capture "$ROOT/out" "$ROOT/err" env PATH="$BIN:$PATH" AUTOPILOT_PLATFORM=qoder AUTOPILOT_STAGE=review bash "$DISPATCH" --model TestModel --cwd "$ROOT" --prompt-file "$ROOT/prompt.md" --instruction "review it" --timeout 5
if printf '%s' "$(<"$ARGLOG")" | grep -q '动手之前严禁输出'; then
  fail 'review stage drops the act-first clause'
else
  pass 'review stage drops the act-first clause'
fi
assert_contains "$(<"$ARGLOG")" '你的交付物就是回复正文' 'review stage is told its prose IS the deliverable'
assert_contains "$(<"$ARGLOG")" 'REVIEW_PASS' 'review stage still gets a mandatory verdict marker'

: > "$ARGLOG"
run_capture "$ROOT/out" "$ROOT/err" env PATH="$BIN:$PATH" AUTOPILOT_PLATFORM=qoder AUTOPILOT_STAGE=analyze-daily bash "$DISPATCH" --model TestModel --cwd "$ROOT" --prompt-file "$ROOT/prompt.md" --instruction "write the report" --timeout 5
if printf '%s' "$(<"$ARGLOG")" | grep -q '动手之前严禁输出'; then
  fail 'analyze-daily stage drops the act-first clause'
else
  pass 'analyze-daily stage drops the act-first clause'
fi

: > "$ARGLOG"
run_capture "$ROOT/out" "$ROOT/err" env PATH="$BIN:$PATH" AUTOPILOT_PLATFORM=qoder AUTOPILOT_STAGE=implement bash "$DISPATCH" --model TestModel --cwd "$ROOT" --prompt-file "$ROOT/prompt.md" --instruction "build it" --timeout 5
assert_contains "$(<"$ARGLOG")" '动手之前严禁输出' 'implement stage keeps the act-first clause'
assert_contains "$(<"$ARGLOG")" '结论标记行' 'implement stage keeps the mandatory verdict'

# --reasoning-effort passthrough: the silent failure is a turn that dies inside
# thinking, so lowering the effort attacks the cause directly (measured: default
# 1/4 silent vs low 0/4 on the same prompt/model). It must stay opt-in per call so
# attempt 1 keeps full-depth reasoning, and it must land BEFORE the variadic
# --tools so it cannot be swallowed as a tools value.
: > "$ARGLOG"
run_capture "$ROOT/out" "$ROOT/err" env PATH="$BIN:$PATH" AUTOPILOT_PLATFORM=qoder bash "$DISPATCH" --model TestModel --cwd "$ROOT" --prompt-file "$ROOT/prompt.md" --instruction x --timeout 5
if grep -q -- '--reasoning-effort' "$ARGLOG"; then fail 'reasoning effort is not passed unless requested'; else pass 'reasoning effort is not passed unless requested'; fi
: > "$ARGLOG"
run_capture "$ROOT/out" "$ROOT/err" env PATH="$BIN:$PATH" AUTOPILOT_PLATFORM=qoder AUTOPILOT_REASONING_EFFORT=low bash "$DISPATCH" --model TestModel --cwd "$ROOT" --prompt-file "$ROOT/prompt.md" --instruction x --timeout 5
assert_contains "$(<"$ARGLOG")" '--reasoning-effort low --tools default -p' 'reasoning effort is passed before the variadic --tools'

: > "$ARGLOG"
run_capture "$ROOT/out" "$ROOT/err" env PATH="$BIN:$PATH" AUTOPILOT_PLATFORM=qoder AUTOPILOT_USAGE_JSON=1 bash "$DISPATCH" --model TestModel --cwd "$ROOT" --prompt-file "$ROOT/prompt.md" --instruction "reply OK" --timeout 5
if grep -q -- '-o json' "$ARGLOG"; then pass 'json output honours explicit opt-in'; else fail 'json output honours explicit opt-in'; fi

# stop_reason=tool_use with rc=0 means the worker never executed its tool call:
# must surface as TRUNCATED_TOOL_USE + rc 125, never as a silent success.
if command -v jq >/dev/null 2>&1; then
  make_stub qodercli 'printf '"'"'%s\n'"'"' '"'"'{"result":"","stop_reason":"tool_use","num_turns":1,"is_error":false}'"'"''
  run_capture "$ROOT/out" "$ROOT/err" env PATH="$BIN:$PATH" AUTOPILOT_PLATFORM=qoder AUTOPILOT_USAGE_JSON=1 bash "$DISPATCH" --model TestModel --cwd "$ROOT" --prompt-file "$ROOT/prompt.md" --instruction x --timeout 5
  [ "$RUN_RC" -eq 125 ] && pass 'truncated tool_use exits 125' || fail "truncated tool_use exits 125 (rc=$RUN_RC)"
  assert_contains "$(<"$ROOT/err")" 'TRUNCATED_TOOL_USE' 'truncation is diagnosed on stderr'
fi

# A worker that exits 0 with no anchored verdict must be named for what it is.
# Measured cause: the model ended its turn inside thinking/redacted_thinking and
# emitted no text block, so stdout was empty while its tool calls had already run.
# Calling that "transport" sent a human chasing the network for 35 minutes, so the
# diagnosis must say so explicitly -- and must not itself fake a verdict marker or
# contain a transport keyword, or it would poison classify-outcome.sh.
make_stub qodercli 'exit 0'
run_capture "$ROOT/out" "$ROOT/err" env PATH="$BIN:$PATH" AUTOPILOT_PLATFORM=qoder bash "$DISPATCH" --model TestModel --cwd "$ROOT" --prompt-file "$ROOT/prompt.md" --instruction x --timeout 5
[ "$RUN_RC" -eq 0 ] && pass 'silent completion keeps rc 0 (stays EMPTY, not TRANSPORT)' || fail "silent completion rc=$RUN_RC (expected 0)"
assert_contains "$(<"$ROOT/err")" 'SILENT_COMPLETION' 'silent completion is diagnosed on stderr'
assert_contains "$(<"$ROOT/err")" 'thinking' 'diagnosis names the thinking-only cause'
SILENT_ERR="$ROOT/err"
if [ "$(bash "$SCRIPT_DIR/parse-markers.sh" status "$SILENT_ERR")" = UNKNOWN ]; then
  pass 'diagnosis does not fake a verdict marker'
else
  fail 'diagnosis does not fake a verdict marker'
fi
if [ "$(bash "$SCRIPT_DIR/classify-outcome.sh" 0 "$SILENT_ERR")" = EMPTY ]; then
  pass 'diagnosis text still classifies as EMPTY'
else
  fail "diagnosis text still classifies as EMPTY (got $(bash "$SCRIPT_DIR/classify-outcome.sh" 0 "$SILENT_ERR"))"
fi
# A worker that does report a verdict must never be tagged silent.
make_stub qodercli 'printf "%s\n" "**Status:** DONE"'
run_capture "$ROOT/out" "$ROOT/err" env PATH="$BIN:$PATH" AUTOPILOT_PLATFORM=qoder bash "$DISPATCH" --model TestModel --cwd "$ROOT" --prompt-file "$ROOT/prompt.md" --instruction x --timeout 5
if grep -q 'SILENT_COMPLETION' "$ROOT/err"; then fail 'reporting worker is not tagged silent'; else pass 'reporting worker is not tagged silent'; fi

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
