---
created: 2026-07-19
source: evolve/completed-change
evidence: primary
---

# 完成变更蒸馏：archive-date-hierarchy（归档四层分层 + 幂等迁移脚本 + dedup 前置超集证明）

> 源：`autopilot/archive/2026/07/07-19/2026-07-19-archive-date-hierarchy/`（spec.md / tasks.md / explore-notes.md）。
> 关联提交：d20cf19（Task1 archive-change.sh 四层）/ 75afce4（Task2 migrate 脚本+冒烟）/ 33862c0（Task3 文档+SCHEMA）/ 1408918（迁移5+归档8+dedup3）/ 2efbbf4（脚本自归档 dogfood）。

## Problem

`autopilot/archive/` 用扁平 `YYYY-MM-DD-<feature>/` 命名，随变更增多会一屏几十个、难按时间检索；同时 `changes/` 里堆积 11 个历史遗留（3 个旧 `cp` 只复制没删的废副本 + 8 个从未走 archive-change.sh 毕业的变更），`changes/` 只增不减、遗留知识未蒸馏。

## Solution

- **①分层** `scripts/archive-change.sh`：`TARGET` 从 `$ARCHIVE_DIR/${DATE_STR}-${CHANGE_NAME}` 改为 `$ARCHIVE_DIR/$Y/$M/$MMDD/${DATE_STR}-${CHANGE_NAME}`，即在**原样保留**的日期前缀叶子之上套 3 层 `年/月/月-日`。日期切分用 bash 3.2 安全参数展开（`Y=${D%%-*}` / `R=${D#*-}` / `M=${R%%-*}` / `DD=${R#*-}`），`mkdir -p "$(dirname "$TARGET")"` 建四层父目录。**所有既有不变量保持**：幂等 `[ -d "$TARGET" ]` 前置、XOR 后置校验、fail-closed、git mv 优先+mv 兜底+嵌套守卫、`git add "$TARGET"` 入库。
- **②迁移** 新增 `scripts/migrate-archive-layout.sh`：一次性把顶层残留扁平 `YYYY-MM-DD-<name>/` git mv 到四层。三件套——**幂等**（已在目标位/已是嵌套 `YYYY/` 结构则跳过）+ **fail-closed**（mv 兜底前 `[ -e TARGET ]` 守卫拒嵌套，任何 mv 失败 exit 1）+ **`--dry-run`**（只打印 `FROM -> TO` 不动文件）。配 `smoke-migrate-archive-layout.sh` token-free 冒烟（临时 git repo 植入扁平+已嵌套，断言迁移到位/嵌套跳过/再跑零变更/dry-run 不改盘）。
- **③数据操作由控制器跑已 CR 脚本**：迁移存量 5、按 git 真实日期归档遗留 8（`archive-change.sh --date <git-derived>`）、dedup 3 废副本，全部调**已通过 CR 的确定性脚本**，控制器不内联手改（铁律 C11）。
- **④dedup 前置超集证明**：删任何"重复"副本前先 `diff -rq` 证明保留侧（archive）是被删侧（changes/）的**超集**——本轮 3 个 changes/ 副本实测是 archive 的严格子集（archive 多一份 summary.md，changes-独有文件数=0），确认零信息损失后 `git rm`（可 `git restore` 回退）。

结果：archive 现共 13 个叶子变更、全部四层，`changes/` 清空。文档同步（using-neil-autopilot / autopilot-evolve SKILL、SCHEMA C13 改四层 + 新增 C15 登记 migrate 脚本、conventions.md）。

## 决策溯源（避免未来重议）

- **叶子保留完整日期前缀**（不改名，仅在其上套层）：迁移即纯 `git mv`、零改名、自描述、可幂等可回退；`MM-DD` 分组天然隔离跨天重名。被否的替代——把日期从叶子名剥离只靠父目录表达（会丢自描述性 + 迁移变改名，风险高）。
- **加深嵌套安全性已 grep 证明**：全仓仅 archive-change.sh / smoke / 2 个 SKILL / SCHEMA 引用旧扁平命名，**无任何代码按深度 glob archive**（`kb-search.sh` 只 grep wiki/ 不碰 archive），故加层只需同步 doc/smoke。
- **归档 8 个按 git 真实完成日期**（dual-track-rollout=07-11、observable-acceptance-gate=07-19、其余 6 个=07-12），不统一用今天、不臆造。
- **不 push、等用户确认**：控制器负责 push/merge，evolve 只知识沉淀。

## Lesson（可复用模式）

- **归档目录分层设计**：扁平 `DATE-name` 随规模膨胀难浏览；`YYYY/MM/MM-DD/` 三层按时间聚合。关键——叶子保留完整日期前缀（自描述 + 迁移零改名），仅在其上套层，迁移即纯 `git mv`、可幂等可回退。
- **存量迁移脚本三件套**：幂等（已在目标位/已嵌套则跳过）+ fail-closed（mv 兜底前 `[ -e TARGET ]` 拒嵌套）+ `--dry-run` 先验。一次性数据迁移必配 dry-run 与幂等，避免半迁移。
- **控制器跑已 CR 脚本做数据操作**：迁移/归档/dedup 均由控制器调用**已通过 CR 的确定性脚本**，而非内联手改（铁律 C11：控制器不写码；数据操作复用 worker 产出的脚本）。
- **dedup 前置超集证明**：删任何"重复"副本前先 `diff -rq` 证明保留侧是被删侧的**超集**（复核 独有文件数=0），git rm 保证可 `git restore`。零信息损失才动手。
