# Spec — Track A 一键启动器（run-track-a.sh）

> 变更类型：feature（补上 Track A 缺失的启动入口）
> 执行档位：B（交互，用了 2 research + 1 code-review subagent）
> 分支：`feat/track-a-launcher`（从 master a804433 切出）
> 状态源：本文件 + TodoWrite

## 1. 背景与根因

`071201_opt.md` 现场反馈：在业务项目（monitor）跑 autopilot，qodercli inner loop 从不触发。根因三层：L1 能力 OK；L2 设计把交互入口钉死为档位 B（正确）；L3 语义——交互 agent 自己就是编排器、卸不掉自身 context。真正缺口：**plugin 没有"启动 Track A"的入口**，只有一段让人手敲 `qodercli -p` 的脆弱 blockquote。前几轮修复只让 Track A "可能"，没让它"可启动"。

## 2. 方案（GitHub/Google 调研 → 两个 subagent 独立收敛）

造**确定性 bash 编排器** `scripts/run-track-a.sh`（Ralph Loop 范式），而非"LLM 当编排器"。编排器=脚本（零 context/确定性/可续跑），worker=每步 fresh qodercli，基于既有原语 dispatch.sh + parse-status.sh + task-state.sh。

## 3. 改动清单

| 文件 | 改动 |
|------|------|
| `scripts/run-track-a.sh`（新） | 串行内循环 implement→verify→review→fix→commit；fail-closed；退出码 0/1/2/130；`--dry-run/--resume/--max-rounds/--impl-model/--review-model`；bash 3.2 兼容；日志入 `$TMPDIR` |
| `scripts/smoke-run-track-a.sh`（新） | token-free 回归：①happy 全 DONE ②verify 失败→exit2 ③commit 失败→exit2 不误标 DONE |
| `scripts/task-state.sh` | flock → mkdir 原子锁降级（stock macOS 无 flock）；锁移 `$TMPDIR`；sed 写端正则放宽 |
| `using-neil-autopilot` / `README` / `conventions` | Track A 入口改指向 `run-track-a.sh`，明确"别用 LLM 当编排器" |
| `autopilot/knowledge/**` | raw + guide `track-a-launcher-pattern` + verify-by-running 补 flock/bash3.2 + SCHEMA C6/C10 |

## 4. fail-closed 契约

verify 失败 / REVIEW≠PASS / worker BLOCKED / commit 真失败 / 轮数耗尽 → 标 BLOCKED + `exit 2`，绝不误标 DONE、绝不静默 commit。编排器**自己**跑 verify，不信 worker 自报。

## 5. 验证

- token-free：`bash -n` 全绿；`smoke-run-track-a.sh` 三场景全 PASS（含 commit-fail fail-closed）。
- 真实 E2E：从 monitor 隔离分支真跑，impl(Performance)→verify→review(Ultimate) REVIEW_PASS→commit `1d41fb0`，`RUN_RC=0`，worker 真建 `track_a_probe.py`。**qodercli inner loop 确认触发**。自测产物已 teardown 清理。

## 6. subagent CR 修复

CRITICAL：commit 真失败被当"无变更"→误标 DONE（fail-open）→ 改为分辨 + fail-closed。MAJOR：`task_verify` 补 `|| true`、sed 写端放宽、锁移 TMPDIR。
