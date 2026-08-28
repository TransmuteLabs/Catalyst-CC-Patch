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
# Лестница дома -- ТА ЖЕ, что у ядра и у самого продукта: своя переменная,
# затем CLAUDE_CONFIG_DIR, затем ~/.claude. Раскатка, знающая только HOME,
# клала бы файлы мимо дома изолированной установки (круг 21, F-8).
CLAUDE_HOME_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PROBES_HOME="${CLAUDE_PROBES_DIR:-$CLAUDE_HOME_DIR/probes}"
# CLAUDE_PROBES_DIR -- ручка САМОГО ядра: где ядро читает настройки, там и дом.
# Две следующие -- ТОЛЬКО для стенда: он гоняет этот скрипт на игрушечных
# деревьях. Гейт конвейера снимает их перед вызовом (env -u), иначе окружение
# оператора увело бы сверку с настоящего дома на выдуманный.
TOOLS_HOME="${CLAUDE_JUDGE_TOOLS_DIR:-$CLAUDE_HOME_DIR/judge}"
LAUNCH_AGENTS_DIR="${CLAUDE_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"

# pairs of "path in the canon : path in the home", the home is filled in by group
PROBE_FILES=(probes.toml judge/prompt.md judge/body.json idle-watch/prompt.md)
TOOL_FILES=(replay.py compact.py validate.py channel.py adjudicate.py README.md)

# The plist has its own home: launchd reads it from ~/Library/LaunchAgents,
# not the probe. Comparing it against a nonexistent file in the probes home is
# a perpetual "diverges" out of nowhere.
# Каталог берётся из LAUNCH_AGENTS_DIR, а не из $HOME напрямую: ручка
# CLAUDE_LAUNCH_AGENTS_DIR объявлена выше именно для того, чтобы стенд гонял
# раскатку на игрушечном дереве. Со вшитым $HOME она была объявлена и НЕ
# ДЕЙСТВОВАЛА на этом пути: `--to-home` в стенде писал бы plist в настоящий
# ~/Library/LaunchAgents живой машины (круг 21, F-4).
PLIST_NAME=com.transmutelabs.judge-compact.plist
PLIST_HOME="$LAUNCH_AGENTS_DIR/$PLIST_NAME"

MODE="${1:---diff}"
case "$MODE" in --to-home|--from-home|--diff) ;; *) echo "не понял режим: $MODE" >&2; __DONE=1; exit 2 ;; esac

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

# Набор пар собирается ЦЕЛИКОМ до первой записи: и сверка, и раскатка идут по
# одному списку, а раскатка обязана быть всё-или-ничего.
PAIR_A=(); PAIR_B=(); PAIR_N=()
add_pair() { PAIR_A+=("$1"); PAIR_B+=("$2"); PAIR_N+=("$3"); }

diff_one() {  # $1 canon, $2 home, $3 display name
  if [[ ! -f "$2" ]]; then
    echo "не раскатан: $3"; ABSENT=$((ABSENT+1))
  elif diff -q "$1" "$2" >/dev/null 2>&1; then
    PRESENT=$((PRESENT+1))
  else
    echo "расходится: $3"; DIFFERS=$((DIFFERS+1))
  fi
}

