#!/usr/bin/env bash
# Version sweep: every pristine image through the whole pipeline.
# One line per version at the end; the full log per version stays on disk.
#
# 2026-08-27. Three guards were added after a sweep produced a green summary
# over a contaminated artifact. The previous sweep had been killed mid-run; its
# `node ... --apply` child survived the kill (killing a parent does not kill its
# descendants), kept the inherited log fd, and went on patching the SAME image
# path the restarted sweep was using. sweep-233.log ended up holding two
# tweakcc applies -- the second one AFTER our verification had already declared
# the image good -- with a 603-byte NUL hole between the interleaved streams.
#
#   * `grep -c` on a log with a NUL byte prints NOTHING and exits 1, so the
#     counts came out as EMPTY strings and the summary would have read
#     `ok= fail=`. Every count here is now `grep -a -c` and is asserted numeric.
#   * A log with a NUL byte is not evidence of anything: it is two streams.
#     Said on the summary line.
#   * Exactly one tweakcc apply and one of our applies per run. Two of either
#     means somebody else was writing to the same image.
#   * The run puts itself in its own process group, so `kill -TERM -<pgid>`
#     takes the descendants with it. The pgid is left in sweep.pgid.
#
# Последняя строка прогона -- ОДНА из двух: `SWEEP DONE ...` (все версии
# измерены, красных нет) или `SWEEP НЕПОЛНЫЙ ...` с ненулевым кодом возврата.
# Кто ждёт конца снаружи, должен искать обе: раньше `SWEEP DONE` печаталось
# всегда, чем бы прогон ни кончился.
set -u
# Все рабочие пути прогона -- под одним корнем, и корень переопределяем.
#
# Замок свипа, сводка, логи версий и копии образов лежали по фиксированным
# путям в /tmp/cc-matrix. Из-за этого стенд корпусных инструментов бился о
# ЖИВОЙ замок настоящего прогона и не мог проверить ни одной двери, пока идёт
# сборка. Одна ручка вместо трёх: боевое значение -- прежнее, стенд подставляет
# свой каталог и никому не мешает.
STATE="${SWEEP_STATE_DIR:-/tmp/cc-matrix}"
mkdir -p "$STATE/log" "$STATE/bin"
if [[ "${SWEEP_LEADER:-}" != "1" ]]; then
  # Кит запоминается ДО ре-экзека: дальше скрипт исполняется из своей копии в
  # /tmp, и dirname его пути указывал бы уже туда.
  SWEEP_KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  export SWEEP_KIT SWEEP_LEADER=1
  # Скрипт переехал из /tmp внутрь кита, а кит правится, пока прогон идёт (в
  # этом и был смысл снимка кита ниже). bash читает тело исполняемого файла по
  # СМЕЩЕНИЮ и дочитывает его на ходу, поэтому правка файла на диске рвёт
  # текущий прогон в произвольном месте. Лидер исполняет СОБСТВЕННУЮ копию,
  # так что файл в репозитории свободен всё время прогона -- ровно та свобода,
  # ради которой снимался кит.
  # Без perl нет ни своей сессии, ни setsid. Прежде `exec perl` просто не
  # находил перехватчика, оболочка выходила из `if` и работала лидером в чужой
  # группе процессов -- ровно то, что шапка объявляет невозможным, и молча.
  command -v perl >/dev/null 2>&1 || {
    echo "SWEEP ОТКАЗ: нет perl -- прогон не отделить в свою сессию" >&2; exit 1; }
  SWEEP_SELF=$(mktemp "$STATE/sweep.self.XXXXXX") || {
    echo "SWEEP ОТКАЗ: не создать копию себя" >&2; exit 1; }
  # Уборка ставится ДО первой записи в копию: неудачное копирование выходило по
  # `exit 1` раньше, чем появлялся trap ниже, и оставляло пустой файл в /tmp.
  trap 'rm -f "${SWEEP_SELF:-}"' EXIT
  cat "$0" > "$SWEEP_SELF" || { echo "SWEEP ОТКАЗ: не скопировать себя" >&2; exit 1; }
  export SWEEP_SELF
  exec perl -e 'use POSIX (); POSIX::setsid(); exec @ARGV or die $!' bash "$SWEEP_SELF" "$@"
fi
# Копия себя убирается на ЛЮБОМ выходе, а не только на успешном: дверей отказа
# у этого скрипта после сюда девять, и на каждой явный rm в хвосте не
# исполняется -- /tmp копил бы по копии на отказ.
trap 'rm -f "${SWEEP_SELF:-}"' EXIT
echo $$ > "$STATE/sweep.pgid"

