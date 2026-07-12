---
name: autopilot-checkpoint
description: "工作流门禁检查。验证 progress.md 中前置阶段已完成，阻止跳步。每个阶段完成时调用。"
---

# Autopilot Checkpoint — 工作流门禁

在宣告任何阶段完成前，强制检查前置步骤是否已完成。

**宣告**: "正在使用 autopilot-checkpoint 验证工作流完整性。"

## 触发时机

每个子 skill 执行完毕后、标记完成前调用。

- **档位 A（无人值守）**：作为独立门禁读写 `progress.md`（下方 Process）。
- **档位 B（交互）**：退化为**自查**——控制器对照 TodoWrite 与下方前置表确认前置阶段已完成即可，不要求 progress.md 存在。核心不变量（explore / CR / verify / evolve 已发生）仍必须满足。

## Process（档位 A）

### Step 1: 读取 Progress 文件

```bash
cat $CHANGE_DIR/progress.md
```

文件不存在时：
- 档位 A → CHECKPOINT_STATUS=FAIL，提示"progress.md 缺失，请先初始化 autopilot 流程"
- 档位 B → 跳过文件检查，改为自查 TodoWrite 状态（不算 FAIL）

### Step 2: 验证前置阶段

根据当前要完成的阶段，检查其前置是否全部完成（档位 A 看 `[x]`；档位 B 看 TodoWrite 对应项为 COMPLETE）：

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

- 档位 A：将 progress.md 中对应行从 `- [ ] stage` 改为 `- [x] stage (YYYY-MM-DD HH:mm)`
- 档位 B：把 TodoWrite 中对应阶段标为 COMPLETE

### Step 4: 输出

- CHECKPOINT_STATUS=PASS: "阶段 [X] 验证通过，已标记完成"
- CHECKPOINT_STATUS=FAIL: "阻止：前置阶段 [Y] 未完成，必须先执行"

## 约束

- 不可绕过：任何阶段的完成声明必须经过 checkpoint（档位 A 走 skill，档位 B 走等价自查）
- 唯一事实源：档位 A 用 progress.md，档位 B 用 TodoWrite——都不依赖 git log 或记忆
