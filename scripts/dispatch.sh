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
USE_QODER_JSON=0
if [ "$PLATFORM" = qoder ] && [ "${AUTOPILOT_USAGE_JSON:-1}" != 0 ] && command -v jq >/dev/null 2>&1; then
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

export AUTOPILOT_ROLE=worker
case "$PLATFORM" in
  qoder)
    if [ "$USE_QODER_JSON" -eq 1 ]; then
      run_worker qodercli -m "$MODEL" -w "$CWD" --permission-mode bypass_permissions --attachment "$PROMPT_FILE" -p "$INSTRUCTION" -o json
    else
      run_worker qodercli -m "$MODEL" -w "$CWD" --permission-mode bypass_permissions --attachment "$PROMPT_FILE" -p "$INSTRUCTION"
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
export AUTOPILOT_TM_PROMPT_BYTES AUTOPILOT_TM_OUTPUT_BYTES AUTOPILOT_TM_ATTEMPT
export AUTOPILOT_TM_INPUT_TOKENS AUTOPILOT_TM_OUTPUT_TOKENS AUTOPILOT_TM_CACHE_READ_TOKENS 2>/dev/null || true
export AUTOPILOT_TM_COST_USD AUTOPILOT_TM_CONTEXT_RATIO AUTOPILOT_TM_NUM_TURNS AUTOPILOT_TM_API_MS AUTOPILOT_TM_IS_ERROR AUTOPILOT_TM_FAILURE_CLASS 2>/dev/null || true
telemetry_emit_dispatch "$WORKER_RC" "$START" || true
exit "$WORKER_RC"
