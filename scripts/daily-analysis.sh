#!/usr/bin/env bash
# daily-analysis.sh — deterministic daily orchestrator for agent-observability.
#
# WHAT: rotates raw runs/, aggregates today's runs/*.jsonl into a metrics/<date>.json
#   via jq (deterministic), and — only when today produced new runs (save tokens) —
#   dispatches ONE analysis agent (stage=analyze-daily) that writes reports/<date>.md
#   and an optional metrics/<date>.categories.json fragment, which this script then
#   merges back into metrics.json (never overwriting numeric fields).
#
# WHY BASH+JQ (not an LLM orchestrator, spec.md C10): rotate / numeric aggregation /
#   fragment-merge are all deterministic — only "categorize problems + write advice"
#   needs an LLM, and that's the one dispatched step.
#
# USAGE:
#   scripts/daily-analysis.sh [--date YYYY-MM-DD] [--keep-days N] [--trend-days N] [--dry-run]
#
# OPTIONS:
#   --date YYYY-MM-DD  Day to analyze (default: today).
#   --keep-days N      runs/ retention days (default: $NEIL_AUTOPILOT_KEEP_DAYS or 30).
#   --trend-days N     How many days of historical metrics to reference (default: 30).
#   --dry-run          Print the plan; rotate/aggregate/dispatch nothing.
#   -h | --help        show usage.
#
# ENV:
#   NEIL_AUTOPILOT_LOG_DIR    $LOG_ROOT override (see telemetry.sh: telemetry_log_root).
#   NEIL_AUTOPILOT_KEEP_DAYS  runs/ retention days fallback.
#   AUTOPILOT_DAILY_MODEL     analysis agent model (default: Ultimate).
#
# EXIT CODES:
#   0    ran to completion (including the "no new runs, skipped agent" path)
#   1    usage / missing jq / unwritable $LOG_ROOT
#
# PORTABILITY: bash 3.2 (macOS stock); hard-depends on jq for aggregation (C6
#   approved exception — local-only daily cron, fail-fast instead of degrading).

set -euo pipefail

# ── self-locate (macOS-safe; not readlink -f) ────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DISPATCH="$SCRIPT_DIR/dispatch.sh"
TELEMETRY="$SCRIPT_DIR/telemetry.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: 需要 jq（brew install jq）" >&2
  exit 1
fi
for dep in "$DISPATCH" "$TELEMETRY"; do
  [ -f "$dep" ] || { echo "ERROR: missing sibling script: $dep" >&2; exit 1; }
done

# shellcheck source=telemetry.sh
. "$TELEMETRY"

usage() { sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ── args ──────────────────────────────────────────────────────────────────────
DATE=""
KEEP_DAYS=""
TREND_DAYS=30
DRY_RUN=false
MODEL="${AUTOPILOT_DAILY_MODEL:-Ultimate}"

# 带值选项缺值时给可行动的报错（否则 set -u 只报 "$2: unbound variable"）。
need_value() { [ "$2" -ge 2 ] || { echo "ERROR: $1 requires a value (use --help)" >&2; exit 1; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --date) need_value "$1" $#; DATE="$2"; shift 2;;
    --keep-days) need_value "$1" $#; KEEP_DAYS="$2"; shift 2;;
    --trend-days) need_value "$1" $#; TREND_DAYS="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1 (use --help)" >&2; exit 1;;
  esac
done

[ -n "$DATE" ] || DATE="$(date +%F)"
case "$DATE" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
  *) echo "ERROR: --date must be YYYY-MM-DD" >&2; exit 1;;
esac

# 默认值必须是 30，与契约的其余四处保持一致：telemetry.sh 的 telemetry_rotate 默认 30、
# install-daily-schedule.sh 注入 30、AGENTS.md 与 README.md 的表格都写 30。曾误写为 3：
# 手动直跑本脚本（header USAGE 里就这么教）且未设环境变量时，telemetry_rotate 3 会执行
# `find runs -mtime +2 -delete`，把 3 天前的原始遥测静默删掉 —— 比文档承诺的保留期
# 提前 27 天，而这些日志正是自进化建议的唯一证据源（cron 停摆几天回来就不可恢复）。
[ -n "$KEEP_DAYS" ] || KEEP_DAYS="${NEIL_AUTOPILOT_KEEP_DAYS:-30}"
case "$KEEP_DAYS" in ''|*[!0-9]*) echo "ERROR: --keep-days must be a positive integer" >&2; exit 1;; esac
case "$TREND_DAYS" in ''|*[!0-9]*) echo "ERROR: --trend-days must be a positive integer" >&2; exit 1;; esac

