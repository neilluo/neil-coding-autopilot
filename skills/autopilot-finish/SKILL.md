---
name: autopilot-finish
description: "分支完成与合并。所有Task完成后，创建PR或直接合并到main，触发CI/CD部署。"
---

# Autopilot Finish — 分支完成与合并

所有 Task 完成且 CR 通过后，处理分支合并和部署触发。

**宣告**: "正在使用 autopilot-finish 完成分支合并。"

## Process

> 先按 `_shared/conventions.md` 档位适配表确定状态源（档位 A 读 tasks.md，档位 B 读 TodoWrite），并用其中的 **base 分支自适应** 探测 `$BASE`（不写死 main/master）。

### Step 0: CR 完整性门（fail-closed）

合并前必须确认所有变更都已通过 CR。任一 Task 的 `REVIEW_STATUS ∈ {FAIL, INCOMPLETE}`，或 review 报告有未审文件（见 `autopilot-review` 的 INCOMPLETE）→ `FINISH_STATUS=BLOCKED`，**拒绝合并**。

```bash
# 档位 A：从 tasks.md 检查；档位 B：从 TodoWrite / 本轮 review 结果检查
grep -nE "REVIEW_STATUS: *(FAIL|INCOMPLETE)" $CHANGE_DIR/tasks.md 2>/dev/null && echo "BLOCKED: 存在未过审 / 未审完的 Task"
```

> 原则：**未经审查的变更不得进入 finish**（fail-closed）。这是 `REVIEW_STATUS=INCOMPLETE` 的落地消费点。

### Step 1: 验证所有 Task 完成

```bash
# 确认 tasks.md 中没有 PENDING/IN_PROGRESS 状态
grep -c "Status: PENDING\|Status: IN_PROGRESS" $CHANGE_DIR/tasks.md
# 期望输出: 0
```

如果有未完成 Task → FINISH_STATUS=BLOCKED

### Step 2: 最终验证

```bash
# 优先使用 tasks.md 头部的验证命令（与 loop 阶段保持一致）
VERIFY_CMD=$(grep -m1 "Verify command:" $CHANGE_DIR/tasks.md | sed 's/Verify command: //')
TEST_CMD=$(grep -m1 "Test command:" $CHANGE_DIR/tasks.md | sed 's/Test command: //')

# 编译验证（必须）
${VERIFY_CMD}

# 测试验证（如有配置）
if [ -n "${TEST_CMD}" ]; then
  ${TEST_CMD}
fi

# 确认没有未提交的修改
git status --porcelain
```

### Step 3: 推送分支

```bash
git push origin HEAD
```

### Step 4: 创建 PR 或直接合并

**选项 A（推荐）**: 创建 PR

```bash
# BASE 见 _shared/conventions.md「base 分支自适应」
BASE=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')
[ -z "$BASE" ] && BASE=$(git rev-parse --verify --quiet main >/dev/null && echo main || echo master)

gh pr create \
  --title "feat: [feature description]" \
  --body "## Summary\n\nAutopilot implementation of [spec].\n\n## Tasks Completed\n\n[从tasks.md提取完成列表]" \
  --base "$BASE"
```

**选项 B**: 直接合并（如果用户配置了 auto_merge=true）

```bash
FEATURE_BRANCH=$(git rev-parse --abbrev-ref HEAD)
git checkout "$BASE"
git merge --squash "$FEATURE_BRANCH"
git commit -m "feat: [feature description]"
git push origin "$BASE"
```

### Step 5: 确认 CI/CD 触发

如果项目有 `.github/workflows/deploy.yml`：

```bash
# 等待 workflow 触发
gh run list --limit 1
```

### Step 6: 归档变更产物（硬门禁：确定性搬迁，XOR 不变量）

调用 `scripts/archive-change.sh` 把 `$CHANGE_DIR` **搬迁**（非复制）进 archive；脚本自身幂等 + fail-closed（见 Task 2 spec）。

**不变量**：完成后该变更在 `archive` **XOR** `changes` 中，绝不两处并存（原 `cp` 手法只复制不清理、导致两处并存，是本步要修复的根因缺陷）。

脚本自身用相对 `scripts/` 不可靠（本 skill 运行在业务项目 CWD 下，`scripts/` 会解析到业务项目、不存在）；按 `_shared/conventions.md`「托管脚本路径」的唯一写法直接用绝对路径：

```bash
ARCHIVE_CHANGE="$HOME/.qoder/skills/neil-coding-autopilot/scripts/archive-change.sh"
[ -f "$ARCHIVE_CHANGE" ] || { echo "FINISH_STATUS=BLOCKED: 定位不到 archive-change.sh"; exit 1; }

if ! "$ARCHIVE_CHANGE" --change-dir "$CHANGE_DIR"; then
  echo "FINISH_STATUS=BLOCKED: archive-change.sh 调用失败"
  exit 1
fi

# 双保险：脚本自身已 fail-closed 校验源目录已消失；此处再核验一次
if [ -d "$CHANGE_DIR" ]; then
  echo "FINISH_STATUS=BLOCKED: 归档后 \$CHANGE_DIR 仍存在（XOR 不变量被破坏）"
  exit 1
fi
```

脚本内部已承担「生成 summary.md 骨架（若缺）」的语义，无需在 SKILL 中重复生成。

### Step 6.5: 移除运行期哨兵

autopilot 运行进入收尾，移除「控制器写码硬门禁」哨兵（幂等；evolve 会再移除一次作双保险，避免陈旧残留误锁日常编码）：

```bash
rm -f autopilot/.run-active
```

### Step 7: 输出

- 状态: `FINISH_STATUS=DONE`
- 产物: PR URL 或合并 commit hash，归档目录已创建
- 如果有 CI/CD: 报告 workflow 运行状态

## 约束

- 不删除工作分支（保留历史）
- PR 标题遵循 Conventional Commits 格式
- 如果 push 失败（冲突），尝试 rebase 一次，再失败则 BLOCKED

