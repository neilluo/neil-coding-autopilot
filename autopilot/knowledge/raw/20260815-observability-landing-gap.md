# 可观测性「代码已写、落地断链」缺陷族（2026-08-15）

## 背景与数据来源

`autopilot-cost-latency`（2026-08-13/14）为提速省 token 做了成体系改造：review 上下文 -78.8%、入口 SKILL -45%、瞬时故障有界重试、真实 usage 记账、每日体检报告。改完使用者感到「有点不好用」。本记录沉淀复盘：**代码本身基本正确，断的是「落地」——三处让改造在真实环境里不生效，且都以「看起来成功」的形态存在。**

证据来源：

- `git log 19336f6..91df7b4`：该批改动全量范围（64 文件 +4857/-564）。
- `autopilot/changes/autopilot-cost-latency/bench-report.md`：离线实测收益（review 1000945 B → 212190 B）。
- `$NEIL_AUTOPILOT_LOG_DIR/runs/*.jsonl`（11 个文件）与 `runs/smoke-*/`：污染取证。
- `launchctl list` 的 `com.neil.autopilot.daily` 退出码、`daily-analysis.launchd.log`、`~/Library/LaunchAgents/com.neil.autopilot.daily.plist`（mtime 7-19 09:48）。
- `~/.zshrc:51` 的 `NEIL_AUTOPILOT_LOG_DIR` 实际取值。

## 实测结论

1. **smoke 遥测污染生产日志根，假数据占 90.4%**。`smoke-all.sh` 不隔离 `NEIL_AUTOPILOT_LOG_DIR`，而 `smoke-run-track-a.sh` / `smoke-run-autopilot.sh` 会跑完整 loop、每步 emit 遥测。全量统计：11702 条事件里 10576 条来自 smoke 或 `model=TestModel`；`runs/` 积压 1081 个 `smoke-*` 目录（8.7M）。8-14 单日 8317 条里 7787 条是假的（93.6%）。Task 10 声称做了「smoke 遥测隔离」，实际只覆盖了部分脚本的部分调用点。后果：daily-analysis 聚合出的 by_stage / by_model / 失败率全部失真，而那份报告正是自进化建议的唯一依据。

2. **每日任务从 7-19 起一直以退出码 126 失败，metrics/reports 全空**。`daily-analysis.launchd.log` 连续刷 `/bin/bash: …/scripts/daily-analysis.sh: Operation not permitted`——launchd 派生的进程无 TCC 授权，读不了 Desktop 下的脚本。Task 7「每日任务 TCC 修复」其实把能力做进了 `install-daily-schedule.sh`（`--stage-scripts` 把脚本副本放到 `~/Library/Application Support/neil-autopilot/scripts`，并检测受保护日志目录），**但装在机器上的 plist 从未重新生成**，仍指向 Desktop 路径、`KEEP_DAYS=3`、日志根也在 Desktop（同样受 TCC 限制，写不进去）。代码正确 + 未重装 = 能力为零。

3. **日志根存在「文档默认 vs 实际取值」漂移**。代码/文档默认已改为 TCC 安全的 `~/Library/Logs/neil-autopilot`，但 `~/.zshrc` 仍 export 旧的 `Desktop/neilcodebase/neil-autopilot-logs-analysis`，env 优先级更高，所以新默认值从未生效。只修 plist 不改 shell 会造成更糟的裂脑：交互运行写旧根、定时任务读新根，报告永远看不到当天数据。

4. **daily-analysis 以 dispatch 退出码定成败，产生「假成功」**。它只判 `$DISPATCH` 的返回值，从不校验 `reports/<date>.md` 是否真的存在。实测：analysis agent 把整个回合收在 `thinking/redacted_thinking` 里、一字未写、rc 仍为 0，于是脚本照样打印 `done: report(s) under …`，而 `reports/` 是空的。这类假成功比直接失败更危险——使用者以为有体检报告，实际连续一个月无产出。

5. **该阶段只 dispatch 一次、无重试，对静默回合零容错**。同样的静默在 `run-track-a.sh` 里被有界重试兜住（实测 implement 前两次静默、第三次成功），而 daily-analysis 一次不中当日就永久没报告。

6. **静默回合在遥测里原本不可测量**。它 `exit_code=0`，既不计入 `dispatch_error_count` 也不计入 `dispatch_timeout_count`，`failure_class` 又缺失，因此花了真实 token 却在每日报告里完全隐形——这正是它长期没被发现的结构性原因。8-14 的日志按新口径统计得到「0 次静默」，不是没发生，而是当时没有标签。

7. **AGENTS.md 的 `AUTOPILOT_USAGE_JSON` 默认值写成 1，代码实际是 0**。而这个开关恰恰是「带 `-o json` 导致 headless 工具循环 0/5 成功」的元凶。照文档配置会直接把 worker 打回 100% 空转。

