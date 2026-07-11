# Neil Coding Autopilot — Plugin 说明

AI 全托管开发编排器。从需求到部署的全自动开发流水线。

## 架构概览

**执行模型（双档）**:
- **档位 A · 批处理**：qodercli 多进程编排——控制器经 `scripts/dispatch.sh` 为每阶段/工人 spawn 独立实例，各配模型、context 隔离。用于无人值守 / CI / 大型构建。
- **档位 B · 交互**：控制器（当前会话）会话内直接执行，TodoWrite 为单一状态源，不 spawn worker。用于会话内协作 / 中小改动。

两档共享同一套阶段与不变量（explore / CR / verify / evolve）。下方拓扑描述**档位 A**；选档规则见 `skills/using-neil-autopilot/SKILL.md` 的「执行档位」。执行层各 skill（loop/plan/finish/evolve/analyze）已 track-aware，档位差异集中在 `skills/_shared/conventions.md` 的「档位适配表」（单一事实源，不在各 skill 复制两套逻辑）。

**顶层串行流程**:

```
用户需求 → init(cli,条件触发) → explore(控制器) → analyze(cli) → plan(cli) → loop(cli) → finish(cli) → evolve(cli) → Done
```

**loop 内部循环（per task）**:

```
implement(worker-cli) → verify(编译) → review(reviewer-cli) → fix(worker-cli) → commit
```

## 平台配置

每个阶段可独立配置模型，通过环境变量或项目级配置指定：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| AUTOPILOT_PLATFORM | auto | qoder / claude / codex / auto(自动检测，优先级 qoder>claude>codex) |
| AGENT_DISPATCH | scripts/dispatch.sh | 统一调度命令路径 |
| AUTOPILOT_ANALYZE_MODEL | Ultimate | 需求分析阶段模型（需强推理） |
| AUTOPILOT_PLAN_MODEL | Ultimate | Task 拆解阶段模型（需强推理） |
| AUTOPILOT_IMPLEMENTER_MODEL | Performance | 编码型 worker 模型 |
| AUTOPILOT_REVIEWER_MODEL | Ultimate | 审查型 worker 模型 |
| AUTOPILOT_FIXER_MODEL | Performance | 修复型 worker 模型 |
| AUTOPILOT_INIT_MODEL | Performance | Harness 初始化阶段模型 |
| AUTOPILOT_EVOLVE_MODEL | Ultimate | 知识沉淀阶段模型（需强归纳） |
| AUTOPILOT_MAX_PARALLEL | 3 | 最大并行 Task 数 |

**统一调度约定**:
```bash
$AGENT_DISPATCH --model "MODEL" --cwd "$PROJECT_ROOT" \
  --prompt-file /tmp/prompt.md --instruction "任务指令" > /tmp/result.md 2>&1
```

**支持平台**:
- **Qoder**: qodercli -m / -w / --permission-mode bypass_permissions / --attachment / -p
- **Claude Code**: claude -m / -p / --allowedTools / --cwd
- **Codex CLI**: codex --model / --approval-mode full-auto / --quiet

## Skills 清单

| Skill | 层级 | 职责 |
|-------|------|------|
| `using-neil-autopilot` | 入口 | Hook 自动注入 bootstrap context |
| `autopilot-init` | 顶层阶段 | Harness 初始化/审计（AGENTS.md + hooks + knowledge/wiki） |
| `autopilot-explore` | 顶层阶段 | 需求澄清 + 设计方向确认（强制多轮交互） |
| `autopilot-analyze` | 顶层阶段 | 基于 explore 产出生成 Spec + 多轮自检 |
| `autopilot-plan` | 顶层阶段 | 读取 Spec → 拆解原子 Task → 写入 tasks.md |
| `autopilot-loop` | 顶层阶段 | Outer Loop 遍历 Task，Inner Loop 调度 worker |
| `autopilot-review` | loop 内部组件 | OCR Code Review（被 loop 调用，非独立阶段） |
| `autopilot-finish` | 顶层阶段 | 分支合并 + 产物归档 |
| `autopilot-evolve` | 顶层阶段 | 知识三层沉淀（raw → ingest → wiki，从 CR/踩坑回写并编译 wiki） |
| `autopilot-checkpoint` | 门禁 | 工作流状态验证与标记 |

## 调用拓扑

```
[using-neil-autopilot]        ← Hook 注入，当前会话作为控制器
  │
  ├─ qodercli: autopilot-init       ← 独立进程，Harness 初始化（条件触发）
  ├─ autopilot-explore (控制器自身)  ← 多轮交互，产出 explore-notes.md
  ├─ qodercli: autopilot-analyze    ← 独立进程，产出 spec.md
  ├─ qodercli: autopilot-plan       ← 独立进程，产出 tasks.md
  ├─ autopilot-loop (控制器自身)     ← 遍历 tasks，编排调度
  │     ├─ qodercli: implementer    ← worker 进程，写代码
  │     ├─ verify command           ← 控制器执行编译验证
  │     ├─ qodercli: reviewer       ← worker 进程，CR
  │     └─ qodercli: fixer          ← worker 进程，修复问题
  │
  ├─ qodercli: autopilot-finish     ← 独立进程，PR/merge + 归档
  └─ qodercli: autopilot-evolve     ← 独立进程，知识双层沉淀
```

## 产物管理

所有 autopilot 产物统一在 `autopilot/` 目录下管理：

| 目录 | 职责 |
|------|------|
| `autopilot/changes/<name>/` | 当前活跃变更（spec + tasks + progress） |
| `autopilot/archive/` | 已完成的历史变更 |
| `autopilot/knowledge/` | 三层知识库（SCHEMA.md + raw/ + wiki/，Karpathy LLM Wiki 架构） |
| `autopilot/hooks/` | 质量门禁（post-edit + build-gate + pre-completion） |

## 安装方式

```bash
# 使用 neil-skill-installer 安装到 Qoder（用户级）
python3 ~/.qoder/skills/neil-skill-installer/scripts/installer.py install \
  /Users/neil/Desktop/neilcodebase/neil-coding-autopilot \
  --tool qoder --scope user --scope-confirmed
```

## 使用方式

```
/neil-coding-autopilot "按照 spec.md 开发整个项目"
/neil-coding-autopilot "添加XX功能"
/neil-coding-autopilot --issue https://github.com/user/repo/issues/N
```
