#!/usr/bin/env bash
# Проба стража «цель против бэкапа tweakcc» и его пост-сверки.
#
# Страж живёт в claude-patch-all.sh и ни одной проверке образа не виден: он
# срабатывает ДО сборки, а проверки читают собранный образ. Без пробы его
# молчание неотличимо от его отсутствия.
#
# Проба НЕ собирает ничего и НЕ трогает настоящий бэкап: она извлекает из
# скрипта ПОДЛИННЫЙ текст (и отказывается, если якорь пропал) и гоняет его по
# таблице случаев с крошечными подставными «образами» -- шелл-скриптами,
# отвечающими на --version. Подмена законна: страж спрашивает у файлов ровно
# версию.
#
# Три вещи, за которые проба отвечает отдельно, потому что каждая уже была
# дырой:
#   * ЗНАЧЕНИЕ OUR_MARKER берётся из скрипта, а не дублируется здесь. Дубль
#     оставлял пробу зелёной при смене маркера, меряющей несуществующее.
#   * УСЛОВИЕ АКТИВАЦИИ. Тело стража лежит внутри `if [[ $ONLY_OURS -eq 0 ]]`.
#     Проба, извлекающая только тело, оставалась зелёной, даже если нормальный
#     путь перестал входить во внешний блок.
#   * ИСХОДОВ ТРИ, а не два: «сработал», «прошёл» и «УМЕР». Раньше смерть
#     стража засчитывалась как правильное молчание -- ровно то, чем оказался
#     неисполнимый образ (rc=126 без единого слова).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../claude-patch-all.sh"
[ -f "$SCRIPT" ] || { echo "нет $SCRIPT" >&2; exit 2; }

# Коды выхода (подмножество общей таблицы кита -- шапка claude-patch-all.sh):
#   0 -- таблица истинности стража сошлась
#   1 -- случай разошёлся с ожиданием (страж молчит там, где обязан отказать,
#        или отказывает чужой причиной), либо прогон оборвался на полпути
#   2 -- прибор не может мерить: якорь вырезки пропал (страж переписан) или
#        случай объявлен без причины отказа
WORK="$(mktemp -d)"
# Часовой оборванного прогона: bash 3.2 отдаёт код 0, когда скрипт с
# EXIT-трапом умирает на фатальной ошибке ПОДСТАНОВКИ (unbound variable под
# `set -u`, `${x:?}`, bad substitution) -- провал невидим вызывающему
# (измерено 2026-08-28). Штатный конец объявляет себя, трап без объявления
# краснит сам.
__DONE=0
__exit_guard() {
  __rc=$?
  rm -rf "$WORK"
  if [[ "${__DONE:-0}" != 1 && "$__rc" == 0 ]]; then
    echo "backup-divergence-probe: ОТКАЗ -- прогон оборвался, не дойдя до конца (ошибка оболочки выше)" >&2
    exit 1
  fi
  exit "$__rc"
}
trap __exit_guard EXIT INT TERM

python3 - "$SCRIPT" "$WORK" <<'PY'
import re, sys
src, work = sys.argv[1], sys.argv[2]
lines = open(src, encoding='utf-8').read().split('\n')

def die(msg):
    sys.stderr.write('ЯКОРЬ ПРОПАЛ: ' + msg + '\n')
    sys.exit(2)

# --- значение маркера: первоисточник, не копия ------------------------------
marker = None
for l in lines:
    m = re.match(r"^OUR_MARKER='(.*)'$", l)
    if m:
        marker = m.group(1)
        break
if marker is None:
    die('строка OUR_MARKER= не найдена')

# --- условие активации ------------------------------------------------------
act = next((i for i, l in enumerate(lines) if l == 'if [[ $ONLY_OURS -eq 0 ]]; then'), None)
if act is None:
    die('внешнее условие активации стадии tweakcc не найдено')

# --- тело стража ------------------------------------------------------------
g0 = next((i for i, l in enumerate(lines)
           if l.startswith('  if [[ -f "$TWEAKCC_BACKUP" ]] && ! grep -q -a -F "$OUR_MARKER" "$BIN"')), None)
if g0 is None:
    die('условие стража «цель против бэкапа» не найдено')
if g0 < act:
    die('страж стоит ВЫШЕ условия активации -- он бы работал и при --only-ours')
