#!/usr/bin/env bash
# Зубы окна шага 7 (session memory): окно обязано кончаться на ГРАНИЦЕ МОДУЛЯ,
# а не на фиксированной ширине от якоря. Предмет -- ИСПОЛНЕНИЕ форка по копии
# образа 2.1.278, приведённой к конвейерному пред-состоянию (нейтрализация
# двух чтений tengu_passport_quail -- то, что стадия tweakcc --apply делает
# ДО нашего шага; без неё шаг отказывает раньше и другим текстом).
#
# Коды (шапка таблицы кита):
#   0  объявленные зубы зелёные: base прошёл, каждая мутация покраснела
#      СВОИМ названным текстом (тексты зубов попарно различны)
#   1  промах: мутация прошла молча или покраснела не своей причиной
#   2  прибор не может мерить ПРИ НАЛИЧИИ предмета: нет патча, якорь
#      мутации не уникален, нейтрализация не легла ровно двумя заменами,
#      base красный
#   3  НЕ ИЗМЕРЕНО: на этой машине нет предмета или инструментария
#      (образ 2.1.278.orig, форк, node/python3/perl). CONSTRAINT: дельта
#      дерева -- не поломка прибора, и сборку она не останавливает;
#      слитый с кодом 2, этот случай был бы неотличим от красного base.
#   4  длина набора зубов разошлась с пином EXPECTED_TEETH
# CONSTRAINT: пин числа зубов -- EXPECTED_TEETH; расхождение прогнанных
# с пином -- код 4, даже если каждый зуб зелёный.
# CONSTRAINT: rm -rf только при непустом WORKDIR -- пустая строка не путь.
set -euo pipefail

KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PATCH="${PATCH:-$KIT/tweakcc-patch.js}"
FORK="${FORK:-$HOME/work/SIB/Transmutation/Nexus/Catalyst/Catalyst-tweakcc/dist/index.mjs}"
IMAGE="${IMAGE:-$HOME/.local/share/claude/versions/2.1.278.orig}"
EXPECTED_TEETH=4

PASSED=0; FAILED=0; RAN=0; WORKDIR=''
# CONSTRAINT: штатный конец объявляет себя сам (__DONE=1); голый EXIT-трап
# съедает обрыв с кодом 0 (правило часового, claude-patch-all.sh).
__DONE=0
cleanup() {
  if [[ -n "${WORKDIR:-}" ]]; then rm -rf "${WORKDIR}"; fi
}
__step7_teeth_guard() {
  local __rc=$?
  trap - EXIT
  cleanup
  if [[ "${__DONE:-0}" != 1 && "${__rc}" == 0 ]]; then
    echo "ОТКАЗ: step7-window-teeth оборвался, не дойдя до конца (ошибка оболочки выше)" >&2
    exit 2
  fi
  exit "${__rc}"
}
trap '__step7_teeth_guard' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

refuse() {  # код 2: прибор не может мерить
  echo "step7-window-teeth: ОТКАЗ -- $1" >&2
  __DONE=1
  exit 2
}

absent() {  # код 3: предмета нет на машине -- НЕ ИЗМЕРЕНО
  echo "step7-window-teeth: НЕ ИЗМЕРЕНО -- $1" >&2
  __DONE=1
  exit 3
}

# Патч -- НАШ дом: его отсутствие ломает прибор. Образ и форк -- предмет и
# инструментарий машины: их отсутствие измеримо, но не наша поломка.
[[ -f "${PATCH}" ]] || refuse "нет ${PATCH}"
for f in "${FORK}" "${IMAGE}"; do
  [[ -f "${f}" ]] || absent "нет ${f}"
done
command -v node > /dev/null 2>&1 || absent "нет node"
command -v python3 > /dev/null 2>&1 || absent "нет python3"
command -v perl > /dev/null 2>&1 || absent "нет perl (часовой прогона)"

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/step7-teeth.XXXXXX") \
  || refuse "не создан временный каталог"
[ -n "${WORKDIR}" ] || refuse "путь временного каталога пуст"

