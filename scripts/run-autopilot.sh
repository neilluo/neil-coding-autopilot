#!/usr/bin/env bash
# run-autopilot.sh — Track A end-to-end orchestrator for neil-coding-autopilot.
#
# WHAT: Chains the three headless Track A stages in order:
#   run-track-a.sh (loop)  →  finish worker  →  evolve worker.
#   The loop stage is delegated verbatim to run-track-a.sh (this script does
#   not reimplement or modify it). finish/evolve are spawned as fresh
#   qodercli workers via dispatch.sh, exactly like run-track-a.sh spawns its
#   implement/review/fix workers — keeping this orchestrator's own context
#   near-zero and every stage disposable / resumable.
#
# WHY fail-closed: a non-zero exit from loop must NEVER be followed by
#   finish/evolve (unreviewed or unfinished work must not be merged or
#   distilled into knowledge). Each stage's own status is parsed via
#   parse-status.sh, matching the loop's own worker-status handling.
#
# USAGE:
#   scripts/run-autopilot.sh --change-dir autopilot/changes/<feat> --cwd <project-root> [opts]
#
# OPTIONS:
#   --change-dir DIR     Change dir holding tasks.md (required).
#   --cwd DIR             Project root where loop/finish/evolve run (default: $PWD).
#   --tasks FILE          Passed through to run-track-a.sh.
#   --resume              Passed through to run-track-a.sh.
#   --max-rounds N        Passed through to run-track-a.sh.
#   --impl-model M        Passed through to run-track-a.sh.
#   --review-model M      Passed through to run-track-a.sh.
#   --finish-model M      Model for the finish worker (default: $AUTOPILOT_FINISH_MODEL or Performance).
#   --evolve-model M      Model for the evolve worker (default: $AUTOPILOT_EVOLVE_MODEL or Ultimate).
#   --skip-finish          Skip the finish stage.
#   --skip-loop            Skip the loop stage (auto-enabled when the change is
#                          already archived, so a failed evolve can be rerun).
#   --skip-evolve          Skip the evolve stage.
#   --dry-run              Parse & print the plan; do NOT spawn any workers.
#   -h | --help            Show usage.
#
# EXIT CODES (semantic, CI-friendly):
#   0    loop → finish → evolve all succeeded (or were skipped)
#   1    usage / setup error
#   2    loop / finish / evolve BLOCKED (fail-closed, stopped)
#   130  interrupted
#
# PORTABILITY: macOS-safe (targets bash 3.2; no associative arrays / mapfile;
#   self-locates via `pwd -P`). Delegates to sibling run-track-a.sh /
#   dispatch.sh / parse-status.sh (path resolution: this script lives with
#   them in the plugin, so SCRIPT_DIR finds them regardless of CWD). Does
#   NOT modify run-track-a.sh.

set -euo pipefail

if [ "${AUTOPILOT_ROLE:-}" = worker ] && [ "${AUTOPILOT_ALLOW_NESTED:-}" != 1 ]; then
  echo "ERROR: nested autopilot run refused (AUTOPILOT_ROLE=worker)" >&2
  exit 2
fi

# ── self-locate (macOS-safe; not readlink -f) ────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RUN_TRACK_A="$SCRIPT_DIR/run-track-a.sh"
FINISH_CHANGE="$SCRIPT_DIR/finish-change.sh"
DISPATCH="$SCRIPT_DIR/dispatch.sh"
PARSE="$SCRIPT_DIR/parse-status.sh"

for dep in "$RUN_TRACK_A" "$DISPATCH" "$PARSE"; do
  [ -f "$dep" ] || { echo "ERROR: missing sibling script: $dep" >&2; exit 1; }
done

