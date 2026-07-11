---
created: 2026-07-11
source: evolve/monitor-feedback (071102_opt.md)
evidence: primary
---

# 自带脚本用相对路径引用，在消费项目里定位不到（Track A 跨项目失效）

## Problem

Track A 靠控制器执行 `scripts/dispatch.sh` spawn worker。但该脚本只随 plugin 安装（`~/.qoder/skills/neil-coding-autopilot/scripts/`），而所有 skill 文档写的是**相对路径** `scripts/dispatch.sh`。在业务项目（如 SLS 监控 monitor）里跑时 CWD=业务项目根 → 解析成 `monitor/scripts/dispatch.sh` → 不存在 → Track A 起不来。`071102_opt.md` 现场反馈"monitor 没有 dispatch.sh、切不了 Track A"即此。

配套隐患（企业推广）：早期讨论里出现过写死 `/Users/neil/...` 绝对路径的想法——写死用户名 + macOS 专属 `~/.qoder` 布局，跨用户/跨机直接废。

## Solution

不 copy 脚本进业务项目；改为**解析出 plugin 自带那份的绝对路径** `$DISPATCH`（首个 `test -f` 通过者用）：

1. `$AGENT_DISPATCH`（显式覆盖，CI/非标准安装）
2. 注入的 skill base 目录推导 plugin 根 → `<root>/scripts/dispatch.sh`（与安装位置无关，主路径）
3. 已知安装位置 `$HOME/.qoder/skills/neil-coding-autopilot/scripts/dispatch.sh`（兜底）
4. 都无 → fail-closed 明确报错，不静默假装跑 A

集中在 `conventions.md` 作单一事实源；`dispatch.sh` 顶部加 `pwd -P` 自定位；`autopilot-init` 加 Track A 能力自检（Step 1b）；`install.sh` 结尾跑 smoke。

## Evidence

- **V2**（token-free）：从假业务项目 CWD（`/var/folders/.../tmp`）解析 → `/Users/neil/.qoder/.../dispatch.sh`，`test -f` PASS；相对 `scripts/dispatch.sh` absent（复现 bug）。
- **V4**（真实）：从外部 CWD 用解析出的绝对路径真起 qodercli(Lite) → 回 `DISPATCH_XPROJ_OK`，`dispatch_exit=0`。
- smoke ALL PASS；`dispatch.sh/smoke/parse-status/install.sh` `bash -n` 全 OK。

## Lesson

分发型 plugin 的自带脚本，引用必须"解析到绝对路径"，绝不用相对消费项目 CWD 的路径，也绝不写死用户名/家目录布局。跨项目正确性要"从一个外部目录真跑一次"才算验证（读代码看不出）。
