---
created: 2026-07-12
source: evolve/dogfood-taskflow-e2e
evidence: primary
---

# Dogfooding 全链路（TaskFlow 新建 + 迭代两次）发现的 plugin 问题与修复

真机跑：用本 plugin 从零建 TaskFlow（Python CLI），再迭代两次（priority、due dates），
开发全程经 `run-track-a.sh` 托管真实 qodercli worker（Performance 实现 / Ultimate 审查）。
结果：3 轮全绿，main 干净历史，39 tests OK。过程中暴露 4 个问题：

## F1 — Write 工具落盘有延迟（工具侧，非 plugin）
- 现象：控制器 `Write` 刚返回成功，磁盘文件可能仍为空；紧接着的 `cp` 会拷到 0 字节。
- 影响：run-track-a.sh 读到空 tasks.md → 正确 fail-closed 报 “no '## Task N:' entries”。
- 缓解：控制器写完关键文件后，**先 `wc -c` 校验落盘再消费**。

## F2 — run-track-a.sh 空 tasks.md fail-closed（**正向**，非缺陷）
- 空/缺 tasks.md 时明确报错并 exit 1，不静默跑空。保持。

## F3 — 新项目缺 .gitignore，`git add -A` 卷入编译产物（已由 CR 兜底）
- 现象：新项目无 `.gitignore`，逐 Task `git add -A` 把 `__pycache__/*.pyc` 提交进历史。
- 兜底：Ultimate reviewer 在 Task 2 以 MAJOR 拦下并触发 fixer 补了 `.gitignore`（CR 闭环生效）。
- 建议（未做）：`autopilot-init` 为新项目按语言脚手架 `.gitignore`，把问题前移到 init。

## F3b — 运行期哨兵 `autopilot/.run-active` 被提交（已修）
- 现象：`git add -A` 把瞬时哨兵提交进业务项目历史（一直 tracked 直到人工清理）。
- 修复：`skills/using-neil-autopilot/SKILL.md` 初始化流程创建哨兵后，幂等
  `grep -qxF ... || printf ... >> .gitignore`，确保哨兵永不入库。

## F4 — 最后一个 Task 的 DONE 状态未提交，导致 finish 切分支失败（已修）
- 现象：`run-track-a.sh` 先 `git commit` 再 `task-state DONE`，故**最后一个 Task 的
  `Status: DONE` 停留在未提交状态**；finish 的 `git checkout <base>` 报
  “local changes would be overwritten by checkout” 而中止（committed 历史里最后一个
  Task 还停在 IN_PROGRESS，可追溯性也受损）。
- 修复：`scripts/run-track-a.sh` 把 `task-state DONE` **移到 `git add -A` 之前**，
  使 DONE 状态随该 Task 的 commit 一起入库；commit 失败仍覆盖为 BLOCKED（fail-closed 不变）。
- 验证：`smoke-run-track-a.sh` 仍 ALL PASS；iter2 跑完 `git status --porcelain` 为空，
  `checkout main` 顺利，可追溯性恢复。

## Lesson
- CR（Ultimate）能真抓 MAJOR 并驱动 fixer 闭环——审查门是有效的。
- 但“新项目卫生（.gitignore 脚手架）”和“状态提交时序（DONE 先于 commit）”这类
  结构性问题应在 init / 编排器里前移解决，而不是每次靠 CR 兜底。
