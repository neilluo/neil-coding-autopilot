# Neil Coding Autopilot — Plugin 说明

AI 全托管开发编排器。从需求到部署的全自动开发流水线。

## 架构概览

**执行模型（铁律：控制器永不内联写码，开发一律托管 qodercli）**:
- **档位 A · 无人值守**：explore/analyze/plan headless（或 spec-ready），从终端起 `scripts/run-track-a.sh` 端到端跑 loop，各步 spawn fresh qodercli worker、context 隔离、分角色模型。用于 CI / 无人值守 / 大型构建。
- **档位 B · 交互**：控制器在会话内跟用户跑 explore/analyze/plan/finish/evolve，**loop 同样调 `scripts/run-track-a.sh` 托管开发**（控制器只看日志摘要、不内联写码）。用于会话内协作 / 需求要边聊边澄清。

两档只差"外层阶段是否有人交互"，**开发都经 `run-track-a.sh` 托管给 qodercli**；共享同一套阶段与不变量（explore / CR / verify / evolve）。选档规则见 `skills/using-neil-autopilot/SKILL.md` 的「执行档位」，档位差异集中在 `skills/_shared/conventions.md` 的「档位适配表」（单一事实源）。

`scripts/run-autopilot.sh` 是档位 A 的无人值守端到端入口：编排 loop（`run-track-a.sh`）→ finish（默认走确定性 `finish-change.sh`）→ evolve 三阶段，fail-closed（任一阶段 BLOCKED 即停，不接力）。可重跑：change 已归档时自动跳过 loop+finish、从 evolve 续跑（也可显式 `--skip-loop`）。

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
| AGENT_DISPATCH | `~/.qoder/skills/neil-coding-autopilot/scripts/dispatch.sh` | 统一调度脚本；留空即用左边这个默认绝对路径（唯一写法见 `conventions.md`「托管脚本路径」），非标准安装才设为绝对路径覆盖（勿用相对 `scripts/dispatch.sh`，也勿去业务仓库找 `.autopilot-local/scripts/`） |
| AUTOPILOT_ANALYZE_MODEL | Ultimate | 需求分析阶段模型（需强推理） |
| AUTOPILOT_PLAN_MODEL | Ultimate | Task 拆解阶段模型（需强推理） |
| AUTOPILOT_IMPLEMENTER_MODEL | Performance | 编码型 worker 模型 |
| AUTOPILOT_REVIEWER_MODEL | Ultimate | 审查型 worker 模型（需高质量 CR，默认 Ultimate）。注：空输出**不是** transport 抖动，而是模型把回合收在 thinking 里（见 `AUTOPILOT_SILENT_*`） |
| AUTOPILOT_FIXER_MODEL | 跟随 AUTOPILOT_IMPLEMENTER_MODEL（即 Performance） | 修复型 worker 模型；未设时跟随 implementer（包括 `--impl-model` 的覆盖值） |
| AUTOPILOT_INIT_MODEL | Performance | Harness 初始化阶段模型 |
| AUTOPILOT_EVOLVE_MODEL | Ultimate | 知识沉淀阶段模型（需强归纳） |
| AUTOPILOT_MAX_PARALLEL | （未实现，保留名） | loop **按设计串行**：run-track-a.sh 逐 Task 跑，且 per-change 锁就是排他的。代码零引用，设了不生效（曾标默认 3，属文档承诺了不存在的旋钮） |
| `AUTOPILOT_TIMEOUT_<STAGE>` | review=900 / implement=1800 / fix=900 / 其他=600 | 分阶段 worker 超时秒数；`<STAGE>` 为大写阶段名（如 `AUTOPILOT_TIMEOUT_REVIEW`） |
| `AUTOPILOT_KILL_AFTER_S` | 30 | 超时发送 TERM 后等待多少秒再强制 KILL |
| `AUTOPILOT_TRANSPORT_RETRIES` | 3 | **TRANSPORT**（真链路故障）最大尝试次数；判为 SILENT（静默且已改动工作树）时不重试 |
| `AUTOPILOT_SILENT_RETRIES` | 5 | **EMPTY / 静默回合**（工作树未动）最大尝试次数，**立即重试不退避**——等待无法让 thinking-only 回合开口；实测静默率约 50%，故上限单独设更高 |
| `AUTOPILOT_SILENT_EFFORT` | low | 静默后的重试降低 `--reasoning-effort` 到此档位（直接打击“回合死在 thinking 里”；实测同 prompt 默认档 1/4 静默 vs low 档 0/4）。**首次尝试不降档**以保质量；设空字符串关闭 |
| `AUTOPILOT_SILENT_FALLBACK_MODEL` | Performance | 连续静默达 `AUTOPILOT_SILENT_SWITCH_AFTER` 次后换成该模型跑完剩余尝试；设空字符串关闭 |
| `AUTOPILOT_SILENT_SWITCH_AFTER` | 2 | 静默几次后开始换模型（保证默认模型先被充分尝试） |
| `AUTOPILOT_TRUNCATED_FAIL_CLOSED` | 1 | 取证判定为 `TRUNCATED_TOOL_USE`（模型发出工具调用、CLI 没执行就退出，工作树零改动）时**立即 fail-closed，不重试**。设 0 退回旧的 EMPTY 静默重试。**默认 1 是省钱决定**：两类静默的统计性质相反 —— thinking-only 是随机的（实测 Ultimate 8/15 静默，重试约一半概率开口，重试阶梯划得来），而截断是确定性的（`dispatch.sh` 实测原样重试 3/3 复现；真实每日分析 agent 3 次尝试只产出 87B/115B/118B、报告一次没落盘）。旧行为把一次注定失败的调用按全价买到 `AUTOPILOT_SILENT_RETRIES`（默认 5）遍 |
| `AUTOPILOT_FINISH_MODE` | deterministic | finish 阶段执行方式；设 `worker` 退回旧的 agent 路径（需要 SKILL.md 里的 PR/CI 语义时）。实测 agent 路径 finish 7/7 未给结论，故默认确定性 |
| `AUTOPILOT_RETRY_BACKOFF_S` | 5 | 传输重试指数退避基数秒数（5/10/20）；**只作用于 TRANSPORT**，静默不退避 |
| `AUTOPILOT_USAGE_JSON` | 0 | 设 1 才启用 `qodercli -o json` usage 信封。**注意历史结论已于 2026-08-17 被推翻**：旧注释称 `-o json` 会让工具循环停在首个 tool_use（0/5 成功），重测（同一版本号 1.0.16、每变体 11 次）为 `-o json` 11/11、`-o text` 10/11、不带 `-o` 9/11。仍默认关闭的新理由：信封里 `total_cost_usd`/`input_tokens`/`output_tokens` **全为 0**，唯一有用的 `stop_reason` 已可由 `session-forensics.sh` 从 transcript 读到，零行为风险。**教训：用版本号钉住的实测结论不可靠，结论必须带日期并周期重测** |
| `AUTOPILOT_RAW_JSON` | （未设置） | 可选：把 qodercli 原始 JSON 信封复制到指定路径 |
| `AUTOPILOT_REVIEW_DIFF_BUDGET` | 120000 | reviewer 上下文最大字节数，超限显式标记 `TRUNCATED` |
| `AUTOPILOT_EMPTY_LOG_BYTES` | 300 | worker 短日志判为 EMPTY / TRANSPORT 的字节阈值 |
| `AUTOPILOT_LOCK_DIR` | `$TMPDIR/autopilot-track-a-lock<change-dir>` | Track A per-change 并发锁路径；默认落 TMPDIR，绝不放业务仓库内（否则被每个 Task 的 `git add -A` 提交进去） |
| NEIL_AUTOPILOT_LOG_DIR | `$HOME/Library/Logs/neil-autopilot` | 遥测日志根（落在业务 CWD 内自动降级到 $TMPDIR） |
| NEIL_AUTOPILOT_TELEMETRY | 1 | 设 0 全局关闭遥测（fail-safe 开关） |
| NEIL_AUTOPILOT_KEEP_DAYS | 30 | runs/ 原始日志保留天数（metrics/reports 长期保留） |
| NEIL_AUTOPILOT_LOG_SINK | file | telemetry 写入后端；云端保险/未来 OSS/SLS 扩展点，未识别值兜底回退 file |
| NEIL_AUTOPILOT_KB_DIR | `$HOME/.neil-autopilot/knowledge` | 全局跨项目知识库路径（`scripts/kb-path.sh` 解析单一事实源，C14/C8）；evolve 升迁通用经验 / kb-search 检索历史命中共用 (source: raw/20260719-archive-knowledge-loop.md) |
| AUTOPILOT_DAILY_MODEL | Ultimate | 每日 analysis agent 模型 |
| `AUTOPILOT_DAILY_RETRIES` | 3 | 每日 analysis agent 最大尝试次数；以「reports/<date>.md 是否落盘」为退出条件，成功即停 |

