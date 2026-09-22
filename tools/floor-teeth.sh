#!/usr/bin/env bash
# Зубы третьего входа блока проверок (П8: дифференциал девяти строк политики
# против пристинного близнеца) и пола проверок.
#
# Коды выхода:
#   0 -- все зубы зелены и КАЖДАЯ мутация покрытого зуба его краснит
#   1 -- красный зуб либо мутация, зуб НЕ покрасневшая
#   2 -- прибор не может мерить; имя отказа печатается первым полем:
#        anchor-not-unique, expect-not-a-tooth, teeth-without-mutation,
#        no-workdir
#   3 -- ПРЕДМЕТА НЕТ НА ЭТОЙ МАШИНЕ: дома пристина не существует
#        (имя печатается первым полем: no-pristine-image)
# КОНСТРЕЙНТ: код 1 закреплён за КРАСНЫМ ЗУБОМ, код 2 -- за отказом прибора.
# Склейка кодов уничтожает различие «дефект предмета / дефект прибора».
# КОНСТРЕЙНТ: код 3 отделён от кода 2 по ВЛАДЕЛЬЦУ причины. Дом пристина
# `~/.tweakcc/native-binary.backup` есть не на каждой площадке (#323), и его
# отсутствие -- свойство МАШИНЫ, а не поломка прибора и не красный зуб.
# Слитый с кодом 2, он останавливал бы сборку там, где мерить попросту нечего;
# слитый с кодом 0 -- выдавал бы неизмеренное за измеренное.
#
# Мутации правят ТЕКСТ КОПИИ кита во временном каталоге; дерево не трогается.
# Мутация зуба, красного в базовой фазе, не ставится: краснить нечего, и
# «ПРОВАЛ» такой мутации ничего не измерил бы.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# Пристинный образ -- вход прибора, а не его свойство: ручка названа, значение
# по умолчанию -- дом пристина последней тронутой версии.
PRISTINE="${FLOOR_TEETH_PRISTINE:-$HOME/.tweakcc/native-binary.backup}"

refuse() { printf 'FLOOR-TEETH ОТКАЗ (%s): %s\n' "$1" "$2" >&2; __DONE=1; exit 2; }
# КОНСТРЕЙНТ: своё ИМЯ и свой код -- «не измеряли, потому что нечего», а не
# «мерили и не смогли». Два исхода с одним кодом неразличимы вызывающему.
absent() { printf 'FLOOR-TEETH НЕ ИЗМЕРЕНО (%s): %s\n' "$1" "$2" >&2; __DONE=1; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/floor-teeth.XXXXXX")" \
  || refuse no-workdir "временный каталог не создан"
# CONSTRAINT: штатный конец объявляет себя сам (__DONE=1); голый EXIT-трап
# съедает обрыв с кодом 0 (правило часового, claude-patch-all.sh).
__DONE=0
__floor_teeth_guard() {
  local __rc=$?
  trap - EXIT
  rm -rf "$WORK"
  if [[ "${__DONE:-0}" != 1 && "${__rc}" == 0 ]]; then
    echo "ОТКАЗ: floor-teeth оборвался, не дойдя до конца (ошибка оболочки выше)" >&2
    exit 2
  fi
  exit "${__rc}"
}
trap '__floor_teeth_guard' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ -f "$PRISTINE" ]] \
  || absent no-pristine-image "нет пристинного образа: $PRISTINE (ручка FLOOR_TEETH_PRISTINE)"

# --- перечень зубов -----------------------------------------------------------
# Поля: <id>@@<что утверждает зуб>
TEETH=(
  "T1@@блок без argv[3] называет ВСЕ прочие проверки, а не ноль"
  "T2@@отказ П8 несёт её имя, её запись реестра красна, код блока НЕнулевой"
  "T3@@floor на пристине: rc=0 и П8 среди объявленных"
  "T4@@несопоставимый близнец даёт имя отказа, ОТЛИЧНОЕ от «входа нет»"
  "T5@@сопоставимый близнец: П8 ИЗМЕРЕНА (зелена), а не отказана"
)

