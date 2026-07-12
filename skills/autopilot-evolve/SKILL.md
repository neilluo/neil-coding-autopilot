---
name: autopilot-evolve
description: "AGENTS.md自进化与知识沉淀。每次autopilot执行结束后，将CR发现的规律性问题和踩坑经验写回项目知识体系，并编译知识库供下次 analyze 读取。"
---

# Autopilot Evolve — 知识沉淀与自进化

每次 autopilot 执行结束后，自动将经验沉淀回项目的 harness 体系，并编译为结构化知识库，供下一次 analyze 阶段读取，减少 Spec 幻觉。

**宣告**: "正在使用 autopilot-evolve 沉淀知识和进化 AGENTS.md。"

> 档位无关：**两档（A 无人值守 / B 交互）都必须执行 evolve**（知识沉淀是不变量）。evolve 只读写知识库文件，机制与档位无关。

## 路径约定

知识库目录路径统一为 `$KNOWLEDGE_DIR`（即 `autopilot/knowledge/`）。

三层结构：
- `$KNOWLEDGE_DIR/SCHEMA.md` — 维护规则 + 项目元数据
- `$KNOWLEDGE_DIR/raw/` — Layer 1: 不可变源（CR发现/踩坑原始记录）
- `$KNOWLEDGE_DIR/wiki/` — Layer 2: LLM 编译产物（entities/concepts/guides/comparisons）
- `$KNOWLEDGE_DIR/references/` — 静态框架性内容

## 核心设计：Karpathy LLM Wiki 三层反哺闭环

```
explore(读 wiki/index.md) → analyze(读 wiki 相关页) → plan → loop → review(发现问题)
     ↑                                                                    │
     └───────────── evolve(写 raw → ingest → 更新 wiki) ────────────────┘
```

evolve 的核心流程：**先写 raw（不可变证据），再编译到 wiki（结构化知识）**。
不允许直接修改 wiki 页面而不留 raw 源。

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

### Step 2: 写入 raw/（不可变源）

将每条经验作为原始证据写入 `$KNOWLEDGE_DIR/raw/`：

**文件命名**: `{YYYYMMDD}-{slug}.md`

**格式**:
```markdown
---
created: YYYY-MM-DD
source: evolve/cr-round-N | evolve/compile-failure | evolve/task-blocked
evidence: primary
---

# [Topic]

## Problem
[问题描述]

## Solution
[解决方式]

## Lesson
[可复用的教训]
```

同时更新 `$KNOWLEDGE_DIR/wiki/inbox.md` 状态为 pending（**若不存在则创建**——init 采用 grow-on-demand 不预建空状态机文件，evolve 首次 ingest 时按需创建 inbox.md/log.md）。

### Step 3: Ingest（raw → wiki 编译）

对每个新写入的 raw 文件执行 2-Step CoT 编译：

**Stage 1 — 分析**：读取 raw 文件，确定：
- 应归入哪个 wiki 分类（entities/concepts/guides/comparisons）
- 是创建新页还是更新现有页
- 相关的现有 wiki 页面（交叉引用）

**Stage 2 — 生成/更新**：
- 创建或更新对应 wiki 页面（带 frontmatter）
- 维护 [[wikilink]] 交叉引用
- 更新 `wiki/index.md` 导航

**分类决策表**：

| 经验类型 | wiki 分类 | 示例 |
|----------|-----------|------|
| 新发现的项目约束/设计原则 | concepts/ | retry-mechanism.md |
| 规律性代码问题 | guides/ | backend-rules.md (追加规则) |
| 架构/模块变更 | entities/ | new-module.md |
| 踩坑记录 | guides/ | pitfall-{topic}.md |
| 方案对比 | comparisons/ | solution-a-vs-b.md |

**回写门禁（防幻觉传播）**：
- 必须有明确来源（raw 文件/官方文档 URL）— **无源不写**
- 纯推理内容标注 `[inferred]`，不得标注 `[primary]`
- 与现有 wiki 矛盾时标注 `[disputed]`，不直接覆盖
- inferred 内容占比不超过 30%

### Step 4: 更新操作日志

更新 `$KNOWLEDGE_DIR/wiki/log.md`（不存在则创建）：

```markdown
| YYYY-MM-DD | Evolve | 新增 N 条 raw，更新 M 页 wiki，新建 K 页 |
```

更新 `$KNOWLEDGE_DIR/wiki/inbox.md`：将 pending 改为 done。

### Step 5: SCHEMA.md 更新（如有新约束/原则）

如果发现新的项目约束或设计原则，追加到 SCHEMA.md 的对应段落：

```bash
# 检查 SCHEMA.md 行数
wc -l $KNOWLEDGE_DIR/SCHEMA.md
# 超过 200 行则要精简（将细节移入 wiki 页面）
```

### Step 6: AGENTS.md 更新（如有架构变更）

```bash
wc -l AGENTS.md
# 超过 150 行则精简（细节移入 wiki/entities/）
```

### Step 7: Lint 建议（条件触发）

检查 `wiki/log.md` 中的 evolve 次数。每 5 次 evolve 后输出建议：

> "建议执行知识库健康检查（lint）：检测矛盾/过时/孤立页/缺页/断链"


### Step 8: 输出

- 状态: `EVOLVE_STATUS=DONE`
- 汇总: "新增 X 条 raw，更新 Y 页 wiki，新建 Z 页，SCHEMA 更新 W 处"

## 约束

- SCHEMA.md 不超过 200 行
- AGENTS.md 不超过 150 行
- 不删除已有 wiki 页面（只更新或归档）
- 不记录密码/密钥/个人信息
- 每次 evolve 单次 ingest 不超过 15 页更新
- raw/ 文件一旦写入不可修改（append-only 语义）
- 回写门禁严格执行：无源不写、推理标 [inferred]、矛盾标 [disputed]

## 完成报告

知识沉淀完成后：
1. 报告 `EVOLVE_STATUS=DONE`
2. 输出最终 autopilot 完成报告（控制器根据状态决定后续清理）

