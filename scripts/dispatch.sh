#!/usr/bin/env bash
# Autopilot unified Agent CLI dispatcher.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=telemetry.sh
. "$SCRIPT_DIR/telemetry.sh"

CHILD_PID=""
OUTPUT_FILE=""
RESULT_FILE=""
cleanup() {
  if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
    kill -TERM "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null || true
  fi
  [ -z "$OUTPUT_FILE" ] || rm -f "$OUTPUT_FILE"
  [ -z "$RESULT_FILE" ] || rm -f "$RESULT_FILE"
}
# 信号路径必须**当场结束**，不能回落主流程。旧写法把三个事件挂在同一个 handler 上
# （`trap cleanup EXIT SIGTERM SIGINT`），而 handler 执行完不退出，于是脚本从 `wait` 之后
# 继续往下跑 —— 而 cleanup 已经删掉了 OUTPUT_FILE，接着的 `wc -c < "$OUTPUT_FILE"`
# 直接报 "No such file or directory"、rc=1。已实测后果（向 dispatch 发 TERM）：
#   ① worker 已经产出的 stdout 被彻底丢弃（下方的 cat 根本没跑到）；
#   ② 退出码被写成 1，上层拿到「非 0 + 极短日志」按 TRANSPORT **重试**，
#     而人为中止根本不该重试；
#   ③ 末尾的 telemetry_emit_dispatch 永不触发，这次调用在遥测里凭空消失。
# 现在信号路径先把已有输出吐出去（保住可观测性），再清理并用约定退出码结束。
_on_signal() {
  local code="${1:-143}"
  if [ -n "$OUTPUT_FILE" ] && [ -s "$OUTPUT_FILE" ]; then command cat "$OUTPUT_FILE" || true; fi
  cleanup
  exit "$code"
}
trap cleanup EXIT
trap '_on_signal 130' INT
trap '_on_signal 143' TERM

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

# 带值选项缺值必须显式报错，不能让 `$2` 在 set -u 下裸奔。这里不仅是报错好看不好看的
# 问题，而是一条真实的 fail-closed 破洞（已实测）：本脚本在第 20 行就装上了 EXIT trap，
# 而 bash 在因 set -u 展开错误而中止时，EXIT trap 里最后一条命令（cleanup 里那个总是成功的
# `[ -z ... ] || rm -f ...`）的退出码会**盖掉**真实失败码，于是一次“参数写错”的硬错误
# 以 **rc=0**（成功）交给调用方；run-track-a 拿到 rc=0 + 空日志就归为 EMPTY，接着按
# “模型静默”重试到耗尽，最后给出一句彻底误导的诊断（“nothing was written, rerunning is
# safe”）—— 而真因是调用方少传了一个参数。显式 `exit 1` 不会被 trap 洗白（已验证）。
need_value() { [ "$2" -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; usage >&2; exit 1; }; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --model) need_value "$1" $#; MODEL="$2"; shift 2 ;;
    --cwd) need_value "$1" $#; CWD="$2"; shift 2 ;;
    --prompt-file) need_value "$1" $#; PROMPT_FILE="$2"; shift 2 ;;
    --instruction) need_value "$1" $#; INSTRUCTION="$2"; shift 2 ;;
    --timeout) need_value "$1" $#; CLI_TIMEOUT="$2"; shift 2 ;;
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

# 「禁前言、但必须收尾报数」双约束。历史上这里只有「禁前言」且措辞是「严禁输出任何
# ……总结文字」，与上层 tasks 要求的「回复末尾必须输出 **Status:** DONE」直接矛盾，
# 后果实测如下（qodercli 1.0.16 + 思维链模型，session jsonl 取证）：
#   模型把整个回合都塞进 thinking/redacted_thinking，不产出任何 text 块 → CLI 只打印
#   text，于是 stdout 零字节；classify-outcome 见「rc=0 且无锚定 marker」判 EMPTY，
#   上层当成掉线重试到耗尽后 fail-closed。最坑的是活其实干完了：有 session 记录为
#   thinking→tool_use×11→thinking 收尾，文件已落盘却因「一言不发」被判失败并丢弃。
# 因此措辞必须精确到「阶段」：动手前禁止叙述，完工后必须输出结论标记行。
# 两个易错点（均已在真实端到端跑中暴露）：
#   ① 不能说「结论行是唯一允许的输出」——reviewer 的交付物本身就是审查正文，
#     那样写等于禁止它写 CR，实测下 reviewer 连续两次静默、第三次才交出正文。
#   ② 不能硬命令「立即调用工具」——只读审查可能根本不需要工具，得给它直接下结论的路。
# 标记形式不写死（run-track-a 用 **Status:** / REVIEW_PASS，run-autopilot 用 FINISH_STATUS=），
# 统一指向提示词自带的「报告格式」段，与 parse-markers.sh 能识别的集合保持一致。
# 固化在 dispatch 内部，任何调用方自动获得，不依赖各处 prompt 自觉。
#
# 按阶段分化（遥测驱动）：同一天的真实数据里 implement 静默率 2/24=8.3%，
# review 却是 4/7=57%（浪费 66s 的 Ultimate 调用）——相差 7 倍。原因不是模型好坏：
# implement 天然要发 tool_use，“少说话”于它无害；而 reviewer 的交付物就是那段文字，
# 压制文本通道等于压制它干活，于是整个回合滞留在 thinking 里。所以以文字为交付物的
# 阶段（review / analyze-daily）不再背「禁前言」，只禁「复述任务/预告动作」。
case "$STAGE" in
  review|analyze-daily)
    QODER_INSTRUCTION="【直接给结论：不要复述任务、不要宣布你接下来要做什么，需要看文件就直接看。你的交付物就是回复正文里的结论与依据，该写多少就写多少；并在正文末尾输出提示词「报告格式/结论」要求的标记行（如 REVIEW_PASS、REVIEW_FAIL 或 **Status:** DONE）。只在思考过程里得出结论而正文不写，等于没交付，会被判为失败。】${INSTRUCTION}"
    ;;
  *)
    QODER_INSTRUCTION="【先动手、后说话：动手之前严禁输出解释、计划或前言，直接开始调用工具；本任务若无需工具则直接给结论。工作完成后，必须按提示词「报告格式」在回复末尾输出结论标记行（如 **Status:** DONE、REVIEW_PASS 或 FINISH_STATUS=DONE）；该行必须出现在回复正文里。只在思考过程里收尾、正文不写该行，等于没交付，会被判为失败。】${INSTRUCTION}"
    ;;
