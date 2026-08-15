#!/usr/bin/env bash
# WHAT: Run project smoke scripts sequentially with fail-fast reporting.
# USAGE: smoke-all.sh [--only <pattern>] [--list]
# EXIT CODES: 0 when selected smokes pass or are listed; 1 on usage or smoke failure.
set -uo pipefail
unset AUTOPILOT_RUN_ID

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SELF="$SCRIPT_DIR/$(basename "$0")"
ONLY=""
LIST=0

usage() {
  echo "Usage: smoke-all.sh [--only <pattern>] [--list]"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --only)
      if [ "$#" -lt 2 ]; then
        echo "Usage: smoke-all.sh [--only <pattern>] [--list]" >&2
        exit 1
      fi
      ONLY="$2"
      shift 2
      ;;
    --list)
      LIST=1
      shift
      ;;
    *)
      echo "Usage: smoke-all.sh [--only <pattern>] [--list]" >&2
      exit 1
      ;;
  esac
done

SMOKE_LIST="$(mktemp)"
SMOKE_OUTPUT="$(mktemp)"
# 遥测沙箱（单一收口点）：smoke 会跑完整 Track A loop 与 dispatch，每一步都 emit 遥测。
# 不隔离就会写进生产日志根：实测某日 640 条事件里 599 条来自 smoke、runs/ 积下
# 1081 个 smoke-* 目录、144 条 model=TestModel——daily-analysis 聚合出来的就是假数据，
# 而那份报告正是自进化建议的依据。在这里 export（而不是逐个 smoke 改）：子进程
# 全部继承，新增 smoke 也自动安全。
SMOKE_TM_ROOT="$(mktemp -d)"
export NEIL_AUTOPILOT_LOG_DIR="$SMOKE_TM_ROOT/telemetry"
trap 'rm -f "$SMOKE_LIST" "$SMOKE_OUTPUT"; rm -rf "$SMOKE_TM_ROOT"' EXIT

for smoke in "$SCRIPT_DIR"/smoke-*.sh; do
  [ -f "$smoke" ] || continue
  [ "$smoke" = "$SELF" ] && continue
  name="$(basename "$smoke")"
  case "$name" in
    *"$ONLY"*) printf '%s\n' "$smoke" ;;
  esac
done | LC_ALL=C sort > "$SMOKE_LIST"

if [ "$LIST" -eq 1 ]; then
  while IFS= read -r smoke; do
    basename "$smoke"
  done < "$SMOKE_LIST"
  exit 0
fi

while IFS= read -r smoke; do
  [ -n "$smoke" ] || continue
  name="$(basename "$smoke")"
  started="$(date +%s)"
  if bash "$smoke" > "$SMOKE_OUTPUT" 2>&1; then
    elapsed=$(( $(date +%s) - started ))
    echo "PASS $name (${elapsed}s)"
  else
    elapsed=$(( $(date +%s) - started ))
    echo "FAIL $name (${elapsed}s)"
    tail -n 30 "$SMOKE_OUTPUT"
    exit 1
  fi
done < "$SMOKE_LIST"

# 隔离自检：上面跑过 dispatch / Track A loop，遥测必须落在沙箱里。沙箱为空意味着
# 事件写到了沙箱之外（大概率是生产日志根），这比 smoke 本身挂掉更隐蔽，所以显式报错。
if [ -z "$ONLY" ] && [ ! -d "$NEIL_AUTOPILOT_LOG_DIR/runs" ]; then
  echo "FAIL telemetry isolation: no events landed in the smoke sandbox ($NEIL_AUTOPILOT_LOG_DIR)"
  echo "     smoke telemetry may be leaking into the production log root."
  exit 1
fi

exit 0
