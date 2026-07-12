# Implementation Tasks — readme-review-table

> Verify command: `grep -q INCOMPLETE README.md && grep -q REVIEW_PASS README.md && grep -q REVIEW_FAIL README.md && grep -q mermaid README.md && [ $(grep -c '^## ' README.md) -ge 10 ]`
> Total tasks: 1

## Task 1: README 补 REVIEW 三态表并修复悬空引用（增量编辑）

**Files**: `README.md`（增量编辑，**不要重写**其它章节）
**Description**: 现有 `README.md` 的「loop 内循环」章节里有一句悬空引用需要修复，并补一张缺失的表。

第一步（先读，保证准确）：
- 读 `README.md`，定位「loop 内循环」章节中这句：`review` 结果是三态（见下方「HARD-GATE 不变量」附近的 REVIEW 状态表）——它引用了一张**正文并不存在**的表。
- 读 `skills/autopilot-review/SKILL.md`，确认 REVIEW 的真实三态契约（PASS / FAIL / INCOMPLETE 的判定条件与 loop 后果）。

第二步（增量修改，仅改这两处，其余章节一字不动）：
1. 在「loop 内循环」章节内（那句引用的就近下方，`git commit` 那段关键点附近）新增一张 **REVIEW 状态表**，Markdown 表格三行，准确对应源码契约：
   - `REVIEW_PASS`：全部文件已审、且只有 MINOR 或无问题 → 允许 commit。
   - `REVIEW_FAIL`：存在 CRITICAL / MAJOR 问题 → 调度 fixer worker 修复后重审。
   - `REVIEW_INCOMPLETE`：有文件未被审查（重试后仍未消解）→ **不得静默 PASS、不得进入 finish**，交由控制器决定（人工审 / 缩小 diff 再审 / 显式豁免）。核心原则：未经审查的变更不能静默通过。
2. 把那句悬空引用改成指向这张就在同段落里的表（例如"三态见下表"），去掉指向「HARD-GATE 不变量」的错误方位；确保读者能在正文真的找到这张表。

约束：中文；Markdown 表格语法正确；**只动 README.md 这一个文件**；不得删除或改写其它章节、mermaid 图、其它表格；改完自己跑一遍验证命令确认通过。

**Verify**: `grep -q INCOMPLETE README.md && grep -q REVIEW_PASS README.md && grep -q REVIEW_FAIL README.md && grep -q mermaid README.md && [ $(grep -c '^## ' README.md) -ge 10 ]`
**Status**: IN_PROGRESS

---
