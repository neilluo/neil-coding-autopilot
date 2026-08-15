# antd 5 / ECharts 5 修法手册

> 本 skill 面向 React 18 + antd 5 + ECharts 5 的数据监控看板。以下是 P6 落地修复时的**技术栈专属修法**，逐 rule_id 对应到组件级操作。**只用现有 token 与现有依赖**（红线 #2/#3）。

## 图标按钮无障碍（A11Y-11）
antd `Button` 只有 `icon` 无文字时，屏幕阅读器读不出用途：
```tsx
// ✗ <Button type="text" icon={<ReloadOutlined />} onClick={...} />
// ✓ 补 aria-label（图标本身 antd 已置 aria-hidden，无需重复）
<Button type="text" icon={<ReloadOutlined />} onClick={...} aria-label="手动刷新" />
```
`Tooltip` 的 title **不会**自动成为 `aria-label`——两者都要给。DatePicker/Select 同理：`<Select aria-label="选择数据口径" />`。

## 可见焦点环（A11Y-03）
antd 组件多数自带 focus 样式，但自定义 header 按钮/可点 div 常丢。全局补 `:focus-visible`（用 token，不用裸色值）：
```css
:where(button, a, [tabindex], .ant-segmented-item):focus-visible {
  outline: 2px solid var(--r-info);
  outline-offset: 2px;
}
```
不要 `outline: none` 后不补替代。

## 自动刷新可暂停/可调频（SF-06）+ 播报（SF-07）
看板轮询必须给"暂停"与"下次刷新倒计时"，并把状态放进 live region：
```tsx
<div role="status" aria-live="polite" className="sr-only">{liveMsg}</div>
// 暂停态要有常驻可见徽标（不能只靠 hover tooltip）——见 SF-05
```
倒计时用 `setInterval` 递减秒数展示；暂停时清定时器且徽标变"已暂停"。

## Skeleton 加载态（SF-01/02）
```tsx
// ✗ {data && <Chart data={data} />}   // 白屏 + 无 empty/error 分支
// ✓ 四态分支
if (loading && !data) return <Skeleton active paragraph={{ rows: 6 }} />
if (error) return <Result status="warning" title="取数失败" subTitle={reason} extra={<Button onClick={retry}>重试</Button>} />
if (!rows.length) return <Empty description="还没有配置任何 CID，请到「配置管理」添加要监控的客户" />
return <Table dataSource={rows} />
```
骨架形状尽量镜像最终布局，防 CLS。

## 缺数 ≠ 0（DT-01，阻断级）
```ts
// ✗ const qps = data.qps ?? 0            // 把"没取到"伪装成"真的是 0"
// ✓ 区分 null 与 0，展示层给 '-'
export const fmtNum = (v: number | null | undefined) =>
  v == null ? '-' : v.toLocaleString('en-US')
```
ECharts 缺口传 `null` 且**不设** `connectNulls`（默认即断开）；表格空单元格用 `-`，整表无数据用 `--` 或 `<Empty>`。

## 数值格式与右对齐（DT-04/05/06）
```tsx
{ title: 'QPS', dataIndex: 'qps', align: 'right',
  render: (v) => <span className="tabular">{fmtNum(v)}</span> }
```
```css
.tabular { font-variant-numeric: tabular-nums; }  /* 数字对齐、不跳动 */
```

## 超长内容截断 + tooltip（DT-16）
```tsx
// 表格列
{ title: 'UID', dataIndex: 'uid', ellipsis: { showTitle: false },
  render: (uid) => <Tooltip title={uid}><span className="mono">{uid}</span></Tooltip> }
// 一键复制（EF 效率）：antd Typography
<Typography.Text copyable={{ text: uid }} className="mono">{uid}</Typography.Text>
```

## 时区标注（DT-09）
跨零点日报必须标注口径。在页头或指标旁：`窗口 2026-08-14 00:00 ~ 23:59（北京时间 UTC+8）`。

## Tabs / Modal（A11Y-14/15）
优先用 antd `Tabs`（已内建 tablist/tab/tabpanel + 方向键 + aria-selected）与 `Modal`（已内建 inert + Tab 循环 + Esc）。**不要**覆盖 `Modal keyboard={false}`（会破坏 Esc 关闭）。`Segmented` 不是 tablist——若当导航用，给容器补 `role="tablist"` 语义或换 `Tabs`。

## 破坏性操作确认（SF-11）
```tsx
<Popconfirm title="将触发服务端重新获取限额，可能需要几秒" onConfirm={refreshLimits}>
  <Button>强制刷新阈值</Button>
</Popconfirm>
```

## 重要失败不用瞬时 message（SF-08）
```ts
// ✗ message.error('刷新失败')        // 3s 自动消失，重要失败会被错过
// ✓ Modal.error({ title: '刷新阈值失败', content: reason })   // 或页内常驻 Alert
```

## URL 深链（IA-06）
把 view/selectedUid/时间范围/tab 同步进 hash 或 `?query`，刷新/分享/前进后退都能还原。项目已用 hash 路由，扩展 `parseRoute`/`routeToHash` 覆盖新状态即可，不引路由库。

## ECharts 无障碍（A11Y-09/10，选做）
ECharts 5 起需 `echarts.use(AriaComponent)` 才能开 `aria`；开启后容器自动生成 `aria-label` 描述，`aria.decal` 提供色盲友好贴花作为颜色的第二编码。**键名（`aria.show` vs `aria.enabled`）以本项目 echarts 版本实测为准**（官方 handbook 混用过两种写法）。图表线色对比度走 A11Y-09。

## 反模式（技术栈相关）
- 别把 antd 组件替换成自造 div（丢无障碍与键盘）。
- 别 `npm i` tailwind/framer-motion/react-icons —— antd + 现有 token 够用（红线 #3）。
- 别在只读 `Table` 加 `role="grid"` 不实现键盘导航（A11Y-12）。
- 别用 `dangerouslySetInnerHTML` 渲染后端文案。
