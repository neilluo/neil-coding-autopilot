# Spec — autopilot 成本与时延治理（cost & latency）

> 档位 B（交互编排 + loop 托管）｜分支 `fix/autopilot-cost-latency`｜被开发项目 = 本 plugin 仓库
> 输入：2026-08-13 的实测诊断（遥测 `runs/2026-08-13.jsonl` 167 事件 + 3 个 run 目录 + 确定性超时实验）

## 1. 问题（全部有实测证据，非推测）

| # | 问题 | 证据 |
|---|------|------|
| P1 | **瞬时故障被当成"审查不通过"**，每次抖动吃掉一轮 `MAX_ROUNDS`，3 轮用尽 → 整个 Task BLOCKED → 下轮 `--resume` 重跑 implement | 今天 6 次 `review=UNKNOWN` 全部 `exit_code=1`；`run-track-a.sh` 的 `dispatch_worker` 拿到 rc 只打 WARN 就 `return 0` 丢弃；Task 2/6 各被毁一次，合计白烧约 39 分钟 |
| P2 | **拿不到真实 token/成本**，只能用时长猜 | telemetry `dispatch` 事件仅 ts/run_id/stage/model/duration_s/exit_code |
| P3 | **review 成本无上限**：prompt 让 reviewer「逐一读取完整内容」`git status` 全量清单（含 `autopilot/changes/*/tasks.md` 等噪音），每轮 fresh context 重读 | review 占 47% 墙钟（83.3 分 / 17 次，均值 294s，最长 1124s），且用 Ultimate 档 |
| P4 | **timeout 是哑弹**：`timeout <s> <cmd>` 无 `-k`，worker 屏蔽/延迟响应 SIGTERM 时上限失效 | 实测 `timeout 2 bash -c 'trap "" TERM; sleep 12'` → exit=124 但**实耗 12s** |
| P5 | **每日成本分析从未跑起来**：launchd 下 /bin/bash 读 `~/Desktop` 被 macOS TCC 拒 | `LastExitStatus=32256`(=126) + `daily-analysis.launchd.log` 连续 `Operation not permitted`；`metrics/`、`reports/` 全空 |
| P6 | 控制器每轮固定背约 35KB（SKILL.md 16.4 + conventions 12.3 + observable-acceptance 6.4） | `wc -c`；session-start hook 注入 `skills/using-neil-autopilot/SKILL.md` |

**非目标**（用户已拍板）：Task 并行（多 worker 同仓 `git add -A` 三重竞态，正确解是 git worktree 隔离，属独立大特性）。

## 2. 关键决策（已冻结）

