# Spec — archive-knowledge-loop

> 让 `changes → archive → knowledge` 主管线真正闭环并可跨项目复利。
> 把归档从"死存档"变成"喂未来开发的活知识"。关键机制一律落成确定性脚本 + token-free 冒烟测试。

## 1. 概述 + 用户故事

**问题**: 当前 `autopilot/archive/` 在代码层面零功能作用——归档是 `cp` 复制（原件永不清理，changes/ 只增不减），且 analyze/explore/evolve 无人读 archive。归档没有"读路径"。

**用户故事**:
- 作为使用本 plugin 开发**任何**系统的人，当我完成一个功能时，系统应把它**真正搬进** archive（不再两处并存），并**蒸馏**其决策/模式进知识库。
- 当我在**任何**项目开发新功能时，系统应在开工前**检索**本项目 + 全局历史经验，让我"站在旧功能的肩膀上"，不重蹈覆辙、不重议已定方案。

## 2. 系统架构

```
                          ┌───────────────── 本地 KB (autopilot/knowledge/) ──────────────┐
 explore/analyze ──④翻──► kb-search.sh ─┤ raw/  wiki/  SCHEMA.md                          │
      │  (开工检索命中记入 explore-notes)  └───────────────────────────────────────────────┘
      ▼                                   ▲                         ▲
    plan → loop                           │②嚼(蒸馏)                │③升(通用经验)
      ▼                                   │                         ▼
    finish ──①挪──► archive-change.sh    │            全局 KB (~/.neil-autopilot/knowledge/)
      │   git mv changes/X→archive/DATE-X │                 ▲ 经 kb-path.sh 解析路径
      ▼                                   │                 │
    evolve ───────────────────────────────┴─────────────────┘  (读完成变更 → 写本地 + 通用升全局)
```

四个改动点（①挪 ②嚼 ③升 ④翻），彼此依赖顺序：③(kb-path) → ①(archive) → ④(kb-search→explore/analyze) → ②(evolve 消费 ③) → SCHEMA 登记。

## 3. 数据模型 / 持久化

无数据库。持久化即文件系统：
- 本地 KB: `autopilot/knowledge/{raw,wiki}/`（已存在）。
- 全局 KB: `$NEIL_AUTOPILOT_KB_DIR`（默认 `$HOME/.neil-autopilot/knowledge/`），结构镜像本地（`raw/` + `wiki/`），跨项目累积。
- 归档: `autopilot/archive/YYYY-MM-DD-<feature>/`（spec.md + tasks.md + explore-notes.md + summary.md）。

## 4. 接口设计（3 个新增内部脚本 CLI）

### 4.1 `scripts/kb-path.sh`（③ 全局 KB 路径解析——单一事实源）
```
kb-path.sh [--ensure]
  stdout: 解析后的全局 KB 绝对路径
  解析优先级(C8): $NEIL_AUTOPILOT_KB_DIR (env) → 默认 $HOME/.neil-autopilot/knowledge
  --ensure: 目录不存在则 mkdir -p（含 raw/ wiki/）；成功 exit 0
  不写死用户名/家目录字面量；$HOME 不可用时 fail-closed(exit 1, stderr)
```

### 4.2 `scripts/archive-change.sh`（① 归档搬迁——确定性 + 幂等 + fail-closed）
```
archive-change.sh --change-dir DIR [--archive-dir DIR] [--date YYYY-MM-DD]
  行为: 若已在 archive（幂等）→ 打印现有路径, exit 0
        否则 git mv <change-dir> <archive-dir>/<DATE>-<name>（非 git 仓库降级 mv）
        若缺 summary.md → 生成骨架
  fail-closed: change-dir 不存在 → exit 1；搬迁后源目录仍在 → exit 1
  不变量: 完成后该变更在 archive XOR changes（绝不两处并存）
```

### 4.3 `scripts/kb-search.sh`（④ 检索器——grep 本地+全局，fail-safe）
```
kb-search.sh --query "kw1 kw2..." [--cwd DIR] [--limit N]
  行为: 在 本地 autopilot/knowledge/{raw,wiki} + 全局(kb-path.sh) 内 grep 关键词
        输出命中: [LOCAL|GLOBAL] 相对路径 : 匹配行摘要
  fail-safe: 无 KB / 无命中 → 打印 "(no prior-art hits)" 且 exit 0（绝不因空而失败）
  只读；不修改任何 KB
```

## 5. 各改动点的具体落地

