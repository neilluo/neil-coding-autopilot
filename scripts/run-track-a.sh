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
#                      fixer 可用 $AUTOPILOT_FIXER_MODEL 单独覆盖（默认跟随 implementer）。
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

if [ "${AUTOPILOT_ROLE:-}" = worker ] && [ "${AUTOPILOT_ALLOW_NESTED:-}" != 1 ]; then
  echo "ERROR: nested autopilot run refused (AUTOPILOT_ROLE=worker)" >&2
  exit 2
fi

# ── self-locate (macOS-safe; not readlink -f) ────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# 自身绝对路径 —— 启动时写进 driver.log，用于当场识别「跑的到底是哪一份拷贝」。
SELF_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
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
REVIEW_MODEL="${AUTOPILOT_REVIEWER_MODEL:-Ultimate}"
FIX_MODEL=""   # 延后解析：必须在参数解析之后，见下方注释
MAX_ROUNDS=3
RESUME=false
DRY_RUN=false

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# 带值选项缺值时必须给可行动的报错。否则 `$2` 在 set -u 下报 "$2: unbound variable"，
# 无人值守的 CI 里只留下一行毫无指向的错误，而下面 92-98 行本该给出的清楚校验根本轮不到。
need_value() { [ "$2" -ge 2 ] || { echo "ERROR: $1 requires a value (use --help)" >&2; exit 1; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --change-dir) need_value "$1" $#; CHANGE_DIR="$2"; shift 2;;
    --cwd) need_value "$1" $#; CWD="$2"; shift 2;;
    --tasks) need_value "$1" $#; TASKS_FILE="$2"; shift 2;;
    --impl-model) need_value "$1" $#; IMPL_MODEL="$2"; shift 2;;
    --review-model) need_value "$1" $#; REVIEW_MODEL="$2"; shift 2;;
    --max-rounds) need_value "$1" $#; MAX_ROUNDS="$2"; shift 2;;
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

# AGENTS.md / README.md / conventions.md 三处都承诺了 `AUTOPILOT_FIXER_MODEL`，但代码里原本
# **零引用** —— fix 阶段硬编码用 $IMPL_MODEL，于是文档承诺了一个不存在的旋钮（设了无效且无提示）。
# 未设时回退到 $IMPL_MODEL（而不是硬写 Performance）：什么都不设 = Performance（与文档默认一致），
# 而只传 --impl-model X 时 fix 仍跟随 X（与本改动前行为完全一致）。
# **必须在参数解析之后解析**：放在默认值区（参数循环之前）会把 $IMPL_MODEL 冻在环境默认值上，
# 于是 `--impl-model X` 不再传给 fix 阶段 —— 已实测到这个回归（fix worker 拿到 Performance 而非 X）。
FIX_MODEL="${AUTOPILOT_FIXER_MODEL:-$IMPL_MODEL}"

