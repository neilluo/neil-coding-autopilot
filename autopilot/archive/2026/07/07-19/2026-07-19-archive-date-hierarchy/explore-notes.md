# Explore Notes — archive-date-hierarchy

> 本 explore 通过控制器与用户多轮会话完成（已澄清模式）。以下沉淀现状调研、
> 根因结论、用户拍板的 4 个决策与设计方向确认（满足 HARD-GATE：用户已逐项确认方向）。

## 触发背景

用户看到项目里 `autopilot/changes/` 仍堆积 11 个文件夹、`archive/` 只有 5 个，且提出
三个问题 + 一个指令。控制器已用证据逐一回答：

1. **是否 push 到 master？** → 否。有 remote（github.com/neilluo/neil-coding-autopilot），
   但 `origin/master`=1e101ae，本地 master=a04a3ba，**17 个提交从未 push**。
2. **changes/ 为何没全归档？** → 11 个是历史遗留、早于 `archive-change.sh`：
   - 3 个**重复**（旧 `cp` 只复制没删原件）：self-evolution-hardening / agent-observability /
     telemetry-pluggable-sink。实测 `changes/` 副本是 archive 的**严格子集**（archive 多一份 summary.md），
     故 changes/ 副本是纯废件。
   - 8 个**从未归档**：delegate-dev-to-qodercli / dispatch-path-resolution / dual-track-rollout /
     harden-controller-write-gate / observable-acceptance-gate / readme-overhaul /
     readme-review-table / track-a-launcher。
3. **knowledge 全蒸馏完了吗？** → 否，部分。wiki 已有 8 guides + 2 entities + 1 concept，
   但上述 8 个"从未归档"的变更大多没走过 evolve。

## 用户拍板的 4 个决策（本次范围）

| # | 决策点 | 用户选择 |
|---|--------|---------|
| 1 | archive 目录结构 | **四层**：`archive/YYYY/MM/MM-DD/YYYY-MM-DD-<feature>/`。即在**原样保留**的日期前缀叶子文件夹之上，套 3 层 `年/月/月-日/`。例：`archive/2026/07/07-18/2026-07-18-self-evolution-hardening/` |
| 2 | 8 个从未归档的变更 | **方案 B：全部归档进 archive**，随后**重建知识库**；重建时**重叠内容用最新知识覆盖** |
| 3 | 存量 5 个扁平条目 | **迁移**到新四层结构，全仓统一 |
| 4 | push | 本轮做完、自检通过、报告给用户后，**等用户确认再 push** |

## 关键现状调研（决定实现安全性）

- **谁消费旧扁平命名**（grep 全仓）：仅 `archive-change.sh`(L107 TARGET 构造) /
  `smoke-archive-change.sh`(断言) / `autopilot-evolve` SKILL(L49 散文) /
  `using-neil-autopilot` SKILL(目录结构文档) / SCHEMA C7-C8(散文)。
  **无任何代码按深度 glob archive**（`kb-search.sh` 只 grep wi/ 不碰 archive），故加深嵌套**安全**，
  只需同步更新上述 doc/smoke 引用。
- **8 个变更的 git 最后提交日期**（用于精确归档，而非统一用今天）：
  dual-track-rollout=2026-07-11；observable-acceptance-gate=2026-07-19；其余 6 个=2026-07-12。
- **环境**：qodercli / jq / timeout / gtimeout 全部 FOUND；master 干净；3 冒烟 PASS。

## 设计方向确认

- 归档结构解析用 bash 3.2 安全的参数展开从 `YYYY-MM-DD` 切出 `YYYY / MM / MM-DD`，叶子名不变。
- 迁移与"归档 8 个"复用**已 CR 过的确定性脚本**跑数据操作（控制器不内联写码，铁律）。
- 3 个重复项：archive 已是超集，直接 `git rm` changes/ 废副本（零信息损失、git 可回退）。
- KB 重建：evolve worker 蒸馏新归档的变更，重叠概念以最新变更覆盖旧版。
