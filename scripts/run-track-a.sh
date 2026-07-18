#!/usr/bin/env bash
# run-track-a.sh — Track A (batch/headless) orchestrator for neil-coding-autopilot.
#
# WHAT: A deterministic bash driver loop. Reads a tasks.md and, for each PENDING
#   task, runs the inner loop  implement → verify → review → (fix)* → commit,
#   spawning a FRESH agent worker per step via dispatch.sh. The orchestrator is
#   THIS script (near-zero context, deterministic); each worker is a disposable
#   fresh-context subprocess. This is the ONLY way to actually run Track A —
#   interactive sessions are Track B by design and never spawn workers.
#
# WHY BASH (not an LLM orchestrator): keeps the orchestrator context clean and the
#   run deterministic / verifiable / resumable — matches the Ralph Loop pattern.
#   An LLM orchestrator would just relocate context-rot onto itself.
#
# USAGE:
#   scripts/run-track-a.sh --change-dir autopilot/changes/<feat> --cwd <project-root> [opts]
#
# OPTIONS:
#   --change-dir DIR   Change dir holding tasks.md (required).
#   --cwd DIR          Project root where verify/commit run (default: $PWD).
#   --tasks FILE       tasks.md path (default: <change-dir>/tasks.md).
#   --impl-model M     implementer/fixer model (default: $AUTOPILOT_IMPLEMENTER_MODEL or Performance).
#   --review-model M   reviewer model    (default: $AUTOPILOT_REVIEWER_MODEL or Ultimate).
#   --max-rounds N     max review→fix rounds per task (default: 3).
#   --resume           skip tasks already marked DONE (default behaviour anyway).
#   --dry-run          parse & print the plan; do NOT spawn workers or commit.
#   -h | --help        show usage.
#
# EXIT CODES (semantic, CI-friendly):
#   0    all tasks DONE
#   1    usage / setup error
#   2    a task BLOCKED (worker blocked, or rounds exhausted) — fail-closed, stopped
#   130  interrupted
#
# PORTABILITY: macOS-safe (targets bash 3.2; no associative arrays / mapfile;
#   awk parsing; no `grep -P`; self-locates via `pwd -P`). Delegates to sibling
#   dispatch.sh / parse-status.sh / task-state.sh (path resolution: this script
#   lives with them in the plugin, so SCRIPT_DIR finds them regardless of CWD).

set -euo pipefail

# ── self-locate (macOS-safe; not readlink -f) ────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DISPATCH="$SCRIPT_DIR/dispatch.sh"
PARSE="$SCRIPT_DIR/parse-status.sh"
TASK_STATE="$SCRIPT_DIR/task-state.sh"
TELEMETRY="$SCRIPT_DIR/telemetry.sh"
BT='`'   # backtick, for awk field-splitting on `code` spans

for dep in "$DISPATCH" "$PARSE" "$TASK_STATE" "$TELEMETRY"; do
  [ -f "$dep" ] || { echo "ERROR: missing sibling script: $dep" >&2; exit 1; }
done

# shellcheck source=telemetry.sh
. "$TELEMETRY"

# ── defaults / args ──────────────────────────────────────────────────────────
CHANGE_DIR=""
CWD="$PWD"
TASKS_FILE=""
IMPL_MODEL="${AUTOPILOT_IMPLEMENTER_MODEL:-Performance}"
REVIEW_MODEL="${AUTOPILOT_REVIEWER_MODEL:-Ultimate}"
MAX_ROUNDS=3
RESUME=false
DRY_RUN=false

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --change-dir) CHANGE_DIR="$2"; shift 2;;
    --cwd) CWD="$2"; shift 2;;
    --tasks) TASKS_FILE="$2"; shift 2;;
    --impl-model) IMPL_MODEL="$2"; shift 2;;
    --review-model) REVIEW_MODEL="$2"; shift 2;;
    --max-rounds) MAX_ROUNDS="$2"; shift 2;;
    --resume) RESUME=true; shift;;
    --dry-run) DRY_RUN=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1 (use --help)" >&2; exit 1;;
  esac
done

