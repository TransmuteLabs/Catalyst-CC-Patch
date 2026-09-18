#!/usr/bin/env bash
# Зубы гварда живости ручек. Предмет -- синтетические фикстуры в mktemp,
# НИКОГДА не живой образ: зуб, зависящий от боевых 36 МБ, мерил бы апстрим,
# а не проводку гварда.
#
# CONSTRAINT: ПИН ЧИСЛА зубов -- EXPECTED_TEETH; расхождение прогнанных с пином
# -- провал, даже если каждый отдельный зуб зелёный.
# CONSTRAINT: rm -rf только при непустом WORKDIR.
# CONSTRAINT: в фикстуре образа есть NUL-байт. Без него зуб не отличил бы
# latin-1 от utf-8, а на боевом образе разница между ними -- это разница между
# замером и падением.
set -u

KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
GUARD="${GUARD:-$KIT/tools/env-handles-live-guard.sh}"
EXPECTED_TEETH=15

PASSED=0; FAILED=0; RAN=0; WORKDIR=''
# CONSTRAINT: конец объявляет себя САМ (__DONE=1). Голый EXIT-трап съедает
# обрыв с кодом 0 -- ошибка оболочки или ранний exit до итога выглядели бы
# зелёным прогоном. Часовой краснит ровно этот случай (правило часового,
# claude-patch-all.sh:4327-4332; образец -- tools/gate-kill-teeth.sh).
__DONE=0

cleanup() {
  if [[ -n "${WORKDIR:-}" ]]; then rm -rf "${WORKDIR}"; fi
}

__env_handles_teeth_guard() {
  local __rc=$?
  trap - EXIT
  cleanup
  if [[ "${__DONE:-0}" != 1 && "$__rc" == 0 ]]; then
    echo "ОТКАЗ: env-handles-live-guard-teeth оборвался, не дойдя до конца (ошибка оболочки выше)" >&2
    exit 2
  fi
  exit "$__rc"
}
trap '__env_handles_teeth_guard' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/env-handles-teeth.XXXXXX") || {
  printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог\n' >&2; __DONE=1; exit 2; }
