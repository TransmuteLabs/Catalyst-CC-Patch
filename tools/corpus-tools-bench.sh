#!/usr/bin/env bash
# Стенд корпусных инструментов: tools/sweep.sh и tools/fetch-corpus.sh.
#
# Зачем. Эти два скрипта -- фундамент измерительной базы: свип решает, что и на
# чём мерить, наполнитель решает, какие байты считать эталонными. Их гарантии
# держались на разовых ручных проверках, то есть на памяти человека; следующая
# правка снимала бы их беззвучно. Здесь они закреплены.
#
# Двери, которые стенд проверяет, срабатывают ДО первой сборки, поэтому корпус
# игрушечный (файлы в десятки байт), сборка не запускается, и весь прогон
# занимает секунды. Дом корпуса и список версий берутся из CORPUS_DIR и
# CORPUS_LIST -- боевые пути при этом не читаются и не пишутся.
#
# Два режима:
#   bash tools/corpus-tools-bench.sh              -- прогон сценариев
#   bash tools/corpus-tools-bench.sh --self-check -- каждая мутация обязана
#                                                    покраснить свой сценарий
# Второй режим -- ответ на вопрос «а стенд вообще может упасть?». Беззубый
# стенд неотличим от рабочего, пока не назовёшь мутацию, которая его краснит.
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
EXPECTED_SCENARIOS=12
EXPECTED_MUTATIONS=6