| # | 决策 | 理由 |
|---|------|------|
| D1 | 新增 `scripts/classify-outcome.sh <exit_code> <log>` 纯函数，输出 `OK|TRANSPORT|TIMEOUT|EMPTY|APP` 五态 | 分类逻辑必须可单测、可复用，不塞进调用点 |
| D2 | `TRANSPORT`/`EMPTY` → 退避重试且**不推进 round**；`TIMEOUT`/`APP` → 不重试 | 抖动不等于质量问题；超时重试只会烧更多；APP（跑完但无结论）仍 fail-closed 交 fixer |
| D3 | 重试参数：`AUTOPILOT_TRANSPORT_RETRIES`（默认 3）、`AUTOPILOT_RETRY_BACKOFF_S`（默认 5，指数 5/10/20） | 有界、可关（设 0 即旧行为） |
| D4 | 每次尝试独立日志 `task-N-<stage>-R-a<attempt>.log`，绝不覆盖 | 排障需要看到每次抖动原文 |
| D5 | dispatch 改用 `qodercli -o json` 抓 usage，**再把 `.result` 还原成纯文本喂给 stdout** | 既拿到真实 token/成本，又保持 `parse-status.sh` / `parse_review` 的文本契约不变；原始 JSON 另存 `<outlog>.json` |
| D6 | 无 `jq` / 输出非合法 JSON / 非 qoder 平台 → 自动退回 `-o text`，token 字段**整体缺省**（绝不写 0 冒充） | 观测数据必须可信；0 与"未知"不是一回事 |
| D7 | telemetry `dispatch` 事件**只增字段不改名**：`input_tokens` `output_tokens` `cache_read_tokens` `cost_usd` `context_ratio` `num_turns` `api_ms` `attempt` `failure_class` `prompt_bytes` `output_bytes` | 下游 `daily-analysis.sh` 的 jq 用事件类型过滤，对多余字段包容 |
| D8 | review 上下文改为 `scripts/review-context.sh` 产出的**有界 diff**：`git diff --stat` 全量 + unified diff 按 `AUTOPILOT_REVIEW_DIFF_BUDGET`（默认 120000 字节）裁剪 + untracked 文件内容；超预算显式标 `TRUNCATED` 并保留完整 stat | 砍掉最大可变成本，但**不许静默丢文件**——reviewer 仍可按需自行打开文件 |
| D9 | 噪音过滤清单：`autopilot/changes/*/tasks.md`（状态行由脚本改）、`*.lock`、`package-lock.json`、`dist/`、`build/`、`target/`、`node_modules/`、`*.min.*` | 这些进 review 纯烧 token |
| D10 | dispatch 加 `-k ${AUTOPILOT_KILL_AFTER_S:-30}`；超时优先级 `--timeout` > `AUTOPILOT_TIMEOUT_<STAGE>` > `AUTOPILOT_TIMEOUT` > 内置 stage 默认（review 900 / implement 1800 / fix 900 / 其他 600） | 补哑弹 + 控长尾；保留全局变量优先以兼容既有 `.zshrc` 配置（文档提示改用 stage 变量） |
| D11 | `NEIL_AUTOPILOT_LOG_DIR` 默认值改为 `${HOME}/Library/Logs/neil-autopilot`（非 TCC）；新增 `scripts/migrate-log-root.sh` **只复制不删除**旧数据 | 用户已选"搬到非 TCC 目录"；删用户历史数据不可逆，一律不做 |
| D12 | `install-daily-schedule.sh` 加 TCC preflight：脚本路径或 LOG_DIR 落在 `$HOME/{Desktop,Documents,Downloads}` 时，默认 `--stage-scripts` 把 `scripts/` 复制到 `${HOME}/Library/Application Support/neil-autopilot/scripts/` 并让 plist 指向副本；`--no-stage` 且仍处 TCC 路径 → **exit 非 0 + 打印可执行修复指令**，绝不静默生成注定 126 的 plist | 静默失败是最坏形态 |
| D13 | `NEIL_AUTOPILOT_KEEP_DAYS` 默认 3 → **30**；`telemetry_rotate` 调用点保持只在 daily-analysis（**不**加进 run-track-a） | 3 天对成本分析太短；自动删历史数据的能力不扩散到主链路 |
| D14 | SKILL.md 渐进式加载：HARD-GATE / 执行档位 / 铁律 / 任务分流 / Skill 调用规则 / 路径约定 / 状态行**留在正文**；DOT 流程图、目录结构树、初始化 bash 模板、progress.md 模板、使用示例、恢复机制下沉 `references/`，正文给明确「何时读哪篇」指针 | 只下沉**参考性**内容，强制性约束一条不动 |
| D15 | 新增 `scripts/smoke-all.sh` 串跑全部 `smoke-*.sh`（fail-fast），作为统一回归门 | 11 个 smoke 现全绿（基线），后续每个 Task 的 Verify 都用它 |

## 3. 变更清单

