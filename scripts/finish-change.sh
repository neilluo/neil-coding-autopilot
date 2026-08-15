#!/usr/bin/env bash
# finish-change.sh — deterministic branch completion for a finished autopilot change.
#
# WHY THIS IS NOT AN LLM STEP (spec C10: 确定性工作用确定性脚本):
#   The finish flow is entirely mechanical — check every Task is DONE, merge the
#   feature branch into the detected base, move the change dir into archive/,
#   commit, drop the run sentinel. None of it needs judgement, yet routing it
#   through an agent worker made the unattended pipeline a coin flip: measured on
#   a real run, the finish worker produced no verdict 7/7 attempts (it emitted a
#   preamble line and stopped without executing a single tool), so `run-autopilot`
#   died at stage 2/3 *after* the whole loop had succeeded. Multi-step tool
#   sequences are exactly where headless truncation/silence hits hardest, and
#   there is nothing to gain by paying that risk for `git merge`.
#
# USAGE:
#   finish-change.sh --change-dir DIR [--cwd DIR] [--base BRANCH] [--no-merge] [--dry-run]
#
# EXIT CODES:
#   0  finished (prints FINISH_STATUS=DONE)
#   2  fail-closed gate tripped (prints FINISH_STATUS=BLOCKED: <reason>)
#   1  usage / environment error
#
# PORTABILITY: bash 3.2 (macOS stock); no GNU-only tools.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ARCHIVE_CHANGE="$SCRIPT_DIR/archive-change.sh"

usage() { echo "Usage: finish-change.sh --change-dir DIR [--cwd DIR] [--base BRANCH] [--no-merge] [--dry-run]"; }

CHANGE_DIR=""; CWD=""; BASE=""; DO_MERGE=1; DRY_RUN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --change-dir) [ "$#" -ge 2 ] || { usage >&2; exit 1; }; CHANGE_DIR="$2"; shift 2 ;;
    --cwd) [ "$#" -ge 2 ] || { usage >&2; exit 1; }; CWD="$2"; shift 2 ;;
    --base) [ "$#" -ge 2 ] || { usage >&2; exit 1; }; BASE="$2"; shift 2 ;;
    --no-merge) DO_MERGE=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1 (use --help)" >&2; usage >&2; exit 1 ;;
  esac
done

blocked() { echo "FINISH_STATUS=BLOCKED: $1"; exit 2; }
# git 报错原文里的换行必须压平才能嵌进 blocked 文案：FINISH_STATUS=... 是被
# parse-status.sh **按行锚定**解析的标记行，多行会把下游的判据打乱。
flatten() { printf '%s' "${1:-}" | tr '\n\r' '; ' ; }
# 把一个字串安全包成 shell 单引号字面量（恢复提示里的路径 / change 名可能含单引号，
# 手拼 `'…'` 会提前闭合，让一条专门用来指导人工修主干的命令变得不可信）。
shq() { printf "'%s'" "$(printf '%s' "${1:-}" | sed "s/'/'\\\\''/g")"; }