# Собственный замок свипа.
#
# Страж выше ловит ЧУЖОЙ уже идущий claude-patch-all.sh, но не свип-ровесника,
# который сам ещё не дошёл до первой сборки: оба проходят стража, а дальше
# делят `sweep-summary.txt` (второй стартовавший обрезает накопленные строки
# первого), один и тот же `bin/<версия>.wave.bin` и один и тот же лог версии.
# Сборки при этом сериализует замок конвейера -- теряется не сборка, а ЗАПИСЬ
# вердикта, то есть ровно то, ради чего свип и запускают.
#
# Дескриптор закрывается у детей (`8>&-` на вызове конвейера): переживший нас
# ребёнок иначе продолжал бы держать замок свипа -- тот самый класс, из-за
# которого прогон корпуса уже терял версии.
exec 8>"$STATE/sweep.lock"
# Код возврата снимается ОТДЕЛЬНОЙ строкой, без `if !`.
#
# После `if ! cmd; then` переменная `$?` внутри ветки равна нулю: её значение --
# результат ОТРИЦАНИЯ, а не самой команды. Первая редакция читала там код perl и
# всегда печатала «не взять замок свипа (perl rc=0)» вместо «другой свип уже
# идёт» -- то есть занятый замок объявлялся поломкой инструмента.
perl -e 'use Fcntl ":flock"; open(my $fh, ">&=8") or exit 2;
         exit(flock($fh, LOCK_EX|LOCK_NB) ? 0 : 1);'
__rc=$?
if (( __rc != 0 )); then
  if (( __rc == 1 )); then
    echo "SWEEP ОТКАЗ: другой свип уже идёт (замок $STATE/sweep.lock)." >&2
    echo "  кто именно: lsof $STATE/sweep.lock" >&2
  else
    echo "SWEEP ОТКАЗ: не взять замок свипа (perl rc=$__rc)" >&2
  fi
  exit 1
fi