[ -n "$CHANGE_DIR" ] || { echo "ERROR: --change-dir is required (use --help)" >&2; exit 1; }
[ -n "$TASKS_FILE" ] || TASKS_FILE="$CHANGE_DIR/tasks.md"
[ -f "$TASKS_FILE" ] || { echo "ERROR: tasks file not found: $TASKS_FILE" >&2; exit 1; }
[ -d "$CWD" ] || { echo "ERROR: --cwd not a directory: $CWD" >&2; exit 1; }
case "$MAX_ROUNDS" in ''|*[!0-9]*) echo "ERROR: --max-rounds must be a positive integer" >&2; exit 1;; esac
[ "$MAX_ROUNDS" -ge 1 ] || { echo "ERROR: --max-rounds must be >= 1" >&2; exit 1; }

trap 'echo "[run-track-a] interrupted" >&2; exit 130' INT TERM

# ── logging (LOG_DIR only when actually running) ─────────────────────────────
# Logs live under TMPDIR (NOT inside the project) so the driver's own artifacts
# never get swept into the consumer project's commits by `git add -A`.
LOG_DIR=""
if ! $DRY_RUN; then
  LOG_DIR="${TMPDIR:-/tmp}/autopilot-track-a/$(basename "$CHANGE_DIR")-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$LOG_DIR"
fi
log() {
  local line="[$(date +%H:%M:%S)] $*"
  if [ -n "$LOG_DIR" ]; then echo "$line" | tee -a "$LOG_DIR/driver.log"; else echo "$line"; fi
}

# ── telemetry: run-level state (init BEFORE installing the EXIT trap below) ──
RUN_ID=""
[ -n "$LOG_DIR" ] && RUN_ID="$(basename "$LOG_DIR")"
TASKS_DONE=0
TASKS_BLOCKED=0
RUN_START_TS="$(date +%s)"

# copy_artifact <src-log-file>: best-effort copy of a review/BLOCKED-step log
# into $LOG_ROOT/runs/<run_id>/ for next-day analysis. Fail-safe: unwritable
# LOG_ROOT or missing source is silently skipped (mirrors telemetry.sh style).
copy_artifact() {
  local src="${1:-}" root="" dest=""
  {
    if [ -n "${RUN_ID:-}" ] && [ -f "$src" ]; then
      root="$(telemetry_log_root)"
      if [ -n "$root" ]; then
        dest="$root/runs/$RUN_ID"
        mkdir -p "$dest" 2>/dev/null && cp "$src" "$dest/" 2>/dev/null
      fi
    fi
  } 2>/dev/null || true
  return 0
}

# ── telemetry: run event on EXIT (independent trap; INT/TERM trap above stays
#    as-is so its own `exit 130` behaviour is preserved and simply flows into
#    this EXIT trap too, which is how the "interrupted" outcome gets recorded).
_emit_run_event_on_exit() {
  local rc=$?
  {
    if [ -n "${RUN_ID:-}" ]; then
      local outcome="complete" dur=0
      if [ "$rc" -eq 130 ]; then
        outcome="interrupted"
      elif [ "${TASKS_BLOCKED:-0}" -gt 0 ] || [ "$rc" -ne 0 ]; then
        outcome="blocked"
      fi
      dur=$(( $(date +%s) - ${RUN_START_TS:-$(date +%s)} ))
      telemetry_emit_run "$RUN_ID" "$(basename "${CHANGE_DIR:-}")" "$outcome" "$dur"
    fi
  } 2>/dev/null || true
}
trap '_emit_run_event_on_exit' EXIT

# ── tasks.md parsing helpers (bash-3.2 / BSD-tool safe) ──────────────────────
task_block() {  # print the markdown block for "## Task N:" up to next task or ---
  awk -v n="$1" '
    $0 ~ ("^## Task " n ":") { inblk=1; print; next }
    inblk && ($0 ~ "^## Task [0-9]+:" || $0 ~ "^---$") { exit }
    inblk { print }
  ' "$TASKS_FILE"
}
task_title() { grep -E "^## Task $1:" "$TASKS_FILE" | head -1 | sed -E "s/^## Task $1:[[:space:]]*//"; }
task_status() {
  task_block "$1" | grep -iE '\*\*status\*\*:' | head -1 \
    | grep -ioE '(DONE_WITH_CONCERNS|DONE|PENDING|IN_PROGRESS|BLOCKED|NEEDS_CONTEXT)' | head -1 \
    | tr '[:lower:]' '[:upper:]' || true
}
task_verify() {  # per-task **Verify**: `cmd`; fall back to global verify
  local v
  v="$(task_block "$1" | grep -iE '\*\*verify\*\*:' | head -1 | awk -F"$BT" 'NF>=3 {print $2; exit}' || true)"
  if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$GLOBAL_VERIFY"; fi
}

