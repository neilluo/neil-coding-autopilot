---
name: autopilot-evolve
description: "AGENTS.md自进化与知识沉淀。每次autopilot执行结束后，将CR发现的规律性问题和踩坑经验写回项目知识体系，并编译知识库供下次 analyze 读取。"
---

# Autopilot Evolve — 知识沉淀与自进化

每次 autopilot 执行结束后，自动将经验沉淀回项目的 harness 体系，并编译为结构化知识库，供下一次 analyze 阶段读取，减少 Spec 幻觉。

**宣告**: "正在使用 autopilot-evolve 沉淀知识和进化 AGENTS.md。"

## 路径约定

知识库目录路径由目标项目的 AGENTS.md 定义，默认为 `harness/`。
控制器在调度前读取目标项目 AGENTS.md 中的 `harness_dir` 配置，如未定义则使用默认值。

```bash
# 控制器读取项目配置，确定 harness 目录
HARNESS_DIR=$(grep -oP 'harness_dir:\s*\K\S+' AGENTS.md 2>/dev/null || echo "harness")
```

下文中所有路径使用 `$HARNESS_DIR` 引用。

## 核心设计：知识反哺闭环

```
analyze(读取 KB) → plan → loop → review(发现问题) → evolve(写回 KB) → 下次 analyze(读取更新后的 KB)
```

evolve 的产出直接成为 analyze 的输入，形成闭环。

## 触发条件

- autopilot-loop 完成后（无论全部完成还是部分完成）
- autopilot-finish 完成后

## Process

### Step 1: 收集本轮经验

从以下来源提取经验：
1. **CR 反馈** — autopilot-review 中发现的规律性问题
2. **编译失败** — 重复出现的编译错误模式
3. **Task BLOCKED** — 阻塞原因和解决方式
4. **新增模块** — 代码架构变更

### Step 2: 分类决策

对每条经验做出决策：

| 经验类型 | 去向 | 条件 |
|----------|------|------|
| 规律性代码问题 | `$HARNESS_DIR/rules/` | 出现2+次的同类问题 |
| 架构/模块变更 | `AGENTS.md` | 新增了模块或改变了项目结构 |
| 踩坑记录 | `$HARNESS_DIR/memory/learnings.md` | 非显而易见的发现 |
| 一次性问题 | 不记录 | 不可复用的特例 |

### Step 3: 执行进化

**3a. AGENTS.md 更新**（如有架构变更）:

```bash
# 检查 AGENTS.md 当前行数
wc -l AGENTS.md
# 如果超过 200 行，先执行衰减
```

**200行上限规则**:
- AGENTS.md 不超过 200 行
- 超过时：将细节移入 `$HARNESS_DIR/docs/`，AGENTS.md 只保留指针
- 旧条目超过 30 天未被引用 → 移入 `$HARNESS_DIR/memory/archive/`

更新内容示例：
```markdown
## Project Structure（更新模块列表）
## Key Commands（更新构建命令）
## Doc Navigation（更新文件导航表）
```

**3b. Rules 更新**（如有规律性问题）:

写入 `$HARNESS_DIR/rules/backend-rules.md`（或对应的规则文件）：

```markdown
## [新规则名称]
**Do**: [正确做法 + 代码示例]
**Don't**: [错误做法]
**Self-check**: [自检方式]
```

**3c. Learnings 追加**（如有踩坑）:

追加到 `$HARNESS_DIR/memory/learnings.md`：

```markdown
## YYYY-MM-DD - [Topic]
**Problem**: [问题描述]
**Solution**: [解决方式]
**Lesson**: [可复用的教训]
```

### Step 4: 编译知识库（核心步骤）

将分散的 rules + learnings 编译为结构化知识库文件，供下次 analyze 直接读取：

**文件位置**: `$HARNESS_DIR/knowledge-base.md`

**编译逻辑**:
1. 读取所有 `$HARNESS_DIR/rules/*.md` 的规则
2. 读取 `$HARNESS_DIR/memory/learnings.md` 的踩坑
3. 提取对 Spec 生成有指导价值的条目，编译为以下格式：

```markdown
# Project Knowledge Base

> Auto-compiled by autopilot-evolve. Read by autopilot-analyze to reduce Spec hallucination.
> Last updated: YYYY-MM-DD

## 已验证的技术决策

- [decision]: [rationale] (来源: Task N / CR)

## 必须遵守的编码规则

- [rule]: [do/don't] (原因: 出现过 N 次同类问题)

## 已知坑点

- [pitfall]: [workaround] (发现时间)

## 项目约束（Spec 生成时必须考虑）

- [constraint]: [reason]
```

**关键设计**:
- 知识库是 **编译产物**，不是原始材料。原始材料在 rules/ 和 learnings.md
- 每次 evolve 重新编译整个文件（而非追加），保证内容不膨胀
- 上限 100 行，超过时只保留最高价值条目
- analyze 读取这个文件后，将内容作为 Spec 生成的约束条件

### Step 5: 验证进化结果

```bash
# AGENTS.md 不超过 200 行
wc -l AGENTS.md | awk '{if ($1 > 200) print "WARNING: AGENTS.md exceeds 200 lines"}'

# 语法检查（确保 Markdown 格式正确）
head -20 AGENTS.md
```

### Step 6: 输出

- 状态: `EVOLVE_STATUS=DONE`
- 汇总: "新增 X 条规则，更新 AGENTS.md Y 处，记录 Z 条踩坑，知识库已重新编译"

## 衰减机制

每次执行 evolve 时，检查 `$HARNESS_DIR/memory/learnings.md`：
- 超过 50 条 → 将最旧的 10 条移到 `archive/`
- 最近 3 个月没有相关代码变更的规则 → 标记为候选归档

## 约束

- AGENTS.md 绝对不超过 200 行
- 不删除已有规则（只归档或更新范围）
- 不记录密码/密钥/个人信息
- 每次 evolve 最多新增 3 条规则（防止膨胀）
