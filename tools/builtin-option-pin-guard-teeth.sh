#!/usr/bin/env bash
# Зубы гварда пинов опций встроенных модов (#303). Предмет -- синтетические
# фикстуры в mktemp, НИКОГДА не живой образ и не живые настройки: зуб,
# зависящий от боевого образа, мерил бы апстрим, а не проводку гварда.
#
# CONSTRAINT: ПИН ЧИСЛА зубов -- EXPECTED_TEETH; расхождение прогнанных с
# пином -- провал (rc=4), даже если каждый отдельный зуб зелёный.
# CONSTRAINT: GUARD -- сменный: мутационный прогон указывает копию прибора
# с подменённой веткой, и каждый зуб ОБЯЗАН краснеть на мутации своей ветки.
# CONSTRAINT: rm -rf только при непустом WORKDIR.
# CONSTRAINT: в фикстуре образа есть NUL-байт: без него зуб не отличил бы
# latin-1 от utf-8, а на боевом образе эта разница -- разница между замером
# и падением.
set -u

KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
GUARD="${GUARD:-$KIT/tools/builtin-option-pin-guard.sh}"
EXPECTED_TEETH=11

PASSED=0; FAILED=0; RAN=0; WORKDIR=''
# CONSTRAINT: конец объявляет себя САМ (__DONE=1). Голый EXIT-трап съедает
# обрыв с кодом 0 -- ошибка оболочки или ранний exit до итога выглядели бы
# зелёным прогоном (правило часового, claude-patch-all.sh:4327-4332;
# образец -- tools/gate-kill-teeth.sh).
__DONE=0

cleanup() {
  if [[ -n "${WORKDIR:-}" ]]; then rm -rf "${WORKDIR}"; fi
}

__option_pin_teeth_guard() {
  local __rc=$?
  trap - EXIT
  cleanup
  if [[ "${__DONE:-0}" != 1 && "$__rc" == 0 ]]; then
    echo "ОТКАЗ: builtin-option-pin-guard-teeth оборвался, не дойдя до конца (ошибка оболочки выше)" >&2
    exit 2
  fi
  exit "$__rc"
}
trap '__option_pin_teeth_guard' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/option-pin-teeth.XXXXXX") || {
  printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог\n' >&2; __DONE=1; exit 2; }