# --- перечень мутаций ---------------------------------------------------------
# Поля: <id зуба>@@<файл кита>@@<якорь>@@<замена>. Якорь обязан встречаться в
# файле РОВНО один раз, иначе отказ anchor-not-unique. Последовательность \n в
# якоре и замене разворачивается в перевод строки.
MUTS=(
  "T1@@claude-patch-all.sh@@    _PRISTINE_REFUSAL = 'no pristine twin input (argv[3])'@@    sys.exit(2)"
  "T2@@claude-patch-all.sh@@  [REFUSED] policy-vs-pristine differential: @@  [REFUSED] безымянный отказ: "
  "T2@@claude-patch-all.sh@@{_PRISTINE_REFUSAL}')\n        return False@@{_PRISTINE_REFUSAL}')\n        return True"
  "T3@@tools/checks-on-image.sh@@    'the nine policy strings count equal in the image and in the pristine twin':@@    'zzz эта запись не имя проверки':"
  "T4@@tools/checks-on-image.sh@@    __twin_arg=\"\$__TWIN_SENTINEL\$TWIN_STATE\"@@    __twin_arg=\"\""
  "T5@@tools/checks-on-image.sh@@    __twin_arg=\"\$IMG.orig\"@@    __twin_arg=\"\""
)

# CONSTRAINT: имя записи П8 в реестре проверок -- пин на ключ словаря `checks`
# блока. Переименование ключа краснит зубы T2/T5, а не зеленит их молча.
P8_NAME='the nine policy strings count equal in the image and in the pristine twin'
P8_REFUSAL_TAG='[REFUSED] policy-vs-pristine differential:'

field() {   # <запись> <номер поля с 1> -> поле, разделитель @@
  local rec="$1" n="$2" i=1
  while [[ $i -lt $n ]]; do rec="${rec#*@@}"; i=$((i + 1)); done
  printf '%s' "${rec%%@@*}"
}

# --- снимок кита и мутация ----------------------------------------------------
mk_kit() {   # <каталог назначения>
  local dst="$1" f
  mkdir -p "$dst/tools" || return 1
  cp "$ROOT/claude-patch-all.sh" "$dst/claude-patch-all.sh" || return 1
  cp "$ROOT/tweakcc-patch.js" "$dst/tweakcc-patch.js" || return 1
  cp "$ROOT/tools/checks-on-image.sh" "$dst/tools/checks-on-image.sh" || return 1
  # Дома реестров ОБЯЗАНЫ ехать в снимок: без них блок отказывает прибором,
  # а не мерит (тот же класс, что у checks-teeth.py).
  for f in step-checks.py our-step-checks.txt our-patch-inapplicable.txt \
           our-steps-off.txt our-carrier-absent.txt; do
    if [[ -f "$ROOT/tools/$f" ]]; then
      cp "$ROOT/tools/$f" "$dst/tools/$f" || return 1
    fi
  done
  return 0
}

apply_mutation() {   # <кит> <файл> <якорь> <замена>
  python3 - "$1/$2" "$3" "$4" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
old = old.replace('\\n', '\n')
new = new.replace('\\n', '\n')
text = open(path, encoding='utf-8').read()
n = text.count(old)
if n != 1:
    sys.stderr.write('якорь встречается %d раз, ждали 1: %r\n' % (n, old[:80]))
    sys.exit(3)
open(path, 'w', encoding='utf-8').write(text.replace(old, new, 1))
PY
}

extract_block() {   # <кит> <файл назначения>
  python3 - "$1/claude-patch-all.sh" "$2" <<'PY'
import sys
src, out = sys.argv[1], sys.argv[2]
lines = open(src, encoding='utf-8').read().split('\n')
# Тот же якорь, которым снимает блок tools/checks-on-image.sh: копия предиката
# разошлась бы молча, поэтому его форма здесь повторена ДОСЛОВНО и требование
# к ней строже -- РОВНО одно вхождение.
marker = 'python3 - "$BIN" "$OUR_PATCH" <<'
hits = [i for i, l in enumerate(lines) if l.startswith(marker)]
if len(hits) != 1:
    sys.stderr.write('якорь блока проверок встречается %d раз, ждали 1\n' % len(hits))
    sys.exit(3)
start = hits[0]
end = next((i for i in range(start + 1, len(lines)) if lines[i] == 'PY'), -1)
if end < 0:
    sys.stderr.write('блок проверок не закрыт\n')
    sys.exit(3)
open(out, 'w', encoding='utf-8').write('\n'.join(lines[start + 1:end]))
PY
}

