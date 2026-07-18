---
updated: 2026-07-18
category: guides
evidence: primary
sources: [raw/20260712-track-a-launcher.md, raw/20260718-self-evolution-hardening.md]
---

# 指南：自主批处理用"确定性脚本编排器"，不是"LLM 当编排器"

**适用**：要做"无人值守跑完多 Task"的 headless / 批处理编排（本项目档位 A）。

## 规则

1. **编排器必须是确定性脚本（bash），不是 LLM**。编排器只做：读落盘任务表 → 逐 Task 派活 → 收状态 → 判 verify/CR → commit；把重活 offload 给每步 fresh 的一次性 agent worker。理由：编排器若是 LLM，context-rot 只是从 worker 搬到编排器，且非确定、难调试、烧 token。
2. **业界一致**：Ralph Wiggum Loop / Aider scripting / Claude Code headless / SWE-agent batch / OpenHands 全是"脚本 harness 编排 + per-step fresh agent"。唯一"LLM 当编排器"（Anthropic 多智能体）用于**无法预先规划路径**的开放式研究，且自列协调爆炸 / 非确定 / 高成本等失败模式；HumanLayer 记录过"试 agent/hook 驱动后退回 5 行 bash loop"。可预先枚举的编码流水线不需要 LLM 编排。
3. **fail-closed 是铁律**：verify 失败 / REVIEW≠PASS / worker BLOCKED / commit 失败 / 轮数耗尽 → 停并上报（非零退出），绝不误标 DONE、绝不静默 commit。编排器**自己**跑 verify，不信 worker 自报。
4. **状态落盘 = 单一事实源 + checkpoint**：`tasks.md` 的 `**Status**:` 行既是进度也是断点续跑依据（`--resume` 跳过 DONE）。
5. **退出码语义化**：`0=全 DONE / 1=用法错 / 2=BLOCKED / 130=中断`，便于 CI/父脚本分支。
6. **可 `--dry-run`**：先解析打印计划、不烧 token，再真跑。

## 本项目落地

`scripts/run-track-a.sh`（编排器）+ `dispatch.sh`（起 worker）+ `parse-status.sh`（解析状态）+ `task-state.sh`（原子改状态）。回归：`scripts/smoke-run-track-a.sh`（token-free 三场景）。入口见 `using-neil-autopilot`「执行档位」。真跑前先 `smoke-dispatch.sh` + `smoke-run-track-a.sh` 冒烟。

**端到端层**：`scripts/run-autopilot.sh` 在 loop 之上串 `loop → finish → evolve`（同样是确定性脚本编排、fail-closed），`run-track-a.sh` 保持 loop-only 单一职责；详见 [[run-autopilot]]。回归：`scripts/smoke-run-autopilot.sh`。

## 出处

Ralph: ghuntley.com/ralph、github.com/snarktank/ralph；ralphloop.sh（退出码/fail-closed/CLI）；Aider scripting（aider.chat/docs/scripting.html）；SWE-agent batch mode；OpenHands eval harness；Anthropic multi-agent-research-system（反例 + 失败模式）；HumanLayer brief-history-of-ralph（退回 bash loop）。
