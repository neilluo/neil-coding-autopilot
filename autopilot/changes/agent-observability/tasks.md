# Implementation Tasks — agent-observability

> Auto-generated from spec.md by autopilot-plan
> Verify command: `true`
> Total tasks: 6 ｜ 权威依据：本目录 `spec.md`（worker 必读对应章节）

## Task 1: telemetry.sh 采集库 + smoke-telemetry.sh

**Branch**: `feature/agent-observability`
**Depends**: none
**Gate**: auto
**Files**:
- Create: `scripts/telemetry.sh`
- Create: `scripts/smoke-telemetry.sh`

**Description**:
读 `autopilot/changes/agent-observability/spec.md` §5.1/§3.1/§3.2（权威）。实现可 source 的 fail-safe 遥测库 `telemetry.sh`：`telemetry_enabled`（`NEIL_AUTOPILOT_TELEMETRY!=0`）；`telemetry_log_root`（`NEIL_AUTOPILOT_LOG_DIR`→`$HOME/neil-autopilot-logs-analysis`；若落在 `$CWD` 内降级 `$TMPDIR`；`mkdir -p runs/ metrics/ reports/`；不可写返回空）；`telemetry_json_escape`（纯 bash 参数扩展，**反斜杠先转**，覆盖 `\ " \r \n \t`）；`telemetry_emit`（`printf '%s\n' >> runs/$(date +%F).jsonl`，整体 `{ …; } 2>/dev/null || true`，**绝不写 stdout**）；`telemetry_rotate [days]`（先 `[ -d runs ]||return 0`；删旧 `.jsonl` 用 `-mtime +$((days-1)) -delete`；删旧目录用 `-mindepth 1 -maxdepth 1 -type d -mtime +$((days-1)) -exec rm -rf {} +`）；dispatch/round/task/run 事件 JSON 构造器（`ts` 用 `date -u +%Y-%m-%dT%H:%M:%SZ`）。所有变量 `${VAR:-}` 兜底、所有函数 `return 0`。`smoke-telemetry.sh`（token-free）覆盖：emit 逐行 `jq -e .` 合法（含 `\r`/中文/制表符）、rotate 删非空目录（`date -v-4d`/`date -d '4 days ago'` 双分支 + `touch -t`）、`NEIL_AUTOPILOT_TELEMETRY=0` 零落盘、emit 的 stdout 为空。

**Verify**: `bash scripts/smoke-telemetry.sh`
**Status**: DONE

---

## Task 2: 埋点 dispatch.sh（修 set-e 幸存者偏差）

**Branch**: `feature/agent-observability`
**Depends**: Task 1
**Gate**: auto
**Files**:
- Modify: `scripts/dispatch.sh`

**Description**:
读 `autopilot/changes/agent-observability/spec.md` §5.2（权威）。顶部 `. "$SCRIPT_DIR/telemetry.sh"`。核心修复：`run_with_timeout` 里把 `wait "$CHILD_PID"; EXIT_CODE=$?` 改为 `EXIT_CODE=0; wait "$CHILD_PID" || EXIT_CODE=$?`（否则 set-e 在 worker 非零时当场中止，emit 与 137→124 归一化成死代码）；**137→124 归一化仅在有 `TIMEOUT_BIN` 时做**；`START=$(date +%s)` 在启动子进程前取；在 `exit $EXIT_CODE` **之前** `{ telemetry 发 dispatch 事件（stage=$AUTOPILOT_STAGE 缺省 unknown、run_id=$AUTOPILOT_RUN_ID 缺省 <date>-<pid>、model、duration_s、exit_code）; } 2>/dev/null || true`。**铁律**：worker stdout 原样不动、`EXIT_CODE` 不被遥测改写、无遥测时行为与今天完全一致。

**Verify**: `bash -n scripts/dispatch.sh && bash scripts/smoke-dispatch.sh`
**Status**: DONE

---

## Task 3: 埋点 run-track-a.sh（修 fail-closed 出口丢事件）

**Branch**: `feature/agent-observability`
**Depends**: Task 1
**Gate**: human
**Files**:
- Modify: `scripts/run-track-a.sh`

**Description**:
读 `autopilot/changes/agent-observability/spec.md` §5.3（权威）。顶部 `. "$SCRIPT_DIR/telemetry.sh"`；`LOG_DIR` 初始化后 `RUN_ID="$(basename "$LOG_DIR")"`。`dispatch_worker()` 加 `stage` 形参，用**命令级 env** `AUTOPILOT_STAGE="$stage" AUTOPILOT_RUN_ID="$RUN_ID" "$DISPATCH" …`（消除 sticky-export），4 个调用点传 `implement`/`fix`/`review`/`fix`。每轮 verify+review 后 emit `round` 事件；**3 处 `exit 2` 前各 emit `final_status=BLOCKED` 的 task 事件**、成功收尾 emit `DONE`；**新增独立 `trap … EXIT`**（勿与现有 `INT TERM` 合并）首行 `rc=$?`，据此 emit `run` 事件（outcome complete/blocked/interrupted）；`TASKS_DONE/TASKS_BLOCKED/RUN_ID` 装 trap 前初始化、trap 内 `${VAR:-}` 且 `[ -n "$RUN_ID" ]` 才 emit；`TASKS_BLOCKED` 在每个 `exit 2` 前自增。每轮 review 日志 + BLOCKED 步骤日志复制到 `$LOG_ROOT/runs/<run_id>/`（fail-safe，不可写静默跳过）。不破坏既有 loop 行为与退出码。

