#!/usr/bin/env bash
# Autopilot unified Agent CLI dispatcher.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=telemetry.sh
. "$SCRIPT_DIR/telemetry.sh"

CHILD_PID=""
OUTPUT_FILE=""
cleanup() {
  if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
    kill -TERM "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null || true
  fi
  [ -z "$OUTPUT_FILE" ] || rm -f "$OUTPUT_FILE"
}
trap cleanup EXIT SIGTERM SIGINT

PLATFORM="${AUTOPILOT_PLATFORM:-auto}"
MODEL=""
CWD=""
PROMPT_FILE=""
INSTRUCTION=""
CLI_TIMEOUT=""
STAGE="${AUTOPILOT_STAGE:-other}"
KILL_AFTER="${AUTOPILOT_KILL_AFTER_S:-30}"
INHERITED_ROLE="${AUTOPILOT_ROLE:-}"
STOP_REASON=""

usage() {
  echo "Usage: dispatch.sh --model MODEL --cwd DIR --prompt-file FILE --instruction TEXT [--timeout SECS]"
  echo
  echo "Options:"
  echo "  --timeout SECS  Worker timeout; overrides stage and global environment values"
  echo
  echo "Platforms: qoder, claude, codex (set via AUTOPILOT_PLATFORM env var)"
}

detect_platform() {
  if command -v qodercli >/dev/null 2>&1; then echo qoder
  elif command -v claude >/dev/null 2>&1; then echo claude
  elif command -v codex >/dev/null 2>&1; then echo codex
  else echo "ERROR: No supported agent CLI found (qodercli/claude/codex)" >&2; exit 1
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --model) MODEL="$2"; shift 2 ;;
    --cwd) CWD="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --instruction) INSTRUCTION="$2"; shift 2 ;;
    --timeout) CLI_TIMEOUT="$2"; shift 2 ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; shift ;;
  esac
done

if [ -z "$MODEL" ] || [ -z "$CWD" ] || [ -z "$PROMPT_FILE" ] || [ -z "$INSTRUCTION" ]; then
  echo "ERROR: Missing required arguments. Use --help for usage." >&2
  exit 1
fi
if [ ! -f "$PROMPT_FILE" ]; then
  echo "ERROR: Prompt file not found: $PROMPT_FILE" >&2
  exit 1
fi
if [ "$INHERITED_ROLE" = worker ] && [ "$MODEL" != TestModel ]; then
  echo "ERROR: nested worker spawn refused" >&2
  exit 2
fi
if [ "$PLATFORM" = auto ]; then PLATFORM="$(detect_platform)"; fi

# Resolve the timeout only after parsing --timeout. Restrict the dynamically
# constructed variable name so hostile or malformed stage text is never
# interpreted as shell syntax.
TIMEOUT=""
if [ -n "$CLI_TIMEOUT" ]; then
  TIMEOUT="$CLI_TIMEOUT"
else
  STAGE_KEY="$(printf '%s' "$STAGE" | tr '[:lower:]' '[:upper:]')"
  case "$STAGE_KEY" in
    *[!A-Z0-9_]*) STAGE_TIMEOUT="" ;;
    *)
      STAGE_TIMEOUT_NAME="AUTOPILOT_TIMEOUT_${STAGE_KEY}"
      STAGE_TIMEOUT="${!STAGE_TIMEOUT_NAME:-}"
      ;;
  esac
  if [ -n "$STAGE_TIMEOUT" ]; then
    TIMEOUT="$STAGE_TIMEOUT"
  elif [ -n "${AUTOPILOT_TIMEOUT:-}" ]; then
    TIMEOUT="$AUTOPILOT_TIMEOUT"
  else
    case "$STAGE" in
      review) TIMEOUT=900 ;;
      implement) TIMEOUT=1800 ;;
      fix) TIMEOUT=900 ;;
      *) TIMEOUT=600 ;;
    esac
  fi
fi
printf 'dispatch: stage=%s timeout=%ss kill-after=%ss model=%s\n' "$STAGE" "$TIMEOUT" "$KILL_AFTER" "$MODEL" >&2

TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
OUTPUT_FILE="$(mktemp "${TMPDIR:-/tmp}/neil-dispatch.XXXXXX")"
START="$(date +%s)"
# JSON 输出默认关闭 —— 这不是风格偏好，而是实测的功能性约束：带 `-o json` 时
# headless agentic 工具循环会在首个 tool_use 处终止，工具根本不被执行。
# 实测（同一「创建文件」任务各 5 次，macOS + qodercli 1.0.16）：
#   带 -o json                     0/5 成功，全部 num_turns=1 / stop_reason=tool_use、文件零改动
#   不带 -o json                   3/5 成功
#   不带 -o json + prompt 禁前言   5/5 成功
# 此前默认开启（为采集精确 usage/cost）导致所有 Track A worker 100% 空转。
# 代价：关闭后没有精确 usage，遥测退化为字节数计量（见下方 AUTOPILOT_TM_*_BYTES）。
# 仅纯只读的统计场景才值得显式 AUTOPILOT_USAGE_JSON=1 换取精确 usage —— 那种场景不需要写文件。
USE_QODER_JSON=0
if [ "$PLATFORM" = qoder ] && [ "${AUTOPILOT_USAGE_JSON:-0}" = 1 ] && command -v jq >/dev/null 2>&1; then
  USE_QODER_JSON=1
fi

run_worker() {
  if [ -n "$TIMEOUT_BIN" ] && [ "$TIMEOUT" != 0 ]; then
    "$TIMEOUT_BIN" -k "$KILL_AFTER" "$TIMEOUT" "$@" >"$OUTPUT_FILE" &
  else
    if [ -z "$TIMEOUT_BIN" ]; then
      echo "WARN: no 'timeout'/'gtimeout' found; running worker without time cap (macOS: brew install coreutils)." >&2
    fi
    "$@" >"$OUTPUT_FILE" &
  fi
  CHILD_PID=$!
  WORKER_RC=0
  wait "$CHILD_PID" || WORKER_RC=$?
  CHILD_PID=""
  if [ -n "$TIMEOUT_BIN" ] && [ "$TIMEOUT" != 0 ] && [ "$WORKER_RC" -eq 137 ]; then WORKER_RC=124; fi
}

# 「禁前言」铁律：模型若先输出叙述/计划文本再发起工具调用，headless CLI 会停在
# stop_reason=tool_use 且不执行工具。实测加上该前缀后成功率从 3/5 升到 5/5，
# 因此把它固化在 dispatch 内部，任何调用方都自动获得，不依赖各处 prompt 自觉。
QODER_INSTRUCTION="【严禁输出任何解释、计划、前言或总结文字。立即直接调用工具动手执行，不要先说你要做什么。】${INSTRUCTION}"

export AUTOPILOT_ROLE=worker
case "$PLATFORM" in
  qoder)
    if [ "$USE_QODER_JSON" -eq 1 ]; then
      run_worker qodercli -m "$MODEL" -w "$CWD" --permission-mode bypass_permissions --attachment "$PROMPT_FILE" -p "$QODER_INSTRUCTION" -o json
    else
      run_worker qodercli -m "$MODEL" -w "$CWD" --permission-mode bypass_permissions --attachment "$PROMPT_FILE" -p "$QODER_INSTRUCTION"
    fi
    ;;
  claude)
    run_worker claude -m "$MODEL" -p "$INSTRUCTION" --allowedTools "Edit,Write,Bash" --cwd "$CWD" < "$PROMPT_FILE"
    ;;
  codex)
    run_worker codex --model "$MODEL" --approval-mode full-auto --quiet "$INSTRUCTION" < "$PROMPT_FILE"
    ;;
  *) echo "ERROR: Unknown platform '$PLATFORM'. Supported: qoder, claude, codex" >&2; exit 1 ;;
esac

# Clear usage values inherited from a controller; this event describes only
# this invocation. Always-on metadata is computed from the actual byte streams.
unset AUTOPILOT_TM_INPUT_TOKENS AUTOPILOT_TM_OUTPUT_TOKENS AUTOPILOT_TM_CACHE_READ_TOKENS
unset AUTOPILOT_TM_COST_USD AUTOPILOT_TM_CONTEXT_RATIO AUTOPILOT_TM_NUM_TURNS AUTOPILOT_TM_API_MS AUTOPILOT_TM_IS_ERROR
unset AUTOPILOT_TM_FAILURE_CLASS
AUTOPILOT_TM_PROMPT_BYTES="$(wc -c < "$PROMPT_FILE")"
AUTOPILOT_TM_PROMPT_BYTES="${AUTOPILOT_TM_PROMPT_BYTES//[[:space:]]/}"
AUTOPILOT_TM_OUTPUT_BYTES="$(wc -c < "$OUTPUT_FILE")"
AUTOPILOT_TM_OUTPUT_BYTES="${AUTOPILOT_TM_OUTPUT_BYTES//[[:space:]]/}"
AUTOPILOT_TM_ATTEMPT="${AUTOPILOT_ATTEMPT:-1}"