[ -n "$CHANGE_DIR" ] || { usage >&2; exit 1; }
# --change-dir 必须先绝对化（按**调用时的 cwd**解析，这才是命令行相对路径的语义）。
# 否则两拨解析会错位：下方 gate 1/2 在调用目录下读 tasks.md，而 `cd "$CWD"` 之后的
# archive 与 XOR 校验却在 $CWD 下解析同一个相对路径 —— 若调用目录恰好也有同名路径
# （另一个 checkout / 备份目录），就会“拿 A 的 tasks.md 验收、对 B 做 merge 与归档”，
# 门禁与被操作对象彻底脱钩。
case "$CHANGE_DIR" in
  /*) ;;
  *) CHANGE_DIR="$(pwd -P)/${CHANGE_DIR#./}" ;;
esac
[ -d "$CHANGE_DIR" ] || blocked "change dir not found: $CHANGE_DIR"
# 两侧都归一到**物理路径**（pwd -P）。下方要拿 `$CHANGE_DIR` 与 `$CWD` 做前缀比较来推导
# 提交范围，而调用方很容易两边给不同形式：run-autopilot 会把 `--cwd` 归一成 `pwd -P`
# （macOS 上 /var → /private/var）却原样透传绝对的 `--change-dir`。不归一时前缀比较必失败，
# 已实测：标准布局的 finish 会被自己的布局校验全部拒掉（smoke 一片红）。
# 归一到物理路径也正好与 archive-change.sh 内部的 `PARENT_ABS="$(cd … && pwd -P)"` 一致。
# 归一走临时变量：直接 `X="$(cd "$X" && pwd -P)" || blocked "… $X"` 时，命令替换失败会先把 X
# 赋成空串，于是报错文案里的路径变成空白 —— 正好在排障最需要路径的失败现场把它丢掉。
_p="$(cd "$CHANGE_DIR" && pwd -P)" || blocked "cannot resolve change dir: $CHANGE_DIR"
CHANGE_DIR="$_p"
[ -x "$ARCHIVE_CHANGE" ] || [ -f "$ARCHIVE_CHANGE" ] || blocked "missing sibling script: $ARCHIVE_CHANGE"
if [ -z "$CWD" ]; then
  # change-dir is expected at <repo>/autopilot/changes/<name>
  CWD="$(cd "$CHANGE_DIR/../../.." && pwd -P)"
fi
[ -d "$CWD" ] || blocked "cwd not a directory: $CWD"
_p="$(cd "$CWD" && pwd -P)" || blocked "cannot resolve cwd: $CWD"
CWD="$_p"
TASKS_FILE="$CHANGE_DIR/tasks.md"
[ -f "$TASKS_FILE" ] || blocked "tasks.md not found in $CHANGE_DIR"

# ── gate 1: every Task must be DONE ─────────────────────────────────────────
# Anything not DONE means the loop did not finish (or fail-closed mid-way), so
# merging would ship unreviewed/unverified work.
# gate 1 已并入下方的**块感知**单一扫描（参见其注释）。曾用无块概念的全文件 grep，
# 有两条已实测的毛病：
#   ① tasks.md 最后一个 `---` 之后的附录/模板里只要有一行顶格 `**Status**: PENDING`，
#     就报 not DONE 并 exit 2 —— 而 loop 侧的 task_block 看不见 `---` 之后的内容、永远不会改它；
#   ② 它要求 DONE 后紧跟行尾，而 loop 的 task_status 只要行里包含 DONE 就算 DONE：
#     本仓真实存在 `**Status**: DONE (side-change cost-latency-classifier)`，
#     旧 gate 1 会把该文件直接卡死（已实测）。
# 上面的 gate 1 只能校验**已经存在的**状态行；一个根本没有状态行的 Task 对它而言
# 是隐形的。而 TASK_COUNT 下限只要求 >=1，于是“10 个 Task 里只有 1 个写了 DONE”也能
# 过闸。已实测复现：tasks.md 中 Task 2 不带状态行时，本脚本直接 merge 到主干并输出
# FINISH_STATUS=DONE —— 未实现/未审查的分支就这么进了主干（最高危的假成功）。
# 因此补一道「每个 Task 段落恰好一条状态行」的配对门禁（fail-closed）。
# 只比**总数**是不够的：只要文件里多出一条“多余的”顶格 `**Status**:` 行
# （本仓就是大量在文档/模板里书写状态标记的项目，tasks.md 里出现示例状态行很现实），
# 就能把缺失的那条补平：`## Task 1`（无状态行）+ `## Task 2` + 一条示例状态行
# → 总数 2==2 过闸，而 gate 1 又看不见 Task 1 → 未实现的 Task 1 照样合进主干。
# 标题判据与 run-track-a.sh 枚举 Task 的判据逐字对齐（`^## Task N:`），不自创：
# 曾用过宽的 `^#{2,3}...Task...` 会把 `### Task 4 增补` 这种**子小节**也当成 Task，
# 已实测会把本仓真实的 autopilot/changes/autopilot-cost-latency/tasks.md 永久卡在 BLOCKED。
# 分块规则必须与单一事实源 run-track-a.sh 的 `task_block` 完全一致：它以下一个
# `^## Task N:` **或 `^---$`** 作为块结束。漏了 `---` 会把最后一个 `---` 之后的任何
# 顶格 `**Status**:` 行（附录/模板示例，包括围栏代码块里的示例）算进最后一个 Task，
# 使其 n=2 → blocked：而读侧（loop 的 task_block）根本看不见 `---` 之后的内容，
# 于是 loop 刚全绿、finish 却确定性 BLOCKED 且重跑无解 —— 与上文「### Task 4 增补
# 误拦」是同一模式（判据自创、与 SSOT 脱钩）。
GATE_DIAG="$(awk '
  function settle() {
    if (n != 1) {
      bad = 1
      printf "  Task at line %d: found %d top-level \"**Status**:\" line(s), want exactly 1\n", hdrline, n
    } else if (sval != "DONE" && sval != "DONE_WITH_CONCERNS") {
      bad = 1
      printf "  unfinished: line %d: %s\n", sline, stext
    }
  }
  /^## Task [0-9]+:/ { if (seen) settle(); seen = 1; n = 0; any = 1; hdrline = FNR; sval = ""; next }
  /^---$/            { if (seen) settle(); seen = 0; next }
  seen && /^\*\*Status\*\*:/ {
    n++; sline = FNR; stext = $0
    v = $0
    sub(/^\*\*Status\*\*:[[:space:]]*/, "", v)
    if (v ~ /^DONE_WITH_CONCERNS([[:space:]].*)?$/)  sval = "DONE_WITH_CONCERNS"
    else if (v ~ /^DONE([[:space:]].*)?$/)           sval = "DONE"
    else { sub(/[[:space:]].*$/, "", v); sval = v }
  }
  END { if (seen) settle(); if (!any) exit 2; if (bad) exit 1; exit 0 }
