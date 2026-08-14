---
name: neil-ux-review
description: 审查并改进 Web 前端（React + Ant Design 数据监控看板类应用）的交互与易用性。当用户提到 UX 审查 / 交互审查 / 易用性 / 可用性 / 无障碍 / a11y / 看板不好用 / 界面难懂 / 交互体验 / heuristic evaluation / WCAG / 键盘可达 / 对比度 / 焦点 / 空状态 / 加载态 / 错误提示，或要求"评审这个页面/组件的体验""给出 UI 改进方案并落地"时使用。不用于纯视觉美化诉求（走设计类 skill）与纯代码风格 lint。
metadata:
  author: neil
  version: "1.0.0"
  argument-hint: <path-or-url> [--fix]
---

# neil-ux-review — 资深 UI 交互专家的审查与改进体系

对 Web 前端做**可判定、可排序、可验证**的交互与易用性审查，并可选地落地修复。规则库 88 条（12 条阻断级），跨 7 组，每条带「断言 / 检查 / 修法 / 来源」。

**宣告**："正在使用 neil-ux-review 执行 UX 审查。"

## 定位与差异化

本机通常已装 Vercel 的 `web-design-guidelines`（只覆盖"通用静态层"：CSS/浏览器细节 + 可 grep 反模式）。**本 skill 复用它、不重写**，差异化在四层它不管的东西：

| 维度 | web-design-guidelines | neil-ux-review |
|---|---|---|
| 规则来源 | 单层（Vercel `command.md`） | 五层：Vercel 通用层（**远程复用**）+ WCAG 2.2 AA 条款 + APG 模式 + 看板领域（Grafana/Datadog/antd）+ 技术栈（antd 5 / ECharts 5） |
| 数据正确性 | 不涉及 | **一等公民红线**：缺数 ≠ 0、口径不可变、精度不可丢 |
| 验证 | 只读代码 | 代码 + 运行时（axe/ESLint/Lighthouse + Playwright 键盘遍历与截图矩阵） |
| 输出 | 扁平 `file:line` | 分级 findings（Nielsen 0–4）+ ROI 排序 + 逐条可验证改法 + 回归断言 |

## 触发时机

1. 用户显式要求审查/改进交互易用性、无障碍。
2. 用户描述**症状**（"看不懂"/"点不到"/"不知道刷没刷新"/"告警没感觉"）——最该召回，因为用户不会说"UX 审查"。
3. `autopilot-review` 检测到 diff 命中前端路径。
4. 新增页面/组件的 PR 前置门禁。

**不触发**：纯后端改动、依赖升级、"只想配色更好看"（转设计 skill）。

## 核心工作流（8 阶段，先建事实 → 再打分 → 再排序 → 最后动手）

每阶段产物落盘到 `<change-dir>/ux/`，可断点续跑。

| 阶段 | 输入 | 动作 | 产物 | 门禁 |
|---|---|---|---|---|
| **P0 Inventory** | 源码 + 路由表 | 枚举页面/组件、每组件状态矩阵(loading/empty/error/partial/dense)、交互清单、数据字段与口径、主题变体、现有 token。**只记录不评判** | `ux/inventory.md` | 组件覆盖 100%；未入清单者后续不得改 |
| **P1 Static sweep** | inventory + 源码 | ① 远程拉 Vercel `command.md` 当通用层；② `eslint-plugin-jsx-a11y`；③ `scripts/sweep-static.sh` grep 反模式 | `ux/sweep-static.json` | 记录规则源版本/抓取时间 |
| **P2 Runtime probe**（不可省） | 已启动前端 | ① `axe-core` 逐路由扫(含对比度)；② 纯键盘遍历录焦点序+截图；③ 3 主题×3 视口截图矩阵；④ 故障注入(空/null/超长/断网)；⑤ 采 INP/CLS | `ux/probe/*.png` + `ux/sweep-runtime.json` | **视觉/状态类结论无截图即标 `unverified`** |
| **P3 Heuristic scoring** | P0–P2 | 按 7 组规则逐条判 `pass/fail/n-a/unverified`，每条 fail 给 Nielsen 严重度 0–4；三视角复评（新手运维/熟练 SRE/纯键盘+读屏）取均值 | `ux/findings.json` | 禁止无 rule_id 的 finding（反幻觉） |
| **P4 Findings ledger** | findings.json | 归并同因；分级 P0阻断/P1严重(mean≥3)/P2一般/P3打磨 | `ux/report.md` | P0 置顶 + blast radius |
| **P5 ROI 排序** | ledger | `priority = mean_severity × reach ÷ cost`(cost=S/M/L)；产出批次(每批≤5 条且同组件) | `ux/plan.md` | 单批禁跨 3+ 文件 |
| **P6 可验证改法**（`--fix`） | plan.md | 逐条改：改动前后截图、原子提交(msg 带 rule_id)、**只用现有 token 与现有依赖** | diff + `ux/before-after/*.png` | 触碰格式化/聚合 → 先写回归测试 |
| **P7 回归与复审** | diff | ① 新增 vitest 断言(格式化/缺数/告警三态)；② 重跑 P1+P2；③ 列出已关闭 + 新引入 finding | `ux/verify.md` | **未重跑 P2 不得声称修好** |

