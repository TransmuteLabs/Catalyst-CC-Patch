#!/usr/bin/env bash
# One command for the whole stack: tweakcc's own patches + our multi-provider
# patches + a correct signature + the model data those patches read.
#
#   bash claude-patch-all.sh                 # apply everything to the current install
#   bash claude-patch-all.sh --configure     # open tweakcc's TUI to pick ITS patches, then apply everything
#   bash claude-patch-all.sh --update        # install the latest Claude Code first, then apply everything
#   bash claude-patch-all.sh --update 2.1.222
#   bash claude-patch-all.sh --only-ours     # skip tweakcc's patches, apply only ours
#   bash claude-patch-all.sh --target /path/to/binary   # build somewhere else
#   bash claude-patch-all.sh --target X --expect-sha <hex>  # ... and prove X is X
#   CLAUDE_PATCH_SKIP_MODELS=1 bash claude-patch-all.sh # skip the model price/window sync
#
# EXIT CODES -- the kit's shared table; every tool declares the subset it can
# return, and every caller branches on the CLASS, not on "non-zero". One code
# for two different answers is how a broken machine spent ten minutes looking
# like a busy lock (round 18, F-2).
#   0  green
#   1  a refusal on the merits: a gate failed, an assertion does not hold
#   2  the call contract is broken (unknown argument/mode, wrong arity), or an
#      instrument cannot measure at all: its anchor/table is gone
#   3  the lock is held by another live run -- retry later
#   4  a declared quantity does not match the actual one: the target's
#      bytes against --expect-sha, or a bench's mutation table against the
#      length/coverage it declares. Both are the same failure -- what the
#      caller was told does not hold -- and a caller that folds either into
#      1 loses the distinction between "a gate failed" and "the gate was
#      measuring something other than what it claims"
#   5  nothing to measure on this machine -- a skip, not a refusal (the
#      pipeline never returns it; see tools/build-path-probe.sh)
#   6  the environment or the lock machinery is broken: an inherited ownership
#      claim that does not hold, perl flock unusable. Retrying will not help.
#   7  the subject cannot be measured YET, for a reason outside this machine
#      that will pass on its own: upstream has not published an artifact a
#      layer needs (today: the prompt snapshot of this version). Nothing here
#      is broken -- the same run on the same version goes green by itself once
#      the artifact appears -- so a consumer must NOT paint it red, and must
#      not send anyone hunting for a defect. Split out of 2 in wave 47: one
#      code carried three different ACTIONS (wait for upstream / fix this
#      host's network / fix the instrument), and an action cannot be chosen
#      from a code that names three.
#   8  a probe's subject split in halves: its logical half WAS measured and
#      held, its material half is absent on this machine -- a skip of the
#      material half only, NOT "nothing was measured" and not a refusal
#      (the pipeline never returns it; split out of 5 in task #112, see
#      tools/build-path-probe.sh)
#
# Death by signal is answered as 128+N (130 INT, 143 TERM, via the split
# traps) and is NOT a kit verdict: POSIX reports the signal, the table above
# reports the kit's answers. Declared here because the two-sided rule demands
# it -- a reachable code must be declared, and wave 26 made 130/143 reachable.
#
# The reachability of 130 is spelled out because it is not verified the way
# one first tries to verify it (measured, round 25, request F-6). 130 arrives
# when INT is delivered to the process GROUP -- what a terminal does on
# Ctrl-C. `kill -INT <script pid>` while a foreground child is alive is
# dropped by bash: the child runs to completion, the INT trap does NOT fire,
# and the run finishes with its ordinary code. Nothing is truncated -- the
# whole run executed -- so that code is honest; but a reader who probes 130
# with a single-pid kill will conclude the trap is broken, and be wrong.
#
# A DEFAULT RUN NEVER TOUCHES THE LIVE FILE UNTIL EVERY GATE HAS PASSED: it
# builds into `<binary>.staging` and swaps that in with a rename at the end (see
# 0b). Patching in place rewrites a live executable under the process reading
# it, and -- worse, because it lasts -- between the tweakcc stage and ours the
# file is a valid binary with only HALF the patches, so a session started in
# that window has no multi-provider routing and dies on "unknown provider". A
# run that dies there used to leave the launcher target in that state for good.
#
# --target is for building an image that is NOT the live one; it patches the
# named file in place, so the caller owns the staging discipline:
#
#   V=~/.local/share/claude/versions/2.1.222
#   cp -p "$V.orig" "$V.staging"
#   bash claude-patch-all.sh --target "$V.staging"
#   mv "$V.staging" "$V"        # atomic; takes effect on the next launch
#
# That discipline is now CHECKED rather than trusted (0b2): a --target naming
# bytes that already carry our patches or tweakcc's stage is refused with code
# 4, before the unpacker and before tweakcc's stage. Both halves were paid for
# on 2026-08-28 -- a --target at the LIVE install had tweakcc restore its backup
# over patched bytes, die FATAL and leave the installation mutated while the run
# reported a refusal; and a staging file that a late gate had refused over still
# carried tweakcc's stage, so feeding it back in would have patched a patched
# image. For the same reason everything that merely VALIDATES the kit -- the
# parse gates, the forms gate, the benches, the number gates -- is asked BEFORE
# the image is touched at all: a refusal there can no longer leave a rewritten
# target behind.
#
# ORDER MATTERS AND IS NOT NEGOTIABLE:
#   `tweakcc --apply` RESTORES Claude Code from tweakcc's backup before applying
#   its own patches, which wipes anything else in the binary. So our patches must
#   always come AFTER it, and re-running tweakcc (its TUI included) always
#   requires re-running this script to put ours back. Re-running is how you
#   recover, and it is safe in the sense that matters -- it never builds over
#   the live file (0b) and never installs a build that failed a gate.
#
#   It is not, however, always ENOUGH: a default run refuses instead of
#   rebuilding when the live image already carries our patches and the pristine
#   copy beside it is missing, is itself patched, or belongs to another build.
#   Rebuilding from any of those would poison tweakcc's backup or swap a
#   different version over the live one, so the recovery there is to name the
#   version you mean: `bash claude-patch-all.sh --update <version>`. The refusal
#   prints that exact line.
#
#   Both tweakcc steps re-sign ad-hoc with an identifier derived from the file
#   name. On macOS that breaks the login keychain's ACL for the OAuth item
#   ("Not logged in"), so we re-sign LAST with a stable identity and the original
#   bundle id.
set -euo pipefail

# ARGUMENTS ARE READ BEFORE THE LOCK IS TAKEN, and that order is the contract,
# not a style choice: a broken call is broken forever, while a held lock is a
# transient condition, and answering the first with the second sends the caller
# to wait for a retry that can never help. Measured on this file: with the lock
# held, `--nonsense` returned 3 ("retry later") instead of 2, and `--help`
# returned 3 instead of the usage text. tools/build-path-probe.sh moved its own
# parsing above its lock for exactly this reason in round 18; the pipeline kept
# the old order until round 19. Nothing here touches shared state, so nothing
# here needs the lock.

CONFIGURE=0
ONLY_OURS=0
DO_UPDATE=0
UPDATE_VER=""
TARGET=""
EXPECT_SHA=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configure) CONFIGURE=1; shift ;;
    --only-ours) ONLY_OURS=1; shift ;;
    --target)    shift; [[ $# -gt 0 ]] || { echo "--target needs a path" >&2; exit 2; }
                 TARGET="$1"; shift ;;
    # The digest the CALLER believes the target holds. Verified here, at read
    # time, by the program that reads the file -- not by the one that handed it
    # over minutes earlier. See 0c.
    --expect-sha) shift; [[ $# -gt 0 ]] || { echo "--expect-sha needs a hex digest" >&2; exit 2; }
                 # The VALUE is checked here, not only its presence. The guard
                 # at the read site is `[[ -n "$EXPECT_SHA" && ... ]]` -- it has
                 # to be, because running without a pin is lawful -- so an EMPTY
                 # value arriving through this door is indistinguishable there
                 # from "the caller pinned nothing", and the run measures
                 # whatever lies at the path, greenly, while the caller believes
                 # it bound the bytes. That is how a caller whose
                 # `$(shasum ... | awk ...)` failed silently still got a green
                 # build. A malformed value is refused for the same reason in
                 # the other direction: without the shape check it would reach
                 # the comparison and exit 4, naming "the target is not the
                 # bytes" for what is actually a typo in the pin. Lowercase is
                 # required because that is what `shasum -a 256` prints, and the
                 # comparison downstream is a plain string equality.
                 [[ "$1" =~ ^[0-9a-f]{64}$ ]] || {
                   echo "--expect-sha needs a 64-character lowercase sha256 digest, got: '$1'" >&2
                   exit 2
                 }
                 EXPECT_SHA="$1"; shift ;;
    --update)    DO_UPDATE=1; shift
                 [[ $# -gt 0 && "$1" != --* ]] && { UPDATE_VER="$1"; shift; } || true ;;
    -h|--help)   sed -n '2,/^[^#]/p' "$0" | sed '$d'; __DONE=1; exit 0 ;;
    *)           echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$TARGET" && $DO_UPDATE -eq 1 ]] && { echo "ERROR: --target and --update are mutually exclusive" >&2; exit 2; }

# ONE RUN AT A TIME. Two instances are not independent: tweakcc keeps its state
# in a single shared directory, and it stores the system-prompt hashes by
# reading the whole index, editing it and writing it back. Two runs interleaving
# on that read-modify-write lose each other's entries, and the loser reports
# `hash storage failed` on whichever prompts happened to collide -- a failure
# that has nothing to do with the binary being patched and disappears on a
# retry, which is exactly the shape that gets dismissed as flaky. Measured: a
# version sweep and a single-version build started in parallel produced two such
# failures and a refused build.
#
# The lock is per-user, not per-target: the contended resource is tweakcc's
# state, not the binary.
#
# ОСВОБОЖДЕНИЕ. Замок держит ДЕСКРИПТОР: он умирает вместе с процессом и --
# что здесь важнее -- ДЕТИ его наследуют, поэтому переживший нас
# `node ... --apply` продолжает держать замок, пока пишет. Утилиты flock(1) на
# macOS нет (измерено: `command -v flock` -> rc=1 при живом контроле), но сам
# flock(2) есть, и его берёт perl, который у кита и так в обязательных
# инструментах. Замок-каталог остался последним рубежом на случай, когда нет ни
# того, ни другого; этого свойства у него НЕТ.
#
# Почему свойство существенно. Измерено пробой: bash ИСПОЛНЯЕТ EXIT-трап на
# SIGTERM (контроль -- трап на нормальном выходе тоже даёт след). На
# замке-каталоге это значило, что kill свипа снимал замок, пока наши дети живы
# и продолжают read-modify-write состояния tweakcc: следующий прогон законно
# брал замок и входил в тот самый interleaving, который шапка выше называет
# измеренным отказом. Прецедент в истории кита есть: переживший kill `--apply`
# дописывал в унаследованный fd. На ядерном замке этот сценарий закрыт по
# устройству -- проверяется прибором `tools/lock-probe.sh`.
#
# Добивание потомства на выходе осталось, но сменило основание: не «отпустить
# замок» (он отпустится сам, и держать его, пока писатель жив, правильно), а
# «не оставлять после убитого прогона `node`, который правит бинарник, никем не
# ожидаемый». TERM, затем -- если кого-то задели -- KILL: ребёнок, игнорирующий
# TERM, держал бы ядерный замок и после нашего выхода, а текст отказа советовал
# бы ждать того, чего уже нет.
# Путь замка переопределяем ОДНОЙ ручкой на конвейер и свип: стенду нужно
# проверить дверь занятого замка, не занимая боевой файл, иначе законный
# прогон оператора в это окно получает FATAL от стенда.
__lock="${CLAUDE_PATCH_LOCK:-${TMPDIR:-/tmp}/claude-patch-all.$(id -u).lock}"
# Замок не на боевом файле -- значит, прогон НЕ выстроен в очередь с настоящими
# сборками: два таких прогона одновременно правят один образ. Для зондов и
# стендов это штатно и ради этого ручка и заведена; молчать об этом нельзя --
# читатель лога иначе не отличит защищённый прогон от незащищённого.
[[ -z "${CLAUDE_PATCH_LOCK:-}" ]] \
  || echo "Lock: $__lock (CLAUDE_PATCH_LOCK; NOT the shared one — this run is not queued behind real builds)"

# УНАСЛЕДОВАННЫЙ ЗАМОК. Законный держатель-предок ровно один --
# tools/build-path-probe.sh: он одалживает ЖИВОЕ состояние ~/.tweakcc
# (config.json и native-binary.backup) на всё своё время -- снимок, три полных
# прогона конвейера, восстановление. Замок, взятый ВНУТРИ каждого прогона, эти
# окна не закрывает: между кейсами и на восстановлении он снят. Ребёнок,
# взявший замок заново, встал бы против собственного родителя, поэтому предок
# передаёт владение, а оболочка не берёт замок второй раз.
#
# ВЛАДЕНИЕ ДОКАЗЫВАЕТСЯ САМИМ ДЕСКРИПТОРОМ, а не переменной и не pid. Прежняя
# форма требовала «заявитель жив И замок занят» -- и это отвергало ровно
# безвредный случай (свободный замок) и пропускало ровно вредный: занят он мог
# быть КЕМ УГОДНО. Измерено пробой: посторонний живой `sleep`, названный в
# переменной при честном чужом держателе, проходил мимо замка и запускал весь
# конвейер параллельно чужому прогону -- тот самый interleaving, ради которого
# замок написан.
#
# Настоящая привязка: дескриптор 9 обязан указывать НА ФАЙЛ ЗАМКА (сверка
# устройства и инода, а не имени -- имя можно подсунуть) и flock на нём обязан
# УДАВАТЬСЯ. Второе и есть доказательство наследования: повторный флок на своём
# же описании -- пустая операция и всегда успех, а чужое описание, открытое кем
# угодно на тот же файл, получило бы отказ. Переменная после этого не нужна ни
# для чего, кроме текста сообщения; носитель переменной без дескриптора
# отсекается по построению.
if [[ -n "${CLAUDE_PATCH_LOCK_HELD_BY:-}" ]]; then
  if perl -e '
        use Fcntl ":flock";
        open(my $fh, ">&=9") or exit 2;
        my @a = stat($fh) or exit 3;
        my @b = stat($ARGV[0]) or exit 4;
        exit(5) unless $a[0] == $b[0] && $a[1] == $b[1];
        exit(flock($fh, LOCK_EX|LOCK_NB) ? 0 : 6);
      ' "$__lock"; then
    __lock_held=1
    __lock_how="унаследован по дескриптору 9 (заявитель pid $CLAUDE_PATCH_LOCK_HELD_BY)"
  else
    __inh_rc=$?
    case $__inh_rc in
      2) __why='дескриптор 9 не открыт -- переменная есть, а замка за ней нет';;
      3) __why='не удалось снять stat с дескриптора 9';;
      4) __why="не удалось снять stat с $__lock";;
      5) __why='дескриптор 9 указывает на ДРУГОЙ файл, не на замок';;
      6) __why='замок на этом файле держит другое описание -- значит не мы';;
      *) __why="perl вернул неожиданный код $__inh_rc";;
    esac
    echo "FATAL: CLAUDE_PATCH_LOCK_HELD_BY=$CLAUDE_PATCH_LOCK_HELD_BY заявляет владение замком," >&2
    echo "       но владение не подтверждается: $__why." >&2
    echo "       Работать без замка нельзя: состояние tweakcc общее." >&2
    # Код 6, а НЕ 3: это сломанное окружение, а не занятый замок. Разница не
    # косметическая -- свип на коде 3 ждёт бюджет замка и записывает «НЕ
    # ИЗМЕРЕНО(замок)», то есть лживая заявка десять минут выглядела бы чужим
    # прогоном и уходила в вердикт как «не измерено», а не как «кит сломан».
    exit 6
  fi
else
  exec 9>"$__lock"

# Замок берётся НАСТОЯЩИЙ -- flock(2) на дескрипторе 9, -- даже там, где нет
# утилиты flock(1). Это не украшение: у замка-на-дескрипторе два свойства,
# которых у замка-каталога нет по устройству, и оба измерены пробой.
#
#   1. Он живёт в ОПИСАНИИ ОТКРЫТОГО ФАЙЛА, а не в имени на диске. Процесс
#      умер -- ядро отпустило. Отсюда: нет протухших замков, нет протокола их
#      перехвата, а значит нет и гонки, в которой два претендента сносят
#      каталоги друг друга и оба считают себя владельцами.
#   2. ДЕТИ НАСЛЕДУЮТ дескриптор, и замок держится, пока жив хоть один из них.
#      Это ровно тот случай, ради которого замок написан: убитый посреди шага
#      прогон оставляет живого `node ... --apply`, который продолжает
#      read-modify-write состояния tweakcc. Замок-каталог в этот момент уже
#      снят (bash исполняет EXIT-трап на SIGTERM -- измерено), и следующий
#      прогон входит в тот самый interleaving, который шапка выше называет
#      измеренным отказом.
#
# Замеры (macOS, эта машина):
#   держатель жив                      -> соперник получает отказ
#   держатель убит SIGKILL, ребёнок жив -> соперник получает отказ
#   ребёнок добит                       -> соперник берёт замок
# Контроль прибора: два последовательных захвата свободного замка -- оба
# успешны, то есть «отказ» не печатается на ровном месте.
#
# Порядок попыток: flock(1), если есть; иначе perl (он и так в обязательных
# инструментах) -- он берёт flock(2) на УНАСЛЕДОВАННОМ дескрипторе 9, и замок
# ложится на описание, общее с этой оболочкой, поэтому выход perl его НЕ
# отпускает. Каталог-замок остаётся последним рубежом на случай, когда нет ни
# того, ни другого.
  __lock_busy() {
    echo "FATAL: another claude-patch-all.sh is running (lock: $__lock, замок держит $1)." >&2
    echo "       tweakcc's state is shared; a second run would interleave on it." >&2
    echo "       Замок живёт, пока жив хоть один его писатель, включая уцелевших детей" >&2
    echo "       убитого прогона -- поэтому «подождать» верный совет НЕ всегда:" >&2
    echo "       если работы уже нет, замок держит осиротевший писатель." >&2
    # Держатель называется В САМОМ отказе: диагноз «сирота внука стенда» не
    # должен стоить ручного разбора. lsof по файлу замка даёт всех его
    # писателей -- pid, команду; время старта добавляет ps.
    local __pid __holders __line
    __holders="$(lsof -t -- "$__lock" 2>/dev/null || true)"
    if [[ -n "$__holders" ]]; then
      echo "       Держатели замка сейчас:" >&2
      # `|| [[ -n "$__pid" ]]`: строка без перевода в конце иначе теряется --
      # read кладёт её в переменную и возвращает ненулевой код.
      while read -r __pid || [[ -n "$__pid" ]]; do
        [[ -n "$__pid" ]] || continue
        __line="$(ps -o pid=,lstart=,command= -p "$__pid" 2>/dev/null || true)"
        # Держатель мог уйти между lsof и ps: назвать его всё равно нужно --
        # голый pid отличает «ушёл сейчас» от «lsof не видел никого».
        if [[ -n "$__line" ]]; then
          printf '         %s\n' "$__line" >&2
        else
          printf '         pid %s (процесс ушёл, пока его называли)\n' "$__pid" >&2
        fi
      done <<< "$__holders"
      echo "       Завершить названного достаточно -- замок отпустится сам." >&2
    else
      # Шапка со списком печаталась безусловно, и при пустом lsof отказ
      # советовал завершить «названного», которого не назвал ни одной строкой.
      echo "       Держателя назвать не удалось: lsof молчит -- его нет в PATH," >&2
      echo "       либо держатель ушёл между попыткой замка и опросом. Отказ всё" >&2
      echo "       равно честен: замок был занят в момент попытки." >&2
    fi
    exit 3
  }

  __lock_held=0
  __lock_how=''
  __lockdir_owned=0
  __lock_rc=0

  # Ступень 1: утилита flock(1). На этой машине её нет, на linux-хостах есть.
  if command -v flock >/dev/null 2>&1; then
    if flock -n 9; then
      __lock_held=1; __lock_how='flock(1)'
    else
      __lock_rc=$?
      # rc=1 -- это ОТВЕТ ядра «занято». Любой другой код -- поломка прибора, и
      # читать её как «свободно» нельзя: различение этих двух случаев и есть
      # единственная причина не писать здесь короткое `|| true`.
      [[ $__lock_rc -eq 1 ]] && __lock_busy 'flock(1)'
      echo "NOTE: flock(1) не сработал (rc=$__lock_rc) -- пробую perl." >&2
    fi
  fi

  # Ступень 2: тот же flock(2), но через perl -- он и так в обязательных
  # инструментах, поэтому это НЕ новая зависимость. Замок ложится на описание
  # открытого файла, общее с этой оболочкой (дескриптор 9 унаследован), поэтому
  # завершение самого perl его НЕ отпускает.
  if [[ $__lock_held -eq 0 ]]; then
    if perl -e '
          use Fcntl ":flock";
          open(my $fh, ">&=9") or exit 2;
          exit(flock($fh, LOCK_EX|LOCK_NB) ? 0 : 1);
        '; then
      __lock_held=1; __lock_how='perl flock(2)'
    else
      __lock_rc=$?
      [[ $__lock_rc -eq 1 ]] && __lock_busy 'perl flock(2)'
      echo "NOTE: perl flock(2) не сработал (rc=$__lock_rc) -- беру каталог-замок." >&2
      echo "      Он слабее: не наследуется детьми и требует уборки за собой." >&2
    fi
  fi

  # Ступень 3, последний рубеж: каталог. Нужен только там, где нет НИ flock(1),
  # НИ рабочего perl -- то есть там, где кит и так не поедет. Сохранён потому,
  # что отсутствие замка хуже слабого замка.
  if [[ $__lock_held -eq 0 ]]; then
    __lockdir="$__lock.d"
    if ! mkdir "$__lockdir" 2>/dev/null; then
      # The pid lands a moment AFTER the directory, so an empty lock is either a
      # holder caught in that window or one that was killed inside it. Waiting a
      # second tells the two apart; without the wait, a kill in that window would
      # leave a lock nobody can ever break.
      # Владелец записывается парой: pid + время старта лидера
      # (LC_ALL=C ps -o lstart=). Живость по одному kill -0 верит
      # переиспользованному номеру: держатель мёртв, номер достался чужому
      # процессу -- и замок стоял бы вечно. pid без метки (файл прежней
      # редакции) живость не опровергает: тогда решает один kill -0.
      __owner=''
      for _ in 1 2 3 4 5; do
        __owner="$(cat "$__lockdir/pid" 2>/dev/null || true)"
        [[ -n "$__owner" ]] && break
        sleep 0.2
      done
      __opid="${__owner%%$'\t'*}"
      # Строка БЕЗ таба -- формат прежней редакции: метки нет, и подстановка
      # вернула бы всю строку; пустая метка возвращает решение kill -0.
      __ostart="${__owner#*$'\t'}"
      [[ "$__ostart" == "$__owner" ]] && __ostart=''
      __stale_dir=1
      if [[ -n "$__opid" ]] && kill -0 "$__opid" 2>/dev/null; then
        # ps отдаёт 1 на УЖЕ исчезнувший процесс -- это штатное «держатель
        # умер между kill -0 и ps», сравнение ниже разбирает пустую строку;
        # отказ прибора -- код выше единицы.
        __ostart_now="$(LC_ALL=C ps -o lstart= -p "$__opid" 2>/dev/null)" || __lstart_rc=$?
        [ "${__lstart_rc:-0}" -le 1 ] || { printf 'ПРИБОР НЕДОСТУПЕН: время старта держателя замка не прочитано (ps, код %s)\n' "$__lstart_rc" >&2; exit 2; }
        __lstart_rc=0
        if [[ -z "$__ostart" ]] || [[ "$__ostart_now" == "$__ostart" ]]; then
          __stale_dir=0
        fi
      fi
      if (( __stale_dir )); then
        # Nobody is behind it -- the lock is stale, take it over.
        rm -rf "$__lockdir"
        mkdir "$__lockdir" 2>/dev/null || { echo "FATAL: cannot take the patch lock ($__lockdir)." >&2; exit 3; }
      else
        echo "FATAL: another claude-patch-all.sh is running (pid $__opid, lock: $__lockdir)." >&2
        echo "       tweakcc's state is shared; wait for it to finish rather than racing it." >&2
        exit 3
      fi
    fi
    printf '%s\t%s\n' "$$" "$(LC_ALL=C ps -o lstart= -p "$$" 2>/dev/null)" > "$__lockdir/pid"
    # Подтверждение владения: `rm -rf` плюс `mkdir` -- не взаимно исключающая
    # пара, и два претендента, пришедшие одновременно, оба сносят свежий каталог
    # соперника. Владелец -- тот, чей pid записан последним; остальные отступают.
    sleep 0.3
    __confirm="$(cat "$__lockdir/pid" 2>/dev/null || true)"
    if [[ "${__confirm%%$'\t'*}" != "$$" ]]; then
      # Уходим, НЕ ТРОГАЯ каталог: он уже принадлежит победителю. Флаг владения
      # так и остался нулём, поэтому EXIT-трап тоже его не снесёт. Без этого
      # разделения проигравший гонки перехвата становился дворником чужого
      # замка -- две правки разных волн (подтверждение владения и трап,
      # снимающий каталог) уничтожали друг друга, и победитель работал с
      # замком, которого уже нет.
      echo "FATAL: замок перехвачен другим прогоном (в нём pid ${__confirm:-неизвестен}, у нас $$)." >&2
      exit 3
    fi
    __lockdir_owned=1
    __lock_held=1; __lock_how="каталог $__lockdir"
  fi
fi

# Уцелевшее потомство добивается на выходе НЕ ради замка -- ядерный замок
# отпустится сам, и держать его, пока писатель жив, правильно. Это гигиена:
# убитый прогон не должен оставлять после себя `node`, продолжающий править
# бинарник, которого уже никто не ждёт. На нормальном выходе детей нет, и цена
# нулевая. Обход в глубину: внуки тоже (pnpm/npx добавляют уровень).
__kids_hit=0
__kill_kids() {
  local __p="$1" __sig="$2" __c
  for __c in $(pgrep -P "$__p" 2>/dev/null || true); do
    __kill_kids "$__c" "$__sig"
    if kill -"$__sig" "$__c" 2>/dev/null; then __kids_hit=$((__kids_hit + 1)); fi
  done
}
# Часовой оборванного прогона.
#
# bash 3.2 (единственный на этой машине): фатальная ошибка ПОДСТАНОВКИ --
# unbound variable под `set -u`, `${x:?}`, bad substitution -- в скрипте с
# EXIT-трапом отдаёт вызывающему код 0. Измерено 2026-08-28 на четырёх формах:
# без трапа код 1, с трапом 0, и `rc=$?` внутри трапа тоже 0 -- «сохранить и
# вернуть» не спасает. Провал невидим ровно там, где его никто не ждёт: на
# ветке отказа, которую зелёный прогон не проходит. Поэтому штатный конец
# ОБЪЯВЛЯЕТ себя (__DONE=1), а трап без объявления краснит сам.
__DONE=0
__release_lock() {
  __rc=$?
  # Часовой контекста исполнителя ловушки: bash 5.2 исполняет EXIT-трап
  # В ПОДОБОЛОЧКЕ, когда фоновый потомок умирает от перехватываемого сигнала
  # (#237) -- без предиката тело сносило бы рабочий каталог среди прогона.
  # В bash 4.0+ BASHPID в подоболочке отличен от $$ (PID главного процесса).
  # В bash без BASHPID (3.2) PID исполняющей трап оболочки добывается форком:
  # PPID ребёнка подстановки -- PID нашей оболочки. Контекст -- ТРИ исхода:
  # главный / подоболочка / НЕ ОПРЕДЕЛЁН. Упавший или пустой форк обязан
  # считаться главным процессом (молчаливый невыход главного дороже редкой
  # уборки в подоболочке: вред требует совпадения двух независимых редкостей)
  # и объявляться именной строкой в stderr -- отказ инструмента не имеет
  # права одеваться в вердикт. Выход из ветки подоболочки -- return, не
  # exit: код выхода подоболочки менять мы права не имеем. Форк исполняется
  # один раз за выход и только на bash без BASHPID.
  if [[ -n "${BASHPID:-}" ]]; then
    [[ "$BASHPID" != "$$" ]] && return
  else
    __guard_ctx=$(exec sh -c 'echo $PPID') || __guard_ctx=
    if [[ -n "$__guard_ctx" && "$__guard_ctx" != "$$" ]]; then
      return
    fi
    [[ -z "$__guard_ctx" ]] && echo "ЧАСОВОЙ КОНТЕКСТА НЕ ОПРЕДЕЛЁН (форк PPID не дал ответа) -- продолжаю уборку как главный процесс" >&2
  fi
  # Однократность: повторный вход ловушки уборки не делает.
  trap - EXIT
  # Одного TERM мало. Ядерный замок держится, пока жив ХОТЬ ОДИН наследник
  # дескриптора 9, поэтому ребёнок, игнорирующий TERM или застрявший в syscall,
  # держал бы замок и ПОСЛЕ выхода этой оболочки -- а текст отказа советовал бы
  # следующему прогону подождать того, чего уже нет, и разорвать такой замок
  # было бы нечем. Ту же дисциплину (TERM, пауза, KILL) держит гейт интерфейса.
  # Пауза платится только если кого-то действительно задели: на нормальном
  # выходе детей нет и цена нулевая.
  __kids_hit=0
  __kill_kids $$ TERM
  if [[ $__kids_hit -gt 0 ]]; then
    sleep 1
    __kill_kids $$ KILL
  fi
  # Каталог сносит ТОЛЬКО его владелец: см. подтверждение владения выше.
  [[ "${__lockdir_owned:-0}" == 1 ]] && rm -rf "$__lockdir"
  if [[ "${__DONE:-0}" != 1 && "$__rc" == 0 ]]; then
    echo "FATAL: прогон оборвался, не дойдя до конца (ошибка оболочки выше)." >&2
    echo "  Ничего не установлено; код возврата 1, а не молчаливый ноль." >&2
    exit 1
  fi
  exit "$__rc"
}
trap '__release_lock' EXIT
# Волна 26 расщепила трапы у свипа, наполнителя, кит-сборки, раскатки проб,
# зонда пути, пола проверок, пробы стража и прибора замка -- а главный,
# 35-минутный скрипт остался на слитой форме (круг 28, F-2). Измерено на этой
# машине: при одиночном `trap ... EXIT` TERM приходит в часового как __rc=0,
# часовой НАЗЫВАЕТ остановку «ошибкой оболочки» и выходит 1 -- ложный диагноз
# на stderr ровно там, где человек читает, чем кончился его прогон. Явный
# `exit 143` по TERM превращает смерть в честный код сигнала; EXIT-трап при
# этом всё равно исполняется (замок снимается, потомство добивается).
trap 'exit 130' INT
trap 'exit 143' TERM

HERE="$(cd "$(dirname "$0")" && pwd)"

# Чтение метаданных файла живёт в ОДНОМ подключаемом файле на весь кит: те же
# два вопроса (метка времени, инод) задают свип и зонд пути сборки, и три копии
# идиомы уже разошлись -- две несли отравляющую форму «попробуй BSD, иначе
# GNU», третья безопасную, и различие держалось на одном пробеле; полный
# разбор формы -- в шапке носителя, и дословно её позволено писать только там
# (ценз сценария 146 стенда корпусных инструментов считает строки этого дома
# без разбора кода и прозы). Подключение
# стоит ЗДЕСЬ, рядом с выводом корня: ниже дом читают функции, объявленные
# раньше своего первого вызова, и подключение обязано опережать вызов, а не
# объявление. Отсутствие файла -- отказ ДО первой правки, код 6 «машинерия»:
# ломается договор между нашими же двумя файлами, а не что-то про образ.
if [[ ! -f "$HERE/tools/fs-meta.sh" ]]; then
  echo "FATAL: не найден $HERE/tools/fs-meta.sh -- метку времени и инод читать нечем." >&2
  echo "  Кит скопирован не целиком: порядок удаления старых сборок распаковщика" >&2
  echo "  считался бы по ключу, которого нет." >&2
  exit 6
fi
# shellcheck source=tools/fs-meta.sh
source "$HERE/tools/fs-meta.sh"

OUR_PATCH="$HERE/tweakcc-patch.js"
INSTALLER="$HERE/claude_patch.py"
COSTS_SYNC="$HERE/set-model-costs.py"
BUNDLE_ID="com.anthropic.claude-code"

resolve_signing_identity() {
  local identities line
  local identity_pattern='^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-Fa-f]{40})[[:space:]]+"[^"]+"[[:space:]]*$'
  if ! identities="$(security find-identity -v -p codesigning)"; then
    echo "FATAL: security find-identity failed; cannot resolve a signing identity." >&2
    return 1
  fi
  while IFS= read -r line; do
    if [[ "$line" =~ $identity_pattern ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done <<< "$identities"
  echo "FATAL: no code-signing identity found; a stable identity is required for Keychain OAuth." >&2
  return 1
}

sign_macos_binary() {
  local bin="$1" id="${CLAUDE_PATCH_SIGN_ID:-}"
  if [[ -z "$id" ]]; then
    id="$(resolve_signing_identity)" || return 1
  fi
  if [[ "$id" == "-" ]]; then
    echo "FATAL: CLAUDE_PATCH_SIGN_ID must name a stable signing identity." >&2
    return 1
  fi
  if ! codesign -f -i "$BUNDLE_ID" -s "$id" "$bin"; then
    echo "FATAL: code signing failed for $bin." >&2
    return 1
  fi
  if ! codesign -v --strict "$bin"; then
    echo "FATAL: strict signature verification failed for $bin." >&2
    return 1
  fi
  # The embedded runtime must start before the staging image can be published.
  # Вывод и код ЗАХВАТЫВАЮТСЯ, а не гасятся в /dev/null: этот `if` -- ЗАМЕР, и
  # до волны 48 его отказ не называл НИ ОДНОЙ причины, хотя ребёнок причину
  # сказал. Диагност платформы отделяет «плохи байты цели» от «образ собран под
  # другую машину»: во втором случае чинить нечего, это просто не тот хозяин.
  local __sv_out="" __sv_rc=0
  __sv_out="$("$bin" --version 2>&1)" || __sv_rc=$?
  if (( __sv_rc != 0 )); then
    echo "FATAL: signed binary --version failed for $bin (код $__sv_rc)." >&2
    if [[ -n "$__sv_out" ]]; then
      echo "  Сказано образом: ${__sv_out%%$'\n'*}" >&2
    fi
    __image_run_note "$bin"
    return 1
  fi
  echo "Re-signed with $id (bundle id $BUNDLE_ID); signature and launch verified"
}

# ~/.claude.json is rewritten by the model sync (and by Claude Code itself), so
# every run leaves a timestamped backup. Keep the three most recent.
prune_config_backups() {
  # `ls` exits 1 when the glob matches nothing, and under `set -euo pipefail`
  # that kills the whole script -- at a point that runs AFTER the launcher has
  # already been repointed. The first --update in a fresh home would then end
  # with no output, no `Done.` and a non-zero status, looking like a failed
  # install of a build that is in fact installed and live. Count with a glob the
  # shell expands itself; a non-matching glob leaves the literal behind, which
  # the -e test rejects.
  local f base delete_count
  local -a backups=()
  for f in "$HOME"/.claude.json.backup.*; do
    [[ -e "$f" ]] || continue
    # Функция вызывается голым именем (без if/&&/$()): отказ прибора вправе
    # ронять прогон отсюда.
    base="$(basename "$f")" || { printf 'ПРИБОР НЕДОСТУПЕН: не получено имя копии конфига из пути\n' >&2; exit 2; }
    [[ "$base" =~ ^\.claude\.json\.backup\.[0-9]{8}-[0-9]{6}$ ]] || continue
    backups[${#backups[@]}]="$f"
  done
  if [[ ${#backups[@]} -gt 3 ]]; then
    echo "==> Cleaning old config backups (keeping 3 most recent by name)"
    delete_count=$((${#backups[@]} - 3))
    printf '%s\n' "${backups[@]}" | LC_ALL=C sort | while IFS= read -r f; do
      (( delete_count > 0 )) || break
      rm -v "$f"
      delete_count=$((delete_count - 1))
    done
  fi
}

versions_in_use() {
  local pids p names pgrep_rc=0
  pids="$(pgrep -x claude 2>/dev/null)" || pgrep_rc=$?
  (( pgrep_rc <= 1 )) || return 2
  [[ -z "$pids" ]] && return 0
  for p in $pids; do
    names="$(lsof -a -p "$p" -d txt -Fn 2>/dev/null | sed -n 's/^n//p')" || return 2
    [[ -n "$names" ]] || return 2
    printf '%s\n' "$names"
  done
}

# One cache entry per pinned SHA, ~490 MB each, and nothing ever removed them:
# nine pins from a single afternoon of bisecting a locator came to 4.3 GB. Keep
# the pin in use plus the two most recent others -- enough to step a bump back
# without a two-minute rebuild -- and drop the rest. Nothing removed here is
# lost: an entry is a content-addressed fetch of a commit GitHub still serves,
# rebuilt on demand by ensure_tweakcc.
prune_tweakcc_cache() {
  local keep="$1" entry
  [[ -d "$CATALYST_TWEAKCC_CACHE" ]] || return 0
  # Iterated by GLOB, not by parsing `ls`. A cache entry whose name contains a
  # newline splits into two lines of `ls` output, and those two lines then name
  # two OTHER real entries -- so the malformed directory survives and two good
  # ones are deleted. Restricting the domain to what ensure_tweakcc actually
  # creates (a 40-character hex commit id) closes that and the `..` class at
  # once: anything else in this directory is left alone rather than guessed at.
  #
  # The in-use pin is touched first so that mtime order reflects USE. Excluding
  # it by name protects this run; touching it also protects a CONCURRENT run,
  # which excludes its own pin but would otherwise be free to select ours.
  if [[ -d "$CATALYST_TWEAKCC_CACHE/$CATALYST_TWEAKCC_SHA" ]]; then
    touch "$CATALYST_TWEAKCC_CACHE/$CATALYST_TWEAKCC_SHA"
  fi
  local -a entries=()
  while IFS= read -r entry; do
    entries+=("$entry")
  done < <(
    cd "$CATALYST_TWEAKCC_CACHE" 2>/dev/null || exit 0
    for entry in [0-9a-f][0-9a-f]*; do
      [[ -d "$entry" && ${#entry} -eq 40 && "$entry" =~ ^[0-9a-f]{40}$ ]] || continue
      [[ "$entry" == "$CATALYST_TWEAKCC_SHA" ]] && continue
      # Ключ сортировки -- метка времени из ОБЩЕГО ДОМА (tools/fs-meta.sh).
      # Здесь стояла своя копия отравляющей идиомы, и на Linux в ключ попадала
      # четырёхстрочная статистика файловой системы плюс число: неверно
      # упорядочивалось то, ЧТО УДАЛЯЕТСЯ. Дом отдаёт либо цифры, либо ничего;
      # `|| echo 0` -- объявленный ответ на «метки нет»: запись без метки
      # становится САМОЙ СТАРОЙ и уходит первой, что здесь и требуется.
      printf '%s\t%s\n' "$(fs_mtime "$entry" || echo 0)" "$entry"
    done | sort -rn | cut -f2-
  )
  (( ${#entries[@]} > keep )) || return 0
  echo "==> Cleaning old unpacker builds (keeping the pin in use + $keep most recent)"
  for entry in "${entries[@]:keep}"; do
    rm -rf "${CATALYST_TWEAKCC_CACHE:?}/$entry" && echo "    removed ${entry:0:12}"
  done
}

# Полнота САМОГО кита -- класс «прибор не может мерить» (2), а не отказ по
# существу: рядом со скриптом нет его же нагрузки.
[[ -f "$OUR_PATCH" ]] || { echo "ERROR: tweakcc-patch.js not found next to this script" >&2; exit 2; }
command -v node >/dev/null || { echo "ERROR: node is required (tweakcc runs on Node)" >&2; exit 6; }
# Everything below is used by a gate or by the install step, and each one fails
# in a way that reads like something else when it is absent: a missing `perl`,
# `script` or `seq` makes the interface gate exit in a second and report "never
# reached a render within 150s"; a missing `curl` or `tar` surfaces as "could
# not fetch/unpack"; a missing `codesign` leaves an unsigned image whose
# keychain access fails much later. Name the missing tool here instead.
# `tsc` попал сюда замером 10.09 на linux: его нет в неинтерактивном PATH, и
# прогон умирал не здесь, а через полторы тысячи строк -- на разборе
# вклеиваемого кода, строкой «разбор НЕ ВЫПОЛНЕН: прибор не может мерить
# (якорь/строка пропали)». Причина названа НЕ ТА: якорь на месте, отсутствует
# компилятор. Проверка имён (tools/emit-check.js) зовётся БЕЗУСЛОВНО и
# объявляет отсутствующий компилятор отказом, а не пропуском, -- значит `tsc`
# обязателен ровно так же, как `node`, у которого своя дверь выше.
# `env` попал сюда волной 46: он несёт обёртку окружения, которой кит
# подставляет форку ручку прокси node (см. __tw_node_proxy_wrap). Без обёртки
# подстановка не состоялась бы, форк ушёл бы в сеть мимо прокси и вернул
# пустой слой промтов -- ровно тот обвал, который дверь обвала лишь НАЗЫВАЕТ.
# Требуется безусловно, а не «когда прокси задан»: эта дверь стоит ДО чтения
# окружения, и дверь, чей состав зависит от окружения, дверью быть перестаёт.
# ПАРА ХОЗЯИНА -- ОДИН дом на весь конвейер. Её спрашивают порознь дверь
# обязательных инструментов, подписант и стадия гейта интерфейса; три
# независимых `uname` разошлись бы молча -- ровно тот силуэт, который эта волна
# и разбирает. Отображение имён -- то же, что у claude_patch.host_os_arch();
# копия здесь существует потому, что стадия гейта ВЫРЕЗАЕТСЯ стендом и
# исполняется без кита рядом, то есть импортировать питон ей нечем.
# печатает <ос>-<дуга> ХОЗЯИНА
__host_os_arch() {
  local os arch __un_s __un_m
  # «unknown» в ветке * -- ОБЪЯВЛЕННЫЙ ответ на неответивший uname (rc 1,
  # пустой вывод): пара хозяина обязана существовать на любом хозяине.
  # Отказ прибора -- код выше единицы.
  __un_s="$(uname -s)" || __unos_rc=$?
  [ "${__unos_rc:-0}" -le 1 ] || { printf 'ПРИБОР НЕДОСТУПЕН: ОС хозяина не опознана (uname, код %s)\n' "$__unos_rc" >&2; exit 2; }
  __unos_rc=0
  case "$__un_s" in
    Darwin)               os=darwin ;;
    Linux)                os=linux ;;
    MINGW*|MSYS*|CYGWIN*) os=win32 ;;
    *)                    os=unknown ;;
  esac
  __un_m="$(uname -m)" || __unm_rc=$?
  [ "${__unm_rc:-0}" -le 1 ] || { printf 'ПРИБОР НЕДОСТУПЕН: дуга хозяина не опознана (uname, код %s)\n' "$__unm_rc" >&2; exit 2; }
  __unm_rc=0
  case "$__un_m" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64)  arch=x64 ;;
    *)             arch=unknown ;;
  esac
  printf '%s-%s\n' "$os" "$arch"
}
# Отказ прибора у этих двух обёрток осаждается ЗДЕСЬ (в подстановке) и
# подхватывается ПРОВЕРЕННЫМ вызовом снаружи: у __host_needs_codesign выше и
# у __HOST_PAIR/__host_pair ниже. Непроверенный вызов остался один -- строка
# «хозяин $(__host_os)» в ветке else двери инструментов, куда прогон попадает
# только после уже прошедшей проверки.
__host_os() {
  local p
  p="$(__host_os_arch)" || { printf 'ПРИБОР НЕДОСТУПЕН: пара платформ хозяина не измерена\n' >&2; exit 2; }
  printf '%s\n' "${p%%-*}"
}
__host_arch() {
  local p
  p="$(__host_os_arch)" || { printf 'ПРИБОР НЕДОСТУПЕН: пара платформ хозяина не измерена\n' >&2; exit 2; }
  printf '%s\n' "${p#*-}"
}

# Пара ОБРАЗА -- у неё дом ОДИН и он питоновский (claude_patch.image_os_arch):
# магические байты читает разборщик, а не оболочка. Отказ детектора (fat, не
# образ) -- отказ конвейера: угадывать платформу образа нечем.
__image_os_arch() {   # путь -> печатает <ос>-<дуга>
  CP_KIT="$HERE" CP_IMG="$1" python3 - <<'PY_IMG_OS'
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ['CP_KIT'])
import claude_patch
print('%s-%s' % claude_patch.image_os_arch(Path(os.environ['CP_IMG'])))
PY_IMG_OS
}

# ПОЧЕМУ ОБРАЗ НЕ НАЗВАЛСЯ: диагноз, а не первая причина из списка.
#
# Четыре двери конвейера просят образ назвать себя (`--version`) и, не получив
# ответа, печатают отказ. До волны 48 каждая называла ПЕРВУЮ причину своего
# списка -- «цель не называет свою версию», «образ не запускается», «бэкап
# держит патч», -- и человек читал их как приговор БАЙТАМ. Между тем у пары
# «darwin-образ на linux-хозяине» ядро отказывает ДО первого байта программы:
# байты цели тут ни при чём, и чинить их бессмысленно. Тот же класс, что #105
# (одно имя на несколько предметов), и лечится тем же: ИЗМЕРИТЬ и НАЗВАТЬ.
#
# Функция НИЧЕГО не решает и никого не роняет -- она только ОПИСЫВАЕТ, поэтому
# возвращает ноль всегда: диагност, роняющий прогон, отнимает у двери право
# самой выбрать код возврата. Детектор платформы умеет отказать сам (fat-образ,
# не образ, нечитаемый путь), и тогда честный ответ -- «пара платформ НЕ
# УСТАНОВЛЕНА» вместе с его собственными словами. Дверь, назвавшая причину
# наугад, вреднее немой: немая отправляет читать лог, а угадавшая -- чинить не то.
__image_run_note() {   # <путь к образу> -> диагноз в stderr; код ВСЕГДА 0
  local __p="$1" __out __host __rc=0 __host_rc=0
  # Пара хозяина нужна диагносту только СЛОВОМ (строка «Хозяин: …» ниже).
  # Контракт функции -- «код ВСЕГДА 0»: диагност не решает и не роняет,
  # отказ измерения НАЗЫВАЕТСЯ в тексте, как и отказ детектора ниже.
  __host="$(__host_os_arch)" || __host_rc=$?
  (( __host_rc == 0 )) || __host="пара не измерена (код $__host_rc)"
  # stderr детектора СЛИВАЕТСЯ в переменную, а не гасится: `2>/dev/null` здесь
  # означал бы «причина неизвестна, и мы не покажем почему».
  __out="$(__image_os_arch "$__p" 2>&1)" || __rc=$?
  # Форма ответа проверяется, а не предполагается: детектор мог вернуть ноль и
  # напечатать что-то иное, и тогда сравнение с хозяином было бы гаданием.
  if (( __rc != 0 )) || [[ ! "$__out" =~ ^(darwin|linux|win32)-(arm64|x64)$ ]]; then
    echo "  ПАРА ПЛАТФОРМ НЕ УСТАНОВЛЕНА (детектор вернул $__rc): ${__out%%$'\n'*}" >&2
    echo "  Хозяин: $__host. Отсюда не видно, платформа виновата или байты -- не гадаем." >&2
    return 0
  fi
  if [[ "$__out" != "$__host" ]]; then
    echo "  ПРИЧИНА: образ собран под $__out, а хозяин $__host. Такой образ здесь не" >&2
    echo "  исполняется НИ ПРИ КАКИХ байтах -- назваться он не мог, и байты цели ни при" >&2
    echo "  чём. Чинить нечего: это просто не та машина." >&2
    return 0
  fi
  echo "  Пара платформ СОВПАДАЕТ ($__out) -- причина НЕ в платформе, смотреть на байты." >&2
  return 0
}

# КОНСТРЕЙНТ: `codesign` требуется ТОГДА И ТОЛЬКО ТОГДА, когда ОС хозяина --
# darwin. Не «и ОС цели darwin»: подписать образ можно лишь при хозяин==цель
# (claude_patch.sign), поэтому на не-darwin хозяине инструмент не может
# понадобиться НИ ПРИ КАКОЙ цели -- дверь, требующая его там, требует
# невозможного, и проходить её приходилось заглушкой в PATH. Цель здесь ещё и
# НЕ ИЗВЕСТНА: дверь стоит до стадии 0, где образ только появляется.
# Условие вынесено в функцию, а не написано на месте, чтобы стенд мог вырезать
# её по имени и прогнать ОБЕ ветки на подставном `uname`, не завися от того, на
# каком хозяине он запущен (тот же приём, что у __gate_script_form).
__host_needs_codesign() {   # код 0 -- нужен, 1 -- не нужен
  local __hos
  # Единственный вызов функции стоит голым `if` и ветвится по ВЕРДИКТУ 0/1;
  # «прибор не измерил» -- вне этого домена и обязано ронять прогон кодом 2,
  # а не выбираться молча в ветку «не нужен».
  __hos="$(__host_os)" || { printf 'ПРИБОР НЕДОСТУПЕН: ОС хозяина не измерена\n' >&2; exit 2; }
  [[ "$__hos" == "darwin" ]]
}

MISSING=()
REQUIRED_TOOLS=(env python3 curl tar perl script seq awk sed grep sort cmp shasum tsc)
if __host_needs_codesign; then
  REQUIRED_TOOLS+=(codesign)
else
  echo "Обязательные инструменты: codesign НЕ требуется -- хозяин $(__host_os), подписать можно только на своей ОС"
fi
for t in "${REQUIRED_TOOLS[@]}"; do
  command -v "$t" >/dev/null || MISSING+=("$t")
done
if (( ${#MISSING[@]} )); then
  echo "ERROR: these tools are required and were not found on PATH: ${MISSING[*]}" >&2
  # Класс 6: сломано ОКРУЖЕНИЕ -- повтор не поможет, чинить машину, а не кит.
  exit 6
fi

# --- 0. optionally install a pristine Claude Code -----------------------------
if [[ -n "$TARGET" ]]; then
  [[ -f "$TARGET" ]] || { echo "ERROR: --target $TARGET does not exist"; exit 1; }
  BIN="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$TARGET")" || { printf 'ПРИБОР НЕДОСТУПЕН: не разрешён полный путь цели\n' >&2; exit 2; }
elif [[ $DO_UPDATE -eq 1 ]]; then
  echo "==> Installing a pristine Claude Code${UPDATE_VER:+ $UPDATE_VER}"
  BIN="$(python3 "$INSTALLER" --download-only ${UPDATE_VER:+$UPDATE_VER} | tail -1)" || { printf 'ПРИБОР НЕДОСТУПЕН: не получен путь скачанного образа\n' >&2; exit 2; }
else
  # `command -v claude` returns the FIRST match on PATH, and the first match is
  # not necessarily a Claude Code image. This machine puts a shell wrapper ahead
  # of the installer's symlink (~/.local/bin-shims/claude adds a flag and then
  # execs the real launcher), and handing that wrapper to the unpacker produced
  # "No VERSION strings found in JS file" -- a message that reads like a broken
  # bundle rather than like a target that was never a bundle at all. The run
  # then continued past it and died a second time in our own patcher, so the
  # first diagnosis to appear was also the least informative one.
  #
  # Walk the WHOLE of PATH and require exactly one Claude Code image. Taking the
  # first would make the choice a property of PATH order: a second image earlier
  # in PATH would be patched while the launcher kept running the other one, and
  # every check below would pass on the binary nobody executes.
  # The wrapper execs the very launcher this then selects, so the binary we
  # patch stays the binary that runs: a wrapper is a redirection, not a
  # different product. If nothing on PATH is an image, say which candidates were
  # found and why each was rejected -- "not on PATH" and "on PATH but not a
  # binary" are different faults and must not share one message.
  # NOTE: this heredoc sits inside a command substitution, and bash scans
  # `$( ... )` for its closing paren while honouring quotes -- so a LONE
  # apostrophe anywhere in this body (in prose, in a comment) opens a quote
  # that swallows the rest of the file, and the parse error surfaces a
  # thousand lines away inside a different heredoc. Write "a foreign tool",
  # never "someone else\x27s tool", below this line.
  BIN="$(python3 - <<'PY'
import os, sys

# Mach-O thin (both endians, 32/64), Mach-O fat, and ELF. A file that starts
# with none of these is not something the unpacker can read.
MAGIC = (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
         b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf',
         b'\x7fELF')

# Three questions, three lists: what named `claude` at all (candidates), which
# physical files have been looked at (seen, keyed by inode), and what was turned
# away and why (rejected). One list answering two questions happens to work only
# for as long as the two kinds of value never compare equal.
candidates, seen, rejected, images = [], [], [], []


def contains(path, marker):
    # Streamed, with an overlap: the marker may straddle a chunk boundary, and a
    # naive per-chunk search would miss it on some builds and not others.
    overlap = len(marker) - 1
    tail = b''
    with open(path, 'rb') as fh:
        while chunk := fh.read(8 << 20):
            if marker in tail + chunk:
                return True
            tail = chunk[-overlap:] if overlap else b''
    return False
for d in os.environ.get('PATH', '').split(os.pathsep):
    p = os.path.join(d or '.', 'claude')
    if not (os.path.isfile(p) and os.access(p, os.X_OK)):
        continue
    # Counted BEFORE anything is read: "no claude on PATH" and "claude is there,
    # but none of them qualified" are different faults, and merging them sends
    # the reader looking in the wrong place. A PATH of unreadable `claude` files
    # reached the first message until this list existed.
    candidates.append(p)
    real = os.path.realpath(p)
    # Identity is the INODE, not the path. realpath collapses symlinks but not
    # hard links, so two directory entries for one physical file survived as two
    # entries and tripped the "more than one image" refusal below -- a refusal
    # whose text asserts the images are DIFFERENT while pointing at one file.
    try:
        st = os.stat(real)
        key = (st.st_dev, st.st_ino)
    except OSError as exc:
        rejected.append('%s: unreadable (%s)' % (p, exc))
        continue
    if key in seen:
        continue
    seen.append(key)
    try:
        head = open(real, 'rb').read(4)
    except OSError as exc:
        rejected.append('%s: unreadable (%s)' % (p, exc))
        continue
    if not any(head.startswith(m) for m in MAGIC):
        rejected.append('%s: %s' % (p, 'shell script' if head.startswith(b'#!') else 'not a native image'))
        continue
    # Being a native image is not being THIS product. Without this test any
    # executable named `claude` anywhere on PATH -- a foreign tool, a
    # compile of your own -- became the target and was rewritten in place; the
    # run only died later, in the unpacker, with a message about a broken
    # bundle rather than about a target that was never this bundle.
    if not contains(real, b'@anthropic-ai/claude-code'):
        rejected.append('%s: a native image, but not Claude Code' % p)
        continue
    images.append(real)

# Exactly one, or say so. Taking the first would make the choice a property of
# PATH order: a second Claude Code earlier in PATH would be patched while the
# launcher kept running the other one, and every check below would pass on the
# binary nobody executes.
if len(images) == 1:
    if rejected:
        # Not "ahead of it": the walk no longer stops at the accepted image --
        # continuing is what powers the exactly-one rule -- so this list holds
        # candidates from BOTH sides of it.
        # Not "non-image": the list now also holds real native images that are
        # not this product. Name the rejections, let each row say why.
        sys.stderr.write('Note: skipped %d other candidate(s) on PATH:\n' % len(rejected))
        for r in rejected:
            sys.stderr.write('  %s\n' % r)
    print(images[0])
    sys.exit(0)

if len(images) > 1:
    sys.stderr.write('ERROR: %d different Claude Code images on PATH:\n' % len(images))
    for i in images:
        sys.stderr.write('  %s\n' % i)
    sys.stderr.write('  Patching the first would leave the launcher running another.\n')
    sys.stderr.write('  Pass the one you mean with --target /path/to/binary.\n')
elif not candidates:
    sys.stderr.write("ERROR: 'claude' not on PATH\n")
else:
    sys.stderr.write('ERROR: no Claude Code image on PATH; every candidate was rejected:\n')
    for r in rejected:
        sys.stderr.write('  %s\n' % r)
    sys.stderr.write('  Pass the image explicitly with --target /path/to/binary.\n')
sys.exit(1)
PY
)" || __img_rc=$?
# Код 1 -- ОТКАЗ ПО СУЩЕСТВУ (образа на PATH нет либо он не единственный):
# разбор сам напечатал причину в stderr, и прогон умирает кодом 1 -- как и
# до правки (тогда его убивал set -e). Код выше единицы -- отказ прибора.
[ "${__img_rc:-0}" -le 1 ] || { printf 'ПРИБОР НЕДОСТУПЕН: авто-детект цели отказал (код %s)\n' "$__img_rc" >&2; exit 2; }
[ "${__img_rc:-0}" -eq 0 ] || exit 1
__img_rc=0
fi

# Три ветки выше выбрали цель тремя разными способами, и спрашивали с неё
# разное. Авто-детект задавал образу два вопроса (магия, вхождение
# `@anthropic-ai/claude-code`), ветка `--update` доверяла своей загрузке, а
# `--target` не спрашивала НИЧЕГО, кроме существования файла -- при том что
# рецепт в шапке этого же скрипта сам ведёт человека к `<версия>.staging`,
# то есть ровно к файлу, который остаётся после ОБОРВАННОЙ загрузки.
#
# Оборванный образ проходит оба прежних вопроса: магия лежит в первых четырёх
# байтах, маркер продукта -- задолго до конца файла. Падало это позже, внутри
# распаковщика, сообщением про сломанный бандл, и классификатор ниже (:600)
# объяснял его как "не применился ни один патч" с тремя советами, среди
# которых причины не было.
#
# Поэтому вопрос задаётся ОДИН и в одном месте -- после того как цель выбрана,
# каким бы способом она ни выбралась, -- и включает третий: объявляют ли
# заголовки самого образа больше байт, чем лежит на диске.
# --- 0a. are these the bytes we were handed? ----------------------------------
# Asked BEFORE image-check.py below, because "is this the file you meant?" comes
# before "is this a valid image": a target that is not the named bytes has
# nothing to say about the run, whatever else it is.
#
# image-check.py asks three questions of the target -- magic, product marker,
# completeness -- and none of them is that one. On the
# `--target` path nobody asks it at all: the caller (the version sweep, the
# recipe in this header) pins a digest, copies the file, and hands over a PATH.
# Minutes pass -- the lock, the unpacker install, tweakcc's stage -- and the
# pipeline then reads whatever is at that path. A failed copy, a leftover under
# the same name from an earlier run, or a foreign writer in between, and the
# build measures other bytes under the pinned version's name, greenly.
#
# So the question is asked by the program that READS the file, at the moment it
# reads it, and the answer is printed either way: `--expect-sha` refuses (code
# 4 of the kit's table at the top of this file; a target that cannot be READ at
# all is not a pin mismatch and exits 1), and the announced
# digest lets a caller that did not pin anything still bind the run's verdict to
# the bytes afterwards.
sha_of() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }
HANDED_SHA="$(sha_of "$BIN")" || { printf 'ПРИБОР НЕДОСТУПЕН: не снята контрольная сумма цели\n' >&2; exit 2; }
if [[ -z "$HANDED_SHA" ]]; then
  echo "ERROR: could not read $BIN to take its digest" >&2
  exit 1
fi
if [[ -n "$EXPECT_SHA" && "$HANDED_SHA" != "$EXPECT_SHA" ]]; then
  echo "ERROR: the target is not the bytes named by --expect-sha" >&2
  echo "  expected: $EXPECT_SHA" >&2
  echo "  on disk:  $HANDED_SHA  ($BIN)" >&2
  exit 4
fi

# `9>&-`: дети наследуют дескриптор замка; без закрытия осиротевший ВНУК
# инструмента держал бы замок за давно закончившийся прогон (измерено свипом:
# отказ на занятом замке без живой сборки). Закрывается у КАЖДОГО вызова
# инструмента кита, а не только у порождающих детей сегодня.
python3 "$HERE/tools/image-check.py" "$BIN" 9>&- || {
  __rc=$?
  # Класс отказа называется по коду И ПЕРЕЖИВАЕТ выход: «образ не тот» (1) и
  # «прибор не мерил» (2) -- разные починки, и раньше оба уезжали кодом 1,
  # хотя таблица кита обещает для второго двойку (раунд 19, A-2).
  if [[ $__rc -eq 2 ]]; then
    echo "FATAL: image-check.py вызван неверно (rc=2) -- это не про образ" >&2
    exit 2
  fi
  exit 1
}

echo "Target binary: $BIN"

# --- 0b. never hand tweakcc a binary that already carries our patches ---------
# `tweakcc --apply` runs its startupCheck first, and that check refreshes its
# backup from whatever `ccInstallationPath` points at whenever the recorded
# version differs from the installed one (startup.ts: `realVersion !==
# backedUpVersion` -> unlink the backup, copy the CURRENT file, record the new
# version). Point it at a patched binary in that state and its backup silently
# becomes a copy of OUR build -- permanently, since the version now matches and
# the refresh never fires again. From then on `tweakcc --restore` writes patched
# bytes and reports success, and the human who asked for stock gets the patch.
#
# The state is not exotic: a sweep across versions leaves ccVersion on the last
# one swept while the live binary is a different, patched one, and the very next
# default run lands in it.
#
# So a default run REBUILDS BESIDE THE LIVE FILE and swaps the result in with a
# rename at the end -- which is what the header mandates for a live binary
# anyway, and which additionally keeps the live file out of the build until
# every gate has passed.
#
# The source of that rebuild depends on what the live file is:
#
#   * it already carries our patches -> build from OUR pristine copy `.orig`
#     (patching a patched image is what poisons tweakcc's backup, above);
#   * it is pristine                 -> build from THE LIVE BYTES THEMSELVES,
#     after taking a pristine copy of them.
#
# The pristine case used to patch in place, and that was a hole of its own: the
# live installation was the build for the whole run, so a gate that fired late
# (the interface gate, the probes, any of the pipeline's 39 checks) left the human
# with an image that had been patched and then declared unfit -- while the run
# reported a refusal. `set -e` cannot undo bytes. Now every default run has the
# same shape: nothing touches the live name until every gate has passed.
#
# It does NOT by itself make the build independent of tweakcc's backup: that
# backup is restored over the staging file at the start of tweakcc's stage, so
# what the build begins from is verified in 1b, not here. A `--target` run
# patches in place and skips this step entirely; there the live file IS the
# build, and the recognizer sends people to exactly that flag when it finds more
# than one image on PATH.
OUR_MARKER='baseURL:/^claude/i.test('
STAGED_FROM_LIVE=0
# First line only: a patched image prints tweakcc's version on a second line,
# and reading every line made the comparison below fail against any pristine
# copy -- refusing the default path outright.
# ЗАМЕРЕНО волной 48: `--version` МОЖЕТ отказать, и прежняя форма уносила
# прогон МОЛЧА. Под `set -euo pipefail` присваивание `V="$(img_ver X)"` --
# простая команда, и ненулевой код пайплайна (pipefail отдаёт код образа)
# убивал скрипт ПРЯМО НА НЁМ: неисполнимый файл давал 126 -- код, которого нет
# ни в одной таблице кита, -- и ни одного слова. Обе ветки «unreadable» ниже
# написаны ровно для этого случая и были НЕДОСТИЖИМЫ: до них не доходило.
# Пустая строка -- законный ответ «образ не назвался»; ПРИЧИНУ называет
# вызывающий, спрашивая диагност платформы.
# ЕДИНСТВЕННЫЙ ДОМ извлечения «первого слова первой строки». Эта форма стояла
# в ЧЕТЫРЁХ местах, и в каждом несла один и тот же скрытый отказ: `awk` уходит
# на первой строке, и вывод длиннее буфера трубы даёт `printf` EPIPE -- под
# `set -o pipefail` это код 141 у ВСЕЙ подстановки, а вызывающий читает её
# присваиванием и умирает молча. Замер волны 48 на обеих машинах (bash 3.2.57
# и 5.2.26): образ на 200 000 строк -> rc=141, ни слова в логе. Пояс `|| true`
# и есть то, что делает объявленный код 0 правдой на ЛЮБОЙ форме вызова.
__first_word() {   # <текст> -> первое слово его первой строки, либо ПУСТО; код ВСЕГДА 0
  printf '%s\n' "$1" | awk 'NR==1{print $1; exit}' || true
}

# ЕДИНСТВЕННЫЙ ДОМ чтения версии ИЗ БАЙТОВ образа (три двери tweakcc читали её
# каждая своей копией одной и той же трубы). Под `set -o pipefail` образ БЕЗ
# отметки версии даёт `grep` код 1, и на ПЛОСКОМ вызове это убивает прогон
# прямо на присваивании -- вместе с веткой «в байтах нет отметки версии»,
# написанной ровно для этого случая. Замер волны 48 на обеих машинах: плоский
# вызов rc=1 без единого слова, вызов из условия -- ветка достигается. То есть
# достижимость объявленной ветки принадлежала ФОРМЕ ВЫЗОВА, а не двери.
# stderr `grep` НЕ гасится: «нет такого файла» -- это причина, а не шум.
__ver_from_bytes() {   # <путь к образу> -> версия из байтов, либо ПУСТО; код ВСЕГДА 0
  LC_ALL=C grep -a -o -m1 '// Version: [0-9][0-9.]*' "$1" | head -1 | sed 's|// Version: ||' || true
}

img_ver() {   # <путь к образу> -> первое слово `--version`, либо ПУСТО; код ВСЕГДА 0
  local __out=""
  # stderr НЕ гасится и НЕ сливается в значение. Погасить -- потерять в ЗАМЕРЕ
  # единственные слова образа о том, почему он не запустился; слить в `__out`
  # -- отдать вызывающему сообщение загрузчика ВМЕСТО номера версии. Место
  # этих слов -- лог, и туда они и идут, мимо подстановки.
  __out="$("$1" --version)" || true
  __first_word "$__out"
}
# `--only-ours` is excluded on purpose. The hazard 0b exists for is handing
# tweakcc a patched image, and `--only-ours` never invokes tweakcc at all (the
# whole stage is behind ONLY_OURS below). Staging from the pristine copy there
# would instead REMOVE tweakcc's patches from the build and swap that in -- the
# opposite kind of loss, committed while preventing nothing. In place is right
# for that flag: our own patcher refuses loudly if the image already carries us.
if [[ -z "$TARGET" && $DO_UPDATE -eq 0 && $ONLY_OURS -eq 0 ]]; then
 if ! grep -q -a -F "$OUR_MARKER" "$BIN"; then
  # The live image is pristine. Preserve those bytes before building over them:
  # after the swap they are gone, and `.orig` is what the patched branch above
  # rebuilds from, what step 1b repairs tweakcc's backup from, and what the
  # kit's restore recipe hands out. A first run on a clean machine used to leave
  # none, so the SECOND run refused with "there is no pristine copy beside it".
  #
  # Replaced when it is missing, when it is not pristine, or when it is a twin
  # of a DIFFERENT build -- `.orig` means "the stock bytes of the file next to
  # it", and a leftover from an earlier version silently breaks both readers.
  ORIG_STATE=keep
  # Имя молчавшего образа -- отдельная переменная: `ORIG_STATE` несёт ТЕКСТ
  # для человека, а диагносту нужен ПУТЬ. Пусто = молчавших не было.
  ORIG_SILENT=""
  if [[ ! -f "$BIN.orig" ]]; then
    ORIG_STATE="missing"
  elif grep -q -a -F "$OUR_MARKER" "$BIN.orig" || grep -q -a -F 'tweakcc' "$BIN.orig"; then
    ORIG_STATE="not pristine"
  else
    # img_ver объявляет «код ВСЕГДА 0» (пояс || true у неё в теле): пусто --
    # законный ответ «образ не назвался», обе ветки -z ниже называют причину.
    LIVE_VER="$(img_ver "$BIN")" || true
    ORIG_VER="$(img_ver "$BIN.orig")" || true
    # ПРИЧИНА называется ИЗМЕРЕННАЯ. Слово «unreadable» одинаково описывало
    # битые байты и образ чужой платформы, а это РАЗНЫЕ поводы: у второго
    # чинить нечего. Действие ветки волна 48 не меняет -- только основание, --
    # потому что здесь `$BIN` уже признан пристинным, и класть его копию в
    # `.orig` законно при любой из причин. Волна 48.
    if [[ -z "$LIVE_VER" ]]; then
      ORIG_STATE="not comparable: the live image did not name its version"
      ORIG_SILENT="$BIN"
    elif [[ -z "$ORIG_VER" ]]; then
      ORIG_STATE="not comparable: $BIN.orig did not name its version"
      ORIG_SILENT="$BIN.orig"
    elif [[ "$LIVE_VER" != "$ORIG_VER" ]]; then
      ORIG_STATE="a twin of $ORIG_VER, not of $LIVE_VER"
    fi
  fi
  if [[ -n "$ORIG_SILENT" ]]; then
    echo "NOTE: $ORIG_SILENT did not name its version -- the twin check was not made." >&2
    __image_run_note "$ORIG_SILENT"
  fi
  if [[ "$ORIG_STATE" != keep ]]; then
    # Staged and renamed: a copy killed halfway leaves a TRUNCATED `.orig`, and
    # truncated bytes carry no marker -- so every later reader calls it pristine
    # and restores a broken binary while reporting success.
    if ! { cp -p "$BIN" "$BIN.orig.new" && mv "$BIN.orig.new" "$BIN.orig"; }; then
      rm -f "$BIN.orig.new"
      echo "ERROR: could not write the pristine copy $BIN.orig" >&2
      echo "  Refusing to build over the only stock bytes on this machine." >&2
      exit 1
    fi
    echo "Kept the live pristine bytes as $BIN.orig ($ORIG_STATE)"
  fi
  if ! cp -p "$BIN" "$BIN.staging"; then
    echo "ERROR: could not create $BIN.staging" >&2
    exit 1
  fi
  BIN="$BIN.staging"
  STAGED_FROM_LIVE=1
  echo "Live binary is pristine; building beside it into $BIN"
  echo "and swapping it in at the end."
 else
  # Same notion of pristine as 1b and claude_patch.py's _is_pristine: neither
  # our bytes nor tweakcc's. A copy carrying only tweakcc's stage passed the
  # our-marker test alone, and on a machine with no backup yet it is exactly
  # this file that becomes tweakcc's idea of the original.
  if [[ -f "$BIN.orig" ]] \
     && ! grep -q -a -F "$OUR_MARKER" "$BIN.orig" \
     && ! grep -q -a -F 'tweakcc' "$BIN.orig"; then
    # Adjacent name is not the same build. A `.orig` left over from an earlier
    # version -- easy on any install that keeps the binary under a FIXED name
    # rather than a versioned one -- would be staged, patched and renamed over
    # the live build: a silent DOWNGRADE presented as a rebuild. Ask both files
    # what they are; `--version` is offline and the pipeline already execs the
    # built image for the smoke check.
    # img_ver объявляет «код ВСЕГДА 0» (пояс || true у неё в теле): пусто --
    # законный ответ «образ не назвался», обе ветки -z ниже называют причину.
    LIVE_VER="$(img_ver "$BIN")" || true
    ORIG_VER="$(img_ver "$BIN.orig")" || true
    if [[ -z "$LIVE_VER" || -z "$ORIG_VER" || "$LIVE_VER" != "$ORIG_VER" ]]; then
      echo "ERROR: $BIN.orig is not a pristine copy of the live build." >&2
      echo "  live=${LIVE_VER:-unreadable}  pristine copy=${ORIG_VER:-unreadable}" >&2
      # «unreadable» -- НАБЛЮДЕНИЕ, а не причина, и совет ниже («поставь эту
      # версию») верен только для битых байтов: образу чужой платформы никакая
      # установка не поможет, там просто не та машина. Молчавший образ
      # называет СВОЮ причину сам. Волна 48.
      if [[ -z "$LIVE_VER" ]]; then
        __image_run_note "$BIN"
      fi
      if [[ -z "$ORIG_VER" ]]; then
        __image_run_note "$BIN.orig"
      fi
      echo "  Rebuilding from it would swap a different version over the live one." >&2
      echo "  Install the version you mean instead:" >&2
      echo "    bash claude-patch-all.sh --update ${LIVE_VER:-<version>}" >&2
      exit 1
    fi
    cp -p "$BIN.orig" "$BIN.staging"
    BIN="$BIN.staging"
    STAGED_FROM_LIVE=1
    echo "Live binary already carries our patches; rebuilding from the pristine copy"
    echo "into $BIN and swapping it in at the end."
  else
    echo "ERROR: the live binary is already patched and there is no pristine copy" >&2
    echo "  beside it ($BIN.orig is missing, or carries our patches or tweakcc's)." >&2
    echo "  Rebuilding in place would hand tweakcc a patched image and poison its" >&2
    echo "  backup. Re-install a pristine build instead:" >&2
    echo "    bash claude-patch-all.sh --update" >&2
    exit 1
  fi
 fi
fi
# The digest of what the build actually begins from. On `--target` and on a
# `--only-ours` run this is the file 0c already hashed; a staging copy is hashed
# again, because it is a different file and the announcement names a path.
if [[ $STAGED_FROM_LIVE -eq 1 ]]; then
  SOURCE_SHA="$(sha_of "$BIN")" || { printf 'ПРИБОР НЕДОСТУПЕН: не снята контрольная сумма источника сборки\n' >&2; exit 2; }
else
  SOURCE_SHA="$HANDED_SHA"
fi
echo "Source digest: $SOURCE_SHA  $BIN"

# The pristine twin of whatever we are building, for the backup guard below.
# Computed AFTER any staging swap and with the suffix stripped: on the --update
# path claude_patch.py leaves <version>.orig beside <version>.staging, never
# <version>.staging.orig, so "$BIN.orig" would name a file that never exists --
# and the repair would silently degrade to a warning on the one path where
# stock bytes are guaranteed to be at hand.
# ЕДИНСТВЕННЫЙ ДОМ снятия staging-суффикса. Установщик даёт ДВЕ формы:
# `<версия>.staging` -- стажирование живого файла (шаг 0b) -- и
# `<версия>.staging.<pid>`, когда версия уже лежит рядом: номер процесса разводит
# двух писателей. Суффикс снимали ТРИ места, и все три знали только первую форму.
# Замер 2026-09-01 на переходе 2.1.257: сборка ушла в `2.1.257.staging.24891`, и
# разошлось сразу всё -- пристинный близнец получил несуществующее имя (пол
# проверок ПРОПУЩЕН молча), переименование не сработало (пусковой лёг на
# промежуточный файл), а уборка приняла имя со staging за имя версии и снесла
# настоящие `2.1.257` и `2.1.257.orig`. Один дом вместо трёх копий формы.
__strip_staging() {
  local __p="$1"
  if [[ "$__p" =~ \.staging(\.[0-9]+)?$ ]]; then
    __p="${__p%"${BASH_REMATCH[0]}"}"
  fi
  printf '%s' "$__p"
}
__has_staging() { [[ "$1" =~ \.staging(\.[0-9]+)?$ ]]; }

# Дом объявленных непроходов tweakcc и их сверка с тем, что случилось.
# Зачем он нужен и почему слепой ручки мало -- в шапке самого файла.
TWEAKCC_KNOWN_MISSES="$HERE/tools/tweakcc-known-misses.txt"

# Сверка ДВУСТОРОННЯЯ. Односторонняя («пропускать объявленное») сделала бы из
# записи вечную индульгенцию: строка пережила бы свою причину и продолжала бы
# молча ослаблять гейт на всех будущих версиях. Поэтому объявленный, но НЕ
# случившийся непроход -- тоже отказ.
__tw_reconcile_misses() {
  local __out="$1" __bin="$2"
  # __comm_rc объявлена local намеренно: без этого она пережила бы вызов в
  # глобальной области, и следующий читатель `${__comm_rc:-0}` до первого
  # присваивания получил бы код ЧУЖОГО прогона вместо своего.
  local __ver __fa __fd __only_actual __only_declared __declared_rows __comm_rc=0
  # Слепая ручка ГАСИТ эту дверь, а не отменяет сверку. Прежде она отменяла:
  # вызов стоял только на ветке с выключенной ручкой, и вход «ручка=1,
  # крестиков нет, объявленный непроход НЕ случился» не печатал ничего --
  # объявление, пережившее свою причину, оставалось невидимым. Гашение обязано
  # быть объявленным и наблюдаемым, как у соседних дверей слоя.
  local __say="FATAL" __blind_rc=1
  if [[ "${CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES:-0}" == "1" ]]; then
    __say="NOTE"; __blind_rc=0
  fi
  # Версия берётся из БАЙТОВ образа, а не из переменной, заполняемой выше по
  # тексту: та присваивается только на одной ветке, и под `set -euo pipefail`
  # сверка на другой ветке уронила бы прогон по неопределённой переменной.
  # Байты же есть всегда, и это тот самый образ, о котором идёт речь. Запускать
  # его ради `--version` тут нельзя: на этой стадии он уже правлен и ещё не
  # переподписан.
  # __ver_from_bytes объявляет «код ВСЕГДА 0» (пояс || true в её теле): пусто
  # -- законный ответ, отказ ниже (regex на версию) называет случай сам.
  __ver="$(__ver_from_bytes "$__bin")" || true
  if [[ ! "$__ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    echo "$__say: сверка непроходов tweakcc не может назвать версию образа." >&2
    echo "  В байтах $__bin нет отметки версии, а запись объявленного непрохода" >&2
    echo "  привязана к версии -- без неё сверка молча не нашла бы ни одной." >&2
    if (( __blind_rc == 0 )); then
      echo "NOTE: CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 -- дверь сверки непроходов tweakcc погашена (версия образа не читается)" >&2
      return 0
    fi
    return 1
  fi
  # Отказ mktemp -- отказ ПРИБОРА, а не вердикт сверки, и кодом 1 его отдавать
  # нельзя: единица тут означает «непроходы разошлись», и вызывающий по ней
  # объявил бы расхождение, которого никто не измерял. Поэтому третий код 2,
  # который вызывающий (единственный, `if !` снят ради этого) разбирает
  # отдельно. Пустой путь проверяется своей строкой: он уходит в
  # перенаправления и в rm ниже.
  # Причину печатает МЕСТО отказа, а не вызывающий: код 2 отдают несколько
  # разных веток этой функции, и одна строка у вызывающего была бы верна лишь
  # для одной из них, а на остальных путях называла бы чужую причину.
  __fa="$(mktemp)" || { printf 'ПРИБОР НЕДОСТУПЕН: сверка непроходов tweakcc не получила временный файл\n' >&2; return 2; }
  __fd="$(mktemp)" || { rm -f "$__fa"; printf 'ПРИБОР НЕДОСТУПЕН: сверка непроходов tweakcc не получила второй временный файл\n' >&2; return 2; }
  if [[ -z "$__fa" || -z "$__fd" ]]; then
    rm -f "$__fa" "$__fd"
    printf 'ПРИБОР НЕДОСТУПЕН: mktemp вернул пустой путь временного файла сверки непроходов\n' >&2
    return 2
  fi
  # Разбор вывода ОДИН на весь кит -- __tw_layer_names. Вторая копия уже
  # разошлась с первой (LC_ALL=C не на всех ступенях, фильтра слоя нет вовсе),
  # и две двери сверяли бы разные множества одного вывода. Слой КОДА, а не оба:
  # предмет ЭТОЙ сверки -- поимённые непроходы правок кода, объявленные по
  # версии апстрима. Крестики слой промтов ПЕЧАТАЕТ (при сбое записи хэшей ими
  # помечается каждая легшая накладка), но у них свой владелец и своя дверь --
  # __tw_prompt_failed в __tw_check_applied_level; поимённого объявления по
  # версии у них нет, потому что каталог накладок принадлежит оператору.
  __tw_layer_names "$__out" code '✗' | LC_ALL=C sort -u > "$__fa"
  if [[ -f "$TWEAKCC_KNOWN_MISSES" ]]; then
    # BOM первой строки снимается ПЕРЕД разбором -- тем же приёмом, что у всех
    # прочих читателей объявлений кита: `[[:space:]]` метки порядка байтов не
    # берёт, и файл, сохранённый редактором с нею, терял бы первую строку
    # объявления молча -- то есть объявленный непроход читался бы как
    # необъявленный, а сборка отказывала бы по чужой причине.
    LC_ALL=C sed $'1s/^\xef\xbb\xbf//' "$TWEAKCC_KNOWN_MISSES" \
    | awk -F'\t' -v v="$__ver" '
      /^[[:space:]]*#/ { next } NF==0 { next }
      $1==v { gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); if ($2!="") print $2 }
    ' | sed '/^$/d' | sort -u > "$__fd"
  else
    : > "$__fd"
  fi
  # comm в роли сбора разности: код 1 -- не отказ (пустой ответ разбирают
  # проверки -n ниже), отказ прибора -- код выше единицы.
  # Отказ отдаётся КОДОМ 2, а не `exit`: функцию зовут без подоболочки, и
  # `exit` отсюда убил бы прогон на месте -- мимо уборки временных файлов
  # здесь и мимо разбора кода у вызывающего, то есть объявленный этой
  # функцией контракт трёх исходов был бы верен не для всех её веток.
  __only_actual="$(comm -23 "$__fa" "$__fd")" || __comm_rc=$?
  [ "${__comm_rc:-0}" -le 1 ] || { rm -f "$__fa" "$__fd"; printf 'ПРИБОР НЕДОСТУПЕН: разность непроходов не собрана (код %s)\n' "$__comm_rc" >&2; return 2; }
  __comm_rc=0
  __only_declared="$(comm -13 "$__fa" "$__fd")" || __comm_rc=$?
  [ "${__comm_rc:-0}" -le 1 ] || { rm -f "$__fa" "$__fd"; printf 'ПРИБОР НЕДОСТУПЕН: разность объявлений не собрана (код %s)\n' "$__comm_rc" >&2; return 2; }
  __comm_rc=0
  # У sed и awk НЕТ кода «не найдено»: ноль даже при пустом выводе (пусто --
  # «строк объявления нет», NOTE-блок ниже молчит), любое ненулевое -- отказ
  # чтения. Временные файлы сносятся здесь: после кода 2 вызывающий до их
  # уборки не доходит.
  __declared_rows="$(LC_ALL=C sed $'1s/^\xef\xbb\xbf//' "$TWEAKCC_KNOWN_MISSES" 2>/dev/null \
    | awk -F'\t' -v v="$__ver" '
      /^[[:space:]]*#/ { next } NF==0 { next }
      $1==v { printf "  %s -- %s\n", $2, $3 }
    ')" || { rm -f "$__fa" "$__fd"; printf 'ПРИБОР НЕДОСТУПЕН: строки объявленных непроходов не прочитаны\n' >&2; return 2; }
  rm -f "$__fa" "$__fd"

  local __bad=0
  if [[ -n "$__only_actual" ]]; then
    echo "$__say: правка tweakcc не легла, и она НЕ объявлена для $__ver:" >&2
    printf '%s\n' "$__only_actual" | sed 's/^/  ✗ /' >&2
    grep -E '^patch: ' "$__out" | sed 's/^/  /' >&2 || true
    echo "  Если это ожидаемо на этой версии -- впишите строку в" >&2
    echo "    $TWEAKCC_KNOWN_MISSES" >&2
    echo "  Слепая дверь на весь слой сразу: CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1" >&2
    __bad=1
  fi
  if [[ -n "$__only_declared" ]]; then
    echo "$__say: для $__ver объявлен непроход, которого НЕ СЛУЧИЛОСЬ:" >&2
    printf '%s\n' "$__only_declared" | sed 's/^/  /' >&2
    echo "  Правка легла -- значит причина записи ушла, а сама запись осталась" >&2
    echo "  и молча ослабляла бы гейт дальше. Снимите строку из" >&2
    echo "    $TWEAKCC_KNOWN_MISSES" >&2
    __bad=1
  fi
  if [[ -n "$__declared_rows" ]]; then
    echo "NOTE: объявленные непроходы tweakcc на $__ver (гейт держится на остальных):" >&2
    printf '%s\n' "$__declared_rows" >&2
  fi
  if [[ "$__say" == "NOTE" ]]; then
    # Гашение объявляется БЕЗ УСЛОВИЯ, как у соседних дверей слоя: строка,
    # замолкающая там, где гасить было нечего, от снятой двери неотличима.
    # Числа называют обе стороны сверки, обе -- измеренные.
    echo "NOTE: CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 -- дверь сверки непроходов tweakcc погашена (не объявлено $(printf '%s' "$__only_actual" | LC_ALL=C grep -a -c . || true), объявлено без непрохода $(printf '%s' "$__only_declared" | LC_ALL=C grep -a -c . || true))" >&2
    return $__blind_rc
  fi
  return $__bad
}

# Дом объявленного УРОВНЯ (сколько правок tweakcc ложится на версии) -- сосед
# дома непроходов, но предмет другой: там поимённые ✗, здесь количество ✓.
# Различие несёт всю нагрузку: когда данных под версию нет, правки не
# пробуются, крестиков нет ни одного, и для сверки непроходов версия
# выглядит чистой -- так падение 33 -> 14 прошло вердиктом «красных нет».
TWEAKCC_EXPECTED_APPLIED="$HERE/tools/tweakcc-expected-applied.txt"

# ИНЕРТНЫЕ правки -- те, что на этой версии не делают ничего: пропущенные по
# версии (⊘) и отработавшие вхолостую (≡). Сосед по владельцу, а не по дому
# машины: решает их пара «версия апстрима + реестр форка», ровно как и число
# попыток. Потому объявление лежит в репозитории кита, рядом с попытками, и
# ездит между машинами вместе с ним. Дом множества ВЫКЛЮЧЕННЫХ правок другой
# (config.json дома tweakcc) именно потому, что там владелец -- машина.
#
# Объявляются ИМЕНА, а не числа. Равный итог не означает равного состава:
# обмен одного инертного имени на другое счёт не двигает, и дверь на числе
# такую подмену пропускает молча (урок соседних дверей кита).
TWEAKCC_EXPECTED_INERT="$HERE/tools/tweakcc-expected-inert.txt"

# Владелец числа -- КОНВЕЙЕР. Свип считает своё поле из лога и остаётся
# потребителем: путь --update, которым образ попадает человеку, свипом не
# проходит вовсе, и оставить счёт только там значило бы не прикрыть его ничем.
# Крестики tweakcc принадлежат ДВУМ слоям с РАЗНЫМИ владельцами, и один счёт на
# оба гейтил число, которое меняет чужая рука. Слой кода принадлежит версии
# апстрима и нашему форку; слой промтов -- каталогу накладок ПОЛЬЗОВАТЕЛЯ
# (~/.tweakcc/system-prompts). Размер того каталога движется, и
# число здесь замер, а не пин: на 04.09 в нём 989 записей -- 875 накладок
# `.md` и 114 сгенерированных `.diff.html`, метку ccVersion несёт каждая.
# Первая редакция этой строки сказала 988 и разошлась с каталогом за сутки:
# ровно поэтому дверь промтов держит ПОЛ, а не равенство.)
# Пин суммы измеренно неустойчив: 2.1.259 дала 34 в 00:35 и 33 в 10:03 на
# неизменном образе -- разошёлся слой промтов, а краснела дверь кита.
# Слой опознаётся СЕКЦИЕЙ вывода, а не префиксом имени правки. Имя принадлежит
# ОПЕРАТОРУ: у накладки оно взято из frontmatter `name:` файла в
# $TWEAKCC_HOME/system-prompts, и кит этой величиной не владеет -- фильтр по
# имени уводил бы в счёт КОДА любую накладку, названную не по типу, то есть
# красил бы сборку на всех версиях от переименования в ЧУЖОМ каталоге и называл
# бы причиной реестр форка. Секцию же печатает сам форк. Перечисления ниже --
# полное перечисление его PatchGroup; секция, которой в них нет, обязана
# ОТКАЗАТЬ (__tw_unsectioned_lines), а не разойтись по двум счётам молча.
# Разделитель перечисления -- ТАБУЛЯЦИЯ, а не вертикальная черта: `split()` в
# awk принимает третий аргумент как РЕГЕКСП, и одиночная «|» разбирается
# буквально лишь по свойству реализации, а не по гарантии текста. Табуляция
# метасимволом регекспа не является нигде.
__TW_CODE_SECTIONS='Always Applied	Misc Configurable	Features'
__TW_PROMPT_SECTIONS='System Prompts'

# Разбор вывода живёт в ОДНОМ подключаемом файле на весь кит: те же строки
# считает свип, и его вторая реализация уже разошлась с этой (без фильтра знаков
# и без части ступеней LC_ALL=C). Отсутствие файла -- отказ ДО первой правки:
# без разбора счётчики вернули бы нули, а нули читаются дверями как «слоя нет».
# Код 6 -- «машинерия»: ломается договор между нашими же двумя файлами.
if [[ ! -f "$HERE/tools/tw-layer.sh" ]]; then
  echo "FATAL: не найден $HERE/tools/tw-layer.sh -- разбор вывода tweakcc подключать неоткуда." >&2
  echo "  Кит скопирован не целиком: слой tweakcc нечем измерить, а пустые счётчики" >&2
  echo "  прошли бы вердиктом «слоя нет»." >&2
  exit 6
fi
# shellcheck source=tools/tw-layer.sh
source "$HERE/tools/tw-layer.sh"

# Обёртка над общим разбором: здесь остаётся ТОЛЬКО выбор перечисления по слою.
# <вывод> <code|prompt> <класс знаков, напр. '✓' или "$TW_MARKS"> -> ИМЕНА по строке
__tw_layer_names() {
  local __out="$1" __layer="$2" __marks="$3" __secs
  if [[ "$__layer" == "code" ]]; then __secs="$__TW_CODE_SECTIONS"; else __secs="$__TW_PROMPT_SECTIONS"; fi
  tw_layer_names "$__out" "$__secs" "$__marks"
}

# Часовой формы вывода: строки правок вне известных секций И строки под
# известной секцией с незнакомым знаком. Оба вида не принадлежат ни одному
# счёту; молчаливое отнесение первых к любому слою вернуло бы отказ по чужой
# причине, а вторые исчезали бы из всех счётов разом.
# <вывод> -> строки-нарушители
__tw_unsectioned_lines() {
  tw_unsectioned_lines "$1" "$(printf '%s	%s' "$__TW_CODE_SECTIONS" "$__TW_PROMPT_SECTIONS")"
}

# Строк результата ЛЮБОГО знака, по ОБОИМ слоям и в области якоря.
# «Вывод нечитаем» -- это НОЛЬ строк любого из пяти знаков, а не отсутствие
# ✓ и ✗: на версии, где ничего не легло и не упало (всё ○/⊘/≡), вывод разобран
# полностью, а сырой образец `^    [✓✗] ` объявлял его непрочитанным.
__tw_result_rows_total() {    # <вывод tweakcc> -> строк результата, оба слоя
  { __tw_layer_names "$1" code "$TW_MARKS"; __tw_layer_names "$1" prompt "$TW_MARKS"; } \
    | LC_ALL=C grep -a -c . || true
}

# Имена НЕ ЛЁГШИХ правок ОБОИХ слоёв -- носителем разбора, а не сырым образцом.
# Слепая ручка печатает этот перечень, и сырой `grep '^    ✗ '` брал бы строки
# и вне области якоря (предапплайный список плана), и вне известных секций.
__tw_failed_any_names() {     # <вывод tweakcc> -> имена ✗ обоих слоёв
  { __tw_layer_names "$1" code '✗'; __tw_layer_names "$1" prompt '✗'; } || true
}

# ПРЕДБАННИК слоя: якорь блока результатов задаёт ОБЛАСТЬ всем читателям, и
# потому проверяется ДО всех дверей, а не внутри одной из них. Прежде он стоял
# внутри двери уровня, и сверка непроходов -- она считает ✗ по той же области --
# успевала отказать раньше: на сменившемся якоре область пуста, крестиков нет, и
# оператора посылали снять ДЕЙСТВУЮЩЕЕ объявление непрохода, тогда как истинная
# причина жила в двери, до которой прогон не дошёл.
#
# Двусторонне: ноль якорей -- форк сменил строку, открывающую блок (область
# пуста, все счёта врут нулём); два и больше -- в один счёт попали две сборки.
__tw_check_anchor() {         # <вывод tweakcc> -> 0 область определена, 1 отказ
  local __out="$1" __n
  # tw_results_anchor_count не отказывает (awk || echo 0 в её теле): любое
  # не-число обнуляется ниже, а «не ровно один якорь» -- сам ответ двери.
  __n="$(tw_results_anchor_count "$__out")" || true; __n="${__n//[^0-9]/}"
  [[ -n "$__n" ]] || __n=0
  if [[ "${CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES:-0}" == "1" ]]; then
    if (( __n != 1 )); then
      echo "NOTE: CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 -- дверь якоря блока результатов tweakcc погашена (якорей $__n, а нужен ровно один)" >&2
    fi
    return 0
  fi
  if (( __n != 1 )); then
    echo "FATAL: якорь блока результатов tweakcc встречается $__n раз, а нужен ровно один." >&2
    echo "  Якорь: «${TW_RESULTS_ANCHOR}»" >&2
    if (( __n == 0 )); then
      echo "  Форк сменил строку, открывающую блок результатов. Без неё разбор" >&2
      echo "  берёт ПУСТУЮ область: легло 0, попыток 0, и дверь уровня обвинила" >&2
      echo "  бы реестр форка вместо формы вывода." >&2
      echo "  Дом якоря -- tools/tw-layer.sh (TW_RESULTS_ANCHOR); сверьте его с" >&2
      echo "  src/index.tsx форка и поправьте в одном месте." >&2
    else
      echo "  В один вывод попало несколько прогонов tweakcc: счёта сложились бы" >&2
      echo "  по двум сборкам сразу, и любое сравнение с объявлением потеряло бы" >&2
      echo "  смысл." >&2
    fi
    return 1
  fi
  return 0
}

# Дверь ЧИТАЕМОСТИ вывода: разобрана ли вообще хоть одна строка результата.
# Предмет -- положительный контроль всем счётам ниже: не увидев ни одной строки
# ЛЮБОГО знака, мы не прочли вывод, и отсутствие ✗ ничего не доказывает.
#
# Гашение слепой ручкой ОБЪЯВЛЯЕТСЯ: прежде эта дверь под ручкой не печатала
# ничего и была неотличима от снятой (вход: ручка=1, tweakcc вышел нулём, форк
# сменил форму вывода -- не исполнялась ни одна ветка).
__tw_check_result_rows() {    # <вывод tweakcc> -> 0 вывод прочитан, 1 отказ
  local __out="$1" __seen
  # __tw_result_rows_total не отказывает (пояс || true в её теле): пусто --
  # ноль строк, обнуление ниже и дверь читаемости -- весь разбор.
  __seen="$(__tw_result_rows_total "$__out")" || true; __seen="${__seen//[^0-9]/}"
  [[ -n "$__seen" ]] || __seen=0
  if [[ "${CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES:-0}" == "1" ]]; then
    echo "NOTE: CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 -- дверь читаемости вывода tweakcc погашена (строк результата $__seen)" >&2
    return 0
  fi
  if (( __seen == 0 )); then
    echo "FATAL: could not read tweakcc's apply output -- no result rows found." >&2
    echo "  Ни одной строки со знаком из набора «${TW_MARKS}» в области блока" >&2
    echo "  результатов: либо в конфиге нет ни одной правки, либо форк сменил" >&2
    echo "  форму вывода, и КАЖДЫЙ счёт слоя ниже посчитан по пустоте." >&2
    echo "  Inspect: $__out" >&2
    echo "  Set CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 to build anyway." >&2
    return 1
  fi
  return 0
}

__tw_applied_code_level() {   # <вывод tweakcc> -> число легших КОД-правок
  __tw_layer_names "$1" code '✓' | LC_ALL=C grep -a -c . || true
}

__tw_applied_prompt_level() { # <вывод tweakcc> -> число легших ПРОМТ-накладок
  __tw_layer_names "$1" prompt '✓' | LC_ALL=C grep -a -c . || true
}

# Предмет двери -- НАБОР ПОПЫТОК, а не число удач. Правка, выключенная
# конфигурацией дома tweakcc, не печатает ни ✓, ни ✗: она исчезает из вывода
# целиком, и счёт удач меняется от настройки ПОЛЬЗОВАТЕЛЯ, а объявлен как
# свойство ВЕРСИИ. Измерено на втором контуре: тот же кит и та же версия дали
# «объявлено 13, легло 14», и единственной разницей был пользовательский
# символ спиннера в зеркале дома. Попытка печатается всегда -- ✓ легло,
# ✗ не легло, ○ выключено конфигурацией, -- поэтому их сумма принадлежит
# паре «версия + форк» и не зависит от машины. Кружки видны только под
# --show-unchanged, и потому конвейер зовёт tweakcc с этим ключом: без него
# выключенная правка неотличима от исчезнувшей.
__tw_attempted_code_level() { # <вывод tweakcc> -> число ПОПЫТОК по слою кода
  __tw_layer_names "$1" code "$TW_MARKS" | LC_ALL=C grep -a -c . || true
}

# Не легло -- ✗ слоя КОДА, считанные ПРЯМО. Прежде число выводилось вычитанием
# (попытки минус легло минус выключено), и всякий новый исход попытки уезжал бы
# в него молча: пропущенная по версии правка числилась бы непрошедшей.
__tw_failed_code_level() {    # <вывод tweakcc> -> число НЕ ЛЕГШИХ правок кода
  __tw_layer_names "$1" code '✗' | LC_ALL=C grep -a -c . || true
}

# Пропущенные по ВЕРСИИ: правка, которой эта версия апстрима не несёт вовсе.
# Владелец -- пара «версия + форк», как у самого числа попыток, и потому
# объявление лежит в репозитории кита, а не в доме машины.
__tw_vskip_code_names() {     # <вывод tweakcc> -> имена ПРОПУЩЕННЫХ ПО ВЕРСИИ
  __tw_layer_names "$1" code '⊘' | LC_ALL=C sort -u || true
}

# Холостые: правка ПРОБОВАЛАСЬ и не изменила ничего. Это НЕ обязательно промах
# локатора: в форке есть умышленный ранний возврат «на этой версии делать
# нечего» (src/patches/worktreeMode.ts:29 -- изоляция worktree уже в сборке;
# src/patches/mcpStartup.ts:130 -- затвор, ради которого правка жила, из сборки
# ушёл). Безусловный отказ на ≡ краснил бы здоровый прогон (замерено на
# 2.1.261), поэтому предмет двери -- ОБЪЯВЛЕННЫЙ НАБОР ИМЁН, как у соседей, а
# не сам факт знака.
__tw_noop_code_names() {      # <вывод tweakcc> -> имена ХОЛОСТЫХ правок кода
  __tw_layer_names "$1" code '≡' | LC_ALL=C sort -u || true
}

# Объявленные ИМЕНА инертных правок для пары «версия + знак».
# Читатель тот же, что у соседей: BOM первой строки, трим каждого поля,
# комментарии и пустые строки пропускаются. Пустое имя не объявляет ничего и
# в набор не попадает -- иначе строка-заготовка гасила бы дверь.
# <версия> <знак> -> ИМЕНА по строке, отсортированы
__tw_inert_declared() {
  LC_ALL=C sed $'1s/^\xef\xbb\xbf//' "$TWEAKCC_EXPECTED_INERT" 2>/dev/null \
    | awk -F'\t' -v v="$1" -v s="$2" '
        /^[[:space:]]*#/ { next } NF==0 { next }
        {
          k=$1; gsub(/^[[:space:]]+|[[:space:]]+$/,"",k)
          m=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",m)
          nm=$3; gsub(/^[[:space:]]+|[[:space:]]+$/,"",nm)
          if (k==v && m==s && nm!="") print nm
        }
      ' | LC_ALL=C sort -u || true
}

# Строки объявления для версии -- СЫРЫЕ, до отбора по знаку и до sort -u.
# Нужны двум проверкам, которых набор имён уже не видит: дублю пары
# «версия+знак+имя» (sort -u схлопнул бы его молча) и пустому полю причины.
# <версия> -> строки «знак<TAB>имя<TAB>причина»
__tw_inert_rows() {
  LC_ALL=C sed $'1s/^\xef\xbb\xbf//' "$TWEAKCC_EXPECTED_INERT" 2>/dev/null \
    | awk -F'\t' -v v="$1" '
        /^[[:space:]]*#/ { next } NF==0 { next }
        {
          k=$1; gsub(/^[[:space:]]+|[[:space:]]+$/,"",k)
          if (k!=v) next
          m=$2;  gsub(/^[[:space:]]+|[[:space:]]+$/,"",m)
          nm=$3; gsub(/^[[:space:]]+|[[:space:]]+$/,"",nm)
          wh=$4; gsub(/^[[:space:]]+|[[:space:]]+$/,"",wh)
          print m "\t" nm "\t" wh
        }
      ' || true
}

# Крестики слоя ПРОМТОВ. Их не читал никто: сверка непроходов разбирает слой
# кода, а комментарий над ней утверждал, что слой промтов крестиков не печатает
# вовсе. Печатает: при сбое записи хэшей (src/patches/systemPrompts.ts) форк
# помечает непрошедшей КАЖДУЮ легшую накладку, и весь слой уходит в ✗.
__tw_prompt_failed() {        # <вывод tweakcc> -> число НЕ ЛЕГШИХ накладок
  __tw_layer_names "$1" prompt '✗' | LC_ALL=C grep -a -c . || true
}

# Имена выключенных правок берутся ТЕМ ЖЕ носителем, что и имена непроходов у
# сверки выше: два читателя одного вывода, разошедшиеся в разборе, дали бы двум
# дверям разные множества, и объявление дома сходилось бы с одним из них через
# раз. Здесь -- слой кода: кружок накладки принадлежит каталогу оператора.
__tw_off_code_names() {       # <вывод tweakcc> -> имена ВЫКЛЮЧЕННЫХ правок кода
  __tw_layer_names "$1" code '○' | LC_ALL=C sort -u || true
}

# Разность двух наборов имён: что есть в первом и чего нет во втором.
# Пустая строка на входе не даёт пустого имени (`grep -a .`): иначе разность
# «пусто против пусто» вернула бы одно фантомное имя и дверь отказала бы там,
# где обе стороны согласны.
# <имена A> <имена B> -> имена A \ B
__tw_names_minus() {
  LC_ALL=C comm -23 \
    <(printf '%s\n' "$1" | LC_ALL=C grep -a . | LC_ALL=C sort -u) \
    <(printf '%s\n' "$2" | LC_ALL=C grep -a . | LC_ALL=C sort -u) || true
}

# Пересечение двух наборов имён -- сосед разности по той же дисциплине:
# пустая строка на входе не даёт фантомного имени.
# <имена A> <имена B> -> имена A ∩ B
__tw_names_both() {
  LC_ALL=C comm -12 \
    <(printf '%s\n' "$1" | LC_ALL=C grep -a . | LC_ALL=C sort -u) \
    <(printf '%s\n' "$2" | LC_ALL=C grep -a . | LC_ALL=C sort -u) || true
}

# Сверка ОДНОГО знака инертности: измеренный набор имён против объявленного.
# Обе стороны обязательны, и причины у них разные:
#   измеренное без строки -- форк перестал что-то делать на этой версии, и это
#     прошло бы молча (ровно тот отказ в тишине, ради которого дверь и живёт);
#   строка без измеренного -- запись пережила свою причину и продолжала бы
#     прикрывать будущую пропажу, то есть стала бы бессрочной индульгенцией.
#
# Сторона «объявлено, но не измерено» РАСЩЕПЛЕНА ПО ПРИЧИНАМ: правка снова
# работает, правка ушла из реестра форка, исход сменился на другой знак. Общая
# формулировка «(или ушла из реестра форка)» смешивала владельцев в одной
# строке, а лечение называла одно на все три случая.
# <версия> <знак> <человеческое имя> <измеренные> <объявленные> <вывод> -> 0 сошлось, 1 отказ
__tw_inert_check_sign() {
  local __v="$1" __s="$2" __human="$3" __got="$4" __want="$5" __out="$6"
  local __miss __extra __alive __gone __swapped __bad=0
  # Обе разности не отказывают (пояс || true в __tw_names_minus): пусто --
  # «множества согласны», проверки -n ниже читают именно его.
  __miss="$(__tw_names_minus "$__got" "$__want")" || true
  __extra="$(__tw_names_minus "$__want" "$__got")" || true
  if [[ -n "$__miss" ]]; then
    # Фигурные скобки ОБЯЗАТЕЛЬНЫ: за подстановкой идёт не-ASCII кавычка, и bash
    # в не-UTF8 локали (так его зовут зубы) втягивает её первый байт в ИМЯ
    # переменной -- под `set -u` это «unbound variable», а не сообщение.
    echo "FATAL: на $__v есть правки tweakcc «${__human}», которых нет в объявлении:" >&2
    printf '%s\n' "$__miss" | LC_ALL=C sed -n "1,10s/^/  $__s /p" >&2 || true
    echo "  Форк перестал делать это на данной версии, а объявления у пропажи нет." >&2
    echo "  Разберитесь с причиной; если так и задумано -- впишите строки в" >&2
    echo "    $TWEAKCC_EXPECTED_INERT" >&2
    echo "  Вид строки: <версия><TAB>$__s<TAB><имя правки><TAB><причина>." >&2
    return 1
  fi
  [[ -n "$__extra" ]] || return 0
  # ВЛАДЕЛЕЦ ЗНАКА РЕШАЕТ, ЧЕМ ГЕЙТИТСЯ ЭТА СТОРОНА.
  #
  # ⊘ машинонезависим: в цикле применения форка проверка версии стоит ПЕРЕД
  # проверкой конфига, и знак решает пара «версия апстрима + реестр форка» --
  # обе стороны отказывают.
  #
  # ≡ достижим ТОЛЬКО там, где конфиг оператора оставил правку включённой:
  # skipKind:'config' (○) отсекает раньше исполнения. Владельцев у него трое,
  # и потому сторона «объявлено, но не измерено» ослаблена РОВНО на исход ○:
  # оператор выключил тумблер в интерфейсе форка -- штатное действие, а исход
  # уже гейтится двусторонне дверью множества выключенных, чей дом -- машина
  # ($TWEAKCC_EXPECTED_OFF). Всякий ДРУГОЙ исход отказывает: имя, измеренное
  # под ⊘ и объявленное ещё и как ≡, иначе жило бы в объявлении бессрочно.
  if [[ "$__s" == '≡' ]]; then
    # Разность и перечень выключенных не отказывают (пояс || true в их
    # телах): пусто -- «исход ○ объясняет всё», возврат ниже именно это и
    # означает.
    __extra="$(__tw_names_minus "$__extra" "$(__tw_off_code_names "$__out")")" || true
    [[ -n "$__extra" ]] || return 0
  fi
  # Пересечение и оба чтения слоя не отказывают (пояс || true в их телах):
  # пусто -- «не работает и не падала», расклад веток ниже его разбирает.
  __alive="$(__tw_names_both "$__extra" \
    "$( { __tw_layer_names "$__out" code '✓'; __tw_layer_names "$__out" code '✗'; } )")" || true
  # Разность/слой не отказывают (пояс || true в их телах): пусто -- «имя
  # не измерено ни под одним знаком», что ветка ниже и называет.
  __gone="$(__tw_names_minus "$__extra" "$(__tw_layer_names "$__out" code "$TW_MARKS")")" || true
  # Разность не отказывает (пояс || true в __tw_names_minus): пусто --
  # «остатка нет», проверка -n ниже читает именно его.
  __swapped="$(__tw_names_minus "$(__tw_names_minus "$__extra" "$__alive")" "$__gone")" || true
  if [[ -n "$__alive" ]]; then
    echo "FATAL: на $__v объявлены правки tweakcc «${__human}», а они снова работают:" >&2
    printf '%s\n' "$__alive" | LC_ALL=C sed -n "1,10s/^/  $__s /p" >&2 || true
    echo "  Правка вернулась к жизни: на этой версии она измерена как ✓ либо ✗," >&2
    echo "  то есть делает что-то, а строка продолжала бы прикрывать её пропажу." >&2
    echo "  Снимите строки из $TWEAKCC_EXPECTED_INERT" >&2
    __bad=1
  fi
  if [[ -n "$__gone" ]]; then
    echo "FATAL: на $__v объявлены правки tweakcc «${__human}», которых нет в реестре форка:" >&2
    printf '%s\n' "$__gone" | LC_ALL=C sed -n "1,10s/^/  $__s /p" >&2 || true
    echo "  Имени нет в выводе форка ни под одним знаком: правка ушла из реестра," >&2
    echo "  и объявлять её инертной больше не о чем." >&2
    echo "  Снимите строки из $TWEAKCC_EXPECTED_INERT" >&2
    __bad=1
  fi
  if [[ -n "$__swapped" ]]; then
    echo "FATAL: на $__v правки tweakcc объявлены как «${__human}», а измерены под другим знаком:" >&2
    printf '%s\n' "$__swapped" | LC_ALL=C sed -n "1,10s/^/  $__s /p" >&2 || true
    echo "  Имя в выводе есть, но исход у него другой: равный итог не означает" >&2
    echo "  равного состава, и строка под прежним знаком осталась без причины." >&2
    echo "  Поправьте знак строки в $TWEAKCC_EXPECTED_INERT" >&2
    __bad=1
  fi
  # Отказ ПОСЛЕ всех трёх блоков: расхождение бывает встречным, и ранний
  # возврат назвал бы человеку одну его часть, отправив чинить дважды.
  return $__bad
}

__tw_prompt_notfound() {      # <вывод tweakcc> -> число НЕ НАЙДЕННЫХ накладок
  # Промах слоя промтов печатается НЕ крестиком, а отдельной строкой
  # «Could not find system prompt "..."», и сверка непроходов (она разбирает
  # только «✗ ») его не видит. Без этого счёта 24 промаха на 2.1.259 уходили
  # в тишину, а единственным выходом оператора было опустить пин -- то есть
  # стереть сигнал.
  # ЗАМЕР не глушит свой stderr (волна t106): вывод tweakcc стал нечитаем --
  # погашенная ошибка grep выходила пустой строкой, и дверь уровня читала
  # «не найдено 0» на сломанном приборе, то есть ложное зелёное. Соседние
  # замеры слоя -- `__tw_prompt_outage` и `__tw_prompt_dl_error` (задачи
  # #101/#105) -- stderr не гасят; этот приведён под тот же закон.
  # `|| true` остаётся: `grep -c` без совпадений возвращает 1, и это не ошибка.
  LC_ALL=C grep -a -c 'Could not find system prompt' "$1" || true
}

# ОБВАЛ слоя промтов опознаётся ПАРОЙ игл, и обе -- ASCII-подстроки. Символ
# «⚠», с которого форк начинает обе строки, в иглу НЕ берётся намеренно: не-ASCII
# под `grep -a -c` на двоичном входе даёт ложный ноль, и различитель обвала стал
# бы молчать ровно тогда, когда он нужен.
#
# Игл две, потому что обе строки печатает ОДИН И ТОТ ЖЕ `if (!preloadResult
# .success)` (форк на пине 943beb9: src/index.tsx:467-475 -- путь применения,
# и :873-880 -- путь интерактивного старта). Раз их печатает одно условие, их
# счета обязаны сходиться; расхождение -- смена формы у форка, а не обвал, и
# называется отдельным словом.
__tw_prompt_outage() {        # <вывод tweakcc> -> строк «слой промтов недоступен»
  LC_ALL=C grep -a -c -F 'System prompts not available' "$1" || true
}
__tw_prompt_dl_error() {      # <вывод tweakcc> -> строк «снимок промтов не скачался»
  LC_ALL=C grep -a -c -F 'Error downloading system prompts' "$1" || true
}

# ВЫКЛЮЧЕННЫЙ слой промтов -- ТРЕТЬЕ состояние рядом с «слой лёг» и «слой
# обвалился», и различает их ровно эта игла. Слой накладок не несёт НИ ОДНОГО
# нашего текста (замер 12.09: из 901 накладки дома «наших» ноль при рабочем
# контроле класса), а промты у нас пишет мод во время исполнения; форк на пине
# 943beb9 умеет выключать ОБЕ половины слоя ручкой TWEAKCC_NO_SYSTEM_PROMPTS.
#
# ЗАЧЕМ ИГЛА, А НЕ ЗНАНИЕ КИТА О СВОЕЙ ЖЕ ПОДСТАНОВКЕ. Выключенный слой даёт
# нули во ВСЕХ счётах слоя, и эти нули сходятся с любым объявлением пола и с
# нулевым умолчанием конфликтов. Ноль, у которого причина не названа В ВЫВОДЕ
# ФОРКА, вакуумен: он одинаково описывает «выключили» и «форк проигнорировал
# ручку». Игла берёт причину оттуда, где её печатает САМ измеряемый, -- это
# тот же закон, по которому обвал опознаётся строкой форка, а не догадкой кита.
#
# Литерал ASCII и через `grep -F`: не-ASCII под `grep -a -c` на двоичном входе
# даёт ложный ноль, а в строке форка есть скобки, которые как регексп означали
# бы группу.
__tw_prompt_layer_off() {     # <вывод tweakcc> -> строк «слой промтов ВЫКЛЮЧЕН ручкой»
  LC_ALL=C grep -a -c -F 'System prompt layer DISABLED by TWEAKCC_NO_SYSTEM_PROMPTS' "$1" || true
}

# Число КОНФЛИКТНЫХ накладок синхронизации. Строку печатает распаковщик при
# синхронизации каталога накладок с определениями апстрима (форк на пине
# 943beb9: src/systemPromptSync.ts:1890, displaySyncResults), когда накладка
# разошлась с текущим определением и он не смог решить за пользователя сам.
# Игла -- литерал через `grep -F`: в строке есть круглые скобки («file(s)»), и
# экранировать их под регексп -- лишняя поверхность отказа на строке, которую
# форк печатает буквально. Единица названа в имени функции: КОНФЛИКТНЫХ
# НАКЛАДОК (файлов), а не строк предупреждения -- число стоит ВНУТРИ строки, и
# счёт по строкам считал бы десять конфликтов одной строкой одним. Числа всех
# совпавших строк складываются: форк печатает строку один раз с итогом, и
# повтор её означал бы ту же величину, а не новые конфликты. Строки нет вовсе
# -- конфликтов ноль (awk печатает ноль из пустого входа), и это ИЗМЕРЕННЫЙ
# ноль: синхронизация бежала и конфликтов не нашла.
__tw_prompt_conflicts() {     # <вывод tweakcc> -> число КОНФЛИКТНЫХ накладок
  # Тот же закон, что у счёта не-найденных выше: ЗАМЕР не глушит свой stderr
  # (волна t106). Погашенная ошибка чтения уходила бы нулём сквозь awk, и
  # дверь конфликтов печатала бы «сходится» на сломанном приборе. Соседние
  # `__tw_prompt_outage`/`__tw_prompt_dl_error` stderr не гасят -- этот
  # приведён под тот же закон; `|| true` в хвосте трубы остаётся по своей
  # прежней причине (grep без совпадений -- не ошибка).
  LC_ALL=C grep -a -F 'WARNING: Conflicts detected for' "$1" \
    | LC_ALL=C sed -n 's/.*Conflicts detected for \([0-9][0-9]*\) system prompt file.*/\1/p' \
    | LC_ALL=C awk '{ s += $1 } END { print s + 0 }' || true
}

# Различитель ПУБЛИКАЦИИ снимка промтов. Отвечает на один вопрос -- лежит ли
# снимок этой версии у апстрима -- и ответ форка («слой не лёг») им НЕ
# подменяется: это разные вопросы, и дверь ниже держит их порознь.
#
# Зачем он: у обвала слоя две РАЗНЫЕ причины -- апстрим не опубликовал снимок и
# ЭТОТ хозяин не смог его скачать, -- а форк печатает на обе один и тот же
# текст. Без отдельного замера дверь называла первую причину в обоих случаях и
# советовала «повторить, когда появится» там, где снимок уже лежит (#101,
# замер 09.09 на usbox: «curl» отдаёт 200, а глобальный fetch node без
# NODE_USE_ENV_PROXY=1 уходит напрямую и падает по таймауту соединения).
#
# `curl` уже перечислен в REQUIRED_TOOLS -- новой зависимости здесь нет. Код
# 000 curl печатает, когда соединения не было вовсе: это ТРЕТИЙ класс, и
# смешать его с «нет снимка» значило бы вернуть ту же ложь в новом месте.
__tw_snapshot_probe() {       # <адрес> -> класс публикации
  local __url="$1" __code
  command -v curl >/dev/null 2>&1 || { printf 'нечем\n'; return 0; }
  # Пояс || true уже стоит ВНУТРИ подстановки: код сети (включая 000) -- сам
  # предмет измерения, различитель ниже разбирает его по классам.
  __code="$(curl -s -o /dev/null -w '%{http_code}' \
              --connect-timeout 10 --max-time 30 "$__url" || true)" || true
  __code="${__code//[^0-9]/}"
  case "$__code" in
    200)    printf 'опубликован\n' ;;
    404)    printf 'не-опубликован\n' ;;
    000|'') printf 'сеть-недоступна\n' ;;
    *)      printf 'неясно-%s\n' "$__code" ;;
  esac
}

# Дверь ОБВАЛА слоя промтов.
#
# Снимок промтов апстрима качается ПО ВЕРСИИ, и на свежем релизе его может ещё
# не быть: форк печатает свою пару строк и идёт дальше, а все три счёта слоя
# выходят нулями -- ровно теми же, что у машины, где слоя нет вовсе. Без этой
# двери ветка пола читала бы (0,0,0) как «сходится» и пропускала бы сборку, у
# которой не легло НИ ОДНОЙ накладки; а её соседка предлагала бы вписать
# измеренный ноль полом -- то есть узаконить обвал навсегда, и следующий
# прогон, когда снимок появится, покраснел бы уже на ПОДЪЁМЕ числа.
#
# КОД ВОЗВРАТА У ДВЕРИ НЕ ОДИН, И ЭТО КОНСТРЕЙНТ. Не отказ (1) -- версия не
# сломана. Но и не один код на все ветки: у двери ПЯТЬ причин и ТРИ разных
# действия, а действие выбирается по коду.
#   7 -- «апстрим не опубликовал»: снаружи, пройдёт само, тот же прогон на той
#        же версии зазеленеет без единой правки. Потребитель обязан считать
#        версию НЕ ИЗМЕРЕННОЙ и ждать, а не красить её красным.
#   6 -- «снимок опубликован, но этот хозяин не скачал» и «соединения не было»:
#        сломано ОКРУЖЕНИЕ хозяина, и по таблице кита это ровно 6 -- повтор без
#        починки даст тот же отказ.
#   2 -- «различителя нет» и «различитель ответил неожиданным»: не установлена
#        сама ПРИЧИНА, то есть не мерит прибор, а не предмет.
# До волны 47 все пять веток возвращали 2, и свип красил обвал апстрима как
# красную версию с причиной «контракт вызова нарушен или прибор гейта не
# мерил» -- то есть отправлял человека искать поломку там, где ждать надо было
# апстрима. Одно имя на три предмета -- тот же дефект, что кит уже чинил
# расколом ручки пропуска стендов (#74).
__tw_prompt_outage_door() {   # <версия> <вывод tweakcc> <легло> <не найдено> <не легло>
  local __ver="$1" __out="$2" __prompts="$3" __nf="$4" __pfail="$5"
  local __outage __outage_dl __out_exists __snap __url __proxy_seen __v __rc
  __out_exists=1
  [[ -f "$__out" ]] || __out_exists=0
  if (( __out_exists == 0 )); then
    echo "FATAL: вывод tweakcc ($__out) исчез до разбора слоя промтов -- мерить нечем." >&2
    return 2
  fi
  # Оба счётчика обвала не отказывают (grep -c || true в их телах): пусто --
  # ноль, обнуление ниже и ветка «>0» -- весь разбор обвала.
  __outage="$(__tw_prompt_outage "$__out")" || true;      __outage="${__outage//[^0-9]/}"
  __outage_dl="$(__tw_prompt_dl_error "$__out")" || true; __outage_dl="${__outage_dl//[^0-9]/}"
  [[ -n "$__outage" ]] || __outage=0
  [[ -n "$__outage_dl" ]] || __outage_dl=0
  (( __outage > 0 || __outage_dl > 0 )) || return 0
  echo "FATAL: слой промтов на $__ver ОБВАЛИЛСЯ, а не отсутствует: форк объявил," >&2
  echo "  что снимок системных промтов недоступен, и пропустил весь слой." >&2
  echo "  Измерено: легло накладок $__prompts, не найдено $__nf, не легло $__pfail." >&2
  echo "  Эти нули принадлежат ОБВАЛУ, а не пустому слою, поэтому пол по ним" >&2
  echo "  НЕ объявляется: вписанный сейчас ноль узаконил бы обвал навсегда." >&2
  if (( __outage == 0 || __outage_dl == 0 )); then
    echo "  ВНИМАНИЕ: две строки обвала печатает одно условие форка, а счета" >&2
    echo "  разошлись (недоступность $__outage, ошибка скачивания $__outage_dl)" >&2
    echo "  -- у форка сменилась форма сообщения, иглы двери устарели." >&2
  fi
  __url="https://raw.githubusercontent.com/Piebald-AI/tweakcc/refs/heads/main/data/prompts/prompts-$__ver.json"
  # __tw_snapshot_probe не отказывает по построению (пояс || true на curl и
  # case, печатающий класс всегда): «нечем» -- сам объявленный класс.
  __snap="$(__tw_snapshot_probe "$__url")" || true
  # Умолчание стоит ДО разбора: ветка, забывшая назвать свой код, обязана
  # уехать «не мерит», а не нулём -- ноль здесь значил бы «обвала нет».
  __rc=2
  case "$__snap" in
    не-опубликован)
      __rc=7
      echo "  ПРИЧИНА: апстрим ещё НЕ ОПУБЛИКОВАЛ снимок этой версии (адрес отвечает 404)." >&2
      echo "  Ждать: тот же прогон на той же версии зазеленеет сам, когда снимок появится." >&2
      ;;
    опубликован)
      __rc=6
      echo "  ПРИЧИНА: снимок ОПУБЛИКОВАН (адрес отвечает 200) -- скачать не смог ЭТОТ хозяин." >&2
      echo "  Ждать НЕЧЕГО: повтор без починки загрузки даст тот же отказ." >&2
      __proxy_seen=""
      for __v in https_proxy HTTPS_PROXY http_proxy HTTP_PROXY all_proxy ALL_PROXY; do
        if [[ -n "${!__v:-}" ]]; then __proxy_seen="$__proxy_seen $__v"; fi
      done
      if [[ -n "$__proxy_seen" ]]; then
        echo "  В окружении заданы прокси-переменные:$__proxy_seen -- «curl» их читает," >&2
        echo "  а глобальный fetch node (undici) НЕТ, и ходит форк именно им. Первое," >&2
        echo "  что стоит проверить: тот же прогон с NODE_USE_ENV_PROXY=1." >&2
      else
        echo "  Прокси-переменных в окружении нет -- причина в сетевом доступе хозяина." >&2
      fi
      ;;
    сеть-недоступна)
      __rc=6
      echo "  ПРИЧИНА: с этой машины не вышел НИ ОДИН запрос (соединения не было)." >&2
      echo "  Опубликован снимок или нет -- отсюда не видно; чинить надо доступ в сеть." >&2
      ;;
    нечем)
      __rc=2
      echo "  ПРИЧИНА НЕ УСТАНОВЛЕНА: на этом хозяине нет «curl», и различить" >&2
      echo "  «апстрим не опубликовал» от «не смог скачать» нечем. «curl» перечислен" >&2
      echo "  в REQUIRED_TOOLS -- дверь предбанника обязана была отказать раньше." >&2
      ;;
    *)
      # ФИГУРНЫЕ СКОБКИ ОБЯЗАТЕЛЬНЫ. Кавычка-ёлочка -- многобайтовая, и bash 3.2
      # затягивает её первый байт в ИМЯ переменной: «$__snap» читается как
      # обращение к `__snap<0xC2>`, под `set -u` это отказ «unbound variable»
      # ровно в ветке, куда попадают неожиданные ответы. Измерено 10.09 пробой
      # ветки «нет curl»; та же ловушка уже описана в этом файле на строке про
      # `«$want»`.
      __rc=2
      echo "  ПРИЧИНА НЕ УСТАНОВЛЕНА: различитель публикации ответил «${__snap}»." >&2
      echo "  Отличить «апстрим не опубликовал» от «не смог скачать» этим прогоном нечем." >&2
      ;;
  esac
  echo "  Адрес снимка: $__url" >&2
  # Код называется ВСЛУХ: потребитель выбирает действие по нему, и человек,
  # читающий лог, должен видеть тот же признак, что и машина.
  case "$__rc" in
    7) echo "  КОД ВОЗВРАТА 7: не измерено ВНЕШНЕЙ причиной, которая пройдёт сама -- ждать апстрим, не чинить." >&2 ;;
    6) echo "  КОД ВОЗВРАТА 6: сломано окружение ЭТОГО хозяина -- повтор без починки даст тот же отказ." >&2 ;;
    *) echo "  КОД ВОЗВРАТА $__rc: причина обвала НЕ УСТАНОВЛЕНА -- не мерит прибор, а не предмет." >&2 ;;
  esac
  return "$__rc"
}

__tw_check_applied_level() {
  local __out="$1" __bin="$2"
  local __ver __code __prompts __nf __want_tried __want_prompts
  local __unsect __unsect_n __floor_rows __floor_said __floor_why
  local __pfail __noop __noop_n __vskip __vskip_n __loff
  local __inert_dups __inert_nowhy __inert_noname __inert_bad
  # Якорь блока результатов задаёт ОБЛАСТЬ всем счётам ниже, и его дверь стоит
  # в общем предбаннике (__tw_check_anchor) ПЕРЕД этой и перед сверкой
  # непроходов: обе читают ту же область, и держать дверь внутри одной из них
  # значило пускать вторую считать по пустоте.
  # Часовой формы снимается ДО счёта: пока строки правок лежат вне известных
  # секций, считать нечего -- они разъехались бы по слоям молча. Сам ОТКАЗ
  # ниже, в зоне отказов: расклад печатается всегда, а слепая ручка гасит и
  # его, как гасит соседние двери.
  # Все счётчики ниже не отказывают (пояс || true в телах хелперов): пусто --
  # измеренный ноль, обнуление строкой ниже -- часть разбора.
  __unsect="$(__tw_unsectioned_lines "$__out")" || true
  __unsect_n="$(printf '%s' "$__unsect" | LC_ALL=C grep -a -c . || true)"
  __unsect_n="${__unsect_n//[^0-9]/}"
  [[ -n "$__unsect_n" ]] || __unsect_n=0
  # Счётчики уровня/промтов/промахов: пусто -- ноль (пояс || true в телах
  # хелперов), обнуление ниже -- часть разбора.
  __code="$(__tw_applied_code_level "$__out")" || true;      __code="${__code//[^0-9]/}"
  __prompts="$(__tw_applied_prompt_level "$__out")" || true; __prompts="${__prompts//[^0-9]/}"
  __nf="$(__tw_prompt_notfound "$__out")" || true;           __nf="${__nf//[^0-9]/}"
  [[ -n "$__code" ]] || __code=0
  [[ -n "$__prompts" ]] || __prompts=0
  [[ -n "$__nf" ]] || __nf=0
  echo "tweakcc: легло $(( __code + __prompts )) правок (кода $__code, промтов $__prompts)" >&2
  local __tried __off __failed
  # __tw_attempted_code_level не отказывает (пояс || true в её теле): пусто --
  # ноль попыток, обнуление ниже и двери «просела/выросла» -- весь разбор.
  __tried="$(__tw_attempted_code_level "$__out")" || true; __tried="${__tried//[^0-9]/}"
  [[ -n "$__tried" ]] || __tried=0
  echo "tweakcc: попыток по слою кода $__tried, из них легло $__code" >&2
  # Расклад попытки: легло + выключено конфигурацией + пропущено по версии +
  # вхолостую + не легло. Одно число попыток не отличает просевший форк от
  # чужого конфига, поэтому дверь печатает расклад, а гейтит сумму.
  __off="$(__tw_off_code_names "$__out" | LC_ALL=C grep -a -c . || true)"
  __off="${__off//[^0-9]/}"
  [[ -n "$__off" ]] || __off=0
  # Каждый исход считается СВОИМ классом знака. Вычитание («попытки минус
  # легло минус выключено») приписывало бы непроходам любой новый исход, какой
  # заведёт форк, -- и число «не легло» врало бы, не сдвинув ни одной двери.
  # __tw_failed_code_level не отказывает (пояс || true в её теле): пусто --
  # ноль, обнуление ниже -- часть разбора.
  __failed="$(__tw_failed_code_level "$__out")" || true; __failed="${__failed//[^0-9]/}"
  [[ -n "$__failed" ]] || __failed=0
  # __tw_prompt_failed не отказывает (пояс || true в её теле): пусто -- ноль,
  # обнуление ниже и дверь непрошедших -- весь разбор.
  __pfail="$(__tw_prompt_failed "$__out")" || true; __pfail="${__pfail//[^0-9]/}"
  [[ -n "$__pfail" ]] || __pfail=0
  # Перечни имён не отказывают (пояс || true в телах хелперов): пусто --
  # «имён нет», счёт -c ниже и проверки -n -- весь разбор.
  __noop="$(__tw_noop_code_names "$__out")" || true
  __noop_n="$(printf '%s' "$__noop" | LC_ALL=C grep -a -c . || true)"
  __noop_n="${__noop_n//[^0-9]/}"
  [[ -n "$__noop_n" ]] || __noop_n=0
  __vskip="$(__tw_vskip_code_names "$__out")" || true
  __vskip_n="$(printf '%s' "$__vskip" | LC_ALL=C grep -a -c . || true)"
  __vskip_n="${__vskip_n//[^0-9]/}"
  [[ -n "$__vskip_n" ]] || __vskip_n=0
  if (( __nf > 0 )); then
    # Счёт непопавших накладок НЕ гейтится, и это не поблажка, а владелец:
    # число растёт и от поломки форка, и от того, что пользователь добавил
    # накладку с чужим текстом. Регресс ловится с ДРУГОЙ стороны -- полом
    # легших промтов ниже: добавление накладки пол не пробивает никогда, а
    # поломка форка роняет число легших. Здесь -- видимость.
    echo "NOTE: накладок промтов не нашлось в образе: $__nf (текст накладки разошёлся с апстримом; каталог накладок принадлежит пользователю, не киту)" >&2
    # Список печатается ПОСТРОЧНО тем же образцом, каким считан счётчик выше:
    # счёт по строкам и перечень по вхождениям разошлись бы на строке с двумя
    # сообщениями, и лог соврал бы числом, которое сам же и печатает.
    #
    # Печатается ИМЯ накладки, а не сырая строка, по двум причинам. Первая:
    # сырая строка несёт весь регекс апстрима (тысячи байт) и обрезалась по
    # БАЙТАМ -- под LC_ALL=C обрез приходился на середину многобайтного
    # символа и в лог уходил обломок. Вторая: сырая строка содержит образец,
    # по которому промахи считает свип, и перечень удваивал ему поле.
    # Неразобранная строка (апстрим сменил форму) идёт отдельной веткой: с
    # неё не-ASCII снимается ЦЕЛИКОМ, поэтому обрез по байтам равен обрезу по
    # символам. Ни одна ветка не начинается образцом tweakcc с начала строки.
    # Перечень -- ОБЪЯСНЕНИЕ счёта `__tw_prompt_notfound`, и ветка ПЕЧАТИ
    # обязана быть такой же честной, как ветка СЧЁТА (волна t106, доводка):
    # с погашенным stderr недоступный вывод дал бы ПУСТОЙ перечень,
    # неотличимый от «промахов нет», -- и оператор читал бы поломку прибора
    # как чистый замер. Пояс у самого grep не нужен: он голова трубы, код
    # всей трубы уже принадлежит `|| true` в хвосте, и отсутствие совпадений
    # ветку не роняет (проверено прогоном под set -euo pipefail).
    LC_ALL=C grep -a 'Could not find system prompt' "$__out" \
    | while IFS= read -r __ln; do
        # У sed нет кода «не найдено»: без совпадения -- ноль и пусто (ветка
        # «строка не разобрана» ниже), ненулевое -- отказ прибора.
        __nm="$(printf '%s' "$__ln" | LC_ALL=C sed -n 's/.*Could not find system prompt "\([^"]*\)".*/\1/p')" || { printf 'ПРИБОР НЕДОСТУПЕН: имя ненайденной накладки не извлечено\n' >&2; return 2; }
        if [[ -n "$__nm" ]]; then
          echo "  не найдена накладка: $__nm"
        else
          echo "  не найдена накладка (строка не разобрана, не-ASCII снят): $(printf '%s' "$__ln" | LC_ALL=C tr -d '\200-\377' | cut -c1-160)"
        fi
      done >&2 || true
  fi
  if [[ "${CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES:-0}" == "1" ]]; then
    # Гашение слепой ручкой ОБЪЯВЛЯЕТСЯ, как объявляется у ✗: дверь, снятая
    # молча, неотличима от двери, которая держится. Ручка гасит НЕСКОЛЬКО
    # дверей, и у каждой погашенной -- своя строка: одно общее «уровень погашен»
    # умалчивало о том, что вместе с ним снят и часовой формы, и обе двери
    # исходов. Ранний возврат стоит ниже всех этих строк, потому что после него
    # не печатается уже ничего.
    #
    # Все строки БЕЗ УСЛОВИЯ (дверь якоря объявляет своё гашение в предбаннике):
    # голос двери читает не только человек, но и поле вердикта свипа, а поле,
    # замолкающее на части законных прогонов, отличить от снятой двери нельзя.
    # Числа в строке и так называют, что именно погашено -- нули говорят
    # «гасить было нечего».
    echo "NOTE: CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 -- часовой формы вывода tweakcc погашен (строк вне известных секций либо с незнакомым знаком: $__unsect_n)" >&2
    echo "NOTE: CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 -- дверь непрошедших накладок tweakcc погашена (не легло накладок $__pfail)" >&2
    echo "NOTE: CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 -- дверь инертных правок tweakcc погашена (пропущено по версии $__vskip_n, вхолостую $__noop_n)" >&2
    echo "NOTE: CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 -- дверь уровня tweakcc погашена (попыток $__tried, легло $__code, промтов $__prompts)" >&2
    return 0
  fi
  # Версия -- из БАЙТОВ образа, по той же причине, что и в сверке непроходов:
  # переменная выше по тексту присваивается только на одной ветке. Снимается
  # ЗДЕСЬ, до первого отказа этой двери: версию называют и голоса часового
  # формы и двери накладок, а они стоят выше объявленного уровня.
  # Слепая ручка проходит ВЫШЕ по тексту и до сюда не доходит: образ без
  # отметки версии она гасит вместе со всеми дверями, как и обещает.
  # __ver_from_bytes объявляет «код ВСЕГДА 0»: пусто -- законный ответ, отказ
  # ниже (regex на версию) называет случай сам.
  __ver="$(__ver_from_bytes "$__bin")" || true
  if [[ ! "$__ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    echo "FATAL: дверь уровня tweakcc не может назвать версию образа." >&2
    echo "  В байтах $__bin нет отметки версии, а объявленный уровень привязан" >&2
    echo "  к версии -- без неё дверь молча не нашла бы ни одной строки." >&2
    return 1
  fi
  # Незнакомая секция -- ОТКАЗ, а не тихое отнесение строки к слою кода: слой
  # различается секцией, и строка, у которой секции нет, не принадлежит ни
  # одному счёту. Отказ идёт сразу за предбанником якоря: на разъехавшемся
  # выводе любое число ниже посчитано не о том.
  if [[ -n "$__unsect" ]]; then
    echo "FATAL: строки правок tweakcc, не принадлежащие ни одному счёту:" >&2
    printf '%s\n' "$__unsect" | LC_ALL=C sed -n '1,10s/^/  /p' >&2 || true
    echo "  форк tweakcc сменил форму печати: либо завёл незнакомую группу (слои" >&2
    # Фигурные скобки ОБЯЗАТЕЛЬНЫ: за подстановкой идёт не-ASCII кавычка, и bash
    # в не-UTF8 локали втягивает её первый байт в ИМЯ переменной -- под `set -u`
    # это «unbound variable», а не сообщение (гейт форм оболочки, тот же урок,
    # что у сообщения об уровне ниже).
    echo "  различаются по секции), либо знак вне набора «${TW_MARKS}» (такую строку" >&2
    echo "  не считает ни один класс, и попытка исчезла бы из всех счётов разом)." >&2
    return 1
  fi
  # Голос двери на успехе -- БЕЗ УСЛОВИЯ, той же формы, что у двери уровня,
  # множества и инертных: дверь, молчащая на здоровом прогоне, побайтово
  # неотличима от снятой, и поле вердикта свипа (twform) читает именно эту
  # строку. Число -- ИЗМЕРЕННОЕ, а не литерал: на отказе выше оно не ноль.
  echo "NOTE: часовой формы строк tweakcc на $__ver: строк вне известных секций $__unsect_n" >&2
  # Крестики слоя ПРОМТОВ. Читателя у них не было вовсе, и полный обвал слоя --
  # накладки легли, а форк объявил их непрошедшими -- проходил молча. Типовой
  # источник: сбой записи хэшей, после которого КАЖДАЯ легшая накладка помечена
  # непрошедшей, а следующий прогон накладывает её повторно. Поимённого
  # объявления по версии здесь нет намеренно: каталог накладок принадлежит
  # оператору, и объявление по версии красило бы вторую машину.
  if (( __pfail > 0 )); then
    echo "FATAL: накладки промтов tweakcc объявлены НЕ ЛЕГШИМИ: $__pfail" >&2
    __tw_layer_names "$__out" prompt '✗' | LC_ALL=C sed -n '1,10s/^/  ✗ /p' >&2 || true
    echo "  Текст накладки лёг в образ, но форк объявил её непрошедшей -- типовой" >&2
    echo "  источник этого расхождения -- сбой записи хэшей накладок" >&2
    echo "  ($TWEAKCC_HOME/systemPromptAppliedHashes.json): следующий прогон наложит" >&2
    echo "  ту же накладку повторно. Разберитесь с причиной; слепая ручка на весь" >&2
    echo "  слой сразу: CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1" >&2
    return 1
  fi
  # Голос двери накладок на успехе -- БЕЗ УСЛОВИЯ, по той же причине, что и у
  # часового формы выше: поле вердикта свипа (twpfail) читает эту строку, и
  # молчание на здоровом прогоне неотличимо от снятой двери.
  echo "NOTE: накладки промтов tweakcc на $__ver: объявленных не легшими $__pfail" >&2
  # Инертные правки (⊘ и ≡) гейтятся ниже, ПОИМЁННО и по версии: набор
  # принадлежит паре «версия + реестр форка». Безусловного отказа на знак здесь
  # нет намеренно -- см. комментарий у __tw_noop_code_names.
  # Одна версия -- одна строка. Читатель ниже берёт ПЕРВОЕ совпадение и
  # выходит; при двух строках вторая (та, которую правил человек) молча не
  # действует, и объявление расходится с дверью незаметно -- ровно тот отказ
  # в тишине, ради которого дверь и заводилась.
  # BOM первой строки снимается ПЕРЕД тримом -- тем же приёмом, что у читателей
  # пола: `[[:space:]]` метки порядка байтов не берёт, и файл из редактора давал
  # бы «версия не объявлена» на строке, которая на экране выглядит правильной.
  # У sed и awk нет кода «не найдено»: ноль даже при пустом выводе (пусто --
  # ноль строк, awk печатает n+0), ненулевое -- отказ чтения.
  __rows="$(LC_ALL=C sed $'1s/^\xef\xbb\xbf//' "$TWEAKCC_EXPECTED_APPLIED" 2>/dev/null \
    | awk -F'\t' -v v="$__ver" '
      /^[[:space:]]*#/ { next } NF==0 { next }
      { k=$1; gsub(/^[[:space:]]+|[[:space:]]+$/,"",k); if (k==v) n++ }
      END { print n+0 }
    ')" || { printf 'ПРИБОР НЕДОСТУПЕН: строки объявленного уровня не прочитаны\n' >&2; return 2; }
  if (( __rows > 1 )); then
    echo "FATAL: в $TWEAKCC_EXPECTED_APPLIED на $__ver приходится строк: $__rows." >&2
    echo "  Читатель берёт первую и выходит -- остальные не действуют." >&2
    echo "  Оставьте на версию ровно одну строку." >&2
    return 1
  fi
  # Ключ сверяется ТРИМЛЕННЫМ, как и оба числа: иначе строка, вписанная с
  # отступом, читается как чужая версия и дверь отвечает «не объявлен».
  # Пусто при нулевом коде -- «уровень не объявлен» (отказ ниже разбирает);
  # ненулевое у sed/awk -- отказ чтения, кода «не найдено» у них нет.
  __want_tried="$(LC_ALL=C sed $'1s/^\xef\xbb\xbf//' "$TWEAKCC_EXPECTED_APPLIED" 2>/dev/null \
    | awk -F'\t' -v v="$__ver" '
      /^[[:space:]]*#/ { next } NF==0 { next }
      { k=$1; gsub(/^[[:space:]]+|[[:space:]]+$/,"",k) }
      k==v { gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit }
    ')" || { printf 'ПРИБОР НЕДОСТУПЕН: объявленный уровень кода не прочитан\n' >&2; return 2; }
  if [[ -z "$__want_tried" ]]; then
    echo "FATAL: для $__ver уровень tweakcc не объявлен, а измерено: попыток $__tried, промтов $__prompts." >&2
    echo "  Уровень к версии не переносится: данные апстрима у каждой свои." >&2
    if (( __rows == 0 && __tried == 0 )); then
      # Готовой строки здесь НЕТ: измеренный ноль -- не уровень, а след
      # сломанного прибора, и вклеенная строка «версия<TAB>0» закрыла бы дверь
      # на нуле навсегда (сошлось бы 0=0 при исчезнувшем слое кода).
      echo "  Измерено НОЛЬ попыток, и готовой строки для вклейки здесь нет:" >&2
      echo "  слой кода из десятков правок не может иметь ноль попыток. Ноль" >&2
      echo "  означает, что разбор взял пустую область либо форк не дошёл до" >&2
      echo "  печати результатов -- разберитесь с причиной, а не с объявлением." >&2
    elif (( __rows == 0 )); then
      echo "  Взгляните на числа один раз и впишите строку в" >&2
      echo "    $TWEAKCC_EXPECTED_APPLIED" >&2
      echo "  Строка ниже -- ровно в том виде, в каком её читает дверь: без" >&2
      echo "  отступа, поля разделены табуляцией." >&2
      printf '%s\t%s\t<причина/происхождение числа>\n' "$__ver" "$__tried" >&2
    else
      # Строка на версию ЕСТЬ, пусто поле. Совет «впишите строку» дал бы вторую
      # строку на версию, и следующий прогон отказал бы уже по дублю -- отказ
      # обязан называть то, что сломано, а не отправлять чинить в тупик.
      echo "  Строка на $__ver в файле ЕСТЬ, но поле кода в ней пусто -- правьте" >&2
      echo "  её, не добавляйте вторую: две строки на версию дверь отвергает." >&2
      echo "  Вид строки: <версия><TAB><попыток кода><TAB><причина>." >&2
      echo "  Измерено сейчас: попыток $__tried, промтов $__prompts." >&2
    fi
    return 1
  fi
  if [[ ! "$__want_tried" =~ ^[0-9]+$ ]]; then
    # Фигурные скобки ОБЯЗАТЕЛЬНЫ: за подстановкой идёт не-ASCII кавычка, и bash
    # в не-UTF8 локали (так его зовут зубы) втягивает её первый байт в ИМЯ
    # переменной -- под `set -u` это «unbound variable», а не сообщение.
    echo "FATAL: в $TWEAKCC_EXPECTED_APPLIED уровень кода для $__ver не число: «${__want_tried}»." >&2
    return 1
  fi
  # У числа есть ПОЛ, и он не ноль. Слой кода -- это десятки правок форка, и
  # ноль попыток не бывает уровнем: он бывает следом сломанного прибора
  # (пустая область разбора, оборванный прогон форка). Без этой ветки объявление
  # «0» сходилось бы с измеренным нулём, инертные -- пустотой, множество --
  # пустотой, и прогон с ИСЧЕЗНУВШИМ слоем кода уходил бы зелёным.
  if (( __want_tried == 0 )); then
    echo "FATAL: в $TWEAKCC_EXPECTED_APPLIED объявленный уровень кода для $__ver -- ноль." >&2
    echo "  Ноль -- не уровень: реестр форка несёт десятки правок, и попытка" >&2
    echo "  печатается при любом исходе. Строка с нулём закрывает дверь навсегда:" >&2
    echo "  она сходится с исчезнувшим слоем кода обеими сторонами." >&2
    echo "  Снимите строку и разберитесь, откуда взялся ноль (измерено сейчас:" >&2
    echo "  попыток $__tried)." >&2
    return 1
  fi
  # Слой КОДА гейтится ПОПЫТКАМИ, а не удачами. У числа удач ТРИ владельца:
  # реестр форка (сколько правок ПРОБУЕТСЯ), версия апстрима (какие не легли --
  # ✗, их разбирает сверка непроходов) и дом tweakcc ЭТОЙ машины (какие
  # выключены конфигурацией -- ○, их разбирает дверь множества ниже). Число
  # удач -- остаток после вычитания двух чужих множеств, а объявлено оно как
  # свойство версии: на втором контуре тот же кит и та же версия дали
  # «объявлено 13, легло 14» из-за одного пользовательского символа спиннера.
  # Попытка же печатается при любом исходе, и её счёт принадлежит паре
  # «версия + форк» целиком. Двусторонне: и просадка, и прибавка означают,
  # что объявление разошлось с реестром.
  if (( __tried < __want_tried )); then
    echo "FATAL: слой кода tweakcc просел на $__ver: объявлено попыток $__want_tried, пробовалось $__tried." >&2
    echo "  Столбец объявляет РАЗМЕР РЕЕСТРА форка: попытка печатается при любом" >&2
    echo "  исходе (легло, не легло, выключено конфигурацией, пропущено по версии," >&2
    echo "  отработало вхолостую), и просадка означает, что реестр разошёлся со" >&2
    echo "  строкой -- правка исчезла из форка, а строка осталась. Разберитесь с" >&2
    echo "  причиной либо, если реестр форка изменился осознанно, поправьте" >&2
    echo "  строку в $TWEAKCC_EXPECTED_APPLIED" >&2
    return 1
  fi
  if (( __tried > __want_tried )); then
    echo "FATAL: на $__ver кода пробовалось БОЛЬШЕ объявленного: объявлено $__want_tried, пробовалось $__tried." >&2
    echo "  Объявление пережило причину с другой стороны: реестр форка вырос" >&2
    echo "  (правку добавили), а строка осталась прежней и продолжала бы прикрывать" >&2
    echo "  будущую пропажу. Поднимите число в" >&2
    echo "    $TWEAKCC_EXPECTED_APPLIED" >&2
    return 1
  fi
  # ИНЕРТНЫЕ правки -- ПОИМЁННО и ДВУСТОРОННЕ, по обоим знакам сразу.
  #
  # Инертная -- это ⊘ (версия правку не несёт вовсе) и ≡ (правка пробовалась и
  # не изменила ни байта). Оба знака означают «на этой версии делать нечего», и
  # оба принадлежат паре «версия + реестр форка» -- потому объявление одно и
  # лежит в репозитории кита.
  #
  # Объявляются ИМЕНА, а не числа: равный итог не означает равного состава --
  # обмен одного инертного имени на другое счёт не двигает, и дверь на числе
  # пропустила бы подмену молча.
  #
  # Дубль пары «версия+знак+имя» -- отказ ДО сверки наборов: sort -u в читателе
  # схлопнул бы вторую строку, и правка человека молча не действовала бы.
  # Пусто при нулевом коде -- законное «дублей нет» (проверка -n ниже);
  # ненулевое у sed/awk/sort -- отказ чтения, кода «не найдено» нет.
  __inert_dups="$(__tw_inert_rows "$__ver" \
    | LC_ALL=C awk -F'\t' '{ k=$1 "\t" $2; c[k]++ } END { for (k in c) if (c[k] > 1) print k }' \
    | LC_ALL=C sort)" || { printf 'ПРИБОР НЕДОСТУПЕН: дубли инертных строк не прочитаны\n' >&2; return 2; }
  if [[ -n "$__inert_dups" ]]; then
    echo "FATAL: в $TWEAKCC_EXPECTED_INERT на $__ver пара «знак + имя» объявлена дважды:" >&2
    printf '%s\n' "$__inert_dups" | LC_ALL=C sed -n '1,10s/^/  /p' >&2 || true
    echo "  Одна пара «версия+знак+имя» -- одна строка: вторую читатель схлопывает," >&2
    echo "  и правка в ней не влияет ни на что." >&2
    return 1
  fi
  # Причина ОБЯЗАТЕЛЬНА -- тот же зуб, что у пола промтов: строку нельзя
  # вклеить, не написав, откуда взялось её содержимое. Пустое поле и
  # оставленный дословно текст-заготовка равны по последствиям и отвергаются
  # оба.
  # Пусто при нулевом коде -- законный «нет строк», отказ ниже его и гейтит;
  # ненулевое у sed/awk -- отказ чтения, кода «не найдено» нет.
  __inert_nowhy="$(__tw_inert_rows "$__ver" \
    | LC_ALL=C awk -F'\t' '$3 == "" || $3 == "<причина>" || $3 == "<причина/происхождение>" { print $1 "\t" $2 }')" || { printf 'ПРИБОР НЕДОСТУПЕН: строки без причины не прочитаны\n' >&2; return 2; }
  if [[ -n "$__inert_nowhy" ]]; then
    echo "FATAL: в $TWEAKCC_EXPECTED_INERT на $__ver есть строки без названной причины:" >&2
    printf '%s\n' "$__inert_nowhy" | LC_ALL=C sed -n '1,10s/^/  /p' >&2 || true
    echo "  Инертность без причины не принимается: строка объявляет, что правка" >&2
    echo "  на этой версии не делает ничего, и это утверждение обязано назвать," >&2
    echo "  откуда оно взято (замер, срез апстрима, решение по реестру форка)." >&2
    return 1
  fi
  # Пустое ИМЯ -- отказ той же формы, что дубль и пустая причина. Строка с
  # пустым именем не объявляет ничего: набор имён её отбрасывает (nm!=""), а
  # наличие СТРОК под версию уводит дверь в ветку сверки, и на пустом измерении
  # она печатала «сошлись с объявлением: 0, 0». Заготовку с незаполненным именем
  # так можно было вклеить и погасить дверь целиком.
  # Пусто при нулевом коде -- законный «нет строк» (awk печатает пустоту),
  # отказ ниже его и гейтит; ненулевое у sed/awk -- отказ чтения.
  __inert_noname="$(__tw_inert_rows "$__ver" \
    | LC_ALL=C awk -F'\t' '$2 == "" { print $1 "\t" $3 }')" || { printf 'ПРИБОР НЕДОСТУПЕН: строки без имени не прочитаны\n' >&2; return 2; }
  if [[ -n "$__inert_noname" ]]; then
    echo "FATAL: в $TWEAKCC_EXPECTED_INERT на $__ver есть строки без ИМЕНИ правки:" >&2
    printf '%s\n' "$__inert_noname" | LC_ALL=C sed -n '1,10s/^/  /p' >&2 || true
    echo "  Объявляются ИМЕНА: строка без имени не сверяется ни с чем, но делает" >&2
    echo "  объявление на версию непустым -- дверь уходит в сверку наборов и на" >&2
    echo "  пустом измерении отвечает «сошлись»." >&2
    echo "  Вид строки: <версия><TAB><знак><TAB><имя правки><TAB><причина>." >&2
    return 1
  fi
  # __tw_inert_rows не отказывает (пояс || true в её теле): пусто -- «строк
  # объявления нет», обе ветки ниже разбирают именно его.
  __inert_any="$(__tw_inert_rows "$__ver")" || true
  if [[ -z "$__inert_any" ]]; then
    if [[ -z "$__vskip" && -z "$__noop" ]]; then
      # Сходимость, а не отказ: пустое объявление и пустое измерение согласны
      # обеими сторонами. Отказ здесь красил бы версию, на которой ничего не
      # сломано, -- урок пустого дома свипа.
      echo "NOTE: инертных правок tweakcc на $__ver не объявлено и не измерено -- сходится." >&2
    else
      echo "FATAL: для $__ver инертные правки tweakcc не объявлены, а измерены: ⊘ $__vskip_n, ≡ $__noop_n." >&2
      echo "  Набор принадлежит паре «версия + форк»: к соседней версии он не" >&2
      echo "  переносится. Взгляните на строки один раз и впишите их в" >&2
      echo "    $TWEAKCC_EXPECTED_INERT" >&2
      echo "  Строки ниже -- ровно в том виде, в каком их читает дверь: без" >&2
      echo "  отступа, поля разделены табуляцией; последнее поле заполнить." >&2
      printf '%s\n' "$__vskip" | LC_ALL=C grep -a . \
        | while IFS= read -r __nm; do printf '%s\t⊘\t%s\t<причина>\n' "$__ver" "$__nm" >&2; done || true
      printf '%s\n' "$__noop" | LC_ALL=C grep -a . \
        | while IFS= read -r __nm; do printf '%s\t≡\t%s\t<причина>\n' "$__ver" "$__nm" >&2; done || true
      return 1
    fi
  else
    __inert_bad=0
    __tw_inert_check_sign "$__ver" '⊘' 'пропущено по версии' \
      "$__vskip" "$(__tw_inert_declared "$__ver" '⊘')" "$__out" || __inert_bad=1
    # Второй знак сверяется СВОИМ набором: одна сверка на оба знака приняла бы
    # ⊘, ушедшее в ≡, за сходимость -- предмет у знаков разный.
    __tw_inert_check_sign "$__ver" '≡' 'отработало вхолостую' \
      "$__noop" "$(__tw_inert_declared "$__ver" '≡')" "$__out" || __inert_bad=1
    (( __inert_bad == 0 )) || return 1
    # Сходимость ОБЪЯВЛЯЕТСЯ -- это та же половина двери, что и отказ. Дверь,
    # молчащая на успехе, побайтово неотличима от снятой: убери отсюда обе
    # сверки, и лог прогона останется прежним. Соседние двери (уровня,
    # выключенных) потому и имеют по свидетелю в вердикте свипа. Названы ОБА
    # знака числами и ФАЙЛ объявления: числа без дома не говорят, с чем именно
    # сошлись.
    echo "NOTE: инертные правки tweakcc на $__ver сошлись с объявлением: пропущено по версии $__vskip_n, вхолостую $__noop_n (из $TWEAKCC_EXPECTED_INERT)" >&2
  fi
  # Слой ПРОМТОВ -- ПОЛОМ, а не равенством: его вторая половина принадлежит
  # каталогу накладок пользователя, и пин равенства краснел бы на добавлении
  # накладки, где дефекта нет. Пол ловит ровно ту сторону, которой владеет кит:
  # падение числа легших накладок.
  #
  # А ДОМ этого числа -- машина, не репозиторий: пол снят с каталога накладок
  # ОПЕРАТОРА, и строка кита, несущая его, отказывала бы на второй машине там,
  # где просело только число накладок у человека. Тот же владелец, что и у
  # множества выключенных правок, -- потому и объявление лежит рядом с ним, в
  # доме tweakcc, и клон дома свипом уносит его с собой без новой ручки.
  # ОБВАЛ слоя промтов -- это не «слоя нет», и различать их обязана дверь, а не
  # человек. Сама дверь вынесена в свою функцию (волна 45, #101): её ветки
  # причины обязаны быть измеримы стендом, а внутри этой пятисотстрочной
  # проверки до них было не добраться -- фикстуру пришлось бы строить на все
  # двери, стоящие выше по той же функции.
  #
  # Отказ идёт ДО всей логики пола, а не внутри её веток: на версии с УЖЕ
  # объявленным полом обвал дал бы просадку и назвал бы причиной «пол просел»
  # -- то есть отправил бы человека искать поломку у себя.
  __tw_prompt_outage_door "$__ver" "$__out" "$__prompts" "$__nf" "$__pfail" || return $?
  # ВЫКЛЮЧЕННЫЙ слой -- третье состояние, и его нули объявлению пола НЕ
  # принадлежат. Пол отвечает на вопрос «перестали ли ложиться накладки»; у
  # выключенного слоя накладок нет по решению, и объявленный под него ноль был
  # бы ровно тем вакуумным нулём, который эта дверь и заводилась ловить.
  # Причину нуля называет САМ форк строкой объявления -- её и требуем.
  # __tw_prompt_layer_off не отказывает (grep -c || true в её теле): пусто --
  # ноль, обнуление и обе ветки «loff» ниже -- весь разбор.
  __loff="$(__tw_prompt_layer_off "$__out")" || true; __loff="${__loff//[^0-9]/}"
  [[ -n "$__loff" ]] || __loff=0
  # ЗУБ ПОДСТАНОВКИ (вторая сторона). Кит подставил ручку -- форк ОБЯЗАН
  # объявиться. Пин форка, не знающего ручки, промты вписал бы как раньше, а
  # все счёты слоя читались бы дверьми как «выключено»: молчаливое расхождение
  # ровно там, где мы считали, что измерили.
  if (( ${TW_PROMPTS_KNOB:-0} == 1 && __loff == 0 )); then
    echo "FATAL: кит подставил форку TWEAKCC_NO_SYSTEM_PROMPTS=1, а форк выключение НЕ ОБЪЯВИЛ." >&2
    echo "  Измерено на $__ver: легло накладок $__prompts, не найдено $__nf, не легло $__pfail." >&2
    echo "  Ручку понимает форк начиная с пина 943beb9; запиненный сейчас" >&2
    echo "  CATALYST_TWEAKCC_SHA=${CATALYST_TWEAKCC_SHA:-<не задан>}." >&2
    echo "  Пока объявления нет, эти числа НЕ значат «слой выключен» -- слой мог" >&2
    echo "  отработать полностью. Либо поднимите пин форка, либо снимите" >&2
    echo "  подстановку ручкой CATALYST_TWEAKCC_KEEP_PROMPTS=1." >&2
    return 1
  fi
  if (( __loff > 0 )); then
    # Двусторонне, как «нет-слоя»: объявлено выключенным -- обязан молчать
    # ВЕСЬ слой. Ожившая накладка при объявленном выключении значит, что ручку
    # услышала не всякая половина слоя.
    if (( __prompts > 0 || __nf > 0 || __pfail > 0 )); then
      echo "FATAL: на $__ver форк объявил слой промтов ВЫКЛЮЧЕННЫМ, но слой работал: легло $__prompts, не найдено $__nf, не легло $__pfail." >&2
      echo "  Обе половины слоя (синхронизация снимка и правка образа накладками)" >&2
      echo "  гасятся одной ручкой; работающая половина при объявленном выключении" >&2
      echo "  -- дефект форка, а не объявления." >&2
      return 1
    fi
    __floor_said="слой ВЫКЛЮЧЕН ручкой TWEAKCC_NO_SYSTEM_PROMPTS, объявлено форком; пол не спрашивался"
  elif [[ ! -f "$TWEAKCC_EXPECTED_PROMPT_FLOOR" ]]; then
    # Отсутствующий файл = слой не объявлен. Пустое измеренное множество
    # сходится с ним обеими сторонами, и отказ здесь красил бы машину, на
    # которой ничего не сломано: свежую и клон-пустышку дома у свипа.
    # Третий счёт -- непрошедшие накладки: полный обвал слоя (всё легло, всё
    # объявлено непрошедшим) даёт легло 0 и не найдено 0, и без него отсутствие
    # ФАЙЛА прочиталось бы как отсутствие СЛОЯ. Дверь непрошедших стоит выше и
    # отказывает раньше; условие держит ту же правду локально -- «слоя нет»
    # значит нет ни одной накладки ни в одном из трёх состояний.
    if (( __prompts == 0 && __nf == 0 && __pfail == 0 )); then
      echo "NOTE: пол слоя промтов tweakcc для дома $TWEAKCC_HOME не объявлен, и слоя нет (легло 0, не найдено 0, не легло 0) -- сходится" >&2
      __floor_said="пол не объявлен, слоя нет"
    else
      echo "FATAL: пол слоя промтов tweakcc для дома $TWEAKCC_HOME не объявлен: $TWEAKCC_EXPECTED_PROMPT_FLOOR" >&2
      echo "  Измерено на $__ver: легло накладок $__prompts, не найдено $__nf." >&2
      echo "  Пол принадлежит ЭТОМУ дому: каталог накладок у каждой машины свой," >&2
      echo "  и число из чужого дома красило бы сборку там, где просело только оно." >&2
      echo "  Строка ниже -- ровно в том виде, в каком её читает дверь: без" >&2
      echo "  отступа, поля разделены табуляцией." >&2
      echo "  ---- $TWEAKCC_EXPECTED_PROMPT_FLOOR ----" >&2
      printf '%s\t%s\t<причина/происхождение числа>\n' "$__ver" "$__prompts" >&2
      echo "  ---- конец ----" >&2
      return 1
    fi
  else
    # Одна версия -- одна строка, как и в файле кита: читатель берёт ПЕРВОЕ
    # совпадение и выходит, а вторая строка (та, которую правил человек) молча
    # не действует. BOM первой строки снимается ПЕРЕД тримом: иначе ключ первой
    # версии читается как чужой, и человеку показывают два одинаковых на вид
    # имени, между которыми нет разницы на экране.
    # У sed и awk нет кода «не найдено»: ноль даже при пустом выводе (пусто --
    # ноль строк, awk печатает n+0), ненулевое -- отказ чтения.
    __floor_rows="$(LC_ALL=C sed $'1s/^\xef\xbb\xbf//' "$TWEAKCC_EXPECTED_PROMPT_FLOOR" 2>/dev/null \
      | awk -F'\t' -v v="$__ver" '
          /^[[:space:]]*#/ { next } NF==0 { next }
          { k=$1; gsub(/^[[:space:]]+|[[:space:]]+$/,"",k); if (k==v) n++ }
          END { print n+0 }
        ')" || { printf 'ПРИБОР НЕДОСТУПЕН: строки пола промтов не прочитаны\n' >&2; return 2; }
    if (( __floor_rows > 1 )); then
      echo "FATAL: в $TWEAKCC_EXPECTED_PROMPT_FLOOR на $__ver приходится строк: $__floor_rows." >&2
      echo "  Читатель берёт первую и выходит -- остальные не действуют." >&2
      echo "  Оставьте на версию ровно одну строку." >&2
      return 1
    fi
    # Пусто при нулевом коде -- «пол не объявлен» (отказ ниже разбирает);
    # ненулевое у sed/awk -- отказ чтения, кода «не найдено» нет.
    __want_prompts="$(LC_ALL=C sed $'1s/^\xef\xbb\xbf//' "$TWEAKCC_EXPECTED_PROMPT_FLOOR" 2>/dev/null \
      | awk -F'\t' -v v="$__ver" '
          /^[[:space:]]*#/ { next } NF==0 { next }
          { k=$1; gsub(/^[[:space:]]+|[[:space:]]+$/,"",k) }
          k==v { gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit }
        ')" || { printf 'ПРИБОР НЕДОСТУПЕН: объявленный пол промтов не прочитан\n' >&2; return 2; }
    if [[ -z "$__want_prompts" ]]; then
      echo "FATAL: для $__ver пол слоя промтов не объявлен, а измерено: легло $__prompts, не найдено $__nf." >&2
      if (( __floor_rows == 0 )); then
        echo "  Взгляните на число один раз и впишите строку в" >&2
        echo "    $TWEAKCC_EXPECTED_PROMPT_FLOOR" >&2
        echo "  Строка ниже -- ровно в том виде, в каком её читает дверь: без" >&2
        echo "  отступа, поля разделены табуляцией." >&2
        printf '%s\t%s\t<причина/происхождение числа>\n' "$__ver" "$__prompts" >&2
      else
        # Строка на версию ЕСТЬ, пусто поле -- та же дорожка, что у файла кита:
        # совет «впишите строку» дал бы вторую строку на версию, и следующий
        # прогон отказал бы уже по дублю.
        echo "  Строка на $__ver в файле ЕСТЬ, но поле пола в ней пусто -- правьте" >&2
        echo "  её, не добавляйте вторую: две строки на версию дверь отвергает." >&2
        echo "    $TWEAKCC_EXPECTED_PROMPT_FLOOR" >&2
        echo "  Вид строки: <версия><TAB><пол|нет-слоя><TAB><причина>." >&2
      fi
      return 1
    fi
    # Третье поле -- ПРОИСХОЖДЕНИЕ числа, и оно обязательно. Дом пола не под
    # контролем версий: кит его не разворачивает и не бэкапит, а собственный
    # отказ печатает готовую строку с ТЕКУЩИМ измерением -- строку эту можно
    # вклеить, не заметив, что пол при этом восстановлен на просевшем уровне и
    # следа не осталось. Пустое поле и оставленная дословно заглушка совета --
    # одно и то же: число без названной причины.
    # Пусто при нулевом коде -- «происхождение не названо» (отказ ниже
    # разбирает); ненулевое у sed/awk -- отказ чтения.
    __floor_why="$(LC_ALL=C sed $'1s/^\xef\xbb\xbf//' "$TWEAKCC_EXPECTED_PROMPT_FLOOR" 2>/dev/null \
      | awk -F'\t' -v v="$__ver" '
          /^[[:space:]]*#/ { next } NF==0 { next }
          { k=$1; gsub(/^[[:space:]]+|[[:space:]]+$/,"",k) }
          k==v { gsub(/^[[:space:]]+|[[:space:]]+$/,"",$3); print $3; exit }
        ')" || { printf 'ПРИБОР НЕДОСТУПЕН: происхождение пола промтов не прочитано\n' >&2; return 2; }
    if [[ -z "$__floor_why" || "$__floor_why" == "<причина/происхождение числа>" ]]; then
      echo "FATAL: в $TWEAKCC_EXPECTED_PROMPT_FLOOR строка $__ver не называет ПРОИСХОЖДЕНИЕ числа." >&2
      echo "  Третье поле пусто либо в нём оставлена заглушка совета. Дом этого" >&2
      echo "  файла вне контроля версий: пол, вклеенный без названной причины," >&2
      echo "  восстанавливается на просевшем уровне и стирает сигнал бесследно." >&2
      echo "  Вид строки: <версия><TAB><пол|нет-слоя><TAB><откуда взято число>." >&2
      return 1
    fi
    if [[ "$__want_prompts" == "нет-слоя" ]]; then
      # Отдельный маркер, а не пол 0: пол 0 беззубый, а «нет-слоя» требует
      # ДВУСТОРОННЕГО нуля -- вернувшийся слой обязан покраснеть и быть объявлен.
      if (( __prompts > 0 || __nf > 0 || __pfail > 0 )); then
        echo "FATAL: на $__ver слой промтов объявлен отсутствующим, но он ожил: легло $__prompts, не найдено $__nf, не легло $__pfail." >&2
        echo "  Замените «нет-слоя» на пол во втором поле строки $__ver в" >&2
        echo "    $TWEAKCC_EXPECTED_PROMPT_FLOOR" >&2
        return 1
      fi
    elif [[ ! "$__want_prompts" =~ ^[0-9]+$ ]]; then
      echo "FATAL: в $TWEAKCC_EXPECTED_PROMPT_FLOOR пол промтов для $__ver не число и не «нет-слоя»: «${__want_prompts}»." >&2
      return 1
    elif (( __prompts < __want_prompts )); then
      echo "FATAL: слой промтов tweakcc просел на $__ver: пол $__want_prompts, легло $__prompts." >&2
      echo "  Пол не пробивается добавлением накладок -- он пробивается тем, что" >&2
      echo "  накладки перестали ложиться. Не опускайте пол, не назвав причину:" >&2
      echo "  опущенный пол стирает сигнал ровно там, где он появился." >&2
      return 1
    fi
    __floor_said="пол $__want_prompts из $TWEAKCC_EXPECTED_PROMPT_FLOOR"
  fi
  # Итог называет ОБА дома: попытки объявлены в репозитории кита (владелец --
  # реестр форка), пол -- в доме tweakcc этой машины (владелец -- каталог
  # накладок оператора). Одно имя на две величины и было тем дефектом, из-за
  # которого строка не переезжала между машинами.
  echo "NOTE: уровень tweakcc на $__ver сошёлся: код $__tried попыток (объявлено $__want_tried в $TWEAKCC_EXPECTED_APPLIED; легло $__code, выключено конфигурацией $__off, пропущено по версии $__vskip_n, вхолостую $__noop_n, не легло $__failed), промты $__prompts ($__floor_said), не легло накладок $__pfail" >&2
  return 0
}

# Дверь МНОЖЕСТВА выключенных правок. Предмет соседний с уровнем, но владелец
# ТРЕТИЙ: конфиг дома tweakcc решает, какие правки не пробовать вовсе, и это
# свойство МАШИНЫ, а не версии и не кита. Потому объявление и лежит рядом с
# самим конфигом: домов на машине бывает несколько, у каждого своё множество,
# а клон дома свипом и заём живого дома зондом уносят объявление с собой сами,
# без новой ручки.
#
# Двусторонне по той же причине, что и сверка непроходов: одностороннее
# объявление стало бы бессрочной индульгенцией. Выключилось без строки --
# отказ (конфиг подменили, а выключенной правки в образе НЕТ); строка есть, а
# правка пробуется -- тоже отказ (её включили обратно, запись пережила причину).
__tw_check_off_set() {        # <вывод tweakcc> <образ> -> 0|1|2 (2 = отказ прибора)
  local __out="$1" __bin="$2"
  local __ver __off __measured __declared __undeclared __stale __origin __bad=0
  __off="$(__tw_off_code_names "$__out" | LC_ALL=C grep -a -c . || true)"
  __off="${__off//[^0-9]/}"
  [[ -n "$__off" ]] || __off=0
  if [[ "${CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES:-0}" == "1" ]]; then
    # Гашение ОБЪЯВЛЯЕТСЯ, как у соседних дверей: снятая молча дверь
    # неотличима от двери, которая держится.
    echo "NOTE: CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 -- дверь выключенных правок tweakcc погашена (выключено $__off)" >&2
    return 0
  fi
  # __tw_off_code_names не отказывает (пояс || true в её теле): пусто --
  # «выключенных нет», проверки ниже именно это и разбирают.
  __measured="$(__tw_off_code_names "$__out")" || true
  # Версия -- из БАЙТОВ образа, как у соседок, и отдельной ветки «отметки нет»
  # здесь нет намеренно: дверь уровня стоит ПЕРЕД этой и на таком образе уже
  # отказала, а сам вердикт множества от версии не зависит вовсе -- множество
  # принадлежит дому.
  # __ver_from_bytes объявляет «код ВСЕГДА 0»: пусто -- законный ответ, ветки
  # «отметки нет» у соседних дверей закрывают случай (здесь -- комментарием).
  __ver="$(__ver_from_bytes "$__bin")" || true
  if [[ ! -f "$TWEAKCC_EXPECTED_OFF" ]]; then
    # Отсутствующий файл = ПУСТОЕ объявленное множество, и пустое измеренное
    # сходится с ним обеими сторонами: comm не даёт ни строки ни туда, ни
    # обратно.
    #
    # Ветка покрывает РОВНО этот случай -- дом, в котором конфигурацией не
    # выключена НИ ОДНА правка кода. «Дом без конфига» этим случаем НЕ является:
    # форк берёт для него DEFAULT_SETTINGS, и часть правок выключена уже ими --
    # на пустом доме и образе 2.1.261 измерено ○ = 30 из 49 правок кода
    # (форк a377c40; реестр 49 = 14 ✓ + 30 ○ + 3 ⊘ + 2 ≡). Свежая машина и
    # пустой клон дома приходят сюда с НЕНУЛЕВЫМ множеством и получают отказ
    # ниже: объявить множество -- разовое действие оператора, и подменять его
    # тишиной здесь нельзя.
    if (( __off == 0 )); then
      echo "NOTE: объявления выключенных правок tweakcc для дома $TWEAKCC_HOME нет, и выключенных правок не измерено (0) -- сходится" >&2
      return 0
    fi
    # Дом, созданный ПРОГОНОМ, а не оператором: у двери нет предмета (см.
    # TWEAKCC_HOME_ORIGIN_NAME). Ключ -- НЕПУСТАЯ отметка: её содержимое
    # конвейер не разбирает (это человекочитаемое утверждение писателя, и
    # второй разборщик чужого формата стал бы вторым домом), но пустой файл не
    # утверждает ничего. Объявление, если оно ЕСТЬ, главнее отметки: эта ветка
    # живёт под условием «файла объявления нет».
    if [[ -s "$TWEAKCC_HOME_ORIGIN" ]]; then
      # Файл существует и непуст (проверка -s выше): пусто первой строки при
      # нулевом коде -- законное «отметка без слов», NOTE ниже печатает её
      # как есть. Ненулевое у sed -- отказ чтения (кода «не найдено» нет).
      # Отдаётся КОДОМ 2, а не `exit`: вызывающий разбирает код и убирает за
      # собой временный вывод tweakcc, чего `exit` отсюда не дал бы сделать.
      # Stderr самого sed НЕ подавляется: код 2 говорит «не прочиталось», а
      # почему именно (права, том, обрыв) знает только сообщение прибора.
      __origin="$(LC_ALL=C sed -n '1p' "$TWEAKCC_HOME_ORIGIN")" || { printf 'ПРИБОР НЕДОСТУПЕН: отметка происхождения дома не прочитана\n' >&2; return 2; }
      echo "NOTE: дом tweakcc $TWEAKCC_HOME создан прогоном, а не оператором ($__origin): объявления выключенных правок у него нет, выключено конфигурацией $__off -- это дефолты форка, дрейфовать в таком доме нечему" >&2
      return 0
    fi
    echo "FATAL: объявление выключенных правок tweakcc для дома $TWEAKCC_HOME не найдено: $TWEAKCC_EXPECTED_OFF" >&2
    echo "  Выключенных конфигурацией правок слоя кода измерено: $__off. Их множество --" >&2
    echo "  свойство ЭТОГО дома, не версии и не кита: объявите его один раз файлом ниже" >&2
    echo "  (имена -- ровно те, что tweakcc печатает после «○ »):" >&2
    echo "  ---- $TWEAKCC_EXPECTED_OFF ----" >&2
    echo "  # Правки tweakcc, выключенные конфигурацией этого дома. Читает claude-patch-all.sh:" >&2
    echo "  # правка выключилась без строки здесь -- отказ; строка есть, а правка пробуется -- отказ." >&2
    if [[ -n "$__measured" ]]; then
      printf '%s\n' "$__measured" | sed 's/^/  /' >&2
    fi
    echo "  ---- конец ----" >&2
    return 1
  fi
  # Ключ тримится с обоих концов, строки «#» и пустые пропускаются, дубли
  # схлопываются: объявление, вписанное с отступом, -- то же объявление, а не
  # чужое имя (та же дисциплина, что у ключа версии в двери уровня).
  # BOM первой строки снимается ПЕРЕД тримом: `[[:space:]]` его не берёт, и
  # файл, сохранённый редактором с меткой порядка байтов, давал ОБА блока
  # отказа сразу -- имя первой правки числилось и невыполненным объявлением, и
  # необъявленным выключением, а на экране два имени выглядели одинаково.
  # Пояс || true уже стоит ВНУТРИ подстановки (хвост трубы): пусто -- законное
  # «объявленное множество пусто», обе разности ниже читают именно его.
  __declared="$(LC_ALL=C sed $'1s/^\xef\xbb\xbf//' "$TWEAKCC_EXPECTED_OFF" 2>/dev/null \
                | LC_ALL=C sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
                | LC_ALL=C grep -a -v -e '^#' -e '^$' \
                | LC_ALL=C sort -u || true)" || true
  # Обе разности ниже уже несут пояс || true ВНУТРИ подстановки: отказ
  # невозможен, пусто -- «множества согласны», проверки -n читают именно его.
  __undeclared="$(LC_ALL=C comm -13 <(printf '%s\n' "$__declared" | LC_ALL=C sed '/^$/d') \
                                    <(printf '%s\n' "$__measured" | LC_ALL=C sed '/^$/d') || true)" || true
  __stale="$(LC_ALL=C comm -23 <(printf '%s\n' "$__declared" | LC_ALL=C sed '/^$/d') \
                               <(printf '%s\n' "$__measured" | LC_ALL=C sed '/^$/d') || true)" || true
  if [[ -n "$__undeclared" ]]; then
    echo "FATAL: выключились правки tweakcc, не объявленные выключенными для дома $TWEAKCC_HOME:" >&2
    printf '%s\n' "$__undeclared" | sed 's/^/  ○ /' >&2
    echo "  Причин ДВЕ, и вторую эта дверь не отличает от первой: конфиг дома" >&2
    echo "  изменился без объявления ЛИБО переехал пин форка (CATALYST_TWEAKCC_SHA)" >&2
    echo "  и выключенную правку в нём ПЕРЕИМЕНОВАЛИ -- тогда число попыток не" >&2
    echo "  движется, знак остаётся ○, и соседние двери молчат. Сверьте пин форка" >&2
    echo "  прежде, чем править конфиг. Либо объявите имена в" >&2
    echo "    $TWEAKCC_EXPECTED_OFF" >&2
    echo "  либо верните конфиг: выключенная правка -- это правка, которой в образе НЕТ." >&2
    __bad=1
  fi
  if [[ -n "$__stale" ]]; then
    echo "FATAL: правки tweakcc объявлены выключенными для дома $TWEAKCC_HOME, а пробуются:" >&2
    printf '%s\n' "$__stale" | sed 's/^/  /' >&2
    echo "  Причин ДВЕ: конфиг включил правки обратно ЛИБО переехал пин форка" >&2
    echo "  (CATALYST_TWEAKCC_SHA) и правку в нём переименовали -- старое имя тогда" >&2
    echo "  «пережило причину», а новое стоит в блоке необъявленных выше. Оба блока" >&2
    echo "  разом на одинаковом числе попыток -- это признак переезда пина, а не" >&2
    echo "  конфига. Снимите строки из" >&2
    echo "    $TWEAKCC_EXPECTED_OFF" >&2
    echo "  либо выключите правки в конфиге. Одностороннее объявление стало бы бессрочной" >&2
    echo "  индульгенцией: ровно так на этой неделе список старых моделей вернулся в /model." >&2
    __bad=1
  fi
  # Отказ ПОСЛЕ обоих блоков: расхождение бывает встречным, и ранний возврат
  # назвал бы человеку одну его половину, отправив чинить дважды.
  if (( __bad )); then
    return 1
  fi
  echo "NOTE: выключенные конфигурацией правки tweakcc на $__ver сошлись с объявлением дома: $__off" >&2
  return 0
}

# Дверь КОНФЛИКТОВ синхронизации накладок.
#
# ЗАЧЕМ ОНА РЯДОМ С ПОЛОМ. Пол легших накладок односторонен по устройству: он
# ловит ПАДЕНИЕ числа, а ниже нуля падать некуда. На доме, где ни одна накладка
# не несёт правки человека (замер 10.09, задача #95: из всех накладок дома --
# ни одной с правкой оператора), «легло промтов» равно нулю на ЛЮБОЙ версии, и
# нулевой пол зуба не имеет. Зуб перенесён на число, которое при регрессе
# различителя РАСТЁТ: конфликты синхронизации. Распаковщик печатает их сам,
# когда накладка разошлась с текущим определением апстрима и он не смог решить
# за пользователя; до пина 650a03f такие накладки молча вписывались в образ
# старым текстом, и измерить их было нечем. Замер конвейера 10.09 по корпусному
# 2.1.265 на новом пине: Updated 33, конфликтов 0.
#
# НАПРАВЛЕНИЕ СРАВНЕНИЯ -- ОБРАТНОЕ ПОЛУ. Отказ вызывает ПРЕВЫШЕНИЕ
# объявленного, а не просадка: добавление конфликта -- всегда событие, требующее
# человека, а уменьшение -- улучшение (NOTE, не отказ). Поэтому отсутствие
# файла объявления здесь -- НЕ отказ и умолчание равно нулю, в отличие от двери
# пола, где ноль по умолчанию был бы ложью: у этой двери нулевое умолчание зуб
# не гасит -- превышение нуля отказывает.
#
# ВЛАДЕЛЕЦ ЧИСЛА -- ДОМ, как у пола и множества выключенных: конфликт
# рождается из пары «накладка оператора × определение апстрима», и в
# репозитории кита объявление красило бы вторую машину, где конфликтов нет.
# Объявление лежит рядом с config.json и уезжает с клоном дома само.
#
# ОБВАЛ слоя опознаётся ТЕМ ЖЕ признаком, что у двери обвала выше (пара игл
# недоступности снимка), -- второй копии правила здесь нет. Под обвалом дверь
# печатает «нечего мерить» и НЕ сравнивает: ноль конфликтов при не бежавшей
# синхронизации не значит ничего. В живом конвейере дверь обвала отказывает
# раньше и до сюда прогон не доходит; собственная ветка держит вызов из
# любого другого места честным.
__tw_check_prompt_conflicts() {   # <вывод tweakcc> <образ> -> 0|1|2 (2 = отказ прибора)
  local __out="$1" __bin="$2"
  local __ver __conf __outage __outage_dl __loff
  local __conf_rows __want_conf __conf_why
  # __tw_prompt_conflicts не отказывает (пояс || true в её теле): пусто --
  # ноль, обнуление ниже превращает её в измеренный ноль.
  __conf="$(__tw_prompt_conflicts "$__out")" || true; __conf="${__conf//[^0-9]/}"
  [[ -n "$__conf" ]] || __conf=0
  if [[ "${CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES:-0}" == "1" ]]; then
    # Гашение ОБЪЯВЛЯЕТСЯ, как у соседних дверей: снятая молча дверь
    # неотличима от двери, которая держится.
    echo "NOTE: CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 -- дверь конфликтов накладок tweakcc погашена (конфликтных $__conf)" >&2
    return 0
  fi
  # Оба счётчика обвала не отказывают (grep -c || true в их телах): пусто --
  # ноль, обнуление и ветка «>0» ниже -- весь разбор обвала.
  __outage="$(__tw_prompt_outage "$__out")" || true;      __outage="${__outage//[^0-9]/}"
  __outage_dl="$(__tw_prompt_dl_error "$__out")" || true; __outage_dl="${__outage_dl//[^0-9]/}"
  [[ -n "$__outage" ]] || __outage=0
  [[ -n "$__outage_dl" ]] || __outage_dl=0
  if (( __outage > 0 || __outage_dl > 0 )); then
    echo "NOTE: слой промтов ОБВАЛИЛСЯ -- конфликтам накладок нечего мерить, сравнение не проводится (обвал уже назван своей дверью выше)" >&2
    return 0
  fi
  # ВЫКЛЮЧЕННЫЙ слой -- как обвал по последствию для ЭТОЙ двери и совсем не как
  # он по смыслу: синхронизация не бежала, конфликту неоткуда взяться, и ноль
  # тут не измерение, а тавтология. Признак тот же, что у двери пола, -- строка
  # объявления САМОГО форка; второй копии правила здесь нет.
  #
  # Зуб подстановки (ручка поднята, а объявления нет) живёт у двери пола: она
  # стоит ВЫШЕ по прогону и до этой двери такой прогон не доходит. Две копии
  # одного отказа разошлись бы молча.
  # __tw_prompt_layer_off не отказывает (grep -c || true в её теле): пусто --
  # ноль, обнуление и ветка «>0» ниже -- весь разбор.
  __loff="$(__tw_prompt_layer_off "$__out")" || true; __loff="${__loff//[^0-9]/}"
  [[ -n "$__loff" ]] || __loff=0
  if (( __loff > 0 )); then
    echo "NOTE: слой промтов ВЫКЛЮЧЕН ручкой (объявлено форком) -- синхронизация не бежала, конфликтам накладок нечего мерить (измерено конфликтных $__conf)" >&2
    return 0
  fi
  # Версия -- из БАЙТОВ образа, как у соседок; отдельной ветки «отметки нет»
  # здесь нет намеренно: дверь уровня стоит ПЕРЕД этой и на таком образе уже
  # отказала.
  # __ver_from_bytes объявляет «код ВСЕГДА 0»: пусто -- законный ответ, дверь
  # уровня выше на таком образе уже отказала (см. комментарий над ней).
  __ver="$(__ver_from_bytes "$__bin")" || true
  if [[ ! -f "$TWEAKCC_EXPECTED_PROMPT_CONFLICTS" ]]; then
    # Файла объявления нет -- умолчание ноль. Ноль конфликтов сходится с ним
    # обеими сторонами; НЕ ноль -- превышение умолчания, и это отказ.
    if (( __conf > 0 )); then
      echo "FATAL: конфликтных накладок tweakcc на $__ver: $__conf, а объявления конфликтов для этого дома нет -- умолчание ноль превышено." >&2
      echo "  Отсутствие файла объявления -- не отказ: умолчание равно нулю, и" >&2
      echo "  отказом является только превышение. Конфликт -- накладка," >&2
      echo "  разошедшаяся с текущим определением апстрима: распаковщик не смог" >&2
      echo "  решить сам и оставил её человеку (diff-страницы он уже положил" >&2
      echo "  рядом с каталогом накладок). До пина 650a03f такие накладки молча" >&2
      echo "  вписывались в образ старым текстом. Разберитесь с накладками, затем," >&2
      echo "  если превышение законно, объявите его файлом" >&2
      echo "    $TWEAKCC_EXPECTED_PROMPT_CONFLICTS" >&2
      echo "  Строка ниже -- ровно в том виде, в каком её читает дверь: без" >&2
      echo "  отступа, поля разделены табуляцией." >&2
      printf '%s\t%s\t<причина/происхождение числа>\n' "$__ver" "$__conf" >&2
      return 1
    fi
    echo "NOTE: объявления конфликтов накладок tweakcc для этого дома нет, и конфликтных накладок не измерено (0) -- умолчание ноль, сходится" >&2
    return 0
  fi
  # Одна версия -- одна строка, как у пола: читатель берёт ПЕРВОЕ совпадение и
  # выходит, а вторая строка (та, которую правил человек) молча не действует.
  # BOM первой строки снимается ПЕРЕД тримом -- тем же приёмом, что у читателя
  # пола: `[[:space:]]` метки порядка байтов не берёт.
  # У sed и awk нет кода «не найдено»: ноль даже при пустом выводе (пусто --
  # ноль строк, awk печатает n+0), ненулевое -- отказ чтения. Отдаётся КОДОМ 2,
  # а не `exit`: вызывающий разбирает код и убирает за собой временный вывод
  # tweakcc, чего `exit` отсюда не дал бы сделать.
  __conf_rows="$(LC_ALL=C sed $'1s/^\xef\xbb\xbf//' "$TWEAKCC_EXPECTED_PROMPT_CONFLICTS" 2>/dev/null \
    | awk -F'\t' -v v="$__ver" '
        /^[[:space:]]*#/ { next } NF==0 { next }
        { k=$1; gsub(/^[[:space:]]+|[[:space:]]+$/,"",k); if (k==v) n++ }
        END { print n+0 }
      ')" || { printf 'ПРИБОР НЕДОСТУПЕН: строки объявленных конфликтов не прочитаны\n' >&2; return 2; }
  if (( __conf_rows > 1 )); then
    echo "FATAL: в $TWEAKCC_EXPECTED_PROMPT_CONFLICTS на $__ver приходится строк: $__conf_rows." >&2
    echo "  Читатель берёт первую и выходит -- остальные не действуют." >&2
    echo "  Оставьте на версию ровно одну строку." >&2
    return 1
  fi
  # Пусто при нулевом коде -- «строки на версию нет» (отказ ниже разбирает);
  # ненулевое у sed/awk -- отказ чтения, кода «не найдено» нет.
  __want_conf="$(LC_ALL=C sed $'1s/^\xef\xbb\xbf//' "$TWEAKCC_EXPECTED_PROMPT_CONFLICTS" 2>/dev/null \
    | awk -F'\t' -v v="$__ver" '
        /^[[:space:]]*#/ { next } NF==0 { next }
        { k=$1; gsub(/^[[:space:]]+|[[:space:]]+$/,"",k) }
        k==v { gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit }
      ')" || { printf 'ПРИБОР НЕДОСТУПЕН: объявленное число конфликтов не прочитано\n' >&2; return 2; }
  if [[ -z "$__want_conf" ]]; then
    if (( __conf_rows == 0 )); then
      echo "FATAL: для $__ver строка конфликтов не объявлена, а измерено: конфликтных $__conf." >&2
      echo "  Файл объявления существует, и умолчание к нему не относится:" >&2
      echo "  ведущий его оператор обязан назвать число для каждой измеряемой" >&2
      echo "  версии -- как у пола. Взгляните на число один раз и впишите строку в" >&2
      echo "    $TWEAKCC_EXPECTED_PROMPT_CONFLICTS" >&2
      echo "  Строка ниже -- ровно в том виде, в каком её читает дверь: без" >&2
      echo "  отступа, поля разделены табуляцией." >&2
      printf '%s\t%s\t<причина/происхождение числа>\n' "$__ver" "$__conf" >&2
    else
      # Строка на версию ЕСТЬ, пусто поле -- та же дорожка, что у пола: совет
      # «впишите строку» дал бы вторую строку на версию, и следующий прогон
      # отказал бы уже по дублю.
      echo "FATAL: строка $__ver в $TWEAKCC_EXPECTED_PROMPT_CONFLICTS есть, но поле числа в ней пусто." >&2
      echo "  Правьте её, не добавляйте вторую: две строки на версию дверь отвергает." >&2
      echo "  Вид строки: <версия><TAB><конфликтов|нет-слоя><TAB><причина>." >&2
    fi
    return 1
  fi
  # Происхождение ОБЯЗАТЕЛЬНО -- тот же зуб, что у пола: строку нельзя вклеить,
  # не написав, откуда взято её содержимое. Дом файла вне контроля версий, и
  # вклеенная без причины строка пережила бы свою правду бесследно.
  # Пусто при нулевом коде -- «происхождение не названо» (отказ «не названо
  # происхождение» ниже); ненулевое у sed/awk -- отказ чтения.
  __conf_why="$(LC_ALL=C sed $'1s/^\xef\xbb\xbf//' "$TWEAKCC_EXPECTED_PROMPT_CONFLICTS" 2>/dev/null \
    | awk -F'\t' -v v="$__ver" '
        /^[[:space:]]*#/ { next } NF==0 { next }
        { k=$1; gsub(/^[[:space:]]+|[[:space:]]+$/,"",k) }
        k==v { gsub(/^[[:space:]]+|[[:space:]]+$/,"",$3); print $3; exit }
      ')" || { printf 'ПРИБОР НЕДОСТУПЕН: происхождение конфликтов не прочитано\n' >&2; return 2; }
  if [[ -z "$__conf_why" || "$__conf_why" == "<причина/происхождение числа>" ]]; then
    echo "FATAL: в $TWEAKCC_EXPECTED_PROMPT_CONFLICTS строка $__ver не называет ПРОИСХОЖДЕНИЕ числа." >&2
    echo "  Третье поле пусто либо в нём оставлена заглушка совета. Число без" >&2
    echo "  названной причины стирает сигнал ровно там, где он появился." >&2
    echo "  Вид строки: <версия><TAB><конфликтных><TAB><откуда взято число>." >&2
    return 1
  fi
  if [[ ! "$__want_conf" =~ ^[0-9]+$ ]]; then
    # Фигурные скобки ОБЯЗАТЕЛЬНЫ: за подстановкой идёт не-ASCII кавычка, и bash
    # в не-UTF8 локали втягивает её первый байт в ИМЯ переменной -- тот же
    # урок, что у двери уровня выше.
    echo "FATAL: в $TWEAKCC_EXPECTED_PROMPT_CONFLICTS объявленные конфликты для $__ver не число: «${__want_conf}»." >&2
    return 1
  fi
  if (( __conf > __want_conf )); then
    echo "FATAL: конфликтных накладок tweakcc на $__ver больше объявленного: конфликтных $__conf, объявлено $__want_conf." >&2
    echo "  Объявление: $TWEAKCC_EXPECTED_PROMPT_CONFLICTS" >&2
    echo "  Конфликт -- накладка, разошедшаяся с текущим определением апстрима:" >&2
    echo "  распаковщик не смог решить сам и оставил её человеку (diff-страницы" >&2
    echo "  он уже положил рядом с каталогом накладок). До пина 650a03f такие" >&2
    echo "  накладки молча вписывались в образ старым текстом. Разберитесь с" >&2
    echo "  накладками в $TWEAKCC_HOME/system-prompts; поднимите объявление," >&2
    echo "  лишь назвав причину, -- опущенное без причины число стирает сигнал." >&2
    return 1
  fi
  if (( __conf < __want_conf )); then
    # Уменьшение -- улучшение, а не отказ: с этой стороны объявление пережило
    # свою причину «хорошим» образом, и отказ красил бы версию, где ничего не
    # сломано. Но улучшение ОБЪЯВЛЯЕТСЯ: молчащее сходство неотличимо от
    # несравнивавшего.
    echo "NOTE: конфликтных накладок tweakcc на $__ver меньше объявленного: конфликтных $__conf, объявлено $__want_conf (из $TWEAKCC_EXPECTED_PROMPT_CONFLICTS) -- улучшение, не отказ" >&2
    return 0
  fi
  echo "NOTE: конфликты накладок tweakcc на $__ver: конфликтных $__conf, объявлено $__want_conf (из $TWEAKCC_EXPECTED_PROMPT_CONFLICTS) -- сходится" >&2
  return 0
}

PRISTINE_SRC="$(__strip_staging "$BIN").orig" || { printf 'ПРИБОР НЕДОСТУПЕН: не снят staging-суффикс с имени цели\n' >&2; exit 2; }

# ГРАНИЦА. Сторожит РОВНО то, что разошлось: форму staging-суффикса в имени,
# которое эта оболочка получила от установщика. Если `.staging` в имени есть, а
# опознанной формы нет, снятие суффикса ниже промолчало бы и дало неверное имя --
# как оно и вышло 2026-09-01. Код 6: ломается не продукт и не запрос человека, а
# договор между нашими же двумя файлами.
#
# Только на пути --update. У --target имя цели принадлежит ВЫЗЫВАЮЩЕМУ по
# замыслу (README учит этому режиму, и зонд пути сборки строит свои цели именно
# так), поэтому требовать от него вид версии значило бы сломать документированный
# режим -- первая редакция этой границы так и сделала, и зонд её покраснил.
if [[ $DO_UPDATE -eq 1 && "$BIN" == *.staging* ]] && ! __has_staging "$BIN"; then
  echo "FATAL: staging-суффикс в имени цели не опознан: $(basename "$BIN")" >&2
  echo "  Ожидается <имя>.staging либо <имя>.staging.<pid>. Установщик сменил" >&2
  echo "  форму имени, и снятие суффикса ниже дало бы неверное имя молча." >&2
  exit 6
fi

# --- 0b2. a --target run must name PRISTINE bytes -----------------------------
# 0b стажирует путь по умолчанию, чтобы tweakcc никогда не увидел пропатченный
# образ. У --target такого шага нет ПО ЗАМЫСЛУ (стажированием владеет
# вызывающий), и никто не спрашивал, стоковые ли байты он назвал. За один день
# 2026-08-28 не стоковые оказались дважды: --target на ЖИВОЙ установке (tweakcc
# восстановил свой бэкап поверх уже пропатченных байт, прогон умер FATAL и
# ОСТАВИЛ установку изменённой) и --target на staging-файле, над которым уже
# отработала стадия tweakcc, потому что прогон отказал ПОЗЖЕ неё.
# Байты читаются здесь: до установки распаковщика и задолго до стадии tweakcc.
# Код 4 -- «байты не те, что названы»: файл не того рода, что обещает флаг.
# --only-ours исключён сознательно: он не зовёт tweakcc вовсе, а метка tweakcc
# на его цели ШТАТНА (в том и смысл флага); пропатченную нами цель отвергает
# сам наш патчер.
if [[ -n "$TARGET" && $ONLY_OURS -eq 0 ]]; then
  __why=""
  if LC_ALL=C grep -q -a -F "$OUR_MARKER" "$BIN"; then
    __why="our patches"
  elif LC_ALL=C grep -q -a -F 'tweakcc' "$BIN"; then
    __why="tweakcc's stage"
  fi
  if [[ -n "$__why" ]]; then
    echo "ERROR: --target names an image that already carries $__why." >&2
    echo "  target: $BIN" >&2
    echo "  tweakcc's stage restores ITS backup over this path and patches it" >&2
    echo "  again, so the build would begin from bytes nobody named -- and the" >&2
    echo "  target is left rewritten even when a later gate refuses." >&2
    echo "  Hand over stock bytes instead (a run that died after tweakcc's stage" >&2
    echo "  leaves exactly this state -- recreate the copy before retrying):" >&2
    echo "    cp -p <pristine image> '$BIN'" >&2
    exit 4
  fi
fi


# --- гейты, которым образ не нужен, спрашиваются ДО того, как его трогают ----
# Всё ниже читает КИТ, а не сборку: вклеиваемый код, блок проверок, формы
# оболочки, инструменты судьи, их раскатку, числа в доках. Блок стоял между
# стадией tweakcc и нашей, и отказ в нём оставлял цель уже переписанной чужой
# стадией, пока прогон докладывал «отказано» -- та самая форма, которую 0b
# убрал с пути по умолчанию (а на --target её не убирал никто). Спрошенный
# здесь, красный гейт стоит ровно тех секунд, что ушли на вопрос.
# The injected code is parsed BEFORE the build: the patcher is syntactically
# intact on its own, while a program glued from hundreds of string pieces may
# not parse at all. The check must be CALLED: while it was merely shipped in
# the kit, it was broken by two commits and stayed silent.
# КЛАСС ОТКАЗА РАЗБОРА -- отдельная функция, и это конструктивно.
#
# Во-первых, она ЧИСТАЯ: слова ребёнка на входе, названные поводы на выходе,
# ни файлов, ни сети. Во-вторых, стенд вырезает её ПО ИМЕНИ и гоняет тот же
# код, а не пересказ: инлайн-кусок посреди прогона нечем позвать, и зуб на
# него пришлось бы городить полным прогоном конвейера.
#
# Поводы НАКАПЛИВАЮТСЯ, а не выбираются первым совпадением: ребёнок может
# назвать сразу два (якорь пропал И компилятор молчал), и «первый из списка»
# -- ровно тот дефект, который эта волна и разбирает. Пустой ответ означает
# «класс НЕ УСТАНОВЛЕН», и звонящий обязан сказать это словом, а не подставить
# любой из известных. Волна 48.
__emit_check_why() {   # <вывод разбора> -> печатает поводы через «; », либо ПУСТО
  local __o="$1" __w=""
  if [[ "$__o" == *"ЯКОРЬ НЕ НАЙДЕН"* ]]; then
    __w="$__w; якорь вклейки не найден -- проверять стало нечего"
  fi
  if [[ "$__o" == *"НЕ СТРОКА"* ]]; then
    __w="$__w; вклеиваемое значение оказалось НЕ строкой"
  fi
  if [[ "$__o" == *"tsc не запустился"* ]]; then
    __w="$__w; компилятор типов НЕ ЗАПУСТИЛСЯ -- его нет на PATH этого прогона"
  fi
  if [[ "$__o" == *"не выдав"* ]]; then
    __w="$__w; компилятор типов вышел с ошибкой, не дав ни одной диагностики"
  fi
  printf '%s\n' "${__w#; }"
}

echo "==> Разбор вклеиваемого кода"
# Вывод ребёнка ЗАХВАТЫВАЕТСЯ и печатается целиком, а не пересказывается.
# Код 2 у emit-check.js несёт ЧЕТЫРЕ повода разной природы -- пропал якорь
# вклейки (:40), вклеиваемое значение оказалось не строкой (:72), компилятор
# типов не запустился (:140), компилятор вышел с ошибкой, не дав ни одной
# диагностики (:169), -- а отказ называл ДВА первых из списка, какой бы ни
# сработал. Ровно эта строка увела расследование волны 45 в сторону, когда tsc
# просто не было на PATH у неинтерактивного ssh. Класс знает ТОЛЬКО ребёнок,
# значит, его надо прочитать у него, а не вспомнить. Волна 48.
#
# Молчание списка -- не повод назвать первый: если ни одна известная метка не
# встретилась, так и печатается «КЛАСС НЕ УСТАНОВЛЕН». Ребёнок мог обзавестись
# новым поводом, и подставить ему чужое имя хуже, чем сознаться.
set +e
__ec_out="$(node "$(dirname "$0")/tools/emit-check.js" 9>&- 2>&1)"
__rc=$?
set -e
if [[ -n "$__ec_out" ]]; then
  printf '%s\n' "$__ec_out"
fi
if (( __rc != 0 )); then
  if (( __rc == 2 )); then
    __ec_why="$(__emit_check_why "$__ec_out")" || { printf 'ПРИБОР НЕДОСТУПЕН: не собраны поводы отказа разбора\n' >&2; exit 2; }
    if [[ -n "$__ec_why" ]]; then
      echo "FATAL: разбор НЕ ВЫПОЛНЕН: прибор не может мерить (rc=2)." >&2
      echo "  ИЗМЕРЕННАЯ ПРИЧИНА: $__ec_why" >&2
    else
      echo "FATAL: разбор НЕ ВЫПОЛНЕН: прибор не может мерить (rc=2)." >&2
      echo "  КЛАСС НЕ УСТАНОВЛЕН: ни одна известная метка отказа не встретилась." >&2
      echo "  Смотреть вывод разбора выше -- у прибора появился новый повод." >&2
    fi
    echo "  Это не «код не парсится» -- покрытие снято." >&2
    exit 2
  fi
  exit 1
fi

# Зубы якоря heredoc'ов -- ДО разбора: правило «строка открывает питоновский
# heredoc» вынесено в единственный дом tools/heredoc-anchor.py, и его форма
# обязана держаться на синтетике раньше, чем по нему что-либо размечается.
echo "==> Зубы якоря heredoc'ов"
python3 "$(dirname "$0")/tools/heredoc-anchor.py" --self-check 9>&- || {
  __rc=$?
  case $__rc in
    2) echo "ЯКОРЬ HEREDOC'ОВ НЕ ИЗМЕРЯЛ: прибор не может мерить (rc=2)" >&2
       exit 2 ;;
    1) echo "ЯКОРЬ HEREDOC'ОВ БЕЗ ЗУБОВ: сужение правила не покраснело" >&2
       exit 1 ;;
    *) echo "ЯКОРЬ HEREDOC'ОВ УПАЛ: сценарий не сошёлся (rc=$__rc)" >&2
       exit 1 ;;
  esac
}

# The verify block is a python heredoc, and NOTHING was looking inside it:
# `bash -n` treats a heredoc as data and `node --check` has no opinion about
# python. So a stray parenthesis in a check was found only AFTER the patch stage
# had already rewritten the image -- minutes in, with a SyntaxError where the
# verdict should have been, and not one check having run. Compile it here, for
# the same reason the injected JS is parsed before anything is written: a gate
# that cannot run is not a lenient gate, it is an absent one.
echo "==> Разбор блока проверок"
python3 - "$0" <<'PYCOMPILE'
import glob, importlib.util, io, os, sys, warnings

path = sys.argv[1]
here = os.path.dirname(os.path.abspath(path))
lines = io.open(path, encoding='utf-8').read().split('\n')

# SyntaxWarning здесь -- ОШИБКА, а не шум. `\s` в обычном литерале уже
# сегодня печатает предупреждение в каждой сборке (пролезло раз), а в
# будущих Python станет SyntaxError -- то есть код перестанет разбираться
# целиком. Измерено: SyntaxWarning от compile() приходит СЮДА, в
# except SyntaxError -- CPython превращает предупреждение компиляции в
# ошибку того же класса, поэтому отдельная ветка была бы недостижима.
warnings.simplefilter('error', SyntaxWarning)

def check(src, name):
    try:
        compile(src, name, 'exec')
    except SyntaxError as e:
        print(f"НЕ РАЗБИРАЕТСЯ {name}: строка {e.lineno}: {e.msg}")
        sys.exit(1)

# Гейт покрывал ОДИН heredoc из восьми: остальные семь (и все отдельные
# .py кита) могли уехать в сборку с любой синтаксической поломкой, а
# упасть уже в бою -- в том числе ПОСЛЕ подмены образа. Поэтому здесь
# перечисляются ВСЕ питоновские heredoc'и всех .sh кита и все его .py-файлы.
# (Круг 28, F-13: прежде перечислялись heredoc'и ТОЛЬКО самого конвейера,
# а питоньи тела остальных .sh -- зонда пути, стенда корпусных инструментов --
# гейт не видел никогда, при целом объявлении «ВСЕ heredoc'и».)
# Правило «строка открывает питоновский heredoc» живёт в ЕДИНСТВЕННОМ доме --
# tools/heredoc-anchor.py: прежняя местная копия расходилась с копиями
# стендов кита, и ошибка каждой молчала. Зубы формы гоняет стадия выше; здесь
# правило только загружается, и отказ загрузки -- отказ стадии, а не откат к
# собственной редакции.
_anchor_spec = importlib.util.spec_from_file_location(
    'heredoc_anchor', os.path.join(here, 'tools/heredoc-anchor.py'))
if _anchor_spec is None or _anchor_spec.loader is None:
    print("ЯКОРЬ HEREDOC'ОВ НЕ ЗАГРУЖАЕТСЯ: нет tools/heredoc-anchor.py")
    sys.exit(2)
_anchor = importlib.util.module_from_spec(_anchor_spec)
try:
    _anchor_spec.loader.exec_module(_anchor)
except Exception as _e:    # отказ загрузки -- не откат к своей копии правила
    print(f"ЯКОРЬ HEREDOC'ОВ НЕ ЗАГРУЖАЕТСЯ: {_e}")
    sys.exit(2)
opener_match = _anchor.opener_match


def scan_heredocs(lines, where):
    """Все питоновские heredoc'и одного файла; (число, виден ли блок проверок)."""
    count, saw, i = 0, False, 0
    while i < len(lines):
        m = opener_match(lines[i])
        if not m:
            i += 1
            continue
        tag = m.group(1)
        end = next((j for j in range(i + 1, len(lines)) if lines[j] == tag), -1)
        if end < 0:
            print(f"HEREDOC НЕ ЗАКРЫТ: {tag} со строки {i + 1} ({where})")
            sys.exit(1)
        if lines[i].startswith('python3 - "$BIN" "$OUR_PATCH" <<'):
            saw = True
            print(f"БЛОК ПРОВЕРОК РАЗБИРАЕТСЯ ({end - i - 1} строк)")
        check('\n'.join(lines[i + 1:end]), f'{tag}@{i + 1} ({where})')
        count += 1
        i = end + 1
    return count, saw


blocks, verify_seen = scan_heredocs(lines, os.path.basename(path))
if not verify_seen:
    print("БЛОК ПРОВЕРОК НЕ НАЙДЕН -- предполётная проверка потеряла свой якорь")
    sys.exit(1)

# Остальные .sh кита: их питоньи тела раньше не проверял никто (F-13). Список
# строится теми же фильтрами, что и .py ниже; сам конвейер исключён -- он уже
# разобран выше, вместе со своим блоком проверок.
sh_files = sorted(
    f for f in glob.glob(os.path.join(here, '**', '*.sh'), recursive=True)
    if '/.git/' not in f and '/distros/' not in f
    and os.path.abspath(f) != os.path.abspath(path)
)
sh_blocks = 0
for f in sh_files:
    sh_blocks += scan_heredocs(
        io.open(f, encoding='utf-8').read().split('\n'),
        os.path.relpath(f, here))[0]

files = sorted(
    f for f in glob.glob(os.path.join(here, '**', '*.py'), recursive=True)
    if '/.git/' not in f and '/distros/' not in f
)
for f in files:
    check(io.open(f, encoding='utf-8').read(), os.path.relpath(f, here))

print(f"РАЗОБРАНО heredoc'ов конвейера {blocks}; .sh-файлов {len(sh_files)} "
      f"с heredoc'ами {sh_blocks}; файлов .py {len(files)}")
PYCOMPILE

# Имя переменной, склеенное с многобайтным символом.
#
# Bash на этой машине считает байты UTF-8 частью ИДЕНТИФИКАТОРА, поэтому
# «$want» -- это обращение к переменной `want»`, а не к `want` внутри кавычек.
# Под `set -u` строка падает с «unbound variable» вместо того, чтобы напечатать
# сообщение, -- и падает она ровно на ветке отказа, то есть там, где её никто
# не видит, пока всё зелено. Найдено ровно так: мутация покраснила сценарий не
# своей причиной, а крахом прибора (2026-08-28, два места в ките).
#
# Гейт с ПОЛОЖИТЕЛЬНЫМ контролем: сначала он обязан увидеть синтетический
# случай, и только потом его молчание на дереве что-то значит.
echo "==> Формы оболочки"
python3 - "$(dirname "$0")" <<'SHVARS' || { echo "ГЕЙТ ИМЁН ПЕРЕМЕННЫХ УПАЛ" >&2; exit 1; }
import io, os, re, sys

root = os.path.abspath(sys.argv[1])
# Спец-параметры ($1, $?, $@) состоят из одного символа, и разбор имени на них
# не распространяется -- ищем только именованные переменные.
PAT = re.compile(r'\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]')

# Контрольная строка СКЛЕИВАЕТСЯ из двух кусков: гейт обходит и файл, в
# котором сам лежит, и записанная целиком она была бы его собственной первой
# находкой -- ровно та самозацепка, на которой уже спотыкался гейт чисел.
control = 'bad "нет причины «$' + 'want»"'
if not PAT.search(control):
    print("ГЕЙТ ИМЁН СЛЕП: он не видит собственного контрольного случая")
    sys.exit(1)
if PAT.search('bad "нет причины «${want}»"'):
    print("ГЕЙТ ИМЁН ЛОЖНО СРАБАТЫВАЕТ: форма ${...} для него тоже находка")
    sys.exit(1)

# Правило 2: отрицание перед СОСТАВНОЙ командой с перенаправлением.
#
# `if ! { ...; } > файл; then` в bash 3.2 не видит провала перенаправления --
# оболочка печатает «Permission denied», условие оказывается ложным, и прогон
# едет дальше. Та же группа отдельной командой даёт rc=1, и `if ...; then :;
# else ...; fi` провал ловит; ломает дело именно `!`. Измерено 2026-08-28 на
# правке, которая как раз и заводила проверку записи -- то есть форма молча
# отменяла ровно ту гарантию, ради которой писалась.
NEG = re.compile(r'^\s*(?:if|while)\s+!\s*[{(]')
control2 = 'if ! { echo x; } > "$f"; then'
if not NEG.search(control2):
    print("ГЕЙТ ФОРМ СЛЕП: он не видит своего контрольного случая")
    sys.exit(1)
if NEG.search('if { echo x; } > "$f"; then'):
    print("ГЕЙТ ФОРМ ЛОЖНО СРАБАТЫВАЕТ: форма без отрицания для него тоже находка")
    sys.exit(1)

# Правило 3: непроверенная подстановка команды (измеренный класс 3a/3b/3c).
#
# Посылка «EXIT-трап + фатальная подстановка => rc=0» не воспроизводится
# (замер 2026-09-16, bash 3.2 и 5.2: оборвавшиеся формы отдают rc=1).
# Реальная маскировка: фатальная ошибка ВНУТРИ $(...) убивает подоболочку,
# внешний скрипт идёт дальше с пустой строкой и штатно возвращает 0.
# Часовой __DONE этот класс не ловит: скрипт дошёл до конца, __DONE=1.
#
# 3a (строчное): local|declare|typeset|export|readonly ИМЯ=$(...) --
# статус берёт builtin (всегда 0), errexit бессилен.
# 3b (волна 4 #219): красна подстановка-присваивание, чей код не проверен
# НИ ОДНИМ из четырёх способов на ЛОГИЧЕСКОЙ команде (склейка продолжений:
# неэкранированный `\`, нечёт кавычек, глубина $(/`(`/backtick):
# (1) `||`/`&&` СВОЕЙ команды -- левый операнд или тело $(); соседний
# сегмент на той же физической строке не считается;
# (2) следующая логическая команда -- присваивание `ИМЯ=$?` (префиксы
# local/declare/typeset/export); границу функции и терминатор heredoc
# не пересекать;
# (3) условный контекст: if/elif/while/until / [[ ]] / левый операнд &&/||;
# (4) явная область `set +e`/`set +o errexit` ... `set -e`/`set -o errexit`
# (или конец функции/файла), и внутри неё захват `$?` до конца области.
# Файловый `set -e` в критерий НЕ входит (sourcing). Тела heredoc сканируются
# как раньше: волна лечит способ судить уже сканируемую строку, не множество.
# 3c (строчное): $(...) в if/elif/while/[[/[ /case, чей код отбрасывается.
#
# Исключения (иначе ложные): $((...)) подстановкой не является;
# if [!] ИМЯ=$(...); then -- образцовая, находкой не бывает.
#
# Форма B (подстановка в аргументе другой команды) в гейт НЕ вносится:
# статически echo "версия: $(date)" неотличима от echo "зубов: $(wc -l < f)",
# а первая безвредна. Названная граница, не недосмотр; замер -- проба B.
#
# Часовой __DONE НЕ удаляется: переводит сигналы в коды (INT/TERM) и ловит
# ветку exit 0, не дошедшую до штатного конца. Это не ответ на подстановки.
# Наблюдённый вред: __DONE=1; exit $? возвращает код ПРИСВАИВАНИЯ (ноль) --
# tree-run.sh --self-check однажды вернул 0 при непройденном зубе.
IDENT = r'[A-Za-z_][A-Za-z0-9_]*'
ASSIGN_SUB = re.compile(
    r'(?:^|\s)(' + IDENT + r')=(?:\$\(|"\$\(|\'\$\()(?!\()')
ASSIGN_AT_START = re.compile(
    r'^' + IDENT + r'=(?:\$\(|"\$\(|\'\$\()(?!\()')
BUILTIN_3A = re.compile(
    r'^(?:local|declare|typeset|export|readonly)(?![A-Za-z0-9_])(.*)$')
CASE_ARM = re.compile(
    r'^(?:[A-Za-z0-9_.*?\[\]\\-]+(?:\|[A-Za-z0-9_.*?\[\]\\-]+)*)\)\s+')
IF_WORD = re.compile(r'^(?:if|elif|while)(?![A-Za-z0-9_])\s+(.*)$')
CASE_WORD = re.compile(r'^case(?![A-Za-z0-9_])\s+(\S+)')


def skip_balanced_paren(s, open_at):
    depth, i, quote, n = 1, open_at + 1, None, len(s)
    while i < n and depth:
        c = s[i]
        if quote == "'":
            if c == "'":
                quote = None
            i += 1
            continue
        if quote == '"':
            if c == '\\':
                i += 2
                continue
            if c == '"':
                quote = None
            i += 1
            continue
        if c == '\\':
            i += 2
            continue
        if c == "'":
            quote = "'"
            i += 1
            continue
        if c == '"':
            quote = '"'
            i += 1
            continue
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
        i += 1
    return i


def skip_dollar_sub(s, i):
    if s.startswith('$((', i):
        j, depth, n = i + 3, 2, len(s)
        while j < n and depth:
            if s.startswith('))', j) and depth == 2:
                return j + 2
            if s[j] == '(':
                depth += 1
            elif s[j] == ')':
                depth -= 1
            j += 1
        return n
    if s.startswith('$(', i):
        return skip_balanced_paren(s, i + 1)
    return i + 1


def split_simple_commands(s):
    # ; && || -- не внутри кавычек, $(...), $((...), [[ ]].
    parts, cmd_start, i, quote, n, dbl = [], 0, 0, None, len(s), 0
    while i < n:
        c = s[i]
        if quote == "'":
            if c == "'":
                quote = None
            i += 1
            continue
        if quote == '"':
            if c == '\\':
                i += 2
                continue
            if c == '"':
                quote = None
                i += 1
                continue
            if s.startswith('$(', i):
                i = skip_dollar_sub(s, i)
                continue
            i += 1
            continue
        if c == '\\':
            i += 2
            continue
        if c == "'":
            quote = "'"
            i += 1
            continue
        if c == '"':
            quote = '"'
            i += 1
            continue
        if s.startswith('$(', i):
            i = skip_dollar_sub(s, i)
            continue
        if s.startswith('[[', i):
            dbl += 1
            i += 2
            continue
        if dbl and s.startswith(']]', i):
            dbl -= 1
            i += 2
            continue
        if dbl:
            i += 1
            continue
        if s.startswith('&&', i) or s.startswith('||', i):
            parts.append(s[cmd_start:i])
            i += 2
            cmd_start = i
            continue
        if c == ';':
            parts.append(s[cmd_start:i])
            i += 1
            cmd_start = i
            continue
        i += 1
    parts.append(s[cmd_start:])
    return parts


def cmdsubs_in(s):
    hits, i, quote, n = [], 0, None, len(s)
    while i < n:
        c = s[i]
        if quote == "'":
            if c == "'":
                quote = None
            i += 1
            continue
        if quote == '"':
            if c == '\\':
                i += 2
                continue
            if c == '"':
                quote = None
                i += 1
                continue
            if s.startswith('$((', i):
                i = skip_dollar_sub(s, i)
                continue
            if s.startswith('$(', i):
                hits.append(i)
                i = skip_dollar_sub(s, i)
                continue
            i += 1
            continue
        if c == '\\':
            i += 2
            continue
        if c == "'":
            quote = "'"
            i += 1
            continue
        if c == '"':
            quote = '"'
            i += 1
            continue
        if s.startswith('$((', i):
            i = skip_dollar_sub(s, i)
            continue
        if s.startswith('$(', i):
            hits.append(i)
            i = skip_dollar_sub(s, i)
            continue
        i += 1
    return hits


def extract_double_brackets(s):
    out, i, quote, n = [], 0, None, len(s)
    while i < n:
        c = s[i]
        if quote == "'":
            if c == "'":
                quote = None
            i += 1
            continue
        if quote == '"':
            if c == '\\':
                i += 2
                continue
            if c == '"':
                quote = None
            i += 1
            continue
        if c == '\\':
            i += 2
            continue
        if c == "'":
            quote = "'"
            i += 1
            continue
        if c == '"':
            quote = '"'
            i += 1
            continue
        if s.startswith('$(', i):
            i = skip_dollar_sub(s, i)
            continue
        if s.startswith('[[', i):
            j, q2 = i + 2, None
            while j < n:
                d = s[j]
                if q2 == "'":
                    if d == "'":
                        q2 = None
                    j += 1
                    continue
                if q2 == '"':
                    if d == '\\':
                        j += 2
                        continue
                    if d == '"':
                        q2 = None
                    j += 1
                    continue
                if d == "'":
                    q2 = "'"
                    j += 1
                    continue
                if d == '"':
                    q2 = '"'
                    j += 1
                    continue
                if s.startswith(']]', j):
                    out.append(s[i:j + 2])
                    j += 2
                    break
                j += 1
            else:
                out.append(s[i:])
            i = j
            continue
        i += 1
    return out


def split_commands_marked(s):
    # Как split_simple_commands, но каждая часть несёт разделитель, которым
    # она отделена от СЛЕДУЮЩЕЙ: None (конец строки), ';', '&&', '||'.
    # Разделитель нужен проверке (б): захват кода -- это `;`-соседство,
    # а `&&`/`||` -- уже проверка (а).
    parts, cmd_start, i, quote, n, dbl = [], 0, 0, None, len(s), 0
    while i < n:
        c = s[i]
        if quote == "'":
            if c == "'":
                quote = None
            i += 1
            continue
        if quote == '"':
            if c == '\\':
                i += 2
                continue
            if c == '"':
                quote = None
                i += 1
                continue
            if s.startswith('$(', i):
                i = skip_dollar_sub(s, i)
                continue
            i += 1
            continue
        if c == '\\':
            i += 2
            continue
        if c == "'":
            quote = "'"
            i += 1
            continue
        if c == '"':
            quote = '"'
            i += 1
            continue
        if s.startswith('$(', i):
            i = skip_dollar_sub(s, i)
            continue
        if s.startswith('[[', i):
            dbl += 1
            i += 2
            continue
        if dbl and s.startswith(']]', i):
            dbl -= 1
            i += 2
            continue
        if dbl:
            i += 1
            continue
        if s.startswith('&&', i) or s.startswith('||', i):
            parts.append((s[cmd_start:i], s[i:i + 2]))
            i += 2
            cmd_start = i
            continue
        if c == ';':
            parts.append((s[cmd_start:i], ';'))
            i += 1
            cmd_start = i
            continue
        i += 1
    parts.append((s[cmd_start:], None))
    return parts


RC_CAPTURE = re.compile(
    r'^(?:(?:local|declare|typeset|export)\s+)?' + IDENT + r'=\$\?$')


def line_has_guard(s):
    # Проверка (а): `||`/`&&` на той же строке -- на уровне строки ПОСЛЕ
    # подстановки или внутри её тела. Кавычки отслеживаются ПО КОНТЕКСТУ:
    # внутри $(...) разбор начинается заново, поэтому контексты лежат на
    # стеке и снимаются закрывающей скобкой. `||`/`&&` ДО первой подстановки
    # код этой подстановки не проверяют -- не индульгенция.
    ctx, first_sub, i, n = [None], None, 0, len(s)
    while i < n:
        q, c = ctx[-1], s[i]
        if q == "'":
            if c == "'":
                ctx[-1] = None
            i += 1
            continue
        if q == '"':
            if c == '\\':
                i += 2
                continue
            # $(...) внутри кавычек разбирается ЗАНОВО: контекст кладётся на
            # стек, и `||` в его теле -- это гард, а не текст строки
            if s.startswith('$((', i):
                i = skip_dollar_sub(s, i)
                continue
            if s.startswith('$(', i):
                if first_sub is None:
                    first_sub = i
                ctx.append(None)
                i += 2
                continue
            if c == '"':
                ctx[-1] = None
            i += 1
            continue
        if c == '\\':
            i += 2
            continue
        if c == "'":
            ctx[-1] = "'"
            i += 1
            continue
        if c == '"':
            ctx[-1] = '"'
            i += 1
            continue
        if s.startswith('$((', i):
            i = skip_dollar_sub(s, i)
            continue
        if s.startswith('$(', i):
            if first_sub is None:
                first_sub = i
            ctx.append(None)
            i += 2
            continue
        if s.startswith('&&', i) or s.startswith('||', i):
            if len(ctx) > 1 or first_sub is not None:
                return True
            i += 2
            continue
        if c == ')' and len(ctx) > 1:
            ctx.pop()
            i += 1
            continue
        i += 1
    return False


def next_capture_line(lines, idx):
    # Проверка (б), межстрочная форма: следующая ИСПОЛНЯЕМАЯ строка
    # (пустые и целиком-комментарийные пропускаются). Заголовок функции
    # захватом не бывает: пара «заголовок + x=$? трапа» -- ложный случай,
    # устранённый ещё классификатором волны 2 (bun-drift.sh:59:60).
    j = idx + 1
    while j < len(lines):
        t = lines[j].strip()
        if t and not t.startswith('#'):
            return t
        j += 1
    return ''


def is_3a_command(cmd):
    m = BUILTIN_3A.match(cmd.strip())
    return bool(m) and ASSIGN_SUB.search(m.group(1)) is not None


def is_3b_command(cmd):
    s = cmd.strip()
    if not s or is_3a_command(s):
        return False
    if re.match(r'^(?:if|elif|while|until|case|then|do|done|fi|esac|else)\b', s):
        return False
    if s.startswith('[[') or re.match(r'^\[\s', s):
        return False
    if not s.startswith('$('):
        s = CASE_ARM.sub('', s, count=1)
    return ASSIGN_AT_START.match(s) is not None



def try_parse_heredoc(s, i):
    # CONSTRAINT: <<< -- here-string, не heredoc; полный разбор bash запрещён.
    if not s.startswith('<<', i) or s.startswith('<<<', i):
        return None
    j = i + 2
    strip_tabs = False
    if j < len(s) and s[j] == '-':
        strip_tabs = True
        j += 1
    while j < len(s) and s[j] in ' \t':
        j += 1
    if j >= len(s):
        return None
    if s[j] in ('"', "'"):
        q = s[j]
        j += 1
        start = j
        while j < len(s) and s[j] != q:
            j += 1
        tag = s[start:j]
        if j < len(s) and s[j] == q:
            j += 1
        if not tag:
            return None
        return (tag, strip_tabs, j)
    if s[j] == '\\':
        j += 1
    start = j
    while j < len(s) and (s[j].isalnum() or s[j] == '_'):
        j += 1
    tag = s[start:j]
    if not tag:
        return None
    return (tag, strip_tabs, j)


def is_heredoc_term(line, tag, strip_tabs):
    s = line.lstrip('\t') if strip_tabs else line
    return s == tag


class _Scan:
    # quote/paren/backtick на каждом уровне $( ); heredocs -- очередь тегов.
    def __init__(self):
        self.ctx = [None]
        self.paren = [0]
        self.btick = [False]
        self.heredocs = []
        self.line_cont = False

    def open_shell(self):
        return (
            self.line_cont
            or any(c is not None for c in self.ctx)
            or any(p > 0 for p in self.paren)
            or any(self.btick)
            or len(self.ctx) > 1
        )


def _walk_line(st, line):
    st.line_cont = False
    i, n = 0, len(line)
    while i < n:
        q, c = st.ctx[-1], line[i]
        if q == "'":
            if c == "'":
                st.ctx[-1] = None
            i += 1
            continue
        if q == '"':
            if c == '\\':
                if i == n - 1:
                    st.line_cont = True
                    break
                i += 2
                continue
            if c == '"':
                st.ctx[-1] = None
                i += 1
                continue
            if line.startswith('$(', i):
                st.ctx.append(None)
                st.paren.append(0)
                st.btick.append(False)
                i += 2
                continue
            i += 1
            continue
        if st.btick[-1]:
            if c == '\\':
                i += 2
                continue
            if c == '`':
                st.btick[-1] = False
                i += 1
                continue
            if line.startswith('$(', i):
                st.ctx.append(None)
                st.paren.append(0)
                st.btick.append(False)
                i += 2
                continue
            i += 1
            continue
        if c == '\\':
            if i == n - 1:
                st.line_cont = True
                break
            i += 2
            continue
        if c == "'":
            st.ctx[-1] = "'"
            i += 1
            continue
        if c == '"':
            st.ctx[-1] = '"'
            i += 1
            continue
        if c == '`' :
            st.btick[-1] = True
            i += 1
            continue
        if c == '#' and (i == 0 or line[i - 1].isspace()):
            break
        # CONSTRAINT: here-string съедается ТРЕМЯ символами здесь, а не отказом
        # в try_parse_heredoc. Отказ там возвращал управление в цикл БЕЗ
        # сдвига, и со следующего символа парсер видел остаток `<<` -- уже не
        # похожий на `<<<` -- то есть заводил heredoc с тегом из строки справа
        # (`done <<< "$ids"` давал тег $ids). Такой терминатор не встречается
        # никогда, поэтому ВЕСЬ остаток файла уходил в тело heredoc, где
        # действует ослабленный построчный предикат: пояс на закрывающей
        # строке многострочной подстановки он не видит. Волна 6 намерила этим
        # 18 ложных флагов на уже вылеченном коде.
        if line.startswith('<<<', i):
            i += 3
            continue
        parsed = try_parse_heredoc(line, i)
        if parsed is not None:
            tag, strip, j = parsed
            st.heredocs.append((tag, strip))
            i = j
            continue
        if line.startswith('$(', i):
            st.ctx.append(None)
            st.paren.append(0)
            st.btick.append(False)
            i += 2
            continue
        if c == '(':
            st.paren[-1] += 1
            i += 1
            continue
        if c == ')':
            if st.paren[-1] > 0:
                st.paren[-1] -= 1
                i += 1
                continue
            if len(st.ctx) > 1:
                st.ctx.pop()
                st.paren.pop()
                st.btick.pop()
                i += 1
                continue
            i += 1
            continue
        i += 1


class _LCmd:
    __slots__ = ('start', 'end', 'text', 'spans', 'in_plus_e')

    def __init__(self, start):
        self.start = start
        self.end = start
        self.text = ''
        self.spans = []
        self.in_plus_e = False


def _analyze_logical(lines):
    # Склейка физических строк в логические. Тела heredoc в text не входят:
    # операторы внутри данных не судят команду (инвариант волны: множество
    # сканируемых строк не меняется -- тела остаются кандидатами построчно).
    lcmds = []
    body_set = set()
    n = len(lines)
    i = 0
    st = _Scan()
    acc = None

    def flush():
        nonlocal acc, st
        if acc is not None:
            lcmds.append(acc)
        acc = None
        st = _Scan()

    while i < n:
        if st.heredocs:
            tag, strip = st.heredocs[0]
            if is_heredoc_term(lines[i], tag, strip):
                st.heredocs.pop(0)
                i += 1
                if not st.heredocs and acc is not None and not st.open_shell():
                    flush()
                continue
            body_set.add(i)
            i += 1
            continue

        line = lines[i]
        if acc is None and not st.open_shell():
            if not line.strip() or line.lstrip().startswith('#'):
                i += 1
                continue

        if acc is None:
            acc = _LCmd(i)
        prev_cont = st.line_cont
        if prev_cont:
            if acc.text.endswith('\\'):
                acc.text = acc.text[:-1]
            if acc.text and not acc.text.endswith((' ', '\t')):
                acc.text += ' '
            start_off = len(acc.text)
            acc.text += line
        else:
            if acc.text:
                acc.text += '\n'
            start_off = len(acc.text)
            acc.text += line
        acc.spans.append((i, start_off, len(acc.text)))
        acc.end = i
        _walk_line(st, line)
        i += 1
        if st.heredocs:
            continue
        if not st.open_shell():
            flush()

    if acc is not None:
        lcmds.append(acc)
    return lcmds, body_set


def _strip_unquoted_comment(s):
    i, quote, n = 0, None, len(s)
    while i < n:
        c = s[i]
        if quote == "'":
            if c == "'":
                quote = None
            i += 1
            continue
        if quote == '"':
            if c == '\\':
                i += 2
                continue
            if c == '"':
                quote = None
            i += 1
            continue
        if c == '\\':
            i += 2
            continue
        if c == "'":
            quote = "'"
            i += 1
            continue
        if c == '"':
            quote = '"'
            i += 1
            continue
        if c == '#' and (i == 0 or s[i - 1].isspace()):
            return s[:i].rstrip()
        i += 1
    return s.rstrip()


def split_segments_marked(s):
    # Как split_commands_marked, плюс незакавыченные `|` и перевод строки.
    # `||` проверяется раньше `|`. Внутри $(...) / [[ ]] не режем.
    parts, cmd_start, i, quote, n, dbl = [], 0, 0, None, len(s), 0
    while i < n:
        c = s[i]
        if quote == "'":
            if c == "'":
                quote = None
            i += 1
            continue
        if quote == '"':
            if c == '\\':
                i += 2
                continue
            if c == '"':
                quote = None
                i += 1
                continue
            if s.startswith('$(', i):
                i = skip_dollar_sub(s, i)
                continue
            i += 1
            continue
        if c == '\\':
            i += 2
            continue
        if c == "'":
            quote = "'"
            i += 1
            continue
        if c == '"':
            quote = '"'
            i += 1
            continue
        if s.startswith('$(', i):
            i = skip_dollar_sub(s, i)
            continue
        if s.startswith('[[', i):
            dbl += 1
            i += 2
            continue
        if dbl and s.startswith(']]', i):
            dbl -= 1
            i += 2
            continue
        if dbl:
            i += 1
            continue
        if s.startswith('&&', i) or s.startswith('||', i):
            parts.append((s[cmd_start:i], s[i:i + 2], cmd_start))
            i += 2
            cmd_start = i
            continue
        if c == '|':
            parts.append((s[cmd_start:i], '|', cmd_start))
            i += 1
            cmd_start = i
            continue
        if c == ';' or c == '\n':
            parts.append((s[cmd_start:i], ';', cmd_start))
            i += 1
            cmd_start = i
            continue
        i += 1
    parts.append((s[cmd_start:], None, cmd_start))
    return parts


def _phys_of(lc, off):
    for idx, start, end in lc.spans:
        if start <= off < end or (off == end and start <= off):
            return idx
    if lc.spans:
        if off >= lc.spans[-1][2]:
            return lc.spans[-1][0]
        if off < lc.spans[0][1]:
            return lc.spans[0][0]
    return lc.start


FUNC_HEAD = re.compile(
    r'^(?:function\s+' + IDENT + r'(?:\s*\(\s*\))?|' + IDENT + r'\s*\(\s*\))\s*\{?\s*$')
FUNC_CLOSE = re.compile(r'^\}\s*$')
SET_PLUS_E = re.compile(r'^set\s+(?:\+e|\+o\s+errexit)\s*$')
SET_MINUS_E = re.compile(r'^set\s+(?:-e|-o\s+errexit)\s*$')


def _lc_head(lc):
    return _strip_unquoted_comment(lc.text).strip()


def _mark_plus_e(lcmds):
    plus = False
    for lc in lcmds:
        t = _lc_head(lc)
        if FUNC_HEAD.match(t):
            lc.in_plus_e = plus
            continue
        if FUNC_CLOSE.match(t):
            lc.in_plus_e = False
            plus = False
            continue
        if SET_PLUS_E.match(t):
            lc.in_plus_e = False
            plus = True
            continue
        if SET_MINUS_E.match(t):
            lc.in_plus_e = False
            plus = False
            continue
        lc.in_plus_e = plus


def _is_boundary_cmd(text):
    t = _strip_unquoted_comment(text).strip()
    return bool(FUNC_HEAD.match(t) or FUNC_CLOSE.match(t))


def _is_capture_cmd(text):
    t = _strip_unquoted_comment(text).strip()
    if not t:
        return False
    first = split_segments_marked(t)[0][0].strip()
    return RC_CAPTURE.match(first) is not None


def _old_verified(line, marked, site, lines, idx):
    if line_has_guard(line):
        return True
    if marked[site][1] == ';' and site + 1 < len(marked) and RC_CAPTURE.match(
            marked[site + 1][0].strip()):
        return True
    if site == len(marked) - 1 and RC_CAPTURE.match(
            next_capture_line(lines, idx).split(';')[0].strip()):
        return True
    return False


def _verified_on_lc(lc, lcmds, lc_i, idx):
    segs = split_segments_marked(lc.text)
    site_seg = None
    for k, (part, sep, off) in enumerate(segs):
        if not is_3b_command(part):
            continue
        if _phys_of(lc, off) != idx:
            continue
        site_seg = k
        break
    if site_seg is None:
        # Кандидат на физической строке не совпал с сегментом склейки --
        # судим сегменты, чьё начало на этой строке; иначе не освобождаем.
        for k, (part, sep, off) in enumerate(segs):
            if is_3b_command(part) and _phys_of(lc, off) == idx:
                site_seg = k
                break
    if site_seg is None:
        return False
    part, sep, _off = segs[site_seg]
    # 1: ||/&& своей команды -- внутренний (тело $()) или левый операнд.
    if line_has_guard(part):
        return True
    if sep in ('&&', '||'):
        return True
    # 2: захват $? той же логической командой через `;`
    if sep == ';' and site_seg + 1 < len(segs) and RC_CAPTURE.match(
            segs[site_seg + 1][0].strip()):
        return True
    # CONSTRAINT: следующая логическая команда захватывает $? сайта только
    # если сайт -- последний непустой сегмент; иначе $? принадлежит
    # последнему сегменту этой же команды (`v=$(cmd); echo x` / `rc=$?`).
    last_nonempty = site_seg
    for k, (p, _s, _o) in enumerate(segs):
        if p.strip():
            last_nonempty = k
    if site_seg == last_nonempty:
        nxt = lcmds[lc_i + 1] if lc_i + 1 < len(lcmds) else None
        if nxt is not None and not _is_boundary_cmd(nxt.text) and _is_capture_cmd(nxt.text):
            return True
    # 4: явная область set +e ... set -e, захват $? до конца области.
    # Тот же констрейнт «сайт последний»: иначе $? в области принадлежит
    # чужому сегменту, как в пункте 2.
    if lc.in_plus_e:
        if sep == ';' and site_seg + 1 < len(segs) and RC_CAPTURE.match(
                segs[site_seg + 1][0].strip()):
            return True
        if site_seg == last_nonempty:
            for later in lcmds[lc_i + 1:]:
                if not later.in_plus_e and not SET_MINUS_E.match(_lc_head(later)):
                    break
                if _is_boundary_cmd(later.text) or SET_MINUS_E.match(_lc_head(later)):
                    break
                if _is_capture_cmd(later.text):
                    return True
                break
    return False


def cmd_3c_hits(cmd):
    s = cmd.strip()
    if not s:
        return []
    body = s
    m = IF_WORD.match(s)
    if m:
        body = re.sub(r'^!\s*', '', m.group(1))
    hits = []
    for frag in extract_double_brackets(body):
        hits.extend(cmdsubs_in(frag))
    if re.match(r'^\[\s', body) and not body.startswith('[['):
        hits.extend(cmdsubs_in(body))
    cm = CASE_WORD.match(s)
    if cm:
        hits.extend(cmdsubs_in(cm.group(1)))
    return hits


def _iter_cmds(text):
    for n, line in enumerate(text.split('\n'), 1):
        if line.lstrip().startswith('#'):
            continue
        for cmd in split_simple_commands(line):
            yield n, line, cmd


def hits_3a(text):
    seen, out = set(), []
    for n, line, cmd in _iter_cmds(text):
        if n not in seen and is_3a_command(cmd):
            seen.add(n)
            out.append((n, line))
    return out


def hits_3b(text):
    # Единица отчёта -- строка-место. Суждение -- логическая команда (§3a).
    # Тело heredoc: прежний построчный предикат (множество сканируемых строк).
    lines = text.split('\n')
    lcmds, body_set = _analyze_logical(lines)
    _mark_plus_e(lcmds)
    phys_to_lc = {}
    for li, lc in enumerate(lcmds):
        for pidx, _s, _e in lc.spans:
            phys_to_lc[pidx] = li
    out = []
    for idx, line in enumerate(lines):
        if line.lstrip().startswith('#'):
            continue
        marked = split_commands_marked(line)
        site = None
        for j, (part, _sep) in enumerate(marked):
            if is_3b_command(part):
                site = j
                break
        if site is None:
            continue
        if idx in body_set or idx not in phys_to_lc:
            if _old_verified(line, marked, site, lines, idx):
                continue
            out.append((idx + 1, line))
            continue
        if _verified_on_lc(lcmds[phys_to_lc[idx]], lcmds, phys_to_lc[idx], idx):
            continue
        out.append((idx + 1, line))
    return out


def hits_3c(text):
    seen, out = set(), []
    for n, line, cmd in _iter_cmds(text):
        if n not in seen and cmd_3c_hits(cmd):
            seen.add(n)
            out.append((n, line))
    return out


# Контроли СКЛЕИВАЮТСЯ: записанные целиком, они были бы находкой в самом гейте.
_s3a = 'local x=' + '$(cmd)'
if not hits_3a(_s3a + '\n'):
    print("ГЕЙТ 3a СЛЕП: он не видит local x=$(cmd)")
    sys.exit(1)
if hits_3a('local x\nx=' + '$(cmd)\n'):
    print("ГЕЙТ 3a ЛОЖНО СРАБАТЫВАЕТ: local и присваивание разными строками -- тоже находка")
    sys.exit(1)

_s3b = 'v=' + '$(cmd)\n'
if not hits_3b(_s3b):
    print("ГЕЙТ 3b СЛЕП: он не видит v=$(cmd) без проверки кода")
    sys.exit(1)
if not hits_3b('set -euo pipefail\nv=' + '$(cmd)\n'):
    print("ГЕЙТ 3b СЛЕП: строка set -e не проверяет код подстановки -- "
          "правило построчное, индульгенции по файлу нет")
    sys.exit(1)
if hits_3b('v=' + '$(cmd) || die "отказ"\n'):
    print("ГЕЙТ 3b ЛОЖНО СРАБАТЫВАЕТ: || после подстановки -- код проверен")
    sys.exit(1)
if hits_3b('v="' + '$(cmd || true)"\n'):
    print("ГЕЙТ 3b ЛОЖНО СРАБАТЫВАЕТ: || внутри подстановки -- код проверен")
    sys.exit(1)
if hits_3b('v=' + '$(cmd); rc=' + '$?\n'):
    print("ГЕЙТ 3b ЛОЖНО СРАБАТЫВАЕТ: захват rc=$? той же строкой -- код проверен")
    sys.exit(1)
if hits_3b('v=' + '$(cmd)\nrc=' + '$?\n'):
    print("ГЕЙТ 3b ЛОЖНО СРАБАТЫВАЕТ: захват rc=$? следующей строкой -- код проверен")
    sys.exit(1)
if not hits_3b('v=' + '$(cmd)\necho x\nrc=' + '$?\n'):
    print("ГЕЙТ 3b СЛЕП: захват через строку кода подстановки уже не ловит")
    sys.exit(1)
if hits_3b('v=' + '$(cmd) || die\n'):
    print("ГЕЙТ 3b R1 ЛОЖНО СРАБАТЫВАЕТ: || своей команды -- код проверен")
    sys.exit(1)
if not hits_3b('v=' + '$(cmd); true || false\n'):
    print("ГЕЙТ 3b R1 СЛЕП: || соседней команды на строке не проверяет подстановку")
    sys.exit(1)
if hits_3b('v=' + '$(cmd)\nrc=' + '$?\n'):
    print("ГЕЙТ 3b R2 ЛОЖНО СРАБАТЫВАЕТ: захват следующей командой -- код проверен")
    sys.exit(1)
if not hits_3b('v=' + '$(cmd)\necho x\nrc=' + '$?\n'):
    print("ГЕЙТ 3b R2 СЛЕП: захват через чужую команду не ловит")
    sys.exit(1)
if hits_3b('if v=' + '$(cmd); then\n'):
    print("ГЕЙТ 3b R3 ЛОЖНО СРАБАТЫВАЕТ: if v=$(cmd) -- условный контекст")
    sys.exit(1)
if not hits_3b('v=' + '$(cmd)\n'):
    print("ГЕЙТ 3b R3 СЛЕП: без условного контекста не ловит")
    sys.exit(1)
if hits_3b('until v=' + '$(cmd); do\n'):
    print("ГЕЙТ 3b R3 ЛОЖНО СРАБАТЫВАЕТ: until v=$(cmd) -- условный контекст")
    sys.exit(1)
if hits_3b('set +e\nv=' + '$(cmd)\nrc=' + '$?\nset -e\n'):
    print("ГЕЙТ 3b R4 ЛОЖНО СРАБАТЫВАЕТ: set +e и захват $? в области -- код проверен")
    sys.exit(1)
if not hits_3b('set +e\nv=' + '$(cmd)\nset -e\n'):
    print("ГЕЙТ 3b R4 СЛЕП: set +e без захвата $? не проверяет код")
    sys.exit(1)
if not hits_3b('v=' + '$(cmd); echo x\nrc=' + '$?\n'):
    print("ГЕЙТ 3b R2 СЛЕП: $? после чужого сегмента той же команды не принадлежит подстановке")
    sys.exit(1)
if not hits_3b('set +e\nv=' + '$(cmd); echo x\nrc=' + '$?\nset -e\n'):
    print("ГЕЙТ 3b R4 СЛЕП: $? после чужого сегмента в области set +e не принадлежит подстановке")
    sys.exit(1)
if hits_3b('v="' + '$(cmd \\\n  | x || true)"\n'):
    print("ГЕЙТ 3b ЛОЖНО СРАБАТЫВАЕТ: || на продолжении логической команды -- код проверен")
    sys.exit(1)
if hits_3b('set +e\nv="' + '$(cmd \\\n  x)"; rc=' + '$?\nset -e\n'):
    print("ГЕЙТ 3b ЛОЖНО СРАБАТЫВАЕТ: set +e, продолжение и захват -- код проверен")
    sys.exit(1)

_s3c_a = 'if [[ "'
_s3c_b = '$(cmd)" == "" ]]'
if not hits_3c(_s3c_a + _s3c_b + '\n'):
    print("ГЕЙТ 3c СЛЕП: он не видит if [[ \"$(cmd)\" == \"\" ]]")
    sys.exit(1)
if hits_3c('if cmd; then\n'):
    print("ГЕЙТ 3c ЛОЖНО СРАБАТЫВАЕТ: if cmd для него тоже находка")
    sys.exit(1)

_arith_n = 'n=$((n+1))\n'
_arith_if = 'if (( n )); then\n'
if hits_3a(_arith_n) or hits_3b(_arith_n) or hits_3c(_arith_n):
    print("ГЕЙТ АРИФМЕТИКИ ЛОЖНО СРАБАТЫВАЕТ: n=$((n+1)) для него находка")
    sys.exit(1)
if hits_3a(_arith_if) or hits_3b(_arith_if) or hits_3c(_arith_if):
    print("ГЕЙТ АРИФМЕТИКИ ЛОЖНО СРАБАТЫВАЕТ: if (( n )) для него находка")
    sys.exit(1)

_verified = 'if ! got=' + '$(cmd); then\n'
if hits_3a(_verified) or hits_3b(_verified) or hits_3c(_verified):
    print("ГЕЙТ ПРОВЕРЕННОЙ ФОРМЫ ЛОЖНО СРАБАТЫВАЕТ: if ! got=$(cmd) для него находка")
    sys.exit(1)

# Часовой __DONE остаётся (сигналы и ветки exit 0), основание -- не подстановки.
TRAP = re.compile(r'^\s*trap\s+[^\n]*\bEXIT\b', re.M)

def sentinel_missing(text):
    lines = [l for l in text.split('\n') if not l.lstrip().startswith('#')]
    body = '\n'.join(lines)
    if not TRAP.search(body):
        return False
    return '__DONE=1' not in body or '__DONE=0' not in body

# Контроль СКЛЕИВАЕТСЯ: записанный целиком, он был бы находкой в самом гейте.
_trap_line = 'trap' + ' cleanup EXIT'
if not sentinel_missing('set -u\n' + _trap_line + '\nrm -rf x\n'):
    print("ГЕЙТ ЧАСОВОГО СЛЕП: он не видит трапа без часового")
    sys.exit(1)
if sentinel_missing('__DONE=0\n' + _trap_line + '\n__DONE=1\n'):
    print("ГЕЙТ ЧАСОВОГО ЛОЖНО СРАБАТЫВАЕТ: файл с часовым для него тоже находка")
    sys.exit(1)

# Правило 4 (волна 26): слитый сигнальный трап.
#
# `trap guard EXIT INT TERM` на TERM отдаёт КОД 0, а не 143: сигнал входит в
# общий гвард, `$?` в нём уже ноль, и убитый прогон зеленеет (измерено
# контроллером волны 26; парные мутации -- в corpus-tools-bench). Сигнальные
# трапы переводят сигнал в КОД и стоят ОТДЕЛЬНЫМИ строками -- образец
# tools/fetch-corpus.sh. Строки-ДАННЫХ таблиц мутаций (начинаются не с `trap`)
# правилом не задеваются.
def merged_trap(line):
    if not re.match(r'\s*trap\s', line):
        return False
    return re.search(r'\bEXIT\b', line) is not None \
        and re.search(r'\b(?:INT|TERM|HUP)\b', line) is not None

_merged = 'trap' + ' __exit_guard EXIT INT TERM'
if not merged_trap(_merged):
    print("ГЕЙТ ТРАПОВ СЛЕП: он не видит слитого трапа")
    sys.exit(1)
if merged_trap("trap '__exit_guard' EXIT"):
    print("ГЕЙТ ТРАПОВ ЛОЖНО СРАБАТЫВАЕТ: раздельный EXIT-трап для него тоже находка")
    sys.exit(1)
if merged_trap("trap 'exit 143' TERM"):
    print("ГЕЙТ ТРАПОВ ЛОЖНО СРАБАТЫВАЕТ: раздельный сигнальный трап для него тоже находка")
    sys.exit(1)

# CONSTRAINT: here-string не открывает heredoc. Зуб держит ОБЕ стороны: ложный
# флаг на вылеченном коде ниже `<<<` (прежний дефект парсера) и слепоту к
# непроверенной подстановке там же. Проба даётся ниже here-string намеренно --
# именно позиция «после <<<» и была зоной, где предикат терял пояс.
_HS_HEAD = 'done <<' + '< "$ids"\n'
_HS_GUARDED = _HS_HEAD + 'v="$(cmd \\\n  | filter)" || { echo fail >&2; exit 2; }\n'
_HS_BARE = _HS_HEAD + 'v="$(cmd \\\n  | filter)"\n'
if hits_3b(_HS_GUARDED):
    print("ГЕЙТ ФОРМ ЛОЖНО СРАБАТЫВАЕТ: here-string принят за heredoc, "
          "пояс на закрывающей строке потерян")
    sys.exit(1)
if not hits_3b(_HS_BARE):
    print("ГЕЙТ ФОРМ СЛЕП: непроверенная подстановка ниже here-string не найдена")
    sys.exit(1)

# Реестр ОБЪЯВЛЕННЫХ мест 3b. Существует потому, что у правила есть законные
# исключения двух родов: фикстура, где пояс заменил бы предмет замера, и
# строка-данные, которая не исполняется вовсе. Чинить их -- подгонять предмет
# под прибор. Молчать о них -- escape hatch без следа. Поэтому объявление:
# поимённое, с причиной и с ДВУСТОРОННЕЙ сверкой (образец --
# tweakcc-known-misses.txt). Якорь -- ТЕКСТ строки: номера едут при правке выше.
# Отказ чтения реестра -- отказ ПРИБОРА (код 2), а не вердикт формы: пустой
# реестр молча снял бы защиту со всех объявленных мест сразу.
_known_path = os.path.join(root, 'tools', 'shvars-known-sites.txt')
_known = {}
if os.path.isfile(_known_path):
    try:
        _ktext = io.open(_known_path, encoding='utf-8').read()
    except (OSError, UnicodeDecodeError):
        print("ПРИБОР НЕДОСТУПЕН: реестр объявленных мест 3b не читается")
        sys.exit(2)
    for _kline in _ktext.split('\n'):
        if not _kline.strip() or _kline.lstrip().startswith('#'):
            continue
        _kp = _kline.split('\t')
        if len(_kp) < 3 or not _kp[0].strip() or not _kp[1].strip() or not _kp[2].strip():
            print("ПРИБОР НЕДОСТУПЕН: строка реестра 3b неполна "
                  "(нужны путь, якорь и причина): " + _kline[:80])
            sys.exit(2)
        _known[(_kp[0].strip(), _kp[1].strip())] = _kp[2].strip()
_known_used = set()

bad = []
scanned = 0
n3a = n3b = n3c = n_sentinel = n3b_files = 0
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in ('.git', 'distros', 'node_modules')]
    for name in sorted(filenames):
        if not (name.endswith('.sh') or name == 'claude-patch-all.sh'):
            continue
        f = os.path.join(dirpath, name)
        try:
            text = io.open(f, encoding='utf-8').read()
        except (OSError, UnicodeDecodeError):
            continue
        scanned += 1
        rel = os.path.relpath(f, root)
        if sentinel_missing(text):
            n_sentinel += 1
            bad.append(f"{rel}: EXIT-трап без часового завершения -- "
                       f"ветка exit 0 до штатного конца не будет поймана")
        for n, line in hits_3a(text):
            n3a += 1
            snip = line.strip()
            if len(snip) > 120:
                snip = snip[:117] + "..."
            bad.append(f"{rel}:{n}: 3a builtin ИМЯ=$" + "(...) -- статус берёт "
                       f"local/declare/typeset/export/readonly, errexit бессилен -- {snip}")
        # Объявленное место снимается с учёта ЗДЕСЬ и отмечается использованным:
        # по этой отметке ниже ловится запись, пережившая свою причину.
        _b3 = []
        for _n3, _l3 in hits_3b(text):
            _k3 = (rel, _l3.strip())
            if _k3 in _known:
                _known_used.add(_k3)
                continue
            _b3.append((_n3, _l3))
        if _b3:
            n3b_files += 1
        for n, line in _b3:
            n3b += 1
            snip = line.strip()
            if len(snip) > 120:
                snip = snip[:117] + "..."
            bad.append(f"{rel}:{n}: 3b код подстановки не проверен -- ни "
                       f"||/&& на строке, ни захвата кода, ни условного "
                       f"контекста -- {snip}")
        for n, line in hits_3c(text):
            n3c += 1
            snip = line.strip()
            if len(snip) > 120:
                snip = snip[:117] + "..."
            bad.append(f"{rel}:{n}: 3c подстановка в условном контексте -- "
                       f"код отбрасывается -- {snip}")
        for n, line in enumerate(text.split('\n'), 1):
            # Строка-комментарий целиком пропускается: она не исполняется, а
            # объяснить дефект без того, чтобы написать его форму, нельзя --
            # эта самая преамбула им и была. Комментарий В КОНЦЕ строки кода
            # не спасает: у такой строки есть исполняемая часть, и она
            # проверяется как обычно.
            if line.lstrip().startswith('#'):
                continue
            for m in PAT.finditer(line):
                bad.append(f"{os.path.relpath(f, root)}:{n}: имя склеено -- {m.group()}")
            # Перенаправление ищется в той же строке или в строке, где
            # составная команда закрывается: `{` и `}` часто на разных строках.
            if NEG.search(line):
                tail = '\n'.join(text.split('\n')[n - 1:n + 8])
                if re.search(r'[});]\s*>[^&]', tail):
                    bad.append(f"{os.path.relpath(f, root)}:{n}: "
                               f"отрицание перед составной командой с перенаправлением -- "
                               f"провал записи не будет замечен")
            if merged_trap(line):
                bad.append(f"{os.path.relpath(f, root)}:{n}: слитый сигнальный трап "
                           f"(EXIT вместе с INT/TERM) -- TERM отдаёт 0, а не 143")
# Вторая сторона сверки. Без неё реестр стал бы бессрочной индульгенцией:
# место вылечили или удалили, а запись осталась бы снимать защиту с будущей
# строки, которая однажды совпадёт с якорем текстуально.
for _k3, _why3 in sorted(_known.items()):
    if _k3 not in _known_used:
        bad.append(f"{_k3[0]}: объявленное место 3b БОЛЬШЕ НЕ срабатывает -- "
                   f"запись пережила свою причину, снимите её из "
                   f"tools/shvars-known-sites.txt -- якорь: {_k3[1][:90]}")

print(f"ПОДФОРМЫ ПРАВИЛА 3: 3a={n3a} строк; 3b={n3b} строк / {n3b_files} файлов; "
      f"3c={n3c} строк; часовой={n_sentinel} "
      f"(единица 3a/3b/3c -- строка-место, не вхождение; "
      f"в одной строке может быть несколько подстановок)")
if bad:
    print("ФОРМЫ ОБОЛОЧКИ, КОТОРЫЕ МОЛЧАТ "
          "(список -- строки-места file:line, не вхождения подстановки):")
    for b in bad:
        print("  " + b)
    sys.exit(1)
print(f"ФОРМЫ ОБОЛОЧКИ ЧИСТЫ: разобрано файлов {scanned}")
SHVARS

# Ручек ДВЕ, потому что предметов два, и путать их дорого в обе стороны.
# CLAUDE_PATCH_SKIP_KIT_BENCH гасит стенды, чей предмет -- САМ КИТ: между
# сборками одной волны они мерят один и тот же неизменившийся предмет и стоят
# минуты на КАЖДУЮ сборку. CLAUDE_PATCH_SKIP_BENCH гасит стенд зондов, чей
# предмет -- СОБРАННЫЙ ОБРАЗ (поведение судьи и наблюдателя внутри него), и он
# у каждой версии свой. Одна общая ручка успела побывать обеими ошибками:
# сперва имя обещало батарею, а гасило один стенд из пяти, и оператор платил
# полную цену молча; затем, когда ею накрыли батарею, свип перестал проверять
# зонды на всех версиях кроме первой -- потеря покрытия, которую поймал его же
# вердикт. Пропуск ОБЪЯВЛЯЕТСЯ поимённо: escape hatch без следа неотличим от
# гейта, который отработал.
# CONSTRAINT: имена стендов объявлены ЗДЕСЬ один раз и читаются обеими
# сторонами -- и текстом пропуска, и заголовками прогона. Прежде пропуск
# перечислял их своими словами: перечень, живущий рядом со своим домом,
# расходится молча, и ручка называла бы оператору не то, что она гасит на
# самом деле, -- ровно тот вред, против которого поимённое объявление и
# заведено. Счётчик ниже краснит сборку, если стендов отработало не столько,
# сколько объявлено имён: стенд, добавленный без имени, и имя, добавленное
# без стенда, -- одинаково расхождение.
KIT_BENCH_NAMES=("Стенд инструментов судьи" "Стенд моделей и цен" "Стенд синхронизации проб")
__kit_bench_ran=0
if [[ "${CLAUDE_PATCH_SKIP_KIT_BENCH:-0}" == "1" ]]; then
  # CONSTRAINT: склейка через printf, а не через IFS: `${arr[*]}` берёт из IFS
  # ТОЛЬКО ПЕРВЫЙ символ, и перечень напечатался бы без пробела после запятой.
  __kit_bench_list=$(printf '%s, ' "${KIT_BENCH_NAMES[@]}") || { printf 'ПРИБОР НЕДОСТУПЕН: не собран перечень стендов кита\n' >&2; exit 2; }
  __kit_bench_list=${__kit_bench_list%, }
  echo "Стенды кита: ПРОПУЩЕНЫ -- CLAUDE_PATCH_SKIP_KIT_BENCH=1. НЕ проверены: $__kit_bench_list" >&2
else
echo "==> ${KIT_BENCH_NAMES[0]}"
python3 "$(dirname "$0")/tools/judge-tools-bench.py" 9>&- || {
  __rc=$?
  case $__rc in
    2) echo "СТЕНД ИНСТРУМЕНТОВ НЕ ИЗМЕРЯЛ: контракт вызова или контроль провален (rc=2)" >&2
       exit 2 ;;
    3) echo "СТЕНД ИНСТРУМЕНТОВ НЕ ИЗМЕРЯЛ: замок дома держит другой живой" >&2
       echo "  прогон (rc=3) -- это не вердикт о продукте, повторить позже" >&2
       exit 3 ;;
    4) echo "СТЕНД ИНСТРУМЕНТОВ: сценариев не столько, сколько объявлено (rc=4)" >&2
       # Круг 28, F-6(б): класс 4 («объявленное число не сошлось») не роняется
       # в единицу -- вызывающий ветвится по КЛАССУ, а не по «ноль/не ноль».
       exit 4 ;;
    *) echo "СТЕНД ИНСТРУМЕНТОВ УПАЛ: сценарий не сошёлся (rc=$__rc)" >&2
       exit 1 ;;
  esac
}
# Зубы стенда проверяются ТУТ ЖЕ, а не по памяти автора: --self-check применяет
# к копиям дерева мутации, воспроизводящие починенные дефекты, и требует, чтобы
# каждая покраснела. Без этого прогона беззубый стенд неотличим от рабочего --
# ровно тот случай, ради которого стенд и написан (13 с на сборку).
python3 "$(dirname "$0")/tools/judge-tools-bench.py" --self-check 9>&- || {
  __rc=$?
  case $__rc in
    2) echo "СТЕНД ИНСТРУМЕНТОВ: self-check НЕ ИЗМЕРЯЛ -- контракт вызова или" >&2
       echo "  КОНТРОЛЬ ПРОВАЛЕН: пристинная копия дерева уже красная (rc=2)" >&2
       exit 2 ;;
    4) echo "СТЕНД ИНСТРУМЕНТОВ: таблица мутаций не той длины, чем объявлено" >&2
       exit 4 ;;
    *) echo "СТЕНД ИНСТРУМЕНТОВ БЕЗ ЗУБОВ: мутация не покраснела своей причиной" >&2
       exit 1 ;;
  esac
}

# --- волна 26: два стенда, не имевшие вызывающего --------------------------------
# tools/costs-bench.py (модели/цены/окна и две функции конвейера) и
# tools/probes-sync-bench.sh (замок писателей синхронизации проб) жили без
# единого вызова: их зелёный прогон никто не читал. Оба чисто питон/баш, без
# сборок и tweakcc, поэтому идут в конвейер, а не в свип (причина невключения
# corpus-tools-bench -- глобальный страж tweakcc-состояния -- к ним не
# относится). Образец -- стенд инструментов судьи выше: прогон и --self-check,
# «мутация не покраснела» = провал сборки; классы кода -- из общей таблицы
# кита, отказ называет стенд и класс.
__kit_bench_ran=$(( __kit_bench_ran + 1 ))
echo "==> ${KIT_BENCH_NAMES[1]}"
python3 "$(dirname "$0")/tools/costs-bench.py" 9>&- || {
  __rc=$?
  case $__rc in
    2) echo "СТЕНД ЦЕН НЕ ИЗМЕРЯЛ: контракт вызова или контроль провален (rc=2)" >&2
       exit 2 ;;
    4) echo "СТЕНД ЦЕН: объявленные числа таблиц не сходятся (rc=4)" >&2
       # Круг 28, F-6(б): класс 4 сохраняется, текст не меняется.
       exit 4 ;;
    *) echo "СТЕНД ЦЕН УПАЛ: сценарий не сошёлся (rc=$__rc)" >&2
       exit 1 ;;
  esac
}
python3 "$(dirname "$0")/tools/costs-bench.py" --self-check 9>&- || {
  __rc=$?
  case $__rc in
    2) echo "СТЕНД ЦЕН: self-check НЕ ИЗМЕРЯЛ -- пристинная копия уже красная (rc=2)" >&2
       exit 2 ;;
    4) echo "СТЕНД ЦЕН: таблица мутаций не той длины, чем объявлено" >&2
       exit 4 ;;
    *) echo "СТЕНД ЦЕН БЕЗ ЗУБОВ: мутация не покраснела своей причиной" >&2
       exit 1 ;;
  esac
}
__kit_bench_ran=$(( __kit_bench_ran + 1 ))
echo "==> ${KIT_BENCH_NAMES[2]}"
bash "$(dirname "$0")/tools/probes-sync-bench.sh" 9>&- || {
  __rc=$?
  case $__rc in
    2) echo "СТЕНД ПРОБ НЕ ИЗМЕРЯЛ: контракт вызова или условие ожидания (rc=2)" >&2
       exit 2 ;;
    4) echo "СТЕНД ПРОБ: объявленные числа таблиц не сходятся (rc=4)" >&2
       # Круг 28, F-6(б): класс 4 сохраняется, текст не меняется.
       exit 4 ;;
    *) echo "СТЕНД ПРОБ УПАЛ: сценарий не сошёлся (rc=$__rc)" >&2
       exit 1 ;;
  esac
}
bash "$(dirname "$0")/tools/probes-sync-bench.sh" --self-check 9>&- || {
  __rc=$?
  case $__rc in
    2) echo "СТЕНД ПРОБ: self-check НЕ ИЗМЕРЯЛ -- якорь или условие ожидания (rc=2)" >&2
       exit 2 ;;
    4) echo "СТЕНД ПРОБ: таблица мутаций не той длины, чем объявлено" >&2
       exit 4 ;;
    *) echo "СТЕНД ПРОБ БЕЗ ЗУБОВ: мутация не покраснела своей причиной" >&2
       exit 1 ;;
  esac
}
__kit_bench_ran=$(( __kit_bench_ran + 1 ))
if [[ $__kit_bench_ran -ne ${#KIT_BENCH_NAMES[@]} ]]; then
  echo "СТЕНДЫ КИТА: объявлено имён ${#KIT_BENCH_NAMES[@]}, отработало $__kit_bench_ran -- перечень разошёлся с блоком" >&2
  exit 4
fi
fi

# --- раскатка судейских инструментов: исполняются ТЕ ЖЕ байты, что заверены ----
# Стенд выше сертифицирует КАНОН: tools/judge-tools-bench.py читает judge/*.py
# ЭТОГО дерева. А launchd гоняет РАСКАТАННУЮ копию из ~/.claude/judge, и ядро
# читает раскатанные настройки и промты. Пока у сверки не было ни одного
# автоматического вызывающего (рецепт в хвосте конвейера человек читает раз в
# жизни), дом отстал от канона на семь волн и продолжал исполняться -- заметил
# только аудит (круг 20, D-1). Тест-ручки домов снимаются: гейт меряет
# НАСТОЯЩИЙ дом, а не тот, что назвало окружение оператора.
echo "==> Раскатка инструментов судьи"
if env -u CLAUDE_JUDGE_TOOLS_DIR -u CLAUDE_LAUNCH_AGENTS_DIR \
     bash "$(dirname "$0")/scripts/probes-sync.sh" --diff 9>&-; then
  # #63: сверка --diff на УСПЕХЕ молчит (probes-sync.sh выходит 0 без echo).
  # Стадия обязана позитивно подтвердить исход в логе, иначе свип-присутствие
  # не отличит успех от молчаливого пропуска. log_re стадии требует эту строку.
  echo "Раскатка инструментов судьи: расхождений нет — раскатка полная"
else
  __rc=$?
  case $__rc in
    5) echo "РАСКАТКИ НЕТ: на этой машине не заведено ни одного файла — пропуск (rc=5)" ;;
    2) echo "СВЕРКА РАСКАТКИ НЕ ИЗМЕРЯЛА: контракт вызова (rc=2)" >&2
       exit 2 ;;
    # Смерть по сигналу -- НЕ вердикт кита: сверка отвечает 128+N (см. шапку
    # probes-sync.sh), и прежняя общая ветка объявляла прерванный прогон
    # расхождением с каноном. Диагноз, которого не было, хуже отсутствия
    # диагноза: читатель шёл чинить дом, который никто не мерил.
    130|143) echo "СВЕРКА РАСКАТКИ ПРЕРВАНА СИГНАЛОМ (rc=$__rc): не мерили, вердикта нет" >&2
       exit "$__rc" ;;
    # КОНСТРЕЙНТ НАПРАВЛЕНИЯ: расхождение НЕ называет, чья сторона верна --
    # его чинят обе команды, и каждая уничтожает работу на своей стороне.
    # Прежняя редакция советовала одну, `--to-home`, и на машине, где правка
    # сделана В ДОМЕ (штатный случай: промт судьи правят на живой машине),
    # совет гейта стирал её. Полный дом правила -- отказ самой сверки.
    1) echo "РАСКАТКА РАСХОДИТСЯ С КАНОНОМ: launchd и ядро исполняют не те" >&2
       echo "  байты, что заверил стенд. Направление НЕ следует из расхождения:" >&2
       echo "    bash $(dirname "$0")/scripts/probes-sync.sh --to-home    канон -> дом  (потеряет правки В ДОМЕ)" >&2
       echo "    bash $(dirname "$0")/scripts/probes-sync.sh --from-home  дом -> канон  (потеряет правки В КАНОНЕ)" >&2
       echo "  Что именно разошлось -- в строках «расходится:» выше." >&2
       exit 1 ;;
    *) echo "СВЕРКА РАСКАТКИ ОТВЕТИЛА НЕОЖИДАННЫМ КОДОМ (rc=$__rc): вердикта нет" >&2
       exit 1 ;;
  esac
fi

# --- 0d. the numbers stated in the docs must be the numbers that are declared --
# A count written in prose has no reader, so it goes stale by default. This is
# its reader. Twice already a wave raised EXPECTED_CHECKS and left every
# sentence about it behind; the second time the correction itself went stale
# within one wave.
#
# A count also has an OWNER. Several benches now declare counts of their own,
# so a number is compared with the constant of the bench named NEAREST to it,
# and the grammar that finds those numbers is itself run against synthetic
# cases with known answers before it is let near a real file.
echo "==> Сверка чисел в доках"
python3 - "$0" <<'PYDOCS'
# docnum:synthetic-block -- этот блок ЕСТЬ сам гейт, и его положительные
# контроли врут числами по замыслу («12 scenarios» при объявленных 115).
# Объявление лежит внутри блока, а не в списке имён снаружи: список отстал бы
# от переименования тега молча, а самоисключение по имени файла выключило бы
# охват всего конвейера разом.
import ast, contextlib, importlib.util, io, os, re, sys, glob

here = os.path.dirname(os.path.abspath(sys.argv[1]))
read = lambda p: io.open(p, encoding='utf-8').read()

# Правило «строка открывает питоновский heredoc» живёт в ЕДИНСТВЕННОМ доме --
# tools/heredoc-anchor.py; местная редакция стадии удалена (волна 230):
# открытие, обязанное кончать строку, пропускало живые формы с хвостом, а
# python3 в ЛЮБОМ месте строки принимал стабы и упоминания. Форма загрузки --
# как у стадии PYCOMPILE выше; отказ загрузки ИЛИ зубов прибора -- отказ
# сверки (код 2), а не откат к местной редакции и не «тел нет».
_anchor_spec = importlib.util.spec_from_file_location(
    'heredoc_anchor', os.path.join(here, 'tools/heredoc-anchor.py'))
if _anchor_spec is None or _anchor_spec.loader is None:
    print("ЯКОРЬ HEREDOC'ОВ НЕ ЗАГРУЖАЕТСЯ: нет tools/heredoc-anchor.py")
    sys.exit(2)
_anchor = importlib.util.module_from_spec(_anchor_spec)
try:
    _anchor_spec.loader.exec_module(_anchor)
except Exception as _e:    # отказ загрузки -- не откат к своей копии правила
    print(f"ЯКОРЬ HEREDOC'ОВ НЕ ЗАГРУЖАЕТСЯ: {_e}")
    sys.exit(2)
# Зубы -- ДО разметки: импортируемый-но-негодный прибор (ослеплённый
# opener_match) оставлял сверку зелёной, и слепота выглядела как «проверено»
# (волна 230). Отпечаток успеха прибора ПОГЛОЩАЕТСЯ, а не печатается: лишняя
# строка в выводе стадии -- шум перед сличением выводов.
_anchor_teeth_out = io.StringIO()
try:
    with contextlib.redirect_stdout(_anchor_teeth_out):
        _anchor_teeth_rc = _anchor.self_check()
except SystemExit as _e:
    _anchor_teeth_rc = _e.code if isinstance(_e.code, int) else 1
except Exception as _e:
    _anchor_teeth_rc = 1
    _anchor_teeth_out.write(f'{type(_e).__name__}: {_e}')
if _anchor_teeth_rc != 0:
    print(f"ЯКОРЬ HEREDOC'ОВ НЕ ДЕРЖИТ ФОРМУ: "
          f"{_anchor_teeth_out.getvalue().strip()}")
    sys.exit(2)
opener_match = _anchor.opener_match

# --- кто объявляет число ------------------------------------------------------
# Число в прозе принадлежит ОДНОМУ объявляющему месту. Пока счётчик сценариев
# был один, владельца можно было держать неявным. С несколькими стендами, у
# каждого свои константы, неявный владелец заставляет гейт сверять утверждение
# про один стенд с константой другого.
OWNERS = (
    # id, имена в прозе, файл (None = сам конвейер), {величина: регексп объявления}
    # У конвейера имён не было вовсе, а величина 'checks' -- единственного
    # владельца, и владелец возвращался без поиска имени: ЛЮБОЕ «N проверок» в
    # любом предложении сверялось с константой конвейера («судья делает 2
    # проверки перед вердиктом» -- красное, docnum:example). Имя теперь
    # называется, как у стендов, и правило одно для всех величин.
    ('pipeline', ('pipeline', 'конвейер', 'конвейера', 'конвейере',
                  'конвейером', 'claude-patch-all'), None,
     {'checks': r'^EXPECTED_CHECKS = (\d+)$'}),
    ('probe-bench', ('probe-bench',), ('tools', 'probe-bench.js'),
     {'scenarios': r'^const EXPECTED_SCENARIOS = (\d+);$',
      'mutations': r'^const EXPECTED_MUTATIONS = (\d+);$'}),
    ('judge-tools-bench', ('judge-tools-bench',), ('tools', 'judge-tools-bench.py'),
     {'scenarios': r'^EXPECTED_SCENARIOS = (\d+)$',
      'mutations': r'^EXPECTED_MUTATIONS = (\d+)$'}),
    ('corpus-tools-bench', ('corpus-tools-bench',), ('tools', 'corpus-tools-bench.sh'),
     {'scenarios': r'^EXPECTED_SCENARIOS=(\d+)$',
      'mutations': r'^EXPECTED_MUTATIONS=(\d+)$'}),
    ('build-path-probe', ('build-path-probe',), ('tools', 'build-path-probe.sh'),
     {'scenarios': r'^EXPECTED_SCENARIOS=(\d+)$',
      'mutations': r'^EXPECTED_MUTATIONS=(\d+)$'}),
    ('backup-divergence-probe', ('backup-divergence-probe',),
     ('tools', 'backup-divergence-probe.sh'),
     {'scenarios': r'^EXPECTED_SCENARIOS=(\d+)$',
      'mutations': r'^EXPECTED_MUTATIONS=(\d+)$'}),
    ('probes-sync-bench', ('probes-sync-bench',), ('tools', 'probes-sync-bench.sh'),
     {'scenarios': r'^EXPECTED_SCENARIOS=(\d+)$',
      'mutations': r'^EXPECTED_MUTATIONS=(\d+)$'}),
    ('costs-bench', ('costs-bench',), ('tools', 'costs-bench.py'),
     {'scenarios': r'^EXPECTED_SCENARIOS = (\d+)$',
      'mutations': r'^EXPECTED_MUTATIONS = (\d+)$'}),
    ('docnum-bench', ('docnum-bench',), ('tools', 'docnum-bench.py'),
     {'mutations': r'^EXPECTED_MUTATIONS = (\d+)$'}),
    ('checks-teeth', ('checks-teeth',), ('tools', 'checks-teeth.py'),
     {'mutations': r'^EXPECTED_MUTATIONS = (\d+)$'}),
    # Имена различает ТОКЕНИЗАТОР, а не подстрока: TOKEN держит дефис внутри
    # слова, поэтому «checks-teeth-corpus» -- отдельное имя, а не вхождение
    # «checks-teeth». Иначе счёт зубов корпусного прибора сверялся бы с
    # константой соседа.
    ('checks-teeth-corpus', ('checks-teeth-corpus',),
     ('tools', 'checks-teeth-corpus.py'),
     {'mutations': r'^EXPECTED_MUTATIONS = (\d+)$'}),
)
# Существительное -> величина. Единственного числа нет намеренно: «1 check» как
# утверждение не пишут, а слово в единственном числе стоит в прозе на каждом шагу.
NOUNS = {}
for _forms, _q in (
        (('checks', 'проверок', 'проверки', 'проверкам', 'проверками',
          'проверках'), 'checks'),
        (('scenarios', 'сценариев', 'сценария', 'сценарии', 'сценариям',
          'сценариями', 'сценариях'), 'scenarios'),
        (('mutations', 'мутаций', 'мутации', 'мутациям', 'мутациями',
          'мутациях'), 'mutations')):
    for _f in _forms:
        NOUNS[_f] = _q

# Форма «все N» с опущенным существительным (круг 28, F-12). Живой случай
# (docnum:example): «Реестр выше говорит, что все 114 сошлись» при
# ТОГДАШНЕМ EXPECTED_CHECKS = 118 (docnum:historical) в девяти строках выше -- счёт назван числом,
# существительное элидировано,
# и пара «число + существительное» не возникала вовсе: гейт был слеп к
# протухшему числу ПО УСТРОЙСТВУ. Такая форма -- тоже счёт: она обязана
# нести владельца (имя, как обычная форма) или явную пометку docnum:*, а
# число -- сходиться хотя бы с ОДНОЙ из объявленных владельцем величин
# (какая именно величина -- элидировано, и требовать её нельзя).
ELIDE_ALL = ('все', 'всех')

# Насколько далеко от числа ищется имя владельца.
WINDOW = 400
# Сколько токенов между числом и существительным считается одной связкой.
# Пять пропускало «13 deliberately isolated and fully executable regression
# scenarios» (docnum:example) и пару, разорванную html-комментарием: живая
# проза длиннее синтетики, на которой число подбиралось.
REACH = 8
# Связки обратной формы: «сценариев — 12» docnum:example, «мутаций всего 9»
# docnum:example.
# Без связки
# «scenarios of the 3 modes» женило бы существительное на постороннем числе.
LINKS = ('—', '-', ':', '=', '(', 'total', 'всего', 'итого', 'итог',
         'стало', 'теперь', 'составляет', 'равно')
# Общие слова, которыми называют стенд НЕ по имени. Если такое слово ближе к
# числу, чем настоящее имя, владелец не назван (docnum:example): «unlike
# corpus-tools-bench, the probe suite covers 12 scenarios» сверялось бы с чужой
# константой и зеленело.
BENCH_WORDS = ('bench', 'benches', 'suite', 'suites', 'стенд', 'стенда',
               'стенде', 'стенды', 'стендов', 'стендах')
# Пометок три: историческое число, счёт подмножества и ОБРАЗЕЦ формы -- этот
# файл сам сканируется, и пара «число + существительное» в комментарии про
# грамматику остаётся живым утверждением, пока не помечена.
# Пометка -- ЯВНЫЙ токен, а не слово естественного языка. Слова «subset» и
# «historical» в соседнем предложении освобождали утверждение, которое к ним
# отношения не имеет, а фраза «это НЕ подмножество» работала как разрешение.
# docnum:delta -- утверждение о ПРИРАЩЕНИИ («волна добавила 4 проверки»): оно
# верно и не равно общему счёту, а historical/subset тут лгали бы.
# docnum:other -- число вообще не про счётчики кита («судья делает 2 проверки»).
MARKERS = ('docnum:historical', 'docnum:subset', 'docnum:example',
           'docnum:delta', 'docnum:other')
MARK_RE = re.compile('|'.join(re.escape(m) for m in MARKERS))
# Журнал кампании записывает прошлые сборки по датам: строка «N checks green»
# под заголовком «Porting to 2.1.237» верна для ТОЙ сборки и не переписывается.
# То же и у дома отчётов аудита: в docs/review/ лежат журнал кампании и отчёты
# аудиторов по раундам, и каждое число в них принадлежит СВОЕЙ дате -- счёт
# волны 21 не обязан сходиться со счётом волны 24. Дом объявлен КАТАЛОГОМ, а не
# перечнем имён: отчётов по раунду бывает несколько, и забытое имя молча
# вернуло бы лавину чужих чисел в вердикт гейта.
#
# Исключение объявляется в потоке (см. ниже) вместе с числом исключённых
# файлов: дыра, о которой не сказано, растёт молча. И объявленный дом обязан
# СУЩЕСТВОВАТЬ -- иначе переименование каталога оставило бы исключение,
# не закрывающее ничего, и это выглядело бы как охват.
JOURNALS = ('judge-patch-spec.md',)
JOURNAL_DIRS = (os.path.join('docs', 'review'),)

# Маскируется до разбора: дата иначе предложит своё число, а версия -- своё.
# Маркер сноски «[^1]» тоже число, и гейт брал ЕГО значением при верном счёте
# рядом; html-комментарий -- не проза, а его токены съедали связку целиком.
MASK = re.compile(r'\d{4}-\d{2}-\d{2}|\d+(?:\.\d+)+|\[\^\d+\]'
                  r'|<!--.*?-->', re.S)
FENCE = re.compile(r'^```.*?^```', re.M | re.S)
# Строка-забор: сам забор -- не проза, но и склейкой соседей быть не должен.
FENCE_LINE = re.compile(r'^```.*$', re.M)
# Строка таблицы и её разделитель («|---|:--:|»).
TABLE_ROW = re.compile(r'^\s*\|')
TABLE_SEP = re.compile(r'^\s*\|[\s:|-]+\|?\s*$')
# Знаки препинания между числом и существительным разбор ПРОПУСКАЕТ, а не
# вычищает заранее: `| 13 | scenarios |` docnum:example, а также `**13**`,
# `(13)` и `` `scenarios` `` docnum:example -- это те же утверждения, и восемь из девяти обычных форм
# прозы гейт пропускал, пока разбирал поток регекспом. Отдельная чистка
# разметки тут была и снята: ни один случай самопроверки её снятия не
# заметил, а механизм, чьё снятие никто не видит, только выглядит рабочим.
TOKEN = re.compile(r"[^\W\d_][\w:-]*|\d+|[^\s\w]")
STOP = ('.', ';', '!', '?')
# Граница блока: пустая строка, элемент списка, строка таблицы, заголовок.
# Поток склеивает строки намеренно (счёт умеет переезжать через перевод
# строки), но из-за этого число ОДНОГО пункта списка женилось с
# существительным СЛЕДУЮЩЕГО, а число одной строки таблицы -- со словом из
# другой строки. Разделитель ставится только там, где разметка сама объявляет
# новый блок, поэтому перенос внутри абзаца по-прежнему не мешает.
BREAK = '\u00b6'
BLOCK_MD = re.compile(r'^\s*(?:[-*+\u2022]\s|\|\s?|\d+[.)]\s|#{1,6}\s)')
BLOCK_CODE = re.compile(r'^\s*(?:[-*+\u2022]\s|\|\s?|\d+[.)]\s)')
# Запятая и двоеточие рвут пару «число одного предмета + существительное
# другого»: «в PR 34, сценарии corpus-tools-bench снова зелёные» и «строка 34:
# сценарии перечислены ниже» краснели как расхождение счёта.
LEFT_STOP = (',', ':', BREAK)
# Для обратной формы двоеточие -- законная связка, поэтому список свой.
RIGHT_STOP = (',', BREAK)
# Сокращения: точка в них -- НЕ конец предложения. «34 шт. сценариев»
# (docnum:example) рвалось на «шт.», и пара переставала существовать.
ABBR = ('шт', 'т', 'тт', 'др', 'пр', 'см', 'напр', 'рис', 'стр', 'гл', 'ср',
        'мин', 'сек', 'ч', 'г', 'гг', 'руб', 'e.g', 'i.e', 'etc', 'vs', 'cf',
        'fig', 'vol', 'no', 'p', 'pp')
# Границы диапазона: «от 10 до 40 сценариев» -- не счёт, а обобщение, и
# сверять его с константой одного стенда нечестно в обе стороны.
RANGE = ('от', 'до', 'from', 'to', 'between', 'around', 'about',
         'примерно', 'около', 'свыше', 'более', 'менее')
# Счёт словом гейт не сверяет и не пропускает: он ТРЕБУЕТ цифру.
#
# Список закрытый, и его неполнота была дырой: «ninety»/«девяносто» в нём не
# значились, поэтому ветка не срабатывала ВООБЩЕ и число не искалось -- счёт,
# записанный такими словами, проходил молча. Теперь перечислены все единицы,
# все десятки и «сто/hundred» в обеих речах; составные формы («сто
# четырнадцать», «one hundred fourteen») ловятся тем же списком, потому что
# проверяется слово, стоящее ВПЛОТНУЮ к существительному, а последним словом
# составного числительного всегда бывает единица, десяток или сотня.
#
# «один/одна/one» НЕ включены сознательно: это обычные слова прозы («one of the
# benches», «the one thing»), и их присутствие давало бы отказ сборки на ровном
# месте. Предел объявлен здесь.
WORDNUM = ('два', 'две', 'три', 'четыре', 'пять', 'шесть', 'семь', 'восемь',
           'девять', 'десять', 'одиннадцать', 'двенадцать', 'тринадцать',
           'четырнадцать', 'пятнадцать', 'шестнадцать', 'семнадцать',
           'восемнадцать', 'девятнадцать', 'двадцать', 'тридцать', 'сорок',
           'пятьдесят', 'шестьдесят', 'семьдесят', 'восемьдесят', 'девяносто',
           'сто', 'двухсот', 'трёхсот', 'трехсот', 'сотен', 'сотни',
           'двух', 'трёх', 'трех', 'четырёх', 'четырех',
           'пяти', 'шести', 'семи', 'восьми', 'девяти', 'десяти',
           'одиннадцати', 'двенадцати', 'тринадцати', 'четырнадцати',
           'пятнадцати', 'шестнадцати', 'семнадцати', 'восемнадцати',
           'девятнадцати', 'двадцати', 'тридцати', 'сорока', 'пятидесяти',
           'шестидесяти', 'семидесяти', 'восьмидесяти', 'девяноста', 'ста',
           'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine',
           'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen',
           'sixteen', 'seventeen', 'eighteen', 'nineteen', 'twenty',
           'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety',
           'hundred')


# Блок, ОБЪЯВИВШИЙ себя синтетикой, не читается: его числа врут по замыслу
# (положительные контроли грамматики этого же гейта). Объявление ЯВНОЕ и
# лежит в самом блоке -- исключение по имени тега сломалось бы от
# переименования, а исключение "своего файла" выключило бы весь конвейер.
SYNTHETIC_BLOCK = 'docnum:synthetic-block'


def heredoc_map(text):
    """Строки питоновских heredoc'ов файла оболочки.

    Возвращает три множества номеров строк: тело питоновского блока,
    его докстринги, и тело блока, объявившего себя синтетикой.

    Питоновость определяется по КОМАНДЕ, открывающей heredoc, а не по
    содержимому: `python3 - <<'PY'` -- питон, `cat > f <<'STUB'` -- данные,
    и данные читать как прозу нельзя (внутри них лежат куски чужих файлов).
    Решение открытия -- ЕДИНСТВЕННЫЙ дом tools/heredoc-anchor.py
    (opener_match, загружен в голове стадии): местная редакция (открытие
    обязано кончать строку + python3 где угодно в строке) пропускала живые
    формы с хвостом и принимала стабы (волна 230). Прогулка и разбор тел --
    собственные: тег закрывается строкой без табуляций (`<<-`), докстринги
    собираются разбором тела.
    """
    body, docs, synthetic = set(), set(), set()
    lines = text.split('\n')
    i = 0
    while i < len(lines):
        line = lines[i]
        match = opener_match(line)
        if match is None:
            i += 1
            continue
        tag = match.group(1)
        start = i + 1
        j = start
        while j < len(lines) and lines[j].strip('\t') != tag:
            j += 1
        chunk = lines[start:j]
        numbers = range(start + 1, j + 1)   # номера строк 1-based
        # Объявление -- КОММЕНТАРИЙ В ГОЛОВЕ блока, а не любое вхождение
        # строки: константа с тем же текстом лежит в этом же блоке (гейт
        # объявляет своё правило внутри себя), и признание «по вхождению»
        # было бы неснимаемым -- мутация, убирающая объявление, ничего бы не
        # меняла, то есть исключение нельзя было бы проверить на зубы.
        if any(c.strip().startswith('# ' + SYNTHETIC_BLOCK) for c in chunk[:10]):
            synthetic.update(numbers)
        else:
            body.update(numbers)
            try:
                tree = ast.parse('\n'.join(chunk))
            except SyntaxError:
                tree = None
            for node in ast.walk(tree) if tree else ():
                inner = getattr(node, 'body', None)
                if not isinstance(inner, list) or not inner:
                    continue
                head = inner[0]
                if (isinstance(head, ast.Expr) and isinstance(head.value, ast.Constant)
                        and isinstance(head.value.value, str)):
                    for n in range(head.lineno, (head.end_lineno or head.lineno) + 1):
                        docs.add(start + n)      # смещение блока в файле
        i = j + 1
    return body, docs, synthetic


def prose(path, text):
    """Проза файла: в коде число -- это значение, а не утверждение о счёте.

    Прежняя версия читала код наравне с прозой и потому боролась с ложными
    срабатываниями сужением грамматики -- а сужение убивало настоящие формы
    прозы. Разделение снимает обе беды разом: в .md читается всё (кроме
    огороженных блоков кода), в коде -- только комментарии. Номера строк
    сохраняются: непрозаические строки заменяются пустыми, а не выбрасываются.
    """
    ext = os.path.splitext(path)[1]
    if ext in ('.md', '.txt', ''):
        # Огороженный блок РАЗБИРАЕТСЯ, а не вычёркивается.
        #
        # Он вычёркивался целиком, и в нём молча жил целый класс счётов: в этот
        # кит вывод стендов вставляют именно так («probe-bench: ИТОГ
        # сценариев=56» docnum:example), и утверждение устаревает как любое
        # другое. Снимаются только строки-заборы -- вместо них BREAK, чтобы
        # текст до забора не женился с текстом после.
        return blocks(FENCE_LINE.sub(BREAK, text), BLOCK_MD)
    if ext == '.py':
        # Докстринг -- главный носитель прозы в питоне, а гейт читал в .py
        # только строки с '#': счёт, записанный в докстринге, был для него
        # значением, а не утверждением.
        #
        # Ищется он РАЗБОРОМ, а не по тройной кавычке в строке: первая
        # редакция принимала за докстринг любую строку, где такая кавычка
        # встретилась, и литерал внутри чужой строки становился «прозой».
        keep_lines = set()
        try:
            tree = ast.parse(text)
        except SyntaxError:
            tree = None
        for node in ast.walk(tree) if tree else ():
            body = getattr(node, 'body', None)
            if not isinstance(body, list) or not body:
                continue
            head = body[0]
            if (isinstance(head, ast.Expr) and isinstance(head.value, ast.Constant)
                    and isinstance(head.value.value, str)):
                for n in range(head.lineno, (head.end_lineno or head.lineno) + 1):
                    keep_lines.add(n)
        out = []
        for number, line in enumerate(text.split('\n'), 1):
            out.append(line if number in keep_lines
                       or line.lstrip().startswith('#') else '')
        return blocks('\n'.join(out), BLOCK_CODE)
    heredoc_py_lines, heredoc_doc_lines, synthetic_lines = (
        heredoc_map(text) if ext == '.sh' else (set(), set(), set()))
    out, block = [], False
    for number, line in enumerate(text.split('\n'), 1):
        stripped = line.lstrip()
        keep = ''
        if ext == '.js':
            if block:
                keep = line
                if '*/' in line:
                    block = False
            elif stripped.startswith('/*'):
                keep = line
                block = '*/' not in line
            elif stripped.startswith('//'):
                keep = line
        elif ext == '.sh':
            # Текст, который шелл ПЕЧАТАЕТ человеку, -- проза: счёт в нём
            # читают глазами так же, как в доке. Берётся только СОДЕРЖИМОЕ
            # кавычек: перенаправление «>&2» дало бы разбору цифру 2, которой
            # человек в сообщении не видит.
            #
            # ПИТОНОВСКИЕ HEREDOC'И этого файла тоже проза -- в той же мере, в
            # какой ею является отдельный .py: докстринг и комментарий внутри
            # блока человек читает глазами, и счёт в них устаревает так же.
            # До этого правила блок был для гейта одной сплошной строкой
            # данных: комментарии внутри него проходили как комментарии
            # оболочки, а докстринги не читались вовсе. Разметка блоков
            # делается ДО этого цикла (heredoc_lines), потому что решение о
            # строке зависит от того, внутри какого блока она стоит.
            if number in synthetic_lines:
                keep = ''
            elif number in heredoc_py_lines:
                keep = line if (number in heredoc_doc_lines
                                or stripped.startswith('#')) else ''
            elif stripped.startswith('#'):
                keep = line
            elif re.match(r'(echo|say|printf)\b', stripped):
                keep = ' '.join(a or b for a, b in
                                re.findall(r'"([^"]*)"|\'([^\']*)\'', line))
        elif stripped.startswith('#'):
            keep = line
        out.append(keep)
    return blocks('\n'.join(out), BLOCK_CODE)


def blocks(text, marker):
    """Разделитель на границах блоков разметки (см. BREAK).

    Плюс одно преобразование: ячейка таблицы получает существительное СВОЕЙ
    КОЛОНКИ. Счёт в таблице записывают шапкой («| стенд | сценариев |») и
    цифрой в ячейке, а шапку от строки отделяет BREAK -- пара «число +
    существительное» не возникала вовсе, и такой счёт не проверял никто.
    Приписка идёт в ту же строку, поэтому имя владельца из соседней ячейки
    остаётся в том же блоке, а нумерация строк не сдвигается.
    """
    out = []
    lines = text.split('\n')
    header = None
    for i, line in enumerate(lines):
        if (TABLE_SEP.match(line) and i
                and TABLE_ROW.match(lines[i - 1]) and not TABLE_SEP.match(lines[i - 1])):
            header = [c.strip() for c in lines[i - 1].strip().strip('|').split('|')]
        if not line.strip():
            header = None
            out.append(BREAK)
            continue
        if not TABLE_ROW.match(line):
            header = None
        if header and TABLE_ROW.match(line) and not TABLE_SEP.match(line):
            cells = [c.strip() for c in line.strip().strip('|').split('|')]
            # Существительное шапки приписывается ТОЛЬКО к ячейке с цифрой.
            # Иначе шапка колонки с именем («| стенд |») ложилась вплотную к
            # счёту как ОБЩЕЕ СЛОВО и гейт требовал назвать владельца, который
            # стоит в той же строке.
            merged = ' '.join(
                (c + ' ' + header[j])
                if (j < len(header) and header[j] and any(ch.isdigit() for ch in c))
                else c
                for j, c in enumerate(cells))
            out.append(BREAK + ' ' + merged)
        elif marker.match(line):
            out.append(BREAK + ' ' + line)
        else:
            out.append(line)
    return '\n'.join(out)


def collapse(text):
    """Поток без повторных пробелов плюс номер строки для каждого символа.

    Построчно гейт не видел счёт, у которого существительное кончало одну
    строку, а число открывало следующую. Потоком видит -- но находка без номера
    строки та, по которой никто не пойдёт, поэтому отображение едет рядом.
    """
    out, lines, ln, prev_space = [], [], 1, True
    for ch in text:
        if ch.isspace():
            if not prev_space:
                out.append(' ')
                lines.append(ln)
                prev_space = True
        else:
            out.append(ch)
            lines.append(ln)
            prev_space = False
        if ch == '\n':
            ln += 1
    return ''.join(out), lines


def scan(text, table, aliases, path='<текст>'):
    """Все расхождения «число + существительное» в одном тексте.

    Разбор идёт ОТ СУЩЕСТВИТЕЛЬНОГО: именно оно называет величину. Число --
    ближайшее слева в пределах связки, не пересекая границу предложения; этим
    одним правилом закрываются и дробь «12/12», и честная форма «7 из 12
    сценариев» (сверяется общее число, а не подсчёт подмножества).
    """
    stream, lines = collapse(prose(path, text))
    stream = MASK.sub(lambda m: 'x' * len(m.group(0)), stream)
    toks = [(m.group(0), m.start()) for m in TOKEN.finditer(stream)]
    low = stream.casefold()

    def real_stop(pos):
        """Точка после сокращения -- не конец предложения."""
        if stream[pos] != '.':
            return True
        j = pos
        while j > 0 and (stream[j - 1].isalnum() or stream[j - 1] == '.'):
            j -= 1
        word = stream[j:pos].casefold().strip('.')
        return not (word in ABBR or len(word) == 1)

    # Границы считаются ОДИН раз на текст: разбор идёт от каждого
    # существительного, и пересчёт на каждом делал бы гейт квадратичным.
    stops = [m.start() for m in re.finditer(r'[.;!?]\s', stream)
             if real_stop(m.start())]
    stops += [m.start() for m in re.finditer(re.escape(BREAK), stream)]
    stops.sort()

    def sentence_span(at):
        lo, hi = 0, len(stream)
        for pos in stops:
            if pos < at:
                lo = pos + (1 if stream[pos] == BREAK else 2)
            elif pos >= at:
                hi = pos
                break
        return lo, hi

    def exempt(at):
        """Пометка освобождает РОВНО ОДИН счёт -- ближайший к ней.

        Прежде она освобождала всё предложение: «the pipeline runs 999 checks
        and probe-bench 999 scenarios docnum:historical» проходило целиком, хотя
        помечено было одно утверждение из двух. Пометок в предложении может быть
        столько же, сколько счётов; каждая берёт себе ближайший.
        """
        lo, hi = sentence_span(at)
        here = [a for a in anchors if lo <= a < hi]
        if not here:
            return False
        for m in MARK_RE.finditer(low[lo:hi]):
            mp = lo + m.start()
            if min(here, key=lambda a: (abs(a - mp), a)) == at:
                return True
        return False

    def resolve(lo, hi, by, at, strict):
        """Владелец счёта в куске потока [lo, hi): (id, причина отказа).

        (None, None) -- в этом куске владельца не называли ни именем, ни общим
        словом; решает следующий круг.
        """
        window = low[lo:hi]
        masked = list(window)
        found = {}
        for alias, oid in aliases:
            if oid not in by:
                continue
            start = 0
            while True:
                k = window.find(alias.casefold(), start)
                if k < 0:
                    break
                # Имя стенда само содержит слово «bench» -- заслонить, иначе
                # каждое имя выглядело бы как «названо общим словом».
                masked[k:k + len(alias)] = ' ' * len(alias)
                d = abs(lo + k - at)
                if oid not in found or d < found[oid]:
                    found[oid] = d
                start = k + 1
        common = None
        for m in TOKEN.finditer(''.join(masked)):
            if m.group(0) in BENCH_WORDS:
                d = abs(lo + m.start() - at)
                if common is None or d < common:
                    common = d
        if not found:
            if common is not None:
                return None, ('владелец назван общим словом, а не именем стенда — '
                              'припишите имя (' + ' / '.join(sorted(by)) + ')')
            return None, None
        best = min(found, key=lambda oid: (found[oid], oid))
        best_d = found[best]
        # Отдельной ветки «равное расстояние до двух имён» здесь больше нет:
        # два имени отвергаются выше В ОБОИХ кругах, поэтому сюда с двумя
        # именами не приходят. Ветка, которая не может сработать, выглядит
        # ровно как работающая -- держать её значит хранить ложное покрытие.
        if len(found) > 1:
            # Предмет речи называет ТЕКСТ, а не расстояние. Правило «побеждает
            # ближайшее имя» принимало ложь молча, когда константа соседа
            # случайно совпадала: «docnum-bench растёт вслед за
            # corpus-tools-bench: 26 мутаций» (docnum:example) зеленело по
            # чужой константе.
            #
            # Второй круг (окно ±WINDOW) раньше эту же ложь принимал: там
            # strict был выключен, и абзац, ЯВНО объявивший владельца в первой
            # строке, проигрывал имени соседа, упомянутому мимоходом ближе к
            # числу. Отказ одинаков в обоих кругах; разное -- только слово о
            # том, где искать (предложение или соседний текст).
            where = 'в предложении' if strict else 'рядом'
            return None, (where + ' названы два стенда — назовите владельца '
                          'счёта в том же предложении (' + ' / '.join(sorted(found)) + ')')
        if common is not None and common < best_d:
            return None, ('владелец назван общим словом, а не именем стенда — '
                          'припишите имя (' + ' / '.join(sorted(by)) + ')')
        return best, None

    def owner(at, quantity):
        by = table[quantity]
        lo_s, hi_s = sentence_span(at)
        oid, why = resolve(lo_s, hi_s, by, at, True)
        if oid or why:
            return oid, why
        lo, hi = max(0, at - WINDOW), min(len(stream), at + WINDOW)
        oid, why = resolve(lo, hi, by, at, False)
        if oid or why:
            return oid, why
        return None, ('владелец счёта не назван — припишите рядом имя стенда ('
                      + ' / '.join(sorted(by)) + ')')

    # Позиции ВСЕХ сверяемых счётных существительных: по ним пометка выбирает
    # себе счёт (см. exempt). Считаются один раз на текст. Сюда же -- числа
    # элидированной формы «все N»: пометка обязана освобождать и их.
    anchors = [at for tok, at in toks
               if NOUNS.get(tok.casefold()) in table]
    anchors += [toks[i + 1][1] for i, (tok, _at) in enumerate(toks[:-1])
                if tok.casefold() in ELIDE_ALL and toks[i + 1][0].isdigit()]

    bad = []
    for i, (tok, at) in enumerate(toks):
        quantity = NOUNS.get(tok.casefold())
        if quantity is None or quantity not in table:
            continue
        lo_s, hi_s = sentence_span(at)
        value, worded, ranged = None, False, False
        # Счёт словом принимается только ВПЛОТНУЮ к существительному. На
        # расстоянии числительное чужого предмета женилось с нашим словом:
        # «a thing with two homes is the defect this kit checks for» -- «two»
        # принадлежит «homes», а не «checks».
        for j in range(i - 1, -1, -1):
            prev = toks[j][0]
            if not prev[:1].isalnum():
                continue
            worded = prev.casefold() in WORDNUM
            break
        for j in range(i - 1, max(-1, i - 1 - REACH), -1):
            prev, prev_at = toks[j]
            if prev_at < lo_s or prev in LEFT_STOP:
                break
            if prev.isdigit():
                # Число в составном слове принадлежит ему: «~300-МБ образа
                # плюс все сценарии» -- это про мегабайты, а не про сценарии.
                # Тильда говорит о прикидке, а прикидку не сверяют с константой.
                nxt_ch = stream[prev_at + len(prev):prev_at + len(prev) + 1]
                prv_ch = stream[prev_at - 1:prev_at]
                if nxt_ch == '-' or prv_ch in ('~', '±'):
                    break
                value = prev
                # «от 10 до 40 сценариев» -- обобщение, а не счёт: сверять его
                # с константой одного стенда нечестно в обе стороны.
                if j and toks[j - 1][0].casefold() in RANGE:
                    ranged = True
                break
        if value is None and not worded:
            linked = False
            for j in range(i + 1, min(len(toks), i + 1 + REACH)):
                nxt, nxt_at = toks[j]
                if nxt_at > hi_s or nxt in RIGHT_STOP:
                    break
                if nxt.isdigit():
                    if linked:
                        value = nxt
                    break
                if nxt.casefold() in LINKS:
                    linked = True
        if ranged or (value is None and not worded) or exempt(at):
            continue
        if worded:
            # Счёт словом не сверить: гейт не принимает его молча, а требует
            # цифру -- иначе устаревшее «тринадцать сценариев» (docnum:example)
            # живёт вечно.
            got = stream[max(lo_s, at - 40):min(hi_s, at + len(tok) + 10)].strip()
            bad.append((lines[at], got,
                        'счёт записан словом — напишите его цифрой'))
            continue
        oid, why = owner(at, quantity)
        got = stream[max(lo_s, at - 40):min(hi_s, at + len(tok) + 10)].strip()
        if why:
            bad.append((lines[at], got, why))
            continue
        want = table[quantity][oid]
        if value != want:
            bad.append((lines[at], got,
                        'объявлено «%s %s» (владелец %s)' % (want, tok, oid)))

    # Элидированная форма «все N» (круг 28, F-12): существительное опущено,
    # разбор от существительного её не видит. Владелец ищется среди ВСЕХ
    # объявителей (величина не названа -- фильтровать не по чему), правилами
    # того же resolve: общее слово и два имени отказывают, как и обычной
    # форме; число обязано сойтись хотя бы с одной величиной владельца.
    by_all = dict.fromkeys((oid for by in table.values() for oid in by), True)
    for i, (tok, at) in enumerate(toks):
        if tok.casefold() not in ELIDE_ALL:
            continue
        if i + 1 >= len(toks) or not toks[i + 1][0].isdigit():
            continue
        num_tok, num_at = toks[i + 1]
        # «все 119 проверок ...» (docnum:example) -- счётное существительное
        # стоит при числе,
        # счёт уже разобран обычным путём выше; повторный отчёт не нужен.
        after = toks[i + 2][0] if i + 2 < len(toks) else ''
        if NOUNS.get(after.casefold()) in table:
            continue
        if exempt(num_at):
            continue
        lo_s, hi_s = sentence_span(num_at)
        oid, why = resolve(lo_s, hi_s, by_all, num_at, True)
        if not oid and not why:
            lo, hi = max(0, num_at - WINDOW), min(len(stream), num_at + WINDOW)
            oid, why = resolve(lo, hi, by_all, num_at, False)
        got = stream[max(lo_s, num_at - 30):min(hi_s, num_at + len(num_tok) + 15)].strip()
        if why:
            bad.append((lines[num_at], got, why))
            continue
        if oid is None:
            bad.append((lines[num_at], got,
                        'счёт с опущенным существительным (все N) -- владелец '
                        'не назван (' + ' / '.join(sorted(by_all)) + ')'))
            continue
        declared = sorted({table[q][oid] for q in table if oid in table[q]})
        if num_tok not in declared:
            bad.append((lines[num_at], got,
                        '«все %s» не сходится ни с одной величиной владельца %s '
                        '(объявлено: %s)' % (num_tok, oid, ', '.join(declared))))
    return bad


# --- самопроверка грамматики --------------------------------------------------
# Гейт трижды молчал не потому, что чисел не было, а потому, что грамматика их
# не видела; каждую дыру находили руками, а восемь форм обычной прозы нашёл
# аудитор раунда 15. Это её положительный контроль: синтетические тексты с
# известным ответом, прогоняемые ДО настоящих файлов. Каждая форма из того
# отчёта записана здесь случаем.
#
# Литеральные пары «число + существительное» тут безопасны: это код, а гейт
# читает в коде только комментарии.
T = {'scenarios': {'probe-bench': '56', 'corpus-tools-bench': '12'},
     'mutations': {'judge-tools-bench': '10', 'corpus-tools-bench': '6'},
     'checks': {'pipeline': '114'}}
A = [('probe-bench', 'probe-bench'), ('judge-tools-bench', 'judge-tools-bench'),
     ('corpus-tools-bench', 'corpus-tools-bench'),
     ('pipeline', 'pipeline'), ('конвейер', 'pipeline')]
# Два имени -- отказ в ОБОИХ кругах, и расстояние до них больше ничего не
# решает. Набивка, уравнивавшая его, стояла здесь ровно против правила
# «побеждает ближнее»; правило снято, и её мутация (сдвиг набивки на символ)
# перестала краснеть -- то есть уравнивание проверять стало нечем. Строки
# лежат буквально: механизм, чьё снятие никто не замечает, только выглядит
# рабочим.
TIE = 'corpus-tools-bench 12 scenarios probe-bench'
# Та же пара имён, но ВНЕ предложения со счётом: первый круг их не видит,
# решает окно.
TIE2 = 'corpus-tools-bench. 12 scenarios. probe-bench'
CASES = (
    ('corpus-tools-bench runs 12 scenarios.', 0, '', 'простая форма, счёт верный'),
    ('corpus-tools-bench runs 13 scenarios.', 1, 'corpus-tools-bench', 'простая форма, счёт разошёлся'),
    ('| corpus-tools-bench | 13 | scenarios |', 1, 'corpus-tools-bench', 'ячейки таблицы'),
    ('corpus-tools-bench runs **13** scenarios.', 1, 'corpus-tools-bench', 'выделение'),
    ('corpus-tools-bench runs (13) scenarios.', 1, 'corpus-tools-bench', 'скобки'),
    ('corpus-tools-bench runs 13 `scenarios`.', 1, 'corpus-tools-bench', 'обратные апострофы'),
    ('corpus-tools-bench runs 13 — scenarios total.', 1, 'corpus-tools-bench', 'тире между'),
    ('corpus-tools-bench covers 13 deliberately isolated executable regression scenarios.',
     1, 'corpus-tools-bench', 'четыре слова между'),
    ('corpus-tools-bench had 13 (2026-08-28) scenarios.', 1, 'corpus-tools-bench', 'дата между'),
    ('corpus-tools-bench had 13 (v2.1.250) scenarios.', 1, 'corpus-tools-bench', 'версия между'),
    ('corpus-tools-bench scenarios total 13.', 1, 'corpus-tools-bench', 'обратная форма со связкой'),
    ('конвейер подтверждён 13 проверками.', 1, 'pipeline', 'творительный падеж'),
    ('конвейер прошёл по 116 проверкам.', 1, 'pipeline', 'дательный падеж'),
    ('judge-tools-bench готов к 27 мутациям.', 1, 'judge-tools-bench', 'дательный падеж мутаций'),
    ('в corpus-tools-bench лежит 13 шт. сценариев.', 1, 'corpus-tools-bench',
     'сокращение не рвёт предложение'),
    ('число сценариев corpus-tools-bench (13) выросло.', 1, 'corpus-tools-bench',
     'обратная форма со скобкой'),
    ('corpus-tools-bench covers 13 deliberately isolated and fully executable '
     'regression scenarios.', 1, 'corpus-tools-bench', 'шесть слов между'),
    ('corpus-tools-bench: 13 <!-- пересчитать --> сценария.', 1, 'corpus-tools-bench',
     'html-комментарий не разрывает пару'),
    ('corpus-tools-bench runs thirteen scenarios.', 1, 'словом',
     'счёт словом требует цифру'),
    ('corpus-tools-bench: 12[^1] scenarios.', 0, '', 'маркер сноски не значение'),
    ('дыра закрыта в PR 34, сценарии corpus-tools-bench снова зелёные.', 0, '',
     'запятая рвёт пару с чужим числом'),
    ('строка 34: сценарии corpus-tools-bench перечислены ниже.', 0, '',
     'двоеточие рвёт пару с чужим числом'),
    ('- сборок за ночь: 34\n- сценарии corpus-tools-bench: все зелёные', 0, '',
     'элементы списка -- разные блоки'),
    ('| probe-bench | 56 |\n| corpus-tools-bench scenarios | pass |', 0, '',
     'строки таблицы -- разные блоки'),
    ('corpus-tools-bench насчитал 13\n\nсценариев в другом абзаце', 0, '',
     'пустая строка -- граница блока'),
    ('волна добавила 4 проверки в конвейер.', 1, 'pipeline',
     'дельта без пометки не проходит'),
    ('волна добавила 4 проверки в конвейер docnum:delta', 0, '',
     'дельта помечена явно'),
    ('судья делает 2 проверки перед вердиктом.', 1, 'не назван',
     'чужой предмет без имени владельца -- отказ'),
    ('судья делает 2 проверки перед вердиктом docnum:other', 0, '',
     'число не про счётчики кита, помечено явно'),
    ('стенды гоняют от 10 до 40 сценариев каждый.', 0, '',
     'диапазон -- не счёт'),
    ('сценариев corpus-tools-bench стало 13.', 1, 'corpus-tools-bench',
     'связка «стало»'),
    ('в отличие от corpus-tools-bench, остальные стенды дают 13 сценариев.',
     1, 'общим словом', 'русское общее слово вместо имени'),
    ('a thing with two homes is the defect this kit checks for', 0, '',
     'числительное чужого предмета не женится'),
    ('~300-МБ образа плюс все сценарии corpus-tools-bench', 0, '',
     'составное число принадлежит своему слову'),
    ('56 и 12 сценариев дают probe-bench и corpus-tools-bench соответственно.',
     1, 'названы два стенда', 'перечисление в обратном порядке -- отказ'),
    ('judge-tools-bench растёт вслед за corpus-tools-bench: 6 мутаций.',
     1, 'названы два стенда', 'два владельца в предложении -- отказ, а не ближайший'),
    ('Corpus-tools-bench has 12 scenarios.', 0, '', 'имя с заглавной буквы -- то же имя'),
    ('Corpus-tools-bench has 56 scenarios.', 1, 'corpus-tools-bench', 'заглавная не отдаёт счёт чужому'),
    ('corpus-tools-bench reports 13\nscenarios.', 1, 'corpus-tools-bench', 'через перевод строки'),
    ('corpus-tools-bench 12/12 scenarios', 0, '', 'дробная форма'),
    ('corpus-tools-bench 12/13 scenarios', 1, 'corpus-tools-bench', 'дробная форма ловит расхождение'),
    ('упало 7 из 12 сценариев corpus-tools-bench', 0, '', 'честная форма «M из N»'),
    ('упало 7 из 13 сценариев corpus-tools-bench', 1, 'corpus-tools-bench', '«M из N» ловит расхождение'),
    ('corpus-tools-bench: 9 scenarios docnum:historical', 0, '', 'историческое помечено явно'),
    ('A subset is documented above. Current corpus-tools-bench has 13 scenarios.',
     1, 'corpus-tools-bench', 'слово subset в соседнем предложении не освобождает'),
    ('docnum:subset above. Current corpus-tools-bench has 13 scenarios.',
     1, 'corpus-tools-bench', 'пометка из соседнего предложения не освобождает'),
    ('corpus-tools-bench has 13 scenarios, это не подмножество',
     1, 'corpus-tools-bench', 'отрицание не работает как разрешение'),
    ('unlike corpus-tools-bench, the probe suite covers 12 scenarios',
     1, 'общим словом', 'предмет речи назван общим словом'),
    ('the bench drives 56 scenarios', 1, 'общим словом', 'без имени стенда счёт не принимается'),
    ('56 scenarios and nobody named the bench', 1, 'общим словом', 'имени нет вовсе'),
    (TIE, 1, 'названы два стенда', 'два имени в одном предложении — отказ'),
    (TIE2, 1, 'названы два стенда', 'два имени в окне — отказ, а не ближайшее'),
    # Абзац объявил владельца первой строкой, а ближе к числу мимоходом назван
    # сосед. Прежде побеждало расстояние, и счёт сверялся с чужой константой.
    ('probe-bench is what this whole section is about.\n\nfiller line one\n\n'
     'corpus-tools-bench is mentioned once here, in passing.\n\n'
     'Its 52 scenarios stayed green.',
     1, 'названы два стенда', 'объявленный владелец не проигрывает соседу по расстоянию'),
    # Пометка освобождает РОВНО ОДИН счёт -- ближайший к ней.
    ('the pipeline runs 999 checks and probe-bench 999 scenarios docnum:historical',
     1, 'pipeline', 'пометка освобождает один счёт, а не всё предложение'),
    ('the pipeline runs 999 checks docnum:historical and probe-bench 56 scenarios',
     0, '', 'помеченный счёт свободен, второй сходится'),
    # Огороженный блок -- проза: в этот кит так вставляют вывод стендов.
    ('```\nprobe-bench: ИТОГ сценариев=56\n```', 0, '', 'огороженный блок сходится'),
    ('```\nprobe-bench: ИТОГ сценариев=99\n```', 1, 'probe-bench',
     'огороженный блок ловит расхождение'),
    # Таблица: существительное в шапке, число в ячейке.
    ('| стенд | сценариев |\n|---|---|\n| probe-bench | 56 |', 0, '',
     'ячейка таблицы сходится с шапкой'),
    ('| стенд | сценариев |\n|---|---|\n| probe-bench | 99 |', 1, 'probe-bench',
     'ячейка таблицы ловит расхождение по шапке'),
    # Числительные словами вне прежнего закрытого списка.
    ('probe-bench runs ninety scenarios.', 1, 'словом', 'ninety -- тоже счёт словом'),
    ('probe-bench гоняет девяносто сценариев.', 1, 'словом', 'девяносто -- тоже счёт словом'),
    ('judge-tools-bench: SELF-CHECK — 10 mutations', 0, '', 'обратная грамматика'),
    ('judge-tools-bench: SELF-CHECK — 11 mutations', 1, 'judge-tools-bench', 'обратная грамматика ловит расхождение'),
    ('the pipeline runs 114 checks', 0, '', 'конвейер назван по имени'),
    ('the pipeline runs 116 checks', 1, 'pipeline', 'единственный владелец тоже сверяется'),
    ('scenario_18 сценариев corpus-tools-bench', 0, '', 'цифры внутри имени не самостоятельный счёт'),
    ('corpus-tools-bench has 13 gates. Its scenarios are green', 0, '',
     'через точку число с существительным не женится'),
    ('corpus-tools-bench scenarios of the 3 modes', 0, '',
     'обратная форма без связки не женится'),
    # Круг 28, F-12: элидированная форма «все N» -- счёт без существительного.
    ('конвейер закрыл все 114 проверок.', 0, '',
     'существительное при числе -- обычный путь, «все» не мешает'),
    ('реестр конвейера сошёлся: все 114 сошлись.', 0, '',
     'элидированная форма с владельцем и сходящимся числом'),
    ('реестр конвейера сошёлся: все 113 сошлись.', 1,
     'не сходится ни с одной',
     'элидированное число сверяется с объявленными величинами'),
    ('все 113 сошлись.', 1, 'опущенным существительным',
     'элидированная форма требует владельца, как обычная'),
    ('все 113 сошлись docnum:other.', 0, '',
     'помеченная элидированная форма свободна'),
)
# Проза живёт и в коде, но читается там по своим правилам: докстринг питона и
# печатаемая шеллом строка -- проза, остальное -- значения.
FILE_CASES = (
    ('случай.py', '"""corpus-tools-bench runs 13 scenarios."""', 1,
     'corpus-tools-bench', 'докстринг питона -- проза'),
    ('случай.py', 'X = "corpus-tools-bench runs 13 scenarios"', 0, '',
     'строковое значение в коде -- не утверждение'),
    ('случай.sh', 'echo "стенд corpus-tools-bench прошёл 13 сценариев"', 1,
     'corpus-tools-bench', 'печатаемая строка -- проза'),
    ('случай.sh', 'X="corpus-tools-bench 13 сценариев"', 0, '',
     'присваивание в шелле -- не проза'),
)

broken = []
for path, text, want_n, want_why, name in FILE_CASES:
    got = scan(text, T, A, path)
    if len(got) != want_n or (want_why and want_why not in got[0][2]):
        broken.append((name, want_n, want_why, got))
for text, want_n, want_why, name in CASES:
    got = scan(text, T, A, 'случай.md')
    if len(got) != want_n or (want_why and want_why not in got[0][2]):
        broken.append((name, want_n, want_why, got))
if broken:
    print("ГРАММАТИКА ЧИСЕЛ БЕЗ ЗУБОВ: самопроверка не сошлась")
    for name, want_n, want_why, got in broken:
        print("  %s: ожидалось находок %d%s, получено %r"
              % (name, want_n, (' с «%s»' % want_why) if want_why else '', got))
    sys.exit(1)
_CASES_N = len(CASES) + len(FILE_CASES)
print("ГРАММАТИКА ЧИСЕЛ: самопроверка %d/%d" % (_CASES_N, _CASES_N))

# --- что объявлено ------------------------------------------------------------
table, aliases = {}, []
for oid, names, parts, counts in OWNERS:
    path = sys.argv[1] if parts is None else os.path.join(here, *parts)
    if not os.path.exists(path):
        print("ЧИСЛА НЕ ОБЪЯВЛЕНЫ: нет файла %s (владелец %s)"
              % (os.path.relpath(path, here), oid))
        sys.exit(1)
    text = read(path)
    for quantity, rx in sorted(counts.items()):
        m = re.search(rx, text, re.M)
        if not m:
            print("ЧИСЛА НЕ ОБЪЯВЛЕНЫ: %s не объявляет свою величину «%s»"
                  % (os.path.relpath(path, here), quantity))
            sys.exit(1)
        table.setdefault(quantity, {})[oid] = m.group(1)
    for alias in names:
        aliases.append((alias, oid))

readme = os.path.join(here, 'README.md')
if not os.path.exists(readme):
    # Объявлено, а не молча: скрипт может законно ехать один.
    print("СВЕРКА ЧИСЕЛ ПРОПУЩЕНА — README.md рядом со скриптом не найден")
    sys.exit(0)

# Проза живёт не только в .md и не только рядом со скриптом. Перечень домов
# ЗАКРЫТЫМ списком уже дал дыру: AGENTS.md, judge/*.md, scripts/*.sh и probes/
# в него не входили, а счёт в них лежал. Теперь берётся всё дерево по
# расширению, за вычетом .git, распакованных образов и журнала кампании.
for _home in JOURNAL_DIRS:
    if not os.path.isdir(os.path.join(here, _home)):
        print("СВЕРКА ЧИСЕЛ ОТКАЗ: объявленный дом журнала кампании не найден: "
              + _home)
        sys.exit(1)

files = []
skipped = []
for root, dirs, names in os.walk(here):
    dirs[:] = [d for d in dirs
               if d not in ('.git', 'distros', 'node_modules', '__pycache__')]
    rel_dir = os.path.relpath(root, here)
    in_journal_home = any(rel_dir == _h or rel_dir.startswith(_h + os.sep)
                          for _h in JOURNAL_DIRS)
    for name in sorted(names):
        # Скрытые файлы -- не документация: гейт, вырезанный стендом в
        # `.docnum-gate.py`, попадал под собственный обход и краснел на своих
        # же синтетических случаях.
        if name.startswith('.'):
            continue
        # Расширения ТЕ ЖЕ, что понимает prose(): ветка для .txt объявлена там,
        # а обход их не собирал -- недостижимая ветка выглядит как охват.
        if os.path.splitext(name)[1] not in ('.md', '.txt', '.sh', '.py', '.js'):
            continue
        if name in JOURNALS or in_journal_home:
            skipped.append(os.path.relpath(os.path.join(root, name), here))
            continue
        files.append(os.path.join(root, name))
if skipped:
    print("СВЕРКА ЧИСЕЛ: журналы кампании не сканируются (%s) -- файлов: %s"
          % ('; '.join(list(JOURNALS) + [_h + os.sep for _h in JOURNAL_DIRS]),
             len(skipped)))
files = sorted(set(files + [readme, os.path.abspath(sys.argv[1])]))

bad = []
for path in files:
    if not os.path.exists(path):
        continue
    for lineno, got, why in scan(read(path), table, aliases, path):
        bad.append((path, lineno, got, why))

if bad:
    print("ЧИСЛА В ДОКАХ РАЗОШЛИСЬ С ОБЪЯВЛЕННЫМИ:")
    for path, lineno, got, why in bad:
        print("  %s:%d  «%s» — %s" % (os.path.relpath(path, here), lineno, got, why))
    print("  Если число ИСТОРИЧЕСКОЕ, это счёт ПОДМНОЖЕСТВА, ПРИРАЩЕНИЕ или речь")
    print("  вообще не о счётчиках кита, поставьте в том же предложении явную")
    print("  пометку: docnum:historical / docnum:subset / docnum:delta / docnum:other.")
    print("  Если число про конкретный стенд — рядом должно стоять его ИМЯ, а не")
    print("  общее слово «стенд»/«bench»: владелец выбирается по ближайшему имени.")
    sys.exit(1)
print("ЧИСЛА В ДОКАХ СОВПАДАЮТ С ОБЪЯВЛЕННЫМИ (%s)" % '; '.join(
    '%s: %s' % (quantity, ', '.join('%s=%s' % (oid, val)
                                    for oid, val in sorted(by.items())))
    for quantity, by in sorted(table.items())))
PYDOCS

# --- 0e. и у этого гейта должны быть зубы -----------------------------------
# Внутри гейта живёт положительный контроль его грамматики, но грамматика,
# сходящаяся на синтетике, ничего не говорит о СВЯЗКЕ с деревом: о README, о
# константах стендов, о выборе владельца по ближайшему имени. Стенд проверяет
# связку на копии кита: пристинный кит обязан быть зелёным, затем каждая
# записанная мутация обязана покраснить гейт своей причиной (1 с на сборку).
# Круг 26, W-2: волна меняет форму или число, а таблицы, запинившие прежнюю
# форму, находятся строго по одной за прогон -- пять последовательных отказов
# там, где предмет один. Перепись якорей стоит ПЕРЕД зубами: она не собирает кит
# и не гоняет гейт, а уехавший вход называет своим номером (D2), тогда как без
# неё то же самое проступает как «мутация не покраснела» после сорока прогонов.
# Гейт наследования замка стоит здесь же, среди дешёвых стадий формы: он не
# собирает кит и не запускает инструменты, а читает их вызовы. Предмет -- та
# дисциплина, которая держалась на памяти автора у каждого нового вызова и
# однажды отказала: осиротевший внук стенда держал замок за законченный
# прогон, и свип дважды отказал на «занятом» замке при отсутствии сборки.
echo "==> Гейт наследования замка"
python3 "$(dirname "$0")/tools/lockfd-check.py" --self-check 9>&- || {
  echo "ГЕЙТ ЗАМКА: грамматика не сошлась со своими синтетическими случаями --" >&2
  echo "  прибор мерить не может, а не дерево чисто" >&2
  exit 2
}
python3 "$(dirname "$0")/tools/lockfd-check.py" 9>&- || {
  __rc=$?
  case $__rc in
    1) echo "ГЕЙТ ЗАМКА: вызов инструмента при открытом замке без N>&- (места названы выше)." >&2
       echo "  Внук такого вызова держит замок после конца прогона." >&2
       exit 1 ;;
    2) echo "ГЕЙТ ЗАМКА: прибор смотрит не туда -- нет файлов кита либо" >&2
       echo "  конвейер без открытия замка (rc=2)" >&2
       exit 2 ;;
    5) echo "ГЕЙТ ЗАМКА: ни одного открытия замка не найдено -- мерить нечего (rc=5)" >&2
       exit 5 ;;
    *) echo "ГЕЙТ ЗАМКА: неизвестный ответ гейта ($__rc)" >&2
       exit 1 ;;
  esac
}

# Ручек ДВЕ, потому что предметов два, и путать их дорого в обе стороны.
# CLAUDE_PATCH_SKIP_KIT_BENCH гасит стенды, чей предмет -- САМ КИТ: между
# сборками одной волны они мерят один и тот же неизменившийся предмет и стоят
# минуты на КАЖДУЮ сборку. CLAUDE_PATCH_SKIP_BENCH гасит стенд зондов, чей
# предмет -- СОБРАННЫЙ ОБРАЗ (поведение судьи и наблюдателя внутри него), и он
# у каждой версии свой. Одна общая ручка успела побывать обеими ошибками:
# сперва имя обещало батарею, а гасило один стенд из пяти, и оператор платил
# полную цену молча; затем, когда ею накрыли батарею, свип перестал проверять
# зонды на всех версиях кроме первой -- потеря покрытия, которую поймал его же
# вердикт. Пропуск ОБЪЯВЛЯЕТСЯ поимённо: escape hatch без следа неотличим от
# гейта, который отработал.
# ПЕРЕПИСЬ ЯКОРЕЙ ИДЁТ ВСЕГДА, ручка её не гасит. Ручка объявлена гасить ЦЕНУ:
# стенды, которые стоят минуты на каждую сборку при неизменившемся предмете. У
# переписи цены нет -- она не собирает кит и не гоняет гейт, а только требует,
# чтобы запись каждой строки таблицы встречалась в названном ею файле ровно
# один раз. Цена ПРОПУСКА, напротив, измерена: семь якорей уехали за двумя
# правками счётчиков и прожили незамеченными, потому что ОБЕ сборочные дорожки
# ставят CLAUDE_PATCH_SKIP_KIT_BENCH (build-path-probe -- всегда, sweep --
# кроме первой версии), и дешёвая дверь гасла заодно с дорогими зубами (#192).
# Ручка гасит цену, а не зрение.
echo "==> Перепись якорей таблицы гейта чисел"
python3 "$(dirname "$0")/tools/docnum-bench.py" --anchors 9>&- || {
  __rc=$?
  case $__rc in
    2) echo "ПЕРЕПИСЬ ЯКОРЕЙ: НЕ ИЗМЕРЯЛА -- нет таблицы либо её контроль" >&2
       echo "  на синтетике не сошёлся (rc=2)" >&2
       exit 2 ;;
    4) echo "ПЕРЕПИСЬ ЯКОРЕЙ: якорь таблицы уехал за правкой дерева --" >&2
       echo "  номера уехавших строк названы выше" >&2
       exit 4 ;;
    *) echo "ПЕРЕПИСЬ ЯКОРЕЙ: неизвестный ответ стенда ($__rc)" >&2
       exit 1 ;;
  esac
}

if [[ "${CLAUDE_PATCH_SKIP_KIT_BENCH:-0}" == "1" ]]; then
  echo "Зубы гейта чисел: ПРОПУЩЕНЫ -- CLAUDE_PATCH_SKIP_KIT_BENCH=1. НЕ проверены: зубы гейта чисел (перепись якорей отработала выше -- она под ручку не подпадает)" >&2
else
echo "==> Зубы гейта чисел"
python3 "$(dirname "$0")/tools/docnum-bench.py" 9>&- || {
  __rc=$?
  case $__rc in
    2) echo "ГЕЙТ ЧИСЕЛ: СТЕНД НЕ ИЗМЕРЯЛ -- нет таблицы/якоря либо КОНТРОЛЬ" >&2
       echo "  ПРОВАЛЕН: пристинный кит уже красный (rc=2)" >&2
       exit 2 ;;
    4) echo "ГЕЙТ ЧИСЕЛ: в таблице не столько мутаций, сколько объявлено" >&2
       # Круг 28, F-6(б): класс 4 сохраняется, текст не меняется.
       exit 4 ;;
    *) echo "ГЕЙТ ЧИСЕЛ БЕЗ ЗУБОВ: мутация не покраснела своей причиной" >&2
       exit 1 ;;
  esac
}
fi

# Зубы обоих гвардов идут ВСЕГДА, ручка CLAUDE_PATCH_SKIP_KIT_BENCH их не
# гасит: она объявлена гасить ЦЕНУ, а цены у этих прогонов нет (замерено 0 с и
# 1 с -- docnum:other, это длительность прогона, а не счётчик кита). Беззубый
# гвард неотличим от рабочего, а числа его зубов сторожит гейт чисел -- ровно
# связка «числа сторожатся, а исполнителя нет», против которой заведена
# перепись ниже.
echo "==> Зубы гварда герметичности стендов"
bash "$(dirname "$0")/tools/stand-env-guard-teeth.sh" 9>&- || {
  __rc=$?
  case $__rc in
    2) echo "ЗУБЫ ГЕРМЕТИЧНОСТИ: НЕ ИЗМЕРЯЛИ -- прибор отказал (rc=2)" >&2
       exit 2 ;;
    4) echo "ЗУБЫ ГЕРМЕТИЧНОСТИ: прогнано либо прошло не столько, сколько" >&2
       echo "  объявлено пином EXPECTED_TEETH (rc=4)" >&2
       exit 4 ;;
    *) echo "ГВАРД ГЕРМЕТИЧНОСТИ БЕЗ ЗУБОВ: мутация не покраснела своей" >&2
       echo "  причиной (rc=$__rc)" >&2
       exit 1 ;;
  esac
}

echo "==> Зубы гварда живости ручек"
bash "$(dirname "$0")/tools/env-handles-live-guard-teeth.sh" 9>&- || {
  __rc=$?
  case $__rc in
    2) echo "ЗУБЫ ЖИВОСТИ РУЧЕК: НЕ ИЗМЕРЯЛИ -- прибор отказал (rc=2)" >&2
       exit 2 ;;
    4) echo "ЗУБЫ ЖИВОСТИ РУЧЕК: прогнано либо прошло не столько, сколько" >&2
       echo "  объявлено пином EXPECTED_TEETH (rc=4)" >&2
       exit 4 ;;
    *) echo "ГВАРД ЖИВОСТИ РУЧЕК БЕЗ ЗУБОВ: мутация не покраснела своей" >&2
       echo "  причиной (rc=$__rc)" >&2
       exit 1 ;;
  esac
}

# --- 0e-ter-pre. гвард живости ручек на реальном дереве (#305) ----------------
# CONSTRAINT: гвард зовётся на РЕАЛЬНОМ предмете (живые настройки и живой
# образ), а не только собственными зубами -- прибор, которого зовут одни
# зубы, реальное дерево не мерит никогда. Дома -- ИСЧЕРПЫВАЮЩЕЕ разделение
# детей корня семьи из tools/env-guard-ours.txt ([ours]/[foreign]; чужие
# дома НЕ осматриваются); каталог вне разделения и любой дрейф файла роняют
# ПРИБОР (rc=2) с именем, а не зеленят предмет.
echo "==> Гвард живости ручек на реальном дереве"
__env_guard_homes="$(dirname "$0")/tools/env-guard-ours.txt"
if [[ ! -f "$__env_guard_homes" ]]; then
  echo "ГВАРД ЖИВОСТИ НА ДЕРЕВЕ: НЕ ИЗМЕРЯЛИ -- файл разделения домов отсутствует (rc=2)" >&2
  exit 2
fi
bash "$(dirname "$0")/tools/env-handles-live-guard.sh" --label "реальное дерево" --homes "$__env_guard_homes" 9>&- || {
  __rc=$?
  case $__rc in
    2) echo "ГВАРД ЖИВОСТИ НА ДЕРЕВЕ: НЕ ИЗМЕРЯЛИ -- прибор отказал (rc=2)" >&2
       exit 2 ;;
    3) echo "ГВАРД ЖИВОСТИ НА ДЕРЕВЕ: ЕСТЬ РУЧКА БЕЗ ЧИТАТЕЛЯ (имена выше)" >&2
       exit 3 ;;
    5) echo "ГВАРД ЖИВОСТИ НА ДЕРЕВЕ: НОЛЬ РУЧЕК ENV в настройках (rc=5)" >&2
       exit 5 ;;
    6) echo "ГВАРД ЖИВОСТИ НА ДЕРЕВЕ: ЧИТАТЕЛЬ ТОЛЬКО В СБОРКЕ -- расхождение сборки и исходника (имена выше)" >&2
       exit 6 ;;
    *) echo "ГВАРД ЖИВОСТИ НА ДЕРЕВЕ: неизвестный ответ гварда (rc=$__rc)" >&2
       exit 1 ;;
  esac
}

# --- 0e-ter. пины опций встроенных модов (#303) -------------------------------
# CONSTRAINT: гвард зовётся на РЕАЛЬНОМ предмете (живые настройки и живой
# образ), а не только собственными зубами -- прибор, которого зовут одни
# зубы, реальное дерево не мерит никогда (замеренный дефект-образец #305).
echo "==> Пины опций встроенных модов"
bash "$(dirname "$0")/tools/builtin-option-pin-guard.sh" 9>&- || {
  __rc=$?
  case $__rc in
    2) echo "ПИНЫ ОПЦИЙ ВСТРОЕННЫХ МОДОВ: НЕ ИЗМЕРЯЛИ -- прибор отказал (rc=2)" >&2
       exit 2 ;;
    1) echo "ПИНЫ ОПЦИЙ ВСТРОЕННЫХ МОДОВ: отказ -- пин пропал или разошёлся (имена выше)" >&2
       exit 1 ;;
    *) echo "ПИНЫ ОПЦИЙ ВСТРОЕННЫХ МОДОВ: неизвестный ответ гварда (rc=$__rc)" >&2
       exit 1 ;;
  esac
}

echo "==> Зубы гварда пинов опций"
bash "$(dirname "$0")/tools/builtin-option-pin-guard-teeth.sh" 9>&- || {
  __rc=$?
  case $__rc in
    2) echo "ЗУБЫ ГВАРДА ПИНОВ ОПЦИЙ: НЕ ИЗМЕРЯЛИ -- прибор отказал (rc=2)" >&2
       exit 2 ;;
    4) echo "ЗУБЫ ГВАРДА ПИНОВ ОПЦИЙ: прогнано либо прошло не столько, сколько" >&2
       echo "  объявлено пином EXPECTED_TEETH (rc=4)" >&2
       exit 4 ;;
    *) echo "ГВАРД ПИНОВ ОПЦИЙ БЕЗ ЗУБОВ: мутация не покраснела своей" >&2
       echo "  причиной (rc=$__rc)" >&2
       exit 1 ;;
  esac
}

# --- 0e-bis. у стендов и гейтов должен быть ИСПОЛНИТЕЛЬ ----------------------
# Дверь против инструмента-сироты: прибор есть, его числа сторожатся гейтом
# чисел, а исполнителя нет -- такая тишина уже была на живом дереве (корпусный
# прибор зубов не звал никто, #144). Дешёвая стадия формы, как гейт замка:
# кит не собирается, читаются вызовы. Отказ роняет прогон.
echo "==> Перепись исполнителей инструментов"
python3 "$(dirname "$0")/tools/orphan-stand-gate.py" --self-check 9>&- || {
  echo "ПЕРЕПИСЬ ИСПОЛНИТЕЛЕЙ: положительный контроль не прошёл --" >&2
  echo "  прибор мерить не может, а не дерево чисто" >&2
  exit 2
}
python3 "$(dirname "$0")/tools/orphan-stand-gate.py" 9>&- || {
  __rc=$?
  case $__rc in
    1) echo "ПЕРЕПИСЬ ИСПОЛНИТЕЛЕЙ: инструмент-сирота -- числа сторожатся, а исполнителя нет (имена выше)" >&2
       exit 1 ;;
    2) echo "ПЕРЕПИСЬ ИСПОЛНИТЕЛЕЙ: прибор не может мерить (причины выше)" >&2
       exit 2 ;;
    *) echo "ПЕРЕПИСЬ ИСПОЛНИТЕЛЕЙ: неизвестный ответ гейта ($__rc)" >&2
       exit 1 ;;
  esac
}

# --- перепись стадий конвейера: каждая стадия объявлена с пином (#63) ---------
# Корень #63: стадия `echo "==> ..."` пиняема по умолчанию НЕ была — новую можно
# было добавить, не объявив, чем ловится её провал, и она текла молчаливо-зелёной.
# Дом объявлений — tools/pipeline-stages.tsv; гейт census роняет прогон, если
# стадия источника не заявлена строкой канона, если строка канона мертва, если
# pin sweep:<field> висит на несуществующем поле sweep.sh, либо счёт стадий
# разошёлся с EXPECTED_STAGES. Так "стадия пиняема по умолчанию".
EXPECTED_STAGES=35
echo "==> Перепись стадий конвейера"
python3 "$(dirname "$0")/tools/pipeline-stage-census.py" census \
    --source "$0" \
    --table "$(dirname "$0")/tools/pipeline-stages.tsv" \
    --sweep "$(dirname "$0")/tools/sweep.sh" \
    --expected "$EXPECTED_STAGES" 9>&- || {
  __rc=$?
  case $__rc in
    2) echo "ПЕРЕПИСЬ СТАДИЙ: стадия конвейера не пиняется каноном (ОТКАЗы выше)" >&2
       exit 2 ;;
    3) echo "ПЕРЕПИСЬ СТАДИЙ: прибор не может мерить (нет/нечитаем файл, битый канон)" >&2
       exit 3 ;;
    *) echo "ПЕРЕПИСЬ СТАДИЙ: неизвестный ответ гейта ($__rc)" >&2
       exit 1 ;;
  esac
}

# --- which tweakcc unpacks the image -----------------------------------------
# Claude Code 2.1.242 split the bundle from one 28 MB module into an ESM entry
# plus ~1400 chunks. Published tweakcc (4.3.3 and every release after it as of
# this writing) extracts the entry ALONE, so all 25 locators search a 20 KB stub
# and the whole set fails at once — a failure that reads like 25 broken patches
# rather than one broken unpacker, which is exactly how it was first misread.
# Our fork joins the entry with its chunks; on 2.1.241 and earlier its selection
# is a single module and it behaves identically to the published one.
#
# This is the second time the unpacker, not the patches, was the thing that
# broke: 4.3.2 could not read the container Claude Code ships from 2.1.231 on
# (bun bumped, the binary grew ~5 MB) and aborted with "Failed to extract
# JavaScript from native installation" before any patch was evaluated. That one
# was fixable by raising a version floor; this one was not, which is why there
# is a fork.
#
# The fork is pinned BY COMMIT, never by branch. The unpacker decides what every
# locator sees, so "whatever main happens to be today" would silently make two
# runs of this script incomparable. A commit SHA is content-addressed, so the
# pin is its own integrity check: GitHub cannot serve a different tree under it.
# Bump it deliberately, the way any dependency is bumped.
CATALYST_TWEAKCC_REPO="${CATALYST_TWEAKCC_REPO:-TransmuteLabs/Catalyst-tweakcc}"
CATALYST_TWEAKCC_SHA="${CATALYST_TWEAKCC_SHA:-7e2a07e5b78c0b1607ab109adc2e5d2f7ed61768}"
# Подменённый источник распаковщика объявляется ВСЕГДА, а не только когда его
# качают: строка «Fetching the unpacker» печатается лишь мимо кэша, и сборка с
# чужой веткой в тёплом кэше была неотличима от сборки с запиненной.
[[ "$CATALYST_TWEAKCC_REPO" == "TransmuteLabs/Catalyst-tweakcc" \
   && "$CATALYST_TWEAKCC_SHA" == "7e2a07e5b78c0b1607ab109adc2e5d2f7ed61768" ]] \
  || echo "Unpacker source OVERRIDDEN: $CATALYST_TWEAKCC_REPO @ ${CATALYST_TWEAKCC_SHA:0:12} (not the pinned fork)"
CATALYST_TWEAKCC_CACHE="${CATALYST_TWEAKCC_CACHE:-$HOME/.cache/catalyst-tweakcc}"

# TWEAKCC_LOCAL is the development escape hatch: point it at a built
# dist/index.mjs to try an unpacker change before it is pushed and pinned. It is
# an EXPLICIT opt-in and it announces itself — an implicit "use the sibling
# checkout if one happens to be there" would make the run depend on the shape of
# somebody's disk.
ensure_tweakcc() {
  if [[ -n "${TWEAKCC_LOCAL:-}" ]]; then
    [[ -f "$TWEAKCC_LOCAL" ]] || { echo "ERROR: TWEAKCC_LOCAL=$TWEAKCC_LOCAL does not exist"; exit 1; }
    TWEAKCC=(node "$TWEAKCC_LOCAL")
    echo "Unpacker: local build via TWEAKCC_LOCAL ($TWEAKCC_LOCAL)"
    return
  fi

  local dir="$CATALYST_TWEAKCC_CACHE/$CATALYST_TWEAKCC_SHA"
  if [[ ! -f "$dir/dist/index.mjs" ]]; then
    echo "==> Fetching the unpacker: $CATALYST_TWEAKCC_REPO @ ${CATALYST_TWEAKCC_SHA:0:12}"
    # Built in .tmp and renamed into place only once dist/index.mjs exists, so an
    # interrupted fetch can never leave a cache entry that looks complete.
    rm -rf "$dir.tmp"
    mkdir -p "$dir.tmp"
    # No `curl | tar`: a pipe reports the LAST stage's exit code, and a failed
    # download would read as a successful extraction of nothing.
    curl -fsSL --connect-timeout 20 --max-time 300 -o "$dir.tmp/src.tar.gz" \
      "https://codeload.github.com/$CATALYST_TWEAKCC_REPO/tar.gz/$CATALYST_TWEAKCC_SHA" \
      || { echo "ERROR: could not fetch $CATALYST_TWEAKCC_REPO @ $CATALYST_TWEAKCC_SHA"; exit 1; }
    tar -xzf "$dir.tmp/src.tar.gz" -C "$dir.tmp" --strip-components=1 \
      || { echo "ERROR: could not unpack the unpacker tarball"; exit 1; }
    rm -f "$dir.tmp/src.tar.gz"
    ( cd "$dir.tmp" \
      && npx -y pnpm@latest install --frozen-lockfile \
      && npx -y pnpm@latest run build ) \
      || { echo "ERROR: unpacker build failed in $dir.tmp"; exit 1; }
    [[ -f "$dir.tmp/dist/index.mjs" ]] \
      || { echo "ERROR: unpacker build produced no dist/index.mjs"; exit 1; }
    rm -rf "$dir"
    mv "$dir.tmp" "$dir"
    echo "Unpacker cached in $dir"
  fi

  TWEAKCC=(node "$dir/dist/index.mjs")
  echo "Unpacker: $CATALYST_TWEAKCC_REPO @ ${CATALYST_TWEAKCC_SHA:0:12}"
  prune_tweakcc_cache 2
}
# --- обёртка окружения для запуска форка --------------------------------------
# Форк ходит в сеть глобальным `fetch` node (undici), а undici переменные
# `*_proxy` НЕ читает: их читает только `NODE_USE_ENV_PROXY=1`. На машине, где
# интернет доступен ТОЛЬКО через прокси, форк без этой ручки скачивает ноль
# снимков промтов, и слой промтов обваливается целиком -- корень #101. Дверь
# обвала (__tw_prompt_outage_door) причину теперь НАЗЫВАЕТ, но назвать -- не
# значит починить: ручку всё равно приходилось дописывать руками, на каждом
# прогоне, на каждой такой машине.
#
# Решение юзера 2026-09-10: кит подставляет ручку САМ, но только (а) объявляя
# подстановку ОТДЕЛЬНОЙ строкой лога и (б) имея выключатель для машины, где
# подстановка нежелательна. Молчаливая правка окружения чужого процесса
# запрещена: разбор прогона по логу перестал бы сходиться с тем, что на самом
# деле исполнялось.
#
# КОНСТРЕЙНТ: обёртка ставится на МАССИВ запуска, а не на сайты вызова. Сайтов
# вызова у форка несколько, и добавленный когда-нибудь позже молча прошёл бы
# мимо ручки; место сборки массива одно -- мимо него не пройти по устройству.
#
# Случаи и что печатается:
#   прокси в окружении нет  -- подставлять нечего, молчим (иначе строка шла бы
#                              на КАЖДОЙ машине, где никакого прокси нет);
#   ручку задал оператор    -- уважаем его значение, в том числе `0`, то есть
#                              явный запрет; кит поверх него не пишет;
#   выключатель поднят      -- не подставляем и говорим, чем это грозит;
#   иначе                   -- подставляем и НАЗЫВАЕМ выключатель.
#
# КОНСТРЕЙНТ ДВЕРЕЙ: решает НАЛИЧИЕ ключа (`${X+set}`), а не его непустота.
# Пояс `-n "${X:-}"` склеивает «не задано» и «задано пустым», и кит подставлял
# бы своё значение поверх ПУСТОГО, заданного оператором намеренно, -- а пустая
# строка у обеих ручек значащая (для слоя промтов она в таблице форка -- слово
# «слой оставить»). Тот же класс, что дверь --expect-sha в #117.
__tw_node_proxy_wrap() {   # переписывает TWEAKCC, добавляя обёртку окружения
  local __v __seen=""
  for __v in https_proxy HTTPS_PROXY http_proxy HTTP_PROXY all_proxy ALL_PROXY; do
    # `if`, а не `&&`: последний `&&` с ложным условием отдаёт функции ненулевой
    # код, и под `set -e` это отказ прогона на ровном месте.
    if [[ -n "${!__v:-}" ]]; then __seen="${__seen} ${__v}"; fi
  done
  if [[ -z "${__seen}" ]]; then return 0; fi
  if [[ -n "${NODE_USE_ENV_PROXY+set}" ]]; then
    # Пустое значение печатается меткой: строка «NODE_USE_ENV_PROXY= задан
    # ОПЕРАТОРОМ» читается как обрыв лога, а не как замер.
    echo "Прокси node: NODE_USE_ENV_PROXY=${NODE_USE_ENV_PROXY:-<пусто>} задан ОПЕРАТОРОМ -- кит своего не подставляет (в окружении задано:${__seen})"
    return 0
  fi
  if [[ -n "${CATALYST_TWEAKCC_NO_ENV_PROXY+set}" ]]; then
    echo "Прокси node: подстановка NODE_USE_ENV_PROXY ОТКЛЮЧЕНА ручкой CATALYST_TWEAKCC_NO_ENV_PROXY -- форк пойдёт в сеть мимо прокси, и слой промтов может обвалиться (в окружении задано:${__seen})"
    return 0
  fi
  TWEAKCC=(env NODE_USE_ENV_PROXY=1 "${TWEAKCC[@]}")
  echo "Прокси node: запуску форка ПОДСТАВЛЕН NODE_USE_ENV_PROXY=1 -- в окружении задано:${__seen}, а global fetch node без этой ручки прокси не видит. Отключить: CATALYST_TWEAKCC_NO_ENV_PROXY=1"
}

# --- слой промтов форка: кит его ВЫКЛЮЧАЕТ -----------------------------------
# Слой накладок форка состоит из двух половин: синхронизация каталога накладок
# со снимком промтов апстрима и правка образа этими накладками. Замер 12.09
# (задача #120): из 901 накладки живого дома НИ ОДНА не несёт нашего текста --
# при работающем контроле класса (текст правки 26 в живом образе есть, в
# пристинном близнеце его нет, то есть различитель «наше» видит). Портировать
# было нечего: промты у нас пишет мод (`prompt.section`, `tool.describe`,
# `command.describe`) во время исполнения, а слой при этом продолжал стоить --
# зависимостью от снимка апстрима (для 2.1.268 он отвечает 404 и держит #118),
# тремя пер-машинными объявлениями и четырьмя закрытыми задачами о его же
# обвалах.
#
# ПОЧЕМУ ОБЕ ПОЛОВИНЫ СРАЗУ. Половинчатые состояния как раз и вводят в
# заблуждение: синхронизация без правки тянет сеть ради накладок, которые никто
# не впишет, а правка без синхронизации вписывает в свежий образ УСТАРЕВШИЙ
# текст -- это дефект #106 дословно.
#
# ТЕ ЖЕ ДВА ЗАКОНА, ЧТО У РУЧКИ ПРОКСИ ВЫШЕ: подстановка ОБЪЯВЛЯЕТСЯ отдельной
# строкой лога, и у неё есть выключатель. Значение, заданное ОПЕРАТОРОМ,
# уважается целиком, включая `0` и ПУСТУЮ строку -- оба в таблице форка значат
# «слой мне нужен», и дверь поэтому смотрит на НАЛИЧИЕ ключа, а не на непустоту.
#
# КОНСТРЕЙНТ: обёртка ставится на МАССИВ запуска (одно место), а не на сайты
# вызова форка -- сайт, добавленный позже, иначе молча прошёл бы мимо ручки.
#
# ВТОРОЙ КОНСТРЕЙНТ: подстановка поднимает TW_PROMPTS_KNOB, и двери слоя по
# нему ТРЕБУЮТ от форка объявления. Подставить ручку и не проверить, что её
# послушали, -- это и есть вакуумный ноль: старый пин форка ручки не знает,
# промты вписал бы как раньше, а нули дверей читались бы как «слой выключен».
__tw_no_prompts_wrap() {   # переписывает TWEAKCC, добавляя выключатель слоя промтов
  if [[ -n "${TWEAKCC_NO_SYSTEM_PROMPTS+set}" ]]; then
    # НАЛИЧИЕ, а не непустота: пустая строка -- это выключающее слово ИЗ ТАБЛИЦЫ
    # ФОРКА («слой оставить»), и подставить поверх неё `1` значило бы отменить
    # решение оператора ровно наоборот. Метка `<пусто>` -- чтобы этот случай
    # читался в логе, а не выглядел оборванной строкой.
    echo "Слой промтов: TWEAKCC_NO_SYSTEM_PROMPTS=${TWEAKCC_NO_SYSTEM_PROMPTS:-<пусто>} задан ОПЕРАТОРОМ -- кит своего не подставляет"
    # Двери требуют объявления только там, где выключение -- решение КИТА.
    # Оператор, задавший ручку сам, отвечает за неё сам; а задавший её в
    # выключающее значение получил бы от двери отказ по отсутствию объявления
    # на пине форка, который ручки не знает, -- отказ о ЧУЖОМ решении.
    return 0
  fi
  if [[ -n "${CATALYST_TWEAKCC_KEEP_PROMPTS+set}" ]]; then
    echo "Слой промтов: выключение ОТМЕНЕНО ручкой CATALYST_TWEAKCC_KEEP_PROMPTS -- форк пойдёт за снимком промтов апстрима и будет править образ накладками"
    return 0
  fi
  TWEAKCC=(env TWEAKCC_NO_SYSTEM_PROMPTS=1 "${TWEAKCC[@]}")
  TW_PROMPTS_KNOB=1
  echo "Слой промтов: запуску форка подставлен TWEAKCC_NO_SYSTEM_PROMPTS=1 -- снимок промтов не качается, накладки в образ не пишутся (наши промты пишет мод). Оставить слой: CATALYST_TWEAKCC_KEEP_PROMPTS=1"
}

ensure_tweakcc
__tw_node_proxy_wrap
# Умолчание объявляется ДО подстановки: ветка, ушедшая из обёртки раньше,
# обязана оставить ключ опущенным, а не унаследовать чужое значение.
TW_PROMPTS_KNOB=0
__tw_no_prompts_wrap

# --- 1. let the user pick tweakcc's patches ----------------------------------
if [[ $CONFIGURE -eq 1 ]]; then
  echo "==> Opening tweakcc's UI — pick the patches you want, save, and quit."
  "${TWEAKCC[@]}" || true
fi

# --- 1b. tweakcc's backup decides what the build starts from -----------------
# Its `--apply` calls restoreNativeBinaryFromBackup() unconditionally for native
# installs (patches/index.ts, pinned SHA): it writes the backup's bytes over
# whatever ccInstallationPath names, and only then patches. Step 0b points that
# path at OUR staging file, so the pristine copy we just made is overwritten
# before tweakcc's first patch lands. Staging alone therefore guarantees
# nothing -- the file the build really starts from is this backup, and it is the
# one that has to be verified. Hence BEFORE the stage: an earlier version of this
# check ran after it, and would have repaired the backup for next time while
# this build had already been made from the poisoned bytes.
#
# With no backup yet, tweakcc's startupCheck creates one from
# ccInstallationPath -- our pristine staging file -- which needs nothing from us.
# Дом tweakcc -- ОДНО разрешение на весь кит.
#
# Прежде дом был вписан в десяток мест как `$HOME/.tweakcc`, и любой прогон,
# который не должен был трогать живое состояние -- свип по корпусу, зонд пути
# сборки, игрушечные прогоны стендов, -- всё равно переписывал живой бэкап и
# живой ccVersion. Измерено 2026-08-28 посреди свипа: `native-binary.backup`
# нёс байты КОРПУСНОЙ версии, а `ccInstallationPath` указывал во временный
# каталог. Это уничтожение точки восстановления живой установки прогоном,
# который к ней отношения не имеет (круг 21, линза E, находка 1).
#
# Лестница -- ТА ЖЕ, что у распаковщика (его `getConfigDir`, src/config.ts
# запиненного форка): переменная, затем существующий ~/.tweakcc, затем
# существующий ~/.claude/tweakcc, затем XDG, иначе ~/.tweakcc. Расхождение
# лестниц ловится ПОСЛЕ стадии: распаковщик печатает, куда он сохранил конфиг,
# и это обязано лежать внутри дома, который назвали мы.
TWEAKCC_HOME="${TWEAKCC_CONFIG_DIR:-}"
if [[ -z "$TWEAKCC_HOME" ]]; then
  if [[ -d "$HOME/.tweakcc" ]]; then TWEAKCC_HOME="$HOME/.tweakcc"
  elif [[ -d "$HOME/.claude/tweakcc" ]]; then TWEAKCC_HOME="$HOME/.claude/tweakcc"
  elif [[ -n "${XDG_CONFIG_HOME:-}" ]]; then TWEAKCC_HOME="$XDG_CONFIG_HOME/tweakcc"
  else TWEAKCC_HOME="$HOME/.tweakcc"
  fi
fi
[[ "$TWEAKCC_HOME" == "$HOME/.tweakcc" ]] \
  || echo "Дом tweakcc: $TWEAKCC_HOME (не умолчание)"
TWEAKCC_BACKUP="$TWEAKCC_HOME/native-binary.backup"
# Запись, по которой tweakcc решает, освежать бэкап или восстанавливать его:
# страж ниже обязан спрашивать ЕЁ, а не версию файла бэкапа.
TWEAKCC_CFG="$TWEAKCC_HOME/config.json"
# Объявление правок, выключенных конфигурацией ЭТОГО дома. Дом файла -- дом
# tweakcc, а не репозиторий и не ~/.claude: лестница выше допускает несколько
# домов на машине, у каждого свой config.json и своё множество выключенных, и
# объявление обязано ездить вместе с конфигом. Клон дома свипом и заём живого
# дома зондом уносят его с собой сами. Кит этот файл только ЧИТАЕТ.
TWEAKCC_EXPECTED_OFF="$TWEAKCC_HOME/catalyst-expected-off.txt"
# Отметка ПРОИСХОЖДЕНИЯ дома. Предмет двери множества выключенных -- ДРЕЙФ
# конфига во времени: набор изменился, а объявление осталось прежним. У дома,
# который свип создаёт заново на каждый прогон (живого дома на машине нет), оси
# времени нет вовсе: оператора у него не было, истории тоже, а выключено в нём
# то, что гасят ДЕФОЛТЫ ФОРКА -- на пустом доме и образе 2.1.261 измерено
# ○ = 30 из 49 правок кода. Требовать от такого дома объявления -- значит
# красить свежую машину без единого дефекта.
#
# ГРАНИЦА послабления держится у ПИСАТЕЛЯ, а не у этой двери: отметку кладёт
# только тот, кто дом создал сам (tools/sweep.sh). Ни живой ~/.tweakcc, ни клон
# живого дома, ни одолженный зондом дом её не несут -- у них оператор есть, и
# дверь работает по-прежнему двусторонне.
#
# СТОЛБЕЦ 0 ОБЯЗАТЕЛЕН: имя достаёт свип якорем `^TWEAKCC_HOME_ORIGIN_NAME=`
# (tools/sweep.sh), и отступ оставил бы его без имени. Имя принадлежит
# конвейеру -- он единственный читатель; вторая копия имени у писателя
# разошлась бы с читателем МОЛЧА и ровно на той машине, ради которой отметка и
# заведена, -- на свежей, где живого дома нет.
TWEAKCC_HOME_ORIGIN_NAME='catalyst-home-origin.txt'
TWEAKCC_HOME_ORIGIN="$TWEAKCC_HOME/$TWEAKCC_HOME_ORIGIN_NAME"
# Пол слоя промтов -- сосед по владельцу: число легших накладок снято с каталога
# накладок ОПЕРАТОРА ($TWEAKCC_HOME/system-prompts), и в репозитории кита оно
# отказывало бы на любой второй машине, где каталог другой. Дом тот же, по той
# же лестнице, и по той же причине: объявление ездит вместе с домом.
TWEAKCC_EXPECTED_PROMPT_FLOOR="$TWEAKCC_HOME/catalyst-prompt-floor.txt"
# Объявление КОНФЛИКТОВ синхронизации накладок -- сосед пола по дому и по
# владельцу: конфликт рождается из пары «накладка оператора × определение
# апстрима», и в репозитории кита число отказывало бы на второй машине, где
# конфликтов нет. Дом тот же, по той же лестнице: объявление ездит вместе с
# домом. Отсутствие файла -- умолчание ноль и НЕ отказ: направление сравнения
# у этой двери обратное полу (зуб на превышение), и нулевое умолчание зуба
# не гасит.
TWEAKCC_EXPECTED_PROMPT_CONFLICTS="$TWEAKCC_HOME/catalyst-prompt-conflicts.txt"
# Канонный дом маркера, которым зонд пути сборки метит ОДОЛЖЕННЫЙ конфиг
# tweakcc на время прогона. Дом здесь, а не в зонде, по одной причине:
# конвейер подключает РОВНО ОДИН файл -- tools/tw-layer.sh, дом разбора вывода
# tweakcc, -- и значения оттуда не берёт; зонд же читать чужой файл умеет, он и
# извлекает.
#
# СТОЛБЕЦ 0 ОБЯЗАТЕЛЕН: зонд достаёт значение якорем `^TWEAKCC_PROBE_CFG_MARKER=`
# (tools/build-path-probe.sh), и отступ перед именем оставит его без маркера --
# зонд тогда отказывает кодом 2, а не молчит. Объявление держится на верхнем
# уровне, а не внутри ветки: константа кита не должна существовать только при
# входе в условие.
TWEAKCC_PROBE_CFG_MARKER='0.0.0-probe'
# Дайджест бэкапа, снятый там, где восстановление применимо; пусто -- не
# применимо. Объявлено здесь: под `set -u` пост-сверка читает его всегда.
TWEAKCC_RESTORE_PINNED=""
# Detection is unconditional -- including under `--only-ours`, which does not
# invoke tweakcc and so cannot cause the poisoning, but whose user is just as
# entitled to learn that a neighbour already did. Only the REPAIR needs a
# verified source, and only a real tweakcc run needs to abort.
if [[ -f "$TWEAKCC_BACKUP" ]] && grep -q -a -F "$OUR_MARKER" "$TWEAKCC_BACKUP"; then
  # "Free of OUR marker" is not "pristine". A `.orig` snapshotted from a binary
  # that had been through tweakcc's stage carries none of our bytes and every
  # one of theirs -- exactly the case claude_patch.py refuses to CREATE, and
  # promoting such a file into the backup would restore a patch while reporting
  # a removal. Nor is a copy of another build a valid restore for this one: ask
  # both for their version.
  BACKUP_OK=0
  # ПРИЧИНА непригодности близнеца ИЗМЕРЯЕТСЯ, а не перечисляется. Прежде отказ
  # ниже печатал список «missing, patched, tweakcc-staged, or another version»,
  # и какой из четырёх поводов сработал, человек угадывал сам. Хуже того, ПЯТЫЙ
  # повод в списке не значился вовсе: обе `--version` могут промолчать оттого,
  # что образ собран под ДРУГУЮ платформу, -- и такой прогон приезжал под чужим
  # именем «бэкап держит патч». Тот же класс, что #105: имя названо по первому
  # элементу списка, а не по замеру. Волна 48.
  BACKUP_WHY=""
  BACKUP_NOTE=""
  if [[ ! -f "$PRISTINE_SRC" ]]; then
    BACKUP_WHY="файла нет"
  elif grep -q -a -F "$OUR_MARKER" "$PRISTINE_SRC"; then
    BACKUP_WHY="в нём НАШ маркер -- это уже пропатченные байты, а не сток"
  elif grep -q -a -F 'tweakcc' "$PRISTINE_SRC"; then
    BACKUP_WHY="в нём следы tweakcc -- образ прошёл чужую стадию"
  else
    # `2>&1` вместо `2>/dev/null`: слова ребёнка -- единственный носитель
    # причины, и гасить их в замере запрещено.
    set +e
    SRC_OUT="$("$PRISTINE_SRC" --version 2>&1)"; SRC_RC=$?
    BLD_OUT="$("$BIN" --version 2>&1)"; BLD_RC=$?
    set -e
    # __first_word объявляет «код ВСЕГДА 0» (пояс || true в её теле): пусто --
    # законный ответ «не назвал», обе ветки -z ниже именно его разбирают.
    SRC_VER="$(__first_word "$SRC_OUT")" || true
    BLD_VER="$(__first_word "$BLD_OUT")" || true
    if [[ -z "$SRC_VER" ]]; then
      BACKUP_WHY="близнец не назвал свою версию (код $SRC_RC): ${SRC_OUT%%$'\n'*}"
      BACKUP_NOTE="$PRISTINE_SRC"
    elif [[ -z "$BLD_VER" ]]; then
      BACKUP_WHY="цель не назвала свою версию (код $BLD_RC): ${BLD_OUT%%$'\n'*}"
      BACKUP_NOTE="$BIN"
    elif [[ "$SRC_VER" != "$BLD_VER" ]]; then
      BACKUP_WHY="это ДРУГАЯ версия: близнец $SRC_VER, цель $BLD_VER"
    else
      BACKUP_OK=1
    fi
  fi
  if [[ $BACKUP_OK -eq 1 ]]; then
    # Staged and renamed, not written in place: a `cp` killed halfway leaves a
    # TRUNCATED backup, and truncated bytes contain no marker either -- so every
    # later run of this very check would read it as healthy while a restore
    # wrote a broken binary and reported success.
    # The message is INSIDE the success branch, and a failed repair is fatal.
    # `set -e` does not fire when an AND-OR list short-circuits on its first
    # command -- measured, not assumed: with `set -euo pipefail` and an
    # unwritable destination, `cp` failed, `mv` was skipped, and the script ran
    # on to exit 0. So the old shape printed "restored it from ..." over a
    # backup that still held the patch, and then built from those bytes.
    if cp -p "$PRISTINE_SRC" "$TWEAKCC_BACKUP.repair" \
       && mv "$TWEAKCC_BACKUP.repair" "$TWEAKCC_BACKUP"; then
      echo "NOTE: tweakcc's backup held a PATCHED image; restored it from $PRISTINE_SRC." >&2
      echo "      This build starts from those bytes, and 'tweakcc --restore' would" >&2
      echo "      have returned the patch until now." >&2
    else
      rm -f "$TWEAKCC_BACKUP.repair"
      echo "FATAL: tweakcc's backup ($TWEAKCC_BACKUP) holds a PATCHED image and the" >&2
      echo "       repair from $PRISTINE_SRC FAILED (no space, no permission?)." >&2
      echo "       Refusing to build: the build would start from patched bytes, and" >&2
      echo "       'tweakcc --restore' would keep handing out the patch." >&2
      exit 1
    fi
  else
    echo "FATAL: tweakcc's backup ($TWEAKCC_BACKUP) holds a PATCHED image, and no" >&2
    echo "  verified-pristine copy of THIS build is available to repair it from." >&2
    echo "  ИЗМЕРЕННАЯ ПРИЧИНА по $PRISTINE_SRC: $BACKUP_WHY" >&2
    if [[ -n "$BACKUP_NOTE" ]]; then
      __image_run_note "$BACKUP_NOTE"
    fi
    echo "  tweakcc restores that backup over the target before patching, so the" >&2
    echo "  build would be made FROM our own patched bytes -- and 'tweakcc" >&2
    echo "  --restore' would hand a human the patch while reporting a removal." >&2
    echo "  Fetch stock bytes for this version and try again:" >&2
    echo "    python3 claude_patch.py --download-only <version>" >&2
    [[ $ONLY_OURS -eq 1 ]] || exit 1
  fi
fi

# --- 2. tweakcc's own patches (restores from its backup first!) ---------------
# tweakcc takes no target argument -- оно само разрешает установку. Порядок
# приоритетов в его коде (src/installationDetection.ts:550-600 форка):
#   1. переменная окружения TWEAKCC_CC_INSTALLATION_PATH,
#   2. ccInstallationPath из конфига,
#   3. `claude` на PATH,
#   4. вшитые пути поиска.
# После --update разрешение по пунктам 3-4 попадает на ПРЕДЫДУЩУЮ версию:
# лаунчер намеренно ещё не переключён, и tweakcc молча патчит образ, который
# никто не запускает, пока наш остаётся нетронутым.
#
# Раньше цель прибивалась пунктом 2 -- правкой конфига человека. У этого было
# две беды, и обе исправляет пункт 1.
#
#   * Пункт 2 существовал ТОЛЬКО если конфиг уже есть: `if [[ -f "$TWEAKCC_CFG" ]]`.
#     Отсутствие конфига -- это и есть определение первого запуска, то есть
#     ровно того случая, ради которого прибивание написано. На чистой машине
#     прибивания не было, и разрешение уходило в пункты 3-4.
#   * Прибивание ПЕРЕЖИВАЛО наш прогон. После сборки по --target конфиг
#     человека оставался указывающим на нашу временную цель (скажем,
#     /tmp/cc-matrix/bin/242.wave.bin), и следующий его собственный запуск
#     tweakcc падал с "ccInstallationPath is set to '...' but file does not
#     exist" -- поломка, которую вносили мы, в файле, который не наш.
#
# Переменная окружения не имеет ни одной из этих привязок: она действует на
# наши вызовы и умирает вместе с процессом, а конфиг человека не трогается
# вовсе.
if [[ $ONLY_OURS -eq 0 ]]; then
  export TWEAKCC_CC_INSTALLATION_PATH="$BIN"
  echo "Pinned tweakcc to $BIN (TWEAKCC_CC_INSTALLATION_PATH)"
  # Цель названа оператором -- собрано может быть из ДРУГИХ байтов.
  #
  # tweakcc восстанавливает свой бэкап поверх цели до всякого патча (см.
  # заголовок секции). Ветка выше ловит только случай «в бэкапе НАШИ патчи»;
  # расхождение двух РАЗНЫХ стоковых образов одной версии она не видит, а
  # именно оно и наблюдалось: цель с одной изменённой строкой собралась в
  # образ БЕЗ этого изменения, все проверки зелёные, `Done.` напечатан.
  # Всё, что человек проверил на своей цели, к отгруженному образу тогда не
  # относится, и узнать об этом неоткуда.
  #
  # ПРЕДИКАТ БЕРЁТСЯ У ТОГО, ЧЬЁ ПОВЕДЕНИЕ ПРЕДСКАЗЫВАЕТСЯ. Первая редакция
  # спрашивала версию у ФАЙЛА бэкапа, а tweakcc решает по ЗАПИСИ
  # config.ccVersion (в форке: бэкап освежается из цели, когда
  # realVersion !== config.ccVersion, и только иначе восстанавливается).
  # Две модели давали два расхождения, оба воспроизведены: сброшенный
  # конфиг -- tweakcc пересоздал бы бэкап из цели, подмены нет, а страж
  # отказывал; запись совпадает, а ФАЙЛ бэкапа несёт другую версию --
  # подмена есть, а страж молчал.
  #
  # Версия ЦЕЛИ снимается так, чтобы падение не убивало прогон: под
  # `set -euo pipefail` присваивание из конвейера с неисполнимым файлом
  # завершает скрипт кодом 126 БЕЗ единого слова (замерено). Прежний
  # комментарий обещал здесь «пустую версию, а дальше страхует дым-гейт» --
  # не было ни того, ни другого: до проверки пустоты не доходило.
  #
  # Невозможность назвать версию цели -- ОТКАЗ, а не пропуск: на ней стоит
  # весь предикат, а образ уже прошёл image-check.py, то есть это валидный
  # нативный образ, который обязан отвечать на --version. Молчание здесь
  # означало бы «не знаю, что будет с байтами» -- ровно та тишина, против
  # которой страж и написан.
  #
  # Отказ, а не автопочинка: два образа одной версии разошлись, и какой из
  # них истина, знает только человек. Молча взять бэкап -- отгрузить не то,
  # что проверяли; молча продвинуть цель в бэкап -- подменить человеку точку
  # восстановления. Обе двери названы в сообщении.
  #
  # Цель с НАШИМ маркером сюда не входит: это штатная пересборка живого
  # образа, где бэкап и есть единственный пристинный источник, а
  # восстановление стока -- сам смысл стадии.
  if [[ -f "$TWEAKCC_BACKUP" ]] && ! grep -q -a -F "$OUR_MARKER" "$BIN"; then
    # Слова и код ребёнка ЗАХВАТЫВАЮТСЯ: «цель не называет свою версию» --
    # это СИМПТОМ, а не причина, и до волны 48 он печатался вместо неё. Причин
    # у пустой версии две разной природы: байты цели негодны ЛИБО ядро отказало
    # ещё до первого байта программы, потому что образ не для этой машины.
    set +e
    TGT_OUT="$("$BIN" --version 2>&1)"; TGT_RC=$?
    set -e
    # __first_word объявляет «код ВСЕГДА 0» (пояс || true в её теле): пусто --
    # законный ответ «не назвал», отказ ниже называет причину и код ребёнка.
    TGT_VER="$(__first_word "$TGT_OUT")" || true
    if [[ ! "$TGT_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
      echo "FATAL: the target does not name its version, so what tweakcc is about to" >&2
      echo "  do with it cannot be established." >&2
      echo "  target: $BIN" >&2
      echo "  --version gave: '${TGT_VER:-<nothing>}' (код $TGT_RC)" >&2
      if [[ -n "$TGT_OUT" ]]; then
        echo "  Сказано образом: ${TGT_OUT%%$'\n'*}" >&2
      fi
      __image_run_note "$BIN"
      echo "  tweakcc restores its backup over the target before patching, and whether" >&2
      echo "  it does depends on this version. Refusing to build blind: the image that" >&2
      echo "  would be shipped may not be the one you named." >&2
      exit 1
    fi
    # Пояс || true уже стоит ВНУТРИ подстановки: python ловит свои ошибки сам
    # и печатает пустую строку, пусто -- законное «ccVersion нет», сравнение
    # ниже читает именно его.
    CFG_VER="$(python3 -c 'import json,sys
try:
    v = json.load(open(sys.argv[1], encoding="utf-8")).get("ccVersion")
except Exception:
    v = None
print(v if isinstance(v, str) else "")' "$TWEAKCC_CFG" 2>/dev/null || true)" || true
    # --- killed-probe config marker guard --------------------------------------
    if [[ "$CFG_VER" == "$TWEAKCC_PROBE_CFG_MARKER" ]]; then
      if [[ "${CLAUDE_PATCH_PROBE_CFG_LOAN:-0}" == "1" ]]; then
        echo "Probe config marker guard: SKIPPED — caller declared the config loan as its own (CLAUDE_PATCH_PROBE_CFG_LOAN=1)"
      else
        echo "FATAL: tweakcc's config has ccVersion=$TWEAKCC_PROBE_CFG_MARKER, the" >&2
        echo "  build-path probe marker. Continuing would make tweakcc refresh its backup" >&2
        echo "  from the target and rewrite the human's return point: what" >&2
        echo "  'tweakcc --restore' hands back." >&2
        echo "  This marker has two possible meanings:" >&2
        echo "    * a previous probe died under SIGKILL; SIGKILL does not run the probe's" >&2
        echo "      trap, and its snapshots, if any, are under:" >&2
        echo "        ${TMPDIR:-/tmp}/cc-build-path-probe.*/config.json.snapshot" >&2
        echo "    * another build-path probe may be running now and borrowing this config." >&2
        echo "      Check for: bash .../tools/build-path-probe.sh" >&2
        echo "      If that process is alive, wait for it to finish; do not repair its loan." >&2
        echo "  Only you know which of the two is the truth:" >&2
        echo "    * for a dead predecessor, restore config.json.snapshot by hand, or write" >&2
        echo "      the real Claude Code version as ccVersion if you know it;" >&2
        echo "    * for a live probe, wait for it to finish and restore its own snapshot." >&2
        exit 1
      fi
    fi
    # --- end killed-probe config marker guard ----------------------------------
    if [[ "$CFG_VER" == "$TGT_VER" ]]; then
      # Восстановление ПРИМЕНИМО: освежать бэкап tweakcc не станет.
      if ! cmp -s "$BIN" "$TWEAKCC_BACKUP"; then
        echo "FATAL: the target and tweakcc's backup are DIFFERENT images, and tweakcc" >&2
        echo "  is about to restore the backup over the target." >&2
        echo "  target: $BIN (v$TGT_VER)" >&2
        echo "  backup: $TWEAKCC_BACKUP" >&2
        echo "  its config records ccVersion=$CFG_VER, which equals the target's version," >&2
        echo "  so the backup will NOT be refreshed -- the build would be made from the" >&2
        echo "  BACKUP's bytes, not from the ones you named. Anything you verified on the" >&2
        echo "  target would not describe the image that gets shipped. Only you know which" >&2
        echo "  of the two is the truth:" >&2
        echo "    * the target is:  cp -p '$BIN' '$TWEAKCC_BACKUP'" >&2
        echo "      (this also changes what 'tweakcc --restore' hands back)" >&2
        echo "    * the backup is:  cp -p '$TWEAKCC_BACKUP' <a copy> and --target that" >&2
        exit 1
      fi
      TWEAKCC_RESTORE_PINNED="$(shasum -a 256 "$TWEAKCC_BACKUP" | awk '{print $1}')" || { printf 'ПРИБОР НЕДОСТУПЕН: не снята контрольная сумма бэкапа tweakcc\n' >&2; exit 2; }
    fi
  fi
  # A non-zero --list-patches meant "skip the apply", silently and with every
  # byte of its output discarded. But that subcommand failing does not imply the
  # apply would fail: a tweakcc that cannot parse its config, or that dropped
  # this subcommand, still patches. Skipping the entire third-party stage
  # without saying why leaves a build carrying none of those patches and a
  # perfectly clean `Done.` -- the same silence the rest of this block exists to
  # end, one level up.
  TWEAKCC_LIST_OUT="$(mktemp)" || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный файл списка правок tweakcc\n' >&2; exit 2; }
  # Пустой путь mktemp уходит ниже в перенаправление и в rm -f.
  [ -n "$TWEAKCC_LIST_OUT" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь списка правок tweakcc пуст\n' >&2; exit 2; }
  if "${TWEAKCC[@]}" --list-patches >"$TWEAKCC_LIST_OUT" 2>&1; then
    rm -f "$TWEAKCC_LIST_OUT"
    echo "==> Applying tweakcc's configured patches"
    # A patch of tweakcc's that cannot find its site prints a ✗ row and marks
    # itself failed -- and then the CLI exits 0 anyway. Nothing downstream looks
    # at it either: none of our checks below cover tweakcc's own output. So a
    # patch could stop applying entirely and the build would still be declared
    # good, with the feature simply gone. That is the same silence the interface
    # gate exists to end, except the gate only sees a CRASH: a clean skip renders
    # the stock interface and passes it.
    #
    # Every patch in the config is there because it is wanted, so a ✗ is a
    # failure of the build. The escape hatch is for deliberately running against
    # a version where something is known not to apply yet.
    TWEAKCC_OUT="$(mktemp)" || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный файл вывода стадии tweakcc\n' >&2; exit 2; }
    # Пустой путь mktemp уходит ниже в tee, в разборщики и в rm -f.
    [ -n "$TWEAKCC_OUT" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь вывода стадии tweakcc пуст\n' >&2; exit 2; }
    set +e
    "${TWEAKCC[@]}" --apply -y --show-unchanged 2>&1 | tee "$TWEAKCC_OUT"
    TWEAKCC_RC=${PIPESTATUS[0]}
    set -e
    # Наша лестница разрешения дома и лестница распаковщика обязаны сойтись.
    # Он печатает, куда сохранил конфиг; если это не внутри дома, который
    # назвали мы, значит весь прогон читал и правил ДРУГОЙ дом -- страж бэкапа
    # сторожил не тот файл, а «изоляция» свипа не изолировала ничего. Дублировать
    # чужую лестницу без такой сверки -- это охват на словах.
    # Точка восстановления, УНИЧТОЖЕННАЯ чужим окном, восстанавливается здесь.
    #
    # startupCheck распаковщика при смене версии снимает бэкап (`unlink`) и
    # только потом кладёт новый. Прогон, убитый в этом окне, оставляет дом
    # ВОВСЕ БЕЗ бэкапа: `tweakcc --restore` человеку отвечать нечем, хотя живая
    # установка уже пропатчена (круг 21, E-2). Байты для восстановления у нас
    # есть и они проверены -- это $PRISTINE_SRC, из которого и строится сборка.
    #
    # Объявленный предел: если убит будет ЭТОТ прогон (SIGKILL до строки ниже),
    # дом останется без бэкапа до следующего прогона -- тот пересоздаст его
    # штатно, из пристинного staging-файла, на который смотрит ccInstallationPath.
    if [[ ! -f "$TWEAKCC_BACKUP" ]]; then
      if [[ -f "$PRISTINE_SRC" ]] \
         && ! grep -q -a -F "$OUR_MARKER" "$PRISTINE_SRC" \
         && ! grep -q -a -F 'tweakcc' "$PRISTINE_SRC"; then
        if cp -p "$PRISTINE_SRC" "$TWEAKCC_BACKUP.repair" \
           && mv "$TWEAKCC_BACKUP.repair" "$TWEAKCC_BACKUP"; then
          echo "NOTE: точки восстановления tweakcc не было -- восстановлена из $PRISTINE_SRC." >&2
          echo "      Так выглядит прогон, убитый в окне между снятием и записью бэкапа." >&2
        else
          rm -f "$TWEAKCC_BACKUP.repair"
          echo "ВНИМАНИЕ: точки восстановления tweakcc нет, и восстановить её не удалось" >&2
          echo "  ($TWEAKCC_BACKUP из $PRISTINE_SRC). 'tweakcc --restore' сейчас без бэкапа." >&2
        fi
      else
        echo "ВНИМАНИЕ: точки восстановления tweakcc нет, а пристинных байтов для неё" >&2
        echo "  на этой машине не нашлось ($PRISTINE_SRC). 'tweakcc --restore' без бэкапа." >&2
      fi
    fi
    __tw_saved=$(sed -n 's/^Configuration saved at: //p' "$TWEAKCC_OUT" | tail -1) || { printf 'ПРИБОР НЕДОСТУПЕН: не прочитан путь сохранённого конфига из вывода стадии\n' >&2; exit 2; }
    if [[ -n "$__tw_saved" && "$__tw_saved" != "$TWEAKCC_HOME/"* ]]; then
      echo "ОТКАЗ: распаковщик сохранил конфиг в $__tw_saved, а кит считает домом" >&2
      echo "  $TWEAKCC_HOME -- лестницы разрешения дома разошлись. Прогон читал и" >&2
      echo "  правил не тот дом; чинить лестницу, а не повторять прогон." >&2
      exit 2
    fi
    if [[ "${CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES:-0}" != "1" && $TWEAKCC_RC -ne 0 ]]; then
      # A non-zero exit means the whole stage died, so NONE of its patches
      # applied -- strictly worse than the single ✗ the branches below treat as
      # fatal, yet this branch used to print a note and let the build continue.
      # The note guessed "no config yet?", a case the no-result-rows branch below
      # already reports properly; the guess only served to make a crash look
      # routine. It hid a real one: handed a shell wrapper instead of an image,
      # tweakcc threw "No VERSION strings found", this branch waved it through,
      # and the run went on to fail in our patcher with a message that pointed
      # nowhere near the actual cause.
      echo "FATAL: tweakcc --apply exited $TWEAKCC_RC -- not one of its patches applied." >&2
      tail -n 20 "$TWEAKCC_OUT" | sed 's/^/  /' >&2
      # On a machine with no ~/.tweakcc yet this is the FIRST thing a human sees,
      # and the only exit it used to name was the hatch -- which builds without
      # that whole stage. Name the two real answers first, so the hatch stays
      # what it is: a deliberate choice, not the obvious way out.
      echo "  If this is a first run, tweakcc has no saved customizations yet:" >&2
      echo "    bash claude-patch-all.sh --configure   # pick its patches, save, quit" >&2
      echo "  To build only OUR patches and skip that stage on purpose:" >&2
      echo "    bash claude-patch-all.sh --only-ours" >&2
      echo "  To build anyway, with the stage failing: CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1" >&2
      rm -f "$TWEAKCC_OUT"
      exit 1
    elif [[ $TWEAKCC_RC -ne 0 ]]; then
      # Сюда приходит только прогон со ВЗВЕДЁННОЙ ручкой (ветка выше отказала
      # бы иначе): стадия умерла целиком, разбирать нечего, и двери слоя ниже
      # объявляют своё гашение сами.
      echo "NOTE: tweakcc --apply exited $TWEAKCC_RC; CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 is set, continuing with ours only." >&2
    else
      # ПРЕДБАННИК: якорь задаёт ОБЛАСТЬ обоим читателям ниже -- и сверке
      # непроходов, и дверям уровня и множества. Прежде он проверялся ВНУТРИ
      # двери уровня, то есть ПОСЛЕ сверки непроходов: на сменившемся якоре
      # область пуста, крестиков нет, и сверка посылала оператора снять
      # ДЕЙСТВУЮЩЕЕ объявление непрохода -- следствие вперёд причины.
      if ! __tw_check_anchor "$TWEAKCC_OUT"; then
        rm -f "$TWEAKCC_OUT"
        exit 1
      fi
      # Положительный контроль чтения: ни одной строки результата -- значит
      # вывод не разобран, и отсутствие ✗ ниже не доказывает ничего. Считает
      # НОСИТЕЛЬ разбора по всем пяти знакам обоих слоёв: сырой образец
      # `^    [✓✗] ` объявлял непрочитанным здоровый вывод версии, где всё
      # ○/⊘/≡ (ничего не легло и ничего не упало).
      if ! __tw_check_result_rows "$TWEAKCC_OUT"; then
        rm -f "$TWEAKCC_OUT"
        exit 1
      fi
      if [[ "${CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES:-0}" == "1" ]]; then
        # Ручка законна -- она для сборки против версии, где что-то заведомо не
        # ложится, -- но невидимой быть не должна. Имена берутся у носителя
        # разбора и по ОБОИМ слоям: сырой образец брал бы строки и вне области
        # якоря (предапплайный список плана), и вне известных секций.
        # __tw_failed_any_names не отказывает (пояс || true в её теле):
        # пусто -- «крестиков нет», проверка -n ниже именно это и читает.
        __tw_failed_rows="$(__tw_failed_any_names "$TWEAKCC_OUT")" || true
        if [[ -n "$__tw_failed_rows" ]] \
           || grep -q -a 'applied with some failures' "$TWEAKCC_OUT"; then
          echo "NOTE: CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 — these tweakcc patches did NOT apply:" >&2
          printf '%s\n' "$__tw_failed_rows" | LC_ALL=C sed -n '1,20s/^/  ✗ /p' >&2 || true
        fi
      fi
      # Сверка непроходов зовётся при ЛЮБОМ положении ручки: со взведённой она
      # печатает, не отказывая (гашение объявляет сама). Прежде вызов стоял
      # только на ветке с выключенной ручкой, и вход «ручка=1, крестиков нет,
      # объявленный непроход не случился» не печатал ничего.
      # Форма `if !` снята намеренно: у сверки ТРИ исхода, а не два. Код 2 --
      # отказ её прибора (не создан временный файл), и объявлять по нему
      # расхождение непроходов нельзя: расхождения никто не измерял. Код
      # прогона тоже обязан различаться, иначе вызывающая сторона конвейера
      # прочтёт отказ прибора как вердикт.
      __rec_rc=0
      __tw_reconcile_misses "$TWEAKCC_OUT" "$BIN" || __rec_rc=$?
      if (( __rec_rc == 2 )); then
        rm -f "$TWEAKCC_OUT"
        # Конкретную причину печатает МЕСТО отказа внутри функции: код 2 отдают
        # разные её ветки (временный файл, пустой путь, разность, чтение
        # объявлений), и названная здесь одна причина была бы ложью на всех
        # остальных путях. Здесь называется только стадия, где отказ случился.
        printf 'ПРИБОР НЕДОСТУПЕН: сверка непроходов tweakcc не выполнена -- отказ её прибора (причина выше)\n' >&2
        exit 2
      elif (( __rec_rc != 0 )); then
        rm -f "$TWEAKCC_OUT"
        exit 1
      fi
    fi
    # Дверь УРОВНЯ стоит вне цепочки выше: та ветвится по коду возврата стадии,
    # а проседание слоя случается при нулевом коде и без крестиков. Ветка со
    # слепой ручкой тоже проходит здесь -- гашение объявляется внутри функции.
    # Порядок ОБЯЗАТЕЛЕН: сперва уровень, потом множество выключенных. Причина
    # не в пропаже данных под версию (метрика попыток версионно-независима по
    # построению, и такой пропажи, двигающей набор ○, не бывает), а в ПЕРЕЕЗДЕ
    # РЕЕСТРА ФОРКА: правку переименовали -- срабатывают ОБЕ двери, и вторая
    # называет владельцем конфиг дома, то есть ЧУЖОГО. Первая называет реестр
    # одним числом, и её диагноз обязан быть первым.
    # Код двери доносится КАК ЕСТЬ: она отличает отказ (1) от «не измерено»
    # (2), и схлопывание в единицу стёрло бы разницу между сломанной версией и
    # неопубликованным снимком промтов. Форма с промежуточной переменной, а не
    # `$?` внутри `if ! ...`: там `$?` принадлежит ОТРИЦАНИЮ и всегда ноль.
    __tw_level_rc=0
    __tw_check_applied_level "$TWEAKCC_OUT" "$BIN" || __tw_level_rc=$?
    if (( __tw_level_rc != 0 )); then
      rm -f "$TWEAKCC_OUT"
      exit "$__tw_level_rc"
    fi
    # Форма `if !` снята по той же причине, что и у сверки непроходов: у двери
    # ТРИ исхода. Код 2 -- отказ её прибора (объявление не прочиталось), и
    # объявлять по нему дрейф множества выключенных правок нельзя: множество
    # никто не измерял. Код прогона обязан различаться, иначе вызывающая
    # сторона конвейера прочтёт отказ прибора как вердикт двери.
    __tw_off_rc=0
    __tw_check_off_set "$TWEAKCC_OUT" "$BIN" || __tw_off_rc=$?
    if (( __tw_off_rc != 0 )); then
      rm -f "$TWEAKCC_OUT"
      exit "$__tw_off_rc"
    fi
    # Дверь КОНФЛИКТОВ стоит ПОСЛЕДНЕЙ из дверей слоя: её предмет печатается
    # ДО якоря результатов (блок синхронизации), и любая из дверей выше,
    # отказав, оставляет вывод неразобранным раньше, чем конфликтам станет
    # что сравнивать. Слепая ручка и обвал слоя объявляют своё гашение сами --
    # внутри функции.
    # `if !` снят по причине двери выше: код 2 -- отказ прибора (объявление
    # конфликтов не прочиталось), и конфликта накладок он не утверждает.
    __tw_conf_rc=0
    __tw_check_prompt_conflicts "$TWEAKCC_OUT" "$BIN" || __tw_conf_rc=$?
    if (( __tw_conf_rc != 0 )); then
      rm -f "$TWEAKCC_OUT"
      exit "$__tw_conf_rc"
    fi
    rm -f "$TWEAKCC_OUT"
  else
    echo "FATAL: tweakcc could not list its patches, so its whole stage would be" >&2
    echo "       skipped and the build would carry none of them:" >&2
    tail -n 12 "$TWEAKCC_LIST_OUT" | sed 's/^/  /' >&2
    rm -f "$TWEAKCC_LIST_OUT"
    exit 1
  fi
fi

# The stage above began by restoring tweakcc's backup over the target. If our
# marker is in the result, that restore reintroduced a patched image behind 1b's
# back -- say so here, where the cause is still nameable, instead of letting our
# patcher fail three steps later with "site not found" for eleven locators and a
# diagnosis that points nowhere near the reason.
if [[ $ONLY_OURS -eq 0 ]] && grep -q -a -F "$OUR_MARKER" "$BIN"; then
  echo "FATAL: after tweakcc's stage the target already carries OUR patches." >&2
  echo "  Its --apply restores $TWEAKCC_BACKUP over the target first, so that" >&2
  echo "  backup is patched and step 1b did not catch it." >&2
  exit 1
fi

# А теперь встречный вопрос к тому же образу: легли ли на него патчи tweakcc.
#
# Гонка check/use по бэкапу.
#
# Страж выше проверяет бэкап ДО стадии, а читает его tweakcc ВНУТРИ неё.
# В это окно внешний писатель -- прямой запуск tweakcc, ручное копирование,
# синхронизация ~/.tweakcc -- может подменить файл, и сборка пойдёт из
# байтов, которых никто не видел; воспроизведено. Замок конвейера закрывает
# только НАШИ прогоны, чужому писателю он не указ.
#
# Предотвратить подмену нельзя, но можно не отгрузить её результат. Дайджест
# снят ровно там, где восстановление применимо (иначе tweakcc сам законно
# освежает бэкап из цели, и изменение файла ожидаемо), и сверяется здесь --
# до наших патчей, до подписи, задолго до переключения лаунчера.
if [[ -n "$TWEAKCC_RESTORE_PINNED" ]]; then
  NOW_DIGEST="$( { shasum -a 256 "$TWEAKCC_BACKUP" 2>/dev/null || true; } | awk '{print $1}')"
  if [[ "$NOW_DIGEST" != "$TWEAKCC_RESTORE_PINNED" ]]; then
    echo "FATAL: tweakcc's backup changed WHILE the tweakcc stage was running." >&2
    echo "  backup: $TWEAKCC_BACKUP" >&2
    echo "  checked: $TWEAKCC_RESTORE_PINNED" >&2
    echo "  now:     ${NOW_DIGEST:-<unreadable>}" >&2
    echo "  Its config's ccVersion equals the target's version, so this stage had no" >&2
    echo "  reason to refresh the backup -- somebody else wrote it. The bytes restored" >&2
    echo "  over the target are therefore NOT the ones checked before the stage." >&2
    echo "  Nothing has been installed. Re-run when no other tweakcc (or copy) is" >&2
    echo "  touching $TWEAKCC_HOME." >&2
    exit 1
  fi
fi

# Весь разбор выше читает то, что tweakcc НАПИСАЛ О СЕБЕ: код возврата, строки
# ✓/✗, фразу "applied with some failures". Это отчёт стороннего инструмента о
# файле, который выбрал он сам. Если он выбрал не тот файл (а до перехода на
# TWEAKCC_CC_INSTALLATION_PATH на чистой машине это было штатным исходом), все
# ✓ честны и все относятся к чужому образу -- к нашему не приложено ничего, и
# ни одна из 39 проверок конвейера ниже этого не заметит: они пинят наш
# текст, а его пишет наш патчер, работающий по --target.
#
# Поэтому landing проверяется на САМИХ БАЙТАХ цели, а не по чужому отчёту.
# Маркер измерен: в пристинном 2.1.247 строки "tweakcc" ноль вхождений, в
# собранном -- восемь.
if [[ $ONLY_OURS -eq 0 ]]; then
  TWEAKCC_LANDED=$(grep -c -a -F 'tweakcc' "$BIN" || true)
  case "$TWEAKCC_LANDED" in ''|*[!0-9]*) TWEAKCC_LANDED=0 ;; esac
  if [[ "$TWEAKCC_LANDED" -eq 0 ]]; then
    if [[ "${CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES:-0}" == "1" ]]; then
      echo "NOTE: в цели нет ни одного следа tweakcc; CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1, продолжаю." >&2
    else
      echo "FATAL: стадия tweakcc отчиталась успехом, но в цели нет её следов." >&2
      echo "  Цель: $BIN" >&2
      echo "  Значит она патчила ДРУГОЙ файл: свой выбор она делает сама," >&2
      echo "  а мы прибиваем его через TWEAKCC_CC_INSTALLATION_PATH -- проверьте," >&2
      echo "  что сборка распаковщика эту переменную знает (форк, пин в шапке)." >&2
      exit 1
    fi
  fi
fi

# --- 3. our patches, ALWAYS after tweakcc -------------------------------------
# Порядку подчинено только ПРИМЕНЕНИЕ; всё, что проверяет сам набор патчей
# (гейты разбора, формы, стенды, числа), спрошено выше -- до того, как tweakcc
# переписал хоть один байт.
echo "==> Applying our multi-provider patches"
"${TWEAKCC[@]}" adhoc-patch \
  --script "@$OUR_PATCH" \
  -p "$BIN" \
  --confirm-possible-dangerous-patch

# --- 3b. bytecode census of the modules our patches touched -------------------
# КОНСТРЕЙНТ: строго ПОСЛЕ применения наших правок (предмет измерения — их
# результат) и ДО подписи: подпись легитимирует байты, неподписанные ещё
# можно отбросить. Отказ роняет прогон, а не печатает предупреждение: с bun
# исполняется предкомпилированный байткод, и образ, где правка текста не
# исполняется, отгружать нельзя.
# КОНСТРЕЙНТ: сток называет КОНВЕЙЕР, а не стенд. Собственный поиск стенда
# знает лишь близнеца рядом с целью, а на пути `--target` цель патчится НА
# МЕСТЕ и близнеца рядом не существует (измерено 2026-09-15 на usbox:
# ~/ccpatch/w272b/img/target без `.orig`) — стенд отказал бы кодом 2 и ронял
# бы КАЖДЫЙ такой прогон. Второй дом стоковых байт — бэкап распаковщика
# (измерено там же: его sha256 совпал с пином стока 2.1.272 linux).
# КОНСТРЕЙНТ: бэкап принимается только той же версии, что и цель, и только
# без нашего маркера: дом tweakcc один на машину, и бэкап чужой сборки дал бы
# расхождение состава модулей — то есть ложный отказ прибора вместо находки.
# КОНСТРЕЙНТ: версия берётся ИЗ БАЙТОВ — подписи на этой стадии ещё нет, и
# запускать образ ради `--version` нельзя.
echo "==> Ценз байткода изменённых модулей"
# __ver_from_bytes объявляет «код ВСЕГДА 0» (пояс || true в её теле): пусто --
# законный ответ «в байтах нет отметки», отбор ниже идёт по ${__BC_VER:+}.
__BC_VER="$(__ver_from_bytes "$BIN")" || true
__BC_STOCK=""
if [[ -f "$PRISTINE_SRC" ]]; then
  __BC_STOCK="$PRISTINE_SRC"
# Присваивание в цепочке ниже -- операнд &&: его код проверяется самим
# оператором, а хелпер всегда 0 (пояс || true в его теле); пусто отбрасывается
# сравнением версий. Комментарий внутрь продолжения ставить нельзя.
elif [[ -f "$TWEAKCC_BACKUP" ]] \
     && ! grep -q -a -F "$OUR_MARKER" "$TWEAKCC_BACKUP" \
     && __bc_bk="$(__ver_from_bytes "$TWEAKCC_BACKUP")" \
     && [[ -n "$__BC_VER" && "$__bc_bk" == "$__BC_VER" ]]; then
  __BC_STOCK="$TWEAKCC_BACKUP"
fi
python3 "$HERE/tools/bytecode-census.py" --built "$BIN" \
  ${__BC_STOCK:+--stock "$__BC_STOCK"} \
  ${__BC_VER:+--version "$__BC_VER"} || exit 1

# --- 4. signature (must be last: both steps above sign ad-hoc) ---------------
# Ветвление по паре (ОС ОБРАЗА, ОС хозяина), а не по одному `uname`: подписать
# можно только образ своей ОС, и прежний вид спрашивал ХОЗЯИНА, выдавая ответ за
# свойство образа. Несовпадение -- ОБЪЯВЛЕННЫЙ пропуск с обеими сторонами в
# строке, не отказ и не тишина: чужой образ подписать нечем, и это не поломка.
# КОНСТРЕЙНТ: у пропуска ДВЕ разные причины, и одна строка на обе была бы
# ложью в объявлении. Чужая ОС -- подписать нечем; своя не-darwin -- подписи у
# образа нет вовсе. Прежняя редакция этой волны печатала первую причину и на
# linux/linux, где стороны СОВПАДАЮТ (поймано первым же прогоном конвейера).
__BIN_OS_ARCH="$(__image_os_arch "$BIN")" || exit 1
__BIN_OS="${__BIN_OS_ARCH%%-*}"
__HOST_PAIR="$(__host_os_arch)" || { printf 'ПРИБОР НЕДОСТУПЕН: пара платформ хозяина не измерена\n' >&2; exit 2; }
if [[ "$__BIN_OS" != "${__HOST_PAIR%%-*}" ]]; then
  echo "==> Подпись ПРОПУЩЕНА: образ ${__BIN_OS_ARCH}, машина ${__HOST_PAIR} -- подписать можно только образ своей ОС"
elif [[ "$__BIN_OS" == "darwin" ]]; then
  sign_macos_binary "$BIN" || exit 1
else
  echo "==> Подписи у образа ${__BIN_OS_ARCH} нет: на этой ОС её не восстанавливают"
fi

# --- 5. verify ---------------------------------------------------------------
echo "==> Verifying"
python3 - "$BIN" "$OUR_PATCH" <<'PY'
import os, re, sys
d = open(sys.argv[1], 'rb').read()
src = open(sys.argv[2], encoding='utf-8').read()
ID = rb'[A-Za-z_$][\w$]*'
# Широкий детектор чтения фича-флага -- глаза постусловия session memory (#341):
# голый идентификатор, возможно с `this.` или точечной цепочкой (`K.read(…)`,
# `this.getFeatureValueWithSource(…)`), литерал умолчания !0 ИЛИ !1. Постусловие
# обязано быть ШИРЕ локатора по построению: локатор режет только понятную ему
# форму, и зеркало локатора не различает «снято» и «переформовано».
FLAG_READ = re.compile(rb'(?:this\.)?' + ID + rb'(?:\.' + ID + rb')*\("tengu_[a-z0-9_]+",(?:!0|!1)\)')


def SWITCH(env, empty_off=True):
    """The typed on/off reader of one probe consumer, as a regexp.

    CONSTRAINT: one home for a shape that 5 checks read (docnum:subset -- a
    slice of the pipeline's checks, not any bench's declared count). Before this builder
    each of them carried its own hand-written copy, and the carrier split
    (CLAUDE_*_CARRIER=mod stands a splice down) updated only some of them: the
    stragglers went on pinning a form that exists in NO image, so they could not
    RISE -- the mirror of a check that cannot fall, and just as silent. A check
    that is red on every payload says nothing about any of them.

    Two parameters, because the shape genuinely has two variants and the
    difference is load-bearing: the judge and the watcher are OFF unless their
    variable is set, the form probe is ON unless it is turned off, so the form
    probe's reader lacks the `__s===""||` disjunct. That absence is what keeps
    the three readers from matching each other, and every caller relies on it.

    Третий гейт `__d` -- дверца CLAUDE_CODE_ENABLE_FUNCTION_HOOKS (моды в
    2.1.272+ выключены по умолчанию): читатель отдаёт splice-путь, если носитель
    не mod ЛИБО функция-хуки не включены (`__c!=="mod"||(__d!=="1"&&__d!=="true")`).
    Прежняя форма кончалась на `return __c!=="mod"` и не имела предмета ни в одном
    образе 2.1.276.
    """
    empty = rb'__s===""\|\|' if empty_off else rb''
    return (rb'\(\(\)=>\{let __s=String\(process\.env\.' + env + rb'\?\?""\)'
            rb'\.trim\(\)\.toLowerCase\(\);'
            rb'if\(' + empty + rb'__s==="0"\|\|__s==="false"\|\|__s==="off"\|\|__s==="no"\)'
            rb'return !1;'
            rb'let __c=String\(process\.env\.' + env + rb'_CARRIER\?\?""\)'
            rb'\.trim\(\)\.toLowerCase\(\);'
            rb'let __d=String\(process\.env\.CLAUDE_CODE_ENABLE_FUNCTION_HOOKS\?\?""\)'
            rb'\.trim\(\)\.toLowerCase\(\);'
            rb'return __c!=="mod"\|\|\(__d!=="1"&&__d!=="true"\)\}\)\(\)')


# Апстримовый отказ, который несёт ТОЛЬКО форма-фабрика инструмента диспатча:
# с 2.1.269 инструмент строит `create()`, чей внутренний `call` отказывает без
# движка, а тело запуска отдано этому движку ЗНАЧЕНИЕМ. Измерено на четырёх
# образах окна: 0 вхождений на 2.1.267/268 (форма метода), 4 на 2.1.269/270.
#
# CONSTRAINT: форма решает, чем связан `this` на месте врезки, и тем самым --
# можно ли судье вообще проверять имя инструмента в рантайме. На форме-фабрике
# `this` принадлежит движку, и такая проверка не страж, а отмена каждого
# диспатча. Этот читатель НЕЗАВИСИМ от того, как форму выбирает сам патч (он
# идёт от головы над якорем глубины): два пути к одному ответу, и сборка, где
# они расходятся, краснеет вместо тихого согласия с любой врезкой.




def _same_env_helper(d):
    # The two edited sites live megabytes apart, so sameness cannot be asserted
    # with one backreference: name the helper at the gate, then look for that
    # exact name at the override.
    m = re.search(rb'if\(!(' + ID + rb')\(process\.env\.CLAUDE_CODE_COORDINATOR_MODE\)\)return!1;', d)
    if not m:
        return False
    return bool(re.search(re.escape(m.group(1)) + rb'\(process\.env\.CLAUDE_CODE_COORDINATOR_FORCE\)', d))

def _env_overrides_resumed_mode(d):
    """Возобновление сессии подчиняется переменной окружения.

    Проверяется ГАРАНТИЯ, а не запись: в матчере режима, до сравнения с
    "coordinator", стоит выход по CLAUDE_CODE_COORDINATOR_FORCE, и истинность
    этой переменной понимается ТАК ЖЕ, как её понимает сам продукт.

    Две формы -- потому что связь имён поменялась. До 2.1.248 помощник разбора
    виден в том же модуле, и вставка зовёт его по имени; сверка `_same_env_helper`
    доказывает, что имя то же самое, что гейтит режим. С 2.1.248 бандл разложен
    на ESM-чанки, помощник живёт в чужом чанке и в модуль матчера не
    импортируется -- имя там не разрешилось бы, -- поэтому вставлено его же
    тело. Здесь оно сверяется с телом настоящего помощника из того же образа:
    сравнивается ВЕСЬ текст функции (без имени), а не только список истинных
    значений. Прежняя редакция сверяла один список -- вставка с тем же списком,
    но с потерянной веткой прошла бы зелёной.
    """
    call = re.search(rb'\{if\(!(' + ID + rb')\)return;'
                     rb'if\((' + ID + rb')\(process\.env\.CLAUDE_CODE_COORDINATOR_FORCE\)\)return;'
                     rb'let ' + ID + rb'=' + ID + rb'\(\),' + ID + rb'=\1==="coordinator";', d)
    if call:
        return _same_env_helper(d)

    # Вставка: то же тело, что у продукта, без имени, вызванное на переменной.
    # Скобки тела берутся ЦЕЛИКОМ (`(\{.{0,400}?\})` до закрывающей скобки
    # вызова), чтобы сравнивать текст, а не отдельные приметы.
    inline = re.search(rb'\{if\(!(' + ID + rb')\)return;'
                       rb'if\(\(function \((' + ID + rb')\)(\{.{0,400}?\})\)'
                       rb'\(process\.env\.CLAUDE_CODE_COORDINATOR_FORCE\)\)return;'
                       rb'let ' + ID + rb'=' + ID + rb'\(\),' + ID + rb'=\1==="coordinator";', d, re.S)
    if not inline:
        return False

    # Настоящий помощник образа: имя отбрасывается, сравнивается тело.
    helper = re.search(rb'function ' + ID + rb'\((' + ID + rb')\)(\{if\(!\1\)return!1;'
                       rb'if\(typeof \1==="boolean"\)return \1;'
                       rb'let (' + ID + rb')=String\(\1\)\.toLowerCase\(\)\.trim\(\);'
                       rb'return\[[^\]]{0,80}\]\.includes\(\3\)\})', d)
    if not helper:
        return False
    # Имя параметра у продукта и во вставке -- одно и то же (вставка сделана из
    # его текста), поэтому тела обязаны совпасть побайтно.
    return inline.group(2) == helper.group(1) and inline.group(3) == helper.group(2)




def _effort_binding_reaches_the_launch(d):
    """The effort name is declared by one edit and read by another.

    Patch 12 destructures `effort:__ccEffort` in the dispatch tool's parameter
    pattern, and reads it again at the launch-definition site -- a different
    splice, tens of kilobytes away. That only holds while both sites are in ONE
    function body: a name bound by a parameter list is invisible to a sibling
    function, and the failure would be a ReferenceError on every dispatch. It
    is the same shape that cost the watcher its journal line one scope over,
    and nothing asserted it here.

    Re-grounded 13.09. The previous form pinned two WRITTEN heads of the
    handler -- `async call(__ccIn` and `async call(X…){let __ccEffort=X.effort;`.
    Patch 12 no longer emits a separate statement (it binds inside the pattern
    the body already destructures), and since 2.1.269 the launch body is not a
    method at all, so both heads matched ZERO images of the window: the check
    could not RISE, which is the same as printing nothing. What is asserted now
    is the guarantee itself and nothing about the spelling of the head -- walk
    from the binding to the read and prove the scope never CLOSED in between.
    Nesting is allowed (a closure sees the name); leaving is not.

    Measured, not argued: string literals are blanked first, so a brace inside
    a message cannot close a scope that is still open.
    """
    binds = [mm.end() for mm in re.finditer(rb'effort:__ccEffort', d)]
    uses = [mm.start() for mm in re.finditer(rb'__ccRaw=typeof __ccEffort', d)]
    if len(binds) != 1 or len(uses) != 1 or binds[0] >= uses[0]:
        return False
    # Обход начинается ЗА закрывающей скобкой самого образца: связывание --
    # свойство в деструктурирующем образце, и его собственная `}` о видимости
    # не говорит ничего. Заведи апстрим вложенный образец ПОСЛЕ нашего
    # свойства -- обход стартует скобкой раньше и уйдёт в минус: красное, а не
    # молчаливое согласие.
    close = d.find(b'}', binds[0])
    if close < 0 or close >= uses[0]:
        return False
    region = d[close + 1:uses[0]]
    for pat in (rb'"(?:[^"\\\n]|\\.)*"', rb"'(?:[^'\\\n]|\\.)*'", rb'`(?:[^`\\]|\\.)*`'):
        region = re.sub(
            pat,
            lambda m: m.group(0)[:1] + b'.' * (len(m.group(0)) - 2) + m.group(0)[:1],
            region)
    depth = 0
    for c in region:
        ch = bytes([c])
        if ch == b'{':
            depth += 1
        elif ch == b'}':
            depth -= 1
            if depth < 0:
                return False
    return True







def _captured_names(src):
    # Names captured by a regex, and everything built from them.
    #
    # The spacing around `=` is NOT part of the thing being detected. Requiring
    # it made the whole check depend on a formatting habit: a single
    # `const x=m[1]` would drop that name from the set, and since the check ends
    # in `return not bad`, an empty set makes it green no matter how many bare
    # `${...}` sit in the templates. `\s*` costs nothing and removes a way for
    # the guarantee to evaporate silently.
    n = set(re.findall(r'const (\w+)\s*=\s*[^;\n]*\[\d+\]', src))
    for _ in range(3):
        for m in re.finditer(r'const (\w+)\s*=\s*(`[^`]*`)', src):
            if any(g in n for g in re.findall(r'\$\{(\w+)\}', m.group(2))):
                n.add(m.group(1))
    return n

def _escaped_interpolations(src):
    # A minified name can contain `$`: in 2.1.239 the session matcher is called
    # `$jS`. In a regex SOURCE `$` is the end-of-line anchor, so a name injected
    # bare never matches, and the locator fails not because the build changed
    # but because the minifier picked a different letter. In the REPLACEMENT
    # string the same `$` reads as a group reference and substitutes someone
    # else's capture — silently. The CLASS is checked: no captured name may
    # stand in a template or replacement without rxEsc/repEsc. On the pre-fix
    # source this catches 12 places.
    # ИМЕНА ВИДНЫ ПО ОБЛАСТИ, а не по всему файлу. Патч устроен как ряд
    # верхнеуровневых `step('N …', () => { … })`, и `const` внутри одного шага
    # невидим другому -- это разные стрелочные функции. Прежняя редакция
    # держала файл одним пространством имён, и однобуквенный локал правки 12
    # (`const t = mm[0]`) отравлял постороннее `${t}` в тексте ОТКАЗА правки 22:
    # ложная тревога на месте, где опасности нет вовсе. Ложная тревога здесь
    # громкая, а не тихая, но она требует правки исходника, которая ничего не
    # чинит -- то есть учит не доверять проверке.
    spans = []
    for mm0 in re.finditer(r"^step\('", src, re.M):
        nxt = re.search(r"^step\('", src[mm0.end():], re.M)
        spans.append((mm0.start(), mm0.end() + nxt.start() if nxt else len(src)))
    outside = src
    for a, b in reversed(spans):
        outside = outside[:a] + outside[b:]
    module_names = _captured_names(outside)
    span_names = [(a, b, _captured_names(src[a:b])) for a, b in spans]

    def visible(pos):
        """Captured names in scope at this position: module level plus one step."""
        for a, b, n in span_names:
            if a <= pos < b:
                return module_names | n
        return module_names

    bad = []

    # `.replace(pattern, replacement)` has TWO slots with OPPOSITE rules, and
    # conflating them is not conservative -- it is wrong in both directions.
    # In a LITERAL string pattern `$` is matched verbatim, so escaping it there
    # would make the search fail; in the replacement `$` is syntax, so NOT
    # escaping it substitutes someone else's capture. The old form flagged every
    # name near any `.replace(`, which demanded repEsc on a literal pattern --
    # a change that would have broken the very site it was pointing at.
    def args_at(pos):
        """Split the argument list starting at the '(' that follows pos."""
        k = src.index('(', pos)
        depth, out, cur, i2 = 0, [], [], k
        quote = None
        while i2 < len(src):
            ch = src[i2]
            if quote:
                if ch == '\\':
                    cur.append(src[i2:i2 + 2]); i2 += 2; continue
                if ch == quote:
                    quote = None
                cur.append(ch); i2 += 1; continue
            if ch in '\'"`':
                quote = ch; cur.append(ch); i2 += 1; continue
            if ch in '([{':
                depth += 1
                if depth == 1:
                    i2 += 1; continue
            elif ch in ')]}':
                depth -= 1
                if depth == 0:
                    out.append(''.join(cur)); return out
            elif ch == ',' and depth == 1:
                out.append(''.join(cur)); cur = []; i2 += 1; continue
            cur.append(ch); i2 += 1
        return out

    # Стрелка или `function` в слоте замены. У ФУНКЦИИ-заменителя нет
    # `$`-синтаксиса вовсе: подстановкой служит её возвращаемое значение, а
    # `$1`/`$&` внутри неё -- обычные символы. Прежняя редакция считала этот
    # слот опасным, и имя, подставленное в текст ОТКАЗА внутри колбэка,
    # читалось как живая ссылка на группу.
    FN = re.compile(r'\s*(?:function\b|(?:\([^()]*\)|[A-Za-z_$][\w$]*)\s*=>)')

    def slots(call_pos, kind):
        """Which argument slots of this call are dangerous for a bare name."""
        a = args_at(call_pos)
        if kind == 'regexp':          # new RegExp(source, flags)
            return a[:1]
        if not a:
            return []
        pat = a[0].lstrip()
        # A literal-string pattern is a verbatim search: safe slot.
        literal = pat[:1] in ('`', '"', "'")
        rep = a[1:2]
        if rep and FN.match(rep[0]):
            rep = []
        return rep if literal else (a[:1] + rep)

    for m in re.finditer(r'new RegExp\s*\(', src):
        for slot in slots(m.end() - 1, 'regexp'):
            bad += [x for x in visible(m.start()) if '${%s}' % x in slot]

    for m in re.finditer(r'\.replace\s*\(', src):
        for slot in slots(m.end() - 1, 'replace'):
            bad += [x for x in visible(m.start()) if '${%s}' % x in slot]

    return not bad

def _session_memory_ungated(d):
    """Both session-memory gates are gone, checked WITHOUT naming the flags.

    Patch step 7 matches these gates by shape rather than by flag name, so a
    check pinned to "tengu_passport_quail" would go green on a bundle whose
    renamed flag still gates extraction -- weaker than the step it verifies,
    which is the wrong way round for a check.

    The extraction gate is scoped to the entry point the anchor names: bundle
    wide this exact form has three instances on 2.1.246 (hawthorn_steeple and
    vscode_feedback_survey are unrelated), and inside the window it is unique.
    The extract-mode predicate shape is unique bundle wide, so it needs no
    scope.

    The postcondition is WIDER than the locator BY CONSTRUCTION (#341): a
    postcondition that merely mirrors the locator's one spelling cannot tell
    "removed" from "reshaped upstream" -- the locator finds nothing, the mirror
    finds nothing, and the run reads green while session memory stays off.
    Measured on the 2.1.276 census: of 110 flag guards inside `if(` the narrow
    spelling covers 17; the compound condition is upstream's DOMINANT idiom,
    not an exotic one. So both halves see the flag read through FLAG_READ
    (bare, dotted, or `this.`-prefixed reader; !0 or !1 default), and the
    window half walks every `if(` structurally instead of matching one shape.

    The predicate half is checked POSITIVELY: exactly one keep-tail function
    survives, and between its head and the tail there is no flag read AT ALL
    (the tail's own escape-hatch read is outside that slice by construction).
    Measured on pristine 2.1.272 / 273 / 2.1.277.orig: keep-tail functions 1,
    flag reads in the body 2 (guard + escape hatch); on the assembled 2.1.276:
    body reads 0, window guards 0.
    """
    anchor = b'querySource:"extract_memories",forkLabel:"extract_memories"'
    at = d.find(anchor)
    if at == -1:
        return False
    window = d[at:at + 8000]
    # Первая половина -- окно точки входа, структурный проход (#341): каждое
    # `if(` в окне получает условие по БАЛАНСУ скобок (не по [^)] -- условия
    # вложенные: стоковый входной гвард на 2.1.272+ сам составной,
    # `if(!Me&&!H("tengu_passport_quail",!1))`). Условие с чтением флага перед
    # return -- живой гвард ЛЮБОЙ формы. Непарное `if(` -- красная проверка,
    # а не «чисто»: молчащее «ничего не нашёл» здесь и был дефект. Баланс
    # считается по символам внутри `if(…)`: комментариев в минифицированном
    # условии нет, а единственный строковый литерал -- имя флага -- скобок
    # не содержит.
    p = window.find(b'if(')
    while p != -1:
        depth = 1
        k = p + 3
        cond_end = -1
        while k < len(window):
            c = window[k:k + 1]
            if c == b'(':
                depth += 1
            elif c == b')':
                depth -= 1
                if depth == 0:
                    cond_end = k
                    break
            k += 1
        if cond_end == -1:
            return False
        cond = window[p + 3:cond_end]
        if FLAG_READ.search(cond):
            s = cond_end + 1
            while s < len(window) and window[s:s + 1] in b' \t\n\r':
                s += 1
            if window[s:s + 6] == b'return':
                return False
        p = window.find(b'if(', p + 1)
    # Вторая половина -- предикат режима. Прежняя редакция требовала тело из
    # ОДНОГО return («forced») и отдельно искала гейтованную форму тем же
    # однострочным написанием. С 2.1.269 апстрим держит в этом теле ещё и
    # ранний возврат (`function X(){if(Y()!==null)return!0;return!Z()||…}`),
    # поэтому «forced» не совпадал НИКОГДА, а «gated» -- тем более: одна
    # половина не могла подняться, вторая не могла упасть, и обе печатались как
    # работающие. Утверждается ГАРАНТИЯ: хвост-«keep» на месте и единственный,
    # и между головой его функции и им НЕТ чтения флага ВООБЩЕ -- ни одной
    # формы из измеренного класса (составное условие, литерал !0, читатель
    # через точку). Ранние возвраты апстрима допускаются -- они не про наш
    # флаг, и правка 7 их не трогает. Чтение-лазейка самого хвоста лежит ВНЕ
    # среза по построению. Измерено на 2.1.267/268/269/270: форма «keep» --
    # ровно 1 вхождение на каждом, от головы до неё 15 (267) и 24 (270) байта.
    keeps = list(re.finditer(rb'return!' + ID + rb'\(\)\|\|' + ID
                             + rb'\("tengu_[a-z0-9_]+",!1\)\}', d))
    if len(keeps) != 1:
        return False
    at_keep = keeps[0].start()
    back = d[max(0, at_keep - 400):at_keep]
    heads = list(re.finditer(rb'function ' + ID + rb'\(\)\{', back))
    if not heads:
        return False
    body = back[heads[-1].end():]
    return not FLAG_READ.search(body)


def _stream_finalize_ok(d):
    """The exhaustion path must never finalize a half answer as a success.

    Which shape proves that depends on the build, because 2.1.246 added a
    recovery the earlier releases have no equivalent of:

      - no truncation marker in the image (233..242 in range): there is nothing
        downstream that could recover from the marker, so the yield is gone and
        the original error is thrown unconditionally.
      - marker present (246): the yield survives ONLY for the lane whose reader
        can act on it -- a non-interactive main-loop session, where the product
        suppresses the marker from the output and nudges the model to resume
        from the truncation. Every other lane still throws.

    Asserting only the first shape would fail the second, and asserting only
    "no marker is emitted" would pass a build where the yield came back
    unguarded, which is the stock half answer.
    """
    # The lane test is the reader's WHOLE classifier -- `repl_main_thread*` OR
    # `"sdk"`, both of which `kD()` maps to "main". Pinning only the prefix let a
    # guard that was a strict subset of the reader read as correct.
    cond = (rb'\((' + ID + rb')\.isNonInteractiveSession&&\(\1\.querySource\?\.startsWith\('
            rb'"repl_main_thread"\)\|\|\1\.querySource==="sdk"\)&&\([^()]{0,80}\)\)')
    # WHICH branch is decided by the finalize site knowing the field, not by the
    # bytes existing somewhere in the image. A build's string pool outlives the
    # code that read the string -- measured on step 24, where `root/sudo
    # privileges` still reads out of the pool after the branch was neutralised.
    # A marker that landed in the pool with no recovery would have sent this
    # check down the 246 branch, demanded a guarded yield that the 233-shaped
    # build has no reason to contain, and printed a form change as a lost
    # guarantee. Measured: exactly one `truncatedAfterOutput:` within 3000 bytes
    # of the finalize anchor on 246/247 (748 away), zero on 233/240/242/243/245,
    # pristine and patched alike.
    _fin = [mm.start() for mm in re.finditer(rb'tengu_streaming_partial_finalized', d)]
    _marker_at_the_site = any(
        _fin and min(abs(mm.start() - a) for a in _fin) <= 3000
        for mm in re.finditer(rb'truncatedAfterOutput:', d)
    )
    if not _marker_at_the_site:
        if re.search(rb',error:"server_error"\}\),' + ID + rb'!=="credited"', d):
            return False
        return bool(re.search(
            rb'tengu_streaming_partial_finalized.{0,240}?!=="credited"\)'
            + ID + rb'="credited",.{0,300}?;throw ' + ID + rb'\}'
            rb'throw ' + ID + rb'\("tengu_streaming_fallback_to_non_streaming"', d, re.S))
    # An UNGUARDED marker yield is the stock half answer -- check first, so a
    # build that merely kept the stock site cannot pass on the clauses below.
    if re.search(rb',yield ' + ID + rb'\(\{content:[^;]{0,1400}?,error:"server_error"', d):
        return False
    if not re.search(rb'tengu_streaming_partial_finalized.{0,240}?,' + cond + rb'\?yield ', d, re.S):
        return False
    if not re.search(rb';if\(!' + cond + rb'\)throw ' + ID + rb';break ' + ID + rb'\}throw '
                     + ID + rb'\("tengu_streaming_fallback_to_non_streaming"', d):
        return False
    return True


def _bypass_no_immunity(d):
    # The registry marks two circuit breakers immune to full-bypass mode:
    #   dangerousRemoval:    {bypassImmune:!0, classifierRouted:!0}
    #   isolatePeerMachines: {bypassImmune:!0, classifierRouted:!1}
    # Step 27 lifts ONLY the first. isolatePeerMachines keeps one machine's
    # session from acting on another through a peer channel; a session holding a
    # full-bypass key is exactly the session that should still stop there.
    #
    # Three facts, none of them leaning on a minified name. From 2.1.242 the
    # bundle is code-split ESM: the predicate exports under a chunk-local name
    # and every consumer imports it under a name of its own, so no single name
    # spans both sides and counting uses across the image proves nothing.
    #
    # Терминатор здесь -- НЕ ЧАСТЬ ГАРАНТИИ. До 2.1.252 выражение закрывало
    # цепочку `let` и кончалось `;`, на 2.1.257 апстрим дописал следом ещё одно
    # объявление, и тот же участок кончается `,`. Шаг 27 воспроизводит символ
    # образа дословно (иначе цепочка разорвалась бы), а проверка, пинившая
    # ровно `;`, объявила бы верную правку потерянной. Пунктуация допускается
    # любая из двух; всё, что проверка утверждает, -- какой предикат стоит на
    # месте и что стоковая форма ушла.
    # 1. The STOCK two-argument call must be gone in its exact shape.
    if re.search(rb'\?' + ID + rb'\(' + ID + rb'\.decisionReason,' + ID + rb'\):void 0[;,]', d):
        return False
    # 2. The narrowed predicate must stand in its place -- absence of the stock
    #    shape alone cannot tell "narrowed" from "branch deleted outright", and
    #    the second is what this check previously accepted.
    if not re.search(
        rb'\?' + ID + rb'\(' + ID + rb'\.decisionReason,\(__ccbr\)=>'
        rb'__ccbr\.circuitBreaker!=="dangerousRemoval"&&' + ID + rb'\(__ccbr\)\):void 0[;,]', d):
        return False
    # 3. The breaker the narrowing names must still exist, and the one whose
    #    immunity is deliberately kept must still be marked immune. A rename
    #    upstream would otherwise turn this step into a silent no-op (case 1) or
    #    silently drop the guard we chose to keep (case 2).
    if b'dangerousRemoval:{bypassImmune:!0' not in d:
        return False
    if b'isolatePeerMachines:{bypassImmune:!0' not in d:
        return False
    return len(re.findall(rb'\.decisionReason,', d)) >= 1


def _fork_drops_are_gone(d):
    """No value is discarded for being a fork, near the launch telemetry.

    The old form of this check listed three literal shapes the patch removes.
    Two of them stopped existing upstream at 2.1.242, and the third is searched
    FORWARD from `is_fork:` while the surviving drops sit before it -- so on
    pristine 2.1.242 and 2.1.246 the entry went green on an image where the
    patch had done nothing at all. A check that passes on an unpatched build is
    worth less than no check, because it reads as a proof.

    Stated the way the patch states it: within the radius the sweep is allowed
    to touch, `<fork>?void 0:` must not occur. That fails on all four pristine
    payloads (the sites are there) and passes only once they are cleared.

    Радиус здесь -- МОДУЛЬ якоря, ровно тот же, что у самой правки
    (`moduleSliceAround` в шаге 12), а не ±20000 байт вокруг него. Байтовое окно
    шире модуля: имя локально для чанка, поэтому `<та же буква>?void 0:` в
    СОСЕДНЕМ чанке -- другое связывание, которое шаг 12 законно не трогает, а
    проверка на нём краснела бы на верно собранном образе. Ложный отказ, не
    ложный зелёный, -- но проверка обязана мерить то же, что правка. На
    измеренном корпусе окно и модуль совпадают (на 2.1.248 все три вхождения
    лежат в пределах 1.2 КБ до якоря), так что правка ничего не ослабляет.
    """
    m = re.search(rb'is_fork:(' + ID + rb'),', d)
    if not m:
        return False
    fork = re.escape(m.group(1))
    lo = d.rfind(b'/*__tweakcc_module_boundary_', 0, m.start())
    hi = d.find(b'/*__tweakcc_module_boundary_', m.start())
    if lo < 0 and hi < 0:
        # Маркеров нет вовсе -- распаковщик их не расставил. Тогда модуля не
        # видно, и честнее вернуться к прежнему байтовому окну, чем молча
        # объявить модулем весь образ.
        lo, hi = max(0, m.start() - 20000), m.start() + 20000
    else:
        lo = lo if lo >= 0 else 0
        hi = hi if hi >= 0 else len(d)
    return not re.search(rb'(?<![\w$])' + fork + rb'\?void 0:', d[lo:hi])


def _fork_sweep_stayed_near_its_anchor(d):
    """The class sweep must not have roamed outside the launch site.

    This is a WITNESS, not the whole guarantee -- an image cannot prove what was
    not touched. It is the site that actually got hit: before the sweep was
    bounded, `moduleSliceAround` returned the whole bundle on the single-module
    builds (2.1.233 / 2.1.240), the fork flag on 2.1.233 minifies to `L`, and
    4.97 MB from the anchor

        M=await P(k?{kind:"skip"}:{kind:"default"},O||L?void 0:process.env.ANTHROPIC_VERTEX_PROJECT_ID)

    binds `L` to GOOGLE_APPLICATION_CREDENTIALS. The sweep removed `L?void 0:`
    from it and the build shipped 79/79 green with Vertex project resolution
    altered. The construct exists once on every payload in range, so its stock
    shape is a cheap, exact tripwire for the same class returning.
    """
    # Предмет ловушки апстрим переписал на 2.1.261: конструкции `<x>||<y>?void
    # 0:process.env.ANTHROPIC_VERTEX_PROJECT_ID` там нет ни одной (измерено на
    # пристинных образах: форма A -- ровно одна на 251..260, ноль на 261; форма
    # B -- ноль на 251..260, ровно одна на 261). Разрешение проекта стало
    # обычной функцией с цепочкой `||`, в которой нет `?void 0:` вовсе, так что
    # исходная опасность на этой форме не воспроизводима -- но ловушка обязана
    # ЗНАТЬ свой предмет, а не молчать. Отсутствие ОБЕИХ форм -- отказ: зуб,
    # переживший свою причину, зеленеет на чём угодно.
    forms = (len(re.findall(
                 rb'\|\|' + ID + rb'\?void 0:process\.env\.ANTHROPIC_VERTEX_PROJECT_ID', d)),
             len(re.findall(
                 rb'function ' + ID + rb'\(\)\{return ' + ID + rb'\.GCLOUD_PROJECT\|\|'
                 + ID + rb'\.GOOGLE_CLOUD_PROJECT\|\|' + ID + rb'\.gcloud_project\|\|'
                 + ID + rb'\.google_cloud_project\|\|' + ID
                 + rb'\.ANTHROPIC_VERTEX_PROJECT_ID\}', d)))
    return sorted(forms) == [0, 1]

def _routing_agrees_with_connection(d):
    """The destination and the connection options must name the same host.

    Step 1 sends `claude-*` to api.anthropic.com while every other id falls
    through to ANTHROPIC_BASE_URL. The same options bag also carries
    `fetchOptions`, and the builder behind it picks proxy-vs-direct from the URL
    it is handed:

        let o=_();                                          // HTTPS_PROXY etc.
        if(o){ if(e.url && m(e.url)) return {...r,...h()};   // NO_PROXY match
               return {...r, proxy:..., ...h()} }

    Computed from the provider URL (ANTHROPIC_BASE_URL for firstParty), that
    decision belongs to a host the request is not going to. Both halves are
    therefore checked TOGETHER, against the same captured model variable and the
    same literal: a build where only one of them survived a relocator is exactly
    the split this is written to forbid, and either half alone reads as success.
    """
    m = re.search(rb'baseURL:/\^claude/i\.test\((' + ID + rb')\)\?'
                  rb'"https://api\.anthropic\.com":void 0,', d)
    if not m:
        return False
    model = re.escape(m.group(1))
    return bool(re.search(
        rb'url:/\^claude/i\.test\(' + model + rb'\)\?"https://api\.anthropic\.com":'
        + ID + rb'\(' + ID + rb',' + model + rb',' + ID + rb'\)\}\)', d))

def _agent_model_schema_relaxed(d):
    """The agent tool's model field takes any string -- asserted so the check CAN fail.

    The previous form of this gate asserted the absence of the zod-v3 shape,
    `.enum(["sonnet","opus","haiku","fable"])`. Measured on every payload this
    pipeline supports -- 2.1.233, 240, 242, 246, 247 -- that shape occurs ZERO
    times, in the PRISTINE image as well as the patched one. The check therefore
    returned the same answer for an unpatched binary and a correct build: no
    discriminating power on any supported version, while the row it printed
    claimed the schema had been relaxed. A check that cannot fail is worse than
    no check, because it is counted.

    Since 2.1.224 the schema is emitted in the zod-v4 standalone-helper form,
    `model:<enum>(["sonnet","opus","haiku","fable"])` (exactly one occurrence on
    each supported payload), and step 3 rewrites it to `model:<str>()`, borrowing
    the builder from the sibling `subagent_type:<str>()` just above.

    Both halves are asserted, because either alone is passable:
      * the stock enum is gone -- true on a patched image, false on a pristine one;
      * the relaxed field uses the SAME builder as subagent_type -- false on a
        pristine image, and this is the half that catches a sibling capture which
        grabbed something other than the string builder. With only the negative
        half, that mis-capture patched and passed.
    """
    if b'.enum(["sonnet","opus","haiku","fable"])' in d:
        return False
    if re.search(rb'model:' + ID + rb'\(\["sonnet","opus","haiku","fable"\]\)', d):
        return False
    for mm in re.finditer(rb'subagent_type:(' + ID + rb')\(\)', d):
        if re.search(rb'model:' + re.escape(mm.group(1)) + rb'\(\)', d[mm.end():mm.end() + 800]):
            return True
    return False

def _every_launch_carries_effort(d):
    """Effort must reach the agent definition at EVERY launch, not only at ours.

    Step 12 attaches effort at the dispatch tool's launch, and it does so by
    replacing the FIRST match. There are two launch sites on every version in
    range (2.1.233, 240, 242, 246, 247): the dispatch tool's, and the resume of a
    parked agent. Leaving the second alone is correct -- upstream attaches effort
    there itself,
    `<opt>?.effort!==void 0?{...<def>,effort:<opt>.effort}:<def>` -- and patching
    it too would make a second source of truth for the same field.

    But that correctness rests on upstream behaviour that nothing checked. Drop
    their attachment in a later version and effort silently vanishes on resume,
    with every gate still green and the feature half working. This is the same
    class as anchoring a mechanism to a dispatcher COUNT: a thing upstream is
    free to change.

    So the guarantee is asserted rather than the authorship: each launch site
    carries effort by one route or the other. Our injection rewrites the
    definition expression in place, so a patched site no longer matches the plain
    identifier form; whatever still matches it must be covered by upstream's own.
    """
    if len(re.findall(rb'=\{agentDefinition:\(\(\(\)=>\{', d)) != 1:
        return False
    plain = list(re.finditer(rb'=\{agentDefinition:(' + ID + rb'),promptMessages:', d))
    if not plain:
        return False
    for m in plain:
        window = d[max(0, m.start() - 3000):m.start()]
        if not re.search(rb'(' + ID + rb')\?\.effort!==void 0\?\{\.\.\.(' + ID
                         + rb'),effort:\1\.effort\}:\2', window):
            return False
    return True





def _gateway_ids_are_undisguised(d):
    """Every gateway-model filter is followed by a map that RESTORES the id.

    The disguise is a prefix plus a reversal, so undoing it is
    `[...<x>.id.slice(18)].reverse().join("")`. Each of the three parts is load
    bearing; a map that keeps the entry untouched satisfies a check that only
    looks for the prefix.
    """
    undisguise = len(re.findall(
        rb'\.map\(\((' + ID + rb')\)=>\1\.id\.startsWith\("claude-fable-5-dd-"\)\?'
        rb'\{\.\.\.\1,id:\[\.\.\.\1\.id\.slice\(18\)\]\.reverse\(\)\.join\(""\)\}:\1\)', d))
    filters = len(re.findall(
        rb'\.filter\(\((' + ID + rb')\)=>/\(claude\|anthropic\)/i\.test\(\1\.id\)\)', d))
    return undisguise == filters > 0


def _chevron_colour_follows_state(d):
    """The chevron's colour is the themed colour when loading, a literal when not.

    Pinned to the chevron's own destructuring (`themeColor:<t>}=<props>,<c>=<t>??
    void 0`) rather than to the ternary's shape, so a restored stock chevron
    cannot be covered by an unrelated `color:X?Y:"z",dimColor:!1` elsewhere.
    """
    m = re.search(rb'color:(' + ID + rb')\?(' + ID + rb'):"[^"]*",dimColor:!1', d)
    if not m:
        return False
    colour = re.escape(m.group(2))
    head = d[max(0, m.start() - 900):m.start()]
    return bool(re.search(rb'themeColor:(' + ID + rb')\}=' + ID + rb',' + colour + rb'=\1\?\?void 0', head))


def _sudo_refusal_is_neutralised(d):
    """Both sites, by their neutralised structure.

    Absence of the stock phrase looks like the obvious test and is not available:
    the refusal text lives in the image's STRING POOL, not only in the code that
    reads it, so neutralising the branch leaves the sentence in the file forever
    (measured on every version -- `root/sudo privileges` is present in the pool of
    each patched image). Requiring its absence could therefore never pass.

    Каждый сторож гасится по СВОЕЙ структуре, и они разные: site A (guard опции
    обхода) -- тело в `void 0`; site B (стартовая инлайн-проверка) -- УСЛОВИЕ
    `process.getuid()===0` в `!1` (ложное условие делает охраняемый выход
    недостижимым, каким бы ни стало тело). На 2.1.276 site B несёт конъюнкт
    `&&!<x>.CLAUDE_CODE_BUBBLEWRAP` и тело `console.error`, а не `)void 0`:
    прежняя проверка ждала `)void 0` -- форму, которой у этого сайта нет.
    Требуются ОБЕ половины -- одна прошла бы зелено со вторым сторожем живым.
    """
    guarded = re.search(rb'if\(' + ID + rb'\.isRootOutsideDeliberateSandbox\(\)\)void 0', d)
    setup = re.search(rb'!1&&process\.env\.IS_SANDBOX!=="1"&&'
                      rb'!' + ID + rb'\.CLAUDE_CODE_BUBBLEWRAP\)', d)
    return bool(guarded and setup)


def _refusal_routes_read_the_config(d):
    """Шов таблицы маршрутов отказа читает конфиг -- и ключ кэша разбора
    есть ЗНАЧЕНИЕ переменной, а не факт первого чтения: образ сам
    перекладывает окружение по ходу процесса (настройки, тёплый перезапуск,
    env.set площадки плагинов), поэтому смена переменной обязана
    подхватываться, и проверка ниже остаётся гарантией того, что чтение
    вообще стоит в теле шва.

    Сток оставляет шов пустым (`function <seam>(){return}` отдаёт undefined
    на обеих дорожках отказа), поэтому одного наличия env-ключа где-то в
    образе мало: ключ обязан стоять в теле ТОЙ САМОЙ функции, которую зовут
    обе дорожки. Требование «ровно два `routesOverride:<name>()` с одним
    именем» -- вторая половина той же двери: дорожек две, имя одно, и любое
    расхождение значит, что правка легла не на свой сайт.

    Окно между открывающей скобкой и ключом -- класс `[^}]`, а не `.`: из
    тела функции нельзя выйти, не пройдя `}`, поэтому `[^}]{0,200}?`
    обязан остановиться у закрывающей скобки тела. Точка с re.S такой
    границы не знает -- проверка обещала бы «ключ в теле», а требовала бы
    «ключ в 200 байтах после открывающей скобки», и зеленела на образе, где
    шов остался пустым, а ключ лежит рядом за его телом.
    """
    calls = re.findall(rb'routesOverride:(' + ID + rb')\(\)', d)
    if len(calls) != 2 or len(set(calls)) != 1:
        return False
    seam = calls[0]
    return bool(re.search(rb'function ' + re.escape(seam) + rb'\(\)\{[^}]{0,200}?'
                          rb'CLAUDE_CODE_REFUSAL_FALLBACK_ROUTES', d, re.S))


def _find_downgrade_reader(d):
    """Уникальный читатель-понижатель `function <B>(<x>){return <A>(<x>)?<F>:<x>}`,
    чей `<F>` привязан к "claude-opus-4-8" -- вход ПО ПОВЕДЕНИЮ, как в шаге.

    2.1.276 сломал прежнюю связку «две `var`-константы + предикат рядом»: между
    ними вставлена посторонняя функция, а тело предиката выросло до трёх
    конъюнктов со сравнением модели внутри `.some()`. Предмет не двигался,
    двигался локатор -- поэтому вход через ЧИТАТЕЛЬ (одно поведение: «предикат
    держит ? константа понижения : вход»). Уникальность требуется над всем
    текстом: константа НЕ уникальна на 2.1.276 (по два связывания opus-4-8 и
    opus-5), читатель уникален; содержимое `<F>` затем опознаёт его как opus.
    Возвращает (B, x, A, F) либо None.
    """
    hits = list(re.finditer(
        rb'function (' + ID + rb')\((' + ID + rb')\)\{return (' + ID + rb')\(\2\)\?(' + ID + rb'):\2\}',
        d))
    if len(hits) != 1:
        return None
    m = hits[0]
    if not re.search(rb'(?<![\w$.])' + re.escape(m.group(4)) + rb'="claude-opus-4-8"', d):
        return None
    return m.group(1), m.group(2), m.group(3), m.group(4)


def _top_of_lineup_is_reachable(d):
    """Верх линейки достижим -- ПО РУЧКЕ, и пинятся ТРИ формы разом.

    Три -- это и есть гарантия волны: (1) читатель-понижатель опознан по
    поведению и содержимому (`<F>="claude-opus-4-8"`) -- на образе, где форма
    ослабла, зелень обещала бы несуществующее свойство (пол чувствительности);
    (2) исключение верха в find-предикате несёт опт-ин форму
    `!(<S>()===void 0&&<A>(<x>))` -- без таблицы равна стоковой `!<A>(<x>)`, с
    таблицей исключение снято; (3) тернар понижения цели несёт
    `<W>()?(<S>()===void 0?<B>(<x>.id):<x>.id):<L>(<x>.id)`. Один и тот же `<S>`
    обязан стоять в ОБОИХ опт-ин формах: ручка одна, два разных шва развязали
    бы половину механизма. `<A>` и `<B>` берутся из читателя, не по буквам.
    """
    r = _find_downgrade_reader(d)
    if not r:
        return False
    B, _x, A, _F = r
    optin = re.search(
        rb'!\((' + ID + rb')\(\)===void 0&&' + re.escape(A) + rb'\((' + ID + rb')\)\)',
        d)
    if not optin:
        return False
    seam = optin.group(1)
    return bool(re.search(
        rb'(' + ID + rb')\(\)\?\(' + re.escape(seam) + rb'\(\)===void 0\?'
        + re.escape(B) + rb'\((' + ID + rb')\.id\):\2\.id\):(' + ID + rb')\(\2\.id\)',
        d))


def _armed_model_keeps_its_downgrade(d):
    """Вооружённая модель сохраняет своё СТОКОВОЕ понижение -- шаг 28 его не
    снимает ни при каком значении ручки.

    Это ОТДЕЛЬНАЯ проверка, а не ещё один конъюнкт соседней: гарантия другая
    (соседняя держит опт-ин, эта -- сохранность защиты), а проверка,
    называющая несколько свойств сразу, неисправна по тому же правилу, что и
    код с несколькими действиями. Снятие этой защиты не ронило НИ ОДНУ из
    прежних проверок шага -- обе пинят только опт-ин формы.

    Проверяется структурное отношение: читатель-понижатель `<B>` (опознан по
    поведению и `<F>="claude-opus-4-8"`) применён к производителю вооружённой
    модели БЕЗ аргументов -- `<B>(<P>())`. Вызов без аргументов -- единственный
    измеримый различитель двух применений читателя: понижение НА ЦЕЛИ в тернаре
    получает `.id`, а производитель вооружённой модели -- функцию. Читатель
    уникален над всем текстом, поэтому чужое одноимённое связывание из другого
    чанка его местом не станет.
    """
    r = _find_downgrade_reader(d)
    if not r:
        return False
    B = r[0]
    return bool(re.search(rb'(?<![\w$])' + re.escape(B)
                          + rb'\((' + ID + rb')\(\)\)', d))


# Отказ мод-API по бюджету -- единственный дом имени потолка. Имя берётся ИЗ
# охраняемого сравнения, а не вписывается буквами: на 2.1.270 оно `BSe` на
# darwin и `eke` на linux (измерено), то есть вшитое имя промахнулось бы на
# второй платформе СЕГОДНЯ. Обе проверки ниже ловят имя одной и той же иглой,
# и потому не могут разъехаться между собой.
_MOD_BUDGET_REFUSAL = (
    rb'if\(\(' + ID + rb'\.get\((' + ID + rb')\)\?\?0\)\+' + ID + rb'>=(' + ID + rb')\)'
    rb'throw new ' + ID + rb'\(`\$\{\1\}: \$\.model\.complete: '
    rb"the session's model budget for this plugin is spent`\)"
)


def _mod_budget_ceiling_is_operator_set(d):
    """Потолок бюджета мод-API, который читает отказ, объявлен НАШЕЙ формой.

    Предмет -- не «в образе есть имя переменной окружения»: стоковый образ
    объявляет потолок числом, и ключ, лежащий где угодно ещё, о потолке не
    говорит ничего. Поэтому имя потолка захватывается из САМОГО сравнения,
    которое бросает отказ, и объявление требуется у ЗАХВАЧЕННОГО имени.

    Пинится тело нашей вставки целиком, включая обе ветки умолчания
    (`Infinity` при отсутствующем/пустом значении и при негодном числе) И
    ЛЕНИВУЮ ФОРМУ: `Symbol.toPrimitive` значит, что окружение читается на
    КАЖДОМ обращении, а не один раз при загрузке модуля. Это не украшение --
    шаг 28 уже платил за нетерпеливую форму ровно здесь: образ перекладывает
    своё окружение по ходу процесса, и прочитанное при загрузке значение к
    моменту сверки может быть чужим. Потеряй правка ленивость, ручка стала бы
    мёртвой для всех, кто ставит её не до старта, -- и никакая другая дверь
    этого не назвала бы.

    Это НЕ тот случай, за который платил корень #75: там пинилась форма записи
    АПСТРИМА, которая меняется без нашего ведома, здесь -- байты, которые
    пишет наш же шаг 29, и их расхождение с этой иглой означает ровно то, что
    игла обязана называть, -- правка легла не той формой.
    """
    site = re.search(_MOD_BUDGET_REFUSAL, d)
    if not site:
        return False
    cap = site.group(2)
    return bool(re.search(
        rb'var ' + re.escape(cap) + rb'=\{\[Symbol\.toPrimitive\]\(\)\{let (' + ID + rb')='
        rb'process\.env\.CLAUDE_CODE_MOD_MODEL_BUDGET;'
        rb'if\(\1===void 0\|\|\1===""\)return Infinity;'
        rb'let (' + ID + rb')=Number\(\1\);'
        rb'return Number\.isFinite\(\2\)&&\2>0\?\2:Infinity\}\};', d))


def _mod_budget_warning_derives_from_the_ceiling(d):
    """Порог предупреждения ВЫВЕДЕН из потолка, а не записан своим числом.

    Гарантия ОТДЕЛЬНАЯ от соседней и с другим предметом, поэтому и проверка
    отдельная. Шаг 29 снимает потолок, но в том же модуле живёт второе число
    -- порог, на котором образ печатает «N of M session tokens». Пока он
    получается умножением ПОТОЛКА на долю, снятый потолок гасит и его:
    `Infinity*0.8` = `Infinity`, и сообщение не выйдет никогда. Если апстрим
    однажды запишет этот порог собственной константой, потолка не станет, а
    сообщение о лимите останется -- продукт будет называть предел, которого
    больше нет. Своего отказа у этого нет ни в одном другом доме.

    Зелена на пристинном образе ПО ОПРЕДЕЛЕНИЮ: предмет -- стоковое свойство,
    на которое опирается наш шаг. Она объявлена в списке пола по этой причине.
    """
    site = re.search(_MOD_BUDGET_REFUSAL, d)
    if not site:
        return False
    cap = site.group(2)
    return bool(re.search(rb'var ' + ID + rb'=' + re.escape(cap) + rb'\*' + ID + rb';', d))


def _step29_witnesses_from_src(src):
    """Свидетели шага 29 извлекаются из исходника патча; копия в проверке запрещена."""
    m = re.search(
        r"step\('29 mod-API session model budget ceiling becomes operator-set'"
        r".*?const WITNESSES = \[(.*?)\];",
        src,
        re.S,
    )
    if not m:
        print('ОТКАЗ ПРИБОРА: якорь WITNESSES шага 29 пропал из исходника патча',
              file=sys.stderr)
        sys.exit(2)
    body = m.group(1)
    witnesses = [a or b for a, b in re.findall(
        r'"((?:[^"\\]|\\.)*)"|\'((?:[^\'\\]|\\.)*)\'', body)]
    if not witnesses:
        print('ОТКАЗ ПРИБОРА: WITNESSES шага 29 извлечён пустым', file=sys.stderr)
        sys.exit(2)
    return witnesses


def _read_inapplicable(path):
    """Дом декларации. Неразобранная строка и дубль пары -- отказ прибора."""
    if not os.path.isfile(path):
        print('ОТКАЗ ПРИБОРА: нет дома декларации неприменимости: ' + path,
              file=sys.stderr)
        sys.exit(2)
    rows = {}
    with open(path, encoding='utf-8') as fh:
        for n, line in enumerate(fh, 1):
            raw = line.rstrip('\n')
            if not raw.strip() or raw.lstrip().startswith('#'):
                continue
            parts = raw.split('\t')
            if len(parts) != 3 or not all(parts):
                print(f'ОТКАЗ ПРИБОРА: неразобранная строка {n} в {path}',
                      file=sys.stderr)
                sys.exit(2)
            key = (parts[0], parts[1])
            if key in rows:
                print(f'ОТКАЗ ПРИБОРА: две строки на пару {parts[0]} × {parts[1]} '
                      f'(строки {rows[key][0]} и {n})', file=sys.stderr)
                sys.exit(2)
            rows[key] = (n, parts[2])
    return rows


def _image_version(d):
    found = set(re.findall(rb'// Version: ([0-9]+\.[0-9]+\.[0-9]+)', d))
    if len(found) != 1:
        print('ОТКАЗ ПРИБОРА: версия в образе неоднозначна или отсутствует '
              f'(различных: {len(found)})', file=sys.stderr)
        sys.exit(2)
    return found.pop().decode()


_NOTE_FMT = "  [NOTE] {name}: {ver} step 29: {reason}"


def _step29_verdict(d, src):
    """Таблица исходов шага 29: note / proceed / fail."""
    _witnesses = _step29_witnesses_from_src(src)
    # CONSTRAINT: порог «предмета нет» -- ВСЕ свидетели мертвы. Один
    # переформулированный литерал не имеет права отключать проверку.
    _all_dead = all(w.encode('utf-8') not in d for w in _witnesses)
    ver = _image_version(d)
    # CONSTRAINT: вызов блока -- (образ, патч); дом декларации рядом с патчем,
    # версия читается из байтов образа, третьего argv нет.
    _inapplicable_rows = _read_inapplicable(
        os.path.join(os.path.dirname(os.path.abspath(sys.argv[2])),
                     'tools', 'our-patch-inapplicable.txt'))
    declared = _inapplicable_rows.get((ver, '29'))
    if _all_dead:
        if declared:
            return {'status': 'note', 'ver': ver, 'reason': declared[1]}
        ready = (ver + '\t29\t'
                 'апстрим удалил механизм бюджета мод-API '
                 '(все свидетели шага 29 мертвы); предмета правки в этой сборке нет')
        return {'status': 'fail', 'fail_kind': 'undeclared', 'ver': ver, 'ready': ready}
    if declared:
        return {'status': 'fail', 'fail_kind': 'stale', 'ver': ver, 'reason': declared[1]}
    return {'status': 'proceed'}


# Отказ мод-API по пределу maxTokens ОДНОГО вызова -- вторая дверь той комнаты
# и единственный дом имени предела. Имя предела берётся ИЗ сравнения внутри
# сторожа, не вписывается буквами. На 2.1.276 апстрим переписал форму: прежний
# «maxTokens must be an integer from 1 to N» (в пристине этой сборки 0 вхождений)
# сменился на «is past what <model> can produce in one reply», а сам предел из
# module-level `var` стал per-call `let M=Math.min(<model>.upperLimit,...)` в теле
# $.model.complete. group(1) -- аргумент maxTokens, group(2) -- имя предела.
_MOD_MAXTOKENS_REFUSAL = (
    rb'if\((' + ID + rb')!==void 0&&\1>(' + ID + rb')\)'
    rb'throw new ' + ID + rb'\(`\$\{' + ID + rb'\}: \$\.model\.complete: '
    rb'maxTokens \$\{\1\} is past what \$\{' + ID + rb'\} '
    rb'can produce in one reply \(\$\{\2\}\)`\)'
)


def _mod_maxtokens_ceiling_is_operator_set(d):
    """Предел maxTokens на ОДИН вызов объявлен НАШЕЙ формой.

    Имя предела захватывается из САМОГО сравнения, которое бросает отказ, --
    «в образе есть имя переменной окружения» о пределе не говорит ничего.

    На 2.1.276 предел -- per-call `let M=Math.min(<model>.upperLimit,IIFE)` в теле
    $.model.complete: `<model>` -- аргумент вызова, поэтому строка исполняется на
    КАЖДЫЙ вызов и IIFE перечитывает окружение каждый раз. Свежесть, ради которой
    на 2.1.270 нужна была ленивая `Symbol.toPrimitive`-форма (там предел был
    module-level `var`, замороженный на загрузке), здесь даётся самим per-call
    `let` нативно: и число в `s>M`, и строка в `(${M})` берут одно текущее
    значение. Пинится тело IIFE целиком, включая обе ветки умолчания на Infinity.
    """
    site = re.search(_MOD_MAXTOKENS_REFUSAL, d)
    if not site:
        return False
    lim = site.group(2)
    return bool(re.search(
        rb'let ' + re.escape(lim) + rb'=Math\.min\(' + ID + rb'\(' + ID + rb'\)\.upperLimit,'
        rb'\(\(\)=>\{let (' + ID + rb')=process\.env\.CLAUDE_CODE_MOD_MAX_TOKENS;'
        rb'if\(\1===void 0\|\|\1===""\)return Infinity;'
        rb'let (' + ID + rb')=Number\(\1\);'
        rb'return Number\.isFinite\(\2\)&&\2>0\?\2:Infinity\}\)\(\)\)', d))


def _mod_maxtokens_default_is_not_the_ceiling(d):
    """Умолчание maxTokens -- ОТДЕЛЬНАЯ константа, а не тот же предел.

    Гарантия отдельная и с другим предметом, поэтому и проверка отдельная.
    Рядом со сторожем стоит `(<arg>??<DEF>)` -- значение, которое получает мод,
    НЕ передавший maxTokens (256 на 2.1.270, имена `H0s` на darwin и `fOs` на
    linux). Пока это своя константа, снятие предела её не трогает: не передал
    -- получил 256, как и на стоке.

    Если апстрим когда-нибудь сведёт их в одно имя (`<arg>??<LIM>`), наш же
    шаг 30 превратит «мод не передал maxTokens» в запрос на Infinity токенов --
    вред, которого на стоке не было и который создаёт именно наша правка.
    Своего отказа у этого нет ни в одном другом доме, а молча он выглядел бы
    как ошибка провайдера, а не как наша.

    Зелена на пристинном образе ПО ОПРЕДЕЛЕНИЮ: предмет -- стоковое свойство,
    на которое опирается наш шаг. Она объявлена в списке пола по этой причине.
    """
    site = re.search(_MOD_MAXTOKENS_REFUSAL, d)
    if not site:
        return False
    arg, lim = site.group(1), site.group(2)
    # Окно берётся от сторожа вперёд: умолчание стоит в теле той же функции,
    # несколькими выражениями ниже. Окно, а не весь образ, -- чтобы `??` из
    # чужого чанка не ответил за этот.
    tail = d[site.end():site.end() + 900]
    use = re.search(rb'\(' + re.escape(arg) + rb'\?\?(' + ID + rb')\)', tail)
    if not use:
        return False
    return use.group(1) != lim


# --- шаг 31: три поля, которые мод-API терял -----------------------------
#
# Голова мод-API ПОСЛЕ нашей правки. Игла без вшитых минифицированных имён:
# на 2.1.270 darwin части зовутся `iMt/e/n/r/s/d/m/S`, на 2.1.268 linux --
# `hTt/e/n/r/o/d/p/_` (измерено), и обе платформы ловятся одной формой.
#
# ВАЖНО ПРО ФОРМУ ПРОВЕРОК НИЖЕ. Шаг 31 ДОПИСЫВАЕТ к якорю, а не переписывает
# его: новая строка НАЧИНАЕТСЯ со старой. Поэтому проверка вида «стоковой формы
# больше нет» здесь ВСЕГДА красна и не значит ничего -- измерено 2026-09-15 на
# собственном стенде шага. Все 3 проверки шага (docnum:subset -- счёт
# подмножества реестра, а не его размер) пинят НАЛИЧИЕ новой структуры.
# На 2.1.276 второй аргумент входа `{plugin,budget}` ушёл вместе с механизмом
# бюджета мод-API (тот же снос, что сделал шаг 29 неприменимым): сигнатура стала
# `({...,detail:__mcDetail},g,h)` c простыми параметрами. group(5) -- аргумент
# maxTokens -- сохраняет свой номер, на него опирается alias-проверка ниже.
_MOD_ENTRY_PATCHED = (
    rb'async function (' + ID + rb')\(\{model:(' + ID + rb'),prompt:(' + ID + rb'),system:(' + ID +
    rb'),maxTokens:(' + ID + rb'),effort:__mcEff,timeoutMs:__mcTmo,max_tokens:__mcAlias'
    rb',detail:__mcDetail\},' + ID + rb',' + ID + rb'\)\{'
)

# Вызов провайдера ПОСЛЕ правки, вместе с обоими пробросами. Окно от головы, а
# не весь образ: `querySource:"hook_prompt"` больше нигде не встречается, но
# привязка к голове держит проверку честной и тогда, когда апстрим заведёт
# второй такой вызов в другом чанке.
def _mod_entry_window(d, span=1400):
    site = re.search(_MOD_ENTRY_PATCHED, d)
    if not site:
        return None, None
    return site, d[site.end():site.end() + span]


def _mod_api_forwards_effort(d):
    """Эффорт мода доезжает до тела запроса как `reasoning_effort`.

    Предмет -- ПОТЕРЯ, а не потолок. Мод-API деструктурировал ровно
    `{model, prompt, system, maxTokens}`, и `effort` падал на пол молча.
    Измерено на живых записях судьи: на дороге сплайса, где эффорт уходит,
    первая ступень лестницы выносит 96% вердиктов; на мод-дороге, где он
    терялся, -- 15%, а последняя и самая дорогая ступень 69%.

    Пинятся ОБА конца одной иглой: приём поля в голове и его проброс в вызов.
    Половина правки хуже целой -- принятое и никуда не отданное поле выглядит
    как работающая ручка.

    Пустой эффорт обязан НЕ уезжать: `typeof ...==="string"&&...!==""` -- это
    не украшение, а разница между «эффорт не задан» и «задан пустым», которая
    у провайдера означает разные вещи.
    """
    site, win = _mod_entry_window(d)
    if not site:
        return False
    return bool(re.search(
        rb'\.\.\.typeof __mcEff==="string"&&__mcEff!==""&&'
        rb'\{extraBodyParams:\{reasoning_effort:__mcEff\}\},', win))


def _mod_api_forwards_timeout(d):
    """Таймаут мода доезжает до вызова SDK как `timeout`.

    Без этого на мод-дороге границы времени НЕТ ВООБЩЕ: замер 2026-09-15
    провисел на одном вызове 24 минуты, а в записях судьи лежит попытка на
    19 минут. Поле `timed_out` встречается только у носителя-сплайса, где
    таймаут делаем мы сами.

    Негодное значение (ноль, отрицательное, NaN, Infinity) означает ОТСУТСТВИЕ
    границы, а не границу в ноль: иначе мод, попросивший нечитаемое, получил бы
    вызов, обрываемый мгновенно. То же прочтение негодного, что у шагов 29 и 30.
    """
    site, win = _mod_entry_window(d)
    if not site:
        return False
    return bool(re.search(
        rb'\.\.\.Number\.isFinite\(__mcTmo\)&&__mcTmo>0&&\{timeout:__mcTmo\},', win))


def _mod_api_alias_is_resolved_before_the_guard(d):
    """Алиас `max_tokens` разрешается ДО сторожа предела, а не после.

    Порядок здесь -- сама гарантия, а не стиль. Сторож шага 30 проверяет
    переменную `maxTokens`; присвой алиас ПОСЛЕ него -- и значение, пришедшее
    под snake_case именем, проедет мимо проверки целиком: ни `Number.isInteger`,
    ни `<1`, ни операторский предел его не увидят. Проверка на наличие
    присваивания где-нибудь в функции такого разворота НЕ ловит, поэтому
    пинится соседство: присваивание стоит ВПЛОТНУЮ к открывающей скобке головы,
    то есть раньше любого другого выражения.

    Алиас нужен потому, что `max_tokens` -- имя, которое читает наш собственный
    сплайс на дороге патча; мод, написанный для той дороги, обязан работать и
    запущенный как мод. Документированное `maxTokens` при этом старше: присваивание
    срабатывает только когда оно не задано.
    """
    site, win = _mod_entry_window(d, 200)
    if not site:
        return False
    arg = site.group(5)
    return bool(re.match(
        rb'if\(' + re.escape(arg) + rb'===void 0&&__mcAlias!==void 0\)'
        + re.escape(arg) + rb'=__mcAlias;', win))


def _mod_api_returns_detail_on_request(d):
    """Причина пустого ответа доезжает до мода, когда он её ПРОСИТ.

    Предмет -- неразличимость, а не нехватка удобства. Мод-API отдаёт
    `xut(content,"")` -- склейку ТОЛЬКО текстовых блоков, поэтому «модель
    промолчала», «всё ушло в блоки размышления» и «ответ обрезан по
    max_tokens» приходят одной и той же пустой строкой, а `stop_reason`,
    типы блоков и `usage` лежат в том же объекте ответа и выбрасываются.
    Именно поэтому молчание нижних ступеней судьи не диагностировалось
    ничем (#153, #190).

    Пинятся ОБА конца одной иглой: приём флага в голове (он в
    `_MOD_ENTRY_PATCHED`, общем для всех проверок шага) и ветка возврата.
    Половина правки хуже целой: принятый и никуда не влияющий флаг
    выглядит как работающая ручка.

    УСЛОВНОСТЬ ветки -- сама гарантия, а не стиль: без флага возврат обязан
    остаться СТРОКОЙ. Мод, написанный против стоковой поверхности (наш и
    чужой), полагается в том числе на ЛОЖНОСТЬ пустой строки в `if (!answer)`;
    объект истинен всегда, и безусловный возврат объекта развернул бы такую
    ветку наизнанку молча.
    """
    site, win = _mod_entry_window(d)
    if not site:
        return False
    return bool(re.search(
        rb'__mcDetail===true\?\{text:(' + ID + rb'),stopReason:(' + ID + rb')\.stop_reason\?\?null,'
        rb'blocks:\(Array\.isArray\(\2\.content\)\?\2\.content:\[\]\)\.map\(', win))


def _cancellation_rule_is_whole(d):
    """The whole rule, not its first clause.

    Each pinned fragment is a separate instruction the main loop needs; any one
    of them can be dropped without touching the others, and the opening clause
    alone proves none of them.
    """
    # Волна 31 (K-3): перед arm стоит типизированный читатель выключателя
    # (инлайн-форма канонического __envon из ядра). 2026-09-12: тот же сайт
    # несёт CLAUDE_JUDGE_CARRIER=mod (splice stands down). Пин проходит по
    # читателю ЦЕЛИКОМ включая stand-down -- иначе ручка выпадёт, а правило
    # в промте останется, и два носителя снова судят вместе. Читатель берётся
    # из SWITCH() -- эта проверка держала СВОЮ копию и отстала от гейта
    # function-hooks (__d), из-за чего краснела на всём 2.1.276; теперь дом один.
    if not re.search(rb'\.\.\.\(' + SWITCH(b'CLAUDE_JUDGE') + rb'&&' + ID
                     + rb'\?\.agentContext\?\.agentType==="main"\?\['
                     rb'"A subagent dispatch may be reviewed before it runs\.', d):
        return False
    for clause in (b'treat that reason as a correction to apply',
                   b'Reissue the dispatch only with the change it names',
                   b'never repeat the identical call',
                   b'separate from the permission system'):
        if clause not in d:
            return False
    return True


def _statusline_throttle_raised(d):
    """The constant the debounce actually reads, in the debounce's OWN module.

    Minified names are chunk-local, so `var <name>=500` anywhere in the bundle
    is not evidence about this one: another chunk is free to bind the same
    letters to something unrelated. The step deliberately edits within the
    module; the check has to look there too, or a same-named constant elsewhere
    keeps it green while the status line is throttled at the stock value again.
    """
    m = re.search(rb'\.setTimeout\(\(\)=>\{this\.#' + ID + rb'=null,this\.#' + ID
                  + rb'\(\)\},(' + ID + rb')\)\}', d)
    if not m:
        return False
    # Маркеров границ модулей в УПАКОВАННОМ образе нет НИ ОДНОГО: они живут в
    # распакованных модулях, с которыми работает сам патчер, а проверка читает
    # `$BIN` (измерено 0 и на собранном 2.1.250, и на четырёх пристинных
    # корпусных). Прежняя форма молча падала в откат `module = d[0:len(d)]`,
    # то есть искала по ВСЕМУ образу -- ровно то сужение, ради которого
    # хелпер и писался, не работало никогда (круг 20, C-10). Окно вокруг
    # места использования -- то, что в упакованном образе измеримо: на живом
    # образе объявление лежит в 4.7 КБ до него.
    lo, hi = max(0, m.start() - 20000), min(len(d), m.start() + 20000)
    window = d[lo:hi]
    decls = re.findall(rb'var ' + re.escape(m.group(1)) + rb'=(\d+)', window)
    # Ровно одно связывание в окне: два -- значит, по имени уже не отличить,
    # какое из них читает дебаунс, и молчать об этом нельзя.
    return decls == [b'500']


def _dispatch_keeps_its_model(d):
    """The model chosen for a dispatch reaches the record the launch writes.

    The old half of this pair looked for `Date.now(),<v>=<f>()?void 0:` -- a shape
    with ZERO occurrences on 2.1.247, pristine as well as patched, so it could not
    become false and the name's promise rested entirely on the other half.

    The record's SHAPE is not stable across the range: `parentModel:` only exists
    from 2.1.242 (measured: absent on 233 and 240, where the value travels as
    `model:<v>??(...)` instead), so pinning that field would have made this check
    a 242+ check wearing a range-wide name. What is stable is the variable: it is
    initialised from the dispatch's model at the depth-check and appears as
    `model:<v>` within the launch function. Both ends are required, so dropping it
    at either one fails -- `void 0` cannot match the identifier pattern, and a
    record built with `model:void 0` no longer names the variable.
    """
    m = re.search(rb'Date\.now\(\),(' + ID + rb')=(' + ID + rb'),' + ID + rb'=' + ID
                  + rb'\(' + ID + rb'\.agentContext\)', d)
    if not m:
        # 2.1.248 переписал этот участок: `Date.now()` кончается точкой с
        # запятой, подавление стало отдельным `if` под переменной окружения, и
        # только потом идёт `let <v>=<model>,<n>=<f>(<ctx>.agentContext)`.
        # Проверяемая гарантия не изменилась -- переменная, из которой растёт
        # запись запуска, инициализируется моделью диспатча, -- поэтому вторая
        # форма даёт ту же пару «имя переменной + её появление как model:<v>».
        m = re.search(rb'Date\.now\(\);if\(' + ID + rb'\(\)&&' + ID
                      + rb'\.CLAUDE_CODE_COORDINATOR_FORCE_WORKER_INHERIT_MODEL\)(' + ID
                      + rb')=void 0;let (' + ID + rb')=\1,(?:' + ID + rb'=' + ID
                      + rb',)*' + ID + rb'=' + ID
                      + rb'\(' + ID + rb'\.agentContext\)', d)
        if not m:
            return False
        var = re.escape(m.group(2))
        return bool(re.search(rb'model:' + var + rb'(?![\w$.])', d[m.end():m.end() + 8000]))
    var = re.escape(m.group(1))
    # Bounded to the launch function: the names here are one letter long, so an
    # unbounded search would find someone else's `model:f` in another chunk.
    return bool(re.search(rb'model:' + var + rb'(?![\w$.])', d[m.end():m.end() + 8000]))


_probe_full = d

_S29 = _step29_verdict(_probe_full, src)

checks = {
    'routing (claude-* -> subscription)': _routing_agrees_with_connection(d),
    'patch source escapes every captured name': _escaped_interpolations(src),
    'full bypass keeps peer-machine immunity': _bypass_no_immunity(d),
    'agent model schema relaxed':         _agent_model_schema_relaxed(d),
    'each launch site carries effort by one route or the other':        _every_launch_carries_effort(d),
    # Две формы охранника (см. шаг 2): до 2.1.248 -- одна строка с ранним
    # `return`, с 2.1.248 -- цепочка промежуточных значений и блок. Гарантия в
    # обеих одна: первый конъюнкт погашен, ранний выход не срабатывает.
    'gateway discovery without token':    bool(
                                              re.search(rb'ANTHROPIC_AUTH_TOKEN,' + ID + rb'=' + ID + rb'\(\);if\(!1&&!', d)
                                              or re.search(rb'ANTHROPIC_AUTH_TOKEN,[^;]{0,240};if\(!1&&!' + ID + rb'\)\{', d)),
    # Two-sided: the stock branch must be gone AND the widened one must still
    # test the "inherit" sentinel. The negative alone passed a build where the
    # sentinel test had been dropped from the ternary -- `"inherit"` is truthy,
    # so it reached the model-name parser and produced a badge from a parse of
    # the sentinel.
    'subagent model badge':               not re.search(rb'else if\((' + ID + rb')\.model&&\1\.model!=="inherit"\)', d)
                                          and bool(re.search(
                                              rb',' + ID + rb'=(' + ID + rb')\.model&&\1\.model!=="inherit"\?'
                                              + ID + rb'\(\1\.model\):' + ID + rb';', d)),
    # The postcondition is that the chevron's colour is CONDITIONAL on the
    # loading state -- which colour is the user's config. Pinning "success"
    # made this check stricter than the step it verifies: step 6 became
    # colour-agnostic when tweakcc started writing this edit first, so setting
    # chevronIdleThemeColor to anything else would pass the step and fail here.
    # Anchored to the chevron itself, not to the shape of a ternary: `color:X?Y:"z"
    # ,dimColor:!1` occurs wherever someone writes one, so the stock chevron could
    # be restored and a lookalike elsewhere would keep this green.
    'input chevron colour':               _chevron_colour_follows_state(d),
    'session memory forced on':           _session_memory_ungated(d),
    # every override read must now be a merge: `{...X().additionalModelCostsCache,...X().customModelCosts}`
    'custom model costs':                 len(re.findall(rb'\{\.\.\.' + ID + rb'\(\)\.additionalModelCostsCache,\.\.\.' + ID + rb'\(\)\.customModelCosts\}', d))
                                          == len(re.findall(ID + rb'\(\)\.additionalModelCostsCache', d)) > 0,
    # every gateway-model filter must be followed by the de-disguise map
    # ...and the map must actually UNDO the disguise. Counting maps that merely
    # mention the prefix accepts `?h:h` and accepts dropping `.reverse()`: the
    # gateway id stays masked, the filter above still reads as patched, and the
    # feature is gone with the gate green. The transformation is what the step
    # promises, so the transformation is what is pinned.
    'gateway model de-disguise':          _gateway_ids_are_undisguised(d),
    # One site, two lookups (raw id, then canonical name), read through a
    # guarded local at the HEAD of the function. Counting `().customModelContext
    # Windows?.[` was satisfied by the old tail placement, where four earlier
    # returns shadowed the override, and by an unguarded config read that throws
    # before the config settles -- so it proved neither of the things that matter.
    # The prelude must stand at the head of the context-window function ITSELF,
    # which is proved by what FOLLOWS it: the first of the three `return 1e6`
    # arms, testing the same identifier the lookup keys on. Without that tail the
    # check accepted the prelude after any `{` -- including one below the arms it
    # exists to outrank, which is the placement the step was written to fix.
    'per-model context window':           bool(re.search(
                                              rb'\{let __ccw;try\{__ccw=' + ID + rb'\(\)\.customModelContextWindows\}catch\{\}'
                                              rb'let __ccv=__ccw\?\.\[(' + ID + rb')\]\?\?__ccw\?\.\['
                                              + ID + rb'\(' + ID + rb'\(\1\)\)\];'
                                              rb'if\(typeof __ccv==="number"&&__ccv>0\)return __ccv;'
                                              rb'if\(' + ID + rb'\(\1\)\)return 1e6;', d))
                                          and not re.search(rb'\?\?' + ID + rb'\(\)\.customModelContextWindows', d),
    # the expired-login bail must be reachable only for the subscription lane,
    # and the proxy lane that now survives it must null both auth headers or
    # the SDK rejects the request itself
    'proxy lane survives expired login':  bool(re.search(
                                              rb'\{if\(!\(!/\^claude/i\.test\(' + ID + rb'\)&&process\.env\.ANTHROPIC_BASE_URL\)\)'
                                              rb'throw new ' + ID + rb';\}if\(', d))
                                          and bool(re.search(
                                              rb'&&!/\^claude/i\.test\(' + ID + rb'\)&&process\.env\.ANTHROPIC_BASE_URL\)'
                                              + ID + rb'\.Authorization=null,' + ID + rb'\["X-Api-Key"\]=null;', d)),
    # Обе половины про одно: значение модели доезжает до записи запуска.
    # ВАЖНО, что именно пинится на каждой записи бандла. До 2.1.248 подавление
    # было безусловным, и шаг 12 его вырезал -- половина модели краснеет на
    # пристинном образе. С 2.1.248 апстрим сам сделал подавление env-условным
    # (`if(<предикат>()&&<ns>.CLAUDE_CODE_COORDINATOR_FORCE_WORKER_INHERIT_MODEL)`),
    # мы его НЕ трогаем, и на новой записи эта половина -- пин чужой ветки: она
    # одинаково истинна и до, и после наших правок. Красноту на пристинном
    # образе там держит вторая половина, снос fork-ветки. Формулировка «никакой
    # путь не отбрасывает модель» была верна для старой записи и лгала для новой,
    # где env-путь отбрасывания обязан остаться на месте.
    'dispatch keeps its model': _dispatch_keeps_its_model(d) and _fork_drops_are_gone(d),
    'Vertex project resolution intact (fork-sweep tripwire)':  _fork_sweep_stayed_near_its_anchor(d),
    # effort must be DECLARED (schema), CARRIED (call handler) and USED (spliced
    # into the definition the runtime reads) — declaring it alone would satisfy
    # a routing gate while the request still went at the vendor default
    # The model-supplied effort must be DECLARED (schema), CARRIED (destructured
    # once in the call handler) and VALIDATED before it reaches the definition.
    # Counting two `effort:__ccEffort` passed the version that attached the raw
    # string straight through, which is the defect: an unvalidated model-supplied
    # value reaching an internal effort layer. Now the only bare use is the
    # destructure, and the attach site must normalise the product's own aliases
    # and drop anything outside its vocabulary. The trim/case-fold is pinned
    # too: without it the check went green on a normaliser stricter than every
    # other surface of the product, where a dropped effort is silent.
    # ДВЕ формы привязки, по форме подписи обработчика: поле в образце
    # параметров (<=2.1.259) либо отдельный оператор в теле (2.1.260+).
    # Ровно одна из них обязана встретиться ровно один раз.
    'dispatch carries effort':            (len(re.findall(rb'effort:__ccEffort', d))
                                           + len(re.findall(rb'let __ccEffort=' + ID + rb'\.effort;', d))) == 1
                                          and bool(re.search(
                                              rb'=\{agentDefinition:\(\(\(\)=>\{let __ccRaw=typeof __ccEffort==="string"'
                                              rb'\?__ccEffort\.trim\(\)\.toLowerCase\(\):__ccEffort;'
                                              rb'let __ccLvl=__ccRaw==="med"\?"medium":'
                                              rb'__ccRaw==="ultracode"\?"xhigh":__ccRaw;return __ccLvl&&'
                                              rb'\["low","medium","high","xhigh","max"\]\.includes\(__ccLvl\)\?'
                                              rb'\{\.\.\.(' + ID + rb'),effort:__ccLvl\}:\1\}\)\(\)\),promptMessages:', d))
                                          and bool(re.search(rb'dispatch_class:' + ID + rb'\(\)\.optional\(\)', d)),
    # coordinator mode must be reachable interactively via its own opt-in (never
    # by borrowing CLAUDE_CODE_REMOTE, which also moves the auth token), and it
    # must no longer be the thing that disables fork — that would undo #12 for
    # anyone who turns the mode on
    # the switch must be parsed by the SAME helper that parses the variable
    # already gating this function — same identifier in both calls
    'interactive coordinator mode':       bool(re.search(
                                              rb'if\(!(' + ID + rb')\(process\.env\.CLAUDE_CODE_COORDINATOR_MODE\)\)return!1;'
                                              rb'if\(' + ID + rb'\(\)&&!' + ID + rb'\(\)&&!' + ID + rb'\.CLAUDE_CODE_REMOTE'
                                              rb'&&!\1\(process\.env\.CLAUDE_CODE_COORDINATOR_INTERACTIVE\)\)return!1;', d))
                                          # neither resolver shape may still gate fork on the mode
                                          and not re.search(
                                              rb'let ' + ID + rb'=' + ID + rb'\(\);if\(' + ID + rb'\(\)\)return"disabled";'
                                              rb'if\(' + ID + rb'\.CLAUDE_CODE_FORK_SUBAGENT===!1\)', d)
                                          and not re.search(
                                              rb'\{if\(' + ID + rb'\(\)\)return"disabled";'
                                              rb'if\(' + ID + rb'\.CLAUDE_CODE_FORK_SUBAGENT===!0\)return"env";', d),
    # a resumed session must not be able to drag the process out of the mode the
    # environment asked for; the bail sits before the first read of the live
    # predicate, so nothing is flipped and no warning is produced
    'env overrides resumed mode':         _env_overrides_resumed_mode(d),
    # a row must carry what was actually spawned: the agent type and the model,
    # the latter falling back to the agent definition when the dispatch did not
    # override it (the normal case for the pinned vendor agents)
    'agent row shows type and model':     bool(re.search(
                                              rb'=\[(' + ID + rb')\.agentType,\1\.model\?\?\1\.selectedAgent\?\.model,'
                                              rb'.{0,80}?\]\.filter\(Boolean\)\.join\(" \\xB7 "\)', d, re.S)),
    # a search must be able to reach sessions the picker has not paged in yet:
    # while the search UI is open the page request fires unconditionally, and
    # the growth signal comes from the LOADED list (the filtered one stops
    # growing as soon as a page contains no match, which is the deadlock)
    # two shapes, because 2.1.242 rewrote the effect: upstream added the loaded
    # length to the dependencies (closing the deadlock the same way) and then
    # capped the scan with a give-up counter, which the patch now steps over
    # while the search UI is open
    'resume search pages in the tail': (bool(re.search(
                                              rb'if\((' + ID + rb')==="search"\|\|(' + ID + rb')\+(' + ID + rb')>='
                                              rb'(' + ID + rb')\.length\)(' + ID + rb')\((' + ID + rb')\*3\)\},'
                                              rb'\[\2,\6,\4\.length,\5,\1,(' + ID + rb')\.length\]\),\7\.length===0', d))
                                          # exactly one, not "either": both shapes present
                                          # means one is dead and the live UI may be running
                                          # a third the check has never seen
                                          + bool(re.search(
                                              rb'if\((' + ID + rb')==="search"\|\|\((' + ID + rb')\+(' + ID + rb')>='
                                              rb'(' + ID + rb')\.length&&(' + ID + rb')\.current\.empty<' + ID + rb'\)\)'
                                              rb'\5\.current\.empty\+\+,(' + ID + rb')\((' + ID + rb')\*3\)\},'
                                              rb'\[\2,\7,\4\.length,(' + ID + rb'),\6,\1\]\),' + ID + rb'\.length===0', d))) == 1,
    # a NAMED dispatch becomes an in-process teammate, whose record is built
    # from a different literal than a plain local agent; the agent type has to
    # reach it through the spawn directive or the row shows only the model
    'named agent carries its type': bool(re.search(
                                              rb'planModeRequired:(' + ID + rb')\?\?!1,model:(' + ID + rb'),'
                                              rb'agentType:(' + ID + rb')\};', d))
                                          and bool(re.search(
                                              rb'type:"in_process_teammate",status:"running",identity:' + ID + rb','
                                              rb'prompt:(' + ID + rb')\.description\?\?' + ID + rb',model:' + ID + rb','
                                              rb'agentType:\1\.agentType,', d)),
    # a stream that dies after content arrived must be retried like any other
    # request and must never leave a truncated answer behind reported as a
    # success: budgets raised to 300, the shared backoff on the wait, and the
    # exhaustion path throws instead of emitting "…may be incomplete"
    'broken stream retried, not halved': bool(re.search(
                                              # 2.1.245 inserts two more declarations right after
                                              # `{value:0}`; the tail run still identifies the two
                                              # counters this patch raises
                                              rb'=3,' + ID + rb'=\{value:0\},(?:' + ID + rb'=[^,;]{1,24},){0,8}'
                                              rb'' + ID + rb'=300,' + ID + rb'=0,'
                                              rb'' + ID + rb'=0,' + ID + rb'=!1,' + ID + rb'=300,' + ID + rb'=0,', d))
                                          and bool(re.search(
                                              rb'if\((' + ID + rb')=null,!(' + ID + rb')\)await (' + ID + rb')\('
                                              rb'(' + ID + rb')\((' + ID + rb')\),(' + ID + rb')\);continue ', d))
                                          and bool(re.search(
                                              rb'&&' + ID + rb'===null&&' + ID + rb'<Math\.max\(' + ID + rb',300\)\)\{', d))
                                          # the content-gate that blocked retry after a real block is gone
                                          and bool(re.search(
                                              rb'if\(' + ID + rb'===null&&\(' + ID + rb'\?' + ID + rb'<' + ID + rb':'
                                              rb'' + ID + rb'<' + ID + rb'\)\)\{', d))
                                          and not re.search(
                                              rb'if\(!' + ID + rb'&&' + ID + rb'===null&&\(' + ID + rb'\?'
                                              rb'' + ID + rb'<' + ID + rb':' + ID + rb'<' + ID + rb'\)\)\{', d)
                                          # the exhaustion path, whichever shape this build calls for
                                          and _stream_finalize_ok(d),
    # a session that ran on a proxy model must come back on it: the stock
    # verdict chain classifies every non-first-party id as unknown_family
    'session model restore keeps a proxy model': bool(re.search(
                                              rb'let ' + ID + rb'=process\.env\.ANTHROPIC_BASE_URL&&'
                                              rb'!/\^claude/i\.test\(' + ID + rb'\)\?void 0:'
                                              rb'!\(' + ID + rb'\.has\(', d)),
    'effort binding reaches the launch': _effort_binding_reaches_the_launch(d),
    # the main loop is told the RULE, not the judge: a cancelled dispatch was
    # once read as the routing gate firing and blindly retried
    # The opening of the sentence is not the rule. Truncate it after "may be
    # reviewed." and the gate stays green while the part that carries the
    # instruction -- reissue only with the named change, never repeat the
    # identical call, this is not the permission system -- is gone. The clauses
    # that make it actionable are pinned individually.
    'dispatch-cancellation rule reaches the main loop': _cancellation_rule_is_whole(d),
    # Step 12 also rewrites what the schema TELLS the model about a fork's model
    # override; stock says the override is ignored, which is false once the code
    # honours it. Nothing measured that, so restoring the stock sentence left all
    # gates green and the model reading the opposite of how the tool behaves.
    'fork model override is documented as working': bool(re.search(
                                              rb'For subagent_type: "fork" it selects the model the fork '
                                              rb'runs on', d))
                                          and not re.search(rb'forks always inherit the parent model', d),
    # ported from tweakcc, whose own patch set cannot apply on this build
    # a bare 'var X=500' matches six unrelated constants in the PRISTINE binary,
    # so the check has to reach the debounce site first and then assert on the
    # constant that site actually names
    # The escaping note the old form carried still holds and now lives inside
    # the helper; what it could not do is keep the search inside the module the
    # step edits.
    'statusline throttle raised': _statusline_throttle_raised(d),
    # One-sided: the exact stock phrase is gone. Rewrite the refusal in any other
    # words and it stays green while the refusal is alive again. The positive
    # half asserts what should be there instead -- the guard evaluating to
    # `void 0` -- and the step's own second anchor (the bare phrase) is checked
    # too, so a reworded upstream cannot pass unnoticed.
    'root/sudo refusal neutralised': _sudo_refusal_is_neutralised(d),
    # step 28: both site-B halves are OPT-IN -- with the handle set the
    # mapped refusal target stops being downgraded to the family default and
    # the top of the lineup stops being excluded from the fallback walk;
    # with the handle unset (or the table rejected) the image behaves
    # exactly like stock. The downgrade predicate itself and the armed
    # model's own downgrade stay STOCK on purpose (the step header says why
    # each half must), and the third record below guards exactly that
    # preservation. Every record here has a mutation that reddens it: the
    # armed-model record rides the constants mutation's second door,
    # declared in that row, so none may quietly become unfailable.
    'refusal fallback routes come from the config': _refusal_routes_read_the_config(d),
    'top of the lineup is a reachable fallback': _top_of_lineup_is_reachable(d),
    'the armed model keeps its stock downgrade': _armed_model_keeps_its_downgrade(d),
    # step 29: the mod-API per-process model budget. Stock refuses every
    # `$.model.complete` call once a plugin has spent its ceiling, and the
    # counter lives in PROCESS memory -- the judge, the idle watch and every
    # other mod sharing that process go dark together until the user restarts,
    # which is exactly what a whole fan of dispatches was cancelled by on
    # 2026-09-14. With the handle unset the ceiling is Infinity, so no limit
    # exists; the second record guards the premise that keeps the derived
    # warning silent with it.
    'the mod-API model budget ceiling is operator-set': (
        'note' if _S29['status'] == 'note' else
        False if _S29['status'] == 'fail' else
        _mod_budget_ceiling_is_operator_set(d)),
    'the mod-API budget warning derives from that ceiling': (
        'note' if _S29['status'] == 'note' else
        False if _S29['status'] == 'fail' else
        _mod_budget_warning_derives_from_the_ceiling(d)),
    # The SECOND door of the same room. Lifting only the process budget leaves
    # a mechanism that may call the model forever but never get a reply longer
    # than 8192 tokens, and the judge's own recorded attempts ask for 24000 --
    # so the first record is what makes the fan work at all, and the second
    # guards the premise our edit depends on: the value a mod gets by NOT
    # passing maxTokens must stay a constant of its own, or lifting the
    # ceiling would silently turn that default into Infinity.
    'the mod-API per-call maxTokens ceiling is operator-set': _mod_maxtokens_ceiling_is_operator_set(d),
    'the mod-API per-call maxTokens default is not the ceiling': _mod_maxtokens_default_is_not_the_ceiling(d),
    # Третья дверь той же комнаты, и предмет у неё другой: не ПОТОЛОК, а ПОТЕРЯ.
    # Мод-API принимал ровно `{model, prompt, system, maxTokens}` и молча ронял
    # `effort`, `timeoutMs` и snake_case `max_tokens` -- все три судья шлёт.
    # Цена измерена на его же записях: на дороге сплайса первая ступень лестницы
    # выносит 96% вердиктов, на мод-дороге -- 15%, а последняя и самая дорогая
    # 69%. Ниже по течению всё нужное уже принималось (`timeout`, `extraBodyParams`),
    # так что правка сквозная; проверки стерегут оба её конца и ПОРЯДОК, в
    # котором алиас встречается со сторожем предела.
    'the mod-API forwards a per-call effort': _mod_api_forwards_effort(d),
    'the mod-API forwards a per-call timeout': _mod_api_forwards_timeout(d),
    'the mod-API token alias is resolved before the ceiling guard':
        _mod_api_alias_is_resolved_before_the_guard(d),
    'the mod-API returns the cause of an empty answer on request':
        _mod_api_returns_detail_on_request(d),
}
# The count is an invariant, not a running total. `all({}.values())` is True,
# so a merge that drops the dictionary -- or a block of it -- leaves a green
# build with nothing behind it. And an unpinned count is a number people get
# wrong: the author of these lines twice recounted the keys with a regex that
# breaks on the escaped apostrophe inside `current turn is the judge\'s alone`,
# reported 88, and was corrected by the run itself printing 89 — historical:
# both are what was miscounted then, not a count of anything now.
EXPECTED_CHECKS = 39
if len(checks) != EXPECTED_CHECKS:
    print(f"  [FAIL] the check registry holds {len(checks)} entries, expected "
          f"{EXPECTED_CHECKS} — checks were added or lost without updating the count")
    sys.exit(1)
for name, ok in checks.items():
    if ok == 'note':
        print(_NOTE_FMT.format(name=name, ver=_S29['ver'], reason=_S29['reason']))
    else:
        print(f"  [{'OK' if ok else 'FAIL'}] {name}")
if _S29.get('fail_kind') == 'undeclared':
    print('объявить неприменимость:')
    print(_S29['ready'])
elif _S29.get('fail_kind') == 'stale':
    print(f"декларация неприменимости пережила причину: {_S29['ver']} step 29")
sys.exit(0 if all(checks.values()) else 1)
PY

# --- 5a0. пол проверок: что остаётся зелёным на ПРИСТИННОМ образе -------------
# Круг 28, F-12: фраза стояла «все 114 сошлись» (docnum:historical) при
# ТОГДАШНЕМ EXPECTED_CHECKS = 118 (docnum:historical) в девяти строках выше -- существительное было
# элидировано, и гейт чисел не видел расхождения ПО УСТРОЙСТВУ (пару «число +
# существительное» не из чего было строить). Число починено, существительное
# и владелец названы явно.
# Реестр выше говорит, что все 39 проверок конвейера сошлись НА СОБРАННОМ
# образе. Он ничего не
# говорит о проверке, которая сошлась бы и без наших патчей -- а такая
# неотличима от работающей ровно до того дня, когда её свойство потеряют. Одна
# такая прожила в реестре неизвестно сколько: порог полосы BOM стоял `>= 2`,
# при том что стоковые образы несут этот приём 3-4 раза сами.
#
# Пристинный близнец есть не всегда: на `--update` это `<версия>.orig`, свип
# называет свой корпусный образ ручкой. Когда его нет, гейт объявляет пропуск и
# не делает вид, что измерил.
FLOOR_IMG=""
if [[ -f "$PRISTINE_SRC" ]]; then
  FLOOR_IMG="$PRISTINE_SRC"
elif [[ -n "${CLAUDE_PATCH_FLOOR_IMAGE:-}" && -f "${CLAUDE_PATCH_FLOOR_IMAGE:-}" ]]; then
  FLOOR_IMG="$CLAUDE_PATCH_FLOOR_IMAGE"
  echo "Пол проверок меряется на образе из CLAUDE_PATCH_FLOOR_IMAGE: $FLOOR_IMG"
fi
if [[ -n "$FLOOR_IMG" ]]; then
  echo "==> Пол проверок на пристинном образе"
  bash "$HERE/tools/checks-on-image.sh" --floor "$FLOOR_IMG" "$OUR_PATCH" 9>&- || {
    __rc=$?
    case $__rc in
      2) echo "FATAL: пол проверок НЕ ИЗМЕРЕН: прибор вызван неверно, якорь пропал" >&2
         echo "  либо блок проверок оказался пустым -- измерения не было" >&2
         exit 2 ;;
      6) echo "FATAL: пол проверок НЕ ИЗМЕРЕН: сломано окружение прибора (rc=6)" >&2
         exit 6 ;;
      *) echo "FATAL: пол проверок не сошёлся -- см. выше" >&2
         exit 1 ;;
    esac
  }
elif [[ $DO_UPDATE -eq 1 ]]; then
  # На пути --update пристинный близнец кладёт САМ установщик, поэтому его
  # отсутствие -- не «нечего мерить», а пропавший гейт. Прежде эта ветка молча
  # печатала строку и прогон ехал дальше; ровно так пол не измерился на переходе
  # 2.1.257, и заметить это можно было только вычитыванием лога.
  echo "FATAL: пол проверок НЕ ИЗМЕРЕН: пристинного близнеца нет ($PRISTINE_SRC)" >&2
  echo "  На пути --update его кладёт установщик рядом со сборкой, значит либо" >&2
  echo "  имя разъехалось с тем, что он пишет, либо файл удалили между шагами." >&2
  exit 6
else
  echo "==> Пол проверок ПРОПУЩЕН: пристинного близнеца нет ($PRISTINE_SRC)"
fi

# A pattern check proves the injected BYTES are present; it does not prove the
# bundle still PARSES. One mis-escaped newline inside an injected string literal
# left every check green while the image died on "SyntaxError: Unexpected EOF"
# (measured 2026-08-20). So run the image and require a real version line — and
# capture the status separately: `echo "$(... | head -1)"` throws the exit code
# away and reports a dead binary as a success.
set +e
SMOKE_OUT="$("$BIN" --version 2>&1)"
SMOKE_RC=$?
set -e
echo "Version: $(printf '%s\n' "$SMOKE_OUT" | head -1)"
if [[ $SMOKE_RC -ne 0 || "$SMOKE_OUT" != *"Claude Code"* ]]; then
  echo "FATAL: the patched image does not run — leaving the launcher alone" >&2
  # «Не запускается» -- это НАБЛЮДЕНИЕ, и оно одинаково выглядит у сломанной
  # вклейки и у образа чужой платформы. Второму никакая правка вклейки не
  # поможет, поэтому пара платформ называется здесь, а не додумывается потом.
  echo "  код $SMOKE_RC; сказано образом: ${SMOKE_OUT%%$'\n'*}" >&2
  __image_run_note "$BIN"
  exit 1
fi

# --- 5a2. the interface must actually come up ---------------------------------
# `--version` never executes a single React render. A patch that emits a name
# which is not in scope where it lands passes every byte check AND the version
# smoke, then kills the product the moment the interface is drawn: 2.1.246
# shipped that way twice in one morning ("l0 is not defined", then "sR is not
# defined"), each time with 78/78 green above this line.
#
# So drive the real interface on a pty with a pre-submitted prompt and require
# the prompt to come BACK on screen -- the echo is the user-message renderer
# having run, which is the exact path both crashes died on.
#
# The session runs in a THROWAWAY config home, and every part of that is
# load-bearing. An earlier version of this gate reused the user's own config and
# a trusted project of theirs, which meant each build: started their 9 MCP
# servers, fired their hooks, wrote a transcript, a history entry and a cost
# record into a real project of theirs, and -- because settings.json `env`
# overrides the process environment -- sent the prompt to their live proxy and
# got a real billed answer back. "Points at a dead port" was written in this
# file while none of it was true.
#
#   * CLAUDE_CONFIG_DIR   -> a temp home: no hooks, no MCP, no history, no cost
#   * seeded trust entry  -> no "is this a project you trust?" prompt, which is
#                            what a session stops at otherwise, rendering
#                            nothing while grepping exactly like a clean run
#   * a NON-claude model  -> patch #1 routes claude-* to api.anthropic.com no
#                            matter what the environment says; anything else
#                            falls through to ANTHROPIC_BASE_URL, so only a
#                            non-claude id actually reaches the dead port
#   * CHILD_SESSION marker-> transcript saving off
#   * --strict-mcp-config -> no servers even if one were configured
# A full session start on a machine already running builds is not a two-second
# affair, and a healthy build that misses the budget is reported as a failure.
# 40s was a guess that a loaded box can lose; this is generous and adjustable.
# Вторая копия десятичного правила живёт в tools/sweep.sh у SWEEP_LAST_N;
# расхождение ловится сценарием стенда, а не чтением. Общая библиотека не
# вводится: оба файла исполняются из копируемых снимков кита, и пропуск одного
# пути в списке копирования оставил бы прогон без валидатора.
validated_nonnegative_integer() {
  local name="$1" value="$2" digits
  case "$value" in
    ''|*[!0-9]*)
      echo "FATAL: $name must be a nonnegative integer, got '$value'." >&2
      return 2
      ;;
  esac
  # Величина сверяется по ЗНАЧЕНИЮ, а не по длине строки: «000005» -- это 5, и
  # отказ по длине отвергал бы законную настройку (волна 26). Ведущие нули
  # снимаются до сравнения; всё длиннее 19 цифр -- заведомо больше границы (это
  # утверждение о значении, а не о длине записи), а равная длина сравнивается
  # поразрядно. Граница -- потолок bash-арифметики: $((10#...)) выше неё
  # ЗАВОРАЧИВАЕТСЯ (измерено на этой машине), и число, которое арифметика не
  # может удержать, не может быть значением ручки.
  digits="$value"
  while [[ "$digits" == 0* && "$digits" != "0" ]]; do digits="${digits#0}"; done
  if (( ${#digits} > 19 )) \
     || { [[ "${#digits}" == 19 ]] && [[ "$digits" > "9223372036854775807" ]]; }; then
    echo "FATAL: $name must be a nonnegative integer up to 9223372036854775807, got '$value'." >&2
    return 2
  fi
  printf '%d\n' "$((10#$digits))"
}
# Код 2 валидатора -- его собственный вердикт о кривой ручке (FATAL напечатан
# им самим); прогон умирает тем же кодом, что и до правки (раньше -- set -e).
GATE_BUDGET="$(validated_nonnegative_integer CLAUDE_PATCH_GATE_BUDGET "${CLAUDE_PATCH_GATE_BUDGET:-150}")" || { printf 'ПРИБОР НЕДОСТУПЕН: бюджет гейта интерфейса не прочитан\n' >&2; exit 2; }
GATE_SCREEN=(120 40)
# G-5: поднятый или срезанный бюджет меняет СМЫСЛ вердикта этого гейта
# (срезанный краснит здоровую сборку, поднятый прячет медленную), поэтому
# отклонение от умолчания объявляется в потоке, а не остаётся в окружении.
[[ "$GATE_BUDGET" == "150" ]] \
  || echo "Interface gate: budget ${GATE_BUDGET}s (CLAUDE_PATCH_GATE_BUDGET, default 150)"

# Пара ЦЕЛИ считается ОДИН раз и передаётся вниз. Считает её ВЫЗЫВАЮЩИЙ, а не
# стадия: стенд гоняет стадию на ПОДДЕЛЬНОМ $BIN, а он скрипт -- настоящие
# магические байты взаимоисключающи с шебангом, и детектор отказал бы на нём
# кодом 1. Позови стадия детектор сама, все её ветки стали бы недостижимы для
# стенда. Решение при этом остаётся по ОБРАЗУ, а не по хозяину.
GATE_TARGET="$(__image_os_arch "$BIN")" || exit 1

# Н-3 (круг 24): величина бюджета проверяется ДО первого следа на диске и до
# запуска ребёнка. Под `set -euo pipefail` отказ валидатора обрывает прогон
# немедленно, а стоял он ниже -- после mktemp -d и после спавна сессии; кривая
# ручка оставляла ЖИВОГО сироту в своей группе процессов и каталог, который
# уже некому убрать: уборка -- не трап, а строка `rm -rf "$GATE_HOME"` в КОНЦЕ
# секции, до неё обрыв не доходит. Порядок здесь -- инвариант: между
# этой проверкой и созданием $GATE_HOME не должно появляться ничего, что
# создаёт файлы или процессы.
GATE_HOME="$(mktemp -d)" || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный дом гейта интерфейса\n' >&2; exit 2; }
# Пустой путь mktemp уходит ниже в mkdir и в rm -rf.
[ -n "$GATE_HOME" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь дома гейта интерфейса пуст\n' >&2; exit 2; }
mkdir -p "$GATE_HOME/cfg" "$GATE_HOME/proj"
GATE_PROMPT="tweakcc interface gate"
python3 - "$GATE_HOME" <<'PYSEED'
import json, os, sys
home = sys.argv[1]
cfg = os.path.join(home, "cfg")
proj = os.path.realpath(os.path.join(home, "proj"))
# The project key must be the RESOLVED path: on macOS /tmp is a symlink to
# /private/tmp, and a key written under the unresolved name does not match, so
# the session stops at the trust prompt and the gate proves nothing.
json.dump(
    {
        "hasCompletedOnboarding": True,
        "theme": "dark",
        "autoUpdates": False,
        "projects": {proj: {"hasTrustDialogAccepted": True, "allowedTools": [], "history": []}},
    },
    open(os.path.join(cfg, ".claude.json"), "w"),
)
json.dump(
    {
        "model": "gate-offline-model",
        "env": {
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:9",
            "DISABLE_TELEMETRY": "1",
            "DISABLE_ERROR_REPORTING": "1",
            "DISABLE_AUTOUPDATER": "1",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        },
    },
    open(os.path.join(cfg, "settings.json"), "w"),
)
PYSEED

GATE_LOG="$GATE_HOME/capture.log"
: > "$GATE_LOG"

# Reads the capture and answers in one word: RENDERED, PENDING, or ERROR <what>.
gate_state() {
  python3 - "$GATE_LOG" "$GATE_PROMPT" <<'PYSTATE'
import re, sys

raw = open(sys.argv[1], "rb").read().decode("utf8", "replace")
# OSC sequences carry the prompt text in a notification payload and can be
# terminated by BEL *or* by ESC-backslash; stripping only the BEL form left the
# prompt visible to the marker check without a single character having been
# rendered.
txt = re.sub(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)", "", raw)
txt = re.sub(r"\x1b[\[\(][0-9;?<>=]*[a-zA-Z]", "", txt)
txt = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", txt)
# The interface writes cursor moves where a person sees spaces, so a literal
# "auto mode on" is not present as bytes even while it is on the screen.
flat = re.sub(r"\s+", "", txt)

# A connection failure is the EXPECTED outcome here -- the model id is routed to
# a dead port on purpose -- so those are not interface faults.
#
# Entries must be spelled the way the ONLY reader below can produce them: that
# loop matches `[A-Z][A-Za-z]*Error`, so a capital-E `Error` suffix is the whole
# vocabulary. The earlier list held "Connectionrefused", "Connectionerror" and
# "fetchfailed" -- flattened PHRASES, none of which that pattern can ever emit,
# so three of its four entries were dead and only APIError did any work. The
# cost was not a silent pass but a false FATAL waiting to happen: let the
# product print a camel-case `ConnectionError` for the dead port and a healthy
# build is refused.
BENIGN = (
    "APIError",
    "APIConnectionError",
    "APIConnectionTimeoutError",
    "ConnectionError",
    "ConnectionRefusedError",
    "FetchError",
    "NetworkError",
)
# Order matters. The parenthesised exit line is the only place the name is
# delimited; anywhere else the flattening glues it to whatever the screen drew
# just before it ("...for shortcuts ERROR" + "l0"), so the on-screen ERROR
# label is consumed explicitly and the capture is non-greedy. Without both, the
# gate reported the identifier as "forshortcutsERRORl0".
m = re.search(r"unrecoverableinterfaceerror\(([^)]*)\)", flat)
if m:
    print(f"ERROR unrecoverable interface error ({m.group(1)})")
    sys.exit()
m = re.search(r"ERROR([A-Za-z_$][A-Za-z0-9_$]*?)isnotdefined", flat)
if m:
    print(f"ERROR {m.group(1)} is not defined")
    sys.exit()
if "isnotdefined" in flat:
    tail = flat[: flat.index("isnotdefined")][-16:]
    print(f"ERROR ...{tail} is not defined")
    sys.exit()
# Any exception class, not the three that happened to be seen once: a build
# that dies with RangeError or "Cannot read properties of undefined" is just as
# broken, and the earlier list called both of those a pass.
for m in re.finditer(r"([A-Z][A-Za-z]*Error)", flat):
    if m.group(1) not in BENIGN:
        print(f"ERROR {m.group(1)}")
        sys.exit()
if re.search(r"Cannotread(?:property|properties)of(?:undefined|null)", flat):
    print("ERROR cannot read properties of undefined")
    sys.exit()
print("RENDERED" if re.sub(r"\s+", "", sys.argv[2]) in flat else "PENDING")
PYSTATE
}

# --- 5a2b. стадия гейта интерфейса как ИМЕНОВАННАЯ функция --------------------
# У стадии появились зубы (tools/corpus-tools-bench.sh, семейство сценариев
# гейта интерфейса), а зуб зовёт стадию по имени: вырезанный по якорю блок
# исполняется стендом с поддельными $BIN и $GATE_HOME.
# КОНСТРЕЙНТ: функция читает $BIN, $GATE_HOME, $GATE_LOG, $GATE_PROMPT,
# $GATE_BUDGET и $GATE_TARGET из окружения вызывающего и НЕ создаёт $GATE_HOME
# сама. Порядок вызывающего -- «проверка бюджета -> пара цели -> создание
# дома»: между проверкой бюджета и созданием дома по-прежнему не должно
# появляться ничего, что создаёт файлы или процессы. Размер -- $GATE_SCREEN,
# прибор -- $HERE/tools/pty-run.py. Пару ХОЗЯИНА стадия берёт
# сама (__host_os_arch): из окружения приходит только пара ЦЕЛИ, и потому зуб
# может задать чужую цель, не трогая машину, на которой он запущен.
__interface_gate() {
  # Гейт ЗАПУСКАЕТ образ, поэтому он возможен ровно тогда, когда пара образа
  # равна паре хозяина. Иначе -- ОБЪЯВЛЕННЫЙ пропуск с обеими сторонами в
  # строке: чужой образ этой машине запустить нечем, и это не поломка продукта.
  # Молчаливый пропуск был бы хуже отказа -- «гейт прошёл» и «гейта не было»
  # читались бы одинаково.
  local __host_pair
  # Стадия вызывается голым именем (set -e в теле активен), выход 2 здесь --
  # честный код прибора для вызывающего.
  __host_pair="$(__host_os_arch)" || { printf 'ПРИБОР НЕДОСТУПЕН: пара платформ хозяина не измерена\n' >&2; exit 2; }
  if [[ "$GATE_TARGET" != "$__host_pair" ]]; then
    echo "==> Гейт интерфейса ПРОПУЩЕН: образ ${GATE_TARGET}, машина ${__host_pair} -- запустить нечем"
    rm -rf "$GATE_HOME"
    return 0
  fi
  # Пропущенной стадии прибор не нужен; отказ проверяется только на своей паре.
  if ! command -v python3 >/dev/null; then
    echo "FATAL: гейт интерфейса НЕ ИЗМЕРЕН -- нет python3 (отказ прибора)" >&2
    return 2
  fi
  local GATE_STATUS="$GATE_HOME/status" GATE_TOOL_RC=0
  local __status_line="" __status_extra="" __status_kind=""
  # Признак «ребёнок не пожат» инициализируется здесь: непроинициализированный
  # флаг под `set -u` уронил бы стадию, а его протечка между вызовами объявила
  # бы чужое состояние машины свойством этой сборки.
  local GATE_UNREAPED=0

  # $! адресует группу драйвера; тот пересылает TERM группе своей PTY-сессии.
  # Убийство одного процесса оставило бы дерево образа живым.
  #
  # `9>&-` CLOSES THE PATCH LOCK FOR THIS CHILD, and it is not hygiene -- it is
  # the lock's lifetime. The lock lives in a file DESCRIPTOR, so every process
  # holding a copy of fd 9 holds the lock; bash does not set close-on-exec on a
  # redirection, so the whole tree spawned here inherited it. This gate starts a
  # real CLI session -- which starts MCP servers, hooks and helper processes, in
  # its own session and process group. Anything that escapes the group kill below
  # then keeps the lock ALIVE AFTER THIS RUN EXITS, and the next run reads that as
  # "the pipeline is already running" (code 3). A version sweep that measured one
  # version and then reported the rest as НЕ ИЗМЕРЕНО is exactly this: no pipeline
  # was running, a straggler from the previous version's interface gate was
  # holding the descriptor.
  # Запускатель исполняется bash по шебангу; printf %q сохраняет argv даже
  # при пробелах в пути образа. Сам путь запускателя передаётся одним аргументом.
  { printf '#!/usr/bin/env bash\n'
    printf 'exec %q %q %q\n' "$BIN" --strict-mcp-config "$GATE_PROMPT"
  } > "$GATE_HOME/run.sh"
  chmod +x "$GATE_HOME/run.sh"
  (
    cd "$GATE_HOME/proj" || exit 1
    # Драйверу не нужен stdin вызывающего: ребёнок получает собственный PTY.
    # Его предел включает добор после первой отрисовки; бюджет опроса не меняется.
    __gate_cmd=(python3 "$HERE/tools/pty-run.py"
      --cols "${GATE_SCREEN[0]}" --rows "${GATE_SCREEN[1]}"
      --seconds "$((GATE_BUDGET + 8))" --out "$GATE_LOG" --status "$GATE_STATUS"
      -- "$GATE_HOME/run.sh")
    exec env CLAUDE_CONFIG_DIR="$GATE_HOME/cfg" CLAUDE_CODE_CHILD_SESSION=1 \
      "${__gate_cmd[@]}" </dev/null >"$GATE_HOME/instrument.log" 2>&1
  ) 9>&- &
  GATE_PID=$!

  # Ответ помощника читается КАК ОТВЕТ ПРИБОРА. Пустой ответ или ненулевой код --
  # это отказ РАЗБОРА захвата (нет python3, захват не прочитать), а не медленный
  # интерфейс: без этой развилки прогон уходил в ветку таймаута и печатал «гейт
  # не дождался отрисовки за N с» -- то есть поломка прибора объявлялась
  # свойством продукта.
  gate_state_checked() {
    local out rc=0
    out="$(gate_state)" || rc=$?
    if (( rc != 0 )) || [[ -z "$out" ]]; then
      printf 'TOOLFAIL разбор захвата не ответил (rc=%s, ответ %s символов)\n' \
        "$rc" "${#out}"
      return 0
    fi
    printf '%s\n' "$out"
  }

  GATE_STATE=PENDING
  GATE_EXITED=0
  i=0
  while (( i < GATE_BUDGET )); do
    i=$((i + 1))
    sleep 1
    # gate_state_checked не отказывает по построению (захват || rc=$? внутри,
    # TOOLFAIL -- сам ответ); пусто невозможно, ветвление ниже -- по слову.
    GATE_STATE="$(gate_state_checked)" || true
    case "$GATE_STATE" in
      ERROR*|TOOLFAIL*) break ;;
    esac
    if ! kill -0 $GATE_PID 2>/dev/null; then
      # It ended on its own. That is not success by itself: read the exit status.
      GATE_EXITED=1
      GATE_RC=0
      wait $GATE_PID 2>/dev/null || GATE_TOOL_RC=$?
      # gate_state_checked не отказывает (захват внутри неё); ответ -- слово.
      GATE_STATE="$(gate_state_checked)" || true
      break
    fi
    if [[ "$GATE_STATE" == RENDERED ]]; then
      # An error can still land after the first paint, so keep watching for a
      # while instead of declaring victory three seconds in.
      for _ in $(seq 1 8); do
        sleep 1
        # gate_state_checked не отказывает (захват внутри неё); ответ -- слово.
        GATE_STATE="$(gate_state_checked)" || true
        [[ "$GATE_STATE" == ERROR* || "$GATE_STATE" == TOOLFAIL* ]] && break
        # The same death the outer loop handles, and it must be handled the same
        # way HERE -- this is the branch the follow-up loop exists for. Breaking
        # without reading the status left GATE_EXITED at 0, and the block below
        # then forced GATE_RC=0: a build that drew its message and died one second
        # later, with a crash whose text matches none of gate_state's patterns
        # (a stack overflow, an engine-level fatal, a bare non-zero exit), was
        # reported as a clean interface.
        if ! kill -0 $GATE_PID 2>/dev/null; then
          GATE_EXITED=1
          GATE_RC=0
          wait $GATE_PID 2>/dev/null || GATE_TOOL_RC=$?
          # gate_state_checked не отказывает (захват внутри неё); ответ -- слово.
          GATE_STATE="$(gate_state_checked)" || true
          break
        fi
      done
      break
    fi
  done

  # GATE_TERM_HELPERS_BEGIN
  __interface_gate_deliver_term() {
    local pid="$1"
    local group_err= process_err=
    local group_rc=0 process_rc=0
    GATE_TERM_OUTCOME=undelivered
    GATE_TERM_GROUP_ERR=
    GATE_TERM_PROC_ERR=
    GATE_TERM_GROUP_RC=
    GATE_TERM_PROC_RC=
    # CONSTRAINT: stderr обеих попыток сохраняется (не /dev/null). Неуспех
    # kill не роняет вызывающего под set -e: код в $(…) становится кодом
    # присваивания, поэтому справа стоит `|| rc=$?`, не `|| true`.
    group_err="$(kill -TERM -"${pid}" 2>&1)" || group_rc=$?
    GATE_TERM_GROUP_ERR="${group_err}"
    GATE_TERM_GROUP_RC="${group_rc}"
    if [[ "${group_rc}" -eq 0 ]]; then
      GATE_TERM_OUTCOME=group
      return 0
    fi
    process_err="$(kill -TERM "${pid}" 2>&1)" || process_rc=$?
    GATE_TERM_PROC_ERR="${process_err}"
    GATE_TERM_PROC_RC="${process_rc}"
    if [[ "${process_rc}" -eq 0 ]]; then
      GATE_TERM_OUTCOME=process
      return 0
    fi
    GATE_TERM_OUTCOME=undelivered
    return 0
  }
  __interface_gate_term_still_alive_msg() {
    # «ignored TERM» только если сигнал доставлен (group|process).
    case "${GATE_TERM_OUTCOME}" in
      group|process)
        echo "  the interface gate ignored TERM; killing it" >&2
        ;;
      *)
        echo "  the interface gate could not deliver TERM (group rc=${GATE_TERM_GROUP_RC:-?} ${GATE_TERM_GROUP_ERR}; process rc=${GATE_TERM_PROC_RC:-?} ${GATE_TERM_PROC_ERR}); killing it" >&2
        ;;
    esac
    return 0
  }
  __interface_gate_classify_status() {
    local line="$1"
    # CONSTRAINT: одна строка — ровно одно из exited N | signaled N | unreaped | bad.
    # exited 0..255; signaled 1..127; unreaped — точное совпадение всей строки.
    if [[ "$line" =~ ^exited\ ([0-9]{1,3})$ ]] && (( 10#${BASH_REMATCH[1]} <= 255 )); then
      echo "exited ${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^signaled\ ([0-9]{1,3})$ ]] && (( 10#${BASH_REMATCH[1]} > 0 && 10#${BASH_REMATCH[1]} < 128 )); then
      echo "signaled ${BASH_REMATCH[1]}"
    elif [[ "$line" == unreaped ]]; then
      echo unreaped
    else
      echo bad
    fi
    return 0
  }
  # GATE_TERM_HELPERS_END
  if [[ $GATE_EXITED -eq 0 ]]; then
    __interface_gate_deliver_term "$GATE_PID"
    # GATE_BUDGET bounds the POLLING, not this. A child that ignores TERM -- or is
    # stuck in a syscall -- leaves the bare `wait` below waiting forever, and the
    # FATAL that explains the timeout sits after it and never prints. Give TERM a
    # few seconds, then take the process group out with KILL.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$GATE_PID" 2>/dev/null || break
      sleep 0.5
    done
    if kill -0 "$GATE_PID" 2>/dev/null; then
      __interface_gate_term_still_alive_msg
      kill -KILL -"$GATE_PID" 2>/dev/null || kill -KILL "$GATE_PID" 2>/dev/null || true
    fi
    wait $GATE_PID 2>/dev/null || GATE_TOOL_RC=$?
    GATE_RC=0
  fi

  # Статус образа и код прибора -- разные каналы. Ровно одна полная строка;
  # отсутствие, пустота и лишние строки не означают нулевой код образа.
  if [[ ! -f "$GATE_STATUS" ]] || ! {
    IFS= read -r __status_line && ! IFS= read -r __status_extra && [[ -z "$__status_extra" ]]
  } < "$GATE_STATUS"; then
    echo "FATAL: гейт интерфейса НЕ ИЗМЕРЕН -- статус отсутствует, пуст или неполон (отказ прибора)" >&2
    return 2
  fi
  # CONSTRAINT: отказ самого классификатора -- НЕ ИЗМЕРЕНО, а не исход образа.
  # Подстановка без проверки кода вернула бы пустую строку, и разбор ниже отнёс
  # бы её в ветку «bad», обвинив образ в том, что сломался прибор.
  if ! __status_kind="$(__interface_gate_classify_status "$__status_line")"; then
    echo "FATAL: гейт интерфейса НЕ ИЗМЕРЕН -- классификатор статуса отказал (отказ прибора)" >&2
    return 2
  fi
  if [[ "$__status_kind" =~ ^exited\ ([0-9]{1,3})$ ]]; then
    GATE_RC=$((10#${BASH_REMATCH[1]}))
  elif [[ "$__status_kind" =~ ^signaled\ ([0-9]{1,3})$ ]]; then
    GATE_RC=$((128 + 10#${BASH_REMATCH[1]}))
  elif [[ "$__status_kind" == unreaped ]]; then
    # CONSTRAINT: ребёнок пережил KILL и не пожат -- состояние МАШИНЫ, а не код
    # образа. Измерено 18.09 на 2.1.276/darwin: сессия, снятая после отрисовки,
    # застревает в состоянии выхода (`ps` STAT `?Es`) и не жнётся даже SIGKILL.
    # Кода выхода у образа в этом исходе НЕТ -- и выдумывать его нельзя.
    #
    # ЭТО НЕ ДВЕРЬ FAIL-OPEN: строка принимается ТОЛЬКО когда образ не выходил
    # сам (снимали мы), а вердикт всё равно выносит GATE_STATE ниже -- без
    # отрисовки ветка `*)` объявит отказ, как и прежде. Обратный случай
    # (образ вышел сам, но прибор его не пожал) -- противоречие двух каналов,
    # и оно объявляется, а не толкуется.
    if [[ $GATE_EXITED -eq 1 ]]; then
      echo "FATAL: гейт интерфейса НЕ ИЗМЕРЕН -- образ вышел сам, но прибор его не пожал (каналы противоречат)" >&2
      return 2
    fi
    GATE_UNREAPED=1
    GATE_RC=0
  else
    echo "FATAL: гейт интерфейса НЕ ИЗМЕРЕН -- отказ прибора или неверный статус: $__status_line" >&2
    [[ ! -f "$GATE_HOME/instrument.log" ]] || while IFS= read -r __status_extra; do
      printf '  %s\n' "$__status_extra" >&2
    done < "$GATE_HOME/instrument.log"
    return 2
  fi
  if (( GATE_TOOL_RC != 0 && GATE_TOOL_RC != 1 )); then
    echo "FATAL: гейт интерфейса НЕ ИЗМЕРЕН -- прибор завершился кодом $GATE_TOOL_RC" >&2
    return 2
  fi
  if (( GATE_TOOL_RC == 1 )); then GATE_EXITED=0; fi
  # Наше снятие после опроса не является самостоятельным выходом образа.
  if [[ "$GATE_EXITED" == 0 ]]; then GATE_RC=0; fi

  case "$GATE_STATE" in
    RENDERED)
      if [[ ${GATE_RC:-0} -ne 0 ]]; then
        echo "FATAL: the interface drew its message and then exited ${GATE_RC}" >&2
        echo "  capture kept at $GATE_LOG" >&2
        return 1
      fi
      echo "Interface: came up in a throwaway home and drew its message, no name or type errors"
      # Незажинаемый ребёнок ОБЪЯВЛЯЕТСЯ, а не проглатывается: отрисовка
      # доказана до снятия, но машина осталась с процессом, которого не берёт
      # даже KILL, и следующий прогон встретит его живым.
      if [[ $GATE_UNREAPED -eq 1 ]]; then
        echo "  примечание: ребёнка не удалось пожать (машина держит его в состоянии выхода);"
        echo "  отрисовка доказана до снятия, код выхода образа в этом исходе не существует"
      fi
      rm -rf "$GATE_HOME"
      ;;
    TOOLFAIL*)
      echo "FATAL: гейт интерфейса НЕ ИЗМЕРЕН -- сломан разбор захвата, а не продукт" >&2
      echo "  ${GATE_STATE#TOOLFAIL }" >&2
      echo "  capture kept at $GATE_LOG" >&2
      return 1
      ;;
    ERROR*)
      echo "FATAL: the interface does not come up — leaving the launcher alone" >&2
      echo "  ${GATE_STATE#ERROR }" >&2
      echo "  capture kept at $GATE_LOG" >&2
      return 1
      ;;
    *)
      # Three different faults arrive here, and only one of them is "the machine is
      # slow": the child may never have started (a helper missing from PATH exits
      # 127 in the first second), it may have exited non-zero without drawing, or
      # it may genuinely still be starting when the budget runs out. Advising a
      # bigger budget for the first two sends the reader in the wrong direction.
      if [[ $GATE_EXITED -eq 1 ]]; then
        echo "FATAL: the interface gate exited ${GATE_RC:-?} without drawing anything." >&2
        echo "       That is not a timeout — the run ended on its own." >&2
        tail -n 12 "$GATE_LOG" 2>/dev/null | sed 's/^/  /' >&2
      else
        echo "FATAL: the interface gate never reached a render within ${GATE_BUDGET}s," >&2
        echo "       so it proves nothing — refusing to call this build good." >&2
        echo "       Raise CLAUDE_PATCH_GATE_BUDGET if the machine is simply slow." >&2
      fi
      echo "  capture kept at $GATE_LOG" >&2
      return 1
      ;;
  esac
  return 0
}

# --- 5a2c. зубы доставки TERM гейта интерфейса ---------------------------------
# Стенд вырезает блок GATE_TERM_HELPERS из этого файла по якорю и гонит
# настоящие kill: доставку группе лидера, одиночному процессу, честное
# сообщение на мёртвом pid и обход всех исходов, не роняющий вызывающего под
# set -e; каждая записанная мутация обязана покраснить свой зуб своей
# причиной. КОНСТРЕЙНТ: стенд стоит ДО гейта, чьи зубы держит, -- сломанный
# зуб останавливает прогон до того, как этот механизм понадобится живой
# сессии, и стенд отрабатывает даже когда сам гейт объявлен пропущенным
# (чужая платформная пара): предмет зубов -- код доставки TERM, а не образ.
echo "==> Зубы доставки TERM гейта интерфейса"
bash "$(dirname "$0")/tools/gate-kill-teeth.sh" 9>&- || {
  __rc=$?
  case $__rc in
    2) echo "ЗУБЫ ГЕЙТА ИНТЕРФЕЙСА НЕ ИЗМЕРЯЛИ: якорь вырезки либо прибор (rc=2)" >&2
       exit 2 ;;
    4) echo "ЗУБЫ ГЕЙТА ИНТЕРФЕЙСА: объявленное число зубов либо мутаций не сошлось (rc=4)" >&2
       exit 4 ;;
    *) echo "ЗУБЫ ГЕЙТА ИНТЕРФЕЙСА УПАЛ: зуб не держится (rc=$__rc)" >&2
       exit 1 ;;
  esac
}

# Стадия зовётся ГОЛЫМ ИМЕНЕМ, а не через `|| exit $?`: у функции, стоящей в
# AND-OR списке, `set -e` ИГНОРИРУЕТСЯ ВО ВСЁМ ТЕЛЕ (замерено: под `||`
# незащищённый `wait` тело не обрывает, голым именем -- обрывает). Форма с `||`
# молча сняла бы с вынесенного тела ту самую оболочку, под которой оно жило до
# выноса, и погасила бы вместе с ней зубы этой волны. Ненулевой возврат под
# `set -e` кончает прогон тем же кодом, каким стадия выходила до выноса.
__interface_gate

# --- 5a3. the probes must BEHAVE, not merely be present -----------------------
# The checks above are text checks on the image and the interface gate only
# proves the product starts. Neither runs the judge or the watcher. The bench
# does: it carves both probe blocks out of the finished binary, compiles them,
# and drives probe-bench's 132 scenarios through a throwaway probes home —
# verdicts, degraded
# configs, trimming, nudges, the fleet filters.
#
# It existed for weeks and proved nothing, because nothing called it. That is
# the same silence that let `emit-check.js` sit broken three times over, and it
# hid three real faults here: the carve took whichever probe block came first
# (so when the judge moved onto the dispatch tool, every scenario died in setup
# with "free name not found: notify"), the judge's block was not compilable at
# all (it names the tool `this` and derives its record key from the context),
# and the session id was located by a payload field that only the watcher has —
# leaving the name free inside the shared core, where the accessor catches the
# ReferenceError and returns null. A green build said nothing about any of it.
#
# It runs in under a second, so there is no cost worth trading for the silence.
if [[ "${CLAUDE_PATCH_SKIP_BENCH:-0}" == "1" ]]; then
  # An escape hatch that leaves no trace is indistinguishable from a gate that
  # ran. This one is inheritable from a shell profile or an earlier diagnostic
  # run, and the build would otherwise end on `Done.` with no hint that the only
  # gate which EXECUTES the judge and the watcher never ran.
  echo "Probes: SKIPPED — CLAUDE_PATCH_SKIP_BENCH=1; judge and watcher behaviour is UNVERIFIED" >&2
else
  BENCH="$(dirname "$0")/tools/probe-bench.js" || { printf 'ПРИБОР НЕДОСТУПЕН: не получен каталог стенда проб\n' >&2; exit 2; }
  if ! command -v bun >/dev/null; then
    # The bench must run under bun: the image is a single-file bun executable
    # and the carved block is executed by its engine. Refusing loudly beats a
    # skip that reads like a pass.
    echo "FATAL: bun is required to run the probe bench (the image is a bun executable)." >&2
    echo "  Set CLAUDE_PATCH_SKIP_BENCH=1 to build without this gate." >&2
    exit 1
  fi
  BENCH_LOG="$(mktemp)" || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный журнал стенда проб\n' >&2; exit 2; }
  # Пустой путь mktemp уходит ниже в перенаправление и в rm -f.
  [ -n "$BENCH_LOG" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь журнала стенда проб пуст\n' >&2; exit 2; }
  __benchrc=0
  bun "$BENCH" --binary "$BIN" >"$BENCH_LOG" 2>&1 || __benchrc=$?
  if (( __benchrc == 0 )); then
    # -a and a numeric guard: a plain `grep -c` on a log with a NUL byte
    # prints NOTHING and exits 1, and the line would read "Probes:  scenarios
    # behaved as specified" -- which still matches every pattern that looks
    # for it, so the loss would be invisible to the sweep as well.
    # Число сценариев берётся из строки, которую печатает САМ стенд, а не
    # пересчётом строк его таблицы. Прежний греп `^[a-z][a-z0-9-]* *|` опирался
    # на грамматику имени сценария, которой писатель не обещал: имя `Foo-bar`
    # или `foo_bar` таблицу не ломает, а из счёта выпадает -- и вместо отказа
    # печаталось меньшее, вполне достоверное на вид число.
    #
    # Отсутствие строки итога -- ОТКАЗ. Прежняя ветка на нечисло печатала
    # "Probes: НЕИЗВЕСТНО СКОЛЬКО scenarios behaved as specified" и ехала
    # дальше: сводка, признающая, что ничего не измерила, всё равно проходила
    # как успех.
    BENCH_SUM=$(grep -a -m1 '^probe-bench: ИТОГ ' "$BENCH_LOG" || true)
    BENCH_N=$(printf '%s' "$BENCH_SUM" | sed -n 's/.*сценариев=\([0-9][0-9]*\).*/\1/p') || { printf 'ПРИБОР НЕДОСТУПЕН: не извлечено число сценариев из итога стенда\n' >&2; exit 2; }
    BENCH_BAD=$(printf '%s' "$BENCH_SUM" | sed -n 's/.*расхождений=\([0-9][0-9]*\).*/\1/p') || { printf 'ПРИБОР НЕДОСТУПЕН: не извлечено число расхождений из итога стенда\n' >&2; exit 2; }
    if [[ -z "$BENCH_N" || -z "$BENCH_BAD" ]]; then
      echo "FATAL: стенд проб завершился успехом, но не назвал итог." >&2
      echo "  Ожидалась строка вида: probe-bench: ИТОГ сценариев=N расхождений=M" >&2
      echo "  Либо формат стенда изменился, либо вывод обрезан. Лог: $BENCH_LOG" >&2
      exit 1
    fi
    if [[ "$BENCH_BAD" -ne 0 ]]; then
      echo "FATAL: стенд вышел с успехом, но сам называет $BENCH_BAD расхождений." >&2
      echo "  Лог: $BENCH_LOG" >&2
      exit 1
    fi
    echo "Probes: $BENCH_N scenarios behaved as specified"
    # The bench says so itself when its bun differs from the image's: the block
    # is executed by a DIFFERENT engine than the one that will run it in
    # production, so runtime-level differences are not covered. That warning
    # went to the log, and the success branch deleted the log unread.
    grep '^probe-bench: ВНИМАНИЕ' "$BENCH_LOG" >&2 || true
    rm -f "$BENCH_LOG"
  elif (( __benchrc == 2 || __benchrc == 4 )); then
    # Класс ответа стенда: код «прибор не мерил» (нет якоря вырезки, нет bun,
    # таблица сценариев структурно битая) против кода «объявленное число не
    # сошлось с фактическим». Прежде ветка отказа не смотрела на код вовсе и
    # печатала «поведение не соответствует спецификации» на оба (раунд 19, A-1).
    if (( __benchrc == 2 )); then
      echo "FATAL: СТЕНД ЗОНДОВ НЕ ИЗМЕРЯЛ: прибор не может мерить (rc=2)." >&2
    else
      echo "FATAL: СТЕНД ЗОНДОВ: сценариев не столько, сколько объявлено (rc=4)." >&2
    fi
    tail -n 15 "$BENCH_LOG" | sed 's/^/  /' >&2
    echo "  full table kept at $BENCH_LOG" >&2
    exit "$__benchrc"
  else
    echo "FATAL: the probe bench found behaviour that does not match its specification:" >&2
    # `grep` exits 1 when nothing matches, and under `set -euo pipefail` that
    # ends the script before the next line -- so the one failure mode we cannot
    # classify (bun killed by a signal, a runtime crash with no MISMATCH line)
    # would print a bare FATAL and swallow the path to the log that explains it.
    # Третья ветвь `^ ` -- не украшение. Стенд печатает причину расхождения
    # ОТДЕЛЬНЫМИ строками под своим `MISMATCH <имя>:`, с отступом в два пробела
    # («outcome: ожидалось "ok", факт null»). Прежний фильтр знал только два
    # первых слова, и объяснения выбрасывались: в лог конвейера уезжал столбик
    # имён без единой причины -- ровно тот вид, из-за которого 119 расхождений
    # на ИСПРАВНОМ образе пришлось разбирать веером, хотя причина стояла в
    # выброшенных строках (замер 2026-09-14). Столбцы таблицы кладутся padEnd,
    # с пробела не начинаются; под `^ ` попадают только эти объяснения и след
    # стека упавшего рантайма -- оба нужны читателю.
    if ! grep -E 'MISMATCH|probe-bench:|^ ' "$BENCH_LOG" | sed 's/^/  /' >&2; then
      echo "  (no MISMATCH or probe-bench line — the bench failed some other way)" >&2
      tail -n 15 "$BENCH_LOG" | sed 's/^/  /' >&2
    fi
    echo "  full table kept at $BENCH_LOG" >&2
    echo "  Set CLAUDE_PATCH_SKIP_BENCH=1 to build without this gate." >&2
    exit 1
  fi

  # Второй прогон -- зубы самого стенда, как у стенда инструментов судьи.
  # Сломай сравнивающий, и первый прогон печатает «поведение по спецификации»
  # для любого образа: гейт, доказывающий поведение, обязан сперва доказать,
  # что умеет краснеть. Мутации ломают КОПИЮ стенда и обязаны СНЯТЬ красноту,
  # которую пристинная копия видит на отраве.
  bun "$BENCH" --self-check --binary "$BIN" || {
    __rc=$?
    case $__rc in
      2) echo "СТЕНД ЗОНДОВ: self-check НЕ ЗАПУСТИЛСЯ -- прибор не может мерить (rc=2)" >&2 ;;
      4) echo "СТЕНД ЗОНДОВ: таблица мутаций не той длины, чем объявлено" >&2 ;;
      *) echo "СТЕНД ЗОНДОВ БЕЗ ЗУБОВ: запись таблицы не сняла красноту отравы" >&2 ;;
    esac
    # Класс ответа ребёнка СОХРАНЯЕТСЯ и здесь (круг 28, F-4): первый прогон
    # того же стенда выходит `exit "$__benchrc"`, и соседи (judge-tools,
    # costs, probes-sync-bench, гейт чисел) -- тоже. Прежняя форма роняла 2 и
    # 4 в единицу: вызывающий, ветвящийся по КЛАССУ, читал «отказ по существу»
    # там, где стенд не мерил или таблица разошлась с объявленным числом.
    if (( __rc == 2 || __rc == 4 )); then
      exit "$__rc"
    fi
    exit 1
  }
fi

# --- 5b0. «СУДЬЯ СЛУЖИТ»: боевой веер обязан отвечать, а не молчать ---------
# Последний несделанный пункт задачи #158. Всё выше по потоку мерило, легла
# ли правка в БАЙТЫ: якоря текста, зелёность на пристинном образе, поведение
# зондов на вырезанных блоках. Ни одна стадия не спрашивала, возвращают ли
# СТУПЕНИ судьи вердикт, -- и вырожденный веер четверо суток проходил сборку
# с зелёными гейтами. Прибор для этого вопроса существует в соседнем
# репозитории; кит ЗОВЁТ его и не измеряет сам: вторая копия прибора уже
# создавалась по ошибке и отвергнута (судьба той копии решена отдельно).
#
# CONSTRAINT: ЕДИНСТВЕННЫЙ ДОМ предиката «продукт этого прогона становится
# живым» -- переменная __goes_live ниже, и ВСЕ её слагаемые перечислены
# рядом. Перечень путей, размазанный по условиям стадий, расходится молча --
# ровно тот класс, которым занят весь этот дом. Слагаемые: --update
# (DO_UPDATE: репойнт в 5b ставит сборку на живое место), дефолтный прогон
# (STAGED_FROM_LIVE: swap в 5b ставит стажированную копию на живое место) и
# --only-ours без --target (блок 0b пропускает этот флаг НАМЕРЕННО, «In
# place is right for that flag»: правка ложится на живой файл НА МЕСТЕ, без
# копии и без swap). С --target продукт живым не становится НИ ПРИ КАКОМ
# флаге, и живых вызовов там быть не должно.
#
# CONSTRAINT: тот же дом называет и ПОРЯДОК пути, потому что у отказа два
# разных мира. На путях swap/repoint гейт стоит ДО факта -- живой образ ещё
# прежний, «в бой не пустили». На пути --only-ours -- ПОСЛЕ факта: правка
# уже легла на живой файл, и красное там значит «в бою уже стоит, и оно не
# служит». Тексты отказа не смешиваются: оператор обязан различать эти два
# состояния по первой же строке.
#
# CONSTRAINT: стадия стоит ПЕРЕД секцией 5b целиком -- до swap И до repoint,
# и меряет $BIN: на путях swap это стажированная копия, байт, который вот-вот
# станет живым; на пути --only-ours это УЖЕ живой файл. Умолчание стенда
# ($HOME/.local/bin/claude) -- СТАРЫЙ живой образ: на путях swap гейт на нём
# зеленел бы предыдущей сборке, поэтому CATALYST_JUDGE_IMAGE передаётся явно.
# После 5b мерить поздно: $BIN переименован, репойнт уже сделан, а неслужащая
# сборка успела бы занять живое место.
#
# CONSTRAINT: стенд не найден -- НЕ пропуск. Кит исполняется и из копируемых
# снимков, где соседнего репозитория может не быть; молчаливый fail-open
# сделал бы «прибора нет» неотличимым от «веер проверен и служит» -- ровно
# та слепота, ради которой стадия существует. Код 7, а не 1: предмет нельзя
# измерить ПОКА, повод вне этой машины (нет соседа у снимка) и пройдёт сам.
__goes_live=0
if [[ $DO_UPDATE -eq 1 || $STAGED_FROM_LIVE -eq 1 ]]; then
  __goes_live=1
fi
if [[ $ONLY_OURS -eq 1 && -z "$TARGET" ]]; then
  __goes_live=1
fi
# Порядок пути: ПРИЗНАК «правка уже на живом файле» -- только чистый
# --only-ours (без --target и без --update); сочетание --update --only-ours
# правит СВЕЖЕУСТАНОВЛЕННЫЙ файл, который репойнт ещё не поставил на живое
# место, -- там гейт снова ДО факта.
__judge_in_place=0
if [[ $ONLY_OURS -eq 1 && $DO_UPDATE -eq 0 && -z "$TARGET" ]]; then
  __judge_in_place=1
fi
if [[ $__goes_live -eq 1 ]]; then
  if [[ "${CLAUDE_PATCH_SKIP_JUDGE_SERVES:-0}" == "1" ]]; then
    # CONSTRAINT: пропуск объявляется ПОИМЁННО, по образцу
    # CLAUDE_PATCH_SKIP_KIT_BENCH: гейт, чей след неотличим от отработавшего
    # гейта, есть гейт, которого нет.
    echo "СУДЬЯ СЛУЖИТ: ПРОПУЩЕН -- CLAUDE_PATCH_SKIP_JUDGE_SERVES=1. Боевой веер судьи в образе $BIN НЕ проверен." >&2
  else
    __judge_stand="${CLAUDE_PATCH_JUDGE_STAND:-$HERE/../Catalyst/tests/scripts/test-judge-ladder-live.sh}"
    if [[ ! -f "$__judge_stand" ]]; then
      echo "СУДЬЯ СЛУЖИТ: НЕ ИЗМЕРЕНО -- файла стенда боевого веера нет (код 7):" >&2
      echo "  искал: $__judge_stand" >&2
      echo "  Стенд живёт в соседнем репозитории и в копируемом снимке кита может" >&2
      echo "  отсутствовать; путь задаётся ручкой CLAUDE_PATCH_JUDGE_STAND." >&2
      echo "  Пропуск -- только явной ручкой CLAUDE_PATCH_SKIP_JUDGE_SERVES=1." >&2
      exit 7
    fi
    if [[ ! -x "$BIN" ]]; then
      # Код 6, а не 7: образ собран ЭТИМ прогоном выше по потоку -- его нет
      # только если сломана сама машинерия прогона, повтор не поможет.
      echo "СУДЬЯ СЛУЖИТ: НЕ ИЗМЕРЕНО -- собранного образа нет или он не исполняется (код 6): $BIN" >&2
      exit 6
    fi
    __judge_probes_home="${CLAUDE_PROBES_HOME:-$HOME/.claude/probes}"
    if [[ ! -f "$__judge_probes_home/probes.toml" ]]; then
      # Код 6: дом проб -- окружение ЭТОЙ машины, а не ожидание внешнего мира.
      echo "СУДЬЯ СЛУЖИТ: НЕ ИЗМЕРЕНО -- боевого дома проб нет (код 6): $__judge_probes_home/probes.toml" >&2
      echo "  Стенд читает боевые ступени из probes.toml; без него мерить нечем." >&2
      exit 6
    fi
    echo "==> СУДЬЯ СЛУЖИТ: приёмка боевого веера (живые вызовы ступеней)"
    # Стенд отвечает СВОИМИ кодами (0 зелёное, 1 красное, 2 отказ прибора,
    # 3 не измерено); таблица ниже -- явное отображение в классы кита, по
    # образцу стадий стендов выше:
    #   стенд 1 -> 1  веер не служит: отказ по существу, чинить образ;
    #   стенд 3 -> 7  НЕ ИЗМЕРЕНО: площадка провайдеров недостижима или
    #                 ступень отказала -- повод вне этой машины, пройдёт сам;
    #                 это не вердикт о продукте и не зелёное;
    #   стенд 2 -> 2  отказ прибора, не покрытый предпроверками выше (нет
    #                 образа и нет дома проб уже ушли кодом 6): у стенда ушла
    #                 его опора в боевом конфиге -- ступеней судьи в нём нет;
    #   прочее  -> 2  код вне объявленной стендом таблицы -- нарушен
    #                 контракт вызова.
    __judge_rc=0
    CATALYST_JUDGE_LIVE=1 CATALYST_JUDGE_IMAGE="$BIN" \
      bash "$__judge_stand" || __judge_rc=$?
    case $__judge_rc in
      0) : ;;
      1) if [[ $__judge_in_place -eq 1 ]]; then
           echo "СУДЬЯ СЛУЖИТ: КРАСНОЕ -- живой образ УЖЕ несёт НЕ служащий веер (стенд rc=1)." >&2
           echo "  Путь --only-ours правит образ на месте: подмены не было, правка уже" >&2
           echo "  легла на живой файл $BIN. Вернуть пристинные байты (staged copy +" >&2
           echo "  rename, НЕ cp поверх живого файла -- канон README):" >&2
           echo "    cp -p \"$BIN.orig\" \"$BIN.restore\" && mv \"$BIN.restore\" \"$BIN\"" >&2
         else
           echo "СУДЬЯ СЛУЖИТ: КРАСНОЕ -- боевой веер не служит (стенд rc=1): в бой НЕ пустили." >&2
           echo "  Живой образ ещё не подменён (стадия стоит до swap/repoint);" >&2
           echo "  чинить образ, а не площадку." >&2
         fi
         exit 1 ;;
      3) echo "СУДЬЯ СЛУЖИТ: НЕ ИЗМЕРЕНО -- площадка недостижима или ступени не ответили (стенд rc=3)" >&2
         echo "  Это не вердикт о продукте: пройдёт само, когда появится доступ." >&2
         exit 7 ;;
      2) echo "СУДЬЯ СЛУЖИТ: стенд не может мерить -- его опора в боевом конфиге ушла (стенд rc=2)" >&2
         exit 2 ;;
      *) echo "СУДЬЯ СЛУЖИТ: контракт вызова нарушен -- стенд ответил кодом вне своей таблицы (rc=$__judge_rc)" >&2
         exit 2 ;;
    esac
  fi
fi

# --- 5b. only now may the launcher point at the new build ----------------------
# The installer deliberately leaves ~/.local/bin/claude on the PREVIOUS version:
# between "pristine installed" and "patched + verified" there is about a minute,
# and a session started inside it runs unpatched — claude-* traffic then goes to
# the local proxy with the subscription OAuth bearer and the session dies on
# "unknown provider for model claude-opus-5" (observed 2026-08-18). The checks
# above are the gate: `set -e` aborts before this line if any of them failed.
if [[ $DO_UPDATE -eq 1 || $STAGED_FROM_LIVE -eq 1 ]]; then
  # The installer hands back a `.staging` path when the requested version was
  # already installed -- the live file was left untouched while we patched a
  # copy. A default run over an already-patched live binary stages for the same
  # reason (see 0b). Swap it in now, with a rename: atomic, and it takes effect
  # on the next launch rather than under a running process.
  if __has_staging "$BIN"; then
    FINAL="$(__strip_staging "$BIN")" || { printf 'ПРИБОР НЕДОСТУПЕН: не снят staging-суффикс с имени цели\n' >&2; exit 2; }
    mv "$BIN" "$FINAL"
    echo "Swapped the verified build over the previous one: $FINAL"
    BIN="$FINAL"
  fi
fi
if [[ $DO_UPDATE -eq 1 ]]; then
  python3 "$HERE/claude_patch.py" --repoint "$BIN"
fi

# --- 6. cleanup previous versions ---------------------------------------------
# After a successful --update, remove all older version binaries and their .orig
# backups. Keep only the current version and its .orig (for emergency restore).
# Config backups: keep only the 3 most recent.
if [[ $DO_UPDATE -eq 1 ]]; then
  VERSIONS_DIR="$(dirname "$BIN")" || { printf 'ПРИБОР НЕДОСТУПЕН: не получен каталог версий из пути цели\n' >&2; exit 2; }
  # The keep-list is built from the REAL version name, not the target name:
  # when building into staging (--target X.staging) basename would give
  # "2.1.237.staging", and the cleanup would wipe the live 2.1.237 along with
  # its pristine .orig — everything except the intermediate file. Only the
  # binary a live session was executing at that moment would survive.
  # Пара присваиваний: сначала снимается staging-суффикс, затем берётся имя
  # версии -- каждая подстановка проверена на своей строке.
  __cur_base="$(__strip_staging "$BIN")" || { printf 'ПРИБОР НЕДОСТУПЕН: не снят staging-суффикс с имени цели\n' >&2; exit 2; }
  CURRENT_VER="$(basename "$__cur_base")" || { printf 'ПРИБОР НЕДОСТУПЕН: не получено имя текущей версии из пути\n' >&2; exit 2; }
  CURRENT_VER="${CURRENT_VER%.orig}"
  echo
  echo "==> Cleaning up previous versions"
  # A version a live session is still executing is kept: unlinking a running
  # binary leaves the process on its now-nameless inode, and a bun executable
  # reads embedded assets back out of its own file. Those sessions release it
  # on exit, so the next --update collects it.
  # Enumerate pids and ask about each: `lsof -c claude` returns nothing on
  # macOS for these processes (verified 2026-08-12, which is how a running
  # 2.1.226 got unlinked), while `lsof -p <pid>` reports the text image fine.
  # Both halves of that answer are silent when they fail. A missing `pgrep`
  # inside the `for` substitution yields an empty list and status 0, which is
  # indistinguishable from "no claude is running"; a missing `grep` sits in an
  # `if` condition, where `set -e` does not look, so the test reads false and
  # the `rm` runs anyway. Either way the deletion the comment above forbids --
  # unlinking a binary a live session is executing -- happens quietly. Ask for
  # the tools first: a stale binary costs disk, an unlinked live one costs the
  # session.
  if ! command -v pgrep >/dev/null || ! command -v lsof >/dev/null; then
    echo "  skipped: without pgrep and lsof, 'is a live session executing it?'" >&2
    echo "  cannot be answered — refusing to delete old versions on a guess." >&2
  else
    IN_USE_RC=0
    IN_USE="$(versions_in_use)" || IN_USE_RC=$?
    if (( IN_USE_RC != 0 )); then
      echo "  skipped: pgrep/lsof could not answer for every live claude pid (rc=$IN_USE_RC)." >&2
      echo "  cannot be answered — refusing to delete old versions on a guess." >&2
    else
      for old in "$VERSIONS_DIR"/2.1.*; do
        base="$(basename "$old")" || { printf 'ПРИБОР НЕДОСТУПЕН: не получено имя старой версии из пути\n' >&2; exit 2; }
        [[ "$base" == "$CURRENT_VER" || "$base" == "$CURRENT_VER.orig" ]] && continue
        if grep -qxF "$old" <<<"$IN_USE"; then
          echo "  kept (a running session is executing it): $base"
          continue
        fi
        # A kept binary without its pristine twin cannot be returned to stock, and
        # that twin is exactly what the in-use test never matches: sessions execute
        # `2.1.239`, never `2.1.239.orig`, so the backup of the one version we
        # deliberately preserved was the first thing deleted. Keep the pair.
        if [[ "$base" == *.orig ]] && grep -qxF "${old%.orig}" <<<"$IN_USE"; then
          echo "  kept (pristine copy of a binary a running session is executing): $base"
          continue
        fi
        rm -v "$old"
      done
    fi
  fi
  prune_config_backups
fi

# Значения-истина: 1 true yes on (без учёта регистра). Ложь: пусто,
# отсутствие, 0 false no off. Всё прочее -- ОТКАЗ кодом 2 с именем ручки:
# в оболочке отказ дёшев и громок, а тихо выбранная сторона у ручки,
# меняющей измеряемое, -- это ровно тот дефект, который здесь чинится.
# В ядре, tweakcc-patch.js, та же семья решена иначе -- безопасная сторона
# плюс строка в журнал: там отказ убил бы живую сессию человека.
# Копии правила живут в tools/sweep.sh, tools/lock-probe.sh и
# tools/build-path-probe.sh; расхождение ловится сценарием стенда, а не чтением.
__envon() {  # имя переменной; 0 истина, 1 ложь, 2 неизвестное значение
  local __name="$1" __raw="${!1-}" __value
  # `return 2`, а не `exit 2`: функция стоит в `||`-списке у своего вызова,
  # и вызывающий уже различает двойку (`(( rc != 2 )) || exit 2`).
  __value=$(printf '%s' "$__raw" | LC_ALL=C tr '[:upper:]' '[:lower:]') || { printf 'ПРИБОР НЕДОСТУПЕН: значение ручки не приведено к нижнему регистру\n' >&2; return 2; }
  case "$__value" in
    1|true|yes|on) return 0 ;;
    ''|0|false|no|off) return 1 ;;
    *) echo "FATAL: $__name='$__raw' -- expected 1/true/yes/on or 0/false/no/off" >&2
       return 2 ;;
  esac
}

# --- 6b. активация: объявить и проверить -------------------------------------
# Сборка, пережившая все гейты, ещё не значит АКТИВНУЮ: репойнт лаунчера
# исполняется только на ветке --update, а на --target и на дефолтном прогоне
# симлинк может остаться на прежней версии, и до этой стадии прогон об этом
# молчал -- оператор читал «Done.» как «версия обновлена». Зуб на стадию --
# вырезка именованной функции в tools/build-path-probe.sh (случай v); по этому
# имени стадия и объявлена.
__activation_announce() {
  local __act_rc=0 __act_out __act_match __act_active __act_built
  # Форма `|| __act_rc=$?`, а НЕ `; __act_rc=$?`: под `set -e` ненулевой код
  # подстановки обрывает скрипт ДО строки с `$?`, и прибор, ответивший
  # ненулём, убил бы прогон раньше строки отказа. Слева от `||` статус
  # команды ошибкой не считается -- ровно для этого.
  __act_out="$(python3 "$HERE/claude_patch.py" --activation "$BIN")" || __act_rc=$?
  if (( __act_rc != 0 )); then
    echo "FATAL: АКТИВАЦИЯ НЕ ИЗМЕРЕНА -- прибор активации ответил кодом $__act_rc" >&2
    printf '%s\n' "$__act_out" >&2
    return 1
  fi
  __act_match="$(printf '%s\n' "$__act_out" | sed -n 's/^MATCH=//p')" || { printf 'ПРИБОР НЕДОСТУПЕН: не извлечен вердикт MATCH из ответа активации\n' >&2; exit 2; }
  if [[ -z "$__act_match" ]]; then
    echo "FATAL: АКТИВАЦИЯ НЕ ИЗМЕРЕНА -- прибор не назвал MATCH" >&2
    printf '%s\n' "$__act_out" >&2
    return 1
  fi
  __act_active="$(printf '%s\n' "$__act_out" | sed -n 's/^ACTIVE=//p')" || { printf 'ПРИБОР НЕДОСТУПЕН: не извлечена активная версия из ответа активации\n' >&2; exit 2; }
  __act_built="$(printf '%s\n' "$__act_out" | sed -n 's/^BUILT=//p')" || { printf 'ПРИБОР НЕДОСТУПЕН: не извлечена собранная версия из ответа активации\n' >&2; exit 2; }
  case "$__act_match" in
    yes)
      echo "==> Активация: собранная версия активна ($__act_active)"
      ;;
    no)
      if [[ $DO_UPDATE -eq 1 ]]; then
        # Репойнт на ветке --update был ОБЕЩАН и не сработал -- молчание здесь
        # читалось бы как «версия обновлена».
        echo "FATAL: РЕПОЙНТ БЫЛ ОБЕЩАН (--update), а лаунчер активен не на собранную версию:" >&2
        echo "  собрано: $__act_built" >&2
        echo "  активно: $__act_active" >&2
        return 1
      fi
      echo "==> РАСХОЖДЕНИЕ ОБЪЯВЛЕНО: собрано $__act_built, активно $__act_active."
      echo "    Этот прогон активации НЕ обещал; активировать вручную:"
      echo "    python3 \"$HERE/claude_patch.py\" --repoint \"$BIN\""
      ;;
    unknown)
      echo "==> Активация НЕ ИЗМЕРЕНА: лаунчера нет -- активной версии нечем назвать."
      echo "    Активировать вручную:"
      echo "    python3 \"$HERE/claude_patch.py\" --repoint \"$BIN\""
      ;;
    *)
      # Слово, которого стадия не знает, -- НЕ вердикт. Без этой ветки `case`
      # возвращает ноль, и прогон едет дальше, прочитав незнакомое значение
      # как «всё сошлось»: ровно та форма молчания, ради которой стадия
      # заведена. Образец дома -- отказ сверки раскатки («ОТВЕТИЛА
      # НЕОЖИДАННЫМ КОДОМ: вердикта нет»).
      echo "FATAL: АКТИВАЦИЯ НЕ ИЗМЕРЕНА -- прибор ответил неизвестным MATCH=$__act_match" >&2
      printf '%s\n' "$__act_out" >&2
      return 1
      ;;
  esac
}
__activation_announce

# --- 7. the model data the patches read --------------------------------------
# Patches #8 and #10 only teach the binary WHERE to look: customModelCosts and
# customModelContextWindows in ~/.claude.json. What is IN those keys is a
# snapshot taken by set-model-costs.py, and the proxy gains models between runs
# — each one then bills at the $5/$25 Opus fallback and is pinned to a 200K
# window until somebody remembers to re-sync. That is exactly how glm-5.3 sat
# unpriced with the wrong window for a day (2026-08-15). Patching is the one
# moment this install is already being touched, so the data is refreshed here
# and the two halves stop drifting apart.
#
# Never fatal. The sync needs the proxy up (for its model listing) and
# models.dev reachable; neither has anything to do with whether the binary was
# patched correctly, so a failure is a warning and the old numbers stay.
# Форма `__envon ИМЯ || rc=$?`, а НЕ `__envon ИМЯ; rc=$?`: под `set -e`
# (шапка :96) вторая обрывает скрипт МОЛЧА на самом частом случае --
# ручка не выставлена, читатель честно вернул «ложь», и оболочка вышла
# кодом 1 сразу после свапа, не дойдя до синхрона цен. Измерено на
# приёмке волны 31: установка проходила, а конвейер объявлял отказ.
# Слева от `||` статус команды не считается ошибкой -- ровно для этого.
__env_rc=0
__envon CLAUDE_PATCH_SKIP_MODELS || __env_rc=$?
(( __env_rc != 2 )) || exit 2
if (( __env_rc == 0 )); then
  echo "Model data: SKIPPED — CLAUDE_PATCH_SKIP_MODELS=1; prices and context windows are stale"
elif [[ ! -f "$COSTS_SYNC" ]]; then
  echo "Model data: SKIPPED — $(basename "$COSTS_SYNC") is not in this kit; prices and context windows are stale" >&2
elif true; then
  echo
  echo "==> Refreshing model prices and context windows"
  MODELS_LOG="$(mktemp)" || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный журнал синхрона цен\n' >&2; exit 2; }
  # Пустой путь mktemp уходит ниже в перенаправление и в rm -f.
  [ -n "$MODELS_LOG" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь журнала синхрона цен пуст\n' >&2; exit 2; }
  # No pipe on the command itself: `python3 ... | grep` would report grep's exit
  # code and a failed sync would read as success. -u so that the two streams
  # land in the log in the order they were written.
  if python3 -u "$COSTS_SYNC" >"$MODELS_LOG" 2>&1; then
    grep -E '^(Backed up|Wrote) ' "$MODELS_LOG" || true
    echo "  (a running claude keeps the old numbers — the config is read once per process)"
    prune_config_backups
  else
    echo "WARNING: model sync failed; prices and context windows are unchanged."
    tail -3 "$MODELS_LOG" | sed 's/^/  /'
  fi
  rm -f "$MODELS_LOG"
fi

echo
echo "Done. Re-run this script after ANY of:"
echo "  * a Claude Code update      (bash $(basename "$0") --update)"
echo "  * running tweakcc's TUI or --apply (it restores from backup and drops our patches)"
echo "  * the proxy gaining a model (or just: bash $(basename "$0") --only-ours)"

# The probes read the rest of their posture from ~/.claude/probes/probes.toml.
# Its absence does NOT soften them: `enforce` is carried by the switch alone, and
# a machine without the settings file has no prompt file either, which the judge
# treats as not knowing its rules -- so it cancels every dispatch and names the
# missing file. Saying so here is the point: the state is loud, but a human who
# sets the switch before syncing the files meets a stopped fleet and no
# explanation of why. (`fail_closed` genuinely has no env carrier: a setting with
# two homes is the defect this kit checks for elsewhere.)
if [[ ! -f "${CLAUDE_PROBES_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/probes}/probes.toml" ]]; then
  echo
  echo "The probes have no settings file yet, and on such a machine the prompt"
  echo "files are missing too -- which is what makes CLAUDE_JUDGE=enforce CANCEL"
  echo "every dispatch (a missing prompt means the judge does not know its rules;"
  echo "a missing settings file by itself is not a degradation). Install both:"
  echo "  bash $(dirname "$0")/scripts/probes-sync.sh --to-home"
fi
# `.orig` is created by the installer, so it exists on the --update path only.
# The default and --target paths patch in place and leave tweakcc's own backup
# under ~/.tweakcc instead. Printing the cp unconditionally hands the reader a
# recovery step that fails exactly when they need it.
if [[ -f "$BIN.orig" ]]; then
  # Not `cp .orig over the live file`: that rewrites the inode a running session
  # is reading its embedded assets out of, and the two files differ in size, so
  # every offset inside moves under it. Same staging+rename the kit uses for its
  # own installs -- atomic, and it takes effect on the next launch.
  echo "Restore the pristine binary with:"
  echo "  cp -p \"$BIN.orig\" \"$BIN.restore\" && mv \"$BIN.restore\" \"$BIN\""
  echo "  (running sessions keep the old build until they are restarted)"
else
  echo "No pristine copy beside the binary; tweakcc keeps its own backup under $TWEAKCC_HOME."
  echo "  Check it before trusting it -- tweakcc restores it blind:"
  echo "    grep -c -a -F 'baseURL:/^claude/i.test(' $TWEAKCC_BACKUP"
  echo "  A non-zero count means the backup itself carries our patches."
  echo "  A zero count alone does NOT mean it is good: a TRUNCATED backup also"
  echo "  answers 0. Ask the second question the build asks -- does it run:"
  echo "    $TWEAKCC_BACKUP --version"
  echo "  A complete stock image prints a version; a truncated one does not."
fi

__DONE=1   # штатный конец: см. «Часовой оборванного прогона» выше
