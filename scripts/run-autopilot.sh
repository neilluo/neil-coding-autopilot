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

# ── self-locate (macOS-safe; not readlink -f) ────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RUN_TRACK_A="$SCRIPT_DIR/run-track-a.sh"
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
DRY_RUN=false

usage() { sed -n '2,44p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

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
  local model="$1" pfile="$2" instr="$3" outlog="$4" rc
  set +e
  AUTOPILOT_PLATFORM="${AUTOPILOT_PLATFORM:-qoder}" \
    "$DISPATCH" --model "$model" --cwd "$CWD" --prompt-file "$pfile" --instruction "$instr" 2>&1 | tee "$outlog"
  rc=${PIPESTATUS[0]}
  set -e
  [ "$rc" -eq 0 ] || log "  WARN: dispatch exit=$rc (see $outlog)"
  return 0
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
  {
    echo "你是一个 autopilot-evolve 工人（Track A worker，经 dispatch.sh 调度）。"
    echo; echo "## 项目信息"
    echo "- 工作目录（--cwd）：$CWD"
    echo "- 变更目录（--change-dir）：$CHANGE_DIR"
    echo; echo "## 你的任务"
    echo "针对上述 --change-dir / --cwd，读取并执行 \`$SCRIPT_DIR/../skills/autopilot-evolve/SKILL.md\` 中定义的完整流程（知识沉淀与自进化）。"
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
$DRY_RUN || log "logs → $LOG_DIR"

log "── stage 1/3: loop (run-track-a.sh) ──"
set +e
bash "$RUN_TRACK_A" "${LOOP_ARGS[@]}"
LOOP_RC=$?
set -e
[ "$LOOP_RC" -eq 0 ] || { log "loop exited rc=$LOOP_RC → stop (fail-closed, not proceeding to finish/evolve)"; exit "$LOOP_RC"; }
log "  loop OK"

if $DRY_RUN; then
  log "would: loop → finish → evolve"
  exit 0
fi

# Stage 2: finish.
if $SKIP_FINISH; then
  log "── stage 2/3: finish (skipped) ──"
else
  log "── stage 2/3: finish ──"
  build_finish_prompt "$LOG_DIR/finish-prompt.md"
  log "  finish → dispatch($FINISH_MODEL)"
  dispatch_worker "$FINISH_MODEL" "$LOG_DIR/finish-prompt.md" \
    "针对本次 autopilot-finish 任务（标识: autopilot-finish）：按提示词要求读取 SKILL.md 并执行完整流程；回复末尾输出一行 'FINISH_STATUS=DONE'（做不了则 'FINISH_STATUS=BLOCKED' 并说明原因）。" \
    "$LOG_DIR/finish.log"
  FINISH_ST="$("$PARSE" "$LOG_DIR/finish.log")"
  if [ "$FINISH_ST" != "DONE" ] && [ "$FINISH_ST" != "DONE_WITH_CONCERNS" ]; then
    log "  finish BLOCKED (status=$FINISH_ST) → stop (fail-closed, not proceeding to evolve)"; exit 2
  fi
  log "  finish OK"
fi

# Stage 3: evolve.
if $SKIP_EVOLVE; then
  log "── stage 3/3: evolve (skipped) ──"
else
  log "── stage 3/3: evolve ──"
  build_evolve_prompt "$LOG_DIR/evolve-prompt.md"
  log "  evolve → dispatch($EVOLVE_MODEL)"
  dispatch_worker "$EVOLVE_MODEL" "$LOG_DIR/evolve-prompt.md" \
    "针对本次 autopilot-evolve 任务（标识: autopilot-evolve）：按提示词要求读取 SKILL.md 并执行完整流程；回复末尾输出一行 'EVOLVE_STATUS=DONE'（做不了则 'EVOLVE_STATUS=BLOCKED' 并说明原因）。" \
    "$LOG_DIR/evolve.log"
  EVOLVE_ST="$("$PARSE" "$LOG_DIR/evolve.log")"
  if [ "$EVOLVE_ST" != "DONE" ] && [ "$EVOLVE_ST" != "DONE_WITH_CONCERNS" ]; then
    log "  evolve BLOCKED (status=$EVOLVE_ST) → stop (fail-closed)"; exit 2
  fi
  log "  evolve OK"
fi

rm -f "$CWD/autopilot/.run-active" 2>/dev/null || true
log "ALL STAGES DONE ✅ (run-autopilot complete)"
exit 0
