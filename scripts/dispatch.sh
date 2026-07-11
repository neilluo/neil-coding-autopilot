#!/usr/bin/env bash
# Autopilot 统一 Agent CLI 调度器
# 封装 qodercli / claude / codex 的平台差异，提供统一调度接口。
#
# 用法:
#   dispatch.sh --model MODEL --cwd DIR --prompt-file FILE --instruction "TEXT"
#
# 环境变量:
#   AUTOPILOT_PLATFORM  - 指定平台 (qoder/claude/codex/auto)，默认 auto
#
set -euo pipefail

# Cleanup trap: forward SIGTERM to child process
CHILD_PID=""
cleanup() {
  if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
    kill -TERM "$CHILD_PID" 2>/dev/null
    wait "$CHILD_PID" 2>/dev/null
  fi
}
trap cleanup SIGTERM SIGINT

PLATFORM="${AUTOPILOT_PLATFORM:-auto}"
TIMEOUT="${AUTOPILOT_TIMEOUT:-600}"
MODEL=""
CWD=""
PROMPT_FILE=""
INSTRUCTION=""

# Auto-detect platform
detect_platform() {
  if command -v qodercli &>/dev/null; then echo "qoder"
  elif command -v claude &>/dev/null; then echo "claude"
  elif command -v codex &>/dev/null; then echo "codex"
  else
    echo "ERROR: No supported agent CLI found (qodercli/claude/codex)" >&2
    exit 1
  fi
}

if [ "$PLATFORM" = "auto" ]; then
  PLATFORM=$(detect_platform)
fi

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --model) MODEL="$2"; shift 2;;
    --cwd) CWD="$2"; shift 2;;
    --prompt-file) PROMPT_FILE="$2"; shift 2;;
    --instruction) INSTRUCTION="$2"; shift 2;;
    --timeout) TIMEOUT="$2"; shift 2;;
    --help)
      echo "Usage: dispatch.sh --model MODEL --cwd DIR --prompt-file FILE --instruction TEXT [--timeout SECS]"
      echo ""
      echo "Options:"
      echo "  --timeout SECS  Worker timeout in seconds (default: 600, env: AUTOPILOT_TIMEOUT)"
      echo ""
      echo "Platforms: qoder, claude, codex (set via AUTOPILOT_PLATFORM env var)"
      exit 0;;
    *) echo "Unknown arg: $1" >&2; shift;;
  esac
done

# Validate required args
if [ -z "$MODEL" ] || [ -z "$CWD" ] || [ -z "$PROMPT_FILE" ] || [ -z "$INSTRUCTION" ]; then
  echo "ERROR: Missing required arguments. Use --help for usage." >&2
  exit 1
fi

if [ ! -f "$PROMPT_FILE" ]; then
  echo "ERROR: Prompt file not found: $PROMPT_FILE" >&2
  exit 1
fi

# Detect a portable timeout binary: GNU `timeout` (Linux) or `gtimeout`
# (macOS via `brew install coreutils`). macOS ships neither by default, so
# degrade gracefully instead of dying with "timeout: command not found" (127).
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"

# Dispatch to platform-specific CLI with timeout (when a timeout binary exists)
run_with_timeout() {
  if [ -n "$TIMEOUT_BIN" ] && [ "$TIMEOUT" != "0" ]; then
    "$TIMEOUT_BIN" "$TIMEOUT" "$@" &
  else
    if [ -z "$TIMEOUT_BIN" ]; then
      echo "WARN: no 'timeout'/'gtimeout' found; running worker without time cap (macOS: brew install coreutils)." >&2
    fi
    "$@" &
  fi
  CHILD_PID=$!
  wait "$CHILD_PID"
  EXIT_CODE=$?
  CHILD_PID=""

  # Normalize timeout exit code (GNU timeout returns 124, but some return 137)
  if [ $EXIT_CODE -eq 137 ] && [ "$TIMEOUT" != "0" ]; then
    EXIT_CODE=124
  fi

  if [ $EXIT_CODE -eq 124 ]; then
    echo "ERROR: Worker timed out after ${TIMEOUT}s" >&2
  fi

  exit $EXIT_CODE
}

case "$PLATFORM" in
  qoder)
    run_with_timeout qodercli -m "$MODEL" \
      -w "$CWD" \
      --permission-mode bypass_permissions \
      --attachment "$PROMPT_FILE" \
      -p "$INSTRUCTION"
    ;;
  claude)
    run_with_timeout claude -m "$MODEL" \
      -p "$INSTRUCTION" \
      --allowedTools "Edit,Write,Bash" \
      --cwd "$CWD" \
      < "$PROMPT_FILE"
    ;;
  codex)
    run_with_timeout codex --model "$MODEL" \
      --approval-mode full-auto \
      --quiet \
      "$INSTRUCTION" \
      < "$PROMPT_FILE"
    ;;
  *)
    echo "ERROR: Unknown platform '$PLATFORM'. Supported: qoder, claude, codex" >&2
    exit 1
    ;;
esac
