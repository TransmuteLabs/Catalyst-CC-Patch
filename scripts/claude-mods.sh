#!/bin/bash
# Session-only fallback: FUNCTION_HOOKS + CARRIER=mod + one --plugin-dir.
# Primary path: TransmuteLabs/Catalyst plugin catalyst-probes@catalyst
# (settings.json env + enabledPlugins). This script does not write
# settings.json and does not patch the live binary.
set -euo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
FAMILY="${CATALYST_FAMILY:-$KIT/../Catalyst}"
PLUGIN="$FAMILY/plugins/catalyst-probes"
if [[ ! -f "$PLUGIN/hooks/register.ts" ]]; then
  PLUGIN="${HOME}/.claude/plugins/cache/catalyst/catalyst-probes/0.1.0"
fi
if [[ ! -f "$PLUGIN/hooks/register.ts" ]]; then
  echo "claude-mods: catalyst-probes not found (clone TransmuteLabs/Catalyst or install catalyst-probes@catalyst)" >&2
  exit 2
fi
pick_image() {
  if [[ -n "${CLAUDE_MODS_IMAGE:-}" ]]; then
    printf '%s\n' "$CLAUDE_MODS_IMAGE"
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
exec "$IMG" --plugin-dir "$PLUGIN" "$@"
