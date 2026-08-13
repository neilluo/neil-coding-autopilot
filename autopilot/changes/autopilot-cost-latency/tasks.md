# Tasks — autopilot 成本与时延治理

> Spec: `autopilot/changes/autopilot-cost-latency/spec.md`（**每个 Task 开工前必读**，尤其 §2 决策表与 §4 可观测验收）
> 全局 verify: `bash scripts/smoke-all.sh`
> 项目根: `/Users/neil/Desktop/neilcodebase/neil-coding-autopilot`
> 分支: `fix/autopilot-cost-latency`

## 全局铁律（所有 Task 都适用，开工前连同 spec 一起读）

0. **不得修改本文件的 `**Verify**` 行，不得为过关放水**：禁止删除/弱化既有 smoke 断言、禁止给 smoke 加 `exit 0` 兜底、禁止把断言改成 `|| true`。验证命令本身有问题 ⟹ 回复里说明并输出 `**Status:** BLOCKED`，不要自己改计划。
1. **基线**：改动前 11 个 smoke 全绿（`smoke-dispatch/run-track-a/run-autopilot/telemetry/guard/bash-guard/daily-analysis/archive-change/kb-path/kb-search/migrate-archive-layout`）。**一个都不许弄挂**。
2. **bash 3.2 + BSD 工具**（macOS stock，见 AGENTS.md）：禁关联数组、`mapfile`、`grep -P`、`readlink -f`、GNU-only `sed -i` 无后缀；`sed -i.bak` + `rm -f *.bak`；`stat` 用双分支（`stat -f '%m'` / `stat -c '%Y'`）。所有脚本 `set -euo pipefail` + `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"` 自定位。
3. **新脚本必须**：可执行位（`chmod +x`）、顶部注释块说明 WHAT/USAGE/EXIT CODES、支持 `-h|--help`、纯函数式（不写全局副作用）。
4. **smoke 一律零成本零副作用**：禁调真实 `qodercli`（用 PATH 前置 stub）、禁 `launchctl`、禁写真实 `~/Library/LaunchAgents`、禁碰真实 `$NEIL_AUTOPILOT_LOG_DIR`（一律 `NEIL_AUTOPILOT_LOG_DIR="$tmp"`）、禁外网。临时产物只放 `$(mktemp -d)` 并 `trap 'rm -rf ...' EXIT`。
5. **向后兼容**：telemetry 字段只增不改名不改序；`dispatch.sh` 既有 flag 与退出码语义不变；`AUTOPILOT_TIMEOUT` 仍生效。
6. **不删用户数据**：任何脚本不得 `rm -rf` 用户日志目录；迁移只复制。
7. **不引入 Task 描述外的功能**；异常不静默吞（catch 后必须打日志或返回非零）。
8. **自修改注意**：本仓库的 `scripts/run-track-a.sh` 正被一个**冻结快照**执行（控制器从 `$TMPDIR` 跑），你改的是仓库副本，改动下次运行才生效——这是预期行为，不要试图"让它立刻生效"，也不要在 Verify 里去跑真实 loop。

## Task 1: 故障分类纯函数 + 统一回归门

**Status**: BLOCKED

落地 spec D1/D15。

1. 新建 `scripts/classify-outcome.sh`：
   - 用法 `classify-outcome.sh <exit_code> <log_file>`，stdout 输出**恰好一个词**：`OK` / `TRANSPORT` / `TIMEOUT` / `EMPTY` / `APP`；退出码恒 0（分类器不因分类结果失败）。
   - 判定顺序（**必须按此序**，先命中先返回）：
     1. `exit_code` ∈ {124, 137} → `TIMEOUT`
     2. 日志（不存在按空处理）匹配传输层错误正则（大小写不敏感）→ `TRANSPORT`：`unable to connect`、`response body idle timeout`、`typo in the url or port`、`econnreset`、`econnrefused`、`etimedout`、`socket hang up`、`fetch failed`、`network error`、`tls handshake`、`too many requests`、`rate limit`、`502 bad gateway`、`503 service unavailable`、`504 gateway timeout`
     3. `exit_code != 0` 且日志字节数 < `${AUTOPILOT_EMPTY_LOG_BYTES:-300}` → `TRANSPORT`（无实质输出的失败，按抖动处理）
     4. `exit_code == 0` 且日志字节数 < 同阈值 → `EMPTY`
     5. `exit_code != 0` → `APP`
     6. 否则 → `OK`
   - 正则清单集中成一个变量便于扩展；用 `grep -qiE`（**不用** `-P`）。