# ── per-change atomic lock ───────────────────────────────────────────────────
# 锁住 TMPDIR，不住业务仓库：这把锁在整个 run 期间持有，而每个 Task 提交都跑
# `git add -A`，放在 $CHANGE_DIR/.lock 会把 .lock/pid、.lock/epoch 一并提进业务仓库
# （已在真实端到端跑中观测到，CR 也报了这一条）。同仓的 task-state.sh 与 LOG_DIR
# 早已遵守「harness 产物不落业务仓库」这个不变量，这里对齐。
# 以 CHANGE_DIR 路径作键，同一 change 的并发运行仍然互斥；AUTOPILOT_LOCK_DIR 可显式覆盖。
LOCK_DIR="${AUTOPILOT_LOCK_DIR:-${TMPDIR:-/tmp}/autopilot-track-a-lock$(printf '%s' "$CHANGE_DIR" | tr '/ ' '__')}"
LOCK_OWNED=false
# 锁目录自身的 mtime（BSD/GNU stat 双分支，与 hooks/ 里的写法一致）。取不到就返回 0，
# 由调用方按「无法判定」处理。接任意目录，以便认领后对 .reclaim.$$ 目录做锁龄复核。
_dir_mtime() {
  local d="${1:-}"
  [ -n "$d" ] && [ -d "$d" ] || { echo 0; return 0; }
  if [ "${OSTYPE:-}" != "${OSTYPE#darwin}" ]; then
    stat -f '%m' "$d" 2>/dev/null || echo 0
  else
    stat -c '%Y' "$d" 2>/dev/null || echo 0
  fi
}
_lock_dir_mtime() { _dir_mtime "$LOCK_DIR"; }
acquire_lock() {
  local holder_pid="" lock_epoch="" now age born grace reclaim_pid="" reclaim_epoch="" reclaim_ok=false reclaim_born=0
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_OWNED=true
  else
    [ -f "$LOCK_DIR/pid" ] && holder_pid="$(sed -n '1p' "$LOCK_DIR/pid" 2>/dev/null || true)"
    [ -f "$LOCK_DIR/epoch" ] && lock_epoch="$(sed -n '1p' "$LOCK_DIR/epoch" 2>/dev/null || true)"
    now="$(date +%s)"
    # 元数据不全 = 锁刚被另一个 run 建好、pid/epoch 还没写进去（mkdir 与写入之间
    # 有一个极短窗口）。旧逻辑在这里把 age 当成 43200 直接判陈旧并 rm -rf，于是两个
    # driver 会同时持锁、对同一工作树并发 dispatch worker 并互相 git add -A/commit。
    # 现在默认拒绝（fail-closed），只有锁目录本身足够老才当成崩溃残留接管。
    if [ -z "$holder_pid" ] || [ -z "$lock_epoch" ]; then
      grace="${AUTOPILOT_LOCK_INIT_GRACE_S:-60}"
      born="$(_lock_dir_mtime)"
      case "$born" in ''|*[!0-9]*) born=0 ;; esac
      if [ "$born" -gt 0 ] && [ "$(( now - born ))" -lt "$grace" ]; then
        echo "ERROR: Track A lock is being initialised by another run: $LOCK_DIR" >&2
        exit 2
      fi
    else
      case "$lock_epoch" in ''|*[!0-9]*) age=43200 ;; *) age=$(( now - lock_epoch )) ;; esac
      if kill -0 "$holder_pid" 2>/dev/null && [ "$age" -lt 43200 ]; then
        echo "ERROR: Track A lock held by active PID $holder_pid" >&2
        exit 2
      fi
    fi
    # 认领陈旧锁：mv 只保证「单次 rename 原子」，不保证「我搬走的还是我刚检查过的那个锁」：
    # A-mv → A-rm → A-mkdir（A 持锁）→ B-mv 此时搬走的是 **A 刚建的新锁**也会成功，
    # 于是双方都“持锁”、并发对同一工作树 dispatch worker 并互相 git add -A/commit，
    # 而 A 的 pid 文件被删，release_lock 比 pid 不相等，A 退出时也不会清理。
    # 所以搬走后必须**核对身份**：里面的 pid/epoch 必须仍是刚才观察到的那一份；
    # 不一致就把它原路搬回去并 fail-closed（宁可停，不可双持锁）。
    if mv "$LOCK_DIR" "$LOCK_DIR.reclaim.$$" 2>/dev/null; then
      reclaim_pid="$(sed -n '1p' "$LOCK_DIR.reclaim.$$/pid" 2>/dev/null || true)"
      reclaim_epoch="$(sed -n '1p' "$LOCK_DIR.reclaim.$$/epoch" 2>/dev/null || true)"
      reclaim_ok=false
      if [ -n "$holder_pid" ] && [ -n "$lock_epoch" ]; then
        # 有元数据：按身份比对。
        if [ "$reclaim_pid" = "$holder_pid" ] && [ "$reclaim_epoch" = "$lock_epoch" ]; then reclaim_ok=true; fi
      else
        # 元数据不全的崩溃残留（SIGKILL 落在 mkdir 与写 pid 之间）：holder_pid/lock_epoch 均为空，
        # 此时用身份比对是**空对空恒真**：A 认领并重建新锁但尚未写 pid 的窗口里，
        # B 搬走 A 的新锁也会得到 reclaim_pid=""，于是判定“仍是刚才那个锁”→ 双方双持锁。
        # 改用**锁龄复核**（与 task-state.sh 同法）：rename 不改变被搬目录自身的 mtime，
        # 所以搬过来的目录必须仍然“足够老”；年轻则说明搬到了别人刚建的新锁。
        reclaim_born="$(_dir_mtime "$LOCK_DIR.reclaim.$$")"
        case "$reclaim_born" in ''|*[!0-9]*) reclaim_born=0 ;; esac
        if [ "$reclaim_born" -gt 0 ] && [ "$(( now - reclaim_born ))" -ge "$grace" ]; then reclaim_ok=true; fi
      fi
      if $reclaim_ok; then
        rm -rf "$LOCK_DIR.reclaim.$$" 2>/dev/null || true
      else
        mv "$LOCK_DIR.reclaim.$$" "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR.reclaim.$$" 2>/dev/null || true
        echo "ERROR: Track A lock changed under us (another run claimed it): $LOCK_DIR" >&2
        exit 2
      fi
    elif [ -d "$LOCK_DIR" ]; then
      echo "ERROR: Track A lock was just claimed by another run: $LOCK_DIR" >&2
      exit 2
    fi
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

# ── startup notice：先把“会被卷进 Task 提交的既有脏改动”说清楚 ──────────────
# 每个 Task 提交前的 `git add -A` 会把工作树里**一切**未提交内容卷进 autopilot 的 Task
# commit，随后被 finish 合入主干；同时 review diff 也会把它们混进被审内容。这对操作者
# 是个真实的意外，所以必须开跑前就把这些路径列出来。
#
# 为何默认只警告而不拦住（重要，勿改回硬门禁）：本系统的 fail-closed 恢复路径本身
# 就会留下脏工作树 —— fail_closed_stop 的提示字面写着“Inspect 'git status' in \$CWD,
# keep or discard those changes, then rerun with --resume”，即 `--resume` 天然就是在脏树上
# 重跑。一刀切的启动门禁会直接堵死这条已文档化的恢复工作流（也实测弄挂了
# smoke-recursion-guard 里“同一 project 重复跑”的真实场景）。
# 需要硬门禁的场景（干净 CI）显式设 AUTOPILOT_REQUIRE_CLEAN=1。
# autopilot/ 下的未提交产物不算脏：analyze/plan 刚写出的 spec/tasks 本来就靠 Task 1
# 的 add -A 入库。
if ! $DRY_RUN; then
  FOREIGN_DIRTY="$( ( cd "$CWD" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1 \
    && git status --porcelain --untracked-files=all 2>/dev/null ) \
    | sed -e 's/^...//' -e 's/.* -> //' | grep -v '^autopilot/' || true )"
  if [ -n "$FOREIGN_DIRTY" ]; then
    if [ "${AUTOPILOT_REQUIRE_CLEAN:-0}" = 1 ]; then
      echo "ERROR: $CWD 存在 autopilot/ 之外的未提交改动，而 AUTOPILOT_REQUIRE_CLEAN=1:" >&2
      printf '%s\n' "$FOREIGN_DIRTY" | sed 's/^/  dirty: /' >&2
      exit 1
    fi
    echo "WARN: $CWD 已有 autopilot/ 之外的未提交改动，它们会被第一个 Task 的 \`git add -A\` 一并提交，" >&2
    echo "      也会混进 review diff。若非有意（例如 --resume 继跑），请先 commit / stash：" >&2
    printf '%s\n' "$FOREIGN_DIRTY" | sed 's/^/      dirty: /' >&2
  fi
