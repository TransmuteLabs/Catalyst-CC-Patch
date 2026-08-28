#!/usr/bin/env bash
# Стенд корпусных инструментов: tools/sweep.sh, tools/fetch-corpus.sh и
# tools/corpus-list.py (общий дом формата списка).
#
# Зачем. Эти скрипты -- фундамент измерительной базы: свип решает, что и на чём
# мерить, наполнитель решает, какие байты считать эталонными, разбор списка
# решает, что вообще считается версией. Их гарантии держались на разовых ручных
# проверках, то есть на памяти человека; следующая правка снимала бы их
# беззвучно. Здесь они закреплены.
#
# Двери, которые стенд проверяет, срабатывают ДО первой сборки, поэтому корпус
# игрушечный (файлы в десятки байт), а вместо конвейера в копию кита кладётся
# ЗАГЛУШКА -- она печатает те же маркеры, по которым свип выносит вердикт, и
# позволяет задать любой их набор. Весь прогон занимает секунды и не трогает ни
# боевой корпус, ни боевой замок конвейера: дом корпуса, список версий,
# рабочий корень и путь замка берутся из CORPUS_DIR, CORPUS_LIST,
# SWEEP_STATE_DIR и CLAUDE_PATCH_LOCK.
#
# Сеть трогается в одном месте: сценарии наполнителя спрашивают реестр о
# заведомо несуществующей версии и получают отказ. При мёртвой сети они
# проходят так же -- проверено прогоном через закрытый порт как прокси.
#
# Два режима:
#   bash tools/corpus-tools-bench.sh              -- прогон сценариев
#   bash tools/corpus-tools-bench.sh --self-check -- каждая мутация обязана
#                                                    покраснить свой сценарий
#                                                    И НАЗВАННОЙ ПРИЧИНОЙ
# Второй режим -- ответ на вопрос «а стенд вообще может упасть?». Беззубый
# стенд неотличим от рабочего, пока не назовёшь мутацию, которая его краснит.
# Мало и того: сценарий, покрасневший по ПОСТОРОННЕЙ причине (отказ соседней
# двери, упавший инструмент), доказывает чужое правило, а выглядит как зуб.
# Поэтому у каждой мутации записан след, который она обязана оставить в выводе.
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
EXPECTED_SCENARIOS=45
EXPECTED_MUTATIONS=38

# Предусловие 1: параллельный прогон СТЕНДА.
#
# Заглушка конвейера называется claude-patch-all.sh -- иначе свип её не
# запустит. Значит, второй прогон стенда виден первому как «идёт настоящий
# прогон»: предусловие ниже объявило бы чужую заглушку боевой сборкой и
# отказало по неверно названной причине (а свипы внутри сценариев -- своим
# стражем выживших). Стенды поэтому выстраиваются в очередь на своём замке, и
# ожидание называется своим именем. Замок берётся ДО предусловия: наоборот
# порядок не помогает -- заглушки предыдущего прогона живы, пока он идёт.
__blk="${CORPUS_BENCH_LOCK:-${TMPDIR:-/tmp}/corpus-tools-bench.$(id -u).lock}"
__budget="${CORPUS_BENCH_LOCK_BUDGET:-300}"
exec 9>"$__blk" || { echo "corpus-tools-bench: ОТКАЗ -- не открыть замок $__blk" >&2; exit 2; }
BLK_BUDGET="$__budget" perl -e '
  use Fcntl ":flock";
  open(my $fh, ">&=9") or exit 2;
  $SIG{ALRM} = sub { exit 1 };
  alarm($ENV{BLK_BUDGET} || 300);
  flock($fh, LOCK_EX) or exit 2;
  alarm(0); exit 0;'
__blk_rc=$?
if (( __blk_rc != 0 )); then
  if (( __blk_rc == 1 )); then
    echo "corpus-tools-bench: ОТКАЗ -- другой прогон стенда держит замок $__blk" >&2
    echo "  дольше ${__budget} c. Параллельно стенды не гоняются: заглушка второго" >&2
    echo "  прогона зовётся claude-patch-all.sh и выглядела бы боевой сборкой." >&2
  else
    echo "corpus-tools-bench: ОТКАЗ -- не взять замок стенда (perl rc=$__blk_rc)" >&2
  fi
  exit 2
fi

# Зонд замка: взять очередь и выйти. Нужен сценарию, который проверяет,
# что второй прогон ЖДЁТ и называет причину: запускать вложенным весь стенд
# нельзя -- он дошёл бы до того же сценария и запустил себя снова.
if [[ "${1:-}" == "--lock-probe" ]]; then
  echo "corpus-tools-bench: замок стенда взят"
  exit 0
fi

# Предусловие 2: живой настоящий прогон.
#
# Свип отказывается стартовать, пока жив чужой claude-patch-all.sh или пишущая
# стадия tweakcc (обе -- и `--apply`, и `adhoc-patch`: вторую страж не видел, а
# пишет она в тот же образ) -- это ГЛОБАЛЬНЫЙ страж общего состояния, и подменять его
# ради стенда нельзя. Но тогда все сценарии свипа получают этот отказ вместо
# своего, и стенд краснеет по причине, не имеющей отношения к его предмету.
# Поэтому условие называется прямо и один раз, отдельным кодом возврата.
__snap=$(ps -eo pid,args)
__alive=$(printf '%s\n' "$__snap" | awk '
  { for (i = 2; i <= NF && i <= 8; i++)
      if ($i ~ /claude-patch-all\.sh$/) { print $1; next } }
  /catalyst-tweakcc.*index\.mjs.*(--apply|adhoc-patch)/ { print $1 }' || true)
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
# След последнего сценария: по нему --self-check требует от мутации ЕЁ причину.
LAST_EVID=""

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
  # Платформа называется и здесь: разбор списка её ТРЕБУЕТ, и игрушечный
  # список без неё проверял бы дверь платформы, а не свой предмет.
  local plat
  plat=$(cd "$KIT" && python3 -c 'import claude_patch; print(claude_patch.npm_platform_pkg())')
  { echo "# игрушечный список стенда"
    echo "# platform: $plat"
    echo "900 0.0.900 $h900"
    echo "901 0.0.901 $h901"
  } > "$dir/versions.txt"
  # Производные списки заводятся один раз, рядом с основным.
  grep -v '^# platform:' "$dir/versions.txt" > "$dir/versions.noplat.txt"
  { echo "# platform: $plat"
    echo "900 0.0.900 $h900"
    echo "900b 0.0.900 $h900"
  } > "$dir/versions.dup.txt"
  { echo "# platform: $plat"
    echo "900 0.0.900 $h900 лишнее"
  } > "$dir/versions.extra.txt"
  { echo "# platform: $plat"
    echo "900 0.0.900 $(printf '%s' "$h900" | tr 'a-f' 'A-F')"
  } > "$dir/versions.upper.txt"
  { echo "# platform: @anthropic-ai/claude-code-и-не-эта-машина"
    echo "900 0.0.900 $h900"
  } > "$dir/versions.foreign.txt"
  # Дубль МЕТКИ при РАЗНЫХ версиях: дубль версии ловит соседняя дверь, и список
  # с обоими совпадениями доказывал бы её, а не эту.
  { echo "# platform: $plat"
    echo "900 0.0.900 $h900"
    echo "900 0.0.901 $h901"
  } > "$dir/versions.duplabel.txt"
  # Пин из 63 знаков -- не «-» и не 64 знака.
  { echo "# platform: $plat"
    echo "900 0.0.900 ${h900:0:63}"
  } > "$dir/versions.badpin.txt"
  # Версия с буквой: имя файла из неё считалось бы молча.
  { echo "# platform: $plat"
    echo "900 0.0.900 $h900"
    echo "90x 0.0.90x $h901"
  } > "$dir/versions.badver.txt"
}