# ── defaults / args ──────────────────────────────────────────────────────────
CHANGE_DIR=""
CWD="$PWD"
TASKS_FILE=""
RESUME=false
MAX_ROUNDS=""
IMPL_MODEL=""
REVIEW_MODEL=""
FINISH_MODEL="${AUTOPILOT_FINISH_MODEL:-Performance}"
EVOLVE_MODEL="${AUTOPILOT_EVOLVE_MODEL:-Ultimate}"
SKIP_FINISH=false
SKIP_EVOLVE=false
SKIP_LOOP=false
DRY_RUN=false

usage() { sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --change-dir) CHANGE_DIR="$2"; shift 2;;
    --cwd) CWD="$2"; shift 2;;
    --tasks) TASKS_FILE="$2"; shift 2;;
    --resume) RESUME=true; shift;;
    --max-rounds) MAX_ROUNDS="$2"; shift 2;;
    --impl-model) IMPL_MODEL="$2"; shift 2;;
    --review-model) REVIEW_MODEL="$2"; shift 2;;
    --finish-model) FINISH_MODEL="$2"; shift 2;;
    --evolve-model) EVOLVE_MODEL="$2"; shift 2;;
    --skip-finish) SKIP_FINISH=true; shift;;
    --skip-evolve) SKIP_EVOLVE=true; shift;;
    --skip-loop) SKIP_LOOP=true; shift;;
    --dry-run) DRY_RUN=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1 (use --help)" >&2; exit 1;;
  esac
done

[ -n "$CHANGE_DIR" ] || { echo "ERROR: --change-dir is required (use --help)" >&2; exit 1; }
[ -d "$CWD" ] || { echo "ERROR: --cwd not a directory: $CWD" >&2; exit 1; }

trap 'echo "[run-autopilot] interrupted" >&2; exit 130' INT TERM

# ── logging (LOG_DIR only when actually running) ─────────────────────────────
# Logs live under TMPDIR (NOT inside the project), matching run-track-a.sh, so
# the orchestrator's own artifacts never get swept into the consumer
# project's commits by `git add -A`.
LOG_DIR=""
if ! $DRY_RUN; then
  LOG_DIR="${TMPDIR:-/tmp}/autopilot-run-autopilot/$(basename "$CHANGE_DIR")-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$LOG_DIR"
fi
log() {
  local line="[$(date +%H:%M:%S)] $*"
  if [ -n "$LOG_DIR" ]; then echo "$line" | tee -a "$LOG_DIR/run-autopilot.log"; else echo "$line"; fi
}

# ── worker dispatch (captures rc without aborting under set -e) ──────────────
dispatch_worker() {
  local stage="$1" model="$2" pfile="$3" instr="$4" outlog="$5" rc
  set +e
  AUTOPILOT_PLATFORM="${AUTOPILOT_PLATFORM:-qoder}" AUTOPILOT_STAGE="$stage" \
    AUTOPILOT_ATTEMPT="${AUTOPILOT_ATTEMPT:-1}" AUTOPILOT_REASONING_EFFORT="${AUTOPILOT_REASONING_EFFORT:-}" \
    "$DISPATCH" --model "$model" --cwd "$CWD" --prompt-file "$pfile" --instruction "$instr" 2>&1 | tee "$outlog"
  rc=${PIPESTATUS[0]}
  set -e
  [ "$rc" -eq 0 ] || log "  WARN: dispatch exit=$rc (see $outlog)"
  return 0
}

# 工作树指纹（与 run-track-a.sh 同语义）：区分“真的什么都没做”与“已经动过盘”。
worktree_signature() {
  ( cd "$CWD" 2>/dev/null || exit 0
    git rev-parse --git-dir >/dev/null 2>&1 || exit 0
    git status --porcelain 2>/dev/null
    git diff HEAD 2>/dev/null ) | cksum 2>/dev/null || true
}