' "$TASKS_FILE")"
GATE_RC=$?
if [ "$GATE_RC" -eq 2 ]; then
  blocked "tasks.md declares no '## Task N:' headings"
elif [ "$GATE_RC" -ne 0 ]; then
  printf '%s\n' "$GATE_DIAG" >&2
  # 保留 "not DONE" 这个稳定英文标记：smoke-finish-change.sh 的「gate 理由要点名未完成 Task」
  # 用于它做断言（改措辞就会让那条断言失效——已实测到），其他消费方也可能 grep 它。
  # 具体是“哪一行不对”由上方 stderr 的诊断行给出（带行号与原文）。
  blocked "tasks.md still has Task(s) that are not DONE, or Task/'**Status**:' lines do not pair 1:1"
fi

cd "$CWD" || blocked "cannot enter cwd: $CWD"
git rev-parse --git-dir >/dev/null 2>&1 || blocked "not a git repository: $CWD"

# ── 预检 index.lock：必须在**动仓库之前**拦住 ──────────────────────────
# 下方 `git add -A` 失败时的 fail-closed 位于 merge + 归档 mv 之后，而那个位置的 BLOCKED
# 是**不可自动恢复**的：重跑时 run-autopilot 按「change 已归档 → 跳过 loop+finish」
# 的语义根本不会再调 finish，那次搬迁就永远不会被提交；直接手工重跑 finish-change 也
# 会在「change dir not found」处被拒。于是“fail-closed 之后重跑”反而会洗成假成功（主干上
# 留着未提交的归档搬迁）。因此把最常见的诱因（worker 异常退出残留 index.lock）
# 提前到任何仓库变更之前检测：此时停下来是完全可恢复的。
GIT_DIR_PATH="$(git rev-parse --git-dir 2>/dev/null || true)"
# index.lock 不只由「异常退出残留」产生：任何刷新索引的并发 git（编辑器的 git 集成
# 轮询 `git status`、另一个终端、loop 刚提交后的后台维护）都会**瞬时**创建它。
# 所以不能单次采样就 blocked —— 那会把一个亚秒级窗口变成「整条无人值守流水线
# 在 loop 全部成功后死在 finish」的偶发中断（本文件开头就说了：finish 存在的理由
# 就是别让这一步变成掷硬币）。改成有界等待 + 龄期判据：消失就继续（只打 WARN），
# 仍存在且足够老才当成残留而 blocked。
INDEX_LOCK=""
[ -z "$GIT_DIR_PATH" ] || INDEX_LOCK="$GIT_DIR_PATH/index.lock"
LOCK_WAIT_TRIES="${AUTOPILOT_INDEX_LOCK_TRIES:-30}"
LOCK_STALE_S="${AUTOPILOT_INDEX_LOCK_STALE_S:-60}"
case "$LOCK_WAIT_TRIES" in ''|*[!0-9]*) LOCK_WAIT_TRIES=30 ;; esac
case "$LOCK_STALE_S" in ''|*[!0-9]*) LOCK_STALE_S=60 ;; esac
_index_lock_age_s() {
  local born now
  [ -n "$INDEX_LOCK" ] && [ -e "$INDEX_LOCK" ] || { echo 0; return 0; }
  if [ "${OSTYPE:-}" != "${OSTYPE#darwin}" ]; then
    born="$(stat -f '%m' "$INDEX_LOCK" 2>/dev/null || echo 0)"
  else
    born="$(stat -c '%Y' "$INDEX_LOCK" 2>/dev/null || echo 0)"
  fi
  case "$born" in ''|*[!0-9]*) born=0 ;; esac
  now="$(date +%s 2>/dev/null || echo 0)"
  if [ "$born" -gt 0 ] && [ "$now" -gt "$born" ]; then echo $(( now - born )); else echo 0; fi
}
# 有界等待 index.lock 消失。返回 0=无锁（或本仓没有 git-dir），1=仍存在。
# 抽成函数是因为它有**两个**调用点：动仓库前的预检，以及下方 `git add -A` 失败后的
# 重试（那个位置已经 merge+归档过，不能一失败就把流水线钉死在不可恢复态上）。
# 返回 1 时把**原因**放进 LOCK_EXIT_REASON：两种情形的排障动作完全不同，而旧文案
# 无论哪种都说“等了 ~15s”—— 锁已经很老时函数在 i=0 处立即 break，一秒没等却声称等满超时。
LOCK_EXIT_REASON=""
wait_index_lock() {
  local i=0
  LOCK_EXIT_REASON=""
  [ -n "$INDEX_LOCK" ] || return 0
  while [ -e "$INDEX_LOCK" ] && [ "$i" -lt "$LOCK_WAIT_TRIES" ]; do
    if [ "$(_index_lock_age_s)" -gt "$LOCK_STALE_S" ]; then LOCK_EXIT_REASON="stale:~$(( i / 2 ))s"; break; fi
    sleep 0.5
    i=$((i + 1))
  done
  [ "$i" -eq 0 ] || echo "  WARN: 等待 index.lock 释放耗时 ~$(( i / 2 ))s（有并发 git 在访问本仓）" >&2
  if [ -n "$INDEX_LOCK" ] && [ -e "$INDEX_LOCK" ]; then
    [ -n "$LOCK_EXIT_REASON" ] || LOCK_EXIT_REASON="held:~$(( i / 2 ))s"
    return 1
  fi
  return 0
}
if ! wait_index_lock; then
  case "$LOCK_EXIT_REASON" in
    stale:*) blocked "$INDEX_LOCK 已存在超过 ${LOCK_STALE_S}s（判为 worker 异常退出残留；本次实际等了 ${LOCK_EXIT_REASON#stale:}）；先删掉它再跑 finish —— 现在停在动仓库之前，是可恢复的" ;;
    *)       blocked "$INDEX_LOCK 在等满 ${LOCK_EXIT_REASON#held:} 后仍未释放（有并发 git 一直持有它）；先让那个进程收工再跑 finish —— 现在停在动仓库之前，是可恢复的" ;;
  esac