超时取值以 `scripts/dispatch.sh` 为准，优先级为：CLI `--timeout` > `AUTOPILOT_TIMEOUT_<STAGE>` > `AUTOPILOT_TIMEOUT` > 内置阶段默认值；任一来源设为 `0` 表示不启用 timeout 包装。**但全局 `AUTOPILOT_TIMEOUT` 只能收紧、不能放大**：当它高于某阶段内置默认时会被夹回该默认（放大某阶段必须用分阶段旋钮或 `--timeout`）。

**超时窗口就是烧钱窗口（全局 `AUTOPILOT_TIMEOUT` 只收紧不放大）**：worker 被杀之前已生成的 token 照付，而 TIMEOUT 在 `run-track-a.sh` 里是 fail-closed、**不重试**，成果整个丢弃 —— 所以超时上限等于「一个卡死的 worker 最多能烧多少钱」。一个笼统的全局 `AUTOPILOT_TIMEOUT` 若高于某阶段各自调好的默认值（review/fix 900、非 implement 600），会把这些便宜阶段的烧钱窗口拉宽 2~3 倍。已实测踩到：shell profile 里一行 `export AUTOPILOT_TIMEOUT=1800` 就把所有阶段抬到 1800s。现在 dispatch 在这种情况下会把值**夹回阶段内置默认**并打一条 `WARN`（头部同时输出 `timeout-src=<来源>`；调小不夹也不告警 —— 那是主动收紧预算）。**效果：即使 `~/.zshrc` 里残留着全局 1800，也已无害（每阶段自动回到自己的默认）。** 要真的放大某阶段，用 `AUTOPILOT_TIMEOUT_<STAGE>`。