2. 新建 `scripts/smoke-classify-outcome.sh`：对上面 6 条分支逐一造 fixture 断言，**必含判别样例**：`exit 1` + 一段 >300B 的真实 CR 文本（含 `REVIEW_FAIL` 与 `scripts/foo.sh:42`）→ 必须是 `APP`（不是 `TRANSPORT`）；`exit 1` + 短文本 `Unable to connect.` → `TRANSPORT`。再加边界：日志文件不存在、日志恰好 300B、exit 137。
3. 新建 `scripts/smoke-all.sh`：
   - 顺序跑 `scripts/smoke-*.sh`（按文件名排序，**排除自身**），每个用 `bash` 执行；打印 `PASS/FAIL` 与耗时；**fail-fast**（首个失败即 exit 1 并回显该 smoke 的最后 30 行输出）；全绿 exit 0。
   - 支持 `--only <pattern>`（子串过滤）与 `--list`。
   - 不得并行（避免共享 TMPDIR 竞态）。

**Verify**: `bash scripts/smoke-all.sh`

## Task 1 增补（D18，随 Task 1 一起完成，Task 1 未含此项即视为未完成）

9. **按 spec §9 的 D18 重排判定顺序**并补齐四个判别样例（①②③④ 全部进 `smoke-classify-outcome.sh`）。要点：新增"裁决/自述标记优先"规则（`REVIEW_PASS`/`REVIEW_FAIL`/`**Status:** DONE`/`**Status:** BLOCKED`）；传输层正则加**长度门** `AUTOPILOT_TRANSPORT_LOG_BYTES`（默认 4096）且**只匹配末 20 行**（用 `tail -20`）。已实测反例：`classify-outcome.sh 1 /tmp/probe-3.log` 当前错判 TRANSPORT，正确答案是 `APP`——修完必须亲自跑这条验证（该文件若已不存在，就用同样特征自造 fixture）。

## Task 2: telemetry 扩展（token 字段 + 默认值调整）

**Status**: PENDING

落地 spec D7/D11/D13。改 `scripts/telemetry.sh`：

1. `telemetry_emit_dispatch` 支持**可选新字段**，全部走 `AUTOPILOT_TM_*` 环境变量传入（避免破坏现有两参签名，保持向后兼容）：
   `AUTOPILOT_TM_INPUT_TOKENS` `AUTOPILOT_TM_OUTPUT_TOKENS` `AUTOPILOT_TM_CACHE_READ_TOKENS` `AUTOPILOT_TM_COST_USD` `AUTOPILOT_TM_CONTEXT_RATIO` `AUTOPILOT_TM_NUM_TURNS` `AUTOPILOT_TM_API_MS` `AUTOPILOT_TM_ATTEMPT` `AUTOPILOT_TM_FAILURE_CLASS` `AUTOPILOT_TM_PROMPT_BYTES` `AUTOPILOT_TM_OUTPUT_BYTES` `AUTOPILOT_TM_IS_ERROR`
   → 对应 JSON 字段名（**冻结**）：`input_tokens` `output_tokens` `cache_read_tokens` `cost_usd` `context_ratio` `num_turns` `api_ms` `attempt` `failure_class` `prompt_bytes` `output_bytes` `is_error`。
   - **关键语义（spec D6）**：变量未设置或为空 → 该字段**整体不出现在 JSON 里**（绝不写 0 或 null 冒充）。数值字段用现有 `_telemetry_int` 规范化；`cost_usd`/`context_ratio` 是小数，需新增 `_telemetry_num`（允许 `0`、`0.0123`、科学计数否则丢弃该字段）；字符串字段走 `telemetry_json_escape`；`is_error` 输出布尔字面量 `true|false`。
   - 字段顺序：先输出现有 6 个字段（ts/run_id/event/stage/model/duration_s/exit_code 保持原序），新字段追加在后。JSON 必须仍是单行合法 JSON（用 `jq -e . </dev/null` 之外的方式验证不了就在 smoke 里用 `jq -e .` 逐行校验）。
2. 默认值调整：`NEIL_AUTOPILOT_KEEP_DAYS` 默认 `3` → `30`；`telemetry_log_root()` 的默认 LOG_DIR 从 `${HOME}/neil-autopilot-logs-analysis` → `${HOME}/Library/Logs/neil-autopilot`（`NEIL_AUTOPILOT_LOG_DIR` 显式设置时仍优先，CWD 安全降级逻辑保持不变）。
3. **不要**把 `telemetry_rotate` 加到 run-track-a.sh 或任何主链路（spec D13）。
4. 扩 `scripts/smoke-telemetry.sh`：
   - 断言「设了 `AUTOPILOT_TM_*` → jsonl 对应字段值精确相等」（含小数 `cost_usd=0.0123`、`context_ratio=0.028036`）；
   - **判别断言**：未设 `AUTOPILOT_TM_INPUT_TOKENS` 时，该行 `jq -e 'has("input_tokens")' == false`（证明是缺省而非 0）；
   - 断言每行都是合法 JSON（`jq -e .` 逐行）；
   - 断言默认 KEEP_DAYS=30、默认 LOG_DIR 指向 `Library/Logs/neil-autopilot`（用假 HOME 隔离，不许创建真实目录）。

**Verify**: `bash scripts/smoke-all.sh`

## Task 3: dispatch.sh —— 真实 usage 抓取 + 超时哑弹修复

**Status**: PENDING