fi

# ── gate 2: worktree must be clean ──────────────────────────────────────────
# run-track-a commits after every Task, so leftovers mean something unexpected
# happened (a silent worker's half-edit, a stray file). Never merge blind.
# 一个例外：运行期哨兵 `autopilot/.run-active`。它本就是本流水线自己创建的瞬时态文件，
# 且本脚本收尾就会删它。项目跑过 init 时它已在 .gitignore 里（autopilot-init 会
# `ensure_ignore 'autopilot/.run-active'`），但**未初始化的消费项目**里它是未跟踪文件 ——
# 已实测：那时本道门禁会每次都以 `?? autopilot/.run-active` 报 BLOCKED，交互档永远无法
# 完成 finish（一个死胡同）。
# 处理原则（三条，缺一不可）：
#   ① **不在这里删它**。哨兵是 hooks（guard-bash-write / guard-controller-write）判定“运行期”
#     的唯一依据，而 gate 2 之后还有 merge / 归档 / 提交 三步都可能 BLOCKED；提前删掉
#     等于在“运行仍处于失败中间态”时解除写入门禁（dry-run 只读探测更不该有这个副作用）。
#     删除回到文件末尾（所有门禁均已通过、提交已完成之后），且只删未跟踪的。
#   ② 脏判定里只忽略**未跟踪**的它：否则未初始化项目里它作为未跟踪文件会让本道门禁每次都以
#     `?? autopilot/.run-active` 报 BLOCKED，交互档永远完成不了 finish（一个死胡同）。
#     已跟踪且有修改时不豁免 —— 那是真脏，git 自己就会拒绝后续的 checkout（已实测）。
#   ③ 提交范围里**无条件排除**它：已实测（且三个审查模型一致指出）哨兵被跟踪且本次运行
#     改写过它时，`git add -A -- $SCOPE_SPEC` 会把 `pid=…` 这种运行期状态提交进标题为
#     “chore(autopilot): archive <name>” 的提交 —— 误提交 + message 完全误导。
#     `:(exclude)` 已验证对 add / diff --cached / commit 三者均有效，SCOPE_SPEC 为 `.` 时也生效。
SENTINEL_PATH="$CWD/autopilot/.run-active"
SENTINEL_REL="autopilot/.run-active"
SENTINEL_TRACKED=0
# 只有 rc==1 才是“确定未跟踪”；其他非零退出（git 自身出错）是“不确定”，不能当未跟踪 ——
# 否则文件末尾的 `rm -f` 可能删掉一个已跟踪的哨兵并留下未提交的删除。
git ls-files --error-unmatch -- "$SENTINEL_PATH" >/dev/null 2>&1
case "$?" in
  0) SENTINEL_TRACKED=1 ;;
  1) SENTINEL_TRACKED=0 ;;
  *) SENTINEL_TRACKED=unknown ;;
