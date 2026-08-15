#!/usr/bin/env bash
# probe-runtime.sh — neil-ux-review P2 运行时探针编排（起服务 → Playwright → 收产物）
#
# 用法：bash probe-runtime.sh [web目录，默认当前]
# 前置：目标项目已 npm i -D @playwright/test @axe-core/playwright，且 a11y.spec.ts 已就位
#       （从本 skill assets/ 拷入目标项目 tests/）。
# 产物：<web>/ux/probe/*.png + 控制台 axe/键盘报告。
set -uo pipefail

WEB="${1:-.}"
cd "$WEB" || { echo "目录不存在: $WEB" >&2; exit 1; }

PORT="${UX_PORT:-5173}"
BASE_URL="${BASE_URL:-http://localhost:${PORT}}"
export BASE_URL
export UX_OUT="${UX_OUT:-ux/probe}"
mkdir -p "$UX_OUT"

# 探测前端是否已在跑；没跑则临时起 dev 并在结束时收摊
STARTED=0
if ! curl -sf "$BASE_URL" >/dev/null 2>&1; then
  echo "前端未在 $BASE_URL 运行，临时启动 npm run dev …"
  npm run dev >/tmp/ux-probe-dev.log 2>&1 &
  DEV_PID=$!
  STARTED=1
  for _ in $(seq 1 30); do
    curl -sf "$BASE_URL" >/dev/null 2>&1 && break
    sleep 1
  done
fi

cleanup() { [ "$STARTED" = 1 ] && kill "${DEV_PID:-}" 2>/dev/null || true; }
trap cleanup EXIT

if ! curl -sf "$BASE_URL" >/dev/null 2>&1; then
  echo "启动失败，见 /tmp/ux-probe-dev.log" >&2
  echo "UX_PROBE_STATUS=BLOCKED|dev-server-not-ready"
  exit 2
fi

echo "对 $BASE_URL 跑 Playwright a11y.spec.ts（axe × 键盘 × 截图矩阵）…"
npx playwright test a11y.spec.ts --reporter=list
RC=$?

echo ""
echo "截图产物：$UX_OUT/"
ls -1 "$UX_OUT" 2>/dev/null | sed 's/^/  - /'
if [ "$RC" = 0 ]; then
  echo "UX_PROBE_STATUS=DONE"
else
  echo "UX_PROBE_STATUS=DONE|with-violations（见上方 axe 输出，逐条转 findings.json）"
fi
exit 0
