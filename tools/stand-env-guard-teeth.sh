#!/usr/bin/env bash
# Зубы гварда герметичности стенда. Предмет -- пустышка в mktemp, не живой стенд.
#
# CONSTRAINT: ПИН ЧИСЛА зубов -- EXPECTED_TEETH; расхождение числа прогнанных
# с пином -- провал, даже если каждый отдельный зуб зелёный.
# CONSTRAINT: rm -rf только при непустом WORKDIR.
set -u

KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
GUARD="${GUARD:-$KIT/tools/stand-env-guard.sh}"
EXPECTED_TEETH=16

PASSED=0
FAILED=0
RAN=0
WORKDIR=''

cleanup() {
  if [[ -n "${WORKDIR:-}" ]]; then
    rm -rf "${WORKDIR}"
  fi
}
trap cleanup EXIT

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/stand-env-guard-teeth.XXXXXX") || {
  printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог\n' >&2
  exit 2
}
[ -n "$WORKDIR" ] || {
  printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога пуст\n' >&2
  exit 2
}

ok() { PASSED=$((PASSED + 1)); printf '  ok     %s\n' "$1"; }
bad() { FAILED=$((FAILED + 1)); printf '  ПРОВАЛ %s\n' "$1"; }

run_guard() {
  # rc в глобальную GUARD_RC, вывод в GUARD_OUT. Не пайп -- код честный.
  GUARD_RC=0
  GUARD_OUT=$(bash "$GUARD" "$@") || GUARD_RC=$?
}

# 1. одно имя запинено и выставлено -- код 0, ВЕРДИКТ ГЕРМЕТИЧЕН
tooth_1() {
  RAN=$((RAN + 1))
  printf 'echo "${PINNED_ONE:-}"\n' > "$WORKDIR/s1.sh"
  PINNED_ONE=value run_guard --subject "$WORKDIR/s1.sh" --pinned PINNED_ONE --label t1
  if [[ $GUARD_RC -eq 0 && "$GUARD_OUT" == *"ВЕРДИКТ ГЕРМЕТИЧЕН"* ]]; then
    ok '1 запинено и выставлено -> 0 ГЕРМЕТИЧЕН'
  else
    bad "1 ждали rc=0 ГЕРМЕТИЧЕН, получили rc=$GUARD_RC :: $GUARD_OUT"
  fi
}

# 2. то же имя НЕ запинено и выставлено -- код 3, имя в выводе
tooth_2() {
  RAN=$((RAN + 1))
  printf 'echo "${LEAKED_TWO:-}"\n' > "$WORKDIR/s2.sh"
  LEAKED_TWO=from-machine run_guard --subject "$WORKDIR/s2.sh" --label t2
  if [[ $GUARD_RC -eq 3 && "$GUARD_OUT" == *"LEAKED_TWO"* ]]; then
    ok '2 не запинено и выставлено -> 3, имя названо'
  else
    bad "2 ждали rc=3 и имя LEAKED_TWO, получили rc=$GUARD_RC :: $GUARD_OUT"
  fi
}

# 3. имя не запинено и отсутствует -- код 0, корзина чисто
tooth_3() {
  RAN=$((RAN + 1))
  printf 'echo "${ABSENT_THREE:-}"\n' > "$WORKDIR/s3.sh"
  unset ABSENT_THREE || true
  run_guard --subject "$WORKDIR/s3.sh" --label t3
  if [[ $GUARD_RC -eq 0 && "$GUARD_OUT" == *"ВЕРДИКТ ГЕРМЕТИЧЕН"* && "$GUARD_OUT" == *"чисто 1"* ]]; then
    ok '3 отсутствует -> 0 чисто'
  else
    bad "3 ждали rc=0 чисто 1, получили rc=$GUARD_RC :: $GUARD_OUT"
  fi
}

# 4. --pinned ИМЯ, в окружении пусто/не выставлено -- код 4
tooth_4() {
  RAN=$((RAN + 1))
  printf 'echo "${MISSING_PIN:-}"\n' > "$WORKDIR/s4.sh"
  unset MISSING_PIN || true
  run_guard --subject "$WORKDIR/s4.sh" --pinned MISSING_PIN --label t4
  if [[ $GUARD_RC -eq 4 ]]; then
    ok '4 заявленный пин пуст -> 4'
  else
    bad "4 ждали rc=4, получили rc=$GUARD_RC :: $GUARD_OUT"
  fi
}

# 5. --pinned на имя, которого предмет не читает -- код 0 + лишний пин
tooth_5() {
  RAN=$((RAN + 1))
  printf 'echo "${READ_FIVE:-}"\n' > "$WORKDIR/s5.sh"
  unset READ_FIVE SPARE_PIN || true
  READ_FIVE=x SPARE_PIN=y run_guard --subject "$WORKDIR/s5.sh" --pinned READ_FIVE --pinned SPARE_PIN --label t5
  if [[ $GUARD_RC -eq 0 && "$GUARD_OUT" == *"лишних пинов 1 (SPARE_PIN)"* ]]; then
    ok '5 лишний пин -> 0 и число с именем в сводке'
  else
    bad "5 ждали rc=0 и «лишних пинов 1 (SPARE_PIN)», получили rc=$GUARD_RC :: $GUARD_OUT"
  fi
}

