# Spec — agent-observability（自观测 → 每日分析 → 数据驱动自进化建议）

> 变更目录：`autopilot/changes/agent-observability/` ｜ 分支：`feature/agent-observability` ｜ 类型：feature（dogfooding）
> 输入依据：`explore-notes.md`（已锁定决策）+ `autopilot/knowledge/SCHEMA.md`（C1–C12）。
> 本版为 Review Round 1 修订稿（4 subagent 审查后定稿，修订记录见 §10）。

## 1. 概述与用户故事

给编排系统的每个 agent（implementer / reviewer / fixer）加一层 **fail-safe 遥测**，把每次运行的关键信号结构化落盘；每天 13:00 定时分析累积日志，产出「体检数据 + 针对**插件自身角色 prompt** 的改进建议」，为数据驱动的角色优化提供证据。核心价值不是"人设更花哨"，而是**先能测量，才能有依据地迭代**（调研结论：角色 prompt 对正确性效果随机，只有测量能指导迭代）。

**用户故事**
- 作为维护者，autopilot 跑完后我能翻出「这个 Task 每个 worker 干了啥、CR 挑了啥、修了几轮、哪步 BLOCKED」用于人工复盘。（→ runs/）
- 作为维护者，我能看到「reviewer 的 FAIL/INCOMPLETE 率、命中问题分布、implementer 首验失败率、平均修复轮数、各角色耗时」随时间的趋势。（→ metrics/）
  - 诚实边界：遥测只能度量 reviewer **命中并 FAIL/INCOMPLETE** 的分布，**无法证明"漏检"**（漏检需事后 ground truth）；仅提供"REVIEW_PASS 后仍追加 fix 轮"作为疑似漏检的弱代理。
- 作为维护者，系统每天给我一份报告 + 具体的「该改插件哪个角色 prompt 文件的哪句」建议，**我批准后才改**，系统绝不自动改自己。（→ reports/ + 人工闸门）

**非目标（YAGNI）**：不自动应用建议；不改现有 evolve 的 per-run 行为；**不给业务项目的 AGENTS.md 提改动建议**（见 §5.5 范围裁定）；不做多用户/远程上报/云端聚合。遥测绝不影响真实开发流程。

## 2. 系统架构

```
┌────────────────── 每次跑 autopilot（任意业务项目 CWD）──────────────────┐
│  run-track-a.sh ──每步（命令级 env: STAGE/RUN_ID）──> dispatch.sh ──> qodercli worker │
│      │ (loop 级信号)                                    │ (worker 级信号)           │
│      └──────────────┬─────────────────────────────────┘  两者 source telemetry.sh  │
│                     ▼   telemetry_emit（只写文件；绝不污染 stdout / 不改 exit code） │
└─────────────────────┬──────────────────────────────────────────────────────────┘
                       ▼
  $LOG_ROOT/ (env NEIL_AUTOPILOT_LOG_DIR → 默认 $HOME/neil-autopilot-logs-analysis)
  ├── runs/YYYY-MM-DD.jsonl   结构化事件（append，仅元数据）      ┐ 默认 3 天滚动删
  ├── runs/<run_id>/          关键 worker 输出（review + BLOCKED 步骤）┘ (NEIL_AUTOPILOT_KEEP_DAYS)
  ├── metrics/YYYY-MM-DD.json 每日体检数（bash 确定性聚合 + agent 回填分类）── 长期保留
  └── reports/YYYY-MM-DD.md   每日报告 + 改进建议（人看）                ── 长期保留

  scripts/daily-analysis.sh（launchd 每日 13:00 触发；确定性编排；硬依赖 jq）
   ①rotate 删 >3 天 runs/  ②jq 聚合 runs → metrics  ③当日有新数据才 dispatch 1 个 analysis agent
     → 写 reports/ + 产出 metrics/<date>.categories.json 片段（由脚本 jq 合并回 metrics，校验后落盘）
                       │
                       ▼ 人工读 reports/，批准后才手动改插件角色 prompt（可再起一次 autopilot）
```

**分工原则（C10）**：确定性活（滚动删、数值聚合、事件落盘、片段合并）全用 bash+jq；只有"定性归类问题 + 写改进建议"交给 1 个被 dispatch 的 LLM agent。编排器是脚本，不是 LLM。

