# 静默回合的可控杠杆与两个被推翻的假设（2026-08-15）

## 背景

`20260815-silent-completion-and-verdict-contract.md` 已定位「静默 completion」（模型把整个回合收在 `thinking/redacted_thinking`、不产出 text，stdout 零字节）。本记录沉淀后续为「提速 + 省 token」做的定量实验：静默每次都白烧一个完整 worker 调用，review 阶段用的又是最贵的模型，因此降低它的代价是收益最高的一处。

所有数字来自当日 `$NEIL_AUTOPILOT_LOG_DIR/runs/2026-08-15.jsonl` 真实遥测与受控实验（同 fixture 仓库、同 prompt、逐一改变单个变量）。

## 定量基线

分阶段静默率（当日真实 dispatch，清洗掉 smoke 假数据后）：

| 阶段 | 静默率 | 浪费墙钟 |
|---|---|---|
| implement | 2/24 = 8.3% | 17s |
| review | 4/7 = 57% | 66s |

review 是最贵阶段（Ultimate + 最大上下文）却有一半以上调用零产出。

## 两个被实验推翻的假设（重要）

1. **假设「禁前言导致 reviewer 静默」→ 不成立。** 推理链条看起来很顺：reviewer 的交付物就是正文，而 dispatch 固化的「动手前禁止叙述」压制了文本通道。据此做了按阶段分化的契约（review / analyze-daily 不再背禁前言），然后实测 **4/8 = 50% 静默，与基线 57% 无实质差别**。契约分化本身作为「不自相矛盾」的设计保留了，但**不能宣称它降低了静默率**。

2. **假设「静默是 Ultimate 特有」→ 不成立（先前一度这样判断）。** 用同一份简单 review prompt 测：Ultimate 4/8 静默、Performance 0/6、Qwen3.8-Max 0/6，看起来是模型问题。但换用 run-track-a 真实生成的 review prompt 后，**Performance 同样连续 3 次静默**。进一步用真实 prompt 做二分（删「可观测验收」那条跨仓库读文件要求 / 删「递归安全禁令」整段）得到 1/3、2/3、2/3 —— 删段无效，也没有单一 prompt 段落是元凶。结论：静默是高方差的随机行为，受模型与 prompt 形态共同影响，不能归因到任一单一因素。

顺带纠正 AGENTS.md 里的一句错误论断：原文写 reviewer「空输出为 transport 抖动、由重试兜底，**与模型无关**」。这既误判了性质（不是链路问题），也误判了归因（模型与 prompt 都有影响），正是当初一直往网络方向查的原因。

## 真正起作用的杠杆：`--reasoning-effort`

既然故障形态是「回合死在 thinking 里」，就直接调这个旋钮。受控对照（同 prompt / 同模型 Performance / 同调用方式，N=4）：

| 推理档位 | 静默率 | 产出 |
|---|---|---|
| 默认 | 1/4 | 610–1159 B |
| `low` | **0/4** | 280–422 B，仍是实质审查（核对 Verify、安全、边界瑕疵，给出正确裁决） |

代价是审查变浅（字节数明显下降），所以**绝不做默认值**。

## 落地设计：静默阶梯（cheapest-first，保住首次质量）

`dispatch_with_retry` 对 EMPTY（静默且工作树未动）按顺序升级手段：

1. **立即重试，不退避**。退避只对 TRANSPORT（限流/连接重置）有意义；等待不会让 thinking-only 回合开口。实测 5 次静默重试合计 52s（旧退避 5+10+20+40 要多睡 75s）；smoke 里 4 次重试总耗时 4s（若误用 30s 基数需 210s）。
2. **首次静默后降 `--reasoning-effort` 到 `AUTOPILOT_SILENT_EFFORT`（默认 low）**。第 1 次尝试永不降档，保住默认深度。
3. **连续静默达 `AUTOPILOT_SILENT_SWITCH_AFTER`（默认 2）次后换 `AUTOPILOT_SILENT_FALLBACK_MODEL`（默认 Performance）** 跑完剩余尝试。
4. 上限 `AUTOPILOT_SILENT_RETRIES` 默认 5（单独于 TRANSPORT 的 3）；耗尽后 fail-closed，文案明确写「NOT a transport failure」并说明「工作树未动，重跑安全」。

两个开关都可设空字符串关闭，退回纯重试。

## 与「工作树已改动」的分工

- EMPTY（静默、工作树**未**动）→ 可安全重试，走上面的阶梯。
- SILENT（静默、工作树**已**动）→ **不重试**（新 worker 会在上一个的半成品上重做同一个 Task），直接 fail-closed 并提示先看 `git status`。

## 回归覆盖

- `smoke-dispatch.sh`：`--reasoning-effort` 默认不透传、显式设置时必须落在 variadic `--tools` **之前**（否则会被当成 tools 取值吞掉）；review / analyze-daily 不带禁前言、implement 保留禁前言。
- `smoke-run-track-a.sh` scenario 9：静默立即重试、不睡退避（退避基数设 30s 做反证）、上限生效、耗尽文案不再误标 transport。
- `smoke-run-track-a.sh` scenario 10：`MuteModel` 永不开口 + 降级模型正常 → 断言首次不降档（stub 记录每次实际档位）、第 2 次降到 low、达阈值后换模型、Task 最终 DONE 且真有产物；关闭开关后回到纯重试并仍 fail-closed。
- `smoke-all.sh` 19/19 全绿。

## 真实端到端结果

同一份 2-Task tasks.md：

- 修复前：review 连续 5 次静默 → 整轮 exit 2（两次复现，一次在 e2e3、一次在 e2e5）。
- 修复后（e2e6）：两个 Task 均 implement → verify → REVIEW_PASS → commit，`ALL TASKS DONE ✅`，**105 秒**跑完，本轮零静默；提交内容洁净（无 `.lock/`）、工作树干净。

## 待观察

- 静默率本身仍由上游决定，harness 只能降低其代价。当日累计 8/39 次 dispatch 静默（约 21%），已可由 `dispatch_silent_count` 持续跟踪。
- `low` 档审查偏浅，仅作为静默后的兜底。若未来发现「降档后 CR 漏问题」，应优先调高 `AUTOPILOT_SILENT_SWITCH_AFTER` / 改用另一个不静默的强模型，而不是把 low 变成默认。
