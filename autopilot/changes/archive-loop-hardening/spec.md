# Spec — archive-loop-hardening (bugfix)

> 修复 archive-knowledge-loop 交付后 CR 标注的 3 个 MINOR，使刚落地的基石机制真正稳固。
> 纯健壮性修复，不改变任何既有对外契约/观测行为。

## 背景

`archive-knowledge-loop` 已合并 master（commit dda7d1d）。CR 与实测暴露 3 个非阻断 MINOR：
1. **#1 生成文件漏入库**：`scripts/archive-change.sh` L122-131 生成 `summary.md` 后未 `git add`，`git mv` 后它以 untracked 残留（实测命中：commit 41af2ea 是手工补的）。每次 finish 都会复现。
2. **#2 evolve 兜底不真跳过**：`skills/autopilot-evolve/SKILL.md` 全局升迁片段 `KB_PATH="$(resolve_script kb-path.sh)" || { echo "跳过…"; }` 失败时只 echo 不 return，下一行 `$KB_PATH --ensure` 会以空路径执行 → 落到 `/raw/...`。仅损坏安装触发，但属真缺陷。
3. **#3 mv 降级可能嵌套**：`archive-change.sh` L143-145 `git mv` 若在部分创建 TARGET 后失败，降级 `mv "$SRC" "$TARGET"` 会把源嵌套进已存在的 TARGET，post-condition 仍误判通过。缺 `[ ! -e "$TARGET" ]` 守卫。

## 修复方案

- **#1**：`archive-change.sh` 移动成功后，若在 git 仓库内，`(cd "$REPO_ROOT" && git add "$TARGET")` 把归档目录（含新生成 summary.md）纳入暂存 → 脚本自包含，调用方无需再 `git add`。
- **#3**：降级 `mv` 前加 `[ ! -e "$TARGET" ]` 守卫；若 TARGET 已存在（git mv 部分失败残留）→ fail-closed（stderr + exit 1），绝不嵌套。
- **#2**：`autopilot-evolve/SKILL.md` 全局升迁片段改为真跳过——`resolve_script` 失败即 `return 0`（或 `if [ -n "$KB_PATH" ]` 守卫后续 GLOBAL_KB 写入），空路径绝不继续执行。

## 可观测验收（Observable Acceptance）

| # | 可观测 | SSOT | 不变量 | 判别性蜕变关系 |
|---|--------|------|--------|----------------|
| H1 | 归档后 summary.md 入库状态 | `git ls-files` | 移动后 summary.md 被 git 跟踪 | 造 change（无 summary）→ archive-change.sh → `git ls-files` 含 `<TARGET>/summary.md`（判别：untracked=FAIL） |
| H3 | TARGET 预存在时行为 | archive-change.sh exit code | TARGET 已存在且源仍在 → fail-closed，绝不嵌套 | 预建同名 TARGET（非幂等场景）+ 源存在 → 期望不把源嵌套进 TARGET（判别：TARGET 内出现嵌套源=FAIL） |
| H2 | evolve 兜底 | SKILL 文本逻辑 | resolve 失败 → 真跳过，不以空路径执行 | CR 核验片段：失败分支 `return 0`/`if` 守卫，空 `$KB_PATH` 不进入 `--ensure`（grep 接线 + CR 逻辑核验） |

**Verify 落地**：H1/H3 → 扩展 `smoke-archive-change.sh` 断言（即 Task 1 的 `**Verify**`）；H2 → grep 接线 + CR 逻辑核验（Task 2）。全部离线可验证，无 UNVERIFIED-OBSERVABLE。

## 约束遵循

- C6/C8 shell 可移植（bash 3.2、`pwd -P`、无 GNU-only）；C7 每处改动有 token-free 冒烟；C10 确定性脚本；C11 控制器不内联写码（本 spec 为 .md 产物，实现经 run-track-a.sh 托管）。
- 不改 archive-change.sh 的既有对外行为（幂等/XOR/fail-closed 语义保持），只补全 #1/#3。
