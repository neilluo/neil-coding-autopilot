# 静默 completion 与结论标记契约（2026-08-15）

## 背景与数据来源

`neil-fbi-init` 项目使用 Track A 开发 `metrics-caliber-consistency` 变更时，07:00–07:35 连续 4 次启动全部 fail-closed，日志一律报 `transport failure`，但网络与 CLI 均正常。本记录沉淀该次排障的实测证据与修复。

证据来源：

- `$TMPDIR/autopilot-track-a/metrics-caliber-consistency-2026081{5-003210,5-070319,5-072212,5-073536}/`：4 次运行的 driver.log 与每次尝试的 worker 日志。
- `~/.qoder/projects/-Users-neil-Desktop-neilcodebase-neil-fbi-init--worktrees-caliber/*.jsonl`：qodercli 会话记录，含每个 assistant 回合的 content block 类型。
- `scripts/dispatch.sh`、`scripts/classify-outcome.sh`、`scripts/parse-markers.sh`、`scripts/run-track-a.sh`、`scripts/run-autopilot.sh`：修复前行为的代码依据。
- 修复后在 `$TMPDIR` scratch git 仓库上的两次真实端到端跑（1 Task / 2 Task），使用真实 qodercli 1.0.16 + Performance/Ultimate。

## 实测结论

1. **4 次运行的 worker 日志全部恰好 74 字节，内容只有 dispatch 自己的 stderr banner**（`dispatch: stage=implement timeout=1800s ...`），qodercli 一个字节都没吐到 stdout。6 次尝试的日志 md5 完全相同。

2. **会话记录显示模型只产出 thinking，不产出 text**：失败回合的 assistant content block 序列为 `thinking,redacted_thinking` 后即结束，既无 `text` 也无 `tool_use`。qodercli 只打印 text block，因此 stdout 为空。这与 `stop_reason=tool_use` 的工具调用截断（TRUNCATED_TOOL_USE）是两种不同故障。

3. **最严重的一例是"干完活被判失败"**：会话 `a0b7c2d9` 的序列为 `thinking,redacted_thinking,tool_use×6,thinking,redacted_thinking,tool_use×3,thinking,redacted_thinking,tool_use×2,thinking,redacted_thinking` —— 11 次工具调用已执行、文件已落盘，但最后一个回合只在 thinking 里收尾，于是零输出被判掉线、结果被丢弃，并在已被改动的工作树上重试。

4. **根因是 dispatch 内固化指令自相矛盾**：原措辞为「严禁输出任何解释、计划、前言或**总结**文字」，而 run-track-a 的报告格式要求「回复末尾必须输出 `**Status:** DONE`」。对思维链模型，全面禁止输出文字会把整个回合压进 thinking 通道，text 通道彻底关闭。

5. **判定链把这种静默一路误标成 transport**：`classify-outcome.sh` 对「rc=0 且无锚定 marker」判 EMPTY（设计如此），`run-track-a.sh` 把 EMPTY 与 TRANSPORT 同等对待并有界重试，日志文案统一写 `transport failure` / `transient failure`。误导性文案直接导致约 35 分钟排查方向偏向网络。

6. **`parse-markers.sh` 的锚定集合窄于系统自己要求的输出形式**（同族假阴性）：
   - `run-autopilot.sh` 要求 finish/evolve worker 输出 `FINISH_STATUS=DONE` / `EVOLVE_STATUS=DONE`，但解析器只认 `^\**Status[:：]`，`FINISH_STATUS=DONE` 恒解为 UNKNOWN → finish 阶段无论实际成败都判 BLOCKED，无人值守全链路无法跨过 finish。归档的 `2026-07-18-self-evolution-hardening/explore-notes.md` 曾记载"对 `FINISH_STATUS=DONE` 亦匹配"，该假设在 D19 锚定式重写后已不成立。
   - impl/fix 提示词的报告格式本身写作 markdown 列表项 `- **Status:** DONE`，带列表符时同样不匹配。

7. **headless 调用缺少 `--tools default`**：`--tools` 是 qodercli 的 variadic 选项（`--tools <tools...>`），用于显式放开全部内置工具；缺省时若用户级/项目级 settings 收窄了工具集，headless 工具循环可能静默不执行。该选项必须紧跟一个选项（这里紧邻 `-p`）来终止取值。

8. **harness 自己的运行期锁被提交进业务仓库**：`run-track-a.sh` 的 per-change 锁原先落在 `$CHANGE_DIR/.lock`，而每个 Task 提交都跑 `git add -A`，实测把 `autopilot/changes/<name>/.lock/pid`、`.lock/epoch` 一并提交（真实端到端跑中观测到，CR 也独立报出该条）。同仓的 `task-state.sh` 锁与 `LOG_DIR` 早已遵守"harness 产物不落业务仓库"，此处是遗漏。

9. **静默 completion 在修复后仍会零星发生，但可被有界重试兜住**：两次端到端验证共出现 5 次静默（implement 2 次、review 3 次），每次都在同一 Task 内由重试恢复；关键前提是这些静默回合并未改动工作树，重试因此是安全的。

