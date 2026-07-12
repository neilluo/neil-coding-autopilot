---
updated: 2026-07-12
category: guides
evidence: primary
sources: [raw/20260712-delegate-all-development.md]
---

# 指南：控制器永不内联写码，开发一律托管子 agent

**适用**：任何"编排器 + 执行"的 agent 工作流，尤其交互式控制器容易顺手把开发做在自己 context 里。

## 规则

1. **控制器只编排，不写码**。implement / verify 驱动的 fix / review 一律托管给 fresh-context 的一次性 worker（本项目 = `run-track-a.sh` 逐 Task spawn qodercli）；控制器只写 prompt、收日志摘要 + 状态行，不读源文件、不看 diff。
2. **"交互 = 必须内联"是伪命题**。真正吃 context 的开发细节可以、且应该 offload 到 worker；控制器卸不掉的只是编排级 context（小、慢涨）。交互档一样托管，只是由控制器在会话内启动 worker（可在 Task 间听用户反馈）。
3. **无人值守 vs 交互，只差外层是否有人**，不差"开发是否托管"（永远托管）。
4. **别把 offload 只当兜底**——它是默认。依据 Anthropic《Context Engineering》的 subagent 策略。

## 反例（本项目踩过）

- 交互跑 autopilot 全程内联写码 → 控制器 context 随开发膨胀（071202 实证）。
- 用"交互 agent 卸不掉自身 context，spawn 是假 A"给内联开发开脱 → 混淆了"开发细节 context"与"编排级 context"。

## 与既有 guide 的关系

- `track-a-launcher-pattern.md`：编排器必须是确定性脚本（run-track-a.sh），不是 LLM。本页是其推论：**连交互控制器也把开发托管给该脚本**。
- 粒度旋钮：小 spec → 1-Task tasks.md（≈直接给 spec），大 spec → 拆 N（见 autopilot-plan）。