| 文件 | 动作 |
|------|------|
| `scripts/classify-outcome.sh` | 新建（五态分类纯函数） |
| `scripts/smoke-classify-outcome.sh` | 新建 |
| `scripts/smoke-all.sh` | 新建（统一回归门） |
| `scripts/dispatch.sh` | 改：`-o json` + usage 提取 + `.result` 还原 + `-k` + 分级超时 + 传新字段给 telemetry |
| `scripts/telemetry.sh` | 改：`telemetry_emit_dispatch` 支持可选新字段；`KEEP_DAYS` 默认 30；`LOG_DIR` 默认改 `~/Library/Logs/neil-autopilot` |
| `scripts/run-track-a.sh` | 改：`dispatch_worker` 传播 outcome；新增 `dispatch_with_retry`；三处接线；BLOCKED 原因带 `failure_class`；review 上下文改用 `review-context.sh` |
| `scripts/review-context.sh` | 新建（有界 diff + 噪音过滤） |
| `scripts/smoke-review-context.sh` | 新建 |
| `scripts/smoke-dispatch.sh` | 改：加 kill-after / 分级超时 / usage 提取 / jq 缺失退化 断言 |
| `scripts/smoke-run-track-a.sh` | 改：加 TRANSPORT-RETRY、TIMEOUT-NO-RETRY、APP-FAIL-CLOSED 三个 scenario |
| `scripts/smoke-telemetry.sh` | 改：加 token 字段断言 + 缺省断言 |
| `scripts/daily-analysis.sh` | 改：metrics 增 token/cost 聚合（按 stage/model） |
| `scripts/smoke-daily-analysis.sh` | 改：加 token 聚合断言 |
| `scripts/install-daily-schedule.sh` | 改：TCC preflight + `--stage-scripts` / `--no-stage` |
| `scripts/smoke-install-daily-schedule.sh` | 新建（假 HOME 隔离，禁真实 launchctl） |
| `scripts/migrate-log-root.sh` | 新建（只复制不删除 + 行数校验） |
| `scripts/smoke-migrate-log-root.sh` | 新建 |
| `skills/using-neil-autopilot/SKILL.md` | 改：瘦身 ≤9KB + references 指针 |
| `skills/using-neil-autopilot/references/*.md` | 新建 5 篇（workflow-graph / directory-layout / bootstrap / usage-examples / recovery） |
| `scripts/smoke-skill-invariants.sh` | 新建（不变量 grep 门禁） |
| `AGENTS.md` | 改：环境变量表补全新变量 + 观测脚本清单 |
| `autopilot/knowledge/raw/` + `wiki/entities/telemetry-system.md` | 改/新增：本次结论沉淀 |

## 4. 可观测验收

> 依据 `skills/_shared/observable-acceptance.md`。本变更的"终端可观测输出"= **CLI/driver 日志 + telemetry 报表 + 注入给控制器的 SKILL 文本**，全部可离线确定性验证（smoke harness + stub CLI），无 `UNVERIFIED-OBSERVABLE` 项。

### O1 · 瞬时故障不消耗 CR 轮次
- **SSOT**：`(dispatch exit_code, worker 输出文本)` 经 `classify-outcome.sh` 得出的 outcome class。
- **不变量**：`TRANSPORT`/`EMPTY` 的尝试**不推进** round 计数、不触发 fixer；`APP`（跑完但无 verdict）仍 fail-closed 交 fixer 并占一轮；`TIMEOUT` 立即 BLOCKED 且不重试；任一路径都不得静默 commit 未审代码。
- **MR**：固定权威源（stub 恒 `exit 1` + 文本 `Unable to connect`），逐轴扰动非权威源 —— stage 属于 {review, implement, fix}、tasks 数 属于 {1,2}、verify 属于 {pass, fail} —— 断言 driver 日志里 round 恒为 1、重试次数恒等于 `AUTOPILOT_TRANSPORT_RETRIES`、最终 BLOCKED 原因含 `transport`。
- **判别样例**（两候选源期望不同）：① `exit 1` + `Unable to connect`（<300B）→ 重试、round 不变；② `exit 1` + 一段大于 300B 的真实 CR 文本（含 `REVIEW_FAIL` 与 `文件:行号`）→ **不重试**、走 fixer、round+1。若实现只看 exit_code 就重试，②会被误判 → 被抓。
- **Verify**：`bash scripts/smoke-all.sh`（新 scenario 在 `smoke-run-track-a.sh`）

