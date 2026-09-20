#!/usr/bin/env bash
# Общий дом рецепта фикстуры: копия образа, приведённая к конвейерному
# пред-состоянию (нейтрализация двух чтений tengu_passport_quail -- то, что
# стадия tweakcc --apply делает ДО нашего шага), с последующим применением
# нашего патча (механизм K1 разбора #407).
# CONSTRAINT: единственный экземпляр рецепта в дереве -- стенд шага 7
# (tools/step7-window-teeth.sh) и прибор зубов (tools/checks-teeth.py) зовут
# ЭТОТ дом; вторая копия рецепта расходится молча (Ф5 #407).
# Коды выхода (подмножество общей таблицы кита):
#   0  предмет построен
#   2  прибор не может построить: аргументы, ПИН «Replaced 2 occurrence(s)»
#      не сошёлся, прогон патча отказал
#   3  НЕ ИЗМЕРЕНО: на машине нет инструментария (node, форк, образ, патч)
# CONSTRAINT: на маке нет timeout -- каждый прогон node обёрнут perl-alarm:
# зависший воркер обязан отказать, а не молчать.
# CONSTRAINT: вывод прогона патча уходит в СВОИ stdout/stderr вызывающего
# (без редиректов и пайпов здесь) -- вызывающий решает, куда его положить;
# код возврата честный, без пайпа.
set -euo pipefail

FORK="${FORK:-$HOME/work/SIB/Transmutation/Nexus/Catalyst/Catalyst-tweakcc/dist/index.mjs}"
RUN_TIMEOUT=420

refuse() {  # код 2: построить предмет нечем
  echo "fixture-build: ОТКАЗ -- $1" >&2
  exit 2
}

absent() {  # код 3: инструментария нет -- НЕ ИЗМЕРЕНО
  echo "fixture-build: НЕ ИЗМЕРЕНО -- $1" >&2
  exit 3
}

run_node() {  # часовой прогона: perl-alarm вокруг node (timeout на маке нет)
  perl -e 'alarm shift; exec @ARGV' "${RUN_TIMEOUT}" "$@"
}

need_node() {
  command -v node > /dev/null 2>&1 || absent "нет node"
  [[ -f "${FORK}" ]] || absent "нет форка ${FORK}"
}

case "${1:-}" in
  neutralize)
    [[ $# -eq 3 ]] || refuse "neutralize: ровно два аргумента (образ, выход), дано $(( $# - 1 ))"
    image=$2; out=$3
    [[ -f "${image}" ]] || absent "нет образа ${image}"
    need_node
    cp "${image}" "${out}"
    NEUT_RC=0
    NEUT_OUT=$(run_node node "${FORK}" adhoc-patch \
      --string 'P("tengu_passport_quail",!1)' '!0' \
      -p "${out}" \
      --confirm-possible-dangerous-patch 2>&1) || NEUT_RC=$?
    if [[ "${NEUT_RC}" -ne 0 ]]; then
      refuse "нейтрализация не применилась (rc=${NEUT_RC}): ${NEUT_OUT}"
    fi
    # ПИН: ровно 2 вхождения -- extraction gate и extract-mode predicate;
    # иное число значит другой предмет, мерить им нельзя (Ф2 #407).
    if [[ "${NEUT_OUT}" != *"Replaced 2 occurrence(s)"* ]]; then
      refuse "нейтрализация легла не двумя заменами: ${NEUT_OUT}"
    fi
    ;;
  apply)
    [[ $# -eq 4 ]] || refuse "apply: ровно три аргумента (скрипт-патч, нейтрализованный, выход), дано $(( $# - 1 ))"
    script=$2; neutralized=$3; out=$4
    [[ -f "${script}" ]] || absent "нет скрипта патча ${script}"
    [[ -f "${neutralized}" ]] || absent "нет нейтрализованного образа ${neutralized}"
    need_node
    cp "${neutralized}" "${out}"
    APPLY_RC=0
    run_node node "${FORK}" adhoc-patch \
      --script "@${script}" -p "${out}" \
      --confirm-possible-dangerous-patch || APPLY_RC=$?
    if [[ "${APPLY_RC}" -ne 0 ]]; then
      refuse "патч не применился к копии (rc=${APPLY_RC})"
    fi
    ;;
  *)
    refuse "подкоманда neutralize|apply, дано: ${1:-пусто}"
    ;;
esac
exit 0
