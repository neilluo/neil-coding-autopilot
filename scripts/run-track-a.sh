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
#   --review-model M   reviewer model    (default: $AUTOPILOT_REVIEWER_MODEL or Qwen3.8-Max).
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

if [ "${AUTOPILOT_ROLE:-}" = worker ] && [ "${AUTOPILOT_ALLOW_NESTED:-}" != 1 ]; then
  echo "ERROR: nested autopilot run refused (AUTOPILOT_ROLE=worker)" >&2
  exit 2
fi

# ── self-locate (macOS-safe; not readlink -f) ────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DISPATCH="$SCRIPT_DIR/dispatch.sh"
PARSE="$SCRIPT_DIR/parse-status.sh"
PARSE_MARKERS="$SCRIPT_DIR/parse-markers.sh"
CLASSIFY="$SCRIPT_DIR/classify-outcome.sh"
TASK_STATE="$SCRIPT_DIR/task-state.sh"
TELEMETRY="$SCRIPT_DIR/telemetry.sh"
REVIEW_CONTEXT="$SCRIPT_DIR/review-context.sh"
BT='`'   # backtick, for awk field-splitting on `code` spans

for dep in "$DISPATCH" "$PARSE" "$PARSE_MARKERS" "$CLASSIFY" "$TASK_STATE" "$TELEMETRY" "$REVIEW_CONTEXT"; do
  [ -f "$dep" ] || { echo "ERROR: missing sibling script: $dep" >&2; exit 1; }
done

# shellcheck source=telemetry.sh
. "$TELEMETRY"

# ── defaults / args ──────────────────────────────────────────────────────────
CHANGE_DIR=""
CWD="$PWD"
TASKS_FILE=""
IMPL_MODEL="${AUTOPILOT_IMPLEMENTER_MODEL:-Performance}"
REVIEW_MODEL="${AUTOPILOT_REVIEWER_MODEL:-Qwen3.8-Max}"
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
CHANGE_DIR="$(cd "$CHANGE_DIR" 2>/dev/null && pwd -P || printf %s "$CHANGE_DIR")"  # absolute so review worker (cwd=$CWD) can read spec.md
[ -n "$TASKS_FILE" ] || TASKS_FILE="$CHANGE_DIR/tasks.md"
[ -f "$TASKS_FILE" ] || { echo "ERROR: tasks file not found: $TASKS_FILE" >&2; exit 1; }
[ -d "$CWD" ] || { echo "ERROR: --cwd not a directory: $CWD" >&2; exit 1; }
case "$MAX_ROUNDS" in ''|*[!0-9]*) echo "ERROR: --max-rounds must be a positive integer" >&2; exit 1;; esac
[ "$MAX_ROUNDS" -ge 1 ] || { echo "ERROR: --max-rounds must be >= 1" >&2; exit 1; }

# ── per-change atomic lock ───────────────────────────────────────────────────
LOCK_DIR="$CHANGE_DIR/.lock"
LOCK_OWNED=false
acquire_lock() {
  local holder_pid="" lock_epoch="" now age
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_OWNED=true
  else
    [ -f "$LOCK_DIR/pid" ] && holder_pid="$(sed -n '1p' "$LOCK_DIR/pid" 2>/dev/null || true)"
    [ -f "$LOCK_DIR/epoch" ] && lock_epoch="$(sed -n '1p' "$LOCK_DIR/epoch" 2>/dev/null || true)"
    now="$(date +%s)"
    case "$lock_epoch" in ''|*[!0-9]*) age=43200 ;; *) age=$(( now - lock_epoch )) ;; esac
    if [ -n "$holder_pid" ] && kill -0 "$holder_pid" 2>/dev/null && [ "$age" -lt 43200 ]; then
      echo "ERROR: Track A lock held by active PID $holder_pid" >&2
      exit 2
    fi
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
      echo "ERROR: unable to acquire Track A lock: $LOCK_DIR" >&2
      exit 2
    fi
    LOCK_OWNED=true
  fi
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  date +%s > "$LOCK_DIR/epoch"
}
release_lock() {
  local lock_pid=""
  if $LOCK_OWNED; then
    [ -f "$LOCK_DIR/pid" ] && lock_pid="$(sed -n '1p' "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [ "$lock_pid" = "$$" ]; then rm -rf "$LOCK_DIR" 2>/dev/null || true; fi
    LOCK_OWNED=false
  fi
}
acquire_lock

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

# Global state set/consumed by dispatch_worker and dispatch_with_retry
WORKER_RC=0
WORKER_OUTCOME="OK"
LAST_WORKER_LOG=""