# ── worker dispatch (captures rc without aborting under set -e) ───────────────
# `stage` is passed as command-level env (not exported) so it never leaks
# ("sticky-export") into a later dispatch call that forgot to set it.
dispatch_worker() {
  local stage="$1" model="$2" pfile="$3" instr="$4" outlog="$5" rc
  set +e
  AUTOPILOT_PLATFORM="${AUTOPILOT_PLATFORM:-qoder}" \
    AUTOPILOT_STAGE="$stage" AUTOPILOT_RUN_ID="${RUN_ID:-}" \
    "$DISPATCH" --model "$model" --cwd "$CWD" --prompt-file "$pfile" --instruction "$instr" 2>&1 | tee "$outlog"
  rc=${PIPESTATUS[0]}
  set -e
  [ "$rc" -eq 0 ] || log "  WARN: dispatch exit=$rc (see $outlog)"
  return 0
}

# ── prompt builders ──────────────────────────────────────────────────────────
build_impl_prompt() {
  local n="$1" out="$2"
  {
    echo "你是一个开发工人，负责实现一个具体的开发任务（Track A worker，经 dispatch.sh 调度）。"
    echo; echo "## 项目信息"
    echo "- 工作目录：$CWD"
    echo "- 验证命令：$(task_verify "$n")"
    echo; echo "## 你的任务（来自 tasks.md）"; echo
    task_block "$n"
    echo; echo "## 代码规范"
    echo "- 遵循被开发项目自身规范：动手前读 AGENTS.md / autopilot/knowledge/SCHEMA.md / wiki/guides/*（存在才读）。"
    echo "- 不引入 Task 描述外的功能；错误/异常不静默吞。"
    echo; echo "## 报告格式（回复末尾必须输出）"
    echo "- **Status:** DONE | BLOCKED"
    echo "- **Files changed:** [列表]"
  } > "$out"
}
build_fix_prompt() {
  local n="$1" fb="$2" out="$3"
  {
    echo "你是一个开发工人，负责修复上一轮遗留的问题（Track A fixer，经 dispatch.sh 调度）。"
    echo; echo "## 项目信息"
    echo "- 工作目录：$CWD"
    echo "- 验证命令：$(task_verify "$n")"
    echo; echo "## 原始任务"; echo
    task_block "$n"
    echo; echo "## 上一轮的问题（验证失败输出 / CR 反馈，节选）"; echo '```'
    tail -c 4000 "$fb" 2>/dev/null || true
    echo '```'
    echo; echo "## 执行要求"
    echo "- 只修上述问题；改完重跑验证命令确认通过；不引入新功能。"
    echo; echo "## 报告格式（回复末尾必须输出）"
    echo "- **Status:** DONE | BLOCKED"
  } > "$out"
}
build_review_prompt() {
  local files="$1" out="$2"
  {
    echo "你是一个代码审查专家，对本 Task 的代码变更做严格审查（Track A reviewer，经 dispatch.sh 调度）。"
    echo; echo "## 变更文件列表（请逐一读取完整内容再评审）"; echo
    cat "$files"
    echo; echo "## 审查维度"
    echo "- 通用：安全（注入/硬编码密钥）、逻辑正确性（空值/边界/资源泄漏/吞错）、健壮性（超时/兜底/失败日志）、可维护性。"
    echo "- 项目特定：读 AGENTS.md / autopilot/knowledge/SCHEMA.md / wiki/guides/*（存在才读），把其中强制规则当 Major 检查项。"
    echo; echo "## 结论（回复末尾必须输出其一）"
    echo "REVIEW_PASS   # 无 CRITICAL/MAJOR"
    echo "REVIEW_FAIL   # 有 CRITICAL/MAJOR（并列出问题 + 文件:行号）"
  } > "$out"
}
parse_review() { grep -ioE 'REVIEW_(PASS|FAIL)' "$1" 2>/dev/null | tail -1 | tr '[:lower:]' '[:upper:]' || true; }