# 6. присвоение ДО чтения -- имя отсеяно
# X выставлен в окружении: без отсева попал бы в «унаследовано» (корзина 2).
tooth_6() {
  RAN=$((RAN + 1))
  printf 'X=1; echo "${X:-}"\n' > "$WORKDIR/s6.sh"
  X=from-machine run_guard --subject "$WORKDIR/s6.sh" --label t6 --allow-zero
  if [[ "$GUARD_OUT" == *"унаследовано: X"* || "$GUARD_OUT" == *"запинено: X"* || "$GUARD_OUT" == *"лишний пин: X"* ]]; then
    bad "6 имя X должно быть отсеяно, вывод: $GUARD_OUT"
  elif [[ $GUARD_RC -eq 0 && "$GUARD_OUT" == *"читает имён: 0"* ]]; then
    ok '6 присвоение до чтения отсеивает имя'
  else
    bad "6 ждали отсев X, имён 0, rc=0; получили rc=$GUARD_RC :: $GUARD_OUT"
  fi
}

# 7. служебное имя оболочки отсеяно
tooth_7() {
  RAN=$((RAN + 1))
  printf 'echo "$PPID"\n' > "$WORKDIR/s7.sh"
  run_guard --subject "$WORKDIR/s7.sh" --label t7 --allow-zero
  if [[ "$GUARD_OUT" == *"PPID"* ]]; then
    bad "7 PPID должен быть отсеян, вывод: $GUARD_OUT"
  elif [[ $GUARD_RC -eq 0 || $GUARD_RC -eq 5 ]]; then
    ok '7 служебное PPID отсеяно'
  else
    bad "7 ждали отсев PPID, получили rc=$GUARD_RC :: $GUARD_OUT"
  fi
}

# 8. python-форма os.environ.get("ИМЯ")
tooth_8() {
  RAN=$((RAN + 1))
  printf 'import os\nos.environ.get("PY_HANDLE")\n' > "$WORKDIR/s8.py"
  unset PY_HANDLE || true
  PY_HANDLE=from-py run_guard --subject "$WORKDIR/s8.py" --pinned PY_HANDLE --label t8
  if [[ $GUARD_RC -eq 0 && "$GUARD_OUT" == *"читает имён: 1"* && "$GUARD_OUT" == *"запинено 1"* ]]; then
    ok '8 python os.environ.get распознан'
  else
    bad "8 ждали rc=0, имён 1, запинено 1; получили rc=$GUARD_RC :: $GUARD_OUT"
  fi
}

# 9. js-форма process.env.ИМЯ
tooth_9() {
  RAN=$((RAN + 1))
  printf 'console.log(process.env.JS_HANDLE)\n' > "$WORKDIR/s9.js"
  unset JS_HANDLE || true
  JS_HANDLE=from-js run_guard --subject "$WORKDIR/s9.js" --pinned JS_HANDLE --label t9
  if [[ $GUARD_RC -eq 0 && "$GUARD_OUT" == *"читает имён: 1"* && "$GUARD_OUT" == *"запинено 1"* ]]; then
    ok '9 js process.env.ИМЯ распознан'
  else
    bad "9 ждали rc=0, имён 1, запинено 1; получили rc=$GUARD_RC :: $GUARD_OUT"
  fi
}

# 10. ноль чтений -> код 5; с --allow-zero -> код 0
tooth_10() {
  RAN=$((RAN + 1))
  printf 'echo hello\n' > "$WORKDIR/s10.sh"
  run_guard --subject "$WORKDIR/s10.sh" --label t10
  rc_a=$GUARD_RC
  out_a=$GUARD_OUT
  run_guard --subject "$WORKDIR/s10.sh" --label t10 --allow-zero
  rc_b=$GUARD_RC
  if [[ $rc_a -eq 5 && $rc_b -eq 0 ]]; then
    ok '10 ноль чтений -> 5; --allow-zero -> 0'
  else
    bad "10 ждали 5 затем 0, получили $rc_a затем $rc_b :: $out_a :: $GUARD_OUT"
  fi
}

# 11. несуществующий --subject -> код 2
tooth_11() {
  RAN=$((RAN + 1))
  run_guard --subject "$WORKDIR/no-such-subject.sh" --label t11
  if [[ $GUARD_RC -eq 2 ]]; then
    ok '11 нет --subject -> 2'
  else
    bad "11 ждали rc=2, получили rc=$GUARD_RC :: $GUARD_OUT"
  fi
}