## 3. 数据模型

### 3.1 存储布局与路径解析（C8：禁写死用户名）

`$LOG_ROOT` 解析（`telemetry.sh: telemetry_log_root()`）：`$NEIL_AUTOPILOT_LOG_DIR` → 默认 `${HOME}/neil-autopilot-logs-analysis`。
- **安全护栏**：若解析出的 `$LOG_ROOT` 落在当前 `$CWD`（业务项目）之内，遥测降级到 `$TMPDIR`，避免被 `git add -A` 卷入业务提交（C12）。
- **首用才建**（grow-on-demand，C3）：`mkdir -p runs/ metrics/ reports/`。
- **⚠️ 环境变量注入链（CRITICAL 修复，见 §5.6）**：交互式运行（终端起 run-track-a.sh）读用户 shell profile 里的 env；但 **launchd/cron 不 source profile**。故 `install-daily-schedule.sh` 必须把解析后的**绝对 `$LOG_ROOT`** 固化进 plist 的 `EnvironmentVariables`，并打印一行 `export` 供用户加入 profile——保证**两条触发路径解析到同一目录**。否则采集与分析分家、闭环静默失效。

### 3.2 事件 schema：`runs/YYYY-MM-DD.jsonl`（append，一行一 JSON，仅元数据）

公共字段：`ts`(UTC，命令钉死 `date -u +%Y-%m-%dT%H:%M:%SZ`)、`run_id`、`event`。

| event | 来源 | 关键字段（均有消费者，见 §3.3） |
|-------|------|------|
| `dispatch` | dispatch.sh | `stage`、`model`、`duration_s`、`exit_code`（0/124超时/其它崩溃） |
| `round` | run-track-a.sh | `task`、`round`、`verify`(pass/fail/skip)、`review`(REVIEW_PASS/REVIEW_FAIL/REVIEW_INCOMPLETE/UNKNOWN) |
| `task` | run-track-a.sh | `task`、`title`(截断≤200B)、`final_status`(DONE/BLOCKED)、`rounds`、`committed`(bool) |
| `run` | run-track-a.sh | `change`、`outcome`(complete/blocked/interrupted)、`duration_s`（tasks 计数由 task 事件聚合，不重复存） |

- **`stage` 取值（本期实际产出）**：`implement` / `fix` / `review`（run-track-a.sh 命令级 env 注入）、`analyze-daily`（daily-analysis.sh）、`unknown`（dispatch.sh 缺省——外层阶段 analyze/plan/finish/evolve/init 本期不埋点，统一记 unknown；Phase-future 再埋 run-autopilot.sh）。**枚举不含死值**。
- `review` 保留项目三态 `{PASS, FAIL, INCOMPLETE}`（C2）+ `UNKNOWN`（解析不到，与 INCOMPLETE 语义不同，不混淆）。
- **落盘原则**：每行只放**元数据**（`title` 等长字段截断 ≤200B，控制单行 ≤512B 以兼容 macOS `PIPE_BUF`）；完整输出**不入 JSONL**，只在 `runs/<run_id>/` 存**关键输出（review + BLOCKED 步骤）**（见 §5.3，与本节措辞一致，不承诺"完整输出"）。并发写同一天文件为 **best-effort**：单行小 + 截断降低交错概率，聚合侧**跳过畸形行**兜底。
- **观测范围**：只记**被 dispatch 的 worker**。档位 B 外层阶段由控制器亲自执行（无独立 worker），不产生 `dispatch` 事件；但 loop 的开发角色（implement/review/fix）两档都托管、都被记录——这正是要观测的核心。
- **敏感信息**：不主动记录密钥（沿用 evolve「不记录密码/密钥」原则）；日志在项目外、不入 git。

### 3.3 每日体检数 schema：`metrics/YYYY-MM-DD.json`（长期保留）