log() { echo "[daily-analysis] $*"; }

LOG_ROOT="$(telemetry_log_root)"
if [ -z "$LOG_ROOT" ]; then
  echo "ERROR: 无法解析或写入 \${LOG_ROOT}（检查 NEIL_AUTOPILOT_LOG_DIR / 权限）" >&2
  exit 1
fi

log "date=$DATE log_root=$LOG_ROOT keep-days=$KEEP_DAYS trend-days=$TREND_DAYS dry-run=$DRY_RUN model=$MODEL"

if $DRY_RUN; then
  log "DRY-RUN: would rotate(keep=$KEEP_DAYS), aggregate metrics/$DATE.json"
  log "DRY-RUN: would dispatch analysis agent(model=$MODEL) only if runs/$DATE.jsonl has new events"
  exit 0
fi

WORK_TMP="$(mktemp -d)"
trap 'rm -rf "$WORK_TMP"' EXIT

# ── 1. rotate raw runs/ ──────────────────────────────────────────────────────
telemetry_rotate "$KEEP_DAYS"

# ── 2. jq-aggregate today's runs/<date>.jsonl → metrics/<date>.json ─────────
METRICS_FILE="$LOG_ROOT/metrics/$DATE.json"
RAW_JSONL="$LOG_ROOT/runs/$DATE.jsonl"
VALID_JSONL="$WORK_TMP/valid.jsonl"
: > "$VALID_JSONL"

