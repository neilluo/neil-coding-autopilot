#!/usr/bin/env bash
# Autopilot unified Agent CLI dispatcher.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=telemetry.sh
. "$SCRIPT_DIR/telemetry.sh"

CHILD_PID=""
OUTPUT_FILE=""
RESULT_FILE=""
STDERR_FILE=""
cleanup() {
  if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
    kill -TERM "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null || true
  fi
  [ -z "$OUTPUT_FILE" ] || rm -f "$OUTPUT_FILE"
  [ -z "$RESULT_FILE" ] || rm -f "$RESULT_FILE"
  [ -z "$STDERR_FILE" ] || rm -f "$STDERR_FILE"
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
  if [ -n "$STDERR_FILE" ] && [ -s "$STDERR_FILE" ]; then command cat "$STDERR_FILE" >&2 || true; fi
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
# 取证字段（由 session-forensics.sh 回填）。必须先置空：本脚本跑 set -u，
# 而它们只在静默分支里赋值，末尾的 export 却无条件引用。
AUTOPILOT_TM_FORENSIC_VERDICT=""
AUTOPILOT_TM_STOP_REASON=""
AUTOPILOT_TM_TOOL_CALLS=""

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
# 记下超时值的来源。超时窗口直接等于「一个卡死的 worker 最多能烧多少钱」：worker 被杀之前
# 生成的 token 照付，而成果全部丢弃（TIMEOUT 在 run-track-a.sh 里是 fail-closed、不重试）。
# 所以「是谁定的这个上限」必须进日志——否则一个全局环境变量把某阶段的窗口悄悄拉宽 3 倍，
# 事后从日志里完全看不出来。
TIMEOUT_SRC=""
# 阶段内置默认值提到外面单独算（原先埋在最后的 else 里），因为下面要拿它来判断
# 「全局 AUTOPILOT_TIMEOUT 是否把这个阶段的上限抬高了」。数值本身未变。
case "$STAGE" in
  review) STAGE_DEFAULT_TIMEOUT=900 ;;
  implement) STAGE_DEFAULT_TIMEOUT=1800 ;;
  fix) STAGE_DEFAULT_TIMEOUT=900 ;;
  *) STAGE_DEFAULT_TIMEOUT=600 ;;
esac
if [ -n "$CLI_TIMEOUT" ]; then
  TIMEOUT="$CLI_TIMEOUT"
  TIMEOUT_SRC="--timeout"
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
    TIMEOUT_SRC="$STAGE_TIMEOUT_NAME"
  elif [ -n "${AUTOPILOT_TIMEOUT:-}" ]; then
    TIMEOUT="$AUTOPILOT_TIMEOUT"
    TIMEOUT_SRC="AUTOPILOT_TIMEOUT"
  else
    TIMEOUT="$STAGE_DEFAULT_TIMEOUT"
    TIMEOUT_SRC="stage-default"
  fi
fi
# 全局 AUTOPILOT_TIMEOUT 只能**收紧**、不能**放大**（省钱设计，2026-08-17）。
# 超时窗口 = 一个卡死 worker 的烧钱上限：TIMEOUT 在 run-track-a.sh 里是 fail-closed、不重试，
# 成果超时即整个丢弃。一个笼统的全局值若高于某阶段的内置默认（review/fix 900、其他 600），
# 会把这些便宜阶段的烧钱窗口悄悄拉宽 2~3 倍 —— 已实测：shell profile 里一行
# `export AUTOPILOT_TIMEOUT=1800` 就把所有阶段抬到 1800s，日志里还没有一个字提示。
# 因此：当且仅当超时值**来自全局**且**高于**本阶段内置默认时，夹回内置默认。
# 只夹「来自全局」这一种来源 —— CLI / 分阶段 / 收紧型全局（值更小）/ 阶段默认都原样不动；
# 0（禁用 timeout 包装）永远不会 > 正数默认，故不受影响。要真的放大某阶段的烧钱上限，
# 必须显式、定向地用 AUTOPILOT_TIMEOUT_<STAGE> 或 --timeout（两者优先级更高，不被夹）。
if [ "$TIMEOUT_SRC" = "AUTOPILOT_TIMEOUT" ]; then
  case "$TIMEOUT" in
    ''|*[!0-9]*) : ;;   # 非数字交给下面的 timeout 包装去报错，这里只管数值比较
    *)
      if [ "$TIMEOUT" -gt "$STAGE_DEFAULT_TIMEOUT" ]; then
        printf 'WARN: global AUTOPILOT_TIMEOUT=%ss exceeds stage %s built-in %ss; clamped to %ss.\n' \
          "$TIMEOUT" "$STAGE" "$STAGE_DEFAULT_TIMEOUT" "$STAGE_DEFAULT_TIMEOUT" >&2
        printf '      A global knob can only tighten, never inflate a burn ceiling. Use AUTOPILOT_TIMEOUT_%s to raise this stage.\n' \
          "$STAGE_KEY" >&2
        TIMEOUT="$STAGE_DEFAULT_TIMEOUT"
        TIMEOUT_SRC="AUTOPILOT_TIMEOUT-clamped"
      fi
      ;;
  esac
