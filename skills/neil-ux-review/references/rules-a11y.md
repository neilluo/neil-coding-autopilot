# 规则库 D：无障碍 a11y（16 条 + WCAG 2.2 AA 条款 + APG 模式）

> 背景事实（已核实）：WCAG 2.2 于 2023-10-05 成为 W3C Recommendation，相比 2.1 新增 9 条，4.1.1 Parsing 已废弃移除。
> 来源缩写：`WCAG x.x.x`（w3.org/TR/WCAG22）、`APG`（w3.org/WAI/ARIA/apg）、`WIG`/`RI`/`RUI`/`AD` 同前。
> **对比度类（A11Y-08/09）必须在真实浏览器测**：axe-core 的 `color-contrast` 规则在 JSDOM 下不工作（官方 README 明确）。

---

### A11Y-01 · B · 全部功能纯键盘可完成
- 检查：Playwright 只用 Tab/Enter/Esc/方向键走完主任务流。
- 修法：用原生 `button`/`a`；自定义交互补键盘 handler。
- 来源：WCAG 2.1.1 Keyboard（A）。

### A11Y-02 · B · 无键盘陷阱（焦点可移入必可移出）
- 检查：Modal/Drawer/自定义下拉内反复 Tab。
- 修法：焦点管理按 APG Dialog。
- 来源：WCAG 2.1.2 No Keyboard Trap（A）、APG Dialog。

### A11Y-03 · B · 每个可聚焦元素有可见焦点环；无裸 `outline: none`
- 检查：grep `outline:\s*none`/`outline-none`；键盘遍历截图。
- 修法：用 `:focus-visible` + token 化 ring（优于 `:focus`，不干扰鼠标点击）。
- 来源：WCAG 2.4.7 Focus Visible（AA）、WIG、RI。

### A11Y-04 · S · 焦点顺序与视觉顺序一致
- 检查：录制 Tab 序号叠加截图（**人工判定"合理性"**，机器只能测"可聚焦"）。
- 修法：调 DOM 顺序而非 `tabIndex` 正值。
- 来源：WCAG 2.4.3 Focus Order（A）。

### A11Y-05 · S · 获焦元素不被 sticky header / 悬浮告警条完全遮挡
- 检查：小视口下 Tab 到底部元素截图（**人工/截图判定**）。
- 修法：`scroll-margin` / 减少 sticky 高度。
- 来源：**WCAG 2.4.11 Focus Not Obscured (Minimum)**（AA，2.2 新增）。

### A11Y-06 · S · 点击目标 ≥ 24×24 CSS px 或满足间距豁免
- 检查：量取表格行内图标按钮、图例点、分页数字（**间距豁免需几何判定，人工**）。
- 修法：扩 padding（视觉可保持小，热区扩大）。
- 来源：**WCAG 2.5.8 Target Size (Minimum)**（AA，2.2 新增）、WIG（"Match visual & hit targets"）。

### A11Y-07 · S · 任何拖拽交互都有非拖拽替代
- 检查：找图表框选缩放/时间轴刷选/拖拽排序。
- 修法：提供起止时间输入框、上下移按钮等单指针替代。
- 来源：**WCAG 2.5.7 Dragging Movements**（AA，2.2 新增）。

### A11Y-08 · B · 文本对比度 ≥ 4.5:1（大字 ≥ 3:1），三套主题分别达标
- 检查：真实浏览器跑 axe（JSDOM 不支持）；次要灰字是最常见失败点。
- 修法：调 token 值，不逐处硬改。
- 来源：WCAG 1.4.3 Contrast (Minimum)（AA）。失效组件/纯装饰/logo 豁免。

### A11Y-09 · S · UI 组件/状态/图表关键图形对比度 ≥ 3:1
- 检查：axe（Non-text Contrast）+ 人工看图表线色/input 边框/focus ring/开关轨道。
- 修法：换色盲友好调色板。
- 来源：WCAG 1.4.11 Non-text Contrast（AA）、WIG（"Accessible charts"）、RUI p146。

### A11Y-10 · B · 状态不只用颜色表达（告警三态 = 色 + 图标 + 文字）
- 检查：灰度化截图后能否分辨。
- 修法：Tag/Badge 带图标与文案，不只靠颜色区分。
- 来源：WCAG 1.4.1 Use of Color（A，"color … not the only visual means"）、WIG（"Redundant status cues"）、RUI p146。

### A11Y-11 · S · 图标-only 按钮有 `aria-label`；装饰图标 `aria-hidden="true"`
- 检查：ESLint（jsx-a11y）+ axe。
- 修法：补 `aria-label`；纯装饰图标加 `aria-hidden`。
- 来源：WIG（"Icons have labels"）、jsx-a11y。

