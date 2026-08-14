# 产物模板 · 自动化钩子 · 反模式

> P0–P7 各阶段落盘产物的模板、可自动化命令清单、以及 AI 做 UI 改进最易翻车的 12 类反模式（每条带机制化防御）。

## 一、产物模板

### P0 `ux/inventory.md`
```md
# UX Inventory — <项目>
## 路由/页面
| 路由 | 组件 | 一句话职责 |
## 组件状态矩阵
| 组件 | loading | empty | error | partial | dense |
|------|---------|-------|-------|---------|-------|
| Xxx  | ✓/✗     | ...   | ...   | ...     | ...   |
## 交互清单
| 组件 | 交互 | 触发方式(click/hover/键盘/拖拽) | 是否键盘可达 |
## 数据字段与口径
| 字段 | 含义 | 聚合口径 | 时区 | 缺数如何呈现 |
## 主题与 token
现有主题：...；token 文件：...
```

### P3 `ux/findings.json`（每条 finding 的 schema）
```json
{
  "rule_id": "A11Y-11",
  "level": "S",
  "location": "src/App.tsx:220-234",
  "evidence": "icon-only Button 无 aria-label",
  "screenshot": "ux/probe/keyboard-focus-header.png",
  "severity": { "novice_ops": 3, "sre": 2, "screen_reader": 4, "mean": 3.0 },
  "state": "fail",
  "fix": "补 aria-label='手动刷新'"
}
```
> `state ∈ pass|fail|n-a|unverified`；视觉/状态类无 `screenshot` 一律 `unverified`。

### P4 `ux/report.md`（人读，terse）
```md
# UX Review — <项目> @<日期>
## P0 阻断（置顶 + blast radius）
- [B][DT-01] src/utils/format.ts:12 — null→0 让缺数伪装成真 0 → 区分 null 给 '-'（影响所有指标卡/图表）
## P1 严重（mean≥3）
- [S][A11Y-11] src/App.tsx:220 — icon 按钮无 aria-label → 补 aria-label
## P2 一般 / P3 打磨
...
## ✓ 通过 / unverified（需人工）
```

### P5 `ux/plan.md`（= autopilot loop 的 tasks.md 输入）
按批次，每批 ≤5 条且同组件；`priority = mean_severity × reach ÷ cost(S/M/L)`。

### P7 `ux/verify.md`
```md
## 回归断言（新增 vitest）
- fmtNum(null) === '-' ✓
- 告警三态映射 3 用例 ✓
## 重跑 P1+P2 结果
- ESLint jsx-a11y: 0 error
- axe(3主题×3视口): 0 violation（对比度真实浏览器）
## 关闭的 finding / 新引入的 finding
```

## 二、自动化钩子（哪些能 CI 自动跑 / 哪些必须人工）

### 能完全自动（进 CI）
```bash
# ① 静态 a11y（见 assets/eslint.jsx-a11y.config.mjs）
npx eslint "src/**/*.{ts,tsx}" --max-warnings 0
# ② 反模式 grep（零依赖，见 scripts/sweep-static.sh）
bash scripts/sweep-static.sh <web-src-dir>
# ③ 运行时 a11y + 截图矩阵（唯一能测对比度，见 assets/a11y.spec.ts）
npx playwright test a11y.spec.ts
# ④ Lighthouse 门禁（见 assets/lighthouserc.cjs）
lhci autorun
```

### 工具能力与已知盲区（诚实度铁律）
- **axe-core 官方自认自动化平均只覆盖 ~57% 的 WCAG 问题**，其余返回 `incomplete` 要人工复核 → 任何"a11y 已全绿"的声称都要被拒绝。
- **axe 的 `color-contrast` 规则在 JSDOM 下不工作** → 对比度断言只能放 Playwright 层，vitest 层不要假装测过。
- `vitest-axe` 停更（npm 0.1.0 / 4 年未发版）→ 用 `assets/axe-vitest.setup.ts` 直接调 `axe-core`，且记住上条限制。
- vitest 层更适合测**数据正确性回归**（`fmtNum(null)==='-'`、聚合口径、跨零点/时区），而非对比度。