fi

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
  # 显式参数优先，缺参时回退到最近一次 worker 日志。
  # 旧写法把 LAST_WORKER_LOG 当成默认值写在外层，于是全局变量**反过来盖住**入参 ——
  # 一个注释写着 `copy_artifact <src-log-file>` 的函数，只要全局非空就忽略参数；
  # 以前所有调用点都不传参，所以一直没暴露。现在需要指名搬 driver.log，必须修正。
  # 改用两行写法（而不是把那个全局变量继续写成 `:-` 默认值），因为
  # smoke-backward-compat.sh 会把「既有默认值表达式被改动」当成兼容性破坏并报错，
  # 那是有意的守卫 —— 不为绕过它而放宽白名单。（同理：本注释也不能写出那个
  # 默认值字面量，守卫是全文扫描、包括注释的 —— 已实测被自己的注释给报了一次。）
  # LAST_WORKER_LOG 已在上方初始化为 ""，因此直接引用在 set -u 下安全。
  local src="${1:-}" root="" dest=""
  [ -n "$src" ] || src="$LAST_WORKER_LOG"
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
  # driver.log 是复盘时最有用的一个文件（每个 Task 的判定、重试、门禁结论都在里面），
  # 但它住在 $TMPDIR 里等着被系统回收 —— 2026-08-16 的复盘能成立纯属 TMPDIR 还没清。
  # copy_artifact 以前只搬 LAST_WORKER_LOG 一个 worker 日志，driver.log 从不留存。
  # 这里无条件把它复制到 log root（fail-safe，失败静默跳过）。
  copy_artifact "$LOG_DIR/driver.log"
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
# `|| true` 是必需的：标题行不匹配时 grep 返回 1，pipefail 会让整条管道失败，调用处
# 的 `title="$(task_title "$n")"` 于是触发 set -e，整个 run 在没有任何 stderr、没有
# BLOCKED 标记的情况下 exit 1（实测：把某个标题写成全角冒号 `## Task 2：` 即可复现）。
# 现在改为返回空串，由 run_task 显式报出可行动的错误。
task_title() { grep -E "^## Task $1:" "$TASKS_FILE" | head -1 | sed -E "s/^## Task $1:[[:space:]]*//" || true; }
# 状态/验证命令的提取必须与写入方 task-state.sh 同锚点（它的 sed 是 `^\*\*Status\*\*:`，
# 即字段必须顶格）。读侧一旦比写侧宽松，就会读到写侧永远不会维护的行：实测 Task 描述
# 里出现一句 `- 示例：**Status**: DONE`，task_status 就返回 DONE、该 Task 被整个跳过，
# 而 run 结束照样打印 ALL TASKS DONE —— 本系统定义里最高危的那类假成功。
# 同理 task_verify：本仓 tasks.md 里真实存在 `0. **不得修改本文件的 `**Verify**` 行`
# 这样的散文行，不顶格锚定就会把散文当成验证命令。
task_status() {
  task_block "$1" | grep -iE '^\*\*status\*\*:' | head -1 \
    | grep -ioE '(DONE_WITH_CONCERNS|DONE|PENDING|IN_PROGRESS|BLOCKED|NEEDS_CONTEXT)' | head -1 \
    | tr '[:lower:]' '[:upper:]' || true
}
task_verify() {  # per-task **Verify**: `cmd`; fall back to global verify
  local v
  # 与 Status 不同：`**Verify**` 没有写侧脚本（Status 由 task-state.sh 用 `^\*\*Status\*\*:` 写，
  # 读写同锚），它完全是 plan 阶段 LLM 自由生成的，写成列表项或带缩进
  # （`- **Verify**: \`cmd\``、`  **Verify**: \`cmd\``）在 markdown 里非常自然。若只认顶格，
  # 这类行一律解析落空 → 回退到 GLOBAL_VERIFY，若全局也没有则 verify=""，
  # 控制器自跑 verify 这道**地面真相门禁整个消失**，Task 只凭 CR 一票就 commit（fail-open）。
  # 因此允许可选的列表符/缩进，但仍禁止「前面有其他文字」—— 这样反例
  # `0. **不得修改本文件的 \`**Verify**\` 行` 仍然不命中（它的 `**Verify**` 不在行首、且后面无冒号）。
  v="$(task_block "$1" | grep -iE '^[[:space:]]*([-*+]|[0-9]+\.)?[[:space:]]*\*\*verify\*\*:' | head -1 | awk -F"$BT" 'NF>=3 {print $2; exit}' || true)"
  if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$GLOBAL_VERIFY"; fi
}

