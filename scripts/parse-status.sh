#!/usr/bin/env bash
# 从 worker 输出文件中鲁棒提取 Status
# 用法: parse-status.sh /tmp/autopilot-task-N-result.md
# 输出: DONE / DONE_WITH_CONCERNS / BLOCKED / NEEDS_CONTEXT / UNKNOWN

set -euo pipefail

FILE="$1"
if [ ! -f "$FILE" ]; then
  echo "UNKNOWN"
  exit 1
fi

# 容错解析：大小写不敏感、支持中英文冒号、支持有无星号。
# 直接锚定到已知状态词提取，避免 GNU-only 的 grep -P/\K（macOS BSD grep 不支持 -P，会 exit 2）；
# 同时修正旧正则对 `**Status:** DONE`（星号在冒号外侧）会误取到 `**` 的问题。
# 末尾 `|| true` 防止无匹配时 pipefail + set -e 提前退出，让下方 case 兜底为 UNKNOWN。
STATUS=$(grep -ioE 'status[^A-Za-z]*(DONE_WITH_CONCERNS|DONE|BLOCKED|NEEDS_CONTEXT)' "$FILE" 2>/dev/null \
  | tail -1 \
  | grep -ioE '(DONE_WITH_CONCERNS|DONE|BLOCKED|NEEDS_CONTEXT)' \
  | tail -1 \
  | tr '[:lower:]' '[:upper:]' || true)

case "$STATUS" in
  DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT)
    echo "$STATUS" ;;
  *)
    echo "UNKNOWN" ;;
esac
