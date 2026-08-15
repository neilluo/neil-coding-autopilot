# 规则库 E+F+G+H：效率 · 响应式 · 一致性 · 性能体感（32 条）

> 格式：**断言** → 检查 → 修法 → 来源。缩写同 `rules-ia-state-data.md`；新增 `WV`=web.dev（INP/Core Web Vitals）。

---

## E. 效率与专家路径（8）

### EF-01 · N · 提供常用时间范围预设 + 自定义
- 检查：看时间控件。修法：antd `RangePicker` + `presets`（最近 1h/24h/7d）。来源：GRAF、NN#7（Flexibility and Efficiency）。

### EF-02 · N · 筛选条件常驻可见
- 检查：截图。修法：抽屉外露 active filter chips，不隐藏在折叠面板。来源：NN#6（Recognition Rather than Recall）。

### EF-03 · N · 筛选可一键清空/重置
- 检查：找重置按钮。修法：加 Reset 到默认。来源：NN#3。

### EF-04 · P · ≥1 组键盘加速器且可发现
- 检查：试按（如 `/` 聚焦搜索、`r` 刷新）。修法：全局 hotkey + 帮助浮层/tooltip 标注。来源：NN#7、WIG。

### EF-05 · N · 同一流程内不重复要求已输入的信息
- 检查：走多步流程。修法：预填/可选择。来源：WCAG 3.3.7 Redundant Entry。

### EF-06 · N · 桌面端单一主输入框可 autofocus；移动端不 autofocus
- 检查：看 `autoFocus` 用法。修法：条件化。来源：WIG、jsx-a11y `no-autofocus`。

### EF-07 · P · 开关类控件立即生效，不需二次确认
- 检查：试 Switch。修法：去掉多余确认。来源：RI。

### EF-08 · N · 表格支持排序/筛选/列宽记忆，且状态进 URL
- 检查：试 + 刷新页面。修法：受控 + URL 同步。来源：NN#7、WIG。

---

## F. 响应式与布局（8）

### RS-01 · S · 320px 宽（=1280px@400%）下除数据表外无双向滚动
- 检查：缩放到 400% 截图。修法：栅格 `xs/sm/md` 断点。来源：WCAG 1.4.10 Reflow。

### RS-02 · N · 覆盖 mobile/laptop/ultra-wide 三档；超宽用 50% 缩放模拟
- 检查：三档截图矩阵。修法：`maxWidth` 容器防超宽拉伸。来源：WIG（"Responsive coverage"）。

### RS-03 · N · 用户覆写文本间距不丢内容
- 检查：注入 line-height 1.5em 等 CSS 后截图。修法：避免固定高度容器。来源：WCAG 1.4.12 Text Spacing。

### RS-04 · N · 无多余滚动条（横向溢出修根因）
- 检查：macOS 设置常显滚动条后截图。修法：修溢出源，不是 `overflow:hidden` 掩盖。来源：WIG（"No excessive scrollbars"）。

### RS-05 · N · 布局交给 flex/grid，不用 JS 测量
- 检查：grep render 里的 `getBoundingClientRect`。修法：改 CSS。来源：WIG（"Let the browser size things"）。

### RS-06 · N · 时序图 ≥1/3 屏宽、日志/长列表 ≥1/2 屏宽
- 检查：小屏截图看是否被压扁。修法：断点下改纵向堆叠。来源：DD（时序 ≥4/12 栏、流式 ≥6/12 栏）。

### RS-07 · N · 间距不歧义：元素与所属组的间距 < 与相邻组的间距
- 检查：量取相邻间距。修法：用间距标尺（token）归组。来源：RUI p83（"Avoid ambiguous spacing"）、AD Proximity。

### RS-08 · P · 全出血布局考虑 `env(safe-area-inset-*)`
- 检查：移动端截图。修法：加 safe-area padding。来源：WIG。

---

## G. 一致性与视觉体系（8）