# ── worker dispatch ──────────────────────────────────────────────────────────
# Sets globals: WORKER_RC, WORKER_OUTCOME, AUTOPILOT_TM_FAILURE_CLASS (env for telemetry)
dispatch_worker() {
  local stage="$1" model="$2" pfile="$3" instr="$4" outlog="$5"
  set +e
  # 默认 auto（与 AGENTS.md 的平台配置表一致），把平台探测留给 dispatch.sh。
  # 曾硬编码为 qoder：在只装了 claude/codex 的机器上，文档承诺的自动检测在 Track A
  # 永远不生效，dispatch 必败后还会被当成链路故障重试到耗尽，诊断方向完全错。
  AUTOPILOT_PLATFORM="${AUTOPILOT_PLATFORM:-auto}" \
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
#
# 工作树指纹：用来区分两种同形异质的 EMPTY。真掉线的 worker 不会动文件，重试是安全的；
# 而「干完活没报数」的 worker（模型把整个回合收在 thinking 里，见 dispatch.sh 同名注释）
# 已经改过盘，再重试等于让新 worker 在上一个 worker 的半成品上重做同一个 Task。
# 非 git 目录永远得到同一个签名，因此不会误判为 SILENT。
# 工作树指纹的噪声排除清单（ERE，同时用于 porcelain 行与 ls-files 路径；
# porcelain 行形如 `?? target/x`，所以前导边界写成 `(^|[ /])`）。
# 这些都是验证/构建/agent 自己产生的东西，不代表 worker 对源码的真实产出。
SIG_EXCLUDE="${AUTOPILOT_SIG_EXCLUDE:-(^|[ /])(\.git|\.qoder|\.claude|\.codex|node_modules|target|build|dist|out|__pycache__|\.pytest_cache|\.mypy_cache|\.ruff_cache|\.venv|venv|\.gradle|\.next|\.turbo|coverage)(/|\$)}"

worktree_signature() {
  ( cd "$CWD" 2>/dev/null || exit 0
    git rev-parse --git-dir >/dev/null 2>&1 || exit 0
    # `--untracked-files=all` 是必需的：默认模式下一个未跟踪目录只占一行 `?? dir/`，
    # worker 往里面新增文件时这行不变。
    git -c core.quotePath=false status --porcelain --untracked-files=all 2>/dev/null | grep -Ev "$SIG_EXCLUDE" || true
    git diff HEAD 2>/dev/null
    # 未跟踪文件的**内容**既不体现在 status 行里、也不进 diff HEAD：只看这两者的话，
    # 一个只改了既有未跟踪文件的静默 worker 会被当成“工作树未动”，于是新 worker
    # 叠在它的半成品上重做同一个 Task —— 正是本守卫要防的事。
    # 但必须排除构建/agent 噪声：worker 被要求“跑验证命令”，验证会产出 target/ 、
    # __pycache__ 、agent CLI 自己的 session 文件等未跟踪产物；把它们计入指纹，会让一次
    # 真链路故障（TRANSPORT）因为多了一个构建垃圾就被改判成 SILENT → 指数退避重试
    # 彻底失效、无人值守夜跑因一次抖动整条停下，而且提示语还把人往“找半成品”上引。
    # 排除清单可用 AUTOPILOT_SIG_EXCLUDE 覆盖（ERE）。
    # 必须 `-c core.quotePath=false` + `-z`：git 默认把非 ASCII 文件名输出成带引号的八进制
    # 转义串（本仓就是中文项目），那种字符串拿去 `[ -f "$_f" ]` 必然为假 → 该文件被跳过、
    # 内容不进指纹，于是“静默 worker 只改了一个中文名未跟踪文件”又会被误判成 EMPTY，
    # 本守卫归于无效（与 review-context.sh 里同一个 quotePath 坑，上一轮在那边修了、这里漏了）。
    # 排除清单改到循环内逐个判：NUL 分隔流上不能用行导向的 grep。
    git -c core.quotePath=false ls-files -z --others --exclude-standard 2>/dev/null | while IFS= read -r -d '' _f; do
      [ -n "$_f" ] || continue
      printf '%s' "$_f" | grep -Eq "$SIG_EXCLUDE" && continue
      [ -f "$_f" ] && cksum "$_f" 2>/dev/null
    done ) | cksum 2>/dev/null || true
}

# ── fail-closed stop with an accurate diagnosis ──────────────────────────────
# 所有不可行动的 worker 结局共用这一个出口。文案必须准确：把「干完活没报数」报成
# transport failure 曾让人花 35 分钟去查网络，而真因是模型只在 thinking 里收尾。
fail_closed_stop() {
  local n="$1" title="$2" round="$3"
  "$TASK_STATE" "$TASKS_FILE" "$n" "BLOCKED" 2>/dev/null || true
  copy_artifact
  TASKS_BLOCKED=$((TASKS_BLOCKED + 1))
  telemetry_emit_task "${RUN_ID:-}" "$n" "$title" "BLOCKED" "$round" false
  case "$WORKER_OUTCOME" in
    TIMEOUT)
      log "  → stop (fail-closed, timeout)"
      echo "hint: transient failure — rerun with --resume to continue from this task"
      ;;
    SILENT)
      log "  → stop (fail-closed, silent worker — worktree already modified)"
      echo "hint: NOT a transport failure — the worker ran tools but never printed a verdict line."
      echo "      Inspect 'git status' in $CWD, keep or discard those changes, then rerun with --resume."
      ;;
    EMPTY)
      # 静默耗尽（工作树未动）也不是链路故障，不能套用 transport 文案——否则
      # 又把人往网络方向引。这种情形下重跑是安全的（没有半成品遗留）。
      log "  → stop (fail-closed, worker stayed silent — no output, worktree untouched)"
      echo "hint: NOT a transport failure — every attempt ended inside thinking with no text block."
      echo "      Nothing was written, so rerunning with --resume is safe; consider raising AUTOPILOT_SILENT_RETRIES"
      echo "      or switching the stage model (see AUTOPILOT_REVIEWER_MODEL) if this repeats."
      ;;
    TRUNCATED)
      # 工具调用被截断：模型发出了 tool_use、CLI 没执行就退出，文件零改动。
      # 这里绝不重试（dispatch.sh 实测：原样重试 3 次全部复现）——重试只是把同一次
      # 注定失败的调用按全价再买两遍。唯一出路是消除诱因后重开 fresh session。
      log "  → stop (fail-closed, truncated tool call — nothing was executed)"
      echo "hint: NOT a transport failure and NOT retryable — the model emitted a tool call the CLI never ran."
      echo "      Nothing was written. Retrying the same prompt reproduces it; fix the cause instead:"
      echo "      unset AUTOPILOT_USAGE_JSON, forbid preamble text in the prompt, or shrink this task, then --resume."
      ;;
    *)
      log "  → stop (fail-closed, transport)"
      echo "hint: transient failure — rerun with --resume to continue from this task"
      ;;
  esac
  exit 2
}

