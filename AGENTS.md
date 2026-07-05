# Neil Coding Autopilot — Plugin 说明

AI 全托管开发编排器。从需求到部署的全自动开发流水线。

## 架构概览

**执行模型**: qodercli 多进程编排。当前会话为控制器，每个阶段/工人通过独立 qodercli 实例执行，各实例可配置不同模型，context 完全隔离。

**顶层串行流程**:

```
用户需求 → analyze(cli) → plan(cli) → loop(cli) → finish(cli) → evolve(cli) → Done
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
| `autopilot-analyze` | 顶层阶段 | 需求分析 + Spec 生成 + 多轮自检 |
| `autopilot-plan` | 顶层阶段 | 读取 Spec → 拆解原子 Task → 写入 tasks.md |
| `autopilot-loop` | 顶层阶段 | Outer Loop 遍历 Task，Inner Loop 调度 worker |
| `autopilot-review` | loop 内部组件 | OCR Code Review（被 loop 调用，非独立阶段） |
| `autopilot-finish` | 顶层阶段 | 分支级合并（feature branch → main） |
| `autopilot-evolve` | 顶层阶段 | AGENTS.md 自进化 + 知识沉淀 |

## 调用拓扑

```
[using-neil-autopilot]        ← Hook 注入，当前会话作为控制器
  │
  ├─ qodercli: autopilot-analyze    ← 独立进程，产出 SPEC.md
  ├─ qodercli: autopilot-plan       ← 独立进程，产出 tasks.md
  ├─ autopilot-loop (控制器自身)     ← 遍历 tasks，编排调度
  │     ├─ qodercli: implementer    ← worker 进程，写代码
  │     ├─ verify command           ← 控制器执行编译验证
  │     ├─ qodercli: reviewer       ← worker 进程，CR
  │     └─ qodercli: fixer          ← worker 进程，修复问题
  │
  ├─ qodercli: autopilot-finish     ← 独立进程，PR/merge
  └─ qodercli: autopilot-evolve     ← 独立进程，知识沉淀
```

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
