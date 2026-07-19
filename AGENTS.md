# Neil Coding Autopilot — Plugin 说明

AI 全托管开发编排器。从需求到部署的全自动开发流水线。

## 架构概览

**执行模型（铁律：控制器永不内联写码，开发一律托管 qodercli）**:
- **档位 A · 无人值守**：explore/analyze/plan headless（或 spec-ready），从终端起 `scripts/run-track-a.sh` 端到端跑 loop，各步 spawn fresh qodercli worker、context 隔离、分角色模型。用于 CI / 无人值守 / 大型构建。
- **档位 B · 交互**：控制器在会话内跟用户跑 explore/analyze/plan/finish/evolve，**loop 同样调 `scripts/run-track-a.sh` 托管开发**（控制器只看日志摘要、不内联写码）。用于会话内协作 / 需求要边聊边澄清。

两档只差"外层阶段是否有人交互"，**开发都经 `run-track-a.sh` 托管给 qodercli**；共享同一套阶段与不变量（explore / CR / verify / evolve）。选档规则见 `skills/using-neil-autopilot/SKILL.md` 的「执行档位」，档位差异集中在 `skills/_shared/conventions.md` 的「档位适配表」（单一事实源）。

`scripts/run-autopilot.sh` 是档位 A 的无人值守端到端入口：编排 loop（`run-track-a.sh`）→ finish → evolve 三阶段，fail-closed（任一阶段 BLOCKED 即停，不接力）；evolve 现会门禁化自动回写 AGENTS.md（见 `autopilot-evolve` Step 6）。

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
| AGENT_DISPATCH | (解析到 plugin 自带绝对路径) | 统一调度脚本；留空则按 `conventions.md`「dispatch.sh 路径解析」推导绝对路径，可设为绝对路径显式覆盖（勿用相对 `scripts/dispatch.sh`） |
| AUTOPILOT_ANALYZE_MODEL | Ultimate | 需求分析阶段模型（需强推理） |
| AUTOPILOT_PLAN_MODEL | Ultimate | Task 拆解阶段模型（需强推理） |
| AUTOPILOT_IMPLEMENTER_MODEL | Performance | 编码型 worker 模型 |
| AUTOPILOT_REVIEWER_MODEL | Ultimate | 审查型 worker 模型 |
| AUTOPILOT_FIXER_MODEL | Performance | 修复型 worker 模型 |
| AUTOPILOT_INIT_MODEL | Performance | Harness 初始化阶段模型 |
| AUTOPILOT_EVOLVE_MODEL | Ultimate | 知识沉淀阶段模型（需强归纳） |
| AUTOPILOT_MAX_PARALLEL | 3 | 最大并行 Task 数 |
| NEIL_AUTOPILOT_LOG_DIR | `$HOME/neil-autopilot-logs-analysis` | 遥测日志根（落在业务 CWD 内自动降级到 $TMPDIR） |
| NEIL_AUTOPILOT_TELEMETRY | 1 | 设 0 全局关闭遥测（fail-safe 开关） |
| NEIL_AUTOPILOT_KEEP_DAYS | 3 | runs/ 原始日志保留天数（metrics/reports 长期保留） |
| NEIL_AUTOPILOT_LOG_SINK | file | telemetry 写入后端；云端保险/未来 OSS/SLS 扩展点，未识别值兜底回退 file |
| AUTOPILOT_DAILY_MODEL | Ultimate | 每日 analysis agent 模型 |

**统一调度约定**:
```bash
$AGENT_DISPATCH --model "MODEL" --cwd "$PROJECT_ROOT" \
  --prompt-file /tmp/prompt.md --instruction "任务指令" > /tmp/result.md 2>&1
```

**支持平台**:
- **Qoder**: qodercli -m / -w / --permission-mode bypass_permissions / --attachment / -p
- **Claude Code**: claude -m / -p / --allowedTools / --cwd
- **Codex CLI**: codex --model / --approval-mode full-auto / --quiet

## 可观测性脚本（数据驱动自进化，见 spec: agent-observability）

| 脚本 | 职责 |
|------|------|
| `scripts/telemetry.sh` | 可 source 的遥测 lib：emit/rotate/log_root，写侧零依赖、fail-safe（绝不污染 stdout / 不改 exit code） |
| `scripts/daily-analysis.sh` | 每日编排：rotate runs/ → jq 聚合 metrics/ → dispatch 1 个 analysis agent 写 reports/（硬依赖 jq） |
| `scripts/install-daily-schedule.sh` | 生成/加载每日 13:00 定时任务（macOS launchd plist / Linux crontab），固化 LOG_DIR + PATH |

系统只产出**建议**（reports/，针对插件自身角色 prompt），改不改永远人工批准，绝不自动改自己。

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
| `autopilot-evolve` | 顶层阶段 | 知识三层沉淀（raw → ingest → wiki）+ 门禁化回写 AGENTS.md（Step 6，见 L13） |
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
  └─ qodercli: autopilot-evolve     ← 独立进程，知识三层沉淀 + 门禁化回写 AGENTS.md
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
