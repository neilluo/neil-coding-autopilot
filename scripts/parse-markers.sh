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
# 分隔符允许 : ： =。全角冒号必须写成分组交替 `(:|：|=)` 而不能放进方括号：
# `：` 是三字节 UTF-8（EF BC 9A），放在 `[:：=]` 里时，非 UTF-8 locale 下 grep 会把它
# 拆成三个单字节成员，于是只能匹配到 0xEF 一个字节、后续 0xBC 就接不上了，
# 整行 `**Status：** DONE` 解成 UNKNOWN。实测：LC_ALL=en_US.UTF-8 得 DONE，
# LC_ALL=C 得 UNKNOWN。而本仓的定时任务正是这种环境：launchd/cron 默认不带 LANG，
# 进程 locale 就是 C，而所有提示词都是中文、模型输出全角冒号是常态 —— 正是本文件
# 要消除的那类假阴：活已干完、却因结论行未被识别而被当成 EMPTY 重试到耗尽。
LEAD='^[[:space:]]*([-*+][[:space:]]+)?[`*]*'
STATUS_RE="${LEAD}([Ss]tatus|[A-Z][A-Z0-9_]*_STATUS)[\`*]*(:|：|=)[\`*]*[[:space:]]*[\`*]*(DONE_WITH_CONCERNS|DONE|BLOCKED|NEEDS_CONTEXT)"
# 裁决行必须独占一行（行尾不得跟注释）—— 这是有意收紧的假阳性防御，并由
# smoke-parse-markers.sh case5 钉住（`REVIEW_PASS   # 无 CRITICAL/MAJOR` 必须得到 UNKNOWN）。
# 注意：所有要求 worker 输出裁决的提示词模板都必须与此一致——切勿在模板里示范
# 带尾随注释的形式，否则 worker 照抛一行就会被这里判成 UNKNOWN，一个实际上
# REVIEW_PASS 的 Task 会被 fail-closed 判成 BLOCKED（run-track-a.sh 的 review 模板
# 曾犯过这个错，已修）。
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
