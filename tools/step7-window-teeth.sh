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
#   5  НЕ ИЗМЕРЕНО: шаг 7 выключен реестром our-steps-off.txt. CONSTRAINT:
#      у кода 3 и кода 5 РАЗНЫЕ владельцы -- дельта машины (окружение)
#      против решения реестра (оператор); один код слил бы два отказа в
#      неразличимые. Выход идёт ДО любой работы: предмет стенда -- сырой
#      патч, где шаг 7 присутствует всегда; реестр выключает его в ПРОДУКТЕ.
# CONSTRAINT: пин числа зубов -- EXPECTED_TEETH; расхождение прогнанных
# с пином -- код 4, даже если каждый зуб зелёный.
# CONSTRAINT: rm -rf только при непустом WORKDIR -- пустая строка не путь.
set -euo pipefail

KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PATCH="${PATCH:-$KIT/tweakcc-patch.js}"
FORK="${FORK:-$HOME/work/SIB/Transmutation/Nexus/Catalyst/Catalyst-tweakcc/dist/index.mjs}"
IMAGE="${IMAGE:-$HOME/.local/share/claude/versions/2.1.278.orig}"
# Зубы 8/9 (fix-волна #407, раунд 2): развилка исходов строителя на ВТОРОЙ
# стадии (apply) и пин применения строителя ЦЕЛОЙ строкой + побайтовым
# сравнением предмета.
# 8 = 7 + 1 (Ф7: код 3 строителя на apply -- «НЕ ИЗМЕРЕНО», не отказ) +
# 1 (Ф8: фальшивые форки обязаны отказывать) = 9
# (docnum:other -- Ф7/Ф8 есть номера пунктов брифа fix-волны 2, не счётчики
# стенда).
# Раунд 3: + 1 (Х2: защита печати успешного пути -- постоянный сторож вместо
# прогона из временной папки) + 1 (Х3: печать причины отказа не уносит 2/3
# на закрытом stderr) = 11 (docnum:other -- Х2/Х3 есть номера пунктов брифа
# fix-волны 3, не счётчики стенда).
EXPECTED_TEETH=11

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
# Нога реестра идёт РАНЬШЕ: выключенный реестром шаг делает предмет
# отсутствующим ПО РЕШЕНИЮ, и это отдельный код 5 (см. шапку); node ей нужен
# до остальных проверок -- читает реестр единственный дом разбора,
# tools/steps-off-registry.js. Имя шага -- дословно из step('7 session memory')
# в tweakcc-patch.js.
command -v node > /dev/null 2>&1 || absent "нет node"
STEP7_OFF_RC=0
node "$KIT/tools/steps-off-registry.js" "$KIT/tools/our-steps-off.txt" \
  --has '7 session memory' || STEP7_OFF_RC=$?
case "${STEP7_OFF_RC}" in
  0) echo "step7-window-teeth: НЕ ИЗМЕРЕНО -- шаг выключен реестром our-steps-off.txt" >&2
     __DONE=1
     exit 5 ;;
  1) ;;
  *) refuse "реестр our-steps-off.txt не читается (rc=${STEP7_OFF_RC})" ;;
esac
[[ -f "${PATCH}" ]] || refuse "нет ${PATCH}"
for f in "${FORK}" "${IMAGE}"; do
  [[ -f "${f}" ]] || absent "нет ${f}"
done
command -v python3 > /dev/null 2>&1 || absent "нет python3"
command -v perl > /dev/null 2>&1 || absent "нет perl (часовой прогона)"

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/step7-teeth.XXXXXX") \
  || refuse "не создан временный каталог"
[ -n "${WORKDIR}" ] || refuse "путь временного каталога пуст"

# Предмет строит ОБЩИЙ дом рецепта tools/fixture-build.sh (#407): копия
# образа + конвейерная нейтрализация двух чтений флага (эквивалент
# patchExtraction + findExtractModeFlagCall на 278). ПИН «Replaced 2
# occurrence(s)» и часовой прогона (perl-alarm) держит дом рецепта;
# CONSTRAINT: вторая копия рецепта в стендe расходилась бы с домом молча
# (Ф5 #407).
BUILD_RC=0
bash "${KIT}/tools/fixture-build.sh" neutralize "${IMAGE}" "${WORKDIR}/subject" \
  > "${WORKDIR}/neutral.log" 2>&1 || BUILD_RC=$?