# ── 静默阶段的有界重试（与 run-track-a.sh 同一套阶梯）────────────────────
# 为何必需：本脚本原来每个阶段只 dispatch 一次，而静默回合（模型把整个回合收在
# thinking 里、stdout 零字节）实测发生率不低——真实跑一次就碰上 finish 静默，于是
# 整条无人值守流水线在 loop 全部成功后死在 finish，而日志只说 “BLOCKED (status=UNKNOWN)”，
# 看不出是“worker 一字未说”还是“worker 拒绝了”。
# 安全红线：finish 会 merge/归档、evolve 会写知识库，都不幂等，所以只在“工作树指纹
# 未变”（真的什么都没做）时重试；一旦改过盘就立即停下交给人，绝不在半成品上重跑。
# 设完后置：STAGE_STATUS 为解析出的状态，STAGE_SILENT_DIRTY 标记是否属于“静默但已改盘”。
dispatch_stage_with_retry() {
  local stage="$1" model="$2" pfile="$3" instr="$4" outlog="$5"
  local cap="${AUTOPILOT_SILENT_RETRIES:-5}"
  local switch_after="${AUTOPILOT_SILENT_SWITCH_AFTER:-2}"
  local fallback_model="${AUTOPILOT_SILENT_FALLBACK_MODEL-Performance}"
  local silent_effort="${AUTOPILOT_SILENT_EFFORT-low}"
  local attempt=1 active_model="$model" effort="" switched=false sig_before sig_after
  case "$cap" in ''|*[!0-9]*) cap=5 ;; esac
  [ "$cap" -ge 1 ] || cap=1
  STAGE_STATUS=UNKNOWN
  STAGE_SILENT_DIRTY=false
  while [ "$attempt" -le "$cap" ]; do
    sig_before="$(worktree_signature)"
    AUTOPILOT_ATTEMPT="$attempt" AUTOPILOT_REASONING_EFFORT="$effort" \
      dispatch_worker "$stage" "$active_model" "$pfile" "$instr" "$outlog"
    STAGE_STATUS="$("$PARSE" "$outlog" 2>/dev/null || echo UNKNOWN)"
    if [ "$STAGE_STATUS" != UNKNOWN ]; then return 0; fi
    sig_after="$(worktree_signature)"
    if [ "$sig_before" != "$sig_after" ]; then
      STAGE_SILENT_DIRTY=true
      log "  $stage: no verdict line, but the worktree changed → refusing to retry on top of its own edits"
      return 0
    fi
    if [ "$attempt" -ge "$cap" ]; then
      log "  $stage: silent worker output (attempt $attempt/$cap) → exhausted"
      return 0
    fi
    log "  $stage: silent worker output (attempt $attempt/$cap) → retry immediately (worktree untouched)"
    if [ -n "$silent_effort" ] && [ "$effort" != "$silent_effort" ]; then
      log "    → lowering reasoning effort to '$silent_effort' for the remaining attempts"
      effort="$silent_effort"
    fi
    if ! $switched && [ -n "$fallback_model" ] && [ "$attempt" -ge "$switch_after" ] \
        && [ "$fallback_model" != "$active_model" ]; then
      log "    → $active_model stayed silent ${attempt}x; switching to $fallback_model"
      active_model="$fallback_model"
      switched=true
    fi
    attempt=$(( attempt + 1 ))
  done
  return 0
}

# 阶段停机时的准确文案：“静默”与“worker 明确报 BLOCKED”必须可区分，否则排障会跑偏。
log_stage_stop() {
  local stage="$1" status="$2"
  if [ "$status" = UNKNOWN ] && $STAGE_SILENT_DIRTY; then
    log "  $stage BLOCKED (silent worker, worktree already modified) → stop (fail-closed)"
    echo "hint: NOT a refusal — the worker printed no verdict but changed files; inspect 'git status' in $CWD first."
  elif [ "$status" = UNKNOWN ]; then
    log "  $stage BLOCKED (worker stayed silent through every attempt) → stop (fail-closed)"
    echo "hint: NOT a refusal and NOT a transport failure — nothing was written, so rerunning is safe."
  else
    log "  $stage BLOCKED (status=$status) → stop (fail-closed)"
  fi
}