# Копия кита под мутации: сценарии всегда гоняют скрипты ИЗ НЕЁ, поэтому режим
# мутаций отличается от обычного ровно одной правкой в копии.
mk_kit() {   # каталог-назначение
  local dir=$1
  mkdir -p "$dir"
  cp -R "$KIT"/. "$dir"/
  # Конвейер игрушечного кита -- ЗАГЛУШКА.
  #
  # Двери, которые проверяет стенд, срабатывают ДО первой сборки, но мутации,
  # эти двери отключающие, пускали свип дальше -- в НАСТОЯЩИЙ конвейер: он брал
  # боевой замок, лез в сеть за распаковщиком и упирался в игрушечную цель.
  # Безопасность держалась на его раннем отказе, который стенд не пинил.
  #
  # Заглушка печатает РОВНО те маркеры, по которым свип считает поля вердикта,
  # и умеет убрать любой из них (STUB_TWEAK) или вернуть любой код (STUB_RC).
  # Так каждое слагаемое вердикта получает свой сценарий и свою мутацию.
  cat > "$dir/claude-patch-all.sh" <<'STUB'
#!/usr/bin/env bash
# Заглушка конвейера для tools/corpus-tools-bench.sh. Печатает маркеры, по
# которым свип считает поля вердикта. STUB_TWEAK убирает один маркер (или
# добавляет [FAIL]/NUL), STUB_RC задаёт код возврата, STUB_TAMPER портит
# названный файл -- так проверяется сверка КОПИИ, сделанной после сверки пинов.
set -u
tweak="${STUB_TWEAK:-none}"
unless() { [[ "$tweak" == "$1" ]] || printf '%s\n' "$2"; }
[[ -z "${STUB_TAMPER:-}" ]] || printf 'подменённые байты\n' > "$STUB_TAMPER"
unless notw    'Customizations applied successfully'
unless notw    '    ✓ site'
unless noours  'Script patch applied'
unless nook    '  [OK] stub check'
[[ "$tweak" != fail ]] || printf '  [FAIL] stub check\n'
unless nosmoke 'Version: 0.0.0 (Claude Code)'
unless noiface 'Interface: stub'
unless nobench 'Probes: 1 scenarios behaved as specified'
[[ "$tweak" != nul ]] || printf 'второй писатель\000\n'
exit "${STUB_RC:-0}"
STUB
  chmod +x "$dir/claude-patch-all.sh"
}

# --- сценарии ----------------------------------------------------------------
# Каждый: подготовить состояние, запустить, потребовать код возврата и текст.

# Свой рабочий корень: иначе стенд бьётся о замок ЖИВОГО прогона и пишет в его
# сводку. Каталог создаётся рядом с игрушечным корпусом и уходит вместе с ним.
run_sweep() {   # kit, corpus-dir, list, аргументы...
  local kit=$1 cdir=$2 list=$3; shift 3
  # Замок конвейера -- СВОЙ: сценарий занятого замка прежде держал боевой файл,
  # и законный прогон оператора в это окно получал FATAL от стенда.
  CORPUS_DIR="$cdir" CORPUS_LIST="$list" SWEEP_STATE_DIR="$cdir/state" \
    CLAUDE_PATCH_LOCK="$PLOCK" \
    STUB_TWEAK="${STUB_TWEAK:-none}" STUB_RC="${STUB_RC:-0}" \
    STUB_TAMPER="${STUB_TAMPER:-}" \
    bash "$kit/tools/sweep.sh" "$@" 2>&1 9>&-
}

run_fetch() {   # kit, corpus-dir, list
  local kit=$1 cdir=$2 list=$3
  CORPUS_DIR="$cdir" CORPUS_LIST="$list" bash "$kit/tools/fetch-corpus.sh" 2>&1 9>&-
}

expect_refusal() {   # имя, ожидаемая подстрока, вывод, код
  local name=$1 want=$2 out=$3 rc=$4
  LAST_EVID="rc=$rc :: $out"
  if [[ $rc -eq 0 ]]; then
    bad "$name: код возврата 0, ждали отказ"; return
  fi
  if [[ "$out" != *"$want"* ]]; then
    bad "$name: в выводе нет «${want}»; было: $(printf '%s' "$out" | head -2 | tr '\n' ' ')"
    return
  fi
  ok "$name"
}

# Красная строка вердикта: прогон обязан назвать ИМЕННО эту причину и вернуть
# ненулевой код. Заглушка задаёт лог, сценарий -- ожидаемое слагаемое.
expect_red() {   # имя, режим заглушки, ожидаемая причина, [код заглушки]
  local name=$1 tweak=$2 want=$3 stub_rc=${4:-0} out rc
  out=$(STUB_TWEAK="$tweak" STUB_RC="$stub_rc" \
        run_sweep "$K" "$C/corpus" "$C/versions.txt" 900); rc=$?
  LAST_EVID="rc=$rc :: $out"
  if (( rc == 0 )); then
    bad "$name: код возврата 0 -- вердикт принял такой лог"; return
  fi
  if [[ "$out" != *"КРАСНАЯ: "*"$want"* ]]; then
    bad "$name: в вердикте нет причины «$want»; было: $(printf '%s' "$out" | grep -a 'SWEEP 900' | head -1)"
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
  { echo "# только комментарий"
    grep '^# platform:' "$C/versions.txt"
  } > "$C/versions.empty.txt"
  local out rc
  out=$(run_sweep "$K" "$C/corpus" "$C/versions.empty.txt"); rc=$?
  expect_refusal "5 пустой список -- отказ" "нет ни одной версии" "$out" $rc
}

