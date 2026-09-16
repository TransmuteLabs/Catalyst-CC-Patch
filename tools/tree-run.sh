#!/usr/bin/env bash
# Прибор быстрого цикла: дерево виртуальной ФС образа + bun cli, без пересборки.
#
# Коды:
#   0  измерено и сошлось (extract/update ок; A/B совпали; патч лёг; run — код ребёнка 0)
#   1  измерено и разошлось (A/B; патч отказал громко; run — код ребёнка, кроме случая ниже)
#   2  прибор не может мерить: нет bun/образа/python, таблица не разобралась,
#      ноль вхождений литерала, литерал не переписан (Cannot find module '/$bunfs/root/…')
#
# run возвращает код ребёнка, НО «Cannot find module '/$bunfs/root/» — это отказ
# прибора (код 2) со своей строкой, не молчаливая 1.
#
# КОНСТРЕЙНТ: законен для A/B (пристинное дерево против патченного в ОДНОМ
# механизме) и НЕ законен для абсолютных заявлений «работает в продукте».
# Строка ГРАНИЦА печатается в stderr на каждом запуске.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
EXTRACT="${TREE_EXTRACT:-$HERE/tree-extract.py}"
if [[ -z "${TREE_CENSUS:-}" && -f "$HERE/bytecode-census.py" ]]; then
  export TREE_CENSUS="$HERE/bytecode-census.py"
fi

# Единственный дом перечня зубов — этот массив: циклы self-check идут ТОЛЬКО
# по нему, литерального перечня нет. EXPECTED_TEETH — отдельная запись-контракт;
# сторож сверяет её с фактической длиной перечня и числом прогнанных зубов,
# рассинхрон = rc=4 с причиной словами.
TEETH_LIST=(1 2 3 4 5 6 7 8 9 10)
EXPECTED_TEETH=10
DRIFT_MATCH_PRINTS_MATCH=1  # MUT_DRIFT_MATCH
DRIFT_DIVERGE_PRINTS_BOTH=1  # MUT_DRIFT_DIVERGE
DRIFT_CODE2_IS_UNMEASURED=1  # MUT_DRIFT_UNMEAS
DRIFT_CODE4_EXITS_2=1  # MUT_DRIFT_CODE4

die2() { printf '%s\n' "$*" >&2; exit 2; }

# Часовой завершения обязателен для КАЖДОГО EXIT-трапа: bash 3.2 отдаёт код 0,
# когда скрипт с трапом умирает на фатальной ошибке подстановки (unbound
# variable под `set -u`, bad substitution) -- трап исполняется, `$?` внутри
# него ноль, и вызывающий видит успех вместо оборванного прогона. Штатный
# конец объявляет себя сам (__DONE=1), трап без объявления краснит.
# Уборка временного каталога живёт ЗДЕСЬ, а не отдельным трапом внутри
# self_check: `trap` в bash глобален, и трап функции затёр бы часового.
# Сигнальные трапы переводят сигнал в КОД (130/143) и стоят отдельными
# строками -- войдя в общий гвард, точечный TERM пришёлся бы на последнюю
# УДАВШУЮСЯ команду и был бы объявлен «ошибкой оболочки».
__DONE=0
WORK=''
__tree_run_guard() {
  __rc=$?
  [[ -n "${WORK:-}" ]] && rm -rf "$WORK"
  if [[ "${__DONE:-0}" != 1 && "$__rc" == 0 ]]; then
    echo "ОТКАЗ: tree-run оборвался, не дойдя до конца (ошибка оболочки выше)" >&2
    exit 2
  fi
  exit "$__rc"
}
trap '__tree_run_guard' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
  cat <<EOF
usage: bash tools/tree-run.sh <command> [options] [-- args...]
       bash tools/tree-run.sh --self-check

commands:
  extract --image PATH --out TREE
  update  --tree TREE --from DIR
  run     --tree TREE [--] [cli-args...]
  ab      --pristine PATH --patched PATH [--] [cli-args...]
  patch   --tree TREE --script PATH [--stitch FILE]

PATH у ab — дерево (каталог с .tree-meta) или образ (файл; будет извлечён).

коды: 0 сошлось / 1 разошлось / 2 прибор не может мерить
EOF
}

require_python() {
  command -v python3 >/dev/null || die2 "ПРИБОР: нет python3 — прибор не может мерить"
}

require_bun() {
  command -v bun >/dev/null || die2 "ПРИБОР: нет bun — прибор не может мерить"
}

