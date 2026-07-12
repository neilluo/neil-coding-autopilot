---
created: 2026-07-12
source: evolve/071202_opt.md + 用户设计决策
evidence: primary
---

# 控制器不该内联写码——开发一律托管 qodercli（纠正"假 A"前提）

## Problem

071202_opt.md 实证：交互跑 autopilot 全程落在"档位 B = 控制器内联写码"，开发细节（读源文件、多轮测试失败、大 diff）全进控制器 context。071201/071202 用一句话替内联开发辩护：**"交互 agent 卸载不了自身 context，spawn 也是假 A"**——据此把"控制器内联开发"当作交互档的合理默认。

这个前提错了：它混淆了两种 context。真正吃 context 的是**开发细节**，托管给 fresh qodercli worker 后这些细节全在 worker 的独立 context 里；控制器只留 prompt + 日志摘要 + 状态行。控制器"卸不掉的"只是**编排级** context（阶段进度 + 对话），它小且慢涨。所以托管**确实**让控制器保持干净——"假 A"是替内联开发开脱的合理化说辞。

## Solution

确立铁律：**控制器永不内联写码；loop 的开发一律经 `run-track-a.sh` 托管给 fresh qodercli worker（两档通用）。**

- 两档区别缩小为"外层阶段（explore/analyze/plan/finish/evolve）是否有人交互"：A 无人值守（终端起脚本）/ B 交互（控制器会话内跑外层 + 会话内 `bash run-track-a.sh` 跑 loop）。
- 删掉"档位 B = 控制器内联开发"。
- tasks.md 两档都产（run-track-a.sh 输入）；粒度是旋钮：小 spec → 1 Task（≈直接给 spec）、大 spec → 拆 N。
- **保留 tasks.md 而非删它**：run-track-a.sh 本质 tasks.md 驱动，去掉要给已测脚本加 spec-mode 新路径（更大改动 + 丢粒度化 CR / 逐 Task commit / --resume / worker context 卫生）。

## Evidence

- 纯文档改动（using-neil / conventions / loop / plan / AGENTS / README + 知识库），**零脚本改动**（git diff 不含 scripts/）。
- 一致性 grep：残留内联语句 = 0；run-track-a.sh 成两档 loop 入口（6 文件均引用）；铁律落地 5 文件。
- 回归：smoke-dispatch + smoke-run-track-a 均 ALL PASS（机制未变，上一轮已真机 E2E RUN_RC=0）。

## 依据

Anthropic《Context Engineering》：subagent offload——把重活交给独立 context 的子 agent，主 context 只收摘要。本项目把它从"context 压力兜底"升为**默认**。
