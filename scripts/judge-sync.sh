#!/usr/bin/env bash
# Синхронизация файлов судьи между КАНОНОМ (этот проект, judge/) и
# РАЗВЁРТЫВАНИЕМ (~/.claude/judge, откуда их читает пропатченный бинарник).
#
# Направление называется явно и всегда: односторонняя копия «куда придётся»
# уже один раз развела архив с исходником, и найдено это было случайно.
#   --to-home    канон  -> ~/.claude/judge   (раскатать правку)
#   --from-home  дом    -> канон             (забрать правку, сделанную на месте)
#   --diff       показать расхождения, ничего не трогая (по умолчанию)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOMEDIR="${CLAUDE_JUDGE_DIR:-$HOME/.claude/judge}"
FILES=(config.json prompt.md body.json README.md replay.py compact.py validate.py
       channel.py adjudicate.py)
# У plist другой дом: его читает launchd из ~/Library/LaunchAgents, а не судья
# из ~/.claude/judge. Сравнивать его с несуществующим файлом в доме судьи —
# вечное «расходится» на пустом месте.
PLIST_NAME=com.maratkarimov.judge-compact.plist
PLIST_HOME="$HOME/Library/LaunchAgents/$PLIST_NAME"
MODE="${1:---diff}"
for f in "${FILES[@]}"; do
  A="$ROOT/judge/$f"; B="$HOMEDIR/$f"
  case "$MODE" in
    --to-home)   [[ -f "$A" ]] && { cp "$A" "$B"; echo "-> $f"; } ;;
    --from-home) [[ -f "$B" ]] && { cp "$B" "$A"; echo "<- $f"; } ;;
    --diff)      diff -q "$A" "$B" >/dev/null 2>&1 || echo "расходится: $f" ;;
    *) echo "не понял режим: $MODE" >&2; exit 1 ;;
  esac
done
A="$ROOT/judge/$PLIST_NAME"; B="$PLIST_HOME"
case "$MODE" in
  --to-home)   [[ -f "$A" ]] && { cp "$A" "$B"; echo "-> $PLIST_NAME (в LaunchAgents; нужен launchctl bootout+bootstrap)"; } ;;
  --from-home) [[ -f "$B" ]] && { cp "$B" "$A"; echo "<- $PLIST_NAME"; } ;;
  --diff)      diff -q "$A" "$B" >/dev/null 2>&1 || echo "расходится: $PLIST_NAME" ;;
esac
[[ "$MODE" == "--diff" ]] && echo "(журнал, записи и bench не синхронизируются — они живут только в доме)"
