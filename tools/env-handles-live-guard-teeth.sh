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
EXPECTED_TEETH=49

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
# CONSTRAINT: положительный контроль второй стороны: OURS_CTRL обязан
# читаться СТРУКТУРНО в placeholder.ts каждого зуба; ручкой он не является
# ни в одной фикстуре, поэтому чужие зубы не зеленит.
OURS_CTRL=OURS_CONTROL_HANDLE
mkdir -p "$WORKDIR/ours"
# CONSTRAINT: дом --ours обязан быть НЕпустым во всех зубах, кроме зуба 14:
# гвард роняет прибор на молчащем доме. Файл несёт ТОЛЬКО контрольного
# читателя OURS_CTRL -- ни одного имени ручки в нём нет, иначе он зеленил
# бы чужие зубы.
printf '// контроль прибора: %s\nconst _probe = process.env.%s;\n' "$OURS_CTRL" "$OURS_CTRL" > "$WORKDIR/ours/placeholder.ts"

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
                --control "$CTRL" --control-ours "$OURS_CTRL" --ours "$WORKDIR/ours" "$@") || GUARD_RC=$?
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

# 16. упоминание имени в комментарии .sh -- НЕ читатель: подстрочный счёт
#     зеленит ручку, которой нет доступа; имя названо УПОМЯНУТОЙ-НО-НЕ-ЧИТАЕМОЙ
tooth_16() {
  RAN=$((RAN + 1))
  mk_image ''
  printf '# комментарий: ручка CMT_SH_SIXTEEN здесь только упомянута\n' > "$WORKDIR/ours/comment.sh"
  mk_settings '{"CMT_SH_SIXTEEN":"x"}'
  run_guard --label t16
  rm -f "$WORKDIR/ours/comment.sh"
  if [[ $GUARD_RC -eq 3 && "$GUARD_OUT" == *"УПОМЯНУТА-НО-НЕ-ЧИТАЕТСЯ"*"CMT_SH_SIXTEEN"* && "$GUARD_OUT" == *"упомянута-но-не-читается 1"* ]]; then
    ok '16 упоминание в комментарии .sh -> 3 УПОМЯНУТА-НО-НЕ-ЧИТАЕТСЯ'
  else bad "16 ждали rc=3 УПОМЯНУТА-НО-НЕ-ЧИТАЕТСЯ CMT_SH_SIXTEEN, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 17. упоминание имени в комментарии .py -- НЕ читатель
tooth_17() {
  RAN=$((RAN + 1))
  mk_image ''
  printf '# see CMT_PY_SEVENTEEN for details\npass\n' > "$WORKDIR/ours/comment.py"
  mk_settings '{"CMT_PY_SEVENTEEN":"x"}'
  run_guard --label t17
  rm -f "$WORKDIR/ours/comment.py"
  if [[ $GUARD_RC -eq 3 && "$GUARD_OUT" == *"УПОМЯНУТА-НО-НЕ-ЧИТАЕТСЯ"*"CMT_PY_SEVENTEEN"* ]]; then
    ok '17 упоминание в комментарии .py -> 3'
  else bad "17 ждали rc=3 УПОМЯНУТА-НО-НЕ-ЧИТАЕТСЯ CMT_PY_SEVENTEEN, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 18. упоминание имени в комментарии .ts -- НЕ читатель
tooth_18() {
  RAN=$((RAN + 1))
  mk_image ''
  printf '// CMT_TS_EIGHTEEN is documented here\n' > "$WORKDIR/ours/comment.ts"
  mk_settings '{"CMT_TS_EIGHTEEN":"x"}'
  run_guard --label t18
  rm -f "$WORKDIR/ours/comment.ts"
  if [[ $GUARD_RC -eq 3 && "$GUARD_OUT" == *"УПОМЯНУТА-НО-НЕ-ЧИТАЕТСЯ"*"CMT_TS_EIGHTEEN"* ]]; then
    ok '18 упоминание в комментарии .ts -> 3'
  else bad "18 ждали rc=3 УПОМЯНУТА-НО-НЕ-ЧИТАЕТСЯ CMT_TS_EIGHTEEN, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 19. упоминание имени в комментарии .rs -- НЕ читатель
tooth_19() {
  RAN=$((RAN + 1))
  mk_image ''
  printf '// CMT_RS_NINETEEN documented in a comment\n' > "$WORKDIR/ours/comment.rs"
  mk_settings '{"CMT_RS_NINETEEN":"x"}'
  run_guard --label t19
  rm -f "$WORKDIR/ours/comment.rs"
  if [[ $GUARD_RC -eq 3 && "$GUARD_OUT" == *"УПОМЯНУТА-НО-НЕ-ЧИТАЕТСЯ"*"CMT_RS_NINETEEN"* ]]; then
    ok '19 упоминание в комментарии .rs -> 3'
  else bad "19 ждали rc=3 УПОМЯНУТА-НО-НЕ-ЧИТАЕТСЯ CMT_RS_NINETEEN, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 20. py: os.environ["ИМЯ"] -- читатель
tooth_20() {
  RAN=$((RAN + 1))
  mk_image ''
  printf 'import os\nv = os.environ["PY_IDX_TWENTY"]\n' > "$WORKDIR/ours/reader.py"
  mk_settings '{"PY_IDX_TWENTY":"x"}'
  run_guard --label t20
  rm -f "$WORKDIR/ours/reader.py"
  if [[ $GUARD_RC -eq 0 && "$GUARD_OUT" == *"читает наш код 1"* ]]; then
    ok '20 os.environ["ИМЯ"] в .py -> 0'
  else bad "20 ждали rc=0 «читает наш код 1», получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 21. py: os.environ.get("ИМЯ", ...) -- читатель (именованный вызов)
tooth_21() {
  RAN=$((RAN + 1))
  mk_image ''
  printf 'import os\nv = os.environ.get("PY_ENVGET_TWENTYONE", "d")\n' > "$WORKDIR/ours/reader.py"
  mk_settings '{"PY_ENVGET_TWENTYONE":"x"}'
  run_guard --label t21
  rm -f "$WORKDIR/ours/reader.py"
  if [[ $GUARD_RC -eq 0 && "$GUARD_OUT" == *"читает наш код 1"* ]]; then
    ok '21 os.environ.get("ИМЯ",...) в .py -> 0'
  else bad "21 ждали rc=0 «читает наш код 1», получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 22. py: os.getenv("ИМЯ") -- читатель
tooth_22() {
  RAN=$((RAN + 1))
  mk_image ''
  printf 'import os\nv = os.getenv("PY_GETENV_TWENTYTWO")\n' > "$WORKDIR/ours/reader.py"
  mk_settings '{"PY_GETENV_TWENTYTWO":"x"}'
  run_guard --label t22
  rm -f "$WORKDIR/ours/reader.py"
  if [[ $GUARD_RC -eq 0 && "$GUARD_OUT" == *"читает наш код 1"* ]]; then
    ok '22 os.getenv("ИМЯ") в .py -> 0'
  else bad "22 ждали rc=0 «читает наш код 1», получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 23. py: environ["ИМЯ"] после from os import environ -- читатель
tooth_23() {
  RAN=$((RAN + 1))
  mk_image ''
  printf 'from os import environ\nv = environ["PY_BARE_TWENTYTHREE"]\n' > "$WORKDIR/ours/reader.py"
  mk_settings '{"PY_BARE_TWENTYTHREE":"x"}'
  run_guard --label t23
  rm -f "$WORKDIR/ours/reader.py"
  if [[ $GUARD_RC -eq 0 && "$GUARD_OUT" == *"читает наш код 1"* ]]; then
    ok '23 environ["ИМЯ"] в .py -> 0'
  else bad "23 ждали rc=0 «читает наш код 1», получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 24. py: getenv("ИМЯ_ДРУГОЕ") -- НЕ читатель для ИМЯ: имя call-аргумента
#     обязано совпадать целиком, упомянутая подстрока не считается
tooth_24() {
  RAN=$((RAN + 1))
  mk_image ''
  printf 'import os\nv = os.getenv("PYCALL_TWENTYFOUR_ALT")\n' > "$WORKDIR/ours/reader.py"
  mk_settings '{"PYCALL_TWENTYFOUR":"x"}'
  run_guard --label t24
  rm -f "$WORKDIR/ours/reader.py"
  if [[ $GUARD_RC -eq 3 && "$GUARD_OUT" == *"УПОМЯНУТА-НО-НЕ-ЧИТАЕТСЯ"*"PYCALL_TWENTYFOUR"* ]]; then
    ok '24 getenv("ИМЯ_ДРУГОЕ") не читатель для ИМЯ -> 3'
  else bad "24 ждали rc=3 УПОМЯНУТА-НО-НЕ-ЧИТАЕТСЯ PYCALL_TWENTYFOUR, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 25. rs: env::var("ИМЯ") -- читатель
tooth_25() {
  RAN=$((RAN + 1))
  mk_image ''
  printf 'let d = env::var("RS_TWENTYFIVE").ok();\n' > "$WORKDIR/ours/hook.rs"
  mk_settings '{"RS_TWENTYFIVE":"x"}'
  run_guard --label t25
  rm -f "$WORKDIR/ours/hook.rs"
  if [[ $GUARD_RC -eq 0 && "$GUARD_OUT" == *"читает наш код 1"* ]]; then
    ok '25 env::var("ИМЯ") в .rs -> 0'
  else bad "25 ждали rc=0 «читает наш код 1», получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 26. rs: std::env::var_os("ИМЯ") -- читатель (полный префикс тоже покрыт)
tooth_26() {
  RAN=$((RAN + 1))
  mk_image ''
  printf 'let d = std::env::var_os("RS_TWENTYSIX");\n' > "$WORKDIR/ours/hook.rs"
  mk_settings '{"RS_TWENTYSIX":"x"}'
  run_guard --label t26
  rm -f "$WORKDIR/ours/hook.rs"
  if [[ $GUARD_RC -eq 0 && "$GUARD_OUT" == *"читает наш код 1"* ]]; then
    ok '26 std::env::var_os("ИМЯ") в .rs -> 0'
  else bad "26 ждали rc=0 «читает наш код 1», получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 27. sh: ${ИМЯ:-x} -- читатель (параметрическое расширение)
tooth_27() {
  RAN=$((RAN + 1))
  mk_image ''
  printf 'echo "${SH_DEF_TWENTYSEVEN:-x}"\n' > "$WORKDIR/ours/script.sh"
  mk_settings '{"SH_DEF_TWENTYSEVEN":"x"}'
  run_guard --label t27
  rm -f "$WORKDIR/ours/script.sh"
  if [[ $GUARD_RC -eq 0 && "$GUARD_OUT" == *"читает наш код 1"* ]]; then
    ok '27 ${ИМЯ:-x} в .sh -> 0'
  else bad "27 ждали rc=0 «читает наш код 1», получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 28. sh: $ИМЯ -- читатель
tooth_28() {
  RAN=$((RAN + 1))
  mk_image ''
  printf 'echo "$SH_PLAIN_TWENTYEIGHT"\n' > "$WORKDIR/ours/script.sh"
  mk_settings '{"SH_PLAIN_TWENTYEIGHT":"x"}'
  run_guard --label t28
  rm -f "$WORKDIR/ours/script.sh"
  if [[ $GUARD_RC -eq 0 && "$GUARD_OUT" == *"читает наш код 1"* ]]; then
    ok '28 $ИМЯ в .sh -> 0'
  else bad "28 ждали rc=0 «читает наш код 1», получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 29. sh: export ИМЯ -- читатель
tooth_29() {
  RAN=$((RAN + 1))
  mk_image ''
  printf 'export SH_EXPORT_TWENTYNINE\n' > "$WORKDIR/ours/script.sh"
  mk_settings '{"SH_EXPORT_TWENTYNINE":"x"}'
  run_guard --label t29
  rm -f "$WORKDIR/ours/script.sh"
  if [[ $GUARD_RC -eq 0 && "$GUARD_OUT" == *"читает наш код 1"* ]]; then
    ok '29 export ИМЯ в .sh -> 0'
  else bad "29 ждали rc=0 «читает наш код 1», получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 30. sh: префикс окружения ИМЯ=... команда -- читатель
tooth_30() {
  RAN=$((RAN + 1))
  mk_image ''
  printf 'SH_PREFIX_THIRTY=1 /usr/bin/env true\n' > "$WORKDIR/ours/script.sh"
  mk_settings '{"SH_PREFIX_THIRTY":"x"}'
  run_guard --label t30
  rm -f "$WORKDIR/ours/script.sh"
  if [[ $GUARD_RC -eq 0 && "$GUARD_OUT" == *"читает наш код 1"* ]]; then
    ok '30 префикс ИМЯ=... команда в .sh -> 0'
  else bad "30 ждали rc=0 «читает наш код 1», получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 31. голое ИМЯ в тексте .sh (без $, без =) -- НЕ читатель
tooth_31() {
  RAN=$((RAN + 1))
  mk_image ''
  printf 'echo BARE_THIRTYONE here\n' > "$WORKDIR/ours/script.sh"
  mk_settings '{"BARE_THIRTYONE":"x"}'
  run_guard --label t31
  rm -f "$WORKDIR/ours/script.sh"
  if [[ $GUARD_RC -eq 3 && "$GUARD_OUT" == *"УПОМЯНУТА-НО-НЕ-ЧИТАЕТСЯ"*"BARE_THIRTYONE"* ]]; then
    ok '31 голое ИМЯ в .sh -> 3'
  else bad "31 ждали rc=3 УПОМЯНУТА-НО-НЕ-ЧИТАЕТСЯ BARE_THIRTYONE, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 32. граница идентификатора: ИМЯ_СУФФИКС не читатель для ИМЯ во всех
#     языковых формах сразу (js-член, sh-скобки, py-скобки, rs-вызов)
tooth_32() {
  RAN=$((RAN + 1))
  mk_image ''
  printf 'const v = process.env.SUFFIX_THIRTYTWO_X;\n' > "$WORKDIR/ours/s1.ts"
  printf 'echo "${SUFFIX_THIRTYTWO_Y}"\n' > "$WORKDIR/ours/s2.sh"
  printf 'import os\nv = os.environ["SUFFIX_THIRTYTWO_Z"]\n' > "$WORKDIR/ours/s3.py"
  printf 'let d = env::var("SUFFIX_THIRTYTWO_W").ok();\n' > "$WORKDIR/ours/s4.rs"
  mk_settings '{"SUFFIX_THIRTYTWO":"x"}'
  run_guard --label t32
  rm -f "$WORKDIR/ours/s1.ts" "$WORKDIR/ours/s2.sh" "$WORKDIR/ours/s3.py" "$WORKDIR/ours/s4.rs"
  if [[ $GUARD_RC -eq 3 && "$GUARD_OUT" == *"УПОМЯНУТА-НО-НЕ-ЧИТАЕТСЯ"*"SUFFIX_THIRTYTWO"* ]]; then
    ok '32 ИМЯ_СУФФИКС не читатель для ИМЯ (4 языка) -> 3'
  else bad "32 ждали rc=3 УПОМЯНУТА-НО-НЕ-ЧИТАЕТСЯ SUFFIX_THIRTYTWO, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 33. js: скобочный доступ cfg["ИМЯ"] с индексируемым перед [ -- читатель
tooth_33() {
  RAN=$((RAN + 1))
  mk_image ''
  printf 'const v = settings["JS_BR_THIRTYTHREE"];\n' > "$WORKDIR/ours/reader.ts"
  mk_settings '{"JS_BR_THIRTYTHREE":"x"}'
  run_guard --label t33
  rm -f "$WORKDIR/ours/reader.ts"
  if [[ $GUARD_RC -eq 0 && "$GUARD_OUT" == *"читает наш код 1"* ]]; then
    ok '33 идентификатор["ИМЯ"] в .ts -> 0'
  else bad "33 ждали rc=0 «читает наш код 1», получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 34. js: ЛИТЕРАЛ МАССИВА ["ИМЯ"] в нашем коде -- НЕ читатель (нет
#      индексируемого перед [) -- тот же класс, что зуб 12 у образа
tooth_34() {
  RAN=$((RAN + 1))
  mk_image ''
  printf 'const names = ["JS_ARR_THIRTYFOUR"];\n' > "$WORKDIR/ours/reader.ts"
  mk_settings '{"JS_ARR_THIRTYFOUR":"x"}'
  run_guard --label t34
  rm -f "$WORKDIR/ours/reader.ts"
  if [[ $GUARD_RC -eq 3 && "$GUARD_OUT" == *"УПОМЯНУТА-НО-НЕ-ЧИТАЕТСЯ"*"JS_ARR_THIRTYFOUR"* ]]; then
    ok '34 литерал массива ["ИМЯ"] в .ts -> 3'
  else bad "34 ждали rc=3 УПОМЯНУТА-НО-НЕ-ЧИТАЕТСЯ JS_ARR_THIRTYFOUR, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 35. читатель есть ТОЛЬКО в каталоге dist (SKIP_DIR первого прохода) --
#     расхождение сборки и исходника, СВОЙ код 6 и своя строка
tooth_35() {
  RAN=$((RAN + 1))
  mk_image ''
  mkdir -p "$WORKDIR/ours/dist"
  printf 'const v = process.env.DIST_THIRTYFIVE;\n' > "$WORKDIR/ours/dist/reader.ts"
  mk_settings '{"DIST_THIRTYFIVE":"x"}'
  run_guard --label t35
  rm -rf "$WORKDIR/ours/dist"
  if [[ $GUARD_RC -eq 6 && "$GUARD_OUT" == *"ТОЛЬКО-СБОРКА"*"DIST_THIRTYFIVE"* && "$GUARD_OUT" == *"только-сборка 1"* ]]; then
    ok '35 читатель только в dist -> 6 ТОЛЬКО-СБОРКА'
  else bad "35 ждали rc=6 ТОЛЬКО-СБОРКА DIST_THIRTYFIVE, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 36. мёртвый контроль нашего кода -> 2 ПРИБОР НЕДОСТУПЕН, вердикта нет
tooth_36() {
  RAN=$((RAN + 1))
  mk_image ''
  mk_settings '{"ANY_THIRTYSIX":"x"}'
  run_guard --label t36 --control-ours NO_SUCH_OURS
  if [[ $GUARD_RC -eq 2 && "$GUARD_OUT" == *"ПРИБОР НЕДОСТУПЕН"* && "$GUARD_OUT" != *"ВЕРДИКТ"* ]]; then
    ok '36 мёртвый контроль-наш -> 2 без вердикта'
  else bad "36 ждали rc=2 ПРИБОР НЕДОСТУПЕН без ВЕРДИКТ, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# Фикстура разделения домов: fakeroot с детьми-каталогами, файл [ours]/[foreign].
mk_homes_file() {   # $1 -- содержимое секций после root
  printf 'root %s\n%s\n' "$WORKDIR/fakeroot" "$1" > "$WORKDIR/homes.txt"
}

# 37. каталог-ребёнок корня вне обоих списков -> 2 с ИМЕНЕМ каталога:
#     дрейф дерева ломает ПРИБОР, а не предмет (fail-closed)
tooth_37() {
  RAN=$((RAN + 1))
  mk_image ''
  mkdir -p "$WORKDIR/fakeroot/ourA" "$WORKDIR/fakeroot/forB" "$WORKDIR/fakeroot/unC"
  printf 'const v = process.env.%s;\n' "$OURS_CTRL" > "$WORKDIR/fakeroot/ourA/placeholder.ts"
  mk_homes_file '[ours]
ourA
[foreign]
forB'
  mk_settings '{"ANY_37":"x"}'
  GUARD_RC=0
  GUARD_OUT=$(bash "$GUARD" --settings "$WORKDIR/settings.json" --image "$WORKDIR/image.js" \
                --control "$CTRL" --control-ours "$OURS_CTRL" --homes "$WORKDIR/homes.txt" --label t37) || GUARD_RC=$?
  if [[ $GUARD_RC -eq 2 && "$GUARD_OUT" == *"ПРИБОР НЕДОСТУПЕН"* && "$GUARD_OUT" == *"unC"* && "$GUARD_OUT" != *"ВЕРДИКТ"* ]]; then
    ok '37 каталог вне [ours]/[foreign] -> 2 с именем unC'
  else bad "37 ждали rc=2 ПРИБОР НЕДОСТУПЕН с unC без ВЕРДИКТ, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
  rm -rf "$WORKDIR/fakeroot" "$WORKDIR/homes.txt"
}

# 38. имя, читаемое ТОЛЬКО в ЧУЖОМ доме, -- НЕ читатель: чужой код не
#     легализует нашу ручку
tooth_38() {
  RAN=$((RAN + 1))
  mk_image ''
  mkdir -p "$WORKDIR/fakeroot/ourA" "$WORKDIR/fakeroot/forB"
  printf 'const v = process.env.%s;\n' "$OURS_CTRL" > "$WORKDIR/fakeroot/ourA/placeholder.ts"
  printf 'const x = process.env.FOREIGN_ONLY_38;\n' > "$WORKDIR/fakeroot/forB/reader.ts"
  mk_homes_file '[ours]
ourA
[foreign]
forB'
  mk_settings '{"FOREIGN_ONLY_38":"x"}'
  GUARD_RC=0
  GUARD_OUT=$(bash "$GUARD" --settings "$WORKDIR/settings.json" --image "$WORKDIR/image.js" \
                --control "$CTRL" --control-ours "$OURS_CTRL" --homes "$WORKDIR/homes.txt" --label t38) || GUARD_RC=$?
  if [[ $GUARD_RC -eq 3 && "$GUARD_OUT" == *"БЕСХОЗНАЯ"*"FOREIGN_ONLY_38"* ]]; then
    ok '38 читатель только в чужом доме -> 3 БЕСХОЗНАЯ'
  else bad "38 ждали rc=3 БЕСХОЗНАЯ FOREIGN_ONLY_38, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
  rm -rf "$WORKDIR/fakeroot" "$WORKDIR/homes.txt"
}

# 39. то же имя, читаемое в НАШЕМ доме, -- читатель (позитив к 38)
tooth_39() {
  RAN=$((RAN + 1))
  mk_image ''
  mkdir -p "$WORKDIR/fakeroot/ourA" "$WORKDIR/fakeroot/forB"
  printf 'const v = process.env.%s;\nconst y = process.env.OURS_READ_39;\n' "$OURS_CTRL" > "$WORKDIR/fakeroot/ourA/reader.ts"
  printf 'const x = process.env.OURS_READ_39;\n' > "$WORKDIR/fakeroot/forB/other.ts"
  mk_homes_file '[ours]
ourA
[foreign]
forB'
  mk_settings '{"OURS_READ_39":"x"}'
  GUARD_RC=0
  GUARD_OUT=$(bash "$GUARD" --settings "$WORKDIR/settings.json" --image "$WORKDIR/image.js" \
                --control "$CTRL" --control-ours "$OURS_CTRL" --homes "$WORKDIR/homes.txt" --label t39) || GUARD_RC=$?
  if [[ $GUARD_RC -eq 0 && "$GUARD_OUT" == *"читает наш код 1"* ]]; then
    ok '39 тот же читатель в нашем доме -> 0'
  else bad "39 ждали rc=0 «читает наш код 1», получили rc=$GUARD_RC :: $GUARD_OUT"; fi
  rm -rf "$WORKDIR/fakeroot" "$WORKDIR/homes.txt"
}

# 40. оба списка непусты и ПОКРЫВАЮТ всех детей -> сверка молчит, прибор
#     доходит до предмета (два наших дома, читатель во втором)
tooth_40() {
  RAN=$((RAN + 1))
  mk_image ''
  mkdir -p "$WORKDIR/fakeroot/ourA" "$WORKDIR/fakeroot/ourD" "$WORKDIR/fakeroot/forB"
  printf 'const v = process.env.%s;\n' "$OURS_CTRL" > "$WORKDIR/fakeroot/ourA/placeholder.ts"
  printf 'const d = process.env.MULTI_FORTY;\n' > "$WORKDIR/fakeroot/ourD/reader.ts"
  mk_homes_file '[ours]
ourA
ourD
[foreign]
forB'
  mk_settings '{"MULTI_FORTY":"x"}'
  GUARD_RC=0
  GUARD_OUT=$(bash "$GUARD" --settings "$WORKDIR/settings.json" --image "$WORKDIR/image.js" \
                --control "$CTRL" --control-ours "$OURS_CTRL" --homes "$WORKDIR/homes.txt" --label t40) || GUARD_RC=$?
  if [[ $GUARD_RC -eq 0 && "$GUARD_OUT" == *"читает наш код 1"* ]]; then
    ok '40 полное покрытие двумя нашими -> 0'
  else bad "40 ждали rc=0 «читает наш код 1», получили rc=$GUARD_RC :: $GUARD_OUT"; fi
  rm -rf "$WORKDIR/fakeroot" "$WORKDIR/homes.txt"
}

# --- реестр внешних ручек (--external-file) и предикат Go -------------------
# CONSTRAINT: реестр -- ФАЙЛ, а не набор флагов: каждый отказ его разбора
# обязан иметь СВОЙ зуб. Два отказа с одним кодом и одной строкой
# неразличимы, поэтому зубы 42--46 требуют ИМЯ отказа, а не только код 2.
mk_ext_file() {   # $1 -- содержимое реестра
  printf '%s\n' "$1" > "$WORKDIR/external.txt"
}

# 41. --external-file на бесхозную -> 0, имя названо (файл РАЗОБРАН, не проглочен)
tooth_41() {
  RAN=$((RAN + 1))
  mk_image ''
  mk_settings '{"EXT_FILE_41":"k"}'
  mk_ext_file "$(printf '# шапка\n\nEXT_FILE_41\tсторонняя программа, замер такой-то')"
  run_guard --label t41 --external-file "$WORKDIR/external.txt"
  if [[ $GUARD_RC -eq 0 && "$GUARD_OUT" == *"объявлено-внешним 1 (EXT_FILE_41)"* ]]; then
    ok '41 реестр разобран -> 0, имя названо'
  else bad "41 ждали rc=0 и «объявлено-внешним 1 (EXT_FILE_41)», получили rc=$GUARD_RC :: $GUARD_OUT"; fi
  rm -f "$WORKDIR/external.txt"
}

# 42. реестр НАЗВАН, но отсутствует -> 2 со СВОИМ именем отказа
tooth_42() {
  RAN=$((RAN + 1))
  mk_image ''
  mk_settings '{"EXT_FILE_42":"k"}'
  rm -f "$WORKDIR/external.txt"
  run_guard --label t42 --external-file "$WORKDIR/external.txt"
  if [[ $GUARD_RC -eq 2 && "$GUARD_OUT" == *"реестр внешних ручек не прочитан"* ]]; then
    ok '42 реестр отсутствует -> 2 со своим именем'
  else bad "42 ждали rc=2 «реестр внешних ручек не прочитан», получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 43. строка без основания -> 2 со СВОИМ именем (запись без причины = забытая)
tooth_43() {
  RAN=$((RAN + 1))
  mk_image ''
  mk_settings '{"EXT_FILE_43":"k"}'
  mk_ext_file 'EXT_FILE_43'
  run_guard --label t43 --external-file "$WORKDIR/external.txt"
  if [[ $GUARD_RC -eq 2 && "$GUARD_OUT" == *"EXT_FILE_43"*"нет основания"* ]]; then
    ok '43 имя без основания -> 2 со своим именем'
  else bad "43 ждали rc=2 «нет основания» EXT_FILE_43, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
  rm -f "$WORKDIR/external.txt"
}

# 44. имя объявлено ДВАЖДЫ -> 2 со СВОИМ именем и обеими строками
tooth_44() {
  RAN=$((RAN + 1))
  mk_image ''
  mk_settings '{"EXT_FILE_44":"k"}'
  mk_ext_file "$(printf 'EXT_FILE_44\tпервое основание\nEXT_FILE_44\tвторое основание')"
  run_guard --label t44 --external-file "$WORKDIR/external.txt"
  if [[ $GUARD_RC -eq 2 && "$GUARD_OUT" == *"EXT_FILE_44"*"объявлено дважды"* ]]; then
    ok '44 дубль имени в реестре -> 2 со своим именем'
  else bad "44 ждали rc=2 «объявлено дважды» EXT_FILE_44, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
  rm -f "$WORKDIR/external.txt"
}

# 45. первое поле -- не имя ручки -> 2 со СВОИМ именем (защита от сдвига полей)
tooth_45() {
  RAN=$((RAN + 1))
  mk_image ''
  mk_settings '{"EXT_FILE_45":"k"}'
  mk_ext_file "$(printf 'не имя ручки\tоснование')"
  run_guard --label t45 --external-file "$WORKDIR/external.txt"
  if [[ $GUARD_RC -eq 2 && "$GUARD_OUT" == *"не похоже"* ]]; then
    ok '45 первое поле не имя ручки -> 2 со своим именем'
  else bad "45 ждали rc=2 «не похоже на ручку», получили rc=$GUARD_RC :: $GUARD_OUT"; fi
  rm -f "$WORKDIR/external.txt"
}

# 46. реестр из одних комментариев -> 2 (пустой реестр неотличим от забытого)
tooth_46() {
  RAN=$((RAN + 1))
  mk_image ''
  mk_settings '{"EXT_FILE_46":"k"}'
  mk_ext_file "$(printf '# только комментарий\n\n# и ещё один')"
  run_guard --label t46 --external-file "$WORKDIR/external.txt"
  if [[ $GUARD_RC -eq 2 && "$GUARD_OUT" == *"не дал ни одного имени"* ]]; then
    ok '46 реестр без единого имени -> 2 со своим именем'
  else bad "46 ждали rc=2 «не дал ни одного имени», получили rc=$GUARD_RC :: $GUARD_OUT"; fi
  rm -f "$WORKDIR/external.txt"
}

# 47. имя в реестре исчезло из настроек -> 7 ЛИШНЯЯ ДЕКЛАРАЦИЯ
#     CONSTRAINT: прочие корзины в этой фикстуре ПУСТЫ намеренно -- иначе
#     зуб мерил бы приоритет кодов, а не сам отказ 7.
tooth_47() {
  RAN=$((RAN + 1))
  mk_image 'let q=cfg.LIVE_47;'
  mk_settings '{"LIVE_47":"x"}'
  mk_ext_file "$(printf 'GONE_47\tоснование было, ручка из настроек ушла')"
  run_guard --label t47 --external-file "$WORKDIR/external.txt"
  if [[ $GUARD_RC -eq 7 && "$GUARD_OUT" == *"ЛИШНЯЯ ДЕКЛАРАЦИЯ"*"GONE_47"* \
        && "$GUARD_OUT" == *"ВЕРДИКТ ЛИШНЯЯ ДЕКЛАРАЦИЯ"* ]]; then
    ok '47 протухшая запись реестра -> 7, имя названо'
  else bad "47 ждали rc=7 ЛИШНЯЯ ДЕКЛАРАЦИЯ GONE_47, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
  rm -f "$WORKDIR/external.txt"
}

# 48. Go: os.Getenv("ИМЯ") -- читатель
tooth_48() {
  RAN=$((RAN + 1))
  mk_image ''
  printf 'package main\nimport "os"\nfunc f() string { return os.Getenv("GO_READ_48") }\n' > "$WORKDIR/ours/reader.go"
  mk_settings '{"GO_READ_48":"1"}'
  run_guard --label t48
  rm -f "$WORKDIR/ours/reader.go"
  if [[ $GUARD_RC -eq 0 && "$GUARD_OUT" == *"читает наш код 1"* ]]; then
    ok '48 Go os.Getenv -> читатель, 0'
  else bad "48 ждали rc=0 «читает наш код 1», получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 49. Go: имя в литерале []string{"ИМЯ"} -- НЕ читатель (зеркало зуба 34)
tooth_49() {
  RAN=$((RAN + 1))
  mk_image ''
  printf 'package main\nvar names = []string{"GO_LIST_49", "OTHER"}\n' > "$WORKDIR/ours/list.go"
  mk_settings '{"GO_LIST_49":"1"}'
  run_guard --label t49
  rm -f "$WORKDIR/ours/list.go"
  if [[ $GUARD_RC -eq 3 && "$GUARD_OUT" == *"УПОМЯНУТА-НО-НЕ-ЧИТАЕТСЯ"*"GO_LIST_49"* ]]; then
    ok '49 Go литерал перечня -> не читатель, 3'
  else bad "49 ждали rc=3 УПОМЯНУТА-НО-НЕ-ЧИТАЕТСЯ GO_LIST_49, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

tooth_1; tooth_2; tooth_3; tooth_4; tooth_5; tooth_6; tooth_7
tooth_8; tooth_9; tooth_10; tooth_11; tooth_12; tooth_13
tooth_14; tooth_15
tooth_16; tooth_17; tooth_18; tooth_19; tooth_20; tooth_21
tooth_22; tooth_23; tooth_24; tooth_25; tooth_26; tooth_27
tooth_28; tooth_29; tooth_30; tooth_31; tooth_32; tooth_33
tooth_34; tooth_35; tooth_36; tooth_37; tooth_38; tooth_39
tooth_40; tooth_41; tooth_42; tooth_43; tooth_44; tooth_45
tooth_46; tooth_47; tooth_48; tooth_49

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
