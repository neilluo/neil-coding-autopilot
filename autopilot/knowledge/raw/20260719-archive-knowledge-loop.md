---
created: 2026-07-19
source: evolve/completed-change
evidence: primary
---

# 完成变更蒸馏：archive-knowledge-loop（changes→archive→knowledge 闭环 + 跨项目复利）

> 源：`autopilot/archive/2026-07-19-archive-knowledge-loop/`（spec.md / tasks.md / explore-notes.md）。

## Problem

`autopilot/archive/` 在代码层面**零功能作用**：归档是 `cp` 复制（原件永不清理、`changes/` 只增不减，铁证——三个文件夹同时存在于 changes/ 与 archive/），且 analyze/explore/evolve **无人读 archive**。归档只有"写路径"没有"读路径"，等于死存档。业界共识：归档的价值不在存储，在**被后续工作读回去**（Google "Where's the design doc?"；SRE "未复盘的 postmortem 等于没发生过"）。

## Solution

四个改动点闭环 `changes→archive→knowledge`，关键机制一律落成**确定性脚本 + token-free 冒烟**（非不可验证 prose，遵 C7/C10）：

- **①挪** `scripts/archive-change.sh`：`git mv`（非 git 降级 `mv`）+ 幂等（目标已存在→打印路径 exit 0）+ 缺 summary.md 生成骨架 + fail-closed（源目录不存在 / 搬迁后源仍在→exit 1）。finish Step 6 改为调它并硬门禁化（失败即 `FINISH_STATUS=BLOCKED`）。
- **②嚼** evolve Step 1 增第 5 类蒸馏源「完成变更」：读 archive 里该变更 spec/tasks/explore-notes → 提炼决策溯源 + 可复用模式 → raw→wiki。
- **③升** `scripts/kb-path.sh`：全局 KB 路径**单一事实源**（`$NEIL_AUTOPILOT_KB_DIR` env → 默认 `$HOME/.neil-autopilot/knowledge` → fail-closed，C8）；evolve 把跨项目通用经验升迁至全局 raw/。
- **④翻** `scripts/kb-search.sh`：grep 检索本地+全局 KB，fail-safe（无 KB/无命中→`(no prior-art hits)` exit 0，只读）；explore Step 1 / analyze Step 1b 开工前检索并记入 explore-notes.md「## 历史经验命中」。

依赖顺序：③(kb-path) → ①(archive) → ④(kb-search→explore/analyze) → ②(evolve 消费 ③)。

## 决策溯源（避免未来重议）

- **B 案被否再复活**：探测阶段 explore 直接 grep 原始 archive 塞进上下文 → 被业界调研否决（Claude memory / Reflexion / Kiro steering 一致主张"Agent 读蒸馏层，不读原始归档"）；用户澄清"不会出现 Context 问题"后，改为**经确定性检索器 + 蒸馏层**安全落地，而非裸塞原文。
- **C 案（archive 仅做门面）否决**：零功能作用正是现状病症。
- **跨项目联邦是独有红利**：用户点明"这个 plugin 是未来所有系统的基石"——归档缺陷会复制到每个项目，故必须做 ③升（全局 KB）。
- **scope out**：不做 embedding/向量检索（当前规模 grep 足够，留架构余地）；不回溯迁移 changes/ 历史草稿（只修正向管线）。

## Lesson（可复用模式）

- **归档要有"读路径"才有价值**：写进 archive 只是半程；必须蒸馏成可检索知识层 + 开工检索接线，否则等于没发生过。
- **Agent 读蒸馏层 + 确定性检索器输出，不裸塞原始归档**：控制 context、防幻觉、可跨项目复利。
- **关键机制脚本化 + token-free 冒烟 > 可读 prose**：archive/kb-path/kb-search 三者各配一个确定性扰动冒烟测试，可验证胜过"承诺清理原件"这类空头 prose。
- **路径解析单一事实源**：全局 KB 路径只由 `kb-path.sh` 解析（写侧 evolve / 读侧 kb-search 共用），env→默认→fail-closed，禁写死家目录/用户名（C8）。
- **不变量落成断言**：完成变更 ∈ archive **XOR** changes（见 C13），由 archive-change.sh 后置校验 + finish 双保险硬拦。