# A previous run's helper still alive would race us on the same image paths.
# The snapshot is taken BEFORE awk starts, so awk cannot find its own command
# line -- which carries the very patterns it searches for. A `ps | awk '/pat/'`
# pipeline matches itself, and a guard that always finds a victim is no guard.
# In `ps -eo pid,args` the script path is NOT $2 -- $2 is the interpreter
# (`bash`), the path is $3. The first form of this guard tested $2 and therefore
# could never fire: verified with a positive control, a fake
# `bash <dir>/claude-patch-all.sh` that the guard walked straight past. So the
# path is looked for across the leading fields.
snap=$(ps -eo pid,args)
alive=$(printf '%s\n' "$snap" | awk '
  { for (i = 2; i <= NF && i <= 8; i++)
      if ($i ~ /claude-patch-all\.sh$/) { print $1; next } }
  /catalyst-tweakcc.*index\.mjs.*(--apply|adhoc-patch)/ { print $1 }' || true)
if [[ -n "$alive" ]]; then
  echo "SWEEP ОТКАЗ: живы процессы предыдущего прогона: $alive" >&2
  exit 1
fi

# Дом корпуса пристинных образов.
#
# 2026-08-28. Корпус жил в ~/.local/share/claude/versions как <версия>.orig, и
# фаза «Cleaning up previous versions» самого конвейера его стёрла: она удаляет
# из этого каталога ВСЁ, кроме текущей версии и той, что исполняет живая сессия.
# То есть успешная установка новой версии уничтожала измерительную базу, на
# которой меряется следующая волна. Образы 233/240/243/245/246 так и пропали.
# У корпуса теперь свой каталог, куда очистка не заглядывает; наполняется он
# из реестра npm (tools/fetch-corpus.sh), а не копированием локальной
# установки: локальная копия может быть уже пропатченной.
# Дом корпуса и список версий переопределяемы -- этим пользуется стенд
# tools/corpus-tools-bench.sh: двери отказа надо уметь проверить на
# игрушечном корпусе, не трогая настоящий и не тратя гигабайты. Значения по
# умолчанию -- боевые, и все вызовы в доках и рецептах идут без ручек.
CORPUS="${CORPUS_DIR:-$HOME/.local/share/claude-patch/corpus}"

# Список версий -- в tools/corpus-versions.txt, общий с наполнителем корпуса.
# Рабочий корень прогона -- $STATE (см. SWEEP_STATE_DIR выше).
LIST="${CORPUS_LIST:-$SWEEP_KIT/tools/corpus-versions.txt}"
[[ -f "$LIST" ]] || { echo "SWEEP ОТКАЗ: нет списка версий $LIST" >&2; exit 1; }
# Формат списка разбирает ОДИН дом на оба инструмента: свой `while read` у
# каждого читателя разошёлся на строке без пина, на лишнем поле и на дубле
# версии под двумя метками (последний давал «все N версий измерены» там, где
# файл на диске один). Отказ разбора -- отказ свипа, до первой сборки.
PARSED=$(python3 "$SWEEP_KIT/tools/corpus-list.py" "$LIST") || {
  echo "SWEEP ОТКАЗ: список версий $LIST не проходит разбор (см. причину выше)" >&2
  exit 1; }
declare -a ALL=()
while IFS=$'\t' read -r label version pin; do
  [[ -n "${label:-}" ]] || continue
  ALL+=("$label:$version:$pin")
done <<< "$PARSED"
(( ${#ALL[@]} )) || { echo "SWEEP ОТКАЗ: список версий пуст: $LIST" >&2; exit 1; }

# Версии можно назвать аргументами: `sweep.sh 246 247`.
#
# 2026-08-27, решение юзера: пока идёт сходимость аудита, каждая волна правок
# меряется на 246 и 247 (~10 минут), а полный прогон с 233 делается ОДИН раз,
# когда сходимость достигнута. Прежний порядок гонял весь корпус после
# каждой волны, то есть тратил полчаса машины на вердикт о дереве, которое
# следующая волна всё равно переписывала.
#
# Неизвестное имя версии -- ОТКАЗ, а не тихий пропуск: опечатка в аргументе
# иначе дала бы пустой прогон с бодрым "SWEEP DONE" и нулём измерений.
declare -a SRC=()
if (( $# )); then
  for want in "$@"; do
    hit=""
    for entry in "${ALL[@]}"; do
      [[ "${entry%%:*}" == "$want" ]] && { SRC+=("$entry"); hit=1; break; }
    done
    [[ -n "$hit" ]] || { echo "SWEEP ОТКАЗ: версия '$want' не в списке (${ALL[*]%%:*})" >&2; exit 1; }
  done
else
  SRC=("${ALL[@]}")
fi
# Отсутствующий образ -- ОТКАЗ, и до первой сборки.
#
# Прежде цикл печатал «нет исходника», записывал строку в сводку и продолжал:
# прогон на неполном корпусе заканчивался бодрым SWEEP DONE и набором зелёных
# строк, по которому нельзя отличить «померили всё» от «померили что нашлось».
# Именно так пропажа корпуса едва не прошла незамеченной. Проверка снята с
# цикла и вынесена вперёд: неполный корпус не тратит десять минут машины и не
# оставляет сводки, которую можно прочесть как вердикт.
# Путь образа выводится из версии одним местом: имя файла корпуса -- часть
# формата, а не догадка каждого потребителя.
src_of() { printf '%s/%s.pristine' "$CORPUS" "$1"; }
ver_of() { local rest="${1#*:}"; printf '%s' "${rest%%:*}"; }
pin_of() { printf '%s' "${1##*:}"; }
declare -a MISSING=()
for entry in "${SRC[@]}"; do
  [[ -f "$(src_of "$(ver_of "$entry")")" ]] \
    || MISSING+=("${entry%%:*} ($(src_of "$(ver_of "$entry")"))")
done
if (( ${#MISSING[@]} )); then
  echo "SWEEP ОТКАЗ: нет пристинных образов: ${MISSING[*]}" >&2
  echo "  наполнить корпус: bash tools/fetch-corpus.sh" >&2
  exit 1
fi

# Корпус сверяется с пином ПЕРЕД прогоном.
#
# Наличие файла ничего не говорит о его содержимом: усечённая закачка,
# пропатченный по ошибке образ или подменённый файл дают измерение, по которому
# нельзя отличить «померили сток» от «померили патч поверх патча». Ровно этот
# класс уже приводил к зелёной сводке поверх загрязнённого артефакта (шапка
# выше). Пины -- третье поле corpus-versions.txt.
# Инструмент хеша выбирается ДО цикла: `exit 1` внутри функции, которую зовут
# только как `got=$(sha256_of ...)`, убивает подшелл, а не прогон -- отказ
# случался потом и по другой причине (пустой хеш не совпал с пином).
if command -v shasum >/dev/null 2>&1; then HASH=(shasum -a 256)
elif command -v sha256sum >/dev/null 2>&1; then HASH=(sha256sum)
else echo "SWEEP ОТКАЗ: нет ни shasum, ни sha256sum -- пин корпуса не проверить" >&2; exit 1
fi
# Пустой результат хеширования -- НЕ расхождение пина: файл без права чтения
# давал «на диске » и объявлялся подменённым, то есть причина отказа называлась
# неверно, а искать шли не там.
sha256_of() {
  local out
  out=$("${HASH[@]}" "$1" 2>/dev/null | awk '{print $1}')
  [[ -n "$out" ]] || return 1
  printf '%s' "$out"
}
declare -a TAINTED=()
for entry in "${SRC[@]}"; do
  v="${entry%%:*}"; src=$(src_of "$(ver_of "$entry")"); want=$(pin_of "$entry")
  if [[ "$want" == "-" ]]; then
    TAINTED+=("$v (пин не записан)"); continue
  fi
  if ! got=$(sha256_of "$src"); then
    TAINTED+=("$v (не прочитать $src)"); continue
  fi
  [[ "$got" == "$want" ]] || TAINTED+=("$v (пин $want, на диске $got)")
done
if (( ${#TAINTED[@]} )); then
  echo "SWEEP ОТКАЗ: корпус не сходится с пином: ${TAINTED[*]}" >&2
  exit 1
fi
echo "SWEEP версии: $(printf '%s ' "${SRC[@]%%:*}")"

SRC_KIT="$SWEEP_KIT"
# The sweep runs from a SNAPSHOT of the kit, not from the working tree.
#
# 2026-08-27. Seven builds is about 35 minutes, and for all of it the tree was
# untouchable: editing a script while bash executes it corrupts the run (bash
# reads by byte offset), so every verification froze the next wave behind it.
# The rhythm that produced was edit -> wait 35 minutes -> edit. Copying the kit
# once at the start costs a second and decouples the two: the snapshot is what
# gets verified, the tree stays free to be worked on, and the summary says which
# commit-state was measured so the two are never confused.
# Метка снимается ДО копирования и сверяется ПОСЛЕ: снятая только после, она
# описывала дерево на момент конца копирования, а не то, что попало в снимок.
# Расхождение не гадаем -- объявляем.
kit_state() {
  local st; st=$(cd "$SRC_KIT" && git rev-parse --short HEAD 2>/dev/null || echo "вне-git")
  [[ -n "$(cd "$SRC_KIT" && git status --porcelain 2>/dev/null)" ]] && st="$st+dirty"
  printf '%s' "$st"
}
STATE_BEFORE=$(kit_state)
HERE=$(mktemp -d "$STATE/kit.XXXXXX")
# Провал копирования -- отказ, а не сборка из половины кита: `cp -R` молча
# оставлял неполный снимок при нехватке места, и красный прогон приписывался
# коду, а не снимку.
cp -R "$SRC_KIT"/. "$HERE"/ || {
  echo "SWEEP ОТКАЗ: не снять снимок кита в $HERE" >&2; exit 1; }
# Метка происхождения снимка.
#
# `git diff --quiet` сравнивает дерево только с ИНДЕКСОМ, то есть видит лишь
# неиндексированные правки ОТСЛЕЖИВАЕМЫХ файлов. Снимок же -- `cp -R` всего
# дерева, вместе с неотслеживаемыми файлами и с проиндексированным. Метка могла
# напечатать чистый HEAD над кодом, которого в HEAD нет: сами инструменты свипа
# в момент их появления были неотслеживаемыми и для прежней формы невидимыми.
# `status --porcelain` покрывает все три случая.
SWEPT_STATE="$STATE_BEFORE"
[[ "$(kit_state)" == "$STATE_BEFORE" ]] || SWEPT_STATE="$SWEPT_STATE+сдвинулось-при-снимке"
echo "SWEEP снимок кита: $HERE (дерево $SWEPT_STATE)"
: > "$STATE/log/sweep-summary.txt"
echo "# снимок дерева: $SWEPT_STATE" >> "$STATE/log/sweep-summary.txt"
num() { case "$1" in ''|*[!0-9]*) echo "БИТО";; *) echo "$1";; esac; }

# Занятый замок конвейера: назвать держателя и переждать, а не записать ноль.
#
# 2026-08-28, прогон всего корпуса: 233 прошла зелёной, а следующие семь версий
# получили FATAL «another claude-patch-all.sh is running» с интервалом в
# секунду -- то есть замок в тот момент кто-то держал. КТО именно, установить не
# удалось: к моменту разбора процессов уже не было, а свип держателя не
# записывал. Отсюда две правки: держатель называется В МОМЕНТ отказа (lsof по
# файлу замка плюс срез ps), и версия не объявляется измеренной, пока бюджет
# ожидания не исчерпан. Конвейер отдаёт 3 на обеих дверях замка -- и на
# flock-ступени, и на каталоге-замке.
# Путь замка -- тот же, что у конвейера, и переопределяется той же ручкой:
# стенд обязан уметь проверить дверь занятого замка, не занимая БОЕВОЙ файл,
# из-за которого законный прогон оператора получал бы FATAL.
PATCH_LOCK="${CLAUDE_PATCH_LOCK:-${TMPDIR:-/tmp}/claude-patch-all.$(id -u).lock}"
LOCK_BUDGET=${SWEEP_LOCK_BUDGET:-600}
LOCK_POLL=15

declare -a UNMEASURED=()
RED=0
for entry in "${SRC[@]}"; do
  v="${entry%%:*}"; src=$(src_of "$(ver_of "$entry")"); want=$(pin_of "$entry")
  log="$STATE/log/sweep-$v.log"
  locklog="$STATE/log/sweep-$v.lock.log"
  rm -f "$log" "$locklog"
  # Меряется КОПИЯ, а пин доказывал исходник. Между сверкой и этим местом
  # проходят минуты и целые сборки: упавший `cp` (нет места, нет прав,
  # обломок прошлого прогона под тем же именем) или подменённый за это время
  # исходник давали измерение чужих байт под именем запинованной версии, и
  # прогон объявлял его зелёным. Сверяется то, что пойдёт в конвейер, и в тот
  # момент, когда оно туда пойдёт.
  if ! cp -p "$src" "$STATE/bin/$v.wave.bin"; then
    RED=$(( RED + 1 ))
    echo "SWEEP $v: КРАСНАЯ -- не скопировать $src в $STATE/bin/$v.wave.bin"
    echo "$v КРАСНАЯ (копия не сделана)" >> "$STATE/log/sweep-summary.txt"
    continue
  fi
  if ! copy=$(sha256_of "$STATE/bin/$v.wave.bin"); then
    RED=$(( RED + 1 ))
    echo "SWEEP $v: КРАСНАЯ -- не прочитать копию $STATE/bin/$v.wave.bin"
    echo "$v КРАСНАЯ (копия не читается)" >> "$STATE/log/sweep-summary.txt"
    continue
  fi
  if [[ "$copy" != "$want" ]]; then
    RED=$(( RED + 1 ))
    echo "SWEEP $v: КРАСНАЯ -- копия не сходится с пином (пин $want, копия $copy)"
    echo "$v КРАСНАЯ (копия не сходится с пином)" >> "$STATE/log/sweep-summary.txt"
    continue
  fi
  waited=0
  while :; do
    CLAUDE_PATCH_SKIP_MODELS=1 bash "$HERE/claude-patch-all.sh" \
      --target "$STATE/bin/$v.wave.bin" > "$log" 2>&1 8>&-
    rc=$?
    (( rc == 3 )) || break
    # Отдельный файл: повтор перезаписывает лог версии, и снятый срез иначе
    # исчез бы вместе с ним -- ровно так и потерялся держатель в прошлый раз.
    {
      echo "=== $(date '+%F %T') замок занят, ждём (прождано ${waited}s из ${LOCK_BUDGET}s) ==="
      echo "--- lsof $PATCH_LOCK ---"
      lsof "$PATCH_LOCK" 2>/dev/null || echo "(lsof не назвал никого)"
      # Срез ps -- ДОПОЛНЕНИЕ к lsof, и он обрезан по длине и числу строк.
      # Подстрока «claude-patch-all» встречается и в командной строке оболочки,
      # которая свип запустила: первый же снимок принёс многокилобайтную строку
      # с чужим окружением вместо имени держателя. lsof называет держателя
      # точно, ps лишь показывает соседей.
      echo "--- ps: конвейер и tweakcc (обрезано) ---"
      ps -eo pid,ppid,pgid,etime,args \
        | grep -E 'claude-patch-all|catalyst-tweakcc|--apply' | grep -v grep \
        | cut -c1-200 | head -20 \
        || echo "(таких процессов нет)"
    } >> "$locklog"
    (( waited >= LOCK_BUDGET )) && break
    sleep "$LOCK_POLL"; waited=$(( waited + LOCK_POLL ))
  done
  ok=$(num "$(grep -a -c '\[OK\]' "$log")")
  fail=$(num "$(grep -a -c '\[FAIL\]' "$log")")
  tw=$(num "$(grep -a -c '^    ✓ ' "$log")")
  ours=$(num "$(grep -a -c 'Script patch applied' "$log")")
  twruns=$(num "$(grep -a -c 'Customizations applied successfully' "$log")")
  iface=$(num "$(grep -a -c '^Interface:' "$log")")
  smoke=$(num "$(grep -a -c '^Version: .*(Claude Code)' "$log")")
  bench=$(num "$(grep -a -c '^Probes: .* scenarios behaved as specified' "$log")")
  # A NUL byte means two writers shared this file: the log is not one run.
  mixed=$(LC_ALL=C tr -d '\000' < "$log" | wc -c | tr -d ' ')
  size=$(wc -c < "$log" | tr -d ' ')
  note=""
  if (( rc == 3 )); then
    note=" НЕ ИЗМЕРЕНО(замок, ждали ${waited}s; держатели: $locklog)"
    UNMEASURED+=("$v")
  fi
  # Вердикт ПОТРЕБЛЯЕТ всё, что измерено.
  #
  # Прежде в него входил один код возврата, а счётчики оставались текстовой
  # припиской: лог, смешанный с чужим потоком (NUL), два применения патчей
  # вместо одного, ноль прошедших проверок, упавшая проверка, непройденный
  # дым, интерфейс или стенд зондов -- всё это печаталось и не мешало
  # последней строке сказать «красных нет» с нулевым кодом. То есть инцидент,
  # ради которого счётчики и заводились (выживший ребёнок допатчивает образ
  # ПОСЛЕ проверки), выглядел зелёным прогоном.
  #
  # Версия, не измеренная из-за замка, считается ОДИН раз, в своём счётчике:
  # её лога нет, и поля к ней не применяются.
  if (( rc != 3 )); then
    declare -a why=()
    (( rc == 0 )) || why+=("конвейер вернул $rc")
    [[ "$mixed" == "$size" ]] || why+=("лог смешан с чужим потоком (NUL)")
    [[ "$fail" == "0" ]] || why+=("проверок упало $fail")
    [[ "$ok" != "0" ]] || why+=("ни одной прошедшей проверки")
    [[ "$ours" == "1" ]] || why+=("наших применений $ours")
    [[ "$twruns" == "1" ]] || why+=("прогонов tweakcc $twruns")
    [[ "$smoke" == "1" ]] || why+=("дым не подтверждён")
    [[ "$iface" == "1" ]] || why+=("интерфейс не подтверждён")
    [[ "$bench" == "1" ]] || why+=("стенд зондов не подтверждён")
    if (( ${#why[@]} )); then
      RED=$(( RED + 1 ))
      note="$note КРАСНАЯ: $(printf '%s; ' "${why[@]}")"
    fi
  fi
  printf '%s exit=%s ok=%s fail=%s tweakcc=%s ours=%s smoke=%s iface=%s bench=%s%s\n' \
    "$v" "$rc" "$ok" "$fail" "$tw" "$ours" "$smoke" "$iface" "$bench" "$note" \
    >> "$STATE/log/sweep-summary.txt"
  echo "SWEEP $v: exit=$rc ok=$ok fail=$fail tweakcc=$tw bench=$bench$note"
done
rm -rf "$HERE"

# Хвост говорит, что произошло, и код возврата это повторяет.
#
# Прежде последней строкой всегда было `SWEEP DONE`, а код возврата -- ноль,
# каким бы ни был исход версий: прогон, где семь версий из восьми не собрались,
# заканчивался тем же словом, что и полностью зелёный. Вердикт лежал в тексте
# сводки, но ничего снаружи нельзя было повесить на код возврата.
if (( ${#UNMEASURED[@]} || RED )); then
  line="SWEEP НЕПОЛНЫЙ (дерево $SWEPT_STATE): версий не измерено ${#UNMEASURED[@]}"
  (( ${#UNMEASURED[@]} )) && line="$line (${UNMEASURED[*]})"
  line="$line, вернувших ошибку $RED из ${#SRC[@]}"
  echo "$line"
  echo "# $line" >> "$STATE/log/sweep-summary.txt"
  exit 1
fi
echo "SWEEP DONE (дерево $SWEPT_STATE): все ${#SRC[@]} версий измерены, красных нет"