print_boundary() {  # MUT_BOUNDARY_PRINT
  local tree="${1:-}"
  local img="${2:-}"
  local local_ver stub
  local drift drift_rc drift_all line
  local drift_stand drift_image drift_reason
  local match_ver s i
  local_ver=$(bun --version) || die2 "ПРИБОР: bun --version отказал"
  stub="неизвестен"
  if [[ -n "$tree" && -f "$tree/.tree-meta" ]]; then
    stub=$(python3 "$EXTRACT" meta-get --tree "$tree" --key stub) || stub="неизвестен"
  elif [[ -n "$img" && -f "$img" ]]; then
    stub=$(python3 "$EXTRACT" stub-version --image "$img") || stub="неизвестен"
  fi
  printf 'ГРАНИЦА: bun локальный=%s стаб-образа=%s; это не продукт — законен A/B внутри одного механизма, не абсолютное «работает в продукте»\n' "$local_ver" "$stub" >&2

  drift="${TREE_BUN_DRIFT:-$HERE/bun-drift.sh}"
  drift_rc=0
  drift_all=""
  if [[ ! -f "$drift" ]]; then
    drift_rc=2
    drift_all="ПРИБОР: нет bun-drift.sh ($drift)"
  elif [[ -n "$tree" && -f "$tree/.tree-meta" ]]; then
    drift_all=$(TREE_EXTRACT="$EXTRACT" bash "$drift" --tree "$tree" 2>&1) || drift_rc=$?
  elif [[ -n "$img" && -f "$img" ]]; then
    drift_all=$(TREE_EXTRACT="$EXTRACT" bash "$drift" --image "$img" 2>&1) || drift_rc=$?
  else
    drift_rc=2
    drift_all="ПРИБОР: нет дерева с .tree-meta и нет образа — рантайм мерить нечем"
  fi

  drift_stand=""
  drift_image=""
  drift_reason=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      *стенд=*)
        drift_stand="${line#*стенд=}"
        drift_stand="${drift_stand%% *}"
        ;;
    esac
    case "$line" in
      *образ=*)
        drift_image="${line#*образ=}"
        drift_image="${drift_image%% *}"
        ;;
    esac
    case "$line" in
      ПРИБОР:*)
        if [[ -z "$drift_reason" ]]; then
          drift_reason="$line"
        fi
        ;;
    esac
  done <<< "$drift_all"

  case "$drift_rc" in
    0)
      match_ver="$drift_stand"
      [[ -n "$match_ver" ]] || match_ver="$local_ver"
      if [[ "$DRIFT_MATCH_PRINTS_MATCH" -eq 1 ]]; then
        printf 'рантайм совпал: %s\n' "$match_ver" >&2
      else
        printf 'рантайм РАСХОДИТСЯ: стенд=%s образ=%s — A/B внутри одного механизма остаётся законным, заявления о продукте нет\n' "$match_ver" "$match_ver" >&2
      fi
      ;;
    1)
      s="$drift_stand"
      i="$drift_image"
      [[ -n "$s" ]] || s="$local_ver"
      [[ -n "$i" ]] || i="$stub"
      if [[ "$DRIFT_DIVERGE_PRINTS_BOTH" -eq 1 ]]; then
        printf 'рантайм РАСХОДИТСЯ: стенд=%s образ=%s — A/B внутри одного механизма остаётся законным, заявления о продукте нет\n' "$s" "$i" >&2
      else
        printf 'рантайм РАСХОДИТСЯ: стенд=%s — A/B внутри одного механизма остаётся законным, заявления о продукте нет\n' "$s" >&2
      fi
      ;;
    2)
      if [[ -z "$drift_reason" ]]; then
        drift_reason="$drift_all"
        [[ -n "$drift_reason" ]] || drift_reason="прибор вернул код 2 без причины"
      fi
      if [[ "$DRIFT_CODE2_IS_UNMEASURED" -eq 1 ]]; then
        printf 'рантайм НЕ ИЗМЕРЕН: %s\n' "$drift_reason" >&2
      else
        printf 'рантайм совпал: %s\n' "$local_ver" >&2
      fi
      ;;
    4)
      # КОНСТРЕЙНТ: код 4 значит, что сам прибор себе не верит — мерить им
      # нельзя, и «не измерено» здесь честнее любого вердикта.
      printf 'рантайм НЕ ИЗМЕРЕН: прибор себе не верит (сторож перечня, код 4) — мерить им нельзя\n' >&2
      if [[ "$DRIFT_CODE4_EXITS_2" -eq 1 ]]; then
        exit 2
      fi
      ;;
    *)
      if [[ -z "$drift_reason" ]]; then
        drift_reason="неожиданный код прибора $drift_rc"
      fi
      printf 'рантайм НЕ ИЗМЕРЕН: %s\n' "$drift_reason" >&2
      ;;
  esac
}

meta_get() {
  python3 "$EXTRACT" meta-get --tree "$1" --key "$2"
}

# RUN_CLI_KIND=instrument|child — отличить отказ прибора от кода ребёнка 2.
RUN_CLI_KIND=

