#!/usr/bin/env bash
# Install all neil-coding-autopilot skills into Qoder
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
QODER_SKILLS_DIR="${HOME}/.qoder/skills"

echo "Installing neil-coding-autopilot plugin..."
echo "Source: ${PLUGIN_DIR}"
echo "Target: ${QODER_SKILLS_DIR}"
echo ""

# Install each sub-skill as a symlink
for skill_dir in "${PLUGIN_DIR}/skills"/*/; do
    skill_name=$(basename "$skill_dir")
    target="${QODER_SKILLS_DIR}/${skill_name}"
    
    if [ -L "$target" ]; then
        rm "$target"
    fi
    
    ln -sf "$skill_dir" "$target"
    echo "  ✅ ${skill_name} → ${target}"
done

# Also install the root as neil-coding-autopilot (bootstrap entry)
root_target="${QODER_SKILLS_DIR}/neil-coding-autopilot"
if [ -L "$root_target" ]; then
    rm "$root_target"
fi
ln -sf "${PLUGIN_DIR}" "$root_target"
echo "  ✅ neil-coding-autopilot (root) → ${root_target}"

echo ""
echo "Done! Installed $(ls -d "${PLUGIN_DIR}/skills"/*/ | wc -l | tr -d ' ') skills + 1 root entry."
echo "⚠️  Restart Qoder to activate new skills."

# Track A self-check (non-blocking): prove dispatch.sh actually runs on THIS host
# now, instead of failing at runtime inside some business project later.
SMOKE="${PLUGIN_DIR}/scripts/smoke-dispatch.sh"
if [ -f "$SMOKE" ]; then
    echo ""
    if bash "$SMOKE" >/dev/null 2>&1; then
        echo "  ✅ Track A self-check (smoke-dispatch): PASS"
    else
        echo "  ⚠️  Track A self-check (smoke-dispatch): FAILED — batch mode (Track A) may not work here."
        echo "     Interactive mode (Track B) is unaffected. Run 'bash scripts/smoke-dispatch.sh' to see why."
    fi
fi

# Activate the controller hard-gates (PreToolUse) ----------------------------
# This plugin installs as skills (symlinks), NOT as a Qoder plugin, so its
# hooks/hooks-qoder.json is NOT auto-loaded. To make the guards actually fire
# for the interactive CONTROLLER session, merge PreToolUse hooks into the
# user-level settings Qoder loads at session start (~/.qoder/settings.json).
# Two gates, both scope-gated by autopilot/.run-active (INERT outside a run):
#   • guard-controller-write.sh — file-writing tools (Write/Edit/…)
#   • guard-bash-write.sh       — shell redirection (cat > x.py / tee / dd)
# Opt out: AUTOPILOT_SKIP_GUARD_INSTALL=1.
FILE_GUARD="${PLUGIN_DIR}/hooks/guard-controller-write.sh"
BASH_GUARD="${PLUGIN_DIR}/hooks/guard-bash-write.sh"
SETTINGS="${HOME}/.qoder/settings.json"
FILE_MATCHER="Write|Edit|MultiEdit|write|edit|create_file|write_file|search_replace|replace|NotebookEdit"
BASH_MATCHER="Bash|bash|shell|run_terminal_cmd|terminal|execute_command"
# Qoder silently SKIPS non-executable hooks (fail-open) — always ensure +x.
chmod +x "$FILE_GUARD" "$BASH_GUARD" 2>/dev/null || true
echo ""
if [ "${AUTOPILOT_SKIP_GUARD_INSTALL:-0}" = "1" ]; then
    echo "  ⏭  hard-gates: skipped (AUTOPILOT_SKIP_GUARD_INSTALL=1)"
elif ! command -v jq >/dev/null 2>&1; then
    echo "  ⚠️  hard-gates: jq not found — add these PreToolUse hooks to ${SETTINGS} manually:"
    echo "        ${FILE_MATCHER}  ->  ${FILE_GUARD}"
    echo "        ${BASH_MATCHER}  ->  ${BASH_GUARD}"
else
    mkdir -p "${HOME}/.qoder"
    [ -s "$SETTINGS" ] || echo '{}' > "$SETTINGS"
    _reg() {  # _reg <matcher> <command> — idempotently append one PreToolUse entry
        local m="$1" cmd="$2" _tmp
        if jq -e --arg cmd "$cmd" '[.. | objects | select(.command? == $cmd)] | length > 0' "$SETTINGS" >/dev/null 2>&1; then
            echo "  ✅ hard-gate already registered: $(basename "$cmd")"; return 0
        fi
        cp "$SETTINGS" "${SETTINGS}.bak-$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
        _tmp="$(mktemp)"
        if jq --arg m "$m" --arg cmd "$cmd" \
              '.hooks = (.hooks // {}) | .hooks.PreToolUse = ((.hooks.PreToolUse // []) + [{"matcher":$m,"hooks":[{"type":"command","command":$cmd}]}])' \
              "$SETTINGS" > "$_tmp" 2>/dev/null && [ -s "$_tmp" ]; then
            mv "$_tmp" "$SETTINGS"; echo "  ✅ hard-gate registered: $(basename "$cmd")"
        else
            rm -f "$_tmp"; echo "  ⚠️  hard-gate merge failed for $(basename "$cmd"); settings.json left untouched."
        fi
    }
    _reg "$FILE_MATCHER" "$FILE_GUARD"
    _reg "$BASH_MATCHER" "$BASH_GUARD"
    echo "     restart Qoder to activate; remove by deleting those PreToolUse entries."
fi

# Guard self-check (token-free): prove both gates' allow/deny logic on THIS host.
for _sg in smoke-guard smoke-bash-guard; do
    _SMOKE="${PLUGIN_DIR}/scripts/${_sg}.sh"
    if [ -f "$_SMOKE" ]; then
        if bash "$_SMOKE" >/dev/null 2>&1; then
            echo "  ✅ hard-gate self-check (${_sg}): PASS"
        else
            echo "  ⚠️  hard-gate self-check (${_sg}): FAILED — run 'bash scripts/${_sg}.sh' to see why."
        fi
    fi
done
