#!/usr/bin/env bash
# 原子更新 tasks.md 中指定 task 的状态
# 用法: task-state.sh <tasks-file> <task-number> <new-status>
# 并发保护：优先用 flock（Linux）；macOS 无 flock 时降级为 mkdir 原子锁。

set -euo pipefail

TASKS_FILE="${1:-}"
TASK_NUM="${2:-}"
NEW_STATUS="${3:-}"
# 入参校验：无校验时上游传空 $2，sed 地址会变成 `^## Task :`，匹配不到任何行但
# sed 仍然 exit 0 —— 于是一个「状态写入脚本」什么都没改却报成功，progress 跟踪与
# tasks.md 实际状态静默脱链。写入类脚本宁可失败，不可假成功。
case "$TASK_NUM" in
  ''|*[!0-9]*) echo "ERROR: task number must be a positive integer, got: '$TASK_NUM'" >&2; exit 1 ;;
esac
case "$NEW_STATUS" in
  ''|*[!A-Za-z_]*) echo "ERROR: status must be a non-empty word, got: '$NEW_STATUS'" >&2; exit 1 ;;
esac
# 锁文件放 TMPDIR（不放业务仓库内，避免被 run-track-a 的 git add -A 卷入提交）
_LOCK_BASE="${TMPDIR:-/tmp}/autopilot-taskstate$(printf '%s' "$TASKS_FILE" | tr '/ ' '__')"
LOCK_FILE="${_LOCK_BASE}.lock"    # flock 分支用
LOCK_DIR="${_LOCK_BASE}.lockd"     # mkdir 降级分支用

if [ ! -f "$TASKS_FILE" ]; then
  echo "ERROR: Tasks file not found: $TASKS_FILE" >&2
  exit 1
fi

# 实际写操作（幂等）：sed -i.bak 两平台通吃（GNU/BSD 都接受附着式后缀）
# 写后必须校验：入参格式合法也照样可能无匹配而 sed 仍退 0 —— 例如编号越界
# （`task-state.sh tasks.md 99 DONE`）、该 Task 段落根本没有 `**Status**:` 行（finish-change.sh
# 新增的「标题数==状态行数」门禁就是因为这种情形真实存在）、或标题用了全角冒号。
# 那些情况下脚本会静默“成功”而 tasks.md 未改，状态跟踪与实际执行全程脱链。
_update_status() {
  sed -i.bak -E "/^## Task ${TASK_NUM}[:：]/,/^## Task [0-9]+[:：]|^---$/ s/^\*\*Status\*\*:[[:space:]]*.*/\*\*Status\*\*: ${NEW_STATUS}/" "$TASKS_FILE"
  rm -f "${TASKS_FILE}.bak"
  if ! awk -v n="$TASK_NUM" -v want="**Status**: ${NEW_STATUS}" '
      $0 ~ ("^## Task " n "[:：]") { inblk=1; next }
      inblk && ($0 ~ "^## Task [0-9]+[:：]" || $0 ~ "^---$") { inblk=0 }
      inblk && $0 == want { found=1 }
      END { exit(found ? 0 : 1) }
    ' "$TASKS_FILE"; then
    echo "ERROR: task-state.sh: Task ${TASK_NUM} 的状态行未被写入 ${NEW_STATUS}（编号不存在？该段没有顶格的 '**Status**:' 行？）: $TASKS_FILE" >&2
    return 1
  fi
  return 0
}

if command -v flock >/dev/null 2>&1; then
  # Linux：fd-based flock
  (
    flock -w 10 200 || { echo "ERROR: Cannot acquire lock" >&2; exit 1; }
    _update_status
  ) 200>"$LOCK_FILE"
else
  # macOS/无 flock：mkdir 原子锁（mkdir 成功=持锁），最多等 ~10s
  # 陈旧锁自愈：EXIT trap 只能覆盖正常退出与可捕获信号；进程被 SIGKILL（kill -9 /
  # OOM / `timeout -k` 的强杀）时 trap 不会执行，锁目录就永久残留。而本脚本是每次
  # 状态切换都要调的，一旦残留，此后所有调用都在 ~10s 轮询后 exit 1，整条无人值守
  # 流水线从此卡死直到人工 rmdir。因此轮询失败时按锁龄判陈旧（与 run-track-a.sh 同思路）。
  _dir_age_s() {
    local d="${1:-}" born now
    [ -n "$d" ] && [ -d "$d" ] || { echo 0; return 0; }
    if [ "${OSTYPE:-}" != "${OSTYPE#darwin}" ]; then
      born="$(stat -f '%m' "$d" 2>/dev/null || echo 0)"
    else
      born="$(stat -c '%Y' "$d" 2>/dev/null || echo 0)"
    fi
    case "$born" in ''|*[!0-9]*) born=0 ;; esac
    now="$(date +%s 2>/dev/null || echo 0)"
    if [ "$born" -gt 0 ] && [ "$now" -gt "$born" ]; then echo $(( now - born )); else echo 0; fi
  }
  _lock_age_s() { _dir_age_s "$LOCK_DIR"; }
  STALE_AFTER_S="${AUTOPILOT_TASKSTATE_LOCK_STALE_S:-120}"
  acquired=0; i=0
  while [ "$i" -lt 100 ]; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      acquired=1
      trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
      break
    fi
    if [ "$(_lock_age_s)" -gt "$STALE_AFTER_S" ]; then
      # 回收必须原子：“判陈旧 → rmdir”是两步，多个 waiter 同时撞上同一个残留锁时，
      # P1 删掉旧锁并 mkdir 持锁后，P2 才执行自己的 rmdir，会把 P1 **刚建的新锁**删掉
      # （空目录 rmdir 必成功），于是两个进程同时持锁、并发对同一 tasks.md 跑 sed -i，
      # 一次状态写入会被覆盖丢失且双方都 exit 0 —— 正是 run-track-a.sh 刚修掉的那个
      # TOCTOU 双持锁模式。用同目录内的原子 rename 认领：只有一个 waiter 能 mv 成功。
      # 搬走后必须**复核锁龄**：mv 只保证单次 rename 原子，不保证搬走的还是刚才判过陈旧的
      # 那个锁：P1 认领成功、重建新锁并开始写 tasks.md 后，P2 才执行自己的 mv，
      # 此时源目录又存在（P1 刚建的新鲜锁）、mv 照样成功 → 两个进程同时对同一
      # tasks.md 跑 sed -i，一次状态写入被覆盖丢失且双方都 exit 0。
      if mv "$LOCK_DIR" "${LOCK_DIR}.reap.$$" 2>/dev/null; then
        if [ "$(_dir_age_s "${LOCK_DIR}.reap.$$")" -gt "$STALE_AFTER_S" ]; then
          echo "WARN: stale task-state lock (>${STALE_AFTER_S}s), reclaimed: $LOCK_DIR" >&2
          rm -rf "${LOCK_DIR}.reap.$$" 2>/dev/null || true
        else
          # 搬到的是新鲜锁（别人刚持上）—— 原路搬回去，按“认领失败”继续等。
          mv "${LOCK_DIR}.reap.$$" "$LOCK_DIR" 2>/dev/null || rm -rf "${LOCK_DIR}.reap.$$" 2>/dev/null || true
        fi
      fi
      # 必须同样计数再 continue：若认领始终失败（权限等），不计数的 continue 会变成
      # 无限循环——把一个可报错的死锁换成更难查的挂死。i 有上限，循环必终止。
      i=$((i + 1))
      continue
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