## 修复要点

- **指令契约改为按阶段精确约束**：动手之前禁止解释/计划/前言；完工后必须在回复正文末尾输出「报告格式」要求的结论标记行。两个反面教训写进注释：① 不能声称结论行是"唯一允许的输出"—— reviewer 的交付物本身就是审查正文，该措辞实测导致 reviewer 连续静默；② 不能硬命令"立即调用工具"—— 只读审查可能无需工具，必须留直接下结论的路径。标记形式不写死，统一指向提示词自带的「报告格式」段。
- **`--tools default` 加入两条 qoder 调用路径**，紧邻 `-p` 以终止 variadic 取值。
- **`dispatch.sh` 新增 SILENT_COMPLETION 诊断**：rc=0 且实际输出中无任何锚定结论行时，向 stderr 说明真实成因（模型在 thinking/redacted_thinking 中收尾、工具可能已执行、文件可能已落盘、重试会在已改动的树上重做）。刻意不改 rc —— 保持 0 才会被归为 EMPTY，改成非 0 反而会被 `classify-outcome.sh` 第 4 条误归为 TRANSPORT。诊断文案不得出现行首锚定标记或 TRANSPORT 关键词，否则会污染自身分类结果。
- **结论行的查找对象必须是"真正吐给上层的字节"**：JSON 信封模式下结论行在 `.result` 内而非信封表面，故引入 `VERDICT_FILE`，信封路径下指向抽取后的 result 文件。否则正常报数的 worker 会被误判为静默（该缺陷由 smoke 中 `(.failure_class|not)` 断言当场抓出）。
- **`run-track-a.sh` 引入工作树指纹区分两种同形 EMPTY**：`worktree_signature()` 取 `git status --porcelain` + `git diff HEAD` 的 cksum；EMPTY 且指纹变化 → 判为新结局 `SILENT`，不重试并给出准确停机原因；指纹未变 → 仍属真掉线，照旧有界重试。非 git 目录恒得同一签名，不会误判。
- **fail-closed 出口统一为 `fail_closed_stop()`**，按结局给出准确文案：SILENT 明确写 "NOT a transport failure" 并提示先看 `git status` 再决定保留或丢弃，不再谎称 transient。
- **`parse-markers.sh` 锚定集合扩宽到覆盖系统自己要求的全部形式**：可选 markdown 列表符（`- * +`）、反引号、粗体星号；标记名接受 `Status` 或 `XXX_STATUS`；分隔符接受 `:` `：` `=`。两道防误报约束保持不变：只看末 15 行、必须行首锚定（正文中提及不算结论）。
- **锁移出业务仓库**：`LOCK_DIR` 默认改为 `${TMPDIR}/autopilot-track-a-lock<mangled-change-dir>`，以 CHANGE_DIR 路径作键保持同一 change 的并发互斥；新增 `AUTOPILOT_LOCK_DIR` 显式覆盖入口（便于测试与运维）。

## 回归覆盖（C7 verify-by-running）

- `smoke-parse-markers.sh`：新增 7 条契约形式（列表符 + 粗体、`FINISH_STATUS=`、反引号、列表符 + 反引号、review 的粗体/反引号/列表符）与 2 条行中提及的误报防线。
- `smoke-dispatch.sh`：断言契约两半都到达 worker、不再出现"唯一允许"、保留无需工具的路径、`--tools default -p` 相邻；SILENT_COMPLETION 保持 rc=0、被 `classify-outcome.sh` 归为 EMPTY、不伪造结论标记；正常报数的 worker 不被打上静默标签。顺带修正了原 fixture 的 `\\n` 转义 —— 它从未产生真换行，因此从未真正构造出"结论行独占一行"的样本。
- `smoke-run-track-a.sh`：新增 Scenario 8，`silent_dirty` stub（先改盘再零输出 exit 0）验证判为 SILENT、零重试、无第二次尝试日志、exit 2、无假 DONE、无提交；对照组（零输出但不改盘）验证真掉线的重试路径未被误伤、仍归 transport。Scenario 1 新增"任何提交都不得含 `.lock/` 路径"的不变量断言。
- `smoke-recursion-guard.sh`：锁相关用例改用 `AUTOPILOT_LOCK_DIR`，并新增"锁绝不落在业务仓库内"的断言。
- `smoke-all.sh` 19/19 全绿；真实 qodercli 端到端两次跑通（2 Task 版本：两个 Task 均 implement → verify → 独立 CR REVIEW_PASS → commit，`ALL TASKS DONE`），提交内容洁净、工作树干净、无锁泄漏。

## 待观察

- 静默 completion 属上游模型/CLI 行为，修复只能降低发生率并保证安全兜底，无法根除。当前默认 `AUTOPILOT_TRANSPORT_RETRIES=3` 在实测中足够（最差用到第 3 次），若后续遥测显示静默率上升，可上调该值而非放松判定。
- `AUTOPILOT_TM_FAILURE_CLASS` 新增 `SILENT_COMPLETION`（dispatch 侧）与 `SILENT`（编排侧）两个取值，可用于按 stage/model 统计静默率。
