#!/usr/bin/env bash
# WHAT: 让**主控会话内的 subagent 开发流**也能写遥测。
# USAGE:
#   record-subagent.sh start --change NAME --task N [--stage implement] [--model Ultimate]
#   record-subagent.sh end   --change NAME --task N [--stage implement] [--status DONE|BLOCKED]
#   record-subagent.sh round --change NAME --task N --round R --verify pass|fail|skip \
#                            [--review REVIEW_PASS|REVIEW_FAIL|REVIEW_INCOMPLETE|UNKNOWN]
#   record-subagent.sh task  --change NAME --task N --status DONE|BLOCKED [--title T] \
#                            [--rounds R] [--committed true|false]
# EXIT: 恒 0（fail-safe。记账失败绝不能影响开发流本身，与 telemetry.sh 同契约）。
#
# 为什么必须有它（2026-08-16 复盘）：
#   档位 A（headless）每次 worker 都经 dispatch.sh，于是 runs/*.jsonl 里有完整的
#   stage/model/duration/exit_code。而改用「主控会话内 subagent 驱动开发」之后，
#   开发根本不经过 dispatch.sh —— 那一晚 23:20 之后的 8 小时、13128 credits、
#   3 个 change / ~25 个 Task **在遥测里一行都没有**（当天连 2026-08-17.jsonl 都不存在）。
#   于是「钱花在哪、时间耗在哪」完全不可归因，自进化也拿不到任何数据。
#
#   本脚本把 subagent 路径按同一套 event schema 记进同一个 runs/*.jsonl，
#   只用 `channel` 字段区分（cli / subagent），这样既能对比两条路径的单位成本，
#   也让 daily-analysis.sh 的既有聚合无需改动就能吃到 subagent 数据。
#
# 状态存放：start/end 之间的开始时间戳写在 $TMPDIR，**绝不落业务仓库**——
# 每个 Task 提交前的 `git add -A` 会把仓库内的一切扫进 commit（C12）。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=telemetry.sh
. "$SCRIPT_DIR/telemetry.sh"

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

ACTION="${1:-}"
[ -n "$ACTION" ] || { usage >&2; exit 0; }
shift || true

CHANGE=""; TASK=""; STAGE="implement"; MODEL_ARG=""; STATUS=""
ROUND=""; VERIFY="skip"; REVIEW="UNKNOWN"; TITLE=""; ROUNDS=""; COMMITTED="false"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --change)    CHANGE="${2:-}"; shift 2 ;;
    --task)      TASK="${2:-}"; shift 2 ;;
    --stage)     STAGE="${2:-}"; shift 2 ;;
    --model)     MODEL_ARG="${2:-}"; shift 2 ;;
    --status)    STATUS="${2:-}"; shift 2 ;;
    --round)     ROUND="${2:-}"; shift 2 ;;
    --verify)    VERIFY="${2:-}"; shift 2 ;;
    --review)    REVIEW="${2:-}"; shift 2 ;;
    --title)     TITLE="${2:-}"; shift 2 ;;
    --rounds)    ROUNDS="${2:-}"; shift 2 ;;
    --committed) COMMITTED="${2:-}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *)           shift ;;
  esac
done

[ -n "$CHANGE" ] || { echo "record-subagent: --change is required" >&2; exit 0; }

# run_id 以 change 名为键，让同一个 change 的所有事件能被聚合到一起。
# 与 run-track-a.sh 的 `<change>-<timestamp>` 形态保持家族相似，便于同表查询。
RUN_ID="${AUTOPILOT_RUN_ID:-subagent-$CHANGE-$(date +%Y%m%d)}"

# 状态目录：per-change + per-task 的开始时间戳。
STATE_DIR="${TMPDIR:-/tmp}/autopilot-subagent-$(printf '%s' "$CHANGE" | tr '/ ' '__')"
mkdir -p "$STATE_DIR" 2>/dev/null || true
_key() { printf '%s' "${STAGE}-${TASK:-none}" | tr '/ ' '__'; }

case "$ACTION" in
  start)
    date +%s > "$STATE_DIR/$(_key).start" 2>/dev/null || true
    ;;
  end)
    started=""
    [ -f "$STATE_DIR/$(_key).start" ] && started="$(cat "$STATE_DIR/$(_key).start" 2>/dev/null || true)"
    case "$started" in ''|*[!0-9]*) started="$(date +%s)" ;; esac
    rm -f "$STATE_DIR/$(_key).start" 2>/dev/null || true
    # exit_code 语义与 cli 通道对齐：DONE→0，其余→1，便于两条通道同口径统计失败率。
    rc=0
    [ "$STATUS" = DONE ] || [ -z "$STATUS" ] || rc=1
    # MODEL 是 telemetry_emit_dispatch 从调用方环境里读的变量名，这里显式赋值。
    MODEL="${MODEL_ARG:-${AUTOPILOT_SUBAGENT_MODEL:-unknown}}"
    AUTOPILOT_TM_CHANNEL=subagent
    AUTOPILOT_TM_TASK="$TASK"
    AUTOPILOT_STAGE="$STAGE"
    AUTOPILOT_RUN_ID="$RUN_ID"
    export MODEL AUTOPILOT_TM_CHANNEL AUTOPILOT_TM_TASK AUTOPILOT_STAGE AUTOPILOT_RUN_ID
    telemetry_emit_dispatch "$rc" "$started" || true
    ;;
  round)
    telemetry_emit_round "$RUN_ID" "$TASK" "${ROUND:-0}" "$VERIFY" "$REVIEW" || true
    ;;
  task)
    telemetry_emit_task "$RUN_ID" "$TASK" "$TITLE" "${STATUS:-BLOCKED}" "${ROUNDS:-0}" "$COMMITTED" || true
    ;;
  *)
    echo "record-subagent: unknown action '$ACTION'" >&2
    usage >&2
    ;;
esac
exit 0