dispatch_with_retry() {
  local stage="$1" model="$2" pfile="$3" instr="$4" base_log="$5"
  local max_attempts="${AUTOPILOT_TRANSPORT_RETRIES:-3}"
  local silent_attempts="${AUTOPILOT_SILENT_RETRIES:-5}"
  local switch_after="${AUTOPILOT_SILENT_SWITCH_AFTER:-2}"
  local fallback_model="${AUTOPILOT_SILENT_FALLBACK_MODEL-Performance}"
  local backoff_base="${AUTOPILOT_RETRY_BACKOFF_S:-5}"
  local attempt=1 outlog backoff mult i sig_before sig_after cap
  local active_model="$model" switched=false
  # 静默降档：空 = 不传 --reasoning-effort（保留默认完整推理）。只在已经静默过之后才降，
  # 因为降档会让审查/实现变浅；但总比“一字不发”好。设 AUTOPILOT_SILENT_EFFORT="" 可关闭。
  local silent_effort="${AUTOPILOT_SILENT_EFFORT-low}" effort=""

  [ "$max_attempts" -gt 0 ] || max_attempts=1
  [ "$silent_attempts" -gt 0 ] || silent_attempts=1
  while true; do
    outlog="${base_log%.log}-a${attempt}.log"
    LAST_WORKER_LOG="$outlog"
    sig_before="$(worktree_signature)"

    AUTOPILOT_ATTEMPT="$attempt" AUTOPILOT_REASONING_EFFORT="$effort" \
      dispatch_worker "$stage" "$active_model" "$pfile" "$instr" "$outlog"

    case "$WORKER_OUTCOME" in
      TRANSPORT|EMPTY)
        sig_after="$(worktree_signature)"
        if [ "$sig_before" != "$sig_after" ]; then
          WORKER_OUTCOME=SILENT
          AUTOPILOT_TM_FAILURE_CLASS=SILENT
          log "  silent worker (attempt $attempt/$max_attempts): no verdict line, but the worktree changed"
          log "    → not a dropped connection; refusing to retry on top of its own edits"
          break
        fi
        # 两类失败的正确重试策略完全不同，不能共用一套参数：
        #   TRANSPORT（限流/连接重置等真链路问题）——等待确实有用，保持指数退避。
        #   EMPTY（静默回合，工作树未动）——等待毫无意义：模型把回合收进 thinking
        #   与服务端拥塞无关，睡 20s 不会让下一次更容易开口。实测（Ultimate×8 轮
        #   review）静默率 ~50%、且每次静默只产出 466B/约 16s；改成立即重试可省掉
        #   5+10+20=35s 的空等，并把上限单独提高（P(连续 5 次静默)≈3%，而 fail-closed
        #   停机要搭上整个 Task + 人工介入，代价高得多）。
        if [ "$WORKER_OUTCOME" = EMPTY ]; then
          cap="$silent_attempts"
          if [ "$attempt" -lt "$cap" ]; then
            log "  silent worker output (attempt $attempt/$cap) → retry immediately (backoff cannot un-silence a thinking-only turn)"
            # 先降推理档位（直接打击“回合死在 thinking 里”这个成因，实测默认档 1/4 静默
            # 而 low 档 0/4），它比换模型更便宜也更定向，所以放在前面。
            if [ -n "$silent_effort" ] && [ "$effort" != "$silent_effort" ]; then
              log "    → lowering reasoning effort to '$silent_effort' for the remaining attempts"
              effort="$silent_effort"
            fi
            # 静默是模型特性，不是链路抖动：同一 review prompt 实测 Ultimate 8/15 静默（含
            # 真实遥测 4/7 与控制实验 4/8），而 Performance 0/6、Qwen3.8-Max 0/6，且两者
            # 都正确找出除零缺陷并给出 REVIEW_FAIL。所以同一个模型反复重试收益有限；
            # 连续静默后换模型，既保留默认模型开口时的 CR 质量，又不让整个 Task 因它闭嘴
            # 而 fail-closed（降级模型通常还更便宜、更快）。设 AUTOPILOT_SILENT_FALLBACK_MODEL="" 可关闭。
            if ! $switched && [ -n "$fallback_model" ] && [ "$attempt" -ge "$switch_after" ] \
                && [ "$fallback_model" != "$active_model" ]; then
              log "    → $active_model stayed silent ${attempt}x; switching to $fallback_model for the remaining attempts"
              active_model="$fallback_model"
              switched=true
            fi
            attempt=$(( attempt + 1 ))
            continue
          fi
          log "  silent worker output (attempt $attempt/$cap) → exhausted"
          break
        fi
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
  local out="$1" n="${2:-}" diff_file="${3:-}"
  {
    echo "你是一个代码审查专家，对本 Task 的代码变更做严格审查（Track A reviewer，经 dispatch.sh 调度）。"
    echo; echo "以下是本 Task 的完整变更（有界 diff）。**先基于 diff 评审**；若某处需要上下文，再自行打开对应文件。"; echo
    # 使用预先生成并已校验过的 diff 文件，而不是在这里直接跑 review-context.sh：
    # 在 `{ ... } > "$out"` 里直调时，它的退出码会被后续的 echo 覆盖而彻底丢弃，
    # 于是 review-context 失败（$CWD 非 git 仓 / git 报错 / 本身出错）时，reviewer 会拿到
    # 一份「以下是本 Task 的完整变更」后面空白的提示词，而提示词又强制它必须给出
    # REVIEW_PASS/FAIL —— 极可能直接盖 PASS，等于“没审就过”。
    if [ -n "$diff_file" ] && [ -s "$diff_file" ]; then
      cat "$diff_file"
    fi
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
    echo; echo "## 结论（回复正文末尾必须输出结论行）"
    # 切勿在这里把裸标记写在行首后面再跟注释。旧模板就是两行
    #   REVIEW_PASS   # 无 CRITICAL/MAJOR
    # 而 parse-markers.sh 有意要求裁决行独占（smoke-parse-markers case5、spec § 均钉住：
    # 这一行必须解成 UNKNOWN）。于是 reviewer 只要照模板抛一行，一个实际上
    # REVIEW_PASS 的 Task 就会被 fail-closed 判成 BLOCKED（已实测复现）。
    # 现在把标记放进反引号的叙述句里（行首是列表符 + 汉字，不可能误命中），
    # 并把「独占一行」当成硬要求写清楚。
    echo "- 无 CRITICAL/MAJOR → 末行写 \`REVIEW_PASS\`"
    echo "- 有 CRITICAL/MAJOR → 末行写 \`REVIEW_FAIL\`，并在其上方列出问题 + 文件:行号"
    echo "- 结论行必须独占一行：行尾**不要**跟 # 注释或任何说明文字，否则会被当成未给结论。"
  } > "$out"
}