run_cli() {
  local tree="$1" out="$2" err="$3"
  local rel cli rc
  RUN_CLI_KIND=instrument
  rel=$(meta_get "$tree" cli) || {
    printf '%s\n' "ПРИБОР: нет cli в мета ($tree)" >&2
    return 2
  }
  cli="$tree/$rel"
  if [[ ! -f "$cli" ]]; then
    printf '%s\n' "ПРИБОР: нет cli в дереве: $cli" >&2
    return 2
  fi
  if [[ ${#RUN_ARGS[@]} -gt 0 ]]; then
    bun "$cli" "${RUN_ARGS[@]}" >"$out" 2>"$err"
    rc=$?
  else
    bun "$cli" >"$out" 2>"$err"
    rc=$?
  fi
  if grep -q -F 'Cannot find module '"'"'/$bunfs/root/' "$err" "$out"; then
    printf '%s\n' 'ПРИБОР: литерал /$bunfs/root/ не переписан — bun не резолвит виртуальный путь' >>"$err"
    RUN_CLI_KIND=instrument
    return 2
  fi
  RUN_CLI_KIND=child
  return "$rc"
}

resolve_side() {
  local path="$1" tag="$2"
  if [[ -d "$path" ]]; then
    printf '%s\n' "$path"
    return 0
  fi
  if [[ -f "$path" ]]; then
    local dest
    dest=$(mktemp -d "${TMPDIR:-/tmp}/tree-run-$tag.XXXXXX")
    python3 "$EXTRACT" extract --image "$path" --out "$dest" >&2 || return 2
    printf '%s\n' "$dest"
    return 0
  fi
  printf '%s\n' "ПРИБОР: нет $tag: $path" >&2
  return 2
}

cmd_extract() {
  require_python
  require_bun
  [[ -n "$IMAGE" ]] || die2 "ПРИБОР: extract нужен --image"
  [[ -n "$OUT" ]] || die2 "ПРИБОР: extract нужен --out"
  python3 "$EXTRACT" extract --image "$IMAGE" --out "$OUT"
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    print_boundary "$OUT" ""
  else
    print_boundary "" "$IMAGE"
  fi
  __DONE=1
  exit "$rc"
}

cmd_update() {
  require_python
  require_bun
  [[ -n "$TREE" ]] || die2 "ПРИБОР: update нужен --tree"
  [[ -n "$FROM" ]] || die2 "ПРИБОР: update нужен --from"
  print_boundary "$TREE" ""
  python3 "$EXTRACT" update --tree "$TREE" --from "$FROM"
  local urc=$?
  __DONE=1
  exit "$urc"
}

cmd_run() {
  require_python
  require_bun
  [[ -n "$TREE" ]] || die2 "ПРИБОР: run нужен --tree"
  [[ -d "$TREE" ]] || die2 "ПРИБОР: нет дерева: $TREE"
  print_boundary "$TREE" ""
  local out err rc
  out=$(mktemp "${TMPDIR:-/tmp}/tree-run-out.XXXXXX")
  err=$(mktemp "${TMPDIR:-/tmp}/tree-run-err.XXXXXX")
  run_cli "$TREE" "$out" "$err"
  rc=$?
  cat "$out"
  cat "$err" >&2
  rm -f "$out" "$err"
  __DONE=1
  exit "$rc"
}

cmd_ab() {
  require_python
  require_bun
  [[ -n "$PRISTINE" ]] || die2 "ПРИБОР: ab нужен --pristine"
  [[ -n "$PATCHED" ]] || die2 "ПРИБОР: ab нужен --patched"
  local left right
  left=$(resolve_side "$PRISTINE" pristine) || exit 2
  right=$(resolve_side "$PATCHED" patched) || exit 2
  local ab_right="$right"  # MUT_AB_SHOULDERS
  print_boundary "$left" ""
  local lout lerr rout rerr lrc rrc lkind rkind
  lout=$(mktemp "${TMPDIR:-/tmp}/tree-run-ab-lo.XXXXXX")
  lerr=$(mktemp "${TMPDIR:-/tmp}/tree-run-ab-le.XXXXXX")
  rout=$(mktemp "${TMPDIR:-/tmp}/tree-run-ab-ro.XXXXXX")
  rerr=$(mktemp "${TMPDIR:-/tmp}/tree-run-ab-re.XXXXXX")
  run_cli "$left" "$lout" "$lerr"
  lrc=$?
  lkind="$RUN_CLI_KIND"
  run_cli "$ab_right" "$rout" "$rerr"
  rrc=$?
  rkind="$RUN_CLI_KIND"
  printf '%s\n' "--- pristine rc=$lrc ---"
  cat "$lout"
  if [[ -s "$lerr" ]]; then
    printf '%s\n' "--- pristine stderr ---" >&2
    cat "$lerr" >&2
  fi
  printf '%s\n' "--- patched rc=$rrc ---"
  cat "$rout"
  if [[ -s "$rerr" ]]; then
    printf '%s\n' "--- patched stderr ---" >&2
    cat "$rerr" >&2
  fi
  if [[ "$lkind" == instrument || "$rkind" == instrument ]]; then
    rm -f "$lout" "$lerr" "$rout" "$rerr"
    die2 "ПРИБОР: A/B не может мерить — отказ прибора на плече (pristine kind=$lkind rc=$lrc, patched kind=$rkind rc=$rrc)"
  fi
  if [[ "$lrc" -eq "$rrc" ]] && cmp -s "$lout" "$rout"; then
    printf '%s\n' "ВЕРДИКТ: совпали"
    rm -f "$lout" "$lerr" "$rout" "$rerr"
    __DONE=1
    exit 0
  fi
  printf '%s\n' "ВЕРДИКТ: разошлись"
  rm -f "$lout" "$lerr" "$rout" "$rerr"
  exit 1
}

cmd_patch() {
  require_python
  require_bun
  [[ -n "$TREE" ]] || die2 "ПРИБОР: patch нужен --tree"
  [[ -n "$SCRIPT" ]] || die2 "ПРИБОР: patch нужен --script"
  [[ -d "$TREE" ]] || die2 "ПРИБОР: нет дерева: $TREE"
  [[ -f "$SCRIPT" ]] || die2 "ПРИБОР: нет скрипта патча: $SCRIPT"
  print_boundary "$TREE" ""
  local rel cli work in out helper err brc
  rel=$(meta_get "$TREE" cli) || exit 2
  cli="$TREE/$rel"
  [[ -f "$cli" ]] || die2 "ПРИБОР: нет cli в дереве: $cli"
  work=$(mktemp -d "${TMPDIR:-/tmp}/tree-run-patch.XXXXXX")
  in="$work/in.js"
  out="$work/out.js"
  helper="$work/run-patch.mjs"
  err="$work/err.txt"
  if [[ -n "${STITCH:-}" ]]; then
    [[ -f "$STITCH" ]] || { rm -rf "$work"; die2 "ПРИБОР: нет сшивки: $STITCH"; }
    cp "$STITCH" "$in"
  else
    cp "$cli" "$in"
  fi
  cat > "$helper" <<'JS'
const script = await Bun.file(process.env.TREE_PATCH_SCRIPT).text();
const input = await Bun.file(process.env.TREE_PATCH_IN).text();
const fn = new Function("js", "vars", script);
try {
  const result = await fn(input, {});
  if (typeof result !== "string") {
    console.error("ПРИБОР: патч вернул не строку: " + typeof result);
    process.exit(2);
  }
  await Bun.write(process.env.TREE_PATCH_OUT, result);
} catch (e) {
  const msg = String((e && e.message) || e);
  console.error(msg);
  process.exit(1);
}
JS
  export TREE_PATCH_SCRIPT="$SCRIPT"
  export TREE_PATCH_IN="$in"
  export TREE_PATCH_OUT="$out"
  bun "$helper" >"$work/out.txt" 2>"$err"
  brc=$?
  if [[ -s "$work/out.txt" ]]; then
    cat "$work/out.txt"
  fi
  if [[ $brc -eq 0 ]]; then
    if [[ -n "${STITCH:-}" ]]; then
      python3 "$EXTRACT" update-from-stitch --tree "$TREE" --orig "$in" --new "$out"
      local urc=$?
      rm -rf "$work"
      __DONE=1
      exit "$urc"
    fi
    cp "$out" "$cli"
    rm -rf "$work"
    printf 'patched %s\n' "$cli"
    __DONE=1
    exit 0
  fi
  cat "$err" >&2
  if grep -q -F 'could not be applied (nothing written)' "$err"; then
    # MUT_PATCH_PROPAGATE
    rm -rf "$work"
    __DONE=1
    exit 1
  fi
  rm -rf "$work"
  if [[ $brc -eq 2 ]]; then
    exit 2
  fi
  exit 1
}

# ---------------------------------------------------------------------------
# --self-check: зубы по TEETH_LIST, у каждого свой названный красный.
# Мутации правят КОПИЮ; оригинал не трогается. Снимок + sha256, не git.
# ---------------------------------------------------------------------------

sha256_of() {
  python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
}

say() { printf '%s\n' "$*"; }

write_fixture_patch() {
  cat > "$1" <<'JS'
if (js.includes("4.3.3 (tweakcc)")) {
  throw new Error("multi-provider patch: 29 of 29 patches could not be applied (nothing written)");
}
js = js.replace(
  'console.log("2.1.273 (Claude Code)");',
  'console.log("2.1.273 (Claude Code)");\n  console.log("4.3.3 (tweakcc)");'
);
return js;
JS
}

run_tool() {
  local out="$1" err="$2"
  shift 2
  bash "$TOOL" "$@" >"$out" 2>"$err"
  return $?
}

tooth_fail() {
  TOOTH_RC=1
  say "ЗУБ $TOOTH_N $TOOTH_NAME: КРАСНЫЙ -- $*"
}

tooth_pass() {
  say "ЗУБ $TOOTH_N $TOOTH_NAME: ЗЕЛЁНЫЙ"
}

# ЗУБ 1: дерево поднимается и отвечает версией.
# Красный: без перезаписи литерала — Cannot find module '/$bunfs/root/…'
# и прибор называет это своей строкой, не молчаливая 1.
tooth_1() {
  TOOTH_N=1 TOOTH_NAME='дерево-версия' TOOTH_RC=0
  local fx img tree out err rc
  fx=$(mktemp -d "$WORK/fx1.XXXXXX")
  img="$fx/img"
  tree="$fx/tree"
  out=$WORK/t1.out; err=$WORK/t1.err
  python3 "$EXTRACT" emit-fixture --out "$img" >"$fx/emit.out" 2>"$fx/emit.err" || {
    tooth_fail "emit-fixture rc=$? $(cat "$fx/emit.err")"
    return 0
  }
  run_tool "$out" "$err" extract --image "$img" --out "$tree"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    tooth_fail "extract rc=$rc stdout=$(cat "$out") stderr=$(cat "$err")"
    return 0
  fi
  run_tool "$out" "$err" run --tree "$tree" -- --version
  rc=$?
  if grep -q -F '2.1.273 (Claude Code)' "$out" && [[ $rc -eq 0 ]]; then
    tooth_pass
    return 0
  fi
  if grep -q -F 'Cannot find module '"'"'/$bunfs/root/' "$err" "$out"; then
    if grep -q -F 'ПРИБОР: литерал /$bunfs/root/ не переписан' "$err" && [[ $rc -eq 2 ]]; then
      tooth_fail "без перезаписи bun не резолвит /\$bunfs/root/ (прибор назвал, rc=2)"
      return 0
    fi
    tooth_fail "Cannot find module есть, но прибор не назвал своей строкой rc=$rc stderr=$(cat "$err")"
    return 0
  fi
  tooth_fail "нет версии и нет Cannot find module rc=$rc stdout=$(cat "$out") stderr=$(cat "$err")"
}

# ЗУБ 2: префикс сохраняет $bunfs — требование верности стенда бою (в бою путь
# виртуальный). Красный: собрать префикс без этой подстроки.
# Резолв модулей от $bunfs не зависит (замерено A/B на шести входах);
# bun --version на префиксе без $bunfs остаётся rc=0 — зуб всё равно красный.
# ЧЕСТНАЯ ГРАНИЦА: зуб мерит САМ ПРЕФИКС, потому что различия в поведении
# A/B найти не удалось (50 входов + 15 внутренних, фрагмент исходника не
# показан ни разу). Не выдавать этот зуб за наблюдение различия.
tooth_2() {
  TOOTH_N=2 TOOTH_NAME='префикс-bunfs' TOOTH_RC=0
  local fx img tree out err rc prefix
  fx=$(mktemp -d "$WORK/fx2.XXXXXX")
  img="$fx/img"
  tree="$fx/tree"
  out=$WORK/t2.out; err=$WORK/t2.err
  python3 "$EXTRACT" emit-fixture --out "$img" >"$fx/emit.out" 2>"$fx/emit.err" || {
    tooth_fail "emit-fixture $(cat "$fx/emit.err")"
    return 0
  }
  run_tool "$out" "$err" extract --image "$img" --out "$tree"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    tooth_fail "extract rc=$rc stderr=$(cat "$err")"
    return 0
  fi
  prefix=$(python3 "$EXTRACT" meta-get --tree "$tree" --key prefix) || {
    tooth_fail "нет prefix в мета"
    return 0
  }
  case "$prefix" in
    *'$bunfs'*)
      tooth_pass
      return 0
      ;;
  esac
  # префикс без $bunfs: зуб красный. bun --version rc=0 здесь — замерённый
  # факт (резолв не зависит от $bunfs), не повод зенить зуб.
  run_tool "$out" "$err" run --tree "$tree" -- --version
  rc=$?
  if grep -q -F '2.1.273 (Claude Code)' "$out" && [[ $rc -eq 0 ]]; then
    say "замерено: префикс без \$bunfs, bun --version rc=0 — резолв модулей от \$bunfs не зависит (A/B шесть входов); xg в 2.1.273 linux (chunk-mdeqame7.js) — гейт чтения исходника для фрагмента у стека, не резолв"
  else
    say "префикс без \$bunfs: bun --version rc=$rc"
  fi
  tooth_fail "префикс не содержит \$bunfs: $prefix"
}

# ЗУБ 3: ноль вхождений литерала = отказ прибора (код 2), не успех.
tooth_3() {
  TOOTH_N=3 TOOTH_NAME='ноль-вхождений' TOOTH_RC=0
  local fx img tree out err rc
  fx=$(mktemp -d "$WORK/fx3.XXXXXX")
  img="$fx/img"
  tree="$fx/tree"
  out=$WORK/t3.out; err=$WORK/t3.err
  python3 "$EXTRACT" emit-fixture --out "$img" --no-literal >"$fx/emit.out" 2>"$fx/emit.err" || {
    tooth_fail "emit-fixture --no-literal $(cat "$fx/emit.err")"
    return 0
  }
  run_tool "$out" "$err" extract --image "$img" --out "$tree"
  rc=$?
  if [[ $rc -eq 2 ]] && grep -q -F 'ноль вхождений литерала /$bunfs/root/' "$err"; then
    tooth_pass
    return 0
  fi
  if [[ $rc -eq 0 ]]; then
    tooth_fail "fail-open: ноль вхождений принят как успех stdout=$(cat "$out")"
    return 0
  fi
  tooth_fail "ожидали rc=2 и «ноль вхождений», получили rc=$rc stderr=$(cat "$err")"
}

# ЗУБ 4: A/B различает пристин и патч (строка tweakcc только на патченном).
# Красный: оба плеча — пристин, вердикт «совпали».
tooth_4() {
  TOOTH_N=4 TOOTH_NAME='ab-различение' TOOTH_RC=0
  local fx img_p img_t tree_p tree_t out err rc
  fx=$(mktemp -d "$WORK/fx4.XXXXXX")
  img_p="$fx/img-p"
  img_t="$fx/img-t"
  tree_p="$fx/tree-p"
  tree_t="$fx/tree-t"
  out=$WORK/t4.out; err=$WORK/t4.err
  python3 "$EXTRACT" emit-fixture --out "$img_p" >"$fx/e1.out" 2>"$fx/e1.err" || {
    tooth_fail "emit pristine $(cat "$fx/e1.err")"
    return 0
  }
  python3 "$EXTRACT" emit-fixture --out "$img_t" --patched >"$fx/e2.out" 2>"$fx/e2.err" || {
    tooth_fail "emit patched $(cat "$fx/e2.err")"
    return 0
  }
  run_tool "$fx/xp.out" "$fx/xp.err" extract --image "$img_p" --out "$tree_p"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    tooth_fail "extract pristine rc=$rc $(cat "$fx/xp.err")"
    return 0
  fi
  run_tool "$fx/xt.out" "$fx/xt.err" extract --image "$img_t" --out "$tree_t"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    tooth_fail "extract patched rc=$rc $(cat "$fx/xt.err")"
    return 0
  fi
  run_tool "$out" "$err" ab --pristine "$tree_p" --patched "$tree_t" -- --version
  rc=$?
  if grep -q -F 'ВЕРДИКТ: совпали' "$out"; then
    tooth_fail "вердикт совпали (зуб на различение) rc=$rc stdout=$(cat "$out")"
    return 0
  fi
  if grep -q -F 'ВЕРДИКТ: разошлись' "$out" && [[ $rc -eq 1 ]]; then
    if grep -q -F '4.3.3 (tweakcc)' "$out" && grep -q -F '2.1.273 (Claude Code)' "$out"; then
      tooth_pass
      return 0
    fi
    tooth_fail "разошлись, но нет пары version/tweakcc stdout=$(cat "$out")"
    return 0
  fi
  tooth_fail "ожидали вердикт разошлись rc=1, получили rc=$rc stdout=$(cat "$out") stderr=$(cat "$err")"
}

# ЗУБ 5: неидемпотентность видна громко.
# Красный: проглотить код повторного патча.
tooth_5() {
  TOOTH_N=5 TOOTH_NAME='неидемпотентность' TOOTH_RC=0
  local fx img tree script out err rc
  fx=$(mktemp -d "$WORK/fx5.XXXXXX")
  img="$fx/img"
  tree="$fx/tree"
  script="$fx/patch.js"
  out=$WORK/t5.out; err=$WORK/t5.err
  python3 "$EXTRACT" emit-fixture --out "$img" >"$fx/emit.out" 2>"$fx/emit.err" || {
    tooth_fail "emit-fixture $(cat "$fx/emit.err")"
    return 0
  }
  run_tool "$fx/x.out" "$fx/x.err" extract --image "$img" --out "$tree"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    tooth_fail "extract rc=$rc $(cat "$fx/x.err")"
    return 0
  fi
  write_fixture_patch "$script"
  run_tool "$out" "$err" patch --tree "$tree" --script "$script"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    tooth_fail "первый патч rc=$rc stderr=$(cat "$err") stdout=$(cat "$out")"
    return 0
  fi
  run_tool "$out" "$err" patch --tree "$tree" --script "$script"
  rc=$?
  if grep -q -F 'could not be applied (nothing written)' "$err" && [[ $rc -ne 0 ]]; then
    tooth_pass
    return 0
  fi
  if [[ $rc -eq 0 ]]; then
    tooth_fail "повторный патч проглочен (rc=0) stdout=$(cat "$out") stderr=$(cat "$err")"
    return 0
  fi
  tooth_fail "повторный патч rc=$rc без «could not be applied (nothing written)» stderr=$(cat "$err")"
}

# ЗУБ 6: строка границы в stderr каждого запуска.
tooth_6() {
  TOOTH_N=6 TOOTH_NAME='граница' TOOTH_RC=0
  local fx img tree out err rc
  fx=$(mktemp -d "$WORK/fx6.XXXXXX")
  img="$fx/img"
  tree="$fx/tree"
  out=$WORK/t6.out; err=$WORK/t6.err
  python3 "$EXTRACT" emit-fixture --out "$img" >"$fx/emit.out" 2>"$fx/emit.err" || {
    tooth_fail "emit-fixture $(cat "$fx/emit.err")"
    return 0
  }
  run_tool "$out" "$err" extract --image "$img" --out "$tree"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    tooth_fail "extract rc=$rc stderr=$(cat "$err")"
    return 0
  fi
  if grep -q -F 'ГРАНИЦА:' "$err" && grep -q -F 'это не продукт' "$err"; then
    if grep -q -F 'bun локальный=' "$err"; then
      tooth_pass
      return 0
    fi
    tooth_fail "граница без версии bun stderr=$(cat "$err")"
    return 0
  fi
  tooth_fail "нет строки границы в stderr: $(cat "$err")"
}

rewrite_stub() {
  local meta="$1" stub="$2"
  python3 - "$meta" "$stub" <<'PY'
import sys
p, stub = sys.argv[1], sys.argv[2]
lines = []
saw = 0
for line in open(p, encoding='utf-8'):
    if line.startswith('stub='):
        lines.append('stub=%s\n' % stub)
        saw = 1
    else:
        lines.append(line)
if not saw:
    lines.append('stub=%s\n' % stub)
open(p, 'w', encoding='utf-8').writelines(lines)
PY
}

write_fake_drift() {
  local dest="$1" rc="$2" msg="$3"
  cat > "$dest" <<EOF
#!/bin/sh
printf '%s\\n' '$msg' >&2
exit $rc
EOF
  chmod +x "$dest"
}

# ЗУБ 7: bun-drift код 0 → «рантайм совпал», код tree-run не меняется.
# Красный: ветка совпадения печатает расхождение (совпал без кода 0).
tooth_7() {
  TOOTH_N=7 TOOTH_NAME='рантайм-совпал' TOOTH_RC=0
  local fx img tree out err rc ver
  fx=$(mktemp -d "$WORK/fx7.XXXXXX")
  img="$fx/img"
  tree="$fx/tree"
  out=$WORK/t7.out; err=$WORK/t7.err
  python3 "$EXTRACT" emit-fixture --out "$img" >"$fx/emit.out" 2>"$fx/emit.err" || {
    tooth_fail "emit-fixture rc=$? $(cat "$fx/emit.err")"
    return 0
  }
  run_tool "$out" "$err" extract --image "$img" --out "$tree"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    tooth_fail "extract rc=$rc stdout=$(cat "$out") stderr=$(cat "$err")"
    return 0
  fi
  ver=$(bun --version) || {
    tooth_fail "bun --version отказал"
    return 0
  }
  rewrite_stub "$tree/.tree-meta" "bun-v$ver"
  run_tool "$out" "$err" run --tree "$tree" -- --version
  rc=$?
  if grep -q -F "рантайм совпал: $ver" "$err" && [[ $rc -eq 0 ]]; then
    if grep -q -F 'рантайм НЕ ИЗМЕРЕН' "$err" || grep -q -F 'рантайм РАСХОДИТСЯ' "$err"; then
      tooth_fail "совпал смешан с другим исходом rc=$rc stderr=$(cat "$err")"
      return 0
    fi
    tooth_pass
    return 0
  fi
  tooth_fail "ждали совпал rc=0, получили rc=$rc stdout=$(cat "$out") stderr=$(cat "$err")"
}

# ЗУБ 8: bun-drift код 1 → громкая строка с ОБЕИМИ версиями, код tree-run не меняется.
# Красный: печатать только стенд, без образа.
tooth_8() {
  TOOTH_N=8 TOOTH_NAME='рантайм-расходятся' TOOTH_RC=0
  local fx img tree out err rc ver verdict
  fx=$(mktemp -d "$WORK/fx8.XXXXXX")
  img="$fx/img"
  tree="$fx/tree"
  out=$WORK/t8.out; err=$WORK/t8.err
  python3 "$EXTRACT" emit-fixture --out "$img" >"$fx/emit.out" 2>"$fx/emit.err" || {
    tooth_fail "emit-fixture rc=$? $(cat "$fx/emit.err")"
    return 0
  }
  run_tool "$out" "$err" extract --image "$img" --out "$tree"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    tooth_fail "extract rc=$rc stdout=$(cat "$out") stderr=$(cat "$err")"
    return 0
  fi
  ver=$(bun --version) || {
    tooth_fail "bun --version отказал"
    return 0
  }
  rewrite_stub "$tree/.tree-meta" "bun-v0.0.0"
  run_tool "$out" "$err" run --tree "$tree" -- --version
  rc=$?
  verdict=$(grep -F 'рантайм РАСХОДИТСЯ:' "$err" || true)
  if [[ $rc -eq 0 ]] && printf '%s\n' "$verdict" | grep -q -F "стенд=$ver" \
    && printf '%s\n' "$verdict" | grep -q -F 'образ=0.0.0'; then
    if grep -q -F 'рантайм совпал' "$err"; then
      tooth_fail "расхождение объявлено совпадением rc=$rc stderr=$(cat "$err")"
      return 0
    fi
    tooth_pass
    return 0
  fi
  tooth_fail "ждали РАСХОДИТСЯ с обеими версиями rc=0, получили rc=$rc вердикт=${verdict:-нет} stdout=$(cat "$out") stderr=$(cat "$err")"
}

# ЗУБ 9: bun-drift код 2 → «рантайм НЕ ИЗМЕРЕН» с причиной, код tree-run не меняется.
# Красный: код 2 печатает «совпал» (пусто не ноль).
tooth_9() {
  TOOTH_N=9 TOOTH_NAME='рантайм-не-измерен' TOOTH_RC=0
  local fx img tree out err rc
  fx=$(mktemp -d "$WORK/fx9.XXXXXX")
  img="$fx/img"
  tree="$fx/tree"
  out=$WORK/t9.out; err=$WORK/t9.err
  python3 "$EXTRACT" emit-fixture --out "$img" >"$fx/emit.out" 2>"$fx/emit.err" || {
    tooth_fail "emit-fixture rc=$? $(cat "$fx/emit.err")"
    return 0
  }
  run_tool "$out" "$err" extract --image "$img" --out "$tree"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    tooth_fail "extract rc=$rc stdout=$(cat "$out") stderr=$(cat "$err")"
    return 0
  fi
  write_fake_drift "$fx/fake-drift.sh" 2 'ПРИБОР: зуб-не-измерен синтетический отказ'
  TREE_BUN_DRIFT="$fx/fake-drift.sh" run_tool "$out" "$err" run --tree "$tree" -- --version
  rc=$?
  if [[ $rc -eq 0 ]] && grep -q -F 'рантайм НЕ ИЗМЕРЕН' "$err" \
    && grep -q -F 'зуб-не-измерен синтетический отказ' "$err" \
    && grep -q -F '2.1.273 (Claude Code)' "$out"; then
    if grep -q -F 'рантайм совпал' "$err"; then
      tooth_fail "код 2 объявлен совпадением rc=$rc stderr=$(cat "$err")"
      return 0
    fi
    tooth_pass
    return 0
  fi
  tooth_fail "ждали НЕ ИЗМЕРЕН rc=0 с причиной прибора, получили rc=$rc stdout=$(cat "$out") stderr=$(cat "$err")"
}

# ЗУБ 10: bun-drift код 4 (сторож перечня) → громкая строка + tree-run отдаёт 2.
# Красный: код 4 не останавливает прогон (cli всё же едет, rc ребёнка).
tooth_10() {
  TOOTH_N=10 TOOTH_NAME='сторож-прибора-код4' TOOTH_RC=0
  local fx img tree out err rc
  fx=$(mktemp -d "$WORK/fx10.XXXXXX")
  img="$fx/img"
  tree="$fx/tree"
  out=$WORK/t10.out; err=$WORK/t10.err
  python3 "$EXTRACT" emit-fixture --out "$img" >"$fx/emit.out" 2>"$fx/emit.err" || {
    tooth_fail "emit-fixture rc=$? $(cat "$fx/emit.err")"
    return 0
  }
  run_tool "$out" "$err" extract --image "$img" --out "$tree"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    tooth_fail "extract rc=$rc stdout=$(cat "$out") stderr=$(cat "$err")"
    return 0
  fi
  write_fake_drift "$fx/fake-drift.sh" 4 'объявлено зубов=8, в перечне=9'
  TREE_BUN_DRIFT="$fx/fake-drift.sh" run_tool "$out" "$err" run --tree "$tree" -- --version
  rc=$?
  if [[ $rc -eq 2 ]] && grep -q -F 'рантайм НЕ ИЗМЕРЕН' "$err" \
    && grep -q -F 'себе не верит' "$err"; then
    if grep -q -F 'рантайм совпал' "$err"; then
      tooth_fail "код 4 объявлен совпадением rc=$rc stderr=$(cat "$err")"
      return 0
    fi
    if grep -q -F '2.1.273 (Claude Code)' "$out"; then
      tooth_fail "cli запустился при коде 4 прибора rc=$rc stdout=$(cat "$out")"
      return 0
    fi
    tooth_pass
    return 0
  fi
  tooth_fail "ждали НЕ ИЗМЕРЕН rc=2 на стороже прибора, получили rc=$rc stdout=$(cat "$out") stderr=$(cat "$err")"
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
    9) tooth_9 ;;
    10) tooth_10 ;;
    *) say "нет зуба $1"; return 2 ;;
  esac
}