esac

export AUTOPILOT_ROLE=worker
case "$PLATFORM" in
  qoder)
    # `--tools default` 显式放开全部内置工具，避免用户级/项目级 settings 把工具集收窄后
    # headless 工具循环静默不执行。它是 variadic 选项（--tools <tools...>），必须紧跟一个
    # 选项来终止取值——这里紧邻 -p，切勿在两者之间插入位置参数。
    #
    # AUTOPILOT_REASONING_EFFORT：非空则透传 --reasoning-effort。用法是“重试时降档”：
    # 静默故障的形态就是模型把整个回合花在 thinking 上、不产出 text，降低推理档位
    # 直接打击该成因。实测（同 prompt / 同模型 / 同调用方式，N=4）：默认档 1/4 静默，
    # low 档 0/4，且 low 档仍给出实质审查（核对 Verify / 安全 / 边界）。因为会变浅，
    # 所以绝不做默认值：第一次尝试保留完整质量，只在已经静默过的重试上降档。
    QODER_ARGS=""
    if [ -n "${AUTOPILOT_REASONING_EFFORT:-}" ]; then
      QODER_ARGS="--reasoning-effort ${AUTOPILOT_REASONING_EFFORT}"
    fi
    if [ "$USE_QODER_JSON" -eq 1 ]; then
      run_worker qodercli -m "$MODEL" -w "$CWD" --permission-mode bypass_permissions --attachment "$PROMPT_FILE" $QODER_ARGS --tools default -p "$QODER_INSTRUCTION" -o json
    else
      run_worker qodercli -m "$MODEL" -w "$CWD" --permission-mode bypass_permissions --attachment "$PROMPT_FILE" $QODER_ARGS --tools default -p "$QODER_INSTRUCTION"
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

# VERDICT_FILE 始终指向「本次真正吐给上层的字节」。JSON 信封模式下结论行在 .result 里而
# 不在信封表面，若直接拿信封去找锚定 marker 会把正常报数的 worker 误判为静默。
VERDICT_FILE="$OUTPUT_FILE"
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
    RESULT_FILE="$(mktemp "${TMPDIR:-/tmp}/neil-dispatch-result.XXXXXX")"
    jq -j '.result' "$OUTPUT_FILE" > "$RESULT_FILE"
    command cat "$RESULT_FILE"
    VERDICT_FILE="$RESULT_FILE"
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
# 静默收尾：CLI 自认成功（rc=0）却没给出任何锚定结论行。实测成因是模型把整个回合
# 收在 thinking/redacted_thinking 里、不产出 text 块，CLI 只打印 text 所以 stdout 为空。
# 它与链路抖动同形但根因完全不同：工具可能已经跑完、文件已落盘。不改 rc（保持 0
# 才会被 classify-outcome 归为 EMPTY；改成非 0 反而会被误归为 TRANSPORT），只把真实成因
# 写进日志，避免下一个人再拿「掉线」去查网络。此处文案切勿出现行首锚定的结论标记，
# 也切勿出现 classify-outcome 的 TRANSPORT 关键词，否则会自己污染分类结果。
if [ "$WORKER_RC" -eq 0 ] \
  && command -v tail >/dev/null 2>&1 && command -v grep >/dev/null 2>&1 \
  && [ "$("$SCRIPT_DIR/parse-markers.sh" status "$VERDICT_FILE" 2>/dev/null || echo UNKNOWN)" = UNKNOWN ] \
  && [ "$("$SCRIPT_DIR/parse-markers.sh" review "$VERDICT_FILE" 2>/dev/null || echo UNKNOWN)" = UNKNOWN ]; then
  AUTOPILOT_TM_FAILURE_CLASS=SILENT_COMPLETION
  echo "WARN: SILENT_COMPLETION - worker exited 0 but produced no anchored verdict line." >&2
  echo "      Typical cause: the model ended its turn inside thinking/redacted_thinking and emitted no text block." >&2
  echo "      This is NOT a dropped connection: tool calls may already have run and files may already be written." >&2
  echo "      Inspect the worktree before any retry; a blind retry re-runs the task on an already-modified tree." >&2
fi
export AUTOPILOT_TM_PROMPT_BYTES AUTOPILOT_TM_OUTPUT_BYTES AUTOPILOT_TM_ATTEMPT
export AUTOPILOT_TM_INPUT_TOKENS AUTOPILOT_TM_OUTPUT_TOKENS AUTOPILOT_TM_CACHE_READ_TOKENS 2>/dev/null || true
export AUTOPILOT_TM_COST_USD AUTOPILOT_TM_CONTEXT_RATIO AUTOPILOT_TM_NUM_TURNS AUTOPILOT_TM_API_MS AUTOPILOT_TM_IS_ERROR AUTOPILOT_TM_FAILURE_CLASS 2>/dev/null || true
telemetry_emit_dispatch "$WORKER_RC" "$START" || true
exit "$WORKER_RC"
