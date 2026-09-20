#!/usr/bin/env bash
# Syncing probe files between the CANON (this project) and the DEPLOYMENT.
#
# The direction is named explicitly, always: a one-way copy "wherever it lands"
# once already diverged the archive from the source, and it was found by accident.
#   --to-home    canon -> home  (roll out an edit)
#   --from-home  home  -> canon (pick up an edit made in place)
#   --diff       show divergences, touching nothing (default)
#   --list       name the SET, one canon-relative path per line, touch nothing
#
# --list exists so that no consumer has to keep its own copy of the set. The
# judge-tools bench used to carry one (a hard-coded list of seven names plus
# the number 11) and it went stale the same day four tools entered the set
# (#193): the bench then reddened on ITS OWN incompleteness while claiming to
# measure the roll-out. A list living next to its home must either be read from
# the home or not exist. --list runs BEFORE the lock is taken: naming the set
# writes nothing, and a reader must not be refused because a writer is busy.
#
# Exit codes (a subset of the kit-wide table -- see the claude-patch-all.sh
# header): 0 -- in sync (or the copy went through); 1 -- divergences found in
# --diff, or files were missed in a copy mode; 2 -- unknown mode; 3 -- another
# live writer holds the sync lock (flock, lock directory, or it has just won
# the takeover race), retry later; 5 -- nothing to measure: this machine has no
# deployment at all; 6 -- the lock machinery is broken: the lock file itself
# cannot be opened. The return code is part of the report: --diff used to print
# "расходится: X" and exit 0, so a gate hung on it stayed green (round 18, F-10).
# Death by signal is answered as 128+N (130 INT, 143 TERM, via the split
# traps) and is NOT a kit verdict (round 28, F-8).
# 130 arrives when INT is delivered to the process GROUP (what a terminal does
# on Ctrl-C); `kill -INT <script pid>` while a foreground child is alive is
# dropped by bash -- the child runs to completion, the trap does NOT fire, and
# the run finishes with its ordinary code. Nothing is truncated, so that code
# is honest; but probing 130 with a single-pid kill yields the false
# conclusion "the trap is broken" (measured, round 25, F-6).
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
# CONSTRAINT: платформа владельца расписания -- ЖИВОЙ признак (uname -s), а не
# вывод из пути. Дверца CLAUDE_SCHEDULE_PLATFORM обязательна: без неё ветка
# чужой платформы мертва на этой машине всегда, и зуб стенда в мёртвой ветке
# ничего не меряет (#237).
SCHEDULE_PLATFORM="${CLAUDE_SCHEDULE_PLATFORM:-$(uname -s)}"
# CONSTRAINT: crontab зовётся ТОЛЬКО этой командой и ТОЛЬКО чтением (`-l`);
# подмена -- CLAUDE_CRONTAB_CMD для стенда, боевые таблицы сверка не пишет.
CRONTAB_CMD="${CLAUDE_CRONTAB_CMD:-crontab}"

# pairs of "path in the canon : path in the home", the home is filled in by group
PROBE_FILES=(probes.toml judge/prompt.md judge/body.json idle-watch/prompt.md)
# CONSTRAINT: перечень -- ПРОЕКЦИЯ, и всё, чего в нём нет, для раскатки не
# существует вовсе. Измерено 15.09: recstore.py, fresh-runs.py и два зуба
# (bench/) прожили в доме, НЕ попав в репозиторий, потому что имён не было
# здесь; гейт раскатки молчал -- он сверяет только перечисленное. Ценз
# «есть в доме, нет в каноне» ниже закрывает ту же дыру со стороны дома:
# новый инструмент теперь называется, а не оседает молча.
TOOL_FILES=(replay.py compact.py validate.py channel.py adjudicate.py recstore.py fresh-runs.py README.md)
# Зубы инструментов -- свой набор: они живут подкаталогом, и без них правка
# инструмента уезжает в дом без того, что её краснит.
TOOL_BENCH_FILES=(bench/test_recstore.py bench/test_line_from_mod.py)

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
# CONSTRAINT: набор проб владельца расписания -- ОДИН дом для ОБОИХ своих
# потребителей: сверки покрытия владельцем и счёта предмета прополки. Литерал
# пробы в одном из двух мест разошёлся бы с другим при появлении третьей пробы.
SCHEDULE_PROBES="judge failover"

MODE="${1:---diff}"
case "$MODE" in --to-home|--from-home|--diff|--list) ;; *) echo "не понял режим: $MODE" >&2; __DONE=1; exit 2 ;; esac

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
# Индексы РАСХОДИВШИХСЯ пар: итоговая ветка знает не только счёт, но и КАКИЕ
# пары разошлись -- доказательство направления идёт по этому списку, а не по
# числу, которое смешивает файлы со стадиями и цензами.
DIFF_IDX=()

# Набор пар собирается ЦЕЛИКОМ до первой записи: и сверка, и раскатка идут по
# одному списку, а раскатка обязана быть всё-или-ничего.
PAIR_A=(); PAIR_B=(); PAIR_N=()
add_pair() { PAIR_A+=("$1"); PAIR_B+=("$2"); PAIR_N+=("$3"); }

diff_one() {  # $1 canon, $2 home, $3 display name, $4 pair index
  if [[ ! -f "$2" ]]; then
    echo "не раскатан: $3"; ABSENT=$((ABSENT+1))
  elif diff -q "$1" "$2" >/dev/null 2>&1; then
    PRESENT=$((PRESENT+1))
  else
    echo "расходится: $3"; DIFFERS=$((DIFFERS+1)); DIFF_IDX+=("$4")
  fi
}