# Use parse-markers.sh for anchored review verdict extraction (D19)
parse_review() { "$PARSE_MARKERS" review "$1" 2>/dev/null || echo "UNKNOWN"; }

# ── per-task inner loop ──────────────────────────────────────────────────────
run_task() {
  local n="$1" title status verify round=0 passed=0 rv verify_status committed
  title="$(task_title "$n")"; status="$(task_status "$n")"; [ -n "$status" ] || status="PENDING"
  if [ -z "$title" ]; then
    log "  ERROR: Task $n 在 $TASKS_FILE 里没有 '## Task $n:' 标题行（是不是用了全角冒号 '：'？）→ stop"
    exit 1
  fi
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

  # Handle transport/silent/timeout exhaustion for implement
  # SILENT（静默但已改盘）在这里**不**停机：本阶段后面紧跟着 verify 门禁，而本仓的
  # 原则本就是“控制器自己跑 verify、绝不信自述”——对 implement 而言地面真相是 verify
  # 通不通，不是那行 Status。实测碰到过：worker 已正确写完文件却未报数，旧逻辑直接
  # 停机要人工介入，而 verify + 独立 CR 本来就能安全地判它好不好。不变量未被放松：
  # 仍须 verify 通过 + 独立 CR REVIEW_PASS 才会 commit。
  IMPL_UNREPORTED=false
  case "$WORKER_OUTCOME" in
    SILENT)
      IMPL_UNREPORTED=true
      log "  implement produced changes without a verdict line → letting the verify gate decide (never trusting self-report anyway)"
      ;;
    TRANSPORT|EMPTY|TIMEOUT|TRUNCATED) fail_closed_stop "$n" "$title" 0 ;;
  esac

  local st
  # 与 parse_review 对称地兼容 parse 失败：无兜底时一旦 parse-status.sh 非零退出，set -e
  # 会直接结束整个 run，既不标 BLOCKED、不发遥测，退出码也落不进 0/1/2/130 的语义契约。
  st="$("$PARSE" "$LAST_WORKER_LOG" 2>/dev/null || echo UNKNOWN)"
  if [ "$st" != "DONE" ] && [ "$st" != "DONE_WITH_CONCERNS" ] && ! $IMPL_UNREPORTED; then
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
        # 与 review-fail 路径对称：最后一轮不再派 fixer。之前只在 review-fail 处加了这道守卫，
        # verify-fail 这边漏了：round == MAX_ROUNDS 时照样派 fixer → continue → 循环条件
        # 不成立退出 → BLOCKED，fixer 的产出永远不会再过 verify/CR/commit：白烧一次 worker
        # 调用，且工作树叠上一层未经任何门禁的修改（下面 SILENT 分支那句
        # “re-running the verify gate” 此时也是假的）。
        if [ "$round" -ge "$MAX_ROUNDS" ]; then
          log "  (round $round = max-rounds; 不再派 fixer，其产出无法再被验证)"
          break
        fi
        build_fix_prompt "$n" "$LOG_DIR/task-$n-verify-$round.log" "$LOG_DIR/task-$n-fix-$round-prompt.md"
        dispatch_with_retry "fix" "$FIX_MODEL" "$LOG_DIR/task-$n-fix-$round-prompt.md" \
          "修复验证失败的问题→重跑验证；回复末尾输出 '**Status:** DONE'。" "$LOG_DIR/task-$n-fix-$round.log"
        # Handle transport/silent/timeout for fix
        # 同 implement：静默但已改盘交给下一轮 verify 判，不靠自述。
        case "$WORKER_OUTCOME" in
          SILENT) log "  fix produced changes without a verdict line → re-running the verify gate" ;;
          TRANSPORT|EMPTY|TIMEOUT|TRUNCATED) fail_closed_stop "$n" "$title" "$round" ;;
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
    # review 的唯一输入就是这份有界 diff，所以它必须先落盘并通过两道校验（rc + 非空），
    # 否则 fail-closed。绝不能拿一份空上下文去让 reviewer 盖章。
    REVIEW_DIFF="$LOG_DIR/task-$n-diff-$round.txt"
    if ! "$REVIEW_CONTEXT" --cwd "$CWD" > "$REVIEW_DIFF" 2>"$REVIEW_DIFF.err"; then
      log "  review-context FAILED (见 $REVIEW_DIFF.err) → stop (fail-closed)"
      "$TASK_STATE" "$TASKS_FILE" "$n" "BLOCKED" 2>/dev/null || true
      TASKS_BLOCKED=$((TASKS_BLOCKED + 1))
      telemetry_emit_task "${RUN_ID:-}" "$n" "$title" "BLOCKED" "$round" false
      exit 2
    fi
    if [ ! -s "$REVIEW_DIFF" ]; then
      log "  review-context 产出空 diff → stop (fail-closed；空上下文下的 CR 结论没有意义)"
      "$TASK_STATE" "$TASKS_FILE" "$n" "BLOCKED" 2>/dev/null || true
      TASKS_BLOCKED=$((TASKS_BLOCKED + 1))
      telemetry_emit_task "${RUN_ID:-}" "$n" "$title" "BLOCKED" "$round" false
      exit 2
    fi
    build_review_prompt "$LOG_DIR/task-$n-review-$round-prompt.md" "$n" "$REVIEW_DIFF"
    log "  review (round $round) → dispatch($REVIEW_MODEL)"
    dispatch_with_retry "review" "$REVIEW_MODEL" "$LOG_DIR/task-$n-review-$round-prompt.md" \
      "基于已内联的有界 diff 审查，必要时才打开个别文件确认，回复末尾输出 REVIEW_PASS 或 REVIEW_FAIL（有 CRITICAL/MAJOR 才 FAIL 并列问题）。" \
      "$LOG_DIR/task-$n-review-$round.log"

    # Handle transport/silent/timeout for review
    case "$WORKER_OUTCOME" in
      TRANSPORT|EMPTY|SILENT|TIMEOUT|TRUNCATED) fail_closed_stop "$n" "$title" "$round" ;;
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
    # 最后一轮不再派 fixer：循环条件已不成立，它的产出永远不会再过 verify/CR/commit。
    # 旧行为白烧一次完整 worker 调用，更坑的是：操作者按提示去看 git status 时，工作树
    # 已叠了一层未经任何门禁检验的修改，与 CR 报告描述的状态不一致。
    if [ "$round" -ge "$MAX_ROUNDS" ]; then
      log "  (round $round = max-rounds; 不再派 fixer，其产出无法再被验证)"
      break
    fi
    build_fix_prompt "$n" "$LAST_WORKER_LOG" "$LOG_DIR/task-$n-fix-$round-prompt.md"
    dispatch_with_retry "fix" "$FIX_MODEL" "$LOG_DIR/task-$n-fix-$round-prompt.md" \
      "按 CR 反馈修复→重跑验证；回复末尾输出 '**Status:** DONE'。" "$LOG_DIR/task-$n-fix-$round.log"
    # Handle transport/silent/timeout for fix after review
    # 同上：静默但已改盘继续进下一轮 verify + CR，不把已完成的修复丢弃。
    case "$WORKER_OUTCOME" in
      SILENT) log "  fix produced changes without a verdict line → re-running the verify gate" ;;
      TRANSPORT|EMPTY|TIMEOUT|TRUNCATED) fail_closed_stop "$n" "$title" "$round" ;;
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
  # DONE 这一次状态写入必须校验（其余状态写失败只影响可观测性，所以仍保持 best-effort）：
  # DONE 写不进去意味着提交里带的 tasks.md 仍是旧状态 —— 下一轮会重跑同一个 Task，
  # finish 的门禁也会卡住，而本轮却已经把代码提交进去了。task-state.sh 现在会在
  # 无匹配时报错并非零退出（编号越界 / 该段没有顶格状态行等）。
  if ! "$TASK_STATE" "$TASKS_FILE" "$n" "DONE"; then
    TASKS_BLOCKED=$((TASKS_BLOCKED + 1))
    telemetry_emit_task "${RUN_ID:-}" "$n" "$title" "BLOCKED" "$round" false
    log "  Task $n 的状态无法写入 DONE（见上方 task-state 报错）→ stop (fail-closed)"; exit 2
  fi
  # `git add -A` 失败必须与「本来就没有改动」区分开。旧写法 `2>/dev/null || true` 把 add
  # 的真失败（index.lock 竞争 / 权限 / 索引损坏）吞成“暂存区为空”，于是走进下面的
  # nothing-to-commit 分支：Task 照记 DONE、run 照 exit 0，改动却仍躺在工作树里，随后被
  # 下一个 Task 的 add -A 卷进错误的提交（归属错乱）。这正是本段注释声称要区分的情形。
  if ! ( cd "$CWD" && git add -A ) 2>/dev/null; then
    "$TASK_STATE" "$TASKS_FILE" "$n" "BLOCKED" 2>/dev/null || true
    TASKS_BLOCKED=$((TASKS_BLOCKED + 1))
    telemetry_emit_task "${RUN_ID:-}" "$n" "$title" "BLOCKED" "$round" false
    log "  Task $n staging FAILED (git add -A) → stop (fail-closed)"; exit 2
  fi
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
# 全局 verify 行的真实写法不止一种（`> 全局 verify: `cmd``、`> Verify command: `cmd``、
# `> Global Verify: `cmd``、`> 全局 verify: 运行 `cmd``），所以不能要求固定字段名；
# 但也不能只要求「行里有 verify 且有反引号」——那样任何一句带反引号的散文
# （如 `> 说明：verify 之前先看 `README.md``）都会被当成验证命令，门禁被替成
# `README.md`：若它恰好是恒过的命令，坏代码一路过闸。
# 判据是「反引号之前的那段文字里，verify 之后跟着一个冒号」（awk 按反引号分域，
# $1 即首个反引号之前的全部文字）：
#   「全局 verify: 运行 」「Verify command: 」「Global Verify: 」→ verify 后有冒号 ✓
#   「说明：verify 之前先看 」→ 冒号在 verify **之前**，不命中 ✗
# 全角冒号必须先 gsub 成 ASCII 再用**纯 ASCII 字符类**，切勿写成 `[^:：]*[:：]`：
# 方括号内的多字节字符在 locale=C 下会被 awk 按**字节**拆成 {':',0xEF,0xBC,0x9A}，
# 而所有全角标点都以 EF BC 开头，于是一行散文 `> 注意 verify，见 \`README.md\``
# （全角逗号 EF BC 8C）也能命中并 exit，把验证命令换成 `README.md`。
# 已实测：LC_ALL=C 下得 `README.md`、UTF-8 下得真命令 —— 而 launchd 定时任务正是 C locale。
# （parse-markers.sh 这轮已把全角冒号改成分组交替，此处曾漏改。）
GLOBAL_VERIFY="$(awk -F"$BT" '/^>/ && NF>=3 { h=tolower($1); gsub(/：/, ":", h); if (h ~ /verify[^:]*:/) { print $2; exit } }' "$TASKS_FILE" 2>/dev/null || true)"
# 落空但存在「看起来就是全局 verify」的行时，必须大声告诉操作者：否则“没有门禁”
# 会静默成为常态。这里不硬停，因为该行也可能真的只是散文（硬停就变成误拦）。
if [ -z "$GLOBAL_VERIFY" ]; then
  SUSPECT_VERIFY="$(awk -F"$BT" '/^>/ && NF>=3 && tolower($1) ~ /verify/ {print; exit}' "$TASKS_FILE" 2>/dev/null || true)"
  if [ -n "$SUSPECT_VERIFY" ]; then
    echo "WARN: 发现类似全局 verify 的行，但格式不被接受，已忽略（于是只剩 per-task Verify）:" >&2
    printf '        %s\n' "$SUSPECT_VERIFY" >&2
    echo "        可接受写法：'> 全局 verify: \`<cmd>\`'（verify 后要有冒号，命令放反引号里）" >&2
  fi