### O2 · telemetry 含真实 token / 成本，且不可信时缺省
- **SSOT**：`qodercli -o json` 信封的 `usage.*` / `total_cost_usd` / `context_usage_ratio`。
- **不变量**：每次 dispatch 恰好 1 条 `event=dispatch`；有 jq 且信封可解析时，jsonl 中 token/cost 字段**数值等于信封值**；否则字段整体不出现（不写 0）；无论走哪条分支，worker 的人类可读文本必须完整出现在 outlog（`**Status:** DONE` / `REVIEW_PASS` 仍可被现有解析器抓到）。
- **MR**：固定信封（stub 输出固定 usage JSON），扰动 stage/model/是否超时 → 断言 token 字段恒等于信封值；扰动"jq 不可用"（PATH 屏蔽 jq）→ 断言退化为无 token 字段、但 dispatch 事件仍产出**且 outlog 仍含状态行**。
- **判别样例**："缺 jq 时写 0" 与 "缺 jq 时不写该字段" 期望不同；"`-o json` 后忘记还原 `.result`" 会让状态行消失 → 被抓。
- **Verify**：`bash scripts/smoke-all.sh`（`smoke-dispatch.sh` + `smoke-telemetry.sh`）

### O3 · review 上下文是有界 diff 且不静默丢文件
- **SSOT**：工作区相对 HEAD 的 `git diff` + untracked 文件内容，经 D9 过滤与 D8 预算裁剪。
- **不变量**：产出字节数不超过 budget；D9 清单内路径不出现在 diff 正文；`--stat` 的文件条目**始终完整**（不随 budget 变化）；发生裁剪时必须出现 `TRUNCATED` 标记与未展开文件清单。
- **MR**：固定同一组变更，扰动 budget（大 → 小 → 极小）→ 断言 ① 输出恒不超预算 ② `--stat` 条目数恒定 ③ 小 budget 时出现 `TRUNCATED`；另扰动"额外新增 `node_modules/x.js` 与 `autopilot/changes/foo/tasks.md` 变更"→ 断言二者不在 diff 正文、而正常源文件仍在。
- **判别样例**："裁剪时直接少列文件" 与 "保留 stat + 标 TRUNCATED" 期望不同。
- **Verify**：`bash scripts/smoke-all.sh`（`smoke-review-context.sh`）

### O4 · 超时真能杀死（哑弹修复）
- **SSOT**：生效超时值 = `--timeout` > `AUTOPILOT_TIMEOUT_<STAGE>` > `AUTOPILOT_TIMEOUT` > 内置 stage 默认。
- **不变量**：无论 worker 是否屏蔽 SIGTERM，dispatch 墙钟不超过 `timeout + kill_after + 5s`；超时时 exit=124 且 telemetry `failure_class=TIMEOUT`。
- **MR**：固定 `timeout=2 / kill-after=1`，扰动 stub 行为 属于 {正常退出、`trap "" TERM` 后 sleep 30、fork 子进程后自身退出} → 断言墙钟恒不超过 8s；再扰动四个超时来源的组合 → 断言生效值符合优先级表。
- **判别样例**：`trap "" TERM; sleep 30` 在改前必然跑满 30s（已实测同形态 12s 版本），改后不超过 8s → 现状必挂、修好必过。
- **Verify**：`bash scripts/smoke-all.sh`（`smoke-dispatch.sh`）

