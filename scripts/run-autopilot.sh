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

# 带值选项缺值时给可行动的报错（否则 set -u 只会报 "$2: unbound variable"）。
need_value() { [ "$2" -ge 2 ] || { echo "ERROR: $1 requires a value (use --help)" >&2; exit 1; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --change-dir) need_value "$1" $#; CHANGE_DIR="$2"; shift 2;;
    --cwd) need_value "$1" $#; CWD="$2"; shift 2;;
    --tasks) need_value "$1" $#; TASKS_FILE="$2"; shift 2;;
    --resume) RESUME=true; shift;;
    --max-rounds) need_value "$1" $#; MAX_ROUNDS="$2"; shift 2;;
    --impl-model) need_value "$1" $#; IMPL_MODEL="$2"; shift 2;;
    --review-model) need_value "$1" $#; REVIEW_MODEL="$2"; shift 2;;
    --finish-model) need_value "$1" $#; FINISH_MODEL="$2"; shift 2;;
    --evolve-model) need_value "$1" $#; EVOLVE_MODEL="$2"; shift 2;;
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
CWD="$(cd "$CWD" && pwd -P)"
# --change-dir 允许相对路径，但整条流水线是在 --cwd 下跑的：必须先按 $CWD 归一，
# 否则从别处（CI/cron 的 $HOME）调用时，下面的存在性判断会把「存在的 change」误判为
# 「不存在」，进而走进「已归档 → 跳过 loop+finish」分支而假成功。归一后一路传绝对路径。
case "$CHANGE_DIR" in
  /*) : ;;
  *)  CHANGE_DIR="$CWD/$CHANGE_DIR" ;;
esac

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
  # 默认 auto（与 AGENTS.md 平台配置表一致），平台探测交给 dispatch.sh；硬编码 qoder
  # 会让只装了 claude/codex 的主机上 finish/evolve 必败。
  AUTOPILOT_PLATFORM="${AUTOPILOT_PLATFORM:-auto}" AUTOPILOT_STAGE="$stage" \
    AUTOPILOT_ATTEMPT="${AUTOPILOT_ATTEMPT:-1}" AUTOPILOT_REASONING_EFFORT="${AUTOPILOT_REASONING_EFFORT:-}" \
    "$DISPATCH" --model "$model" --cwd "$CWD" --prompt-file "$pfile" --instruction "$instr" 2>&1 | tee "$outlog"
  rc=${PIPESTATUS[0]}
  set -e
  [ "$rc" -eq 0 ] || log "  WARN: dispatch exit=$rc (see $outlog)"
  return 0
}

# 工作树指纹（与 run-track-a.sh 同语义）：区分“真的什么都没做”与“已经动过盘”。
# 必须包含 HEAD：只看未提交状态时，一个把 merge/归档/commit 全做完却没输出结论行的
# 静默 finish worker（FINISH_MODE=worker）会让指纹前后一致（提交后工作树本就是干净的），
# 于是被判成“未动盘、重试安全”—— 在一个已完成且不幂等的 finish 上再拉一次 worker。
worktree_signature() {
  ( cd "$CWD" 2>/dev/null || exit 0
    git rev-parse --git-dir >/dev/null 2>&1 || exit 0
    git rev-parse HEAD 2>/dev/null
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
  # switch_after 也必须清洗：它只在 `[ "$attempt" -ge "$switch_after" ]` 里用，非数字时
  # 该比较每次都往 stderr 打 "integer expression expected" 并恒为假 —— 换模型这道兜底
  # 永远不会触发（静默退化，不报错）。
  case "$switch_after" in ''|*[!0-9]*) switch_after=2 ;; esac
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

# ── 归档提交断言（假成功通道的单一守卫）──────────────────────────
# finish-change.sh 的 merge 与归档 mv 发生在提交**之前**：它在 `git add` / `git commit`
# 那一步 fail-closed（磁盘满 / hook 拒绝 / index.lock 被长期占用）时，归档搬迁已落在
# 主干工作树上但未提交。而本脚本只要“finish 本轮没跑 + change 已归档”就会直接接力
# 跑 evolve，跑完就打印终局成功标记 + exit 0 —— 把一个未提交的主干状态洗成全绿
# （下一轮的 finish 还会被它的工作树清洁门禁确定性卡死）。
#
# 为何必须是可复用函数而不是写在自动探测分支里：**两条**入口都能到达同一终态。
#   ① 自动探测（change 目录不在 changes/ 且 archive/ 里有同名归档）；
#   ② 手工 `--skip-loop --skip-finish` —— 而这正是本文件 OPTIONS 里自己推荐的
#     “evolve 挂了单独重跑”路径。已实测：只把断言写在 ① 里时，② 照样输出
#     终局成功标记 + exit 0，而 `git status` 里归档搬迁仍未提交。
#
# pathspec 必须**只钉本次搬迁的足迹**：archive 整目录 + `changes/<本 change 名>`。
# 曾用过 `autopilot/changes` 整目录，已实测会误拦：同仓里另一个进行中的 change
# （analyze/plan 刚产出的 spec.md 尚未提交）会让 `?? autopilot/changes/` 非空 →
# 本已干净收尾的 change 重跑 evolve 被 exit 2，且报错归因到一个不存在的 finish 故障上。
# `:(literal)` 是必需的：change 名来自命令行，含 `*`/`?` 时会被当通配符而误伤旁边目录。
# 已验证：pathspec 指向不存在的路径时 git status 返回 0 且无输出（不会永久卡死），
# 而被删的已跟踪文件仍会以 ` D` 行被窄 pathspec 命中（搬迁真未提交时仍能拦住）。
# archive 侧也只钉**本 change 的归档叶子**：直接钉整个 `autopilot/archive` 会被任何
# 无关残留（手工搬进去的旧归档、编辑器临时文件）误触发。叶子在**每个调用点重算**：
# 同一次运行里 finish 跑过之后才会出现归档叶子，拿启动时的快照会永远看不到它。
# 必须拿**全部**匹配叶子而不是 `head -1`：同一个 change 名在不同日期被归档两次是现实
# 用法（删掉 changes/<feat> 重建再跑一轮），而 find 的输出是目录遍历序、**无序**（已实测）：
# 取到旧叶子时，打印的恢复命令就比真实足迹更窄 → 用户照做只提交了“changes/<name> 被删”，
# 新归档叶子仍是 untracked → 下一次重跑断言通过、打印终局成功标记，而本次变更的
# spec/tasks/summary 从未进入版本控制（随后一条 `git clean` 就永久丢失）。
# find 侧也必须是**固定串**匹配：`-name "...-$CHANGE_NAME"` 会把 change 名当 glob（同一个
# 函数对 git pathspec 特意用了 `:(literal)`，这里不能双标准）：名字含 `*`/`?` 时会误匹配
# 旁边的归档，含 `[` 时 pattern 甚至整体失效。改用 awk 做长度 + 日期前缀 + 整名相等的
# 精确比较（名字走 ENVIRON 而不走 `awk -v`，后者会处理值里的反斜杠转义）。
archived_leaves_rel() {
  [ -d "$CWD/autopilot/archive" ] || return 0
  find "$CWD/autopilot/archive" -maxdepth 4 -type d 2>/dev/null \
    | AP_CHANGE_NAME="$CHANGE_NAME" awk '
        BEGIN { n = ENVIRON["AP_CHANGE_NAME"]; want = length(n) + 11 }
        { b = $0; sub(/^.*\//, "", b)
          if (length(b) == want && substr(b, 12) == n \
              && substr(b, 1, 11) ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-$/) print }' \
    | sort || true
}
# 把一个字串安全包成 shell 单引号字面量。打印的“可直接执行的恢复命令”必须真的可执行：
# 路径或 change 名含单引号时，手拼的 '…' 会提前闭合，用户粘贴后执行到的是意外内容 ——
# 而这条命令恰好是用来指导人工修主干状态的，不可信比没有更坏。
shq() { printf "'%s'" "$(printf '%s' "${1:-}" | sed "s/'/'\\\\''/g")"; }
assert_archive_committed() {
  local pending="" rc=0 specs="" line="" leaves=""
  # bash 3.2 无法把数组从函数里传出，也不能对空数组在 set -u 下安全展开；
  # 用本地数组逐行累加，并保证至少有 CHANGE_REL 一项，展开永不为空。
  local specs_args=()
  leaves="$(archived_leaves_rel)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    line="${line#"$CWD"/}"
    specs_args[${#specs_args[@]}]=":(literal)$line"
    specs="$specs $(shq "$line")"
  done <<EOF
$leaves
EOF
  specs_args[${#specs_args[@]}]=":(literal)$CHANGE_REL"
  specs="${specs# } $(shq "$CHANGE_REL")"
  set +e
  pending="$(cd "$CWD" && git -c core.quotePath=false status --porcelain -- "${specs_args[@]}" 2>/dev/null)"
  rc=$?
  set -e
  # git 自身失败时绝不能当“干净”放行（旧写法 `|| true` 把 rc=128 洗成空输出，
  # 门禁直接退化成装饰）。失败路径上再跑一次拿 git 的原文，不在正常路径上多调一次。
  if [ "$rc" -ne 0 ]; then
    ( cd "$CWD" && git status --porcelain -- ":(literal)$CHANGE_REL" 2>&1 >/dev/null ) | sed 's/^/  git: /' >&2 || true
    echo "ERROR: 无法确认归档是否已提交（git status 退出 rc=${rc}）；不在不确定的前提下接力。" >&2
    exit 2
  fi
  [ -n "$pending" ] || return 0
  echo "$pending" | sed 's/^/  pending: /' >&2
  echo "ERROR: $CHANGE_NAME 已归档，但归档搬迁尚未提交（上一次 finish 在提交那一步失败了）。" >&2
  echo "       不能直接接力跑 evolve：那会把一个未提交的主干状态当成全绿收尾（打印终局成功标记 + exit 0）。" >&2
  # 恢复命令必须与检测范围**逐字对齐**。曾给过 `git add -A -- autopilot`：用户照做会把
  # knowledge 笔记、另一个 change 的半成品、甚至运行期哨兵 `autopilot/.run-active`
  # 一起打包进一条标题为 "archive <name>" 的提交，属于误提交且 message 完全误导后续考古
  # （下方 evolve 提交处的注释已论证过同一道理）。
  echo "       先执行：(cd $(shq "$CWD") && git add -A -- $specs && git commit -m $(shq "chore(autopilot): archive $CHANGE_NAME") -- $specs)，然后重跑本命令。" >&2
  exit 2
}

# 归档探测提到循环外：下面的自动探测分支与 stage 3 前的守卫共用同一份结果。
CHANGE_NAME="$(basename "$CHANGE_DIR")"
# change 目录的**仓内相对路径**：不得写死 "autopilot/changes/<name>"，--change-dir 允许指向
# 别处（测试夹具、非标准布局），写死就会把门禁指向一个不存在的路径而静默退化成装饰。
CHANGE_REL="autopilot/changes/$CHANGE_NAME"
case "$CHANGE_DIR" in "$CWD"/*) CHANGE_REL="${CHANGE_DIR#"$CWD"/}" ;; esac
ARCHIVED=""
if [ ! -d "$CHANGE_DIR" ]; then
  # 归档叶子名形如 YYYY-MM-DD-<name>（SCHEMA C13），必须整名锚定。曾用的
  # "*-$CHANGE_NAME" 是**后缀匹配**：archive 里任何以 -<name> 结尾的历史变更
  # （如 2026-01-01-auth-foo 对查询 foo）都会命中，于是 loop 与 finish 被双双跳过、
  # 却打印 "ALL STAGES DONE" 并 exit 0：什么都没建、没合，却报全绿（已实测复现）。
  # 直接复用 archived_leaves_rel（单一判据），取最新的一份用于日志；
  # 它已含 `|| true`，archive/ 不存在时不会在 set -e + pipefail 下静默退出 1。
  ARCHIVED="$(archived_leaves_rel | tail -1 || true)"
fi

# 可重跑性：finish 成功后 change 目录已被搬进 archive，此时再跑本入口会在 loop 就
# 直接失败（读不到 tasks.md）——于是“只有 evolve 挂了”变成无法从入口恢复，只能手工
# 拼命令。这里按证据自动识别：变更目录不在 changes/ 且 archive/ 里有同名归档，则 loop
# 与 finish 已经完成过，跳过它们直接跑 evolve。要求“归档确实存在”而不是“目录不在”，
# 是为了不把 --change-dir 拼写错静默当成“已完成”。
if [ ! -d "$CHANGE_DIR" ] && ! $SKIP_LOOP; then
  if [ -n "$ARCHIVED" ]; then
    # 早失败优于晚失败：在打任何开工日志之前就把“已归档但未提交”拦下。
    # stage 3 前还有一道同函数的守卫，负责盖住 `--skip-loop --skip-finish` 那条入口。
    assert_archive_committed
    SKIP_LOOP=true
    $SKIP_FINISH || SKIP_FINISH=true
    log "change already archived ($ARCHIVED) → loop + finish already done; resuming at evolve"
  else
    echo "ERROR: change dir not found: $CHANGE_DIR" >&2
    echo "       (也没在 $CWD/autopilot/archive 下找到 YYYY-MM-DD-$CHANGE_NAME 形式的归档；拼写错了？)" >&2
    exit 1
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
# ↑上方那道断言只盖得住自动探测入口。这里再守一次，盖住**其余所有**入口：
#   ① 显式 `--skip-loop --skip-finish`（OPTIONS 里自己推荐的单跑 evolve 姿势）；
#   ② `AUTOPILOT_FINISH_MODE=worker` 时 finish 走 agent 路径 —— worker 面对一个已归档的
#     change 很可能直接回 FINISH_STATUS=DONE（它不做工作树清洁校验），于是“finish 跑了且报
#     成功”但搬迁仍未提交。所以判据不能是 `$SKIP_FINISH`（那会漏掉 ②），而是当前
#     事实：**change 目录已不在位**就必须确认那次搬迁已落入版本控制。
# 确定性 finish 正常成功时本断言是空操作（它已经提交过）。
# 必须放在 `if $SKIP_EVOLVE` **之前**：带 --skip-evolve 时也会走到末尾打终局成功标记，
# 而那同样是把未提交的主干状态报成全绿。
if [ ! -d "$CHANGE_DIR" ]; then
  assert_archive_committed
fi
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
  # 脏检查本身也不得 fail-open：旧写法 `2>/dev/null || true` 把 git 的 rc=128（index 不可读 /
  # 权限 / 并发 gc）洗成空串 → 整个提交块被跳过 → 产物已落盘未提交却一路跑到终局
  # 成功标记 + exit 0，与上方归档断言、finish gate 2 认定不可接受的形态完全同类。
  set +e
  KN_DIRTY="$(cd "$CWD" && git status --porcelain -- autopilot/knowledge 2>/dev/null)"
  KN_DIRTY_RC=$?
  set -e
  if [ "$KN_DIRTY_RC" -ne 0 ]; then
    ( cd "$CWD" && git status --porcelain -- autopilot/knowledge 2>&1 >/dev/null ) | sed 's/^/  git: /' >&2 || true
    log "  evolve BLOCKED: 无法确认知识产物是否已提交（git status rc=${KN_DIRTY_RC}）→ stop (fail-closed)"
    exit 2
  fi
  if [ -n "$KN_DIRTY" ]; then
    # commit 也必须钉住 pathspec。`git add` 限定了路径，但 `git commit -m` 提交的是
    # **整个 index** —— 只要进入 evolve 时 index 里已有其他人暂存的内容（走 worker 路径的
    # finish 自己 git add 后未提交、上一次 commit 失败留下的暂存、或 evolve worker 无视
    # “不要碰 git”的指令做了 git add），这些无关改动就会被静默打包进一条标题为
    # “docs(knowledge): evolve <name>” 的提交并随后被合入主干 —— 属于误提交，
    # 且 message 完全误导后续的 code archaeology。
    #
    # 失败必须 fail-closed 而不是只打 WARN：旧写法跑完照样打终局成功标记 + exit 0，
    # 而知识产物已落盘未提交 —— 这正是本文件上方归档断言认定不可接受的形态（先改盘、
    # 提交失败、却报全绿），只是换了个目录；而且 `>/dev/null 2>&1` 把唯一的原因
    # （hook 拒绝 vs 磁盘满 vs 锁占用）全丢了，故障被推迟到**下一个**变更的 finish
    # gate 2 上突然 BLOCKED，那时已无线索。
    set +e
    KN_ERR="$( cd "$CWD" && git add -A -- autopilot/knowledge 2>&1 \
      && git commit -m "docs(knowledge): evolve $CHANGE_NAME" -- autopilot/knowledge 2>&1 )"
    KN_RC=$?
    set -e
    if [ "$KN_RC" -eq 0 ]; then
      log "  evolve: committed the knowledge artifacts"
    else
      printf '%s\n' "$KN_ERR" | sed 's/^/  git: /' >&2
      log "  evolve BLOCKED: 知识产物已写盘但提交失败（rc=${KN_RC}）→ stop (fail-closed)"
      log "  恢复：(cd $(shq "$CWD") && git add -A -- autopilot/knowledge && git commit -m $(shq "docs(knowledge): evolve $CHANGE_NAME") -- autopilot/knowledge)"
      exit 2
    fi
  fi
  log "  evolve OK"
fi

rm -f "$CWD/autopilot/.run-active" 2>/dev/null || true
log "ALL STAGES DONE ✅ (run-autopilot complete)"
exit 0