落地 spec D5/D6/D10。改 `scripts/dispatch.sh`（**保持既有 flag 与退出码语义**）。

1. **分级超时 + kill-after**：
   - 生效值优先级（spec D10）：`--timeout` > `AUTOPILOT_TIMEOUT_<STAGE 大写>`（stage 取 `$AUTOPILOT_STAGE`，如 `AUTOPILOT_TIMEOUT_REVIEW`）> `AUTOPILOT_TIMEOUT` > 内置 stage 默认（`review=900` `implement=1800` `fix=900` 其他=`600`）。
   - `timeout` 调用加 `-k "${AUTOPILOT_KILL_AFTER_S:-30}"`（放在秒数前：`"$TIMEOUT_BIN" -k "$KILL_AFTER" "$TIMEOUT" cmd...`）。保留无 `timeout` 二进制时的降级与 WARN。
   - 生效值与 kill-after 必须打到 stderr 一行（便于排障与 smoke 断言），格式：`dispatch: stage=<s> timeout=<n>s kill-after=<k>s model=<m>`。
2. **usage 抓取（仅 qoder 平台）**：当 `command -v jq` 存在且 `${AUTOPILOT_USAGE_JSON:-1}` != 0：
   - qodercli 追加 `-o json`；把 worker 原始 stdout 收集到临时文件（**不要**直接进终端）。
   - 结束后：若原始输出是合法 JSON（`jq -e 'type=="object"'`）→
     a. 把 `.result // ""` **原样打印到 stdout**（这是调用方 tee/parse-status/parse_review 的唯一输入，绝不能丢；`.result` 为空时退回打印原始 JSON）；
     b. 抽取 `.usage.input_tokens` `.usage.output_tokens` `.usage.cache_read_input_tokens` `.total_cost_usd` `.usage.context_usage_ratio` `.num_turns` `.duration_api_ms` `.is_error` → 导出为 Task 2 定义的 `AUTOPILOT_TM_*` 后再调 `telemetry_emit_dispatch`（**null/缺失 → 不导出该变量**）；
     c. 若 `AUTOPILOT_RAW_JSON` 指向路径，则把原始 JSON 另存该路径（调用方用来留证）。
   - 若不是合法 JSON（或 jq 缺失/关闭/非 qoder 平台）→ 原始输出**逐字打印到 stdout**（退化路径，绝不吞输出），token 字段整体缺省。
   - **`.is_error == true` 时 dispatch 退出码取 1**（让上游分类器能看见失败）；否则沿用真实退出码。
   - 另外始终导出 `AUTOPILOT_TM_PROMPT_BYTES`（prompt 文件字节数）、`AUTOPILOT_TM_OUTPUT_BYTES`（worker 输出字节数）、`AUTOPILOT_TM_ATTEMPT`（透传 `${AUTOPILOT_ATTEMPT:-1}`）、`AUTOPILOT_TM_FAILURE_CLASS`（超时时 `TIMEOUT`，其余留空由上游补）。
3. 扩 `scripts/smoke-dispatch.sh`（stub 化，零 token）：
   - **O4 判别 scenario（必做）**：stub 为 `trap "" TERM; sleep 30`，用 `AUTOPILOT_TIMEOUT=2 AUTOPILOT_KILL_AFTER_S=1` 跑，断言 ① 墙钟 ≤ 8s ② exit=124。再加 stub 正常秒退 → 断言 exit=0 且墙钟 < 5s。
   - **优先级 scenario**：四种来源组合（`--timeout` / `AUTOPILOT_TIMEOUT_REVIEW` / `AUTOPILOT_TIMEOUT` / 无）→ 断言 stderr 里 `timeout=<期望值>`。
   - **usage scenario**：stub 输出固定 JSON 信封（含 `result` 里带 `**Status:** DONE` 与 usage 数值）→ 断言 ① stdout 含 `**Status:** DONE`（`.result` 已还原）② jsonl 中 token 字段等于信封值 ③ `AUTOPILOT_RAW_JSON` 指定时原始 JSON 落盘。
   - **jq 缺失退化 scenario**：PATH 中屏蔽 jq（stub 目录放一个不可执行的 jq 或用 `env PATH=` 精简）→ 断言 stdout 仍含 `**Status:** DONE`、jsonl 仍有 dispatch 事件且**无** token 字段。
   - 保留原有三平台 flag 断言。

**Verify**: `bash scripts/smoke-all.sh`

## Task 4: run-track-a.sh —— 瞬时故障重试且不扣轮次

**Status**: PENDING

落地 spec D2/D3/D4（本次核心）。改 `scripts/run-track-a.sh`。