# между активацией и стражем не должно быть закрывающего внешний блок `fi`
if any(lines[i] == 'fi' for i in range(act + 1, g0)):
    die('внешний блок закрыт РАНЬШЕ стража -- страж больше не в стадии tweakcc')
g1 = next((j for j in range(g0 + 1, len(lines)) if lines[j] == '  fi'), None)
if g1 is None:
    die('закрывающий fi стража не найден')
guard = '\n'.join(lines[g0:g1 + 1])
if 'FATAL: the target and tweakcc' not in guard or 'does not name its version' not in guard:
    die('в извлечённом страже нет одного из двух его сообщений')

# --- пост-сверка дайджеста ---------------------------------------------------
p0 = next((i for i, l in enumerate(lines) if l == 'if [[ -n "$TWEAKCC_RESTORE_PINNED" ]]; then'), None)
if p0 is None:
    die('пост-сверка дайджеста бэкапа не найдена')
p1 = next((j for j in range(p0 + 1, len(lines)) if lines[j] == 'fi'), None)
if p1 is None:
    die('закрывающий fi пост-сверки не найден')
post = '\n'.join(lines[p0:p1 + 1])
if 'changed WHILE the tweakcc stage' not in post:
    die('в извлечённой пост-сверке нет её сообщения')

open(work + '/marker.txt', 'w', encoding='utf-8').write(marker)
open(work + '/guard.sh', 'w', encoding='utf-8').write(
    'set -euo pipefail\nOUR_MARKER=' + repr(marker).replace('"', '\\"') + '\n'
    + guard + '\n'
    + '[ -z "${STAGE_HOOK:-}" ] || eval "$STAGE_HOOK"\n'
    + post + '\necho GUARD-PASSED\n')
print(f'извлечено: страж {g0+1}..{g1+1}, пост-сверка {p0+1}..{p1+1}, '
      f'активация {act+1}, маркер из первоисточника')
PY

# repr питона даёт одинарные кавычки -- для bash это ровно то, что нужно.
MARKER="$(cat "$WORK/marker.txt")"

mkimg() {   # $1 путь, $2 версия ('-' = не называет версию), $3 начинка
  if [ "$2" = "-" ]; then
    printf '#!/bin/sh\necho "warming up"\n: %s\n' "$3" > "$1"
  else
    printf '#!/bin/sh\ncase "$1" in --version) echo "%s (Claude Code)";; esac\n: %s\n' "$2" "$3" > "$1"
  fi
  chmod +x "$1"
}
mkcfg() { printf '{"ccVersion":"%s"}\n' "$1" > "$2"; }

FAILED=0
BADCASE=0
# $7 -- ПРИЧИНА, по которой обязан сработать страж. Без неё случай зачитывался
# по родовому «FATAL:» (раунд 18, E-4): случай «цель не называет версию» прошёл
# бы и тогда, когда страж отказал по расхождению с бэкапом, то есть проверял не
# ту дверь. Для passed-случаев причина не нужна: их след -- GUARD-PASSED.
run_case() {  # $1 имя, $2 исход (fired|passed), $3 цель, $4 бэкап, $5 конфиг, $6 хук, $7 причина
  local name="$1" want="$2" cause="${7:-}" out rc got
  if [[ "$want" == fired && -z "$cause" ]]; then
    echo "  КРАСНО $name: случай ждёт отказа, но не назвал причину" >&2
    BADCASE=1
    return 0
  fi
  set +e
  out="$(BIN="$3" TWEAKCC_BACKUP="$4" TWEAKCC_CFG="$5" TWEAKCC_RESTORE_PINNED="" \
         STAGE_HOOK="${6:-}" bash "$WORK/guard.sh" 2>&1)"; rc=$?
  set -e
  if [[ $rc -eq 1 && "$out" == *"FATAL:"* && -n "$cause" && "$out" != *"$cause"* ]]; then
    got="fired-ЧУЖОЙ-ПРИЧИНОЙ (нет «${cause}»)"
  elif [[ $rc -eq 1 && "$out" == *"FATAL:"* ]]; then got=fired
  elif [[ $rc -eq 0 && "$out" == *"GUARD-PASSED"* ]]; then got=passed
  else got="died(rc=$rc)"; fi
  if [[ "$got" == "$want" ]]; then
    echo "  ok    $name"
  else
    echo "  КРАСНО $name: ждали $want, получили $got" >&2
    echo "$out" | sed 's/^/        /' >&2
    FAILED=1
  fi
}

