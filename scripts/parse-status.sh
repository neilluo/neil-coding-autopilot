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

# 容错解析：大小写不敏感、支持中英文冒号、支持有无星号
STATUS=$(grep -ioP '(?:\*{0,2})status(?:\*{0,2})\s*[：:]\s*\K\S+' "$FILE" | tail -1 | tr '[:lower:]' '[:upper:]')

case "$STATUS" in
  DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT)
    echo "$STATUS" ;;
  *)
    echo "UNKNOWN" ;;
esac