scenario_6() {   # списка нет
  local out rc
  out=$(run_sweep "$K" "$C/corpus" "$C/нет-такого.txt"); rc=$?
  expect_refusal "6 нет списка версий -- отказ" "нет списка версий" "$out" $rc
}

scenario_7() {   # замок свипа занят
  # Держателям закрывается дескриптор 9 -- на нём висит замок САМОГО стенда.
  # Держатель, переживший стенд (прерывание между запуском и `kill`), держал бы
  # вместе с проверяемым замком ещё и замок стенда, и следующий прогон ждал бы
  # призрака: ровно тот класс, из-за которого замок конвейера закрывают детям.
  local holder out rc
  mkdir -p "$S"
  perl -e 'use Fcntl ":flock"; open(my $fh, ">>", $ARGV[0]) or die $!;
           flock($fh, LOCK_EX) or die $!; sleep 20;' "$S/sweep.lock" 9>&- &
  holder=$!
  sleep 1
  out=$(run_sweep "$K" "$C/corpus" "$C/versions.txt" 900); rc=$?
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  expect_refusal "7 замок свипа занят -- отказ с именем причины" "другой свип уже идёт" "$out" $rc
}

scenario_8() {   # метка происхождения видит неотслеживаемое
  # Проверяется ФУНКЦИЯ из самого свипа, вырезанная по якорю, а не переписанное
  # здесь выражение: копия разошлась бы с оригиналом молча. Первая редакция
  # вырезала ОДНУ СТРОКУ и держала имя переменной результата у себя -- правка,
  # свернувшая те же две строки в функцию с локальным именем, сделала сценарий
  # вечно красным, хотя проверяемое свойство не менялось.
  local repo fn out
  fn=$(awk '/^kit_state\(\) \{/{f=1} f{print} f && /^\}/{exit}' "$K/tools/sweep.sh")
  # Проверка вырезки идёт по имени ВХОДА функции, а не по её содержимому:
  # опора на конкретное выражение внутри делала мутацию этого выражения
  # неотличимой от «якорь не найден», то есть съедала собственный зуб.
  if [[ -z "$fn" || "$fn" != *"SRC_KIT"* ]]; then
    LAST_EVID="ЯКОРЬ_НЕ_НАЙДЕН"
    bad "8 метка происхождения: kit_state в sweep.sh не вырезан по якорю"; return
  fi
  repo=$(mktemp -d "$ROOT/gitrepo.XXXXXX")
  ( cd "$repo" && git init -q . && echo a > a.txt && git add a.txt \
      && git -c user.email=b@b -c user.name=b commit -qm init ) >/dev/null 2>&1
  echo untracked > "$repo/b.txt"
  out=$(SRC_KIT="$repo" bash -c "$fn
kit_state")
  if [[ "$out" == *"+dirty"* ]]; then
    LAST_EVID="метка=[$out]"
    ok "8 метка происхождения видит неотслеживаемый файл"
  else
    LAST_EVID="БЕЗ_ПОМЕТКИ_ГРЯЗИ метка=[$out]"
    bad "8 метка происхождения: неотслеживаемый файл не сделал дерево грязным (метка «${out}»)"
  fi
}

scenario_9() {   # конвейер вернул 3 -- версия НЕ ИЗМЕРЕНА, а не зелена
  # Держатель настоящий: свип обязан НАЗВАТЬ его в момент отказа, и проверяется
  # именно это -- pid держателя в записи lsof, а не наличие слова «lsof».
  local holder out rc
  perl -e 'use Fcntl ":flock"; open(my $fh, ">>", $ARGV[0]) or die $!;
           flock($fh, LOCK_EX) or die $!; sleep 30;' "$PLOCK" 9>&- &
  holder=$!
  sleep 1
  out=$(SWEEP_LOCK_BUDGET=0 STUB_RC=3 \
        run_sweep "$K" "$C/corpus" "$C/versions.txt" 900); rc=$?
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  LAST_EVID="rc=$rc :: $out"
  if [[ $rc -eq 0 ]]; then
    bad "9 конвейер вернул 3: код возврата свипа 0"; return
  fi
  if [[ "$out" != *"НЕ ИЗМЕРЕНО(замок"* || "$out" != *"НЕПОЛНЫЙ"* ]]; then
    bad "9 конвейер вернул 3: нет пометки НЕ ИЗМЕРЕНО или хвоста НЕПОЛНЫЙ"
    return
  fi
  if ! grep -q "[^0-9]$holder[^0-9]" "$S/log/sweep-900.lock.log" 2>/dev/null; then
    bad "9 конвейер вернул 3: держатель замка (pid $holder) не записан"
    return
  fi
  ok "9 конвейер вернул 3 -- НЕ ИЗМЕРЕНО, держатель назван, код ненулевой"
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
  LAST_EVID="pin=[$pin] rc=$rc :: $out"
  if [[ "$pin" != "-" ]]; then
    LAST_EVID="ПИН_ЗАПИСАН_С_ДИСКА pin=[$pin]"
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
  LAST_EVID="$out"
  if [[ "$out" == *"0.0.900"* && "$out" == *"0.0.901"* ]]; then
    ok "12 обход списка доходит до последней версии"
  else
    bad "12 обход списка оборвался: в выводе нет обеих версий"
  fi
}

scenario_13() {   # список не называет платформу
  local out rc
  out=$(run_sweep "$K" "$C/corpus" "$C/versions.noplat.txt" 900); rc=$?
  expect_refusal "13 платформа не названа -- отказ" "не названа платформа" "$out" $rc
}

scenario_14() {   # одна версия под двумя метками
  local out rc
  out=$(run_sweep "$K" "$C/corpus" "$C/versions.dup.txt"); rc=$?
  expect_refusal "14 дубль версии -- отказ" "уже была в строке" "$out" $rc
}

scenario_15() {   # лишнее поле в строке
  local out rc
  out=$(run_sweep "$K" "$C/corpus" "$C/versions.extra.txt" 900); rc=$?
  expect_refusal "15 лишнее поле -- отказ" "а формат -- ровно три" "$out" $rc
}

scenario_16() {   # пин в верхнем регистре -- ТОТ ЖЕ хеш (позитивный контроль)
  local out rc
  out=$(run_sweep "$K" "$C/corpus" "$C/versions.upper.txt" 900); rc=$?
  LAST_EVID="rc=$rc :: $out"
  if (( rc != 0 )) || [[ "$out" != *"SWEEP DONE"* ]]; then
    bad "16 пин в верхнем регистре объявлен подменой (код $rc)"
  else
    ok "16 пин в верхнем регистре -- тот же хеш, прогон идёт"
  fi
}

scenario_17() {   # образ не прочитать -- причина называется своя
  if [[ "$(id -u)" == "0" ]]; then
    LAST_EVID="под root"
    bad "17 нечитаемый образ: стенд идёт под root, права ничего не запрещают"; return
  fi
  chmod 000 "$C/corpus/0.0.901.pristine"
  local out rc
  out=$(run_sweep "$K" "$C/corpus" "$C/versions.txt" 901); rc=$?
  chmod 644 "$C/corpus/0.0.901.pristine"
  expect_refusal "17 нечитаемый образ -- «не прочитать», а не подмена" "не прочитать $C/corpus/0.0.901.pristine" "$out" $rc
}

scenario_18() {   # копию не создать
  mkdir -p "$S/bin"; rm -f "$S/bin/900.wave.bin"; chmod 500 "$S/bin"
  local out rc
  out=$(run_sweep "$K" "$C/corpus" "$C/versions.txt" 900); rc=$?
  chmod 700 "$S/bin"
  LAST_EVID="rc=$rc :: $out"
  if (( rc == 0 )); then
    bad "18 копию не создать: код возврата 0"; return
  fi
  if [[ "$out" != *"КРАСНАЯ -- не скопировать"* ]]; then
    bad "18 копию не создать: в выводе нет «КРАСНАЯ -- не скопировать»"; return
  fi
  ok "18 копию не создать -- КРАСНАЯ, а не измерение"
}

scenario_19() {   # копию не прочитать
  rm -rf "$S/bin/900.wave.bin"
  mkdir -p "$S/bin/900.wave.bin"
  local out rc
  out=$(run_sweep "$K" "$C/corpus" "$C/versions.txt" 900); rc=$?
  rm -rf "$S/bin/900.wave.bin"
  LAST_EVID="rc=$rc :: $out"
  if (( rc == 0 )); then
    bad "19 копию не прочитать: код возврата 0"; return
  fi
  if [[ "$out" != *"КРАСНАЯ -- не прочитать копию"* ]]; then
    bad "19 копию не прочитать: в выводе нет «КРАСНАЯ -- не прочитать копию»"; return
  fi
  ok "19 копию не прочитать -- КРАСНАЯ, а не измерение"
}

scenario_20() {   # исходник подменён ПОСЛЕ общей сверки пинов
  # Пин доказывал ИСХОДНИК, а конвейер получает КОПИЮ, и между этими двумя
  # событиями проходят целые сборки. Заглушка портит образ следующей версии
  # прямо во время прогона первой -- ровно то окно, которое сверка копии и
  # закрывает.
  local out rc
  out=$(STUB_TAMPER="$C/corpus/0.0.901.pristine" \
        run_sweep "$K" "$C/corpus" "$C/versions.txt" 900 901); rc=$?
  printf 'образ девятьсот один\n' > "$C/corpus/0.0.901.pristine"
  LAST_EVID="rc=$rc :: $out"
  if (( rc == 0 )); then
    bad "20 подмена после сверки: код возврата 0"; return
  fi
  if [[ "$out" != *"КРАСНАЯ -- копия не сходится с пином"* ]]; then
    bad "20 подмена после сверки: копия не сверена с пином"; return
  fi
  ok "20 подмена исходника после сверки -- КРАСНАЯ на копии"
}

scenario_21() {   # позитивный контроль вердикта: чистый лог проходит
  # Без него любая мутация, делающая свип КРАСНЫМ всегда, выглядела бы зубом:
  # девять сценариев ниже (docnum:subset) требуют красноты, и ни один не
  # заметил бы, что зелёным не бывает вообще ничего.
  local out rc
  out=$(run_sweep "$K" "$C/corpus" "$C/versions.txt" 900); rc=$?
  LAST_EVID="rc=$rc :: $out"
  if (( rc != 0 )) || [[ "$out" != *"SWEEP DONE"* ]]; then
    bad "21 чистый лог заглушки объявлен красным (код $rc)"
  else
    ok "21 чистый лог -- SWEEP DONE и код 0"
  fi
}

scenario_22() { expect_red "22 конвейер вернул не 0 -- КРАСНАЯ" none "конвейер вернул 1" 1; }
scenario_23() { expect_red "23 NUL в логе -- КРАСНАЯ" nul "лог смешан с чужим потоком"; }
scenario_24() { expect_red "24 упавшая проверка -- КРАСНАЯ" fail "проверок упало 1"; }
scenario_25() { expect_red "25 ни одной прошедшей проверки -- КРАСНАЯ" nook "ни одной прошедшей проверки"; }
scenario_26() { expect_red "26 нет нашего применения -- КРАСНАЯ" noours "наших применений 0"; }
scenario_27() { expect_red "27 нет прогона tweakcc -- КРАСНАЯ" notw "прогонов tweakcc 0"; }
scenario_28() { expect_red "28 дым не подтверждён -- КРАСНАЯ" nosmoke "дым не подтверждён"; }
scenario_29() { expect_red "29 интерфейс не подтверждён -- КРАСНАЯ" noiface "интерфейс не подтверждён"; }
scenario_30() { expect_red "30 стенд зондов не подтверждён -- КРАСНАЯ" nobench "стенд зондов не подтверждён"; }

scenario_31() {   # список набран для ЧУЖОЙ платформы
  # Пин платформозависим: пакеты реестра для разных пар ОС+архитектура разные,
  # и корпус с другой машины отвергался бы поштучно с текстом про подмену
  # образа -- то есть причина называлась бы неверно, а искать шли бы не там.
  local out rc
  out=$(run_sweep "$K" "$C/corpus" "$C/versions.foreign.txt" 900); rc=$?
  expect_refusal "31 чужая платформа -- отказ своей причиной" "список набран для платформы" "$out" $rc
}

scenario_32() {   # разбор вернул пусто -- отказ НАЗЫВАЕТ причину
  # Дом формата -- corpus-list.py, и он сам отвергает список без версий
  # (сценарий 5). Но у свипа стоит СВОЙ поперечный assert на случай, если
  # разбор когда-нибудь вернёт пустоту молча: без него прогон уходит в
  # `"${SRC[@]}"` при пустом массиве и падает именем внутренней переменной,
  # а на bash 4.4+ печатал бы бодрое «все 0 версий измерены». Проверить его
  # можно только подменив разбор -- потому подмена и делается здесь, в копии
  # кита, и снимается сразу.
  local out rc saved
  saved=$(cat "$K/tools/corpus-list.py")
  printf '#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n' > "$K/tools/corpus-list.py"
  out=$(run_sweep "$K" "$C/corpus" "$C/versions.txt" 900); rc=$?
  printf '%s' "$saved" > "$K/tools/corpus-list.py"
  expect_refusal "32 разбор вернул пусто -- отказ с именем причины" "список версий пуст" "$out" $rc
}

scenario_33() {   # замок стенда занят -- второй прогон ЖДЁТ и называет причину
  # Заглушка конвейера зовётся claude-patch-all.sh, поэтому два прогона стенда
  # видят заглушки друг друга как боевую сборку. Очередь на своём замке
  # называет ожидание своим именем; зонд `--lock-probe` берёт ту же очередь и
  # выходит, не запуская сценарии.
  local holder out rc lock
  lock="$C/bench.lock"
  perl -e 'use Fcntl ":flock"; open(my $fh, ">>", $ARGV[0]) or die $!;
           flock($fh, LOCK_EX) or die $!; sleep 30;' "$lock" 9>&- &
  holder=$!
  sleep 1
  out=$(CORPUS_BENCH_LOCK="$lock" CORPUS_BENCH_LOCK_BUDGET=1 \
        bash "$K/tools/corpus-tools-bench.sh" --lock-probe 2>&1); rc=$?
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  LAST_EVID="rc=$rc :: $out"
  if (( rc == 0 )); then
    bad "33 замок стенда занят: второй прогон не стал ждать (код 0)"; return
  fi
  if [[ "$out" != *"другой прогон стенда держит замок"* ]]; then
    bad "33 замок стенда занят: причина не названа; было: $(printf '%s' "$out" | head -1)"
    return
  fi
  ok "33 замок стенда занят -- второй прогон ждёт и называет причину"
}

scenario_34() {   # ранний отказ обесценивает сводку
  # Сводка -- единственный файл, который читают ПОСЛЕ прогона. Обрезалась она
  # после всех дверей отказа, и отказавший прогон оставлял на диске зелёный
  # вердикт ПРОШЛОГО: читатель видел успех, которого в этом прогоне не было.
  local out rc summary
  summary="$S/log/sweep-summary.txt"
  out=$(run_sweep "$K" "$C/corpus" "$C/versions.txt" 900); rc=$?
  if (( rc != 0 )) || ! grep -aq 'SWEEP DONE' "$summary" 2>/dev/null; then
    LAST_EVID="подготовка: rc=$rc :: $out"
    bad "34 обесценивание сводки: зелёный прогон не оставил вердикта в сводке"; return
  fi
  out=$(run_sweep "$K" "$C/corpus" "$C/versions.txt" 999); rc=$?
  LAST_EVID="rc=$rc :: сводка после отказа :: $(cat "$summary" 2>&1)"
  if (( rc == 0 )); then
    bad "34 обесценивание сводки: неизвестная версия не стала отказом"; return
  fi
  if grep -aq 'SWEEP DONE' "$summary" 2>/dev/null; then
    bad "34 обесценивание сводки: после отказа остался вердикт прошлого прогона"; return
  fi
  if ! grep -aq 'ПРОГОН НАЧАТ' "$summary" 2>/dev/null; then
    bad "34 обесценивание сводки: нет отметки начатого прогона"; return
  fi
  ok "34 ранний отказ обесценивает сводку"
}

scenario_35() {   # одна версия названа дважды в аргументах
  local out rc
  out=$(run_sweep "$K" "$C/corpus" "$C/versions.txt" 900 900); rc=$?
  expect_refusal "35 повтор версии в аргументах -- отказ" "названа дважды" "$out" $rc
}

scenario_36() {   # наполнитель: лежащий образ не прочитать
  # Тот же класс, что у свипа в сценарии 17: пустой хеш против пина читался как
  # подмена, и искать шли подменённые байты вместо прав на файл.
  local out rc
  chmod 000 "$C/corpus/0.0.900.pristine"
  out=$(run_fetch "$K" "$C/corpus" "$C/versions.txt"); rc=$?
  chmod 644 "$C/corpus/0.0.900.pristine"
  expect_refusal "36 наполнитель: нечитаемый образ -- не подмена" \
                 "лежит, но не прочитать" "$out" $rc
}

scenario_37() {   # имя файла корпуса -- ОДИН дом
  # Стенд держит имена ЛИТЕРАЛАМИ намеренно: выводи он их той же функцией, что
  # и инструменты, смена суффикса поехала бы в обе стороны разом и осталась бы
  # невидимой. Поэтому исключены ровно два файла -- дом и сам стенд.
  local stray
  stray=$(grep -rl '\.pristine' --include='*.sh' --include='*.py' \
            "$K/claude-patch-all.sh" "$K/tools" 2>/dev/null \
          | grep -v 'corpus-file-name\.sh$' | grep -v 'corpus-tools-bench\.sh$' \
          | sed "s|^$K/||" | tr '\n' ' ')
  LAST_EVID="суффикс написан вне общего дома: $stray"
  if [[ -n "${stray// /}" ]]; then
    bad "37 имя файла корпуса: суффикс написан ещё и в: $stray"; return
  fi
  ok "37 имя файла корпуса живёт в одном доме"
}

scenario_38() {   # форма имени замка одна во всех домах
  # Общий файл сюда не подключить: преамбулу конвейера lock-probe исполняет
  # ОТДЕЛЬНО, вырезав из файла, и подключение сделало бы её несамодостаточной.
  # Поэтому форма пинится, и это объявлено -- см. комментарий в build-path-probe.
  local homes n f bad_homes=""
  # Конвейер читается из ЖИВОГО кита: в игрушечной копии на его месте лежит
  # заглушка, и дом преамбулы там отсутствует по устройству стенда.
  homes=$(grep -rl 'claude-patch-all\.\$(id -u)\.lock' \
            "$KIT/claude-patch-all.sh" "$K/tools" 2>/dev/null | sort)
  n=$(printf '%s\n' "$homes" | grep -c .)
  for f in $homes; do
    # Ручку обязана называть ТА ЖЕ строка: слово CLAUDE_PATCH_LOCK живёт в
    # зондах ещё и внутри CLAUDE_PATCH_LOCK_HELD_BY, и проверка по файлу
    # зеленела, когда строка имени ручку уже не читала.
    grep 'claude-patch-all\.\$(id -u)\.lock' "$f" | grep -q 'CLAUDE_PATCH_LOCK' \
      || bad_homes="$bad_homes $(basename "$f")"
  done
  LAST_EVID="домов=$n без ручки:$bad_homes"
  if (( n != 4 )); then
    bad "38 форма имени замка: домов $n, а известных четыре"; return
  fi
  if [[ -n "${bad_homes// /}" ]]; then
    bad "38 форма имени замка: ручку не читают:$bad_homes"; return
  fi
  ok "38 имя замка во всех четырёх домах читает одну ручку"
}

scenario_39() {   # снимок кита убирается и на отказе
  # Снимок сносился только в успешном хвосте: отказ после копирования оставлял
  # копию кита в рабочем каталоге навсегда, и следующий прогон мерил диск,
  # засеянный предыдущими.
  local out rc leftover
  mkdir -p "$K/непрочитаемое"; chmod 000 "$K/непрочитаемое"
  out=$(run_sweep "$K" "$C/corpus" "$C/versions.txt" 900); rc=$?
  chmod 755 "$K/непрочитаемое"; rmdir "$K/непрочитаемое"
  leftover=$(ls -d "$S"/kit.* 2>/dev/null | tr '\n' ' ')
  LAST_EVID="rc=$rc :: $out :: $([[ -n "${leftover// /}" ]] && printf 'ОСТАЛСЯ_СНИМОК=%s' "$leftover")"
  if (( rc == 0 )) || [[ "$out" != *"не снять снимок кита"* ]]; then
    bad "39 уборка снимка: копирование не отказало (rc=$rc)"; return
  fi
  if [[ -n "${leftover// /}" ]]; then
    bad "39 уборка снимка: после отказа остался снимок $leftover"; return
  fi
  ok "39 снимок кита убирается и на отказе"
}

scenario_40() {   # дубль МЕТКИ в списке
  local out rc
  out=$(run_sweep "$K" "$C/corpus" "$C/versions.duplabel.txt"); rc=$?
  expect_refusal "40 дубль метки -- отказ" "уже была в строке" "$out" $rc
}

scenario_41() {   # пин не 64 шестнадцатеричных знака
  local out rc
  out=$(run_sweep "$K" "$C/corpus" "$C/versions.badpin.txt" 900); rc=$?
  expect_refusal "41 пин не по форме -- отказ" "не 64 шестнадцатеричных" "$out" $rc
}

scenario_42() {   # версия не по форме
  local out rc
  out=$(run_sweep "$K" "$C/corpus" "$C/versions.badver.txt"); rc=$?
  expect_refusal "42 версия не по форме -- отказ" "не похоже на номер версии" "$out" $rc
}

scenario_43() {   # рассинхрон таблиц мутаций -- отказ, а не сдвиг описаний
  # Пять таблиц описывают одну мутацию каждая своим полем. Короче одна -- и
  # номера разъезжаются: замена одной мутации однажды встала к образцу другой,
  # и стенд объявил зубом правило, которого не проверял. Копия укорачивается
  # намеренно, и стенд обязан ОТКАЗАТЬСЯ, а не считать.
  local probe out rc
  probe="$C/bench-short.sh"
  # Снимается последняя запись MUT_CAUSE. Якорь -- присваивание В НАЧАЛЕ
  # СТРОКИ: первая редакция искала имя таблицы где угодно и находила его в
  # ЭТОМ ЖЕ сценарии, после чего резала строку соседнего кода -- та самая
  # теневая цель, от которой мутации защищены счётом совпадений.
  python3 - "$K/tools/corpus-tools-bench.sh" "$probe" <<'SHORTEN'
import io, re, sys
src = io.open(sys.argv[1], encoding='utf-8').read()
at = re.search(r'^MUT_CAUSE=\(x', src, re.M).start()
end = src.index(')\n', at)
head = src[:end]
io.open(sys.argv[2], 'w', encoding='utf-8').write(
    head[:head.rindex('\n  ')] + '\n' + src[end:])
SHORTEN
  if ! grep -q 'MUT_CAUSE=(x' "$probe"; then
    LAST_EVID="копия не собрана"
    bad "43 рассинхрон таблиц: не удалось укоротить таблицу в копии"; return
  fi
  out=$(CORPUS_BENCH_LOCK="$C/tables.lock" CORPUS_BENCH_LOCK_BUDGET=5 \
        bash "$probe" --table-check 2>&1); rc=$?
  LAST_EVID="rc=$rc :: $out"
  if (( rc == 0 )); then
    bad "43 рассинхрон таблиц: укороченная таблица принята (код 0)"; return
  fi
  if [[ "$out" != *"а мутаций"* ]]; then
    bad "43 рассинхрон таблиц: причина не названа; было: $(printf '%s' "$out" | head -1)"
    return
  fi
  ok "43 рассинхрон таблиц мутаций -- отказ с названной причиной"
}

scenario_44() {   # копия зелёной версии убирается, копия красной остаётся
  # Копия -- сотни мегабайт на версию, и её никто не читает после прогона; у
  # красной версии она улика, поэтому исходы разные, и оба проверяются.
  local out rc green red
  out=$(run_sweep "$K" "$C/corpus" "$C/versions.txt" 900); rc=$?
  green=$([[ -e "$S/bin/900.wave.bin" ]] && echo ОСТАЛАСЬ_КОПИЯ_ЗЕЛЁНОЙ)
  out=$(STUB_RC=1 run_sweep "$K" "$C/corpus" "$C/versions.txt" 900); rc=$?
  red=$([[ -e "$S/bin/900.wave.bin" ]] && echo есть)
  LAST_EVID="зелёная: ${green:-убрана} :: красная: ${red:-СНЕСЛИ_УЛИКУ_КРАСНОЙ}"
  if [[ -n "$green" ]]; then
    bad "44 копии: после зелёной версии копия осталась"; return
  fi
  if [[ -z "$red" ]]; then
    bad "44 копии: после красной версии копия удалена -- улика потеряна"; return
  fi
  ok "44 копия зелёной версии убирается, копия красной остаётся"
}

scenario_45() {   # страж живых прогонов: сам прогон против пути в аргументах
  # Две половины в одном сценарии намеренно: страж, который не ловит ничего, и
  # страж, который ловит всё, одинаково бесполезны, и половина без своей пары
  # молча вырождается.
  local fake out rc caught missed
  fake="$C/fake"; mkdir -p "$fake"
  printf '#!/bin/sh\nsleep 30\n' > "$fake/claude-patch-all.sh"
  printf 'import time\ntime.sleep(30)\n' > "$fake/gate.py"
  chmod +x "$fake/claude-patch-all.sh"

  # (1) настоящий прогон конвейера -- страж ОБЯЗАН отказать
  bash "$fake/claude-patch-all.sh" & local runner=$!
  sleep 1
  out=$(run_sweep "$K" "$C/corpus" "$C/versions.txt" 900); rc=$?
  kill "$runner" 2>/dev/null; wait "$runner" 2>/dev/null
  caught=$([[ $rc -ne 0 && "$out" == *"живы процессы предыдущего прогона"* ]] && echo да)

  # (2) путь конвейера АРГУМЕНТОМ чужой программы -- отказа быть не должно
  python3 "$fake/gate.py" "$fake/claude-patch-all.sh" & local reader=$!
  sleep 1
  out=$(run_sweep "$K" "$C/corpus" "$C/versions.txt" 900); rc=$?
  kill "$reader" 2>/dev/null; wait "$reader" 2>/dev/null
  missed=$([[ $rc -eq 0 ]] || echo "ОТКАЗ_НА_ЧУЖОМ_АРГУМЕНТЕ: $out")

  LAST_EVID="прогон пойман: ${caught:-НЕТ} :: ${missed:-чужой аргумент пропущен}"
  if [[ -z "$caught" ]]; then
    bad "45 страж живых: настоящий прогон конвейера не пойман"; return
  fi
  if [[ -n "$missed" ]]; then
    bad "45 страж живых: отказ на пути в аргументах чужой программы"; return
  fi
  ok "45 страж живых ловит прогон и не ловит путь в чужих аргументах"
}

run_all() {
  scenario_1; scenario_2; scenario_3; scenario_4; scenario_5; scenario_6
  scenario_7; scenario_8; scenario_9; scenario_10; scenario_11; scenario_12
  scenario_13; scenario_14; scenario_15; scenario_16; scenario_17; scenario_18
  scenario_19; scenario_20; scenario_21; scenario_22; scenario_23; scenario_24
  scenario_25; scenario_26; scenario_27; scenario_28; scenario_29; scenario_30
  scenario_31; scenario_32; scenario_33; scenario_34; scenario_35; scenario_36
  scenario_37; scenario_38; scenario_39; scenario_40; scenario_41; scenario_42
  scenario_43; scenario_44; scenario_45
}

# --- мутации для --self-check ------------------------------------------------
# Каждая -- ОДНА правка в копии кита, отменяющая ровно одну починенную гарантию.
#
# Образец и замена передаются ОТДЕЛЬНЫМИ полями и попадают в perl через
# окружение, а не внутрь текста программы. Прежняя редакция вписывала их прямо
# в `s/.../.../`, и доллары замены разбирались как переменные perl: мутация
# применялась, подставляла пустые строки, инструмент падал по другой причине, а
# стенд объявлял её зубом. Ни образец, ни замена больше не проходят через
# разбор кода.
MUT_FILE=(x
  tools/sweep.sh tools/sweep.sh tools/sweep.sh tools/sweep.sh
  tools/fetch-corpus.sh tools/sweep.sh
  tools/corpus-list.py tools/corpus-list.py tools/corpus-list.py tools/corpus-list.py
  tools/sweep.sh tools/sweep.sh tools/sweep.sh tools/sweep.sh
  tools/sweep.sh tools/sweep.sh tools/sweep.sh tools/sweep.sh
  tools/sweep.sh tools/sweep.sh tools/sweep.sh tools/sweep.sh tools/sweep.sh
  tools/corpus-list.py tools/sweep.sh tools/corpus-tools-bench.sh
  tools/sweep.sh tools/sweep.sh tools/fetch-corpus.sh tools/fetch-corpus.sh
  tools/build-path-probe.sh tools/sweep.sh
  tools/corpus-list.py tools/corpus-list.py tools/corpus-list.py
  tools/corpus-tools-bench.sh tools/sweep.sh tools/sweep.sh)

MUT_PAT=(x
  'if \(\( \$\{#MISSING\[\@\]\} \)\); then'
  'TAINTED\+=\("\$v \(пин не записан\)"\); continue'
  'git status --porcelain 2>/dev/null'
  'note=" НЕ ИЗМЕРЕНО\(замок'
  'echo "== \$version лежит без пина[^\n]*'
  '__rc=\$\?'
  'if declared is None:'
  'if version in versions:'
  'parts = line\.split\(\)'
  'rows\.append\(\(label, version, pin\.lower\(\)\)\)'
  '\[\[ -n "\$out" \]\] \|\| return 1'
  'if ! cp -p "\$src" "\$STATE/bin/\$v\.wave\.bin"; then'
  'if ! copy=\$\(sha256_of "\$STATE/bin/\$v\.wave\.bin"\); then'
  'if \[\[ "\$copy" != "\$want" \]\]; then'
  '\(\( rc == 0 \)\) \|\| why\+=\("конвейер вернул \$rc"\)'
  '\[\[ "\$mixed" == "\$size" \]\] \|\| why\+=\("лог смешан с чужим потоком \(NUL\)"\)'
  '\[\[ "\$fail" == "0" \]\] \|\| why\+=\("проверок упало \$fail"\)'
  '\[\[ "\$ok" != "0" \]\] \|\| why\+=\("ни одной прошедшей проверки"\)'
  '\[\[ "\$ours" == "1" \]\] \|\| why\+=\("наших применений \$ours"\)'
  '\[\[ "\$twruns" == "1" \]\] \|\| why\+=\("прогонов tweakcc \$twruns"\)'
  '\[\[ "\$smoke" == "1" \]\] \|\| why\+=\("дым не подтверждён"\)'
  '\[\[ "\$iface" == "1" \]\] \|\| why\+=\("интерфейс не подтверждён"\)'
  '\[\[ "\$bench" == "1" \]\] \|\| why\+=\("стенд зондов не подтверждён"\)'
  'if declared != here_platform:'
  '\(\( \$\{#ALL\[\@\]\} \)\) \|\| \{ echo "SWEEP ОТКАЗ: список версий пуст: \$LIST" >&2; exit 1; \}'
  'flock\(\$fh, LOCK_EX\) or exit 2;'
  '\} > "\$STATE/log/sweep-summary\.txt"'
  'uniq -d'
  '\[\[ -n "\$out" \]\] \|\| return 1'
  'dst="\$CORPUS/\$\(corpus_file_name "\$version"\)"'
  'LOCK_FILE="\$\{CLAUDE_PATCH_LOCK:-\$\{TMPDIR:-/tmp\}'
  'rm -rf "\$\{HERE:-\}"'
  'if label in labels:'
  "if pin != '-' and not PIN\.match\(pin\):"
  'if not VERSION\.match\(version\):'
  'if \(\( len != EXPECTED_MUTATIONS \+ 1 \)\); then'
  'rm -f "\$STATE\/bin\/\$v\.wave\.bin"'
  'if \(\$i ~ \/\\\.\(py\|js\|mjs\)\$\/\) break')

MUT_REP=(x
  'if false; then'
  'continue'
  'git diff --quiet; echo -n'
  'note=" измерено(замок'
  'NEW_PINS+=("$version" "$got"); continue'
  '__rc=0'
  'if False:'
  'if False and version in versions:'
  'parts = line.split()[:3]'
  'rows.append((label, version, pin))'
  ':'
  'cp -p "$src" "$STATE/bin/$v.wave.bin"; if false; then'
  'copy=$(sha256_of "$STATE/bin/$v.wave.bin"); if false; then'
  'if false; then'
  ':' ':' ':' ':' ':' ':' ':' ':' ':'
  'if False:'
  ':'
  'exit 0;'
  '} > /dev/null'
  'uniq -u'
  ':'
  "dst=\"\$CORPUS/\$version.pristine\""
  'LOCK_FILE="${TMPDIR:-/tmp}'
  ':'
  'if False:'
  'if False:'
  'if False:'
  'if false; then'
  ':'
  'if (0) break')

# Мутация N краснит сценарий MUT_SCENARIO[N], и обязана оставить в его следе
# подстроку MUT_CAUSE[N]. Второе поле -- защита от «покраснел по чужой
# причине»: отказ соседней двери или упавший инструмент тоже делают сценарий
# красным, и без названного следа беззубость неотличима от исправности.
MUT_SCENARIO=(x 2 4 8 9 11 7 13 14 15 16 17 18 19 20 22 23 24 25 26 27 28 29 30 31 32 33
               34 35 36 37 38 39 40 41 42 43 44 45)
MUT_CAUSE=(x
  'корпус не сходится с пином'
  'копия не сходится с пином'
  'БЕЗ_ПОМЕТКИ_ГРЯЗИ'
  ' измерено(замок'
  'ПИН_ЗАПИСАН_С_ДИСКА'
  'SWEEP DONE'
  'платформы None'
  'SWEEP DONE'
  'SWEEP DONE'
  'не сходится с пином'
  ', на диске )'
  'не прочитать копию'
  'копия не сходится с пином'
  'SWEEP DONE'
  'SWEEP DONE' 'SWEEP DONE' 'SWEEP DONE' 'SWEEP DONE' 'SWEEP DONE'
  'SWEEP DONE' 'SWEEP DONE' 'SWEEP DONE' 'SWEEP DONE'
  'SWEEP DONE'
  'unbound variable'
  'замок стенда взят'
  'SWEEP DONE'
  'все 2 версий'
  ', файл )'
  'tools/fetch-corpus.sh'
  'build-path-probe.sh'
  'ОСТАЛСЯ_СНИМОК'
  'все 2 версий'
  'не сходится с пином'
  'нет пристинных образов'
  'rc=0 ::'
  'ОСТАЛАСЬ_КОПИЯ_ЗЕЛЁНОЙ'
  'ОТКАЗ_НА_ЧУЖОМ_АРГУМЕНТЕ')

# Длины пяти таблиц сверяются ДО первого прогона: рассинхрон сдвигает описания
# мутаций молча, и стенд начинает доказывать чужие правила.
check_mut_tables() {
  local name len rc=0
  for name in MUT_FILE MUT_PAT MUT_REP MUT_SCENARIO MUT_CAUSE; do
    eval "len=\${#$name[@]}"
    if (( len != EXPECTED_MUTATIONS + 1 )); then
      say "corpus-tools-bench: ОТКАЗ -- в $name записей $((len - 1)), а мутаций $EXPECTED_MUTATIONS"
      rc=1
    fi
  done
  return $rc
}

if [[ "${1:-}" == "--table-check" ]]; then
  check_mut_tables || exit 1
  say "corpus-tools-bench: таблицы мутаций согласованы ($EXPECTED_MUTATIONS)"
  exit 0
fi

mutate() {   # номер
  local n=$1 f pat rep hits before after
  f="$K/${MUT_FILE[$n]}"; pat="${MUT_PAT[$n]}"; rep="${MUT_REP[$n]}"
  [[ -f "$f" ]] || { say "  ПРОВАЛ мутация $n: нет файла $f"; return 1; }
  # Образец обязан встречаться РОВНО раз. Два совпадения -- и правится первое,
  # то есть, возможно, не то место, а мутация всё равно «применилась»: сценарий
  # покраснел бы по теневому совпадению, доказав чужое правило.
  hits=$(PAT="$pat" perl -0ne 'my $n = () = /$ENV{PAT}/g; print $n' "$f")
  if [[ "$hits" != "1" ]]; then
    say "  ПРОВАЛ мутация $n: образец встречается $hits раз в ${MUT_FILE[$n]}"
    return 1
  fi
  before=$(cat "$f")
  PAT="$pat" REP="$rep" perl -0pi -e 's/$ENV{PAT}/$ENV{REP}/' "$f" || return 1
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
use_corpus() { C="$1"; S="$C/corpus/state"; PLOCK="$C/corpus/patch.lock"; }

self_check() {
  local n reddened=0
  for n in $(seq 1 $EXPECTED_MUTATIONS); do
    local kdir cdir before_failed
    kdir=$(mktemp -d "$ROOT/kit.XXXXXX"); cdir=$(mktemp -d "$ROOT/corp.XXXXXX")
    mk_kit "$kdir"; mk_corpus "$cdir"
    K="$kdir"; use_corpus "$cdir"
    if ! mutate "$n"; then
      say "  ПРОВАЛ мутация $n не применилась"
      rm -rf "$kdir" "$cdir"; continue
    fi
    before_failed=$FAILED
    LAST_EVID=""
    "scenario_${MUT_SCENARIO[$n]}"
    if (( FAILED > before_failed )); then
      if [[ "$LAST_EVID" == *"${MUT_CAUSE[$n]}"* ]]; then
        say "  ok     мутация $n покраснила сценарий ${MUT_SCENARIO[$n]} своей причиной"
        reddened=$((reddened+1))
      else
        say "  ПРОВАЛ мутация $n покраснила сценарий ${MUT_SCENARIO[$n]} ЧУЖОЙ причиной:"
        say "         ждали след «${MUT_CAUSE[$n]}», было: $(printf '%s' "$LAST_EVID" | tr '\n' '|' | cut -c1-300)"
      fi
      FAILED=$before_failed
    else
      say "  ПРОВАЛ мутация $n прошла МОЛЧА (сценарий ${MUT_SCENARIO[$n]} остался зелёным)"
    fi
    rm -rf "$kdir" "$cdir"
  done
  say "corpus-tools-bench: SELF-CHECK мутаций=$EXPECTED_MUTATIONS покраснели=$reddened"
  (( reddened == EXPECTED_MUTATIONS )) || return 1
  return 0
}

if [[ "${1:-}" == "--self-check" ]]; then
  check_mut_tables || exit 1
  self_check || exit 1
  exit 0
fi

check_mut_tables || exit 1
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
