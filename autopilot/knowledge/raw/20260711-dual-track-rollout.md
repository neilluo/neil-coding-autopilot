---
created: 2026-07-11
source: evolve/cr-round-1
evidence: primary
---

# 双档抽象只改框架层、执行层遗漏

## Problem

`fix/workflow-hardening`（commit 2004e42）引入两个横切抽象——双档执行（A / B）与 `REVIEW_STATUS=INCOMPLETE`——但只落在框架层（using-neil-autopilot / conventions / checkpoint）。执行层 skill（loop / plan / finish / evolve / analyze）零档位感知：

- `loop` 无条件 "Spawn qodercli worker"，与"档位 B 不 spawn"直接矛盾；
- `review` 发出 INCOMPLETE 并声称"loop 收到 INCOMPLETE 不得进 finish"，但 loop / finish 都不消费该状态（空头支票）；
- 附带缺口：loop digraph "CR 3 轮后 force complete"（fail-open）；finish 仍硬编码 `main`。

作者的"残留清扫"只 grep 了被删 token（ext_info / --max-turns / *.java），没验证跨 skill 契约闭环 → token 干净但契约断裂。

## Solution

- 不按档位 fork：执行层保留一套步骤，差异集中到 conventions「档位适配表」（单一事实源）。
- INCOMPLETE fail-closed：loop CR 三态分支 + finish 合并前 CR 完整性硬门（真正的消费者）。
- 删除 force-complete fail-open → BLOCKED。
- finish 去硬编码 main → base 分支自适应。
- 验证从"grep 被删 token"升级为"grep 覆盖率 + producer→consumer 闭环"。

## Lesson

引入横切抽象（新档位 / 新状态 / 新契约）时：

1. 必须同步 rollout 到**所有消费该抽象的 skill**，不能只改定义处；
2. 必须验证 **producer→consumer 闭环**（谁发出、谁消费、断了没）；
3. 残留验证要查"契约完整性"，不只是"旧 token 是否删净"；
4. **fail-closed 优先**：新增"未完成 / 未知"状态默认挡住流程，绝不静默放行。
