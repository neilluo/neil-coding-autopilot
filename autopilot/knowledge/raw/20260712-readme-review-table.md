---
created: 2026-07-12
source: evolve/readme-review-table (第二轮 dogfooding)
evidence: primary
---

# 自动门禁放过文档"内部悬空引用"——第二轮 dogfooding 才抓到

## Problem

首轮 README overhaul（Track A 托管产出）通过了 verify（grep 断言：有 mermaid、≥10 H2）与 Ultimate reviewer（REVIEW_PASS），但仍留了一处内部一致性缺陷：正文第 68 行引用"见下方 REVIEW 状态表"，而**这张表根本不存在**；且三态中最关键的 `INCOMPLETE`（未审→不得静默 PASS→不得进 finish）全篇 0 次提及。

两道自动门禁都没拦到：
- **verify**（结构化 grep）只断言"有 mermaid / ≥10 H2"，管不了"被引用的表是否真的存在"。
- **reviewer**（代码向维度：安全/逻辑/健壮性）聚焦技术准确性，没查文档的内部交叉引用一致性。

## Solution

第二轮走 Track A（同样控制器不内联、delegate 给 qodercli worker）增量编辑：补上真实的 REVIEW 三态表（PASS/FAIL/INCOMPLETE，判定条件 + loop 后果，逐条对齐 `skills/autopilot-review/SKILL.md`），并把悬空引用改为"三态见下表"。verify 强化为断言三态 token（含此前缺失的 INCOMPLETE）均在，RUN_RC=0、REVIEW_PASS，commit 受新加的 .gitignore 保护无 scratch。

## Lesson

- **自动门禁有盲区**：结构化 grep verify + 代码向 CR 都可能放过文档的"内部悬空引用/缺表"。文档类交付物的验证/审查维度应显式包含"被引用的表/章节/锚点真的存在"（可用针对被引用物的定向 grep 作为 verify 子句）。
- **dogfooding 要迭代**：一轮 REVIEW_PASS 不等于零缺陷；第二次真跑 + 定向复核才抓到首轮遗漏。与 C7 verify-by-running 同源——把交付物真正"用一遍/读一遍"胜过信任一次通过。
- **次要环境观察**：控制器写完 tasks.md 立刻调 run-track-a.sh 读取，可能撞文件 flush 竞态（本轮首次 dry-run 报 "no Task"，重试即正常）；影响小，重试可解。
