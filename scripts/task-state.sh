#!/usr/bin/env bash
# 原子更新 tasks.md 中指定 task 的状态
# 用法: task-state.sh <tasks-file> <task-number> <new-status>
# 使用 flock 防止并发写入冲突

set -euo pipefail

TASKS_FILE="$1"
TASK_NUM="$2"
NEW_STATUS="$3"
LOCK_FILE="${TASKS_FILE}.lock"

if [ ! -f "$TASKS_FILE" ]; then
  echo "ERROR: Tasks file not found: $TASKS_FILE" >&2
  exit 1
fi

(
  flock -w 10 200 || { echo "ERROR: Cannot acquire lock" >&2; exit 1; }

  # 使用 sed 原子替换指定 task 的 Status 行
  sed -i.bak -E "/^## Task ${TASK_NUM}:/,/^## Task [0-9]+:|^---$/ s/^\*\*Status\*\*: .*/\*\*Status\*\*: ${NEW_STATUS}/" "$TASKS_FILE"
  rm -f "${TASKS_FILE}.bak"

) 200>"$LOCK_FILE"