if [ -f "$RAW_JSONL" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    printf '%s' "$line" | jq -e . >/dev/null 2>&1 && printf '%s\n' "$line" >> "$VALID_JSONL"
  done < "$RAW_JSONL"
fi

HAS_NEW_RUNS=false
[ -s "$VALID_JSONL" ] && HAS_NEW_RUNS=true

# （不再预先把全天事件 slurp 成一个 shell 变量：下方的 jq 已改用 --slurpfile 直接读
#   $VALID_JSONL，多存一份完整 JSON 只消耗内存并制造 ARG_MAX 隐患。）

# jq aggregation program. producer->consumer mapping per spec.md §3.3.
# commit_fail_count: task events carry committed=false for BOTH "rounds
# exhausted" and "commit failed" blocks (run-track-a.sh emits the same
# shape either way), so the only way to tell them apart is the LAST round
# event for that task: a real commit failure always happens AFTER a
# REVIEW_PASS round, while rounds-exhausted never reaches REVIEW_PASS.
read -r -d '' JQ_AGG <<'JQEOF' || true
def divround(a; b):
  if b == 0 then 0
  else (((a / b) * 100) | round) / 100
  end;
def cost_sum(items):
  (((items | map(.cost_usd // 0) | add // 0) * 1000000000000) | round) / 1000000000000;
def dispatch_summary(items):
  {
    count: (items | length),
    duration_s: (items | map(.duration_s // 0) | add // 0),
    input_tokens: (items | map(.input_tokens // 0) | add // 0),
    output_tokens: (items | map(.output_tokens // 0) | add // 0),
    cost_usd: cost_sum(items)
  };
# 在消费端排除测试事件（防御纵深）。写侧已经把 smoke 遥测无条件隔离到临时目录，
# 但历史日志里已经泄进去的假事件不应要求人工清洗才能用：只要聚合时过滤，
# 无论过去还是未来漏进来的测试数据都不会污染 metrics/。判据两条：
#   run_id 以 smoke- 开头（smoke 用的 change 目录名就叫 smoke）；model 为 TestModel。
# 实测过某日 11702 条事件里 10576 条（90.4%）是这两类，如果直接聚合，
# 自进化建议就是建立在假数据上的。
($events | map(select(
    (((.run_id // "") | startswith("smoke-")) | not)
    and ((.model // "") != "TestModel")
  ))) as $e
| ($e | map(select(.event == "run"))) as $runs
| ($e | map(select(.event == "task"))) as $tasks
| ($e | map(select(.event == "round"))) as $rounds
| ($e | map(select(.event == "dispatch"))) as $dispatches
| ($rounds | map(select(.verify == "pass" or .verify == "fail"))) as $verify_att
| ($rounds | map(select(.verify == "fail"))) as $verify_fail
| ($rounds | map(select(.review == "REVIEW_FAIL"))) as $review_fail
| ($rounds | map(select(.review == "REVIEW_INCOMPLETE"))) as $review_incomplete
| ($dispatches | map(select(.stage == "implement" or .stage == "review" or .stage == "fix"))) as $dev_dispatches
| ($tasks | map(select(.final_status == "BLOCKED"))) as $blocked_tasks
| {
    date: $date,
    runs: ($runs | length),
    runs_blocked: ($runs | map(select(.outcome == "blocked" or .outcome == "interrupted")) | length),
    tasks_total: ($tasks | length),
    tasks_done: ($tasks | map(select(.final_status == "DONE")) | length),
    tasks_blocked: ($blocked_tasks | length),
    verify_fail_rate: divround($verify_fail | length; $verify_att | length),
    review_fail_rounds: ($review_fail | length),
    review_incomplete_rounds: ($review_incomplete | length),
    review_total_rounds: ($rounds | length),
    review_fail_rate: divround($review_fail | length; $rounds | length),
    avg_rounds_per_task: divround(($tasks | map(.rounds // 0) | add // 0); $tasks | length),
    dispatch_error_count: ($dev_dispatches | map(select(.exit_code != 0 and .exit_code != 124)) | length),
    dispatch_timeout_count: ($dev_dispatches | map(select(.exit_code == 124)) | length),
    # 静默回合（rc=0 但无锚定结论行）在本字段存在之前是不可测的：exit_code 为 0，
    # 既不计入 error 也不计入 timeout，于是花了真实 token 却在报告里完全隐形。
    # 分开计：SILENT_COMPLETION=模型只在 thinking 里收尾；SILENT=静默但已改动工作树。
    dispatch_silent_count: ($dispatches | map(select((.failure_class // "") == "SILENT_COMPLETION")) | length),
    dispatch_silent_dirty_count: ($dispatches | map(select((.failure_class // "") == "SILENT")) | length),
    dispatch_silent_seconds: ($dispatches | map(select((.failure_class // "") | test("^SILENT")) | .duration_s // 0) | add // 0),
    tokens_input_total: ($dispatches | map(.input_tokens // 0) | add // 0),
    tokens_output_total: ($dispatches | map(.output_tokens // 0) | add // 0),
    tokens_cache_read_total: ($dispatches | map(.cache_read_tokens // 0) | add // 0),
    cost_usd_total: cost_sum($dispatches),
    dispatch_with_usage_count: ($dispatches | map(select(has("input_tokens") or has("output_tokens") or has("cache_read_tokens") or has("cost_usd"))) | length),
    dispatch_total_count: ($dispatches | length),
    by_stage: {
      implement: dispatch_summary($dispatches | map(select(.stage == "implement"))),
      review: dispatch_summary($dispatches | map(select(.stage == "review"))),
      fix: dispatch_summary($dispatches | map(select(.stage == "fix")))
    },
    by_model: ($dispatches | sort_by(.model // "") | group_by(.model // "") | map({key: (.[0].model // ""), value: dispatch_summary(.)}) | from_entries),
    commit_fail_count: (
      [ $blocked_tasks[] as $t
        | ($rounds | map(select(.run_id == $t.run_id and .task == $t.task)) | sort_by(.round) | last) as $lr
        | select($lr != null and $lr.review == "REVIEW_PASS")
      ] | length
    ),
    avg_duration_s: {
      implement: divround(($dev_dispatches | map(select(.stage == "implement") | .duration_s) | add // 0); ($dev_dispatches | map(select(.stage == "implement")) | length)),
      review: divround(($dev_dispatches | map(select(.stage == "review") | .duration_s) | add // 0); ($dev_dispatches | map(select(.stage == "review")) | length)),
      fix: divround(($dev_dispatches | map(select(.stage == "fix") | .duration_s) | add // 0); ($dev_dispatches | map(select(.stage == "fix")) | length))
    },
    top_problem_categories: []
  }
JQEOF

# 事件集走**文件**而不走 argv：`--argjson events "$EVENTS_JSON"` 把一整天的事件序列化后
# 当命令行参数传，macOS 的 ARG_MAX 只有 1MB（还要与环境变量共享）。本文件上方注释自己
# 就记载过单日 11702 条事件，每条数百字节就已越限（smoke 过滤发生在 jq 程序内部，
# argv 阶段是全量）；一到活跃日就会 execve 报 "Argument list too long"，set -e 退出，
# 当日 metrics 与报告全部缺失。--slurpfile 绑定的 $events 同样是数组，程序体无需改；
# 空文件得 []，与原来的 `|| echo '[]'` 兜底等价。
NEW_METRICS_JSON="$(LC_ALL=C jq -n --slurpfile events "$VALID_JSONL" --arg date "$DATE" "$JQ_AGG")"

# Re-running the same date must not silently reset a previously-merged
# top_problem_categories back to [] — only the guarded merge step below
# (fresh agent output) is allowed to replace it.
if [ -f "$METRICS_FILE" ] && jq -e '(.top_problem_categories // []) | (type == "array" and length > 0)' "$METRICS_FILE" >/dev/null 2>&1; then
  EXISTING_CATS="$(jq -c '.top_problem_categories' "$METRICS_FILE" 2>/dev/null || echo '[]')"
  NEW_METRICS_JSON="$(printf '%s' "$NEW_METRICS_JSON" | jq --argjson c "$EXISTING_CATS" '.top_problem_categories = $c' 2>/dev/null || printf '%s' "$NEW_METRICS_JSON")"
fi

printf '%s\n' "$NEW_METRICS_JSON" > "$METRICS_FILE"
log "metrics written: $METRICS_FILE"

# ── 3. no new runs today → stop here (save tokens); else dispatch 1 analysis agent ──
if ! $HAS_NEW_RUNS; then
  log "no new runs for $DATE → skip analysis agent (save tokens)"
  exit 0
fi

# build_analysis_prompt <out_file>
# Embeds spec.md §5.5's role -> runtime-prompt-location table so advice always
# points at the function that actually changes worker behaviour (not the
# doc-template *-prompt.md files, which are not loaded at runtime).
build_analysis_prompt() {
  local out="$1"
  local plugin_root trend_list cats_file
  plugin_root="$(cd "$SCRIPT_DIR/.." && pwd -P)"
  cats_file="$LOG_ROOT/metrics/$DATE.categories.json"
  trend_list="$(ls -1 "$LOG_ROOT/metrics" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}\.json$' | sort | tail -n "$TREND_DAYS" || true)"
  {
    echo "你是一个数据分析 agent，负责基于聚合遥测数据产出针对插件自身角色 prompt 的改进建议（stage=analyze-daily，经 dispatch.sh 调度）。"
    echo
    echo "## 读写范围（硬约束）"
    echo "- 只读：\$LOG_ROOT（${LOG_ROOT}，近 $TREND_DAYS 天 metrics 趋势 + 当日 runs/ 含关键输出）与插件仓库（${plugin_root}，用于定位角色 prompt 落点）。"
    echo "- 不读任意业务项目源码。"
    echo "- 只写：\$LOG_ROOT 下文件（reports/$DATE.md、可选 metrics/$DATE.categories.json）。产出是建议，不是改动；绝不自动改插件代码。"
    echo
    echo "## 角色 → 运行时 prompt 落点表（spec.md §5.5，改这里才真正改 worker 行为）"
    echo "- implement → scripts/run-track-a.sh 的 build_impl_prompt()"
    echo "- fix → scripts/run-track-a.sh 的 build_fix_prompt()"
    echo "- review → scripts/run-track-a.sh 的 build_review_prompt()"
    echo "- skills/autopilot-loop/implementer-prompt.md、skills/autopilot-review/reviewer-prompt.md 是文档模板（运行时不加载），不是运行时落点；改它们不改变 worker 行为，仅作次级同步项。"
    echo "- 建议必须引用上述运行时落点的具体文件+函数，并标注证据来源（哪些 runs/metrics 支撑）。"
    echo
    echo "## 当日体检数据"
    echo "- 当日 metrics: $METRICS_FILE"
    echo "- 当日 runs（含关键输出目录）: $RAW_JSONL 、 $LOG_ROOT/runs/*/（若存在）"
    echo "- 近 $TREND_DAYS 天历史 metrics 供趋势对比："
    if [ -n "$trend_list" ]; then
      printf '%s\n' "$trend_list" | sed "s#^#  - $LOG_ROOT/metrics/#"
    else
      echo "  （无历史 metrics）"
    fi
    echo
    echo "## 产出要求"
    echo "1. 写 $LOG_ROOT/reports/$DATE.md，结构：\`## 体检摘要\` | \`## 趋势\`（对比历史 metrics） | \`## 高频问题\`（定性归类 + 样例链接到 runs/） | \`## 改进建议\`（引用上面角色→落点表） | \`## 免责\`（仅建议，需人工批准，系统绝不自动改插件代码）。"
    echo "2. 可选：把定性归类结果写 ${cats_file}——**只允许一个 JSON 数组**，形如 [{\"category\":\"空值/边界未检查\",\"count\":4}, ...]；无归类可跳过（不要写空文件/非数组）。"
    echo
    echo "## 报告格式（回复末尾必须输出）"
    echo "- **Status:** DONE（报告已写入）或 BLOCKED（写不了，并说明原因）"
  } > "$out"
}

PROMPT_FILE="$WORK_TMP/analysis-prompt.md"
RESULT_FILE="$WORK_TMP/analysis-result.md"
build_analysis_prompt "$PROMPT_FILE"

PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
REPORT_FILE="$LOG_ROOT/reports/$DATE.md"
# 有界重试：本阶段原本只 dispatch 一次，所以只要碰上一次静默回合（模型把整个
# 回合收在 thinking 里、不产出 text）当日就永久没报告——而 run-track-a 同样的静默靠
# 重试就恢复了。本任务幂等（只读遥测 + 重写同一份报告），重试无副作用；且以「报告
# 文件是否落盘」为退出条件，成功即停，不会白烧 token。
ATTEMPTS="${AUTOPILOT_DAILY_RETRIES:-3}"
case "$ATTEMPTS" in ''|*[!0-9]*) ATTEMPTS=3 ;; esac
[ "$ATTEMPTS" -ge 1 ] || ATTEMPTS=1
REPORT_OK=0
attempt=1
# 基线指纹：下面的产物校验必须是「**本次运行**产生了新报告」，而不是「报告文件存在」。
# $REPORT_FILE 在本脚本里从不被删除或清空，所以只要该日期已有报告（launchd 因唤醒
# 重复触发同一天、人工用 --date 回补/重跑），即使本次 dispatch 完全静默、一字未写，
# 第一轮就会命中 `-s` 而宣告成功 —— 有界重试（本阶段的核心机制）在重跑路径上被
# 完全绕过，使用者看到的是一份**旧内容**报告被宣告成功。
REPORT_SIG_BEFORE="none"
if [ -f "$REPORT_FILE" ]; then
  REPORT_SIG_BEFORE="$(cksum < "$REPORT_FILE" 2>/dev/null || echo none)"
fi
while [ "$attempt" -le "$ATTEMPTS" ]; do
  log "dispatching analysis agent (stage=analyze-daily model=$MODEL attempt=$attempt/$ATTEMPTS)"
  if ! AUTOPILOT_STAGE="analyze-daily" AUTOPILOT_RUN_ID="$DATE" AUTOPILOT_ATTEMPT="$attempt" \
      "$DISPATCH" --model "$MODEL" --cwd "$PLUGIN_ROOT" \
      --prompt-file "$PROMPT_FILE" \
      --instruction "分析当日遥测数据，写体检报告到 \$LOG_ROOT/reports/，可选写分类片段；只出建议不改代码。" \
      > "$RESULT_FILE" 2>&1; then
    log "WARN: analysis agent dispatch failed (attempt $attempt/$ATTEMPTS)"
    tail -20 "$RESULT_FILE" 2>/dev/null | sed 's/^/  | /'
  fi
  # 产物硬校验：dispatch rc=0 只说明 CLI 正常退出，不说明 agent 真的写了报告。
  # 假成功比失败更危险：使用者以为有体检报告，实际从 7 月起就无产出。
  # 判据是「指纹变了」或「有明确的 DONE 裁决」二者之一：
  #   ① 只看文件存在会让同一日期重跑时旧报告冒充本次产物（静默回合也算成功）；
  #   ② 但只看指纹也不对：agent 幂等地确认“旧报告已完备”而未改写（或写出字节相同
  #     的内容）是**合法结果**，那样会白烧完所有重试并报一句误导的 “no report”。
  # 静默回合没有锚定裁决行，所以② 不会放过它 —— 防假成功的语义不变。
  REPORT_SIG_NOW="none"
  [ -f "$REPORT_FILE" ] && REPORT_SIG_NOW="$(cksum < "$REPORT_FILE" 2>/dev/null || echo none)"
  REPORT_VERDICT="$("$SCRIPT_DIR/parse-markers.sh" status "$RESULT_FILE" 2>/dev/null || echo UNKNOWN)"
  if [ -s "$REPORT_FILE" ] && { [ "$REPORT_SIG_NOW" != "$REPORT_SIG_BEFORE" ] \
      || [ "$REPORT_VERDICT" = DONE ] || [ "$REPORT_VERDICT" = DONE_WITH_CONCERNS ]; }; then
    REPORT_OK=1
    log "report verified: $REPORT_FILE ($(wc -c < "$REPORT_FILE" | tr -d '[:space:]') bytes, attempt $attempt)"
    break
  fi
  log "WARN: no report at $REPORT_FILE after attempt $attempt/$ATTEMPTS"
  log "      worker verdict: $("$SCRIPT_DIR/parse-markers.sh" status "$RESULT_FILE" 2>/dev/null || echo UNKNOWN)"
  tail -6 "$RESULT_FILE" 2>/dev/null | sed 's/^/  | /'
  attempt=$(( attempt + 1 ))
done
if [ "$REPORT_OK" -eq 0 ]; then
  log "WARN: analysis agent produced no report after $ATTEMPTS attempt(s) (metrics are still valid)"
fi

# ── 4. categories fragment merge protocol (spec.md §5.4) ────────────────────
# Guarded so a missing/empty/non-array fragment never touches metrics.json,
# and the merge is verified valid JSON before it replaces the file — numeric
# fields are never part of this jq expression, so they can never be clobbered.
CATS_FILE="$LOG_ROOT/metrics/$DATE.categories.json"
if [ -s "$CATS_FILE" ] && jq -e 'type == "array" and length > 0' "$CATS_FILE" >/dev/null 2>&1; then
  MERGE_TMP="$WORK_TMP/metrics-merged.json"
  if jq --slurpfile c "$CATS_FILE" '.top_problem_categories = $c[0]' "$METRICS_FILE" > "$MERGE_TMP" 2>/dev/null \
      && jq -e . "$MERGE_TMP" >/dev/null 2>&1; then
    mv "$MERGE_TMP" "$METRICS_FILE"
    log "categories merged into $METRICS_FILE"
  else
    log "WARN: categories merge produced invalid JSON → kept previous metrics.json unchanged"
  fi
else
  log "no categories fragment to merge (missing/empty/non-array) — skipped"
fi

if [ "$REPORT_OK" -eq 1 ]; then
  log "done: report(s) under $LOG_ROOT/reports/, metrics under $LOG_ROOT/metrics/"
  exit 0
fi
log "done with WARNINGS: metrics under $LOG_ROOT/metrics/, but no report was produced"
exit 0