fi
# Session id 必须由**我们**指定，不能等 CLI 自己生成。
# 理由（2026-08-17 定案）：worker 静默时 stdout 只有 1 字节、stderr 0 字节，CLI 什么都不说；
# 而它把完整回合（thinking / tool_use / stop_reason）落盘在
# `~/.qoder/projects/<物理 cwd 的 / 换成 ->/<session-id>.jsonl`。
# 以前不 pin session-id，事后只能靠时间戳猜是哪个文件 —— 2026-08-16 那次能定案纯属运气。
# pin 之后，session-forensics.sh 可以确定性地取证「到底干了什么、动没动盘」。
# uuidgen 缺失时留空并降级（fail-safe：取证是加分项，绝不能因此让 dispatch 失败）。
SESSION_ID=""
if [ "$PLATFORM" = qoder ] && command -v uuidgen >/dev/null 2>&1; then
  SESSION_ID="$(uuidgen 2>/dev/null | tr 'A-Z' 'a-z' || true)"
fi

# TIMEOUT_BIN 必须在版本探测**之前**解析 —— 下面要用它给探测封上超时。
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"

# 头部必须写清「谁在跑」。2026-08-16 的事故里，业务仓库有一份 8-15 拷出来的 fork
# （neil-fbi-init/.autopilot-local/scripts/），缺 worktree 指纹守卫与 EMPTY 分支，
# 把「干完活没报数」全标成 transport 并丢弃重试；而日志里没有任何一行说明
# **正在执行哪个文件**，于是排查方向被带偏了一整晚。脚本路径从此进日志。
#
# 为何这里**不**探测 CLI 版本（已实测的踩坑，勿加回来）：
#   版本对诊断很有用（下方那段教训就是「同一版本号下行为反转」），但把
#   `qodercli --version` 放在每次 dispatch 的关键路径上，等于引入一个无界的外部调用。
#   实测：对一个忽略参数、`trap "" TERM; sleep 30` 的 CLI，dispatch 从 3s 拖到 33s；
#   而且 `timeout 5 ... | head -1` 也救不了 —— TERM 被忽略，而命令替换要等管道
#   所有写端关闭，被 KILL 的只是直接子进程、孙进程仍握着管道。
#   所以版本只在**静默诊断分支**里取（那里已经是故障路径，且写临时文件、不经管道）。
# timeout-src 追加在行尾，不插到中间：smoke-dispatch.sh 对 `stage=… model=…` 这段
# 做子串断言，插进去会拆掉它。新字段一律往后加。
printf 'dispatch: stage=%s timeout=%ss kill-after=%ss model=%s timeout-src=%s\n' \
  "$STAGE" "$TIMEOUT" "$KILL_AFTER" "$MODEL" "$TIMEOUT_SRC" >&2
printf 'dispatch: script=%s platform=%s session=%s attempt=%s\n' \
  "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" "$PLATFORM" \
  "${SESSION_ID:-<cli-assigned>}" "${AUTOPILOT_ATTEMPT:-1}" >&2