### O5 · 每日分析不再静默失败；迁移不丢数据
- **SSOT**：`NEIL_AUTOPILOT_LOG_DIR` 与 plist 中 `ProgramArguments` 指向的脚本路径。
- **不变量**：检测到 TCC 前缀时，要么 stage 后成功生成 plist（其 `ProgramArguments` 与 `EnvironmentVariables` 路径均不在 TCC 前缀下），要么 exit 非 0 并打印可执行修复指令——**不得生成注定 126 的 plist**；`migrate-log-root.sh` 只复制不删除，迁移后目标 `runs/*.jsonl` 总行数不少于源总行数。
- **MR**：扰动 LOG_DIR 属于 {`$HOME/Desktop/...`, `$HOME/Library/Logs/...`} 与 `--stage-scripts`/`--no-stage` 四种组合 → 断言路径不落 TCC 前缀或明确失败；扰动源目录内容（0 个 / 1 个 / 多个 jsonl 加子目录）→ 断言行数守恒且源目录仍在。
- **判别样例**：现状（Desktop + no-stage → 静默生成坏 plist）与修复后（拒绝或 stage）期望不同。
- **安全约束**：smoke 必须用**假 HOME**（`HOME=$tmp`）且**禁止**调用真实 `launchctl bootstrap/load`；只断言生成的 plist 文本。
- **Verify**：`bash scripts/smoke-all.sh`（`smoke-install-daily-schedule.sh` + `smoke-migrate-log-root.sh`）

### O6 · SKILL.md 瘦身后强制约束一条不丢
- **SSOT**：HARD-GATE 7 条不变量 + "控制器永不内联写码"铁律 + 档位判定规则 + `{STAGE}_STATUS` 状态行约定 + REVIEW 三态。
- **不变量**：瘦身后的 `SKILL.md` 正文仍**逐条包含**上述强制项的判别关键词；每个 `references/` 指针指向的文件真实存在；`SKILL.md` 不超过 9216 字节。
- **MR**：扰动"删掉任一条 HARD-GATE 关键词"→ 断言 `smoke-skill-invariants.sh` 失败；扰动"重命名一个 references 文件"→ 断言失败；扰动"正文加无关内容至超 9KB"→ 断言失败。三个扰动都必须让门禁翻红（证明门禁本身有判别力，不是空跑）。
- **Verify**：`bash scripts/smoke-all.sh`（`smoke-skill-invariants.sh`）

## 5. 约束与风险

1. **自修改危险（本次最大工程风险）**：worker 会改正在运行的 `run-track-a.sh` / `dispatch.sh`，而 bash 是**增量读取**脚本的 → 运行中被改可能导致语法错乱。**对策：控制器把 `scripts/` 快照到 `$TMPDIR` 并从快照启动 loop**（`skills` 以 symlink 挂回真仓库，保证 review prompt 里 `../skills/...` 路径有效）；`--cwd` 仍指真仓库，提交照常落在真仓库。worker 改的是仓库副本，下一次运行才生效——这正是要的确定性。
2. **bash 3.2 / BSD 工具**：禁关联数组、`mapfile`、`grep -P`、GNU-only `sed -i` 无后缀写法；`stat` 需双分支（`-f %m` / `-c %Y`）。
3. **不得破坏 11 个既有 smoke**（基线全绿），也不得为过关而弱化断言。
4. **smoke 一律零 token、零外网、零真实系统副作用**：禁调真实 `qodercli`（用 stub）、禁 `launchctl`、禁写真实 `~/Library/LaunchAgents`、禁碰真实 `NEIL_AUTOPILOT_LOG_DIR`。
5. **向后兼容**：telemetry 字段只增不改名；`dispatch.sh` 既有 flag 语义不变；`AUTOPILOT_TIMEOUT` 仍生效。
6. **不删用户数据**：`migrate-log-root.sh` 只复制；`telemetry_rotate` 不进主链路。

ANALYZE_STATUS=DONE

## 7. 追加根因 P7（2026-08-13 23:40 实测，替换先前"后端不健康"的错误判断）

`reviewer=Ultimate` + **需长时间多轮工具调用的重 prompt** ⟹ 走完约 130~175s 后 **rc=0 但 stdout 恰好 1 字节（空）**，`parse_review` 抓不到裁决 → `UNKNOWN` → fail-closed 扣轮次。四组对照（同一 prompt / 同一 cwd，只换单一变量）：

