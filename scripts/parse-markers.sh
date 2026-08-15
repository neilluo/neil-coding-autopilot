#!/usr/bin/env bash
# 锚定式解析 worker 输出的 Status / CR 裁决（spec §11 D19 的唯一实现）
# 用法: parse-markers.sh status|review <log-file>
# 输出: status → DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT|UNKNOWN
#       review → REVIEW_PASS|REVIEW_FAIL|UNKNOWN
# 规则: 只看末 15 行；须行首锚定；裁决须独占一行。文件缺失/无匹配 → UNKNOWN。
#
# 锚定集合必须覆盖本系统自己要求 worker 输出的全部形式，否则就是「让人家写 A、
# 自己只认 B」的假阴性门禁。已知要求形式：
#   run-track-a 提示词：`- **Status:** DONE`（带 markdown 列表符！）
#   run-autopilot 提示词：`` `FINISH_STATUS=DONE` `` / `` `EVOLVE_STATUS=DONE` ``（带反引号、= 分隔）
# 旧实现只认 `^\**Status[:：]`，于是 FINISH_STATUS=DONE 永远解成 UNKNOWN，run-autopilot
# 的 finish/evolve 阶段无论实际成败都被判 BLOCKED。扩宽后仍保持两道约束防误报：
# 只看末 15 行、且标记必须从行首开始（正文讲解里的 Status 不会命中）。
set -uo pipefail
MODE="${1:-}"; FILE="${2:-}"
WINDOW="${AUTOPILOT_MARKER_WINDOW:-15}"
# 可选前缀：markdown 列表符（- * +）、粗体星号、反引号；标记名允许 Status 或 XXX_STATUS；
# 分隔符允许 : ： =。
LEAD='^[[:space:]]*([-*+][[:space:]]+)?[`*]*'
STATUS_RE="${LEAD}([Ss]tatus|[A-Z][A-Z0-9_]*_STATUS)[\`*]*[:：=][\`*]*[[:space:]]*[\`*]*(DONE_WITH_CONCERNS|DONE|BLOCKED|NEEDS_CONTEXT)"
REVIEW_RE="${LEAD}REVIEW_(PASS|FAIL)[\`*]*[[:space:]]*$"
if [ "$MODE" = "-h" ] || [ "$MODE" = "--help" ]; then echo "usage: parse-markers.sh status|review <log>"; exit 0; fi
if [ -z "$MODE" ] || [ -z "$FILE" ]; then echo "usage: parse-markers.sh status|review <log>" >&2; exit 2; fi
if [ ! -f "$FILE" ]; then echo "UNKNOWN"; exit 0; fi
case "$MODE" in
  status)
    M="$(tail -"$WINDOW" "$FILE" 2>/dev/null \
      | grep -oE "$STATUS_RE" \
      | tail -1 | grep -oE '(DONE_WITH_CONCERNS|DONE|BLOCKED|NEEDS_CONTEXT)' | tail -1 || true)"
    ;;
  review)
    M="$(tail -"$WINDOW" "$FILE" 2>/dev/null \
      | grep -oE "$REVIEW_RE" \
      | tail -1 | grep -oE 'REVIEW_(PASS|FAIL)' | tail -1 || true)"
    ;;
  *) echo "usage: parse-markers.sh status|review <log>" >&2; exit 2 ;;
esac
[ -n "$M" ] && echo "$M" || echo "UNKNOWN"
exit 0
