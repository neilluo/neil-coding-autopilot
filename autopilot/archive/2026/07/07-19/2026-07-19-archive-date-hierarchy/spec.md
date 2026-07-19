# Spec — archive-date-hierarchy

> 把 `autopilot/archive/` 从扁平 `YYYY-MM-DD-<feature>/` 重构为四层
> `YYYY/MM/MM-DD/YYYY-MM-DD-<feature>/`；迁移存量 5 条、归档遗留 8 个、清理 3 个重复；
> 随后重建知识库（重叠用最新覆盖）。关键机制一律确定性脚本 + token-free 冒烟测试。

## 1. 概述 + 用户故事

**问题**: (a) archive 扁平命名随变更增多会一屏几十个，看着别扭、难按时间检索；
(b) 11 个历史 change 从未毕业到 archive（3 废副本 + 8 未归档），`changes/` 只增不减；
(c) 遗留变更的知识未蒸馏完整。

**用户故事**:
- 作为维护者，我希望 archive 按 `年/月/月-日/` 三层组织，同月同日的变更聚在一起，一眼可按时间浏览。
- 我希望历史遗留变更被正确毕业到 archive（按其真实完成日期），`changes/` 只留真正在做的。
- 我希望遗留变更的经验被蒸馏进知识库，重叠概念以最新为准。

## 2. 目标结构（用户拍板）

```
autopilot/archive/
└── 2026/                                  # YYYY 年
    └── 07/                                # MM 月
        ├── 07-18/                         # MM-DD 月-日
        │   └── 2026-07-18-self-evolution-hardening/   # 叶子：原全名不变
        │       ├── spec.md  tasks.md  explore-notes.md  summary.md
        └── 07-19/
            └── 2026-07-19-agent-observability/
```

- 叶子文件夹名**保持** `YYYY-MM-DD-<feature>`（不改），仅在其上新增 3 层 `YYYY/MM/MM-DD/`。
- 日期切分（bash 3.2 安全）：`Y=${D%%-*}` → `2026`；`R=${D#*-}` → `07-19`；`M=${R%%-*}` → `07`；
  `DD=${R#*-}` → `19`；`MMDD="$M-$DD"` → `07-19`。

## 3. 系统架构（数据流）

```
                    ┌─── 开发（worker 托管，铁律）───┐
  archive-change.sh (改 TARGET 为四层)  ← Task 1
  migrate-archive-layout.sh (扁平→四层, 幂等)  ← Task 2
  docs/SCHEMA/smoke 同步  ← Task 3
                    └───────────────┬───────────────┘
                                    ▼ 脚本 CR 通过后
                    ┌─── 数据操作（控制器跑已验证脚本）───┐
  migrate-archive-layout.sh → 迁移存量 5 条
  archive-change.sh --date <git日期> → 归档 8 个遗留
  git rm changes/<3 dup> → 清废副本（archive 已超集）
                    └───────────────┬───────────────┘
                                    ▼
  evolve worker → 蒸馏新归档变更进 KB（重叠用最新覆盖）
```

## 4. 接口设计

### 4.1 `archive-change.sh`（改造，非新增）
- 唯一改动：`TARGET` 从 `$ARCHIVE_DIR/${DATE_STR}-${CHANGE_NAME}`
  改为 `$ARCHIVE_DIR/$YEAR/$MONTH/$MMDD/${DATE_STR}-${CHANGE_NAME}`；
  `mkdir -p "$ARCHIVE_DIR"` 改 `mkdir -p "$(dirname "$TARGET")"`。
- **所有既有不变量保持**：幂等（`[ -d "$TARGET" ]` 前置）、XOR、fail-closed、
  git mv 优先 + mv 兜底 + 嵌套守卫、summary skeleton、`git add "$TARGET"` 入库。

### 4.2 `migrate-archive-layout.sh`（新增）
- 用法：`migrate-archive-layout.sh [--archive-dir DIR] [--dry-run]`。
- 默认 `--archive-dir` = `<脚本 pwd 推导>/autopilot/archive`（或必填，见实现约定）。
- 行为：仅扫描 archive **顶层**、匹配 `^YYYY-MM-DD-*` 的**扁平**目录（已嵌套的 `YYYY/` 跳过），
  对每个 git mv 到 `YYYY/MM/MM-DD/<原名>`。幂等（已在目标位置则跳过）、fail-closed、支持 `--dry-run`。

### 4.3 数据操作（控制器，跑已验证脚本，非新代码）
- 迁移 5：`bash scripts/migrate-archive-layout.sh`
- 归档 8：逐个 `bash scripts/archive-change.sh --change-dir autopilot/changes/<name> --date <git-derived>`
- 清 3 dup：`git rm -r autopilot/changes/{self-evolution-hardening,agent-observability,telemetry-pluggable-sink}`

## 5. 影响的既有文件（doc 同步，Task 3）
- `skills/autopilot-evolve/SKILL.md` L49：archive 路径散文改嵌套描述。
- `skills/using-neil-autopilot/SKILL.md`：目录结构块 `archive/YYYY-MM-DD-<feature>/` → 四层。
- `autopilot/knowledge/SCHEMA.md`：C7/C8 归档命名不变量更新为四层；如需新增 C 条目登记迁移脚本。
- `skills/_shared/conventions.md`：`$ARCHIVE_DIR` 行补注新结构（根目录不变，故可选）。

## 6. 边界 / 非目标
- **不**改 `changes/` 结构、**不**改 `kb-search.sh`（不消费 archive）。
- **不** push（等用户确认）。
- 归档 8 个按 git 真实日期，不臆造。

## 7. 风险 + 缓解
- **迁移中断致半迁移** → migrate 脚本幂等 + fail-closed + `--dry-run` 先验；git mv 保历史、可回退。
- **叶子重名跨天** → 叶子含完整日期前缀，`MM-DD` 分组天然隔离，无碰撞。
- **误删非重复** → 清理仅限 3 个已证 archive 为超集的 dup；git rm 可 `git restore`。

## 8. 可观测验收（每项都有确定性扰动测试 = 该 Task 的 Verify）

- **O1 archive-change.sh 四层落点**（SSOT=脚本 TARGET 构造；不变量：move 后
  `archive/YYYY/MM/MM-DD/YYYY-MM-DD-<name>/` 存在 XOR `changes/<name>` 存在；
  蜕变：换 `--date` 落点随之变）→ `smoke-archive-change.sh` 断言嵌套路径。
- **O2 迁移幂等 + 完整**（SSOT=migrate 脚本；不变量：跑完后 archive 顶层无残留扁平 `YYYY-MM-DD-*`，
  全部落到 `YYYY/MM/MM-DD/`；再跑一次零变更=幂等）→ `smoke-migrate-archive-layout.sh`。
- **O3 XOR 全局**（不变量：任一变更名在 archive XOR changes，绝不并存/两缺）→ 数据操作后控制器断言。
- **O4 文档一致**（不变量：evolve/using SKILL + SCHEMA 不再出现旧扁平 `archive/YYYY-MM-DD-<feature>`
  作为**当前**结构描述）→ Task 3 grep 断言。
- 全局回归：`for f in scripts/*.sh; do bash -n "$f"; done` + 全量冒烟全绿。