# 12. --declared-machine: значение машины пропущено ОБЪЯВЛЕННО -- код 0,
# имя названо в сводке даже на зелёном.
tooth_12() {
  RAN=$((RAN + 1))
  printf 'echo "${MACHINE_TWELVE:-}"\n' > "$WORKDIR/s12.sh"
  MACHINE_TWELVE=from-machine run_guard --subject "$WORKDIR/s12.sh" \
    --declared-machine MACHINE_TWELVE --label t12
  if [[ $GUARD_RC -eq 0 && "$GUARD_OUT" == *"объявлено-машинных 1 (MACHINE_TWELVE)"* ]]; then
    ok '12 объявленно-машинная ручка -> 0, названа в сводке'
  else
    bad "12 ждали rc=0 и «объявлено-машинных 1 (MACHINE_TWELVE)», получили rc=$GUARD_RC :: $GUARD_OUT"
  fi
}

# 13. та же ручка НЕ выставлена: для --pinned это код 4 (зуб 4), для
# --declared-machine -- зелено, но с пометкой «не выставлена».
tooth_13() {
  RAN=$((RAN + 1))
  printf 'echo "${MACHINE_THIRTEEN:-}"\n' > "$WORKDIR/s13.sh"
  unset MACHINE_THIRTEEN || true
  run_guard --subject "$WORKDIR/s13.sh" --declared-machine MACHINE_THIRTEEN --label t13
  if [[ $GUARD_RC -eq 0 && "$GUARD_OUT" == *"MACHINE_THIRTEEN(не выставлена)"* ]]; then
    ok '13 объявленно-машинная и не выставлена -> 0 с пометкой'
  else
    bad "13 ждали rc=0 и «MACHINE_THIRTEEN(не выставлена)», получили rc=$GUARD_RC :: $GUARD_OUT"
  fi
}

# 14. одно имя в обеих ролях -- противоречие декларации, код 2.
tooth_14() {
  RAN=$((RAN + 1))
  printf 'echo "${BOTH_ROLES:-}"\n' > "$WORKDIR/s14.sh"
  BOTH_ROLES=x run_guard --subject "$WORKDIR/s14.sh" \
    --pinned BOTH_ROLES --declared-machine BOTH_ROLES --label t14
  if [[ $GUARD_RC -eq 2 ]]; then
    ok '14 имя в обеих ролях -> 2'
  else
    bad "14 ждали rc=2, получили rc=$GUARD_RC :: $GUARD_OUT"
  fi
}

# 15. ТИШИНА НА ЗЕЛЁНОМ: поимённых строк корзин нет, сводка одна.
tooth_15() {
  RAN=$((RAN + 1))
  printf 'echo "${QUIET_A:-}${QUIET_B:-}"\n' > "$WORKDIR/s15.sh"
  QUIET_A=1 QUIET_B=2 run_guard --subject "$WORKDIR/s15.sh" \
    --pinned QUIET_A --pinned QUIET_B --label t15
  local lines
  lines=$(printf '%s\n' "$GUARD_OUT" | grep -c .)
  if [[ $GUARD_RC -eq 0 && "$GUARD_OUT" != *"запинено: "* && "$lines" -eq 1 ]]; then
    ok '15 зелёный вывод -- одна строка, без поимённых корзин'
  else
    bad "15 ждали rc=0 и РОВНО одну строку без «запинено: », получили rc=$GUARD_RC строк=$lines :: $GUARD_OUT"
  fi
}

# 16. Положительный контроль к 15: при ОТКАЗЕ поимённые строки есть.
# Без него «тишина» зуба 15 неотличима от гварда, разучившегося печатать.
tooth_16() {
  RAN=$((RAN + 1))
  printf 'echo "${LOUD_PIN:-}${LOUD_LEAK:-}"\n' > "$WORKDIR/s16.sh"
  LOUD_PIN=1 LOUD_LEAK=2 run_guard --subject "$WORKDIR/s16.sh" \
    --pinned LOUD_PIN --label t16
  if [[ $GUARD_RC -eq 3 && "$GUARD_OUT" == *"запинено: LOUD_PIN"* \
        && "$GUARD_OUT" == *"унаследовано: LOUD_LEAK"* ]]; then
    ok '16 отказ печатает корзины поимённо'
  else
    bad "16 ждали rc=3 с поимённым «запинено: LOUD_PIN» и «унаследовано: LOUD_LEAK», получили rc=$GUARD_RC :: $GUARD_OUT"
  fi
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
tooth_12
tooth_13
tooth_14
tooth_15
tooth_16

printf '%s прошло, %s провалов, ожидалось %s\n' "$PASSED" "$FAILED" "$EXPECTED_TEETH"
if [[ $RAN -ne $EXPECTED_TEETH ]]; then
  printf 'TEETH_RC=4\n'
  printf 'stand-env-guard-teeth: ОТКАЗ -- прогнано %s, пин EXPECTED_TEETH=%s\n' "$RAN" "$EXPECTED_TEETH" >&2
  exit 4
fi
if [[ $FAILED -ne 0 ]]; then
  printf 'TEETH_RC=1\n'
  exit 1
fi
if [[ $PASSED -ne $EXPECTED_TEETH ]]; then
  printf 'TEETH_RC=4\n'
  printf 'stand-env-guard-teeth: ОТКАЗ -- прошло %s, пин EXPECTED_TEETH=%s\n' "$PASSED" "$EXPECTED_TEETH" >&2
  exit 4
fi
printf 'TEETH_RC=0\n'
exit 0