# --- прогоны (кешируются на кит: один и тот же прогон читают разные зубы) ------
run_block2() {   # <кит> <метка> -> путь к выводу; код прогона в <вывод>.rc
  local kit="$1" label="$2" out="$WORK/block2.$2.out" blk="$WORK/block.$2.py"
  if [[ ! -f "$out" ]]; then
    extract_block "$kit" "$blk" \
      || refuse anchor-not-unique "блок проверок не снят с кита $kit"
    python3 "$blk" "$PRISTINE" "$kit/tweakcc-patch.js" > "$out" 2>&1
    printf '%s' "$?" > "$out.rc"
  fi
  printf '%s' "$out"
}

run_floor() {   # <кит> <метка> -> путь к выводу
  local kit="$1" out="$WORK/floor.$2.out"
  if [[ ! -f "$out" ]]; then
    bash "$kit/tools/checks-on-image.sh" --floor "$PRISTINE" "$kit/tweakcc-patch.js" \
      > "$out" 2>&1
    printf '%s' "$?" > "$out.rc"
  fi
  printf '%s' "$out"
}

# Близнец собирается СИМЛИНКАМИ на один и тот же пристинный образ: сопоставимый
# близнец -- тот же образ (версии равны по построению), несопоставимый -- файл,
# который на `--version` не назовётся.
run_nonfloor() {   # <кит> <метка> <comparable|incomparable> -> путь к выводу
  local kit="$1" label="$2" kind="$3" out="$WORK/nonfloor.$2.$3.out"
  local d="$WORK/img.$2.$3"
  if [[ ! -f "$out" ]]; then
    mkdir -p "$d"
    ln -sf "$PRISTINE" "$d/img"
    if [[ "$kind" == comparable ]]; then
      ln -sf "$PRISTINE" "$d/img.orig"
    else
      printf 'не образ: этот файл на --version не назовётся\n' > "$d/img.orig"
      chmod 0644 "$d/img.orig"
    fi
    bash "$kit/tools/checks-on-image.sh" "$d/img" "$kit/tweakcc-patch.js" > "$out" 2>&1
    printf '%s' "$?" > "$out.rc"
  fi
  printf '%s' "$out"
}

rc_of() { cat "$1.rc"; }

refusal_name() {   # <файл вывода> -> текст отказа П8 после метки, либо ПУСТО
  python3 - "$1" "$P8_REFUSAL_TAG" <<'PY'
import sys
tag = sys.argv[2]
for line in open(sys.argv[1], encoding='utf-8', errors='replace'):
    line = line.strip()
    if line.startswith(tag):
        sys.stdout.write(line[len(tag):].strip())
        break
PY
}

count_named() {   # <файл вывода> -> число названных проверок ([OK]/[FAIL])
  python3 - "$1" <<'PY'
import sys
n = 0
for line in open(sys.argv[1], encoding='utf-8', errors='replace'):
    s = line.strip()
    if s.startswith('[OK] ') or s.startswith('[FAIL] '):
        n += 1
sys.stdout.write(str(n))
PY
}

verdict_of() {   # <файл вывода> <имя проверки> -> OK | FAIL | ПУСТО
  python3 - "$1" "$2" <<'PY'
import sys
name = sys.argv[2]
for line in open(sys.argv[1], encoding='utf-8', errors='replace'):
    s = line.strip()
    for tag in ('OK', 'FAIL'):
        if s == '[%s] %s' % (tag, name):
            sys.stdout.write(tag)
            sys.exit(0)
PY
}

# --- зубы ---------------------------------------------------------------------
WHY=""
# CONSTRAINT: код подстановки раннера/парсера не есть вердикт зуба -- вердикт
# читается из ТЕКСТА вывода (rc_of "$out", refusal_name, verdict_of), поэтому
# код каждой подстановки ниже гасится явно `|| true`, а не проверяется.

