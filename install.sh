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