# Раскатка идёт В ДВА ПРОХОДА: сперва КАЖДЫЙ файл ложится рядом с местом
# назначения под временным именем, и только когда лёг весь набор -- он вводится
# переименованиями. Прежняя форма копировала и переименовывала по одному:
# пропавший исходник шестого файла оставлял дом с пятью новыми и пятью старыми,
# и ядро читает такой дом молча -- промт одной волны с настройками другой
# (круг 21, E-4). Пропуск любого исходника теперь не трогает дом ВООБЩЕ.
#
# Во временном имени стоит pid: два одновременных `--to-home` на общий дом
# писали в один и тот же `$dst.sync-new`, и переименование второго уносило
# полуготовые байты первого (круг 21, F-5).
#
# Остаточное окно -- жёсткое убийство МЕЖДУ переименованиями (в проходе 2 нет
# ни чтения, ни записи данных). Закрыть его без подмены каталога целиком нельзя,
# а подменять дом нельзя: рядом с раскатанными файлами лежат журналы и записи
# машины. Смешанное состояние из этого окна видит `--diff` -- тот самый гейт,
# который дом и читает.
STAGE_TMP=(); STAGE_DST=(); STAGE_NAME=()
cleanup_staged() {
  local __i
  for ((__i=0; __i<${#STAGE_TMP[@]}; __i++)); do rm -f "${STAGE_TMP[$__i]}"; done
  STAGE_TMP=()
}
# Часовой оборванного прогона: bash 3.2 отдаёт код 0, когда скрипт с EXIT-трапом
# умирает на фатальной ошибке ПОДСТАНОВКИ (unbound под `set -u`, `${x:?}`, bad
# substitution) -- трап исполняется, `$?` внутри него ноль, и вызывающий видит
# успех вместо обрыва. Гейт этой формы (правило 3) поймал скрипт сразу после
# того, как у него появился трап. Каждый ОБЪЯВЛЕННЫЙ выход ставит __DONE=1;
# обрыв доезжает сюда с нулём и не объявленным -- и краснит.
__DONE=0
__exit_guard() {
  __rc=$?
  cleanup_staged
  if [[ "${__DONE:-0}" != 1 && "$__rc" == 0 ]]; then
    echo "ОТКАЗ: раскатка оборвалась, не дойдя до конца (ошибка оболочки выше)" >&2
    exit 1
  fi
  exit "$__rc"
}
trap __exit_guard EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

stage_one() {  # $1 canon, $2 home, $3 display name
  local A="$1" B="$2" name="$3" src dst tmp
  case "$MODE" in
    --to-home)   src="$A"; dst="$B" ;;
    --from-home) src="$B"; dst="$A" ;;
  esac
  if [[ ! -f "$src" ]]; then
    echo "ОТКАЗ: нет исходника для $name ($src)" >&2
    FAILED=$((FAILED+1))
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  tmp="$dst.sync-new.$$"
  if cp "$src" "$tmp"; then
    STAGE_TMP+=("$tmp"); STAGE_DST+=("$dst"); STAGE_NAME+=("$name")
  else
    rm -f "$tmp"
    echo "ОТКАЗ: не удалось разложить $name ($dst)" >&2
    FAILED=$((FAILED+1))
  fi
  return 0
}

for f in "${PROBE_FILES[@]}";  do add_pair "$ROOT/probes/$f" "$PROBES_HOME/$f" "probes/$f"; done
for f in "${TOOL_FILES[@]}";   do add_pair "$ROOT/judge/$f"  "$TOOLS_HOME/$f"  "judge/$f";  done
# The plist in the canon is a SAMPLE with path placeholders. Rolling it out
# as-is means registering in launchd an agent pointing at /Users/YOUR-USER:
# it would silently never run. We copy only one filled in for this machine.
PLIST_IN_SET=0
if grep -q 'YOUR-USER' "$ROOT/judge/$PLIST_NAME" 2>/dev/null; then
  [[ "$MODE" == "--to-home" ]] && \
    echo "!! $PLIST_NAME не раскатан: в каноне образец с /Users/YOUR-USER — заполните пути под себя"
  [[ "$MODE" == "--diff" ]] && echo "(plist в каноне — образец с плейсхолдерами, сравнение с домом не имеет смысла)"
  true
else
  add_pair "$ROOT/judge/$PLIST_NAME" "$PLIST_HOME" "$PLIST_NAME"
  PLIST_IN_SET=1
fi

__pairs=${#PAIR_A[@]}
if [[ "$MODE" == "--diff" ]]; then
  for ((__i=0; __i<__pairs; __i++)); do
    diff_one "${PAIR_A[$__i]}" "${PAIR_B[$__i]}" "${PAIR_N[$__i]}"
  done
else
  for ((__i=0; __i<__pairs; __i++)); do
    stage_one "${PAIR_A[$__i]}" "${PAIR_B[$__i]}" "${PAIR_N[$__i]}"
  done
  if [[ "$FAILED" -ne 0 ]]; then
    cleanup_staged
    echo "ОТКАЗ: набор разложен не целиком (не готово файлов: $FAILED из $__pairs) — не перенесено НИЧЕГО" >&2
    echo "  Половина набора в доме хуже отсутствия раскатки: она не объявляет себя ничем." >&2
    __DONE=1; exit 1
  fi
  __moved=0
  for ((__i=0; __i<${#STAGE_TMP[@]}; __i++)); do
    if mv "${STAGE_TMP[$__i]}" "${STAGE_DST[$__i]}"; then
      __moved=$((__moved+1))
      [[ "$MODE" == "--to-home" ]] && echo "-> ${STAGE_NAME[$__i]}" || echo "<- ${STAGE_NAME[$__i]}"
    else
      echo "ОТКАЗ: не удалось ввести ${STAGE_NAME[$__i]} (${STAGE_DST[$__i]})" >&2
      echo "  ДОМ СМЕШАН: введено файлов $__moved из ${#STAGE_TMP[@]}; остальные остались прежними." >&2
      echo "  Что именно разошлось, покажет: bash $0 --diff" >&2
      FAILED=$((FAILED+1))
      cleanup_staged
      __DONE=1; exit 1
    fi
  done
  STAGE_TMP=()
  [[ "$PLIST_IN_SET" -eq 1 && "$MODE" == "--to-home" ]] && \
    echo "   (plist обновлён — нужен launchctl bootout+bootstrap)"
  true
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
    __DONE=1; exit 1
  fi
  if [[ "$PRESENT" -eq 0 && "$ABSENT" -ne 0 ]]; then
    echo "ИТОГ: на этой машине не раскатано ничего ($ABSENT файлов) — мерить нечего" >&2
    __DONE=1; exit 5
  fi
  if [[ "$ABSENT" -ne 0 ]]; then
    echo "ИТОГ: раскатка неполная, нет файлов: $ABSENT (раскатать: bash $0 --to-home)" >&2
    __DONE=1; exit 1
  fi
  __DONE=1; exit 0
fi

# Код возврата -- часть отчёта: раскатка, у которой не нашлось части файлов,
# прежде заканчивалась `exit 0`, и вызывающий (в том числе рецепт в хвосте
# конвейера) не мог отличить её от полной. Обе ветки копирования выходят выше --
# и на неразложенном наборе, и на сбое ввода; хвост держит контракт кода
# возврата на случай, если появится третья.
if [[ "$FAILED" -ne 0 ]]; then
  echo "ИТОГ: не перенесено файлов: $FAILED" >&2
  __DONE=1; exit 1
fi
__DONE=1; exit 0