# Предусловие: живой настоящий прогон.
#
# Свип отказывается стартовать, пока жив чужой claude-patch-all.sh или tweakcc
# --apply -- это ГЛОБАЛЬНЫЙ страж общего состояния tweakcc, и подменять его
# ради стенда нельзя. Но тогда все сценарии свипа получают этот отказ вместо
# своего, и стенд краснеет по причине, не имеющей отношения к его предмету.
# Поэтому условие называется прямо и один раз, отдельным кодом возврата.
__snap=$(ps -eo pid,args)
__alive=$(printf '%s\n' "$__snap" | awk '
  { for (i = 2; i <= NF && i <= 8; i++)
      if ($i ~ /claude-patch-all\.sh$/) { print $1; next } }
  /catalyst-tweakcc.*index\.mjs.*--apply/ { print $1 }' || true)
if [[ -n "$__alive" ]]; then
  say() { printf '%s\n' "$*"; }
  say "corpus-tools-bench: ОТКАЗ -- идёт настоящий прогон (pid: $__alive)."
  say "  Стенд гоняет те же скрипты, и их же страж общего состояния tweakcc"
  say "  отказал бы каждому сценарию раньше проверяемой двери. Дождитесь конца."
  exit 2
fi

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/corpus-bench.XXXXXX")
cleanup() { rm -rf "$ROOT"; }
trap cleanup EXIT

FAILED=0
RUN=0

say()  { printf '%s\n' "$*"; }
ok()   { RUN=$((RUN+1)); say "  ok     $*"; }
bad()  { RUN=$((RUN+1)); FAILED=$((FAILED+1)); say "  ПРОВАЛ $*"; }

# --- игрушечный корпус -------------------------------------------------------
# Версии названы заведомо несуществующими в реестре: если сценарий всё же
# дойдёт до сети, он получит отказ, а не чужой образ.
mk_corpus() {   # каталог-назначение
  local dir=$1
  mkdir -p "$dir/corpus"
  printf 'образ девятьсот\n'      > "$dir/corpus/0.0.900.pristine"
  printf 'образ девятьсот один\n' > "$dir/corpus/0.0.901.pristine"
  local h900 h901
  h900=$(shasum -a 256 "$dir/corpus/0.0.900.pristine" | awk '{print $1}')
  h901=$(shasum -a 256 "$dir/corpus/0.0.901.pristine" | awk '{print $1}')
  { echo "# игрушечный список стенда"
    echo "900 0.0.900 $h900"
    echo "901 0.0.901 $h901"
  } > "$dir/versions.txt"
}

# Копия кита под мутации: сценарии всегда гоняют скрипты ИЗ НЕЁ, поэтому режим
# мутаций отличается от обычного ровно одной правкой в копии.
mk_kit() {   # каталог-назначение
  local dir=$1
  mkdir -p "$dir"
  cp -R "$KIT"/. "$dir"/
}

# --- сценарии ----------------------------------------------------------------
# Каждый: подготовить состояние, запустить, потребовать код возврата и текст.

# Свой рабочий корень: иначе стенд бьётся о замок ЖИВОГО прогона и пишет в его
# сводку. Каталог создаётся рядом с игрушечным корпусом и уходит вместе с ним.
run_sweep() {   # kit, corpus-dir, list, аргументы...
  local kit=$1 cdir=$2 list=$3; shift 3
  CORPUS_DIR="$cdir" CORPUS_LIST="$list" SWEEP_STATE_DIR="$cdir/state" \
    bash "$kit/tools/sweep.sh" "$@" 2>&1
}

run_fetch() {   # kit, corpus-dir, list
  local kit=$1 cdir=$2 list=$3
  CORPUS_DIR="$cdir" CORPUS_LIST="$list" bash "$kit/tools/fetch-corpus.sh" 2>&1
}

expect_refusal() {   # имя, ожидаемая подстрока, вывод, код
  local name=$1 want=$2 out=$3 rc=$4
  if [[ $rc -eq 0 ]]; then
    bad "$name: код возврата 0, ждали отказ"; return
  fi
  if [[ "$out" != *"$want"* ]]; then
    bad "$name: в выводе нет «${want}»; было: $(printf '%s' "$out" | head -2 | tr '\n' ' ')"
    return
  fi
  ok "$name"
}

scenario_1() {   # неизвестное имя версии
  local out rc
  out=$(run_sweep "$K" "$C/corpus" "$C/versions.txt" 999); rc=$?
  expect_refusal "1 неизвестная версия -- отказ" "не в списке" "$out" $rc
}

scenario_2() {   # образа нет
  rm -f "$C/corpus/0.0.901.pristine"
  local out rc
  out=$(run_sweep "$K" "$C/corpus" "$C/versions.txt" 901); rc=$?
  printf 'образ девятьсот один\n' > "$C/corpus/0.0.901.pristine"
  expect_refusal "2 образа нет -- отказ до сборки" "нет пристинных образов" "$out" $rc
}

scenario_3() {   # байты не сходятся с пином
  printf 'подменённые байты\n' > "$C/corpus/0.0.901.pristine"
  local out rc
  out=$(run_sweep "$K" "$C/corpus" "$C/versions.txt" 901); rc=$?
  printf 'образ девятьсот один\n' > "$C/corpus/0.0.901.pristine"
  expect_refusal "3 подменённый образ -- отказ по пину" "не сходится с пином" "$out" $rc
}

scenario_4() {   # пин не записан
  sed 's/^901 0.0.901 .*/901 0.0.901 -/' "$C/versions.txt" > "$C/versions.nopin.txt"
  local out rc
  out=$(run_sweep "$K" "$C/corpus" "$C/versions.nopin.txt" 901); rc=$?
  expect_refusal "4 пин не записан -- отказ" "пин не записан" "$out" $rc
}

scenario_5() {   # список пуст
  printf '# только комментарий\n' > "$C/versions.empty.txt"
  local out rc
  out=$(run_sweep "$K" "$C/corpus" "$C/versions.empty.txt"); rc=$?
  expect_refusal "5 пустой список -- отказ" "список версий пуст" "$out" $rc
}

scenario_6() {   # списка нет
  local out rc
  out=$(run_sweep "$K" "$C/corpus" "$C/нет-такого.txt"); rc=$?
  expect_refusal "6 нет списка версий -- отказ" "нет списка версий" "$out" $rc
}

scenario_7() {   # замок свипа занят
  local holder out rc
  mkdir -p "$S"
  perl -e 'use Fcntl ":flock"; open(my $fh, ">>", $ARGV[0]) or die $!;
           flock($fh, LOCK_EX) or die $!; sleep 20;' "$S/sweep.lock" &
  holder=$!
  sleep 1
  out=$(run_sweep "$K" "$C/corpus" "$C/versions.txt" 900); rc=$?
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  expect_refusal "7 замок свипа занят -- отказ с именем причины" "другой свип уже идёт" "$out" $rc
}

scenario_8() {   # метка происхождения видит неотслеживаемое
  # Строка метки берётся ИЗ САМОГО свипа по якорю: стенд не должен проверять
  # свою копию выражения -- она разошлась бы с оригиналом молча.
  local repo line out
  line=$(grep -n 'git status --porcelain' "$K/tools/sweep.sh" | head -1 | cut -d: -f2-)
  if [[ -z "$line" ]]; then
    bad "8 метка происхождения: якорь строки в sweep.sh не найден"; return
  fi
  repo=$(mktemp -d "$ROOT/gitrepo.XXXXXX")
  ( cd "$repo" && git init -q . && echo a > a.txt && git add a.txt \
      && git -c user.email=b@b -c user.name=b commit -qm init ) >/dev/null 2>&1
  echo untracked > "$repo/b.txt"
  out=$(SRC_KIT="$repo" SWEPT_STATE="sha" bash -c "$line; printf '%s' \"\$SWEPT_STATE\"")
  if [[ "$out" == *"+dirty"* ]]; then
    ok "8 метка происхождения видит неотслеживаемый файл"
  else
    bad "8 метка происхождения: неотслеживаемый файл не сделал дерево грязным (метка «${out}»)"
  fi
}

scenario_9() {   # замок конвейера занят -- версия НЕ ИЗМЕРЕНА, а не зелена
  local lock holder out rc
  lock="${TMPDIR:-/tmp}/claude-patch-all.$(id -u).lock"
  perl -e 'use Fcntl ":flock"; open(my $fh, ">>", $ARGV[0]) or die $!;
           flock($fh, LOCK_EX) or die $!; sleep 30;' "$lock" &
  holder=$!
  sleep 1
  out=$(SWEEP_LOCK_BUDGET=0 run_sweep "$K" "$C/corpus" "$C/versions.txt" 900); rc=$?
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  if [[ $rc -eq 0 ]]; then
    bad "9 занятый замок конвейера: код возврата 0"; return
  fi
  if [[ "$out" != *"НЕ ИЗМЕРЕНО(замок"* || "$out" != *"НЕПОЛНЫЙ"* ]]; then
    bad "9 занятый замок конвейера: нет пометки НЕ ИЗМЕРЕНО или хвоста НЕПОЛНЫЙ"
    return
  fi
  if ! grep -q 'lsof' "$S/log/sweep-900.lock.log" 2>/dev/null; then
    bad "9 занятый замок конвейера: держатель не записан"
    return
  fi
  ok "9 занятый замок конвейера -- НЕ ИЗМЕРЕНО, держатель записан, код ненулевой"
}

scenario_10() {   # наполнитель: байты на диске не сходятся с пином
  printf 'подменённые байты\n' > "$C/corpus/0.0.901.pristine"
  local out rc
  out=$(run_fetch "$K" "$C/corpus" "$C/versions.txt"); rc=$?
  printf 'образ девятьсот один\n' > "$C/corpus/0.0.901.pristine"
  expect_refusal "10 наполнитель: диск против пина -- отказ" "на диске не сходится с пином" "$out" $rc
}

scenario_11() {   # наполнитель НЕ пинит то, что лежит на диске
  cp "$C/versions.txt" "$C/versions.diskpin.txt"
  sed -i.bak 's/^901 0.0.901 .*/901 0.0.901 -/' "$C/versions.diskpin.txt"; rm -f "$C/versions.diskpin.txt.bak"
  local out rc pin
  out=$(run_fetch "$K" "$C/corpus" "$C/versions.diskpin.txt"); rc=$?
  pin=$(awk '$1=="901"{print $3}' "$C/versions.diskpin.txt")
  if [[ "$pin" != "-" ]]; then
    bad "11 наполнитель записал пин по байтам диска (стало «${pin}»)"; return
  fi
  if [[ $rc -eq 0 ]]; then
    bad "11 наполнитель не отказал, хотя реестр не подтвердил файл"; return
  fi
  ok "11 лежащий образ без пина не становится эталоном без реестра"
}

scenario_12() {   # обход списка не обрывается на первой версии
  # Регрессия: пин писался ПРЯМО В ЦИКЛЕ, в файл, который цикл читал по
  # открытому дескриптору. Первая запись усекала файл, и хвост списка молча
  # не обходился. Обе версии обязаны появиться в выводе.
  rm -f "$C/corpus/0.0.900.pristine" "$C/corpus/0.0.901.pristine"
  cp "$C/versions.txt" "$C/versions.both.txt"
  sed -i.bak -e 's/^900 0.0.900 .*/900 0.0.900 -/' -e 's/^901 0.0.901 .*/901 0.0.901 -/' \
    "$C/versions.both.txt"; rm -f "$C/versions.both.txt.bak"
  local out
  out=$(run_fetch "$K" "$C/corpus" "$C/versions.both.txt")
  printf 'образ девятьсот\n'      > "$C/corpus/0.0.900.pristine"
  printf 'образ девятьсот один\n' > "$C/corpus/0.0.901.pristine"
  if [[ "$out" == *"0.0.900"* && "$out" == *"0.0.901"* ]]; then
    ok "12 обход списка доходит до последней версии"
  else
    bad "12 обход списка оборвался: в выводе нет обеих версий"
  fi
}

run_all() {
  scenario_1; scenario_2; scenario_3; scenario_4; scenario_5; scenario_6
  scenario_7; scenario_8; scenario_9; scenario_10; scenario_11; scenario_12
}

# --- мутации для --self-check ------------------------------------------------
# Каждая -- ОДНА правка в копии кита, отменяющая ровно одну починенную гарантию.
mutate() {   # номер
  local n=$1 f rx
  case "$n" in
    1) f="$K/tools/sweep.sh"
       rx='s/if \(\( \$\{#MISSING\[\@\]\} \)\); then/if false; then/' ;;
    2) f="$K/tools/sweep.sh"
       rx='s/TAINTED\+=\("\$v \(пин не записан\)"\); continue/continue/' ;;
    3) f="$K/tools/sweep.sh"
       rx='s/git status --porcelain 2>\/dev\/null/git diff --quiet; echo -n/' ;;
    4) f="$K/tools/sweep.sh"
       rx='s/note=" НЕ ИЗМЕРЕНО\(замок/note=" измерено(замок/' ;;
    5) f="$K/tools/fetch-corpus.sh"
       # Доллары ПРАВОЙ части экранируются: неэкранированные $version и $got --
       # это переменные perl, а не шелла. Мутация применялась, но подставляла
       # пустые строки: наполнитель падал на пустом пине, сценарий оставался
       # зелёным, и беззубость выглядела как исправность.
       rx='s/(\n\s*)echo "== \$version лежит без пина[^\n]*\n/$1NEW_PINS+=("\$version" "\$got"); continue\n/' ;;
    6) f="$K/tools/sweep.sh"
       rx='s/^__rc=\$\?\n/__rc=0\n/m' ;;
    *) return 1 ;;
  esac
  [[ -f "$f" ]] || return 1
  local before after
  before=$(cat "$f")
  perl -0pi -e "$rx" "$f" || return 1
  after=$(cat "$f")
  # Правка, ничего не изменившая, «применяется» молча: perl не жалуется на
  # несовпавший шаблон. Такая мутация объявляет сценарий беззубым по ложной
  # причине -- поэтому применение доказывается сравнением, а не кодом возврата.
  [[ "$after" != "$before" ]]
}