CFG_MATCH="$WORK/cfg-match.json";  mkcfg 2.1.247 "$CFG_MATCH"
CFG_STALE="$WORK/cfg-stale.json";  mkcfg 2.1.246 "$CFG_STALE"
CFG_NONE="$WORK/cfg-missing.json"  # намеренно не создаётся
mkimg "$WORK/backup" 2.1.247 backup-bytes

# (a) цель несёт НАШ маркер -- штатная пересборка живого образа.
mkimg "$WORK/marked" 2.1.247 "$MARKER"
run_case "цель с нашим маркером -- молчит"            passed "$WORK/marked"   "$WORK/backup" "$CFG_MATCH"

# (b) бэкапа нет -- восстанавливать нечего.
run_case "бэкапа нет -- молчит"                        passed "$WORK/backup"   "$WORK/no-such" "$CFG_MATCH"

# (c) байты совпадают -- восстановление ничего не подменит.
cp -p "$WORK/backup" "$WORK/same"
run_case "байты совпадают -- молчит"                   passed "$WORK/same"     "$WORK/backup" "$CFG_MATCH"

# (d) запись конфига НЕ равна версии цели -- tweakcc освежит бэкап из цели.
mkimg "$WORK/diverged" 2.1.247 target-bytes
run_case "конфиг другой версии -- молчит"              passed "$WORK/diverged" "$WORK/backup" "$CFG_STALE"
run_case "конфига нет -- молчит"                       passed "$WORK/diverged" "$WORK/backup" "$CFG_NONE"

# (e) единственный случай подмены: запись совпадает, байты разные.
run_case "запись совпадает, байты разные -- ОТКАЗ"     fired  "$WORK/diverged" "$WORK/backup" "$CFG_MATCH" "" \
         "the target and tweakcc's backup are DIFFERENT images"

# (f) версия цели не устанавливается -- отказ, а не молчание и не смерть.
mkimg "$WORK/nover" - target-bytes
run_case "цель не называет версию -- ОТКАЗ"            fired  "$WORK/nover"    "$WORK/backup" "$CFG_MATCH" "" \
         "the target does not name its version"
cp -p "$WORK/diverged" "$WORK/noexec"; chmod -x "$WORK/noexec"
run_case "цель не исполняется -- ОТКАЗ"                fired  "$WORK/noexec"   "$WORK/backup" "$CFG_MATCH" "" \
         "the target does not name its version"
mkdir -p "$WORK/dir-target"
run_case "цель -- каталог -- ОТКАЗ"                    fired  "$WORK/dir-target" "$WORK/backup" "$CFG_MATCH" "" \
         "the target does not name its version"

# (g) гонка check/use: бэкап подменён ВНУТРИ стадии.
cp -p "$WORK/backup" "$WORK/same2"
run_case "бэкап подменён внутри стадии -- ОТКАЗ"       fired  "$WORK/same2"   "$WORK/backup" "$CFG_MATCH" \
         'mkimg_race() { printf "#!/bin/sh\ncase \"\$1\" in --version) echo \"2.1.247 (Claude Code)\";; esac\n: foreign\n" > "$TWEAKCC_BACKUP"; chmod +x "$TWEAKCC_BACKUP"; }; mkimg_race' \
         "tweakcc's backup changed WHILE the tweakcc stage was running"
# и контроль к ней: без подмены та же дорога молчит
cp -p "$WORK/backup" "$WORK/backup-intact"; cp -p "$WORK/backup" "$WORK/same3"
run_case "бэкап не менялся внутри стадии -- молчит"    passed "$WORK/same3"   "$WORK/backup-intact" "$CFG_MATCH"

__DONE=1   # таблица пройдена целиком; дальше только вердикт
if [[ $BADCASE -ne 0 ]]; then
  echo "страж «цель против бэкапа»: таблица НЕ ИЗМЕРЕНА -- случай объявлен без причины отказа" >&2
  exit 2
fi
if [[ $FAILED -eq 0 ]]; then
  echo "страж «цель против бэкапа»: таблица из 11 случаев сошлась"
else
  echo "страж «цель против бэкапа»: таблица истинности НЕ сошлась" >&2
  exit 1
fi
