// lighthouserc.cjs
//
// Lighthouse CI 门禁配置（neil-ux-review P1/P7 用）。
// 安装：npm i -g @lhci/cli@0.15.x
// 运行：lhci autorun   （需要能启动的前端；startServerCommand 按目标项目改）
//
// 只对 accessibility 类目设硬阈值 + 若干高价值单项 audit；performance 给软阈值
// （看板首屏受数据源影响大，硬卡 perf 易 flaky，故 warn 而非 error）。

module.exports = {
  ci: {
    collect: {
      startServerCommand: 'npm run preview',       // 或 dev；按目标项目改
      startServerReadyPattern: 'Local:',
      url: [
        'http://localhost:4173/#/monitor',
        'http://localhost:4173/#/throttle',
        'http://localhost:4173/#/daily',
      ],
      numberOfRuns: 2,
      settings: { preset: 'desktop' },
    },
    assert: {
      assertions: {
        'categories:accessibility': ['error', { minScore: 0.95 }],
        'categories:performance': ['warn', { minScore: 0.8 }],
        'categories:best-practices': ['warn', { minScore: 0.9 }],
        // 高价值单项（对应规则库）
        'color-contrast': ['error', { minScore: 1 }],       // A11Y-08/09
        'button-name': ['error', { minScore: 1 }],          // A11Y-11
        'link-name': ['error', { minScore: 1 }],            // A11Y-11
        'aria-required-attr': ['error', { minScore: 1 }],   // A11Y-14/15
        'tabindex': ['error', { minScore: 1 }],             // A11Y-04
        'cumulative-layout-shift': ['warn', { maxNumericValue: 0.1 }], // PF-07
      },
    },
    upload: { target: 'temporary-public-storage' },
  },
}