mutate_copy() {
  local n="$1"
  python3 - "$n" "$WORK/tree-extract.py" "$WORK/tree-run.sh" <<'PY'
import sys
n = int(sys.argv[1])
extract, sh = sys.argv[2], sys.argv[3]
if n in (1, 2, 3):
    path = extract
elif n in (4, 5, 6, 7, 8, 9, 10):
    path = sh
else:
    sys.stderr.write('unknown mutation %d\n' % n)
    raise SystemExit(2)
text = open(path, encoding='utf-8').read()
pairs = []
if n == 1:
    pairs = [
        ('REWRITE_ENABLED = True  # MUT_REWRITE\n',
         'REWRITE_ENABLED = False  # MUT_REWRITE\n'),
    ]
elif n == 2:
    pairs = [
        ("BUNFS_ROOT_SUFFIX = '/$bunfs/root/'  # MUT_BUNFS_PREFIX\n",
         "BUNFS_ROOT_SUFFIX = '/root/'  # MUT_BUNFS_PREFIX\n"),
        ("    if b'$bunfs' not in prefix:  # MUT_BUNFS_CHECK\n",
         "    if False and b'$bunfs' not in prefix:  # MUT_BUNFS_CHECK\n"),
    ]
elif n == 3:
    pairs = [
        ('ZERO_HITS_IS_ERROR = True  # MUT_ZERO_HITS\n',
         'ZERO_HITS_IS_ERROR = False  # MUT_ZERO_HITS\n'),
    ]
elif n == 4:
    pairs = [
        ('  local ab_right="$right"  # MUT_AB_SHOULDERS\n',
         '  local ab_right="$left"  # MUT_AB_SHOULDERS\n'),
    ]
elif n == 5:
    pairs = [
        ('    # MUT_PATCH_PROPAGATE\n    rm -rf "$work"\n    __DONE=1\n    exit 1\n',
         '    # MUT_PATCH_PROPAGATE\n    rm -rf "$work"\n    __DONE=1\n    exit 0\n'),
    ]
elif n == 6:
    pairs = [
        ('print_boundary() {  # MUT_BOUNDARY_PRINT\n  local tree="${1:-}"\n',
         'print_boundary() {  # MUT_BOUNDARY_PRINT\n  return 0\n  local tree="${1:-}"\n'),
    ]
elif n == 7:
    pairs = [
        ('DRIFT_MATCH_PRINTS_MATCH=1  # MUT_DRIFT_MATCH\n',
         'DRIFT_MATCH_PRINTS_MATCH=0  # MUT_DRIFT_MATCH\n'),
    ]
elif n == 8:
    pairs = [
        ('DRIFT_DIVERGE_PRINTS_BOTH=1  # MUT_DRIFT_DIVERGE\n',
         'DRIFT_DIVERGE_PRINTS_BOTH=0  # MUT_DRIFT_DIVERGE\n'),
    ]
elif n == 9:
    pairs = [
        ('DRIFT_CODE2_IS_UNMEASURED=1  # MUT_DRIFT_UNMEAS\n',
         'DRIFT_CODE2_IS_UNMEASURED=0  # MUT_DRIFT_UNMEAS\n'),
    ]
elif n == 10:
    pairs = [
        ('DRIFT_CODE4_EXITS_2=1  # MUT_DRIFT_CODE4\n',
         'DRIFT_CODE4_EXITS_2=0  # MUT_DRIFT_CODE4\n'),
    ]
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
  require_python
  require_bun
  local orig_here="$HERE"
  export TREE_CENSUS="$orig_here/bytecode-census.py"
  WORK=$(mktemp -d "${TREE_SELF_WORK:-${TMPDIR:-/tmp}}/tree-run-self.XXXXXX")
  cp "$orig_here/tree-run.sh" "$WORK/tree-run.sh"
  cp "$orig_here/tree-extract.py" "$WORK/tree-extract.py"
  cp "$orig_here/bun-drift.sh" "$WORK/bun-drift.sh" || return 2
  TOOL=$WORK/tree-run.sh
  EXTRACT=$WORK/tree-extract.py
  SNAP_SH=$WORK/tree-run.sh.snap
  SNAP_PY=$WORK/tree-extract.py.snap
  cp "$TOOL" "$SNAP_SH"
  cp "$EXTRACT" "$SNAP_PY"
  SNAP_SH_HASH=$(sha256_of "$SNAP_SH")
  SNAP_PY_HASH=$(sha256_of "$SNAP_PY")

  local n list_len=${#TEETH_LIST[@]} green=0 redctl=0 ran=0
  if [[ "$list_len" -ne "$EXPECTED_TEETH" ]]; then
    say "tree-run --self-check: ОТКАЗ — объявлено зубов=$EXPECTED_TEETH, в перечне=$list_len (rc=4)"
    return 4
  fi
  say "tree-run --self-check: зубы=$EXPECTED_TEETH (зелёная сторона на исходном тексте)"
  for n in "${TEETH_LIST[@]}"; do
    ran=$((ran + 1))
    TOOTH_RC=0
    run_one_tooth "$n" || return 2
    if [[ "$TOOTH_RC" -eq 0 ]]; then
      green=$((green + 1))
    fi
  done
  if [[ "$ran" -ne "$EXPECTED_TEETH" ]]; then
    say "tree-run --self-check: ОТКАЗ — объявлено зубов=$EXPECTED_TEETH, прогнано=$ran (rc=4)"
    return 4
  fi
  if [[ "$green" -ne "$EXPECTED_TEETH" ]]; then
    say "tree-run --self-check: ОТКАЗ — зелёных $green из $EXPECTED_TEETH"
    return 1
  fi

  say "tree-run --self-check: красный контроль (мутация → именной красный → снимок)"
  for n in "${TEETH_LIST[@]}"; do
    cp "$SNAP_SH" "$TOOL"
    cp "$SNAP_PY" "$EXTRACT"
    if ! mutate_copy "$n"; then
      say "ЗУБ $n красный-контроль: ОТКАЗ прибора — якорь мутации не единственный"
      return 2
    fi
    TOOTH_RC=0
    run_one_tooth "$n" || return 2
    if [[ "$TOOTH_RC" -eq 0 ]]; then
      say "ЗУБ $n красный-контроль: мутация прошла молча (зуб без зубов)"
      cp "$SNAP_SH" "$TOOL"
      cp "$SNAP_PY" "$EXTRACT"
      return 1
    fi
    say "ЗУБ $n красный-контроль: мутация покраснела именным красным"
    cp "$SNAP_SH" "$TOOL"
    cp "$SNAP_PY" "$EXTRACT"
    local now_sh now_py
    now_sh=$(sha256_of "$TOOL")
    now_py=$(sha256_of "$EXTRACT")
    if [[ "$now_sh" != "$SNAP_SH_HASH" || "$now_py" != "$SNAP_PY_HASH" ]]; then
      say "ЗУБ $n красный-контроль: sha256 после восстановления разошёлся"
      say "  sh $now_sh vs $SNAP_SH_HASH"
      say "  py $now_py vs $SNAP_PY_HASH"
      return 1
    fi
    redctl=$((redctl + 1))
  done
  say "tree-run --self-check: ИТОГ зубов=$EXPECTED_TEETH зелёных=$green красный-контроль=$redctl"
  if [[ "$green" -eq "$EXPECTED_TEETH" && "$redctl" -eq "$EXPECTED_TEETH" ]]; then
    return 0
  fi
  return 1
}

# --- argv ---
CMD=
IMAGE=
OUT=
TREE=
FROM=
PRISTINE=
PATCHED=
SCRIPT=
STITCH=
SELF_CHECK=0
RUN_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    extract|update|run|ab|patch)
      if [[ -n "$CMD" ]]; then
        die2 "ПРИБОР: две команды ($CMD и $1)"
      fi
      CMD=$1
      shift
      ;;
    --self-check) SELF_CHECK=1; shift ;;
    --image)
      [[ $# -ge 2 ]] || die2 "ПРИБОР: --image нужен путь"
      IMAGE=$2; shift 2
      ;;
    --out)
      [[ $# -ge 2 ]] || die2 "ПРИБОР: --out нужен путь"
      OUT=$2; shift 2
      ;;
    --tree)
      [[ $# -ge 2 ]] || die2 "ПРИБОР: --tree нужен путь"
      TREE=$2; shift 2
      ;;
    --from)
      [[ $# -ge 2 ]] || die2 "ПРИБОР: --from нужен путь"
      FROM=$2; shift 2
      ;;
    --pristine)
      [[ $# -ge 2 ]] || die2 "ПРИБОР: --pristine нужен путь"
      PRISTINE=$2; shift 2
      ;;
    --patched)
      [[ $# -ge 2 ]] || die2 "ПРИБОР: --patched нужен путь"
      PATCHED=$2; shift 2
      ;;
    --script)
      [[ $# -ge 2 ]] || die2 "ПРИБОР: --script нужен путь"
      SCRIPT=$2; shift 2
      ;;
    --stitch)
      [[ $# -ge 2 ]] || die2 "ПРИБОР: --stitch нужен путь"
      STITCH=$2; shift 2
      ;;
    -h|--help) usage; __DONE=1; exit 0 ;;
    --) shift; RUN_ARGS=("$@"); break ;;
    *)
      if [[ "$CMD" == "run" || "$CMD" == "ab" ]]; then
        RUN_ARGS=("$@")
        break
      fi
      die2 "ПРИБОР: неизвестный аргумент $1"
      ;;
  esac
done

if [[ $SELF_CHECK -eq 1 ]]; then
  if [[ -n "${TREE_SELF_CHECK_RUNNING:-}" ]]; then
    die2 "ПРИБОР: вложенный --self-check"
  fi
  export TREE_SELF_CHECK_RUNNING=1
  self_check
  __sc_rc=$?
  __DONE=1
  exit "$__sc_rc"
fi

if [[ -z "$CMD" ]]; then
  usage >&2
  die2 "ПРИБОР: нет команды"
fi

case "$CMD" in
  extract) cmd_extract ;;
  update) cmd_update ;;
  run) cmd_run ;;
  ab) cmd_ab ;;
  patch) cmd_patch ;;
  *) die2 "ПРИБОР: неизвестная команда $CMD" ;;
esac
__DONE=1