# ── per-task inner loop ──────────────────────────────────────────────────────
run_task() {
  local n="$1" title status verify round=0 passed=0 st rv verify_status committed
  title="$(task_title "$n")"; status="$(task_status "$n")"; [ -n "$status" ] || status="PENDING"
  verify="$(task_verify "$n")"

  if [ "$status" = "DONE" ]; then log "Task $n [$title]: already DONE → skip"; return 0; fi

  if $DRY_RUN; then
    log "DRY-RUN Task $n [$title] status=$status"
    log "    verify: ${verify:-<none>}"
    log "    would: implement($IMPL_MODEL) → verify → review($REVIEW_MODEL) → (fix ≤$MAX_ROUNDS) → commit"
    return 0
  fi

  log "── Task $n [$title] ──"
  "$TASK_STATE" "$TASKS_FILE" "$n" "IN_PROGRESS" 2>/dev/null || true

  # 1. implement
  build_impl_prompt "$n" "$LOG_DIR/task-$n-impl-prompt.md"
  log "  implement → dispatch($IMPL_MODEL)"
  dispatch_worker "implement" "$IMPL_MODEL" "$LOG_DIR/task-$n-impl-prompt.md" \
    "实现该 Task：读相关文件→写代码→跑验证命令；回复末尾输出一行 '**Status:** DONE'（做不了则 'BLOCKED' 并说明原因）。" \
    "$LOG_DIR/task-$n-impl.log"
  st="$("$PARSE" "$LOG_DIR/task-$n-impl.log")"
  if [ "$st" != "DONE" ] && [ "$st" != "DONE_WITH_CONCERNS" ]; then
    "$TASK_STATE" "$TASKS_FILE" "$n" "BLOCKED" 2>/dev/null || true
    copy_artifact "$LOG_DIR/task-$n-impl.log"
    TASKS_BLOCKED=$((TASKS_BLOCKED + 1))
    telemetry_emit_task "${RUN_ID:-}" "$n" "$title" "BLOCKED" 0 false
    log "  Task $n BLOCKED at implement (status=$st) → stop (fail-closed)"; exit 2
  fi

  # 2. verify → review → fix rounds (controller runs verify itself; never trust self-report)
  while [ "$round" -lt "$MAX_ROUNDS" ]; do
    round=$((round + 1))
    if [ -n "$verify" ]; then
      log "  verify (round $round): $verify"
      if ! ( cd "$CWD" && eval "$verify" ) >"$LOG_DIR/task-$n-verify-$round.log" 2>&1; then
        log "  verify FAILED (round $round) → fixer"
        verify_status="fail"
        telemetry_emit_round "${RUN_ID:-}" "$n" "$round" "$verify_status" "UNKNOWN"
        build_fix_prompt "$n" "$LOG_DIR/task-$n-verify-$round.log" "$LOG_DIR/task-$n-fix-$round-prompt.md"
        dispatch_worker "fix" "$IMPL_MODEL" "$LOG_DIR/task-$n-fix-$round-prompt.md" \
          "修复验证失败的问题→重跑验证；回复末尾输出 '**Status:** DONE'。" "$LOG_DIR/task-$n-fix-$round.log"
        continue
      fi
      verify_status="pass"
      log "  verify OK"
    else
      verify_status="skip"
      log "  (no verify command; verify gate skipped)"
    fi

    # review
    ( cd "$CWD" && git status --porcelain 2>/dev/null | cut -c4- ) > "$LOG_DIR/task-$n-files-$round.txt" || true
    [ -s "$LOG_DIR/task-$n-files-$round.txt" ] || echo "(no changed files detected)" > "$LOG_DIR/task-$n-files-$round.txt"
    build_review_prompt "$LOG_DIR/task-$n-files-$round.txt" "$LOG_DIR/task-$n-review-$round-prompt.md"
    log "  review (round $round) → dispatch($REVIEW_MODEL)"
    dispatch_worker "review" "$REVIEW_MODEL" "$LOG_DIR/task-$n-review-$round-prompt.md" \
      "审查上述变更文件（逐一读取），回复末尾输出 REVIEW_PASS 或 REVIEW_FAIL（有 CRITICAL/MAJOR 才 FAIL 并列问题）。" \
      "$LOG_DIR/task-$n-review-$round.log"
    rv="$(parse_review "$LOG_DIR/task-$n-review-$round.log")"
    copy_artifact "$LOG_DIR/task-$n-review-$round.log"
    telemetry_emit_round "${RUN_ID:-}" "$n" "$round" "$verify_status" "${rv:-UNKNOWN}"
    if [ "$rv" = "REVIEW_PASS" ]; then passed=1; log "  REVIEW_PASS"; break; fi
    log "  review = ${rv:-UNKNOWN} → fail-closed, fixer"
    build_fix_prompt "$n" "$LOG_DIR/task-$n-review-$round.log" "$LOG_DIR/task-$n-fix-$round-prompt.md"
    dispatch_worker "fix" "$IMPL_MODEL" "$LOG_DIR/task-$n-fix-$round-prompt.md" \
      "按 CR 反馈修复→重跑验证；回复末尾输出 '**Status:** DONE'。" "$LOG_DIR/task-$n-fix-$round.log"
  done

  if [ "$passed" -ne 1 ]; then
    "$TASK_STATE" "$TASKS_FILE" "$n" "BLOCKED" 2>/dev/null || true
    TASKS_BLOCKED=$((TASKS_BLOCKED + 1))
    telemetry_emit_task "${RUN_ID:-}" "$n" "$title" "BLOCKED" "$round" false
    log "  Task $n exhausted $MAX_ROUNDS rounds without REVIEW_PASS → stop (fail-closed)"; exit 2
  fi

  # 3. commit + mark DONE — distinguish "nothing to commit" from a REAL commit
  #    failure (hook reject / signing / dirty index). A real failure must NOT be
  #    mistaken for success (fail-closed).
  #    Mark DONE BEFORE staging so the status update is captured IN this task's
  #    commit; otherwise the LAST task's DONE stays uncommitted and a later
  #    `git checkout`/merge (finish) aborts on "local changes would be
  #    overwritten". A real commit failure still fails-closed by overwriting
  #    the status with BLOCKED below.
  "$TASK_STATE" "$TASKS_FILE" "$n" "DONE" 2>/dev/null || true
  ( cd "$CWD" && git add -A ) 2>/dev/null || true
  if ( cd "$CWD" && git diff --cached --quiet ); then
    committed=false
    log "  (no staged changes — nothing to commit)"
  elif ( cd "$CWD" && git commit -m "autopilot(track-a): Task $n — $title" >/dev/null 2>&1 ); then
    committed=true
    log "  committed"
  else
    "$TASK_STATE" "$TASKS_FILE" "$n" "BLOCKED" 2>/dev/null || true
    TASKS_BLOCKED=$((TASKS_BLOCKED + 1))
    telemetry_emit_task "${RUN_ID:-}" "$n" "$title" "BLOCKED" "$round" false
    log "  Task $n commit FAILED (hook/signing/index?) → stop (fail-closed)"; exit 2
  fi
  TASKS_DONE=$((TASKS_DONE + 1))
  telemetry_emit_task "${RUN_ID:-}" "$n" "$title" "DONE" "$round" "$committed"
  log "  Task $n DONE ✅"
}

# ── main ─────────────────────────────────────────────────────────────────────
GLOBAL_VERIFY="$(awk -F"$BT" '/^>/ && tolower($0) ~ /verify/ && NF>=3 {print $2; exit}' "$TASKS_FILE" 2>/dev/null || true)"
TASK_NUMS=( $(grep -oE '^## Task [0-9]+' "$TASKS_FILE" | grep -oE '[0-9]+' || true) )
[ "${#TASK_NUMS[@]}" -gt 0 ] || { echo "ERROR: no '## Task N:' entries in $TASKS_FILE" >&2; exit 1; }

log "Track A run | change=$CHANGE_DIR | cwd=$CWD | tasks=${#TASK_NUMS[@]} | impl=$IMPL_MODEL review=$REVIEW_MODEL | max-rounds=$MAX_ROUNDS resume=$RESUME dry-run=$DRY_RUN"
log "global verify: ${GLOBAL_VERIFY:-<none>}"
$DRY_RUN || log "logs → $LOG_DIR"

for n in "${TASK_NUMS[@]}"; do
  run_task "$n"
done

log "ALL TASKS DONE ✅ (Track A complete)"
exit 0