### CS-01 · B · 无新增硬编码色值/字号/间距，一律引用现有 token
- 检查：grep `#[0-9a-fA-F]{3,8}`、组件里的 `px` 字面量。修法：加 token 或引用既有 token，不写局部值。来源：AD（Object-oriented/Modular）、RUI p60/p129。

### CS-02 · S · 同一语义全站同色同图标同措辞
- 检查：生成语义×呈现交叉表，看是否 1:1 无冲突。修法：抽 `StatusTag` 单一来源。来源：NN#4（Consistency and Standards）、AD Repetition。

### CS-03 · S · 三套主题都通过 A11Y-08/09/10
- 检查：三主题 × 全路由 axe。修法：改 token 层。来源：WCAG + 多主题项目现状。

### CS-04 · N · 深色主题 `color-scheme: dark` + `<meta theme-color>` 与背景一致
- 检查：查 DOM。修法：补上。来源：WIG（"`color-scheme: dark`"、"`<meta name=theme-color>`"）。

### CS-05 · N · hover/active/focus 对比度高于静态态
- 检查：三态截图取色。修法：调 token。来源：WIG（"Interactions increase contrast"）。

### CS-06 · N · 层级靠弱化次要实现（值主导、标签弱化）
- 检查：看指标卡标签是否与值同权重。修法：标签降级（小号/次级色）。来源：RUI p39（"De-emphasize to emphasize"）/ p41（"Labels are a last resort"）。

### CS-07 · P · 子圆角 ≤ 父圆角且同心；阴影 ≥2 层且方向一致
- 检查：视觉检查。修法：用 token 统一。来源：WIG（"Nested radii"、"Layered shadows"）、RUI p150/p163。

### CS-08 · P · 少用边框，优先用间距/背景色分隔
- 检查：数边框数量。修法：删冗余 border。来源：RUI p206（"Use fewer borders"）。

---

## H. 性能与交互体感（8）

> INP 阈值（web.dev，field 数据 75 分位）：**≤ 200ms good / 200–500ms needs improvement / > 500ms poor**。一次 interaction 延迟 = 该手势事件处理器组中最长的单个处理器时长（input delay + handler + presentation delay）。

### PF-01 · S · 关键交互 INP ≤ 200ms（>500ms 视为 P0）
- 检查：Playwright + web-vitals 采集；DevTools CPU 4x 节流。修法：拆长任务、移出主线程。来源：WV。

### PF-02 · S · 长列表（>50 行）虚拟化或 `content-visibility: auto`
- 检查：看 Table `pagination`/虚拟化配置。修法：antd 虚拟表或分页。来源：WIG（command.md 明确 >50 items）。

### PF-03 · N · 动画只动 `transform`/`opacity`；禁止 `transition: all`
- 检查：grep `transition:\s*all`。修法：显式列属性。来源：WIG、RI。

### PF-04 · S · 尊重 `prefers-reduced-motion`
- 检查：系统开减少动效后截图/录屏。修法：媒体查询关动画。来源：WIG、WCAG 2.3 相关。

### PF-05 · N · 交互类动画时长 ≤ 200ms 且可被输入打断
- 检查：计时。修法：调 duration、Interruptible。来源：RI、WIG。

### PF-06 · N · 写操作 P95 < 500ms，否则须乐观更新或进度反馈
- 检查：看后端日志/前端计时。修法：乐观更新 + 失败回滚。来源：WIG（"latency budgets: POST/PATCH/DELETE < 500ms"）。

### PF-07 · N · 无图片导致的 CLS；图表容器预留高度
- 检查：Lighthouse CLS。修法：显式宽高 / 固定容器高度。来源：WIG。

### PF-08 · P · 频繁刷新的图表复用实例
- 检查：看 echarts-for-react/`setOption` 用法。修法：复用 instance，谨慎 `notMerge`。来源：WIG（"Track re-renders"）。
