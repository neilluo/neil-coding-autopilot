#!/usr/bin/env bash
# Zero-token smoke coverage for scripts/finish-change.sh.
#
# WHAT IT LOCKS DOWN: finish is now deterministic (C10), so every gate must be
# provable without a model. The gates exist because finish merges to trunk —
# shipping unreviewed work or merging a dirty tree is unrecoverable damage.
set -uo pipefail
unset AUTOPILOT_RUN_ID

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FINISH="$SCRIPT_DIR/finish-change.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAILED=1; }

# ── fixture: a repo mid-change on a feature branch ──────────────────────────
make_project() {  # $1=task-status  → echoes project dir
  local status="$1" proj chg
  proj="$(mktemp -d "$WORK/proj.XXXXXX")"
  (
    cd "$proj" || exit 1
    git init -q -b master . && git config user.email t@t && git config user.name t
    printf '# fixture\n' > README.md
    git add -A && git commit -qm "chore: scaffold"
    git checkout -q -b feature/thing
  ) >/dev/null 2>&1
  chg="$proj/autopilot/changes/thing"; mkdir -p "$chg"
  {
    echo "# Implementation Tasks — thing"
    echo "> Total tasks: 1"
    echo
    echo "## Task 1: do the thing"
    echo "**Verify**: \`true\`"
    echo "**Status**: $status"
    echo
    echo "---"
  } > "$chg/tasks.md"
  ( cd "$proj" && printf 'thing\n' > thing.txt && git add -A && git commit -qm "feat: thing" ) >/dev/null 2>&1
  printf '%s' "$proj"
}

run_finish() {  # $1=proj  ... extra args → sets RC/OUT
  local proj="$1"; shift
  set +e
  OUT="$(bash "$FINISH" --change-dir "$proj/autopilot/changes/thing" --cwd "$proj" "$@" 2>&1)"
  RC=$?
  set -e
}

echo "===== Scenario 1: HAPPY (all DONE, clean tree) ====="
P1="$(make_project DONE)"
run_finish "$P1"
[ "$RC" -eq 0 ] && pass "exit 0" || { fail "exit=$RC"; printf '%s\n' "$OUT" | sed 's/^/    | /'; }
printf '%s' "$OUT" | grep -q 'FINISH_STATUS=DONE' && pass "prints FINISH_STATUS=DONE" || fail "missing FINISH_STATUS=DONE"
[ "$(cd "$P1" && git rev-parse --abbrev-ref HEAD)" = master ] && pass "ends on the base branch" || fail "not on base branch"
# 必须是真正的合并提交（双 parent），而不是 fast-forward：否则历史里看不出“这批改动来自哪个变更”。
MERGE_SUBJ="$( cd "$P1" && git log --merges --format=%s 2>/dev/null | head -1 )"
if [ "$MERGE_SUBJ" = "merge: thing" ]; then
  pass "feature branch merged with a real merge commit"
else
  fail "merge commit missing (merges subject='$MERGE_SUBJ')"
  ( cd "$P1" && git log --oneline --graph | head -6 | sed 's/^/    | /' )
fi
[ -f "$P1/thing.txt" ] && pass "feature content present on trunk" || fail "feature content missing on trunk"
# XOR 不变量：change 只能在 archive 或 changes 之一
[ ! -d "$P1/autopilot/changes/thing" ] && pass "change dir left changes/" || fail "change dir still in changes/"
ARCH="$(find "$P1/autopilot/archive" -maxdepth 4 -type d -name '*-thing' 2>/dev/null | head -1)"
[ -n "$ARCH" ] && pass "change landed in the 4-level archive ($(basename "$ARCH"))" || fail "change not archived"
[ -f "$ARCH/summary.md" ] && pass "summary.md exists after archiving" || fail "summary.md missing"
( cd "$P1" && git status --porcelain | grep -q . ) && fail "worktree left dirty" || pass "worktree clean afterwards"
# 幂等：重跑不得报错、也不得重复归档
run_finish "$P1"
# 这里必须是真断言。旧写法 `A && B && pass X || pass Y` 两个分支都调 pass、从不调 fail，
# 无论重跑返回什么（exit 0、静默二次归档、任何回归）这一行必然 PASS —— 它本该钉住的
# 安全属性（归档成功后重跑必须 fail-closed）完全没被校验，只提供了错误的安全感。
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'change dir not found'; then
  pass "re-run is fail-closed, not a silent double-archive"
else
  fail "re-run was NOT fail-closed (rc=$RC, expected 2 + 'change dir not found')"
fi