# copy_artifact <src-log-file>: best-effort copy of a review/BLOCKED-step log
# into $LOG_ROOT/runs/<run_id>/ for next-day analysis. Fail-safe: unwritable
# LOG_ROOT or missing source is silently skipped (mirrors telemetry.sh style).
copy_artifact() {
  local src="${LAST_WORKER_LOG:-${1:-}}" root="" dest=""
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
  local rc="${1:-$?}"
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
_run_track_a_on_exit() {
  local rc=$?
  trap - EXIT
  _emit_run_event_on_exit "$rc"
  release_lock
  exit "$rc"
}
trap '_run_track_a_on_exit' EXIT

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

# ── worker dispatch ──────────────────────────────────────────────────────────
# Sets globals: WORKER_RC, WORKER_OUTCOME, AUTOPILOT_TM_FAILURE_CLASS (env for telemetry)
dispatch_worker() {
  local stage="$1" model="$2" pfile="$3" instr="$4" outlog="$5"
  set +e
  AUTOPILOT_PLATFORM="${AUTOPILOT_PLATFORM:-qoder}" \
    AUTOPILOT_STAGE="$stage" AUTOPILOT_RUN_ID="${RUN_ID:-}" \
    AUTOPILOT_ATTEMPT="${AUTOPILOT_ATTEMPT:-}" \
    "$DISPATCH" --model "$model" --cwd "$CWD" --prompt-file "$pfile" --instruction "$instr" 2>&1 | tee "$outlog"
  WORKER_RC=${PIPESTATUS[0]}
  set -e
  WORKER_OUTCOME="$("$CLASSIFY" "$WORKER_RC" "$outlog")"
  if [ "$WORKER_OUTCOME" = "OK" ]; then
    AUTOPILOT_TM_FAILURE_CLASS=""
  else
    AUTOPILOT_TM_FAILURE_CLASS="$WORKER_OUTCOME"
    [ "$WORKER_RC" -eq 0 ] || log "  WARN: dispatch exit=$WORKER_RC outcome=$WORKER_OUTCOME (see $outlog)"
  fi
  return 0
}

# ── dispatch with transport/empty retry (spec D2/D3/D4) ─────────────────────
# Usage: dispatch_with_retry <stage> <model> <prompt-file> <instruction> <base-log>
# Sets: LAST_WORKER_LOG, WORKER_RC, WORKER_OUTCOME
dispatch_with_retry() {
  local stage="$1" model="$2" pfile="$3" instr="$4" base_log="$5"
  local max_attempts="${AUTOPILOT_TRANSPORT_RETRIES:-3}"
  local backoff_base="${AUTOPILOT_RETRY_BACKOFF_S:-5}"
  local attempt=1 outlog backoff mult i

  [ "$max_attempts" -gt 0 ] || max_attempts=1
  while true; do
    outlog="${base_log%.log}-a${attempt}.log"
    LAST_WORKER_LOG="$outlog"

    AUTOPILOT_ATTEMPT="$attempt" dispatch_worker "$stage" "$model" "$pfile" "$instr" "$outlog"

    case "$WORKER_OUTCOME" in
      TRANSPORT|EMPTY)
        if [ "$attempt" -lt "$max_attempts" ]; then
          mult=1
          i=1
          while [ "$i" -lt "$attempt" ]; do
            mult=$(( mult * 2 ))
            i=$(( i + 1 ))
          done
          backoff=$(( backoff_base * mult ))
          log "  transport failure (attempt $attempt/$max_attempts) → retry in ${backoff}s"
          sleep "$backoff"
          attempt=$(( attempt + 1 ))
          continue
        fi
        log "  transport failure (attempt $attempt/$max_attempts) → exhausted"
        ;;
    esac
    break
  done
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
    echo; echo "## 递归安全禁令"
    echo "- 禁止调用任何 autopilot-* / using-neil-autopilot / neil-coding-autopilot skill"
    echo "- 禁止执行 run-track-a.sh / run-autopilot.sh / dispatch.sh"
    echo "- 只做本 Task 描述的事"
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
    echo; echo "## 递归安全禁令"
    echo "- 禁止调用任何 autopilot-* / using-neil-autopilot / neil-coding-autopilot skill"
    echo "- 禁止执行 run-track-a.sh / run-autopilot.sh / dispatch.sh"
    echo "- 只做本 Task 描述的事"
    echo; echo "## 报告格式（回复末尾必须输出）"
    echo "- **Status:** DONE | BLOCKED"
  } > "$out"
}
build_review_prompt() {
  local out="$1" n="${2:-}"
  {
    echo "你是一个代码审查专家，对本 Task 的代码变更做严格审查（Track A reviewer，经 dispatch.sh 调度）。"
    echo; echo "以下是本 Task 的完整变更（有界 diff）。**先基于 diff 评审**；若某处需要上下文，再自行打开对应文件。"; echo
    "$REVIEW_CONTEXT" --cwd "$CWD"
    echo; echo "## 审查维度"
    echo "- 通用：安全（注入/硬编码密钥）、逻辑正确性（空值/边界/资源泄漏/吞错）、健壮性（超时/兜底/失败日志）、可维护性。"
    echo "- 项目特定：读 AGENTS.md / autopilot/knowledge/SCHEMA.md / wiki/guides/*（存在才读），把其中强制规则当 Major 检查项。"
    echo "- 可观测验收（本 Task 若改动用户可观测输出——UI/CLI/API/告警/报表）：读 $CHANGE_DIR/spec.md 的「可观测验收」段 + $SCRIPT_DIR/../skills/_shared/observable-acceptance.md，核验 ① 每个改动的可观测值/态有 SSOT + 判别性蜕变关系（多源值扰动非权威源期望不同）；② 下方本 Task 块的 Verify 为确定性扰动测试（非仅编译级）且期望可追溯到 spec 的 MR；③ 标 UNVERIFIED-OBSERVABLE 者须确为无离线宿主的纯渲染层、否则免除无效。缺失/对不上/免除滥用 → MAJOR。纯内部改动（无可观测变化）跳过本维度。"
    echo; echo "## 递归安全禁令"
    echo "- 禁止调用任何 autopilot-* / using-neil-autopilot / neil-coding-autopilot skill"
    echo "- 禁止执行 run-track-a.sh / run-autopilot.sh / dispatch.sh"
    echo "- 只做本 Task 描述的事"
    echo; echo "## 本 Task 块（含 **Verify** 与可能的 UNVERIFIED-OBSERVABLE 标记，供 ②③ 交叉核验）"; echo
    [ -n "$n" ] && task_block "$n"
    echo; echo "## 结论（回复末尾必须输出其一）"
    echo "REVIEW_PASS   # 无 CRITICAL/MAJOR"
    echo "REVIEW_FAIL   # 有 CRITICAL/MAJOR（并列出问题 + 文件:行号）"
  } > "$out"
}