# ── prompt builders ──────────────────────────────────────────────────────────
build_finish_prompt() {
  local out="$1"
  {
    echo "你是一个 autopilot-finish 工人（Track A worker，经 dispatch.sh 调度）。"
    echo; echo "## 项目信息"
    echo "- 工作目录（--cwd）：$CWD"
    echo "- 变更目录（--change-dir）：$CHANGE_DIR"
    echo; echo "## 你的任务"
    echo "针对上述 --change-dir / --cwd，读取并执行 \`$SCRIPT_DIR/../skills/autopilot-finish/SKILL.md\` 中定义的完整流程（分支完成与合并）。"
    echo; echo "## 报告格式（回复末尾必须输出）"
    echo "- 一行：\`FINISH_STATUS=DONE\` 或 \`FINISH_STATUS=BLOCKED\`（BLOCKED 需说明原因）"
  } > "$out"
}
build_evolve_prompt() {
  local out="$1"
  # 单产物、自包含：不再说“读 SKILL.md 并执行完整三层流程”。实测教训：多步重任务是
  # headless 静默/截断的重灾区（finish 就是这么死的，7/7 未给结论），而沉淀知识的
  # 最小有效产物就是一份 raw 笔记。wiki 编译、全局升迁等后续步骤留给交互档或下一轮，
  # 不在无人值守路径上用一个可能静默的 worker 换取它们。
  {
    echo "你是一个知识沉淀工人（标识: autopilot-evolve，经 dispatch.sh 调度）。"
    echo; echo "## 上下文"
    echo "- 工作目录：$CWD"
    echo "- 本次变更名：$(basename "$CHANGE_DIR")"
    echo "- 变更产物已归档到 \`autopilot/archive/\` 下对应日期目录（含 spec.md / tasks.md / summary.md）。"
    echo "- 知识库约束：存在 \`autopilot/knowledge/SCHEMA.md\` 则先读它，raw/ 是 append-only。"
    echo; echo "## 你只需交付一份产物"
    echo "新建文件 \`autopilot/knowledge/raw/$(date +%Y%m%d)-$(basename "$CHANGE_DIR").md\`，包含："
    echo "1. YAML front-matter：\`created\`（今天日期）、\`source: evolve/completed-change\`。"
    echo "2. \`## Problem\`：本次变更要解决什么（从归档的 spec.md 提炼）。"
    echo "3. \`## Solution\`：实际怎么做的（从归档的 tasks.md / summary.md 与代码提炼）。"
    echo "4. \`## Lessons\`：可复用的经验或踩坑；无则写「本次无新增经验」，不凭空编。"
    echo "只写这一个文件，不要改代码、不要碰 git。"
    echo; echo "## 报告格式（回复末尾必须输出）"
    echo "- 一行：\`EVOLVE_STATUS=DONE\` 或 \`EVOLVE_STATUS=BLOCKED\`（BLOCKED 需说明原因）"
  } > "$out"
}

# ── main ─────────────────────────────────────────────────────────────────────

# Stage 1: loop (delegated verbatim to run-track-a.sh; passthrough its args).
LOOP_ARGS=( --change-dir "$CHANGE_DIR" --cwd "$CWD" )
[ -n "$TASKS_FILE" ] && LOOP_ARGS+=( --tasks "$TASKS_FILE" )
[ -n "$MAX_ROUNDS" ] && LOOP_ARGS+=( --max-rounds "$MAX_ROUNDS" )
[ -n "$IMPL_MODEL" ] && LOOP_ARGS+=( --impl-model "$IMPL_MODEL" )
[ -n "$REVIEW_MODEL" ] && LOOP_ARGS+=( --review-model "$REVIEW_MODEL" )
$RESUME && LOOP_ARGS+=( --resume )
$DRY_RUN && LOOP_ARGS+=( --dry-run )

