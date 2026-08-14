# 规则库 A+B+C：信息架构 · 状态反馈 · 数据正确性（40 条）

> 每条格式：**断言** → 检查（如何判定）→ 修法（一句话）→ 来源。
> 来源缩写：`WIG`=vercel-labs/web-interface-guidelines、`RI`=rauno/interfaces、`NN`=Nielsen 10 Heuristics、`RUI`=Refactoring UI（带页码）、`AD`=Ant Design 规范、`GRAF`=Grafana best practices、`DD`=Datadog。

---

## A. 信息架构与导航（10）

### IA-01 · S · 每页能一句话回答"它回答什么问题"
- 检查：读页面组件头注释/description；写不出即 fail。
- 修法：页面顶部加一行 subtitle 或 Card description。
- 来源：GRAF（"A dashboard should tell a story or answer a question"）、DD。

### IA-02 · S · 单屏独立信息模块数 ∈ [1, 9]
- 检查：首屏截图数卡片/图表/表格块。
- 修法：拆页或折叠次要模块（Collapse）。
- 来源：AD（"Limit the sum of modules to 5-9 to avoid information overload"）。

### IA-03 · S · 最重要的指标/scorecard 在首屏上部
- 检查：截图看视觉顺序 vs 业务优先级表。
- 修法：重排 Row/Col 顺序。
- 来源：AD（"Put the most important charts and key scorecards on the top"）、GRAF。

### IA-04 · N · 一卡一主题；强关联数据同卡内用分隔线分区
- 检查：逐卡列出承载指标数与语义。
- 修法：拆卡或加 Divider。
- 来源：AD（"One card, one topic"）。

### IA-05 · S · 有总览→明细的显式 drill-down 且路径可逆
- 检查：点每个指标看是否可下钻；下钻后返回筛选是否保留。
- 修法：下钻用 `<Link>` + URL 携带筛选。
- 来源：GRAF（hierarchical dashboards）、NN#3（User Control and Freedom）。

### IA-06 · S · 全部可分享状态在 URL 中
- 检查：grep `useState`，逐个判断是否属可分享状态；复制 URL 到新窗口验证。
- 修法：`useSearchParams`/hash 同步；antd Tabs 的 `activeKey` 受控于 URL。
- 来源：WIG（"Deep-link everything … anytime `useState` is used"）。

### IA-07 · N · 浏览器前进/后退与滚动位置恢复正常
- 检查：后退键测试。
- 修法：用路由而非局部状态切页。
- 来源：WIG（"Scroll positions persist"）。

### IA-08 · N · `<title>` 反映当前上下文
- 检查：切页看 tab 标题。
- 修法：每路由设置 document.title（含页面名 + 关键筛选）。
- 来源：WIG（"Accurate page titles"）。

### IA-09 · N · 任何页面都不是死路
- 检查：遍历所有终态（空/错/无权限）截图。
- 修法：Result/Empty 组件配主 CTA。
- 来源：WIG（"No dead ends"）、NN#3。

### IA-10 · P · 帮助/联系入口在所有页面相对位置一致
- 检查：多页对比位置。
- 修法：固定放全局 header。
- 来源：WCAG 3.2.6 Consistent Help。

---

## B. 状态与反馈（14）

### SF-01 · B · 每个数据单元有 4 种独立可达态：loading/empty/error/partial
- 检查：用 mock 强制各态截图；找 `data && <Chart/>` 一把梭的写法。
- 修法：组件内建四分支，禁止只处理 happy path。
- 来源：WIG（"All states designed: empty / sparse / dense / error"）、AD。

### SF-02 · S · 加载用 Skeleton（镜像最终内容）而非全屏 spinner
- 检查：截图对比骨架与实际布局是否位移（CLS）。
- 修法：antd `Skeleton` 按最终结构定制。
- 来源：AD（"Use Skeleton screen when loading data"）、WIG（"Stable skeletons"）。

### SF-03 · N · spinner 有延迟显示 + 最短可见时长（防闪烁）
- 检查：快网下反复触发看是否闪烁。
- 修法：加 ~150–300ms delay + ~300–500ms minimum-duration 包装 hook。
- 来源：WIG（"Minimum loading-state duration"）。