OUTPUT_FILE="$(mktemp "${TMPDIR:-/tmp}/neil-dispatch.XXXXXX")"
# worker 的 stderr 单独留存，不再直接继承本脚本的 stderr。
# 否则调用方拿到的是两股流合并后的一坨，无法区分「CLI 一个字没说」与「我们把 stderr 丢了」——
# 2026-08-16 的 74 字节日志正是卡在这个区分上（事后才确认 CLI 真的 0 字节 stderr）。
# 采集完仍原样吐回 stderr，调用方行为不变。
STDERR_FILE="$(mktemp "${TMPDIR:-/tmp}/neil-dispatch-err.XXXXXX")"
START="$(date +%s)"
# JSON 输出默认关闭。注意：下面这段历史结论已在 2026-08-17 被推翻，**保留它只为记录教训**：
#   旧结论（声称 qodercli 1.0.16）：带 `-o json` 时 headless 工具循环会停在首个 tool_use、
#   工具根本不执行；实测 0/5 成功，不带则 3/5、加上 prompt 禁前言 5/5。
#   2026-08-17 在**同一个版本号 1.0.16** 上重测（每变体 11 次、隔离 git repo、分流取证）：
#       -o json      11/11 成功，且信封带 stop_reason / session_id / context_usage_ratio
#       -o text      10/11
#       不带 -o       9/11
#   —— 结论完全反转，而版本号一模一样。教训：**用版本号钉住的实测结论不可靠**，
#   服务端模型/CLI 行为可以在版本号不变的前提下改变；结论必须带**日期**并周期重测。
#
# 为何仍然默认关闭（新的、基于证据的理由）：
#   开它的原本动机是采集精确 usage/cost，但实测信封里
#   total_cost_usd / input_tokens / output_tokens **全是 0**（本账号不填充），
#   唯一真正有用的是 stop_reason —— 而它现在可以从 CLI 自己落盘的 session transcript
#   里读到（见 session-forensics.sh），不需要改动任何 CLI 调用方式、零行为风险。
#   所以：保持关闭（不引入不必要的行为变更），取证走 transcript。
#   若将来信封里的 usage 真的非零了，再重新评估是否默认开启。
# 代价：关闭后没有精确 usage，遥测退化为字节数计量（见下方 AUTOPILOT_TM_*_BYTES）。
USE_QODER_JSON=0
if [ "$PLATFORM" = qoder ] && [ "${AUTOPILOT_USAGE_JSON:-0}" = 1 ] && command -v jq >/dev/null 2>&1; then
  USE_QODER_JSON=1
fi