# CONSTRAINT: на маке нет timeout; каждый прогон обёрнут perl-alarm, чтобы
# зависший node не молчал вечно -- молчание потока дороже отказа.
RUN_TIMEOUT=420

# Предмет: копия образа + конвейерная нейтрализация двух чтений флага тем же
# форком (эквивалент patchExtraction + findExtractModeFlagCall на 278).
# ПИН: ровно 2 вхождения -- extraction gate и extract-mode predicate; иное
# число значит другой предмет, мерить им этим стендом нельзя.
cp "${IMAGE}" "${WORKDIR}/subject"
NEUT_RC=0
perl -e 'alarm shift; exec @ARGV' "${RUN_TIMEOUT}" \
  node "${FORK}" adhoc-patch \
    --string 'P("tengu_passport_quail",!1)' '!0' \
    -p "${WORKDIR}/subject" \
    --confirm-possible-dangerous-patch > "${WORKDIR}/neutral.log" 2>&1 || NEUT_RC=$?
if [[ "${NEUT_RC}" -ne 0 ]]; then
  refuse "нейтрализация не применилась (rc=${NEUT_RC}): $(cat "${WORKDIR}/neutral.log")"
fi
grep -F -q 'Replaced 2 occurrence(s)' "${WORKDIR}/neutral.log" \
  || refuse "нейтрализация легла не двумя заменами: $(grep -F 'Replaced' "${WORKDIR}/neutral.log")"

# Мутация: замена с требованием ровно одного вхождения якоря в копии ПАТЧА.
# Исчезнувший якорь (правка ушла вперёд) -- отказ прибора, не зелёный зуб.
mutate() {  # $1 dest, дальше тройки old-file new-file
  local dest="$1"; shift
  python3 - "${PATCH}" "${dest}" "$@" <<'PY'
import sys
path, dest = sys.argv[1], sys.argv[2]
pairs = [(sys.argv[i], sys.argv[i + 1]) for i in range(3, len(sys.argv), 2)]
text = open(path, encoding='utf-8').read()
for old, new in pairs:
    n = text.count(old)
    if n != 1:
        sys.stderr.write(
            "step7-window-teeth: ОТКАЗ -- якорь мутации встречается %d раз, нужно ровно 1: %r\n"
            % (n, old[:60])
        )
        sys.exit(2)
    text = text.replace(old, new, 1)
open(dest, 'w', encoding='utf-8').write(text)
PY
}

# Прогон копии патча по СВОЕЙ копии предмета; код и лог -- в глобальные.
RUN_RC=0
run_patch() {  # $1 script, $2 tag
  cp "${WORKDIR}/subject" "${WORKDIR}/img.$2"
  RUN_RC=0
  perl -e 'alarm shift; exec @ARGV' "${RUN_TIMEOUT}" \
    node "${FORK}" adhoc-patch \
      --script "@$1" -p "${WORKDIR}/img.$2" \
      --confirm-possible-dangerous-patch > "${WORKDIR}/run.$2.log" 2>&1 || RUN_RC=$?
}

ok()  { PASSED=$((PASSED + 1)); printf '  ok     %s\n' "$1"; }
bad() { FAILED=$((FAILED + 1)); printf '  ПРОВАЛ %s\n' "$1"; }

# 1. base: исправленный патч по предмету -- шаг 7 НЕ отказывает.
#    Отказ base = прибор не может мерить (код 2), а не промах.
tooth_1() {
  RAN=$((RAN + 1))
  run_patch "${PATCH}" base
  if [[ "${RUN_RC}" -ne 0 ]]; then
    echo "base красный -- мерить нечем:"
    cat "${WORKDIR}/run.base.log"
    refuse "base-прогон шага 7 отказал (rc=${RUN_RC})"
  fi
  if grep -F -q '7 session memory:' "${WORKDIR}/run.base.log"; then
    echo "base красный -- мерить нечем:"
    cat "${WORKDIR}/run.base.log"
    refuse "base-прогон отказал шагом 7"
  fi
  grep -F -q 'Script patch applied' "${WORKDIR}/run.base.log" \
    || refuse "base-прогон прошёл без строки применения: $(cat "${WORKDIR}/run.base.log")"
  ok '1 base: шаг 7 прошёл, патч применён'
}

