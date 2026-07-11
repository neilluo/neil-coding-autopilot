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