### SF-04 · S · 操作 >2s 必须有加载态；耗时长的还须能取消
- 检查：节流网络到 slow 3G 逐个操作计时。
- 修法：`AbortController` + 取消按钮。
- 来源：AD（">2s 提示、"a cancel operation should be provided""）。

### SF-05 · S · 每个数据块显示"数据时间"与"是否陈旧"
- 检查：断网后截图，旧数据是否被标注。
- 修法：加 `更新于 HH:mm:ss` + stale 徽标。
- 来源：NN#1（Visibility of System Status）、DD（give context）。

### SF-06 · B · 自动刷新可暂停或可调频率
- 检查：找刷新控件；无则 fail。
- 修法：加暂停按钮 + 间隔下拉。
- 来源：**WCAG 2.2.2 Pause, Stop, Hide**（auto-updating 信息必须可暂停/停止/隐藏或控频）、GRAF（"Avoid unnecessary dashboard refreshing"）。

### SF-07 · S · 异步完成/失败通过 `role="status"`/`aria-live="polite"` 播报
- 检查：读 DOM 是否存在 live region。
- 修法：全局挂一个 polite live region，刷新完成/失败写入。
- 来源：**WCAG 4.1.3 Status Messages**、WIG（"Announce async updates"）。

### SF-08 · S · 重要失败不用 3s 自动消失的 message，用 Modal/Alert 常驻
- 检查：枚举所有 `message.error` 调用点，判断严重度。
- 修法：关键失败改 `Modal.error` 或页内 Alert。
- 来源：AD（"Lightweight prompts are not recommended for important failure messages"，message 默认 3s）。

### SF-09 · S · 错误文案 = 现象 + 原因 + 下一步动作
- 检查：抓取所有 error 文案逐条评审"下一步"是否存在。
- 修法：套模板 "X 失败：<原因>。请<动作>。"，不裸露堆栈/错误码。
- 来源：NN#9（Help Users Recognize/Diagnose/Recover）、WIG（"Error messages guide the exit"）。

### SF-10 · N · 校验错误就近显示且不自动消失；提交时聚焦首个错误
- 检查：提交空表单看焦点落点。
- 修法：antd `Form` + `scrollToFirstError`。
- 来源：AD（Input feedback）、WIG。

### SF-11 · N · 破坏性/不可逆操作有二次确认或 Undo
- 检查：枚举所有写操作。
- 修法：Popconfirm（轻）/ Modal.confirm（重）。
- 来源：NN#5（Error Prevention）、WIG（"Confirm destructive actions"）。

### SF-12 · N · 提交按钮不预 disabled；提交后才 disabled + spinner，label 不变
- 检查：点击时截图。
- 修法：用 `loading` 属性而非替换文案。
- 来源：WIG（"Don't pre-disable submit"）。

### SF-13 · P · 加载/进行中文案以省略号 `…` 结尾（不用 `...`）
- 检查：grep `\.\.\.`。
- 修法：替换为单字符 `…`。
- 来源：WIG、RI（"Ellipsis for further input & loading states"）。

### SF-14 · N · 反馈不过量：结果立刻可见的简单操作不弹 toast
- 检查：数一次典型操作触发的 toast 数。
- 修法：删除冗余 message。
- 来源：AD（"Avoid excessive feedback"）。

---

## C. 数据可读性与正确性（16 · 本 skill 差异化核心）

> **DT-01/02/03 是阻断级红线**：监控看板的数据错误比丑更致命。任何触碰 formatter/聚合/时区的改动，P6 必须先写 vitest 回归断言（见 `report-templates.md`）。

### DT-01 · B · 缺失/null 绝不渲染为 `0`
- 检查：grep `?? 0`、`\|\| 0`、`Number(x)||0`；mock null 后截图。
- 修法：格式化层区分 `null/undefined` 与 `0`；表格单元格用 `-`、无数据状态用 `--`；ECharts 传 `null` 且不设 `connectNulls`（缺口不连线）。
- 来源：**AD**（表格空用 `-`、无数据状态 `--`）、**GRAF**（No value 默认显示 `-`；Connect null values 默认 Never）。

