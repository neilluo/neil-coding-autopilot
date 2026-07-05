---
name: autopilot-finish
description: "分支完成与合并。所有Task完成后，创建PR或直接合并到main，触发CI/CD部署。"
---

# Autopilot Finish — 分支完成与合并

所有 Task 完成且 CR 通过后，处理分支合并和部署触发。

**宣告**: "正在使用 autopilot-finish 完成分支合并。"

## 前置检查（自动执行）

执行本 skill 前，必须确认：
1. `.autopilot/progress.md` 存在
2. 本阶段的前置阶段已标记 `[x]`：loop 必须已完成

如果前置未满足，立即停止并提示需要先执行哪个阶段。

## Process

### Step 1: 验证所有 Task 完成

```bash
# 确认 tasks.md 中没有 PENDING/IN_PROGRESS 状态
grep -c "Status: PENDING\|Status: IN_PROGRESS" tasks.md
# 期望输出: 0
```

如果有未完成 Task → FINISH_STATUS=BLOCKED

### Step 2: 最终验证

```bash
# 运行完整的验证命令
mvn compile -q   # 或项目对应的构建命令
mvn test -q      # 如果有测试

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
gh pr create \
  --title "feat: [feature description]" \
  --body "## Summary\n\nAutopilot implementation of [spec].\n\n## Tasks Completed\n\n[从tasks.md提取完成列表]" \
  --base main
```

**选项 B**: 直接合并（如果用户配置了 auto_merge=true）

```bash
git checkout main
git merge --squash autopilot/feature-name
git commit -m "feat: [feature description]"
git push origin main
```

### Step 5: 确认 CI/CD 触发

如果项目有 `.github/workflows/deploy.yml`：

```bash
# 等待 workflow 触发
gh run list --limit 1
```

### Step 6: 输出

- 状态: `FINISH_STATUS=DONE`
- 产物: PR URL 或合并 commit hash
- 如果有 CI/CD: 报告 workflow 运行状态

## 约束

- 不删除工作分支（保留历史）
- PR 标题遵循 Conventional Commits 格式
- 如果 push 失败（冲突），尝试 rebase 一次，再失败则 BLOCKED

## 强制后继（MANDATORY NEXT STEP）

分支合并完成后：
1. 调用 autopilot-checkpoint 标记 finish 完成
2. 必须立即调用 `Skill("autopilot-evolve")`

警告：finish 之后跳过 evolve 是最常见的违规，知识沉淀是强制的。