- **③ kb-path.sh + 约定**: 新增脚本 + 冒烟；`skills/_shared/conventions.md` 增「全局 KB 路径」段（$GLOBAL_KB_DIR/解析规则）；`AGENTS.md` 环境变量表加 `NEIL_AUTOPILOT_KB_DIR`（默认 `$HOME/.neil-autopilot/knowledge`）。
- **① finish**: `skills/autopilot-finish/SKILL.md` Step 6 用 `scripts/archive-change.sh` 替换 `cp` 手法；调用失败或搬迁后源目录仍在 → `FINISH_STATUS=BLOCKED`；显式写明「XOR 不变量」。
- **④ explore/analyze**: explore Step 1 增「历史经验检索」——调 `kb-search.sh` 以需求关键词检索，命中写入 explore-notes.md 的「## 历史经验命中」段（无命中写"无命中"）；analyze Step 1b 增读本地+全局 KB 命中并纳入 Spec 约束。
- **② evolve**: `skills/autopilot-evolve/SKILL.md` Step 1 增第 5 类蒸馏源「完成变更」（读 archive 中该变更 spec/tasks/explore-notes → 提炼决策溯源 + 可复用模式 → raw→wiki）；新增一步：通用经验经 `kb-path.sh --ensure` 升迁写入全局 KB（无源不写、inferred≤30% 沿用现有门禁）。
- **SCHEMA 登记**: `autopilot/knowledge/SCHEMA.md` 增两条约束（见 §8）。

## 6. 部署方案

纯文件改动，随插件分发。新脚本 `chmod +x`。无需迁移。全局 KB 首次 evolve 时按需生长（grow-on-demand，C3）。

## 7. 里程碑 / Phase

单 Phase（6 个原子 Task，见 tasks.md）。全部离线可验证（token-free 冒烟 + grep 断言），无 UNVERIFIED-OBSERVABLE 项。

## 8. 可观测验收（Observable Acceptance）

> 本特性的用户可观测输出 = **文件系统状态迁移** + **脚本 stdout** + **explore-notes.md 段落**。全部离线可派生 → Phase 1。

| # | 可观测值/态 | SSOT | 不变量 | 蜕变关系（判别性，含空/部分/打架） |
|---|------------|------|--------|-----------------------------------|
| O1 | 变更归档位置 | 文件系统 | 完成变更 ∈ archive **XOR** changes（绝不两处并存/皆无） | 移动 X 后：archive/DATE-X 存在 且 changes/X 消失；**再跑一次**(幂等)→ exit 0 不报错、状态不变；移动 X 不影响 Y；change-dir 不存在→**exit 1**（判别：静默成功=BUG） |
| O2 | 全局 KB 路径 | `kb-path.sh` stdout | env 覆盖 > 默认；默认必为 `$HOME/.neil-autopilot/knowledge` | 设 `NEIL_AUTOPILOT_KB_DIR=/tmp/x`→输出 `/tmp/x`（判别：仍输出默认=BUG）；未设→输出含 `.neil-autopilot`；`--ensure` 后目录存在 |
| O3 | KB 检索命中 | `kb-search.sh` stdout | 同时覆盖 LOCAL + GLOBAL；空/无 KB→exit 0（fail-safe） | 全局 KB 放一条含 "widget" 的条目 + query "widget"→输出含 `[GLOBAL]` 该条（判别：漏 GLOBAL=BUG）；query 无关词→"(no prior-art hits)" 且 exit 0（判别：exit≠0=BUG） |
| O4 | evolve 蒸馏产物 | `raw/` 新文件 frontmatter `source` | 完成变更→本地 raw/ 生成 1 条溯源该变更的记录 | evolve 后本地 raw/ 出现引用该 change 的条目；通用经验→全局 KB 也出现（部分态：仅本地无全局=允许，纯项目特定经验） |
| O5 | explore 历史命中段 | `explore-notes.md` | 必含「历史经验命中」段（有命中列条目，无命中写"无命中"） | 存在相关全局经验→段内列出；无→显式"无命中"（判别：缺段=BUG） |

**Verify 落地**: O1→`smoke-archive-change.sh`；O2→`smoke-kb-path.sh`；O3→`smoke-kb-search.sh`（三者均为确定性扰动测试，即对应 Task 的 `**Verify**`）；O4/O5 为 SKILL 文档改动，Verify 用 ASCII 脚本名 grep 断言接线 + CR 核验蒸馏/检索接入质量。

## 9. 约束遵循

- C6/C8: 新脚本 bash 3.2 安全、`pwd -P` 自定位、无 GNU 工具硬依赖（`git mv` 缺 git 降级 `mv`）、路径解析 env→默认→fail-closed。
- C7: 每个关键机制（archive/kb-path/kb-search）配 token-free 冒烟测试。
- C10: 归档/检索是确定性脚本，非 LLM 编排。
- C11: 本 spec 由控制器产出（.md 产物）；实现（脚本 + SKILL 编辑）全部经 run-track-a.sh 托管 worker。