```json
{
  "date": "2026-07-18",
  "runs": 3, "runs_blocked": 1,
  "tasks_total": 12, "tasks_done": 10, "tasks_blocked": 2,
  "verify_fail_rate": 0.25,
  "review_fail_rounds": 5, "review_incomplete_rounds": 1, "review_total_rounds": 15, "review_fail_rate": 0.33,
  "avg_rounds_per_task": 1.6,
  "dispatch_error_count": 1, "dispatch_timeout_count": 0, "commit_fail_count": 0,
  "avg_duration_s": { "implement": 40, "review": 25, "fix": 30 },
  "top_problem_categories": [ {"category": "空值/边界未检查", "count": 4} ]
}
```
- **producer→consumer 闭环**：`verify`→`verify_fail_rate`（implementer 质量）；`exit_code`→`dispatch_error_count`/`dispatch_timeout_count`；`committed`→`commit_fail_count`；`review`→`review_fail_rate`/`review_incomplete_rounds`；`task.final_status`→`tasks_*`；`run.outcome`→`runs_blocked`。metrics 聚合字段均有 producer；`model`/`run.duration_s`/`task.title`/`run.change`/`round` 序号 **仅作 runs 复盘 + 报告展示元数据（不进聚合）**，非孤儿；`platform` 因彻底无用已删；`dispatch_error_count`/`dispatch_timeout_count` 仅统计 dev 三档（implement/review/fix），排除 analyze-daily/unknown。
- 数值字段：`daily-analysis.sh` 用 **jq 确定性聚合**（跳过畸形行；除零产 `0`；`LC_ALL=C` 锁小数点）。
- `top_problem_categories`：由 analysis agent 定性归类，经 §5.4 的**片段合并协议**回填（不直接重写主文件）。
- **为什么长期留**：raw 删了之后这些数仍在，才能看"改了 prompt 后 FAIL 率降没降"的跨月趋势。量级 ~KB/天、年增长 <1MB，不设上限（如需手动删）。

## 4. 接口设计（脚本 CLI + 环境变量）

### 4.1 新增脚本
| 脚本 | 职责 | 关键用法 |
|------|------|---------|
| `scripts/telemetry.sh` | **可 source 的 lib**（无副作用、写侧零依赖），emit/rotate/log_root/run_id/json_escape | `. telemetry.sh` 后调函数 |
| `scripts/daily-analysis.sh` | 每日编排：rotate → jq 聚合 metrics → dispatch 报告 agent（**硬依赖 jq**） | `daily-analysis.sh [--date YYYY-MM-DD] [--keep-days 3] [--trend-days 30] [--dry-run]` |
| `scripts/install-daily-schedule.sh` | 生成/加载 launchd plist（含 EnvironmentVariables）；Linux 打印 crontab 行 | `install-daily-schedule.sh [--hour 13] [--log-dir DIR]` |
| `scripts/smoke-telemetry.sh` | token-free 冒烟（C7） | `bash scripts/smoke-telemetry.sh` |

### 4.2 环境变量
| 变量 | 默认 | 说明 |
|------|------|------|
| `NEIL_AUTOPILOT_LOG_DIR` | `$HOME/neil-autopilot-logs-analysis` | 日志根；由 install-daily-schedule 固化进 plist + profile |
| `NEIL_AUTOPILOT_TELEMETRY` | `1` | 设 `0` 全局关闭遥测（fail-safe 开关） |
| `NEIL_AUTOPILOT_KEEP_DAYS` | `3` | runs/ 原始日志保留天数 |
| `AUTOPILOT_STAGE` / `AUTOPILOT_RUN_ID` | (调用方**命令级**注入) | worker 阶段标签 / 运行 id；dispatch.sh 缺省 `unknown` / `<date>-<pid>` |
| `AUTOPILOT_DAILY_MODEL` | `Ultimate` | 每日 analysis agent 模型 |

## 5. 核心组件实现要点

### 5.1 `scripts/telemetry.sh`（fail-safe 是第一原则）
- `telemetry_enabled`：`[ "${NEIL_AUTOPILOT_TELEMETRY:-1}" != "0" ]`。
- `telemetry_log_root`：按 §3.1 解析 + 安全护栏 + `mkdir -p`；不可写返回空（调用方静默跳过）。
- `telemetry_json_escape`：**纯 bash 参数扩展**（bash 3.2 兼容），**反斜杠必须第一个转**，覆盖 `\ " \r \n \t`；其余罕见裸控制字符不保证转义（聚合侧跳过畸形行兜底，写侧不引入 tr/sed 外部依赖）；**不用 sed**（无法行内替换换行）：
  `s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\r'/\\r}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}`