## 修复要点

- **遥测隔离收口到单点**：`smoke-all.sh` 建 `mktemp -d` 沙箱并 `export NEIL_AUTOPILOT_LOG_DIR`，子进程全部继承，新增 smoke 自动安全；两个跑全量 loop 的 smoke 用 `: "${VAR:=$WORK/telemetry}"` 兜住单独运行。收尾新增隔离自检：沙箱里没有 `runs/` 即报错（事件跑到沙箱外比 smoke 挂掉更隐蔽）。
- **历史数据还原**：先整体备份 11 个 jsonl 到 `neil-autopilot-logs-backup-20260815/`，再按 `run_id ^smoke-` 或 `model==TestModel` 过滤，逐文件校验预期行数与实际行数一致后才替换；删除 1081 个 `smoke-*` 目录。结果 11702 → 1126 条真实事件，8.7M → 1.0M。
- **TCC 落地**：`migrate-log-root.sh` 只拷不删迁到 `~/Library/Logs/neil-autopilot` 并校验 JSONL 行数（1126 = 1126，旧目录保留）；`.zshrc` 幂等替换那一行（先备份 `.bak-20260815`）避免裂脑；`install-daily-schedule.sh --stage-scripts` 重装 plist。验证：退出码 **126 → 0**，`metrics/2026-08-15.json` 首次产出。
- **产物硬校验**：daily-analysis 改为按 `reports/<date>.md` 是否落盘定成败；缺失时打印 worker 的锚定结论解析结果与末尾输出，结尾文案区分 `done` 与 `done with WARNINGS`，绝不再谎称有报告。
- **有界重试**：新增 `AUTOPILOT_DAILY_RETRIES`（默认 3），以「报告是否落盘」为退出条件——本任务幂等（只读遥测 + 重写同一份报告），重试无副作用，成功即停不白烧 token。同时给该阶段 prompt 补上「报告格式」结论行，与全系统的锚定标记契约对齐。
- **让静默可测**：metrics 新增 `dispatch_silent_count`（thinking-only）、`dispatch_silent_dirty_count`（静默但已改盘）、`dispatch_silent_seconds`，静默回合从此进入趋势对比。
- **文档纠偏**：`AUTOPILOT_USAGE_JSON` 默认值改回 0 并写明「默认关闭是功能性约束」；`install-daily-schedule.sh` 条目显式标注「插件改动后必须重跑，staged 副本不会自动跟随仓库」。

## 回归覆盖（C7 verify-by-running）

- `smoke-daily-analysis.sh` 新增 scenario 6（`silent` stub：rc=0、零输出、不写文件 → 必须重试满 3 次、无报告、打印 `no report was produced`、且不出现 `done: report`、metrics 仍有效）与 scenario 7（`silent_then_ok`：第 2 次才写出 → 必须停在第 2 次，不浪费第 3 次调用）；聚合断言新增静默三指标（1 / 1 / 25s）。
- 隔离效果实测：修复前每跑一次 smoke-all 向生产日志根写入数百条事件；修复后同一套 smoke 跑完，生产根新增 **0 目录 / 0 行**。
- `smoke-all.sh` 19/19 全绿。

## 教训（可复用）

- **「改造已完成」不等于「改造已生效」**。凡是依赖机器上一份安装态产物（launchd plist、staged 脚本副本、shell env）的能力，代码改完必须同时验证安装态；否则会长期停在「代码正确、能力为零」。
- **默认值改动要连同覆盖来源一起改**。env 优先级高于代码默认值，只改默认值等于没改；且只改一半（改 plist 不改 shell）会从「不生效」恶化为「裂脑」。
- **凡是「产出一份产物」的 agent 步骤，成败判据必须是产物本身，而不是调度器退出码**。LLM 步骤可以 rc=0 却什么都没做，用退出码判定就会稳定地产出假成功。
- **测试与生产共用同一个可观测 sink 时，隔离必须做在唯一入口**。逐个测试脚本自觉隔离必然漏，而漏出来的表现是数据慢慢变假，没有任何报错。

## 待观察

- staged 脚本副本仍需人工在插件改动后重跑 `install-daily-schedule.sh --stage-scripts`（TCC 决定了 launchd 侧读不到 Desktop 源码，无法自动刷新）。当前靠 AGENTS.md 显式标注；若再次踩坑，可考虑在 staged 副本里记录源码指纹并在每日日志打印「staged 副本可能已过期」。
- 本次静默率：6/33 次真实 dispatch（约 18%），全部由重试恢复，浪费 83 秒墙钟。该数字现已可被每日报告持续跟踪。