# CONSTRAINT: потолок опрошенных предков -- КОНСТАНТА. Неограниченный обход на
# длинной истории превращает быструю сверку в минуты; файл, равный предку
# глубже потолка, остаётся недоказанным (прежний двунаправленный текст, НЕ
# отказ -- отсутствие доказательства поведением не хуже прежнего).
DIRECTION_HISTORY_LIMIT=200
# Доказательство направления для одной РАСХОДИВШЕЙСЯ пары -- ВЫЧИСЛИМОЕ
# подмножество неразрешимого общего случая: байты дома, побайтово равные
# ПРЕДКУ файла в истории канона, доказывают, что дом есть ПРОШЛОЕ канона, и
# правок в доме нет ПО ПОСТРОЕНИЮ. Отказы опросов истории (нет коммита, нет
# пути, битый репозиторий) -- НЕ событие для читателя: незачёт молча.
# CONSTRAINT: дайджест обеих сторон считает ОДИН инструмент прогона
# ($__digest_tool, выбирается в ветке итога до первого вызова); сравнение
# дайджестов, а не размеров -- файлы одного объёма не равны побайтово.
prove_direction_one() {  # $1 индекс пары; 0 -- направление доказано и названо
  local __a __rel __log __home_d __sha __blob_d __iso
  __a="${PAIR_A[$1]}"
  __rel="${__a#"$ROOT"/}"
  __log=$(git -C "$ROOT" log -n "$DIRECTION_HISTORY_LIMIT" --format=%H -- "$__rel" 2>/dev/null) || __log=''
  [[ -n "$__log" ]] || return 1
  __home_d=$($__digest_tool "${PAIR_B[$1]}" 2>/dev/null) || return 1
  __home_d="${__home_d%% *}"
  while IFS= read -r __sha; do
    [[ -n "$__sha" ]] || continue
    __blob_d=$(git -C "$ROOT" show "$__sha:$__rel" 2>/dev/null | $__digest_tool) || continue
    __blob_d="${__blob_d%% *}"
    if [[ "$__blob_d" == "$__home_d" ]]; then
      __iso=$(git -C "$ROOT" show -s --format=%cI "$__sha" 2>/dev/null) || __iso=''
      printf 'направление ДОКАЗАНО: %s в доме равен канону на %s (%s) -- правок В ДОМЕ нет\n' \
        "${PAIR_N[$1]}" "${__sha:0:12}" "${__iso:-дата не получена}"
      return 0
    fi
  done <<<"$__log"
  return 1
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
STAGE_TMP=(); STAGE_DST=(); STAGE_NAME=(); STAGE_OWNER=()
cleanup_staged() {
  local __i
  for ((__i=0; __i<${#STAGE_TMP[@]}; __i++)); do
    rm -f "${STAGE_TMP[$__i]}" "${STAGE_OWNER[$__i]}"
  done
  STAGE_TMP=(); STAGE_OWNER=()
}
# Часовой оборванного прогона: bash 3.2 отдаёт код 0, когда скрипт с EXIT-трапом
# умирает на фатальной ошибке ПОДСТАНОВКИ (unbound под `set -u`, `${x:?}`, bad
# substitution) -- трап исполняется, `$?` внутри него ноль, и вызывающий видит
# успех вместо обрыва. Гейт этой формы (правило 3) поймал скрипт сразу после
# того, как у него появился трап. Каждый ОБЪЯВЛЕННЫЙ выход ставит __DONE=1;
# обрыв доезжает сюда с нулём и не объявленным -- и краснит.
__DONE=0
__SYNC_LOCKDIR_OWNED=0
__exit_guard() {
  __rc=$?
  # Часовой контекста исполнителя ловушки: bash 5.2 исполняет EXIT-трап
  # В ПОДОБОЛОЧКЕ, когда фоновый потомок умирает от перехватываемого сигнала
  # (#237) -- без предиката тело сносило бы рабочий каталог среди прогона.
  # В bash 4.0+ BASHPID в подоболочке отличен от $$ (PID главного процесса).
  # В bash без BASHPID (3.2) PID исполняющей трап оболочки добывается форком:
  # PPID ребёнка подстановки -- PID нашей оболочки. Контекст -- ТРИ исхода:
  # главный / подоболочка / НЕ ОПРЕДЕЛЁН. Упавший или пустой форк обязан
  # считаться главным процессом (молчаливый невыход главного дороже редкой
  # уборки в подоболочке: вред требует совпадения двух независимых редкостей)
  # и объявляться именной строкой в stderr -- отказ инструмента не имеет
  # права одеваться в вердикт. Выход из ветки подоболочки -- return, не
  # exit: код выхода подоболочки менять мы права не имеем. Форк исполняется
  # один раз за выход и только на bash без BASHPID.
  if [[ -n "${BASHPID:-}" ]]; then
    [[ "$BASHPID" != "$$" ]] && return
  else
    __guard_ctx=$(exec sh -c 'echo $PPID') || __guard_ctx=
    if [[ -n "$__guard_ctx" && "$__guard_ctx" != "$$" ]]; then
      return
    fi
    [[ -z "$__guard_ctx" ]] && echo "ЧАСОВОЙ КОНТЕКСТА НЕ ОПРЕДЕЛЁН (форк PPID не дал ответа) -- продолжаю уборку как главный процесс" >&2
  fi
  # Однократность: повторный вход ловушки уборки не делает.
  trap - EXIT
  cleanup_staged
  if [[ "${__SYNC_LOCKDIR_OWNED:-0}" == 1 ]]; then
    rm -rf "$SYNC_LOCKDIR"
    __SYNC_LOCKDIR_OWNED=0
  fi
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
  local A="$1" B="$2" name="$3" src dst tmp owner owner_start
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
  owner="$dst.sync-owner.$$"
  owner_start="$(LC_ALL=C ps -o lstart= -p $$ 2>/dev/null)" || { printf 'ПРИБОР НЕДОСТУПЕН: не получено время старта процесса-писателя\n' >&2; exit 2; }
  # Владелец пишется ДО стадии: существующая стадия без владельца тем самым
  # однозначно принадлежит оборванному писателю. Другой инфикс обязателен:
  # sync-owner не попадает в глоб sync-new.* и не становится ложной стадией.
  if ! printf '%s\t%s\n' "$$" "$owner_start" > "$owner"; then
    echo "ОТКАЗ: не записать владельца стадии для $name ($owner)" >&2
    FAILED=$((FAILED+1))
    return 0
  fi
  if cp "$src" "$tmp"; then
    STAGE_TMP+=("$tmp"); STAGE_DST+=("$dst"); STAGE_NAME+=("$name"); STAGE_OWNER+=("$owner")
  else
    rm -f "$tmp" "$owner"
    echo "ОТКАЗ: не удалось разложить $name ($dst)" >&2
    FAILED=$((FAILED+1))
  fi
  return 0
}

for f in "${PROBE_FILES[@]}";  do add_pair "$ROOT/probes/$f" "$PROBES_HOME/$f" "probes/$f"; done
for f in "${TOOL_FILES[@]}";   do add_pair "$ROOT/judge/$f"  "$TOOLS_HOME/$f"  "judge/$f";  done
for f in "${TOOL_BENCH_FILES[@]}"; do add_pair "$ROOT/judge/$f" "$TOOLS_HOME/$f" "judge/$f"; done

# Дом словарей вердиктов едет ОТДЕЛЬНОЙ парой, а не строкой TOOL_FILES:
# тот список задан относительно $ROOT/judge, а этот файл лежит в корне
# кита. Без него раскатанный replay.py читать нечего -- он отказывает
# кодом 2, и раскатанный судья остаётся без словаря (волна 40b).
add_pair "$ROOT/tweakcc-patch.js" "$TOOLS_HOME/tweakcc-patch.js" "tweakcc-patch.js"

# Замок лежит при том доме, который инструмент РЕАЛЬНО пишет, а не при доме,
# вычисленном из CLAUDE_CONFIG_DIR (круг 25, замер контроллера). Стенд
# подменяет все три каталога записи (CLAUDE_PROBES_DIR, CLAUDE_JUDGE_TOOLS_DIR,
# CLAUDE_LAUNCH_AGENTS_DIR) и раскатывает в игрушечный дом -- а замок брался от
# CLAUDE_HOME_DIR, то есть БОЕВОЙ. Отсюда обе беды: игрушечный прогон стенда
# отказывал настоящей раскатке («держит другой писатель»), а настоящая
# раскатка роняла сценарий стенда. Ключ замка обязан совпадать с объектом,
# который он защищает.
#
# dirname от PROBES_HOME, а не сам PROBES_HOME: каталог дома может ещё не
# существовать, а замок открывается ДО раскатки. При умолчаниях путь тот же,
# что и был (dirname ~/.claude/probes = ~/.claude), поэтому боевой замок
# остаётся на своём месте и старые держатели видны новым.
#
# Ключ ведётся по дому ПРОБ: остальные два каталога в любом реальном вызове
# переезжают вместе с ним (это одна раскатка), а раздельный перенос только
# одного из них -- случай стенда, где дома всё равно игрушечные.
SYNC_LOCK="${PROBES_SYNC_LOCK:-$(dirname "$PROBES_HOME")/probes-sync.lock}"
SYNC_LOCKDIR="$SYNC_LOCK.d"
acquire_sync_lock() {
  local __held=0 __rc=0 __owner __confirm __opid __ostart __stale_dir __cpid
  mkdir -p "$(dirname "$SYNC_LOCK")"
  exec 7>"$SYNC_LOCK" || { echo "ОТКАЗ: не открыть замок синхронизации $SYNC_LOCK" >&2; exit 6; }
  if command -v flock >/dev/null 2>&1; then
    if flock -n 7; then
      __held=1
    else
      __rc=$?
      if [[ $__rc -eq 1 ]]; then
        echo "ОТКАЗ: другой писатель синхронизации держит $SYNC_LOCK (узнать держателя: lsof $SYNC_LOCK)" >&2
        exit 3
      fi
      echo "NOTE: flock(1) не сработал (rc=$__rc) -- пробую perl" >&2
    fi
  fi
  if [[ $__held -eq 0 ]]; then
    if perl -e 'use Fcntl ":flock"; open(my $fh, ">&=7") or exit 2;
                exit(flock($fh, LOCK_EX|LOCK_NB) ? 0 : 1);'; then
      __held=1
    else
      __rc=$?
      if [[ $__rc -eq 1 ]]; then
        echo "ОТКАЗ: другой писатель синхронизации держит $SYNC_LOCK (узнать держателя: lsof $SYNC_LOCK)" >&2
        exit 3
      fi
      echo "NOTE: perl flock(2) не сработал (rc=$__rc) -- беру каталог-замок" >&2
    fi
  fi
  if [[ $__held -eq 0 ]]; then
    if ! mkdir "$SYNC_LOCKDIR" 2>/dev/null; then
      __owner=''
      for _ in 1 2 3 4 5; do
        __owner=$(cat "$SYNC_LOCKDIR/pid" 2>/dev/null || true)
        [[ -n "$__owner" ]] && break
        sleep 0.2
      done
      # Владелец записывается парой: pid + время старта процесса
      # (LC_ALL=C ps -o lstart=). Живость по одному kill -0 верит
      # переиспользованному номеру: держатель мёртв, номер достался чужому
      # процессу -- и замок стоял бы вечно. pid без метки (файл прежней
      # редакции) живость не опровергает: тогда решает один kill -0.
      __opid="${__owner%%$'\t'*}"
      # Строка БЕЗ таба -- формат прежней редакции: метки нет, и подстановка
      # вернула бы всю строку; пустая метка возвращает решение kill -0.
      __ostart="${__owner#*$'\t'}"
      [[ "$__ostart" == "$__owner" ]] && __ostart=''
      __stale_dir=1
      if [[ -n "$__opid" ]] && kill -0 "$__opid" 2>/dev/null; then
        __ps_lstart="$(LC_ALL=C ps -o lstart= -p "$__opid" 2>/dev/null)" || __ps_lstart_rc=$?
        [ "${__ps_lstart_rc:-0}" -le 1 ] || { printf 'ПРИБОР НЕДОСТУПЕН: не прочитать время старта держателя замка (код %s)\n' "$__ps_lstart_rc" >&2; exit 2; }
        __ps_lstart_rc=0
        if [[ -z "$__ostart" ]] \
           || [[ "$__ps_lstart" == "$__ostart" ]]; then
          __stale_dir=0
        fi
      fi
      if (( __stale_dir )); then
        # За номером никого нет -- замок протух, берём его.
        rm -rf "$SYNC_LOCKDIR"
        mkdir "$SYNC_LOCKDIR" 2>/dev/null || {
          echo "ОТКАЗ: гонка за каталог-замок $SYNC_LOCKDIR -- его только что взял другой живой писатель" >&2
          exit 3; }
      else
        echo "ОТКАЗ: другой писатель синхронизации держит $SYNC_LOCKDIR (pid $__opid)" >&2
        exit 3
      fi
    fi
    printf '%s\t%s\n' "$$" "$(LC_ALL=C ps -o lstart= -p "$$" 2>/dev/null)" > "$SYNC_LOCKDIR/pid"
    sleep 0.3
    __confirm=$(cat "$SYNC_LOCKDIR/pid" 2>/dev/null || true)
    __cpid="${__confirm%%$'\t'*}"
    if [[ "$__cpid" != "$$" ]]; then
      echo "ОТКАЗ: каталог-замок синхронизации перехвачен pid ${__cpid:-неизвестен}" >&2
      exit 3
    fi
    __SYNC_LOCKDIR_OWNED=1
  fi
}

for_each_sync_stage() {  # $1 -- функция-потребитель пути
  local __fn="$1" __i __stage
  # Обходятся ОБЕ стороны независимо от режима текущего прогона:
  # --from-home кладёт стадии на КАНОННУЮ сторону (dst="$A",
  # дерево репозитория), и обход одной домашней стороны
  # оставлял бы обломок в дереве навсегда -- прополка его не видит,
  # --diff о нём молчит. Обломок остаётся от ПРОШЛОГО прогона,
  # чей режим сегодняшнему прогону неизвестен.
  for ((__i=0; __i<${#PAIR_A[@]}; __i++)); do
    for __stage in "${PAIR_A[$__i]}.sync-new."*; do
      [[ -e "$__stage" ]] || continue
      "$__fn" "$__stage"
    done
  done
  for ((__i=0; __i<${#PAIR_B[@]}; __i++)); do
    for __stage in "${PAIR_B[$__i]}.sync-new."*; do
      [[ -e "$__stage" ]] || continue
      "$__fn" "$__stage"
    done
  done
}

sync_stage_owner() {  # стадия; печатает путь файла-владельца
  local __stage="$1" __pid="${1##*.sync-new.}"
  printf '%s.sync-owner.%s' "${__stage%.sync-new.*}" "$__pid"
}
sync_stage_writer_alive() {  # стадия; pid жив И время старта принадлежит писателю
  local __stage="$1" __pid="${1##*.sync-new.}" __owner __line __owner_pid __owner_start __now
  case "$__pid" in ''|*[!0-9]*) return 1 ;; esac
  # Путь владельца — сборка из пути стадии; пустой/отказ проверяет [[ -f ]] ниже штатным «писатель неизвестен».
  __owner=$(sync_stage_owner "$__stage") || true
  [[ -f "$__owner" ]] || return 1
  __line=$(cat "$__owner" 2>/dev/null) || return 1
  __owner_pid="${__line%%$'\t'*}"
  __owner_start="${__line#*$'\t'}"
  [[ "$__owner_start" != "$__line" && "$__owner_pid" == "$__pid" ]] || return 1
  kill -0 "$__pid" 2>/dev/null || return 1
  # Пустой lstart — штатно: процесс уже не тот (умер или номер переиспользован);
  # равенство ниже не сходится, функция сообщает «не жив».
  __now="$(LC_ALL=C ps -o lstart= -p "$__pid" 2>/dev/null)" || true
  [[ "$__now" == "$__owner_start" ]]
}
prune_one_sync_stage() {
  local __stage="$1" __pid="${1##*.sync-new.}" __owner
  case "$__pid" in ''|*[!0-9]*) return 0 ;; esac
  # Путь владельца — сборка из пути стадии; прополка зовёт alive ниже и без файла-владельца считает писателя мёртвым.
  __owner=$(sync_stage_owner "$__stage") || true
  if ! sync_stage_writer_alive "$__stage"; then
    rm -f "$__stage" "$__owner" && echo "убрана осиротевшая стадия: $__stage"
  fi
}
prune_sync_stages() { for_each_sync_stage prune_one_sync_stage; }
report_one_sync_stage() {
  local __pid="${1##*.sync-new.}"
  # Стадия ЖИВОГО писателя -- не расхождение: параллельный --diff во время
  # идущей синхронизации красил бы живого писателя и вешал ложный
  # красный на гейт. Живость -- та же тройка, что у прополки: файл-владелец,
  # живой pid и совпавшее время старта. Один kill -0 верит чужому процессу,
  # которому достался номер уже умершего писателя.
  if sync_stage_writer_alive "$1"; then
    echo "(стадия живого писателя pid $__pid -- идёт, не расхождение)"
  else
    echo "расходится: стадия синхронизации осталась: $1"
    DIFFERS=$((DIFFERS+1))
  fi
}
report_sync_stages() { for_each_sync_stage report_one_sync_stage; }
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

# Второй образец plist — агент синкрона цен по смене каталога прокси (#53).
# Механизм ТОТ ЖЕ, что у judge-compact выше: дом образцов один (judge/),
# установка — осознанным шагом заполненной копией в ~/Library/LaunchAgents.
# CONSTRAINT: отсутствующий образец исключается из набора НАРЯВНЕ с образцом
# с плейсхолдерами. Стенд синхронизации строит игрушечный канон по --list ДО
# того, как положит этот файл, и у judge-compact дыра закрыта заглушкой в
# самом стенде; здесь закрытие живёт в самом правиле, чтобы отсутствующий
# файл не вводил пару, чья канонная сторона не существует.
MODEL_COSTS_PLIST_NAME=com.maratkarimov.model-costs-sync.plist
MODEL_COSTS_PLIST_IN_SET=0
if [[ -f "$ROOT/judge/$MODEL_COSTS_PLIST_NAME" ]] \
   && ! grep -q 'YOUR-USER' "$ROOT/judge/$MODEL_COSTS_PLIST_NAME"; then
  add_pair "$ROOT/judge/$MODEL_COSTS_PLIST_NAME" \
           "$LAUNCH_AGENTS_DIR/$MODEL_COSTS_PLIST_NAME" "$MODEL_COSTS_PLIST_NAME"
  MODEL_COSTS_PLIST_IN_SET=1
else
  [[ "$MODE" == "--to-home" ]] && \
    echo "!! $MODEL_COSTS_PLIST_NAME не раскатан: образец отсутствует или несёт /Users/YOUR-USER — заполните пути под себя"
  [[ "$MODE" == "--diff" ]] && echo "($MODEL_COSTS_PLIST_NAME в каноне — образец с плейсхолдерами, сравнение с домом не имеет смысла)"
  true
fi

__pairs=${#PAIR_A[@]}

# Набор назван ЗДЕСЬ и только здесь: место выбрано после пары plist -- она
# добавляется условно, и перечень, снятый раньше, соврал бы на машине с
# заполненным образцом.
if [[ "$MODE" == "--list" ]]; then
  if [[ "$__pairs" -eq 0 ]]; then
    echo "ОТКАЗ: набор пуст -- перечислять нечего" >&2
    __DONE=1
    exit 1
  fi
  for ((__i=0; __i<__pairs; __i++)); do printf '%s\n' "${PAIR_N[$__i]}"; done
  __DONE=1
  exit 0
fi

if [[ "$MODE" == "--diff" ]]; then
  report_sync_stages
  for ((__i=0; __i<__pairs; __i++)); do
    diff_one "${PAIR_A[$__i]}" "${PAIR_B[$__i]}" "${PAIR_N[$__i]}" "$__i"
  done
else
  acquire_sync_lock
  prune_sync_stages
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
      rm -f "${STAGE_OWNER[$__i]}"
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
  STAGE_TMP=(); STAGE_OWNER=()
  [[ "$PLIST_IN_SET" -eq 1 && "$MODE" == "--to-home" ]] && \
    echo "   (plist обновлён — нужен launchctl bootout+bootstrap)"
  [[ "$MODEL_COSTS_PLIST_IN_SET" -eq 1 && "$MODE" == "--to-home" ]] && \
    echo "   ($MODEL_COSTS_PLIST_NAME обновлён — нужен launchctl bootout+bootstrap)"
  true
fi

# Имя файла plist -- личное дело машины: launchd берёт метку из содержимого, а
# канон держит ОБРАЗЕЦ с плейсхолдерами. Сверять фиксированное КАНОНИЧЕСКОЕ имя
# с домом бессмысленно вдвойне: такого файла в доме нет никогда, и нога молчала
# всегда. Проверяемо и важно другое -- КУДА показывает реально заведённый агент:
# исполняются те байты, на которые он указывает, а не те, что заверил стенд.
# Владелец расписания -- функция ПЛАТФОРМЫ (Darwin: launchd-агент; Linux:
# пользовательский crontab; прочее -- НАЗВАННОЕ расхождение, не молчание) и
# ПРЕДМЕТА: зелёным без владельца может быть только машина, где нет и
# предмета прополки, -- иначе молчание неотличимо от исправности.
sched_cover_check() {  # $1 подпись владельца в строках отчёта, $2 строка аргументов вызова
  local __who="$1" __args="$2" __probe
  for __probe in $SCHEDULE_PROBES; do
    if grep -q -- '--probe' <<<"$__args" && grep -qF "$__probe" <<<"$__args"; then
      echo "$__who покрывает пробу $__probe"
    else
      echo "расходится: $__who не покрывает пробу $__probe"
      DIFFERS=$((DIFFERS+1))
    fi
  done
}
if [[ "$MODE" == "--diff" ]]; then
  __sched_owners=0
  __sched_owner_known=1
  __sched_owner_kind='launchd-агент'
  case "$SCHEDULE_PLATFORM" in
    Darwin)
      for __pl in "$LAUNCH_AGENTS_DIR"/*judge-compact.plist; do
        [[ -f "$__pl" ]] || continue
        __sched_owners=$((__sched_owners+1))
        if grep -qF "$TOOLS_HOME/compact.py" "$__pl"; then
          echo "агент $(basename "$__pl") запускает раскатанный compact.py"
        else
          echo "расходится: агент $(basename "$__pl") запускает НЕ $TOOLS_HOME/compact.py"
          DIFFERS=$((DIFFERS+1))
        fi
        # Вторая проверка ТОГО ЖЕ агента -- покрытие ПРОБ (волна 227b): сверка цели
        # видит только путь к инструменту, и машина, где агент остался на умолчании
        # judge, выглядела зелёной, а журнал лестницы failover не пропалывал никто.
        # Сверяются ИМЕННО элементы <string> блока ProgramArguments: слово пробы
        # в XML-комментарии внутри массива ничего не доказывает -- аргумент обязан
        # назвать пробу, а владелец прополки один на все журналы. `|| true` обязателен:
        # под set -e код подстановки становится кодом присваивания, и plist без
        # блока аргументов ронял бы всю сверку вместо красной строки о непокрытии
        # (fail-closed -- пустой набор аргументов красит).
        __args=$(sed -n '/<key>ProgramArguments<\/key>/,/<\/array>/p' "$__pl" \
                 | grep -o '<string>[^<]*</string>' || true)
        sched_cover_check "агент $(basename "$__pl")" "$__args"
      done
      ;;
    Linux)
      # CONSTRAINT: владелец -- именно пользовательский crontab, а не таймер
      # `systemctl --user`: при Linger=no пользовательские таймеры не переживают
      # выход из сессии и простаивают молча, тогда как crond на площадке
      # active+enabled и не требует ни прав администратора, ни включения linger
      # (замер 17.09, Catalyst-programs/2026-09-17-linux-schedule-owner-235/
      # MEASURE-linux-journals-235.md).
      __cron_rc=0
      __cron_out="$("$CRONTAB_CMD" -l)" || __cron_rc=$?
      if [[ "$__cron_rc" -ne 0 && "$__cron_rc" -ne 1 ]]; then
        # Код 1 у crontab -l -- ШТАТНОЕ «таблицы нет»; любой иной код -- отказ
        # прибора, и неизмеримое не имеет права быть зелёным (fail-closed).
        printf 'ПРИБОР НЕДОСТУПЕН: crontab -l вернул код %s\n' "$__cron_rc"
        DIFFERS=$((DIFFERS+1))
        __sched_owner_known=0
      else
        while IFS= read -r __cline; do
          [[ "$__cline" == *"$TOOLS_HOME/compact.py"* ]] || continue
          __sched_owners=$((__sched_owners+1))
          echo "расписание crontab запускает раскатанный compact.py"
          sched_cover_check 'расписание crontab' "$__cline"
        done <<<"$__cron_out"
      fi
      __sched_owner_kind='пользовательский crontab'
      ;;
    *)
      __sched_owner_known=0
      echo "расходится: прибор не знает владельца расписания для платформы $SCHEDULE_PLATFORM"
      DIFFERS=$((DIFFERS+1))
      ;;
  esac
  if [[ "$__sched_owner_known" -eq 1 && "$__sched_owners" -eq 0 ]]; then
    # Счёт предмета -- ЖИВОЙ: файлы records и шарды журнала по каждой пробе
    # набора; отсутствие каталога -- ноль, а не ошибка (машина без пробы
    # законна). ПУСТО != НОЛЬ: числа печатаются в обеих строках вердикта.
    __sched_rec=0
    __sched_shard=0
    for __p in $SCHEDULE_PROBES; do
      if [[ -d "$PROBES_HOME/$__p/records" ]]; then
        for __rf in "$PROBES_HOME/$__p/records"/*; do
          if [[ -f "$__rf" ]]; then __sched_rec=$((__sched_rec+1)); fi
        done
      fi
      for __sh in "$PROBES_HOME/$__p"/journal.jsonl.shard.*; do
        if [[ -f "$__sh" ]]; then __sched_shard=$((__sched_shard+1)); fi
      done
    done
    if [[ "$((__sched_rec+__sched_shard))" -gt 0 ]]; then
      echo "расходится: владельца расписания нет, а предмет прополки есть (записей $__sched_rec, шардов $__sched_shard)"
      DIFFERS=$((DIFFERS+1))
    else
      echo "(владельца расписания нет; предмета тоже нет: записей $__sched_rec, шардов $__sched_shard — заводить нечего. Владельцем на $SCHEDULE_PLATFORM будет $__sched_owner_kind)"
    fi
  fi
  echo "(журналы, записи и метки не синхронизируются — они данные машины, а не исходник)"
fi

# ЦЕНЗ СО СТОРОНЫ ДОМА. Пары выше -- ПРОЕКЦИЯ канона: инструмент, которого в
# перечне нет, для них не существует, и «расхождений 0» ничего о нём не
# говорит. Измерено 15.09: recstore.py, fresh-runs.py и два зуба прожили
# только в доме, не попав в репозиторий вовсе, -- потеря машины унесла бы их,
# а раскатка --to-home снесла бы. Ценз идёт от ДОМА и называет исходники,
# которых канон не знает. Данные машины (журналы, записи, метки, кэш, снимки
# запросов и личный config.json) исходником не являются и в ценз не входят.
#
# «Лежит в каталоге канона» и «живёт в репозитории» -- РАЗНЫЕ утверждения, и
# ценз по первому даёт ложное зелёное ровно в том случае, ради которого он
# написан: `.gitignore` нёс строку `judge/bench/` (под записи прогонов), и
# положенные рядом зубы были невидимы git, оставаясь видимыми find. Поэтому
# вторая нога спрашивает git. Ответа git нет (кит, распакованный вне
# репозитория) -- это НЕ ИЗМЕРЕНО и говорится вслух, а не молчаливое зелёное.
HOME_ONLY=0
UNTRACKED=0
CHECKED=0
if [[ "$MODE" == "--diff" && -d "$TOOLS_HOME" ]]; then
  # `|| true` ОБЯЗАТЕЛЕН обеим пробам: под `set -e` код командной подстановки
  # становится кодом присваивания, и «канон не в репозитории» (git отдаёт 128)
  # ронял бы весь скрипт вместо честного НЕ ИЗМЕРЕНО; grep -c отдаёт 1 на нуле
  # совпадений -- ровно тот случай, ради которого написан положительный контроль.
  __git_probe=$( (cd "$ROOT" && git rev-parse --is-inside-work-tree) 2>&1 ) || true
  __tracked_seen=$( (cd "$ROOT" && git ls-files -- judge) 2>&1 | grep -c . ) || true
  TRACK_CENSUS='да'
  __track_src='git'
  __wit_head=''
  __wit_paths=''
  if [[ "$__git_probe" != "true" ]]; then
    if [[ -z "${CATALYST_TRACKED_WITNESS:-}" ]]; then
      TRACK_CENSUS='нет'
      echo "ЦЕНЗ РЕПОЗИТОРИЯ: НЕ ИЗМЕРЕНО -- канон не в рабочем дереве git ($__git_probe)"
    else
      # Заказанный свидетель -- прибор, не опция: нет/нечитаем/бит → отказ, не
      # откат к НЕ ИЗМЕРЕНО. Пустой набор путей под judge/ -- слепота, не чистота.
      __wit="$CATALYST_TRACKED_WITNESS"
      if [[ ! -r "$__wit" ]]; then
        printf 'ПРИБОР НЕДОСТУПЕН: свидетель индекса нечитаем: %s\n' "$__wit" >&2
        exit 2
      fi
      __have_tree=0
      __have_head=0
      __have_count=0
      __wit_count=''
      __wit_npaths=0
      while IFS= read -r __wline || [[ -n "$__wline" ]]; do
        case "$__wline" in
          ''|'#'*) continue ;;
          TREE=*) __have_tree=1 ;;
          HEAD=*) __have_head=1; __wit_head="${__wline#HEAD=}" ;;
          COUNT=*) __have_count=1; __wit_count="${__wline#COUNT=}" ;;
          *)
            __wit_npaths=$((__wit_npaths + 1))
            if [[ -n "$__wit_paths" ]]; then
              __wit_paths="${__wit_paths}
${__wline}"
            else
              __wit_paths="$__wline"
            fi
            ;;
        esac
      done < "$__wit"
      if [[ "$__have_tree" -ne 1 || "$__have_head" -ne 1 || "$__have_count" -ne 1 ]]; then
        printf 'ПРИБОР НЕДОСТУПЕН: свидетель индекса битый (нет TREE=/HEAD=/COUNT=): %s\n' "$__wit" >&2
        exit 2
      fi
      if [[ "$__wit_count" != "$__wit_npaths" ]]; then
        printf 'ПРИБОР НЕДОСТУПЕН: свидетель индекса битый (COUNT=%s, путей=%s): %s\n' "$__wit_count" "$__wit_npaths" "$__wit" >&2
        exit 2
      fi
      __wit_judge=0
      if [[ -n "$__wit_paths" ]]; then
        __wit_judge=$(printf '%s\n' "$__wit_paths" | grep -c '^judge/') || true
      fi
      if [[ "$__wit_judge" -eq 0 ]]; then
        TRACK_CENSUS='нет'
        echo "ЦЕНЗ РЕПОЗИТОРИЯ: НЕ ИЗМЕРЕНО -- свидетель снимка не назвал ни одного отслеживаемого файла под judge/ (по свидетелю снимка (HEAD=$__wit_head))"
      else
        TRACK_CENSUS='да'
        __track_src='witness'
      fi
    fi
  elif [[ "$__tracked_seen" -eq 0 ]]; then
    # ПУСТО != НОЛЬ: ценз, которому git не назвал НИ ОДНОГО отслеживаемого
    # файла под judge/, ничего не доказывает -- он слеп, а не чист.
    TRACK_CENSUS='нет'
    echo "ЦЕНЗ РЕПОЗИТОРИЯ: НЕ ИЗМЕРЕНО -- git не назвал ни одного отслеживаемого файла под judge/"
  fi
  while IFS= read -r __rel; do
    [[ -z "$__rel" ]] && continue
    if [[ ! -f "$ROOT/judge/$__rel" ]]; then
      echo "не занесён в канон: judge/$__rel (живёт только в доме инструментов)"
      HOME_ONLY=$((HOME_ONLY+1))
    elif [[ "$TRACK_CENSUS" == 'да' ]]; then
      CHECKED=$((CHECKED+1))
      if [[ "$__track_src" == 'witness' ]]; then
        __git_ls=$(printf '%s\n' "$__wit_paths" | grep -Fx "judge/$__rel") || true
        if [[ -z "$__git_ls" ]]; then
          echo "лежит в каноне, но вне репозитория: judge/$__rel (по свидетелю снимка (HEAD=$__wit_head))"
          UNTRACKED=$((UNTRACKED+1))
        fi
      else
        __git_ls="$( (cd "$ROOT" && git ls-files -- "judge/$__rel") 2>&1 )" || __git_ls_rc=$?
        [ "${__git_ls_rc:-0}" -le 1 ] || { printf 'ПРИБОР НЕДОСТУПЕН: не спросить git об отслеживании judge/%s (код %s)\n' "$__rel" "$__git_ls_rc" >&2; exit 2; }
        __git_ls_rc=0
        if [[ -z "$__git_ls" ]]; then
          echo "лежит в каноне, но вне репозитория: judge/$__rel (git его не отслеживает)"
          UNTRACKED=$((UNTRACKED+1))
        fi
      fi
    fi
  done < <(cd "$TOOLS_HOME" && find . \( -name records -o -name labelled -o -name __pycache__ -o -name fixtures \) -prune -o \
             -type f \( -name '*.py' -o -name '*.md' -o -name '*.sh' \) -print 2>&1 | sed 's|^\./||' | sort)
  if [[ "$HOME_ONLY" -ne 0 ]]; then
    echo "ЦЕНЗ ДОМА: исходников мимо канона: $HOME_ONLY -- занести их в репозиторий"
    echo "  (иначе следующая раскатка --to-home снесёт их, а другая машина их не получит)"
    DIFFERS=$((DIFFERS+HOME_ONLY))
  fi
  # CONSTRAINT: измеренное и чистое ОБЯЗАНО отличаться от неизмеренного. Молчание
  # при нуле нарушений читается как «ценз прошёл» и как «ценз не запускался»
  # одинаково -- поэтому источник и знаменатель называются ВСЕГДА, а не только
  # когда есть о чём ругаться.
  if [[ "$TRACK_CENSUS" == 'да' ]]; then
    if [[ "$__track_src" == 'witness' ]]; then
      echo "ЦЕНЗ РЕПОЗИТОРИЯ: ИЗМЕРЕН по свидетелю снимка (HEAD=$__wit_head): проверено файлов $CHECKED, вне истории $UNTRACKED"
    else
      echo "ЦЕНЗ РЕПОЗИТОРИЯ: ИЗМЕРЕН по git: проверено файлов $CHECKED, вне истории $UNTRACKED"
    fi
  fi
  if [[ "$UNTRACKED" -ne 0 ]]; then
    if [[ "$__track_src" == 'witness' ]]; then
      echo "ЦЕНЗ РЕПОЗИТОРИЯ: исходников вне истории: $UNTRACKED -- добавить их в git (по свидетелю снимка (HEAD=$__wit_head))"
    else
      echo "ЦЕНЗ РЕПОЗИТОРИЯ: исходников вне истории: $UNTRACKED -- добавить их в git"
    fi
    echo "  (файл на диске канона, но не в коммитах: клон репозитория его не несёт)"
    DIFFERS=$((DIFFERS+UNTRACKED))
  fi
fi

# --diff отвечает КЛАССОМ, а не одним «не сошлось»: раскатки нет вовсе (5,
# мерить нечего) -- это не то же самое, что раскатка есть и отличается (1).
if [[ "$MODE" == "--diff" ]]; then
  if [[ "$DIFFERS" -ne 0 ]]; then
    # Обе беды называются В ОДНОЙ строке: ветка расхождения выходит раньше
    # ветки неполноты, и итог сообщал только про расхождение, тогда как
    # выше по потоку стояло ещё и «не раскатан». Класс ответа при этом
    # прежний -- 1, «раскатка есть и отличается».
    # КОНСТРЕЙНТ НАПРАВЛЕНИЯ: из расхождения направление НЕ СЛЕДУЕТ. Сверка
    # знает ровно одно -- байты сторон разные; чья сторона верна, она не знает
    # и знать не может (время файла не свидетель: копия его не сохраняет, а
    # правка законна с любой стороны -- на то и объявлен `--from-home`).
    # Прежняя редакция называла ОДНУ команду, `--to-home`, и на машине, где
    # правка сделана В ДОМЕ, этот совет её уничтожает: отказ вёл читателя в
    # потерю работы. Называются ОБА направления вместе с тем, что теряет
    # каждое, а решает человек. Тот же класс, что «не раскатан» против
    # «расходится»: прибор обязан назвать различие, а не выбрать за читателя.
    __also=""
    [[ "$ABSENT" -ne 0 ]] && __also=", не раскатано: $ABSENT"
    # ВЫЧИСЛИМОЕ подмножество направления (#277): констрейнт выше остаётся в
    # силе для общего случая, но если КАЖДЫЙ расходящийся файл дома побайтово
    # равен ПРЕДКУ канона, дом есть ПРОШЛОЕ канона -- направление доказано и
    # совет один. Механизм -- ТОЛЬКО при живом .git и доступном git: кит без
    # истории (#269) получает прежний текст без единой жалобы, отсутствие
    # доказательства НИКОГДА не ухудшает поведение.
    __proven=0
    if [[ -e "$ROOT/.git" ]] && command -v git >/dev/null 2>&1; then
      __digest_tool=''
      if command -v shasum >/dev/null 2>&1; then __digest_tool='shasum -a 256'
      elif command -v sha256sum >/dev/null 2>&1; then __digest_tool='sha256sum'
      fi
      if [[ -n "$__digest_tool" ]]; then
        for ((__p=0; __p<${#DIFF_IDX[@]}; __p++)); do
          if prove_direction_one "${DIFF_IDX[$__p]}"; then
            __proven=$((__proven+1))
          fi
        done
      fi
    fi
    if [[ "$__proven" -ne 0 && "$__proven" -eq "$DIFFERS" ]]; then
      echo "ИТОГ: расходится файлов: $DIFFERS$__also -- направление ДОКАЗАНО для каждого расходящегося файла" >&2
      echo "  Дом -- ПРОШЛОЕ состояние канона: потеряется только отставание дома, правок В ДОМЕ нет." >&2
      echo "    bash $0 --to-home     канон -> дом" >&2
      echo "  Стороны: канон $ROOT, дом проб $PROBES_HOME, дом инструментов $TOOLS_HOME" >&2
      __DONE=1; exit 1
    fi
    echo "ИТОГ: расходится файлов: $DIFFERS$__also" >&2
    echo "  Направление НЕ выводится из расхождения -- решает человек:" >&2
    echo "    bash $0 --to-home     канон -> дом  (потеряет правки, сделанные В ДОМЕ)" >&2
    echo "    bash $0 --from-home   дом -> канон  (потеряет правки, сделанные В КАНОНЕ)" >&2
    echo "  Стороны: канон $ROOT, дом проб $PROBES_HOME, дом инструментов $TOOLS_HOME" >&2
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
