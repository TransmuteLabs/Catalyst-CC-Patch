#!/usr/bin/env bash
# Syncing probe files between the CANON (this project) and the DEPLOYMENT.
#
# The direction is named explicitly, always: a one-way copy "wherever it lands"
# once already diverged the archive from the source, and it was found by accident.
#   --to-home    canon -> home  (roll out an edit)
#   --from-home  home  -> canon (pick up an edit made in place)
#   --diff       show divergences, touching nothing (default)
#
# Exit codes (a subset of the kit-wide table -- see the claude-patch-all.sh
# header): 0 -- in sync (or the copy went through); 1 -- divergences found in
# --diff, or files were missed in a copy mode; 2 -- unknown mode; 5 -- nothing
# to measure: this machine has no deployment at all. The return code is part of
# the report: --diff used to print "расходится: X" and exit 0, so a gate hung on
# it stayed green (round 18, F-10).
#
# «Не раскатан» и «расходится» -- РАЗНЫЕ классы, и смешивать их нельзя. Чистая
# машина, где дома ещё нет, обязана получить объявленный пропуск (5), иначе
# первая же сборка на ней не доедет до конца из-за гейта. Дом, который есть и
# отличается, -- красный: исполняются НЕ те байты, что сертифицировал стенд
# (круг 20, D-1: launchd месяц гонял compact.py доволновой сборки, пока стенд
# заверял канон).
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
# CLAUDE_PROBES_DIR -- ручка САМОГО ядра: где ядро читает настройки, там и дом.
# Две следующие -- ТОЛЬКО для стенда: он гоняет этот скрипт на игрушечных
# деревьях. Гейт конвейера снимает их перед вызовом (env -u), иначе окружение
# оператора увело бы сверку с настоящего дома на выдуманный.
TOOLS_HOME="${CLAUDE_JUDGE_TOOLS_DIR:-$HOME/.claude/judge}"
LAUNCH_AGENTS_DIR="${CLAUDE_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"

# pairs of "path in the canon : path in the home", the home is filled in by group
PROBE_FILES=(probes.toml judge/prompt.md judge/body.json idle-watch/prompt.md)
TOOL_FILES=(replay.py compact.py validate.py channel.py adjudicate.py README.md)

# The plist has its own home: launchd reads it from ~/Library/LaunchAgents,
# not the probe. Comparing it against a nonexistent file in the probes home is
# a perpetual "diverges" out of nowhere.
PLIST_NAME=com.transmutelabs.judge-compact.plist
PLIST_HOME="$HOME/Library/LaunchAgents/$PLIST_NAME"

MODE="${1:---diff}"
case "$MODE" in --to-home|--from-home|--diff) ;; *) echo "не понял режим: $MODE" >&2; exit 2 ;; esac

# Отсутствие исходной стороны -- НАЗВАННЫЙ отказ, а не тихий пропуск.
#
# Прежняя форма коротко замыкалась на `[[ -f "$A" ]] &&` и возвращала 0: файла
# канона нет -- ни строки, ни кода возврата. А это единственная команда, которую
# конвейер советует чистой машине, и человек читал её молчание как «раскатано».
#
# И копия ставится ПЕРЕИМЕНОВАНИЕМ. `cp` пишет поверх места назначения, и
# прерванный `cp` оставляет в доме половину файла. Для prompt.md это худший из
# исходов: усечённый TOML и усечённый body.json ядро замечает и объявляет
# (unparsed:/unparsed-body:), а половина prompt.md -- законный текст, то есть
# половина свода правил без единого признака деградации.
FAILED=0
DIFFERS=0
ABSENT=0
PRESENT=0
sync_one() {  # $1 canon, $2 home, $3 display name
  local A="$1" B="$2" name="$3" src dst
  case "$MODE" in
    --to-home)   src="$A"; dst="$B" ;;
    --from-home) src="$B"; dst="$A" ;;
    --diff)      if [[ ! -f "$B" ]]; then
                   echo "не раскатан: $name"; ABSENT=$((ABSENT+1))
                 elif diff -q "$A" "$B" >/dev/null 2>&1; then
                   PRESENT=$((PRESENT+1))
                 else
                   echo "расходится: $name"; DIFFERS=$((DIFFERS+1))
                 fi
                 return 0 ;;
  esac
  if [[ ! -f "$src" ]]; then
    echo "ОТКАЗ: нет исходника для $name ($src)" >&2
    FAILED=$((FAILED+1))
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  if cp "$src" "$dst.sync-new" && mv "$dst.sync-new" "$dst"; then
    [[ "$MODE" == "--to-home" ]] && echo "-> $name" || echo "<- $name"
  else
    rm -f "$dst.sync-new"
    echo "ОТКАЗ: не удалось записать $name ($dst)" >&2
    FAILED=$((FAILED+1))
  fi
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
  true
