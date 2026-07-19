# 指南：autopilot 上云就绪（接缝策略 + 延迟路线图）

> 来源：`raw/20260719-telemetry-pluggable-sink.md`（primary）+ `changes/telemetry-pluggable-sink/explore-notes.md`。适用：把 autopilot **编排器本体**放到云端跑（无人值守 / CI）。

## 定位：现设计"跨 Unix 主机可移植"，非"云原生"

受 C6/C8 约束，本系统能从 Mac 平移到一台常开 Linux 主机；但进容器 / CI / 多实例会撞墙：

| 环节 | 现状 | 云端症结 |
|------|------|----------|
| 调度 | launchd/cron | 容器无 launchd；需 CronJob / 函数定时 / CI schedule |
| 存储 | 本地文件夹 | 容器盘用完即毁，日志蒸发 |
| 汇聚 | 单机读一目录 | 多实例各写各的，读不到全量 |
| 环境变量 | `~/.zshrc` export | 云端非交互不 source profile |
| 凭证 | 本机登录 qodercli | 需 API key 走密钥管理 + 成本护栏 |
| 时区 | 13:00 本地 | 云上 UTC，"本地"含糊 |

12-factor 视角：容器里"写本地文件"本就是反模式（应 stdout / 平台收集）。

## 策略：接缝做成形态无关（不预先押形态）

上云 = 换两块后端，采集代码不动：

- **存储 sink（✅ 已做 · step 1）**：`NEIL_AUTOPILOT_LOG_SINK`（默认 `file`）。加云后端 = 定义 `_telemetry_sink_oss/_sls(){…}`（fail-safe、不写 stdout），设 env 即切。见 entity: telemetry-system。
- **调度器（待做）**：`install-daily-schedule.sh` 已独立成脚本，加适配分支即可。

## 延迟路线图（真部署时按需做）

1. **调度器适配**：launchd/cron → k8s CronJob / 函数定时触发 / CI schedule（按选定形态）。
2. **分析读侧**：`daily-analysis.sh` 的 jq 聚合当前只读本地；实现某云后端时连同其**读侧**一起做（写读成对，否则分析读不到）。
3. **完整输出路径**：`run-track-a.sh` 复制 worker/CR 完整输出到日志目录的路径也需 sink 化（次级 bulk 产物）。
4. **凭证**：模型 API key 进密钥管理（KMS / CI secret），非交互登录；无人值守设成本护栏。
5. **git 身份 + 合并治理**：云端 finish **不应自动合主干**；改为 autopilot 推分支 + 开 PR、人事后合（本地这次是"合前问人"）。动到 HARD-GATE finish 语义。
6. **时区**：把 "13:00 本地" 钉成显式时区，而非依赖主机本地时区。

## 推荐起步形态

autopilot 是长时（~1h）、突发触发、要 git + 模型凭证的编排器：
- **首选**：一台常开 ECS/VM —— 约等于"远程 Mac"，cron 换 launchd、盘持久，改动最小。
- 按用付费再谈临时容器 / CI（须先做 sink 中心化 + 读侧）。
- k8s 多实例除非把 autopilot 当服务卖，否则过度。