| 变量 | model | cwd | prompt | rc | 耗时 | stdout |
|---|---|---|---|---|---|---|
| 重放 | Ultimate | 插件仓库 | 真实 review prompt | 0 | 134s | **1B（空）** |
| E1 | Ultimate | /tmp | trivial | 0 | 6s | 12B `REVIEW_PASS` |
| E2 | Ultimate | 插件仓库 | trivial | 0 | 7s | 12B `REVIEW_PASS` |
| E3 | Performance | 插件仓库 | 真实 review prompt | 0 | 143s | 2035B 完整审查 + `REVIEW_PASS` |

排除：服务可用性（E1/E2 秒回）、仓库 hooks / AGENTS.md（E2 同 cwd 正常）、prompt 本身（E3 同 prompt 正常）。归因：**Ultimate 档位在 headless 长会话下最终文本不落 stdout**（qodercli 侧行为差异，非本 plugin 缺陷）。

**决策 D16**：`AUTOPILOT_REVIEWER_MODEL` 默认值由 `Ultimate` 改为 `Performance`（E3 证明其 CR 质量足够——它主动提了 `set -uo pipefail` 与边界覆盖两条 minor）。`Ultimate` 保留为可选值并在 AGENTS.md 标注该已知缺陷。

**决策 D17**：`EMPTY` 类（rc=0 且输出 < 阈值）必须与 `TRANSPORT` 同等对待——**重试且不扣 CR 轮次**。`classify-outcome.sh` 已含该分支（Task 1 第 4 条），Task 3 接线时不得漏。

## 8. 追加问题 P8：自迭代（plugin 改自己）缺递归护栏

实测事实：① `~/.qoder/skills/` 下 `_shared`、`autopilot-*`、`neil-coding-autopilot`、`using-neil-autopilot` **全部是软链到本仓** → 改仓库即实时改掉当前会话与所有 worker 加载的 skill；② `AUTOPILOT_ROLE=worker` 目前**仅**用于 hooks 写权限白名单，全仓无任何递归防护；③ worker prompt 未禁止调用 autopilot skill / 执行编排脚本；④ `run-track-a.sh` 无并发锁（同一 change-dir 可并行多实例）；⑤ **env 穿透已实测**：worker 跑 `smoke-all.sh` → 内部 `dispatch.sh(TestModel)` 继承 `AUTOPILOT_RUN_ID`，42 条 fixture 事件被记进真实 run `autopilot-cost-latency-20260813-225354`，污染成本统计。

今日 worker 日志全量 grep `Skill(` / `run-track-a.sh --change-dir` = **空**，即嵌套尚未真实发生；但通道齐备（bypass_permissions + cwd 在插件仓 + 任务文本满是 autopilot 关键词），一旦 worker 决定调 skill 即无限递归、指数烧 token。→ 见 Task 10。

## 9. 追加根因 P9：分类器把「实质输出」误判为 TRANSPORT（自指式误伤，已实测）

实测：`classify-outcome.sh 1 /tmp/probe-3.log` → `TRANSPORT`，而该日志是 2035 字节的**真实 CR 正文、末尾 `REVIEW_PASS`**。命中原因是正文里逐字出现 `Unable to connect` —— 因为这次 CR 审的就是那张传输层正则表本身。`smoke-classify-outcome.sh` 的 APP fixture 恰好不含任何传输关键词，所以断言全绿却漏掉真实场景。

**危害（必须在 Task 4 之前修）**：Task 4 让 TRANSPORT 类"重试且不扣轮次"。一旦真正的 `REVIEW_FAIL` 正文里出现任一传输关键词（在本仓库里几乎必然，因为代码和文档到处写这些词），就会被当成抖动**无限重试**，既拿不到修复也持续烧 token —— 与本次治理目标完全相反。