1. `dispatch_worker` 不再丢弃 rc：保留 `tee` 行为，执行后设置全局 `WORKER_RC`、并调 `scripts/classify-outcome.sh "$WORKER_RC" "$outlog"` 得到全局 `WORKER_OUTCOME`；把 outcome 经 `AUTOPILOT_TM_FAILURE_CLASS` 补进遥测（OK 时留空）。仍 `return 0`（不让 `set -e` 中断编排）。
2. 新增 `dispatch_with_retry <stage> <model> <prompt-file> <instruction> <base-log>`：
   - 尝试序号 `attempt` 从 1 起，日志路径 `${base-log%.log}-a${attempt}.log`（spec D4，绝不覆盖）；把 `AUTOPILOT_ATTEMPT=$attempt` 传给 dispatch。
   - `WORKER_OUTCOME` ∈ {`TRANSPORT`,`EMPTY`} 且 `attempt <= ${AUTOPILOT_TRANSPORT_RETRIES:-3}` → 退避 `sleep $(( ${AUTOPILOT_RETRY_BACKOFF_S:-5} * 2**(attempt-1) ))`（bash 3.2 无 `**`，用循环或乘法累积）后重试；日志打 `transport failure (attempt N/M) → retry in Xs`。
   - 其他 outcome（`OK`/`APP`/`TIMEOUT`）→ 立即返回。
   - 结束时把最终日志路径写入全局 `LAST_WORKER_LOG`（下游 `parse-status`/`parse_review`/fix prompt/copy_artifact 全部改用它）。
   - `AUTOPILOT_TRANSPORT_RETRIES=0` 时行为等价于旧逻辑（可关）。
3. 三个调用点（implement / review / fix）全部改用 `dispatch_with_retry`。
4. **轮次语义（不变量）**：
   - 重试**不推进** `round`（`round` 只在 verify→review 主循环里 +1）。
   - `TRANSPORT`/`EMPTY` 重试耗尽 → 标 Task `BLOCKED`、`telemetry_emit_task` 记 BLOCKED、日志 `→ stop (fail-closed, transport)`、`exit 2`；**不得**触发 fixer、**不得**推进 round。
   - `TIMEOUT` → 立即 `BLOCKED`（原因 `timeout`）、`exit 2`、不重试、不走 fixer。
   - review 只有在 outcome ∈ {`OK`,`APP`} 时才 `parse_review`；`APP` 且解析不到 verdict → 维持现有 fail-closed 行为（走 fixer 并占一轮）。
   - implement 的 `APP`（跑完但没 DONE）→ 维持现有 BLOCKED 行为。
   - BLOCKED 退出前多打一行给人看的提示：`hint: transient failure — rerun with --resume to continue from this task`。
5. 扩 `scripts/smoke-run-track-a.sh` 新增三个 scenario（stub 用 `STUB_MODE` 切换；smoke 里设 `AUTOPILOT_RETRY_BACKOFF_S=0` 保持快速，并额外断言退避变量被尊重）：
   - **TRANSPORT-RETRY**：stub 恒 `exit 1` + 短文本 `Unable to connect.` → 断言 ① 出现 `transport failure (attempt 1/3)`…`(attempt 3/3)` ② driver 日志中 **`round 1` 只出现一次、从未出现 `round 2`** ③ 最终 exit=2 且 tasks.md 该 Task 为 `BLOCKED` ④ **没有** fixer 被调起（日志无 `fix` 派发行）⑤ 生成了 `-a1/-a2/-a3` 三个日志文件。
   - **TIMEOUT-NO-RETRY**：stub `trap "" TERM; sleep 30` + `AUTOPILOT_TIMEOUT=2 AUTOPILOT_KILL_AFTER_S=1` → 断言 ① 无 `retry in` ② exit=2 ③ 总墙钟 ≤ 20s。
   - **APP-FAIL-CLOSED（判别样例）**：review stub `exit 1` + 一段 >300B 的真实 CR 文本（含 `REVIEW_FAIL` 与 `scripts/x.sh:12`）→ 断言 ① **不重试**（无 `retry in`）② fixer 被调起 ③ round 推进到 2。
   - 原有三个 scenario（HAPPY / FAIL-CLOSED / COMMIT-FAILURE）必须继续全绿。

**Verify**: `bash scripts/smoke-all.sh`

## Task 5: review 上下文改为有界 diff

**Status**: PENDING

落地 spec D8/D9。

