# Entity: telemetry-system（自观测 → 每日分析 → 数据驱动自进化）

> 2026-07-19 落地（change: agent-observability）。目的：先能测量 agent 行为，才能有依据地迭代角色 prompt（调研结论：角色 prompt 是行为方向盘、非准确率增强器）。

## 组成

| 脚本 | 职责 |
|------|------|
| `scripts/telemetry.sh` | 可 source 的 **fail-safe** 遥测库：`telemetry_log_root`（`NEIL_AUTOPILOT_LOG_DIR`→`$HOME/...`，$CWD 内降级 TMPDIR）、`telemetry_json_escape`（纯 bash，反斜杠先转）、`telemetry_emit`（只写文件、绝不污染 stdout）、`telemetry_rotate`（`.jsonl` `-delete` + 非空目录 `-exec rm -rf`）。写侧零依赖。 |
| `scripts/dispatch.sh`（埋点） | 每 worker emit `dispatch` 事件（stage/model/duration/exit_code）；修了 set-e 幸存者偏差（`wait \|\| EXIT_CODE=$?`）。 |
| `scripts/run-track-a.sh`（埋点） | emit `round`/`task`/`run` 事件；3 处 `exit 2` 前就地 emit BLOCKED task 事件 + 独立 EXIT trap emit run 事件。 |
| `scripts/daily-analysis.sh` | 确定性编排（硬依赖 jq）：rotate → jq 聚合 `runs/*.jsonl`→`metrics/<date>.json` → 当日有新数据才 dispatch 1 个 analysis agent 写 `reports/<date>.md`（分类回填走 if 包裹的 jq slurpfile 合并）。 |
| `scripts/install-daily-schedule.sh` | 生成 launchd plist（每日 13:00）/Linux crontab；PATH 动态构造逐个判空；env 固化进 plist EnvironmentVariables。 |
| `scripts/smoke-{telemetry,daily-analysis}.sh` | token-free 冒烟（C7）。 |

## 数据布局（`$LOG_ROOT`）

- `runs/YYYY-MM-DD.jsonl` 结构化事件 + `runs/<run_id>/` 关键 worker 输出 —— **默认 3 天滚动删**（`NEIL_AUTOPILOT_KEEP_DAYS`）
- `metrics/YYYY-MM-DD.json` 每日体检数（bash 聚合 + agent 回填分类）—— **长期**
- `reports/YYYY-MM-DD.md` 每日报告 + 改进建议 —— **长期**

## 关键契约

- **fail-safe 铁律**：遥测任何失败都不影响真实开发流程的 stdout/退出码；`NEIL_AUTOPILOT_TELEMETRY=0` 一键关。
- **自进化 = 纯建议 + 人工批**：每日报告只产出建议（针对**插件自身角色 prompt**：`run-track-a.sh` 的 `build_impl/fix/review_prompt`；`*-prompt.md` 是运行时不加载的文档模板），**不自动改**、不碰业务项目 AGENTS.md、不动既有 evolve per-run 行为。
- **路径 C8**：不硬编码用户名，经 `NEIL_AUTOPILOT_LOG_DIR` env（install 固化进 plist + profile export，保证交互与 launchd 两条路径同目录）。

## 运维

详见 [[dogfood-freeze-and-stall-recovery]]（改本子系统脚本时的冻结运行 + worker stall 恢复）。规范文档见 README「可观测性」章节 + AGENTS.md。