- `telemetry_emit <json>`：`printf '%s\n' "$json" >> "$root/runs/$(date +%F).jsonl"`；整体 `{ ...; } 2>/dev/null || true`——任何失败都吞掉。
- `telemetry_rotate [days]`：先 `[ -d "$root/runs" ] || return 0`；删旧文件 `find "$root/runs" -maxdepth 1 -name '*.jsonl' -mtime +$((days-1)) -delete`；删旧**目录**用 `-exec rm -rf`（`-delete` 删不掉非空目录！）：`find "$root/runs" -mindepth 1 -maxdepth 1 -type d -mtime +$((days-1)) -exec rm -rf {} + 2>/dev/null || true`。（`-mtime +$((days-1))`=保留<N天，正确；按 mtime 非文件名日期判定，注明。）
- **纪律**：被 `set -euo pipefail` 的脚本 source →**所有变量引用一律 `${VAR:-}` 兜底**（否则 set -u 中断）；所有函数任何路径 `return 0`；**绝不向 stdout 写**（stdout 是 worker 输出，被 parse-status/parse_review grep——误吐 `DONE/REVIEW_PASS` 会污染解析，正确性红线）。

### 5.2 `dispatch.sh` 埋点（修复 set -e 幸存者偏差）
- 顶部 `. "$SCRIPT_DIR/telemetry.sh"`。
- **核心修复**：`run_with_timeout` 里把 `wait "$CHILD_PID"; EXIT_CODE=$?` 改为 `EXIT_CODE=0; wait "$CHILD_PID" || EXIT_CODE=$?`——否则 `set -e` 在 worker 非零时**当场中止，emit 与 137→124 归一化全成死代码**（实验证实）。`START=$(date +%s)` 在启动子进程前取（137→124 归一化仅在有 TIMEOUT_BIN 时做，避免把外部 SIGKILL 误标超时）。
- 在归一化之后、`exit $EXIT_CODE` **之前** `{ telemetry_emit_dispatch "$EXIT_CODE" "$START"; } 2>/dev/null || true`（读命令级 `AUTOPILOT_STAGE`/`AUTOPILOT_RUN_ID`/`MODEL`，缺省兜底）。
- **不变**：worker 输出仍原样走 stdout；`EXIT_CODE` 不被遥测改写；无遥测/不可写时行为与今天完全一致。

### 5.3 `run-track-a.sh` 埋点（修复 fail-closed 出口丢事件）
- 顶部 `. "$SCRIPT_DIR/telemetry.sh"`；`LOG_DIR` 初始化后 `RUN_ID="$(basename "$LOG_DIR")"`（dry-run 下 LOG_DIR 为空则跳过遥测）。
- **命令级注入（消除 sticky-export 错标）**：给 `dispatch_worker()` 加 `stage` 形参，内部以命令级 env 调 dispatch：`AUTOPILOT_STAGE="$stage" AUTOPILOT_RUN_ID="$RUN_ID" "$DISPATCH" ...`。4 个调用点显式传 stage：implement→`implement`、验证失败 fix→`fix`、review→`review`、CR 失败 fix→`fix`。
- **task 事件在每个出口就地 emit**（CRITICAL 修复）：3 处 `exit 2`（implement 阻塞 / rounds 耗尽 / commit 失败）前各 emit 一条 `final_status=BLOCKED` 的 task 事件；成功收尾处 emit `DONE`。round 事件在每轮 verify/review 后 emit。
- **run 事件走独立 `trap ... EXIT`**（勿与现有 `INT TERM` trap 合并，否则覆盖 interrupted 行为）：①trap **首行 `rc=$?`** 再做任何事（据此定 outcome complete/blocked/interrupted）；②`TASKS_DONE`/`TASKS_BLOCKED`/`RUN_ID` 在**装 trap 之前**初始化，trap 内一律 `${VAR:-}`，且 `[ -n "${RUN_ID:-}" ]` 才 emit（避开早退 `exit 1`/dry-run 空 LOG_DIR 时发假事件）；③`TASKS_BLOCKED` 在每个 `exit 2` **之前**自增。
- **关键输出复制**：每轮 review 日志、BLOCKED 步骤日志复制到 `$LOG_ROOT/runs/<run_id>/`（供次日 agent 定性归类 + 复盘）；复制在各 `exit 2` **之前**逐轮做，经 fail-safe 包裹，$LOG_ROOT 不可写则静默跳过。