1. 新建 `scripts/review-context.sh`：
   - 用法 `review-context.sh --cwd <repo> [--budget <bytes>] [--out <file>]`；默认 budget `${AUTOPILOT_REVIEW_DIFF_BUDGET:-120000}`。
   - 产出结构（顺序固定，便于断言）：
     ```
     ## 变更概览（git diff --stat，全量，不裁剪）
     <git diff --stat HEAD -- <过滤后路径>  + untracked 文件清单>
     ## 变更内容（unified diff，预算内）
     <git diff HEAD -- ...>
     <untracked 文件的完整内容，按 ``` 包裹>
     ## TRUNCATED（仅在超预算时出现）
     <未展开的文件清单 + 提示 reviewer 自行打开>
     ```
   - 噪音过滤（spec D9）：`autopilot/changes/*/tasks.md`、`*.lock`、`package-lock.json`、`*.min.*`、`dist/`、`build/`、`target/`、`node_modules/` 一律不进正文（stat 里也不算入，避免误导）。
   - 二进制文件只列名不展开；`git` 不可用或非仓库 → 优雅退化为文件清单 + 明确说明（不得报错退出）。
   - **不变量**：总输出 ≤ budget；裁剪时必须出现 `TRUNCATED` 段且 stat 段完整。
2. `scripts/run-track-a.sh` 的 `build_review_prompt`：把「变更文件列表（请逐一读取完整内容再评审）」替换为 `review-context.sh` 的产出；措辞改为「以下是本 Task 的完整变更（有界 diff）。**先基于 diff 评审**；若某处需要上下文，再自行打开对应文件」。原来的 `task-N-files-R.txt` 仍生成（留证 + 供 smoke 断言），但不再作为 prompt 主体。
3. 新建 `scripts/smoke-review-context.sh`：造一个临时 git 仓库（含正常源文件、一个 `node_modules/x.js`、一个 `autopilot/changes/foo/tasks.md`、一个 untracked 文件、一个二进制文件），断言：
   - budget 大 → 无 `TRUNCATED`、正常文件的 diff 正文存在；
   - budget 极小（如 200）→ 出现 `TRUNCATED`，**且 stat 段的文件条目数与大 budget 时完全相同**（O3 的关键不变量）；
   - 三档 budget 下输出字节数均 ≤ budget；
   - `node_modules/x.js` 与 `autopilot/changes/foo/tasks.md` 在任何档位都不出现在正文；
   - 非 git 目录下不报错且给出清单。

**Verify**: `bash scripts/smoke-all.sh`

## Task 6: daily-analysis 增加 token/成本聚合

**Status**: PENDING

落地 spec P2 的消费端。改 `scripts/daily-analysis.sh`：

1. metrics JSON 增加（字段名冻结）：`tokens_input_total` `tokens_output_total` `tokens_cache_read_total` `cost_usd_total`，以及 `by_stage`（对 implement/review/fix 各给 `count/duration_s/input_tokens/output_tokens/cost_usd`）与 `by_model`（同结构，按 model 分组）。
   - 用 jq 对 `event=="dispatch"` 的行聚合；**缺字段的行按 0 计入求和但不得让 jq 报错**（用 `(.input_tokens // 0)`）；同时输出 `dispatch_with_usage_count`（有 token 字段的行数）与 `dispatch_total_count`，便于判断观测覆盖率。
2. 保持既有字段与行为不变（含"无新 runs 就跳过 LLM 分析"的省钱逻辑、`telemetry_rotate` 调用点、dry-run）。
3. 扩 `scripts/smoke-daily-analysis.sh`：fixture 里混入**带 token 字段**与**不带 token 字段**的 dispatch 行 → 断言 ① 求和数值正确（手算期望值写死在断言里）② `dispatch_with_usage_count` 与 `dispatch_total_count` 正确 ③ 既有五个 scenario 全绿。

**Verify**: `bash scripts/smoke-all.sh`

## Task 7: 每日任务 TCC 修复 + 日志目录迁移工具

**Status**: PENDING

落地 spec D11/D12（用户已选"搬到非 TCC 目录"）。

1. 新建 `scripts/migrate-log-root.sh`：
   - 用法 `migrate-log-root.sh --from <dir> --to <dir> [--dry-run]`；默认 `--to "${HOME}/Library/Logs/neil-autopilot"`。
   - 行为：**只复制不删除**（`cp -R`，保留 `runs/ metrics/ reports/` 结构）；复制后校验「目标 `runs/*.jsonl` 总行数 ≥ 源总行数」，不满足则 exit 非 0 并保留现场；打印后续手工动作（如何改 `.zshrc` 的 `NEIL_AUTOPILOT_LOG_DIR`、旧目录可自行删除）。
   - 幂等：重复跑不得重复追加或损坏已有文件（同名文件按"目标更新则跳过"处理并报告）。
   - **绝不** `rm -rf` 源目录。
2. 改 `scripts/install-daily-schedule.sh`：
   - 新增 TCC preflight：把 `$HOME/Desktop`、`$HOME/Documents`、`$HOME/Downloads` 视为受保护前缀，检查**两个**路径 —— 待写入 plist 的脚本路径、以及 LOG_DIR。
   - 新增 `--stage-scripts`（macOS 默认开启）：把整个 `scripts/` 目录复制到 `${HOME}/Library/Application Support/neil-autopilot/scripts/`（含 `telemetry.sh`/`dispatch.sh` 等同级依赖，保持相对结构），plist 的 `ProgramArguments` 指向副本；同时打印"plugin 更新后需重跑本脚本以刷新 staged 副本"的提示。
   - 新增 `--no-stage`：若此时脚本路径或 LOG_DIR 仍落在受保护前缀 → **exit 非 0**，打印可执行修复指令（`migrate-log-root.sh` 命令行 + 改 `.zshrc` 的具体行 + 或去"完整磁盘访问权限"授权 `/bin/bash`）。**绝不**生成注定 126 失败的 plist。
   - plist 的 `EnvironmentVariables.NEIL_AUTOPILOT_LOG_DIR` 用**校验通过后**的 LOG_DIR；保留既有 PATH 构造与 bootout/bootstrap 逻辑。
3. 新建 `scripts/smoke-install-daily-schedule.sh`：**假 HOME 隔离**（`HOME="$tmp"`），**禁止**调用真实 `launchctl`（用 PATH stub 一个 `launchctl` 记录调用参数即可），断言 O5 的四种组合：
   - `LOG_DIR` 在假 HOME 的 `Desktop/` 下 + `--no-stage` → exit 非 0、**未生成** plist、输出含 `migrate-log-root.sh` 修复指令；
   - 同上 + `--stage-scripts` → exit 0、plist 的 `ProgramArguments` 与 `NEIL_AUTOPILOT_LOG_DIR` 均不含 `/Desktop/`、staged 脚本真实存在且可执行；
   - `LOG_DIR` 在 `Library/Logs` 下 + 两种 stage 开关 → 均 exit 0 且路径合法；
   - 断言全程没有真实 `launchctl bootstrap` 被执行（stub 记录里可有，但必须是 stub）。
4. 新建 `scripts/smoke-migrate-log-root.sh`：造源目录（0 个 / 1 个 / 3 个 jsonl + `runs/<run_id>/` 子目录 + metrics），断言行数守恒、源目录仍存在、`--dry-run` 不写目标、重复执行幂等。

**Verify**: `bash scripts/smoke-all.sh`

## Task 8: SKILL.md 渐进式瘦身 + 不变量门禁

**Status**: PENDING

落地 spec D14/O6。目标：`skills/using-neil-autopilot/SKILL.md` 从 16.4KB 降到 **≤9216 字节**，且强制约束一条不丢。

1. **留在正文**（一字不改地保留语义）：frontmatter、一句话定位、`<HARD-GATE>` 全部 7 条、执行档位表 + "控制器永不内联写码"铁律 + `run-track-a.sh` 用法与前置、判定规则、任务类型分流表、Skill 调用规则（通用 6 条 + 两档各自要点）、路径约定表、`{STAGE}_STATUS` 状态行与 REVIEW 三态指针、以及一张「按需加载」索引表（列出下面 5 篇 references 及**何时读**）。
2. **下沉到 `skills/using-neil-autopilot/references/`**（新建目录，5 个文件）：
   - `workflow-graph.md` ← 完整 DOT 流程图
   - `directory-layout.md` ← `autopilot/` 目录结构树 + archive 四层说明
   - `bootstrap.md` ← 初始化 bash 片段（分支纪律 / 变更目录 / 哨兵 / .gitignore）+ `progress.md` 模板 + 向下兼容说明
   - `usage-examples.md` ← 使用方式示例
   - `recovery.md` ← 恢复机制
   每篇开头一行写明「何时读我」。**内容整体搬迁，不许删减语义**。
3. 新建 `scripts/smoke-skill-invariants.sh`：
   - 断言 `SKILL.md` 字节数 ≤ 9216；
   - 断言正文仍含全部强制关键词（逐条 grep，缺一即失败）：`HARD-GATE`、`需求澄清`、`分支纪律`、`Code Review`、`验证`、`知识沉淀`、`状态可追溯`、`可观测验收`、`控制器永不内联写码`、`run-track-a.sh`、`拿不准`、`{STAGE}_STATUS`、`REVIEW_PASS`、`fail-closed`；
   - 断言正文里出现的每个 `references/*.md` 链接目标**文件真实存在**；
   - 断言 5 篇 references 都存在且非空、每篇含「何时读我」。
   - **自检有判别力**（O6 的 MR）：脚本内部对**临时副本**做三种扰动 —— 删掉一条 HARD-GATE 关键词 / 重命名一个 references 目标 / 把正文填充到超 9216 字节 —— 断言在这三种扰动下门禁**必须失败**（在临时目录里做，绝不改真文件）。
4. 同步 `hooks/session-start`（若它 cat 的是 SKILL.md，无需改逻辑，但要确认瘦身后注入正常）；`README.md` 若有 SKILL 结构说明则同步一句。

**Verify**: `bash scripts/smoke-all.sh`

## Task 9: 文档与知识沉淀

**Status**: PENDING

1. `AGENTS.md`：环境变量表补齐本次新增/变更项并注明默认值与优先级 —— `AUTOPILOT_TIMEOUT_<STAGE>`、`AUTOPILOT_KILL_AFTER_S`、`AUTOPILOT_TRANSPORT_RETRIES`、`AUTOPILOT_RETRY_BACKOFF_S`、`AUTOPILOT_USAGE_JSON`、`AUTOPILOT_RAW_JSON`、`AUTOPILOT_REVIEW_DIFF_BUDGET`、`AUTOPILOT_EMPTY_LOG_BYTES`、`NEIL_AUTOPILOT_KEEP_DAYS`(30)、`NEIL_AUTOPILOT_LOG_DIR`(新默认 `~/Library/Logs/neil-autopilot`)；观测脚本清单补 `classify-outcome.sh`/`review-context.sh`/`migrate-log-root.sh`/`smoke-all.sh`。**必须写明超时优先级链**。
2. `autopilot/knowledge/raw/` 新增一篇 `20260813-cost-latency-diagnosis.md`：记录本次实测数据（review 占 47%、6 次 UNKNOWN 全是 exit 1、timeout 无 `-k` 的哑弹实验、launchd TCC 126、telemetry 无 token 字段）与修复方案要点，标注数据来源文件路径。
3. 更新 `autopilot/knowledge/wiki/entities/telemetry-system.md`：补 dispatch 事件的新字段表 + 「token 从 `qodercli -o json` 信封抽取、缺失即缺省不写 0」的口径。
4. `README.md`：新增一节「成本与时延观测」——如何看 `runs/*.jsonl`、如何按 stage/model 聚合（给一条可复制的 jq 命令）、如何装每日分析（含 TCC 注意事项与 `migrate-log-root.sh`）。
5. 不改任何脚本逻辑（本 Task 只动文档）。

**Verify**: `bash scripts/smoke-all.sh && grep -q 'AUTOPILOT_KILL_AFTER_S' AGENTS.md && grep -q 'AUTOPILOT_TRANSPORT_RETRIES' AGENTS.md && grep -q 'Library/Logs/neil-autopilot' AGENTS.md && test -f autopilot/knowledge/raw/20260813-cost-latency-diagnosis.md && grep -q 'input_tokens' autopilot/knowledge/wiki/entities/telemetry-system.md`

## Task 10: 自迭代安全 — 递归护栏 + 并发锁 + smoke 遥测隔离

**Status**: PENDING

落地 spec §8（P8）。**这是唯一能防"plugin 改自己时无限递归烧 token"的门禁**，实现时逐条对齐，不要合并简化。

1. `scripts/run-track-a.sh` 与 `scripts/run-autopilot.sh`：解析参数**之前**做启动自检 —— 若继承到 `AUTOPILOT_ROLE=worker`，向 stderr 打印 `ERROR: nested autopilot run refused (AUTOPILOT_ROLE=worker)` 并 `exit 2`；仅当 `AUTOPILOT_ALLOW_NESTED=1` 时放行（供 smoke 用）。
2. `scripts/dispatch.sh`：**在 `export AUTOPILOT_ROLE=worker` 之前**把继承值快照到局部变量（如 `INHERITED_ROLE`），若其为 `worker` 且 `MODEL != TestModel` → stderr 打印 `ERROR: nested worker spawn refused` 并 `exit 2`；`TestModel` 放行以保留 smoke 能力。**注意执行顺序**：读快照必须早于 export，否则永远自我命中。
3. 三个 prompt builder（`build_impl_prompt` / `build_fix_prompt` / `build_review_prompt`）统一追加一段禁令，措辞含以下关键词以便断言：`禁止调用任何 autopilot-* / using-neil-autopilot / neil-coding-autopilot skill`、`禁止执行 run-track-a.sh / run-autopilot.sh / dispatch.sh`、`只做本 Task 描述的事`。
4. 并发锁：`run-track-a.sh` 用 `mkdir "$CHANGE_DIR/.lock"`（原子）加锁，锁内写 `pid` 与 epoch；已存在且（PID 仍存活 且 未超 12h）→ `exit 2` 并提示持有者 PID；否则视为陈旧锁自动接管。正常结束与 `trap`（INT/TERM/EXIT）路径都要清锁。`.lock` 必须进 `.gitignore`（幂等追加）。
5. smoke 遥测隔离：所有 `scripts/smoke-*.sh` 启动时 `unset AUTOPILOT_RUN_ID`（不要在 telemetry.sh 里特判 smoke 名字）。
6. 新增 `scripts/smoke-recursion-guard.sh`，逐条断言：
   - `AUTOPILOT_ROLE=worker bash scripts/run-track-a.sh --dry-run ...` → rc=2 且 stderr 含 `refused`；加 `AUTOPILOT_ALLOW_NESTED=1` 后不再是 2。
   - `AUTOPILOT_ROLE=worker` 调 `dispatch.sh --model Ultimate` → rc=2；`--model TestModel` → rc=0（**判别样例**：证明护栏不是一刀切）。
   - 同一 `--change-dir` 起第二个 `run-track-a.sh` → rc=2；把 `.lock` 的 mtime 倒推 13h 后 → 可被接管（rc≠2）。
   - 三个 prompt builder 的产物都含第 3 条的禁令关键词（用 TestModel dry 跑一轮取 prompt 文件断言）。
   - 遥测隔离：`NEIL_AUTOPILOT_LOG_DIR=<临时目录> AUTOPILOT_RUN_ID=real-xyz bash scripts/smoke-dispatch.sh` 后，临时目录里的 jsonl **不得**出现 `real-xyz`。
7. 不得放宽或删除现有 14 个 smoke 的任何断言。
8. **自指陷阱（必须一并处理，否则本 Task 自己验不过）**：本 Task 的 `**Verify**` 由 worker 执行，worker 环境里 `AUTOPILOT_ROLE=worker` 已被 dispatch.sh 导出；而 `smoke-run-track-a.sh` / `smoke-run-autopilot.sh` / `smoke-dispatch.sh` 内部会调真实编排脚本，必然命中第 1/2 条新护栏。⟹ 这三个 smoke 在**自身脚本开头**显式 `export AUTOPILOT_ALLOW_NESTED=1` 并 `unset AUTOPILOT_ROLE`，使其无论从控制器会话还是从 worker 内部运行都能通过。`smoke-recursion-guard.sh` 是例外：它要断言护栏生效，必须在**子 shell 里显式重设** `AUTOPILOT_ROLE=worker` 且**不带** `AUTOPILOT_ALLOW_NESTED`，不得依赖继承环境。

**Verify**: `bash scripts/smoke-all.sh`

## Task 11: 目标验收 — 成本/时延削减量测量 + 功能一致性审计

**Status**: PENDING

落地 spec §10。**只允许离线、确定性、零 token 的测量**（禁止为测量去发真实模型请求）。

1. 新建 `scripts/bench-compare.sh`，输出一张 markdown 表到 stdout 并写入 `autopilot/changes/autopilot-cost-latency/bench-report.md`，包含三组硬数字：
   - **review 上下文削减**：对本次变更涉及的每个 Task，算「旧口径」= 变更文件全文字节之和（`git show`/工作区读全文，即旧 `build_review_prompt` 让 reviewer 逐一读完的量）；「新口径」= Task 5 落地的有界 diff 字节数（调用其真实实现，不要复刻逻辑）。给出每 Task 与合计的字节数与削减百分比。
   - **SKILL.md 注入削减**：`git show master:skills/using-neil-autopilot/SKILL.md | wc -c` vs 当前 `wc -c`，以及 `skills/*/SKILL.md` 合计；给出百分比。
   - **重跑浪费的重放推算**：读 `${NEIL_AUTOPILOT_LOG_DIR}/runs/*.jsonl`（默认路径按 Task 7 结论），统计历史上 `stage=review|fix` 且被判为 TRANSPORT/EMPTY/TIMEOUT 的 dispatch 事件数与其 `duration_s` 合计，再统计因轮次耗尽导致的 `--resume` 重跑（同一 run_id 前缀出现多个 run 目录 / outcome=blocked 后又有同 change 的新 run）所重复消耗的 `implement` 时长合计。这两项即"新版本可避免的墙钟浪费"。**取不到数据时打印 `NO-DATA` 而不是编造 0**。
2. 新建 `scripts/smoke-backward-compat.sh`（功能一致性门禁），断言：
   - **CLI 兼容**：`run-track-a.sh` 与 `run-autopilot.sh` 的 `--change-dir/--cwd/--dry-run/--resume/--max-rounds/--impl-model/--review-model` 全部仍被接受（用 `--dry-run` + TestModel 实跑，rc=0）；`--help` 仍列出它们。
   - **env 兼容**：`AUTOPILOT_PLATFORM/AUTOPILOT_TIMEOUT/AUTOPILOT_IMPLEMENTER_MODEL/AUTOPILOT_REVIEWER_MODEL/AUTOPILOT_STAGE/AUTOPILOT_RUN_ID/AUTOPILOT_ROLE/NEIL_AUTOPILOT_LOG_DIR` 仍被读取且语义未变（对每个变量做一次可观测断言，例如设 `AUTOPILOT_TIMEOUT=1` 后 dispatch 一个 sleep 型 TestModel 应得 TIMEOUT 语义）。
   - **遥测 schema 只增不减**：`git show master:scripts/telemetry.sh` 里 dispatch 事件的字段名集合，必须是当前字段名集合的**子集**（新增允许，删改即失败）；且用 `jq -e` 断言当前产出的一条 dispatch 事件仍能被"只认旧字段"的消费者解析。
   - **行为变更白名单**：唯一允许的默认值变更是 `AUTOPILOT_REVIEWER_MODEL` 由 `Ultimate` → `Performance`（D16）与 `NEIL_AUTOPILOT_LOG_DIR` 新默认（Task 7）。断言 `AGENTS.md` 中这两项都有显式记载（`grep`）；若还有第三处默认值变更而未登记 → 失败。
   - **入口未消失**：`scripts/` 下 master 版本存在的每个 `*.sh` 在当前版本**仍存在**（可以新增，不许删）。
3. `scripts/smoke-all.sh` 自动纳入上面两个新 smoke（它按 `smoke-*.sh` 通配，确认无需改）。
4. 把 `bench-report.md` 的结论摘要（三组数字 + 一句结论）追加进 `autopilot/changes/autopilot-cost-latency/summary.md`（文件不存在则创建）。

**Verify**: `bash scripts/smoke-all.sh && bash scripts/bench-compare.sh && test -s autopilot/changes/autopilot-cost-latency/bench-report.md`
