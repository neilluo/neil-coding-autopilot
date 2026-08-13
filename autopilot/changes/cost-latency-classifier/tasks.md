# Tasks — autopilot 成本与时延治理

> Spec: `autopilot/changes/autopilot-cost-latency/spec.md`（**每个 Task 开工前必读**，尤其 §2 决策表与 §4 可观测验收）
> 全局 verify: `bash scripts/smoke-all.sh`
> 项目根: `/Users/neil/Desktop/neilcodebase/neil-coding-autopilot`
> 分支: `fix/autopilot-cost-latency`

## 全局铁律（所有 Task 都适用，开工前连同 spec 一起读）

0. **先落盘、再解释（最高优先级执行纪律）**：拿到任务后**立刻**用 Write/Edit 把文件写出来，**禁止**先输出长篇分析或"让我先读一下…"式的铺垫。实测教训：环境存在约 60s 的空闲断流，worker 在分析阶段被掐断已连续发生 4 次（3~5 分钟、0 文件落盘）。解释压缩到最后一两句。回复**末尾必须有独占一行**的 `**Status:** DONE`（或 `**Status:** BLOCKED`），行内不得夹带其它文字——解析器只认末 15 行里行首锚定的这一行。
0. **不得修改本文件的 `**Verify**` 行，不得为过关放水**：禁止删除/弱化既有 smoke 断言、禁止给 smoke 加 `exit 0` 兜底、禁止把断言改成 `|| true`。验证命令本身有问题 ⟹ 回复里说明并输出 `**Status:** BLOCKED`，不要自己改计划。
1. **基线**：改动前 11 个 smoke 全绿（`smoke-dispatch/run-track-a/run-autopilot/telemetry/guard/bash-guard/daily-analysis/archive-change/kb-path/kb-search/migrate-archive-layout`）。**一个都不许弄挂**。
2. **bash 3.2 + BSD 工具**（macOS stock，见 AGENTS.md）：禁关联数组、`mapfile`、`grep -P`、`readlink -f`、GNU-only `sed -i` 无后缀；`sed -i.bak` + `rm -f *.bak`；`stat` 用双分支（`stat -f '%m'` / `stat -c '%Y'`）。所有脚本 `set -euo pipefail` + `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"` 自定位。
3. **新脚本必须**：可执行位（`chmod +x`）、顶部注释块说明 WHAT/USAGE/EXIT CODES、支持 `-h|--help`、纯函数式（不写全局副作用）。
4. **smoke 一律零成本零副作用**：禁调真实 `qodercli`（用 PATH 前置 stub）、禁 `launchctl`、禁写真实 `~/Library/LaunchAgents`、禁碰真实 `$NEIL_AUTOPILOT_LOG_DIR`（一律 `NEIL_AUTOPILOT_LOG_DIR="$tmp"`）、禁外网。临时产物只放 `$(mktemp -d)` 并 `trap 'rm -rf ...' EXIT`。
5. **向后兼容**：telemetry 字段只增不改名不改序；`dispatch.sh` 既有 flag 与退出码语义不变；`AUTOPILOT_TIMEOUT` 仍生效。
6. **不删用户数据**：任何脚本不得 `rm -rf` 用户日志目录；迁移只复制。
7. **不引入 Task 描述外的功能**；异常不静默吞（catch 后必须打日志或返回非零）。
8. **自修改注意**：本仓库的 `scripts/run-track-a.sh` 正被一个**冻结快照**执行（控制器从 `$TMPDIR` 跑），你改的是仓库副本，改动下次运行才生效——这是预期行为，不要试图"让它立刻生效"，也不要在 Verify 里去跑真实 loop。

## Task 1: smoke-parse-markers.sh —— D19 六条判别样例

**Status**: DONE

> **执行纪律（必读，实测教训）**：拿到任务**立刻用 Write/Edit 落盘**，禁止先输出长篇分析或"让我先读一下…" —— 本环境存在约 60s 空闲断流，已多次在分析阶段被掐断导致 **0 文件落盘、白耗一轮**。需要读文件就直接读、读完马上写。解释压缩到最后一两句。
> 回复**末尾必须有独占一行**的 `**Status:** DONE`（或 `**Status:** BLOCKED`），该行**不得夹带其它文字**——解析器只认末 15 行里行首锚定的这一行，行内提及一概不算。

