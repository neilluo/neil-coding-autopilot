---
created: 2026-07-12
source: evolve/dogfood-trackA-unattended
evidence: primary
---

# 纯无人值守 Track A 端到端验证（headless analyze+plan+loop）通过

继 TaskFlow（Track B，控制器在会话内写 spec/tasks）之后，又做了一次**纯无人值守
Track A**：新建项目 `wordstat`（Python stdlib CLI：行/词/字符数 + Top-5 高频词），
**从一句话需求出发，控制器不撰写任何 spec/tasks/代码**，全部经 dispatch.sh 托管
真实 qodercli worker 完成。

## 链路与结果
1. headless **analyze**（`dispatch.sh --model Ultimate` + autopilot-analyze skill）
   → 产出 `spec.md`（103 行，含 skill 规定的 3 轮自检）。
2. headless **plan**（autopilot-plan skill）→ 产出 `tasks.md`（2 Task），
   **格式与 run-track-a.sh 解析器兼容**（`**Verify**: \`cmd\` exit 0` + `**Status**`），
   `--dry-run` 解析 tasks=2 通过。
3. **loop**（`run-track-a.sh`）→ 两 Task 均 verify OK + REVIEW_PASS + 逐 Task commit。
4. **finish** → `git checkout main` 顺利（F4 修复生效，无 dirty-tree 中止）+ 合并。
5. 独立复验：**41 tests OK**；`wordstat` 功能冒烟正确（Top-5 + 大小写/标点归一）。
6. main 历史干净：**无 `*.pyc` / `autopilot/.run-active` 入库**（F3/F3b 生效）。

## Lesson
- autopilot-analyze / autopilot-plan **可作为 headless worker 经 dispatch.sh 独立运行**，
  且 plan 产出的 tasks.md 与 run-track-a.sh 解析器兼容——纯无人值守 Track A 通路成立。
- 上一轮修的 F3（init 脚手架 .gitignore）/ F3b（哨兵 gitignore）/ F4（DONE 先于 commit）
  在本轮**全部成立、未复发**，未发现新 bug。
- 结论校准：**「一句话需求 → 合并、可运行、带测试的代码」的全无人值守通路已真机验证可用**；
  仍未硬化的软约束（Bash 重定向绕过写码门、跳阶段纪律）不在本轮范围。
