#!/bin/bash
# Session-only fallback: FUNCTION_HOOKS + CARRIER=mod + three --plugin-dir.
# Primary path (measured on 2.1.267): ~/.claude/settings.json env +
# extraKnownMarketplaces catalyst-mods (directory) + enabledPlugins
# plugin-id@catalyst-mods. `claude plugin marketplace add --scope user`
# writes known_marketplaces.json; extraKnownMarketplaces alone does not
# register. This script does not write settings.json and does not patch
# the live binary.
set -euo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
pick_image() {
  if [[ -n "${CLAUDE_MODS_IMAGE:-}" ]]; then
    printf '%s\n' "$CLAUDE_MODS_IMAGE"
    return
  fi
  local st=/tmp/t113-full/267.staging
  if [[ -x "$st" ]] && python3 -c "import sys; sys.exit(0 if b'CLAUDE_JUDGE_CARRIER' in open('$st','rb').read() else 1)"; then
    printf '%s\n' "$st"
    return
  fi
  command -v claude
}
IMG="$(pick_image)"
if [[ -z "$IMG" || ! -x "$IMG" ]]; then
  echo "claude-mods: no executable image" >&2
  exit 2
fi
export CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1
export CLAUDE_JUDGE_CARRIER="${CLAUDE_JUDGE_CARRIER:-mod}"
export CLAUDE_FORM_CARRIER="${CLAUDE_FORM_CARRIER:-mod}"
export CLAUDE_IDLE_CARRIER="${CLAUDE_IDLE_CARRIER:-mod}"
exec "$IMG" \
  --plugin-dir "$KIT/mods/catalyst-judge" \
  --plugin-dir "$KIT/mods/catalyst-form" \
  --plugin-dir "$KIT/mods/catalyst-idle" \
  "$@"
