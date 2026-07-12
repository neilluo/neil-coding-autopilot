# Spec — 开发一律托管 qodercli（控制器永不内联写码）

> 变更类型：refactor（把设计决策编码进 plugin 文档）
> 执行档位：B（交互）
> 分支：`refactor/delegate-dev-to-qodercli`（从 master 切出）
> 状态源：本文件 + TodoWrite

## 1. 背景与根因

071202_opt.md 实证：交互跑 autopilot 全程落在"档位 B = 控制器内联写码"，开发细节全进控制器 context。报告用"交互 agent 卸载不了自身 context，spawn 也是假 A"替内联开发辩护——**这个前提是错的**：

- 托管给 qodercli 后，真正吃 context 的开发细节（读源文件、多轮测试失败、大 diff）**全在 worker 的独立 fresh context**；
- 控制器只留 prompt + tail 摘要 + 状态行，**开发细节从不进控制器**。

这正是 Anthropic context-engineering 手册背书的 subagent offload——现状只当"context 压力兜底"，本变更把它升为**默认**。

## 2. 方案（用户确认的推荐方案）

**铁律：控制器永不内联写码；loop 的开发一律经 `run-track-a.sh` 托管给 fresh qodercli worker（两档通用）。**

- 保留 `tasks.md`（run-track-a.sh 的输入），**脚本一行不动**（已测、已在 monitor 跑通）。
- 粒度是旋钮：小 spec → 1-Task tasks.md（≈直接把 spec 给 worker）；大 spec → 拆 N 个 Task。
- 两档区别缩小为"外层阶段（explore/analyze/plan/finish/evolve）是否有人交互"：
  - **档位 A · 无人值守**：从终端起 run-track-a.sh 端到端。
  - **档位 B · 交互**：控制器在会话内跑外层阶段，**loop 同样调 run-track-a.sh** 托管开发。
- 删掉"档位 B = 控制器内联开发"。

## 3. 为何保留 tasks.md（不是删）

`run-track-a.sh` 本质 tasks.md 驱动（L82 无文件即 exit1；L272 无 `## Task N` 即 exit1；worker prompt 从 task block 拼）。去掉 tasks.md 要给已测脚本加 spec-mode 新代码路径 = **更大改动 + 丢粒度化 CR / 逐 Task commit / --resume / worker context 卫生**。保留 tasks.md（可小到 1 Task）= 零脚本改动。

## 4. 改动清单（纯文档 + 知识库，零脚本改动）

| 文件 | 改动 |
|------|------|
| `skills/using-neil-autopilot/SKILL.md` | 执行档位表重定义（B 的 loop 走 run-track-a.sh 托管）+ Skill 调用规则 + 完整流程注 |
| `skills/_shared/conventions.md` | 执行档位描述 + 档位适配表（Task/CR/fix 改托管）+ Worker 模板适用范围 |
| `skills/autopilot-loop/SKILL.md` | 删控制器内联；档位 B 执行段改"启动 run-track-a.sh"；简化 context 兜底；规则 #1/#5；Architecture 注；commit 规范 |
| `skills/autopilot-plan/SKILL.md` | tasks.md 两档都产 + "小 spec→1-Task / 大 spec→N" 粒度指南；Step5 分支纪律对齐 |
| `AGENTS.md` / `README.md` | 双档描述同步（开发一律托管） |
| `autopilot/knowledge/**` | evolve 沉淀（raw + guide + index/log + SCHEMA 约束） |

## 5. 验证方法（改动正确性）

- **一致性 grep**：无残留"档位 B = 控制器内联/直接实现"；`run-track-a.sh` 被标为 loop 的两档入口；plan 有 1-Task 指南。
- **零脚本改动**：`git diff --stat` 不含 `scripts/`。
- **回归**：重跑 `smoke-dispatch.sh` + `smoke-run-track-a.sh`（token-free）确认脚本仍绿（机制未变、上一轮已真机 E2E 过）。

## 6. 边界 / 非目标

- 不改任何 `scripts/`（零脚本改动是本方案的卖点）。
- 不重新真机 E2E 烧 token——机制（run-track-a.sh 托管 qodercli）未变，上一轮已 RUN_RC=0 验过。
- 不动并行执行 / 人工门禁等可选段（超范围）。