[ -n "$WORKDIR" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога пуст\n' >&2; __DONE=1; exit 2; }

ok()  { PASSED=$((PASSED + 1)); printf '  ok     %s\n' "$1"; }
bad() { FAILED=$((FAILED + 1)); printf '  ПРОВАЛ %s\n' "$1"; }

CTRL=CTRL_HANDLE
mkdir -p "$WORKDIR/ours"
# CONSTRAINT: дом --ours обязан быть НЕпустым во всех зубах, кроме зуба 14:
# гвард роняет прибор на молчащем доме. Файл нейтрален -- ни одного имени
# ручки в нём нет, иначе он зеленил бы чужие зубы.
printf '// нейтральный файл фикстуры\n' > "$WORKDIR/ours/placeholder.ts"

# Фикстура образа: контрольная ручка ЧИТАЕТСЯ (e.CTRL_HANDLE), NUL внутри.
mk_image() {   # $1 -- добавочный текст
  python3 - "$WORKDIR/image.js" "${1:-}" <<'PY'
import sys
p, extra = sys.argv[1], sys.argv[2]
body = 'function f(e){return e.CTRL_HANDLE??20}\x00' + extra
open(p, 'w', encoding='latin-1').write(body)
PY
}

mk_settings() {   # $1 -- JSON объекта env
  python3 - "$WORKDIR/settings.json" "$1" <<'PY'
import json, sys
p, env = sys.argv[1], sys.argv[2]
json.dump({"env": json.loads(env)}, open(p, "w", encoding="utf-8"), indent=2)
PY
}

run_guard() {
  GUARD_RC=0
  GUARD_OUT=$(bash "$GUARD" --settings "$WORKDIR/settings.json" --image "$WORKDIR/image.js" \
                --control "$CTRL" --ours "$WORKDIR/ours" "$@") || GUARD_RC=$?
}

# 1. ручка с читателем-членом в образе -> 0
tooth_1() {
  RAN=$((RAN + 1))
  mk_image 'let q=cfg.LIVE_ONE;'
  mk_settings '{"LIVE_ONE":"x"}'
  run_guard --label t1
  if [[ $GUARD_RC -eq 0 && "$GUARD_OUT" == *"ВЕРДИКТ ВСЕ РУЧКИ ЖИВЫ"* && "$GUARD_OUT" == *"читает хост 1"* ]]; then
    ok '1 читатель-член в образе -> 0'
  else bad "1 ждали rc=0 и «читает хост 1», получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 2. имя в образе есть, но только внутри перечня -> 3, названо МЁРТВОЙ
tooth_2() {
  RAN=$((RAN + 1))
  mk_image 'var names=["DEAD_TWO","OTHER"];'
  mk_settings '{"DEAD_TWO":"99999"}'
  run_guard --label t2
  if [[ $GUARD_RC -eq 3 && "$GUARD_OUT" == *"МЁРТВАЯ"*"DEAD_TWO"* ]]; then
    ok '2 имя только в перечне -> 3 МЁРТВАЯ'
  else bad "2 ждали rc=3 и МЁРТВАЯ DEAD_TWO, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 3. образ имени не знает, но читает наш КОД -> 0
tooth_3() {
  RAN=$((RAN + 1))
  mk_image ''
  printf 'const v = process.env.OUR_THREE\n' > "$WORKDIR/ours/reader.ts"
  mk_settings '{"OUR_THREE":"1"}'
  run_guard --label t3
  rm -f "$WORKDIR/ours/reader.ts"
  if [[ $GUARD_RC -eq 0 && "$GUARD_OUT" == *"читает наш код 1"* ]]; then
    ok '3 читатель в нашем коде -> 0'
  else bad "3 ждали rc=0 и «читает наш код 1», получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 4. читателя нет нигде -> 3, названа БЕСХОЗНОЙ
tooth_4() {
  RAN=$((RAN + 1))
  mk_image ''
  mk_settings '{"ORPHAN_FOUR":"k"}'
  run_guard --label t4
  if [[ $GUARD_RC -eq 3 && "$GUARD_OUT" == *"БЕСХОЗНАЯ"*"ORPHAN_FOUR"* ]]; then
    ok '4 читателя нет нигде -> 3 БЕСХОЗНАЯ'
  else bad "4 ждали rc=3 и БЕСХОЗНАЯ ORPHAN_FOUR, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 5. потребитель -- подстановка ${ИМЯ} в тех же настройках -> 0
tooth_5() {
  RAN=$((RAN + 1))
  mk_image ''
  python3 - "$WORKDIR/settings.json" <<'PY'
import json, sys
json.dump({"env": {"SUBST_FIVE": "secret"},
           "mcpServers": {"s": {"env": {"SUBST_FIVE": "${SUBST_FIVE}"}}}},
          open(sys.argv[1], "w", encoding="utf-8"), indent=2)
PY
  run_guard --label t5
  if [[ $GUARD_RC -eq 0 && "$GUARD_OUT" == *"подстановка в настройках 1"* ]]; then
    ok '5 подстановка ${ИМЯ} в настройках -> 0'
  else bad "5 ждали rc=0 и «подстановка в настройках 1», получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 6. --external на бесхозную -> 0, имя названо в сводке
tooth_6() {
  RAN=$((RAN + 1))
  mk_image ''
  mk_settings '{"EXT_SIX":"k"}'
  run_guard --label t6 --external EXT_SIX
  if [[ $GUARD_RC -eq 0 && "$GUARD_OUT" == *"объявлено-внешним 1 (EXT_SIX)"* ]]; then
    ok '6 объявленный внешний потребитель -> 0, назван'
  else bad "6 ждали rc=0 и «объявлено-внешним 1 (EXT_SIX)», получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 7. --external на ручку, у которой читатель ЕСТЬ -> 2 (противоречие декларации)
tooth_7() {
  RAN=$((RAN + 1))
  mk_image 'let q=cfg.LIVE_SEVEN;'
  mk_settings '{"LIVE_SEVEN":"x"}'
  run_guard --label t7 --external LIVE_SEVEN
  if [[ $GUARD_RC -eq 2 && "$GUARD_OUT" == *"ОТКАЗ ДЕКЛАРАЦИИ"*"LIVE_SEVEN"* ]]; then
    ok '7 --external на живую ручку -> 2'
  else bad "7 ждали rc=2 ОТКАЗ ДЕКЛАРАЦИИ, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 8. контрольная ручка не читается -> 2 ПРИБОР НЕДОСТУПЕН, вердикта нет
tooth_8() {
  RAN=$((RAN + 1))
  mk_image 'let q=cfg.LIVE_EIGHT;'
  mk_settings '{"LIVE_EIGHT":"x"}'
  GUARD_RC=0
  GUARD_OUT=$(bash "$GUARD" --settings "$WORKDIR/settings.json" --image "$WORKDIR/image.js" \
                --control NO_SUCH_CONTROL --ours "$WORKDIR/ours" --label t8) || GUARD_RC=$?
  if [[ $GUARD_RC -eq 2 && "$GUARD_OUT" == *"ПРИБОР НЕДОСТУПЕН"* && "$GUARD_OUT" != *"ВЕРДИКТ"* ]]; then
    ok '8 мёртвый контроль -> 2 без вердикта'
  else bad "8 ждали rc=2 ПРИБОР НЕДОСТУПЕН без ВЕРДИКТ, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 9. образа нет -> 2
tooth_9() {
  RAN=$((RAN + 1))
  mk_settings '{"ANY_NINE":"x"}'
  GUARD_RC=0
  GUARD_OUT=$(bash "$GUARD" --settings "$WORKDIR/settings.json" --image "$WORKDIR/no-such-image.js" \
                --control "$CTRL" --label t9) || GUARD_RC=$?
  if [[ $GUARD_RC -eq 2 ]]; then ok '9 образа нет -> 2'
  else bad "9 ждали rc=2, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 10. упоминание в ДОКУМЕНТЕ нашего дерева читателем не считается -> 3
tooth_10() {
  RAN=$((RAN + 1))
  mk_image ''
  printf 'Ручка DOC_TEN описана в этом документе.\n' > "$WORKDIR/ours/notes.md"
  mk_settings '{"DOC_TEN":"x"}'
  run_guard --label t10
  rm -f "$WORKDIR/ours/notes.md"
  if [[ $GUARD_RC -eq 3 && "$GUARD_OUT" == *"БЕСХОЗНАЯ"*"DOC_TEN"* ]]; then
    ok '10 упоминание в доке не читатель -> 3'
  else bad "10 ждали rc=3 БЕСХОЗНАЯ DOC_TEN, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 11. тишина на зелёном: ровно одна строка
tooth_11() {
  RAN=$((RAN + 1))
  mk_image 'let a=cfg.Q_A; let b=cfg.Q_B;'
  mk_settings '{"Q_A":"1","Q_B":"2"}'
  run_guard --label t11
  # CONSTRAINT: код подстановки берётся ЯВНО. `grep -c` отдаёт 1 при НУЛЕ
  # совпадений -- это счёт, а не отказ; отказом прибора считается 2 и выше.
  local lines __lrc=0
  lines=$(printf '%s\n' "$GUARD_OUT" | grep -c .) || __lrc=$?
  if (( __lrc > 1 )); then
    printf 'ПРИБОР НЕДОСТУПЕН: счёт строк вывода отказал кодом %s\n' "$__lrc" >&2
    __DONE=1
    exit 2
  fi
  if [[ $GUARD_RC -eq 0 && "$lines" -eq 1 ]]; then
    ok '11 зелёный вывод -- ровно одна строка'
  else bad "11 ждали rc=0 и одну строку, получили rc=$GUARD_RC строк=$lines :: $GUARD_OUT"; fi
}

# 12. положительный контроль к 11: отказ печатает поимённо
tooth_12() {
  RAN=$((RAN + 1))
  mk_image 'let a=cfg.LOUD_LIVE; var names=["LOUD_DEAD"];'
  mk_settings '{"LOUD_LIVE":"1","LOUD_DEAD":"2","LOUD_ORPHAN":"3"}'
  run_guard --label t12
  if [[ $GUARD_RC -eq 3 && "$GUARD_OUT" == *"МЁРТВАЯ"*"LOUD_DEAD"* && "$GUARD_OUT" == *"БЕСХОЗНАЯ"*"LOUD_ORPHAN"* ]]; then
    ok '12 отказ печатает обе корзины поимённо'
  else bad "12 ждали rc=3 с LOUD_DEAD и LOUD_ORPHAN поимённо, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 13. ноль ручек env -> 5 (ПУСТО ≠ НОЛЬ)
tooth_13() {
  RAN=$((RAN + 1))
  mk_image ''
  mk_settings '{}'
  run_guard --label t13
  if [[ $GUARD_RC -eq 5 ]]; then ok '13 ноль ручек -> 5'
  else bad "13 ждали rc=5, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 14. дом --ours без единого сканируемого файла -> 2 (молчащий дом неотличим
#     от дома без читателей: именно так живая ручка получила «бесхозная»)
tooth_14() {
  RAN=$((RAN + 1))
  mk_image 'let q=cfg.LIVE_FOURTEEN;'
  mk_settings '{"LIVE_FOURTEEN":"x"}'
  mkdir -p "$WORKDIR/empty-home"
  rm -f "$WORKDIR/empty-home"/*
  GUARD_RC=0
  GUARD_OUT=$(bash "$GUARD" --settings "$WORKDIR/settings.json" --image "$WORKDIR/image.js" \
                --control "$CTRL" --ours "$WORKDIR/empty-home" --label t14 2>&1) || GUARD_RC=$?
  if [[ $GUARD_RC -eq 2 && "$GUARD_OUT" == *"ПРИБОР НЕДОСТУПЕН"* && "$GUARD_OUT" != *"ВЕРДИКТ"* ]]; then
    ok '14 молчащий дом --ours -> 2 без вердикта'
  else bad "14 ждали rc=2 ПРИБОР НЕДОСТУПЕН без ВЕРДИКТ, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 15. читатель на Rust засчитывается: std::env::var в .rs -- живой читатель,
#     потому что claude-hooks запускаются потомками Claude Code
tooth_15() {
  RAN=$((RAN + 1))
  mk_image 'let q=cfg.UNRELATED_FIFTEEN;'
  mk_settings '{"RUST_FIFTEEN":"x"}'
  printf 'let d = std::env::var("RUST_FIFTEEN").ok();\n' > "$WORKDIR/ours/hook.rs"
  run_guard --label t15
  local rc=$GUARD_RC out=$GUARD_OUT
  rm -f "$WORKDIR/ours/hook.rs"
  if [[ $rc -eq 0 && "$out" == *"читает наш код 1"* ]]; then
    ok '15 читатель на Rust засчитан'
  else bad "15 ждали rc=0 и «читает наш код 1», получили rc=$rc :: $out"; fi
}

tooth_1; tooth_2; tooth_3; tooth_4; tooth_5; tooth_6; tooth_7
tooth_8; tooth_9; tooth_10; tooth_11; tooth_12; tooth_13
tooth_14; tooth_15

printf '%s прошло, %s провалов, ожидалось %s\n' "$PASSED" "$FAILED" "$EXPECTED_TEETH"
if [[ $RAN -ne $EXPECTED_TEETH ]]; then
  printf 'TEETH_RC=4\n'
  printf 'env-handles-live-guard-teeth: ОТКАЗ -- прогнано %s, пин EXPECTED_TEETH=%s\n' "$RAN" "$EXPECTED_TEETH" >&2
  __DONE=1
  exit 4
fi
if [[ $FAILED -ne 0 ]]; then printf 'TEETH_RC=1\n'; __DONE=1; exit 1; fi
if [[ $PASSED -ne $EXPECTED_TEETH ]]; then
  printf 'TEETH_RC=4\n'
  printf 'env-handles-live-guard-teeth: ОТКАЗ -- прошло %s, пин EXPECTED_TEETH=%s\n' "$PASSED" "$EXPECTED_TEETH" >&2
  __DONE=1
  exit 4
fi
printf 'TEETH_RC=0\n'
__DONE=1
exit 0