echo ""
echo "===== Scenario 2: GATE — a Task is not DONE ====="
P2="$(make_project PENDING)"
run_finish "$P2"
[ "$RC" -eq 2 ] && pass "exit 2 (fail-closed)" || fail "exit=$RC (expected 2)"
printf '%s' "$OUT" | grep -q 'not DONE' && pass "reason names the unfinished Task" || fail "reason unclear"
[ "$(cd "$P2" && git rev-parse --abbrev-ref HEAD)" = feature/thing ] && pass "did NOT leave the feature branch" || fail "branch changed despite gate"
( cd "$P2" && git log --oneline master | grep -q 'feat: thing' ) && fail "unreviewed work reached trunk" || pass "nothing merged to trunk"
[ -d "$P2/autopilot/changes/thing" ] && pass "change dir untouched" || fail "change dir moved despite gate"

echo ""
echo "===== Scenario 3: GATE — dirty worktree ====="
P3="$(make_project DONE)"
printf 'uncommitted\n' > "$P3/stray.txt"
run_finish "$P3"
[ "$RC" -eq 2 ] && pass "exit 2 (fail-closed)" || fail "exit=$RC (expected 2)"
printf '%s' "$OUT" | grep -q 'uncommitted changes' && pass "reason names the dirty worktree" || fail "reason unclear"
( cd "$P3" && git log --oneline master | grep -q 'feat: thing' ) && fail "merged despite dirty tree" || pass "nothing merged"

echo ""
echo "===== Scenario 4: base-branch detection (main instead of master) ====="
P4="$(make_project DONE)"
( cd "$P4" && git branch -m master main ) >/dev/null 2>&1
run_finish "$P4"
[ "$RC" -eq 0 ] && pass "exit 0 with 'main' as trunk" || { fail "exit=$RC"; printf '%s\n' "$OUT" | sed 's/^/    | /'; }
[ "$(cd "$P4" && git rev-parse --abbrev-ref HEAD)" = main ] && pass "detected 'main' without hardcoding" || fail "wrong branch after finish"

echo ""
echo "===== Scenario 5: --dry-run writes nothing ====="
P5="$(make_project DONE)"
run_finish "$P5" --dry-run
[ "$RC" -eq 0 ] && pass "exit 0" || fail "exit=$RC"
printf '%s' "$OUT" | grep -q 'DRY-RUN' && pass "announces dry-run" || fail "no dry-run notice"
[ "$(cd "$P5" && git rev-parse --abbrev-ref HEAD)" = feature/thing ] && pass "branch untouched" || fail "dry-run switched branches"
[ -d "$P5/autopilot/changes/thing" ] && pass "change dir untouched" || fail "dry-run archived anyway"
# dry-run 最关键的不变量是「绝不碰主干」，而上面四条断言（rc=0 / DRY-RUN 文案 /
# 分支未动 / change dir 仍在）没有任何一条看 master：若 finish-change.sh 回归成
# “dry-run 只跳过归档、merge 照样执行”（dry-run 门禁放错层级是现实回归形态），
# merge 后 HEAD 回到 feature、工作树干净，四条断言全过 —— 而未审查代码并入主干
# 正是本套件自述的不可恢复损害。
( cd "$P5" && git log --oneline master 2>/dev/null | grep -q 'feat: thing' ) && fail "dry-run merged feature into trunk" || pass "trunk untouched by dry-run"
[ -z "$( cd "$P5" && git log --merges --format=%s 2>/dev/null )" ] && pass "dry-run created no merge commit" || fail "dry-run created a merge commit"

echo ""
echo "===== Scenario 6: merge conflict is fail-closed and restores state ====="
P6="$(make_project DONE)"
# 让 master 与 feature 对同一文件产生冲突
( cd "$P6" && git checkout -q master && printf 'trunk version\n' > thing.txt && git add -A && git commit -qm "feat: trunk thing" && git checkout -q feature/thing ) >/dev/null 2>&1
run_finish "$P6"
[ "$RC" -eq 2 ] && pass "exit 2 on conflict" || fail "exit=$RC (expected 2)"
# 断言升级：不再只查脚本自己的措词，而是要求把 **git 自己的原文**带出来（之前的
# 写法把任何 merge 失败都文案为 "conflicted"，非冲突失败（unrelated histories / hook
# 拒绝 / 磁盘满）会被误诊），并要求显式报告还原结果（旧文案无条件声称
# "branch restored"，而 checkout 自己也可能失败、HEAD 停在主干上）。
printf '%s' "$OUT" | grep -q 'CONFLICT' && pass "reason carries git's own conflict output" || fail "git's real reason was not surfaced"
printf '%s' "$OUT" | grep -q 'restore=ok' && pass "restore result is verified, not assumed" || fail "restore result not reported"
[ "$(cd "$P6" && git rev-parse --abbrev-ref HEAD)" = feature/thing ] && pass "feature branch restored" || fail "left on the wrong branch after conflict"
( cd "$P6" && git status --porcelain | grep -q '^UU' ) && fail "conflict markers left in the worktree" || pass "merge aborted cleanly"
[ -d "$P6/autopilot/changes/thing" ] && pass "change dir not archived on failure" || fail "archived despite conflict"

