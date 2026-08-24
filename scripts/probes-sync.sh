#!/usr/bin/env bash
# Синхронизация файлов проб между КАНОНОМ (этот проект) и РАЗВЁРТЫВАНИЕМ.
#
# Направление называется явно и всегда: односторонняя копия «куда придётся»
# уже один раз развела архив с исходником, и найдено это было случайно.
#   --to-home    канон -> дом   (раскатать правку)
#   --from-home  дом   -> канон (забрать правку, сделанную на месте)
#   --diff       показать расхождения, ничего не трогая (по умолчанию)
#
# Домов ДВА, и это не небрежность, а сегодняшний факт установки:
#   настройки и промты  -> $CLAUDE_PROBES_DIR (умолчание ~/.claude/probes)
#   инструменты (.py)   -> ~/.claude/judge — оттуда их запускает launchd,
#                          путь записан в plist агента
# Скрипт, знавший только один дом, раскатывал промты в каталог, который ядро
# перестало читать после переезда на реестр: правка «уезжала» молча.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBES_HOME="${CLAUDE_PROBES_DIR:-$HOME/.claude/probes}"
TOOLS_HOME="$HOME/.claude/judge"

# пары «путь в каноне : путь в доме», дом подставляется по группе
PROBE_FILES=(probes.toml judge/prompt.md judge/body.json idle-watch/prompt.md)
TOOL_FILES=(replay.py compact.py validate.py channel.py adjudicate.py README.md)

# У plist свой дом: его читает launchd из ~/Library/LaunchAgents, а не проба.
# Сравнивать его с несуществующим файлом в доме проб — вечное «расходится»
# на пустом месте.
PLIST_NAME=com.transmutelabs.judge-compact.plist
PLIST_HOME="$HOME/Library/LaunchAgents/$PLIST_NAME"

MODE="${1:---diff}"
case "$MODE" in --to-home|--from-home|--diff) ;; *) echo "не понял режим: $MODE" >&2; exit 1 ;; esac

sync_one() {  # $1 канон, $2 дом, $3 отображаемое имя
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
# plist в каноне — ОБРАЗЕЦ с плейсхолдерами путей. Раскатать его как есть
# значит зарегистрировать в launchd агент, указывающий на /Users/YOUR-USER:
# он молча не отработает ни разу. Копируем только заполненный под себя.
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