**只做一件事**：新建 `scripts/smoke-parse-markers.sh`（不改其它文件）。用 fixture 逐条断言 `scripts/parse-markers.sh`，六条**全部必须有**（spec §11 D19 第 5 条）：

1. 真实截断日志（正文行内提及四个标记名、末尾无锚定行）→ `status` 得 `UNKNOWN`。fixture 正文直接用：
   `- Add verdict marker check (REVIEW_PASS/REVIEW_FAIL/**Status:** DONE/**Status:** BLOCKED) before transport`
2. 末尾 `**Status:** DONE` 独占一行 → `DONE`。
3. 正文中段有 `**Status:** DONE`，但其后追加 20 行无关内容（挤出末 15 行窗口）→ `UNKNOWN`。
4. 末行 `REVIEW_PASS` → `REVIEW_PASS`。
5. 末行 `REVIEW_PASS   # 无 CRITICAL/MAJOR` → `UNKNOWN`（行内夹带说明不成立）。
6. 末尾先 `REVIEW_FAIL` 行、后 `REVIEW_PASS` 行 → 取最后 = `REVIEW_PASS`。

再加两条边界：文件不存在 → `UNKNOWN` 且退出码 0；中文冒号 `Status：DONE` → `DONE`。
风格对齐现有 smoke（`set -euo pipefail`、临时目录 `mktemp -d` + trap 清理、失败打印期望/实际并 exit 1、全绿打印 PASS）。开头 `unset AUTOPILOT_RUN_ID`（避免污染真实遥测）。

**Verify**: `bash scripts/smoke-parse-markers.sh && bash scripts/smoke-all.sh`

## Task 2: classify-outcome.sh 改用锚定解析 + D18 长度门

**Status**: PENDING

> **执行纪律（必读，实测教训）**：拿到任务**立刻用 Write/Edit 落盘**，禁止先输出长篇分析或"让我先读一下…" —— 本环境存在约 60s 空闲断流，已多次在分析阶段被掐断导致 **0 文件落盘、白耗一轮**。需要读文件就直接读、读完马上写。解释压缩到最后一两句。
> 回复**末尾必须有独占一行**的 `**Status:** DONE`（或 `**Status:** BLOCKED`），该行**不得夹带其它文字**——解析器只认末 15 行里行首锚定的这一行，行内提及一概不算。

**只改两个文件**：`scripts/classify-outcome.sh` 与 `scripts/smoke-classify-outcome.sh`。

1. `classify-outcome.sh` 判定顺序按 spec §9 D18（已被 §11 D19 修订）重排：
   1) `exit_code ∈ {124,137}` → `TIMEOUT`
   2) **调 `scripts/parse-markers.sh`**（同目录，用 `$(dirname "$0")` 定位）：`status` 或 `review` 任一得到非 `UNKNOWN` ⟹ `exit_code==0` 则 `OK`，否则 `APP`。**不得**自己写正则。
   3) 传输层正则：仅当 `日志字节数 < ${AUTOPILOT_TRANSPORT_LOG_BYTES:-4096}` 且只对 `tail -20` 匹配 → `TRANSPORT`
   4) `exit_code != 0` 且字节数 < `${AUTOPILOT_EMPTY_LOG_BYTES:-300}` → `TRANSPORT`
   5) `exit_code == 0` 且字节数 < 同阈值 → `EMPTY`
   6) `exit_code != 0` → `APP`
   7) 否则 → `OK`
   保持原 CLI 契约：`classify-outcome.sh <exit_code> <log>`、stdout 恰好一个词、退出码恒 0。
2. `smoke-classify-outcome.sh` 保留全部既有断言，**新增四条判别样例**：
   - `exit 1` + >300B CR 正文且**逐字含 `Unable to connect`** + 末行 `REVIEW_FAIL` → `APP`（旧实现在此错判 TRANSPORT）
   - 短日志仅 `Unable to connect.` → 仍 `TRANSPORT`
   - 6KB 正文、其 `tail -20` 内含 `502 Bad Gateway`、无锚定标记 → `APP`（超长度门）
   - 250B 且末行 `**Status:** DONE`、`exit 0` → `OK`（短但有结论，不得判 EMPTY）
3. 开头 `unset AUTOPILOT_RUN_ID`。

**Verify**: `bash scripts/smoke-classify-outcome.sh && bash scripts/smoke-all.sh`
