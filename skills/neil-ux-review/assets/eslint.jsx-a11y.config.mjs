// eslint.jsx-a11y.config.mjs
//
// neil-ux-review 提供的 a11y 静态检查 flat config（ESLint 9+）。
// 用法：拷到目标前端项目根为 eslint.config.mjs（或 merge 进已有 config），然后
//   npm i -D eslint @eslint/js typescript-eslint eslint-plugin-react-hooks eslint-plugin-jsx-a11y
//   npx eslint "src/**/*.{ts,tsx}" --max-warnings 0
//
// 只聚焦无障碍与交互正确性，不做风格化 lint（那是另一回事）。
// recommended 之外额外开启两条默认关闭但对看板高价值的规则。

import js from '@eslint/js'
import tseslint from 'typescript-eslint'
import jsxA11y from 'eslint-plugin-jsx-a11y'
import reactHooks from 'eslint-plugin-react-hooks'

export default tseslint.config(
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: ['**/*.{ts,tsx}'],
    plugins: { 'jsx-a11y': jsxA11y, 'react-hooks': reactHooks },
    rules: {
      // --- jsx-a11y recommended 的关键项（显式列出便于审计）---
      'jsx-a11y/alt-text': 'error',
      'jsx-a11y/anchor-is-valid': 'error',
      'jsx-a11y/aria-props': 'error',
      'jsx-a11y/aria-role': 'error',
      'jsx-a11y/click-events-have-key-events': 'error',
      'jsx-a11y/heading-has-content': 'error',
      'jsx-a11y/interactive-supports-focus': 'error',
      'jsx-a11y/label-has-associated-control': 'error',
      'jsx-a11y/mouse-events-have-key-events': 'error',
      'jsx-a11y/no-autofocus': 'warn',
      'jsx-a11y/no-aria-hidden-on-focusable': 'error',
      'jsx-a11y/no-noninteractive-tabindex': 'error',
      'jsx-a11y/no-static-element-interactions': 'error',
      'jsx-a11y/role-has-required-aria-props': 'error',
      'jsx-a11y/role-supports-aria-props': 'error',
      'jsx-a11y/scope': 'error',
      'jsx-a11y/tabindex-no-positive': 'error',
      // --- 默认关闭、本 skill 额外开启（看板高价值）---
      'jsx-a11y/control-has-associated-label': 'error', // 图标按钮/可点控件必须有可访问名（对应 A11Y-11）
      'jsx-a11y/anchor-ambiguous-text': 'warn',         // 禁 "点这里"/"更多" 之类无意义链接文案
      'react-hooks/rules-of-hooks': 'error',
      'react-hooks/exhaustive-deps': 'warn',
    },
  },
  { ignores: ['dist/**', 'node_modules/**', '**/*.config.*', 'tests/**'] },
)
