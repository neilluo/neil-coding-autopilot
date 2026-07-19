# Spec — 修复 README 悬空引用 + 补 REVIEW 三态表

> 变更类型：fix（README 内容缺陷）+ 流程再验证（第二轮 dogfooding）
> 执行档位：B（外层交互 + loop 经 run-track-a.sh 托管 qodercli）
> 分支：`fix/readme-review-table`（从 master 5990eb7 切出）
> 状态源：本文件 + TodoWrite

## 1. 背景与缺陷

上一轮 Track A 产出的 README 存在一处内容缺陷（我复核 + reviewer 未拦到的内部一致性问题）：

- README 第 68 行称"`review` 结果是三态（见下方「HARD-GATE 不变量」附近的 REVIEW 状态表）"，**但正文根本没有这张表**——悬空引用。
- 更实质：三态里最关键的 `INCOMPLETE`（未审文件 → 不得静默 PASS → loop 收到不得进 finish）**全篇 0 次提及**，"非常详细"名不副实。

## 2. 真实三态契约（取自 skills/autopilot-review/SKILL.md，worker 照此写表）

| 状态 | 含义 | loop 后果 |
|------|------|-----------|
| `REVIEW_PASS` | 全部文件已审，且只有 MINOR / 无问题 | 允许 commit |
| `REVIEW_FAIL` | 有 CRITICAL / MAJOR 问题 | 调度 fixer worker 修复后重审 |
| `REVIEW_INCOMPLETE` | 有文件未被审查（重试后仍未消解） | **不得静默 PASS、不得进 finish**；交控制器决定 |

## 3. 方案（增量编辑，不重写）

在 README「loop 内循环」段落合适位置补一张 **REVIEW 状态表**（上述三态），并把第 68 行的悬空引用改为指向这张真实的表（或就近内联）。其余章节保持不变。

## 4. 验证方法（tasks.md Verify，无 backtick）

```
grep -q INCOMPLETE README.md && grep -q REVIEW_PASS README.md && grep -q REVIEW_FAIL README.md && grep -q mermaid README.md && [ $(grep -c '^## ' README.md) -ge 10 ]
```

断言：三态（含此前缺失的 INCOMPLETE）均已记载、mermaid 图与章节数未回退。reviewer 另审内部引用一致性。控制器最终复核：悬空引用已消除。

## 5. 边界

- 只改 `README.md`（+ 变更目录留痕 + evolve）。不改 skills / scripts。
- 增量编辑，禁止把上一轮的高质量 README 推倒重写。