[ -n "$WORKDIR" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога пуст\n' >&2; __DONE=1; exit 2; }

ok()  { PASSED=$((PASSED + 1)); printf '  ok     %s\n' "$1"; }
bad() { FAILED=$((FAILED + 1)); printf '  ПРОВАЛ %s\n' "$1"; }

mk_image() {   # $1 -- добавочные литералы «образа» (js-подобный текст)
  python3 - "$WORKDIR/image.bin" "${1:-}" <<'PY'
import sys
p, extra = sys.argv[1], sys.argv[2]
open(p, 'w', encoding='latin-1').write('\x00' + extra)
PY
}

mk_settings() {   # $1 -- python-литерал pluginConfigs (dict) либо None
  python3 - "$WORKDIR/settings.json" "${1:-None}" <<'PY'
import json, sys
p, pc = sys.argv[1], sys.argv[2]
cfg = {}
if pc != 'None':
    cfg['pluginConfigs'] = {'agents-md@builtin': {'options': eval(pc)}}
json.dump(cfg, open(p, 'w', encoding='utf-8'), indent=2)
PY
}

write_tsv() {   # $1 -- файл; остальное -- строки таблицы
  local f="$1"; shift
  : > "$f"
  local line
  for line in "$@"; do printf '%s\n' "$line" >> "$f"; done
}

run_guard() {   # $1 -- образ, $2 -- настройки, $3 -- таблица
  GUARD_RC=0
  GUARD_OUT=$(CATALYST_LIVE_IMAGE="$1" CATALYST_SETTINGS_FILE="$2" \
              CATALYST_PINS_TSV="$3" bash "$GUARD") || GUARD_RC=$?
}

ROW_276=$'agents-md@builtin\tprojectInstructions\tboth\tформа 2.1.276; уfixture'
ROW_277=$'agents-md@builtin\tinstructionFiles\tclaude-md-and-agents-md\tформа 2.1.277; fixture'
IMG_276='var re={projectInstructions:{type:"string",title:"Project instructions"}};'
IMG_277='var re={instructionFiles:{type:"string",title:"Project instructions"}};'
VAL_276='var vals=["none","claude","agents-fallback","both"];'
VAL_277='var vals=["none","claude-md","claude-md-or-agents-md","claude-md-and-agents-md"];'

# 1. положительный контроль: обе формы здоровы -> 0 и ноль красных;
#    заодно границы: plugin_id с точкой и @, значение с дефисами, таблица с
#    комментариями и пустыми строками
tooth_1() {
  RAN=$((RAN + 1))
  mk_image "$IMG_276 $VAL_276 $IMG_277 $VAL_277"
  mk_settings "{'projectInstructions': 'both', 'instructionFiles': 'claude-md-and-agents-md'}"
  write_tsv "$WORKDIR/pins.tsv" \
    '# комментарий таблицы' '' "$ROW_276" '' '# ещё комментарий' "$ROW_277"
  run_guard "$WORKDIR/image.bin" "$WORKDIR/settings.json" "$WORKDIR/pins.tsv"
  if [[ $GUARD_RC -eq 0 && "$GUARD_OUT" == *"измерено=2 неизмерено=0 красных=0"* && "$GUARD_OUT" == *"ВЕРДИКТ ПИНЫ НА МЕСТЕ"* ]]; then
    ok '1 здоровый набор из двух форм -> 0, красных 0'
  else bad "1 ждали rc=0 и красных=0, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 2. ветка 1: образ нечитаем -> 2, своё имя отказа
tooth_2() {
  RAN=$((RAN + 1))
  mk_settings "{'projectInstructions': 'both'}"
  write_tsv "$WORKDIR/pins.tsv" "$ROW_276"
  run_guard "$WORKDIR/no-such-image.bin" "$WORKDIR/settings.json" "$WORKDIR/pins.tsv"
  if [[ $GUARD_RC -eq 2 && "$GUARD_OUT" == *"ПРИБОР НЕДОСТУПЕН: образ"* && "$GUARD_OUT" == *"нечитаем"* ]]; then
    ok '2 образа нет -> 2 ПРИБОР НЕДОСТУПЕН: образ'
  else bad "2 ждали rc=2 ПРИБОР НЕДОСТУПЕН: образ, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 3. ветка 2: опции в образе нет, вторая форма зелёная -> 0, НЕ ИЗМЕРЕНО
tooth_3() {
  RAN=$((RAN + 1))
  mk_image "$IMG_276 $VAL_276"
  mk_settings "{'projectInstructions': 'both', 'instructionFiles': 'claude-md-and-agents-md'}"
  write_tsv "$WORKDIR/pins.tsv" "$ROW_276" "$ROW_277"
  run_guard "$WORKDIR/image.bin" "$WORKDIR/settings.json" "$WORKDIR/pins.tsv"
  if [[ $GUARD_RC -eq 0 && "$GUARD_OUT" == *"НЕ ИЗМЕРЕНО: опции instructionFiles нет в образе"* \
     && "$GUARD_OUT" == *"измерено=1 неизмерено=1 красных=0"* ]]; then
    ok '3 опции нет в образе -> 0 НЕ ИЗМЕРЕНО, счётчики названы'
  else bad "3 ждали rc=0 НЕ ИЗМЕРЕНО и 1/1/0, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 4. ветка 3: опция есть, значение исчезло -> 1 ЗНАЧЕНИЕ ИСЧЕЗЛО
tooth_4() {
  RAN=$((RAN + 1))
  mk_image "$IMG_276"
  mk_settings "{'projectInstructions': 'both'}"
  write_tsv "$WORKDIR/pins.tsv" "$ROW_276"
  run_guard "$WORKDIR/image.bin" "$WORKDIR/settings.json" "$WORKDIR/pins.tsv"
  if [[ $GUARD_RC -eq 1 && "$GUARD_OUT" == *"ЗНАЧЕНИЕ ИСЧЕЗЛО: both нет в образе"* ]]; then
    ok '4 значение исчезло -> 1 ЗНАЧЕНИЕ ИСЧЕЗЛО'
  else bad "4 ждали rc=1 ЗНАЧЕНИЕ ИСЧЕЗЛО: both, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 5. ветка 4: опция и значение в образе, пина в настройках нет -> 1
tooth_5() {
  RAN=$((RAN + 1))
  mk_image "$IMG_276 $VAL_276"
  mk_settings "{'instructionFiles': 'claude-md-and-agents-md'}"
  write_tsv "$WORKDIR/pins.tsv" "$ROW_276"
  run_guard "$WORKDIR/image.bin" "$WORKDIR/settings.json" "$WORKDIR/pins.tsv"
  if [[ $GUARD_RC -eq 1 && "$GUARD_OUT" == *"ПИН ОТСУТСТВУЕТ"* \
     && "$GUARD_OUT" == *"pluginConfigs[agents-md@builtin].options[projectInstructions]"* ]]; then
    ok '5 пина нет в настройках -> 1 ПИН ОТСУТСТВУЕТ'
  else bad "5 ждали rc=1 ПИН ОТСУТСТВУЕТ, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 6. ветка 5: значение в настройках расходится с объявленным -> 1
tooth_6() {
  RAN=$((RAN + 1))
  mk_image "$IMG_276 $VAL_276"
  mk_settings "{'projectInstructions': 'claude'}"
  write_tsv "$WORKDIR/pins.tsv" "$ROW_276"
  run_guard "$WORKDIR/image.bin" "$WORKDIR/settings.json" "$WORKDIR/pins.tsv"
  if [[ $GUARD_RC -eq 1 && "$GUARD_OUT" == *"ПИН РАЗОШЁЛСЯ: настройки несут \"claude\", объявлено both"* ]]; then
    ok '6 пин разошёлся -> 1 ПИН РАЗОШЁЛСЯ с фактом'
  else bad "6 ждали rc=1 ПИН РАЗОШЁЛСЯ (claude против both), получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 7. пусто ≠ ноль: таблица без строк данных -> 2, а не зелень
tooth_7() {
  RAN=$((RAN + 1))
  mk_image "$IMG_276 $VAL_276 $IMG_277 $VAL_277"
  mk_settings "{'projectInstructions': 'both'}"
  write_tsv "$WORKDIR/pins.tsv" '# только комментарий' '' '# и пустая строка'
  run_guard "$WORKDIR/image.bin" "$WORKDIR/settings.json" "$WORKDIR/pins.tsv"
  if [[ $GUARD_RC -eq 2 && "$GUARD_OUT" == *"ПРИБОР НЕ ИЗМЕРИЛ НИЧЕГО"* ]]; then
    ok '7 пустая таблица -> 2 ПРИБОР НЕ ИЗМЕРИЛ НИЧЕГО'
  else bad "7 ждали rc=2 ПРИБОР НЕ ИЗМЕРИЛ НИЧЕГО, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 8. объявление протухло целиком: строки есть, ни одна не измерена -> 2
tooth_8() {
  RAN=$((RAN + 1))
  mk_image 'var unrelated=1;'
  mk_settings "{'projectInstructions': 'both', 'instructionFiles': 'claude-md-and-agents-md'}"
  write_tsv "$WORKDIR/pins.tsv" "$ROW_276" "$ROW_277"
  run_guard "$WORKDIR/image.bin" "$WORKDIR/settings.json" "$WORKDIR/pins.tsv"
  if [[ $GUARD_RC -eq 2 && "$GUARD_OUT" == *"ПРИБОР НЕ ИЗМЕРИЛ НИЧЕГО"* \
     && "$GUARD_OUT" == *"НЕ ИЗМЕРЕНО: опции projectInstructions"* ]]; then
    ok '8 ни одна форма не измерена -> 2, обе строки названы'
  else bad "8 ждали rc=2 ПРИБОР НЕ ИЗМЕРИЛ НИЧЕГО с двумя НЕ ИЗМЕРЕНО, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 9. контроль имени: два отказа с одним кодом печатают РАЗНЫЕ строки
tooth_9() {
  RAN=$((RAN + 1))
  mk_image "$IMG_276 $VAL_276"
  write_tsv "$WORKDIR/pins.tsv" "$ROW_276"
  mk_settings "{'instructionFiles': 'claude-md-and-agents-md'}"
  run_guard "$WORKDIR/image.bin" "$WORKDIR/settings.json" "$WORKDIR/pins.tsv"
  local rc_a=$GUARD_RC out_a=$GUARD_OUT
  mk_settings "{'projectInstructions': 'claude'}"
  run_guard "$WORKDIR/image.bin" "$WORKDIR/settings.json" "$WORKDIR/pins.tsv"
  if [[ $rc_a -eq 1 && $GUARD_RC -eq 1 && "$out_a" == *"ПИН ОТСУТСТВУЕТ"* \
     && "$GUARD_OUT" == *"ПИН РАЗОШЁЛСЯ"* && "$out_a" != "$GUARD_OUT" ]]; then
    ok '9 два отказа rc=1 печатают разные строки'
  else bad "9 ждали два различных rc=1, получили $rc_a/$GUARD_RC :: $out_a ||| $GUARD_OUT"; fi
}

# 10. проглоченная ошибка: битый json настроек -- отказ прибора с именем,
#     а НЕ «пина нет»
tooth_10() {
  RAN=$((RAN + 1))
  mk_image "$IMG_276 $VAL_276"
  printf '{ битый json\n' > "$WORKDIR/settings.json"
  write_tsv "$WORKDIR/pins.tsv" "$ROW_276"
  run_guard "$WORKDIR/image.bin" "$WORKDIR/settings.json" "$WORKDIR/pins.tsv"
  if [[ $GUARD_RC -eq 2 && "$GUARD_OUT" == *"ПРИБОР НЕДОСТУПЕН"* && "$GUARD_OUT" == *"json"* \
     && "$GUARD_OUT" != *"ПИН ОТСУТСТВУЕТ"* ]]; then
    ok '10 битый json настроек -> 2 с именем, не «пина нет»'
  else bad "10 ждали rc=2 ПРИБОР НЕДОСТУПЕН ... json без ПИН ОТСУТСТВУЕТ, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

# 11. настроек нет вовсе -> 2 со СВОИМ именем (не именем отказа образа)
tooth_11() {
  RAN=$((RAN + 1))
  mk_image "$IMG_276 $VAL_276"
  write_tsv "$WORKDIR/pins.tsv" "$ROW_276"
  run_guard "$WORKDIR/image.bin" "$WORKDIR/no-such-settings.json" "$WORKDIR/pins.tsv"
  if [[ $GUARD_RC -eq 2 && "$GUARD_OUT" == *"ПРИБОР НЕДОСТУПЕН: настройки"* \
     && "$GUARD_OUT" != *"образ"* ]]; then
    ok '11 настроек нет -> 2 своим именем'
  else bad "11 ждали rc=2 ПРИБОР НЕДОСТУПЕН: настройки, получили rc=$GUARD_RC :: $GUARD_OUT"; fi
}

tooth_1; tooth_2; tooth_3; tooth_4; tooth_5; tooth_6
tooth_7; tooth_8; tooth_9; tooth_10; tooth_11

printf '%s прошло, %s провалов, ожидалось %s\n' "$PASSED" "$FAILED" "$EXPECTED_TEETH"
if [[ $RAN -ne $EXPECTED_TEETH ]]; then
  printf 'TEETH_RC=4\n'
  printf 'builtin-option-pin-guard-teeth: ОТКАЗ -- прогнано %s, пин EXPECTED_TEETH=%s\n' "$RAN" "$EXPECTED_TEETH" >&2
  __DONE=1
  exit 4
fi
if [[ $FAILED -ne 0 ]]; then printf 'TEETH_RC=1\n'; __DONE=1; exit 1; fi
if [[ $PASSED -ne $EXPECTED_TEETH ]]; then
  printf 'TEETH_RC=4\n'
  printf 'builtin-option-pin-guard-teeth: ОТКАЗ -- прошло %s, пин EXPECTED_TEETH=%s\n' "$PASSED" "$EXPECTED_TEETH" >&2
  __DONE=1
  exit 4
fi
printf 'TEETH_RC=0\n'
__DONE=1
exit 0