### 5.4 `scripts/daily-analysis.sh`（确定性编排，C10；硬依赖 jq）
1. **前置**：`command -v jq` 缺失 → 明确报错 `需要 jq（brew install jq）` 并退出（聚合侧不做 awk 降级——YAGNI，单机本地）。自定位 `DISPATCH="$SCRIPT_DIR/dispatch.sh"`（同插件目录，C8 可移植，不依赖 SKILL_BASE_DIR）。
2. 解析 `$LOG_ROOT`；保留天数优先级 `--keep-days` > `NEIL_AUTOPILOT_KEEP_DAYS` > 默认 3；据此 `telemetry_rotate "$KEEP_DAYS"`。
3. **jq 聚合**当日（及缺失历史日）`runs/*.jsonl` → 写/更新 `metrics/<date>.json`（跳过畸形行；除零产 0；`LC_ALL=C`）。
4. **当日无新 `runs` → 到此为止（仅 rotate + metrics），跳过 agent（省 token）**。否则经 `$DISPATCH` dispatch **1 个** analysis agent（`stage=analyze-daily`，`model=$AUTOPILOT_DAILY_MODEL`）：
   - **读取范围**：只读 `$LOG_ROOT`（近 `--trend-days` 天 metrics 趋势 + 当日 runs/ 含 CR 原文）+ **插件仓库**（自 `$SCRIPT_DIR/..` 定位，用于引用角色 prompt 文件路径）。**不读任意业务项目源码**。
   - **产出**：写 `reports/<date>.md`；**分类回填走片段协议**——agent 只写 `metrics/<date>.categories.json`（一个 JSON 数组），由脚本 `jq` 合并，**用 `if` 包裹避免 set-e 中止**：`if [ -s cats ] && jq -e 'type=="array" and length>0' cats >/dev/null; then jq --slurpfile c cats '.top_problem_categories=$c[0]' metrics.json > tmp && jq -e . tmp >/dev/null && mv tmp metrics.json; fi`（缺文件/空数组/非数组则跳过、保留 bash 版不覆盖成 `[]`，数值字段绝不被覆盖）。
   - **硬约束（对齐"人工批"）**：产出的是**建议不是改动**；只写 `$LOG_ROOT` 下文件。
5. 单步失败跳过、不中断已完成步骤；整体以非 0 退出码 + 日志上报（cron 可见）。

### 5.5 报告模板 `reports/YYYY-MM-DD.md`（要点）+ 范围裁定
`## 体检摘要`｜`## 趋势`（对比历史 metrics）｜`## 高频问题`（定性归类 + 样例链接到 runs/）｜`## 改进建议`｜`## 免责`（仅建议，需人工批准）。

**范围裁定（MAJOR 修复：多项目聚合语义）**：日志跨所有业务项目聚合，故建议**只针对插件自身的全局角色 prompt**（对全局生效的角色，用聚合数据合理）；**不对任何业务项目的 AGENTS.md 提改动**（用聚合数据改 per-project 是错配）。为让 agent 精确落点，§5.4 的 agent 提示词内**嵌入角色→运行时 prompt 落点表**（Round 2 修正：两档 loop 开发都经 `run-track-a.sh` 托管，worker prompt 由脚本**内联生成**，运行时**不读** skill 的 `*-prompt.md`）：
- **运行时唯一落点**（改这里才真正改 worker 行为）：
  - `implement` → `scripts/run-track-a.sh` 的 `build_impl_prompt()`
  - `fix` → `scripts/run-track-a.sh` 的 `build_fix_prompt()`
  - `review` → `scripts/run-track-a.sh` 的 `build_review_prompt()`
- `skills/autopilot-loop/implementer-prompt.md`、`skills/autopilot-review/reviewer-prompt.md` 是**文档模板（运行时不加载）**：改它们不改变 worker 行为，仅作次级同步项（改完运行时落点后同步文档、防漂移）。
建议必须引用**运行时落点的具体文件 + 函数**，并标注证据来源（哪些 runs/metrics 支撑）。

