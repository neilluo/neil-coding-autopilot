// a11y.spec.ts
//
// neil-ux-review 的 P2 运行时探针（Playwright + axe-core）。
// 这是唯一能真实测出「颜色对比度」的层（JSDOM 下 axe 的 color-contrast 规则不工作）。
//
// 安装：npm i -D @playwright/test @axe-core/playwright && npx playwright install chromium
// 运行：BASE_URL=http://localhost:5173 npx playwright test a11y.spec.ts
// 产物：ux/probe/*.png（3 主题 × 3 视口 截图矩阵）+ 控制台打印每路由 violations。
//
// 按目标项目改 ROUTES / THEMES / 主题切换方式（下方用 localStorage + class，贴合
// bailian-radar-web 的 theme 体系；其它项目请改 applyTheme）。

import { test, expect, type Page } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'

const BASE_URL = process.env.BASE_URL ?? 'http://localhost:5173'
const OUT = process.env.UX_OUT ?? 'ux/probe'

// 逐路由（hash 路由示例）。改成目标项目的真实路由。
const ROUTES: Record<string, string> = {
  monitor: '#/monitor',
  throttle: '#/throttle',
  limits: '#/limits',
  daily: '#/daily',
  config: '#/config',
}

const THEMES = ['midnight', 'daylight', 'console'] as const
const VIEWPORTS = [
  { name: 'laptop', width: 1440, height: 900 },
  { name: 'tablet', width: 1024, height: 768 },
  // 320 CSS px = 1280px@400% zoom（WCAG 1.4.10 Reflow）
  { name: 'reflow320', width: 320, height: 720 },
]

async function applyTheme(page: Page, theme: string) {
  await page.addInitScript((t) => {
    try { localStorage.setItem('radar-theme', t) } catch { /* ignore */ }
  }, theme)
}

// ① 逐路由 × 主题 axe 扫描（含对比度）——WCAG 2.0/2.1/2.2 A+AA
for (const theme of THEMES) {
  for (const [name, hash] of Object.entries(ROUTES)) {
    test(`axe: ${theme} / ${name}`, async ({ page }) => {
      await applyTheme(page, theme)
      await page.goto(`${BASE_URL}/${hash}`)
      await page.waitForLoadState('networkidle')
      const results = await new AxeBuilder({ page })
        .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa', 'wcag22aa'])
        .analyze()
      const serious = results.violations.filter((v) =>
        v.impact === 'serious' || v.impact === 'critical',
      )
      if (serious.length) {
        console.log(`\n[axe ${theme}/${name}] ${serious.length} serious/critical:`)
        for (const v of serious) console.log(`  - [${v.id}] ${v.help} (${v.nodes.length} nodes)`)
      }
      // 门禁：serious/critical 归零。放开 minor/moderate 给人工复核。
      expect(serious, `axe serious violations on ${theme}/${name}`).toEqual([])
    })
  }
}

// ② 3 主题 × 3 视口 截图矩阵（人工看空/密/溢出/对比）
for (const theme of THEMES) {
  for (const vp of VIEWPORTS) {
    test(`shot: ${theme} / ${vp.name}`, async ({ page }) => {
      await applyTheme(page, theme)
      await page.setViewportSize({ width: vp.width, height: vp.height })
      await page.goto(`${BASE_URL}/${ROUTES.monitor}`)
      await page.waitForLoadState('networkidle')
      await page.screenshot({ path: `${OUT}/${theme}-${vp.name}.png`, fullPage: true })
    })
  }
}

// ③ 纯键盘遍历：记录焦点序，验证无裸元素被跳过、焦点环可见（截图交人工判"合理性"）
test('keyboard: focus order & visible ring', async ({ page }) => {
  await page.goto(`${BASE_URL}/${ROUTES.monitor}`)
  await page.waitForLoadState('networkidle')
  const order: string[] = []
  for (let i = 0; i < 25; i++) {
    await page.keyboard.press('Tab')
    const info = await page.evaluate(() => {
      const el = document.activeElement as HTMLElement | null
      if (!el || el === document.body) return null
      const s = getComputedStyle(el)
      return {
        tag: el.tagName.toLowerCase(),
        label: el.getAttribute('aria-label') || el.textContent?.trim().slice(0, 20) || '',
        // 焦点环可见性：outline 或 box-shadow 至少一个非 none（A11Y-03）
        ring: s.outlineStyle !== 'none' || s.boxShadow !== 'none',
      }
    })
    if (info) {
      order.push(`${info.tag}[${info.label}]${info.ring ? '' : ' ⚠NO-RING'}`)
    }
  }
  console.log('\n[keyboard focus order]\n  ' + order.join('\n  '))
  await page.screenshot({ path: `${OUT}/keyboard-focus.png` })
  // 至少能 Tab 到若干可交互元素（防"全站不可键盘达"）
  expect(order.length).toBeGreaterThan(3)
})
