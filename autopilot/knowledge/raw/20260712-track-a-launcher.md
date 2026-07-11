---
created: 2026-07-12
source: evolve/071201_opt.md + github/google 调研 + 真实 E2E
evidence: primary
---

# Track A 有文档无入口：qodercli inner loop 从不被触发

## Problem

`071201_opt.md` 现场反馈：在业务项目（monitor）跑 autopilot，qodercli inner loop 从不触发。根因三层：
- **L1 能力**：qodercli / 已装 dispatch.sh 就绪，物理上能 spawn。
- **L2 设计**：skill 把交互入口钉死为档位 B（正确的有意约束）。
- **L3 语义**：交互 IDE agent 自己就是编排器、卸不掉自身 context，强行 spawn 也是"假 A"。

真正缺口：**整个 plugin 没有"启动 Track A"的入口**——SKILL 里只有一段让人手敲 `qodercli -p "以档位 A 跑…"` 的 blockquote，而那还要另一个 qodercli 自己读 SKILL、决定循环、调 dispatch，脆弱到没人会真用。证据：monitor 4 个历史变更的 tasks.md 全写着 "Track B"，inner loop 从未执行过。之前几轮修复（dispatch 路径解析 / timeout / parse-status 可移植）只让 Track A **变得可能**，没让它**变得可启动**。

## Solution

造确定性 bash 编排器 `scripts/run-track-a.sh`（Ralph Loop 范式）：编排器=脚本（零 context / 确定性 / 可续跑），worker=每步 fresh qodercli；基于既有原语 dispatch.sh + parse-status.sh + task-state.sh，跑 implement→verify→review→fix→commit。fail-closed（verify 失败 / REVIEW≠PASS / worker BLOCKED / commit 失败 / 轮数耗尽 → exit 2，绝不误标 DONE / 绝不静默 commit），退出码语义化（0/1/2/130），支持 --dry-run / --resume / --max-rounds。文档入口（using-neil / README / conventions）改为指向它，并明确"别用 LLM 当编排器"。

调研（GitHub/Google，两个 subagent 独立收敛）：Ralph Wiggum Loop、Aider scripting、Claude Code headless、SWE-agent batch、OpenHands 全是"脚本/harness 当编排器、agent 当 per-step worker"；唯一"LLM 当编排器"案例（Anthropic 多智能体）用于无法预先规划的开放式研究且自列协调爆炸/非确定/高成本等失败模式；HumanLayer 有"试 agent 驱动后退回 5 行 bash loop"的直接踩坑。

## 附带修掉的 macOS 可移植 bug（真跑/CR 才现形）

- `task-state.sh` 用 `flock` → stock macOS 无 flock（本机实测）→ 降级 mkdir 原子锁。
- 新脚本目标 **bash 3.2.57**（macOS 自带）：禁用 `declare -A` / `mapfile`，用普通数组 + awk 解析。
- run-track-a 日志放 `$TMPDIR`（不放业务仓库，否则被 `git add -A` 卷入 commit）。
- subagent CR 挖出 CRITICAL：commit 真失败（hook/签名）被当"无变更"→误标 DONE（fail-open）→ 改为分辨"无变更 vs 真失败"并 fail-closed（真失败 → BLOCKED + exit 2）。

## Evidence

- token-free 冒烟 `smoke-run-track-a.sh` 三场景全 PASS：① happy 全 DONE + 提交 + exit0 ② verify 失败 → exit2 + BLOCKED + 无提交 ③ commit 失败（pre-commit hook 拒绝）→ exit2 + BLOCKED + 不误标 DONE。
- 真实 E2E：从 monitor 隔离分支真跑，impl(Performance)→verify(py_compile)→review(Ultimate) `REVIEW_PASS`→commit `1d41fb0`，`RUN_RC=0`；worker 真建 `track_a_probe.py` 并输出 `TRACK_A_PROBE_OK`。**qodercli inner loop 确认触发。**（自测产物已 teardown 清理。）