### DT-02 · B · 聚合口径不因 UI 改动而变
- 检查：改动前后对同一时间窗跑数值断言（求和/均值/去重/时区）。
- 修法：任何 formatter/聚合改动先写 vitest 快照锁定。
- 来源：监控看板红线（数据正确性 > 视觉）。

### DT-03 · B · 数值精度不因显示格式丢失
- 检查：对比原始值与展示值。
- 修法：展示可截断，导出用原值（展示与导出分离）。
- 来源：监控看板红线。

### DT-04 · S · 表格中数值列右对齐
- 检查：截图检查。
- 修法：列配置 `align: 'right'`。
- 来源：AD（"numbers right-aligned … facilitates comparison"）。

### DT-05 · S · 用于比较的数字用等宽 `font-variant-numeric: tabular-nums`
- 检查：查 CSS；截图看数字是否跳动。
- 修法：给数值 class 加该属性。
- 来源：WIG、RI（"Tabular numbers for comparisons"）。

### DT-06 · S · 大数字有千分位；单位与数字规范且全站统一
- 检查：grep 是否统一用 `Intl.NumberFormat`/`toLocaleString` 或统一 formatter。
- 修法：抽一个统一 formatter，禁止硬编码格式串。
- 来源：AD（data-format）、WIG（禁硬编码格式，用 `Intl.*`）。

### DT-07 · S · 绝对时间 `YYYY-MM-DD HH:mm:ss`；区间用 ` ~ `（前后空格）
- 检查：grep dayjs format 串是否一致。
- 修法：统一时间格式常量。
- 来源：AD（"YYYY-MM-DD"，24 时制，区间 `2018-12-08 ~ 2019-12-07`）。

### DT-08 · N · 相对时间遵循阶梯
- 检查：读相对时间函数。
- 修法：<1min→刚刚；<1h→N 分钟前；<24h→N 小时前；>24h→MM-DD HH:mm；>1y→YYYY-MM-DD HH:mm。
- 来源：AD（relative time 阶梯）。

### DT-09 · S · 时间必须标注时区/口径（尤其跨天/跨零点日报）
- 检查：找时区标注；用 00:05 与 23:55 两个时刻各截一张图。
- 修法：标注 `UTC+8` 或"自然日(北京时间)"。
- 来源：NN#2（Match Real World）；跨零点是日报类看板的真实事故源。

### DT-10 · S · 图表类型与数据语义匹配
- 检查：逐图核对（趋势→线/构成→饼堆叠/分布→直方/对比→柱）。
- 修法：换图型。
- 来源：AD（"Use the correct chart type"）、GRAF。

### DT-11 · S · 默认不堆叠；如需堆叠必须显式说明
- 检查：查 ECharts `stack` 用法。
- 修法：关掉堆叠或加说明。
- 来源：**GRAF**（"Be careful with stacking … recommended that you turn it off in most cases"）。

### DT-12 · N · 不同单位/量级用双 Y 轴或拆图
- 检查：看是否有一条线被压成直线。
- 修法：双 yAxis 或拆分面板。
- 来源：GRAF。

### DT-13 · N · 比率类指标归一化
- 检查：逐指标核对定义。
- 修法：用百分比而非受分母影响的绝对值。
- 来源：GRAF（normalizing axes 降认知负荷）。

### DT-14 · S · 每个指标名旁有口径解释（Popover/description）
- 检查：逐指标找解释。
- 修法：antd `Tooltip`/`Popover` + `<QuestionCircleOutlined>`。
- 来源：AD（"Provide explanations where necessary"）、NN#10、DD（description 必填）。

### DT-15 · N · 高度聚合的图必须能补充细节
- 检查：试图回答"这个尖峰是谁造成的"。
- 修法：加 drill-down 或 tooltip 明细或切粒度。
- 来源：AD（Do/Don't 第一条）、GRAF。

### DT-16 · S · 极端内容不破版
- 检查：注入 200 字符字符串与 1e15 数字。
- 修法：`ellipsis: { showTitle: true }` + 容器 `min-width:0`；超长 ID 截断 + tooltip 全文。
- 来源：AD（"keep the words intact without occupying multiple lines"）、WIG（"Resilient to user-generated content"）。