tooth_T1() {   # <кит> <метка>
  local out named
  out="$(run_block2 "$1" "$2")" || true
  named="$(count_named "$out")" || true
  if [[ "${named:-0}" -gt 0 ]]; then return 0; fi
  WHY="блок назвал проверок: ${named:-?} (ждали больше нуля); rc=$(rc_of "$out")"
  return 1
}

tooth_T2() {   # <кит> <метка>
  local out name verdict rc
  out="$(run_block2 "$1" "$2")" || true
  name="$(refusal_name "$out")" || true
  verdict="$(verdict_of "$out" "$P8_NAME")" || true
  rc="$(rc_of "$out")" || true
  if [[ -n "$name" && "$verdict" == FAIL && "$rc" != 0 ]]; then return 0; fi
  WHY="имя отказа: «${name:-НЕТ}»; вердикт записи П8: «${verdict:-НЕТ}»; rc=$rc"
  return 1
}

tooth_T3() {   # <кит> <метка>
  local out rc declared
  out="$(run_floor "$1" "$2")" || true
  rc="$(rc_of "$out")" || true
  declared=0
  if grep -q -F "    '$P8_NAME':" "$1/tools/checks-on-image.sh"; then declared=1; fi
  if [[ "$rc" == 0 && "$declared" == 1 ]]; then return 0; fi
  # КОНСТРЕЙНТ: доклад называет ИМЕНА находок пола, а не хвост его вывода.
  # Хвост -- пояснительная строка под находкой, одна на все три класса
  # расхождения, и она не называет предмет: разбор уходит к записи, которую
  # зуб проверяет своим вторым условием, вместо той, что реально красна.
  local found
  # КОНСТРЕЙНТ: код подстановки захвачен (`|| true`) -- у grep код 1 на нуле
  # совпадений законен (находок нет), а под `set -euo pipefail` он оборвал бы
  # сам доклад зуба на месте его составления.
  found="$(grep -F -e 'а не объявлена: ' -e 'но красна: ' -e 'но зелена на стоке: ' "$out" | sed 's/^ *//' | tr '\n' '|')" || true
  [[ -n "$found" ]] || found="находок пола не названо; последняя строка: $(tail -1 "$out")"
  WHY="floor rc=$rc; П8 объявлена в DECLARED: $declared; находки пола: $found"
  return 1
}

tooth_T4() {   # <кит> <метка>
  local out_nc out_noarg name_nc name_noarg
  out_nc="$(run_nonfloor "$1" "$2" incomparable)" || true
  out_noarg="$(run_block2 "$1" "$2")" || true
  name_nc="$(refusal_name "$out_nc")" || true
  name_noarg="$(refusal_name "$out_noarg")" || true
  if [[ -n "$name_nc" && -n "$name_noarg" && "$name_nc" != "$name_noarg" ]] \
     && case "$name_nc" in *"twin not usable:"*) true ;; *) false ;; esac; then
    return 0
  fi
  WHY="имя при несопоставимом близнеце: «${name_nc:-НЕТ}»; имя при отсутствии входа: «${name_noarg:-НЕТ}»"
  return 1
}

tooth_T5() {   # <кит> <метка>
  local out name verdict
  out="$(run_nonfloor "$1" "$2" comparable)" || true
  name="$(refusal_name "$out")" || true
  verdict="$(verdict_of "$out" "$P8_NAME")" || true
  if [[ -z "$name" && "$verdict" == OK ]]; then return 0; fi
  WHY="отказ П8: «${name:-нет, и это правильно}»; вердикт записи П8: «${verdict:-НЕТ}»"
  return 1
}

run_tooth() {   # <id> <кит> <метка>
  WHY=""
  case "$1" in
    T1) tooth_T1 "$2" "$3" ;;
    T2) tooth_T2 "$2" "$3" ;;
    T3) tooth_T3 "$2" "$3" ;;
    T4) tooth_T4 "$2" "$3" ;;
    T5) tooth_T5 "$2" "$3" ;;
    *)  refuse expect-not-a-tooth "мутация ссылается на несуществующий зуб: $1" ;;
  esac
}

