# Explore Notes — telemetry-pluggable-sink

> 交互档（Track B）。本变更承接 `agent-observability` 上线后的一轮云端部署讨论，记录澄清过程与已锁定决策，供 analyze 生成 spec 读取。

## 需求起点

`agent-observability`（自观测→每日分析）刚落地后，用户提出：**如果以后要把 autopilot 部署到云端，现在这套方案看起来不太行。** 要求先讨论清楚，不急于写码。

## 讨论结论（多轮澄清）

**诊断**：现方案是"跨 Unix 主机可移植"（受 C6/C8 约束避免了硬编码），但**不是云原生**。进入容器/CI/多实例会撞墙：
- 调度：launchd/cron 是主机绑定的，云上要 CronJob/函数定时/CI schedule。
- 存储：写本地文件夹，容器磁盘用完即毁，日志随实例蒸发。
- 汇聚：单机读一个目录；多实例各写各的，分析读不到全量。
- 环境变量：`~/.zshrc` export 在云端非交互场景不生效。
- 凭证：qodercli 不能靠本机登录，需要 API key 走密钥管理。
- 12-factor：容器里"写本地文件"本就是反模式（应 stdout / 平台收集）。

**好消息**：本系统已**分层解耦**——采集（`telemetry.sh`→`NEIL_AUTOPILOT_LOG_DIR`）与存储位置/调度是分开的。上云本质是**换两块后端**（存储 sink + 调度器），采集代码几乎不动。

## 用户决策

- Q「云端跑什么」→ **autopilot 编排器本体上云**（无人值守/CI/后台）。
- Q「云端形态」→ **还不确定**（VM？CI？k8s？）。
- Q「现在做多少」→ **顺手做可插拔 sink**（三档里的中间档，买份保险）。

因为形态未定，正确策略是**把接缝做成形态无关**：先把"存储写入 sink"抽象成可插拔后端，默认仍是本地文件、**行为零变化**；将来落到 VM 用 file、落到临时环境换 OSS/SLS，采集侧零改动。

## 本次变更范围（锁定）

**In scope**：
- `telemetry.sh`：新增 env `NEIL_AUTOPILOT_LOG_SINK`（默认 `file`）；把 `telemetry_emit` 的唯一写入点路由到 sink 分发器；抽出 `_telemetry_sink_file`（承载现逻辑）；提供"按函数名自动发现后端"的扩展 seam。
- `smoke-telemetry.sh`：新增用例证明 seam 可插拔 + 未知 sink 安全兜底 + stdout 洁净不变。
- 文档：README / AGENTS 环境变量表 + telemetry-system entity 记录 sink seam。

**Out of scope（延迟到真部署时再做，spec 里显式声明）**：
- 真正的 `oss`/`sls` 等云后端实现（现在只做 `file` + 扩展点）。
- 调度器上云适配（CronJob/函数定时/CI）。
- 分析读侧（`daily-analysis.sh` 的 jq 聚合仍只读本地）——将来实现某云后端时连同其读侧一起做。
- `run-track-a.sh` 的"完整输出文件"复制路径（次级 bulk 产物，后续扩展）。
- 云端凭证管理、git 身份/合并审批治理、时区——已记录为已知待办，非本次。

## 关键不变量（不得削弱）

- **fail-safe**：任何 sink 在 `set -euo pipefail` 调用方下都不得中止调用方。
- **stdout 洁净**：sink 绝不写 stdout（stdout 是 worker 输出、被 parse-status 解析）。**因此本次不新增 `stdout` sink**（会破坏 in-worker 契约；云端 stdout 收集属未来专门设计）。
- bash 3.2（无关联数组/mapfile）；不引入新外部依赖。