else
  sync_one "$ROOT/judge/$PLIST_NAME" "$PLIST_HOME" "$PLIST_NAME"
  [[ "$MODE" == "--to-home" ]] && \
    echo "   (plist обновлён — нужен launchctl bootout+bootstrap)"
fi

# Имя файла plist -- личное дело машины: launchd берёт метку из содержимого, а
# канон держит ОБРАЗЕЦ с плейсхолдерами. Сверять фиксированное КАНОНИЧЕСКОЕ имя
# с домом бессмысленно вдвойне: такого файла в доме нет никогда, и нога молчала
# всегда. Проверяемо и важно другое -- КУДА показывает реально заведённый агент:
# исполняются те байты, на которые он указывает, а не те, что заверил стенд.
if [[ "$MODE" == "--diff" ]]; then
  __agents=0
  for __pl in "$LAUNCH_AGENTS_DIR"/*judge-compact.plist; do
    [[ -f "$__pl" ]] || continue
    __agents=$((__agents+1))
    if grep -qF "$TOOLS_HOME/compact.py" "$__pl"; then
      echo "агент $(basename "$__pl") запускает раскатанный compact.py"
    else
      echo "расходится: агент $(basename "$__pl") запускает НЕ $TOOLS_HOME/compact.py"
      DIFFERS=$((DIFFERS+1))
    fi
  done
  if [[ "$__agents" -eq 0 ]]; then
    echo "(агента launchd *judge-compact.plist нет — сжатие журналов не заведено)"
  fi
  echo "(журналы, записи, метки и bench не синхронизируются — они данные машины, а не исходник)"
fi

# --diff отвечает КЛАССОМ, а не одним «не сошлось»: раскатки нет вовсе (5,
# мерить нечего) -- это не то же самое, что раскатка есть и отличается (1).
if [[ "$MODE" == "--diff" ]]; then
  if [[ "$DIFFERS" -ne 0 ]]; then
    echo "ИТОГ: расходится файлов: $DIFFERS (раскатать: bash $0 --to-home)" >&2
    exit 1
  fi
  if [[ "$PRESENT" -eq 0 && "$ABSENT" -ne 0 ]]; then
    echo "ИТОГ: на этой машине не раскатано ничего ($ABSENT файлов) — мерить нечего" >&2
    exit 5
  fi
  if [[ "$ABSENT" -ne 0 ]]; then
    echo "ИТОГ: раскатка неполная, нет файлов: $ABSENT (раскатать: bash $0 --to-home)" >&2
    exit 1
  fi
  exit 0
fi

# Код возврата -- часть отчёта. Раскатка, у которой не нашлось части файлов,
# прежде заканчивалась `exit 0`, и вызывающий (в том числе рецепт в хвосте
# конвейера) не мог отличить её от полной.
if [[ "$FAILED" -ne 0 ]]; then
  if [[ "$MODE" == "--diff" ]]; then
    echo "ИТОГ: расходится файлов: $FAILED" >&2
  else
    echo "ИТОГ: не перенесено файлов: $FAILED" >&2
  fi
  exit 1
fi
exit 0