**决策 D18（覆盖 Task 1 原判定顺序）**：先判"有没有实质结论"，再判传输特征。新顺序：
1. `exit_code ∈ {124,137}` → `TIMEOUT`
2. **（新）日志含裁决/自述标记** —— `REVIEW_PASS` / `REVIEW_FAIL` / `**Status:** DONE` / `**Status:** BLOCKED` —— 说明 worker 真的产出了结论 ⟹ `exit_code==0` 则 `OK`，否则 `APP`。**永不**归为 TRANSPORT/EMPTY。
3. 传输层正则：仅当**日志字节数 < `AUTOPILOT_TRANSPORT_LOG_BYTES`（默认 4096）**且只对**末 20 行**匹配时才判 `TRANSPORT`（抖动的特征是"短且以错误收尾"，而非"正文提到过这些词"）
4. `exit_code != 0` 且字节数 < `AUTOPILOT_EMPTY_LOG_BYTES`(300) → `TRANSPORT`
5. `exit_code == 0` 且字节数 < 同阈值 → `EMPTY`
6. `exit_code != 0` → `APP`
7. 否则 → `OK`

**判别样例（必须进 smoke，缺一不可）**：① `exit 1` + >300B CR 正文且**逐字包含 `Unable to connect`** + `REVIEW_FAIL` → 必须 `APP`；② 短日志仅 `Unable to connect.` → 仍 `TRANSPORT`；③ 6KB 正文其**末 20 行**含 `502 Bad Gateway`、但无裁决标记 → `APP`（超长度门，不算抖动）；④ 250B 且含 `**Status:** DONE`、`exit 0` → `OK`（不得因为短就判 EMPTY）。

## 10. 目标验收（用户目标的可证伪化）

用户目标三条：**省 token、更快、功能与以前一致**。全部要求**离线可测**，不靠"感觉"：
- 省 token：以结构性削减量为证据（review 上下文字节、SKILL.md 注入字节、避免的重跑次数），并用今日真实遥测做重放推算。
- 更快：以"被消灭的等待"为证据（超时哑弹导致的挂死时长、瞬时故障吃掉的轮次时长）。
- 功能一致：既有 11 个 smoke 全绿 + CLI/env/遥测 schema 向后兼容断言。
→ 落地为 Task 11。

## 11. 追加根因 P10：状态/裁决解析未锚定，被日志正文里"提到"的标记名欺骗（已实测，最严重）

实测（2026-08-14 00:25，run `autopilot-cost-latency-20260814-002419`）：implement worker 在 67s 处被**截断**（327B，代码一行没写），其正文最后一句是
`- Add verdict marker check (REVIEW_PASS/REVIEW_FAIL/**Status:** DONE/**Status:** BLOCKED) before transport`
结果：`parse-status.sh` 用 `grep -ioE 'status[^A-Za-z]*(DONE|BLOCKED|...)' | tail -1` **全文匹配**，取到句中的 `Status:** BLOCKED` → 报告"worker 明确 BLOCKED"；而实际上 worker 什么结论都没给。同一句话也让 `classify-outcome.sh`（D18 新增的标记优先规则）判成 `OK`。**两个解析器被同一行文字同时骗过。**

同类隐患：`run-track-a.sh:239` 的 `parse_review() { grep -ioE 'REVIEW_(PASS|FAIL)' "$1" | tail -1; }` 也是全文匹配 —— 而 review prompt 自身就写着 `REVIEW_PASS # 无 CRITICAL/MAJOR` 与 `REVIEW_FAIL # 有 CRITICAL/MAJOR`，reviewer 一旦复述指令或两者都列，`tail -1` 就可能取到错的那个，**把通过判成不通过、或反之**。

**危害**：这是"假 BLOCKED"的制造机 —— 截断（本应重试、几乎零成本）被误判成"真失败"（停机等人工 / 或触发 fixer 白跑一轮）。在无人值守下直接决定流程走向，比 P7/P9 更致命。

