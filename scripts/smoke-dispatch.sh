#!/usr/bin/env bash
# Smoke test for scripts/dispatch.sh (Track A worker dispatch).
#
# Verifies — WITHOUT burning LLM tokens — that dispatch.sh:
#   1. runs to completion on this host (regression guard for the macOS
#      "timeout: command not found" / exit 127 bug), and
#   2. invokes the underlying CLI with the expected, real flags.
#
# It shims qodercli/claude/codex with a stub that only echoes its args, so no
# model is ever called. Intended for CI and post-install self-check.
#
# Usage:  bash scripts/smoke-dispatch.sh
# Exit:   0 = all platforms pass, 1 = failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$SCRIPT_DIR/dispatch.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

# Stub each supported CLI: echo the args so we can assert on them.
for bin in qodercli claude codex; do
  printf '#!/usr/bin/env bash\necho "CALLED %s $*"\n' "$bin" > "$STUB_DIR/$bin"
  chmod +x "$STUB_DIR/$bin"
done
printf 'smoke prompt body\n' > "$STUB_DIR/prompt.md"

fail=0

if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  echo "INFO: timeout binary present -> worker time cap is active"
else
  echo "INFO: no timeout/gtimeout -> dispatch.sh degrades to no time cap (expected on stock macOS)"
fi

run_one() {
  local plat="$1" expect="$2" out
  if ! out="$(AUTOPILOT_PLATFORM="$plat" AUTOPILOT_TIMEOUT=5 PATH="$STUB_DIR:$PATH" \
      bash "$DISPATCH" --model TestModel --cwd "$STUB_DIR" \
      --prompt-file "$STUB_DIR/prompt.md" --instruction "reply OK" 2>&1)"; then
    echo "FAIL[$plat]: dispatch.sh exited non-zero"; echo "$out"; fail=1; return
  fi
  if ! grep -q "$expect" <<<"$out"; then
    echo "FAIL[$plat]: expected '$expect' not found in output"; echo "$out"; fail=1; return
  fi
  echo "PASS[$plat]: $(grep -m1 CALLED <<<"$out" || true)"
}

run_one qoder  "CALLED qodercli -m TestModel -w"
run_one claude "CALLED claude -m TestModel"
run_one codex  "CALLED codex --model TestModel"

if [ "$fail" = 0 ]; then
  echo "SMOKE: ALL PASS"
else
  echo "SMOKE: FAILED"
  exit 1
fi