log "run-autopilot | change=$CHANGE_DIR | cwd=$CWD | finish=$FINISH_MODEL evolve=$EVOLVE_MODEL | skip-finish=$SKIP_FINISH skip-evolve=$SKIP_EVOLVE dry-run=$DRY_RUN"

# 可重跑性：finish 成功后 change 目录已被搬进 archive，此时再跑本入口会在 loop 就
# 直接失败（读不到 tasks.md）——于是“只有 evolve 挂了”变成无法从入口恢复，只能手工
# 拼命令。这里按证据自动识别：变更目录不在 changes/ 且 archive/ 里有同名归档，则 loop
# 与 finish 已经完成过，跳过它们直接跑 evolve。要求“归档确实存在”而不是“目录不在”，
# 是为了不把 --change-dir 拼写错静默当成“已完成”。
if [ ! -d "$CHANGE_DIR" ] && ! $SKIP_LOOP; then
  CHANGE_NAME="$(basename "$CHANGE_DIR")"
  ARCHIVED="$(find "$CWD/autopilot/archive" -maxdepth 4 -type d -name "*-$CHANGE_NAME" 2>/dev/null | head -1)"
  if [ -n "$ARCHIVED" ]; then
    SKIP_LOOP=true
    $SKIP_FINISH || SKIP_FINISH=true
    log "change already archived ($ARCHIVED) → loop + finish already done; resuming at evolve"
  fi
fi
$DRY_RUN || log "logs → $LOG_DIR"

if $SKIP_LOOP; then
  log "── stage 1/3: loop (skipped) ──"
else
  log "── stage 1/3: loop (run-track-a.sh) ──"
  set +e
  bash "$RUN_TRACK_A" "${LOOP_ARGS[@]}"
  LOOP_RC=$?
  set -e
  [ "$LOOP_RC" -eq 0 ] || { log "loop exited rc=$LOOP_RC → stop (fail-closed, not proceeding to finish/evolve)"; exit "$LOOP_RC"; }
  log "  loop OK"
fi

if $DRY_RUN; then
  log "would: loop → finish → evolve"
  exit 0
fi

# Stage 2: finish.
if $SKIP_FINISH; then
  log "── stage 2/3: finish (skipped) ──"
else
  log "── stage 2/3: finish ──"
  # 默认走确定性 finish（C10）：merge / 归档 / 提交 / 清哨兵全是机械步骤，交给 agent
  # 只会把无人值守流水线变成掷硬币：实测 finish worker 7/7 次未给出结论（只吐一句
  # 前言就停、一个工具未执行），loop 全部成功后却死在 stage 2/3。
  # 设 AUTOPILOT_FINISH_MODE=worker 可恢复旧的 agent 路径（需要 SKILL.md 里的 PR/CI 语义时）。
  if [ "${AUTOPILOT_FINISH_MODE:-deterministic}" = deterministic ] && [ -f "$FINISH_CHANGE" ]; then
    log "  finish → deterministic ($(basename "$FINISH_CHANGE"))"
    set +e
    bash "$FINISH_CHANGE" --change-dir "$CHANGE_DIR" --cwd "$CWD" 2>&1 | tee "$LOG_DIR/finish.log"
    FINISH_RC=${PIPESTATUS[0]}
    set -e
    FINISH_ST="$("$PARSE" "$LOG_DIR/finish.log" 2>/dev/null || echo UNKNOWN)"
    if [ "$FINISH_RC" -ne 0 ] || { [ "$FINISH_ST" != DONE ] && [ "$FINISH_ST" != DONE_WITH_CONCERNS ]; }; then
      log "  finish BLOCKED (rc=$FINISH_RC status=$FINISH_ST) → stop (fail-closed, not proceeding to evolve)"
      exit 2
    fi
    log "  finish OK"
  else
  build_finish_prompt "$LOG_DIR/finish-prompt.md"
  log "  finish → dispatch($FINISH_MODEL)"
  dispatch_stage_with_retry "finish" "$FINISH_MODEL" "$LOG_DIR/finish-prompt.md" \
    "针对本次 autopilot-finish 任务（标识: autopilot-finish）：按提示词要求读取 SKILL.md 并执行完整流程；回复末尾输出一行 'FINISH_STATUS=DONE'（做不了则 'FINISH_STATUS=BLOCKED' 并说明原因）。" \
    "$LOG_DIR/finish.log"
  FINISH_ST="$STAGE_STATUS"
  if [ "$FINISH_ST" != "DONE" ] && [ "$FINISH_ST" != "DONE_WITH_CONCERNS" ]; then
    log_stage_stop finish "$FINISH_ST"
    log "  → not proceeding to evolve"; exit 2
  fi
  log "  finish OK"
  fi