**决策 D19（三处解析统一锚定，缺一不可）**：
1. **只在末尾窗口内找**：仅检查日志**最后 15 行**（`tail -15`）。worker 的结论按约定必须在回复末尾，正文中段的提及一律不算。
2. **必须行首锚定 + 整行成立**：
   - Status：`^[[:space:]]*\**[Ss]tatus\**[:：]\**[[:space:]]*\**(DONE_WITH_CONCERNS|DONE|BLOCKED|NEEDS_CONTEXT)` —— 用 `\**`（零或多个星号）而**不是** `(\*\*)?`，因为真实格式是 `**Status:** DONE`（**冒号在两个星号之间**）；写成 `Status(\*\*)?[:：]` 会一条都匹配不到（已实测踩中）。该行必须以 Status 开头，行内提及一律不算。
   - 裁决：`^[[:space:]]*\**REVIEW_(PASS|FAIL)\**[[:space:]]*$` —— 必须独占一行（允许星号/空格），行内夹带说明文字（如 prompt 模板里的 `REVIEW_PASS   # 无 CRITICAL/MAJOR`）判不成立。
3. 末尾窗口内无锚定标记 → `UNKNOWN`（交给按字节数的 EMPTY/TRANSPORT 分类去处理 = 重试），**不得**回退成全文 grep。
4. `classify-outcome.sh` 的 D18 规则 2 同步改为"锚定标记"判定（用同一套正则，建议抽成 `scripts/parse-markers.sh` 单一实现，三处共用，避免正则三份漂移）。
5. **判别样例（必须进 smoke）**：① 上述真实截断日志原文（行内提及 4 个标记名，末尾无锚定标记）→ `parse-status.sh` 必须输出 `UNKNOWN`、`classify-outcome.sh` 必须输出 `EMPTY`（**不是** BLOCKED / OK）；② 正常结尾 `**Status:** DONE` 独占一行 → `DONE`；③ 日志正文中段有 `**Status:** DONE` 但末 15 行没有 → `UNKNOWN`；④ 末行为 `REVIEW_PASS` → `REVIEW_PASS`；⑤ 末行为 `REVIEW_PASS   # 无 CRITICAL/MAJOR`（prompt 模板原文）→ **不成立** → `UNKNOWN`；⑥ 末尾同时有 `REVIEW_FAIL` 行与更靠后的 `REVIEW_PASS` 行 → 取最后一个 = `REVIEW_PASS`。

**同时记录一个环境事实（非本 plugin 缺陷，但决定重试策略）**：`qodercli --help` 中**不存在**任何 idle / stream / 超时相关开关，无法调高那个 60s 空闲断流阈值；worker 被截断只能靠"分类 + 重试"消化，这进一步抬高了 D18/D19 与 Task 4 的优先级。

### D19 正则实测结果（7 条 fixture，实现时以此为准）

统一正则（BSD grep -oE 可用，无 GNU 扩展）：
```
^[[:space:]]*\**[Ss]tatus\**[:：]\**[[:space:]]*\**(DONE_WITH_CONCERNS|DONE|BLOCKED|NEEDS_CONTEXT)|^[[:space:]]*\**REVIEW_(PASS|FAIL)\**[[:space:]]*$
```

| fixture | 期望 | 实测 |
|---|---|---|
| 真实成功日志末尾 `**Status:** DONE` | 匹配 | ✅ `**Status:** DONE` |
| 真实截断日志（行内提及 4 个标记名） | 不匹配 | ✅ 空 |
| 真实 CR 末行 `REVIEW_PASS` | 匹配 | ✅ `REVIEW_PASS` |
| prompt 模板行 `REVIEW_PASS   # 无 CRITICAL/MAJOR` | 不匹配 | ✅ 空 |
| 行内 `(**Status:** DONE/**Status:** BLOCKED)` | 不匹配 | ✅ 空 |
| 中文冒号 `Status：DONE` | 匹配 | ✅ `Status：DONE` |
| 1 字节空日志 | 不匹配 | ✅ 空 |