# 2. fixed-window: граница возвращается к anchorIdx + 8000 -- прогон обязан
#    отказать текстом про unbalanced if( (чужой if( без закрывающей в окне).
tooth_2() {
  RAN=$((RAN + 1))
  mutate "${WORKDIR}/t2.js" \
    'return m.index;' 'return anchorIdx + 8000;'
  run_patch "${WORKDIR}/t2.js" t2
  if [[ "${RUN_RC}" -ne 0 ]] \
     && grep -F -q 'session-memory extraction window holds an unbalanced if(' "${WORKDIR}/run.t2.log"; then
    ok '2 fixed-window: unbalanced if( пойман'
  else
    bad "2 ждали отказ с unbalanced if(, получили rc=${RUN_RC}: $(cat "${WORKDIR}/run.t2.log")"
  fi
}

# 3. no-marker: регексп маркера подменён на несовпадающий (оба места moduleEnd)
#    -- отказ ИМЕННО первой формой Р2, не «unbalanced if(».
tooth_3() {
  RAN=$((RAN + 1))
  mutate "${WORKDIR}/t3.js" \
    'const boundary = /\n\/\*__tweakcc_module_boundary_\d+__\*\/\n/g;
    boundary.lastIndex = anchorIdx;' \
    'const boundary = /\n\/\*__tweakcc_module_boundary_ZZ__\*\/\n/g;
    boundary.lastIndex = anchorIdx;' \
    'const total = (js.match(/\/\*__tweakcc_module_boundary_\d+__\*\//g) || []).length;' \
    'const total = (js.match(/\/\*__tweakcc_module_boundary_ZZ__\*\//g) || []).length;'
  run_patch "${WORKDIR}/t3.js" t3
  if [[ "${RUN_RC}" -ne 0 ]] \
     && grep -F -q 'the bundle carries no boundary markers (0)' "${WORKDIR}/run.t3.log" \
     && ! grep -F -q 'unbalanced if(' "${WORKDIR}/run.t3.log"; then
    ok '3 no-marker: первая форма Р2 поймана'
  else
    bad "3 ждали отказ «no boundary markers (0)» без unbalanced, получили rc=${RUN_RC}: $(cat "${WORKDIR}/run.t3.log")"
  fi
}

# 4. marker-after-anchor: поиск маркера от 0 -- найденная граница ДО якоря,
#    окно вырождается; отказ обязан быть второй формой Р2 (текст отличен и от
#    base, и от зуба 3 -- совпадение текстов зубов есть находка).
tooth_4() {
  RAN=$((RAN + 1))
  mutate "${WORKDIR}/t4.js" \
    'boundary.lastIndex = anchorIdx;' 'boundary.lastIndex = 0;'
  run_patch "${WORKDIR}/t4.js" t4
  if [[ "${RUN_RC}" -ne 0 ]] \
     && grep -F -q 'no marker after the anchor' "${WORKDIR}/run.t4.log"; then
    ok '4 marker-after-anchor: вырожденное окно поймано второй формой Р2'
  else
    bad "4 ждали отказ «no marker after the anchor» (несовпадение с выводом зуба 1), получили rc=${RUN_RC}: $(cat "${WORKDIR}/run.t4.log")"
  fi
}

tooth_1
tooth_2
tooth_3
tooth_4

printf '%s прошло, %s провалов, ожидалось %s\n' "$PASSED" "$FAILED" "$EXPECTED_TEETH"
if [[ "${RAN}" -ne "${EXPECTED_TEETH}" ]]; then
  printf 'TEETH_RC=4\n'
  printf 'step7-window-teeth: ОТКАЗ -- прогнано %s, пин EXPECTED_TEETH=%s\n' "$RAN" "$EXPECTED_TEETH" >&2
  __DONE=1
  exit 4
fi
if [[ "${FAILED}" -ne 0 ]]; then printf 'TEETH_RC=1\n'; __DONE=1; exit 1; fi
printf 'TEETH_RC=0\n'
__DONE=1
exit 0