esac
# **两个锚不同，必须分开算**（均已实测）：
#   · `git status --porcelain` 的路径是**仓根相对**的（从子目录跑也一样）；
#   · 命令行 pathspec（含 `:(exclude)`）是**cwd 相对**的（从 sub/ 传 `:(exclude)autopilot/…`
#     才生效，传 `sub/autopilot/…` 不生效）。
# 混用同一个相对路径会在 `--cwd` 是仓库子目录时让过滤失配 → 未跟踪哨兵又把 gate 2 卡成死胡同。
SENTINEL_EXCLUDE=":(exclude)$SENTINEL_REL"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
SENTINEL_REL_REPO="$SENTINEL_REL"
if [ -n "$REPO_ROOT" ]; then
  case "$SENTINEL_PATH" in "$REPO_ROOT"/*) SENTINEL_REL_REPO="${SENTINEL_PATH#"$REPO_ROOT"/}" ;; esac
fi
# grep 用的是 BRE，而路径里的 `.` 是元字符（`autopilot/.run-active` 能误匹 `autopilot/Xrun-active`）：
# 转义后再拼，否则可能豁免掉一个真正的脏文件。
SENTINEL_RE="$(printf '%s' "$SENTINEL_REL_REPO" | sed 's/[][\.*^$]/\\&/g')"
if [ "$SENTINEL_TRACKED" = 1 ] && [ -e "$SENTINEL_PATH" ]; then
  # 人工修法必须无歧义且**真的能粘贴执行**：pathspec 是 cwd 相对的，而读者很可能在仓根
  # 而不是 $CWD 里执行（`--cwd` 为仓库子目录时两者不同）—— 用 `git -C <cwd>` 钉住执行目录。
  # 第二步用**文字描述**而不给 shell 命令：曾给过 `printf … >> $(git rev-parse --show-toplevel)/.gitignore`，
  # 两个审查模型分别指出它在仓根含空格时会 `ambiguous redirect` 失败、且 .gitignore 模式里的
  # glob 元字符未转义 —— 一条专门用来指导人工收尾的命令，不可靠比没有更坏。
  echo "  WARN: $SENTINEL_REL_REPO 已被 git 跟踪（运行期瞬时态文件不应入库）；本次不删它、也不提交它。人工清理：① 执行 \`git -C $(shq "$CWD") rm --cached $(shq "$SENTINEL_REL")\`；② 把一行 \`$SENTINEL_REL_REPO\` 加到仓库根的 .gitignore 里" >&2
fi
# `git status` 自身失败时不得当“干净”：旧写法 `2>/dev/null || true` 会把 rc=128
# （.git 损坏 / 权限 / index 不可读）洗成空输出，于是本道门禁退化成装饰并直接去 merge。
# 这里不需要（也绝不能用）`set +e; ...; set -e` 包裹：本脚本全程跑在 `set -uo pipefail`
# 下、**有意不开 -e**（靠显式 `|| blocked` 控制流），跑一句 `set -e` 会把它后面
# 所有语句的语义都改掉（任何非零返回就静默退出，连 FINISH_STATUS 都不会打）。
# `core.quotePath=false` 是必需的：仓根到 `--cwd` 之间的路径含非 ASCII 时，porcelain 会把
# 整行用双引号包起并把字节转义成 \3xx 形式 → 下方的哨兵过滤失配 → 把一个本应豁免的
# 哨兵误拦成 BLOCKED（跟 review-context.sh 里同一道理，那里已经因中文文件名跌过一次）。
DIRTY="$(git -c core.quotePath=false status --porcelain 2>/dev/null)"
DIRTY_RC=$?
if [ "$DIRTY_RC" -ne 0 ]; then
  git -c core.quotePath=false status --porcelain 2>&1 >/dev/null | sed 's/^/  git: /' >&2 || true
  blocked "git status failed (rc=$DIRTY_RC); 无法确认工作树是否清洁，不在不确定的前提下 merge"
fi
if [ -n "$DIRTY" ]; then
  # 只豁免**未跟踪**的哨兵（porcelain 里的 `?? ` 行）。它对 git 操作是隐形的：checkout /
  # merge 都不会因它而失败，所以豁免它安全，且能解开“未跑 init 的项目永远完成不了 finish”的死胡同。
  # **已跟踪且有本地修改**的哨兵绝不能豁免（曾这么写，已被 smoke 实测拓住）：让它过了本道门禁
  # 之后，`git checkout "$BASE"` 会被 **git 自己**拒绝（“Your local changes … would be
  # overwritten by checkout”）—— 只是把同一个死胡同从 gate 2 推迟到 checkout，报错还更难懂。
  # 那种情形就该在这里 fail-closed：上方的 WARN 已经点名根因与人工修法。
  DIRTY="$(printf '%s\n' "$DIRTY" | grep -v "^?? $SENTINEL_RE\$" || true)"
fi
if [ -n "$DIRTY" ]; then
  echo "$DIRTY" | sed 's/^/  dirty: /' >&2
  blocked "worktree has uncommitted changes; commit or discard them first"
fi

CURRENT="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[ -n "$CURRENT" ] && [ "$CURRENT" != HEAD ] || blocked "detached HEAD; cannot finish"

# ── 提交范围（必须在**动仓库之前**算好）─────────────────────────
# 下方的 `git add`/`git commit` 需要一个能盖住搬迁两侧（changes/ 删除侧 + archive/ 新增侧）
# 的 pathspec。不能裸 `git add -A`：本轮把重试窗口拉长到最多 3×(15s 等锁 + 1s)，而这里已过
# gate 2、之后无人再校验工作树：窗口期间并发进程（编辑器 git 集成、另一个 worker）
# 新落盘的文件会被扫进一条标题为 “chore(autopilot): archive <name>” 的提交并合入主干。
# 也不能写死 `-- autopilot`：--change-dir 允许指向 autopilot/ 之外（测试夹具 / 非标准布局），
# 已实测那时会 `fatal: pathspec 'autopilot' did not match any files` → 本可正常完成的 finish 硬失败。
# 范围与 archive-change.sh **同源推导**：它把归档放在 `dirname(dirname(change-dir))/archive`
# （其 AUTOPILOT_ROOT），而 change 目录就在 `dirname(change-dir)` 下，所以这个共同父目录
# 同时盖住两侧。
#
# 关键：归档根**不在 --cwd 子树内**时必须 fail-closed，绝不能傅会成 `.`。已实测过
# 那个傅会的后果：`--change-dir /repo/autopilot/changes/x --cwd /repo/sub` 时，
# `git add -A -- .` 在 /repo/sub 下什么也暂存不到 → `git diff --cached --quiet` 为真 →
# 走“nothing to commit”→ 照样输出 FINISH_STATUS=DONE exit 0，而 merge 已做、搬迁未提交
# （且上游 run-autopilot 的归档断言在该布局下也找不到叶子、同样傅不住）。
# 不支持的布局就明确拒绝，而且停在这里（merge 之前）是完全可恢复的。
SCOPE_ABS="$(dirname "$(dirname "$CHANGE_DIR")")"
case "$SCOPE_ABS" in
  "$CWD")   SCOPE_SPEC="." ;;                                        # change-dir 恰在仓根下两层：足迹就是整个 CWD 子树
  "$CWD"/*) SCOPE_SPEC=":(literal)${SCOPE_ABS#"$CWD"/}" ;;
  *) blocked "归档根 $SCOPE_ABS 不在 --cwd（${CWD}）之内：无法钉住提交范围（傅会成整仓 '.' 会把搬迁洗成“nothing to commit”的假成功），拒绝在此布局下 finish；请让 --cwd 指向包含 $SCOPE_ABS 的目录 —— 现在停在动仓库之前，是可恢复的" ;;
esac
# 为何 `SCOPE_ABS == CWD` 时接受 `.` 而不再收窄（有意的取舍，不是遗漏）：
# 那种布局下 change 目录就挂在仓根下两层，此时“共同父目录”本身就是仓根。
# 更窄的做法是改传两个精确 pathspec（archive 根 + change 目录），但 `git add` 对
# **匹配不到任何文件的 pathspec 是硬错**（fatal: pathspec did not match）：归档后 change
# 目录已不存在，若它从未被提交过就什么都匹配不到 → 本可正常完成的 finish 变硬失败
# （这正是上一版写死 `-- autopilot` 时实测到的故障）。在“非标准布局 + 并发写入”这个
# 窄窗口里多扫几个文件（P2）比把一条常规路径变成硬失败（P1）代价小得多。

# ── base branch detection (C4: never hardcode the trunk name) ───────────────
if [ -z "$BASE" ]; then
  for candidate in master main; do
    if git show-ref --verify --quiet "refs/heads/$candidate"; then BASE="$candidate"; break; fi
  done
fi
[ -n "$BASE" ] || blocked "cannot detect a base branch (looked for master, main); pass --base"
git show-ref --verify --quiet "refs/heads/$BASE" || blocked "base branch does not exist: $BASE"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY-RUN: would merge '$CURRENT' into '$BASE', archive $CHANGE_DIR, then commit"
  echo "FINISH_STATUS=DONE"
  exit 0
fi

# ── merge feature branch into base (fail-closed on conflict) ────────────────
# checkout / merge 失败时不得把 git 的报错丢进 /dev/null，也不得猜测式归因。
# 旧写法把任何 merge 失败都文案为 “conflicted (merge aborted, branch restored)”：
# 非冲突失败（refusing to merge unrelated histories、pre-merge hook 拒绝、磁盘满）会被
# 误诊为冲突，而 `git checkout "$CURRENT"` 自己也失败时（索引仍带冲突项）文案却声称
# “已还原”，HEAD 可能停在 $BASE 上 —— 排障方向直接跑偏。改成带出 git 原文 + 校验还原结果。
if [ "$DO_MERGE" -eq 1 ] && [ "$CURRENT" != "$BASE" ]; then
  if ! CO_ERR="$(git checkout "$BASE" 2>&1)"; then
    blocked "cannot checkout base branch $BASE: $(flatten "$CO_ERR")"
  fi
  if ! MERGE_ERR="$(git merge --no-ff -m "merge: $(basename "$CHANGE_DIR")" "$CURRENT" 2>&1)"; then
    git merge --abort >/dev/null 2>&1 || true
    RESTORED=ok
    git checkout "$CURRENT" >/dev/null 2>&1 || RESTORED="FAILED (HEAD 仍在 ${BASE}，需人工收尾)"
    blocked "merge of '$CURRENT' into '$BASE' failed (merge aborted, restore=$RESTORED): $(flatten "$MERGE_ERR")"
  fi
  echo "merged '$CURRENT' into '$BASE'"
else
  echo "merge skipped (current=$CURRENT base=$BASE do_merge=$DO_MERGE)"
fi

# ── archive the change dir (delegated; idempotent + XOR invariant) ──────────
if ! ARCHIVE_OUT="$(bash "$ARCHIVE_CHANGE" --change-dir "$CHANGE_DIR" 2>&1)"; then
  echo "$ARCHIVE_OUT" | sed 's/^/  archive: /' >&2
  blocked "archive-change.sh failed"
fi
echo "$ARCHIVE_OUT" | sed 's/^/  archive: /'
[ ! -d "$CHANGE_DIR" ] || blocked "change dir still exists after archiving (XOR invariant violated): $CHANGE_DIR"

# ── commit the archive move ─────────────────────────────────────────────────
# `git add -A` 失败不得吞：典型场景是 `.git/index.lock` 残留或被并发进程持有（无人
# 值守长跑中 worker 异常退出后常见）。旧写法 `|| true` 把它吞掉后，下一行
# `git diff --cached --quiet` 因暂存区为空而返回 0，走“nothing to commit”分支，
# 脚本照样打印 FINISH_STATUS=DONE 并 exit 0 —— 但归档搬迁（archive-change 已执行的 mv）
# 实际未提交、工作树是脏的，上游 run-autopilot 却以为 finish 成功并继续跑 evolve。
#
# 但**只是** fail-closed 还不够：这里已经 merge 进主干、也已经 mv 过归档，此处退出 2 是
# 「不可自动恢复」的 —— 重跑时 run-autopilot 按「change 已归档 → 跳过 loop+finish」
# 的语义不会再调 finish，那次搬迁就永远不会被提交（run-autopilot 侧另加了一道
# 「归档路径仍脏就 fail-closed」的门禁堵这条洗白路径）。所以这里要做两件事：
#   ① 复用上面那套有界等待重试几次，把并发 git 造成的**瞬时**占用磨掉，不为一个
#     亚秒级窗口把整条流水线钉在需要人工介入的状态；
#   ② 真的失败时把 git 自己的报错原文带出来。旧写法 `>/dev/null 2>&1` 把唯一的
#     诊断信息全丢了，只剩一句猜测式的 “index.lock 残留或并发占用？”，而这个位置
#     恰恰是最需要精确原因的地方（磁盘满 / 权限 / hook 拒绝 / gpg 签名失败各有不同解法）。
# 报错原文的换行由上方 flatten() 压平（它紧挨 blocked() 定义，merge 失败处也在用）。
# 提交范围 $SCOPE_SPEC 已在**动仓库之前**算好并校验过（见上方）；add / diff / commit 三处
# 必须用同一个，否则三者范围不一致时会出现“有暂存但提交不到”的碎片态。
RECOVER_HINT="归档搬迁已发生但未提交：先在 $CWD 手工执行 \`git add -A -- $(shq "$SCOPE_SPEC") $(shq "$SENTINEL_EXCLUDE") && git commit -m $(shq "chore(autopilot): archive $(basename "$CHANGE_DIR")") -- $(shq "$SCOPE_SPEC") $(shq "$SENTINEL_EXCLUDE")\`，再重跑（两处 \`:(exclude)\` 不能去，否则会把运行期哨兵提交进去）"
ADD_OK=0; ADD_ERR=""; _try=1
while [ "$_try" -le 3 ]; do
  wait_index_lock || true
  if ADD_ERR="$(git add -A -- "$SCOPE_SPEC" ${SENTINEL_EXCLUDE:+"$SENTINEL_EXCLUDE"} 2>&1)"; then ADD_OK=1; break; fi
  echo "  WARN: git add -A -- $SCOPE_SPEC 失败（尝试 $_try/3）：$(flatten "$ADD_ERR")" >&2
  sleep 1
  _try=$((_try + 1))
done
[ "$ADD_OK" -eq 1 ] || blocked "git add -A failed after 3 tries: $(flatten "$ADD_ERR") — $RECOVER_HINT"
if git diff --cached --quiet -- "$SCOPE_SPEC" ${SENTINEL_EXCLUDE:+"$SENTINEL_EXCLUDE"}; then
  echo "nothing to commit for the archive move"
else
  if ! COMMIT_ERR="$(git commit -m "chore(autopilot): archive $(basename "$CHANGE_DIR")" -- "$SCOPE_SPEC" ${SENTINEL_EXCLUDE:+"$SENTINEL_EXCLUDE"} 2>&1)"; then
    blocked "committing the archive move failed: $(flatten "$COMMIT_ERR") — $RECOVER_HINT"
  fi
  echo "committed the archive move"
fi

# ── drop the run sentinel (idempotent) ─────────────────────────────────────
# 只能在这里删（所有门禁已通过、merge/归档/提交已完成），不能提前：哨兵是 guard hooks
# 判定“运行期”的唯一依据，提前删会在任何中途 BLOCKED（脏树 / 冲突 / 提交失败）之后
# 把写入门禁留在打开状态 —— 而那正是“运行处于失败中间态”、最需要守住的时候；
# dry-run 根本到不了这里（上方已 exit 0），也就不会在只读模式下误删。
# 只删未跟踪的：删一个已跟踪文件会在**提交之后**留下一条未提交的删除 —— 于是本脚本
# 会在“工作树已脏”的状态下输出 FINISH_STATUS=DONE，而下一轮的 gate 2 又会被它卡住。
if [ "$SENTINEL_TRACKED" = 0 ]; then
  rm -f "$SENTINEL_PATH" 2>/dev/null || true
fi

echo "FINISH_STATUS=DONE"
exit 0
