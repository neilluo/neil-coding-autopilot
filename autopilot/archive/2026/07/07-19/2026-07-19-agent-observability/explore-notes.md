# Explore Notes — agent-observability

> 本文件是 explore 阶段产出：记录需求澄清过程、方案演化与已锁定决策，供 analyze 生成 spec 读取。
> 交互档（Track B），需求经多轮讨论澄清而成。

## 需求起点（用户原话概括）

用户观察到本插件里有多个"单独的 CLI"——有做开发的（implementer）、做测试/审查的（reviewer）、做管控的（controller）——本质都是 agent。
**原始想法**：给这些 agent 附加特定角色，用 prompt 让它们更有针对性。要求先调研（Google + GitHub）验证方向是否正确，再讨论，不急于写代码。

## 调研结论（2 个 subagent：GitHub 框架 + Google/学术）

- **方向正确且是业界主流**：CrewAI(`role/goal/backstory`)、MetaGPT(SOP 五岗位)、ChatDev(公司角色)、Claude Code subagents(`.claude/agents/*.md` + tools 白名单)、Magentic-One(按工具边界分角色) 普遍在做角色专门化。共性 = 角色 ≈ 定向 system prompt + **工具权限收窄** + 供编排器路由的 description。
- **关键修正**：角色 prompt 是"行为方向盘"，**不是"准确率增强器"**。
  - 反方证据：Zheng 2024 (EMNLP) — system prompt 加人设不能系统性提升事实准确率，影响方向基本随机。
  - 正方证据：ExpertPrompting / Role-Play Prompting (NAACL 2024) — **具体、与任务匹配的**角色描述能帮推理；起效的不是"你是专家"四个字。
  - 结论：角色对「行为引导/工具收窄/多智能体分工/输出格式」强，对「事实/代码正确性」弱（正确性靠 verify + CR 门控）。
- **反例（本项目基本免疫）**：Cognition《Don't Build Multi-Agents》——上下文隔离在并行 fan-out 时导致子 agent 决策冲突。本项目是**串行**架构（tasks.md 逐 Task + verify/CR 门控），威胁很小。

## 现状（读码确认）

- 已有角色骨架但很薄：per-role 模型（`AUTOPILOT_IMPLEMENTER_MODEL=Performance` / `REVIEWER=Ultimate`）、per-role prompt 模板、`AUTOPILOT_ROLE=worker` 标记、控制器写硬门禁。
- `dispatch.sh`：每个 worker 的唯一收口；知道 model/cwd/exit_code/耗时，但**不知道角色/阶段**。
- `run-track-a.sh`：已把运行日志写到 `$TMPDIR/autopilot-track-a/...`（故意不入项目仓库）；已掌握 task/轮数/verify/REVIEW_PASS-FAIL/commit 全部循环级信号。
- **缺失**：没有任何持久化、可聚合、跨运行的遥测层——所以无法回答"哪个角色在哪类问题上不稳"，角色优化只能盲改。

## 需求演化（讨论关键转折）

1. 用户被问"当前哪种质量不稳最频繁"时答不上来 → 意识到**没有数据**。
2. 用户主动提出：**先加日志，未来基于日志迭代 / 自我进化**。
3. 收敛为闭环：**①采集 → ②存储 → ③每日定时分析 → ④数据驱动的自进化建议（人工批准）**。
4. 角色强化诉求**不丢弃**，而是被安置在 ④：等日志跑一阵，报告用数据告诉你"该改哪个角色的哪句 prompt"，再经你批准去改——从盲改变成证据驱动。

## 已锁定决策（用户确认）

| 项 | 决策 |
|----|------|
| 日志目录 | `/Users/neil/Desktop/neilcodebase/neil-autopilot-logs-analysis/`（用户已手动建好空目录）；含 `runs/` + `metrics/` + `reports/` |
| 路径实现 | ⚠️ 因约束 C8（禁写死用户名），脚本用 `NEIL_AUTOPILOT_LOG_DIR` env + 可移植默认值解析；用户那个路径经该 env 指过去（analyze 需在 spec 明确并请用户确认） |
| 保留策略（两层） | **原始日志（runs/，完整 worker 输出）3 天滚动自动删**；**每日体检数（metrics/，几个数）长期保留**。理由：详细的放久无意义只用于人工复盘；精简数字要留着看趋势（否则每日分析永远只能看 3 天，看不出"改了 prompt 后 FAIL 率降没降"）。对应知识库 raw(过期)→wiki(长期) 的思路。 |
| 上报触发 | 用了插件就自动上报——在 `dispatch.sh` + `run-track-a.sh` 两收口埋点，无需手动开关 |
| 每日分析 | 骑定时能力（macOS launchd / cron）触发；确定性活（聚合/滚动删）用 bash，定性分析/写建议才用 LLM agent；**只读，不改任何源文件** |
| 自进化尺度 | **纯建议 + 人工批准**（用户选最保守档）：每日报告只产出「报告 + 改动建议」，系统绝不自动改自己 |

## 设计方向（闭环）

```
每次跑 autopilot
  ├─①采集(自动)   dispatch.sh(每 worker: stage/model/耗时/exit) + run-track-a.sh(每 task: 轮数/verify/CR/commit)
  ├─②存储(自动)   $LOG_ROOT/runs/YYYY-MM-DD.jsonl（结构化事件）+ 完整 worker 输出（3天滚动）
  ├─③每日分析(自动·只读)  daily-analysis.sh：滚动删>3天 → bash 聚合 metrics → 派 1 个 agent 读近期日志写 reports/
  └─④自进化(只出建议·人工批)  reports/YYYY-MM-DD.md 含"角色/AGENTS.md 改进建议"，人看了批准才改
```

## 边界（YAGNI / 明确不做）

- **不改现有 evolve 的 per-run 行为**（Step 6 门禁化回写 AGENTS.md 已上线，属既有机制）；本次"自进化"仅指每日报告出建议，人工批。
- 不做自动应用建议、不做多用户、不做远程上报/云端聚合（用户"暂时只本地用"；留 env 覆盖点即可）。
- 遥测必须 fail-safe：任何遥测失败都不得影响真实开发流程的 stdout / 退出码（提供 `NEIL_AUTOPILOT_TELEMETRY=0` 关闭开关）。

## 执行档位与类型

- 档位 B（交互）；任务类型 feature（dogfooding，开发插件自身）。
- init 跳过（harness 完整）；explore 本文件即产出。
- 分支：`feature/agent-observability`（已切）。