fi
TASK_NUMS=( $(grep -oE '^## Task [0-9]+' "$TASKS_FILE" | grep -oE '[0-9]+' || true) )
[ "${#TASK_NUMS[@]}" -gt 0 ] || { echo "ERROR: no '## Task N:' entries in $TASKS_FILE" >&2; exit 1; }

log "Track A run | change=$CHANGE_DIR | cwd=$CWD | tasks=${#TASK_NUMS[@]} | impl=$IMPL_MODEL review=$REVIEW_MODEL | max-rounds=$MAX_ROUNDS resume=$RESUME dry-run=$DRY_RUN"
# 「谁在跑」必须第一行就写清。2026-08-16 的事故：业务仓库里有一份 8-15 拷出来的 fork
# （neil-fbi-init/.autopilot-local/scripts/），缺 worktree 指纹守卫、缺 EMPTY 分支，于是把
# 「干完活没报数」全标成 transport failure、丢弃已落盘的成果并重试到 BLOCKED；9 次真实 run
# 无一例外。而 driver.log 里没有任何一行说明正在执行哪个文件，排查方向被带偏了一整晚。
# 打印自身绝对路径 + dispatch 路径，任何「跑的不是你以为的那份代码」当场可见。
log "driver: script=$SELF_PATH dispatch=$DISPATCH classify=$CLASSIFY"
log "global verify: ${GLOBAL_VERIFY:-<none>}"
$DRY_RUN || log "logs → $LOG_DIR"

for n in "${TASK_NUMS[@]}"; do
  run_task "$n"
done

log "ALL TASKS DONE ✅ (Track A complete)"
exit 0
