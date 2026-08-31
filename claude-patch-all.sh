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
    echo "       если работы уже нет, замок держит осиротевший писатель. Кто именно:" >&2
    echo "         lsof $__lock" >&2
    echo "       Названного там процесса достаточно завершить -- замок отпустится сам." >&2
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
        if [[ -z "$__ostart" ]] \
           || [[ "$(LC_ALL=C ps -o lstart= -p "$__opid" 2>/dev/null)" == "$__ostart" ]]; then
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
OUR_PATCH="$HERE/tweakcc-patch.js"
INSTALLER="$HERE/claude_patch.py"
COSTS_SYNC="$HERE/set-model-costs.py"
BUNDLE_ID="com.anthropic.claude-code"

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
    base="$(basename "$f")"
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
      printf '%s\t%s\n' "$(stat -f '%m' "$entry" 2>/dev/null || stat -c '%Y' "$entry" 2>/dev/null || echo 0)" "$entry"
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
MISSING=()
for t in python3 curl tar perl script seq awk sed grep sort cmp shasum codesign; do
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
  BIN="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$TARGET")"
elif [[ $DO_UPDATE -eq 1 ]]; then
  echo "==> Installing a pristine Claude Code${UPDATE_VER:+ $UPDATE_VER}"
  BIN="$(python3 "$INSTALLER" --download-only ${UPDATE_VER:+$UPDATE_VER} | tail -1)"
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
)"
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
HANDED_SHA="$(sha_of "$BIN")"
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

