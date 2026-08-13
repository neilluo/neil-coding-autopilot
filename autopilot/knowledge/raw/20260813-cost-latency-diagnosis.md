# 成本与时延诊断（2026-08-13）

## 背景与数据来源

本记录沉淀 `autopilot-cost-latency` 变更前的实测诊断。主要证据来自：

- `autopilot/changes/autopilot-cost-latency/spec.md`：问题表、决策、对照实验与可观测验收；输入注明为 2026-08-13 的 167 条遥测事件和 3 个 run 目录。
- `$NEIL_AUTOPILOT_LOG_DIR/runs/2026-08-13.jsonl`：dispatch/round/task/run 结构化事件。
- `$NEIL_AUTOPILOT_LOG_DIR/runs/<run_id>/`：对应 worker 与 review 原始输出。
- `$NEIL_AUTOPILOT_LOG_DIR/daily-analysis.launchd.log`：launchd 的 TCC 拒绝日志。
- `scripts/dispatch.sh`、`scripts/telemetry.sh`、`scripts/run-track-a.sh`、`scripts/daily-analysis.sh`：修复前行为的代码依据。

日志根由环境决定；历史安装常用 `$HOME/neil-autopilot-logs-analysis`，新默认值为 `$HOME/Library/Logs/neil-autopilot`。

## 实测结论

1. **review 占总墙钟 47%**：17 次 review 合计 83.3 分钟，均值 294 秒，最长 1124 秒，且使用高成本 reviewer 档位。根因是 fresh reviewer 每轮读取全量工作区与噪音文件，输入规模无上限。
2. **6 次 `review=UNKNOWN` 全部对应 `exit_code=1`**：瞬时传输失败被当成普通审查失败，消耗 review/fix 轮次；Task 2 与 Task 6 各因此失败一次，约白耗 39 分钟。
3. **timeout 无 `-k` 是哑弹**：实验 `timeout 2 bash -c 'trap "" TERM; sleep 12'` 最终虽返回 124，墙钟仍为 12 秒。只发 TERM 无法约束忽略信号的 worker。
4. **launchd 因 macOS TCC 以 126 失败**：`LastExitStatus=32256`（即 126），日志连续出现 `Operation not permitted`。原因是 `/bin/bash` 从 launchd 访问 Desktop 下的插件脚本或日志目录；结果是 `metrics/`、`reports/` 一直为空。
5. **原 telemetry 没有 token/成本字段**：旧 `dispatch` 事件只有 `ts/run_id/stage/model/duration_s/exit_code`，成本只能由时长猜测，无法按 stage/model 做真实 token 与美元成本归因。

## 修复要点

- 引入 `scripts/classify-outcome.sh`，按锚定结果、退出码和日志大小区分 `OK/TRANSPORT/TIMEOUT/EMPTY/APP`；TRANSPORT/EMPTY 有界退避重试且不推进质量轮次，TIMEOUT/APP 保持 fail-closed。
- `AUTOPILOT_TRANSPORT_RETRIES=3`，`AUTOPILOT_RETRY_BACKOFF_S=5`；每次尝试保留独立日志，避免覆盖排障证据。
- `dispatch.sh` 使用 `timeout -k "$AUTOPILOT_KILL_AFTER_S"`，默认 kill-after 30 秒；超时优先级为 CLI `--timeout` > `AUTOPILOT_TIMEOUT_<STAGE>` > `AUTOPILOT_TIMEOUT` > 内置阶段默认。
- `scripts/review-context.sh` 提供全量 stat、噪音过滤和默认 120000 字节的 diff 预算；超限必须标记 `TRUNCATED`，不静默遗漏文件。
- Qoder 路径使用 `qodercli -o json`，从信封抽取 token、成本、context、turn 和 API 时延，再把 `.result` 恢复成纯文本。缺少 jq、信封字段或合法 JSON 时，相关字段整体省略，绝不写 0 冒充已知值。
- 日志默认根迁到 `$HOME/Library/Logs/neil-autopilot`，保留期由 3 天增至 30 天；`scripts/migrate-log-root.sh` 只复制不删除并校验 JSONL 行数。
- `scripts/install-daily-schedule.sh` 对 Desktop/Documents/Downloads 做 TCC preflight：默认 stage 脚本到 `$HOME/Library/Application Support/neil-autopilot/scripts/`；若显式 `--no-stage` 且路径仍受保护，则明确失败，不生成注定返回 126 的任务。
- `scripts/daily-analysis.sh` 增加按 stage/model 的 token、成本与时延聚合；`scripts/smoke-all.sh` 作为统一 token-free 回归门。
