#!/usr/bin/env bash
# 原子更新 tasks.md 中指定 task 的状态
# 用法: task-state.sh <tasks-file> <task-number> <new-status>
# 并发保护：优先用 flock（Linux）；macOS 无 flock 时降级为 mkdir 原子锁。

set -euo pipefail

TASKS_FILE="$1"
TASK_NUM="$2"
NEW_STATUS="$3"
# 锁文件放 TMPDIR（不放业务仓库内，避免被 run-track-a 的 git add -A 卷入提交）
_LOCK_BASE="${TMPDIR:-/tmp}/autopilot-taskstate$(printf '%s' "$TASKS_FILE" | tr '/ ' '__')"
LOCK_FILE="${_LOCK_BASE}.lock"    # flock 分支用
LOCK_DIR="${_LOCK_BASE}.lockd"     # mkdir 降级分支用

if [ ! -f "$TASKS_FILE" ]; then
  echo "ERROR: Tasks file not found: $TASKS_FILE" >&2
  exit 1
fi

# 实际写操作（幂等）：sed -i.bak 两平台通吃（GNU/BSD 都接受附着式后缀）
_update_status() {
  sed -i.bak -E "/^## Task ${TASK_NUM}:/,/^## Task [0-9]+:|^---$/ s/^\*\*Status\*\*:[[:space:]]*.*/\*\*Status\*\*: ${NEW_STATUS}/" "$TASKS_FILE"
  rm -f "${TASKS_FILE}.bak"
}

if command -v flock >/dev/null 2>&1; then
  # Linux：fd-based flock
  (
    flock -w 10 200 || { echo "ERROR: Cannot acquire lock" >&2; exit 1; }
    _update_status
  ) 200>"$LOCK_FILE"
else
  # macOS/无 flock：mkdir 原子锁（mkdir 成功=持锁），最多等 ~10s
  acquired=0; i=0
  while [ "$i" -lt 100 ]; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      acquired=1
      trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
      break
    fi
    sleep 0.1; i=$((i + 1))
  done
  if [ "$acquired" -ne 1 ]; then
    echo "ERROR: Cannot acquire lock (mkdir): $LOCK_DIR" >&2
    exit 1
  fi
  _update_status
  rmdir "$LOCK_DIR" 2>/dev/null || true
  trap - EXIT
fi