### 必须人工/截图（写死，禁 agent 声称自动通过）
1. 焦点顺序是否符合**语义**（2.4.3，机器只测"可聚焦"不测"合理"）
2. 焦点被 sticky 遮挡（2.4.11）
3. 24px 目标的**间距豁免**判定（2.5.8）
4. 拖拽替代是否存在（2.5.7）
5. 浮层三要件（1.4.13）
6. **缺数是否被渲染成 0**（DT-01，mock null 看图）
7. 颜色是否唯一手段（1.4.1，灰度截图法）
8. 信息架构/模块优先级/文案"下一步"
9. 三主题视觉一致性
10. 跨零点/跨时区口径（DT-09）

## 三、反模式（12 类 · 每条带机制化防御）

| # | 反模式 | 表现 | 防御机制 |
|---|--------|------|----------|
| 1 | 改视觉，破坏数据正确性 | 把缺数 `-` 改 `0`；顺手 `?? 0`；改 formatter 丢精度/改聚合/改时区 | DT-01/02/03 阻断级；触碰 formatter/聚合先写 vitest；`rg "\?\?\s*0|\|\|\s*0"` 进 CI |
| 2 | 推翻已有设计体系 | 无视 token 写 `#1677ff`/`padding:13px`；引第二套色阶 | CS-01 阻断级 + `rg "#[0-9a-fA-F]{3,8}"` 门禁；只允许新增/引用 token |
| 3 | 引入新依赖 | `npm i tailwind/framer-motion/shadcn/react-icons`；antd 组件换自造 | 红线：依赖清单锁定；`git diff package.json` 新 dependencies 即失败 |
| 4 | AI Slop（更炫但更难用） | 加毛玻璃/渐变/入场动画；清晰表格换花哨图；值与标签同权重 | 每处改动绑一个 rule_id；无 rule_id 的美化直接拒；配 RUI p39/p41 |
| 5 | 用 ARIA 覆盖原生语义 | `Table` 硬加 `role="grid"` 不实现键盘导航；`<div role=button>`；可聚焦元素加 `aria-hidden` | A11Y-12 + jsx-a11y `no-noninteractive-element-to-interactive-role`/`no-aria-hidden-on-focusable`；APG |
| 6 | 幻觉规则/伪造条款号 | 编造 "WCAG 2.5.9"；AAA 说成 AA；不存在的 axe 规则名 | 规则库每条带 source；P3 禁止不在 rule-index 的 rule_id；条款号须与 references 一致 |
| 7 | 声称修好但没验证 | 改完直接说"符合 AA"；不重跑 axe；不截图 | P7 门禁：未重跑 P2 不得关 finding；无截图的视觉/状态结论标 `unverified` |
| 8 | 英文品牌文案套中文控制台 | Title Case、"和"→`&`、中文加弯引号、强推 `10 MB` 空格 | 规则包排除 Copywriting 段；中文走 antd 文案 |
| 9 | 一次改太多 | 一个 commit 改 10 个组件/顺手改后端 DTO | P5 限单批 ≤5 条且同组件；P6 一 finding 一原子提交 |
| 10 | 只测 happy path | 只在有数据/快网/默认主题/1440px 看一眼 | P2 强制矩阵：3 主题×3 视口×5 数据态（正常/空/null/超长/失败） |
| 11 | 误删"看起来没用"的东西 | 删 `aria-label`/live region/`sr-only`/冗余状态文字 | A11Y-10/11 阻断级；P6 diff 审查：删 `aria-*`/`role`/隐藏文本需附理由 |
| 12 | 可用性/性能问题混淆 | 用户说"卡"其实缺加载态；说"看不懂"却去优化 bundle | P0 先建事实、P3 才归因；INP 硬阈值（200/500ms）区分真假卡顿 |

## 四、Nielsen 严重度评分（P3 用）
`severity = frequency × impact × persistence`；量表 `0 不是问题 / 1 Cosmetic / 2 Minor / 3 Major / 4 Catastrophe`。
NN/g 元规则：**单评估者严重度不可靠，三评估者均值足够**→ 本 skill 用三视角（新手运维 / 熟练 SRE / 纯键盘+读屏）取均值。