fi

# Stage 3: evolve.
if $SKIP_EVOLVE; then
  log "── stage 3/3: evolve (skipped) ──"
else
  log "── stage 3/3: evolve ──"
  build_evolve_prompt "$LOG_DIR/evolve-prompt.md"
  log "  evolve → dispatch($EVOLVE_MODEL)"
  # 产物优先于自述：evolve 的地面真相是“知识库里多了东西”，不是聊天里那行标记。
  # 实测碰到过：worker 已经写出合规的 raw/<date>-<name>.md（含 front-matter），却未输出
  # EVOLVE_STATUS=DONE，于是整条流水线在最后一步被判失败、而知识已经沉淀完了。
  KNOWLEDGE_DIR="$CWD/autopilot/knowledge"
  knowledge_signature() {
    ( [ -d "$KNOWLEDGE_DIR" ] || exit 0
      find "$KNOWLEDGE_DIR" -type f -name '*.md' -exec wc -c {} \; 2>/dev/null | sort ) | cksum 2>/dev/null || true
  }
  KNOWLEDGE_BEFORE="$(knowledge_signature)"
  dispatch_stage_with_retry "evolve" "$EVOLVE_MODEL" "$LOG_DIR/evolve-prompt.md" \
    "针对本次 autopilot-evolve 任务（标识: autopilot-evolve）：按提示词要求读取 SKILL.md 并执行完整流程；回复末尾输出一行 'EVOLVE_STATUS=DONE'（做不了则 'EVOLVE_STATUS=BLOCKED' 并说明原因）。" \
    "$LOG_DIR/evolve.log"
  EVOLVE_ST="$STAGE_STATUS"
  if [ "$EVOLVE_ST" = UNKNOWN ] && [ "$KNOWLEDGE_BEFORE" != "$(knowledge_signature)" ]; then
    EVOLVE_ST=DONE_WITH_CONCERNS
    log "  evolve: no verdict line, but the knowledge base gained content → accepting on artifact evidence"
  fi
  if [ "$EVOLVE_ST" != "DONE" ] && [ "$EVOLVE_ST" != "DONE_WITH_CONCERNS" ]; then
    log_stage_stop evolve "$EVOLVE_ST"; exit 2
  fi
  # 沉淀产物必须落入版本控制，否则永久留脏（下一轮 finish 的工作树清洁门禁会直接被它卡住）。
  if [ -n "$(cd "$CWD" && git status --porcelain -- autopilot/knowledge 2>/dev/null || true)" ]; then
    if ( cd "$CWD" && git add -A -- autopilot/knowledge >/dev/null 2>&1 && git commit -m "docs(knowledge): evolve $(basename "$CHANGE_DIR")" >/dev/null 2>&1 ); then
      log "  evolve: committed the knowledge artifacts"
    else
      log "  WARN: evolve wrote knowledge files but committing them failed — left in the worktree"
    fi
  fi
  log "  evolve OK"
fi

rm -f "$CWD/autopilot/.run-active" 2>/dev/null || true
log "ALL STAGES DONE ✅ (run-autopilot complete)"
exit 0
