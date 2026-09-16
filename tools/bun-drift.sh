#!/usr/bin/env bash
# Прибор расхождения рантайма bun: каким bun пойдут сценарии стенда, и на каком
# bun собран извлечённый образ. Расхождение — объявленное состояние, не отказ
# сборки. Отказ прибора (не смог измерить) — другой код.
#
#   bash tools/bun-drift.sh --tree TREE
#   bash tools/bun-drift.sh --self-check
#
# Коды (подмножество таблицы кита — шапка claude-patch-all.sh):
#   0  измерено, версии совпадают
#   1  измерено, версии расходятся. Это не код 2: вызывающий по умолчанию
#      ПЕЧАТАЕТ вердикт и не валит прогон. Стенд, который хочет остановиться
#      на расхождении, ветвится по 1 явно.
#   2  прибор не может мерить: нет bun, нет/нечитаема мета дерева, --version
#      отказал или дал пустую строку (пусто не ноль)
#   4  --self-check: объявленное число зубов не сходится с фактическим
#
# Версию спрашивает у ИСПОЛНЯЕМОГО бинаря (which -a + --version каждой копии),
# не у менеджера пакетов: brew объявлял 1.4.2 при исполняемом 1.3.14 (симлинк
# мимо Cellar). Образ — поле stub в .tree-meta извлечённого дерева; без дерева
# прибор отказывает, а не пропускает замер.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Единственный дом перечня зубов — этот массив: циклы self-check идут ТОЛЬКО
# по нему, литерального перечня нет. EXPECTED_TEETH — отдельная запись-контракт;
# сторож (GUARD_TEETH_LIST) сверяет её с фактической длиной перечня и числом
# прогнанных зубов, рассинхрон = rc=4 с причиной словами.
TEETH_LIST=(1 2 3 4 5 6 7 8)
EXPECTED_TEETH=8
COMPARE_EQUAL_IS_MATCH=1  # MUT_COMPARE
PRINT_BOTH_VERSIONS=1  # MUT_VERDICT_BOTH
FAIL_CLOSED_MISSING=1  # MUT_FAIL_CLOSED
LIST_ALL_COPIES=1  # MUT_ALL_COPIES
GUARD_TEETH_LIST=1  # MUT_GUARD_LIST
META_MUST_BE_READABLE=1  # MUT_META_READABLE
REFUSE_STUB_EMPTY=1  # MUT_STUB_EMPTY
REFUSE_VER_EMPTY=1  # MUT_VER_EMPTY

die2() { printf '%s\n' "$*" >&2; exit 2; }

usage() {
  cat <<EOF
usage: bash tools/bun-drift.sh --tree TREE
       bash tools/bun-drift.sh --self-check

  --tree TREE   извлечённое дерево (каталог с .tree-meta, ключ stub)
  --self-check  зубы по перечню TEETH_LIST; мутации правят копию, снимок+sha256, не git

коды: 0 совпадают / 1 расходятся (объявлено) / 2 прибор не может мерить /
      4 self-check: сторож перечня зубов (объявлено N, факт M)
EOF
}

refuse_missing() {
  local msg="$1"
  if [[ "$FAIL_CLOSED_MISSING" -eq 1 ]]; then
    printf '%s\n' "$msg" >&2
    exit 2
  fi
  printf 'ВЕРДИКТ: совпадают\n'
  exit 0
}

trim() {
  local s="$1"
  s="${s%$'\r'}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

normalize_ver() {
  local v
  v=$(trim "$1")
  case "$v" in
    bun-v*) v="${v#bun-v}" ;;
    bun-*) v="${v#bun-}" ;;
    v[0-9]*) v="${v#v}" ;;
  esac
  printf '%s' "$v"
}

resolve_path() {
  local path="$1" real
  if command -v realpath >/dev/null; then
    real=$(realpath "$path") || real="$path"
  else
    real="$path"
  fi
  printf '%s' "$real"
}