# --- гейт объявлений: каждый зуб существует и покрыт мутацией ------------------
# CONSTRAINT: field -- парсер записи массива, его код возврата не несёт вердикта
# (несуществующий зуб ловит refuse ниже); подстановка вычисляется ДО [[ ]],
# чтобы код не отбрасывался условным контекстом, и гасится явно.
for m in "${MUTS[@]}"; do
  mt="$(field "$m" 1)" || true
  known=0
  for t in "${TEETH[@]}"; do
    t_id="$(field "$t" 1)" || true
    [[ "$t_id" == "$mt" ]] && known=1
  done
  [[ $known == 1 ]] || refuse expect-not-a-tooth "мутация ссылается на несуществующий зуб: $mt"
done
for t in "${TEETH[@]}"; do
  tid="$(field "$t" 1)" || true
  covered=0
  for m in "${MUTS[@]}"; do
    m_id="$(field "$m" 1)" || true
    [[ "$m_id" == "$tid" ]] && covered=1
  done
  [[ $covered == 1 ]] \
    || refuse teeth-without-mutation "зуб без покрывающей мутации: $tid"
done

# --- фаза 1: базовая ----------------------------------------------------------
# CONSTRAINT: field -- парсер записи, его код возврата не вердикт (вердикт фазы
# даёт run_tooth ниже), поэтому код подстановки гасится явно.
RESULTS=()
GREEN_TEETH=""
echo "== базовая фаза: кит дерева, пристинный образ $PRISTINE"
mk_kit "$WORK/base" || refuse no-workdir "снимок кита не собран"
for t in "${TEETH[@]}"; do
  tid="$(field "$t" 1)" || true
  what="$(field "$t" 2)" || true
  if run_tooth "$tid" "$WORK/base" base; then
    RESULTS+=("$tid:pass")
    GREEN_TEETH="$GREEN_TEETH $tid"
    printf '  [ЗУБ OK] %s: %s\n' "$tid" "$what"
  else
    RESULTS+=("$tid:fail")
    printf '  [ЗУБ КРАСЕН] %s: %s\n' "$tid" "$what"
    printf '    -- %s\n' "$WHY"
  fi
done

# --- фаза 2: мутационная ------------------------------------------------------
# CONSTRAINT: field -- парсер записи мутации, его код возврата не вердикт
# (вердикт даёт run_tooth ниже), поэтому код подстановки гасится явно.
echo "== мутационная фаза: каждая мутация обязана покрасить свой зуб"
mi=0
for m in "${MUTS[@]}"; do
  mi=$((mi + 1))
  mt="$(field "$m" 1)" || true
  mfile="$(field "$m" 2)" || true
  mold="$(field "$m" 3)" || true
  mnew="$(field "$m" 4)" || true
  case " $GREEN_TEETH " in
    *" $mt "*) ;;
    *) printf '  [МУТАЦИЯ ПРОПУЩЕНА] %s #%d: зуб красен в базовой фазе -- краснить нечего\n' "$mt" "$mi"
       continue ;;
  esac
  kit="$WORK/mut$mi"
  mk_kit "$kit" || refuse no-workdir "снимок кита не собран: $kit"
  apply_mutation "$kit" "$mfile" "$mold" "$mnew" \
    || refuse anchor-not-unique "мутация #$mi ($mt, $mfile): якорь не уникален"
  if run_tooth "$mt" "$kit" "mut$mi"; then
    RESULTS+=("M$mi:fail")
    printf '  [МУТАЦИЯ НЕ КРАСИТ] %s #%d (%s): зуб остался зелёным -- он ничего не стережёт\n' \
      "$mt" "$mi" "$mfile"
  else
    RESULTS+=("M$mi:pass")
    printf '  [ПРОВАЛ %s] мутация #%d (%s) -- зуб СРАБОТАЛ: %s\n' "$mt" "$mi" "$mfile" "$WHY"
  fi
done

# --- итог ---------------------------------------------------------------------
pass=0
failed=0
for r in "${RESULTS[@]}"; do
  case "$r" in
    *:pass) pass=$((pass + 1)) ;;
    *) failed=$((failed + 1)) ;;
  esac
done
printf 'FLOOR-TEETH PASS=%d FAILED=%d\n' "$pass" "$failed"
__DONE=1
[[ $failed -eq 0 ]] || exit 1
exit 0