# Use parse-markers.sh for anchored review verdict extraction (D19)
parse_review() { "$PARSE_MARKERS" review "$1" 2>/dev/null || echo "UNKNOWN"; }

# ── per-task inner loop ──────────────────────────────────────────────────────
run_task() {
  local n="$1" title status verify round=0 passed=0 rv verify_status committed
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
  log "  implement (round 1) → dispatch($IMPL_MODEL)"
  dispatch_with_retry "implement" "$IMPL_MODEL" "$LOG_DIR/task-$n-impl-prompt.md" \
    "实现该 Task：读相关文件→写代码→跑验证命令；回复末尾输出一行 '**Status:** DONE'（做不了则 'BLOCKED' 并说明原因）。" \
    "$LOG_DIR/task-$n-impl.log"

  # Handle transport/timeout exhaustion for implement
  case "$WORKER_OUTCOME" in
    TRANSPORT|EMPTY)
      "$TASK_STATE" "$TASKS_FILE" "$n" "BLOCKED" 2>/dev/null || true
      copy_artifact
      TASKS_BLOCKED=$((TASKS_BLOCKED + 1))
      telemetry_emit_task "${RUN_ID:-}" "$n" "$title" "BLOCKED" 0 false
      log "  → stop (fail-closed, transport)"
      echo "hint: transient failure — rerun with --resume to continue from this task"
      exit 2
      ;;
    TIMEOUT)
      "$TASK_STATE" "$TASKS_FILE" "$n" "BLOCKED" 2>/dev/null || true
      copy_artifact
      TASKS_BLOCKED=$((TASKS_BLOCKED + 1))
      telemetry_emit_task "${RUN_ID:-}" "$n" "$title" "BLOCKED" 0 false
      log "  → stop (fail-closed, timeout)"
      echo "hint: transient failure — rerun with --resume to continue from this task"
      exit 2
      ;;
  esac

  local st
  st="$("$PARSE" "$LAST_WORKER_LOG")"
  if [ "$st" != "DONE" ] && [ "$st" != "DONE_WITH_CONCERNS" ]; then
    "$TASK_STATE" "$TASKS_FILE" "$n" "BLOCKED" 2>/dev/null || true
    copy_artifact
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
        dispatch_with_retry "fix" "$IMPL_MODEL" "$LOG_DIR/task-$n-fix-$round-prompt.md" \
          "修复验证失败的问题→重跑验证；回复末尾输出 '**Status:** DONE'。" "$LOG_DIR/task-$n-fix-$round.log"
        # Handle transport/timeout for fix
        case "$WORKER_OUTCOME" in
          TRANSPORT|EMPTY)
            "$TASK_STATE" "$TASKS_FILE" "$n" "BLOCKED" 2>/dev/null || true
            copy_artifact
            TASKS_BLOCKED=$((TASKS_BLOCKED + 1))
            telemetry_emit_task "${RUN_ID:-}" "$n" "$title" "BLOCKED" "$round" false
            log "  → stop (fail-closed, transport)"
            echo "hint: transient failure — rerun with --resume to continue from this task"
            exit 2
            ;;
          TIMEOUT)
            "$TASK_STATE" "$TASKS_FILE" "$n" "BLOCKED" 2>/dev/null || true
            copy_artifact
            TASKS_BLOCKED=$((TASKS_BLOCKED + 1))
            telemetry_emit_task "${RUN_ID:-}" "$n" "$title" "BLOCKED" "$round" false
            log "  → stop (fail-closed, timeout)"
            echo "hint: transient failure — rerun with --resume to continue from this task"
            exit 2
            ;;
        esac
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
    build_review_prompt "$LOG_DIR/task-$n-review-$round-prompt.md" "$n"
    log "  review (round $round) → dispatch($REVIEW_MODEL)"
    dispatch_with_retry "review" "$REVIEW_MODEL" "$LOG_DIR/task-$n-review-$round-prompt.md" \
      "审查上述变更文件（逐一读取），回复末尾输出 REVIEW_PASS 或 REVIEW_FAIL（有 CRITICAL/MAJOR 才 FAIL 并列问题）。" \
      "$LOG_DIR/task-$n-review-$round.log"

    # Handle transport/timeout for review
    case "$WORKER_OUTCOME" in
      TRANSPORT|EMPTY)
        "$TASK_STATE" "$TASKS_FILE" "$n" "BLOCKED" 2>/dev/null || true
        copy_artifact
        TASKS_BLOCKED=$((TASKS_BLOCKED + 1))
        telemetry_emit_task "${RUN_ID:-}" "$n" "$title" "BLOCKED" "$round" false
        log "  → stop (fail-closed, transport)"
        echo "hint: transient failure — rerun with --resume to continue from this task"
        exit 2
        ;;
      TIMEOUT)
        "$TASK_STATE" "$TASKS_FILE" "$n" "BLOCKED" 2>/dev/null || true
        copy_artifact
        TASKS_BLOCKED=$((TASKS_BLOCKED + 1))
        telemetry_emit_task "${RUN_ID:-}" "$n" "$title" "BLOCKED" "$round" false
        log "  → stop (fail-closed, timeout)"
        echo "hint: transient failure — rerun with --resume to continue from this task"
        exit 2
        ;;
    esac

    # Only parse review verdict when outcome is OK or APP
    case "$WORKER_OUTCOME" in
      OK|APP)
        rv="$(parse_review "$LAST_WORKER_LOG")"
        ;;
      *)
        rv="UNKNOWN"
        ;;
    esac
    copy_artifact
    telemetry_emit_round "${RUN_ID:-}" "$n" "$round" "$verify_status" "${rv:-UNKNOWN}"
    if [ "$rv" = "REVIEW_PASS" ]; then passed=1; log "  REVIEW_PASS"; break; fi
    log "  review = ${rv:-UNKNOWN} → fail-closed, fixer"
    build_fix_prompt "$n" "$LAST_WORKER_LOG" "$LOG_DIR/task-$n-fix-$round-prompt.md"
    dispatch_with_retry "fix" "$IMPL_MODEL" "$LOG_DIR/task-$n-fix-$round-prompt.md" \
      "按 CR 反馈修复→重跑验证；回复末尾输出 '**Status:** DONE'。" "$LOG_DIR/task-$n-fix-$round.log"
    # Handle transport/timeout for fix after review
    case "$WORKER_OUTCOME" in
      TRANSPORT|EMPTY)
        "$TASK_STATE" "$TASKS_FILE" "$n" "BLOCKED" 2>/dev/null || true
        copy_artifact
        TASKS_BLOCKED=$((TASKS_BLOCKED + 1))
        telemetry_emit_task "${RUN_ID:-}" "$n" "$title" "BLOCKED" "$round" false
        log "  → stop (fail-closed, transport)"
        echo "hint: transient failure — rerun with --resume to continue from this task"
        exit 2
        ;;
      TIMEOUT)
        "$TASK_STATE" "$TASKS_FILE" "$n" "BLOCKED" 2>/dev/null || true
        copy_artifact
        TASKS_BLOCKED=$((TASKS_BLOCKED + 1))
        telemetry_emit_task "${RUN_ID:-}" "$n" "$title" "BLOCKED" "$round" false
        log "  → stop (fail-closed, timeout)"
        echo "hint: transient failure — rerun with --resume to continue from this task"
        exit 2
        ;;
    esac
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
