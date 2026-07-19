---
updated: 2026-07-19
category: guides
evidence: primary
sources: [raw/20260719-archive-knowledge-loop.md]
---

# 指南：archive→knowledge 反哺闭环（让归档变成"喂未来开发的活知识"）

**适用**：任何"完成物 → 归档 → 供未来复用"的管线设计（归档 / postmortem / 决策记录 / 经验库），尤其分发型工具要跨项目复利时。

## 核心原则

- **归档要有"读路径"才有价值**：写进 archive 只是半程。业界共识——归档的价值不在存储，在**被后续工作读回去**（Google "Where's the design doc?"；SRE "未复盘的 postmortem 等于没发生过"）。只写不读 = 死存档 = 零功能作用。
- **Agent 读蒸馏层 + 确定性检索器输出，不裸塞原始归档进上下文**：主流 agent memory 设计一致（Claude memory / Reflexion / Kiro steering）。裸塞原文烧 context、放大幻觉、无法跨项目复利。

## 本项目的四点闭环（①挪 ②嚼 ③升 ④翻）

```
explore/analyze ──④翻──► kb-search.sh(本地+全局 grep, fail-safe) ─► 本地 KB(raw/wiki)
     │  (开工检索命中记入 explore-notes.md「## 历史经验命中」)     ▲②嚼  ▲③升
     ▼                                                            │      ▼
   plan→loop→finish ──①挪──► archive-change.sh(git mv, XOR)   evolve  全局 KB(kb-path.sh)
     │                                                           │      ▲
     └── evolve 读完成变更 → 蒸馏本地 raw→wiki → 通用者升全局 ────┘──────┘
```

- **①挪** `scripts/archive-change.sh`：`git mv`（非 git 降级 `mv`）+ 幂等 + 缺 summary.md 生成骨架 + fail-closed。finish Step 6 调它并硬门禁化（失败即 BLOCKED）。不变量：完成变更 ∈ archive **XOR** changes（C13）。
- **②嚼** evolve Step 1 第 5 类蒸馏源「完成变更」：读 archive 里 spec/tasks/explore-notes → 决策溯源 + 可复用模式 → raw→wiki。
- **③升** `scripts/kb-path.sh`：全局 KB 路径**单一事实源**（env `$NEIL_AUTOPILOT_KB_DIR` → 默认 `$HOME/.neil-autopilot/knowledge` → fail-closed，C8）；evolve 把跨项目通用经验升迁至全局 raw/。
- **④翻** `scripts/kb-search.sh`：grep 本地+全局 KB，fail-safe（无 KB/无命中→`(no prior-art hits)` exit 0，只读）。explore Step 1 / analyze Step 1b 开工前检索。

## 设计决策（避免重议）

- **不裸 grep 原始 archive 塞上下文**（B 案）：改经确定性检索器 + 蒸馏层安全落地。
- **关键机制脚本化 + token-free 冒烟 > 可读 prose**：archive/kb-path/kb-search 各配确定性扰动冒烟，可验证胜过"承诺清理原件"的空头 prose。
- **路径解析单一事实源**：全局 KB 路径只由 `kb-path.sh` 解析（写侧 evolve / 读侧 kb-search 共用）。
- **不做 embedding/向量检索**：当前规模 grep 足够，留架构余地；不回溯迁移历史草稿。

## 相关

- 源自 `raw/20260719-archive-knowledge-loop.md`
- 约束见 `SCHEMA.md` C13（归档毕业不变量）/ C14（archive→knowledge 反哺闭环）
- 脚本坑点见 [[verify-by-running]]（pipefail+head SIGPIPE / 生成文件入库）
