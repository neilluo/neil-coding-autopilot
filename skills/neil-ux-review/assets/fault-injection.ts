// fault-injection.ts
//
// neil-ux-review 的故障注入工具（P2 强制的 5 种数据态之 4：空/null/超长/超大）。
// 用于在 vitest 组件测 或 Storybook/预览态里，把组件推到极端数据，验证：
//   - 缺数不被渲染成 0（DT-01）
//   - 超长 ID/名称截断 + tooltip、超大数不换行（DT-16）
//   - 空数组走 empty 态而非残缺骨架（SF-01）
// 断网/超时（第 5 态）在 Playwright 层用 route.abort() 注入，见 a11y.spec 的扩展。

/** 超长字符串（撑爆布局用） */
export const LONG_STRING = 'x'.repeat(200)

/** 超大数字（千分位/换行/精度用） */
export const HUGE_NUMBER = 1e15 + 123456

/** 把对象的所有数值字段置 null（模拟"取数失败但字段在"） */
export function nullifyNumbers<T extends Record<string, unknown>>(obj: T): T {
  const out = { ...obj }
  for (const k of Object.keys(out)) {
    if (typeof out[k] === 'number') (out as Record<string, unknown>)[k] = null
  }
  return out
}

/** 五种数据态的枚举，供测试 describe.each 遍历 */
export const DATA_STATES = ['normal', 'empty', 'nullFields', 'longText', 'hugeNumber'] as const
export type DataState = (typeof DATA_STATES)[number]

/** 依据态生成一行样例数据（按目标项目的行类型改字段） */
export function makeRow(state: DataState, base: Record<string, unknown>) {
  switch (state) {
    case 'empty': return null
    case 'nullFields': return nullifyNumbers(base)
    case 'longText': return { ...base, uid: LONG_STRING, model: LONG_STRING }
    case 'hugeNumber': return { ...base, qps: HUGE_NUMBER, tokens: HUGE_NUMBER }
    default: return base
  }
}

/** 断言：格式化后的展示值绝不把 null/undefined 变成 '0' 或 0（DT-01 回归） */
export function assertMissingNotZero(rendered: string): boolean {
  const bad = rendered.trim()
  return bad !== '0' // 期望是 '-' / '--' / '' 之一，绝不是 '0'
}