**Verify**: `bash -n scripts/run-track-a.sh && bash scripts/smoke-run-track-a.sh`
**Status**: DONE

---

## Task 4: daily-analysis.sh 每日分析 + smoke

**Branch**: `feature/agent-observability`
**Depends**: Task 1
**Gate**: auto
**Files**:
- Create: `scripts/daily-analysis.sh`
- Create: `scripts/smoke-daily-analysis.sh`

**Description**:
读 `autopilot/changes/agent-observability/spec.md` §5.4/§3.3/§5.5（权威）。`daily-analysis.sh`（确定性编排，**硬依赖 jq**，缺失报错 `brew install jq` 退出）：自 `$SCRIPT_DIR` 定位 `DISPATCH`；解析 `$LOG_ROOT`；保留天数 `--keep-days`>`NEIL_AUTOPILOT_KEEP_DAYS`>3；`telemetry_rotate`；**jq 聚合**当日 `runs/*.jsonl`→`metrics/<date>.json`（字段见 §3.3；跳畸形行/除零产0/`LC_ALL=C`）；**当日无新 runs 则止（省 token）**；否则 dispatch 1 个 analysis agent（`stage=analyze-daily`，`model=$AUTOPILOT_DAILY_MODEL` 缺省 Ultimate），提示词内嵌 §5.5 角色→运行时落点表（`build_impl_prompt/build_fix_prompt/build_review_prompt`；`*-prompt.md` 仅文档模板），**只读 `$LOG_ROOT`+插件仓库、只写 `$LOG_ROOT`、只出建议**；写 `reports/<date>.md`；分类回填用 `if [ -s cats ] && jq -e 'type=="array" and length>0' …; then jq --slurpfile 合并+`jq -e .`校验; fi`（缺/空/非数组跳过、绝不覆盖数值字段）。支持 `--date/--trend-days`(默认30)`/--dry-run`。`smoke-daily-analysis.sh`：fixture `runs`→断言合法 `metrics.json`；回填后数值字段不变、缺片段不覆盖。

**Verify**: `bash -n scripts/daily-analysis.sh && bash scripts/smoke-daily-analysis.sh`
**Status**: PENDING

---

## Task 5: install-daily-schedule.sh 定时安装器

**Branch**: `feature/agent-observability`
**Depends**: Task 4
**Gate**: human
**Files**:
- Create: `scripts/install-daily-schedule.sh`

**Description**:
读 `autopilot/changes/agent-observability/spec.md` §5.6（权威）。`install-daily-schedule.sh`：`uname -s` 判平台；`--hour` 默认 **13**；`--log-dir` 缺省取 `$NEIL_AUTOPILOT_LOG_DIR` 或默认值，解析**绝对路径**。macOS：生成 `~/Library/LaunchAgents/com.neil.autopilot.daily.plist`，`StartCalendarInterval` 每日 hour，`EnvironmentVariables` 写 `NEIL_AUTOPILOT_LOG_DIR`(绝对)+`NEIL_AUTOPILOT_KEEP_DAYS`+`PATH`；**PATH 动态构造逐个判空**（qodercli/jq/gtimeout 各 `p="$(command -v X||true)"; [ -n "$p" ] && dirs+=("$(dirname "$p")")`，**绝不注入 `.`**，缺 qodercli 报错中止）并上 `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`；`daily-analysis.sh` 绝对路径自 `$SCRIPT_DIR` 解析写入；`launchctl bootstrap gui/$UID` 兜底 `load`；打印 `export NEIL_AUTOPILOT_LOG_DIR=…` 供 profile；幂等重装先 unload/删旧。Linux：打印 crontab 行。**禁止硬编码用户名/家目录**（C8）。

**Verify**: `bash -n scripts/install-daily-schedule.sh`
**Status**: PENDING

---

## Task 6: 更新 README.md + AGENTS.md（文档）

**Branch**: `feature/agent-observability`
**Depends**: Task 1, Task 2, Task 3, Task 4, Task 5
**Gate**: human
**Files**:
- Modify: `README.md`
- Modify: `AGENTS.md`

**Description**:
读 `autopilot/changes/agent-observability/spec.md` 全文。**README.md** 新增"可观测性与数据驱动自进化"章节：说明能力（每次跑 autopilot 自动落 `runs/metrics/reports` 遥测；每天 13:00 分析出**针对插件角色 prompt 的改进建议**；**人工批准才改**，系统不自动改自己）；环境变量表（`NEIL_AUTOPILOT_LOG_DIR`/`NEIL_AUTOPILOT_TELEMETRY`/`NEIL_AUTOPILOT_KEEP_DAYS`/`AUTOPILOT_DAILY_MODEL`）；安装定时（`scripts/install-daily-schedule.sh`，需设 `NEIL_AUTOPILOT_LOG_DIR`）；保留策略（`runs/` 3 天滚动、`metrics/`+`reports/` 长期）。**AGENTS.md** 在脚本/平台配置处补 `telemetry.sh`/`daily-analysis.sh`/`install-daily-schedule.sh` 与新增环境变量（保持 ≤150 行，超则精简移 wiki）。保持既有文档风格。

**Verify**: `grep -q NEIL_AUTOPILOT_LOG_DIR README.md && grep -qiE 'observability|遥测|可观测|telemetry' AGENTS.md`
**Status**: PENDING
