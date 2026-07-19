---
created: 2026-07-19
source: evolve/observable-acceptance-gate
evidence: primary
---

# 可观测验收门：用 autopilot 自身给 autopilot 补「验收=不变量/蜕变关系」

## Problem

一个真实逃逸驱动本次改造：被 autopilot 开发的项目里，配置页卡片显示「1 个模型」、用户实际配了 2 个。根因不是实现难，而是**验收口径错**——spec 把显示写成**实现口径**（"数 `tpm_by_model` 的 key 个数"，即数"这一分钟实际有数据的模型"），而非**用户可观测的承诺**（"用户配 N 个 → 卡片显示 N 个"），且从没问一句"当『配置的集合』≠『实测的集合』时以谁为准"。

这是 **test oracle problem**（Liu 2014 / Segura 综述）：作者把实现当期望值写进验收，下游每道门（unit test 断言、CR 照 diff 核 spec）都**信 spec**、把 bug 又确认一遍——全绿。白盒门天然抓不住"oracle 本身就是错的"。autopilot 原有 explore/analyze/plan 的产出 schema 全是 HOW（方案/边界/决策），**没有一格是"用户应看到什么"**。

## Solution

给 autopilot 加一道**可观测验收门**（`feature/observable-acceptance-gate`，FF 合并 181005d）：

- **验收 = 不变量 + 蜕变关系（metamorphic relation）**，不写"期望等于几"的点 oracle。作者无法把 bug 编码进不变量：测试**独立扰动**配置与实测子集（固定配置=2、实测 2 有数据→1→0），断言"显示数恒=2"——buggy 实现（数实测）必违反 → 抓住。SSOT（单一事实源）+ 判别样例（多源值给"两源期望不同"的例子）是格式要件。
- **载重路径蹭现有 verify 门**：扰动测试即该 Task 的 `**Verify**`，`run-track-a.sh` 现成 `eval "$verify"` 在无人值守直接拦，不新增控制流。
- **headless reviewer 上牙**：`build_review_prompt` 增一条「可观测验收」审查维度（读 spec 验收段 + `_shared/observable-acceptance.md`，交叉核验 Verify↔MR、UNVERIFIED 免除正当性）；`CHANGE_DIR` 绝对化使 review worker（cwd=$CWD）读得到 spec。
- **落点**：新增 `skills/_shared/observable-acceptance.md`（SSOT）；`using-neil` HARD-GATE #7 + explore/analyze/plan 引用它。

## Lesson

- **验收要写"对用户的承诺"，不是"代码怎么算"**：spec 里出现"数 X 的 key/长度"这类实现口径 = 埋雷；改写成 Given-When-Then 的不变量 + 判别样例（GitHub spec-kit / Example Mapping 均以此为地基）。
- **点 oracle 治不了 oracle problem，不变量/蜕变关系才行**：作者会把 bug 写进点期望，却写不进"扰动下不变"的关系。
- **headless 拦截有天花板、要诚实**：只有**可离线派生层**（如后端计数逻辑）能被扰动测试真正拦；纯像素渲染 / 选错 SSOT 类缺陷 headless 拦不住 → 显式 `UNVERIFIED-OBSERVABLE` 登记转 **Phase 2**（观测/独立 QA 层），禁静默放行。
- **元方法论有效 + 过程教训**：用 autopilot 自身的 spec→多 qodercli 对抗式 review 循环→收敛 改 autopilot 本体（7 轮 × 3 视角 ≈ 20 审，逐轮把 CRITICAL 喂回）。我曾在 90%<95% 抢先应用——是"信心门"把我拉回：补齐 headless 牙 + 用**植入违规实测 reviewer 真输出 `REVIEW_FAIL`**（行为证据）后，95% 才有据。**evidence before assertion**——正是这道门要教会 autopilot 的事。
