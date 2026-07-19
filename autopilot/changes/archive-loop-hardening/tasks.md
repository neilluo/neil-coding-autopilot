# Tasks — archive-loop-hardening

> Global Verify: `for f in scripts/*.sh; do bash -n "$f" || exit 1; done`
> 设计与验收见同目录 `spec.md`。所有脚本改动须 bash 3.2 安全、无 GNU-only、保持既有幂等/XOR/fail-closed 语义。

---

## Task 1: 加固 archive-change.sh（#1 summary 入库 + #3 mv 守卫）+ 扩展冒烟

**Status**: DONE

**目标**: 修复 `scripts/archive-change.sh` 的 #1（生成文件漏入库）与 #3（mv 降级嵌套），并扩展 `scripts/smoke-archive-change.sh` 加判别性断言。

**要做**:
1. 编辑 `scripts/archive-change.sh`：
   - **#1**：移动成功且在 git 仓库内（`$REPO_ROOT` 非空）时，把归档目录纳入 git 暂存，使新生成的 `summary.md` 被跟踪。建议在 post-condition 校验通过后追加：`[ -n "$REPO_ROOT" ] && ( cd "$REPO_ROOT" && git add "$TARGET" ) >/dev/null 2>&1 || true`。（`git mv` 分支本身会 stage 已跟踪文件，但新建的 summary.md 是 untracked，必须显式 add；非 git 的 `mv` 分支无需 add。）
   - **#3**：降级 `mv` 前加守卫——若 `[ -e "$TARGET" ]`（git mv 部分失败已残留 TARGET）则 **fail-closed**：`echo "ERROR: archive-change.sh: git mv failed and TARGET already exists, refusing to nest: $TARGET" >&2; exit 1`，绝不 `mv` 进已存在目录造成嵌套。
   - 保持既有幂等（L110 TARGET 已存在→exit0）、XOR post-condition、fail-closed 语义不变；bash 3.2 安全。
2. 扩展 `scripts/smoke-archive-change.sh`，新增两条断言（token-free，临时 git 仓库内）：
   - **H1**：造一个无 summary.md 的 change → archive-change.sh 移动后，`git -C <repo> ls-files "<TARGET>/summary.md"` 非空（summary.md 已被跟踪）。判别：若 untracked（ls-files 为空）= FAIL。
   - **H3**：先在目标 `archive/<DATE>-<name2>` 预建一个**非空目录**（模拟 git mv 部分失败残留），再对同名 change 跑脚本 → 断言脚本 **exit≠0** 且源目录仍在原位（未被嵌套进 TARGET）。判别：源被 mv 进 TARGET 内 = FAIL。
   - 保留原有 4 场景全绿；新增后仍打印 `SMOKE(archive-change): ALL PASS`；用完清理临时目录。

**Verify**: `bash scripts/smoke-archive-change.sh`

---

## Task 2: 修 evolve 全局升迁兜底（#2 真跳过）+ 全量回归

**Status**: PENDING

**目标**: 修复 `skills/autopilot-evolve/SKILL.md` 全局升迁片段的兜底逻辑，使 `kb-path.sh` 定位失败时**真正跳过**，绝不以空 `$KB_PATH` 继续执行；并确认全套机制无回归。

**要做**:
1. 编辑 `skills/autopilot-evolve/SKILL.md` 的「全局升迁」步骤（约含 `resolve_script kb-path.sh` 与 `$KB_PATH --ensure` 的片段）：
   - 把 `KB_PATH="$(resolve_script kb-path.sh)" || { echo "跳过全局升迁：定位不到 kb-path.sh"; }` 改为**真跳过**：失败即 `return 0`（若在函数内）或用 `if [ -n "$KB_PATH" ]; then ... fi` 守卫，确保空 `$KB_PATH` **绝不**进入 `"$KB_PATH" --ensure`，也绝不让 `$GLOBAL_KB` 为空导致写到 `/raw/...`。
   - 仅改这段兜底逻辑；不改 evolve 其它步骤语义；`kb-path.sh` 字面保留（全局升迁接线不变）。
2. 不引入任何脚本回归。

**Verify**: `grep -q kb-path.sh skills/autopilot-evolve/SKILL.md && for s in smoke-dispatch smoke-run-track-a smoke-run-autopilot smoke-kb-path smoke-archive-change smoke-kb-search; do bash scripts/$s.sh >/dev/null 2>&1 || exit 1; done`

---
