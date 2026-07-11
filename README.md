# Neil Coding Autopilot

AI 全托管开发编排器 — 从需求到部署的全自动开发流水线。

## 简介

Neil Coding Autopilot 是一个 Qoder 插件，支持两种**执行档位**：

- **档位 A · 批处理（Autonomous）**：控制器经 dispatch.sh（其路径按 `skills/_shared/conventions.md`「dispatch.sh 路径解析」解析为绝对路径，跨项目可用）为每个阶段 spawn 独立 qodercli 实例，各配不同模型、context 完全隔离。适合无人值守 / CI / 大型多 Task 构建。
- **档位 B · 交互（Interactive）**：控制器（当前会话）在会话内直接执行各阶段，以 TodoWrite 为单一状态源，不 spawn worker。适合会话内协作 / 中小改动。

**两档执行同一套阶段与不变量**（explore 澄清 / CR / 验证 / evolve 沉淀）：档位只决定「怎么做」，不决定「是否做」。选档规则见 `skills/using-neil-autopilot/SKILL.md` 的「执行档位」。下文架构图描述**档位 A** 的完整多进程编排。

**设计原则**：
- 各 Skill 只负责自身业务逻辑，报告状态后退出
- 路由、前置验证、调度约定、**档位适配表**（执行层档位差异的单一事实源）统一在 `skills/_shared/conventions.md` 和控制器流程图中定义
- `autopilot-checkpoint` 作为门禁机制，在阶段间强制验证（档位 A 走 skill 门禁，档位 B 走 TodoWrite 等价自查）

## 架构

```
用户需求 → init(条件) → explore(澄清) → analyze(Spec) → plan(Tasks) → loop(实现) → finish(合并+归档) → evolve(知识沉淀) → Done
```

```
[控制器 - 当前会话]                        [Worker - 独立 qodercli 实例]
  │                                          │
  ├─ explore (控制器自身) ─────────────►  多轮交互→explore-notes.md
  ├─ qodercli: analyze ──────────────►  产出 spec.md
  ├─ qodercli: plan ─────────────────►  产出 tasks.md
  ├─ loop (控制器自身遍历 tasks)
  │     ├─ qodercli: implementer ──────►  写代码
  │     ├─ verify (控制器执行编译)
  │     ├─ qodercli: reviewer ─────────►  Code Review
  │     └─ qodercli: fixer ────────────►  修复问题
  ├─ qodercli: finish ───────────────►  PR/merge + 归档
  └─ qodercli: evolve ───────────────►  知识双层沉淀
```

| 阶段 | 职责 |
|------|------|
| **explore** | 需求澄清 + 设计方向确认（强制多轮交互，HARD-GATE） |
| **analyze** | 基于 explore 产出生成 Spec + 多轮自检 |
| **plan** | 读取 Spec → 拆解原子 Task → 写入 tasks.md |
| **loop** | Outer Loop 遍历 Task，Inner Loop 调度 worker |
| **finish** | 分支合并 + 产物归档到 archive/ |
| **evolve** | 知识三层沉淀（raw → ingest → wiki，Karpathy LLM Wiki） |

## 安装

```bash
# 方式一：使用 neil-skill-installer（推荐）
python3 ~/.qoder/skills/neil-skill-installer/scripts/installer.py install \
  /path/to/neil-coding-autopilot \
  --tool qoder --scope user --scope-confirmed

# 方式二：直接运行 install.sh
./install.sh
```

## 使用

```bash
# 从需求开始全自动开发
/neil-coding-autopilot "添加用户注册功能，支持邮箱和手机号"

# 按现有 Spec 执行
/neil-coding-autopilot "按照 spec.md 开发整个项目"

# GitHub Issue 驱动
/neil-coding-autopilot --issue https://github.com/user/repo/issues/42
```

## 配置

通过环境变量控制各阶段模型和行为：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `AUTOPILOT_PLATFORM` | auto | qoder / claude / codex / auto（优先级 qoder>claude>codex） |
| `AUTOPILOT_ANALYZE_MODEL` | Ultimate | 需求分析阶段模型（需强推理） |
| `AUTOPILOT_PLAN_MODEL` | Ultimate | Task 拆解阶段模型（需强推理） |
| `AUTOPILOT_IMPLEMENTER_MODEL` | Performance | 编码型 worker 模型 |
| `AUTOPILOT_REVIEWER_MODEL` | Ultimate | 审查型 worker 模型 |
| `AUTOPILOT_FIXER_MODEL` | Performance | 修复型 worker 模型 |
| `AUTOPILOT_EVOLVE_MODEL` | Ultimate | 知识沉淀阶段模型（需强归纳） |
| `AUTOPILOT_MAX_PARALLEL` | 3 | 最大并行 Task 数 |

## 支持平台

- **Qoder** (qodercli)
- **Claude Code** (claude)
- **Codex CLI** (codex)

## 项目结构

```
├── AGENTS.md              # AI Agent 指令文档
├── SKILL.md               # 插件入口声明
├── hooks/                 # Session Hook（自动注入）
├── scripts/               # 调度脚本
└── skills/                # 各阶段 Skill 定义
    ├── _shared/                 # 共享约定（路径/调度/状态/路由）
    ├── using-neil-autopilot/  # 入口编排器
    ├── autopilot-init/       # 项目 Harness 初始化
    ├── autopilot-explore/    # 需求澄清
    ├── autopilot-analyze/    # Spec 生成
    ├── autopilot-plan/       # Task 拆解
    ├── autopilot-loop/       # 双层 Loop 执行器
    ├── autopilot-review/     # Code Review
    ├── autopilot-finish/     # 合并 + 归档
    ├── autopilot-evolve/     # 知识沉淀
    └── autopilot-checkpoint/ # 工作流门禁
```

**目标项目产物目录**（autopilot 执行时在目标项目中创建）：

```
autopilot/
├── changes/<feature>/     # 活跃变更（spec + tasks + progress）
├── archive/              # 已完成历史变更
├── knowledge/            # 三层知识库（SCHEMA.md + raw/ + wiki/）
└── hooks/                # 质量门禁（post-edit + build-gate + pre-completion）
```

## License

MIT