### A11Y-12 · S · 原生语义优先（button/a/label/table），ARIA 是兜底
- 检查：jsx-a11y `no-static-element-interactions`、`click-events-have-key-events`。
- 修法：换标签；不用 `<div onClick>`。
- 来源：WIG（"Semantics before ARIA"）、jsx-a11y。

### A11Y-13 · S · 标题层级不跳级、唯一 `<h1>`；提供 skip link
- 检查：axe `heading-order` + 人工。
- 修法：用真 heading，不用加粗 div。
- 来源：WCAG 1.3.1 / 2.4.6、WIG。

### A11Y-14 · S · Tabs 符合 APG
- 检查：键盘测 + DOM 审。
- 修法：优先用 antd `Tabs`（内建），不自造。要件见下「APG Tabs」。
- 来源：APG Tabs Pattern。

### A11Y-15 · S · Modal 符合 APG
- 检查：键盘测。
- 修法：用 antd `Modal` 默认行为，勿覆盖 `keyboard={false}`。要件见下「APG Dialog」。
- 来源：APG Dialog (Modal) Pattern。

### A11Y-16 · N · hover/focus 浮层满足三要件；tooltip 内不放交互元素
- 检查：Esc 测（Dismissible）、鼠标移入测（Hoverable）、等待测（Persistent 不自动消失）。
- 修法：ECharts tooltip 设 `enterable`；需交互的内容改用 Popover。
- 来源：**WCAG 1.4.13 Content on Hover or Focus**（AA，三要件 Dismissible/Hoverable/Persistent）、AD、RI。

---

## APG 模式速查（实现自定义交互时对照）

### APG Tabs（antd Tabs 已内建，自造时必须满足）
- 角色：容器 `tablist`、项 `tab`、面板 `tabpanel`；`tab` 用 `aria-controls` 指向面板，`tabpanel` 用 `aria-labelledby` 回指。
- 状态：当前 `aria-selected="true"`，其余显式 `false`；垂直时 `aria-orientation="vertical"`。
- 键盘：Tab 进入落在 active tab（roving tabindex）；左右箭头在 tab 间循环移动；Space/Enter 手动激活；**水平 tablist 不监听上下箭头**（留给页面滚动）。
- 建议：面板内容无明显延迟时推荐自动激活（需预加载）；面板无可聚焦内容时 `tabpanel` 设 `tabindex="0"`。

### APG Dialog (Modal)（antd Modal 已内建）
- 外部内容 `inert`；Tab/Shift+Tab **不得移出**对话框；**Escape 关闭**；打开时焦点移入内部；关闭时焦点归还触发元素；`tabindex > 0` strongly discouraged。

### APG Alert
- `role="alert"`，**不影响键盘焦点**（Keyboard Interaction: Not applicable）。
- **避免设计会自动消失的 alert**；频繁打断使满足 WCAG 2.2.4 更难。需打断工作流时改用 Alert Dialog。
- 屏幕阅读器不会播报页面加载前就已存在的 alert → 首屏告警需挂载后再置入 live region。

### Table vs Grid
- 只读数据表 → `table` 语义（不做方向键导航）；需方向键/单元格编辑 → `grid`/`treegrid`。
- **不要在 antd `Table` 上硬加 `role="grid"` 却不实现键盘导航。**

## ARIA live region 对照表

| 值 | 行为 | 用于 |
|---|---|---|
| `aria-live="polite"` | 下一个停顿时播报 | 状态更新、保存确认、刷新完成 |
| `aria-live="assertive"` | 立即播报 | 错误、时效性告警 |
| `role="status"` | 等价 polite | 状态消息 |
| `role="alert"` | 等价 assertive | 错误消息 |

## 其它 WCAG 2.2 相关条款（作为加分/延伸检查）
- 1.4.10 Reflow（AA）：320 CSS px 宽不产生双向滚动；**data tables 属"需二维布局"例外**（宽表允许横滚）。
- 1.4.12 Text Spacing（AA）：用户覆写 line-height 1.5em / 段距 2em / 字距 0.12em / 词距 0.16em 时不丢内容。
- 2.2.1 Timing Adjustable（A）：时限可关/可调/可延长。
- 3.3.7 Redundant Entry（A，2.2 新增）：同流程内已输入信息须自动填充或可选择。
- 3.3.8 Accessible Authentication (Min)（AA，2.2 新增）：认证步骤允许粘贴/密码管理器，不强制认知测试。
- 4.1.2 Name, Role, Value（A）：自定义组件须暴露名称/角色/值/状态。
- 2.4.13 Focus Appearance（AAA，加分项）：焦点指示器面积 ≥ 未聚焦组件 2 CSS px 周长面积。