echo ""
echo "===== Scenario 7: 运行期哨兵 autopilot/.run-active 的四种形态 ====="
# 哨兵是本流水线自己创建的瞬时态文件，也是 guard hooks（guard-bash-write /
# guard-controller-write）判定“运行期”的**唯一依据**。四条约束全都是跨轮审查实测出来的：
#   ① 未跟踪时不得把本道清洁门禁卡死（否则未跑 init 的项目永远完成不了 finish）；
#   ② 任何情形下都不得被提交进归档提交（运行期状态入库 = 误提交 + message 误导）；
#      而已被跟踪且有本地修改时，必须在动仓库之前 fail-closed（git 自己也会拒绝 checkout）；
#   ③ 中途 BLOCKED 时必须仍在（否则在“运行处于失败中间态”时解除了写入门禁）；
#   ④ dry-run 只读，不得删它。
# 另钉住一条反面断言：嵌套路径 `sub/autopilot/.run-active` 不得被误豁免。
sentinel_state() { [ -f "$1/autopilot/.run-active" ] && echo present || echo gone; }

P7A="$(make_project DONE)"; printf 'pid=1\n' > "$P7A/autopilot/.run-active"
run_finish "$P7A"
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'FINISH_STATUS=DONE' && pass "untracked sentinel does not block the clean-tree gate" || { fail "untracked sentinel blocked finish (rc=$RC)"; printf '%s\n' "$OUT" | tail -3 | sed 's/^/    | /'; }
[ "$(sentinel_state "$P7A")" = gone ] && pass "untracked sentinel is dropped at the end" || fail "untracked sentinel survived a successful finish"
[ "$( cd "$P7A" && git log -1 --name-only --format= | grep -c 'run-active' )" = 0 ] && pass "sentinel never enters the archive commit" || fail "sentinel was committed into the archive commit"
[ -z "$( cd "$P7A" && git status --porcelain )" ] && pass "worktree clean after finish" || { fail "worktree left dirty"; ( cd "$P7A" && git status --porcelain ) | sed 's/^/    | /'; }

# ③ 中途 BLOCKED（用 merge 冲突造）时哨兵必须仍在
P7B="$(make_project DONE)"
( cd "$P7B" && git checkout -q master && printf 'trunk\n' > thing.txt && git add -A && git commit -qm "feat: trunk thing" && git checkout -q feature/thing ) >/dev/null 2>&1
printf 'pid=1\n' > "$P7B/autopilot/.run-active"
run_finish "$P7B"
[ "$RC" -eq 2 ] && pass "mid-way BLOCKED (conflict) as expected" || fail "expected exit 2, got $RC"
[ "$(sentinel_state "$P7B")" = present ] && pass "sentinel survives a mid-way BLOCKED (guard window preserved)" || fail "sentinel was dropped while the run was still failing — guard hooks disarmed"

# ④ dry-run 不得删
P7C="$(make_project DONE)"; printf 'pid=1\n' > "$P7C/autopilot/.run-active"
run_finish "$P7C" --dry-run
[ "$(sentinel_state "$P7C")" = present ] && pass "dry-run does not touch the sentinel" || fail "dry-run deleted the sentinel (read-only mode disarmed the guards)"

