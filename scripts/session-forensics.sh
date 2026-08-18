#!/usr/bin/env bash
# WHAT: 从 Agent CLI 自己落盘的 session transcript 里还原「这个 worker 到底干了什么」。
# USAGE: session-forensics.sh --cwd DIR --session-id ID [--format text|json]
# EXIT: 恒 0（fail-safe，取不到证据就什么都不输出；绝不能让调用方因取证失败而挂）。
#
# 为什么需要它（2026-08-17 实测取证，勿删）：
#   headless worker 的失败形态是 `rc=0 + stdout 1 字节(\n) + stderr 0 字节`——CLI
#   一个字都不说。仅凭「退出码 + 日志字节数」无法区分三种**后果完全相反**的情况：
#     ① THINKING_ONLY          回合全部收在 thinking/redacted_thinking，工具一次没调
#                              → 什么都没做，重试是安全的。
#     ② TRUNCATED_TOOL_USE     模型发出了 tool_use 但 CLI 没执行就退出
#                              → 原样重试实测 3/3 复现，`-r` 续跑也救不回。
#     ③ WORK_DONE_UNREPORTED   工具跑完、文件已落盘，只是最后一个回合没产出 text
#                              → **绝不能重试**，否则新 worker 叠在半成品上重做。
#   而 CLI 把完整回合（thinking / tool_use / stop_reason）写在
#   `~/.qoder/projects/<物理 cwd 把 / 换成 ->/<session-id>.jsonl`，证据一直在，
#   只是以前没人 pin session-id、也没人去读。
#
#   真实代价（2026-08-16 23:18，session 91d1e95d）：worker 跑了 96s、11 次 tool_use、
#   Write 了 5 个文件，因为「一言不发」被判 transport 故障 → 重试 → Task 判 BLOCKED，
#   已完成的活整个丢弃。属 ③，而当时的编排器把它当成 ①。
set -euo pipefail

CWD=""
SESSION_ID=""
FORMAT=text

usage() { echo "Usage: session-forensics.sh --cwd DIR --session-id ID [--format text|json]"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cwd) CWD="${2:-}"; shift 2 ;;
    --session-id) SESSION_ID="${2:-}"; shift 2 ;;
    --format) FORMAT="${2:-text}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) shift ;;
  esac
done

