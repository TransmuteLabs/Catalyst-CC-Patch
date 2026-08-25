#!/usr/bin/env bash
# Syncing probe files between the CANON (this project) and the DEPLOYMENT.
#
# The direction is named explicitly, always: a one-way copy "wherever it lands"
# once already diverged the archive from the source, and it was found by accident.
#   --to-home    canon -> home  (roll out an edit)
#   --from-home  home  -> canon (pick up an edit made in place)
#   --diff       show divergences, touching nothing (default)
#
# There are TWO homes, and that is not sloppiness but today's install fact:
#   settings and prompts  -> $CLAUDE_PROBES_DIR (default ~/.claude/probes)
#   tools (.py)           -> ~/.claude/judge — launchd runs them from there,
#                           the path is written in the agent plist
# A script that knew only one home rolled prompts into a directory the core
# stopped reading after the move to the registry: the edit "went away" silently.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBES_HOME="${CLAUDE_PROBES_DIR:-$HOME/.claude/probes}"
TOOLS_HOME="$HOME/.claude/judge"

# pairs of "path in the canon : path in the home", the home is filled in by group
PROBE_FILES=(probes.toml judge/prompt.md judge/body.json idle-watch/prompt.md)
TOOL_FILES=(replay.py compact.py validate.py channel.py adjudicate.py README.md)

# The plist has its own home: launchd reads it from ~/Library/LaunchAgents,
# not the probe. Comparing it against a nonexistent file in the probes home is
# a perpetual "diverges" out of nowhere.
PLIST_NAME=com.transmutelabs.judge-compact.plist
PLIST_HOME="$HOME/Library/LaunchAgents/$PLIST_NAME"

MODE="${1:---diff}"
case "$MODE" in --to-home|--from-home|--diff) ;; *) echo "не понял режим: $MODE" >&2; exit 1 ;; esac

sync_one() {  # $1 canon, $2 home, $3 display name
  local A="$1" B="$2" name="$3"
  case "$MODE" in
    --to-home)   [[ -f "$A" ]] && { mkdir -p "$(dirname "$B")"; cp "$A" "$B"; echo "-> $name"; } ;;
    --from-home) [[ -f "$B" ]] && { mkdir -p "$(dirname "$A")"; cp "$B" "$A"; echo "<- $name"; } ;;
    --diff)      diff -q "$A" "$B" >/dev/null 2>&1 || echo "расходится: $name" ;;
  esac
  return 0
}

for f in "${PROBE_FILES[@]}";  do sync_one "$ROOT/probes/$f" "$PROBES_HOME/$f" "probes/$f"; done
for f in "${TOOL_FILES[@]}";   do sync_one "$ROOT/judge/$f"  "$TOOLS_HOME/$f"  "judge/$f";  done
# The plist in the canon is a SAMPLE with path placeholders. Rolling it out
# as-is means registering in launchd an agent pointing at /Users/YOUR-USER:
# it would silently never run. We copy only one filled in for this machine.
if grep -q 'YOUR-USER' "$ROOT/judge/$PLIST_NAME" 2>/dev/null; then
  [[ "$MODE" == "--to-home" ]] && \
    echo "!! $PLIST_NAME не раскатан: в каноне образец с /Users/YOUR-USER — заполните пути под себя"
  [[ "$MODE" == "--diff" ]] && echo "(plist в каноне — образец с плейсхолдерами, сравнение с домом не имеет смысла)"
else
  sync_one "$ROOT/judge/$PLIST_NAME" "$PLIST_HOME" "$PLIST_NAME"
  [[ "$MODE" == "--to-home" ]] && \
    echo "   (plist обновлён — нужен launchctl bootout+bootstrap)"
fi

[[ "$MODE" == "--diff" ]] && \
  echo "(журналы, записи, метки и bench не синхронизируются — они данные машины, а не исходник)"
exit 0