read_stub() {
  local meta="$1" line key val found="" saw=0
  if [[ ! -f "$meta" ]]; then
    refuse_missing "ПРИБОР: нет метаданных дерева ($meta) — извлеките образ (tools/tree-extract.py extract) и передайте --tree"
  fi
  if [[ "$META_MUST_BE_READABLE" -eq 1 && ! -r "$meta" ]]; then
    refuse_missing "ПРИБОР: мета дерева не читается ($meta)"
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    case "$line" in
      *=*) ;;
      *) die2 "ПРИБОР: кривая строка мета: $line" ;;
    esac
    key="${line%%=*}"
    val="${line#*=}"
    if [[ "$key" == stub ]]; then
      found="$val"
      saw=1
    fi
  done < "$meta"
  if [[ "$saw" -eq 0 ]]; then
    refuse_missing "ПРИБОР: в мета нет ключа stub ($meta)"
  fi
  found=$(trim "$found")
  if [[ "$REFUSE_STUB_EMPTY" -eq 1 && -z "$found" ]]; then
    refuse_missing "ПРИБОР: ключ stub в мета пуст ($meta) — пусто не ноль"
  fi
  STUB_RAW="$found"
}

measure_one() {
  local path="$1" out rc
  MEASURE_VER=
  if [[ ! -e "$path" ]]; then
    return 2
  fi
  if [[ ! -x "$path" ]]; then
    return 3
  fi
  out=$("$path" --version)
  rc=$?
  if [[ $rc -ne 0 ]]; then
    MEASURE_RC=$rc
    return 4
  fi
  out="${out%%$'\n'*}"
  out=$(trim "$out")
  if [[ "$REFUSE_VER_EMPTY" -eq 1 && -z "$out" ]]; then
    return 5
  fi
  MEASURE_VER="$out"
  return 0
}