[ -n "$SESSION_ID" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# transcript 路径规则（实测 qodercli 1.0.16）：项目目录名 = **物理** cwd 把 `/` 与**空白**都换成 `-`。
# 必须用 pwd -P：macOS 上 /tmp 是 /private/tmp 的符链，用逻辑路径会拼出不存在的目录。
# 空格也必须换（已实测踩坑）：每日分析 agent 的 cwd 是
# `~/Library/Application Support/neil-autopilot`，CLI 存成 `…-Application-Support-neil-autopilot`；
# 只换 `/` 会得到 `…-Application Support-…`、找不到文件，于是取证**静默失效**
# 并回退到“大概是 thinking”的笼统文案 —— 比没有取证更坐误。
SESSION_ROOT="${QODER_SESSION_ROOT:-$HOME/.qoder/projects}"
slug=""
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  slug="$(cd "$CWD" 2>/dev/null && pwd -P || printf '%s' "$CWD")"
else
  slug="$CWD"
fi
# 只换 `/` 与空格，**不用 `[:space:]`**：它包含换行，一旦有人改成
# `pwd -P | tr …` 这种管道写法，尾部换行会被转成一个多余的 `-`、slug 就对不上了
# （已在本仓的冗余测试里真的犯过这个错）。列举字符更稳，且对真实路径结果完全一致。
slug="$(printf '%s' "$slug" | tr '/ ' '--')"

TRANSCRIPT="$SESSION_ROOT/$slug/$SESSION_ID.jsonl"
[ -f "$TRANSCRIPT" ] || exit 0

# 逐块统计。用一次 jq 扫全文件，避免对大 transcript 反复读。
counts="$(jq -rs '
  [ .[] | select(.message.role == "assistant") | (.message.content // [])[] | .type ] as $blocks
  | {
      thinking:  ([ $blocks[] | select(. == "thinking" or . == "redacted_thinking") ] | length),
      text:      ([ $blocks[] | select(. == "text") ] | length),
      tool_use:  ([ $blocks[] | select(. == "tool_use") ] | length)
    }
  | "\(.thinking) \(.text) \(.tool_use)"
' "$TRANSCRIPT" 2>/dev/null || true)"
[ -n "$counts" ] || exit 0

N_THINK="$(printf '%s' "$counts" | awk '{print $1+0}')"
N_TEXT="$(printf '%s' "$counts" | awk '{print $2+0}')"
N_TOOL="$(printf '%s' "$counts" | awk '{print $3+0}')"

# 最后一个带 stop_reason 的 assistant 回合 —— 判断「回合是怎么收尾的」的唯一依据。
STOP_REASON="$(jq -rs '
  [ .[] | select(.message.role == "assistant") | .message.stop_reason | select(. != null) ] | last // ""
' "$TRANSCRIPT" 2>/dev/null || true)"

# 用过的工具名（去重保序）。
TOOLS="$(jq -rs '
  [ .[] | select(.message.role == "assistant") | (.message.content // [])[]
    | select(.type == "tool_use") | .name ] | unique | join(",")
' "$TRANSCRIPT" 2>/dev/null || true)"

# CLI 版本：transcript 自带 `version` 字段。从这里读而不是跑 `qodercli --version`：
# 零额外进程（实测过：对忽略 TERM 的 CLI，那个探测会把 dispatch 从 3s 拖到 33s），
# 而且它绑定的是**出事的那个会话**当时的版本，而非事后重查时的版本。
# 这对本仓尤其重要：已经出现过「版本号不变而行为反转」，结论必须能钉到具体会话。
CLI_VERSION="$(jq -rs '[ .[] | .version | select(. != null) ] | last // ""' "$TRANSCRIPT" 2>/dev/null || true)"

# 会话有没有**正常收尾**。CLI 在一个完整回合结束后会追加一条 `type=last-prompt`
# 记录；被中途掐断的会话没有它。2026-08-18 在三个真实 session 上验证（3/3 区分正确）：
# 正常跑完的 implement 末条记录就是 last-prompt，两个截断的末条都停在 assistant。
# 它比 stop_reason 更硬 —— stop_reason 可能缺失或为空，而这条记录的有无是二元事实，
# 因此用来给「stop_reason 说不清但会话确实被掐断」的情形兜底（见下方判据）。
SESSION_CLOSED=false
if jq -e -s 'any(.[]; .type == "last-prompt")' "$TRANSCRIPT" >/dev/null 2>&1; then
  SESSION_CLOSED=true
fi

# 是否动过盘。Write/Edit 类一律算；Bash **不能一律算**，必须看命令内容。
# 已实测踩坑（每日分析 agent，session d09d5965）：它只跑了一个只读 `ls` 加 3 次 Read，
# 一个字都没写，却因为「Bash 在列表里」被定成 WORK_DONE_UNREPORTED、结论“不要重试”——
# 而此时重试恰恰是正确动作。把探索型会话误判成“已改盘”会直接卡死整个 Task，
# 比不取证更坏，所以宁可在 Bash 上保守判“只读”。
# 注：这里只是启发式；「工作树到底变没变」的**地面真相**是调用方的 worktree 指纹
# （run-track-a.sh 的 worktree_signature），本字段不试图取代它。
MUTATING_TOOLS=""
case ",$TOOLS," in
  *,Write,*|*,Edit,*|*,MultiEdit,*|*,NotebookEdit,*|*,SearchReplace,*) MUTATING_TOOLS=yes ;;
esac
# Bash 按命令内容判定：出现重定向/写类命令才算动过盘。
if [ -z "$MUTATING_TOOLS" ]; then
  case ",$TOOLS," in
    *,Bash,*)
      if jq -rs '
        [ .[] | select(.message.role == "assistant") | (.message.content // [])[]
          | select(.type == "tool_use" and .name == "Bash") | (.input.command // "") ] | join("\n")
      ' "$TRANSCRIPT" 2>/dev/null \
        | LC_ALL=C grep -Eq '(^|[^>])>[^&]|>>|[|[:space:]]tee[[:space:]]|\b(mv|cp|rm|rmdir|mkdir|touch|install|truncate|dd|chmod|chown|ln)\b|sed[[:space:]]+-i|perl[[:space:]]+-i|tar[[:space:]]+-x|unzip|npm[[:space:]]+(i|install)|pip[[:space:]]+install|mvn|gradle|make|git[[:space:]]+(commit|add|apply|checkout|merge|reset|clean|stash|rm|mv)'; then
        MUTATING_TOOLS=yes
      fi
      ;;
  esac
fi
MUTATED=false
[ -z "$MUTATING_TOOLS" ] || MUTATED=true

# ── 判据（顺序即优先级，勿调换）────────────────────────────────────────────
# REPORTED 必须排在最前，否则健康回合会被误标成失败：一个正常收尾的 worker
# （stop_reason=end_turn 且产出过 text）当然也「动过盘」，若先判 MUTATED 就会
# 得到 WORK_DONE_UNREPORTED —— 而它明明报了数。已在自检 ③ 里实测到这个误判。
# 这条区分本身也有诊断价值：模型确实说了话、而调用方却收到空 stdout，
# 那是 **CLI 侧没把 text 打出来**，与「模型闭嘴」是两个不同的故障，修法也不同。
#
# 其余顺序里「动过盘」优先：它决定「能不能重试」，是几者中唯一不可逆的后果。
if [ "$STOP_REASON" = end_turn ] && [ "$N_TEXT" -gt 0 ]; then
  VERDICT=REPORTED
elif $MUTATED; then
  VERDICT=WORK_DONE_UNREPORTED
elif [ "$N_TOOL" -gt 0 ] && [ "$STOP_REASON" = tool_use ]; then
  VERDICT=TRUNCATED_TOOL_USE
# 兜底：调过工具、没动盘、且会话没有正常收尾记录 —— 同样是被掐断在工具循环里，
# 只是 stop_reason 没能证明它。不加这条时这种形态会落到 INCONCLUSIVE（“证据不足”），
# 上层就只能按 EMPTY 走 5 次全价静默重试。放在 tool_use 判据之后、THINKING_ONLY
# 之前：THINKING_ONLY 要求 N_TOOL=0，两者不重叠；MUTATED 已在更前面拦掉。
elif [ "$N_TOOL" -gt 0 ] && ! $SESSION_CLOSED; then
  VERDICT=TRUNCATED_TOOL_USE
elif [ "$N_TOOL" -eq 0 ] && [ "$N_TEXT" -eq 0 ] && [ "$N_THINK" -gt 0 ]; then
  VERDICT=THINKING_ONLY
else
  VERDICT=INCONCLUSIVE
fi

if [ "$FORMAT" = json ]; then
  printf '{"session_id":"%s","verdict":"%s","stop_reason":"%s","thinking_blocks":%s,"text_blocks":%s,"tool_calls":%s,"mutated":%s,"session_closed":%s,"tools":"%s","cli_version":"%s"}\n' \
    "$SESSION_ID" "$VERDICT" "$STOP_REASON" "$N_THINK" "$N_TEXT" "$N_TOOL" "$MUTATED" "$SESSION_CLOSED" "$TOOLS" "$CLI_VERSION"
  exit 0
fi

echo "session-forensics: verdict=$VERDICT stop_reason=${STOP_REASON:-<none>}"
echo "  session=$SESSION_ID cli_version=${CLI_VERSION:-unknown}"
echo "  transcript=$TRANSCRIPT"
echo "  blocks: thinking=$N_THINK text=$N_TEXT tool_use=$N_TOOL  mutated_worktree=$MUTATED  session_closed=$SESSION_CLOSED"
[ -z "$TOOLS" ] || echo "  tools: $TOOLS"
case "$VERDICT" in
  REPORTED)
    echo "  → 模型正常收尾并产出了正文。若调用方却收到空 stdout，问题在 CLI 打印侧，"
    echo "    不是模型闭嘴：别去调重试/降档参数，先核对 -o 输出格式与 stdout 重定向。" ;;
  WORK_DONE_UNREPORTED)
    echo "  → 该 worker 真的干了活并动过盘，只是最后一个回合没产出 text。"
    echo "    不要重试：新 worker 会叠在它的半成品上重做同一个 Task。先看 git status 再决定。" ;;
  TRUNCATED_TOOL_USE)
    echo "  → 模型发出了工具调用但 CLI 没执行就退出（文件零改动）。"
    echo "    原样重试与 -r 续跑均无效；缩小 Task 粒度 / 关掉 -o json / prompt 禁前言后重开新会话。" ;;
  THINKING_ONLY)
    echo "  → 整个回合收在 thinking 里，工具一次没调、什么都没做。重试是安全的。" ;;
  *)
    echo "  → 证据不足以定性；直接读 transcript。" ;;
esac
exit 0