# ② 已被 git 跟踪且本次被改写：必须 fail-closed（不是豁免），且要点名根因。
# 曾把这种情形也从脏判定里豁免掉，本场景当场拓住：过了 gate 2 之后 `git checkout master`
# 会被 **git 自己**拒绝（local changes would be overwritten）—— 同一个死胡同只是被推迟，
# 报错还更难懂。正确行为：停在动仓库之前（可恢复）+ WARN 告知根因。
P7D="$(make_project DONE)"
printf 'pid=OLD\n' > "$P7D/autopilot/.run-active"
( cd "$P7D" && git add -A -- autopilot/.run-active && git commit -qm "chore: (mistake) track the sentinel" ) >/dev/null 2>&1
printf 'pid=NEW-RUNTIME\n' > "$P7D/autopilot/.run-active"
run_finish "$P7D"
[ "$RC" -eq 2 ] && pass "a tracked+modified sentinel fails closed before touching the repo" || { fail "expected exit 2, got $RC"; printf '%s\n' "$OUT" | tail -3 | sed 's/^/    | /'; }
printf '%s' "$OUT" | grep -q 'WARN: autopilot/.run-active' && pass "names the root cause (tracked runtime file)" || fail "no warning naming the tracked sentinel"
[ "$(cd "$P7D" && git rev-parse --abbrev-ref HEAD)" = feature/thing ] && pass "still on the feature branch (nothing merged)" || fail "branch changed despite the gate"
[ -d "$P7D/autopilot/changes/thing" ] && pass "change dir not archived" || fail "archived despite the gate"
[ "$(sentinel_state "$P7D")" = present ] && pass "tracked sentinel is left alone (no uncommitted deletion)" || fail "deleted a tracked file, leaving an uncommitted deletion"

# 反面：嵌套路径同名文件不得被豁免。
# 必须先在 sub/autopilot/ 里放一个**已跟踪**的占位文件：否则该目录整体未跟踪，
# `git status --porcelain` 会把它折叠成一行 `?? sub/`，全路径行根本不会出现 ——
# 那样本断言对它声称要钉的“过滤器误豁免嵌套路径”回归**零检出力**（恒真）。
P7E="$(make_project DONE)"
mkdir -p "$P7E/sub/autopilot"
printf 'placeholder\n' > "$P7E/sub/autopilot/keep.txt"
( cd "$P7E" && git add -A -- sub && git commit -qm "chore: track sub/autopilot placeholder" ) >/dev/null 2>&1
printf 'x\n' > "$P7E/sub/autopilot/.run-active"
# 先自检夹具：porcelain 必须真的列出全路径行，否则下面的断言仍是恒真的。
( cd "$P7E" && git status --porcelain | grep -q '^?? sub/autopilot/\.run-active$' ) \
  && pass "fixture really produces a nested full-path porcelain line (assertion is meaningful)" \
  || fail "fixture collapsed to '?? sub/' — the nested-path assertion would be vacuous"
run_finish "$P7E"
[ "$RC" -eq 2 ] && pass "a nested */autopilot/.run-active is NOT exempted from the clean gate" || fail "nested sentinel-like path was wrongly exempted (rc=$RC)"

# --cwd 是仓库**子目录**时哨兵仍须被豁免。这里钉的是一个已实测的陷阱：
# `git status --porcelain` 的路径是**仓根相对**的（从子目录跑也一样），而命令行 pathspec
# （含 `:(exclude)`）是**cwd 相对**的。两边混用同一个相对路径时，本场景会因过滤失配
# 而重新变成“未跟踪哨兵把 gate 2 卡成死胡同”。
P7F="$(mktemp -d "$WORK/outer.XXXXXX")"
(
  cd "$P7F" || exit 1
  git init -q -b master . && git config user.email t@t && git config user.name t
  mkdir -p proj/autopilot/changes/thing
  printf '# outer\n' > README.md
  {
    echo "# Implementation Tasks — thing"; echo "> Total tasks: 1"; echo
    echo "## Task 1: do the thing"; echo "**Verify**: \`true\`"; echo "**Status**: DONE"; echo; echo "---"
  } > proj/autopilot/changes/thing/tasks.md
  git add -A && git commit -qm "chore: scaffold"
  git checkout -q -b feature/thing
  printf 'thing\n' > proj/thing.txt && git add -A && git commit -qm "feat: thing"
) >/dev/null 2>&1
printf 'pid=1\n' > "$P7F/proj/autopilot/.run-active"
set +e
OUT="$( cd "$P7F/proj" && bash "$FINISH" --change-dir "$P7F/proj/autopilot/changes/thing" --cwd "$P7F/proj" 2>&1 )"
RC=$?
set -e
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'FINISH_STATUS=DONE' && pass "sentinel is still exempted when --cwd is a repo subdirectory" || { fail "subdir --cwd: sentinel blocked finish (rc=$RC)"; printf '%s\n' "$OUT" | tail -3 | sed 's/^/    | /'; }
[ "$( cd "$P7F" && git log -1 --name-only --format= | grep -c 'run-active' )" = 0 ] && pass "subdir --cwd: sentinel still kept out of the commit" || fail "subdir --cwd: sentinel was committed"

echo ""
if [ "$FAILED" -eq 0 ]; then echo "SMOKE(finish-change): ALL PASS"; exit 0; fi
echo "SMOKE(finish-change): FAILURES"; exit 1