python3 "$HERE/tools/image-check.py" "$BIN" || {
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
# (the interface gate, the probes, any of the pipeline's 119 checks) left the human
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
img_ver() { "$1" --version 2>/dev/null | awk 'NR==1{print $1; exit}'; }
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
  if [[ ! -f "$BIN.orig" ]]; then
    ORIG_STATE="missing"
  elif grep -q -a -F "$OUR_MARKER" "$BIN.orig" || grep -q -a -F 'tweakcc' "$BIN.orig"; then
    ORIG_STATE="not pristine"
  else
    LIVE_VER="$(img_ver "$BIN")"
    ORIG_VER="$(img_ver "$BIN.orig")"
    [[ -n "$LIVE_VER" && "$LIVE_VER" == "$ORIG_VER" ]] || ORIG_STATE="a twin of ${ORIG_VER:-an unreadable build}, not of $LIVE_VER"
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
    LIVE_VER="$(img_ver "$BIN")"
    ORIG_VER="$(img_ver "$BIN.orig")"
    if [[ -z "$LIVE_VER" || -z "$ORIG_VER" || "$LIVE_VER" != "$ORIG_VER" ]]; then
      echo "ERROR: $BIN.orig is not a pristine copy of the live build." >&2
      echo "  live=${LIVE_VER:-unreadable}  pristine copy=${ORIG_VER:-unreadable}" >&2
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
  SOURCE_SHA="$(sha_of "$BIN")"
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
PRISTINE_SRC="${BIN%.staging}.orig"

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
echo "==> Разбор вклеиваемого кода"
node "$(dirname "$0")/tools/emit-check.js" || {
  __rc=$?
  if [[ $__rc -eq 2 ]]; then
    echo "FATAL: разбор НЕ ВЫПОЛНЕН: прибор не может мерить (якорь/строка пропали, rc=2)." >&2
    echo "  Это не «код не парсится» -- покрытие снято, причина выше." >&2
    exit 2
  fi
  exit 1
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
import glob, io, os, re, sys, warnings

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
# Якорь начала: строка НАЧИНАЕТСЯ с вызова python3 -- упоминание тех же
# слов внутри кода (как в этой строке) под якорь не подходит.
# Строка обязана КОНЧАТЬСЯ открытием heredoc: так под якорь попадает и форма
# внутри подстановки (BIN="$(python3 - <<'PY'), и не попадают упоминания тех
# же слов в коде и комментариях -- как эта строка. Круг 28, F-13 добавил
# ЕДИНСТВЕННОЕ послабление -- закрытый список управляющих продолжений
# (`; then`, `; do`, `; fi`, `; else`, `; done`, `; esac`): живая форма
# `if ! python3 - "$X" <<'MUTX'; then` под старый якорь не подходила ВООБЩЕ,
# и её питоновское тело не проверял никто. ЗАЩИТА КОНЦА СТРОКИ ЭТИМ НЕ
# СНИМАЕТСЯ: произвольный текст после тега (строки-примеры в комментариях
# и коде) отсекается, как и прежде.
opener = re.compile(r"^[^#]*\bpython3\b[^|;&]*<<'([A-Za-z_][A-Za-z0-9_]*)'"
                    r"(?:\s*;\s*(?:then|do|fi|else|done|esac))?\s*$")

# ЗУБЫ НА ЯКОРЬ (круг 28, F-13). Сужение якоря -- например, возврат к «кончается
# открытием без хвостов» -- снова оставило бы форму `; then` невидимой, и
# никакой прогон этого не заметил бы: гейт, не видящий тела, выглядит ровно
# как гейт, который его проверил. Синтетика с известным ответом краснит
# такое сужение сама, ДО всякого обращения к дереву.
for _line, _want in (
    ('if ! python3 - "$PIPELINE" "$mut" <<\'MUTX\'; then', True),
    ('  python3 - "$X" <<\'PY\'', True),
    ('BIN="$(python3 - <<\'PY\'', True),
    ('# пример: python3 - <<\'PY\' и текст', False),
    ('echo "python3 - <<\'PY\'"', False),
    ('python3 - <<\'X\'; echo done', False),
):
    if bool(opener.match(_line)) is not _want:
        print("ЯКОРЬ HEREDOC ПОТЕРЯЛ ФОРМУ: ожидалось "
              + ("принять" if _want else "отвергнуть") + f": {_line!r}")
        sys.exit(1)


def scan_heredocs(lines, where):
    """Все питоновские heredoc'и одного файла; (число, виден ли блок проверок)."""
    count, saw, i = 0, False, 0
    while i < len(lines):
        m = opener.match(lines[i])
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

# Правило 3: EXIT-трап без часового завершения.
#
# bash 3.2 (единственный на этой машине) отдаёт код 0, когда скрипт с
# EXIT-трапом умирает на фатальной ошибке ПОДСТАНОВКИ (unbound variable под
# `set -u`, `${x:?}`, bad substitution): трап исполняется, `$?` внутри него --
# ноль, и вызывающий видит успех вместо оборванного прогона. Измерено
# 2026-08-28 на зонде, который так «зеленел» посреди таблицы. Лечится только
# ЧАСОВЫМ: штатный конец объявляет себя (`__DONE=1`), трап без объявления
# краснит сам. Правило файловое, а не строчное: трап и часовой стоят в разных
# местах файла.
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

bad = []
scanned = 0
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
        if sentinel_missing(text):
            bad.append(f"{os.path.relpath(f, root)}: EXIT-трап без часового "
                       f"завершения -- обрыв на ошибке подстановки вернёт 0")
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
if bad:
    print("ФОРМЫ ОБОЛОЧКИ, КОТОРЫЕ МОЛЧАТ:")
    for b in bad:
        print("  " + b)
    sys.exit(1)
print(f"ФОРМЫ ОБОЛОЧКИ ЧИСТЫ: разобрано файлов {scanned}")
SHVARS

echo "==> Стенд инструментов судьи"
python3 "$(dirname "$0")/tools/judge-tools-bench.py" || {
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
python3 "$(dirname "$0")/tools/judge-tools-bench.py" --self-check || {
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
echo "==> Стенд моделей и цен"
python3 "$(dirname "$0")/tools/costs-bench.py" || {
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
python3 "$(dirname "$0")/tools/costs-bench.py" --self-check || {
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
echo "==> Стенд синхронизации проб"
bash "$(dirname "$0")/tools/probes-sync-bench.sh" || {
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
bash "$(dirname "$0")/tools/probes-sync-bench.sh" --self-check || {
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

# --- раскатка судейских инструментов: исполняются ТЕ ЖЕ байты, что заверены ----
# Стенд выше сертифицирует КАНОН: tools/judge-tools-bench.py читает judge/*.py
# ЭТОГО дерева. А launchd гоняет РАСКАТАННУЮ копию из ~/.claude/judge, и ядро
# читает раскатанные настройки и промты. Пока у сверки не было ни одного
# автоматического вызывающего (рецепт в хвосте конвейера человек читает раз в
# жизни), дом отстал от канона на семь волн и продолжал исполняться -- заметил
# только аудит (круг 20, D-1). Тест-ручки домов снимаются: гейт меряет
# НАСТОЯЩИЙ дом, а не тот, что назвало окружение оператора.
echo "==> Раскатка инструментов судьи"
env -u CLAUDE_JUDGE_TOOLS_DIR -u CLAUDE_LAUNCH_AGENTS_DIR \
  bash "$(dirname "$0")/scripts/probes-sync.sh" --diff || {
  __rc=$?
  case $__rc in
    5) echo "РАСКАТКИ НЕТ: на этой машине не заведено ни одного файла — пропуск (rc=5)" ;;
    2) echo "СВЕРКА РАСКАТКИ НЕ ИЗМЕРЯЛА: контракт вызова (rc=2)" >&2
       exit 2 ;;
    *) echo "РАСКАТКА РАСХОДИТСЯ С КАНОНОМ (rc=$__rc): launchd и ядро исполняют" >&2
       echo "  не те байты, что заверил стенд. Починка:" >&2
       echo "  bash $(dirname "$0")/scripts/probes-sync.sh --to-home" >&2
       exit 1 ;;
  esac
}

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
import ast, io, os, re, sys, glob

here = os.path.dirname(os.path.abspath(sys.argv[1]))
read = lambda p: io.open(p, encoding='utf-8').read()

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
    out, block = [], False
    for line in text.split('\n'):
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
            if stripped.startswith('#'):
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
echo "==> Зубы гейта чисел"
python3 "$(dirname "$0")/tools/docnum-bench.py" || {
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
CATALYST_TWEAKCC_SHA="${CATALYST_TWEAKCC_SHA:-a89c9dae9bbd35979f66afd18908a4c9bffa82b0}"
# Подменённый источник распаковщика объявляется ВСЕГДА, а не только когда его
# качают: строка «Fetching the unpacker» печатается лишь мимо кэша, и сборка с
# чужой веткой в тёплом кэше была неотличима от сборки с запиненной.
[[ "$CATALYST_TWEAKCC_REPO" == "TransmuteLabs/Catalyst-tweakcc" \
   && "$CATALYST_TWEAKCC_SHA" == "a89c9dae9bbd35979f66afd18908a4c9bffa82b0" ]] \
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
ensure_tweakcc

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
  if [[ -f "$PRISTINE_SRC" ]] \
     && ! grep -q -a -F "$OUR_MARKER" "$PRISTINE_SRC" \
     && ! grep -q -a -F 'tweakcc' "$PRISTINE_SRC"; then
    SRC_VER="$("$PRISTINE_SRC" --version 2>/dev/null | awk 'NR==1{print $1; exit}')"
    BLD_VER="$("$BIN" --version 2>/dev/null | awk 'NR==1{print $1; exit}')"
    [[ -n "$SRC_VER" && "$SRC_VER" == "$BLD_VER" ]] && BACKUP_OK=1
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
    echo "  verified-pristine copy of THIS build is available to repair it from" >&2
    echo "  ($PRISTINE_SRC is missing, patched, tweakcc-staged, or another version)." >&2
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
    TGT_VER="$( { "$BIN" --version 2>/dev/null || true; } | awk 'NR==1{print $1; exit}')"
    if [[ ! "$TGT_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
      echo "FATAL: the target does not name its version, so what tweakcc is about to" >&2
      echo "  do with it cannot be established." >&2
      echo "  target: $BIN" >&2
      echo "  --version gave: '${TGT_VER:-<nothing>}'" >&2
      echo "  tweakcc restores its backup over the target before patching, and whether" >&2
      echo "  it does depends on this version. Refusing to build blind: the image that" >&2
      echo "  would be shipped may not be the one you named." >&2
      exit 1
    fi
    CFG_VER="$(python3 -c 'import json,sys
try:
    v = json.load(open(sys.argv[1], encoding="utf-8")).get("ccVersion")
except Exception:
    v = None
print(v if isinstance(v, str) else "")' "$TWEAKCC_CFG" 2>/dev/null || true)"
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
      TWEAKCC_RESTORE_PINNED="$(shasum -a 256 "$TWEAKCC_BACKUP" | awk '{print $1}')"
    fi
  fi
  # A non-zero --list-patches meant "skip the apply", silently and with every
  # byte of its output discarded. But that subcommand failing does not imply the
  # apply would fail: a tweakcc that cannot parse its config, or that dropped
  # this subcommand, still patches. Skipping the entire third-party stage
  # without saying why leaves a build carrying none of those patches and a
  # perfectly clean `Done.` -- the same silence the rest of this block exists to
  # end, one level up.
  TWEAKCC_LIST_OUT="$(mktemp)"
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
    TWEAKCC_OUT="$(mktemp)"
    set +e
    "${TWEAKCC[@]}" --apply -y 2>&1 | tee "$TWEAKCC_OUT"
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
    __tw_saved=$(sed -n 's/^Configuration saved at: //p' "$TWEAKCC_OUT" | tail -1)
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
      echo "NOTE: tweakcc --apply exited $TWEAKCC_RC; CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 is set, continuing with ours only." >&2
    elif [[ "${CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES:-0}" != "1" ]] \
         && ! grep -qE '^    [✓✗] ' "$TWEAKCC_OUT"; then
      # The failure detector below is a one-sided text anchor on another
      # program's human-facing output: a glyph, an indent, an English phrase.
      # If any of those drift, `grep -q '✗'` finds nothing and the build is
      # declared good -- the very "clean skip renders the stock interface and
      # passes" hole the interface gate was added to close, reopened from the
      # other end. So require the positive counterpart first: if we cannot see a
      # single row of EITHER kind, we did not read the output at all, and the
      # absence of a ✗ proves nothing.
      echo "FATAL: could not read tweakcc's apply output -- no result rows found." >&2
      echo "  Either no patches are configured, or its output format changed and" >&2
      echo "  the failure check below is now blind. Inspect: $TWEAKCC_OUT" >&2
      echo "  Set CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 to build anyway." >&2
      exit 1
    elif [[ "${CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES:-0}" == "1" ]] \
         && grep -qE '^    ✗ |applied with some failures' "$TWEAKCC_OUT"; then
      # The hatch is legitimate -- it exists for building against a version where
      # something is known not to apply yet -- but it must not be invisible. It
      # only ever announced itself in the non-zero-exit branch, so a build where
      # tweakcc exited 0 with a ✗ row went out with a patch missing and nothing
      # in the log to say a gate had been turned off.
      echo "NOTE: CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 — these tweakcc patches did NOT apply:" >&2
      grep -E '^    ✗ ' "$TWEAKCC_OUT" | sed 's/^ */  /' >&2
    elif [[ "${CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES:-0}" != "1" ]] \
         && grep -qE '^    ✗ |applied with some failures' "$TWEAKCC_OUT"; then
      echo "FATAL: a configured tweakcc patch did not apply:" >&2
      grep -E '^    ✗ ' "$TWEAKCC_OUT" | sed 's/^ */  /' >&2
      grep -E '^patch: ' "$TWEAKCC_OUT" | sed 's/^/  /' >&2
      echo "  Set CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 to build anyway." >&2
      rm -f "$TWEAKCC_OUT"
      exit 1
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
# ни одна из 119 проверок конвейера ниже этого не заметит: они пинят наш
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

# --- 4. signature (must be last: both steps above sign ad-hoc) ---------------
if [[ "$(uname -s)" == "Darwin" ]]; then
  SIGN_ID="${CLAUDE_PATCH_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk 'NR==1{print $2}')}"
  if [[ -n "$SIGN_ID" && "$SIGN_ID" != "valid" ]]; then
    codesign -f -i "$BUNDLE_ID" -s "$SIGN_ID" "$BIN"
    echo "Re-signed with $SIGN_ID (bundle id $BUNDLE_ID)"
  else
    echo "WARNING: no code-signing identity found — keychain OAuth will NOT work."
  fi
fi

# --- 5. verify ---------------------------------------------------------------
echo "==> Verifying"
python3 - "$BIN" "$OUR_PATCH" <<'PY'
import re, sys
d = open(sys.argv[1], 'rb').read()
src = open(sys.argv[2], encoding='utf-8').read()
ID = rb'[A-Za-z_$][\w$]*'

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


def _probe_uses_the_images_own_names(full):
    """The probe's free names must be the image's own bindings, byte for byte.

    They are spliced into the block as text. While the injection still went
    through String.replace, a `$` in a minified name had to be doubled or it
    would have read as a group reference; the injection later moved to a plain
    offset splice and the doubling stayed behind. On 2.1.242/243/245 the
    single-shot query engine is called `$A`, so the block asked for `$$A` --
    a name bound to nothing. `typeof` does not throw on an unbound name, so the
    judge fell back to raw HTTP and said so nowhere: the channel changed lanes
    on a third of the supported range while every shape check passed, because
    `$$A` is a perfectly well-formed identifier.

    Shape is therefore not enough here. Each name is compared against the site
    the image itself defines it at, with the probe's own blocks cut out first so
    a name cannot be confirmed by the very text under test.
    """
    blocks = re.findall(rb'/\*__ccProbe0\*/[\s\S]*?/\*__ccProbe1\*/', full)
    if len(blocks) != 2:
        return False
    rest = full
    for b in blocks:
        rest = rest.replace(b, b'', 1)

    pool = re.search(rb'let __pool=typeof (' + ID + rb')==="function"', blocks[0])
    engine = re.search(rb'async function (' + ID + rb')\(\{messages:' + ID +
                       rb',systemPrompt:' + ID + rb',thinkingConfig:', rest)
    if not pool or not engine or pool.group(1) != engine.group(1):
        return False
    # Both copies of the core ask for the same engine, or they are not one core.
    if re.search(rb'let __pool=typeof (' + ID + rb')==="function"', blocks[1]).group(1) != pool.group(1):
        return False

    watch = [b for b in blocks if b'tag:"[Watch]"' in b]
    if len(watch) != 1:
        return False
    queue = re.search(rb'onAct:async\(__r,__svc\)=>\{try\{(' + ID + rb')\(\{value:', watch[0])
    session = re.search(rb'agentId:(' + ID + rb')\(\),priority:"next"', watch[0])
    # Upstream spells the same call with `mode` first, so this cannot match our
    # own text even before the blocks are cut out.
    upstream = re.search(rb'(?:^|[^.\w$])(' + ID + rb')\(\{mode:"task-notification",agentId:(' +
                         ID + rb')\(\)', rest)
    if not (queue and session and upstream):
        return False
    return queue.group(1) == upstream.group(1) and session.group(1) == upstream.group(2)


def _effort_binding_reaches_the_launch(d):
    """The effort name is declared by one edit and read by another.

    Patch 12 destructures `effort:__ccEffort` in the dispatch tool's parameter
    pattern, and reads it again at the launch-definition site -- a different
    splice, tens of kilobytes away. That only holds while both sites are in ONE
    function body: a name bound by a parameter list is invisible to a sibling
    function, and the failure would be a ReferenceError on every dispatch. It
    is the same shape that cost the watcher its journal line one scope over,
    and nothing asserted it here.

    Measured, not argued: string literals are blanked first, so a brace inside
    a message cannot close a function that is still open.
    """
    if d.count(b'async call(__ccIn') != 1:
        return False
    start = d.find(b'async call(__ccIn')
    use = d.find(b'__ccRaw=typeof __ccEffort')
    if use < 0 or use < start:
        return False
    body = d.find(b'{', d.find(b')', start))
    if body < 0 or body > use:
        return False
    region = d[body:use]
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
            if depth == 0:
                return False
    return depth > 0

def _strip_strings(b):
    # Same length, no punctuation carried over from inside a literal: the walk
    # below counts braces and semicolons, and a message that contains one would
    # end a declaration list that has not ended.
    return re.sub(rb'"(?:[^"\\]|\\.)*"',
                  lambda m: b'"' + b'.' * (len(m.group(0)) - 2) + b'"', b)


def _decl_list(b, i, names):
    """Collect a whole declaration LIST starting just past let/const/var.

    `let __now=…,__w=…,__th=…` binds every name in it. A reader that takes only
    the first calls the rest undeclared -- which is exactly what the JS-side
    stand did on its first run, reporting six names out of one chain.
    """
    depth, expect, n = 0, True, len(b)
    while i < n:
        c = b[i:i + 1]
        if c in b'([{':
            depth += 1; i += 1; continue
        if c in b')]}':
            if depth == 0:
                break
            depth -= 1; i += 1; continue
        if depth == 0:
            if c == b';':
                break
            if c == b',':
                expect = True; i += 1; continue
            if not c.isspace():
                if expect:
                    m = re.match(rb'[A-Za-z_$][\w$]*', b[i:])
                    if m:
                        names.add(m.group(0)); i += m.end(); expect = False; continue
                expect = False
        i += 1
    return i


def _core_head_declared(d):
    """Every name in scope at the top of the core body, read from the code.

    Not a fixed-size window. The window form ended at a fixed byte distance and
    everything past it had to be hand-listed -- `__jlog` had in fact been
    written into this check by a human. A list a human maintains stops matching
    the code the first time nobody remembers to extend it, and the check goes
    on passing.
    """
    blk = re.search(rb'/\*__ccCore0\*/(.*?)/\*__ccCore1\*/', d, re.S)
    if not blk:
        return None
    b = _strip_strings(blk.group(1))
    m = re.search(rb'globalThis\.__ccProbe\?\?=async function\((__\w+)\)\{', b)
    if not m:
        return None
    names = {m.group(1)}
    i, depth, n = m.end(), 0, len(b)
    while i < n:
        c = b[i:i + 1]
        if c in b'([{':
            depth += 1; i += 1; continue
        if c in b')]}':
            if depth == 0:
                break
            depth -= 1; i += 1; continue
        if depth == 0:
            if b[i:i + 4] == b'try{':
                break
            km = re.match(rb'(?:let|const|var)\s+', b[i:i + 8])
            if km:
                i = _decl_list(b, i + km.end(), names); continue
        i += 1
    return names


def _judge_catch_scope(d):
    # The judge's failure path runs only when something is broken, so a typo in
    # it lives unnoticed: the name __pdir was read from a neighboring block and
    # crashed with ReferenceError BEFORE the journal write — the dispatch got
    # "__pdir is not defined", the journal got nothing. The check is
    # structural: every name the catch reads must be declared ABOVE the try.
    declared = _core_head_declared(d)
    if declared is None:
        return False
    blk = re.search(rb'/\*__ccCore0\*/(.*?)/\*__ccCore1\*/', d, re.S)
    body = _strip_strings(blk.group(1))
    c = re.search(rb'\}\}catch\(__e\)\{if\(__e&&__e\.__ccJudgeBlock\)throw __e;(.{0,1400}?)\}\}',
                  body, re.S)
    if not c:
        return False
    cb = c.group(1)
    local = set(re.findall(rb'let (__\w+)', cb)) | {b'__e'}
    # A name behind a dot is a property, not a binding: `__e.__ccJudgeBlock`
    # asks nothing of this scope.
    used = {m.group(1) for m in re.finditer(rb'(?<![.\w$])(__\w+)', cb)}
    return not (used - declared - local)

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
    # There is a THIRD legitimate defence beside the two escapers, and it is the
    # stricter one: siteName does not transform the name, it REFUSES a name that
    # would be transformed -- so what reaches the image is either the image's own
    # name, verbatim, or nothing at all (the build stops). That only holds for a
    # REPLACEMENT string, whose dangerous syntax siteName enumerates. In a regex
    # SOURCE the danger is different -- there a bare `$` is the end-of-line
    # anchor, and `$A` is a perfectly acceptable name to siteName while being a
    # pattern that cannot match. So siteName counts for js.replace and never for
    # new RegExp.
    refused = set(re.findall(r'const (\w+) = siteName\(', src))
    names = _captured_names(src)
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
        return (a[1:2] if literal else a[:2])

    for m in re.finditer(r'new RegExp\s*\(', src):
        for slot in slots(m.end() - 1, 'regexp'):
            bad += [x for x in names if '${%s}' % x in slot]

    for m in re.finditer(r'\.replace\s*\(', src):
        for slot in slots(m.end() - 1, 'replace'):
            bad += [x for x in names if '${%s}' % x in slot and x not in refused]

    return not bad

def _judge_both_shapes(src):
    # Reads the PATCH SOURCE, not the image, and its name now says so. Only ONE
    # dispatcher shape exists in any given payload, so no image can testify that
    # the other branch survives; what this guards is a branch being deleted from
    # the locator, which would go unnoticed until a version that needs it. The
    # shape actually present IS verified against the image, by
    # _judge_rides_the_tool, which builds its tail out of that call's own names.
    #
    # 2.1.239 moved the tool call behind an adapter: `e.call(w,ctx,…)` became
    # `hii(e).execute(w,ctx,…)`, where `hii(e) = e.executor ?? {execute:…}`.
    # The judge locator must hold BOTH shapes and latch onto the tool itself,
    # not the wrapper: the tool has `.name`, the adapter does not.
    i = src.find("step('22 judge consulted")
    j = src.find("step('23", i)
    blk = src[i:j] if i >= 0 and j > i else ''
    return (r'\\.call|' in blk) and (r'\\)\\.execute' in blk) and ('m[2] ?? m[3]' in blk)

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

    The predicate half is checked POSITIVELY. Absence of the gated shape alone
    cannot tell "forced" from "reshaped upstream", and the second reads as
    success while session memory stays off -- the same one-sided weakness this
    docstring warns about for flag names. The end state is exactly one function
    of the forced shape `function X(){return!Y()||Z("tengu_...",!1)}`: the flag
    guard gone, the product's own interactivity condition kept. Measured on
    pristine 2.1.233 / 240 / 242 / 246: gated shape 1, forced shape 0.
    """
    anchor = b'querySource:"extract_memories",forkLabel:"extract_memories"'
    at = d.find(anchor)
    if at == -1:
        return False
    window = d[at:at + 8000]
    if re.search(rb'if\(!' + ID + rb'\("tengu_[a-z0-9_]+",!1\)\)\s*return[^;]*;', window):
        return False
    predicate = (rb'function ' + ID + rb'\(\)\{if\(!' + ID + rb'\("tengu_[a-z0-9_]+",!1\)\)return!1;'
                 rb'return!' + ID + rb'\(\)\|\|' + ID + rb'\("tengu_[a-z0-9_]+",!1\)\}')
    if re.search(predicate, d):
        return False
    forced = (rb'function ' + ID + rb'\(\)\{return!' + ID + rb'\(\)\|\|'
              + ID + rb'\("tengu_[a-z0-9_]+",!1\)\}')
    return len(re.findall(forced, d)) == 1


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
    # 1. The STOCK two-argument call must be gone in its exact shape.
    if re.search(rb'\?' + ID + rb'\(' + ID + rb'\.decisionReason,' + ID + rb'\):void 0;', d):
        return False
    # 2. The narrowed predicate must stand in its place -- absence of the stock
    #    shape alone cannot tell "narrowed" from "branch deleted outright", and
    #    the second is what this check previously accepted.
    if not re.search(
        rb'\?' + ID + rb'\(' + ID + rb'\.decisionReason,\(__ccbr\)=>'
        rb'__ccbr\.circuitBreaker!=="dangerousRemoval"&&' + ID + rb'\(__ccbr\)\):void 0;', d):
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
    return len(re.findall(
        rb'\|\|' + ID + rb'\?void 0:process\.env\.ANTHROPIC_VERTEX_PROJECT_ID', d)) == 1

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

def _judge_rides_the_tool(d):
    """The judge must sit inside the dispatch tool, the watcher on the dispatcher.

    An earlier form of this check counted DISPATCHERS and required a probe in
    front of each. That was the wrong invariant twice over: the executor it
    named as the second one cannot receive a dispatch at all (the sandbox's
    tool list is built by a filter that drops the dispatch tool by name), and
    the census it rested on was not complete anyway -- `claude mcp serve`
    exposes the same tool through a third executor. A mechanism that fails
    CLOSED cannot be anchored to a number that upstream is free to change, so
    the judge now rides the one thing every executor must go through: the
    tool's own `call`.

    What is asserted here:

      * the judge block is inside that method, and the parameter pattern the
        original signature destructured moved into the body intact;
      * `$2` at that site is `this` -- the tool, not a literal we made up;
      * the watcher block is in front of the main dispatch call, with all four
        of its names bound to that call's own;
      * neither consumer appears at the other's site (one judgement per
        dispatch, one heartbeat per tool call);
      * the two cores are byte-identical.
    """
    ends = [mm.end() for mm in re.finditer(rb'/\*__ccProbe1\*/', d)]
    starts = [mm.start() for mm in re.finditer(rb'/\*__ccProbe0\*/', d)]
    if len(ends) != 2 or len(starts) != 2:
        return False
    # `.index` would RAISE on a block whose core marker is gone, and an
    # exception in this dict aborts the whole verify stage -- no verdicts at
    # all, which reads as a pipeline bug rather than as the failed check it is.
    # Every lookup here answers False instead.
    core_end = [d.find(b'/*__ccCore1*/', st) for st in starts]
    if any(c < 0 for c in core_end) or any(c > e for c, e in zip(core_end, ends)):
        return False
    cores = [d[st:c] for st, c in zip(starts, core_end)]
    if len(set(cores)) != 1 or len(cores[0]) < 15000:
        return False

    # Волна 31 (K-3): потребитель-судья опознаётся по своему
    # типизированному выключателю (сырая истинность строки ушла вместе с
    # `CLAUDE_JUDGE=0`); наблюдатель несёт такой же читатель для
    # CLAUDE_IDLE -- в блоке судьи его нет, и наоборот.
    JUDGE = (rb'String\(process\.env\.CLAUDE_JUDGE\?\?""\)\.trim\(\)\.toLowerCase\(\);'
             rb'return !\(__s===""\|\|__s==="0"\|\|__s==="false"\|\|__s==="off"\|\|__s==="no"\)\}\)\(\)')
    WATCH = rb'globalThis\.__ccFleet\?\?=\[\];'
    judge_sites = [i for i, (c, e) in enumerate(zip(core_end, ends))
                   if re.search(JUDGE, d[c:e])]
    watch_sites = [i for i, (c, e) in enumerate(zip(core_end, ends))
                   if re.search(WATCH, d[c:e])]
    if len(judge_sites) != 1 or len(watch_sites) != 1 or judge_sites == watch_sites:
        return False

    # The judge's home: the tool's own call, with the pattern re-bound in the
    # body and `this` as the tool.
    ji = judge_sites[0]
    head = d[max(0, starts[ji] - 400):starts[ji]]
    if not re.search(rb'async call\(__ccIn,' + ID + rb'[^)]*\)\{let \{prompt:' + ID
                     + rb',subagent_type:' + ID + rb',description:' + ID + rb',model:'
                     + ID + rb',[^{}]*\}=__ccIn;$', head):
        return False
    body = d[core_end[ji]:ends[ji]]
    if body.count(b'this.name==="Agent"||this.name==="Task"') != 1:
        return False
    if b'tool:this,input:__ccIn,ctx:' not in body:
        return False

    # The watcher's home: in front of the main dispatch call, every name bound
    # to that call's own. Normalising the names would only prove they are used
    # consistently INSIDE the block; building the tail out of them is what
    # proves they are the right ones.
    wi = watch_sites[0]
    wb = d[core_end[wi]:ends[wi]]
    b4 = re.search(rb'tool:(' + ID + rb'),input:(' + ID + rb'),ctx:(' + ID
                   + rb'),key:(' + ID + rb'),', wb)
    if not b4:
        return False
    tool, inp, ctx, key = (re.escape(b4.group(i)) for i in (1, 2, 3, 4))
    tail = d[ends[wi]:ends[wi] + 400]
    if not re.match(ID + rb'=await (?:' + tool + rb'\.call|' + ID + rb'\(' + tool
                    + rb'\)\.execute)\(' + inp + rb',\{\.\.\.' + ctx
                    + rb',toolUseId:' + key + rb',userModified:' + ID
                    + rb'\.userModified\?\?!1\},', tail):
        return False
    return True


# Every check below that COUNTS occurrences counts them per emitted copy: the
# numbers were measured when the injected text existed once, and they say
# something about the SHAPE of the probe, not about how many places carry it.
# The judge and the watcher live at different sites now and each appears once,
# so their numbers stand as calibrated; what is emitted twice is the CORE they
# share, because neither site can rely on the other having run first. `??=`
# makes the second copy inert at runtime, and the collapse below makes it
# absent from the text the counts are taken over. Removal only takes text away,
# which is why the site check above runs on the UNCOLLAPSED bytes -- an
# "is absent" count is exactly the shape that removal makes more likely to
# pass, so nothing that must be PRESENT may be verified after this point.
def _turn_belongs_to_the_judge(d):
    """The current-turn stash must be consumed by the judge and by nobody else.

    Step 21 fills a map keyed by tool_use id so the judge can see the thinking
    that motivated a dispatch -- in streaming, the message that reaches the
    executor carries the tool_use block alone. Its contract is single-consumer:
    an entry goes away when the judge reads it.

    The read used to live in the SHARED core, so whichever consumer ran the
    core first took the entry. That was invisible while both consumers sat in
    one block with the judge written first; it stopped being true the moment
    they moved to different sites, and the watcher -- which has no use for a
    turn -- would have emptied it before the judge was reached. Nothing would
    crash and nothing would be refused: the judge would simply reason without
    the turn, on the first dispatch of a session and on every watcher window
    after it. So ownership is asserted in the text rather than left to splice
    order.
    """
    starts = [mm.start() for mm in re.finditer(rb'/\*__ccProbe0\*/', d)]
    ends = [mm.end() for mm in re.finditer(rb'/\*__ccProbe1\*/', d)]
    if len(starts) != 2 or len(ends) != 2:
        return False
    core_end = [d.find(b'/*__ccCore1*/', st) for st in starts]
    if any(c < 0 for c in core_end) or any(c > e for c, e in zip(core_end, ends)):
        return False
    # no core may touch the map, and each must take the turn from its caller
    for st, c in zip(starts, core_end):
        if b'__ccJudgeTurn' in d[st:c]:
            return False
        if d.count(b'let __t=__o.turn?__o.turn():[];', st, c) != 1:
            return False
    # exactly one consumer supplies a turn, and it is the one carrying the judge
    suppliers = [i for i, (c, e) in enumerate(zip(core_end, ends))
                 if b'turn:()=>{' in d[c:e]]
    judges = [i for i, (c, e) in enumerate(zip(core_end, ends))
              if re.search(rb'String\(process\.env\.CLAUDE_JUDGE\?\?""\)\.trim\(\)\.toLowerCase\(\);'
                           rb'return !\(__s===""\|\|__s==="0"\|\|__s==="false"\|\|__s==="off"\|\|__s==="no"\)\}\)\(\)', d[c:e])]
    if suppliers != judges or len(suppliers) != 1:
        return False
    c, e = core_end[suppliers[0]], ends[suppliers[0]]
    blk = d[c:e]
    key = re.search(rb'turn:\(\)=>\{let __x=globalThis\.__ccJudgeTurn\?\.get\((' + ID
                    + rb'(?:\.' + ID + rb')?)\);'
                    rb'globalThis\.__ccJudgeTurn\?\.delete\(\1\);return __x\|\|\[\]\},', blk)
    if not key:
        return False
    # the turn is fetched under the SAME key the record and journal use, or the
    # judge would read one dispatch's thinking while filing it under another
    return b'key:' + key.group(1) + b',' in blk


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

def _record_name_is_unique(d):
    """One consultation, one record file -- on every route, not only the ones with an id.

    `rec` is the join key between the journal and the corpus: judge/validate.py
    indexes labels by that basename and adjudicate.py matches on it. Two
    consultations sharing a name therefore do not merely overwrite a file, they
    merge two different judgements under one label -- and the data does not say
    it happened.

    The name cannot get that guarantee from the tool-use id, because the id is
    not something every route has: `claude mcp serve` calls the dispatch tool
    with a context built as `agentContext:{agentType:"main",agentId:...}` and no
    `toolUseId` field, so the key is undefined for that whole route. The judge
    meets that route by construction -- it rides the tool exactly so no executor
    can slip past it.

    Asserted here: the name is still derived from the key, so the correlation
    survives; the keyless case is NAMED rather than stringified into "ndefined";
    and the two separators of last resort are present -- the pid, and a counter
    incremented exactly once per record. Replacing the key with a constant, or
    dropping either separator, turns this red.
    """
    if not re.search(rb'let __n=__ts\.replace\(/\[:\.\]/g,"-"\)\+"-"'
                     rb'\+\(__o\.key==null\?"nokey":String\(__o\.key\)\.slice\(-8\)\)'
                     rb'\+"-"\+process\.pid\+"-"'
                     rb'\+String\(__seq\)\.padStart\(6,"0"\)\+"\.json"', d):
        return False
    # After the collapse above there is ONE core, so one counter line. Two would
    # mean the cores drifted; none, that the guarantee was edited away.
    return d.count(b'let __seq=globalThis.__ccRecSeq=(globalThis.__ccRecSeq??0)+1;') == 1

def _consumer_uses_no_core_privates(full):
    """The consumer half of a probe block must not name the core's privates.

    The core is a closed function assigned to globalThis; each consumer's call
    is spliced into the scope of ITS site. Anything the core declares is
    invisible there, so a bare `__jlog` in a consumer is a free variable that
    throws ReferenceError the moment that line runs -- and the lines in
    question are failure handlers. That is how the watcher lost its
    `nudge_undelivered` record: present in the text, unreachable in fact,
    swallowed by its own catch{}. The pre-build stand now resolves scopes
    exactly; this is its counterpart on the FINISHED image, where the text is
    the only evidence left.

    Checked on the pre-collapse payload, so both blocks are seen. What the core
    owns crosses the boundary as an argument -- hence the positive half: the
    watcher's queueing failure must reach the journal through the handed-over
    services, not by a name it cannot see.
    """
    blocks = re.findall(rb'/\*__ccProbe0\*/[\s\S]*?/\*__ccProbe1\*/', full)
    if len(blocks) != 2:
        return False
    for b in blocks:
        i = b.find(b'/*__ccCore1*/')
        if i < 0:
            return False
        tail = b[i:]
        for private in (b'__jlog', b'__clip', b'__jdir', b'__jarm', b'__deg', b'__t0'):
            if private in tail:
                return False
    return bool(re.search(rb'catch\(__ne\)\{try\{await __svc\.log\(\{'
                          rb'outcome:"nudge_undelivered",reason:__svc\.clip\(', full))

def _bom_stripped_in_our_blocks(d):
    """Our four BOM strips, counted INSIDE our blocks -- not in the whole image.

    The old form counted `^\\uFEFF/,""` across the file and asked for `>= 2`.
    Stock images carry the same idiom on their own: 3 occurrences in 2.1.233 and
    2.1.240, 4 in every version from 2.1.242 on. The threshold sat BELOW that
    floor, so the check was green on an image with none of our patches at all,
    and byte-neutrally replacing all four of ours (measured 2026-08-28) left the
    whole registry green -- including the check named for exactly that property.

    A count is only ours if it is scoped to our blocks, the way the neighbouring
    checks do it. Two blocks (judge and observer), two strips each: the judge's
    verdict text and the observer's, both of which arrive as provider answers
    that may start with a BOM.

    Reads `_probe_full`, NOT `d`: `d` has every duplicate of the shared core
    removed, and the strips live in that core -- so on `d` the second block is
    empty of them by construction and the check would refuse a perfectly good
    build.
    """
    blocks = re.findall(rb'/\*__ccProbe0\*/[\s\S]*?/\*__ccProbe1\*/', d)
    if len(blocks) != 2:
        return False
    return all(len(re.findall(rb'\^\\uFEFF/,""', b)) == 2 for b in blocks)


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
    """Both sites, by their consequents.

    Absence of the stock phrase looks like the obvious test and is not available:
    the refusal text lives in the image's STRING POOL, not only in the code that
    reads it, so neutralising the branch leaves the sentence in the file forever
    (measured on every version -- `root/sudo privileges` is present in the pool of
    each patched image). Requiring its absence could therefore never pass.

    What the step actually does is turn each consequent into `void 0`, at TWO
    sites: the bypass-option guard and the setup path. Requiring both is what
    makes this mean something -- one alone would go green with the other refusal
    still alive.
    """
    guarded = re.search(rb'if\(' + ID + rb'\.isRootOutsideDeliberateSandbox\(\)\)void 0', d)
    setup = re.search(rb'process\.getuid\(\)===0&&process\.env\.IS_SANDBOX!=="1"&&'
                      rb'!' + ID + rb'\.CLAUDE_CODE_BUBBLEWRAP\)void 0', d)
    return bool(guarded and setup)

def _claude_md_alternates_are_tried(d):
    """The full alternate list AND the descriptor that must not be handed over.

    Two adjacent names in a literal prove neither. The part that can produce a
    WRONG answer rather than a missing one is the fourth argument: passing the
    storage descriptor to an alternate makes the loader serve CLAUDE.md's own
    bytes under another name, so the step passes `void 0` there deliberately.
    """
    names = b'["AGENTS.md","GEMINI.md","CRUSH.md","QWEN.md","IFLOW.md","WARP.md","copilot-instructions.md"]'
    if names not in d:
        return False
    return bool(re.search(rb'await ' + ID + rb'\$tw\(__sw\(__p,__n\),' + ID + rb','
                          rb'__c\?__sw\(__c,__n\):' + ID + rb',void 0\)', d))


def _cancellation_rule_is_whole(d):
    """The whole rule, not its first clause.

    Each pinned fragment is a separate instruction the main loop needs; any one
    of them can be dropped without touching the others, and the opening clause
    alone proves none of them.
    """
    # Волна 31 (K-3): перед arm стоит типизированный читатель выключателя
    # (инлайн-форма канонического __envon из ядра), и пин проходит по нему
    # целиком -- ослабления нет, пин стал длиннее прежнего.
    if not re.search(rb'\.\.\.\(\(\(\)=>\{let __s=String\(process\.env\.CLAUDE_JUDGE\?\?""\)'
                     rb'\.trim\(\)\.toLowerCase\(\);'
                     rb'return !\(__s===""\|\|__s==="0"\|\|__s==="false"\|\|__s==="off"\|\|__s==="no"\)\}'
                     rb'\)\(\)&&' + ID
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
                      + rb')=void 0;let (' + ID + rb')=\1,' + ID + rb'=' + ID
                      + rb'\(' + ID + rb'\.agentContext\)', d)
        if not m:
            return False
        var = re.escape(m.group(2))
        return bool(re.search(rb'model:' + var + rb'(?![\w$.])', d[m.end():m.end() + 8000]))
    var = re.escape(m.group(1))
    # Bounded to the launch function: the names here are one letter long, so an
    # unbounded search would find someone else's `model:f` in another chunk.
    return bool(re.search(rb'model:' + var + rb'(?![\w$.])', d[m.end():m.end() + 8000]))

def _every_cut_is_named(d):
    """Every cut in the probe is either declared to its reader or structural.

    Round 8 replaced a list of known-bad truncations with a CENSUS, and the
    census immediately found four more the list did not name. This is that
    census as a check, and widened: it counts every `.slice(` in both probe
    blocks, not only the `.slice(0,N)` head-cut shape, because a tail cut and a
    two-ended cut lose text just as quietly.

    The set below is the whole inventory. Two entries cut TEXT and both append
    a notice as they do it -- `__dcut` (the list) and `__clip` (the string),
    which is also where the dispatch head and the transcript head/tail land.
    A third, `0,__tk`, cuts an attachment body and declares the cut in that
    file's own header, so the reader never mistakes our trim for the caller's.
    The rest do not lose meaning: a BOM byte, a lone surrogate half, the JSON
    quote pair, the array copy, the fleet ring, the eight-character key suffix
    of a record name, the leading `~` of an attachment path, and the prune
    victim list.

    Re-run by hand after changing the injected code:
      python3 - <<'EOF'  (the same walk, printing Counter(args))

    A new cut fails this check whatever it cuts, which is the point: the
    previous form could only catch the cuts somebody had already thought of.
    The paren walk assumes no unbalanced parenthesis inside a string literal
    argument; if that ever appears the captured text is wrong and the check
    goes RED, which is the safe direction.
    """
    blocks = re.findall(rb'/\*__ccProbe0\*/[\s\S]*?/\*__ccProbe1\*/', d)
    if len(blocks) != 2:
        return False
    def _closes(b, start):
        i, depth = start, 1
        while i < len(b) and depth:
            c = b[i:i + 1]
            if c == b'(':
                depth += 1
            elif c == b')':
                depth -= 1
            i += 1
        return None if depth else i - 1

    found = {}
    for b in blocks:
        # Опись ходила ТОЛЬКО по `.slice(`. `.substring(0,__n)` режет ровно так
        # же тихо, в опись не попадал вовсе, и равенство описи от него не
        # менялось -- новый необъявленный срез проходил зелёным (круг 20, C-6).
        # В наших блоках их ноль (измерено на собранном 2.1.250); появление
        # любого краснит перепись, пока его не объявят как остальные.
        if re.search(rb'\.substring\(|\.substr\(', b):
            return False
        surs = []
        for m in re.finditer(rb'__sur\(', b):
            e = _closes(b, m.end())
            if e is None:
                return False
            surs.append((m.end(), e))
        for m in re.finditer(rb'\.slice\(', b):
            i, depth = m.end(), 1
            while i < len(b) and depth:
                c = b[i:i + 1]
                if c == b'(':
                    depth += 1
                elif c == b')':
                    depth -= 1
                i += 1
            if depth:
                return False
            arg = b[m.end():i - 1]
            # Second axis: is this cut inside a `__sur(...)` call, the seam
            # repair? A cut is measured in UTF-16 code units and lands between
            # the halves of a surrogate pair whenever it feels like it, so every
            # cut of TEXT must go through it and every cut that is not text must
            # not. One argument text, `0,__k`, belongs to two different sites
            # (__clip cuts characters, __dcut cuts a list) and only this axis
            # tells them apart.
            key = (arg, any(s <= m.start() < e for s, e in surs))
            found[key] = found.get(key, 0) + 1
    return found == {
        (b'', False): 1,                          # array copy before the trim walk
        (b'-256', False): 1,                      # the fleet ring keeps its last marks
        (b'-8', False): 1,                        # key suffix inside the record name
        (b'-__tl', True): 1,                      # declared middle-cut, tail half
        (b'0,-1', False): 1,                      # inside __sur itself
        (b'0,__tk', True): 1,                     # attachment body, declared in its header
        (b'0,__dmax', True): 1,                   # dispatch head, declared on the label
        (b'0,__h', True): 1,                      # declared middle-cut, head half
        (b'0,__k', True): 1,                      # __clip: characters
        (b'0,__k', False): 1,                     # __dcut: a list, no seam
        (b'0,__ls.length-__jkeep+1', False): 1,   # prune victims, not text
        (b'1', False): 5,                         # three BOM strips, one low surrogate,
                                                  # one leading `~` of an attachment path
        (b'1,-1', False): 1,                      # JSON.stringify quote pair
        (b'16,-1', False): 1,                     # `[dispatch-class:` and `]` off a matched marker
    }

def _judge_attaches_named_files(d):
    """The judge reads the brief the dispatch points at, and that read cannot
    itself cancel the dispatch.

    Most dispatches do not carry the task, they name a file that does. Without
    this the judge decides the decision boundary from the caller's retelling --
    exactly the thing the criterion forbids. Six properties, each one a defect
    if it goes:

      * off unless a probe asks for it -- the file count defaults to zero and
        the whole block sits behind `__atn>0&&__atc>0&&__atb>0`, so the watcher
        (which shares this core) never touches the disk for a file it has no
        use for;
      * the per-file cap does not bound the payload on its own -- N files times
        the per-file cap is the real size, so a total budget (`__atb`) is spent
        down file by file and the last one in is TRIMMED to what is left rather
        than dropped;
      * only `.md`/`.txt`, and the extension must end the token, so a path that
        merely CONTAINS `.md` earlier does not qualify;
      * an unreadable file is a note in `__deg`, never in the judgement-defect
        list -- a stale path in a dispatch must not become a cancellation, and a
        file simply absent (`__pcode`) is silent;
      * the trim is declared with BOTH numbers in the file's own header, so the
        reader can tell our cut from the caller's;
      * the cut goes through `__sur` -- a body cut in the middle of a surrogate
        pair would otherwise leave a lone half in the prompt.
    """
    return (bool(re.search(rb'__atn=__num\("attach_files",__cfg\.attach_files,0,0\)', d))
            and bool(re.search(rb'__atc=__num\("attach_chars",__cfg\.attach_chars,\d+,0\)', d))
            and bool(re.search(rb'__atb=__num\("attach_total",__cfg\.attach_total,\d+,0\)', d))
            and bool(re.search(rb'if\(__atn>0&&__atc>0&&__atb>0\)\{', d))
            and bool(re.search(rb'__rm=__atb-__sp;if\(__rm<=0\)break', d))
            and bool(re.search(rb'__tk=__atc<__rm\?__atc:__rm', d))
            and bool(re.search(rb'__kn=__bc\?__tk:__bd\.length;__sp\+=__kn', d))
            and bool(re.search(rb'\\\.\(\?:md\|txt\)\(\?!\[A-Za-z0-9\]\)', d))
            and bool(re.search(rb'__att\.length<__atn', d))
            and bool(re.search(rb'catch\(__ae\)\{if\(__pcode\(__ae\)!==0\)'
                               rb'__deg\.push\("attach-unreadable:', d))
            and not re.search(rb'__degb\.push\("attach', d)
            and bool(re.search(rb't:__bc\?__sur\(__bd\.slice\(0,__tk\)\):__bd', d))
            and bool(re.search(rb'__a\.c\?"[^"]*"\+__a\.k\+"[^"]*"\+__a\.n\+"', d)))


_probe_full = d
_probe_dup = re.findall(rb'/\*__ccCore0\*/[\s\S]*?/\*__ccCore1\*/', d)
for _b in _probe_dup[1:]:
    d = d.replace(_b, b'', 1)

checks = {
    'routing (claude-* -> subscription)': _routing_agrees_with_connection(d),
    'patch source escapes every captured name': _escaped_interpolations(src),
    'patch source keeps both dispatcher shapes': _judge_both_shapes(src),
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
    'dispatch carries effort':            len(re.findall(rb'effort:__ccEffort', d)) == 1
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
    # judge part 1: the current turn (thinking included) is stashed by
    # tool_use id, because the message reaching the executor carries the
    # tool_use block alone
    'judge stashes the current turn': bool(re.search(
                                              rb'\.streamingToolExecutor\.addTool\(' + ID + rb',' + ID + rb','
                                              # волна 31 (K-3): стэш гейтится тем же типизированным читателем --
                                              # CLAUDE_JUDGE=0 больше не наполняет карту хода
                                              rb'\(\(\(\)=>\{let __s=String\(process\.env\.CLAUDE_JUDGE\?\?""\)'
                                              rb'\.trim\(\)\.toLowerCase\(\);'
                                              rb'return !\(__s===""\|\|__s==="0"\|\|__s==="false"\|\|__s==="off"\|\|__s==="no"\)\}'
                                              rb'\)\(\)\?'
                                              rb'\(\(globalThis\.__ccJudgeTurn\?\?=new Map\(\)\)', d)),
    # judge part 2: consulted before a subagent dispatch, off unless
    # CLAUDE_JUDGE is set, fail-open on every path
    'judge consulted before dispatch': bool(re.search(
                                              # волна 31 (K-3): инлайн-читатель выключателя (см. E1)
                                              rb'if\(\(\(\)=>\{let __s=String\(process\.env\.CLAUDE_JUDGE\?\?""\)'
                                              rb'\.trim\(\)\.toLowerCase\(\);'
                                              rb'return !\(__s===""\|\|__s==="0"\|\|__s==="false"\|\|__s==="off"\|\|__s==="no"\)\}'
                                              rb'\)\(\)&&\(' + ID + rb'\.name==="Agent"'
                                              rb'\|\|' + ID + rb'\.name==="Task"\)&&' + ID +
                                              rb'\?\.agentContext\?\.agentType==="main"\)'
                                              rb'await globalThis\.__ccProbe\(\{', d)),
    'judge rides the tool, watcher the dispatcher': _judge_rides_the_tool(_probe_full),
    'consumers do not reach into the core': _consumer_uses_no_core_privates(_probe_full),
    'probe names match the image bindings': _probe_uses_the_images_own_names(_probe_full),
    'effort binding reaches the launch': _effort_binding_reaches_the_launch(d),
    'current turn is the judge\'s alone': _turn_belongs_to_the_judge(_probe_full),
    'one consultation, one record name': _record_name_is_unique(d),
    # One core per site, and the count is CHECKED. The previous form of this
    # entry was `bool(re.search(...))` under the name "defined once" -- a
    # presence test wearing a count's name, which would have gone green on any
    # number of copies including the drifted ones it was written to forbid.
    # (Copies across sites are compared byte for byte by the entry above; this
    # one is what keeps a single site from accumulating two.)
    'exactly one probe core survives the collapse': len(re.findall(
                                              rb'globalThis\.__ccProbe\?\?=async function\(__o\)\{', d)) == 1,
    # The verdict vocabulary is set by the CALLER: the judge and the watcher
    # have different ones, and a vocabulary hardcoded into the core would
    # silently judge the watcher in the judge's words.
    # And so does the FALLBACK PROMPT, for exactly the same reason. The core
    # used to carry the judge's own text and hand it to both probes; the
    # watcher's parser accepts only SILENT|NUDGE, so a machine with no
    # idle-watch/prompt.md paid for a full ladder that could not produce a
    # verdict by construction. Pin all three halves: the core defers to the
    # caller, the judge's fallback names its own verdicts, the watcher's names
    # its own.
    'each probe fallback prompt speaks its own vocabulary': bool(re.search(
                                              rb'__sys=__o\.fb\}', d))
                                          and not re.search(rb'__sys="You judge', d)
                                          and bool(re.search(
                                              rb'act:"BLOCK\|STOP\|DENY",fb:"You judge one'
                                              rb'[\s\S]{0,500}OK:<why>[\s\S]{0,200}BLOCK:<', d))
                                          and bool(re.search(
                                              rb'act:"NUDGE",fb:"You watch'
                                              rb'[\s\S]{0,500}SILENT:<[\s\S]{0,160}NUDGE:<', d)),
    'probe verdict vocabulary comes from the caller': bool(re.search(
                                              rb'let __rx=new RegExp\("\^\\\\s\*\(\?:"\+__o\.rx\+"\):\.\*\$","gmi"\)', d))
                                          and bool(re.search(
                                              rb'rx:"OK\|BLOCK\|STOP\|DENY\|WARN",act:"BLOCK\|STOP\|DENY"', d)),
    # A regex built from a STRING needs a double backslash: a single one
    # quietly degenerates the class (`"\s"` in a JS string is the letter s,
    # `"[\s\S]"` is [sS]), and the verdict vocabulary stops matching while
    # staying syntactically valid. Measured on the bench: BLOCK was recorded as
    # ok, and the judge cancelled nothing.
    'probe verdict classes survive string escaping': bool(re.search(
                                              rb'new RegExp\("\^\(\?:"\+__o\.act\+"\):\\\\s\*'
                                              rb'\(\[\\\\s\\\\S\]\+\)\$","mi"\)', d))
                                          and not re.search(
                                              rb'new RegExp\("\^\(\?:"\+__o\.act\+"\):\\s\*\(\[\\s\\S\]\+\)', d),
    # The watcher is the second consumer of the SAME core. A separate
    # definition here would mean the decomposition into a core never happened.
    'watcher rides the same core': bool(re.search(
                                              # волна 31 (K-3): тот же типизированный читатель для
                                              # выключателя наблюдателя
                                              rb'if\(\(\(\)=>\{let __s=String\(process\.env\.CLAUDE_IDLE\?\?""\)'
                                              rb'\.trim\(\)\.toLowerCase\(\);'
                                              rb'return !\(__s===""\|\|__s==="0"\|\|__s==="false"\|\|__s==="off"\|\|__s==="no"\)\}'
                                              rb'\)\(\)&&' + ID +
                                              rb'\?\.agentContext\?\.agentType==="main"\)'
                                              rb'await globalThis\.__ccProbe\(\{'
                                              rb'tag:"\[Watch\]",dirName:"idle-watch",arm:!1,'
                                              rb'label:"FLEET",rx:"SILENT\|NUDGE",act:"NUDGE",', d)),
    # The watcher's reaction is a tab in the thread, not a dispatch
    # cancellation. A throw here would crash a working tool for the sake of a
    # reminder; `arm:!1` additionally locks the failure path through which the
    # judge cancels a dispatch.
    # The main-loop filter in the IMAGE is `dA(e)=e.agentId===Di()`; the
    # typescript-src reconstruction says `undefined` at this spot and has
    # diverged since 2.1.239.
    # The drain threshold equals "later" only in a thread with Sleep, so
    # "later" would wait for Sleep indefinitely: a journal with "nudge" and
    # zero delivery.
    'watcher nudges through the notification queue': bool(re.search(
                                              rb'onAct:async\(__r,__svc\)=>\{try\{' + ID +
                                              rb'\(\{value:"\[fleet-idle\] "\+__r\+"[^"]*",'
                                              rb'mode:"task-notification",agentId:' + ID +
                                              rb'\(\),priority:"next"\}\)\}', d))
                                          # A silent catch here = a journal with nudge and zero delivery.
                                          # The line must be written through the services the core
                                          # HANDS OVER: the same record written by a bare `__jlog` is
                                          # a free variable at this site and never runs at all.
                                          and bool(re.search(
                                              rb'catch\(__ne\)\{try\{await __svc\.log\(\{'
                                              rb'outcome:"nudge_undelivered"', d))
                                          # the recipient must match what the filter itself requires
                                          and bool(re.search(
                                              rb'function (\w+)\(\w+\)\{return \w+\.agentId===(\w+)\(\)\}', d))
                                          and bool(re.search(
                                              rb'onNoVerdict:\(\)=>\{\},onBroken:\(\)=>\{\},'
                                              rb'onFail:\(\)=>\{\}\}\)', d)),
    # The fleet count happens on EVERY tool call: counting only where the
    # watcher is invoked means never seeing already-started subagents. The
    # list is capped from above — otherwise it grows the whole session.
    'watcher counts every dispatch': bool(re.search(
                                              rb'globalThis\.__ccFleet\?\?=\[\];if\(' + ID +
                                              rb'\.name==="Agent"\|\|' + ID + rb'\.name==="Task"\)\{'
                                              rb'globalThis\.__ccFleet\.push\(globalThis\.__ccMono\(\)\);', d))
                                          and bool(re.search(
                                              rb'if\(globalThis\.__ccFleet\.length>256\)', d)),
    # The cheap count stands BEFORE the model: a busy fleet, an unfilled window
    # and a cooldown cut off the consultation for free. Without it the watcher
    # would become a permanent expense line on every tool call.
    # Четыре присутствия не задают ПОРЯДКА: перенести блок ворот за разбор
    # истории -- все строки на месте, а наблюдатель снова платит за консультацию
    # на каждом вызове инструмента (круг 20, C-7). Порядок пинится склейкой:
    # блок ворот обязан ПРИМЫКАТЬ к началу сборки транскрипта.
    'watcher spends nothing before the cheap count': bool(re.search(
                                              rb'if\(__ask&&__o\.gate\)\{let __g=null;'
                                              rb'try\{__g=await __o\.gate\(__cfg,__svc\)\}'
                                              rb'catch\(__ge\)\{__g="gate-failed:"\+'
                                              rb'String\(__ge\?\.message\?\?__ge\)\}'
                                              rb'if\(__g\)\{__ask=!1;await __jlog\(\{'
                                              rb'outcome:"filtered",by:String\(__g\),cls:null,'
                                              rb'\.\.\.\(__deg\.length\?\{deg:__dcut\(__deg,5\)\}'
                                              rb':\{\}\)\}\)\}\}let __uw=\[\];'
                                              # Перечень между дешёвыми воротами и разбором
                                              # ОСТАЁТСЯ полным: две подготовительные строки
                                              # ленты (длина истории и идентификатор предмета)
                                              # названы поимённо, поэтому любая ТРЕТЬЯ работа,
                                              # вставленная сюда, по-прежнему краснит проверку.
                                              rb'let __nh=\(__o\.ctx\.messages\|\|\[\]\)\.length;'
                                              rb'let __sid=__o\.selfId\?__o\.selfId\(\):null;'
                                              rb'let __arr=\[', d))
                                          # three count refusals; the exact moment of each is
                                          # checked separately below
                                          and bool(re.search(rb'return "fleet-busy:"\+__n\}', d))
                                          and bool(re.search(rb'return "window-not-filled"\}', d))
                                          and bool(re.search(rb'return "cooldown"\}', d)),
    # The probe is called on every tool call, so the filter must run BEFORE
    # reading settings: walking up the tree costs tens of filesystem accesses,
    # and a journaled refusal would drown the human's journal.
    'probe skips before touching the disk': bool(re.search(
                                              rb'globalThis\.__ccProbe\?\?=async function\(__o\)\{'
                                              rb'if\(__o\.pre\)\{let __pr=null;try\{__pr=__o\.pre\(\)\}'
                                              rb'catch\{__pr=null\}if\(__pr\)return\}', d)),
    # The filter must know the MOMENT, not the polling interval: every cheap-count
    # refusal names a time before which it cannot change.
    # A monotonic clock has no "long ago": its zero is the start of the
    # process. The sentinel for "has not spoken yet" must therefore sit outside
    # the value space, or a fresh session serves a full cooldown of silence the
    # moment its window fills -- and writes `cooldown` in the journal, where it
    # is indistinguishable from a real one. Both halves are pinned: a null that
    # nothing tests for is arithmetic on null, which is a 0 again.
    'the watcher\'s "never" is not a clock reading': bool(re.search(
                                              rb'let __s=globalThis\.__ccWatch\?\?='
                                              rb'\{last:null,start:__now\}', d))
                                          and bool(re.search(
                                              rb'if\(__s\.last!==null&&__now-__s\.last<__cd\)'
                                              rb'\{__s\.nextAt=__s\.last\+__cd;return "cooldown"\}', d))
                                          and len(re.findall(rb'last:0,start:', d)) == 0,
    'every cut in the probe is named': _every_cut_is_named(d),
    'judge attaches the brief the dispatch names': _judge_attaches_named_files(d),
    'watcher names the next possible moment': bool(re.search(
                                              rb'pre:\(\)=>\{let __s=globalThis\.__ccWatch;'
                                              rb'return __s&&__s\.nextAt>globalThis\.__ccMono\(\)\?"not-yet":null\}', d))
                                          and bool(re.search(
                                              rb'\}else if\(__n>=__th\)\{__s\.nextAt=__f\[__n-__th\]\+__w;', d))
                                          and bool(re.search(
                                              rb'__s\.nextAt=__s\.start\+__w;', d))
                                          and bool(re.search(
                                              rb'__s\.nextAt=__s\.last\+__cd;', d))
                                          and bool(re.search(
                                              rb'__s\.last=__now;__s\.nextAt=__now\+__cd;return null', d)),
    # A cheap-count refusal lands in the journal with a REASON: otherwise "never
    # called" and "called and stayed silent" are indistinguishable, and those
    # are two different outcomes.
    'watcher journals why it stayed cheap': bool(re.search(
                                              rb'await __jlog\(\{outcome:"filtered",by:String\(__g\),'
                                              rb'cls:null,\.\.\.\(__deg\.length\?\{deg:__dcut\(__deg,5\)\}:'
                                              rb'\{\}\)\}\)', d))
                                          # both filtered lines, not just the gate's
                                          and len(re.findall(
                                              rb'outcome:"filtered",by:[^}]*?__deg\.length', d)) == 2,
    # The outcome word in the journal is the class named by the model, not the
    # judge's "block": the vocabulary comes from the caller, and a hardcoded
    # word would write the watcher's silence with the same characters as a real
    # judge cancellation.
    'outcome word comes from the verdict class': bool(re.search(
                                              # a regex LITERAL: one backslash, unlike the
                                              # string-built vocabulary one above
                                              rb'let __ocw=String\(\(/\^\\s\*\(\[A-Za-z\]\+\):/'
                                              rb'\.exec\(__v\|\|""\)\|\|\[\]\)\[1\]\|\|"ok"\)'
                                              rb'\.toLowerCase\(\);', d))
                                          and bool(re.search(
                                              rb'outcome:__bl\?\(__en\?__ocw:__ocw\+"_not_enforced"\):'
                                              rb'\(__v\?__ocw:', d))
                                          and not re.search(
                                              rb'outcome:__bl\?\(__en\?"block"', d),
    # The corpus of records is the material for model selection and for
    # training our own, and it will have to be parsed from the outside. The
    # verdict vocabulary therefore lives IN THE RECORD ITSELF: a copy in
    # config.json would be a second source of truth and would drift silently,
    # while without the vocabulary the parsing tools hardcode the judge's
    # OK/WARN/BLOCK and cannot express the watcher's SILENT/NUDGE at all. The
    # journal line carries no vocabulary deliberately — a human reads it.
    'records carry their own verdict vocabulary': bool(re.search(
                                              rb'JSON\.stringify\(\{\.\.\.__base,rx:__o\.rx,act:__o\.act,'
                                              rb'http:__jst,url:__jurl,pid:process\.pid,', d))
                                          and not re.search(
                                              rb'let __base=\{t:__ts,rx:', d),
    # a WARN never reaches the model and a fail-open skip leaves no trace,
    # so both are only observable through the append-only journal
    'judge has a journal sink': bool(re.search(
                                              rb'appendFile\(__jdir\+"/journal\.jsonl"', d)),
    # a journal line has to say which switch armed enforcement and what the
    # consultation cost — without both, `block` and `block_not_enforced` are
    # separable only by guessing at the environment of a past run
    'judge journal records cost and switch': bool(re.search(
                                              rb'ms:globalThis\.__ccMono\(\)-__t0,sw:__o\.sw\|\|null', d))
                                          and bool(re.search(
                                              rb'en:__en\?\(__o\.sw==="enforce"\?'
                                              rb'"env":"config"\):\(__cfgseen\?"off":"no-config"\)', d))
                                          # the judge's switch remains env: the core does not know it
                                          and bool(re.search(
                                              rb'sw:process\.env\.CLAUDE_JUDGE,', d)),
    # the journal line clips the verdict and holds none of the material the
    # judge saw, so the request/response pair is kept beside it per consultation
    # a text prefix cannot carry provenance — content shares its namespace and
    # any line starting with 'user: ' forges a label, so the transcript goes
    # over as a JSON array whose `src` cannot be reached from inside `text`
    # a silent fail-open under load is indistinguishable from blanket approval,
    # so a failed consultation is retried once on a short tail before giving up
    # a 2xx whose budget went entirely into reasoning returns no verdict, and
    # silence reads as consent — that must advance the chain like any failure
    # the body template carries its own ceiling, so config.json's max_tokens is
    # a silent no-op without this override — that silence once ate a cancellation.
    # Волна 31 (K-8): наличие -- `??` и страж от void 0/null, а не истинность:
    # ноль прежде не доезжал до __num, и один и тот же ноль получал два
    # ответа -- на живом шаблоне молча оставался его потолок.
    'judge budget has one home': bool(re.search(
                                              rb'let __mt=__e\.max_tokens\?\?__cfg\.max_tokens;'
                                              rb'if\(__mt!==void 0&&__mt!==null\)__obj\.max_tokens=__num\("max_tokens",__mt,'
                                              rb'__obj\.max_tokens\?\?__mtd,1\)', d)),
    'judge treats a verdictless reply as a failure': bool(re.search(
                                              rb'__v=__pv\(__raw\);if\(__v\)break;', d))
                                          and bool(re.search(
                                              rb'__errs\.push\(__jm\+": empty verdict"\)', d)),
    # each rung of the ladder carries its own deadline and transcript size,
    # because the reasons a rung fails differ
    'judge ladder rungs carry their own limits': bool(re.search(
                                              # волна 31: у ступеней те же границы, что у главных
                                              # чтений -- пол 60 (K-6) и потолок setTimeout 2^31-1 (K-1)
                                              rb'__raw=await __call\(__e\.context_chars\?'
                                              rb'__cut\(__num\("rung\.context_chars",__e\.context_chars,'
                                              rb'__max,60\)\):__ctx,'
                                              rb'__num\("rung\.timeout_ms",__e\.timeout_ms,__tmo,1,!1,2147483647\),'
                                              rb'__e\)', d)),
    # Ни `for` (это ладдер), ни присваивание счётчика не требуют, чтобы повтор
    # СОСТОЯЛСЯ: выбросить сам вызов -- и проверка остаётся зелёной, а имя её
    # идёт в сводку как доказательство повтора (круг 20, C-9).
    'judge retries a failed consultation': bool(re.search(
                                              rb'for\(let __i=0;__i<__mdls\.length;__i\+\+\)\{', d))
                                          and bool(re.search(
                                              rb'__jtry=__mdls\.length\+1;__jm=__e\.model;', d))
                                          and bool(re.search(
                                              rb'try\{__raw=await __call\(__cut\(__rcc\),'
                                              rb'Math\.min\(__rt,Math\.max\(1000,'
                                              rb'Math\.round\(__rt/2\)\)\),__e\);', d)),
    # a project restates the RULES for itself; the judge still knows nothing
    # about what the project is — the nearest .claude/judge above cwd layers over
    # the global one
    'judge takes a project layer': bool(re.search(
                                              rb'if\(__has\.some\(\(__x\)=>__x\.c===1\)\)\{if\(__c!==__jdir\)'
                                              rb'\{__pdir=__c;__phomeP=__ch\}break\}', d))
                                  and bool(re.search(
                                              rb'if\(__phomeP\)\{let __c1=await __ldt\(__phomeP\+"/probes\.toml"\);'
                                              rb'if\(__c1===!1\)__cfgbad=!0;else if\(__c1\)'
                                              rb'\{__cfgseen=!0;__cfg=\{\.\.\.__cfg,\.\.\.__eff\(__c1,__o\.dirName\)\}\}\}', d)),
    # Волна 24 добавила в ту же запись две ПОМЕТКИ ленты: `now` (вызов выпущен
    # ЭТИМ ходом и ещё не исполнен) и `self` (это и есть предмет консультации).
    # Образец пинится вместе с ними: без пометок судья снова читает свой
    # собственный вызов как «уже отправленный голос» и отменяет веер.
    'judge context is structured, not prefixed': bool(re.search(
                                              rb'return\{src:__role,text:__bt,'
                                              rb'\.\.\.\(__now\?\{now:!0\}:\{\}\),'
                                              rb'\.\.\.\(__slf\?\{self:!0\}:\{\}\)\}\}\)\.filter\(Boolean\)', d))
                                          and bool(re.search(
                                              rb'let __cut=\(__n\)=>\{let __b=Math\.max\(60,__n\),'
                                              rb'__pb=Math\.floor\(__b\*0\.35\),__sb=Math\.floor\(__b\*0\.3\);', d)),
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
    # a record has to be REPLAYABLE, so it carries the endpoint, the sending
    # process, and what every rung was fed — not just the body that answered
    'judge keeps the full consultation': bool(re.search(
                                              rb'\{\.\.\.__base,rx:__o\.rx,act:__o\.act,'
                                              rb'http:__jst,url:__jurl,pid:process\.pid,'
                                              rb'cwd:process\.cwd\(\),attempts:__jatt,request:__rq,'
                                              rb'response:__jres\}', d))
                                          and bool(re.search(
                                              rb'__jatt\.push\(__a\)', d)),
    # the judge must ride the client model pool, not its own HTTP call: a
    # dedicated path would route claude-models to api.anthropic.com at API
    # prices
    'judge rides the client model pool': bool(re.search(
                                              rb'via:__http\?"http":"pool"', d))
                                          and bool(re.search(
                                              rb'querySource:"hook_prompt",toolChoice:void 0', d))
                                          and bool(re.search(
                                              rb'effortValue:__e\.effort\|\|void 0', d)),
    # a whole-ladder failure under fail_closed = cancellation, not a silent pass
    'judge can fail closed': bool(re.search(
                                              rb'__fc=!__v&&__en&&__fcl', d))
                                          # волна 31 (K-2): fail_closed читается типизированным
                                          # читателем, безопасная сторона -- включён
                                          and bool(re.search(
                                              rb'let __fcl=__cfgbad\|\|__bl3\("fail_closed",__cfg\.fail_closed,!0\)', d))
                                          and bool(re.search(rb'if\(__fc\)await __o\.onNoVerdict\(', d))
                                          # ...and the judge's reaction to it must be a throw,
                                          # otherwise fail_closed turns into fail-open with a one-line edit at the call site
                                          and bool(re.search(
                                              rb'onNoVerdict:\(__r\)=>\{let __e=new Error\([\s\S]{0,4000}?'
                                              rb'__e\.__ccJudgeBlock=!0;throw __e\}', d)),
    # a channel cancellation and a verdict cancellation are different defects,
    # different names
    'judge names a fail-closed cancellation': bool(re.search(
                                              rb'__fc\?"block_no_verdict":"empty"', d)),
    # trimming the transcript must not drop what the human typed before
    # anything else
    'judge keeps the human turns when trimming': bool(re.search(
                                              rb'__pr=\(__x\)=>__x&&\(__x\.src==="user"\|\|'
                                              rb'__x\.src==="compaction-summary"\)', d))
                                          and bool(re.search(
                                              rb'if\(!__al\(__k\)\|\|__pr\(__a\[__k\]\)\)continue;'
                                              rb'if\(__tot-__w\[__k\]>=__b\)', d))
                                          # the share is counted per CLASS (a per-item summary cap
                                          # gave 64% of the transcript), the carrier is cut by text, not dropped
                                          and bool(re.search(
                                              rb'__cap\(__iss,__sb\);__cap\(__isu,__pb\)', d))
                                          and bool(re.search(
                                              rb'__dp\?"; \\u0412\\u042b\\u0422\\u0415\\u0421', d)),
    # the last unpinned entry is shortened to fit the gap rather than dropped:
    # otherwise the transcript empties out and the judges blind
    'judge fills the budget instead of emptying the tape': bool(re.search(
                                              rb'if\(__tot-__w\[__k\]>=__b\)\{__del\(__k,!1\);continue\}', d))
                                          and bool(re.search(
                                              rb'if\(__w\[__k\]>120\)__fit\(__k,__w\[__k\]-\(__tot-__b\)\);'
                                              rb'else __del\(__k,!1\)', d)),
    # trimming thresholds and the marker cost are counted in JSON LENGTH:
    # text thresholds missed on escaping in both directions (overflow and
    # undershoot)
    'judge measures trimming in JSON length': bool(re.search(
                                              rb'let __fit=\(__i,__tc\)=>\{if\(__w\[__i\]<=__tc\)return 0;', d))
                                          and bool(re.search(
                                              rb'__lim=Math\.max\(8,Math\.floor\(__lim\*__tc/__c\*0\.9\)\)', d))
                                          and bool(re.search(
                                              rb'__tot\+__mc>__b', d)),
    # trimming must be LINEAR: re-serialising the whole array on every removal
    # gave 8.3 s of local compute against the rung's 25 s threshold
    'judge trims without re-serialising': bool(re.search(
                                              rb'__cs=\(__x\)=>JSON\.stringify\(__x\)\.length\+1', d))
                                          and bool(re.search(
                                              rb'__del=\(__i,__p\)=>\{if\(__dd\[__i\]\)return 0;__dd\[__i\]=!0', d))
                                          # removal marks instead of cutting out: a splice per
                                          # removal gave 5-10 s on a marathon transcript
                                          and len(re.findall(rb'__a\.splice\(', d)) == 0
                                          # the marks are reset after EVERY compaction: otherwise
                                          # the marker count runs on stale marks and undercounts
                                          # the pinned human turns, down to zero with three live
                                          # occurrences: introducing the mark array and the reset
                                          # after each of the two compactions
                                          and len(re.findall(rb'__dd=new Array\(__a\.length\)\.fill\(!1\)', d)) == 3
                                          and len(re.findall(rb'__fit\(0,', d)) == 0
                                          and len(re.findall(rb'__s=JSON\.stringify\(__a\)', d)) == 0
                                          and bool(re.search(rb'__mt=\(\)=>"\[\\u043b', d))
                                          and bool(re.search(rb'__pb=Math\.floor\(__b\*0\.35\)', d)),
    # the numbers in the marker and in the record itself must state the FACT,
    # not the call count: counting __fit calls gave 39 trims against 4 live
    # ones, and counting from the previous cut gave "123 cut out" where
    # 200000 were cut
    'judge counts trimmed records honestly': bool(re.search(
                                              rb'let __ot=new Array\(__a\.length\)\.fill\(null\)', d))
                                          # a trim always works from the ORIGINAL text
                                          and bool(re.search(
                                              rb"let __t=__ot\[__i\]!==null\?__ot\[__i\]:String\(__a\[__i\]\.text\)", d))
                                          and bool(re.search(
                                              rb'__ot\[__i\]=__t;__a\[__i\]=__nx', d))
                                          # the originals array is carried across BOTH compactions
                                          and len(re.findall(rb'__ot=__ot\.filter\(', d)) == 2
                                          # the call counter is removed from the code entirely
                                          and len(re.findall(rb'__c2', d)) == 0
                                          and bool(re.search(
                                              rb'__ctd=\(\)=>\{let __r=0;.{0,80}__ot\[__k\]!==null', d))
                                          and bool(re.search(rb'\(__cd=__ctd\(\)\)\?', d)),
    # the failure path reads only names declared above the try (see the helper)
    'judge fail-open path stays in scope': _judge_catch_scope(d),
    # Every number came in as `Number(x||default)`, which normalizes the falsy
    # typos and lets through the two that break the mechanism: a NEGATIVE
    # threshold makes `__n>=__th` always true and the watcher goes permanently
    # mute, a non-numeric one yields NaN and the threshold stops applying at
    # all. `||` cannot tell "absent" from "invalid". The positive control for
    # the absence half is the count on the same line: a payload without our
    # code scores zero and fails rather than passing as "nothing bad found".
    'numeric settings are sanitised, not coerced': (
                                              # per KEY, not one total: a count that only
                                              # adds up says nothing about WHICH home lost
                                              # its guard. Counts are taken on the collapsed
                                              # payload, so they equal the source's.
                                              len(re.findall(rb'__num\("context_chars"', d)) == 1
                                          and len(re.findall(rb'__num\("dispatch_chars"', d)) == 1
                                          and len(re.findall(rb'__num\("retry_context_chars"', d)) == 1
                                          and len(re.findall(rb'__num\("records_keep"', d)) == 1
                                          and len(re.findall(rb'__num\("max_tokens"', d)) == 5
                                          and len(re.findall(rb'__num\("timeout_ms"', d)) == 1
                                          and len(re.findall(rb'__num\("rung\.context_chars"', d)) == 1
                                          and len(re.findall(rb'__num\("rung\.timeout_ms"', d)) == 2
                                          # no home left reading its number raw
                                          and len(re.findall(rb'Number\(__cfg\.', d)) == 0
                                          and len(re.findall(rb'Number\(__e\.', d)) == 0
                                          and len(re.findall(rb'Number\(__mt\)', d)) == 0
                                          and len(re.findall(rb'Number\(__o\.tmoEnv', d)) == 0
                                          and len(re.findall(rb'Number\(__c\.', d)) == 0
                                          # one report per SETTING, not per reader: five
                                          # rungs read the same budget, and five identical
                                          # lines crowd the five-line cut
                                          and bool(re.search(rb'if\(!__q&&!__nseen\[__k\]\)\{__nseen\[__k\]=1;', d))
                                          # the attempt ledger RECORDS a budget, it does not
                                          # choose one: its default is null, and reporting
                                          # from there told the human "using null" while the
                                          # send path had already used 1200
                                          and bool(re.search(
                                              rb'max_tokens:__num\("max_tokens",'
                                              rb'__e\.max_tokens\?\?__cfg\.max_tokens,null,1,!0\)', d))
                                          and bool(re.search(
                                              rb'__num=\(__k,__v,__d,__min,__q,__cap\)=>\{if\(__v===void 0\|\|'
                                              rb'__v===null\|\|__v===""\)return __d;', d))
                                          # волна 31 (K-1/K-9): вход типизирован (Number(true)===1
                                          # больше не проходит числом), у чтений появился потолок
                                          and bool(re.search(
                                              rb'let __x=typeof __v==="number"\?__v:'
                                              rb'\(typeof __v==="string"&&__v\.trim\(\)!==""\?Number\(__v\):NaN\);', d))
                                          and bool(re.search(
                                              rb'if\(!Number\.isFinite\(__x\)\|\|__x<__min\|\|\(__cap!==void 0&&__x>__cap\)\)\{'
                                              rb'if\(!__q&&!__nseen\[__k\]\)\{__nseen\[__k\]=1;'
                                              rb'__deg\.push\("bad-setting:"', d))
                                          # the watcher's gate is a callback closed over ITS
                                          # splice site, so the sanitiser reaches it only as a
                                          # handed-over service -- and both ends must agree
                                          # волна 31 (K-12): в сервисах появился читатель списков
                                          # (live_kinds), __svc.num-счёт ниже не тронут
                                          and bool(re.search(rb'__svc=\{log:__jlog,clip:__clip,num:__num,list:__lkr\}', d))
                                          and bool(re.search(rb'__g=await __o\.gate\(__cfg,__svc\)', d))
                                          and bool(re.search(rb'gate:\(__c,__svc\)=>', d))
                                          and len(re.findall(rb'__svc\.num\("', d)) == 5),
    # One record per consultation, ~28 KB each, ~130 a day, and nothing ever
    # deleted them: 31 MB and 1134 files measured on the live install. The prune
    # rides the WRITE -- `record = false` means "stop writing", not "erase what
    # is there" -- and its failure is reported on the same channel as a failed
    # record write, never swallowed.
    'the records directory is bounded': (
                                              bool(re.search(
                                                  # Пинит РАМКУ прополки, а не содержимое фильтра: две его
                                                  # оговорки принадлежат СВОИМ проверкам ниже («the record
                                                  # just written is never pruned» и «the archive is out of
                                                  # the window»). Пока эта строка несла обе, та из них, что
                                                  # объявлена отдельной проверкой, не могла покраснеть в
                                                  # одиночку -- проверка, которую нельзя провалить одну,
                                                  # неотличима от работающей.
                                                  rb'let __ls=\(await __jfs\.readdir\(__jdir\+"/records"\)\)'
                                                  rb'\.filter\(\(__x\)=>', d))
                                          and bool(re.search(
                                                  rb'if\(__ls\.length>=__jkeep\)\{__ls\.sort\(\);', d))
                                          and bool(re.search(
                                                  rb'for\(let __old of __ls\.slice\(0,__ls\.length-__jkeep\+1\)\)'
                                                  rb'try\{await __jfs\.unlink\(__jdir\+"/records/"\+__old\)\}'
                                                  rb'catch\(__ue\)\{if\(__ue\?\.code!=="ENOENT"\)throw __ue\}', d))
                                          and bool(re.search(rb'record prune failed: ', d))
                                          and bool(re.search(
                                                  rb'__jkeep=__num\("records_keep",__cfg\.records_keep,500,1\)', d))),
    # a channel failure under fail_closed = CANCELLATION, not a pass: the retry
    # on a short transcript was not wrapped, its crash was written up as a
    # regular skip and the dispatch went through
    'judge cancels when it cannot decide': bool(re.search(
                                              rb'if\(__ask\)\{__jarm=!!__o\.arm&&__en&&__fcl;', d))
                                          # the retry is wrapped the same way as a rung
                                          and bool(re.search(
                                              rb'let __rcc=__num\("retry_context_chars",'
                                              rb'__cfg\.retry_context_chars,8000,0\);', d))
                                          and bool(re.search(
                                              rb'try\{__raw=await __call\(__cut\(__rcc\),', d))
                                          # the obligation is released LAST
                                          and bool(re.search(
                                              rb'await __o\.onAct\(__bl\[1\]\.trim\(\),__svc\);__jarm=!1;\}\}catch', d))
                                          and bool(re.search(
                                              rb'outcome:__jarm\?"block_no_verdict":"skip"', d))
                                          and bool(re.search(
                                              rb'if\(__jarm\)await __o\.onFail\(__rs,__svc\);', d))
                                          # the journal write does not steer control past decisions
                                          and bool(re.search(
                                              rb'try\{await __jlog\(\{http:__jst,outcome:__bl\?', d))
                                          and bool(re.search(
                                              rb'verdict:__clip\(__v,400\)\|\|null\}\)\}catch\{\}', d)),
    # every truncation in the journal and the record is declared, like
    # trimming the transcript. A name-by-name list of forbidden places forbids
    # only what has already been thought of: trimming THE DISPATCH ITSELF was
    # not in it, and a bare slice on the main object of the judgment held
    # 69/69 while the judge returned corrected dispatches for a truncation we
    # had made ourselves (measured 2026-08-23). The dispatch is pinned
    # separately.
    # A journal record is addressed by SESSION, not by pid alone: the OS
    # reuses pids, and after the process dies the record points at nothing.
    # The pin is class-level: the field must sit in the shared base (the record
    # file inherits it too), the getter must swallow the throw — a journal line
    # has no right to disappear over a field — and there must be no bare call
    # in the base.
    # Session busyness is taken from the task REGISTRY, not inferred from
    # dispatch timestamps: a subagent working longer than the window fell out
    # of the marks, and the session looked idle exactly while the fan-out was
    # running. The pin is class-level: reading the registry, a liveness check
    # exactly as in the image (_L), a readability declaration in the payload,
    # and a recheck NOT through the window.
    # The dispatch model is RESOLVED (call -> agent definition -> inheritance),
    # the source is named by the msrc field. A third of the records went out
    # without a model, and the "who worked with what" census undercounted that
    # third. The pin is class-level: the old form is forbidden too — the model
    # straight from the call into the record base.
    'journal resolves the dispatch model': bool(re.search(
                                              rb'__mdl=\(\)=>\{try\{let __m=__o\.input\?\.model;', d))
                                          and bool(re.search(
                                              rb'ctx\?\.options\?\.agentDefinitions\?\.activeAgents', d))
                                          and bool(re.search(rb'__dm!=="inherit"\)return\{m:__dm,s:"agent"\}', d))
                                          and bool(re.search(rb's:__dm==="inherit"\?"inherit":"main"', d))
                                          and bool(re.search(rb'model:__mv\.m,msrc:__mv\.s', d))
                                          and len(re.findall(rb'model:__o\.input\?\.model,', d)) == 0,
    # The session title is taken through an accessor whose binding in the image
    # is NOT proven: a wrong name would return a stack parse instead of a
    # string, SILENTLY. The shape check is mandatory — without it the journal
    # would collect garbage that looks like data.
    # The applied settings layer is named in EVERY journal line, not only in
    # consultation lines: before, the layer filter named nothing, and which
    # config.json took effect had to be inferred indirectly from behavior. The
    # field has exactly one source — the shared record base.
    'every journal line names the applied config layer': bool(re.search(
                                              rb'msrc:__mv\.s,cfg:__pdir\|\|null,', d))
                                          and len(re.findall(rb'cfg:__pdir\|\|null', d)) == 1,
    'the journal line is bounded whatever fills it': (
                                              bool(re.search(
                                                  rb'for\(let __k2 in __base\)\{let __v2=__base\[__k2\];'
                                                  rb'if\(typeof __v2==="string"\)__base\[__k2\]=__clip\(__v2,400\);', d))
                                          and bool(re.search(
                                                  rb'else if\(Array\.isArray\(__v2\)\)__base\[__k2\]='
                                                  rb'__dcut\(__v2,8\);', d))
                                          # A value that is neither string nor array used to
                                          # go in untouched, so one object field could carry
                                          # an unbounded string inside it and the name of
                                          # this check would be decoration.
                                          and bool(re.search(
                                                  rb'else if\(__v2&&typeof __v2==="object"\)'
                                                  rb'__base\[__k2\]=__clip\(JSON\.stringify\(__v2\),400\)', d))
                                          # the join key is added AFTER the walk and must stay whole
                                          and bool(re.search(rb'__rn\?\{\.\.\.__base,rec:__rn\}:__base', d))),
    'session title is shape-guarded': bool(re.search(
                                              rb'__ttl=\(\)=>\{try\{let __i=__sid\(\);', d))
                                          and bool(re.search(
                                              rb'typeof __v==="string"&&__v\?__v:void 0', d))
                                          and bool(re.search(rb'title:__ttl\(\)', d)),
    'watcher counts live work, not dispatch marks': bool(re.search(
                                              rb'__tr=[\w$]+\?\.taskRegistry\?\.all\?\.\(\)', d))
                                          and bool(re.search(
                                              rb'status==="running"\|\|[\w$.?]+status==="pending"', d))
                                          and bool(re.search(
                                              rb'isBackgrounded!==!1', d))
                                          and bool(re.search(
                                              rb'return "live-work:"\+', d))
                                          and bool(re.search(
                                              rb'task_registry_readable:', d))
                                          # an unreachable registry is NOT reported as "no work"
                                          and bool(re.search(rb'__s\.reg=!!__tr', d))
                                          and bool(re.search(rb'if\(__tr&&__lv\.length>=__lth\)', d)),
    # --- волна 9 -------------------------------------------------------------
    # A mark is the PAST; the registry is the present. When the registry can be
    # read, a mark may silence the watcher only for the settling time.
    'watcher prefers the registry to a stale mark': bool(re.search(
                                              rb'return "dispatch-settling:"\+', d))
                                          and bool(re.search(
                                              rb'__now-__lm<__rc', d))
                                          # the window path survives ONLY as the
                                          # unreadable-registry fallback
                                          and bool(re.search(
                                              rb'\}else if\(__n>=__th\)\{', d))
                                          and bool(re.search(
                                              rb'return "fleet-busy:"\+__n', d)),
    # Durations and schedules on a monotonic clock, moments on the wall clock.
    'intervals are monotonic, moments are not': bool(re.search(
                                              rb'globalThis\.__ccMono\?\?=', d))
                                          and bool(re.search(
                                              rb'let __t0=globalThis\.__ccMono\(\)', d))
                                          and bool(re.search(
                                              rb'ms:globalThis\.__ccMono\(\)-__t0', d))
                                          and bool(re.search(
                                              rb'__ccFleet\.push\(globalThis\.__ccMono\(\)\)', d))
                                          and bool(re.search(
                                              rb'__s&&__s\.nextAt>globalThis\.__ccMono\(\)', d))
                                          # Часы САМОГО окна наблюдателя: от `__now`
                                          # считаются окно, порог, остывание, живая работа
                                          # и оседание. Ни один прежний конъюнкт его не
                                          # называл, а запрет знал лишь два имени -- перевод
                                          # инициализатора на стенные часы проходил зелёным
                                          # (круг 20, C-8).
                                          and bool(re.search(
                                              rb'gate:\(__c,__svc\)=>\{let __now='
                                              rb'globalThis\.__ccMono\(\),', d))
                                          # not one duration left on the wall clock
                                          and len(re.findall(rb'Date\.now\(\)-__t0', d)) == 0
                                          and len(re.findall(rb'Date\.now\(\)-__s0', d)) == 0
                                          and len(re.findall(rb'__now=Date\.now\(\)', d)) == 0
                                          # and the moment is still named by it
                                          and bool(re.search(
                                              rb'new Date\(\)\.toISOString\(\)', d)),
    'the record just written is never pruned': bool(re.search(
                                              rb'\.filter\(\(__x\)=>__x!==__n&&', d))
                                          and bool(re.search(
                                              rb'__ls\.length>=__jkeep', d)),
    # Отдельной проверкой, а не хвостом предыдущей: горизонт записей и
    # неприкосновенность архива -- два разных обещания, и обещание про архив
    # обязано уметь провалиться в одиночку. Волна 31 (L-6) перевела фильтр с
    # запретного списка на ДОПУСТИМЫЙ: записью считается кончающееся на
    # .json, всё прочее -- не наше. Сжатое (<имя>.json.gz, куда compact.py
    # кладёт старое) в счёт не идёт и не удаляется -- как и обломок
    # <имя>.json.gz.tmp.<pid>, который запретный список не знал и считал
    # ГОРЯЧЕЙ ЗАПИСЬЮ: из 45 размеченных записей горизонт унёс 24 (замер
    # 2026-08-30), а чужой обломок мог быть снесён в миг между его
    # верификацией и os.replace.
    'the archive is out of the window': bool(re.search(
                                              rb'__x\.endsWith\("\.json"\)', d)),
    'a prune losing a race is not a failure': bool(re.search(
                                              rb'if\(__ue\?\.code!=="ENOENT"\)throw __ue', d)),
    'record names sort as time inside one millisecond': bool(re.search(
                                              rb'String\(__seq\)\.padStart\(6,"0"\)', d)),
    'debug artefacts name their consultation': bool(re.search(
                                              rb'last-request\."\+process\.pid\+"\."\+__seq', d))
                                          and bool(re.search(
                                              rb'last-verdict\."\+process\.pid\+"\."\+__seq', d)),
    # Both regexes carry the flag or the pair splits: recorded by one, acted on
    # by the other.
    'the verdict vocabulary ignores case': bool(re.search(
                                              rb'\+__o\.rx\+"\):\.\*\$","gmi"\)', d))
                                          and bool(re.search(
                                              rb'\+__o\.act\+"\):', d))
                                          and bool(re.search(
                                              rb'","mi"\)\.exec\(__v\)', d)),
    # Имя обещает, что массив частей ЧИТАЕТСЯ как строка, а идентификатор
    # доказывает лишь, что кто-то спросил про массив. Заменить ветку на
    # `String(__mm.content)` -- и вердикт снова становится "[object Object]",
    # ровно тот дефект, ради которого блок написан (круг 20, C-1).
    'a content array reads like a content string': bool(re.search(
                                              rb'Array\.isArray\(__mm\.content\)\?__mm\.content'
                                              rb'\.filter\(\(__b\)=>__b\?\.type==="text"\|\|'
                                              rb'typeof __b\?\.text==="string"\)'
                                              rb'\.map\(\(__b\)=>__b\.text\)\.join\("\\n"\)'
                                              rb':String\(__mm\.content\?\?""\)', d)),
    'a BOM does not silence the channel': _bom_stripped_in_our_blocks(_probe_full),
    # `stop_reason==="max_tokens"` -- строка САМОГО апстрима (4-5 вхождений на
    # каждом пристинном образе корпуса), краснеть она не умеет. И ни один из
    # двух прежних конъюнктов не касался того, что обещает имя: ПРИЗНАТЬСЯ в
    # обрыве. Пинится объявление и обе точки, где оно приклеивается к ответу:
    # без них обрыв снова превращает BLOCK в пустой вердикт (круг 20, C-3).
    'an answer cut at the output cap says so': bool(re.search(
                                              rb'let __cut1=__j\?\.choices\?\.\[0\]\?\.'
                                              rb'finish_reason==="length"'
                                              rb'\|\|__j\?\.stop_reason==="max_tokens"'
                                              # полоса pool несёт stop_reason ВНУТРИ .message --
                                              # там же, откуда этот разбор берёт содержимое
                                              rb'\|\|__j\?\.message\?\.stop_reason==="max_tokens"\?" \[', d))
                                          and bool(re.search(
                                              rb'if\(__c1\)return __c1\.trim\(\)\+__cut1;', d))
                                          and bool(re.search(
                                              rb'return __cv\?__cv\+__cut1:""\}', d)),
    # Recorded, never gated on: the gateway answers with another id by design.
    # Считать присваивания мало: `__a.served=__clip(__e.model,80)` оставляет
    # счёт прежним и записывает ЗАПРОШЕННЫЙ ид -- шлюз, ответивший другой
    # моделью, снова неотличим (круг 20, C-4). Пинится значение на обеих ногах.
    'the model that answered is recorded': bool(re.search(
                                              rb'if\(__sv&&__sv!==__e\.model\)'
                                              rb'__a\.served=__clip\(__sv,80\)', d))
                                          and bool(re.search(
                                              rb'if\(__sv2&&__sv2!==__e\.model\)'
                                              rb'__a\.served=__clip\(__sv2,80\)', d))
                                          and len(re.findall(
                                              rb'__a\.served=', d)) == 2,
    'the output budget has one default': bool(re.search(
                                              rb'let __mtd=8000', d))
                                          and len(re.findall(
                                              rb'__cfg\.max_tokens,300,1\)', d)) == 0
                                          and len(re.findall(
                                              rb'__cfg\.max_tokens,1200,1\)', d)) == 0,
    'transcript cuts are declared like every other': bool(re.search(
                                              rb'__clip\(JSON\.stringify\(__b\.input\),400\)', d))
                                          and len(re.findall(
                                              rb'JSON\.stringify\(__b\.input\)\.slice', d)) == 0
                                          and bool(re.search(
                                              rb'\[result\] "\+__clip\(String\(', d)),
    'no cut leaves a lone surrogate': bool(re.search(
                                              rb'__sur=\(__x\)=>', d))
                                          and bool(re.search(
                                              rb'__sur\(__x\.slice\(0,__k\)\)', d))
                                          and bool(re.search(
                                              rb'__sur\(__t\.slice\(0,__h\)\)', d)),
    # Both halves of the phase, not just the comparison. Pinning `>__b` alone
    # left `__fit(...-(__tot+__mc-__n))` free to keep cutting by the raw request
    # while the loop measured by the floor -- green, and over-cutting by the
    # whole floor at context_chars=0.
    'the marker phase measures by the same floor': bool(re.search(
                                              rb'__tot\+__mc>__b', d))
                                          and len(re.findall(
                                              rb'__tot\+__mc>__n', d)) == 0
                                          and bool(re.search(
                                              rb'__tot\+__mc-__b', d))
                                          and len(re.findall(
                                              rb'__tot\+__mc-__n', d)) == 0,
    # The floor is pinned with the half. Pinning `/2` alone let the 1000 ms
    # floor be raised to anything -- including past every shipped rung, which
    # would delete the half while the name still promised it -- and left the
    # rung-under-2s case, where the floor made the retry longer than the rung,
    # invisible.
    'the retry runs on half its rung': bool(re.search(
                                              rb'__rt=__num\("rung\.timeout_ms"', d))
                                          and bool(re.search(
                                              rb'Math\.min\(__rt,Math\.max\(1000,Math\.round\(__rt/2\)\)\)', d)),
    # One expression per core copy, and no second name for the same string.
    'the probes home is computed once': len(re.findall(
                                              rb'__phome=__o\.dirEnv\|\|\(\(process\.env\.CLAUDE_CONFIG_DIR', d)) == 1
                                          and bool(re.search(
                                              rb'__jdir=__phome\+"/"\+__o\.dirName', d))
                                          and len(re.findall(
                                              rb'let __dir=__phome', d)) == 0,
    'journal line carries the session id': bool(re.search(
                                              rb'__base=\{t:__ts,sid:__sid\(\)', d))
                                          and bool(re.search(
                                              rb'__sid=\(\)=>\{try\{return [\w$]+\(\)\}catch\{return null\}\}', d))
                                          # a bare image call outside the swallower:
                                          # the swallower itself is not under the ban
                                          and len(re.findall(
                                              rb'sid:(?!__sid\(\))[\w$]+\(\),tool:', d)) == 0,
    'judge declares every truncation': len(re.findall(
                                              rb'__clip\(', d)) >= 6
                                          and len(re.findall(rb'__v\.slice\(0,400\)', d)) == 0
                                          and len(re.findall(rb'\.resp=__t2?\.slice\(0,800\)', d)) == 0
                                          # the dispatch is cut ONLY with a declaration
                                          and bool(re.search(
                                              rb'__dtr=__dsrc\.length>__dmax;', d))
                                          # Through __sur: the declaration says
                                          # how many characters were shown, and a
                                          # cut that leaves half a surrogate pair
                                          # shows one character that was never
                                          # there.
                                          and bool(re.search(
                                              rb'__disp=__dtr\?__sur\(__dsrc\.slice\(0,__dmax\)\):__dsrc', d))
                                          and bool(re.search(
                                              rb'__lbl=String\(__o\.label\|\|"DISPATCH"\)\+\(__dtr\?', d))
                                          and len(re.findall(
                                              rb'\.slice\(0,Number\(__cfg\.dispatch_chars', d)) == 0
                                          # the failed attempt's message: a bare slice
                                          # chopped off the phrase naming the tool
                                          and len(re.findall(rb'__xe\?\.message\?\?__xe\)\.slice\(', d)) == 0
                                          and bool(re.search(rb'__clip\(__em,200\)', d))
                                          # our own OUTPUT ceiling is called by its own name
                                          and bool(re.search(rb'our output budget "\+__ob\[1\]\+" exhausted', d))
                                          # before the first attempt there are ZERO attempts
                                          and bool(re.search(rb'__jtry=0,__jerr1=null', d)),
    # a broken config silently removed enforce and fail_closed: the judge
    # looked alive and let everything through, including its own BLOCK verdict
    # one home for all probes: the id is a subdirectory, not a separate
    # settings root
    'settings live in one probes home': bool(re.search(
                                              rb'__phome=__o\.dirEnv\|\|\(\(process\.env\.CLAUDE_CONFIG_DIR\|\|'
                                              rb'\(\(process\.env\.HOME\|\|"\."\)\+"/\.claude"\)\)\+"/probes"\),'
                                              rb'__jdir=__phome\+"/"\+__o\.dirName', d))
                                          # a probe's journal lives in its subdirectory of the same home
                                          and bool(re.search(
                                              rb'__jdir=__phome\+"/"\+__o\.dirName;', d))
                                          # ONE environment variable for all probes
                                          and len(re.findall(rb'dirEnv:process\.env\.CLAUDE_PROBES_DIR', d)) == 2
                                          and len(re.findall(rb'CLAUDE_JUDGE_DIR', d)) == 0
                                          and len(re.findall(rb'CLAUDE_IDLE_DIR', d)) == 0,
    # [defaults] under the probe table; a probe not named in the file gets
    # bare defaults — that is the absence of its own edits, not an error
    'probe settings merge defaults under the probe table': bool(re.search(
                                              rb'let __eff=\(__t,__id\)=>__t&&typeof __t==="object"'
                                              rb'\?\{\.\.\.\(__t\.defaults\|\|\{\}\),'
                                              rb'\.\.\.\(\(__t\.probe\|\|\{\}\)\[__id\]\|\|\{\}\)\}:\{\}', d)),
    # disabling a probe is a setting; the registry must silence one consumer
    # without touching the others, and the silencing must be VISIBLE in the
    # journal
    # ...и не печатает эту строку на КАЖДОМ вызове: памятка ядра гасит ПОВТОР
    # до конца объявленного срока, срок едет в той же строке, а подпись
    # настроек возвращает строку немедленно, как только настройки правят
    # (круг 20, D-3; сужено после измерения стендом зондов -- ранний выход ДО
    # чтения конфига ломал «настройки читаются на каждой консультации»).
    'a disabled probe says so in the journal': bool(re.search(
                                              rb'if\(__cfg\.enabled===!1\)\{'
                                              rb'let __dm=__num\("disabled_memo_ms",'
                                              rb'__cfg\.disabled_memo_ms,60000,0\),', d))
                                          and bool(re.search(
                                              rb'__pv=__offs\[__o\.dirName\];'
                                              rb'if\(!\(__pv&&__pv\.s===__sg'
                                              rb'&&__pv\.u>globalThis\.__ccMono\(\)\)\)\{', d))
                                          and bool(re.search(
                                              rb'__offs\[__o\.dirName\]='
                                              rb'\{u:globalThis\.__ccMono\(\)\+__dm,s:__sg\};'
                                              rb'await __jlog\(\{outcome:"skip_disabled",'
                                              rb'memo_ms:__dm\}\)\}return\}', d))
                                          # Ранний выход ДО чтения настроек не
                                          # должен вернуться: он и был тем, что
                                          # уводило в тишину всё после первой
                                          # выключенной пробы в процессе.
                                          and not re.search(
                                              rb'if\(__offs\[__o\.dirName\]>'
                                              rb'globalThis\.__ccMono\(\)\)return;', d),
    # a missing TOML parser is an event, not empty settings: empty ones
    # silently remove enforce, the ladder and the budgets
    'a missing TOML parser is declared, not silently empty': bool(re.search(
                                              rb'let __tp=globalThis\.Bun\?\.TOML\?\.parse;'
                                              rb'if\(typeof __tp!=="function"\)\{'
                                              rb'__deg\.push\("no-toml-parser:"\+__f\);'
                                              rb'__degb\.push\("no-toml-parser:"\+__f\);return !1\}', d)),
    'debug artefacts do not collide between processes or consultations': (
                                              bool(re.search(
                                                  rb'__jdir\+"/last-request\."\+process\.pid\+"\."\+__seq\+"\.json"', d))
                                          and bool(re.search(
                                                  rb'__jdir\+"/last-verdict\."\+process\.pid\+"\."\+__seq\+"\.txt"', d))
                                          and len(re.findall(rb'"/last-request\.json"', d)) == 0
                                          and len(re.findall(rb'"/last-verdict\.txt"', d)) == 0),
    'judge tells a broken config from a missing one': bool(re.search(
                                              rb'let __ldt=async\(__f\)=>\{let __x=await __rdj\(__f\)', d))
                                          and bool(re.search(
                                              rb'let __x2=await __rdj\(__f\);'
                                              rb'if\(__x2!==null&&__x2!==__x\)\{', d))
                                          and bool(re.search(
                                              rb'let __c0=await __ldt\(__phome\+"/probes\.toml"\);'
                                              rb'if\(__c0===!1\)__cfgbad=!0;else if\(__c0\)'
                                              rb'\{__cfgseen=!0;__cfg=__eff\(__c0,__o\.dirName\)\}', d))
                                          # unknown enforce/fail_closed count as ON;
                                          # волна 31 (K-2): сравнения ===!0 заменены типизированным
                                          # читателем __bl3 с безопасной стороной (см. ядро)
                                          and bool(re.search(
                                              rb'__bl3\("enforce",__cfg\.enforce,!0\)\|\|__cfgbad', d))
                                          and bool(re.search(
                                              rb'let __fcl=__cfgbad\|\|__bl3\("fail_closed",__cfg\.fail_closed,!0\)', d))
                                          # an unreadable layer is distinct from a missing one:
                                          # "no such path" (ENOENT/ENOTDIR/ELOOP) versus
                                          # "the path exists, no access" (EACCES/EPERM)
                                          and bool(re.search(
                                              rb'__c==="EACCES"\|\|__c==="EPERM"\?2:', d))
                                          and bool(re.search(
                                              rb'__c==="ENOENT"\|\|__c==="ENOTDIR"\|\|'
                                              rb'__c==="ELOOP"\|\|__c==="ENAMETOOLONG"\?0:3', d))
                                          and bool(re.search(
                                              rb'__deg\.push\("layer-unreadable:"', d))
                                          # a BOM is invisible and the parser rejects it
                                          and bool(re.search(
                                              rb'if\(__x\.charCodeAt\(0\)===65279\)__x=__x\.slice\(1\)', d))
                                          and bool(re.search(
                                              rb'__deg\.push\("empty:"\+__f\)', d)),
    # broken rules are not "fall back to defaults" but a cancellation naming
    # the file
    # Половина prompt.md -- законный текст: ни разбор, ни prompt-missing её не
    # ловят, и вызов уехал бы с половиной свода правил. Признак несёт сам файл,
    # а обрыв объявляется КАК ДЕФЕКТ СУЖДЕНИЯ (__degb), то есть отменяет вызов
    # при enforce+fail_closed, наравне с отсутствующим промтом.
    'judge tells a truncated rule-book from a whole one': bool(re.search(
                                              rb'__sys\.indexOf\("<!-- END OF RULES -->"\)<0', d))
                                          and bool(re.search(
                                              rb'let __ptr="prompt-truncated:"\+\(__pdir\?__pdir:__jdir\)\+"/prompt\.md";'
                                              rb'__deg\.push\(__ptr\);__degb\.push\(__ptr\)', d)),
    # Инвариант рамки проверялся ТОЛЬКО на каноне (tools/emit-check.js читает
    # файл из дерева), а развёрнутый шаблон -- ни разу и нигде. Шаблон без
    # {{LABEL}} молча терял объявление об усечении, без {{DISPATCH}} судье
    # уходил пустой бриф -- и оба состояния не имели записи в deg.
    'the deployed body template is checked for its placeholders': bool(re.search(
                                              rb'\["\{\{LABEL\}\}","\{\{CONTEXT\}\}","\{\{DISPATCH\}\}"\]'
                                              rb'\.filter\(\(__ph\)=>__tplr\.indexOf\(__ph\)<0\)', d))
                                          # Вместе с ОХРАНОЙ, а не только с нагрузкой: мутация
                                          # `if(__miss.length&&!1)` оставляет оба текста на месте
                                          # и обезоруживает ветку -- проверка, пинящая одну
                                          # нагрузку, проходит по такой правке зелёной (измерено).
                                          and bool(re.search(
                                              rb'if\(__miss\.length\)\{'
                                              rb'__deg\.push\("body-no-placeholder:"\+__miss\.join\(","\)\);__tplr=null\}', d)),
    # Недоступный каталог записей давал строку журнала БЕЗ rec и БЕЗ deg --
    # побайтово такую же, как при record=false. Корпус мог перестать расти
    # навсегда, а журнал читался как здоровая установка с выключенной записью.
    'a failed record write is a declared degradation': bool(re.search(
                                              rb'__deg\.push\("rec-write:"\+String\(__re\?\.code\?\?""\)', d))
                                          # в __deg, но НЕ в __degb: права на диске не отменяют чужие вызовы
                                          and not bool(re.search(
                                              rb'__degb\.push\("rec-write:', d)),
    'judge cancels when its rules are broken': bool(re.search(
                                              rb'if\(__degb\.length&&__en\)\{', d))
                                          and bool(re.search(
                                              rb'await __o\.onBroken\(__dcut\(__degb,3\)\.join\("; "\),__svc\)', d))
                                          and bool(re.search(
                                              rb'outcome:__o\.arm\?"block_degraded":"skip_degraded"', d))
                                          # a probe that does not cancel the dispatch does not pay
                                          # for a consultation by rules it does not have
                                          and bool(re.search(
                                              rb'await __o\.onBroken\(__dcut\(__degb,3\)\.join\("; "\),__svc\);return\}', d))
                                          and bool(re.search(
                                              rb'\.\.\.\(__deg\.length\?\{deg:__dcut\(__deg,5\)\}:\{\}\)', d))
                                          and bool(re.search(
                                              rb'onBroken:\(__r\)=>\{let __e=new Error[\s\S]{0,4000}?__e\.__ccJudgeBlock=!0;throw __e\}', d)),
    # the fallback prompt must be able to cancel, otherwise the gate is
    # formally alive and substantively off: the old one had no word BLOCK at
    # all
    'fallback prompt can cancel': b'BLOCK cancels the dispatch' in d
                                          and b'SWAP:<model>:<why>' not in d
                                          and bool(re.search(
                                              rb'let __pmm="prompt-missing:"\+__jdir', d)),
    # an answer outside the vocabulary is not a verdict: it used to be
    # recorded as ok
    'an unrecognised answer is not a verdict': bool(re.search(
                                              rb'let __cv=\(\(String\(__rr\)\.match\(__rx\)\|\|\[\]\)'
                                              rb'\.pop\(\)\|\|""\)\.trim\(\);'
                                              rb'return __cv\?__cv\+__cut1:""\}', d))
                                          and len(re.findall(rb'\.pop\(\)\)\|\|__ct\)\.trim\(\)', d)) == 0,
    # a cancellation must have a way out: which file to fix, and whether
    # several more like it were silently dropped
    'a cancelled dispatch names the file to fix': bool(re.search(
                                              rb'"prompt-missing:"\+__jdir\+"/prompt\.md"', d))
                                          # degradation lists are cut with a declaration
                                          and bool(re.search(
                                              rb'__dcut=\(__l,__k\)=>\(__l\.length<=__k\?__l:'
                                              rb'__l\.slice\(0,__k\)\)\.map\(\(__i\)=>__clip\('
                                              rb'typeof __i==="string"\?__i:JSON\.stringify\(__i\),300\)\)'
                                              rb'\.concat\(', d))
                                          and len(re.findall(rb'__deg\.slice\(0,5\)', d)) == 0
                                          and len(re.findall(rb'__degb\.slice\(0,3\)', d)) == 0
                                          and bool(re.search(rb'deg:__dcut\(__deg,5\)', d))
                                          # on a fresh install the journal creates its own directory
                                          and bool(re.search(
                                              rb'catch\(__ae\)\{if\(__ae\?\.code!=="ENOENT"\)throw __ae;'
                                              rb'await __jfs\.mkdir\(__jdir,\{recursive:!0\}\)', d)),
    # local command output is a PROGRAM's answer; it must not carry the human
    # label: otherwise pinning keeps it forever as an authorization
    'judge does not read command output as the human': bool(re.search(
                                              rb'__bt\.includes\("<local-command-stdout"\)', d))
                                          and bool(re.search(
                                              rb'\?"user-command":', d))
                                          and bool(re.search(
                                              rb'<command-args>\\s\*\[\^\\s<\]/\.test\(__bt\)\)\?"user"', d))
                                          # МЕТКА самой ветки stdout/stderr. Прежние три конъюнкта
                                          # брали `?"user-command":` -- метку СОСЕДНЕЙ ветки (слэш-
                                          # команда без аргументов), и подмена этой на `?"user":`
                                          # проходила зелёной (круг 20, C-2).
                                          and bool(re.search(
                                              rb'\?"tool-output":__M\?\.isCompactSummary\?'
                                              rb'"compaction-summary":', d)),
    # Класс диспатча берётся ОДНОЗНАЧНО: цитата чужого маркера в теле брифа
    # угоняла фильтр первым совпадением, а несколько РАЗНЫХ маркеров теперь не
    # дают пропустить вызов мимо судьи и объявляются отдельно (круг 20, D-8).
    'dispatch class is taken unambiguously': bool(re.search(
                                              rb'__cls=\[\.\.\.new Set\(\(String\(__pm\)\.match\('
                                              rb'/\\\[dispatch-class:\[\\w-\]\+\\\]/g\)\|\|\[\]\)', d))
                                          and bool(re.search(
                                              rb'__amb=__cls\.length>1,__cl=__cls\.length===1\?__cls\[0\]:"",', d))
                                          and bool(re.search(
                                              rb'if\(__amb\)__deg\.push\("dispatch-class-ambiguous:"'
                                              rb'\+__dcut\(__cls,4\)\);'
                                              rb'if\(!__amb&&__mt\("classes_skip",__f\.classes_skip,__cl,!1\)\)', d)),
    # Вытеснение из стэша хода -- усечение материала судьи, и оно объявляется:
    # без метки «хода не было» не отличалось от «ход вытеснен» (круг 20, D-11).
    'an evicted turn is declared': bool(re.search(
                                              rb'\(globalThis\.__ccJudgeTurnLost\?\?=new Set\(\)\)'
                                              rb'\.add\(__k\);', d))
                                          and bool(re.search(
                                              rb'turnLost:\(\)=>globalThis\.__ccJudgeTurnLost\?\.has\(', d))
                                          and bool(re.search(
                                              rb'if\(!__t\.length&&__o\.turnLost&&__o\.turnLost\(\)\)'
                                              rb'__deg\.push\("turn-evicted"\);', d)),
    # Предмет консультации и соседи ТОГО ЖЕ хода помечены в ленте ПОЛЯМИ:
    # склеенная лента показывала судье его собственный вызов среди
    # «уже случившегося», и он отменял его как повтор уже отправленного голоса,
    # а соседа по сообщению не засчитывал в веер (круг 21, находка контроллера).
    # Метка -- поле, а не префикс текста: `text` содержимым не доверяют.
    'the judge sees which calls are its own turn': bool(re.search(
                                              rb'let __nh=\(__o\.ctx\.messages\|\|\[\]\)\.length;'
                                              rb'let __sid=__o\.selfId\?__o\.selfId\(\):null;', d))
                                          and bool(re.search(
                                              rb'let __slf=!!\(__sid&&__c\.some\(\(__x\)=>'
                                              rb'__x\?\.type==="tool_use"&&__x\.id===__sid\)\);', d))
                                          and bool(re.search(
                                              rb'return\{src:__role,text:__bt,'
                                              rb'\.\.\.\(__now\?\{now:!0\}:\{\}\),'
                                              rb'\.\.\.\(__slf\?\{self:!0\}:\{\}\)\}', d))
                                          and bool(re.search(rb'selfId:\(\)=>', d)),
    # an unknown wrapper under the user role must be VISIBLE in the journal:
    # three defects in a row were one class, found through an incident
    'judge reports unknown user-role wrappers': bool(re.search(
                                              rb'\{uw:__dcut\(__uw,5\)\}', d))
                                          and bool(re.search(
                                              rb'"command-name","command-message","command-args"', d)),
    # after compaction the summary is the ONLY carrier of standing directives;
    # it is pinned with its own share and trimmed by text, not dropped
    'judge pins the compaction summary': bool(re.search(
                                              rb'__M\?\.isCompactSummary\?"compaction-summary"', d))
                                          and bool(re.search(
                                              rb'__x\.src==="compaction-summary"\)', d))
                                          and bool(re.search(
                                              rb'__sb=Math\.floor\(__b\*0\.3\)', d)),
    # a rung failure must carry the reason and its own reply, otherwise there
    # is nothing to analyze
    # `__a.resp=` -- запись тела на УСПЕШНОЙ ноге, к причине провала она
    # отношения не имеет, а голый префикс остаётся на месте и когда причину
    # выбросили: журнал снова висит на "api error from the pool: " без текста
    # (круг 20, C-5). Пинится сама причина.
    'judge keeps the reason of a failed rung': bool(re.search(
                                              rb'throw new Error\("api error from the pool: "'
                                              rb'\+\(__clip\(__et,300\)\|\|', d))
                                          and len(re.findall(rb'__a\.resp=', d)) == 2,
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
    # Two adjacent names in a literal proved neither the full list nor the part
    # that can give a WRONG answer instead of a missing one: the alternates are
    # read with `void 0` in place of the storage descriptor, and swapping that
    # back makes the loader serve CLAUDE.md's bytes under another name. Both are
    # pinned now.
    'CLAUDE.md alternates tried': _claude_md_alternates_are_tried(d),
}
# The count is an invariant, not a running total. `all({}.values())` is True,
# so a merge that drops the dictionary -- or a block of it -- leaves a green
# build with nothing behind it. And an unpinned count is a number people get
# wrong: the author of these lines twice recounted the keys with a regex that
# breaks on the escaped apostrophe inside `current turn is the judge\'s alone`,
# reported 88, and was corrected by the run itself printing 89 — historical:
# both are what was miscounted then, not a count of anything now.
EXPECTED_CHECKS = 119
if len(checks) != EXPECTED_CHECKS:
    print(f"  [FAIL] the check registry holds {len(checks)} entries, expected "
          f"{EXPECTED_CHECKS} — checks were added or lost without updating the count")
    sys.exit(1)
for name, ok in checks.items():
    print(f"  [{'OK' if ok else 'FAIL'}] {name}")
sys.exit(0 if all(checks.values()) else 1)
PY

# --- 5a0. пол проверок: что остаётся зелёным на ПРИСТИННОМ образе -------------
# Круг 28, F-12: фраза стояла «все 114 сошлись» (docnum:historical) при
# ТОГДАШНЕМ EXPECTED_CHECKS = 118 (docnum:historical) в девяти строках выше -- существительное было
# элидировано, и гейт чисел не видел расхождения ПО УСТРОЙСТВУ (пару «число +
# существительное» не из чего было строить). Число починено, существительное
# и владелец названы явно.
# Реестр выше говорит, что все 119 проверок конвейера сошлись НА СОБРАННОМ
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
  bash "$HERE/tools/checks-on-image.sh" --floor "$FLOOR_IMG" "$OUR_PATCH" || {
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
GATE_BUDGET="$(validated_nonnegative_integer CLAUDE_PATCH_GATE_BUDGET "${CLAUDE_PATCH_GATE_BUDGET:-150}")"
# G-5: поднятый или срезанный бюджет меняет СМЫСЛ вердикта этого гейта
# (срезанный краснит здоровую сборку, поднятый прячет медленную), поэтому
# отклонение от умолчания объявляется в потоке, а не остаётся в окружении.
[[ "$GATE_BUDGET" == "150" ]] \
  || echo "Interface gate: budget ${GATE_BUDGET}s (CLAUDE_PATCH_GATE_BUDGET, default 150)"

# Н-3 (круг 24): величина бюджета проверяется ДО первого следа на диске и до
# запуска ребёнка. Под `set -euo pipefail` отказ валидатора обрывает прогон
# немедленно, а стоял он ниже -- после mktemp -d и после спавна сессии; кривая
# ручка оставляла ЖИВОГО сироту в своей группе процессов и каталог, который
# уже некому убрать: уборка -- не трап, а строка `rm -rf "$GATE_HOME"` в КОНЦЕ
# секции, до неё обрыв не доходит. Порядок здесь -- инвариант: между
# этой проверкой и созданием $GATE_HOME не должно появляться ничего, что
# создаёт файлы или процессы.
GATE_HOME="$(mktemp -d)"
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

# `exec` replaces the subshell so $! is the pid that setsid then makes a session
# and process-group leader. Killing the single pid leaves `script` and the CLI
# running: during one version sweep that left 23 sessions and 1.4 GB resident.
# The group kill is what actually ends the run.
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
(
  cd "$GATE_HOME/proj" || exit 1
  exec env CLAUDE_CONFIG_DIR="$GATE_HOME/cfg" CLAUDE_CODE_CHILD_SESSION=1 \
    perl -e 'use POSIX (); POSIX::setsid(); exec @ARGV or die $!' \
    script -q /dev/null "$BIN" --strict-mcp-config "$GATE_PROMPT" >"$GATE_LOG" 2>&1
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
  GATE_STATE="$(gate_state_checked)"
  case "$GATE_STATE" in
    ERROR*|TOOLFAIL*) break ;;
  esac
  if ! kill -0 $GATE_PID 2>/dev/null; then
    # It ended on its own. That is not success by itself: read the exit status.
    GATE_EXITED=1
    wait $GATE_PID 2>/dev/null
    GATE_RC=$?
    GATE_STATE="$(gate_state_checked)"
    break
  fi
  if [[ "$GATE_STATE" == RENDERED ]]; then
    # An error can still land after the first paint, so keep watching for a
    # while instead of declaring victory three seconds in.
    for _ in $(seq 1 8); do
      sleep 1
      GATE_STATE="$(gate_state_checked)"
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
        wait $GATE_PID 2>/dev/null
        GATE_RC=$?
        GATE_STATE="$(gate_state_checked)"
        break
      fi
    done
    break
  fi
done

if [[ $GATE_EXITED -eq 0 ]]; then
  kill -TERM -"$GATE_PID" 2>/dev/null || kill -TERM "$GATE_PID" 2>/dev/null || true
  # GATE_BUDGET bounds the POLLING, not this. A child that ignores TERM -- or is
  # stuck in a syscall -- leaves the bare `wait` below waiting forever, and the
  # FATAL that explains the timeout sits after it and never prints. Give TERM a
  # few seconds, then take the process group out with KILL.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$GATE_PID" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 "$GATE_PID" 2>/dev/null; then
    echo "  the interface gate ignored TERM; killing it" >&2
    kill -KILL -"$GATE_PID" 2>/dev/null || kill -KILL "$GATE_PID" 2>/dev/null || true
  fi
  wait $GATE_PID 2>/dev/null || true
  GATE_RC=0
fi

case "$GATE_STATE" in
  RENDERED)
    if [[ ${GATE_RC:-0} -ne 0 ]]; then
      echo "FATAL: the interface drew its message and then exited ${GATE_RC}" >&2
      echo "  capture kept at $GATE_LOG" >&2
      exit 1
    fi
    echo "Interface: came up in a throwaway home and drew its message, no name or type errors"
    rm -rf "$GATE_HOME"
    ;;
  TOOLFAIL*)
    echo "FATAL: гейт интерфейса НЕ ИЗМЕРЕН -- сломан разбор захвата, а не продукт" >&2
    echo "  ${GATE_STATE#TOOLFAIL }" >&2
    echo "  capture kept at $GATE_LOG" >&2
    exit 1
    ;;
  ERROR*)
    echo "FATAL: the interface does not come up — leaving the launcher alone" >&2
    echo "  ${GATE_STATE#ERROR }" >&2
    echo "  capture kept at $GATE_LOG" >&2
    exit 1
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
    exit 1
    ;;
esac

# --- 5a3. the probes must BEHAVE, not merely be present -----------------------
# The checks above are text checks on the image and the interface gate only
# proves the product starts. Neither runs the judge or the watcher. The bench
# does: it carves both probe blocks out of the finished binary, compiles them,
# and drives probe-bench's 82 scenarios through a throwaway probes home —
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
  BENCH="$(dirname "$0")/tools/probe-bench.js"
  if ! command -v bun >/dev/null; then
    # The bench must run under bun: the image is a single-file bun executable
    # and the carved block is executed by its engine. Refusing loudly beats a
    # skip that reads like a pass.
    echo "FATAL: bun is required to run the probe bench (the image is a bun executable)." >&2
    echo "  Set CLAUDE_PATCH_SKIP_BENCH=1 to build without this gate." >&2
    exit 1
  fi
  BENCH_LOG="$(mktemp)"
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
    BENCH_N=$(printf '%s' "$BENCH_SUM" | sed -n 's/.*сценариев=\([0-9][0-9]*\).*/\1/p')
    BENCH_BAD=$(printf '%s' "$BENCH_SUM" | sed -n 's/.*расхождений=\([0-9][0-9]*\).*/\1/p')
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
    if ! grep -E 'MISMATCH|probe-bench:' "$BENCH_LOG" | sed 's/^/  /' >&2; then
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
  if [[ "$BIN" == *.staging ]]; then
    FINAL="${BIN%.staging}"
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
  VERSIONS_DIR="$(dirname "$BIN")"
  # The keep-list is built from the REAL version name, not the target name:
  # when building into staging (--target X.staging) basename would give
  # "2.1.237.staging", and the cleanup would wipe the live 2.1.237 along with
  # its pristine .orig — everything except the intermediate file. Only the
  # binary a live session was executing at that moment would survive.
  CURRENT_VER="$(basename "$BIN")"
  CURRENT_VER="${CURRENT_VER%.staging}"
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
        base="$(basename "$old")"
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
  __value=$(printf '%s' "$__raw" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  case "$__value" in
    1|true|yes|on) return 0 ;;
    ''|0|false|no|off) return 1 ;;
    *) echo "FATAL: $__name='$__raw' -- expected 1/true/yes/on or 0/false/no/off" >&2
       return 2 ;;
  esac
}

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
__envon CLAUDE_PATCH_SKIP_MODELS; __env_rc=$?
(( __env_rc != 2 )) || exit 2
if (( __env_rc == 0 )); then
  echo "Model data: SKIPPED — CLAUDE_PATCH_SKIP_MODELS=1; prices and context windows are stale"
elif [[ ! -f "$COSTS_SYNC" ]]; then
  echo "Model data: SKIPPED — $(basename "$COSTS_SYNC") is not in this kit; prices and context windows are stale" >&2
elif true; then
  echo
  echo "==> Refreshing model prices and context windows"
  MODELS_LOG="$(mktemp)"
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