# CONSTRAINT (Р6 fix-волны #407): код 3 строителя -- «НЕ ИЗМЕРЕНО» с причиной
# из ЕГО лога (инструментария/предмета нет), любой иной ненулевой -- отказ
# прибора; причина обоих -- вывод строителя, не сообщение cat о пути.
if [[ "${BUILD_RC}" -eq 3 ]]; then
  absent "нейтрализация: инструментария или предмета нет (rc=3): $(cat "${WORKDIR}/neutral.log")"
fi
if [[ "${BUILD_RC}" -ne 0 ]]; then
  refuse "нейтрализация не построена (rc=${BUILD_RC}): $(cat "${WORKDIR}/neutral.log")"
fi

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

# Прогон копии патча по СВОЕЙ копии предмета -- общий дом рецепта
# fixture-build.sh (apply); код и лог -- в глобальные, вывод прогона лежит
# в run.$2.log.
RUN_RC=0
run_patch() {  # $1 script, $2 tag
  BUILD_RC=0
  bash "${KIT}/tools/fixture-build.sh" apply "$1" "${WORKDIR}/subject" \
    "${WORKDIR}/img.$2" > "${WORKDIR}/run.$2.log" 2>&1 || BUILD_RC=$?
  RUN_RC="${BUILD_RC}"
}

ok()  { PASSED=$((PASSED + 1)); printf '  ok     %s\n' "$1"; }
bad() { FAILED=$((FAILED + 1)); printf '  ПРОВАЛ %s\n' "$1"; }

