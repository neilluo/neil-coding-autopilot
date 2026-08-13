# Entity: telemetry-system（自观测 → 每日分析 → 数据驱动自进化）

> 2026-07-19 落地（change: agent-observability），2026-08-13 增补成本与时延字段。来源：`raw/20260813-cost-latency-diagnosis.md`。目的：先能测量 agent 行为，才能有依据地迭代角色 prompt（调研结论：角色 prompt 是行为方向盘、非准确率增强器）。

## 组成

| 脚本 | 职责 |
|------|------|
| `scripts/telemetry.sh` | 可 source 的 **fail-safe** 遥测库：`telemetry_log_root`（`NEIL_AUTOPILOT_LOG_DIR`→`$HOME/...`，$CWD 内降级 TMPDIR）、`telemetry_json_escape`（纯 bash，反斜杠先转）、`telemetry_emit`（路由到可插拔 sink、绝不污染 stdout）、`telemetry_rotate`（`.jsonl` `-delete` + 非空目录 `-exec rm -rf`）。写侧零依赖。 |
| `scripts/dispatch.sh`（埋点） | 每 worker emit `dispatch` 事件；Qoder + jq 默认用 `qodercli -o json`，从信封抽 usage/cost 后把 `.result` 还原为纯文本 stdout。 |
| `scripts/run-track-a.sh`（埋点） | emit `round`/`task`/`run` 事件；3 处 `exit 2` 前就地 emit BLOCKED task 事件 + 独立 EXIT trap emit run 事件。 |
| `scripts/daily-analysis.sh` | 确定性编排（硬依赖 jq）：rotate → jq 聚合 `runs/*.jsonl`→`metrics/<date>.json` → 当日有新数据才 dispatch 1 个 analysis agent 写 `reports/<date>.md`（分类回填走 if 包裹的 jq slurpfile 合并）。 |
| `scripts/install-daily-schedule.sh` | 生成 launchd plist（每日 13:00）/Linux crontab；TCC 前缀预检，必要时 stage 脚本；env 固化进 plist EnvironmentVariables。 |
| `scripts/classify-outcome.sh` | 将 worker 结果分成 `OK/TRANSPORT/TIMEOUT/EMPTY/APP`，瞬时失败可重试且不消耗质量轮次。 |
| `scripts/review-context.sh` | 输出全量 stat + 预算内 diff，默认 120000 字节；裁剪时显式 `TRUNCATED`。 |
| `scripts/migrate-log-root.sh` | 从旧日志根只复制 runs/metrics/reports 到非 TCC 默认目录，迁移后校验 JSONL 行数，不删源目录。 |
| `scripts/smoke-all.sh` | fail-fast 串行运行全部 token-free smoke，是统一回归入口（C7）。 |
| `scripts/smoke-{telemetry,daily-analysis}.sh` | token-free 冒烟（C7）。 |

## 数据布局（`$LOG_ROOT`）

- `runs/YYYY-MM-DD.jsonl` 结构化事件 + `runs/<run_id>/` 关键 worker 输出 —— **默认 30 天滚动删**（`NEIL_AUTOPILOT_KEEP_DAYS`）
- `metrics/YYYY-MM-DD.json` 每日体检数（bash 聚合 + agent 回填分类）—— **长期**
- `reports/YYYY-MM-DD.md` 每日报告 + 改进建议 —— **长期**


### dispatch 事件新增字段

| JSON 字段 | qodercli JSON 信封/运行时来源 | 语义 |
|-----------|------------------------------|------|
| `input_tokens` | `.usage.input_tokens` | 输入 token |
| `output_tokens` | `.usage.output_tokens` | 输出 token |
| `cache_read_tokens` | `.usage.cache_read_input_tokens` | 缓存读取 token |
| `cost_usd` | `.total_cost_usd` | 本次调用美元成本 |
| `context_ratio` | `.usage.context_usage_ratio` | 上下文使用比例 |
| `num_turns` | `.num_turns` | agent turn 数 |
| `api_ms` | `.duration_api_ms` | API 时延毫秒 |
| `attempt` | `AUTOPILOT_ATTEMPT`，默认 1 | 当前传输尝试序号 |
| `failure_class` | outcome/timeout 分类 | `TRANSPORT/TIMEOUT/EMPTY/APP` 等失败类别 |
| `prompt_bytes` | prompt 文件字节数 | 调度输入体积 |
| `output_bytes` | 原始 worker 输出字节数 | 调度输出体积 |
| `is_error` | `.is_error` | qodercli 信封错误标志 |

Token 与成本的单一事实源是 `qodercli -o json` 信封。仅当平台为 Qoder、`AUTOPILOT_USAGE_JSON!=0`、存在 jq 且信封可解析时抽取；缺失、null、非 JSON、无 jq 或非 Qoder 平台时，相关字段**整体省略，不写 0 或 null**。这样可区分“真实为 0”和“未知”。`AUTOPILOT_RAW_JSON` 可选保留原始信封，stdout 始终恢复为 `.result` 文本以维持状态解析契约。

## 关键契约

- **fail-safe 铁律**：遥测任何失败都不影响真实开发流程的 stdout/退出码；`NEIL_AUTOPILOT_TELEMETRY=0` 一键关。
- **自进化 = 纯建议 + 人工批**：每日报告只产出建议（针对**插件自身角色 prompt**：`run-track-a.sh` 的 `build_impl/fix/review_prompt`；`*-prompt.md` 是运行时不加载的文档模板），**不自动改**、不碰业务项目 AGENTS.md、不动既有 evolve per-run 行为。
- **路径 C8**：不硬编码用户名，默认 `$HOME/Library/Logs/neil-autopilot`，也可经 `NEIL_AUTOPILOT_LOG_DIR` env（install 固化进 plist + profile export，保证交互与 launchd 两条路径同目录）。

## Sink 可插拔 seam（change: telemetry-pluggable-sink，云端保险）

`telemetry_emit` 的唯一写入点已改为路由式：`telemetry_emit` → `_telemetry_sink_dispatch`（按 `${NEIL_AUTOPILOT_LOG_SINK:-file}` 组函数名 `_telemetry_sink_<name>`，`_telemetry_is_function` 判存在，**绝不 eval**）→ 命中则调用该函数，未命中兜底回退 `_telemetry_sink_file`（现有本地文件逻辑原样抽出）。加新后端只需按约定命名新增一个 `_telemetry_sink_<name>()` 函数（同 fail-safe 契约），分发器代码零改动。

**Out of scope（本次显式不做，写侧 only）**：真实云后端（`oss`/`sls` 等）实现、调度器上云（launchd/cron→CronJob/函数定时）、`daily-analysis.sh` 读侧适配、`run-track-a.sh` 完整输出复制路径、云端凭证/git 身份/时区治理——均延迟到真正上云部署时的后续变更。**不新增 `stdout` sink**：stdout 是 worker 输出通道（被 parse-status.sh 解析），加 stdout sink 会破坏该契约。`telemetry_rotate` 仍只对 `file` 后端生效，云后端留存交由其自身机制（bucket 生命周期 / 日志服务 TTL）。

## 运维

详见 [[dogfood-freeze-and-stall-recovery]]（改本子系统脚本时的冻结运行 + worker stall 恢复）。规范文档见 README「可观测性」章节 + AGENTS.md。