run_worker() {
  if [ -n "$TIMEOUT_BIN" ] && [ "$TIMEOUT" != 0 ]; then
    "$TIMEOUT_BIN" -k "$KILL_AFTER" "$TIMEOUT" "$@" >"$OUTPUT_FILE" 2>"$STDERR_FILE" &
  else
    if [ -z "$TIMEOUT_BIN" ]; then
      echo "WARN: no 'timeout'/'gtimeout' found; running worker without time cap (macOS: brew install coreutils)." >&2
    fi
    "$@" >"$OUTPUT_FILE" 2>"$STDERR_FILE" &
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
    # --session-id 把会话钉在我们自己生成的 uuid 上（实测有效：transcript 就落在
    # $HOME/.qoder/projects/<slug>/<uuid>.jsonl），使失败后的取证变成确定性查找而非猜测。
    # 必须拼在 --reasoning-effort **之前**：下方的 `--tools default -p` 是一个有意的相邻约束
    # （--tools 是 variadic，靠紧跟的选项终止取值），而 smoke-dispatch.sh 针对
    # `--reasoning-effort low --tools default -p` 这段字面相邻关系做了断言；
    # 把 session-id 插到中间会拆掉它（已实测报错）。新参数一律往前面加。
    if [ -n "$SESSION_ID" ]; then
      QODER_ARGS="--session-id $SESSION_ID"
    fi
    if [ -n "${AUTOPILOT_REASONING_EFFORT:-}" ]; then
      QODER_ARGS="$QODER_ARGS --reasoning-effort ${AUTOPILOT_REASONING_EFFORT}"
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

# worker 的 stderr 原样吐回（保持调用方行为），但字节数已单独记下。
if [ -s "$STDERR_FILE" ]; then command cat "$STDERR_FILE" >&2 || true; fi

# Clear usage values inherited from a controller; this event describes only
# this invocation. Always-on metadata is computed from the actual byte streams.
unset AUTOPILOT_TM_INPUT_TOKENS AUTOPILOT_TM_OUTPUT_TOKENS AUTOPILOT_TM_CACHE_READ_TOKENS
unset AUTOPILOT_TM_COST_USD AUTOPILOT_TM_CONTEXT_RATIO AUTOPILOT_TM_NUM_TURNS AUTOPILOT_TM_API_MS AUTOPILOT_TM_IS_ERROR
unset AUTOPILOT_TM_FAILURE_CLASS
AUTOPILOT_TM_PROMPT_BYTES="$(wc -c < "$PROMPT_FILE")"
AUTOPILOT_TM_PROMPT_BYTES="${AUTOPILOT_TM_PROMPT_BYTES//[[:space:]]/}"
AUTOPILOT_TM_OUTPUT_BYTES="$(wc -c < "$OUTPUT_FILE")"
AUTOPILOT_TM_OUTPUT_BYTES="${AUTOPILOT_TM_OUTPUT_BYTES//[[:space:]]/}"
AUTOPILOT_TM_STDERR_BYTES="$(wc -c < "$STDERR_FILE" 2>/dev/null || echo 0)"
AUTOPILOT_TM_STDERR_BYTES="${AUTOPILOT_TM_STDERR_BYTES//[[:space:]]/}"
AUTOPILOT_TM_SESSION_ID="$SESSION_ID"
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
# 它与链路抖动同形但根因完全不同：工具可能已经跑完、文件已落盘。默认不改 rc（保持 0
# 才会被 classify-outcome 归为 EMPTY；改成非 0 反而会被误归为 TRANSPORT），只把真实成因
# 写进日志，避免下一个人再拿「掉线」去查网络。此处文案切勿出现行首锚定的结论标记，
# 也切勿出现 classify-outcome 的 TRANSPORT 关键词，否则会自己污染分类结果。
# （唯一例外见下方 TRUNCATED_TOOL_USE 分支：它改 rc 为 125，而 125 已被专门归为 TRUNCATED。）
if [ "$WORKER_RC" -eq 0 ] \
  && command -v tail >/dev/null 2>&1 && command -v grep >/dev/null 2>&1 \
  && [ "$("$SCRIPT_DIR/parse-markers.sh" status "$VERDICT_FILE" 2>/dev/null || echo UNKNOWN)" = UNKNOWN ] \
  && [ "$("$SCRIPT_DIR/parse-markers.sh" review "$VERDICT_FILE" 2>/dev/null || echo UNKNOWN)" = UNKNOWN ]; then
  AUTOPILOT_TM_FAILURE_CLASS=SILENT_COMPLETION
  echo "WARN: SILENT_COMPLETION - worker exited 0 but produced no anchored verdict line." >&2
  echo "      stdout=${AUTOPILOT_TM_OUTPUT_BYTES}B stderr=${AUTOPILOT_TM_STDERR_BYTES}B session=${SESSION_ID:-<unknown>}" >&2
  # 注意：这里也**不**再跑一次 CLI 取版本（已实测的两个坑，勿加回来）：
  #   ① 它把一个无界外部调用放进流程（对忽略 TERM 的 CLI 会直接拖长整个 dispatch）；
  #   ② 多出一次 CLI 调用会污染一切「数 CLI 调用次数/参数」的记账与测试
  #     —— smoke-run-track-a 的降档阶段断言当场被多出的一行顶歪。
  # 版本直接从 transcript 的 `version` 字段读（零额外进程，而且绑定到出事的那个
  # 会话本身，比“现在跑一下 --version”更准），由 session-forensics.sh 输出。
  # 到这一步为止，「为什么没报数」以前只能靠猜，所以旧文案只能写成「可能已经写了文件」。
  # 现在直接读 CLI 自己的 transcript 定性（已对 3 个真实案例验证），把结论当场打出来
  # 并写进遥测；它区分的三种情况对「能不能重试」的结论正好相反，不能再含糊过去。
  #
  # 取证可能拿不到东西（无 uuidgen / 无 jq / transcript 尚未落盘 / 非 qoder 平台）。
  # 那种情况必须回退到静态文案，**不能什么都不说** —— 否则这次失败就只剩一行
  # “no anchored verdict line”，比改之前更难查（已被 smoke-dispatch.sh 当场抓到）。
  FORENSIC_TEXT=""
  if [ -n "$SESSION_ID" ] && [ -x "$SCRIPT_DIR/session-forensics.sh" ]; then
    FORENSIC_JSON="$("$SCRIPT_DIR/session-forensics.sh" --cwd "$CWD" --session-id "$SESSION_ID" --format json 2>/dev/null || true)"
    if [ -n "$FORENSIC_JSON" ] && command -v jq >/dev/null 2>&1; then
      AUTOPILOT_TM_FORENSIC_VERDICT="$(printf '%s' "$FORENSIC_JSON" | jq -r '.verdict // ""' 2>/dev/null || true)"
      AUTOPILOT_TM_STOP_REASON="$(printf '%s' "$FORENSIC_JSON" | jq -r '.stop_reason // ""' 2>/dev/null || true)"
      AUTOPILOT_TM_TOOL_CALLS="$(printf '%s' "$FORENSIC_JSON" | jq -r '.tool_calls // ""' 2>/dev/null || true)"
    fi
    FORENSIC_TEXT="$("$SCRIPT_DIR/session-forensics.sh" --cwd "$CWD" --session-id "$SESSION_ID" 2>/dev/null || true)"
  fi
  if [ -n "$FORENSIC_TEXT" ]; then
    printf '%s\n' "$FORENSIC_TEXT" | sed 's/^/      /' >&2
  else
    echo "      Typical cause: the model ended its turn inside thinking/redacted_thinking and emitted no text block." >&2
    echo "      This is NOT a dropped connection: tool calls may already have run and files may already be written." >&2
    echo "      Inspect the worktree before any retry; a blind retry re-runs the task on an already-modified tree." >&2
  fi
  # 取证一旦明确定为「工具调用被截断」，就不能再让它走 EMPTY 的静默重试路径。
  # 关键在于两类静默的**统计性质完全不同**，所以不能共用一套重试策略：
  #   THINKING_ONLY——随机的。实测同一 review prompt：Ultimate 8/15 静默，即重试约
  #     有一半概率开口；降 effort / 换模型还能进一步推高。重试阶梯是划得来的。
  #   TRUNCATED_TOOL_USE——确定性的。两份独立证据：上方注释记的「原样重试 3 次全部
  #     复现」；以及真实遇到的每日分析 agent（2026-08-17，3 次尝试分别只产出
  #     87B/115B/118B，报告一次没落盘）。重试只是把同一次注定失败的调用按全价
  #     买到 AUTOPILOT_SILENT_RETRIES（默认 5）遍。系统已经知道答案，不能丢掉。
  #
  # 为何这是上面那句「不改 rc」的**定向例外**而不是违背它：那句担心的是被误归为
  # TRANSPORT（会退避重试），而现在 125 + 下面这行锚定文案已被 classify-outcome 专门
  # 识别为 TRUNCATED、直接 fail-closed。也正因如此，判据必须是 rc（由本脚本设置），
  # 不能只凭日志里出现这个字符串 —— 本仓源码自己就含该词，worker 在本仓干活时
  # 完全可能把它打进日志，按文本匹配就会把一次正常的开发误判成截断。
  #
  # 安全前提：session-forensics.sh 的判据顺序把「动过盘」排在 TRUNCATED_TOOL_USE 之前，
  # 所以走到这里时工作树一定未被修改，直接停机不会丢弃任何已完成的成果。
  #
  # 遗留不确定性（所以留了开关）：上述「确定性」测的是**原样**重试；而静默阶梯在
  # 第 2 次降 effort、第 3 次换模型，那两根杠杆对「截断」究竟有没用没有受控实测。
  # 若以后发现停得太死，设 AUTOPILOT_TRUNCATED_FAIL_CLOSED=0 即可退回旧的 EMPTY 重试行为。
  if [ "${AUTOPILOT_TM_FORENSIC_VERDICT:-}" = TRUNCATED_TOOL_USE ] \
    && [ "${AUTOPILOT_TRUNCATED_FAIL_CLOSED:-1}" = 1 ]; then
    AUTOPILOT_TM_FAILURE_CLASS=TRUNCATED_TOOL_USE
    WORKER_RC=125
    echo "ERROR: TRUNCATED_TOOL_USE - the model emitted a tool call the CLI never executed (worktree untouched)." >&2
    echo "       Not retryable: an identical retry reproduces it. Remove the cause, then rerun." >&2
    echo "       Set AUTOPILOT_TRUNCATED_FAIL_CLOSED=0 to fall back to the old silent-retry ladder." >&2
  fi
fi
export AUTOPILOT_TM_PROMPT_BYTES AUTOPILOT_TM_OUTPUT_BYTES AUTOPILOT_TM_ATTEMPT
export AUTOPILOT_TM_STDERR_BYTES AUTOPILOT_TM_SESSION_ID
export AUTOPILOT_TM_FORENSIC_VERDICT AUTOPILOT_TM_STOP_REASON AUTOPILOT_TM_TOOL_CALLS 2>/dev/null || true
export AUTOPILOT_TM_INPUT_TOKENS AUTOPILOT_TM_OUTPUT_TOKENS AUTOPILOT_TM_CACHE_READ_TOKENS 2>/dev/null || true
export AUTOPILOT_TM_COST_USD AUTOPILOT_TM_CONTEXT_RATIO AUTOPILOT_TM_NUM_TURNS AUTOPILOT_TM_API_MS AUTOPILOT_TM_IS_ERROR AUTOPILOT_TM_FAILURE_CLASS 2>/dev/null || true
telemetry_emit_dispatch "$WORKER_RC" "$START" || true
exit "$WORKER_RC"