# Каталог состояния свипа выводится ровно там же, где его выводит
# run_sweep: выписанный вторым местом, он разошёлся, и сценарии замков
# держали чужой файл -- пройти они не могли в принципе. Заводятся
# ВМЕСТЕ: режим мутаций пересобирает окружение для каждой мутации.
use_corpus() { C="$1"; S="$C/corpus/state"; }

MUT_SCENARIO=(x 2 4 8 9 11 7)   # мутация N краснит сценарий MUT_SCENARIO[N]

self_check() {
  local n reddened=0
  for n in $(seq 1 $EXPECTED_MUTATIONS); do
    local kdir cdir before_failed
    kdir=$(mktemp -d "$ROOT/kit.XXXXXX"); cdir=$(mktemp -d "$ROOT/corp.XXXXXX")
    mk_kit "$kdir"; mk_corpus "$cdir"
    K="$kdir"; use_corpus "$cdir"
    if ! mutate "$n"; then say "  ПРОВАЛ мутация $n не применилась"; FAILED=$((FAILED+1)); continue; fi
    before_failed=$FAILED
    "scenario_${MUT_SCENARIO[$n]}"
    if (( FAILED > before_failed )); then
      say "  ok     мутация $n покраснила сценарий ${MUT_SCENARIO[$n]}"
      FAILED=$before_failed
      reddened=$((reddened+1))
    else
      say "  ПРОВАЛ мутация $n прошла МОЛЧА (сценарий ${MUT_SCENARIO[$n]} остался зелёным)"
      FAILED=$((FAILED+1))
    fi
    rm -rf "$kdir" "$cdir"
  done
  say "corpus-tools-bench: SELF-CHECK мутаций=$EXPECTED_MUTATIONS покраснели=$reddened"
  (( reddened == EXPECTED_MUTATIONS )) || return 1
  return 0
}

if [[ "${1:-}" == "--self-check" ]]; then
  self_check || exit 1
  exit 0
fi

K=$(mktemp -d "$ROOT/kit.XXXXXX"); use_corpus "$(mktemp -d "$ROOT/corp.XXXXXX")"
mk_kit "$K"; mk_corpus "$C"
say "corpus-tools-bench: игрушечный корпус $C, копия кита $K"
run_all
say "corpus-tools-bench: ИТОГ сценариев=$RUN расхождений=$FAILED"
if (( RUN != EXPECTED_SCENARIOS )); then
  say "corpus-tools-bench: ОТКАЗ -- исполнено $RUN сценариев из $EXPECTED_SCENARIOS"
  exit 1
fi
(( FAILED == 0 )) || exit 1
