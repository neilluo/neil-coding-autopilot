// axe-vitest.setup.ts
//
// 在 vitest + jsdom 里做基本的 a11y 断言（结构/角色/label/aria），
// 因为 vitest-axe 已停更（npm 0.1.0 / 4 年未发版），这里直接调 axe-core。
//
// ⚠️ 已知盲区：JSDOM 下 axe 的 color-contrast 规则不工作 —— 对比度必须走 Playwright
//    层（assets/a11y.spec.ts）。这里显式禁用 color-contrast，避免给出假绿。
//
// 安装：npm i -D axe-core @testing-library/react jsdom
// 用法（组件测试内）：
//   import { expectNoA11yViolations } from './axe-vitest.setup'
//   const { container } = render(<MyPage />)
//   await expectNoA11yViolations(container)

import axe from 'axe-core'
import { expect } from 'vitest'

export async function expectNoA11yViolations(
  container: Element,
  options: axe.RunOptions = {},
): Promise<void> {
  const results = await axe.run(container, {
    // JSDOM 测不了对比度，显式关掉以免误导（对比度见 Playwright 层）
    rules: { 'color-contrast': { enabled: false }, ...(options.rules ?? {}) },
    ...options,
  })
  const violations = results.violations
  if (violations.length) {
    const msg = violations
      .map((v) => `  [${v.id}] ${v.help}\n    ${v.nodes.map((n) => n.target).join(', ')}`)
      .join('\n')
    // 用 vitest 断言承载，失败时打印可读清单
    expect(violations, `a11y violations (JSDOM, 不含对比度):\n${msg}`).toEqual([])
  }
}