path_seen() {
  local p="$1" x
  if [[ ${#COPY_PATHS[@]} -eq 0 ]]; then
    return 1
  fi
  for x in "${COPY_PATHS[@]}"; do
    [[ "$x" == "$p" ]] && return 0
  done
  return 1
}

ver_seen() {
  local v="$1" x
  if [[ ${#UNIQ_VERS[@]} -eq 0 ]]; then
    return 1
  fi
  for x in "${UNIQ_VERS[@]}"; do
    [[ "$x" == "$v" ]] && return 0
  done
  return 1
}

collect_which() {
  local which_bin list dir cand saveifs
  WHICH_LIST=
  which_bin=$(command -v which) || die2 "ПРИБОР: нет which — копии bun перечислить нечем"
  if [[ "$LIST_ALL_COPIES" -eq 1 ]]; then
    # Brief: which -a bun. Walk PATH too — same search; darwin /usr/bin/which
    # is a csh script and may not honor the PATH given to this process.
    list=$("$which_bin" -a bun) || true
    saveifs=$IFS
    set -f
    IFS=:
    for dir in $PATH; do
      [[ -z "$dir" ]] && dir=.
      cand="$dir/bun"
      if [[ -x "$cand" ]]; then
        if [[ -n "$list" ]]; then
          list="$list"$'\n'"$cand"
        else
          list="$cand"
        fi
      fi
    done
    IFS=$saveifs
    set +f
  else
    list=$(command -v bun) || true
  fi
  WHICH_LIST="$list"
}

measure() {
  local tree="$1"
  local meta stub_n exec_path exec_ver exec_n
  local line path real rc nver others n
  STUB_RAW=
  COPY_PATHS=()
  COPY_VERS=()
  UNIQ_VERS=()
  MEASURE_VER=
  MEASURE_RC=0

  [[ -n "$tree" ]] || refuse_missing "ПРИБОР: нужен --tree (извлечённое дерево с .tree-meta) — без него bun образа мерить нечем"
  [[ -d "$tree" ]] || refuse_missing "ПРИБОР: нет дерева: $tree"
  meta="$tree/.tree-meta"
  read_stub "$meta"
  stub_n=$(normalize_ver "$STUB_RAW")
  if [[ "$REFUSE_STUB_EMPTY" -eq 1 && -z "$stub_n" ]]; then
    refuse_missing "ПРИБОР: stub не нормализуется: $STUB_RAW"
  fi

  printf 'ОБРАЗ stub=%s version=%s tree=%s\n' "$STUB_RAW" "$stub_n" "$tree"

  collect_which
  if [[ -z "$(trim "${WHICH_LIST:-}")" ]]; then
    refuse_missing "ПРИБОР: bun не найден (which -a bun пуст) — пусто не ноль, «совпадают» этим не объявить"
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line=$(trim "$line")
    [[ -z "$line" ]] && continue
    path="$line"
    path_seen "$path" && continue
    COPY_PATHS+=("$path")
    real=$(resolve_path "$path")
    measure_one "$path"
    rc=$?
    if [[ $rc -ne 0 ]]; then
      printf 'КОПИЯ path=%s real=%s version=НЕ ИЗМЕРЕНО rc=%s\n' "$path" "$real" "$rc"
      COPY_VERS+=("")
      continue
    fi
    nver=$(normalize_ver "$MEASURE_VER")
    printf 'КОПИЯ path=%s real=%s version=%s\n' "$path" "$real" "$nver"
    COPY_VERS+=("$nver")
    if [[ -n "$nver" ]] && ! ver_seen "$nver"; then
      UNIQ_VERS+=("$nver")
    fi
  done <<< "$WHICH_LIST"

  if [[ ${#COPY_PATHS[@]} -eq 0 ]]; then
    refuse_missing "ПРИБОР: bun не найден (which -a bun пуст) — пусто не ноль, «совпадают» этим не объявить"
  fi

  exec_path=$(command -v bun) || exec_path=""
  exec_path=$(trim "$exec_path")
  [[ -n "$exec_path" ]] || die2 "ПРИБОР: command -v bun пуст при непустом which -a — исполняемый bun не назван"

  exec_ver=""
  exec_n=""
  n=0
  while [[ $n -lt ${#COPY_PATHS[@]} ]]; do
    if [[ "${COPY_PATHS[$n]}" == "$exec_path" ]]; then
      exec_ver="${COPY_VERS[$n]}"
      break
    fi
    n=$((n + 1))
  done
  if [[ -z "$exec_ver" ]]; then
    measure_one "$exec_path"
    rc=$?
    if [[ $rc -ne 0 || ( "$REFUSE_VER_EMPTY" -eq 1 && -z "$MEASURE_VER" ) ]]; then
      die2 "ПРИБОР: исполняемый bun не дал --version: $exec_path"
    fi
    exec_ver=$(normalize_ver "$MEASURE_VER")
    real=$(resolve_path "$exec_path")
    printf 'КОПИЯ path=%s real=%s version=%s\n' "$exec_path" "$real" "$exec_ver"
  fi
  exec_n="$exec_ver"
  if [[ "$REFUSE_VER_EMPTY" -eq 1 && -z "$exec_n" ]]; then
    die2 "ПРИБОР: исполняемый bun дал пустую версию: $exec_path — пусто не ноль"
  fi

  real=$(resolve_path "$exec_path")
  printf 'ИСПОЛНЯЕМЫЙ path=%s real=%s version=%s\n' "$exec_path" "$real" "$exec_n"

  if [[ ${#UNIQ_VERS[@]} -gt 1 ]]; then
    others=""
    n=0
    while [[ $n -lt ${#UNIQ_VERS[@]} ]]; do
      if [[ "${UNIQ_VERS[$n]}" != "$exec_n" ]]; then
        if [[ -n "$others" ]]; then
          others="$others,${UNIQ_VERS[$n]}"
        else
          others="${UNIQ_VERS[$n]}"
        fi
      fi
      n=$((n + 1))
    done
    printf 'НАХОДКА: копии bun расходятся исполняемый=%s другие=%s\n' "$exec_n" "$others"
  fi

  if [[ "$COMPARE_EQUAL_IS_MATCH" -eq 1 && "$exec_n" == "$stub_n" ]]; then
    printf 'ВЕРДИКТ: совпадают стенд=%s образ=%s\n' "$exec_n" "$stub_n"
    exit 0
  fi
  if [[ "$PRINT_BOTH_VERSIONS" -eq 1 ]]; then
    printf 'ВЕРДИКТ: расходятся стенд=%s образ=%s\n' "$exec_n" "$stub_n"
  else
    printf 'ВЕРДИКТ: расходятся стенд=%s\n' "$exec_n"
  fi
  exit 1
}

# ---------------------------------------------------------------------------
# --self-check: четыре зуба, у каждого свой названный красный.
# Мутации правят КОПИЮ; оригинал не трогается. Снимок + sha256, не git.
# ---------------------------------------------------------------------------

sha256_of() {
  python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
}

say() { printf '%s\n' "$*"; }

write_fake_bun() {
  local dest="$1" ver="$2"
  mkdir -p "$(dirname "$dest")"
  cat > "$dest" <<EOF
#!/bin/sh
echo '$ver'
EOF
  chmod +x "$dest"
}

write_meta() {
  local dest="$1" stub="$2"
  mkdir -p "$(dirname "$dest")"
  printf 'stub=%s\n' "$stub" > "$dest"
}

BASEPATH="/usr/bin:/bin:/usr/sbin:/sbin"

run_measure() {
  local path="$1" tree="$2" out="$3" err="$4"
  env PATH="$path" bash "$TOOL" --tree "$tree" >"$out" 2>"$err"
  return $?
}

tooth_fail() {
  TOOTH_RC=1
  say "ЗУБ $TOOTH_N $TOOTH_NAME: КРАСНЫЙ -- $*"
}

tooth_pass() {
  say "ЗУБ $TOOTH_N $TOOTH_NAME: ЗЕЛЁНЫЙ"
}

# ЗУБ 1: совпадающие версии → вердикт «совпадают», код 0.
# Красный: сломать сравнение (равные едут в «расходятся»).
tooth_1() {
  TOOTH_N=1 TOOTH_NAME='совпадают' TOOTH_RC=0
  local fx tree out err rc path
  fx=$(mktemp -d "$WORK/fx1.XXXXXX")
  tree="$fx/tree"
  write_fake_bun "$fx/bin/bun" "1.4.2"
  write_meta "$tree/.tree-meta" "bun-v1.4.2"
  path="$fx/bin:$BASEPATH"
  out=$WORK/t1.out; err=$WORK/t1.err
  run_measure "$path" "$tree" "$out" "$err"
  rc=$?
  if grep -q -F 'ВЕРДИКТ: совпадают стенд=1.4.2 образ=1.4.2' "$out" && [[ $rc -eq 0 ]]; then
    if grep -q -F 'ВЕРДИКТ: расходятся' "$out"; then
      tooth_fail "совпадение и расхождение в одном выводе rc=$rc stdout=$(cat "$out")"
      return 0
    fi
    tooth_pass
    return 0
  fi
  tooth_fail "ждали совпадают rc=0, получили rc=$rc stdout=$(cat "$out") stderr=$(cat "$err")"
}

# ЗУБ 2: разные версии → «расходятся» с ОБЕИМИ версиями в строке, код 1.
# Красный: печатать одну.
tooth_2() {
  TOOTH_N=2 TOOTH_NAME='расходятся' TOOTH_RC=0
  local fx tree out err rc path verdict
  fx=$(mktemp -d "$WORK/fx2.XXXXXX")
  tree="$fx/tree"
  write_fake_bun "$fx/bin/bun" "1.4.2"
  write_meta "$tree/.tree-meta" "bun-v1.4.3"
  path="$fx/bin:$BASEPATH"
  out=$WORK/t2.out; err=$WORK/t2.err
  run_measure "$path" "$tree" "$out" "$err"
  rc=$?
  verdict=$(grep -F 'ВЕРДИКТ:' "$out" || true)
  if [[ $rc -eq 1 ]] && printf '%s\n' "$verdict" | grep -q -F 'ВЕРДИКТ: расходятся' \
    && printf '%s\n' "$verdict" | grep -q -F 'стенд=1.4.2' \
    && printf '%s\n' "$verdict" | grep -q -F 'образ=1.4.3'; then
    tooth_pass
    return 0
  fi
  tooth_fail "ждали расходятся с обеими версиями rc=1, получили rc=$rc вердикт=${verdict:-нет} stdout=$(cat "$out") stderr=$(cat "$err")"
}

# ЗУБ 3: нет bun / нечитаемая мета → отказ прибора (код 2), НЕ «совпадают».
# Красный: fail-open (пустое измерение объявить совпадением).
tooth_3() {
  TOOTH_N=3 TOOTH_NAME='отказ-пустого' TOOTH_RC=0
  local fx tree out err rc path
  fx=$(mktemp -d "$WORK/fx3.XXXXXX")
  tree="$fx/tree"
  write_meta "$tree/.tree-meta" "bun-v1.4.2"
  path="$BASEPATH"
  out=$WORK/t3a.out; err=$WORK/t3a.err
  run_measure "$path" "$tree" "$out" "$err"
  rc=$?
  if grep -q -F 'ВЕРДИКТ: совпадают' "$out"; then
    tooth_fail "fail-open: bun нет, а вердикт совпадают rc=$rc stdout=$(cat "$out") stderr=$(cat "$err")"
    return 0
  fi
  if [[ $rc -ne 2 ]] || ! grep -q -F 'ПРИБОР: bun не найден' "$err"; then
    tooth_fail "нет bun: ждали rc=2 и ПРИБОР bun не найден, получили rc=$rc stdout=$(cat "$out") stderr=$(cat "$err")"
    return 0
  fi
  write_fake_bun "$fx/bin/bun" "1.4.2"
  path="$fx/bin:$BASEPATH"
  mkdir -p "$fx/empty-tree"
  out=$WORK/t3b.out; err=$WORK/t3b.err
  run_measure "$path" "$fx/empty-tree" "$out" "$err"
  rc=$?
  if grep -q -F 'ВЕРДИКТ: совпадают' "$out"; then
    tooth_fail "fail-open: мета нет, а вердикт совпадают rc=$rc stdout=$(cat "$out") stderr=$(cat "$err")"
    return 0
  fi
  if [[ $rc -ne 2 ]] || ! grep -q -F 'ПРИБОР:' "$err"; then
    tooth_fail "нет мета: ждали rc=2 и ПРИБОР, получили rc=$rc stdout=$(cat "$out") stderr=$(cat "$err")"
    return 0
  fi
  tooth_pass
}

# ЗУБ 4: несколько копий с разными версиями — назвать исполняемую и напечатать остальные.
# Красный: брать первую попавшуюся (остальных нет в выводе).
tooth_4() {
  TOOTH_N=4 TOOTH_NAME='несколько-копий' TOOTH_RC=0
  local fx tree out err rc path
  fx=$(mktemp -d "$WORK/fx4.XXXXXX")
  tree="$fx/tree"
  write_fake_bun "$fx/bin1/bun" "1.4.2"
  write_fake_bun "$fx/bin2/bun" "1.3.14"
  write_meta "$tree/.tree-meta" "bun-v1.4.2"
  path="$fx/bin1:$fx/bin2:$BASEPATH"
  out=$WORK/t4.out; err=$WORK/t4.err
  run_measure "$path" "$tree" "$out" "$err"
  rc=$?
  if ! grep -F 'ИСПОЛНЯЕМЫЙ' "$out" | grep -q -F 'version=1.4.2'; then
    tooth_fail "не назван исполняемый 1.4.2 rc=$rc stdout=$(cat "$out") stderr=$(cat "$err")"
    return 0
  fi
  if ! grep -q -F '1.3.14' "$out"; then
    tooth_fail "вторая копия 1.3.14 не напечатана rc=$rc stdout=$(cat "$out") stderr=$(cat "$err")"
    return 0
  fi
  if ! grep -q -F 'НАХОДКА: копии bun расходятся' "$out"; then
    tooth_fail "нет находки расхождения копий rc=$rc stdout=$(cat "$out") stderr=$(cat "$err")"
    return 0
  fi
  if ! grep -q -F 'исполняемый=1.4.2' "$out" || ! grep -q -F 'другие=1.3.14' "$out"; then
    tooth_fail "находка без пары исполняемый/другие rc=$rc stdout=$(cat "$out")"
    return 0
  fi
  tooth_pass
}

# ЗУБ 5: сторож перечня — синтетический лишний зуб в TEETH_LIST обязан давать
# rc=4 с причиной словами, а не молчаливый прогон. Проба гоняет КОПИЮ прибора;
# BUN_DRIFT_GUARD_PROBE — тормоз рекурсии (внутри пробы зуб проходит молча,
# меряет наружный уровень).
tooth_5() {
  TOOTH_N=5 TOOTH_NAME='сторож-перечня' TOOTH_RC=0
  local fx copy out err rc
  if [[ -n "${BUN_DRIFT_GUARD_PROBE:-}" ]]; then
    tooth_pass
    return 0
  fi
  fx=$(mktemp -d "$WORK/fx5.XXXXXX")
  copy="$fx/bun-drift.sh"
  cp "$TOOL" "$copy"
  if ! python3 - "$copy" <<'PY'
import sys
p = sys.argv[1]
t = open(p, encoding='utf-8').read()
old = "TEETH_LIST=(1 2 3 4 5 6 7 8)\n"
new = "TEETH_LIST=(1 2 3 4 5 6 7 8 99)\n"
c = t.count(old)
if c != 1:
    sys.stderr.write('anchor count=%d\n' % c)
    raise SystemExit(2)
open(p, 'w', encoding='utf-8').write(t.replace(old, new, 1))
PY
  then
    tooth_fail "не смогли подсунуть лишний зуб в копию прибора"
    return 0
  fi
  out=$WORK/t5.out; err=$WORK/t5.err
  BUN_DRIFT_GUARD_PROBE=1 env -u BUN_DRIFT_SELF_CHECK_RUNNING bash "$copy" --self-check >"$out" 2>"$err"
  rc=$?
  if [[ $rc -eq 4 ]] && grep -q -F "объявлено зубов=$EXPECTED_TEETH" "$out" && grep -q -F 'в перечне=9' "$out"; then
    tooth_pass
    return 0
  fi
  tooth_fail "лишний зуб в перечне: ждали rc=4 с причиной словами, получили rc=$rc stdout=$(cat "$out") stderr=$(cat "$err")"
}

# ЗУБ 6: нечитаемая мета (права доступа) → отказ с ПРАВДИВОЙ причиной
# «не читается», а не замаскированной под «нет ключа stub».
tooth_6() {
  TOOTH_N=6 TOOTH_NAME='нечитаемая-мета' TOOTH_RC=0
  local fx tree out err rc path
  fx=$(mktemp -d "$WORK/fx6.XXXXXX")
  tree="$fx/tree"
  write_fake_bun "$fx/bin/bun" "1.4.2"
  write_meta "$tree/.tree-meta" "bun-v1.4.2"
  chmod 000 "$tree/.tree-meta"
  path="$fx/bin:$BASEPATH"
  out=$WORK/t6.out; err=$WORK/t6.err
  run_measure "$path" "$tree" "$out" "$err"
  rc=$?
  if grep -q -F 'ВЕРДИКТ:' "$out"; then
    tooth_fail "fail-open: мета нечитаема, а вердикт напечатан rc=$rc stdout=$(cat "$out")"
    return 0
  fi
  if [[ $rc -ne 2 ]] || ! grep -q -F 'мета дерева не читается' "$err"; then
    tooth_fail "нечитаемая мета: ждали rc=2 и «мета дерева не читается», получили rc=$rc stdout=$(cat "$out") stderr=$(cat "$err")"
    return 0
  fi
  tooth_pass
}

# ЗУБ 7: ПУСТО ≠ НОЛЬ — пустая версия стенда И пустой stub ОДНОВРЕМЕННО.
# Наивное сравнение объявило бы две пустоты равными; прибор обязан отказаться
# (rc=2 с ПРИБОР-причиной), а не печатать «совпадают».
tooth_7() {
  TOOTH_N=7 TOOTH_NAME='пусто-не-ноль' TOOTH_RC=0
  local fx tree out err rc path
  fx=$(mktemp -d "$WORK/fx7.XXXXXX")
  tree="$fx/tree"
  write_fake_bun "$fx/bin/bun" ""
  write_meta "$tree/.tree-meta" ""
  path="$fx/bin:$BASEPATH"
  out=$WORK/t7.out; err=$WORK/t7.err
  run_measure "$path" "$tree" "$out" "$err"
  rc=$?
  if grep -q -F 'ВЕРДИКТ:' "$out"; then
    tooth_fail "две пустоты объявлены вердиктом rc=$rc stdout=$(cat "$out")"
    return 0
  fi
  if [[ $rc -ne 2 ]] || ! grep -q -F 'ПРИБОР:' "$err"; then
    tooth_fail "пустой стенд + пустой stub: ждали rc=2 с ПРИБОР-причиной, получили rc=$rc stdout=$(cat "$out") stderr=$(cat "$err")"
    return 0
  fi
  tooth_pass
}

# ЗУБ 8: пустой --version у bun при валидном stub → отказ (rc=2, «не дал
# --version»), а не пустой стенд в вердикте.
tooth_8() {
  TOOTH_N=8 TOOTH_NAME='пустой-version' TOOTH_RC=0
  local fx tree out err rc path
  fx=$(mktemp -d "$WORK/fx8.XXXXXX")
  tree="$fx/tree"
  write_fake_bun "$fx/bin/bun" ""
  write_meta "$tree/.tree-meta" "bun-v1.4.2"
  path="$fx/bin:$BASEPATH"
  out=$WORK/t8.out; err=$WORK/t8.err
  run_measure "$path" "$tree" "$out" "$err"
  rc=$?
  if grep -q -F 'ВЕРДИКТ:' "$out"; then
    tooth_fail "пустой --version дал вердикт rc=$rc stdout=$(cat "$out")"
    return 0
  fi
  if [[ $rc -ne 2 ]] || ! grep -q -F 'не дал --version' "$err"; then
    tooth_fail "пустой --version: ждали rc=2 и «не дал --version», получили rc=$rc stdout=$(cat "$out") stderr=$(cat "$err")"
    return 0
  fi
  tooth_pass
}

run_one_tooth() {
  case "$1" in
    1) tooth_1 ;;
    2) tooth_2 ;;
    3) tooth_3 ;;
    4) tooth_4 ;;
    5) tooth_5 ;;
    6) tooth_6 ;;
    7) tooth_7 ;;
    8) tooth_8 ;;
    *) say "нет зуба $1"; return 2 ;;
  esac
}

mutate_copy() {
  local n="$1"
  python3 - "$n" "$TOOL" <<'PY'
import sys
n = int(sys.argv[1])
path = sys.argv[2]
text = open(path, encoding='utf-8').read()
pairs = []
if n == 1:
    pairs = [
        ('COMPARE_EQUAL_IS_MATCH=1  # MUT_COMPARE\n',
         'COMPARE_EQUAL_IS_MATCH=0  # MUT_COMPARE\n'),
    ]
elif n == 2:
    pairs = [
        ('PRINT_BOTH_VERSIONS=1  # MUT_VERDICT_BOTH\n',
         'PRINT_BOTH_VERSIONS=0  # MUT_VERDICT_BOTH\n'),
    ]
elif n == 3:
    pairs = [
        ('FAIL_CLOSED_MISSING=1  # MUT_FAIL_CLOSED\n',
         'FAIL_CLOSED_MISSING=0  # MUT_FAIL_CLOSED\n'),
    ]
elif n == 4:
    pairs = [
        ('LIST_ALL_COPIES=1  # MUT_ALL_COPIES\n',
         'LIST_ALL_COPIES=0  # MUT_ALL_COPIES\n'),
    ]
elif n == 5:
    pairs = [
        ('GUARD_TEETH_LIST=1  # MUT_GUARD_LIST\n',
         'GUARD_TEETH_LIST=0  # MUT_GUARD_LIST\n'),
    ]
elif n == 6:
    pairs = [
        ('META_MUST_BE_READABLE=1  # MUT_META_READABLE\n',
         'META_MUST_BE_READABLE=0  # MUT_META_READABLE\n'),
    ]
elif n == 7:
    # Две пустоты — один дефект: наивность прибора относительно пустых значений
    # ломается только парой флагов (stub-сторона + version-сторона).
    pairs = [
        ('REFUSE_STUB_EMPTY=1  # MUT_STUB_EMPTY\n',
         'REFUSE_STUB_EMPTY=0  # MUT_STUB_EMPTY\n'),
        ('REFUSE_VER_EMPTY=1  # MUT_VER_EMPTY\n',
         'REFUSE_VER_EMPTY=0  # MUT_VER_EMPTY\n'),
    ]
elif n == 8:
    pairs = [
        ('REFUSE_VER_EMPTY=1  # MUT_VER_EMPTY\n',
         'REFUSE_VER_EMPTY=0  # MUT_VER_EMPTY\n'),
    ]
else:
    sys.stderr.write('unknown mutation %d\n' % n)
    raise SystemExit(2)
for old, new in pairs:
    c = text.count(old)
    if c != 1:
        sys.stderr.write('mutation %d anchor count=%d for %r\n' % (n, c, old))
        raise SystemExit(2)
    text = text.replace(old, new, 1)
open(path, 'w', encoding='utf-8').write(text)
PY
}

self_check() {
  command -v python3 >/dev/null || die2 "ПРИБОР: нет python3 — --self-check не может мерить"
  local orig="$HERE/bun-drift.sh"
  [[ -f "$orig" ]] || orig="${BASH_SOURCE[0]}"
  WORK=$(mktemp -d "${BUN_DRIFT_SELF_WORK:-${TMPDIR:-/tmp}}/bun-drift-self.XXXXXX")
  cp "$orig" "$WORK/bun-drift.sh"
  TOOL=$WORK/bun-drift.sh
  SNAP=$WORK/bun-drift.sh.snap
  cp "$TOOL" "$SNAP"
  SNAP_HASH=$(sha256_of "$SNAP")
  trap 'rm -rf "$WORK"' EXIT

  local n list_len=${#TEETH_LIST[@]} green=0 redctl=0 ran=0
  if [[ "$GUARD_TEETH_LIST" -eq 1 && "$list_len" -ne "$EXPECTED_TEETH" ]]; then
    say "bun-drift --self-check: ОТКАЗ — объявлено зубов=$EXPECTED_TEETH, в перечне=$list_len (rc=4)"
    return 4
  fi
  say "bun-drift --self-check: зубы=$EXPECTED_TEETH (зелёная сторона на исходном тексте)"
  for n in "${TEETH_LIST[@]}"; do
    ran=$((ran + 1))
    TOOTH_RC=0
    run_one_tooth "$n" || return 2
    if [[ "$TOOTH_RC" -eq 0 ]]; then
      green=$((green + 1))
    fi
  done
  if [[ "$GUARD_TEETH_LIST" -eq 1 && "$ran" -ne "$EXPECTED_TEETH" ]]; then
    say "bun-drift --self-check: ОТКАЗ — объявлено зубов=$EXPECTED_TEETH, прогнано=$ran (rc=4)"
    return 4
  fi
  if [[ "$green" -ne "$EXPECTED_TEETH" ]]; then
    say "bun-drift --self-check: ОТКАЗ — зелёных $green из $EXPECTED_TEETH"
    return 1
  fi

  say "bun-drift --self-check: красный контроль (мутация → именной красный → снимок+sha256)"
  for n in "${TEETH_LIST[@]}"; do
    cp "$SNAP" "$TOOL"
    now=$(sha256_of "$TOOL")
    if [[ "$now" != "$SNAP_HASH" ]]; then
      say "ЗУБ $n красный-контроль: sha256 копии до мутации разошёлся с снимком"
      return 1
    fi
    if ! mutate_copy "$n"; then
      say "ЗУБ $n красный-контроль: ОТКАЗ прибора — якорь мутации не единственный"
      return 2
    fi
    TOOTH_RC=0
    run_one_tooth "$n" || return 2
    if [[ "$TOOTH_RC" -eq 0 ]]; then
      say "ЗУБ $n красный-контроль: мутация прошла молча (зуб без зубов)"
      cp "$SNAP" "$TOOL"
      return 1
    fi
    say "ЗУБ $n красный-контроль: мутация покраснела именным красным"
    cp "$SNAP" "$TOOL"
    now=$(sha256_of "$TOOL")
    if [[ "$now" != "$SNAP_HASH" ]]; then
      say "ЗУБ $n красный-контроль: sha256 после восстановления разошёлся"
      say "  now $now vs $SNAP_HASH"
      return 1
    fi
    redctl=$((redctl + 1))
  done
  say "bun-drift --self-check: ИТОГ зубов=$EXPECTED_TEETH зелёных=$green красный-контроль=$redctl"
  if [[ "$green" -eq "$EXPECTED_TEETH" && "$redctl" -eq "$EXPECTED_TEETH" ]]; then
    return 0
  fi
  return 1
}

TREE=
SELF_CHECK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tree)
      [[ $# -ge 2 ]] || die2 "ПРИБОР: --tree нужен путь"
      TREE=$2
      shift 2
      ;;
    --self-check) SELF_CHECK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      die2 "ПРИБОР: неизвестный аргумент $1"
      ;;
  esac
done

if [[ $SELF_CHECK -eq 1 ]]; then
  if [[ -n "${BUN_DRIFT_SELF_CHECK_RUNNING:-}" ]]; then
    die2 "ПРИБОР: вложенный --self-check"
  fi
  if [[ -n "$TREE" ]]; then
    die2 "ПРИБОР: --self-check и --tree вместе не допускаются"
  fi
  export BUN_DRIFT_SELF_CHECK_RUNNING=1
  self_check
  exit $?
fi

measure "$TREE"
