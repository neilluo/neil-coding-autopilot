---
name: autopilot-checkpoint
description: "工作流门禁检查。验证 progress.md 中前置阶段已完成，阻止跳步。每个阶段完成时调用。"
---

# Autopilot Checkpoint — 工作流门禁

在宣告任何阶段完成前，强制检查前置步骤是否已标记完成。

**宣告**: "正在使用 autopilot-checkpoint 验证工作流完整性。"

## 触发时机

每个子 skill 执行完毕后、标记完成前，由编排器调用。

## Process

### Step 1: 读取 Progress 文件

```bash
cat $CHANGE_DIR/progress.md
```

如果文件不存在 → CHECKPOINT_STATUS=FAIL，提示"progress.md 缺失，请先初始化 autopilot 流程"

### Step 2: 验证前置阶段

根据当前要完成的阶段，检查其前置是否全部标记 `[x]`：

| 当前阶段 | 必须已完成的前置 |
|---------|---------------|
| init | (无前置) |
| explore | init |
| analyze | explore |
| plan | analyze |
| loop | plan |
| review | (被 loop 内部调用，无独立检查) |
| finish | loop |
| evolve | finish |

如果有前置未完成 → CHECKPOINT_STATUS=FAIL，输出具体缺失项。

### Step 3: 标记当前阶段完成

将 progress.md 中对应行从 `- [ ] stage` 改为 `- [x] stage (YYYY-MM-DD HH:mm)`

### Step 4: 输出

- CHECKPOINT_STATUS=PASS: "阶段 [X] 验证通过，已标记完成"
- CHECKPOINT_STATUS=FAIL: "阻止：前置阶段 [Y] 未完成，必须先执行"

## 约束

- 不可绕过：任何阶段的完成声明必须经过 checkpoint
- progress.md 是唯一事实源：不依赖 git log 或内存判断