### 5.6 调度 `scripts/install-daily-schedule.sh`（环境变量注入链的唯一落点）
- 平台判定 `uname -s`（Darwin/Linux）。`--log-dir` 缺省取当前 `$NEIL_AUTOPILOT_LOG_DIR` 或默认值，解析成**绝对路径**。
- macOS：生成 `~/Library/LaunchAgents/com.neil.autopilot.daily.plist`，`StartCalendarInterval` 每日 `--hour`（默认 **13** 点）。**必须写 `EnvironmentVariables`**：`NEIL_AUTOPILOT_LOG_DIR`(绝对)、`NEIL_AUTOPILOT_KEEP_DAYS`、以及 `PATH`。**PATH 动态构造（逐个判空，空结果跳过、绝不产生 `.`）**：对 qodercli/jq/gtimeout 各取 `p="$(command -v X || true)"; [ -n "$p" ] && dirs+=("$(dirname "$p")")`，去重后并上 `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`——qodercli 常经 nvm/volta/npm-global 安装、不在固定前缀里，硬编码会漏，导致 launchd 定位不到、每日报告静默失效；**缺 qodercli 则 install 报错中止**（jq/gtimeout 缺失只跳过其 dirname，不注入 `.`）。加载优先 `launchctl bootstrap gui/$UID <plist>`（macOS 15 `load` 已弃用，兜底 `load`）。
- **同时打印一行** `export NEIL_AUTOPILOT_LOG_DIR="<abs>"` 提示用户加入 shell profile（覆盖交互式运行，保证两条路径同目录）。
- Linux：打印可粘贴 crontab 行（前置 `NEIL_AUTOPILOT_LOG_DIR=<abs>`）。plist/crontab 是**用户级 setup 产物**（含绝对路径），不进插件仓库（C8 只约束分发脚本）。幂等：重装先 unload/删旧。
- `daily-analysis.sh` 的绝对路径同样由 install 脚本自 `$SCRIPT_DIR` 解析写入，禁止硬编码。

## 6. 约束遵循（SCHEMA C1–C12）

| 约束 | 遵循方式 |
|------|---------|
| C1 不按档位 fork | 遥测横切，两档同一套 telemetry.sh；无档位分叉 |
| C2 CR fail-closed | 遥测不改 `EXIT_CODE`、不污染 stdout → 绝不破坏 CR fail-closed；`review` 保留三态含 INCOMPLETE |
| C3 grow-on-demand | 目录首用才建；不预建空文件 |
| C4 不写死主干名 | 本 spec 不涉主干名（N/A） |
| C5 横切全量 rollout | 遥测经 `dispatch.sh` 单收口即覆盖全部被托管 worker；外层阶段 stage 标注为 Phase-future 显式待补（不留死值） |
| C6 shell 可移植 | 写侧零依赖（纯 bash 转义）；**聚合侧 jq 为已批准例外**（仅本机每日跑，缺失 fail-fast 报错而非降级，见 §9.4）；`date -u`/`date +%F`/`find -mtime`/`-exec rm -rf`/`uname` 均两平台安全；bash 3.2 |
| C7 verify-by-running | `smoke-telemetry.sh` token-free 覆盖 emit/rotate(含非空目录)/set-e 失败路径/关闭开关/不污染 stdout/env 注入 |
| C8 自带脚本可移植定位 | `$LOG_ROOT` env→`$HOME` 默认，**不写死用户名**；daily-analysis 自 `$SCRIPT_DIR` 定位 dispatch；绝对路径只进用户级 plist/crontab |
| C9 分支纪律 | 已切 `feature/agent-observability` |
| C10 确定性编排 | daily-analysis 是 bash+jq 编排器；LLM 仅做定性报告一步 |
| C11 控制器不内联写码 | 每日报告由 dispatch 的 agent 产出 |
| C12 .gitignore 兜底 | `$LOG_ROOT` 默认在项目外；护栏禁其落在 $CWD 内；新脚本本身是被追踪源码 |

## 7. 验证方案（无编译，用 grep/smoke 断言）