json_value() {
  local variable="$1" filter="$2" value=""
  value="$(jq -r "$filter | if . == null then empty else . end" "$OUTPUT_FILE" 2>/dev/null || true)"
  [ -z "$value" ] || printf -v "$variable" '%s' "$value"
}

if [ "$USE_QODER_JSON" -eq 1 ] && jq -e 'type == "object"' "$OUTPUT_FILE" >/dev/null 2>&1; then
  if [ -n "${AUTOPILOT_RAW_JSON:-}" ]; then cp "$OUTPUT_FILE" "$AUTOPILOT_RAW_JSON"; fi
  json_value AUTOPILOT_TM_INPUT_TOKENS '.usage.input_tokens'
  json_value AUTOPILOT_TM_OUTPUT_TOKENS '.usage.output_tokens'
  json_value AUTOPILOT_TM_CACHE_READ_TOKENS '.usage.cache_read_input_tokens'
  json_value AUTOPILOT_TM_COST_USD '.total_cost_usd'
  json_value AUTOPILOT_TM_CONTEXT_RATIO '.usage.context_usage_ratio'
  json_value AUTOPILOT_TM_NUM_TURNS '.num_turns'
  json_value AUTOPILOT_TM_API_MS '.duration_api_ms'
  json_value STOP_REASON '.stop_reason'
  if jq -e '.is_error == true' "$OUTPUT_FILE" >/dev/null 2>&1; then
    AUTOPILOT_TM_IS_ERROR=true
    [ "$WORKER_RC" -eq 124 ] || WORKER_RC=1
  elif jq -e '.is_error == false' "$OUTPUT_FILE" >/dev/null 2>&1; then
    AUTOPILOT_TM_IS_ERROR=false
  fi
  if jq -e '.result | type == "string" and length > 0' "$OUTPUT_FILE" >/dev/null 2>&1; then
    jq -j '.result' "$OUTPUT_FILE"
  else
    command cat "$OUTPUT_FILE"
  fi
else
  command cat "$OUTPUT_FILE"
fi

if [ "$WORKER_RC" -eq 124 ]; then
  AUTOPILOT_TM_FAILURE_CLASS=TIMEOUT
  echo "ERROR: Worker timed out after ${TIMEOUT}s" >&2
fi
# 工具调用截断：CLI 自认成功（rc=0）却停在 stop_reason=tool_use —— 模型发出了工具调用
# 但 CLI 没执行就退出，文件零改动。这既不是超时也不是 transport 抖动，因此绝不能被上层
# 当成瞬时故障重试：实测原样重试 3 次全部复现，`-r` 续跑同样救不回（会话已被悬空的
# tool_use 污染）。唯一出路是消除诱因（关掉 AUTOPILOT_USAGE_JSON、prompt 禁前言、缩小
# Task 粒度）后重开 fresh session。用 125 与超时的 124 区分，便于上层分流处置。
if [ "$STOP_REASON" = tool_use ] && [ "$WORKER_RC" -eq 0 ]; then
  AUTOPILOT_TM_FAILURE_CLASS=TRUNCATED_TOOL_USE
  WORKER_RC=125
  echo "ERROR: TRUNCATED_TOOL_USE - worker stopped at a tool call without executing it (no files changed)." >&2
  echo "       Neither plain-retry nor '-r' resume helps. Unset AUTOPILOT_USAGE_JSON, forbid preamble text in the prompt, shrink the task." >&2
fi
export AUTOPILOT_TM_PROMPT_BYTES AUTOPILOT_TM_OUTPUT_BYTES AUTOPILOT_TM_ATTEMPT
export AUTOPILOT_TM_INPUT_TOKENS AUTOPILOT_TM_OUTPUT_TOKENS AUTOPILOT_TM_CACHE_READ_TOKENS 2>/dev/null || true
export AUTOPILOT_TM_COST_USD AUTOPILOT_TM_CONTEXT_RATIO AUTOPILOT_TM_NUM_TURNS AUTOPILOT_TM_API_MS AUTOPILOT_TM_IS_ERROR AUTOPILOT_TM_FAILURE_CLASS 2>/dev/null || true
telemetry_emit_dispatch "$WORKER_RC" "$START" || true
exit "$WORKER_RC"