# 1. base: исправленный патч по предмету -- шаг 7 НЕ отказывает.
#    Отказ base = прибор не может мерить (код 2), а не промах.
tooth_1() {
  RAN=$((RAN + 1))
  run_patch "${PATCH}" base
  # CONSTRAINT (Ф7 fix-волны #407): та же развилка, что у neutralize выше:
  # код 3 строителя на apply -- «НЕ ИЗМЕРЕНО» с причиной из ЕГО лога
  # (инструментария/предмета нет), а не отказ прибора; свёрнутый в общий
  # отказ, исход делал НЕИЗМЕРЕННОСТЬ площадки неотличимой от поломки.
  if [[ "${RUN_RC}" -eq 3 ]]; then
    absent "base-прогон: инструментария или предмета нет (rc=3): $(cat "${WORKDIR}/run.base.log")"
  fi
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

# 5. identity: строитель отвергает скрипт, НЕ меняющий содержимое предмета
#    (Р5 fix-волны #407) -- форк считает тождество успехом с кодом 0, дом
#    рецепта обязан пинить содержательную строку применения.
tooth_5() {
  RAN=$((RAN + 1))
  printf 'return js;\n' > "${WORKDIR}/identity.js"
  BUILD_RC=0
  bash "${KIT}/tools/fixture-build.sh" apply "${WORKDIR}/identity.js" \
    "${WORKDIR}/subject" "${WORKDIR}/img.t5" > "${WORKDIR}/run.t5.log" 2>&1 || BUILD_RC=$?
  if [[ "${BUILD_RC}" -ne 2 ]]; then
    bad "5 ждали отказ кодом 2 от скрипта-тождества, получили rc=${BUILD_RC}: $(cat "${WORKDIR}/run.t5.log")"
    return
  fi
  if ! grep -F -q 'Script returned unchanged content' "${WORKDIR}/run.t5.log"; then
    bad "5 причина отказа не назвала неизменённое содержимое: $(cat "${WORKDIR}/run.t5.log")"
    return
  fi
  if grep -F -q 'Script patch applied' "${WORKDIR}/run.t5.log"; then
    bad "5 строк применения присутствует при неизменённом содержимом"
    return
  fi
  ok '5 identity: строитель отверг неизменённый предмет'
}

# 6/7. Оба исхода строителя различимы СТЕНДОМ (Р6 fix-волны #407): код 3 --
#     «НЕ ИЗМЕРЕНО» с причиной строителя, код 2 -- отказ прибора с ней же.
#     Снимок стенда живёт в игрушечном ките со строителем-заглушкой: предмет
#     не строится, меряется только развилка потребителя. Причина из лога
#     строителя, а не сообщение cat о несуществующем пути (Р7).
_tooth_stub_kit() {  # $1.. -- строки тела заглушки строителя
  local kit2
  kit2=$(mktemp -d "${TMPDIR:-/tmp}/step7-teeth-k.XXXXXX") \
    || refuse "не создан временный каталог снимка стенда"
  mkdir -p "${kit2}/tools"
  cp "${KIT}/tools/steps-off-registry.js" "${kit2}/tools/steps-off-registry.js"
  cp "${KIT}/tools/our-steps-off.txt" "${kit2}/tools/our-steps-off.txt"
  cp "${PATCH}" "${kit2}/tweakcc-patch.js"
  cp "${BASH_SOURCE[0]}" "${kit2}/tools/step7-window-teeth.sh"
  { printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' "$@"
  } > "${kit2}/tools/fixture-build.sh"
  printf '%s\n' "${kit2}"
}

tooth_6() {
  RAN=$((RAN + 1))
  local kit2 rc6 out6
  kit2=$(_tooth_stub_kit \
    'echo "fixture-build: НЕ ИЗМЕРЕНО -- зуб 6: нет форка на этой площадке" >&2' \
    'exit 3')
  rc6=0
  out6=$(cd / && FORK="${FORK}" IMAGE="${IMAGE}" \
    bash "${kit2}/tools/step7-window-teeth.sh" 2>&1) || rc6=$?
  [[ -n "${kit2}" ]] && rm -rf "${kit2}"
  if [[ "${rc6}" -ne 3 ]]; then
    bad "6 ждали «НЕ ИЗМЕРЕНО» кодом 3 от строителя без инструментария, получили rc=${rc6}: ${out6}"
    return
  fi
  if ! grep -F -q 'зуб 6: нет форка на этой площадке' <<<"${out6}"; then
    bad "6 причина строителя (код 3) не доехала до вывода: ${out6}"
    return
  fi
  if grep -F -q 'нейтрализация не построена' <<<"${out6}"; then
    bad "6 код 3 строителя свёрнут в отказ прибора: ${out6}"
    return
  fi
  ok '6 строитель-3: НЕ ИЗМЕРЕНО с причиной строителя'
}

tooth_7() {
  RAN=$((RAN + 1))
  local kit2 rc7 out7
  # CONSTRAINT (Ф3 fix-волны #407): заглушка отказывает ТОЛЬКО на первом
  # вызове строителя (neutralize) и молчит на последующих: всегда отказывающая
  # заглушка делала зуб вакуумным -- приманка «if false» на развилке
  # neutralize пропускала отказ строителя, а поздний вызов apply отдаёт тот
  # же rc=2 с той же строкой, и зуб принимал поздний отказ за результат
  # проверяемой развилки (маркер приезжал в вывод чужим путём -- из cat лога
  # зуба 1).
  kit2=$(_tooth_stub_kit \
    'if [[ -f "$(dirname "$0")/.stub-called" ]]; then echo "stub ok"; exit 0; fi' \
    'touch "$(dirname "$0")/.stub-called"' \
    'echo "fixture-build: ОТКАЗ -- зуб 7: нейтрализация легла не двумя заменами" >&2' \
    'exit 2')
  rc7=0
  out7=$(cd / && FORK="${FORK}" IMAGE="${IMAGE}" \
    bash "${kit2}/tools/step7-window-teeth.sh" 2>&1) || rc7=$?
  [[ -n "${kit2}" ]] && rm -rf "${kit2}"
  if [[ "${rc7}" -ne 2 ]]; then
    bad "7 ждали отказ кодом 2 от сломанного строителя, получили rc=${rc7}: ${out7}"
    return
  fi
  if ! grep -F -q 'зуб 7: нейтрализация легла не двумя заменами' <<<"${out7}"; then
    bad "7 причина строителя (код 2) не доехала до вывода: ${out7}"
    return
  fi
  if grep -F -q 'НЕ ИЗМЕРЕНО' <<<"${out7}"; then
    bad "7 отказ построения свёрнут в неизмеренность: ${out7}"
    return
  fi
  if grep -F -q 'cat:' <<<"${out7}"; then
    bad "7 в отказе живёт сообщение cat, а не причина строителя (Р7): ${out7}"
    return
  fi
  # Мутационное плечо (Х4 fix-волны #407, раунд 3): различение «какого вызова
  # отказ» жило ТОЛЬКО в состоянии заглушки, и возврат к всегда-отказывающей
  # заглушке не красил ни один постоянный прогон -- вакуум класса Ф3 вернулся
  # бы молча. Плечо гасит перенос причины строителя в КОПИИ стенда: отказ
  # остаётся кодом 2, но причина обязана исчезнуть.
  local kit3 m7rc m7out m7build
  kit3=$(_tooth_stub_kit \
    'if [[ -f "$(dirname "$0")/.stub-called" ]]; then echo "stub ok"; exit 0; fi' \
    'touch "$(dirname "$0")/.stub-called"' \
    'echo "fixture-build: ОТКАЗ -- зуб 7: нейтрализация легла не двумя заменами" >&2' \
    'exit 2')
  m7build=0
  python3 - "${kit3}/tools/step7-window-teeth.sh" <<'MUT7' || m7build=$?
import sys
path = sys.argv[1]
text = open(path, encoding='utf-8').read()
# CONSTRAINT: якорь берётся ДВУМЯ строками. Одной строкой он встречается
# дважды -- копия стенда несёт и сам сайт, и его литерал внутри этого тела;
# двухстрочная форма существует только на сайте (здесь она собрана из
# escape-последовательности и потому собой не совпадает).
old = ('if [[ "${BUILD_RC}" -ne 0 ]]; then\n'
       '  refuse "нейтрализация не построена (rc=${BUILD_RC}): '
       '$(cat "${WORKDIR}/neutral.log")"\n')
new = ('if [[ "${BUILD_RC}" -ne 0 ]]; then\n'
       '  refuse "нейтрализация не построена (rc=${BUILD_RC})"  # мутация Х4\n')
n = text.count(old)
if n != 1:
    sys.stderr.write('tooth 7: якорь мутации встречается %d раз, нужно 1\n' % n)
    sys.exit(2)
open(path, 'w', encoding='utf-8').write(text.replace(old, new, 1))
MUT7
  if [[ "${m7build}" -ne 0 ]]; then
    bad "7 мутационное плечо не построено (rc=${m7build})"
    [[ -n "${kit3}" ]] && rm -rf "${kit3}"
    return
  fi
  m7rc=0
  m7out=$(cd / && FORK="${FORK}" IMAGE="${IMAGE}" \
    bash "${kit3}/tools/step7-window-teeth.sh" 2>&1) || m7rc=$?
  [[ -n "${kit3}" ]] && rm -rf "${kit3}"
  if [[ "${m7rc}" -ne 2 ]]; then
    bad "7 погашенный перенос причины дал чужой исход: rc=${m7rc}: ${m7out}"
    return
  fi
  if grep -F -q 'зуб 7: нейтрализация легла не двумя заменами' <<<"${m7out}"; then
    bad "7 мутация пережила зуб: причина строителя доехала без её переноса: ${m7out}"
    return
  fi
  ok '7 строитель-2: отказ прибора с причиной строителя'
}

# 8. Оба исхода строителя различимы стендом и на ВТОРОЙ стадии (apply):
#    потребитель обязан отличать код 3 («НЕ ИЗМЕРЕНО» с причиной из лога
#    строителя) от отказа построения -- как на стадии neutralize (Ф7
#    fix-волны #407). Снимок стенда живёт в игрушечном ките со строителем,
#    отдающим rc=3 ТОЛЬКО на apply; мутационное плечо гасит развилку в КОПИИ
#    стенда -- прогон обязан свалиться в отказ (rc=2), и зуб это ловит.
tooth_8() {
  RAN=$((RAN + 1))
  local kit2 rc8 out8
  kit2=$(_tooth_stub_kit \
    'case "${1:-}" in neutralize) exit 0 ;; *)' \
    'echo "fixture-build: НЕ ИЗМЕРЕНО -- зуб 8: нет форка на apply" >&2' \
    'exit 3 ;; esac')
  rc8=0
  out8=$(cd / && FORK="${FORK}" IMAGE="${IMAGE}" \
    bash "${kit2}/tools/step7-window-teeth.sh" 2>&1) || rc8=$?
  [[ -n "${kit2}" ]] && rm -rf "${kit2}"
  if [[ "${rc8}" -ne 3 ]]; then
    bad "8 ждали «НЕ ИЗМЕРЕНО» кодом 3 от строителя на apply, получили rc=${rc8}: ${out8}"
    return
  fi
  if ! grep -F -q 'зуб 8: нет форка на apply' <<<"${out8}"; then
    bad "8 причина строителя (код 3 на apply) не доехала до вывода: ${out8}"
    return
  fi
  if grep -F -q 'base-прогон шага 7 отказал' <<<"${out8}"; then
    bad "8 код 3 строителя на apply свёрнут в отказ прибора: ${out8}"
    return
  fi
  # Мутационное плечо: развилка rc=3 на apply погашена в КОПИИ стенда --
  # прогон обязан свалиться в отказ (rc=2), иначе развилка не несущая.
  local kit3 m8rc m8out m8build
  kit3=$(_tooth_stub_kit \
    'case "${1:-}" in neutralize) exit 0 ;; *)' \
    'echo "fixture-build: НЕ ИЗМЕРЕНО -- зуб 8: нет форка на apply" >&2' \
    'exit 3 ;; esac')
  m8build=0
  python3 - "${kit3}/tools/step7-window-teeth.sh" <<'MUT8' || m8build=$?
import sys
path = sys.argv[1]
text = open(path, encoding='utf-8').read()
old = '  if [[ "${RUN_RC}" -eq 3 ]]; then\n'
new = '  if false; then  # мутация Ф7: развилка apply погашена\n'
n = text.count(old)
if n != 1:
    sys.stderr.write('tooth 8: якорь мутации встречается %d раз, нужно 1\n' % n)
    sys.exit(2)
open(path, 'w', encoding='utf-8').write(text.replace(old, new, 1))
MUT8
  if [[ "${m8build}" -ne 0 ]]; then
    bad "8 мутационное плечо не построено (rc=${m8build})"
    [[ -n "${kit3}" ]] && rm -rf "${kit3}"
    return
  fi
  m8rc=0
  m8out=$(cd / && FORK="${FORK}" IMAGE="${IMAGE}" \
    bash "${kit3}/tools/step7-window-teeth.sh" 2>&1) || m8rc=$?
  [[ -n "${kit3}" ]] && rm -rf "${kit3}"
  if [[ "${m8rc}" -eq 3 ]]; then
    bad "8 мутация пережила зуб: погашенная развилка всё ещё даёт rc=3: ${m8out}"
    return
  fi
  if ! grep -F -q 'base-прогон шага 7 отказал' <<<"${m8out}"; then
    bad "8 погашенная развилка дала чужой исход (ждали отказ): rc=${m8rc}: ${m8out}"
    return
  fi
  ok '8 строитель-3 на apply: НЕ ИЗМЕРЕНО с причиной строителя'
}

# 9. Фальшивые форки обязаны отказывать (Ф8 fix-волны #407): пин применения
#    -- ЦЕЛАЯ строка, а фраза внутри предупреждения не проходит; код 0 при
#    побайтово неизменном предмете -- отказ с собственным текстом. Каждый
#    фальшивый форк изолирует ОДНУ проверку: подстрока+изменённые байты
#    ловится только пином строки, целая строка+нет изменения -- только
#    сравнением предмета.
tooth_9() {
  RAN=$((RAN + 1))
  local fk rc9 msg9
  fk=$(mktemp -d "${TMPDIR:-/tmp}/s7t9.XXXXXX") \
    || refuse "не создан временный каталог зуба 9"
  cat > "${fk}/sub.mjs" <<'FK1'
console.log("warning: prior runs printed Script patch applied here");
import fs from "fs";
for (let i = 2; i < process.argv.length; i++) {
  if (process.argv[i - 1] === "-p") { fs.appendFileSync(process.argv[i], "X"); }
}
process.exit(0);
FK1
  cat > "${fk}/line.mjs" <<'FK2'
import fs from "fs";
let out = "";
for (let i = 2; i < process.argv.length; i++) {
  if (process.argv[i - 1] === "-p") { out = fs.realpathSync(process.argv[i]); }
}
console.log("✓ Script patch applied to " + out);
process.exit(0);
FK2
  printf 'PREDMET-9\n' > "${fk}/subject"
  msg9=''
  for arm in sub line; do
    BUILD_RC=0
    FORK="${fk}/${arm}.mjs" bash "${KIT}/tools/fixture-build.sh" apply \
      "${PATCH}" "${fk}/subject" "${fk}/out.${arm}" > "${fk}/log.${arm}" 2>&1 \
      || BUILD_RC=$?
    if [[ "${BUILD_RC}" -ne 2 ]]; then
      msg9="фальшивый форк ${arm} принят (rc=${BUILD_RC}): $(cat "${fk}/log.${arm}")"
      break
    fi
    if ! grep -F -q 'ОТКАЗ' "${fk}/log.${arm}"; then
      msg9="фальшивый форк ${arm} отказал без текста отказа: $(cat "${fk}/log.${arm}")"
      break
    fi
  done
  rm -rf "${fk}"
  if [[ -n "${msg9}" ]]; then
    bad "9 ${msg9}"
    return
  fi
  ok '9 фальшивые форки (подстрока/без изменения байтов) отвергнуты строителем'
}

# 10. Печать пойманного вывода на УСПЕШНОМ пути строителя не имеет права
#     уносить код выхода за объявленное множество {0,2,3} (Ф9 fix-волны
#     #407). Векторов два, и защиты у них РАЗНЫЕ: оборванный потребитель
#     доставляет печати SIGPIPE (держит `trap '' PIPE`), закрытый
#     дескриптор -- EBADF (держит `|| true`). Плечо мутации снимает по
#     ОДНОЙ защите за раз: общая мутация не сказала бы, какая из них жива.
#     Зуб работает на СВОЕЙ копии строителя -- дом рецепта самодостаточен.
tooth_10() {
  RAN=$((RAN + 1))
  local fk fb rcA rcB mrc mout
  fk=$(mktemp -d "${TMPDIR:-/tmp}/s7t10.XXXXXX") \
    || refuse "не создан временный каталог зуба 10"
  # Фальшивый форк, проходящий ОБА пина строителя: печатает строку применения
  # ЦЕЛИКОМ и меняет байты предмета -- иначе путь до печати не доживает.
  cat > "${fk}/good.mjs" <<'FK10'
import fs from "fs";
let out = "";
for (let i = 2; i < process.argv.length; i++) {
  if (process.argv[i - 1] === "-p") { out = process.argv[i]; }
}
fs.appendFileSync(out, "Y");
console.log("\u2713 Script patch applied to " + fs.realpathSync(out));
process.exit(0);
FK10
  printf 'PREDMET-10\n' > "${fk}/subject"
  cp "${KIT}/tools/fixture-build.sh" "${fk}/fb.sh"
  fb="${fk}/fb.sh"
  # Вектор A: потребитель ушёл -- печати прилетает SIGPIPE.
  # CONSTRAINT: стенд идёт под `set -euo pipefail`, где обрыв убил бы его
  # самого, а `|| true` после конвейера обнулил бы PIPESTATUS -- код левой
  # стороны снимается ВНУТРИ отдельной оболочки без этих флагов.
  rcA=0
  FORK="${fk}/good.mjs" bash -c \
    'bash "$1" apply "$2" "$3" "$4" 2> "$5" | true; exit "${PIPESTATUS[0]}"' \
    _ "${fb}" "${PATCH}" "${fk}/subject" "${fk}/outA" "${fk}/errA" || rcA=$?
  # Вектор B: дескриптор закрыт -- печати прилетает EBADF.
  rcB=0
  FORK="${fk}/good.mjs" bash -c \
    'exec 1>&-; bash "$1" apply "$2" "$3" "$4"' _ "${fb}" "${PATCH}" \
    "${fk}/subject" "${fk}/outB" 2> "${fk}/errB" || rcB=$?
  if [[ "${rcA}" -ne 0 ]]; then
    bad "10 оборванный потребитель унёс код строителя: rc=${rcA}: $(cat "${fk}/errA")"
    rm -rf "${fk}"; return
  fi
  if [[ "${rcB}" -ne 0 ]]; then
    bad "10 закрытый stdout унёс код строителя: rc=${rcB}: $(cat "${fk}/errB")"
    rm -rf "${fk}"; return
  fi
  # Плечо A: снят игнор SIGPIPE -- вектор A обязан покраснеть.
  mrc=0
  python3 - "${fb}" 'TRAP_APPLY' <<'MUT10' || mrc=$?
import sys
path, which = sys.argv[1], sys.argv[2]
text = open(path, encoding='utf-8').read()
old = "    trap '' PIPE\n    printf '%s\\n' \"${APPLY_OUT}\" || true\n"
if which == 'TRAP_APPLY':
    new = "    printf '%s\\n' \"${APPLY_OUT}\" || true\n"
else:
    new = "    trap '' PIPE\n    printf '%s\\n' \"${APPLY_OUT}\"\n"
n = text.count(old)
if n != 1:
    sys.stderr.write('tooth 10: якорь мутации встречается %d раз, нужно 1\n' % n)
    sys.exit(2)
open(path, 'w', encoding='utf-8').write(text.replace(old, new, 1))
MUT10
  if [[ "${mrc}" -ne 0 ]]; then
    bad "10 плечо A не построено (rc=${mrc})"
    rm -rf "${fk}"; return
  fi
  mout=0
  FORK="${fk}/good.mjs" bash -c \
    'bash "$1" apply "$2" "$3" "$4" 2> "$5" | true; exit "${PIPESTATUS[0]}"' \
    _ "${fb}" "${PATCH}" "${fk}/subject" "${fk}/outMA" "${fk}/errMA" || mout=$?
  if [[ "${mout}" -eq 0 ]]; then
    bad "10 мутация пережила зуб: без игнора SIGPIPE вектор обрыва всё ещё даёт 0"
    rm -rf "${fk}"; return
  fi
  # Плечо B: возвращён игнор, снят `|| true` -- вектор B обязан покраснеть.
  cp "${KIT}/tools/fixture-build.sh" "${fb}"
  mrc=0
  python3 - "${fb}" 'GUARD_APPLY' <<'MUT10B' || mrc=$?
import sys
path, which = sys.argv[1], sys.argv[2]
text = open(path, encoding='utf-8').read()
old = "    trap '' PIPE\n    printf '%s\\n' \"${APPLY_OUT}\" || true\n"
new = "    trap '' PIPE\n    printf '%s\\n' \"${APPLY_OUT}\"\n"
n = text.count(old)
if n != 1:
    sys.stderr.write('tooth 10: якорь мутации B встречается %d раз, нужно 1\n' % n)
    sys.exit(2)
open(path, 'w', encoding='utf-8').write(text.replace(old, new, 1))
MUT10B
  if [[ "${mrc}" -ne 0 ]]; then
    bad "10 плечо B не построено (rc=${mrc})"
    rm -rf "${fk}"; return
  fi
  mout=0
  FORK="${fk}/good.mjs" bash -c \
    'exec 1>&-; bash "$1" apply "$2" "$3" "$4"' _ "${fb}" "${PATCH}" \
    "${fk}/subject" "${fk}/outMB" 2> "${fk}/errMB" || mout=$?
  if [[ "${mout}" -eq 0 ]]; then
    bad "10 мутация пережила зуб: без защиты печати закрытый stdout всё ещё даёт 0"
    rm -rf "${fk}"; return
  fi
  rm -rf "${fk}"
  ok '10 печать успешного пути: обрыв и закрытый stdout не уносят код'
}

# 11. Печать ПРИЧИНЫ на путях отказа -- тот же вектор, что зуб 10, и та же
#     защита (Х3 fix-волны #407, раунд 3): закрытый stderr под `set -e`
#     убивал строитель ДО `exit 2/3`, и потребитель терял РАЗЛИЧЕНИЕ «нечем
#     построить» (2) от «инструментария нет» (3) вместе с кодом.
tooth_11() {
  RAN=$((RAN + 1))
  local fk fb rc2 rc3 rcP mrc mrc2
  fk=$(mktemp -d "${TMPDIR:-/tmp}/s7t11.XXXXXX") \
    || refuse "не создан временный каталог зуба 11"
  cp "${KIT}/tools/fixture-build.sh" "${fk}/fb.sh"
  fb="${fk}/fb.sh"
  rc2=0
  bash -c 'exec 2>&-; bash "$1" bogus' _ "${fb}" > /dev/null || rc2=$?
  rc3=0
  bash -c 'exec 2>&-; bash "$1" apply "$2" "$3" "$4"' _ "${fb}" \
    "${fk}/nope.js" "${fk}/nope.img" "${fk}/out" > /dev/null || rc3=$?
  rcP=0
  bash -c 'bash "$1" bogus 2>&1 > /dev/null | true; exit "${PIPESTATUS[0]}"' \
    _ "${fb}" || rcP=$?
  if [[ "${rc2}" -ne 2 ]]; then
    bad "11 закрытый stderr унёс код отказа: ждали 2, получили ${rc2}"
    rm -rf "${fk}"; return
  fi
  if [[ "${rc3}" -ne 3 ]]; then
    bad "11 закрытый stderr унёс код «НЕ ИЗМЕРЕНО»: ждали 3, получили ${rc3}"
    rm -rf "${fk}"; return
  fi
  if [[ "${rcP}" -ne 2 ]]; then
    bad "11 оборванный потребитель stderr унёс код отказа: ждали 2, получили ${rcP}"
    rm -rf "${fk}"; return
  fi
  # Плечо A: снят `|| true` у печати причины отказа -- закрытый stderr
  # обязан вернуть код вне {2,3}.
  mrc=0
  python3 - "${fb}" 'GUARD' <<'MUT11' || mrc=$?
import sys
path, which = sys.argv[1], sys.argv[2]
text = open(path, encoding='utf-8').read()
if which == 'GUARD':
    old = 'echo "fixture-build: ОТКАЗ -- $1" >&2 || true'
    new = 'echo "fixture-build: ОТКАЗ -- $1" >&2'
else:
    old = "refuse() {  # код 2: построить предмет нечем\n  trap '' PIPE\n"
    new = 'refuse() {  # код 2: построить предмет нечем\n'
n = text.count(old)
if n != 1:
    sys.stderr.write('tooth 11: якорь мутации %s встречается %d раз, нужно 1\n' % (which, n))
    sys.exit(2)
open(path, 'w', encoding='utf-8').write(text.replace(old, new, 1))
MUT11
  if [[ "${mrc}" -ne 0 ]]; then
    bad "11 плечо A не построено (rc=${mrc})"
    rm -rf "${fk}"; return
  fi
  mrc2=0
  bash -c 'exec 2>&-; bash "$1" bogus' _ "${fb}" > /dev/null || mrc2=$?
  if [[ "${mrc2}" -eq 2 ]]; then
    bad "11 мутация пережила зуб: без защиты печати закрытый stderr всё ещё даёт 2"
    rm -rf "${fk}"; return
  fi
  # Плечо B: возвращён `|| true`, снят игнор SIGPIPE -- вектор обрыва
  # обязан покраснеть.
  cp "${KIT}/tools/fixture-build.sh" "${fb}"
  mrc=0
  python3 - "${fb}" 'TRAP' <<'MUT11B' || mrc=$?
import sys
path, which = sys.argv[1], sys.argv[2]
text = open(path, encoding='utf-8').read()
old = "refuse() {  # код 2: построить предмет нечем\n  trap '' PIPE\n"
new = 'refuse() {  # код 2: построить предмет нечем\n'
n = text.count(old)
if n != 1:
    sys.stderr.write('tooth 11: якорь мутации B встречается %d раз, нужно 1\n' % n)
    sys.exit(2)
open(path, 'w', encoding='utf-8').write(text.replace(old, new, 1))
MUT11B
  if [[ "${mrc}" -ne 0 ]]; then
    bad "11 плечо B не построено (rc=${mrc})"
    rm -rf "${fk}"; return
  fi
  mrc2=0
  bash -c 'bash "$1" bogus 2>&1 > /dev/null | true; exit "${PIPESTATUS[0]}"' \
    _ "${fb}" || mrc2=$?
  if [[ "${mrc2}" -eq 2 ]]; then
    bad "11 мутация пережила зуб: без игнора SIGPIPE обрыв stderr всё ещё даёт 2"
    rm -rf "${fk}"; return
  fi
  rm -rf "${fk}"
  ok '11 печать причины: закрытый и оборванный stderr не уносят 2/3'
}

tooth_1
tooth_2
tooth_3
tooth_4
tooth_5
tooth_6
tooth_7
tooth_8
tooth_9
tooth_10
tooth_11

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