`bash scripts/smoke-telemetry.sh` 全绿（token-free，不起真实 worker）：
- emit 出的 JSONL 行数/字段正确、`jq -e .` 逐行合法；含 `\r`/`"`/中文/制表符的字段转义后仍合法。
- **rotate 覆盖非空目录**：伪造一个含文件的 `runs/<old>/` 目录并回填 mtime（`date -v-4d`/`date -d '4 days ago'` 双分支 + `touch -t`），断言旧目录被删、新目录保留。
- **set-e 失败路径**：以非零退出的假 worker 走 dispatch 的 emit 逻辑，断言 `exit_code!=0` 的 dispatch 事件被记录（防幸存者偏差回归）。
- `NEIL_AUTOPILOT_TELEMETRY=0` 零落盘；`$LOG_ROOT` 不可写不报错。
- **env 注入**：伪造干净环境（`env -i`）跑 `daily-analysis.sh --dry-run`，断言经 plist 风格 env 能定位到指定目录（非默认 $HOME）。
- **分类回填**：给定 fixture metrics + categories 片段，断言 jq 合并后 JSON 合法且**数值字段未变**；缺片段/空数组/**非数组**时均不覆盖原值。
- **stdout 洁净**：捕获 `telemetry_emit` 的 stdout 断言为空（正确性红线，防污染 parse-status/parse_review）。
- **fail-closed 事件（修复2，属 smoke-run-track-a.sh）**：token-free 注入——PATH 前置一个假 `qodercli`（输出 `**Status:** BLOCKED`）+ `AUTOPILOT_PLATFORM=qoder`，走 implement-BLOCKED 分支命中 `exit 2`，断言其前 emit 了 `final_status=BLOCKED` task 事件、EXIT trap emit 了 `outcome=blocked` run 事件；`exit 130` 用后台跑 + `kill -INT` 断言 `outcome=interrupted`。
- **PATH 注入**：断言 install 生成的 plist PATH 能 `command -v qodercli`，**且不含 `.`/空段**（防 gtimeout/jq 缺失注入 `.`）。
- **落点防漂移（§5.5）**：grep 断言 daily agent 提示词内嵌落点表引用 `build_impl_prompt/build_fix_prompt/build_review_prompt`，且不把 `*-prompt.md` 列为运行时落点。

回归：`bash scripts/smoke-dispatch.sh` + `bash scripts/smoke-run-track-a.sh` 仍全绿。
grep 断言：`telemetry_emit` 调用点均带 fail-safe 包裹；`grep -rn "/Users/" scripts/` 无命中（C8）；`grep -n 'date --iso' scripts/` 无命中（防 GNU-only）。

## 8. 里程碑（Phase）

| Phase | 内容 | 完成判据 |
|-------|------|---------|
| **P1 采集地基** | `telemetry.sh` + 埋点 `dispatch.sh`/`run-track-a.sh` + `smoke-telemetry.sh` | smoke 全绿（含非空目录 rotate + set-e 失败路径）；两既有 smoke 回归通过；样例运行产出含 BLOCKED 的全类型事件 |
| **P2 每日分析** | `daily-analysis.sh`（rotate + jq 聚合 + dispatch 报告 agent + 片段合并）+ 报告模板（含角色→prompt 映射表） | 对 fixture 跑出合法 `metrics.json`（回填后数值不变）+ `reports/*.md`；无 jq 明确报错；`--dry-run` 不写 |
| **P3 调度与文档** | `install-daily-schedule.sh` + AGENTS.md/README 增补 + 知识库 wiki 页 | plist 含正确 `EnvironmentVariables`(LOG_DIR+PATH)；**干净环境 env 注入 smoke 通过、交互与 launchd 解析同目录**；`autopilot/knowledge/raw/` 新增 1 条 raw + wiki inbox 收录 |

## 9. 决策点（Review 后已全部锁定）

1. **路径**：`NEIL_AUTOPILOT_LOG_DIR` env（默认 `$HOME/...`）；由 `install-daily-schedule.sh --log-dir` 固化进 plist EnvironmentVariables + 打印 profile export，指到 `/Users/neil/Desktop/neilcodebase/neil-autopilot-logs-analysis`。**唯一落点机制，已解决 launchd 断链**。
2. **保留**：`runs/` 默认 3 天滚动删；`metrics/` + `reports/` 长期（KB 级，不设上限）。
3. **定时点**：每天 **13:00** 本地时间，可 `--hour` 改。
4. **jq**：写侧零依赖；**聚合侧（仅你本机每日跑）硬依赖 jq**，缺失明确报错提示 `brew install jq`（不再维护 awk 降级）。⚠️ 这是相对最初讨论的一处务实收紧，请知悉。
5. **范围**：不动现有 evolve per-run 行为；"自进化"= 每日报告出建议 + 人工批；建议**只针对插件自身角色 prompt**，不碰业务项目 AGENTS.md。

## 10. Review 修订记录（Round 1，4 subagent）

- **[CRIT]** dispatch.sh：`wait || EXIT_CODE=$?` 修复 set-e 幸存者偏差（失败/超时 worker 原本永不 emit）。
- **[CRIT]** run-track-a.sh：task 事件在 3 处 `exit 2` 前就地 emit、run 事件走 EXIT trap（BLOCKED 原本记不到）。
- **[CRIT]** rotate：非空 `runs/<run_id>/` 改 `-exec rm -rf`（`-delete` 删不掉、还被 fail-safe 吞掉）。
- **[CRIT]** env 注入：install 脚本把 LOG_DIR+PATH 固化进 plist EnvironmentVariables（launchd 不读 profile）。
- **[MAJ]** 多项目语义：建议只针对插件全局角色 prompt；agent 提示词嵌角色→prompt 文件映射表。
- **[MAJ]** metrics 回填改片段协议（jq 合并 + 校验，数值字段不被 LLM 覆盖）。
- **[MAJ]** review 枚举补 `INCOMPLETE`；metrics 补 `verify_fail_rate`/`dispatch_error/timeout`/`commit_fail`（消灭孤儿字段）；删 `platform`。
- **[MAJ]** JSON 转义补 `\r`+控制字符、反斜杠先转、弃用 sed；`ts` 钉死 `date -u +...Z`；stage 命令级注入消除 sticky-export 错标。
- **[MAJ/YAGNI]** 聚合侧硬依赖 jq、删 awk 双路径与双分支测试；stage 枚举收窄至实际产出值。
- **[MIN]** `${VAR:-}` 兜底、`--keep-days` 整数校验、trend-days 默认 30、launchctl bootstrap、`>>` 改口径为 best-effort+截断、P3 判据可验证化。

### Round 2（2 subagent 复审）
- **[CRIT]** §5.5 角色→prompt 落点：两档 loop 都经 run-track-a.sh 内联生成 prompt，运行时不读 `*-prompt.md`→映射表收敛为“运行时唯一落点=build_* 函数”，.md 降为文档模板。
- **[MAJ]** §5.6 plist PATH 改为动态构造（`dirname $(command -v qodercli)` 等），覆盖 nvm/volta 装的 qodercli。
- **[MAJ]** §5.3 EXIT trap 实现细节钉死（首行 rc=$?、计数器先初始化、独立 trap 勿合并、TASKS_BLOCKED 在 exit 2 前自增）。
- **[MAJ]** §5.4 jq --slurpfile 加守卫（缺片段/空数组不覆盖）；§7 补修复2 的 token-free 断言 + stdout 洁净 + PATH 断言。
- **[MAJ]** §3.3 `model`/`run.duration_s` 明确为“报告/复盘元数据不进聚合”，消除与“无孤儿字段”矛盾；run 事件裁减冗余 tasks 计数。
- **[MIN]** json 转义控制字符声明诚实化、137 归一化仅有 TIMEOUT_BIN、keep-days 优先级、C6 标为已批准例外、完整→关键输出收窄已确认（体积考量）。

### Round 3（2 subagent 收尾）
- **[MAJ]** §5.6 plist PATH 逐个判空（gtimeout/jq 缺失只跳过其 dirname、绝不注入 `.`）；§7 补“PATH 不含 `.`/空段”断言。
- **[MIN]** §5.4 jq 合并用 `if...fi` 包裹（防 set-e 中止）；§7 钉死修复2 的 token-free 注入机制 + 非数组回填用例 + §5.5 落点 grep 断言；§3.3 补 title/change/round 序号为展示元数据、error/timeout 计数仅 dev 三档。
- **判定**：两 subagent 均确认 **0 Critical / 0 Major**（PATH 一行兜底并入后），decision-complete，可进 plan。