**成本目前不可观测（已核实）**：`runs/*.jsonl` 里 `input_tokens`/`output_tokens`/`cost_usd` 字段存在但永远为空——`-o json` 信封里这三个值本身全是 0，而 CLI 的 session transcript **根本没有** `usage` 字段（已逐字段验证）。因此只有 `duration_s` / `prompt_bytes` / `output_bytes` 三个代理指标可用；任何「省了多少钱」的结论只能基于这三个代理量或平台账单，**不得声称精确 token 数**。

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
| `scripts/session-forensics.sh` | **静默 worker 取证**：读 CLI 自己落盘的 session transcript（`~/.qoder/projects/<物理cwd 的/换成->/<session-id>.jsonl`），定性为 `REPORTED` / `WORK_DONE_UNREPORTED` / `TRUNCATED_TOOL_USE` / `THINKING_ONLY`，并给出 cli_version。这四种对「能不能重试」的结论**互相矛盾**，是重试决策的唯一可靠判据 |
| `scripts/record-subagent.sh` | **subagent 通道记账**：主控会话内用 subagent 开发时，开发不经 dispatch.sh，遥测会整段缺失（实测：一个 9h37min / 13128 credits 的整夜在 runs/ 里一行都没有）。用 `start/end/round/task` 四个子命令按同一 schema 写进同一个 runs/*.jsonl，靠 `channel` 字段区分 cli / subagent |
| `scripts/classify-outcome.sh` | 按退出码、锚定标记与日志大小分类 `OK/TRANSPORT/TIMEOUT/TRUNCATED/EMPTY/APP`，供有界重试决策使用。`TRUNCATED` 判据是 **rc=125 + 日志含 `TRUNCATED_TOOL_USE` 锚定行**这一对组合：`timeout(1)` 也用 125 表示自身启动失败，而本仓源码自己就含该字符串（worker 在本仓干活时可能把它打进日志），所以两者都不能单独作为判据 |
| `scripts/parse-markers.sh` | 锚定式解析结论标记（`**Status:**` / `XXX_STATUS=` / `REVIEW_PASS|FAIL`，容列表符与反引号），是「worker 报没报数」的单一判据 |
| `scripts/finish-change.sh` | **确定性 finish**（C10）：全 Task DONE + 工作树清洁两道门禁 → 探测基分支合并（冲突即 abort 并还原）→ 归档（XOR）→ 提交 → 清哨兵。merge 路径上不再有 LLM |
| `scripts/review-context.sh` | 生成预算受限的 review diff，上下文超限时保留文件概览并标记 `TRUNCATED` |
| `scripts/migrate-log-root.sh` | 将旧日志根的 runs/metrics/reports 只复制到新目录并校验 JSONL 行数，不删除源数据 |
| `scripts/smoke-all.sh` | 顺序执行全部 token-free `smoke-*.sh`，失败即停的统一回归入口 |
| `scripts/daily-analysis.sh` | 每日编排：rotate runs/ → jq 聚合 metrics/ → dispatch analysis agent 写 reports/（硬依赖 jq；按报告文件是否落盘定成败，不以 dispatch 退出码为准） |
| `scripts/install-daily-schedule.sh` | 生成/加载每日 13:00 定时任务；**插件改动后必须重跑本脚本**（`--stage-scripts` 把脚本副本放到 TCC 安全目录，副本不会自动跟随仓库更新）。用 `--check-staged` 只读检测副本是否落后（一致 exit 0 / 落后 exit 3 并点名文件） |

系统只产出**建议**（reports/，针对插件自身角色 prompt），改不改永远人工批准，绝不自动改自己。

### 铁律：脚本只有一份事实源（2026-08-16 事故）

业务仓库里曾出现一份手工拷出的编排器副本 `<project>/.autopilot-local/scripts/`（8-15 拷贝），
它**缺** `worktree_signature` 指纹守卫、**缺** EMPTY/静默分支、**缺** `SILENT_COMPLETION` 诊断，
于是把「worker 干完活但没报数」一律标成 `transport failure`、丢弃已落盘的成果并重试到 Task BLOCKED。
当晚 9 次真实 run 无一例外；而插件仓库那份代码本身是正确的（用桩可复现它正确判定为 silent 并拒绝重试）。
后果被放大到了策略层：据此得出「headless 只有 ~50% 成功率、不可用」的错误结论，转向 in-session
subagent 开发，把编码工作从 Performance 抬到 Ultimate 计费 —— 一夜 13128 credits。

三条硬约束：

1. **不要在业务仓库里放编排器脚本副本。** 一律引用插件仓库路径（或 `AGENT_DISPATCH` 指向它）。
2. `run-track-a.sh` / `dispatch.sh` 启动时会打印**正在执行的脚本绝对路径**（`driver: script=…` /
   `dispatch: script=…`）。排查任何异常行为，**先看这一行**再看别的。
3. `install-daily-schedule.sh --stage-scripts` 生成的 staged 副本同样会漂移；
   用 `--check-staged` 定期核对（一致 exit 0 / 落后 exit 3 并点名文件）。

### 遥测新增字段（取证用）

| 字段 | 含义 |
|------|------|
| `session_id` | dispatch 自己生成并用 `--session-id` 钉住的会话 id；凭它可直接定位 transcript 做取证 |
| `stderr_bytes` | 与 `output_bytes` 分开记；两股流合并后「CLI 一个字没说」与「我们把 stderr 丢了」长得一样 |
| `forensic_verdict` | `session-forensics.sh` 的定性结论（见上表）；区分「重试安全」与「重试会叠在半成品上」 |
| `stop_reason` | 回合收尾方式（`end_turn` / `tool_use`）；`tool_use` + 零改动 = 工具调用被截断 |
| `tool_calls` | 该会话实际发出的工具调用次数；`0` 意味着模型什么都没做 |
| `channel` | `cli`（headless worker 进程，单独计费、fresh context）/ `subagent`（主控会话内，计费归主控、共享上下文） |

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
| `autopilot/archive/` | 已完成的历史变更（四层 `YYYY/MM/MM-DD/YYYY-MM-DD-<name>/`，叶子保完整日期前缀；SCHEMA C13/C15，source: raw/20260719-archive-date-hierarchy-and-idempotent-migration.md） |
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
