# 无人值守三段流水线的修复：确定性 finish 与「产物优先于自述」（2026-08-15）

## 背景

`run-autopilot.sh` 是档位 A 的无人值守入口（loop → finish → evolve）。上游修复（见 `20260815-silent-completion-and-verdict-contract.md`、`20260815-silent-turn-levers-and-refuted-hypotheses.md`）让 `run-track-a.sh` 的 loop 稳定跑通后，本记录沉淀 **run-autopilot 自身从"结构性坏"到三段全绿**的过程。所有结论来自真实跑，不是 smoke 推断。

## 实测结论

1. **`parse-markers` 修好后 run-autopilot 仍然跑不通**。真实跑：loop 全部成功，却死在 stage 2/3，日志只说 `finish BLOCKED (status=UNKNOWN)`，7 秒就结束——真实 merge+归档不可能这么快。原因是 finish worker 静默，而**本脚本每阶段只 dispatch 一次、没有任何重试**（run-track-a 早就有重试，这里没有）。这说明「同一个缺陷要在每个编排入口各修一次」，不能假设修了一处就全好。

2. **finish worker 7/7 次未给出结论**，其中一次吐了一句前言（"正在使用 autopilot-finish 完成分支合并。"）后就停、一个工具都没执行、分支未合并——即仓库注释里记录的 `stop_reason=tool_use` 截断。把 prompt 从"读 SKILL.md 执行整套 7 步流程"换成 1182 字节的内联 4 步清单后**同样失败**，所以排除了"SKILL.md 间接层"与"prompt 体量"两个假设。

3. **任务的工具步数才是关键风险因子**。同一模型、同一 cwd：单步小任务（写一个文件 / 跑一次 git）静默 2/4；finish 那种多步序列 7/7 全静默。这与仓库既有的缓解建议「缩小 Task 粒度」一致。

4. **finish 的全部步骤都是确定性的**：全 Task DONE 校验、基分支探测、merge、归档、提交、清哨兵。让 LLM 做这些，只是把无人值守链路变成掷硬币，没有任何判断力收益。

5. **evolve 也犯了同样的错**（提示词让它"读 SKILL.md 执行完整三层流程"），5 次全静默且零产出。收窄为"只交付一份 raw 笔记"的自包含单产物任务后，真实跑**第一次尝试即 `EVOLVE_STATUS=DONE`**（992 字节合规笔记）。

6. **evolve 存在"干完活不报数"**：一次真实跑里 worker 已写出 633 字节合规 raw 笔记（含 front-matter），却未输出 `EVOLVE_STATUS=DONE`，于是整条流水线在最后一步被判失败——而知识已经沉淀完了。且这些文件没人提交，会永久留脏。

7. **implement 的"干完活不报数"同理不该停机**。本仓原则本就是「控制器自己跑 verify、绝不信自述」，所以对 implement/fix 而言地面真相是 **verify 通不通**，不是那行 Status。旧逻辑一遇静默改盘就停机要人工介入，白白丢弃已完成且可验证的工作。

8. **finish 成功后无法从入口重跑**：change 目录已被搬进 archive，再跑 run-autopilot 会在 loop 就失败（读不到 tasks.md）。于是"只差沉淀一步"变成无法恢复，只能手工拼命令。

## 修复要点

- **新增 `scripts/finish-change.sh`：finish 改为确定性执行（C10）**。门禁：① tasks.md 全 Task DONE（否则未审工作会进主干）；② 工作树必须干净（绝不盲目合并）。基分支自适应探测 master/main（C4，不写死）；冲突即 `merge --abort` + 还原分支；归档委托已有的 `archive-change.sh`（幂等 + XOR 不变量）；末尾清 `.run-active`。`AUTOPILOT_FINISH_MODE=worker` 可退回旧 agent 路径（需要 SKILL.md 的 PR/CI 语义时）。
- **run-autopilot 补上与 run-track-a 同一套静默阶梯**：立即重试（不退避）→ 降 `--reasoning-effort` → 换模型；安全红线是"工作树指纹未变才重试"（finish/evolve 都不幂等，绝不在半成品上重跑）。停机文案区分"静默"与"worker 明确拒绝"，并说明重跑是否安全。
- **产物优先于自述，贯彻到每个阶段**：
  - daily-analysis → `reports/<date>.md` 是否落盘；
  - evolve → 知识库是否新增内容（新增即验收，并自动提交产物，避免永久留脏）；
  - implement/fix → **verify 门禁**说话（静默改盘不再停机，交给 verify + 独立 CR 判；verify 失败仍 fail-closed）。
- **evolve 提示词收窄为单产物自包含任务**（只写一份 raw 笔记，不改代码不碰 git），wiki 编译/全局升迁等多步动作留给交互档或下一轮，不在无人值守路径上用可能静默的 worker 去换。
- **可重跑性**：新增 `--skip-loop`；并按证据自动恢复——change 目录不在 `changes/` 且 `archive/` 里有同名归档时，判定 loop+finish 已完成、直接从 evolve 续跑。要求"归档确实存在"而不是"目录不在"，以免把 `--change-dir` 拼错静默当成已完成。

## 效果（真实跑对比）

| 阶段 | 修复前 | 修复后 |
|---|---|---|
| finish | 7/7 未给结论 → 整条流水线死在 stage 2/3 | 确定性执行，**3–4 秒稳定完成**（两次真实跑均一次成功） |
| evolve | 提示词过重，5 次全静默零产出 | 收窄后首次尝试即 DONE；静默但有产物时凭产物验收 |
| implement 静默改盘 | 停机要人工介入，丢弃已完成工作 | 交给 verify + 独立 CR，真正完成并提交 |
| 三段整体 | 从未跑通 | **`ALL STAGES DONE ✅`，142 秒** |

最终一次真实跑的产物核验：主干上 `bash dbl.sh 21` → `42`；`changes/` 为空且 `archive/2026/08/08-15/2026-08-15-dbl-helper/` 含 spec+tasks+summary（XOR 成立）；`knowledge/raw/20260815-dbl-helper.md` 已提交；工作树干净；提交历史无 `.lock/` 或日志泄漏。

## 回归覆盖（C7）

- 新增 `smoke-finish-change.sh`（6 场景）：happy + XOR + summary、未 DONE 门禁不误合并、脏工作树门禁、main/master 探测、`--dry-run` 零写入、冲突 fail-closed 并还原分支。断言用"是否真有双 parent 合并提交"而非字符串近似。
- `smoke-run-autopilot.sh` 扩到 6 场景：finish 静默被重试救回（worker 模式）、`FINISH_STATUS=`/`EVOLVE_STATUS=` 可解析、evolve 静默但有产物→凭产物验收并提交、evolve 静默且无产物→仍 fail-closed、归档后重跑自动恢复到 evolve、拼错 change 名仍失败。
- `smoke-run-track-a.sh` Scenario 8 重写：静默改盘 → 交给 verify 判并真正 DONE+commit；对照组 verify 失败 → 仍 fail-closed、零提交。
- `smoke-all.sh` **20/20 全绿**。

## 待观察

- evolve 仍是唯一 model-dependent 阶段。当前有五道保护（立即重试 / 降档 / 换模型 / 产物验收 / 诚实 fail-closed），真实跑 2 次成功、1 次在收窄前失败。样本仍偏小。
- 静默率由上游决定：当日真实 dispatch 中约 20–30% 静默。harness 只能降低其代价，不能消除。若未来 `dispatch_silent_count` 趋势上升，应优先调 `AUTOPILOT_SILENT_RETRIES` / 换模型，而不是放松任何门禁。