> 只审不改：跑 P0–P5 即可（`--fix` 缺省关闭）。接入 `autopilot` 流程时，P5 的 `plan.md` 即 loop 的 `tasks.md` 输入。

## 规则库（88 条 / 7 组，按需加载 `references/`）

先读 `references/rule-index.md`（ID→组→等级→一句话断言），据 finding 命中范围再加载对应分组：

| 组 | 文件 | 内容 |
|---|---|---|
| A 信息架构·导航 / B 状态·反馈 / C 数据可读性·**正确性** | `references/rules-ia-state-data.md` | 40 条（C 组是差异化核心，含 antd data-format 全表 + Grafana/Datadog 条目） |
| D 无障碍 | `references/rules-a11y.md` | 16 条（WCAG 2.2 AA 条款号原文 + APG Tabs/Dialog/Alert 键盘表 + live-region 表） |
| E 效率 / F 响应式 / G 一致性 / H 性能体感 | `references/rules-eff-resp-cons-perf.md` | 32 条 |

## 红线区（必须遵守，不靠按需加载）

AI 做 UI 改进最容易翻车的地方，每条都有机制化防御（详见 `references/report-templates.md` 反模式表）：

1. **数据正确性优先于视觉**：缺失/null **绝不**渲染成 `0`（表格 `-`、无数据 `--`、图表断点不连线）；不改聚合口径/时区；不丢精度。触碰任何 formatter/聚合 → **先写 vitest 回归断言**。
2. **不推翻已有设计体系**：不新增硬编码色值/字号/间距，一律引用现有 token；不引入第二套色阶。
3. **不引入新运行时依赖**：`git diff package.json` 出现新 `dependencies` 即失败（devDependencies 工具链需人类批准）；不把 antd 组件替换成自造组件。
4. **无 rule_id 的"美化"直接拒绝**（AI Slop 检测）：每处改动必须绑定一条规则。
5. **原生语义优先于 ARIA**：不给 `<div>` 加 `role="button"` 而不换标签；不在只读 `Table` 上硬加 `role="grid"` 却不实现键盘导航。
6. **不伪造规则/条款号**：规则库每条带来源；条款号必须与 references 原文一致。
7. **无验证不得声称修好**：未重跑 P2、无截图的视觉/状态结论一律标 `unverified`（axe 官方自认自动化仅覆盖 ~57% WCAG 问题）。
8. **中文控制台禁用英文品牌文案规则**：Vercel Copywriting 段（Title Case / `&` / 弯引号）不适用，走 antd 中文文案规范。

## 通用静态层复用（P1 用）

```
WebFetch https://raw.githubusercontent.com/vercel-labs/web-interface-guidelines/main/command.md
```
把它当"通用静态层规则包"直接套用，**仅排除**：整个 Copywriting 段（英文品牌规则）与 "APCA 优于 WCAG2" 一条（需合规证据时反以 WCAG 2.x 为准）。上游更新自动继承，本 skill 不维护重复内容。

## 输出格式

继承 Vercel 的 terse 风格 + 本 skill 分级：每条 finding 一行 `[等级][rule_id] file:line — 现状 → 修法（附证据/截图路径）`；通过项标 `✓`；无把握项标 `unverified`。报告落 `ux/report.md`，模板见 `references/report-templates.md`。**无 preamble，除非修法不显然否则不解释。**

## 自动化钩子与技术栈修法

- 命令清单 / CI 接入 / 各工具能力与盲区（JSDOM 测不了对比度、axe 57% 覆盖、必须人工的 10 项）：`references/report-templates.md` 的自动化节 + `assets/` 下配置。
- 本技术栈（antd 5 / ECharts 5）逐组件修法：`references/antd5-echarts-playbook.md`。
- 可直接落地的资产：`assets/eslint.jsx-a11y.config.mjs`、`assets/a11y.spec.ts`(Playwright)、`assets/lighthouserc.cjs`、`assets/axe-vitest.setup.ts`、`assets/fault-injection.ts`；`scripts/sweep-static.sh`、`scripts/probe-runtime.sh`。

## 状态报告

结束时输出：`UX_REVIEW_STATUS=DONE | BLOCKED|{原因} | SKIPPED`（接入 autopilot 时供控制器路由）。
